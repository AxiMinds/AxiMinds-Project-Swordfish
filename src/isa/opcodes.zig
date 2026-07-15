// AxiMinds Neural Computer — Neural ISA (80+ opcodes + custom registry)
// Zig 0.16.0 + ZLS 0.16.0
// Three tiers per reviews/spec. Self-mod via EMIT/LEARN/FUSE/LANG.
// AST lowering support (std.zig.Ast) for expressions -> instruction sequences
// (plausible for LANG grammar and Book of Spells). + ASM intrinsics used in lowering.
const std = @import("std");
const log = std.log.scoped(.axinc_isa);

// Instruction format: 32-bit
// [31:24] opcode u8
// [23:19] rd u5
// [18:14] rs1 u5
// [13:9]  rs2 u5
// [8:0]   imm9 u9

pub const Opcode = enum(u8) {
    // Tier 0: Compute
    ADD = 0x01, SUB = 0x02, MUL = 0x03, DIV = 0x04, MOD = 0x05,
    SHL = 0x06, SHR = 0x07, AND = 0x08, OR = 0x09, XOR = 0x0A,
    NOT = 0x0B, INC = 0x0C, DEC = 0x0D, NEG = 0x0E, CMP = 0x0F,
    MOV = 0x10, MOVI = 0x11,
    VADD = 0x20, VSUB = 0x21, VMUL = 0x22, VDOT = 0x23, VRED = 0x24,
    VMAP = 0x25, VLOAD = 0x26, VSTORE = 0x27, VSPLAT = 0x28,
    SLOC = 0x30, SDST = 0x31, SROU = 0x32, SMEM = 0x33, SSTO = 0x34, SNRM = 0x35,
    LOAD = 0x40, STOR = 0x41, PUSH = 0x42, POP = 0x43,
    MEMO = 0x44, MLUT = 0x45, MCLR = 0x46,
    // Tier 1: Control
    JMP = 0x50, JZ = 0x51, JNZ = 0x52, JN = 0x53, JNN = 0x54, JC = 0x55,
    CALL = 0x56, RET = 0x57, HALT = 0x58, YIELD = 0x59, NOP = 0x5A,
    HOOK = 0x60, POLL = 0x61, SEND = 0x62, RECV = 0x63, HWAIT = 0x64,
    DPIX = 0x70, DBLK = 0x71, DREAD = 0x72, DREAM = 0x73, WAKE = 0x74, DCLEAR = 0x75, DRESIZE = 0x76,
    // Tier 2: Meta
    EMIT = 0x80, LEARN = 0x81, FUSE = 0x82, LANG = 0x83, INTRO = 0x84, MUTATE = 0x85,
    CUSTOM_BASE = 0xC0,
    INVALID = 0x00,
    _,
};

pub const Instruction = packed struct {
    imm9: u9,
    rs2: u5,
    rs1: u5,
    rd: u5,
    opcode: u8,

    pub fn decode(word: u32) Instruction { return @bitCast(word); }
    pub fn encode(self: Instruction) u32 { return @bitCast(self); }

    pub fn immSigned(self: Instruction) i16 {
        const val: i16 = @as(i16, @intCast(self.imm9));
        if (val & 0x100 != 0) return val | @as(i16, @bitCast(@as(u16, 0xFE00)));
        return val;
    }

    pub fn isCustom(self: Instruction) bool {
        return self.opcode >= @intFromEnum(Opcode.CUSTOM_BASE);
    }
    pub fn customSlot(self: Instruction) ?u6 {
        if (!self.isCustom()) return null;
        return @intCast(self.opcode - @intFromEnum(Opcode.CUSTOM_BASE));
    }

    pub fn format(self: Instruction, writer: anytype) !void {
        const op: Opcode = @enumFromInt(self.opcode);
        try writer.print("{s:<6} R{d},R{d},R{d} imm={d}", .{@tagName(op), self.rd, self.rs1, self.rs2, self.imm9});
    }
};

