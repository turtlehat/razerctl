pub const Config = struct {
    presets: []const FanPreset = &.{},
    scale: u16 = 100,
};

pub const FanPreset = struct { name: []const u8, wire: u8, min: u16, max: u16 };
