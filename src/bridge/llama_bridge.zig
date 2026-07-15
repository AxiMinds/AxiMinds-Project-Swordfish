// AxiMinds Neural Computer — llama.cpp Bridge (C ABI)
// Zig 0.16.0 + ZLS 0.16.0
// Minimal implementation for integration + demo entry point.
// See full vision + fixes in Conv-20260628-1155pm.md
// (AST/ASM modernized primitives available to hosted NC)
const std = @import("std");
const core = @import("../core/types.zig");
const engine_mod = @import("../core/engine.zig");
const isa = @import("../isa/opcodes.zig");
const log = std.log.scoped(.axinc_bridge);

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var global_state: ?*core.MachineState = null;
var global_engine: ?*engine_mod.Engine = null;

pub export fn axinc_init() callconv(.C) c_int {
    const allocator = gpa.allocator();
    if (global_state != null) return 0;
    const state = allocator.create(core.MachineState) catch return -1;
    state.* = core.MachineState.init(allocator) catch return -2;
    global_state = state;

    const eng = allocator.create(engine_mod.Engine) catch return -3;
    eng.* = engine_mod.Engine.init(allocator, state, .{}) catch return -4;
    global_engine = eng;

    log.info("[bridge] axinc_init success", .{});
    return 0;
}

pub export fn axinc_ffn_tap(cycles: c_ulonglong) callconv(.C) c_ulonglong {
    if (global_engine) |eng| {
        const ran = eng.executeTap() catch 0;
        return @intCast(ran);
    }
    return 0;
}

pub export fn axinc_get_stats_json(buf: [*]u8, len: usize) callconv(.C) usize {
    // Very small stub JSON
    const msg = "{\"cycles\":0,\"hit_rate\":0.0}";
    const to_copy = @min(msg.len, len - 1);
    @memcpy(buf[0..to_copy], msg[0..to_copy]);
    buf[to_copy] = 0;
    return to_copy;
}

pub export fn axinc_shutdown() callconv(.C) void {
    if (global_engine) |eng| {
        eng.deinit();
        const allocator = gpa.allocator();
        allocator.destroy(eng);
    }
    if (global_state) |st| {
        const allocator = gpa.allocator();
        st.deinit(allocator);
        allocator.destroy(st);
    }
    _ = gpa.deinit();
    global_state = null;
    global_engine = null;
}

// Simple main for "zig build run" / testing the core without llama
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("AxiMinds axicore (Swordfish) standalone demo\n", .{});

    var state = try core.MachineState.init(allocator);
    defer state.deinit(allocator);

    var eng = try engine_mod.Engine.init(allocator, &state, .{ .max_cycles_per_tap = 128 });
    defer eng.deinit();

    const prog = [_]isa.Instruction{
        isa.Builder.movi(1, 100),
        isa.Builder.movi(2, 23),
        isa.Builder.add(3, 1, 2),
        isa.Builder.mul(4, 3, 2),
        isa.Builder.dream(5),
        isa.Builder.dpix(0, 0, 4),
        isa.Builder.halt(),
    };
    try eng.loadProgram(&prog);

    const ran = try eng.executeTap();
    const stats = eng.getStats();

    std.debug.print("Executed {d} cycles. R3={d} R4={d}\n", .{ ran, state.regs.getGP(3), state.regs.getGP(4) });
    std.debug.print("Stats: hit_rate={d:.2} vram={d}MB dream={}\n", .{
        stats.tricache_overall_hit_rate, stats.vram_usage_mb, stats.dream_mode,
    });

    std.debug.print("Demo complete. (See HTML ocean demo concept in Conv log.)\n", .{});
}
