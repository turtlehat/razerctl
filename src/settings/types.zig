//! Contracts exchanged between feature declarations and the settings engine.

const std = @import("std");
const device = @import("device_types");
const transport = @import("transport");
const ui = @import("ui");

pub const Reading = struct { val: ui.Val, note: []const u8 = "" };

/// Validated before any hardware write.
pub const Input = union(enum) {
    none,
    num: u16,
    choice: usize,
    flag: bool,
    word: []const u8,
    args: []const [:0]const u8,
    /// Feature-prepared wire data owned by the operation's allocator.
    payload: []const u8,
};

pub const Read = *const fn (std.mem.Allocator, *transport.Device, *const device.Descriptor, u8) anyerror!Reading;
pub const Write = *const fn (std.mem.Allocator, *transport.Device, *const device.Descriptor, u8, Input) anyerror!void;

pub const Setting = struct {
    usage: ui.Command,
    ctx: u8 = 0,
    read: ?Read = null,
    write: ?Write = null,
    prepare: ?*const fn (std.mem.Allocator, *const device.Descriptor, u8, Input) ui.Error!ui.Result(Input) = null,
    unit: ?ui.Unit = null,

    /// Common argument grammar, then the feature's device-specific checks.
    /// Set, capture and restore all use this before reaching a writer.
    pub fn parse(s: Setting, allocator: std.mem.Allocator, desc: *const device.Descriptor, args: []const [:0]const u8) !ui.Result(Input) {
        const input = switch (try parseSyntax(allocator, s, args)) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        };

        if (s.prepare) |prepare|
            return prepare(allocator, desc, s.ctx, input);

        return .{ .success = input };
    }
};

pub const Operation = struct {
    setting: Setting,
    args: []const [:0]const u8,
    input: Input = .none,
};

pub const Action = enum { get, set, save, restore };

pub fn selectable(s: Setting, action: Action) bool {
    return switch (action) {
        .get => s.read != null,
        .set, .restore => s.write != null,
        .save => s.read != null and s.write != null,
    };
}

pub const Settings = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Setting) = .empty,

    pub fn init(allocator: std.mem.Allocator) Settings {
        return .{ .allocator = allocator };
    }

    /// Copies `usage` slices because features build params in literals on
    /// their own stack.
    pub fn add(s: *Settings, setting: Setting) !void {
        const allocator = s.allocator;
        var copy = setting;

        copy.usage.params = try allocator.dupe(ui.Param, setting.usage.params);
        copy.usage.flags = try allocator.dupe(ui.Flag, setting.usage.flags);
        try s.items.append(allocator, copy);
    }
};

fn parseSyntax(allocator: std.mem.Allocator, s: Setting, args: []const [:0]const u8) !ui.Result(Input) {
    const u = s.usage;

    if (u.flags.len > 0 or u.subs.len > 0 or u.params.len > 1) {
        if (args.len == 0)
            return .{ .failure = .{ .message = try allocator.print("{s} needs a value: {s}", .{ u.name, try ui.usage(allocator, u) }) } };

        return .{ .success = .{ .args = args } };
    }

    if (u.params.len == 0) {
        if (args.len > 0)
            return .{ .failure = .{ .message = try allocator.print("{s} takes no value -- got '{s}'", .{ u.name, args[0] }) } };

        return .{ .success = .none };
    }

    const p = u.params[0];

    if (args.len == 0) {
        if (p.optional)
            return .{ .success = .none };

        return .{ .failure = .{ .message = try allocator.print("{s} needs a value: {s}", .{ u.name, try ui.usage(allocator, u) }) } };
    }

    if (args.len > 1)
        return .{ .failure = .{ .message = try allocator.print("{s} takes one value -- got '{s}' as well", .{ u.name, args[1] }) } };

    const input = parseArg(p.arg, s.unit, args[0]) orelse
        return .{ .failure = .{ .message = try allocator.print("{s}: expected {s} -- got '{s}'", .{ u.name, try ui.paramText(allocator, .{ .arg = p.arg }), args[0] }) } };
    return .{ .success = input };
}

fn parseArg(arg: ui.Arg, unit: ?ui.Unit, a: []const u8) ?Input {
    switch (arg) {
        .value => return .{ .word = a },
        .toggle => {
            const toggle = std.meta.stringToEnum(enum { off, on }, a) orelse return null;

            return .{ .flag = toggle == .on };
        },
        .choices => |choices| {
            for (choices, 0..) |name, i|
                if (std.mem.eql(u8, name, a))
                    return .{ .choice = i };

            return null;
        },
        .range => |range| {
            if (range.extra) |extra|
                if (std.mem.eql(u8, extra, a))
                    return .{ .word = a };

            const suffix = if (unit) |un| std.mem.trim(u8, un.suffix(), " ") else "";
            const body = if (suffix.len > 0 and std.mem.endsWith(u8, a, suffix)) a[0 .. a.len - suffix.len] else a;
            const value = std.fmt.parseInt(u16, body, 10) catch return null;

            if (value < range.min or value > range.max)
                return null;

            return .{ .num = value };
        },
    }
}

test "arguments are checked against help's Arg" {
    const expectEqual = std.testing.expectEqual;
    const range: ui.Arg = .{ .range = .{ .min = 50, .max = 100 } };

    try expectEqual(@as(?Input, .{ .num = 80 }), parseArg(range, .percent, "80%"));
    try expectEqual(@as(?Input, .{ .num = 80 }), parseArg(range, .percent, "80"));
    try expectEqual(@as(?Input, null), parseArg(range, .percent, "49"));
    try expectEqual(@as(?Input, null), parseArg(range, null, "80%"));
    try expectEqual(@as(?Input, .{ .word = "auto" }), parseArg(.{ .range = .{ .min = 1, .max = 9, .extra = "auto" } }, .rpm, "auto"));
    try expectEqual(@as(?Input, .{ .num = 5 }), parseArg(.{ .range = .{ .min = 1, .max = 9 } }, .rpm, "5"));
    try expectEqual(@as(?Input, .{ .choice = 1 }), parseArg(.{ .choices = &.{ "a", "b" } }, null, "b"));
    try expectEqual(@as(?Input, null), parseArg(.{ .choices = &.{ "a", "b" } }, null, "c"));
    try expectEqual(@as(?Input, .{ .flag = false }), parseArg(.toggle, null, "off"));
    try expectEqual(@as(?Input, null), parseArg(.toggle, null, "no"));
}
