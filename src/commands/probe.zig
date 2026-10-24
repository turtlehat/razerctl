//! `probe`: reports what the hardware supports; reads only unless `--effects`.

const std = @import("std");
const device = @import("device_types");
const transport = @import("transport");
const settings = @import("settings");
const probe_result = @import("probe_result");
const ui = @import("ui");
const devices = @import("../device/select.zig");

const command = @import("../interface/command.zig");
pub const entry: command.Entry = .{
    .definition = .{
        .name = "probe",
        .note = "Scan device settings and show found capabilities",
        .grammar = .device,
        .options = &.{
            command.help_option,
            .{
                .name = "effects",
                .note = "Also test effect ids, restoring lighting afterwards.",
            },
        },
    },
    .execute = execute,
};

pub fn execute(context: command.Context, invocation: command.args.Invocation, output: *ui.Output) !void {
    const allocator = context.allocator;
    const desc = switch (try devices.one(allocator, if (invocation.arguments.len > 0) invocation.arguments[0] else null)) {
        .success => |value| value,
        .failure => |failure| return output.writeError(failure.message, failure.err),
    };
    var hid = transport.Device.open(context.io, desc.pid) catch |err|
        return output.writeError(try allocator.print("0x{x:0>4}: {s}", .{ desc.pid, transport.openErrorMessage(err) }), err);
    defer hid.close();
    var table = output.createTable(.{}, 0);

    switch (try probe(&table, &hid, &desc, invocation.hasOption("--effects"))) {
        .success => {},
        .failure => |failure| return output.writeError(failure.message, failure.err),
    }

    try output.writeTable(table);
}

pub fn probe(table: *ui.TableBuilder, hid: *transport.Device, desc: *const device.Descriptor, effects: bool) !ui.Result(void) {
    hid.acquire() catch |err|
        return .{ .failure = .{ .message = "probe: cannot lock device", .err = err } };
    defer hid.release();
    var result: probe_result.ProbeResult = .init(table);

    inline for (settings.names) |name| {
        const feature = settings.module(name);

        if (@hasDecl(feature, "probe"))
            try feature.probe(hid, &result);

        if (effects and @hasDecl(feature, "probeWrites")) {
            if (try feature.probeWrites(hid, desc, &result)) |failure|
                return .{ .failure = failure };
        }
    }

    return .{ .success = {} };
}
