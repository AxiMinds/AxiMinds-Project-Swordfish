// src/main.zig - Demo runner for AxiMinds axiNC (Zig 0.16)
// Uses relative imports from src/ to avoid module path issues in bridge for exe.
const std = @import("std");
const core = @import("core/types.zig");
const axicore = @import("core/axicore.zig");
const engine_mod = @import("core/engine.zig");
const isa = @import("isa/opcodes.zig");
const assembler = @import("asm/assembler.zig");
const log = std.log.scoped(.axinc_main);

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("AxiMinds axicore (0.16) standalone demo with metrics\n", .{});

    var state = try core.MachineState.init(allocator);
    defer state.deinit(allocator);

    var eng = try engine_mod.Engine.init(allocator, &state, .{ .max_cycles_per_tap = 128 });
    defer eng.deinit();

    // Demo using assembler
    const asm_src = 
        \\MOVI R1, 100
        \\MOVI R2, 23
        \\ADD R3, R1, R2
        \\MUL R4, R3, R2
        \\DREAM 5
        \\HALT
    ;
    const prog = try assembler.assemble(allocator, asm_src);
    defer allocator.free(prog);
    try eng.loadProgram(prog);

    // Real-time metrics loop (simulates running throughout day/night)
    var total_cycles: u64 = 0;
    const start = std.time.milliTimestamp();
    for (0..5) |tick| {
        const ran = try eng.executeTap();
        total_cycles += ran;
        const stats = eng.getStats();
        const now_ms = std.time.milliTimestamp();
        const elapsed_s = @as(f64, @floatFromInt(now_ms - start)) / 1000.0;
        const ips = if (elapsed_s > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_cycles)) / elapsed_s)) else 0;

        const now = std.time.timestamp();
        const hour = @mod(@as(u64, @intCast(now / 3600)), 24);
        const is_night = hour < 6 or hour > 18;

        std.debug.print("[T+{d:.1}s] {s} | cycles={d} IPS={d} hit={d:.1}% energy={d} dream={}\n", .{
            elapsed_s,
            if (is_night) "NIGHT" else "DAY",
            total_cycles,
            ips,
            stats.tricache_overall_hit_rate * 100,
            stats.energy_saved,
            stats.dream_mode,
        });

        // Industry AI specific metrics
        const learn_rate = if (elapsed_s > 0) @as(f64, @floatFromInt(stats.custom_opcodes)) / elapsed_s else 0;
        std.debug.print("  AI: learn_rate={d:.2}/s fused={d} vram_mb={d} ctx_eff~{d:.0}%\n", .{
            learn_rate,
            stats.total_fused_ops,
            stats.vram_usage_mb,
            if (stats.total_cycles > 0) @as(f64, @floatFromInt(stats.total_instructions)) / @as(f64, @floatFromInt(stats.total_cycles)) * 100 else 0,
        });

        // simple "sleep" for demo
        std.time.sleep(200 * std.time.ns_per_ms);
    }

    std.debug.print("Demo complete with real-time + AI industry metrics. See README/docs.\n", .{});
}
