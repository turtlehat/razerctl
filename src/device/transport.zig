//! Razer's HID transport: 90-byte feature reports over hidapi (Protocol 25).

const std = @import("std");
const device_lock = @import("device_lock");

pub const c = @import("hidapi_c");

pub const RAZER_VID: u16 = 0x1532;

/// Status byte of each response.
pub const Status = enum(u8) {
    new_command = 0x00,
    busy = 0x01,
    success = 0x02,
    failed = 0x03,
    timeout = 0x04,
    not_supported = 0x05,
    custom_command_mismatch = 0xe1,
    _,
};

pub const Error = device_lock.Error || std.Io.Cancelable || error{
    OpenFailed,
    SendFailed,
    ReadFailed,
    NotSupported,
    DeviceBusy,
    BadResponse,
    CommandMismatch,
    ResponseMismatch,
    CommandFailed,
    CommandTimeout,
    InvalidReport,
    AmbiguousFrameInterface,
};

pub const Format = struct {
    report_id: u8 = 0,
    compact: bool = false,
    checksum_transaction: bool = false,

    pub fn size(self: Format) usize {
        return if (self.compact) 65 else 91;
    }
};

pub const Report = struct {
    bytes: [375]u8 = @splat(0),
    len: usize,

    pub fn slice(self: *const Report) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn fromPacket(packet: Packet, format: Format) error{InvalidReport}!Report {
        const size = format.size();
        const capacity = size - 11;
        if (packet.data_size > capacity)
            return error.InvalidReport;
        var report: Report = .{ .len = size };

        report.bytes[0] = format.report_id;
        @memcpy(report.bytes[1..9], std.mem.asBytes(&packet)[0..8]);
        @memcpy(report.bytes[9 .. 9 + capacity], packet.args[0..capacity]);
        const start: usize = if (format.checksum_transaction) 1 else 3;
        for (report.bytes[start .. size - 2]) |byte|
            report.bytes[size - 2] ^= byte;
        return report;
    }
};

pub const Command = struct {
    id: u16,
    /// Payload bytes needed by the success decoder; writes and raw probes need none.
    min_response: u8 = 0,

    fn validate(self: Command, packet: Packet) Error!void {
        if (packet.status == @backingInt(Status.success) and packet.data_size < self.min_response)
            return Error.BadResponse;
    }
};

pub fn openErrorMessage(err: Error) []const u8 {
    return switch (err) {
        error.DeviceLockTimeout => "device busy: timed out waiting for another razerctl process",
        error.DeviceLockFailed => "cannot initialize or acquire the device lock",
        error.OpenFailed => "cannot open (attached? in plugdev?)",
        else => "opened a HID interface, but its device-mode probe failed",
    };
}

/// A Razer report. 90 bytes on the wire; the report-id byte hidapi wants is
/// added at send time.
pub const Packet = extern struct {
    status: u8 = 0,
    transaction_id: u8 = 0x1f,
    remaining: u16 = 0,
    protocol_type: u8 = 0,
    data_size: u8 = 0,
    class: u8 = 0,
    id: u8 = 0,
    args: [80]u8 = @as([80]u8, @splat(0)),
    crc: u8 = 0,
    reserved: u8 = 0,

    comptime {
        std.debug.assert(@sizeOf(Packet) == 90);
    }

    pub fn init(cmd: u16, args: []const u8) Packet {
        var p = Packet{
            .data_size = @intCast(args.len),
            .class = @intCast(cmd >> 8),
            .id = @intCast(cmd & 0xff),
        };

        @memcpy(p.args[0..args.len], args);
        p.crc = p.checksum();
        return p;
    }

    /// XOR of bytes 2..87 inclusive: status, transaction id, crc and reserved
    /// are outside it.
    pub fn checksum(self: Packet) u8 {
        const bytes = std.mem.asBytes(&self);
        var sum: u8 = 0;

        for (bytes[2..88]) |b|
            sum ^= b;

        return sum;
    }

    pub fn command(self: Packet) u16 {
        return (@as(u16, self.class) << 8) | self.id;
    }

    pub fn argSlice(self: *const Packet) []const u8 {
        return self.args[0..self.data_size];
    }
};

