import SwiftUI
import Charts

struct BandwidthTestView: View {
    @ObservedObject var viewModel: CANDashboardViewModel
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Connection Status Card
                VStack(alignment: .leading, spacing: 16) {
                    Text("Adapter Status")
                        .font(.headline)
                    
                    HStack(spacing: 20) {
                        // Adapter 1 Status
                        VStack(spacing: 8) {
                            Image(systemName: viewModel.testDirection == 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                .font(.title)
                                .foregroundColor(viewModel.adapter1.isCANOpen ? .blue : .red)
                            Text("Adapter 1 (A1)")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(viewModel.adapter1.isCANOpen ? "Ready" : "Closed")
                                .font(.caption)
                                .foregroundColor(viewModel.adapter1.isCANOpen ? .green : .red)
                            if viewModel.adapter1.isCANOpen {
                                Text(viewModel.testDirection == 0 ? "TX Node" : "RX Node")
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(viewModel.testDirection == 0 ? Color.blue.opacity(0.2) : Color.purple.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.platformSecondaryBackground)
                        .cornerRadius(12)
                        
                        // Directional Arrow
                        VStack {
                            Image(systemName: viewModel.testDirection == 0 ? "arrow.right" : "arrow.left")
                                .font(.title2)
                                .foregroundColor(.secondary)
                            Text(viewModel.testDirection == 0 ? "A1 → A2" : "A2 → A1")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        // Adapter 2 Status
                        VStack(spacing: 8) {
                            Image(systemName: viewModel.testDirection == 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                .font(.title)
                                .foregroundColor(viewModel.adapter2.isCANOpen ? .purple : .red)
                            Text("Adapter 2 (A2)")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(viewModel.adapter2.isCANOpen ? "Ready" : "Closed")
                                .font(.caption)
                                .foregroundColor(viewModel.adapter2.isCANOpen ? .green : .red)
                            if viewModel.adapter2.isCANOpen {
                                Text(viewModel.testDirection == 0 ? "RX Node" : "TX Node")
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(viewModel.testDirection == 0 ? Color.purple.opacity(0.2) : Color.blue.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.platformSecondaryBackground)
                        .cornerRadius(12)
                    }
                }
                .padding()
                .background(Color.platformBackground)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .padding(.horizontal)
                
                // Test Configuration
                VStack(alignment: .leading, spacing: 16) {
                    Text("Test Configuration")
                        .font(.headline)
                    
                    HStack(spacing: 20) {
                        VStack(alignment: .leading) {
                            Text("Direction")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Picker("Direction", selection: $viewModel.testDirection) {
                                Text("A1 sends to A2").tag(0)
                                Text("A2 sends to A1").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .disabled(viewModel.isBandwidthTestRunning)
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Message Size")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Picker("Size", selection: $viewModel.testMessageSize) {
                                Text("8 bytes").tag(8)
                                Text("64 bytes (FD)").tag(64)
                            }
                            .pickerStyle(.segmented)
                            .disabled(viewModel.isBandwidthTestRunning)
                            .onChange(of: viewModel.testMessageSize) { _, newValue in
                                if newValue > 8 { viewModel.testUseFD = true }
                            }
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Burst Size")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Picker("Burst", selection: $viewModel.testBurstSize) {
                                Text("1").tag(1)
                                Text("2").tag(2)
                                Text("4").tag(4)
                                Text("6").tag(6)
                                Text("10").tag(10)
                                Text("50").tag(50)
                            }
                            .pickerStyle(.menu)
                            .disabled(viewModel.isBandwidthTestRunning)
                        }
                    }
                    
                    if !viewModel.adapter1.isCANOpen || !viewModel.adapter2.isCANOpen {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Both adapters must be connected and CAN channels open to run tests.")
                                .font(.subheadline)
                                .foregroundColor(.orange)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding()
                .background(Color.platformBackground)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .padding(.horizontal)
                
                // Controls
                HStack(spacing: 20) {
                    Button(action: {
                        if viewModel.isBandwidthTestRunning {
                            viewModel.stopBandwidthTest()
                        } else {
                            viewModel.startBandwidthTest()
                        }
                    }) {
                        HStack {
                            Image(systemName: viewModel.isBandwidthTestRunning ? "stop.fill" : "play.fill")
                            Text(viewModel.isBandwidthTestRunning ? "Stop Test" : "Start Full Bandwidth Test")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(viewModel.isBandwidthTestRunning ? Color.red : (viewModel.adapter1.isCANOpen && viewModel.adapter2.isCANOpen ? Color.blue : Color.gray))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(!viewModel.adapter1.isCANOpen || !viewModel.adapter2.isCANOpen)
                    
                    Button(action: {
                        viewModel.resetBandwidthStats()
                    }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset Stats")
                        }
                        .padding()
                        .background(Color.platformSecondaryBackground)
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                    }
                    .disabled(viewModel.isBandwidthTestRunning)
                }
                .padding(.horizontal)
                
                // Real-time Results
                if viewModel.bandwidthStats.messagesSent > 0 || viewModel.isBandwidthTestRunning {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Real-time Performance")
                                .font(.headline)
                            Spacer()
                            Text(String(format: "Duration: %.1fs", viewModel.bandwidthStats.duration))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        
                        // Performance Metrics Grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                            // TX Rate
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "arrow.up.right")
                                        .foregroundColor(viewModel.testDirection == 0 ? .blue : .purple)
                                    Text("TX Rate")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(String(format: "%.0f msg/s", viewModel.bandwidthStats.instantTxRate))
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .monospacedDigit()
                            }
                            .padding()
                            .background(Color.platformSecondaryBackground)
                            .cornerRadius(12)
                            
                            // RX Rate
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "arrow.down.right")
                                        .foregroundColor(viewModel.testDirection == 0 ? .purple : .blue)
                                    Text("RX Rate")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Text(String(format: "%.0f msg/s", viewModel.bandwidthStats.instantRxRate))
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .monospacedDigit()
                            }
                            .padding()
                            .background(Color.platformSecondaryBackground)
                            .cornerRadius(12)
                            
                            // Success Rate
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "checkmark.seal.fill")
                                        .foregroundColor(viewModel.bandwidthStats.instantRxRate >= viewModel.bandwidthStats.instantTxRate * 0.99 ? .green : .orange)
                                    Text("Delivery Rate")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                let txRate = max(viewModel.bandwidthStats.instantTxRate, 1)
                                let rxRate = viewModel.bandwidthStats.instantRxRate
                                let ratio = min((rxRate / txRate) * 100, 100)
                                Text(String(format: "%.1f %%", ratio))
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .monospacedDigit()
                            }
                            .padding()
                            .background(Color.platformSecondaryBackground)
                            .cornerRadius(12)
                        }
                        
                        // Chart Tracking Rates
                        if !viewModel.bandwidthHistory.isEmpty {
                            Chart {
                                ForEach(viewModel.bandwidthHistory) { point in
                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("TX Rate", point.txRate),
                                        series: .value("Type", "TX")
                                    )
                                    .foregroundStyle(viewModel.testDirection == 0 ? .blue : .purple)
                                    
                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("RX Rate", point.rxRate),
                                        series: .value("Type", "RX")
                                    )
                                    .foregroundStyle(viewModel.testDirection == 0 ? .purple : .blue)
                                }
                            }
                            .chartXAxis(.hidden)
                            .chartYAxis {
                                AxisMarks(position: .leading)
                            }
                            .frame(height: 180)
                            .padding(.top, 8)
                        }
                    }
                    .padding()
                    .background(Color.platformBackground)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                    .padding(.horizontal)
                    
