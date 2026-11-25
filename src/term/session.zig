//! The terminal session: raw mode and (optionally) the alternate screen with
//! a hidden cursor, and a restore that works from anywhere: normal exit, a
//! signal handler, the panic handler, or a Windows console control handler.
//!
//! Process-wide by nature (signal handlers can't take a context), so the
//! state is global and there is at most one session.
//!
//! `restore` is idempotent and async-signal-safe: one atomic swap, one
//! pre-built byte string written with `write(2)` (`WriteFile` on Windows),
//! then `tcsetattr` (`SetConsoleMode`). The byte string deletes every kitty
//! image on the alternate screen (`a=d,d=A`): temui owns the alt screen, and
//! its image store is separate from the main screen's, so no id registry is
//! needed. Renderers still delete only their own ids in `clear`.
//!
//! With `contain_stdio` (POSIX), session output goes to a private
//! duplicate of fd 1, and fds 1 and 2 are pointed at a pipe (or
//! `/dev/null`), so a core's `printf` never lands on the screen. `restore`
//! puts fds 1 and 2 back (`dup2`, async-signal-safe) so panics, signal
//! traces and the exit summary reach the terminal. Windows doesn't redirect:
//! CRT-level core output may reach the console (D13).
//!
//! SIGKILL can't be caught; `reset` recovers the terminal (see README).

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const c = std.c;
const posix = std.posix;
const win = std.os.windows;

/// Alternate screen on, cursor hidden, screen cleared and homed, then every
/// kitty placement there deleted, so a fresh start never shows stale images.
pub const enter_alt = "\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H\x1b_Ga=d,d=A,q=2\x1b\\";
/// Kitty images on the alt screen deleted, SGR reset, cursor shown, alt
/// screen left.
pub const leave_alt = "\x1b_Ga=d,d=A,q=2\x1b\\\x1b[0m\x1b[?25h\x1b[?1049l";

pub const Options = struct {
    /// Enter the alternate screen and hide the cursor; otherwise only raw
    /// mode (e.g. for terminal detection).
    alt_screen: bool = true,
    /// Keep the process's own stdout/stderr off the terminal (POSIX; a
    /// no-op on Windows).
    contain_stdio: Contain = .off,
};

pub const Contain = enum {
    /// fds 1 and 2 stay on the terminal.
    off,
    /// fds 1 and 2 go to a pipe; the caller drains `stdioPipe()` (into the
    /// log) and calls `flushContained` before `restore`.
    pipe,
    /// fds 1 and 2 go to `/dev/null` (logging disabled).
    discard,
};

pub const Fd = if (is_windows) win.HANDLE else c.fd_t;

const Saved = if (is_windows) struct {
    in_mode: win.DWORD,
    out_mode: win.DWORD,
    out_cp: win.UINT,
} else c.termios;

/// Global session state. `active` gates `restore`; the rest is written by
/// `enter` before `active` is set and before any handler is installed.
var active: std.atomic.Value(bool) = .init(false);
var in_fd: Fd = undefined;
var out_fd: Fd = undefined;
var saved: ?Saved = null;
var cleanup: []const u8 = "";
var handlers_installed = false;
/// Containment state (POSIX): set by `enter` before `active`, cleared by
/// `restore`. `saved_err` is a duplicate of the original fd 2; `out_fd` is
/// then the private duplicate of the original fd 1.
var contained = false;
var saved_err: c.fd_t = -1;
var stdio_read: c.fd_t = -1;

pub const EnterError = error{ NotATerminal, AlreadyActive, WriteFailed, ContainFailed };

/// Puts the terminal into raw mode: no echo, no line buffering, no signals
/// from keys (ISIG off, so Ctrl-C arrives as byte 0x03), and with
/// `alt_screen`, the alternate screen with a hidden cursor. Installs
/// handlers for termination signals and crashes (`caught`; Windows: a
/// console control handler) that restore and then hand the signal to its
/// previous action. Undo with `restore`.
pub fn enter(opts: Options) EnterError!void {
    if (active.load(.acquire)) return error.AlreadyActive;
    if (is_windows) try enterWindows() else try enterPosix();
    if (!is_windows and opts.contain_stdio != .off) {
        containPosix(opts.contain_stdio) catch {
            _ = c.tcsetattr(in_fd, .FLUSH, &saved.?);
            return error.ContainFailed;
        };
    }
    cleanup = if (opts.alt_screen) leave_alt else "";
    active.store(true, .release);
    installHandlers();
    if (opts.alt_screen and !writeAll(out_fd, enter_alt)) {
        restore();
        return error.WriteFailed;
    }
}

