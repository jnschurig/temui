//! Terminal input bytes → `keys.Input`, for the kitty keyboard protocol and
//! for plain legacy terminal input (item 06). Built over `replies.Parser`,
//! so sequences split across reads are reassembled and late detection
//! replies are swallowed.
//!
//! **Kitty mode** decodes `CSI code[:shifted[:base]] [;mods[:event]] u` and
//! the functional keys the protocol still sends in legacy form (`CSI 1;mods:
//! event A–D/H/F/P–S`, `CSI n;mods:event ~`), with press, repeat and
//! release. With flag 8 the terminal never sends a key as a plain byte, so
//! one arriving suggests the protocol is gone, but doesn't prove it (the
//! rest of a sequence split across slow reads looks the same). Such keys
//! are dropped, and `wantsQuery` asks the loop to send the terminal
//! `session.kitty_query`; the answer (`takeAnswer`) decides. While a query
//! is out, keys in legacy form are dropped too: they may predate the push,
//! or be the tail of a split sequence. Ctrl-C always gets through.
//!
//! **Queries** (both modes): the reply to `CSI ? u` and the DA1 sentinel
//! after it answer the query that is out. Nonzero flags mean the protocol
//! is active; zero flags, or DA1 alone, mean it isn't. The session's query
//! at enter is out from `init` in kitty mode; the loop's later ones, from
//! `querySent`, are taken as unanswered after `query_timeout_ns`.
//!
//! **Legacy mode** decodes printable ASCII and UTF-8, Enter, Tab, Backspace,
//! Ctrl chords, CSI/SS3 navigation keys with modifier parameters, and ESC +
//! byte as Alt. Every event is a press. A lone ESC with nothing after it
//! for `stale_ns` is Esc (`deadline` / `expire`).
//!
//! Both modes: `CSI I` / `CSI O` are focus reports. Unknown sequences are
//! dropped. A 0x03 byte always resets the parser and is Ctrl-C, except in
//! a paste.
//!
//! **Bracketed paste** (both modes): everything from `CSI 200 ~` to
//! `CSI 201 ~` is discarded, so pasted text never reads as keys (or as
//! legacy keys on the kitty path). If no byte arrives for `paste_idle_ns`
//! before the end marker, the paste is ended there (`deadline` /
//! `expire`), so a lost end marker can't lock out input.

const std = @import("std");
const keys = @import("keys.zig");
const replies = @import("replies.zig");

const Event = keys.Event;
const Input = keys.Input;
const Mods = keys.Mods;
const Named = keys.Named;

pub const Mode = enum { kitty, legacy };

/// How long an unfinished escape sequence may wait for its next byte.
/// Terminals send a sequence in one write, so a longer gap means a typed
/// ESC (as vim's `ttimeoutlen`, 100 ms).
pub const stale_ns: i96 = 100 * std.time.ns_per_ms;

/// How long a paste may go without a byte before it is taken as ended.
/// Terminals send a paste in a burst.
pub const paste_idle_ns: i96 = 500 * std.time.ns_per_ms;

/// How long a query sent by the loop may go unanswered before the protocol
/// is taken as inactive. Every terminal answers DA1, so this only matters
/// for a terminal that stopped answering, or a very slow link.
pub const query_timeout_ns: i96 = 2 * std.time.ns_per_s;

/// The terminal's answer to a kitty keyboard query.
pub const Answer = enum { active, inactive };

const Query = struct {
    /// When the loop sent it; null for the session's own query at enter,
    /// which never times out.
    sent_ns: ?i96,
    /// The flags the terminal reported, once its `CSI ? flags u` arrived.
    flags: ?u32 = null,
};

const paste_end = "\x1b[201~";

const log = std.log.scoped(.input);

const Paste = struct {
    /// Bytes discarded so far, the end marker included.
    bytes: usize = 0,
    /// How much of `paste_end` the last bytes matched.
    matched: u8 = 0,
};

