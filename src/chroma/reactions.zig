const std = @import("std");
const profile = @import("profile.zig");
const effects = @import("effects.zig");
const Generator = @import("random.zig").Generator;
const transparent: profile.TableColor = .{ .rgb = .{ 0, 0, 0 }, .transparency = 100 };
const black: profile.TableColor = .{ .rgb = .{ 0, 0, 0 }, .transparency = 0 };

const Reaction = struct {
    origin: profile.KeyEvent,
    start: u64,
    table: []const profile.TableColor,
};

pub const Reactions = struct {
    allocator: std.mem.Allocator,
    parameters: profile.Parameters,
    device: profile.Device,
    rng: Generator,
    children: std.ArrayList(Reaction) = .empty,
    output: []profile.TableColor,
    scratch: []profile.TableColor,
    tick: ?u64 = null,
    last_input: ?usize = null,
    step: f32 = 0,
    speed: u32 = 0,
    period: u64,
    width: i32 = 0,
    table_count: usize,

    pub fn init(allocator: std.mem.Allocator, p: profile.Parameters, device: profile.Device, seed: u32) !Reactions {
        const cells = @as(usize, device.rows) * device.columns;
        const output = try allocator.alloc(profile.TableColor, cells);
        errdefer allocator.free(output);
        const scratch = try allocator.alloc(profile.TableColor, if (p.kind == .ripple) cells else 0);
        errdefer allocator.free(scratch);
        @memset(output, transparent);
        var self: Reactions = .{
            .allocator = allocator,
            .parameters = p,
            .device = device,
            .rng = .{ .state = seed },
            .output = output,
            .scratch = scratch,
            .period = 0,
            .table_count = 0,
        };
        if (p.kind == .reactive) {
            self.table_count = @max(2, @as(usize, @intFromFloat(@round(p.duration * 1000))) / profile.frame_ms);
            self.period = self.table_count;
        } else {
            const maximum = @max(device.rows, device.columns);
            const minimum = @min(device.rows, device.columns);
            var speed: u32 = @intFromFloat(p.speed);
            const half: i32 = maximum / 2;
            if (speed >= 26 and @as(f32, @floatFromInt(speed / profile.fps)) > @as(f32, @floatFromInt(half)) - 2) {
                if (half < 2) return error.InvalidChromaParameter;
                speed = @intCast((half - 2) * profile.fps);
            }
            speed = @max(1, speed);
            self.speed = speed;
            self.step = @as(f32, @floatFromInt(speed)) / profile.fps;
            self.width = @intFromFloat(p.width / 100);
            const count = @as(usize, maximum) + @as(usize, @intCast(self.width)) + minimum / 2 + 1;
            self.table_count = count;
            self.period = @intFromFloat(@as(f32, @floatFromInt(count)) / self.step + 1);
        }
        return self;
    }

    pub fn deinit(self: *Reactions) void {
        for (self.children.items) |child| self.allocator.free(child.table);
        self.children.deinit(self.allocator);
        self.allocator.free(self.output);
        self.allocator.free(self.scratch);
    }

    pub fn trigger(self: *Reactions, event: profile.KeyEvent, tick: u64) !void {
        if (self.tick) |current| if (tick < current) return error.InputTimeReversed;
        if (!event.pressed) {
            if (self.parameters.kind == .ripple) self.last_input = null;
            return;
        }
        const cell = @as(usize, event.row) * self.device.columns + event.col;
        if (self.parameters.kind == .ripple and self.output.len > 1 and self.last_input == cell) return;

        const samples = try self.makeTable();
        errdefer self.allocator.free(samples);
        const child: Reaction = .{ .origin = event, .start = tick, .table = samples };
        if (self.parameters.kind == .reactive) {
            for (self.children.items) |*old| {
                if (old.origin.row == event.row and old.origin.col == event.col) {
                    self.allocator.free(old.table);
                    old.* = child;
                    return;
                }
            }
        }
        try self.children.append(self.allocator, child);
        self.last_input = cell;
    }

    fn makeTable(self: *Reactions) ![]const profile.TableColor {
        const p = self.parameters;
        if (p.kind == .reactive) {
            const stops = [_]profile.Stop{
                .{ .position = 0, .color = if (p.random) self.rng.color() else p.color },
                .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 0 } } },
            };
            return effects.table(self.allocator, &stops, self.table_count);
        }
        const base_count = self.table_count - @min(self.device.rows, self.device.columns) / 2 - 1;
        const base = try effects.table(self.allocator, p.stops, base_count);
        defer self.allocator.free(base);
        const samples = try self.allocator.alloc(profile.TableColor, self.table_count);
        @memcpy(samples[0..base.len], base);
        @memset(samples[base.len..], base[base.len - 1]);
        return samples;
    }

    pub fn advance(self: *Reactions, tick: u64) !void {
        if (self.tick) |current| if (tick < current) return error.InputTimeReversed;
        self.tick = tick;
        @memset(self.output, transparent);
        var index: usize = 0;
        while (index < self.children.items.len) {
            const child = self.children.items[index];
            if (tick < child.start) return error.InputTimeReversed;
            const age = tick - child.start;
            if (self.parameters.end == .after and age / self.period >= self.parameters.cycles) {
                self.allocator.free(child.table);
                _ = self.children.orderedRemove(index);
                continue;
            }
            const phase = age % self.period;
            if (self.parameters.kind == .reactive) {
                var c = child.table[@intCast(phase)];
                // Black is transparent; non-black RGB is opaque.
                c.transparency = if (std.mem.eql(u8, &c.rgb, &black.rgb)) 100 else 0;
                self.output[@as(usize, child.origin.row) * self.device.columns + child.origin.col] = c;
            } else {
                self.ripple(child, phase);
            }
            index += 1;
        }
    }

    fn ripple(self: *Reactions, child: Reaction, phase: u64) void {
        @memset(self.scratch, black);
        const i = @min(@as(usize, @intFromFloat(@as(f32, @floatFromInt(phase)) * self.step)), child.table.len - 1);
        const radius: i32 = @intCast(i);
        const inner = radius - self.width;
        const color = child.table[i];
        if (inner <= 0) self.point(child.origin.col, child.origin.row, color);
        if (self.step > 0.5) {
            self.disk(child.origin, radius, color);
        } else {
            const reciprocal: f32 = @as(f32, profile.fps) / @as(f32, @floatFromInt(self.speed));
            const fraction: f32 = (@as(f32, @floatFromInt(phase)) - @as(f32, @floatFromInt(i)) * reciprocal) / reciprocal;
            // Extend the endpoint so interpolation can safely read the next entry.
            const next = child.table[@min(i + 1, child.table.len - 1)];
            self.disk(child.origin, radius + 1, scaleOuter(next, fraction));
            if (self.width >= 2) self.disk(child.origin, radius, color);
            self.disk(child.origin, inner + 1, scaleInner(color, 1 - @as(f64, fraction)));
        }
        self.disk(child.origin, inner, black);
        for (self.output, self.scratch) |*out, sample_color| {
            if (sample_color.transparency != 0 or !std.mem.eql(u8, &sample_color.rgb, &black.rgb))
                out.* = sample_color;
        }
    }

    fn point(self: *Reactions, x: i32, y: i32, color: profile.TableColor) void {
        if (x < 0 or y < 0 or x >= self.device.columns or y >= self.device.rows) return;
        self.scratch[@as(usize, @intCast(y)) * self.device.columns + @as(usize, @intCast(x))] = color;
    }

    fn span(self: *Reactions, first: i32, last: i32, row: i32, color: profile.TableColor) void {
        if (row < 0 or row >= self.device.rows) return;
        var x = @max(0, first);
        while (x <= @min(last, @as(i32, self.device.columns) - 1)) : (x += 1)
            self.point(x, row, color);
    }

    fn disk(self: *Reactions, origin: profile.KeyEvent, radius: i32, color: profile.TableColor) void {
        if (radius < 0) return;
        const x: i32 = origin.col;
        const y: i32 = origin.row;
        self.span(x - radius, x + radius, y, color);
        if (radius == 0) return;
        var a: i32 = 0;
        var b = radius;
        var err = 1 - radius;
        while (a < b) : (a += 1) {
            if (err >= 0) {
                self.span(x - a, x + a, y - b, color);
                self.span(x - a, x + a, y + b, color);
                err += 2 - 2 * b;
                b -= 1;
            }
            if (a != b) {
                self.span(x - b, x + b, y - a - 1, color);
                self.span(x - b, x + b, y + a + 1, color);
            }
            err += 2 * a + 3;
        }
    }

    pub fn sample(self: *const Reactions, pixel: profile.Pixel) profile.Color {
        return self.output[pixel.offset / 3].color();
    }
};

