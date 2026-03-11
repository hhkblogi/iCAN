/*
 * shared_ring.h — Shared memory ring buffer layout for app ↔ driver IPC.
 *
 * V3 layout: frame-level SPSC ring buffer.
 * Driver decodes protocol-specific bytes → canfd_frame → writeRxFrame.
 * Client reads structured frames. No userspace protocol decoding.
 *
 * Entry format in both RX and TX data areas:
 *   [uint16_t frameSize][canfd_frame or can_frame bytes]
 *
 * Apple Silicon uses 128-byte cache lines. RX and TX ring controls
 * are on separate cache lines to minimize false-sharing.
 *
 * Layout:
 *   [0..127]   metadata: magic, layoutVersion, capacities, counters
 *   [128..255] RX ring control: head (driver writes), tail (client writes)
 *   [256..383] TX ring control: head (client writes), tail (driver writes)
 *   [384..]    data: rxData[0..rxCapacity), txData[rxCapacity..rxCapacity+txCapacity)
 */

#pragma once

#include "protocol/can.h"
#include <stdint.h>

#define SHARED_RING_MAGIC           0xCAFECAFEU
#define SHARED_RING_LAYOUT_VERSION  3
#define SHARED_RX_CAPACITY          65536   /* 64KB RX data (holds ~885 frames) */
#define SHARED_TX_CAPACITY          16384   /* 16KB TX data (holds ~221 frames) */
#define SHARED_RING_HEADER_SIZE     384

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
    uint32_t txCapacity;      /* byte size of TX data area */
    uint32_t rxProduceCount;  /* frames written to RX ring */
    uint32_t rxDropped;       /* frames dropped (RX full) */
    uint32_t txDrainCount;    /* frames drained from TX ring */
    uint32_t txDropped;       /* invalid TX entries skipped */
    uint8_t  protocolId;      /* CANProtocol enum value */
    uint8_t  channelCount;    /* 1 for SLCAN/gs_usb, 2 for PCAN */
    uint8_t  _reserved[2];
    uint8_t  _pad0[92];       /* pad to 128 bytes (128 - 36 = 92) */

    /* --- RX ring control cache line (offset 128, 128 bytes) --- */
    /* Driver produces (writes head), client consumes (writes tail) */
    RingCtrl rx;
    uint8_t  _pad1[120];     /* pad to 256 bytes (128 - 8 = 120) */

    /* --- TX ring control cache line (offset 256, 128 bytes) --- */
    /* Client produces (writes head), driver consumes (writes tail) */
    RingCtrl tx;
    uint8_t  _pad2[120];     /* pad to 384 bytes (128 - 8 = 120) */

    /* --- data area (offset 384) --- */
    /* [0, rxCapacity): RX frames  (driver → client) */
    /* [rxCapacity, rxCapacity + txCapacity): TX frames  (client → driver) */
    uint8_t data[];
};

#define SHARED_RING_ALLOC (SHARED_RING_HEADER_SIZE + SHARED_RX_CAPACITY + SHARED_TX_CAPACITY)

/* Inline accessors for TX data region (offset by rxCapacity) */
static inline uint8_t* shared_ring_tx_data(struct SharedRingHeader* hdr) {
    return hdr->data + hdr->rxCapacity;
}
static inline const uint8_t* shared_ring_tx_data_const(const struct SharedRingHeader* hdr) {
    return hdr->data + hdr->rxCapacity;
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
