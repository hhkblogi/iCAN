/*
 * DashboardMetricsEngine.cpp — Background CAN frame reader + metrics accumulator
 *
 * A pthread continuously reads from the CANClient reader FIFO using
 * readManyBlocking(). Metrics are accumulated in atomics (counters) and
 * a mutex-protected ID histogram + recent-frame circular buffer.
 * Swift polls snapshot() every ~300ms for UI updates.
 */

#include "DashboardMetricsEngine.hpp"
#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>
#include <algorithm>
#include <cstring>

// Pre-parsed frame data prepared outside the mutex
struct ParsedFrame {
    uint32_t rawId;
    uint8_t  len;
    uint8_t  flags;
    uint8_t  channel;
    bool     isExtended;
    uint64_t timestamp_us;  // microseconds since Unix epoch (from driver)
    uint8_t  data[64];
};

class DashboardMetricsEngineImpl {
public:
    // --- Lifecycle (protected by lifecycleMutex) ---
    std::mutex lifecycleMutex;  // serializes start()/stop()
    std::atomic<bool> running{false};
    std::atomic<bool> cancelled{false};
    std::thread readerThread;

    CANClient client;

    // --- Atomic counters (hot path — updated per RX frame) ---
    std::atomic<uint64_t> totalMessages{0};
    std::atomic<uint64_t> totalBytes{0};
    std::atomic<uint32_t> secMessages{0};  // per-second, drained by drainRateCounters
    std::atomic<uint32_t> secBytes{0};

    // --- TX tracking (sampled from CANClient, not atomic — read on snapshot) ---
    uint32_t lastTxCount{0};        // last sampled txCount
    std::atomic<uint32_t> secTx{0}; // per-second TX, drained by drainRateCounters

    // startTime is protected by dataMutex (read by reader thread, written by reset())
    std::chrono::steady_clock::time_point startTime;

    // --- Mutex-protected state (updated per frame, read ~3x/sec) ---
    std::mutex dataMutex;
    // canId -> (count, isExtended, lastSeenTimestamp_us)
    struct IdInfo { uint32_t count; bool isExtended; uint64_t lastSeen_us; };
    std::unordered_map<uint32_t, IdInfo> idCounts;
    RecentFrame recentBuf[kMaxRecentFrames];
    int recentHead = 0;   // next write position
    int recentCount = 0;  // total written (capped at kMaxRecentFrames)

    void readerLoop() {
        constexpr int kBatchSize = 256;
        CANPacket packets[kBatchSize];
        ParsedFrame parsed[kBatchSize];

        while (!cancelled.load(std::memory_order_relaxed)) {
            int n = client.readManyBlocking(packets, kBatchSize, 10);  // 10ms timeout
            if (n <= 0) continue;

            // Pre-parse frames and compute byte total outside the mutex
            uint32_t batchBytes = 0;
            for (int i = 0; i < n; i++) {
                const auto& f = packets[i].frame;
                auto& p = parsed[i];
                p.rawId = f.can_id & 0x1FFFFFFFU;
                p.isExtended = (f.can_id & 0x80000000U) != 0;
                uint8_t clampedLen = f.len <= 64 ? f.len : 64;
                p.len = clampedLen;
                p.flags = f.flags;
                p.channel = f.__res0;
                p.timestamp_us = packets[i].timestamp_us;
                memcpy(p.data, f.data, clampedLen);
                if (clampedLen < 64) memset(p.data + clampedLen, 0, 64 - clampedLen);
                batchBytes += clampedLen + 4;  // payload + CAN header overhead
            }

            // Atomic counter updates (no lock needed)
            totalMessages.fetch_add(static_cast<uint64_t>(n), std::memory_order_relaxed);
            totalBytes.fetch_add(batchBytes, std::memory_order_relaxed);
            secMessages.fetch_add(static_cast<uint32_t>(n), std::memory_order_relaxed);
            secBytes.fetch_add(batchBytes, std::memory_order_relaxed);

            // Mutex-protected updates (ID map + recent buffer) — only map
            // insertion and buffer writes; parsing was done above.
            {
                std::lock_guard<std::mutex> lock(dataMutex);
                for (int i = 0; i < n; i++) {
                    const auto& p = parsed[i];
                    auto& entry = idCounts[p.rawId];
                    entry.count++;
                    entry.isExtended = p.isExtended;
                    entry.lastSeen_us = p.timestamp_us;

                    auto& rf = recentBuf[recentHead];
                    rf.canId = p.rawId;
                    rf.len = p.len;
                    rf.flags = p.flags;
                    rf.channel = p.channel;
                    rf.isExtended = p.isExtended;
                    rf.timestamp_us = p.timestamp_us;
                    memcpy(rf.data, p.data, 64);

                    recentHead = (recentHead + 1) % kMaxRecentFrames;
                    if (recentCount < kMaxRecentFrames) recentCount++;
                }
            }
        }

        running.store(false, std::memory_order_release);
    }
};

// --- Public API ---

DashboardMetricsEngine::DashboardMetricsEngine()
    : _impl(std::make_shared<DashboardMetricsEngineImpl>()) {}

DashboardMetricsEngine::~DashboardMetricsEngine() {
    stop();
}

// Copy shares the impl. The background thread (if running) stays alive as
// long as any shared_ptr to _impl exists; it self-terminates via the
// cancelled flag. Callers must call stop() on at least one copy before
// all copies are destroyed if they want a deterministic join.
DashboardMetricsEngine::DashboardMetricsEngine(const DashboardMetricsEngine& other)
    : _impl(other._impl) {}

