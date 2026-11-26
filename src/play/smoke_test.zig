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

test "play runs the test core on a pty for --duration and exits cleanly; core stdout goes to the log" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const o = @import("test_options");
    const gpa = testing.allocator;

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
    const argv = [_:null]?[*:0]const u8{
        exe,
        "play",
        rom,
        "--core",
        core,
        "--duration",
        "1.5",
        "--renderer",
        "ascii",
        "--log-file",
        log_path,
        "--option",
        "temui_test_stdout_marker=on",
    };
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
        _ = c.execve(exe, &argv, &envp);
        c._exit(122);
    }

    // Read the master side until the child has exited and its output is
    // drained, so `play` never blocks writing to the terminal.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var status: c_int = 0;
    var exited = false;
    const start = std.Io.Clock.awake.now(testing.io).nanoseconds;
    while (true) {
        if (std.Io.Clock.awake.now(testing.io).nanoseconds - start > timeout_ns) {
            _ = c.kill(pid, .KILL);
            _ = c.waitpid(pid, &status, 0);
            std.debug.print("pty output so far:\n{f}\n", .{std.ascii.hexEscape(out.items, .lower)});
            return error.Timeout;
        }
        var pfd = [1]c.pollfd{.{ .fd = master, .events = c.POLL.IN, .revents = 0 }};
        const ready = c.poll(&pfd, 1, 50);
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

    const st: u32 = @bitCast(status);
    if (!posix.W.IFEXITED(st) or posix.W.EXITSTATUS(st) != 0) {
        std.debug.print("status {d}; pty output:\n{f}\n", .{ st, std.ascii.hexEscape(out.items, .lower) });
        return error.TestUnexpectedResult;
    }

    // Alternate screen entered and left; the core's stdout never shown.
    const enter = std.mem.indexOf(u8, out.items, "\x1b[?1049h") orelse return error.NoAltScreenEnter;
    const leave = std.mem.indexOf(u8, out.items, "\x1b[?1049l") orelse return error.NoAltScreenLeave;
    try testing.expect(enter < leave);
    try testing.expect(std.mem.indexOf(u8, out.items, marker) == null);

    // The summary, after the terminal is restored: about 90 frames. (1.5 s,
    // so the one-second stats line is logged before the duration ends.)
    const at = std.mem.indexOfPos(u8, out.items, leave, " frames in ") orelse return error.NoSummary;
    var i = at;
    while (i > 0 and std.ascii.isDigit(out.items[i - 1])) i -= 1;
    const frames = try std.fmt.parseInt(u64, out.items[i..at], 10);
    if (frames < 80 or frames > 100) {
        std.debug.print("summary reports {d} frames\n", .{frames});
        return error.TestUnexpectedResult;
    }

    // The log has the per-second stats and the core's stdout.
    const log_text = try tmp.dir.readFileAlloc(testing.io, "play.log", gpa, .limited(1 << 20));
    defer gpa.free(log_text);
    try expectContains(log_text, "info(play): stats: emu ");
    try expectContains(log_text, "info(core): stdio: " ++ marker);
    try expectContains(log_text, "info(play): summary: ");
}

fn expectContains(log_text: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, log_text, needle) != null) return;
    std.debug.print("log lacks \"{s}\":\n{s}\n", .{ needle, log_text });
    return error.TestUnexpectedResult;
}