/// Whether a session is active (entered and not yet restored).
pub fn isActive() bool {
    return active.load(.acquire);
}

/// Where session output goes: the terminal (the private duplicate of fd 1
/// under containment). Valid while a session is active.
pub fn outFd() Fd {
    return out_fd;
}

/// Where session input comes from: stdin (Windows: the console input
/// handle). Valid while a session is active.
pub fn inFd() Fd {
    return in_fd;
}

/// Writes all of `bytes` to `outFd()`, retrying short writes and EINTR.
pub fn writeOut(bytes: []const u8) error{WriteFailed}!void {
    if (!writeAll(out_fd, bytes)) return error.WriteFailed;
}

/// The non-blocking read end of the containment pipe (`contain_stdio =
/// .pipe`), or null. The caller drains it and owns it after `restore`.
pub fn stdioPipe() ?Fd {
    if (is_windows or stdio_read < 0) return null;
    return stdio_read;
}

/// Flushes C stdio buffers (a core's stdout is block-buffered when fd 1 is
/// a pipe) into the containment pipe. Call before `restore`, then drain the
/// pipe once more, so buffered core output lands in the log rather than on
/// the restored terminal. Not async-signal-safe.
pub fn flushContained() void {
    if (is_windows) return;
    _ = fflush(null);
}

extern "c" fn fflush(stream: ?*anyopaque) c_int;

/// Undoes `enter`: writes the cleanup bytes, puts fds 1 and 2 back on the
/// terminal (under containment) and restores the saved terminal modes.
/// Idempotent; safe to call from a signal handler, the panic handler, or
/// with no session (does nothing).
pub fn restore() void {
    if (!active.swap(false, .acq_rel)) return;
    _ = writeAll(out_fd, cleanup);
    if (!is_windows and contained) {
        contained = false;
        _ = c.dup2(out_fd, 1);
        _ = c.dup2(saved_err, 2);
        // Known gap: the private `out_fd` and `saved_err` duplicates stay
        // open, and `stdio_read` still names the pipe (which `play` closes),
        // so `stdioPipe()` goes stale. Harmless while a process enters one
        // contained session (`play`). Before a second one (the attach/detach
        // viewer, item 13), close them and reset the fds in a teardown
        // outside this signal path.
    }
    if (saved) |*s| {
        if (is_windows) {
            _ = SetConsoleMode(in_fd, s.in_mode);
            _ = SetConsoleMode(out_fd, s.out_mode);
            _ = SetConsoleOutputCP(s.out_cp);
        } else {
            // FLUSH: unread replies and keys don't spill into the shell.
            _ = c.tcsetattr(in_fd, .FLUSH, s);
        }
    }
}

/// Writes all of `bytes`, retrying on EINTR and short writes. Returns false
/// if the descriptor failed. Async-signal-safe.
fn writeAll(fd: Fd, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        if (is_windows) {
            var n: win.DWORD = undefined;
            const len: win.DWORD = @intCast(@min(rest.len, std.math.maxInt(win.DWORD)));
            if (WriteFile(fd, rest.ptr, len, &n, null) == .FALSE) return false;
            rest = rest[n..];
        } else {
            const n = c.write(fd, rest.ptr, rest.len);
            if (n < 0) {
                if (c._errno().* == @backingInt(c.E.INTR)) continue;
                return false;
            }
            rest = rest[@intCast(n)..];
        }
    }
    return true;
}

// ---------------------------------------------------------------- POSIX

fn enterPosix() EnterError!void {
    var t: c.termios = undefined;
    if (c.tcgetattr(0, &t) != 0) return error.NotATerminal;
    if (c.isatty(1) != 1) return error.NotATerminal;
    in_fd = 0;
    out_fd = 1;
    saved = t;
    t.lflag.ICANON = false;
    t.lflag.ECHO = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;
    t.iflag.IXON = false;
    t.iflag.ICRNL = false;
    t.cc[@backingInt(c.V.MIN)] = 1;
    t.cc[@backingInt(c.V.TIME)] = 0;
    if (c.tcsetattr(0, .FLUSH, &t) != 0) return error.NotATerminal;
}

