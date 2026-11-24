//! Live terminal capability detection (D7). Runs once at startup.
//!
//! Round 1 sends every spike 02 query (kitty graphics `a=q`, kitty keyboard
//! `CSI ? u`, DECRQSS truecolor, `CSI 14 t`, `CSI 16 t`, XTVERSION) followed
//! by one DA1 (`CSI c`). Every terminal answers DA1, and answers in order,
//! so the DA1 reply ends the round; a 500 ms hard timeout covers terminals
//! that don't. If the kitty query answered OK, round 2 sends one 1×1 `a=q`
//! test transmission per transport (shm, temp file, inline zlib; distinct
//! ids) then DA1, and records which answered OK. Probe objects the terminal
//! didn't consume are unlinked afterwards, also on timeout. Replies are
//! recorded in whichever round they arrive. If a round timed out and the
//! terminal has answered anything, detection then waits up to one more
//! timeout for the outstanding DA1, so late replies don't reach the shell
//! once raw mode ends.
//!
//! The read loop works on plain fds and doesn't touch terminal modes, so
//! tests drive it over pipes; `run` adds the tty check, raw mode and restore.
//! Bytes that aren't replies (typed keys) are logged and dropped: input
//! handling is item 06. Ctrl-C aborts detection with `error.Interrupted`.
//!
//! Windows: no queries; capabilities come from the environment only.

const std = @import("std");
const builtin = @import("builtin");
const caps = @import("caps.zig");
const replies = @import("replies.zig");
const session = @import("session.zig");
const kitty = @import("../render/kitty.zig");

const Io = std.Io;
const c = std.c;
const Capabilities = caps.Capabilities;
const Transport = caps.Transport;
const log = std.log.scoped(.term);

const is_windows = builtin.os.tag == .windows;
const b64 = std.base64.standard.Encoder;

pub const default_timeout_ms = 500;

/// Image id of the round-1 kitty query; probes use the next ids, one per
/// transport. `a=q` never stores an image, so these can't collide with a
/// renderer's ids.
pub const query_id = 31;
pub const probe_ids = [_]u32{ 32, 33, 34 };
const probe_order = [_]Transport{ .shm, .file, .zlib };

const da1 = "\x1b[c";

