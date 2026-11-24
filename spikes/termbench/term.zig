//! Terminal setup and restore: raw mode, alternate screen, window size,
//! signal handling, and unbuffered writes to stdout.

const std = @import("std");
const c = std.c;
const posix = std.posix;

pub const stdin_fd: c.fd_t = 0;
pub const stdout_fd: c.fd_t = 1;

var saved: ?c.termios = null;
var in_alt_screen = std.atomic.Value(bool).init(false);
/// Set by SIGINT/SIGTERM (and by the reader on a Ctrl-C byte).
pub var interrupted = std.atomic.Value(bool).init(false);
var signal_count = std.atomic.Value(u32).init(0);
var main_thread: ?c.pthread_t = null;

/// Monotonic ns when the main thread's current `writeWatched` last made
/// progress; 0 when it isn't writing. Read by the reader's watchdog.
pub var write_since = std.atomic.Value(u64).init(0);
/// Set by the watchdog when a write made no progress for too long.
pub var write_stalled = std.atomic.Value(bool).init(false);

pub const Size = struct {
    cols: u16,
    rows: u16,
    /// Window size in pixels; 0 when the terminal doesn't report it.
    px_w: u16,
    px_h: u16,

    pub fn cellW(s: Size) f64 {
        return if (s.px_w == 0) 0 else @as(f64, @floatFromInt(s.px_w)) / @as(f64, @floatFromInt(s.cols));
    }
    pub fn cellH(s: Size) f64 {
        return if (s.px_h == 0) 0 else @as(f64, @floatFromInt(s.px_h)) / @as(f64, @floatFromInt(s.rows));
    }
};

pub fn size() !Size {
    var ws: posix.winsize = undefined;
    if (c.ioctl(stdout_fd, c.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) return error.NotATerminal;
    return .{ .cols = ws.col, .rows = ws.row, .px_w = ws.xpixel, .px_h = ws.ypixel };
}

/// Raw mode (no echo, no canonical input, no signals from keys: Ctrl-C
/// arrives as byte 0x03), alternate screen, hidden cursor. Installs
/// SIGINT/SIGTERM handlers. Undo with `restore`.
pub fn enter() !void {
    var t: c.termios = undefined;
    if (c.tcgetattr(stdin_fd, &t) != 0) return error.NotATerminal;
    saved = t;
    t.lflag.ICANON = false;
    t.lflag.ECHO = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;
    t.iflag.IXON = false;
    t.iflag.ICRNL = false;
    t.cc[@backingInt(c.V.MIN)] = 1;
    t.cc[@backingInt(c.V.TIME)] = 0;
    if (c.tcsetattr(stdin_fd, .FLUSH, &t) != 0) return error.NotATerminal;

    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0, // no SA_RESTART: a blocked write/poll returns EINTR
    };
    posix.sigaction(.INT, &act, null);
    posix.sigaction(.TERM, &act, null);
    // SIGUSR1 only interrupts a blocked write (see `wakeMain`).
    const wake: posix.Sigaction = .{ .handler = .{ .handler = onWake }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.USR1, &wake, null);
    main_thread = c.pthread_self();

    writeAll("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H");
    in_alt_screen.store(true, .release);
}

/// Idempotent. Deletes kitty images, leaves the alternate screen, shows the
/// cursor, restores termios. Async-signal-safe (write + tcsetattr only).
pub fn restore() void {
    if (in_alt_screen.swap(false, .acq_rel)) {
        writeAll("\x1b_Ga=d,d=A,q=2\x1b\\\x1b[0m\x1b[2J\x1b[?25h\x1b[?1049l");
    }
    if (saved) |*t| _ = c.tcsetattr(stdin_fd, .FLUSH, t);
}

fn onWake(_: posix.SIG) callconv(.c) void {}

/// Interrupts a blocking write on the main thread (EINTR or a short write),
/// so it can notice `interrupted` or `write_stalled`.
pub fn wakeMain() void {
    if (main_thread) |t| _ = c.pthread_kill(t, .USR1);
}

fn onSignal(_: posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
    // A second signal means the main loop is stuck: restore and leave now.
    if (signal_count.fetchAdd(1, .acq_rel) >= 1) {
        restore();
        c._exit(130);
    }
}

/// Writes all of `bytes` to stdout, retrying on EINTR/partial writes.
/// Returns false if the write failed (e.g. the terminal went away) or the
/// process was interrupted mid-write.
pub fn writeAll(bytes: []const u8) void {
    _ = tryWriteAll(bytes);
}

pub fn tryWriteAll(bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(stdout_fd, rest.ptr, rest.len);
        if (n < 0) {
            if (c._errno().* == @backingInt(c.E.INTR)) {
                if (interrupted.load(.acquire)) return false;
                continue;
            }
            return false;
        }
        rest = rest[@intCast(n)..];
    }
    return true;
}

pub const WriteResult = enum { ok, stalled, interrupted, failed };

/// Blocking write of all of `bytes` that gives up when the run is
/// interrupted or the reader's watchdog flags a stall (no progress for the
/// ack timeout). Stdout stays blocking: O_NONBLOCK on the tty would also
/// affect the shell's stdin and outlive a crash.
pub fn writeWatched(bytes: []const u8) WriteResult {
    write_stalled.store(false, .release);
    write_since.store(nowNs(), .release);
    defer write_since.store(0, .release);
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(stdout_fd, rest.ptr, rest.len);
        if (n < 0 and c._errno().* != @backingInt(c.E.INTR)) return .failed;
        if (n > 0) {
            rest = rest[@intCast(n)..];
            write_since.store(nowNs(), .release);
        }
        if (rest.len == 0) break;
        if (interrupted.load(.acquire)) return .interrupted;
        if (write_stalled.load(.acquire)) return .stalled;
    }
    return .ok;
}

/// Monotonic nanoseconds.
pub fn nowNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn sleepNs(ns: u64) void {
    var ts: c.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    _ = c.nanosleep(&ts, null);
}
