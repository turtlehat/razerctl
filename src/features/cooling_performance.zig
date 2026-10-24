//! Cooling pad fan modes (0x0d10): three stored slots and off.

const std = @import("std");
const device = @import("device_types");
const transport = @import("transport");
const ui = @import("ui");
const setting_types = @import("setting_types");
const capability = @import("features/cooling_performance_types");

pub const title = "Performance";
pub const order = 2;

pub const Config = capability.Config;

pub const FanPreset = capability.FanPreset;

/// No reads: reading a slot selects it and spins the fans; the full `get` report reads them all.
pub fn settings(desc: *const device.Descriptor, s: *setting_types.Settings) !void {
    const allocator = s.allocator;
    const presets = desc.features.cooling_performance.presets;

    if (presets.len == 0)
        return;

    var k = presets.len;

    while (k > 0) {
        k -= 1;
        const preset = presets[k];

        try s.add(.{
            .usage = .{
                .name = try allocator.print("fan-{s}", .{preset.name}),
                .params = &.{.{ .arg = .{ .range = .{ .min = preset.min, .max = preset.max } }, .optional = true }},
                .note = if (k + 1 == presets.len) "Each preset stores its own speed; omit rpm to reuse it." else "",
            },
            .ctx = @intCast(k),
            .write = writePreset,
            .unit = .rpm,
        });
    }

    try s.add(.{ .usage = .{ .name = "fan-off", .note = "Stop the fans." }, .write = writeOff });
}

/// Slots are what the device's button cycles through. No rpm sends 0, keeping the slot's stored value.
fn writePreset(_: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, k: u8, in: setting_types.Input) !void {
    const preset = desc.features.cooling_performance.presets[k];
    const rpm = switch (in) {
        .num => |v| device.snap(v, desc.features.cooling_performance.scale),
        else => 0,
    };

    try setFanPreset(hid, desc, preset, rpm);
}

fn writeOff(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8, _: setting_types.Input) !void {
    try setFanPresetOff(hid);
}

/// Reading a slot selects it, which spins the fans. Ends on the quietest preset: the device's
/// button may have changed slots, so restoring could apply a stale one.
pub fn readFields(hid: *transport.Device, desc: *const device.Descriptor, fields: *ui.Fields) !void {
    const allocator = fields.allocator;
    const presets = desc.features.cooling_performance.presets;

    if (presets.len == 0 or presets.len > 8)
        return;

    var slots: [8]?u16 = @splat(null);
    var causes: [8]?anyerror = @splat(null);
    var selected: ?usize = null;
    var i = presets.len;

    // Backwards, so the last one written is the quietest.
    while (i > 0) {
        i -= 1;
        setFanPreset(hid, desc, presets[i], 0) catch |err| {
            causes[i] = err;
            continue;
        };
        const now = getFanPreset(hid, desc) catch |err| {
            causes[i] = err;
            continue;
        };

        if (now.preset != presets[i].wire) {
            causes[i] = transport.Error.BadResponse;
            continue;
        }

        slots[i] = now.rpm;
        selected = i;
    }

    var k = presets.len;

    while (k > 0) {
        k -= 1;

        const rpm = slots[k] orelse {
            try fields.missWithCause(.{
                .message = try allocator.print("fan-{s}: cannot read preset slot", .{presets[k].name}),
                .err = causes[k],
            });
            continue;
        };

        try fields.add(.{
            .label = try allocator.print("fan-{s}", .{presets[k].name}),
            .val = .{ .num = rpm },
            .unit = .rpm,
            .note = if (selected == k) "  (active)" else "",
        });
    }

    if (selected) |s|
        try fields.add(.{ .label = "fan-active", .val = .{ .str = presets[s].name }, .json_only = true });
}

/// Thermal Fan Cooling Mode: [enabled, preset, rpm/scale].
const SET_FAN_PRESET: transport.Command = .{ .id = 0x0d10 };
const GET_FAN_PRESET: transport.Command = .{ .id = 0x0d90, .min_response = 3 };

const PresetState = struct { preset: u8, rpm: u16 };

/// The argument selects a record by enabled flag; [0] returns the disabled one.
/// Reports the host's last selection, not the device button's.
fn getFanPreset(hid: *transport.Device, desc: *const device.Descriptor) !PresetState {
    const r = try hid.call(GET_FAN_PRESET, &.{1});
    const a = r.argSlice();

    return .{ .preset = a[1], .rpm = @as(u16, a[2]) * desc.features.cooling_performance.scale };
}

/// `rpm` 0 keeps the slot's stored value.
fn setFanPreset(hid: *transport.Device, desc: *const device.Descriptor, preset: FanPreset, rpm: u16) !void {
    const wire: u8 = @intCast(rpm / desc.features.cooling_performance.scale);

    _ = hid.call(SET_FAN_PRESET, &.{ 1, preset.wire, wire }) catch |e| {
        // The EC honours a zero and then reports NotSupported for it anyway.
        if (wire != 0 or e != error.NotSupported)
            return e;
    };
}

/// Stops the fans outright. Not "auto": these devices have no sensor to
/// automate against. The 6 is required; [0, 0, 0] is refused.
fn setFanPresetOff(hid: *transport.Device) !void {
    _ = try hid.call(SET_FAN_PRESET, &.{ 0, 6, 0 });
}