fn scaleOuter(c: profile.TableColor, fraction: f32) profile.TableColor {
    var result = c;
    for (&result.rgb, c.rgb) |*out, channel|
        out.* = @intFromFloat(@as(f32, @floatFromInt(channel)) * fraction);
    return result;
}

fn scaleInner(c: profile.TableColor, fraction: f64) profile.TableColor {
    var result = c;
    for (&result.rgb, c.rgb) |*out, channel|
        out.* = @intFromFloat(@as(f64, @floatFromInt(channel)) * fraction);
    return result;
}

test "Reactive pulses restart on presses, ignore releases, and expire through black" {
    var state = try Reactions.init(std.testing.allocator, .{
        .kind = .reactive,
        .color = .{ .rgb = .{ 255, 0, 0 } },
        .duration = 0.16,
        .end = .after,
    }, .{ .pid = 694, .rows = 1, .columns = 2 }, 1);
    defer state.deinit();
    const key: profile.KeyEvent = .{ .row = 0, .col = 1, .pressed = true };
    try state.advance(0);
    try std.testing.expectEqual(@as(u8, 100), state.output[1].transparency);
    try state.trigger(key, 0);
    try state.advance(0);
    try std.testing.expectEqual(@as(u8, 255), state.output[1].rgb[0]);
    try state.advance(1);
    try std.testing.expectEqual(@as(u8, 170), state.output[1].rgb[0]);
    try state.trigger(.{ .row = 0, .col = 1, .pressed = false }, 1);
    try state.advance(1);
    try std.testing.expectEqual(@as(u8, 170), state.output[1].rgb[0]);
    try state.trigger(key, 2);
    try state.advance(2);
    try std.testing.expectEqual(@as(u8, 255), state.output[1].rgb[0]);
    try std.testing.expectEqual(@as(usize, 1), state.children.items.len);
    try state.advance(5);
    try std.testing.expectEqual(@as(u8, 100), state.output[1].transparency);
    try state.advance(6);
    try std.testing.expectEqual(@as(usize, 0), state.children.items.len);
    try std.testing.expectError(error.InputTimeReversed, state.advance(1));
}

