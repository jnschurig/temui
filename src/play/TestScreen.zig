//! Test-only: a tiny terminal model that replays the bytes the viewer and
//! boxes write. It knows CUP, SGR (only whether the background is
//! non-default), ECH and `CSI 2 J`, and puts one code point per cell.

const std = @import("std");
const TestScreen = @This();

pub const Cell = struct {
    cp: u21 = ' ',
    /// A non-default background (a colour or reverse video).
    bg: bool = false,
};

pub const max_cells = 200 * 60;

cols: u32,
rows: u32,
cells: [max_cells]Cell = @splat(.{}),
row: u32 = 1,
col: u32 = 1,
bg_set: bool = false,
reverse: bool = false,

pub fn init(cols: u32, rows: u32) TestScreen {
    std.debug.assert(cols * rows <= max_cells);
    return .{ .cols = cols, .rows = rows };
}

/// The cell at 1-based `row`, `col`.
pub fn at(s: *const TestScreen, row: u32, col: u32) Cell {
    return s.cells[(row - 1) * s.cols + (col - 1)];
}

fn put(s: *TestScreen, cp: u21, bg: bool) void {
    if (s.row >= 1 and s.row <= s.rows and s.col >= 1 and s.col <= s.cols)
        s.cells[(s.row - 1) * s.cols + (s.col - 1)] = .{ .cp = cp, .bg = bg };
    s.col += 1;
}

pub fn feed(s: *TestScreen, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            if (i + 1 >= bytes.len or bytes[i + 1] != '[') return error.UnknownEscape;
            var j = i + 2;
            while (j < bytes.len and (bytes[j] < 0x40 or bytes[j] > 0x7e)) j += 1;
            if (j >= bytes.len) return error.TruncatedEscape;
            try s.csi(bytes[i + 2 .. j], bytes[j]);
            i = j + 1;
            continue;
        }
        const n = try std.unicode.utf8ByteSequenceLength(bytes[i]);
        const cp = try std.unicode.utf8Decode(bytes[i .. i + n]);
        s.put(cp, s.bg_set or s.reverse);
        i += n;
    }
}

fn csi(s: *TestScreen, params: []const u8, final: u8) !void {
    var nums: [16]u32 = undefined;
    var n: usize = 0;
    var it = std.mem.splitAny(u8, params, ";:");
    while (it.next()) |p| : (n += 1) {
        if (n == nums.len) return error.TooManyParams;
        nums[n] = if (p.len == 0) 0 else try std.fmt.parseInt(u32, p, 10);
    }
    switch (final) {
        'H' => {
            s.row = if (n > 0 and nums[0] > 0) nums[0] else 1;
            s.col = if (n > 1 and nums[1] > 0) nums[1] else 1;
        },
        'X' => {
            const count = if (n > 0 and nums[0] > 0) nums[0] else 1;
            const c0 = s.col;
            for (0..count) |_| s.put(' ', s.bg_set);
            s.col = c0;
        },
        'J' => if (n > 0 and nums[0] == 2) {
            s.cells = @splat(.{});
        },
        'm' => {
            if (n == 0) n = 1;
            var k: usize = 0;
            while (k < n) : (k += 1) switch (nums[k]) {
                0 => {
                    s.bg_set = false;
                    s.reverse = false;
                },
                7 => s.reverse = true,
                27 => s.reverse = false,
                49 => s.bg_set = false,
                38, 48 => {
                    if (nums[k] == 48) s.bg_set = true;
                    if (k + 1 < n and nums[k + 1] == 5) k += 2 else if (k + 1 < n and nums[k + 1] == 2) k += 4;
                },
                else => {},
            };
        },
        else => {},
    }
}

/// Row `row` as text, trailing spaces kept.
pub fn line(s: *const TestScreen, buf: []u8, row: u32) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (1..s.cols + 1) |c| {
        var tmp: [4]u8 = undefined;
        const k = std.unicode.utf8Encode(s.at(row, @intCast(c)).cp, &tmp) catch unreachable;
        w.writeAll(tmp[0..k]) catch break;
    }
    return w.buffered();
}

test "CUP, SGR and ECH" {
    var s: TestScreen = .init(10, 3);
    try s.feed("\x1b[2;3Hab\x1b[48;5;236mc\x1b[0md\x1b[3;1H\x1b[7mx\x1b[0m\x1b[3;1H\x1b[2X");
    try std.testing.expect(!s.at(2, 3).bg);
    try std.testing.expect(s.at(2, 5).bg);
    try std.testing.expectEqual('c', s.at(2, 5).cp);
    try std.testing.expect(!s.at(2, 6).bg);
    try std.testing.expectEqual(' ', s.at(3, 1).cp);
    try std.testing.expect(!s.at(3, 1).bg);
}
