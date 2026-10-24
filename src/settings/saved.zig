//! Saved settings: one plain-text file per device, replayed by `restore`.

const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui");

pub const Entry = struct { name: []const u8, args: []const [:0]const u8 };

/// One capture, committed only after all hardware reads succeed.
pub fn recordAll(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, pid: u16, entries: []const Entry) !?ui.Failure {
    var store: Store = try .init(allocator, io, environ, pid);
    defer store.close();

    return try store.recordAll(entries);
}

/// Opens nothing until set --save's first successful write, then saves each setting before the next.
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    location: ?Place,
    filename: []const u8,
    directory: ?std.Io.Dir = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, pid: u16) !Store {
        return .{
            .allocator = allocator,
            .io = io,
            .location = try place(allocator, environ),
            .filename = try file(allocator, pid),
        };
    }

    pub fn close(store: *Store) void {
        if (store.directory) |dir|
            dir.close(store.io);

        store.directory = null;
    }

    pub fn recordAll(store: *Store, entries: []const Entry) !?ui.Failure {
        const allocator = store.allocator;
        const io = store.io;
        const p = store.location orelse return .{ .message = "cannot load saved settings: no valid state directory" };
        // Reload on every commit: do not overwrite an intervening user edit
        // with a command-local snapshot. Only the directory handle is reused.
        var text = switch (try if (store.directory) |dir|
            read(allocator, io, dir, p, store.filename)
        else
            loadAt(allocator, io, p, store.filename)) {
            .success => |contents| contents,
            .failure => |failure| return failure,
        };

        for (entries) |entry| {
            var aw: std.Io.Writer.Allocating = .init(allocator);

            try aw.writer.print("{s}", .{entry.name});

            for (entry.args) |a|
                try aw.writer.print(" {s}", .{a});

            text = try upsert(allocator, text, aw.written());
        }

        if (store.directory == null) {
            var root = std.Io.Dir.openDirAbsolute(io, p.root, .{}) catch |err|
                return .{ .message = try allocator.print("cannot save: {s}", .{p.root}), .err = err };
            defer root.close(io);

            store.directory = root.createDirPathOpen(io, p.sub, .{}) catch |err|
                return .{ .message = try allocator.print("cannot save: {s}", .{try p.dir(allocator)}), .err = err };
        }

        writeAtomic(io, store.directory.?, store.filename, text) catch |err|
            return .{
                .message = try allocator.print("cannot save: {s}/{s}", .{ try p.dir(allocator), store.filename }),
                .err = err,
            };
        return null;
    }
};

/// A crash or full disk mid-write leaves the previous file intact.
fn writeAtomic(io: std.Io, dir: std.Io.Dir, filename: []const u8, data: []const u8) !void {
    var atomic = try dir.createFileAtomic(io, filename, .{ .replace = true });
    defer atomic.deinit(io);

    try atomic.file.writeStreamingAll(io, data);
    try atomic.replace(io);
}

/// The whole file, or nothing where none has been written.
pub fn load(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, pid: u16) !ui.Result([]const u8) {
    const p = (try place(allocator, environ)) orelse return .{ .failure = .{
        .message = "cannot load saved settings: no valid state directory",
    } };

    return loadAt(allocator, io, p, try file(allocator, pid));
}

fn loadAt(allocator: std.mem.Allocator, io: std.Io, p: Place, filename: []const u8) !ui.Result([]const u8) {
    var dir = std.Io.Dir.openDirAbsolute(io, try p.dir(allocator), .{}) catch |err| switch (err) {
        error.FileNotFound => return .{ .success = "" },
        else => return .{ .failure = .{
            .message = try allocator.print("cannot load saved settings: {s}", .{try p.dir(allocator)}),
            .err = err,
        } },
    };
    defer dir.close(io);

    return read(allocator, io, dir, p, filename);
}

fn read(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, p: Place, filename: []const u8) !ui.Result([]const u8) {
    const text = dir.readFileAlloc(io, filename, allocator, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .success = "" },
        else => return .{ .failure = .{
            .message = try allocator.print("cannot load saved settings: {s}/{s}", .{ try p.dir(allocator), filename }),
            .err = err,
        } },
    };

    return .{ .success = text };
}

fn file(allocator: std.mem.Allocator, pid: u16) ![]const u8 {
    return try allocator.print("0x{x:0>4}", .{pid});
}

/// `$XDG_STATE_HOME/razerctl`, `~/.local/state/razerctl` or `%LOCALAPPDATA%\razerctl`,
/// split into a root that exists and the part razerctl creates.
const Place = struct {
    root: []const u8,
    sub: []const u8,

    fn dir(p: Place, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fs.path.join(allocator, &.{ p.root, p.sub });
    }
};

