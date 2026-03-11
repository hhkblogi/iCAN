/*
 * USBCANUserClient.cpp
 * IOUserClient Implementation
 *
 * 7 ExternalMethods: Open, Close, SendData, SetBaudRate, WaitForData,
 *                    OpenChannel, CloseChannel.
 * RX/TX data via SharedRingHeader frame ring in shared memory.
 * Protocol encode/decode handled by driver codec — app reads/writes CAN frames.
 */

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/OSData.h>
#include "usb_can_user_client.h"
#include "usb_can_driver.h"
#include "protocol/can.h"
#include "can_client/ipc_methods.h"
#include "can_client/shared_ring.h"

#define LOG_PREFIX "USBCANUserClient: "
#define DEXT_LOG(fmt, ...) os_log(OS_LOG_DEFAULT, LOG_PREFIX fmt, ##__VA_ARGS__)

// Instance variables
struct USBCANUserClient_IVars {
    USBCANDriver* fDriver;
    bool fIsOpen;
    OSAction* fPendingCompletion;  // accessed with atomics for cross-queue safety
};

// Static wrapper functions for method dispatch
static kern_return_t sOpen(OSObject* target, void* reference, IOUserClientMethodArguments* args);
static kern_return_t sClose(OSObject* target, void* reference, IOUserClientMethodArguments* args);
static kern_return_t sSendData(OSObject* target, void* reference, IOUserClientMethodArguments* args);
static kern_return_t sSetBaudRate(OSObject* target, void* reference, IOUserClientMethodArguments* args);
static kern_return_t sWaitForData(OSObject* target, void* reference, IOUserClientMethodArguments* args);
static kern_return_t sOpenChannel(OSObject* target, void* reference, IOUserClientMethodArguments* args);
static kern_return_t sCloseChannel(OSObject* target, void* reference, IOUserClientMethodArguments* args);

// Method dispatch table
static const IOUserClientMethodDispatch sMethods[kCANDriverMethodCount] = {
    // kCANDriverMethodOpen
    {
        .function = sOpen,
        .checkCompletionExists = false,
        .checkScalarInputCount = 0,
        .checkStructureInputSize = 0,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = 0,
    },
    // kCANDriverMethodClose
    {
        .function = sClose,
        .checkCompletionExists = false,
        .checkScalarInputCount = 0,
        .checkStructureInputSize = 0,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = 0,
    },
    // kCANDriverMethodSendData
    {
        .function = sSendData,
        .checkCompletionExists = false,
        .checkScalarInputCount = 0,
        .checkStructureInputSize = kIOUserClientVariableStructureSize,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = 0,
    },
    // kCANDriverMethodSetBaudRate
    {
        .function = sSetBaudRate,
        .checkCompletionExists = false,
        .checkScalarInputCount = 1,  // baud rate
        .checkStructureInputSize = 0,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = 0,
    },
    // kCANDriverMethodWaitForData
    {
        .function = sWaitForData,
        .checkCompletionExists = true,
        .checkScalarInputCount = 0,
        .checkStructureInputSize = 0,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = 0,
    },
    // kCANDriverMethodOpenChannel
    {
        .function = sOpenChannel,
        .checkCompletionExists = false,
        .checkScalarInputCount = 2,  // bitrate, channel
        .checkStructureInputSize = 0,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = 0,
    },
    // kCANDriverMethodCloseChannel
    {
        .function = sCloseChannel,
        .checkCompletionExists = false,
        .checkScalarInputCount = 1,  // channel
        .checkStructureInputSize = 0,
        .checkScalarOutputCount = 0,
        .checkStructureOutputSize = 0,
    },
};

// MARK: - IOService Lifecycle

bool USBCANUserClient::init()
{
    DEXT_LOG("init");
    if (!super::init()) return false;
    ivars = IONewZero(USBCANUserClient_IVars, 1);
    return ivars != nullptr;
}

kern_return_t USBCANUserClient::Start_Impl(IOService* provider)
{
    DEXT_LOG("Start");
    kern_return_t ret = super::Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;

    ivars->fDriver = OSDynamicCast(USBCANDriver, provider);
    if (!ivars->fDriver) {
        DEXT_LOG("Provider is not USBCANDriver");
        return kIOReturnBadArgument;
    }
    ivars->fDriver->retain();
    ivars->fDriver->SetUserClient(this);

    DEXT_LOG("Start completed");
    return kIOReturnSuccess;
}

