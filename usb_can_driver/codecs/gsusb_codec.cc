/*
 * GsusbCodec.cc
 * gs_usb binary protocol implementation.
 */

#include "gsusb_codec.h"

#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <USBDriverKit/IOUSBHostDevice.h>

#include <cstring>

namespace gsusb {

// ================================================================
// Free functions: frame codec
// ================================================================

RxResult decodeRxTransfer(const uint8_t* data, uint32_t len) {
    RxResult result{};
    result.type = RxResult::Invalid;

    if (len < GS_HOST_FRAME_CLASSIC_SIZE) return result;

    const auto* hdr = reinterpret_cast<const gs_host_frame_header*>(data);
    bool isFD = (hdr->flags & GS_CAN_FLAG_FD) != 0;
    uint32_t gsFrameSize = isFD ? GS_HOST_FRAME_FD_SIZE : GS_HOST_FRAME_CLASSIC_SIZE;

    if (gsFrameSize > len) return result;  // truncated

    if (hdr->echo_id != 0xFFFFFFFF) {
        // TX echo — device confirms CAN transmission
        result.type = RxResult::TxEcho;
        return result;
    }

    // RX frame — convert gs_host_frame → canfd_frame
    result.type = RxResult::Frame;
    memset(&result.frame, 0, sizeof(canfd_frame));
    result.frame.can_id = hdr->can_id;

    uint8_t dlcVal = hdr->can_dlc;
    if (isFD) {
        result.frame.len = can_fd_dlc2len(dlcVal);
        result.frame.flags = CANFD_FDF;
        if (hdr->flags & GS_CAN_FLAG_BRS) result.frame.flags |= CANFD_BRS;
        if (hdr->flags & GS_CAN_FLAG_ESI) result.frame.flags |= CANFD_ESI;
    } else {
        result.frame.len = (dlcVal > CAN_MAX_DLEN) ? CAN_MAX_DLEN : dlcVal;
        result.frame.flags = 0;
    }

    // Copy payload (starts right after header)
    const uint8_t* payload = data + sizeof(gs_host_frame_header);
    uint8_t copyLen = result.frame.len;
    uint8_t maxLen = isFD ? CANFD_MAX_DLEN : CAN_MAX_DLEN;
    if (copyLen > maxLen) copyLen = maxLen;
    memcpy(result.frame.data, payload, copyLen);

    return result;
}

uint32_t encodeTxFrame(const canfd_frame& frame, uint32_t echoId,
                       uint8_t* out, uint32_t outSize) {
    bool isFD = (frame.flags & CANFD_FDF) != 0;
    uint32_t gsFrameSize = isFD ? GS_HOST_FRAME_FD_SIZE : GS_HOST_FRAME_CLASSIC_SIZE;

    if (outSize < gsFrameSize) return 0;

    memset(out, 0, gsFrameSize);

    auto* hdr = reinterpret_cast<gs_host_frame_header*>(out);
    hdr->echo_id = echoId;
    hdr->can_id = frame.can_id;
    hdr->can_dlc = isFD ? can_fd_len2dlc(frame.len) : frame.len;
    hdr->channel = 0;
    hdr->flags = 0;
    if (isFD) {
        hdr->flags |= GS_CAN_FLAG_FD;
        if (frame.flags & CANFD_BRS) hdr->flags |= GS_CAN_FLAG_BRS;
        if (frame.flags & CANFD_ESI) hdr->flags |= GS_CAN_FLAG_ESI;
    }
    hdr->reserved = 0;

    // Copy payload after header
    uint8_t payloadLen = frame.len;
    uint8_t maxLen = isFD ? CANFD_MAX_DLEN : CAN_MAX_DLEN;
    if (payloadLen > maxLen) payloadLen = maxLen;
    memcpy(out + sizeof(gs_host_frame_header), frame.data, payloadLen);

    return gsFrameSize;
}

// ================================================================
// Codec class: unified interface + protocol state
// ================================================================

bool Codec::checkStall(uint64_t now) {
    if (echoInflight_ < kMaxEchoInflight) return false;

    if (echoStallStart_ == 0) {
        echoStallStart_ = now;
        return false;
    }

    if (now - echoStallStart_ > kStallTimeoutNS) {
        DEXT_LOG("TX echo stall: %u in-flight for >%llums, releasing 1 slot",
                 echoInflight_, kStallTimeoutNS / 1000000ULL);
        echoInflight_--;
        echoStallStart_ = 0;
        return true;
    }

    return false;
}

kern_return_t Codec::sendControlRequest(
    IOUSBHostDevice* dev, IOService* forClient,
    uint8_t breq, uint16_t wValue,
    const void* sendData, uint16_t sendLen,
    void* recvData, uint16_t recvLen)
{
    if (!dev) return kIOReturnNotReady;

    bool isOut = (sendData != nullptr && sendLen > 0);
    uint16_t wLength = isOut ? sendLen : recvLen;

    IOBufferMemoryDescriptor* dataMD = nullptr;
    if (wLength > 0) {
        kern_return_t ret = IOBufferMemoryDescriptor::Create(
            isOut ? kIOMemoryDirectionOut : kIOMemoryDirectionIn,
            wLength, 0, &dataMD);
        if (ret != kIOReturnSuccess || !dataMD) {
            DEXT_LOG("gsusb::sendControlRequest: Create MD failed: 0x%x", ret);
            return kIOReturnNoMemory;
        }

        if (isOut) {
            uint64_t addr = 0, len = 0;
            dataMD->Map(0, 0, 0, 0, &addr, &len);
            memcpy(reinterpret_cast<void*>(addr), sendData, sendLen);
        }
    }

    uint16_t bytesTransferred = 0;
    uint8_t bmRequestType = isOut ? 0x41 : 0xC1;

    kern_return_t ret = dev->DeviceRequest(
        forClient,
        bmRequestType,
        breq,
        wValue,
        0,              // wIndex: interface 0
        wLength,
        dataMD,
        &bytesTransferred,
        5000);          // 5 second timeout

    if (ret == kIOReturnSuccess && !isOut && recvData && recvLen > 0 && dataMD) {
        uint64_t addr = 0, len = 0;
        dataMD->Map(0, 0, 0, 0, &addr, &len);
        uint16_t copyLen = (bytesTransferred < recvLen) ? bytesTransferred : recvLen;
        memcpy(recvData, reinterpret_cast<void*>(addr), copyLen);
    }

    if (dataMD) dataMD->release();

    if (ret != kIOReturnSuccess) {
        DEXT_LOG("gsusb::sendControlRequest: breq=%u wValue=%u failed: 0x%x", breq, wValue, ret);
    }

    return ret;
}

kern_return_t Codec::configureDevice(IOUSBHostDevice* dev, IOService* forClient) {
    kern_return_t ret;

    // 1. Send HOST_FORMAT
    gs_host_config hostConfig;
    hostConfig.byte_order = 0x0000BEEF;
    ret = sendControlRequest(dev, forClient, GS_USB_BREQ_HOST_FORMAT, 1,
                             &hostConfig, sizeof(hostConfig), nullptr, 0);
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("gsusb::configureDevice: HOST_FORMAT failed: 0x%x", ret);
        return ret;
    }
    DEXT_LOG("gsusb::configureDevice: HOST_FORMAT OK");

