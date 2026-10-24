//! Content produced by commands, and its rendering to stdout and stderr.

const std = @import("std");
const Writer = std.Io.Writer;
const Error = @import("result.zig").Error;
const Failure = @import("result.zig").Failure;
const Result = @import("result.zig").Result;
const Table = @import("table.zig").Table;
const TableBuilder = @import("table.zig").TableBuilder;
const Fields = @import("fields.zig").Fields;
const Format = @import("fields.zig").Format;

pub const Output = struct {
    allocator: std.mem.Allocator,

    out: std.ArrayList(Block) = .empty,
    err: std.ArrayList(Failure) = .empty,
    exit_code: u8 = 0,

    pub fn init(allocator: std.mem.Allocator) Output {
        return .{ .allocator = allocator };
    }

    pub const Block = union(enum) {
        text: []const u8,
        candidates: []const []const u8,
        table: struct {
            title: ?[]const u8 = null,
            table: Table,
            layout: Table.Layout = .{},
            gap: usize = 0,
        },
        fields: struct { fields: Fields, format: Format, selected: bool = false },
    };

    pub fn writeText(output: *Output, text: []const u8) !void {
        try output.out.append(output.allocator, .{ .text = text });
    }

    pub fn writeLine(output: *Output, text: []const u8) !void {
        try output.writeText(text);
        try output.writeText("\n");
    }

    pub fn writeError(output: *Output, message: []const u8, cause: ?anyerror) !void {
        try output.writeDiagnostic(.{ .message = message, .err = cause });
        output.exit_code = 1;
    }

    /// A message on stderr that does not fail the command.
    pub fn writeDiagnostic(output: *Output, failure: Failure) !void {
        try output.err.append(output.allocator, failure);
    }

    pub fn writeCandidates(output: *Output, items: []const []const u8) !void {
        try output.out.append(output.allocator, .{ .candidates = try output.allocator.dupe([]const u8, items) });
    }

    pub fn createTable(output: *Output, layout: Table.Layout, gap: usize) TableBuilder {
        return .{ .allocator = output.allocator, .layout = layout, .gap = gap, .table = .init(output.allocator) };
    }

    pub fn writeTable(output: *Output, builder: TableBuilder) !void {
        std.debug.assert(!builder.has_row);
        try output.writeTableData(null, builder.table, builder.layout, builder.gap);
    }

    pub fn writeTableData(output: *Output, title: ?[]const u8, table: Table, layout: Table.Layout, gap: usize) !void {
        try output.out.append(output.allocator, .{ .table = .{ .title = title, .table = table, .layout = layout, .gap = gap } });
    }

    pub fn writeFields(output: *Output, fields: Fields, format: Format, selected: bool) !void {
        try output.out.append(output.allocator, .{ .fields = .{ .fields = fields, .format = format, .selected = selected } });
    }
};

pub fn render(out_writer: *Writer, err_writer: *Writer, output: Output) Error!void {
    try renderOut(out_writer, output.out.items);
    try renderErr(err_writer, output.err.items);
}

pub fn renderOut(w: *Writer, content: []const Output.Block) Error!void {
    for (content) |block| {
        switch (block) {
            .text => |text| try w.writeAll(text),
            .candidates => |items| for (items) |item| {
                try w.writeAll(item);
                try w.writeByte('\n');
            },
            .table => |item| {
                if (item.title) |title| {
                    try w.writeByte('\n');
                    try w.splatByteAll(' ', item.layout.indent -| 2);
                    try w.print("{s}:\n", .{title});
                }

                try item.table.render(w, item.layout);

                if (item.gap > 0)
                    try w.splatByteAll('\n', item.gap);
            },
            .fields => |item| if (item.selected)
                try item.fields.renderSelected(w, item.format)
            else
                try item.fields.render(w, item.format),
        }
    }
}

pub fn renderErr(w: *Writer, messages: []const Failure) Writer.Error!void {
    for (messages) |failure|
        try renderFailure(w, failure);
}

pub fn renderFailure(w: *Writer, failure: Failure) Writer.Error!void {
    if (failure.message.len == 0) {
        if (failure.err) |cause| {
            try w.print("razerctl: '{s}'\n", .{@errorName(cause)});
            return;
        }

        try w.writeAll("razerctl:\n");
        return;
    }

    try w.print("razerctl: {s}", .{failure.message});

    if (failure.err) |cause|
        try w.print(" - '{s}'", .{@errorName(cause)});

    try w.writeByte('\n');
}

test "diagnostics render error names without allocating" {
    var buffer: [128]u8 = undefined;
    var writer: Writer = .fixed(&buffer);

    try renderFailure(&writer, .{ .message = "cannot read arguments", .err = error.OutOfMemory });
    try std.testing.expectEqualStrings("razerctl: cannot read arguments - 'OutOfMemory'\n", writer.buffered());
    writer = .fixed(&buffer);
    try renderFailure(&writer, .{ .message = "invalid device id" });
    try std.testing.expectEqualStrings("razerctl: invalid device id\n", writer.buffered());
    writer = .fixed(&buffer);
    try renderFailure(&writer, .{ .message = "", .err = error.ReadFailed });
    try std.testing.expectEqualStrings("razerctl: 'ReadFailed'\n", writer.buffered());
}

