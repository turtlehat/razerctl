const device = @import("device_types");
const lighting = @import("features/lighting_types");

pub const descriptor = device.Descriptor{
    .pid = 0x02b6,
    .name = "Razer Blade 14 (2024)",
    .provenance = .measured,
    .category = .system,
    .features = .{
        .system_performance = .{
            .modes = &.{
                .{ .name = "silent", .wire = 0x05 },
                .{ .name = "balanced", .wire = 0x00 },
                .{ .name = "turbo", .wire = 0x01 },
                .{ .name = "custom", .wire = 0x04 },
            },
            .wattage = .{
                .cpu = &.{
                    .{ .name = "low", .wire = 0 },
                    .{ .name = "medium", .wire = 1 },
                    .{ .name = "high", .wire = 2 },
                    .{ .name = "boost", .wire = 3 },
                    .{ .name = "optimizer", .wire = 4 },
                },
                .gpu = &.{
                    .{ .name = "low", .wire = 0 },
                    .{ .name = "medium", .wire = 1 },
                    .{ .name = "high", .wire = 2 },
                },
            },
            .fan_range = .{ .min = 2000, .max = 5400 },
            .max_fan = true,
            .fan_speed = true,
            .cpu_temp = true,
            .gpu_temp = true,
            .gpu_mode = true,
        },
        .lighting = .{
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
        .power = .{
            .charge_limiter = true,
            .charge_override = true,
            .source = true,
            .battery = .host,
        },
        .device = .{ .firmware = true, .driver_mode = true },
    },
};
