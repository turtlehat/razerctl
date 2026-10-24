const std = @import("std");
const profile = @import("profile.zig");
const effects = @import("effects.zig");
const Generator = @import("random.zig").Generator;
const Movie = @import("fire.zig").Movie;
const Reactions = @import("reactions.zig").Reactions;
const transparent: profile.TableColor = .{ .rgb = .{ 0, 0, 0 }, .transparency = 100 };

const Star = struct {
    table: []const profile.TableColor,
    phase: usize = 0,
    finished: bool = false,
    active: bool = true,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    parameters: profile.Parameters,
    device: profile.Device,
    seed: u32,
    rng: Generator,
    next_frame: u64 = 0,
    current: ?u64 = null,
    color: profile.Color = transparent.color(),
    breathing_table: []const profile.TableColor = &.{},
    stars: []?Star = &.{},
    output: []profile.TableColor = &.{},
    population: usize = 0,
    capacity: usize = 0,
    nominal: usize = 0,
    regen: usize = 1,
    movie: ?Movie = null,
    reactions: ?Reactions = null,

    pub fn required(p: profile.Parameters) bool {
        return p.kind == .reactive or p.kind == .ripple or p.kind == .starlight or p.kind == .fire or (p.kind == .breathing and p.random);
    }

    pub fn init(allocator: std.mem.Allocator, p: profile.Parameters, device: profile.Device, seed: u32) !State {
        var self: State = .{ .allocator = allocator, .parameters = p, .device = device, .seed = seed, .rng = .{ .state = seed } };
        errdefer self.deinit();
        switch (p.kind) {
            .reactive, .ripple => {
                const reactions = try Reactions.init(allocator, p, device, seed);
                self.reactions = reactions;
            },
            .fire => {
                const movie = try Movie.init(allocator, p.color, p.color2, seed);
                self.movie = movie;
            },
            .starlight => {
                const cells = @as(usize, device.rows) * device.columns;
                const max_star: f32 = @floatCast(@trunc(p.density / 10 * 100));
                self.capacity = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(cells)) * max_star / 100)));
                const stop_count = effectiveCount(if (p.random) &random_star_stops else p.stops);
                self.nominal = @max(stop_count, @as(usize, @intFromFloat(@round(p.duration * 1000))) / profile.frame_ms);
                self.regen = self.nominal / 8;
                if (self.regen == 0)
                    return error.InvalidChromaParameter;
                self.stars = try allocator.alloc(?Star, cells);
                @memset(self.stars, null);
                self.output = try allocator.alloc(profile.TableColor, cells);
                @memset(self.output, transparent);
            },
            .breathing => {},
            else => unreachable,
        }
        return self;
    }

    pub fn deinit(self: *State) void {
        self.clearStars();
        self.allocator.free(self.stars);
        self.allocator.free(self.output);
        self.allocator.free(self.breathing_table);
        if (self.movie) |*movie| movie.deinit();
        if (self.reactions) |*reactions| reactions.deinit();
    }

    fn clearStars(self: *State) void {
        for (self.stars) |*slot| {
            if (slot.*) |star| self.allocator.free(star.table);
            slot.* = null;
        }
        self.population = 0;
    }

    fn reset(self: *State) void {
        self.clearStars();
        self.allocator.free(self.breathing_table);
        self.breathing_table = &.{};
        self.rng.state = self.seed;
        self.next_frame = 0;
        self.current = null;
    }

    pub fn advance(self: *State, tick: u64) !void {
        if (self.reactions) |*reactions| {
            try reactions.advance(tick);
            self.current = tick;
            return;
        }
        if (self.current) |current| {
            if (tick == current) return;
            if (tick < current) self.reset();
        }
        if (self.movie != null) {
            self.current = tick;
            return;
        }
        while (self.next_frame <= tick) {
            switch (self.parameters.kind) {
                .breathing => try self.breathe(self.next_frame),
                .starlight => try self.twinkle(self.next_frame),
                else => unreachable,
            }
            self.current = self.next_frame;
            self.next_frame += 1;
        }
    }

    pub fn sample(self: *const State, pixel: profile.Pixel) profile.Color {
        if (self.reactions) |*reactions| return reactions.sample(pixel);
        if (self.movie) |movie| {
            const cell = pixel.offset / 3;
            return movie.sample(self.current.?, cell % self.device.columns, cell / self.device.columns, self.device.rows, self.device.columns).color();
        }
        return if (self.parameters.kind == .starlight) self.output[pixel.offset / 3].color() else self.color;
    }

    pub fn trigger(self: *State, event: profile.KeyEvent, tick: u64) !void {
        if (self.reactions) |*reactions| try reactions.trigger(event, tick);
    }

    fn breathe(self: *State, tick: u64) !void {
        const p = self.parameters;
        const index: usize = @intCast(tick % p.table.len);
        if (p.end == .after and tick / p.table.len >= p.cycles) {
            self.color = transparent.color();
            return;
        }
        const samples = if (self.breathing_table.len == 0) p.table else self.breathing_table;
        self.color = samples[index].color();
        if (index == 0) {
            var stops = effects.random_breathing_stops;
            const c = self.rng.color();
            stops[2].color = c;
            stops[3].color = c;
            const replacement = try effects.table(self.allocator, &stops, p.table.len);
            self.allocator.free(self.breathing_table);
            self.breathing_table = replacement;
        }
    }

    fn twinkle(self: *State, tick: u64) !void {
        @memset(self.output, transparent);
        for (self.stars, self.output) |*slot, *out| {
            if (slot.*) |*star| {
                if (!star.active) continue;
                if (star.finished) {
                    star.active = false;
                    continue;
                }
                out.* = star.table[star.phase];
                star.phase += 1;
                if (star.phase == star.table.len) {
                    star.phase = 0;
                    star.finished = true;
                }
            }
        }
        if (tick % self.regen == 0) {
            try self.spawn();
            for (self.stars) |*slot| {
                if (slot.*) |star| {
                    if (!star.active) {
                        self.allocator.free(star.table);
                        slot.* = null;
                        self.population -= 1;
                    }
                }
            }
        }
    }

    fn spawn(self: *State) !void {
        if (self.population >= self.capacity) return;
        const budget = self.rng.next() % (self.capacity - self.population + 1);
        for (0..budget) |_| {
            var cell = self.rng.next() % self.stars.len;
            if (self.stars[cell] != null) {
                cell = self.rng.next() % self.stars.len;
                if (self.stars[cell] != null) {
                    const discarded = self.rng.next() % self.stars.len;
                    if (self.stars[discarded] != null) _ = self.rng.next();
                    return;
                }
            }
            const source = if (self.parameters.random) &random_star_stops else self.parameters.stops;
            const length = @max(effectiveCount(source), 5 + self.rng.next() % self.nominal);
            const brightness: f32 = @as(f32, @floatFromInt(20 + self.rng.next() % 80)) / 100;
            const stops = try self.allocator.dupe(profile.Stop, source);
            defer self.allocator.free(stops);
            const c = if (self.parameters.random) self.rng.color() else null;
            for (stops) |*stop| {
                if (c) |color| {
                    if (stop.color.rgb[0] != 0 or stop.color.rgb[1] != 0 or stop.color.rgb[2] != 0)
                        stop.color = color;
                }
                for (&stop.color.rgb) |*channel|
                    channel.* = @trunc(@as(f32, @floatCast(channel.*)) * brightness);
            }
            const samples = try effects.table(self.allocator, stops, length);
            self.stars[cell] = .{ .table = samples };
            self.population += 1;
        }
    }
};