pub const Decoder = struct {
    mode: Mode,
    parser: replies.Parser = .{},
    /// When the last input arrived.
    last_ns: ?i96 = null,
    /// The kitty keyboard query out, if any.
    query: ?Query = null,
    /// The last query's answer, until `takeAnswer`.
    answer: ?Answer = null,
    /// Kitty mode: a key arrived in legacy form with no query out.
    suspect: bool = false,
    /// A partial UTF-8 character (legacy input).
    utf8: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_need: u3 = 0,
    utf8_alt: bool = false,
    /// One input queued ahead of the bytes (a stale ESC found by `feed`).
    queued: ?Input = null,
    /// Inside a bracketed paste.
    paste: ?Paste = null,

    /// In kitty mode, the session's query at enter is out.
    pub fn init(mode: Mode) Decoder {
        return .{ .mode = mode, .query = if (mode == .kitty) .{ .sent_ns = null } else null };
    }

    /// Kitty mode: a key arrived in legacy form, so the protocol may be
    /// gone. Send `session.kitty_query`, then call `querySent`.
    pub fn wantsQuery(d: *const Decoder) bool {
        return d.suspect;
    }

    /// The loop sent `session.kitty_query` at `now_ns`.
    pub fn querySent(d: *Decoder, now_ns: i96) void {
        d.suspect = false;
        d.query = .{ .sent_ns = now_ns };
    }

    /// The answer to the last query, once; null while none has come.
    pub fn takeAnswer(d: *Decoder) ?Answer {
        defer d.answer = null;
        return d.answer;
    }

    /// Decodes in legacy mode from now on (the protocol is gone).
    pub fn switchToLegacy(d: *Decoder) void {
        d.mode = .legacy;
        d.suspect = false;
    }

    /// Decodes in kitty mode from now on (a recheck found the protocol).
    pub fn switchToKitty(d: *Decoder) void {
        d.mode = .kitty;
        d.suspect = false;
    }

    /// The inputs in `bytes`, read at `now_ns`, in order. Parser state
    /// carries over between calls, so a sequence split across reads is
    /// still recognised, unless it has gone stale (see `stale_ns`): then a
    /// held lone ESC comes out as Esc first, and any other partial
    /// sequence is dropped.
    pub fn feed(d: *Decoder, bytes: []const u8, now_ns: i96) Iterator {
        if (bytes.len > 0) {
            if (d.paste != null) {
                _ = d.expire(now_ns);
            } else if (d.last_ns) |last| if (now_ns - last >= stale_ns) {
                d.queued = d.takeStale();
            };
            d.last_ns = now_ns;
        }
        return .{ .d = d, .rest = bytes };
    }

    /// When a held lone ESC goes stale, a paste is taken as ended or a query
    /// times out (call `expire` then), or null.
    pub fn deadline(d: *const Decoder) ?i96 {
        const q = d.queryDeadline();
        const i = d.inputDeadline() orelse return q;
        return if (q) |x| @min(x, i) else i;
    }

    fn queryDeadline(d: *const Decoder) ?i96 {
        const q = d.query orelse return null;
        return (q.sent_ns orelse return null) + query_timeout_ns;
    }

    fn inputDeadline(d: *const Decoder) ?i96 {
        const last = d.last_ns orelse return null;
        if (d.paste != null) return last + paste_idle_ns;
        if (!d.parser.pendingLoneEsc()) return null;
        return last + stale_ns;
    }

    /// Esc, if a lone ESC has been held for `stale_ns` by `now_ns`. Ends a
    /// paste that has gone `paste_idle_ns` without a byte. A query out for
    /// `query_timeout_ns` is answered `inactive`.
    pub fn expire(d: *Decoder, now_ns: i96) ?Input {
        if (d.queryDeadline()) |qd| if (now_ns >= qd) {
            log.warn("no answer to the kitty keyboard query in {d} ms; taking the protocol as inactive", .{@divTrunc(query_timeout_ns, std.time.ns_per_ms)});
            d.query = null;
            d.answer = .inactive;
        };
        const dl = d.inputDeadline() orelse return null;
        if (now_ns < dl) return null;
        if (d.paste) |p| {
            log.warn("paste: no end marker after {d} bytes; taking it as ended", .{p.bytes});
            d.paste = null;
            return null;
        }
        return d.takeStale();
    }

    /// A paste byte: discarded, watching for the end marker.
    fn pasteByte(d: *Decoder, b: u8) void {
        const p = &d.paste.?;
        p.bytes += 1;
        if (b == paste_end[p.matched]) {
            p.matched += 1;
            if (p.matched == paste_end.len) {
                log.debug("paste: {d} bytes discarded", .{p.bytes - paste_end.len});
                d.paste = null;
            }
        } else {
            // ESC occurs only at the marker's start.
            p.matched = if (b == paste_end[0]) 1 else 0;
        }
    }

    fn takeStale(d: *Decoder) ?Input {
        const esc = d.parser.pendingLoneEsc();
        d.parser = .{};
        d.utf8_need = 0;
        return if (esc) d.legacy(.{ .key = .named(.escape) }) else null;
    }

    /// Passes a legacy-form input through the kitty-mode rule: dropped, and
    /// suspected unless a query is already out.
    fn legacy(d: *Decoder, in: Input) ?Input {
        if (d.mode == .legacy) return in;
        d.suspectLegacy();
        return null;
    }

    fn suspectLegacy(d: *Decoder) void {
        if (d.mode == .kitty and d.query == null) d.suspect = true;
    }

    pub const Iterator = struct {
        d: *Decoder,
        rest: []const u8,

        pub fn next(it: *Iterator) ?Input {
            const d = it.d;
            if (d.queued) |q| {
                d.queued = null;
                return q;
            }
            while (it.rest.len > 0) {
                const b = it.rest[0];
                it.rest = it.rest[1..];
                if (d.paste != null) {
                    d.pasteByte(b);
                    continue;
                }
                if (b == 0x03) {
                    d.parser = .{};
                    d.utf8_need = 0;
                    const ctrl_c: Input = .{ .key = .{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } } };
                    // Ctrl-C always gets through, even with a query out.
                    d.suspectLegacy();
                    return ctrl_c;
                }
                const e = d.parser.feed(b) orelse continue;
                if (d.decode(e)) |in| return in;
            }
            return null;
        }
    };

    fn decode(d: *Decoder, e: replies.Event) ?Input {
        switch (e.kind) {
            .byte => return d.byte(e.raw[0], false),
            .kitty_keyboard => {
                if (d.query) |*q| q.flags = e.keyboardFlags() orelse 0;
                return null;
            },
            .da1 => {
                // The sentinel after `CSI ? u`, which ends the query.
                if (d.query) |q| {
                    d.query = null;
                    d.answer = if ((q.flags orelse 0) != 0) .active else .inactive;
                }
                return null;
            },
            .other => {},
            else => return null,
        }
        const raw = e.raw;
        if (raw.len < 2 or raw[0] != 0x1b) return null;
        return switch (raw[1]) {
            '[' => if (raw.len >= 3) d.csi(raw[2 .. raw.len - 1], raw[raw.len - 1]) else null,
            'O' => if (raw.len == 3) d.ss3(raw[2]) else null,
            'P', '_', ']', 'X', '^' => null, // strings
            else => if (raw.len == 2) d.byte(raw[1], true) else null,
        };
    }

    /// A plain byte outside a sequence (or after ESC, with `alt`).
    fn byte(d: *Decoder, b: u8, alt: bool) ?Input {
        if (b >= 0x80) return d.utf8Byte(b, alt);
        d.utf8_need = 0;
        var ev = legacyByte(b);
        if (alt) ev.mods.alt = true;
        return d.legacy(.{ .key = ev });
    }

    fn utf8Byte(d: *Decoder, b: u8, alt: bool) ?Input {
        if (d.utf8_need > 0 and b & 0xc0 == 0x80) {
            d.utf8[d.utf8_len] = b;
            d.utf8_len += 1;
            if (d.utf8_len < d.utf8_need) return null;
            d.utf8_need = 0;
            const cp = std.unicode.utf8Decode(d.utf8[0..d.utf8_len]) catch return null;
            var ev: Event = .char(cp);
            ev.mods.alt = d.utf8_alt;
            return d.legacy(.{ .key = ev });
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            d.utf8_need = 0;
            return null;
        };
        d.utf8[0] = b;
        d.utf8_len = 1;
        d.utf8_need = n;
        d.utf8_alt = alt;
        return null;
    }

    fn ss3(d: *Decoder, final: u8) ?Input {
        const n = letterKey(final) orelse return null;
        return d.legacy(.{ .key = .named(n) });
    }

    fn csi(d: *Decoder, params: []const u8, final: u8) ?Input {
        if (params.len > 0 and (params[0] < '0' or params[0] > '9') and params[0] != ';' and params[0] != ':') return null;
        var fields: [3][]const u8 = .{ "", "", "" };
        var it = std.mem.splitScalar(u8, params, ';');
        for (&fields) |*f| f.* = it.next() orelse break;
        switch (final) {
            'I', 'O' => return if (params.len == 0) .{ .focus = final == 'I' } else null,
            'u' => return kittyKey(fields),
            'Z' => return d.legacy(.{ .key = .{ .key = .{ .named = .tab }, .mods = .{ .shift = true } } }),
            '~' => {
                const num = parseNum(sub(fields[0], 0)) orelse return null;
                if (num == 27) return modifyOtherKeys(fields);
                if (std.mem.eql(u8, params, "200")) {
                    d.paste = .{};
                    return null;
                }
                // A stray end marker.
                if (num == 200 or num == 201) return null;
                const n = tildeKey(num) orelse return null;
                return withEventMods(.named(n), fields[1]);
            },
            else => {
                const n = letterKey(final) orelse return null;
                // `CSI A` or `CSI 1;mods[:event] A`.
                if (fields[0].len > 0 and !std.mem.eql(u8, sub(fields[0], 0), "1")) return null;
                return withEventMods(.named(n), fields[1]);
            },
        }
    }
};

