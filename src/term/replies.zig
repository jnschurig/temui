//! Incremental parser for terminal replies on stdin. Feed one byte at a time;
//! a completed sequence is returned as an `Event` whose slices point into the
//! parser and stay valid until the next `feed`. Nothing is dropped silently:
//! bytes outside a sequence come back as `.byte` events and unrecognised
//! sequences as `.other`, so callers can log them (or act on `q`).
//! Ported from `spikes/termbench/replies.zig`.

const std = @import("std");

pub const Kind = enum {
    /// `CSI 0 n` — Device Status Report "OK"; our per-frame ack.
    dsr_ok,
    /// `CSI ? … c` — Primary Device Attributes.
    da1,
    /// `APC G … ST` — kitty graphics reply; `body` is after the `G`.
    kitty_graphics,
    /// `CSI ? flags u` — kitty keyboard protocol flags.
    kitty_keyboard,
    /// `DCS 1 $ r … ST` (valid) or `DCS 0 $ r … ST` (invalid); `body` after `$r`.
    decrqss,
    /// `CSI 4 ; h ; w t` — text area size in pixels.
    text_area_px,
    /// `CSI 6 ; h ; w t` — cell size in pixels.
    cell_px,
    /// `DCS > | text ST` — XTVERSION; `body` is the text.
    xtversion,
    /// A bare 0x03 byte (Ctrl-C in raw mode).
    ctrl_c,
    /// Any other byte outside an escape sequence (typed input); `raw` and
    /// `body` are that one byte.
    byte,
    /// Any other complete sequence, including two-byte escapes.
    other,
};

pub const Event = struct {
    kind: Kind,
    /// The whole sequence as received.
    raw: []const u8,
    /// The interesting part (see `Kind`).
    body: []const u8,

    pub fn kittyOk(e: Event) bool {
        const semi = std.mem.indexOfScalar(u8, e.body, ';') orelse return false;
        return std.mem.eql(u8, e.body[semi + 1 ..], "OK");
    }

    pub fn decrqssValid(e: Event) bool {
        return e.raw.len > 2 and e.raw[2] == '1';
    }

    /// For `text_area_px` / `cell_px`: {height, width}.
    pub fn dims(e: Event) ?[2]u32 {
        var it = std.mem.splitScalar(u8, e.body, ';');
        _ = it.next() orelse return null;
        const h = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const w = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        return .{ h, w };
    }

    pub fn keyboardFlags(e: Event) ?u32 {
        return std.fmt.parseInt(u32, e.body, 10) catch null;
    }
};

const State = enum { ground, esc, csi, ss3, string, string_esc };

