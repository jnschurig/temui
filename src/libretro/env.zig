//! Pure helpers for the environment callback: command names, the core option
//! store, and the log-once set. No I/O; the host does the logging.

const std = @import("std");
const c = @import("libretro");

const prefix = "RETRO_ENVIRONMENT_";

const Entry = struct { cmd: c_uint, name: []const u8 };

/// Every `RETRO_ENVIRONMENT_*` command in the vendored header, by number.
/// Built at comptime from the translated declarations, so it follows the
/// header. Experimental commands carry the 0x10000 bit in their number.
const table = blk: {
    @setEvalBranchQuota(100_000);
    const decls = std.meta.declarations(c);
    var entries: [decls.len]Entry = undefined;
    var n: usize = 0;
    for (decls) |decl_name| {
        if (!std.mem.startsWith(u8, decl_name, prefix)) continue;
        const short = decl_name[prefix.len..];
        // Flag bits, not commands.
        if (std.mem.eql(u8, short, "EXPERIMENTAL") or std.mem.eql(u8, short, "PRIVATE")) continue;
        const cmd: c_uint = @intCast(@field(c, decl_name));
        // Keep the first name for a number, should an alias ever appear.
        for (entries[0..n]) |e| {
            if (e.cmd == cmd) break;
        } else {
            entries[n] = .{ .cmd = cmd, .name = short };
            n += 1;
        }
    }
    const final = entries[0..n].*;
    break :blk final;
};

/// The command's name without the `RETRO_ENVIRONMENT_` prefix, or null for a
/// number the header doesn't define.
pub fn name(cmd: c_uint) ?[]const u8 {
    for (table) |e| {
        if (e.cmd == cmd) return e.name;
    }
    return null;
}

/// A `--option key=value` override.
pub const Override = struct { key: []const u8, value: []const u8 };

/// Core options in the legacy `SET_VARIABLES` format ("Description; a|b|c",
/// default first). Overrides are fixed before load; declarations arrive during
/// load. Every string handed to the core lives until `deinit` (unload).
pub const Options = struct {
    arena: std.heap.ArenaAllocator,
    overrides: []const Override,
    declared: std.ArrayList(Declared) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,

    const Declared = struct { key: []const u8, values: []const [:0]const u8 };

    /// Copies `overrides`.
    pub fn init(gpa: std.mem.Allocator, overrides: []const Override) !Options {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const copy = try a.alloc(Override, overrides.len);
        for (overrides, copy) |o, *dst| dst.* = .{ .key = try a.dupe(u8, o.key), .value = try a.dupe(u8, o.value) };
        return .{ .arena = arena, .overrides = copy };
    }

    pub fn deinit(self: *Options) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Handles `SET_VARIABLES`: replaces the declared set with the
    /// `{ NULL, NULL }`-terminated array. Malformed entries are skipped with a
    /// warning. Older strings stay valid, since the core may still hold them.
    pub fn setVariables(self: *Options, list: [*c]const c.struct_retro_variable) !void {
        const a = self.arena.allocator();
        self.declared.clearRetainingCapacity();
        if (list == null) return;
        var i: usize = 0;
        while (list[i].key != null) : (i += 1) {
            const key = std.mem.span(list[i].key);
            if (list[i].value == null) {
                try self.warn("core option \"{s}\" has no value list; ignored", .{key});
                continue;
            }
            const raw = std.mem.span(list[i].value);
            const values = parseValues(a, raw) catch |err| switch (err) {
                error.Malformed => {
                    try self.warn("core option \"{s}\" has a malformed declaration \"{s}\"; ignored", .{ key, raw });
                    continue;
                },
                error.OutOfMemory => return err,
            };
            try self.declared.append(a, .{ .key = try a.dupe(u8, key), .values = values });
        }
    }

    /// Handles `GET_VARIABLE`: the override if it names a declared value
    /// (the last one wins), else the default. Null for an undeclared key.
    pub fn get(self: *const Options, key: []const u8) ?[*:0]const u8 {
        const d = self.find(key) orelse return null;
        var i = self.overrides.len;
        while (i > 0) {
            i -= 1;
            const o = self.overrides[i];
            if (!std.mem.eql(u8, o.key, key)) continue;
            for (d.values) |v| {
                if (std.mem.eql(u8, v, o.value)) return v.ptr;
            }
            break;
        }
        return d.values[0].ptr;
    }

    /// Checks the overrides against the declarations. Call after load: the
    /// core declares its options during `retro_set_environment`/`retro_init`.
    pub fn validate(self: *Options) !void {
        for (self.overrides) |o| {
            const d = self.find(o.key) orelse {
                try self.warn("option \"{s}\" is not declared by the core; ignored", .{o.key});
                continue;
            };
            for (d.values) |v| {
                if (std.mem.eql(u8, v, o.value)) break;
            } else {
                try self.warn("option \"{s}\": \"{s}\" is not one of {f}; using the default \"{s}\"", .{ o.key, o.value, joined(d.values), d.values[0] });
            }
        }
    }

    fn find(self: *const Options, key: []const u8) ?Declared {
        for (self.declared.items) |d| {
            if (std.mem.eql(u8, d.key, key)) return d;
        }
        return null;
    }

    fn warn(self: *Options, comptime fmt: []const u8, args: anytype) !void {
        const a = self.arena.allocator();
        try self.warnings.append(a, try std.fmt.allocPrint(a, fmt, args));
    }
};

