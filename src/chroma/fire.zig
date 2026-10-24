const std = @import("std");
const profile = @import("profile.zig");
const effects = @import("effects.zig");

const columns = 23;
const rows = 7;
const cells = rows * columns;
const anchors = 100;
const stride = 160 / 40 + 1;
const frame_count = anchors * stride;
const black: profile.TableColor = .{ .rgb = .{ 0, 0, 0 }, .transparency = 0 };

const attenuation = [rows][columns]u8{
    .{ 128, 128, 96, 128, 128, 96, 64, 32, 64, 96, 128, 128, 96, 128, 128, 128, 96, 64, 64, 96, 128, 128, 128 },
    .{ 128, 96, 64, 96, 96, 64, 32, 16, 32, 64, 96, 96, 64, 96, 128, 96, 64, 32, 32, 64, 96, 128, 128 },
    .{ 96, 64, 32, 64, 64, 32, 16, 8, 16, 32, 64, 64, 32, 64, 96, 64, 32, 16, 16, 32, 64, 96, 128 },
    .{ 64, 32, 16, 32, 32, 16, 8, 6, 8, 16, 32, 32, 16, 32, 64, 32, 16, 8, 8, 16, 32, 64, 96 },
    .{ 32, 16, 8, 16, 16, 8, 6, 4, 6, 8, 16, 16, 8, 16, 32, 16, 8, 6, 6, 8, 16, 32, 64 },
    .{ 16, 8, 6, 8, 8, 6, 4, 2, 4, 6, 8, 8, 6, 8, 16, 8, 6, 4, 4, 6, 8, 16, 32 },
    .{ 8, 6, 4, 6, 6, 4, 2, 2, 2, 4, 6, 6, 4, 6, 8, 6, 4, 2, 2, 4, 6, 8, 16 },
};

const coordinates = [rows][columns]u8{
    .{ 224, 224, 192, 224, 224, 192, 160, 128, 160, 192, 224, 224, 192, 224, 224, 224, 192, 160, 160, 192, 224, 224, 224 },
    .{ 224, 192, 160, 192, 192, 160, 128, 96, 128, 160, 192, 192, 160, 192, 224, 192, 160, 128, 128, 160, 192, 224, 224 },
    .{ 192, 160, 128, 160, 160, 128, 96, 64, 96, 128, 160, 160, 128, 160, 192, 160, 128, 96, 96, 128, 160, 192, 224 },
    .{ 160, 128, 96, 128, 128, 96, 64, 32, 64, 96, 128, 128, 96, 128, 160, 128, 96, 64, 64, 96, 128, 160, 192 },
    .{ 128, 96, 64, 96, 96, 64, 32, 16, 32, 64, 96, 96, 64, 96, 128, 96, 64, 32, 32, 64, 96, 128, 160 },
    .{ 96, 64, 32, 64, 64, 32, 16, 8, 16, 32, 64, 64, 32, 64, 96, 64, 32, 16, 16, 32, 64, 96, 128 },
    .{ 64, 32, 16, 32, 32, 16, 8, 8, 8, 16, 32, 32, 16, 32, 64, 32, 16, 8, 8, 16, 32, 64, 96 },
};

fn crtRand(state: *u32) u32 {
    state.* = state.* *% 214013 +% 2531011;
    return (state.* >> 16) & 0x7fff;
}

fn attenuate(value: u8, amount: u8) u8 {
    return value - @as(u8, @intCast(@as(u16, value) * amount / 255));
}

// The two-stop, five-sample specialization of effects.table. Repeated f32
// addition and the explicit last endpoint are observable after truncation.
fn temporal(first: u8, second: u8) [stride]u8 {
    var result: [stride]u8 = undefined;
    result[0] = first;
    result[stride - 1] = second;
    var value: f32 = @floatFromInt(first);
    const step = (@as(f32, @floatFromInt(second)) - value) / (stride - 1);
    for (result[1 .. stride - 1]) |*out| {
        value += step;
        out.* = @intFromFloat(value);
    }
    return result;
}

