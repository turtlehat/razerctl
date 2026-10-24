//! Cross-process serialization for cooperating razerctl instances.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("device_lock_c");

pub const Error = error{ DeviceLockFailed, DeviceLockTimeout };
const Handle = if (builtin.target.os.tag == .windows) c.HANDLE else c_int;
pub const Priority = enum { normal, high };

pub const Lock = struct {
    handle: Handle,
    pid: u16,
    depth: usize = 0,
    gate: ?Handle = null,
    priority: Priority = .normal,

    pub fn open(pid: u16) Error!Lock {
        var lock = try openNamed(pid, "");
        errdefer lock.close();
        const gate = try openNamed(pid, "-priority");
        lock.gate = gate.handle;

        return lock;
    }

    fn openNamed(pid: u16, suffix: []const u8) Error!Lock {
        if (builtin.target.os.tag == .windows) {
            var buffer: [80]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&buffer, "Local\\razerctl-1532-{x:0>4}{s}", .{ pid, suffix }, 0) catch unreachable;
            const handle = c.CreateMutexA(null, 0, name.ptr) orelse return error.DeviceLockFailed;

            return .{ .handle = handle, .pid = pid };
        } else {
            var buffer: [128]u8 = undefined;
            const path = std.fmt.bufPrintSentinel(&buffer, "/tmp/razerctl-{d}-1532-{x:0>4}{s}.lock", .{ c.geteuid(), pid, suffix }, 0) catch unreachable;

            const fd = c.open(path.ptr, c.O_CREAT | c.O_RDWR | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));

            if (fd < 0)
                return error.DeviceLockFailed;

            errdefer _ = c.close(fd);

            var info: c.struct_stat = undefined;

            if (c.fstat(fd, &info) != 0)
                return error.DeviceLockFailed;

            const owned = info.st_uid == c.geteuid() and info.st_nlink == 1;
            const private_file = info.st_mode & c.S_IFMT == c.S_IFREG and info.st_mode & 0o077 == 0;

            if (!owned or !private_file)
                return error.DeviceLockFailed;

            return .{ .handle = fd, .pid = pid };
        }
    }

    /// Nested scopes on this single-threaded Device reuse existing ownership.
    pub fn acquire(self: *Lock) Error!void {
        return self.acquirePriority(.normal);
    }

    pub fn acquirePriority(self: *Lock, priority: Priority) Error!void {
        if (self.depth > 0) {
            self.depth += 1;
            return;
        }

        if (self.gate) |handle| {
            var gate: Lock = .{ .handle = handle, .pid = self.pid };
            try gate.acquireHandle();
            gate.depth = 1;
            errdefer if (gate.depth > 0) gate.release();

            if (priority == .normal)
                gate.release();

            // Normal callers have already passed admission and may finish
            // ahead of a frame that reserves the gate afterward.
            try self.acquireHandle();
        } else {
            try self.acquireHandle();
        }

        self.priority = priority;
        self.depth = 1;
    }

    fn acquireHandle(self: *Lock) Error!void {
        if (builtin.target.os.tag == .windows) {
            switch (c.WaitForSingleObject(self.handle, 2000)) {
                c.WAIT_OBJECT_0, c.WAIT_ABANDONED => {},
                c.WAIT_TIMEOUT => return error.DeviceLockTimeout,
                else => return error.DeviceLockFailed,
            }
        } else if (c.flock(self.handle, c.LOCK_EX) != 0) {
            return error.DeviceLockFailed;
        }
    }

    pub fn release(self: *Lock) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;

        if (self.depth != 0)
            return;

        if (builtin.target.os.tag == .windows) {
            if (c.ReleaseMutex(self.handle) == 0)
                @panic("device mutex release failed");
        } else {
            if (c.flock(self.handle, c.LOCK_UN) != 0)
                @panic("device lock release failed");
        }

        if (self.priority == .high) {
            if (self.gate) |handle| {
                var gate: Lock = .{ .handle = handle, .pid = self.pid, .depth = 1 };
                gate.release();
            }
        }
    }

    pub fn close(self: *Lock) void {
        std.debug.assert(self.depth == 0);

        if (self.gate) |handle| {
            var gate: Lock = .{ .handle = handle, .pid = self.pid };
            gate.close();
        }

        if (builtin.target.os.tag == .windows) {
            if (c.CloseHandle(self.handle) == 0)
                @panic("device mutex close failed");
        } else {
            if (c.close(self.handle) != 0)
                @panic("device lock close failed");
        }
    }
};

test "independent handles contend and nested scopes retain ownership" {
    var first = try Lock.open(0xffff);
    defer first.close();
    var second = try Lock.open(0xffff);
    defer second.close();

    try first.acquire();
    try first.acquire();
    first.release();

    // Windows mutexes are recursive by thread, even across handles.
    if (builtin.target.os.tag != .windows)
        try std.testing.expect(c.flock(second.handle, c.LOCK_EX | c.LOCK_NB) != 0);

    var other = try Lock.open(0xfffe);
    defer other.close();

    try other.acquire();
    other.release();
    first.release();
    try second.acquire();
    second.release();
}

