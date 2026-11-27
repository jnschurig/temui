const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const paths = @import("paths.zig");
const log = @import("log.zig");
const run = @import("run.zig");
const host = @import("libretro/host.zig");
const session = @import("term/session.zig");
const detect_cmd = @import("detect_cmd.zig");
const detect = @import("term/detect.zig");
const play = @import("play.zig");

pub const std_options: std.Options = .{
    // Compile debug logging in; `log` filters by level at runtime.
    .log_level = .debug,
    .logFn = log.logFn,
};

/// Restores the terminal (if a session is active) before the default panic
/// output, so the message lands on a usable screen.
pub const panic = std.debug.FullPanic(panicRestoring);

fn panicRestoring(msg: []const u8, first_trace_addr: ?usize) noreturn {
    session.restore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: std.Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fw.interface;
    var stderr_buf: [512]u8 = undefined;
    var stderr_fw: std.Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    const env = paths.envFromProcess(init.environ_map);
    const log_dir: ?[]const u8 = paths.logDir(init.arena.allocator(), builtin.os.tag, env) catch |err| switch (err) {
        error.NoHomeDirectory => null,
        error.OutOfMemory => return err,
    };

    const opts = switch (cli.parse(args[1..])) {
        .ok => |o| o,
        .err => |e| {
            try e.write(stderr);
            try stderr.flush();
            return 2;
        },
    };

    log.init(init.gpa, io, .{
        .verbose = opts.verbose,
        .log_file = opts.log_file,
        .log_dir = log_dir,
    }) catch |err| {
        const target = opts.log_file orelse log_dir orelse "(no log directory: home directory not set)";
        try stderr.print("temui: warning: logging disabled: {t}: {s}\n", .{ err, target });
        try stderr.flush();
    };
    defer log.deinit();

    std.log.debug("temui {s} ({t}-{t}-{t}) args: {f}", .{
        build_options.version,
        builtin.cpu.arch,
        builtin.os.tag,
        builtin.abi,
        std.json.fmt(args[1..], .{}),
    });

    switch (opts.command) {
        // No ROM browser yet (item 08), so bare `temui` shows usage.
        .none, .help => try cli.usage(stdout, log_dir orelse "(unavailable: home directory not set)"),
        .version => try stdout.print("temui {s}\n", .{build_options.version}),
        .detect => {
            const arena = init.arena.allocator();
            // Windows sends no queries, so it never polls stdin.
            const code = if (comptime builtin.os.tag == .windows)
                try detect_cmd.run(arena, io, init.environ_map, opts.renderer, opts.json, stdout)
            else
                detect_cmd.run(arena, io, init.environ_map, opts.renderer, opts.json, stdout) catch |err| switch (err) {
                    error.InputNotPollable => {
                        try stderr.print("temui: {s}\n", .{detect.input_not_pollable_msg});
                        try stderr.flush();
                        return 1;
                    },
                    else => return err,
                };
            if (code != 0) return code;
        },
        .play => {
            var diag: host.Diagnostic = .{};
            var summary_buf: [256]u8 = undefined;
            var summary: std.Io.Writer = .fixed(&summary_buf);
            // Returns with the terminal restored, on success and on error.
            play.run(init.gpa, io, init.environ_map, &opts, &summary, &diag) catch |err| {
                if (err == error.Interrupted) return 130;
                const msg = if (diag.len > 0) diag.message() else @errorName(err);
                std.log.err("play failed: {s}", .{msg});
                try stderr.print("temui: {s}\n", .{msg});
                try stderr.flush();
                return 1;
            };
            try stdout.writeAll(summary.buffered());
        },
        .run => {
            var diag: host.Diagnostic = .{};
            run.run(init.gpa, io, &opts.run, stdout, stderr, &diag) catch |err| {
                const msg = if (diag.len > 0) diag.message() else @errorName(err);
                std.log.err("run failed: {s}", .{msg});
                try stdout.flush();
                try stderr.print("temui: {s}\n", .{msg});
                try stderr.flush();
                return 1;
            };
        },
    }
    try stdout.flush();
    return 0;
}

test {
    std.testing.refAllDecls(@This());
    _ = cli;
    _ = paths;
    _ = log;
    _ = @import("log_files.zig");
    _ = @import("libretro/core_log.zig");
    _ = @import("libretro/pixels.zig");
    _ = @import("libretro/env.zig");
    _ = @import("libretro/host.zig");
    _ = @import("ppm.zig");
    _ = run;
    _ = @import("term/replies.zig");
    _ = @import("term/keys.zig");
    _ = @import("term/key_decoder.zig");
    _ = @import("term/console_keys.zig");
    _ = @import("term/caps.zig");
    _ = session;
    _ = @import("term/detect.zig");
    _ = detect_cmd;
    _ = @import("render/layout.zig");
    _ = @import("render/sgr.zig");
    _ = @import("render/halfblock.zig");
    _ = @import("render/ascii.zig");
    _ = @import("render/kitty.zig");
    _ = @import("render/Renderer.zig");
    _ = @import("lib.zig");
    _ = @import("play/Pacer.zig");
    _ = @import("play/Stats.zig");
    _ = @import("play/overlay.zig");
    _ = @import("play/text.zig");
    _ = @import("play/statusline.zig");
    _ = @import("play/boxes.zig");
    _ = @import("play/TestScreen.zig");
    _ = @import("play/bindings.zig");
    _ = @import("play/FixedHold.zig");
    _ = @import("play/Modes.zig");
    _ = @import("play/stdio.zig");
    _ = @import("play/events.zig");
    _ = @import("play/Watchdog.zig");
    _ = @import("play/input_test.zig");
    _ = @import("play/Engine.zig");
    _ = @import("play/Viewer.zig");
    _ = @import("play/smoke_test.zig");
    _ = play;
}

test "vendored libretro.h translates" {
    try std.testing.expectEqual(1, @import("libretro").RETRO_API_VERSION);
}
