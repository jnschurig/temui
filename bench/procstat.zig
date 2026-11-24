//! Finds the terminal's processes and samples their CPU time (macOS libproc,
//! no subprocesses), and this process's own CPU time (any POSIX). Ported
//! from `spikes/termbench/procstat.zig`. On other systems terminal CPU is
//! not measured: `discover` finds nothing.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const is_macos = builtin.os.tag == .macos;

extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_name(pid: c_int, buffer: *anyopaque, buffersize: u32) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, buffersize: c_int) c_int;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *anyopaque) c_int;

/// Unlike PROC_PIDTBSDINFO and proc_name, this works for root-owned
/// processes such as `login`, which sits between a terminal and its shell.
const PROC_PIDT_SHORTBSDINFO = 13;
const RUSAGE_INFO_V2 = 2;

/// `struct proc_bsdshortinfo` (64 bytes).
const ShortInfo = extern struct {
    pid: u32,
    ppid: u32,
    pgid: u32,
    status: u32,
    comm: [16]u8,
    _rest: [64 - 32]u8,
};

/// `struct rusage_info_v2` (160 bytes); times are Mach absolute-time ticks.
const RusageV2 = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    _rest: [160 - 32]u8,
};

comptime {
    std.debug.assert(@sizeOf(ShortInfo) == 64 and @offsetOf(ShortInfo, "comm") == 16);
    std.debug.assert(@sizeOf(RusageV2) == 160 and @offsetOf(RusageV2, "user_time") == 16);
}

pub const Proc = struct { pid: i32, name: []const u8 };

pub const Method = enum {
    /// `--term-pid`.
    cli,
    /// A known terminal among the bench's ancestors (plus its companions).
    known_ancestor,
    /// The first ancestor that isn't a shell or login.
    ancestor,
    none,
};

pub const Discovery = struct { method: Method, procs: []const Proc };

/// Process names of known terminals. The first ancestor with `name` is the
/// PTY owner; `companions` are other processes of the same terminal found
/// by exact name (Rex: the server owns the PTY, the app renders).
const Known = struct { name: []const u8, companions: []const []const u8 };
const known = [_]Known{
    .{ .name = "ghostty", .companions = &.{} },
    .{ .name = "rex", .companions = &.{"Rex"} },
};

/// Skipped by the ancestry fallback.
const not_terminals = [_][]const u8{ "zsh", "bash", "sh", "dash", "fish", "nu", "login", "sudo", "su", "env" };

fn shortInfo(pid: i32) ?ShortInfo {
    var info: ShortInfo = undefined;
    const n = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, @sizeOf(ShortInfo));
    if (n != @sizeOf(ShortInfo)) return null;
    return info;
}

/// Process name (`p_name`, else the 16-byte `p_comm` for processes we may
/// not inspect fully), or null if the process is gone.
pub fn name(pid: i32, buf: *[64]u8) ?[]const u8 {
    const n = proc_name(pid, buf, buf.len);
    if (n > 0) return buf[0..@intCast(n)];
    const info = shortInfo(pid) orelse return null;
    const len = std.mem.indexOfScalar(u8, &info.comm, 0) orelse info.comm.len;
    @memcpy(buf[0..len], info.comm[0..len]);
    return buf[0..len];
}

pub fn parent(pid: i32) ?i32 {
    return @intCast((shortInfo(pid) orelse return null).ppid);
}

pub fn discover(arena: std.mem.Allocator, override: []const i32) !Discovery {
    if (comptime is_macos) return discoverMacos(arena, override);
    return .{ .method = .none, .procs = &.{} };
}

fn discoverMacos(arena: std.mem.Allocator, override: []const i32) !Discovery {
    var procs: std.ArrayList(Proc) = .empty;
    var buf: [64]u8 = undefined;
    if (override.len > 0) {
        for (override) |pid| try procs.append(arena, .{ .pid = pid, .name = try arena.dupe(u8, name(pid, &buf) orelse "?") });
        return .{ .method = .cli, .procs = procs.items };
    }

    var fallback: ?Proc = null;
    var pid: i32 = c.getppid();
    var depth: usize = 0;
    while (pid > 1 and depth < 64) : (depth += 1) {
        const n = name(pid, &buf) orelse break;
        for (known) |k| {
            if (!std.mem.eql(u8, n, k.name)) continue;
            try procs.append(arena, .{ .pid = pid, .name = try arena.dupe(u8, n) });
            for (k.companions) |comp| try appendByName(arena, &procs, comp);
            return .{ .method = .known_ancestor, .procs = procs.items };
        }
        if (fallback == null and !isNotTerminal(n)) fallback = .{ .pid = pid, .name = try arena.dupe(u8, n) };
        pid = parent(pid) orelse break;
    }
    if (fallback) |f| {
        try procs.append(arena, f);
        return .{ .method = .ancestor, .procs = procs.items };
    }
    return .{ .method = .none, .procs = &.{} };
}