/// Moves terminal output to a private fd and points fds 1 and 2 at a pipe
/// or `/dev/null`. On error nothing has changed.
fn containPosix(mode: Contain) error{ContainFailed}!void {
    const term = c.fcntl(1, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (term < 0) return error.ContainFailed;
    errdefer _ = c.close(term);
    const err = c.fcntl(2, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
    if (err < 0) return error.ContainFailed;
    errdefer _ = c.close(err);

    var read_end: c.fd_t = -1;
    const target: c.fd_t = switch (mode) {
        .off => unreachable,
        .pipe => blk: {
            var p: [2]c.fd_t = undefined;
            if (c.pipe(&p) != 0) return error.ContainFailed;
            // Read end: temui's, never blocks the loop. Write end: the
            // core's; a flood drops output (EAGAIN) instead of blocking it.
            if (!setNonblockCloexec(p[0]) or !setNonblockCloexec(p[1])) {
                _ = c.close(p[0]);
                _ = c.close(p[1]);
                return error.ContainFailed;
            }
            read_end = p[0];
            break :blk p[1];
        },
        .discard => c.open("/dev/null", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }),
    };
    if (target < 0) return error.ContainFailed;
    // dup2 clears close-on-exec on 1 and 2, as for ordinary stdio.
    if (c.dup2(target, 1) < 0 or c.dup2(target, 2) < 0) {
        _ = c.dup2(term, 1);
        _ = c.dup2(err, 2);
        _ = c.close(target);
        if (read_end >= 0) _ = c.close(read_end);
        return error.ContainFailed;
    }
    _ = c.close(target);
    out_fd = term;
    saved_err = err;
    stdio_read = read_end;
    contained = true;
}

fn setNonblockCloexec(fd: c.fd_t) bool {
    const fl = c.fcntl(fd, c.F.GETFL);
    if (fl < 0) return false;
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    if (c.fcntl(fd, c.F.SETFL, fl | nonblock) != 0) return false;
    return c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) == 0;
}

/// Termination requests, and crashes (a fault in a libretro core, `abort`).
const caught = if (is_windows) [_]void{} else [_]posix.SIG{ .INT, .TERM, .HUP, .QUIT, .ABRT, .SEGV, .BUS, .ILL, .FPE };
/// The action each `caught` signal had before (default, or Zig's segfault
/// handler that prints a stack trace).
var previous: [caught.len]posix.Sigaction = undefined;

fn installHandlers() void {
    if (handlers_installed) return;
    handlers_installed = true;
    if (is_windows) {
        _ = SetConsoleCtrlHandler(onCtrl, .TRUE);
        return;
    }
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (caught, &previous) |sig, *prev| {
        posix.sigaction(sig, null, prev);
        // An ignored signal (SIGHUP under nohup) stays ignored.
        if (prev.handler.handler != posix.SIG.IGN) posix.sigaction(sig, &act, null);
    }
}

fn onSignal(sig: posix.SIG) callconv(.c) void {
    restore();
    // Hand the signal on to the previous action: blocked until this handler
    // returns, then delivered, so a crash still prints its trace (on the
    // restored screen) and the exit status says which signal it was.
    for (caught, previous) |s, prev| {
        if (s == sig) posix.sigaction(sig, &prev, null);
    }
    _ = c.raise(sig);
}

/// Result of `pollInput`.
pub const Input = struct {
    /// Bytes read (a prefix of the caller's buffer); empty on timeout.
    bytes: []u8,
    /// Ctrl-C (0x03) or `q` was among them.
    quit: bool,
};

/// Whether `poll` works on `fd`. macOS can't poll `/dev/tty` (the
/// controlling-terminal alias): `poll` reports POLLNVAL at once, so a wait
/// would spin and the following `read` would block. Seen when stdin is
/// redirected from `/dev/tty`. POSIX only; true on Windows.
pub fn pollable(fd: Fd) bool {
    if (is_windows) return true;
    var fds = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    if (c.poll(&fds, 1, 0) < 0) return true; // EINTR and the like: not this problem
    return fds[0].revents & c.POLL.NVAL == 0;
}

