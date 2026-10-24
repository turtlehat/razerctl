//! Shared frame output and restoration.
const std = @import("std");
const transport = @import("transport");
const device = @import("device_types");
const settings = @import("settings");
const lighting = settings.module("lighting");
const wire = lighting.streaming;

pub const Input = @import("stream_input").Input;

pub const Result = struct {
    failure: ?anyerror = null,
    control_restore: ?anyerror = null,
    effect_restore: ?anyerror = null,
};

pub const Layout = lighting.Layout;
pub const format = wire.format;
pub const layout = wire.layout;

pub const Output = struct {
    hid: transport.Device,
    shape: Layout,

    pub fn open(io: std.Io, desc: *const device.Descriptor) !Output {
        const config = desc.features.lighting;
        if (!config.validFrames())
            return error.StreamNotSupported;
        var hid = try transport.Device.openWith(io, desc.pid, .{
            .interface = config.control_interface,
            .format = wire.format(config),
            .probe = if (config.protocol == .audio37) .none else .firmware,
        });
        errdefer hid.close();
        const shape = selected: {
            try hid.acquire();
            defer hid.release();
            break :selected try wire.layout(&hid, config);
        };
        return .{ .hid = hid, .shape = shape };
    }

    pub fn close(self: *Output) void {
        self.hid.close();
    }
};

pub fn run(hid: *transport.Device, desc: *const device.Descriptor, shape: Layout, input: anytype, frame: []u8) Result {
    const config = desc.features.lighting;
    if (config.protocol == null)
        return .{ .failure = error.StreamNotSupported };
    if (!config.validFrames() or frame.len != shape.frameSize())
        return .{ .failure = error.InvalidFrame };
    var writer = wire.Writer.init(hid, config, shape) catch |err| return .{ .failure = err };
    defer writer.deinit();
    var backend: Backend = .{ .hid = hid, .desc = desc, .config = config, .writer = &writer };

    return session(&backend, input, frame, backend.config.frame_latch);
}

const Backend = struct {
    hid: *transport.Device,
    desc: *const device.Descriptor,
    config: lighting.Config,
    writer: *wire.Writer,
    effects: [16][12]u8 = undefined,
    audio_effect: [37]u8 = undefined,
    audio_status: u8 = undefined,

    fn now(self: *Backend) i96 {
        return std.Io.Clock.boot.now(self.hid.io).nanoseconds;
    }

    fn acquire(self: *Backend) !void {
        try self.hid.acquirePriority(.high);
    }

    fn release(self: *Backend) void {
        self.hid.release();
    }

    fn snapshot(self: *Backend) !void {
        if (self.config.protocol == .audio37) {
            self.audio_status = (try wire.audioQuery(self.hid, 0x84, 0))[3];
            self.audio_effect = try wire.audioQuery(self.hid, 0x81, self.audioZone());
            if (self.audio_effect[4] == 8)
                return error.CustomFrameAlreadyActive;
            return;
        }
        for (self.config.zones, 0..) |zone, i| {
            if (zone.frame == null)
                continue;
            self.effects[i] = try lighting.readBlock(self.hid, self.desc, zone.id);
            // A live custom framebuffer cannot be recovered from its effect register.
            if (self.effects[i][2] == 8)
                return error.CustomFrameAlreadyActive;
        }
    }

    fn enter(self: *Backend) !void {
        if (self.config.protocol == .audio37) {
            try self.setAudioStatus(1);
        }
    }

    fn write(self: *Backend, frame: []const u8) !void {
        try self.writer.write(frame);
    }

    fn needsWrite(self: *Backend, frame: []const u8) bool {
        return self.writer.needsWrite(frame);
    }

    fn invalidate(self: *Backend) void {
        self.writer.invalidate();
    }

    fn latch(self: *Backend) !void {
        try self.writer.latch();
    }

    fn restoreControl(self: *Backend) !void {
        if (self.config.protocol == .audio37) {
            try self.setAudioStatus(self.audio_status);
        }
    }

    fn restoreEffect(self: *Backend) !void {
        if (self.config.protocol == .audio37) {
            var report = self.audio_effect;
            report[0..3].* = .{ 0x40, 1, 1 };
            try self.hid.writeReport(&report);
            return;
        }
        var failure: ?anyerror = null;
        for (self.config.zones, 0..) |zone, i| {
            if (zone.frame == null)
                continue;
            lighting.restore(self.hid, self.desc, zone.id, self.effects[i]) catch |err| {
                if (failure == null)
                    failure = err;
            };
        }
        if (failure) |err|
            return err;
    }

    fn setAudioStatus(self: *Backend, value: u8) !void {
        var report: [37]u8 = @splat(0);
        report[0..4].* = .{ 0x40, 4, 0, value };
        try self.hid.writeReport(&report);
    }

    fn audioZone(self: *const Backend) u8 {
        for (self.config.zones) |zone|
            if (zone.frame != null)
                return zone.id;
        unreachable;
    }
};

