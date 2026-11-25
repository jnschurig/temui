//! Temporary key handling for `play`, until item 06 brings modes and game
//! input (D15). Raw terminal bytes become play actions; escape sequences
//! (arrow keys, late detection replies) are swallowed whole by the reply
//! parser, even when split across reads, so they never misfire.
//!
//! A lone ESC waits for the byte after it: ESC then `q` reads as Alt-q and
//! does not quit. An escape sequence left unfinished for `stale_ns` (a
//! typed ESC, or ESC `]` opening a string nothing terminates) is dropped
//! when the next input arrives, so typed keys can't be swallowed for good.
//! Ctrl-C (0x03) always quits, whatever the parser is in the middle of.

const std = @import("std");
const replies = @import("../term/replies.zig");

pub const Action = enum {
    quit,
    toggle_pause,
    step,
    faster,
    slower,
    reset_speed,
    toggle_overlay,
};

/// The binding for one typed byte, if any. Space is deliberately unbound:
/// it is reserved as a possible leader key (item 06).
pub fn bound(b: u8) ?Action {
    return switch (b) {
        'q' => .quit,
        'p' => .toggle_pause,
        '.' => .step,
        '+', '=' => .faster,
        '-' => .slower,
        '0' => .reset_speed,
        'o' => .toggle_overlay,
        else => null,
    };
}

/// How long an unfinished escape sequence may wait for its next byte.
/// Terminals send a sequence in one write, so a longer gap means a typed
/// ESC (as vim's `ttimeoutlen`, 100 ms).
pub const stale_ns: i96 = 100 * std.time.ns_per_ms;

pub const Decoder = struct {
    parser: replies.Parser = .{},
    /// When the last input arrived.
    last_ns: ?i96 = null,

    /// The actions in `bytes`, read at `now_ns`, in order. Parser state
    /// carries over between calls, so a sequence split across reads is
    /// still recognised, unless it has gone stale (see `stale_ns`).
    pub fn feed(d: *Decoder, bytes: []const u8, now_ns: i96) Iterator {
        if (bytes.len > 0) {
            if (d.last_ns) |last| if (now_ns - last >= stale_ns) {
                d.parser = .{};
            };
            d.last_ns = now_ns;
        }
        return .{ .d = d, .rest = bytes };
    }

    pub const Iterator = struct {
        d: *Decoder,
        rest: []const u8,

        pub fn next(it: *Iterator) ?Action {
            while (it.rest.len > 0) {
                const b = it.rest[0];
                it.rest = it.rest[1..];
                if (b == 0x03) {
                    it.d.parser = .{};
                    return .quit;
                }
                const e = it.d.parser.feed(b) orelse continue;
                switch (e.kind) {
                    .byte => if (bound(e.raw[0])) |a| return a,
                    else => {},
                }
            }
            return null;
        }
    };
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Feeds `input` in chunks of `chunk` bytes and collects the actions.
fn collect(input: []const u8, chunk: usize, out: []Action) ![]Action {
    var d: Decoder = .{};
    var n: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += chunk) {
        var it = d.feed(input[i..@min(i + chunk, input.len)], 0);
        while (it.next()) |a| {
            if (n == out.len) return error.TooManyActions;
            out[n] = a;
            n += 1;
        }
    }
    return out[0..n];
}

fn expectActions(input: []const u8, want: []const Action) !void {
    var buf: [64]Action = undefined;
    var chunk: usize = 1;
    while (chunk <= @max(input.len, 1)) : (chunk += 1) {
        try testing.expectEqualSlices(Action, want, try collect(input, chunk, &buf));
    }
}

test "every binding" {
    try expectActions("q\x03p.+=-0o", &.{
        .quit, .quit, .toggle_pause, .step, .faster, .faster, .slower, .reset_speed, .toggle_overlay,
    });
}

test "space and other bytes are ignored" {
    try expectActions(" aQP\r\n\x7f\x1a\xc3\xa9", &.{});
}

test "arrow keys and function keys, split at every boundary, do nothing" {
    // CSI arrows, SS3 arrows and F1 (ESC O P), a CSI F5 with params.
    try expectActions("\x1b[A\x1b[B\x1bOA\x1bOP\x1bOq\x1b[15~\x1b[1;5p", &.{});
}

test "late detection replies containing q and p do nothing" {
    const late =
        "\x1b[?62;22;52c" ++ // DA1
        "\x1bP>|qterm p.1\x1b\\" ++ // XTVERSION with q and p
        "\x1b_Gi=31;OK\x1b\\" ++ // kitty graphics reply
        "\x1b]11;rgb:0000/0000/0000\x07" ++ // OSC, BEL-terminated
        "\x1bP1$rq\x1b\\" ++ // DECRQSS
        "\x1b[6;20;10t";
    try expectActions(late, &.{});
    // Keys around them still work.
    try expectActions("p" ++ late ++ "q", &.{ .toggle_pause, .quit });
}

test "ESC then q does not quit; a lone ESC does nothing" {
    try expectActions("\x1bq", &.{});
    try expectActions("\x1b", &.{});
    try expectActions("\x1b\x1bq", &.{});
    // The key after an Alt-combination works.
    try expectActions("\x1bqp", &.{.toggle_pause});
}

fn feedAll(d: *Decoder, bytes: []const u8, now_ns: i96, out: []Action) []Action {
    var n: usize = 0;
    var it = d.feed(bytes, now_ns);
    while (it.next()) |a| : (n += 1) out[n] = a;
    return out[0..n];
}

test "Ctrl-C quits inside any unfinished sequence" {
    for ([_][]const u8{ "\x1b", "\x1b[1;", "\x1bO", "\x1b]11;", "\x1bP>|", "\x1b_G", "\x1bP>|x\x1b" }) |prefix| {
        var d: Decoder = .{};
        var buf: [4]Action = undefined;
        try testing.expectEqualSlices(Action, &.{}, feedAll(&d, prefix, 0, &buf));
        try testing.expectEqualSlices(Action, &.{.quit}, feedAll(&d, "\x03", 0, &buf));
        // The parser was reset: the next key works.
        try testing.expectEqualSlices(Action, &.{.toggle_pause}, feedAll(&d, "p", 0, &buf));
    }
}

test "an unfinished sequence goes stale, so later keys work" {
    var buf: [4]Action = undefined;
    // A typed ESC ] (OSC opener) would swallow everything until ST or BEL.
    var d: Decoder = .{};
    try testing.expectEqualSlices(Action, &.{}, feedAll(&d, "\x1b]", 0, &buf));
    try testing.expectEqualSlices(Action, &.{}, feedAll(&d, "q", stale_ns - 1, &buf));
    try testing.expectEqualSlices(Action, &.{.quit}, feedAll(&d, "q", 2 * stale_ns, &buf));
    // ESC, then q well after it, is a plain q.
    d = .{};
    try testing.expectEqualSlices(Action, &.{}, feedAll(&d, "\x1b", 0, &buf));
    try testing.expectEqualSlices(Action, &.{.quit}, feedAll(&d, "q", stale_ns, &buf));
    // A reply split across reads inside the window is still swallowed.
    d = .{};
    try testing.expectEqualSlices(Action, &.{}, feedAll(&d, "\x1bP>|qte", 0, &buf));
    try testing.expectEqualSlices(Action, &.{}, feedAll(&d, "rm p\x1b\\", stale_ns / 2, &buf));
    try testing.expectEqualSlices(Action, &.{.toggle_pause}, feedAll(&d, "p", stale_ns / 2, &buf));
}
