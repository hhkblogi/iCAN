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

class DashboardMetricsEngineImpl {
public:
    // --- Lifecycle ---
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

        while (!cancelled.load(std::memory_order_relaxed)) {
            int n = client.readManyBlocking(frames, kBatchSize, 10);  // 10ms timeout
            if (n <= 0) continue;

            auto now = std::chrono::steady_clock::now();
            double elapsed = std::chrono::duration<double>(now - startTime).count();

            // Atomic counter updates (no lock needed)
            totalMessages.fetch_add(static_cast<uint64_t>(n), std::memory_order_relaxed);

            uint32_t batchBytes = 0;
            for (int i = 0; i < n; i++) {
                batchBytes += frames[i].len + 4;  // payload + CAN header overhead
            }
            totalBytes.fetch_add(batchBytes, std::memory_order_relaxed);
            secMessages.fetch_add(static_cast<uint32_t>(n), std::memory_order_relaxed);
            secBytes.fetch_add(batchBytes, std::memory_order_relaxed);

            // Mutex-protected updates (ID map + recent buffer)
            {
                std::lock_guard<std::mutex> lock(dataMutex);
                for (int i = 0; i < n; i++) {
                    const auto& f = frames[i];
                    uint32_t rawId = f.can_id & 0x1FFFFFFFU;
                    bool isExt = (f.can_id & 0x80000000U) != 0;
                    auto& entry = idCounts[rawId];
                    entry.first++;
                    entry.second = isExt;

                    // Circular recent-frame buffer
                    auto& rf = recentBuf[recentHead];
                    rf.canId = rawId;
                    rf.len = f.len;
                    rf.flags = f.flags;
                    rf.channel = f.__res0;
                    rf.timestampOffset = elapsed;
                    uint8_t copyLen = f.len <= 64 ? f.len : 64;
                    memcpy(rf.data, f.data, copyLen);
                    if (copyLen < 64) memset(rf.data + copyLen, 0, 64 - copyLen);

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

DashboardMetricsEngine::DashboardMetricsEngine(const DashboardMetricsEngine& other)
    : _impl(other._impl) {}

DashboardMetricsEngine& DashboardMetricsEngine::operator=(const DashboardMetricsEngine& other) {
    if (this != &other) _impl = other._impl;
    return *this;
}

void DashboardMetricsEngine::start(CANClient client, int adapterIndex) {
    if (_impl->running.load(std::memory_order_acquire)) return;

    _impl->cancelled.store(false, std::memory_order_relaxed);
    _impl->client = client;
    _impl->adapterIndex = adapterIndex;
    _impl->startTime = std::chrono::steady_clock::now();
    _impl->running.store(true, std::memory_order_release);

    _impl->readerThread = std::thread([impl = _impl]() {
        impl->readerLoop();
    });
}

void DashboardMetricsEngine::stop() {
    if (!_impl->running.load(std::memory_order_acquire)) return;
    _impl->cancelled.store(true, std::memory_order_release);
    if (_impl->readerThread.joinable())
        _impl->readerThread.join();
}

bool DashboardMetricsEngine::isRunning() const {
    return _impl->running.load(std::memory_order_acquire);
}

DashboardSnapshot DashboardMetricsEngine::snapshot() {
    DashboardSnapshot snap{};

    auto now = std::chrono::steady_clock::now();
    snap.totalMessages = _impl->totalMessages.load(std::memory_order_relaxed);
    snap.totalBytes = _impl->totalBytes.load(std::memory_order_relaxed);
    snap.duration = std::chrono::duration<double>(now - _impl->startTime).count();
    snap.dropCount = _impl->client.dropCount();

    // Copy ID distribution + recent frames under lock
    {
        std::lock_guard<std::mutex> lock(_impl->dataMutex);

        snap.uniqueIdCount = static_cast<int>(_impl->idCounts.size());

        // Build top-N by count
        struct IdEntry { uint32_t id; uint32_t count; bool isExt; };
        std::vector<IdEntry> entries;
        entries.reserve(_impl->idCounts.size());
        for (auto& [id, val] : _impl->idCounts) {
            entries.push_back({id, val.first, val.second});
        }
        std::partial_sort(entries.begin(),
                          entries.begin() + std::min(static_cast<int>(entries.size()), kMaxTopIds),
                          entries.end(),
                          [](const IdEntry& a, const IdEntry& b) { return a.count > b.count; });

        snap.topIdCount = std::min(static_cast<int>(entries.size()), kMaxTopIds);
        for (int i = 0; i < snap.topIdCount; i++) {
            snap.topIds[i] = {entries[i].id, entries[i].count, entries[i].isExt};
        }

        // Copy recent frames (newest first)
        snap.recentFrameCount = _impl->recentCount;
        for (int i = 0; i < snap.recentFrameCount; i++) {
            int idx = (_impl->recentHead - 1 - i + kMaxRecentFrames) % kMaxRecentFrames;
            snap.recentFrames[i] = _impl->recentBuf[idx];
        }
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
    _impl->totalMessages.store(0, std::memory_order_relaxed);
    _impl->totalBytes.store(0, std::memory_order_relaxed);
    _impl->secMessages.store(0, std::memory_order_relaxed);
    _impl->secBytes.store(0, std::memory_order_relaxed);
    _impl->startTime = std::chrono::steady_clock::now();

    std::lock_guard<std::mutex> lock(_impl->dataMutex);
    _impl->idCounts.clear();
    _impl->recentHead = 0;
    _impl->recentCount = 0;
}
