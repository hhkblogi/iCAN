/*
 * CANClient.cc — CAN client implementation
 *
 * Device builds: IOKit IPC to DriverKit (SharedRingHeader frame ring + WaitForData async)
 *   - RX: read structured canfd_frame entries from shared RX ring (no protocol decode)
 *   - TX: write canfd_frame entries to shared TX ring + trigger driver drain
 *   - Channel: OpenChannel/CloseChannel IPC → driver → codec
 *
 * Simulator builds: POSIX serial I/O to /dev/cu.usbmodem* with SLCAN text codec
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

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <os/log.h>

#if TARGET_OS_SIMULATOR
#include <glob.h>
#include <termios.h>
#include <sys/select.h>
#else
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
#endif

/* ================================================================
 * SLCAN text codec (simulator path only — device path uses driver codec)
 * ================================================================ */

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

/// Encode a CAN/FD frame to SLCAN text. Returns bytes written (including \r).
static uint32_t slcan_encode(const canfd_frame* frame, char* out, uint32_t outSize) {
    if (!frame || !out || outSize < 8) return 0;

    uint32_t pos = 0;
    bool isExtended = (frame->can_id & CAN_EFF_FLAG) != 0;
    bool isFD = (frame->flags & CANFD_FDF) != 0;
    uint32_t rawId = isExtended ? (frame->can_id & CAN_EFF_MASK)
                                : (frame->can_id & CAN_SFF_MASK);

    if (isFD) {
        out[pos++] = isExtended ? 'D' : 'd';
    } else {
        out[pos++] = isExtended ? 'T' : 't';
    }

    if (isExtended) {
        for (int i = 7; i >= 0; i--)
            out[pos++] = hex_nibble((rawId >> (i * 4)) & 0x0F);
    } else {
        out[pos++] = hex_nibble((rawId >> 8) & 0x0F);
        out[pos++] = hex_nibble((rawId >> 4) & 0x0F);
        out[pos++] = hex_nibble(rawId & 0x0F);
    }

    uint8_t dlc = isFD ? canfd_len_to_dlc(frame->len) : frame->len;
    out[pos++] = hex_nibble(dlc);

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

/// Decode an SLCAN line into a canfd_frame. Returns true on success.
static bool slcan_decode(const char* buf, uint32_t len, canfd_frame* out) {
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

    canid_t canId = 0;
    for (uint32_t i = 0; i < idDigits; i++) {
        int v = hex_val(buf[pos++]);
        if (v < 0) return false;
        canId = (canId << 4) | static_cast<uint32_t>(v);
    }
    if (isExtended) canId |= CAN_EFF_FLAG;
    out->can_id = canId;

    int dlcVal = hex_val(buf[pos++]);
    if (dlcVal < 0 || dlcVal > 15) return false;

    uint8_t dataLen = isFD ? canfd_dlc_to_len(static_cast<uint8_t>(dlcVal))
                           : static_cast<uint8_t>(dlcVal);
    if (!isFD && dataLen > CAN_MAX_DLEN) return false;
    out->len = dataLen;
    if (isFD) out->flags = CANFD_FDF;

    if (pos + dataLen * 2 > len) return false;
    for (uint8_t i = 0; i < dataLen; i++) {
        int hi = hex_val(buf[pos++]);
        int lo = hex_val(buf[pos++]);
        if (hi < 0 || lo < 0) return false;
        out->data[i] = static_cast<uint8_t>((hi << 4) | lo);
    }

    return true;
}

/// Map CAN bitrate (bps) to SLCAN 'Sn' command digit.
static char slcan_bitrate_to_code(uint32_t bitrate) {
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

#if !TARGET_OS_SIMULATOR
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
#endif

/* ================================================================
 * CANClientImpl — the actual implementation hidden by pimpl
 * ================================================================ */

static constexpr int kErrorBufSize = 256;
static constexpr int kRxBufSize = 4096;
static constexpr int kFrameFifoSize = 2048;

class CANClientImpl {
public:
    /* State */
    bool is_connected = false;
    bool is_open = false;       // CAN channel open

    /* SLCAN RX accumulator (simulator path only) */
    char rx_line[256] = {};
    int  rx_line_len = 0;

    /* Per-reader decoded frame FIFOs (ring buffers).
     * Each CANClient copy that calls read*() gets its own slot via registerReader().
     * drainRxFrames/processRxBytes fan out each frame to all active readers on the
     * matching channel, providing SocketCAN-like independent-reader semantics. */
    static constexpr int kMaxChannels = 2;
    static constexpr int kMaxReaders = 8;

    struct ReaderSlot {
        canfd_frame fifo[kFrameFifoSize];  // ~144KB per slot
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

    /* Read one frame from a reader's own FIFO. Returns 1 if available, 0 if empty. */
    int readFrameFromReader(int readerId, canfd_frame* out) {
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

    /* Push a frame to all active readers matching the given channel */
    void fanOutFrame(const canfd_frame& frame, int channel) {
        for (int i = 0; i < kMaxReaders; i++) {
            auto& r = readers[i];
            if (!r.active || r.channel != channel) continue;
            int curHead = r.head.load(std::memory_order_relaxed);
            int next = (curHead + 1) % kFrameFifoSize;
            if (next != r.tail.load(std::memory_order_acquire)) {
                r.fifo[curHead] = frame;
                r.head.store(next, std::memory_order_release);
                r.epoch.fetch_add(1, std::memory_order_release);
                r.epoch.notify_all();
            }
        }
    }

    /* Thread safety */
    std::mutex io_lock;
    std::mutex drain_lock;  // protects drainRxFrames / drainSerial
    std::atomic<bool> drainer_active{false};   // only one thread does blockForData at a time
    std::atomic<uint32_t> drain_epoch{0};      // bumped after every drainRxFrames; non-drainer atomic::wait on this

    /* Error reporting */
    char last_error[kErrorBufSize] = {};

#if TARGET_OS_SIMULATOR
    /* POSIX serial */
    int fd = -1;
    char device_path[256] = {};
#else
    /* IOKit IPC */
    io_connect_t connection = 0;

    /* Shared-memory frame ring (V3 layout) */
    mach_vm_address_t queueAddr = 0;
    mach_vm_size_t    queueSize = 0;
    SharedRingHeader* ringHeader = nullptr;
    mach_port_t       asyncPort = MACH_PORT_NULL;
    bool              useAsyncNotify = false;
    bool              waitPending = false;
#endif

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

#if TARGET_OS_SIMULATOR
    /* Process raw bytes through SLCAN accumulator, fan out to all active readers.
     * SLCAN is always single-channel, so frames go to channel 0. */
    void processRxBytes(const uint8_t* data, uint32_t len) {
        constexpr int ch = 0;
        for (uint32_t i = 0; i < len; i++) {
            char c = static_cast<char>(data[i]);
            if (c == '\r') {
                if (rx_line_len > 0) {
                    canfd_frame frame;
                    if (slcan_decode(rx_line, static_cast<uint32_t>(rx_line_len), &frame)) {
                        fanOutFrame(frame, ch);
                    }
                }
                rx_line_len = 0;
            } else if (c != '\n' && rx_line_len < static_cast<int>(sizeof(rx_line) - 1)) {
                rx_line[rx_line_len++] = c;
            }
        }
    }
#endif

#if TARGET_OS_SIMULATOR
    /* Write all bytes to fd, handling partial writes */
    ssize_t writeAll(const void* buf, size_t len) {
        auto* p = static_cast<const uint8_t*>(buf);
        size_t remaining = len;
        while (remaining > 0) {
            ssize_t n = ::write(fd, p, remaining);
            if (n < 0) {
                if (errno == EINTR) continue;
                return -1;
            }
            p += n;
            remaining -= static_cast<size_t>(n);
        }
        return static_cast<ssize_t>(len);
    }

    /* Read available bytes from serial, accumulate lines, decode frames into FIFO.
     * drain_lock serializes concurrent callers. */
    void drainSerial() {
        if (fd < 0) return;
        std::lock_guard<std::mutex> lock(drain_lock);
        uint8_t tmp[kRxBufSize];
        while (true) {
            ssize_t n = ::read(fd, tmp, sizeof(tmp));
            if (n <= 0) break;
            processRxBytes(tmp, static_cast<uint32_t>(n));
        }
    }
#else
    /* ================================================================
     * Device path: frame ring operations
     * ================================================================ */

    /* Drain structured frames from SharedRingHeader RX ring into FIFO */
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
            if (avail < 2) break;

            // Read entry header: [uint16_t frameSize]
            uint16_t frameSize = static_cast<uint16_t>(
                static_cast<uint32_t>(rxData[tail % cap]) |
                (static_cast<uint32_t>(rxData[(tail + 1) % cap]) << 8));

            uint32_t entrySize = 2 + frameSize;
            if (entrySize > avail) break;  // incomplete entry

            // Validate frame size
            if (frameSize != CAN_MTU && frameSize != CANFD_MTU) {
                tail += entrySize;  // skip invalid entry
                continue;
            }

            // Read frame bytes (handle ring wrap)
            canfd_frame frame;
            memset(&frame, 0, sizeof(canfd_frame));

            if (frameSize == CAN_MTU) {
                uint8_t frameBuf[CAN_MTU];
                for (uint32_t i = 0; i < frameSize; i++) {
                    frameBuf[i] = rxData[(tail + 2 + i) % cap];
                }
                auto* cf = reinterpret_cast<can_frame*>(frameBuf);
                frame.can_id = cf->can_id;
                frame.len = cf->len;
                frame.flags = 0;
                frame.__res0 = cf->__res0;  // preserve channel
                memcpy(frame.data, cf->data, cf->len);
            } else {
                for (uint32_t i = 0; i < frameSize; i++) {
                    reinterpret_cast<uint8_t*>(&frame)[i] = rxData[(tail + 2 + i) % cap];
                }
            }

            // Fan out to all active readers on the matching channel
            int ch = CAN_CHANNEL(frame);
            if (ch < 0 || ch >= kMaxChannels) ch = 0;
            fanOutFrame(frame, ch);
            count++;

            tail += entrySize;
        }

        ring_store_tail_release(&ringHeader->rx, tail);
        return count;
    }

    /* Write a canfd_frame to the TX ring. Returns true on success. */
    bool writeTxFrame(const canfd_frame* frame) {
        if (!ringHeader || ringHeader->magic != SHARED_RING_MAGIC) return false;

        uint16_t frameSize = static_cast<uint16_t>(sizeof(canfd_frame));
        uint32_t entrySize = 2 + frameSize;

        uint32_t head = ring_load_head_relaxed(&ringHeader->tx);
        uint32_t tail = ring_load_tail_acquire(&ringHeader->tx);
        uint32_t cap = ringHeader->txCapacity;
        uint32_t free = cap - (head - tail);

        if (entrySize > free) return false;

        uint8_t* txData = shared_ring_tx_data(ringHeader);

        // Write entry header
        txData[head % cap] = static_cast<uint8_t>(frameSize & 0xFF);
        txData[(head + 1) % cap] = static_cast<uint8_t>(frameSize >> 8);

        // Write frame bytes (handle ring wrap)
        const uint8_t* frameBytes = reinterpret_cast<const uint8_t*>(frame);
        for (uint32_t i = 0; i < frameSize; i++) {
            txData[(head + 2 + i) % cap] = frameBytes[i];
        }

        ring_store_head_release(&ringHeader->tx, head + entrySize);
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
                "CANClient: SharedRingHeader magic=0x%x layout=V%u rxCap=%u txCap=%u",
                ringHeader->magic, ringHeader->layoutVersion,
                ringHeader->rxCapacity, ringHeader->txCapacity);
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
#endif
};

/* ================================================================
 * CANClient — public API delegates to _impl
 * ================================================================ */

CANClient::CANClient() : _impl(std::make_shared<CANClientImpl>()), _channel(0), _readerId(-1) {}

CANClient::~CANClient() {
    if (_readerId >= 0 && _impl)
        _impl->unregisterReader(_readerId);
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

#if TARGET_OS_SIMULATOR
    // POSIX serial — same as before
    static const char* patterns[] = {
        "/dev/cu.SLCAN*",
        "/dev/cu.usbmodem*",
        "/dev/cu.usbserial*",
    };
    static const int kNumPatterns = sizeof(patterns) / sizeof(patterns[0]);

    struct MatchedPath { char path[256]; };
    static constexpr int kMaxDevices = 32;
    MatchedPath matched[kMaxDevices];
    int totalFound = 0;

    for (int p = 0; p < kNumPatterns && totalFound < kMaxDevices; p++) {
        glob_t g = {};
        int rc = glob(patterns[p], 0, nullptr, &g);
        if (rc == 0) {
            for (size_t i = 0; i < g.gl_pathc && totalFound < kMaxDevices; i++) {
                strncpy(matched[totalFound].path, g.gl_pathv[i],
                        sizeof(matched[totalFound].path) - 1);
                matched[totalFound].path[sizeof(matched[totalFound].path) - 1] = '\0';
                totalFound++;
            }
        }
        globfree(&g);
    }

    if (totalFound == 0) {
        c.setError("No serial device found");
        return false;
    }
    if (adapter_index >= totalFound) {
        c.setError("Only %d device(s) found, index %d requested", totalFound, adapter_index);
        return false;
    }

    strncpy(c.device_path, matched[adapter_index].path, sizeof(c.device_path) - 1);

    c.fd = ::open(c.device_path, O_RDWR | O_NOCTTY | O_NONBLOCK);
    if (c.fd < 0) {
        c.setError("Failed to open %s: %s", c.device_path, strerror(errno));
        return false;
    }

    struct termios tio;
    if (tcgetattr(c.fd, &tio) == 0) {
        cfmakeraw(&tio);
        cfsetspeed(&tio, B115200);
        tio.c_cc[VMIN] = 0;
        tio.c_cc[VTIME] = 0;
        tcsetattr(c.fd, TCSANOW, &tio);
    }
    tcflush(c.fd, TCIOFLUSH);

    c.is_connected = true;
    c.clearError();
    return true;

#else
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
                "CANClient: SharedRingHeader OK: rxCap=%u txCap=%u layout=V%u proto=%u",
                c.ringHeader->rxCapacity, c.ringHeader->txCapacity,
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
#endif
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

#if TARGET_OS_SIMULATOR
    int fd = c.fd;
    c.fd = -1;
    c.device_path[0] = '\0';

    if (was_open && fd >= 0) {
        const char cmd[] = "C\r";
        ::write(fd, cmd, 2);
    }
    if (fd >= 0) ::close(fd);
#else
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
#endif

    c.rx_line_len = 0;
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

#if TARGET_OS_SIMULATOR
    if (c.fd < 0) {
        c.setError("Not connected");
        return -1;
    }
    speed_t speed;
    switch (baud_rate) {
        case 9600:    speed = B9600; break;
        case 19200:   speed = B19200; break;
        case 38400:   speed = B38400; break;
        case 57600:   speed = B57600; break;
        case 115200:  speed = B115200; break;
        case 230400:  speed = B230400; break;
        default:      speed = B115200; break;
    }
    struct termios tio;
    if (tcgetattr(c.fd, &tio) < 0) {
        c.setError("tcgetattr failed: %s", strerror(errno));
        return -1;
    }
    cfsetspeed(&tio, speed);
    if (tcsetattr(c.fd, TCSANOW, &tio) < 0) {
        c.setError("tcsetattr failed: %s", strerror(errno));
        return -1;
    }
    return 0;
#else
    uint64_t input[] = { baud_rate };
    kern_return_t kr = IOConnectCallScalarMethod(
        c.connection, kCANDriverMethodSetBaudRate, input, 1, nullptr, nullptr);
    if (kr != KERN_SUCCESS) {
        c.setError("SetBaudRate failed: 0x%x", kr);
        return -1;
    }
    return 0;
#endif
}

int CANClient::openChannel(uint32_t bitrate) {
    auto& c = *_impl;
    if (!c.is_connected) {
        c.setError("Not connected");
        return -1;
    }

#if TARGET_OS_SIMULATOR
    // Simulator: SLCAN text commands via POSIX serial
    char code = slcan_bitrate_to_code(bitrate);
    if (code == 0) {
        c.setError("Unsupported CAN bitrate: %u", bitrate);
        return -1;
    }

    char initCmd[16];
    int cmdLen = snprintf(initCmd, sizeof(initCmd), "C\rS%c\rO\r", code);

    if (c.fd < 0) return -1;
    if (c.writeAll(initCmd, cmdLen) < 0) {
        c.setError("Failed to send init commands: %s", strerror(errno));
        return -1;
    }
#else
    // Device: codec-based channel open via IPC (bitrate + channel)
    uint64_t input[] = { bitrate, static_cast<uint64_t>(_channel) };
    kern_return_t kr = IOConnectCallScalarMethod(
        c.connection, kCANDriverMethodOpenChannel, input, 2, nullptr, nullptr);
    if (kr != KERN_SUCCESS) {
        c.setError("OpenChannel failed: 0x%x", kr);
        return -1;
    }
#endif

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
    c.rx_line_len = 0;
#if TARGET_OS_SIMULATOR
    tcflush(c.fd, TCIFLUSH);
#endif

    c.clearError();
    return 0;
}

int CANClient::closeChannel() {
    auto& c = *_impl;

    {
        std::lock_guard<std::mutex> lock(c.io_lock);
        c.is_open = false;
    }

#if TARGET_OS_SIMULATOR
    if (c.fd >= 0) c.writeAll("C\r", 2);
#else
    if (c.connection) {
        uint64_t input[] = { static_cast<uint64_t>(_channel) };
        IOConnectCallScalarMethod(c.connection, kCANDriverMethodCloseChannel,
                                   input, 1, nullptr, nullptr);
    }
#endif
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

#if TARGET_OS_SIMULATOR
    char buf[256];
    uint32_t len = slcan_encode(&fd_frame, buf, sizeof(buf));
    if (len == 0) return 0;
    if (c.fd < 0) return 0;
    ssize_t written = c.writeAll(buf, len);
    return (written > 0) ? 1 : 0;
#else
    if (!c.writeTxFrame(&fd_frame)) return 0;
    c.triggerTxDrain();
    return 1;
#endif
}

int CANClient::write(const struct canfd_frame* frame) {
    if (!frame) return 0;
    auto& c = *_impl;

    // Tag channel on outgoing frame
    canfd_frame tagged = *frame;
    CAN_CHANNEL(tagged) = static_cast<uint8_t>(_channel);

#if TARGET_OS_SIMULATOR
    char buf[256];
    uint32_t len = slcan_encode(&tagged, buf, sizeof(buf));
    if (len == 0) return 0;
    if (c.fd < 0) return 0;
    ssize_t written = c.writeAll(buf, len);
    return (written > 0) ? 1 : 0;
#else
    if (!c.writeTxFrame(&tagged)) return 0;
    c.triggerTxDrain();
    return 1;
#endif
}

/* ---- Frame read ---- */

int CANClient::read(struct canfd_frame* frame) {
    if (!frame) return 0;
    ensureReader();
    auto& c = *_impl;

#if TARGET_OS_SIMULATOR
    c.drainSerial();
#else
    c.drainIOKit();
#endif
    return c.readFrameFromReader(_readerId, frame);
}

int CANClient::readMany(struct canfd_frame* frames, int max_frames) {
    if (!frames || max_frames <= 0) return 0;
    ensureReader();
    auto& c = *_impl;

#if TARGET_OS_SIMULATOR
    c.drainSerial();
#else
    c.drainIOKit();
#endif

    int count = 0;
    for (int i = 0; i < max_frames; i++) {
        if (c.readFrameFromReader(_readerId, &frames[i]) != 1) break;
        count++;
    }
    return count;
}

int CANClient::readManyBlocking(struct canfd_frame* frames, int max_frames, uint32_t timeoutMs) {
    if (!frames || max_frames <= 0) return 0;
    ensureReader();
    auto& c = *_impl;

#if TARGET_OS_SIMULATOR
    c.drainSerial();
    if (c.readerEmpty(_readerId) && timeoutMs > 0 && c.fd >= 0) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(c.fd, &rfds);
        struct timeval tv;
        tv.tv_sec = timeoutMs / 1000;
        tv.tv_usec = (timeoutMs % 1000) * 1000;
        select(c.fd + 1, &rfds, nullptr, nullptr, &tv);
        c.drainSerial();
    }
#else
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
#endif

    int count = 0;
    for (int i = 0; i < max_frames; i++) {
        if (c.readFrameFromReader(_readerId, &frames[i]) != 1) break;
        count++;
    }
    return count;
}

int CANClient::sendRaw(const void* data, int len) {
    if (!data || len <= 0) return 0;
    auto& c = *_impl;

#if TARGET_OS_SIMULATOR
    if (c.fd < 0) return 0;
    ssize_t written = c.writeAll(data, static_cast<size_t>(len));
    return (written > 0) ? static_cast<int>(written) : 0;
#else
    return c.sendBytes(data, static_cast<uint32_t>(len));
#endif
}

const char* CANClient::lastError() const {
    auto& c = *_impl;
    std::lock_guard<std::mutex> lock(c.io_lock);
    return c.last_error;
}

uint32_t CANClient::dropCount() const {
#if TARGET_OS_SIMULATOR
    return 0;
#else
    auto& c = *_impl;
    if (c.ringHeader && c.ringHeader->magic == SHARED_RING_MAGIC)
        return c.ringHeader->rxDropped;
    return 0;
#endif
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