DashboardMetricsEngine& DashboardMetricsEngine::operator=(const DashboardMetricsEngine& other) {
    if (this != &other) _impl = other._impl;
    return *this;
}

void DashboardMetricsEngine::start(CANClient client) {
    std::lock_guard<std::mutex> lock(_impl->lifecycleMutex);
    if (_impl->running.load(std::memory_order_acquire)) return;

    _impl->cancelled.store(false, std::memory_order_relaxed);
    _impl->client = client;
    {
        std::lock_guard<std::mutex> dataLock(_impl->dataMutex);
        _impl->startTime = std::chrono::steady_clock::now();
    }

    _impl->readerThread = std::thread([impl = _impl]() {
        impl->readerLoop();
    });

    // Set running after thread is successfully created
    _impl->running.store(true, std::memory_order_release);
}

void DashboardMetricsEngine::stop() {
    std::lock_guard<std::mutex> lock(_impl->lifecycleMutex);
    if (!_impl->running.load(std::memory_order_acquire)) return;
    _impl->cancelled.store(true, std::memory_order_release);
    if (_impl->readerThread.joinable())
        _impl->readerThread.join();
    _impl->running.store(false, std::memory_order_release);
}

bool DashboardMetricsEngine::isRunning() const {
    return _impl->running.load(std::memory_order_acquire);
}

DashboardSnapshot DashboardMetricsEngine::snapshot() {
    DashboardSnapshot snap{};

    snap.totalMessages = _impl->totalMessages.load(std::memory_order_relaxed);
    snap.totalBytes = _impl->totalBytes.load(std::memory_order_relaxed);
    snap.dropCount = _impl->client.dropCount();

    // Sample TX count and compute delta for per-second tracking
    uint32_t currentTx = _impl->client.txCount();
    uint32_t txDelta = currentTx - _impl->lastTxCount;
    if (txDelta > 0) {
        _impl->secTx.fetch_add(txDelta, std::memory_order_relaxed);
        _impl->lastTxCount = currentTx;
    }
    snap.totalTxFrames = currentTx;
    snap.rxReaderCount = _impl->client.rxReaderCount();
    snap.txWriterCount = _impl->client.txWriterCount();

    // Copy raw data under lock; sort and format outside lock
    struct IdEntry { uint32_t id; uint32_t count; bool isExt; };
    std::vector<IdEntry> entries;

    {
        std::lock_guard<std::mutex> lock(_impl->dataMutex);

        snap.duration = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - _impl->startTime).count();

        snap.uniqueIdCount = static_cast<int>(_impl->idCounts.size());

        // Count RX IDs active in last 30 seconds
        uint64_t now_us = 0;
        if (!_impl->idCounts.empty()) {
            // Use the most recent timestamp as "now" reference
            for (const auto& [id, info] : _impl->idCounts) {
                if (info.lastSeen_us > now_us) now_us = info.lastSeen_us;
            }
        }
        uint64_t window_us = 30ULL * 1000000ULL;  // 30 seconds
        int rxIds30s = 0;

        entries.reserve(_impl->idCounts.size());
        for (const auto& [id, info] : _impl->idCounts) {
            entries.push_back({id, info.count, info.isExtended});
            if (now_us > 0 && (now_us - info.lastSeen_us) < window_us) {
                rxIds30s++;
            }
        }
        snap.rxUniqueIds30s = rxIds30s;
        snap.txUniqueIds30s = _impl->client.txUniqueIds(30);

        // Copy recent frames (newest first)
        snap.recentFrameCount = _impl->recentCount;
        for (int i = 0; i < snap.recentFrameCount; i++) {
            int idx = (_impl->recentHead - 1 - i + kMaxRecentFrames) % kMaxRecentFrames;
            snap.recentFrames[i] = _impl->recentBuf[idx];
        }
    }
    // Mutex released — sort outside the lock
    std::partial_sort(entries.begin(),
                      entries.begin() + std::min(static_cast<int>(entries.size()), kMaxTopIds),
                      entries.end(),
                      [](const IdEntry& a, const IdEntry& b) { return a.count > b.count; });

    snap.topIdCount = std::min(static_cast<int>(entries.size()), kMaxTopIds);
    for (int i = 0; i < snap.topIdCount; i++) {
        snap.topIds[i] = {entries[i].id, entries[i].count, entries[i].isExt};
    }

    return snap;
}

DashboardRateCounters DashboardMetricsEngine::drainRateCounters() {
    return {
        _impl->secMessages.exchange(0, std::memory_order_relaxed),
        _impl->secBytes.exchange(0, std::memory_order_relaxed),
        _impl->secTx.exchange(0, std::memory_order_relaxed)
    };
}

void DashboardMetricsEngine::reset() {
    // Atomic counters: best-effort reset. If the reader thread is running
    // concurrently, a few frames may be counted between the stores below
    // and the next snapshot. This is acceptable for a UI "clear" action.
    _impl->totalMessages.store(0, std::memory_order_relaxed);
    _impl->totalBytes.store(0, std::memory_order_relaxed);
    _impl->secMessages.store(0, std::memory_order_relaxed);
    _impl->secBytes.store(0, std::memory_order_relaxed);

    std::lock_guard<std::mutex> lock(_impl->dataMutex);
    _impl->startTime = std::chrono::steady_clock::now();
    _impl->idCounts.clear();
    _impl->recentHead = 0;
    _impl->recentCount = 0;
}