kern_return_t USBCANUserClient::Stop_Impl(IOService* provider)
{
    DEXT_LOG("Stop");
    if (ivars->fIsOpen) Close(nullptr);
    if (ivars->fDriver) {
        ivars->fDriver->SetUserClient(nullptr);
        ivars->fDriver->release();
        ivars->fDriver = nullptr;
    }
    return super::Stop(provider, SUPERDISPATCH);
}

void USBCANUserClient::free()
{
    DEXT_LOG("free");
    if (ivars) {
        OSAction* pending = __atomic_exchange_n(&ivars->fPendingCompletion, nullptr, __ATOMIC_ACQ_REL);
        if (pending) {
            pending->release();
        }
        IOSafeDeleteNULL(ivars, USBCANUserClient_IVars, 1);
    }
    super::free();
}

// MARK: - ExternalMethod Dispatch

kern_return_t USBCANUserClient::ExternalMethod(
    uint64_t selector,
    IOUserClientMethodArguments* arguments,
    const IOUserClientMethodDispatch* dispatch,
    OSObject* target,
    void* reference)
{
    if (selector >= kCANDriverMethodCount) return kIOReturnBadArgument;
    return super::ExternalMethod(selector, arguments, &sMethods[selector], this, nullptr);
}

// MARK: - Client Methods

kern_return_t USBCANUserClient::Open(IOUserClientMethodArguments* args)
{
    DEXT_LOG("Open");
    if (ivars->fIsOpen) return kIOReturnStillOpen;
    if (!ivars->fDriver) return kIOReturnNotReady;

    kern_return_t ret = ivars->fDriver->StartIO();
    if (ret == kIOReturnSuccess) ivars->fIsOpen = true;
    return ret;
}

kern_return_t USBCANUserClient::Close(IOUserClientMethodArguments* args)
{
    DEXT_LOG("Close");
    if (!ivars->fIsOpen) return kIOReturnNotOpen;

    // Cancel pending async notification (atomic for cross-queue safety)
    OSAction* pending = __atomic_exchange_n(&ivars->fPendingCompletion, nullptr, __ATOMIC_ACQ_REL);
    if (pending) {
        AsyncCompletion(pending, kIOReturnAborted, nullptr, 0);
        pending->release();
    }

    if (ivars->fDriver) ivars->fDriver->StopIO();
    ivars->fIsOpen = false;
    return kIOReturnSuccess;
}

kern_return_t USBCANUserClient::SendData(IOUserClientMethodArguments* args)
{
    if (!ivars->fIsOpen || !ivars->fDriver) return kIOReturnNotOpen;

    if (args->structureInput) {
        uint32_t inputLen = (uint32_t)args->structureInput->getLength();
        if (inputLen > 0) {
            const void* inputData = args->structureInput->getBytesNoCopy();
            if (!inputData) return kIOReturnBadArgument;
            return ivars->fDriver->SendData((const uint8_t*)inputData, inputLen);
        }
    }

    // No data: trigger TX ring drain
    return ivars->fDriver->DrainTxRing();
}

kern_return_t USBCANUserClient::SetBaudRate(IOUserClientMethodArguments* args)
{
    DEXT_LOG("SetBaudRate");
    if (!ivars->fDriver) return kIOReturnNotReady;
    if (args->scalarInputCount < 1) return kIOReturnBadArgument;
    uint32_t baudRate = (uint32_t)args->scalarInput[0];
    return ivars->fDriver->SetLineCoding(baudRate, 8, 0, 0);
}

kern_return_t USBCANUserClient::OpenChannel(IOUserClientMethodArguments* args)
{
    if (!ivars->fIsOpen || !ivars->fDriver) return kIOReturnNotOpen;
    if (args->scalarInputCount < 2) return kIOReturnBadArgument;
    uint32_t bitrate = (uint32_t)args->scalarInput[0];
    uint8_t channel = (uint8_t)args->scalarInput[1];
    DEXT_LOG("OpenChannel: bitrate=%u channel=%u", bitrate, channel);
    return ivars->fDriver->OpenChannel(bitrate, channel);
}

kern_return_t USBCANUserClient::CloseChannel(IOUserClientMethodArguments* args)
{
    if (!ivars->fIsOpen || !ivars->fDriver) return kIOReturnNotOpen;
    if (args->scalarInputCount < 1) return kIOReturnBadArgument;
    uint8_t channel = (uint8_t)args->scalarInput[0];
    DEXT_LOG("CloseChannel: channel=%u", channel);
    return ivars->fDriver->CloseChannel(channel);
}

