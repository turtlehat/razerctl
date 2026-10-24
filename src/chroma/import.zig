const std = @import("std");
const runtime = @import("profile.zig");
const effects = @import("effects.zig");
const Value = std.json.Value;
const Led = struct { row: u16, col: u16 };
const Device = struct {
    id: []const u8,
    vendorId: u16,
    productId: u16,
    x: f64 = 0,
    y: f64 = 0,
    orientation: u16 = 0,
    config: struct { MatrixMaxRow: u16, MatrixMaxCol: u16 },
    leds: []const Led,
};
const Selection = struct { id: []const u8, productId: u16, leds: []const Led };
const Region = struct { params: Value, devices: []const Selection };
const Layer = struct {
    type: []const u8,
    name: ?[]const u8 = null,
    visible: bool,
    params: Value = .null,
    regions: []const Region = &.{},
    layers: []const Layer = &.{},
};
const Document = struct {
    version: u32,
    profiles: []Value,
};
const Source = struct { devices: []const Device, layers: []const Layer };

fn number(object: Value, key: []const u8, default: f64, min: f64, max: f64) !f64 {
    const value = object.object.get(key) orelse return default;
    const n: f64 = switch (value) {
        .integer => @floatFromInt(value.integer),
        .float => value.float,
        else => return error.InvalidChromaParameter,
    };

    if (!std.math.isFinite(n) or n < min or n > max)
        return error.InvalidChromaParameter;

    return n;
}

fn boolean(object: Value, key: []const u8, default: bool) !bool {
    const value = object.object.get(key) orelse return default;

    if (value != .bool)
        return error.InvalidChromaParameter;

    return value.bool;
}

fn color(value: Value) !runtime.Color {
    if (value != .integer or value.integer < 0 or value.integer > 0xffffff)
        return error.InvalidChromaColour;

    const n: u32 = @intCast(value.integer);

    return .{ .rgb = .{
        @floatFromInt(n >> 16),
        @floatFromInt((n >> 8) & 255),
        @floatFromInt(n & 255),
    } };
}

fn getColor(object: Value, key: []const u8, default: ?runtime.Color) !runtime.Color {
    return if (object.object.get(key)) |value|
        color(value)
    else
        default orelse error.InvalidChromaColour;
}

fn allowed(kind: runtime.Kind, key: []const u8) bool {
    const keys: []const []const u8 = switch (kind) {
        .static => &.{"color"},
        .breathing => &.{ "color", "color2", "colorStops", "colorStopsCustom", "randomColor", "duration", "playbackStart", "playbackEnd", "cycles" },
        .reactive => &.{ "color", "randomColor", "duration", "playbackStart", "playbackEnd", "cycles" },
        .ripple => &.{ "width", "speed", "colorStops", "colorStopsCustom", "playbackStart", "playbackEnd", "cycles" },
        .spectrum => &.{ "colorStops", "colorStopsCustom", "duration" },
        .wave => &.{ "width", "speed", "colorStops", "colorStopsCustom", "split", "pause", "angle", "playbackStart", "playbackEnd", "cycles" },
        .wheel => &.{ "speed", "colorStops", "colorStopsCustom", "playbackStart", "playbackEnd", "cycles" },
        .starlight => &.{ "colorStops", "colorStopsCustom", "randomColor", "density", "duration" },
        .fire => &.{ "color", "color2" },
    };

    for (keys) |candidate|
        if (std.mem.eql(u8, key, candidate))
            return true;

    return false;
}

