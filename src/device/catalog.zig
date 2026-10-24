//! Runtime lookup for built-in device descriptors.

const device_types = @import("device_types");
const registry = @import("registry");

pub const DEVICES = registry.devices;

/// Unknown devices support probing only; no capabilities are assumed.
pub fn unknown(pid: u16) device_types.Descriptor {
    return .{ .pid = pid, .name = "Unrecognised", .category = .accessory, .provenance = .unrecognised };
}

pub fn byPid(pid: u16) ?*const device_types.Descriptor {
    for (&DEVICES) |*descriptor| {
        if (descriptor.pid == pid)
            return descriptor;
    }

    return null;
}

test "catalog contains only laptops with encodable stream layouts" {
    const std = @import("std");
    var count: usize = 0;
    for (DEVICES) |descriptor| {
        try std.testing.expect(descriptor.category == .system);
        const config = descriptor.features.lighting;
        try std.testing.expect(config.protocol != null);
        try std.testing.expect(config.validFrames());
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 41), count);
    const blade = byPid(0x02e1).?.features.lighting;
    try std.testing.expect(blade.protocol == .large_matrix);
    try std.testing.expectEqual(@as(u8, 3), blade.frame_interface.?);
    try std.testing.expectEqual(@as(usize, 342), blade.fixedLayout().?.frameSize());
    try std.testing.expect(byPid(0x0f43) == null);
}
