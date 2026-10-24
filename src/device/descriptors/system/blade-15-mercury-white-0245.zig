const device = @import("device_types");
const lighting = @import("features/lighting_types");

pub const descriptor = device.Descriptor{
    .pid = 0x0245,
    .provenance = .transcribed,
    .name = "Razer Blade 15 Mercury White (2019)",
    .category = .system,
    .features = .{
        .system_performance = .{
            .modes = &.{
                .{ .name = "balanced", .wire = 0x00 },
                .{ .name = "custom", .wire = 0x04 },
            },
            .wattage = .{
                .cpu = &.{
                    .{ .name = "low", .wire = 0 },
                    .{ .name = "medium", .wire = 1 },
                    .{ .name = "high", .wire = 2 },
                },
                .gpu = &.{
                    .{ .name = "low", .wire = 0 },
                    .{ .name = "medium", .wire = 1 },
                    .{ .name = "high", .wire = 2 },
                },
            },
            .fan_range = .{ .min = 3700, .max = 5300 },
            .fan_speed = true,
            .cpu_temp = true,
        },
        .lighting = .{
            .key_maps = &.{
                .{ .edition = 0, .layout = 1, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_c6ca9c523d61 },
                .{ .edition = 0, .layout = 3, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_f00de0f5ccf7 },
                .{ .edition = 0, .layout = 4, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_f00de0f5ccf7 },
                .{ .edition = 0, .layout = 6, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_f00de0f5ccf7 },
                .{ .edition = 0, .layout = 7, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_f00de0f5ccf7 },
                .{ .edition = 0, .layout = 8, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_f00de0f5ccf7 },
                .{ .edition = 0, .layout = 9, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_c6ca9c523d61 },
                .{ .edition = 0, .layout = 12, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_d2f07b788f95 },
            },
            .protocol = .legacy_rows,
            .control_interface = 2,
            .layouts = &.{
                .{ .rows = 6, .columns = 16 },
            },
            .zones = &.{
                .{ .id = 0x05, .name = "backlight", .brightness = true, .effects = &lighting.MATRIX_REACTIVE, .frame = .{} },
                .{ .id = 0x04, .name = "logo", .effects = &lighting.MONO },
            },
        },
        .power = .{ .battery = .host },
    },
};
