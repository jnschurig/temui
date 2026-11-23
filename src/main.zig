const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;
}

test {
    std.testing.refAllDecls(@This());
}

test "vendored libretro.h translates" {
    try std.testing.expectEqual(1, @import("libretro").RETRO_API_VERSION);
}
