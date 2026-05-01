#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

#include <swift/bridging>

#include "../include/can_schema_ffi.h"

struct CANSchemaDecodedSignal {
    const char* name = nullptr;
    size_t nameLength = 0;
    double value = 0.0;
    const char* unit = nullptr;
    size_t unitLength = 0;
    const char* displayValue = nullptr;
    size_t displayValueLength = 0;
};

struct CANSchemaDecodedMessage {
    bool matched = false;
    const char* messageName = nullptr;
    size_t messageNameLength = 0;
    size_t signalCount = 0;
};

class CANSchema {
public:
    CANSchema();
    ~CANSchema();

    CANSchema(const CANSchema&) = delete;
    CANSchema& operator=(const CANSchema&) = delete;

    CANSchema(CANSchema&& other) noexcept;
    CANSchema& operator=(CANSchema&& other) noexcept;

    bool loadDBCText(const uint8_t* text, size_t length);
    bool loadDBCText(const char* text) {
        return loadDBCText(reinterpret_cast<const uint8_t*>(text), text ? std::strlen(text) : 0);
    }

    int32_t decode(
        const struct canfd_frame& frame,
        CANSchemaDecodedMessage* outMessage,
        CANSchemaDecodedSignal* outSignals,
        size_t signalCapacity,
        size_t* outSignalCount
    ) const;

    bool hasSchema() const;
    const char* lastError() const SWIFT_RETURNS_INDEPENDENT_VALUE;

private:
    void clearHandle();
    void setFallbackError(const char* message) const;

    ican_schema_t* handle_ = nullptr;
    mutable char fallback_error_[256] = {};
};
