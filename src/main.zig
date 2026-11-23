const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cli = @import("cli.zig");
const paths = @import("paths.zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: std.Io.File.Writer = .initStreaming(.stdout(), io, &stdout_buf);
    const stdout = &stdout_fw.interface;

    const env = paths.envFromProcess(init.environ_map);
    const log_dir: []const u8 = paths.logDir(init.arena.allocator(), builtin.os.tag, env) catch |err| switch (err) {
        error.NoHomeDirectory => "(unavailable: home directory not set)",
        error.OutOfMemory => return err,
    };

    const opts = switch (cli.parse(args[1..])) {
        .ok => |o| o,
        .err => |e| {
            var stderr_buf: [512]u8 = undefined;
            var stderr_fw: std.Io.File.Writer = .initStreaming(.stderr(), io, &stderr_buf);
            try e.write(&stderr_fw.interface);
            try stderr_fw.interface.flush();
            return 2;
        },
    };

    switch (opts.command) {
        // No ROM browser yet (item 08), so bare `temui` shows usage.
        .none, .help => try cli.usage(stdout, log_dir),
        .version => try stdout.print("temui {s}\n", .{build_options.version}),
    }
    try stdout.flush();
    return 0;
}

test {
    std.testing.refAllDecls(@This());
    _ = cli;
    _ = paths;
    _ = @import("log_files.zig");
}

test "vendored libretro.h translates" {
    try std.testing.expectEqual(1, @import("libretro").RETRO_API_VERSION);
}
