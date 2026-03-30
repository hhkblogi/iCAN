/*
 * CANMessage.swift
 * CAN message model and SLCAN protocol helpers
 * Supports both Classic CAN and CAN FD
 */

import Foundation

// MARK: - CAN Message

struct CANMessage: Identifiable, Equatable {
    let id = UUID()
    let arbitrationId: UInt32
    let data: [UInt8]
    let isExtended: Bool
    let isFD: Bool
    let timestamp: Date

    var dataLength: Int { data.count }

    var arbitrationIdHex: String {
        if isExtended {
            return String(format: "0x%08X", arbitrationId)
        } else {
            return String(format: "0x%03X", arbitrationId)
        }
    }

    var dataHex: String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func standard(id: UInt32, data: [UInt8]) -> CANMessage {
        CANMessage(arbitrationId: id, data: data, isExtended: false, isFD: false, timestamp: Date())
    }

    static func fd(id: UInt32, data: [UInt8], extended: Bool = false) -> CANMessage {
        CANMessage(arbitrationId: id, data: data, isExtended: extended, isFD: true, timestamp: Date())
    }
}

// MARK: - CAN Bitrate

enum CANBitrate: Int, CaseIterable, Identifiable {
    case kbps125 = 125000
    case kbps250 = 250000
    case kbps500 = 500000
    case kbps1000 = 1000000
    case kbps2000 = 2000000
    case kbps5000 = 5000000

    var id: Int { rawValue }

    var description: String {
        switch self {
        case .kbps125: return "125 kbps"
        case .kbps250: return "250 kbps"
        case .kbps500: return "500 kbps"
        case .kbps1000: return "1 Mbps"
        case .kbps2000: return "2 Mbps (FD)"
        case .kbps5000: return "5 Mbps (FD)"
        }
    }

    /// Standard SLCAN bitrate codes (confirmed working with DSD TECH SH-C31G)
    var slcanCode: String {
        switch self {
        case .kbps125: return "S4"
        case .kbps250: return "S5"
        case .kbps500: return "S6"
        case .kbps1000: return "S8"
        case .kbps2000: return "Y2"  // CAN FD data rate
        case .kbps5000: return "Y5"  // CAN FD data rate
        }
    }

    var isFDOnly: Bool {
        switch self {
        case .kbps2000, .kbps5000: return true
        default: return false
        }
    }
}

// MARK: - CAN Bus Load Calculation

/// Calculates the nominal bit-time cost of a single CAN frame on the bus.
/// This accounts for frame overhead, data payload, CRC, and bit stuffing.
enum CANBusLoad {

    /// Bit-time cost per CAN 2.0 frame (standard 11-bit ID).
    /// Formula: (SOF + Arb + Ctrl + Data + CRC + ACK + EOF + IFS) × stuffing
    /// = (1 + 11 + 1 + 1 + 4 + DLC×8 + 15 + 1 + 2 + 7 + 3) × 1.2
    /// = (46 + DLC×8) × 1.2
    static func bitsPerFrame_CAN20(dataBytes: Int = 8) -> Double {
        let overhead = 46.0  // SOF(1) + ID(11) + RTR(1) + IDE(0) + r0(1) + DLC(4) + CRC(15) + CRC_del(1) + ACK(2) + EOF(7) + IFS(3)
        let dataBits = Double(min(dataBytes, 8)) * 8.0
        return (overhead + dataBits) * 1.2  // 20% bit stuffing
    }

    /// Bit-time cost per CAN FD frame (no BRS — single bitrate).
    /// CAN FD has larger CRC: 17 bits for ≤16 bytes, 21 bits for >16 bytes.
    static func bitsPerFrame_CANFD(dataBytes: Int = 64) -> Double {
        let crcBits = dataBytes <= 16 ? 17.0 : 21.0
        let overhead = 29.0  // SOF(1) + ID(11) + r1(1) + IDE(0) + r0(1) + FDF(1) + res(1) + BRS(1) + ESI(1) + DLC(4) + stuff_cnt(4) + CRC_del(1) + ACK(2)
        let fixedEnd = 12.0  // EOF(7) + IFS(3) + parity(2)
        let dataBits = Double(min(dataBytes, 64)) * 8.0
        // CAN FD uses fixed stuffing in data phase (1 stuff bit per 4 data bits)
        let dataWithStuff = dataBits * 1.25
        return (overhead + dataWithStuff + crcBits + fixedEnd) * 1.1  // ~10% arb phase stuffing
    }

