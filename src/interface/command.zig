//! Command definitions: grammar, options and validated invocations.
const std = @import("std");
const ui = @import("ui");
const setting_types = @import("setting_types");
pub const args = @import("args.zig");

pub const help_option: ui.Flag = .{ .name = "help", .short = 'h', .note = "Display this help." };

pub const Validation = union(enum) {
    valid,
    missing_input,
    invalid: []const u8,
};

pub const Definition = struct {
    name: []const u8,
    note: []const u8,
    aliases: []const []const u8 = &.{},
    grammar: union(enum) {
        plain,
        device,
        device_file,
        settings: setting_types.Action,
        payload,
    } = .plain,
    hidden: bool = false,
    handles_help: bool = false,
    options: []const ui.Flag = &.{help_option},
    help: struct {
        description: []const u8 = "",
        settings: enum { selectors, values } = .selectors,
        feature_references: bool = false,
    } = .{},

    pub fn takesDevice(self: Definition) bool {
        return self.grammar == .device or self.grammar == .device_file or self.grammar == .settings;
    }

    pub fn deviceSpec(self: Definition, inv: args.Invocation) ?[]const u8 {
        const has_id = if (self.grammar == .device_file)
            inv.arguments.len == 2 or (inv.arguments.len == 1 and (inv.hasOption("--help") or inv.hasOption("-h")))
        else
            self.takesDevice() and inv.arguments.len > 0;
        return if (has_id) inv.arguments[0] else null;
    }

    pub fn action(self: Definition) ?setting_types.Action {
        return if (self.grammar == .settings) self.grammar.settings else null;
    }

    pub fn named(self: Definition, word: []const u8) bool {
        if (args.is(word, self.name))
            return true;

        for (self.aliases) |alias|
            if (args.is(word, alias))
                return true;

        return false;
    }

    pub fn option(self: Definition, word: []const u8) ?ui.Flag {
        for (self.options) |flag| {
            if (flag.matches(word))
                return flag;
        }

        return null;
    }

    pub fn validate(self: Definition, allocator: std.mem.Allocator, inv: args.Invocation) !Validation {
        if (self.grammar == .payload)
            return .valid;

        if (!args.is(inv.command, self.name) and (inv.arguments.len != 0 or inv.options.len != 0))
            return .{ .invalid = try allocator.print("{s} takes no arguments", .{self.name}) };

        if (self.grammar == .device_file) {
            if (inv.arguments.len > 2)
                return .{ .invalid = try allocator.print("{s} takes one file and an optional device id", .{self.name}) };
        } else if (inv.arguments.len > @intFromBool(self.takesDevice()))
            return .{ .invalid = try allocator.print("{s} takes {s}", .{ self.name, if (self.takesDevice()) "only an optional device id" else "no arguments" }) };

        var wants_help = false;
        var has_setting = false;
        for (inv.options, 0..) |opt, i| {
            const flag = self.option(opt.spelling) orelse {
                if (self.grammar == .settings) {
                    has_setting = true;
                    continue;
                }

                return .{ .invalid = try allocator.print("'{s}' is not an option for {s}", .{ opt.spelling, self.name }) };
            };

            if (opt.values.len != 0)
                return .{ .invalid = try allocator.print("{s} takes no value", .{opt.spelling}) };

            for (inv.options[0..i]) |previous|
                if (self.option(previous.spelling)) |prior| {
                    if (args.is(prior.name, flag.name))
                        return .{ .invalid = try allocator.print("'{s}' was given more than once", .{opt.spelling}) };
                };
            if (args.is(flag.name, "help"))
                wants_help = true;
        }

        if (!wants_help) {
            if (self.grammar == .device_file and inv.arguments.len == 0)
                return .missing_input;
            if (self.action() == .set and !has_setting)
                return .missing_input;
        }
        return .valid;
    }
};

pub fn find(definitions: []const Definition, word: []const u8) ?Definition {
    for (definitions) |def|
        if (def.named(word))
            return def;

    return null;
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    root: Definition,
    definitions: []const Definition,
};

