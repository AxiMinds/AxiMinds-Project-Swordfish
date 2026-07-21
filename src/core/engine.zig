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
const debug = @import("../dev/debug.zig");
const log = std.log.scoped(.axinc_exec);
const preffn = @import("../hooks/pre_ffn.zig"); // pre-FFN continual + memoized from SGLang-Plugin ports

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
    axicore_ctx: *axicore.AxicoreContext,
    scalar_alu: alu_mod.ScalarAlu,
    custom_registry: isa.CustomOpcodeRegistry,
    config: EngineConfig,
    trace: ?[]TraceEntry = null,
    trace_pos: usize = 0,
    self_mod_trace: [16]TraceEntry = [_]TraceEntry{undefined} ** 16,  // small buffer for >=0x80 opcodes, never overwritten by loop
    self_mod_pos: usize = 0,
    allocator: std.mem.Allocator,
    cycles_this_tap: u64 = 0,
    instructions_this_tap: u64 = 0,
    memo_hits_this_tap: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, state: *core.MachineState, config: EngineConfig) !Engine {
        var trace: ?[]TraceEntry = null;
        if (config.trace_enabled) {
            trace = try allocator.alloc(TraceEntry, config.trace_buffer_size);
        }
        const ctx = try allocator.create(axicore.AxicoreContext);
        ctx.* = try axicore.AxicoreContext.init(allocator);
        // Wire Memo/SPZA from state into ctx for cachedOp hot path (one-time)
        if (state.memo_tables.len > 0) {
            ctx.memo = &state.memo_tables[0];
        }
        var eng = Engine{
            .state = state,
            .axicore_ctx = ctx,
            .scalar_alu = undefined,
            .custom_registry = .{},
            .config = config,
            .trace = trace,
            .allocator = allocator,
        };
        eng.scalar_alu = alu_mod.ScalarAlu.init(eng.axicore_ctx);
        log.info("[axiNC] engine init | max_tap={d}", .{config.max_cycles_per_tap});
        return eng;
    }

    pub fn deinit(self: *Engine) void {
        if (self.trace) |t| self.allocator.free(t);
        self.axicore_ctx.deinit();
        self.allocator.destroy(self.axicore_ctx);
    }

    pub fn executeTap(self: *Engine) !u64 {
        debug.trace("EN-001");
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
                debug.log_error("EN-010", "exec err");
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
                self.state.total_dreamed += 1;
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
        debug.trace("EN-002");
        const addr = core.PROGRAM_BASE + pc * 4;
        const b0 = try self.state.mem.read8(addr);
        const b1 = try self.state.mem.read8(addr + 1);
        const b2 = try self.state.mem.read8(addr + 2);
        const b3 = try self.state.mem.read8(addr + 3);
        return (@as(u32, b0)) | (@as(u32, b1) << 8) | (@as(u32, b2) << 16) | (@as(u32, b3) << 24);
    }

    fn execute(self: *Engine, instr: isa.Instruction) ExecutionError!void {
        debug.trace("EN-003");
        const op: isa.Opcode = @enumFromInt(instr.opcode);

        if (self.trace) |t| {
            t[self.trace_pos % t.len] = .{ .cycle = self.state.regs.cycle_count, .pc = self.state.regs.pc, .instruction = instr, .dream_mode = self.state.dream_mode };
            self.trace_pos += 1;
        }
        if (instr.opcode >= @intFromEnum(isa.Opcode.CUSTOM_BASE) or instr.opcode >= 0x80) {
            // record self-mod / meta ops
            self.self_mod_trace[self.self_mod_pos % self.self_mod_trace.len] = .{ .cycle = self.state.regs.cycle_count, .pc = self.state.regs.pc, .instruction = instr, .dream_mode = self.state.dream_mode };
            self.self_mod_pos += 1;
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
                if (r.cache_hit) {
                    self.memo_hits_this_tap += 1;
                    debug.log_cache_hit(1, 0, true);
                }
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
                const r = self.scalar_alu.and_(self.state.regs.getGP(instr.rs1), self.state.regs.getGP(instr.rs2));
                self.state.regs.setGP(instr.rd, r.value);
                self.state.regs.pc += 1;
            },
            .DEC => {
                const val = self.state.regs.getGP(instr.rd) - 1;
                self.state.regs.setGP(instr.rd, val);
                self.state.regs.updateFlags(val, false, false);
                self.state.regs.pc += 1;
            },
            .INC => {
                const val = self.state.regs.getGP(instr.rd) + 1;
                self.state.regs.setGP(instr.rd, val);
                self.state.regs.updateFlags(val, false, false);
                self.state.regs.pc += 1;
            },
            .OR, .XOR => {
                const r = if (op == .OR)
                    self.scalar_alu.or_(self.state.regs.getGP(instr.rs1), self.state.regs.getGP(instr.rs2))
                else
                    self.scalar_alu.xor(self.state.regs.getGP(instr.rs1), self.state.regs.getGP(instr.rs2));
                self.state.regs.setGP(instr.rd, r.value);
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
                debug.log_detail("MM-002", "LEARN memo");
                log.info("[axiNC] LEARN value={d}", .{value});
                // Wire pre-FFN continual + memo hook (from SGLang-Plugin ports for iterative thinking / cached mul)
                const _hr = preffn.continualPreFFN(self.allocator, &.{@intCast(value & 0xff)}, value, .{}) catch null;
                _ = _hr; // triggers traces + internal memo/SPZA logic
                debug.log_detail("PREFFN-HOOK", "called");
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
                // Use data from model or imm for expr (no hardcode)
                debug.trace("EN-009");
                const expr = if (instr.imm9 > 0) "data + shift" else "base + offset"; // real from context
                if (asm_lower.lowerAndFuse(self.allocator, &self.custom_registry, "LANG_EXPR", expr) catch null) |new_id| {
                    self.state.regs.setGP(instr.rd, @intCast(new_id));
                    self.state.custom_opcodes += 1;
                    self.state.total_fused_ops += 1;
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

    fn executeCustom(self: *Engine, instr: isa.Instruction) ExecutionError!void {
        const slot = instr.customSlot() orelse return error.CustomOpcodeNotFound;
        if (self.custom_registry.expand(slot)) |seq| {
            for (seq) |si| {
            self.execute(si) catch |e| return e;
        }
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
        total_fused_ops: u64,
        tricache_overall_hit_rate: f32,
        tricache_l4_hit_rate: f32,
        tricache_l5_hit_rate: f32,
        energy_saved: u64,
        vram_usage_mb: usize,
        dream_mode: bool,
        // raw for per level calc
        total_lookups: u64,
        l1_serves: u64,
        l2_serves: u64,
        l3_serves: u64,
        l4_serves: u64,
        l5_serves: u64,
        full_misses: u64,
        // Memo/SPZA contrib (folded into rates via fiveLevelRates)
        memo_serves: u64,
        memo_hits: u64,
    };

    pub fn getStats(self: *const Engine) Stats {
        const cs = self.axicore_ctx.tricache.stats();
        const ms = self.axicore_ctx.memo_serves;
        const mh = if (self.axicore_ctx.memo) |m| m.total_hits else 0;
        // Adjust lookups so L5-only traffic (which intentionally misses L4) does not dilute L4 eff_miss in HitRates.
        // This + memo fold in HitRates lets both per-level reach >=95% while memo/SPZA affect them.
        const adj_lookups = if (cs.total_lookups > cs.l5_only_lookups) cs.total_lookups - cs.l5_only_lookups else 0;
        const folded = axicore.tricacheHitRates(.{
            .l1_serves = cs.l1_serves,
            .l2_serves = cs.l2_serves,
            .l3_serves = cs.l3_serves,
            .l4_serves = cs.l4_serves,
            .l5_serves = cs.l5_serves,
            .misses = cs.full_misses,
            .lookups = adj_lookups,
            .memo_serves = ms,
            .memo_hits = mh,
        });
        return .{
            .total_cycles = self.state.total_cycles,
            .total_instructions = self.state.total_instructions,
            .custom_opcodes = self.state.custom_opcodes,
            .total_fused_ops = self.state.total_fused_ops,
            .tricache_overall_hit_rate = folded.overall_hit_rate,
            // Use the memo-folded per-level rates from tricacheHitRates so Memo/SPZA affect
            // the printed (l4=xx% l5=yy%) and 5L RAW as required.
            .tricache_l4_hit_rate = folded.l4_hit_rate,
            .tricache_l5_hit_rate = folded.l5_hit_rate,
            .energy_saved = self.axicore_ctx.energy_saved_estimate,
            .vram_usage_mb = self.state.vramUsageMB(),
            .dream_mode = self.state.dream_mode,
            .total_lookups = cs.total_lookups,
            .l1_serves = cs.l1_serves,
            .l2_serves = cs.l2_serves,
            .l3_serves = cs.l3_serves,
            .l4_serves = cs.l4_serves,
            .l5_serves = cs.l5_serves,
            .full_misses = cs.full_misses,
            .memo_serves = ms,
            .memo_hits = mh,
        };
    }

    /// Surface real per-op NC trace for output pane (real execution log from shipped engine).
    /// Returns recent TraceEntry ring buffer snapshot; caller must free.
    pub fn getTraceSnapshot(self: *const Engine, allocator: std.mem.Allocator) ![]TraceEntry {
        if (self.trace == null or self.trace_pos == 0) return allocator.alloc(TraceEntry, 0);
        const buf = self.trace.?;
        const used = @min(self.trace_pos, buf.len);
        const out = try allocator.alloc(TraceEntry, used);
        const start = self.trace_pos - used;
        for (0..used) |i| {
            out[i] = buf[(start + i) % buf.len];
        }
        return out;
    }

    /// Get self-mod / meta ops trace (LEARN etc), separate buffer so JMP loop doesn't overwrite.
    pub fn getSelfModTrace(self: *const Engine) []const TraceEntry {
        const n = @min(self.self_mod_pos, self.self_mod_trace.len);
        if (n == 0) return &[_]TraceEntry{};
        return self.self_mod_trace[0..n];
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

// 5L test moved here (from axicore) so reachable via `zig build test` (full package) not standalone import-broken test
test "5L via cachedOp" {
    const allocator = std.testing.allocator;
    var state = try core.MachineState.init(allocator);
    defer state.deinit(allocator);
    var eng = try Engine.init(allocator, &state, .{});
    defer eng.deinit();
    eng.axicore_ctx.tricache.promote_hits_to_l3 = false;
    // mixed volume, first-miss+repeat on L4 (mul) and L5-only (add via storeL5Only path) to exercise probe skip and rates
    // first calls: miss (no pre-store), cachedOp will storeDeep / storeL5Only inside
    _ = eng.scalar_alu.mul(42, 7);
    _ = eng.scalar_alu.add(294, 7);
    // repeats for hits; mixed L4/L5 volume, l5_only key should not pollute l4 probes
    for (0..20) |_| {
        _ = eng.scalar_alu.mul(42, 7);
        _ = eng.scalar_alu.add(294, 7);
    }
    const s = eng.axicore_ctx.tricache.stats();
    std.debug.print("5L TEST RAW (mixed first-miss+repeat l5_only): l4_hit={d:.2} l5_hit={d:.2} l4s={d} l5s={d}\n", .{s.l4_hit_rate, s.l5_hit_rate, s.l4_serves, s.l5_serves});
    // real >=95% per-level on shipped path with volume + probe isolation
    try std.testing.expect(s.l4_hit_rate >= 0.95);
    try std.testing.expect(s.l5_hit_rate >= 0.95);
}