test "Ripple uses native filled disks, repeat suppression, release rearming and frozen palettes" {
    var stops = [_]profile.Stop{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 255, 0, 0 } } },
    };
    var state = try Reactions.init(std.testing.allocator, .{
        .kind = .ripple,
        .stops = &stops,
        .speed = 25,
        .width = 300,
        .end = .after,
    }, .{ .pid = 694, .rows = 7, .columns = 9 }, 1);
    defer state.deinit();
    const key: profile.KeyEvent = .{ .row = 3, .col = 4, .pressed = true };
    try state.trigger(key, 0);
    try state.trigger(key, 0);
    try std.testing.expectEqual(@as(usize, 1), state.children.items.len);
    try state.advance(1);
    var lit: usize = 0;
    for (state.output) |c| {
        if (c.rgb[0] == 255) lit += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), lit);
    try state.advance(2);
    lit = 0;
    for (state.output) |c| {
        if (c.rgb[0] == 255) lit += 1;
    }
    try std.testing.expectEqual(@as(usize, 21), lit);
    try state.trigger(.{ .row = 3, .col = 4, .pressed = false }, 2);
    stops[0].color.rgb = .{ 0, 0, 255 };
    stops[1].color.rgb = .{ 0, 0, 255 };
    try state.trigger(key, 2);
    try state.advance(2);
    try std.testing.expectEqual(@as(usize, 2), state.children.items.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, &state.output[3 * 9 + 4].rgb);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0 }, &state.output[3 * 9 + 2].rgb);
    try state.advance(state.period + 2);
    try std.testing.expectEqual(@as(usize, 0), state.children.items.len);
}

test "Ripple edge interpolation retains transparency and never samples outside the palette" {
    const c: profile.TableColor = .{ .rgb = .{ 255, 128, 64 }, .transparency = 37 };
    try std.testing.expectEqualDeep(profile.TableColor{
        .rgb = .{ 127, 64, 32 },
        .transparency = 37,
    }, scaleOuter(c, 0.5));
    const stops = [_]profile.Stop{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 128, 64 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 0 }, .alpha = 0 } },
    };
    var state = try Reactions.init(std.testing.allocator, .{
        .kind = .ripple,
        .stops = &stops,
        .speed = 1,
        .width = 100,
        .end = .after,
    }, .{ .pid = 694, .rows = 6, .columns = 16 }, 1);
    defer state.deinit();
    try state.trigger(.{ .row = 0, .col = 0, .pressed = true }, 0);
    var tick: u64 = 0;
    while (tick <= state.period) : (tick += 1) try state.advance(tick);
    try std.testing.expectEqual(@as(usize, 0), state.children.items.len);
}

