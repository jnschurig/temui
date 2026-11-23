const std = @import("std");

pub fn main(init: std.process.Init) !void {
    _ = init;
}

test {
    std.testing.refAllDecls(@This());
}
