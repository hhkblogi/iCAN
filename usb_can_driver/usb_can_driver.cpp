/*
 * USBCANDriver.cpp
 * IOService-based USB driver for CAN adapters (SLCAN, gs_usb, PCAN)
 *
 * Multi-protocol codec architecture:
 *   USB RX bytes → codec.processRxData → canfd_frame → SharedRingHeader RX ring
 *   SharedRingHeader TX ring → codec.drainTx → protocol bytes → USB TX
 *
 * The driver handles all protocol encode/decode internally.
 * The app reads/writes structured CAN frames via shared memory.
 *
 * Dual dispatch queues:
 *   Default queue: ReadCompleteBundled, ExternalMethod dispatch
 *   TX queue:      WriteComplete
 */

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/OSCollections.h>
#include <DriverKit/IODispatchQueue.h>
#include <USBDriverKit/USBDriverKit.h>
#include "usb_can_driver.h"
#include "usb_can_user_client.h"
#include "protocol/can.h"
#include "can_client/shared_ring_io.h"
#include "codecs/slcan_codec.h"
#include "codecs/gsusb_codec.h"
#include "codecs/pcan_codec.h"

#include <string.h>
#include <atomic>
#include <variant>
#include <time.h>

// Types, constants, and macros imported from driver_types.h via codec headers

// Known USB CAN adapters for protocol detection
struct USBAdapterInfo {
    uint16_t vid;
    uint16_t pid;
    uint8_t  protocol;  // CANProtocol enum
};
static const USBAdapterInfo kKnownAdapters[] = {
    { 0x16D0, 0x117E, kCANProtocolSLCAN },  // CANable / SH-C31G slcan
    { 0x1D50, 0x606F, kCANProtocolGSUSB },   // gs_usb / candleLight
    { 0x0C72, 0x0011, kCANProtocolPCAN  },   // PCAN-USB Pro FD
};

// Codec variant type — all supported protocol codecs
using CodecVariant = std::variant<slcan::Codec, gsusb::Codec, pcan::Codec>;

// Instance variables
struct USBCANDriver_IVars {
    // USB objects
    IOUSBHostDevice*    fDevice;
    IOUSBHostInterface* fControlInterface;
    IOUSBHostInterface* fDataInterface;
    IOUSBHostPipe*      fBulkInPipe;
    IOUSBHostPipe*      fBulkOutPipe;

    // Additional pipes for multi-endpoint adapters (PCAN)
    IOUSBHostPipe*      fCommandOutPipe;   // EP 0x01 (PCAN command TX)
    IOUSBHostPipe*      fCommandInPipe;    // EP 0x81 (PCAN command RX)
    IOUSBHostPipe*      fDataOutPipe2;     // EP 0x03 (PCAN ch1 TX)

    // Dual dispatch queues
    IODispatchQueue*    fTxQueue;            // dedicated TX queue

    // RX: MemoryDescriptorRing slots (16 × 128B) for AsyncIOBundled
    IOBufferMemoryDescriptor* fRxSlotBuffers[RX_RING_SIZE];
    OSAction*                 fReadBundledAction;  // bound to default queue
    RxSlotState               fRxSlotState[RX_RING_SIZE];
    uint32_t                  fRxSlotsInFlight;

    // TX channel 0: buffer for AsyncIO on fBulkOutPipe (EP 0x02)
    IOBufferMemoryDescriptor* fTxBuffer;
    OSAction*                 fWriteAction;        // bound to fTxQueue
    std::atomic<bool>         fTxInFlight{false};

    // TX channel 1 (PCAN EP 0x03): separate buffer + action + in-flight flag
    IOBufferMemoryDescriptor* fTxBuffer2;
    OSAction*                 fWriteAction2;       // bound to fTxQueue
    std::atomic<bool>         fTxInFlight2{false};

    // Command pipe (PCAN EP 0x01): separate buffer + in-flight flag
    IOBufferMemoryDescriptor* fCmdBuffer;
    OSAction*                 fCmdWriteAction;
    std::atomic<bool>         fCmdInFlight{false};

    // Shared-memory frame ring (app maps via CopyClientMemoryForType)
    IOBufferMemoryDescriptor* fRingSharedBuf;
    SharedRingHeader*         fRingHeader;   // mapped pointer for driver-side access

    // User client for RX notifications
    USBCANUserClient*      fUserClient;

    // Protocol codec
    CodecVariant              fCodec;
    uint8_t                   fDetectedProtocol;  // CANProtocol enum

    // State
    bool                fIsConfigured;
    std::atomic<bool>   fIsRunning{false};
    uint32_t            fBaudRate;
    bool                fMatchedOnInterface;  // provider was IOUSBHostInterface (composite)
    bool                fDeviceOpened;         // we called fDevice->Open() successfully
    bool                fControlInterfaceOpened;  // interface 0 Open succeeded
    bool                fDataInterfaceOpened;     // interface 1 Open succeeded

    // Diagnostics
    uint32_t fReadCompleteCount;
    uint32_t fReadCompleteBytes;
    bool     fRxFirstDump;
};

// MARK: - IOService Lifecycle

bool USBCANDriver::init()
{
    DEXT_LOG("init");

    if (!super::init()) return false;

    ivars = IONewZero(USBCANDriver_IVars, 1);
    if (!ivars) return false;

    ivars->fBaudRate = 115200;
    ivars->fDetectedProtocol = kCANProtocolSLCAN;  // default
    return true;
}

