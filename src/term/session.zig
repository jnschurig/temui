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

/// String terminator. Leads every cleanup string, so a kitty image
/// sequence cut off mid-write (a crash, a signal) is closed and the rest of
/// the cleanup is read as commands, not as image data.
pub const string_terminator = "\x1b\\";
/// Focus reporting (`CSI I` / `CSI O`) on and off.
pub const focus_on = "\x1b[?1004h";
pub const focus_off = "\x1b[?1004l";
/// Bracketed paste on and off: a paste arrives between `CSI 200 ~` and
/// `CSI 201 ~`, so it can be told from typed keys.
pub const paste_on = "\x1b[?2004h";
pub const paste_off = "\x1b[?2004l";
/// Pops the kitty keyboard flags pushed at `enter`.
pub const kitty_pop = "\x1b[<u";
/// Asks for the current kitty keyboard flags, then sends DA1 as a sentinel:
/// a terminal that doesn't know the protocol answers only the DA1.
pub const kitty_query = "\x1b[?u\x1b[c";

pub const Options = struct {
    /// Enter the alternate screen and hide the cursor; otherwise only raw
    /// mode (e.g. for terminal detection).
    alt_screen: bool = true,
    /// Keep the process's own stdout/stderr off the terminal (POSIX; a
    /// no-op on Windows).
    contain_stdio: Contain = .off,
    /// Push these kitty keyboard protocol flags (`CSI > flags u`) after
    /// entering the alternate screen, then query them (`kitty_query`); pop
    /// them on restore. POSIX terminals.
    kitty_keyboard_flags: ?u8 = null,
    /// Turn on focus reporting; off again on restore. POSIX terminals.
    focus_events: bool = false,
    /// Turn on bracketed paste; off again on restore. POSIX terminals.
    bracketed_paste: bool = false,
    /// Windows: deliver console input as VT sequences
    /// (`ENABLE_VIRTUAL_TERMINAL_INPUT`). Off, `ReadConsoleInputW` returns
    /// `KEY_EVENT` records with virtual-key codes, key-down and key-up.
    vt_input: bool = true,
};

/// The bytes `enter` writes and the cleanup `restore` writes.
pub const Strings = struct {
    enter: []const u8,
    cleanup: []const u8,
};

/// Longest output of `buildStrings`, with room to spare.
pub const max_string_len = 128;

/// Builds the enter and cleanup strings for `opts` into the buffers.
/// Enter: alternate screen, kitty push, focus on, paste on, kitty query.
/// Cleanup, in reverse: paste off, focus off, kitty pop, alternate screen
/// left, after a leading `string_terminator` (none when there is nothing
/// to clean up).
pub fn buildStrings(opts: Options, enter_out: *[max_string_len]u8, cleanup_out: *[max_string_len]u8) Strings {
    var e: std.Io.Writer = .fixed(enter_out);
    var x: std.Io.Writer = .fixed(cleanup_out);
    // Fixed parts, bounded well below `max_string_len`: the writes can't fail.
    if (opts.alt_screen) e.writeAll(enter_alt) catch unreachable;
    if (opts.kitty_keyboard_flags) |f| e.print("\x1b[>{d}u", .{f}) catch unreachable;
    if (opts.focus_events) e.writeAll(focus_on) catch unreachable;
    if (opts.bracketed_paste) e.writeAll(paste_on) catch unreachable;
    if (opts.kitty_keyboard_flags != null) e.writeAll(kitty_query) catch unreachable;

    const any = opts.alt_screen or opts.kitty_keyboard_flags != null or opts.focus_events or opts.bracketed_paste;
    if (any) x.writeAll(string_terminator) catch unreachable;
    if (opts.bracketed_paste) x.writeAll(paste_off) catch unreachable;
    if (opts.focus_events) x.writeAll(focus_off) catch unreachable;
    if (opts.kitty_keyboard_flags != null) x.writeAll(kitty_pop) catch unreachable;
    if (opts.alt_screen) x.writeAll(leave_alt) catch unreachable;
    return .{ .enter = e.buffered(), .cleanup = x.buffered() };
}

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
} else Termios;

