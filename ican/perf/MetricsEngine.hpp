#ifndef MetricsEngine_hpp
#define MetricsEngine_hpp

#include <cstdint>
#include <memory>

struct BandwidthSnapshot {
    uint32_t messagesSent;
    uint32_t bytesSent;
    uint32_t messagesReceived;
    uint32_t bytesReceived;
    
    uint32_t rxPolls;
    uint32_t rxHits;
    uint32_t rxRawBytes;
    
    uint32_t rxSequenceGaps;
    uint32_t rxOutOfOrder;
    uint32_t rxDuplicates;
    uint32_t rxDecodeFailures;
    uint64_t rxLastSequence;

    double duration;
};

struct RateCounters {
    uint32_t tx;
    uint32_t txBytes;
    uint32_t rx;
    uint32_t rxBytes;
    uint32_t seqGaps;    // per-second sequence gaps (missing frames)
};

class MetricsEngineImpl;

class MetricsEngine {
public:
    MetricsEngine();
    ~MetricsEngine();
    
    // Make copyable for Swift value-type semantics
    MetricsEngine(const MetricsEngine& other);
    MetricsEngine& operator=(const MetricsEngine& other);

    void reset();
    void cancel();
    bool isCancelled() const;
    
    void addSent(uint32_t messages, uint32_t bytes);
    void addPoll(bool hit, uint32_t rawBytes);
    void addReceived(const uint8_t* data, uint32_t length);
    void addDecodeFailure();
    
    BandwidthSnapshot snapshot();
    RateCounters drainPerSecondCounters();

private:
    std::shared_ptr<MetricsEngineImpl> _impl;
};

#endif /* MetricsEngine_hpp */
