extern crate can_schema;

use std::fs;

use can_schema::{ByteOrder, MuxRoleIr, SchemaIr, SchemaState};

const DUPLICATE_MESSAGE_DBC: &str = r#"VERSION "1.0"

NS_ :

BS_:

BU_: ECM

BO_ 291 DemoA : 8 ECM
 SG_ Speed : 0|16@1+ (1,0) [0|65535] "km/h" ECM

BO_ 291 DemoB : 8 ECM
 SG_ Temp : 0|8@1+ (1,0) [0|255] "C" ECM
"#;

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

fn load_fixture() -> SchemaState {
    let dbc = load_fixture_dbc();
    SchemaState::load_dbc_text(dbc.as_bytes()).expect("fixture DBC should load")
}

#[test]
fn rejects_empty_dbc_text() {
    let result = SchemaState::load_dbc_text(b"");
    assert!(result.is_err());
}

#[test]
fn supports_basic_multiplexed_signal_definitions() {
    let schema = load_fixture();
    let muxed = schema
        .schema_ir()
        .messages
        .iter()
        .find(|message| message.name == "MultiStatus")
        .expect("MultiStatus should be present");

    assert_eq!(muxed.signals.len(), 3);
    assert_eq!(muxed.signals[0].mux_role, MuxRoleIr::Multiplexor);
    assert_eq!(
        muxed.signals[1].mux_role,
        MuxRoleIr::Multiplexed { selector_value: 0 }
    );
    assert_eq!(
        muxed.signals[2].mux_role,
        MuxRoleIr::Multiplexed { selector_value: 1 }
    );
}

#[test]
fn rejects_duplicate_message_ids_during_runtime_compile() {
    let result = SchemaState::load_dbc_text(DUPLICATE_MESSAGE_DBC.as_bytes());
    assert!(result.is_err());
}

#[test]
fn parses_fixture_file_into_ir() {
    let dbc = load_fixture_dbc();
    let schema_ir = SchemaIr::parse_dbc(&dbc).expect("fixture DBC should parse");

    assert_eq!(schema_ir.messages.len(), 5);
    assert_eq!(schema_ir.messages[0].name, "Demo");
    assert_eq!(schema_ir.messages[0].signals.len(), 2);
    assert_eq!(schema_ir.messages[0].signals[0].byte_order, ByteOrder::LittleEndian);
    assert_eq!(schema_ir.messages[1].name, "Battery");
    assert_eq!(schema_ir.messages[2].name, "ExtStatus");
    assert!(schema_ir.messages[2].is_extended);
    assert_eq!(schema_ir.messages[2].signals[0].choices.len(), 2);
    assert_eq!(schema_ir.messages[3].name, "MultiStatus");
    assert_eq!(schema_ir.messages[4].name, "Empty");
    assert_eq!(schema_ir.messages[4].signals.len(), 0);
}

#[test]
fn loads_fixture_and_reports_max_signals() {
    let schema = load_fixture();
    assert!(schema.has_schema());
    assert_eq!(schema.max_signals(), 3);
    assert_eq!(schema.schema_ir().messages.len(), 5);
}

#[test]
fn runtime_schema_supports_lookup_and_borrowed_metadata() {
    let schema = load_fixture();
    let runtime = schema.runtime_schema();

    let demo = runtime.find_message(291, false).expect("Demo message should be present");
    assert_eq!(demo.frame_id(), 291);
    assert!(!demo.is_extended());
    assert_eq!(demo.name(), "Demo");
    let speed = demo.signal(0).expect("Speed signal should be present");
    assert_eq!(speed.name(), "Speed");
    assert_eq!(speed.unit(), Some("km/h"));

    let ext = runtime
        .find_message(419385573, true)
        .expect("ExtStatus message should be present");
    assert_eq!(ext.frame_id(), 419385573);
    assert!(ext.is_extended());
    assert_eq!(ext.name(), "ExtStatus");
    let mode = ext.signal(0).expect("Mode signal should be present");
    assert_eq!(mode.name(), "Mode");
    assert_eq!(mode.unit(), None);
    assert_eq!(mode.display_label_for_raw(7, Some(7)), Some("Active"));

    let multi = runtime
        .find_message(600, false)
        .expect("MultiStatus should be present");
    let page = multi.signal(0).expect("Page signal should be present");
    assert!(page.is_multiplexor());
    assert_eq!(page.display_label_for_raw(1, Some(1)), Some("Thermal"));
}

