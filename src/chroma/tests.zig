const std = @import("std");
const importer = @import("import.zig");
const render = @import("render.zig");

test "targeted playback selects the first matching profile and entry" {
    const text =
        \\{"version":1,"profiles":[
        \\{"devices":[{"productId":229}],
        \\"layers":[{"type":"layer","name":"unknown","visible":true}]},
        \\{"devices":[
        \\{"id":"first","vendorId":5426,"productId":694,
        \\"config":{"MatrixMaxRow":1,"MatrixMaxCol":1},"leds":[{"row":0,"col":0}]},
        \\{"id":"second","vendorId":5426,"productId":694,
        \\"config":{"MatrixMaxRow":0,"MatrixMaxCol":0},"leds":[]}],
        \\"layers":[
        \\{"type":"layer","name":"unknown","visible":true,"regions":[{"params":{},
        \\"devices":[{"id":"second","productId":694,"leds":[]}]}]},
        \\{"type":"layer","name":"ambient","visible":true,"regions":[{"params":{},
        \\"devices":[{"id":"first","productId":694,"leds":[{"row":0,"col":0}]}]}]},
        \\{"type":"layer","name":"audio","visible":true,"regions":[{"params":{},
        \\"devices":[{"id":"first","productId":694,"leds":[{"row":0,"col":0}]}]}]},
        \\{"type":"layer","name":"static","visible":true,"regions":[{"params":{"color":65535},
        \\"devices":[{"id":"first","productId":694,"leds":[{"row":0,"col":0}]}]}]}]},
        \\{"devices":[],"layers":[]}]}
    ;
    var p = try importer.parseForDevice(std.testing.allocator, text, 1, 694);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.devices.len);
    try std.testing.expectEqual(@as(usize, 1), p.regions.len);
    try std.testing.expect(p.skipped_ambient and p.skipped_audio);
    var rgb: [3]u8 = undefined;
    try render.frameTick(p, 0, 0, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 255 }, &rgb);
    try std.testing.expectError(error.ChromaDeviceNotListed, importer.parseForDevice(std.testing.allocator, text, 1, 999));
}

test "targeted playback permits a profile containing only skipped effects" {
    const text =
        \\{"version":1,"profiles":[{"devices":[{"id":"blade","vendorId":5426,"productId":694,
        \\"config":{"MatrixMaxRow":1,"MatrixMaxCol":1},"leds":[{"row":0,"col":0}]}],
        \\"layers":[{"type":"layer","name":"ambient","visible":true,"regions":[{"params":{},
        \\"devices":[{"id":"blade","productId":694,"leds":[{"row":0,"col":0}]}]}]}]}]}
    ;
    var p = try importer.parseForDevice(std.testing.allocator, text, 1, 694);
    defer p.deinit();
    try std.testing.expect(p.skipped_ambient);
    try std.testing.expectEqual(@as(usize, 0), p.regions.len);
}

const fixture =
    \\{"version":1,"profiles":[{"devices":[{"id":"blade","vendorId":5426,"productId":694,
    \\"config":{"MatrixMaxRow":1,"MatrixMaxCol":2},"leds":[{"row":0,"col":0},{"row":0,"col":1}]}],
    \\"layers":[{"type":"layer","name":"static","visible":true,"regions":[{"params":{"color":65535},
    \\"devices":[{"id":"blade","productId":694,"leds":[{"row":0,"col":1}]}]}]},
    \\{"type":"layer","name":"static","visible":true,"regions":[{"params":{"color":8388736},
    \\"devices":[{"id":"blade","productId":694,"leds":[{"row":0,"col":0},{"row":0,"col":1}]}]}]}]}]}
;

const input_fixture =
    \\{"version":1,"profiles":[{"devices":[{"id":"blade","vendorId":5426,"productId":694,
    \\"config":{"MatrixMaxRow":1,"MatrixMaxCol":3},"leds":[{"row":0,"col":0},{"row":0,"col":1},{"row":0,"col":2}]}],
    \\"layers":[{"type":"layer","name":"reactive","visible":true,"regions":[{"params":{
    \\"color":16711680,"duration":160,"playbackStart":"onPress","playbackEnd":"after","cycles":1},
    \\"devices":[{"id":"blade","productId":694,"leds":[{"row":0,"col":1}]}]}]},
    \\{"type":"layer","name":"static","visible":true,"regions":[{"params":{"color":255},
    \\"devices":[{"id":"blade","productId":694,"leds":[{"row":0,"col":0},{"row":0,"col":1},{"row":0,"col":2}]}]}]}]}]}
