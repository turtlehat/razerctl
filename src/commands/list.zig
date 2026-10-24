const ui = @import("ui");
const devices = @import("../device/select.zig");
const command = @import("../interface/command.zig");

pub const entry: command.Entry = .{
    .definition = .{ .name = "list", .note = "Show devices and their ids" },
    .execute = execute,
};

pub fn execute(context: command.Context, _: command.args.Invocation, output: *ui.Output) !void {
    const allocator = context.allocator;
    const attached_devices = devices.attached(allocator) catch |err|
        return try output.writeError("cannot enumerate Razer devices", err);

    if (attached_devices.len == 0) {
        try output.writeLine("no Razer devices found");
        return;
    }

    var table = output.createTable(.{ .gap = 2 }, 0);

    for (attached_devices) |device| {
        var row = table.createRow();

        try row.writeFmtCol("0x{x:0>4}", .{device.pid});

        if (device.provenance == .unrecognised) {
            try row.writeCol("unknown");
            try row.writeCol("unrecognised");
            try row.close();
            continue;
        }

        try row.writeCol(@tagName(device.category));

        if (device.provenance == .transcribed) {
            try row.writeFmtCol("{s} (unverified)", .{device.name});
        } else {
            try row.writeFmtCol("{s}", .{device.name});
        }

        try row.close();
    }

    try output.writeTable(table);
}
