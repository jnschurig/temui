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

    // Test core (D14): zig-out/lib/temui_test_libretro.{so,dylib}, or
    // zig-out/bin/temui_test_libretro.dll on Windows.
    const testcore = makeTestCore(b, target, optimize);
    b.getInstallStep().dependOn(&b.addInstallArtifact(testcore, .{
        .dest_sub_path = testCoreFileName(b, target),
        .implib_dir = .disabled,
    }).step);

    // Tests get their own module so the paths below never reach the release
    // binary. They're imported as `test_options`, only from test blocks.
    const test_options = b.addOptions();
    test_options.addOptionPath("test_core_path", testcore.getEmittedBin());
    test_options.addOptionPath("testcore_rom", b.path("testdata/testcore.rom"));
    const test_mod = makeModule(b, target, optimize);
    test_mod.addImport("test_options", test_options.createModule());
    const tests = b.addTest(.{ .root_module = test_mod });
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
        const cross_target = b.resolveTargetQuery(query);
        const install_core = b.addInstallArtifact(makeTestCore(b, cross_target, optimize), .{
            .dest_dir = .{ .override = .{ .custom = ct.name } },
            .dest_sub_path = testCoreFileName(b, cross_target),
            .implib_dir = .disabled,
            .pdb_dir = .disabled,
        });
        cross_step.dependOn(&install_core.step);
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
    // Measurements need optimized encoders, so termbench has its own
    // optimize option; `-Doptimize` (temui's) does not apply to it.
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
    return b.addExecutable(.{ .name = "temui", .root_module = makeModule(b, target, optimize) });
}

/// Zig 0.17 has no @cImport; C headers are translated by the build system.
fn libretroModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.addTranslateC(.{
        .root_source_file = b.path("vendor/libretro/libretro.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();
}

/// The in-repo test core (testcore/main.zig), a libretro shared library.
fn makeTestCore(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addLibrary(.{
        .name = "temui_test_libretro",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("testcore/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "libretro", .module = libretroModule(b, target, optimize) }},
        }),
    });
}

/// libretro cores are named `<name>_libretro.<ext>`, without a `lib` prefix.
fn testCoreFileName(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    return b.fmt("temui_test_libretro{s}", .{target.result.dynamicLibSuffix()});
}

fn makeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // glibc/libSystem are needed to dlopen cores later (D2, D3).
        .link_libc = target.result.os.tag != .windows,
        .imports = &.{
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "libretro", .module = libretroModule(b, target, optimize) },
        },
    });

    // Core log formatting (src/libretro/core_log.c): see vendor/stb_sprintf.
    mod.addIncludePath(b.path("vendor/stb_sprintf"));
    mod.addCSourceFile(.{ .file = b.path("src/libretro/core_log.c"), .flags = &.{"-std=c99"} });
    return mod;
}
