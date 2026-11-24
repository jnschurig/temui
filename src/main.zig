const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const paths = @import("paths.zig");
const log = @import("log.zig");
const run = @import("run.zig");
const host = @import("libretro/host.zig");

pub const std_options: std.Options = .{
    // Compile debug logging in; `log` filters by level at runtime.
    .log_level = .debug,
    .logFn = log.logFn,
};

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
    _ = @import("term/caps.zig");
    _ = @import("render/layout.zig");
    _ = @import("render/sgr.zig");
    _ = @import("render/halfblock.zig");
    _ = @import("render/ascii.zig");
    _ = @import("render/kitty.zig");
    _ = @import("render/Renderer.zig");
}

test "vendored libretro.h translates" {
    try std.testing.expectEqual(1, @import("libretro").RETRO_API_VERSION);
}
