const std = @import("std");
const profile = @import("profile.zig");
const Color = profile.Color;
const Parameters = profile.Parameters;

pub const random_breathing_stops = [_]profile.Stop{
    .{ .position = 0, .color = .{ .rgb = .{ 0, 0, 0 } } },
    .{ .position = 0.25, .color = .{ .rgb = .{ 0, 0, 0 } } },
    .{ .position = 0.50, .color = .{ .rgb = .{ 255, 255, 255 } } },
    .{ .position = 0.75, .color = .{ .rgb = .{ 255, 255, 255 } } },
    .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 0 } } },
};

fn mix(a: Color, b: Color, t: f64) Color {
    var result: Color = .{ .rgb = undefined, .alpha = a.alpha + (b.alpha - a.alpha) * t };

    for (&result.rgb, a.rgb, b.rgb) |*out, x, y|
        out.* = x + (y - x) * t;

    return result;
}

pub fn gradient(stops: []const profile.Stop, position: f64) Color {
    if (stops.len == 0)
        return .{ .rgb = .{ 0, 0, 0 }, .alpha = 0 };

    const pos = std.math.clamp(position, 0, 1);

    if (pos <= stops[0].position)
        return stops[0].color;

    for (stops[1..], 1..) |stop, i| {
        if (pos <= stop.position) {
            const previous = stops[i - 1];

            return mix(previous.color, stop.color, (pos - previous.position) / (stop.position - previous.position));
        }
    }

    return stops[stops.len - 1].color;
}

pub fn encodeColor(c: Color) profile.TableColor {
    return .{
        .rgb = .{ @intFromFloat(c.rgb[0]), @intFromFloat(c.rgb[1]), @intFromFloat(c.rgb[2]) },
        .transparency = @intFromFloat(@round((1 - c.alpha) * 100)),
    };
}

fn percent(stop: profile.Stop) usize {
    return stop.percent orelse @as(u32, @intFromFloat(@round(stop.position * 100)));
}

fn stopIndex(stop: profile.Stop, count: usize) usize {
    return percent(stop) * count / 100;
}

pub fn table(allocator: std.mem.Allocator, stops: []const profile.Stop, count: usize) ![]const profile.TableColor {
    std.debug.assert(stops.len > 0 and count >= 2);

    const normalized = try allocator.alloc(profile.Stop, stops.len + 2);
    defer allocator.free(normalized);

    var len: usize = 0;

    if (stops[0].position > 0) {
        normalized[len] = .{ .position = 0, .color = stops[0].color };
        len += 1;
    }

    @memcpy(normalized[len..][0..stops.len], stops);
    len += stops.len;

    if (stops[stops.len - 1].position < 1) {
        normalized[len] = .{ .position = 1, .color = stops[stops.len - 1].color };
        len += 1;
    }

    const samples = try allocator.alloc(profile.TableColor, count);
    @memset(samples, .{ .rgb = .{ 0, 0, 0 }, .transparency = 0 });

    const size: f64 = @floatFromInt(count);

    for (normalized[0 .. len - 1], normalized[1..len]) |start, *end| {
        const first = stopIndex(start, count);
        const limit = stopIndex(end.*, count);

        if (first >= limit) {
            end.percent = @intFromFloat(@min(100, @floor(@as(f64, @floatFromInt(first + 1)) * 100 / size + 1)));
            end.position = @as(f64, @floatFromInt(end.percent.?)) / 100;
        }
    }

    for (normalized[0 .. len - 1], normalized[1..len]) |start, end| {
        const first = stopIndex(start, count);
        const limit = stopIndex(end, count);

        if (first >= count)
            break;

        samples[first] = encodeColor(start.color);

        if (limit <= first + 1)
            continue;

        const last = @min(limit - 1, count - 1);
        samples[last] = encodeColor(end.color);

        const a = encodeColor(start.color);
        const b = encodeColor(end.color);
        var values: [4]f32 = .{ @floatFromInt(a.rgb[0]), @floatFromInt(a.rgb[1]), @floatFromInt(a.rgb[2]), @floatFromInt(a.transparency) };
        const targets: [4]f32 = .{ @floatFromInt(b.rgb[0]), @floatFromInt(b.rgb[1]), @floatFromInt(b.rgb[2]), @floatFromInt(b.transparency) };
        var steps: [4]f32 = undefined;

        for (&steps, values, targets) |*step, x, y|
            step.* = (y - x) / @as(f32, @floatFromInt(last - first));

        for (samples[first + 1 .. last]) |*sample_color| {
            for (&values, steps) |*value, step|
                value.* += step;

            sample_color.* = .{
                .rgb = .{ @intFromFloat(values[0]), @intFromFloat(values[1]), @intFromFloat(values[2]) },
                .transparency = @intFromFloat(values[3]),
            };
        }
    }

    samples[0] = encodeColor(stops[0].color);
    samples[count - 1] = encodeColor(stops[stops.len - 1].color);

    return samples;
}

