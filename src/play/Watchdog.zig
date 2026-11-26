//! The play loop's watchdog thread (item 06, D15): quits on two Ctrl-C
//! presses when the loop is stuck, e.g. a core spinning in `retro_run` or a
//! terminal write blocked because the terminal stopped reading.
//!
//! The loop marks itself in its event wait (`Events.Handback`, from
//! `handback`). Time inside the wait never counts. Once the loop has been
//! outside it for `stale_ns`, and only then, the thread reads terminal
//! input itself, under the lock the loop takes to enter its wait, so the
//! two never read at once. Everything it reads goes into a handback buffer
//! the loop drains before its own next read, so no key is lost or split if
//! the loop recovers. On the second Ctrl-C of one stuck stretch it restores
//! the terminal (best effort), says so on stderr and exits with 130 at once:
//! no summary, no atexit handlers, no C stdio flush and no core unload, since
//! the stuck core may hold any of their locks.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const session = @import("../term/session.zig");
const key_decoder = @import("../term/key_decoder.zig");
const console_keys = @import("../term/console_keys.zig");
const Events = @import("events.zig");

const is_windows = builtin.os.tag == .windows;
const c = std.c;
const win = std.os.windows;

const Watchdog = @This();

pub const Raw = Events.Raw;
/// Raw input held for the loop: 512 bytes (POSIX) or 64 console records.
pub const handback_len = if (is_windows) 64 else 512;

/// What the thread does on the second Ctrl-C. Production: `quitNow`, which
/// doesn't return. Tests record the call instead.
pub const Exit = struct {
    ctx: ?*anyopaque = null,
    exitFn: *const fn (ctx: ?*anyopaque) void = quitNow,
};

pub const Options = struct {
    /// Terminal input (`session.inFd()`).
    in: Events.Fd,
    /// How long the loop must be outside its wait to count as stuck.
    stale_ns: i64 = std.time.ns_per_s,
    /// How often the thread checks, and how long one input read waits.
    tick_ms: u32 = 100,
    exit: Exit = .{},
};

io: Io,
opts: Options,
/// When the loop left its wait, on `Io.Clock.awake`; 0 while in it (and
/// before `start`).
busy_since_ns: std.atomic.Value(i64) = .init(0),
stop_flag: std.atomic.Value(bool) = .init(false),
/// Guards input reads, `held` and `scanner`.
mutex: Io.Mutex = .init,
held: [handback_len]Raw = undefined,
held_len: usize = 0,
scanner: CtrlCScanner = .{},
thread: ?std.Thread = null,

pub fn init(io: Io, opts: Options) Watchdog {
    return .{ .io = io, .opts = opts };
}

