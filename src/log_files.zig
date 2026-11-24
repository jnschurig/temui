//! Log file names and retention.
//!
//! Names are `temui-<YYYYMMDDTHHMMSSZ>-<pid>[.<seq>].log` (seq 0 has no
//! suffix). Retention orders files by the parsed (start, pid, seq), never by
//! raw name or mtime, and only deletes files whose lock it can take without
//! blocking, so files owned by live processes survive.
//!
//! This module does not log: the logger calls `prune` while holding its own
//! lock, so `prune` reports what it did through its return value instead.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const epoch = std.time.epoch;

pub const Name = struct {
    /// Process start time, whole seconds since the Unix epoch (UTC).
    start: u64,
    pid: u32,
    seq: u32 = 0,

    /// Upper bound on a formatted name's length.
    pub const max_len = "temui-".len + "YYYYMMDDTHHMMSSZ".len + "-".len + 10 + ".".len + 10 + ".log".len;

    /// Writes the file name into `buf` and returns it.
    pub fn format(n: Name, buf: *[max_len]u8) []const u8 {
        const es: epoch.EpochSeconds = .{ .secs = n.start };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        var w: Io.Writer = .fixed(buf);
        w.print("temui-{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z-{d}", .{
            yd.year,                  md.month.numeric(),      @as(u32, md.day_index) + 1,
            ds.getHoursIntoDay(),     ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
            n.pid,
        }) catch unreachable;
        if (n.seq != 0) w.print(".{d}", .{n.seq}) catch unreachable;
        w.writeAll(".log") catch unreachable;
        return w.buffered();
    }

    /// Parses a file name produced by `format`. Anything else, including
    /// non-canonical spellings (leading zeros, `.0`, invalid dates), is null.
    pub fn parse(filename: []const u8) ?Name {
        const prefix = "temui-";
        const suffix = ".log";
        if (filename.len > max_len) return null;
        if (!std.mem.startsWith(u8, filename, prefix) or !std.mem.endsWith(u8, filename, suffix)) return null;
        const mid = filename[prefix.len .. filename.len - suffix.len];
        // YYYYMMDDTHHMMSSZ-
        if (mid.len < 17 or mid[8] != 'T' or mid[15] != 'Z' or mid[16] != '-') return null;
        const year = digits(mid[0..4]) orelse return null;
        const month = digits(mid[4..6]) orelse return null;
        const day = digits(mid[6..8]) orelse return null;
        const hour = digits(mid[9..11]) orelse return null;
        const minute = digits(mid[11..13]) orelse return null;
        const second = digits(mid[13..15]) orelse return null;
        if (year < epoch.epoch_year or month < 1 or month > 12 or day < 1 or day > 31) return null;
        if (hour > 23 or minute > 59 or second > 59) return null;

        const rest = mid[17..];
        const dot = std.mem.indexOfScalar(u8, rest, '.');
        const pid = digits(rest[0 .. dot orelse rest.len]) orelse return null;
        const seq = if (dot) |d| digits(rest[d + 1 ..]) orelse return null else 0;
        if (pid > std.math.maxInt(u32) or seq > std.math.maxInt(u32)) return null;

        const days = daysFromCivil(year, month, day);
        const n: Name = .{
            .start = days * epoch.secs_per_day + hour * 3600 + minute * 60 + second,
            .pid = @intCast(pid),
            .seq = @intCast(seq),
        };
        // Round-trip to reject non-canonical forms (Feb 30, "007", ".0", ...).
        var buf: [max_len]u8 = undefined;
        if (!std.mem.eql(u8, n.format(&buf), filename)) return null;
        return n;
    }

    /// Older first: by start time, then pid, then sequence number.
    pub fn lessThan(a: Name, b: Name) bool {
        if (a.start != b.start) return a.start < b.start;
        if (a.pid != b.pid) return a.pid < b.pid;
        return a.seq < b.seq;
    }
};

/// Parses 1–10 ASCII digits.
fn digits(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 10) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

