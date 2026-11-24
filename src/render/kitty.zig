//! Kitty graphics backend (D7). Frames go to the terminal at native
//! resolution and the terminal scales them to the fitted cell box (`c=`,
//! `r=`). Each instance owns two image ids and alternates them: frame N is
//! transmitted and placed on one id, then the other id's placement is
//! deleted, so there is never a moment with no image (a single id flickers
//! in Ghostty).
//!
//! Transports, tried in the order detection chose: shared memory (`t=s`,
//! RGBA), temp file (`t=t`, RGBA), inline zlib (`o=z`, RGB, base64 in
//! ≤ 4096-byte chunks). shm and file are POSIX-only. Frames use `q=2`, so the
//! terminal never answers; if temui fails to create a shm object or file,
//! the backend logs a warning and moves to the next transport for good.
//!
//! The terminal unlinks shm objects and temp files once it has read them.
//! Ones it never read are unlinked by temui 5 s after creation (checked on
//! each `present`) and on `deinit`.

const std = @import("std");
const builtin = @import("builtin");
const layout = @import("layout.zig");
const sgr = @import("sgr.zig");
const caps = @import("../term/caps.zig");

const Io = std.Io;
const c = std.c;
const flate = std.compress.flate;
const log = std.log.scoped(.render);

const Rect = layout.Rect;
const Frame = layout.Frame;
const CellPx = caps.CellPx;
const Transport = caps.Transport;

/// shm and file transports exist only here.
pub const posix = builtin.os.tag != .windows;

/// Max base64 bytes per escape sequence (protocol limit).
pub const chunk_len = 4096;
const raw_chunk_len = chunk_len / 4 * 3;
const b64 = std.base64.standard.Encoder;

/// Objects the terminal hasn't consumed after this long are unlinked.
pub const object_ttl_ns: i96 = 5 * std.time.ns_per_s;

/// Hands out id pairs (`2k+1`, `2k+2`) so instances never share ids.
var next_pair: std.atomic.Value(u32) = .init(0);

pub const Options = struct {
    /// Directory for temp-file frames; default `$TMPDIR`, else `/tmp`.
    tmp_dir: ?[]const u8 = null,
    /// Names are `<tmp_dir>/tty-graphics-protocol-<prefix>-<pid>-<pair>-<n>.rgba`
    /// and shm `/<prefix>-<pid>-<pair>-<n>` (at most 31 bytes, macOS's limit).
    prefix: []const u8 = "temui",
    /// Tests only: fixes the instance number instead of taking the next one.
    pair: ?u32 = null,
};

const Object = struct { transport: Transport, serial: u64, created_ns: i96 };