kern_return_t USBCANDriver::Start_Impl(IOService* provider)
{
    kern_return_t ret;
    DEXT_LOG("Start - begin");

    ret = super::Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("super::Start failed: 0x%x", ret);
        return ret;
    }

    // Get the USB device — provider may be IOUSBHostDevice or IOUSBHostInterface
    ivars->fDevice = OSDynamicCast(IOUSBHostDevice, provider);
    if (ivars->fDevice) {
        // Device-level match (SLCAN, gs_usb)
        ivars->fDevice->retain();
        ivars->fMatchedOnInterface = false;
        DEXT_LOG("Start: provider is IOUSBHostDevice");
    } else {
        // Interface-level match (composite device like PCAN-USB Pro FD)
        IOUSBHostInterface* iface = OSDynamicCast(IOUSBHostInterface, provider);
        if (!iface) {
            DEXT_LOG("Provider is neither IOUSBHostDevice nor IOUSBHostInterface");
            return kIOReturnNotFound;
        }
        ivars->fMatchedOnInterface = true;
        DEXT_LOG("Start: provider is IOUSBHostInterface (composite device)");

        // Get the parent device for VID/PID detection and control transfers
        ret = iface->CopyDevice(&ivars->fDevice);
        if (ret != kIOReturnSuccess || !ivars->fDevice) {
            DEXT_LOG("CopyDevice from interface failed: 0x%x", ret);
            return kIOReturnNotFound;
        }
        // CopyDevice retains the device for us

        // Store the matched interface for use in FindInterfaces
        ivars->fControlInterface = iface;
        iface->retain();
    }

    // Create dedicated TX dispatch queue
    ret = IODispatchQueue::Create("TxQueue", 0, 0, &ivars->fTxQueue);
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("Failed to create TxQueue: 0x%x", ret);
        ivars->fDevice->release();
        ivars->fDevice = nullptr;
        return ret;
    }

    // Create shared-memory frame ring buffer (persists for driver lifetime)
    ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionInOut, SHARED_RING_ALLOC, 0, &ivars->fRingSharedBuf);
    if (ret != kIOReturnSuccess || !ivars->fRingSharedBuf) {
        DEXT_LOG("Start: frame ring buffer create failed: 0x%x", ret);
        ivars->fTxQueue->release();
        ivars->fTxQueue = nullptr;
        ivars->fDevice->release();
        ivars->fDevice = nullptr;
        return ret;
    }

    // Map and initialize the ring buffer header
    uint64_t ringAddr = 0, ringLen = 0;
    kern_return_t mapRet = ivars->fRingSharedBuf->Map(0, 0, 0, 0, &ringAddr, &ringLen);
    if (mapRet != kIOReturnSuccess || ringAddr == 0 || ringLen < SHARED_RING_ALLOC) {
        DEXT_LOG("Start: frame ring Map failed: 0x%x addr=%llu len=%llu",
                 mapRet, ringAddr, ringLen);
        ivars->fRingSharedBuf->release();
        ivars->fRingSharedBuf = nullptr;
        ivars->fTxQueue->release();
        ivars->fTxQueue = nullptr;
        ivars->fDevice->release();
        ivars->fDevice = nullptr;
        return kIOReturnNoMemory;
    }
    ivars->fRingHeader = reinterpret_cast<SharedRingHeader*>(ringAddr);
    memset(ivars->fRingHeader, 0, SHARED_RING_ALLOC);
    ivars->fRingHeader->magic = SHARED_RING_MAGIC;
    ivars->fRingHeader->layoutVersion = SHARED_RING_LAYOUT_VERSION;
    ivars->fRingHeader->rxCapacity = SHARED_RX_CAPACITY;
    ivars->fRingHeader->tx0Capacity = SHARED_TX0_CAPACITY;
    ivars->fRingHeader->tx1Capacity = SHARED_TX1_CAPACITY;
    ivars->fRingHeader->protocolId = kCANProtocolSLCAN;  // updated in ConfigureDevice
    ivars->fRingHeader->channelCount = 1;
    DEXT_LOG("Start: frame ring V%u created, rxCap=%u tx0Cap=%u tx1Cap=%u",
             SHARED_RING_LAYOUT_VERSION, SHARED_RX_CAPACITY,
             SHARED_TX0_CAPACITY, SHARED_TX1_CAPACITY);

    RegisterService();

    DEXT_LOG("Start - complete, service registered");
    return kIOReturnSuccess;
}

kern_return_t IMPL(USBCANDriver, NewUserClient)
{
    kern_return_t ret;
    IOService* client = nullptr;

    DEXT_LOG("NewUserClient - type=%u", type);

    ret = Create(this, "UserClientProperties", &client);
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("NewUserClient - Create failed: 0x%x", ret);
        return ret;
    }

    *userClient = OSDynamicCast(IOUserClient, client);
    if (*userClient == nullptr) {
        DEXT_LOG("NewUserClient - cast failed");
        client->release();
        return kIOReturnError;
    }

    DEXT_LOG("NewUserClient - success");
    return kIOReturnSuccess;
}

kern_return_t USBCANDriver::Stop_Impl(IOService* provider)
{
    DEXT_LOG("Stop");

    StopIO();

    // Release USB pipes
    if (ivars->fBulkInPipe) {
        ivars->fBulkInPipe->release();
        ivars->fBulkInPipe = nullptr;
    }
    if (ivars->fBulkOutPipe) {
        ivars->fBulkOutPipe->release();
        ivars->fBulkOutPipe = nullptr;
    }
    if (ivars->fCommandOutPipe) {
        ivars->fCommandOutPipe->release();
        ivars->fCommandOutPipe = nullptr;
    }
    if (ivars->fCommandInPipe) {
        ivars->fCommandInPipe->release();
        ivars->fCommandInPipe = nullptr;
    }
    if (ivars->fDataOutPipe2) {
        ivars->fDataOutPipe2->release();
        ivars->fDataOutPipe2 = nullptr;
    }

    bool sameInterface = (ivars->fControlInterface == ivars->fDataInterface);
    if (ivars->fDataInterface) {
        if (ivars->fDataInterfaceOpened) ivars->fDataInterface->Close(this, 0);
        ivars->fDataInterface->release();
        ivars->fDataInterface = nullptr;
        ivars->fDataInterfaceOpened = false;
    }
    if (ivars->fControlInterface && !sameInterface) {
        if (ivars->fControlInterfaceOpened) ivars->fControlInterface->Close(this, 0);
        ivars->fControlInterface->release();
    }
    ivars->fControlInterface = nullptr;
    ivars->fControlInterfaceOpened = false;

    if (ivars->fDevice) {
        if (ivars->fDeviceOpened) {
            ivars->fDevice->Close(this, 0);
            ivars->fDeviceOpened = false;
        }
        ivars->fDevice->release();
        ivars->fDevice = nullptr;
    }

    if (ivars->fTxBuffer) {
        ivars->fTxBuffer->release();
        ivars->fTxBuffer = nullptr;
    }
    if (ivars->fTxBuffer2) {
        ivars->fTxBuffer2->release();
        ivars->fTxBuffer2 = nullptr;
    }

    if (ivars->fTxQueue) {
        ivars->fTxQueue->release();
        ivars->fTxQueue = nullptr;
    }

    // Release shared ring buffer (created in Start)
    if (ivars->fRingSharedBuf) {
        ivars->fRingSharedBuf->release();
        ivars->fRingSharedBuf = nullptr;
        ivars->fRingHeader = nullptr;
    }

    if (ivars->fUserClient) {
        ivars->fUserClient->release();
        ivars->fUserClient = nullptr;
    }

    return super::Stop(provider, SUPERDISPATCH);
}

void USBCANDriver::free()
{
    DEXT_LOG("free");

    if (ivars) {
        if (ivars->fReadBundledAction) {
            ivars->fReadBundledAction->release();
            ivars->fReadBundledAction = nullptr;
        }
        for (uint32_t i = 0; i < RX_RING_SIZE; i++) {
            if (ivars->fRxSlotBuffers[i]) {
                ivars->fRxSlotBuffers[i]->release();
                ivars->fRxSlotBuffers[i] = nullptr;
            }
        }
        if (ivars->fWriteAction) {
            ivars->fWriteAction->release();
            ivars->fWriteAction = nullptr;
        }
        if (ivars->fTxBuffer) {
            ivars->fTxBuffer->release();
            ivars->fTxBuffer = nullptr;
        }
        if (ivars->fWriteAction2) {
            ivars->fWriteAction2->release();
            ivars->fWriteAction2 = nullptr;
        }
        if (ivars->fTxBuffer2) {
            ivars->fTxBuffer2->release();
            ivars->fTxBuffer2 = nullptr;
        }
        if (ivars->fCmdWriteAction) {
            ivars->fCmdWriteAction->release();
            ivars->fCmdWriteAction = nullptr;
        }
        if (ivars->fCmdBuffer) {
            ivars->fCmdBuffer->release();
            ivars->fCmdBuffer = nullptr;
        }
        if (ivars->fRingSharedBuf) {
            ivars->fRingSharedBuf->release();
            ivars->fRingSharedBuf = nullptr;
        }
        ivars->fRingHeader = nullptr;
        if (ivars->fUserClient) {
            ivars->fUserClient->release();
            ivars->fUserClient = nullptr;
        }
        // Safety: release USB objects if still held (e.g., Start failed after retain)
        if (ivars->fDevice) {
            ivars->fDevice->release();
            ivars->fDevice = nullptr;
        }
        if (ivars->fTxQueue) {
            ivars->fTxQueue->release();
            ivars->fTxQueue = nullptr;
        }
        IOSafeDeleteNULL(ivars, USBCANDriver_IVars, 1);
    }

    super::free();
}

