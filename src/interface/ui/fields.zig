//! Setting fields, one value per setting, rendered as aligned text or JSON.

const std = @import("std");
const Writer = std.Io.Writer;
const Error = @import("result.zig").Error;
const Failure = @import("result.zig").Failure;
const Table = @import("table.zig").Table;

pub const Val = union(enum) {
    str: []const u8,
    num: u16,
    decimal: f64,
    flag: bool,
};

pub const Unit = enum {
    percent,
    rpm,
    celsius,
    hz,
    watts,
    watt_hours,

    /// Appended to the number in text.
    pub fn suffix(u: Unit) []const u8 {
        return switch (u) {
            .percent => "%",
            .rpm => " rpm",
            .celsius => " °C",
            .hz => " Hz",
            .watts => " W",
            .watt_hours => " Wh",
        };
    }

    /// Listed under `units` in JSON; ASCII, for scripts.
    pub fn symbol(u: Unit) []const u8 {
        return switch (u) {
            .percent => "%",
            .rpm => "rpm",
            .celsius => "C",
            .hz => "Hz",
            .watts => "W",
            .watt_hours => "Wh",
        };
    }
};

pub const Format = enum { text, json };

/// JSON keys replace label hyphens with underscores.
pub const Field = struct {
    label: []const u8,
    val: Val,
    /// Text only; include the leading spaces.
    note: []const u8 = "",
    unit: ?Unit = null,
    json_only: bool = false,
};

pub const Fields = struct {
    allocator: std.mem.Allocator,

    items: std.ArrayList(Field) = .empty,
    /// Distinguishes failed reads from an empty result.
    misses: usize = 0,
    diagnostics: std.ArrayList(Failure) = .empty,

    pub fn init(allocator: std.mem.Allocator) Fields {
        return .{ .allocator = allocator };
    }

    pub fn add(fields: *Fields, field: Field) !void {
        const allocator = fields.allocator;

        try fields.items.append(allocator, field);
    }

    pub fn miss(fields: *Fields) void {
        fields.misses += 1;
    }

    pub fn missWithCause(fields: *Fields, failure: Failure) !void {
        fields.miss();
        try fields.diagnostics.append(fields.allocator, failure);
    }

    pub fn slice(fields: *const Fields) []const Field {
        return fields.items.items;
    }

    pub fn len(fields: *const Fields) usize {
        return fields.items.items.len;
    }

    pub fn renderSelected(fields: *const Fields, w: *Writer, format: Format) Error!void {
        const allocator = fields.allocator;

        if (format == .text and fields.len() == 1) {
            try w.print("{s}\n", .{try bareText(allocator, fields.slice()[0])});
        } else {
            try fields.render(w, format);
        }
    }

    /// Text aligns labels and values; JSON adds a `units` object for fields with a unit.
    pub fn render(fields: *const Fields, w: *Writer, format: Format) Error!void {
        const allocator = fields.allocator;

        switch (format) {
            .text => {
                var t: Table = .init(allocator);

                for (fields.slice()) |f| {
                    if (!f.json_only)
                        try t.add(&.{ f.label, try valueText(allocator, f) });
                }

                try t.render(w, .{});
            },
            .json => {
                var s: std.json.Stringify = .{ .writer = w };

                try s.beginObject();

                for (fields.slice()) |f| {
                    try s.objectField(try jsonKey(allocator, f.label));

                    switch (f.val) {
                        inline else => |v| try s.write(v),
                    }
                }

                try s.objectField("units");
                try s.beginObject();

                for (fields.slice()) |f| {
                    if (f.unit) |u| {
                        try s.objectField(try jsonKey(allocator, f.label));
                        try s.write(u.symbol());
                    }
                }

                try s.endObject();

                try s.endObject();
                try w.writeByte('\n');
            },
        }
    }
};

fn jsonKey(allocator: std.mem.Allocator, label: []const u8) ![]const u8 {
    const key = try allocator.dupe(u8, label);

    std.mem.replaceScalar(u8, key, '-', '_');
    return key;
}

/// The value as text shows it, unit and note included.
pub fn valueText(allocator: std.mem.Allocator, field: Field) ![]const u8 {
    return switch (field.val) {
        .str => |s| try allocator.print("{s}{s}", .{ s, field.note }),
        .num => |v| try allocator.print("{d}{s}{s}", .{ v, if (field.unit) |u| u.suffix() else "", field.note }),
        .decimal => |v| try allocator.print("{d:.3}{s}{s}", .{ v, if (field.unit) |u| u.suffix() else "", field.note }),
        .flag => |v| try allocator.print("{s}{s}", .{ if (v) "on" else "off", field.note }),
    };
}

