import SwiftUI
import Foundation

// MARK: - Bandwidth Stats Model

struct BandwidthTestStats {
    var messagesSent: Int = 0
    var messagesReceived: Int = 0
    var bytesSent: Int = 0
    var bytesReceived: Int = 0
    var startTime: Date?
    var duration: Double = 0
    // Diagnostics: track raw receive calls
    var rxPolls: Int = 0       // total receive() calls
    var rxHits: Int = 0        // receive() calls that returned data
    var rxRawBytes: Int = 0    // total raw bytes received (before SLCAN decode)
    // Sequence tracking
    var rxSequenceGaps: Int = 0        // number of gaps detected
    var rxLastSequence: UInt32? = nil   // last received sequence number
    var rxOutOfOrder: Int = 0           // out-of-order deliveries
    var rxDuplicates: Int = 0           // duplicate sequence numbers
    var rxDecodeFailures: Int = 0      // SLCAN lines that failed to decode

    // Driver-level diagnostics (from USBSerialStatus)
    var driverReadCompleteCount: Int = 0
    var driverReadCompleteBytes: Int = 0
    var driverReadSubmitFailures: Int = 0
    var driverRxSlotsInFlight: Int = 0
    var driverTxBusyCount: Int = 0
    var driverReadChainRestarts: Int = 0

    // PCAN codec diagnostics (from SharedRingHeader via CANClient)
    var codecEchoCount: Int = 0        // TX echoes filtered by driver
    var codecOverrunCount: Int = 0     // firmware FIFO overflows (MSG_OVERRUN)
    var codecTruncatedCount: Int = 0   // msgs truncated at USB transfer boundary
    var codecZeroSentinelCount: Int = 0 // zero-size end-of-stream hits
    var ringRxDropped: Int = 0         // frames dropped because RX ring was full

    // Debug: last USB transfer snapshot
    var dbgTransferSeq: Int = 0
    var dbgTransferLen: Int = 0
    var dbgMsgsParsed: Int = 0
    var dbgHeadHex: String = ""        // hex dump of first 48 bytes

    // Sequence-verified delivery from FlightWindow
    var seqDeliveryRate: Double = -1.0
    var deliveryReaped: UInt64 = 0       // frames past grace window (verified)
    var deliveryConfirmed: UInt64 = 0    // of those, confirmed received
    var deliveryTimedOut: UInt64 { deliveryReaped - deliveryConfirmed }

    // Instantaneous per-second rates (updated every ~1s from drainPerSecondCounters)
    var instantTxRate: Double = 0
    var instantRxRate: Double = 0
    var instantSeqGaps: Double = 0  // per-second missing sequence numbers
    var instantTxBandwidth: Double = 0
    var instantRxBandwidth: Double = 0
    var txRate: Double { instantTxRate }
    var rxRate: Double { instantRxRate }
    var txBandwidth: Double { instantTxBandwidth }
    var rxBandwidth: Double { instantRxBandwidth }

    /// Cumulative loss rate — per-second is inaccurate due to CAN bus latency
    /// (messages sent in second N arrive in second N+1, causing phantom loss).
    var lossRate: Double {
        guard messagesSent > 0 else { return 0 }
        let lost = messagesSent - messagesReceived
        return Double(max(0, lost)) / Double(messagesSent) * 100
    }

    mutating func reset() {
        messagesSent = 0
        messagesReceived = 0
        bytesSent = 0
        bytesReceived = 0
        startTime = nil
        duration = 0
        seqDeliveryRate = -1.0
        deliveryReaped = 0
        deliveryConfirmed = 0
        instantTxRate = 0
        instantRxRate = 0
        instantSeqGaps = 0
        instantTxBandwidth = 0
        instantRxBandwidth = 0
        rxPolls = 0
        rxHits = 0
        rxRawBytes = 0
        rxSequenceGaps = 0
        rxLastSequence = nil
        rxOutOfOrder = 0
        rxDuplicates = 0
        rxDecodeFailures = 0
        driverReadCompleteCount = 0
        driverReadCompleteBytes = 0
        driverReadSubmitFailures = 0
        driverRxSlotsInFlight = 0
        driverTxBusyCount = 0
        driverReadChainRestarts = 0
        codecEchoCount = 0
        codecOverrunCount = 0
        codecTruncatedCount = 0
        codecZeroSentinelCount = 0
        ringRxDropped = 0
        dbgTransferSeq = 0
        dbgTransferLen = 0
        dbgMsgsParsed = 0
        dbgHeadHex = ""
    }
}



