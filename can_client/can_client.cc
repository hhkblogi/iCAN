/*
 * CANClient.cc — CAN client implementation
 *
 * IOKit IPC to DriverKit (SharedRingHeader frame ring + WaitForData async)
 *   - RX: read structured canfd_frame entries from shared RX ring (no protocol decode)
 *   - TX: write canfd_frame entries to shared TX ring + trigger driver drain
 *   - Channel: OpenChannel/CloseChannel IPC → driver → codec
 */

#include "can_client.h"
#include "ipc_methods.h"
#include "shared_ring.h"

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <time.h>

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <os/log.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach_port.h>
#include <mach/mach_time.h>
#include <mach/message.h>

// Known USB CAN adapters
struct KnownAdapter { int vid; int pid; };
static const KnownAdapter kKnownAdapters[] = {
    { 0x16D0, 0x117E },   // CANable / SH-C31G (slcan)
    { 0x1D50, 0x606F },   // gs_usb / candleLight
    { 0x0C72, 0x0011 },   // PCAN-USB Pro FD (SavvyCAN-FD-X2)
};
static const int kNumKnownAdapters = sizeof(kKnownAdapters) / sizeof(kKnownAdapters[0]);

// Create a matching dict for IOUSBHostDevice with VID/PID
static CFMutableDictionaryRef create_usb_matching_dict(int vid, int pid) {
    CFMutableDictionaryRef dict = IOServiceMatching("IOUSBHostDevice");
    if (!dict) return nullptr;
    CFNumberRef vidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
    CFNumberRef pidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pid);
    CFDictionarySetValue(dict, CFSTR("idVendor"), vidNum);
    CFDictionarySetValue(dict, CFSTR("idProduct"), pidNum);
    CFRelease(vidNum);
    CFRelease(pidNum);
    return dict;
}

// Walk IORegistry children of a USB device to find the IOUserService child (our driver)
static io_service_t find_user_service_child(io_service_t usb_device) {
    io_iterator_t child_iter = 0;
    if (IORegistryEntryGetChildIterator(usb_device, "IOService", &child_iter) != KERN_SUCCESS)
        return 0;

    io_service_t found = 0;
    io_service_t child;
    while ((child = IOIteratorNext(child_iter)) != 0 && found == 0) {
        char class_name[128] = {0};
        IOObjectGetClass(child, class_name);
        if (strcmp(class_name, "IOUserService") == 0) {
            found = child;
            break;
        }
        // Recurse one level for interface children
        io_iterator_t grandchild_iter = 0;
        if (IORegistryEntryGetChildIterator(child, "IOService", &grandchild_iter) == KERN_SUCCESS) {
            io_service_t grandchild;
            while ((grandchild = IOIteratorNext(grandchild_iter)) != 0 && found == 0) {
                char gc_name[128] = {0};
                IOObjectGetClass(grandchild, gc_name);
                if (strcmp(gc_name, "IOUserService") == 0) {
                    found = grandchild;
                    break;
                }
                IOObjectRelease(grandchild);
            }
            IOObjectRelease(grandchild_iter);
        }
        IOObjectRelease(child);
    }
    IOObjectRelease(child_iter);
    return found;
}

// Count how many known USB CAN adapters are present
static int count_usb_adapters() {
    int count = 0;
    for (int a = 0; a < kNumKnownAdapters; a++) {
        CFMutableDictionaryRef dict = create_usb_matching_dict(
            kKnownAdapters[a].vid, kKnownAdapters[a].pid);
        if (!dict) continue;
        io_iterator_t iter = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iter) == KERN_SUCCESS) {
            io_service_t s;
            while ((s = IOIteratorNext(iter)) != 0) {
                count++;
                IOObjectRelease(s);
            }
            IOObjectRelease(iter);
        }
    }
    return count;
}

/// Convert nanoseconds to mach absolute time ticks.
static uint64_t nanosToAbs(uint64_t nanos) {
    // C++ guarantees thread-safe initialization of block-scope statics
    static const mach_timebase_info_data_t sInfo = []() {
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        return info;
    }();
    return nanos * sInfo.denom / sInfo.numer;
}

/* ================================================================
 * CANClientImpl — the actual implementation hidden by pimpl
 * ================================================================ */

static constexpr int kErrorBufSize = 256;
static constexpr int kFrameFifoSize = 2048;

class CANClientImpl {
public:
    /* State */
    bool is_connected = false;
    bool is_open = false;       // CAN channel open

    /* Per-reader decoded frame FIFOs (ring buffers).
     * Each CANClient copy that calls read*() gets its own slot via registerReader().
     * drainRxFrames fan out each frame to all active readers on the
     * matching channel, providing SocketCAN-like independent-reader semantics. */
    static constexpr int kMaxChannels = 2;

    // Per-channel TX write counters (incremented in writeTxFrame, read by dashboard engine)
    std::atomic<uint32_t> txWriteCount[kMaxChannels] = {};
    std::atomic<int> txWriterCount[kMaxChannels] = {};  // distinct writers per channel

