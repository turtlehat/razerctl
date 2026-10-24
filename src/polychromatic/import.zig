//! Polychromatic sequence file decoding and validation.
const std = @import("std");

const Document = struct {
    type: u32,
    save_format: u32,
    map_cols: u16,
    map_rows: u16,
    fps: u32,
    loop: bool,
    frames: []const std.json.Value,
};

pub fn parse(comptime Sequence: type, allocator: std.mem.Allocator, text: []const u8) !Sequence {
    const parsed = try std.json.parseFromSlice(Document, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const doc = parsed.value;
    if (doc.save_format != 8)
        return error.UnsupportedAnimationVersion;
    if (doc.type != 3)
        return error.UnsupportedAnimationType;
    if (doc.map_rows == 0 or doc.map_rows > 255 or doc.map_cols == 0 or doc.map_cols > 255)
        return error.InvalidAnimationDimensions;
    if (doc.fps == 0 or doc.fps > std.time.ns_per_s)
        return error.InvalidAnimationFps;
    if (doc.frames.len == 0)
        return error.EmptyAnimation;
    for (doc.frames) |frame|
        try pixels(doc, frame, null);
    const frame_size = @as(usize, doc.map_rows) * doc.map_cols * 3;
    const frames = try allocator.alloc(u8, try std.math.mul(usize, frame_size, doc.frames.len));
    errdefer allocator.free(frames);
    @memset(frames, 0);
    for (doc.frames, 0..) |frame, i|
        try pixels(doc, frame, frames[i * frame_size ..][0..frame_size]);
    return .{
        .allocator = allocator,
        .rows = @intCast(doc.map_rows),
        .columns = @intCast(doc.map_cols),
        .fps = doc.fps,
        .loop = doc.loop,
        .frames = frames,
    };
}

fn coordinate(key: []const u8, bound: u16) !usize {
    if (key.len == 0 or (key.len > 1 and key[0] == '0'))
        return error.InvalidAnimationCoordinate;
    for (key) |c|
        if (!std.ascii.isDigit(c))
            return error.InvalidAnimationCoordinate;
    const value = std.fmt.parseInt(usize, key, 10) catch return error.InvalidAnimationCoordinate;
    if (value >= bound)
        return error.InvalidAnimationCoordinate;
    return value;
}

fn colour(value: std.json.Value) ![3]u8 {
    if (value != .string)
        return error.InvalidAnimationColour;
    const hex = value.string;
    if (hex.len != 7 or hex[0] != '#')
        return error.InvalidAnimationColour;
    for (hex[1..]) |c|
        if (!std.ascii.isHex(c))
            return error.InvalidAnimationColour;
    var rgb: [3]u8 = undefined;
    for (&rgb, 0..) |*channel, i|
        channel.* = std.fmt.parseInt(u8, hex[1 + i * 2 ..][0..2], 16) catch
            return error.InvalidAnimationColour;
    return rgb;
}

fn pixels(doc: Document, frame: std.json.Value, rgb: ?[]u8) !void {
    if (frame != .object)
        return error.InvalidAnimationFrame;
    var columns = frame.object.iterator();
    while (columns.next()) |column| {
        const x = try coordinate(column.key_ptr.*, doc.map_cols);
        if (column.value_ptr.* != .object)
            return error.InvalidAnimationFrame;
        var rows = column.value_ptr.object.iterator();
        while (rows.next()) |row| {
            const y = try coordinate(row.key_ptr.*, doc.map_rows);
            const value = try colour(row.value_ptr.*);
            if (rgb) |buffer| {
                const offset = (y * doc.map_cols + x) * 3;
                @memcpy(buffer[offset..][0..3], &value);
            }
        }
    }
}