/// Waits up to `timeout_ms` (negative: forever) for input on `fd`, reads
/// what's there into `buf`, and flags Ctrl-C / `q`. POSIX only: Windows
/// console input is event-based and arrives with item 06.
pub fn pollInput(fd: Fd, buf: []u8, timeout_ms: i32) !Input {
    if (is_windows) return error.Unsupported;
    var fds = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    const ready = c.poll(&fds, 1, timeout_ms);
    if (ready < 0) {
        if (c._errno().* == @backingInt(c.E.INTR)) return .{ .bytes = buf[0..0], .quit = false };
        return error.PollFailed;
    }
    if (ready == 0) return .{ .bytes = buf[0..0], .quit = false };
    const n = c.read(fd, buf.ptr, buf.len);
    if (n < 0) {
        if (c._errno().* == @backingInt(c.E.INTR)) return .{ .bytes = buf[0..0], .quit = false };
        return error.ReadFailed;
    }
    // n == 0 is end of input (the terminal went away): treat as quit.
    const bytes = buf[0..@intCast(n)];
    const quit = n == 0 or std.mem.indexOfAny(u8, bytes, "\x03q") != null;
    return .{ .bytes = bytes, .quit = quit };
}

// ---------------------------------------------------------------- Windows

const ENABLE_PROCESSED_INPUT: win.DWORD = 0x0001;
const ENABLE_LINE_INPUT: win.DWORD = 0x0002;
const ENABLE_ECHO_INPUT: win.DWORD = 0x0004;
const ENABLE_WINDOW_INPUT: win.DWORD = 0x0008;
const ENABLE_VIRTUAL_TERMINAL_INPUT: win.DWORD = 0x0200;
const ENABLE_PROCESSED_OUTPUT: win.DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: win.DWORD = 0x0004;
const STD_INPUT_HANDLE: win.DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: win.DWORD = @bitCast(@as(i32, -11));
const CP_UTF8: win.UINT = 65001;

const CtrlHandler = *const fn (win.DWORD) callconv(.winapi) win.BOOL;

extern "kernel32" fn GetStdHandle(nStdHandle: win.DWORD) callconv(.winapi) ?win.HANDLE;
extern "kernel32" fn GetConsoleMode(hConsoleHandle: win.HANDLE, lpMode: *win.DWORD) callconv(.winapi) win.BOOL;
extern "kernel32" fn SetConsoleMode(hConsoleHandle: win.HANDLE, dwMode: win.DWORD) callconv(.winapi) win.BOOL;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) win.UINT;
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: win.UINT) callconv(.winapi) win.BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(HandlerRoutine: ?CtrlHandler, Add: win.BOOL) callconv(.winapi) win.BOOL;
extern "kernel32" fn WriteFile(hFile: win.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: win.DWORD, lpNumberOfBytesWritten: ?*win.DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) win.BOOL;

fn enterWindows() EnterError!void {
    const in = GetStdHandle(STD_INPUT_HANDLE) orelse return error.NotATerminal;
    const out = GetStdHandle(STD_OUTPUT_HANDLE) orelse return error.NotATerminal;
    var in_mode: win.DWORD = undefined;
    var out_mode: win.DWORD = undefined;
    if (GetConsoleMode(in, &in_mode) == .FALSE) return error.NotATerminal;
    if (GetConsoleMode(out, &out_mode) == .FALSE) return error.NotATerminal;
    in_fd = in;
    out_fd = out;
    saved = .{ .in_mode = in_mode, .out_mode = out_mode, .out_cp = GetConsoleOutputCP() };
    const raw_in = (in_mode & ~(ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT)) | ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_WINDOW_INPUT;
    if (SetConsoleMode(in, raw_in) == .FALSE) return error.NotATerminal;
    const vt_out = out_mode | ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING;
    if (SetConsoleMode(out, vt_out) == .FALSE) {
        _ = SetConsoleMode(in, in_mode);
        return error.NotATerminal;
    }
    _ = SetConsoleOutputCP(CP_UTF8);
}

