/*
 * PcanCodec.h
 * PCAN-USB Pro FD binary protocol: frame codec, bit timing, command pipe.
 * Satisfies CanProtocol concept for std::variant dispatch.
 *
 * Protocol reference: Linux kernel drivers/net/can/usb/peak_usb/pcan_usb_fd.c
 * and include/linux/can/dev/peak_canfd.h
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

namespace pcan {

// ================================================================
// PCAN uCAN protocol constants
// ================================================================

// Device constants
constexpr uint32_t CRYSTAL_HZ       = 80000000;  // 80 MHz internal clock
constexpr uint32_t CMD_BUFFER_SIZE   = 512;

// USB vendor request codes (for USB control transfers)
constexpr uint8_t  REQ_INFO         = 0;     // PCAN_USBPRO_REQ_INFO
constexpr uint8_t  REQ_FCT          = 2;     // PCAN_USBPRO_REQ_FCT
constexpr uint16_t INFO_FW          = 1;     // PCAN_USBPRO_INFO_FW
constexpr uint16_t FCT_DRVLD        = 5;     // PCAN_USBPRO_FCT_DRVLD
constexpr uint16_t FCT_DRVLD_LEN    = 16;

// RX message types (from device on EP 0x82)
constexpr uint16_t MSG_CAN_RX       = 0x0001;
constexpr uint16_t MSG_ERROR        = 0x0002;
constexpr uint16_t MSG_STATUS       = 0x0003;
constexpr uint16_t MSG_CALIBRATION  = 0x0100;
constexpr uint16_t MSG_OVERRUN      = 0x0101;

// TX message type (host -> device on EP 0x02/0x03)
constexpr uint16_t MSG_CAN_TX       = 0x1000;

// Command opcodes (host -> device on EP 0x01)
constexpr uint16_t CMD_RESET_MODE       = 0x001;
constexpr uint16_t CMD_NORMAL_MODE      = 0x002;
constexpr uint16_t CMD_TIMING_SLOW      = 0x004;
constexpr uint16_t CMD_FILTER_STD       = 0x008;
constexpr uint16_t CMD_WR_ERR_CNT       = 0x00A;
constexpr uint16_t CMD_NOP              = 0x000;
constexpr uint16_t CMD_CLK_SET          = 0x080;

// CAN message flags (shared TX/RX, in flags field)
constexpr uint16_t FLAG_RTR            = 0x01;
constexpr uint16_t FLAG_EXT_ID         = 0x02;
constexpr uint16_t FLAG_EXT_DATA_LEN   = 0x10;  // CAN FD frame
constexpr uint16_t FLAG_BRS            = 0x20;   // Bitrate switch
constexpr uint16_t FLAG_ESI            = 0x40;   // Error state indicator

// Error counter write masks
constexpr uint16_t WRERRCNT_TE = 0x4000;
constexpr uint16_t WRERRCNT_RE = 0x8000;

// ================================================================
// Wire structures (packed, little-endian — ARM64 is LE, no swap needed)
// ================================================================

/// Build opcode_channel field: channel in bits [15:12], opcode in bits [9:0]
static inline uint16_t opcode_channel(uint8_t channel, uint16_t opcode) {
    return static_cast<uint16_t>((static_cast<uint16_t>(channel) << 12) | (opcode & 0x3FF));
}

/// Base RX message header (12 bytes)
struct __attribute__((packed)) pucan_msg {
    uint16_t size;
    uint16_t type;
    uint32_t ts_low;
    uint32_t ts_high;
};

/// CAN RX message (28 bytes + variable data)
struct __attribute__((packed)) pucan_rx_msg {
    uint16_t size;
    uint16_t type;        // MSG_CAN_RX
    uint32_t ts_low;
    uint32_t ts_high;
    uint32_t tag_low;
    uint32_t tag_high;
    uint8_t  channel_dlc;  // [3:0]=channel, [7:4]=DLC
    uint8_t  client;
    uint16_t flags;
    uint32_t can_id;
    // uint8_t data[] follows
};

/// CAN TX message (20 bytes + variable data)
struct __attribute__((packed)) pucan_tx_msg {
    uint16_t size;         // ALIGN(20 + data_len, 4)
    uint16_t type;         // MSG_CAN_TX
    uint32_t tag_low;
    uint32_t tag_high;
    uint8_t  channel_dlc;  // (channel & 0xf) | (dlc << 4)
    uint8_t  client;
    uint16_t flags;
    uint32_t can_id;
    // uint8_t data[] follows
};

/// Generic command (8 bytes)
struct __attribute__((packed)) pucan_command {
    uint16_t opcode_channel;
    uint16_t args[3];
};

/// Arbitration bit timing command (8 bytes)
struct __attribute__((packed)) pucan_timing_slow {
    uint16_t opcode_channel;  // CMD_TIMING_SLOW
    uint8_t  ewl;             // Error Warning Limit (default 96)
    uint8_t  sjw_t;           // SJW-1 [6:0] | triple_sampling << 7
    uint8_t  tseg2;           // TSEG2-1
    uint8_t  tseg1;           // (prop_seg+phase_seg1)-1
    uint16_t brp;             // BRP-1
};

/// Write error counters command (8 bytes)
struct __attribute__((packed)) pucan_wr_err_cnt {
    uint16_t opcode_channel;  // CMD_WR_ERR_CNT
    uint16_t sel_mask;        // WRERRCNT_TE | WRERRCNT_RE
    uint8_t  tx_counter;
    uint8_t  rx_counter;
    uint16_t unused;
};

/// Standard filter command (8 bytes)
struct __attribute__((packed)) pucan_filter_std {
    uint16_t opcode_channel;  // CMD_FILTER_STD
    uint16_t idx;             // Row index (0..63)
    uint32_t mask;            // 32-bit acceptance mask
};

/// Firmware info (read via USB control transfer)
struct __attribute__((packed)) pcan_ufd_fw_info {
    uint16_t size_of;
    uint16_t type;
    uint8_t  hw_type;
    uint8_t  bl_version[3];
    uint8_t  hw_version;
    uint8_t  fw_version[3];
    uint32_t dev_id[2];
    uint32_t ser_no;
    uint32_t flags;
    // Extended (type >= 2):
    uint8_t  cmd_out_ep;
    uint8_t  cmd_in_ep;
    uint8_t  data_out_ep[2];
    uint8_t  data_in_ep;
    uint8_t  dummy[3];
};

// ================================================================
// PCAN Codec class — satisfies CanProtocol concept
// ================================================================

class Codec {
public:
    // --- CanProtocol unified interface ---

    kern_return_t configureDevice(IOUSBHostDevice* dev, IOService* forClient);

    template <typename SendFn>
    kern_return_t openChannel(IOUSBHostDevice* dev, IOService* forClient,
                              uint32_t bitrate, uint8_t channel, SendFn&& sendFn) {
        if (channel >= channelCount_) {
            DEXT_LOG("pcan::openChannel: invalid channel %u (max %u)", channel, channelCount_);
            return kIOReturnBadArgument;
        }

        // Send 1: Accept-all standard CAN frame filters (64 rows × 8 bytes = 512 bytes)
        // Linux kernel: pcan_usb_fd_set_filter_std(dev, -1, 0xffffffff)
        {
            uint8_t filterBuf[CMD_BUFFER_SIZE];
            for (uint8_t row = 0; row < 64; row++) {
                writeFilterStd(filterBuf + row * 8, channel, row, 0xFFFFFFFF);
            }
            kern_return_t ret = sendFn(filterBuf, CMD_BUFFER_SIZE);
            if (ret != kIOReturnSuccess) {
                DEXT_LOG("pcan::openChannel: filter send failed: 0x%x", ret);
                return ret;
            }
        }

        // Send 2: Init commands — clock set, bit timing, reset errors, normal mode
        {
            uint8_t cmdBuf[CMD_BUFFER_SIZE];
            memset(cmdBuf, 0xFF, CMD_BUFFER_SIZE);  // Fill with end-of-collection
            uint32_t off = 0;

            // Set clock domain to 80 MHz — only on first channel open
            if (!channelOpen_[0] && !channelOpen_[1]) {
                writeClockSet(cmdBuf + off);
                off += 8;
            }

            writeBitTiming(cmdBuf + off, channel, bitrate);
            off += 8;

            writeResetErrors(cmdBuf + off, channel);
            off += 8;

            writeNormalMode(cmdBuf + off, channel);
            off += 8;

            DEXT_LOG("pcan::openChannel: ch=%u bitrate=%u cmdBytes=%u", channel, bitrate, off);

            kern_return_t ret = sendFn(cmdBuf, CMD_BUFFER_SIZE);
            if (ret != kIOReturnSuccess) {
                DEXT_LOG("pcan::openChannel: init send failed: 0x%x", ret);
                return ret;
            }
        }

        channelOpen_[channel] = true;
        channelBitrate_[channel] = bitrate;
        return kIOReturnSuccess;
    }

    template <typename SendFn>
    kern_return_t closeChannel(IOUSBHostDevice* dev, IOService* forClient,
                               uint8_t channel, SendFn&& sendFn) {
        if (channel >= channelCount_) {
            DEXT_LOG("pcan::closeChannel: invalid channel %u", channel);
            return kIOReturnBadArgument;
        }

        uint8_t cmdBuf[CMD_BUFFER_SIZE];
        memset(cmdBuf, 0xFF, CMD_BUFFER_SIZE);

        uint32_t off = 0;
        if (channelOpen_[channel] && off + 8 <= CMD_BUFFER_SIZE) {
            writeResetMode(cmdBuf + off, channel);
            off += 8;
            channelOpen_[channel] = false;
            channelBitrate_[channel] = 0;
        }

        DEXT_LOG("pcan::closeChannel: ch=%u cmdBytes=%u", channel, off);
        return sendFn(reinterpret_cast<const uint8_t*>(cmdBuf), CMD_BUFFER_SIZE);
    }

    void onStopIO(IOUSBHostDevice* dev, IOService* forClient) {
        // Mark channels closed — USB disconnect handles device-side cleanup
        for (uint8_t ch = 0; ch < channelCount_; ch++)
            channelOpen_[ch] = false;
    }

    void onTimer(uint64_t now) {}

    // TX drain: read one frame from ring, encode to PCAN binary, send
    template <typename SendFn>
    kern_return_t drainTx(SharedRingHeader* hdr, const uint8_t* txData,
                          bool txInFlight, SendFn&& sendFn) {
        if (!hdr || !txData) return kIOReturnNotReady;
        if (txInFlight) return kIOReturnBusy;

        auto* txCtrl = &hdr->tx;
        uint32_t tail = ring_load_tail_relaxed(txCtrl);

        // One frame per USB transfer (PCAN firmware requirement)
        auto txRead = shared_ring::readTxFrame(hdr, txData, tail);
        if (!txRead.valid && !txRead.dropped) return kIOReturnSuccess;

        tail += txRead.bytesConsumed;
        if (txRead.dropped) {
            ring_store_tail_release(txCtrl, tail);
            return kIOReturnSuccess;
        }

        // Encode to pucan_tx_msg + null terminator
        uint8_t txBuf[128];  // Max: 20 + 64 (FD payload) + padding + 4 (null) = 92
        uint32_t txSize = encodeTxFrame(txRead.frame, txBuf, sizeof(txBuf));
        if (txSize == 0) {
            __atomic_fetch_add(&hdr->txDropped, 1, __ATOMIC_RELAXED);
            ring_store_tail_release(txCtrl, tail);
            return kIOReturnSuccess;
        }

        ring_store_tail_release(txCtrl, tail);
        __atomic_fetch_add(&hdr->txDrainCount, 1, __ATOMIC_RELAXED);

        return sendFn(txBuf, txSize);
    }

    // RX processing: parse PCAN TLV stream from EP 0x82, emit CAN frames
    template <typename FrameFn>
    void processRxData(const uint8_t* data, uint32_t len, FrameFn&& onFrame) {
        const uint8_t* ptr = data;
        const uint8_t* end = data + len;

        while (ptr + sizeof(pucan_msg) <= end) {
            const auto* msg = reinterpret_cast<const pucan_msg*>(ptr);
            uint16_t msgSize = msg->size;
            uint16_t msgType = msg->type;

            if (msgSize == 0) break;              // End of message stream
            if (ptr + msgSize > end) break;        // Truncated

            if (msgType == MSG_CAN_RX && msgSize >= sizeof(pucan_rx_msg)) {
                decodeRxFrame(ptr, msgSize, onFrame);
            }

            ptr += msgSize;
        }
    }

    bool needsDrainTx() const { return false; }

    // --- Metadata ---

    bool needsCDC()          const { return false; }
    const char* name()       const { return "PCAN"; }
    uint8_t protocolId()     const { return kCANProtocolPCAN; }

    // --- Diagnostics ---

    uint32_t diagLine(const uint8_t* buf, uint32_t bufSize) const;

    // --- Accessors ---

    uint8_t channelCount()            const { return channelCount_; }
    bool isChannelOpen(uint8_t ch)    const { return ch < 2 && channelOpen_[ch]; }

private:
    // Encode a canfd_frame to PCAN TX binary format.
    // Returns total bytes written (message + null terminator), or 0 on failure.
    static uint32_t encodeTxFrame(const canfd_frame& frame,
                                   uint8_t* out, uint32_t outSize);

    // Decode a PCAN RX message to canfd_frame
    template <typename FrameFn>
    static void decodeRxFrame(const uint8_t* data, uint32_t size, FrameFn&& onFrame) {
        const auto* rx = reinterpret_cast<const pucan_rx_msg*>(data);

        canfd_frame frame;
        memset(&frame, 0, sizeof(frame));

        uint8_t channel = rx->channel_dlc & 0x0F;
        uint8_t dlc = rx->channel_dlc >> 4;
        uint16_t flags = rx->flags;

        frame.can_id = rx->can_id;
        if (flags & FLAG_EXT_ID) frame.can_id |= CAN_EFF_FLAG;
        if (flags & FLAG_RTR)    frame.can_id |= CAN_RTR_FLAG;

        if (flags & FLAG_EXT_DATA_LEN) {
            // CAN FD frame
            frame.len = can_fd_dlc2len(dlc);
            frame.flags = CANFD_FDF;
            if (flags & FLAG_BRS) frame.flags |= CANFD_BRS;
            if (flags & FLAG_ESI) frame.flags |= CANFD_ESI;
        } else {
            // Classic CAN frame
            frame.len = (dlc > CAN_MAX_DLEN) ? CAN_MAX_DLEN : dlc;
            frame.flags = 0;
        }

        // Set channel in __res0 field
        CAN_CHANNEL(frame) = channel;

        // Copy payload (if not RTR)
        if (!(flags & FLAG_RTR)) {
            uint32_t payloadOffset = sizeof(pucan_rx_msg);
            uint32_t payloadAvail = size - payloadOffset;
            uint8_t copyLen = frame.len;
            if (copyLen > payloadAvail) copyLen = static_cast<uint8_t>(payloadAvail);
            if (copyLen > CANFD_MAX_DLEN) copyLen = CANFD_MAX_DLEN;
            memcpy(frame.data, data + payloadOffset, copyLen);
        }

        onFrame(frame);
    }

    // Command builders (each writes 8 bytes at `out`)
    static void writeClockSet(uint8_t* out);
    void writeBitTiming(uint8_t* out, uint8_t channel, uint32_t bitrate);
    static void writeFilterStd(uint8_t* out, uint8_t channel, uint16_t row, uint32_t mask);
    static void writeResetErrors(uint8_t* out, uint8_t channel);
    static void writeNormalMode(uint8_t* out, uint8_t channel);
    static void writeResetMode(uint8_t* out, uint8_t channel);

    // Calculate bit timing parameters for given bitrate (80 MHz clock)
    static bool calculateBitTiming(uint32_t bitrate,
                                    uint32_t& brp, uint32_t& tseg1,
                                    uint32_t& tseg2, uint32_t& sjw);

    // State
    uint8_t  channelCount_ = 2;  // PCAN-USB Pro FD = 2 channels
    bool     channelOpen_[2] = {false, false};
    uint32_t channelBitrate_[2] = {0, 0};
    uint32_t fwVersion_[3] = {};
    uint32_t serialNo_ = 0;
};

static_assert(CanProtocol<Codec>);

} // namespace pcan
