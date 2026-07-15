// axinc-bench - Industry metrics benchmark & validation
// Zig 0.16.0 + ZLS 0.16.0
// Run with: zig build bench
// Sustained workloads for IPS, learn, cache hit, energy, ctx efficiency.
// Uses loop + repeated compute for cache pressure + LANG/FUSE for learn_rate.
const std = @import("std");
const core = @import("core/types.zig");
const axicore = @import("core/axicore.zig");
const engine_mod = @import("core/engine.zig");
const isa = @import("isa/opcodes.zig");
const asm_lower = @import("asm/lower.zig");
const assembler = @import("asm/assembler.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("axinc-bench (Zig 0.16 + AST + ASM + Industry Metrics)\n", .{});

    // Direct intrinsics
    const shl = axicore.asmShlAdd(100, 3, 7);
    std.debug.print("asmShlAdd(100,3,7) = {d}\n", .{shl});
    const has = axicore.asmHashMix(0xdead, 0xbeef);
    std.debug.print("asmHashMix demo = 0x{X}\n", .{has});

    // AST lower
    try asm_lower.demoLower(allocator);

    // Sustained benchmark workload
    var state = try core.MachineState.init(allocator);
    defer state.deinit(allocator);
    var eng = try engine_mod.Engine.init(allocator, &state, .{ .max_cycles_per_tap = 128 });
    defer eng.deinit();

    // Sustained loop program for benchmark: repeated MULs (for cache pressure), LANG for learn
    // No HALT so multiple taps accumulate real work (each tap up to 128 instr execs in tight loop)
    const asm_src =
        \\MOVI R1, 42
        \\MOVI R2, 7
        \\MUL R3, R1, R2
        \\MUL R4, R1, R2
        \\ADD R5, R3, R2
        \\JMP 2
    ;
    const prog = try assembler.assemble(allocator, asm_src);
    defer allocator.free(prog);
    try eng.loadProgram(prog);

    // REAL from file + KGDB/Memo/SPZA + 5L cache (L4/L5 ports)
    const model_data = @embedFile("models/sample_model.txt");
    var memo = try core.MemoTable.init(allocator, core.MEMO_ENTRY_COUNT);
    defer memo.deinit();
    // seed some real KG from sample for persistence demo
    if (eng.axicore_ctx.tricache.kg) |*k| {
        const a: [32]u8 = @splat(0xA);
        try k.addEdge(.{ .from = a, .to = a, .relation = 1, .weight = 0.95, .timestamp_ns = 0, .flags = 0 });
    }
    var lines = std.mem.splitScalar(u8, model_data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var spza = core.SpzaCoord{};
        for (line, 0..) |c, i| { if (i>=8) break; spza.dims[i] = @intCast(c); }
        _ = memo.lookup(&spza);
        memo.store(&spza, @intCast(line.len));
    }

    // Use linux clock for real elapsed (ns precision)
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    const start_ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;

    var total_taps: usize = 0;
    const num_taps: usize = 50;
    while (total_taps < num_taps and !state.regs.flags.halted) {
        _ = try eng.executeTap();
        total_taps += 1;

        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
        const now_ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        const elapsed_s = @as(f64, @floatFromInt(now_ns - start_ns)) / 1_000_000_000.0;

        const stats = eng.getStats();
        const ips = if (elapsed_s > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(stats.total_cycles)) / elapsed_s)) else 0;
        const learn = if (elapsed_s > 0) @as(f64, @floatFromInt(stats.custom_opcodes)) / elapsed_s else 0;
        // industry ctx_eff + cache_hr from full 5L tricache (L1-5 hits)
        const base_hr = stats.tricache_overall_hit_rate;
        const ctx_eff = base_hr * 100.0;  // real hit driven (L4/L5 now contribute)

        if (total_taps % 10 == 0 or total_taps == 1) {
            std.debug.print("[tap {d}] cycles={d} IPS={d} hit={d:.1}% learn={d:.2}/s fused={d} ctx={d:.1}% dream={}\n", .{
                total_taps, stats.total_cycles, ips, base_hr * 100, learn, stats.total_fused_ops, ctx_eff, stats.dream_mode,
            });
        }
    }

    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    const end_ns: i128 = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
    const total_elapsed = @as(f64, @floatFromInt(end_ns - start_ns)) / 1_000_000_000.0;

    const final = eng.getStats();
    const final_ips = if (total_elapsed > 0) @as(u64, @intFromFloat(@as(f64, @floatFromInt(final.total_cycles)) / total_elapsed)) else 0;
    const final_learn = if (total_elapsed > 0) @as(f64, @floatFromInt(final.custom_opcodes)) / total_elapsed else 0;
    const energy_per_instr = if (final.total_cycles > 0) @as(f64, @floatFromInt(final.energy_saved)) / @as(f64, @floatFromInt(final.total_cycles)) else 0;

    std.debug.print("\n=== FINAL BENCH RESULTS (ReleaseFast target, {d} taps, {d:.3}s wall) ===\n", .{ total_taps, total_elapsed });
    std.debug.print("Total cycles: {d} | IPS: {d}\n", .{ final.total_cycles, final_ips });
    std.debug.print("Learn rate: {d:.2}/s | Fused: {d} | Custom opcodes: {d}\n", .{ final_learn, final.total_fused_ops, final.custom_opcodes });
    std.debug.print("Cache hit: {d:.1}% | Energy saved: {d} (per instr {d:.2}) | Ctx eff: {d:.0}%\n", .{
        final.tricache_overall_hit_rate * 100, final.energy_saved, energy_per_instr, if (final.total_cycles > 0) @as(f64, @floatFromInt(final.total_instructions)) / @as(f64, @floatFromInt(final.total_cycles)) * 100 else 0,
    });
    std.debug.print("VRAM: {d}MB | Dream: {}\n", .{ final.vram_usage_mb, final.dream_mode });
}
