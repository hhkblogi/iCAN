use std::collections::{HashMap, HashSet};

use crate::ir::{ByteOrder, SchemaIr, SignalIr};
use crate::runtime::{
    MessageDesc, MessageLookupEntry, RuntimeSchema, SignalDesc, StringRef,
    MESSAGE_FLAG_EXTENDED, SIGNAL_FLAG_LITTLE_ENDIAN, SIGNAL_FLAG_SIGNED,
};

impl RuntimeSchema {
    pub fn from_ir(ir: &SchemaIr) -> Result<Self, String> {
        let mut strings = StringTableBuilder::default();
        let mut messages = Vec::with_capacity(ir.messages.len());
        let mut signals = Vec::new();
        let mut message_lookup = Vec::with_capacity(ir.messages.len());
        let mut seen_keys = HashSet::with_capacity(ir.messages.len());
        let mut max_signals_per_message = 0u16;

        for message_ir in &ir.messages {
            if !seen_keys.insert((message_ir.frame_id, message_ir.is_extended)) {
                return Err(format!(
                    "duplicate message id {} ({})",
                    message_ir.frame_id,
                    if message_ir.is_extended {
                        "extended"
                    } else {
                        "standard"
                    }
                ));
            }

            let message_index = u32::try_from(messages.len())
                .map_err(|_| "schema contains too many messages".to_owned())?;
            let signal_start = u32::try_from(signals.len())
                .map_err(|_| "schema contains too many signals".to_owned())?;
            let signal_count = u16::try_from(message_ir.signals.len())
                .map_err(|_| format!("message {} has too many signals", message_ir.name))?;

            max_signals_per_message = max_signals_per_message.max(signal_count);

            for signal_ir in &message_ir.signals {
                signals.push(SignalDesc::from_ir(signal_ir, &mut strings)?);
            }

            let flags = message_flags(message_ir.is_extended);
            messages.push(MessageDesc {
                frame_id: message_ir.frame_id,
                flags,
                dlc: message_ir.dlc,
                signal_start,
                signal_count,
                name: strings.intern(&message_ir.name)?,
            });
            message_lookup.push(MessageLookupEntry {
                frame_id: message_ir.frame_id,
                flags,
                message_index,
            });
        }

        message_lookup.sort_by_key(|entry| (entry.is_extended(), entry.frame_id));

        Ok(Self {
            strings: strings.finish(),
            messages: messages.into_boxed_slice(),
            signals: signals.into_boxed_slice(),
            message_lookup: message_lookup.into_boxed_slice(),
            max_signals_per_message,
        })
    }
}

impl SignalDesc {
    fn from_ir(signal: &SignalIr, strings: &mut StringTableBuilder) -> Result<Self, String> {
        Ok(Self {
            start_bit: signal.start_bit,
            bit_len: signal.bit_len,
            flags: signal_flags(signal.byte_order, signal.is_signed),
            factor: signal.factor,
            offset: signal.offset,
            name: strings.intern(&signal.name)?,
            unit: strings.intern(signal.unit.as_deref().unwrap_or(""))?,
        })
    }

    pub(crate) fn byte_order(&self) -> ByteOrder {
        if (self.flags & SIGNAL_FLAG_LITTLE_ENDIAN) != 0 {
            ByteOrder::LittleEndian
        } else {
            ByteOrder::BigEndian
        }
    }
}

#[derive(Default)]
struct StringTableBuilder {
    bytes: Vec<u8>,
    index: HashMap<String, StringRef>,
}

impl StringTableBuilder {
    fn intern(&mut self, value: &str) -> Result<StringRef, String> {
        if value.is_empty() {
            return Ok(StringRef::default());
        }

        if let Some(existing) = self.index.get(value) {
            return Ok(*existing);
        }

        let offset = u32::try_from(self.bytes.len())
            .map_err(|_| "string table exceeds supported size".to_owned())?;
        let len = u32::try_from(value.len())
            .map_err(|_| "string table entry exceeds supported size".to_owned())?;
        self.bytes.extend_from_slice(value.as_bytes());

        let string_ref = StringRef { offset, len };
        self.index.insert(value.to_owned(), string_ref);
        Ok(string_ref)
    }

    fn finish(self) -> Box<[u8]> {
        self.bytes.into_boxed_slice()
    }
}

fn message_flags(is_extended: bool) -> u16 {
    if is_extended {
        MESSAGE_FLAG_EXTENDED
    } else {
        0
    }
}

fn signal_flags(byte_order: ByteOrder, is_signed: bool) -> u16 {
    let mut flags = 0;
    if byte_order == ByteOrder::LittleEndian {
        flags |= SIGNAL_FLAG_LITTLE_ENDIAN;
    }
    if is_signed {
        flags |= SIGNAL_FLAG_SIGNED;
    }
    flags
}
