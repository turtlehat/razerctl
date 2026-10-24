//! Streaming wire formats, layout discovery and custom-effect selection.
const std = @import("std");
const transport = @import("transport");
const capability = @import("features/lighting_types");
const Config = capability.Config;
pub const Layout = capability.Layout;

pub fn format(config: Config) transport.Format {
    return .{
        .report_id = config.report_id,
        .compact = config.report != .standard,
        .checksum_transaction = config.report == .compact_camy,
    };
}

pub fn layout(hid: *transport.Device, config: Config) !Layout {
    if (config.fixedLayout()) |fixed|
        return fixed;
    const edition = try hid.call(.{ .id = 0x0086, .min_response = 2 }, &.{ 0, 0, 0 });
    if (config.selectLayout(edition.args[1], edition.args[0])) |selected|
        return selected;
    // Layout 0 is unspecified; use layout 1 as the default.
    if (edition.args[0] == 0)
        if (config.selectLayout(edition.args[1], 1)) |selected|
            return selected;
    return error.UnknownStreamLayout;
}

pub fn frameRow(config: Config, shape: Layout, row: u8, rgb: []const u8, sequence: u8) !transport.Report {
    return regionRow(config, shape, row, 0, rgb, sequence);
}

fn regionRow(config: Config, shape: Layout, row: u8, region: u8, rgb: []const u8, sequence: u8) !transport.Report {
    if (!config.validFrames() or shape.columns == 0 or row >= shape.rows or rgb.len != @as(usize, shape.columns) * 3)
        return error.InvalidFrame;
    var args: [80]u8 = @splat(0);
    switch (config.protocol.?) {
        .legacy_rows, .extended_rows => {
            const extended = config.protocol == .extended_rows;
            const offset: usize = if (extended) 5 else 4;
            if (rgb.len > args.len - offset)
                return error.InvalidFrame;
            if (extended) {
                args[0..5].* = .{ 0, region, row, 0, shape.columns - 1 };
            } else {
                args[0..4].* = .{ 255, row, 0, shape.columns - 1 };
            }
            @memcpy(args[offset .. offset + rgb.len], rgb);
            return transport.Report.fromPacket(transport.Packet.init(if (extended) 0x0f03 else 0x030b, args[0 .. offset + rgb.len]), format(config));
        },
        .large_matrix => {
            if (shape.rows != 1 or shape.columns > 120)
                return error.InvalidFrame;
            var report: transport.Report = .{ .len = 375 };

            report.bytes[0] = config.report_id;
            report.bytes[2] = sequence & 31;
            // Fixed native header, including 01 36 even for 114 columns.
            report.bytes[5..9].* = .{ 1, 0x36, 3, 0x0b };
            report.bytes[12] = shape.columns - 1;
            @memcpy(report.bytes[13 .. 13 + rgb.len], rgb);
            for (report.bytes[3..373]) |byte|
                report.bytes[373] ^= byte;
            return report;
        },
        .audio37 => {
            if (shape.rows != 1 or rgb.len > 34)
                return error.InvalidFrame;
            var report: transport.Report = .{ .len = 37 };

            report.bytes[0..3].* = .{ 0x40, 3, 0 };
            @memcpy(report.bytes[3 .. 3 + rgb.len], rgb);
            return report;
        },
    }
}

