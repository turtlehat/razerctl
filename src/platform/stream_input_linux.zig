//! Linux stdin backend: poll-based reads interrupted by INT and TERM.
const std = @import("std");
const builtin = @import("builtin");

var interrupted: u8 = 0;

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    @atomicStore(u8, &interrupted, 1, .seq_cst);
}

pub const Input = struct {
    fd: std.posix.fd_t = std.posix.STDIN_FILENO,
    old_int: std.posix.Sigaction,
    old_term: std.posix.Sigaction,

    pub fn init() !Input {
        @atomicStore(u8, &interrupted, 0, .seq_cst);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var input: Input = .{ .old_int = undefined, .old_term = undefined };

        std.posix.sigaction(.INT, &action, &input.old_int);
        std.posix.sigaction(.TERM, &action, &input.old_term);
        return input;
    }

    pub fn deinit(self: *Input) void {
        std.posix.sigaction(.TERM, &self.old_term, null);
        std.posix.sigaction(.INT, &self.old_int, null);
    }

    pub fn check(_: *Input) !void {
        if (@atomicLoad(u8, &interrupted, .seq_cst) != 0)
            return error.StreamInterrupted;
    }

    pub fn read(self: *Input, buffer: []u8) !usize {
        while (true) {
            try self.check();
            var pollfd: [1]std.c.pollfd = .{.{ .fd = self.fd, .events = std.c.POLL.IN, .revents = 0 }};
            // A worker thread may receive the signal instead of interrupting poll.
            const ready = std.c.poll(&pollfd, 1, 50);

            if (ready < 0) {
                if (std.posix.errno(ready) == .INTR)
                    continue;
                return error.StreamReadFailed;
            }
            if (ready == 0)
                continue;
            try self.check();
            if (pollfd[0].revents & (std.c.POLL.NVAL | std.c.POLL.ERR) != 0)
                return error.StreamReadFailed;

            const n = std.c.read(self.fd, buffer.ptr, buffer.len);

            if (n < 0) {
                if (std.posix.errno(n) == .INTR)
                    continue;
                return error.StreamReadFailed;
            }
            return @intCast(n);
        }
    }
};

test "stdin interruption is observed for both termination signals" {
    if (builtin.os.tag != .linux)
        return error.SkipZigTest;

    for ([_]std.posix.SIG{ .INT, .TERM }) |signal| {
        var input = try Input.init();
        defer input.deinit();

        try input.check();
        try std.posix.raise(signal);
        try std.testing.expectError(error.StreamInterrupted, input.check());
        var buffer: [1]u8 = undefined;

        try std.testing.expectError(error.StreamInterrupted, input.read(&buffer));
    }
}

test "pipe input drains bytes before EOF and reports invalid descriptors" {
    if (builtin.os.tag != .linux)
        return error.SkipZigTest;

    var fds: [2]std.c.fd_t = undefined;

    try std.testing.expect(std.c.pipe(&fds) == 0);
    defer _ = std.c.close(fds[0]);
    {
        defer _ = std.c.close(fds[1]);
        try std.testing.expectEqual(@as(isize, 3), std.c.write(fds[1], "rgb", 3));
    }

    var input = try Input.init();
    defer input.deinit();
    input.fd = fds[0];
    var buffer: [8]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 3), try input.read(&buffer));
    try std.testing.expectEqualStrings("rgb", buffer[0..3]);
    try std.testing.expectEqual(@as(usize, 0), try input.read(&buffer));
    input.fd = fds[1];
    try std.testing.expectError(error.StreamReadFailed, input.read(&buffer));
}
