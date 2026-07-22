// AxiMinds axiNC — C ABI bridge library root (Zig 0.16)
// Root lives under src/ so relative imports work (avoids "outside module path").
// Exports for llama.cpp / host integration + full stats / program load / model slots.
//
// SOURCES: prior llama_bridge.zig + Claude-Remote/NoDev patterns for host integration.

const std = @import("std");
const build_options = @import("build_options");
// Touch option so module is used (dev/debug.zig also imports it transitively).
comptime {
    _ = build_options.dev_debug;
}
const core = @import("core/types.zig");
const engine_mod = @import("core/engine.zig");
const isa = @import("isa/opcodes.zig");
const assembler = @import("asm/assembler.zig");
const models = @import("models/host.zig");
const log = std.log.scoped(.axinc_bridge);

// Zig 0.16: DebugAllocator replaces GeneralPurposeAllocator
var gpa_state: std.heap.DebugAllocator(.{}) = .init;
var global_state: ?*core.MachineState = null;
var global_engine: ?*engine_mod.Engine = null;
var global_models: models.ModelHost = .{};

fn allocator() std.mem.Allocator {
    return gpa_state.allocator();
}

/// Initialize global machine + engine. Idempotent (returns 0 if already init).
pub export fn axinc_init() callconv(.c) c_int {
    if (global_state != null) return 0;
    const a = allocator();
    const state = a.create(core.MachineState) catch return -1;
    state.* = core.MachineState.init(a) catch {
        a.destroy(state);
        return -2;
    };
    global_state = state;

    const eng = a.create(engine_mod.Engine) catch {
        state.deinit(a);
        a.destroy(state);
        global_state = null;
        return -3;
    };
    eng.* = engine_mod.Engine.init(a, state, .{ .max_cycles_per_tap = 1024 }) catch {
        state.deinit(a);
        a.destroy(state);
        a.destroy(eng);
        global_state = null;
        return -4;
    };
    global_engine = eng;
    global_models = models.ModelHost.init(a);
    log.info("[bridge] axinc_init success", .{});
    return 0;
}

/// Run up to `cycles` instructions (or max_cycles_per_tap). Returns cycles executed.
pub export fn axinc_ffn_tap(cycles: c_ulonglong) callconv(.c) c_ulonglong {
    if (global_engine) |eng| {
        if (cycles > 0) eng.config.max_cycles_per_tap = @intCast(cycles);
        eng.state.regs.flags.halted = false;
        eng.state.running = true;
        const ran = eng.executeTap() catch 0;
        return @intCast(ran);
    }
    return 0;
}

/// Write JSON stats into buf (NUL-terminated). Returns bytes written (excluding NUL).
pub export fn axinc_get_stats_json(buf: [*]u8, len: usize) callconv(.c) usize {
    if (len == 0) return 0;
    if (global_engine) |eng| {
        const s = eng.getStats();
        const msg = std.fmt.bufPrint(buf[0 .. len - 1],
            \\{{"cycles":{d},"instructions":{d},"hit_rate":{d:.4},"l4_hit":{d:.4},"l5_hit":{d:.4},"energy_saved":{d},"vram_mb":{d},"dream":{s},"custom_ops":{d},"fused":{d},"models":{d}}}
        , .{
            s.total_cycles,
            s.total_instructions,
            s.tricache_overall_hit_rate,
            s.tricache_l4_hit_rate,
            s.tricache_l5_hit_rate,
            s.energy_saved,
            s.vram_usage_mb,
            if (s.dream_mode) "true" else "false",
            s.custom_opcodes,
            s.total_fused_ops,
            global_models.count(),
        }) catch {
            const fallback = "{\"error\":\"buf_small\"}";
            const n = @min(fallback.len, len - 1);
            @memcpy(buf[0..n], fallback[0..n]);
            buf[n] = 0;
            return n;
        };
        buf[msg.len] = 0;
        return msg.len;
    }
    const msg = "{\"error\":\"not_init\"}";
    const n = @min(msg.len, len - 1);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
    return n;
}

/// Load a raw instruction word array (little-endian u32 each). n = instruction count.
pub export fn axinc_load_program(words: [*]const u32, n: usize) callconv(.c) c_int {
    if (global_engine == null) return -1;
    if (n == 0 or n > 65536) return -2;
    const a = allocator();
    var instrs = a.alloc(isa.Instruction, n) catch return -3;
    defer a.free(instrs);
    for (0..n) |i| {
        instrs[i] = isa.Instruction.decode(words[i]);
    }
    global_engine.?.loadProgram(instrs) catch return -4;
    global_engine.?.state.regs.flags.halted = false;
    global_engine.?.state.running = true;
    return 0;
}