pub const Device = struct {
    handle: *c.hid_device,
    pid: u16,
    io: std.Io,
    lock: device_lock.Lock,
    format: Format = .{},
    frame_handle: ?*c.hid_device = null,

    /// Interface numbers vary by model, so each is tried with a harmless device-mode read.
    pub fn open(io: std.Io, pid: u16) Error!Device {
        return openWith(io, pid, .{});
    }

    pub const OpenOptions = struct {
        interface: ?u8 = null,
        format: Format = .{},
        probe: enum { mode, firmware, none } = .mode,
    };

    pub fn openWith(io: std.Io, pid: u16, options: OpenOptions) Error!Device {
        if (c.hid_init() != 0)
            return Error.OpenFailed;

        const list = c.hid_enumerate(RAZER_VID, pid);
        defer if (list != null) c.hid_free_enumeration(list);

        var it = list;
        var lock = try device_lock.Lock.open(pid);
        errdefer lock.close();
        var probe_error: ?Error = null;

        while (it != null) : (it = it.*.next) {
            if (options.interface) |interface|
                if (it.*.interface_number != interface)
                    continue;
            const handle = c.hid_open_path(it.*.path) orelse continue;
            var dev = Device{ .handle = handle, .pid = pid, .io = io, .lock = lock, .format = options.format };
            if (options.probe == .none)
                return dev;

            dev.acquire() catch |err| {
                c.hid_close(handle);
                return err;
            };
            const probe = dev.call(.{
                .id = if (options.probe == .firmware) 0x0081 else 0x0084,
                .min_response = 1,
            }, &.{ 0, 0 });

            dev.release();
            _ = probe catch |err| {
                c.hid_close(handle);

                if (err == error.Canceled)
                    return err;

                if (probe_error == null)
                    probe_error = err;

                continue;
            };
            return dev;
        }

        return probe_error orelse Error.OpenFailed;
    }

    pub fn sleepMs(self: *Device, ms: i64) Error!void {
        try std.Io.sleep(self.io, .fromMilliseconds(ms), .awake);
    }

    pub fn close(self: *Device) void {
        self.closeFrameInterface();
        c.hid_close(self.handle);
        self.lock.close();
    }

    pub fn acquire(self: *Device) Error!void {
        try self.lock.acquire();
    }

    pub fn acquirePriority(self: *Device, priority: device_lock.Priority) Error!void {
        try self.lock.acquirePriority(priority);
    }

    pub fn release(self: *Device) void {
        self.lock.release();
    }

    /// Frame output only: OS send success is not firmware acknowledgement.
    pub fn send(self: *Device, packet: Packet) error{ SendFailed, InvalidReport }!void {
        try self.sendReport((try Report.fromPacket(packet, self.format)).slice());
    }

    pub fn sendReport(self: *Device, report: []const u8) error{SendFailed}!void {
        if (c.hid_send_feature_report(self.handle, report.ptr, report.len) != report.len)
            return error.SendFailed;
    }

    pub fn sendFrameReport(self: *Device, report: []const u8) error{SendFailed}!void {
        const handle = self.frame_handle orelse self.handle;
        if (c.hid_send_feature_report(handle, report.ptr, report.len) != report.len)
            return error.SendFailed;
    }

    pub fn closeFrameInterface(self: *Device) void {
        if (self.frame_handle) |handle| {
            c.hid_close(handle);
            self.frame_handle = null;
        }
    }

    pub fn writeReport(self: *Device, report: []const u8) error{SendFailed}!void {
        if (c.hid_write(self.handle, report.ptr, report.len) != report.len)
            return error.SendFailed;
    }

    pub fn readReport(self: *Device, report: []u8, timeout_ms: c_int) error{ReadFailed}!usize {
        const n = c.hid_read_timeout(self.handle, report.ptr, report.len, timeout_ms);
        if (n < 0)
            return error.ReadFailed;
        return @intCast(n);
    }

    /// Dedicated frame interfaces are not probed.
    pub fn openFrameInterface(self: *Device, interface: u8) Error!void {
        std.debug.assert(self.frame_handle == null);
        const list = c.hid_enumerate(RAZER_VID, self.pid);
        defer if (list != null) c.hid_free_enumeration(list);
        var it = list;
        var candidate: ?[*c]const u8 = null;
        while (it != null) : (it = it.*.next) {
            if (it.*.interface_number == interface) {
                // Never pair one laptop's control handle with another's frame handle.
                if (candidate != null)
                    return error.AmbiguousFrameInterface;
                candidate = it.*.path;
            }
        }
        const path = candidate orelse return error.OpenFailed;
        self.frame_handle = c.hid_open_path(path) orelse return error.OpenFailed;
    }

    /// The caller holds the device lock across the complete operation.
    pub fn call(self: *Device, command: Command, args: []const u8) Error!Packet {
        const req = Packet.init(command.id, args);
        var last_error: Error = Error.SendFailed;

        for (0..20) |_| {
            self.send(req) catch |err| {
                last_error = err;
                try self.sleepMs(5);
                continue;
            };

            const reply = self.response(command) catch |err| {
                switch (err) {
                    Error.DeviceBusy, Error.CommandFailed, Error.CommandTimeout, Error.ResponseMismatch => {
                        last_error = err;
                        continue;
                    },
                    else => return err,
                }
            };

            return reply;
        }

        return last_error;
    }

    fn response(self: *Device, command: Command) Error!Packet {
        for (0..10) |_| {
            try self.sleepMs(5);

            var reply: [91]u8 = @splat(0);
            reply[0] = self.format.report_id;

            const received = c.hid_get_feature_report(self.handle, &reply, self.format.size());
            const resp = try decodeFormattedResponse(&reply, received, command.id, self.format);

            try command.validate(resp);

            switch (@as(Status, @fromBackingInt(@intCast(resp.status)))) {
                .success => return resp,
                .not_supported => return Error.NotSupported,
                .busy => continue,
                .new_command, .failed => return Error.CommandFailed,
                .timeout => return Error.CommandTimeout,
                .custom_command_mismatch => return Error.CommandMismatch,
                else => return Error.BadResponse,
            }
        }

        return Error.DeviceBusy;
    }
};

