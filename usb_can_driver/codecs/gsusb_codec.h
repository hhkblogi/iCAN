/*
 * GsusbCodec.h
 * gs_usb binary protocol: frame codec, bit timing, echo flow, control requests.
 * Unified Codec for std::variant dispatch — satisfies CanProtocol concept.
 *
 * DriverKit objects (IOUSBHostDevice*, IOService*) are passed as method params
 * and never stored — the codec owns only protocol state.
 */

#pragma once

#include "driver_types.h"
#include "protocol/can.h"
#include "can_client/shared_ring_io.h"
#include <DriverKit/IOReturn.h>
#include <cstdint>
#include <cstring>

// Forward declarations
class IOUSBHostDevice;
class IOService;

namespace gsusb {

// ================================================================
// gs_usb wire protocol constants (from Linux kernel gs_usb.c)
// ================================================================

// USB vendor request codes
constexpr uint8_t GS_USB_BREQ_HOST_FORMAT   = 0;
constexpr uint8_t GS_USB_BREQ_BITTIMING     = 1;
constexpr uint8_t GS_USB_BREQ_MODE          = 2;
constexpr uint8_t GS_USB_BREQ_BT_CONST      = 4;
constexpr uint8_t GS_USB_BREQ_DEVICE_CONFIG = 5;

// CAN channel mode
constexpr uint32_t GS_CAN_MODE_RESET = 0;
constexpr uint32_t GS_CAN_MODE_START = 1;

// CAN frame flags (in gs_host_frame_header.flags)
constexpr uint8_t GS_CAN_FLAG_FD  = 0x04;  // BIT(2) — CAN FD frame
constexpr uint8_t GS_CAN_FLAG_BRS = 0x08;  // BIT(3) — bitrate switch
constexpr uint8_t GS_CAN_FLAG_ESI = 0x10;  // BIT(4) — error state indicator

// ================================================================
// gs_usb wire structures (packed, little-endian)
// ================================================================

/// Host frame header (12 bytes) — precedes 8 or 64 bytes of CAN data
struct __attribute__((packed)) gs_host_frame_header {
    uint32_t echo_id;     // 0xFFFFFFFF for RX, echo ID for TX/echo
    uint32_t can_id;      // CAN ID + EFF/RTR/ERR flags
    uint8_t  can_dlc;     // DLC (0..15)
    uint8_t  channel;     // CAN channel index
    uint8_t  flags;       // GS_CAN_FLAG_*
    uint8_t  reserved;
};

constexpr uint32_t GS_HOST_FRAME_CLASSIC_SIZE = sizeof(gs_host_frame_header) + CAN_MAX_DLEN;   // 20
constexpr uint32_t GS_HOST_FRAME_FD_SIZE      = sizeof(gs_host_frame_header) + CANFD_MAX_DLEN;  // 76

/// Device bit timing constants (40 bytes)
struct __attribute__((packed)) gs_device_bt_const {
    uint32_t feature;
    uint32_t fclk_can;
    uint32_t tseg1_min;
    uint32_t tseg1_max;
    uint32_t tseg2_min;
    uint32_t tseg2_max;
    uint32_t sjw_max;
    uint32_t brp_min;
    uint32_t brp_max;
    uint32_t brp_inc;
};

/// Device configuration (12 bytes)
struct __attribute__((packed)) gs_device_config {
    uint8_t  reserved1;
    uint8_t  reserved2;
    uint8_t  reserved3;
    uint8_t  icount;       // number of CAN interfaces - 1
    uint32_t sw_version;
    uint32_t hw_version;
};

/// Host configuration (4 bytes)
struct __attribute__((packed)) gs_host_config {
    uint32_t byte_order;   // 0x0000BEEF
};

/// Device bit timing request (20 bytes)
struct __attribute__((packed)) gs_device_bittiming {
    uint32_t prop_seg;
    uint32_t phase_seg1;
    uint32_t phase_seg2;
    uint32_t sjw;
    uint32_t brp;
};

/// Device mode request (8 bytes)
struct __attribute__((packed)) gs_device_mode {
    uint32_t mode;         // GS_CAN_MODE_*
    uint32_t flags;
};

// ================================================================

/// Result of decoding a USB bulk IN transfer.
struct RxResult {
    enum Type : uint8_t { Frame, TxEcho, Invalid };
    Type type;
    canfd_frame frame;   // valid only when type == Frame
};

/// Decode a single USB bulk IN transfer into an RxResult.
RxResult decodeRxTransfer(const uint8_t* data, uint32_t len);

/// Encode a canfd_frame into a gs_host_frame for USB bulk OUT.
/// Returns bytes written (0 on failure).
uint32_t encodeTxFrame(const canfd_frame& frame, uint32_t echoId,
                       uint8_t* out, uint32_t outSize);

/// gs_usb protocol state: configuration, echo tracking, control requests.
/// Satisfies the CanProtocol concept for variant dispatch.
class Codec {
public:
    // --- CanProtocol unified interface ---

    kern_return_t configureDevice(IOUSBHostDevice* dev, IOService* forClient);

