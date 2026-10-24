//! Mouse and keyboard sensor resolution and polling rate.

const std = @import("std");
const device = @import("device_types");
const transport = @import("transport");
const ui = @import("ui");
const probe_result = @import("probe_result");
const setting_types = @import("setting_types");
const capability = @import("features/input_performance_types");

pub const title = "Performance";
pub const order = 3;

pub const Config = capability.Config;

pub const Dpi = capability.Dpi;

pub const Polling = capability.Polling;

pub fn settings(desc: *const device.Descriptor, s: *setting_types.Settings) !void {
    const allocator = s.allocator;
    const f = desc.features.input_performance;

    if (f.dpi.max > 0) {
        const range: ui.Param = .{ .arg = .{ .range = .{ .min = f.dpi.min, .max = f.dpi.max } } };

        try s.add(.{
            .usage = .{
                .name = "dpi",
                .params = &.{range},
                .note = if (f.dpi.xy) "Sets both X and Y." else "",
            },
            .read = readDpi,
            .write = writeDpi,
            .prepare = prepareDpi,
        });

        if (f.dpi.xy)
            try s.add(.{
                .usage = .{
                    .name = "dpi-y",
                    .params = &.{range},
                    .note = "Overrides Y separately.",
                },
                .ctx = 1,
                .read = readDpi,
                .write = writeDpi,
                .prepare = prepareDpi,
            });
    }

    if (f.polling.rates.len > 0)
        try s.add(.{
            .usage = .{
                .name = "polling",
                .params = &.{.{ .arg = .{ .choices = try rateNames(allocator, f.polling.rates) } }},
                .note = try pollingNote(allocator, f.polling),
            },
            .read = readPolling,
            .write = writePolling,
            .unit = .hz,
        });
}

fn rateNames(allocator: std.mem.Allocator, rates: []const u16) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, rates.len);

    for (rates, names) |r, *n|
        n.* = try allocator.print("{d}", .{r});

    return names;
}

/// Dongle-only rates are informational, not accepted values.
fn pollingNote(allocator: std.mem.Allocator, polling: Polling) ![]const u8 {
    const hyper = top(polling.hyper);

    if (hyper > top(polling.rates))
        return try allocator.print("Report rate in Hz; {d} with the HyperPolling dongle.", .{hyper});

    return "Report rate in Hz.";
}

fn top(rates: []const u16) u16 {
    return if (rates.len > 0) rates[rates.len - 1] else 0;
}

test "polling note" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("Report rate in Hz; 4000 with the HyperPolling dongle.", try pollingNote(allocator, .{ .rates = &.{ 125, 500, 1000 }, .hyper = &.{ 125, 500, 1000, 2000, 4000 } }));
    try std.testing.expectEqualStrings("Report rate in Hz.", try pollingNote(allocator, .{ .rates = &.{ 250, 1000 } }));
}

/// `ctx` 0 is X, 1 is Y.
fn readDpi(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, axis: u8) !setting_types.Reading {
    const d = try getDpi(hid);

    return .{ .val = .{ .num = if (axis == 0) d.x else d.y } };
}

/// Apply DPI to both axes before an optional DPI-Y override.
fn writeDpi(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, axis: u8, in: setting_types.Input) !void {
    const v = in.num;

    const now = if (axis == 0) Resolution{ .x = v, .y = v } else Resolution{ .x = (try getDpi(hid)).x, .y = v };

    try setDpi(hid, now);
}

fn prepareDpi(allocator: std.mem.Allocator, desc: *const device.Descriptor, _: u8, in: setting_types.Input) !ui.Result(setting_types.Input) {
    const step = desc.features.input_performance.dpi.step;

    if (step > 1 and in.num % step != 0)
        return .{ .failure = .{ .message = try allocator.print("dpi goes in steps of {d} -- got {d}", .{ step, in.num }) } };

    return .{ .success = in };
}

fn readPolling(_: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, _: u8) !setting_types.Reading {
    return .{ .val = .{ .num = try getPolling(hid, desc.features.input_performance.polling) } };
}

fn writePolling(_: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, _: u8, in: setting_types.Input) !void {
    const polling = desc.features.input_performance.polling;

    try setPolling(hid, polling, polling.rates[in.choice]);
}

// These registers have not been verified on hardware.

/// NOSTORE reads and writes what is live; VARSTORE also saves it on the device.
const NOSTORE: u8 = 0x00;
const VARSTORE: u8 = 0x01;

