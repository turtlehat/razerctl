const std = @import("std");
const chroma = @import("chroma");
const polychromatic = @import("polychromatic");
const device = @import("device");

const names = .{ "after-hours", "undertow", "prismatic-drift", "emberfall", "ghost-signal", "supernova" };
const shapes = .{ .{ 1, 16 }, .{ 6, 16 }, .{ 6, 17 }, .{ 7, 19 }, .{ 1, 102 }, .{ 1, 114 } };

const Clock = struct {
    time: i96 = 0,

    pub fn check(_: *@This()) !void {}
    pub fn now(self: *@This()) i96 {
        return self.time;
    }
    pub fn wait(self: *@This(), deadline: i96) !void {
        self.time = deadline;
    }
};

test "each Chroma design parses and renders for every shipped laptop" {
    inline for (names) |name| {
        const text = @embedFile("chroma/" ++ name ++ ".ChromaEffects");
        var full = try chroma.parseWithSeed(std.testing.allocator, text, 73);
        defer full.deinit();
        try std.testing.expectEqual(device.DEVICES.len, full.devices.len);
        for (device.DEVICES) |descriptor| {
            var profile = try chroma.parseForDevice(std.testing.allocator, text, 73, descriptor.pid);
            defer profile.deinit();
            try std.testing.expectEqual(
                std.mem.eql(u8, name, "ghost-signal") or std.mem.eql(u8, name, "prismatic-drift"),
                profile.needsInput(0),
            );
            try std.testing.expectEqual(@as(usize, 1), profile.devices.len);
            const target = profile.devices[0];
            try std.testing.expectEqual(descriptor.features.lighting.layouts[0].rows, target.rows);
            try std.testing.expectEqual(descriptor.features.lighting.layouts[0].columns, target.columns);
            const rgb = try std.testing.allocator.alloc(u8, @as(usize, target.rows) * target.columns * 3);
            defer std.testing.allocator.free(rgb);
            var player: chroma.Player(Clock) = .{ .profile = &profile, .device = 0, .clock = .{} };
            var nonzero = false;
            for (0..150) |tick| {
                if (profile.needsInput(0) and tick == 20)
                    try chroma.input(profile, 0, .{ .row = 0, .col = 1, .pressed = true }, tick);
                try std.testing.expect(try player.next(rgb));
                for (rgb) |channel|
                    nonzero = nonzero or channel != 0;
            }
            try std.testing.expect(nonzero);
        }
    }
}

test "layout-dependent laptops have per-key Chroma variants" {
    inline for (names) |name| {
        const text = @embedFile("chroma/per-key/" ++ name ++ ".ChromaEffects");
        for ([_]u16{ 0x023b, 0x0246 }) |pid| {
            var profile = try chroma.parseForDevice(std.testing.allocator, text, 73, pid);
            defer profile.deinit();
            try std.testing.expectEqual(@as(u8, 6), profile.devices[0].rows);
            try std.testing.expectEqual(@as(u8, 16), profile.devices[0].columns);
        }
    }
}

test "Polychromatic designs have exact dimensions and seamless loops" {
    inline for (names) |name| {
        if (comptime !std.mem.eql(u8, name, "ghost-signal")) {
            inline for (shapes) |shape| {
                const path = std.fmt.comptimePrint("polychromatic/{s}-{d}x{d}.json", .{ name, shape[0], shape[1] });
                var sequence = try polychromatic.Sequence.parse(std.testing.allocator, @embedFile(path));
                defer sequence.deinit();
                try std.testing.expect(sequence.matches(shape[0], shape[1]));
                try std.testing.expect(sequence.loop);
                const size = shape[0] * shape[1] * 3;
                const first = sequence.frames[0..size];
                const last = sequence.frames[sequence.frames.len - size ..];
                for (first, last) |a, b|
                    try std.testing.expect(@abs(@as(i16, a) - @as(i16, b)) < 30);
            }
        }
    }
}
