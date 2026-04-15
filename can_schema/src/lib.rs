use std::cell::RefCell;
use std::ffi::{c_char, CString};
use std::sync::Mutex;

mod compile;
mod decode;
mod ir;
mod parser;
mod runtime;
mod status;

pub use decode::DecodedSignalValue;
pub use ir::{ByteOrder, ChoiceIr, MessageIr, MuxRoleIr, SchemaIr, SignalIr};
pub use runtime::{RuntimeMessageRef, RuntimeSchema, RuntimeSignalRef, StringRef};
pub use status::SchemaStatus;

thread_local! {
    static LAST_ERROR_SNAPSHOT: RefCell<CString> =
        RefCell::new(CString::new("").expect("empty CString must be valid"));
}

pub struct SchemaState {
    schema_ir: SchemaIr,
    runtime: RuntimeSchema,
    last_error: Mutex<CString>,
}

impl SchemaState {
    pub fn load_dbc_text(bytes: &[u8]) -> Result<Self, String> {
        if bytes.is_empty() {
            return Err("DBC text must not be empty".to_owned());
        }

        let text = std::str::from_utf8(bytes)
            .map_err(|_| "DBC text must be valid UTF-8".to_owned())?;
        let schema_ir = SchemaIr::parse_dbc(text)?;
        let runtime = RuntimeSchema::from_ir(&schema_ir)?;

        Ok(Self {
            schema_ir,
            runtime,
            last_error: Mutex::new(CString::new("").expect("empty CString must be valid")),
        })
    }

    pub fn has_schema(&self) -> bool {
        !self.runtime.messages.is_empty()
    }

    pub fn schema_ir(&self) -> &SchemaIr {
        &self.schema_ir
    }

    pub fn runtime_schema(&self) -> &RuntimeSchema {
        &self.runtime
    }

    pub fn last_error_ptr(&self) -> *const c_char {
        let snapshot = self
            .last_error
            .lock()
            .expect("schema error mutex should not be poisoned")
            .clone();

        LAST_ERROR_SNAPSHOT.with(|slot| {
            *slot.borrow_mut() = snapshot;
            slot.borrow().as_ptr()
        })
    }

    pub fn set_last_error(&self, message: impl AsRef<str>) {
        let sanitized = message.as_ref().replace('\0', "?");
        *self
            .last_error
            .lock()
            .expect("schema error mutex should not be poisoned") =
            CString::new(sanitized).expect("sanitized error strings must not contain NUL");
    }

    pub fn clear_last_error(&self) {
        *self
            .last_error
            .lock()
            .expect("schema error mutex should not be poisoned") =
            CString::new("").expect("empty CString must be valid");
    }

    pub fn find_message(&self, id: u32, is_extended: bool) -> Option<RuntimeMessageRef<'_>> {
        self.runtime.find_message(id, is_extended)
    }

    pub fn max_signals(&self) -> usize {
        self.runtime.max_signals()
    }
}

#[cfg(test)]
mod tests {}
