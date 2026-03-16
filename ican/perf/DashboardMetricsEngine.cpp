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
    double   timestamp;
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
    int adapterIndex = 0;

    // --- Atomic counters (hot path — updated per frame) ---
    std::atomic<uint64_t> totalMessages{0};
    std::atomic<uint64_t> totalBytes{0};
    std::atomic<uint32_t> secMessages{0};  // per-second, drained by drainRateCounters
    std::atomic<uint32_t> secBytes{0};

    // startTime is protected by dataMutex (read by reader thread, written by reset())
    std::chrono::steady_clock::time_point startTime;

    // --- Mutex-protected state (updated per frame, read ~3x/sec) ---
    std::mutex dataMutex;
    std::unordered_map<uint32_t, std::pair<uint32_t, bool>> idCounts;  // canId -> (count, isExtended)
    RecentFrame recentBuf[kMaxRecentFrames];
    int recentHead = 0;   // next write position
    int recentCount = 0;  // total written (capped at kMaxRecentFrames)

    void readerLoop() {
        constexpr int kBatchSize = 256;
        canfd_frame frames[kBatchSize];
        ParsedFrame parsed[kBatchSize];

        while (!cancelled.load(std::memory_order_relaxed)) {
            int n = client.readManyBlocking(frames, kBatchSize, 10);  // 10ms timeout
            if (n <= 0) continue;

            double elapsed;
            {
                std::lock_guard<std::mutex> lock(dataMutex);
                elapsed = std::chrono::duration<double>(
                    std::chrono::steady_clock::now() - startTime).count();
            }

            // Pre-parse frames and compute byte total outside the mutex
            uint32_t batchBytes = 0;
            for (int i = 0; i < n; i++) {
                const auto& f = frames[i];
                auto& p = parsed[i];
                p.rawId = f.can_id & 0x1FFFFFFFU;
                p.isExtended = (f.can_id & 0x80000000U) != 0;
                uint8_t clampedLen = f.len <= 64 ? f.len : 64;
                p.len = clampedLen;
                p.flags = f.flags;
                p.channel = f.__res0;
                p.timestamp = elapsed;
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
                    entry.first++;
                    entry.second = p.isExtended;

                    auto& rf = recentBuf[recentHead];
                    rf.canId = p.rawId;
                    rf.len = p.len;
                    rf.flags = p.flags;
                    rf.channel = p.channel;
                    rf.isExtended = p.isExtended;
                    rf.timestampOffset = p.timestamp;
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

void DashboardMetricsEngine::start(CANClient client, int adapterIndex) {
    std::lock_guard<std::mutex> lock(_impl->lifecycleMutex);
    if (_impl->running.load(std::memory_order_acquire)) return;

    _impl->cancelled.store(false, std::memory_order_relaxed);
    _impl->client = client;
    _impl->adapterIndex = adapterIndex;
    _impl->startTime = std::chrono::steady_clock::now();

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

    // Copy raw data under lock; sort and format outside lock
    struct IdEntry { uint32_t id; uint32_t count; bool isExt; };
    std::vector<IdEntry> entries;

    {
        std::lock_guard<std::mutex> lock(_impl->dataMutex);

        snap.duration = std::chrono::duration<double>(
            std::chrono::steady_clock::now() - _impl->startTime).count();

        snap.uniqueIdCount = static_cast<int>(_impl->idCounts.size());

        entries.reserve(_impl->idCounts.size());
        for (const auto& [id, val] : _impl->idCounts) {
            entries.push_back({id, val.first, val.second});
        }

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
        _impl->secBytes.exchange(0, std::memory_order_relaxed)
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