    // Per-channel TX CAN ID tracking: canId -> last write timestamp (microseconds)
    std::mutex txIdMutex;
    std::unordered_map<uint32_t, uint64_t> txIdLastSeen[kMaxChannels];
    static constexpr int kMaxReaders = 8;

    struct ReaderSlot {
        CANPacket fifo[kFrameFifoSize];  // ~160KB per slot (frame + timestamp)
        std::atomic<int> head{0};   // producer writes (release), consumer reads (acquire)
        std::atomic<int> tail{0};   // consumer writes (release), producer reads (acquire)
        std::atomic<uint32_t> epoch{0};
        int channel = -1;
        bool active = false;
    };

    ReaderSlot readers[kMaxReaders] = {};
    std::mutex readers_lock;  // protects register/unregister only

    int registerReader(int channel) {
        std::lock_guard<std::mutex> lock(readers_lock);
        for (int i = 0; i < kMaxReaders; i++) {
            if (!readers[i].active) {
                readers[i].active = true;
                readers[i].channel = channel;
                readers[i].head.store(0, std::memory_order_relaxed);
                readers[i].tail.store(0, std::memory_order_relaxed);
                readers[i].epoch.store(0, std::memory_order_relaxed);
                return i;
            }
        }
        return -1;  // full
    }

    void unregisterReader(int idx) {
        if (idx < 0 || idx >= kMaxReaders) return;
        std::lock_guard<std::mutex> lock(readers_lock);
        readers[idx].active = false;
        readers[idx].channel = -1;
    }

    /* Read one packet from a reader's own FIFO. Returns 1 if available, 0 if empty. */
    int readPacketFromReader(int readerId, CANPacket* out) {
        if (readerId < 0 || readerId >= kMaxReaders) return 0;
        auto& r = readers[readerId];
        int curTail = r.tail.load(std::memory_order_relaxed);
        if (curTail == r.head.load(std::memory_order_acquire)) return 0;
        *out = r.fifo[curTail];
        r.tail.store((curTail + 1) % kFrameFifoSize, std::memory_order_release);
        return 1;
    }

    /* Check if a reader's FIFO is empty */
    bool readerEmpty(int readerId) const {
        if (readerId < 0 || readerId >= kMaxReaders) return true;
        auto& r = readers[readerId];
        return r.tail.load(std::memory_order_relaxed) ==
               r.head.load(std::memory_order_acquire);
    }

    /* Push a packet to all active readers matching the given channel */
    void fanOutPacket(const CANPacket& packet, int channel) {
        for (int i = 0; i < kMaxReaders; i++) {
            auto& r = readers[i];
            if (!r.active || r.channel != channel) continue;
            int curHead = r.head.load(std::memory_order_relaxed);
            int next = (curHead + 1) % kFrameFifoSize;
            if (next != r.tail.load(std::memory_order_acquire)) {
                r.fifo[curHead] = packet;
                r.head.store(next, std::memory_order_release);
                r.epoch.fetch_add(1, std::memory_order_release);
                r.epoch.notify_all();
            }
        }
    }

    /* Thread safety */
    std::mutex io_lock;
    std::mutex drain_lock;  // protects drainRxFrames
    // tx_lock removed in V4: per-channel TX rings eliminate multi-producer race
    std::atomic<bool> drainer_active{false};   // only one thread does blockForData at a time
    std::atomic<uint32_t> drain_epoch{0};      // bumped after every drainRxFrames; non-drainer atomic::wait on this

    /* Error reporting */
    char last_error[kErrorBufSize] = {};

    /* IOKit IPC */
    io_connect_t connection = 0;

    /* Shared-memory frame ring (V3 layout) */
    mach_vm_address_t queueAddr = 0;
    mach_vm_size_t    queueSize = 0;
    SharedRingHeader* ringHeader = nullptr;
    mach_port_t       asyncPort = MACH_PORT_NULL;
    bool              useAsyncNotify = false;
    bool              waitPending = false;

    ~CANClientImpl() = default;

    void setError(const char* fmt, ...) {
        va_list ap;
        va_start(ap, fmt);
        std::lock_guard<std::mutex> lock(io_lock);
        vsnprintf(last_error, kErrorBufSize, fmt, ap);
        va_end(ap);
    }

    void clearError() {
        std::lock_guard<std::mutex> lock(io_lock);
        last_error[0] = '\0';
    }

    /* ================================================================
     * Device path: frame ring operations
     * ================================================================ */

