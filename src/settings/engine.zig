//! Settings engine: prepares requests and runs reads, writes, saves and restores.

const std = @import("std");
const device = @import("device_types");
const transport = @import("transport");
const ui = @import("ui");
const saved = @import("saved");
const setting_types = @import("setting_types");

const registry = @import("registry");

pub const Reading = setting_types.Reading;
pub const Input = setting_types.Input;
pub const Setting = setting_types.Setting;
pub const Operation = setting_types.Operation;
pub const Action = setting_types.Action;
pub const Settings = setting_types.Settings;
pub const selectable = setting_types.selectable;

pub const names = blk: {
    const decls = @typeInfo(registry.features).@"struct".decl_names;
    var list: [decls.len][]const u8 = undefined;

    for (decls, 0..) |d, i| {
        var j = i;

        while (j > 0 and module(list[j - 1]).order > module(d).order) : (j -= 1)
            list[j] = list[j - 1];

        list[j] = d;
    }

    const final = list;

    break :blk final;
};

pub fn module(comptime name: []const u8) type {
    return @field(registry.features, name);
}

/// A device's settings, built once in declaration order for lookup and ordering.
pub const Catalog = struct {
    items: []const Setting,

    pub fn init(allocator: std.mem.Allocator, desc: *const device.Descriptor) !Catalog {
        var list: Settings = .init(allocator);

        inline for (names) |name|
            try module(name).settings(desc, &list);

        return .{ .items = list.items.items };
    }

    pub fn find(catalog: Catalog, name: []const u8) ?Setting {
        for (catalog.items) |s|
            if (std.mem.eql(u8, s.usage.name, name))
                return s;

        return null;
    }
};

/// Validate the whole request before opening the device or writing anything.
pub fn prepare(allocator: std.mem.Allocator, desc: *const device.Descriptor, words: []const [:0]const u8, action: Action) !ui.Result([]Operation) {
    const writing = action == .set;

    if (words.len == 0) {
        if (writing)
            return .{ .failure = .{ .message = "set needs at least one setting -- see `razerctl set --help`" } };

        return .{ .success = &.{} };
    }

    const catalog: Catalog = try .init(allocator, desc);
    var operations: std.ArrayList(Operation) = .empty;
    var i: usize = 0;

    while (i < words.len) {
        const word = words[i];

        if (!std.mem.startsWith(u8, word, "--"))
            return .{ .failure = .{ .message = try allocator.print("expected a setting option -- got '{s}'", .{word}) } };

        const s = catalog.find(word[2..]) orelse
            return .{ .failure = .{ .message = try allocator.print("'{s}' is not supported on {s}", .{ word, desc.name }) } };

        for (operations.items) |op|
            if (std.mem.eql(u8, op.setting.usage.name, s.usage.name))
                return .{ .failure = .{ .message = try allocator.print("'{s}' was given more than once", .{word}) } };

        if (writing and s.write == null)
            return .{ .failure = .{ .message = try allocator.print("{s} is read-only", .{word}) } };

        if (!selectable(s, action))
            return .{ .failure = .{ .message = try allocator.print("{s} cannot be used with {s}", .{ word, @tagName(action) }) } };

        const start = i + 1;

        i = switch (try valuesEnd(allocator, s, words, start, writing)) {
            .success => |end| end,
            .failure => |failure| return .{ .failure = failure },
        };
        const values = words[start..i];

        if (!writing and values.len > 0)
            return .{ .failure = .{ .message = try allocator.print("{s} {s} takes no value", .{ @tagName(action), word }) } };

        const input = if (writing) switch (try s.parse(allocator, desc, values)) {
            .success => |value| value,
            .failure => |failure| return .{ .failure = failure },
        } else Input.none;

        try operations.append(allocator, .{ .setting = s, .args = values, .input = input });
    }

    if (!writing)
        return .{ .success = operations.items };

    // Feature declaration order puts mode before its dependent settings.
    var next: usize = 0;

    for (catalog.items) |s| {
        for (operations.items[next..], next..) |op, index| {
            if (!std.mem.eql(u8, s.usage.name, op.setting.usage.name))
                continue;

            std.mem.swap(Operation, &operations.items[next], &operations.items[index]);
            next += 1;
            break;
        }
    }

    return .{ .success = operations.items };
}

/// Index past the values of the setting at `words[start]`, its own flags included; only `set` reads past one flag.
fn valuesEnd(allocator: std.mem.Allocator, s: Setting, words: []const [:0]const u8, start: usize, writing: bool) !ui.Result(usize) {
    var i = start;

    while (i < words.len) {
        if (!std.mem.startsWith(u8, words[i], "--")) {
            i += 1;
            continue;
        }

        const f = flagNamed(s.usage.flags, words[i][2..]) orelse break;

        for (words[start..i]) |previous|
            if (std.mem.eql(u8, previous, words[i]))
                return .{ .failure = .{ .message = try allocator.print("'{s}' was given more than once", .{words[i]}) } };

        i += 1;

        if (f.param != null) {
            if (i >= words.len or std.mem.startsWith(u8, words[i], "--"))
                return .{ .failure = .{ .message = try allocator.print("--{s} needs a value", .{f.name}) } };

            i += 1;
        }

        if (!writing)
            break;
    }

    return .{ .success = i };
}