/// Arms the watchdog: the loop counts as busy from now (it is running, not
/// waiting) and the thread starts. Call once the loop has started, so
/// detection and core loading never count.
pub fn start(self: *Watchdog) !void {
    std.debug.assert(self.thread == null);
    self.busy_since_ns.store(self.now(), .release);
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

/// Stops and joins the thread (within about two ticks). Call before the
/// session is restored.
pub fn stop(self: *Watchdog) void {
    const t = self.thread orelse return;
    self.stop_flag.store(true, .release);
    t.join();
    self.thread = null;
}

/// The hook `Events.wait` calls around its blocking call.
pub fn handback(self: *Watchdog) Events.Handback {
    return .{ .ctx = self, .enterFn = enterWait, .leaveFn = leaveWait };
}

/// Marks the loop as in its wait and moves the held input into `out`. A
/// watchdog read in progress finishes first (the lock), so its bytes are
/// included. The Ctrl-C count starts over: the loop recovered.
fn enterWait(ctx: *anyopaque, out: []Raw) usize {
    const self: *Watchdog = @ptrCast(@alignCast(ctx));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.busy_since_ns.store(0, .release);
    self.scanner = .{};
    const n = @min(out.len, self.held_len);
    @memcpy(out[0..n], self.held[0..n]);
    std.mem.copyForwards(Raw, self.held[0 .. self.held_len - n], self.held[n..self.held_len]);
    self.held_len -= n;
    return n;
}

/// Marks the loop as busy again. No lock: the watchdog re-checks under the
/// lock, and a fresh timestamp can't make it stale.
fn leaveWait(ctx: *anyopaque) void {
    const self: *Watchdog = @ptrCast(@alignCast(ctx));
    self.busy_since_ns.store(self.now(), .release);
}

/// Whether a loop that left its wait at `busy_since_ns` (0: in the wait)
/// counts as stuck at `now_ns`.
pub fn isStale(busy_since_ns: i64, now_ns: i64, stale_ns: i64) bool {
    return busy_since_ns != 0 and now_ns - busy_since_ns >= stale_ns;
}

fn now(self: *const Watchdog) i64 {
    // Never 0, which means "in the wait".
    return @max(1, @as(i64, @intCast(Io.Clock.awake.now(self.io).nanoseconds)));
}

fn stale(self: *const Watchdog) bool {
    return isStale(self.busy_since_ns.load(.acquire), self.now(), self.opts.stale_ns);
}

fn run(self: *Watchdog) void {
    const tick: Io.Duration = .fromMilliseconds(self.opts.tick_ms);
    while (!self.stop_flag.load(.acquire)) {
        // While stuck, the read's own timeout paces the loop.
        if (!self.stale()) {
            self.io.sleep(tick, .awake) catch return;
            continue;
        }
        if (self.checkOnce()) {
            self.opts.exit.exitFn(self.opts.exit.ctx);
            return;
        }
    }
}

/// One locked read while the loop is stuck. Returns true on the second
/// Ctrl-C.
fn checkOnce(self: *Watchdog) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    // The loop may have entered its wait while we took the lock.
    if (!self.stale()) return false;
    var scratch: [handback_len]Raw = undefined;
    const got = self.readInput(&scratch);
    // A full buffer still gets scanned, but the overflow is dropped.
    const keep = @min(got.len, self.held.len - self.held_len);
    @memcpy(self.held[self.held_len..][0..keep], got[0..keep]);
    self.held_len += keep;
    return self.scanner.feed(got) >= 2;
}

/// Waits up to a tick for input and reads what is there.
fn readInput(self: *Watchdog, buf: []Raw) []Raw {
    if (is_windows) {
        if (WaitForSingleObject(self.opts.in, self.opts.tick_ms) != WAIT_OBJECT_0) return buf[0..0];
        var queued: win.DWORD = 0;
        if (GetNumberOfConsoleInputEvents(self.opts.in, &queued) == .FALSE or queued == 0) return buf[0..0];
        var got: win.DWORD = 0;
        const want: win.DWORD = @intCast(@min(queued, buf.len));
        if (ReadConsoleInputW(self.opts.in, buf.ptr, want, &got) == .FALSE) return buf[0..0];
        return buf[0..got];
    }
    var fds = [_]c.pollfd{.{ .fd = self.opts.in, .events = c.POLL.IN, .revents = 0 }};
    if (c.poll(&fds, 1, @intCast(self.opts.tick_ms)) != 1) return buf[0..0];
    if (fds[0].revents & c.POLL.IN == 0) {
        // Hang-up or error with nothing to read: the loop sees it too.
        // Don't spin on it.
        self.io.sleep(.fromMilliseconds(self.opts.tick_ms), .awake) catch {};
        return buf[0..0];
    }
    const r = c.read(self.opts.in, buf.ptr, buf.len);
    return if (r > 0) buf[0..@intCast(r)] else buf[0..0];
}

/// Restores the terminal (best effort), tells stderr and exits with 130,
/// skipping every exit-time hook. Doesn't return.
fn quitNow(_: ?*anyopaque) void {
    session.restoreBestEffort();
    const msg = "temui: not responding; quit\n";
    if (is_windows) {
        if (GetStdHandle(STD_ERROR_HANDLE)) |h| _ = WriteFile(h, msg, msg.len, null, null);
        // Not `ExitProcess`, which runs DLL detach code (the stuck core's
        // too) and can deadlock.
        _ = TerminateProcess(GetCurrentProcess(), 130);
        unreachable;
    }
    _ = c.write(2, msg, msg.len);
    c._exit(130);
}