// MARK: - Protocol Detection

static uint8_t detectProtocol(uint16_t vid, uint16_t pid)
{
    for (const auto& adapter : kKnownAdapters) {
        if (adapter.vid == vid && adapter.pid == pid) {
            return adapter.protocol;
        }
    }
    return kCANProtocolSLCAN;  // default fallback
}

// MARK: - USB Configuration

kern_return_t USBCANDriver::ConfigureDevice()
{
    if (ivars->fIsConfigured) {
        DEXT_LOG("ConfigureDevice: already configured");
        return kIOReturnSuccess;
    }

    kern_return_t ret;

    if (!ivars->fMatchedOnInterface) {
        // Device-level match: open device and set configuration
        DEXT_LOG("ConfigureDevice - step 1: Open device");
        ret = ivars->fDevice->Open(this, 0, 0);
        if (ret != kIOReturnSuccess) {
            DEXT_LOG("Failed to open device: 0x%x", ret);
            return ret;
        }
        ivars->fDeviceOpened = true;

        DEXT_LOG("ConfigureDevice - step 2: SetConfiguration");
        ret = ivars->fDevice->SetConfiguration(1, false);
        if (ret != kIOReturnSuccess) {
            DEXT_LOG("SetConfiguration(1) failed: 0x%x (continuing)", ret);
        }
    } else {
        // Interface-level match (composite device): composite driver already
        // owns the device and set the configuration. Try opening device for
        // control transfers (firmware info, driver-loaded notification).
        DEXT_LOG("ConfigureDevice - step 1/2: interface-level match, skip SetConfiguration");
        ret = ivars->fDevice->Open(this, 0, 0);
        if (ret == kIOReturnSuccess) {
            ivars->fDeviceOpened = true;
            DEXT_LOG("ConfigureDevice: opened device for control transfers");
        } else {
            DEXT_LOG("ConfigureDevice: device open failed: 0x%x (control xfers skipped)", ret);
        }
    }

    // Detect protocol from VID/PID
    // TODO: Query VID/PID from device properties. For now, use codec that was
    // set at init (SLCAN default) — the IOKit matching already filtered by VID/PID.
    // We detect based on which personality matched by checking device properties.
    uint16_t vid = 0, pid = 0;
    {
        // Try to read VID/PID from IORegistry properties
        OSDictionary* dict = nullptr;
        ivars->fDevice->CopyProperties(&dict);
        if (dict) {
            OSObject* vidObj = dict->getObject("idVendor");
            OSObject* pidObj = dict->getObject("idProduct");
            OSNumber* vidNum = OSDynamicCast(OSNumber, vidObj);
            OSNumber* pidNum = OSDynamicCast(OSNumber, pidObj);
            if (vidNum) vid = static_cast<uint16_t>(vidNum->unsigned16BitValue());
            if (pidNum) pid = static_cast<uint16_t>(pidNum->unsigned16BitValue());
            dict->release();
        }
    }
    DEXT_LOG("ConfigureDevice: VID=0x%04x PID=0x%04x", vid, pid);

    ivars->fDetectedProtocol = detectProtocol(vid, pid);
    switch (ivars->fDetectedProtocol) {
        case kCANProtocolGSUSB:
            ivars->fCodec.emplace<gsusb::Codec>();
            break;
        case kCANProtocolPCAN:
            ivars->fCodec.emplace<pcan::Codec>();
            break;
        case kCANProtocolSLCAN:
        default:
            ivars->fCodec.emplace<slcan::Codec>();
            break;
    }

    // Update ring header with detected protocol info
    if (ivars->fRingHeader) {
        ivars->fRingHeader->protocolId = ivars->fDetectedProtocol;
        ivars->fRingHeader->channelCount =
            (ivars->fDetectedProtocol == kCANProtocolPCAN) ? 2 : 1;
    }

    DEXT_LOG("ConfigureDevice - step 3: FindInterfaces (protocol=%s)",
             std::visit([](const auto& c) { return c.name(); }, ivars->fCodec));

    ret = FindInterfaces();
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("FindInterfaces failed: 0x%x", ret);
        if (ivars->fDeviceOpened) ivars->fDevice->Close(this, 0);
        ivars->fDeviceOpened = false;
        return ret;
    }

    DEXT_LOG("ConfigureDevice - step 4: ConfigurePipes");
    ret = ConfigurePipes();
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("ConfigurePipes failed: 0x%x", ret);
        if (ivars->fDeviceOpened) ivars->fDevice->Close(this, 0);
        ivars->fDeviceOpened = false;
        return ret;
    }

    DEXT_LOG("ConfigureDevice - step 5: Allocate TX buffer");
    ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionInOut, TX_BUFFER_SIZE, 0, &ivars->fTxBuffer);
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("Failed to create TX buffer: 0x%x", ret);
        if (ivars->fDeviceOpened) ivars->fDevice->Close(this, 0);
        ivars->fDeviceOpened = false;
        return ret;
    }

    // Step 6: Codec-specific device configuration (CDC line coding, gs_usb host format, etc.)
    // Pass device only if we opened it (so control transfers will work).
    // For interface-level match where device open failed, pass nullptr —
    // codec returns early, which is fine (PCAN control transfers are informational).
    IOUSBHostDevice* devForCodec = ivars->fDeviceOpened ? ivars->fDevice : nullptr;
    DEXT_LOG("ConfigureDevice - step 6: codec.configureDevice (devOpen=%d)",
             ivars->fDeviceOpened);
    ret = std::visit([&](auto& codec) {
        return codec.configureDevice(devForCodec, this);
    }, ivars->fCodec);
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("codec.configureDevice failed: 0x%x (continuing)", ret);
        // Non-fatal — CDC requests may fail on some adapters, PCAN control
        // transfers are informational only
    }

    ivars->fIsConfigured = true;
    DEXT_LOG("Device configured successfully");
    return kIOReturnSuccess;
}