fn flagNamed(flags: []const ui.Flag, name: []const u8) ?ui.Flag {
    for (flags) |f|
        if (std.mem.eql(u8, f.name, name))
            return f;

    return null;
}

pub fn apply(allocator: std.mem.Allocator, hid: *transport.Device, environ: std.process.Environ, desc: *const device.Descriptor, operations: []const Operation, persist: bool) !?ui.Failure {
    hid.acquire() catch |err|
        return .{ .message = "set: cannot lock device; no settings applied", .err = err };
    defer hid.release();
    var store: ?saved.Store = if (persist) try .init(allocator, hid.io, environ, desc.pid) else null;
    defer if (store) |*destination| destination.close();

    for (operations, 0..) |op, i| {
        op.setting.write.?(allocator, hid, desc, op.setting.ctx, op.input) catch |err|
            return .{
                .message = try allocator.print("--{s}: write failed; {d} earlier setting(s) applied, {d} later setting(s) not attempted; the failing setting may be partially applied", .{ op.setting.usage.name, i, operations.len - i - 1 }),
                .err = err,
            };

        if (store) |*destination|
            if (try destination.recordAll(&.{.{ .name = op.setting.usage.name, .args = op.args }})) |failure|
                return .{
                    .message = try allocator.print("--{s} was applied but could not be saved: {s}; {d} setting(s) applied, {d} later setting(s) not attempted", .{ op.setting.usage.name, failure.message, i + 1, operations.len - i - 1 }),
                    .err = failure.err,
                };
    }

    return null;
}

pub fn get(allocator: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, operations: []const Operation) !ui.Result(ui.Fields) {
    var fields: ui.Fields = .init(allocator);

    for (operations) |op| {
        const s = op.setting;
        const reading = readSetting(allocator, hid, desc, s) catch |err|
            return .{ .failure = .{
                .message = try allocator.print("--{s}: read failed", .{s.usage.name}),
                .err = err,
            } };
        try fields.add(field(s, reading));
    }

    return .{ .success = fields };
}

/// The no-selector read includes feature-specific aggregate fields, such as
/// the cooling pad's preset slots, in feature order.
pub fn fullRead(allocator: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor) !ui.Result(ui.Fields) {
    var fields: ui.Fields = .init(allocator);

    try readFields(hid, desc, &fields);

    if (fields.len() == 0 and fields.misses > 0) {
        if (fields.diagnostics.items.len > 0)
            return .{ .failure = fields.diagnostics.items[0] };

        return .{ .failure = .{ .message = "get: cannot read settings", .err = transport.Error.ReadFailed } };
    }
    return .{ .success = fields };
}

/// Capture only settings that can be both read and written. Read everything
/// first so a failed capture does not save a partial snapshot.
pub fn save(allocator: std.mem.Allocator, hid: *transport.Device, environ: std.process.Environ, desc: *const device.Descriptor, selected: []const Operation) !?ui.Failure {
    hid.acquire() catch |err|
        return .{ .message = "save: cannot lock device; nothing saved", .err = err };
    defer hid.release();
    var snapshot: std.ArrayList(saved.Entry) = .empty;

    inline for (names) |name|
        for (try settings(allocator, desc, name)) |s| {
            if (!selectable(s, .save) or !included(selected, s.usage.name))
                continue;

            const entry = switch (try capture(allocator, hid, desc, s)) {
                .success => |value| value,
                .failure => |failure| return failure,
            };

            try snapshot.append(allocator, entry);
        };

    if (snapshot.items.len == 0)
        return .{ .message = try allocator.print("no settings can be captured on {s}", .{desc.name}) };

    return saved.recordAll(allocator, hid.io, environ, desc.pid, snapshot.items);
}

fn capture(allocator: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, s: Setting) !ui.Result(saved.Entry) {
    const reading = s.read.?(allocator, hid, desc, s.ctx) catch |err|
        return .{ .failure = .{
            .message = try allocator.print("save --{s}: read failed; nothing saved", .{s.usage.name}),
            .err = err,
        } };
    const values = try split(allocator, try ui.bareText(allocator, field(s, reading)));

    switch (try s.parse(allocator, desc, values)) {
        .success => {},
        .failure => |failure| return .{ .failure = .{
            .message = try allocator.print("save --{s}: {s}", .{ s.usage.name, failure.message }),
            .err = failure.err,
        } },
    }

    return .{ .success = .{ .name = s.usage.name, .args = values } };
}

