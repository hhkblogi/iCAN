#include "TestEngines.hpp"
#include <atomic>
#include <cstring>
#include <pthread.h>
#include <unistd.h>
#include <mach/mach_time.h>

// ============================================================
// Shared helpers
// ============================================================

static mach_timebase_info_data_t sTimebaseInfo;

static void ensureTimebase() {
    if (sTimebaseInfo.denom == 0)
        mach_timebase_info(&sTimebaseInfo);
}

/// Convert nanoseconds to mach absolute time ticks.
static uint64_t nanosToAbs(uint64_t nanos) {
    ensureTimebase();
    return nanos * sTimebaseInfo.denom / sTimebaseInfo.numer;
}

/// Build a CAN frame with big-endian counter + padding.
/// Always builds canfd_frame (classic CAN uses len<=8, flags==0).
static canfd_frame buildFrame(uint64_t counter, uint32_t canId, int msgSize, bool fd) {
    canfd_frame f;
    memset(&f, 0, sizeof(f));
    f.can_id = canId;
    f.len = (uint8_t)msgSize;
    f.flags = fd ? (CANFD_BRS | CANFD_FDF) : 0;

    // Big-endian counter in first 8 bytes
    int seqBytes = msgSize < 8 ? msgSize : 8;
    for (int i = 0; i < seqBytes; i++) {
        f.data[i] = (uint8_t)((counter >> (56 - i * 8)) & 0xFF);
    }
    // Padding bytes
    for (int i = 8; i < msgSize && i < CANFD_MAX_DLEN; i++) {
        f.data[i] = (uint8_t)((i - 8) & 0xFF);
    }

    return f;
}

// ============================================================
// Test 1: BandwidthTestEngine
// ============================================================

class BandwidthTestEngineImpl {
public:
    MetricsEngine engine;
    std::atomic<bool> cancelled{false};
    pthread_t txThread{};
    pthread_t rxThread{};
    bool threadsRunning{false};

    // Config (set before threads start)
    CANClient txClient;
    CANClient rxClient;
    uint32_t canId{0x100};
    int messageSize{8};
    int burstSize{1};
    bool useFD{false};
    int bitrate{1000000};
};

static void* bandwidthTxThread(void* arg) {
    auto* impl = (BandwidthTestEngineImpl*)arg;
    uint64_t counter = 0;

    // Calculate TX pacing to match CAN bus capacity
    double bitsPerFrame = (47.0 + impl->messageSize * 8.0) * 1.2;
    double burstBits = bitsPerFrame * impl->burstSize;
    uint32_t burstTimeUs = (uint32_t)(burstBits / impl->bitrate * 1000000.0);

    // Drift-free absolute-time pacing
    uint64_t ticksPerBurst = nanosToAbs((uint64_t)burstTimeUs * 1000);
    uint64_t nextWake = mach_absolute_time();

    while (!impl->cancelled.load(std::memory_order_relaxed)) {
        uint32_t framesSent = 0;
        for (int i = 0; i < impl->burstSize; i++) {
            canfd_frame f = buildFrame(counter, impl->canId, impl->messageSize, impl->useFD);

            bool ok = impl->useFD
                ? (impl->txClient.write(&f) == 1)
                : (impl->txClient.writeClassic((can_frame*)&f) == 1);

            if (!ok) break;
            framesSent++;
            counter++;
        }

        if (framesSent > 0) {
            impl->engine.addSent(framesSent, framesSent * (impl->messageSize + 4));
            if (ticksPerBurst > 0) {
                nextWake += ticksPerBurst;
                mach_wait_until(nextWake);
            }
        } else {
            usleep(500);
            nextWake = mach_absolute_time();
        }
    }
    return nullptr;
}

static void* bandwidthRxThread(void* arg) {
    auto* impl = (BandwidthTestEngineImpl*)arg;
    CANPacket packets[256];

    while (!impl->cancelled.load(std::memory_order_relaxed)) {
        int n = impl->rxClient.readManyBlocking(packets, 256, 5);
        if (n > 0) {
            impl->engine.addPoll(true, (uint32_t)(n * 20));
            for (int i = 0; i < n; i++) {
                impl->engine.addReceived(packets[i].frame.data, packets[i].frame.len);
            }
        } else {
            impl->engine.addPoll(false, 0);
        }
    }
    return nullptr;
}

BandwidthTestEngine::BandwidthTestEngine()
    : _impl(std::make_shared<BandwidthTestEngineImpl>()) {}