pub const Writer = struct {
    hid: *transport.Device,
    config: Config,
    shape: Layout,
    sequence: u8 = 1,
    sent: bool = false,
    last_sent: []u8,
    cache_valid: bool = false,

    pub fn init(hid: *transport.Device, config: Config, shape: Layout) !Writer {
        const cache = try std.heap.page_allocator.alloc(u8, shape.frameSize());
        errdefer std.heap.page_allocator.free(cache);
        if (config.frame_interface) |interface|
            try hid.openFrameInterface(interface);
        return .{ .hid = hid, .config = config, .shape = shape, .last_sent = cache };
    }

    pub fn deinit(self: *Writer) void {
        std.heap.page_allocator.free(self.last_sent);
        self.hid.closeFrameInterface();
    }

    pub fn invalidate(self: *Writer) void {
        self.cache_valid = false;
    }

    pub fn needsWrite(self: *const Writer, rgb: []const u8) bool {
        return !self.cache_valid or !std.mem.eql(u8, rgb, self.last_sent);
    }

    pub fn write(self: *Writer, rgb: []const u8) !void {
        try self.writeTo(rgb, self);
    }

    fn writeTo(self: *Writer, rgb: []const u8, sender: anytype) !void {
        if (rgb.len != self.shape.frameSize())
            return error.InvalidFrame;
        self.sent = false;
        const stride = @as(usize, self.shape.columns) * 3;
        for (0..self.shape.rows) |row| {
            const row_rgb = rgb[row * stride ..][0..stride];
            var addressed = false;
            for (self.config.zones) |zone| {
                const frame = zone.frame orelse continue;
                const length = frame.length orelse continue;
                addressed = true;
                const start = @as(usize, frame.start) * 3;
                var regional_shape = self.shape;
                regional_shape.columns = @intCast(length);
                const colours = row_rgb[start..][0 .. @as(usize, length) * 3];
                const previous = self.last_sent[row * stride + start ..][0..colours.len];
                if (self.cache_valid and std.mem.eql(u8, colours, previous))
                    continue;
                try sender.send(try regionRow(self.config, regional_shape, @intCast(row), zone.id, colours, self.sequence));
                @memcpy(previous, colours);
            }
            if (!addressed) {
                const previous = self.last_sent[row * stride ..][0..stride];
                if (self.cache_valid and std.mem.eql(u8, row_rgb, previous))
                    continue;
                try sender.send(try frameRow(self.config, self.shape, @intCast(row), row_rgb, self.sequence));
                @memcpy(previous, row_rgb);
            }
        }
        @memcpy(self.last_sent, rgb);
        self.cache_valid = true;
    }

    fn send(self: *Writer, report: transport.Report) !void {
        try pace(&self.sent, self.hid);
        self.sequence +%= 1;
        if (self.config.protocol == .audio37) {
            try self.hid.writeReport(report.slice());
        } else {
            try self.hid.sendFrameReport(report.slice());
        }
    }

    pub fn latch(self: *Writer) !void {
        switch (self.config.protocol.?) {
            .legacy_rows, .large_matrix => {
                try pace(&self.sent, self.hid);
                const command: transport.Command = .{ .id = 0x030a };
                if (self.config.latch_response) {
                    _ = try self.hid.call(command, &.{ 5, 0 });
                } else {
                    try self.hid.send(transport.Packet.init(command.id, &.{ 5, 0 }));
                }
            },
            .extended_rows => {
                for (self.config.zones) |zone| {
                    if (zone.frame == null)
                        continue;
                    try pace(&self.sent, self.hid);
                    const args = [_]u8{ 0, zone.id, 8, 0, 0, 0 };
                    if (self.config.latch_response) {
                        _ = try self.hid.call(.{ .id = 0x0f02 }, &args);
                    } else {
                        try self.hid.send(transport.Packet.init(0x0f02, &args));
                    }
                }
            },
            .audio37 => {
                try pace(&self.sent, self.hid);
                var report: [37]u8 = @splat(0);
                report[0..6].* = .{ 0x40, 1, 0, 15, 8, 0 };
                try self.hid.writeReport(&report);
            },
        }
    }
};

fn pace(sent: *bool, clock: anytype) !void {
    if (sent.*)
        try clock.sleepMs(1);
    sent.* = true;
}

test "writer caches successful rows and invalidation forces a full resend" {
    const Sender = struct {
        calls: usize = 0,
        fail: bool = false,
        fn send(self: *@This(), _: transport.Report) !void {
            if (self.fail) return error.SendFailed;
            self.calls += 1;
        }
    };
    for ([_]bool{ false, true }) |regional| {
        const shape: Layout = .{ .rows = 2, .columns = 2 };
        var cache: [12]u8 = undefined;
        const config: Config = .{
            .protocol = if (regional) .extended_rows else .legacy_rows,
            .layouts = &.{shape},
            .zones = if (regional) &.{
                .{ .id = 1, .name = "a", .frame = .{ .start = 0, .length = 1 } },
                .{ .id = 2, .name = "b", .frame = .{ .start = 1, .length = 1 } },
            } else &.{.{ .id = 5, .name = "backlight", .frame = .{} }},
        };
        var writer: Writer = .{ .hid = undefined, .config = config, .shape = shape, .last_sent = &cache };
        var sender: Sender = .{};
        var rgb: [12]u8 = @splat(0);
        const full: usize = if (regional) 4 else 2;
        try std.testing.expect(writer.needsWrite(&rgb));
        try writer.writeTo(&rgb, &sender);
        try std.testing.expectEqual(full, sender.calls);
        try std.testing.expect(!writer.needsWrite(&rgb));
        try writer.writeTo(&rgb, &sender);
        try std.testing.expectEqual(full, sender.calls);
        rgb[7] = 42;
        sender.fail = true;
        try std.testing.expectError(error.SendFailed, writer.writeTo(&rgb, &sender));
        try std.testing.expectEqual(@as(u8, 0), cache[7]);
        sender.fail = false;
        try writer.writeTo(&rgb, &sender);
        try std.testing.expectEqual(full + 1, sender.calls);
        try std.testing.expectEqual(@as(u8, 42), cache[7]);
        writer.invalidate();
        try writer.writeTo(&rgb, &sender);
        try std.testing.expectEqual(full * 2 + 1, sender.calls);
    }
}

