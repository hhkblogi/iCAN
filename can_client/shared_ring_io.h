/*
 * shared_ring_io.h — C++ helpers for reading/writing CAN frames in the
 * shared memory SPSC ring buffers.
 */

#pragma once

#include "shared_ring.h"
#include <cstdint>
#include <cstring>

namespace shared_ring {

/// Write a canfd_frame into the RX ring (driver produces, app consumes).
/// V5 entry format: [uint16_t frameSize][uint64_t timestamp_us][frame bytes]
/// frameSize = CAN frame size only (16 or 72); total entry = 2 + 8 + frameSize.
/// Returns true if written, false if ring was full.
/// Atomically updates rxProduceCount or rxDropped in the header.
inline bool writeRxFrame(SharedRingHeader* hdr, uint8_t* rxData,
                         const canfd_frame& frame, uint64_t timestamp_us) {
    uint16_t frameSize = static_cast<uint16_t>(sizeof(canfd_frame));
    uint32_t entrySize = 2 + 8 + frameSize;  // header + timestamp + frame
    auto* rxCtrl = &hdr->rx;
    uint32_t cap = hdr->rxCapacity;
    uint32_t head = ring_load_head_relaxed(rxCtrl);
    uint32_t tail = ring_load_tail_acquire(rxCtrl);
    uint32_t rxFree = cap - (head - tail);

    if (entrySize > rxFree) {
        __atomic_fetch_add(&hdr->rxDropped, 1, __ATOMIC_RELAXED);
        return false;
    }
    // Write frame size header (2 bytes, little-endian)
    rxData[head % cap] = static_cast<uint8_t>(frameSize & 0xFF);
    rxData[(head + 1) % cap] = static_cast<uint8_t>(frameSize >> 8);
    // Write timestamp (8 bytes, little-endian)
    auto* tsBytes = reinterpret_cast<const uint8_t*>(&timestamp_us);
    for (uint32_t i = 0; i < 8; i++) {
        rxData[(head + 2 + i) % cap] = tsBytes[i];
    }
    // Write frame bytes
    auto* frameBytes = reinterpret_cast<const uint8_t*>(&frame);
    for (uint32_t i = 0; i < frameSize; i++) {
        rxData[(head + 10 + i) % cap] = frameBytes[i];
    }
    ring_store_head_release(rxCtrl, head + entrySize);
    __atomic_fetch_add(&hdr->rxProduceCount, 1, __ATOMIC_RELAXED);
    return true;
}

/// Result of reading the next TX frame from a TX ring.
struct TxReadResult {
    bool valid;              // true if a frame was successfully read
    bool dropped;            // true if an invalid entry was skipped (txDropped bumped)
    canfd_frame frame;       // valid only when valid == true
    uint32_t bytesConsumed;  // total ring bytes consumed by this read
};

/// Read the next CAN frame from a TX ring.
/// `txCtrl` is the ring control (tx0 or tx1).
/// `txData` points to the ring's data region.
/// `cap` is the ring's capacity in bytes.
/// `tail` is the current consumer position.
/// On success, caller should advance tail by result.bytesConsumed.
inline TxReadResult readTxFrame(SharedRingHeader* hdr, RingCtrl* txCtrl,
                                const uint8_t* txData, uint32_t cap,
                                uint32_t tail) {
    TxReadResult result{};
    uint32_t used = ring_load_head_acquire(txCtrl) - tail;

    if (used < 2) return result;  // not enough data

    // Read entry header
    uint16_t frameSize = static_cast<uint16_t>(
        static_cast<uint32_t>(txData[tail % cap]) |
        (static_cast<uint32_t>(txData[(tail + 1) % cap]) << 8));

    uint32_t entrySize = 2 + frameSize;
    if (entrySize > used) return result;  // incomplete entry

    // Validate frame size
    if (frameSize != CAN_MTU && frameSize != CANFD_MTU) {
        __atomic_fetch_add(&hdr->txDropped, 1, __ATOMIC_RELAXED);
        result.dropped = true;
        result.bytesConsumed = entrySize;
        return result;
    }

    // Copy frame bytes (handle ring wrap)
    uint8_t frameBuf[CANFD_MTU];
    for (uint32_t i = 0; i < frameSize; i++) {
        frameBuf[i] = txData[(tail + 2 + i) % cap];
    }

    // Build canfd_frame
    memset(&result.frame, 0, sizeof(canfd_frame));
    if (frameSize == CAN_MTU) {
        auto* cf = reinterpret_cast<can_frame*>(frameBuf);
        result.frame.can_id = cf->can_id;
        result.frame.len = cf->len;
        result.frame.flags = 0;
        memcpy(result.frame.data, cf->data, cf->len);
    } else {
        memcpy(&result.frame, frameBuf, sizeof(canfd_frame));
    }

    result.valid = true;
    result.bytesConsumed = entrySize;
    return result;
}

/// Backward-compat overload: reads from the legacy single-TX-ring layout.
/// Used by SLCAN/gs_usb codecs that still use hdr->tx0 as the only TX ring.
inline TxReadResult readTxFrame(SharedRingHeader* hdr, const uint8_t* txData,
                                uint32_t tail) {
    return readTxFrame(hdr, &hdr->tx0, txData, hdr->tx0Capacity, tail);
}

} // namespace shared_ring