kern_return_t USBCANDriver::FindInterfaces()
{
    DEXT_LOG("FindInterfaces");
    kern_return_t ret;

    // Interface-level match: the matched interface is already stored
    if (ivars->fMatchedOnInterface && ivars->fControlInterface) {
        DEXT_LOG("FindInterfaces: using matched interface directly (composite device)");

        ret = ivars->fControlInterface->Open(this, 0, nullptr);
        if (ret != kIOReturnSuccess) {
            DEXT_LOG("Failed to open matched interface: 0x%x", ret);
            return ret;
        }
        ivars->fControlInterfaceOpened = true;
        ivars->fDataInterfaceOpened = true;
        DEXT_LOG("Opened matched interface");

        // Use same interface for both control and data (all PCAN endpoints are here)
        ivars->fDataInterface = ivars->fControlInterface;
        ivars->fDataInterface->retain();
        return kIOReturnSuccess;
    }

    uintptr_t iterRef = 0;
    ret = ivars->fDevice->CreateInterfaceIterator(&iterRef);
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("CreateInterfaceIterator failed: 0x%x", ret);
        return ret;
    }

    IOUSBHostInterface* iface = nullptr;
    int ifaceIndex = 0;
    while (true) {
        iface = nullptr;
        ret = ivars->fDevice->CopyInterface(iterRef, &iface);
        if (ret != kIOReturnSuccess || iface == nullptr) break;

        DEXT_LOG("Found interface at index %d", ifaceIndex);

        if (ifaceIndex == 0) {
            ivars->fControlInterface = iface;
            ret = ivars->fControlInterface->Open(this, 0, nullptr);
            if (ret == kIOReturnSuccess) {
                ivars->fControlInterfaceOpened = true;
                DEXT_LOG("Opened interface 0 (Control)");
            } else {
                // Device-level match: Open may fail but CopyPipe can still work
                // since we already own the device. Keep the interface reference.
                DEXT_LOG("Failed to open interface 0: 0x%x (keeping for pipes)", ret);
            }
        } else if (ifaceIndex == 1) {
            // For PCAN, interface 1 is LIN (not needed) — skip it
            if (ivars->fDetectedProtocol == kCANProtocolPCAN) {
                DEXT_LOG("PCAN: skipping interface 1 (LIN)");
                iface->release();
            } else {
                ivars->fDataInterface = iface;
                ret = ivars->fDataInterface->Open(this, 0, nullptr);
                if (ret == kIOReturnSuccess) {
                    ivars->fDataInterfaceOpened = true;
                    DEXT_LOG("Opened interface 1 (Data)");
                } else {
                    // Keep interface — pipes may work without explicit Open
                    DEXT_LOG("Failed to open interface 1: 0x%x (keeping for pipes)", ret);
                }
            }
        } else {
            iface->release();
        }
        ifaceIndex++;
    }
    ivars->fDevice->DestroyInterfaceIterator(iterRef);

    DEXT_LOG("FindInterfaces: found %d interfaces, ctrl=%p data=%p",
             ifaceIndex, (void*)ivars->fControlInterface, (void*)ivars->fDataInterface);

    // No separate data interface — use control as data
    // (single-interface devices like gs_usb, or PCAN where interface 1 is LIN/skipped)
    if (ivars->fControlInterface && !ivars->fDataInterface) {
        DEXT_LOG("Using control interface as data interface");
        ivars->fDataInterface = ivars->fControlInterface;
        ivars->fDataInterface->retain();
        ivars->fDataInterfaceOpened = ivars->fControlInterfaceOpened;
    }

    if (!ivars->fDataInterface) {
        DEXT_LOG("No usable data interface found (ctrl=%p data=%p)",
                 (void*)ivars->fControlInterface, (void*)ivars->fDataInterface);
        return kIOReturnNotFound;
    }

    return kIOReturnSuccess;
}

kern_return_t USBCANDriver::ConfigurePipes()
{
    DEXT_LOG("ConfigurePipes");

    if (!ivars->fDataInterface) return kIOReturnNotReady;

    kern_return_t ret;
    static const uint8_t outAddresses[] = { 0x01, 0x02, 0x03 };
    static const uint8_t inAddresses[]  = { 0x81, 0x82, 0x83 };

    bool needsCDC = std::visit([](const auto& c) { return c.needsCDC(); }, ivars->fCodec);

    if (needsCDC) {
        // CDC device (SLCAN): find first available Bulk IN/OUT pair
        for (int i = 0; i < 3 && !ivars->fBulkOutPipe; i++) {
            ret = ivars->fDataInterface->CopyPipe(outAddresses[i], &ivars->fBulkOutPipe);
            if (ret == kIOReturnSuccess && ivars->fBulkOutPipe) {
                DEXT_LOG("Found Bulk OUT pipe at 0x%02x", outAddresses[i]);
            } else {
                ivars->fBulkOutPipe = nullptr;
            }
        }

        for (int i = 0; i < 3 && !ivars->fBulkInPipe; i++) {
            ret = ivars->fDataInterface->CopyPipe(inAddresses[i], &ivars->fBulkInPipe);
            if (ret == kIOReturnSuccess && ivars->fBulkInPipe) {
                DEXT_LOG("Found Bulk IN pipe at 0x%02x", inAddresses[i]);
            } else {
                ivars->fBulkInPipe = nullptr;
            }
        }

        // Try control interface if data interface had no pipes
        if ((!ivars->fBulkOutPipe || !ivars->fBulkInPipe) && ivars->fControlInterface
            && ivars->fControlInterface != ivars->fDataInterface) {
            DEXT_LOG("Trying control interface for missing pipes");
            for (int i = 0; i < 3 && !ivars->fBulkOutPipe; i++) {
                ret = ivars->fControlInterface->CopyPipe(outAddresses[i], &ivars->fBulkOutPipe);
                if (ret == kIOReturnSuccess && ivars->fBulkOutPipe) {
                    DEXT_LOG("Found Bulk OUT on ctrl at 0x%02x", outAddresses[i]);
                } else {
                    ivars->fBulkOutPipe = nullptr;
                }
            }
            for (int i = 0; i < 3 && !ivars->fBulkInPipe; i++) {
                ret = ivars->fControlInterface->CopyPipe(inAddresses[i], &ivars->fBulkInPipe);
                if (ret == kIOReturnSuccess && ivars->fBulkInPipe) {
                    DEXT_LOG("Found Bulk IN on ctrl at 0x%02x", inAddresses[i]);
                } else {
                    ivars->fBulkInPipe = nullptr;
                }
            }
        }
    } else {
        // Non-CDC device (gs_usb, PCAN): specific endpoint mapping
        // For gs_usb: EP 0x01 OUT (TX), EP 0x81 IN (RX)
        // For PCAN:   EP 0x01 OUT (cmd TX), EP 0x81 IN (cmd RX),
        //             EP 0x02 OUT (data TX ch0), EP 0x82 IN (data RX),
        //             EP 0x03 OUT (data TX ch1)
        IOUSBHostInterface* iface = ivars->fDataInterface;

        // Try all OUT endpoints
        for (int i = 0; i < 3; i++) {
            IOUSBHostPipe* pipe = nullptr;
            ret = iface->CopyPipe(outAddresses[i], &pipe);
            if (ret == kIOReturnSuccess && pipe) {
                if (i == 0 && !ivars->fBulkOutPipe) {
                    // EP 0x01: primary TX (gs_usb) or command TX (PCAN)
                    if (ivars->fDetectedProtocol == kCANProtocolPCAN) {
                        ivars->fCommandOutPipe = pipe;
                        DEXT_LOG("PCAN command OUT pipe at 0x01");
                    } else {
                        ivars->fBulkOutPipe = pipe;
                        DEXT_LOG("Bulk OUT pipe at 0x01");
                    }
                } else if (i == 1) {
                    if (ivars->fDetectedProtocol == kCANProtocolPCAN) {
                        ivars->fBulkOutPipe = pipe;
                        DEXT_LOG("PCAN data OUT ch0 pipe at 0x02");
                    } else {
                        pipe->release();
                    }
                } else if (i == 2) {
                    if (ivars->fDetectedProtocol == kCANProtocolPCAN) {
                        ivars->fDataOutPipe2 = pipe;
                        DEXT_LOG("PCAN data OUT ch1 pipe at 0x03");
                    } else {
                        pipe->release();
                    }
                } else {
                    pipe->release();
                }
            }
        }

        // Try all IN endpoints
        for (int i = 0; i < 3; i++) {
            IOUSBHostPipe* pipe = nullptr;
            ret = iface->CopyPipe(inAddresses[i], &pipe);
            if (ret == kIOReturnSuccess && pipe) {
                if (i == 0) {
                    if (ivars->fDetectedProtocol == kCANProtocolPCAN) {
                        ivars->fCommandInPipe = pipe;
                        DEXT_LOG("PCAN command IN pipe at 0x81");
                    } else {
                        ivars->fBulkInPipe = pipe;
                        DEXT_LOG("Bulk IN pipe at 0x81");
                    }
                } else if (i == 1) {
                    if (ivars->fDetectedProtocol == kCANProtocolPCAN) {
                        ivars->fBulkInPipe = pipe;
                        DEXT_LOG("PCAN data IN pipe at 0x82");
                    } else {
                        pipe->release();
                    }
                } else {
                    pipe->release();
                }
            }
        }
    }

    if (ivars->fBulkOutPipe && ivars->fBulkInPipe) {
        DEXT_LOG("Pipes configured successfully");
        return kIOReturnSuccess;
    }

    DEXT_LOG("ConfigurePipes FAILED: OUT=%p IN=%p",
           (void*)ivars->fBulkOutPipe, (void*)ivars->fBulkInPipe);
    return kIOReturnNotFound;
}

