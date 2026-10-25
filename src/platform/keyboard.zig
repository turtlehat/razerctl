const std = @import("std");
const builtin = @import("builtin");
const chroma = @import("chroma");
const lighting = @import("lighting_types");
const transport = @import("transport");
const Backend = switch (builtin.os.tag) {
    .linux => @import("keyboard_linux.zig").Keyboard,
    .windows => @import("keyboard_windows.zig").Keyboard,
    else => @compileError("keyboard input is not supported on " ++ @tagName(builtin.os.tag)),
};

pub const Keyboard = struct {
    backend: Backend,
    entries: []const lighting.key_maps.Entry,

    pub fn open(pid: u16, hid: *transport.Device, config: lighting.Config, rows: u8, columns: u8) !Keyboard {
        const map = selected: {
            try hid.acquire();
            defer hid.release();
            const edition = try hid.call(.{ .id = 0x0086, .min_response = 2 }, &.{ 0, 0, 0 });
            break :selected config.selectKeyMap(edition.args[1], edition.args[0]) orelse
                return error.KeyboardLayoutUnsupported;
        };
        if (map.rows != rows or map.columns != columns)
            return error.KeyboardLayoutUnsupported;
        return .{ .entries = map.entries, .backend = try Backend.open(pid) };
    }

    pub fn deinit(self: *Keyboard) void {
        self.backend.deinit();
    }

    pub fn drain(self: *Keyboard, p: *const chroma.Profile, device: usize, tick: u64) !void {
        while (try self.backend.next()) |event| {
            for (self.entries) |entry| {
                if (entry.code != event.code) continue;
                try chroma.input(p.*, device, .{
                    .row = entry.row,
                    .col = entry.col,
                    .pressed = event.pressed,
                }, tick);
            }
        }
    }
};

// Measured ANSI Blade mapping retained as a regression reference.
fn measuredCell(code: u16) ?[2]u8 {
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

test "shared input maps preserve every measured Blade key" {
    const entries = lighting.key_maps.blade_ansi;
    for (0..256) |code| {
        if (measuredCell(@intCast(code))) |position| {
            var found = false;
            for (entries) |entry|
                if (entry.code == code and entry.row == position[0] and entry.col == position[1]) {
                    found = true;
                };
            try std.testing.expect(found);
        }
    }
    var space = false;
    for (entries) |entry|
        if (entry.code == 57 and entry.row == 5 and entry.col == 6) {
            space = true;
        };
    try std.testing.expect(space);
}

test {
    _ = Backend;
}
