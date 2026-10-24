//! Shared argument grammar for validation, help and completion.

const std = @import("std");
const Writer = std.Io.Writer;
const Table = @import("table.zig").Table;

pub const Arg = union(enum) {
    value: []const u8,
    choices: []const []const u8,
    /// `extra` is a word accepted instead of a number, like `auto`.
    range: struct { min: u32, max: u32, extra: ?[]const u8 = null },
    toggle,
};

pub const Param = struct {
    arg: Arg,
    /// Completion suggestions for an open-ended value.
    candidates: []const []const u8 = &.{},
    optional: bool = false,
    repeat: u8 = 1,
};

/// Flags are always optional in usage text.
pub const Flag = struct {
    name: []const u8,
    param: ?Param = null,
    short: ?u8 = null,
    note: []const u8 = "",

    pub fn matches(flag: Flag, spelling: []const u8) bool {
        if (std.mem.startsWith(u8, spelling, "--"))
            return std.mem.eql(u8, spelling[2..], flag.name);

        return spelling.len == 2 and spelling[0] == '-' and
            flag.short != null and spelling[1] == flag.short.?;
    }
};

pub const Command = struct {
    name: []const u8,
    params: []const Param = &.{},
    flags: []const Flag = &.{},
    subs: []const Command = &.{},
    note: []const u8 = "",
};

test "flag spelling shares long and short alias matching without a fixed buffer" {
    const flag: Flag = .{ .name = "help", .short = 'h' };

    try std.testing.expect(flag.matches("--help"));
    try std.testing.expect(flag.matches("-h"));
    try std.testing.expect(!flag.matches("help"));
    try std.testing.expect(!flag.matches("--h"));
    try std.testing.expect(!flag.matches("-help"));
    const long: Flag = .{ .name = &@as([80]u8, @splat('a')) };

    try std.testing.expect(long.matches("--" ++ @as([80]u8, @splat('a'))));
}

pub const Help = struct {
    table: Table,

    pub fn init(allocator: std.mem.Allocator) Help {
        return .{ .table = .init(allocator) };
    }

    /// Parameterless alternatives fit as `<a|b>`; otherwise each gets its own line and the command ends in `:`.
    pub fn command(h: *Help, cmd: Command) !void {
        const allocator = h.table.allocator;

        if (cmd.subs.len == 0)
            return h.table.add(&.{ try usage(allocator, cmd), cmd.note });

        for (cmd.subs) |s| {
            if (s.params.len > 0) {
                try h.table.add(&.{ try allocator.print("{s}:", .{try usage(allocator, cmd)}), cmd.note });

                for (cmd.subs) |sub|
                    try h.table.addSub(try usage(allocator, sub));

                return;
            }
        }

        const alts = try allocator.alloc([]const u8, cmd.subs.len);

        for (cmd.subs, alts) |s, *a|
            a.* = s.name;

        try h.table.add(&.{
            try allocator.print("{s} {s}", .{ try usage(allocator, cmd), try paramText(allocator, .{ .arg = .{ .choices = alts } }) }),
            cmd.note,
        });
    }
    pub fn option(h: *Help, f: Flag) !void {
        const allocator = h.table.allocator;
        var aw: Writer.Allocating = .init(allocator);
        const w = &aw.writer;

        if (f.short) |c|
            try w.print("-{c}, ", .{c});

        try w.print("--{s}", .{f.name});

        if (f.param) |p|
            try w.print(" {s}", .{try paramText(allocator, p)});

        try h.table.add(&.{ aw.written(), f.note });
    }
};

/// `name [--flag <x>] <param> [param]`, without the alternatives.
pub fn usage(allocator: std.mem.Allocator, cmd: Command) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);
    const w = &aw.writer;

    try w.writeAll(cmd.name);

    for (cmd.flags) |f| {
        if (f.param) |p| {
            try w.print(" [--{s} {s}]", .{ f.name, try paramText(allocator, p) });
        } else {
            try w.print(" [--{s}]", .{f.name});
        }
    }

    for (cmd.params) |p|
        try w.print(" {s}", .{try paramText(allocator, p)});

    return aw.written();
}

