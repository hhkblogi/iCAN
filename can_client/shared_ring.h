/*
 * shared_ring.h — Shared memory ring buffer layout for app ↔ driver IPC.
 *
 * V4 layout: frame-level SPSC ring buffers with per-channel TX.
 * Driver decodes protocol-specific bytes → canfd_frame → writeRxFrame.
 * Client reads structured frames. No userspace protocol decoding.
 *
 * Entry format in all data areas:
 *   [uint16_t frameSize][canfd_frame or can_frame bytes]
 *
 * Apple Silicon uses 128-byte cache lines. Each ring control is on its
 * own cache line to minimize false-sharing.
 *
 * V4 changes from V3:
 *   - Per-channel TX rings (tx0 for ch0, tx1 for ch1)
 *   - Eliminates SPSC multi-producer race for dual-channel adapters
 *   - Each channel's TX thread writes to its own SPSC ring
 *   - Driver drains each ring independently to its USB endpoint
 *
 * Layout:
 *   [0..127]   metadata: magic, layoutVersion, capacities, counters
 *   [128..255] RX ring control: head (driver writes), tail (client writes)
 *   [256..383] TX0 ring control: head (ch0 client writes), tail (driver writes)
 *   [384..511] TX1 ring control: head (ch1 client writes), tail (driver writes)
 *   [512..]    data: rxData[0..rxCap), tx0Data[rxCap..rxCap+tx0Cap),
 *                    tx1Data[rxCap+tx0Cap..rxCap+tx0Cap+tx1Cap)
 */

#pragma once

#include "protocol/can.h"
#include <stdint.h>

#define SHARED_RING_MAGIC           0xCAFECAFEU
#define SHARED_RING_LAYOUT_VERSION  4
#define SHARED_RX_CAPACITY          262144  /* 256KB RX data (holds ~3540 frames) */
#define SHARED_TX0_CAPACITY         16384   /* 16KB TX ch0 data (holds ~221 frames) */
#define SHARED_TX1_CAPACITY         16384   /* 16KB TX ch1 data (holds ~221 frames) */
#define SHARED_RING_HEADER_SIZE     512

/* Ring control pair — head and tail on the same cache line.
 * False sharing between producer and consumer is acceptable for
 * frame-level updates (much less frequent than byte-level). */
struct RingCtrl {
    uint32_t head;
    uint32_t tail;
};

struct SharedRingHeader {
    /* --- metadata cache line (offset 0, 128 bytes) --- */
    uint32_t magic;           /* SHARED_RING_MAGIC */
    uint32_t layoutVersion;   /* SHARED_RING_LAYOUT_VERSION */
    uint32_t rxCapacity;      /* byte size of RX data area */
    uint32_t tx0Capacity;     /* byte size of TX ch0 data area */
    uint32_t rxProduceCount;  /* frames written to RX ring */
    uint32_t rxDropped;       /* frames dropped (RX full) */
    uint32_t txDrainCount;    /* frames drained from TX rings (both channels) */
    uint32_t txDropped;       /* invalid TX entries skipped */
    uint8_t  protocolId;      /* CANProtocol enum value */
    uint8_t  channelCount;    /* 1 for SLCAN/gs_usb, 2 for PCAN */
    uint8_t  _reserved[2];

    /* Codec diagnostic counters (driver writes, app reads).
     * For PCAN: echo = filtered TX echoes, overrun = firmware FIFO drops,
     * calibration/error/status = non-CAN protocol messages from firmware. */
    uint32_t codecEchoCount;        /* offset 36 */
    uint32_t codecOverrunCount;     /* offset 40 */
    uint32_t codecCalibrationCount; /* offset 44 */
    uint32_t codecErrorCount;       /* offset 48 */
    uint32_t codecStatusCount;      /* offset 52 */
    uint32_t codecTruncatedCount;   /* offset 56: msgs truncated at USB boundary */
    uint32_t codecZeroSentinelCount;/* offset 60: zero-size end-of-stream hits */

    /* Live debug snapshot of last USB transfer (driver writes, app reads) */
    uint32_t dbgTransferSeq;        /* offset 64: transfer sequence number */
    uint32_t dbgTransferLen;        /* offset 68: USB actualByteCount */
    uint32_t dbgMsgsParsed;         /* offset 72: CAN frames parsed */
    uint32_t dbgZerosHit;           /* offset 76: zero sentinels in this transfer */
    uint8_t  dbgHead[48];           /* offset 80: first 48 bytes of raw transfer */
                                    /* total: 80+48 = 128 bytes, pad0 fully used */

