//! Linux device lock: an flock on a private file per device in /tmp.
const std = @import("std");
const c = @import("device_lock_linux_c");
const Lock = @import("device_lock.zig").Lock;

pub const Handle = c_int;

pub fn open(pid: u16, suffix: []const u8) error{DeviceLockFailed}!Handle {
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

    return fd;
}

pub fn acquire(handle: Handle) error{DeviceLockFailed}!void {
    if (c.flock(handle, c.LOCK_EX) != 0)
        return error.DeviceLockFailed;
}

pub fn release(handle: Handle) void {
    if (c.flock(handle, c.LOCK_UN) != 0)
        @panic("device lock release failed");
}

pub fn close(handle: Handle) void {
    if (c.close(handle) != 0)
        @panic("device lock close failed");
}

test "independent handles contend" {
    var first = try Lock.open(0xfff9);
    defer first.close();
    var second = try Lock.open(0xfff9);
    defer second.close();

    try first.acquire();
    try std.testing.expect(c.flock(second.handle, c.LOCK_EX | c.LOCK_NB) != 0);
    first.release();
}

test "normal admission releases the gate and high priority retains it through nested scopes" {
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
