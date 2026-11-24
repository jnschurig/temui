//! Conversion from libretro's software framebuffer formats (D3) to temui's
//! internal format: packed RGB888, 3 bytes per pixel, row-major, no padding.
//! Pure: no allocation, no I/O.

const std = @import("std");

pub const Format = enum {
    /// `RETRO_PIXEL_FORMAT_0RGB1555`, the libretro default. Bit 15 is ignored.
    rgb1555,
    /// `RETRO_PIXEL_FORMAT_RGB565`.
    rgb565,
    /// `RETRO_PIXEL_FORMAT_XRGB8888`. The X byte is ignored.
    xrgb8888,

    pub fn bytesPerPixel(f: Format) usize {
        return switch (f) {
            .rgb1555, .rgb565 => 2,
            .xrgb8888 => 4,
        };
    }

    /// Maps a `retro_pixel_format` value; null for anything unsupported.
    pub fn fromRetro(value: i64) ?Format {
        return switch (value) {
            0 => .rgb1555,
            1 => .xrgb8888,
            2 => .rgb565,
            else => null,
        };
    }

    pub fn name(f: Format) []const u8 {
        return switch (f) {
            .rgb1555 => "0RGB1555",
            .rgb565 => "RGB565",
            .xrgb8888 => "XRGB8888",
        };
    }
};

pub const rgb_bytes = 3;

/// Converts a `width` × `height` image with rows `pitch` bytes apart from `src`
/// into packed RGB888 in `dst` (`width * height * 3` bytes). Source pixels are
/// little-endian, as on every D2 target. Bytes between the end of a row's
/// pixels and `pitch` are never read.
pub fn convert(format: Format, src: []const u8, width: usize, height: usize, pitch: usize, dst: []u8) void {
    const bpp = format.bytesPerPixel();
    std.debug.assert(pitch >= width * bpp);
    std.debug.assert(height == 0 or src.len >= (height - 1) * pitch + width * bpp);
    std.debug.assert(dst.len >= width * height * rgb_bytes);

    for (0..height) |y| {
        const row = src[y * pitch ..][0 .. width * bpp];
        const out = dst[y * width * rgb_bytes ..][0 .. width * rgb_bytes];
        switch (format) {
            .rgb1555 => for (0..width) |x| {
                const p = std.mem.readInt(u16, row[x * 2 ..][0..2], .little);
                out[x * 3 + 0] = expand5(@truncate(p >> 10));
                out[x * 3 + 1] = expand5(@truncate(p >> 5));
                out[x * 3 + 2] = expand5(@truncate(p));
            },
            .rgb565 => for (0..width) |x| {
                const p = std.mem.readInt(u16, row[x * 2 ..][0..2], .little);
                out[x * 3 + 0] = expand5(@truncate(p >> 11));
                out[x * 3 + 1] = expand6(@truncate(p >> 5));
                out[x * 3 + 2] = expand5(@truncate(p));
            },
            .xrgb8888 => for (0..width) |x| {
                // Little-endian 0xXXRRGGBB is stored as B, G, R, X.
                out[x * 3 + 0] = row[x * 4 + 2];
                out[x * 3 + 1] = row[x * 4 + 1];
                out[x * 3 + 2] = row[x * 4 + 0];
            },
        }
    }
}

/// 5-bit to 8-bit by bit replication, so 31 maps to 255 and 0 to 0.
fn expand5(v: u5) u8 {
    const w: u8 = v;
    return (w << 3) | (w >> 2);
}

/// 6-bit to 8-bit by bit replication, so 63 maps to 255 and 0 to 0.
fn expand6(v: u6) u8 {
    const w: u8 = v;
    return (w << 2) | (w >> 4);
}

const testing = std.testing;

fn le16(v: u16) [2]u8 {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    return b;
}

