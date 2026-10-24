const std = @import("std");
const ui = @import("ui");
const args = @import("interface/args.zig");
const commands = @import("commands.zig");

pub fn main(init: std.process.Init.Minimal) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var stderr = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const out = &stdout.interface;
    const err = &stderr.interface;

    const exit_code = run(arena.allocator(), io, init, out, err) catch |e| return fatal(out, err, e);

    // stderr is flushed even when stdout fails.
    const out_flushed = out.flush();

    err.flush() catch |e| return fatal(out, err, e);
    out_flushed catch |e| return fatal(out, err, e);
    return exit_code;
}

fn run(allocator: std.mem.Allocator, io: std.Io, init: std.process.Init.Minimal, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    const invocation = try args.parse(allocator, init.args);
    var output: ui.Output = .init(allocator);

    try commands.execute(allocator, io, init.environ, invocation, &output);
    try ui.render(out, err, output);
    return output.exit_code;
}

fn fatal(out: *std.Io.Writer, err: *std.Io.Writer, e: anyerror) u8 {
    out.flush() catch {};
    err.print("razerctl: {s}\n", .{@errorName(e)}) catch {};
    err.flush() catch {};
    return 1;
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(args);
    std.testing.refAllDecls(commands);
    std.testing.refAllDecls(ui);
    std.testing.refAllDecls(@import("device_types"));
    std.testing.refAllDecls(@import("setting_types"));
    std.testing.refAllDecls(@import("transport"));
}