/// `CSI 27;mods;code ~` (xterm modifyOtherKeys, as tmux's extended keys
/// send it): a character key with modifiers. Press only.
fn modifyOtherKeys(fields: [3][]const u8) ?Input {
    const code = parseNum(fields[2]) orelse return null;
    var ev = codeKey(code) orelse return null;
    ev.mods = parseMods(fields[1]) orelse return null;
    return .{ .key = ev };
}

/// `code[:shifted[:base]] ; mods[:event] [; text]`.
fn kittyKey(fields: [3][]const u8) ?Input {
    const code = parseNum(sub(fields[0], 0)) orelse return null;
    var ev = codeKey(code) orelse return null;
    if (ev.key == .char) {
        if (parseNum(sub(fields[0], 1))) |s| if (s >= 0x20 and s <= 0x10ffff) {
            ev.shifted = @intCast(s);
        };
    }
    return withEventMods(ev, fields[1]);
}

/// Applies `mods[:event]` (both optional) to `ev`.
fn withEventMods(ev0: Event, field: []const u8) ?Input {
    var ev = ev0;
    const m = parseMods(sub(field, 0)) orelse return null;
    ev.mods.shift = ev.mods.shift or m.shift;
    ev.mods.alt = m.alt;
    ev.mods.ctrl = m.ctrl;
    ev.mods.super = m.super;
    ev.kind = switch (parseNum(sub(field, 1)) orelse 1) {
        1 => .press,
        2 => .repeat,
        3 => .release,
        else => return null,
    };
    return .{ .key = ev };
}

/// A kitty modifier value (1 + bits): shift 1, alt 2, ctrl 4, super 8,
/// hyper 16, meta 32 (both read as super), caps 64, num 128 (ignored).
/// Empty is no modifiers.
fn parseMods(s: []const u8) ?Mods {
    if (s.len == 0) return Mods.none;
    const v = parseNum(s) orelse return null;
    if (v == 0) return null;
    const bits = v - 1;
    return .{
        .shift = bits & 1 != 0,
        .alt = bits & 2 != 0,
        .ctrl = bits & 4 != 0,
        .super = bits & (8 | 16 | 32) != 0,
    };
}

