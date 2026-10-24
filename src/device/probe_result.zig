//! Probe-specific rows collected from device feature checks.

const std = @import("std");
const ui = @import("ui");
const transport = @import("transport");
const Writer = std.Io.Writer;

pub const ProbeResult = struct {
    table: *ui.TableBuilder,

    pub fn init(table: *ui.TableBuilder) ProbeResult {
        return .{ .table = table };
    }

    pub fn add(result: *ProbeResult, command: transport.Command, name: []const u8, value: []const u8) !void {
        var row = result.table.createRow();

        try row.writeFmtCol("0x{x:0>4}", .{command.id});
        try row.writeCol(name);
        try row.writeCol(value);
        try row.close();
    }

    /// The first `n` response bytes, or why the command is unavailable.
    pub fn reply(result: *ProbeResult, command: transport.Command, name: []const u8, response: anytype, n: usize) !void {
        if (response) |packet| {
            const bytes = packet.argSlice();

            try result.add(command, name, try hex(result.table.allocator, bytes[0..@min(bytes.len, n)]));
        } else |err| {
            try result.failure(command, name, err);
        }
    }

    pub fn failure(result: *ProbeResult, command: transport.Command, name: []const u8, err: anyerror) !void {
        try result.add(command, name, if (err == error.NotSupported) "NotSupported" else try result.table.allocator.print("error ({s})", .{@errorName(err)}));
    }
};

pub fn hex(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(allocator);

    for (bytes, 0..) |byte, i|
        try aw.writer.print("{s}{x:0>2}", .{ if (i == 0) "" else " ", byte });

    return aw.written();
}

test "probe byte formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("01 0a ff", try hex(allocator, &.{ 1, 10, 255 }));
    try std.testing.expectEqualStrings("", try hex(allocator, &.{}));
}

test "probe results add formatted registers and reply bytes" {
    const Packet = struct {
        bytes: []const u8,

        fn argSlice(packet: *const @This()) []const u8 {
            return packet.bytes;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output: ui.Output = .init(arena.allocator());
    var table = output.createTable(.{}, 0);
    var result: ProbeResult = .init(&table);

    try result.reply(.{ .id = 0x0081 }, "firmware", @as(error{NotSupported}!Packet, .{ .bytes = &.{ 1, 10 } }), 1);
    try result.reply(.{ .id = 0x0082 }, "serial", @as(error{NotSupported}!Packet, error.NotSupported), 2);
    try result.reply(.{ .id = 0x0084 }, "device mode", @as(error{ReadFailed}!Packet, error.ReadFailed), 2);

    try std.testing.expectEqual(@as(usize, 3), table.table.len());
    try std.testing.expectEqualStrings("0x0081", table.table.rows.items[0].cells[0]);
    try std.testing.expectEqualStrings("01", table.table.rows.items[0].cells[2]);
    try std.testing.expectEqualStrings("NotSupported", table.table.rows.items[1].cells[2]);
    try std.testing.expectEqualStrings("error (ReadFailed)", table.table.rows.items[2].cells[2]);
}