;

test "imported Reactive composes with background, retains quick taps and validates input" {
    var p = try importer.parse(std.testing.allocator, input_fixture);
    defer p.deinit();
    try std.testing.expect(p.needsInput(0));
    var rgb: [9]u8 = undefined;
    try render.frameTick(p, 0, 0, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 0, 0, 255, 0, 0, 255 }, &rgb);
    try render.input(p, 0, .{ .row = 0, .col = 1, .pressed = true }, 1);
    try render.input(p, 0, .{ .row = 0, .col = 1, .pressed = false }, 1);
    try render.frameTick(p, 0, 1, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 0, 0, 0, 0, 255 }, &rgb);
    try render.frameTick(p, 0, 4, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 0, 0, 255, 0, 0, 255 }, &rgb);
    try std.testing.expectError(error.InvalidInputDevice, render.input(p, 1, .{ .row = 0, .col = 1, .pressed = true }, 4));
    try std.testing.expectError(error.InvalidInputCell, render.input(p, 0, .{ .row = 0, .col = 3, .pressed = true }, 4));
}

test "player delivers queued input before each animated frame" {
    const Clock = struct {
        time: i96 = 0,
        calls: u64 = 0,
        pub fn check(_: *@This()) !void {}
        pub fn now(self: *@This()) i96 {
            return self.time;
        }
        pub fn wait(self: *@This(), deadline: i96) !void {
            self.time = deadline;
        }
        pub fn input(self: *@This(), p: *const @import("profile.zig").Profile, device: usize, tick: u64) !void {
            try std.testing.expectEqual(self.calls, tick);
            self.calls += 1;
            if (tick != 1) return;
            try render.input(p.*, device, .{ .row = 0, .col = 1, .pressed = true }, tick);
            try render.input(p.*, device, .{ .row = 0, .col = 1, .pressed = false }, tick);
        }
    };
    var p = try importer.parse(std.testing.allocator, input_fixture);
    defer p.deinit();
    var player: render.Player(Clock) = .{ .profile = &p, .device = 0, .clock = .{} };
    var rgb: [9]u8 = undefined;
    try std.testing.expect(try player.next(&rgb));
    try std.testing.expectEqual(@as(u8, 0), rgb[3]);
    try std.testing.expect(try player.next(&rgb));
    try std.testing.expectEqual(@as(u8, 255), rgb[3]);
    try std.testing.expect(try player.next(&rgb));
    try std.testing.expectEqual(@as(u8, 170), rgb[3]);
    try std.testing.expectEqual(@as(u64, 3), player.clock.calls);
}

test "Ripple onPress accepts origins outside output mask while onSelectedKeys gates them" {
    const ripple = try std.mem.replaceOwned(u8, std.testing.allocator, input_fixture, "\"name\":\"reactive\"", "\"name\":\"ripple\"");
    defer std.testing.allocator.free(ripple);
    const text = try std.mem.replaceOwned(u8, std.testing.allocator, ripple, "\"color\":16711680,\"duration\":160", "\"colorStops\":[{\"Stop\":0,\"Color\":16711680},{\"Stop\":100,\"Color\":16711680}],\"speed\":10,\"width\":100");
    defer std.testing.allocator.free(text);
    for ([_]bool{ false, true }) |selected| {
        const source = try std.mem.replaceOwned(u8, std.testing.allocator, text, "onPress", if (selected) "onSelectedKeys" else "onPress");
        defer std.testing.allocator.free(source);
        var p = try importer.parse(std.testing.allocator, source);
        defer p.deinit();
        try render.input(p, 0, .{ .row = 0, .col = 0, .pressed = true }, 0);
        var rgb: [9]u8 = undefined;
        try render.frameTick(p, 0, 3, &rgb);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, rgb[0..3]);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, rgb[6..9]);
        if (selected) {
            try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255 }, rgb[3..6]);
        } else try std.testing.expect(rgb[3] > 0);
    }
}

