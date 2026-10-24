//! Power Mode Control (0x070f): one byte of independent flags shared by
//! power, system_performance and display. Writes preserve unrelated bits.

const transport = @import("transport");

pub const Bit = enum(u8) {
    max_fan = 0x02,
    charge_override = 0x04,
    local_dimming = 0x08,
};

const SET: transport.Command = .{ .id = 0x070f };
pub const GET: transport.Command = .{ .id = 0x078f, .min_response = 1 };

fn get(hid: *transport.Device) !u8 {
    return (try hid.call(GET, &.{0})).argSlice()[0];
}

pub fn read(hid: *transport.Device, bit: Bit) !bool {
    return try get(hid) & @backingInt(bit) != 0;
}

/// Always writes. Returns whether the bit was set before.
pub fn write(hid: *transport.Device, bit: Bit, on: bool) !bool {
    const cur = try get(hid);
    const mask = @backingInt(bit);

    _ = try hid.call(SET, &.{if (on) cur | mask else cur & ~mask});

    return cur & mask != 0;
}
