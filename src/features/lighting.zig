//! LED zones and effects (0x0f02), the lid logo included.

const std = @import("std");
const device = @import("device_types");
const transport = @import("transport");
const ui = @import("ui");
const probe_result = @import("probe_result");
const setting_types = @import("setting_types");
const capability = @import("features/lighting_types");

pub const title = "Lighting";
pub const order = 5;

pub const Zone = capability.Zone;
pub const Config = capability.Config;
pub const Layout = capability.Layout;
pub const streaming = @import("lighting_stream.zig");
pub const Effect = capability.Effect;
pub const OFF = capability.OFF;
pub const STATIC = capability.STATIC;
pub const BREATHING = capability.BREATHING;
pub const SPECTRUM = capability.SPECTRUM;
pub const WAVE = capability.WAVE;
pub const REACTIVE = capability.REACTIVE;
pub const RIPPLE = capability.RIPPLE;
pub const STARLIGHT = capability.STARLIGHT;
pub const FIRE = capability.FIRE;
pub const STATIC_MONO = capability.STATIC_MONO;
pub const BREATHING_MONO = capability.BREATHING_MONO;
pub const MONO = capability.MONO;
pub const SINGLE = capability.SINGLE;
pub const SINGLE_REACTIVE = capability.SINGLE_REACTIVE;
pub const LINEAR_REACTIVE = capability.LINEAR_REACTIVE;
pub const MULTI = capability.MULTI;
pub const MULTI_REACTIVE = capability.MULTI_REACTIVE;
pub const DENSE = capability.DENSE;
pub const DENSE_REACTIVE = capability.DENSE_REACTIVE;
pub const MATRIX_REACTIVE = capability.MATRIX_REACTIVE;

pub fn effect(zone: Zone, name: []const u8) ?Effect {
    for (zone.effects) |e| {
        if (std.mem.eql(u8, e.name, name))
            return e;
    }

    return null;
}

const GAMMA_MIN: f32 = 1.0;
const GAMMA_MAX: f32 = 4.0;

/// The first zone takes the bare setting names; later zones are prefixed with their own name.
pub fn settings(desc: *const device.Descriptor, s: *setting_types.Settings) !void {
    const allocator = s.allocator;

    for (desc.features.lighting.zones, 0..) |z, i| {
        const first = i == 0;

        if (z.brightness)
            try s.add(.{
                .usage = .{
                    .name = if (first) "brightness" else try allocator.print("{s}-brightness", .{z.name}),
                    .params = &.{.{ .arg = .{ .range = .{ .min = 0, .max = 100 } } }},
                },
                .ctx = @intCast(i),
                .read = readBrightness,
                .write = writeBrightness,
                .unit = .percent,
            });

        if (z.effects.len == 0)
            continue;

        const subs = try allocator.alloc(ui.Command, z.effects.len);

        for (z.effects, subs) |e, *sub|
            sub.* = .{ .name = e.name, .params = try effectParams(allocator, e) };

        try s.add(.{
            .usage = if (takesColour(z)) .{
                .name = if (first) "effect" else z.name,
                .subs = subs,
                .note = try allocator.print("Default colour gamma: {d:.1}.", .{desc.features.lighting.gamma}),
            } else .{ .name = if (first) "effect" else z.name, .subs = subs },
            .ctx = @intCast(i),
            .read = readEffect,
            .write = writeEffect,
            .prepare = prepareEffect,
        });
    }
}

fn takesColour(zone: Zone) bool {
    for (zone.effects) |e| {
        if (e.colours > 0)
            return true;
    }

    return false;
}

/// Only offer speeds that can be represented by duration names.
fn effectParams(allocator: std.mem.Allocator, e: Effect) ![]const ui.Param {
    var list: std.ArrayList(ui.Param) = .empty;

    if (e.colours > 0)
        try list.append(allocator, .{ .arg = .{ .value = "colour" }, .candidates = &COLOUR_NAMES, .optional = true, .repeat = e.colours });

    if (e.speed) |sp|
        if (sp.min == 1 and sp.max <= DURATIONS.len)
            try list.append(allocator, .{ .arg = .{ .choices = DURATIONS[0..sp.max] }, .optional = true });

    if (e.direction)
        try list.append(allocator, .{ .arg = .{ .choices = &.{ "left", "right" } }, .optional = true });

    return list.items;
}

