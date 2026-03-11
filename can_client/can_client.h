/*
 * can_client.h — SocketCAN-inspired C++ client library
 *
 * IOKit IPC to DriverKit driver (IOService + IOUserClient + SharedRingHeader).
 * Protocol-agnostic: driver handles encoding/decoding, client sends/receives frames.
 * Pimpl pattern hides internals from Swift interop.
 *
 * On device: IOKit matching + ExternalMethod(SendData) + SharedRingHeader(RX via mmap)
 * On simulator: POSIX serial I/O to /dev/cu.usbmodem*
 *
 * Return convention: 0 = success, negative = error (POSIX-style).
 * write/writeClassic return 0/1 (frames written). readMany returns count.
 */

#ifndef CANClient_hpp
#define CANClient_hpp

#include "protocol/can.h"
#include <cstdint>
#include <memory>
#include <swift/bridging>

class CANClientImpl;

class CANClient {
public:
    CANClient();
    ~CANClient();

    // Copyable (shared_ptr); new copy gets its own reader slot on first read
    CANClient(const CANClient&);
    CANClient& operator=(const CANClient&);

    // Movable — transfers reader slot ownership
    CANClient(CANClient&&) noexcept;
    CANClient& operator=(CANClient&&) noexcept;

    // --- Lifecycle (analogous to socket + bind + close) ---

    // Find and open the CAN adapter.
    // On device: IOKit service matching + IOServiceOpen
    // On simulator: POSIX serial to /dev/cu.usbmodem*
    // Returns true on success.
    bool open(int adapter_index = 0);

    // Set the CAN channel for this client instance (0 or 1 for PCAN dual-channel).
    // Must be called before openChannel(). Copies of CANClient share the connection
    // but can have independent channels.
    void setChannel(int channel);

    // Close the connection.
    void close();

    // --- Channel control (analogous to setsockopt + ifconfig up/down) ---

    // Combined: set CAN bitrate + open CAN channel via SLCAN commands.
    int start(uint32_t bitrate);

    // Combined: close CAN channel via SLCAN command.
    int stop();

    // Individual channel operations (finer control)
    int openSerial();
    int closeSerial();
    int setBaudRate(uint32_t baud_rate);
    int openChannel(uint32_t bitrate);
    int closeChannel();

    // --- Data (analogous to read/write on a CAN socket) ---

    // Write one classic CAN frame.
    // Returns 1 on success, 0 on failure.
    int writeClassic(const struct can_frame* frame);

    // Write one CAN FD frame.
    // Returns 1 on success, 0 on failure.
    int write(const struct canfd_frame* frame);

    // Read one CAN FD frame (non-blocking).
    // Returns 1 on success (frame filled), 0 if no data.
    int read(struct canfd_frame* frame);

    // Read up to max_frames (non-blocking batch).
    // Returns number of frames read (0 if empty).
    int readMany(struct canfd_frame* frames, int max_frames);

    // Read up to max_frames, blocking up to timeoutMs if none available.
    // On device: uses async completion (WaitForData) to sleep efficiently.
    // Returns number of frames read (0 if timeout with no data).
    int readManyBlocking(struct canfd_frame* frames, int max_frames, uint32_t timeoutMs);

    // --- Raw serial I/O (for SLCAN control commands) ---

    // Send raw bytes to driver.
    // Returns number of bytes sent, 0 on failure.
    int sendRaw(const void* data, int len);

    // --- Diagnostics ---

    const char* lastError() const SWIFT_RETURNS_INDEPENDENT_VALUE;

    // Driver-side drop count from SharedRingHeader (ring-full events).
    // Returns 0 when not connected or ring not mapped.
    uint32_t dropCount() const;

    // --- State queries ---

    bool isConnected() const;
    bool isOpen() const;

private:
    void ensureReader();

    std::shared_ptr<CANClientImpl> _impl;
    int _channel = 0;   // per-copy channel (copies share connection, not channel)
    int _readerId = -1;  // per-copy reader slot index (-1 = not yet registered)
};

#endif /* CANClient_hpp */