/// Counts Ctrl-C presses in raw input, across reads. POSIX: `0x03`, and the
/// kitty forms `CSI 99;5u` / `CSI 99;5:1u` (via the kitty decoder, so lock
/// modifiers and the base-layout key are handled as in the loop); repeats
/// and releases don't count. Windows: a key-down `KEY_EVENT` for VK `C`
/// with Ctrl.
pub const CtrlCScanner = struct {
    decoder: key_decoder.Decoder = .init(.kitty),
    count: usize = 0,

    /// Returns the presses seen so far, including this call's.
    pub fn feed(s: *CtrlCScanner, raw: []const Raw) usize {
        if (is_windows) {
            for (raw) |r| if (isCtrlCRecord(r)) {
                s.count += 1;
            };
        } else {
            // Time doesn't matter here: a lone ESC is never Ctrl-C.
            var it = s.decoder.feed(raw, 0);
            while (it.next()) |in| switch (in) {
                .key => |e| if (e.kind == .press and e.isCtrlC()) {
                    s.count += 1;
                },
                else => {},
            };
        }
        return s.count;
    }
};

pub fn isCtrlCRecord(r: console_keys.InputRecord) bool {
    if (r.EventType != console_keys.KEY_EVENT) return false;
    const k = r.Event.key;
    return k.bKeyDown != 0 and k.wVirtualKeyCode == 'C' and
        k.dwControlKeyState & (console_keys.LEFT_CTRL_PRESSED | console_keys.RIGHT_CTRL_PRESSED) != 0;
}

const WAIT_OBJECT_0: win.DWORD = 0;
const STD_ERROR_HANDLE: win.DWORD = @bitCast(@as(i32, -12));
extern "kernel32" fn WaitForSingleObject(h: win.HANDLE, ms: win.DWORD) callconv(.winapi) win.DWORD;
extern "kernel32" fn GetNumberOfConsoleInputEvents(in: win.HANDLE, n: *win.DWORD) callconv(.winapi) win.BOOL;
extern "kernel32" fn ReadConsoleInputW(in: win.HANDLE, records: [*]console_keys.InputRecord, len: win.DWORD, read: *win.DWORD) callconv(.winapi) win.BOOL;
extern "kernel32" fn GetStdHandle(n: win.DWORD) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn WriteFile(h: win.HANDLE, buf: [*]const u8, len: win.DWORD, written: ?*win.DWORD, overlapped: ?*anyopaque) callconv(.winapi) win.BOOL;
extern "kernel32" fn TerminateProcess(h: win.HANDLE, code: win.UINT) callconv(.winapi) win.BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) win.HANDLE;

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "isStale: never in the wait, not before the threshold" {
    const s = std.time.ns_per_s;
    try testing.expect(!isStale(0, 100 * s, s));
    try testing.expect(!isStale(10 * s, 10 * s + s - 1, s));
    try testing.expect(isStale(10 * s, 11 * s, s));
    try testing.expect(isStale(10 * s, 20 * s, s));
}

test "CtrlCScanner: legacy and kitty forms, split, mixed, release-only" {
    if (is_windows) return error.SkipZigTest;
    var s: CtrlCScanner = .{};
    try testing.expectEqual(@as(usize, 0), s.feed("abc"));
    try testing.expectEqual(@as(usize, 1), s.feed("x\x03y"));
    // Kitty press, split across reads.
    try testing.expectEqual(@as(usize, 1), s.feed("\x1b[9"));
    try testing.expectEqual(@as(usize, 2), s.feed("9;5u"));
    // Explicit press event, with Caps Lock on.
    try testing.expectEqual(@as(usize, 3), s.feed("\x1b[99;69:1u"));

    var r: CtrlCScanner = .{};
    // Repeat and release don't count, nor Ctrl-Shift-... other keys.
    try testing.expectEqual(@as(usize, 0), r.feed("\x1b[99;5:2u\x1b[99;5:3u\x1b[100;5u\x1b[99;1u"));
    // Super+Ctrl+C isn't Ctrl-C.
    try testing.expectEqual(@as(usize, 0), r.feed("\x1b[99;13u"));
}

test "isCtrlCRecord: key-down VK C with either Ctrl" {
    const rec = console_keys.testRecord;
    try testing.expect(isCtrlCRecord(.keyRecord(rec(true, 'C', 0x03, console_keys.LEFT_CTRL_PRESSED))));
    try testing.expect(isCtrlCRecord(.keyRecord(rec(true, 'C', 0x03, console_keys.RIGHT_CTRL_PRESSED))));
    try testing.expect(!isCtrlCRecord(.keyRecord(rec(false, 'C', 0x03, console_keys.LEFT_CTRL_PRESSED))));
    try testing.expect(!isCtrlCRecord(.keyRecord(rec(true, 'C', 'c', 0))));
    try testing.expect(!isCtrlCRecord(.keyRecord(rec(true, 'D', 0x04, console_keys.LEFT_CTRL_PRESSED))));
    try testing.expect(!isCtrlCRecord(.focusRecord(true)));
}

