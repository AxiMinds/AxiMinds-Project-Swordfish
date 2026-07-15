const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dev debug option: enable pluggable debugging (default: false for release, strip for IP)
    // Use: zig build -Ddev-debug=true
    // When false, all debug calls are no-op (zero cost, bypassed at comptime if possible)
    const dev_debug = b.option(bool, "dev-debug", "Enable pluggable dev debugging module (default false)") orelse false;

    const build_options = b.addOptions();
    build_options.addOption(bool, "dev_debug", dev_debug);

    // Note: lib build for bridge currently hits 0.16 "outside module path" due to relative ../ in src/bridge when rooted there.
    // For demo, we build exe (via main.zig) + bench + tests. See docs for llama integration.
    // const lib = ... (disabled for clean build)
    _ = b.createModule(.{ // keep for future lib if bridge adjusted
        .root_source_file = b.path("src/bridge/llama_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    const test_step = b.step("test", "Run unit tests");
    // Consolidated test using exe root module (avoids "outside module path" for relative imports in 0.16).
    // This pulls in tests from types, alu, engine, isa, asm (via usage in main/bench paths).
    // Separate per-file tests disabled due to module root rules for ../ imports; covered via integration in run/bench too.
    const main_test = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(main_test).step);

    const bench_module = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_module.addOptions("build_options", build_options);
    const bench = b.addExecutable(.{ .name = "axinc-bench", .root_module = bench_module });
    b.installArtifact(bench);
    b.step("bench", "bench").dependOn(&b.addRunArtifact(bench).step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |a| run.addArgs(a);
    b.step("run", "run").dependOn(&run.step);
}