BandwidthTestEngine::~BandwidthTestEngine() = default;
BandwidthTestEngine::BandwidthTestEngine(const BandwidthTestEngine&) = default;
BandwidthTestEngine& BandwidthTestEngine::operator=(const BandwidthTestEngine&) = default;

void BandwidthTestEngine::startTest(CANClient txClient, CANClient rxClient,
                                     uint32_t canId, int messageSize, int burstSize,
                                     bool useFD, int bitrate) {
    _impl->engine.reset();
    _impl->cancelled = false;
    _impl->txClient = txClient;
    _impl->rxClient = rxClient;
    _impl->canId = canId;
    _impl->messageSize = messageSize;
    _impl->burstSize = burstSize;
    _impl->useFD = useFD;
    _impl->bitrate = bitrate;

    // Flush stale frames from previous test
    {
        CANPacket buf[256];
        while (_impl->rxClient.readMany(buf, 256) > 0) {}
    }

    pthread_create(&_impl->txThread, nullptr, bandwidthTxThread, _impl.get());
    pthread_create(&_impl->rxThread, nullptr, bandwidthRxThread, _impl.get());
    _impl->threadsRunning = true;
}

void BandwidthTestEngine::stopTest() {
    _impl->cancelled = true;
    if (_impl->threadsRunning) {
        pthread_join(_impl->txThread, nullptr);
        pthread_join(_impl->rxThread, nullptr);
        _impl->threadsRunning = false;
    }
}

BandwidthSnapshot BandwidthTestEngine::snapshot() {
    return _impl->engine.snapshot();
}

RateCounters BandwidthTestEngine::drainPerSecondCounters() {
    return _impl->engine.drainPerSecondCounters();
}

// ============================================================
// Test 2: BidirTestEngine
// ============================================================

class BidirTestEngineImpl {
public:
    MetricsEngine engineA1toA2;
    MetricsEngine engineA2toA1;
    std::atomic<bool> cancelled{false};
    pthread_t a1TxThread{};
    pthread_t a1RxThread{};
    pthread_t a2TxThread{};
    pthread_t a2RxThread{};
    bool threadsRunning{false};

    // Config
    CANClient a1Client;
    CANClient a2Client;
    int messageSize{8};
    int burstSize{1};
    bool useFD{false};
    int bitrate{1000000};
    int targetRateA{4000};  // target msg/s for A→B direction
    int targetRateB{4000};  // target msg/s for B→A direction
};

struct BidirThreadArgs {
    BidirTestEngineImpl* impl;
    bool isA1;  // true = adapter 1 side
};

static void* bidirTxThread(void* arg) {
    auto* args = (BidirThreadArgs*)arg;
    auto* impl = args->impl;
    bool isA1 = args->isA1;
    delete args;

    CANClient& client = isA1 ? impl->a1Client : impl->a2Client;
    MetricsEngine& engine = isA1 ? impl->engineA1toA2 : impl->engineA2toA1;
    uint32_t canId = isA1 ? 0x200 : 0x201;

    uint64_t counter = 0;

    // Configurable TX rate per direction
    int rate = isA1 ? impl->targetRateA : impl->targetRateB;
    uint32_t frameTimeUs = (rate > 0) ? (1000000 / rate) : 250;
    uint32_t burstTimeUs = impl->burstSize * frameTimeUs;

    // Drift-free absolute-time pacing
    uint64_t ticksPerBurst = nanosToAbs((uint64_t)burstTimeUs * 1000);
    uint64_t nextWake = mach_absolute_time();

    while (!impl->cancelled.load(std::memory_order_relaxed)) {
        uint32_t framesSent = 0;
        for (int i = 0; i < impl->burstSize; i++) {
            canfd_frame f = buildFrame(counter, canId, impl->messageSize, impl->useFD);

            bool ok = impl->useFD
                ? (client.write(&f) == 1)
                : (client.writeClassic((can_frame*)&f) == 1);

            if (!ok) break;
            framesSent++;
            counter++;
        }

        if (framesSent > 0) {
            engine.addSent(framesSent, framesSent * (impl->messageSize + 4));
            if (ticksPerBurst > 0) {
                nextWake += ticksPerBurst;
                mach_wait_until(nextWake);
            }
        } else {
            usleep(500);
            nextWake = mach_absolute_time();
        }
    }
    return nullptr;
}

