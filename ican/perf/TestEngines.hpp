#ifndef TestEngines_hpp
#define TestEngines_hpp

#include "MetricsEngine.hpp"
#include "can_client.h"
#include <cstdint>
#include <memory>

// --- Test 1: Bandwidth (unidirectional TX→RX) ---
class BandwidthTestEngineImpl;
class BandwidthTestEngine {
public:
    BandwidthTestEngine();
    ~BandwidthTestEngine();
    BandwidthTestEngine(const BandwidthTestEngine&);
    BandwidthTestEngine& operator=(const BandwidthTestEngine&);

    void startTest(CANClient txClient, CANClient rxClient,
                   uint32_t canId, int messageSize, int burstSize,
                   bool useFD, int bitrate);
    void stopTest();
    BandwidthSnapshot snapshot();
    RateCounters drainPerSecondCounters();
private:
    std::shared_ptr<BandwidthTestEngineImpl> _impl;
};

// --- Test 2: Bidirectional (2 adapters, 1 iPad) ---
class BidirTestEngineImpl;
class BidirTestEngine {
public:
    BidirTestEngine();
    ~BidirTestEngine();
    BidirTestEngine(const BidirTestEngine&);
    BidirTestEngine& operator=(const BidirTestEngine&);

    void startTest(CANClient a1Client, CANClient a2Client,
                   int messageSize, int burstSize, bool useFD, int bitrate,
                   int targetRateA = 4000, int targetRateB = 4000);
    void stopTest();
    BandwidthSnapshot snapshotA1toA2();
    BandwidthSnapshot snapshotA2toA1();
    RateCounters drainPerSecondCountersA1toA2();
    RateCounters drainPerSecondCountersA2toA1();
    double deliveryRateA1toA2();
    double deliveryRateA2toA1();
    uint64_t deliveryReapedA1toA2();      // frames reaped (past grace window)
    uint64_t deliveryConfirmedA1toA2();   // of those, confirmed received
    uint64_t deliveryReapedA2toA1();
    uint64_t deliveryConfirmedA2toA1();
private:
    std::shared_ptr<BidirTestEngineImpl> _impl;
};

// --- Test 3: Distributed Bidirectional (1 adapter per iPad) ---
class DistBidirTestEngineImpl;
class DistBidirTestEngine {
public:
    DistBidirTestEngine();
    ~DistBidirTestEngine();
    DistBidirTestEngine(const DistBidirTestEngine&);
    DistBidirTestEngine& operator=(const DistBidirTestEngine&);

    void startTest(CANClient client,
                   uint32_t txCanId, uint32_t rxCanId,
                   int messageSize, bool useFD, int bitrate);
    void stopTest();
    BandwidthSnapshot snapshot();
    RateCounters drainPerSecondCounters();
private:
    std::shared_ptr<DistBidirTestEngineImpl> _impl;
};

#endif /* TestEngines_hpp */
