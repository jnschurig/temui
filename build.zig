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
    // One option per file, so editing a golden invalidates the cached test run.
    for ([_][]const u8{ "xrgb8888", "rgb565", "0rgb1555" }) |f| {
        test_options.addOptionPath(b.fmt("golden_{s}", .{f}), b.path(b.fmt("testdata/golden/testcore-{s}-f60.ppm", .{f})));
    }
    // Renderer goldens (testdata/golden/render-*): read and, with
    // -Dupdate-goldens, rewritten by the tests themselves.
    const update_goldens = b.option(bool, "update-goldens", "Rewrite renderer golden files that differ (the test still fails)") orelse false;
    test_options.addOption(bool, "update_goldens", update_goldens);
    test_options.addOption([]const u8, "golden_dir", try b.root.joinString(b.allocator, "testdata/golden"));
    const test_mod = makeModule(b, target, optimize, "src/main.zig");
    test_mod.addImport("test_options", test_options.createModule());
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    try addRenderGoldenInputs(b, run_tests);
    if (update_goldens) run_tests.has_side_effects = true;
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

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
    addBench(b, target);
}

/// `temui-bench` (bench/): renderer encode and live-terminal benchmarks.
/// Never built by the default, `test` or `cross` steps, nor by CI.
fn addBench(b: *std.Build, target: std.Build.ResolvedTarget) void {
    // Measurements need optimized code, so the bench has its own optimize
    // option; `-Doptimize` (temui's) does not apply to it.
    const optimize = b.option(std.builtin.OptimizeMode, "bench-optimize", "Optimize mode for temui-bench (default fast)") orelse .fast;
    const testcore = makeTestCore(b, target, optimize);
    const options = b.addOptions();
    options.addOption([]const u8, "optimize", @tagName(optimize));
    options.addOptionPath("test_core_path", testcore.getEmittedBin());
    options.addOptionPath("testcore_rom", b.path("testdata/testcore.rom"));

    const exe = b.addExecutable(.{ .name = "temui-bench", .root_module = benchModule(b, target, optimize, options) });
    b.step("bench", "Build temui-bench (renderer benchmarks)").dependOn(&b.addInstallArtifact(exe, .{}).step);

    // Its own tests (scenes, stats) keep safety checks on.
    const tests = b.addTest(.{ .root_module = benchModule(b, target, .debug, options) });
    b.step("bench-test", "Run temui-bench unit tests").dependOn(&b.addRunArtifact(tests).step);
}

fn benchModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag != .windows,
        .imports = &.{
            .{ .name = "bench_options", .module = options.createModule() },
            .{ .name = "temui", .module = makeModule(b, target, optimize, "src/lib.zig") },
        },
    });
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
    return b.addExecutable(.{ .name = "temui", .root_module = makeModule(b, target, optimize, "src/main.zig") });
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

/// A module rooted at `root` (`src/main.zig` for temui, `src/lib.zig` for
/// tools) with the libretro header and stb_sprintf set up.
fn makeModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root: []const u8,
) *std.Build.Module {
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const mod = b.createModule(.{
        .root_source_file = b.path(root),
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

/// Makes the test run depend on every `testdata/golden/render-*` file, so
/// editing or regenerating one invalidates the cached result.
fn addRenderGoldenInputs(b: *std.Build, run: *std.Build.Step.Run) !void {
    const io = b.graph.io;
    var dir = try b.root.openDir(io, "testdata/golden", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.startsWith(u8, e.name, "render-")) continue;
        run.addFileInput(b.path(b.fmt("testdata/golden/{s}", .{e.name})));
    }
}
