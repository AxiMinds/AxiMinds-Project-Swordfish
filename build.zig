const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dev_debug = b.option(bool, "dev-debug", "Enable pluggable dev debugging module (default false)") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "dev_debug", dev_debug);

    // ── Shared + static library (C ABI bridge, root under src/ for 0.16 imports)
    const bridge_mod = b.createModule(.{
        .root_source_file = b.path("src/bridge_lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    bridge_mod.addOptions("build_options", build_options);

    const lib_static = b.addLibrary(.{
        .name = "axinc",
        .root_module = bridge_mod,
        .linkage = .static,
    });
    b.installArtifact(lib_static);

    const lib_shared = b.addLibrary(.{
        .name = "axinc",
        .root_module = bridge_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib_shared);

    // ── Main executable (demo + agent)
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "axinc",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // ── Tests (single consolidated module via main — pulls agent/asm/core/bridge_lib tests)
    const test_step = b.step("test", "Run unit tests");
    const main_test = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(main_test).step);

    // ── Bench
    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_module.addOptions("build_options", build_options);
    const bench = b.addExecutable(.{ .name = "axinc-bench", .root_module = bench_module });
    b.installArtifact(bench);
    b.step("bench", "bench").dependOn(&b.addRunArtifact(bench).step);

    // ── Run
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |a| run.addArgs(a);
    b.step("run", "run").dependOn(&run.step);
}