    /* Drain structured frames from SharedRingHeader RX ring into FIFO.
     * V5 RX entry format: [uint16_t frameSize][uint64_t timestamp_us][frame bytes]
     * Total entry = 2 + 8 + frameSize */
    int drainRxFrames() {
        if (!ringHeader || ringHeader->magic != SHARED_RING_MAGIC) return 0;

        uint32_t head = ring_load_head_acquire(&ringHeader->rx);
        uint32_t tail = ring_load_tail_relaxed(&ringHeader->rx);
        if (head == tail) return 0;

        uint32_t cap = ringHeader->rxCapacity;
        const uint8_t* rxData = ringHeader->data;
        int count = 0;

        while (head != tail) {
            uint32_t avail = head - tail;
            if (avail < 10) break;  // minimum: 2 (size) + 8 (timestamp)

            // Read entry header: [uint16_t frameSize]
            uint16_t frameSize = static_cast<uint16_t>(
                static_cast<uint32_t>(rxData[tail % cap]) |
                (static_cast<uint32_t>(rxData[(tail + 1) % cap]) << 8));

            uint32_t entrySize = 2 + 8 + frameSize;  // header + timestamp + frame
            if (entrySize > avail) break;  // incomplete entry

            // Validate frame size
            if (frameSize != CAN_MTU && frameSize != CANFD_MTU) {
                tail += entrySize;  // skip invalid entry
                continue;
            }

            // Read timestamp (8 bytes, little-endian, handle ring wrap)
            uint64_t timestamp_us = 0;
            for (uint32_t i = 0; i < 8; i++) {
                timestamp_us |= static_cast<uint64_t>(rxData[(tail + 2 + i) % cap]) << (i * 8);
            }

            // Read frame bytes (handle ring wrap)
            CANPacket packet;
            packet.timestamp_us = timestamp_us;
            memset(&packet.frame, 0, sizeof(canfd_frame));

            if (frameSize == CAN_MTU) {
                uint8_t frameBuf[CAN_MTU];
                for (uint32_t i = 0; i < frameSize; i++) {
                    frameBuf[i] = rxData[(tail + 10 + i) % cap];
                }
                auto* cf = reinterpret_cast<can_frame*>(frameBuf);
                packet.frame.can_id = cf->can_id;
                packet.frame.len = cf->len;
                packet.frame.flags = 0;
                packet.frame.__res0 = cf->__res0;  // preserve channel
                memcpy(packet.frame.data, cf->data, cf->len);
            } else {
                for (uint32_t i = 0; i < frameSize; i++) {
                    reinterpret_cast<uint8_t*>(&packet.frame)[i] = rxData[(tail + 10 + i) % cap];
                }
            }

            // Fan out to all active readers on the matching channel
            int ch = CAN_CHANNEL(packet.frame);
            if (ch < 0 || ch >= kMaxChannels) ch = 0;
            fanOutPacket(packet, ch);
            count++;

            tail += entrySize;
        }

        ring_store_tail_release(&ringHeader->rx, tail);
        return count;
    }

    /* Write a canfd_frame to the per-channel TX ring. Returns true on success.
     * V4 layout: each channel has its own SPSC TX ring (tx0 / tx1).
     * No mutex needed — each channel's TX thread is the sole producer.
     *
     * IMPORTANT: Single-writer-per-channel contract. Each TX ring is SPSC.
     * Callers MUST NOT have multiple threads writing to the same channel
     * concurrently. The BidirTestEngine enforces this: one TX thread per
     * channel. Violating this contract causes silent data corruption. */
    bool writeTxFrame(const canfd_frame* frame, int channel) {
        if (!ringHeader || ringHeader->magic != SHARED_RING_MAGIC) return false;

        // Select per-channel ring control and data region
        RingCtrl* txCtrl;
        uint8_t* txData;
        uint32_t cap;
        if (channel == 1 && ringHeader->channelCount >= 2 && ringHeader->tx1Capacity > 0) {
            txCtrl = &ringHeader->tx1;
            txData = shared_ring_tx1_data(ringHeader);
            cap = ringHeader->tx1Capacity;
        } else {
            txCtrl = &ringHeader->tx0;
            txData = shared_ring_tx0_data(ringHeader);
            cap = ringHeader->tx0Capacity;
        }

        uint16_t frameSize = static_cast<uint16_t>(sizeof(canfd_frame));
        uint32_t entrySize = 2 + frameSize;

        uint32_t head = ring_load_head_relaxed(txCtrl);
        uint32_t tail = ring_load_tail_acquire(txCtrl);
        uint32_t free = cap - (head - tail);

        if (entrySize > free) return false;

        // Write entry header
        txData[head % cap] = static_cast<uint8_t>(frameSize & 0xFF);
        txData[(head + 1) % cap] = static_cast<uint8_t>(frameSize >> 8);

        // Write frame bytes (handle ring wrap)
        const uint8_t* frameBytes = reinterpret_cast<const uint8_t*>(frame);
        for (uint32_t i = 0; i < frameSize; i++) {
            txData[(head + 2 + i) % cap] = frameBytes[i];
        }

        ring_store_head_release(txCtrl, head + entrySize);
        if (channel >= 0 && channel < kMaxChannels) {
            txWriteCount[channel].fetch_add(1, std::memory_order_relaxed);
            // Track TX CAN ID with timestamp
            uint32_t canId = frame->can_id & 0x1FFFFFFFU;
            {
                std::lock_guard<std::mutex> lock(txIdMutex);
                txIdLastSeen[channel][canId] = clock_gettime_nsec_np(CLOCK_REALTIME) / 1000;
            }
        }
        return true;
    }