/// Round 1: the spike 02 queries. DECRQSS sets a truecolor background, asks
/// for the current SGR, then resets.
pub const round1_queries = std.fmt.comptimePrint("\x1b_Gi={d},s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\", .{query_id}) ++
    "\x1b[?u" ++
    "\x1b[48:2::1:2:3m\x1bP$qm\x1b\\\x1b[0m" ++
    "\x1b[14t" ++
    "\x1b[16t" ++
    "\x1b[>0q";

pub const Options = struct {
    /// Per round.
    timeout_ms: u32 = default_timeout_ms,
    /// Directory for the temp-file probe; default as for the kitty backend.
    tmp_dir: ?[]const u8 = null,
    /// Probe object names: `<tmp_dir>/tty-graphics-protocol-<prefix>-<pid>.rgba`
    /// and shm `/<prefix>-<pid>`.
    prefix: []const u8 = "temui-probe",
};

/// The environment part of the capabilities (`TERM`, `TERM_PROGRAM`,
/// `COLORTERM`). Strings point into `env`.
pub fn fromEnv(env: *const std.process.Environ.Map) Capabilities {
    return .{
        .term = env.get("TERM"),
        .term_program = env.get("TERM_PROGRAM"),
        .colorterm = env.get("COLORTERM"),
    };
}

/// Full detection: environment, then, if stdin and stdout are both
/// terminals, window size and the query rounds in raw mode (entered and
/// restored here unless a session is already active). Not a terminal:
/// `is_tty` is false and nothing is sent. Strings live in `arena` or `env`.
pub fn run(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, opts: Options) !Capabilities {
    var cs = fromEnv(env);
    cs.is_tty = try Io.File.stdin().isTty(io) and try Io.File.stdout().isTty(io);
    if (!cs.is_tty) {
        log.info("detect: not a terminal; skipping queries", .{});
        return cs;
    }
    if (is_windows) {
        log.info("detect: Windows console; environment only", .{});
    } else {
        cs.winsize = winSize(1);
        const entered = !session.isActive();
        if (entered) try session.enter(.{ .alt_screen = false });
        defer if (entered) session.restore();
        try query(arena, io, &cs, 0, 1, opts);
    }
    logCaps(cs);
    return cs;
}

/// `TIOCGWINSZ` on `fd`, or null if it isn't a terminal.
pub fn winSize(fd: c.fd_t) ?caps.WinSize {
    if (is_windows) {
        return null;
    } else {
        var ws: c.winsize = undefined;
        if (c.ioctl(fd, c.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) return null;
        return .{ .cols = ws.col, .rows = ws.row, .px_w = ws.xpixel, .px_h = ws.ypixel };
    }
}

/// Runs both rounds: writes queries to `out_fd`, reads replies from
/// `in_fd`, and folds them into `cs`. The terminal must already be in raw
/// mode (or the fds are pipes, in tests).
pub fn query(arena: std.mem.Allocator, io: Io, cs: *Capabilities, in_fd: c.fd_t, out_fd: c.fd_t, opts: Options) !void {
    if (comptime is_windows) @compileError("detection queries are POSIX-only");
    var r: Reader = .{ .io = io, .fd = in_fd };
    r.drain();
    const h: Handler = .{ .arena = arena, .cs = cs };

    const t0 = now(io);
    try writeAll(out_fd, round1_queries);
    const done1 = try r.round(out_fd, opts.timeout_ms, h);
    log.debug("detect: round 1 {s} after {d} ms", .{ if (done1) "answered" else "timed out", msSince(io, t0) });
    if (cs.kitty_graphics) try probeTransports(arena, io, &r, out_fd, opts, h);
    try r.settle(opts.timeout_ms, h);
}

/// Round 2: one test transmission per transport.
fn probeTransports(arena: std.mem.Allocator, io: Io, r: *Reader, out_fd: c.fd_t, opts: Options, h: Handler) !void {
    var probes: Probes = try .init(arena, opts);
    defer probes.unlink();
    var cmds: Io.Writer.Allocating = .init(arena);
    for (probe_order, probe_ids) |t, id| probes.write(&cmds.writer, t, id) catch |err| {
        log.warn("detect: kitty {t} probe not sent: {t}", .{ t, err });
    };
    const t1 = now(io);
    try writeAll(out_fd, cmds.written());
    const done2 = try r.round(out_fd, opts.timeout_ms, h);
    log.debug("detect: round 2 {s} after {d} ms", .{ if (done2) "answered" else "timed out", msSince(io, t1) });
}

/// Folds replies into the capabilities in every round, so a round-1 reply
/// that arrives late (during round 2 or the settle) still counts. Probe
/// replies mark their transport.
const Handler = struct {
    arena: std.mem.Allocator,
    cs: *Capabilities,

    fn event(h: Handler, e: replies.Event) !void {
        if (e.kind == .kitty_graphics) if (kittyId(e.body)) |id| {
            for (probe_order, probe_ids) |t, pid| {
                if (id != pid) continue;
                if (e.kittyOk()) h.cs.transports_ok.insert(t) else log.info("detect: kitty {t} probe failed: {s}", .{ t, e.body });
                return;
            }
        };
        try h.cs.record(h.arena, e);
    }
};

/// `i=<id>` from a kitty graphics reply body (`i=32;OK`).
fn kittyId(body: []const u8) ?u32 {
    var it = std.mem.tokenizeAny(u8, body, ",;");
    while (it.next()) |kv| {
        if (std.mem.startsWith(u8, kv, "i=")) return std.fmt.parseInt(u32, kv[2..], 10) catch null;
    }
    return null;
}

/// Reads and parses replies, keeping unread bytes between rounds.
const Reader = struct {
    io: Io,
    fd: c.fd_t,
    parser: replies.Parser = .{},
    buf: [1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    /// DA1s sent and not yet answered. After a round times out its DA1 may
    /// still arrive; it belongs to that round, not the next.
    pending_da1: u32 = 0,
    /// The terminal has answered something (any reply, not typed keys).
    heard: bool = false,

    /// Discards input that arrived before detection (typed-ahead keys).
    fn drain(r: *Reader) void {
        var tmp: [256]u8 = undefined;
        while (true) {
            var fds = [_]c.pollfd{.{ .fd = r.fd, .events = c.POLL.IN, .revents = 0 }};
            if (c.poll(&fds, 1, 0) <= 0) return;
            const n = c.read(r.fd, &tmp, tmp.len);
            if (n <= 0) return;
            log.debug("detect: dropped {d} bytes of earlier input", .{n});
        }
    }

    /// Sends DA1 and handles events until its reply (true) or the timeout
    /// or end of input (false).
    fn round(r: *Reader, out_fd: c.fd_t, timeout_ms: u32, handler: Handler) !bool {
        try writeAll(out_fd, da1);
        r.pending_da1 += 1;
        return r.awaitDa1(timeout_ms, handler);
    }

    /// After a timed-out round, the replies still on their way would arrive
    /// once raw mode is off and land in the shell. If the terminal has
    /// answered anything at all, wait up to `timeout_ms` more for every
    /// outstanding DA1, recording what comes before it. A terminal that
    /// never answered costs nothing extra.
    fn settle(r: *Reader, timeout_ms: u32, handler: Handler) !void {
        if (r.pending_da1 == 0 or !r.heard) return;
        if (!try r.awaitDa1(timeout_ms, handler)) log.info("detect: {d} DA1 replies still outstanding", .{r.pending_da1});
    }

    /// Handles events until every DA1 sent is answered (true) or the
    /// timeout or end of input (false).
    fn awaitDa1(r: *Reader, timeout_ms: u32, handler: Handler) !bool {
        const deadline = now(r.io) + @as(i96, timeout_ms) * std.time.ns_per_ms;
        while (try r.next(deadline)) |e| switch (e.kind) {
            .da1 => {
                r.heard = true;
                try handler.event(e);
                r.pending_da1 -= 1;
                if (r.pending_da1 == 0) return true;
            },
            .ctrl_c => return error.Interrupted,
            .byte, .other => log.debug("detect: dropped input {any}", .{e.raw}),
            else => {
                r.heard = true;
                try handler.event(e);
            },
        };
        return false;
    }

    /// The next complete sequence, or null at `deadline` or end of input.
    fn next(r: *Reader, deadline: i96) !?replies.Event {
        while (true) {
            while (r.start < r.end) {
                const b = r.buf[r.start];
                r.start += 1;
                if (r.parser.feed(b)) |e| return e;
            }
            const left = deadline - now(r.io);
            if (left <= 0) return null;
            var fds = [_]c.pollfd{.{ .fd = r.fd, .events = c.POLL.IN, .revents = 0 }};
            const wait: c_int = @intCast(@divFloor(left + std.time.ns_per_ms - 1, std.time.ns_per_ms));
            const ready = c.poll(&fds, 1, wait);
            if (ready < 0) {
                if (c._errno().* == @backingInt(c.E.INTR)) continue;
                return error.PollFailed;
            }
            if (ready == 0) continue;
            const n = c.read(r.fd, &r.buf, r.buf.len);
            if (n < 0) {
                if (c._errno().* == @backingInt(c.E.INTR)) continue;
                return error.ReadFailed;
            }
            if (n == 0) return null;
            r.start = 0;
            r.end = @intCast(n);
        }
    }
};

/// The shm object and temp file the round-2 probes point at.
const Probes = struct {
    file: [:0]const u8,
    shm: [:0]const u8,
    made: std.EnumSet(Transport) = .empty,

    fn init(arena: std.mem.Allocator, opts: Options) !Probes {
        const pid = c.getpid();
        const dir = std.mem.trimEnd(u8, opts.tmp_dir orelse kitty.defaultTmpDir(), "/");
        return .{
            .file = try std.fmt.allocPrintSentinel(arena, "{s}/tty-graphics-protocol-{s}-{d}.rgba", .{ dir, opts.prefix, pid }, 0),
            .shm = try std.fmt.allocPrintSentinel(arena, "/{s}-{d}", .{ opts.prefix, pid }, 0),
        };
    }

    /// Creates the object for `t` (shm, file) and writes its `a=q` command.
    fn write(p: *Probes, w: *Io.Writer, t: Transport, id: u32) !void {
        const pixel = [4]u8{ 0, 0, 0, 255 };
        var enc: [Io.Dir.max_path_bytes * 4 / 3 + 4]u8 = undefined;
        switch (t) {
            .shm => {
                if (p.shm.len > 31) return error.ShmNameTooLong; // macOS limit
                try kitty.writeShm(p.shm, &pixel);
                p.made.insert(.shm);
                try w.print("\x1b_Gi={d},s=1,v=1,a=q,f=32,t=s,S=4;{s}\x1b\\", .{ id, b64.encode(&enc, p.shm) });
            },
            .file => {
                try kitty.writeFile(p.file, &pixel);
                p.made.insert(.file);
                try w.print("\x1b_Gi={d},s=1,v=1,a=q,f=32,t=t;{s}\x1b\\", .{ id, b64.encode(&enc, p.file) });
            },
            .zlib => try w.print("\x1b_Gi={d},s=1,v=1,a=q,f=24,o=z;{s}\x1b\\", .{ id, b64.encode(&enc, &zlib_black_pixel) }),
        }
    }

    /// Removes the objects the terminal didn't consume (ENOENT: it did).
    fn unlink(p: *Probes) void {
        if (p.made.contains(.shm)) _ = c.shm_unlink(p.shm);
        if (p.made.contains(.file)) _ = c.unlink(p.file);
        p.made = .empty;
    }
};

/// zlib stream of one black RGB pixel (`00 00 00`), stored block.
const zlib_black_pixel = [_]u8{ 0x78, 0x01, 0x01, 0x03, 0x00, 0xfc, 0xff, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01 };

fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n < 0) {
            if (c._errno().* == @backingInt(c.E.INTR)) continue;
            return error.WriteFailed;
        }
        rest = rest[@intCast(n)..];
    }
}

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn msSince(io: Io, t0: i96) i96 {
    return @divTrunc(now(io) - t0, std.time.ns_per_ms);
}

