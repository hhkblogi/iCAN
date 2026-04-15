#include "can_schema.h"

#include <cstdio>
#include <utility>

namespace {

constexpr const char* kCreateFailure = "failed to create can_schema handle";
constexpr const char* kNoSchemaLoaded = "schema is not loaded";

}  // namespace

CANSchema::CANSchema() = default;

CANSchema::~CANSchema() {
    clearHandle();
}

CANSchema::CANSchema(CANSchema&& other) noexcept
    : handle_(other.handle_) {
    std::memcpy(fallback_error_, other.fallback_error_, sizeof(fallback_error_));
    other.handle_ = nullptr;
    other.fallback_error_[0] = '\0';
}

CANSchema& CANSchema::operator=(CANSchema&& other) noexcept {
    if (this == &other) {
        return *this;
    }

    clearHandle();
    handle_ = other.handle_;
    std::memcpy(fallback_error_, other.fallback_error_, sizeof(fallback_error_));
    other.handle_ = nullptr;
    other.fallback_error_[0] = '\0';
    return *this;
}

bool CANSchema::loadDBCText(const uint8_t* text, size_t length) {
    clearHandle();

    if (text == nullptr || length == 0) {
        setFallbackError(kCreateFailure);
        return false;
    }

    ican_schema_t* next = ican_schema_create_from_dbc_text(text, length);
    if (next == nullptr) {
        setFallbackError(kCreateFailure);
        return false;
    }

    handle_ = next;
    fallback_error_[0] = '\0';
    return true;
}

int32_t CANSchema::decode(
    const struct canfd_frame& frame,
    CANSchemaDecodedMessage* outMessage,
    CANSchemaDecodedSignal* outSignals,
    size_t signalCapacity,
    size_t* outSignalCount
) const {
    if (outMessage == nullptr || outSignalCount == nullptr) {
        return static_cast<int32_t>(ICAN_SCHEMA_STATUS_INVALID_ARGUMENT);
    }

    if (handle_ == nullptr) {
        outMessage->matched = false;
        outMessage->messageName = nullptr;
        outMessage->messageNameLength = 0;
        outMessage->signalCount = 0;
        *outSignalCount = 0;
        setFallbackError(kNoSchemaLoaded);
        return static_cast<int32_t>(ICAN_SCHEMA_STATUS_NOT_READY);
    }

    ican_schema_decoded_message_t message = {};
    const ican_schema_status_t status = ican_schema_decode_frame_into(
        handle_,
        &frame,
        &message,
        reinterpret_cast<ican_schema_decoded_signal_t*>(outSignals),
        signalCapacity,
        outSignalCount
    );

    outMessage->matched = message.matched;
    outMessage->messageName = message.message_name_ptr;
    outMessage->messageNameLength = message.message_name_len;
    outMessage->signalCount = message.signal_count;

    if (status != ICAN_SCHEMA_STATUS_OK || outSignals == nullptr) {
        return static_cast<int32_t>(status);
    }

    for (size_t i = 0; i < *outSignalCount; ++i) {
        auto* raw = reinterpret_cast<ican_schema_decoded_signal_t*>(&outSignals[i]);
        outSignals[i].name = raw->name_ptr;
        outSignals[i].nameLength = raw->name_len;
        outSignals[i].value = raw->value;
        outSignals[i].unit = raw->unit_ptr;
        outSignals[i].unitLength = raw->unit_len;
        outSignals[i].displayValue = raw->display_value_ptr;
        outSignals[i].displayValueLength = raw->display_value_len;
    }

    return static_cast<int32_t>(status);
}

bool CANSchema::hasSchema() const {
    return handle_ != nullptr && ican_schema_has_schema(handle_);
}

const char* CANSchema::lastError() const {
    if (handle_ != nullptr) {
        const char* err = ican_schema_last_error(handle_);
        if (err != nullptr && err[0] != '\0') {
            return err;
        }
    }

    return fallback_error_;
}

void CANSchema::clearHandle() {
    if (handle_ != nullptr) {
        ican_schema_destroy(handle_);
        handle_ = nullptr;
    }
}

void CANSchema::setFallbackError(const char* message) const {
    std::snprintf(fallback_error_, sizeof(fallback_error_), "%s", message);
}