pub const Kitty = struct {
    gpa: std.mem.Allocator,
    io: Io,
    cell_px: CellPx,
    pair: u32,
    ids: [2]u32,
    /// Index into `ids` for the next frame.
    next: u1 = 0,
    /// `ids[i]` has a placement on screen.
    placed: [2]bool = .{ false, false },
    /// `ids[i]` has image data in the terminal.
    used: [2]bool = .{ false, false },
    transports: caps.Order,
    /// Index into `transports` of the one in use; earlier ones failed.
    current: u8 = 0,
    tmp_dir: []u8,
    prefix: []u8,
    pid: i32,
    /// Name counter for shm/file objects.
    serial: u64 = 0,
    /// Created shm/file objects, oldest first from `obj_head`.
    objects: std.ArrayList(Object) = .empty,
    obj_head: usize = 0,
    /// RGBA frame for shm/file.
    rgba: []u8 = &.{},
    /// Compressed frame and the compressor's window, for zlib.
    zbuf: []u8 = &.{},
    window: []u8 = &.{},
    /// The rect and fitted box of the previous `present`; null forces a
    /// full redraw (margin clear).
    last: ?struct { rect: Rect, box: Rect } = null,

    /// `transports` must contain `.zlib`; shm and file are dropped off POSIX.
    pub fn init(gpa: std.mem.Allocator, io: Io, cell_px: CellPx, transports: caps.Order, opts: Options) !Kitty {
        var order: caps.Order = .{};
        for (transports.slice()) |t| {
            if (t == .zlib or posix) order.buf[order.len] = t else continue;
            order.len += 1;
        }
        std.debug.assert(std.mem.indexOfScalar(Transport, order.slice(), .zlib) != null);

        const tmp_dir = try gpa.dupe(u8, std.mem.trimEnd(u8, opts.tmp_dir orelse defaultTmpDir(), "/"));
        errdefer gpa.free(tmp_dir);
        const prefix = try gpa.dupe(u8, opts.prefix);
        errdefer gpa.free(prefix);
        const pair = opts.pair orelse next_pair.fetchAdd(1, .monotonic);
        return .{
            .gpa = gpa,
            .io = io,
            .cell_px = cell_px,
            .pair = pair,
            .ids = .{ 2 * pair + 1, 2 * pair + 2 },
            .transports = order,
            .tmp_dir = tmp_dir,
            .prefix = prefix,
            .pid = if (posix) c.getpid() else 0,
        };
    }

    /// Unlinks every shm/file object still outstanding and frees memory.
    /// Call `clear` first to remove the images from the terminal.
    pub fn deinit(k: *Kitty) void {
        k.reap(std.math.maxInt(i96));
        k.objects.deinit(k.gpa);
        k.gpa.free(k.rgba);
        k.gpa.free(k.zbuf);
        k.gpa.free(k.window);
        k.gpa.free(k.tmp_dir);
        k.gpa.free(k.prefix);
        k.* = undefined;
    }

    /// Deletes both images and their data from the terminal (`d=I`) and
    /// erases the last rect. Only this instance's ids are touched.
    pub fn clear(k: *Kitty, w: *Io.Writer) !void {
        for (k.ids, k.used) |id, used| {
            if (used) try w.print("\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{id});
        }
        if (k.last) |l| try sgr.clearRect(w, l.rect);
        k.used = .{ false, false };
        k.placed = .{ false, false };
        k.last = null;
    }

    /// The next `present` clears the margin again.
    pub fn invalidate(k: *Kitty) void {
        k.last = null;
    }

    pub fn setCellPx(k: *Kitty, cell_px: CellPx) void {
        k.cell_px = cell_px;
        k.invalidate();
    }

    /// The transport the next frame will use.
    pub fn transport(k: *const Kitty) Transport {
        return k.transports.slice()[k.current];
    }

    /// Draws `frame` into `rect`, letterboxed to `aspect` (default: the
    /// frame's own width / height). An empty frame or rect draws nothing.
    pub fn present(k: *Kitty, w: *Io.Writer, frame: Frame, rect: Rect, aspect: ?f32) !void {
        if (frame.isEmpty() or rect.isEmpty()) return;
        const box = layout.fit(rect, k.cell_px, aspect orelse frame.aspect());
        if (box.isEmpty()) return;
        if (posix) k.reap(Io.Clock.awake.now(k.io).nanoseconds);

        // Create the shm/file object before writing anything, so a failure
        // can fall back without leaving half a command in `w`.
        var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const payload: Payload = while (true) {
            if (k.prepare(&name_buf, frame)) |p| break p else |err| {
                // zlib is last and fails only for temui-side resource errors.
                if (k.transport() == .zlib) return err;
                const failed = k.transport();
                k.current += 1;
                log.warn("kitty {t} transport failed ({t}); using {t} from now on", .{ failed, err, k.transport() });
            }
        };

        const full = if (k.last) |l| !std.meta.eql(l.rect, rect) or !std.meta.eql(l.box, box) else true;
        if (full) try sgr.clearMargin(w, rect, box);

        const i = k.next;
        try sgr.cup(w, box.row, box.col);
        try w.print("\x1b_Ga=T,i={d},p=1,q=2,C=1,c={d},r={d},f={d},s={d},v={d}", .{
            k.ids[i], box.cols, box.rows, @as(u32, if (payload == .zlib) 24 else 32), frame.width, frame.height,
        });
        switch (payload) {
            .zlib => |z| {
                try w.writeAll(",o=z");
                try writeChunked(w, z);
            },
            .file => |path| {
                try w.writeAll(",t=t");
                try writeChunked(w, path);
            },
            .shm => |name| {
                try w.print(",t=s,S={d}", .{k.rgba.len});
                try writeChunked(w, name);
            },
        }
        // The new frame is up; now drop the other id's placement (D7).
        const o = i +% 1;
        if (k.placed[o]) try w.print("\x1b_Ga=d,d=i,i={d},q=2\x1b\\", .{k.ids[o]});
        k.placed = .{ false, false };
        k.placed[i] = true;
        k.used[i] = true;
        k.next = o;
        k.last = .{ .rect = rect, .box = box };
    }

    const Payload = union(enum) { zlib: []const u8, file: []const u8, shm: []const u8 };

    fn prepare(k: *Kitty, name_buf: []u8, frame: Frame) !Payload {
        const t = k.transport();
        if (t == .zlib) return .{ .zlib = try k.compress(frame.rgb) };
        if (comptime !posix) unreachable;

        const n = frame.width * frame.height * 4;
        if (k.rgba.len != n) {
            k.gpa.free(k.rgba);
            k.rgba = &.{};
            k.rgba = try k.gpa.alloc(u8, n);
        }
        for (0..frame.width * frame.height) |p| {
            k.rgba[p * 4 ..][0..4].* = frame.rgb[p * 3 ..][0..3].* ++ [1]u8{255};
        }
        const obj: Object = .{ .transport = t, .serial = k.serial, .created_ns = Io.Clock.awake.now(k.io).nanoseconds };
        try k.objects.ensureUnusedCapacity(k.gpa, 1);
        const name = try k.objectName(name_buf, obj);
        switch (t) {
            .file => try writeFile(name, k.rgba),
            .shm => try writeShm(name, k.rgba),
            .zlib => unreachable,
        }
        k.serial += 1;
        k.objects.appendAssumeCapacity(obj);
        return switch (t) {
            .file => .{ .file = name },
            .shm => .{ .shm = name },
            .zlib => unreachable,
        };
    }

    /// Unlinks objects created at or before `now_ns - object_ttl_ns`.
    /// ENOENT (the terminal already did) is the normal case.
    pub fn reap(k: *Kitty, now_ns: i96) void {
        if (comptime !posix) return;
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const items = k.objects.items;
        while (k.obj_head < items.len and now_ns -| items[k.obj_head].created_ns >= object_ttl_ns) : (k.obj_head += 1) {
            const obj = items[k.obj_head];
            const name = k.objectName(&buf, obj) catch unreachable; // it was created
            _ = if (obj.transport == .file) c.unlink(name) else c.shm_unlink(name);
        }
        if (k.obj_head == items.len) {
            k.objects.clearRetainingCapacity();
            k.obj_head = 0;
        } else if (k.obj_head > 256 and k.obj_head * 2 > items.len) {
            std.mem.copyForwards(Object, items, items[k.obj_head..]);
            k.objects.shrinkRetainingCapacity(items.len - k.obj_head);
            k.obj_head = 0;
        }
    }

    /// Objects created and not yet unlinked by `reap`.
    pub fn outstanding(k: *const Kitty) usize {
        return k.objects.items.len - k.obj_head;
    }

    fn objectName(k: *const Kitty, buf: []u8, obj: Object) ![:0]const u8 {
        return switch (obj.transport) {
            .file => std.mem.printSentinel(buf, "{s}/tty-graphics-protocol-{s}-{d}-{d}-{d}.rgba", .{ k.tmp_dir, k.prefix, k.pid, k.pair, obj.serial }, 0),
            .shm => std.mem.printSentinel(buf[0..@min(buf.len, 32)], "/{s}-{d}-{d}-{d}", .{ k.prefix, k.pid, k.pair, obj.serial }, 0) catch error.ShmNameTooLong,
            .zlib => unreachable,
        };
    }

    fn compress(k: *Kitty, raw: []const u8) ![]const u8 {
        // Deflate's worst case is stored blocks: 5 bytes per 64 KiB, plus
        // the zlib header and checksum.
        const cap = raw.len + raw.len / 1024 + 64;
        if (k.zbuf.len < cap) {
            k.gpa.free(k.zbuf);
            k.zbuf = &.{};
            k.zbuf = try k.gpa.alloc(u8, cap);
        }
        if (k.window.len == 0) k.window = try k.gpa.alloc(u8, flate.max_window_len);
        var w: Io.Writer = .fixed(k.zbuf);
        var z = try flate.Compress.init(&w, k.window, .zlib, .fastest);
        try z.writer.writeAll(raw);
        try z.finish();
        return w.buffered();
    }
};

fn defaultTmpDir() []const u8 {
    if (posix) if (c.getenv("TMPDIR")) |p| {
        const s = std.mem.span(p);
        if (s.len > 0) return s;
    };
    return "/tmp";
}

/// Writes `,m=1` (if more chunks follow) then `;payload` in base64, split
/// into chunks of at most `chunk_len` bytes; later chunks carry only `m`.
fn writeChunked(w: *Io.Writer, raw: []const u8) !void {
    var rest = raw;
    var first = true;
    while (true) {
        const take = @min(rest.len, raw_chunk_len);
        const last = take == rest.len;
        if (!first) try w.writeAll("\x1b_G");
        try w.writeAll(if (first) (if (last) "" else ",m=1") else (if (last) "m=0" else "m=1"));
        try w.writeByte(';');
        var enc: [chunk_len]u8 = undefined;
        try w.writeAll(b64.encode(&enc, rest[0..take]));
        try w.writeAll("\x1b\\");
        rest = rest[take..];
        first = false;
        if (last) break;
    }
}

fn writeFile(path: [:0]const u8, bytes: []const u8) !void {
    // EXCL: never follow or reuse something already at this name.
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.TempFileOpen;
    defer _ = c.close(fd);
    errdefer _ = c.unlink(path);
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
    errdefer _ = c.shm_unlink(name);
    if (c.ftruncate(fd, @intCast(bytes.len)) != 0) return error.ShmTruncate;
    const p = c.mmap(null, bytes.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (p == c.MAP_FAILED) return error.ShmMap;
    const mem: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(p));
    @memcpy(mem[0..bytes.len], bytes);
    _ = c.munmap(mem, bytes.len);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const golden = @import("golden.zig");

const zlib_only: caps.Order = .init(&.{.zlib});

fn render(k: *Kitty, frame: Frame, rect: Rect) ![]u8 {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try k.present(&aw.writer, frame, rect, null);
    return aw.toOwnedSlice();
}

const Command = struct { keys: []const u8, payload: []const u8 };

/// The APC G commands in `out`, in order.
fn commands(out: []const u8, buf: []Command) ![]Command {
    var n: usize = 0;
    var rest = out;
    while (std.mem.indexOf(u8, rest, "\x1b_G")) |at| {
        rest = rest[at + 3 ..];
        const end = std.mem.indexOf(u8, rest, "\x1b\\") orelse return error.Unterminated;
        const body = rest[0..end];
        const semi = std.mem.indexOfScalar(u8, body, ';');
        buf[n] = .{ .keys = body[0 .. semi orelse body.len], .payload = if (semi) |s| body[s + 1 ..] else "" };
        n += 1;
        rest = rest[end + 2 ..];
    }
    return buf[0..n];
}

/// The decoded payload of the transmission starting at `cs[0]`.
fn payloadOf(gpa: std.mem.Allocator, cs: []const Command) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (cs, 0..) |cmd, i| {
        try testing.expect(cmd.payload.len <= chunk_len);
        try text.appendSlice(gpa, cmd.payload);
        const more = if (i == 0) std.mem.endsWith(u8, cmd.keys, ",m=1") else std.mem.eql(u8, cmd.keys, "m=1");
        if (!more) break;
    }
    const d = std.base64.standard.Decoder;
    const out = try gpa.alloc(u8, try d.calcSizeForSlice(text.items));
    errdefer gpa.free(out);
    try d.decode(out, text.items);
    return out;
}

fn inflate(gpa: std.mem.Allocator, z: []const u8) ![]u8 {
    var r: Io.Reader = .fixed(z);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&r, .zlib, &window);
    return d.reader.allocRemaining(gpa, .unlimited);
}