fn isNotTerminal(n: []const u8) bool {
    const bare = std.mem.trimStart(u8, n, "-");
    for (not_terminals) |s| if (std.mem.eql(u8, bare, s)) return true;
    return false;
}

fn appendByName(arena: std.mem.Allocator, procs: *std.ArrayList(Proc), want: []const u8) !void {
    var pids: [8192]c_int = undefined;
    const n = proc_listallpids(&pids, @sizeOf(@TypeOf(pids)));
    if (n <= 0) return;
    var buf: [64]u8 = undefined;
    for (pids[0..@min(@as(usize, @intCast(n)), pids.len)]) |pid| {
        const pn = name(pid, &buf) orelse continue;
        if (std.mem.eql(u8, pn, want)) try procs.append(arena, .{ .pid = pid, .name = try arena.dupe(u8, pn) });
    }
}

var timebase: std.atomic.Value(u64) = .init(0);

fn ticksToNs(ticks: u64) u64 {
    var tb = timebase.load(.monotonic);
    if (tb == 0) {
        var info: c.mach_timebase_info_data = undefined;
        _ = c.mach_timebase_info(&info);
        tb = (@as(u64, info.numer) << 32) | info.denom;
        timebase.store(tb, .monotonic);
    }
    const numer: u128 = tb >> 32;
    const denom: u128 = tb & 0xffff_ffff;
    return @intCast(@as(u128, ticks) * numer / denom);
}

/// User+system CPU of `pids` in ns. Processes that exited count as 0, so
/// compare samples of the same pid set.
pub fn cpuNs(pids: []const Proc) u64 {
    if (comptime !is_macos) return 0;
    var total: u64 = 0;
    for (pids) |p| {
        var ru: RusageV2 = undefined;
        if (proc_pid_rusage(p.pid, RUSAGE_INFO_V2, &ru) != 0) continue;
        total += ticksToNs(ru.user_time + ru.system_time);
    }
    return total;
}

/// This process's user+system CPU in ns (all threads); 0 on Windows.
pub fn selfCpuNs() u64 {
    if (comptime builtin.os.tag == .windows) return 0;
    var ru: c.rusage = undefined;
    _ = c.getrusage(c.rusage.SELF, &ru);
    const us = (@as(u64, @intCast(ru.utime.sec)) + @as(u64, @intCast(ru.stime.sec))) * std.time.us_per_s +
        @as(u64, @intCast(ru.utime.usec)) + @as(u64, @intCast(ru.stime.usec));
    return us * std.time.ns_per_us;
}

// ---- tests ----

const testing = std.testing;

fn spin(ms: u64) void {
    const end = nowNs() + ms * std.time.ns_per_ms;
    var x: u64 = 0;
    while (nowNs() < end) {
        x +%= 1;
        std.mem.doNotOptimizeAway(x);
    }
}

fn nowNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "cpu time of this process increases after a busy loop" {
    if (!is_macos) return error.SkipZigTest;
    const me = [_]Proc{.{ .pid = c.getpid(), .name = "self" }};
    const a = cpuNs(&me);
    const s0 = selfCpuNs();
    spin(50);
    const b = cpuNs(&me);
    const s1 = selfCpuNs();
    try testing.expect(b - a >= 30 * std.time.ns_per_ms);
    try testing.expect(s1 - s0 >= 30 * std.time.ns_per_ms);
    // Both clocks agree within a few ms.
    const d: i64 = @as(i64, @intCast(b - a)) - @as(i64, @intCast(s1 - s0));
    try testing.expect(@abs(d) < 10 * std.time.ns_per_ms);
}

test "names, parents, overrides" {
    if (!is_macos) return error.SkipZigTest;
    var buf: [64]u8 = undefined;
    try testing.expect(name(c.getpid(), &buf) != null);
    try testing.expectEqual(@as(?i32, c.getppid()), parent(c.getpid()));
    try testing.expectEqual(@as(?[]const u8, null), name(-5, &buf));
    // launchd is root-owned: proc_name fails, the short-info fallback works.
    try testing.expectEqualStrings("launchd", name(1, &buf).?);
    try testing.expectEqual(@as(?i32, 0), parent(1));

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const d = try discover(arena.allocator(), &.{c.getpid()});
    try testing.expectEqual(Method.cli, d.method);
    try testing.expectEqual(@as(usize, 1), d.procs.len);
    const auto = try discover(arena.allocator(), &.{});
    try testing.expect(auto.method != .cli);
}

test "shells and login are skipped by the fallback" {
    try testing.expect(isNotTerminal("-zsh"));
    try testing.expect(isNotTerminal("login"));
    try testing.expect(!isNotTerminal("ghostty"));
}
