pub const Config = struct {
    charge_limiter: bool = false,
    charge_override: bool = false,
    battery: Battery = .none,
    source: bool = false,
};

pub const Battery = enum {
    none,
    device,
    /// Laptops answer 0 over HID, so read the OS battery instead.
    host,
};

pub const LIMIT_MIN: u8 = 50;
pub const LIMIT_MAX: u8 = 100;
