//! kitty graphics protocol encoders, one per transport. Each call to
//! `Encoder.encode` returns the complete bytes for one frame: cursor
//! positioning plus an `a=T` transmit-and-display command that reuses one
//! image id and one placement id (D7), scaled by the terminal to a cell box.

const std = @import("std");
const c = std.c;
const flate = std.compress.flate;
const cli = @import("cli.zig");
const scene = @import("scene.zig");
const term = @import("term.zig");

/// Max base64 payload bytes per escape sequence (protocol limit).
pub const chunk_len = 4096;
const raw_chunk_len = chunk_len / 4 * 3;
const b64 = std.base64.standard.Encoder;

pub const Kind = enum { inline_rgb, inline_rgba, inline_zlib, file, shm };

pub fn kind(t: cli.Transport) ?Kind {
    return switch (t) {
        .@"inline-rgb" => .inline_rgb,
        .@"inline-rgba" => .inline_rgba,
        .@"inline-zlib" => .inline_zlib,
        .file => .file,
        .shm => .shm,
        .@"half-full", .@"half-diff" => null,
    };
}

/// Pixel format each transport sends. Bytes don't cross the PTY for file and
/// shm, so those send RGBA (what a GPU texture wants); zlib compresses RGB.
pub fn format(k: Kind) scene.Format {
    return switch (k) {
        .inline_rgb, .inline_zlib => .rgb,
        .inline_rgba, .file, .shm => .rgba,
    };
}

/// Where and how big the image is drawn, in cells. `col`/`row` are 1-based.
pub const Placement = struct { col: u32, row: u32, cols: u32, rows: u32 };

/// Largest box that fits the window above `reserved_rows` while keeping the
/// image's aspect ratio, centred horizontally. Assumes 1:2 cells when the
/// terminal doesn't report pixel sizes.
pub fn place(win: term.Size, img_w: u32, img_h: u32, reserved_rows: u32) Placement {
    var cw = win.cellW();
    var ch = win.cellH();
    if (cw == 0 or ch == 0) {
        cw = 1;
        ch = 2;
    }
    const avail_rows = @max(@as(u32, win.rows) -| reserved_rows, 1);
    const avail_w = @as(f64, @floatFromInt(win.cols)) * cw;
    const avail_h = @as(f64, @floatFromInt(avail_rows)) * ch;
    const iw: f64 = @floatFromInt(img_w);
    const ih: f64 = @floatFromInt(img_h);
    const scale = @min(avail_w / iw, avail_h / ih);
    const cols: u32 = @max(1, @as(u32, @intFromFloat(@floor(iw * scale / cw))));
    const rows: u32 = @max(1, @as(u32, @intFromFloat(@floor(ih * scale / ch))));
    return .{ .col = 1 + (win.cols -| cols) / 2, .row = 1, .cols = cols, .rows = rows };
}