    /* --- RX ring control cache line (offset 128, 128 bytes) --- */
    /* Driver produces (writes head), client consumes (writes tail) */
    RingCtrl rx;
    uint8_t  _pad1[120];     /* pad to 128 bytes */

    /* --- TX0 ring control cache line (offset 256, 128 bytes) --- */
    /* Ch0 client produces (writes head), driver consumes (writes tail) */
    RingCtrl tx0;
    uint8_t  _pad2[120];     /* pad to 128 bytes */

    /* --- TX1 ring control cache line (offset 384, 128 bytes) --- */
    /* Ch1 client produces (writes head), driver consumes (writes tail) */
    RingCtrl tx1;
    uint32_t tx1Capacity;    /* byte size of TX ch1 data area */
    uint8_t  _pad3[116];     /* pad to 128 bytes (128 - 8 - 4 = 116) */

    /* --- data area (offset 512) --- */
    /* [0, rxCapacity):                              RX frames  (driver → client) */
    /* [rxCapacity, rxCapacity+tx0Capacity):         TX0 frames (ch0 client → driver) */
    /* [rxCapacity+tx0Capacity, ...+tx1Capacity):    TX1 frames (ch1 client → driver) */
    uint8_t data[];
};

#define SHARED_RING_ALLOC (SHARED_RING_HEADER_SIZE + SHARED_RX_CAPACITY + SHARED_TX0_CAPACITY + SHARED_TX1_CAPACITY)

/* Inline accessors for TX data regions */
static inline uint8_t* shared_ring_tx0_data(struct SharedRingHeader* hdr) {
    return hdr->data + hdr->rxCapacity;
}
static inline const uint8_t* shared_ring_tx0_data_const(const struct SharedRingHeader* hdr) {
    return hdr->data + hdr->rxCapacity;
}
static inline uint8_t* shared_ring_tx1_data(struct SharedRingHeader* hdr) {
    return hdr->data + hdr->rxCapacity + hdr->tx0Capacity;
}
static inline const uint8_t* shared_ring_tx1_data_const(const struct SharedRingHeader* hdr) {
    return hdr->data + hdr->rxCapacity + hdr->tx0Capacity;
}

/* Backward-compat aliases — tx0 is the "default" TX ring */
static inline uint8_t* shared_ring_tx_data(struct SharedRingHeader* hdr) {
    return shared_ring_tx0_data(hdr);
}
static inline const uint8_t* shared_ring_tx_data_const(const struct SharedRingHeader* hdr) {
    return shared_ring_tx0_data_const(hdr);
}

/* ================================================================
 * Ring atomic helpers
 *
 * Naming convention:
 *   ring_load_head_relaxed  — producer reads own head (no ordering needed)
 *   ring_load_head_acquire  — consumer reads producer's head (acquire)
 *   ring_load_tail_relaxed  — consumer reads own tail
 *   ring_load_tail_acquire  — producer reads consumer's tail (acquire)
 *   ring_store_head_release — producer publishes new head (release)
 *   ring_store_tail_release — consumer publishes new tail (release)
 * ================================================================ */

static inline uint32_t ring_load_head_relaxed(const struct RingCtrl* c) {
    return __atomic_load_n(&c->head, __ATOMIC_RELAXED);
}
static inline uint32_t ring_load_head_acquire(const struct RingCtrl* c) {
    return __atomic_load_n(&c->head, __ATOMIC_ACQUIRE);
}
static inline uint32_t ring_load_tail_relaxed(const struct RingCtrl* c) {
    return __atomic_load_n(&c->tail, __ATOMIC_RELAXED);
}
static inline uint32_t ring_load_tail_acquire(const struct RingCtrl* c) {
    return __atomic_load_n(&c->tail, __ATOMIC_ACQUIRE);
}
static inline void ring_store_head_release(struct RingCtrl* c, uint32_t val) {
    __atomic_store_n(&c->head, val, __ATOMIC_RELEASE);
}
static inline void ring_store_tail_release(struct RingCtrl* c, uint32_t val) {
    __atomic_store_n(&c->tail, val, __ATOMIC_RELEASE);
}
