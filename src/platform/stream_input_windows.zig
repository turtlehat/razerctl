//! Windows stdin backend: polled pipe reads interrupted by console control events.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("stream_input_windows_c");

var interrupted: u8 = 0;

fn onControl(_: c.DWORD) callconv(.winapi) c.BOOL {
    @atomicStore(u8, &interrupted, 1, .seq_cst);
    return 1;
}

pub const Input = struct {
    handle: c.HANDLE,
    kind: c.DWORD,

    pub fn init() !Input {
        @atomicStore(u8, &interrupted, 0, .seq_cst);
        const handle = c.GetStdHandle(c.STD_INPUT_HANDLE);

        if (handle == null or handle == c.INVALID_HANDLE_VALUE)
            return error.StreamReadFailed;

        if (c.SetConsoleCtrlHandler(onControl, 1) == 0)
            return error.StreamInterruptSetupFailed;

        return .{ .handle = handle, .kind = c.GetFileType(handle) };
    }

    pub fn deinit(_: *Input) void {
        _ = c.SetConsoleCtrlHandler(onControl, 0);
    }

    pub fn check(_: *Input) !void {
        if (@atomicLoad(u8, &interrupted, .seq_cst) != 0)
            return error.StreamInterrupted;
    }

    /// Anonymous pipes cannot be waited on, so they are polled for pending bytes.
    pub fn read(self: *Input, buffer: []u8) !usize {
        while (true) {
            try self.check();

            switch (self.kind) {
                c.FILE_TYPE_PIPE => {
                    var pending: c.DWORD = 0;

                    if (c.PeekNamedPipe(self.handle, null, 0, null, &pending, null) == 0)
                        return finished(c.GetLastError());

                    if (pending == 0) {
                        c.Sleep(5);
                        continue;
                    }
                },
                c.FILE_TYPE_CHAR => if (c.WaitForSingleObject(self.handle, 50) != c.WAIT_OBJECT_0)
                    continue,
                else => {},
            }

            var count: c.DWORD = 0;
            const length: c.DWORD = @intCast(@min(buffer.len, std.math.maxInt(c.DWORD)));

            if (c.ReadFile(self.handle, buffer.ptr, length, &count, null) == 0)
                return finished(c.GetLastError());

            try self.check();
            return count;
        }
    }

    fn finished(code: c.DWORD) !usize {
        return switch (code) {
            c.ERROR_BROKEN_PIPE, c.ERROR_HANDLE_EOF => 0,
            else => error.StreamReadFailed,
        };
    }
};

test "console control events interrupt reads" {
    if (builtin.os.tag != .windows)
        return error.SkipZigTest;

    var input = try Input.init();
    defer input.deinit();

    try input.check();
    try std.testing.expectEqual(@as(c.BOOL, 1), onControl(0));
    try std.testing.expectError(error.StreamInterrupted, input.check());
    var buffer: [1]u8 = undefined;

    try std.testing.expectError(error.StreamInterrupted, input.read(&buffer));
}

test "pipe input drains bytes before EOF" {
    if (builtin.os.tag != .windows)
        return error.SkipZigTest;

    var reader: c.HANDLE = null;
    var writer: c.HANDLE = null;

    try std.testing.expect(c.CreatePipe(&reader, &writer, null, 0) != 0);
    defer _ = c.CloseHandle(reader);
    var written: c.DWORD = 0;

    try std.testing.expect(c.WriteFile(writer, "rgb", 3, &written, null) != 0);
    _ = c.CloseHandle(writer);

    var input = try Input.init();
    defer input.deinit();
    input.handle = reader;
    input.kind = c.FILE_TYPE_PIPE;
    var buffer: [8]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 3), try input.read(&buffer));
    try std.testing.expectEqualStrings("rgb", buffer[0..3]);
    try std.testing.expectEqual(@as(usize, 0), try input.read(&buffer));
}