fn nextFrame(input: anytype, frame: []u8) !bool {
    return input.next(frame);
}

fn session(backend: anytype, input: anytype, frame: []u8, every_frame: bool) Result {
    const first = nextFrame(input, frame) catch |err| return .{ .failure = err };
    if (!first)
        return .{};
    var result: Result = .{};
    var last_frame: ?i96 = null;
    {
        backend.acquire() catch |err| return .{ .failure = err };
        defer backend.release();
        backend.snapshot() catch |err| return .{ .failure = err };
        upload(backend, input, frame, &last_frame, every_frame) catch |err| {
            result.failure = err;
        };
    }
    if (result.failure == null)
        pump(backend, input, frame, &last_frame, every_frame) catch |err| {
            result.failure = err;
        };

    backend.acquire() catch |err| {
        result.control_restore = err;
        result.effect_restore = err;
        return result;
    };
    defer backend.release();
    // Both restorations are attempted, even after a partially failed setup.
    backend.restoreControl() catch |err| {
        result.control_restore = err;
    };
    backend.restoreEffect() catch |err| {
        result.effect_restore = err;
    };
    return result;
}

fn upload(backend: anytype, input: anytype, frame: []const u8, last_frame: *?i96, every_frame: bool) !void {
    try input.check();
    // Sleep can reset streaming control without invalidating the USB handle.
    const started = backend.now();
    const reenter = if (last_frame.*) |last| started - last >= std.time.ns_per_s else true;
    if (reenter) {
        backend.invalidate();
        try backend.enter();
    }
    try backend.write(frame);
    if (reenter or every_frame)
        try backend.latch();
    last_frame.* = started;
}

fn pump(backend: anytype, input: anytype, frame: []u8, last_frame: *?i96, every_frame: bool) !void {
    while (try nextFrame(input, frame)) {
        try input.check();
        const now = backend.now();
        const gap = if (last_frame.*) |last| now - last >= std.time.ns_per_s else true;
        if (!gap and !backend.needsWrite(frame)) {
            last_frame.* = now;
            continue;
        }
        try backend.acquire();
        defer backend.release();
        try upload(backend, input, frame, last_frame, every_frame);
    }
}

const TestInput = struct {
    bytes: []const u8,
    chunk: usize = 1,
    interrupted_after: ?usize = null,
    offset: usize = 0,
    backend: ?*TestBackend = null,
    frame_interval: i96 = 0,
    suspend_at: ?usize = null,

    fn next(self: *TestInput, frame: []u8) !bool {
        if (self.backend) |backend| {
            backend.time += self.frame_interval;
            if (self.suspend_at == self.offset)
                backend.time += 60 * std.time.ns_per_s;
        }
        var offset: usize = 0;
        while (offset < frame.len) {
            const n = try self.read(frame[offset..]);
            if (n == 0) {
                if (offset != 0)
                    return error.IncompleteFrame;
                return false;
            }
            offset += n;
        }
        return true;
    }

    fn check(self: *TestInput) !void {
        if (self.interrupted_after) |limit|
            if (self.offset >= limit)
                return error.StreamInterrupted;
    }

    fn read(self: *TestInput, buffer: []u8) !usize {
        if (self.backend) |backend|
            try std.testing.expect(!backend.locked);
        try self.check();
        const n = @min(buffer.len, self.chunk, self.bytes.len);

        @memcpy(buffer[0..n], self.bytes[0..n]);
        self.bytes = self.bytes[n..];
        self.offset += n;
        return n;
    }
};