    /// Calculate bus load percentage.
    /// - Parameters:
    ///   - framesPerSec: total frames observed on the bus per second (TX + RX)
    ///   - bitrate: nominal bitrate in bits/sec
    ///   - isFD: whether CAN FD frames
    ///   - dataBytes: average payload size
    static func busLoadPercent(framesPerSec: Double, bitrate: Int, isFD: Bool = false, dataBytes: Int = 8) -> Double {
        let bpf = isFD ? bitsPerFrame_CANFD(dataBytes: dataBytes) : bitsPerFrame_CAN20(dataBytes: dataBytes)
        let load = framesPerSec * bpf / Double(max(bitrate, 1)) * 100.0
        return min(load, 100.0)
    }
}

// MARK: - CAN FD DLC Mapping

enum CANFD {
    // CAN FD supports these data lengths: 0-8, 12, 16, 20, 24, 32, 48, 64
    static let validLengths = [0, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 20, 24, 32, 48, 64]

    static func dlcToLength(_ dlc: Int) -> Int {
        switch dlc {
        case 0...8: return dlc
        case 9: return 12
        case 10: return 16
        case 11: return 20
        case 12: return 24
        case 13: return 32
        case 14: return 48
        case 15: return 64
        default: return 8
        }
    }

    static func lengthToDlc(_ length: Int) -> Int {
        switch length {
        case 0...8: return length
        case 9...12: return 9
        case 13...16: return 10
        case 17...20: return 11
        case 21...24: return 12
        case 25...32: return 13
        case 33...48: return 14
        case 49...64: return 15
        default: return 8
        }
    }
}

// MARK: - SocketCAN Constants (Swift-side literals to avoid C++ interop macro crash)

private let kCAN_EFF_FLAG: UInt32  = 0x80000000  // extended frame format
private let kCAN_SFF_MASK: UInt32  = 0x000007FF  // standard frame: 11-bit ID
private let kCAN_EFF_MASK: UInt32  = 0x1FFFFFFF  // extended frame: 29-bit ID
private let kCAN_MAX_DLEN: Int     = 8           // classic CAN max payload
private let kCANFD_MAX_DLEN: Int   = 64          // CAN FD max payload
private let kCANFD_FDF: UInt8      = 0x04        // FD frame format flag

// MARK: - CAN Frame Bridge (C struct ↔ Swift CANMessage)

extension CANMessage {
    /// Convert to C can_frame (classic CAN only, len <= 8)
    func ToCanFrame() -> can_frame {
        var frame = can_frame()
        var canId = arbitrationId
        if isExtended { canId |= kCAN_EFF_FLAG }
        frame.can_id = canId
        frame.len = UInt8(min(data.count, kCAN_MAX_DLEN))
        withUnsafeMutableBytes(of: &frame.data) { buf in
            for i in 0..<Int(frame.len) {
                buf[i] = data[i]
            }
        }
        return frame
    }

    /// Convert to C canfd_frame (works for both classic and FD)
    func ToCanFDFrame() -> canfd_frame {
        var frame = canfd_frame()
        var canId = arbitrationId
        if isExtended { canId |= kCAN_EFF_FLAG }
        frame.can_id = canId
        frame.len = UInt8(min(data.count, kCANFD_MAX_DLEN))
        frame.flags = isFD ? kCANFD_FDF : 0
        withUnsafeMutableBytes(of: &frame.data) { buf in
            for i in 0..<Int(frame.len) {
                buf[i] = data[i]
            }
        }
        return frame
    }