/// A kitty key code (a Unicode codepoint or a private-use functional key).
fn codeKey(code: u32) ?Event {
    const named: ?Named = switch (code) {
        27 => .escape,
        13 => .enter,
        9 => .tab,
        127, 8 => .backspace,
        57358 => .caps_lock,
        57414 => .enter, // keypad Enter
        57417 => .left,
        57418 => .right,
        57419 => .up,
        57420 => .down,
        57421 => .page_up,
        57422 => .page_down,
        57423 => .home,
        57424 => .end,
        57425 => .insert,
        57426 => .delete,
        57441 => .left_shift,
        57442 => .left_ctrl,
        57443 => .left_alt,
        57444 => .left_super,
        57447 => .right_shift,
        57448 => .right_ctrl,
        57449 => .right_alt,
        57450 => .right_super,
        else => null,
    };
    if (named) |n| return .named(n);
    // Keypad characters.
    const kp: ?u21 = switch (code) {
        57399...57408 => @intCast('0' + (code - 57399)),
        57409 => '.',
        57410 => '/',
        57411 => '*',
        57412 => '-',
        57413 => '+',
        57415 => '=',
        57416 => ',',
        else => null,
    };
    if (kp) |c| return .char(c);
    // Other private-use codes (media keys, F13+, hyper/meta keys, …) and
    // anything that isn't a valid codepoint are dropped.
    if (code >= 0xe000 and code <= 0xf8ff) return null;
    if (code < 0x20 or code > 0x10ffff) return null;
    const c: u21 = @intCast(code);
    var ev: Event = .char(keys.lower(c));
    if (c != ev.key.char) {
        ev.shifted = c;
        ev.mods.shift = true;
    }
    return ev;
}

/// The final byte of `CSI 1;mods X` / `SS3 X` navigation and F1–F4 keys.
fn letterKey(final: u8) ?Named {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3, // safe: temui never asks for a cursor position report
        'S' => .f4,
        else => null,
    };
}

/// The number of `CSI n ~`.
fn tildeKey(n: u32) ?Named {
    return switch (n) {
        1, 7 => .home,
        2 => .insert,
        3 => .delete,
        4, 8 => .end,
        5 => .page_up,
        6 => .page_down,
        11...15 => Named.f(@intCast(n - 11)),
        17...21 => Named.f(@intCast(n - 17 + 5)),
        23, 24 => Named.f(@intCast(n - 23 + 10)),
        else => null,
    };
}

/// A legacy byte outside a sequence (not ESC, not 0x03, not ≥ 0x80).
fn legacyByte(b: u8) Event {
    const c: Mods = .{ .ctrl = true };
    return switch (b) {
        '\r', '\n' => .named(.enter),
        '\t' => .named(.tab),
        0x7f, 0x08 => .named(.backspace),
        0x00 => .{ .key = .{ .char = ' ' }, .mods = c },
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => .{ .key = .{ .char = 'a' + @as(u21, b) - 1 }, .mods = c },
        0x1b => .named(.escape),
        0x1c => .{ .key = .{ .char = '\\' }, .mods = c },
        0x1d => .{ .key = .{ .char = ']' }, .mods = c },
        0x1e => .{ .key = .{ .char = '^' }, .mods = c },
        0x1f => .{ .key = .{ .char = '_' }, .mods = c },
        'A'...'Z' => .{ .key = .{ .char = keys.lower(b) }, .shifted = b, .mods = .{ .shift = true } },
        else => .char(b),
    };
}

/// The `i`th `:`-separated part of `field`, or "".
fn sub(field: []const u8, i: usize) []const u8 {
    var it = std.mem.splitScalar(u8, field, ':');
    var k: usize = 0;
    while (it.next()) |part| : (k += 1) if (k == i) return part;
    return "";
}

fn parseNum(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Feeds `input` in chunks of `chunk` bytes (all at time 0) and collects
/// the inputs.
fn collect(d: *Decoder, input: []const u8, chunk: usize, out: []Input) ![]Input {
    var n: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += chunk) {
        var it = d.feed(input[i..@min(i + chunk, input.len)], 0);
        while (it.next()) |in| {
            if (n == out.len) return error.TooManyInputs;
            out[n] = in;
            n += 1;
        }
    }
    return out[0..n];
}

fn expectInputsEql(want: []const Input, got: []const Input) !void {
    errdefer {
        std.debug.print("want:\n", .{});
        for (want) |w| printInput(w);
        std.debug.print("got:\n", .{});
        for (got) |g| printInput(g);
    }
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        switch (w) {
            .focus => |f| try testing.expect(g == .focus and g.focus == f),
            .key => |k| try testing.expect(g == .key and k.eql(g.key)),
        }
    }
}

fn printInput(in: Input) void {
    switch (in) {
        .focus => |f| std.debug.print("  focus {}\n", .{f}),
        .key => |k| std.debug.print("  {f} shifted={?d}\n", .{ k, k.shifted }),
    }
}

/// Checks `input` decodes to `want` at every chunk size.
fn expectDecode(mode: Mode, input: []const u8, want: []const Input) !void {
    var buf: [64]Input = undefined;
    var chunk: usize = 1;
    while (chunk <= @max(input.len, 1)) : (chunk += 1) {
        var d: Decoder = .init(mode);
        d.query = null;
        try expectInputsEql(want, try collect(&d, input, chunk, &buf));
    }
}

fn key(k: keys.Key, mods: Mods, kind: keys.Kind) Input {
    return .{ .key = .{ .key = k, .mods = mods, .kind = kind } };
}

fn ch(c: u21) keys.Key {
    return .{ .char = c };
}

fn nm(n: Named) keys.Key {
    return .{ .named = n };
}

const none: Mods = .none;
const ctrl: Mods = .{ .ctrl = true };
const shift: Mods = .{ .shift = true };