/// Control bytes, one escape per line, with base64 payloads elided and
/// continuation chunks dropped (their count depends on the compressor).
fn describe(gpa: std.mem.Allocator, out: []const u8) ![]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    var i: usize = 0;
    while (i < out.len) {
        if (std.mem.startsWith(u8, out[i..], "\x1b_G")) {
            const end = i + std.mem.indexOf(u8, out[i..], "\x1b\\").?;
            const body = out[i + 3 .. end];
            const semi = std.mem.indexOfScalar(u8, body, ';');
            const keys = body[0 .. semi orelse body.len];
            if (!std.mem.eql(u8, keys, "m=1")) {
                try w.print("APC G {s}{s}\n", .{ keys, if (semi != null) ";…" else "" });
            }
            i = end + 2;
        } else if (std.mem.startsWith(u8, out[i..], "\x1b[")) {
            var j = i + 2;
            while (out[j] < 0x40 or out[j] > 0x7e) j += 1;
            try w.print("CSI {s}\n", .{out[i + 2 .. j + 1]});
            i = j + 1;
        } else return error.UnexpectedByte;
    }
    return aw.toOwnedSlice();
}

test "golden: zlib, test-core frame 60, 80×24 at 10×20 px cells" {
    const gpa = testing.allocator;
    const frame = try golden.loadFrame60(gpa);
    defer gpa.free(frame.rgb);
    var k: Kitty = try .init(gpa, testing.io, golden.cell_px, zlib_only, .{ .pair = 0 });
    defer k.deinit();
    const out = try render(&k, frame, golden.rect);
    defer gpa.free(out);

    const text = try describe(gpa, out);
    defer gpa.free(text);
    try golden.check("render-kitty-zlib-80x24.txt", text);

    var buf: [256]Command = undefined;
    const cs = try commands(out, &buf);
    try testing.expect(std.mem.startsWith(u8, cs[0].keys, "a=T,i=1,p=1,q=2,C=1,c=55,r=24,f=24,s=256,v=224,o=z,m=1"));
    const z = try payloadOf(gpa, cs);
    defer gpa.free(z);
    try testing.expect(z.len < frame.rgb.len / 4);
    const back = try inflate(gpa, z);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, frame.rgb, back);
}