test "input profiles reject toggle and automatic starts and clean up after trigger allocation errors" {
    for ([_][]const u8{ "toggle", "random" }) |start| {
        const text = try std.mem.replaceOwned(u8, std.testing.allocator, input_fixture, "onPress", start);
        defer std.testing.allocator.free(text);
        try std.testing.expectError(error.UnsupportedChromaTrigger, importer.parse(std.testing.allocator, text));
    }
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var p = try importer.parse(allocator, input_fixture);
            defer p.deinit();
            try render.input(p, 0, .{ .row = 0, .col = 1, .pressed = true }, 0);
            var rgb: [9]u8 = undefined;
            try render.frameTick(p, 0, 0, &rgb);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "first layer wins; decoded profile owns storage; hidden groups suppress children" {
    const text = try std.testing.allocator.dupe(u8, fixture);
    var p = importer.parse(std.testing.allocator, text) catch |err| {
        std.testing.allocator.free(text);
        return err;
    };
    defer p.deinit();
    @memset(text, 0);
    std.testing.allocator.free(text);
    var rgb: [6]u8 = undefined;
    try render.frame(p, 0, 0, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 128, 0, 255, 255 }, &rgb);
    try std.testing.expect(!p.animated(0));
    const wrapped = try std.mem.replaceOwned(u8, std.testing.allocator, fixture, "\"layers\":[", "\"layers\":[{\"type\":\"group\",\"visible\":false,\"layers\":[");
    defer std.testing.allocator.free(wrapped);
    const group = try std.testing.allocator.print("{s}]}}]}}]}}", .{wrapped[0 .. wrapped.len - 4]});
    defer std.testing.allocator.free(group);
    var hidden = try importer.parse(std.testing.allocator, group);
    defer hidden.deinit();
    try render.frame(hidden, 0, 0, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, &rgb);
}

test "invalid and unsupported fields fail before playback" {
    const cases = .{
        .{ "\"version\":1", "\"version\":2", error.UnsupportedChromaVersion },
        .{ "\"name\":\"static\"", "\"name\":\"audio\"", error.UnsupportedChromaEffect },
        .{ "\"col\":1", "\"col\":2", error.InvalidChromaLed },
        .{ "\"color\":65535", "\"color\":16777216", error.InvalidChromaColour },
        .{ "\"color\":65535", "\"color\":65535,\"opacity\":0.5", error.UnsupportedChromaParameters },
        .{ "\"id\":\"blade\",\"productId\"", "\"id\":\"other\",\"productId\"", error.ChromaDeviceMismatch },
    };
    inline for (cases) |case| {
        const text = try std.mem.replaceOwned(u8, std.testing.allocator, fixture, case[0], case[1]);
        defer std.testing.allocator.free(text);
        try std.testing.expectError(case[2], importer.parse(std.testing.allocator, text));
    }
}

test "animated profiles change pixels without frame allocations" {
    const wave =
        \\{"version":1,"profiles":[{"devices":[{"id":"blade","vendorId":5426,"productId":694,
        \\"config":{"MatrixMaxRow":1,"MatrixMaxCol":2},"leds":[{"row":0,"col":0},{"row":0,"col":1}]}],
        \\"layers":[{"type":"layer","name":"wave","visible":true,"params":{},"regions":[{"params":{
        \\"speed":25,"width":100,"angle":0,"colorStops":[{"Stop":0,"Color":16711680},{"Stop":100,"Color":255}],
        \\"playbackStart":"random","playbackEnd":"never","cycles":-1},
        \\"devices":[{"id":"blade","productId":694,"leds":[{"row":0,"col":0},{"row":0,"col":1}]}]}]}]}]}
    ;
    var p = try importer.parse(std.testing.allocator, wave);
    defer p.deinit();
    try std.testing.expect(p.animated(0));
    var a: [6]u8 = undefined;
    var b: [6]u8 = undefined;
    try render.frame(p, 0, 0, &a);
    try render.frame(p, 0, 0.5, &b);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    try std.testing.expectError(error.InvalidFrame, render.frame(p, 1, 0, &a));
    try std.testing.expectError(error.InvalidFrame, render.frame(p, 0, -1, &a));
    const triggered = try std.mem.replaceOwned(u8, std.testing.allocator, wave, "\"random\"", "\"onPress\"");
    defer std.testing.allocator.free(triggered);
    try std.testing.expectError(error.UnsupportedChromaTrigger, importer.parse(std.testing.allocator, triggered));
    const zero = try std.mem.replaceOwned(u8, std.testing.allocator, wave, "\"width\":100", "\"width\":0");
    defer std.testing.allocator.free(zero);
    try std.testing.expectError(error.InvalidChromaParameter, importer.parse(std.testing.allocator, zero));
}

