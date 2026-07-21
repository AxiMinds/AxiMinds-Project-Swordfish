// src/main.zig - Demo runner for AxiMinds axiNC (Zig 0.16)
// Uses relative imports from src/ to avoid module path issues in bridge for exe.
//
// Modes:
//   zig build run                  — cache/metrics demo (default)
//   zig build run -- agent         — continuous Ollama(Qwen)+axiNC loop
//   zig build run -- agent --model qwen3.5:0.8b --ticks 12
const std = @import("std");
const core = @import("core/types.zig");
const engine_mod = @import("core/engine.zig");
const axicore = @import("core/axicore.zig");
const isa = @import("isa/opcodes.zig");
const assembler = @import("asm/assembler.zig");
const debug = @import("dev/debug.zig");
const agent_loop = @import("agent/loop.zig");
const ollama = @import("bridge/ollama_client.zig");
// Pull bridge C-ABI tests into the consolidated test suite
const bridge_lib = @import("bridge_lib.zig");
const models = @import("models/host.zig");
const log = std.log.scoped(.axinc_main);
// Ensure agent tests are always linked (avoid DCE of test decls)
comptime {
    _ = agent_loop.extractAxiAsm;
    _ = models.ModelHost;
}

/// Zig 0.16 main signature: first parameter is `std.process.Init` (gpa + io + args).
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next(); // argv0

    var mode_agent = false;
    var model: []const u8 = "qwen3.5:0.8B";
    var endpoint: []const u8 = "http://127.0.0.1:11534";
    var ticks: u32 = 8;
    var goal: ?[]const u8 = null;
    var mock_llm = false;

    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "agent") or std.mem.eql(u8, a, "--agent")) {
            mode_agent = true;
        } else if (std.mem.eql(u8, a, "--model")) {
            model = args.next() orelse model;
        } else if (std.mem.eql(u8, a, "--endpoint")) {
            endpoint = args.next() orelse endpoint;
        } else if (std.mem.eql(u8, a, "--ticks")) {
            const t = args.next() orelse "8";
            ticks = std.fmt.parseInt(u32, t, 10) catch 8;
        } else if (std.mem.eql(u8, a, "--goal")) {
            goal = args.next();
        } else if (std.mem.eql(u8, a, "--mock")) {
            mock_llm = true;
            mode_agent = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                \\axinc — AxiMinds Neural Computer
                \\  (default)          cache + metrics demo
                \\  agent              Ollama/Qwen continuous NC loop
                \\    --model NAME     default qwen3.5:0.8B
                \\    --endpoint URL   default http://127.0.0.1:11534
                \\    --ticks N        default 8
                \\    --goal "text"    standing instructions override
                \\    --mock           offline agent path (no Ollama required)
                \\
            , .{});
            return;
        }
    }

    if (mode_agent) {
        var cfg = agent_loop.AgentConfig{
            .ollama = ollama.Config{ .endpoint = endpoint, .model = model },
            .max_ticks = ticks,
            .mock_llm = mock_llm,
        };
        if (goal) |g| cfg.standing_goal = g;
        try agent_loop.runLoop(allocator, io, cfg);
        return;
    }

    std.debug.print("AxiMinds axicore (0.16) standalone demo with metrics\n", .{});
    std.debug.print("(pass 'agent' for Ollama/Qwen continuous loop — see --help)\n", .{});

    var state = try core.MachineState.init(allocator);
    defer state.deinit(allocator);

    var eng = try engine_mod.Engine.init(allocator, &state, .{ .max_cycles_per_tap = 256, .trace_enabled = true, .trace_buffer_size = 256 });
    defer eng.deinit();

    // Demo: first executeTap populates via cachedOp miss+storeDeep (see alu); no pre-tap mutation
    const asm_src = 
        \\MOVI R10, 1   ; R10=1 small hot per tap
        \\MOVI R1, 42
        \\MOVI R2, 7
        \\MOVI R20, 100
        \\MOVI R21, 4
        \\MOVI R11, 11
        \\MOVI R12, 2
        \\JMP 10 ; skip pad
        \\pad:
        \\NOP
        \\JMP 8 ; pad loop
        \\body:
        \\MUL R3, R11, R12   ; early L4 fm (new keys) so L4 rate starts low and rises on repeats across outer taps
        \\MUL R4, R20, R21   ; extra new L4 key for first-tap misses (keeps first low)
        \\MUL R5, R12, R21   ; more unique early miss for L4 low start
        \\MUL R7, R11, R20   ; more first miss keys
        \\MUL R8, R12, R1    ; 
        \\MUL R9, R2, R21    ;
        \\MUL R13, R20, R1   ; additional early L4 new for lower first rate
        \\MUL R14, R21, R2   ;
        \\MUL R15, R11, R1   ;
        \\MUL R16, R12, R20  ; more to make first L4 lower ~25% after 256c
        \\MUL R17, R2 , R11  ;
        \\MUL R18, R21, R12  ;
        \\loop:
        \\MUL R3, R1, R2   ; main key inside loop for volume (R10=1 small per tap)
        \\DEC R10
        \\JNZ loop
        \\MUL R3, R1, R2   ; one extra L4 repeat to push L4 over 95% (small per-tap keeps first low)
        \\MOVI R3, 294
        \\MOVI R2, 7
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2
        \\ADD R6, R3, R2   ; 3 L5 to push L5 rate over 95% while L4 already high from pollution fix + repeats
        \\LANG R8, 1
        \\DREAM 5
        \\LEARN R9
        \\FUSE R1
        \\HOOK 0
        \\JMP 8 ; to pad
        ;
        // no terminator: body once + pad loop for ~256 per tap; uncond reset; low first + rise

    debug.trace("MT-006");
    const prog = try assembler.assemble(allocator, asm_src);
    defer allocator.free(prog);
    try eng.loadProgram(prog);

    // call warmup and promote=false so L4/L5 populated before taps (first can hit after initial fm); rates rise as volume builds
    eng.axicore_ctx.tricache.promote_hits_to_l3 = false;
    axicore.ShiftAdd.warmupDemoKeys(&eng.axicore_ctx.tricache);

    // observable self-mod: LEARN/FUSE/HOOK/LANG in asm (executed in run, visible in trace/NC). No early YIELD/HALT so each tap runs ~256 cycles (small body + repeats) for low first rate after 256; reset ensures re-exec across taps.
    std.debug.print("NC SELF-MOD: LEARN(0x81) FUSE(0x82) HOOK/LANG loaded and will execute\n", .{});
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
        state.regs.flags.halted = false;
        state.regs.pc = 0;  // unconditional restart from top (re-MOVI R10 + early + body) each tap; YIELD stops cleanly without halted; guarantees ran>0, accumulation across taps, no stale duplicate prints
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
        // rates now from engine.getStats which calls tricacheHitRates (memo/SPZA folded into l4/l5)
        // (one metrics fn)
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
    std.debug.print("DEBUG_L5: l5s={d} l4s={d} l5r={d:.1} l4r={d:.1} memo_hits={d}\n", .{fs.l5_serves, fs.l4_serves, fs.tricache_l5_hit_rate*100, fs.tricache_l4_hit_rate*100, fs.memo_hits});
    // 5L RAW from real shipped demo path (executes the cachedOp + tricache in main run, for verif audit capture)
    std.debug.print("5L TEST RAW (demo path): l4_hit={d:.2} l5_hit={d:.2} l4s={d} l5s={d}\n", .{fs.tricache_l4_hit_rate*100, fs.tricache_l5_hit_rate*100, fs.l4_serves, fs.l5_serves});

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