test "kitty: press, repeat, release of a letter, split at every boundary" {
    try expectDecode(.kitty, "\x1b[101u\x1b[101;1:2u\x1b[101;1:3u", &.{
        key(ch('e'), none, .press),
        key(ch('e'), none, .repeat),
        key(ch('e'), none, .release),
    });
}

test "kitty: modifiers, alternate keys and Ctrl-C" {
    try expectDecode(.kitty, "\x1b[122:90;2u" ++ // Shift-z
        "\x1b[61:43;2u" ++ // Shift-= gives +
        "\x1b[99;5u" ++ // Ctrl-C
        "\x1b[93;5u" ++ // Ctrl-]
        "\x1b[101;3u" ++ // Alt-e
        "\x1b[101;65u" ++ // e with Caps Lock (ignored)
        "\x1b[101;9u", // Super-e
        &.{
            .{ .key = .{ .key = ch('z'), .shifted = 'Z', .mods = shift } },
            .{ .key = .{ .key = ch('='), .shifted = '+', .mods = shift } },
            key(ch('c'), ctrl, .press),
            key(ch(']'), ctrl, .press),
            key(ch('e'), .{ .alt = true }, .press),
            key(ch('e'), none, .press),
            key(ch('e'), .{ .super = true }, .press),
        });
}

test "kitty: named and functional keys" {
    try expectDecode(.kitty, "\x1b[27u\x1b[13u\x1b[9u\x1b[127u\x1b[32u" ++
        "\x1b[A\x1b[1;5B\x1b[1;1:3C\x1b[1;2:2D\x1b[H\x1b[F" ++
        "\x1b[2~\x1b[3;5~\x1b[5~\x1b[6;1:3~\x1b[P\x1b[1;2Q\x1b[13~\x1b[S\x1b[15~\x1b[24;1:2~" ++
        "\x1b[57441;2u\x1b[57441;1:3u\x1b[57399u\x1b[57414u\x1b[57428u", &.{
        key(nm(.escape), none, .press),
        key(nm(.enter), none, .press),
        key(nm(.tab), none, .press),
        key(nm(.backspace), none, .press),
        key(ch(' '), none, .press),
        key(nm(.up), none, .press),
        key(nm(.down), ctrl, .press),
        key(nm(.right), none, .release),
        key(nm(.left), shift, .repeat),
        key(nm(.home), none, .press),
        key(nm(.end), none, .press),
        key(nm(.insert), none, .press),
        key(nm(.delete), ctrl, .press),
        key(nm(.page_up), none, .press),
        key(nm(.page_down), none, .release),
        key(nm(.f1), none, .press),
        key(nm(.f2), shift, .press),
        key(nm(.f3), none, .press),
        key(nm(.f4), none, .press),
        key(nm(.f5), none, .press),
        key(nm(.f12), none, .repeat),
        key(nm(.left_shift), shift, .press),
        key(nm(.left_shift), none, .release),
        key(ch('0'), none, .press), // keypad 0
        key(nm(.enter), none, .press), // keypad Enter
        // 57428 (media play) is dropped.
    });
}

test "kitty: text field and unknown sequences are tolerated" {
    try expectDecode(.kitty, "\x1b[97;1;97u\x1b[?1049h\x1b[12;40R\x1b[201~\x1b[5;5x", &.{
        key(ch('a'), none, .press),
    });
}

test "kitty: late detection replies are swallowed" {
    const late =
        "\x1b[?62;22;52c" ++ // DA1
        "\x1bP>|qterm p.1\x1b\\" ++ // XTVERSION
        "\x1b_Gi=31;OK\x1b\\" ++ // kitty graphics reply
        "\x1b]11;rgb:0000/0000/0000\x07" ++ // OSC
        "\x1bP1$rq\x1b\\" ++ // DECRQSS
        "\x1b[6;20;10t";
    try expectDecode(.kitty, "\x1b[112u" ++ late ++ "\x1b[113u", &.{
        key(ch('p'), none, .press),
        key(ch('q'), none, .press),
    });
    try expectDecode(.legacy, "p" ++ late ++ "q", &.{
        key(ch('p'), none, .press),
        key(ch('q'), none, .press),
    });
}

// Recorded from Rex 0.1.0-preview.19 with flags 15 pushed (roadmap 06 manual
// run, `docs/bench/06-keyboard.md`): the reads logged by `play --verbose`
// while `rex send-key` pressed and released keys, in order.
test "recorded: Rex, kitty flags 15" {
    try expectDecode(.kitty, "\x1b[?15u\x1b[?62;22c" ++ // detection replies
        "\x1b[101u\x1b[101;1:3u" ++ // e
        "\x1b[27u\x1b[27;1:3u" ++ // Esc
        "\x1b[46u\x1b[46;1:3u" ++ // .
        "\x1b[93;5u\x1b[93;5:3u" ++ // Ctrl-]
        "\x1b[13u\x1b[13;1:3u" ++ // Enter
        "\x1b[99;5u\x1b[99;5:3u" ++ // Ctrl-C
        "\x1b[32u\x1b[32;1:3u\x1b[113u\x1b[113;1:3u" ++ // Space q, one read
        "\x1b[O\x1b[O\x1b[I", // focus out twice, then in
        &.{
            key(ch('e'), none, .press),     key(ch('e'), none, .release),
            key(nm(.escape), none, .press), key(nm(.escape), none, .release),
            key(ch('.'), none, .press),     key(ch('.'), none, .release),
            key(ch(']'), ctrl, .press),     key(ch(']'), ctrl, .release),
            key(nm(.enter), none, .press),  key(nm(.enter), none, .release),
            key(ch('c'), ctrl, .press),     key(ch('c'), ctrl, .release),
            key(ch(' '), none, .press),     key(ch(' '), none, .release),
            key(ch('q'), none, .press),     key(ch('q'), none, .release),
            .{ .focus = false },            .{ .focus = false },
            .{ .focus = true },
        });
}