fn decodeFormattedResponse(report: *const [91]u8, received: c_int, command: u16, format: Format) Error!Packet {
    if (!format.compact)
        return decodeResponse(report, received, command);
    if (received < 0)
        return error.ReadFailed;
    if (received != 65 or report[6] > 54)
        return error.BadResponse;
    var normalized: [91]u8 = @splat(0);
    @memcpy(normalized[0..63], report[0..63]);
    return decodeResponse(&normalized, 91, command);
}

fn decodeResponse(report: *const [91]u8, received: c_int, command: u16) Error!Packet {
    if (received < 0)
        return Error.ReadFailed;

    if (received != report.len)
        return Error.BadResponse;

    var packet: Packet = undefined;

    @memcpy(std.mem.asBytes(&packet), report[1..]);

    if (packet.command() != command)
        return Error.ResponseMismatch;

    if (packet.data_size > packet.args.len)
        return Error.BadResponse;

    return packet;
}

pub const EnumerationError = error{ HidInitFailed, OutOfMemory };

/// Deduplicated: a device enumerates once per HID interface.
pub fn attachedPids(gpa: std.mem.Allocator) EnumerationError![]u16 {
    var pids: std.ArrayList(u16) = .empty;

    if (c.hid_init() != 0)
        return error.HidInitFailed;

    const list = c.hid_enumerate(RAZER_VID, 0);
    defer if (list != null) c.hid_free_enumeration(list);

    var it = list;

    outer: while (it != null) : (it = it.*.next) {
        const p = it.*.product_id;

        for (pids.items) |seen|
            if (seen == p)
                continue :outer;

        try pids.append(gpa, p);
    }
    return pids.items;
}

test "packet framing" {
    const e = std.testing.expectEqual;
    const p = Packet.init(0x0d02, &.{ 1, 1, 5, 0 });

    try e(@as(u8, 0x0d), p.class);
    try e(@as(u8, 0x02), p.id);
    try e(@as(u8, 4), p.data_size);
    try e(@as(u16, 0x0d02), p.command());
    try e(@as(usize, 4), p.argSlice().len);
    try e(@as(u8, 0x0e), p.crc);
}

