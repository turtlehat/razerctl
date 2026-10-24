//! Interruptible raw stdin for the Linux CLI.
const std = @import("std");
const builtin = @import("builtin");

pub const Input = if (builtin.os.tag == .linux) LinuxInput else struct {
    pub fn init() !@This() {
        return error.StreamUnsupportedPlatform;
    }

    pub fn deinit(_: *@This()) void {}
    pub fn check(_: *@This()) !void {
        return error.StreamUnsupportedPlatform;
    }
    pub fn read(_: *@This(), _: []u8) !usize {
        return error.StreamUnsupportedPlatform;
    }
    pub fn next(_: *@This(), _: []u8) !bool {
        return error.StreamUnsupportedPlatform;
    }
    pub fn wait(_: *@This(), _: std.Io, _: i96) !void {
        return error.StreamUnsupportedPlatform;
    }
};

var interrupted: u8 = 0;

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    @atomicStore(u8, &interrupted, 1, .seq_cst);
}

const LinuxInput = struct {
    fd: std.posix.fd_t = std.posix.STDIN_FILENO,
    old_int: std.posix.Sigaction,
    old_term: std.posix.Sigaction,

    pub fn init() !LinuxInput {
        @atomicStore(u8, &interrupted, 0, .seq_cst);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var input: LinuxInput = .{ .old_int = undefined, .old_term = undefined };

        std.posix.sigaction(.INT, &action, &input.old_int);
        std.posix.sigaction(.TERM, &action, &input.old_term);
        return input;
    }

    pub fn deinit(self: *LinuxInput) void {
        std.posix.sigaction(.TERM, &self.old_term, null);
        std.posix.sigaction(.INT, &self.old_int, null);
    }

    pub fn check(_: *LinuxInput) !void {
        if (@atomicLoad(u8, &interrupted, .seq_cst) != 0)
            return error.StreamInterrupted;
    }

    pub fn next(self: *LinuxInput, frame: []u8) !bool {
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

    pub fn wait(self: *LinuxInput, io: std.Io, deadline: i96) !void {
        while (true) {
            try self.check();
            const remaining = deadline - std.Io.Clock.awake.now(io).nanoseconds;
            if (remaining <= 0)
                return;
            try std.Io.sleep(io, .fromNanoseconds(@min(remaining, 20_000_000)), .awake);
        }
    }

    pub fn read(self: *LinuxInput, buffer: []u8) !usize {
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

test "raw frame input distinguishes complete, truncated and empty pipes" {
    if (builtin.os.tag != .linux)
        return error.SkipZigTest;
    for ([_][]const u8{ "", "AA", "AAA" }) |bytes| {
        var fds: [2]std.c.fd_t = undefined;
        try std.testing.expect(std.c.pipe(&fds) == 0);
        defer _ = std.c.close(fds[0]);
        {
            defer _ = std.c.close(fds[1]);
            try std.testing.expectEqual(@as(isize, @intCast(bytes.len)), std.c.write(fds[1], bytes.ptr, bytes.len));
        }
        var input = try Input.init();
        defer input.deinit();
        input.fd = fds[0];
        var frame: [3]u8 = undefined;
        if (bytes.len == 2) {
            try std.testing.expectError(error.IncompleteFrame, input.next(&frame));
        } else {
            try std.testing.expectEqual(bytes.len == 3, try input.next(&frame));
        }
    }
}
