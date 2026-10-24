const std = @import("std");

pub const fps = 25;
pub const frame_ms = 1000 / fps;

pub const Color = struct {
    rgb: [3]f64,
    alpha: f64 = 1,
};

pub const TableColor = struct {
    rgb: [3]u8,
    transparency: u8,

    pub fn color(self: TableColor) Color {
        return .{
            .rgb = .{ @floatFromInt(self.rgb[0]), @floatFromInt(self.rgb[1]), @floatFromInt(self.rgb[2]) },
            .alpha = @as(f64, @floatFromInt(100 - self.transparency)) / 100,
        };
    }
};

pub const Stop = struct { position: f64, color: Color, percent: ?u32 = null };
pub const Kind = enum { static, breathing, spectrum, wave, wheel, starlight, fire, reactive, ripple };
pub const End = enum { never, after };
pub const Start = enum { random, onPress, onSelectedKeys };
pub const KeyEvent = struct { row: u8, col: u8, pressed: bool };

pub const Parameters = struct {
    kind: Kind,
    color: Color = .{ .rgb = .{ 0, 0, 0 } },
    color2: Color = .{ .rgb = .{ 0, 0, 0 } },
    stops: []const Stop = &.{},
    table: []const TableColor = &.{},
    duration: f64 = 1,
    speed: f64 = 15,
    width: f64 = 100,
    angle: f64 = 90,
    split: bool = false,
    pause: f64 = 0,
    random: bool = false,
    density: f64 = 1,
    cycles: u32 = 1,
    end: End = .never,
    start: Start = .random,
    center_x: ?f64 = null,
    center_y: ?f64 = null,
    counterclockwise: bool = false,
    traversal: usize = 0,
    projected_extent: usize = 0,
    direction_x: f32 = 0,
    direction_y: f32 = 0,
};

pub const Pixel = struct { offset: usize, x: f64, y: f64 };

pub const Region = struct {
    device: usize,
    pixels: []const Pixel,
    parameters: Parameters,
    seed: u32,
    state: ?*@import("state.zig").State = null,
};

pub const Device = struct { pid: u16, rows: u8, columns: u8 };

pub const Profile = struct {
    arena: std.heap.ArenaAllocator,
    skipped_ambient: bool = false,
    skipped_audio: bool = false,
    devices: []const Device,
    // Stored bottom to top, with group visibility already resolved.
    regions: []const Region,

    pub fn deinit(self: *Profile) void {
        for (self.regions) |region|
            if (region.state) |state|
                state.deinit();
        self.arena.deinit();
    }

    pub fn animated(self: Profile, device: usize) bool {
        for (self.regions) |region|
            if (region.device == device and region.parameters.kind != .static)
                return true;

        return false;
    }

    pub fn needsInput(self: Profile, device: usize) bool {
        for (self.regions) |region|
            if (region.device == device and (region.parameters.kind == .reactive or region.parameters.kind == .ripple))
                return true;
        return false;
    }
};