static void* bidirRxThread(void* arg) {
    auto* args = (BidirThreadArgs*)arg;
    auto* impl = args->impl;
    bool isA1 = args->isA1;
    delete args;

    // A1 RX receives A2→A1 traffic (filter for CAN ID 0x201)
    // A2 RX receives A1→A2 traffic (filter for CAN ID 0x200)
    CANClient& client = isA1 ? impl->a1Client : impl->a2Client;
    MetricsEngine& engine = isA1 ? impl->engineA2toA1 : impl->engineA1toA2;
    uint32_t filterCanId = isA1 ? 0x201 : 0x200;

    CANPacket packets[256];

    while (!impl->cancelled.load(std::memory_order_relaxed)) {
        int n = client.readManyBlocking(packets, 256, 5);
        if (n > 0) {
            engine.addPoll(true, (uint32_t)(n * 20));
            for (int i = 0; i < n; i++) {
                const auto& f = packets[i].frame;
                uint32_t id = f.can_id & CAN_EFF_MASK;
                if (id == filterCanId || (f.can_id & CAN_SFF_MASK) == filterCanId) {
                    engine.addReceived(f.data, f.len);
                }
            }
        } else {
            engine.addPoll(false, 0);
        }
    }
    return nullptr;
}

BidirTestEngine::BidirTestEngine()
    : _impl(std::make_shared<BidirTestEngineImpl>()) {}

BidirTestEngine::~BidirTestEngine() = default;
BidirTestEngine::BidirTestEngine(const BidirTestEngine&) = default;
BidirTestEngine& BidirTestEngine::operator=(const BidirTestEngine&) = default;

void BidirTestEngine::startTest(CANClient a1Client, CANClient a2Client,
                                 int messageSize, int burstSize,
                                 bool useFD, int bitrate,
                                 int targetRateA, int targetRateB) {
    _impl->engineA1toA2.reset();
    _impl->engineA2toA1.reset();
    _impl->cancelled = false;
    _impl->a1Client = a1Client;
    _impl->a2Client = a2Client;
    _impl->messageSize = messageSize;
    _impl->burstSize = burstSize;
    _impl->useFD = useFD;
    _impl->bitrate = bitrate;
    _impl->targetRateA = (targetRateA > 0) ? targetRateA : 4000;
    _impl->targetRateB = (targetRateB > 0) ? targetRateB : 4000;

    // Allocate args on heap — thread functions delete them
    auto* a1TxArgs = new BidirThreadArgs{_impl.get(), true};
    auto* a1RxArgs = new BidirThreadArgs{_impl.get(), true};
    auto* a2TxArgs = new BidirThreadArgs{_impl.get(), false};
    auto* a2RxArgs = new BidirThreadArgs{_impl.get(), false};

    // Flush stale frames from previous test runs.
    // Without this, the first frames received have old sequence numbers
    // from the prior test, causing spurious gap/ooo counts in MetricsEngine.
    // Two passes with a brief settle to catch in-flight USB transfers.
    {
        CANPacket buf[256];
        while (_impl->a1Client.readMany(buf, 256) > 0) {}
        while (_impl->a2Client.readMany(buf, 256) > 0) {}
        usleep(20000);  // 20ms: let USB pipeline drain
        while (_impl->a1Client.readMany(buf, 256) > 0) {}
        while (_impl->a2Client.readMany(buf, 256) > 0) {}
    }

    // Start RX threads first, then TX threads
    pthread_create(&_impl->a1RxThread, nullptr, bidirRxThread, a1RxArgs);
    pthread_create(&_impl->a2RxThread, nullptr, bidirRxThread, a2RxArgs);
    pthread_create(&_impl->a1TxThread, nullptr, bidirTxThread, a1TxArgs);
    pthread_create(&_impl->a2TxThread, nullptr, bidirTxThread, a2TxArgs);
    _impl->threadsRunning = true;
}

void BidirTestEngine::stopTest() {
    _impl->cancelled = true;
    if (_impl->threadsRunning) {
        pthread_join(_impl->a1TxThread, nullptr);
        pthread_join(_impl->a1RxThread, nullptr);
        pthread_join(_impl->a2TxThread, nullptr);
        pthread_join(_impl->a2RxThread, nullptr);
        _impl->threadsRunning = false;
    }
}

BandwidthSnapshot BidirTestEngine::snapshotA1toA2() {
    return _impl->engineA1toA2.snapshot();
}

BandwidthSnapshot BidirTestEngine::snapshotA2toA1() {
    return _impl->engineA2toA1.snapshot();
}

RateCounters BidirTestEngine::drainPerSecondCountersA1toA2() {
    return _impl->engineA1toA2.drainPerSecondCounters();
}

