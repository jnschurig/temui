//! End-to-end smoke test for `temui play` (POSIX). The built binary runs as
//! a subprocess on a pseudo-terminal: it can't run in-process, because
//! `zig build test` talks to its test runner over stdin and stdout. Nothing
//! answers the detection queries, so detection times out (about 1 s) first.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const testing = std.testing;

// libc, not `openpty`: that needs libutil on glibc 2.28.
extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;

/// Printed by the test core on load with `temui_test_stdout_marker=on`
/// (testcore/main.zig `stdout_marker`).
const marker = "temui test core: stdout marker";
const timeout_ns = 20 * std.time.ns_per_s;
/// `_IOW('t', 103, struct winsize)`; std.c lacks it for Darwin.
const tiocswinsz = if (builtin.os.tag.isDarwin()) @as(c_int, @bitCast(@as(u32, 0x80087467))) else c.T.IOCSWINSZ;

/// Bytes written to the pty once the alternate screen is up, each after
/// waiting `after_ms` from the previous step.
const Step = struct { after_ms: u32, bytes: []const u8 };

const Run = struct {
    /// The raw `waitpid` status.
    status: u32,
    /// Everything the child wrote to the terminal.
    out: std.ArrayList(u8),
    log_text: []u8,

    fn deinit(r: *Run, gpa: std.mem.Allocator) void {
        r.out.deinit(gpa);
        gpa.free(r.log_text);
    }

    fn exitCode(r: *const Run) ?u8 {
        return if (posix.W.IFEXITED(r.status)) posix.W.EXITSTATUS(r.status) else null;
    }

    fn dump(r: *const Run) void {
        std.debug.print("status {d}; pty output:\n{f}\nlog:\n{s}\n", .{ r.status, std.ascii.hexEscape(r.out.items, .lower), r.log_text });
    }
};

