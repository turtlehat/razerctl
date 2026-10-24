const device = @import("device_base_types");

pub const Config = struct {
    modes: []const device.Mode = &.{},
    fan_range: ?device.Range = null,
    fan_speed: bool = false,
    cpu_temp: bool = false,
    gpu_temp: bool = false,
    scale: u16 = 100,
    zones: u8 = 2,
    wattage: Wattage = .{},
    max_fan: bool = false,
    gpu_mode: bool = false,
};

pub const Wattage = struct {
    cpu: []const device.Mode = &.{},
    gpu: []const device.Mode = &.{},
};
