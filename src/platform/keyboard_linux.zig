const std = @import("std");
const c = @import("keyboard_input_c");

pub const Keyboard = struct {
    fds: [8]c_int = undefined,
    len: usize = 0,
    cursor: usize = 0,

    pub fn open(pid: u16) !Keyboard {
        var self: Keyboard = .{};
        const count = c.rz_keyboard_open_all(pid, &self.fds, self.fds.len);
        if (count < 0) {
            if (std.c._errno().* == c.EACCES or std.c._errno().* == c.EPERM)
                return error.KeyboardPermissionDenied;
            return error.KeyboardOpenFailed;
        }
        if (count == 0) return error.KeyboardNotFound;
        self.len = @intCast(count);
        return self;
    }

    pub fn deinit(self: *Keyboard) void {
        for (self.fds[0..self.len]) |fd| {
            _ = c.close(fd);
        }
    }

    pub fn next(self: *Keyboard) !?struct { code: u16, pressed: bool } {
        while (self.cursor < self.len) {
            var kind: u16 = 0;
            var code: u16 = 0;
            var value: c_int = 0;
            switch (c.rz_keyboard_next(self.fds[self.cursor], &kind, &code, &value)) {
                0 => self.cursor += 1,
                1 => if (kind == c.EV_KEY) {
                    return .{ .code = code, .pressed = value != 0 };
                },
                else => return error.KeyboardReadFailed,
            }
        }
        self.cursor = 0;
        return null;
    }
};

test "evdev reader preserves quick taps and reports truncated input" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    try std.testing.expect(c.fcntl(fds[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK)) >= 0);
    var event: c.struct_input_event = std.mem.zeroes(c.struct_input_event);
    event.type = c.EV_KEY;
    event.code = c.KEY_Q;
    var kind: u16 = 0;
    var code: u16 = 0;
    var value: c_int = 0;
    for ([_]i32{ 1, 0, 2 }) |state| {
        event.value = state;
        try std.testing.expectEqual(@as(isize, @sizeOf(@TypeOf(event))), c.write(fds[1], &event, @sizeOf(@TypeOf(event))));
    }

    for ([_]i32{ 1, 0, 2 }) |state| {
        try std.testing.expectEqual(@as(c_int, 1), c.rz_keyboard_next(fds[0], &kind, &code, &value));
        try std.testing.expectEqual(@as(u16, c.KEY_Q), code);
        try std.testing.expectEqual(state, value);
    }
    try std.testing.expectEqual(@as(c_int, 0), c.rz_keyboard_next(fds[0], &kind, &code, &value));
    _ = c.write(fds[1], &event, 1);
    try std.testing.expectEqual(@as(c_int, -1), c.rz_keyboard_next(fds[0], &kind, &code, &value));
}