fn parameters(allocator: std.mem.Allocator, name: []const u8, object: Value, global: Value) !runtime.Parameters {
    const kind = std.meta.stringToEnum(runtime.Kind, name) orelse return error.UnsupportedChromaEffect;

    if (object != .object)
        return error.InvalidChromaParameter;

    var fields = object.object.iterator();

    while (fields.next()) |field|
        if (!allowed(kind, field.key_ptr.*))
            return error.UnsupportedChromaParameters;

    if (global != .null) {
        if (global != .object)
            return error.InvalidChromaParameter;

        var globals = global.object.iterator();

        while (globals.next()) |field| {
            const key = field.key_ptr.*;

            if (kind != .wheel or
                !(std.mem.eql(u8, key, "centerPointX") or std.mem.eql(u8, key, "centerPointY") or
                    std.mem.eql(u8, key, "centerPointX2") or std.mem.eql(u8, key, "centerPointY2") or
                    std.mem.eql(u8, key, "counterclockwise") or std.mem.eql(u8, key, "isActive")))
                return error.UnsupportedChromaParameters;
        }
    }

    var p: runtime.Parameters = .{ .kind = kind };
    p.random = try boolean(object, "randomColor", false);

    if (kind == .static or kind == .breathing or kind == .fire or kind == .reactive) {
        p.color = try getColor(object, "color", if (p.random or object.object.contains("colorStops")) .{ .rgb = .{ 255, 0, 0 } } else null);

        if (kind != .static)
            p.color2 = try getColor(object, "color2", .{ .rgb = .{ 0, 0, 0 }, .alpha = if (kind == .breathing) 0 else 1 });
    }

    if (object.object.get("colorStops")) |stops| {
        if (stops != .array or stops.array.items.len == 0)
            return error.InvalidChromaGradient;

        const decoded = try allocator.alloc(runtime.Stop, stops.array.items.len);

        for (stops.array.items, decoded, 0..) |stop, *target, i| {
            if (stop != .object or stop.object.count() > 2 or !stop.object.contains("Stop"))
                return error.InvalidChromaGradient;

            var stop_fields = stop.object.iterator();

            while (stop_fields.next()) |field|
                if (!std.mem.eql(u8, field.key_ptr.*, "Stop") and !std.mem.eql(u8, field.key_ptr.*, "Color"))
                    return error.InvalidChromaGradient;

            const position = try number(stop, "Stop", 0, 0, 100);
            target.* = .{
                .position = position / 100,
                .percent = @intFromFloat(position),
                .color = try getColor(stop, "Color", .{ .rgb = .{ 0, 0, 0 }, .alpha = 0 }),
            };

            if (i > 0 and target.position <= decoded[i - 1].position)
                return error.InvalidChromaGradient;
        }

        p.stops = decoded;
    } else if (kind == .wave or kind == .wheel or kind == .spectrum or (kind == .ripple and !p.random) or (kind == .starlight and !p.random)) {
        return error.InvalidChromaGradient;
    }

    _ = try boolean(object, "colorStopsCustom", true);
    p.duration = @trunc(try number(object, "duration", switch (kind) {
        .breathing => 14000,
        .spectrum => 37740,
        .starlight => 1700,
        .reactive => 1500,
        else => 1000,
    }, 1, 86400000)) / 1000;
    p.speed = @trunc(try number(object, "speed", if (kind == .wheel) 60 else if (kind == .ripple) 10 else 15, if (kind == .ripple) 1 else 0, if (kind == .wheel) 360 else 50));
    p.width = @trunc(try number(object, "width", if (kind == .ripple) 300 else 100, if (kind == .ripple) 100 else 10, 400));
    p.angle = @trunc(try number(object, "angle", 90, 0, 359));
    p.split = try boolean(object, "split", false);
    p.pause = @trunc(try number(object, "pause", 0, 0, 60000)) / 1000;
    p.density = try number(object, "density", 1, 1, 10);

    if (object.object.get("playbackStart")) |start| {
        if (start != .string)
            return error.InvalidChromaParameter;

        p.start = std.meta.stringToEnum(runtime.Start, start.string) orelse return error.UnsupportedChromaTrigger;
    }
    const triggered = kind == .reactive or kind == .ripple;
    if (triggered) {
        if (p.start == .random) {
            if (object.object.contains("playbackStart")) return error.UnsupportedChromaTrigger;
            p.start = .onPress;
        }
        p.end = .after;
    } else if (p.start != .random) return error.UnsupportedChromaTrigger;

    if (object.object.get("playbackEnd")) |end| {
        if (end != .string)
            return error.InvalidChromaParameter;

        p.end = std.meta.stringToEnum(runtime.End, end.string) orelse return error.UnsupportedChromaTrigger;
    }

    const cycles = try number(object, "cycles", if (p.end == .never) -1 else 1, -1, 1000000);

    if (@floor(cycles) != cycles or (p.end == .after and cycles < 1) or cycles == 0)
        return error.InvalidChromaParameter;

    p.cycles = if (cycles < 0) 1 else @intFromFloat(cycles);

    if (global == .object and kind == .wheel) {
        if (global.object.contains("centerPointX"))
            p.center_x = try number(global, "centerPointX", 0, -1000000, 1000000);

        if (global.object.contains("centerPointY"))
            p.center_y = try number(global, "centerPointY", 0, -1000000, 1000000);

        _ = try number(global, "centerPointX2", 0, -40000000, 40000000);
        _ = try number(global, "centerPointY2", 0, -40000000, 40000000);

        p.counterclockwise = try boolean(global, "counterclockwise", false);
        _ = try boolean(global, "isActive", true);
    }

    return p;
}

