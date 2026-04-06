import SwiftUI

struct ContentView: View {
    @StateObject private var vm = CANViewModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Status
                HStack {
                    Circle()
                        .fill(vm.isOpen ? .green : vm.isConnected ? .orange : .red)
                        .frame(width: 12, height: 12)
                    if let iface = vm.selectedInterface, vm.isConnected {
                        Text("\(iface.interfaceName) — \(vm.isOpen ? "CAN bus active" : "Connected")")
                            .font(.headline)
                    } else {
                        Text("Disconnected")
                            .font(.headline)
                    }
                    Spacer()
                    Text("\(vm.frameCount) frames")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal)

                // Interface list + controls
                if !vm.isConnected {
                    if vm.interfaces.isEmpty {
                        HStack {
                            Text("No CAN interfaces detected")
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Scan") { vm.scanInterfaces() }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal)
                    } else {
                        // Interface list
                        ForEach(vm.interfaces) { iface in
                            HStack {
                                Button {
                                    vm.selectedInterface = iface
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: vm.selectedInterface == iface ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(vm.selectedInterface == iface ? .blue : .secondary)
                                        Text(iface.interfaceName)
                                            .font(.headline)
                                            .monospaced()
                                        Text("(\(iface.adapterName), \(iface.codec))")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                            }
                            .padding(.horizontal)
                        }

                        HStack {
                            Button("Connect") { vm.connect() }
                                .buttonStyle(.borderedProminent)
                                .disabled(vm.selectedInterface == nil)
                            Spacer()
                            Button { vm.scanInterfaces() } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                                    .labelStyle(.iconOnly)
                            }
                        }
                        .padding(.horizontal)
                    }
                } else if vm.isOpen {
                    HStack(spacing: 12) {
                        Button("Send 0x123") { vm.sendTestFrame() }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        Button("Close") { vm.closeCAN() }
                    }
                    .padding(.horizontal)
                } else {
                    HStack(spacing: 12) {
                        Picker("Bitrate", selection: $vm.selectedBitrate) {
                            ForEach(vm.bitrates, id: \.1) { name, rate in
                                Text(name).tag(rate)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)

                        Button("Open") { vm.openCAN() }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                        Button("Disconnect") { vm.disconnect() }
                    }
                    .padding(.horizontal)
                }

                // Error
                if let error = vm.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                }

                Divider()

                // Frame list
                if vm.frames.isEmpty {
                    ContentUnavailableView(
                        "No CAN Frames",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Connect to a USB CAN adapter and open the CAN bus to see frames.")
                    )
                } else {
                    List(vm.frames) { frame in
                        HStack {
                            Text(String(format: "0x%03X", frame.canId))
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.bold)
                                .foregroundColor(.blue)
                                .frame(width: 70, alignment: .leading)

                            Text(frame.data.map { String(format: "%02X", $0) }.joined(separator: " "))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)

                            Spacer()

                            if frame.isFD {
                                Text("FD")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .background(Color.purple.opacity(0.2))
                                    .cornerRadius(3)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("CAN Client Demo")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { vm.scanInterfaces() }
        }
    }
}
