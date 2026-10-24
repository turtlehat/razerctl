//! Razer's 0x00 class: firmware version and normal/driver mode.

const std = @import("std");
const device = @import("device_types");
const transport = @import("transport");
const setting_types = @import("setting_types");
const ui = @import("ui");
const probe_result = @import("probe_result");
const capability = @import("features/device_types");

pub const title = "Device";
pub const order = 6;

pub const Config = capability.Config;

pub fn settings(desc: *const device.Descriptor, s: *setting_types.Settings) !void {
    const d = desc.features.device;

    if (d.firmware)
        try s.add(.{
            .usage = .{ .name = "firmware" },
            .read = readFirmware,
        });

    if (d.driver_mode)
        try s.add(.{
            .usage = .{
                .name = "driver-mode",
                .params = &.{.{ .arg = .toggle }},
                .note = "Disables laptop Fn shortcuts while on.",
            },
            .read = readDriverMode,
            .write = writeDriverMode,
        });
}

fn readFirmware(allocator: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !setting_types.Reading {
    const v = try getFirmware(hid);

    return .{ .val = .{ .str = try allocator.print("v{d}.{d:0>2}", .{ v[0], v[1] }) } };
}

fn readDriverMode(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !setting_types.Reading {
    return .{ .val = .{ .flag = try getMode(hid) == DRIVER } };
}

fn writeDriverMode(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8, in: setting_types.Input) !void {
    const want = if (in.flag) DRIVER else NORMAL;

    _ = try hid.call(SET_DEVICE_MODE, &.{ want, 0 });
}

const GET_FIRMWARE: transport.Command = .{ .id = 0x0081, .min_response = 2 };
const GET_SERIAL: transport.Command = .{ .id = 0x0082 };
const SET_DEVICE_MODE: transport.Command = .{ .id = 0x0004 };
const GET_DEVICE_MODE: transport.Command = .{ .id = 0x0084, .min_response = 1 };
// Any other value can put the device into its bootloader; never write anything else.
const NORMAL: u8 = 0x00;
const DRIVER: u8 = 0x03;

fn getMode(hid: *transport.Device) !u8 {
    return (try hid.call(GET_DEVICE_MODE, &.{ 0, 0 })).argSlice()[0];
}

/// Major and minor. Asked for one byte, it answers only the major.
fn getFirmware(hid: *transport.Device) ![2]u8 {
    const a = (try hid.call(GET_FIRMWARE, &.{ 0, 0 })).argSlice();

    return .{ a[0], a[1] };
}

pub fn probe(hid: *transport.Device, p: *probe_result.ProbeResult) !void {
    try p.reply(GET_FIRMWARE, "firmware", hid.call(GET_FIRMWARE, &.{ 0, 0 }), 2);
    try p.reply(GET_SERIAL, "serial", hid.call(GET_SERIAL, &@as([22]u8, @splat(0))), 22);
    try p.reply(GET_DEVICE_MODE, "device mode", hid.call(GET_DEVICE_MODE, &.{ 0, 0 }), 2);
}
