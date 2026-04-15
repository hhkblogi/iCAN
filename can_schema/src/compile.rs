use std::collections::{HashMap, HashSet};

use crate::ir::{ByteOrder, MuxRoleIr, SchemaIr, SignalIr};
use crate::runtime::{
    ChoiceDesc, MessageDesc, MessageLookupEntry, RuntimeSchema, SignalDesc, StringRef,
    MESSAGE_FLAG_EXTENDED, SIGNAL_FLAG_LITTLE_ENDIAN, SIGNAL_FLAG_MULTIPLEXED,
    SIGNAL_FLAG_MULTIPLEXOR, SIGNAL_FLAG_SIGNED,
};

impl RuntimeSchema {
    pub fn from_ir(ir: &SchemaIr) -> Result<Self, String> {
        let mut strings = StringTableBuilder::default();
        let mut messages = Vec::with_capacity(ir.messages.len());
        let mut signals = Vec::new();
        let mut choices = Vec::new();
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
            let multiplexor_rel_index = multiplexor_rel_index(message_ir)?;

            max_signals_per_message = max_signals_per_message.max(signal_count);

            for signal_ir in &message_ir.signals {
                signals.push(SignalDesc::from_ir(signal_ir, &mut strings, &mut choices)?);
            }

            let flags = message_flags(message_ir.is_extended);
            messages.push(MessageDesc {
                frame_id: message_ir.frame_id,
                flags,
                dlc: message_ir.dlc,
                signal_start,
                signal_count,
                multiplexor_rel_index,
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
            choices: choices.into_boxed_slice(),
            message_lookup: message_lookup.into_boxed_slice(),
            max_signals_per_message,
        })
    }
}

impl SignalDesc {
    fn from_ir(
        signal: &SignalIr,
        strings: &mut StringTableBuilder,
        choices: &mut Vec<ChoiceDesc>,
    ) -> Result<Self, String> {
        let choices_start = u32::try_from(choices.len())
            .map_err(|_| "schema contains too many value choices".to_owned())?;
        let choices_count = u16::try_from(signal.choices.len())
            .map_err(|_| format!("signal {} has too many value choices", signal.name))?;
        for choice in &signal.choices {
            choices.push(ChoiceDesc {
                raw_value: choice.raw_value,
                label: strings.intern(&choice.label)?,
            });
        }

        Ok(Self {
            start_bit: signal.start_bit,
            bit_len: signal.bit_len,
            flags: signal_flags(signal.byte_order, signal.is_signed, signal.mux_role),
            factor: signal.factor,
            offset: signal.offset,
            name: strings.intern(&signal.name)?,
            unit: strings.intern(signal.unit.as_deref().unwrap_or(""))?,
            choices_start,
            choices_count,
            mux_selector_value: match signal.mux_role {
                MuxRoleIr::Multiplexed { selector_value } => selector_value,
                _ => 0,
            },
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

fn multiplexor_rel_index(message: &crate::ir::MessageIr) -> Result<u16, String> {
    let mut multiplexor_rel_index = None;
    let mut has_multiplexed_signals = false;

    for (index, signal) in message.signals.iter().enumerate() {
        match signal.mux_role {
            MuxRoleIr::Multiplexor => {
                if multiplexor_rel_index.is_some() {
                    return Err(format!(
                        "message {} has multiple multiplexor signals; only basic DBC multiplexing is supported",
                        message.name
                    ));
                }
                multiplexor_rel_index = Some(
                    u16::try_from(index)
                        .map_err(|_| format!("message {} has too many signals", message.name))?,
                );
            }
            MuxRoleIr::Multiplexed { .. } => has_multiplexed_signals = true,
            MuxRoleIr::None => {}
        }
    }

    if has_multiplexed_signals && multiplexor_rel_index.is_none() {
        return Err(format!(
            "message {} has multiplexed signals but no multiplexor",
            message.name
        ));
    }

    Ok(multiplexor_rel_index.unwrap_or(u16::MAX))
}

fn message_flags(is_extended: bool) -> u16 {
    if is_extended {
        MESSAGE_FLAG_EXTENDED
    } else {
        0
    }
}

fn signal_flags(byte_order: ByteOrder, is_signed: bool, mux_role: MuxRoleIr) -> u16 {
    let mut flags = 0;
    if byte_order == ByteOrder::LittleEndian {
        flags |= SIGNAL_FLAG_LITTLE_ENDIAN;
    }
    if is_signed {
        flags |= SIGNAL_FLAG_SIGNED;
    }
    match mux_role {
        MuxRoleIr::Multiplexor => flags |= SIGNAL_FLAG_MULTIPLEXOR,
        MuxRoleIr::Multiplexed { .. } => flags |= SIGNAL_FLAG_MULTIPLEXED,
        MuxRoleIr::None => {}
    }
    flags
}
