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

    // Run with visible metrics
    const ran = try eng.executeTap();
    const stats = eng.getStats();

    std.debug.print("Executed {d} cycles. R3={d} R4={d}\n", .{ ran, state.regs.getGP(3), state.regs.getGP(4) });
    std.debug.print("Stats: hit_rate={d:.2} vram={d}MB dream={}\n", .{
        stats.tricache_overall_hit_rate, stats.vram_usage_mb, stats.dream_mode,
    });

    // Real-time style print (sim day/night)
    const now = std.time.timestamp();
    const hour = @mod(@as(u64, @intCast(now / 3600)), 24);
    std.debug.print("Wall time hour (day/night sim): {d}  AI metrics: IPS~{d} energy_saved={d}\n", .{hour, if (ran > 0) 1_000_000 / ran else 0 , stats.energy_saved });

    std.debug.print("Demo complete. (See README for full metrics, axiASM.)\n", .{});
}