test "double buffering: ids alternate and the other placement is deleted" {
    const gpa = testing.allocator;
    var k: Kitty = try .init(gpa, testing.io, golden.cell_px, zlib_only, .{ .pair = 7 });
    defer k.deinit();
    const px = [_]u8{ 1, 2, 3 };
    const frame: Frame = .{ .width = 1, .height = 1, .rgb = &px };
    // 3×1 cells of 10×20 px; a square image fits 2×1 at col 4, margin col 6.
    const rect: Rect = .{ .col = 4, .row = 2, .cols = 3, .rows = 1 };
    const want = [_][]const u8{
        // First frame: margin clear, place on id 15, nothing to delete.
        "CSI 0m\nCSI 2;6H\nCSI 1X\nCSI 2;4H\nAPC G a=T,i=15,p=1,q=2,C=1,c=2,r=1,f=24,s=1,v=1,o=z;…\n",
        "CSI 2;4H\nAPC G a=T,i=16,p=1,q=2,C=1,c=2,r=1,f=24,s=1,v=1,o=z;…\nAPC G a=d,d=i,i=15,q=2\n",
        "CSI 2;4H\nAPC G a=T,i=15,p=1,q=2,C=1,c=2,r=1,f=24,s=1,v=1,o=z;…\nAPC G a=d,d=i,i=16,q=2\n",
    };
    for (want) |wnt| {
        const out = try render(&k, frame, rect);
        defer gpa.free(out);
        const text = try describe(gpa, out);
        defer gpa.free(text);
        try testing.expectEqualStrings(wnt, text);
    }

    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try k.clear(&aw.writer);
    const text = try describe(gpa, aw.written());
    defer gpa.free(text);
    try testing.expectEqualStrings("APC G a=d,d=I,i=15,q=2\nAPC G a=d,d=I,i=16,q=2\nCSI 0m\nCSI 2;4H\nCSI 3X\n", text);
}

