//! File logging (D13). Never writes to stdout or stderr: stdout carries the
//! terminal graphics. `main` reports setup failures itself.
//!
//! Managed mode (default) writes one file per process into the log directory,
//! rolls to `.1.log`, `.2.log`, ... at `roll_bytes`, and prunes the directory
//! at startup and on each roll. Explicit mode (`--log-file`) appends to one
//! path with no rolling or pruning. Every file is held with a non-blocking
//! exclusive lock while open, which is what keeps other processes' pruners
//! away from it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const epoch = std.time.epoch;
const log_files = @import("log_files.zig");

pub const default_roll_bytes: u64 = 5 * 1000 * 1000;

pub const Logger = struct {
    io: Io,
    gpa: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    /// Messages less severe than this are dropped.
    level: std.log.Level,
    /// null once logging has stopped (closed, or a write failed).
    file: ?Io.File = null,
    writer: Io.File.Writer = undefined,
    buf: [4096]u8 = undefined,
    mode: Mode,

    pub const Mode = union(enum) {
        managed: Managed,
        explicit,
    };

    pub const Managed = struct {
        dir: Io.Dir,
        name: log_files.Name,
        roll_bytes: u64 = default_roll_bytes,
        limits: log_files.Limits = .{},
    };

    /// Creates and locks the first file in `m.dir` (which must be opened with
    /// `.iterate = true` and outlive the logger), then prunes the directory.
    /// `m.name.seq` is bumped past any existing file with the same name.
    pub fn openManaged(self: *Logger, gpa: std.mem.Allocator, io: Io, level: std.log.Level, m: Managed) !void {
        self.* = .{ .io = io, .gpa = gpa, .level = level, .mode = .{ .managed = m } };
        try self.createNext();
        self.prune();
    }

    /// Opens (creating if needed) `sub_path` relative to `dir` and appends to it.
    pub fn openExplicit(self: *Logger, io: Io, level: std.log.Level, dir: Io.Dir, sub_path: []const u8) !void {
        self.* = .{ .io = io, .gpa = undefined, .level = level, .mode = .explicit };
        const file = try dir.createFile(io, sub_path, .{
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
        });
        errdefer file.close(io);
        const len = try file.length(io);
        self.attach(file, len);
    }

    pub fn close(self: *Logger) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.closeFile();
    }

    pub fn enabled(self: *const Logger, level: std.log.Level) bool {
        return @backingInt(level) <= @backingInt(self.level);
    }

    pub fn log(
        self: *Logger,
        comptime level: std.log.Level,
        comptime scope: @EnumLiteral(),
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (!self.enabled(level)) return;
        const io = self.io;
        const prev = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(prev);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.file == null) return;
        const now = Io.Clock.real.now(io);
        self.writeLine(now, level, scope, format, args);
        self.maybeRoll();
    }

    // Everything below runs with the mutex held (or before the logger is shared).

    fn attach(self: *Logger, file: Io.File, offset: u64) void {
        self.file = file;
        // Positional, starting at the current end, so explicit mode appends.
        self.writer = .init(file, self.io, &self.buf);
        self.writer.pos = offset;
    }

    fn closeFile(self: *Logger) void {
        const file = self.file orelse return;
        self.writer.interface.flush() catch {};
        file.close(self.io);
        self.file = null;
    }

    /// Writes one line and flushes it, so a crash loses at most the line
    /// being written. A write failure stops logging: there is nowhere left
    /// to report it.
    fn writeLine(
        self: *Logger,
        now: Io.Timestamp,
        comptime level: std.log.Level,
        comptime scope: @EnumLiteral(),
        comptime format: []const u8,
        args: anytype,
    ) void {
        const w = &self.writer.interface;
        formatLine(w, now, level, scope, format, args) catch return self.closeFile();
        w.flush() catch return self.closeFile();
    }

    fn maybeRoll(self: *Logger) void {
        const m = switch (self.mode) {
            .managed => |*m| m,
            .explicit => return,
        };
        if (self.writer.logicalPos() < m.roll_bytes) return;
        self.closeFile();
        m.name.seq += 1;
        self.createNext() catch return; // logging stops; nowhere to report it
        self.prune();
    }

    /// Creates the file for `mode.managed.name`, bumping `seq` past names
    /// that already exist (e.g. a reused pid within the same second).
    fn createNext(self: *Logger) !void {
        const m = &self.mode.managed;
        var attempts: u32 = 0;
        while (true) : (attempts += 1) {
            var name_buf: [log_files.Name.max_len]u8 = undefined;
            const name = m.name.format(&name_buf);
            const file = m.dir.createFile(self.io, name, .{
                .exclusive = true,
                .lock = .exclusive,
                .lock_nonblocking = true,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => if (attempts < 100) {
                    m.name.seq += 1;
                    continue;
                } else return err,
                else => return err,
            };
            self.attach(file, 0);
            return;
        }
    }

    /// Prunes the managed directory and records the outcome in the log.
    /// Uses `writeLine` directly: `log` would deadlock on the mutex.
    fn prune(self: *Logger) void {
        const m = &self.mode.managed;
        const now = Io.Clock.real.now(self.io);
        const r = log_files.prune(self.gpa, self.io, m.dir, m.limits) catch |err| {
            if (self.enabled(.warn)) self.writeLine(now, .warn, .log, "pruning log directory failed: {t}", .{err});
            return;
        };
        if (r.deleted != 0 or r.skipped != 0) {
            if (self.enabled(.debug)) self.writeLine(now, .debug, .log, "pruned log directory: {d} deleted, {d} skipped", .{ r.deleted, r.skipped });
        }
    }
};

