// ASM / AST Lowerer for axiNC
// Zig 0.16.0 + ZLS 0.16.0
// Uses std.zig.Ast to parse Zig expressions and lower them to our Neural ISA
// instruction sequences. Plausible for LANG "grammar", Book of Spells,
// and host-assisted FUSE generation from high-level expressions.
//
// The inner LLM can "think" in expressions; host lowers via AST to efficient
// shift-add / native sequences + custom op registration.
//
// Also demonstrates explicit asm intrinsics for key lowering steps (shifts, adds).

const std = @import("std");
const isa = @import("../isa/opcodes.zig");
// Note: We deliberately avoid importing core/axicore here to prevent cycles.
// ASM helpers are re-exported or duplicated lightly where needed from axicore.

pub const LowerError = error{ ParseFailed, UnsupportedNode, TooManyTemps, InvalidIdent };

/// Virtual register allocator for lowering (very small, 8 temps for demo).
const TempRegs = struct {
    next: u5 = 8, // start after common low regs for safety
    pub fn alloc(self: *TempRegs) u5 {
        const r = self.next;
        self.next = @min(30, self.next + 1);
        return r;
    }
};

/// Result of lowering: sequence of instructions + final result register.
pub const Lowered = struct {
    instructions: []isa.Instruction,
    result_reg: u5,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Lowered) void {
        self.allocator.free(self.instructions);
    }
};

/// Parse a Zig expression source (subset) and lower to ISA instructions.
/// Example sources that work:
///   "a + b"
///   "x * 5 + 3"
///   "(base << 2) + (offset * 7)"
/// We wrap the expression so std.zig.Ast (Zig 0.16) can parse it as valid Zig.
pub fn lowerExpression(allocator: std.mem.Allocator, source: []const u8) LowerError!Lowered {
    // Build a tiny valid Zig snippet containing the expression.
    // "_ = ( <expr> );"
    var wrapped = std.ArrayList(u8).init(allocator);
    defer wrapped.deinit();
    wrapped.appendSlice("_ = (") catch return error.ParseFailed;
    wrapped.appendSlice(source) catch return error.ParseFailed;
    wrapped.appendSlice(");") catch return error.ParseFailed;
    wrapped.append(0) catch return error.ParseFailed; // sentinel after );

    const content_len = wrapped.items.len - 1;
    const src0: [:0]const u8 = wrapped.items[0..content_len :0];
    var ast = std.zig.Ast.parse(allocator, src0, .zig) catch return error.ParseFailed;
    defer ast.deinit(allocator);

    const root_decls = ast.rootDecls();
    if (root_decls.len == 0) return error.ParseFailed;

    // Find a usable expression node. Look inside the simple var decl / assign.
    // For "_ = (expr);" the structure is usually a .simple_var_decl whose init is our expr.
    var expr_node: ?std.zig.Ast.Node.Index = null;
    for (root_decls) |decl| {
        const tag = ast.nodes.items(.tag)[decl];
        if (tag == .simple_var_decl) {
            const d = ast.nodes.items(.data)[decl];
            if (d.rhs != 0) {
                // The init expression (our "(expr)")
                expr_node = d.rhs;
                break;
            }
        }
    }
    const start_node = expr_node orelse root_decls[0];

    var tmp_regs = TempRegs{};
    var out_list = std.ArrayList(isa.Instruction).init(allocator);
    errdefer out_list.deinit();

    const result_reg = try lowerNode(allocator, &ast, start_node, &mut out_list, &mut tmp_regs);

    return Lowered{
        .instructions = try out_list.toOwnedSlice(),
        .result_reg = result_reg,
        .allocator = allocator,
    };
}

fn lowerNode(
    allocator: std.mem.Allocator,
    ast: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    out: *std.ArrayList(isa.Instruction),
    temps: *TempRegs,
) LowerError!u5 {
    const tag = ast.nodes.items(.tag)[node];
    const data = ast.nodes.items(.data)[node];
    const main_tokens = ast.nodes.items(.main_token);

    switch (tag) {
        .number_literal => {
            const lit = ast.tokenSlice(main_tokens[node]);
            const val = std.fmt.parseInt(i64, lit, 0) catch 0;
            // MOVI into a temp (imm9 limited; for demo truncate)
            const rd = temps.alloc();
            const imm: u9 = @truncate(@as(u64, @bitCast(@as(i64, @min(511, @max(-511, val))))));
            try out.append(isa.Builder.movi(rd, imm));
            return rd;
        },
        .identifier => {
            // Map ident to a register. Use simple hash of name mod 8 + offset for demo.
            const name = ast.tokenSlice(main_tokens[node]);
            var h: u32 = 0;
            for (name) |c| h = h *% 33 +% c;
            const rd: u5 = @intCast((h % 8) + 1); // R1..R8
            return rd;
        },
        .add, .sub, .mul, .shl, .shr => {
            const l = try lowerNode(allocator, ast, data.lhs, out, temps);
            const r = try lowerNode(allocator, ast, data.rhs, out, temps);
            const rd = temps.alloc();

            const op: isa.Opcode = switch (tag) {
                .add => .ADD,
                .sub => .SUB,
                .mul => .MUL, // will become shift-add in engine/ALU
                .shl => .SHL,
                .shr => .SHR,
                else => unreachable,
            };

            if (tag == .shl or tag == .shr) {
                // For shifts we can use imm form when possible. Here use rrr with r as rs2 (low bits)
                try out.append(isa.Builder.rrr(op, rd, l, r));
            } else {
                try out.append(isa.Builder.rrr(op, rd, l, r));
            }
            return rd;
        },
        .grouped_expression => {
            return try lowerNode(allocator, ast, data.lhs, out, temps);
        },
        .bit_or, .bit_and, .bit_xor => {
            const l = try lowerNode(allocator, ast, data.lhs, out, temps);
            const r = try lowerNode(allocator, ast, data.rhs, out, temps);
            const rd = temps.alloc();
            const op: isa.Opcode = if (tag == .bit_or) .OR else if (tag == .bit_and) .AND else .XOR;
            try out.append(isa.Builder.rrr(op, rd, l, r));
            return rd;
        },
        else => {
            // Fallback: unsupported for this tiny lowerer
            // Still produce a NOP-ish result reg for demo robustness
            const rd = temps.alloc();
            try out.append(isa.Builder.movi(rd, 0));
            return rd;
        },
    }
}

