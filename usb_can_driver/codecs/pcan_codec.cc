/*
 * PcanCodec.cc
 * PCAN-USB Pro FD binary protocol implementation.
 *
 * Protocol reference: Linux kernel pcan_usb_fd.c
 */

#include "pcan_codec.h"

#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <USBDriverKit/IOUSBHostDevice.h>

#include <cstring>

namespace pcan {

// ================================================================
// Codec: device configuration (USB control requests)
// ================================================================

kern_return_t Codec::configureDevice(IOUSBHostDevice* dev, IOService* forClient) {
    if (!dev) return kIOReturnNotReady;

    // 1. Read firmware info via USB vendor control transfer
    IOBufferMemoryDescriptor* fwBuf = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionIn, sizeof(pcan_ufd_fw_info), 0, &fwBuf);
    if (ret != kIOReturnSuccess || !fwBuf) {
        DEXT_LOG("pcan::configureDevice: create fw buf failed: 0x%x", ret);
        return ret;
    }

    uint16_t bytesTransferred = 0;
    ret = dev->DeviceRequest(
        forClient,
        0xC0,                        // bmRequestType: vendor, device, IN
        REQ_INFO,                    // bRequest
        INFO_FW,                     // wValue
        0,                           // wIndex
        sizeof(pcan_ufd_fw_info),    // wLength
        fwBuf,
        &bytesTransferred,
        5000);

    if (ret == kIOReturnSuccess && bytesTransferred >= 16) {
        uint64_t addr = 0, len = 0;
        fwBuf->Map(0, 0, 0, 0, &addr, &len);
        const auto* fw = reinterpret_cast<const pcan_ufd_fw_info*>(addr);

        fwVersion_[0] = fw->fw_version[0];
        fwVersion_[1] = fw->fw_version[1];
        fwVersion_[2] = fw->fw_version[2];
        serialNo_ = fw->ser_no;

        DEXT_LOG("pcan::configureDevice: FW v%u.%u.%u SN=%u hwType=%u",
                 fwVersion_[0], fwVersion_[1], fwVersion_[2],
                 serialNo_, fw->hw_type);
    } else {
        DEXT_LOG("pcan::configureDevice: FW info read failed: 0x%x bytes=%u (continuing)",
                 ret, bytesTransferred);
    }
    fwBuf->release();

    // 2. Send "driver loaded" notification via USB vendor control transfer
    IOBufferMemoryDescriptor* drvBuf = nullptr;
    ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionOut, FCT_DRVLD_LEN, 0, &drvBuf);
    if (ret == kIOReturnSuccess && drvBuf) {
        uint64_t addr = 0, len = 0;
        drvBuf->Map(0, 0, 0, 0, &addr, &len);
        memset(reinterpret_cast<void*>(addr), 0, FCT_DRVLD_LEN);
        reinterpret_cast<uint8_t*>(addr)[1] = 1;  // loaded = true

        bytesTransferred = 0;
        ret = dev->DeviceRequest(
            forClient,
            0x40,                    // bmRequestType: vendor, device, OUT
            REQ_FCT,                 // bRequest
            FCT_DRVLD,               // wValue
            0,                       // wIndex
            FCT_DRVLD_LEN,           // wLength
            drvBuf,
            &bytesTransferred,
            5000);

        if (ret == kIOReturnSuccess) {
            DEXT_LOG("pcan::configureDevice: driver-loaded notification sent");
        } else {
            DEXT_LOG("pcan::configureDevice: driver-loaded failed: 0x%x (continuing)", ret);
        }
        drvBuf->release();
    }

    channelCount_ = 2;  // PCAN-USB Pro FD is always dual-channel
    DEXT_LOG("pcan::configureDevice: done, channels=%u", channelCount_);
    return kIOReturnSuccess;
}

// ================================================================
// Codec: bit timing calculation
// ================================================================

bool Codec::calculateBitTiming(uint32_t bitrate,
                                uint32_t& brp, uint32_t& tseg1,
                                uint32_t& tseg2, uint32_t& sjw) {
    if (bitrate == 0) return false;

    // Search for valid timing with PCAN 80 MHz clock
    // Constraints: BRP 1..1024, TSEG1 1..256, TSEG2 1..128, SJW 1..128
    for (uint32_t testBrp = 1; testBrp <= 1024; testBrp++) {
        uint32_t tq = CRYSTAL_HZ / (bitrate * testBrp);
        if (tq < 3 || tq > 385) continue;  // min 1+1+1, max 1+256+128

        uint32_t tsegTotal = tq - 1;  // 1 sync_seg + tseg1 + tseg2
        uint32_t t1 = (tsegTotal * 3) / 4;  // ~75% sample point
        uint32_t t2 = tsegTotal - t1;

        if (t1 < 1 || t1 > 256) continue;
        if (t2 < 1 || t2 > 128) continue;

        // Verify exact match
        uint32_t actual = CRYSTAL_HZ / (testBrp * (1 + t1 + t2));
        if (actual != bitrate) continue;

        brp = testBrp;
        tseg1 = t1;
        tseg2 = t2;
        sjw = (t2 < 4) ? t2 : 4;  // SJW = min(TSEG2, 4)
        return true;
    }

    return false;
}

// ================================================================
// Codec: command builders (each writes 8 bytes)
// ================================================================

void Codec::writeClockSet(uint8_t* out) {
    memset(out, 0, 8);
    uint16_t oc = opcode_channel(0, CMD_CLK_SET);
    memcpy(out, &oc, 2);
    out[2] = 0;  // PCAN_UFD_CLK_80MHZ = mode 0
}

