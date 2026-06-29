// AxiMinds Neural Computer — Execution Engine
// Zig 0.16.0 + ZLS 0.16.0
// Fetch/decode/execute with axicore integration, self-mod (EMIT/LEARN/FUSE/LANG)
// PC safety, functional HOOK/canvas stubs applied per review fixes.
// From Conv-20260628-1155pm.md. LANG now has basic AST-backed lowering support.
const std = @import("std");
const core = @import("types.zig");
const axicore = @import("axicore.zig");
const isa = @import("../isa/opcodes.zig");
const alu_mod = @import("alu.zig");
const asm_lower = @import("../asm/lower.zig");
const log = std.log.scoped(.axinc_exec);

pub const ExecutionError = error{
    InvalidOpcode, MemoryAccessViolation, DivisionByZero,
    StackOverflow, StackUnderflow, ProgramCounterOutOfBounds,
    HookNotAvailable, CustomOpcodeNotFound, CanvasOutOfBounds,
};

pub const TraceEntry = struct {
    cycle: u64,
    pc: u64,
    instruction: isa.Instruction,
    result: ?i64 = null,
    memo_hit: bool = false,
    dream_mode: bool = false,
};

pub const EngineConfig = struct {
    max_cycles_per_tap: u64 = 1024,
    trace_enabled: bool = false,
    trace_buffer_size: usize = 4096,
    memo_enabled: bool = true,
    dream_max_cycles: u64 = 1_000_000,
    self_modify_enabled: bool = true,
};

