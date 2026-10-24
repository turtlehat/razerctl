//! Command registry and routing; the only module that imports command modules.
const std = @import("std");
const ui = @import("ui");
const command = @import("interface/command.zig");
const args = command.args;
const help = @import("interface/help.zig");

const modules = .{
    .settings = @import("commands/settings.zig"),
    .list = @import("commands/list.zig"),
    .probe = @import("commands/probe.zig"),
    .stream = @import("commands/stream.zig"),
    .play = @import("commands/play.zig"),
    .help = @import("commands/help.zig"),
    .version = @import("commands/version.zig"),
    .complete = @import("commands/complete.zig"),
};

pub const entries = modules.settings.entries[0..2].* ++ [_]command.Entry{
    modules.play.entry,
} ++ modules.settings.entries[2..].* ++ [_]command.Entry{
    modules.list.entry,
    modules.probe.entry,
    modules.stream.entry,
    modules.help.entry,
    modules.version.entry,
    modules.complete.entry,
};

pub const definitions: [entries.len]command.Definition = blk: {
    var result: [entries.len]command.Definition = undefined;

    for (entries, &result) |entry, *def|
        def.* = entry.definition;

    break :blk result;
};

pub const root: command.Root = .{
    .definition = .{
        .name = "razerctl",
        .note = "",
        .options = &.{command.help_option},
    },
    .default_entry = modules.help.entry,
};

pub fn find(name: []const u8) ?command.Entry {
    for (entries) |entry|
        if (entry.definition.named(name))
            return entry;

    return null;
}

pub fn execute(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, inv: args.Invocation, output: *ui.Output) !void {
    const context: command.Context = .{
        .allocator = allocator,
        .io = io,
        .environ = environ,
        .root = root.definition,
        .definitions = &definitions,
    };

    if (isRootInvocation(inv)) {
        if (inv.command.len > 0 and (inv.arguments.len > 0 or inv.options.len > 0))
            return output.writeError(try allocator.print("{s} takes no arguments", .{root.definition.name}), null);

        return root.default_entry.execute(context, inv, output);
    }

    const entry = find(inv.command) orelse
        return output.writeError(try allocator.print("'{s}' is not a command -- see `razerctl help`", .{inv.command}), null);

    const def = entry.definition;

    switch (try def.validate(allocator, inv)) {
        .valid => {},
        .invalid => |message| return output.writeError(message, null),
        .missing_input => {
            output.exit_code = 1;
            return help.render(allocator, def, def.deviceSpec(inv), output);
        },
    }

    if (def.grammar != .payload and !def.handles_help and hasOption(def, inv, "help"))
        return help.render(allocator, def, def.deviceSpec(inv), output);

    return entry.execute(context, inv, output);
}

fn hasOption(def: command.Definition, inv: args.Invocation, name: []const u8) bool {
    for (inv.options) |option|
        if (def.option(option.spelling)) |flag| {
            if (args.is(flag.name, name))
                return true;
        };

    return false;
}

test "missing input uses command help while explicit help succeeds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var missing: ui.Output = .init(a);
    try execute(a, undefined, undefined, try args.group(a, &.{ "set", "0x02b6" }), &missing);
    try std.testing.expectEqual(@as(u8, 1), missing.exit_code);
    try std.testing.expectEqual(@as(usize, 0), missing.err.items.len);
    try std.testing.expect(missing.out.items.len > 0);
    var explicit: ui.Output = .init(a);
    try execute(a, undefined, undefined, try args.group(a, &.{ "set", "0x02b6", "--help" }), &explicit);
    try std.testing.expectEqual(@as(u8, 0), explicit.exit_code);
    try std.testing.expectEqual(missing.out.items.len, explicit.out.items.len);
    try std.testing.expectEqualStrings(missing.out.items[0].text, explicit.out.items[0].text);
    var invalid: ui.Output = .init(a);
    try execute(a, undefined, undefined, try args.group(a, &.{ "play", "--unknown" }), &invalid);
    try std.testing.expectEqual(@as(u8, 1), invalid.exit_code);
    try std.testing.expectEqual(@as(usize, 0), invalid.out.items.len);
    try std.testing.expectEqualStrings("'--unknown' is not an option for play", invalid.err.items[0].message);
}

test "hidden completion is dispatched through the registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entry = find("__complete").?;

    try std.testing.expect(entry.definition.hidden);
    var result: ui.Output = .init(a);

    try execute(a, undefined, undefined, try args.group(a, &.{ "__complete", "--", "version" }), &result);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    var unknown: ui.Output = .init(a);

    try execute(a, undefined, undefined, try args.group(a, &.{"stauts"}), &unknown);
    try std.testing.expectEqual(@as(u8, 1), unknown.exit_code);
    try std.testing.expectEqual(@as(usize, 0), unknown.out.items.len);
    try std.testing.expectEqualStrings("'stauts' is not a command -- see `razerctl help`", unknown.err.items[0].message);
    var invalid: ui.Output = .init(a);

    try execute(a, undefined, undefined, try args.group(a, &.{ "probe", "--effects", "--effects" }), &invalid);
    try std.testing.expectEqual(@as(u8, 1), invalid.exit_code);
    try std.testing.expect(invalid.err.items.len > 0);
}

