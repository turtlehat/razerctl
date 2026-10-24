//! Laptop performance modes, fans, CPU/GPU wattage and temperature.

const device = @import("device_types");
const transport = @import("transport");
const power_mode = @import("power_mode");
const ui = @import("ui");
const probe_result = @import("probe_result");
const setting_types = @import("setting_types");
const capability = @import("features/system_performance_types");
const std = @import("std");

pub const title = "Performance";
pub const order = 1;

pub const Config = capability.Config;

pub const Wattage = capability.Wattage;

pub fn settings(desc: *const device.Descriptor, s: *setting_types.Settings) !void {
    const allocator = s.allocator;
    const perf = desc.features.system_performance;
    const custom = "Custom mode only.";

    if (perf.modes.len > 0)
        try s.add(.{
            .usage = .{ .name = "mode", .params = &.{.{ .arg = .{ .choices = try ui.names(allocator, perf.modes) } }} },
            .read = readMode,
            .write = writeMode,
        });

    if (perf.wattage.cpu.len > 0) {
        try s.add(.{
            .usage = .{
                .name = "custom-cpu",
                .params = &.{.{ .arg = .{ .choices = try ui.names(allocator, perf.wattage.cpu) } }},
                .note = custom,
            },
            .ctx = @backingInt(Axis.cpu),
            .read = readWattage,
            .write = writeWattage,
        });
        try s.add(.{
            .usage = .{
                .name = "custom-gpu",
                .params = &.{.{ .arg = .{ .choices = try ui.names(allocator, perf.wattage.gpu) } }},
                .note = custom,
            },
            .ctx = @backingInt(Axis.gpu),
            .read = readWattage,
            .write = writeWattage,
        });
    }

    if (perf.max_fan)
        try s.add(.{
            .usage = .{ .name = "custom-max-fan", .params = &.{.{ .arg = .toggle }}, .note = custom },
            .read = readMaxFan,
            .write = writeMaxFan,
        });

    // Below the hardware floor, the EC stores the setpoint but spins at the floor.
    if (perf.fan_range) |r|
        try s.add(.{
            .usage = .{
                .name = "fan",
                .params = &.{.{ .arg = .{ .range = .{ .min = r.min, .max = r.max, .extra = "auto" } } }},
            },
            .read = readFan,
            .write = writeFan,
            .unit = .rpm,
        });

    if (perf.fan_speed) {
        var zone: u16 = 1;

        while (zone <= perf.zones) : (zone += 1)
            try s.add(.{
                .usage = .{ .name = if (perf.zones == 1) "fan-speed" else try allocator.print("fan-speed-{d}", .{zone}) },
                .ctx = @intCast(zone),
                .read = readFanSpeed,
                .unit = .rpm,
            });
    }

    if (perf.gpu_mode)
        try s.add(.{
            .usage = .{ .name = "gpu-mode", .note = "Optimus or dGPU only; changes require Synapse and a restart." },
            .read = readGpuMode,
        });

    if (perf.cpu_temp)
        try s.add(.{ .usage = .{ .name = "cpu-temp" }, .read = readCpuTemp, .unit = .celsius });

    if (perf.gpu_temp)
        try s.add(.{
            .usage = .{ .name = "gpu-temp", .note = "Off while the GPU sleeps." },
            .read = readGpuTemp,
            .unit = .celsius,
        });
}

// Firmware-selected on battery; recognized on reads, not offered for writes.
const normal_mode = device.Mode{ .name = "normal", .wire = 0x06 };

fn readMode(allocator: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, _: u8) !setting_types.Reading {
    const cur = try getPerf(hid, desc);
    const name = device.nameFor(desc.features.system_performance.modes, cur.mode) orelse
        device.nameFor(&.{normal_mode}, cur.mode);

    return .{ .val = .{ .str = try ui.nameOr(allocator, name, cur.mode) } };
}

fn writeMode(_: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, _: u8, in: setting_types.Input) !void {
    const cur = try getPerf(hid, desc);

    try setPerf(hid, desc, desc.features.system_performance.modes[in.choice].wire, cur.fan);
}

fn levels(desc: *const device.Descriptor, axis: u8) []const device.Mode {
    const tiers = desc.features.system_performance.wattage;

    return if (axis == @backingInt(Axis.cpu)) tiers.cpu else tiers.gpu;
}

/// Readable in every mode, but effective only in Custom.
fn readWattage(allocator: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, axis: u8) !setting_types.Reading {
    const v = try getWattage(hid, @fromBackingInt(@intCast(axis)));

    return .{ .val = .{ .str = try ui.nameOr(allocator, device.nameFor(levels(desc, axis), v), v) } };
}

fn writeWattage(_: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, axis: u8, in: setting_types.Input) !void {
    try setWattage(hid, @fromBackingInt(@intCast(axis)), levels(desc, axis)[in.choice].wire);
}

/// The setpoint register keeps its last manual value while on auto, so
/// reporting it then would describe a speed that is not in effect.
fn readFan(_: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, _: u8) !setting_types.Reading {
    const cur = try getPerf(hid, desc);

    if (cur.fan == .auto)
        return .{ .val = .{ .str = "auto" } };

    return .{ .val = .{ .num = try getSetpoint(hid, desc, 1) } };
}