pub fn prepare(allocator: std.mem.Allocator, p: *Parameters, device: profile.Device) !void {
    if (p.kind == .wave) {
        const angle: f32 = @floatCast((@trunc(p.angle) + 270) * std.math.tau / 360);
        const dx = @cos(angle);
        const dy = @sin(angle);
        const projected_x: i32 = @intFromFloat(dx * @as(f32, @floatFromInt(device.columns)));
        const projected_y: i32 = @intFromFloat(dy * @as(f32, @floatFromInt(device.rows)));
        p.projected_extent = @max(1, @abs(projected_x) + @abs(projected_y));
        p.direction_x = if (@abs(dx) < 0.0001) 0 else dx;
        p.direction_y = if (@abs(dy) < 0.0001) 0 else dy;
        const extent: f32 = @floatFromInt(p.projected_extent);
        const speed: f32 = @floatCast(@trunc(p.speed));
        const step: f32 = if (speed == 0) @as(f32, 1) / profile.fps else ((speed * 4 / 100) * extent) / profile.fps;
        p.traversal = @intFromFloat(extent / step);
        const endpoint_count = @as(usize, @intFromBool(p.stops[0].position > 0)) +
            @as(usize, @intFromBool(p.stops[p.stops.len - 1].position < 1));
        const count = @max(p.stops.len + endpoint_count, @as(usize, @intFromFloat(@floor(waveTraversal(p) * (p.width / 100)))));
        p.table = try table(allocator, p.stops, count);
        return;
    }
    if (p.kind == .wheel) {
        p.table = try table(allocator, p.stops, 1024);
        return;
    }
    if (p.kind != .breathing and p.kind != .spectrum)
        return;

    const black: Color = .{ .rgb = .{ 0, 0, 0 } };
    const breathing = [_]profile.Stop{
        .{ .position = 0, .color = black },
        .{ .position = 0.12, .color = black },
        .{ .position = 0.25, .color = p.color },
        .{ .position = 0.38, .color = p.color },
        .{ .position = 0.50, .color = black },
        .{ .position = 0.62, .color = black },
        .{ .position = 0.75, .color = p.color2 },
        .{ .position = 0.88, .color = p.color2 },
        .{ .position = 1, .color = black },
    };
    const stops = if (p.kind == .breathing and p.random) &random_breathing_stops else if (p.stops.len != 0) p.stops else &breathing;
    const endpoint_count = @as(usize, @intFromBool(stops[0].position > 0)) +
        @as(usize, @intFromBool(stops[stops.len - 1].position < 1));
    const duration_ms = @floor(@round(p.duration * 1000) / (if (p.kind == .breathing and p.random) @as(f64, 2) else 1));
    const count = @max(stops.len + endpoint_count, @as(usize, @intFromFloat(@floor(duration_ms / profile.frame_ms))));

    p.table = try table(allocator, stops, count);
}

fn waveTraversal(p: *const Parameters) f64 {
    return @floatFromInt(p.traversal);
}

pub fn sample(p: Parameters, pixel: profile.Pixel, time: f64, seed: u32, device: profile.Device) Color {
    _ = seed;
    return sampleTick(p, pixel, @intFromFloat(@floor(time * profile.fps)), device);
}