#[test]
fn loads_fixture_file_into_schema_state() {
    let dbc = load_fixture_dbc();
    let schema = SchemaState::load_dbc_text(dbc.as_bytes()).expect("fixture DBC should load");

    assert!(schema.has_schema());
    assert_eq!(schema.max_signals(), 3);
}

#[test]
fn decodes_fixture_demo_message_signals_from_file() {
    let schema = load_fixture();
    let message = schema.find_message(291, false).expect("Demo message should be present");
    let payload = [0x34, 0x12, 100, 0, 0, 0, 0, 0];

    let speed = message.decode_signal(0, &payload).expect("Speed should decode");
    let temp = message.decode_signal(1, &payload).expect("Temp should decode");

    assert_eq!(speed, 0x1234 as f64);
    assert_eq!(temp, 10.0);
}

#[test]
fn decodes_fixture_battery_message_signals_from_file() {
    let schema = load_fixture();
    let message = schema.find_message(512, false).expect("Battery message should be present");
    let payload = [0x10, 0x27, 0x9c, 0xff, 0, 0, 0, 0];

    let voltage = message.decode_signal(0, &payload).expect("Voltage should decode");
    let current = message.decode_signal(1, &payload).expect("Current should decode");

    assert_eq!(voltage, 100.0);
    assert_eq!(current, -10.0);
}

#[test]
fn decodes_extended_message_signal_from_file() {
    let schema = load_fixture();
    let message = schema
        .find_message(419385573, true)
        .expect("ExtStatus message should be present");
    let payload = [7, 0, 0, 0, 0, 0, 0, 0];

    let mode = message.decode_signal(0, &payload).expect("Mode should decode");
    assert_eq!(mode, 7.0);
}

#[test]
fn decodes_choice_label_and_multiplexed_signals_from_file() {
    let schema = load_fixture();

    let ext = schema
        .find_message(419385573, true)
        .expect("ExtStatus should be present");
    let ext_payload = [7, 0, 0, 0, 0, 0, 0, 0];
    let mode = ext.signal(0).expect("Mode signal should be present");
    let decoded_mode = ext
        .decode_signal_value(0, &ext_payload)
        .expect("Mode should decode");
    assert_eq!(decoded_mode.engineering_value, 7.0);
    assert_eq!(
        mode.display_label_for_raw(decoded_mode.raw_unsigned, decoded_mode.raw_signed),
        Some("Active")
    );

    let multi = schema
        .find_message(600, false)
        .expect("MultiStatus should be present");
    let drive_payload = [0, 88, 0, 0, 0, 0, 0, 0];
    assert_eq!(multi.is_signal_active(0, &drive_payload), Some(true));
    assert_eq!(multi.is_signal_active(1, &drive_payload), Some(true));
    assert_eq!(multi.is_signal_active(2, &drive_payload), Some(false));
    assert_eq!(multi.decode_signal(1, &drive_payload), Some(88.0));

    let thermal_payload = [1, 93, 0, 0, 0, 0, 0, 0];
    assert_eq!(multi.is_signal_active(0, &thermal_payload), Some(true));
    assert_eq!(multi.is_signal_active(1, &thermal_payload), Some(false));
    assert_eq!(multi.is_signal_active(2, &thermal_payload), Some(true));
    assert!(multi.decode_signal_value(1, &thermal_payload).is_none());
    assert!(multi.decode_signal(1, &thermal_payload).is_none());
    assert_eq!(multi.decode_signal(2, &thermal_payload), Some(93.0));
}