pub const Parser = struct {
    state: State = .ground,
    buf: [512]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,

    /// Whether the parser holds exactly one ESC and nothing after it: a
    /// typed Esc, or the first byte of a sequence still on its way.
    pub fn pendingLoneEsc(p: *const Parser) bool {
        return p.state == .esc and p.len == 1;
    }

    pub fn feed(p: *Parser, b: u8) ?Event {
        switch (p.state) {
            .ground => {
                if (b == 0x1b) {
                    p.start(b);
                    p.state = .esc;
                    return null;
                }
                if (b == 0x03) return .{ .kind = .ctrl_c, .raw = "\x03", .body = "" };
                p.start(b);
                return .{ .kind = .byte, .raw = p.buf[0..1], .body = p.buf[0..1] };
            },
            .esc => {
                p.push(b);
                switch (b) {
                    '[' => p.state = .csi,
                    'O' => p.state = .ss3, // SS3: one more byte (F1-F4, keypad)
                    'P', '_', ']', 'X', '^' => p.state = .string,
                    0x1b => p.start(b), // stay in .esc
                    else => { // two-byte escape
                        p.state = .ground;
                        return .{ .kind = .other, .raw = p.buf[0..p.len], .body = p.buf[1..p.len] };
                    },
                }
                return null;
            },
            .csi => {
                if (b == 0x1b) { // aborted; restart
                    p.start(b);
                    p.state = .esc;
                    return null;
                }
                p.push(b);
                if (b >= 0x40 and b <= 0x7e) {
                    p.state = .ground;
                    return p.classifyCsi();
                }
                return null;
            },
            .ss3 => {
                if (b == 0x1b) { // aborted; restart
                    p.start(b);
                    p.state = .esc;
                    return null;
                }
                p.push(b);
                p.state = .ground;
                return .{ .kind = .other, .raw = p.buf[0..p.len], .body = p.buf[1..p.len] };
            },
            .string => {
                if (b == 0x1b) {
                    p.state = .string_esc;
                } else if (b == 0x07) { // BEL terminates OSC (and some APC)
                    p.state = .ground;
                    return p.classifyString(p.len);
                } else {
                    p.push(b);
                }
                return null;
            },
            .string_esc => {
                if (b == '\\') {
                    const content_end = p.len;
                    p.push(0x1b);
                    p.push('\\');
                    p.state = .ground;
                    return p.classifyString(content_end);
                }
                // ESC not followed by '\': string aborted, new escape begins.
                p.start(0x1b);
                p.state = .esc;
                return p.feed(b);
            },
        }
    }

    fn start(p: *Parser, b: u8) void {
        p.len = 0;
        p.overflow = false;
        p.push(b);
    }

    fn push(p: *Parser, b: u8) void {
        if (p.len < p.buf.len) {
            p.buf[p.len] = b;
            p.len += 1;
        } else p.overflow = true;
    }

    fn classifyCsi(p: *Parser) Event {
        const raw = p.buf[0..p.len];
        const params = raw[2 .. raw.len - 1];
        const final = raw[raw.len - 1];
        var e: Event = .{ .kind = .other, .raw = raw, .body = params };
        if (p.overflow) return e;
        if (final == 'n' and std.mem.eql(u8, params, "0")) {
            e.kind = .dsr_ok;
        } else if (final == 'c' and params.len > 0 and params[0] == '?') {
            e.kind = .da1;
            e.body = params[1..];
        } else if (final == 'u' and params.len > 0 and params[0] == '?') {
            e.kind = .kitty_keyboard;
            e.body = params[1..];
        } else if (final == 't' and std.mem.startsWith(u8, params, "4;")) {
            e.kind = .text_area_px;
        } else if (final == 't' and std.mem.startsWith(u8, params, "6;")) {
            e.kind = .cell_px;
        }
        return e;
    }

    /// `content_end` is the index where the string's content ends (before ST).
    fn classifyString(p: *Parser, content_end: usize) Event {
        const raw = p.buf[0..p.len];
        const content = p.buf[2..content_end];
        var e: Event = .{ .kind = .other, .raw = raw, .body = content };
        if (p.overflow) return e;
        const intro = raw[1];
        if (intro == '_' and content.len > 0 and content[0] == 'G') {
            e.kind = .kitty_graphics;
            e.body = content[1..];
        } else if (intro == 'P' and content.len >= 3 and (content[0] == '0' or content[0] == '1') and content[1] == '$' and content[2] == 'r') {
            e.kind = .decrqss;
            e.body = content[3..];
        } else if (intro == 'P' and content.len >= 2 and content[0] == '>' and content[1] == '|') {
            e.kind = .xtversion;
            e.body = content[2..];
        }
        return e;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Expect = struct { kind: Kind, body: []const u8 };

/// Feeds `input` in chunks of `chunk` bytes and checks the events in order.
fn expectEvents(input: []const u8, chunk: usize, want: []const Expect) !void {
    var p: Parser = .{};
    var got: usize = 0;
    var i: usize = 0;
    while (i < input.len) : (i += chunk) {
        for (input[i..@min(i + chunk, input.len)]) |b| {
            if (p.feed(b)) |e| {
                try testing.expect(got < want.len);
                try testing.expectEqual(want[got].kind, e.kind);
                try testing.expectEqualStrings(want[got].body, e.body);
                got += 1;
            }
        }
    }
    try testing.expectEqual(want.len, got);
}

const all_replies =
    "\x1b[0n" ++
    "\x1b[?62;22;52c" ++
    "\x1b_Gi=31;OK\x1b\\" ++
    "\x1b_Gi=1;ENOENT:no such image\x1b\\" ++
    "\x1b[?15u" ++
    "\x1bP1$r48:2::1:2:3m\x1b\\" ++
    "\x1bP0$r\x1b\\" ++
    "\x1b[4;800;1200t" ++
    "\x1b[6;20;10t" ++
    "\x1bP>|ghostty 1.2.3\x1b\\" ++
    "\x03" ++
    "q" ++
    "\x1b[12;40R";

const all_expected = [_]Expect{
    .{ .kind = .dsr_ok, .body = "0" },
    .{ .kind = .da1, .body = "62;22;52" },
    .{ .kind = .kitty_graphics, .body = "i=31;OK" },
    .{ .kind = .kitty_graphics, .body = "i=1;ENOENT:no such image" },
    .{ .kind = .kitty_keyboard, .body = "15" },
    .{ .kind = .decrqss, .body = "48:2::1:2:3m" },
    .{ .kind = .decrqss, .body = "" },
    .{ .kind = .text_area_px, .body = "4;800;1200" },
    .{ .kind = .cell_px, .body = "6;20;10" },
    .{ .kind = .xtversion, .body = "ghostty 1.2.3" },
    .{ .kind = .ctrl_c, .body = "" },
    .{ .kind = .byte, .body = "q" },
    .{ .kind = .other, .body = "12;40" },
};

test "every reply type, split at every chunk size" {
    var chunk: usize = 1;
    while (chunk <= all_replies.len) : (chunk += 1) {
        try expectEvents(all_replies, chunk, &all_expected);
    }
}

test "stray bytes and two-byte escapes surface as events" {
    try expectEvents("ab\x1b[0nz\x1bM\x1bOP\x1b[?1;2c\r", 1, &.{
        .{ .kind = .byte, .body = "a" },
        .{ .kind = .byte, .body = "b" },
        .{ .kind = .dsr_ok, .body = "0" },
        .{ .kind = .byte, .body = "z" },
        .{ .kind = .other, .body = "M" },
        .{ .kind = .other, .body = "OP" },
        .{ .kind = .da1, .body = "1;2" },
        .{ .kind = .byte, .body = "\r" },
    });
}

test "aborted sequences restart cleanly" {
    try expectEvents("\x1b[12\x1b[0n\x1b_Gi=1\x1b[0n", 1, &.{
        .{ .kind = .dsr_ok, .body = "0" },
        .{ .kind = .dsr_ok, .body = "0" },
    });
}

test "pendingLoneEsc" {
    var p: Parser = .{};
    try testing.expect(!p.pendingLoneEsc());
    _ = p.feed(0x1b);
    try testing.expect(p.pendingLoneEsc());
    _ = p.feed('[');
    try testing.expect(!p.pendingLoneEsc());
    _ = p.feed('A');
    try testing.expect(!p.pendingLoneEsc());
    _ = p.feed(0x1b);
    _ = p.feed(0x1b); // ESC ESC: the second restarts, still one ESC held
    try testing.expect(p.pendingLoneEsc());
}

test "event helpers" {
    var p: Parser = .{};
    var last: ?Event = null;
    for ("\x1b[6;20;10t") |b| last = p.feed(b) orelse last;
    try testing.expectEqual([2]u32{ 20, 10 }, last.?.dims().?);

    p = .{};
    for ("\x1b_Gi=31;OK\x1b\\") |b| last = p.feed(b) orelse last;
    try testing.expect(last.?.kittyOk());
    p = .{};
    for ("\x1b_Gi=31;EINVAL:bad\x1b\\") |b| last = p.feed(b) orelse last;
    try testing.expect(!last.?.kittyOk());

    p = .{};
    for ("\x1bP1$rm\x1b\\") |b| last = p.feed(b) orelse last;
    try testing.expect(last.?.decrqssValid());
    p = .{};
    for ("\x1b[?15u") |b| last = p.feed(b) orelse last;
    try testing.expectEqual(@as(u32, 15), last.?.keyboardFlags().?);
}
