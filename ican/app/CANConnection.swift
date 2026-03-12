/*
 * CANConnection.swift
 * Thin Swift wrapper around the CANClient C++ library.
 *
 * CANClient communicates via POSIX serial I/O to /dev/cu.SLCAN
 * (provided by the IOUserUSBSerial driver). SLCAN encoding/decoding
 * is handled by the C++ library.
 */

import Foundation
import os.log

private nonisolated let log = OSLog(subsystem: "com.hhkblogi.iCAN", category: "CANConnection")

/// nonisolated: This class uses the C++ library's std::mutex for thread safety
/// and is called from background threads (bandwidth test loops).
nonisolated class CANConnection: @unchecked Sendable {

    // MARK: - Instance tracking
    private static let _instanceCounter = NSLock()
    private static var _nextInstanceID: Int = 0
    private static var _aliveCount: Int = 0
    let instanceID: Int

    // MARK: - C++ client
    private var client = CANClient()

    // MARK: - State (delegated to C++ library)

    var isConnected: Bool { client.isConnected() }
    var isOpen: Bool { client.isOpen() }

    var lastError: String? {
        get {
            let err = String(cString: client.lastError())
            return err.isEmpty ? nil : err
        }
        set { /* errors are set internally by C++ library */ }
    }

    // MARK: - Initialization

    init() {
        Self._instanceCounter.lock()
        self.instanceID = Self._nextInstanceID
        Self._nextInstanceID += 1
        Self._aliveCount += 1
        let alive = Self._aliveCount
        Self._instanceCounter.unlock()
        os_log(.error, log: log, "CANConnection[%d] init (alive=%d)", instanceID, alive)
    }

    deinit {
        disconnect()
        Self._instanceCounter.lock()
        Self._aliveCount -= 1
        let alive = Self._aliveCount
        Self._instanceCounter.unlock()
        os_log(.error, log: log, "CANConnection[%d] deinit (alive=%d)", instanceID, alive)
    }

    // MARK: - Connection Management

    func connect(adapterIndex: Int = 0) -> Bool {
        client = CANClient()
        let ok = client.open(Int32(adapterIndex))
        os_log(.error, log: log, "[%d] connect(index=%d) → %d", instanceID, adapterIndex, ok ? 1 : 0)
        return ok
    }

    /// Create a shared-connection client that reuses an existing client's connection
    /// but operates on a different CAN channel. Used for PCAN dual-channel.
    func shareConnection(from other: CANConnection, channel: Int) {
        client = other.client  // CANClient copy shares the underlying connection (shared_ptr)
        client.setChannel(Int32(channel))
        os_log(.error, log: log, "[%d] shareConnection from [%d] ch=%d", instanceID, other.instanceID, channel)
    }

    func setChannel(_ channel: Int) {
        client.setChannel(Int32(channel))
    }

    func disconnect() {
        os_log(.error, log: log, "[%d] disconnect", instanceID)
        client.close()
    }

    // MARK: - Serial Port Operations

    func openSerial() -> Bool {
        let ok = client.openSerial() == 0
        os_log(.error, log: log, "[%d] openSerial → %d", instanceID, ok ? 1 : 0)
        return ok
    }

    func closeSerial() -> Bool {
        return client.closeSerial() == 0
    }

    func setBaudRate(_ baudRate: UInt32) -> Bool {
        return client.setBaudRate(baudRate) == 0
    }

    // MARK: - CAN Channel Control

    func openCAN(bitrate: UInt32) -> Bool {
        let ok = client.openChannel(bitrate) == 0
        os_log(.error, log: log, "[%d] openCAN(%u) → %d", instanceID, bitrate, ok ? 1 : 0)
        return ok
    }

    func closeCAN() -> Bool {
        return client.closeChannel() == 0
    }

    // MARK: - CAN Frame API (POSIX serial + SLCAN encoding)

    func SendFrame(_ frame: can_frame) -> Bool {
        var f = frame
        return client.writeClassic(&f) == 1
    }

    func SendFDFrame(_ frame: canfd_frame) -> Bool {
        var f = frame
        return client.write(&f) == 1
    }

    func ReceiveFrame() -> canfd_frame? {
        var frame = canfd_frame()
        return client.read(&frame) == 1 ? frame : nil
    }

    func ReceiveFrames(maxFrames: Int = 64) -> [canfd_frame] {
        var frames = [canfd_frame](repeating: canfd_frame(), count: min(maxFrames, 256))
        let count = client.readMany(&frames, Int32(frames.count))
        return count > 0 ? Array(frames.prefix(Int(count))) : []
    }

    // MARK: - Raw Data (SLCAN control commands)

    func send(_ data: Data) -> Int {
        return data.withUnsafeBytes { ptr in
            Int(client.sendRaw(ptr.baseAddress, Int32(data.count)))
        }
    }

    func send(_ string: String) -> Int {
        guard let data = string.data(using: .ascii) else { return 0 }
        return send(data)
    }

    // MARK: - C++ Client Access (for TestEngines)

    func canClient() -> CANClient {
        return client
    }
}