fn included(selected: []const Operation, name: []const u8) bool {
    if (selected.len == 0)
        return true;

    for (selected) |op|
        if (std.mem.eql(u8, op.setting.usage.name, name))
            return true;

    return false;
}

pub fn settings(allocator: std.mem.Allocator, desc: *const device.Descriptor, comptime name: []const u8) ![]const Setting {
    var s: Settings = .init(allocator);

    try module(name).settings(desc, &s);
    return s.items.items;
}

pub fn hasReadable(allocator: std.mem.Allocator, desc: *const device.Descriptor) !bool {
    inline for (names) |name| {
        const list = try settings(allocator, desc, name);

        if (list.len > 0 and @hasDecl(module(name), "readFields"))
            return true;

        for (list) |s|
            if (s.read != null)
                return true;
    }

    return false;
}

test "readability includes aggregate-only features but not empty descriptors" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try std.testing.expect(try hasReadable(arena.allocator(), try descriptorByPid(0x02b6)));
    try std.testing.expect(try hasReadable(arena.allocator(), &test_cooling_device));

    const empty: device.Descriptor = .{ .pid = 0, .name = "Empty", .category = .system };

    try std.testing.expect(!try hasReadable(arena.allocator(), &empty));
}

fn readSetting(allocator: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, s: Setting) !Reading {
    try hid.acquire();
    defer hid.release();

    return s.read.?(allocator, hid, desc, s.ctx);
}

fn readFields(hid: *transport.Device, desc: *const device.Descriptor, fields: *ui.Fields) !void {
    const allocator = fields.allocator;

    inline for (names) |name| {
        const list = try settings(allocator, desc, name);

        for (list) |s| {
            if (s.read == null)
                continue;

            const reading = readSetting(allocator, hid, desc, s) catch |err| {
                try fields.missWithCause(.{
                    .message = try allocator.print("--{s}: read failed", .{s.usage.name}),
                    .err = err,
                });
                continue;
            };

            try fields.add(field(s, reading));
        }

        if (list.len > 0 and @hasDecl(module(name), "readFields")) aggregate: {
            hid.acquire() catch |err| {
                try fields.missWithCause(.{
                    .message = try allocator.print("{s}: cannot lock device for aggregate read", .{name}),
                    .err = err,
                });
                break :aggregate;
            };
            defer hid.release();

            try module(name).readFields(hid, desc, fields);
        }
    }
}

fn field(s: Setting, r: Reading) ui.Field {
    return .{ .label = s.usage.name, .val = r.val, .unit = s.unit, .note = r.note };
}

pub fn hasWritable(allocator: std.mem.Allocator, desc: *const device.Descriptor) !bool {
    inline for (names) |name| {
        for (try settings(allocator, desc, name)) |s|
            if (s.write != null)
                return true;
    }

    return false;
}

/// Replays the saved settings, writing only what the device has lost.
pub fn restore(allocator: std.mem.Allocator, hid: *transport.Device, environ: std.process.Environ, desc: *const device.Descriptor, selected: []const Operation) !?ui.Failure {
    const text = switch (try saved.load(allocator, hid.io, environ, desc.pid)) {
        .success => |contents| contents,
        .failure => |failure| return failure,
    };
    const operations = switch (try restorePlan(allocator, desc, text, selected)) {
        .success => |value| value,
        .failure => |failure| return failure,
    };

    return restoreOperations(allocator, hid, desc, operations);
}

fn restoreOperations(allocator: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, operations: []const Operation) !?ui.Failure {
    hid.acquire() catch |err|
        return .{ .message = "restore: cannot lock device; no settings applied", .err = err };
    defer hid.release();
    var applied: usize = 0;

    for (operations, 0..) |op, i| {
        const value = try std.mem.join(allocator, " ", op.args);

        const held = holds(allocator, hid, desc, op.setting, value) catch |err|
            return .{
                .message = try allocator.print("restore --{s}: read failed; {d} earlier setting(s) applied, this and {d} later setting(s) not attempted", .{ op.setting.usage.name, applied, operations.len - i - 1 }),
                .err = err,
            };

        if (held)
            continue;

        op.setting.write.?(allocator, hid, desc, op.setting.ctx, op.input) catch |err|
            return .{
                .message = try allocator.print("restore --{s}: write failed; {d} earlier setting(s) applied, {d} later setting(s) not attempted; the failing setting may be partially applied", .{ op.setting.usage.name, applied, operations.len - i - 1 }),
                .err = err,
            };
        applied += 1;
    }

    return null;
}

