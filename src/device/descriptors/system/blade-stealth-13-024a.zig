const device = @import("device_types");
const lighting = @import("features/lighting_types");

pub const descriptor = device.Descriptor{
    .pid = 0x024a,
    .provenance = .transcribed,
    .name = "Razer Blade Stealth 13 (2019)",
    .category = .system,
    .features = .{
        .system_performance = .{
            .modes = &.{
                .{ .name = "balanced", .wire = 0x00 },
                .{ .name = "battery_saver", .wire = 0x03 },
                .{ .name = "gaming", .wire = 0x01 },
            },
            .fan_range = .{ .min = 2500, .max = 5500 },
            .fan_speed = true,
            .cpu_temp = true,
        },
        .lighting = .{
            .key_maps = &.{
                .{ .edition = 0, .layout = 1, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_86f36587251e },
                .{ .edition = 0, .layout = 3, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_52007749a6df },
                .{ .edition = 0, .layout = 4, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_52007749a6df },
                .{ .edition = 0, .layout = 6, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_52007749a6df },
                .{ .edition = 0, .layout = 7, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_52007749a6df },
                .{ .edition = 0, .layout = 8, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_52007749a6df },
                .{ .edition = 0, .layout = 9, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_86f36587251e },
                .{ .edition = 0, .layout = 12, .rows = 1, .columns = 16, .entries = &lighting.key_maps.map_8415f2de2f1b },
            },
            .protocol = .legacy_rows,
            .control_interface = 2,
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
