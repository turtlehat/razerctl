const std = @import("std");
const c = @import("keyboard_input_windows_c");

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("razerctl-keyboard");

// An HRAWINPUT is an opaque number that need not satisfy the alignment of the
// pointer type it is declared as, so @ptrFromInt would panic on it.
fn rawInputHandle(lparam: c.LPARAM) c.HRAWINPUT {
    const handle: extern union { number: usize, pointer: c.HRAWINPUT } = .{ .number = @bitCast(lparam) };

    return handle.pointer;
}

pub const Keyboard = struct {
    window: c.HWND,
    instance: c.HINSTANCE,
    devices: [8]c.HANDLE = undefined,
    len: usize = 0,

    pub fn open(pid: u16) !Keyboard {
        const instance = c.GetModuleHandleW(null);
        var window_class: c.WNDCLASSW = std.mem.zeroes(c.WNDCLASSW);
        window_class.lpfnWndProc = c.DefWindowProcW;
        window_class.hInstance = instance;
        window_class.lpszClassName = class_name;
        if (c.RegisterClassW(&window_class) == 0)
            return error.KeyboardOpenFailed;
        errdefer _ = c.UnregisterClassW(class_name, instance);

        const window = c.CreateWindowExW(0, class_name, class_name, 0, 0, 0, 0, 0, null, null, instance, null) orelse
            return error.KeyboardOpenFailed;
        errdefer _ = c.DestroyWindow(window);
        var self: Keyboard = .{ .window = window, .instance = instance };
        var count: c.UINT = 0;
        if (c.GetRawInputDeviceList(null, &count, @sizeOf(c.RAWINPUTDEVICELIST)) == std.math.maxInt(c.UINT))
            return error.KeyboardOpenFailed;
        if (count == 0) return error.KeyboardNotFound;
        const devices = try std.heap.page_allocator.alloc(c.RAWINPUTDEVICELIST, count);
        defer std.heap.page_allocator.free(devices);
        const found = c.GetRawInputDeviceList(devices.ptr, &count, @sizeOf(c.RAWINPUTDEVICELIST));
        if (found == std.math.maxInt(c.UINT))
            return error.KeyboardOpenFailed;
        for (devices[0..found]) |device| {
            if (device.dwType != c.RIM_TYPEKEYBOARD or !try matchesDevice(device.hDevice, pid))
                continue;
            if (self.len == self.devices.len)
                return error.KeyboardTooManyDevices;
            self.devices[self.len] = device.hDevice;
            self.len += 1;
        }
        if (self.len == 0) return error.KeyboardNotFound;
        const registration: c.RAWINPUTDEVICE = .{
            .usUsagePage = 1,
            .usUsage = 6,
            .dwFlags = c.RIDEV_INPUTSINK,
            .hwndTarget = window,
        };
        if (c.RegisterRawInputDevices(&registration, 1, @sizeOf(c.RAWINPUTDEVICE)) == 0)
            return error.KeyboardOpenFailed;
        return self;
    }

    pub fn deinit(self: *Keyboard) void {
        const registration: c.RAWINPUTDEVICE = .{
            .usUsagePage = 1,
            .usUsage = 6,
            .dwFlags = c.RIDEV_REMOVE,
            .hwndTarget = null,
        };
        if (c.RegisterRawInputDevices(&registration, 1, @sizeOf(c.RAWINPUTDEVICE)) == 0)
            @panic("keyboard input unregister failed");
        if (c.DestroyWindow(self.window) == 0)
            @panic("keyboard window close failed");
        if (c.UnregisterClassW(class_name, self.instance) == 0)
            @panic("keyboard window class unregister failed");
    }

    pub fn next(self: *Keyboard) !?struct { code: u16, pressed: bool } {
        var message: c.MSG = undefined;
        while (c.PeekMessageW(&message, self.window, 0, 0, c.PM_REMOVE) != 0) {
            // DefWindowProc releases foreground Raw Input resources after decoding.
            defer _ = c.DispatchMessageW(&message);
            if (message.message != c.WM_INPUT) continue;
            var raw: c.RAWINPUT = undefined;
            var size: c.UINT = @sizeOf(c.RAWINPUT);
            const read = c.GetRawInputData(rawInputHandle(message.lParam), c.RID_INPUT, &raw, &size, @sizeOf(c.RAWINPUTHEADER));
            if (read == std.math.maxInt(c.UINT) or read < @sizeOf(c.RAWINPUTHEADER))
                return error.KeyboardReadFailed;
            if (raw.header.dwType != c.RIM_TYPEKEYBOARD) continue;
            if (read < @sizeOf(c.RAWINPUTHEADER) + @sizeOf(c.RAWKEYBOARD))
                return error.KeyboardReadFailed;
            var selected = false;
            for (self.devices[0..self.len]) |device| {
                if (device == raw.header.hDevice) selected = true;
            }
            if (!selected) continue;
            const key = raw.data.keyboard;
            if (key.VKey >= 255 or key.MakeCode == 0xff) continue;
            const scan = if (key.MakeCode != 0)
                key.MakeCode
            else
                c.MapVirtualKeyW(key.VKey, c.MAPVK_VK_TO_VSC_EX);
            const flags = key.Flags | @as(u16, if (scan & 0xff00 == 0xe000) c.RI_KEY_E0 else if (scan & 0xff00 == 0xe100) c.RI_KEY_E1 else 0);
            const code = keyCode(@intCast(scan & 0xff), flags) orelse continue;
            return .{ .code = code, .pressed = key.Flags & c.RI_KEY_BREAK == 0 };
        }
        return null;
    }
};