test "player paces frames and static profiles wait without reuploading" {
    const Clock = struct {
        time: i96 = 0,
        interrupted: bool = false,
        pub fn check(self: *@This()) !void {
            if (self.interrupted) return error.StreamInterrupted;
        }
        pub fn now(self: *@This()) i96 {
            return self.time;
        }
        pub fn wait(self: *@This(), deadline: i96) !void {
            self.time = deadline;
            return error.StreamInterrupted;
        }
    };
    var p = try importer.parse(std.testing.allocator, fixture);
    defer p.deinit();
    var player: render.Player(Clock) = .{ .profile = &p, .device = 0, .clock = .{} };
    var rgb: [6]u8 = undefined;
    try std.testing.expect(try player.next(&rgb));
    try std.testing.expectError(error.StreamInterrupted, player.next(&rgb));
    try std.testing.expectEqual(@as(i96, std.time.ns_per_s), player.clock.time);
}

test "transparent top region blends over the lower layer" {
    const types = @import("profile.zig");
    const devices = [_]types.Device{.{ .pid = 0x02b6, .rows = 1, .columns = 1 }};
    const pixels = [_]types.Pixel{.{ .offset = 0, .x = 0, .y = 0 }};
    const regions = [_]types.Region{
        .{ .device = 0, .pixels = &pixels, .seed = 1, .parameters = .{
            .kind = .static,
            .color = .{ .rgb = .{ 255, 0, 0 } },
        } },
        .{ .device = 0, .pixels = &pixels, .seed = 2, .parameters = .{
            .kind = .static,
            .color = .{ .rgb = .{ 0, 0, 255 }, .alpha = 0.5 },
        } },
    };
    const p: types.Profile = .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .devices = &devices,
        .regions = &regions,
    };
    var rgb: [3]u8 = undefined;
    try render.frame(p, 0, 0, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 127 }, &rgb);
}

test "animated player waits between frames and propagates interruption" {
    const types = @import("profile.zig");
    const devices = [_]types.Device{.{ .pid = 0x02b6, .rows = 1, .columns = 1 }};
    const pixels = [_]types.Pixel{.{ .offset = 0, .x = 0, .y = 0 }};
    const regions = [_]types.Region{.{
        .device = 0,
        .pixels = &pixels,
        .seed = 1,
        .parameters = .{ .kind = .breathing, .table = &.{.{ .rgb = .{ 255, 0, 0 }, .transparency = 0 }} },
    }};
    const p: types.Profile = .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .devices = &devices,
        .regions = &regions,
    };
    const Clock = struct {
        time: i96 = 0,
        interrupted: bool = false,
        pub fn check(self: *@This()) !void {
            if (self.interrupted) return error.StreamInterrupted;
        }
        pub fn now(self: *@This()) i96 {
            return self.time;
        }
        pub fn wait(self: *@This(), deadline: i96) !void {
            try self.check();
            self.time = @max(self.time, deadline);
        }
    };
    var player: render.Player(Clock) = .{ .profile = &p, .device = 0, .clock = .{} };
    var rgb: [3]u8 = undefined;
    try std.testing.expect(try player.next(&rgb));
    try std.testing.expect(try player.next(&rgb));
    try std.testing.expectEqual(@as(i96, std.time.ns_per_s / 25), player.clock.time);
    player.clock.time += std.time.ns_per_s;
    try std.testing.expect(try player.next(&rgb));
    try std.testing.expectEqual(@as(u64, 3), player.tick);
    try std.testing.expectEqual(player.clock.time + std.time.ns_per_s / 25, player.deadline.?);
    player.clock.interrupted = true;
    try std.testing.expectError(error.StreamInterrupted, player.next(&rgb));
}

test "native gradient samples composite with signed truncation" {
    const types = @import("profile.zig");
    const effects = @import("effects.zig");
    const devices = [_]types.Device{.{ .pid = 0x02b6, .rows = 1, .columns = 1 }};
    const pixels = [_]types.Pixel{.{ .offset = 0, .x = 0, .y = 0 }};
    const stops = [_]types.Stop{
        .{ .position = 0, .color = .{ .rgb = .{ 255, 0, 0 } } },
        .{ .position = 1, .color = .{ .rgb = .{ 0, 0, 0 }, .alpha = 0 } },
    };
    const samples = try effects.table(std.testing.allocator, &stops, 5);
    defer std.testing.allocator.free(samples);

    const regions = [_]types.Region{.{
        .device = 0,
        .pixels = &pixels,
        .seed = 1,
        .parameters = .{ .kind = .spectrum, .table = samples },
    }};
    const p: types.Profile = .{
        .arena = std.heap.ArenaAllocator.init(std.testing.allocator),
        .devices = &devices,
        .regions = &regions,
    };
    var rgb: [3]u8 = undefined;

    for ([_]u8{ 255, 143, 63, 15, 0 }, 0..) |red, i| {
        try render.frame(p, 0, @as(f64, @floatFromInt(i)) / types.fps, &rgb);
        try std.testing.expectEqualSlices(u8, &.{ red, 0, 0 }, &rgb);
    }
}

