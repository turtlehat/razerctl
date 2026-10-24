//! Raw RGB frame input; producers own rendering and timing.
const std = @import("std");
const command = @import("../interface/command.zig");
const frames = @import("frame_session");
const frame_output = @import("../playback/frame_output.zig");
const ui = @import("ui");

pub const entry: command.Entry = .{
    .definition = .{
        .name = "stream",
        .note = "Stream raw RGB frames from stdin",
        .grammar = .device,
        .options = &.{
            command.help_option,
            .{ .name = "info", .note = "Show layout and frame size without streaming." },
        },
        .help = .{ .description =
        \\Read RGB8 frames in hardware row/column order. Restores the original effect on exit.
        },
    },
    .execute = execute,
};

pub fn execute(context: command.Context, invocation: command.args.Invocation, output: *ui.Output) !void {
    const allocator = context.allocator;
    var selected = (try frame_output.open(context, if (invocation.arguments.len > 0) invocation.arguments[0] else null, output)) orelse return;
    defer selected.close();
    const config = selected.desc.features.lighting;
    const shape = selected.session.shape;
    var input = frames.Input.init() catch |err|
        return output.writeError("stream: cannot initialize interruptible stdin", err);
    defer input.deinit();
    if (invocation.hasOption("--info")) {
        try output.writeText(try allocator.print("protocol {s}\nrows {d}\ncolumns {d}\nframe-bytes {d}\n", .{
            @tagName(config.protocol.?), shape.rows, shape.columns, shape.frameSize(),
        }));
        for (config.zones) |zone| {
            const mapping = zone.frame orelse continue;
            try output.writeText(try allocator.print("zone {s} id {d}", .{ zone.name, zone.id }));
            if (mapping.length) |length|
                try output.writeText(try allocator.print(" pixels {d}..{d}", .{
                    mapping.start, @as(u32, mapping.start) + length - 1,
                }));
            try output.writeText("\n");
        }
        return;
    }
    try selected.run(context, &input, output);
}

test "unsupported devices fail before opening hardware" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output: ui.Output = .init(allocator);
    const context: command.Context = .{
        .allocator = allocator,
        .io = undefined,
        .environ = undefined,
        .root = entry.definition,
        .definitions = &.{},
    };

    try execute(context, try command.args.group(allocator, &.{ "stream", "0x0e05" }), &output);
    try std.testing.expectEqual(@as(u8, 1), output.exit_code);
    try std.testing.expectEqualStrings("stream is not supported on Unrecognised", output.err.items[0].message);
}