pub const Movie = struct {
    allocator: std.mem.Allocator,
    frames: []profile.TableColor,

    /// Seeds the RNG, not the fixed number of animation anchors.
    pub fn init(allocator: std.mem.Allocator, first: profile.Color, second: profile.Color, seed: u32) !Movie {
        const stops = [_]profile.Stop{
            .{ .position = 0, .color = first },
            .{ .position = 0.5, .color = second },
            .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 0 } } },
        };
        const palette = try effects.table(allocator, &stops, 256);
        defer allocator.free(palette);

        const frames = try allocator.alloc(profile.TableColor, frame_count * cells);
        @memset(frames, black);
        var state = seed;

        for (0..anchors) |t| {
            for (0..columns) |x| {
                const q: u8 = @intCast(crtRand(&state) % 192 + 32);
                const value = attenuate(q, attenuation[rows - 1][x]);
                frames[t * stride * cells + (rows - 1) * columns + x].rgb = @splat(value);
            }
        }

        var y: usize = rows - 1;
        while (y > 0) {
            y -= 1;
            for (0..anchors) |t| {
                for (0..columns) |x| {
                    const below = frames[t * stride * cells + (y + 1) * columns + x].rgb[0];
                    const value = @max(1, attenuate(below, attenuation[y][x]));
                    frames[((t + 1) % anchors) * stride * cells + y * columns + x].rgb = @splat(value);
                }
            }
        }

        for (0..anchors) |t| {
            for (0..cells) |cell| {
                const first_value = frames[t * stride * cells + cell].rgb[0];
                const next_value = frames[((t + 1) % anchors) * stride * cells + cell].rgb[0];
                const samples = temporal(first_value, next_value);
                for (samples[1..], 1..) |value, j|
                    frames[(t * stride + j) * cells + cell].rgb = @splat(value);
            }
        }

        for (frames, 0..) |*color, i| {
            const cell = i % cells;
            const tint = palette[coordinates[cell / columns][cell % columns]];
            for (&color.rgb, tint.rgb) |*channel, multiplier|
                channel.* = @intCast(@as(u16, channel.*) * multiplier / 255);
            color.transparency = tint.transparency;
        }

        return .{ .allocator = allocator, .frames = frames };
    }

    pub fn deinit(self: *Movie) void {
        self.allocator.free(self.frames);
        self.* = undefined;
    }

    pub fn sample(self: Movie, tick: u64, x: usize, y: usize, destination_rows: usize, destination_columns: usize) profile.TableColor {
        std.debug.assert(x < destination_columns and y < destination_rows);
        const source_y = if (destination_columns <= columns - 1 and destination_rows <= rows - 1)
            rows - destination_rows + y
        else blk: {
            const bottom_offset: f32 = @floatFromInt(destination_rows - 1 - y);
            const scale = @as(f32, rows) / @as(f32, @floatFromInt(destination_rows));
            break :blk rows - 1 - @as(usize, @intFromFloat(bottom_offset * scale));
        };
        const frame: usize = @intCast(tick % frame_count);
        return self.frames[frame * cells + source_y * columns + x % columns];
    }
};

test "CRT initial state and discrete temporal interpolation" {
    var state: u32 = 1;
    for ([_]u32{ 41, 18467, 6334, 26500, 19169, 15724 }) |expected|
        try std.testing.expectEqual(expected, crtRand(&state));

    for ([_][2]u8{ .{ 0, 255 }, .{ 255, 0 }, .{ 71, 180 }, .{ 1, 2 }, .{ 223, 32 } }) |pair| {
        const stops = [_]profile.Stop{
            .{ .position = 0, .color = .{ .rgb = @splat(@as(f64, @floatFromInt(pair[0]))) } },
            .{ .position = 1, .color = .{ .rgb = @splat(@as(f64, @floatFromInt(pair[1]))) } },
        };
        const reference = try effects.table(std.testing.allocator, &stops, stride);
        defer std.testing.allocator.free(reference);
        for (temporal(pair[0], pair[1]), reference) |actual, expected|
            try std.testing.expectEqual(expected.rgb[0], actual);
    }
}

test "canonical Fire samples pin CRT attenuation shifted anchors and temporal endpoints" {
    var movie = try Movie.init(std.testing.allocator, .{ .rgb = .{ 255, 0, 0 } }, .{ .rgb = .{ 255, 255, 0 } }, 1);
    defer movie.deinit();
    try std.testing.expectEqual(@as(usize, 500 * 7 * 23), movie.frames.len);

    // Independently calculated from CRT seed 1 and integer attenuation:
    // first q=73, bottom=73-floor(73*8/255)=71; next anchor=180.
    const Reference = struct { tick: u64, x: usize, y: usize, rgb: [3]u8 };
    const reference = [_]Reference{
        .{ .tick = 0, .x = 0, .y = 6, .rgb = .{ 71, 35, 0 } },
        .{ .tick = 1, .x = 0, .y = 6, .rgb = .{ 98, 49, 0 } },
        .{ .tick = 2, .x = 0, .y = 6, .rgb = .{ 125, 62, 0 } },
        .{ .tick = 3, .x = 0, .y = 6, .rgb = .{ 152, 76, 0 } },
        .{ .tick = 4, .x = 0, .y = 6, .rgb = .{ 180, 90, 0 } },
        .{ .tick = 5, .x = 0, .y = 6, .rgb = .{ 180, 90, 0 } },
        .{ .tick = 0, .x = 7, .y = 6, .rgb = .{ 205, 12, 0 } },
        .{ .tick = 0, .x = 7, .y = 0, .rgb = .{ 168, 168, 0 } },
        .{ .tick = 0, .x = 22, .y = 0, .rgb = .{ 1, 1, 0 } },
        .{ .tick = 127, .x = 16, .y = 3, .rgb = .{ 96, 72, 0 } },
        .{ .tick = 495, .x = 7, .y = 0, .rgb = .{ 126, 126, 0 } },
        .{ .tick = 499, .x = 7, .y = 0, .rgb = .{ 168, 168, 0 } },
    };
    for (reference) |expected| {
        const actual = movie.sample(expected.tick, expected.x, expected.y, rows, columns);
        try std.testing.expectEqual(expected.rgb, actual.rgb);
        try std.testing.expectEqual(@as(u8, 0), actual.transparency);
    }
    for (0..frame_count) |tick| {
        for (0..cells) |cell|
            try std.testing.expectEqual(
                movie.sample(tick, cell % columns, cell / columns, rows, columns),
                movie.sample(tick + 500, cell % columns, cell / columns, rows, columns),
            );
    }
}

