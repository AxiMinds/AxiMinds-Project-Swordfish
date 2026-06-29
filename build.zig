const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/bridge/llama_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "axinc",
        .root_module = root_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const shared = b.addLibrary(.{
        .name = "axinc",
        .root_module = root_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(shared);

    const exe = b.addExecutable(.{
        .name = "axinc",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const test_step = b.step("test", "Run unit tests");
    const test_files = [_][]const u8{
        "src/core/types.zig",
        "src/isa/opcodes.zig",
        "src/core/alu.zig",
        "src/core/engine.zig",
        "src/asm/lower.zig",
        "src/asm/assembler.zig",
    };
    for (test_files) |f| {
        const tmod = b.createModule(.{ .root_source_file = b.path(f), .target = target, .optimize = optimize });
        const t = b.addTest(.{ .root_module = tmod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench = b.addExecutable(.{ .name = "axinc-bench", .root_module = bench_mod });
    b.installArtifact(bench);
    b.step("bench", "bench").dependOn(&b.addRunArtifact(bench).step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |a| run.addArgs(a);
    b.step("run", "run").dependOn(&run.step);
}
