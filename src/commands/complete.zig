//! `__complete`: completion candidates for the shell, one per line.

const std = @import("std");
const device = @import("device_types");
const settings = @import("settings");
const devices = @import("../device/select.zig");
const args = @import("../interface/args.zig");
const ui = @import("ui");
const command = @import("../interface/command.zig");

pub const entry: command.Entry = .{
    .definition = .{
        .name = "__complete",
        .note = "",
        .hidden = true,
        .grammar = .payload,
        .options = &.{},
    },
    .execute = execute,
};

pub fn execute(context: command.Context, invocation: args.Invocation, output: *ui.Output) !void {
    if (invocation.options.len != 0)
        return try output.writeError("__complete payload must follow --", null);

    switch (try complete(context.allocator, context.definitions, invocation.arguments)) {
        .success => |items| try output.writeCandidates(items),
        .failure => |failure| try output.writeError(failure.message, failure.err),
    }
}

/// Payload excludes the word currently being edited; zsh filters its prefix.
pub fn complete(allocator: std.mem.Allocator, definitions: []const command.Definition, words: []const [:0]const u8) !ui.Result([]const []const u8) {
    var candidates_: std.ArrayList([]const u8) = .empty;

    if (words.len == 0) {
        for (definitions) |def|
            if (!def.hidden)
                try candidate(allocator, &candidates_, def.name);

        return .{ .success = candidates_.items };
    }

    const inv = args.group(allocator, words) catch |err|
        return .{ .failure = .{ .message = "cannot parse completion words", .err = err } };

    const def = command.find(definitions, inv.command) orelse
        return .{ .success = candidates_.items };

    if (def.hidden)
        return .{ .success = candidates_.items };

    const selector = def.deviceSpec(inv);

    for (def.options) |flag| {
        if (!hasOption(def, inv, flag.name))
            try candidate(allocator, &candidates_, try allocator.print("--{s}", .{flag.name}));
    }

    if (!def.takesDevice())
        return .{ .success = candidates_.items };

    const action = def.action();
    const offer_ids = inv.options.len == 0 and selector == null and
        (def.grammar != .device_file or inv.arguments.len == 0);

    if (action == null and !offer_ids)
        return .{ .success = candidates_.items };

    var found: ?device.Descriptor = null;

    if (selector) |sel| {
        found = devices.find(sel);
    } else {
        const attached = devices.attached(allocator) catch |err|
            return .{ .failure = .{ .message = "cannot enumerate Razer devices", .err = err } };

        if (offer_ids)
            for (attached) |d|
                try candidate(allocator, &candidates_, try allocator.print("0x{x:0>4}", .{d.pid}));

        found = devices.automatic(attached);
    }
    const setting_action = action orelse return .{ .success = candidates_.items };

    const desc = &(found orelse return .{ .success = candidates_.items });
    const catalog: settings.Catalog = try .init(allocator, desc);
    const rest = try settingWords(allocator, def, inv);
    const writing = setting_action == .set;

    if (writing) {
        // Complete the last setting's values until the next setting begins.
        var active: ?struct { setting: settings.Setting, arguments: []const [:0]const u8 } = null;

        for (rest, 0..) |word, i| {
            if (std.mem.startsWith(u8, word, "--"))
                if (catalog.find(word[2..])) |s| {
                    active = .{ .setting = s, .arguments = rest[i + 1 ..] };
                };
        }

        if (active) |last|
            if (last.setting.write != null)
                try values(allocator, &candidates_, last.setting.usage, last.arguments);
    }

    for (catalog.items) |s| {
        if (settings.selectable(s, setting_action))
            try option(allocator, &candidates_, rest, try allocator.print("--{s}", .{s.usage.name}));
    }

    return .{ .success = candidates_.items };
}

fn hasOption(def: command.Definition, invocation: args.Invocation, name: []const u8) bool {
    for (invocation.options) |opt|
        if (def.option(opt.spelling)) |flag| {
            if (std.mem.eql(u8, flag.name, name))
                return true;
        };

    return false;
}

fn settingWords(allocator: std.mem.Allocator, def: command.Definition, invocation: args.Invocation) ![]const [:0]const u8 {
    var excluded: std.ArrayList([]const u8) = .empty;

    for (invocation.options) |opt| {
        if (def.option(opt.spelling) != null)
            try excluded.append(allocator, opt.spelling);
    }

    return invocation.optionWordsExcept(allocator, excluded.items);
}

fn option(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), rest: []const [:0]const u8, opt: []const u8) !void {
    if (!given(rest, opt))
        try candidate(allocator, list, opt);
}

