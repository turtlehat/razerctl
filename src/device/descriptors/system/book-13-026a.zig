const device = @import("device_types");
const lighting = @import("features/lighting_types");

pub const descriptor = device.Descriptor{
    .pid = 0x026a,
    .provenance = .transcribed,
    .name = "Razer Book 13 (2020)",
    .category = .system,
    .features = .{
        .system_performance = .{
            .modes = &.{
                .{ .name = "balanced", .wire = 0x00 },
                .{ .name = "performance", .wire = 0x02 },
                .{ .name = "battery_saver", .wire = 0x03 },
            },
            .fan_range = .{ .min = 2700, .max = 5500 },
            .fan_speed = true,
            .cpu_temp = true,
        },
        .lighting = .{
            .key_maps = &.{
                .{ .edition = 0, .layout = 1, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_e3865cb82790 },
                .{ .edition = 0, .layout = 3, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_8fbd83431703 },
                .{ .edition = 0, .layout = 4, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_8fbd83431703 },
                .{ .edition = 0, .layout = 6, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_8fbd83431703 },
                .{ .edition = 0, .layout = 7, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_8fbd83431703 },
                .{ .edition = 0, .layout = 8, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_e3865cb82790 },
                .{ .edition = 0, .layout = 9, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_e3865cb82790 },
                .{ .edition = 0, .layout = 12, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_db2728af6af1 },
                .{ .edition = 0, .layout = 16, .rows = 6, .columns = 16, .entries = &lighting.key_maps.map_8fbd83431703 },
            },
            .protocol = .legacy_rows,
            .control_interface = 2,
            .layouts = &.{
                .{ .rows = 6, .columns = 16 },
            },
            .zones = &.{
                .{ .id = 0x05, .name = "backlight", .brightness = true, .effects = &lighting.MATRIX_REACTIVE, .frame = .{} },
            },
        },
        .power = .{ .battery = .host },
    },
};
