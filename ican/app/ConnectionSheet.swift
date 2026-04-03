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
                ForEach(viewModel.usbAdapters) { usbAdapter in
                    Section {
                        ForEach(usbAdapter.interfaces) { iface in
                            if let adapter = viewModel.adapterForInterface(iface) {
                                InterfaceSection(
                                    iface: iface,
                                    adapter: adapter,
                                    onConnect: { viewModel.connectAdapter(adapter) },
                                    onOpenCAN: { viewModel.openCANChannel(for: adapter) },
                                    onCloseCAN: { viewModel.closeCANChannel(for: adapter) }
                                )
                            }
                        }
                    } header: {
                        HStack {
                            Text("USB Adapter \(usbAdapter.deviceIndex): \(usbAdapter.name)")
                            Spacer()
                            Button { viewModel.refreshPorts() } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }
                }
            }

            // Diagnostic Section
            Section("Driver Diagnostics") {
                DiagnosticView()
            }
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

        // CAN settings (always visible, disabled when CAN is open)
        Picker("Bitrate", selection: $adapter.selectedBitrate) {
            ForEach(CANBitrate.allCases) { bitrate in
                Text(bitrate.description).tag(bitrate)
            }
        }
        .disabled(adapter.isCANOpen)

        Toggle("CAN FD", isOn: $adapter.canFDEnabled)
            .disabled(adapter.isCANOpen)

        // Actions row
        HStack {
            if !adapter.isConnected {
                Button("Connect") { onConnect() }
                    .buttonStyle(.borderless)
                    .disabled(adapter.isConnecting)
            } else if adapter.isCANOpen {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("CAN bus active").font(.caption).foregroundColor(.green)
                }

                Spacer()

                Button { onCloseCAN() } label: {
                    Label("Close", systemImage: "stop.fill")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.orange)
                .font(.caption)
            } else {
                Button("Open") { onOpenCAN() }
                    .buttonStyle(.borderless)

                Spacer()

                Button("Disconnect") { adapter.disconnect() }
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }

        if let error = adapter.lastError {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
        }
    }
}
