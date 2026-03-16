import SwiftUI

struct ConnectionSheet: View {
    @ObservedObject var viewModel: CANDashboardViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // Adapter 1 Section
                Section("Adapter 1 (TX/RX)") {
                    AdapterConnectionSection(
                        adapter: viewModel.adapter1,
                        availablePorts: viewModel.availablePorts,
                        onRefresh: { viewModel.refreshPorts() },
                        onConnect: { viewModel.connectAdapter(viewModel.adapter1) }
                    )
                }

                // Adapter 2 Section
                Section("Adapter 2 (RX/TX)") {
                    AdapterConnectionSection(
                        adapter: viewModel.adapter2,
                        availablePorts: viewModel.availablePorts,
                        onRefresh: { viewModel.refreshPorts() },
                        onConnect: { viewModel.connectAdapter(viewModel.adapter2) }
                    )
                }

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
                    
                    HStack {
                        Button {
                            viewModel.openCANChannels()
                        } label: {
                            Label("Open CAN Channels", systemImage: "play.fill")
                        }
                        .disabled(!viewModel.adapter1.isConnected && !viewModel.adapter2.isConnected || viewModel.isCANOpen)
                        .buttonStyle(.borderedProminent)
                        
                        if viewModel.isCANOpen {
                            Button {
                                viewModel.closeCANChannels()
                            } label: {
                                Label("Close CAN Channels", systemImage: "power")
                            }
                            .foregroundColor(.orange)
                        }
                    }
                }

                // Diagnostic Section
                Section("Driver Diagnostics") {
                    DiagnosticView()
                }
            }
            .navigationTitle("Connections & Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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

    var body: some View {
        // Each element is a separate Form row so taps don't get swallowed by Picker
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

        if adapter.isCANOpen {
            HStack {
                Image(systemName: "bolt.car.fill")
                    .foregroundColor(.green)
                Text("CAN Channel Open")
                    .font(.caption)
                    .foregroundColor(.green)
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
