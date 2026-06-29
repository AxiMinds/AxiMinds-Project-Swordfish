// AxiMinds Neural Computer — Build Configuration
// Zig 0.16.0 | ZLS 0.16.0 | Targets: native, aarch64-linux, x86_64-linux, etc.
// Uses std.zig.Ast + asm intrinsics where plausible (see axicore + isa/lower).
// See Conv-20260628-1155pm.md for full history and review feedback.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Core Library (for linking) ─────────────────────────────────
    const lib = b.addStaticLibrary(.{
        .name = "axinc",
        .root_source_file = b.path("src/bridge/llama_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // Shared library for dynamic linking (llama.cpp)
    const shared = b.addSharedLibrary(.{
        .name = "axinc",
        .root_source_file = b.path("src/bridge/llama_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(shared);

    // ── Executable example / runner (optional) ─────────────────────
    const exe = b.addExecutable(.{
        .name = "axinc",
        .root_source_file = b.path("src/bridge/llama_bridge.zig"), // placeholder; can point to a main later
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // ── Test Runner (per review: run all unit tests) ───────────────
    const test_core = b.addTest(.{
        .root_source_file = b.path("src/core/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_isa = b.addTest(.{
        .root_source_file = b.path("src/isa/opcodes.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_alu = b.addTest(.{
        .root_source_file = b.path("src/core/alu.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_engine = b.addTest(.{
        .root_source_file = b.path("src/core/engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_lower = b.addTest(.{
        .root_source_file = b.path("src/asm/lower.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_test_core = b.addRunArtifact(test_core);
    const run_test_isa = b.addRunArtifact(test_isa);
    const run_test_alu = b.addRunArtifact(test_alu);
    const run_test_engine = b.addRunArtifact(test_engine);
    const run_test_lower = b.addRunArtifact(test_lower);

    const test_step = b.step("test", "Run all axiNC unit tests");
    test_step.dependOn(&run_test_core.step);
    test_step.dependOn(&run_test_isa.step);
    test_step.dependOn(&run_test_alu.step);
    test_step.dependOn(&run_test_engine.step);
    test_step.dependOn(&run_test_lower.step);

    // ── Benchmarks ────────────────────────────────────────────────
    const bench = b.addExecutable(.{
        .name = "axinc-bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    b.installArtifact(bench);
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run axiNC performance benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Default run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
