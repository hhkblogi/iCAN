#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "../../protocol/can.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ican_schema_t ican_schema_t;

typedef enum ican_schema_status_t {
    ICAN_SCHEMA_STATUS_OK = 0,
    ICAN_SCHEMA_STATUS_INVALID_ARGUMENT = 1,
    ICAN_SCHEMA_STATUS_LOAD_ERROR = 2,
    ICAN_SCHEMA_STATUS_NOT_READY = 3,
    ICAN_SCHEMA_STATUS_NO_MATCH = 4,
    ICAN_SCHEMA_STATUS_BUFFER_TOO_SMALL = 5,
    ICAN_SCHEMA_STATUS_UNIMPLEMENTED = 6,
} ican_schema_status_t;

typedef struct ican_schema_decoded_signal_t {
    const char* name_ptr;
    size_t name_len;
    double value;
    const char* unit_ptr;
    size_t unit_len;
    const char* display_value_ptr;
    size_t display_value_len;
} ican_schema_decoded_signal_t;

typedef struct ican_schema_decoded_message_t {
    bool matched;
    const char* message_name_ptr;
    size_t message_name_len;
    size_t signal_count;
} ican_schema_decoded_message_t;

ican_schema_t* ican_schema_create_from_dbc_text(const uint8_t* text, size_t len);
void ican_schema_destroy(ican_schema_t* schema);

ican_schema_status_t ican_schema_decode_frame_into(
    const ican_schema_t* schema,
    const struct canfd_frame* frame,
    ican_schema_decoded_message_t* out_message,
    ican_schema_decoded_signal_t* out_signals,
    size_t signal_capacity,
    size_t* out_signal_count
);

const char* ican_schema_last_error(const ican_schema_t* schema);
bool ican_schema_has_schema(const ican_schema_t* schema);

#ifdef __cplusplus
}  // extern "C"
#endif