pub fn sampleTick(p: Parameters, pixel: profile.Pixel, frame: u64, device: profile.Device) Color {
    const transparent: Color = .{ .rgb = .{ 0, 0, 0 }, .alpha = 0 };
    if (p.kind == .static)
        return p.color;

    if (p.kind == .wave) {
        std.debug.assert(p.table.len > 0);
        const padding: usize = @intFromFloat(@floor(@round(p.pause * 1000) / profile.frame_ms));
        const period = p.table.len + padding;
        const tick = if (p.speed == 0) 0 else frame;
        const cycle = tick / period;
        if (p.end == .after and cycle >= p.cycles)
            return transparent;

        const dx = p.direction_x;
        const dy = p.direction_y;
        const columns: f32 = @floatFromInt(device.columns);
        const rows: f32 = @floatFromInt(device.rows);
        const traversal: f32 = @floatFromInt(p.traversal);
        const projection = (@as(f32, @floatCast(pixel.y)) * dy / rows) +
            (@as(f32, @floatCast(pixel.x)) * dx / columns);
        var spatial: i64 = @intFromFloat(projection * traversal);
        const final = p.end == .after and cycle + 1 == p.cycles;
        const count = p.stops.len + @as(usize, @intFromBool(p.stops[0].position > 0)) +
            @as(usize, @intFromBool(p.stops[p.stops.len - 1].position < 1));
        const length = if (final and p.projected_extent >= count) period + p.table.len else period;
        const phase: i64 = @intCast(tick % period);
        const base = @as(i64, @intCast(length)) - phase;
        var offset = base;
        if (final and (dx < 0 or (dx == 0 and dy <= 0)))
            offset -= @intCast(p.table.len);
        if (p.split) {
            const center: i64 = @intFromFloat((@as(f32, @floatFromInt(device.rows / 2)) * dy / rows +
                @as(f32, @floatFromInt(device.columns / 2)) * dx / columns) * traversal);
            spatial = @intCast(@abs(spatial - center));
            offset = if (dx > 0 or (dx == 0 and dy > 0)) base else phase;
        }
        const index: usize = @intCast(@mod(spatial + offset, @as(i64, @intCast(length))));
        return if (index < p.table.len) p.table[index].color() else transparent;
    }

    if (p.kind == .breathing or p.kind == .spectrum) {
        std.debug.assert(p.table.len > 0);

        const tick = frame;
        const cycle = tick / p.table.len;

        if (p.end == .after and cycle >= p.cycles)
            return transparent;

        return p.table[@intCast(tick % p.table.len)].color();
    }

    switch (p.kind) {
        .static, .breathing, .spectrum, .wave => unreachable,
        .wheel => {
            const speed: f32 = @floatCast(@trunc(p.speed));
            const period: u64 = if (speed == 0) 0 else @as(u64, @intFromFloat(@as(f32, 360000) / speed)) / profile.frame_ms;
            if (p.end == .after and period != 0 and frame / period >= p.cycles)
                return transparent;
            const x: f32 = @floatCast(@trunc(pixel.x) - @trunc(p.center_x orelse 0));
            const y: f32 = @floatCast(@trunc(pixel.y) - @trunc(p.center_y orelse 0));
            const angular: i64 = @intFromFloat(1024 * (std.math.atan2(@as(f64, y), @as(f64, x)) + std.math.pi) / std.math.tau);
            const progress: f32 = if (period == 0) 0 else @as(f32, @floatFromInt(frame % period)) * 1024 / @as(f32, @floatFromInt(period));
            const phase: i64 = @intFromFloat(if (p.counterclockwise) progress else 1024 - progress);
            const index: usize = @intCast(@mod(angular + phase, 1024));
            return p.table[index].color();
        },
        .starlight, .fire, .reactive, .ripple => unreachable, // These require the owned runtime in state.zig.
    }
}

test "gradient interpolates opacity and clamps ends" {
    const stops = [_]profile.Stop{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 }, .alpha = 0 } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 255, 255 } } },
    };
    const c = gradient(&stops, 0.5);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), c.alpha, 0.001);
    try std.testing.expectEqual(@as(f64, 127.5), c.rgb[1]);
    try std.testing.expectEqual(@as(f64, 1), gradient(&stops, 2).alpha);
}

