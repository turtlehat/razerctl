pub const Config = struct {
    dpi: Dpi = .{},
    polling: Polling = .{},
};

pub const Dpi = struct {
    min: u16 = 0,
    max: u16 = 0,
    step: u16 = 0,
    xy: bool = false,
};

pub const Polling = struct {
    rates: []const u16 = &.{},
    /// Rates reachable only through the HyperPolling dongle.
    hyper: []const u16 = &.{},
};