/// Ctrl-C (if processed input is on), Ctrl-Break, close, logoff, shutdown:
/// restore, then let the default handler terminate the process.
fn onCtrl(_: win.DWORD) callconv(.winapi) win.BOOL {
    restore();
    return .FALSE;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Points the session at a pipe, as if `enter` had succeeded without a tty
/// (no termios to restore), and returns the read end.
fn fakeSession(alt_screen: bool) ![2]c.fd_t {
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    out_fd = fds[1];
    saved = null;
    cleanup = if (alt_screen) leave_alt else "";
    active.store(true, .release);
    return fds;
}

fn readAll(fd: c.fd_t, buf: []u8) ![]u8 {
    var fds = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
    if (c.poll(&fds, 1, 0) == 0) return buf[0..0];
    const n = c.read(fd, buf.ptr, buf.len);
    if (n < 0) return error.ReadFailed;
    return buf[0..@intCast(n)];
}

test "cleanup strings" {
    try testing.expectEqualStrings("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[H\x1b_Ga=d,d=A,q=2\x1b\\", enter_alt);
    // Images are deleted while still on the alt screen, before leaving it.
    try testing.expect(std.mem.indexOf(u8, leave_alt, "a=d,d=A").? < std.mem.indexOf(u8, leave_alt, "\x1b[?1049l").?);
    try testing.expect(std.mem.indexOf(u8, leave_alt, "\x1b[?25h") != null);
    try testing.expect(std.mem.indexOf(u8, leave_alt, "\x1b[0m") != null);
}

test "restore writes the cleanup once and is idempotent" {
    if (is_windows) return error.SkipZigTest;
    const fds = try fakeSession(true);
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    try testing.expect(isActive());
    restore();
    try testing.expect(!isActive());
    restore();
    restore();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(leave_alt, try readAll(fds[0], &buf));
}

test "raw-only session writes nothing on restore" {
    if (is_windows) return error.SkipZigTest;
    const fds = try fakeSession(false);
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    restore();
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("", try readAll(fds[0], &buf));
}

test "a signal restores, then takes its previous action; crashes are caught" {
    if (is_windows) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    const pid = c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        _ = c.close(fds[0]);
        out_fd = fds[1];
        saved = null;
        cleanup = leave_alt;
        active.store(true, .release);
        handlers_installed = false;
        installHandlers();
        var q: posix.Sigaction = undefined;
        posix.sigaction(.SEGV, null, &q);
        if (q.handler.handler != onSignal) c._exit(2);
        _ = c.raise(.TERM);
        c._exit(3);
    }
    _ = c.close(fds[1]);
    var status: c_int = 0;
    try testing.expectEqual(pid, c.waitpid(pid, &status, 0));
    const st: u32 = @bitCast(status);
    try testing.expect(posix.W.IFSIGNALED(st));
    try testing.expectEqual(posix.SIG.TERM, posix.W.TERMSIG(st));
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(leave_alt, try readAll(fds[0], &buf));
}

test "restore without a session does nothing" {
    try testing.expect(!isActive());
    restore();
    try testing.expect(!isActive());
}

test "enter fails cleanly without a terminal" {
    if (is_windows) return error.SkipZigTest;
    // Under `zig build test` stdin/stdout are not a tty; skip if run by
    // hand in one, since entering raw mode would disturb the terminal.
    if (c.isatty(0) == 1 and c.isatty(1) == 1) return error.SkipZigTest;
    try testing.expectError(error.NotATerminal, enter(.{}));
    try testing.expect(!isActive());
}

test "pollable: a pipe is, a closed fd is not" {
    if (is_windows) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[1]);
    try testing.expect(pollable(fds[0]));
    _ = c.close(fds[0]);
    try testing.expect(!pollable(fds[0]));
}

test "pollInput flags Ctrl-C and q, and times out" {
    if (is_windows) return error.SkipZigTest;
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    defer _ = c.close(fds[0]);
    var buf: [16]u8 = undefined;

    const none = try pollInput(fds[0], &buf, 0);
    try testing.expectEqual(@as(usize, 0), none.bytes.len);
    try testing.expect(!none.quit);

    _ = c.write(fds[1], "ab", 2);
    const plain = try pollInput(fds[0], &buf, 100);
    try testing.expectEqualStrings("ab", plain.bytes);
    try testing.expect(!plain.quit);

    _ = c.write(fds[1], "x\x03", 2);
    try testing.expect((try pollInput(fds[0], &buf, 100)).quit);
    _ = c.write(fds[1], "q", 1);
    try testing.expect((try pollInput(fds[0], &buf, 100)).quit);

    // Writer gone: end of input counts as quit.
    _ = c.close(fds[1]);
    try testing.expect((try pollInput(fds[0], &buf, 100)).quit);
}