fn testFields(allocator: std.mem.Allocator) !Fields {
    var fields: Fields = .init(allocator);

    try fields.add(.{ .label = "mode", .val = .{ .str = "turbo \"x\"" } });
    try fields.add(.{ .label = "fan-speed", .val = .{ .num = 2200 }, .unit = .rpm });
    try fields.add(.{ .label = "hidden", .val = .{ .flag = true }, .json_only = true });
    try fields.add(.{ .label = "charge-limit", .val = .{ .num = 100 }, .unit = .percent, .note = " (no limit)" });
    return fields;
}

test "setting fields as text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fields = try testFields(allocator);
    var aw: Writer.Allocating = .init(allocator);

    try fields.render(&aw.writer, .text);
    try std.testing.expectEqualStrings(
        \\mode         turbo "x"
        \\fan-speed    2200 rpm
        \\charge-limit 100% (no limit)
        \\
    , aw.written());
}

test "setting fields as json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fields = try testFields(allocator);
    var aw: Writer.Allocating = .init(allocator);

    try fields.render(&aw.writer, .json);
    try std.testing.expectEqualStrings(
        \\{"mode":"turbo \"x\"","fan_speed":2200,"hidden":true,"charge_limit":100,"units":{"fan_speed":"rpm","charge_limit":"%"}}
        \\
    , aw.written());
}

/// Preserve unmapped wire values for diagnostics.
pub fn nameOr(allocator: std.mem.Allocator, found: ?[]const u8, wire: u8) ![]const u8 {
    return found orelse try allocator.print("unknown (0x{x:0>2})", .{wire});
}

/// The value alone, as a setter takes it.
pub fn bareText(allocator: std.mem.Allocator, field: Field) ![]const u8 {
    return switch (field.val) {
        .str => |s| s,
        .num => |v| try allocator.print("{d}", .{v}),
        .decimal => |v| try allocator.print("{d:.3}", .{v}),
        .flag => |v| if (v) "on" else "off",
    };
}

test "bare values drop unit and note" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fields = try testFields(allocator);
    const f = fields.slice();

    try std.testing.expectEqualStrings("2200", try bareText(allocator, f[1]));
    try std.testing.expectEqualStrings("on", try bareText(allocator, f[2]));
    try std.testing.expectEqualStrings("100", try bareText(allocator, f[3]));
}

test "battery decimals are numeric in JSON and carry units in text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fields: Fields = .init(allocator);

    try fields.add(.{ .label = "charge-rate", .val = .{ .decimal = -12.5 }, .unit = .watts });
    try fields.add(.{ .label = "battery-energy", .val = .{ .decimal = 45.125 }, .unit = .watt_hours });
    try fields.add(.{ .label = "battery-energy-full", .val = .{ .str = "unavailable" }, .unit = .watt_hours });
    try std.testing.expectEqualStrings("-12.500 W", try valueText(allocator, fields.slice()[0]));
    try std.testing.expectEqualStrings("-12.500", try bareText(allocator, fields.slice()[0]));
    try std.testing.expectEqualStrings("45.125 Wh", try valueText(allocator, fields.slice()[1]));
    var writer: Writer.Allocating = .init(allocator);

    try fields.render(&writer.writer, .json);
    const json = try std.json.parseFromSlice(std.json.Value, allocator, writer.written(), .{});

    try std.testing.expectEqual(@as(f64, -12.5), json.value.object.get("charge_rate").?.float);
    try std.testing.expectEqualStrings("W", json.value.object.get("units").?.object.get("charge_rate").?.string);
    try std.testing.expectEqualStrings("Wh", json.value.object.get("units").?.object.get("battery_energy").?.string);
    try std.testing.expectEqualStrings("unavailable", json.value.object.get("battery_energy_full").?.string);
}

test "selected reads use bare single values, labelled multiple values, and JSON objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fields: Fields = .init(allocator);

    try fields.add(.{ .label = "cpu-temp", .val = .{ .num = 48 }, .unit = .celsius });
    var bare: Writer.Allocating = .init(allocator);

    try fields.renderSelected(&bare.writer, .text);
    try std.testing.expectEqualStrings("48\n", bare.written());
    var json: Writer.Allocating = .init(allocator);

    try fields.renderSelected(&json.writer, .json);
    try std.testing.expectEqualStrings("{\"cpu_temp\":48,\"units\":{\"cpu_temp\":\"C\"}}\n", json.written());
    try fields.add(.{ .label = "gpu-temp", .val = .{ .flag = false }, .unit = .celsius });
    var text: Writer.Allocating = .init(allocator);

    try fields.renderSelected(&text.writer, .text);
    try std.testing.expectEqualStrings("cpu-temp 48 °C\ngpu-temp off\n", text.written());
}