// MARK: - I/O Start/Stop

kern_return_t USBCANDriver::StartIO()
{
    if (ivars->fIsRunning.load()) return kIOReturnSuccess;

    if (!ivars->fIsConfigured && ivars->fDevice) {
        kern_return_t ret = ConfigureDevice();
        if (ret != kIOReturnSuccess) {
            DEXT_LOG("StartIO: ConfigureDevice failed: 0x%x", ret);
            return ret;
        }
    }

    if (!ivars->fIsConfigured) return kIOReturnNotReady;

    DEXT_LOG("StartIO");
    ivars->fIsRunning.store(true);

    // Reset diagnostics
    ivars->fReadCompleteCount = 0;
    ivars->fReadCompleteBytes = 0;
    ivars->fRxFirstDump = false;

    // Create async TX completion action
    if (!ivars->fWriteAction) {
        kern_return_t ret = CreateActionWriteComplete(0, &ivars->fWriteAction);
        if (ret != kIOReturnSuccess) {
            DEXT_LOG("StartIO: CreateActionWriteComplete failed: 0x%x", ret);
            ivars->fIsRunning.store(false);
            return ret;
        }
    }
    ivars->fTxInFlight.store(false);

    // Create async TX completion for PCAN channel 1 (EP 0x03)
    if (ivars->fDataOutPipe2 && !ivars->fWriteAction2) {
        kern_return_t ret2 = IOBufferMemoryDescriptor::Create(
            kIOMemoryDirectionInOut, TX_BUFFER_SIZE, 0, &ivars->fTxBuffer2);
        if (ret2 == kIOReturnSuccess) {
            ret2 = CreateActionWriteComplete2(0, &ivars->fWriteAction2);
        }
        if (ret2 != kIOReturnSuccess) {
            DEXT_LOG("StartIO: ch1 TX setup failed: 0x%x (single-endpoint fallback)", ret2);
            if (ivars->fTxBuffer2) { ivars->fTxBuffer2->release(); ivars->fTxBuffer2 = nullptr; }
            ivars->fWriteAction2 = nullptr;
        } else {
            DEXT_LOG("StartIO: PCAN dual-endpoint TX enabled (EP 0x02 + 0x03)");
        }
    }
    ivars->fTxInFlight2.store(false);

    // Reset frame ring for fresh I/O session
    if (ivars->fRingHeader) {
        ring_store_head_release(&ivars->fRingHeader->rx, 0);
        ring_store_tail_release(&ivars->fRingHeader->rx, 0);
        ring_store_head_release(&ivars->fRingHeader->tx0, 0);
        ring_store_tail_release(&ivars->fRingHeader->tx0, 0);
        ring_store_head_release(&ivars->fRingHeader->tx1, 0);
        ring_store_tail_release(&ivars->fRingHeader->tx1, 0);
        ivars->fRingHeader->rxProduceCount = 0;
        ivars->fRingHeader->rxDropped = 0;
        ivars->fRingHeader->txDrainCount = 0;
        ivars->fRingHeader->txDropped = 0;
    }

    // Start async RX
    kern_return_t rxRet = StartAsyncRead();
    if (rxRet != kIOReturnSuccess) {
        DEXT_LOG("StartIO: StartAsyncRead failed: 0x%x", rxRet);
        ivars->fIsRunning.store(false);
        return rxRet;
    }

    DEXT_LOG("StartIO complete");
    return kIOReturnSuccess;
}

kern_return_t USBCANDriver::StopIO()
{
    if (!ivars->fIsRunning.load()) return kIOReturnSuccess;

    DEXT_LOG("StopIO");
    ivars->fIsRunning.store(false);

    // Codec cleanup
    std::visit([&](auto& codec) {
        codec.onStopIO(ivars->fDevice, this);
    }, ivars->fCodec);

    StopAsyncRead();

    if (ivars->fBulkOutPipe) {
        ivars->fBulkOutPipe->Abort(0, kIOReturnAborted, this);
    }
    if (ivars->fDataOutPipe2) {
        ivars->fDataOutPipe2->Abort(0, kIOReturnAborted, this);
    }

    return kIOReturnSuccess;
}

kern_return_t USBCANDriver::OpenChannel(uint32_t bitrate, uint8_t channel)
{
    DEXT_LOG("OpenChannel: bitrate=%u channel=%u", bitrate, channel);
    if (!ivars->fIsConfigured || !ivars->fBulkOutPipe) return kIOReturnNotReady;

    // PCAN commands go via command pipe (EP 0x01), others via data pipe
    auto sendFn = [this](const uint8_t* data, uint32_t len) -> kern_return_t {
        if (ivars->fDetectedProtocol == kCANProtocolPCAN && ivars->fCommandOutPipe) {
            return this->SendCommandBytes(data, len);
        }
        return this->SendRawBytes(data, len);
    };

    return std::visit([&](auto& codec) {
        return codec.openChannel(ivars->fDevice, this, bitrate, channel, sendFn);
    }, ivars->fCodec);
}