// Recorded from Ghostty 1.4.0 with flags 15 pushed (same run): reads as
// logged, including several events in one read.
test "recorded: Ghostty, kitty flags 15" {
    try expectDecode(.kitty, "\x1b[I\x1b[?15u\x1b[?62;22;52c" ++ // focus in, detection replies
        "\x1b[101u\x1b[101;1:3u" ++ // e
        "\x1b[102;1:2u\x1b[107u" ++ // f repeating, k pressed, one read
        "\x1b[106;5:2u" ++ // Ctrl-j repeating
        "\x1b[57441;2u\x1b[92:124;2u\x1b[92;2:3u\x1b[57441;1:3u" ++ // Shift-\ gives |
        "\x1b[57448;5u\x1b[93;5u\x1b[93;5:3u" ++ // right Ctrl, Ctrl-]
        "\x1b[57448;1:3u\x1b[O" ++ // right Ctrl up, then focus out (Cmd-Tab), one read
        "\x1b[99;5u\x1b[99;5:3u" ++ // Ctrl-C
        "\x1b[200~printf '\\033[<u' > /dev/ttys008\x1b[201~", // a paste, discarded
        &.{
            .{ .focus = true },
            key(ch('e'), none, .press),
            key(ch('e'), none, .release),
            key(ch('f'), none, .repeat),
            key(ch('k'), none, .press),
            key(ch('j'), ctrl, .repeat),
            key(nm(.left_shift), shift, .press),
            .{ .key = .{ .key = ch('\\'), .shifted = '|', .mods = shift } },
            key(ch('\\'), shift, .release),
            key(nm(.left_shift), none, .release),
            key(nm(.right_ctrl), ctrl, .press),
            key(ch(']'), ctrl, .press),
            key(ch(']'), ctrl, .release),
            key(nm(.right_ctrl), none, .release),
            .{ .focus = false },
            key(ch('c'), ctrl, .press),
            key(ch('c'), ctrl, .release),
        });
}

// Recorded from Rex through GNU screen 4.00 (no kitty protocol: the
// disabled path): i, Enter, Ctrl-], Space, Ctrl-C.
test "recorded: Rex through screen, legacy" {
    try expectDecode(.legacy, "i\x0d\x1d \x03", &.{
        key(ch('i'), none, .press),
        key(nm(.enter), none, .press),
        key(ch(']'), ctrl, .press),
        key(ch(' '), none, .press),
        key(ch('c'), ctrl, .press),
    });
}

test "focus reports on both paths" {
    for ([_]Mode{ .kitty, .legacy }) |m| try expectDecode(m, "\x1b[O\x1b[I", &.{ .{ .focus = false }, .{ .focus = true } });
}

test "legacy: bytes" {
    try expectDecode(.legacy, "aZ+;\r\n\t\x7f\x08\x05\x1d\x1c\x1e\x00 ", &.{
        key(ch('a'), none, .press),
        .{ .key = .{ .key = ch('z'), .shifted = 'Z', .mods = shift } },
        key(ch('+'), none, .press),
        key(ch(';'), none, .press),
        key(nm(.enter), none, .press),
        key(nm(.enter), none, .press),
        key(nm(.tab), none, .press),
        key(nm(.backspace), none, .press),
        key(nm(.backspace), none, .press),
        key(ch('e'), ctrl, .press),
        key(ch(']'), ctrl, .press),
        key(ch('\\'), ctrl, .press),
        key(ch('^'), ctrl, .press),
        key(ch(' '), ctrl, .press),
        key(ch(' '), none, .press),
    });
}

test "legacy: UTF-8, Alt, navigation keys" {
    try expectDecode(.legacy, "\xc3\xa9\xe2\x82\xac\x1be\x1bZ\x1b\x7f\x1b[A\x1bOB\x1b[1;5C\x1bOP\x1b[15;2~\x1b[Z\x1b\xc3\xa9", &.{
        key(ch(0xe9), none, .press),
        key(ch(0x20ac), none, .press),
        key(ch('e'), .{ .alt = true }, .press),
        .{ .key = .{ .key = ch('z'), .shifted = 'Z', .mods = .{ .shift = true, .alt = true } } },
        key(nm(.backspace), .{ .alt = true }, .press),
        key(nm(.up), none, .press),
        key(nm(.down), none, .press),
        key(nm(.right), ctrl, .press),
        key(nm(.f1), none, .press),
        key(nm(.f5), shift, .press),
        key(nm(.tab), shift, .press),
        key(ch(0xe9), .{ .alt = true }, .press),
    });
}

test "legacy: modifyOtherKeys form" {
    try expectDecode(.legacy, "\x1b[27;5;93~\x1b[27;2;65~", &.{
        key(ch(']'), ctrl, .press),
        .{ .key = .{ .key = ch('a'), .shifted = 'A', .mods = shift } },
    });
}

fn feedAll(d: *Decoder, bytes: []const u8, now_ns: i96, out: []Input) []Input {
    var n: usize = 0;
    var it = d.feed(bytes, now_ns);
    while (it.next()) |in| : (n += 1) out[n] = in;
    return out[0..n];
}