test "finite breathing ends transparently and zero-speed wave stays still" {
    const device: profile.Device = .{ .pid = 1, .rows = 2, .columns = 2 };
    const pixel: profile.Pixel = .{ .offset = 0, .x = 0, .y = 0 };
    var p: Parameters = .{ .kind = .breathing, .duration = 1, .end = .after, .cycles = 2 };
    try prepare(std.testing.allocator, &p, device);
    defer std.testing.allocator.free(p.table);

    try std.testing.expectEqual(@as(f64, 0), sample(p, pixel, 2, 1, device).alpha);
    const stops = [_]profile.Stop{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 255 } } },
    };
    var wave: Parameters = .{ .kind = .wave, .speed = 0, .stops = &stops };
    try prepare(std.testing.allocator, &wave, device);
    defer std.testing.allocator.free(wave.table);
    try std.testing.expectEqual(sample(wave, pixel, 0, 1, device), sample(wave, pixel, 100, 1, device));
}

test "wave angles follow Synapse cardinal directions and Aurora vertical travel" {
    const device: profile.Device = .{ .pid = 1, .rows = 6, .columns = 16 };
    const stops = [_]profile.Stop{
        .{ .position = 0, .color = .{ .rgb = .{ 0, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 255, 255, 255 } } },
    };
    const cases = [_]struct { angle: f64, x: f64, y: f64 }{
        .{ .angle = 0, .x = 0, .y = -1 },
        .{ .angle = 90, .x = 1, .y = 0 },
        .{ .angle = 180, .x = 0, .y = 1 },
        .{ .angle = 270, .x = -1, .y = 0 },
        .{ .angle = 195, .x = -0.25881904510252074, .y = 0.9659258262890683 },
    };

    for (cases) |case| {
        var p: Parameters = .{ .kind = .wave, .speed = 25, .angle = case.angle, .stops = &stops };
        try prepare(std.testing.allocator, &p, device);
        defer std.testing.allocator.free(p.table);
        const pixel: profile.Pixel = .{ .offset = 0, .x = case.x * 16 * 0.21, .y = case.y * 6 * 0.21 };
        const initial = sample(p, pixel, 0, 1, device);

        try std.testing.expect(initial.rgb[0] > 0 and initial.rgb[0] < 255);

        const distance = 0.21 + 5 / @as(f64, @floatFromInt(p.traversal));
        const advanced: profile.Pixel = .{ .offset = 0, .x = case.x * 16 * distance, .y = case.y * 6 * distance };
        const moved = sample(p, advanced, 0.2, 1, device);

        try std.testing.expectApproxEqAbs(initial.rgb[0], moved.rgb[0], 0.000001);
    }
}

test "wave width follows device extent and pause is moving spatial padding" {
    const device: profile.Device = .{ .pid = 1, .rows = 6, .columns = 16 };
    var p: Parameters = .{ .kind = .wave, .speed = 11, .pause = 2, .stops = &.{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 255 } } },
    } };
    try prepare(std.testing.allocator, &p, device);
    defer std.testing.allocator.free(p.table);
    const left: profile.Pixel = .{ .offset = 0, .x = 0, .y = 0 };
    const right: profile.Pixel = .{ .offset = 0, .x = 15, .y = 0 };
    try std.testing.expectEqual(@as(usize, 56), p.table.len);
    try std.testing.expectEqual(p.table[52].color(), sample(p, right, 0, 1, device));
    try std.testing.expectEqual(@as(f64, 0), sample(p, left, 0.4, 1, device).alpha);
    try std.testing.expectEqual(@as(f64, 1), sample(p, right, 0.4, 1, device).alpha);
    try std.testing.expectEqual(sample(p, right, 0, 1, device), sample(p, right, 4.24, 1, device));
    try std.testing.expectEqual(sample(p, right, 0, 1, device), sample(p, right, 0.039, 1, device));
    const wide: profile.Device = .{ .pid = 1, .rows = 6, .columns = 32 };
    const scaled: profile.Pixel = .{ .offset = 0, .x = 30, .y = 0 };
    try std.testing.expectEqual(sample(p, right, 0, 1, device), sample(p, scaled, 0, 1, wide));
    p.end = .after;
    try std.testing.expectEqual(@as(f64, 0), sample(p, right, 4.24, 1, device).alpha);
}