kern_return_t USBCANDriver::CloseChannel(uint8_t channel)
{
    DEXT_LOG("CloseChannel: channel=%u", channel);
    if (!ivars->fIsConfigured || !ivars->fBulkOutPipe) return kIOReturnNotReady;

    // PCAN commands go via command pipe (EP 0x01), others via data pipe
    auto sendFn = [this](const uint8_t* data, uint32_t len) -> kern_return_t {
        if (ivars->fDetectedProtocol == kCANProtocolPCAN && ivars->fCommandOutPipe) {
            return this->SendCommandBytes(data, len);
        }
        return this->SendRawBytes(data, len);
    };

    return std::visit([&](auto& codec) {
        return codec.closeChannel(ivars->fDevice, this, channel, sendFn);
    }, ivars->fCodec);
}

kern_return_t USBCANDriver::GetRxSharedBuffer(IOBufferMemoryDescriptor** buffer)
{
    if (!buffer) return kIOReturnBadArgument;
    if (!ivars->fRingSharedBuf) return kIOReturnNotReady;
    *buffer = ivars->fRingSharedBuf;
    ivars->fRingSharedBuf->retain();
    return kIOReturnSuccess;
}

void* USBCANDriver::GetRxRing()
{
    return ivars->fRingHeader;
}

void USBCANDriver::SetUserClient(USBCANUserClient* uc)
{
    if (uc) uc->retain();
    USBCANUserClient* old = ivars->fUserClient;
    ivars->fUserClient = uc;
    if (old) old->release();
}

// MARK: - Async RX

kern_return_t USBCANDriver::StartAsyncRead()
{
    kern_return_t ret;

    ret = ivars->fBulkInPipe->CreateMemoryDescriptorRing(RX_RING_SIZE);
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("CreateMemoryDescriptorRing failed: 0x%x", ret);
        return ret;
    }

    for (uint32_t i = 0; i < RX_RING_SIZE; i++) {
        ret = IOBufferMemoryDescriptor::Create(
            kIOMemoryDirectionInOut, RX_SLOT_SIZE, 0, &ivars->fRxSlotBuffers[i]);
        if (ret != kIOReturnSuccess) {
            DEXT_LOG("RX slot %u buffer Create failed: 0x%x", i, ret);
            for (uint32_t j = 0; j < i; j++) {
                ivars->fRxSlotBuffers[j]->release();
                ivars->fRxSlotBuffers[j] = nullptr;
            }
            return ret;
        }
        ivars->fRxSlotBuffers[i]->SetLength(RX_SLOT_SIZE);

        ret = ivars->fBulkInPipe->SetMemoryDescriptor(ivars->fRxSlotBuffers[i], i);
        if (ret != kIOReturnSuccess) {
            DEXT_LOG("SetMemoryDescriptor slot %u failed: 0x%x", i, ret);
            for (uint32_t j = 0; j <= i; j++) {
                ivars->fRxSlotBuffers[j]->release();
                ivars->fRxSlotBuffers[j] = nullptr;
            }
            return ret;
        }

        ivars->fRxSlotState[i] = kRxSlotFree;
    }

    ret = CreateActionReadCompleteBundled(0, &ivars->fReadBundledAction);
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("CreateActionReadCompleteBundled failed: 0x%x", ret);
        for (uint32_t i = 0; i < RX_RING_SIZE; i++) {
            ivars->fRxSlotBuffers[i]->release();
            ivars->fRxSlotBuffers[i] = nullptr;
        }
        return ret;
    }

    ivars->fRxSlotsInFlight = 0;

    // Submit all free slots via SubmitPendingReads
    ret = SubmitPendingReads();
    if (ret != kIOReturnSuccess) {
        DEXT_LOG("StartAsyncRead: initial SubmitPendingReads failed: 0x%x", ret);
        ivars->fReadBundledAction->release();
        ivars->fReadBundledAction = nullptr;
        for (uint32_t i = 0; i < RX_RING_SIZE; i++) {
            ivars->fRxSlotBuffers[i]->release();
            ivars->fRxSlotBuffers[i] = nullptr;
        }
        return ret;
    }

    DEXT_LOG("StartAsyncRead: ring=%u slots, %u in flight", RX_RING_SIZE, ivars->fRxSlotsInFlight);
    return kIOReturnSuccess;
}

kern_return_t USBCANDriver::StopAsyncRead()
{
    if (ivars->fBulkInPipe) {
        ivars->fBulkInPipe->Abort(0, kIOReturnAborted, this);
    }

    for (uint32_t i = 0; i < RX_RING_SIZE; i++) {
        ivars->fRxSlotState[i] = kRxSlotFree;
    }
    ivars->fRxSlotsInFlight = 0;

    return kIOReturnSuccess;
}

// MARK: - RX Slot Resubmission

kern_return_t USBCANDriver::SubmitPendingReads()
{
    if (!ivars->fIsRunning.load() || !ivars->fBulkInPipe) return kIOReturnNotReady;

    // Find first FREE slot and count contiguous FREE slots
    uint32_t startIdx = UINT32_MAX;
    uint32_t count = 0;

    for (uint32_t i = 0; i < RX_RING_SIZE; i++) {
        if (ivars->fRxSlotState[i] == kRxSlotFree) {
            if (startIdx == UINT32_MAX) startIdx = i;
            count++;
        } else if (startIdx != UINT32_MAX) {
            break;  // non-contiguous
        }
    }

    // Handle wrap: if contiguous run ended at ring end, check beginning too
    if (startIdx != UINT32_MAX && (startIdx + count) == RX_RING_SIZE) {
        for (uint32_t i = 0; i < startIdx; i++) {
            if (ivars->fRxSlotState[i] == kRxSlotFree) count++;
            else break;
        }
    }

    if (count == 0) return kIOReturnSuccess;
    if (count > 16) count = 16;

    uint32_t lengths[16];
    for (uint32_t i = 0; i < count; i++) lengths[i] = RX_SLOT_SIZE;

    uint32_t accepted = 0;
    kern_return_t ret = ivars->fBulkInPipe->AsyncIOBundled(
        startIdx, count, &accepted, lengths, (int)count,
        ivars->fReadBundledAction, 0);

    if (ret == kIOReturnSuccess && accepted > 0) {
        for (uint32_t i = 0; i < accepted; i++) {
            ivars->fRxSlotState[(startIdx + i) % RX_RING_SIZE] = kRxSlotInflight;
        }
        ivars->fRxSlotsInFlight += accepted;
    } else if (ret != kIOReturnSuccess) {
        DEXT_LOG("SubmitPendingReads: AsyncIOBundled failed: 0x%x (start=%u count=%u)",
                 ret, startIdx, count);
    }

    return ret;
}

// MARK: - RX Completion (codec-based frame decode)