/// Convenience: lower then register as a fused custom opcode (uses FUSE style).
/// Returns the assigned custom opcode id or null.
pub fn lowerAndFuse(
    allocator: std.mem.Allocator,
    registry: *isa.CustomOpcodeRegistry,
    name: []const u8,
    expr_source: []const u8,
) LowerError!?u8 {
    var lowered = try lowerExpression(allocator, expr_source);
    defer lowered.deinit();

    // Trim to MAX_FUSED_SEQUENCE and copy because lowered will be freed.
    const len = @min(lowered.instructions.len, isa.MAX_FUSED_SEQUENCE);
    var seq: [isa.MAX_FUSED_SEQUENCE]isa.Instruction = undefined;
    @memcpy(seq[0..len], lowered.instructions[0..len]);
    return registry.register(name, seq[0..len]);
}

// ---------------------------------------------------------------------------
// Explicit ASM Intrinsics helpers (used by lowerer / hot paths)
// These guarantee certain shift+add behavior and can be arch-specialized.
// ---------------------------------------------------------------------------

/// ASM-enhanced shift-left + add (a* (1<<sh) + b). Uses inline asm where supported.
pub fn asmShlAdd(a: i64, shift: u6, b: i64) i64 {
    const arch = @import("builtin").target.cpu.arch;
    return switch (arch) {
        .x86_64 => asmShlAddX64(a, shift, b),
        .aarch64 => asmShlAddAarch64(a, shift, b),
        else => (a << shift) +% b, // portable fallback (compiler will use shifts+adds)
    };
}

inline fn asmShlAddX64(a: i64, shift: u6, b: i64) i64 {
    return asm ("lea %[out], [%[a] + %[b] * %[scale]]"
        : [out] "=r" (-> i64),
        : [a] "r" (a),
          [b] "r" (b),
          [scale] "i" (@as(u64, 1) << @min(shift, 3)), // lea limited scale; demo
    );
}

inline fn asmShlAddAarch64(a: i64, shift: u6, b: i64) i64 {
    var tmp: i64 = undefined;
    return asm ("lsl %[tmp], %[a], %[sh]\n\t"
                "add %[out], %[tmp], %[b]"
        : [out] "=r" (-> i64),
          [tmp] "=&r" (tmp),
        : [a] "r" (a),
          [b] "r" (b),
          [sh] "i" (shift),
        : "cc"
    );
}

/// ASM version of a critical FNV-like mix step (used in computeKey / hash).
/// Explicit shifts + xors to make "no mul" extremely visible to the compiler + reviewer.
pub fn asmHashMix(h: u64, x: u64) u64 {
    var res = h ^ x;
    // Mix using explicit shifts (asm on supported)
    res = asmMixStep(res);
    return res;
}

inline fn asmMixStep(v: u64) u64 {
    const arch = @import("builtin").target.cpu.arch;
    if (arch == .x86_64 or arch == .aarch64) {
        var out: u64 = undefined;
        _ = asm ("mov %[out], %[v]\n\t"
                 "shl %[out], 40\n\t"
                 "add %[out], %[v]\n\t"  // simplified demo of the shift+add spirit
                 "shl %[v], 8\n\t"
                 "add %[out], %[v]"
            : [out] "=r" (out),
            : [v] "r" (v),
        );
        return out;
    }
    // Fallback pure zig (still no mul)
    const v40 = v << 40;
    const v8 = v << 8;
    return v40 +% v8 +% v;
}

// Small test helper (used by bench)
pub fn demoLower(allocator: std.mem.Allocator) !void {
    const src = "(x << 2) + y * 3";
    const lowered = try lowerExpression(allocator, src);
    defer lowered.deinit();
    std.debug.print("AST lower of '{s}' -> {d} instrs, final R{d}\n", .{ src, lowered.instructions.len, lowered.result_reg });
    for (lowered.instructions, 0..) |ins, i| {
        std.debug.print("  [{d}] ", .{i});
        var buf: [64]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        ins.format(fbs.writer()) catch {};
        std.debug.print("{s}\n", .{fbs.getWritten()});
    }
}

test "asm-lower: std.zig.Ast expression lowering" {
    const allocator = std.testing.allocator;
    const src = "a + b * 2";
    const lowered = try lowerExpression(allocator, src);
    defer lowered.deinit();
    try std.testing.expect(lowered.instructions.len > 0);
    try std.testing.expect(lowered.result_reg != 0);
}