pub fn reference(allocator: std.mem.Allocator, shown: []const device.Descriptor) !?[]const u8 {
    if (!anyColour(shown))
        return null;

    var aw: std.Io.Writer.Allocating = .init(allocator);

    try aw.writer.writeAll("\nColours: '#rrggbb[,gamma]', 'r,g,b[,gamma]', or a name.\n");
    try aw.writer.writeAll("  Gamma: 1-4; omitted or named colours use the device default.\n  Names: ");

    for (NAMED, 0..) |c, k|
        try aw.writer.print("{s}{s}", .{ c.n, if (k + 1 == NAMED.len) "\n" else ", " });

    return aw.written();
}

fn anyColour(shown: []const device.Descriptor) bool {
    for (shown) |d| {
        for (d.features.lighting.zones) |z| {
            if (takesColour(z))
                return true;
        }
    }

    return false;
}

fn readBrightness(_: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, i: u8) !setting_types.Reading {
    const z = desc.features.lighting.zones[i];

    return .{ .val = .{ .num = device.levelToPct(try getBrightness(hid, desc, z.id)) } };
}

fn writeBrightness(_: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, i: u8, in: setting_types.Input) !void {
    const z = desc.features.lighting.zones[i];

    try setBrightness(hid, desc, z.id, device.pctToLevel(@intCast(in.num)));
}

fn readEffect(allocator: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, i: u8) !setting_types.Reading {
    const z = desc.features.lighting.zones[i];
    const b = try readBlock(hid, desc, z.id);

    return .{ .val = .{ .str = try describe(allocator, z, desc.features.lighting.gamma, &b) } };
}

/// `<effect> [colour...] [duration] [direction]`, in any order after the name.
fn writeEffect(_: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, i: u8, in: setting_types.Input) !void {
    try apply(hid, desc, desc.features.lighting.zones[i].id, in.payload[0], in.payload[1..]);
}

fn prepareEffect(allocator: std.mem.Allocator, desc: *const device.Descriptor, i: u8, in: setting_types.Input) !ui.Result(setting_types.Input) {
    var colours: [2]Rgb = undefined;
    const parsed = switch (try parseEffect(allocator, desc, i, in, &colours)) {
        .success => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };
    var buffer: [13]u8 = undefined;
    const payload = effectPayload(desc.features.lighting.gamma, parsed.effect, parsed.options, &buffer);

    return .{ .success = .{ .payload = try allocator.dupe(u8, payload) } };
}

const ParsedEffect = struct { effect: Effect, options: Options };

fn parseEffect(allocator: std.mem.Allocator, desc: *const device.Descriptor, i: u8, in: setting_types.Input, colours: *[2]Rgb) !ui.Result(ParsedEffect) {
    const zone = desc.features.lighting.zones[i];
    const args = in.args;
    const cmd = if (i == 0) "effect" else zone.name;

    if (args.len == 0)
        return .{ .failure = .{ .message = try allocator.print("{s}: an effect name is required", .{cmd}) } };

    const e = effect(zone, args[0]) orelse
        return .{ .failure = .{ .message = try allocator.print("{s}: expected <{s}> -- got '{s}'", .{ cmd, try std.mem.join(allocator, "|", try ui.names(allocator, zone.effects)), args[0] }) } };

    var o = Options{};
    var ncol: usize = 0;
    var k: usize = 1;

    while (k < args.len) : (k += 1) {
        const a = args[k];

        if (e.direction and (std.mem.eql(u8, a, "left") or std.mem.eql(u8, a, "right"))) {
            o.rightward = std.mem.eql(u8, a, "right");
        } else if (durationWord(e, a)) |sp| {
            o.speed = sp;
        } else {
            const colour = if (e.colours > ncol) parseColour(a) else null;

            if (colour) |c| {
                colours[ncol] = c.rgb;
                o.colours_gamma[ncol] = c.gamma;
                ncol += 1;
            } else {
                return .{ .failure = .{ .message = try allocator.print("{s}: expected {s} -- got '{s}'", .{ cmd, try ui.usage(allocator, .{ .name = e.name, .params = try effectParams(allocator, e) }), a }) } };
            }
        }
    }

    // No colour given: the EC's own random mode where the effect has one,
    // otherwise white.
    if (ncol == 0 and e.colours > 0) {
        if (e.random) {
            o.random = true;
        } else {
            colours[0] = .{ .r = 255, .g = 255, .b = 255 };
            o.colours_gamma[0] = null;
            ncol = 1;
        }
    }

    o.colours = colours[0..ncol];

    return .{ .success = .{ .effect = e, .options = o } };
}

