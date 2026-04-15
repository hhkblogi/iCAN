use std::ffi::c_char;

use can_schema::{SchemaState, SchemaStatus};

const CAN_EFF_FLAG: u32 = 0x8000_0000;
const CAN_RTR_FLAG: u32 = 0x4000_0000;
const CAN_ERR_FLAG: u32 = 0x2000_0000;
const CAN_SFF_MASK: u32 = 0x0000_07ff;
const CAN_EFF_MASK: u32 = 0x1fff_ffff;
const CANFD_MAX_DLEN: usize = 64;

#[repr(C)]
pub struct ican_schema_t {
    state: SchemaState,
}

#[repr(C)]
pub struct ican_schema_decoded_signal_t {
    pub name_ptr: *const c_char,
    pub name_len: usize,
    pub value: f64,
    pub unit_ptr: *const c_char,
    pub unit_len: usize,
    pub display_value_ptr: *const c_char,
    pub display_value_len: usize,
}

#[repr(C)]
pub struct ican_schema_decoded_message_t {
    pub matched: bool,
    pub message_name_ptr: *const c_char,
    pub message_name_len: usize,
    pub signal_count: usize,
}

#[repr(C)]
pub struct canfd_frame {
    pub can_id: u32,
    pub len: u8,
    pub flags: u8,
    pub __res0: u8,
    pub __res1: u8,
    pub data: [u8; 64],
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
    signal_capacity: usize,
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
    if (raw_id & (CAN_RTR_FLAG | CAN_ERR_FLAG)) != 0 {
        schema
            .state
            .set_last_error("RTR and error CAN frames are not decodable");
        return status_to_ffi(SchemaStatus::InvalidArgument);
    }

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

    let payload = unsafe {
        let data = &(*frame).data;
        &data[..payload_len]
    };
    if payload_len < usize::from(message.dlc()) {
        schema.state.set_last_error("frame payload shorter than DBC message DLC");
        return status_to_ffi(SchemaStatus::InvalidArgument);
    }

    let mut active_signal_count = 0usize;
    for index in 0..message.signal_count() {
        match message.is_signal_active(index, payload) {
            Some(true) => active_signal_count += 1,
            Some(false) => {}
            None => {
                schema.state.set_last_error("failed to resolve multiplexed signal visibility");
                return status_to_ffi(SchemaStatus::InvalidArgument);
            }
        }
    }

    unsafe {
        (*out_message).matched = true;
        (*out_message).message_name_ptr = message.name().as_ptr().cast();
        (*out_message).message_name_len = message.name().len();
        (*out_message).signal_count = active_signal_count;
        *out_signal_count = active_signal_count;
    }

    if active_signal_count > 0 && out_signals.is_null() {
        if signal_capacity == 0 {
            schema.state.set_last_error("decoded signal buffer is too small");
            return status_to_ffi(SchemaStatus::BufferTooSmall);
        }
        schema.state.set_last_error("decoded signal buffer pointer is null");
        return status_to_ffi(SchemaStatus::InvalidArgument);
    }

    if active_signal_count > signal_capacity {
        schema.state.set_last_error("decoded signal buffer is too small");
        return status_to_ffi(SchemaStatus::BufferTooSmall);
    }

    let mut out_index = 0usize;
    for index in 0..message.signal_count() {
        if !message
            .is_signal_active(index, payload)
            .expect("multiplex visibility should have been validated")
        {
            continue;
        }

        let signal = message.signal(index).expect("runtime message signal range should stay valid");
        let decoded = match message.decode_signal_value(index, payload) {
            Some(decoded) => decoded,
            None => {
                schema.state.set_last_error("failed to decode signal from payload");
                return status_to_ffi(SchemaStatus::InvalidArgument);
            }
        };
        let display_value = signal.display_label_for_raw(decoded.raw_unsigned, decoded.raw_signed);

        unsafe {
            (*out_signals.add(out_index)).name_ptr = signal.name().as_ptr().cast();
            (*out_signals.add(out_index)).name_len = signal.name().len();
            (*out_signals.add(out_index)).value = decoded.engineering_value;
            if let Some(unit) = signal.unit() {
                (*out_signals.add(out_index)).unit_ptr = unit.as_ptr().cast();
                (*out_signals.add(out_index)).unit_len = unit.len();
            } else {
                (*out_signals.add(out_index)).unit_ptr = std::ptr::null();
                (*out_signals.add(out_index)).unit_len = 0;
            }
            if let Some(display_value) = display_value {
                (*out_signals.add(out_index)).display_value_ptr = display_value.as_ptr().cast();
                (*out_signals.add(out_index)).display_value_len = display_value.len();
            } else {
                (*out_signals.add(out_index)).display_value_ptr = std::ptr::null();
                (*out_signals.add(out_index)).display_value_len = 0;
            }
        }
        out_index += 1;
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