fn effectiveCount(stops: []const profile.Stop) usize {
    return stops.len + @as(usize, @intFromBool(stops[0].position > 0)) +
        @as(usize, @intFromBool(stops[stops.len - 1].position < 1));
}

const random_star_stops = [_]profile.Stop{
    .{ .position = 0, .color = .{ .rgb = .{ 0, 0, 0 } } },
    .{ .position = 0.5, .color = .{ .rgb = .{ 255, 0, 0 } } },
    .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 0 } } },
};

test "random breathing outputs before rebuilding a colored table with native rounding" {
    var p: profile.Parameters = .{ .kind = .breathing, .random = true, .duration = 2.56 };
    try effects.prepare(std.testing.allocator, &p, .{ .pid = 1, .rows = 1, .columns = 1 });
    defer std.testing.allocator.free(p.table);
    var state = try State.init(std.testing.allocator, p, .{ .pid = 1, .rows = 1, .columns = 1 }, 1);
    defer state.deinit();
    const pixel: profile.Pixel = .{ .offset = 0, .x = 0, .y = 0 };
    try state.advance(0);
    try std.testing.expectEqual([3]f64{ 0, 0, 0 }, state.sample(pixel).rgb);
    try std.testing.expectEqual(@as(u32, 1030492215), state.rng.state);
    try state.advance(12);
    try std.testing.expectEqual([3]f64{ 73, 0, 0 }, state.sample(pixel).rgb);
    const saved = state.sample(pixel);
    try state.advance(12);
    try std.testing.expectEqual(saved, state.sample(pixel));
    try state.advance(0);
    try state.advance(12);
    try std.testing.expectEqual(saved, state.sample(pixel));
}