test "Reaction allocation failures release all tables and frame buffers" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator, kind: profile.Kind) !void {
            const stops = [_]profile.Stop{
                .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
                .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 0 } } },
            };
            var state = try Reactions.init(allocator, .{
                .kind = kind,
                .stops = &stops,
                .duration = 0.16,
                .speed = 10,
                .width = 300,
            }, .{ .pid = 694, .rows = 6, .columns = 16 }, 1);
            defer state.deinit();
            try state.trigger(.{ .row = 2, .col = 5, .pressed = true }, 0);
            try state.trigger(.{ .row = 2, .col = 5, .pressed = false }, 0);
            try state.trigger(.{ .row = 2, .col = 5, .pressed = true }, 0);
            try state.advance(0);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{profile.Kind.reactive});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{profile.Kind.ripple});
}

test "Ripple completes all supported Blade speeds without invalid edge conversions" {
    const stops = [_]profile.Stop{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 255, 255 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 255, 255, 255 } } },
    };
    for (1..51) |speed| {
        var state = try Reactions.init(std.testing.allocator, .{
            .kind = .ripple,
            .stops = &stops,
            .speed = @floatFromInt(speed),
            .width = 400,
            .end = .after,
        }, .{ .pid = 694, .rows = 6, .columns = 16 }, 1);
        defer state.deinit();
        try state.trigger(.{ .row = 2, .col = 8, .pressed = true }, 0);
        var tick: u64 = 0;
        while (tick <= state.period) : (tick += 1) try state.advance(tick);
    }
}

test "Reactive random palettes are deterministic per press and retained across cycles" {
    var state = try Reactions.init(std.testing.allocator, .{
        .kind = .reactive,
        .random = true,
        .duration = 0.16,
        .end = .after,
        .cycles = 2,
    }, .{ .pid = 694, .rows = 1, .columns = 1 }, 7);
    defer state.deinit();
    var rng: Generator = .{ .state = 7 };
    const first = rng.color();
    try state.trigger(.{ .row = 0, .col = 0, .pressed = true }, 0);
    try state.advance(0);
    try std.testing.expectEqualSlices(u8, &state.output[0].rgb, &state.children.items[0].table[0].rgb);
    const initial = state.output[0];
    try std.testing.expectEqual(@as(u8, @intFromFloat(first.rgb[0])), initial.rgb[0]);
    try state.advance(4);
    try std.testing.expectEqualDeep(initial, state.output[0]);
    try state.advance(8);
    try std.testing.expectEqual(@as(usize, 0), state.children.items.len);
}

test "transparent packed Ripple samples overwrite older children but erased disks do not" {
    var stops = [_]profile.Stop{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 255, 0, 0 } } },
    };
    var state = try Reactions.init(std.testing.allocator, .{
        .kind = .ripple,
        .stops = &stops,
        .speed = 25,
        .width = 100,
        .end = .after,
    }, .{ .pid = 694, .rows = 7, .columns = 9 }, 1);
    defer state.deinit();
    try state.trigger(.{ .row = 3, .col = 4, .pressed = true }, 0);
    try state.advance(1);
    try std.testing.expectEqual(@as(u8, 255), state.output[3 * 9 + 5].rgb[0]);
    for (&stops) |*stop| stop.color = .{ .rgb = .{ 0, 0, 0 }, .alpha = 0 };
    try state.trigger(.{ .row = 3, .col = 5, .pressed = true }, 1);
    try state.advance(1);
    try std.testing.expectEqualDeep(transparent, state.output[3 * 9 + 5]);
    try std.testing.expectEqual(@as(u8, 255), state.output[3 * 9 + 3].rgb[0]);
}

test "single-cell Ripple accepts repeated makes and never-ending children keep cycling" {
    const stops = [_]profile.Stop{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 255, 0, 0 } } },
    };
    var state = try Reactions.init(std.testing.allocator, .{
        .kind = .ripple,
        .stops = &stops,
        .speed = 25,
        .width = 100,
        .end = .never,
    }, .{ .pid = 694, .rows = 1, .columns = 1 }, 1);
    defer state.deinit();
    const key: profile.KeyEvent = .{ .row = 0, .col = 0, .pressed = true };
    try state.trigger(key, 0);
    try state.trigger(key, 0);
    try state.advance(state.period * 3);
    try std.testing.expectEqual(@as(usize, 2), state.children.items.len);
    try std.testing.expectEqual(@as(u8, 255), state.output[0].rgb[0]);
}
