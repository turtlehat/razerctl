//! Builds device-aware command help from definitions and settings.

const std = @import("std");
const settings = @import("settings");
const devices = @import("../device/select.zig");
const ui = @import("ui");
const command = @import("command.zig");

pub fn render(allocator: std.mem.Allocator, def: command.Definition, spec: ?[]const u8, output: *ui.Output) !void {
    const cmd = def.name;

    if (!def.takesDevice()) {
        try output.writeText(try allocator.print("Usage: razerctl {s}\n", .{cmd}));
        try description(output, def);

        var options: ui.Help = .init(allocator);

        for (def.options) |flag|
            try options.option(flag);

        try section(output, "Options", options.table, 6);

        return;
    }

    const desc = switch (try devices.one(allocator, spec)) {
        .success => |value| value,
        .failure => |failure| return output.writeError(failure.message, failure.err),
    };

    try output.writeText(try allocator.print("{s} (0x{x:0>4}):\nUsage: razerctl {s} [id]{s} [options]\n", .{
        desc.name, desc.pid, cmd, if (def.grammar == .device_file) " <file>" else "",
    }));

    if (desc.provenance == .transcribed)
        try output.writeText(try allocator.print("\nThis device is UNVERIFIED -- try `razerctl probe 0x{x:0>4}` and report what works.\n", .{desc.pid}));

    try description(output, def);

    var options: ui.Help = .init(allocator);

    for (def.options) |flag|
        try options.option(flag);

    try section(output, "Options", options.table, 6);

    if (def.action()) |action| {
        inline for (settings.names) |name| {
            var fields: ui.Help = .init(allocator);

            for (try settings.settings(allocator, &desc, name)) |setting| {
                if (!settings.selectable(setting, action))
                    continue;

                if (def.help.settings == .selectors) {
                    try fields.option(.{ .name = setting.usage.name, .note = setting.usage.note });
                } else {
                    var usage = setting.usage;

                    usage.name = try allocator.print("--{s}", .{usage.name});
                    try fields.command(usage);
                }
            }
            try section(output, settings.module(name).title, fields.table, 6);
        }
    }

    if (def.help.feature_references) {
        inline for (settings.names) |name| {
            const feature = settings.module(name);

            if (@hasDecl(feature, "reference")) {
                if (try feature.reference(allocator, &.{desc})) |reference|
                    try output.writeText(reference);
            }
        }
    }
}

fn description(output: *ui.Output, def: command.Definition) !void {
    if (def.help.description.len > 0)
        try output.writeText(try output.allocator.print("\n{s}\n", .{def.help.description}));
}

fn section(output: *ui.Output, title: []const u8, table: ui.Table, gap: usize) !void {
    if (table.len() == 0)
        return;

    try output.writeTableData(title, table, .{ .indent = 2, .gap = gap }, 0);
}

test "command descriptions come from definitions even without settings grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const def: command.Definition = .{
        .name = "example",
        .note = "",
        .help = .{ .description = "Command-owned explanation." },
    };
    var output: ui.Output = .init(allocator);

    try render(allocator, def, null, &output);

    try std.testing.expectEqualStrings("\nCommand-owned explanation.\n", output.out.items[1].text);
}

test "setting help presentation and references do not depend on action" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var def: command.Definition = .{
        .name = "example",
        .note = "",
        .grammar = .{ .settings = .get },
    };
    var selectors: ui.Output = .init(allocator);

    try render(allocator, def, "0x02b6", &selectors);
    def.help.settings = .values;
    var values: ui.Output = .init(allocator);

    try render(allocator, def, "0x02b6", &values);

    var found_selector = false;

    for (selectors.out.items) |block| {
        if (block != .table)
            continue;

        for (block.table.table.rows.items) |row| {
            if (std.mem.eql(u8, row.cells[0], "--brightness"))
                found_selector = true;
        }
    }

    var found_value = false;

    for (values.out.items) |block| {
        if (block != .table)
            continue;

        for (block.table.table.rows.items) |row| {
            if (std.mem.startsWith(u8, row.cells[0], "--brightness ") and std.mem.indexOfScalar(u8, row.cells[0], '<') != null)
                found_value = true;
        }
    }

    try std.testing.expect(found_selector);
    try std.testing.expect(found_value);

    def.help.feature_references = true;
    var references: ui.Output = .init(allocator);

    try render(allocator, def, "0x02b6", &references);
    try std.testing.expect(references.out.items.len > values.out.items.len);
}
