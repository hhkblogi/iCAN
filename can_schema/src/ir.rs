#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ByteOrder {
    LittleEndian,
    BigEndian,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ChoiceIr {
    pub raw_value: i64,
    pub label: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MuxRoleIr {
    None,
    Multiplexor,
    Multiplexed { selector_value: u64 },
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
    pub choices: Vec<ChoiceIr>,
    pub mux_role: MuxRoleIr,
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
