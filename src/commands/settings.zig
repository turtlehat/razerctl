//! Device settings workflows; results are data for the interface to render.

const std = @import("std");
const args = @import("../interface/args.zig");
const ui = @import("ui");
const settings = @import("settings");
const transport = @import("transport");
const device = @import("device_types");
const command = @import("../interface/command.zig");
const devices = @import("../device/select.zig");

pub const entries = [_]command.Entry{
    .{
        .definition = .{
            .name = "get",
            .note = "Show device information and settings",
            .grammar = .{ .settings = .get },
            .options = &.{
                command.help_option,
                .{
                    .name = "json",
                    .note = "JSON output, including single settings.",
                },
            },
            .help = .{ .description = "No selectors reads everything; one setting prints a bare value." },
        },
        .execute = executeGet,
    },
    .{
        .definition = .{
            .name = "set",
            .note = "Change device settings",
            .grammar = .{ .settings = .set },
            .options = &.{
                command.help_option,
                .{
                    .name = "save",
                    .note = "Save applied settings for restore.",
                },
            },
            .help = .{
                .settings = .values,
                .feature_references = true,
            },
        },
        .execute = executeSet,
    },
    .{
        .definition = .{
            .name = "save",
            .note = "Save device settings for restore",
            .grammar = .{ .settings = .save },
            .help = .{
                .description = "Without selectors, saves all restorable settings. Does not change hardware.",
            },
        },
        .execute = executeSave,
    },
    .{
        .definition = .{
            .name = "restore",
            .note = "Restore saved device settings",
            .grammar = .{ .settings = .restore },
            .help = .{
                .description = "Without selectors, restores all saved settings.",
            },
        },
        .execute = executeRestore,
    },
};

const Prepared = struct {
    desc: device.Descriptor,
    operations: []settings.Operation,
};

fn prepare(context: command.Context, invocation: args.Invocation, action: settings.Action, excluded: []const []const u8) !ui.Result(Prepared) {
    const allocator = context.allocator;

    const desc = switch (try devices.one(allocator, if (invocation.arguments.len > 0) invocation.arguments[0] else null)) {
        .success => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };

    const operations = switch (try settings.prepare(allocator, &desc, try invocation.optionWordsExcept(allocator, excluded), action)) {
        .success => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };

    return .{ .success = .{ .desc = desc, .operations = operations } };
}

fn openDevice(context: command.Context, allocator: std.mem.Allocator, desc: device.Descriptor) !ui.Result(transport.Device) {
    const hid = transport.Device.open(context.io, desc.pid) catch |err|
        return .{ .failure = .{
            .message = try allocator.print("0x{x:0>4}: {s}", .{ desc.pid, transport.openErrorMessage(err) }),
            .err = err,
        } };

    return .{ .success = hid };
}

pub fn executeGet(context: command.Context, invocation: args.Invocation, output: *ui.Output) !void {
    const allocator = context.allocator;
    const prepared = switch (try prepare(context, invocation, .get, &.{"--json"})) {
        .success => |value| value,
        .failure => |failure| return output.writeError(failure.message, failure.err),
    };

    if (!try settings.hasReadable(allocator, &prepared.desc))
        return output.writeError(try allocator.print("get is not supported on {s}", .{prepared.desc.name}), null);

    var hid = switch (try openDevice(context, allocator, prepared.desc)) {
        .success => |value| value,
        .failure => |failure| return output.writeError(failure.message, failure.err),
    };
    defer hid.close();

    switch (try executeGetWithDevice(allocator, &hid, &prepared.desc, prepared.operations)) {
        .success => |fields| try addReadOutput(output, fields, if (invocation.hasOption("--json")) .json else .text, prepared.operations.len > 0),
        .failure => |failure| try output.writeError(failure.message, failure.err),
    }
}

fn executeGetWithDevice(allocator: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, operations: []const settings.Operation) !ui.Result(ui.Fields) {
    const fields = switch (try if (operations.len == 0)
        settings.fullRead(allocator, hid, desc)
    else
        settings.get(allocator, hid, desc, operations)) {
        .success => |value| value,
        .failure => |failure| return .{ .failure = failure },
    };

    return .{ .success = fields };
}

pub fn executeSet(context: command.Context, invocation: args.Invocation, output: *ui.Output) !void {
    const allocator = context.allocator;
    const prepared = switch (try prepare(context, invocation, .set, &.{"--save"})) {
        .success => |value| value,
        .failure => |failure| return try output.writeError(failure.message, failure.err),
    };
    var hid = switch (try openDevice(context, allocator, prepared.desc)) {
        .success => |value| value,
        .failure => |failure| return output.writeError(failure.message, failure.err),
    };
    defer hid.close();

    if (try settings.apply(allocator, &hid, context.environ, &prepared.desc, prepared.operations, invocation.hasOption("--save"))) |failure|
        return output.writeError(failure.message, failure.err);
}

pub fn executeSave(context: command.Context, invocation: args.Invocation, output: *ui.Output) !void {
    const allocator = context.allocator;
    const prepared = switch (try prepare(context, invocation, .save, &.{})) {
        .success => |value| value,
        .failure => |failure| return output.writeError(failure.message, failure.err),
    };
    var hid = switch (try openDevice(context, allocator, prepared.desc)) {
        .success => |value| value,
        .failure => |failure| return output.writeError(failure.message, failure.err),
    };
    defer hid.close();

    if (try settings.save(allocator, &hid, context.environ, &prepared.desc, prepared.operations)) |failure|
        return output.writeError(failure.message, failure.err);
}