    /* Trigger driver to drain TX ring */
    void triggerTxDrain() {
        if (!connection) return;
        // Call SendData with no struct input → driver drains TX ring
        IOConnectCallStructMethod(connection, kCANDriverMethodSendData,
                                   nullptr, 0, nullptr, nullptr);
    }

    /* Submit WaitForData async call to driver */
    void submitWaitForData() {
        if (!connection || asyncPort == MACH_PORT_NULL) return;
        uint64_t ref = 0;
        IOConnectCallAsyncScalarMethod(
            connection, kCANDriverMethodWaitForData,
            asyncPort, &ref, 1,
            nullptr, 0, nullptr, nullptr);
    }

    /* Block until data notification or timeout */
    void blockForData(uint32_t timeoutMs) {
        if (useAsyncNotify && asyncPort != MACH_PORT_NULL) {
            if (!waitPending) {
                submitWaitForData();
                waitPending = true;
            }
            struct { mach_msg_header_t header; uint8_t pad[256]; } msg;
            memset(&msg, 0, sizeof(msg));
            kern_return_t kr = mach_msg(&msg.header,
                     MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                     0, sizeof(msg), asyncPort, timeoutMs,
                     MACH_PORT_NULL);
            if (kr == MACH_MSG_SUCCESS) {
                waitPending = false;
            }
        } else {
            usleep(timeoutMs * 1000);
        }
    }

    /* Set up WaitForData async completion with driver */
    bool setupAsyncNotification() {
        if (!connection) return false;

        mach_port_t port = MACH_PORT_NULL;
        kern_return_t kr = mach_port_allocate(
            mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
        if (kr != KERN_SUCCESS) return false;

        kr = mach_port_insert_right(
            mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
        if (kr != KERN_SUCCESS) {
            mach_port_destruct(mach_task_self(), port, 0, 0);
            return false;
        }

        // Probe: submit WaitForData to check driver support
        uint64_t ref = 0;
        kr = IOConnectCallAsyncScalarMethod(
            connection, kCANDriverMethodWaitForData,
            port, &ref, 1,
            nullptr, 0, nullptr, nullptr);
        if (kr != KERN_SUCCESS) {
            os_log_error(OS_LOG_DEFAULT, "CANClient: WaitForData unsupported: 0x%x", kr);
            mach_port_destruct(mach_task_self(), port, 0, 0);
            return false;
        }

        asyncPort = port;
        useAsyncNotify = true;

        // Drain probe response
        struct { mach_msg_header_t header; uint8_t pad[256]; } msg;
        memset(&msg, 0, sizeof(msg));
        kern_return_t drainKr = mach_msg(&msg.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                 0, sizeof(msg), asyncPort, 50, MACH_PORT_NULL);
        if (drainKr == MACH_RCV_TIMED_OUT) {
            waitPending = true;
        }

        os_log(OS_LOG_DEFAULT, "CANClient: async RX notification OK");
        return true;
    }

    /* Read available frames from shared-memory ring.
     * drain_lock serializes concurrent callers (e.g. two channels polling). */
    uint64_t drainCallCount = 0;
    void drainIOKit(uint32_t timeoutMs = 0) {
        drainCallCount++;
        if (!ringHeader) {
            if (drainCallCount == 1) {
                setError("drainIOKit: ringHeader=NULL, map failed");
            }
            return;
        }

        if (drainCallCount == 1) {
            os_log(OS_LOG_DEFAULT,
                "CANClient: SharedRingHeader magic=0x%x layout=V%u rxCap=%u tx0Cap=%u",
                ringHeader->magic, ringHeader->layoutVersion,
                ringHeader->rxCapacity, ringHeader->tx0Capacity);
        }

        {
            std::lock_guard<std::mutex> lock(drain_lock);
            int drainedFrames = drainRxFrames();
            if (drainedFrames > 0) {
                if (drainCallCount <= 3) {
                    os_log(OS_LOG_DEFAULT, "CANClient: drain#%llu: drained %d frames OK",
                           drainCallCount, drainedFrames);
                }
                return;
            }
        }

        if (drainCallCount == 2) {
            os_log(OS_LOG_DEFAULT, "CANClient: drain#2: empty notify=%s",
                   useAsyncNotify ? "async" : "poll");
        }

        if (timeoutMs == 0) return;

        // Block for data notification (outside lock — don't hold while sleeping)
        blockForData(timeoutMs);

        // Drain again after wakeup
        {
            std::lock_guard<std::mutex> lock(drain_lock);
            int afterFrames = drainRxFrames();
            if (afterFrames > 0 && drainCallCount <= 5) {
                os_log(OS_LOG_DEFAULT, "CANClient: drain#%llu: woke+drained %d frames",
                       drainCallCount, afterFrames);
            }
        }
    }

    /* Send raw bytes via ExternalMethod(kSendData) */
    int sendBytes(const void* data, uint32_t len) {
        if (!connection || len == 0) return 0;

        kern_return_t kr = IOConnectCallStructMethod(
            connection,
            kCANDriverMethodSendData,
            data, len,
            nullptr, nullptr);

        return (kr == KERN_SUCCESS) ? static_cast<int>(len) : 0;
    }
};

/* ================================================================
 * CANClient — public API delegates to _impl
 * ================================================================ */

CANClient::CANClient() : _impl(std::make_shared<CANClientImpl>()), _channel(0), _readerId(-1) {}

CANClient::~CANClient() {
    if (_readerId >= 0 && _impl)
        _impl->unregisterReader(_readerId);
    if (_isTxRegistered && _impl && _channel >= 0 && _channel < CANClientImpl::kMaxChannels)
        _impl->txWriterCount[_channel].fetch_sub(1, std::memory_order_relaxed);
}

// Copy: shares impl but gets its own reader slot on first read
CANClient::CANClient(const CANClient& other)
    : _impl(other._impl), _channel(other._channel), _readerId(-1) {}

CANClient& CANClient::operator=(const CANClient& other) {
    if (this != &other) {
        if (_readerId >= 0 && _impl)
            _impl->unregisterReader(_readerId);
        _impl = other._impl;
        _channel = other._channel;
        _readerId = -1;
    }
    return *this;
}

// Move: transfers reader slot ownership
CANClient::CANClient(CANClient&& other) noexcept
    : _impl(std::move(other._impl)), _channel(other._channel), _readerId(other._readerId) {
    other._readerId = -1;
}

CANClient& CANClient::operator=(CANClient&& other) noexcept {
    if (this != &other) {
        if (_readerId >= 0 && _impl)
            _impl->unregisterReader(_readerId);
        _impl = std::move(other._impl);
        _channel = other._channel;
        _readerId = other._readerId;
        other._readerId = -1;
    }
    return *this;
}

void CANClient::ensureReader() {
    if (_readerId < 0 && _impl)
        _readerId = _impl->registerReader(_channel);
}

void CANClient::setChannel(int channel) { _channel = channel; }

bool CANClient::open(int adapter_index) {
    auto& c = *_impl;

    // IOKit IPC — find DriverKit service via USB VID/PID + IORegistry walk
    io_service_t service = 0;

    // Strategy 1: VID/PID match on IOUSBHostDevice → walk to child IOUserService
    int device_index = 0;
    for (int a = 0; a < kNumKnownAdapters && service == 0; a++) {
        CFMutableDictionaryRef dict = create_usb_matching_dict(
            kKnownAdapters[a].vid, kKnownAdapters[a].pid);
        if (!dict) continue;

        io_iterator_t iter = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iter) != KERN_SUCCESS)
            continue;

        io_service_t usb_device;
        while ((usb_device = IOIteratorNext(iter)) != 0) {
            if (device_index == adapter_index) {
                service = find_user_service_child(usb_device);
                IOObjectRelease(usb_device);
                break;
            }
            IOObjectRelease(usb_device);
            device_index++;
        }
        IOObjectRelease(iter);
    }

