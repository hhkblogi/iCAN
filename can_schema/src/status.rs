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