test "wave width controls gradient length and zero speed ignores pause advancement" {
    const device: profile.Device = .{ .pid = 1, .rows = 6, .columns = 16 };
    var p: Parameters = .{ .kind = .wave, .speed = 25, .width = 200, .stops = &.{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 255 } } },
    } };
    try prepare(std.testing.allocator, &p, device);
    try std.testing.expectEqual(@as(usize, 50), p.table.len);
    std.testing.allocator.free(p.table);
    p.speed = 0;
    p.width = 100;
    p.pause = 2;
    try prepare(std.testing.allocator, &p, device);
    defer std.testing.allocator.free(p.table);
    const pixel: profile.Pixel = .{ .offset = 0, .x = 8, .y = 2 };
    try std.testing.expectEqual(sample(p, pixel, 0, 1, device), sample(p, pixel, 100, 1, device));
}

test "discrete gradients interpolate colour and transparency independently" {
    const stops = [_]profile.Stop{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 0 }, .alpha = 0 } },
    };
    const samples = try table(std.testing.allocator, &stops, 5);
    defer std.testing.allocator.free(samples);

    const expected_red = [_]u8{ 255, 191, 127, 63, 0 };
    const expected_transparency = [_]u8{ 0, 25, 50, 75, 100 };

    for (samples, expected_red, expected_transparency) |c, red, transparency| {
        try std.testing.expectEqual(red, c.rgb[0]);
        try std.testing.expectEqual(transparency, c.transparency);
    }
}

test "discrete gradients extend endpoints and separate collapsed stops" {
    const stops = [_]profile.Stop{
        .{ .position = 0.20, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 0.21, .color = .{ .rgb = .{ 0, 255, 0 } } },
        .{ .position = 0.80, .color = .{ .rgb = .{ 0, 0, 255 } } },
    };
    const samples = try table(std.testing.allocator, &stops, 10);
    defer std.testing.allocator.free(samples);

    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, samples[0].rgb);
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, samples[2].rgb);
    try std.testing.expectEqual([3]u8{ 0, 255, 0 }, samples[3].rgb);
    try std.testing.expectEqual([3]u8{ 0, 0, 255 }, samples[9].rgb);
}

test "breathing pulses through black and durations are frame quantized" {
    const device: profile.Device = .{ .pid = 1, .rows = 1, .columns = 1 };
    var p: Parameters = .{
        .kind = .breathing,
        .duration = 4,
        .color = .{ .rgb = .{ 255, 0, 0 } },
        .color2 = .{ .rgb = .{ 0, 0, 255 } },
        .end = .after,
        .cycles = 1,
    };
    try prepare(std.testing.allocator, &p, device);
    defer std.testing.allocator.free(p.table);

    const pixel: profile.Pixel = .{ .offset = 0, .x = 0, .y = 0 };

    try std.testing.expectEqual(@as(usize, 100), p.table.len);
    try std.testing.expectEqual([3]f64{ 0, 0, 0 }, sample(p, pixel, 0, 1, device).rgb);
    try std.testing.expectEqual(p.color, sample(p, pixel, 1, 1, device));
    try std.testing.expectEqual([3]f64{ 0, 0, 0 }, sample(p, pixel, 2, 1, device).rgb);
    try std.testing.expectEqual(p.color2, sample(p, pixel, 3, 1, device));
    try std.testing.expectEqual(@as(f64, 0), sample(p, pixel, 4, 1, device).alpha);

    var spectrum: Parameters = .{ .kind = .spectrum, .duration = 37.740, .stops = &.{
        .{ .position = 0, .color = p.color },
        .{ .position = 1, .color = p.color2 },
    } };
    try prepare(std.testing.allocator, &spectrum, device);
    defer std.testing.allocator.free(spectrum.table);

    try std.testing.expectEqual(@as(usize, 943), spectrum.table.len);
    try std.testing.expectEqual(sample(spectrum, pixel, 0, 1, device), sample(spectrum, pixel, 37.72, 1, device));
    try std.testing.expectEqual(sample(spectrum, pixel, 0, 1, device), sample(spectrum, pixel, 0.039, 1, device));
}