    // Strategy 2: Enumerate all IOUserService named "USBCANDriver"
    if (service == 0) {
        CFMutableDictionaryRef dict = IOServiceMatching("IOUserService");
        if (dict) {
            io_iterator_t iter = 0;
            if (IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iter) == KERN_SUCCESS) {
                io_service_t candidate;
                int match_index = 0;
                while ((candidate = IOIteratorNext(iter)) != 0) {
                    char name[128] = {0};
                    IORegistryEntryGetName(candidate, name);
                    if (strcmp(name, "USBCANDriver") == 0) {
                        if (match_index == adapter_index) {
                            service = candidate;
                            break;
                        }
                        match_index++;
                    }
                    IOObjectRelease(candidate);
                }
                IOObjectRelease(iter);
            }
        }
    }

    if (service == 0) {
        int usb_count = count_usb_adapters();
        if (usb_count > 0) {
            c.setError("USB adapter detected but driver not loaded. Try rebooting iPad.");
        } else {
            c.setError("No USB CAN adapter found. Is the driver approved in Settings?");
        }
        return false;
    }

    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &c.connection);
    IOObjectRelease(service);

    if (kr != KERN_SUCCESS || c.connection == 0) {
        c.setError("IOServiceOpen failed: 0x%x", kr);
        c.connection = 0;
        return false;
    }

    // Open the driver (triggers USB configuration)
    kr = IOConnectCallScalarMethod(c.connection, kCANDriverMethodOpen,
                                    nullptr, 0, nullptr, nullptr);
    if (kr != KERN_SUCCESS) {
        c.setError("Open method failed: 0x%x", kr);
        IOServiceClose(c.connection);
        c.connection = 0;
        return false;
    }

    // Map the SharedRingHeader shared memory
    kr = IOConnectMapMemory64(c.connection, 0, mach_task_self(),
                               &c.queueAddr, &c.queueSize, kIOMapAnywhere);
    os_log_error(OS_LOG_DEFAULT, "CANClient: IOConnectMapMemory64 → 0x%x addr=%p size=%llu",
           kr, (void*)c.queueAddr, (unsigned long long)c.queueSize);
    if (kr == KERN_SUCCESS && c.queueAddr) {
        c.ringHeader = reinterpret_cast<SharedRingHeader*>(c.queueAddr);
        if (c.ringHeader->magic != SHARED_RING_MAGIC) {
            os_log_error(OS_LOG_DEFAULT,
                "CANClient: SharedRingHeader BAD MAGIC: 0x%x (expected 0x%x)",
                c.ringHeader->magic, SHARED_RING_MAGIC);
            c.setError("SharedRingHeader bad magic. Reboot iPad.");
            c.ringHeader = nullptr;
        } else if (c.ringHeader->layoutVersion != SHARED_RING_LAYOUT_VERSION) {
            os_log_error(OS_LOG_DEFAULT,
                "CANClient: STALE DEXT — layoutVersion=%u expected=%u. "
                "Toggle driver OFF/ON in Settings or reboot iPad.",
                c.ringHeader->layoutVersion, SHARED_RING_LAYOUT_VERSION);
            c.setError("Stale dext (layout V%u, need V%u). Reboot iPad.",
                c.ringHeader->layoutVersion, SHARED_RING_LAYOUT_VERSION);
            c.ringHeader = nullptr;
        } else {
            os_log(OS_LOG_DEFAULT,
                "CANClient: SharedRingHeader OK: rxCap=%u tx0Cap=%u layout=V%u proto=%u",
                c.ringHeader->rxCapacity, c.ringHeader->tx0Capacity,
                c.ringHeader->layoutVersion, c.ringHeader->protocolId);
            c.setupAsyncNotification();
        }
    } else {
        os_log_error(OS_LOG_DEFAULT, "CANClient: IOConnectMapMemory64 FAILED: 0x%x", kr);
        c.setError("IOConnectMapMemory64 failed: 0x%x", kr);
        c.queueAddr = 0;
        c.ringHeader = nullptr;
    }

    c.is_connected = true;
    if (c.ringHeader) {
        c.clearError();
    }
    return true;
}