/// Runs `temui play` on the test core on a pty, with `extra` arguments,
/// writing `script` once the alternate screen is entered. Reads the pty
/// until the child has exited and its output is drained, so `play` never
/// blocks writing to the terminal.
fn runPlay(gpa: std.mem.Allocator, extra: []const [:0]const u8, script: []const Step) !Run {
    const o = @import("test_options");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var log_buf: [256]u8 = undefined;
    const log_path = try std.fmt.bufPrintSentinel(&log_buf, ".zig-cache/tmp/{s}/play.log", .{tmp.sub_path}, 0);

    // Everything the child needs is prepared before fork.
    const exe = try gpa.dupeSentinel(u8, o.temui_exe, 0);
    defer gpa.free(exe);
    const rom = try gpa.dupeSentinel(u8, o.testcore_rom, 0);
    defer gpa.free(rom);
    const core = try gpa.dupeSentinel(u8, o.test_core_path, 0);
    defer gpa.free(core);
    const base = [_]?[*:0]const u8{ exe, "play", rom, "--core", core, "--renderer", "ascii", "--log-file", log_path };
    var argv_buf: [base.len + 16:null]?[*:0]const u8 = undefined;
    @memcpy(argv_buf[0..base.len], &base);
    for (extra, base.len..) |a, i| argv_buf[i] = a.ptr;
    argv_buf[base.len + extra.len] = null;
    const argv: [*:null]const ?[*:0]const u8 = &argv_buf;
    const envp = [_:null]?[*:0]const u8{"TERM=xterm-256color"};

    const master = posix_openpt(@bitCast(@as(u32, @bitCast(c.O{ .ACCMODE = .RDWR, .NOCTTY = true }))));
    if (master < 0) return error.OpenPtFailed;
    defer _ = c.close(master);
    if (grantpt(master) != 0 or unlockpt(master) != 0) return error.PtyFailed;
    var slave_buf: [128]u8 = undefined;
    const slave = try std.fmt.bufPrintSentinel(&slave_buf, "{s}", .{ptsname(master) orelse return error.PtyFailed}, 0);
    var ws: c.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.close(master);
        _ = c.setsid();
        const fd = c.open(slave, .{ .ACCMODE = .RDWR });
        if (fd < 0) c._exit(120);
        _ = c.ioctl(fd, tiocswinsz, @intFromPtr(&ws));
        if (c.dup2(fd, 0) < 0 or c.dup2(fd, 1) < 0 or c.dup2(fd, 2) < 0) c._exit(121);
        if (fd > 2) _ = c.close(fd);
        _ = c.execve(exe, argv, &envp);
        c._exit(122);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var status: c_int = 0;
    var exited = false;
    const now = struct {
        fn f() i96 {
            return std.Io.Clock.awake.now(testing.io).nanoseconds;
        }
    }.f;
    const start = now();
    var next_step: usize = 0;
    // When the next script step is due; null until the alternate screen.
    var step_at: ?i96 = null;
    while (true) {
        if (now() - start > timeout_ns) {
            _ = c.kill(pid, .KILL);
            _ = c.waitpid(pid, &status, 0);
            std.debug.print("pty output so far:\n{f}\n", .{std.ascii.hexEscape(out.items, .lower)});
            return error.Timeout;
        }
        if (step_at == null and next_step < script.len and std.mem.indexOf(u8, out.items, "\x1b[?1049h") != null)
            step_at = now() + @as(i96, script[0].after_ms) * std.time.ns_per_ms;
        if (step_at) |at| if (!exited and now() >= at) {
            const b = script[next_step].bytes;
            if (c.write(master, b.ptr, b.len) != @as(isize, @intCast(b.len))) return error.WriteFailed;
            next_step += 1;
            step_at = if (next_step < script.len) now() + @as(i96, script[next_step].after_ms) * std.time.ns_per_ms else null;
        };
        var pfd = [1]c.pollfd{.{ .fd = master, .events = c.POLL.IN, .revents = 0 }};
        const ready = c.poll(&pfd, 1, 10);
        var got = false;
        if (ready > 0) {
            var buf: [4096]u8 = undefined;
            const n = c.read(master, &buf, buf.len);
            if (n > 0) {
                try out.appendSlice(gpa, buf[0..@intCast(n)]);
                got = true;
            }
        }
        if (got) continue;
        if (exited) break;
        if (c.waitpid(pid, &status, c.W.NOHANG) == pid) {
            exited = true;
            continue; // drain what's left
        }
        // The master reports a hangup (no data) while no slave is open, so
        // poll returns at once; don't spin.
        if (ready > 0) std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    if (next_step < script.len) {
        std.debug.print("exited before script step {d}\n", .{next_step});
        return error.ScriptNotFinished;
    }

    const log_text = try tmp.dir.readFileAlloc(testing.io, "play.log", gpa, .limited(1 << 20));
    return .{ .status = @bitCast(status), .out = out, .log_text = log_text };
}

test "play runs the test core on a pty for --duration and exits cleanly; core stdout goes to the log" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    // `--keyboard kitty`, for the push, pop and focus bytes: nothing
    // answers detection, so `auto` would disable game input.
    var r = try runPlay(gpa, &.{ "--duration", "1.5", "--keyboard", "kitty", "--option", "temui_test_stdout_marker=on" }, &.{});
    defer r.deinit(gpa);
    const out = r.out.items;
    if (r.exitCode() != 0) {
        r.dump();
        return error.TestUnexpectedResult;
    }

    // Alternate screen entered and left, the kitty flags pushed and popped,
    // focus reporting on and off; the core's stdout never shown.
    const enter = std.mem.indexOf(u8, out, "\x1b[?1049h") orelse return error.NoAltScreenEnter;
    const leave = std.mem.indexOf(u8, out, "\x1b[?1049l") orelse return error.NoAltScreenLeave;
    try testing.expect(enter < leave);
    try expectBetween(out, enter, leave, "\x1b[>15u");
    try expectBetween(out, enter, leave, "\x1b[?1004h");
    try expectBetween(out, enter, leave + 8, "\x1b[<u");
    try expectBetween(out, enter, leave + 8, "\x1b[?1004l");
    try testing.expect(std.mem.indexOf(u8, out, marker) == null);

    // The summary, after the terminal is restored: about 90 frames. (1.5 s,
    // so the one-second stats line is logged before the duration ends.)
    const frames = try summaryFrames(out, leave);
    if (frames < 80 or frames > 100) {
        std.debug.print("summary reports {d} frames\n", .{frames});
        return error.TestUnexpectedResult;
    }

    // The log has the per-second stats and the core's stdout.
    try expectContains(r.log_text, "info(play): stats: emu ");
    try expectContains(r.log_text, "info(core): stdio: " ++ marker);
    try expectContains(r.log_text, "info(play): keyboard: kitty (--keyboard), pushing flags 15");
    try expectContains(r.log_text, "info(play): summary: ");
}

