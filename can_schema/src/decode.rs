use crate::ir::ByteOrder;
use crate::runtime::{RuntimeMessageRef, RuntimeSignalRef};

#[derive(Clone, Copy, Debug)]
pub struct DecodedSignalValue {
    pub raw_unsigned: u64,
    pub raw_signed: Option<i64>,
    pub engineering_value: f64,
}

impl<'a> RuntimeMessageRef<'a> {
    pub fn decode_signal(&self, index: usize, payload: &[u8]) -> Option<f64> {
        Some(self.decode_signal_value(index, payload)?.engineering_value)
    }

    pub fn decode_signal_value(&self, index: usize, payload: &[u8]) -> Option<DecodedSignalValue> {
        if !self.is_signal_active(index, payload)? {
            return None;
        }
        self.signal(index)?.decode(payload)
    }

    pub fn is_signal_active(&self, index: usize, payload: &[u8]) -> Option<bool> {
        let signal = self.signal(index)?;
        if signal.is_multiplexor() || !signal.is_multiplexed() {
            return Some(true);
        }

        let multiplexor = self.multiplexor()?;
        let selector = multiplexor.decode(payload)?;
        Some(selector.raw_unsigned == signal.multiplex_selector_value()?)
    }
}

impl<'a> RuntimeSignalRef<'a> {
    fn decode(&self, payload: &[u8]) -> Option<DecodedSignalValue> {
        let desc = self.desc();
        let raw = match desc.byte_order() {
            ByteOrder::LittleEndian => {
                extract_little_endian(payload, usize::from(desc.start_bit), usize::from(desc.bit_len))?
            }
            ByteOrder::BigEndian => {
                extract_big_endian(payload, usize::from(desc.start_bit), usize::from(desc.bit_len))?
            }
        };

        if desc.is_float32() {
            let numeric = f32::from_bits(u32::try_from(raw).ok()?) as f64;
            return Some(DecodedSignalValue {
                raw_unsigned: raw,
                raw_signed: None,
                engineering_value: numeric * desc.factor + desc.offset,
            });
        }

        if desc.is_float64() {
            let numeric = f64::from_bits(raw);
            return Some(DecodedSignalValue {
                raw_unsigned: raw,
                raw_signed: None,
                engineering_value: numeric * desc.factor + desc.offset,
            });
        }

        let raw_signed = if desc.is_signed() {
            Some(sign_extend(raw, usize::from(desc.bit_len))?)
        } else {
            None
        };
        let numeric = if let Some(signed) = raw_signed {
            signed as f64
        } else {
            raw as f64
        };

        Some(DecodedSignalValue {
            raw_unsigned: raw,
            raw_signed,
            engineering_value: numeric * desc.factor + desc.offset,
        })
    }
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