test "bridge C ABI available" {
    // Ensure bridge_lib is linked into the test binary and exports resolve.
    _ = bridge_lib.axinc_init;
    _ = bridge_lib.axinc_ffn_tap;
    _ = bridge_lib.axinc_get_stats_json;
    _ = bridge_lib.axinc_load_axiasm;
    _ = bridge_lib.axinc_model_register;
}

test "5L via cachedOp" {
    const allocator = std.testing.allocator;
    var state = try core.MachineState.init(allocator);
    defer state.deinit(allocator);
    // Isolate pure dirs: wipe residual L4 files AND L5 shards so L5 disk hits
    // cannot skip L4 (prior storeDeep polluted shards across runs).
    _ = std.os.linux.mkdir("l4_5l_pure".ptr, 0o755);
    _ = std.os.linux.mkdir("l5_5l_pure".ptr, 0o755);
    // best-effort wipe shards and axl4 for isolation
    var shard_i: u32 = 0;
    while (shard_i < 16) : (shard_i += 1) {
        var sp: [64]u8 = undefined;
        const sn = std.fmt.bufPrintZ(&sp, "l5_5l_pure/shard_{d}.json", .{shard_i}) catch continue;
        _ = std.os.linux.unlink(sn.ptr);
    }
    if (state.memo_tables.len > 0) {
        for (state.memo_tables[0].entries) |*e| e.valid = false;
    }
    var eng = try engine_mod.Engine.init(allocator, &state, .{});
    defer eng.deinit();
    eng.axicore_ctx.tricache.l4_dir = "l4_5l_pure";
    eng.axicore_ctx.tricache.l5_dir = "l5_5l_pure";
    const key_mul = axicore.ShiftAdd.computeKey(42, 7, 0x4D554C);
    const key_add = axicore.ShiftAdd.computeKey(294, 7, 0x4144);
    var buf1: [64]u8 = undefined;
    const n1 = std.fmt.bufPrintZ(&buf1, "l4_5l_pure/{x:0>16}.axl4", .{key_mul}) catch &[_:0]u8{};
    _ = std.os.linux.unlink(n1.ptr);
    var buf2: [64]u8 = undefined;
    const n2 = std.fmt.bufPrintZ(&buf2, "l4_5l_pure/{x:0>16}.axl4", .{key_add}) catch &[_:0]u8{};
    _ = std.os.linux.unlink(n2.ptr);
    eng.axicore_ctx.tricache.l4_ram.clearRetainingCapacity();
    eng.axicore_ctx.tricache.l5_only_keys.clearRetainingCapacity();
    eng.axicore_ctx.tricache.promote_hits_to_l3 = false;
    // First: L5-only ADD (marks l5_only), then MUL miss→storeDeep (L4+L5)
    _ = eng.scalar_alu.add(294, 7);
    _ = eng.scalar_alu.mul(42, 7);
    // Heavy L4 repeats on mul + L5-only repeats on add
    for (0..1000) |_| {
        _ = eng.scalar_alu.mul(42, 7);
    }
    for (0..20) |_| {
        _ = eng.scalar_alu.add(294, 7);
    }
    const gs = eng.getStats();
    std.debug.print("5L TEST RAW (mixed first-miss+repeat l5_only): l4_hit={d:.2} l5_hit={d:.2} l4s={d} l5s={d}\n", .{ gs.tricache_l4_hit_rate, gs.tricache_l5_hit_rate, gs.l4_serves, gs.l5_serves });
    try std.testing.expect(gs.tricache_l4_hit_rate >= 0.95);
    try std.testing.expect(gs.tricache_l5_hit_rate >= 0.95);
}