/// [store, x_hi, x_lo, y_hi, y_lo, 0, 0].
const GET_DPI: transport.Command = .{ .id = 0x0485, .min_response = 5 };
const SET_DPI: transport.Command = .{ .id = 0x0405 };
/// Not decoded; probe reports it raw.
const GET_DPI_DATA: transport.Command = .{ .id = 0x0486 };
/// Get/Set Device Polling Period: [period_ms], so 1 = 1000 Hz and 8 = 125 Hz.
const GET_POLLING: transport.Command = .{ .id = 0x0085, .min_response = 1 };
const SET_POLLING: transport.Command = .{ .id = 0x0005 };
/// Get/Set USB High Speed Polling Period, for devices that reach past 1000 Hz:
/// [store, rate], where 0x01 = 8000 Hz and each doubling halves it.
const GET_HIGH_SPEED_POLLING: transport.Command = .{ .id = 0x00c0, .min_response = 2 };
const SET_HIGH_SPEED_POLLING: transport.Command = .{ .id = 0x0040 };

const Resolution = struct { x: u16, y: u16 };

fn getDpi(hid: *transport.Device) !Resolution {
    const r = try hid.call(GET_DPI, &.{ NOSTORE, 0, 0, 0, 0, 0, 0 });
    const a = r.argSlice();

    return .{ .x = std.mem.readInt(u16, a[1..3], .big), .y = std.mem.readInt(u16, a[3..5], .big) };
}

fn setDpi(hid: *transport.Device, d: Resolution) !void {
    var args = [_]u8{ VARSTORE, 0, 0, 0, 0, 0, 0 };

    std.mem.writeInt(u16, args[1..3], d.x, .big);
    std.mem.writeInt(u16, args[3..5], d.y, .big);
    _ = try hid.call(SET_DPI, &args);
}

/// The device's top rate picks the register; the dongle's rates don't count.
fn highSpeed(polling: Polling) bool {
    return top(polling.rates) > 1000;
}

fn getPolling(hid: *transport.Device, polling: Polling) !u16 {
    if (!highSpeed(polling)) {
        const r = try hid.call(GET_POLLING, &.{0});

        return periodToHz(r.argSlice()[0]);
    }

    const r = try hid.call(GET_HIGH_SPEED_POLLING, &.{ NOSTORE, 0 });

    return highSpeedToHz(r.argSlice()[1]);
}

/// High-speed polling requires both a saved and a live write.
fn setPolling(hid: *transport.Device, polling: Polling, hz: u16) !void {
    if (!highSpeed(polling)) {
        _ = try hid.call(SET_POLLING, &.{hzToPeriod(hz)});
        return;
    }

    _ = try hid.call(SET_HIGH_SPEED_POLLING, &.{ VARSTORE, hzToHighSpeed(hz) });
    _ = try hid.call(SET_HIGH_SPEED_POLLING, &.{ NOSTORE, hzToHighSpeed(hz) });
}

fn periodToHz(period: u8) u16 {
    return if (period == 0) 0 else 1000 / @as(u16, period);
}

fn hzToPeriod(hz: u16) u8 {
    return @intCast(1000 / hz);
}

fn highSpeedToHz(code: u8) u16 {
    return if (code == 0) 0 else @as(u16, 8000) >> @ctz(code);
}

fn hzToHighSpeed(hz: u16) u8 {
    return @as(u8, 1) << @intCast(@ctz(8000 / hz));
}

test "polling codes" {
    const e = std.testing.expectEqual;

    try e(@as(u16, 1000), periodToHz(1));
    try e(@as(u16, 500), periodToHz(2));
    try e(@as(u16, 125), periodToHz(8));
    try e(@as(u16, 8000), highSpeedToHz(0x01));
    try e(@as(u16, 1000), highSpeedToHz(0x08));
    try e(@as(u16, 125), highSpeedToHz(0x40));

    for ([_]u16{ 125, 250, 500, 1000 }) |hz|
        try e(hz, periodToHz(hzToPeriod(hz)));

    for ([_]u16{ 125, 250, 500, 1000, 2000, 4000, 8000 }) |hz|
        try e(hz, highSpeedToHz(hzToHighSpeed(hz)));

    try e(@as(u8, 0x20), hzToHighSpeed(250));
}

pub fn probe(hid: *transport.Device, p: *probe_result.ProbeResult) !void {
    try p.reply(GET_POLLING, "polling period", hid.call(GET_POLLING, &.{0}), 1);
    try p.reply(GET_HIGH_SPEED_POLLING, "high speed polling", hid.call(GET_HIGH_SPEED_POLLING, &.{ 0, 0 }), 2);
    try p.reply(GET_DPI, "dpi", hid.call(GET_DPI, &.{ 0, 0, 0, 0, 0, 0, 0 }), 7);
    try p.reply(GET_DPI_DATA, "dpi class data", hid.call(GET_DPI_DATA, &@as([80]u8, @splat(0))), 16);
}