/// Splits "Description; a|b|c" into NUL-terminated values.
fn parseValues(a: std.mem.Allocator, raw: []const u8) error{ Malformed, OutOfMemory }![]const [:0]const u8 {
    const sep = std.mem.indexOf(u8, raw, "; ") orelse return error.Malformed;
    const list = raw[sep + 2 ..];
    if (list.len == 0) return error.Malformed;
    const values = try a.alloc([:0]const u8, std.mem.countScalar(u8, list, '|') + 1);
    var it = std.mem.splitScalar(u8, list, '|');
    for (values) |*v| v.* = try a.dupeSentinel(u8, it.next().?, 0);
    return values;
}

fn joined(values: []const [:0]const u8) Joined {
    return .{ .values = values };
}

const Joined = struct {
    values: []const [:0]const u8,
    pub fn format(self: Joined, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.values, 0..) |v, i| {
            if (i > 0) try w.writeByte('|');
            try w.writeAll(v);
        }
    }
};

/// Remembers which commands were already logged, so an unsupported command a
/// core calls every frame is logged once. Allocation-free: once full, further
/// new commands are not logged (a core uses far fewer than `capacity`).
pub const SeenSet = struct {
    cmds: [capacity]c_uint = undefined,
    len: usize = 0,

    pub const capacity = 128;

    /// True the first time `cmd` is seen.
    pub fn firstTime(self: *SeenSet, cmd: c_uint) bool {
        for (self.cmds[0..self.len]) |s| {
            if (s == cmd) return false;
        }
        if (self.len == capacity) return false;
        self.cmds[self.len] = cmd;
        self.len += 1;
        return true;
    }
};

const testing = std.testing;

test "command names" {
    try testing.expectEqualStrings("GET_VARIABLE", name(15).?);
    try testing.expectEqualStrings("SET_PIXEL_FORMAT", name(c.RETRO_ENVIRONMENT_SET_PIXEL_FORMAT).?);
    try testing.expectEqualStrings("SET_MEMORY_MAPS", name(36 | 0x10000).?);
    try testing.expectEqual(null, name(36)); // experimental bit missing
    try testing.expectEqual(null, name(0x10000));
    try testing.expectEqual(null, name(0x20000));
    try testing.expectEqual(null, name(9999));
}

test "command table has no duplicate numbers" {
    for (table, 0..) |a, i| {
        for (table[i + 1 ..]) |b| try testing.expect(a.cmd != b.cmd);
    }
    try testing.expect(table.len > 80);
}

fn vars(comptime list: []const [2]?[*:0]const u8) [list.len + 1]c.struct_retro_variable {
    var out: [list.len + 1]c.struct_retro_variable = undefined;
    for (list, 0..) |kv, i| out[i] = .{ .key = kv[0], .value = kv[1] };
    out[list.len] = .{ .key = null, .value = null };
    return out;
}

