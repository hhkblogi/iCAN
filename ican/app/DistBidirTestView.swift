import SwiftUI
import Charts

struct DistBidirTestView: View {
    @ObservedObject var viewModel: CANDashboardViewModel

    private var txCanIdHex: String {
        viewModel.distBidirRole == 0 ? "0x200" : "0x201"
    }
    private var rxCanIdHex: String {
        viewModel.distBidirRole == 0 ? "0x201" : "0x200"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Role Picker
                VStack(alignment: .leading, spacing: 16) {
                    Text("Device Role")
                        .font(.headline)

                    Picker("Role", selection: $viewModel.distBidirRole) {
                        Text("iPad 1 (TX: 0x200)").tag(0)
                        Text("iPad 2 (TX: 0x201)").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .disabled(viewModel.isDistBidirTestRunning)

                    Text("Each iPad uses one adapter. Pick opposite roles on each device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.platformBackground)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .padding(.horizontal)

                // Adapter Status Card
                VStack(alignment: .leading, spacing: 16) {
                    Text("Adapter Status")
                        .font(.headline)

                    VStack(spacing: 8) {
                        Image(systemName: "arrow.up.arrow.down.circle.fill")
                            .font(.title)
                            .foregroundColor(viewModel.adapter1.isCANOpen ? .green : .red)
                        Text("Adapter 1")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(viewModel.adapter1.isCANOpen ? "Ready" : (viewModel.adapter1.isConnected ? "Connected (CAN Closed)" : "Disconnected"))
                            .font(.caption)
                            .foregroundColor(viewModel.adapter1.isCANOpen ? .green : .red)
                        if viewModel.adapter1.isCANOpen {
                            Text("TX: \(txCanIdHex) / RX: \(rxCanIdHex)")
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
                        .disabled(viewModel.isDistBidirTestRunning)

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
                        .disabled(viewModel.isDistBidirTestRunning)

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
                        }
                        .disabled(viewModel.isDistBidirTestRunning)

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
                                Text("TX: \(txCanIdHex)")
                                    .font(.system(.body, design: .monospaced))
                            }
                            HStack(spacing: 4) {
                                Circle().fill(.green).frame(width: 8, height: 8)
                                Text("RX: \(rxCanIdHex)")
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
                    if !viewModel.isDistBidirTestRunning {
                        Button {
                            viewModel.startDistBidirTest()
                        } label: {
                            Label("Start Distributed Test", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(!viewModel.adapter1.isCANOpen)
                    } else {
                        Button {
                            viewModel.stopDistBidirTest()
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
                        viewModel.resetDistBidirStats()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isDistBidirTestRunning)
                }
                .padding(.horizontal)

                if !viewModel.adapter1.isCANOpen {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Adapter 1 must be connected and CAN channel open to run this test.")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }

                // Live Statistics
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Live Statistics")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "Duration: %.1f s", viewModel.distBidirStats.duration))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        BidirStatRow(label: "TX Rate", value: String(format: "%.0f msg/s", viewModel.distBidirStats.instantTxRate), color: .primary)
                        BidirStatRow(label: "RX Rate", value: String(format: "%.0f msg/s", viewModel.distBidirStats.instantRxRate), color: .primary)
                        let delivery = viewModel.distBidirStats.instantTxRate > 0
                            ? min((viewModel.distBidirStats.instantRxRate / viewModel.distBidirStats.instantTxRate) * 100, 100) : .zero
                        BidirStatRow(label: "Delivery", value: String(format: "%.1f%%", delivery), color: delivery > 99 ? .green : .orange)

                        Divider()
                        BidirStatRow(label: "Sent", value: "\(viewModel.distBidirStats.messagesSent)", color: .secondary)
                        BidirStatRow(label: "Recv", value: "\(viewModel.distBidirStats.messagesReceived)", color: .secondary)

                        if viewModel.distBidirStats.rxSequenceGaps > 0 {
                            BidirStatRow(label: "Seq Gaps", value: "\(viewModel.distBidirStats.rxSequenceGaps)", color: .red)
                        }
                    }
                    .padding()
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(12)
                }
                .padding()
                .background(Color.platformBackground)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .padding(.horizontal)

                // Diagnostics (collapsible)
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup("Diagnostics") {
                        VStack(alignment: .leading, spacing: 8) {
                            BidirStatRow(label: "RX Polls", value: "\(viewModel.distBidirStats.rxPolls)", color: .secondary)
                            BidirStatRow(label: "RX Hits", value: "\(viewModel.distBidirStats.rxHits)", color: viewModel.distBidirStats.rxHits > 0 ? .green : .red)
                            BidirStatRow(label: "RX Raw Bytes", value: "\(viewModel.distBidirStats.rxRawBytes)", color: .secondary)
                            BidirStatRow(label: "Decode Failures", value: "\(viewModel.distBidirStats.rxDecodeFailures)", color: viewModel.distBidirStats.rxDecodeFailures > 0 ? .red : .secondary)
                            BidirStatRow(label: "Bytes Sent", value: "\(viewModel.distBidirStats.bytesSent)", color: .secondary)
                            BidirStatRow(label: "Bytes Recv", value: "\(viewModel.distBidirStats.bytesReceived)", color: .secondary)
                            BidirStatRow(label: "Out of Order", value: "\(viewModel.distBidirStats.rxOutOfOrder)", color: viewModel.distBidirStats.rxOutOfOrder > 0 ? .orange : .secondary)
                            BidirStatRow(label: "Duplicates", value: "\(viewModel.distBidirStats.rxDuplicates)", color: viewModel.distBidirStats.rxDuplicates > 0 ? .orange : .secondary)
                            Divider()
                            Text("Driver").font(.caption).foregroundColor(.secondary)
                            BidirStatRow(label: "ReadComplete", value: "\(viewModel.distBidirStats.driverReadCompleteCount)", color: .secondary)
                            BidirStatRow(label: "USB IN Bytes", value: "\(viewModel.distBidirStats.driverReadCompleteBytes)", color: .secondary)
                            BidirStatRow(label: "Submit Fail", value: "\(viewModel.distBidirStats.driverReadSubmitFailures)", color: viewModel.distBidirStats.driverReadSubmitFailures > 0 ? .red : .secondary)
                            BidirStatRow(label: "RX Slots InFlight", value: "\(viewModel.distBidirStats.driverRxSlotsInFlight)", color: viewModel.distBidirStats.driverRxSlotsInFlight > 0 ? .green : .red)
                            BidirStatRow(label: "TX Busy", value: "\(viewModel.distBidirStats.driverTxBusyCount)", color: .secondary)
                            BidirStatRow(label: "Chain Restarts", value: "\(viewModel.distBidirStats.driverReadChainRestarts)", color: viewModel.distBidirStats.driverReadChainRestarts > 0 ? .orange : .secondary)
                        }
                        .padding()
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(12)
                    }
                    .font(.headline)
                }
                .padding()
                .background(Color.platformBackground)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .padding(.horizontal)

                // Throughput Chart
                if !viewModel.distBidirHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Throughput Over Time")
                            .font(.headline)

                        Chart {
                            ForEach(viewModel.distBidirHistory) { point in
                                LineMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("TX", point.txRate),
                                    series: .value("Direction", "TX")
                                )
                                .foregroundStyle(.blue)
                                .lineStyle(StrokeStyle(lineWidth: 2))

                                LineMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("RX", point.rxRate),
                                    series: .value("Direction", "RX")
                                )
                                .foregroundStyle(.green)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                            }
                        }
                        .chartXAxis(.hidden)
                        .chartForegroundStyleScale([
                            "TX": Color.blue,
                            "RX": Color.green
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