fn restorePlan(allocator: std.mem.Allocator, desc: *const device.Descriptor, text: []const u8, selected: []const Operation) !ui.Result([]Operation) {
    var words: std.ArrayList([:0]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |line| {
        if (line.len == 0)
            continue;

        const cmd = saved.word(line);

        if (!included(selected, cmd))
            continue;

        try words.append(allocator, try allocator.dupeSentinel(u8, try allocator.print("--{s}", .{cmd}), 0));
        try words.appendSlice(allocator, try split(allocator, line[cmd.len..]));
    }

    for (selected) |op| {
        var found = false;
        var saved_lines = std.mem.splitScalar(u8, text, '\n');

        while (saved_lines.next()) |line|
            if (std.mem.eql(u8, saved.word(line), op.setting.usage.name)) {
                found = true;
                break;
            };

        if (!found)
            return .{ .failure = .{ .message = try allocator.print("no saved value for --{s}", .{op.setting.usage.name}) } };
    }

    if (words.items.len == 0)
        return .{ .success = &.{} };

    return prepare(allocator, desc, words.items, .set);
}

fn holds(allocator: std.mem.Allocator, hid: *transport.Device, desc: *const device.Descriptor, s: Setting, val: []const u8) !bool {
    const r = s.read orelse return false;
    const reading = try r(allocator, hid, desc, s.ctx);

    return std.mem.eql(u8, try ui.bareText(allocator, field(s, reading)), val);
}

fn split(allocator: std.mem.Allocator, text: []const u8) ![]const [:0]const u8 {
    var list: std.ArrayList([:0]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, text, ' ');

    while (words.next()) |w|
        try list.append(allocator, try allocator.dupeSentinel(u8, w, 0));

    return list.items;
}

fn mustPrepare(result: ui.Result([]Operation)) ![]Operation {
    return switch (result) {
        .success => |operations| operations,
        .failure => |failure| {
            std.debug.print("unexpected failure: {s}\n", .{failure.message});
            return error.TestUnexpectedResult;
        },
    };
}

fn descriptorByPid(pid: u16) !*const device.Descriptor {
    for (&registry.devices) |*descriptor|
        if (descriptor.pid == pid)
            return descriptor;

    return error.TestUnexpectedResult;
}

const test_cooling_device: device.Descriptor = .{
    .pid = 0,
    .name = "Test cooling device",
    .category = .accessory,
    .features = .{
        .cooling_performance = .{
            .presets = &.{.{ .name = "low", .wire = 0, .min = 500, .max = 2000 }},
            .scale = 50,
        },
    },
};

test "setting request validation returns contextual diagnostics before execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const desc = try descriptorByPid(0x02b6);
    const repeated = try prepare(allocator, desc, &.{ "--brightness", "30", "--brightness", "40" }, .set);

    try std.testing.expectEqualStrings("'--brightness' was given more than once", repeated.failure.message);
    try std.testing.expect(repeated.failure.err == null);

    const invalid_effect = try prepare(allocator, desc, &.{ "--effect", "not-an-effect" }, .set);

    try std.testing.expect(std.mem.startsWith(u8, invalid_effect.failure.message, "effect: expected <off|static|breathing|spectrum|wave|reactive|ripple|starlight|fire>"));
    try std.testing.expect(invalid_effect.failure.err == null);

    const both = try prepare(allocator, desc, &.{ "--custom-max-fan", "on", "--charge-override", "on" }, .set);

    try std.testing.expect(both == .success);
}

test "set validates and orders dependencies before applying" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const desc = try descriptorByPid(0x02b6);
    const ops = try mustPrepare(try prepare(allocator, desc, &.{ "--fan", "auto", "--custom-gpu", "high", "--custom-cpu", "boost", "--mode", "custom" }, .set));

    try std.testing.expectEqual(@as(usize, 4), ops.len);
    try std.testing.expectEqualStrings("mode", ops[0].setting.usage.name);
    try std.testing.expectEqualStrings("custom-cpu", ops[1].setting.usage.name);
    try std.testing.expectEqualStrings("custom-gpu", ops[2].setting.usage.name);
    try std.testing.expectEqualStrings("fan", ops[3].setting.usage.name);
    try std.testing.expectEqualStrings("auto", ops[3].input.word);
}

test "catalog retains feature order and owns stack-built parameter descriptors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const desc = try descriptorByPid(0x02b6);
    const catalog: Catalog = try .init(allocator, desc);
    var i: usize = 0;

    inline for (names) |name|
        for (try settings(allocator, desc, name)) |s| {
            try std.testing.expectEqualStrings(s.usage.name, catalog.items[i].usage.name);
            try std.testing.expectEqualDeep(s.usage.params, catalog.items[i].usage.params);
            i += 1;
        };

    try std.testing.expectEqual(i, catalog.items.len);
    try std.testing.expect(catalog.find("not-a-setting") == null);
    try std.testing.expectEqual(@as(u16, 30), (try catalog.find("brightness").?.parse(allocator, desc, &.{"30"})).success.num);
}