/// Days since 1970-01-01 for a proleptic Gregorian date (year >= 1970).
/// Howard Hinnant's `days_from_civil`.
fn daysFromCivil(year: u64, month: u64, day: u64) u64 {
    const y = if (month <= 2) year - 1 else year;
    const era = y / 400;
    const yoe = y - era * 400;
    const mp = if (month > 2) month - 3 else month + 9;
    const doy = (153 * mp + 2) / 5 + day - 1;
    const doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

pub const Limits = struct {
    max_files: usize = 20,
    max_bytes: u64 = 50 * 1000 * 1000,
};

pub const PruneResult = struct {
    deleted: u32 = 0,
    /// Files that should have been deleted but were gone, locked, or could
    /// not be opened or deleted.
    skipped: u32 = 0,
};

/// Deletes the oldest log files in `dir` until at most `limits.max_files`
/// remain and their total size is at most `limits.max_bytes`. `dir` must be
/// opened with `.iterate = true`. Files whose names don't parse are ignored.
/// Per-file failures are counted in `skipped`, not returned.
pub fn prune(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, limits: Limits) !PruneResult {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Entry = struct { name: Name, file_name: []const u8, size: u64 };
    var entries: std.ArrayList(Entry) = .empty;

    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        const name = Name.parse(e.name) orelse continue;
        const st = dir.statFile(io, e.name, .{}) catch |err| switch (err) {
            error.Canceled => return err,
            else => continue, // gone or unreadable: nothing to account for
        };
        try entries.append(arena, .{ .name = name, .file_name = try arena.dupe(u8, e.name), .size = st.size });
    }

    // Newest first.
    std.mem.sortUnstable(Entry, entries.items, {}, struct {
        fn newer(_: void, a: Entry, b: Entry) bool {
            return Name.lessThan(b.name, a.name);
        }
    }.newer);

    // Keep the newest run that fits both limits; everything older goes.
    var keep: usize = 0;
    var kept_bytes: u64 = 0;
    while (keep < entries.items.len and keep < limits.max_files) : (keep += 1) {
        const size = entries.items[keep].size;
        if (kept_bytes + size > limits.max_bytes) break;
        kept_bytes += size;
    }

    var result: PruneResult = .{};
    for (entries.items[keep..]) |e| {
        if (try deleteIfUnlocked(io, dir, e.file_name)) result.deleted += 1 else result.skipped += 1;
    }
    return result;
}

/// Deletes `name` only if its exclusive lock can be taken without blocking.
/// Returns false (skipped) if it is locked, gone, or can't be deleted.
fn deleteIfUnlocked(io: Io, dir: Io.Dir, name: []const u8) Io.Cancelable!bool {
    const file = dir.openFile(io, name, .{ .lock = .exclusive, .lock_nonblocking = true }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    // Windows can't delete an open file; elsewhere delete while holding the lock.
    if (builtin.os.tag == .windows) file.close(io);
    defer if (builtin.os.tag != .windows) file.close(io);
    dir.deleteFile(io, name) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => return false,
    };
    return true;
}

const testing = std.testing;

fn expectFormat(want: []const u8, n: Name) !void {
    var buf: [Name.max_len]u8 = undefined;
    try testing.expectEqualStrings(want, n.format(&buf));
}

// 2026-11-23T22:45:46Z
const t0: u64 = 1795473946;

test "format" {
    try expectFormat("temui-20261123T224546Z-12345.log", .{ .start = t0, .pid = 12345 });
    try expectFormat("temui-20261123T224546Z-12345.1.log", .{ .start = t0, .pid = 12345, .seq = 1 });
    try expectFormat("temui-19700101T000000Z-1.log", .{ .start = 0, .pid = 1 });
    try expectFormat("temui-20240229T235959Z-4294967295.4294967295.log", .{
        .start = 1709251199,
        .pid = std.math.maxInt(u32),
        .seq = std.math.maxInt(u32),
    });
}

test "parse round-trips" {
    const cases = [_]Name{
        .{ .start = t0, .pid = 12345 },
        .{ .start = t0, .pid = 12345, .seq = 10 },
        .{ .start = 0, .pid = 1 },
        .{ .start = 1709251199, .pid = std.math.maxInt(u32), .seq = std.math.maxInt(u32) },
        .{ .start = 4102444800, .pid = 7, .seq = 2 }, // 2100-01-01, not a leap year
    };
    for (cases) |n| {
        var buf: [Name.max_len]u8 = undefined;
        try testing.expectEqual(n, Name.parse(n.format(&buf)).?);
    }
}

test "parse rejects other names" {
    const bad = [_][]const u8{
        "",
        "temui.log",
        "notes.txt",
        "temui-20261123T224546Z-12345.log.gz",
        "temui-20261123T224546Z-12345.txt",
        "xtemui-20261123T224546Z-12345.log",
        "temui-20261123T224546Z-.log",
        "temui-20261123T224546Z-12345..log",
        "temui-20261123T224546Z-12345.0.log", // seq 0 has no suffix
        "temui-20261123T224546Z-012345.log", // leading zero
        "temui-20261123T224546Z-12345.01.log",
        "temui-20261123T224546Z-4294967296.log", // pid overflows u32
        "temui-20261123T224546-12345.log",
        "temui-20261123224546Z-12345.log",
        "temui-20261323T224546Z-12345.log", // month 13
        "temui-20260230T224546Z-12345.log", // Feb 30
        "temui-20250229T000000Z-1.log", // not a leap year
        "temui-20261123T244546Z-12345.log", // hour 24
        "temui-19691231T235959Z-1.log", // before the epoch
        "temui-2026112xT224546Z-12345.log",
        "temui-20261123T224546Z-12a45.log",
        "temui-20261123T224546Z-12345.1.2.log",
    };
    for (bad) |s| {
        if (Name.parse(s) != null) {
            std.debug.print("unexpectedly parsed: {s}\n", .{s});
            return error.TestUnexpectedResult;
        }
    }
}