// MARK: - Async RX Notification

kern_return_t USBCANUserClient::WaitForData(IOUserClientMethodArguments* args)
{
    if (!ivars->fIsOpen || !ivars->fDriver) return kIOReturnNotOpen;

    // Get ring buffer pointer for race checks
    SharedRingHeader* ring = reinterpret_cast<SharedRingHeader*>(ivars->fDriver->GetRxRing());

    // Race fix #1: if RX ring already has data, complete immediately
    if (ring && ring->magic == SHARED_RING_MAGIC) {
        uint32_t head = ring_load_head_acquire(&ring->rx);
        uint32_t tail = ring_load_tail_relaxed(&ring->rx);
        if (head != tail) {
            AsyncCompletion(args->completion, kIOReturnSuccess, nullptr, 0);
            return kIOReturnSuccess;
        }
    }

    // Store completion for driver notification
    args->completion->retain();
    OSAction* old = __atomic_exchange_n(&ivars->fPendingCompletion, args->completion, __ATOMIC_ACQ_REL);
    if (old) {
        AsyncCompletion(old, kIOReturnAborted, nullptr, 0);
        old->release();
    }

    // Race fix #2: data may have arrived between check #1 and storing completion
    if (ring && ring->magic == SHARED_RING_MAGIC) {
        uint32_t head = ring_load_head_acquire(&ring->rx);
        uint32_t tail = ring_load_tail_relaxed(&ring->rx);
        if (head != tail) {
            OSAction* c = __atomic_exchange_n(&ivars->fPendingCompletion, nullptr, __ATOMIC_ACQ_REL);
            if (c) {
                AsyncCompletion(c, kIOReturnSuccess, nullptr, 0);
                c->release();
            }
        }
    }

    return kIOReturnSuccess;
}

void USBCANUserClient::NotifyRxDataAvailable()
{
    OSAction* completion = __atomic_exchange_n(&ivars->fPendingCompletion, nullptr, __ATOMIC_ACQ_REL);
    if (completion) {
        AsyncCompletion(completion, kIOReturnSuccess, nullptr, 0);
        completion->release();
    }
}

// MARK: - Shared Memory

kern_return_t USBCANUserClient::CopyClientMemoryForType_Impl(
    uint64_t type, uint64_t* options, IOMemoryDescriptor** memory)
{
    DEXT_LOG("CopyClientMemoryForType: type=%llu", type);
    if (type != 0) return kIOReturnBadArgument;
    if (!ivars->fDriver) {
        DEXT_LOG("CopyClientMemoryForType: no driver");
        return kIOReturnNotReady;
    }

    IOBufferMemoryDescriptor* buf = nullptr;
    kern_return_t ret = ivars->fDriver->GetRxSharedBuffer(&buf);
    if (ret != kIOReturnSuccess || !buf) {
        DEXT_LOG("CopyClientMemoryForType: GetRxSharedBuffer failed: 0x%x", ret);
        return kIOReturnNotReady;
    }

    *memory = buf;
    DEXT_LOG("CopyClientMemoryForType: OK, buf=%p", (void*)buf);
    return kIOReturnSuccess;
}

// MARK: - Static Wrapper Functions

static kern_return_t sOpen(OSObject* target, void* reference, IOUserClientMethodArguments* args) {
    return ((USBCANUserClient*)target)->Open(args);
}

static kern_return_t sClose(OSObject* target, void* reference, IOUserClientMethodArguments* args) {
    return ((USBCANUserClient*)target)->Close(args);
}

static kern_return_t sSendData(OSObject* target, void* reference, IOUserClientMethodArguments* args) {
    return ((USBCANUserClient*)target)->SendData(args);
}

static kern_return_t sSetBaudRate(OSObject* target, void* reference, IOUserClientMethodArguments* args) {
    return ((USBCANUserClient*)target)->SetBaudRate(args);
}

static kern_return_t sWaitForData(OSObject* target, void* reference, IOUserClientMethodArguments* args) {
    return ((USBCANUserClient*)target)->WaitForData(args);
}

static kern_return_t sOpenChannel(OSObject* target, void* reference, IOUserClientMethodArguments* args) {
    return ((USBCANUserClient*)target)->OpenChannel(args);
}

static kern_return_t sCloseChannel(OSObject* target, void* reference, IOUserClientMethodArguments* args) {
    return ((USBCANUserClient*)target)->CloseChannel(args);
}
