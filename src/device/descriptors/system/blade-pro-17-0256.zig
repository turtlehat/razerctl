const device = @import("device_types");
const lighting = @import("features/lighting_types");

pub const descriptor = device.Descriptor{
    .pid = 0x0256,
    .provenance = .transcribed,
    .name = "Razer Blade Pro 17 (2020)",
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
                    .{ .name = "boost", .wire = 3 },
                },
                .gpu = &.{
                    .{ .name = "low", .wire = 0 },
                    .{ .name = "medium", .wire = 1 },
                    .{ .name = "high", .wire = 2 },
                },
            },
            .fan_range = .{ .min = 2300, .max = 4300 },
            .fan_speed = true,
            .cpu_temp = true,
        },
        .lighting = .{
            .key_maps = &.{
                .{ .edition = 0, .layout = 1, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_3381bde83a4a },
                .{ .edition = 0, .layout = 3, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_b52df3ea35ad },
                .{ .edition = 0, .layout = 4, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_b52df3ea35ad },
                .{ .edition = 0, .layout = 6, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_b52df3ea35ad },
                .{ .edition = 0, .layout = 7, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_b52df3ea35ad },
                .{ .edition = 0, .layout = 8, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_3381bde83a4a },
                .{ .edition = 0, .layout = 9, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_3381bde83a4a },
                .{ .edition = 0, .layout = 12, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_743643bcbfbf },
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