const Skipped = struct { ambient: bool = false, audio: bool = false };

fn layers(allocator: std.mem.Allocator, source: []const Layer, devices: []const Device, regions: *std.ArrayList(runtime.Region), visible: bool, depth: usize, seed: u32, targeted: bool, skipped: *Skipped) anyerror!void {
    if (depth > 32)
        return error.ChromaGroupsTooDeep;

    var i = source.len;

    while (i > 0) {
        i -= 1;
        const layer = source[i];
        const enabled = visible and layer.visible;

        if (std.mem.eql(u8, layer.type, "group")) {
            if (layer.regions.len != 0)
                return error.InvalidChromaLayer;

            try layers(allocator, layer.layers, devices, regions, enabled, depth + 1, seed, targeted, skipped);

            continue;
        }

        if (!std.mem.eql(u8, layer.type, "layer") or layer.layers.len != 0)
            return error.UnsupportedChromaLayerType;

        const name = layer.name orelse return error.InvalidChromaLayer;

        if (targeted) {
            var relevant = false;
            for (layer.regions) |region| {
                for (region.devices) |selection| {
                    if (selection.productId == devices[0].productId and std.mem.eql(u8, selection.id, devices[0].id))
                        relevant = true;
                }
            }
            if (!enabled or !relevant) continue;
            if (std.mem.eql(u8, name, "ambient")) {
                skipped.ambient = true;
                continue;
            }
            if (std.mem.eql(u8, name, "audio") or std.mem.eql(u8, name, "audiometer")) {
                skipped.audio = true;
                continue;
            }
        }

        // Validate effect names even for layers without regions.
        _ = std.meta.stringToEnum(runtime.Kind, name) orelse return error.UnsupportedChromaEffect;

        for (layer.regions) |region| {
            var params: ?runtime.Parameters = null;

            for (region.devices) |selection| {
                var device_index: ?usize = null;

                for (devices, 0..) |device, index| {
                    if (std.mem.eql(u8, selection.id, device.id) and selection.productId == device.productId) {
                        device_index = index;
                        break;
                    }
                }

                const index = device_index orelse {
                    if (targeted) continue;
                    return error.ChromaDeviceMismatch;
                };
                if (params == null)
                    params = try parameters(allocator, name, region.params, layer.params);
                var p = params.?;
                const device = devices[index];
                const pixels = try allocator.alloc(runtime.Pixel, selection.leds.len);
                var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
                defer seen.deinit(allocator);

                for (selection.leds, pixels) |led, *pixel| {
                    var exists = false;

                    for (device.leds) |known| {
                        if (known.row == led.row and known.col == led.col) {
                            exists = true;
                            break;
                        }
                    }

                    if (!exists)
                        return error.InvalidChromaLed;

                    const key = @as(u32, led.row) * 65536 + led.col;

                    if ((try seen.getOrPut(allocator, key)).found_existing)
                        return error.DuplicateChromaLed;

                    pixel.* = .{
                        .offset = (@as(usize, led.row) * device.config.MatrixMaxCol + led.col) * 3,
                        .x = @as(f64, @floatFromInt(led.col)),
                        .y = @as(f64, @floatFromInt(led.row)),
                    };

                    if (p.kind == .wheel) {
                        pixel.x += @trunc(device.x / 40);
                        pixel.y += @trunc(device.y / 40);
                    }
                }

                if (enabled) {
                    const shape: runtime.Device = .{ .pid = device.productId, .rows = @intCast(device.config.MatrixMaxRow), .columns = @intCast(device.config.MatrixMaxCol) };
                    if (p.kind == .wheel) {
                        if (p.center_x) |x| p.center_x = if (x < 0 or x >= 256) 0 else @trunc(x);
                        if (p.center_y) |y| p.center_y = if (y < 0 or y >= 256) 0 else @trunc(y);
                    }
                    try effects.prepare(allocator, &p, shape);
                    try regions.append(allocator, .{
                        .device = index,
                        .pixels = pixels,
                        .parameters = p,
                        .seed = seed,
                    });
                }
            }
        }
    }
}

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !runtime.Profile {
    return parseWithSeed(allocator, text, 1);
}

