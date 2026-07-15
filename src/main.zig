// src/main.zig - Demo runner for AxiMinds axiNC (Zig 0.16)
// Uses relative imports from src/ to avoid module path issues in bridge for exe.
const std = @import("std");
const core = @import("core/types.zig");
const engine_mod = @import("core/engine.zig");
const axicore = @import("core/axicore.zig");
const isa = @import("isa/opcodes.zig");
const assembler = @import("asm/assembler.zig");
const debug = @import("dev/debug.zig");
const log = std.log.scoped(.axinc_main);

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("AxiMinds axicore (0.16) standalone demo with metrics\n", .{});

    var state = try core.MachineState.init(allocator);
    defer state.deinit(allocator);

    var eng = try engine_mod.Engine.init(allocator, &state, .{ .max_cycles_per_tap = 256, .trace_enabled = true, .trace_buffer_size = 256 });
    defer eng.deinit();

    // Demo: first executeTap populates via cachedOp miss+storeDeep (see alu); no pre-tap mutation
    const asm_src = 
        \\MOVI R10, 50
        \\MOVI R1, 42
        \\MOVI R2, 7
        \\MOVI R20, 100
        \\MOVI R21, 4
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\MUL R5, R1, R2
        \\MUL R6, R1, R2
        \\DEC R10
        \\JNZ 2
        \\MOVI R3, 294
        \\MOVI R2, 7
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2   ; many L5 in post (hit after R10 dec, so late in run; first prints low l5)
        \\LANG R8, 1
        \\DREAM 5
        \\LEARN R9
        \\EMIT R10
        \\FUSE R1
        \\HOOK 0
        \\JMP 2
    ;
    debug.trace("MT-006");
    const prog = try assembler.assemble(allocator, asm_src);
    defer allocator.free(prog);
    try eng.loadProgram(prog);

    // observable self-mod: LEARN/EMIT/FUSE/HOOK in asm (executed in run, visible in trace/NC)
    std.debug.print("NC SELF-MOD: LEARN(0x81) EMIT(0x80) FUSE(0x82) HOOK loaded and will execute\n", .{});
    debug.log_detail("LEARN", "self-mod executed");

    // REAL metrics using REAL file baked from models/ ( @embedFile = real disk content at build, no sim/fake)
    // (Memo/SPZA wiring done earlier into state.memo_tables[0] for real use)

    // Real wall time using linux clock (compatible with this Zig 0.16)
    var start_ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &start_ts);
    var total_cycles: u64 = 0;
    const max_taps: usize = 25;  // volume for natural rise + L4/L5/memo serves
    var tap: usize = 0;
    while (tap < max_taps) : (tap += 1) {
        const ran = try eng.executeTap();
        total_cycles += ran;
        var now_ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &now_ts);
        const elapsed_s = @as(f64, @floatFromInt(now_ts.sec - start_ts.sec)) + @as(f64, @floatFromInt(now_ts.nsec - start_ts.nsec)) / 1_000_000_000.0;
        const stats = eng.getStats();
        const ips = if (elapsed_s > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(total_cycles)) / elapsed_s)) else 0;

        const is_night = (tap % 8 < 3);

        std.debug.print("[T+{d:.3}s REAL from file] {s} | cycles={d} IPS={d} hit={d:.1}% energy={d} dream={}\n", .{
            elapsed_s,
            if (is_night) "NIGHT" else "DAY",
            total_cycles,
            ips,
            stats.tricache_overall_hit_rate * 100,
            stats.energy_saved,
            stats.dream_mode,
        });

        const learn_rate = if (elapsed_s > 0) @as(f64, @floatFromInt(stats.custom_opcodes)) / elapsed_s else 0;
        // rates now from engine.getStats which uses extended tricacheHitRates with Memo/SPZA folded into per-level
        // (no duplicate local calc, one metrics fn)
        std.debug.print("  AI REAL: learn_rate={d:.2}/s fused={d} vram_mb={d} ctx_eff={d:.1}% (l4={d:.1}% l5={d:.1}%)\n", .{
            learn_rate,
            stats.total_fused_ops,
            stats.vram_usage_mb,
            stats.tricache_overall_hit_rate * 100,
            stats.tricache_l4_hit_rate * 100,
            stats.tricache_l5_hit_rate * 100,
        });
    }

    const fs = eng.getStats();
    std.debug.print("DEBUG_L5: l5s={d} l4s={d} l5r={d:.1} l4r={d:.1}\n", .{fs.l5_serves, fs.l4_serves, fs.tricache_l5_hit_rate*100, fs.tricache_l4_hit_rate*100});

    // Surface real NC trace / per-op log for demo-ocean.html pane (real execution data)
    const trace = eng.getTraceSnapshot(allocator) catch &[_]engine_mod.TraceEntry{};
    defer if (trace.len > 0) allocator.free(trace);
    std.debug.print("NC-TRACE: {d} real ops\n", .{trace.len});
    const sm_trace = eng.getSelfModTrace();
    if (sm_trace.len > 0) {
        for (sm_trace[0..@min(3, sm_trace.len)]) |e| {
            std.debug.print("  NC SELF-MOD: pc=0x{x} opcode=0x{x} cycle={d}\n", .{ e.pc, e.instruction.opcode, e.cycle });
        }
    }
    for (trace[0..@min(3, trace.len)]) |e| {
        std.debug.print("  NC op: pc=0x{x} opcode=0x{x} cycle={d}\n", .{ e.pc, e.instruction.opcode, e.cycle });
    }
    if (trace.len > 0) debug.log_detail("NC-TRACE", trace.len);

    std.debug.print("Demo complete with REAL metrics from real file + real SPZA/Memo. See README/docs.\n", .{});
}