pub const Encoder = struct {
    gpa: std.mem.Allocator,
    kind: Kind,
    /// Bytes of the most recent frame.
    out: std.ArrayList(u8) = .empty,
    /// zlib only: compressed frame and the compressor's window.
    zbuf: []u8 = &.{},
    window: []u8 = &.{},
    /// file only: `$TMPDIR` with a trailing slash.
    tmpdir: []const u8,
    pid: c.pid_t,
    /// Alternate image ids 1 and 2, deleting the other id's placement after
    /// each frame, so the terminal never shows a frame with no image.
    double_buffer: bool = false,
    /// Frames encoded; also the name counter for file/shm objects.
    frames: u64 = 0,
    /// file/shm objects for frames below this were already unlinked.
    released: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, k: Kind, frame_len: usize, tmpdir: []const u8) !Encoder {
        var e: Encoder = .{
            .gpa = gpa,
            .kind = k,
            .tmpdir = try std.fmt.allocPrint(gpa, "{s}{s}", .{ tmpdir, if (std.mem.endsWith(u8, tmpdir, "/")) "" else "/" }),
            .pid = c.getpid(),
        };
        errdefer e.deinit();
        // Base64 plus ~40 bytes of framing per chunk, plus the first header.
        try e.out.ensureTotalCapacity(gpa, b64.calcSize(frame_len) + (frame_len / raw_chunk_len + 1) * 48 + 256);
        if (k == .inline_zlib) {
            // Deflate's worst case is stored blocks: 5 bytes per 64 KiB.
            e.zbuf = try gpa.alloc(u8, frame_len + frame_len / 1024 + 64);
            e.window = try gpa.alloc(u8, flate.max_window_len);
        }
        return e;
    }

    /// Unlinks every file/shm object still outstanding, then frees.
    pub fn deinit(e: *Encoder) void {
        e.release(e.frames);
        e.out.deinit(e.gpa);
        e.gpa.free(e.zbuf);
        e.gpa.free(e.window);
        e.gpa.free(e.tmpdir);
        e.* = undefined;
    }

    /// Encodes one frame (`pixels` in `format(kind)`, w×h) placed at `p`.
    pub fn encode(e: *Encoder, pixels: []const u8, w: u32, h: u32, p: Placement) ![]const u8 {
        const gpa = e.gpa;
        const fmt = format(e.kind);
        std.debug.assert(pixels.len == @as(usize, w) * h * fmt.bpp());
        e.out.clearRetainingCapacity();
        const n = e.frames;
        e.frames += 1;
        const id: u32 = if (e.double_buffer) 1 + @as(u32, @intCast(n % 2)) else 1;

        try e.out.print(gpa, "\x1b[{d};{d}H\x1b_Ga=T,i={d},p=1,q=1,C=1,c={d},r={d},f={d},s={d},v={d}", .{
            p.row, p.col, id, p.cols, p.rows, fmt.bpp() * 8, w, h,
        });
        switch (e.kind) {
            .inline_rgb, .inline_rgba => try e.appendChunked(pixels),
            .inline_zlib => {
                try e.out.appendSlice(gpa, ",o=z");
                try e.appendChunked(try e.compress(pixels));
            },
            .file => {
                var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const path = try e.objectName(&path_buf, n);
                try writeFile(path, pixels);
                try e.out.appendSlice(gpa, ",t=t");
                try e.appendChunked(path);
            },
            .shm => {
                var name_buf: [32]u8 = undefined;
                const name = try e.objectName(&name_buf, n);
                try writeShm(name, pixels);
                try e.out.print(gpa, ",t=s,S={d}", .{pixels.len});
                try e.appendChunked(name);
            },
        }
        // The new frame is placed; now drop the previous one (q=2: the first
        // frame has nothing to delete).
        if (e.double_buffer) try e.out.print(gpa, "\x1b_Ga=d,d=i,i={d},q=2\x1b\\", .{3 - id});
        return e.out.items;
    }

    /// Unlinks file/shm objects for frames below `upto` (ENOENT ignored: the
    /// terminal normally deletes them after reading). Off the per-frame path:
    /// call at status-bar ticks with the ack count, and at cell end.
    pub fn release(e: *Encoder, upto: u64) void {
        if (e.kind != .file and e.kind != .shm) return;
        const end = @min(upto, e.frames);
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        while (e.released < end) : (e.released += 1) {
            const name = e.objectName(&buf, e.released) catch continue;
            _ = if (e.kind == .file) c.unlink(name) else c.shm_unlink(name);
        }
    }

    /// Unique per frame, since several frames may be unread at once.
    /// shm names stay under macOS's 31-byte limit.
    fn objectName(e: *const Encoder, buf: []u8, n: u64) ![:0]const u8 {
        return switch (e.kind) {
            .file => std.mem.printSentinel(buf, "{s}tty-graphics-protocol-termbench-{d}-{d}.rgba", .{ e.tmpdir, e.pid, n }, 0),
            .shm => std.mem.printSentinel(buf, "/tgp-{d}-{d}", .{ e.pid, n }, 0),
            else => unreachable,
        };
    }

    fn compress(e: *Encoder, raw: []const u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(e.zbuf);
        var z = try flate.Compress.init(&w, e.window, .zlib, .fastest);
        try z.writer.writeAll(raw);
        try z.finish();
        return w.buffered();
    }

    /// Appends `;payload` as base64, split into `m=1` chunks of at most
    /// `chunk_len` bytes; the last chunk has `m=0`. The first chunk carries
    /// the keys already in `out`; later chunks carry only `m`.
    fn appendChunked(e: *Encoder, raw: []const u8) !void {
        const gpa = e.gpa;
        var rest = raw;
        var first = true;
        while (true) {
            const take = @min(rest.len, raw_chunk_len);
            const last = take == rest.len;
            if (!first) try e.out.appendSlice(gpa, "\x1b_G");
            try e.out.appendSlice(gpa, if (first) (if (last) "" else ",m=1") else (if (last) "m=0" else "m=1"));
            try e.out.append(gpa, ';');
            const dst = try e.out.addManyAsSlice(gpa, b64.calcSize(take));
            _ = b64.encode(dst, rest[0..take]);
            try e.out.appendSlice(gpa, "\x1b\\");
            rest = rest[take..];
            first = false;
            if (last) break;
        }
    }
};

