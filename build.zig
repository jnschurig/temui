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

    addTermbench(b, target);
}

/// Spike 02's throwaway benchmark (spikes/termbench). macOS only; never built
/// by the default, `test` or `cross` steps, nor by CI.
fn addTermbench(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const bench_step = b.step("termbench", "Build the terminal-graphics benchmark (spike 02, macOS only)");
    const test_step = b.step("termbench-test", "Run termbench unit tests (macOS only)");
    if (target.result.os.tag != .macos) {
        const fail = b.addFail("termbench is macOS-only");
        bench_step.dependOn(&fail.step);
        test_step.dependOn(&fail.step);
        return;
    }
    // Measurements need optimized encoders; `-Doptimize` still overrides.
    const optimize = b.option(std.builtin.OptimizeMode, "termbench-optimize", "Optimize mode for termbench (default fast)") orelse .fast;
    const options = b.addOptions();
    options.addOption([]const u8, "optimize", @tagName(optimize));

    const exe = b.addExecutable(.{ .name = "termbench", .root_module = termbenchModule(b, target, optimize, options) });
    bench_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

    // Tests keep safety checks on.
    const tests = b.addTest(.{ .root_module = termbenchModule(b, target, .debug, options) });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn termbenchModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("spikes/termbench/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "log", .module = b.createModule(.{ .root_source_file = b.path("src/log.zig"), .target = target, .optimize = optimize }) },
            .{ .name = "paths", .module = b.createModule(.{ .root_source_file = b.path("src/paths.zig"), .target = target, .optimize = optimize }) },
        },
    });
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