    template <typename SendFn>
    kern_return_t openChannel(IOUSBHostDevice* dev, IOService* forClient,
                              uint32_t bitrate, uint8_t /*channel*/, SendFn&& /*sendFn*/) {
        // gs_usb uses vendor control requests, not bulk data
        resetEcho();
        kern_return_t ret = setBitTiming(dev, forClient, bitrate);
        if (ret != kIOReturnSuccess) return ret;
        return startChannel(dev, forClient);
    }

    template <typename SendFn>
    kern_return_t closeChannel(IOUSBHostDevice* dev, IOService* forClient,
                               uint8_t /*channel*/, SendFn&& /*sendFn*/) {
        return stopChannel(dev, forClient);
    }

    void onStopIO(IOUSBHostDevice* dev, IOService* forClient);
    void onTimer(uint64_t now);

    template <typename SendFn>
    kern_return_t drainTx(SharedRingHeader* hdr, const uint8_t* txData,
                          bool txInFlight, SendFn&& sendFn) {
        if (!hdr || !txData) return kIOReturnNotReady;
        if (txInFlight) return kIOReturnBusy;
        if (!canSend()) return kIOReturnBusy;

        auto* txCtrl = &hdr->tx0;
        uint32_t tail = ring_load_tail_relaxed(txCtrl);

        // gs_usb firmware expects exactly ONE gs_host_frame per USB bulk OUT transfer
        while (true) {
            auto txRead = shared_ring::readTxFrame(hdr, txData, tail);
            if (!txRead.valid && !txRead.dropped) return kIOReturnSuccess;

            tail += txRead.bytesConsumed;
            if (txRead.dropped) {
                ring_store_tail_release(txCtrl, tail);
                continue;
            }

            // Encode to gs_host_frame
            uint8_t txFrame[GS_HOST_FRAME_FD_SIZE];
            uint32_t gsFrameSize = encodeTxFrame(txRead.frame, nextEchoId(),
                                                  txFrame, sizeof(txFrame));
            if (gsFrameSize == 0) {
                __atomic_fetch_add(&hdr->txDropped, 1, __ATOMIC_RELAXED);
                ring_store_tail_release(txCtrl, tail);
                continue;
            }

            // Send first, advance tail only on success (prevents silent
            // frame loss when concurrent DrainTxRing calls race on fTxInFlight).
            kern_return_t txRet = sendFn(txFrame, gsFrameSize);
            if (txRet == kIOReturnSuccess) {
                onTxSent();
                ring_store_tail_release(txCtrl, tail);
                __atomic_fetch_add(&hdr->txDrainCount, 1, __ATOMIC_RELAXED);
            }
            return txRet;
        }
    }

    template <typename FrameFn>
    void processRxData(const uint8_t* data, uint32_t len, FrameFn&& onFrame,
                       SharedRingHeader* = nullptr) {
        needsDrainTx_ = false;
        auto rxResult = decodeRxTransfer(data, len);
        if (rxResult.type == RxResult::TxEcho) {
            onEchoReceived();
            needsDrainTx_ = true;
        } else if (rxResult.type == RxResult::Frame) {
            onFrame(rxResult.frame);
        }
    }

    bool needsDrainTx() const { return needsDrainTx_; }

    // --- Metadata ---

    bool needsCDC()          const { return false; }
    const char* name()       const { return "gs_usb"; }
    uint8_t protocolId()     const { return kCANProtocolGSUSB; }

    // --- Diagnostics ---

    uint32_t diagLine(const uint8_t* buf, uint32_t bufSize) const;

    // --- Echo flow control ---

    bool     canSend()      const { return echoInflight_ < kMaxEchoInflight; }
    uint32_t nextEchoId()         { return nextEchoId_++; }
    void     onTxSent()           { echoInflight_++; }
    void     onEchoReceived()     { if (echoInflight_ > 0) echoInflight_--; echoStallStart_ = 0; }

    /// Check for echo stall: if at max in-flight for > timeout, release one slot.
    bool checkStall(uint64_t now);

    void resetEcho() { echoInflight_ = 0; echoStallStart_ = 0; nextEchoId_ = 0; }

    // --- Accessors ---

    uint32_t echoInflight()  const { return echoInflight_; }
    bool     isChannelOpen() const { return channelOpen_; }
    uint32_t features()      const { return features_; }

private:
    // Internal control request helpers
    kern_return_t sendControlRequest(IOUSBHostDevice* dev, IOService* forClient,
                                     uint8_t breq, uint16_t wValue,
                                     const void* sendData, uint16_t sendLen,
                                     void* recvData, uint16_t recvLen);

    kern_return_t setBitTiming(IOUSBHostDevice* dev, IOService* forClient, uint32_t bitrate);
    kern_return_t startChannel(IOUSBHostDevice* dev, IOService* forClient);
    kern_return_t stopChannel(IOUSBHostDevice* dev, IOService* forClient);

    gs_device_bt_const btConst_     {};
    gs_device_config   deviceConfig_{};
    uint32_t features_         = 0;
    bool     channelOpen_      = false;

    uint32_t echoInflight_     = 0;
    uint64_t echoStallStart_   = 0;
    uint32_t nextEchoId_       = 0;
    bool     needsDrainTx_     = false;

    static constexpr uint32_t kMaxEchoInflight = 10;
    static constexpr uint64_t kStallTimeoutNS  = 200000000ULL;  // 200ms
};

static_assert(CanProtocol<Codec>);

} // namespace gsusb