fn writeFile(path: [:0]const u8, bytes: []const u8) !void {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.TempFileOpen;
    defer _ = c.close(fd);
    try writeFd(fd, bytes);
}

fn writeFd(fd: c.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n < 0) {
            if (c._errno().* == @backingInt(c.E.INTR)) continue;
            return error.TempFileWrite;
        }
        rest = rest[@intCast(n)..];
    }
}

fn writeShm(name: [:0]const u8, bytes: []const u8) !void {
    const flags: c_int = @bitCast(c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true });
    const fd = c.shm_open(name, flags, @as(c.mode_t, 0o600));
    if (fd < 0) return error.ShmOpen;
    defer _ = c.close(fd);
    if (c.ftruncate(fd, @intCast(bytes.len)) != 0) return error.ShmTruncate;
    const p = c.mmap(null, bytes.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (p == c.MAP_FAILED) return error.ShmMap;
    const mem: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(p));
    @memcpy(mem[0..bytes.len], bytes);
    _ = c.munmap(mem, bytes.len);
}

// ---- tests ----

const testing = std.testing;

const Chunk = struct { keys: []const u8, payload: []const u8 };

/// Splits encoder output (after the leading CUP) into APC G commands.
fn chunks(out: []const u8, buf: []Chunk) ![]Chunk {
    var n: usize = 0;
    var rest = out[std.mem.indexOf(u8, out, "\x1b_G").?..];
    while (rest.len > 0) {
        try testing.expect(std.mem.startsWith(u8, rest, "\x1b_G"));
        const end = std.mem.indexOf(u8, rest, "\x1b\\").?;
        const body = rest[3..end];
        const semi = std.mem.indexOfScalar(u8, body, ';').?;
        buf[n] = .{ .keys = body[0..semi], .payload = body[semi + 1 ..] };
        n += 1;
        rest = rest[end + 2 ..];
    }
    return buf[0..n];
}

fn decodeAll(gpa: std.mem.Allocator, cs: []const Chunk) ![]u8 {
    var b64s: std.ArrayList(u8) = .empty;
    defer b64s.deinit(gpa);
    for (cs) |ch| try b64s.appendSlice(gpa, ch.payload);
    const d = std.base64.standard.Decoder;
    const out = try gpa.alloc(u8, try d.calcSizeForSlice(b64s.items));
    try d.decode(out, b64s.items);
    return out;
}

const test_place: Placement = .{ .col = 3, .row = 1, .cols = 40, .rows = 20 };

test "inline chunk framing" {
    const gpa = testing.allocator;
    var l = try scene.Loop.init(gpa, .scroll, .@"256x224", .rgb);
    defer l.deinit(gpa);
    var e = try Encoder.init(gpa, .inline_rgb, l.frame_len, "/tmp");
    defer e.deinit();
    const out = try e.encode(l.frame(3), 256, 224, test_place);
    try testing.expect(std.mem.startsWith(u8, out, "\x1b[1;3H\x1b_Ga=T,i=1,p=1,q=1,C=1,c=40,r=20,f=24,s=256,v=224,m=1;"));
    var buf: [128]Chunk = undefined;
    const cs = try chunks(out, &buf);
    try testing.expectEqual(@as(usize, (256 * 224 * 3 + raw_chunk_len - 1) / raw_chunk_len), cs.len);
    for (cs, 0..) |ch, i| {
        try testing.expect(ch.payload.len <= chunk_len);
        if (i > 0) try testing.expectEqualStrings(if (i + 1 == cs.len) "m=0" else "m=1", ch.keys);
    }
    const back = try decodeAll(gpa, cs);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, l.frame(3), back);
}

test "single-chunk payload has no m key" {
    const gpa = testing.allocator;
    var e = try Encoder.init(gpa, .inline_rgba, 4, "/tmp");
    defer e.deinit();
    const out = try e.encode(&.{ 1, 2, 3, 255 }, 1, 1, test_place);
    try testing.expectEqualStrings("\x1b[1;3H\x1b_Ga=T,i=1,p=1,q=1,C=1,c=40,r=20,f=32,s=1,v=1;AQID/w==\x1b\\", out);
}

test "double buffer alternates ids and deletes the previous placement" {
    const gpa = testing.allocator;
    var e = try Encoder.init(gpa, .inline_rgba, 4, "/tmp");
    defer e.deinit();
    e.double_buffer = true;
    const px = [_]u8{ 1, 2, 3, 255 };
    const head = "\x1b[1;3H\x1b_Ga=T,i={d},p=1,q=1,C=1,c=40,r=20,f=32,s=1,v=1;AQID/w==\x1b\\\x1b_Ga=d,d=i,i={d},q=2\x1b\\";
    var buf: [128]u8 = undefined;
    for ([_][2]u32{ .{ 1, 2 }, .{ 2, 1 }, .{ 1, 2 } }) |ids| {
        const out = try e.encode(&px, 1, 1, test_place);
        try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, head, .{ ids[0], ids[1] }), out);
    }
}