const TestBackend = struct {
    events: std.ArrayList(u8) = .empty,
    fail: ?u8 = null,
    fail_restore: bool = false,
    locked: bool = false,
    time: i96 = 0,
    write_duration: i96 = 0,
    unchanged: bool = false,

    fn needsWrite(self: *TestBackend, _: []const u8) bool {
        return !self.unchanged;
    }

    fn invalidate(_: *TestBackend) void {}

    fn now(self: *TestBackend) i96 {
        return self.time;
    }

    fn acquire(self: *TestBackend) !void {
        try std.testing.expect(!self.locked);
        self.locked = true;
    }

    fn release(self: *TestBackend) void {
        std.debug.assert(self.locked);
        self.locked = false;
    }

    fn event(self: *TestBackend, id: u8) !void {
        try std.testing.expect(self.locked);
        try self.events.append(std.testing.allocator, id);
        if (self.fail == id)
            return error.TestFailure;
    }
    fn snapshot(self: *TestBackend) !void {
        try self.event('s');
    }
    fn enter(self: *TestBackend) !void {
        try self.event('e');
    }
    fn write(self: *TestBackend, frame: []const u8) !void {
        try self.event(frame[0]);
        self.time += self.write_duration;
    }
    fn latch(self: *TestBackend) !void {
        try self.event('l');
    }
    fn restoreControl(self: *TestBackend) !void {
        try self.event('m');
        if (self.fail_restore)
            return error.ControlRestoreFailed;
    }
    fn restoreEffect(self: *TestBackend) !void {
        try self.event('r');
        if (self.fail_restore)
            return error.EffectRestoreFailed;
    }
};

test "fragmented RGB frames remain ordered and latch once or per frame" {
    for ([_]bool{ false, true }) |every| {
        var backend: TestBackend = .{};
        defer backend.events.deinit(std.testing.allocator);
        var input: TestInput = .{ .bytes = "AAABBB", .backend = &backend };
        var frame: [3]u8 = undefined;
        const result = session(&backend, &input, &frame, every);

        try std.testing.expect(result.failure == null);
        try std.testing.expect(result.control_restore == null);
        try std.testing.expect(result.effect_restore == null);
        try std.testing.expectEqualStrings(if (every) "seAlBlmr" else "seAlBmr", backend.events.items);
        try std.testing.expect(!backend.locked);
    }
}

test "empty or incomplete first frames never change hardware" {
    for ([_][]const u8{ "", "AA" }) |bytes| {
        var backend: TestBackend = .{};
        defer backend.events.deinit(std.testing.allocator);
        var input: TestInput = .{ .bytes = bytes };
        var frame: [3]u8 = undefined;
        const result = session(&backend, &input, &frame, false);

        try std.testing.expectEqual(@as(usize, 0), backend.events.items.len);
        try std.testing.expectEqual(if (bytes.len == 0) null else @as(?anyerror, error.IncompleteFrame), result.failure);
    }
}

test "unchanged frames skip uploads and per-frame latches" {
    for ([_]bool{ false, true }) |every| {
        var backend: TestBackend = .{ .unchanged = true };
        defer backend.events.deinit(std.testing.allocator);
        var input: TestInput = .{
            .bytes = &@as([120]u8, @splat('A')),
            .backend = &backend,
            .frame_interval = 40 * std.time.ns_per_ms,
        };
        var frame: [3]u8 = undefined;
        const result = session(&backend, &input, &frame, every);
        try std.testing.expect(result.failure == null);
        try std.testing.expectEqualStrings("seAlmr", backend.events.items);
    }
}

test "resume forces an unchanged frame to upload and latch again" {
    var backend: TestBackend = .{ .unchanged = true };
    defer backend.events.deinit(std.testing.allocator);
    var input: TestInput = .{
        .bytes = "AAAAAAAAAAAA",
        .backend = &backend,
        .frame_interval = 40 * std.time.ns_per_ms,
        .suspend_at = 6,
    };
    var frame: [3]u8 = undefined;
    const result = session(&backend, &input, &frame, false);
    try std.testing.expect(result.failure == null);
    try std.testing.expectEqualStrings("seAleAlmr", backend.events.items);
}

