const device = @import("device_types");
const lighting = @import("features/lighting_types");

pub const descriptor = device.Descriptor{
    .pid = 0x02c7,
    .provenance = .transcribed,
    .name = "Razer Blade 18 (2025)",
    .category = .system,
    .features = .{
        .system_performance = .{
            .modes = &.{
                .{ .name = "balanced", .wire = 0x00 },
                .{ .name = "silent", .wire = 0x05 },
                .{ .name = "performance", .wire = 0x02 },
                .{ .name = "turbo", .wire = 0x01 },
                .{ .name = "custom", .wire = 0x04 },
                .{ .name = "battery_saver", .wire = 0x03 },
            },
            .wattage = .{
                .cpu = &.{
                    .{ .name = "low", .wire = 0 },
                    .{ .name = "medium", .wire = 1 },
                    .{ .name = "high", .wire = 2 },
                    .{ .name = "max", .wire = 3 },
                },
                .gpu = &.{
                    .{ .name = "low", .wire = 0 },
                    .{ .name = "medium", .wire = 1 },
                    .{ .name = "high", .wire = 2 },
                    .{ .name = "max", .wire = 3 },
                },
            },
            .fan_speed = true,
            .cpu_temp = true,
        },
        .lighting = .{
            .key_maps = &.{
                .{ .edition = 0, .layout = 1, .rows = 7, .columns = 19, .entries = &lighting.key_maps.map_bba1570f5645 },
                .{ .edition = 0, .layout = 3, .rows = 7, .columns = 19, .entries = &lighting.key_maps.map_8aa4b8129ce6 },
                .{ .edition = 0, .layout = 4, .rows = 7, .columns = 19, .entries = &lighting.key_maps.map_8aa4b8129ce6 },
                .{ .edition = 0, .layout = 6, .rows = 7, .columns = 19, .entries = &lighting.key_maps.map_8aa4b8129ce6 },
                .{ .edition = 0, .layout = 7, .rows = 7, .columns = 19, .entries = &lighting.key_maps.map_8aa4b8129ce6 },
                .{ .edition = 0, .layout = 8, .rows = 7, .columns = 19, .entries = &lighting.key_maps.map_bba1570f5645 },
                .{ .edition = 0, .layout = 9, .rows = 7, .columns = 19, .entries = &lighting.key_maps.map_bba1570f5645 },
                .{ .edition = 0, .layout = 12, .rows = 7, .columns = 19, .entries = &lighting.key_maps.map_0d1abf9a1052 },
                .{ .edition = 0, .layout = 16, .rows = 7, .columns = 19, .entries = &lighting.key_maps.map_8aa4b8129ce6 },
            },
            .protocol = .legacy_rows,
            .control_interface = 2,
            .layouts = &.{
                .{ .rows = 7, .columns = 19 },
            },
            .zones = &.{
                .{ .id = 0x05, .name = "backlight", .brightness = true, .effects = &lighting.MATRIX_REACTIVE, .frame = .{} },
                .{ .id = 0x04, .name = "logo", .effects = &lighting.MONO },
            },
        },
        .power = .{ .charge_limiter = true, .charge_override = true, .battery = .host },
    },
};
