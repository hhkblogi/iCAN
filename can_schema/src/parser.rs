use crate::ir::{ByteOrder, ChoiceIr, MessageIr, MuxRoleIr, SchemaIr, SignalIr};

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

            if line.starts_with("VAL_ ") {
                parse_value_choices_line(&mut messages, line)
                    .map_err(|err| format!("line {}: {}", line_no + 1, err))?;
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

    let signal_name = left_tokens[0].to_owned();
    let mux_role = parse_mux_role(&left_tokens[1..])?;
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
        choices: Vec::new(),
        mux_role,
    })
}

fn parse_mux_role(tokens: &[&str]) -> Result<MuxRoleIr, String> {
    match tokens {
        [] => Ok(MuxRoleIr::None),
        ["M"] => Ok(MuxRoleIr::Multiplexor),
        [selector] if selector.starts_with('m') => {
            let selector_value = selector[1..]
                .parse::<u64>()
                .map_err(|_| "multiplex selector value must be an unsigned integer".to_owned())?;
            Ok(MuxRoleIr::Multiplexed { selector_value })
        }
        _ => Err("unsupported multiplexed signal syntax".to_owned()),
    }
}

fn parse_value_choices_line(messages: &mut [MessageIr], line: &str) -> Result<(), String> {
    let rest = line
        .strip_prefix("VAL_ ")
        .ok_or_else(|| "value choice line must start with VAL_".to_owned())?;
    let rest = rest
        .strip_suffix(';')
        .ok_or_else(|| "value choice line must end with ';'".to_owned())?;

    let mut cursor = 0usize;
    let raw_id = next_token(rest, &mut cursor)
        .ok_or_else(|| "value choice line must contain a message id".to_owned())?;
    let signal_name = next_token(rest, &mut cursor)
        .ok_or_else(|| "value choice line must contain a signal name".to_owned())?;
    let raw_id = raw_id
        .parse::<u32>()
        .map_err(|_| "value choice message id must be an unsigned integer".to_owned())?;
    let (frame_id, is_extended) = classify_frame_id(raw_id)?;

    let message = messages
        .iter_mut()
        .find(|message| message.frame_id == frame_id && message.is_extended == is_extended)
        .ok_or_else(|| format!("value choice line references unknown message id {}", frame_id))?;
    let signal = message
        .signals
        .iter_mut()
        .find(|signal| signal.name == signal_name)
        .ok_or_else(|| format!("value choice line references unknown signal {}", signal_name))?;

    while let Some(value_text) = next_token(rest, &mut cursor) {
        let raw_value = value_text
            .parse::<i64>()
            .map_err(|_| "choice raw value must be numeric".to_owned())?;
        let label = next_quoted(rest, &mut cursor)
            .ok_or_else(|| "choice label must be quoted".to_owned())?;
        signal.choices.push(ChoiceIr { raw_value, label });
    }

    Ok(())
}

fn next_token<'a>(text: &'a str, cursor: &mut usize) -> Option<&'a str> {
    let bytes = text.as_bytes();
    while *cursor < bytes.len() && bytes[*cursor].is_ascii_whitespace() {
        *cursor += 1;
    }
    if *cursor >= bytes.len() {
        return None;
    }

    let start = *cursor;
    while *cursor < bytes.len() && !bytes[*cursor].is_ascii_whitespace() {
        *cursor += 1;
    }
    Some(&text[start..*cursor])
}

fn next_quoted(text: &str, cursor: &mut usize) -> Option<String> {
    let bytes = text.as_bytes();
    while *cursor < bytes.len() && bytes[*cursor].is_ascii_whitespace() {
        *cursor += 1;
    }
    if *cursor >= bytes.len() || bytes[*cursor] != b'"' {
        return None;
    }
    *cursor += 1;
    let start = *cursor;
    while *cursor < bytes.len() && bytes[*cursor] != b'"' {
        *cursor += 1;
    }
    if *cursor >= bytes.len() {
        return None;
    }
    let label = text[start..*cursor].to_owned();
    *cursor += 1;
    Some(label)
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