pub fn parseWithSeed(allocator: std.mem.Allocator, text: []const u8, seed: u32) !runtime.Profile {
    return parseTarget(allocator, text, seed, null);
}

pub fn parseForDevice(allocator: std.mem.Allocator, text: []const u8, seed: u32, pid: u16) !runtime.Profile {
    return parseTarget(allocator, text, seed, pid);
}

fn parseTarget(allocator: std.mem.Allocator, text: []const u8, seed: u32, pid: ?u16) !runtime.Profile {
    const parsed = try std.json.parseFromSlice(Document, allocator, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const doc = parsed.value;

    if (doc.version != 1)
        return error.UnsupportedChromaVersion;

    if (pid == null and doc.profiles.len != 1)
        return error.ChromaRequiresOneProfile;

    var profile_index: usize = 0;
    if (pid) |target| {
        search: for (doc.profiles, 0..) |*candidate, i| {
            if (candidate.* != .object) continue;
            const candidates = candidate.object.getPtr("devices") orelse continue;
            if (candidates.* != .array) continue;
            for (candidates.array.items, 0..) |device, j| {
                if (device != .object) continue;
                const vendor = device.object.get("vendorId") orelse continue;
                const product = device.object.get("productId") orelse continue;
                if (vendor == .integer and product == .integer and vendor.integer == 0x1532 and product.integer == target) {
                    profile_index = i;
                    // Decode only the selected entry, not other devices' capabilities.
                    candidates.array.items = candidates.array.items[j..][0..1];
                    break :search;
                }
            }
        } else return error.ChromaDeviceNotListed;
    }
    const decoded = try std.json.parseFromValue(Source, allocator, doc.profiles[profile_index], .{ .ignore_unknown_fields = true });
    defer decoded.deinit();
    const source = decoded.value;
    const selected_devices = source.devices;

    if (source.devices.len == 0)
        return error.ChromaRequiresDevice;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const a = arena.allocator();
    const devices = try a.alloc(runtime.Device, selected_devices.len);

    for (selected_devices, devices, 0..) |device, *target, i| {
        if (device.vendorId != 0x1532)
            return error.UnsupportedChromaVendor;

        if (device.orientation != 0)
            return error.UnsupportedChromaOrientation;

        if (!std.math.isFinite(device.x) or !std.math.isFinite(device.y) or @abs(device.x) > 40000000 or @abs(device.y) > 40000000)
            return error.InvalidChromaGrid;

        const rows = device.config.MatrixMaxRow;
        const cols = device.config.MatrixMaxCol;

        if (rows == 0 or cols == 0 or rows > 255 or cols > 255 or device.leds.len == 0)
            return error.InvalidChromaGrid;

        for (device.leds) |led|
            if (led.row >= rows or led.col >= cols)
                return error.InvalidChromaLed;

        for (selected_devices[0..i]) |other|
            if (std.mem.eql(u8, other.id, device.id))
                return error.DuplicateChromaDevice;

        target.* = .{ .pid = device.productId, .rows = @intCast(rows), .columns = @intCast(cols) };
    }

    var regions: std.ArrayList(runtime.Region) = .empty;
    var skipped: Skipped = .{};
    try layers(a, source.layers, selected_devices, &regions, true, 0, seed, pid != null, &skipped);
    const owned_regions = try regions.toOwnedSlice(a);

    errdefer for (owned_regions) |region| {
        if (region.state) |state| state.deinit();
    };
    for (owned_regions) |*region| {
        const State = @import("state.zig").State;
        if (State.required(region.parameters)) {
            const state = try a.create(State);
            state.* = try State.init(allocator, region.parameters, devices[region.device], if (region.parameters.kind == .fire) 1 else seed);
            region.state = state;
        }
    }
    return .{ .arena = arena, .devices = devices, .regions = owned_regions, .skipped_ambient = skipped.ambient, .skipped_audio = skipped.audio };
}
