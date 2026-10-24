const std = @import("std");
const profile = @import("profile.zig");
const effects = @import("effects.zig");

pub fn input(p: profile.Profile, device_index: usize, event: profile.KeyEvent, tick: u64) !void {
    if (device_index >= p.devices.len) return error.InvalidInputDevice;
    const device = p.devices[device_index];
    if (event.row >= device.rows or event.col >= device.columns) return error.InvalidInputCell;
    const offset = (@as(usize, event.row) * device.columns + event.col) * 3;
    for (p.regions) |region| {
        if (region.device != device_index) continue;
        if (region.parameters.kind != .reactive and region.parameters.kind != .ripple) continue;
        var selected = false;
        for (region.pixels) |pixel| {
            if (pixel.offset == offset) {
                selected = true;
                break;
            }
        }
        if (region.parameters.start == .onSelectedKeys and !selected) continue;
        // Reactive only has output at the originating selected cell.
        if (region.parameters.kind == .reactive and !selected) continue;
        try region.state.?.trigger(event, tick);
    }
}

pub fn frame(p: profile.Profile, device_index: usize, time: f64, rgb: []u8) !void {
    if (device_index >= p.devices.len or !std.math.isFinite(time) or time < 0)
        return error.InvalidFrame;
    const ticks = @floor(time * profile.fps);
    if (ticks >= @as(f64, @floatFromInt(std.math.maxInt(u64))))
        return error.InvalidFrame;
    return frameTick(p, device_index, @intFromFloat(ticks), rgb);
}

pub fn frameTick(p: profile.Profile, device_index: usize, tick: u64, rgb: []u8) !void {
    if (device_index >= p.devices.len) return error.InvalidFrame;
    const device = p.devices[device_index];

    if (rgb.len != @as(usize, device.rows) * device.columns * 3)
        return error.InvalidFrame;

    @memset(rgb, 0);

    for (p.regions) |region| {
        if (region.device != device_index)
            continue;

        if (region.state) |state| try state.advance(tick);
        for (region.pixels) |pixel| {
            const c = if (region.state) |state| state.sample(pixel) else effects.sampleTick(region.parameters, pixel, tick, device);

            for (rgb[pixel.offset..][0..3], c.rgb) |*channel, value| {
                const source: f32 = @floatCast(value);
                const destination: f32 = @floatFromInt(channel.*);
                const weight: f32 = @floatCast(c.alpha);
                const delta = @trunc((source - destination) * weight);

                channel.* = @intFromFloat(std.math.clamp(destination + delta, 0, 255));
            }
        }
    }
}

pub fn Player(comptime Clock: type) type {
    return struct {
        profile: *const profile.Profile,
        device: usize,
        clock: Clock,
        tick: u64 = 0,
        deadline: ?i96 = null,

        pub fn check(self: *@This()) !void {
            try self.clock.check();
        }

        pub fn next(self: *@This(), rgb: []u8) !bool {
            try self.check();

            if (self.deadline) |deadline| {
                if (!self.profile.animated(self.device)) {
                    while (true)
                        try self.clock.wait(self.clock.now() + std.time.ns_per_s);
                }

                try self.clock.wait(deadline);
            }

            const now = self.clock.now();

            if (comptime @hasDecl(Clock, "input"))
                try self.clock.input(self.profile, self.device, self.tick);
            try frameTick(self.profile.*, self.device, self.tick, rgb);
            self.tick += 1;
            self.deadline = now + std.time.ns_per_s / profile.fps;

            return true;
        }
    };
}