pub const Execute = *const fn (Context, args.Invocation, *ui.Output) ui.Error!void;
pub const Entry = struct { definition: Definition, execute: Execute };

/// The executable's root command: its global options and no-subcommand action.
pub const Root = struct {
    definition: Definition,
    default_entry: Entry,
};

test "command grammar rejects duplicate aliases values and positional arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const def: Definition = .{ .name = "version", .note = "" };

    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "version", "--help", "-h" }))) == .invalid);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "version", "--help", "value" }))) == .invalid);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "version", "now" }))) == .invalid);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "version", "--json" }))) == .invalid);
}

test "file playback accepts an optional leading device id and requires one file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const def: Definition = .{ .name = "play", .note = "", .grammar = .device_file };
    const file = try args.group(a, &.{ "play", "stars.json" });
    try std.testing.expect((try def.validate(a, file)) == .valid);
    try std.testing.expect(def.deviceSpec(file) == null);
    const selected = try args.group(a, &.{ "play", "0x02b6", "stars.json" });
    try std.testing.expect((try def.validate(a, selected)) == .valid);
    try std.testing.expectEqualStrings("0x02b6", def.deviceSpec(selected).?);
    const selected_help = try args.group(a, &.{ "play", "0x02b6", "--help" });
    try std.testing.expectEqualStrings("0x02b6", def.deviceSpec(selected_help).?);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "play", "--help" }))) == .valid);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{"play"}))) == .missing_input);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "play", "a", "b", "c" }))) == .invalid);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "play", "a", "--unknown" }))) == .invalid);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "play", "--unknown" }))) == .invalid);
}

test "grammar distinguishes plain device settings and literal payload requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const plain: Definition = .{ .name = "version", .note = "" };
    const device: Definition = .{ .name = "probe", .note = "", .grammar = .device };
    const settings: Definition = .{ .name = "set", .note = "", .grammar = .{ .settings = .set } };
    const payload: Definition = .{ .name = "__complete", .note = "", .grammar = .payload };
    const inv = try args.group(a, &.{ "set", "0x02b6", "--brightness", "20" });

    try std.testing.expect(!plain.takesDevice());
    try std.testing.expect(device.takesDevice());
    try std.testing.expect(settings.takesDevice());
    try std.testing.expect(!payload.takesDevice());
    try std.testing.expect(device.action() == null);
    try std.testing.expect(settings.action().? == .set);
    try std.testing.expect((try plain.validate(a, inv)) == .invalid);
    try std.testing.expect((try device.validate(a, try args.group(a, &.{ "probe", "0x02b6", "--brightness", "20" }))) == .invalid);
    try std.testing.expect((try settings.validate(a, inv)) == .valid);
    try std.testing.expect((try payload.validate(a, try args.group(a, &.{ "__complete", "--", "set", "--help" }))) == .valid);
}

test "missing settings exclude command flags and preserve optional-selector commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const def: Definition = .{
        .name = "set",
        .note = "",
        .grammar = .{ .settings = .set },
        .options = &.{ help_option, .{ .name = "save", .note = "" } },
    };
    try std.testing.expect((try def.validate(a, try args.group(a, &.{"set"}))) == .missing_input);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "set", "0x02b6" }))) == .missing_input);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "set", "--save" }))) == .missing_input);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "set", "-h" }))) == .valid);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "set", "--brightness" }))) == .valid);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "set", "--unknown" }))) == .valid);
    try std.testing.expect((try def.validate(a, try args.group(a, &.{ "set", "--save", "--save" }))) == .invalid);
    inline for (.{ .get, .save, .restore }) |action| {
        const optional: Definition = .{ .name = "optional", .note = "", .grammar = .{ .settings = action } };
        try std.testing.expect((try optional.validate(a, try args.group(a, &.{"optional"}))) == .valid);
    }
}

test "invocation identifies exact option spellings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inv = try args.group(a, &.{ "set", "0x02b6", "--effect", "static", "--save", "--brightness", "20" });

    try std.testing.expect(inv.hasOption("--save"));
    try std.testing.expect(!inv.hasOption("save"));
}