    /// Create from C canfd_frame (works for both classic and FD)
    static func FromCanFDFrame(_ frame: canfd_frame) -> CANMessage {
        let isExt = (frame.can_id & kCAN_EFF_FLAG) != 0
        let rawId = isExt ? (frame.can_id & kCAN_EFF_MASK)
                          : (frame.can_id & kCAN_SFF_MASK)
        let isFDFrame = (frame.flags & kCANFD_FDF) != 0
        let len = Int(frame.len)

        var data = [UInt8]()
        data.reserveCapacity(len)
        var frameCopy = frame
        withUnsafeBytes(of: &frameCopy.data) { buf in
            for i in 0..<len {
                data.append(buf[i])
            }
        }

        return CANMessage(arbitrationId: rawId, data: data,
                         isExtended: isExt, isFD: isFDFrame,
                         timestamp: Date())
    }
}

// MARK: - SLCAN Protocol

enum SLCAN {

    /// Encode a CAN message to slcan format
    static func encode(_ message: CANMessage) -> String {
        var cmd: String

        if message.isFD {
            // CAN FD frame: 'd' for standard, 'D' for extended
            cmd = message.isExtended ? "D" : "d"
        } else {
            // Classic CAN: 't' for standard, 'T' for extended
            cmd = message.isExtended ? "T" : "t"
        }

        if message.isExtended {
            cmd += String(format: "%08X", message.arbitrationId)
        } else {
            cmd += String(format: "%03X", message.arbitrationId)
        }

        if message.isFD {
            // CAN FD uses actual DLC value (0-15)
            let dlc = CANFD.lengthToDlc(message.dataLength)
            cmd += String(format: "%X", dlc)
        } else {
            cmd += String(format: "%X", message.dataLength)
        }

        for byte in message.data {
            cmd += String(format: "%02X", byte)
        }

        cmd += "\r"
        return cmd
    }

    /// Decode slcan response to CAN message
    static func decode(_ response: String) -> CANMessage? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let firstChar = trimmed.first else { return nil }

        let isExtended: Bool
        let isFD: Bool

        switch firstChar {
        case "t": isExtended = false; isFD = false
        case "T": isExtended = true; isFD = false
        case "d": isExtended = false; isFD = true
        case "D": isExtended = true; isFD = true
        default: return nil
        }

        var index = trimmed.index(after: trimmed.startIndex)
        let idLength = isExtended ? 8 : 3

        guard trimmed.distance(from: index, to: trimmed.endIndex) >= idLength + 1 else { return nil }

        let idEndIndex = trimmed.index(index, offsetBy: idLength)
        let idString = String(trimmed[index..<idEndIndex])
        guard let arbitrationId = UInt32(idString, radix: 16) else { return nil }
        index = idEndIndex

        guard index < trimmed.endIndex else { return nil }
        let dlcChar = String(trimmed[index])
        guard let dlc = Int(dlcChar, radix: 16) else { return nil }
        index = trimmed.index(after: index)

        // Convert DLC to actual data length
        let dataLength = isFD ? CANFD.dlcToLength(dlc) : dlc

        var data: [UInt8] = []
        for _ in 0..<dataLength {
            guard trimmed.distance(from: index, to: trimmed.endIndex) >= 2 else { break }
            let byteEndIndex = trimmed.index(index, offsetBy: 2)
            let byteString = String(trimmed[index..<byteEndIndex])
            guard let byte = UInt8(byteString, radix: 16) else { break }
            data.append(byte)
            index = byteEndIndex
        }

        return CANMessage(arbitrationId: arbitrationId, data: data, isExtended: isExtended, isFD: isFD, timestamp: Date())
    }

    // MARK: - Commands

    static var openCommand: String { "O\r" }
    static var closeCommand: String { "C\r" }
    static var versionCommand: String { "V\r" }

    // CAN FD mode command
    static var enableFDCommand: String { "Y\r" }

    static func setBitrateCommand(_ bitrate: CANBitrate) -> String {
        bitrate.slcanCode + "\r"
    }

    // Set CAN FD data bitrate separately (some adapters need this)
    static func setFDDataBitrateCommand(_ bitrate: CANBitrate) -> String {
        "Y" + String(bitrate.rawValue / 1000000) + "\r"
    }

    static func isOK(_ response: String) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || (response.contains("\r") && !response.contains("\u{07}"))
    }

    static func isError(_ response: String) -> Bool {
        response.contains("\u{07}")
    }
}