test "declared options: defaults and values with spaces" {
    var o: Options = try .init(testing.allocator, &.{});
    defer o.deinit();
    const v = vars(&.{
        .{ "a_mode", "Display mode; 4:3 (PAR)|Full width|8:7" },
        .{ "a_single", "Only one; on" },
    });
    try o.setVariables(&v);
    try testing.expectEqualStrings("4:3 (PAR)", std.mem.span(o.get("a_mode").?));
    try testing.expectEqualStrings("on", std.mem.span(o.get("a_single").?));
    try testing.expectEqual(null, o.get("a_missing"));
    try o.validate();
    try testing.expectEqual(0, o.warnings.items.len);
}

test "malformed declarations are ignored with a warning" {
    var o: Options = try .init(testing.allocator, &.{});
    defer o.deinit();
    const v = vars(&.{
        .{ "a_nosep", "No separator a|b" },
        .{ "a_empty", "Empty list; " },
        .{ "a_null", null },
        .{ "a_ok", "Fine; x|y" },
    });
    try o.setVariables(&v);
    try testing.expectEqual(null, o.get("a_nosep"));
    try testing.expectEqual(null, o.get("a_empty"));
    try testing.expectEqual(null, o.get("a_null"));
    try testing.expectEqualStrings("x", std.mem.span(o.get("a_ok").?));
    try testing.expectEqual(3, o.warnings.items.len);
    try testing.expectEqualStrings(
        "core option \"a_nosep\" has a malformed declaration \"No separator a|b\"; ignored",
        o.warnings.items[0],
    );
}

test "overrides: valid, invalid value, undeclared key, last wins" {
    var o: Options = try .init(testing.allocator, &.{
        .{ .key = "a_fmt", .value = "rgb565" },
        .{ .key = "a_speed", .value = "warp" },
        .{ .key = "a_ghost", .value = "1" },
        .{ .key = "a_twice", .value = "b" },
        .{ .key = "a_twice", .value = "c" },
    });
    defer o.deinit();
    const v = vars(&.{
        .{ "a_fmt", "Pixel format; xrgb8888|rgb565|0rgb1555" },
        .{ "a_speed", "Speed; normal|fast" },
        .{ "a_twice", "Twice; a|b|c" },
    });
    try o.setVariables(&v);
    try testing.expectEqualStrings("rgb565", std.mem.span(o.get("a_fmt").?));
    try testing.expectEqualStrings("normal", std.mem.span(o.get("a_speed").?));
    try testing.expectEqualStrings("c", std.mem.span(o.get("a_twice").?));
    try testing.expectEqual(null, o.get("a_ghost"));

    try o.validate();
    try testing.expectEqual(2, o.warnings.items.len);
    try testing.expectEqualStrings(
        "option \"a_speed\": \"warp\" is not one of normal|fast; using the default \"normal\"",
        o.warnings.items[0],
    );
    try testing.expectEqualStrings("option \"a_ghost\" is not declared by the core; ignored", o.warnings.items[1]);
}

test "SET_VARIABLES again replaces the set; old pointers stay valid" {
    var o: Options = try .init(testing.allocator, &.{});
    defer o.deinit();
    const v1 = vars(&.{.{ "a_old", "Old; x|y" }});
    try o.setVariables(&v1);
    const old = o.get("a_old").?;
    const v2 = vars(&.{.{ "a_new", "New; p|q" }});
    try o.setVariables(&v2);
    try testing.expectEqual(null, o.get("a_old"));
    try testing.expectEqualStrings("p", std.mem.span(o.get("a_new").?));
    try testing.expectEqualStrings("x", std.mem.span(old));
}

test "log once per command number" {
    var s: SeenSet = .{};
    try testing.expect(s.firstTime(42));
    try testing.expect(!s.firstTime(42));
    try testing.expect(s.firstTime(42 | 0x10000));
    try testing.expect(!s.firstTime(42 | 0x10000));

    var full: SeenSet = .{};
    for (0..SeenSet.capacity) |i| try testing.expect(full.firstTime(@intCast(i + 1000)));
    try testing.expect(!full.firstTime(1));
    try testing.expect(!full.firstTime(1000));
}