extern "c" fn printf(format: [*:0]const u8, ...) c_int;

fn readToEof(fd: c.fd_t, buf: []u8) ![]u8 {
    var len: usize = 0;
    while (len < buf.len) {
        const n = c.read(fd, buf[len..].ptr, buf.len - len);
        if (n < 0) {
            if (c._errno().* == @backingInt(c.E.INTR)) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        len += @intCast(n);
    }
    return buf[0..len];
}

/// Runs a contained session in a forked child whose fds 1 and 2 are a pipe
/// standing in for the terminal (the test runner's own stdout is its IPC
/// channel, so it must not be redirected in-process). The child writes to
/// fd 1 with C stdio (block-buffered, as a core's would be) and to fd 2,
/// flushes, forwards what it drained from the containment pipe on `fwd`,
/// restores (twice), and writes again. Returns the "terminal" and drained
/// bytes.
fn runContained(mode: Contain, term_buf: []u8, drained_buf: []u8) !struct { term: []u8, drained: []u8 } {
    var term: [2]c.fd_t = undefined;
    var fwd: [2]c.fd_t = undefined;
    if (c.pipe(&term) != 0 or c.pipe(&fwd) != 0) return error.PipeFailed;
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.close(term[0]);
        _ = c.close(fwd[0]);
        if (c.dup2(term[1], 1) < 0 or c.dup2(term[1], 2) < 0) c._exit(10);
        _ = c.close(term[1]);
        saved = null;
        containPosix(mode) catch c._exit(11);
        cleanup = leave_alt;
        active.store(true, .release);
        if (outFd() == 1) c._exit(12);
        if ((stdioPipe() != null) != (mode == .pipe)) c._exit(13);

        _ = printf("printf-text\n");
        _ = c.write(2, "err-text\n", 9);
        flushContained();
        if (stdioPipe()) |r| {
            var buf: [256]u8 = undefined;
            const n = c.read(r, &buf, buf.len);
            if (n > 0) _ = c.write(fwd[1], &buf, @intCast(n));
        }
        restore();
        restore();
        _ = c.write(1, "after1\n", 7);
        _ = c.write(2, "after2\n", 7);
        _ = printf("after3\n");
        _ = fflush(null);
        c._exit(0);
    }
    _ = c.close(term[1]);
    _ = c.close(fwd[1]);
    defer _ = c.close(term[0]);
    defer _ = c.close(fwd[0]);
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) != pid) return error.WaitFailed;
    const st: u32 = @bitCast(status);
    try testing.expect(posix.W.IFEXITED(st));
    try testing.expectEqual(@as(u32, 0), posix.W.EXITSTATUS(st));
    return .{ .term = try readToEof(term[0], term_buf), .drained = try readToEof(fwd[0], drained_buf) };
}

test "contain_stdio pipe: stdio goes to the pipe, never the terminal; restore puts it back" {
    if (is_windows) return error.SkipZigTest;
    var tb: [512]u8 = undefined;
    var db: [512]u8 = undefined;
    const r = try runContained(.pipe, &tb, &db);
    try testing.expectEqualStrings(leave_alt ++ "after1\nafter2\nafter3\n", r.term);
    // Unbuffered fd 2 arrives first; C stdio's buffer only on fflush.
    try testing.expectEqualStrings("err-text\nprintf-text\n", r.drained);
}

test "contain_stdio discard: stdio is dropped; restore puts it back" {
    if (is_windows) return error.SkipZigTest;
    var tb: [512]u8 = undefined;
    var db: [512]u8 = undefined;
    const r = try runContained(.discard, &tb, &db);
    try testing.expectEqualStrings(leave_alt ++ "after1\nafter2\nafter3\n", r.term);
    try testing.expectEqualStrings("", r.drained);
}
