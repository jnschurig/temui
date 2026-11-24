//! Capability-detection prototype (D7, D9). Sends one query at a time, each
//! followed by Primary Device Attributes (`CSI c`) as a sentinel: every
//! terminal answers DA1, so an unanswered query is detected without waiting
//! for the hard timeout.

const std = @import("std");
const c = std.c;
const term = @import("term.zig");
const replies = @import("replies.zig");

pub const hard_timeout_ms = 500;

pub const QueryResult = struct {
    name: []const u8,
    sent: []const u8,
    answered: bool,
    /// Escaped reply bytes (excluding the DA1 sentinel).
    reply: []const u8,
    latency_ms: ?f64,
    /// Whether the DA1 sentinel arrived (false = hard timeout hit).
    sentinel: bool,
    sentinel_ms: ?f64,
};

pub const Result = struct {
    env: struct {
        TERM: ?[]const u8,
        TERM_PROGRAM: ?[]const u8,
        TERM_PROGRAM_VERSION: ?[]const u8,
        COLORTERM: ?[]const u8,
    },
    winsize: term.Size,
    xtversion: ?[]const u8 = null,
    kitty_graphics: bool = false,
    kitty_keyboard_flags: ?u32 = null,
    truecolor_decrqss: bool = false,
    truecolor_env: bool = false,
    cell_px: ?[2]u32 = null,
    text_area_px: ?[2]u32 = null,
    /// Worst sentinel latency across all queries.
    max_latency_ms: f64 = 0,
    queries: []QueryResult,

    /// Short lowercase name for file names: XTVERSION's first word, else
    /// TERM_PROGRAM, else "unknown".
    pub fn terminalName(r: Result, buf: []u8) []const u8 {
        const src = if (r.xtversion) |v| blk: {
            var it = std.mem.tokenizeAny(u8, v, " ()");
            break :blk it.next() orelse v;
        } else r.env.TERM_PROGRAM orelse "unknown";
        var n: usize = 0;
        for (src) |ch| {
            if (n == buf.len) break;
            const l = std.ascii.toLower(ch);
            buf[n] = if (std.ascii.isAlphanumeric(l) or l == '.' or l == '-') l else '_';
            n += 1;
        }
        return buf[0..n];
    }
};

const Query = struct { name: []const u8, bytes: []const u8 };

