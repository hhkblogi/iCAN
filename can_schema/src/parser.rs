use crate::ir::{ByteOrder, MessageIr, SchemaIr, SignalIr};

const CAN_EFF_FLAG: u32 = 0x8000_0000;
const CAN_SFF_MASK: u32 = 0x0000_07ff;
const CAN_EFF_MASK: u32 = 0x1fff_ffff;

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
                    return Err(format!(
                        "line {}: SG_ line appeared before any BO_ line",
                        line_no + 1
                    ));
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