/// `2026-11-23T22:45:46.123Z info(scope): message\n`
pub fn formatLine(
    w: *Io.Writer,
    now: Io.Timestamp,
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) Io.Writer.Error!void {
    try writeTimestamp(w, now);
    try w.writeAll(" " ++ comptime level.asText() ++ "(" ++ @tagName(scope) ++ "): ");
    try w.print(format, args);
    try w.writeByte('\n');
}

/// ISO 8601 UTC with milliseconds. Times before the epoch clamp to it.
fn writeTimestamp(w: *Io.Writer, now: Io.Timestamp) Io.Writer.Error!void {
    const ns: u96 = if (now.nanoseconds < 0) 0 else @intCast(now.nanoseconds);
    const es: epoch.EpochSeconds = .{ .secs = @intCast(ns / std.time.ns_per_s) };
    const ms: u32 = @intCast(ns / std.time.ns_per_ms % 1000);
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year,              md.month.numeric(),      @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        ms,
    });
}

// Process-wide logger, installed by `main` via `std_options.logFn`.

var global: Logger = undefined;
var global_active: bool = false;
var global_dir: ?Io.Dir = null;

pub const Options = struct {
    verbose: bool = false,
    /// `--log-file`: append to this path instead of the managed directory.
    log_file: ?[]const u8 = null,
    /// The managed directory; null when it couldn't be determined.
    log_dir: ?[]const u8 = null,
};

/// Starts process-wide logging. On error logging stays disabled; the caller
/// reports it (once, on stderr).
pub fn init(gpa: std.mem.Allocator, io: Io, opts: Options) !void {
    const level: std.log.Level = if (opts.verbose) .debug else .info;
    if (opts.log_file) |path| {
        try global.openExplicit(io, level, .cwd(), path);
    } else {
        const path = opts.log_dir orelse return error.NoLogDirectory;
        try Io.Dir.cwd().createDirPath(io, path);
        const dir = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        errdefer dir.close(io);
        const start = Io.Clock.real.now(io).nanoseconds;
        try global.openManaged(gpa, io, level, .{
            .dir = dir,
            .name = .{ .start = @intCast(@divFloor(@max(start, 0), std.time.ns_per_s)), .pid = pid() },
        });
        global_dir = dir;
    }
    global_active = true;
}

/// Flushes and closes the log file.
pub fn deinit() void {
    if (!global_active) return;
    global_active = false;
    global.close();
    if (global_dir) |d| d.close(global.io);
    global_dir = null;
}

