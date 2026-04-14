extern crate can_schema;

use std::fs;

use can_schema::{ByteOrder, SchemaIr, SchemaState};

const UNSUPPORTED_MULTIPLEXED_DBC: &str = r#"VERSION "1.0"

NS_ :

BS_:

BU_: ECM

BO_ 100 Muxed : 8 ECM
 SG_ Speed m0 : 0|8@1+ (1,0) [0|255] "" ECM
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
fn rejects_unsupported_multiplexed_signal_definitions() {
    let result = SchemaState::load_dbc_text(UNSUPPORTED_MULTIPLEXED_DBC.as_bytes());
    assert!(result.is_err());
}

#[test]
fn parses_fixture_file_into_ir() {
    let dbc = load_fixture_dbc();
    let schema_ir = SchemaIr::parse_dbc(&dbc).expect("fixture DBC should parse");

    assert_eq!(schema_ir.messages.len(), 3);
    assert_eq!(schema_ir.messages[0].name, "Demo");
    assert_eq!(schema_ir.messages[0].signals.len(), 2);
    assert_eq!(schema_ir.messages[0].signals[0].byte_order, ByteOrder::LittleEndian);
    assert_eq!(schema_ir.messages[1].name, "Battery");
    assert_eq!(schema_ir.messages[2].name, "ExtStatus");
    assert!(schema_ir.messages[2].is_extended);
}

#[test]
fn loads_fixture_and_reports_max_signals() {
    let schema = load_fixture();
    assert!(schema.has_schema());
    assert_eq!(schema.max_signals(), 2);
    assert_eq!(schema.schema_ir().messages.len(), 3);
}

#[test]
fn loads_fixture_file_into_schema_state() {
    let dbc = load_fixture_dbc();
    let schema = SchemaState::load_dbc_text(dbc.as_bytes()).expect("fixture DBC should load");

    assert!(schema.has_schema());
    assert_eq!(schema.max_signals(), 2);
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
