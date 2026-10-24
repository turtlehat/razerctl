const std = @import("std");
const Writer = std.Io.Writer;
const Error = @import("result.zig").Error;

/// Rows of cells, aligned per table. A `sub` row is an indented continuation
/// of the row above, one cell, and never sets a column width.
pub const Table = struct {
    allocator: std.mem.Allocator,

    rows: std.ArrayList(Row) = .empty,

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{ .allocator = allocator };
    }

    pub const Row = struct { cells: []const []const u8, sub: bool = false };

    pub const Layout = struct {
        indent: usize = 0,
        sub_indent: usize = 2,
        gap: usize = 1,
    };

    /// Everything is copied, so callers can pass stack buffers.
    pub fn add(t: *Table, cells: []const []const u8) !void {
        const allocator = t.allocator;
        const copy = try allocator.alloc([]const u8, cells.len);

        for (cells, copy) |c, *d|
            d.* = try allocator.dupe(u8, c);

        try t.rows.append(allocator, .{ .cells = copy });
    }

    pub fn addSub(t: *Table, text: []const u8) !void {
        try t.add(&.{text});
        t.rows.items[t.rows.items.len - 1].sub = true;
    }

    pub fn len(t: *const Table) usize {
        return t.rows.items.len;
    }

    /// Ignore trailing empty cells so unnoted usage rows are not padded.
    fn used(cells: []const []const u8) usize {
        var n = cells.len;

        while (n > 0 and cells[n - 1].len == 0)
            n -= 1;

        return n;
    }

    /// A cell counts toward its column's width only when something follows it
    /// on the row, so one long unnoted usage does not push every note right.
    pub fn render(t: *const Table, w: *Writer, layout: Layout) Error!void {
        const allocator = t.allocator;
        var widths: std.ArrayList(usize) = .empty;

        for (t.rows.items) |r| {
            if (r.sub)
                continue;

            const n = used(r.cells);

            if (n == 0)
                continue;

            for (r.cells[0 .. n - 1], 0..) |c, i| {
                while (widths.items.len <= i)
                    try widths.append(allocator, 0);

                widths.items[i] = @max(widths.items[i], c.len);
            }
        }

        for (t.rows.items) |r| {
            if (r.sub) {
                try w.splatByteAll(' ', layout.indent + layout.sub_indent);
                try w.writeAll(r.cells[0]);
                try w.writeAll("\n");
                continue;
            }

            try w.splatByteAll(' ', layout.indent);
            const n = used(r.cells);

            for (r.cells[0..n], 0..) |c, i| {
                try w.writeAll(c);

                if (i + 1 < n)
                    try w.splatByteAll(' ', widths.items[i] - c.len + layout.gap);
            }

            try w.writeAll("\n");
        }
    }
};

pub const TableBuilder = struct {
    allocator: std.mem.Allocator,
    layout: Table.Layout,
    gap: usize,
    table: Table,
    row: RowBuilder = undefined,
    has_row: bool = false,

    pub fn createRow(builder: *TableBuilder) *RowBuilder {
        std.debug.assert(!builder.has_row);
        builder.row = .{ .allocator = builder.allocator, .table = builder };
        builder.has_row = true;
        return &builder.row;
    }

    fn addRow(builder: *TableBuilder, row: *RowBuilder) !void {
        std.debug.assert(builder.has_row and row == &builder.row);
        try builder.table.add(builder.row.cells.items);
        builder.has_row = false;
    }
};

pub const RowBuilder = struct {
    allocator: std.mem.Allocator,
    table: *TableBuilder,
    cells: std.ArrayList([]const u8) = .empty,

    pub fn writeCol(row: *RowBuilder, value: []const u8) !void {
        try row.cells.append(row.allocator, value);
    }

    pub fn writeFmtCol(row: *RowBuilder, comptime fmt: []const u8, args: anytype) !void {
        try row.writeCol(try row.allocator.print(fmt, args));
    }

    pub fn close(row: *RowBuilder) !void {
        try row.table.addRow(row);
    }
};
