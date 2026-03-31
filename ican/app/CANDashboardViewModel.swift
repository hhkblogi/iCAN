import Foundation
import Combine
import SwiftUI
import os.log

private let dashLog = OSLog(subsystem: "com.hhkblogi.ican", category: "Dashboard")

struct CANInterface: Hashable, Identifiable {
    let interfaceName: String  // "can0", "can1", "can2", ...
    let codec: String          // "slcan", "gs_usb", "pcan"
    let adapterName: String    // "CANable", "candleLight", "PCAN-USB Pro FD"
    let deviceIndex: Int       // index among all known USB CAN adapters
    let channel: Int           // 0 for single-channel, 0 or 1 for multi-channel

    var id: String { "\(deviceIndex):\(channel)" }
}

// For grouping interfaces by USB adapter in the UI
struct USBAdapter: Identifiable {
    let name: String
    let deviceIndex: Int
    let interfaces: [CANInterface]

    var id: Int { deviceIndex }
}

@MainActor
class CANDashboardViewModel: ObservableObject {
    @Published var isLive: Bool = true

    // Core Data
    @Published var metrics = CANDashboardMetrics()
    @Published var busStatuses: [BusStatus] = []
    @Published var messages: [CANLogMessage] = []
    @Published var messageInterfaceFilter: String = "All"
    @Published var dashboardInterfaceFilter: String = "All"
    @Published var errorCount: Int = 0
    @Published var messageDistribution: [MessageDistPoint] = []
    @Published var idDistribution: [CANIdDistribution] = []
    @Published var busLoadHistory: [BusLoadPoint] = []
    @Published var messageRateHistory: [MessageRatePoint] = []

    // Hardware State — dynamic N adapters
    @Published var adapters: [SerialAdapter] = []
    @Published var availableInterfaces: [CANInterface] = []
    @Published var usbAdapters: [USBAdapter] = []
    @Published var selectedBitrate: CANBitrate = .kbps1000
    @Published var canFDEnabled = false
    @Published var lastError: String?

    // Test Interface Selection (user picks which interfaces to use)
    // Bidirectional test — -1 means "not selected"
    @Published var bidirInterfaceAIndex: Int = -1
    @Published var bidirInterfaceBIndex: Int = -1
    @Published var bidirTargetRateA: Int = 4000
    @Published var bidirTargetRateB: Int = 4000

    // Bidirectional Test Properties
    @Published var isBidirTestRunning = false
    @Published var bidirStats = BidirTestStats()
    @Published var bidirHistory: [BidirHistoryPoint] = []
    @Published var pcanDebugLog: String = ""

    // C++ Test Engine (direct ring access, pthread + mach_wait_until)
    private var bidirEngine = BidirTestEngine()

    // C++ Dashboard Metrics Engines (one per adapter, background reader threads)
    private var dashEngines: [DashboardMetricsEngine] = []

    // Timers
    private var bidirStatsTimer: Timer?
    private var snapshotTimer: Timer?

    private var bidirLastSecond = Date()
    private var startTime = Date()
    private var lastRateTime = Date()
    private var cancellables = Set<AnyCancellable>()

    var isCANOpen: Bool {
        adapters.contains { $0.isCANOpen }
    }

    var connectionStatusColor: Color {
        if adapters.contains(where: { $0.isCANOpen }) {
            return .green
        } else if adapters.contains(where: { $0.isConnected }) {
            return .orange
        }
        return .red
    }

    var connectionStatusText: String {
        let openCount = adapters.filter { $0.isCANOpen }.count
        let totalCount = adapters.count
        if totalCount == 0 {
            return "No Interfaces"
        }
        return "\(openCount) / \(totalCount)"
    }

    init() {
        refreshPorts()
        setupBusStatuses()
        startDataCollection()
    }

    private func setupBusStatuses() {
        busStatuses = adapters.map { adapter in
            BusStatus(name: adapter.name, messageRate: 0, messageCount: 0, busLoad: 0, isConnected: false, isActive: false)
        }
    }