test "setting parsing combines shared grammar and feature validation for captures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Stub = struct {
        fn read(_: std.mem.Allocator, _: *transport.Device, _: *const device.Descriptor, _: u8) !Reading {
            return .{ .val = .{ .num = 7 } };
        }
        fn prepare(_: std.mem.Allocator, _: *const device.Descriptor, _: u8, input: Input) ui.Error!ui.Result(Input) {
            return if (input.num % 2 == 0) .{ .success = input } else .{ .failure = .{ .message = "needs an even value" } };
        }
    };
    const desc = try descriptorByPid(0x02b6);
    const s: Setting = .{
        .usage = .{ .name = "example", .params = &.{.{ .arg = .{ .range = .{ .min = 0, .max = 10 } } }} },
        .read = Stub.read,
        .prepare = Stub.prepare,
    };

    try std.testing.expectEqual(@as(u16, 8), (try s.parse(allocator, desc, &.{"8"})).success.num);
    try std.testing.expectEqualStrings("needs an even value", (try s.parse(allocator, desc, &.{"7"})).failure.message);
    try std.testing.expectEqualStrings("example: expected <0-10> -- got '11'", (try s.parse(allocator, desc, &.{"11"})).failure.message);
    var hid: transport.Device = .{ .handle = undefined, .pid = desc.pid, .io = std.testing.io, .lock = undefined };

    try std.testing.expectEqualStrings("save --example: needs an even value", (try capture(allocator, &hid, desc, s)).failure.message);
}

test "get preserves selection order and supports writable capture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const desc = try descriptorByPid(0x02b6);
    const ops = try mustPrepare(try prepare(allocator, desc, &.{ "--gpu-temp", "--cpu-temp" }, .get));

    try std.testing.expectEqualStrings("gpu-temp", ops[0].setting.usage.name);
    try std.testing.expectEqualStrings("cpu-temp", ops[1].setting.usage.name);
    try std.testing.expectEqual(@as(usize, 0), (try mustPrepare(try prepare(allocator, desc, &.{}, .get))).len);
    try std.testing.expectEqual(@as(usize, 1), (try mustPrepare(try prepare(allocator, desc, &.{"--brightness"}, .save))).len);
}

test "effect values stop at the next setting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const desc = try descriptorByPid(0x02b6);
    const ops = try mustPrepare(try prepare(allocator, desc, &.{ "--effect", "static", "#00ff00,2.8", "--brightness", "30" }, .set));

    try std.testing.expectEqual(@as(usize, 2), ops.len);
    try std.testing.expectEqualStrings("brightness", ops[0].setting.usage.name);
    try std.testing.expectEqualStrings("effect", ops[1].setting.usage.name);
    try std.testing.expectEqual(@as(usize, 2), ops[1].args.len);
}

test "pad's optional preset values and no-value writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const desc = &test_cooling_device;
    const ops = try mustPrepare(try prepare(allocator, desc, &.{ "--fan-low", "--fan-off" }, .set));

    try std.testing.expectEqual(@as(usize, 2), ops.len);
    try std.testing.expectEqual(Input.none, ops[0].input);
    try std.testing.expectEqual(Input.none, ops[1].input);
}

test "apply runs all prepared writes without saving when requested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Stub = struct {
        var seen: [2]u16 = undefined;
        var count: usize = 0;
        fn write(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, ctx: u8, input: Input) !void {
            try std.testing.expectEqual(@as(usize, 1), hid.lock.depth);
            seen[count] = @as(u16, ctx) * 100 + input.num;
            count += 1;
        }
    };

    Stub.count = 0;
    var hid: transport.Device = .{ .handle = undefined, .pid = 0x02b6, .io = std.testing.io, .lock = try .open(0xfffe) };
    defer hid.lock.close();
    const desc = try descriptorByPid(0x02b6);
    const diagnostic = try apply(allocator, &hid, .empty, desc, &.{
        .{
            .setting = .{ .usage = .{ .name = "first" }, .ctx = 1, .write = Stub.write },
            .args = &.{"30"},
            .input = .{ .num = 30 },
        },
        .{
            .setting = .{ .usage = .{ .name = "second" }, .ctx = 2, .write = Stub.write },
            .args = &.{"40"},
            .input = .{ .num = 40 },
        },
    }, false);

    try std.testing.expect(diagnostic == null);
    try std.testing.expectEqual(@as(usize, 2), Stub.count);
    try std.testing.expectEqualSlices(u16, &.{ 130, 240 }, &Stub.seen);
    try std.testing.expectEqual(@as(usize, 0), hid.lock.depth);
}