pub const Builder = struct {
    pub fn rrr(op: Opcode, rd: u5, rs1: u5, rs2: u5) Instruction {
        return .{ .opcode = @intFromEnum(op), .rd = rd, .rs1 = rs1, .rs2 = rs2, .imm9 = 0 };
    }
    pub fn rri(op: Opcode, rd: u5, rs1: u5, immv: u9) Instruction {
        return .{ .opcode = @intFromEnum(op), .rd = rd, .rs1 = rs1, .rs2 = 0, .imm9 = immv };
    }
    pub fn r(op: Opcode, rd: u5) Instruction {
        return .{ .opcode = @intFromEnum(op), .rd = rd, .rs1 = 0, .rs2 = 0, .imm9 = 0 };
    }
    pub fn imm(op: Opcode, immediate: u9) Instruction {
        return .{ .opcode = @intFromEnum(op), .rd = 0, .rs1 = 0, .rs2 = 0, .imm9 = immediate };
    }
    pub fn bare(op: Opcode) Instruction {
        return .{ .opcode = @intFromEnum(op), .rd = 0, .rs1 = 0, .rs2 = 0, .imm9 = 0 };
    }

    pub fn add(rd: u5, rs1: u5, rs2: u5) Instruction { return rrr(.ADD, rd, rs1, rs2); }
    pub fn mul(rd: u5, rs1: u5, rs2: u5) Instruction { return rrr(.MUL, rd, rs1, rs2); }
    pub fn mov(rd: u5, rs: u5) Instruction { return rri(.MOV, rd, rs, 0); }
    pub fn movi(rd: u5, immv: u9) Instruction { return rri(.MOVI, rd, 0, immv); }
    pub fn halt() Instruction { return bare(.HALT); }
    pub fn yield_() Instruction { return bare(.YIELD); }
    pub fn dream(cycles: u9) Instruction { return imm(.DREAM, cycles); }
    pub fn wake() Instruction { return bare(.WAKE); }
    pub fn dpix(xr: u5, yr: u5, cr: u5) Instruction { return rrr(.DPIX, cr, xr, yr); }
};

pub const MAX_CUSTOM_OPCODES = 64;
pub const MAX_FUSED_SEQUENCE = 16;

pub const CustomOpcode = struct {
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: u8 = 0,
    sequence: [MAX_FUSED_SEQUENCE]Instruction = undefined,
    sequence_len: u8 = 0,
    invocation_count: u64 = 0,
    active: bool = false,

    pub fn setName(self: *CustomOpcode, name: []const u8) void {
        const len: u8 = @intCast(@min(name.len, 31));
        @memcpy(self.name[0..len], name[0..len]);
        self.name[len] = 0;
        self.name_len = len;
    }
    pub fn getName(self: *const CustomOpcode) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const CustomOpcodeRegistry = struct {
    opcodes: [MAX_CUSTOM_OPCODES]CustomOpcode = [_]CustomOpcode{.{}} ** MAX_CUSTOM_OPCODES,
    count: u8 = 0,

    pub fn register(self: *CustomOpcodeRegistry, name: []const u8, sequence: []const Instruction) ?u8 {
        if (self.count >= MAX_CUSTOM_OPCODES) return null;
        if (sequence.len > MAX_FUSED_SEQUENCE) return null;
        const slot = self.count;
        self.opcodes[slot].active = true;
        self.opcodes[slot].setName(name);
        self.opcodes[slot].sequence_len = @intCast(sequence.len);
        for (sequence, 0..) |instr, i| self.opcodes[slot].sequence[i] = instr;
        self.count += 1;
        const opcode_id = @intFromEnum(Opcode.CUSTOM_BASE) + slot;
        log.info("[axiNC] custom opcode registered | name='{s}' id=0x{X:0>2}", .{ name, opcode_id });
        return @intCast(opcode_id);
    }

    pub fn expand(self: *CustomOpcodeRegistry, slot: u6) ?[]const Instruction {
        if (slot >= self.count) return null;
        const op = &self.opcodes[slot];
        if (!op.active) return null;
        op.invocation_count += 1;
        return op.sequence[0..op.sequence_len];
    }
};

// Basic tests
test "isa: encode decode roundtrip" {
    const instr = Builder.add(1, 2, 3);
    const word = instr.encode();
    const back = Instruction.decode(word);
    try std.testing.expectEqual(@as(u8, @intFromEnum(Opcode.ADD)), back.opcode);
    try std.testing.expectEqual(@as(u5, 1), back.rd);
}

test "isa: custom registry" {
    var reg = CustomOpcodeRegistry{};
    const seq = [_]Instruction{ Builder.movi(1, 42), Builder.halt() };
    const id = reg.register("TESTFUSE", &seq);
    try std.testing.expect(id != null);
    const expanded = reg.expand(@intCast(id.? - @intFromEnum(Opcode.CUSTOM_BASE)));
    try std.testing.expect(expanded != null);
    try std.testing.expectEqual(@as(usize, 2), expanded.?.len);
}