/// libc's `struct termios`, with room to spare. On Linux, `std.c.termios`
/// is the kernel's layout (`NCCS` 19, 44 bytes), but glibc and musl use
/// `NCCS` 32 (60 bytes), so `tcgetattr` into a bare `c.termios` writes 16
/// bytes past it. On x86_64 Debug builds that overwrote `enter`'s stack
/// frame and crashed. The fields temui touches (the flags and `cc[VMIN]`,
/// `cc[VTIME]`) are at the same offsets in both layouts; pass `&x.t`.
const Termios = extern struct {
    t: c.termios,
    libc_tail: [if (builtin.os.tag == .linux) 64 else 0]u8 = undefined,

    comptime {
        // glibc and musl's struct termios on the arches temui targets.
        if (builtin.os.tag == .linux) std.debug.assert(@sizeOf(Termios) >= 60);
    }
};

/// Global session state. `active` gates `restore`; the rest is written by
/// `enter` before `active` is set and before any handler is installed.
var active: std.atomic.Value(bool) = .init(false);
var in_fd: Fd = undefined;
var out_fd: Fd = undefined;
var saved: ?Saved = null;
var cleanup: []const u8 = "";
/// `cleanup` with the kitty pop, for once `requestKittyFlags` has pushed
/// flags that `enter` didn't.
var cleanup_pop: []const u8 = "";
/// Whether kitty keyboard flags are pushed: `restore` then writes
/// `cleanup_pop`.
var kitty_pushed: std.atomic.Value(bool) = .init(false);
/// `buildStrings` output, kept for the life of the process: `cleanup`
/// and `cleanup_pop` point into it, and signal handlers read it.
var enter_buf: [max_string_len]u8 = undefined;
var cleanup_buf: [max_string_len]u8 = undefined;
var cleanup_pop_buf: [max_string_len]u8 = undefined;

/// Builds the strings for `opts` into the buffers above and sets
/// `cleanup`, `cleanup_pop` and `kitty_pushed`. Returns the enter string.
fn setStrings(opts: Options) []const u8 {
    const strings = buildStrings(opts, &enter_buf, &cleanup_buf);
    cleanup = strings.cleanup;
    var with_pop = opts;
    if (with_pop.kitty_keyboard_flags == null) with_pop.kitty_keyboard_flags = 1; // any: only the cleanup is kept
    var scratch: [max_string_len]u8 = undefined;
    cleanup_pop = buildStrings(with_pop, &scratch, &cleanup_pop_buf).cleanup;
    kitty_pushed.store(opts.kitty_keyboard_flags != null, .release);
    return strings.enter;
}

fn cleanupNow() []const u8 {
    return if (kitty_pushed.load(.acquire)) cleanup_pop else cleanup;
}
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
    if (is_windows) try enterWindows(opts.vt_input) else try enterPosix();
    if (!is_windows and opts.contain_stdio != .off) {
        containPosix(opts.contain_stdio) catch {
            _ = c.tcsetattr(in_fd, .FLUSH, &saved.?.t);
            return error.ContainFailed;
        };
    }
    const enter_str = setStrings(opts);
    active.store(true, .release);
    installHandlers();
    if (enter_str.len > 0 and !writeAll(out_fd, enter_str)) {
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

/// Asks the terminal for the kitty keyboard protocol again (a recheck
/// before game mode, item 06), then sends `kitty_query`. Pushes `flags` if
/// none are pushed yet, and from then on `restore` pops them. Otherwise
/// sets them on the entry already pushed (`CSI = flags ; 1 u`), so repeated
/// rechecks never grow the stack. POSIX, with a session active.
pub fn requestKittyFlags(flags: u8) error{WriteFailed}!void {
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Marked first: a pop with nothing pushed only empties the stack.
    if (kitty_pushed.swap(true, .acq_rel)) {
        w.print("\x1b[={d};1u", .{flags}) catch unreachable;
    } else {
        w.print("\x1b[>{d}u", .{flags}) catch unreachable;
    }
    w.writeAll(kitty_query) catch unreachable;
    try writeOut(w.buffered());
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
    _ = writeAll(out_fd, cleanupNow());
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
            _ = c.tcsetattr(in_fd, .FLUSH, &s.t);
        }
    }
}

