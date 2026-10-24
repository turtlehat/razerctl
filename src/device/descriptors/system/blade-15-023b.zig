const device = @import("device_types");
const lighting = @import("features/lighting_types");

pub const descriptor = device.Descriptor{
    .pid = 0x023b,
    .provenance = .transcribed,
    .name = "Razer Blade 15 (2018)",
    .category = .system,
    .features = .{
        .system_performance = .{
            .modes = &.{
                .{ .name = "balanced", .wire = 0x00 },
                .{ .name = "gaming", .wire = 0x01 },
            },
            .fan_range = .{ .min = 3700, .max = 5300 },
            .fan_speed = true,
            .cpu_temp = true,
        },
        .lighting = .{
            .key_maps = &.{
                .{ .edition = 0, .layout = 1, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_e7306fec6051 },
                .{ .edition = 0, .layout = 3, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_a82655a97140 },
                .{ .edition = 0, .layout = 4, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_a82655a97140 },
                .{ .edition = 0, .layout = 6, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_a82655a97140 },
                .{ .edition = 0, .layout = 7, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_a82655a97140 },
                .{ .edition = 0, .layout = 8, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_81732c79b2fd },
                .{ .edition = 0, .layout = 12, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_743643bcbfbf },
            },
            .protocol = .legacy_rows,
            .control_interface = 2,
            .frame_latch = true,
            .layouts = &.{
                .{ .edition = 0, .layout = 1, .rows = 1, .columns = 16 },
                .{ .edition = 0, .layout = 3, .rows = 1, .columns = 16 },
                .{ .edition = 0, .layout = 4, .rows = 1, .columns = 16 },
                .{ .edition = 0, .layout = 6, .rows = 1, .columns = 16 },
                .{ .edition = 0, .layout = 7, .rows = 1, .columns = 16 },
                .{ .edition = 0, .layout = 8, .rows = 1, .columns = 16 },
                .{ .edition = 0, .layout = 12, .rows = 6, .columns = 16 },
            },
            .zones = &.{
                .{ .id = 0x05, .name = "backlight", .brightness = true, .effects = &lighting.SINGLE, .frame = .{} },
            },
        },
        .power = .{ .battery = .host },
    },
};
