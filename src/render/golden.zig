//! Test-only helpers for renderer goldens: the fixed input (test-core frame
//! 60, an 80×24 rect of 10×20 px cells), byte comparison against
//! `testdata/golden/render-*`, and `-Dupdate-goldens` to rewrite them.
//! See `testdata/golden/README.md`.

const std = @import("std");
const testing = std.testing;
const test_options = @import("test_options");
const layout = @import("layout.zig");
const CellPx = @import("../term/caps.zig").CellPx;

pub const cell_px: CellPx = .{ .w = 10, .h = 20 };
pub const rect: layout.Rect = .{ .col = 1, .row = 1, .cols = 80, .rows = 24 };

/// Frame 60 of the test core in XRGB8888, from the committed PPM golden.
/// Caller frees `rgb`.
pub fn loadFrame60(gpa: std.mem.Allocator) !layout.Frame {
    const data = try std.Io.Dir.cwd().readFileAlloc(testing.io, test_options.golden_xrgb8888, gpa, .limited(1 << 20));
    errdefer gpa.free(data);
    const header = "P6\n256 224\n255\n";
    if (!std.mem.startsWith(u8, data, header) or data.len != header.len + 256 * 224 * 3) return error.BadPpm;
    std.mem.copyForwards(u8, data, data[header.len..]);
    const rgb = try gpa.realloc(data, 256 * 224 * 3);
    return .{ .width = 256, .height = 224, .rgb = rgb };
}

/// Compares `got` with `testdata/golden/<name>`. With `-Dupdate-goldens`, a
/// missing or different golden is rewritten and the test still fails, so an
/// update can never pass silently.
pub fn check(name: []const u8, got: []const u8) !void {
    const gpa = testing.allocator;
    const path = try std.fs.path.join(gpa, &.{ test_options.golden_dir, name });
    defer gpa.free(path);
    const cwd = std.Io.Dir.cwd();
    const want: ?[]u8 = cwd.readFileAlloc(testing.io, path, gpa, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (want) |w| gpa.free(w);
    // Text goldens may be checked out with CRLF (git autocrlf on Windows).
    const want_cmp: ?[]const u8 = if (want) |w| (if (std.mem.endsWith(u8, name, ".txt")) w[0..crlfToLf(w)] else w) else null;
    if (want_cmp != null and std.mem.eql(u8, want_cmp.?, got)) return;

    if (test_options.update_goldens) {
        try cwd.writeFile(testing.io, .{ .sub_path = path, .data = got });
        std.debug.print("golden {s}: rewritten ({d} bytes); inspect it before committing\n", .{ name, got.len });
        return error.GoldenUpdated;
    }
    if (want_cmp) |w| {
        const at = std.mem.indexOfDiff(u8, w, got) orelse @min(w.len, got.len);
        std.debug.print("golden {s}: differs at byte {d} (want {d} bytes, got {d}); regenerate with `zig build test -Dupdate-goldens` if intended\n", .{ name, at, w.len, got.len });
        return error.GoldenMismatch;
    }
    std.debug.print("golden {s}: missing; create it with `zig build test -Dupdate-goldens`\n", .{name});
    return error.GoldenMissing;
}

/// Rewrites every CRLF in `buf` as LF, in place; returns the new length.
fn crlfToLf(buf: []u8) usize {
    var n: usize = 0;
    for (buf, 0..) |b, i| {
        if (b == '\r' and i + 1 < buf.len and buf[i + 1] == '\n') continue;
        buf[n] = b;
        n += 1;
    }
    return n;
}

test crlfToLf {
    var buf = "a\r\nb\rc\r\n\n".*;
    try testing.expectEqualStrings("a\nb\rc\n\n", buf[0..crlfToLf(&buf)]);
}

pub const Scan = struct {
    /// Printed characters (escape sequences excluded).
    glyphs: usize = 0,
    /// CUP sequences.
    cups: usize = 0,
    /// The column every CUP moved to, or null if they differ (or none).
    only_col: ?u32 = null,
};

/// Counts glyphs and cursor moves in a cell backend's output.
pub fn scan(out: []const u8) !Scan {
    var s: Scan = .{};
    var mixed = false;
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] == 0x1b) {
            const start = i + 2;
            i = start;
            while (out[i] < 0x40 or out[i] > 0x7e) i += 1;
            if (out[i] == 'H') {
                s.cups += 1;
                const params = out[start..i];
                const semi = std.mem.indexOfScalar(u8, params, ';') orelse return error.BadCup;
                const col = try std.fmt.parseInt(u32, params[semi + 1 ..], 10);
                if (s.cups == 1) s.only_col = col else if (s.only_col != col) mixed = true;
            }
            i += 1;
            continue;
        }
        i += try std.unicode.utf8ByteSequenceLength(out[i]);
        s.glyphs += 1;
    }
    if (mixed) s.only_col = null;
    return s;
}
