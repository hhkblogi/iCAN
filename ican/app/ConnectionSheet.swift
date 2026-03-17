import SwiftUI

struct PortsView: View {
    @ObservedObject var viewModel: CANDashboardViewModel

    var body: some View {
        Form {
            if viewModel.usbAdapters.isEmpty {
                Section("USB Adapters") {
                    HStack {
                        Image(systemName: "cable.connector.slash")
                            .foregroundColor(.secondary)
                        Text("No USB CAN adapters detected")
                            .foregroundColor(.secondary)
                    }
                    Button("Refresh") { viewModel.refreshPorts() }
                        .font(.caption)
                }
            } else {
                ForEach(viewModel.usbAdapters) { adapter in
                    Section("USB Adapter \(adapter.deviceIndex): \(adapter.name)") {
                        ForEach(adapter.interfaces) { iface in
                            InterfaceSection(
                                iface: iface,
                                adapter: adapterFor(iface),
                                onConnect: { viewModel.connectAdapter(adapterFor(iface)) },
                                onOpenCAN: { viewModel.openCANChannel(for: adapterFor(iface)) },
                                onCloseCAN: { viewModel.closeCANChannel(for: adapterFor(iface)) }
                            )
                        }
                        Button("Refresh") { viewModel.refreshPorts() }
                            .font(.caption)
                    }
                }
            }

            // Diagnostic Section
            Section("Driver Diagnostics") {
                DiagnosticView()
            }
        }
    }

    private func adapterFor(_ iface: CANInterface) -> SerialAdapter {
        // Match by current selection or assign
        if viewModel.adapter1.selectedPort == iface.id ||
           (!viewModel.adapter1.isConnected && viewModel.adapter2.selectedPort != iface.id) {
            if viewModel.adapter1.selectedPort != iface.id {
                viewModel.adapter1.selectedPort = iface.id
                viewModel.adapter1.adapterIndex = iface.deviceIndex
                viewModel.adapter1.channel = iface.channel
            }
            return viewModel.adapter1
        } else {
            if viewModel.adapter2.selectedPort != iface.id {
                viewModel.adapter2.selectedPort = iface.id
                viewModel.adapter2.adapterIndex = iface.deviceIndex
                viewModel.adapter2.channel = iface.channel
            }
            return viewModel.adapter2
        }
    }
}

// Per-interface section within a USB adapter
struct InterfaceSection: View {
    let iface: CANInterface
    @ObservedObject var adapter: SerialAdapter
    let onConnect: () -> Void
    let onOpenCAN: () -> Void
    let onCloseCAN: () -> Void

    var body: some View {
        // Interface header
        HStack {
            Text(iface.interfaceName)
                .font(.headline)
                .monospaced()
            Text("(\(iface.codec))")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            if adapter.isConnecting {
                ProgressView()
                    .frame(width: 10, height: 10)
                Text("Connecting...")
                    .foregroundColor(.orange)
                    .font(.caption)
            } else if adapter.isConnected {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Connected")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("Disconnected")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }

        if !adapter.isConnected {
            Button("Connect") { onConnect() }
                .buttonStyle(.borderedProminent)
                .disabled(adapter.isConnecting)
        }

        if adapter.isConnected {
            // CAN settings
            Picker("Bitrate", selection: $adapter.selectedBitrate) {
                ForEach(CANBitrate.allCases) { bitrate in
                    Text(bitrate.description).tag(bitrate)
                }
            }
            .disabled(adapter.isCANOpen)

            Toggle("CAN FD", isOn: $adapter.canFDEnabled)
                .disabled(adapter.isCANOpen)

            // Open/Close CAN
            HStack {
                if adapter.isCANOpen {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("CAN Open")
                            .font(.subheadline)
                            .foregroundColor(.green)
                    }
                    Spacer()
                    Button {
                        onCloseCAN()
                    } label: {
                        Label("Close", systemImage: "stop.fill")
                    }
                    .foregroundColor(.orange)
                } else {
                    Button {
                        onOpenCAN()
                    } label: {
                        Label("Open CAN", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Button("Disconnect") {
                adapter.disconnect()
            }
            .foregroundColor(.red)
            .font(.caption)
        }

        if let error = adapter.lastError {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
        }
    }
}