/// One info line with everything detection found.
pub fn logCaps(cs: Capabilities) void {
    const px = cs.cellPx();
    log.info("detect: terminal={s} TERM={s} TERM_PROGRAM={s} COLORTERM={s} da1={} kitty_graphics={} transports_ok={{shm={},file={},zlib={}}} kitty_keyboard={?d} truecolor={} cell_px={d}x{d} ({t}) winsize={?any}", .{
        cs.xtversion orelse "?",
        cs.term orelse "-",
        cs.term_program orelse "-",
        cs.colorterm orelse "-",
        cs.da1,
        cs.kitty_graphics,
        cs.transports_ok.contains(.shm),
        cs.transports_ok.contains(.file),
        cs.transports_ok.contains(.zlib),
        cs.kitty_keyboard_flags,
        cs.truecolor(),
        px.px.w,
        px.px.h,
        px.source,
        cs.winsize,
    });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "zlib probe payload inflates to one black pixel" {
    var r: Io.Reader = .fixed(&zlib_black_pixel);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d: std.compress.flate.Decompress = .init(&r, .zlib, &window);
    const out = try d.reader.allocRemaining(testing.allocator, .unlimited);
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0 }, out);
}

test "kittyId" {
    try testing.expectEqual(@as(?u32, 32), kittyId("i=32;OK"));
    try testing.expectEqual(@as(?u32, 34), kittyId("i=34,p=1;EBADF:bad"));
    try testing.expectEqual(@as(?u32, null), kittyId(";OK"));
}