const queries = [_]Query{
    .{ .name = "da1 (baseline)", .bytes = "" },
    .{ .name = "kitty graphics a=q", .bytes = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\" },
    .{ .name = "kitty keyboard CSI ? u", .bytes = "\x1b[?u" },
    // Set a truecolor background, ask for the current SGR, then reset.
    .{ .name = "DECRQSS SGR truecolor", .bytes = "\x1b[48:2::1:2:3m\x1bP$qm\x1b\\\x1b[0m" },
    .{ .name = "text area px CSI 14 t", .bytes = "\x1b[14t" },
    .{ .name = "cell px CSI 16 t", .bytes = "\x1b[16t" },
    .{ .name = "XTVERSION CSI > q", .bytes = "\x1b[>0q" },
};

/// Terminal must already be in raw mode (`term.enter`), and no reader
/// thread may be running.
pub fn probe(arena: std.mem.Allocator, env: *const std.process.Environ.Map) !Result {
    var r: Result = .{
        .env = .{
            .TERM = env.get("TERM"),
            .TERM_PROGRAM = env.get("TERM_PROGRAM"),
            .TERM_PROGRAM_VERSION = env.get("TERM_PROGRAM_VERSION"),
            .COLORTERM = env.get("COLORTERM"),
        },
        .winsize = try term.size(),
        .queries = try arena.alloc(QueryResult, queries.len),
    };
    if (r.env.COLORTERM) |ct| r.truecolor_env = std.mem.eql(u8, ct, "truecolor") or std.mem.eql(u8, ct, "24bit");

    drain();
    var parser: replies.Parser = .{};
    // DA1 sentinels sent but not yet answered. After a query times out its
    // DA1 may still arrive; it belongs to that query, not the next one.
    var pending_da1: u32 = 0;
    for (queries, r.queries) |q, *out| {
        out.* = .{ .name = q.name, .sent = try escape(arena, q.bytes), .answered = false, .reply = "", .latency_ms = null, .sentinel = false, .sentinel_ms = null };
        const t0 = term.nowNs();
        term.writeAll(q.bytes);
        term.writeAll("\x1b[c");
        pending_da1 += 1;
        var reply: std.ArrayList(u8) = .empty;
        const deadline = t0 + hard_timeout_ms * std.time.ns_per_ms;
        outer: while (true) {
            const now = term.nowNs();
            if (now >= deadline) break;
            var fds = [_]c.pollfd{.{ .fd = term.stdin_fd, .events = c.POLL.IN, .revents = 0 }};
            const wait_ms: c_int = @intCast(@max(1, (deadline - now) / std.time.ns_per_ms));
            if (c.poll(&fds, 1, wait_ms) <= 0) continue;
            var buf: [1024]u8 = undefined;
            const n = c.read(term.stdin_fd, &buf, buf.len);
            if (n <= 0) break;
            const at = msSince(t0);
            for (buf[0..@intCast(n)]) |b| {
                const e = parser.feed(b) orelse continue;
                if (e.kind == .da1) {
                    pending_da1 -|= 1;
                    if (pending_da1 > 0) continue; // a timed-out query's sentinel
                    out.sentinel = true;
                    out.sentinel_ms = at;
                    r.max_latency_ms = @max(r.max_latency_ms, at);
                    if (q.bytes.len == 0) { // the baseline query is DA1 itself
                        out.answered = true;
                        out.latency_ms = at;
                        try reply.appendSlice(arena, e.raw);
                    }
                    break :outer;
                }
                if (e.kind == .ctrl_c) {
                    term.interrupted.store(true, .release);
                    continue;
                }
                if (!out.answered) out.latency_ms = at;
                out.answered = true;
                try reply.appendSlice(arena, e.raw);
                try record(arena, &r, e);
            }
        }
        out.reply = try escape(arena, reply.items);
        if (!out.sentinel) r.max_latency_ms = @max(r.max_latency_ms, @as(f64, hard_timeout_ms));
        if (term.interrupted.load(.acquire)) return error.Interrupted;
    }
    return r;
}

fn record(arena: std.mem.Allocator, r: *Result, e: replies.Event) !void {
    switch (e.kind) {
        .kitty_graphics => r.kitty_graphics = r.kitty_graphics or e.kittyOk(),
        .kitty_keyboard => r.kitty_keyboard_flags = e.keyboardFlags(),
        .decrqss => r.truecolor_decrqss = e.decrqssValid() and
            (std.mem.indexOf(u8, e.body, "1:2:3") != null or std.mem.indexOf(u8, e.body, "1;2;3") != null),
        .text_area_px => r.text_area_px = e.dims(),
        .cell_px => r.cell_px = e.dims(),
        .xtversion => r.xtversion = try arena.dupe(u8, e.body),
        else => {},
    }
}

/// Discards any pending input.
pub fn drain() void {
    var fds = [_]c.pollfd{.{ .fd = term.stdin_fd, .events = c.POLL.IN, .revents = 0 }};
    var buf: [1024]u8 = undefined;
    while (c.poll(&fds, 1, 0) > 0) {
        if (c.read(term.stdin_fd, &buf, buf.len) <= 0) return;
    }
}

fn msSince(t0: u64) f64 {
    return @as(f64, @floatFromInt(term.nowNs() - t0)) / std.time.ns_per_ms;
}

/// Printable form: ESC → `\e`, other control bytes → `\xNN`.
pub fn escape(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (bytes) |b| {
        if (b == 0x1b) {
            try out.appendSlice(arena, "\\e");
        } else if (b < 0x20 or b == 0x7f) {
            try out.print(arena, "\\x{x:0>2}", .{b});
        } else try out.append(arena, b);
    }
    return out.items;
}

pub fn printSummary(w: *std.Io.Writer, r: Result) !void {
    try w.print("terminal: {s}  (TERM_PROGRAM={s} {s}, TERM={s}, COLORTERM={s})\n", .{
        r.xtversion orelse "?",
        r.env.TERM_PROGRAM orelse "-",
        r.env.TERM_PROGRAM_VERSION orelse "",
        r.env.TERM orelse "-",
        r.env.COLORTERM orelse "-",
    });
    try w.print("window: {d}x{d} cells, {d}x{d} px (TIOCGWINSZ)\n\n", .{ r.winsize.cols, r.winsize.rows, r.winsize.px_w, r.winsize.px_h });
    try w.print("{s:<24} {s:<8} {s:>10} {s:>10}  reply\n", .{ "query", "answered", "reply ms", "DA1 ms" });
    for (r.queries) |q| {
        var lb: [16]u8 = undefined;
        var sb: [16]u8 = undefined;
        try w.print("{s:<24} {s:<8} {s:>10} {s:>10}  {s}\n", .{
            q.name,
            if (q.answered) "yes" else "no",
            fmtMs(&lb, q.latency_ms),
            if (q.sentinel) fmtMs(&sb, q.sentinel_ms) else "TIMEOUT",
            q.reply,
        });
    }
    try w.print("\nkitty graphics: {}   kitty keyboard flags: {?d}   truecolor (DECRQSS): {}   truecolor (env): {}\n", .{
        r.kitty_graphics, r.kitty_keyboard_flags, r.truecolor_decrqss, r.truecolor_env,
    });
    try w.print("cell px (16t): {?any}   text area px (14t): {?any}   worst latency: {d:.2} ms\n", .{ r.cell_px, r.text_area_px, r.max_latency_ms });
}

fn fmtMs(buf: []u8, v: ?f64) []const u8 {
    const x = v orelse return "-";
    return std.fmt.bufPrint(buf, "{d:.2}", .{x}) catch "?";
}

test "escape" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("\\e[0n\\x07ok", try escape(a.allocator(), "\x1b[0n\x07ok"));
}

test "terminal name" {
    var r: Result = .{ .env = .{ .TERM = null, .TERM_PROGRAM = "Rex Beta", .TERM_PROGRAM_VERSION = null, .COLORTERM = null }, .winsize = undefined, .queries = &.{} };
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("rex_beta", r.terminalName(&buf));
    r.xtversion = "ghostty 1.2.3";
    try std.testing.expectEqualStrings("ghostty", r.terminalName(&buf));
}
