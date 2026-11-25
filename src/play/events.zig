//! The play loop's one blocking call (D8): wait until a deadline, terminal
//! input or a resize, whichever comes first. No busy-spinning.
//!
//! POSIX: `poll` on stdin, a SIGWINCH self-pipe and the stdio containment
//! pipe, with the timeout floored to whole ms and the sub-ms rest slept with
//! `nanosleep`. Windows: `WaitForMultipleObjects` on the console input
//! handle and a high-resolution waitable timer; console `KEY_EVENT`s become
//! UTF-8 bytes for the key decoder, `WINDOW_BUFFER_SIZE_EVENT` a resize.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const caps = @import("../term/caps.zig");
const detect = @import("../term/detect.zig");
const session = @import("../term/session.zig");

const is_windows = builtin.os.tag == .windows;
const c = std.c;
const posix = std.posix;
const win = std.os.windows;

pub const Fd = session.Fd;

const Events = @This();

pub const Options = struct {
    /// Terminal input; null waits on time (and resize) only.
    in: ?Fd,
    /// The terminal output, for `winSize`.
    out: Fd,
    /// The stdio containment pipe's read end (POSIX), if any.
    stdio: ?Fd = null,
};

/// What ended a wait. Several fields can be set at once; all empty means
/// the deadline passed.
pub const Wake = struct {
    /// Bytes read from the terminal (valid until the next `wait`).
    input: []const u8 = "",
    /// The terminal input reached end of file (it went away).
    eof: bool = false,
    /// The window was resized; re-read `winSize`.
    resized: bool = false,
    /// The stdio pipe has data to drain.
    stdio_ready: bool = false,
};

io: Io,
opts: Options,
buf: [512]u8 = undefined,
/// Windows: the waitable timer and a pending high surrogate.
timer: if (is_windows) win.HANDLE else void = undefined,
high_surrogate: if (is_windows) u16 else void = if (is_windows) 0 else {},
/// POSIX: the SIGWINCH self-pipe's read end and the previous action.
winch_read: if (is_windows) void else c.fd_t = undefined,
prev_winch: if (is_windows) void else posix.Sigaction = undefined,

/// Sets up the resize wake (POSIX: a SIGWINCH handler and self-pipe;
/// Windows: the timer). One instance at a time; undo with `deinit`.
pub fn init(io: Io, opts: Options) !Events {
    var self: Events = .{ .io = io, .opts = opts };
    if (is_windows) {
        self.timer = CreateWaitableTimerExW(null, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS) orelse
            // Before Windows 10 1803 (below D2's minimum): ~15 ms precision.
            CreateWaitableTimerExW(null, null, 0, TIMER_ALL_ACCESS) orelse return error.TimerFailed;
    } else {
        if (winch_write >= 0) return error.AlreadyActive;
        var p: [2]c.fd_t = undefined;
        if (c.pipe(&p) != 0) return error.PipeFailed;
        for (p) |fd| {
            const fl = c.fcntl(fd, c.F.GETFL);
            _ = c.fcntl(fd, c.F.SETFL, fl | nonblock);
            _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        }
        self.winch_read = p[0];
        winch_write = p[1];
        const act: posix.Sigaction = .{
            .handler = .{ .handler = onWinch },
            .mask = posix.sigemptyset(),
            // Restart the core's interrupted syscalls (its stdio and file
            // I/O), which may not retry on EINTR. The wait still wakes:
            // `poll` is never restarted, and the self-pipe is readable.
            .flags = posix.SA.RESTART,
        };
        posix.sigaction(.WINCH, &act, &self.prev_winch);
    }
    return self;
}

pub fn deinit(self: *Events) void {
    if (is_windows) {
        win.CloseHandle(self.timer);
    } else {
        posix.sigaction(.WINCH, &self.prev_winch, null);
        const w = winch_write;
        winch_write = -1;
        _ = c.close(w);
        _ = c.close(self.winch_read);
    }
}

