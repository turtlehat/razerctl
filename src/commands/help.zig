const std = @import("std");
const ui = @import("ui");
const device = @import("device_types");
const devices = @import("../device/select.zig");
const command = @import("../interface/command.zig");

pub const entry: command.Entry = .{
    .definition = .{
        .name = "help",
        .note = "Show this help",
        .handles_help = true,
    },
    .execute = execute,
};

pub fn execute(context: command.Context, _: command.args.Invocation, output: *ui.Output) !void {
    const allocator = context.allocator;
    const attached = devices.attached(allocator) catch |err|
        return output.writeError("cannot enumerate Razer devices", err);

    try output.writeText("Usage:\n  razerctl <command>\n");

    var options: ui.Help = .init(allocator);

    for (context.root.options) |flag|
        try options.option(flag);

    if (options.table.len() > 0)
        try output.writeTableData("Options", options.table, .{ .indent = 2, .gap = 3 }, 0);

    var commands: ui.Help = .init(allocator);

    for (context.definitions) |def| {
        if (def.hidden)
            continue;

        try commands.command(.{
            .name = if (def.takesDevice()) try allocator.print("{s} <id>{s}", .{
                def.name, if (def.grammar == .device_file) " <file>" else "",
            }) else def.name,
            .note = def.note,
        });
    }

    if (commands.table.len() > 0)
        try output.writeTableData("Commands", commands.table, .{ .indent = 2, .gap = 3 }, 0);

    try output.writeText(try allocator.print("\n{s}Use 'razerctl <command> --help' for more information on a command.\n", .{try deviceHint(allocator, devices.automatic(attached))}));
}

fn deviceHint(allocator: std.mem.Allocator, host: ?device.Descriptor) ![]const u8 {
    if (host) |desc|
        return try allocator.print("Omit <id> to use your {s}.\n", .{desc.name});

    return "Use an id from 'razerctl list' to select a device.\n";
}

test "root device hint names the automatically selected laptop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("Omit <id> to use your Razer Blade 14 (2025).\n", try deviceHint(allocator, .{ .pid = 0, .name = "Razer Blade 14 (2025)", .category = .system }));
    try std.testing.expectEqualStrings("Use an id from 'razerctl list' to select a device.\n", try deviceHint(allocator, null));
}
