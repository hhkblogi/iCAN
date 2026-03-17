import SwiftUI
import Combine
import Foundation
import os.log

// MARK: - Serial Adapter

private nonisolated let slcanLog = OSLog(subsystem: "com.hhkblogi.ican", category: "SLCAN")

@MainActor
class SerialAdapter: ObservableObject {
    @Published var selectedPort: String = ""
    @Published var isConnected: Bool = false
    @Published var isCANOpen: Bool = false
    @Published var isConnecting: Bool = false
    @Published var lastError: String?
    @Published var selectedBitrate: CANBitrate = .kbps1000
    @Published var canFDEnabled: Bool = false

    private var client: CANConnection?
    private var isSharedConnection = false
    let name: String
    var adapterIndex: Int
    var channel: Int

    /// Expose client for background I/O (bandwidth test)
    var ioClient: CANConnection? { client }

    init(name: String, adapterIndex: Int = 0, channel: Int = 0) {
        self.name = name
        self.adapterIndex = adapterIndex
        self.channel = channel
    }

    func connect() {
        guard !isConnecting else {
            os_log(.error, log: slcanLog, "%{public}s: connect() skipped — already connecting", name)
            return
        }
        isConnecting = true
        lastError = nil

        os_log(.error, log: slcanLog, "%{public}s: connect() started idx=%d ch=%d", name, adapterIndex, channel)

        // Move blocking IOKit calls off the main thread
        let idx = adapterIndex
        let ch = channel
        let adapterName = name
        Task.detached { [weak self] in
            let usbClient = CANConnection()
            os_log(.error, log: slcanLog, "%{public}s: IOKit connect(index=%d)...", adapterName, idx)
            let connected = usbClient.connect(adapterIndex: idx)
            os_log(.error, log: slcanLog, "%{public}s: IOKit connect → %d", adapterName, connected ? 1 : 0)

            if connected {
                usbClient.setChannel(ch)
                let opened = usbClient.openSerial()
                os_log(.error, log: slcanLog, "%{public}s: openSerial → %d", adapterName, opened ? 1 : 0)
                if opened {
                    _ = usbClient.setBaudRate(6_000_000)
                }

                guard let self else {
                    os_log(.error, log: slcanLog, "%{public}s: self deallocated during connect", adapterName)
                    return
                }
                await MainActor.run {
                    if opened {
                        self.client = usbClient
                        self.isConnected = true
                        self.lastError = nil
                        os_log(.error, log: slcanLog, "%{public}s: UI → Connected", adapterName)
                    } else {
                        let err = usbClient.lastError ?? "Failed to open serial port"
                        self.lastError = err
                        usbClient.disconnect()
                        os_log(.error, log: slcanLog, "%{public}s: UI → Error: %{public}s", adapterName, err)
                    }
                    self.isConnecting = false
                }
            } else {
                let error = usbClient.lastError ?? "Driver not found. Is the adapter connected?"
                os_log(.error, log: slcanLog, "%{public}s: connect failed: %{public}s", adapterName, error)
                guard let self else { return }
                await MainActor.run {
                    self.lastError = error
                    self.isConnecting = false
                }
            }
        }
    }

    /// Connect by sharing an existing client's connection (for PCAN dual-channel).
    func connectShared(from existingClient: CANConnection) {
        guard !isConnecting else {
            os_log(.error, log: slcanLog, "%{public}s: connectShared() skipped — already connecting", name)
            return
        }
        isConnecting = true
        lastError = nil

        let ch = channel
        os_log(.error, log: slcanLog, "%{public}s: connectShared ch=%d from client[%d]",
               name, ch, existingClient.instanceID)

        let usbClient = CANConnection()
        usbClient.shareConnection(from: existingClient, channel: ch)

        self.client = usbClient
        self.isSharedConnection = true
        self.isConnected = true
        self.lastError = nil
        self.isConnecting = false
        os_log(.error, log: slcanLog, "%{public}s: UI → Connected (shared)", name)
    }

    func disconnect() {
        closeCANChannel()
        if !isSharedConnection {
            client?.disconnect()
        }
        client = nil
        isConnected = false
        isCANOpen = false
        isSharedConnection = false
    }

    func openCANChannel(bitrate: CANBitrate) {
        guard isConnected else { return }

        let adapterName = self.name
        let bitrateDesc = bitrate.description
        let bitrateRaw = bitrate.rawValue
        // Move blocking I/O off main thread
        Task.detached { [weak self] in
            guard let self else { return }
            let c = await MainActor.run { self.client }

            os_log(.error, log: slcanLog, "%{public}s: openCANChannel bitrate=%{public}s (%u bps)",
                   adapterName, bitrateDesc, bitrateRaw)

            // Use protocol-aware OpenCAN IPC (driver handles SLCAN vs gs_usb internally)
            let success = c?.openCAN(bitrate: UInt32(bitrateRaw)) ?? false

            if success {
                os_log(.error, log: slcanLog, "%{public}s: CAN channel opened at %{public}s",
                       adapterName, bitrateDesc)
                await MainActor.run {
                    self.lastError = nil
                    self.isCANOpen = true
                }
            } else {
                let err = c?.lastError ?? "OpenCAN failed"
                os_log(.error, log: slcanLog, "%{public}s: openCANChannel failed: %{public}s",
                       adapterName, err)
                await MainActor.run {
                    self.lastError = err
                }
            }
        }
    }

    func closeCANChannel() {
        guard isConnected, isCANOpen else { return }
        _ = client?.closeCAN()
        isCANOpen = false
    }

    func send(_ message: CANMessage) -> Bool {
        guard isConnected, isCANOpen else { return false }
        let encoded = SLCAN.encode(message)
        return (client?.send(encoded) ?? 0) > 0
    }

    func sendRaw(_ slcanString: String) -> Int {
        guard isConnected, isCANOpen else { return 0 }
        return client?.send(slcanString) ?? 0
    }

    func receiveFrames() -> [canfd_frame] {
        return client?.ReceiveFrames(maxFrames: 64) ?? []
    }
}