test "output writer appends lines, completed tables, and errors with failure status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output: Output = .init(allocator);

    try output.writeLine("Devices");

    var table = output.createTable(.{ .gap = 2 }, 0);
    var header = table.createRow();

    try header.writeCol("id");
    try header.writeCol("name");
    try header.close();
    var device = table.createRow();

    try device.writeFmtCol("0x{x:0>2}", .{1});
    try device.writeCol("mouse");
    try device.close();
    try output.writeTable(table);

    try output.writeError("cannot enumerate devices", error.TestDeviceError);
    try std.testing.expectEqual(@as(u8, 1), output.exit_code);

    var out_buffer: [128]u8 = undefined;
    var err_buffer: [128]u8 = undefined;
    var stdout: Writer = .fixed(&out_buffer);
    var stderr: Writer = .fixed(&err_buffer);

    try render(&stdout, &stderr, output);
    try std.testing.expectEqualStrings("Devices\nid    name\n0x01  mouse\n", stdout.buffered());
    try std.testing.expectEqualStrings("razerctl: cannot enumerate devices - 'TestDeviceError'\n", stderr.buffered());
}

test "result failures and diagnostic output preserve the named cause until rendering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result: Result(void) = .{ .failure = .{
        .message = "cannot read test setting",
        .err = error.NamedReadFailure,
    } };

    try std.testing.expectEqual(error.NamedReadFailure, result.failure.err.?);
    var output: Output = .init(allocator);

    try output.writeDiagnostic(result.failure);
    try output.writeDiagnostic(.{ .message = "output is incomplete" });
    var out_buffer: [1]u8 = undefined;
    var err_buffer: [256]u8 = undefined;
    var stdout: Writer = .fixed(&out_buffer);
    var stderr: Writer = .fixed(&err_buffer);

    try render(&stdout, &stderr, output);
    try std.testing.expectEqualStrings("", stdout.buffered());
    try std.testing.expectEqualStrings("razerctl: cannot read test setting - 'NamedReadFailure'\nrazerctl: output is incomplete\n", stderr.buffered());
}

test "output renders mixed text and tables, and diagnostics separately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var output: Output = .init(allocator);

    try output.writeText("Findings:\n");
    var table: Table = .init(allocator);

    try table.add(&.{ "0x0001", "effect", "supported" });
    try output.writeTableData(null, table, .{}, 1);
    var fields: Fields = .init(allocator);

    try fields.add(.{ .label = "mode", .val = .{ .str = "balanced" } });
    try output.writeFields(fields, .text, false);
    try output.writeDiagnostic(.{ .message = "1 setting read failed" });

    var stdout: Writer.Allocating = .init(allocator);
    var stderr: Writer.Allocating = .init(allocator);

    try render(&stdout.writer, &stderr.writer, output);
    try std.testing.expectEqualStrings("Findings:\n0x0001 effect supported\n\nmode balanced\n", stdout.written());

    try std.testing.expectEqualStrings("razerctl: 1 setting read failed\n", stderr.written());
}

test "builders keep caller-owned lifetimes independent and copy table cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output: Output = .init(allocator);
    var table: Table = .init(allocator);
    var cell = "original".*;

    try table.add(&.{&cell});
    @memset(&cell, 'x');
    try output.writeTableData(null, table, .{}, 0);
    var fields: Fields = .init(allocator);

    try fields.add(.{ .label = "brightness", .val = .{ .num = 30 }, .unit = .percent });
    try output.writeFields(fields, .text, true);

    {
        var other_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer other_arena.deinit();
        const other_allocator = other_arena.allocator();
        var other: Output = .init(other_allocator);

        try other.writeText("independent\n");
        var writer: Writer.Allocating = .init(other_allocator);

        try renderOut(&writer.writer, other.out.items);
        try std.testing.expectEqualStrings("independent\n", writer.written());
    }

    var writer: Writer.Allocating = .init(allocator);

    try renderOut(&writer.writer, output.out.items);
    try std.testing.expectEqualStrings("original\n30\n", writer.written());
}

test "empty output streams need no optional state and diagnostics do not imply failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output: Output = .init(arena.allocator());

    try std.testing.expectEqual(@as(usize, 0), output.out.items.len);
    try std.testing.expectEqual(@as(usize, 0), output.err.items.len);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    try output.writeDiagnostic(.{ .message = "a warning" });
    try std.testing.expectEqual(@as(usize, 0), output.out.items.len);
    try std.testing.expectEqual(@as(usize, 1), output.err.items.len);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    try output.writeText("partial result\n");
    output.exit_code = 1;
    try std.testing.expectEqual(@as(usize, 1), output.out.items.len);
    try std.testing.expectEqual(@as(u8, 1), output.exit_code);
}