test "zlib payload round-trips" {
    const gpa = testing.allocator;
    var l = try scene.Loop.init(gpa, .sprites, .@"320x240", .rgb);
    defer l.deinit(gpa);
    var e = try Encoder.init(gpa, .inline_zlib, l.frame_len, "/tmp");
    defer e.deinit();
    const out = try e.encode(l.frame(7), 320, 240, test_place);
    var buf: [128]Chunk = undefined;
    const cs = try chunks(out, &buf);
    try testing.expectEqualStrings("a=T,i=1,p=1,q=1,C=1,c=40,r=20,f=24,s=320,v=240,o=z,m=1", cs[0].keys);
    const z = try decodeAll(gpa, cs);
    defer gpa.free(z);
    try testing.expect(z.len < l.frame_len / 2);
    var r: std.Io.Reader = .fixed(z);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&r, .zlib, &window);
    const back = try d.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, l.frame(7), back);
}

test "file transport writes the frame and release unlinks it" {
    const gpa = testing.allocator;
    const px = [_]u8{ 9, 8, 7, 255, 1, 2, 3, 255 };
    var e = try Encoder.init(gpa, .file, px.len, "/tmp");
    defer e.deinit();
    const out = try e.encode(&px, 2, 1, test_place);
    var buf: [4]Chunk = undefined;
    const cs = try chunks(out, &buf);
    try testing.expectEqual(@as(usize, 1), cs.len);
    try testing.expect(std.mem.endsWith(u8, cs[0].keys, ",t=t"));
    const path = try decodeAll(gpa, cs);
    defer gpa.free(path);
    try testing.expect(std.mem.indexOf(u8, path, "tty-graphics-protocol") != null);
    const pathz = try gpa.dupeSentinel(u8, path, 0);
    defer gpa.free(pathz);
    var got: [16]u8 = undefined;
    const fd = c.open(pathz, .{ .ACCMODE = .RDONLY });
    try testing.expect(fd >= 0);
    const n = c.read(fd, &got, got.len);
    _ = c.close(fd);
    try testing.expectEqualSlices(u8, &px, got[0..@intCast(n)]);
    e.release(1);
    try testing.expect(c.access(pathz, c.F_OK) != 0);
}

test "shm transport writes the frame and release unlinks it" {
    const gpa = testing.allocator;
    const px = [_]u8{ 9, 8, 7, 255, 1, 2, 3, 255 };
    var e = try Encoder.init(gpa, .shm, px.len, "/tmp");
    defer e.deinit();
    const out = try e.encode(&px, 2, 1, test_place);
    var buf: [4]Chunk = undefined;
    const cs = try chunks(out, &buf);
    try testing.expect(std.mem.endsWith(u8, cs[0].keys, ",t=s,S=8"));
    const name = try decodeAll(gpa, cs);
    defer gpa.free(name);
    try testing.expect(name.len <= 31);
    const namez = try gpa.dupeSentinel(u8, name, 0);
    defer gpa.free(namez);
    const fd = c.shm_open(namez, @bitCast(c.O{ .ACCMODE = .RDONLY }), @as(c.mode_t, 0));
    try testing.expect(fd >= 0);
    const p = c.mmap(null, px.len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
    _ = c.close(fd);
    try testing.expect(p != c.MAP_FAILED);
    const mem: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(p));
    try testing.expectEqualSlices(u8, &px, mem[0..px.len]);
    _ = c.munmap(mem, px.len);
    e.release(1);
    try testing.expect(c.shm_open(namez, @bitCast(c.O{ .ACCMODE = .RDONLY }), @as(c.mode_t, 0)) < 0);
}

test "place keeps aspect ratio and centres" {
    // 160x61 cells of 8x16 px; one status row.
    const p = place(.{ .cols = 160, .rows = 61, .px_w = 1280, .px_h = 976 }, 256, 224, 1);
    // Height-bound: 60 rows * 16 = 960 px tall -> 1097 px wide -> 137 cols.
    try testing.expectEqual(@as(u32, 60), p.rows);
    try testing.expectEqual(@as(u32, 137), p.cols);
    try testing.expectEqual(@as(u32, 1 + (160 - 137) / 2), p.col);
}
