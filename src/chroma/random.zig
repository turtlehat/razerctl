const std = @import("std");
const profile = @import("profile.zig");

pub const Generator = struct {
    state: u32,

    pub fn next(self: *Generator) u32 {
        self.state = self.state *% 214013 +% 2531011;
        return self.state ^ (self.state >> 16);
    }

    pub fn color(self: *Generator) profile.Color {
        while (true) {
            var rgb: [3]f64 = undefined;
            for (&rgb) |*channel| {
                const value = self.next() % 255;
                channel.* = if (value < 86) 0 else if (value < 171) 128 else 255;
            }
            if (rgb[0] != rgb[1] or rgb[1] != rgb[2])
                return .{ .rgb = rgb };
        }
    }
};

test "native effect random sequence and rejected grey palette" {
    var rng: Generator = .{ .state = 1 };
    for ([_]u32{ 2745065, 3357752992, 415145860, 3884226193, 3403748709, 1030499675 }) |expected|
        try std.testing.expectEqual(expected, rng.next());

    var seen: [27]bool = @splat(false);
    for (0..1000) |_| {
        const c = rng.color();
        var combination: usize = 0;
        for (c.rgb) |value| {
            try std.testing.expect(value == 0 or value == 128 or value == 255);
            combination = combination * 3 + (if (value == 0) @as(usize, 0) else if (value == 128) @as(usize, 1) else 2);
        }
        try std.testing.expect(c.rgb[0] != c.rgb[1] or c.rgb[1] != c.rgb[2]);
        seen[combination] = true;
    }
    try std.testing.expectEqual(@as(usize, 24), std.mem.count(bool, &seen, &.{true}));
}
