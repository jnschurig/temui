//! Binary PPM (P6, maxval 255) encoding of packed RGB888 images.

const std = @import("std");

pub fn write(w: *std.Io.Writer, width: usize, height: usize, rgb: []const u8) std.Io.Writer.Error!void {
    std.debug.assert(rgb.len == width * height * 3);
    try w.print("P6\n{d} {d}\n255\n", .{ width, height });
    try w.writeAll(rgb);
}

test "2x1 image" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, 2, 1, &.{ 255, 0, 0, 0, 0, 255 });
    try std.testing.expectEqualSlices(u8, "P6\n2 1\n255\n\xff\x00\x00\x00\x00\xff", w.buffered());
}
