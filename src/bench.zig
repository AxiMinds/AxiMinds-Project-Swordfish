// axinc-bench stub
// Zig 0.16.0 + ZLS 0.16.0
// Run with: zig build bench
// Exercises AST lowerer + asm intrinsics paths.
const std = @import("std");
const core = @import("core/types.zig");
const axicore = @import("core/axicore.zig");
const engine = @import("core/engine.zig");
const isa = @import("isa/opcodes.zig");
const asm_lower = @import("asm/lower.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("axinc-bench (Zig 0.16 + AST + ASM intrinsics)\n", .{});

    // Exercise AST lowerer (std.zig.Ast)
    try asm_lower.demoLower(allocator);

    // Exercise asm intrinsics directly
    const shl = axicore.asmShlAdd(100, 3, 7);
    std.debug.print("asmShlAdd(100,3,7) = {d}\n", .{shl});
    const has = axicore.asmHashMix(0xdead, 0xbeef);
    std.debug.print("asmHashMix demo = 0x{X}\n", .{has});

    var state = try core.MachineState.init(allocator);
    defer state.deinit(allocator);
    var eng = try engine.Engine.init(allocator, &state, .{});
    defer eng.deinit();

    const prog = [_]isa.Instruction{
        isa.Builder.movi(1, 123),
        isa.Builder.movi(2, 456),
        isa.Builder.mul(3, 1, 2),
        isa.Builder.halt(),
    };
    try eng.loadProgram(&prog);
    _ = try eng.executeTap();
    const s = eng.getStats();
    std.debug.print("bench cycles={d} hit={d:.1}%\n", .{ s.total_cycles, s.tricache_overall_hit_rate * 100 });
}
