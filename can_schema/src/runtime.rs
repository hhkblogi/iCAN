pub(crate) const MESSAGE_FLAG_EXTENDED: u16 = 1 << 0;
pub(crate) const SIGNAL_FLAG_LITTLE_ENDIAN: u16 = 1 << 0;
pub(crate) const SIGNAL_FLAG_SIGNED: u16 = 1 << 1;
pub(crate) const SIGNAL_FLAG_MULTIPLEXOR: u16 = 1 << 2;
pub(crate) const SIGNAL_FLAG_MULTIPLEXED: u16 = 1 << 3;
pub(crate) const SIGNAL_FLAG_FLOAT32: u16 = 1 << 4;
pub(crate) const SIGNAL_FLAG_FLOAT64: u16 = 1 << 5;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct StringRef {
    pub(crate) offset: u32,
    pub(crate) len: u32,
}

#[derive(Clone, Debug)]
pub struct MessageDesc {
    pub(crate) frame_id: u32,
    pub(crate) flags: u16,
    pub(crate) dlc: u8,
    pub(crate) signal_start: u32,
    pub(crate) signal_count: u16,
    pub(crate) multiplexor_rel_index: u16,
    pub(crate) name: StringRef,
}

#[derive(Clone, Debug)]
pub struct SignalDesc {
    pub(crate) start_bit: u16,
    pub(crate) bit_len: u16,
    pub(crate) flags: u16,
    pub(crate) factor: f64,
    pub(crate) offset: f64,
    pub(crate) name: StringRef,
    pub(crate) unit: StringRef,
    pub(crate) choices_start: u32,
    pub(crate) choices_count: u16,
    pub(crate) mux_selector_value: u64,
}

#[derive(Clone, Debug)]
pub struct ChoiceDesc {
    pub(crate) raw_value: i64,
    pub(crate) label: StringRef,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct MessageLookupEntry {
    pub(crate) frame_id: u32,
    pub(crate) flags: u16,
    pub(crate) message_index: u32,
}

#[derive(Clone, Debug)]
pub struct RuntimeSchema {
    pub(crate) strings: Box<[u8]>,
    pub(crate) messages: Box<[MessageDesc]>,
    pub(crate) signals: Box<[SignalDesc]>,
    pub(crate) choices: Box<[ChoiceDesc]>,
    pub(crate) message_lookup: Box<[MessageLookupEntry]>,
    pub(crate) max_signals_per_message: u16,
}

#[derive(Clone, Copy)]
pub struct RuntimeMessageRef<'a> {
    pub(crate) schema: &'a RuntimeSchema,
    pub(crate) message_index: usize,
}

#[derive(Clone, Copy)]
pub struct RuntimeSignalRef<'a> {
    pub(crate) schema: &'a RuntimeSchema,
    pub(crate) signal_index: usize,
}

impl RuntimeSchema {
    pub fn max_signals(&self) -> usize {
        usize::from(self.max_signals_per_message)
    }

    pub fn find_message(&self, id: u32, is_extended: bool) -> Option<RuntimeMessageRef<'_>> {
        let search_key = (is_extended, id);
        let lookup_index = self
            .message_lookup
            .binary_search_by_key(&search_key, |entry| (entry.is_extended(), entry.frame_id))
            .ok()?;
        let message_index = self.message_lookup[lookup_index].message_index as usize;

        Some(RuntimeMessageRef {
            schema: self,
            message_index,
        })
    }

    pub(crate) fn string(&self, string_ref: StringRef) -> &str {
        if string_ref.len == 0 {
            return "";
        }

        let start = string_ref.offset as usize;
        let end = start + string_ref.len as usize;
        std::str::from_utf8(&self.strings[start..end])
            .expect("runtime string table must contain valid UTF-8")
    }
}

impl<'a> RuntimeMessageRef<'a> {
    pub(crate) fn desc(&self) -> &'a MessageDesc {
        &self.schema.messages[self.message_index]
    }

    pub fn frame_id(&self) -> u32 {
        self.desc().frame_id
    }

    pub fn is_extended(&self) -> bool {
        (self.desc().flags & MESSAGE_FLAG_EXTENDED) != 0
    }

    pub fn name(&self) -> &'a str {
        self.schema.string(self.desc().name)
    }

    pub fn dlc(&self) -> u8 {
        self.desc().dlc
    }

    pub fn signal_count(&self) -> usize {
        usize::from(self.desc().signal_count)
    }

    pub fn multiplexor(&self) -> Option<RuntimeSignalRef<'a>> {
        let rel = self.desc().multiplexor_rel_index;
        if rel == u16::MAX {
            return None;
        }
        self.signal(usize::from(rel))
    }

    pub fn signal(&self, index: usize) -> Option<RuntimeSignalRef<'a>> {
        if index >= self.signal_count() {
            return None;
        }

        Some(RuntimeSignalRef {
            schema: self.schema,
            signal_index: self.desc().signal_start as usize + index,
        })
    }
}

impl<'a> RuntimeSignalRef<'a> {
    pub(crate) fn desc(&self) -> &'a SignalDesc {
        &self.schema.signals[self.signal_index]
    }

    pub fn name(&self) -> &'a str {
        self.schema.string(self.desc().name)
    }

    pub fn unit(&self) -> Option<&'a str> {
        let unit = self.schema.string(self.desc().unit);
        if unit.is_empty() {
            None
        } else {
            Some(unit)
        }
    }

    pub fn is_multiplexor(&self) -> bool {
        (self.desc().flags & SIGNAL_FLAG_MULTIPLEXOR) != 0
    }

    pub fn is_multiplexed(&self) -> bool {
        (self.desc().flags & SIGNAL_FLAG_MULTIPLEXED) != 0
    }

    pub fn multiplex_selector_value(&self) -> Option<u64> {
        if self.is_multiplexed() {
            Some(self.desc().mux_selector_value)
        } else {
            None
        }
    }

    pub fn display_label_for_raw(&self, raw_unsigned: u64, raw_signed: Option<i64>) -> Option<&'a str> {
        let start = self.desc().choices_start as usize;
        let end = start + usize::from(self.desc().choices_count);
        for choice in &self.schema.choices[start..end] {
            if self.matches_choice(choice.raw_value, raw_unsigned, raw_signed) {
                return Some(self.schema.string(choice.label));
            }
        }
        None
    }

    fn matches_choice(&self, choice_value: i64, raw_unsigned: u64, raw_signed: Option<i64>) -> bool {
        if self.desc().is_signed() {
            raw_signed == Some(choice_value)
        } else {
            choice_value >= 0 && raw_unsigned == choice_value as u64
        }
    }
}

impl SignalDesc {
    pub(crate) fn is_float32(&self) -> bool {
        (self.flags & SIGNAL_FLAG_FLOAT32) != 0
    }

    pub(crate) fn is_float64(&self) -> bool {
        (self.flags & SIGNAL_FLAG_FLOAT64) != 0
    }

    pub(crate) fn is_signed(&self) -> bool {
        (self.flags & SIGNAL_FLAG_SIGNED) != 0
    }
}

impl MessageLookupEntry {
    pub(crate) fn is_extended(&self) -> bool {
        (self.flags & MESSAGE_FLAG_EXTENDED) != 0
    }
}
