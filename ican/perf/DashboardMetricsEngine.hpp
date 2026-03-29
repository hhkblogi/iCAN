#ifndef DashboardMetricsEngine_hpp
#define DashboardMetricsEngine_hpp

#include "can_client.h"
#include <cstdint>
#include <memory>

// CAN ID distribution entry
struct CanIdCount {
    uint32_t canId;
    uint32_t count;
    bool     isExtended;
};

// A recent CAN frame for the message log
struct RecentFrame {
    uint32_t canId;
    uint8_t  len;
    uint8_t  flags;
    uint8_t  channel;
    bool     isExtended;
    uint8_t  data[64];
    uint64_t timestamp_us;  // microseconds since Unix epoch (driver RX time)
};

static constexpr int kMaxTopIds       = 16;
static constexpr int kMaxRecentFrames = 200;

// Full dashboard snapshot — polled by Swift every ~300ms
struct DashboardSnapshot {
    // Cumulative metrics
    uint64_t totalMessages;      // RX frames received
    uint64_t totalBytes;         // RX bytes
    uint32_t totalTxFrames;      // TX frames written (app-side)
    int      rxReaderCount;      // active RX reader clients
    int      txWriterCount;      // active TX writer clients
    double   duration;           // seconds since start
    uint32_t dropCount;          // driver-side ring drops

    // Top CAN IDs by count
    CanIdCount topIds[kMaxTopIds];
    int        topIdCount;       // actual entries (0..kMaxTopIds)
    int        uniqueIdCount;    // total distinct CAN IDs seen

    // Recent frames (newest first)
    RecentFrame recentFrames[kMaxRecentFrames];
    int         recentFrameCount;
};

// Per-second rate counters (drained atomically)
struct DashboardRateCounters {
    uint32_t messages;      // RX
    uint32_t bytes;         // RX
    uint32_t txMessages;    // TX
};

class DashboardMetricsEngineImpl;

class DashboardMetricsEngine {
public:
    DashboardMetricsEngine();
    ~DashboardMetricsEngine();

    DashboardMetricsEngine(const DashboardMetricsEngine&);
    DashboardMetricsEngine& operator=(const DashboardMetricsEngine&);

    /// Start background reader thread. Client must be open with CAN channel active.
    void start(CANClient client);

    /// Stop and join background thread.
    void stop();

    bool isRunning() const;

    /// Poll a consistent snapshot (called from main thread ~3x/sec).
    DashboardSnapshot snapshot();

    /// Drain per-second rate counters (atomic exchange).
    DashboardRateCounters drainRateCounters();

    /// Reset all accumulators.
    void reset();

private:
    std::shared_ptr<DashboardMetricsEngineImpl> _impl;
};

#endif /* DashboardMetricsEngine_hpp */