fn place(allocator: std.mem.Allocator, environ: std.process.Environ) !?Place {
    if (builtin.target.os.tag == .windows)
        return .{ .root = (try env(allocator, environ, "LOCALAPPDATA")) orelse return null, .sub = "razerctl" };

    const state = (try env(allocator, environ, "XDG_STATE_HOME")) orelse
        try allocator.print("{s}/.local/state", .{(try env(allocator, environ, "HOME")) orelse return null});

    if (state.len < 2 or state[0] != '/')
        return null;

    return .{ .root = "/", .sub = try allocator.print("{s}/razerctl", .{std.mem.trim(u8, state, "/")}) };
}

fn env(allocator: std.mem.Allocator, environ: std.process.Environ, key: []const u8) !?[]const u8 {
    return environ.getAlloc(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => unreachable,
    };
}

/// Replaces the line whose setting matches `line`'s, or appends. Order is
/// kept, so restore replays settings in the order they were first set.
fn upsert(allocator: std.mem.Allocator, text: []const u8, line: []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var replaced = false;

    var lines = std.mem.splitScalar(u8, text, '\n');

    while (lines.next()) |l| {
        if (l.len == 0)
            continue;

        const matches = std.mem.eql(u8, word(l), word(line));

        if (matches)
            replaced = true;

        try aw.writer.print("{s}\n", .{if (matches) line else l});
    }

    if (!replaced)
        try aw.writer.print("{s}\n", .{line});

    return aw.written();
}

pub fn word(line: []const u8) []const u8 {
    return line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len];
}

test "a setting keeps one line, in first-set order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const e = std.testing.expectEqualStrings;

    try e("mode turbo\n", try upsert(allocator, "", "mode turbo"));
    try e("mode silent\n", try upsert(allocator, "mode turbo\n", "mode silent"));
    try e("mode turbo\nfan auto\n", try upsert(allocator, "mode turbo\n", "fan auto"));
    try e("mode silent\nfan auto\n", try upsert(allocator, "mode silent\nfan 3000\n", "fan auto"));
    try e("effect static #e14350\n", try upsert(allocator, "effect spectrum\n", "effect static #e14350"));
}

test "missing state directory returns message-only failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const failure = (try load(allocator, std.testing.io, .empty, 0x02b6)).failure;

    try std.testing.expectEqualStrings("cannot load saved settings: no valid state directory", failure.message);
    try std.testing.expect(failure.err == null);
    const recorded = (try recordAll(allocator, std.testing.io, .empty, 0x02b6, &.{.{ .name = "brightness", .args = &.{"30"} }})).?;

    try std.testing.expectEqualStrings(failure.message, recorded.message);
    try std.testing.expect(recorded.err == null);
}

test "store opens lazily reuses its directory and reloads intervening edits" {
    if (builtin.target.os.tag != .linux)
        return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const test_path = try allocator.print(".razerctl-store-test-{d}", .{std.os.linux.getpid()});

    // Exclusive creation protects an existing file or directory from cleanup.
    try cwd.createDir(io, test_path, .default_dir);
    defer cwd.deleteTree(io, test_path) catch @panic("cannot remove test state directory");
    const absolute = try cwd.realPathFileAlloc(io, test_path, allocator);
    const state = try allocator.dupeSentinel(u8, try allocator.print("XDG_STATE_HOME={s}", .{absolute}), 0);
    const raw = [_:null]?[*:0]const u8{state};
    const environ: std.process.Environ = .{ .block = .{ .slice = &raw } };
    var store: Store = try .init(allocator, io, environ, 0x0000);
    defer store.close();

    try std.testing.expect(store.directory == null);
    try std.testing.expectError(error.FileNotFound, cwd.openDir(io, try allocator.print("{s}/razerctl", .{test_path}), .{}));
    try std.testing.expect((try store.recordAll(&.{.{ .name = "brightness", .args = &.{"30"} }})) == null);
    const dir = store.directory.?;

    try std.testing.expect((try store.recordAll(&.{.{ .name = "effect", .args = &.{ "static", "255,0,0,2.2" } }})) == null);
    try std.testing.expect(std.meta.eql(dir, store.directory.?));
    try dir.writeFile(io, .{ .sub_path = "0x0000", .data = "brightness 30\neffect static 255,0,0,2.2\nfan auto\n" });
    try std.testing.expect((try store.recordAll(&.{.{ .name = "brightness", .args = &.{"40"} }})) == null);
    const contents = (try load(allocator, io, environ, 0x0000)).success;

    try std.testing.expectEqualStrings("brightness 40\neffect static 255,0,0,2.2\nfan auto\n", contents);
    store.close();
    try std.testing.expect(store.directory == null);
}