    // 2. Query DEVICE_CONFIG
    memset(&deviceConfig_, 0, sizeof(deviceConfig_));
    ret = sendControlRequest(dev, forClient, GS_USB_BREQ_DEVICE_CONFIG, 1,
                             nullptr, 0, &deviceConfig_, sizeof(gs_device_config));
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("gsusb::configureDevice: DEVICE_CONFIG failed: 0x%x", ret);
        return ret;
    }
    DEXT_LOG("gsusb::configureDevice: DEVICE_CONFIG: icount=%u sw=%u hw=%u",
             deviceConfig_.icount, deviceConfig_.sw_version, deviceConfig_.hw_version);

    // 3. Query BT_CONST (channel 0)
    memset(&btConst_, 0, sizeof(btConst_));
    ret = sendControlRequest(dev, forClient, GS_USB_BREQ_BT_CONST, 0,
                             nullptr, 0, &btConst_, sizeof(gs_device_bt_const));
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("gsusb::configureDevice: BT_CONST failed: 0x%x", ret);
        return ret;
    }
    features_ = btConst_.feature;
    DEXT_LOG("gsusb::configureDevice: BT_CONST: feature=0x%x fclk=%u brp=[%u..%u] tseg1=[%u..%u] tseg2=[%u..%u]",
             btConst_.feature, btConst_.fclk_can,
             btConst_.brp_min, btConst_.brp_max,
             btConst_.tseg1_min, btConst_.tseg1_max,
             btConst_.tseg2_min, btConst_.tseg2_max);

    channelOpen_ = false;
    nextEchoId_ = 0;

    return kIOReturnSuccess;
}

