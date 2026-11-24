const std = @import("std");
const zon = @import("build.zig.zon");

/// The six release targets (D2). Directory names are `<os>-<arch>`.
const cross_targets = [_]struct { name: []const u8, triple: []const u8 }{
    .{ .name = "linux-x86_64", .triple = "x86_64-linux-gnu.2.28" },
    .{ .name = "linux-aarch64", .triple = "aarch64-linux-gnu.2.28" },
    .{ .name = "macos-x86_64", .triple = "x86_64-macos" },
    .{ .name = "macos-aarch64", .triple = "aarch64-macos" },
    .{ .name = "windows-x86_64", .triple = "x86_64-windows.win10_rs4" },
    .{ .name = "windows-aarch64", .triple = "aarch64-windows.win10_rs4" },
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Native build: zig-out/bin/temui
    const exe = makeExe(b, target, optimize);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run temui").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    // Cross build: zig-out/<os>-<arch>/temui[.exe]
    const cross_step = b.step("cross", "Build all six release targets");
    for (cross_targets) |ct| {
        const query = try std.Target.Query.parse(.{ .arch_os_abi = ct.triple });
        const cross_exe = makeExe(b, b.resolveTargetQuery(query), optimize);
        const install = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{ .override = .{ .custom = ct.name } },
        });
        cross_step.dependOn(&install.step);
    }
}

fn makeExe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    // Zig 0.17 has no @cImport; C headers are translated by the build system.
    const libretro = b.addTranslateC(.{
        .root_source_file = b.path("vendor/libretro/libretro.h"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // glibc/libSystem are needed to dlopen cores later (D2, D3).
        .link_libc = target.result.os.tag != .windows,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "libretro", .module = libretro.createModule() },
        },
    });

    return b.addExecutable(.{ .name = "temui", .root_module = mod });
}