void USBCANDriver::ReadCompleteBundled_Impl(
    OSAction*           action,
    uint32_t            ioCompletionIndex,
    uint32_t            ioCompletionCount,
    const uint32_t      actualByteCountArray[16],
    int                 actualByteCountArrayCount,
    const kern_return_t statusArray[16],
    int                 statusArrayCount)
{
    bool didWriteFrame = false;

    for (uint32_t i = 0; i < ioCompletionCount; i++) {
        uint32_t idx = (ioCompletionIndex + i) % RX_RING_SIZE;

        if (ivars->fRxSlotsInFlight > 0) ivars->fRxSlotsInFlight--;

        if (statusArray[i] == kIOReturnSuccess && actualByteCountArray[i] > 0) {
            uint32_t byteCount = actualByteCountArray[i];

            // Map USB slot buffer
            uint64_t addr = 0, len = 0;
            ivars->fRxSlotBuffers[idx]->Map(0, 0, 0, 0, &addr, &len);

            // One-time debug dump
            if (!ivars->fRxFirstDump) {
                ivars->fRxFirstDump = true;
                const uint8_t* p = (const uint8_t*)addr;
                if (byteCount >= 8) {
                    DEXT_LOG("RX-FIRST[%u]: %02X %02X %02X %02X %02X %02X %02X %02X",
                             byteCount, p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
                }
            }

            // Decode USB bytes through codec → write CAN frames to shared ring
            if (ivars->fRingHeader) {
                const uint8_t* src = (const uint8_t*)addr;
                std::visit([&](auto& codec) {
                    codec.processRxData(src, byteCount, [&](const canfd_frame& frame) {
                        uint64_t rxTimestamp = clock_gettime_nsec_np(CLOCK_REALTIME) / 1000;
                        if (shared_ring::writeRxFrame(ivars->fRingHeader, ivars->fRingHeader->data, frame, rxTimestamp)) {
                            didWriteFrame = true;
                        }
                    }, ivars->fRingHeader);
                }, ivars->fCodec);
            }

            ivars->fReadCompleteCount++;
            ivars->fReadCompleteBytes += byteCount;
        } else if (statusArray[i] != kIOReturnSuccess && statusArray[i] != kIOReturnAborted) {
            DEXT_LOG("ReadCompleteBundled[%u]: error 0x%x", idx, statusArray[i]);
        }

        // Mark slot free immediately
        ivars->fRxSlotState[idx] = kRxSlotFree;
    }

    // Resubmit freed slots FIRST — minimize the gap where no USB reads
    // are pending, which causes the adapter's internal FIFO to fill and
    // drop frames at high message rates (see issue #11).
    if (ivars->fIsRunning.load()) {
        SubmitPendingReads();
    }

    // Notify client after resubmission (IPC can be slow)
    if (didWriteFrame && ivars->fUserClient) {
        ivars->fUserClient->NotifyRxDataAvailable();
    }

    // Check if codec needs TX drain (gs_usb echo flow control)
    if (std::visit([](const auto& c) { return c.needsDrainTx(); }, ivars->fCodec)) {
        DrainTxRing();
    }

    // Log periodically
    if (ivars->fReadCompleteCount <= 3 || ivars->fReadCompleteCount % 5000 == 0) {
        DEXT_LOG("ReadCompleteBundled: idx=%u count=%u inFlight=%u total=%u",
                 ioCompletionIndex, ioCompletionCount,
                 ivars->fRxSlotsInFlight, ivars->fReadCompleteCount);
    }
}

// MARK: - Data Transfer

kern_return_t USBCANDriver::SendRawBytes(const uint8_t* data, uint32_t length)
{
    if (!ivars->fIsConfigured || !ivars->fBulkOutPipe) return kIOReturnNotReady;
    if (length == 0) return kIOReturnSuccess;
    if (length > TX_BUFFER_SIZE) return kIOReturnNoSpace;

    // Atomically claim TX slot to prevent concurrent buffer access
    bool expected = false;
    if (!ivars->fTxInFlight.compare_exchange_strong(expected, true,
            std::memory_order_acq_rel)) {
        return kIOReturnBusy;
    }

    // Copy data to TX buffer
    uint64_t txAddr = 0, txLen = 0;
    ivars->fTxBuffer->Map(0, 0, 0, 0, &txAddr, &txLen);
    memcpy((void*)txAddr, data, length);

    kern_return_t ret = ivars->fBulkOutPipe->AsyncIO(
        ivars->fTxBuffer, length, ivars->fWriteAction, 0);

    if (ret != kIOReturnSuccess) {
        ivars->fTxInFlight.store(false, std::memory_order_release);
        DEXT_LOG("AsyncIO Write failed: 0x%x", ret);
    }

    return ret;
}

kern_return_t USBCANDriver::SendRawBytesChannel1(const uint8_t* data, uint32_t length)
{
    if (!ivars->fIsConfigured || !ivars->fDataOutPipe2 || !ivars->fTxBuffer2)
        return kIOReturnNotReady;
    if (length == 0) return kIOReturnSuccess;
    if (length > TX_BUFFER_SIZE) return kIOReturnNoSpace;

    bool expected = false;
    if (!ivars->fTxInFlight2.compare_exchange_strong(expected, true,
            std::memory_order_acq_rel)) {
        return kIOReturnBusy;
    }

    uint64_t txAddr = 0, txLen = 0;
    kern_return_t mapRet = ivars->fTxBuffer2->Map(0, 0, 0, 0, &txAddr, &txLen);
    if (mapRet != kIOReturnSuccess || txAddr == 0 || txLen < length) {
        ivars->fTxInFlight2.store(false, std::memory_order_release);
        DEXT_LOG("SendRawBytesChannel1: Map failed: 0x%x", mapRet);
        return kIOReturnNoMemory;
    }
    memcpy((void*)txAddr, data, length);

    kern_return_t ret = ivars->fDataOutPipe2->AsyncIO(
        ivars->fTxBuffer2, length, ivars->fWriteAction2, 0);

    if (ret != kIOReturnSuccess) {
        ivars->fTxInFlight2.store(false, std::memory_order_release);
        DEXT_LOG("AsyncIO Write ch1 failed: 0x%x", ret);
    }
    return ret;
}

void USBCANDriver::WriteComplete2_Impl(
    OSAction*  action,
    IOReturn   status,
    uint32_t   actualByteCount,
    uint64_t   completionTimestamp)
{
    ivars->fTxInFlight2.store(false);

    if (status != kIOReturnSuccess && status != kIOReturnAborted) {
        DEXT_LOG("WriteComplete2 error: 0x%x (bytes=%u)", status, actualByteCount);
        if (status == 0xe0005000 && ivars->fDataOutPipe2) {
            kern_return_t clr = ivars->fDataOutPipe2->ClearStall(false);
            DEXT_LOG("ClearStall OUT pipe2: 0x%x", clr);
        }
    }

    if (status == kIOReturnSuccess && ivars->fIsRunning.load()) {
        DrainTxRing();
    }
}

kern_return_t USBCANDriver::SendData(const uint8_t* data, uint32_t length)
{
    // If called with data, send raw bytes (backward compat for simulator path)
    if (data && length > 0) {
        return SendRawBytes(data, length);
    }

    // If called with no data, drain the TX ring via codec
    return DrainTxRing();
}

kern_return_t USBCANDriver::DrainTxRing()
{
    if (!ivars->fRingHeader || !ivars->fBulkOutPipe) return kIOReturnNotReady;

    auto sendCh0 = [this](const uint8_t* data, uint32_t len) -> kern_return_t {
        return this->SendRawBytes(data, len);
    };

    // PCAN dual-endpoint: drain tx0 → EP 0x02, tx1 → EP 0x03 independently
    if (ivars->fDetectedProtocol == kCANProtocolPCAN &&
        ivars->fDataOutPipe2 && ivars->fTxBuffer2 && ivars->fWriteAction2) {

        auto sendCh1 = [this](const uint8_t* data, uint32_t len) -> kern_return_t {
            return this->SendRawBytesChannel1(data, len);
        };

        auto& codec = std::get<pcan::Codec>(ivars->fCodec);
        const uint8_t* tx0Data = shared_ring_tx0_data_const(ivars->fRingHeader);
        const uint8_t* tx1Data = shared_ring_tx1_data_const(ivars->fRingHeader);

        // Drain ch0 ring → EP 0x02
        kern_return_t ret0 = codec.drainTxRing(ivars->fRingHeader, &ivars->fRingHeader->tx0,
                          tx0Data, ivars->fRingHeader->tx0Capacity,
                          ivars->fTxInFlight.load(), sendCh0);
        // Drain ch1 ring → EP 0x03
        kern_return_t ret1 = codec.drainTxRing(ivars->fRingHeader, &ivars->fRingHeader->tx1,
                          tx1Data, ivars->fRingHeader->tx1Capacity,
                          ivars->fTxInFlight2.load(), sendCh1);
        // Propagate first error, prefer error over busy over success
        if (ret0 != kIOReturnSuccess && ret0 != kIOReturnBusy) return ret0;
        if (ret1 != kIOReturnSuccess && ret1 != kIOReturnBusy) return ret1;
        return kIOReturnSuccess;
    }

    // Single-endpoint path (SLCAN, gs_usb, or PCAN fallback)
    // Drain both tx0 and tx1 to EP 0x02 in case ch1 frames were queued
    const uint8_t* tx0Data = shared_ring_tx0_data_const(ivars->fRingHeader);

    kern_return_t ret = std::visit([&](auto& codec) {
        return codec.drainTx(ivars->fRingHeader, tx0Data,
                             ivars->fTxInFlight.load(), sendCh0);
    }, ivars->fCodec);

    // Also drain tx1 if it has data (PCAN fallback without EP 0x03)
    if (ivars->fRingHeader->tx1Capacity > 0 && ivars->fRingHeader->channelCount >= 2) {
        const uint8_t* tx1Data = shared_ring_tx1_data_const(ivars->fRingHeader);
        std::visit([&](auto& codec) {
            codec.drainTx(ivars->fRingHeader, tx1Data,
                          ivars->fTxInFlight.load(),
                          sendCh0);  // route ch1 through EP 0x02 as fallback
        }, ivars->fCodec);
    }

    return ret;
}

void USBCANDriver::WriteComplete_Impl(
    OSAction*  action,
    IOReturn   status,
    uint32_t   actualByteCount,
    uint64_t   completionTimestamp)
{
    ivars->fTxInFlight.store(false);

    if (status != kIOReturnSuccess && status != kIOReturnAborted) {
        DEXT_LOG("WriteComplete error: 0x%x (bytes=%u)", status, actualByteCount);

        // Recover from pipe stall
        if (status == 0xe0005000 && ivars->fBulkOutPipe) {
            kern_return_t clr = ivars->fBulkOutPipe->ClearStall(false);
            DEXT_LOG("ClearStall OUT pipe: 0x%x", clr);
        }
    }

    // After TX completes, check if more frames need draining
    if (status == kIOReturnSuccess && ivars->fIsRunning.load()) {
        DrainTxRing();
    }
}

// MARK: - Command Pipe (PCAN EP 0x01)

kern_return_t USBCANDriver::SendCommandBytes(const uint8_t* data, uint32_t length)
{
    if (!ivars->fCommandOutPipe) return kIOReturnNotReady;
    if (length == 0) return kIOReturnSuccess;
    if (length > 512) return kIOReturnNoSpace;

    // Lazy-create command buffer
    if (!ivars->fCmdBuffer) {
        kern_return_t ret = IOBufferMemoryDescriptor::Create(
            kIOMemoryDirectionInOut, 512, 0, &ivars->fCmdBuffer);
        if (ret != kIOReturnSuccess || !ivars->fCmdBuffer) {
            DEXT_LOG("SendCommandBytes: create cmd buffer failed: 0x%x", ret);
            return ret;
        }
    }

    // Copy data to command buffer
    uint64_t addr = 0, len = 0;
    ivars->fCmdBuffer->Map(0, 0, 0, 0, &addr, &len);
    memcpy((void*)addr, data, length);

    // Synchronous IO — command pipe is only used for init/teardown, not data path.
    // This avoids fCmdInFlight races when opening two channels sequentially.
    uint32_t bytesTransferred = 0;
    kern_return_t ret = ivars->fCommandOutPipe->IO(
        ivars->fCmdBuffer, length, &bytesTransferred, 5000);

    if (ret != kIOReturnSuccess) {
        DEXT_LOG("SendCommandBytes: IO failed: 0x%x (sent %u/%u bytes)",
                 ret, bytesTransferred, length);
    }

    return ret;
}

void USBCANDriver::CommandWriteComplete_Impl(
    OSAction*  action,
    IOReturn   status,
    uint32_t   actualByteCount,
    uint64_t   completionTimestamp)
{
    ivars->fCmdInFlight.store(false);

    if (status != kIOReturnSuccess && status != kIOReturnAborted) {
        DEXT_LOG("CommandWriteComplete error: 0x%x (bytes=%u)", status, actualByteCount);

        if (status == 0xe0005000 && ivars->fCommandOutPipe) {
            kern_return_t clr = ivars->fCommandOutPipe->ClearStall(false);
            DEXT_LOG("ClearStall CMD pipe: 0x%x", clr);
        }
    }
}

// MARK: - CDC Control Requests

kern_return_t USBCANDriver::SetLineCoding(uint32_t baudRate, uint8_t dataBits,
                                              uint8_t stopBits, uint8_t parity)
{
    DEXT_LOG("SetLineCoding: %u (protocol=%u)", baudRate, ivars->fDetectedProtocol);
    if (!ivars->fDevice) return kIOReturnNotReady;

    ivars->fBaudRate = baudRate;

    // PCAN and gs_usb are NOT CDC devices — skip USB control transfer
    if (ivars->fDetectedProtocol == kCANProtocolPCAN ||
        ivars->fDetectedProtocol == kCANProtocolGSUSB) {
        DEXT_LOG("SetLineCoding: skipped for non-CDC protocol %u", ivars->fDetectedProtocol);
        return kIOReturnSuccess;
    }

    LineCoding coding;
    coding.dwDTERate = baudRate;
    coding.bCharFormat = stopBits;
    coding.bParityType = parity;
    coding.bDataBits = dataBits;

    IOBufferMemoryDescriptor* dataMD = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionOut, sizeof(LineCoding), 0, &dataMD);
    if (ret != kIOReturnSuccess || !dataMD) return kIOReturnNoMemory;

    uint64_t addr = 0, len = 0;
    dataMD->Map(0, 0, 0, 0, &addr, &len);
    memcpy((void*)addr, &coding, sizeof(LineCoding));

    uint16_t bytesTransferred = 0;
    ret = ivars->fDevice->DeviceRequest(
        this, 0x21, kSetLineCoding, 0, 0,
        (uint16_t)sizeof(LineCoding), dataMD,
        &bytesTransferred, 5000);

    dataMD->release();
    return ret;
}