void CANClient::close() {
    auto& c = *_impl;

    bool was_open;
    {
        std::lock_guard<std::mutex> lock(c.io_lock);
        was_open = c.is_open;
        c.is_connected = false;
        c.is_open = false;
    }

    if (was_open && c.connection) {
        // Close CAN channel via codec
        uint64_t input[] = { static_cast<uint64_t>(_channel) };
        IOConnectCallScalarMethod(c.connection, kCANDriverMethodCloseChannel,
                                   input, 1, nullptr, nullptr);
    }

    // Unmap shared memory
    if (c.queueAddr) {
        IOConnectUnmapMemory64(c.connection, 0, mach_task_self(), c.queueAddr);
        c.queueAddr = 0;
        c.ringHeader = nullptr;
    }
    if (c.asyncPort != MACH_PORT_NULL) {
        mach_port_destruct(mach_task_self(), c.asyncPort, 0, 0);
        c.asyncPort = MACH_PORT_NULL;
    }
    c.useAsyncNotify = false;
    c.waitPending = false;

    if (c.connection) {
        IOConnectCallScalarMethod(c.connection, kCANDriverMethodClose,
                                   nullptr, 0, nullptr, nullptr);
        IOServiceClose(c.connection);
        c.connection = 0;
    }

    // Reset all reader FIFOs (slots stay registered — owned by CANClient copies)
    for (int i = 0; i < CANClientImpl::kMaxReaders; i++) {
        c.readers[i].head.store(0, std::memory_order_relaxed);
        c.readers[i].tail.store(0, std::memory_order_relaxed);
        c.readers[i].epoch.store(0, std::memory_order_relaxed);
    }
    c.drain_epoch.store(0, std::memory_order_relaxed);
}

/* ---- Individual channel operations ---- */

int CANClient::openSerial() {
    auto& c = *_impl;
    if (!c.is_connected) {
        c.setError("Not connected");
        return -1;
    }
    return 0;
}

int CANClient::closeSerial() {
    return 0;
}

int CANClient::setBaudRate(uint32_t baud_rate) {
    auto& c = *_impl;
    if (!c.is_connected) {
        c.setError("Not connected");
        return -1;
    }

    uint64_t input[] = { baud_rate };
    kern_return_t kr = IOConnectCallScalarMethod(
        c.connection, kCANDriverMethodSetBaudRate, input, 1, nullptr, nullptr);
    if (kr != KERN_SUCCESS) {
        c.setError("SetBaudRate failed: 0x%x", kr);
        return -1;
    }
    return 0;
}

int CANClient::openChannel(uint32_t bitrate) {
    auto& c = *_impl;
    if (!c.is_connected) {
        c.setError("Not connected");
        return -1;
    }

    // Device: codec-based channel open via IPC (bitrate + channel)
    uint64_t input[] = { bitrate, static_cast<uint64_t>(_channel) };
    kern_return_t kr = IOConnectCallScalarMethod(
        c.connection, kCANDriverMethodOpenChannel, input, 2, nullptr, nullptr);
    if (kr != KERN_SUCCESS) {
        c.setError("OpenChannel failed: 0x%x", kr);
        return -1;
    }

    {
        std::lock_guard<std::mutex> lock(c.io_lock);
        c.is_open = true;
    }

    // Clear stale RX data for all readers on this channel
    int ch = (_channel >= 0 && _channel < CANClientImpl::kMaxChannels) ? _channel : 0;
    for (int i = 0; i < CANClientImpl::kMaxReaders; i++) {
        if (c.readers[i].active && c.readers[i].channel == ch) {
            c.readers[i].head.store(0, std::memory_order_relaxed);
            c.readers[i].tail.store(0, std::memory_order_relaxed);
            c.readers[i].epoch.store(0, std::memory_order_relaxed);
        }
    }

    c.clearError();
    return 0;
}