fn argText(allocator: std.mem.Allocator, arg: Arg) ![]const u8 {
    return switch (arg) {
        .value => |v| v,
        .choices => |c| try std.mem.join(allocator, "|", c),
        .range => |r| if (r.extra) |x| try allocator.print("{d}-{d}|{s}", .{ r.min, r.max, x }) else try allocator.print("{d}-{d}", .{ r.min, r.max }),
        .toggle => "on|off",
    };
}

/// A required first occurrence is `<x>`; every further one is optional and
/// nests inside the last: `[x [x]]`.
pub fn paramText(allocator: std.mem.Allocator, p: Param) ![]const u8 {
    const inner = try argText(allocator, p.arg);
    var aw: Writer.Allocating = .init(allocator);
    const w = &aw.writer;
    const n = @max(p.repeat, 1);

    if (p.optional) {
        for (0..n) |i|
            try w.print("{s}[{s}", .{ if (i > 0) " " else "", inner });

        try w.splatByteAll(']', n);
    } else {
        try w.print("<{s}>", .{inner});

        for (1..n) |_|
            try w.print(" [{s}", .{inner});

        try w.splatByteAll(']', n - 1);
    }

    return aw.written();
}

pub fn names(allocator: std.mem.Allocator, items: anytype) ![]const []const u8 {
    const list = try allocator.alloc([]const u8, items.len);

    for (items, list) |item, *n|
        n.* = item.name;

    return list;
}

test "usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const eq = std.testing.expectEqualStrings;

    try eq("mode <a|bc>", try usage(allocator, .{ .name = "mode", .params = &.{.{ .arg = .{ .choices = &.{ "a", "bc" } } }} }));
    try eq("fan <2000-5400|auto>", try usage(allocator, .{ .name = "fan", .params = &.{.{ .arg = .{ .range = .{ .min = 2000, .max = 5400, .extra = "auto" } } }} }));
    try eq("fan-high [1900-3200]", try usage(allocator, .{
        .name = "fan-high",
        .params = &.{.{ .arg = .{ .range = .{ .min = 1900, .max = 3200 } }, .optional = true }},
    }));
    try eq("get [--json]", try usage(allocator, .{ .name = "get", .flags = &.{.{ .name = "json" }} }));
    try eq("effect [--level <1-4>]", try usage(allocator, .{
        .name = "effect",
        .flags = &.{.{ .name = "level", .param = .{ .arg = .{ .range = .{ .min = 1, .max = 4 } } } }},
    }));
    try eq("starlight [colour [colour]] [short|medium|long]", try usage(allocator, .{ .name = "starlight", .params = &.{
        .{ .arg = .{ .value = "colour" }, .optional = true, .repeat = 2 },
        .{ .arg = .{ .choices = &.{ "short", "medium", "long" } }, .optional = true },
    } }));
    try eq("x <on|off> [on|off]", try usage(allocator, .{ .name = "x", .params = &.{.{ .arg = .toggle, .repeat = 2 }} }));
}

fn renderHelp(h: *const Help) []const u8 {
    const allocator = h.table.allocator;
    var aw: Writer.Allocating = .init(allocator);

    h.table.render(&aw.writer, .{ .indent = 4, .gap = 6 }) catch unreachable;
    return aw.written();
}

test "help layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var h: Help = .init(allocator);

    try h.command(.{ .name = "a", .note = "Note." });
    try h.command(.{ .name = "a-much-longer-command" });
    try h.command(.{ .name = "logo", .subs = &.{ .{ .name = "off" }, .{ .name = "static" } } });
    try h.command(.{
        .name = "effect",
        .note = "N.",
        .subs = &.{
            .{ .name = "off" },
            .{ .name = "static", .params = &.{.{ .arg = .{ .value = "colour" }, .optional = true }} },
        },
    });

    try std.testing.expectEqualStrings(
        \\    a            Note.
        \\    a-much-longer-command
        \\    logo <off|static>
        \\    effect:      N.
        \\      off
        \\      static [colour]
        \\
    , renderHelp(&h));
}
