//! Linux battery telemetry from /sys/class/power_supply.

const std = @import("std");
const battery = @import("battery.zig");

const State = battery.State;
const Reading = battery.Reading;

pub fn read(io: std.Io) !Reading {
    var dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/power_supply", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer dir.close(io);

    return readLinuxDirectory(io, dir);
}

fn readLinuxDirectory(io: std.Io, dir: std.Io.Dir) !Reading {
    var it = dir.iterate();

    while (try it.next(io)) |entry| {
        var supply = try dir.openDir(io, entry.name, .{});
        defer supply.close(io);
        var buffer: [128]u8 = undefined;
        const kind = try text(io, supply, "type", &buffer) orelse continue;

        if (!std.mem.eql(u8, kind, "Battery"))
            continue;

        if (try text(io, supply, "scope", &buffer)) |scope| {
            if (std.mem.eql(u8, scope, "Device"))
                continue;
        }

        if (try number(io, supply, "present")) |present| {
            if (present == 0)
                continue;
        }

        return readLinuxSupply(io, supply);
    }

    return .{};
}

fn text(io: std.Io, dir: std.Io.Dir, name: []const u8, buffer: []u8) !?[]const u8 {
    const contents = dir.readFile(io, name, buffer) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    return std.mem.trim(u8, contents, " \r\n\t");
}

fn number(io: std.Io, dir: std.Io.Dir, name: []const u8) !?f64 {
    const parsed = try signedNumber(io, dir, name) orelse return null;

    if (parsed < 0)
        return error.InvalidBatteryValue;

    return parsed;
}

fn signedNumber(io: std.Io, dir: std.Io.Dir, name: []const u8) !?f64 {
    var buffer: [128]u8 = undefined;
    const value = try text(io, dir, name, &buffer) orelse return null;
    const parsed = try std.fmt.parseInt(i64, value, 10);

    return @floatFromInt(parsed);
}

fn readLinuxSupply(io: std.Io, dir: std.Io.Dir) !Reading {
    var result: Reading = .{};
    var buffer: [128]u8 = undefined;

    if (try text(io, dir, "status", &buffer)) |status|
        result.state = parseState(status);

    if (try number(io, dir, "capacity")) |capacity| {
        if (capacity > 100)
            return error.InvalidBatteryValue;

        result.percent = @intFromFloat(capacity);
    }

    const voltage = try number(io, dir, "voltage_now");
    const energy_voltage = (try number(io, dir, "voltage_min_design")) orelse voltage;

    result.energy = try energy(io, dir, "energy_now", "charge_now", energy_voltage);
    result.energy_full = try energy(io, dir, "energy_full", "charge_full", energy_voltage);
    result.energy_design = try energy(io, dir, "energy_full_design", "charge_full_design", energy_voltage);

    if (result.percent == null) {
        if (result.energy) |remaining| {
            if (result.energy_full) |full| {
                if (full > 0)
                    result.percent = @intFromFloat(@min(100, remaining / full * 100));
            }
        }
    }

    var watts: ?f64 = null;

    if (try signedNumber(io, dir, "power_now")) |power| {
        watts = @abs(power) / 1_000_000;
    } else if (try signedNumber(io, dir, "current_now")) |current| {
        if (voltage) |volts| {
            if (volts > 0)
                watts = @abs(current) * volts / 1_000_000_000_000;
        }
    }

    result.rate = signedRate(result.state, watts);
    return result;
}

fn energy(io: std.Io, dir: std.Io.Dir, energy_name: []const u8, charge_name: []const u8, voltage: ?f64) !?f64 {
    if (try number(io, dir, energy_name)) |value|
        return value / 1_000_000;

    if (voltage) |volts| {
        if (volts > 0) {
            if (try number(io, dir, charge_name)) |charge|
                return charge * volts / 1_000_000_000_000;
        }
    }

    return null;
}

const states: std.StaticStringMap(State) = .initComptime(.{
    .{ "Charging", .charging },
    .{ "Discharging", .discharging },
    .{ "Full", .full },
    .{ "Not charging", .idle },
});

fn parseState(status: []const u8) State {
    return states.get(status) orelse .unknown;
}

fn signedRate(state: State, watts: ?f64) ?f64 {
    const magnitude = watts orelse return null;

    return switch (state) {
        .charging => magnitude,
        .discharging => -magnitude,
        .full, .idle => if (magnitude == 0) 0 else null,
        .unknown => null,
    };
}

test "battery state and signed rate" {
    try std.testing.expectEqual(State.charging, parseState("Charging"));
    try std.testing.expectEqual(State.idle, parseState("Not charging"));
    try std.testing.expectEqual(@as(?f64, -12.5), signedRate(.discharging, 12.5));
    try std.testing.expectEqual(@as(?f64, null), signedRate(.unknown, 12.5));
    try std.testing.expectEqual(@as(?f64, null), signedRate(.idle, null));
}

test "Linux battery telemetry uses energy and power units" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "status", .data = "Discharging\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "capacity", .data = "75\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "energy_now", .data = "45000000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "energy_full", .data = "60000000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "energy_full_design", .data = "65000000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "power_now", .data = "12500000\n" });
    const reading = try readLinuxSupply(io, tmp.dir);

    try std.testing.expectEqual(@as(?u8, 75), reading.percent);
    try std.testing.expectEqual(@as(?f64, -12.5), reading.rate);
    try std.testing.expectEqual(@as(?f64, 45), reading.energy);
    try std.testing.expectEqual(@as(?f64, 60), reading.energy_full);
    try std.testing.expectEqual(@as(?f64, 65), reading.energy_design);
}

test "Linux charge and current telemetry converts with voltage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "status", .data = "Charging\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "voltage_now", .data = "12000000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "voltage_min_design", .data = "10000000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "current_now", .data = "-2000000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "charge_now", .data = "3000000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "charge_full", .data = "4000000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "charge_full_design", .data = "5000000\n" });
    const reading = try readLinuxSupply(io, tmp.dir);

    try std.testing.expectEqual(@as(?u8, 75), reading.percent);
    try std.testing.expectEqual(@as(?f64, 24), reading.rate);
    try std.testing.expectEqual(@as(?f64, 30), reading.energy);
    try std.testing.expectEqual(@as(?f64, 40), reading.energy_full);
    try std.testing.expectEqual(@as(?f64, 50), reading.energy_design);
}

test "zero voltage cannot convert charge or current to energy or power" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "status", .data = "Discharging\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "voltage_now", .data = "0\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "current_now", .data = "2000000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "charge_now", .data = "3000000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "charge_full", .data = "4000000\n" });
    const reading = try readLinuxSupply(io, tmp.dir);

    try std.testing.expect(reading.rate == null);
    try std.testing.expect(reading.energy == null);
    try std.testing.expect(reading.energy_full == null);
}

test "Linux missing telemetry stays unavailable and invalid telemetry fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const reading = try readLinuxSupply(io, tmp.dir);

    try std.testing.expect(reading.rate == null and reading.energy == null and reading.percent == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "capacity", .data = "101\n" });
    try std.testing.expectError(error.InvalidBatteryValue, readLinuxSupply(io, tmp.dir));
}
