/*
 * driver_types.h
 * Shared constants, enums, and types for the USBCANDriver modules.
 */

#pragma once

#include <os/log.h>
#include <DriverKit/IOReturn.h>
#include <concepts>
#include <cstdint>

// Forward declarations for concept constraints
class IOUSBHostDevice;
class IOService;
struct SharedRingHeader;
struct canfd_frame;

// --- Logging ---

#define LOG_PREFIX "USBCANDriver: "
#define DEXT_LOG(fmt, ...) os_log(OS_LOG_DEFAULT, LOG_PREFIX fmt, ##__VA_ARGS__)

// --- Buffer sizes ---

#define TX_BUFFER_SIZE      4096
#define RX_RING_SIZE        16       // slots in MemoryDescriptorRing (kIOUSBHostPipeBundlingMax)
#define RX_SLOT_SIZE        128      // bytes per slot (USB 2.0 FS max packet = 64)
#define SLCAN_ENCODE_BUF    256      // worst case: 'D' + 8-char ID + 1 DLC + 128 hex + '\r'
#define TX_POLL_INTERVAL_NS 250000ULL  // 0.25ms

// --- RX slot state machine: FREE → INFLIGHT → READY → FREE ---

enum RxSlotState : uint8_t {
    kRxSlotFree     = 0,
    kRxSlotInflight = 1,
    kRxSlotReady    = 2,
};

// --- USB CDC Class Request Codes ---

enum CDCRequestCode {
    kSetLineCoding          = 0x20,
    kGetLineCoding          = 0x21,
    kSetControlLineState    = 0x22,
    kSendBreak              = 0x23
};

// --- USB CDC Line Coding Structure (7 bytes per spec) ---

struct LineCoding {
    uint32_t dwDTERate;     // Baud rate
    uint8_t  bCharFormat;   // Stop bits: 0=1, 1=1.5, 2=2
    uint8_t  bParityType;   // Parity: 0=None, 1=Odd, 2=Even, 3=Mark, 4=Space
    uint8_t  bDataBits;     // Data bits: 5, 6, 7, 8, or 16
} __attribute__((packed));

// --- CanProtocol concept: compile-time interface for protocol codecs ---
// Every codec in std::variant<slcan::Codec, gsusb::Codec, ...> must satisfy this.
// Adding a new protocol that doesn't implement all methods causes a compile error
// at the static_assert in the codec header (not buried in std::visit expansions).

// SendFn type used in concept constraints: (const uint8_t* data, uint32_t len) -> kern_return_t
using ConceptSendFn = kern_return_t(*)(const uint8_t*, uint32_t);

template <typename T>
concept CanProtocol = requires(T& c, const T& cc,
                               IOUSBHostDevice* dev, IOService* client,
                               uint32_t bitrate, uint8_t channel, uint64_t now,
                               const uint8_t* data, uint32_t len,
                               SharedRingHeader* hdr, bool txInFlight,
                               ConceptSendFn sendFn) {
    // Lifecycle
    { c.configureDevice(dev, client) } -> std::same_as<kern_return_t>;
    { c.openChannel(dev, client, bitrate, channel, sendFn) } -> std::same_as<kern_return_t>;
    { c.closeChannel(dev, client, channel, sendFn) } -> std::same_as<kern_return_t>;
    { c.onStopIO(dev, client) };
    { c.onTimer(now) };

    // TX drain: reads frames from ring, encodes, sends via callback
    { c.drainTx(hdr, data, txInFlight, sendFn) } -> std::same_as<kern_return_t>;

    // RX processing: decodes USB bytes, calls onFrame for each valid CAN frame
    { c.processRxData(data, len, [](const canfd_frame&) {}) };

    // After processRxData, check if TX drain is needed (gs_usb echo flow)
    { cc.needsDrainTx() } -> std::convertible_to<bool>;

    // Metadata
    { cc.needsCDC() } -> std::convertible_to<bool>;
    { cc.name() } -> std::convertible_to<const char*>;
    { cc.protocolId() } -> std::convertible_to<uint8_t>;

    // Diagnostics: write protocol-specific stats into buffer, return bytes written
    { cc.diagLine(data, len) } -> std::same_as<uint32_t>;
};
