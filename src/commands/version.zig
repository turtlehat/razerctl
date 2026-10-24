const ui = @import("ui");
const command = @import("../interface/command.zig");

pub const entry: command.Entry = .{
    .definition = .{ .name = "version", .note = "Show razerctl version" },
    .execute = execute,
};

pub const value = "0.1.0";

pub fn execute(_: command.Context, _: command.args.Invocation, output: *ui.Output) !void {
    try output.writeLine("razerctl " ++ value);
}