const TestExit = struct {
    fired: std.atomic.Value(bool) = .init(false),

    fn exitFn(ctx: ?*anyopaque) void {
        const t: *TestExit = @ptrCast(@alignCast(ctx.?));
        t.fired.store(true, .release);
    }
};

fn waitFor(flag: *std.atomic.Value(bool), timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (!flag.load(.acquire)) : (waited += 5) {
        if (waited >= timeout_ms) return false;
        testing.io.sleep(.fromMilliseconds(5), .awake) catch return false;
    }
    return true;
}

test "a stuck loop: two Ctrl-Cs fire the exit, other bytes are handed back" {
    if (is_windows) return error.SkipZigTest;
    var p: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&p));
    defer _ = c.close(p[0]);
    defer _ = c.close(p[1]);
    var exit: TestExit = .{};
    var wd: Watchdog = .init(testing.io, .{
        .in = p[0],
        .stale_ns = 50 * std.time.ns_per_ms,
        .tick_ms = 10,
        .exit = .{ .ctx = &exit, .exitFn = TestExit.exitFn },
    });
    // Busy from here on: no `enterWait`.
    try wd.start();
    defer wd.stop();
    _ = c.write(p[1], "x\x03", 2);
    testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    try testing.expect(!exit.fired.load(.acquire));
    _ = c.write(p[1], "\x03", 1);
    try testing.expect(waitFor(&exit.fired, 2000));
    wd.stop();
    var out: [handback_len]Raw = undefined;
    const n = enterWait(&wd, &out);
    try testing.expectEqualStrings("x\x03\x03", out[0..n]);
}

test "a responsive loop: the watchdog never reads" {
    if (is_windows) return error.SkipZigTest;
    var p: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&p));
    defer _ = c.close(p[0]);
    defer _ = c.close(p[1]);
    var exit: TestExit = .{};
    var wd: Watchdog = .init(testing.io, .{
        .in = p[0],
        .stale_ns = 30 * std.time.ns_per_ms,
        .tick_ms = 10,
        .exit = .{ .ctx = &exit, .exitFn = TestExit.exitFn },
    });
    try wd.start();
    defer wd.stop();
    var out: [handback_len]Raw = undefined;
    // In the wait (as `Events.wait` would be), well past the threshold.
    try testing.expectEqual(@as(usize, 0), enterWait(&wd, &out));
    _ = c.write(p[1], "\x03\x03", 2);
    testing.io.sleep(.fromMilliseconds(150), .awake) catch {};
    try testing.expect(!exit.fired.load(.acquire));
    // The bytes are still on the pipe, for the loop.
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(isize, 2), c.read(p[0], &buf, buf.len));
}

test "a loop that recovers gets the bytes through Events.wait, and the count starts over" {
    if (is_windows) return error.SkipZigTest;
    var p: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&p));
    defer _ = c.close(p[0]);
    defer _ = c.close(p[1]);
    var exit: TestExit = .{};
    var wd: Watchdog = .init(testing.io, .{
        .in = p[0],
        .stale_ns = 30 * std.time.ns_per_ms,
        .tick_ms = 10,
        .exit = .{ .ctx = &exit, .exitFn = TestExit.exitFn },
    });
    var ev: Events = try .init(testing.io, .{ .in = p[0], .out = undefined, .handback = wd.handback() });
    defer ev.deinit();
    try wd.start();
    defer wd.stop();

    // Stuck: the watchdog reads one Ctrl-C and a key.
    _ = c.write(p[1], "\x03k", 2);
    testing.io.sleep(.fromMilliseconds(120), .awake) catch {};
    // Recovered: the loop's wait returns them without blocking.
    const w = try ev.wait(null);
    try testing.expectEqualStrings("\x03k", w.input);
    // Stuck again: one more Ctrl-C is a first one, not a second.
    testing.io.sleep(.fromMilliseconds(80), .awake) catch {};
    _ = c.write(p[1], "\x03", 1);
    testing.io.sleep(.fromMilliseconds(80), .awake) catch {};
    try testing.expect(!exit.fired.load(.acquire));
}
