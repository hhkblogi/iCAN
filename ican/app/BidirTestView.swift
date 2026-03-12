import SwiftUI
import Charts

struct BidirTestView: View {
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
                            Image(systemName: "arrow.up.arrow.down.circle.fill")
                                .font(.title)
                                .foregroundColor(viewModel.adapter1.isCANOpen ? .blue : .red)
                            Text("Adapter 1 (A1)")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(viewModel.adapter1.isCANOpen ? "Ready" : "Closed")
                                .font(.caption)
                                .foregroundColor(viewModel.adapter1.isCANOpen ? .green : .red)
                            if viewModel.adapter1.isCANOpen {
                                Text("TX: 0x200 / RX: 0x201")
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.platformSecondaryBackground)
                        .cornerRadius(12)
                        
                        // Bidirectional Arrows
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.right")
                                .font(.title2)
                                .foregroundColor(.blue)
                            Text("Full Duplex")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Image(systemName: "arrow.left")
                                .font(.title2)
                                .foregroundColor(.orange)
                        }
                        
                        // Adapter 2 Status
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.up.arrow.down.circle.fill")
                                .font(.title)
                                .foregroundColor(viewModel.adapter2.isCANOpen ? .orange : .red)
                            Text("Adapter 2 (A2)")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(viewModel.adapter2.isCANOpen ? "Ready" : "Closed")
                                .font(.caption)
                                .foregroundColor(viewModel.adapter2.isCANOpen ? .green : .red)
                            if viewModel.adapter2.isCANOpen {
                                Text("TX: 0x201 / RX: 0x200")
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.1))
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
                    
                    Toggle("Use CAN FD", isOn: $viewModel.testUseFD)
                        .disabled(viewModel.isBidirTestRunning)
                    
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Message Size")
                            if viewModel.testUseFD {
                                Picker("Size", selection: $viewModel.testMessageSize) {
                                    Text("8").tag(8)
                                    Text("16").tag(16)
                                    Text("32").tag(32)
                                    Text("64").tag(64)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 250)
                            } else {
                                Picker("Size", selection: $viewModel.testMessageSize) {
                                    Text("1").tag(1)
                                    Text("4").tag(4)
                                    Text("8").tag(8)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 250)
                            }
                        }
                        .disabled(viewModel.isBidirTestRunning)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Burst Size")
                            Picker("Burst", selection: $viewModel.testBurstSize) {
                                Text("1").tag(1)
                                Text("2").tag(2)
                                Text("4").tag(4)
                                Text("6").tag(6)
                                Text("10").tag(10)
                                Text("50").tag(50)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 200)
                        }
                        .disabled(viewModel.isBidirTestRunning)
                        
                        Spacer()
                        Text(viewModel.testUseFD ? "CAN FD" : "Classic CAN")
                            .foregroundColor(viewModel.testUseFD ? .blue : .secondary)
                    }
                    
                    HStack {
                        Text("CAN IDs")
                        Spacer()
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Circle().fill(.blue).frame(width: 8, height: 8)
                                Text("A1: 0x200")
                                    .font(.system(.body, design: .monospaced))
                            }
                            HStack(spacing: 4) {
                                Circle().fill(.orange).frame(width: 8, height: 8)
                                Text("A2: 0x201")
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color.platformBackground)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .padding(.horizontal)
                
                // Control Buttons
                HStack(spacing: 16) {
                    if !viewModel.isBidirTestRunning {
                        Button {
                            viewModel.startBidirTest()
                        } label: {
                            Label("Start Bidirectional Stress Test", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(!viewModel.adapter1.isCANOpen || !viewModel.adapter2.isCANOpen)
                    } else {
                        Button {
                            viewModel.stopBidirTest()
                        } label: {
                            Label("Stop Test", systemImage: "stop.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    
                    Button {
                        viewModel.resetBidirStats()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isBidirTestRunning)
                }
                .padding(.horizontal)
                
                if !viewModel.adapter1.isCANOpen || !viewModel.adapter2.isCANOpen {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Both adapters must be connected and CAN channels open to run tests.")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }
                
                // Live Statistics — Two-column layout
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Live Statistics")
                            .font(.headline)
                        
                        Spacer()
                        
                        Text(String(format: "Duration: %.1f s", max(viewModel.bidirStats.a1toA2.duration, viewModel.bidirStats.a2toA1.duration)))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    
                    // Two-column: A1→A2 (blue) | A2→A1 (orange)
                    HStack(alignment: .top, spacing: 16) {
                        // Left column: A1 → A2
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 6) {
                                Circle().fill(.blue).frame(width: 10, height: 10)
                                Text("A1 → A2 (0x200)").font(.headline)
                            }
                            Divider()
                            BidirStatRow(label: "TX Rate", value: String(format: "%.0f msg/s", viewModel.bidirStats.a1toA2.instantTxRate), color: .primary)
                            BidirStatRow(label: "RX Rate", value: String(format: "%.0f msg/s", viewModel.bidirStats.a1toA2.instantRxRate), color: .primary)
                            let dr1 = viewModel.bidirStats.a1toA2.instantTxRate > 0 ? min((viewModel.bidirStats.a1toA2.instantRxRate / viewModel.bidirStats.a1toA2.instantTxRate) * 100, 100) : .zero
                            BidirStatRow(label: "Delivery", value: String(format: "%.1f%%", dr1), color: dr1 > 99 ? .green : .orange)
                            
                            Divider()
                            BidirStatRow(label: "Sent", value: "\(viewModel.bidirStats.a1toA2.messagesSent)", color: .secondary)
                            BidirStatRow(label: "Recv", value: "\(viewModel.bidirStats.a1toA2.messagesReceived)", color: .secondary)
                            
                            if viewModel.bidirStats.a1toA2.rxSequenceGaps > 0 {
                                BidirStatRow(label: "Seq Gaps", value: "\(viewModel.bidirStats.a1toA2.rxSequenceGaps)", color: .red)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(12)
                        
                        // Right column: A2 → A1
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 6) {
                                Circle().fill(.orange).frame(width: 10, height: 10)
                                Text("A2 → A1 (0x201)").font(.headline)
                            }
                            Divider()
                            BidirStatRow(label: "TX Rate", value: String(format: "%.0f msg/s", viewModel.bidirStats.a2toA1.instantTxRate), color: .primary)
                            BidirStatRow(label: "RX Rate", value: String(format: "%.0f msg/s", viewModel.bidirStats.a2toA1.instantRxRate), color: .primary)
                            let dr2 = viewModel.bidirStats.a2toA1.instantTxRate > 0 ? min((viewModel.bidirStats.a2toA1.instantRxRate / viewModel.bidirStats.a2toA1.instantTxRate) * 100, 100) : .zero
                            BidirStatRow(label: "Delivery", value: String(format: "%.1f%%", dr2), color: dr2 > 99 ? .green : .orange)
                            
                            Divider()
                            BidirStatRow(label: "Sent", value: "\(viewModel.bidirStats.a2toA1.messagesSent)", color: .secondary)
                            BidirStatRow(label: "Recv", value: "\(viewModel.bidirStats.a2toA1.messagesReceived)", color: .secondary)
                            
                            if viewModel.bidirStats.a2toA1.rxSequenceGaps > 0 {
                                BidirStatRow(label: "Seq Gaps", value: "\(viewModel.bidirStats.a2toA1.rxSequenceGaps)", color: .red)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange.opacity(0.05))
                        .cornerRadius(12)
                    }
                }
                .padding()
                .background(Color.platformBackground)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .padding(.horizontal)
                
                // Diagnostics (collapsible)
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup("Diagnostics") {
                        HStack(alignment: .top, spacing: 16) {
                            // Left column: A1 → A2 diagnostics
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Circle().fill(.blue).frame(width: 8, height: 8)
                                    Text("A1 → A2").font(.subheadline).fontWeight(.medium)
                                }
                                BidirStatRow(label: "RX Polls", value: "\(viewModel.bidirStats.a1toA2.rxPolls)", color: .secondary)
                                BidirStatRow(label: "RX Hits", value: "\(viewModel.bidirStats.a1toA2.rxHits)", color: viewModel.bidirStats.a1toA2.rxHits > 0 ? .green : .red)
                                BidirStatRow(label: "RX Raw Bytes", value: "\(viewModel.bidirStats.a1toA2.rxRawBytes)", color: .secondary)
                                BidirStatRow(label: "Decode Failures", value: "\(viewModel.bidirStats.a1toA2.rxDecodeFailures)", color: viewModel.bidirStats.a1toA2.rxDecodeFailures > 0 ? .red : .secondary)
                                BidirStatRow(label: "Bytes Sent", value: "\(viewModel.bidirStats.a1toA2.bytesSent)", color: .secondary)
                                BidirStatRow(label: "Bytes Recv", value: "\(viewModel.bidirStats.a1toA2.bytesReceived)", color: .secondary)
                                BidirStatRow(label: "Out of Order", value: "\(viewModel.bidirStats.a1toA2.rxOutOfOrder)", color: viewModel.bidirStats.a1toA2.rxOutOfOrder > 0 ? .orange : .secondary)
                                BidirStatRow(label: "Duplicates", value: "\(viewModel.bidirStats.a1toA2.rxDuplicates)", color: viewModel.bidirStats.a1toA2.rxDuplicates > 0 ? .orange : .secondary)
                                Divider()
                                Text("Driver (A2 RX)").font(.caption).foregroundColor(.secondary)
                                BidirStatRow(label: "ReadComplete", value: "\(viewModel.bidirStats.a1toA2.driverReadCompleteCount)", color: .secondary)
                                BidirStatRow(label: "USB IN Bytes", value: "\(viewModel.bidirStats.a1toA2.driverReadCompleteBytes)", color: .secondary)
                                BidirStatRow(label: "Submit Fail", value: "\(viewModel.bidirStats.a1toA2.driverReadSubmitFailures)", color: viewModel.bidirStats.a1toA2.driverReadSubmitFailures > 0 ? .red : .secondary)
                                BidirStatRow(label: "RX Slots InFlight", value: "\(viewModel.bidirStats.a1toA2.driverRxSlotsInFlight)", color: viewModel.bidirStats.a1toA2.driverRxSlotsInFlight > 0 ? .green : .red)
                                BidirStatRow(label: "TX Busy", value: "\(viewModel.bidirStats.a1toA2.driverTxBusyCount)", color: .secondary)
                                BidirStatRow(label: "Chain Restarts", value: "\(viewModel.bidirStats.a1toA2.driverReadChainRestarts)", color: viewModel.bidirStats.a1toA2.driverReadChainRestarts > 0 ? .orange : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue.opacity(0.05))
                            .cornerRadius(12)

                            // Right column: A2 → A1 diagnostics
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Circle().fill(.orange).frame(width: 8, height: 8)
                                    Text("A2 → A1").font(.subheadline).fontWeight(.medium)
                                }
                                BidirStatRow(label: "RX Polls", value: "\(viewModel.bidirStats.a2toA1.rxPolls)", color: .secondary)
                                BidirStatRow(label: "RX Hits", value: "\(viewModel.bidirStats.a2toA1.rxHits)", color: viewModel.bidirStats.a2toA1.rxHits > 0 ? .green : .red)
                                BidirStatRow(label: "RX Raw Bytes", value: "\(viewModel.bidirStats.a2toA1.rxRawBytes)", color: .secondary)
                                BidirStatRow(label: "Decode Failures", value: "\(viewModel.bidirStats.a2toA1.rxDecodeFailures)", color: viewModel.bidirStats.a2toA1.rxDecodeFailures > 0 ? .red : .secondary)
                                BidirStatRow(label: "Bytes Sent", value: "\(viewModel.bidirStats.a2toA1.bytesSent)", color: .secondary)
                                BidirStatRow(label: "Bytes Recv", value: "\(viewModel.bidirStats.a2toA1.bytesReceived)", color: .secondary)
                                BidirStatRow(label: "Out of Order", value: "\(viewModel.bidirStats.a2toA1.rxOutOfOrder)", color: viewModel.bidirStats.a2toA1.rxOutOfOrder > 0 ? .orange : .secondary)
                                BidirStatRow(label: "Duplicates", value: "\(viewModel.bidirStats.a2toA1.rxDuplicates)", color: viewModel.bidirStats.a2toA1.rxDuplicates > 0 ? .orange : .secondary)
                                Divider()
                                Text("Driver (A1 RX)").font(.caption).foregroundColor(.secondary)
                                BidirStatRow(label: "ReadComplete", value: "\(viewModel.bidirStats.a2toA1.driverReadCompleteCount)", color: .secondary)
                                BidirStatRow(label: "USB IN Bytes", value: "\(viewModel.bidirStats.a2toA1.driverReadCompleteBytes)", color: .secondary)
                                BidirStatRow(label: "Submit Fail", value: "\(viewModel.bidirStats.a2toA1.driverReadSubmitFailures)", color: viewModel.bidirStats.a2toA1.driverReadSubmitFailures > 0 ? .red : .secondary)
                                BidirStatRow(label: "RX Slots InFlight", value: "\(viewModel.bidirStats.a2toA1.driverRxSlotsInFlight)", color: viewModel.bidirStats.a2toA1.driverRxSlotsInFlight > 0 ? .green : .red)
                                BidirStatRow(label: "TX Busy", value: "\(viewModel.bidirStats.a2toA1.driverTxBusyCount)", color: .secondary)
                                BidirStatRow(label: "Chain Restarts", value: "\(viewModel.bidirStats.a2toA1.driverReadChainRestarts)", color: viewModel.bidirStats.a2toA1.driverReadChainRestarts > 0 ? .orange : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.orange.opacity(0.05))
                            .cornerRadius(12)
                        }
                    }
                    .font(.headline)
                }
                .padding()
                .background(Color.platformBackground)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .padding(.horizontal)

                // Throughput Chart
                if !viewModel.bidirHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Throughput Over Time")
                            .font(.headline)
                        
                        Chart {
                            ForEach(viewModel.bidirHistory) { point in
                                LineMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("A1→A2 RX", point.rxRateA1),
                                    series: .value("Direction", "A1→A2")
                                )
                                .foregroundStyle(.blue)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                                
                                LineMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("A2→A1 RX", point.rxRateA2),
                                    series: .value("Direction", "A2→A1")
                                )
                                .foregroundStyle(.orange)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                            }
                        }
                        .chartXAxis(.hidden)
                        .chartForegroundStyleScale([
                            "A1→A2": Color.blue,
                            "A2→A1": Color.orange
                        ])
                        .chartLegend(position: .bottom)
                        .chartYAxisLabel("msg/s")
                        .frame(height: 200)
                    }
                    .padding()
                    .background(Color.platformBackground)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                    .padding(.horizontal)
                }
                
                Spacer(minLength: 20)
            }
            .padding(.top, 16)
        }
    }
}

// Bidir Stat Row
struct BidirStatRow: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(color)
        }
    }
}