    func refreshPorts() {
        // Scan all known CAN adapter VID/PID pairs
        let knownAdapters: [(adapterName: String, codec: String, vid: Int, pid: Int, channels: Int)] = [
            ("CANable",          "slcan",  0x16D0, 0x117E, 1),
            ("candleLight",      "gs_usb", 0x1D50, 0x606F, 1),
            ("PCAN-USB Pro FD",  "pcan",   0x0C72, 0x0011, 2),
        ]

        var interfaces: [CANInterface] = []
        var usbAdapterList: [USBAdapter] = []
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
                    var adapterInterfaces: [CANInterface] = []
                    for ch in 0..<adapter.channels {
                        let iface = CANInterface(
                            interfaceName: "can\(canIndex)",
                            codec: adapter.codec,
                            adapterName: adapter.adapterName,
                            deviceIndex: deviceIndex,
                            channel: ch
                        )
                        interfaces.append(iface)
                        adapterInterfaces.append(iface)
                        canIndex += 1
                    }
                    usbAdapterList.append(USBAdapter(
                        name: adapter.adapterName,
                        deviceIndex: deviceIndex,
                        interfaces: adapterInterfaces
                    ))
                    deviceIndex += 1
                    IOObjectRelease(s)
                    s = IOIteratorNext(usbIter)
                }
                IOObjectRelease(usbIter)
            }
        }

        availableInterfaces = interfaces
        usbAdapters = usbAdapterList

        // Build adapters array: one SerialAdapter per discovered interface.
        // Preserve existing adapters that match (by selectedPort) to keep connection state.
        var newAdapters: [SerialAdapter] = []
        for iface in interfaces {
            if let existing = adapters.first(where: { $0.selectedPort == iface.id }) {
                newAdapters.append(existing)
            } else {
                let sa = SerialAdapter(name: iface.interfaceName, adapterIndex: iface.deviceIndex, channel: iface.channel)
                sa.selectedPort = iface.id
                newAdapters.append(sa)
            }
        }

        // Unsubscribe old, set new adapters, resubscribe
        cancellables.removeAll()

        // Rebuild dash engines: reuse existing engines for preserved adapters
        // that have an active CAN channel, create new ones otherwise.
        var newEngines: [DashboardMetricsEngine] = []
        for newAdapter in newAdapters {
            if let oldIdx = adapters.firstIndex(where: { $0 === newAdapter }),
               oldIdx < dashEngines.count,
               newAdapter.isCANOpen {
                // Preserve running engine for this adapter
                newEngines.append(dashEngines[oldIdx])
            } else {
                newEngines.append(DashboardMetricsEngine())
            }
        }

        adapters = newAdapters
        dashEngines = newEngines

        for adapter in adapters {
            adapter.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }.store(in: &cancellables)
        }

        setupBusStatuses()

        // Clamp test interface indices to valid range
        if adapters.count > 0 {
            let maxIdx = adapters.count - 1
            if bidirInterfaceAIndex >= 0 { bidirInterfaceAIndex = min(bidirInterfaceAIndex, maxIdx) }
            if bidirInterfaceBIndex >= 0 { bidirInterfaceBIndex = min(bidirInterfaceBIndex, maxIdx) }
            if bidirInterfaceAIndex >= 0 && bidirInterfaceAIndex == bidirInterfaceBIndex && adapters.count > 1 {
                bidirInterfaceBIndex = bidirInterfaceAIndex == 0 ? 1 : 0
            }
        } else {
            bidirInterfaceAIndex = -1
            bidirInterfaceBIndex = -1
        }

        // Reset filters if selected interface no longer exists
        if messageInterfaceFilter != "All" &&
           !adapters.contains(where: { $0.name == messageInterfaceFilter }) {
            messageInterfaceFilter = "All"
        }
        if dashboardInterfaceFilter != "All" &&
           !adapters.contains(where: { $0.name == dashboardInterfaceFilter }) {
            dashboardInterfaceFilter = "All"
        }
    }

    /// Returns the SerialAdapter assigned to a given interface, or nil.
    func adapterForInterface(_ iface: CANInterface) -> SerialAdapter? {
        adapters.first { $0.selectedPort == iface.id }
    }

    /// Connect an adapter, sharing the connection if another adapter is already
    /// connected to the same physical device (PCAN dual-channel).
    func connectAdapter(_ adapter: SerialAdapter) {
        // Find another adapter on the same physical device that is already connected
        let other = adapters.first { $0 !== adapter && $0.isConnected && $0.adapterIndex == adapter.adapterIndex }
        os_log(.error, log: dashLog,
               "connectAdapter(%{public}s): idx=%d ch=%d, other=%{public}s",
               adapter.name, adapter.adapterIndex, adapter.channel,
               other?.name ?? "nil")
        // Check if the other adapter is connected to the same physical device
        if let other = other, let existingClient = other.ioClient {
            os_log(.error, log: dashLog, "connectAdapter(%{public}s): using shared connection", adapter.name)
            adapter.connectShared(from: existingClient)
        } else {
            os_log(.error, log: dashLog, "connectAdapter(%{public}s): using full connect", adapter.name)
            adapter.connect()
        }
    }

    func openCANChannels() {
        for adapter in adapters {
            openCANChannel(for: adapter)
        }
    }

    func closeCANChannels() {
        for adapter in adapters {
            closeCANChannel(for: adapter)
        }
    }

    func openCANChannel(for adapter: SerialAdapter) {
        guard adapter.isConnected && !adapter.isCANOpen else { return }
        adapter.openCANChannel(bitrate: adapter.selectedBitrate)
        if let idx = adapters.firstIndex(where: { $0 === adapter }), let c = adapter.ioClient {
            dashEngines[idx] = DashboardMetricsEngine()
            dashEngines[idx].start(c.canClient())
        }
        updateBusStatuses()
    }

    func closeCANChannel(for adapter: SerialAdapter) {
        guard adapter.isCANOpen else { return }
        if let idx = adapters.firstIndex(where: { $0 === adapter }) {
            dashEngines[idx].stop()
        }
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

        // Collect snapshots from all engines (indexed access required for mutating C++ methods)
        let snapshots = (0..<dashEngines.count).map { dashEngines[$0].snapshot() }

        // Drain per-second rate counters
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRateTime)

        if elapsed >= 0.9 {
            let rates = (0..<dashEngines.count).map { dashEngines[$0].drainRateCounters() }

            let totalMsgRate = rates.reduce(0.0) { $0 + Double($1.messages) } / elapsed
            let totalByteRate = rates.reduce(0.0) { $0 + Double($1.bytes) } / elapsed

            metrics.messageRate = totalMsgRate
            metrics.throughput = totalByteRate / 1024.0

            let bitsPerFrame = 130.0

            // Per-bus load and rate
            var busLoads: [Double] = []
            for i in 0..<adapters.count {
                let capacity = max(Double(adapters[i].selectedBitrate.rawValue), 1.0)
                let rateMsgSec = Double(rates[i].messages) / elapsed
                let load = min(rateMsgSec * bitsPerFrame / capacity * 100, 100)
                busLoads.append(load)
                if i < busStatuses.count {
                    busStatuses[i].messageRate = rateMsgSec
                    busStatuses[i].txRate = Double(rates[i].txMessages) / elapsed
                }
            }
            metrics.busLoad = busLoads.max() ?? 0

            messageRateHistory.append(MessageRatePoint(timestamp: now, messageRate: totalMsgRate))
            if messageRateHistory.count > 60 { messageRateHistory.removeFirst() }

            // Bus load history: use first two buses for chart compatibility, zero-fill if fewer
            let bus0Load = busLoads.count > 0 ? busLoads[0] : 0
            let bus1Load = busLoads.count > 1 ? busLoads[1] : 0
            busLoadHistory.append(BusLoadPoint(timestamp: now, bus0Load: bus0Load, bus1Load: bus1Load))
            if busLoadHistory.count > 60 { busLoadHistory.removeFirst() }

            let totalMessages = rates.reduce(UInt64(0)) { $0 + UInt64($1.messages) }
            messageDistribution.append(MessageDistPoint(timestamp: now, count: Int(totalMessages)))
            if messageDistribution.count > 30 { messageDistribution.removeFirst() }

            lastRateTime = now
        }

        // Cumulative metrics
        let totalMessages = snapshots.reduce(UInt64(0)) { $0 + $1.totalMessages }
        let totalUniqueIds = snapshots.reduce(UInt32(0)) { $0 + UInt32($1.uniqueIdCount) }
        metrics.messagesReceived = Int(totalMessages)
        metrics.uptime = now.timeIntervalSince(startTime)
        metrics.activeNodes = Int(totalUniqueIds)

        for i in 0..<min(snapshots.count, busStatuses.count) {
            busStatuses[i].messageCount = Int(snapshots[i].totalMessages)
            busStatuses[i].rxReaderCount = Int(snapshots[i].rxReaderCount)
            busStatuses[i].txWriterCount = Int(snapshots[i].txWriterCount)
            busStatuses[i].rxUniqueIds30s = Int(snapshots[i].rxUniqueIds30s)
            busStatuses[i].txUniqueIds30s = Int(snapshots[i].txUniqueIds30s)
        }

        // ID distribution (top 10 from C++ snapshots)
        var combined: [CANIdDistribution] = []
        for snap in snapshots {
            withUnsafeBytes(of: snap.topIds) { buf in
                for i in 0..<Int(snap.topIdCount) {
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
        }
        idDistribution = combined.sorted { $0.count > $1.count }.prefix(10).map { $0 }

        // Recent messages from C++ circular buffers
        var newMessages: [CANLogMessage] = []
        for (i, snap) in snapshots.enumerated() {
            let adapterName = i < adapters.count ? adapters[i].name : "can\(i)"
            withUnsafeBytes(of: snap.recentFrames) { buf in
                for j in 0..<min(Int(snap.recentFrameCount), 100) {
                    let rf = buf.load(fromByteOffset: j * MemoryLayout<RecentFrame>.stride, as: RecentFrame.self)
                    newMessages.append(recentFrameToLogMessage(rf, adapter: adapterName, snapDuration: snap.duration))
                }
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
        // Convert driver-captured Unix microsecond timestamp to Date
        let timestamp = Date(timeIntervalSince1970: Double(rf.timestamp_us) / 1_000_000.0)
        return CANLogMessage(
            timestamp: timestamp,
            bus: adapter,
            canId: hexId,
            dlc: Int(rf.len),
            data: dataHex,
            type: isExt ? "Extended" : "Standard",
            direction: "RX"
        )
    }

    private func updateBusStatuses() {
        for i in 0..<min(adapters.count, busStatuses.count) {
            busStatuses[i].isConnected = adapters[i].isConnected
            busStatuses[i].isActive = adapters[i].isCANOpen
            busStatuses[i].busLoad = adapters[i].isCANOpen ? metrics.busLoad : 0
        }
    }

    func clearMessages() {
        for i in 0..<dashEngines.count {
            dashEngines[i].reset()
        }
        messages.removeAll()
        errorCount = 0
        idDistribution.removeAll()
        messageRateHistory.removeAll()
        busLoadHistory.removeAll()
        messageDistribution.removeAll()
    }

    // MARK: - Tests

    /// Selected bidirectional test interfaces (user-configurable via Interface A/B pickers).
    var bidirAdapterA: SerialAdapter? {
        guard bidirInterfaceAIndex >= 0 && bidirInterfaceAIndex < adapters.count else { return nil }
        return adapters[bidirInterfaceAIndex]
    }
    var bidirAdapterB: SerialAdapter? {
        guard bidirInterfaceBIndex >= 0 && bidirInterfaceBIndex < adapters.count else { return nil }
        return adapters[bidirInterfaceBIndex]
    }

    /// Whether both selected bidirectional test interfaces are CAN-open and different.
    var bothBidirAdaptersReady: Bool {
        guard let a = bidirAdapterA, let b = bidirAdapterB else { return false }
        return a.isCANOpen && b.isCANOpen && bidirInterfaceAIndex != bidirInterfaceBIndex
    }

    /// Whether any test is currently running.
    var anyTestRunning: Bool {
        isBidirTestRunning
    }

    func startBidirTest() {
        guard bothBidirAdaptersReady else { return }
        guard let a1 = bidirAdapterA, let a2 = bidirAdapterB else { return }
        guard !anyTestRunning else { return }

        guard let c1 = a1.ioClient, let c2 = a2.ioClient else {
            lastError = "Interfaces not available for bidir test"
            return
        }

        isBidirTestRunning = true
        bidirStats.reset()
        bidirStats.startTime = Date()
        bidirHistory.removeAll()
        bidirLastSecond = Date()

        bidirEngine = BidirTestEngine()
        bidirEngine.startTest(c1.canClient(), c2.canClient(),
                              8, 1,
                              false, Int32(selectedBitrate.rawValue),
                              Int32(bidirTargetRateA), Int32(bidirTargetRateB))

        bidirStatsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let c1 = self.bidirAdapterA?.ioClient, let c2 = self.bidirAdapterB?.ioClient else { return }
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
                self.bidirStats.a1toA2.codecEchoCount = Int(c2.canClient().codecEchoCount())
                self.bidirStats.a1toA2.codecOverrunCount = Int(c2.canClient().codecOverrunCount())
                self.bidirStats.a1toA2.codecTruncatedCount = Int(c2.canClient().codecTruncatedCount())
                self.bidirStats.a1toA2.codecZeroSentinelCount = Int(c2.canClient().codecZeroSentinelCount())
                self.bidirStats.a1toA2.ringRxDropped = Int(c2.canClient().dropCount())
                // Debug snapshot
                self.bidirStats.a1toA2.dbgTransferSeq = Int(c2.canClient().dbgTransferSeq())
                self.bidirStats.a1toA2.dbgTransferLen = Int(c2.canClient().dbgTransferLen())
                self.bidirStats.a1toA2.dbgMsgsParsed = Int(c2.canClient().dbgMsgsParsed())
                do {
                    var buf = [UInt8](repeating: 0, count: 48)
                    c2.canClient().dbgHead(&buf, 48)
                    let len = min(Int(c2.canClient().dbgTransferLen()), 48)
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
                self.bidirStats.a2toA1.codecEchoCount = Int(c1.canClient().codecEchoCount())
                self.bidirStats.a2toA1.codecOverrunCount = Int(c1.canClient().codecOverrunCount())
                self.bidirStats.a2toA1.codecTruncatedCount = Int(c1.canClient().codecTruncatedCount())
                self.bidirStats.a2toA1.codecZeroSentinelCount = Int(c1.canClient().codecZeroSentinelCount())
                self.bidirStats.a2toA1.ringRxDropped = Int(c1.canClient().dropCount())
                // Debug snapshot
                self.bidirStats.a2toA1.dbgTransferSeq = Int(c1.canClient().dbgTransferSeq())
                self.bidirStats.a2toA1.dbgTransferLen = Int(c1.canClient().dbgTransferLen())
                self.bidirStats.a2toA1.dbgMsgsParsed = Int(c1.canClient().dbgMsgsParsed())
                do {
                    var buf = [UInt8](repeating: 0, count: 48)
                    c1.canClient().dbgHead(&buf, 48)
                    let len = min(Int(c1.canClient().dbgTransferLen()), 48)
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

}
