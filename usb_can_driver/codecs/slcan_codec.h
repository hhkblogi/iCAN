/*
 * SlcanCodec.h
 * SLCAN text protocol encoder/decoder + unified Codec for variant dispatch.
 */

#pragma once

#include "driver_types.h"
#include "protocol/can.h"
#include "can_client/shared_ring_io.h"
#include <cstdint>
#include <cstring>

namespace slcan {

/// Encode a CAN/FD frame to SLCAN text. Returns bytes written (including \r).
uint32_t encode(const canfd_frame* frame, char* out, uint32_t outSize);

/// Decode an SLCAN line into a canfd_frame. Returns true on success.
bool decode(const char* buf, uint32_t len, canfd_frame* out);

/// Map CAN bitrate (bps) to SLCAN 'Sn' command digit. Returns 0 on unsupported bitrate.
char bitrateToCode(uint32_t bitrate);

/// Accumulates raw USB bytes, splits on '\r', decodes each line as a CAN frame.
/// Stateful: maintains a partial-line buffer across calls.
class LineAccumulator {
public:
    /// Process raw bytes. Calls onFrame(const canfd_frame&) for each decoded CAN frame.
    template <typename Fn>
    void processBytes(const uint8_t* data, uint32_t len, Fn&& onFrame) {
        for (uint32_t i = 0; i < len; i++) {
            char ch = static_cast<char>(data[i]);
            if (ch == '\r') {
                if (bufLen_ > 0) {
                    linesTotal_++;
                    canfd_frame frame;
                    if (decode(buf_, bufLen_, &frame)) {
                        linesDecoded_++;
                        onFrame(frame);
                    } else {
                        linesFailed_++;
                        if (linesFailed_ <= 5) {
                            buf_[bufLen_] = '\0';
                            DEXT_LOG("SLCAN-FAIL[%u]: len=%u '%s'",
                                     linesFailed_, bufLen_, buf_);
                        }
                    }
                }
                bufLen_ = 0;
            } else if (ch != '\n' && bufLen_ < sizeof(buf_) - 1) {
                buf_[bufLen_++] = ch;
            }
        }
    }

    void reset() {
        bufLen_ = 0;
        linesTotal_ = 0;
        linesDecoded_ = 0;
        linesFailed_ = 0;
    }

    uint32_t linesTotal()   const { return linesTotal_; }
    uint32_t linesDecoded() const { return linesDecoded_; }
    uint32_t linesFailed()  const { return linesFailed_; }

private:
    char     buf_[256] {};
    uint32_t bufLen_       = 0;
    uint32_t linesTotal_   = 0;
    uint32_t linesDecoded_ = 0;
    uint32_t linesFailed_  = 0;
};

/// Unified codec for std::variant dispatch. Wraps LineAccumulator + free functions.
/// Satisfies the CanProtocol concept.
class Codec {
public:
    // --- Lifecycle ---

    kern_return_t configureDevice(IOUSBHostDevice* dev, IOService* forClient);

    template <typename SendFn>
    kern_return_t openChannel(IOUSBHostDevice* dev, IOService* forClient,
                              uint32_t bitrate, uint8_t /*channel*/, SendFn&& sendFn) {
        char code = bitrateToCode(bitrate);
        if (code == 0) {
            DEXT_LOG("slcan::openChannel: unsupported bitrate %u", bitrate);
            return kIOReturnBadArgument;
        }

        // Batch all commands into a single USB transfer to avoid
        // async I/O contention (sendFn sets fTxInFlight).
        const uint8_t cmd[] = {'C', '\r', 'S', static_cast<uint8_t>(code), '\r', 'O', '\r'};
        kern_return_t ret = sendFn(cmd, sizeof(cmd));

        DEXT_LOG("slcan::openChannel: sent C+S%c+O (%u bytes): 0x%x",
                 code, (uint32_t)sizeof(cmd), ret);
        return ret;
    }

    template <typename SendFn>
    kern_return_t closeChannel(IOUSBHostDevice* dev, IOService* forClient,
                               uint8_t /*channel*/, SendFn&& sendFn) {
        const uint8_t closeCmd[] = {'C', '\r'};
        return sendFn(closeCmd, 2);
    }

    void onStopIO(IOUSBHostDevice* dev, IOService* forClient) {
        accum_.reset();
    }
    void onTimer(uint64_t now) {}

    // --- TX drain: batch-encode CAN frames from ring, send via callback ---

    template <typename SendFn>
    kern_return_t drainTx(SharedRingHeader* hdr, const uint8_t* txData,
                          bool txInFlight, SendFn&& sendFn) {
        if (!hdr || !txData) return kIOReturnNotReady;
        if (txInFlight) return kIOReturnBusy;

        auto* txCtrl = &hdr->tx0;
        uint32_t tail = ring_load_tail_relaxed(txCtrl);

        char slcanBatch[TX_BUFFER_SIZE];
        uint32_t slcanLen = 0;
        uint32_t framesProcessed = 0;

        while (true) {
            auto txRead = shared_ring::readTxFrame(hdr, txData, tail);
            if (!txRead.valid && !txRead.dropped) break;

            tail += txRead.bytesConsumed;
            if (txRead.dropped) continue;

            char encoded[SLCAN_ENCODE_BUF];
            uint32_t encLen = slcan::encode(&txRead.frame, encoded, sizeof(encoded));
            if (encLen == 0 || slcanLen + encLen > TX_BUFFER_SIZE) {
                if (encLen == 0) {
                    __atomic_fetch_add(&hdr->txDropped, 1, __ATOMIC_RELAXED);
                }
                break;
            }

            memcpy(slcanBatch + slcanLen, encoded, encLen);
            slcanLen += encLen;
            framesProcessed++;
        }

        if (slcanLen > 0) {
            // Send first, advance tail only on success (prevents silent
            // frame loss when concurrent DrainTxRing calls race on fTxInFlight).
            kern_return_t txRet = sendFn(reinterpret_cast<const uint8_t*>(slcanBatch), slcanLen);
            if (txRet == kIOReturnSuccess && framesProcessed > 0) {
                ring_store_tail_release(txCtrl, tail);
                __atomic_fetch_add(&hdr->txDrainCount, framesProcessed, __ATOMIC_RELAXED);
            }
            return txRet;
        }

        return kIOReturnSuccess;
    }

    // --- RX processing: accumulate USB bytes, decode lines, emit CAN frames ---

    template <typename FrameFn>
    void processRxData(const uint8_t* data, uint32_t len, FrameFn&& onFrame,
                       SharedRingHeader* = nullptr) {
        accum_.processBytes(data, len, onFrame);
    }

    bool needsDrainTx() const { return false; }

    // --- Metadata ---

    bool needsCDC()          const { return true; }
    const char* name()       const { return "SLCAN"; }
    uint8_t protocolId()     const { return kCANProtocolSLCAN; }

    // --- Diagnostics ---

    uint32_t diagLine(const uint8_t* buf, uint32_t bufSize) const;

    // --- Accessors ---

    const LineAccumulator& accumulator() const { return accum_; }
    void reset() { accum_.reset(); }

private:
    LineAccumulator accum_;
};

static_assert(CanProtocol<Codec>);

} // namespace slcan