/// `restore` for a watchdog that gave up on a stuck loop (item 06), which
/// must not hang too. POSIX: writes the cleanup only if the terminal takes
/// output within 200 ms (a terminal that stopped reading would block the
/// write forever), restores the terminal modes at once (`TCSANOW`; the
/// `FLUSH` in `restore` waits for output to drain) and then discards unread
/// input. Never sets `O_NONBLOCK`, which is shared with the shell's tty
/// description. Async-signal-safe. Windows: `restore`.
pub fn restoreBestEffort() void {
    if (is_windows) return restore();
    if (!active.swap(false, .acq_rel)) return;
    var fds = [_]c.pollfd{.{ .fd = out_fd, .events = c.POLL.OUT, .revents = 0 }};
    // The cleanup is shorter than PIPE_BUF, so a writable fd takes it whole.
    if (c.poll(&fds, 1, 200) == 1 and fds[0].revents & c.POLL.OUT != 0) _ = writeAll(out_fd, cleanupNow());
    if (contained) {
        contained = false;
        _ = c.dup2(out_fd, 1);
        _ = c.dup2(saved_err, 2);
    }
    if (saved) |*s| {
        _ = c.tcsetattr(in_fd, .NOW, &s.t);
        _ = tcflush(in_fd, TCIFLUSH);
    }
}

extern "c" fn tcflush(fd: c.fd_t, queue: c_int) c_int;
/// 0 on Linux, 1 on macOS and the BSDs.
const TCIFLUSH: c_int = if (builtin.os.tag == .linux) 0 else 1;

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
    var buf: Termios = undefined;
    if (c.tcgetattr(0, &buf.t) != 0) return error.NotATerminal;
    if (c.isatty(1) != 1) return error.NotATerminal;
    in_fd = 0;
    out_fd = 1;
    saved = buf;
    const t = &buf.t;
    t.lflag.ICANON = false;
    t.lflag.ECHO = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;
    t.iflag.IXON = false;
    t.iflag.ICRNL = false;
    t.cc[@backingInt(c.V.MIN)] = 1;
    t.cc[@backingInt(c.V.TIME)] = 0;
    if (c.tcsetattr(0, .FLUSH, t) != 0) return error.NotATerminal;
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

