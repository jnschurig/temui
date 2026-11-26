//! Drains the stdio containment pipe (`session.stdioPipe`) into the log,
//! one `core: stdio: <line>` entry per line, so a core's `printf` is kept
//! for diagnosis without reaching the screen (D13). POSIX only.

const std = @import("std");
const c = std.c;

/// Longest line kept whole; longer ones are split into pieces this long.
pub const max_line = 512;

pub const Drain = struct {
    fd: c.fd_t,
    buf: [max_line]u8 = undefined,
    len: usize = 0,

    /// Reads everything available (the fd is non-blocking) and hands each
    /// complete line to `sink.line`. A partial line is kept for the next
    /// call. Stops at EOF, EAGAIN or an error.
    pub fn drain(self: *Drain, sink: anytype) void {
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = c.read(self.fd, &chunk, chunk.len);
            if (n < 0 and c._errno().* == @backingInt(c.E.INTR)) continue;
            if (n <= 0) return;
            self.feed(chunk[0..@intCast(n)], sink);
        }
    }

    /// `drain`, then emits a trailing partial line. Call at exit, after
    /// `session.flushContained`.
    pub fn finish(self: *Drain, sink: anytype) void {
        self.drain(sink);
        if (self.len > 0) self.emit(sink);
    }

    fn feed(self: *Drain, bytes: []const u8, sink: anytype) void {
        for (bytes) |b| {
            if (b == '\n') {
                self.emit(sink);
                continue;
            }
            if (self.len == max_line) self.emit(sink);
            self.buf[self.len] = b;
            self.len += 1;
        }
    }

    fn emit(self: *Drain, sink: anytype) void {
        const line = std.mem.trimEnd(u8, self.buf[0..self.len], "\r");
        self.len = 0;
        sink.line(line);
    }
};

/// The production sink: one info entry per line, scope `core`.
pub const LogSink = struct {
    pub fn line(_: LogSink, text: []const u8) void {
        std.log.scoped(.core).info("stdio: {s}", .{text});
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const builtin = @import("builtin");

const Collect = struct {
    lines: std.ArrayList([]u8) = .empty,

    fn line(self: *Collect, text: []const u8) void {
        self.lines.append(testing.allocator, testing.allocator.dupe(u8, text) catch @panic("oom")) catch @panic("oom");
    }

    fn deinit(self: *Collect) void {
        for (self.lines.items) |l| testing.allocator.free(l);
        self.lines.deinit(testing.allocator);
    }
};

test "feed splits lines, keeps partials, strips CR, splits overlong lines" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var d: Drain = .{ .fd = -1 };
    var sink: Collect = .{};
    defer sink.deinit();
    d.feed("one\ntw", &sink);
    try testing.expectEqual(@as(usize, 1), sink.lines.items.len);
    d.feed("o\r\n\nthree", &sink);
    try testing.expectEqual(@as(usize, 3), sink.lines.items.len);
    try testing.expectEqualStrings("one", sink.lines.items[0]);
    try testing.expectEqualStrings("two", sink.lines.items[1]);
    try testing.expectEqualStrings("", sink.lines.items[2]);
    try testing.expectEqual(@as(usize, 5), d.len);

    const long = @as([max_line + 10]u8, @splat('x')) ++ "\n";
    d.len = 0;
    d.feed(long, &sink);
    try testing.expectEqual(@as(usize, 5), sink.lines.items.len);
    try testing.expectEqual(@as(usize, max_line), sink.lines.items[3].len);
    try testing.expectEqual(@as(usize, 10), sink.lines.items[4].len);
}

test "drain reads a non-blocking pipe; finish flushes the partial line" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var p: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&p));
    defer _ = c.close(p[0]);
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    _ = c.fcntl(p[0], c.F.SETFL, c.fcntl(p[0], c.F.GETFL) | nonblock);

    var d: Drain = .{ .fd = p[0] };
    var sink: Collect = .{};
    defer sink.deinit();
    d.drain(&sink); // empty: returns at once (EAGAIN)
    try testing.expectEqual(@as(usize, 0), sink.lines.items.len);

    _ = c.write(p[1], "hello\nwor", 9);
    d.drain(&sink);
    try testing.expectEqual(@as(usize, 1), sink.lines.items.len);
    _ = c.close(p[1]);
    d.finish(&sink);
    try testing.expectEqual(@as(usize, 2), sink.lines.items.len);
    try testing.expectEqualStrings("wor", sink.lines.items[1]);
}
