pub const parse = @import("chroma/import.zig").parse;
pub const parseWithSeed = @import("chroma/import.zig").parseWithSeed;
pub const parseForDevice = @import("chroma/import.zig").parseForDevice;
pub const Profile = @import("chroma/profile.zig").Profile;
pub const Player = @import("chroma/render.zig").Player;
pub const KeyEvent = @import("chroma/profile.zig").KeyEvent;
pub const input = @import("chroma/render.zig").input;

test {
    @import("std").testing.refAllDecls(@import("chroma/import.zig"));
    @import("std").testing.refAllDecls(@import("chroma/effects.zig"));
    @import("std").testing.refAllDecls(@import("chroma/render.zig"));
    _ = @import("chroma/tests.zig");
    _ = @import("chroma/reactions.zig");
}