pub const Engine = struct {
    state: *core.MachineState,
    axicore_ctx: axicore.AxicoreContext,
    scalar_alu: alu_mod.ScalarAlu,
    custom_registry: isa.CustomOpcodeRegistry,
    config: EngineConfig,
    trace: ?[]TraceEntry = null,
    trace_pos: usize = 0,
    allocator: std.mem.Allocator,
    cycles_this_tap: u64 = 0,
    instructions_this_tap: u64 = 0,
    memo_hits_this_tap: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, state: *core.MachineState, config: EngineConfig) !Engine {
        var trace: ?[]TraceEntry = null;
        if (config.trace_enabled) {
            trace = try allocator.alloc(TraceEntry, config.trace_buffer_size);
        }
        var ctx = try axicore.AxicoreContext.init(allocator);
        var eng = Engine{
            .state = state,
            .axicore_ctx = ctx,
            .scalar_alu = alu_mod.ScalarAlu.init(&ctx),
            .custom_registry = .{},
            .config = config,
            .trace = trace,
            .allocator = allocator,
        };
        eng.scalar_alu = alu_mod.ScalarAlu.init(&eng.axicore_ctx);
        log.info("[axiNC] engine init | max_tap={d}", .{config.max_cycles_per_tap});
        return eng;
    }

    pub fn deinit(self: *Engine) void {
        if (self.trace) |t| self.allocator.free(t);
        self.axicore_ctx.deinit();
    }

    pub fn executeTap(self: *Engine) !u64 {
        self.cycles_this_tap = 0;
        self.instructions_this_tap = 0;
        self.memo_hits_this_tap = 0;
        const max = self.config.max_cycles_per_tap;
        self.state.running = true;

        while (self.state.running and self.cycles_this_tap < max) {
            if (self.state.regs.flags.halted) break;

            const old_pc = self.state.regs.pc;
            if (old_pc > 1024 * 1024) return error.ProgramCounterOutOfBounds; // guard

            const word = self.fetch(old_pc) catch |e| {
                log.err("fetch fail pc={d}: {}", .{old_pc, e});
                self.state.running = false;
                break;
            };

            const instr = isa.Instruction.decode(word);
            self.execute(instr) catch |err| {
                log.err("[axiNC] exec err pc=0x{X} {}", .{old_pc, err});
                self.state.regs.flags.halted = true;
                self.state.running = false;
                break;
            };

            // SAFE PC advance (review fix): only inc if not changed by jump/control
            if (self.state.regs.pc == old_pc) {
                self.state.regs.pc += 1;
            }
            // Bounds clamp
            if (self.state.regs.pc >= self.state.mem.program_end / 4) {
                self.state.regs.pc = self.state.mem.program_end / 4;
            }

            self.state.regs.cycle_count += 1;
            self.cycles_this_tap += 1;
            self.instructions_this_tap += 1;

            if (self.state.dream_mode) {
                self.state.dream_cycles_remaining -|= 1;
                if (self.state.dream_cycles_remaining == 0) {
                    self.state.wake();
                }
            }
        }
        self.state.total_cycles += self.cycles_this_tap;
        self.state.total_instructions += self.instructions_this_tap;
        return self.cycles_this_tap;
    }

    fn fetch(self: *Engine, pc: u64) !u32 {
        const addr = core.PROGRAM_BASE + pc * 4;
        const b0 = try self.state.mem.read8(addr);
        const b1 = try self.state.mem.read8(addr + 1);
        const b2 = try self.state.mem.read8(addr + 2);
        const b3 = try self.state.mem.read8(addr + 3);
        return (@as(u32, b0)) | (@as(u32, b1) << 8) | (@as(u32, b2) << 16) | (@as(u32, b3) << 24);
    }

    fn execute(self: *Engine, instr: isa.Instruction) !void {
        const op: isa.Opcode = @enumFromInt(instr.opcode);

        if (self.trace) |t| {
            t[self.trace_pos % t.len] = .{ .cycle = self.state.regs.cycle_count, .pc = self.state.regs.pc, .instruction = instr, .dream_mode = self.state.dream_mode };
            self.trace_pos += 1;
        }

        if (instr.isCustom()) {
            return self.executeCustom(instr);
        }

        switch (op) {
            .ADD => {
                const r = self.scalar_alu.add(self.state.regs.getGP(instr.rs1), self.state.regs.getGP(instr.rs2));
                self.state.regs.setGP(instr.rd, r.value);
                self.state.regs.updateFlags(r.value, r.carry, r.overflow);
                self.state.regs.pc += 1;
            },
            .SUB => {
                const r = self.scalar_alu.sub(self.state.regs.getGP(instr.rs1), self.state.regs.getGP(instr.rs2));
                self.state.regs.setGP(instr.rd, r.value);
                self.state.regs.updateFlags(r.value, r.carry, r.overflow);
                self.state.regs.pc += 1;
            },
            .MUL => {
                const r = self.scalar_alu.mul(self.state.regs.getGP(instr.rs1), self.state.regs.getGP(instr.rs2));
                self.state.regs.setGP(instr.rd, r.value);
                if (r.cache_hit) self.memo_hits_this_tap += 1;
                self.state.regs.pc += 1;
            },
            .DIV => {
                const r = try self.scalar_alu.div(self.state.regs.getGP(instr.rs1), self.state.regs.getGP(instr.rs2));
                self.state.regs.setGP(instr.rd, r.value);
                self.state.regs.pc += 1;
            },
            .MOD => {
                const r = try self.scalar_alu.mod(self.state.regs.getGP(instr.rs1), self.state.regs.getGP(instr.rs2));
                self.state.regs.setGP(instr.rd, r.value);
                self.state.regs.pc += 1;
            },
            .SHL => {
                const a = self.state.regs.getGP(instr.rs1);
                const sh: u6 = @intCast(instr.imm9 & 0x3F);
                const val = a << sh;
                self.state.regs.setGP(instr.rd, val);
                self.state.regs.pc += 1;
            },
            .SHR => {
                const a = self.state.regs.getGP(instr.rs1);
                const sh: u6 = @intCast(instr.imm9 & 0x3F);
                const val = a >> sh;
                self.state.regs.setGP(instr.rd, val);
                self.state.regs.pc += 1;
            },
            .AND => {
                const val = self.state.regs.getGP(instr.rs1) & self.state.regs.getGP(instr.rs2);
                self.state.regs.setGP(instr.rd, val);
                self.state.regs.pc += 1;
            },
            .OR, .XOR => {
                const val = if (op == .OR) (self.state.regs.getGP(instr.rs1) | self.state.regs.getGP(instr.rs2))
                            else (self.state.regs.getGP(instr.rs1) ^ self.state.regs.getGP(instr.rs2));
                self.state.regs.setGP(instr.rd, val);
                self.state.regs.pc += 1;
            },
            .MOV => {
                const val = self.state.regs.getGP(instr.rs1);
                self.state.regs.setGP(instr.rd, val);
                self.state.regs.pc += 1;
            },
            .MOVI => {
                self.state.regs.setGP(instr.rd, @intCast(instr.imm9));
                self.state.regs.pc += 1;
            },
            .JMP => { self.state.regs.pc = @intCast(instr.imm9); },
            .JZ => { if (self.state.regs.flags.zero) self.state.regs.pc = @intCast(instr.imm9) else self.state.regs.pc += 1; },
            .JNZ => { if (!self.state.regs.flags.zero) self.state.regs.pc = @intCast(instr.imm9) else self.state.regs.pc += 1; },
            .HALT => { self.state.regs.flags.halted = true; self.state.running = false; },
            .YIELD => { self.state.regs.pc += 1; self.state.running = false; },
            .NOP => { self.state.regs.pc += 1; },
            .DREAM => {
                self.state.enterDream(@intCast(instr.imm9));
                self.state.regs.pc += 1;
            },
            .WAKE => {
                self.state.wake();
                self.state.running = false;
            },
            .DPIX => {
                const x: u32 = @truncate(@as(u64, @bitCast(self.state.regs.getGP(instr.rs1))));
                const y: u32 = @truncate(@as(u64, @bitCast(self.state.regs.getGP(instr.rs2))));
                const col: u32 = @truncate(@as(u64, @bitCast(self.state.regs.getGP(instr.rd))));
                self.state.canvas.setPixel(x, y, @bitCast(col));
                log.info("[axiNC] DPIX {d},{d}", .{x, y});
                self.state.regs.pc += 1;
            },
            .DBLK => {
                // Simplified: use rs1 as base vector reg index, imm for w/h
                const x: u32 = @truncate(@as(u64, @bitCast(self.state.regs.getGP(instr.rs1))));
                const y: u32 = @truncate(@as(u64, @bitCast(self.state.regs.getGP(instr.rs2))));
                // For demo, write a small block of constant color
                var data: [16]i32 = [_]i32{@bitCast(@as(u32, 0xFF00FF00))} ** 16; // green-ish
                self.state.canvas.writeBlock(x, y, 4, 4, &data);
                log.info("[axiNC] DBLK block write", .{});
                self.state.regs.pc += 1;
            },
            .EMIT => {
                if (!self.config.self_modify_enabled) { self.state.regs.pc += 1; return; }
                const word: u32 = @truncate(@as(u64, @bitCast(self.state.regs.getGP(instr.rs1))));
                const target = core.PROGRAM_BASE + @as(u64, @bitCast(self.state.regs.getGP(instr.rs2))) * 4;
                const bytes: [4]u8 = @bitCast(word);
                for (bytes, 0..) |b, i| try self.state.mem.write8(target + i, b);
                self.state.regs.flags.self_modify = true;
                log.info("[axiNC] EMIT 0x{X:0>8}", .{word});
                self.state.regs.pc += 1;
            },
            .LEARN => {
                if (!self.config.self_modify_enabled) { self.state.regs.pc += 1; return; }
                const value = self.state.regs.getGP(instr.rd);
                const key = axicore.ShiftAdd.computeKey(0, @intCast(value), 0x4C524E);
                self.axicore_ctx.tricache.store(key, value, 0x4C524E);
                log.info("[axiNC] LEARN value={d}", .{value});
                self.state.regs.pc += 1;
            },
            .FUSE => {
                if (!self.config.self_modify_enabled) { self.state.regs.pc += 1; return; }
                const len: usize = @min(@as(usize, instr.imm9), isa.MAX_FUSED_SEQUENCE);
                if (len == 0) { self.state.regs.pc += 1; return; }
                var seq: [isa.MAX_FUSED_SEQUENCE]isa.Instruction = undefined;
                const start = self.state.regs.getGP(instr.rs1);
                for (0..len) |i| {
                    const w = try self.fetch(@intCast(start + @as(i64, @intCast(i))));
                    seq[i] = isa.Instruction.decode(w);
                }
                if (self.custom_registry.register("FUSED", seq[0..len])) |id| {
                    self.state.regs.setGP(instr.rd, @intCast(id));
                    self.state.custom_opcodes += 1;
                }
                self.state.regs.pc += 1;
            },
            .LANG => {
                // Zig 0.16.0: Use std.zig.Ast based lowering for "grammar" expressions.
                // For demo we synthesize a small expression from imm and do lowering.
                // In full system the inner LLM would write a source blob into memory;
                // here we demonstrate the path.
                const expr = if (instr.imm9 > 0) "(r1 << 1) + r2 * 3" else "r1 + r2";
                if (asm_lower.lowerAndFuse(self.allocator, &self.custom_registry, "LANG_EXPR", expr) catch null) |new_id| {
                    self.state.regs.setGP(instr.rd, @intCast(new_id));
                    log.info("[axiNC] LANG (AST) registered '{s}' as 0x{X:0>2}", .{ expr, new_id });
                } else {
                    self.state.regs.setGP(instr.rd, 0xC0 + self.custom_registry.count);
                    log.info("[axiNC] LANG (AST fallback) placeholder", .{});
                }
                self.state.regs.pc += 1;
            },
            .HOOK => {
                const hid: u8 = @truncate(instr.imm9 & 0x7);
                // Functional stub: mark pending and simulate callback dispatch
                self.state.regs.flags.hook_pending = true;
                self.state.hooks_active |= (@as(u32, 1) << @as(u5, @intCast(hid & 0x1f)));
                log.info("[axiNC] HOOK id={d} (stub dispatch)", .{hid});
                self.state.regs.pc += 1;
            },
            else => {
                log.warn("[axiNC] unimplemented op 0x{X:0>2}", .{instr.opcode});
                self.state.regs.pc += 1;
            },
        }
    }

    fn executeCustom(self: *Engine, instr: isa.Instruction) !void {
        const slot = instr.customSlot() orelse return error.CustomOpcodeNotFound;
        if (self.custom_registry.expand(slot)) |seq| {
            for (seq) |si| try self.execute(si);
        }
    }

    pub fn loadProgram(self: *Engine, instructions: []const isa.Instruction) !void {
        const size_needed = instructions.len * 4;
        if (size_needed > self.state.mem.size / 2) {
            log.warn("Program large, consider splitting", .{});
        }
        var buf = try self.allocator.alloc(u8, size_needed);
        defer self.allocator.free(buf);
        for (instructions, 0..) |instr, i| {
            const w = instr.encode();
            const bytes: [4]u8 = @bitCast(w);
            @memcpy(buf[i*4 .. i*4+4], &bytes);
        }
        try self.state.mem.loadProgram(buf);
        self.state.regs.pc = 0;
        self.state.regs.sp = core.STACK_BASE;
        log.info("[axiNC] loadProgram {d} instrs", .{instructions.len});
    }

    pub const Stats = struct {
        total_cycles: u64,
        total_instructions: u64,
        custom_opcodes: u16,
        tricache_overall_hit_rate: f32,
        energy_saved: u64,
        vram_usage_mb: usize,
        dream_mode: bool,
    };

    pub fn getStats(self: *const Engine) Stats {
        const cs = self.axicore_ctx.tricache.stats();
        return .{
            .total_cycles = self.state.total_cycles,
            .total_instructions = self.state.total_instructions,
            .custom_opcodes = self.state.custom_opcodes,
            .tricache_overall_hit_rate = cs.overall_hit_rate,
            .energy_saved = self.axicore_ctx.energy_saved_estimate,
            .vram_usage_mb = self.state.vramUsageMB(),
            .dream_mode = self.state.dream_mode,
        };
    }
};

// Tests from conv + new
test "engine: basic add/mul/halt" {
    const allocator = std.testing.allocator;
    var state = try core.MachineState.init(allocator);
    defer state.deinit(allocator);

    var eng = try Engine.init(allocator, &state, .{});
    defer eng.deinit();

    const prog = [_]isa.Instruction{
        isa.Builder.movi(1, 7),
        isa.Builder.movi(2, 6),
        isa.Builder.mul(3, 1, 2),
        isa.Builder.halt(),
    };
    try eng.loadProgram(&prog);
    _ = try eng.executeTap();
    try std.testing.expectEqual(@as(i64, 42), state.regs.getGP(3));
}
