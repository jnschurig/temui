//! termbench: roadmap item 02's throwaway terminal-graphics benchmark.
//! See docs/spikes/02-terminal-graphics.md. macOS only.
//!
//! stdout carries the frames, so logs go to a file (D13); the human-readable
//! summary is printed only after the terminal is restored.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const log = @import("log");
const paths = @import("paths");
const cli = @import("cli.zig");
const term = @import("term.zig");
const detect = @import("detect.zig");
const reader = @import("reader.zig");
const replies = @import("replies.zig");
const util = @import("util.zig");
const procstat = @import("procstat.zig");
const run = @import("run.zig");

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log.logFn,
};

/// Restore the terminal (raw mode, alt screen) before printing the panic.
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, ra: ?usize) noreturn {
        term.restore();
        std.debug.defaultPanic(msg, ra);
    }
}.f);

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [8192]u8 = undefined;
    var out_fw: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_fw.interface;
    var err_buf: [512]u8 = undefined;
    var err_fw: std.Io.File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const stderr = &err_fw.interface;

    const opts = switch (cli.parse(args[1..])) {
        .ok => |o| o,
        .err => |e| {
            try e.write(stderr);
            try stderr.flush();
            return 2;
        },
    };
    if (opts.command == .help) {
        try cli.usage(out);
        try out.flush();
        return 0;
    }

    const env = paths.envFromProcess(init.environ_map);
    const log_dir: ?[]const u8 = paths.logDir(arena, builtin.os.tag, env) catch null;
    log.init(init.gpa, io, .{ .verbose = opts.verbose, .log_file = opts.log_file, .log_dir = log_dir }) catch |err| {
        try stderr.print("termbench: warning: logging disabled: {t}\n", .{err});
        try stderr.flush();
    };
    defer log.deinit();
    std.log.info("termbench ({s}) args: {f}", .{ build_options.optimize, std.json.fmt(args[1..], .{}) });

    if (opts.command == .procs) return runProcs(arena, opts, out);

    _ = term.size() catch {
        try stderr.writeAll("termbench: stdout is not a terminal\n");
        try stderr.flush();
        return 1;
    };

    try term.enter();
    defer term.restore();

    switch (opts.command) {
        .help, .procs => unreachable,
        .detect => return runDetect(io, arena, init.environ_map, opts, out),
        .run => return run.main(io, init.gpa, arena, init.environ_map, opts, out),
    }
}

fn runProcs(arena: std.mem.Allocator, opts: cli.Options, out: *std.Io.Writer) !u8 {
    const d = try procstat.discover(arena, opts.term_pids[0..opts.term_pid_count]);
    std.log.info("procs: {f}", .{std.json.fmt(d, .{})});
    try out.print("method: {t}\n", .{d.method});
    for (d.procs) |p| try out.print("  {d}  {s}\n", .{ p.pid, p.name });
    const a = procstat.cpuNs(d.procs);
    term.sleepNs(std.time.ns_per_s);
    const b = procstat.cpuNs(d.procs);
    try out.print("terminal CPU over 1 s: {d:.1}%\n", .{@as(f64, @floatFromInt(b - a)) / std.time.ns_per_s * 100});
    try out.flush();
    return if (d.procs.len == 0) 1 else 0;
}

fn runDetect(io: std.Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map, opts: cli.Options, out: *std.Io.Writer) !u8 {
    const r = detect.probe(arena, env) catch |err| {
        term.restore();
        std.log.err("detect failed: {t}", .{err});
        try out.print("termbench: detect failed: {t}\n", .{err});
        try out.flush();
        return 1;
    };
    term.restore();
    std.log.info("detect: {f}", .{std.json.fmt(r, .{})});

    var name_buf: [32]u8 = undefined;
    var stamp_buf: [16]u8 = undefined;
    const path = opts.out orelse try std.fmt.allocPrint(arena, "termbench-detect-{s}-{s}.json", .{
        r.terminalName(&name_buf), util.utcStamp(io, &stamp_buf),
    });
    try detect.printSummary(out, r);
    util.writeJsonFile(io, path, r) catch |err| {
        try out.print("\ntermbench: could not write {s}: {t}\n", .{ path, err });
        try out.flush();
        return 1;
    };
    try out.print("\nresults: {s}\n", .{path});
    try out.flush();
    return 0;
}

test {
    _ = cli;
    _ = term;
    _ = replies;
    _ = reader;
    _ = detect;
    _ = util;
    _ = procstat;
    _ = run;
    _ = @import("scene.zig");
    _ = @import("stats.zig");
    _ = @import("kitty.zig");
    _ = @import("halfblock.zig");
}