int CANClient::closeChannel() {
    auto& c = *_impl;

    {
        std::lock_guard<std::mutex> lock(c.io_lock);
        c.is_open = false;
    }

    if (c.connection) {
        uint64_t input[] = { static_cast<uint64_t>(_channel) };
        IOConnectCallScalarMethod(c.connection, kCANDriverMethodCloseChannel,
                                   input, 1, nullptr, nullptr);
    }
    return 0;
}

/* ---- Combined convenience functions ---- */

int CANClient::start(uint32_t bitrate) {
    int r = openSerial();
    if (r < 0) return r;
    return openChannel(bitrate);
}

int CANClient::stop() {
    closeChannel();
    return closeSerial();
}

/* ---- Frame write ---- */

int CANClient::writeClassic(const struct can_frame* frame) {
    if (!frame) return 0;
    auto& c = *_impl;

    canfd_frame fd_frame;
    memset(&fd_frame, 0, sizeof(fd_frame));
    fd_frame.can_id = frame->can_id;
    uint8_t copyLen = frame->len;
    if (copyLen > CAN_MAX_DLEN) copyLen = CAN_MAX_DLEN;
    fd_frame.len = copyLen;
    fd_frame.flags = 0;
    CAN_CHANNEL(fd_frame) = static_cast<uint8_t>(_channel);
    memcpy(fd_frame.data, frame->data, copyLen);

    if (!c.writeTxFrame(&fd_frame, _channel)) return 0;
    if (!_isTxRegistered && _channel >= 0 && _channel < CANClientImpl::kMaxChannels) {
        c.txWriterCount[_channel].fetch_add(1, std::memory_order_relaxed);
        _isTxRegistered = true;
    }
    c.triggerTxDrain();
    return 1;
}

int CANClient::write(const struct canfd_frame* frame) {
    if (!frame) return 0;
    auto& c = *_impl;

    // Tag channel on outgoing frame
    canfd_frame tagged = *frame;
    CAN_CHANNEL(tagged) = static_cast<uint8_t>(_channel);

    if (!c.writeTxFrame(&tagged, _channel)) return 0;
    if (!_isTxRegistered && _channel >= 0 && _channel < CANClientImpl::kMaxChannels) {
        c.txWriterCount[_channel].fetch_add(1, std::memory_order_relaxed);
        _isTxRegistered = true;
    }
    c.triggerTxDrain();
    return 1;
}

/* ---- Frame read ---- */

int CANClient::read(struct CANPacket* packet) {
    if (!packet) return 0;
    ensureReader();
    auto& c = *_impl;

    c.drainIOKit();
    return c.readPacketFromReader(_readerId, packet);
}

int CANClient::readMany(struct CANPacket* packets, int max_packets) {
    if (!packets || max_packets <= 0) return 0;
    ensureReader();
    auto& c = *_impl;

    c.drainIOKit();

    int count = 0;
    for (int i = 0; i < max_packets; i++) {
        if (c.readPacketFromReader(_readerId, &packets[i]) != 1) break;
        count++;
    }
    return count;
}

int CANClient::readManyBlocking(struct CANPacket* packets, int max_packets, uint32_t timeoutMs) {
    if (!packets || max_packets <= 0) return 0;
    ensureReader();
    auto& c = *_impl;

    // Non-blocking drain first
    {
        std::lock_guard<std::mutex> lock(c.drain_lock);
        c.drainRxFrames();
    }

    if (c.readerEmpty(_readerId) && timeoutMs > 0) {
        uint64_t deadline = mach_absolute_time() + nanosToAbs((uint64_t)timeoutMs * 1000000ULL);

        while (c.readerEmpty(_readerId) && mach_absolute_time() < deadline) {
            // One thread does blockForData + drain; others atomic::wait on drain_epoch
            bool expected = false;
            if (c.drainer_active.compare_exchange_strong(expected, true,
                    std::memory_order_acq_rel)) {
                // Drainer: wait for driver notification, drain ring, wake all waiters
                c.blockForData(2);
                {
                    std::lock_guard<std::mutex> lock(c.drain_lock);
                    c.drainRxFrames();
                }
                c.drain_epoch.fetch_add(1, std::memory_order_release);
                c.drain_epoch.notify_all();
                c.drainer_active.store(false, std::memory_order_release);
            } else {
                // Non-drainer: atomic::wait for drain_epoch change (zero-latency wakeup)
                uint32_t de = c.drain_epoch.load(std::memory_order_acquire);
                c.drain_epoch.wait(de, std::memory_order_acquire);
            }
        }
    }

    int count = 0;
    for (int i = 0; i < max_packets; i++) {
        if (c.readPacketFromReader(_readerId, &packets[i]) != 1) break;
        count++;
    }
    return count;
}

