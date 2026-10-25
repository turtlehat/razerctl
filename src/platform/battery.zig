//! Host battery telemetry through standard operating-system interfaces. An OS
//! backend supplies `read`.

const std = @import("std");
const builtin = @import("builtin");

pub const State = enum { charging, discharging, full, idle, unknown };

pub const Reading = struct {
    percent: ?u8 = null,
    state: State = .unknown,
    rate: ?f64 = null,
    energy: ?f64 = null,
    energy_full: ?f64 = null,
    energy_design: ?f64 = null,
};

const Backend = switch (builtin.os.tag) {
    .linux => @import("battery_linux.zig"),
    .windows => @import("battery_windows.zig"),
    else => @compileError("battery telemetry is not supported on " ++ @tagName(builtin.os.tag)),
};

pub const read = Backend.read;

test {
    _ = Backend;
}
