pub const Zone = struct {
    id: u8,
    name: []const u8,
    brightness: bool = false,
    effects: []const Effect = &.{},
    frame: ?Frame = null,

    pub const Frame = struct {
        /// Zero-based pixel offset in the row-major frame, not a byte offset.
        start: u16 = 0,
        /// Null uses the whole-device frame command; a count uses this zone's ID.
        length: ?u16 = null,
    };
};

pub const Config = struct {
    /// 1 = the device keeps settings across power cycles, 0 = it forgets them.
    varstore: u8 = 1,
    zones: []const Zone = &.{},
    /// Only Static changes colour[0]; other effects acknowledge a colour and keep the old one.
    colour_via_static: bool = false,
    gamma: f32 = 2.8,
    protocol: ?enum { legacy_rows, extended_rows, large_matrix, audio37 } = null,
    layouts: []const Layout = &.{},
    control_interface: u8 = 0,
    frame_interface: ?u8 = null,
    report_id: u8 = 0,
    report: enum { standard, compact, compact_camy } = .standard,
    frame_latch: bool = false,
    latch_response: bool = true,

    pub fn validFrames(self: Config) bool {
        const protocol = self.protocol orelse return false;
        var affected: usize = 0;
        var addressed: usize = 0;
        for (self.zones, 0..) |zone, i| {
            if (zone.frame) |frame| {
                affected += 1;
                if (frame.length != null)
                    addressed += 1;
            }
            for (self.zones[0..i]) |previous|
                if (zone.id == previous.id)
                    return false;
        }
        if (self.layouts.len == 0 or affected == 0 or self.zones.len > 16)
            return false;
        if (protocol == .audio37 and affected != 1)
            return false;
        if (addressed > 0 and (protocol != .extended_rows or addressed != affected))
            return false;
        const max_columns: u8 = switch (protocol) {
            .legacy_rows => 25,
            .extended_rows => if (self.report == .standard) 25 else 16,
            .large_matrix => 120,
            .audio37 => 11,
        };
        for (self.layouts) |layout| {
            if (layout.rows == 0 or layout.columns == 0 or layout.columns > max_columns)
                return false;
            if ((protocol == .large_matrix or protocol == .audio37) and layout.rows != 1)
                return false;
            var covered: u16 = 0;
            for (self.zones, 0..) |zone, i| {
                const frame = zone.frame orelse continue;
                const length = frame.length orelse {
                    if (frame.start != 0)
                        return false;
                    continue;
                };
                // Addressed slices currently have a single-row wire representation.
                if (layout.rows != 1 or length == 0 or @as(u32, frame.start) + length > layout.columns)
                    return false;
                for (self.zones[0..i]) |previous| {
                    const other = previous.frame orelse continue;
                    const other_length = other.length orelse continue;
                    if (@as(u32, frame.start) < @as(u32, other.start) + other_length and
                        @as(u32, other.start) < @as(u32, frame.start) + length)
                        return false;
                }
                covered += length;
            }
            if (addressed > 0 and covered != layout.columns)
                return false;
        }
        return true;
    }

    pub fn fixedLayout(self: Config) ?Layout {
        if (self.layouts.len == 0)
            return null;
        const first = self.layouts[0];
        for (self.layouts[1..]) |layout|
            if (layout.rows != first.rows or layout.columns != first.columns)
                return null;
        return first;
    }

    pub fn selectLayout(self: Config, edition: u8, layout_id: u8) ?Layout {
        for (self.layouts) |layout|
            if (layout.edition == edition and layout.layout == layout_id)
                return layout;
        return null;
    }
};

pub const Layout = struct {
    edition: u8 = 0,
    layout: u8 = 0,
    rows: u8,
    columns: u8,

    pub fn frameSize(self: Layout) usize {
        return @as(usize, self.rows) * self.columns * 3;
    }
};

