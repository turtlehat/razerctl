const device = @import("device_types");
const lighting = @import("features/lighting_types");

pub const descriptor = device.Descriptor{
    .pid = 0x02e1,
    .provenance = .transcribed,
    .name = "Razer Blade 18",
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
        .display = .{ .local_dimming = true },
        .lighting = .{
            .key_maps = &.{
                .{ .edition = 0, .layout = 1, .rows = 1, .columns = 114, .entries = &lighting.key_maps.map_e2dd9a5cf3ce },
                .{ .edition = 0, .layout = 3, .rows = 1, .columns = 114, .entries = &lighting.key_maps.map_96cceed9d975 },
                .{ .edition = 0, .layout = 4, .rows = 1, .columns = 114, .entries = &lighting.key_maps.map_96cceed9d975 },
                .{ .edition = 0, .layout = 6, .rows = 1, .columns = 114, .entries = &lighting.key_maps.map_96cceed9d975 },
                .{ .edition = 0, .layout = 7, .rows = 1, .columns = 114, .entries = &lighting.key_maps.map_96cceed9d975 },
                .{ .edition = 0, .layout = 8, .rows = 1, .columns = 114, .entries = &lighting.key_maps.map_e2dd9a5cf3ce },
                .{ .edition = 0, .layout = 9, .rows = 1, .columns = 114, .entries = &lighting.key_maps.map_e2dd9a5cf3ce },
                .{ .edition = 0, .layout = 12, .rows = 1, .columns = 114, .entries = &lighting.key_maps.map_5c357552ed29 },
                .{ .edition = 0, .layout = 16, .rows = 1, .columns = 114, .entries = &lighting.key_maps.map_96cceed9d975 },
            },
            .protocol = .large_matrix,
            .control_interface = 2,
            .frame_interface = 3,
            .layouts = &.{
                .{ .rows = 1, .columns = 114 },
            },
            .zones = &.{
                .{ .id = 0x05, .name = "backlight", .brightness = true, .effects = &lighting.MATRIX_REACTIVE, .frame = .{} },
                .{ .id = 0x04, .name = "logo", .effects = &lighting.MONO },
            },
        },
        .power = .{ .charge_limiter = true, .charge_override = true, .battery = .host },
    },
};
