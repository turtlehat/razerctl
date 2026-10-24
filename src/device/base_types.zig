//! Device-independent values used to declare device capabilities.

pub const Mode = struct { name: []const u8, wire: u8 };
pub const Range = struct { min: u16, max: u16 };