test "random breathing halves duration and the palette excludes greys" {
    var p: Parameters = .{ .kind = .breathing, .duration = 4, .random = true };
    try prepare(std.testing.allocator, &p, .{ .pid = 1, .rows = 1, .columns = 1 });
    defer std.testing.allocator.free(p.table);

    try std.testing.expectEqual(@as(usize, 50), p.table.len);

    var seen: [27]bool = @splat(false);
    var rng: @import("random.zig").Generator = .{ .state = 1 };

    for (0..1000) |_| {
        const c = rng.color();
        var combination: usize = 0;

        for (c.rgb) |value| {
            try std.testing.expect(value == 0 or value == 128 or value == 255);
            combination = combination * 3 + (if (value == 0) @as(usize, 0) else if (value == 128) @as(usize, 1) else 2);
        }

        try std.testing.expect(!(c.rgb[0] == c.rgb[1] and c.rgb[1] == c.rgb[2]));
        seen[combination] = true;
    }

    try std.testing.expectEqual(@as(usize, 24), std.mem.count(bool, &seen, &.{true}));
}

test "wheel revolution is quantized to native frame intervals" {
    const device: profile.Device = .{ .pid = 1, .rows = 3, .columns = 3 };
    var p: Parameters = .{ .kind = .wheel, .speed = 7, .stops = &.{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 255 } } },
    } };
    try prepare(std.testing.allocator, &p, device);
    defer std.testing.allocator.free(p.table);
    const pixel: profile.Pixel = .{ .offset = 0, .x = 2, .y = 1 };
    const initial = sample(p, pixel, 0, 1, device);

    try std.testing.expectEqual(initial, sample(p, pixel, 51.4, 1, device));
    try std.testing.expect(!std.meta.eql(initial, sample(p, pixel, 0.6, 1, device)));
}

test "integer percentage indices do not slip below their native stop" {
    const stops = [_]profile.Stop{
        .{ .position = 0, .color = .{ .rgb = .{ 0, 0, 0 } } },
        .{ .position = 0.29, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 0.57, .color = .{ .rgb = .{ 0, 255, 0 } } },
        .{ .position = 0.58, .color = .{ .rgb = .{ 0, 0, 255 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 0 } } },
    };
    const samples = try table(std.testing.allocator, &stops, 100);
    defer std.testing.allocator.free(samples);
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, samples[29].rgb);
    try std.testing.expectEqual([3]u8{ 0, 255, 0 }, samples[57].rgb);
    try std.testing.expectEqual([3]u8{ 0, 0, 255 }, samples[58].rgb);
}

test "wave traversal preserves native float32 operations and zero-speed extent" {
    const stops = [_]profile.Stop{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 255 } } },
    };
    const device: profile.Device = .{ .pid = 1, .rows = 6, .columns = 16 };
    var p: Parameters = .{ .kind = .wave, .speed = 5, .stops = &stops };
    try prepare(std.testing.allocator, &p, device);
    try std.testing.expectEqual(@as(usize, 124), p.traversal);
    std.testing.allocator.free(p.table);
    p.speed = 0;
    try prepare(std.testing.allocator, &p, device);
    defer std.testing.allocator.free(p.table);
    try std.testing.expectEqual(@as(usize, 400), p.traversal);
}

test "wave width divides percentage before multiplying traversal" {
    var p: Parameters = .{ .kind = .wave, .speed = 0, .angle = 0, .width = 29, .stops = &.{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 255 } } },
    } };
    try prepare(std.testing.allocator, &p, .{ .pid = 1, .rows = 4, .columns = 16 });
    defer std.testing.allocator.free(p.table);
    try std.testing.expectEqual(@as(usize, 100), p.traversal);
    try std.testing.expectEqual(@as(usize, 28), p.table.len);
}