void Codec::writeBitTiming(uint8_t* out, uint8_t channel, uint32_t bitrate) {
    uint32_t brp, tseg1, tseg2, sjw;
    if (!calculateBitTiming(bitrate, brp, tseg1, tseg2, sjw)) {
        DEXT_LOG("pcan::writeBitTiming: no valid timing for bitrate=%u, writing NOP", bitrate);
        memset(out, 0, 8);
        uint16_t oc = opcode_channel(channel, CMD_NOP);
        memcpy(out, &oc, 2);
        return;
    }

    auto* cmd = reinterpret_cast<pucan_timing_slow*>(out);
    memset(cmd, 0, 8);
    cmd->opcode_channel = opcode_channel(channel, CMD_TIMING_SLOW);
    cmd->ewl = 96;                          // Default error warning limit
    cmd->sjw_t = (sjw - 1) & 0x7F;         // SJW - 1 (no triple sampling)
    cmd->tseg2 = (tseg2 - 1) & 0x7F;
    cmd->tseg1 = (tseg1 - 1) & 0xFF;
    cmd->brp = (brp - 1) & 0x3FF;

    DEXT_LOG("pcan::writeBitTiming: ch=%u bitrate=%u brp=%u tseg1=%u tseg2=%u sjw=%u",
             channel, bitrate, brp, tseg1, tseg2, sjw);
}

void Codec::writeFilterStd(uint8_t* out, uint8_t channel, uint16_t row, uint32_t mask) {
    auto* cmd = reinterpret_cast<pucan_filter_std*>(out);
    memset(cmd, 0, 8);
    cmd->opcode_channel = opcode_channel(channel, CMD_FILTER_STD);
    cmd->idx = row;
    cmd->mask = mask;
}

void Codec::writeResetErrors(uint8_t* out, uint8_t channel) {
    auto* cmd = reinterpret_cast<pucan_wr_err_cnt*>(out);
    memset(cmd, 0, 8);
    cmd->opcode_channel = opcode_channel(channel, CMD_WR_ERR_CNT);
    cmd->sel_mask = WRERRCNT_TE | WRERRCNT_RE;
    cmd->tx_counter = 0;
    cmd->rx_counter = 0;
}

void Codec::writeNormalMode(uint8_t* out, uint8_t channel) {
    auto* cmd = reinterpret_cast<pucan_command*>(out);
    memset(cmd, 0, 8);
    cmd->opcode_channel = opcode_channel(channel, CMD_NORMAL_MODE);
}

void Codec::writeResetMode(uint8_t* out, uint8_t channel) {
    auto* cmd = reinterpret_cast<pucan_command*>(out);
    memset(cmd, 0, 8);
    cmd->opcode_channel = opcode_channel(channel, CMD_RESET_MODE);
}

// ================================================================
// Codec: TX encoding
// ================================================================

uint32_t Codec::encodeTxFrame(const canfd_frame& frame,
                               uint8_t* out, uint32_t outSize) {
    bool isFD = (frame.flags & CANFD_FDF) != 0;
    uint8_t dataLen = frame.len;
    if (isFD) {
        if (dataLen > CANFD_MAX_DLEN) dataLen = CANFD_MAX_DLEN;
    } else {
        if (dataLen > CAN_MAX_DLEN) dataLen = CAN_MAX_DLEN;
    }

    constexpr uint32_t headerSize = 20;  // sizeof(pucan_tx_msg) without data
    uint32_t msgSize = (headerSize + dataLen + 3) & ~3u;  // 4-byte aligned
    uint32_t totalSize = msgSize + 4;  // + null terminator

    if (totalSize > outSize) return 0;

    memset(out, 0, totalSize);

    auto* tx = reinterpret_cast<pucan_tx_msg*>(out);
    tx->size = static_cast<uint16_t>(msgSize);
    tx->type = MSG_CAN_TX;
    tx->tag_low = 0;    // No echo tracking
    tx->tag_high = 0;

    uint8_t channel = CAN_CHANNEL(frame);
    uint8_t dlc = isFD ? can_fd_len2dlc(dataLen) : dataLen;
    tx->channel_dlc = static_cast<uint8_t>((channel & 0x0F) | (dlc << 4));
    tx->client = 0;

    uint16_t flags = 0;
    if (frame.can_id & CAN_EFF_FLAG) flags |= FLAG_EXT_ID;
    if (isFD) {
        flags |= FLAG_EXT_DATA_LEN;
        if (frame.flags & CANFD_BRS) flags |= FLAG_BRS;
        if (frame.flags & CANFD_ESI) flags |= FLAG_ESI;
    } else {
        if (frame.can_id & CAN_RTR_FLAG) flags |= FLAG_RTR;
    }
    tx->flags = flags;

    // Strip flag bits from CAN ID
    uint32_t idMask = (frame.can_id & CAN_EFF_FLAG) ? CAN_EFF_MASK : CAN_SFF_MASK;
    tx->can_id = frame.can_id & idMask;

    // Copy payload after header
    memcpy(out + headerSize, frame.data, dataLen);

    // Null terminator at end (already zero from memset)
    return totalSize;
}

// ================================================================
// Codec: lifecycle + diagnostics
// ================================================================

uint32_t Codec::diagLine(const uint8_t* buf, uint32_t bufSize) const {
    (void)buf;
    (void)bufSize;
    return 0;
}

} // namespace pcan