fn byId(zone: Zone, id: u8) ?Effect {
    for (zone.effects) |e| {
        if (e.id == id)
            return e;
    }

    return null;
}

fn describe(allocator: std.mem.Allocator, zone: Zone, gamma: f32, a: []const u8) ![]const u8 {
    const e = byId(zone, a[2]) orelse return try ui.nameOr(allocator, null, a[2]);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    const w = &aw.writer;

    try w.writeAll(e.name);

    // Colour mode 3 is the EC's own random. [3] carries a direction instead on
    // effects that have one, where 3 is not a value it can take.
    if (e.random and !e.direction and a[3] == 3)
        try w.writeAll(" random");

    // Clamped: the EC keeps a stale count for effects that take no colours.
    var i: usize = 0;

    while (i < @min(a[5], e.colours)) : (i += 1) {
        const o = 6 + i * 3;
        const c = decode(.{ .r = a[o], .g = a[o + 1], .b = a[o + 2] }, gamma);

        try w.print(" #{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b });
    }

    if (e.direction)
        try w.print(" {s}", .{if (a[3] == 1) "right" else "left"});

    // Only where the value is a choice: Wave and Ripple have exactly one
    // correct speed, so printing it says nothing.
    if (e.speed) |r|
        if (r.min != r.max) {
            if (r.min == 1) {
                try w.print(" {s}", .{durationName(a[4])});
            } else {
                try w.print(" speed {d}", .{a[4]});
            }
        };

    return aw.written();
}

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Colour = struct {
    rgb: Rgb,
    gamma: ?f32 = null,
};

/// sRGB to wire. At the exponents LEDs want, everything below about 50 lands
/// on 0, so dark colours do not survive the round trip through `decode`.
pub fn encode(c: Rgb, gamma: f32) Rgb {
    return .{ .r = curve(c.r, gamma), .g = curve(c.g, gamma), .b = curve(c.b, gamma) };
}

pub fn decode(c: Rgb, gamma: f32) Rgb {
    return .{ .r = curve(c.r, 1.0 / gamma), .g = curve(c.g, 1.0 / gamma), .b = curve(c.b, 1.0 / gamma) };
}

fn curve(v: u8, exp: f32) u8 {
    const x = @as(f32, @floatFromInt(v)) / 255.0;

    return @intFromFloat(@round(std.math.pow(f32, x, exp) * 255.0));
}

test "gamma" {
    const e = std.testing.expectEqual;

    try e(@as(u8, 0x62), encode(.{ .r = 0xc2, .g = 0x94, .b = 0x94 }, 3.5).r);
    try e(@as(u8, 0x26), encode(.{ .r = 0xc2, .g = 0x94, .b = 0x94 }, 3.5).g);
    try e(@as(u8, 200), encode(.{ .r = 200, .g = 0, .b = 0 }, 1.0).r);
    const back = decode(encode(.{ .r = 0xc2, .g = 0x94, .b = 0x94 }, 3.5), 3.5);

    try e(@as(u8, 0xc2), back.r);
    try e(@as(u8, 0x94), back.g);
}

pub const NAMED = [_]struct { n: []const u8, c: Rgb }{
    .{ .n = "red", .c = .{ .r = 255, .g = 0, .b = 0 } },
    .{ .n = "green", .c = .{ .r = 0, .g = 255, .b = 0 } },
    .{ .n = "blue", .c = .{ .r = 0, .g = 0, .b = 255 } },
    .{ .n = "cyan", .c = .{ .r = 0, .g = 255, .b = 255 } },
    .{ .n = "magenta", .c = .{ .r = 255, .g = 0, .b = 255 } },
    .{ .n = "yellow", .c = .{ .r = 255, .g = 255, .b = 0 } },
    .{ .n = "orange", .c = .{ .r = 255, .g = 165, .b = 0 } },
    .{ .n = "purple", .c = .{ .r = 128, .g = 0, .b = 128 } },
    .{ .n = "pink", .c = .{ .r = 255, .g = 192, .b = 203 } },
    .{ .n = "white", .c = .{ .r = 255, .g = 255, .b = 255 } },
};

const COLOUR_NAMES = blk: {
    var names: [NAMED.len][]const u8 = undefined;

    for (NAMED, &names) |colour, *name|
        name.* = colour.n;

    break :blk names;
};

pub fn parseColour(s: []const u8) ?Colour {
    if (std.mem.lastIndexOfScalar(u8, s, ',')) |comma| {
        const prefix = s[0..comma];

        if (parseGamma(s[comma + 1 ..])) |gamma| {
            if (parseNumericRgb(prefix)) |rgb|
                return .{ .rgb = rgb, .gamma = gamma };
        }
    }

    const rgb = parseRgb(s) orelse return null;

    return .{ .rgb = rgb };
}

fn parseRgb(s: []const u8) ?Rgb {
    for (NAMED) |e| {
        if (std.mem.eql(u8, e.n, s))
            return e.c;
    }

    return parseNumericRgb(s);
}

fn parseNumericRgb(s: []const u8) ?Rgb {
    if (std.mem.indexOfScalar(u8, s, ',') != null) {
        var it = std.mem.splitScalar(u8, s, ',');
        var v: [3]u8 = undefined;
        var i: usize = 0;

        while (it.next()) |part| : (i += 1) {
            if (i >= 3)
                return null;

            v[i] = std.fmt.parseInt(u8, std.mem.trim(u8, part, " "), 10) catch return null;
        }

        if (i != 3)
            return null;

        return .{ .r = v[0], .g = v[1], .b = v[2] };
    }

    const h = if (s.len > 0 and s[0] == '#') s[1..] else s;

    if (h.len != 6)
        return null;

    return .{
        .r = std.fmt.parseInt(u8, h[0..2], 16) catch return null,
        .g = std.fmt.parseInt(u8, h[2..4], 16) catch return null,
        .b = std.fmt.parseInt(u8, h[4..6], 16) catch return null,
    };
}

test "colour formats" {
    const e = std.testing.expectEqual;

    try e(@as(u8, 255), parseColour("#ff0053").?.rgb.r);
    try e(@as(u8, 83), parseColour("ff0053").?.rgb.b);
    try e(@as(u8, 83), parseColour("255,0,83").?.rgb.b);
    try e(@as(u8, 255), parseColour("red").?.rgb.r);
    try e(@as(?Colour, null), parseColour("nope"));
    try e(@as(u8, 255), parseColour("#ff00ff,2.4").?.rgb.r);
    try e(@as(f32, 2.4), parseColour("#ff00ff,2.4").?.gamma.?);
    try e(@as(u8, 255), parseColour("255,0,255,2.4").?.rgb.r);
    try e(@as(f32, 2.4), parseColour("255,0,255,2.4").?.gamma.?);
    try e(@as(?f32, null), parseColour("red").?.gamma);
    try e(@as(?Colour, null), parseColour("red,2.4"));
    try e(@as(?Colour, null), parseColour("#ff00ff,4.1"));
}

fn parseGamma(text: []const u8) ?f32 {
    const gamma = std.fmt.parseFloat(f32, text) catch return null;

    if (!std.math.isFinite(gamma) or gamma < GAMMA_MIN or gamma > GAMMA_MAX)
        return null;

    return gamma;
}

/// Speed words for effects with a small range; they must cover every range in the device table.
pub const DURATIONS = [_][]const u8{ "short", "medium", "long", "longest" };

pub fn durationWord(e: Effect, a: []const u8) ?u8 {
    const sp = e.speed orelse return null;

    if (sp.min != 1 or sp.max > DURATIONS.len)
        return null;

    for (DURATIONS[0..sp.max], 1..) |w, i| {
        if (std.mem.eql(u8, w, a))
            return @intCast(i);
    }

    return null;
}

pub fn durationName(sp: u8) []const u8 {
    return if (sp >= 1 and sp <= DURATIONS.len) DURATIONS[sp - 1] else "?";
}

test "duration words" {
    const e = std.testing.expectEqual;

    try e(@as(?u8, 3), durationWord(STARLIGHT, "long"));
    try e(@as(?u8, null), durationWord(STARLIGHT, "longest"));
    try e(@as(?u8, 4), durationWord(REACTIVE, "longest"));
    try e(@as(?u8, null), durationWord(WAVE, "short"));
    try std.testing.expectEqualStrings("medium", durationName(2));
}

pub const SET_CHROMA_EFFECT: transport.Command = .{ .id = 0x0f02 };
const GET_CHROMA_EFFECT: transport.Command = .{ .id = 0x0f82, .min_response = 12 };
/// [store, zone, level], linear 0-255. The classic 0x0303/0x0383 pair reaches
/// the same register on the laptop, but the pad refuses it.
const SET_BRIGHTNESS: transport.Command = .{ .id = 0x0f04 };
const GET_BRIGHTNESS: transport.Command = .{ .id = 0x0f84, .min_response = 3 };
/// Get LED ID List. Only the ids are decoded.
const GET_LED_IDS: transport.Command = .{ .id = 0x0389, .min_response = 1 };
/// Not decoded; probe reports it raw.
const GET_EFFECT_IDS: transport.Command = .{ .id = 0x0f18 };

pub const Options = struct {
    colours: []const Rgb = &.{},
    colours_gamma: [2]?f32 = @splat(null),
    random: bool = false,
    speed: ?u8 = null,
    /// true = left-to-right (wire 1), false = right-to-left (wire 2)
    rightward: bool = true,
};

/// Builds `[effect, colour_mode, speed, count, RGB...]`.
/// colour_mode is 1, 2 or 3 for one, two or random colours; Wave's [3] is a direction instead.
fn effectPayload(gamma_default: f32, e: Effect, opts: Options, buffer: *[13]u8) []const u8 {
    buffer[0] = e.id;
    const buf = buffer[1..];

    if (e.direction) {
        const sp = opts.speed orelse (if (e.speed) |s| s.default else 40);

        buf[0] = if (opts.rightward) 1 else 2;
        buf[1] = sp;
        return buffer[0..3];
    }

    if (e.colours == 0 and e.speed == null)
        return buffer[0..1];

    const sp = opts.speed orelse (if (e.speed) |s| s.default else 0);
    var n: usize = 0;

    if (opts.random) {
        buf[0] = 3;
        buf[1] = sp;
        buf[2] = 0;
        n = 3;
    } else {
        const count: u8 = @intCast(opts.colours.len);

        buf[0] = count;
        buf[1] = sp;
        buf[2] = count;
        n = 3;

        for (opts.colours[0..count], 0..) |raw, i| {
            const gamma = opts.colours_gamma[i] orelse gamma_default;
            const c = encode(raw, gamma);

            buf[n] = c.r;
            buf[n + 1] = c.g;
            buf[n + 2] = c.b;
            n += 3;
        }
    }
    return buffer[0 .. 1 + n];
}

fn apply(hid: *transport.Device, desc: *const device.Descriptor, zone_id: u8, id: u8, args: []const u8) !void {
    var buf: [16]u8 = undefined;

    buf[0] = desc.features.lighting.varstore;
    buf[1] = zone_id;
    buf[2] = id;
    @memcpy(buf[3 .. 3 + args.len], args);

    // Firmware can ignore colour changes while the same effect is active.
    // Switch Off first so the requested effect is applied afresh.
    _ = try hid.call(SET_CHROMA_EFFECT, &.{ desc.features.lighting.varstore, zone_id, OFF.id });
    _ = try placeColour(hid, desc, zone_id, id, args);
    _ = try hid.call(SET_CHROMA_EFFECT, buf[0 .. 3 + args.len]);
}

/// Write colour[0] through Static on devices where nothing else moves it.
/// Returns true if it fired, which also means the current effect is now Static.
fn placeColour(hid: *transport.Device, desc: *const device.Descriptor, zone_id: u8, id: u8, args: []const u8) !bool {
    const lighting = desc.features.lighting;

    if (!lighting.colour_via_static or id == STATIC.id or args.len < 6)
        return false;

    _ = try hid.call(SET_CHROMA_EFFECT, &.{ lighting.varstore, zone_id, STATIC.id, 1, 0, 1, args[3], args[4], args[5] });
    try hid.sleepMs(150);
    return true;
}

/// The whole effect block. Requests all twelve bytes: the reply echoes the requested size.
pub fn readBlock(hid: *transport.Device, desc: *const device.Descriptor, zone_id: u8) transport.Error![12]u8 {
    var req: [12]u8 = @splat(0);

    req[0] = desc.features.lighting.varstore;
    req[1] = zone_id;
    const r = try hid.call(GET_CHROMA_EFFECT, &req);
    return r.argSlice()[0..12].*;
}

/// Writes a `readBlock` result back; the effect id alone would return without its colours.
pub fn restore(hid: *transport.Device, desc: *const device.Descriptor, zone_id: u8, block: [12]u8) !void {
    const count = @min(block[5], 2);

    try apply(hid, desc, zone_id, block[2], block[3 .. 6 + @as(usize, count) * 3]);
}

fn getBrightness(hid: *transport.Device, desc: *const device.Descriptor, zone_id: u8) !u8 {
    const r = try hid.call(GET_BRIGHTNESS, &.{ desc.features.lighting.varstore, zone_id, 0 });
    const a = r.argSlice();

    if (a[1] != zone_id)
        return transport.Error.BadResponse;

    return a[2];
}

fn setBrightness(hid: *transport.Device, desc: *const device.Descriptor, zone_id: u8, level: u8) !void {
    _ = try hid.call(SET_BRIGHTNESS, &.{ desc.features.lighting.varstore, zone_id, level });
}

/// `kind` is not decoded.
pub const Led = struct { id: u8, kind: u8 };

/// `[count]` then `count` `(id, kind)` pairs; reading kind bytes as ids would invent LEDs.
pub fn getLedIds(hid: *transport.Device, buf: []Led) ![]const Led {
    const r = try readLedList(hid);
    const a = r.argSlice();
    const n = @min(a[0], buf.len);

    for (buf[0..n], 0..) |*z, i|
        z.* = .{ .id = a[1 + i * 2], .kind = a[2 + i * 2] };

    return buf[0..n];
}

fn validateLedList(a: []const u8) !void {
    if (a.len == 0 or @as(usize, a[0]) * 2 + 1 > a.len)
        return transport.Error.BadResponse;
}

fn readLedList(hid: *transport.Device) !transport.Packet {
    const r = try hid.call(GET_LED_IDS, &@as([80]u8, @splat(0)));

    try validateLedList(r.argSlice());
    return r;
}

fn probeZone(hid: *transport.Device) !u8 {
    var buf: [1]Led = undefined;
    const leds = try getLedIds(hid, &buf);

    if (leds.len == 0)
        return error.NoLedZone;

    return leds[0].id;
}

pub fn probe(hid: *transport.Device, p: *probe_result.ProbeResult) !void {
    const list = readLedList(hid);
    const store: u8 = (Config{}).varstore;

    try p.reply(GET_LED_IDS, "led id list", list, 16);
    try p.reply(GET_EFFECT_IDS, "effect id list", hid.call(GET_EFFECT_IDS, &.{0}), 2);

    const packet = list catch |err| {
        try p.failure(GET_BRIGHTNESS, "led brightness: LED discovery failed", err);
        try p.failure(GET_CHROMA_EFFECT, "chroma effect: LED discovery failed", err);
        return;
    };
    const a = packet.argSlice();

    if (a[0] == 0) {
        try p.failure(GET_BRIGHTNESS, "led brightness", error.NoLedZone);
        try p.failure(GET_CHROMA_EFFECT, "chroma effect", error.NoLedZone);
        return;
    }

    const zone = a[1];

    try p.reply(GET_BRIGHTNESS, "led brightness", hid.call(GET_BRIGHTNESS, &.{ store, zone, 0 }), 3);
    var req: [12]u8 = @splat(0);

    req[0] = store;
    req[1] = zone;
    try p.reply(GET_CHROMA_EFFECT, "chroma effect", hid.call(GET_CHROMA_EFFECT, &req), 12);
}

/// Tries every known effect id, then puts the lighting back as it was.
pub fn probeWrites(hid: *transport.Device, desc: *const device.Descriptor, p: *probe_result.ProbeResult) !?ui.Failure {
    const allocator = p.table.allocator;
    const zone = probeZone(hid) catch |err|
        return .{ .message = "probe --effects: cannot discover an LED zone; no effects were tested", .err = err };
    const before = readBlock(hid, desc, zone) catch |err|
        return .{ .message = "probe --effects: cannot read current lighting; no effects were tested", .err = err };

    for (MATRIX_REACTIVE) |e| {
        const name = try allocator.print("backlight {s}", .{e.name});

        var buf: [16]u8 = @splat(0);

        buf[0] = desc.features.lighting.varstore;
        buf[1] = zone;
        buf[2] = e.id;

        if (hid.call(SET_CHROMA_EFFECT, &buf)) |_| {
            try p.add(SET_CHROMA_EFFECT, name, try probe_result.hex(allocator, &.{e.id}));
        } else |err| {
            try p.failure(SET_CHROMA_EFFECT, name, err);
        }
    }

    restore(hid, desc, zone, before) catch |err|
        return .{
            .message = "probe --effects: effects were tested, but previous lighting could not be restored",
            .err = err,
        };
    return null;
}

test "LED list counts must fit the declared payload including every kind byte" {
    try std.testing.expectError(error.BadResponse, validateLedList(&.{}));
    try std.testing.expectError(error.BadResponse, validateLedList(&.{1}));
    try std.testing.expectError(error.BadResponse, validateLedList(&.{ 1, 5 }));
    try std.testing.expectError(error.BadResponse, validateLedList(&.{ 2, 5, 1, 4 }));
    try std.testing.expectError(error.BadResponse, validateLedList(&.{255}));
    try validateLedList(&.{0});
    try validateLedList(&.{ 1, 5, 1 });
    try validateLedList(&.{ 2, 5, 1, 4, 2 });
    try validateLedList(&.{ 1, 5, 1, 0, 0 });
}

test "effect preparation owns encoded payloads before a writer runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var desc: device.Descriptor = .{ .pid = 0, .name = "Test", .category = .system };

    desc.features.lighting = .{
        .gamma = 1,
        .zones = &.{
            .{ .id = 5, .name = "backlight", .effects = &MATRIX_REACTIVE },
            .{ .id = 4, .name = "logo", .effects = &MONO },
        },
    };
    var list: setting_types.Settings = .init(allocator);

    try settings(&desc, &list);
    const effect_setting = list.items.items[0];
    const cases = [_]struct { args: []const [:0]const u8, expected: []const u8 }{
        .{ .args = &.{"off"}, .expected = &.{0} },
        .{ .args = &.{"static"}, .expected = &.{ 1, 1, 0, 1, 255, 255, 255 } },
        .{ .args = &.{ "static", "red" }, .expected = &.{ 1, 1, 0, 1, 255, 0, 0 } },
        .{ .args = &.{ "breathing", "red", "blue" }, .expected = &.{ 2, 2, 0, 2, 255, 0, 0, 0, 0, 255 } },
        .{ .args = &.{"breathing"}, .expected = &.{ 2, 3, 0, 0 } },
        .{ .args = &.{ "wave", "right" }, .expected = &.{ 4, 1, 40 } },
        .{ .args = &.{ "wave", "left" }, .expected = &.{ 4, 2, 40 } },
        .{ .args = &.{ "reactive", "blue", "longest" }, .expected = &.{ 5, 1, 4, 1, 0, 0, 255 } },
        .{ .args = &.{ "starlight", "short" }, .expected = &.{ 7, 3, 1, 0 } },
    };

    for (cases) |case| {
        const prepared = try effect_setting.parse(allocator, &desc, case.args);

        try std.testing.expectEqualSlices(u8, case.expected, prepared.success.payload);
    }

    const mono = try list.items.items[1].parse(allocator, &desc, &.{"static"});

    try std.testing.expectEqualSlices(u8, &.{1}, mono.success.payload);
    const gamma = try effect_setting.parse(allocator, &desc, &.{ "static", "#c89494,3.5" });
    const encoded = encode(.{ .r = 200, .g = 148, .b = 148 }, 3.5);

    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 0, 1, encoded.r, encoded.g, encoded.b }, gamma.success.payload);
    const colour = try allocator.dupeSentinel(u8, "red", 0);
    const owned = try effect_setting.parse(allocator, &desc, &.{ "static", colour });

    @memcpy(colour, "bad");
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 0, 1, 255, 0, 0 }, owned.success.payload);
    try std.testing.expect((try effect_setting.parse(allocator, &desc, &.{ "static", "bad" })) == .failure);
}
