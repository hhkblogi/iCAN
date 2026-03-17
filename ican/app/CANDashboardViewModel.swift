import Foundation
import Combine
import SwiftUI
import os.log

private let dashLog = OSLog(subsystem: "com.hhkblogi.ican", category: "Dashboard")

struct PortInfo: Hashable, Identifiable {
    let name: String        // "PCAN Ch0", "SLCAN", "gs_usb", etc.
    let deviceIndex: Int    // index among all known USB CAN adapters
    let channel: Int        // 0 for single-channel adapters, 0 or 1 for PCAN

    var id: String { "\(deviceIndex):\(channel)" }
}

@MainActor
class CANDashboardViewModel: ObservableObject {
    @Published var isLive: Bool = true

    // Core Data
    @Published var metrics = CANDashboardMetrics()
    @Published var busStatuses: [BusStatus] = []
    @Published var messages: [CANLogMessage] = []
    @Published var errorCount: Int = 0
    @Published var messageDistribution: [MessageDistPoint] = []
    @Published var idDistribution: [CANIdDistribution] = []
    @Published var busLoadHistory: [BusLoadPoint] = []
    @Published var messageRateHistory: [MessageRatePoint] = []

    // Hardware State
    @Published var adapter1: SerialAdapter
    @Published var adapter2: SerialAdapter
    @Published var availablePorts: [PortInfo] = []
    @Published var selectedBitrate: CANBitrate = .kbps1000
    @Published var canFDEnabled = false
    @Published var lastError: String?
    
    // Bandwidth Test Properties
    @Published var isBandwidthTestRunning = false
    @Published var bandwidthStats = BandwidthTestStats()
    @Published var bandwidthHistory: [BandwidthHistoryPoint] = []
    @Published var testMessageSize: Int = 8
    @Published var testUseFD = false
    @Published var testBurstSize: Int = 1
    @Published var testTargetRate: Int = 4000  // msg/s per direction
    @Published var testDirection: Int = 0  // 0 = A1→A2, 1 = A2→A1
    
    // Bidirectional Test Properties
    @Published var isBidirTestRunning = false
    @Published var bidirStats = BidirTestStats()
    @Published var bidirHistory: [BidirHistoryPoint] = []
    @Published var pcanDebugLog: String = ""

    // Distributed Bidirectional Test Properties
    @Published var isDistBidirTestRunning = false
    @Published var distBidirStats = BandwidthTestStats()
    @Published var distBidirHistory: [BandwidthHistoryPoint] = []
    @Published var distBidirRole: Int = 0  // 0 = iPad 1 (TX:0x200, RX:0x201), 1 = iPad 2 (TX:0x201, RX:0x200)

    // C++ Test Engines (direct ring access, pthread + mach_wait_until)
    private var bandwidthEngine = BandwidthTestEngine()
    private var bidirEngine = BidirTestEngine()
    private var distBidirEngine = DistBidirTestEngine()

    // C++ Dashboard Metrics Engines (background reader threads)
    private var dashEngine1 = DashboardMetricsEngine()
    private var dashEngine2 = DashboardMetricsEngine()

    // Timers
    private var bandwidthStatsTimer: Timer?
    private var bidirStatsTimer: Timer?
    private var distBidirStatsTimer: Timer?
    private var snapshotTimer: Timer?

    private var bidirLastSecond = Date()
    private var bandwidthLastSecond = Date()
    private var distBidirLastSecond = Date()
    private var startTime = Date()
    private var lastRateTime = Date()
    private var cancellables = Set<AnyCancellable>()
    
    var isCANOpen: Bool {
        adapter1.isCANOpen || adapter2.isCANOpen
    }
    
    var connectionStatusColor: Color {
        if adapter1.isCANOpen || adapter2.isCANOpen {
            return .green
        } else if adapter1.isConnected || adapter2.isConnected {
            return .orange
        }
        return .red
    }
    
    var connectionStatusText: String {
        let connectedCount = (adapter1.isConnected ? 1 : 0) + (adapter2.isConnected ? 1 : 0)
        if connectedCount == 0 {
            return "Disconnected"
        }
        return "\(connectedCount) Connected"
    }
    