/// Assemble axiASM text and load into NC. text must be NUL-terminated or pass len.
pub export fn axinc_load_axiasm(text: [*:0]const u8) callconv(.c) c_int {
    if (global_engine == null) return -1;
    const a = allocator();
    const src = std.mem.span(text);
    const prog = assembler.assemble(a, src) catch return -2;
    defer a.free(prog);
    global_engine.?.loadProgram(prog) catch return -3;
    global_engine.?.state.regs.flags.halted = false;
    global_engine.?.state.running = true;
    return @intCast(prog.len);
}

/// Register / "spawn" a secondary model slot (GGUF path or Ollama tag).
/// kind: 0=ollama tag, 1=gguf path
pub export fn axinc_model_register(kind: c_int, name_or_path: [*:0]const u8) callconv(.c) c_int {
    const s = std.mem.span(name_or_path);
    const k: models.ModelKind = if (kind == 1) .gguf else .ollama;
    const id = global_models.register(k, s) catch return -1;
    return @intCast(id);
}

/// Run inference on a registered model slot (Ollama chat or GGUF metadata echo for MVP).
/// Returns length written to out_buf, or negative error.
pub export fn axinc_model_infer(slot: c_int, prompt: [*:0]const u8, out_buf: [*]u8, out_len: usize) callconv(.c) c_int {
    if (out_len == 0) return -1;
    const a = allocator();
    // Need Io for process.run — use a minimal threaded Io for C ABI callers.
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const result = global_models.infer(a, io, @intCast(slot), std.mem.span(prompt)) catch return -2;
    defer a.free(result);
    const n = @min(result.len, out_len - 1);
    @memcpy(out_buf[0..n], result[0..n]);
    out_buf[n] = 0;
    return @intCast(n);
}

pub export fn axinc_shutdown() callconv(.c) void {
    const a = allocator();
    global_models.deinit();
    if (global_engine) |eng| {
        eng.deinit();
        a.destroy(eng);
    }
    if (global_state) |st| {
        st.deinit(a);
        a.destroy(st);
    }
    _ = gpa_state.deinit();
    gpa_state = .init;
    global_state = null;
    global_engine = null;
}

// Also provide a test that exercises the C path from Zig.
test "bridge C ABI init tap stats shutdown" {
    try std.testing.expectEqual(@as(c_int, 0), axinc_init());
    try std.testing.expectEqual(@as(c_int, 0), axinc_init()); // idempotent
    // Load minimal program: MOVI R1, 10; MOVI R2, 3; MUL R3,R1,R2; HALT
    const words = [_]u32{
        isa.Builder.movi(1, 10).encode(),
        isa.Builder.movi(2, 3).encode(),
        isa.Builder.mul(3, 1, 2).encode(),
        isa.Builder.halt().encode(),
    };
    try std.testing.expectEqual(@as(c_int, 0), axinc_load_program(&words, words.len));
    const ran = axinc_ffn_tap(64);
    try std.testing.expect(ran > 0);
    var buf: [512]u8 = undefined;
    const n = axinc_get_stats_json(&buf, buf.len);
    try std.testing.expect(n > 10);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "cycles") != null);
    // axiASM path
    const asm_z = "MOVI R1, 5\nMOVI R2, 5\nADD R3, R1, R2\nHALT\n";
    const n_asm = axinc_load_axiasm(asm_z);
    try std.testing.expect(n_asm >= 4);
    _ = axinc_ffn_tap(32);
    axinc_shutdown();
}

test "bridge C ABI axinc_model_infer GGUF full forward path" {
    try std.testing.expectEqual(@as(c_int, 0), axinc_init());
    defer axinc_shutdown();

    // Register fixture GGUF (real parse + weight probe at register + forward on infer)
    const path_z = "src/models/fixtures/tiny.gguf";
    const slot = axinc_model_register(1, path_z); // 1 = gguf
    try std.testing.expect(slot >= 0);

    var out: [4096]u8 = undefined;
    const n = axinc_model_infer(slot, "hello-weights", &out, out.len);
    try std.testing.expect(n > 0);
    const text = out[0..@intCast(n)];
    try std.testing.expect(std.mem.indexOf(u8, text, "status=forward_ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "weight_probe_sum_f32=512") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "token_embd.weight") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "generated=") != null);
}