kern_return_t Codec::setBitTiming(IOUSBHostDevice* dev, IOService* forClient, uint32_t bitrate) {
    if (bitrate == 0) return kIOReturnBadArgument;
    if (btConst_.fclk_can == 0) {
        DEXT_LOG("gsusb::setBitTiming: fclk_can is 0, BT_CONST not queried?");
        return kIOReturnNotReady;
    }

    gs_device_bittiming bt;
    memset(&bt, 0, sizeof(bt));
    bool found = false;

    for (uint32_t brp = btConst_.brp_min; brp <= btConst_.brp_max; brp += btConst_.brp_inc) {
        uint32_t tq = btConst_.fclk_can / (bitrate * brp);
        if (tq < 3) continue;

        uint32_t tseg_total = tq - 1;
        uint32_t tseg1 = (tseg_total * 3) / 4;
        uint32_t tseg2 = tseg_total - tseg1;

        if (tseg1 < btConst_.tseg1_min) tseg1 = btConst_.tseg1_min;
        if (tseg1 > btConst_.tseg1_max) tseg1 = btConst_.tseg1_max;
        tseg2 = tseg_total - tseg1;
        if (tseg2 < btConst_.tseg2_min) continue;
        if (tseg2 > btConst_.tseg2_max) continue;

        uint32_t actual = btConst_.fclk_can / (brp * (1 + tseg1 + tseg2));
        if (actual != bitrate) continue;

        bt.prop_seg = 0;
        bt.phase_seg1 = tseg1;
        bt.phase_seg2 = tseg2;
        bt.sjw = 1;
        bt.brp = brp;
        found = true;

        DEXT_LOG("gsusb::setBitTiming: bitrate=%u brp=%u tseg1=%u tseg2=%u sjw=%u",
                 bitrate, brp, tseg1, tseg2, bt.sjw);
        break;
    }

    if (!found) {
        DEXT_LOG("gsusb::setBitTiming: no valid timing for bitrate=%u", bitrate);
        return kIOReturnBadArgument;
    }

    return sendControlRequest(dev, forClient, GS_USB_BREQ_BITTIMING, 0,
                              &bt, sizeof(bt), nullptr, 0);
}

kern_return_t Codec::startChannel(IOUSBHostDevice* dev, IOService* forClient) {
    gs_device_mode mode;
    mode.mode = GS_CAN_MODE_START;
    mode.flags = 0;

    kern_return_t ret = sendControlRequest(dev, forClient, GS_USB_BREQ_MODE, 0,
                                           &mode, sizeof(mode), nullptr, 0);
    if (ret == kIOReturnSuccess) {
        channelOpen_ = true;
        DEXT_LOG("gsusb::startChannel: OK");
    }
    return ret;
}

kern_return_t Codec::stopChannel(IOUSBHostDevice* dev, IOService* forClient) {
    gs_device_mode mode;
    mode.mode = GS_CAN_MODE_RESET;
    mode.flags = 0;

    kern_return_t ret = sendControlRequest(dev, forClient, GS_USB_BREQ_MODE, 0,
                                           &mode, sizeof(mode), nullptr, 0);
    if (ret == kIOReturnSuccess) {
        channelOpen_ = false;
        DEXT_LOG("gsusb::stopChannel: OK");
    } else {
        DEXT_LOG("gsusb::stopChannel: failed 0x%x (forcing closed)", ret);
        channelOpen_ = false;
    }
    return ret;
}

void Codec::onStopIO(IOUSBHostDevice* dev, IOService* forClient) {
    if (channelOpen_) {
        stopChannel(dev, forClient);
    }
    resetEcho();
}

void Codec::onTimer(uint64_t now) {
    checkStall(now);
}

uint32_t Codec::diagLine(const uint8_t* buf, uint32_t bufSize) const {
    // Diagnostics logged directly by the driver using echoInflight() accessor.
    (void)buf;
    (void)bufSize;
    return 0;
}

} // namespace gsusb