test "write failure returns partial-application details and stops later settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Stub = struct {
        var count: usize = 0;
        fn write(_: std.mem.Allocator, _: *transport.Device, _: *const device.Descriptor, ctx: u8, _: Input) !void {
            count += 1;

            if (ctx == 2)
                return error.TestFailure;
        }
    };

    Stub.count = 0;
    var hid: transport.Device = .{ .handle = undefined, .pid = 0x02b6, .io = std.testing.io, .lock = try .open(0xfffe) };
    defer hid.lock.close();
    const desc = try descriptorByPid(0x02b6);
    const operations = [_]Operation{
        .{ .setting = .{ .usage = .{ .name = "first" }, .ctx = 1, .write = Stub.write }, .args = &.{} },
        .{ .setting = .{ .usage = .{ .name = "second" }, .ctx = 2, .write = Stub.write }, .args = &.{} },
        .{ .setting = .{ .usage = .{ .name = "third" }, .ctx = 3, .write = Stub.write }, .args = &.{} },
    };
    const failure = (try apply(allocator, &hid, .empty, desc, &operations, false)).?;

    try std.testing.expectEqualStrings("--second: write failed; 1 earlier setting(s) applied, 1 later setting(s) not attempted; the failing setting may be partially applied", failure.message);
    try std.testing.expectEqual(error.TestFailure, failure.err.?);
    try std.testing.expectEqual(@as(usize, 2), Stub.count);
}

test "logical reads own only their scope and allocate in the caller's arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Stub = struct {
        fn read(gpa: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, ctx: u8) !Reading {
            try std.testing.expectEqual(@as(usize, 1), hid.lock.depth);

            return .{ .val = .{ .str = try gpa.print("value-{d}", .{ctx}) } };
        }
    };
    var hid: transport.Device = .{ .handle = undefined, .pid = 0x02b6, .io = std.testing.io, .lock = try .open(0xfffe) };
    defer hid.lock.close();
    const desc = try descriptorByPid(0x02b6);

    _ = try readSetting(allocator, &hid, desc, .{ .usage = .{ .name = "test" }, .ctx = 7, .read = Stub.read });
    try std.testing.expectEqual(@as(usize, 0), hid.lock.depth);

    const result = try get(allocator, &hid, desc, &.{
        .{ .setting = .{ .usage = .{ .name = "test" }, .ctx = 7, .read = Stub.read }, .args = &.{} },
    });
    const fields = result.success;

    try std.testing.expectEqual(allocator.ptr, fields.allocator.ptr);
    var writer: std.Io.Writer.Allocating = .init(allocator);

    try fields.renderSelected(&writer.writer, .text);
    try std.testing.expectEqualStrings("value-7\n", writer.written());
    try std.testing.expectEqual(@as(usize, 0), hid.lock.depth);
}

test "failed logical reads release their USB lock" {
    const Stub = struct {
        fn read(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !Reading {
            try std.testing.expectEqual(@as(usize, 1), hid.lock.depth);

            return error.TestReadFailure;
        }
    };
    var hid: transport.Device = .{ .handle = undefined, .pid = 0x02b6, .io = std.testing.io, .lock = try .open(0xfffe) };
    defer hid.lock.close();
    const desc = try descriptorByPid(hid.pid);

    try std.testing.expectError(error.TestReadFailure, readSetting(std.testing.allocator, &hid, desc, .{
        .usage = .{ .name = "test" },
        .read = Stub.read,
    }));
    try std.testing.expectEqual(@as(usize, 0), hid.lock.depth);
}

test "restore stops on a comparison read failure without writing that or later settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Stub = struct {
        var writes: usize = 0;

        fn read(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8) !Reading {
            try std.testing.expectEqual(@as(usize, 1), hid.lock.depth);

            return error.NamedRestoreReadFailure;
        }

        fn write(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, _: u8, _: Input) !void {
            try std.testing.expectEqual(@as(usize, 1), hid.lock.depth);
            writes += 1;
        }
    };

    Stub.writes = 0;
    var hid: transport.Device = .{ .handle = undefined, .pid = 0x02b6, .io = std.testing.io, .lock = try .open(0xfffe) };
    defer hid.lock.close();
    const desc = try descriptorByPid(hid.pid);
    const failure = (try restoreOperations(allocator, &hid, desc, &.{
        .{ .setting = .{ .usage = .{ .name = "first" }, .write = Stub.write }, .args = &.{} },
        .{ .setting = .{ .usage = .{ .name = "second" }, .read = Stub.read, .write = Stub.write }, .args = &.{"30"} },
        .{ .setting = .{ .usage = .{ .name = "third" }, .write = Stub.write }, .args = &.{} },
    })).?;

    try std.testing.expectEqual(error.NamedRestoreReadFailure, failure.err.?);
    try std.testing.expectEqualStrings("restore --second: read failed; 1 earlier setting(s) applied, this and 1 later setting(s) not attempted", failure.message);
    try std.testing.expectEqual(@as(usize, 1), Stub.writes);
    try std.testing.expectEqual(@as(usize, 0), hid.lock.depth);
}

