const std = @import("std");
const builtin = @import("builtin");
const chroma = @import("chroma");
const c = if (builtin.os.tag == .linux) @import("keyboard_input_c") else struct {};

/// Every key-capable event node of one Razer product; a laptop keyboard
/// can report typing through more than one USB interface.
pub const Keyboard = struct {
    fds: [8]c_int = undefined,
    len: usize = 0,

    pub fn open(pid: u16) !Keyboard {
        if (builtin.os.tag != .linux) return error.KeyboardCaptureUnsupportedPlatform;
        if (pid != 0x02b6) return error.KeyboardLayoutUnsupported;
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
        if (builtin.os.tag == .linux) for (self.fds[0..self.len]) |fd| {
            _ = c.close(fd);
        };
    }

    pub fn drain(self: *Keyboard, p: *const chroma.Profile, device: usize, tick: u64) !void {
        if (builtin.os.tag != .linux) return error.KeyboardCaptureUnsupportedPlatform;
        for (self.fds[0..self.len]) |fd| try drainOne(fd, p, device, tick);
    }

    fn drainOne(fd: c_int, p: *const chroma.Profile, device: usize, tick: u64) !void {
        while (true) {
            var kind: u16 = 0;
            var code: u16 = 0;
            var value: c_int = 0;
            switch (c.rz_keyboard_next(fd, &kind, &code, &value)) {
                0 => return,
                1 => {},
                else => return error.KeyboardReadFailed,
            }
            if (kind != 1) continue;
            if (cell(code)) |position|
                try chroma.input(p.*, device, .{
                    .row = position[0],
                    .col = position[1],
                    .pressed = value != 0,
                }, tick);
        }
    }
};

// ANSI Blade 02b6 key codes to hardware cells, layout 1.
// Extended Linux key codes are translated explicitly; no character layout.
pub fn cell(code: u16) ?[2]u8 {
    return switch (code) {
        1 => .{ 0, 1 },
        59...68 => .{ 0, @intCast(code - 57) },
        87 => .{ 0, 12 },
        88 => .{ 0, 13 },
        110, 111 => .{ 0, 14 },
        41 => .{ 1, 1 },
        2...13 => .{ 1, @intCast(code) },
        14 => .{ 1, 15 },
        15 => .{ 2, 1 },
        16...27 => .{ 2, @intCast(code - 14) },
        43 => .{ 2, 15 },
        58 => .{ 3, 1 },
        30...40 => .{ 3, @intCast(code - 28) },
        28 => .{ 3, 15 },
        42 => .{ 4, 1 },
        44...53 => .{ 4, @intCast(code - 41) },
        54 => .{ 4, 15 },
        29 => .{ 5, 1 },
        125 => .{ 5, 3 },
        56 => .{ 5, 5 },
        100 => .{ 5, 9 },
        97 => .{ 5, 11 },
        105, 102 => .{ 5, 12 },
        103, 104 => .{ 5, 13 },
        106, 107 => .{ 5, 14 },
        108, 109 => .{ 5, 15 },
        else => null,
    };
}

test "Blade physical key mapping distinguishes extended keys and skips unmapped input" {
    try std.testing.expectEqual(@as(?[2]u8, .{ 2, 2 }), cell(16));
    try std.testing.expectEqual(@as(?[2]u8, .{ 5, 11 }), cell(97));
    try std.testing.expectEqual(@as(?[2]u8, .{ 5, 1 }), cell(29));
    try std.testing.expectEqual(@as(?[2]u8, null), cell(57));
    try std.testing.expectEqual(@as(?[2]u8, null), cell(272));
}

test "evdev reader preserves quick taps and reports truncated input" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
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
