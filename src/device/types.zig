//! Device descriptor contracts shared by descriptors and runtime engines.

const std = @import("std");
const capabilities = @import("capabilities");
const base = @import("device_base_types");

pub const Features = capabilities.Features;
pub const Mode = base.Mode;
pub const Range = base.Range;

/// Rounds rather than truncates so a percentage survives a set/get round trip.
pub fn pctToLevel(pct: u8) u8 {
    return @intCast((@as(u16, pct) * 255 + 50) / 100);
}

pub fn levelToPct(level: u8) u8 {
    return @intCast((@as(u16, level) * 100 + 127) / 255);
}

test "percent round-trips through a byte" {
    const e = std.testing.expectEqual;

    for ([_]u8{ 0, 1, 25, 33, 50, 66, 99, 100 }) |p|
        try e(p, levelToPct(pctToLevel(p)));

    try e(@as(u8, 255), pctToLevel(100));
    try e(@as(u8, 0), pctToLevel(0));
}

/// The wire byte is rpm/scale, so arbitrary numbers do not survive.
pub fn snap(rpm: u16, step: u16) u16 {
    return (rpm + step / 2) / step * step;
}

test "rpm snaps to the wire step" {
    const e = std.testing.expectEqual;

    try e(@as(u16, 1850), snap(1830, 50));
    try e(@as(u16, 1800), snap(1820, 50));
    try e(@as(u16, 2300), snap(2250, 100));
    try e(@as(u16, 2000), snap(2000, 100));
}

pub fn nameFor(modes: []const Mode, wire: u8) ?[]const u8 {
    for (modes) |mode|
        if (mode.wire == wire)
            return mode.name;

    return null;
}

/// Defaults to unverified capabilities until exercised on hardware.
pub const Provenance = enum {
    /// Exercised on hardware; absent fields are tested absences.
    measured,
    /// A hardware owner reports it behaves correctly.
    confirmed,
    /// Capabilities have not been verified on hardware.
    transcribed,
    /// No capability claims are made.
    unrecognised,
};

/// Descriptive only; categories do not uniquely identify attached devices.
pub const Category = enum { system, mouse, keyboard, keypad, mousemat, audio, gamepad, broadcaster, egpu, accessory };

pub const Descriptor = struct {
    pid: u16,
    name: []const u8,
    provenance: Provenance = .transcribed,
    category: Category,
    features: Features = .{},
};
