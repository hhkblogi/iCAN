/*
 * SlcanCodec.cc
 * SLCAN text protocol encoder/decoder + Codec unified methods.
 */

#include "slcan_codec.h"

#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <USBDriverKit/IOUSBHostDevice.h>

#include <cstring>

namespace slcan {

// ================================================================
// Free functions: SLCAN text codec
// ================================================================

static inline char hex_nibble(uint8_t v) {
    v &= 0x0F;
    return (v < 10) ? ('0' + v) : ('A' + v - 10);
}

static inline int hex_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

uint32_t encode(const canfd_frame* frame, char* out, uint32_t outSize) {
    if (!frame || !out || outSize < 8) return 0;

    uint32_t pos = 0;
    bool isExtended = (frame->can_id & CAN_EFF_FLAG) != 0;
    bool isFD = (frame->flags & CANFD_FDF) != 0;
    uint32_t rawId = isExtended ? (frame->can_id & CAN_EFF_MASK)
                                : (frame->can_id & CAN_SFF_MASK);

    // Frame type character
    if (isFD) {
        out[pos++] = isExtended ? 'D' : 'd';
    } else {
        out[pos++] = isExtended ? 'T' : 't';
    }

    // CAN ID
    if (isExtended) {
        for (int i = 7; i >= 0; i--) {
            out[pos++] = hex_nibble((rawId >> (i * 4)) & 0x0F);
        }
    } else {
        out[pos++] = hex_nibble((rawId >> 8) & 0x0F);
        out[pos++] = hex_nibble((rawId >> 4) & 0x0F);
        out[pos++] = hex_nibble(rawId & 0x0F);
    }

    // DLC
    uint8_t dlc = isFD ? can_fd_len2dlc(frame->len) : frame->len;
    out[pos++] = hex_nibble(dlc);

    // Data bytes
    uint8_t dataLen = frame->len;
    if (!isFD && dataLen > CAN_MAX_DLEN) dataLen = CAN_MAX_DLEN;
    if (isFD && dataLen > CANFD_MAX_DLEN) dataLen = CANFD_MAX_DLEN;

    if (pos + dataLen * 2 + 1 > outSize) return 0;

    for (uint8_t i = 0; i < dataLen; i++) {
        out[pos++] = hex_nibble(frame->data[i] >> 4);
        out[pos++] = hex_nibble(frame->data[i]);
    }

    out[pos++] = '\r';
    return pos;
}

bool decode(const char* buf, uint32_t len, canfd_frame* out) {
    if (!buf || !out || len < 5) return false;

    memset(out, 0, sizeof(canfd_frame));

    bool isExtended, isFD;
    switch (buf[0]) {
        case 't': isExtended = false; isFD = false; break;
        case 'T': isExtended = true;  isFD = false; break;
        case 'd': isExtended = false; isFD = true;  break;
        case 'D': isExtended = true;  isFD = true;  break;
        default: return false;
    }

    uint32_t pos = 1;
    uint32_t idDigits = isExtended ? 8 : 3;
    if (pos + idDigits + 1 > len) return false;

    // Parse CAN ID
    canid_t canId = 0;
    for (uint32_t i = 0; i < idDigits; i++) {
        int v = hex_val(buf[pos++]);
        if (v < 0) return false;
        canId = (canId << 4) | static_cast<uint32_t>(v);
    }
    if (isExtended) canId |= CAN_EFF_FLAG;
    out->can_id = canId;

    // Parse DLC
    int dlcVal = hex_val(buf[pos++]);
    if (dlcVal < 0 || dlcVal > 15) return false;

    uint8_t dataLen = isFD ? can_fd_dlc2len(static_cast<uint8_t>(dlcVal))
                           : static_cast<uint8_t>(dlcVal);
    if (!isFD && dataLen > CAN_MAX_DLEN) return false;
    out->len = dataLen;
    if (isFD) out->flags = CANFD_FDF;

    // Parse data bytes
    if (pos + dataLen * 2 > len) return false;
    for (uint8_t i = 0; i < dataLen; i++) {
        int hi = hex_val(buf[pos++]);
        int lo = hex_val(buf[pos++]);
        if (hi < 0 || lo < 0) return false;
        out->data[i] = static_cast<uint8_t>((hi << 4) | lo);
    }

    return true;
}

char bitrateToCode(uint32_t bitrate) {
    switch (bitrate) {
        case 10000:   return '0';
        case 20000:   return '1';
        case 50000:   return '2';
        case 100000:  return '3';
        case 125000:  return '4';
        case 250000:  return '5';
        case 500000:  return '6';
        case 800000:  return '7';
        case 1000000: return '8';
        default:      return 0;
    }
}

// ================================================================
// Codec class: unified interface for variant dispatch
// ================================================================

kern_return_t Codec::configureDevice(IOUSBHostDevice* dev, IOService* forClient) {
    if (!dev) return kIOReturnNotReady;

    // Set default CDC line coding (115200 8N1)
    LineCoding coding;
    coding.dwDTERate = 115200;
    coding.bCharFormat = 0;   // 1 stop bit
    coding.bParityType = 0;   // no parity
    coding.bDataBits = 8;

    IOBufferMemoryDescriptor* dataMD = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionOut, sizeof(LineCoding), 0, &dataMD);
    if (ret != kIOReturnSuccess || !dataMD) return kIOReturnNoMemory;

    uint64_t addr = 0, len = 0;
    dataMD->Map(0, 0, 0, 0, &addr, &len);
    memcpy(reinterpret_cast<void*>(addr), &coding, sizeof(LineCoding));

    uint16_t bytesTransferred = 0;
    ret = dev->DeviceRequest(forClient, 0x21, kSetLineCoding, 0, 0,
                             static_cast<uint16_t>(sizeof(LineCoding)),
                             dataMD, &bytesTransferred, 0);
    dataMD->release();
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("slcan::configureDevice: SetLineCoding failed: 0x%x (non-critical)", ret);
    }

    // Set DTR + RTS
    bytesTransferred = 0;
    ret = dev->DeviceRequest(forClient, 0x21, kSetControlLineState,
                             0x03, 0, 0, nullptr, &bytesTransferred, 0);
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("slcan::configureDevice: SetControlLineState failed: 0x%x (non-critical)", ret);
    }

    return kIOReturnSuccess;
}

uint32_t Codec::diagLine(const uint8_t* buf, uint32_t bufSize) const {
    // Diagnostics are logged directly by the driver using accumulator() accessors.
    (void)buf;
    (void)bufSize;
    return 0;
}

} // namespace slcan