test "root command declares global help and defaults to the help command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("razerctl", root.definition.name);
    try std.testing.expectEqualStrings("help", root.default_entry.definition.name);
    try std.testing.expect(root.definition.option("--help") != null);
    try std.testing.expect(root.definition.option("-h") != null);
    try std.testing.expect(root.definition.option("--version") == null);
    try std.testing.expect(find("") == null);
    try std.testing.expect(find("-h") == null);
    try std.testing.expect(find("--help") == null);
    const names = [_][]const u8{ "get", "set", "play", "save", "restore", "list", "probe", "stream", "help", "version", "__complete" };

    try std.testing.expectEqual(names.len, definitions.len);

    for (names, definitions) |name, def|
        try std.testing.expectEqualStrings(name, def.name);

    var version_help: ui.Output = .init(a);

    try execute(a, undefined, undefined, try args.group(a, &.{ "version", "--help" }), &version_help);
    try std.testing.expectEqualStrings("Usage: razerctl version\n", version_help.out.items[0].text);
}

test "root invocation is separate from child command lookup" {
    const no_args = args.Invocation{};
    const long_help = args.Invocation{ .command = "--help" };
    const short_help = args.Invocation{ .command = "-h" };
    const help_subcommand = args.Invocation{ .command = "help" };
    const get_subcommand = args.Invocation{ .command = "get" };

    try std.testing.expect(isRootInvocation(no_args));
    try std.testing.expect(isRootInvocation(long_help));
    try std.testing.expect(isRootInvocation(short_help));
    try std.testing.expect(!isRootInvocation(help_subcommand));
    try std.testing.expect(!isRootInvocation(get_subcommand));
}

fn isRootInvocation(inv: args.Invocation) bool {
    return inv.command.len == 0 or root.definition.option(inv.command) != null;
}

fn contains(items: []const []const u8, word: []const u8) bool {
    for (items) |item|
        if (args.is(item, word))
            return true;

    return false;
}

test "completion consumes command grammar and device-specific setting descriptors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root_candidates = try completionItems(a, &.{});

    try std.testing.expect(contains(root_candidates, "set"));
    try std.testing.expect(contains(root_candidates, "stream"));
    try std.testing.expect(!contains(root_candidates, modules.complete.entry.definition.name));
    const laptop = try completionItems(a, &.{ "set", "0x02b6" });

    try std.testing.expect(contains(laptop, "--save"));
    try std.testing.expect(contains(laptop, "--custom-cpu"));
    try std.testing.expect(!contains(laptop, "--fan-low"));
    const unknown = try completionItems(a, &.{ "set", "0xbeef" });

    try std.testing.expect(!contains(unknown, "--fan-low"));
    try std.testing.expect(!contains(unknown, "--custom-cpu"));
    const effect = try completionItems(a, &.{ "set", "0x02b6", "--effect" });

    try std.testing.expect(contains(effect, "static"));
    try std.testing.expect(!contains(effect, "--gamma"));
    const used = try completionItems(a, &.{ "get", "0x02b6", "--json", "--brightness" });

    try std.testing.expect(!contains(used, "--json"));
    try std.testing.expect(!contains(used, "--brightness"));
    try std.testing.expect(!contains(used, "--save"));
    const stream = try completionItems(a, &.{ "stream", "0x02b6" });

    try std.testing.expect(contains(stream, "--help"));
    try std.testing.expect(!contains(stream, "--brightness"));
}

fn completionItems(allocator: std.mem.Allocator, words: []const [:0]const u8) ![]const []const u8 {
    return (try modules.complete.complete(allocator, &definitions, words)).success;
}

fn imports(allocator: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var rest = source;
    const open = "@import(\"";

    while (std.mem.indexOf(u8, rest, open)) |i| {
        rest = rest[i + open.len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;

        try result.append(allocator, rest[0..end]);
        rest = rest[end..];
    }

    return result.items;
}

test "command modules import only shared modules, and shared modules import no commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const count = try checkImports(a, "src/commands");

    try std.testing.expectEqual(@typeInfo(@TypeOf(modules)).@"struct".field_names.len, count);
    _ = try checkImports(a, "src/interface");

    for ([_][]const u8{ "src", "src/device", "src/settings", "src/interface/ui" }) |shared|
        _ = try checkImports(a, shared);
}

/// Scans the directory so new files can't escape the boundary test.
fn checkImports(allocator: std.mem.Allocator, path: []const u8) !usize {
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    const command_module = args.is(path, "src/commands");
    var iterator = dir.iterate();
    var count: usize = 0;

    while (try iterator.next(io)) |file| {
        if (file.kind != .file or !std.mem.endsWith(u8, file.name, ".zig"))
            continue;

        if (args.is(path, "src") and (args.is(file.name, "main.zig") or args.is(file.name, "commands.zig")))
            continue;

        count += 1;
        const source = try dir.readFileAlloc(io, file.name, allocator, .limited(128 * 1024));

        for (try imports(allocator, source)) |target| {
            const allowed = if (command_module)
                args.is(target, "std") or args.is(target, "device") or args.is(target, "device_types") or
                    args.is(target, "settings") or args.is(target, "setting_types") or
                    args.is(target, "frame_session") or args.is(target, "polychromatic") or args.is(target, "chroma") or args.is(target, "keyboard_input") or args.is(target, "../playback/frame_output.zig") or args.is(target, "../playback/chroma_playback.zig") or
                    args.is(target, "transport") or args.is(target, "ui") or args.is(target, "probe_result") or
                    args.is(target, "../device/select.zig") or std.mem.startsWith(u8, target, "../interface/")
            else
                !std.mem.endsWith(u8, target, "commands.zig") and std.mem.indexOf(u8, target, "commands/") == null;

            if (!allowed) {
                std.debug.print("{s}/{s} imports {s}\n", .{ path, file.name, target });
                return error.ImportBoundaryViolation;
            }
        }
    }

    return count;
}

test {
    std.testing.refAllDecls(command);

    inline for (@typeInfo(@TypeOf(modules)).@"struct".field_names) |name|
        std.testing.refAllDecls(@field(modules, name));

    std.testing.refAllDecls(help);
    std.testing.refAllDecls(@import("device/select.zig"));
}
