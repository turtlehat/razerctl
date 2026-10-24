//! Razer's 0x07 class: charge limit, charge override, battery and charger.

const std = @import("std");
const device = @import("device_types");
const transport = @import("transport");
const ui = @import("ui");
const probe_result = @import("probe_result");
const setting_types = @import("setting_types");
const battery = @import("battery");
const power_mode = @import("power_mode");
const capability = @import("features/power_types");

pub const title = "Power";
pub const order = 4;

pub const Config = capability.Config;
pub const Battery = capability.Battery;

pub const LIMIT_MIN = capability.LIMIT_MIN;
pub const LIMIT_MAX = capability.LIMIT_MAX;

pub fn settings(desc: *const device.Descriptor, s: *setting_types.Settings) !void {
    const b = desc.features.power;

    if (b.charge_limiter)
        try s.add(.{
            .usage = .{
                .name = "charge-limit",
                .params = &.{.{ .arg = .{ .range = .{ .min = LIMIT_MIN, .max = LIMIT_MAX } } }},
            },
            .read = readChargeLimit,
            .write = writeChargeLimit,
            .unit = .percent,
        });

    if (b.charge_override)
        try s.add(.{
            .usage = .{
                .name = "charge-override",
                .params = &.{.{ .arg = .toggle }},
                .note = "Charges to 100% until turned off.",
            },
            .read = readChargeOverride,
            .write = writeChargeOverride,
        });

    switch (b.battery) {
        .none => {},
        .device => {
            try s.add(.{ .usage = .{ .name = "battery-percent" }, .read = readBattery, .unit = .percent });
            try s.add(.{
                .usage = .{ .name = "charging" },
                .read = readCharging,
            });
        },
        .host => {
            try s.add(.{
                .usage = .{ .name = "battery-percent" },
                .read = readHostBattery,
                .ctx = @backingInt(HostField.percent),
                .unit = .percent,
            });
            try s.add(.{
                .usage = .{ .name = "battery-state", .note = "Charging, discharging, full, idle, or unknown." },
                .read = readHostBattery,
                .ctx = @backingInt(HostField.state),
            });
            try s.add(.{
                .usage = .{ .name = "charge-rate", .note = "Positive while charging, negative while discharging." },
                .read = readHostBattery,
                .ctx = @backingInt(HostField.rate),
                .unit = .watts,
            });
            try s.add(.{
                .usage = .{ .name = "battery-energy" },
                .read = readHostBattery,
                .ctx = @backingInt(HostField.energy),
                .unit = .watt_hours,
            });
            try s.add(.{
                .usage = .{ .name = "battery-energy-full", .note = "Current full-charge capacity." },
                .read = readHostBattery,
                .ctx = @backingInt(HostField.energy_full),
                .unit = .watt_hours,
            });
            try s.add(.{
                .usage = .{ .name = "battery-energy-design", .note = "Original design capacity." },
                .read = readHostBattery,
                .ctx = @backingInt(HostField.energy_design),
                .unit = .watt_hours,
            });
        },
    }

    if (b.source)
        try s.add(.{
            .usage = .{ .name = "power-source", .note = "Charger wattage, or battery." },
            .read = readPowerSource,
        });
}