/// `std_options.logFn`. Drops messages until `init` succeeds.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!global_active) return;
    global.log(level, scope, format, args);
}

fn pid() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}

const testing = std.testing;

test "formatLine" {
    var buf: [128]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    // 2026-11-23T22:45:46.123Z
    const now: Io.Timestamp = .{ .nanoseconds = 1795473946 * std.time.ns_per_s + 123_456_789 };
    try formatLine(&w, now, .info, .cli, "hello {s}", .{"world"});
    try testing.expectEqualStrings("2026-11-23T22:45:46.123Z info(cli): hello world\n", w.buffered());

    w = .fixed(&buf);
    try formatLine(&w, .{ .nanoseconds = 0 }, .debug, .default, "x", .{});
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z debug(default): x\n", w.buffered());
}

/// The parsed names of all log files in `dir`, oldest first.
fn listLogs(dir: Io.Dir, out: []log_files.Name) ![]log_files.Name {
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(testing.io)) |e| {
        const name = log_files.Name.parse(e.name) orelse continue;
        out[n] = name;
        n += 1;
    }
    std.mem.sortUnstable(log_files.Name, out[0..n], {}, struct {
        fn lt(_: void, a: log_files.Name, b: log_files.Name) bool {
            return a.lessThan(b);
        }
    }.lt);
    return out[0..n];
}

test "managed mode rolls at the cap and prunes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var l: Logger = undefined;
    try l.openManaged(testing.allocator, testing.io, .info, .{
        .dir = tmp.dir,
        .name = .{ .start = 1795473946, .pid = 42 },
        .roll_bytes = 100,
        .limits = .{ .max_files = 3, .max_bytes = 1 << 20 },
    });
    defer l.close();

    // Each line is ~60 bytes, so every second line rolls.
    for (0..8) |i| l.log(.info, .t, "line {d} padding padding", .{i});
    l.log(.debug, .t, "dropped: below the level", .{});

    var names: [16]log_files.Name = undefined;
    const got = try listLogs(tmp.dir, &names);
    // seq 0..4 were written; pruning kept the newest 3.
    try testing.expectEqual(3, got.len);
    for (got, 2..) |n, seq| {
        try testing.expectEqual(42, n.pid);
        try testing.expectEqual(seq, n.seq);
    }

    var buf: [log_files.Name.max_len]u8 = undefined;
    const content = try tmp.dir.readFileAlloc(testing.io, got[0].format(&buf), testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, " info(t): line 4 ") != null);
    try testing.expect(std.mem.indexOf(u8, content, "dropped") == null);
}

test "managed mode skips an existing name" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    (try tmp.dir.createFile(testing.io, "temui-20261123T224546Z-42.log", .{})).close(testing.io);
    var l: Logger = undefined;
    try l.openManaged(testing.allocator, testing.io, .info, .{ .dir = tmp.dir, .name = .{ .start = 1795473946, .pid = 42 } });
    defer l.close();
    try testing.expectEqual(1, l.mode.managed.name.seq);
}

test "explicit mode appends and never rolls" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "x.log", .data = "existing\n" });
    var l: Logger = undefined;
    try l.openExplicit(testing.io, .debug, tmp.dir, "x.log");
    for (0..2000) |i| l.log(.debug, .t, "line {d}", .{i});
    l.close();

    const content = try tmp.dir.readFileAlloc(testing.io, "x.log", testing.allocator, .unlimited);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.startsWith(u8, content, "existing\n"));
    try testing.expectEqual(2001, std.mem.count(u8, content, "\n"));

    var names: [4]log_files.Name = undefined;
    try testing.expectEqual(0, (try listLogs(tmp.dir, &names)).len);
}

test "explicit mode refuses a file another handle has locked" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const held = try tmp.dir.createFile(testing.io, "x.log", .{ .lock = .exclusive });
    defer held.close(testing.io);
    var l: Logger = undefined;
    try testing.expectError(error.WouldBlock, l.openExplicit(testing.io, .info, tmp.dir, "x.log"));
}
