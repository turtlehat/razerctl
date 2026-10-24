const std = @import("std");

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Context for a failure, with its original cause kept separate until rendering.
pub const Failure = struct {
    message: []const u8,
    err: ?anyerror = null,
};

pub fn Result(comptime T: type) type {
    return union(enum) {
        success: T,
        failure: Failure,
    };
}