    init() {
        adapter1 = SerialAdapter(name: "Adapter 1", adapterIndex: 0)
        adapter2 = SerialAdapter(name: "Adapter 2", adapterIndex: 1)
        
        setupBusStatuses()
        refreshPorts()
        
        adapter1.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        
        adapter2.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        
        startDataCollection()
    }
    
    private func setupBusStatuses() {
        busStatuses = [
            BusStatus(name: "Adapter 1", messageRate: 0, messageCount: 0, busLoad: 0, isConnected: false, isActive: false),
            BusStatus(name: "Adapter 2", messageRate: 0, messageCount: 0, busLoad: 0, isConnected: false, isActive: false)
        ]
    }
    
    func refreshPorts() {
        // Scan all known CAN adapter VID/PID pairs
        let knownAdapters: [(name: String, vid: Int, pid: Int, channels: Int)] = [
            ("SLCAN",    0x16D0, 0x117E, 1),
            ("gs_usb",   0x1D50, 0x606F, 1),
            ("PCAN",     0x0C72, 0x0011, 2),  // PCAN-USB Pro FD = 2 channels
        ]

        var ports: [PortInfo] = []
        var deviceIndex = 0

        for adapter in knownAdapters {
            guard let usbMatchCF = IOServiceMatching("IOUSBHostDevice") else { continue }
            let usbMatch = usbMatchCF as NSMutableDictionary
            usbMatch["idVendor"] = adapter.vid
            usbMatch["idProduct"] = adapter.pid
            var usbIter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, usbMatch as CFDictionary, &usbIter) == KERN_SUCCESS {
                var s = IOIteratorNext(usbIter)
                while s != 0 {
                    if adapter.channels == 1 {
                        ports.append(PortInfo(name: adapter.name, deviceIndex: deviceIndex, channel: 0))
                    } else {
                        for ch in 0..<adapter.channels {
                            ports.append(PortInfo(name: "\(adapter.name) Ch\(ch)", deviceIndex: deviceIndex, channel: ch))
                        }
                    }
                    deviceIndex += 1
                    IOObjectRelease(s)
                    s = IOIteratorNext(usbIter)
                }
                IOObjectRelease(usbIter)
            }
        }