test "instances get disjoint id pairs" {
    const gpa = testing.allocator;
    var a: Kitty = try .init(gpa, testing.io, golden.cell_px, zlib_only, .{});
    defer a.deinit();
    var b: Kitty = try .init(gpa, testing.io, golden.cell_px, zlib_only, .{});
    defer b.deinit();
    for (a.ids) |x| for (b.ids) |y| try testing.expect(x != y);
    try testing.expect(a.ids[0] != a.ids[1] and b.ids[0] != b.ids[1]);
}

test "empty frame or rect writes nothing" {
    var k: Kitty = try .init(testing.allocator, testing.io, golden.cell_px, zlib_only, .{});
    defer k.deinit();
    const px = [_]u8{ 1, 2, 3 };
    const empty = try render(&k, .{ .width = 0, .height = 0, .rgb = &.{} }, golden.rect);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);
    const no_rect = try render(&k, .{ .width = 1, .height = 1, .rgb = &px }, .{ .cols = 0, .rows = 5 });
    defer testing.allocator.free(no_rect);
    try testing.expectEqualStrings("", no_rect);
}

/// A scratch directory for file-transport tests, as a path libc can open.
const TestDir = struct {
    tmp: testing.TmpDir,
    path: []u8,

    fn init() !TestDir {
        const tmp = testing.tmpDir(.{});
        return .{ .tmp = tmp, .path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path}) };
    }

    fn deinit(d: *TestDir) void {
        testing.allocator.free(d.path);
        d.tmp.cleanup();
    }
};

