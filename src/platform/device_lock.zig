//! Cross-process serialization for cooperating razerctl instances. An OS backend
//! supplies the named handle and its lock primitives; nesting and priority are shared.
const std = @import("std");
const builtin = @import("builtin");

const Backend = switch (builtin.os.tag) {
    .linux => @import("device_lock_linux.zig"),
    .windows => @import("device_lock_windows.zig"),
    else => @compileError("device locking is not supported on " ++ @tagName(builtin.os.tag)),
};

pub const Error = error{ DeviceLockFailed, DeviceLockTimeout };
const Handle = Backend.Handle;
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
        return .{ .handle = try Backend.open(pid, suffix), .pid = pid };
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
            try Backend.acquire(gate.handle);
            gate.depth = 1;
            errdefer if (gate.depth > 0) gate.release();

            if (priority == .normal)
                gate.release();

            // Normal callers have already passed admission and may finish
            // ahead of a frame that reserves the gate afterward.
            try Backend.acquire(self.handle);
        } else {
            try Backend.acquire(self.handle);
        }

        self.priority = priority;
        self.depth = 1;
    }

    pub fn release(self: *Lock) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;

        if (self.depth != 0)
            return;

        Backend.release(self.handle);

        if (self.priority == .high) {
            if (self.gate) |handle| {
                var gate: Lock = .{ .handle = handle, .pid = self.pid, .depth = 1 };
                gate.release();
            }
        }
    }

    pub fn close(self: *Lock) void {
        std.debug.assert(self.depth == 0);

        if (self.gate) |handle|
            Backend.close(handle);

        Backend.close(self.handle);
    }
};

test "nested scopes retain ownership and other devices lock independently" {
    var first = try Lock.open(0xffff);
    defer first.close();
    var second = try Lock.open(0xffff);
    defer second.close();

    try first.acquire();
    try first.acquire();
    first.release();

    var other = try Lock.open(0xfffe);
    defer other.close();

    try other.acquire();
    other.release();
    first.release();
    try second.acquire();
    second.release();
}

test {
    _ = Backend;
}
