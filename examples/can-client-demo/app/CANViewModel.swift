import Foundation
import Combine

struct CANInterface: Identifiable, Hashable {
    let id: String           // "0:0", "1:0", "1:1"
    let interfaceName: String // "can0", "can1", ...
    let adapterName: String  // "CANable", "candleLight", "PCAN-USB Pro FD"
    let codec: String        // "slcan", "gs_usb", "pcan"
    let deviceIndex: Int     // for CANClient.open()
    let channel: Int         // 0 or 1
}

struct ReceivedFrame: Identifiable {
    let id = UUID()
    let timestamp: UInt64
    let canId: UInt32
    let data: [UInt8]
    let isExtended: Bool
    let isFD: Bool
}

@MainActor
class CANViewModel: ObservableObject {
    @Published var interfaces: [CANInterface] = []
    @Published var selectedInterface: CANInterface?
    @Published var isConnected = false
    @Published var isOpen = false
    @Published var frames: [ReceivedFrame] = []
    @Published var lastError: String?
    @Published var frameCount: Int = 0
    @Published var selectedBitrate: UInt32 = 1_000_000

    private var client = CANClient()
    private var readTimer: Timer?
    private var sendCounter: UInt64 = 0

    let bitrates: [(String, UInt32)] = [
        ("125 kbps", 125_000),
        ("250 kbps", 250_000),
        ("500 kbps", 500_000),
        ("1 Mbps", 1_000_000),
    ]

    // Known USB CAN adapters (same VID/PID as iCAN's driver)
    private let knownAdapters: [(name: String, codec: String, vid: Int, pid: Int, channels: Int)] = [
        ("CANable",          "slcan",  0x16D0, 0x117E, 1),
        ("candleLight",      "gs_usb", 0x1D50, 0x606F, 1),
        ("PCAN-USB Pro FD",  "pcan",   0x0C72, 0x0011, 2),
    ]

    func scanInterfaces() {
        var found: [CANInterface] = []
        var deviceIndex = 0
        var canIndex = 0

        for adapter in knownAdapters {
            guard let usbMatchCF = IOServiceMatching("IOUSBHostDevice") else { continue }
            let usbMatch = usbMatchCF as NSMutableDictionary
            usbMatch["idVendor"] = adapter.vid
            usbMatch["idProduct"] = adapter.pid
            var usbIter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, usbMatch as CFDictionary, &usbIter) == KERN_SUCCESS {
                var s = IOIteratorNext(usbIter)
                while s != 0 {
                    for ch in 0..<adapter.channels {
                        found.append(CANInterface(
                            id: "\(deviceIndex):\(ch)",
                            interfaceName: "can\(canIndex)",
                            adapterName: adapter.name,
                            codec: adapter.codec,
                            deviceIndex: deviceIndex,
                            channel: ch
                        ))
                        canIndex += 1
                    }
                    deviceIndex += 1
                    IOObjectRelease(s)
                    s = IOIteratorNext(usbIter)
                }
                IOObjectRelease(usbIter)
            }
        }

        interfaces = found
        if selectedInterface == nil {
            selectedInterface = found.first
        }
    }

    func connect() {
        guard let iface = selectedInterface else {
            lastError = "No interface selected"
            return
        }
        lastError = nil
        let idx = Int32(iface.deviceIndex)
        let ch = Int32(iface.channel)
        Task.detached { [weak self] in
            guard let self else { return }
            var c = CANClient()
            let ok = c.open(idx)
            if ok {
                c.setChannel(ch)
                _ = c.openSerial()
                _ = c.setBaudRate(6_000_000)
            }
            let err = ok ? nil : String(cString: c.lastError())
            let client = c
            await MainActor.run {
                if ok {
                    self.client = client
                    self.isConnected = true
                    self.lastError = nil
                } else {
                    self.lastError = err
                }
            }
        }
    }

    func openCAN() {
        guard isConnected else { return }
        let bitrate = selectedBitrate
        Task.detached { [weak self] in
            guard let self else { return }
            var c = await MainActor.run { self.client }
            let result = c.openChannel(bitrate)
            let err = result == 0 ? nil : String(cString: c.lastError())
            let client = c
            await MainActor.run {
                if result == 0 {
                    self.client = client
                    self.isOpen = true
                    self.lastError = nil
                    self.startReading()
                } else {
                    self.lastError = err
                }
            }
        }
    }

    func closeCAN() {
        stopReading()
        _ = client.closeChannel()
        isOpen = false
    }

    func disconnect() {
        closeCAN()
        client.close()
        isConnected = false
    }

    func sendTestFrame() {
        guard isOpen else { return }
        var frame = can_frame()
        frame.can_id = 0x123
        frame.len = 8
        withUnsafeMutableBytes(of: &frame.data) { buf in
            for i in 0..<min(8, buf.count) {
                buf[i] = UInt8((sendCounter >> (56 - i * 8)) & 0xFF)
            }
        }
        var c = client
        let written = c.writeClassic(&frame)
        if written != 1 {
            lastError = "Send failed"
        }
        sendCounter += 1
    }

    private func startReading() {
        readTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollFrames()
            }
        }
    }

    private func stopReading() {
        readTimer?.invalidate()
        readTimer = nil
    }

    private func pollFrames() {
        var packets = [CANPacket](repeating: CANPacket(), count: 64)
        var c = client
        let n = c.readMany(&packets, 64)
        if n > 0 {
            for i in 0..<Int(n) {
                let p = packets[i]
                let f = p.frame
                let id = f.can_id & UInt32(CAN_EFF_MASK)
                let isExt = (f.can_id & UInt32(CAN_EFF_FLAG)) != 0
                let isFD = (f.flags & UInt8(CANFD_FDF)) != 0
                let len = Int(f.len)

                var dataBytes = [UInt8]()
                withUnsafeBytes(of: f.data) { buf in
                    for j in 0..<min(len, buf.count) {
                        dataBytes.append(buf[j])
                    }
                }

                let frame = ReceivedFrame(
                    timestamp: p.timestamp_us,
                    canId: id,
                    data: dataBytes,
                    isExtended: isExt,
                    isFD: isFD
                )
                frames.insert(frame, at: 0)
                frameCount += 1
            }
            if frames.count > 200 {
                frames = Array(frames.prefix(200))
            }
        }
    }
}