test "restore filters saved values and orders only the selected dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const desc = try descriptorByPid(0x02b6);
    const text = "fan auto\ncustom-cpu boost\nmode custom\nbrightness 30\n";
    const all = try mustPrepare(try restorePlan(allocator, desc, text, &.{}));

    try std.testing.expectEqual(@as(usize, 4), all.len);
    try std.testing.expectEqualStrings("mode", all[0].setting.usage.name);
    try std.testing.expectEqualStrings("custom-cpu", all[1].setting.usage.name);
    const selected = try mustPrepare(try prepare(allocator, desc, &.{"--custom-cpu"}, .restore));
    const only = try mustPrepare(try restorePlan(allocator, desc, text, selected));

    try std.testing.expectEqual(@as(usize, 1), only.len);
    try std.testing.expectEqualStrings("custom-cpu", only[0].setting.usage.name);
    try std.testing.expectEqual(@as(usize, 0), (try mustPrepare(try restorePlan(allocator, desc, "", &.{}))).len);
}

test "save eligibility excludes measurements and write-only presets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const laptop = try descriptorByPid(0x02b6);
    const laptop_settings: Catalog = try .init(allocator, laptop);

    try std.testing.expect(selectable(laptop_settings.find("brightness").?, .save));
    try std.testing.expect(!selectable(laptop_settings.find("cpu-temp").?, .save));
    try std.testing.expect(!selectable(laptop_settings.find("firmware").?, .save));
    const pad = &test_cooling_device;
    const pad_settings: Catalog = try .init(allocator, pad);

    try std.testing.expect(!selectable(pad_settings.find("fan-low").?, .save));
    try std.testing.expect(selectable(pad_settings.find("fan-low").?, .restore));
}

test "selected reads and save capture preserve named callback failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Stub = struct {
        fn read(_: std.mem.Allocator, _: *transport.Device, _: *const device.Descriptor, _: u8) !Reading {
            return error.NamedReadFailure;
        }
    };
    var hid: transport.Device = .{ .handle = undefined, .pid = 0x02b6, .io = std.testing.io, .lock = try .open(0xfffe) };
    defer hid.lock.close();
    const desc = try descriptorByPid(hid.pid);
    const s: Setting = .{ .usage = .{ .name = "test" }, .read = Stub.read };
    const read_failure = (try get(allocator, &hid, desc, &.{.{ .setting = s, .args = &.{} }})).failure;

    try std.testing.expectEqualStrings("--test: read failed", read_failure.message);
    try std.testing.expectEqual(error.NamedReadFailure, read_failure.err.?);
    const save_failure = (try capture(allocator, &hid, desc, s)).failure;

    try std.testing.expectEqualStrings("save --test: read failed; nothing saved", save_failure.message);
    try std.testing.expectEqual(error.NamedReadFailure, save_failure.err.?);
}

test "restore preserves a named cause and counts applied writes without counting skipped settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Stub = struct {
        var writes: usize = 0;
        fn read(_: std.mem.Allocator, _: *transport.Device, _: *const device.Descriptor, _: u8) !Reading {
            return .{ .val = .{ .num = 30 } };
        }
        fn write(_: std.mem.Allocator, _: *transport.Device, _: *const device.Descriptor, ctx: u8, _: Input) !void {
            writes += 1;

            if (ctx == 2)
                return error.NamedRestoreFailure;
        }
    };

    Stub.writes = 0;
    var hid: transport.Device = .{ .handle = undefined, .pid = 0x02b6, .io = std.testing.io, .lock = try .open(0xfffe) };
    defer hid.lock.close();
    const desc = try descriptorByPid(hid.pid);
    const failure = (try restoreOperations(allocator, &hid, desc, &.{
        .{ .setting = .{ .usage = .{ .name = "held" }, .read = Stub.read, .write = Stub.write }, .args = &.{"30"} },
        .{ .setting = .{ .usage = .{ .name = "first" }, .ctx = 1, .write = Stub.write }, .args = &.{} },
        .{ .setting = .{ .usage = .{ .name = "second" }, .ctx = 2, .write = Stub.write }, .args = &.{} },
        .{ .setting = .{ .usage = .{ .name = "third" }, .ctx = 3, .write = Stub.write }, .args = &.{} },
    })).?;

    try std.testing.expectEqualStrings("restore --second: write failed; 1 earlier setting(s) applied, 1 later setting(s) not attempted; the failing setting may be partially applied", failure.message);
    try std.testing.expectEqual(error.NamedRestoreFailure, failure.err.?);
    try std.testing.expectEqual(@as(usize, 2), Stub.writes);
}