fn readChargeLimit(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !setting_types.Reading {
    const v = try getChargeLimit(hid);

    return .{ .val = .{ .num = v }, .note = if (v >= 100) " (no limit)" else "" };
}

fn writeChargeLimit(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8, in: setting_types.Input) !void {
    try setChargeLimit(hid, @intCast(in.num));
}

/// The override stays enabled until explicitly cleared, even after a full charge.
fn readChargeOverride(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !setting_types.Reading {
    return .{ .val = .{ .flag = try power_mode.read(hid, .charge_override) } };
}

fn writeChargeOverride(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8, in: setting_types.Input) !void {
    _ = try power_mode.write(hid, .charge_override, in.flag);
}

fn readBattery(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !setting_types.Reading {
    return .{ .val = .{ .num = try getBatteryLevel(hid) } };
}

const HostField = enum(u8) { percent, state, rate, energy, energy_full, energy_design };

fn readHostBattery(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, field: u8) !setting_types.Reading {
    return hostReading(try battery.read(hid.io), @fromBackingInt(@intCast(field)));
}

fn hostReading(reading: battery.Reading, field: HostField) setting_types.Reading {
    const unavailable: setting_types.Reading = .{ .val = .{ .str = "unavailable" } };

    switch (field) {
        .percent => return if (reading.percent) |value| .{ .val = .{ .num = value } } else unavailable,
        .state => return .{ .val = .{ .str = @tagName(reading.state) } },
        inline .rate, .energy, .energy_full, .energy_design => |f| {
            return if (@field(reading, @tagName(f))) |number| .{ .val = .{ .decimal = number } } else unavailable;
        },
    }
}

test "host battery readings preserve signed decimals and unavailable values" {
    const reading: battery.Reading = .{ .percent = 75, .state = .discharging, .rate = -12.5, .energy = 45 };

    try std.testing.expectEqual(@as(u16, 75), hostReading(reading, .percent).val.num);
    try std.testing.expectEqualStrings("discharging", hostReading(reading, .state).val.str);
    try std.testing.expectEqual(@as(f64, -12.5), hostReading(reading, .rate).val.decimal);
    try std.testing.expectEqual(@as(f64, 45), hostReading(reading, .energy).val.decimal);
    try std.testing.expectEqualStrings("unavailable", hostReading(reading, .energy_full).val.str);
}

test "host battery settings are read-only and HID batteries retain charging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var desc: device.Descriptor = .{ .pid = 0, .name = "Battery test", .category = .system };

    desc.features.power.battery = .host;
    var host: setting_types.Settings = .init(arena.allocator());

    try settings(&desc, &host);
    const names = [_][]const u8{
        "battery-percent",
        "battery-state",
        "charge-rate",
        "battery-energy",
        "battery-energy-full",
        "battery-energy-design",
    };

    try std.testing.expectEqual(names.len, host.items.items.len);

    for (names, host.items.items) |name, setting| {
        try std.testing.expectEqualStrings(name, setting.usage.name);
        try std.testing.expect(setting.read != null and setting.write == null);
    }

    desc.features.power.battery = .device;
    var peripheral: setting_types.Settings = .init(arena.allocator());

    try settings(&desc, &peripheral);
    try std.testing.expectEqual(@as(usize, 2), peripheral.items.items.len);
    try std.testing.expectEqualStrings("battery-percent", peripheral.items.items[0].usage.name);
    try std.testing.expectEqualStrings("charging", peripheral.items.items[1].usage.name);
}

fn readPowerSource(allocator: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !setting_types.Reading {
    const level = try getAdapterLevel(hid);

    if (level == 0)
        return .{ .val = .{ .str = "battery" } };

    const watts = adapterWatts(level) orelse return .{ .val = .{ .str = try ui.nameOr(allocator, null, level) } };

    return .{ .val = .{ .str = try allocator.print("{d} W", .{watts}) } };
}

fn readCharging(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !setting_types.Reading {
    return .{ .val = .{ .flag = try getCharging(hid) } };
}

const SET_CHARGE_LIMIT: transport.Command = .{ .id = 0x0712 };
const GET_CHARGE_LIMIT: transport.Command = .{ .id = 0x0792, .min_response = 1 };
const GET_BATTERY_LEVEL: transport.Command = .{ .id = 0x0780, .min_response = 2 };
const GET_CHARGING: transport.Command = .{ .id = 0x0784, .min_response = 2 };
const GET_ADAPTER_LEVEL: transport.Command = .{ .id = 0x078c, .min_response = 1 };
/// Asked for with a short size, 0x078c answers zeros, which reads as battery.
const ADAPTER_LEVEL_SIZE = 16;
/// Adapter wattage by wire level. 0 is no adapter; 16 is unused.
const ADAPTER_WATTS = [_]u16{ 0, 40, 45, 60, 65, 80, 90, 100, 120, 130, 150, 180, 200, 230, 250, 310, 0, 280, 330, 400 };

/// Percent, where 100 means no limit. On the wire that is 0x80 | percent, or
/// 0x50 for off.
fn getChargeLimit(hid: *transport.Device) !u8 {
    const r = try hid.call(GET_CHARGE_LIMIT, &.{0});
    const w = r.argSlice()[0];

    return if (w == 0x50) 100 else w & 0x7f;
}

fn setChargeLimit(hid: *transport.Device, pct: u8) !void {
    const wire: u8 = if (pct >= 100) 0x50 else 0x80 | pct;

    _ = try hid.call(SET_CHARGE_LIMIT, &.{wire});
}

fn getBatteryLevel(hid: *transport.Device) !u8 {
    const r = try hid.call(GET_BATTERY_LEVEL, &.{ 0, 0 });

    return device.levelToPct(r.argSlice()[1]);
}

fn getCharging(hid: *transport.Device) !bool {
    const r = try hid.call(GET_CHARGING, &.{ 0, 0 });

    return r.argSlice()[1] != 0;
}

/// Byte 0 is the charger plugged in now; byte 1, unused here, is the one Razer
/// recommends for the laptop.
fn getAdapterLevel(hid: *transport.Device) !u8 {
    return (try hid.call(GET_ADAPTER_LEVEL, &@as([ADAPTER_LEVEL_SIZE]u8, @splat(0)))).argSlice()[0];
}

fn adapterWatts(level: u8) ?u16 {
    if (level >= ADAPTER_WATTS.len or ADAPTER_WATTS[level] == 0)
        return null;

    return ADAPTER_WATTS[level];
}

pub fn probe(hid: *transport.Device, p: *probe_result.ProbeResult) !void {
    try p.reply(GET_BATTERY_LEVEL, "battery level", hid.call(GET_BATTERY_LEVEL, &.{ 0, 0 }), 2);
    try p.reply(GET_CHARGING, "charging status", hid.call(GET_CHARGING, &.{ 0, 0 }), 2);
    try p.reply(GET_CHARGE_LIMIT, "charge limiter", hid.call(GET_CHARGE_LIMIT, &.{0}), 1);
    try p.reply(power_mode.GET, "power mode", hid.call(power_mode.GET, &.{0}), 1);
    try p.reply(GET_ADAPTER_LEVEL, "adapter wattage level", hid.call(GET_ADAPTER_LEVEL, &@as([ADAPTER_LEVEL_SIZE]u8, @splat(0))), 2);
}

test "adapter levels map to Synapse's watts" {
    try std.testing.expectEqual(@as(?u16, 100), adapterWatts(0x07));
    try std.testing.expectEqual(@as(?u16, 230), adapterWatts(0x0d));
    try std.testing.expectEqual(@as(?u16, 280), adapterWatts(17));
    try std.testing.expectEqual(@as(?u16, null), adapterWatts(16));
    try std.testing.expectEqual(@as(?u16, null), adapterWatts(0xff));
}