test "split wave reflects around integer canvas midpoint and follows direction phase" {
    const device: profile.Device = .{ .pid = 1, .rows = 6, .columns = 16 };
    var p: Parameters = .{ .kind = .wave, .speed = 25, .split = true, .stops = &.{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 255 } } },
    } };
    try prepare(std.testing.allocator, &p, device);
    defer std.testing.allocator.free(p.table);
    const center: profile.Pixel = .{ .offset = 0, .x = 8, .y = 3 };
    const left: profile.Pixel = .{ .offset = 0, .x = 0, .y = 3 };
    try std.testing.expectEqual(p.table[0].color(), sampleTick(p, center, 0, device));
    try std.testing.expectEqual(p.table[12].color(), sampleTick(p, left, 0, device));
    try std.testing.expectEqual(p.table[11].color(), sampleTick(p, left, 1, device));
    p.direction_x = -1;
    try std.testing.expectEqual(p.table[13].color(), sampleTick(p, left, 1, device));
}

test "finite wave final cycle uses extra transparent tail and sign-dependent offset" {
    const device: profile.Device = .{ .pid = 1, .rows = 6, .columns = 16 };
    var p: Parameters = .{ .kind = .wave, .speed = 25, .end = .after, .cycles = 1, .stops = &.{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 255 } } },
    } };
    try prepare(std.testing.allocator, &p, device);
    defer std.testing.allocator.free(p.table);
    const left: profile.Pixel = .{ .offset = 0, .x = 0, .y = 0 };
    try std.testing.expectEqual(p.table[0].color(), sampleTick(p, left, 0, device));
    try std.testing.expectEqual(@as(f64, 0), sampleTick(p, left, 1, device).alpha);
    p.direction_x = -1;
    try std.testing.expectEqual(@as(f64, 0), sampleTick(p, left, 0, device).alpha);
    try std.testing.expectEqual(p.table[24].color(), sampleTick(p, left, 1, device));
    try std.testing.expectEqual(@as(f64, 0), sampleTick(p, left, 25, device).alpha);
}

test "split phase sign table covers cardinal and diagonal finite and infinite paths" {
    const device: profile.Device = .{ .pid = 1, .rows = 6, .columns = 16 };
    const pixel: profile.Pixel = .{ .offset = 0, .x = 8, .y = 3 };
    var p: Parameters = .{ .kind = .wave, .speed = 25, .split = true, .stops = &.{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 255 } } },
    } };
    try prepare(std.testing.allocator, &p, device);
    defer std.testing.allocator.free(p.table);
    for ([_]f32{ -1, 0, 1 }) |dx| {
        for ([_]f32{ -1, 0, 1 }) |dy| {
            if (dx == 0 and dy == 0) continue;
            p.direction_x = dx;
            p.direction_y = dy;
            const reverse = dx < 0 or (dx == 0 and dy < 0);
            p.end = .never;
            try std.testing.expectEqual(p.table[if (reverse) 1 else 24].color(), sampleTick(p, pixel, 1, device));
            p.end = .after;
            const c = sampleTick(p, pixel, 1, device);
            if (reverse)
                try std.testing.expectEqual(p.table[1].color(), c)
            else
                try std.testing.expectEqual(@as(f64, 0), c.alpha);
        }
    }
}

test "wheel uses discrete half-turn origin and native clockwise phase truncation" {
    const device: profile.Device = .{ .pid = 1, .rows = 3, .columns = 3 };
    const pixel: profile.Pixel = .{ .offset = 0, .x = 2, .y = 1 };
    var p: Parameters = .{ .kind = .wheel, .speed = 7, .center_x = 1, .center_y = 1, .stops = &.{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 255 } } },
    } };
    try prepare(std.testing.allocator, &p, device);
    defer std.testing.allocator.free(p.table);
    try std.testing.expectEqual(p.table[512].color(), sampleTick(p, pixel, 0, device));
    try std.testing.expectEqual(p.table[511].color(), sampleTick(p, pixel, 1, device));
    p.counterclockwise = true;
    try std.testing.expectEqual(p.table[512].color(), sampleTick(p, pixel, 1, device));
}
