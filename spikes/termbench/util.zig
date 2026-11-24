const std = @import("std");
const Io = std.Io;

/// `YYYYMMDDTHHMMSSZ` for the current UTC time.
pub fn utcStamp(io: Io, buf: *[16]u8) []const u8 {
    const ns = Io.Clock.real.now(io).nanoseconds;
    const secs: u64 = @intCast(@divFloor(@max(ns, 0), std.time.ns_per_s));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Writes `value` as one JSON line to a new file at `path`.
pub fn writeJsonFile(io: Io, path: []const u8, value: anytype) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &fw.interface);
    try fw.interface.writeByte('\n');
    try fw.interface.flush();
}