const two_px = [_]u8{ 9, 8, 7, 1, 2, 3 };
const two_px_rgba = [_]u8{ 9, 8, 7, 255, 1, 2, 3, 255 };

test "file transport: escape, file contents, reap and deinit unlink" {
    if (comptime !posix) return error.SkipZigTest;
    const gpa = testing.allocator;
    var dir: TestDir = try .init();
    defer dir.deinit();
    var k: Kitty = try .init(gpa, testing.io, golden.cell_px, .init(&.{ .file, .zlib }), .{ .tmp_dir = dir.path, .prefix = "t", .pair = 3 });
    defer k.deinit();
    const frame: Frame = .{ .width = 2, .height = 1, .rgb = &two_px };

    const out = try render(&k, frame, .{ .cols = 2, .rows = 1 });
    defer gpa.free(out);
    var buf: [4]Command = undefined;
    const cs = try commands(out, &buf);
    try testing.expectEqual(@as(usize, 1), cs.len);
    try testing.expectEqualStrings("a=T,i=7,p=1,q=2,C=1,c=2,r=1,f=32,s=2,v=1,t=t", cs[0].keys);
    const path = try payloadOf(gpa, cs);
    defer gpa.free(path);
    const want_path = try std.fmt.allocPrint(gpa, "{s}/tty-graphics-protocol-t-{d}-3-0.rgba", .{ dir.path, k.pid });
    defer gpa.free(want_path);
    try testing.expectEqualStrings(want_path, path);
    const got = try Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(64));
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, &two_px_rgba, got);

    // A second frame; reaping at "creation + ttl" removes both, and only
    // objects that old.
    gpa.free(try render(&k, frame, .{ .cols = 2, .rows = 1 }));
    try testing.expectEqual(@as(usize, 2), k.outstanding());
    k.reap(k.objects.items[0].created_ns + object_ttl_ns - 1);
    try testing.expectEqual(@as(usize, 2), k.outstanding());
    k.reap(k.objects.items[0].created_ns + object_ttl_ns);
    try testing.expect(k.outstanding() < 2);
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, path, .{}));

    // deinit unlinks whatever is left.
    gpa.free(try render(&k, frame, .{ .cols = 2, .rows = 1 }));
    const last_path = try std.fmt.allocPrint(gpa, "{s}/tty-graphics-protocol-t-{d}-3-2.rgba", .{ dir.path, k.pid });
    defer gpa.free(last_path);
    try Io.Dir.cwd().access(testing.io, last_path, .{});
    k.deinit();
    k = try .init(gpa, testing.io, golden.cell_px, zlib_only, .{});
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().access(testing.io, last_path, .{}));
}