                    // Detailed Statistics
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Cumulative Diagnostics")
                            .font(.headline)
                        
                        Divider()
                        
                        HStack(alignment: .top, spacing: 20) {
                            // Column 1: TX/RX Counters
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Totals").font(.subheadline).foregroundColor(.secondary)
                                StatRow(title: "Messages Sent", value: "\(viewModel.bandwidthStats.messagesSent)")
                                StatRow(title: "Messages Received", value: "\(viewModel.bandwidthStats.messagesReceived)")
                                StatRow(title: "Bytes Sent", value: "\(viewModel.bandwidthStats.bytesSent)")
                                StatRow(title: "Bytes Received", value: "\(viewModel.bandwidthStats.bytesReceived)")
                                
                                let totalSent = max(viewModel.bandwidthStats.messagesSent, 1)
                                let totalRecv = viewModel.bandwidthStats.messagesReceived
                                let loss = totalSent > totalRecv ? totalSent - totalRecv : 0
                                let lossPct = (Double(loss) / Double(totalSent)) * 100
                                
                                StatRow(title: "Packet Loss", value: String(format: "%d (%.2f%%)", loss, lossPct),
                                        valueColor: loss > 0 ? .red : .primary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            // Column 2: Driver Metrics
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Driver Level").font(.subheadline).foregroundColor(.secondary)
                                StatRow(title: "RX Polls (Total)", value: "\(viewModel.bandwidthStats.rxPolls)")
                                StatRow(title: "RX Hits (Data)", value: "\(viewModel.bandwidthStats.rxHits)")
                                StatRow(title: "Raw Bytes Read", value: "\(viewModel.bandwidthStats.rxRawBytes)")
                                
                                let efficiency = viewModel.bandwidthStats.rxPolls > 0 ?
                                    (Double(viewModel.bandwidthStats.rxHits) / Double(viewModel.bandwidthStats.rxPolls)) * 100 : 0
                                StatRow(title: "Poll Efficiency", value: String(format: "%.1f%%", efficiency))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            // Column 3: Integrity Metrics
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Data Integrity (C++)").font(.subheadline).foregroundColor(.secondary)
                                StatRow(title: "Sequence Gaps", value: "\(viewModel.bandwidthStats.rxSequenceGaps)",
                                        valueColor: viewModel.bandwidthStats.rxSequenceGaps > 0 ? .red : .primary)
                                StatRow(title: "Out Of Order", value: "\(viewModel.bandwidthStats.rxOutOfOrder)",
                                        valueColor: viewModel.bandwidthStats.rxOutOfOrder > 0 ? .orange : .primary)
                                StatRow(title: "Duplicates", value: "\(viewModel.bandwidthStats.rxDuplicates)",
                                        valueColor: viewModel.bandwidthStats.rxDuplicates > 0 ? .orange : .primary)
                                StatRow(title: "Decode Failures", value: "\(viewModel.bandwidthStats.rxDecodeFailures)",
                                        valueColor: viewModel.bandwidthStats.rxDecodeFailures > 0 ? .red : .primary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                    .background(Color.platformBackground)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                    .padding(.horizontal)
                    .padding(.bottom, 30) // Extra padding for scrolling
                }
                
                Spacer(minLength: 20)
            }
            .padding(.top, 16)
        }
    }
}

// Sub-component for a data row in statistics
struct StatRow: View {
    let title: String
    let value: String
    var valueColor: Color = .primary
    
    var body: some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(valueColor)
                .monospacedDigit()
        }
    }
}