test "legacy: a lone ESC goes stale into Esc, by expire or by the next input" {
    var buf: [8]Input = undefined;
    var d: Decoder = .init(.legacy);
    try expectInputsEql(&.{}, feedAll(&d, "\x1b", 0, &buf));
    try testing.expectEqual(@as(?i96, stale_ns), d.deadline());
    try testing.expectEqual(@as(?Input, null), d.expire(stale_ns - 1));
    try expectInputsEql(&.{key(nm(.escape), none, .press)}, &.{d.expire(stale_ns).?});
    try testing.expectEqual(@as(?i96, null), d.deadline());

    // Not expired, but the next byte comes late: Esc, then the byte.
    d = .init(.legacy);
    try expectInputsEql(&.{}, feedAll(&d, "\x1b", 0, &buf));
    try expectInputsEql(&.{ key(nm(.escape), none, .press), key(ch('e'), none, .press) }, feedAll(&d, "e", stale_ns, &buf));

    // In time: Alt-e.
    d = .init(.legacy);
    try expectInputsEql(&.{}, feedAll(&d, "\x1b", 0, &buf));
    try expectInputsEql(&.{key(ch('e'), .{ .alt = true }, .press)}, feedAll(&d, "e", stale_ns - 1, &buf));

    // A stale partial CSI is dropped, not Esc.
    d = .init(.legacy);
    try expectInputsEql(&.{}, feedAll(&d, "\x1b]", 0, &buf));
    try testing.expectEqual(@as(?i96, null), d.deadline());
    try expectInputsEql(&.{key(ch('q'), none, .press)}, feedAll(&d, "q", stale_ns, &buf));
}

test "Ctrl-C resets inside any unfinished sequence, on both paths" {
    for ([_]Mode{ .kitty, .legacy }) |m| {
        for ([_][]const u8{ "\x1b", "\x1b[1;", "\x1bO", "\x1b]11;", "\x1bP>|", "\x1b_G", "\x1bP>|x\x1b", "\xc3" }) |prefix| {
            var d: Decoder = .init(m);
            var buf: [4]Input = undefined;
            try expectInputsEql(&.{}, feedAll(&d, prefix, 0, &buf));
            try expectInputsEql(&.{key(ch('c'), ctrl, .press)}, feedAll(&d, "\x03", 0, &buf));
        }
    }
}

test "kitty: keys in legacy form are dropped while the query at enter is out" {
    var buf: [8]Input = undefined;
    var d: Decoder = .init(.kitty);
    try expectInputsEql(&.{ key(ch('c'), ctrl, .press), key(ch('e'), none, .press) }, feedAll(&d, "x\x1bOA\x03\x1b[101u", 0, &buf));
    try testing.expect(!d.wantsQuery());
    try testing.expectEqual(null, d.takeAnswer());
    // The query at enter never times out.
    try testing.expectEqual(null, d.deadline());
    // The answer; then a plain byte is dropped and asks for a query.
    try expectInputsEql(&.{}, feedAll(&d, "\x1b[?15u\x1b[?62c", 0, &buf));
    try testing.expectEqual(Answer.active, d.takeAnswer().?);
    try testing.expectEqual(null, d.takeAnswer());
    try expectInputsEql(&.{}, feedAll(&d, "x", 0, &buf));
    try testing.expect(d.wantsQuery());
}

test "kitty: the answer is active for nonzero flags, inactive for zero flags or DA1 alone" {
    var buf: [8]Input = undefined;
    const cases = [_]struct { reply: []const u8, want: Answer }{
        .{ .reply = "\x1b[?15u\x1b[?62;22c", .want = .active },
        .{ .reply = "\x1b[?0u\x1b[?62c", .want = .inactive },
        .{ .reply = "\x1b[?62;22c", .want = .inactive },
    };
    for (cases) |c| {
        var d: Decoder = .init(.kitty);
        _ = feedAll(&d, c.reply, 0, &buf);
        try testing.expectEqual(c.want, d.takeAnswer().?);
        // With no query out, a late reply answers nothing.
        _ = feedAll(&d, c.reply, 0, &buf);
        try testing.expectEqual(null, d.takeAnswer());
    }
}

test "kitty: a key in legacy form asks for a query; the answer decides" {
    var buf: [8]Input = undefined;
    var d: Decoder = .init(.kitty);
    d.query = null;
    // Kitty-form keys never count; Ctrl-C as 0x03 comes through and does.
    try expectInputsEql(&.{ key(ch('e'), none, .press), key(nm(.up), none, .press), key(nm(.up), ctrl, .release) }, feedAll(&d, "\x1b[101u\x1b[A\x1b[1;5:3A", 0, &buf));
    try testing.expect(!d.wantsQuery());
    try expectInputsEql(&.{key(ch('c'), ctrl, .press)}, feedAll(&d, "\x03", 0, &buf));
    try testing.expect(d.wantsQuery());
    d.querySent(10);
    try testing.expect(!d.wantsQuery());
    try testing.expectEqual(@as(?i96, 10 + query_timeout_ns), d.deadline());
    // While it is out, keys in legacy form are dropped and ask for nothing
    // more; kitty-form keys still come through.
    try expectInputsEql(&.{key(ch('f'), none, .press)}, feedAll(&d, "x\x1b[102u", 20, &buf));
    try testing.expect(!d.wantsQuery());
    // Still active: a false alarm.
    _ = feedAll(&d, "\x1b[?15u\x1b[?62c", 30, &buf);
    try testing.expectEqual(Answer.active, d.takeAnswer().?);
    try testing.expectEqual(null, d.deadline());

    // Gone this time; after switchToLegacy, bytes decode as legacy keys.
    _ = feedAll(&d, "y", 40, &buf);
    try testing.expect(d.wantsQuery());
    d.querySent(40);
    _ = feedAll(&d, "\x1b[?62c", 50, &buf);
    try testing.expectEqual(Answer.inactive, d.takeAnswer().?);
    d.switchToLegacy();
    try expectInputsEql(&.{key(ch('e'), none, .press)}, feedAll(&d, "e", 60, &buf));
}