test "Fire crops small rectangles and scales height and tiles width otherwise" {
    var movie = try Movie.init(std.testing.allocator, .{ .rgb = .{ 255, 0, 0 } }, .{ .rgb = .{ 255, 255, 0 } }, 1);
    defer movie.deinit();
    const Shape = struct { height: usize, width: usize, source_rows: []const usize };
    const shapes = [_]Shape{
        .{ .height = 1, .width = 1, .source_rows = &.{6} },
        .{ .height = 6, .width = 22, .source_rows = &.{ 1, 2, 3, 4, 5, 6 } },
        .{ .height = 7, .width = 23, .source_rows = &.{ 0, 1, 2, 3, 4, 5, 6 } },
        .{ .height = 6, .width = 24, .source_rows = &.{ 1, 2, 3, 4, 5, 6 } },
        .{ .height = 3, .width = 24, .source_rows = &.{ 2, 4, 6 } },
        .{ .height = 8, .width = 23, .source_rows = &.{ 0, 1, 2, 3, 4, 5, 6, 6 } },
        .{ .height = 7, .width = 50, .source_rows = &.{ 0, 1, 2, 3, 4, 5, 6 } },
    };
    for (shapes) |shape| {
        for (shape.source_rows, 0..) |source_y, y| {
            for (0..shape.width) |x|
                try std.testing.expectEqual(
                    movie.sample(127, x % columns, source_y, rows, columns),
                    movie.sample(127, x, y, shape.height, shape.width),
                );
        }
    }
}

test "Fire is deterministic but respects CRT initial state" {
    const first: profile.Color = .{ .rgb = .{ 255, 0, 0 } };
    const second: profile.Color = .{ .rgb = .{ 255, 255, 0 } };
    var a = try Movie.init(std.testing.allocator, first, second, 1);
    defer a.deinit();
    var b = try Movie.init(std.testing.allocator, first, second, 1);
    defer b.deinit();
    var c = try Movie.init(std.testing.allocator, first, second, 2);
    defer c.deinit();
    try std.testing.expectEqualSlices(profile.TableColor, a.frames, b.frames);
    try std.testing.expect(!std.mem.eql(u8, &a.sample(0, 0, 6, rows, columns).rgb, &c.sample(0, 0, 6, rows, columns).rgb));
}

test "Fire colors come from caller stops without implicit defaults" {
    var dark = try Movie.init(std.testing.allocator, .{ .rgb = .{ 0, 0, 0 } }, .{ .rgb = .{ 0, 0, 0 } }, 1);
    defer dark.deinit();
    for (dark.frames) |color|
        try std.testing.expectEqual(black, color);

    var movie = try Movie.init(std.testing.allocator, .{ .rgb = .{ 255, 0, 0 }, .alpha = 0 }, .{ .rgb = .{ 0, 255, 0 }, .alpha = 0.5 }, 1);
    defer movie.deinit();
    // B[0][7]=128 is the exact second stop: its alpha is not heat-scaled.
    try std.testing.expectEqual(profile.TableColor{ .rgb = .{ 0, 168, 0 }, .transparency = 50 }, movie.sample(0, 7, 0, rows, columns));
}

fn allocationCheck(allocator: std.mem.Allocator) !void {
    var movie = try Movie.init(allocator, .{ .rgb = .{ 255, 0, 0 } }, .{ .rgb = .{ 255, 255, 0 } }, 0);
    defer movie.deinit();
    _ = movie.sample(0, 0, 0, rows, columns);
}

test "Fire initialization releases allocations on success and failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCheck, .{});
}