fn given(rest: []const [:0]const u8, word: []const u8) bool {
    for (rest) |a|
        if (std.mem.eql(u8, a, word))
            return true;

    return false;
}

/// A setting's argument position: its options, then value candidates until
/// every parameter slot is filled.
fn values(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), usage: ui.Command, rest: []const [:0]const u8) !void {
    var u = usage;

    // A flag's own argument is not offered as a setting value.
    if (rest.len > 0 and flagWithParam(u, rest[rest.len - 1]) != null)
        return;

    for (u.flags) |f|
        try option(allocator, list, rest, try allocator.print("--{s}", .{f.name}));

    const arguments = positionals(u, rest);
    var taken = arguments.count;

    if (u.subs.len > 0) {
        const first = arguments.first orelse {
            for (u.subs) |sub|
                try candidate(allocator, list, sub.name);

            return;
        };
        const sub = findSub(u, first) orelse return;

        u.params = sub.params;
        taken -= 1;
    }

    var slots: usize = 0;

    for (u.params) |p|
        slots += p.repeat;

    if (taken >= slots)
        return;

    // Some commands take their values in any order, so every unfilled
    // parameter's candidates are offered rather than one position's.
    for (u.params) |p| {
        for (p.candidates) |value|
            try candidate(allocator, list, value);

        try valueCandidates(allocator, list, p.arg);
    }
}

fn valueCandidates(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), arg: ui.Arg) !void {
    switch (arg) {
        .choices => |c| for (c) |value| try candidate(allocator, list, value),
        .toggle => {
            try candidate(allocator, list, "on");
            try candidate(allocator, list, "off");
        },
        .range => |r| if (r.extra) |x| try candidate(allocator, list, x),
        .value => {},
    }
}

fn candidate(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    try list.append(allocator, value);
}

fn findSub(u: ui.Command, name: []const u8) ?ui.Command {
    for (u.subs) |sub| {
        if (std.mem.eql(u8, sub.name, name))
            return sub;
    }

    return null;
}

fn flagWithParam(u: ui.Command, word: []const u8) ?ui.Flag {
    for (u.flags) |f| {
        if (f.param == null)
            continue;

        if (f.matches(word))
            return f;
    }

    return null;
}

const Positionals = struct { count: usize = 0, first: ?[]const u8 = null };

test "play completion does not reoffer device ids after a file or leading id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const definitions = [_]command.Definition{
        .{ .name = "play", .note = "", .grammar = .device_file },
    };
    for ([_][:0]const u8{ "stars.json", "0x02b6" }) |argument| {
        const result = try complete(arena.allocator(), &definitions, &.{ "play", argument });
        try std.testing.expect(result == .success);
        try std.testing.expectEqual(@as(usize, 1), result.success.len);
        try std.testing.expectEqualStrings("--help", result.success[0]);
    }
}

fn positionals(u: ui.Command, rest: []const [:0]const u8) Positionals {
    var result: Positionals = .{};
    var i: usize = 0;

    while (i < rest.len) : (i += 1) {
        if (args.isOption(rest[i])) {
            if (flagWithParam(u, rest[i]) != null)
                i += 1;

            continue;
        }

        if (result.first == null)
            result.first = rest[i];

        result.count += 1;
    }

    return result;
}

test "positionals skip options and their arguments" {
    const effect_command = ui.Command{
        .name = "effect",
        .flags = &.{.{ .name = "tone", .param = .{ .arg = .{ .value = "g" } } }},
    };
    const words = [_][:0]const u8{ "--tone", "warm", "static", "red" };

    try std.testing.expectEqual(@as(usize, 2), positionals(effect_command, &words).count);
    try std.testing.expectEqualStrings("static", positionals(effect_command, &words).first.?);
    const bare = [_][:0]const u8{ "static", "--save" };

    try std.testing.expectEqual(@as(usize, 1), positionals(effect_command, &bare).count);
}

test "open-ended value candidates come from their owner regardless of placeholder name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    const usage: ui.Command = .{
        .name = "example",
        .params = &.{.{ .arg = .{ .value = "anything" }, .candidates = &.{ "first", "second" } }},
    };

    try values(a, &list, usage, &.{});
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("first", list.items[0]);
    try std.testing.expectEqualStrings("second", list.items[1]);
    list.clearRetainingCapacity();
    try values(a, &list, usage, &.{"filled"});
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
    try values(a, &list, .{ .name = "unrelated", .params = &.{.{ .arg = .{ .value = "colour" } }} }, &.{});
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}