test "shm transport: escape, object contents, deinit unlinks" {
    if (comptime !posix) return error.SkipZigTest;
    const gpa = testing.allocator;
    var k: Kitty = try .init(gpa, testing.io, golden.cell_px, .init(&.{ .shm, .zlib }), .{ .prefix = "tt", .pair = 5 });
    defer k.deinit();
    const out = try render(&k, .{ .width = 2, .height = 1, .rgb = &two_px }, .{ .cols = 2, .rows = 1 });
    defer gpa.free(out);
    var buf: [4]Command = undefined;
    const cs = try commands(out, &buf);
    try testing.expectEqualStrings("a=T,i=11,p=1,q=2,C=1,c=2,r=1,f=32,s=2,v=1,t=s,S=8", cs[0].keys);
    const name = try payloadOf(gpa, cs);
    defer gpa.free(name);
    const want = try std.fmt.allocPrint(gpa, "/tt-{d}-5-0", .{k.pid});
    defer gpa.free(want);
    try testing.expectEqualStrings(want, name);

    const namez = try gpa.dupeSentinel(u8, name, 0);
    defer gpa.free(namez);
    const fd = c.shm_open(namez, @bitCast(c.O{ .ACCMODE = .RDONLY }), @as(c.mode_t, 0));
    try testing.expect(fd >= 0);
    const p = c.mmap(null, two_px_rgba.len, .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0);
    _ = c.close(fd);
    try testing.expect(p != c.MAP_FAILED);
    const mem: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(p));
    try testing.expectEqualSlices(u8, &two_px_rgba, mem[0..two_px_rgba.len]);
    _ = c.munmap(mem, two_px_rgba.len);

    k.deinit();
    k = try .init(gpa, testing.io, golden.cell_px, zlib_only, .{});
    try testing.expect(c.shm_open(namez, @bitCast(c.O{ .ACCMODE = .RDONLY }), @as(c.mode_t, 0)) < 0);
}

test "runtime fallback: failed shm and file move on to zlib for good" {
    if (comptime !posix) return error.SkipZigTest;
    const gpa = testing.allocator;
    const prev_level = testing.log_level;
    testing.log_level = .err; // the fallback warnings are expected
    defer testing.log_level = prev_level;
    // shm name over 31 bytes, temp dir that doesn't exist.
    var k: Kitty = try .init(gpa, testing.io, golden.cell_px, .init(&.{ .shm, .file, .zlib }), .{
        .tmp_dir = "/nonexistent-temui-test-dir",
        .prefix = "a-prefix-far-too-long-for-shm-names",
    });
    defer k.deinit();
    const frame: Frame = .{ .width = 2, .height = 1, .rgb = &two_px };
    for (0..2) |_| {
        const out = try render(&k, frame, .{ .cols = 2, .rows = 1 });
        defer gpa.free(out);
        var buf: [4]Command = undefined;
        const cs = try commands(out, &buf);
        try testing.expect(std.mem.endsWith(u8, cs[0].keys, ",f=24,s=2,v=1,o=z"));
        const z = try payloadOf(gpa, cs);
        defer gpa.free(z);
        const back = try inflate(gpa, z);
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, &two_px, back);
    }
    try testing.expectEqual(Transport.zlib, k.transport());
    try testing.expectEqual(@as(usize, 0), k.outstanding());
}

test "init drops shm and file off POSIX and keeps the order" {
    var k: Kitty = try .init(testing.allocator, testing.io, golden.cell_px, .init(&.{ .zlib, .shm, .file }), .{});
    defer k.deinit();
    const want: []const Transport = if (posix) &.{ .zlib, .shm, .file } else &.{.zlib};
    try testing.expectEqualSlices(Transport, want, k.transports.slice());
}
