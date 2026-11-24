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

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log.logFn,
};

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

    _ = term.size() catch {
        try stderr.writeAll("termbench: stdout is not a terminal\n");
        try stderr.flush();
        return 1;
    };

    try term.enter();
    defer term.restore();

    // Placeholder until the run loop exists (step 6).
    term.writeAll("termbench skeleton: press any key\r\n");
    var b: [16]u8 = undefined;
    _ = std.c.read(term.stdin_fd, &b, b.len);
    return 0;
}

test {
    _ = cli;
    _ = term;
}