        availablePorts = ports
        if ports.count >= 1 && adapter1.selectedPort.isEmpty {
            adapter1.selectedPort = ports[0].id
            adapter1.adapterIndex = ports[0].deviceIndex
            adapter1.channel = ports[0].channel
        }
        if ports.count >= 2 && adapter2.selectedPort.isEmpty {
            adapter2.selectedPort = ports[1].id
            adapter2.adapterIndex = ports[1].deviceIndex
            adapter2.channel = ports[1].channel
        }
    }
    
    /// Connect an adapter, sharing the connection if another adapter is already
    /// connected to the same physical device (PCAN dual-channel).
    func connectAdapter(_ adapter: SerialAdapter) {
        let other = (adapter === adapter1) ? adapter2 : adapter1
        os_log(.error, log: dashLog,
               "connectAdapter(%{public}s): idx=%d ch=%d, other.connected=%d other.idx=%d other.ioClient=%{public}s",
               adapter.name, adapter.adapterIndex, adapter.channel,
               other.isConnected ? 1 : 0, other.adapterIndex,
               other.ioClient == nil ? "nil" : "ok")
        // Check if the other adapter is connected to the same physical device
        if other.isConnected,
           other.adapterIndex == adapter.adapterIndex,
           let existingClient = other.ioClient {
            os_log(.error, log: dashLog, "connectAdapter(%{public}s): using shared connection", adapter.name)
            adapter.connectShared(from: existingClient)
        } else {
            os_log(.error, log: dashLog, "connectAdapter(%{public}s): using full connect", adapter.name)
            adapter.connect()
        }
    }

    func openCANChannels() {
        openCANChannel(for: adapter1)
        openCANChannel(for: adapter2)
    }

    func closeCANChannels() {
        closeCANChannel(for: adapter1)
        closeCANChannel(for: adapter2)
    }

    func openCANChannel(for adapter: SerialAdapter) {
        guard adapter.isConnected && !adapter.isCANOpen else { return }
        adapter.openCANChannel(bitrate: selectedBitrate)
        if adapter === adapter1, let c = adapter.ioClient {
            dashEngine1 = DashboardMetricsEngine()
            dashEngine1.start(c.canClient())
        } else if adapter === adapter2, let c = adapter.ioClient {
            dashEngine2 = DashboardMetricsEngine()
            dashEngine2.start(c.canClient())
        }
        updateBusStatuses()
    }

    func closeCANChannel(for adapter: SerialAdapter) {
        guard adapter.isCANOpen else { return }
        if adapter === adapter1 { dashEngine1.stop() }
        else if adapter === adapter2 { dashEngine2.stop() }
        adapter.closeCANChannel()
        updateBusStatuses()
    }
    
    private func startDataCollection() {
        // Single snapshot timer — polls C++ engines every 300ms
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollSnapshots() }
        }
    }

    private func pollSnapshots() {
        guard isLive else { return }

        let snap1 = dashEngine1.snapshot()
        let snap2 = dashEngine2.snapshot()

        // Drain per-second rate counters
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRateTime)

        if elapsed >= 0.9 {
            let rate1 = dashEngine1.drainRateCounters()
            let rate2 = dashEngine2.drainRateCounters()

            let totalMsgRate = (Double(rate1.messages) + Double(rate2.messages)) / elapsed
            let totalByteRate = (Double(rate1.bytes) + Double(rate2.bytes)) / elapsed

            metrics.messageRate = totalMsgRate
            metrics.throughput = totalByteRate / 1024.0

            let bitsPerFrame = 130.0
            let busCapacity = max(Double(selectedBitrate.rawValue), 1.0)
            let rate1MsgSec = Double(rate1.messages) / elapsed
            let rate2MsgSec = Double(rate2.messages) / elapsed
            let bus0Load = min(rate1MsgSec * bitsPerFrame / busCapacity * 100, 100)
            let bus1Load = min(rate2MsgSec * bitsPerFrame / busCapacity * 100, 100)
            metrics.busLoad = min(totalMsgRate * bitsPerFrame / busCapacity * 100, 100)

            busStatuses[0].messageRate = rate1MsgSec
            busStatuses[1].messageRate = rate2MsgSec

            messageRateHistory.append(MessageRatePoint(timestamp: now, messageRate: totalMsgRate))
            if messageRateHistory.count > 60 { messageRateHistory.removeFirst() }

            busLoadHistory.append(BusLoadPoint(timestamp: now, bus0Load: bus0Load, bus1Load: bus1Load))
            if busLoadHistory.count > 60 { busLoadHistory.removeFirst() }

            messageDistribution.append(MessageDistPoint(timestamp: now, count: Int(rate1.messages + rate2.messages)))
            if messageDistribution.count > 30 { messageDistribution.removeFirst() }

            lastRateTime = now
        }

        // Cumulative metrics
        metrics.messagesReceived = Int(snap1.totalMessages + snap2.totalMessages)
        metrics.uptime = now.timeIntervalSince(startTime)
        metrics.activeNodes = Int(snap1.uniqueIdCount + snap2.uniqueIdCount)

        busStatuses[0].messageCount = Int(snap1.totalMessages)
        busStatuses[1].messageCount = Int(snap2.totalMessages)

        // ID distribution (top 10 from C++ snapshots)
        var combined: [CANIdDistribution] = []
        withUnsafeBytes(of: snap1.topIds) { buf in
            for i in 0..<Int(snap1.topIdCount) {
                let entry = buf.load(fromByteOffset: i * MemoryLayout<CanIdCount>.stride, as: CanIdCount.self)
                let hexId = entry.isExtended
                    ? String(format: "0x%08X", entry.canId)
                    : String(format: "0x%03X", entry.canId)
                combined.append(CANIdDistribution(canId: hexId, count: Int(entry.count)))
            }
        }
        withUnsafeBytes(of: snap2.topIds) { buf in
            for i in 0..<Int(snap2.topIdCount) {
                let entry = buf.load(fromByteOffset: i * MemoryLayout<CanIdCount>.stride, as: CanIdCount.self)
                let hexId = entry.isExtended
                    ? String(format: "0x%08X", entry.canId)
                    : String(format: "0x%03X", entry.canId)
                if let idx = combined.firstIndex(where: { $0.canId == hexId }) {
                    combined[idx] = CANIdDistribution(canId: hexId, count: combined[idx].count + Int(entry.count))
                } else {
                    combined.append(CANIdDistribution(canId: hexId, count: Int(entry.count)))
                }
            }
        }
        idDistribution = combined.sorted { $0.count > $1.count }.prefix(10).map { $0 }

        // Recent messages from C++ circular buffer
        var newMessages: [CANLogMessage] = []
        withUnsafeBytes(of: snap1.recentFrames) { buf in
            for i in 0..<min(Int(snap1.recentFrameCount), 100) {
                let rf = buf.load(fromByteOffset: i * MemoryLayout<RecentFrame>.stride, as: RecentFrame.self)
                newMessages.append(recentFrameToLogMessage(rf, adapter: "Adapter 1", snapDuration: snap1.duration))
            }
        }
        withUnsafeBytes(of: snap2.recentFrames) { buf in
            for i in 0..<min(Int(snap2.recentFrameCount), 100) {
                let rf = buf.load(fromByteOffset: i * MemoryLayout<RecentFrame>.stride, as: RecentFrame.self)
                newMessages.append(recentFrameToLogMessage(rf, adapter: "Adapter 2", snapDuration: snap2.duration))
            }
        }
        newMessages.sort { $0.timestamp > $1.timestamp }
        messages = Array(newMessages.prefix(500))

        // Network health
        if metrics.messageRate > 100 { metrics.networkHealth = "Excellent" }
        else if metrics.messageRate > 10 { metrics.networkHealth = "Good" }
        else if metrics.messagesReceived > 0 { metrics.networkHealth = "Low Traffic" }
        else { metrics.networkHealth = "No Data" }

        updateBusStatuses()
    }

    private func recentFrameToLogMessage(_ rf: RecentFrame, adapter: String, snapDuration: Double) -> CANLogMessage {
        let isExt = rf.isExtended
        let hexId = isExt
            ? String(format: "0x%08X", rf.canId)
            : String(format: "0x%03X", rf.canId)
        let dataHex = withUnsafeBytes(of: rf.data) { buf in
            (0..<Int(rf.len)).map { String(format: "%02X", buf[$0]) }.joined(separator: " ")
        }
        return CANLogMessage(
            timestamp: Date().addingTimeInterval(rf.timestampOffset - snapDuration),
            bus: adapter,
            canId: hexId,
            dlc: Int(rf.len),
            data: dataHex,
            type: isExt ? "Extended" : "Standard",
            direction: "RX"
        )
    }
    
    private func updateBusStatuses() {
        busStatuses[0].isConnected = adapter1.isConnected
        busStatuses[0].isActive = adapter1.isCANOpen
        busStatuses[0].busLoad = adapter1.isCANOpen ? metrics.busLoad : 0
        
        busStatuses[1].isConnected = adapter2.isConnected
        busStatuses[1].isActive = adapter2.isCANOpen
        busStatuses[1].busLoad = adapter2.isCANOpen ? metrics.busLoad * 0.8 : 0
    }
    
    func clearMessages() {
        dashEngine1.reset()
        dashEngine2.reset()
        messages.removeAll()
        errorCount = 0
        idDistribution.removeAll()
        messageRateHistory.removeAll()
        busLoadHistory.removeAll()
        messageDistribution.removeAll()
    }
    
    // MARK: - Tests
    
    func startBandwidthTest() {
        guard adapter1.isCANOpen && adapter2.isCANOpen else { return }
        guard !isBandwidthTestRunning && !isBidirTestRunning && !isDistBidirTestRunning else { return }

        let txAdapter = testDirection == 0 ? adapter1.ioClient : adapter2.ioClient
        let rxAdapter = testDirection == 0 ? adapter2.ioClient : adapter1.ioClient

        guard let txC = txAdapter, let rxC = rxAdapter else {
            lastError = "Adapters not available for bandwidth test"
            return
        }

        isBandwidthTestRunning = true
        bandwidthStats.reset()
        bandwidthStats.startTime = Date()
        bandwidthHistory.removeAll()
        bandwidthLastSecond = Date()

        bandwidthEngine = BandwidthTestEngine()
        bandwidthEngine.startTest(txC.canClient(), rxC.canClient(),
                                  0x100, Int32(testMessageSize), Int32(testBurstSize),
                                  testUseFD, Int32(selectedBitrate.rawValue))

        bandwidthStatsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let snap = self.bandwidthEngine.snapshot()
                self.bandwidthStats.messagesSent = Int(snap.messagesSent)
                self.bandwidthStats.bytesSent = Int(snap.bytesSent)
                self.bandwidthStats.messagesReceived = Int(snap.messagesReceived)
                self.bandwidthStats.bytesReceived = Int(snap.bytesReceived)

                self.bandwidthStats.rxPolls = Int(snap.rxPolls)
                self.bandwidthStats.rxHits = Int(snap.rxHits)
                self.bandwidthStats.rxSequenceGaps = Int(snap.rxSequenceGaps)
                self.bandwidthStats.rxOutOfOrder = Int(snap.rxOutOfOrder)
                self.bandwidthStats.rxDuplicates = Int(snap.rxDuplicates)
                self.bandwidthStats.rxDecodeFailures = Int(snap.rxDecodeFailures)
                self.bandwidthStats.duration = snap.duration

                let now = Date()
                let elapsed = now.timeIntervalSince(self.bandwidthLastSecond)
                if elapsed >= 1.0 {
                    let perSec = self.bandwidthEngine.drainPerSecondCounters()
                    self.bandwidthStats.instantTxRate = Double(perSec.tx) / elapsed
                    self.bandwidthStats.instantRxRate = Double(perSec.rx) / elapsed
                    self.bandwidthHistory.append(BandwidthHistoryPoint(timestamp: now, txRate: self.bandwidthStats.instantTxRate, rxRate: self.bandwidthStats.instantRxRate))
                    if self.bandwidthHistory.count > 60 { self.bandwidthHistory.removeFirst() }
                    self.bandwidthLastSecond = now
                }
            }
        }
    }
    
    func stopBandwidthTest() {
        bandwidthEngine.stopTest()
        bandwidthStatsTimer?.invalidate()
        bandwidthStatsTimer = nil
        isBandwidthTestRunning = false
    }
    
    func resetBandwidthStats() {
        bandwidthStats.reset()
        bandwidthHistory.removeAll()
    }
    
    func startBidirTest() {
        guard adapter1.isCANOpen && adapter2.isCANOpen else { return }
        guard !isBidirTestRunning && !isBandwidthTestRunning && !isDistBidirTestRunning else { return }

        guard let a1 = adapter1.ioClient, let a2 = adapter2.ioClient else {
            lastError = "Adapters not available for bidir test"
            return
        }

        isBidirTestRunning = true
        bidirStats.reset()
        bidirStats.startTime = Date()
        bidirHistory.removeAll()
        bidirLastSecond = Date()

        bidirEngine = BidirTestEngine()
        bidirEngine.startTest(a1.canClient(), a2.canClient(),
                              Int32(testMessageSize), Int32(testBurstSize),
                              testUseFD, Int32(selectedBitrate.rawValue),
                              Int32(testTargetRate))

        bidirStatsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let snap1 = self.bidirEngine.snapshotA1toA2()
                self.bidirStats.a1toA2.messagesSent = Int(snap1.messagesSent)
                self.bidirStats.a1toA2.messagesReceived = Int(snap1.messagesReceived)
                self.bidirStats.a1toA2.bytesSent = Int(snap1.bytesSent)
                self.bidirStats.a1toA2.bytesReceived = Int(snap1.bytesReceived)
                self.bidirStats.a1toA2.rxPolls = Int(snap1.rxPolls)
                self.bidirStats.a1toA2.rxHits = Int(snap1.rxHits)
                self.bidirStats.a1toA2.rxRawBytes = Int(snap1.rxRawBytes)
                self.bidirStats.a1toA2.rxSequenceGaps = Int(snap1.rxSequenceGaps)
                self.bidirStats.a1toA2.rxOutOfOrder = Int(snap1.rxOutOfOrder)
                self.bidirStats.a1toA2.rxDuplicates = Int(snap1.rxDuplicates)
                self.bidirStats.a1toA2.rxDecodeFailures = Int(snap1.rxDecodeFailures)
                self.bidirStats.a1toA2.duration = snap1.duration
                // PCAN codec counters (from shared ring header)
                self.bidirStats.a1toA2.codecEchoCount = Int(a2.canClient().codecEchoCount())
                self.bidirStats.a1toA2.codecOverrunCount = Int(a2.canClient().codecOverrunCount())
                self.bidirStats.a1toA2.codecTruncatedCount = Int(a2.canClient().codecTruncatedCount())
                self.bidirStats.a1toA2.codecZeroSentinelCount = Int(a2.canClient().codecZeroSentinelCount())
                self.bidirStats.a1toA2.ringRxDropped = Int(a2.canClient().dropCount())
                // Debug snapshot
                self.bidirStats.a1toA2.dbgTransferSeq = Int(a2.canClient().dbgTransferSeq())
                self.bidirStats.a1toA2.dbgTransferLen = Int(a2.canClient().dbgTransferLen())
                self.bidirStats.a1toA2.dbgMsgsParsed = Int(a2.canClient().dbgMsgsParsed())
                do {
                    var buf = [UInt8](repeating: 0, count: 48)
                    a2.canClient().dbgHead(&buf, 48)
                    let len = min(Int(a2.canClient().dbgTransferLen()), 48)
                    self.bidirStats.a1toA2.dbgHeadHex = buf.prefix(len).map { String(format: "%02X", $0) }.joined(separator: " ")
                }

                let snap2 = self.bidirEngine.snapshotA2toA1()
                self.bidirStats.a2toA1.messagesSent = Int(snap2.messagesSent)
                self.bidirStats.a2toA1.messagesReceived = Int(snap2.messagesReceived)
                self.bidirStats.a2toA1.bytesSent = Int(snap2.bytesSent)
                self.bidirStats.a2toA1.bytesReceived = Int(snap2.bytesReceived)
                self.bidirStats.a2toA1.rxPolls = Int(snap2.rxPolls)
                self.bidirStats.a2toA1.rxHits = Int(snap2.rxHits)
                self.bidirStats.a2toA1.rxRawBytes = Int(snap2.rxRawBytes)
                self.bidirStats.a2toA1.rxSequenceGaps = Int(snap2.rxSequenceGaps)
                self.bidirStats.a2toA1.rxOutOfOrder = Int(snap2.rxOutOfOrder)
                self.bidirStats.a2toA1.rxDuplicates = Int(snap2.rxDuplicates)
                self.bidirStats.a2toA1.rxDecodeFailures = Int(snap2.rxDecodeFailures)
                self.bidirStats.a2toA1.duration = snap2.duration
                // PCAN codec counters (from shared ring header)
                self.bidirStats.a2toA1.codecEchoCount = Int(a1.canClient().codecEchoCount())
                self.bidirStats.a2toA1.codecOverrunCount = Int(a1.canClient().codecOverrunCount())
                self.bidirStats.a2toA1.codecTruncatedCount = Int(a1.canClient().codecTruncatedCount())
                self.bidirStats.a2toA1.codecZeroSentinelCount = Int(a1.canClient().codecZeroSentinelCount())
                self.bidirStats.a2toA1.ringRxDropped = Int(a1.canClient().dropCount())
                // Debug snapshot
                self.bidirStats.a2toA1.dbgTransferSeq = Int(a1.canClient().dbgTransferSeq())
                self.bidirStats.a2toA1.dbgTransferLen = Int(a1.canClient().dbgTransferLen())
                self.bidirStats.a2toA1.dbgMsgsParsed = Int(a1.canClient().dbgMsgsParsed())
                do {
                    var buf = [UInt8](repeating: 0, count: 48)
                    a1.canClient().dbgHead(&buf, 48)
                    let len = min(Int(a1.canClient().dbgTransferLen()), 48)
                    self.bidirStats.a2toA1.dbgHeadHex = buf.prefix(len).map { String(format: "%02X", $0) }.joined(separator: " ")
                }

                let now = Date()
                let elapsed = now.timeIntervalSince(self.bidirLastSecond)
                if elapsed >= 1.0 {
                    let p1 = self.bidirEngine.drainPerSecondCountersA1toA2()
                    let p2 = self.bidirEngine.drainPerSecondCountersA2toA1()
                    self.bidirStats.a1toA2.instantTxRate = Double(p1.tx) / elapsed
                    self.bidirStats.a1toA2.instantRxRate = Double(p1.rx) / elapsed
                    self.bidirStats.a2toA1.instantTxRate = Double(p2.tx) / elapsed
                    self.bidirStats.a2toA1.instantRxRate = Double(p2.rx) / elapsed

                    self.bidirHistory.append(BidirHistoryPoint(
                        timestamp: now,
                        txRateA1: self.bidirStats.a1toA2.instantTxRate,
                        rxRateA1: self.bidirStats.a1toA2.instantRxRate,
                        txRateA2: self.bidirStats.a2toA1.instantTxRate,
                        rxRateA2: self.bidirStats.a2toA1.instantRxRate
                    ))
                    if self.bidirHistory.count > 60 { self.bidirHistory.removeFirst() }
                    self.bidirLastSecond = now
                }
            }
        }
    }
    
    func stopBidirTest() {
        bidirEngine.stopTest()
        bidirStatsTimer?.invalidate()
        bidirStatsTimer = nil
        isBidirTestRunning = false
    }
    
    func resetBidirStats() {
        bidirStats.reset()
        bidirHistory.removeAll()
    }

    // MARK: - Distributed Bidirectional Test

    func startDistBidirTest() {
        guard adapter1.isCANOpen else { return }
        guard !isDistBidirTestRunning && !isBandwidthTestRunning && !isBidirTestRunning else { return }

        guard let a1 = adapter1.ioClient else {
            lastError = "Adapter not available for dist bidir test"
            return
        }

        let txCanId: UInt32 = distBidirRole == 0 ? 0x200 : 0x201
        let rxCanId: UInt32 = distBidirRole == 0 ? 0x201 : 0x200

        os_log(.info, log: dashLog,
               "startDistBidirTest: role=%d txId=0x%X rxId=0x%X",
               distBidirRole, txCanId, rxCanId)

        isDistBidirTestRunning = true
        distBidirStats.reset()
        distBidirStats.startTime = Date()
        distBidirHistory.removeAll()
        distBidirLastSecond = Date()

        distBidirEngine = DistBidirTestEngine()
        distBidirEngine.startTest(a1.canClient(), txCanId, rxCanId,
                                  Int32(testMessageSize), testUseFD,
                                  Int32(selectedBitrate.rawValue))

        distBidirStatsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let snap = self.distBidirEngine.snapshot()
                self.distBidirStats.messagesSent = Int(snap.messagesSent)
                self.distBidirStats.messagesReceived = Int(snap.messagesReceived)
                self.distBidirStats.bytesSent = Int(snap.bytesSent)
                self.distBidirStats.bytesReceived = Int(snap.bytesReceived)
                self.distBidirStats.rxPolls = Int(snap.rxPolls)
                self.distBidirStats.rxHits = Int(snap.rxHits)
                self.distBidirStats.rxRawBytes = Int(snap.rxRawBytes)
                self.distBidirStats.rxSequenceGaps = Int(snap.rxSequenceGaps)
                self.distBidirStats.rxOutOfOrder = Int(snap.rxOutOfOrder)
                self.distBidirStats.rxDuplicates = Int(snap.rxDuplicates)
                self.distBidirStats.rxDecodeFailures = Int(snap.rxDecodeFailures)
                self.distBidirStats.duration = snap.duration

                let now = Date()
                let elapsed = now.timeIntervalSince(self.distBidirLastSecond)
                if elapsed >= 1.0 {
                    let perSec = self.distBidirEngine.drainPerSecondCounters()
                    self.distBidirStats.instantTxRate = Double(perSec.tx) / elapsed
                    self.distBidirStats.instantRxRate = Double(perSec.rx) / elapsed
                    self.distBidirHistory.append(BandwidthHistoryPoint(
                        timestamp: now,
                        txRate: self.distBidirStats.instantTxRate,
                        rxRate: self.distBidirStats.instantRxRate
                    ))
                    if self.distBidirHistory.count > 60 { self.distBidirHistory.removeFirst() }
                    self.distBidirLastSecond = now
                }
            }
        }
    }

    func stopDistBidirTest() {
        distBidirEngine.stopTest()
        distBidirStatsTimer?.invalidate()
        distBidirStatsTimer = nil
        isDistBidirTestRunning = false
    }

    func resetDistBidirStats() {
        distBidirStats.reset()
        distBidirHistory.removeAll()
    }
}
