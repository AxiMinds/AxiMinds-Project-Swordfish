// AxiMinds Neural Computer — Build Configuration
// Zig 0.16.0 | ZLS 0.16.0 | Targets: native, aarch64-linux, x86_64-linux, etc.
// Uses std.zig.Ast + asm intrinsics where plausible (see axicore + isa/lower).
// See Conv-20260628-1155pm.md for full history and review feedback.
//
// NOTE: Updated for Zig 0.16 Build API changes (addLibrary + root_module instead of
// addStaticLibrary/addSharedLibrary with root_source_file directly).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Common root module for the main bridge entry (used by lib/exe)
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/bridge/llama_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Core Library (static) ──────────────────────────────────────
    const lib = b.addLibrary(.{
        .name = "axinc",
        .root_module = root_module,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Shared library for dynamic linking (llama.cpp)
    const shared = b.addLibrary(.{
        .name = "axinc",
        .root_module = root_module,
        .linkage = .dynamic,
    });
    b.installArtifact(shared);

    // ── Executable example / runner ────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "axinc",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    // ── Test Runner (per review: run all unit tests) ───────────────
    // Helper to make a module for a test root
    const make_test_mod = struct {
        fn make(b2: *std.Build, path: []const u8, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode) *std.Build.Module {
            return b2.createModule(.{
                .root_source_file = b2.path(path),
                .target = t,
                .optimize = o,
            });
        }
    }.make;

    const test_core = b.addTest(.{
        .root_module = make_test_mod(b, "src/core/types.zig", target, optimize),
    });
    const test_isa = b.addTest(.{
        .root_module = make_test_mod(b, "src/isa/opcodes.zig", target, optimize),
    });
    const test_alu = b.addTest(.{
        .root_module = make_test_mod(b, "src/core/alu.zig", target, optimize),
    });
    const test_engine = b.addTest(.{
        .root_module = make_test_mod(b, "src/core/engine.zig", target, optimize),
    });
    const test_lower = b.addTest(.{
        .root_module = make_test_mod(b, "src/asm/lower.zig", target, optimize),
    });
    // Add assembler test later when implemented

    const test_step = b.step("test", "Run all axiNC unit tests");
    test_step.dependOn(&b.addRunArtifact(test_core).step);
    test_step.dependOn(&b.addRunArtifact(test_isa).step);
    test_step.dependOn(&b.addRunArtifact(test_alu).step);
    test_step.dependOn(&b.addRunArtifact(test_engine).step);
    test_step.dependOn(&b.addRunArtifact(test_lower).step);

    // ── Benchmarks ────────────────────────────────────────────────
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench = b.addExecutable(.{
        .name = "axinc-bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench);
    const bench_step = b.step("bench", "Run axiNC performance benchmarks");
    bench_step.dependOn(&b.addRunArtifact(bench).step);

    // Default run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
