//! Windows system battery queries; no vendor-specific driver interface.

const std = @import("std");
const battery = @import("battery.zig");
const c = @import("battery_windows_c");

const battery_interface: c.GUID = .{
    .Data1 = 0x72631e54,
    .Data2 = 0x78a4,
    .Data3 = 0x11d0,
    .Data4 = .{ 0xbc, 0xf7, 0x00, 0xaa, 0x00, 0xb7, 0xb3, 0x2a },
};

pub fn read() !battery.Reading {
    var result: battery.Reading = .{};
    var system: c.SYSTEM_POWER_STATUS = undefined;

    if (c.GetSystemPowerStatus(&system) == 0)
        return error.BatteryStatusFailed;

    if (system.BatteryFlag == 128)
        return result;

    if (system.BatteryLifePercent <= 100)
        result.percent = system.BatteryLifePercent;

    if (system.BatteryFlag != 255) {
        result.state = if (system.BatteryFlag & 8 != 0)
            .charging
        else if (system.ACLineStatus == 0)
            .discharging
        else if (system.ACLineStatus == 1)
            .idle
        else
            .unknown;
    }

    const devices = c.SetupDiGetClassDevsW(&battery_interface, null, null, c.DIGCF_PRESENT | c.DIGCF_DEVICEINTERFACE);

    if (devices == c.INVALID_HANDLE_VALUE)
        return error.BatteryEnumerationFailed;

    defer _ = c.SetupDiDestroyDeviceInfoList(devices);

    var index: c.DWORD = 0;

    while (true) : (index += 1) {
        var interface: c.SP_DEVICE_INTERFACE_DATA = std.mem.zeroes(c.SP_DEVICE_INTERFACE_DATA);

        interface.cbSize = @sizeOf(c.SP_DEVICE_INTERFACE_DATA);

        if (c.SetupDiEnumDeviceInterfaces(devices, null, &battery_interface, index, &interface) == 0) {
            if (c.GetLastError() == c.ERROR_NO_MORE_ITEMS)
                return result;

            return error.BatteryEnumerationFailed;
        }

        var storage: [4096]u8 align(@alignOf(c.SP_DEVICE_INTERFACE_DETAIL_DATA_W)) = undefined;
        const detail: *c.SP_DEVICE_INTERFACE_DETAIL_DATA_W = @ptrCast(&storage);

        detail.cbSize = @sizeOf(c.SP_DEVICE_INTERFACE_DETAIL_DATA_W);

        if (c.SetupDiGetDeviceInterfaceDetailW(devices, &interface, detail, storage.len, null, null) == 0)
            return error.BatteryInterfaceFailed;

        const handle = c.CreateFileW(@ptrCast(&detail.DevicePath), c.GENERIC_READ, c.FILE_SHARE_READ | c.FILE_SHARE_WRITE, null, c.OPEN_EXISTING, 0, null);

        if (handle == c.INVALID_HANDLE_VALUE)
            return error.BatteryOpenFailed;

        defer _ = c.CloseHandle(handle);

        var timeout: c.ULONG = 0;
        var tag: c.ULONG = 0;

        if (!try query(handle, c.IOCTL_BATTERY_QUERY_TAG, &timeout, &tag) or tag == 0)
            continue;

        var request: c.BATTERY_QUERY_INFORMATION = std.mem.zeroes(c.BATTERY_QUERY_INFORMATION);

        request.BatteryTag = tag;
        request.InformationLevel = c.BatteryInformation;
        var info: c.BATTERY_INFORMATION = undefined;

        if (!try query(handle, c.IOCTL_BATTERY_QUERY_INFORMATION, &request, &info))
            continue;

        if (info.Capabilities & c.BATTERY_SYSTEM_BATTERY == 0)
            continue;

        const absolute = info.Capabilities & c.BATTERY_CAPACITY_RELATIVE == 0;

        if (absolute) {
            result.energy_full = capacity(info.FullChargedCapacity);
            result.energy_design = capacity(info.DesignedCapacity);
        }

        var wait: c.BATTERY_WAIT_STATUS = std.mem.zeroes(c.BATTERY_WAIT_STATUS);

        wait.BatteryTag = tag;
        var status: c.BATTERY_STATUS = undefined;

        if (!try query(handle, c.IOCTL_BATTERY_QUERY_STATUS, &wait, &status))
            return result;

        result.state = if (status.PowerState & c.BATTERY_CHARGING != 0)
            .charging
        else if (status.PowerState & c.BATTERY_DISCHARGING != 0)
            .discharging
        else
            .idle;

        if (absolute) {
            result.energy = capacity(status.Capacity);
            result.rate = rate(status.Rate);
        }

        const capacity_known = status.Capacity != c.BATTERY_UNKNOWN_CAPACITY and
            info.FullChargedCapacity != c.BATTERY_UNKNOWN_CAPACITY and info.FullChargedCapacity > 0;

        if (result.percent == null and capacity_known)
            result.percent = @intFromFloat(@min(100, @as(f64, @floatFromInt(status.Capacity)) /
                @as(f64, @floatFromInt(info.FullChargedCapacity)) * 100));

        if (result.state == .idle and capacity_known and status.Capacity >= info.FullChargedCapacity)
            result.state = .full;

        return result;
    }
}

fn query(handle: c.HANDLE, code: c.DWORD, input: anytype, output: anytype) !bool {
    var returned: c.DWORD = 0;

    if (c.DeviceIoControl(handle, code, input, @sizeOf(@TypeOf(input.*)), output, @sizeOf(@TypeOf(output.*)), &returned, null) == 0)
        return switch (c.GetLastError()) {
            c.ERROR_INVALID_FUNCTION, c.ERROR_NOT_SUPPORTED, c.ERROR_FILE_NOT_FOUND => false,
            else => error.BatteryQueryFailed,
        };

    if (returned != @sizeOf(@TypeOf(output.*)))
        return error.InvalidBatteryResponse;

    return true;
}

fn capacity(value: c.ULONG) ?f64 {
    return if (value == c.BATTERY_UNKNOWN_CAPACITY) null else @as(f64, @floatFromInt(value)) / 1000;
}

fn rate(value: c.LONG) ?f64 {
    const unknown: c.LONG = @bitCast(@as(c.ULONG, c.BATTERY_UNKNOWN_RATE));

    return if (value == unknown) null else @as(f64, @floatFromInt(value)) / 1000;
}

comptime {
    std.debug.assert(rate(@bitCast(@as(c.ULONG, c.BATTERY_UNKNOWN_RATE))) == null);
    std.debug.assert(rate(-12500) == -12.5);
    std.debug.assert(capacity(c.BATTERY_UNKNOWN_CAPACITY) == null);
}

test "Windows battery snapshot uses standard queries" {
    _ = try read();
}
