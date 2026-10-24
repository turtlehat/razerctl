const std = @import("std");
const command = @import("../interface/command.zig");
const frame_output = @import("frame_output.zig");
const frames = @import("frame_session");
const chroma = @import("chroma");
const ui = @import("ui");
const Keyboard = @import("keyboard_input").Keyboard;

const Clock = struct {
    signals: *frames.Input,
    io: std.Io,
    keyboard: ?*Keyboard = null,

    pub fn input(self: *Clock, p: *const chroma.Profile, device: usize, tick: u64) !void {
        if (self.keyboard) |keyboard| try keyboard.drain(p, device, tick);
    }

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

pub fn play(context: command.Context, effect: *const chroma.Profile, output: *ui.Output) ui.Error!void {
    const index = 0;
    const device = effect.devices[index];
    const spec = try context.allocator.print("0x{x:0>4}", .{device.pid});
    var selected = (try frame_output.open(context, spec, output)) orelse return;
    defer selected.close();
    const shape = selected.session.shape;
    if (device.rows != shape.rows or device.columns != shape.columns)
        return output.writeError(try context.allocator.print(
            "ChromaEffects grid {d}x{d} does not match device grid {d}x{d}; no resizing is performed",
            .{ device.rows, device.columns, shape.rows, shape.columns },
        ), null);
    var keyboard: ?Keyboard = null;
    defer if (keyboard) |*source| source.deinit();
    if (effect.needsInput(index)) {
        keyboard = Keyboard.open(device.pid, &selected.session.hid, selected.desc.features.lighting, shape.rows, shape.columns) catch |err| fallback: {
            const message = if (err == error.KeyboardPermissionDenied)
                "warning: Reactive/Ripple inactive: keyboard access denied. On Linux, joining the input group and logging out/in may grant access; this grants access to keyboard events"
            else
                "warning: Reactive/Ripple inactive: cannot read keyboard input";
            try output.writeDiagnostic(.{ .message = message, .err = err });
            break :fallback null;
        };
    }
    if (effect.skipped_ambient)
        try output.writeDiagnostic(.{ .message = "warning: Ambient layers are unsupported and will be skipped" });
    if (effect.skipped_audio)
        try output.writeDiagnostic(.{ .message = "warning: Audiometer layers are unsupported and will be skipped" });
    // Playback can run indefinitely, so emit warnings before entering its loop.
    var stderr = std.Io.File.stderr().writerStreaming(context.io, &.{});
    try ui.renderDiagnostics(&stderr.interface, output.err.items);
    try stderr.interface.flush();
    output.err.clearRetainingCapacity();
    var signals = frames.Input.init() catch |err|
        return output.writeError("play: cannot initialize interruption handling", err);
    defer signals.deinit();
    if (effect.regions.len == 0) {
        waitForInterruption(context.io, &signals) catch |err| {
            if (err == error.StreamInterrupted) {
                output.exit_code = 130;
                return;
            }
            return output.writeError("playback stopped", err);
        };
        return;
    }
    var input: chroma.Player(Clock) = .{
        .profile = effect,
        .device = index,
        .clock = .{ .signals = &signals, .io = context.io, .keyboard = if (keyboard) |*source| source else null },
    };
    try selected.run(context, &input, output);
}

fn waitForInterruption(io: std.Io, signals: *frames.Input) !void {
    while (true) {
        try signals.check();
        try signals.wait(io, std.Io.Clock.awake.now(io).nanoseconds + std.time.ns_per_s);
    }
}