test "whole-frame caching ignores sequence changes" {
    const Sender = struct {
        calls: usize = 0,
        fn send(self: *@This(), _: transport.Report) !void {
            self.calls += 1;
        }
    };
    const shape: Layout = .{ .rows = 1, .columns = 102 };
    const config: Config = .{
        .protocol = .large_matrix,
        .layouts = &.{shape},
        .zones = &.{.{ .id = 5, .name = "backlight", .frame = .{} }},
    };
    var cache: [306]u8 = undefined;
    var rgb: [306]u8 = @splat(1);
    var writer: Writer = .{ .hid = undefined, .config = config, .shape = shape, .last_sent = &cache };
    var sender: Sender = .{};
    try writer.writeTo(&rgb, &sender);
    writer.sequence = 31;
    try writer.writeTo(&rgb, &sender);
    try std.testing.expectEqual(@as(usize, 1), sender.calls);
    rgb[305] = 2;
    try writer.writeTo(&rgb, &sender);
    try std.testing.expectEqual(@as(usize, 2), sender.calls);
}

test "frame pacing skips the first send and waits before subsequent rows and latches" {
    const Clock = struct {
        waits: usize = 0,
        fn sleepMs(self: *@This(), ms: u32) !void {
            try std.testing.expectEqual(@as(u32, 1), ms);
            self.waits += 1;
        }
    };
    var clock: Clock = .{};
    var sent = false;
    try pace(&sent, &clock);
    try std.testing.expectEqual(@as(usize, 0), clock.waits);
    try pace(&sent, &clock);
    try pace(&sent, &clock);
    try pace(&sent, &clock);
    try std.testing.expectEqual(@as(usize, 3), clock.waits);
    sent = false;
    try pace(&sent, &clock);
    try std.testing.expectEqual(@as(usize, 3), clock.waits);
}

pub fn audioQuery(hid: *transport.Device, command: u8, region: u8) ![37]u8 {
    var request: [37]u8 = @splat(0);
    request[0] = 0x40;
    request[1] = command;
    request[3] = region;
    try hid.writeReport(&request);
    var reply: [64]u8 = undefined;
    for (0..10) |_| {
        const n = try hid.readReport(&reply, 100);
        const minimum: usize = if (command == 0x81) 13 else 4;
        if (n >= minimum and reply[0] == 0x41 and reply[1] == command) {
            if (command == 0x81 and reply[3] != region)
                continue;
            var result: [37]u8 = @splat(0);
            @memcpy(result[0..@min(n, 37)], reply[0..@min(n, 37)]);
            return result;
        }
    }
    return error.CommandTimeout;
}

test "legacy and extended rows preserve raw RGB and inclusive column bounds" {
    const shape: Layout = .{ .rows = 6, .columns = 16 };
    var config: Config = .{
        .protocol = .legacy_rows,
        .zones = &.{.{ .id = 5, .name = "backlight", .frame = .{} }},
        .layouts = &.{shape},
        .control_interface = 2,
    };
    var rgb: [48]u8 = undefined;
    for (&rgb, 0..) |*byte, i|
        byte.* = @intCast(i);
    const legacy = try frameRow(config, shape, 5, &rgb, 1);
    try std.testing.expectEqualSlices(u8, &.{ 255, 5, 0, 15 }, legacy.bytes[9..13]);
    try std.testing.expectEqualSlices(u8, &rgb, legacy.bytes[13..61]);
    config.protocol = .extended_rows;
    const extended = try frameRow(config, shape, 5, &rgb, 1);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 5, 0, 15 }, extended.bytes[9..14]);
    try std.testing.expectEqualSlices(u8, &rgb, extended.bytes[14..62]);
    try std.testing.expectEqual(@as(u8, 53), extended.bytes[6]);
    try std.testing.expectError(error.InvalidFrame, frameRow(config, shape, 6, &rgb, 1));
    try std.testing.expectError(error.InvalidFrame, frameRow(config, shape, 0, rgb[0..47], 1));
}

