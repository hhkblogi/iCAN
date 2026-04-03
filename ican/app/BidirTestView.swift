import SwiftUI
import Charts

struct BidirTestView: View {
    @ObservedObject var viewModel: CANDashboardViewModel

    private var interfaceAIsOpen: Bool { viewModel.bidirAdapterA?.isCANOpen ?? false }
    private var interfaceBIsOpen: Bool { viewModel.bidirAdapterB?.isCANOpen ?? false }

    private func codecForAdapter(_ adapter: SerialAdapter?) -> String {
        guard let adapter = adapter,
              let iface = viewModel.availableInterfaces.first(where: { $0.id == adapter.selectedPort })
        else { return "" }
        return iface.codec
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Test Description
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bidirectional Test")
                        .font(.headline)
                    Text("Measures bidirectional throughput between two CAN interfaces. Both interfaces simultaneously transmit and receive frames on the shared CAN bus, testing concurrent TX/RX performance and delivery reliability under arbitration.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.platformBackground)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .padding(.horizontal)

                // Interface Selection + Status
                VStack(alignment: .leading, spacing: 16) {
                    Text("Test Setup")
                        .font(.headline)

                    HStack(spacing: 16) {
                        // Interface A
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("Interface A")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Image(systemName: "arrow.up.arrow.down.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(interfaceAIsOpen ? .blue : .secondary)
                                Picker("", selection: $viewModel.bidirInterfaceAIndex) {
                                    Text("— Select —").tag(-1)
                                    ForEach(Array(viewModel.adapters.enumerated()), id: \.offset) { idx, adapter in
                                        if adapter.isCANOpen && idx != viewModel.bidirInterfaceBIndex {
                                            Text(adapter.name).tag(idx)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .disabled(viewModel.anyTestRunning)
                                Spacer()
                            }
                            if let adapterA = viewModel.bidirAdapterA, adapterA.isCANOpen {
                                InterfaceConfigLabel(adapter: adapterA)
                                RatePicker(
                                    label: "TX Loop Rate (Hz)",
                                    selection: $viewModel.bidirTargetRateA,
                                    disabled: viewModel.anyTestRunning
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color.platformSecondaryBackground)
                        .cornerRadius(10)

                        // Bidirectional Arrows
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right")
                                .foregroundColor(.blue)
                            Image(systemName: "arrow.left")
                                .foregroundColor(.orange)
                        }
                        .font(.subheadline)

                        // Interface B
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("Interface B")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Image(systemName: "arrow.up.arrow.down.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(interfaceBIsOpen ? .orange : .secondary)
                                Picker("", selection: $viewModel.bidirInterfaceBIndex) {
                                    Text("— Select —").tag(-1)
                                    ForEach(Array(viewModel.adapters.enumerated()), id: \.offset) { idx, adapter in
                                        if adapter.isCANOpen && idx != viewModel.bidirInterfaceAIndex {
                                            Text(adapter.name).tag(idx)
                                        }
                                    }
                                }
                                .pickerStyle(.menu)
                                .disabled(viewModel.anyTestRunning)
                                Spacer()
                            }
                            if let adapterB = viewModel.bidirAdapterB, adapterB.isCANOpen {
                                InterfaceConfigLabel(adapter: adapterB)
                                RatePicker(
                                    label: "TX Loop Rate (Hz)",
                                    selection: $viewModel.bidirTargetRateB,
                                    disabled: viewModel.anyTestRunning
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity)
                        .background(Color.platformSecondaryBackground)
                        .cornerRadius(10)
                    }

                    // CAN ID assignments — aligned with interface blocks
                    if interfaceAIsOpen && interfaceBIsOpen {
                        let nameA = viewModel.bidirAdapterA?.name ?? "A"
                        let nameB = viewModel.bidirAdapterB?.name ?? "B"
                        HStack(spacing: 16) {
                            // A → B info, aligned with Interface A block
                            HStack(spacing: 4) {
                                Text("\(nameA) → \(nameB)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                                Text("TX CAN ID: 0x200")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)

                            // Spacer matching the arrows column
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.right").opacity(0)
                                Image(systemName: "arrow.left").opacity(0)
                            }
                            .font(.subheadline)

                            // B → A info, aligned with Interface B block
                            HStack(spacing: 4) {
                                Text("\(nameB) → \(nameA)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.orange)
                                Text("TX CAN ID: 0x201")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding()
                .background(Color.platformBackground)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .padding(.horizontal)


                // Control Button
                if !viewModel.isBidirTestRunning {
                    Button {
                        viewModel.startBidirTest()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!viewModel.bothBidirAdaptersReady || viewModel.anyTestRunning)
                    .padding(.horizontal)
                } else {
                    Button {
                        viewModel.stopBidirTest()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.horizontal)
                }

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

                    // Two-column: A→B (blue) | B→A (orange)
                    HStack(alignment: .top, spacing: 16) {
                        // Left column: A → B
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 6) {
                                Circle().fill(.blue).frame(width: 10, height: 10)
                                Text("A → B (0x200)").font(.headline)
                            }
                            Divider()
                            BidirStatRow(label: "TX Rate", value: String(format: "%.0f msg/s", viewModel.bidirStats.a1toA2.instantTxRate), color: .primary)
                            BidirStatRow(label: "RX Rate", value: String(format: "%.0f msg/s", viewModel.bidirStats.a1toA2.instantRxRate), color: .primary)
                            let dr1 = viewModel.bidirStats.a1toA2.instantTxRate > 0 ? min((viewModel.bidirStats.a1toA2.instantRxRate / viewModel.bidirStats.a1toA2.instantTxRate) * 100, 100) : .zero
                            BidirStatRow(label: "Delivery", value: String(format: "%.1f%%", dr1), color: dr1 > 99 ? .green : .orange)
                            BidirStatRow(label: "Sent", value: "\(viewModel.bidirStats.a1toA2.messagesSent)", color: .secondary)
                            BidirStatRow(label: "Recv", value: "\(viewModel.bidirStats.a1toA2.messagesReceived)", color: .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(12)

                        // Right column: B → A
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 6) {
                                Circle().fill(.orange).frame(width: 10, height: 10)
                                Text("B → A (0x201)").font(.headline)
                            }
                            Divider()
                            BidirStatRow(label: "TX Rate", value: String(format: "%.0f msg/s", viewModel.bidirStats.a2toA1.instantTxRate), color: .primary)
                            BidirStatRow(label: "RX Rate", value: String(format: "%.0f msg/s", viewModel.bidirStats.a2toA1.instantRxRate), color: .primary)
                            let dr2 = viewModel.bidirStats.a2toA1.instantTxRate > 0 ? min((viewModel.bidirStats.a2toA1.instantRxRate / viewModel.bidirStats.a2toA1.instantTxRate) * 100, 100) : .zero
                            BidirStatRow(label: "Delivery", value: String(format: "%.1f%%", dr2), color: dr2 > 99 ? .green : .orange)
                            BidirStatRow(label: "Sent", value: "\(viewModel.bidirStats.a2toA1.messagesSent)", color: .secondary)
                            BidirStatRow(label: "Recv", value: "\(viewModel.bidirStats.a2toA1.messagesReceived)", color: .secondary)
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

                // Diagnostics — table layout
                VStack(alignment: .leading, spacing: 8) {
                    Text("Diagnostics")
                        .font(.headline)

                    let s1 = viewModel.bidirStats.a1toA2
                    let s2 = viewModel.bidirStats.a2toA1
                    let cd1 = s1.messagesSent > 0 ? min(Double(s1.messagesReceived) / Double(s1.messagesSent) * 100, 100) : 0
                    let cd2 = s2.messagesSent > 0 ? min(Double(s2.messagesReceived) / Double(s2.messagesSent) * 100, 100) : 0

                    // Header
                    DiagRow(label: "", valA: "A → B", valB: "B → A", header: true)
                    Divider()

                    // Delivery
                    DiagRow(label: "Cumul Delivery", valA: String(format: "%.2f%%", cd1), valB: String(format: "%.2f%%", cd2),
                            colorA: cd1 > 99.9 ? .green : .orange, colorB: cd2 > 99.9 ? .green : .orange)
                    DiagRow(label: "Seq Gaps", valA: "\(s1.rxSequenceGaps)", valB: "\(s2.rxSequenceGaps)",
                            colorA: s1.rxSequenceGaps > 0 ? .red : .secondary, colorB: s2.rxSequenceGaps > 0 ? .red : .secondary)
                    Divider()

                    // IPC
                    DiagRow(label: "RX Polls", valA: "\(s1.rxPolls)", valB: "\(s2.rxPolls)")
                    DiagRow(label: "RX Hits", valA: "\(s1.rxHits)", valB: "\(s2.rxHits)",
                            colorA: s1.rxHits > 0 ? .green : .red, colorB: s2.rxHits > 0 ? .green : .red)
                    DiagRow(label: "RX Raw Bytes", valA: "\(s1.rxRawBytes)", valB: "\(s2.rxRawBytes)")
                    DiagRow(label: "Decode Failures", valA: "\(s1.rxDecodeFailures)", valB: "\(s2.rxDecodeFailures)",
                            colorA: s1.rxDecodeFailures > 0 ? .red : .secondary, colorB: s2.rxDecodeFailures > 0 ? .red : .secondary)
                    DiagRow(label: "Bytes Sent", valA: "\(s1.bytesSent)", valB: "\(s2.bytesSent)")
                    DiagRow(label: "Bytes Recv", valA: "\(s1.bytesReceived)", valB: "\(s2.bytesReceived)")
                    DiagRow(label: "Out of Order", valA: "\(s1.rxOutOfOrder)", valB: "\(s2.rxOutOfOrder)",
                            colorA: s1.rxOutOfOrder > 0 ? .orange : .secondary, colorB: s2.rxOutOfOrder > 0 ? .orange : .secondary)
                    DiagRow(label: "Duplicates", valA: "\(s1.rxDuplicates)", valB: "\(s2.rxDuplicates)",
                            colorA: s1.rxDuplicates > 0 ? .orange : .secondary, colorB: s2.rxDuplicates > 0 ? .orange : .secondary)
                    Divider()

                    // Driver
                    DiagRow(label: "ReadComplete", valA: "\(s1.driverReadCompleteCount)", valB: "\(s2.driverReadCompleteCount)")
                    DiagRow(label: "USB IN Bytes", valA: "\(s1.driverReadCompleteBytes)", valB: "\(s2.driverReadCompleteBytes)")
                    DiagRow(label: "Submit Fail", valA: "\(s1.driverReadSubmitFailures)", valB: "\(s2.driverReadSubmitFailures)",
                            colorA: s1.driverReadSubmitFailures > 0 ? .red : .secondary, colorB: s2.driverReadSubmitFailures > 0 ? .red : .secondary)
                    DiagRow(label: "RX Slots InFlight", valA: "\(s1.driverRxSlotsInFlight)", valB: "\(s2.driverRxSlotsInFlight)",
                            colorA: s1.driverRxSlotsInFlight > 0 ? .green : .red, colorB: s2.driverRxSlotsInFlight > 0 ? .green : .red)
                    DiagRow(label: "TX Busy", valA: "\(s1.driverTxBusyCount)", valB: "\(s2.driverTxBusyCount)")
                    DiagRow(label: "Chain Restarts", valA: "\(s1.driverReadChainRestarts)", valB: "\(s2.driverReadChainRestarts)",
                            colorA: s1.driverReadChainRestarts > 0 ? .orange : .secondary, colorB: s2.driverReadChainRestarts > 0 ? .orange : .secondary)
                    DiagRow(label: "Ring RX Drop", valA: "\(s1.ringRxDropped)", valB: "\(s2.ringRxDropped)",
                            colorA: s1.ringRxDropped > 0 ? .red : .secondary, colorB: s2.ringRxDropped > 0 ? .red : .secondary)

                    // Codec-specific (per-interface)
                    let codecA = codecForAdapter(viewModel.bidirAdapterA)
                    let codecB = codecForAdapter(viewModel.bidirAdapterB)
                    Divider()
                    DiagRow(label: "Codec", valA: codecA, valB: codecB, header: true)
                    if codecA == "pcan" || codecB == "pcan" {
                        DiagRow(label: "TX Echoes",
                                valA: codecA == "pcan" ? "\(s1.codecEchoCount)" : "—",
                                valB: codecB == "pcan" ? "\(s2.codecEchoCount)" : "—",
                                colorA: s1.codecEchoCount > 0 ? .blue : .secondary,
                                colorB: s2.codecEchoCount > 0 ? .blue : .secondary)
                        DiagRow(label: "FW Overruns",
                                valA: codecA == "pcan" ? "\(s1.codecOverrunCount)" : "—",
                                valB: codecB == "pcan" ? "\(s2.codecOverrunCount)" : "—",
                                colorA: s1.codecOverrunCount > 0 ? .red : .secondary,
                                colorB: s2.codecOverrunCount > 0 ? .red : .secondary)
                        DiagRow(label: "Truncated",
                                valA: codecA == "pcan" ? "\(s1.codecTruncatedCount)" : "—",
                                valB: codecB == "pcan" ? "\(s2.codecTruncatedCount)" : "—",
                                colorA: s1.codecTruncatedCount > 0 ? .orange : .secondary,
                                colorB: s2.codecTruncatedCount > 0 ? .orange : .secondary)
                        DiagRow(label: "Zero Sentinel",
                                valA: codecA == "pcan" ? "\(s1.codecZeroSentinelCount)" : "—",
                                valB: codecB == "pcan" ? "\(s2.codecZeroSentinelCount)" : "—")
                    }
                    if codecA == "gs_usb" || codecB == "gs_usb" {
                        DiagRow(label: "Echo Frames",
                                valA: codecA == "gs_usb" ? "\(s1.codecEchoCount)" : "—",
                                valB: codecB == "gs_usb" ? "\(s2.codecEchoCount)" : "—",
                                colorA: s1.codecEchoCount > 0 ? .blue : .secondary,
                                colorB: s2.codecEchoCount > 0 ? .blue : .secondary)
                    }
                }
                .padding()
                .background(Color.platformBackground)
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
                .padding(.horizontal)

                Spacer(minLength: 20)
            }
            .padding(.top, 16)
        }
    }
}

// Diagnostics table row: label | A→B value | B→A value
struct DiagRow: View {
    let label: String
    let valA: String
    let valB: String
    var colorA: Color = .secondary
    var colorB: Color = .secondary
    var header: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(header ? .caption.bold() : .caption)
                .foregroundColor(header ? .primary : .secondary)
                .frame(width: 140, alignment: .leading)
            Text(valA)
                .font(.system(header ? .caption : .caption, design: .monospaced))
                .fontWeight(header ? .bold : .medium)
                .foregroundColor(header ? .blue : colorA)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(valB)
                .font(.system(header ? .caption : .caption, design: .monospaced))
                .fontWeight(header ? .bold : .medium)
                .foregroundColor(header ? .orange : colorB)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 2)
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
