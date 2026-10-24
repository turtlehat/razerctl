const std = @import("std");
const transport = @import("transport");
const device = @import("device");
const descriptor = @import("device_types");
const ui = @import("ui");
const SEE_LIST = "see `razerctl list`";

/// Every attached Razer device in enumeration order, known or not: an
/// unrecognised pid gets the no-claims descriptor, so `probe` can run on it.
pub fn attached(allocator: std.mem.Allocator) transport.EnumerationError![]descriptor.Descriptor {
    const pids = try transport.attachedPids(allocator);
    const found = try allocator.alloc(descriptor.Descriptor, pids.len);

    for (pids, found) |p, *d|
        d.* = if (device.byPid(p)) |known| known.* else device.unknown(p);

    return found;
}

/// The single attached `.system` device; accessories are never picked automatically.
pub fn automatic(found: []const descriptor.Descriptor) ?descriptor.Descriptor {
    var host: ?descriptor.Descriptor = null;

    for (found) |d| {
        if (d.category != .system)
            continue;

        if (host != null)
            return null;

        host = d;
    }

    return host;
}

pub fn one(allocator: std.mem.Allocator, spec: ?[]const u8) !ui.Result(descriptor.Descriptor) {
    const sel = spec orelse {
        const found = attached(allocator) catch |err|
            return .{ .failure = .{ .message = "cannot enumerate Razer devices", .err = err } };

        if (automatic(found)) |host|
            return .{ .success = host };

        return .{ .failure = .{ .message = if (found.len == 0)
            try allocator.print("no Razer device detected -- {s}", .{SEE_LIST})
        else
            try allocator.print("only a Razer laptop is selected automatically -- put its id after the command, {s}", .{SEE_LIST}) } };
    };

    return if (find(sel)) |desc|
        .{ .success = desc }
    else
        .{ .failure = .{ .message = try allocator.print("'{s}' is not a device id -- {s}", .{ sel, SEE_LIST }) } };
}

/// A `0x` pid. One we do not recognise still gets a descriptor, so `help` can
/// say what `probe` will do and `probe` can run.
pub fn find(sel: []const u8) ?descriptor.Descriptor {
    if (!std.mem.startsWith(u8, sel, "0x"))
        return null;

    const pid = std.fmt.parseInt(u16, sel[2..], 16) catch return null;

    return if (device.byPid(pid)) |d| d.* else device.unknown(pid);
}

test "device ids resolve known and unrecognised pids, and only one laptop is automatic" {
    const laptop = find("0x02b6").?;

    try std.testing.expect(laptop.category == .system);
    try std.testing.expect(find("0xbeef").?.provenance == .unrecognised);
    try std.testing.expect(find("02b6") == null);
    try std.testing.expect(find("0xzz") == null);
    const pad = find("0x0f43").?;

    try std.testing.expectEqual(laptop.pid, automatic(&.{ pad, laptop }).?.pid);
    try std.testing.expect(automatic(&.{pad}) == null);
    try std.testing.expect(automatic(&.{ laptop, laptop }) == null);
}
