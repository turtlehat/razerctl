const std = @import("std");
const command = @import("../interface/command.zig");
const frame_output = @import("../playback/frame_output.zig");
const frames = @import("frame_session");
const polychromatic = @import("polychromatic");
const ui = @import("ui");
const devices = @import("../device/select.zig");
const chroma_playback = @import("../playback/chroma_playback.zig");
const chroma = @import("chroma");

pub const entry: command.Entry = .{
    .definition = .{
        .name = "play",
        .note = "Play a Polychromatic or ChromaEffects file",
        .grammar = .device_file,
        .help = .{ .description = "Play a Polychromatic or ChromaEffects file. Restores the original effect on exit." },
    },
    .execute = execute,
};

const Clock = struct {
    io: std.Io,
    signals: *frames.Input,

    pub fn check(self: *Clock) !void {
        try self.signals.check();
    }

    pub fn now(self: *Clock) i96 {
        return std.Io.Clock.awake.now(self.io).nanoseconds;
    }

    pub fn wait(self: *Clock, deadline: i96) !void {
        try self.signals.wait(self.io, deadline);
    }
};

pub fn execute(context: command.Context, invocation: command.args.Invocation, output: *ui.Output) ui.Error!void {
    const filename = invocation.arguments[invocation.arguments.len - 1];
    const allocator = std.heap.page_allocator;
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, filename, allocator, .limited(64 * 1024 * 1024)) catch |err|
        return output.writeError(try context.allocator.print("cannot read effect file: {s}", .{filename}), err);
    var text_owned = true;
    defer if (text_owned) allocator.free(text);
    const kind = detect(allocator, text) catch |err|
        return output.writeError("unrecognized or ambiguous effect file; expected Polychromatic or ChromaEffects JSON", err);
    if (kind == .chroma) {
        const desc = switch (try devices.one(context.allocator, entry.definition.deviceSpec(invocation))) {
            .success => |desc| desc,
            .failure => |failure| return output.writeError(failure.message, failure.err),
        };
        const seconds = @divFloor(std.Io.Clock.real.now(context.io).nanoseconds, std.time.ns_per_s);
        const seed: u32 = @truncate(@as(u64, @intCast(@max(0, @divTrunc(seconds, 1800000) * 1800000))));
        var effect = chroma.parseForDevice(allocator, text, seed, desc.pid) catch |err| {
            if (err == error.ChromaDeviceNotListed)
                return output.writeError(try context.allocator.print("device 0x{x:0>4} is not listed in the ChromaEffects file", .{desc.pid}), null);
            return output.writeError("invalid or unsupported ChromaEffects profile", err);
        };
        defer effect.deinit();
        allocator.free(text);
        text_owned = false;
        return chroma_playback.play(context, &effect, output);
    }
    var sequence = polychromatic.Sequence.parse(allocator, text) catch |err|
        return output.writeError("invalid Polychromatic sequence (requires type 3, save_format 8)", err);
    defer sequence.deinit();
    allocator.free(text);
    text_owned = false;
    var signals = frames.Input.init() catch |err|
        return output.writeError("play: cannot initialize interruption handling", err);
    defer signals.deinit();
    var selected = (try frame_output.open(context, entry.definition.deviceSpec(invocation), output)) orelse return;
    defer selected.close();
    const shape = selected.session.shape;
    if (!sequence.matches(shape.rows, shape.columns))
        return output.writeError(try context.allocator.print(
            "animation grid {d}x{d} does not match device grid {d}x{d} (rows x columns); no resizing is performed",
            .{ sequence.rows, sequence.columns, shape.rows, shape.columns },
        ), null);
    const clock: Clock = .{ .io = context.io, .signals = &signals };
    var player: polychromatic.Player(Clock) = .{
        .sequence = &sequence,
        .clock = clock,
    };
    try selected.run(context, &player, output);
}

const Format = enum { polychromatic, chroma };

fn detect(allocator: std.mem.Allocator, text: []const u8) !Format {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.UnknownEffectFormat;
    const profiles = parsed.value.object.contains("profiles");
    const frames_present = parsed.value.object.contains("frames");
    if (profiles == frames_present) return error.UnknownEffectFormat;
    return if (profiles) .chroma else .polychromatic;
}

test "play detects contents rather than filenames and rejects ambiguous formats" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Format.chroma, try detect(a, "{\"profiles\":[]}"));
    try std.testing.expectEqual(Format.polychromatic, try detect(a, "{\"frames\":[]}"));
    try std.testing.expectError(error.UnknownEffectFormat, detect(a, "{\"profiles\":[],\"frames\":[]}"));
    try std.testing.expectError(error.UnknownEffectFormat, detect(a, "{}"));
}
