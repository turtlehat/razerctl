//! Device-independent animation frames and playback.
const std = @import("std");
const importer = @import("import.zig");

pub const Sequence = struct {
    allocator: std.mem.Allocator,
    rows: u8,
    columns: u8,
    fps: u32,
    loop: bool,
    frames: []u8,

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Sequence {
        return importer.parse(Sequence, allocator, text);
    }

    pub fn deinit(self: *Sequence) void {
        self.allocator.free(self.frames);
    }

    pub fn matches(self: Sequence, rows: u8, columns: u8) bool {
        return self.rows == rows and self.columns == columns;
    }

    fn frameSize(self: Sequence) usize {
        return @as(usize, self.rows) * self.columns * 3;
    }

    fn frameCount(self: Sequence) usize {
        return self.frames.len / self.frameSize();
    }

    pub fn render(self: Sequence, index: usize, rgb: []u8) !void {
        const size = self.frameSize();
        if (rgb.len != size or index >= self.frameCount())
            return error.InvalidFrame;
        @memcpy(rgb, self.frames[index * size ..][0..size]);
    }
};

pub fn Player(comptime Clock: type) type {
    return struct {
        sequence: *const Sequence,
        clock: Clock,
        index: usize = 0,
        deadline: ?i96 = null,

        pub fn check(self: *@This()) !void {
            try self.clock.check();
        }

        pub fn next(self: *@This(), frame: []u8) !bool {
            try self.check();
            if (self.deadline) |deadline|
                try self.clock.wait(deadline);
            if (self.index == self.sequence.frameCount()) {
                if (!self.sequence.loop)
                    return false;
                self.index = 0;
            }
            self.deadline = self.clock.now() + @as(i96, @intCast(std.time.ns_per_s / self.sequence.fps));
            try self.sequence.render(self.index, frame);
            self.index += 1;
            return true;
        }
    };
}