test "Starlight spawns after empty first render with independent lifetimes and brightness" {
    const p: profile.Parameters = .{ .kind = .starlight, .duration = 1.7, .density = 10, .stops = &random_star_stops };
    var state = try State.init(std.testing.allocator, p, .{ .pid = 1, .rows = 2, .columns = 2 }, 2);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 42), state.nominal);
    try std.testing.expectEqual(@as(usize, 5), state.regen);
    try state.advance(0);
    for (state.output) |out| try std.testing.expectEqual(transparent, out);
    try std.testing.expectEqual(@as(usize, 2), state.population);
    try std.testing.expectEqual(@as(usize, 26), state.stars[0].?.table.len);
    try std.testing.expectEqual(@as(usize, 29), state.stars[1].?.table.len);
    try std.testing.expectEqual(@as(u8, 104), state.stars[0].?.table[12].rgb[0]);
    try std.testing.expectEqual(@as(u8, 84), state.stars[1].?.table[13].rgb[0]);
    try state.advance(1);
    try std.testing.expectEqual(@as(u8, 0), state.output[0].transparency);
    try std.testing.expectEqual(@as(usize, 1), state.stars[0].?.phase);
    try state.advance(2);
    try std.testing.expect(state.output[0].rgb[0] > 0);
}

test "Starlight discards a free third collision candidate and ends the spawn batch" {
    const p: profile.Parameters = .{ .kind = .starlight, .duration = 1.7, .density = 10, .stops = &random_star_stops };
    var state = try State.init(std.testing.allocator, p, .{ .pid = 1, .rows = 1, .columns = 4 }, 6);
    defer state.deinit();
    for (0..2) |cell| state.stars[cell] = .{ .table = try effects.table(std.testing.allocator, &random_star_stops, 10) };
    state.population = 2;
    try state.spawn();
    try std.testing.expectEqual(@as(usize, 2), state.population);
    try std.testing.expectEqual(@as(u32, 1031865002), state.rng.state);
    try std.testing.expect(state.stars[3] == null);
}

test "Starlight capacity includes inactive stars until spawn-before-cleanup completes" {
    const p: profile.Parameters = .{ .kind = .starlight, .duration = 1.7, .density = 1, .stops = &random_star_stops };
    var state = try State.init(std.testing.allocator, p, .{ .pid = 1, .rows = 1, .columns = 1 }, 2);
    defer state.deinit();
    state.stars[0] = .{ .table = try effects.table(std.testing.allocator, &random_star_stops, 2), .finished = true };
    state.population = 1;
    try state.advance(0);
    try std.testing.expectEqual(@as(usize, 0), state.population);
    try std.testing.expectEqual(@as(u32, 2), state.rng.state);
    try std.testing.expectEqual(transparent, state.output[0]);
    try state.advance(5);
    try std.testing.expectEqual(@as(usize, 0), state.population); // This seed draws a zero spawn budget.
    try std.testing.expect(state.rng.state != 2);
}

fn allocationCheck(allocator: std.mem.Allocator, kind: profile.Kind) !void {
    var p: profile.Parameters = .{ .kind = kind, .random = true, .duration = 1.7, .density = 10 };
    try effects.prepare(allocator, &p, .{ .pid = 1, .rows = 2, .columns = 2 });
    defer allocator.free(p.table);
    var state = try State.init(allocator, p, .{ .pid = 1, .rows = 2, .columns = 2 }, 2);
    defer state.deinit();
    try state.advance(100);
    try state.advance(0);
}

test "mutable effect allocations clean up on creation and frame failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCheck, .{profile.Kind.starlight});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCheck, .{profile.Kind.breathing});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCheck, .{profile.Kind.fire});
}