test "long upload gaps reenter and latch without replacing the original snapshot" {
    for ([_]bool{ false, true }) |every| {
        for ([_]i96{ std.time.ns_per_s - 1, std.time.ns_per_s, 60 * std.time.ns_per_s }) |gap| {
            var backend: TestBackend = .{};
            defer backend.events.deinit(std.testing.allocator);
            var input: TestInput = .{ .bytes = "" };
            var last_upload: ?i96 = null;
            try backend.acquire();
            defer backend.release();
            try upload(&backend, &input, "AAA", &last_upload, every);
            backend.time += gap;
            try upload(&backend, &input, "BBB", &last_upload, every);
            try upload(&backend, &input, "CCC", &last_upload, every);
            const expected = if (gap >= std.time.ns_per_s)
                (if (every) "eAleBlCl" else "eAleBlC")
            else
                (if (every) "eAlBlCl" else "eAlBC");
            try std.testing.expectEqualStrings(expected, backend.events.items);
        }
    }
}

test "suspend during an upload is detected on the next frame" {
    var backend: TestBackend = .{};
    defer backend.events.deinit(std.testing.allocator);
    var input: TestInput = .{ .bytes = "" };
    var last_upload: ?i96 = null;
    try backend.acquire();
    defer backend.release();
    try upload(&backend, &input, "AAA", &last_upload, false);
    backend.write_duration = 60 * std.time.ns_per_s;
    try upload(&backend, &input, "BBB", &last_upload, false);
    try std.testing.expectEqual(@as(?i96, 0), last_upload);
    backend.write_duration = 0;
    try upload(&backend, &input, "CCC", &last_upload, false);
    try upload(&backend, &input, "DDD", &last_upload, false);
    try std.testing.expectEqualStrings("eAlBeClD", backend.events.items);
}

test "failed gap recovery does not advance the last upload time" {
    var backend: TestBackend = .{};
    defer backend.events.deinit(std.testing.allocator);
    var input: TestInput = .{ .bytes = "" };
    var last_upload: ?i96 = null;
    try backend.acquire();
    defer backend.release();
    try upload(&backend, &input, "AAA", &last_upload, false);
    backend.time += std.time.ns_per_s;
    backend.fail = 'l';
    try std.testing.expectError(error.TestFailure, upload(&backend, &input, "BBB", &last_upload, false));
    try std.testing.expectEqual(@as(?i96, 0), last_upload);
}
test "partial setup frame and latch failures attempt both restorations" {
    for ("seAl") |failed| {
        var backend: TestBackend = .{ .fail = failed };
        defer backend.events.deinit(std.testing.allocator);
        var input: TestInput = .{ .bytes = "AAA" };
        var frame: [3]u8 = undefined;
        const result = session(&backend, &input, &frame, false);

        try std.testing.expectEqual(error.TestFailure, result.failure.?);
        if (failed == 's') {
            try std.testing.expectEqualStrings("s", backend.events.items);
        } else {
            try std.testing.expect(std.mem.endsWith(u8, backend.events.items, "mr"));
        }
    }
}

test "truncation interruption and restoration failures remain distinct" {
    for ([_]bool{ false, true }) |interrupt| {
        var backend: TestBackend = .{ .fail_restore = true };
        defer backend.events.deinit(std.testing.allocator);
        var input: TestInput = .{ .bytes = "AAAB", .interrupted_after = if (interrupt) 4 else null };
        var frame: [3]u8 = undefined;
        const result = session(&backend, &input, &frame, false);

        try std.testing.expectEqual(if (interrupt) error.StreamInterrupted else error.IncompleteFrame, result.failure.?);
        try std.testing.expectEqual(error.ControlRestoreFailed, result.control_restore.?);
        try std.testing.expectEqual(error.EffectRestoreFailed, result.effect_restore.?);
        try std.testing.expectEqualStrings("seAlmr", backend.events.items);
    }
}

test {
    _ = @import("stream_input");
}
