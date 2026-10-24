const device = @import("device_types");
const lighting = @import("features/lighting_types");

pub const descriptor = device.Descriptor{
    .pid = 0x0239,
    .provenance = .transcribed,
    .name = "Razer Blade Stealth 13 (2019)",
    .category = .system,
    .features = .{
        .system_performance = .{
            .modes = &.{
                .{ .name = "balanced", .wire = 0x00 },
                // Creator uses the Gaming wire value on this model.
                .{ .name = "productivity_creator", .wire = 0x01 },
                .{ .name = "battery_saver", .wire = 0x03 },
            },
            .fan_range = .{ .min = 2200, .max = 5500 },
            .fan_speed = true,
            .cpu_temp = true,
        },
        .lighting = .{
            .protocol = .legacy_rows,
            .control_interface = 2,
            .frame_latch = true,
            .layouts = &.{
                .{ .rows = 1, .columns = 16 },
            },
            .zones = &.{
                .{ .id = 0x05, .name = "backlight", .brightness = true, .effects = &lighting.SINGLE, .frame = .{} },
            },
        },
        .power = .{ .battery = .host },
    },
};