test "play: the leader menu's quit, confirmed with Enter, quits normally" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    const t0 = std.Io.Clock.awake.now(testing.io).nanoseconds;
    // `auto`, and nothing answers detection: game input is disabled, so
    // play starts in TUI mode. Space, q, Enter.
    var r = try runPlay(gpa, &.{ "--duration", "15" }, &.{
        .{ .after_ms = 300, .bytes = " " },
        .{ .after_ms = 150, .bytes = "q" },
        .{ .after_ms = 150, .bytes = "\r" },
    });
    defer r.deinit(gpa);
    const elapsed = std.Io.Clock.awake.now(testing.io).nanoseconds - t0;
    if (r.exitCode() != 0) {
        r.dump();
        return error.TestUnexpectedResult;
    }
    // Well before --duration.
    try testing.expect(elapsed < 10 * std.time.ns_per_s);
    const leave = std.mem.indexOf(u8, r.out.items, "\x1b[?1049l") orelse return error.NoAltScreenLeave;
    _ = try summaryFrames(r.out.items, leave);
    try expectContains(r.log_text, "info(play): keyboard: disabled (no kitty keyboard protocol detected)");
    // The flag, white on red.
    try expectBetween(r.out.items, 0, leave, "\x1b[97;41mGAME MODE DISABLED\x1b[0m");
    try expectContains(r.log_text, "info(input): menu opened");
    try expectContains(r.log_text, "info(input): quit confirmed");
    if (std.mem.indexOf(u8, r.log_text, "--duration reached") != null) return error.QuitByDuration;
}

test "play: a bracketed paste is discarded; the keys after it act" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    // The paste holds the whole quit sequence and a pause; if it acted,
    // play would quit before the script ends (`ScriptNotFinished`).
    var r = try runPlay(gpa, &.{ "--duration", "15", "--verbose" }, &.{
        .{ .after_ms = 300, .bytes = "\x1b[200~ q\rp\x03\x03\x1b[201~" },
        .{ .after_ms = 300, .bytes = " " },
        .{ .after_ms = 150, .bytes = "q" },
        .{ .after_ms = 150, .bytes = "\r" },
    });
    defer r.deinit(gpa);
    if (r.exitCode() != 0) {
        r.dump();
        return error.TestUnexpectedResult;
    }
    const out = r.out.items;
    const enter = std.mem.indexOf(u8, out, "\x1b[?1049h") orelse return error.NoAltScreenEnter;
    const leave = std.mem.indexOf(u8, out, "\x1b[?1049l") orelse return error.NoAltScreenLeave;
    try expectBetween(out, enter, leave, "\x1b[?2004h");
    try expectBetween(out, enter, leave + 8, "\x1b[?2004l");
    try expectContains(r.log_text, "debug(input): paste: 6 bytes discarded");
    try testing.expectEqual(1, std.mem.count(u8, r.log_text, "info(input): menu opened"));
    if (std.mem.indexOf(u8, r.log_text, "Ctrl-C") != null) return error.PastedCtrlCActed;
}

test "play: a core stuck in retro_run quits on two Ctrl-Cs via the watchdog" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    // 30 frames is 0.5 s; the Ctrl-Cs are sent well after, so the loop is
    // stuck by then.
    var r = try runPlay(gpa, &.{ "--duration", "15", "--option", "temui_test_hang_after=30" }, &.{
        .{ .after_ms = 1800, .bytes = "\x03\x03" },
    });
    defer r.deinit(gpa);
    if (r.exitCode() != 130) {
        r.dump();
        return error.TestUnexpectedResult;
    }
    const out = r.out.items;
    const not_responding = std.mem.indexOf(u8, out, "temui: not responding; quit") orelse {
        r.dump();
        return error.NoMessage;
    };
    // The terminal restored, before the message; no summary.
    const leave = std.mem.indexOf(u8, out, "\x1b[?1049l") orelse return error.NoAltScreenLeave;
    try testing.expect(leave < not_responding);
    try testing.expect(std.mem.indexOf(u8, out, " frames in ") == null);
}

/// The frame count in the exit summary printed after `from`.
fn summaryFrames(out: []const u8, from: usize) !u64 {
    const at = std.mem.indexOfPos(u8, out, from, " frames in ") orelse return error.NoSummary;
    var i = at;
    while (i > 0 and std.ascii.isDigit(out[i - 1])) i -= 1;
    return std.fmt.parseInt(u64, out[i..at], 10);
}

/// `needle` occurs in `out[from..to]`.
fn expectBetween(out: []const u8, from: usize, to: usize, needle: []const u8) !void {
    const end = @min(to, out.len);
    if (std.mem.indexOf(u8, out[from..end], needle) != null) return;
    std.debug.print("pty output lacks {f} in [{d}, {d}):\n{f}\n", .{ std.ascii.hexEscape(needle, .lower), from, end, std.ascii.hexEscape(out, .lower) });
    return error.TestUnexpectedResult;
}

fn expectContains(log_text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, log_text, needle) != null) return;
    std.debug.print("log lacks \"{s}\":\n{s}\n", .{ needle, log_text });
    return error.TestUnexpectedResult;
}