// MARK: - Thread-safe Bandwidth I/O Accumulator

/// Accumulates bandwidth test stats from background I/O threads.
/// All methods are thread-safe via NSLock.
class BandwidthIOAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _messagesSent = 0
    private var _bytesSent = 0
    private var _messagesReceived = 0
    private var _bytesReceived = 0
    private var _txThisSecond = 0
    private var _rxThisSecond = 0
    private var _txBytesThisSecond = 0
    private var _rxBytesThisSecond = 0
    private var _rxPolls = 0
    private var _rxHits = 0
    private var _rxRawBytes = 0
    private var _rxSequenceGaps = 0
    private var _rxOutOfOrder = 0
    private var _rxDuplicates = 0
    private var _rxLastSequence: UInt32? = nil
    private var _rxDecodeFailures = 0

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    func addSent(messages: Int, bytes: Int) {
        lock.lock()
        _messagesSent += messages
        _bytesSent += bytes
        _txThisSecond += messages
        _txBytesThisSecond += bytes
        lock.unlock()
    }

    func addReceived(data: [UInt8], dataLength: Int) {
        lock.lock()
        _messagesReceived += 1
        _bytesReceived += dataLength + 4
        _rxThisSecond += 1
        _rxBytesThisSecond += dataLength + 4

        // Sequence tracking (first 4 bytes)
        if data.count >= 4 {
            let seq = UInt32(data[0]) << 24
                    | UInt32(data[1]) << 16
                    | UInt32(data[2]) << 8
                    | UInt32(data[3])
            if let last = _rxLastSequence {
                let expected = last &+ 1
                if seq == last {
                    _rxDuplicates += 1
                } else if seq != expected {
                    _rxSequenceGaps += 1
                    if seq < expected {
                        _rxOutOfOrder += 1
                    }
                }
            }
            _rxLastSequence = seq
        }
        lock.unlock()
    }

    func addPoll(hit: Bool, rawBytes: Int) {
        lock.lock()
        _rxPolls += 1
        if hit { _rxHits += 1; _rxRawBytes += rawBytes }
        lock.unlock()
    }

    func addDecodeFailure() {
        lock.lock()
        _rxDecodeFailures += 1
        lock.unlock()
    }

    /// Snapshot current stats (called from MainActor stats timer)
    func snapshot() -> BandwidthTestStats {
        lock.lock()
        var s = BandwidthTestStats()
        s.messagesSent = _messagesSent
        s.bytesSent = _bytesSent
        s.messagesReceived = _messagesReceived
        s.bytesReceived = _bytesReceived
        s.rxPolls = _rxPolls
        s.rxHits = _rxHits
        s.rxRawBytes = _rxRawBytes
        s.rxSequenceGaps = _rxSequenceGaps
        s.rxOutOfOrder = _rxOutOfOrder
        s.rxDuplicates = _rxDuplicates
        s.rxLastSequence = _rxLastSequence
        s.rxDecodeFailures = _rxDecodeFailures
        lock.unlock()
        return s
    }

    /// Read and reset per-second counters (called from MainActor stats timer)
    func drainPerSecondCounters() -> (tx: Int, rx: Int, txBytes: Int, rxBytes: Int) {
        lock.lock()
        let tx = _txThisSecond
        let rx = _rxThisSecond
        let txB = _txBytesThisSecond
        let rxB = _rxBytesThisSecond
        _txThisSecond = 0
        _rxThisSecond = 0
        _txBytesThisSecond = 0
        _rxBytesThisSecond = 0
        lock.unlock()
        return (tx, rx, txB, rxB)
    }

    func reset() {
        lock.lock()
        _messagesSent = 0; _bytesSent = 0
        _messagesReceived = 0; _bytesReceived = 0
        _txThisSecond = 0; _rxThisSecond = 0
        _txBytesThisSecond = 0; _rxBytesThisSecond = 0
        _rxPolls = 0; _rxHits = 0; _rxRawBytes = 0
        _rxSequenceGaps = 0; _rxOutOfOrder = 0; _rxDuplicates = 0
        _rxLastSequence = nil; _rxDecodeFailures = 0
        lock.unlock()
    }
}


struct BidirTestStats {
    var a1toA2 = BandwidthTestStats()
    var a2toA1 = BandwidthTestStats()
    var a1toA2Rate: Double = 0
    var a2toA1Rate: Double = 0
    var startTime: Date?
    
    mutating func reset() {
        self = BidirTestStats()
    }
}
