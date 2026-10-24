//! Polychromatic facade; independent of device access.
const std = @import("std");
const runtime = @import("polychromatic/sequence.zig");

pub const Sequence = runtime.Sequence;
pub const Player = runtime.Player;

const fixture =
    \\{"type":3,"save_format":8,"map_cols":2,"map_rows":2,"fps":10,"loop":false,
    \\"name":"Test","frames":[{"1":{"0":"#12aB34"}},{"0":{"1":"#FF0000"}}]}
;

test "sequence transposes column-major JSON into raw row-major RGB and clears sparse pixels" {
    var sequence = try Sequence.parse(std.testing.allocator, fixture);
    defer sequence.deinit();
    var rgb: [12]u8 = undefined;
    try sequence.render(0, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0x12, 0xab, 0x34, 0, 0, 0, 0, 0, 0 }, &rgb);
    try sequence.render(1, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 255, 0, 0, 0, 0, 0 }, &rgb);
    try std.testing.expect(sequence.matches(2, 2));
    try std.testing.expect(!sequence.matches(1, 4));
}

test "invalid sequences fail before playback, including errors in later frames" {
    const cases = .{
        .{ "\"save_format\":8", "\"save_format\":9", error.UnsupportedAnimationVersion },
        .{ "\"type\":3", "\"type\":1", error.UnsupportedAnimationType },
        .{ "\"fps\":10", "\"fps\":0", error.InvalidAnimationFps },
        .{ "\"map_rows\":2", "\"map_rows\":0", error.InvalidAnimationDimensions },
        .{ "\"#FF0000\"", "\"#GG0000\"", error.InvalidAnimationColour },
        .{ "\"#FF0000\"", "\"#-10000\"", error.InvalidAnimationColour },
        .{ "\"0\":{\"1\":", "\"2\":{\"1\":", error.InvalidAnimationCoordinate },
    };
    inline for (cases) |case| {
        const text = try std.mem.replaceOwned(u8, std.testing.allocator, fixture, case[0], case[1]);
        defer std.testing.allocator.free(text);
        try std.testing.expectError(case[2], Sequence.parse(std.testing.allocator, text));
    }

    try std.testing.expectError(error.EmptyAnimation, Sequence.parse(std.testing.allocator,
        \\{"type":3,"save_format":8,"map_cols":1,"map_rows":1,"fps":10,"loop":true,"frames":[]}
    ));
}

test "decoded frames own their storage and reject invalid output sizes and indices" {
    const text = try std.testing.allocator.dupe(u8, fixture);
    var sequence = Sequence.parse(std.testing.allocator, text) catch |err| {
        std.testing.allocator.free(text);
        return err;
    };
    defer sequence.deinit();
    @memset(text, 0);
    std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 24), sequence.frames.len);
    var rgb: [12]u8 = undefined;
    try sequence.render(0, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0xab, 0x34 }, rgb[3..6]);
    try std.testing.expectError(error.InvalidFrame, sequence.render(2, &rgb));
    try std.testing.expectError(error.InvalidFrame, sequence.render(0, rgb[0..9]));
}

test "player honors final frame duration, looping, slow output and interruption" {
    const Clock = struct {
        time: i96 = 0,
        interrupted: bool = false,
        pub fn check(self: *@This()) !void {
            if (self.interrupted)
                return error.StreamInterrupted;
        }
        pub fn now(self: *@This()) i96 {
            return self.time;
        }
        pub fn wait(self: *@This(), deadline: i96) !void {
            try self.check();
            self.time = @max(self.time, deadline);
        }
    };
    var sequence = try Sequence.parse(std.testing.allocator, fixture);
    defer sequence.deinit();
    var player: Player(Clock) = .{ .sequence = &sequence, .clock = .{} };
    var rgb: [12]u8 = undefined;
    try std.testing.expect(try player.next(&rgb));
    try std.testing.expectEqual(@as(i96, 0), player.clock.time);
    try std.testing.expect(try player.next(&rgb));
    try std.testing.expectEqual(@as(i96, 100_000_000), player.clock.time);
    try std.testing.expect(!try player.next(&rgb));
    try std.testing.expectEqual(@as(i96, 200_000_000), player.clock.time);
    sequence.loop = true;
    try std.testing.expect(try player.next(&rgb));
    player.clock.time += 500_000_000;
    try std.testing.expect(try player.next(&rgb));
    try std.testing.expectEqual(@as(i96, 800_000_000), player.deadline.?);
    player.clock.interrupted = true;
    try std.testing.expectError(error.StreamInterrupted, player.next(&rgb));
}