test {
    // Pipes, poll and shm: POSIX only.
    if (!is_windows) _ = posix_tests;
}

const posix_tests = struct {
    const Pipes = struct {
        /// Replies flow test → `in[0]`; queries flow `out[1]` → test.
        in: [2]c.fd_t,
        out: [2]c.fd_t,

        fn init() !Pipes {
            var p: Pipes = undefined;
            if (c.pipe(&p.in) != 0) return error.PipeFailed;
            if (c.pipe(&p.out) != 0) return error.PipeFailed;
            return p;
        }

        fn deinit(p: Pipes) void {
            for (p.in ++ p.out) |fd| _ = c.close(fd);
        }

        fn reply(p: Pipes, bytes: []const u8) !void {
            try writeAll(p.in[1], bytes);
        }

        /// Everything written to the "terminal" so far.
        fn sent(p: Pipes, buf: []u8) ![]u8 {
            var n: usize = 0;
            while (n < buf.len) {
                var fds = [_]c.pollfd{.{ .fd = p.out[0], .events = c.POLL.IN, .revents = 0 }};
                if (c.poll(&fds, 1, 0) <= 0) break;
                const k = c.read(p.out[0], buf[n..].ptr, buf.len - n);
                if (k <= 0) break;
                n += @intCast(k);
            }
            return buf[0..n];
        }
    };

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

        fn exists(d: *TestDir, name: []const u8) bool {
            d.tmp.dir.access(testing.io, name, .{}) catch return false;
            return true;
        }
    };

    fn testOpts(dir: []const u8, timeout_ms: u32) Options {
        return .{ .timeout_ms = timeout_ms, .tmp_dir = dir, .prefix = "temui-dt" };
    }

    test "both rounds: replies, stray bytes, a failed probe, objects unlinked" {
        var a = std.heap.ArenaAllocator.init(testing.allocator);
        defer a.deinit();
        var dir: TestDir = try .init();
        defer dir.deinit();
        const p: Pipes = try .init();
        defer p.deinit();

        // Typed-ahead input before detection is drained.
        try p.reply("zz");
        var cs: Capabilities = .{ .is_tty = true };
        // Replies for both rounds arrive up front: leftovers after round 1's DA1
        // must carry over to round 2. A stray key in the middle is dropped.
        const r1 = "\x1b_Gi=31;OK\x1b\\\x1b[?0u\x1bP1$r0;48:2::1:2:3m\x1b\\x\x1b[4;1972;3375t\x1b[6;29;15t\x1bP>|rex 0.1.0\x1b\\\x1b[?62;22c";
        const r2 = "\x1b_Gi=32;OK\x1b\\\x1b_Gi=33;EBADF:bad file\x1b\\\x1b_Gi=34;OK\x1b\\\x1b[?62;22c";
        // `drain` runs first and would eat the replies, so feed them from a
        // thread once the queries have gone out.
        const Feeder = struct {
            fn run(pp: Pipes) void {
                var fds = [_]c.pollfd{.{ .fd = pp.out[0], .events = c.POLL.IN, .revents = 0 }};
                _ = c.poll(&fds, 1, 2000);
                writeAll(pp.in[1], r1 ++ r2) catch {};
            }
        };
        const t = try std.Thread.spawn(.{}, Feeder.run, .{p});
        try query(a.allocator(), testing.io, &cs, p.in[0], p.out[1], testOpts(dir.path, 2000));
        t.join();

        try testing.expect(cs.da1 and cs.kitty_graphics and cs.truecolor_decrqss);
        try testing.expectEqualStrings("rex 0.1.0", cs.xtversion.?);
        try testing.expectEqual(caps.CellPx{ .w = 15, .h = 29 }, cs.cell_px_reply.?);
        try testing.expect(cs.transports_ok.contains(.shm));
        try testing.expect(!cs.transports_ok.contains(.file));
        try testing.expect(cs.transports_ok.contains(.zlib));

        var buf: [4096]u8 = undefined;
        const sent = try p.sent(&buf);
        try testing.expect(std.mem.startsWith(u8, sent, round1_queries ++ da1));
        try testing.expect(std.mem.indexOf(u8, sent, "a=q,f=32,t=s,S=4;") != null);
        try testing.expect(std.mem.indexOf(u8, sent, "a=q,f=32,t=t;") != null);
        try testing.expect(std.mem.endsWith(u8, sent, "a=q,f=24,o=z;eAEBAwD8/wAAAAADAAE=\x1b\\" ++ da1));

        // The terminal (a pipe) consumed nothing; detection unlinked both.
        var name: [64]u8 = undefined;
        try testing.expect(!dir.exists(try std.fmt.bufPrint(&name, "tty-graphics-protocol-temui-dt-{d}.rgba", .{c.getpid()})));
        const shm_name = try std.fmt.bufPrintSentinel(&name, "/temui-dt-{d}", .{c.getpid()}, 0);
        const fd = c.shm_open(shm_name, @bitCast(c.O{ .ACCMODE = .RDONLY }), @as(c.mode_t, 0));
        if (fd >= 0) _ = c.close(fd);
        try testing.expect(fd < 0);
    }

    test "DA1 ends round 1 early; no kitty reply, no round 2" {
        var a = std.heap.ArenaAllocator.init(testing.allocator);
        defer a.deinit();
        var dir: TestDir = try .init();
        defer dir.deinit();
        const p: Pipes = try .init();
        defer p.deinit();
        var cs: Capabilities = .{ .is_tty = true };

        const Feeder = struct {
            fn run(pp: Pipes) void {
                var fds = [_]c.pollfd{.{ .fd = pp.out[0], .events = c.POLL.IN, .revents = 0 }};
                _ = c.poll(&fds, 1, 2000);
                writeAll(pp.in[1], "\x1bP>|tmux 3.5a\x1b\\\x1b[?1;2;4c") catch {};
            }
        };
        const t = try std.Thread.spawn(.{}, Feeder.run, .{p});
        const t0 = now(testing.io);
        try query(a.allocator(), testing.io, &cs, p.in[0], p.out[1], testOpts(dir.path, 5000));
        t.join();
        try testing.expect(msSince(testing.io, t0) < 2500);
        try testing.expect(cs.da1 and !cs.kitty_graphics);
        try testing.expectEqualStrings("tmux 3.5a", cs.xtversion.?);

        var buf: [1024]u8 = undefined;
        try testing.expectEqualStrings(round1_queries ++ da1, try p.sent(&buf));
    }

    test "silent terminal: round 1 times out, nothing recorded" {
        var a = std.heap.ArenaAllocator.init(testing.allocator);
        defer a.deinit();
        var dir: TestDir = try .init();
        defer dir.deinit();
        const p: Pipes = try .init();
        defer p.deinit();
        var cs: Capabilities = .{ .is_tty = true };
        const t0 = now(testing.io);
        try query(a.allocator(), testing.io, &cs, p.in[0], p.out[1], testOpts(dir.path, 50));
        try testing.expect(msSince(testing.io, t0) >= 50);
        try testing.expect(!cs.da1 and !cs.kitty_graphics and cs.xtversion == null);
    }

    test "round 2 timeout: probes unanswered, objects still unlinked" {
        var a = std.heap.ArenaAllocator.init(testing.allocator);
        defer a.deinit();
        var dir: TestDir = try .init();
        defer dir.deinit();
        const p: Pipes = try .init();
        defer p.deinit();
        var cs: Capabilities = .{ .is_tty = true };
        const Feeder = struct {
            fn run(pp: Pipes) void {
                var fds = [_]c.pollfd{.{ .fd = pp.out[0], .events = c.POLL.IN, .revents = 0 }};
                _ = c.poll(&fds, 1, 2000);
                writeAll(pp.in[1], "\x1b_Gi=31;OK\x1b\\\x1b[?62c") catch {};
            }
        };
        const t = try std.Thread.spawn(.{}, Feeder.run, .{p});
        try query(a.allocator(), testing.io, &cs, p.in[0], p.out[1], testOpts(dir.path, 100));
        t.join();
        try testing.expect(cs.kitty_graphics);
        try testing.expectEqual(@as(usize, 0), cs.transports_ok.count());
        var name: [64]u8 = undefined;
        try testing.expect(!dir.exists(try std.fmt.bufPrint(&name, "tty-graphics-protocol-temui-dt-{d}.rgba", .{c.getpid()})));
    }

    test "slow terminal: late round-1 replies are recorded and its last DA1 drained" {
        var a = std.heap.ArenaAllocator.init(testing.allocator);
        defer a.deinit();
        var dir: TestDir = try .init();
        defer dir.deinit();
        const p: Pipes = try .init();
        defer p.deinit();
        var cs: Capabilities = .{ .is_tty = true };
        // Timeout 300 ms. Kitty OK at once; round 1 times out at 300, round 2
        // runs to 600. XTVERSION and round 1's DA1 come at 450 (in round 2),
        // round 2's DA1 at 650 (in the settle, which runs to 900).
        const Feeder = struct {
            fn run(pp: Pipes) void {
                var fds = [_]c.pollfd{.{ .fd = pp.out[0], .events = c.POLL.IN, .revents = 0 }};
                _ = c.poll(&fds, 1, 2000);
                writeAll(pp.in[1], "\x1b_Gi=31;OK\x1b\\") catch {};
                var none: [0]c.pollfd = .{};
                _ = c.poll(&none, 0, 450);
                writeAll(pp.in[1], "\x1bP>|slow 1\x1b\\\x1b[?62c") catch {};
                _ = c.poll(&none, 0, 200);
                writeAll(pp.in[1], "\x1b[?62c") catch {};
            }
        };
        const t = try std.Thread.spawn(.{}, Feeder.run, .{p});
        try query(a.allocator(), testing.io, &cs, p.in[0], p.out[1], testOpts(dir.path, 300));
        t.join();
        try testing.expect(cs.kitty_graphics and cs.da1);
        try testing.expectEqualStrings("slow 1", cs.xtversion.?);
        // Nothing left over for the shell.
        var fds = [_]c.pollfd{.{ .fd = p.in[0], .events = c.POLL.IN, .revents = 0 }};
        try testing.expectEqual(@as(c_int, 0), c.poll(&fds, 1, 0));
    }

    test "Ctrl-C aborts detection" {
        var a = std.heap.ArenaAllocator.init(testing.allocator);
        defer a.deinit();
        var dir: TestDir = try .init();
        defer dir.deinit();
        const p: Pipes = try .init();
        defer p.deinit();
        var cs: Capabilities = .{ .is_tty = true };
        const Feeder = struct {
            fn run(pp: Pipes) void {
                var fds = [_]c.pollfd{.{ .fd = pp.out[0], .events = c.POLL.IN, .revents = 0 }};
                _ = c.poll(&fds, 1, 2000);
                writeAll(pp.in[1], "\x03") catch {};
            }
        };
        const t = try std.Thread.spawn(.{}, Feeder.run, .{p});
        try testing.expectError(error.Interrupted, query(a.allocator(), testing.io, &cs, p.in[0], p.out[1], testOpts(dir.path, 2000)));
        t.join();
    }
};
