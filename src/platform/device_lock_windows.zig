//! Windows device lock: a named mutex per device.
const std = @import("std");
const c = @import("device_lock_windows_c");

pub const Handle = c.HANDLE;

pub fn open(pid: u16, suffix: []const u8) error{DeviceLockFailed}!Handle {
    var buffer: [80]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&buffer, "Local\\razerctl-1532-{x:0>4}{s}", .{ pid, suffix }, 0) catch unreachable;

    return c.CreateMutexA(null, 0, name.ptr) orelse error.DeviceLockFailed;
}

pub fn acquire(handle: Handle) error{ DeviceLockFailed, DeviceLockTimeout }!void {
    switch (c.WaitForSingleObject(handle, 2000)) {
        c.WAIT_OBJECT_0, c.WAIT_ABANDONED => {},
        c.WAIT_TIMEOUT => return error.DeviceLockTimeout,
        else => return error.DeviceLockFailed,
    }
}

pub fn release(handle: Handle) void {
    if (c.ReleaseMutex(handle) == 0)
        @panic("device mutex release failed");
}

pub fn close(handle: Handle) void {
    if (c.CloseHandle(handle) == 0)
        @panic("device mutex close failed");
}
