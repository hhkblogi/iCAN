import SwiftUI
import Charts

struct BidirTestView: View {
    @ObservedObject var viewModel: CANDashboardViewModel

    private var interfaceAIsOpen: Bool { viewModel.bidirAdapterA?.isCANOpen ?? false }
    private var interfaceBIsOpen: Bool { viewModel.bidirAdapterB?.isCANOpen ?? false }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Interface Selection + Status
                VStack(alignment: .leading, spacing: 16) {
                    Text("Interface Selection")
                        .font(.headline)

                    HStack(spacing: 20) {
                        // Interface A
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.up.arrow.down.circle.fill")
                                .font(.title)
                                .foregroundColor(interfaceAIsOpen ? .blue : .red)
                            Picker("Interface A", selection: $viewModel.bidirInterfaceAIndex) {
                                ForEach(Array(viewModel.adapters.enumerated()), id: \.offset) { idx, adapter in
                                    Text(adapter.name).tag(idx)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(viewModel.anyTestRunning)
                            Text(interfaceAIsOpen ? "Ready" : "Not Open")
                                .font(.caption)
                                .foregroundColor(interfaceAIsOpen ? .green : .red)
                            if interfaceAIsOpen {
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

                        // Interface B
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.up.arrow.down.circle.fill")
                                .font(.title)
                                .foregroundColor(interfaceBIsOpen ? .orange : .red)
                            Picker("Interface B", selection: $viewModel.bidirInterfaceBIndex) {
                                ForEach(Array(viewModel.adapters.enumerated()), id: \.offset) { idx, adapter in
                                    Text(adapter.name).tag(idx)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(viewModel.anyTestRunning)
                            Text(interfaceBIsOpen ? "Ready" : "Not Open")
                                .font(.caption)
                                .foregroundColor(interfaceBIsOpen ? .green : .red)
                            if interfaceBIsOpen {
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
                            Text("Target Rate (msg/s)")
                            Picker("Rate", selection: $viewModel.testTargetRate) {
                                Text("1").tag(1)
                                Text("10").tag(10)
                                Text("100").tag(100)
                                Text("1K").tag(1000)
                                Text("2K").tag(2000)
                                Text("3K").tag(3000)
                                Text("4K").tag(4000)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 400)
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
                        .disabled(!viewModel.bothBidirAdaptersReady || viewModel.anyTestRunning)
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

                if viewModel.adapters.count < 2 {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("At least two CAN interfaces are required for this test.")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
                } else if viewModel.bidirInterfaceAIndex == viewModel.bidirInterfaceBIndex {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("Interface A and B must be different.")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
                } else if !viewModel.bothBidirAdaptersReady {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Both interfaces must have CAN channels open.")
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
                            let cd1 = viewModel.bidirStats.a1toA2.messagesSent > 0 ? min(Double(viewModel.bidirStats.a1toA2.messagesReceived) / Double(viewModel.bidirStats.a1toA2.messagesSent) * 100, 100) : .zero
                            BidirStatRow(label: "Cumul Delivery", value: String(format: "%.2f%%", cd1), color: cd1 > 99.9 ? .green : .orange)

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
                            let cd2 = viewModel.bidirStats.a2toA1.messagesSent > 0 ? min(Double(viewModel.bidirStats.a2toA1.messagesReceived) / Double(viewModel.bidirStats.a2toA1.messagesSent) * 100, 100) : .zero
                            BidirStatRow(label: "Cumul Delivery", value: String(format: "%.2f%%", cd2), color: cd2 > 99.9 ? .green : .orange)

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
                                Divider()
                                Text("PCAN Codec").font(.caption).foregroundColor(.secondary)
                                BidirStatRow(label: "TX Echoes", value: "\(viewModel.bidirStats.a1toA2.codecEchoCount)", color: viewModel.bidirStats.a1toA2.codecEchoCount > 0 ? .blue : .secondary)
                                BidirStatRow(label: "FW Overruns", value: "\(viewModel.bidirStats.a1toA2.codecOverrunCount)", color: viewModel.bidirStats.a1toA2.codecOverrunCount > 0 ? .red : .secondary)
                                BidirStatRow(label: "Truncated", value: "\(viewModel.bidirStats.a1toA2.codecTruncatedCount)", color: viewModel.bidirStats.a1toA2.codecTruncatedCount > 0 ? .orange : .secondary)
                                BidirStatRow(label: "Zero Sentinel", value: "\(viewModel.bidirStats.a1toA2.codecZeroSentinelCount)", color: .secondary)
                                BidirStatRow(label: "Ring RX Drop", value: "\(viewModel.bidirStats.a1toA2.ringRxDropped)", color: viewModel.bidirStats.a1toA2.ringRxDropped > 0 ? .red : .secondary)
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
                                Divider()
                                Text("PCAN Codec").font(.caption).foregroundColor(.secondary)
                                BidirStatRow(label: "TX Echoes", value: "\(viewModel.bidirStats.a2toA1.codecEchoCount)", color: viewModel.bidirStats.a2toA1.codecEchoCount > 0 ? .blue : .secondary)
                                BidirStatRow(label: "FW Overruns", value: "\(viewModel.bidirStats.a2toA1.codecOverrunCount)", color: viewModel.bidirStats.a2toA1.codecOverrunCount > 0 ? .red : .secondary)
                                BidirStatRow(label: "Truncated", value: "\(viewModel.bidirStats.a2toA1.codecTruncatedCount)", color: viewModel.bidirStats.a2toA1.codecTruncatedCount > 0 ? .orange : .secondary)
                                BidirStatRow(label: "Zero Sentinel", value: "\(viewModel.bidirStats.a2toA1.codecZeroSentinelCount)", color: .secondary)
                                BidirStatRow(label: "Ring RX Drop", value: "\(viewModel.bidirStats.a2toA1.ringRxDropped)", color: viewModel.bidirStats.a2toA1.ringRxDropped > 0 ? .red : .secondary)
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

                // Raw USB Transfer Debug
                VStack(alignment: .leading, spacing: 12) {
                    DisclosureGroup("Raw USB Transfer (Live)") {
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Circle().fill(.blue).frame(width: 8, height: 8)
                                    Text("A2 RX (for A1→A2)").font(.subheadline).fontWeight(.medium)
                                }
                                Text("Transfer #\(viewModel.bidirStats.a1toA2.dbgTransferSeq)  len=\(viewModel.bidirStats.a1toA2.dbgTransferLen)  msgs=\(viewModel.bidirStats.a1toA2.dbgMsgsParsed)")
                                    .font(.system(.caption, design: .monospaced))
                                Text(viewModel.bidirStats.a1toA2.dbgHeadHex)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.blue.opacity(0.05))
                            .cornerRadius(8)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Circle().fill(.orange).frame(width: 8, height: 8)
                                    Text("A1 RX (for A2→A1)").font(.subheadline).fontWeight(.medium)
                                }
                                Text("Transfer #\(viewModel.bidirStats.a2toA1.dbgTransferSeq)  len=\(viewModel.bidirStats.a2toA1.dbgTransferLen)  msgs=\(viewModel.bidirStats.a2toA1.dbgMsgsParsed)")
                                    .font(.system(.caption, design: .monospaced))
                                Text(viewModel.bidirStats.a2toA1.dbgHeadHex)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.orange.opacity(0.05))
                            .cornerRadius(8)
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