fn writeFan(_: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, _: u8, in: setting_types.Input) !void {
    const cur = try getPerf(hid, desc);

    switch (in) {
        .num => |rpm| {
            try setPerf(hid, desc, cur.mode, .manual);
            try setFanRpm(hid, desc, device.snap(rpm, desc.features.system_performance.scale));
        },
        else => try setPerf(hid, desc, cur.mode, .auto),
    }
}

fn readMaxFan(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !setting_types.Reading {
    return .{ .val = .{ .flag = try power_mode.read(hid, .max_fan) } };
}

fn writeMaxFan(_: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, _: u8, in: setting_types.Input) !void {
    const was_on = try power_mode.write(hid, .max_fan, in.flag);

    if (in.flag or !was_on)
        return;

    // Clearing max fan leaves the fans wherever it put them. The setpoint
    // register still holds the manual value, so writing it back re-asserts it.
    const p = try getPerf(hid, desc);

    if (p.fan != .manual)
        return;

    const sp = try getSetpoint(hid, desc, 1);

    try setFanRpm(hid, desc, sp);
}

const gpu_modes = [_]device.Mode{
    .{ .name = "optimus", .wire = 0 },
    .{ .name = "dgpu", .wire = 1 },
};

fn readGpuMode(allocator: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !setting_types.Reading {
    const v = (try hid.call(GET_GPU_MODE, &.{ 0, 0 })).argSlice()[1];

    return .{ .val = .{ .str = try ui.nameOr(allocator, device.nameFor(&gpu_modes, v), v) } };
}

fn readFanSpeed(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, zone: u8) !setting_types.Reading {
    return .{ .val = .{ .num = try getActualRpm(hid, zone) } };
}

fn readCpuTemp(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !setting_types.Reading {
    return .{ .val = .{ .num = (try getTemperature(hid)).cpu } };
}

fn readGpuTemp(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !setting_types.Reading {
    const t = (try getTemperature(hid)).gpu;

    return .{ .val = if (t == 0) .{ .flag = false } else .{ .num = t } };
}

/// Thermal Fan Mode: [1, zone, mode, fanmode].
const SET_PERF: transport.Command = .{ .id = 0x0d02 };
const GET_PERF: transport.Command = .{ .id = 0x0d82, .min_response = 4 };
/// Thermal Fan Speed, the setpoint: [0, zone, rpm/scale].
const SET_FAN_SPEED: transport.Command = .{ .id = 0x0d01 };
const GET_FAN_SPEED: transport.Command = .{ .id = 0x0d81, .min_response = 3 };
/// Thermal Advance Fan Mode Wattage: [1, axis, level].
const SET_WATTAGE: transport.Command = .{ .id = 0x0d07 };
const GET_WATTAGE: transport.Command = .{ .id = 0x0d87, .min_response = 3 };
const GET_ACTUAL: transport.Command = .{ .id = 0x0d88, .min_response = 3 };
const GET_TEMPERATURE: transport.Command = .{ .id = 0x0d85, .min_response = 3 };
/// VGA configure: [total, mode]. Set (0x0d09) needs a restart, so it is not offered.
const GET_GPU_MODE: transport.Command = .{ .id = 0x0d89, .min_response = 2 };
/// Fan Information. Not decoded; probe reports it raw.
const GET_FAN_INFO: transport.Command = .{ .id = 0x0d83 };
const FanMode = enum(u8) { auto = 0, manual = 1 };
const State = struct { mode: u8, fan: FanMode };
const Axis = enum(u8) { cpu = 1, gpu = 2 };

fn readPerfZone(hid: *transport.Device, zone: u8) !State {
    const r = try hid.call(GET_PERF, &.{ 0, zone, 0, 0 });
    const a = r.argSlice();

    return .{ .mode = a[2], .fan = @fromBackingInt(@intCast(a[3] & 1)) };
}

/// Every zone must agree. `zones` is inherited across chassis, so a NotSupported zone is skipped.
fn getPerf(hid: *transport.Device, desc: *const device.Descriptor) !State {
    var first: ?State = null;
    var zone: u8 = 1;

    while (zone <= desc.features.system_performance.zones) : (zone += 1) {
        const s = readPerfZone(hid, zone) catch |e| {
            if (e == error.NotSupported)
                continue;

            return e;
        };

        if (first) |f| {
            if (f.mode != s.mode)
                return transport.Error.BadResponse;
        } else first = s;
    }

    return first orelse transport.Error.ReadFailed;
}

fn setPerf(hid: *transport.Device, desc: *const device.Descriptor, mode_wire: u8, fan_mode: FanMode) !void {
    try eachZone(desc, setPerfZone, .{ hid, mode_wire, fan_mode });
}

fn setPerfZone(hid: *transport.Device, mode_wire: u8, fan_mode: FanMode, zone: u8) !void {
    _ = try hid.call(SET_PERF, &.{ 1, zone, mode_wire, @backingInt(fan_mode) });
}

/// Writes every zone. `zones` is inherited across chassis, so a later NotSupported zone ends the list.
fn eachZone(desc: *const device.Descriptor, comptime write: anytype, args: anytype) !void {
    var zone: u8 = 1;

    while (zone <= desc.features.system_performance.zones) : (zone += 1)
        @call(.auto, write, args ++ .{zone}) catch |e| {
            if (e == error.NotSupported and zone > 1)
                return;

            return e;
        };
}

fn getSetpoint(hid: *transport.Device, desc: *const device.Descriptor, zone: u8) !u16 {
    const r = try hid.call(GET_FAN_SPEED, &.{ 0, zone, 0 });

    return @as(u16, r.argSlice()[2]) * desc.features.system_performance.scale;
}

fn setFanRpm(hid: *transport.Device, desc: *const device.Descriptor, rpm: u16) !void {
    try eachZone(desc, setFanRpmZone, .{ hid, desc, rpm });
}

fn setFanRpmZone(hid: *transport.Device, desc: *const device.Descriptor, rpm: u16, zone: u8) !void {
    const wire: u8 = @intCast(rpm / desc.features.system_performance.scale);

    _ = try hid.call(SET_FAN_SPEED, &.{ 0, zone, wire });
}

fn getWattage(hid: *transport.Device, axis: Axis) !u8 {
    const r = try hid.call(GET_WATTAGE, &.{ 0, @backingInt(axis), 0 });

    return r.argSlice()[2];
}

fn setWattage(hid: *transport.Device, axis: Axis, level: u8) !void {
    _ = try hid.call(SET_WATTAGE, &.{ 1, @backingInt(axis), level });
}

fn getActualRpm(hid: *transport.Device, zone: u8) !u16 {
    const r = try hid.call(GET_ACTUAL, &.{ 0, zone, 0 });
    const a = r.argSlice();

    if (a[1] != zone)
        return transport.Error.BadResponse;

    return @as(u16, a[2]) * 100;
}

const Temperature = struct { cpu: u8, gpu: u8 };

fn getTemperature(hid: *transport.Device) !Temperature {
    const a = (try hid.call(GET_TEMPERATURE, &@as([80]u8, @splat(0)))).argSlice();

    return .{ .cpu = a[1], .gpu = a[2] };
}

pub fn probe(hid: *transport.Device, p: *probe_result.ProbeResult) !void {
    const allocator = p.table.allocator;

    if (getActualRpm(hid, 1)) |rpm|
        try p.add(GET_ACTUAL, "fan current speed", try allocator.print("{d} rpm", .{rpm}))
    else |err|
        try p.failure(GET_ACTUAL, "fan current speed", err);

    if (getTemperature(hid)) |t|
        try p.add(GET_TEMPERATURE, "temperature", try allocator.print("cpu {d} C, gpu {d} C", .{ t.cpu, t.gpu }))
    else |err|
        try p.failure(GET_TEMPERATURE, "temperature", err);
    try p.reply(GET_FAN_INFO, "fan information", hid.call(GET_FAN_INFO, &@as([12]u8, @splat(0))), 12);
    try p.reply(GET_FAN_SPEED, "fan setpoint", hid.call(GET_FAN_SPEED, &.{ 0, 1, 0 }), 3);
    try p.reply(GET_PERF, "fan mode", hid.call(GET_PERF, &.{ 0, 1, 0, 0 }), 4);
    try p.reply(GET_WATTAGE, "wattage", hid.call(GET_WATTAGE, &.{ 0, 1, 0 }), 3);
    try p.reply(GET_GPU_MODE, "gpu mode", hid.call(GET_GPU_MODE, &.{ 0, 0 }), 2);
}

test "fan tachometer selectors address each declared zone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var desc: device.Descriptor = .{ .pid = 0, .name = "Test", .category = .system };

    desc.features.system_performance = .{ .fan_speed = true, .zones = 2 };
    var multiple = setting_types.Settings.init(arena.allocator());

    try settings(&desc, &multiple);
    try std.testing.expectEqual(@as(usize, 2), multiple.items.items.len);

    for (multiple.items.items, 1..) |s, zone| {
        try std.testing.expectEqualStrings(try arena.allocator().print("fan-speed-{d}", .{zone}), s.usage.name);
        try std.testing.expectEqual(@as(u8, @intCast(zone)), s.ctx);
        try std.testing.expect(s.read != null and s.write == null);
        try std.testing.expectEqual(ui.Unit.rpm, s.unit);
    }

    desc.features.system_performance.zones = 1;
    var single = setting_types.Settings.init(arena.allocator());

    try settings(&desc, &single);
    try std.testing.expectEqual(@as(usize, 1), single.items.items.len);
    try std.testing.expectEqualStrings("fan-speed", single.items.items[0].usage.name);
    try std.testing.expectEqual(@as(u8, 1), single.items.items[0].ctx);

    desc.features.system_performance.fan_speed = false;
    var unsupported = setting_types.Settings.init(arena.allocator());

    try settings(&desc, &unsupported);
    try std.testing.expectEqual(@as(usize, 0), unsupported.items.items.len);
}