pub fn executeRestore(context: command.Context, invocation: args.Invocation, output: *ui.Output) !void {
    const allocator = context.allocator;
    const prepared = switch (try prepare(context, invocation, .restore, &.{})) {
        .success => |value| value,
        .failure => |failure| return output.writeError(failure.message, failure.err),
    };

    if (!try settings.hasWritable(allocator, &prepared.desc))
        return output.writeError(try allocator.print("restore is not supported on {s}", .{prepared.desc.name}), null);

    var hid = switch (try openDevice(context, allocator, prepared.desc)) {
        .success => |value| value,
        .failure => |failure| return output.writeError(failure.message, failure.err),
    };
    defer hid.close();

    if (try settings.restore(allocator, &hid, context.environ, &prepared.desc, prepared.operations)) |failure|
        return output.writeError(failure.message, failure.err);
}

fn addReadOutput(output: *ui.Output, fields: ui.Fields, format: ui.Format, selected: bool) !void {
    try output.writeFields(fields, format, selected);

    if (!selected and fields.misses > 0) {
        for (fields.diagnostics.items) |failure|
            try output.writeError(failure.message, failure.err);

        try output.writeError(try output.allocator.print("{d} setting read(s) failed; output is incomplete", .{fields.misses}), null);
    }
}

test "grouped settings preserve color gamma suffix and device-specific validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const desc = devices.find("0x02b6").?;
    const inv = try args.group(a, &.{ "set", "0x02b6", "--effect", "static", "255,0,0,2.2", "--save" });
    const operations = (try settings.prepare(a, &desc, try inv.optionWordsExcept(a, &.{"--save"}), .set)).success;

    try std.testing.expectEqual(@as(usize, 1), operations.len);
    try std.testing.expectEqualStrings("255,0,0,2.2", operations[0].args[1]);
    try std.testing.expect(inv.hasOption("--save"));
    const unknown = try settings.prepare(a, &desc, &.{ "--nonexistent", "1" }, .set);

    try std.testing.expect(unknown == .failure);
    const duplicate = try settings.prepare(a, &desc, &.{ "--brightness", "20", "--brightness", "30" }, .set);

    try std.testing.expect(duplicate == .failure);
}

test "command selected read failures keep callback causes and validation precedes device open" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Stub = struct {
        fn read(_: std.mem.Allocator, _: *transport.Device, _: *const device.Descriptor, _: u8) !settings.Reading {
            return error.NamedCommandReadFailure;
        }
    };
    var hid: transport.Device = .{ .handle = undefined, .pid = 0x02b6, .io = std.testing.io, .lock = try .open(0xfffd) };
    defer hid.lock.close();
    const desc = devices.find("0x02b6").?;
    const context: command.Context = .{
        .allocator = allocator,
        .io = std.testing.io,
        .environ = .empty,
        .root = .{ .name = "razerctl", .note = "" },
        .definitions = &.{},
    };
    const failure = (try executeGetWithDevice(allocator, &hid, &desc, &.{
        .{ .setting = .{ .usage = .{ .name = "test" }, .read = Stub.read }, .args = &.{} },
    })).failure;

    try std.testing.expectEqual(error.NamedCommandReadFailure, failure.err.?);
    try std.testing.expectEqualStrings("--test: read failed", failure.message);
    var output: ui.Output = .init(allocator);

    try executeSet(context, try args.group(allocator, &.{ "set", "0x02b6", "--brightness", "101" }), &output);
    try std.testing.expectEqual(@as(u8, 1), output.exit_code);
    try std.testing.expect(output.err.items[0].err == null);
    try std.testing.expectEqualStrings("brightness: expected <0-100> -- got '101'", output.err.items[0].message);
}

test "partial full-read output preserves structured causes and explicit failure status in text and JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fields: ui.Fields = .init(allocator);

    try fields.add(.{ .label = "brightness", .val = .{ .num = 30 } });
    try fields.missWithCause(.{ .message = "--test: read failed", .err = error.NamedPartialReadFailure });
    fields.miss();

    for ([_]ui.Format{ .text, .json }) |format| {
        var output: ui.Output = .init(allocator);

        try addReadOutput(&output, fields, format, false);
        try std.testing.expectEqual(@as(u8, 1), output.exit_code);
        try std.testing.expectEqual(error.NamedPartialReadFailure, output.err.items[0].err.?);
        try std.testing.expect(output.err.items[1].err == null);
        var stdout: std.Io.Writer.Allocating = .init(allocator);
        var stderr: std.Io.Writer.Allocating = .init(allocator);

        try ui.render(&stdout.writer, &stderr.writer, output);

        if (format == .text)
            try std.testing.expectEqualStrings("brightness 30\n", stdout.written())
        else {
            const json = try std.json.parseFromSlice(std.json.Value, allocator, stdout.written(), .{});

            try std.testing.expectEqual(@as(i64, 30), json.value.object.get("brightness").?.integer);
        }

        try std.testing.expectEqualStrings("razerctl: --test: read failed - 'NamedPartialReadFailure'\nrazerctl: 2 setting read(s) failed; output is incomplete\n", stderr.written());
    }
}
