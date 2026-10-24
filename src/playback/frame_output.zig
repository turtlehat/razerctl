const command = @import("../interface/command.zig");
const devices = @import("../device/select.zig");
const device = @import("device_types");
const frames = @import("frame_session");
const ui = @import("ui");

pub const Selection = struct {
    desc: device.Descriptor,
    session: frames.Output,

    pub fn close(self: *Selection) void {
        self.session.close();
    }

    pub fn run(self: *Selection, context: command.Context, input: anytype, output: *ui.Output) !void {
        const frame = try context.allocator.alloc(u8, self.session.shape.frameSize());
        defer context.allocator.free(frame);
        const result = frames.run(&self.session.hid, &self.desc, self.session.shape, input, frame);
        try report(result, output);
    }
};

fn report(result: frames.Result, output: *ui.Output) !void {
    if (result.failure) |err| {
        if (err == error.StreamInterrupted)
            output.exit_code = 130
        else
            try output.writeError("frame playback stopped", err);
    }
    if (result.control_restore) |err|
        try output.writeError("failed to restore original lighting control state", err);
    if (result.effect_restore) |err|
        try output.writeError("failed to restore original lighting effect", err);
}

test "interruption is quiet while playback and restoration failures remain errors" {
    const std = @import("std");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var interrupted = ui.Output.init(arena.allocator());
    try report(.{ .failure = error.StreamInterrupted }, &interrupted);
    try std.testing.expectEqual(@as(u8, 130), interrupted.exit_code);
    try std.testing.expectEqual(@as(usize, 0), interrupted.err.items.len);

    var restored = ui.Output.init(arena.allocator());
    try report(.{
        .failure = error.StreamInterrupted,
        .control_restore = error.ControlRestoreFailed,
        .effect_restore = error.EffectRestoreFailed,
    }, &restored);
    try std.testing.expectEqual(@as(u8, 1), restored.exit_code);
    try std.testing.expectEqual(@as(usize, 2), restored.err.items.len);

    var failed = ui.Output.init(arena.allocator());
    try report(.{ .failure = error.SendFailed }, &failed);
    try std.testing.expectEqual(@as(u8, 1), failed.exit_code);
    try std.testing.expectEqualStrings("frame playback stopped", failed.err.items[0].message);
}

pub fn open(context: command.Context, spec: ?[]const u8, output: *ui.Output) !?Selection {
    const desc = switch (try devices.one(context.allocator, spec)) {
        .success => |value| value,
        .failure => |failure| {
            try output.writeError(failure.message, failure.err);
            return null;
        },
    };
    if (desc.features.lighting.protocol == null) {
        try output.writeError(try context.allocator.print("stream is not supported on {s}", .{desc.name}), null);
        return null;
    }
    const session = frames.Output.open(context.io, &desc) catch |err| {
        try output.writeError(try context.allocator.print("0x{x:0>4}: cannot open frame output", .{desc.pid}), err);
        return null;
    };
    return .{ .desc = desc, .session = session };
}