int CANClient::sendRaw(const void* data, int len) {
    if (!data || len <= 0) return 0;
    auto& c = *_impl;

    return c.sendBytes(data, static_cast<uint32_t>(len));
}

const char* CANClient::lastError() const {
    auto& c = *_impl;
    std::lock_guard<std::mutex> lock(c.io_lock);
    return c.last_error;
}

uint32_t CANClient::dropCount() const {
    auto& c = *_impl;
    if (c.ringHeader && c.ringHeader->magic == SHARED_RING_MAGIC)
        return c.ringHeader->rxDropped;
    return 0;
}

uint32_t CANClient::txCount() const {
    auto& c = *_impl;
    if (_channel >= 0 && _channel < CANClientImpl::kMaxChannels)
        return c.txWriteCount[_channel].load(std::memory_order_relaxed);
    return 0;
}

int CANClient::rxReaderCount() const {
    auto& c = *_impl;
    int count = 0;
    for (int i = 0; i < CANClientImpl::kMaxReaders; i++) {
        if (c.readers[i].active && c.readers[i].channel == _channel)
            count++;
    }
    return count;
}

int CANClient::txWriterCount() const {
    auto& c = *_impl;
    if (_channel >= 0 && _channel < CANClientImpl::kMaxChannels)
        return c.txWriterCount[_channel].load(std::memory_order_relaxed);
    return 0;
}

int CANClient::txUniqueIds(int windowSec) const {
    auto& c = *_impl;
    if (_channel < 0 || _channel >= CANClientImpl::kMaxChannels) return 0;
    uint64_t now_us = clock_gettime_nsec_np(CLOCK_REALTIME) / 1000;
    uint64_t window_us = static_cast<uint64_t>(windowSec) * 1000000ULL;
    int count = 0;
    {
        std::lock_guard<std::mutex> lock(c.txIdMutex);
        for (const auto& [id, lastSeen] : c.txIdLastSeen[_channel]) {
            if ((now_us - lastSeen) < window_us) count++;
        }
    }
    return count;
}

uint32_t CANClient::codecEchoCount() const {
    auto& c = *_impl;
    if (c.ringHeader && c.ringHeader->magic == SHARED_RING_MAGIC)
        return __atomic_load_n(&c.ringHeader->codecEchoCount, __ATOMIC_RELAXED);
    return 0;
}

uint32_t CANClient::codecOverrunCount() const {
    auto& c = *_impl;
    if (c.ringHeader && c.ringHeader->magic == SHARED_RING_MAGIC)
        return __atomic_load_n(&c.ringHeader->codecOverrunCount, __ATOMIC_RELAXED);
    return 0;
}

uint32_t CANClient::codecTruncatedCount() const {
    auto& c = *_impl;
    if (c.ringHeader && c.ringHeader->magic == SHARED_RING_MAGIC)
        return __atomic_load_n(&c.ringHeader->codecTruncatedCount, __ATOMIC_RELAXED);
    return 0;
}

uint32_t CANClient::codecZeroSentinelCount() const {
    auto& c = *_impl;
    if (c.ringHeader && c.ringHeader->magic == SHARED_RING_MAGIC)
        return __atomic_load_n(&c.ringHeader->codecZeroSentinelCount, __ATOMIC_RELAXED);
    return 0;
}

uint32_t CANClient::dbgTransferSeq() const {
    auto& c = *_impl;
    if (c.ringHeader && c.ringHeader->magic == SHARED_RING_MAGIC)
        return __atomic_load_n(&c.ringHeader->dbgTransferSeq, __ATOMIC_RELAXED);
    return 0;
}

uint32_t CANClient::dbgTransferLen() const {
    auto& c = *_impl;
    if (c.ringHeader && c.ringHeader->magic == SHARED_RING_MAGIC)
        return __atomic_load_n(&c.ringHeader->dbgTransferLen, __ATOMIC_RELAXED);
    return 0;
}

uint32_t CANClient::dbgMsgsParsed() const {
    auto& c = *_impl;
    if (c.ringHeader && c.ringHeader->magic == SHARED_RING_MAGIC)
        return __atomic_load_n(&c.ringHeader->dbgMsgsParsed, __ATOMIC_RELAXED);
    return 0;
}

void CANClient::dbgHead(uint8_t* out, uint32_t maxLen) const {
    if (!out || maxLen == 0) return;
    auto& c = *_impl;
    if (c.ringHeader && c.ringHeader->magic == SHARED_RING_MAGIC) {
        uint32_t n = (maxLen < 48) ? maxLen : 48;
        memcpy(out, c.ringHeader->dbgHead, n);
    }
}

bool CANClient::isConnected() const {
    auto& c = *_impl;
    std::lock_guard<std::mutex> lock(c.io_lock);
    return c.is_connected;
}

bool CANClient::isOpen() const {
    auto& c = *_impl;
    std::lock_guard<std::mutex> lock(c.io_lock);
    return c.is_open;
}
