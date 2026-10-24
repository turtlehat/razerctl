const std = @import("std");
const device = @import("device_types");
const transport = @import("transport");
const power_mode = @import("power_mode");
const setting_types = @import("setting_types");
const capability = @import("features/display_types");

pub const title = "Display";
pub const order = 7;

pub const Config = capability.Config;

pub fn settings(desc: *const device.Descriptor, s: *setting_types.Settings) !void {
    if (desc.features.display.local_dimming)
        try s.add(.{
            .usage = .{ .name = "local-dimming", .params = &.{.{ .arg = .toggle }}, .note = "Mini-LED contrast; enables HDR." },
            .read = readLocalDimming,
            .write = writeLocalDimming,
        });
}

fn readLocalDimming(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !setting_types.Reading {
    return .{ .val = .{ .flag = try power_mode.read(hid, .local_dimming) } };
}

fn writeLocalDimming(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8, in: setting_types.Input) !void {
    _ = try power_mode.write(hid, .local_dimming, in.flag);
}

test "local dimming is exposed only when declared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var desc: device.Descriptor = .{ .pid = 0, .name = "Test", .category = .system };
    var unsupported = setting_types.Settings.init(arena.allocator());

    try settings(&desc, &unsupported);
    try std.testing.expectEqual(@as(usize, 0), unsupported.items.items.len);

    desc.features.display.local_dimming = true;
    var supported = setting_types.Settings.init(arena.allocator());

    try settings(&desc, &supported);
    try std.testing.expectEqual(@as(usize, 1), supported.items.items.len);
    const setting = supported.items.items[0];
    try std.testing.expectEqualStrings("local-dimming", setting.usage.name);
    try std.testing.expect(setting.read != null and setting.write != null);
}
