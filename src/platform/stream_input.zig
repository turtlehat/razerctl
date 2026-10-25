//! Interruptible raw stdin for the CLI. An OS backend supplies init, deinit,
//! check and read; frame reading and deadline waiting are shared.
const std = @import("std");
const builtin = @import("builtin");

const Backend = switch (builtin.os.tag) {
    .linux => @import("stream_input_linux.zig").Input,
    .windows => @import("stream_input_windows.zig").Input,
    else => @compileError("stream input is not supported on " ++ @tagName(builtin.os.tag)),
};

pub const Input = Stream(Backend);

fn Stream(comptime B: type) type {
    return struct {
        backend: B,

        const Self = @This();

        pub fn init() !Self {
            return .{ .backend = try B.init() };
        }

        pub fn deinit(self: *Self) void {
            self.backend.deinit();
        }

        pub fn check(self: *Self) !void {
            return self.backend.check();
        }

        pub fn read(self: *Self, buffer: []u8) !usize {
            return self.backend.read(buffer);
        }

        pub fn next(self: *Self, frame: []u8) !bool {
            std.debug.assert(frame.len > 0);
            var offset: usize = 0;
            while (offset < frame.len) {
                const n = try self.read(frame[offset..]);
                if (n == 0) {
                    if (offset != 0)
                        return error.IncompleteFrame;
                    return false;
                }
                offset += n;
            }
            return true;
        }

        pub fn wait(self: *Self, io: std.Io, deadline: i96) !void {
            while (true) {
                try self.check();
                const remaining = deadline - std.Io.Clock.awake.now(io).nanoseconds;
                if (remaining <= 0)
                    return;
                try std.Io.sleep(io, .fromNanoseconds(@min(remaining, 20_000_000)), .awake);
            }
        }
    };
}

test "raw frame input distinguishes complete, truncated and empty streams" {
    const Fake = struct {
        bytes: []const u8,

        pub fn init() !@This() {
            unreachable;
        }

        pub fn deinit(_: *@This()) void {}

        pub fn check(_: *@This()) !void {}

        // Short reads exercise frame assembly across several calls.
        pub fn read(self: *@This(), buffer: []u8) !usize {
            const n = @min(buffer.len, 2, self.bytes.len);
            @memcpy(buffer[0..n], self.bytes[0..n]);
            self.bytes = self.bytes[n..];
            return n;
        }
    };

    for ([_][]const u8{ "", "AA", "AAA" }) |bytes| {
        var input: Stream(Fake) = .{ .backend = .{ .bytes = bytes } };
        var frame: [3]u8 = undefined;

        if (bytes.len == 2) {
            try std.testing.expectError(error.IncompleteFrame, input.next(&frame));
        } else {
            try std.testing.expectEqual(bytes.len == 3, try input.next(&frame));
        }
    }
}

test {
    _ = Backend;
}
