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
