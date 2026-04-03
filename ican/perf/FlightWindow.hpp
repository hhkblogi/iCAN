#ifndef FlightWindow_hpp
#define FlightWindow_hpp

#include <atomic>
#include <cstdint>
#include <cstring>

/// Lock-free per-direction delivery tracker using an atomic bitset.
///
/// Thread roles (each is single-writer to its cache line):
///   TX thread  -> head_seq (store-relaxed)
///   RX thread  -> ack_bitmap[word].fetch_or (relaxed)
///   UI thread  -> reap() + deliveryRate() (single caller, ~1 Hz)
///
/// Design inspired by Meta/Folly's ConcurrentBitSet (fetch_or + popcount)
/// and BucketedTimeSeries (running-total reaper). Cache-line isolation
/// follows ProducerConsumerQueue's padding pattern.
///
/// Memory: ~2.2 KB per FlightWindow (16384 bits + 3 cache lines of metadata).
class FlightWindow {
public:
    static constexpr int kCapacity     = 16384;           // power of 2
    static constexpr int kBitmapWords  = kCapacity / 64;  // 256
    static constexpr uint64_t kMask    = kCapacity - 1;   // 0x3FFF
    static constexpr uint64_t kGraceEntries = 8000;       // ~2s at 4000 msg/s

    // --- TX path (single writer: TX thread) ---

    /// Record a sent frame. Must be called with monotonically increasing seq.
    void onTxSent(uint64_t seq) {
        head_seq_.store(seq + 1, std::memory_order_relaxed);
    }

    // --- RX path (single writer: RX thread) ---

    /// Record a received frame. O(1), lock-free, idempotent.
    void onRxReceived(uint64_t seq) {
        rxCalls_.fetch_add(1, std::memory_order_relaxed);
        uint64_t head = head_seq_.load(std::memory_order_relaxed);
        // Reject acks for seq nums that have already wrapped past the bitmap.
        if (head > seq && (head - seq) > kCapacity) {
            rxStaleRejects_.fetch_add(1, std::memory_order_relaxed);
            return;
        }
        // Reject acks for seq nums already reaped (behind base_seq).
        // Without this, a late ack sets a bit in a cleared word, which
        // will be falsely counted for a future frame in the next cycle.
        uint64_t base = base_seq_;  // relaxed read OK: reaper is the only writer
        if (seq < base) {
            rxReapedRejects_.fetch_add(1, std::memory_order_relaxed);
            return;
        }

        uint64_t idx  = seq & kMask;
        int      word = static_cast<int>(idx / 64);
        int      bit  = static_cast<int>(idx % 64);
        ack_bitmap_[word].fetch_or(1ULL << bit, std::memory_order_relaxed);
    }

    // --- Reaper (single caller: UI thread, ~1 Hz) ---

    /// Walk the bitmap from base_seq forward, harvesting completed 64-entry
    /// chunks that are outside the grace window. Returns cumulative delivery %.
    /// Returns -1.0 if no frames have been reaped yet.
    double deliveryRate() {
        reap();
        if (totalSent_ == 0) return -1.0;
        return static_cast<double>(totalConfirmed_)
             / static_cast<double>(totalSent_) * 100.0;
    }

    /// Reset all state. Must be called when no other threads are active.
    void reset() {
        head_seq_.store(0, std::memory_order_relaxed);
        for (int i = 0; i < kBitmapWords; i++)
            ack_bitmap_[i].store(0, std::memory_order_relaxed);
        base_seq_       = 0;
        totalSent_      = 0;
        totalConfirmed_ = 0;
        rxCalls_.store(0, std::memory_order_relaxed);
        rxStaleRejects_.store(0, std::memory_order_relaxed);
        rxReapedRejects_.store(0, std::memory_order_relaxed);
    }

    // Accessors
    uint64_t totalSent()       const { return totalSent_; }
    uint64_t totalConfirmed()  const { return totalConfirmed_; }
    uint64_t baseSeq()         const { return base_seq_; }
    uint64_t rxCalls()         const { return rxCalls_.load(std::memory_order_relaxed); }
    uint64_t rxStaleRejects()  const { return rxStaleRejects_.load(std::memory_order_relaxed); }
    uint64_t rxReapedRejects() const { return rxReapedRejects_.load(std::memory_order_relaxed); }

private:
    void reap() {
        uint64_t head = head_seq_.load(std::memory_order_relaxed);

        // Walk in 64-entry chunks. Only reap chunks that are fully
        // outside the grace window (base_seq + 64 + kGraceEntries <= head).
        while (base_seq_ + 64 + kGraceEntries <= head) {
            uint64_t idx  = base_seq_ & kMask;
            int      word = static_cast<int>(idx / 64);

            // Atomically harvest and clear the bitmap word
            uint64_t bits = ack_bitmap_[word].exchange(0, std::memory_order_relaxed);
            int confirmed = __builtin_popcountll(bits);

            totalSent_      += 64;
            totalConfirmed_ += confirmed;
            base_seq_       += 64;
        }
    }

    // --- Cache-line-separated fields (128 bytes on Apple Silicon M-series) ---

    // TX cache line (written by TX thread only)
    alignas(128) std::atomic<uint64_t> head_seq_{0};

    // Bitmap (written by RX via fetch_or, read/cleared by reaper)
    alignas(128) std::atomic<uint64_t> ack_bitmap_[kBitmapWords]{};

    // Reaper state (single-writer: reaper/UI thread only)
    alignas(128) uint64_t base_seq_{0};
    uint64_t totalSent_{0};
    uint64_t totalConfirmed_{0};

    // Debug counters (written by RX thread)
    alignas(128) std::atomic<uint64_t> rxCalls_{0};
    std::atomic<uint64_t> rxStaleRejects_{0};
    std::atomic<uint64_t> rxReapedRejects_{0};
};

#endif /* FlightWindow_hpp */