RateCounters BidirTestEngine::drainPerSecondCountersA2toA1() {
    return _impl->engineA2toA1.drainPerSecondCounters();
}

// ============================================================
// Test 3: DistBidirTestEngine
// ============================================================

class DistBidirTestEngineImpl {
public:
    MetricsEngine engine;
    std::atomic<bool> cancelled{false};
    pthread_t txThread{};
    pthread_t rxThread{};
    bool threadsRunning{false};

    // Config
    CANClient client;
    uint32_t txCanId{0x200};
    uint32_t rxCanId{0x201};
    int messageSize{8};
    bool useFD{false};
    int bitrate{1000000};
};

static void* distBidirTxThread(void* arg) {
    auto* impl = (DistBidirTestEngineImpl*)arg;
    uint64_t counter = 0;

    // Bus-capacity-aware TX pacing (single frame per iteration)
    double bitsPerFrame = (47.0 + impl->messageSize * 8.0) * 1.2;
    uint32_t frameTimeUs = (uint32_t)(bitsPerFrame / impl->bitrate * 1e6);

    // Drift-free absolute-time pacing
    uint64_t ticksPerFrame = nanosToAbs((uint64_t)frameTimeUs * 1000);
    uint64_t nextWake = mach_absolute_time();

    while (!impl->cancelled.load(std::memory_order_relaxed)) {
        canfd_frame f = buildFrame(counter, impl->txCanId, impl->messageSize, impl->useFD);

        bool ok = impl->useFD
            ? (impl->client.write(&f) == 1)
            : (impl->client.writeClassic((can_frame*)&f) == 1);

        if (ok) {
            impl->engine.addSent(1, (uint32_t)(impl->messageSize + 4));
            counter++;
            if (ticksPerFrame > 0) {
                nextWake += ticksPerFrame;
                mach_wait_until(nextWake);
            }
        } else {
            usleep(500);
            nextWake = mach_absolute_time();
        }
    }
    return nullptr;
}

static void* distBidirRxThread(void* arg) {
    auto* impl = (DistBidirTestEngineImpl*)arg;
    CANPacket packets[256];

    while (!impl->cancelled.load(std::memory_order_relaxed)) {
        int n = impl->client.readManyBlocking(packets, 256, 5);
        if (n > 0) {
            impl->engine.addPoll(true, (uint32_t)(n * 20));
            for (int i = 0; i < n; i++) {
                const auto& f = packets[i].frame;
                uint32_t id = f.can_id & CAN_EFF_MASK;
                if (id == impl->rxCanId ||
                    (f.can_id & CAN_SFF_MASK) == impl->rxCanId) {
                    impl->engine.addReceived(f.data, f.len);
                }
            }
        } else {
            impl->engine.addPoll(false, 0);
        }
    }
    return nullptr;
}

DistBidirTestEngine::DistBidirTestEngine()
    : _impl(std::make_shared<DistBidirTestEngineImpl>()) {}

DistBidirTestEngine::~DistBidirTestEngine() = default;
DistBidirTestEngine::DistBidirTestEngine(const DistBidirTestEngine&) = default;
DistBidirTestEngine& DistBidirTestEngine::operator=(const DistBidirTestEngine&) = default;

void DistBidirTestEngine::startTest(CANClient client,
                                     uint32_t txCanId, uint32_t rxCanId,
                                     int messageSize, bool useFD, int bitrate) {
    _impl->engine.reset();
    _impl->cancelled = false;
    _impl->client = client;
    _impl->txCanId = txCanId;
    _impl->rxCanId = rxCanId;
    _impl->messageSize = messageSize;
    _impl->useFD = useFD;
    _impl->bitrate = bitrate;

    // Flush stale frames from previous test
    {
        CANPacket buf[256];
        while (_impl->client.readMany(buf, 256) > 0) {}
    }

    pthread_create(&_impl->txThread, nullptr, distBidirTxThread, _impl.get());
    pthread_create(&_impl->rxThread, nullptr, distBidirRxThread, _impl.get());
    _impl->threadsRunning = true;
}

void DistBidirTestEngine::stopTest() {
    _impl->cancelled = true;
    if (_impl->threadsRunning) {
        pthread_join(_impl->txThread, nullptr);
        pthread_join(_impl->rxThread, nullptr);
        _impl->threadsRunning = false;
    }
}

BandwidthSnapshot DistBidirTestEngine::snapshot() {
    return _impl->engine.snapshot();
}

RateCounters DistBidirTestEngine::drainPerSecondCounters() {
    return _impl->engine.drainPerSecondCounters();
}