test "normal admission releases the gate and high priority retains it through nested scopes" {
    if (builtin.target.os.tag != .linux)
        return error.SkipZigTest;

    var first = try Lock.open(0xfffa);
    defer first.close();
    var second = try Lock.open(0xfffa);
    defer second.close();

    try first.acquire();
    try std.testing.expect(c.flock(second.gate.?, c.LOCK_EX | c.LOCK_NB) == 0);
    try std.testing.expect(c.flock(second.gate.?, c.LOCK_UN) == 0);
    first.release();

    try first.acquirePriority(.high);
    try first.acquire();
    first.release();
    try std.testing.expect(c.flock(second.gate.?, c.LOCK_EX | c.LOCK_NB) != 0);
    try std.testing.expect(c.flock(second.handle, c.LOCK_EX | c.LOCK_NB) != 0);
    first.release();

    try second.acquirePriority(.high);
    second.release();
    try first.acquire();
    first.release();
}

test "USB acquisition blocks until another process releases the lock" {
    if (builtin.target.os.tag != .linux)
        return error.SkipZigTest;

    var lock = try Lock.open(0xfffb);
    defer lock.close();
    try lock.acquire();
    defer if (lock.depth > 0) lock.release();

    var pipe: [2]c_int = undefined;
    try std.testing.expect(c.pipe(&pipe) == 0);
    defer _ = c.close(pipe[0]);
    const child = c.fork();

    if (child < 0) {
        _ = c.close(pipe[1]);
        return error.ForkFailed;
    }

    if (child == 0) {
        _ = c.close(pipe[0]);
        _ = c.close(lock.handle);
        var waiter = Lock.open(0xfffb) catch c._exit(1);
        const ready = [_]u8{1};

        if (c.write(pipe[1], &ready, 1) != 1)
            c._exit(2);

        waiter.acquire() catch c._exit(3);
        waiter.release();
        waiter.close();

        if (c.write(pipe[1], &ready, 1) != 1)
            c._exit(4);

        c._exit(0);
    }

    _ = c.close(pipe[1]);
    var reaped = false;
    defer if (!reaped) {
        _ = c.kill(child, c.SIGKILL);
        var status: c_int = 0;

        _ = c.waitpid(child, &status, 0);
    };
    var pollfd = [_]std.c.pollfd{.{ .fd = pipe[0], .events = std.c.POLL.IN, .revents = 0 }};
    var ready: [1]u8 = undefined;

    try std.testing.expect(std.c.poll(&pollfd, 1, 2000) == 1);
    try std.testing.expect(c.read(pipe[0], &ready, 1) == 1);
    try std.testing.expect(std.c.poll(&pollfd, 1, 40) == 0);
    lock.release();
    try std.testing.expect(std.c.poll(&pollfd, 1, 2000) == 1);
    try std.testing.expect(c.read(pipe[0], &ready, 1) == 1);
    var status: c_int = 0;

    try std.testing.expect(c.waitpid(child, &status, 0) == child);
    reaped = true;
    try std.testing.expectEqual(@as(c_int, 0), status);
}

test "process exit releases ownership and competing processes cannot acquire it" {
    if (builtin.target.os.tag != .linux)
        return error.SkipZigTest;

    var lock = try Lock.open(0xfffd);
    defer lock.close();
    var pipe: [2]c_int = undefined;

    try std.testing.expect(c.pipe(&pipe) == 0);
    defer _ = c.close(pipe[0]);
    const child = c.fork();

    if (child < 0) {
        _ = c.close(pipe[1]);
        return error.ForkFailed;
    }

    if (child == 0) {
        // Open a new file description; inherited flock handles share ownership.
        const owned = Lock.open(0xfffd) catch c._exit(1);

        if (c.flock(owned.handle, c.LOCK_EX | c.LOCK_NB) != 0)
            c._exit(2);

        const ready = [_]u8{1};

        if (c.write(pipe[1], &ready, 1) != 1)
            c._exit(3);

        while (true)
            _ = c.pause();
    }

    _ = c.close(pipe[1]);
    var reaped = false;
    defer if (!reaped) {
        _ = c.kill(child, c.SIGKILL);
        var status: c_int = 0;

        _ = c.waitpid(child, &status, 0);
    };
    var ready: [1]u8 = undefined;

    try std.testing.expect(c.read(pipe[0], &ready, 1) == 1);
    try std.testing.expect(c.flock(lock.handle, c.LOCK_EX | c.LOCK_NB) != 0);
    try std.testing.expect(c.kill(child, c.SIGKILL) == 0);
    var status: c_int = 0;

    try std.testing.expect(c.waitpid(child, &status, 0) == child);
    reaped = true;
    try lock.acquire();
    lock.release();
}
