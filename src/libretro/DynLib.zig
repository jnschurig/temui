//! A loaded shared library (D3). `std.DynLib` in Zig 0.17.1 has no Windows
//! backend and drops `dlerror()`'s text, so this is the small subset temui
//! needs: open with a readable error, look up a symbol, close.

const std = @import("std");
const builtin = @import("builtin");

const DynLib = @This();

handle: *anyopaque,

pub const OpenError = error{ OpenFailed, OutOfMemory };

/// Opens the library at `path`. On failure, writes a one-line reason (without
/// the path) to `reason`. The path is made absolute first, so the platform
/// loader never searches its library path for it (dyld would, even for a
/// relative path with a slash).
pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8, reason: *std.Io.Writer) OpenError!DynLib {
    const full = std.Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            reason.print("{t}", .{err}) catch {};
            return error.OpenFailed;
        },
    };
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
        // The core's own DLL dependencies are searched for next to it.
        const h = win.LoadLibraryExW(wide.ptr, null, LOAD_WITH_ALTERED_SEARCH_PATH) orelse {
            reason.print("LoadLibrary failed: {t}", .{std.os.windows.GetLastError()}) catch {};
            return error.OpenFailed;
        };
        return .{ .handle = h };
    } else {
        // RTLD_LOCAL: a core's symbols never leak into the next. It is the
        // default on glibc (whose RTLD has no LOCAL field) but not on macOS.
        var flags: std.c.RTLD = .{ .NOW = true };
        if (@hasField(std.c.RTLD, "LOCAL")) flags.LOCAL = true;
        const h = std.c.dlopen(full.ptr, flags) orelse {
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

const LOAD_WITH_ALTERED_SEARCH_PATH = 0x8;

const win = struct {
    extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) c_int;
};