/// Waits until `deadline_ns` (on `Io.Clock.awake`; null: no deadline),
/// terminal input, a resize or stdio data, whichever comes first. Never
/// returns before the deadline when nothing else happened. EINTR counts as
/// a wake (with nothing set).
pub fn wait(self: *Events, deadline_ns: ?i96) !Wake {
    return if (is_windows) self.waitWindows(deadline_ns) else self.waitPosix(deadline_ns);
}

/// The current window size of the terminal output.
pub fn winSize(self: *const Events) ?caps.WinSize {
    return detect.winSize(self.opts.out);
}

fn now(self: *const Events) i96 {
    return Io.Clock.awake.now(self.io).nanoseconds;
}

// ---------------------------------------------------------------- POSIX

const nonblock: c_int = if (is_windows) 0 else @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));

/// The self-pipe's write end, for the handler. -1 when no instance exists.
var winch_write: c.fd_t = -1;

fn onWinch(_: posix.SIG) callconv(.c) void {
    const saved_errno = c._errno().*;
    defer c._errno().* = saved_errno;
    const fd = winch_write;
    // Full pipe: a resize is already pending, which is all that matters.
    if (fd >= 0) _ = c.write(fd, "w", 1);
}

fn waitPosix(self: *Events, deadline_ns: ?i96) !Wake {
    var fds: [3]c.pollfd = undefined;
    var n: usize = 0;
    fds[n] = .{ .fd = self.winch_read, .events = c.POLL.IN, .revents = 0 };
    n += 1;
    const in_i = n;
    if (self.opts.in) |fd| {
        fds[n] = .{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
        n += 1;
    }
    const stdio_i = n;
    if (self.opts.stdio) |fd| {
        fds[n] = .{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
        n += 1;
    }

    const timeout_ms: c_int = if (deadline_ns) |d| blk: {
        const left = d - self.now();
        if (left <= 0) break :blk 0;
        break :blk @intCast(@min(@divFloor(left, std.time.ns_per_ms), std.math.maxInt(c_int)));
    } else -1;

    const ready = c.poll(&fds, @intCast(n), timeout_ms);
    if (ready < 0) {
        if (c._errno().* == @backingInt(c.E.INTR)) return .{};
        return error.PollFailed;
    }
    if (ready == 0) {
        // Timed out: sleep off the sub-ms (or early-wake) remainder.
        if (deadline_ns) |d| {
            const left = d - self.now();
            if (left > 0) {
                const ts: c.timespec = .{
                    .sec = @intCast(@divFloor(left, std.time.ns_per_s)),
                    .nsec = @intCast(@mod(left, std.time.ns_per_s)),
                };
                _ = c.nanosleep(&ts, null);
            }
        }
        return .{};
    }

    var wake: Wake = .{};
    if (fds[0].revents != 0) {
        var sink: [64]u8 = undefined;
        while (c.read(self.winch_read, &sink, sink.len) > 0) {}
        wake.resized = true;
    }
    if (self.opts.in != null and fds[in_i].revents & c.POLL.NVAL != 0) return error.InputNotPollable;
    if (self.opts.in != null and fds[in_i].revents != 0) {
        const r = c.read(self.opts.in.?, &self.buf, self.buf.len);
        if (r > 0) {
            wake.input = self.buf[0..@intCast(r)];
        } else if (r == 0) {
            wake.eof = true;
        } else if (c._errno().* != @backingInt(c.E.INTR) and c._errno().* != @backingInt(c.E.AGAIN)) {
            return error.ReadFailed;
        }
    }
    if (self.opts.stdio != null and fds[stdio_i].revents != 0) wake.stdio_ready = true;
    return wake;
}

// ---------------------------------------------------------------- Windows

const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: win.DWORD = 0x00000002;
const TIMER_ALL_ACCESS: win.DWORD = 0x001F0003;
const WAIT_OBJECT_0: win.DWORD = 0;
const WAIT_TIMEOUT: win.DWORD = 0x102;
const INFINITE: win.DWORD = 0xFFFFFFFF;
const KEY_EVENT: u16 = 0x0001;
const WINDOW_BUFFER_SIZE_EVENT: u16 = 0x0004;

const KeyEventRecord = extern struct {
    bKeyDown: win.BOOL,
    wRepeatCount: u16,
    wVirtualKeyCode: u16,
    wVirtualScanCode: u16,
    UnicodeChar: u16,
    dwControlKeyState: win.DWORD,
};

const InputRecord = extern struct {
    EventType: u16,
    Event: extern union {
        key: KeyEventRecord,
        /// Mouse, window size, menu and focus records; only the type matters.
        other: [16]u8,
    },
};

comptime {
    std.debug.assert(@sizeOf(InputRecord) == 20);
}

extern "kernel32" fn CreateWaitableTimerExW(attrs: ?*anyopaque, name: ?[*:0]const u16, flags: win.DWORD, access: win.DWORD) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn SetWaitableTimer(timer: win.HANDLE, due: *const i64, period: i32, completion: ?*anyopaque, arg: ?*anyopaque, resume_: win.BOOL) callconv(.winapi) win.BOOL;
extern "kernel32" fn CancelWaitableTimer(timer: win.HANDLE) callconv(.winapi) win.BOOL;
extern "kernel32" fn WaitForMultipleObjects(count: win.DWORD, handles: [*]const win.HANDLE, wait_all: win.BOOL, ms: win.DWORD) callconv(.winapi) win.DWORD;
extern "kernel32" fn GetNumberOfConsoleInputEvents(in: win.HANDLE, n: *win.DWORD) callconv(.winapi) win.BOOL;
extern "kernel32" fn ReadConsoleInputW(in: win.HANDLE, records: [*]InputRecord, len: win.DWORD, read: *win.DWORD) callconv(.winapi) win.BOOL;

fn waitWindows(self: *Events, deadline_ns: ?i96) !Wake {
    var handles: [2]win.HANDLE = undefined;
    var n: win.DWORD = 0;
    if (self.opts.in) |h| {
        handles[n] = h;
        n += 1;
    }
    var ms: win.DWORD = INFINITE;
    if (deadline_ns) |d| {
        const left = d - self.now();
        if (left <= 0) {
            ms = 0;
        } else {
            // Relative due time, in 100 ns units (negative = relative).
            const due: i64 = -@as(i64, @intCast(@max(1, @divFloor(left, 100))));
            if (SetWaitableTimer(self.timer, &due, 0, null, null, .FALSE) == .FALSE) return error.TimerFailed;
            handles[n] = self.timer;
            n += 1;
        }
    }
    if (n == 0) return if (ms == 0) .{} else error.NothingToWaitOn;
    const r = WaitForMultipleObjects(n, &handles, .FALSE, ms);
    if (deadline_ns != null) _ = CancelWaitableTimer(self.timer);
    if (r == WAIT_TIMEOUT) return .{};
    if (r >= n) return error.WaitFailed;
    if (self.opts.in == null or r != WAIT_OBJECT_0) return .{};
    return self.readConsole(self.opts.in.?);
}

/// Reads exactly the queued events (`ReadConsoleInputW` blocks on an empty
/// queue) and turns them into bytes and a resize flag.
fn readConsole(self: *Events, in: win.HANDLE) !Wake {
    var wake: Wake = .{};
    var queued: win.DWORD = 0;
    if (GetNumberOfConsoleInputEvents(in, &queued) == .FALSE) return error.ReadFailed;
    var records: [64]InputRecord = undefined;
    var len: usize = 0;
    while (queued > 0) {
        var got: win.DWORD = 0;
        const want: win.DWORD = @min(queued, records.len);
        if (ReadConsoleInputW(in, &records, want, &got) == .FALSE) return error.ReadFailed;
        queued -= @min(queued, got);
        for (records[0..got]) |rec| switch (rec.EventType) {
            WINDOW_BUFFER_SIZE_EVENT => wake.resized = true,
            KEY_EVENT => {
                const k = rec.Event.key;
                if (k.bKeyDown == .FALSE or k.UnicodeChar == 0) continue;
                var reps = @max(k.wRepeatCount, 1);
                while (reps > 0) : (reps -= 1) len = self.appendUtf16(len, k.UnicodeChar);
            },
            else => {},
        };
        if (got == 0) break;
    }
    wake.input = self.buf[0..len];
    return wake;
}

/// Appends one UTF-16 unit as UTF-8 at `len` (pairing surrogates across
/// records); drops it when the buffer is full. Returns the new length.
fn appendUtf16(self: *Events, len: usize, unit: u16) usize {
    if (is_windows) {
        var cp: u21 = unit;
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.high_surrogate = unit;
            return len;
        }
        if (std.unicode.utf16IsLowSurrogate(unit)) {
            const hi = self.high_surrogate;
            self.high_surrogate = 0;
            if (hi == 0) return len;
            cp = std.unicode.utf16DecodeSurrogatePair(&.{ hi, unit }) catch return len;
        }
        if (len + 4 > self.buf.len) return len;
        return len + (std.unicode.utf8Encode(cp, self.buf[len..]) catch 0);
    }
    unreachable;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "deadline wakes are accurate and don't spin" {
    var ev: Events = try .init(testing.io, .{ .in = null, .out = undefined });
    defer ev.deinit();
    var errs: [50]i96 = undefined;
    for (&errs) |*e| {
        const deadline = ev.now() + 5 * std.time.ns_per_ms;
        while (true) {
            const w = try ev.wait(deadline);
            if (!w.resized) break;
        }
        e.* = ev.now() - deadline;
        // Never early.
        try testing.expect(e.* >= 0);
    }
    std.mem.sortUnstable(i96, &errs, {}, std.sort.asc(i96));
    // Loose bound so a loaded CI runner doesn't flake.
    try testing.expect(errs[errs.len / 2] < 2 * std.time.ns_per_ms);
}

test "a past deadline returns at once" {
    var ev: Events = try .init(testing.io, .{ .in = null, .out = undefined });
    defer ev.deinit();
    const t0 = ev.now();
    _ = try ev.wait(t0 - 1);
    try testing.expect(ev.now() - t0 < 50 * std.time.ns_per_ms);
}

test "SIGWINCH wakes a wait with no deadline" {
    if (is_windows) return error.SkipZigTest;
    var ev: Events = try .init(testing.io, .{ .in = null, .out = undefined });
    defer ev.deinit();
    _ = c.raise(.WINCH);
    _ = c.raise(.WINCH);
    const w = try ev.wait(null);
    try testing.expect(w.resized);
    // Coalesced: both signals drained in one wake.
    const again = try ev.wait(ev.now());
    try testing.expect(!again.resized);
}

test "input, stdio readiness and end of input" {
    if (is_windows) return error.SkipZigTest;
    var in: [2]c.fd_t = undefined;
    var io_pipe: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&in));
    try testing.expectEqual(@as(c_int, 0), c.pipe(&io_pipe));
    defer _ = c.close(in[0]);
    defer _ = c.close(io_pipe[0]);
    defer _ = c.close(io_pipe[1]);
    var ev: Events = try .init(testing.io, .{ .in = in[0], .out = undefined, .stdio = io_pipe[0] });
    defer ev.deinit();

    _ = c.write(in[1], "ab", 2);
    const w = try ev.wait(null);
    try testing.expectEqualStrings("ab", w.input);
    try testing.expect(!w.stdio_ready and !w.eof);

    _ = c.write(io_pipe[1], "x\n", 2);
    const s = try ev.wait(null);
    try testing.expect(s.stdio_ready);
    try testing.expectEqualStrings("", s.input);
    var sink: [8]u8 = undefined;
    _ = c.read(io_pipe[0], &sink, sink.len);

    _ = c.close(in[1]);
    const e = try ev.wait(null);
    try testing.expect(e.eof);
}

test "Windows: surrogate pairs become one UTF-8 sequence" {
    if (!is_windows) return error.SkipZigTest;
    var ev: Events = try .init(testing.io, .{ .in = null, .out = undefined });
    defer ev.deinit();
    var len = ev.appendUtf16(0, 'q');
    len = ev.appendUtf16(len, 0xD83D);
    len = ev.appendUtf16(len, 0xDE00);
    try testing.expectEqualStrings("q\u{1F600}", ev.buf[0..len]);
}