test "stream layouts distinguish firmware variants and reject oversized or overlapping frames" {
    const std = @import("std");
    const config: Config = .{
        .protocol = .legacy_rows,
        .zones = &.{.{ .id = 5, .name = "backlight", .frame = .{} }},
        .layouts = &.{
            .{ .layout = 1, .rows = 1, .columns = 16 },
            .{ .layout = 12, .rows = 6, .columns = 16 },
        },
        .control_interface = 2,
    };
    try std.testing.expect(config.validFrames());
    try std.testing.expect(config.fixedLayout() == null);
    try std.testing.expectEqual(@as(usize, 48), config.selectLayout(0, 1).?.frameSize());
    try std.testing.expectEqual(@as(usize, 288), config.selectLayout(0, 12).?.frameSize());
    try std.testing.expect(config.selectLayout(0, 99) == null);
    var invalid = config;
    invalid.layouts = &.{.{ .rows = 1, .columns = 26 }};
    try std.testing.expect(!invalid.validFrames());
    invalid = config;
    invalid.protocol = .extended_rows;
    invalid.layouts = &.{.{ .rows = 1, .columns = 12 }};
    invalid.zones = &.{
        .{ .id = 16, .name = "speaker-16", .frame = .{ .start = 0, .length = 6 } },
        .{ .id = 17, .name = "speaker-17", .frame = .{ .start = 5, .length = 6 } },
    };
    try std.testing.expect(!invalid.validFrames());
}

pub const Effect = struct {
    name: []const u8,
    id: u8,
    /// 0 = none, 1 = one colour, 2 = one or two.
    colours: u8 = 0,
    random: bool = false,
    speed: ?struct { min: u8, max: u8, default: u8 } = null,
    direction: bool = false,
};

pub const OFF = Effect{ .name = "off", .id = 0x00 };
pub const STATIC = Effect{ .name = "static", .id = 0x01, .colours = 1 };
pub const BREATHING = Effect{ .name = "breathing", .id = 0x02, .colours = 2, .random = true };
pub const SPECTRUM = Effect{ .name = "spectrum", .id = 0x03 };
pub const WAVE = Effect{
    .name = "wave",
    .id = 0x04,
    .direction = true,
    .speed = .{ .min = 40, .max = 40, .default = 40 },
};
pub const REACTIVE = Effect{
    .name = "reactive",
    .id = 0x05,
    .colours = 1,
    .speed = .{ .min = 1, .max = 4, .default = 2 },
};
pub const RIPPLE = Effect{
    .name = "ripple",
    .id = 0x06,
    .colours = 1,
    .speed = .{ .min = 40, .max = 40, .default = 40 },
};
pub const STARLIGHT = Effect{
    .name = "starlight",
    .id = 0x07,
    .colours = 2,
    .random = true,
    .speed = .{ .min = 1, .max = 3, .default = 2 },
};
pub const FIRE = Effect{ .name = "fire", .id = 0x09 };

pub const STATIC_MONO = Effect{ .name = "static", .id = 0x01 };
pub const BREATHING_MONO = Effect{ .name = "breathing", .id = 0x02 };

pub const MONO = [_]Effect{ OFF, STATIC_MONO, BREATHING_MONO };
pub const SINGLE = [_]Effect{ OFF, STATIC, BREATHING, SPECTRUM };
pub const SINGLE_REACTIVE = [_]Effect{ OFF, STATIC, BREATHING, SPECTRUM, REACTIVE };
pub const LINEAR_REACTIVE = [_]Effect{ OFF, STATIC, BREATHING, SPECTRUM, WAVE, REACTIVE };
pub const MULTI = [_]Effect{ OFF, STATIC, BREATHING, SPECTRUM, WAVE, STARLIGHT };
pub const MULTI_REACTIVE = [_]Effect{ OFF, STATIC, BREATHING, SPECTRUM, WAVE, REACTIVE, STARLIGHT };
pub const DENSE = [_]Effect{ OFF, STATIC, BREATHING, SPECTRUM, WAVE, STARLIGHT, FIRE };
pub const DENSE_REACTIVE = [_]Effect{ OFF, STATIC, BREATHING, SPECTRUM, WAVE, REACTIVE, STARLIGHT, FIRE };
pub const MATRIX_REACTIVE = [_]Effect{ OFF, STATIC, BREATHING, SPECTRUM, WAVE, REACTIVE, RIPPLE, STARLIGHT, FIRE };
