import SwiftUI

struct PortsView: View {
    @ObservedObject var viewModel: CANDashboardViewModel

    var body: some View {
        Form {
            // CAN Settings
            Section("CAN Settings") {
                Picker("Bitrate", selection: $viewModel.selectedBitrate) {
                    ForEach(CANBitrate.allCases) { bitrate in
                        Text(bitrate.description).tag(bitrate)
                    }
                }

                Toggle("CAN FD Enabled", isOn: $viewModel.canFDEnabled)

                if viewModel.canFDEnabled {
                    Text("Note: DSD TECH adapters support up to 5M data phase bitrate.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Adapter 1 Section
            Section("Adapter 1") {
                AdapterConnectionSection(
                    adapter: viewModel.adapter1,
                    availablePorts: viewModel.availablePorts,
                    onRefresh: { viewModel.refreshPorts() },
                    onConnect: { viewModel.connectAdapter(viewModel.adapter1) },
                    onOpenCAN: { viewModel.openCANChannel(for: viewModel.adapter1) },
                    onCloseCAN: { viewModel.closeCANChannel(for: viewModel.adapter1) }
                )
            }

            // Adapter 2 Section
            Section("Adapter 2") {
                AdapterConnectionSection(
                    adapter: viewModel.adapter2,
                    availablePorts: viewModel.availablePorts,
                    onRefresh: { viewModel.refreshPorts() },
                    onConnect: { viewModel.connectAdapter(viewModel.adapter2) },
                    onOpenCAN: { viewModel.openCANChannel(for: viewModel.adapter2) },
                    onCloseCAN: { viewModel.closeCANChannel(for: viewModel.adapter2) }
                )
            }

            // Diagnostic Section
            Section("Driver Diagnostics") {
                DiagnosticView()
            }
        }
    }
}

// Sub-component for individual adapter connection
struct AdapterConnectionSection: View {
    @ObservedObject var adapter: SerialAdapter
    let availablePorts: [PortInfo]
    let onRefresh: () -> Void
    let onConnect: () -> Void
    let onOpenCAN: () -> Void
    let onCloseCAN: () -> Void

    var body: some View {
        Picker("Port", selection: $adapter.selectedPort) {
            Text("Select Port").tag("")
            ForEach(availablePorts) { port in
                Text(port.name).tag(port.id)
            }
        }
        .onChange(of: adapter.selectedPort) { _, newValue in
            if let port = availablePorts.first(where: { $0.id == newValue }) {
                adapter.adapterIndex = port.deviceIndex
                adapter.channel = port.channel
            }
        }

        HStack {
            if adapter.isConnecting {
                ProgressView()
                    .frame(width: 10, height: 10)
                Text("Connecting...")
                    .foregroundColor(.orange)
                    .font(.subheadline)
                    .fontWeight(.bold)
            } else {
                Circle()
                    .fill(adapter.isConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(adapter.isConnected ? "Connected" : "Disconnected")
                    .foregroundColor(adapter.isConnected ? .green : .red)
                    .font(.subheadline)
                    .fontWeight(.bold)
            }

            Spacer()

            if adapter.isConnected {
                Button("Disconnect") {
                    adapter.disconnect()
                }
                .foregroundColor(.red)
            } else {
                Button("Connect") {
                    onConnect()
                }
                .buttonStyle(.borderedProminent)
                .disabled(adapter.selectedPort.isEmpty || adapter.isConnecting)
            }
        }

        if adapter.isConnected {
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
        }

        if let error = adapter.lastError {
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
        }

        Button("Refresh Ports") {
            onRefresh()
        }
        .font(.caption)
    }
}
