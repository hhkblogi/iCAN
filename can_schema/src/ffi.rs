use std::ffi::c_char;

use can_schema::{SchemaState, SchemaStatus};

const CAN_EFF_FLAG: u32 = 0x8000_0000;
const CAN_SFF_MASK: u32 = 0x0000_07ff;
const CAN_EFF_MASK: u32 = 0x1fff_ffff;
const CANFD_MAX_DLEN: usize = 64;

#[repr(C)]
pub struct ican_schema_t {
    state: SchemaState,
}

#[repr(C)]
pub struct ican_schema_decoded_signal_t {
    name_ptr: *const c_char,
    name_len: usize,
    value: f64,
    unit_ptr: *const c_char,
    unit_len: usize,
    display_value_ptr: *const c_char,
    display_value_len: usize,
}

#[repr(C)]
pub struct ican_schema_decoded_message_t {
    matched: bool,
    message_name_ptr: *const c_char,
    message_name_len: usize,
    signal_count: usize,
}

#[repr(C)]
pub struct canfd_frame {
    can_id: u32,
    len: u8,
    flags: u8,
    __res0: u8,
    __res1: u8,
    data: [u8; 64],
}

fn status_to_ffi(status: SchemaStatus) -> i32 {
    status as i32
}

fn clear_message(out_message: *mut ican_schema_decoded_message_t) {
    unsafe {
        (*out_message).matched = false;
        (*out_message).message_name_ptr = std::ptr::null();
        (*out_message).message_name_len = 0;
        (*out_message).signal_count = 0;
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ican_schema_create_from_dbc_text(
    text: *const u8,
    len: usize,
) -> *mut ican_schema_t {
    if text.is_null() {
        return std::ptr::null_mut();
    }

    let bytes = unsafe { std::slice::from_raw_parts(text, len) };
    let state = match SchemaState::load_dbc_text(bytes) {
        Ok(state) => state,
        Err(_) => return std::ptr::null_mut(),
    };

    Box::into_raw(Box::new(ican_schema_t { state }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ican_schema_destroy(schema: *mut ican_schema_t) {
    if schema.is_null() {
        return;
    }

    let _ = unsafe { Box::from_raw(schema) };
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ican_schema_decode_frame_into(
    schema: *const ican_schema_t,
    frame: *const canfd_frame,
    out_message: *mut ican_schema_decoded_message_t,
    out_signals: *mut ican_schema_decoded_signal_t,
    _signal_capacity: usize,
    out_signal_count: *mut usize,
) -> i32 {
    if schema.is_null() || frame.is_null() || out_message.is_null() || out_signal_count.is_null() {
        return status_to_ffi(SchemaStatus::InvalidArgument);
    }

    let schema = unsafe { &mut *(schema as *mut ican_schema_t) };
    if !schema.state.has_schema() {
        schema.state.set_last_error("schema is not loaded");
        return status_to_ffi(SchemaStatus::NotReady);
    }

    clear_message(out_message);
    unsafe { *out_signal_count = 0; }

    let payload_len = usize::from(unsafe { (*frame).len });
    if payload_len > CANFD_MAX_DLEN {
        schema.state.set_last_error("frame length exceeds CAN FD maximum");
        return status_to_ffi(SchemaStatus::InvalidArgument);
    }

    let raw_id = unsafe { (*frame).can_id };
    let is_extended = (raw_id & CAN_EFF_FLAG) != 0;
    let frame_id = if is_extended {
        raw_id & CAN_EFF_MASK
    } else {
        raw_id & CAN_SFF_MASK
    };

    let message = match schema.state.find_message(frame_id, is_extended) {
        Some(message) => message,
        None => {
            schema.state.clear_last_error();
            return status_to_ffi(SchemaStatus::NoMatch);
        }
    };

    let signal_count = message.signals().len();
    unsafe {
        (*out_message).matched = true;
        (*out_message).message_name_ptr = message.name().as_ptr().cast();
        (*out_message).message_name_len = message.name().len();
        (*out_message).signal_count = signal_count;
        *out_signal_count = signal_count;
    }

    if signal_count > 0 && out_signals.is_null() {
        if _signal_capacity == 0 {
            schema.state.set_last_error("decoded signal buffer is too small");
            return status_to_ffi(SchemaStatus::BufferTooSmall);
        }
        schema.state.set_last_error("decoded signal buffer pointer is null");
        return status_to_ffi(SchemaStatus::InvalidArgument);
    }

    if signal_count > _signal_capacity {
        schema.state.set_last_error("decoded signal buffer is too small");
        return status_to_ffi(SchemaStatus::BufferTooSmall);
    }

    let payload = unsafe {
        let data = &(*frame).data;
        &data[..payload_len]
    };
    if signal_count > 0 && payload_len < usize::from(message.dlc()) {
        schema.state.set_last_error("frame payload shorter than DBC message DLC");
        return status_to_ffi(SchemaStatus::InvalidArgument);
    }

    for index in 0..signal_count {
        let signal = &message.signals()[index];
        let value = match message.decode_signal(index, payload) {
            Some(value) => value,
            None => {
                schema.state.set_last_error("failed to decode signal from payload");
                return status_to_ffi(SchemaStatus::InvalidArgument);
            }
        };

        unsafe {
            (*out_signals.add(index)).name_ptr = signal.name().as_ptr().cast();
            (*out_signals.add(index)).name_len = signal.name().len();
            (*out_signals.add(index)).value = value;
            if let Some(unit) = signal.unit() {
                (*out_signals.add(index)).unit_ptr = unit.as_ptr().cast();
                (*out_signals.add(index)).unit_len = unit.len();
            } else {
                (*out_signals.add(index)).unit_ptr = std::ptr::null();
                (*out_signals.add(index)).unit_len = 0;
            }
            (*out_signals.add(index)).display_value_ptr = std::ptr::null();
            (*out_signals.add(index)).display_value_len = 0;
        }
    }

    schema.state.clear_last_error();
    status_to_ffi(SchemaStatus::Ok)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ican_schema_last_error(schema: *const ican_schema_t) -> *const c_char {
    if schema.is_null() {
        return std::ptr::null();
    }

    let schema = unsafe { &*schema };
    schema.state.last_error().as_ptr()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn ican_schema_has_schema(schema: *const ican_schema_t) -> bool {
    if schema.is_null() {
        return false;
    }

    let schema = unsafe { &*schema };
    schema.state.has_schema()
}