test "import compiles owned breathing tables and keeps missing second colour transparent" {
    const text = try std.mem.replaceOwned(u8, std.testing.allocator, fixture, "\"name\":\"static\"", "\"name\":\"breathing\"");
    defer std.testing.allocator.free(text);

    var p = try importer.parse(std.testing.allocator, text);
    defer p.deinit();

    const params = p.regions[0].parameters;

    try std.testing.expectEqual(@as(usize, 350), params.table.len);
    try std.testing.expectEqual(@as(f64, 0), params.color2.alpha);
    try std.testing.expectEqual(@as(u8, 100), params.table[270].transparency);

    const custom = try std.mem.replaceOwned(u8, std.testing.allocator, text, "\"color\":65535", "\"colorStops\":[{\"Stop\":0,\"Color\":16711680},{\"Stop\":100,\"Color\":255}],\"duration\":1");
    defer std.testing.allocator.free(custom);

    var short = try importer.parse(std.testing.allocator, custom);
    defer short.deinit();

    try std.testing.expectEqual(@as(usize, 2), short.regions[1].parameters.table.len);
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, short.regions[1].parameters.table[0].rgb);
}

test "compiled profile tables clean up on allocation failure" {
    const text = try std.mem.replaceOwned(u8, std.testing.allocator, fixture, "\"name\":\"static\"", "\"name\":\"breathing\"");
    defer std.testing.allocator.free(text);

    const Check = struct {
        fn parse(allocator: std.mem.Allocator, source: []const u8) !void {
            var p = try importer.parse(allocator, source);
            defer p.deinit();
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.parse, .{text});
}

const stars_fixture =
    \\{"version":1,"profiles":[{"devices":[{"id":"blade","vendorId":5426,"productId":694,
    \\"config":{"MatrixMaxRow":1,"MatrixMaxCol":2},"leds":[{"row":0,"col":0},{"row":0,"col":1}]}],
    \\"layers":[{"type":"layer","name":"starlight","visible":true,"regions":[{"params":{
    \\"randomColor":true,"duration":1700,"density":10},
    \\"devices":[{"id":"blade","productId":694,"leds":[{"row":0,"col":1}]}]}]}]}]}
;

test "import owns mutable effect state and sparse selections only mask the full canvas" {
    var p = try importer.parseWithSeed(std.testing.allocator, stars_fixture, 2);
    defer p.deinit();
    const state = p.regions[0].state.?;
    try std.testing.expectEqual(@as(usize, 2), state.capacity);
    var rgb: [6]u8 = undefined;
    try render.frameTick(p, 0, 0, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, &rgb);
    try std.testing.expect(state.population > 0);
    var changed = false;
    for (1..100) |tick| {
        try render.frameTick(p, 0, tick, &rgb);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, rgb[0..3]);
        changed = changed or rgb[3] != 0 or rgb[4] != 0 or rgb[5] != 0;
    }
    try std.testing.expect(changed);
    try render.frameTick(p, 0, 0, &rgb);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, &rgb);
}

test "imported mutable state releases allocations on every failure path" {
    const Check = struct {
        fn parse(allocator: std.mem.Allocator) !void {
            var p = try importer.parseWithSeed(allocator, stars_fixture, 2);
            defer p.deinit();
            var rgb: [6]u8 = undefined;
            try render.frameTick(p, 0, 20, &rgb);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.parse, .{});
}

test "short Starlight duration rejects zero native spawn interval explicitly" {
    const text = try std.mem.replaceOwned(u8, std.testing.allocator, stars_fixture, "\"duration\":1700", "\"duration\":1");
    defer std.testing.allocator.free(text);
    try std.testing.expectError(error.InvalidChromaParameter, importer.parse(std.testing.allocator, text));
}