test "large reports match emulated native encoder for both new Blade sizes and sequence wrap" {
    for ([_]u8{ 102, 114, 120 }) |columns| {
        const shape: Layout = .{ .rows = 1, .columns = columns };
        const config: Config = .{
            .protocol = .large_matrix,
            .zones = &.{.{ .id = 5, .name = "backlight", .frame = .{} }},
            .layouts = &.{shape},
            .control_interface = 2,
            .frame_interface = 3,
        };
        var rgb: [360]u8 = undefined;
        for (&rgb, 0..) |*byte, i|
            byte.* = @truncate(i * 37 + 19);
        for ([_]u8{ 1, 31, 32 }) |sequence| {
            const report = try frameRow(config, shape, 0, rgb[0 .. @as(usize, columns) * 3], sequence);
            try std.testing.expectEqual(@as(usize, 375), report.len);
            try std.testing.expectEqual(sequence & 31, report.bytes[2]);
            try std.testing.expectEqualSlices(u8, &.{ 1, 54, 3, 11 }, report.bytes[5..9]);
            try std.testing.expectEqual(columns - 1, report.bytes[12]);
            try std.testing.expectEqualSlices(u8, rgb[0 .. @as(usize, columns) * 3], report.bytes[13 .. 13 + @as(usize, columns) * 3]);
            var crc: u8 = 0;
            for (report.bytes[3..373]) |byte|
                crc ^= byte;
            try std.testing.expectEqual(crc, report.bytes[373]);
            for (report.bytes[13 + @as(usize, columns) * 3 .. 373]) |byte|
                try std.testing.expectEqual(@as(u8, 0), byte);
        }
    }
}

test "compact audio uses its report ID and checksum convention; Kitty uses output reports" {
    const shape: Layout = .{ .rows = 1, .columns = 10 };
    const config: Config = .{
        .protocol = .extended_rows,
        .zones = &.{.{ .id = 5, .name = "backlight", .frame = .{} }},
        .layouts = &.{shape},
        .control_interface = 3,
        .report = .compact_camy,
        .report_id = 7,
    };
    const report = try frameRow(config, shape, 0, &@as([30]u8, @splat(91)), 1);
    try std.testing.expectEqual(@as(usize, 65), report.len);
    try std.testing.expectEqual(@as(u8, 7), report.bytes[0]);
    var crc: u8 = 0;
    for (report.bytes[1..63]) |byte|
        crc ^= byte;
    try std.testing.expectEqual(crc, report.bytes[63]);
    const kitty_shape: Layout = .{ .rows = 1, .columns = 1 };
    const kitty: Config = .{
        .protocol = .audio37,
        .zones = &.{.{ .id = 15, .name = "backlight", .frame = .{} }},
        .layouts = &.{kitty_shape},
        .control_interface = 3,
    };
    const frame = try frameRow(kitty, kitty_shape, 0, &.{ 1, 2, 3 }, 0);
    try std.testing.expectEqual(@as(usize, 37), frame.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 3, 0, 1, 2, 3 }, frame.bytes[0..6]);
}

test "regional frames carry independent IDs and regional column bounds" {
    const shape: Layout = .{ .rows = 1, .columns = 12 };
    const config: Config = .{
        .protocol = .extended_rows,
        .layouts = &.{shape},
        .control_interface = 0,
        .report_id = 7,
        .zones = &.{
            .{ .id = 16, .name = "speaker-16", .frame = .{ .start = 0, .length = 6 } },
            .{ .id = 17, .name = "speaker-17", .frame = .{ .start = 6, .length = 6 } },
        },
    };
    const regional_shape: Layout = .{ .rows = 1, .columns = 6 };
    for ([_]u8{ 16, 17 }) |id| {
        const report = try regionRow(config, regional_shape, 0, id, &@as([18]u8, @splat(id)), 1);
        try std.testing.expectEqual(@as(u8, 7), report.bytes[0]);
        try std.testing.expectEqualSlices(u8, &.{ 0, id, 0, 0, 5 }, report.bytes[9..14]);
        try std.testing.expectEqualSlices(u8, &@as([18]u8, @splat(id)), report.bytes[14..32]);
    }
}