test "saved file failures survive record, restore and persist-after-write context" {
    if (@import("builtin").os.tag != .linux)
        return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, "README.md", allocator);
    const state = try allocator.dupeSentinel(u8, try allocator.print("XDG_STATE_HOME={s}", .{path}), 0);
    const raw = [_:null]?[*:0]const u8{state};
    const environ: std.process.Environ = .{ .block = .{ .slice = &raw } };
    const Stub = struct {
        var writes: usize = 0;
        fn write(_: std.mem.Allocator, _: *transport.Device, _: *const device.Descriptor, _: u8, _: Input) !void {
            writes += 1;
        }
    };

    Stub.writes = 0;
    var hid: transport.Device = .{ .handle = undefined, .pid = 0x02b6, .io = std.testing.io, .lock = try .open(0xfffe) };
    defer hid.lock.close();
    const desc = try descriptorByPid(hid.pid);
    const loaded = (try saved.load(allocator, hid.io, environ, desc.pid)).failure;

    try std.testing.expectEqual(error.NotDir, loaded.err.?);
    try std.testing.expect(std.mem.indexOf(u8, loaded.message, path) != null);
    try std.testing.expect(std.mem.indexOf(u8, loaded.message, "NotDir") == null);
    const recorded = (try saved.recordAll(allocator, hid.io, environ, desc.pid, &.{.{ .name = "test", .args = &.{"30"} }})) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings(loaded.message, recorded.message);
    try std.testing.expectEqual(loaded.err, recorded.err);
    const restored = (try restore(allocator, &hid, environ, desc, &.{})) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings(loaded.message, restored.message);
    try std.testing.expectEqual(loaded.err, restored.err);
    const applied = (try apply(allocator, &hid, environ, desc, &.{
        .{ .setting = .{ .usage = .{ .name = "test" }, .write = Stub.write }, .args = &.{"30"} },
        .{ .setting = .{ .usage = .{ .name = "later" }, .write = Stub.write }, .args = &.{} },
    }, true)).?;

    try std.testing.expectEqual(error.NotDir, applied.err.?);
    try std.testing.expect(std.mem.indexOf(u8, applied.message, loaded.message) != null);
    try std.testing.expect(std.mem.endsWith(u8, applied.message, "1 setting(s) applied, 1 later setting(s) not attempted"));
    try std.testing.expect(std.mem.indexOf(u8, applied.message, "NotDir") == null);
    try std.testing.expectEqual(@as(usize, 1), Stub.writes);
}

test "persisted apply commits each success before the next write and keeps it on failure" {
    if (@import("builtin").os.tag != .linux)
        return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const test_path = try allocator.print(".razerctl-apply-save-test-{d}", .{std.os.linux.getpid()});

    try cwd.createDir(io, test_path, .default_dir);
    defer cwd.deleteTree(io, test_path) catch @panic("cannot remove test state directory");
    const absolute = try cwd.realPathFileAlloc(io, test_path, allocator);
    const state = try allocator.dupeSentinel(u8, try allocator.print("XDG_STATE_HOME={s}", .{absolute}), 0);
    const raw = [_:null]?[*:0]const u8{state};
    const environ: std.process.Environ = .{ .block = .{ .slice = &raw } };
    const Stub = struct {
        var writes: usize = 0;
        var state_dir: []const u8 = undefined;
        fn write(_: std.mem.Allocator, hid: *transport.Device, _: *const device.Descriptor, ctx: u8, _: Input) !void {
            writes += 1;

            if (ctx != 2)
                return;

            var dir = try std.Io.Dir.openDirAbsolute(hid.io, state_dir, .{});
            defer dir.close(hid.io);
            var buffer: [64]u8 = undefined;
            const text = try dir.readFile(hid.io, "0x02b6", &buffer);

            if (!std.mem.eql(u8, text, "first 30\n"))
                return error.EarlierWriteWasNotSaved;

            return error.NamedPersistedWriteFailure;
        }
    };

    Stub.writes = 0;
    Stub.state_dir = try allocator.print("{s}/razerctl", .{absolute});
    const desc = try descriptorByPid(0x02b6);
    var hid: transport.Device = .{ .handle = undefined, .pid = desc.pid, .io = io, .lock = try .open(0xfffe) };
    defer hid.lock.close();
    const failure = (try apply(allocator, &hid, environ, desc, &.{
        .{ .setting = .{ .usage = .{ .name = "first" }, .ctx = 1, .write = Stub.write }, .args = &.{"30"} },
        .{ .setting = .{ .usage = .{ .name = "second" }, .ctx = 2, .write = Stub.write }, .args = &.{"40"} },
        .{ .setting = .{ .usage = .{ .name = "third" }, .ctx = 3, .write = Stub.write }, .args = &.{"50"} },
    }, true)).?;

    try std.testing.expectEqual(error.NamedPersistedWriteFailure, failure.err.?);
    try std.testing.expectEqual(@as(usize, 2), Stub.writes);
    try std.testing.expectEqualStrings("first 30\n", (try saved.load(allocator, io, environ, desc.pid)).success);
}