test "kitty: a sequence split across slow reads is a false alarm" {
    var buf: [8]Input = undefined;
    var d: Decoder = .init(.kitty);
    d.query = null;
    _ = feedAll(&d, "\x1b", 0, &buf);
    // The lone ESC goes stale: dropped, and a query is asked for.
    try testing.expectEqual(null, d.expire(stale_ns));
    try testing.expect(d.wantsQuery());
    d.querySent(stale_ns);
    // The rest of the sequence arrives as plain bytes: dropped.
    try expectInputsEql(&.{}, feedAll(&d, "[101u", stale_ns + 50 * std.time.ns_per_ms, &buf));
    try testing.expect(!d.wantsQuery());
    _ = feedAll(&d, "\x1b[?15u\x1b[?62c", stale_ns + 60 * std.time.ns_per_ms, &buf);
    try testing.expectEqual(Answer.active, d.takeAnswer().?);
    try expectInputsEql(&.{key(ch('e'), none, .release)}, feedAll(&d, "\x1b[101;1:3u", stale_ns + 70 * std.time.ns_per_ms, &buf));
}

test "a query unanswered for query_timeout_ns is answered inactive" {
    // The warning is expected.
    const lv = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = lv;
    var d: Decoder = .init(.legacy);
    d.querySent(0);
    try testing.expectEqual(@as(?i96, query_timeout_ns), d.deadline());
    try testing.expectEqual(null, d.expire(query_timeout_ns - 1));
    try testing.expectEqual(null, d.takeAnswer());
    try testing.expectEqual(null, d.expire(query_timeout_ns));
    try testing.expectEqual(Answer.inactive, d.takeAnswer().?);
    try testing.expectEqual(null, d.deadline());
}

test "legacy: a recheck finds the protocol; then kitty mode's rule applies" {
    var buf: [8]Input = undefined;
    var d: Decoder = .init(.legacy);
    d.querySent(0);
    // Keys still come through while it is out.
    try expectInputsEql(&.{key(ch('i'), none, .press)}, feedAll(&d, "i", 1, &buf));
    _ = feedAll(&d, "\x1b[?15u\x1b[?62c", 2, &buf);
    try testing.expectEqual(Answer.active, d.takeAnswer().?);
    d.switchToKitty();
    try expectInputsEql(&.{key(ch('e'), none, .press)}, feedAll(&d, "\x1b[101u", 3, &buf));
    try expectInputsEql(&.{}, feedAll(&d, "x", 4, &buf));
    try testing.expect(d.wantsQuery());
}

test "paste: discarded in both modes, split at any boundary; a key after it is decoded" {
    // Letters, Ctrl bytes (Ctrl-C and Ctrl-] included), ESC sequences and a
    // partial end marker inside the paste.
    const paste = "\x1b[200~hello q\r\x03\x1d\x1b[A\x1b[201\x1b[20x\x1b[112u" ++ paste_end;
    try expectDecode(.kitty, "\x1b[101u" ++ paste ++ "\x1b[113u", &.{
        key(ch('e'), none, .press),
        key(ch('q'), none, .press),
    });
    try expectDecode(.legacy, "e" ++ paste ++ "q", &.{
        key(ch('e'), none, .press),
        key(ch('q'), none, .press),
    });
    // Pasted plain bytes never count as legacy keys on the kitty path.
    var d: Decoder = .init(.kitty);
    d.query = null;
    var buf: [8]Input = undefined;
    try testing.expectEqual(0, (try collect(&d, paste, 1, &buf)).len);
    try testing.expect(!d.wantsQuery());
    try testing.expectEqual(@as(?Paste, null), d.paste);
}

test "paste: a start marker with no end is ended after 500 ms without a byte" {
    // The warning is expected.
    const lv = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = lv;
    const ms = std.time.ns_per_ms;
    var d: Decoder = .init(.kitty);
    d.query = null;
    var it = d.feed("\x1b[200~abc", 0);
    try testing.expectEqual(null, it.next());
    try testing.expectEqual(@as(?i96, 500 * ms), d.deadline());
    // Bytes less than 500 ms apart keep it going, Ctrl-C included.
    for (1..5) |i| {
        it = d.feed("x\x03", @as(i96, @intCast(i)) * 400 * ms);
        try testing.expectEqual(null, it.next());
    }
    try testing.expectEqual(@as(?i96, 2100 * ms), d.deadline());
    try testing.expectEqual(null, d.expire(2099 * ms));
    try testing.expect(d.paste != null);
    try testing.expectEqual(null, d.expire(2100 * ms));
    try testing.expectEqual(@as(?Paste, null), d.paste);
    try testing.expectEqual(@as(?i96, null), d.deadline());
    it = d.feed("\x1b[113u", 2200 * ms);
    try testing.expectEqual(key(ch('q'), none, .press), it.next().?);

    // Without `expire`, a byte arriving after the gap ends the paste and is
    // decoded itself.
    d = .init(.legacy);
    it = d.feed("\x1b[200~abc", 0);
    try testing.expectEqual(null, it.next());
    it = d.feed("q", 600 * ms);
    try testing.expectEqual(key(ch('q'), none, .press), it.next().?);
}