fn le32(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

fn expectPixel(format: Format, src: []const u8, want: [3]u8) !void {
    var out: [3]u8 = undefined;
    convert(format, src, 1, 1, format.bytesPerPixel(), &out);
    try testing.expectEqual(want, out);
}

test "bit replication" {
    try testing.expectEqual(@as(u8, 0), expand5(0));
    try testing.expectEqual(@as(u8, 255), expand5(31));
    try testing.expectEqual(@as(u8, 132), expand5(16)); // 10000 → 10000100
    try testing.expectEqual(@as(u8, 0), expand6(0));
    try testing.expectEqual(@as(u8, 255), expand6(63));
    try testing.expectEqual(@as(u8, 130), expand6(32)); // 100000 → 10000010
}

test "0RGB1555" {
    try expectPixel(.rgb1555, &le16(0x0000), .{ 0, 0, 0 });
    try expectPixel(.rgb1555, &le16(0x7fff), .{ 255, 255, 255 });
    try expectPixel(.rgb1555, &le16(0x7c00), .{ 255, 0, 0 });
    try expectPixel(.rgb1555, &le16(0x03e0), .{ 0, 255, 0 });
    try expectPixel(.rgb1555, &le16(0x001f), .{ 0, 0, 255 });
    try expectPixel(.rgb1555, &le16(0x4210), .{ 132, 132, 132 }); // 16,16,16
    // Bit 15 is ignored.
    try expectPixel(.rgb1555, &le16(0x8000), .{ 0, 0, 0 });
    try expectPixel(.rgb1555, &le16(0xffff), .{ 255, 255, 255 });
}

test "RGB565" {
    try expectPixel(.rgb565, &le16(0x0000), .{ 0, 0, 0 });
    try expectPixel(.rgb565, &le16(0xffff), .{ 255, 255, 255 });
    try expectPixel(.rgb565, &le16(0xf800), .{ 255, 0, 0 });
    try expectPixel(.rgb565, &le16(0x07e0), .{ 0, 255, 0 });
    try expectPixel(.rgb565, &le16(0x001f), .{ 0, 0, 255 });
    try expectPixel(.rgb565, &le16(0x8410), .{ 132, 130, 132 }); // 16,32,16
}

test "XRGB8888" {
    try expectPixel(.xrgb8888, &le32(0x00000000), .{ 0, 0, 0 });
    try expectPixel(.xrgb8888, &le32(0x00ffffff), .{ 255, 255, 255 });
    try expectPixel(.xrgb8888, &le32(0x00ff0000), .{ 255, 0, 0 });
    try expectPixel(.xrgb8888, &le32(0x0000ff00), .{ 0, 255, 0 });
    try expectPixel(.xrgb8888, &le32(0x000000ff), .{ 0, 0, 255 });
    try expectPixel(.xrgb8888, &le32(0x00804020), .{ 0x80, 0x40, 0x20 });
    // The X byte is ignored.
    try expectPixel(.xrgb8888, &le32(0xff000000), .{ 0, 0, 0 });
    try expectPixel(.xrgb8888, &le32(0xab123456), .{ 0x12, 0x34, 0x56 });
}

test "pitch padding is skipped" {
    // 2×2 RGB565 with a 6-byte pitch: 4 bytes of pixels + 2 bytes of padding
    // filled with white, which must not leak into the output.
    const pad = le16(0xffff);
    const src = le16(0xf800) ++ le16(0x07e0) ++ pad ++ le16(0x001f) ++ le16(0x0000) ++ pad;
    var out: [2 * 2 * 3]u8 = undefined;
    convert(.rgb565, &src, 2, 2, 6, &out);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0 }, &out);
}

test "pitch padding is skipped (XRGB8888, last row short)" {
    // The last row need not include its padding.
    const src = le32(0x00010203) ++ le32(0xffffffff) ++ le32(0x00040506);
    var out: [2 * 3]u8 = undefined;
    convert(.xrgb8888, &src, 1, 2, 8, &out);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &out);
}

test "fromRetro" {
    try testing.expectEqual(Format.rgb1555, Format.fromRetro(0).?);
    try testing.expectEqual(Format.xrgb8888, Format.fromRetro(1).?);
    try testing.expectEqual(Format.rgb565, Format.fromRetro(2).?);
    try testing.expectEqual(null, Format.fromRetro(3));
    try testing.expectEqual(null, Format.fromRetro(-1));
    try testing.expectEqual(null, Format.fromRetro(0xFFFF_FFFF));
}

test "fromRetro matches libretro.h" {
    const c = @import("libretro");
    try testing.expectEqual(Format.rgb1555, Format.fromRetro(c.RETRO_PIXEL_FORMAT_0RGB1555).?);
    try testing.expectEqual(Format.xrgb8888, Format.fromRetro(c.RETRO_PIXEL_FORMAT_XRGB8888).?);
    try testing.expectEqual(Format.rgb565, Format.fromRetro(c.RETRO_PIXEL_FORMAT_RGB565).?);
}
