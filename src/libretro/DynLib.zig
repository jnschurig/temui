//! A loaded shared library (D3). `std.DynLib` in Zig 0.17.1 has no Windows
//! backend and drops `dlerror()`'s text, so this is the small subset temui
//! needs: open with a readable error, look up a symbol, close.

const std = @import("std");
const builtin = @import("builtin");

const DynLib = @This();

handle: *anyopaque,

pub const OpenError = error{ OpenFailed, OutOfMemory };

/// Opens the library at `path`. On failure, writes a one-line reason (without
/// the path) to `reason`. A path without a directory separator is treated as
/// relative to the working directory, never searched for on the library path.
pub fn open(gpa: std.mem.Allocator, path: []const u8, reason: *std.Io.Writer) OpenError!DynLib {
    const sep_chars = if (builtin.os.tag == .windows) "/\\" else "/";
    const prefix = if (std.mem.indexOfAny(u8, path, sep_chars) == null)
        (if (builtin.os.tag == .windows) ".\\" else "./")
    else
        "";
    const full = try std.mem.concat(gpa, u8, &.{ prefix, path });
    defer gpa.free(full);

    if (builtin.os.tag == .windows) {
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, full) catch |err| switch (err) {
            error.InvalidWtf8 => {
                reason.writeAll("invalid path encoding") catch {};
                return error.OpenFailed;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer gpa.free(wide);
        const h = win.LoadLibraryExW(wide.ptr, null, 0) orelse {
            reason.print("LoadLibrary failed: {t}", .{std.os.windows.GetLastError()}) catch {};
            return error.OpenFailed;
        };
        return .{ .handle = h };
    } else {
        const z = try gpa.dupeSentinel(u8, full, 0);
        defer gpa.free(z);
        // RTLD_LOCAL (the default): a core's symbols never leak into the next.
        const h = std.c.dlopen(z.ptr, .{ .NOW = true }) orelse {
            const msg: []const u8 = if (std.c.dlerror()) |e| std.mem.span(e) else "dlopen failed";
            // Keep the error on one line.
            for (msg) |ch| reason.writeByte(if (ch == '\n') ' ' else ch) catch {};
            return error.OpenFailed;
        };
        return .{ .handle = h };
    }
}

pub fn lookup(self: *const DynLib, name: [:0]const u8) ?*anyopaque {
    if (builtin.os.tag == .windows) return win.GetProcAddress(self.handle, name.ptr);
    // dlsym takes a hidden return-address argument on some libcs; never tail-call it.
    return @call(.never_tail, std.c.dlsym, .{ self.handle, name.ptr });
}

/// The library may stay mapped (macOS never unloads some images), so cores
/// must not rely on static initialisers running again.
pub fn close(self: *DynLib) void {
    if (builtin.os.tag == .windows) {
        _ = win.FreeLibrary(self.handle);
    } else {
        _ = std.c.dlclose(self.handle);
    }
    self.* = undefined;
}

const win = struct {
    extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) c_int;
};
