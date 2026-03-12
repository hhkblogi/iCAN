#include "MetricsEngine.hpp"
#include <atomic>
#include <chrono>

class MetricsEngineImpl {
public:
    std::atomic<bool> _isCancelled;
    
    std::atomic<uint32_t> _messagesSent;
    std::atomic<uint32_t> _bytesSent;
    std::atomic<uint32_t> _messagesReceived;
    std::atomic<uint32_t> _bytesReceived;
    
    std::atomic<uint32_t> _rxPolls;
    std::atomic<uint32_t> _rxHits;
    std::atomic<uint32_t> _rxRawBytes;
    
    std::atomic<uint32_t> _rxSequenceGaps;
    std::atomic<uint32_t> _rxOutOfOrder;
    std::atomic<uint32_t> _rxDuplicates;
    std::atomic<uint32_t> _rxDecodeFailures;
    std::atomic<uint64_t> _rxLastSequence;
    
    std::atomic<uint32_t> _secTx;
    std::atomic<uint32_t> _secTxBytes;
    std::atomic<uint32_t> _secRx;
    std::atomic<uint32_t> _secRxBytes;
    
    std::chrono::time_point<std::chrono::steady_clock> _startTime;
};

MetricsEngine::MetricsEngine() : _impl(std::make_shared<MetricsEngineImpl>()) {
    reset();
}

MetricsEngine::~MetricsEngine() = default;

MetricsEngine::MetricsEngine(const MetricsEngine& other) = default;

MetricsEngine& MetricsEngine::operator=(const MetricsEngine& other) = default;

void MetricsEngine::reset() {
    _impl->_isCancelled = false;
    _impl->_startTime = std::chrono::steady_clock::now();
    
    _impl->_messagesSent = 0;
    _impl->_bytesSent = 0;
    _impl->_messagesReceived = 0;
    _impl->_bytesReceived = 0;
    
    _impl->_rxPolls = 0;
    _impl->_rxHits = 0;
    _impl->_rxRawBytes = 0;
    
    _impl->_rxSequenceGaps = 0;
    _impl->_rxOutOfOrder = 0;
    _impl->_rxDuplicates = 0;
    _impl->_rxDecodeFailures = 0;
    _impl->_rxLastSequence = 0;
    
    _impl->_secTx = 0;
    _impl->_secTxBytes = 0;
    _impl->_secRx = 0;
    _impl->_secRxBytes = 0;
}

void MetricsEngine::cancel() {
    _impl->_isCancelled = true;
}

bool MetricsEngine::isCancelled() const {
    return _impl->_isCancelled.load(std::memory_order_relaxed);
}

void MetricsEngine::addSent(uint32_t messages, uint32_t bytes) {
    _impl->_messagesSent.fetch_add(messages, std::memory_order_relaxed);
    _impl->_bytesSent.fetch_add(bytes, std::memory_order_relaxed);
    _impl->_secTx.fetch_add(messages, std::memory_order_relaxed);
    _impl->_secTxBytes.fetch_add(bytes, std::memory_order_relaxed);
}

void MetricsEngine::addPoll(bool hit, uint32_t rawBytes) {
    _impl->_rxPolls.fetch_add(1, std::memory_order_relaxed);
    if (hit) {
        _impl->_rxHits.fetch_add(1, std::memory_order_relaxed);
        _impl->_rxRawBytes.fetch_add(rawBytes, std::memory_order_relaxed);
    }
}

void MetricsEngine::addReceived(const uint8_t* data, uint32_t length) {
    _impl->_messagesReceived.fetch_add(1, std::memory_order_relaxed);
    uint32_t packetBytes = length + 4;
    _impl->_bytesReceived.fetch_add(packetBytes, std::memory_order_relaxed);
    _impl->_secRx.fetch_add(1, std::memory_order_relaxed);
    _impl->_secRxBytes.fetch_add(packetBytes, std::memory_order_relaxed);
    
    if (length >= 8) {
        uint64_t seq = ((uint64_t)data[0] << 56) | ((uint64_t)data[1] << 48) |
                       ((uint64_t)data[2] << 40) | ((uint64_t)data[3] << 32) |
                       ((uint64_t)data[4] << 24) | ((uint64_t)data[5] << 16) |
                       ((uint64_t)data[6] << 8)  |  (uint64_t)data[7];

        if (_impl->_messagesReceived.load(std::memory_order_relaxed) == 1) {
            _impl->_rxLastSequence.store(seq, std::memory_order_relaxed);
            return;
        }

        uint64_t lastSeq = _impl->_rxLastSequence.load(std::memory_order_relaxed);
        uint64_t expected = lastSeq + 1;

        if (seq == expected) {
            // Perfect sequential delivery
        } else if (seq == lastSeq) {
            _impl->_rxDuplicates.fetch_add(1, std::memory_order_relaxed);
        } else if (seq < lastSeq && (lastSeq - seq) < 1000) {
            _impl->_rxOutOfOrder.fetch_add(1, std::memory_order_relaxed);
        } else {
            uint32_t gap = (seq > expected) ? (uint32_t)(seq - expected) : 1;
            _impl->_rxSequenceGaps.fetch_add(gap, std::memory_order_relaxed);
        }

        if (seq > lastSeq || (lastSeq - seq) > 0x7FFFFFFFFFFFFFFFULL) {
            _impl->_rxLastSequence.store(seq, std::memory_order_relaxed);
        }
    }
}

void MetricsEngine::addDecodeFailure() {
    _impl->_rxDecodeFailures.fetch_add(1, std::memory_order_relaxed);
}

BandwidthSnapshot MetricsEngine::snapshot() {
    auto now = std::chrono::steady_clock::now();
    std::chrono::duration<double> elapsed = now - _impl->_startTime;
    
    return BandwidthSnapshot{
        .messagesSent = _impl->_messagesSent.load(std::memory_order_relaxed),
        .bytesSent = _impl->_bytesSent.load(std::memory_order_relaxed),
        .messagesReceived = _impl->_messagesReceived.load(std::memory_order_relaxed),
        .bytesReceived = _impl->_bytesReceived.load(std::memory_order_relaxed),
        
        .rxPolls = _impl->_rxPolls.load(std::memory_order_relaxed),
        .rxHits = _impl->_rxHits.load(std::memory_order_relaxed),
        .rxRawBytes = _impl->_rxRawBytes.load(std::memory_order_relaxed),
        
        .rxSequenceGaps = _impl->_rxSequenceGaps.load(std::memory_order_relaxed),
        .rxOutOfOrder = _impl->_rxOutOfOrder.load(std::memory_order_relaxed),
        .rxDuplicates = _impl->_rxDuplicates.load(std::memory_order_relaxed),
        .rxDecodeFailures = _impl->_rxDecodeFailures.load(std::memory_order_relaxed),
        .rxLastSequence = _impl->_rxLastSequence.load(std::memory_order_relaxed),
        
        .duration = elapsed.count()
    };
}

RateCounters MetricsEngine::drainPerSecondCounters() {
    return RateCounters{
        .tx = _impl->_secTx.exchange(0, std::memory_order_relaxed),
        .txBytes = _impl->_secTxBytes.exchange(0, std::memory_order_relaxed),
        .rx = _impl->_secRx.exchange(0, std::memory_order_relaxed),
        .rxBytes = _impl->_secRxBytes.exchange(0, std::memory_order_relaxed)
    };
}