fn matchesDevice(device: c.HANDLE, pid: u16) !bool {
    var length: c.UINT = 0;
    if (c.GetRawInputDeviceInfoW(device, c.RIDI_DEVICENAME, null, &length) == std.math.maxInt(c.UINT))
        return error.KeyboardOpenFailed;
    const name = try std.heap.page_allocator.alloc(u16, length);
    defer std.heap.page_allocator.free(name);
    const read = c.GetRawInputDeviceInfoW(device, c.RIDI_DEVICENAME, name.ptr, &length);
    if (read == std.math.maxInt(c.UINT))
        return error.KeyboardOpenFailed;
    return matchesName(name[0..read], pid);
}

fn matchesName(name: []const u16, pid: u16) bool {
    var buffer: [17]u8 = undefined;
    const needle = std.fmt.bufPrint(&buffer, "vid_1532&pid_{x:0>4}", .{pid}) catch unreachable;
    if (name.len < needle.len) return false;
    for (0..name.len - needle.len + 1) |offset| {
        for (needle, name[offset..][0..needle.len]) |expected, actual| {
            if (actual > 127 or std.ascii.toLower(@intCast(actual)) != expected) break;
        } else return true;
    }
    return false;
}

// Normalize physical Windows scan codes to the codes used by our shared LED maps.
fn keyCode(scan: u16, flags: u16) ?u16 {
    if (flags & c.RI_KEY_E1 != 0)
        return if (scan == 0x45) 119 else null;
    if (flags & c.RI_KEY_E0 != 0) return switch (scan) {
        0x1c => 96,
        0x1d => 97,
        0x35 => 98,
        0x37 => 99,
        0x38 => 100,
        0x45 => 69,
        0x46 => 119,
        0x47 => 102,
        0x48 => 103,
        0x49 => 104,
        0x4b => 105,
        0x4d => 106,
        0x4f => 107,
        0x50 => 108,
        0x51 => 109,
        0x52 => 110,
        0x53 => 111,
        0x5b => 125,
        0x5c => 126,
        0x5d => 127,
        else => null,
    };
    return switch (scan) {
        1...0x58 => scan,
        0x70 => 93,
        0x73 => 89,
        0x79 => 92,
        0x7b => 94,
        0x7d => 124,
        else => null,
    };
}

test "device filter accepts only the selected Razer product" {
    try std.testing.expect(matchesName(std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\HID#VID_1532&PID_02B6&MI_00"), 0x02b6));
    try std.testing.expect(matchesName(std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\hid#vid_1532&pid_02b6"), 0x02b6));
    try std.testing.expect(!matchesName(std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\HID#VID_1532&PID_02B7"), 0x02b6));
    try std.testing.expect(!matchesName(std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\HID#VID_1234&PID_02B6"), 0x02b6));
}

test "scan codes preserve physical keys and extended distinctions" {
    try std.testing.expectEqual(@as(?u16, 30), keyCode(0x1e, 0));
    try std.testing.expectEqual(@as(?u16, 30), keyCode(0x1e, c.RI_KEY_BREAK));
    try std.testing.expectEqual(@as(?u16, 28), keyCode(0x1c, 0));
    try std.testing.expectEqual(@as(?u16, 96), keyCode(0x1c, c.RI_KEY_E0));
    try std.testing.expectEqual(@as(?u16, 100), keyCode(0x38, c.RI_KEY_E0));
    try std.testing.expectEqual(@as(?u16, 103), keyCode(0x48, c.RI_KEY_E0));
    try std.testing.expectEqual(@as(?u16, 69), keyCode(0x45, c.RI_KEY_E0));
    try std.testing.expectEqual(@as(?u16, 119), keyCode(0x45, c.RI_KEY_E1));
    try std.testing.expectEqual(@as(?u16, 89), keyCode(0x73, 0));
    try std.testing.expectEqual(@as(?u16, null), keyCode(0x2a, c.RI_KEY_E0));
}

test "raw input handles keep odd values without an alignment check" {
    const lparam: c.LPARAM = 0x1001;

    try std.testing.expectEqual(@as(usize, 0x1001), @intFromPtr(rawInputHandle(lparam)));
}