test "ordering by start, then pid, then seq" {
    const a = Name.parse("temui-20261123T224546Z-12345.log").?;
    const a2 = Name.parse("temui-20261123T224546Z-12345.2.log").?;
    const a10 = Name.parse("temui-20261123T224546Z-12345.10.log").?;
    const b = Name.parse("temui-20261123T224546Z-99.log").?;
    const later = Name.parse("temui-20261123T224547Z-1.log").?;
    try testing.expect(Name.lessThan(a, a2));
    try testing.expect(Name.lessThan(a2, a10));
    try testing.expect(!Name.lessThan(a10, a2));
    try testing.expect(Name.lessThan(b, a)); // same start: lower pid first
    try testing.expect(Name.lessThan(a10, later)); // start dominates pid and seq
    try testing.expect(!Name.lessThan(a, a));
}

/// Creates `name` in `dir` with `size` bytes.
fn makeFile(dir: Io.Dir, name: []const u8, size: u64) !void {
    const f = try dir.createFile(testing.io, name, .{});
    defer f.close(testing.io);
    try f.setLength(testing.io, size);
}

fn exists(dir: Io.Dir, name: []const u8) bool {
    dir.access(testing.io, name, .{}) catch return false;
    return true;
}

/// Names for `n` files of one process, oldest first: base, .1, .2, ...
fn seqName(buf: *[Name.max_len]u8, seq: u32) []const u8 {
    return (Name{ .start = t0, .pid = 42, .seq = seq }).format(buf);
}

test "prune keeps the newest max_files" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var buf: [Name.max_len]u8 = undefined;
    for (0..12) |i| try makeFile(tmp.dir, seqName(&buf, @intCast(i)), 1);

    const r = try prune(testing.allocator, testing.io, tmp.dir, .{ .max_files = 3, .max_bytes = 1000 });
    try testing.expectEqual(PruneResult{ .deleted = 9 }, r);
    // .9, .10, .11 survive: numeric, not lexical, order.
    for (0..12) |i| {
        try testing.expectEqual(i >= 9, exists(tmp.dir, seqName(&buf, @intCast(i))));
    }
}

test "prune enforces the byte limit" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeFile(tmp.dir, "temui-20261123T224546Z-1.log", 40); // oldest
    try makeFile(tmp.dir, "temui-20261123T224546Z-2.log", 10);
    try makeFile(tmp.dir, "temui-20261123T224547Z-1.log", 50);
    try makeFile(tmp.dir, "temui-20261123T224548Z-1.log", 30); // newest

    const r = try prune(testing.allocator, testing.io, tmp.dir, .{ .max_files = 20, .max_bytes = 85 });
    try testing.expectEqual(PruneResult{ .deleted = 2 }, r);
    try testing.expect(exists(tmp.dir, "temui-20261123T224548Z-1.log"));
    try testing.expect(exists(tmp.dir, "temui-20261123T224547Z-1.log"));
    try testing.expect(!exists(tmp.dir, "temui-20261123T224546Z-2.log"));
    try testing.expect(!exists(tmp.dir, "temui-20261123T224546Z-1.log"));
}

test "prune leaves non-matching files alone" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const others = [_][]const u8{ "notes.txt", "temui.log", "temui-20261123T224546Z-1.0.log", "temui-20200101T000000Z-1.log.gz" };
    for (others) |o| try makeFile(tmp.dir, o, 1000);
    try tmp.dir.createDirPath(testing.io, "temui-20200101T000000Z-9.log"); // a directory with a log-like name
    try makeFile(tmp.dir, "temui-20261123T224546Z-1.log", 1);
    try makeFile(tmp.dir, "temui-20261123T224546Z-2.log", 1);

    const r = try prune(testing.allocator, testing.io, tmp.dir, .{ .max_files = 1, .max_bytes = 10 });
    try testing.expectEqual(PruneResult{ .deleted = 1 }, r);
    for (others) |o| try testing.expect(exists(tmp.dir, o));
    try testing.expect(exists(tmp.dir, "temui-20200101T000000Z-9.log"));
    try testing.expect(exists(tmp.dir, "temui-20261123T224546Z-2.log"));
}

test "prune skips files locked by another handle" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try makeFile(tmp.dir, "temui-20261123T224546Z-1.log", 1);
    try makeFile(tmp.dir, "temui-20261123T224546Z-2.log", 1);
    try makeFile(tmp.dir, "temui-20261123T224547Z-1.log", 1);

    const held = try tmp.dir.openFile(testing.io, "temui-20261123T224546Z-1.log", .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    defer held.close(testing.io);

    const r = try prune(testing.allocator, testing.io, tmp.dir, .{ .max_files = 1, .max_bytes = 10 });
    try testing.expectEqual(PruneResult{ .deleted = 1, .skipped = 1 }, r);
    try testing.expect(exists(tmp.dir, "temui-20261123T224546Z-1.log"));
    try testing.expect(!exists(tmp.dir, "temui-20261123T224546Z-2.log"));
    try testing.expect(exists(tmp.dir, "temui-20261123T224547Z-1.log"));
}

test "prune on an empty directory" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testing.expectEqual(PruneResult{}, try prune(testing.allocator, testing.io, tmp.dir, .{}));
}
