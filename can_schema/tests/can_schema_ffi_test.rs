extern crate can_schema;

use std::ffi::CStr;
use std::fs;
use std::ptr;

#[path = "../src/ffi.rs"]
mod ffi;

fn load_fixture_dbc() -> String {
    let test_srcdir = std::env::var("TEST_SRCDIR").unwrap_or_default();
    let test_workspace = std::env::var("TEST_WORKSPACE").unwrap_or_default();
    let candidates = [
        format!("{}/_main/can_schema/testdata/demo.dbc", test_srcdir),
        format!("{}/{}/can_schema/testdata/demo.dbc", test_srcdir, test_workspace),
    ];

    for path in candidates {
        if path.is_empty() {
            continue;
        }

        if let Ok(text) = fs::read_to_string(&path) {
            return text;
        }
    }

    panic!("failed to resolve can_schema/testdata/demo.dbc from Bazel runfiles");
}

unsafe fn load_schema() -> *mut ffi::ican_schema_t {
    let dbc = load_fixture_dbc();
    let schema = unsafe { ffi::ican_schema_create_from_dbc_text(dbc.as_ptr(), dbc.len()) };
    assert!(!schema.is_null());
    schema
}

unsafe fn last_error(schema: *const ffi::ican_schema_t) -> String {
    let error = unsafe { ffi::ican_schema_last_error(schema) };
    assert!(!error.is_null());
    unsafe { CStr::from_ptr(error) }
        .to_str()
        .expect("error should be valid UTF-8")
        .to_owned()
}

#[test]
fn ffi_decode_null_signal_buffer_probe_reports_required_count() {
    let schema = unsafe { load_schema() };

    let mut frame = ffi::canfd_frame {
        can_id: 291,
        len: 8,
        flags: 0,
        __res0: 0,
        __res1: 0,
        data: [0; 64],
    };
    frame.data[0] = 0x34;
    frame.data[1] = 0x12;
    frame.data[2] = 100;

    let mut message: ffi::ican_schema_decoded_message_t = unsafe { std::mem::zeroed() };
    let mut signal_count = 99usize;

    let status = unsafe {
        ffi::ican_schema_decode_frame_into(
            schema,
            &frame,
            &mut message,
            ptr::null_mut(),
            0,
            &mut signal_count,
        )
    };

    assert_eq!(status, can_schema::SchemaStatus::BufferTooSmall as i32);
    assert!(message.matched);
    assert_eq!(signal_count, 2);
    assert_eq!(unsafe { last_error(schema) }, "decoded signal buffer is too small");

    unsafe { ffi::ican_schema_destroy(schema) };
}

#[test]
fn ffi_rejects_remote_and_error_frames_before_lookup() {
    let schema = unsafe { load_schema() };

    for flag in [0x4000_0000u32, 0x2000_0000u32] {
        let mut frame = ffi::canfd_frame {
            can_id: flag | 291,
            len: 8,
            flags: 0,
            __res0: 0,
            __res1: 0,
            data: [0; 64],
        };
        frame.data[0] = 0x34;
        frame.data[1] = 0x12;
        frame.data[2] = 100;

        let mut message: ffi::ican_schema_decoded_message_t = unsafe { std::mem::zeroed() };
        let mut signals: [ffi::ican_schema_decoded_signal_t; 2] = unsafe { std::mem::zeroed() };
        let mut signal_count = 99usize;

        let status = unsafe {
            ffi::ican_schema_decode_frame_into(
                schema,
                &frame,
                &mut message,
                signals.as_mut_ptr(),
                signals.len(),
                &mut signal_count,
            )
        };

        assert_eq!(status, can_schema::SchemaStatus::InvalidArgument as i32);
        assert!(!message.matched);
        assert_eq!(signal_count, 0);
        assert_eq!(
            unsafe { last_error(schema) },
            "RTR and error CAN frames are not decodable"
        );
    }

    unsafe { ffi::ican_schema_destroy(schema) };
}
