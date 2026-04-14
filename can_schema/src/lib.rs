use std::ffi::CString;

const CAN_EFF_FLAG: u32 = 0x8000_0000;
const CAN_SFF_MASK: u32 = 0x0000_07ff;
const CAN_EFF_MASK: u32 = 0x1fff_ffff;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ByteOrder {
    LittleEndian,
    BigEndian,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SignalIr {
    pub name: String,
    pub start_bit: u16,
    pub bit_len: u16,
    pub byte_order: ByteOrder,
    pub is_signed: bool,
    pub factor: f64,
    pub offset: f64,
    pub unit: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MessageIr {
    pub frame_id: u32,
    pub is_extended: bool,
    pub name: String,
    pub dlc: u8,
    pub signals: Vec<SignalIr>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct SchemaIr {
    pub messages: Vec<MessageIr>,
}

#[derive(Clone, Debug)]
pub struct CompiledSignal {
    name: String,
    start_bit: u16,
    bit_len: u16,
    byte_order: ByteOrder,
    is_signed: bool,
    factor: f64,
    offset: f64,
    unit: Option<String>,
}

#[derive(Clone, Debug)]
pub struct CompiledMessage {
    frame_id: u32,
    is_extended: bool,
    name: String,
    dlc: u8,
    signals: Vec<CompiledSignal>,
}

#[derive(Clone, Debug)]
pub struct CompiledSchema {
    messages: Vec<CompiledMessage>,
    max_signals: usize,
}

pub struct SchemaState {
    schema_ir: SchemaIr,
    compiled: CompiledSchema,
    last_error: CString,
}

impl SchemaState {
    pub fn load_dbc_text(bytes: &[u8]) -> Result<Self, String> {
        if bytes.is_empty() {
            return Err("DBC text must not be empty".to_owned());
        }

        let text = std::str::from_utf8(bytes)
            .map_err(|_| "DBC text must be valid UTF-8".to_owned())?;
        let schema_ir = SchemaIr::parse_dbc(text)?;
        let compiled = CompiledSchema::from_ir(&schema_ir);

        Ok(Self {
            schema_ir,
            compiled,
            last_error: CString::new("").expect("empty CString must be valid"),
        })
    }

    pub fn has_schema(&self) -> bool {
        !self.compiled.messages.is_empty()
    }

    pub fn schema_ir(&self) -> &SchemaIr {
        &self.schema_ir
    }

    pub fn last_error(&self) -> &CString {
        &self.last_error
    }

    pub fn set_last_error(&mut self, message: impl AsRef<str>) {
        let sanitized = message.as_ref().replace('\0', "?");
        self.last_error = CString::new(sanitized).expect("sanitized error strings must not contain NUL");
    }

    pub fn clear_last_error(&mut self) {
        self.last_error = CString::new("").expect("empty CString must be valid");
    }

    pub fn find_message(&self, id: u32, is_extended: bool) -> Option<&CompiledMessage> {
        self.compiled.find_message(id, is_extended)
    }

    pub fn max_signals(&self) -> usize {
        self.compiled.max_signals()
    }
}

impl SchemaIr {
    pub fn parse_dbc(text: &str) -> Result<Self, String> {
        let mut messages = Vec::new();
        let mut current_message: Option<usize> = None;

        for (line_no, raw_line) in text.lines().enumerate() {
            let line = raw_line.trim();
            if line.is_empty() {
                continue;
            }

            if line.starts_with("BO_ ") {
                let message = parse_message_line(line)
                    .map_err(|err| format!("line {}: {}", line_no + 1, err))?;
                messages.push(message);
                current_message = Some(messages.len() - 1);
                continue;
            }

            if line.starts_with("SG_ ") {
                let Some(message_index) = current_message else {
                    return Err(format!("line {}: SG_ line appeared before any BO_ line", line_no + 1));
                };
                let signal = parse_signal_line(line)
                    .map_err(|err| format!("line {}: {}", line_no + 1, err))?;
                messages[message_index].signals.push(signal);
                continue;
            }
        }

        Ok(Self { messages })
    }
}

impl CompiledSchema {
    pub fn from_ir(ir: &SchemaIr) -> Self {
        let mut messages = ir
            .messages
            .iter()
            .map(|message| CompiledMessage {
                frame_id: message.frame_id,
                is_extended: message.is_extended,
                name: message.name.clone(),
                dlc: message.dlc,
                signals: message
                    .signals
                    .iter()
                    .map(|signal| CompiledSignal {
                        name: signal.name.clone(),
                        start_bit: signal.start_bit,
                        bit_len: signal.bit_len,
                        byte_order: signal.byte_order,
                        is_signed: signal.is_signed,
                        factor: signal.factor,
                        offset: signal.offset,
                        unit: signal.unit.clone(),
                    })
                    .collect(),
            })
            .collect::<Vec<_>>();

        messages.sort_by_key(|message| (message.is_extended, message.frame_id));
        let max_signals = messages.iter().map(|message| message.signals.len()).max().unwrap_or(0);

        Self {
            messages,
            max_signals,
        }
    }

    pub fn find_message(&self, id: u32, is_extended: bool) -> Option<&CompiledMessage> {
        self.messages
            .iter()
            .find(|message| message.frame_id == id && message.is_extended == is_extended)
    }

    pub fn max_signals(&self) -> usize {
        self.max_signals
    }
}

impl CompiledMessage {
    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn dlc(&self) -> u8 {
        self.dlc
    }

    pub fn signals(&self) -> &[CompiledSignal] {
        &self.signals
    }

    pub fn decode_signal(&self, index: usize, payload: &[u8]) -> Option<f64> {
        let signal = self.signals.get(index)?;
        signal.decode(payload)
    }
}

impl CompiledSignal {
    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn unit(&self) -> Option<&str> {
        self.unit.as_deref()
    }

    fn decode(&self, payload: &[u8]) -> Option<f64> {
        let raw = match self.byte_order {
            ByteOrder::LittleEndian => extract_little_endian(payload, usize::from(self.start_bit), usize::from(self.bit_len))?,
            ByteOrder::BigEndian => extract_big_endian(payload, usize::from(self.start_bit), usize::from(self.bit_len))?,
        };

        let numeric = if self.is_signed {
            let signed = sign_extend(raw, usize::from(self.bit_len))?;
            signed as f64
        } else {
            raw as f64
        };

        Some(numeric * self.factor + self.offset)
    }
}

fn parse_message_line(line: &str) -> Result<MessageIr, String> {
    let rest = line
        .strip_prefix("BO_ ")
        .ok_or_else(|| "message line must start with BO_".to_owned())?;
    let (left, right) = rest
        .split_once(':')
        .ok_or_else(|| "message line must contain ':'".to_owned())?;

    let left_tokens = left.split_whitespace().collect::<Vec<_>>();
    if left_tokens.len() < 2 {
        return Err("message line must contain id and name".to_owned());
    }

    let raw_id = left_tokens[0]
        .parse::<u32>()
        .map_err(|_| "message id must be an unsigned integer".to_owned())?;
    let (frame_id, is_extended) = classify_frame_id(raw_id)?;

    let right_tokens = right.split_whitespace().collect::<Vec<_>>();
    if right_tokens.is_empty() {
        return Err("message line must contain DLC".to_owned());
    }
    let dlc = right_tokens[0]
        .parse::<u8>()
        .map_err(|_| "message DLC must be an unsigned integer".to_owned())?;

    Ok(MessageIr {
        frame_id,
        is_extended,
        name: left_tokens[1].to_owned(),
        dlc,
        signals: Vec::new(),
    })
}

fn parse_signal_line(line: &str) -> Result<SignalIr, String> {
    let rest = line
        .strip_prefix("SG_ ")
        .ok_or_else(|| "signal line must start with SG_".to_owned())?;
    let (left, right) = rest
        .split_once(':')
        .ok_or_else(|| "signal line must contain ':'".to_owned())?;

    let left_tokens = left.split_whitespace().collect::<Vec<_>>();
    if left_tokens.is_empty() {
        return Err("signal line must contain a signal name".to_owned());
    }
    if left_tokens.len() > 1 {
        return Err("multiplexed signals are not supported yet".to_owned());
    }

    let signal_name = left_tokens[0].to_owned();
    let right = right.trim();
    let right_tokens = right.split_whitespace().collect::<Vec<_>>();
    if right_tokens.len() < 2 {
        return Err("signal line must contain bit spec and scale/offset".to_owned());
    }

    let (start_bit, bit_len, byte_order, is_signed) = parse_signal_spec(right_tokens[0])?;
    let (factor, offset) = parse_factor_offset(right_tokens[1])?;
    let unit = parse_quoted_unit(right);

    Ok(SignalIr {
        name: signal_name,
        start_bit,
        bit_len,
        byte_order,
        is_signed,
        factor,
        offset,
        unit,
    })
}

fn classify_frame_id(raw_id: u32) -> Result<(u32, bool), String> {
    if (raw_id & CAN_EFF_FLAG) != 0 {
        return Ok((raw_id & CAN_EFF_MASK, true));
    }

    if raw_id <= CAN_SFF_MASK {
        return Ok((raw_id, false));
    }

    if raw_id <= CAN_EFF_MASK {
        return Ok((raw_id, true));
    }

    Err("message id exceeds 29-bit CAN range".to_owned())
}

fn parse_signal_spec(spec: &str) -> Result<(u16, u16, ByteOrder, bool), String> {
    let (start_text, rest) = spec
        .split_once('|')
        .ok_or_else(|| "signal bit spec must contain '|'".to_owned())?;
    let (len_text, rest) = rest
        .split_once('@')
        .ok_or_else(|| "signal bit spec must contain '@'".to_owned())?;

    let start_bit = start_text
        .parse::<u16>()
        .map_err(|_| "signal start bit must be an unsigned integer".to_owned())?;
    let bit_len = len_text
        .parse::<u16>()
        .map_err(|_| "signal bit length must be an unsigned integer".to_owned())?;
    if bit_len == 0 || bit_len > 64 {
        return Err("signal bit length must be in 1..=64".to_owned());
    }

    let mut chars = rest.chars();
    let byte_order = match chars.next() {
        Some('1') => ByteOrder::LittleEndian,
        Some('0') => ByteOrder::BigEndian,
        _ => return Err("signal byte order must be 0 or 1".to_owned()),
    };
    let is_signed = match chars.next() {
        Some('+') => false,
        Some('-') => true,
        _ => return Err("signal sign marker must be '+' or '-'".to_owned()),
    };

    Ok((start_bit, bit_len, byte_order, is_signed))
}

fn parse_factor_offset(spec: &str) -> Result<(f64, f64), String> {
    let inner = spec
        .strip_prefix('(')
        .and_then(|value| value.strip_suffix(')'))
        .ok_or_else(|| "signal factor/offset must be wrapped in parentheses".to_owned())?;
    let (factor_text, offset_text) = inner
        .split_once(',')
        .ok_or_else(|| "signal factor/offset must contain ','".to_owned())?;

    let factor = factor_text
        .parse::<f64>()
        .map_err(|_| "signal factor must be numeric".to_owned())?;
    let offset = offset_text
        .parse::<f64>()
        .map_err(|_| "signal offset must be numeric".to_owned())?;
    Ok((factor, offset))
}

fn parse_quoted_unit(line: &str) -> Option<String> {
    let start = line.find('"')?;
    let rest = &line[start + 1..];
    let end = rest.find('"')?;
    Some(rest[..end].to_owned())
}

fn extract_little_endian(payload: &[u8], start_bit: usize, bit_len: usize) -> Option<u64> {
    let mut raw = 0u64;
    for offset in 0..bit_len {
        let bit_index = start_bit + offset;
        let byte = *payload.get(bit_index / 8)?;
        let bit = (byte >> (bit_index % 8)) & 1;
        raw |= u64::from(bit) << offset;
    }
    Some(raw)
}

fn extract_big_endian(payload: &[u8], start_bit: usize, bit_len: usize) -> Option<u64> {
    let mut raw = 0u64;
    let mut bit_index = start_bit;

    for consumed in 0..bit_len {
        let byte = *payload.get(bit_index / 8)?;
        let bit = (byte >> (bit_index % 8)) & 1;
        raw = (raw << 1) | u64::from(bit);

        if consumed + 1 < bit_len {
            bit_index = next_big_endian_bit(bit_index)?;
        }
    }

    Some(raw)
}

fn next_big_endian_bit(bit_index: usize) -> Option<usize> {
    if bit_index % 8 == 0 {
        bit_index.checked_add(15)
    } else {
        bit_index.checked_sub(1)
    }
}

fn sign_extend(raw: u64, bit_len: usize) -> Option<i64> {
    if bit_len == 0 || bit_len > 64 {
        return None;
    }
    if bit_len == 64 {
        return Some(raw as i64);
    }

    let shift = 64 - bit_len;
    Some(((raw << shift) as i64) >> shift)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(i32)]
pub enum SchemaStatus {
    Ok = 0,
    InvalidArgument = 1,
    LoadError = 2,
    NotReady = 3,
    NoMatch = 4,
    BufferTooSmall = 5,
    Unimplemented = 6,
}

#[cfg(test)]
mod tests {}
