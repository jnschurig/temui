//! Default log directory per OS. Pure: the environment is passed in, so every
//! OS branch is testable on any host.

const std = @import("std");

/// The environment variables `logDir` consults. Empty strings count as unset.
pub const Env = struct {
    xdg_state_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
};

pub const Error = error{NoHomeDirectory} || std.mem.Allocator.Error;

/// Returns the default log directory for `os`, allocated with `gpa`.
/// - Linux (and other Unix): `$XDG_STATE_HOME/temui/logs`, or
///   `$HOME/.local/state/temui/logs` when `XDG_STATE_HOME` is unset, empty or
///   relative (the XDG spec says relative values are invalid).
/// - macOS: `$HOME/Library/Logs/temui`
/// - Windows: `%LOCALAPPDATA%\temui\logs`
pub fn logDir(gpa: std.mem.Allocator, os: std.Target.Os.Tag, env: Env) Error![]u8 {
    switch (os) {
        .windows => {
            const base = nonEmpty(env.local_app_data) orelse return error.NoHomeDirectory;
            return join(gpa, '\\', base, &.{ "temui", "logs" });
        },
        .macos => {
            const home = nonEmpty(env.home) orelse return error.NoHomeDirectory;
            return join(gpa, '/', home, &.{ "Library", "Logs", "temui" });
        },
        else => {
            if (nonEmpty(env.xdg_state_home)) |xdg| {
                if (xdg[0] == '/') return join(gpa, '/', xdg, &.{ "temui", "logs" });
            }
            const home = nonEmpty(env.home) orelse return error.NoHomeDirectory;
            return join(gpa, '/', home, &.{ ".local", "state", "temui", "logs" });
        },
    }
}

/// Reads the variables `logDir` needs from the process environment.
/// This is the only place that touches the real environment.
pub fn envFromProcess(map: *const std.process.Environ.Map) Env {
    return .{
        .xdg_state_home = map.get("XDG_STATE_HOME"),
        .home = map.get("HOME"),
        .local_app_data = map.get("LOCALAPPDATA"),
    };
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

/// Joins `base` and `parts` with `sep`, dropping trailing separators from
/// `base`. Uses the target's separator rather than the host's.
fn join(gpa: std.mem.Allocator, sep: u8, base: []const u8, parts: []const []const u8) Error![]u8 {
    const trimmed = std.mem.trimEnd(u8, base, if (sep == '\\') "\\/" else "/");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, trimmed);
    for (parts) |p| {
        try out.append(gpa, sep);
        try out.appendSlice(gpa, p);
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

fn expectDir(want: []const u8, os: std.Target.Os.Tag, env: Env) !void {
    const got = try logDir(testing.allocator, os, env);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "linux uses XDG_STATE_HOME when absolute" {
    try expectDir("/xdg/temui/logs", .linux, .{ .xdg_state_home = "/xdg", .home = "/home/a" });
    try expectDir("/xdg/temui/logs", .linux, .{ .xdg_state_home = "/xdg/", .home = "/home/a" });
    try expectDir("/xdg/temui/logs", .linux, .{ .xdg_state_home = "/xdg" });
}

test "linux falls back to HOME when XDG_STATE_HOME is unset, empty or relative" {
    try expectDir("/home/a/.local/state/temui/logs", .linux, .{ .home = "/home/a" });
    try expectDir("/home/a/.local/state/temui/logs", .linux, .{ .xdg_state_home = "", .home = "/home/a" });
    try expectDir("/home/a/.local/state/temui/logs", .linux, .{ .xdg_state_home = "rel/state", .home = "/home/a" });
    try expectDir("/home/a/.local/state/temui/logs", .linux, .{ .home = "/home/a/" });
}

test "linux without HOME" {
    try testing.expectError(error.NoHomeDirectory, logDir(testing.allocator, .linux, .{}));
    try testing.expectError(error.NoHomeDirectory, logDir(testing.allocator, .linux, .{ .home = "" }));
    try testing.expectError(error.NoHomeDirectory, logDir(testing.allocator, .linux, .{ .xdg_state_home = "rel" }));
}

test "macos" {
    try expectDir("/Users/a/Library/Logs/temui", .macos, .{ .home = "/Users/a", .xdg_state_home = "/xdg" });
    try testing.expectError(error.NoHomeDirectory, logDir(testing.allocator, .macos, .{}));
    try testing.expectError(error.NoHomeDirectory, logDir(testing.allocator, .macos, .{ .home = "" }));
}

test "windows" {
    try expectDir("C:\\Users\\a\\AppData\\Local\\temui\\logs", .windows, .{ .local_app_data = "C:\\Users\\a\\AppData\\Local" });
    try expectDir("C:\\L\\temui\\logs", .windows, .{ .local_app_data = "C:\\L\\" });
    try testing.expectError(error.NoHomeDirectory, logDir(testing.allocator, .windows, .{ .home = "C:\\Users\\a" }));
    try testing.expectError(error.NoHomeDirectory, logDir(testing.allocator, .windows, .{ .local_app_data = "" }));
}

test "envFromProcess" {
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();
    try map.put("HOME", "/h");
    try map.put("LOCALAPPDATA", "C:\\L");
    const env = envFromProcess(&map);
    try testing.expectEqualStrings("/h", env.home.?);
    try testing.expectEqualStrings("C:\\L", env.local_app_data.?);
    try testing.expectEqual(null, env.xdg_state_home);
}