fn enterWindows(vt_input: bool) EnterError!void {
    const in = GetStdHandle(STD_INPUT_HANDLE) orelse return error.NotATerminal;
    const out = GetStdHandle(STD_OUTPUT_HANDLE) orelse return error.NotATerminal;
    var in_mode: win.DWORD = undefined;
    var out_mode: win.DWORD = undefined;
    if (GetConsoleMode(in, &in_mode) == .FALSE) return error.NotATerminal;
    if (GetConsoleMode(out, &out_mode) == .FALSE) return error.NotATerminal;
    in_fd = in;
    out_fd = out;
    saved = .{ .in_mode = in_mode, .out_mode = out_mode, .out_cp = GetConsoleOutputCP() };
    const cooked = ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT;
    const vt: win.DWORD = if (vt_input) ENABLE_VIRTUAL_TERMINAL_INPUT else 0;
    const raw_in = (in_mode & ~(cooked | ENABLE_VIRTUAL_TERMINAL_INPUT)) | vt | ENABLE_WINDOW_INPUT;
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

/// Points the session at a pipe, as if `enter(opts)` had succeeded without
/// a tty (no termios to restore), and returns the pipe.
fn fakeSession(opts: Options) ![2]c.fd_t {
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    out_fd = fds[1];
    saved = null;
    _ = setStrings(opts);
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

test "enter and cleanup strings for each option combination" {
    var eb: [max_string_len]u8 = undefined;
    var cb: [max_string_len]u8 = undefined;
    const Case = struct { opts: Options, enter: []const u8, cleanup: []const u8 };
    const cases = [_]Case{
        .{ .opts = .{ .alt_screen = false }, .enter = "", .cleanup = "" },
        .{ .opts = .{}, .enter = enter_alt, .cleanup = string_terminator ++ leave_alt },
        .{
            .opts = .{ .kitty_keyboard_flags = 15 },
            .enter = enter_alt ++ "\x1b[>15u" ++ "\x1b[?u\x1b[c",
            .cleanup = string_terminator ++ "\x1b[<u" ++ leave_alt,
        },
        .{
            .opts = .{ .focus_events = true },
            .enter = enter_alt ++ "\x1b[?1004h",
            .cleanup = string_terminator ++ "\x1b[?1004l" ++ leave_alt,
        },
        .{
            .opts = .{ .kitty_keyboard_flags = 15, .focus_events = true },
            .enter = enter_alt ++ "\x1b[>15u\x1b[?1004h\x1b[?u\x1b[c",
            .cleanup = string_terminator ++ "\x1b[?1004l\x1b[<u" ++ leave_alt,
        },
        .{
            .opts = .{ .bracketed_paste = true },
            .enter = enter_alt ++ "\x1b[?2004h",
            .cleanup = string_terminator ++ "\x1b[?2004l" ++ leave_alt,
        },
        .{
            .opts = .{ .kitty_keyboard_flags = 15, .focus_events = true, .bracketed_paste = true },
            .enter = enter_alt ++ "\x1b[>15u\x1b[?1004h\x1b[?2004h\x1b[?u\x1b[c",
            .cleanup = string_terminator ++ "\x1b[?2004l\x1b[?1004l\x1b[<u" ++ leave_alt,
        },
        .{
            .opts = .{ .alt_screen = false, .kitty_keyboard_flags = 1 },
            .enter = "\x1b[>1u\x1b[?u\x1b[c",
            .cleanup = string_terminator ++ "\x1b[<u",
        },
    };
    for (cases) |k| {
        const got = buildStrings(k.opts, &eb, &cb);
        try testing.expectEqualStrings(k.enter, got.enter);
        try testing.expectEqualStrings(k.cleanup, got.cleanup);
    }
    // The longest case stays well inside the buffers.
    const big = buildStrings(.{ .kitty_keyboard_flags = 255, .focus_events = true, .bracketed_paste = true }, &eb, &cb);
    try testing.expect(big.enter.len < max_string_len * 3 / 4 and big.cleanup.len < max_string_len * 3 / 4);
}

test "restore writes the cleanup once and is idempotent" {
    if (is_windows) return error.SkipZigTest;
    const fds = try fakeSession(.{ .kitty_keyboard_flags = 15, .focus_events = true });
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    try testing.expect(isActive());
    restore();
    try testing.expect(!isActive());
    restore();
    restore();
    var buf: [256]u8 = undefined;
    const got = try readAll(fds[0], &buf);
    try testing.expectEqualStrings(string_terminator ++ focus_off ++ kitty_pop ++ leave_alt, got);
    // The pop and focus-off happen on the alt screen, before leaving it.
    try testing.expect(std.mem.indexOf(u8, got, kitty_pop).? < std.mem.indexOf(u8, got, "\x1b[?1049l").?);
    try testing.expect(std.mem.indexOf(u8, got, focus_off).? < std.mem.indexOf(u8, got, "\x1b[?1049l").?);
}

test "requestKittyFlags pushes once, then sets; restore pops what was pushed" {
    if (is_windows) return error.SkipZigTest;
    var buf: [256]u8 = undefined;
    // Nothing pushed at enter: the first request pushes, later ones set.
    {
        const fds = try fakeSession(.{ .focus_events = true });
        defer _ = c.close(fds[0]);
        defer _ = c.close(fds[1]);
        try requestKittyFlags(15);
        try testing.expectEqualStrings("\x1b[>15u" ++ kitty_query, try readAll(fds[0], &buf));
        try requestKittyFlags(15);
        try testing.expectEqualStrings("\x1b[=15;1u" ++ kitty_query, try readAll(fds[0], &buf));
        restore();
        try testing.expectEqualStrings(string_terminator ++ focus_off ++ kitty_pop ++ leave_alt, try readAll(fds[0], &buf));
    }
    // Pushed at enter: a request sets, and restore pops once.
    {
        const fds = try fakeSession(.{ .kitty_keyboard_flags = 15 });
        defer _ = c.close(fds[0]);
        defer _ = c.close(fds[1]);
        try requestKittyFlags(15);
        try testing.expectEqualStrings("\x1b[=15;1u" ++ kitty_query, try readAll(fds[0], &buf));
        restore();
        try testing.expectEqualStrings(string_terminator ++ kitty_pop ++ leave_alt, try readAll(fds[0], &buf));
    }
    // Never requested: no pop.
    {
        const fds = try fakeSession(.{ .focus_events = true });
        defer _ = c.close(fds[0]);
        defer _ = c.close(fds[1]);
        restore();
        try testing.expectEqualStrings(string_terminator ++ focus_off ++ leave_alt, try readAll(fds[0], &buf));
    }
}

test "restoreBestEffort gives up on a terminal that stopped reading" {
    if (is_windows) return error.SkipZigTest;
    const fds = try fakeSession(.{ .kitty_keyboard_flags = 15 });
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    // Fill the pipe (non-blocking only while filling; the restore sees a
    // blocking fd, as a real tty would be).
    const fl = c.fcntl(fds[1], c.F.GETFL);
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    _ = c.fcntl(fds[1], c.F.SETFL, fl | nonblock);
    const chunk: [4096]u8 = @splat('x');
    while (c.write(fds[1], &chunk, chunk.len) > 0) {}
    while (c.write(fds[1], &chunk, 1) > 0) {}
    _ = c.fcntl(fds[1], c.F.SETFL, fl);

    const t0 = std.Io.Clock.awake.now(testing.io).nanoseconds;
    restoreBestEffort();
    const took = std.Io.Clock.awake.now(testing.io).nanoseconds - t0;
    try testing.expect(!isActive());
    try testing.expect(took >= 150 * std.time.ns_per_ms);
    try testing.expect(took < 2 * std.time.ns_per_s);
    // Idempotent, and a later `restore` does nothing either.
    restoreBestEffort();
    restore();
}

test "restoreBestEffort writes the cleanup when the terminal reads" {
    if (is_windows) return error.SkipZigTest;
    const fds = try fakeSession(.{});
    defer _ = c.close(fds[0]);
    defer _ = c.close(fds[1]);
    restoreBestEffort();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(string_terminator ++ leave_alt, try readAll(fds[0], &buf));
}

test "raw-only session writes nothing on restore" {
    if (is_windows) return error.SkipZigTest;
    const fds = try fakeSession(.{ .alt_screen = false });
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
        cleanup = buildStrings(.{}, &enter_buf, &cleanup_buf).cleanup;
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
    try testing.expectEqualStrings(string_terminator ++ leave_alt, try readAll(fds[0], &buf));
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
        cleanup = buildStrings(.{}, &enter_buf, &cleanup_buf).cleanup;
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
    try testing.expectEqualStrings(string_terminator ++ leave_alt ++ "after1\nafter2\nafter3\n", r.term);
    // Unbuffered fd 2 arrives first; C stdio's buffer only on fflush.
    try testing.expectEqualStrings("err-text\nprintf-text\n", r.drained);
}

test "contain_stdio discard: stdio is dropped; restore puts it back" {
    if (is_windows) return error.SkipZigTest;
    var tb: [512]u8 = undefined;
    var db: [512]u8 = undefined;
    const r = try runContained(.discard, &tb, &db);
    try testing.expectEqualStrings(string_terminator ++ leave_alt ++ "after1\nafter2\nafter3\n", r.term);
    try testing.expectEqualStrings("", r.drained);
}