test "standard report encoding is unchanged and compact responses exclude tail bytes" {
    const packet = Packet.init(0x0f03, &.{ 0, 0, 0, 0, 1, 10, 20, 30, 40, 50, 60 });
    const report = try Report.fromPacket(packet, .{});
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&packet), report.bytes[1..91]);
    const compact = try Report.fromPacket(packet, .{ .compact = true, .report_id = 8 });
    try std.testing.expectEqual(@as(usize, 65), compact.len);
    try std.testing.expectEqual(@as(u8, 8), compact.bytes[0]);
    var reply: [91]u8 = @splat(0);
    @memcpy(reply[0..65], compact.bytes[0..65]);
    reply[1] = 2;
    reply[63] = 0xaa;
    reply[64] = 0xbb;
    const decoded = try decodeFormattedResponse(&reply, 65, 0x0f03, .{ .compact = true });
    try std.testing.expectEqualSlices(u8, packet.argSlice(), decoded.argSlice());
    try std.testing.expectEqual(@as(u8, 0), decoded.args[54]);
    try std.testing.expectError(error.BadResponse, decodeFormattedResponse(&reply, 64, 0x0f03, .{ .compact = true }));
    reply[6] = 55;
    try std.testing.expectError(error.BadResponse, decodeFormattedResponse(&reply, 65, 0x0f03, .{ .compact = true }));
    try std.testing.expectError(error.InvalidReport, Report.fromPacket(Packet.init(0x0f03, &@as([55]u8, @splat(0))), .{ .compact = true }));
}

test "checksum skips status and transaction id" {
    var p = Packet.init(0x0f02, &.{ 1, 5, 3 });
    const crc = p.checksum();

    p.status = 0xff;
    p.transaction_id = 0xff;
    try std.testing.expectEqual(crc, p.checksum());
}

test "response decoding rejects incomplete reports before reading padded data" {
    const packet = Packet.init(0x0792, &.{80});
    var report: [91]u8 = @splat(0);

    @memcpy(report[1..], std.mem.asBytes(&packet));
    report[1] = @backingInt(Status.success);

    for (0..report.len) |length|
        try std.testing.expectError(error.BadResponse, decodeResponse(&report, @intCast(length), 0x0792));

    try std.testing.expectError(error.ReadFailed, decodeResponse(&report, -1, 0x0792));
    try std.testing.expectError(error.BadResponse, decodeResponse(&report, 92, 0x0792));
    const response = try decodeResponse(&report, report.len, 0x0792);

    try std.testing.expectEqual(@as(u8, 80), response.argSlice()[0]);
    try std.testing.expectError(error.ResponseMismatch, decodeResponse(&report, report.len, 0x0084));
    report[6] = 81;
    try std.testing.expectError(error.BadResponse, decodeResponse(&report, report.len, 0x0792));
}

test "device open diagnostics distinguish opening from probe failures" {
    try std.testing.expectEqualStrings("cannot open (attached? in plugdev?)", openErrorMessage(error.OpenFailed));
    try std.testing.expectEqualStrings("opened a HID interface, but its device-mode probe failed", openErrorMessage(error.ReadFailed));
}

test "command payload requirements apply only to successful replies" {
    for ([_]u8{ 1, 2, 3, 4, 5, 12 }) |minimum| {
        const command: Command = .{ .id = 0x0792, .min_response = minimum };
        var packet = Packet.init(command.id, &.{});

        packet.status = @backingInt(Status.success);

        for (0..minimum) |length| {
            packet.data_size = @intCast(length);
            try std.testing.expectError(error.BadResponse, command.validate(packet));
        }

        packet.data_size = minimum;
        try command.validate(packet);
        packet.data_size = 80;
        try command.validate(packet);

        for ([_]Status{ .busy, .not_supported, .failed, .timeout, .new_command, .custom_command_mismatch }) |status| {
            packet.status = @backingInt(status);
            packet.data_size = 0;
            try command.validate(packet);
        }
    }

    const setter: Command = .{ .id = 0x0712 };
    var acknowledgement = Packet.init(setter.id, &.{});

    acknowledgement.status = @backingInt(Status.success);
    try setter.validate(acknowledgement);
}

test "sleep cancellation propagates before fetching a response" {
    const Stub = struct {
        fn sleep(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
            return error.Canceled;
        }
    };
    var vtable = std.testing.io.vtable.*;

    vtable.sleep = Stub.sleep;
    var hid: Device = .{
        .handle = undefined,
        .pid = 0,
        .io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable },
        .lock = undefined,
    };

    try std.testing.expectError(error.Canceled, hid.sleepMs(5));
    try std.testing.expectError(error.Canceled, hid.response(.{ .id = 0x0792, .min_response = 1 }));
}
