// AxiMinds Neural Computer — Core Types
// Zig 0.16.0 + ZLS 0.16.0
// Registers, memory, SPZA, dream canvas, machine state
// Extracted/refined from Conv-20260628-1155pm.md reviews and code.
const std = @import("std");
const log = std.log.scoped(.axinc_types);

// ─────────────────────────────────────────────────────────────────────
// SPZA — 8D Spherical Coordinates (θ/φ/ψ/τ + 4 more dims) @ 2^60 scale
// ─────────────────────────────────────────────────────────────────────
pub const SPZA_SCALE: i128 = 1 << 60; // 2^60 fixed-point

pub const SpzaCoord = struct {
    dims: [8]i64 = [_]i64{0} ** 8,

    pub fn fromRegisters(r0: i64, r1: i64, r2: i64, r3: i64, r4: i64, r5: i64, r6: i64, r7: i64) SpzaCoord {
        return .{ .dims = .{ r0, r1, r2, r3, r4, r5, r6, r7 } };
    }

    /// Approximate cosine of angle between two 8D vectors (normalized)
    pub fn angularDistance(self: *const SpzaCoord, other: *const SpzaCoord) u128 {
        var dot: i256 = 0;
        var mag_a: u256 = 0;
        var mag_b: u256 = 0;
        for (0..8) |i| {
            const a: i256 = @intCast(self.dims[i]);
            const b: i256 = @intCast(other.dims[i]);
            dot += a * b;
            const aa = if (a < 0) -a else a;
            const bb = if (b < 0) -b else b;
            mag_a += @as(u256, @intCast(aa)) * @as(u256, @intCast(aa));
            mag_b += @as(u256, @intCast(bb)) * @as(u256, @intCast(bb));
        }
        const scale: u128 = 1 << 60;
        if (mag_a == 0 or mag_b == 0) return scale; // max distance
        const abs_dot: u256 = if (dot < 0) @intCast(-dot) else @intCast(dot);
        return @truncate((abs_dot * scale) / (mag_a + mag_b));
    }

    pub fn isWithinThreshold(self: *const SpzaCoord, other: *const SpzaCoord, threshold_scaled: u128) bool {
        return self.angularDistance(other) > threshold_scaled;
    }
};

// ─────────────────────────────────────────────────────────────────────
// axiNC Register File
// ─────────────────────────────────────────────────────────────────────
pub const GP_REG_COUNT = 32;
pub const VEC_WIDTH = 256;
pub const SPZA_REG_COUNT = 8;
pub const MEMO_PTR_COUNT = 4;

pub const Flags = packed struct {
    negative: bool = false,
    zero: bool = false,
    carry: bool = false,
    overflow: bool = false,
    dreaming: bool = false,
    hook_pending: bool = false,
    halted: bool = false,
    self_modify: bool = false,
    _pad: u8 = 0,
};

pub const RegisterFile = struct {
    gp: [GP_REG_COUNT]i64 = [_]i64{0} ** GP_REG_COUNT,
    vec: [GP_REG_COUNT][VEC_WIDTH]i32 = [_][VEC_WIDTH]i32{[_]i32{0} ** VEC_WIDTH} ** GP_REG_COUNT,
    spza: [SPZA_REG_COUNT]SpzaCoord = [_]SpzaCoord{.{}} ** SPZA_REG_COUNT,
    memo: [MEMO_PTR_COUNT]u64 = [_]u64{0} ** MEMO_PTR_COUNT,
    flags: Flags = .{},
    pc: u64 = 0,
    sp: u64 = 0,
    hp: u64 = 0,
    dp: u64 = 0,
    cycle_count: u64 = 0,

    pub fn reset(self: *RegisterFile) void {
        self.* = .{};
        log.info("[axiNC] register file reset | cycle=0", .{});
    }

    pub fn getGP(self: *const RegisterFile, idx: u5) i64 {
        return self.gp[@intCast(idx)];
    }

    pub fn setGP(self: *RegisterFile, idx: u5, val: i64) void {
        if (idx == 31) return; // zero register
        self.gp[@intCast(idx)] = val;
    }

    pub fn updateFlags(self: *RegisterFile, result: i64, carry: bool, overflow: bool) void {
        self.flags.negative = result < 0;
        self.flags.zero = result == 0;
        self.flags.carry = carry;
        self.flags.overflow = overflow;
    }
};

// ─────────────────────────────────────────────────────────────────────
// axiNC Main Memory
// ─────────────────────────────────────────────────────────────────────
pub const DEFAULT_MEM_SIZE: usize = 256 * 1024 * 1024;
pub const STACK_BASE: u64 = 0x0FFF_0000;
pub const PROGRAM_BASE: u64 = 0x0000_1000;
pub const HOOK_BUFFER_BASE: u64 = 0x0E00_0000;
pub const MEMO_TABLE_BASE: u64 = 0x0C00_0000;
pub const CANVAS_MAP_BASE: u64 = 0x0800_0000;

pub const Memory = struct {
    data: []u8,
    size: usize,
    allocator: std.mem.Allocator,
    program_end: u64 = PROGRAM_BASE,
    heap_ptr: u64 = 0x0100_0000,

    pub fn init(allocator: std.mem.Allocator, size: usize) !Memory {
        const data = try allocator.alloc(u8, size);
        @memset(data, 0);
        log.info("[axiNC] memory initialized | size={d}MB", .{size / (1024 * 1024)});
        return Memory{ .data = data, .size = size, .allocator = allocator };
    }

    pub fn deinit(self: *Memory) void {
        self.allocator.free(self.data);
    }

    pub fn read64(self: *const Memory, addr: u64) !i64 {
        const a: usize = @intCast(addr);
        if (a + 8 > self.size) return error.MemoryAccessViolation;
        return @bitCast(std.mem.readInt(u64, self.data[a..][0..8], .little));
    }

    pub fn write64(self: *Memory, addr: u64, val: i64) !void {
        const a: usize = @intCast(addr);
        if (a + 8 > self.size) return error.MemoryAccessViolation;
        std.mem.writeInt(u64, self.data[a..][0..8], @bitCast(val), .little);
    }

    pub fn read8(self: *const Memory, addr: u64) !u8 {
        const a: usize = @intCast(addr);
        if (a >= self.size) return error.MemoryAccessViolation;
        return self.data[a];
    }

    pub fn write8(self: *Memory, addr: u64, val: u8) !void {
        const a: usize = @intCast(addr);
        if (a >= self.size) return error.MemoryAccessViolation;
        self.data[a] = val;
    }

    pub fn loadProgram(self: *Memory, program: []const u8) !void {
        const base: usize = @intCast(PROGRAM_BASE);
        if (base + program.len > self.size) return error.ProgramTooLarge;
        @memcpy(self.data[base .. base + program.len], program);
        self.program_end = PROGRAM_BASE + @as(u64, @intCast(program.len));
        log.info("[axiNC] program loaded | addr=0x{X:0>8} size={d}B", .{ PROGRAM_BASE, program.len });
    }
};

// ─────────────────────────────────────────────────────────────────────
// MemoTable (SPZA-indexed)
// ─────────────────────────────────────────────────────────────────────
pub const MEMO_ENTRY_COUNT: usize = 65536;
pub const MemoEntry = struct {
    key: SpzaCoord = .{},
    value: i64 = 0,
    hit_count: u32 = 0,
    valid: bool = false,
    fused_op: ?u16 = null,

    pub fn hit(self: *MemoEntry) i64 {
        self.hit_count +|= 1;
        return self.value;
    }
};

pub const MemoTable = struct {
    entries: []MemoEntry,
    entry_count: usize,
    total_hits: u64 = 0,
    total_misses: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, count: usize) !MemoTable {
        const entries = try allocator.alloc(MemoEntry, count);
        @memset(entries, MemoEntry{});
        log.info("[axiNC] memo table initialized | entries={d}", .{count});
        return MemoTable{ .entries = entries, .entry_count = count, .allocator = allocator };
    }

    pub fn deinit(self: *MemoTable) void {
        self.allocator.free(self.entries);
    }

    pub fn lookup(self: *MemoTable, key: *const SpzaCoord) ?i64 {
        const idx = spzaHash(key) % self.entry_count;
        const entry = &self.entries[idx];
        if (entry.valid) {
            const threshold: u128 = (1 << 60) * 95 / 100;
            if (key.angularDistance(&entry.key) > threshold) {
                self.total_hits += 1;
                return entry.hit();
            }
        }
        self.total_misses += 1;
        return null;
    }

    pub fn store(self: *MemoTable, key: *const SpzaCoord, value: i64) void {
        const idx = spzaHash(key) % self.entry_count;
        const entry = &self.entries[idx];
        if (!entry.valid or entry.hit_count < 2) {
            entry.* = MemoEntry{ .key = key.*, .value = value, .hit_count = 1, .valid = true };
        }
    }

    pub fn storeFused(self: *MemoTable, key: *const SpzaCoord, value: i64, opcode: u16) void {
        const idx = spzaHash(key) % self.entry_count;
        self.entries[idx] = MemoEntry{ .key = key.*, .value = value, .hit_count = 1, .valid = true, .fused_op = opcode };
    }

    fn spzaHash(coord: *const SpzaCoord) usize {
        var h: u64 = 0xcbf29ce484222325;
        inline for (0..8) |i| {
            const bytes: [16]u8 = @bitCast(coord.dims[i]);
            for (bytes) |b| {
                h ^= b;
                h *%= 0x100000001b3;
            }
        }
        return @intCast(h);
    }
};

// ─────────────────────────────────────────────────────────────────────
// Dream Canvas
// ─────────────────────────────────────────────────────────────────────
pub const CanvasPixel = packed struct { r: u8, g: u8, b: u8, a: u8 };

pub const DreamCanvas = struct {
    width: u32,
    height: u32,
    pixels: []CanvasPixel,
    allocator: std.mem.Allocator,
    layer_count: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !DreamCanvas {
        const pixel_count: usize = @as(usize, width) * @as(usize, height);
        const pixels = try allocator.alloc(CanvasPixel, pixel_count);
        @memset(pixels, CanvasPixel{ .r = 0, .g = 0, .b = 0, .a = 255 });
        const size_mb = (pixel_count * @sizeOf(CanvasPixel)) / (1024 * 1024);
        log.info("[axiNC] dream canvas initialized | {d}x{d} ({d}MB)", .{ width, height, size_mb });
        return DreamCanvas{ .width = width, .height = height, .pixels = pixels, .allocator = allocator };
    }

    pub fn deinit(self: *DreamCanvas) void {
        self.allocator.free(self.pixels);
    }

    pub fn setPixel(self: *DreamCanvas, x: u32, y: u32, pixel: CanvasPixel) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)] = pixel;
    }

    pub fn getPixel(self: *const DreamCanvas, x: u32, y: u32) CanvasPixel {
        if (x >= self.width or y >= self.height) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        return self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    pub fn writeBlock(self: *DreamCanvas, x: u32, y: u32, w: u32, h: u32, data: []const i32) void {
        var idx: usize = 0;
        var dy: u32 = 0;
        while (dy < h) : (dy += 1) {
            var dx: u32 = 0;
            while (dx < w) : (dx += 1) {
                if (idx >= data.len) return;
                const val: u32 = @bitCast(data[idx]);
                self.setPixel(x + dx, y + dy, @bitCast(val));
                idx += 1;
            }
        }
    }

    pub fn vramBytes(self: *const DreamCanvas) usize {
        return self.pixels.len * @sizeOf(CanvasPixel) * self.layer_count;
    }
};

// ─────────────────────────────────────────────────────────────────────
// MachineState
// ─────────────────────────────────────────────────────────────────────
pub const MachineState = struct {
    regs: RegisterFile = .{},
    mem: Memory,
    memo_tables: [MEMO_PTR_COUNT]MemoTable,
    canvas: DreamCanvas,
    running: bool = false,
    dream_mode: bool = false,
    dream_cycles_remaining: u64 = 0,
    hooks_active: u32 = 0,
    hook_queue_depth: u32 = 0,
    custom_opcodes: u16 = 0,
    total_fused_ops: u64 = 0,
    total_cycles: u64 = 0,
    total_instructions: u64 = 0,
    memo_hit_rate: f32 = 0.0,

    pub fn init(allocator: std.mem.Allocator) !MachineState {
        const mem = try Memory.init(allocator, DEFAULT_MEM_SIZE);
        var memo_tables: [MEMO_PTR_COUNT]MemoTable = undefined;
        for (&memo_tables) |*mt| {
            mt.* = try MemoTable.init(allocator, MEMO_ENTRY_COUNT);
        }
        const canvas = try DreamCanvas.init(allocator, 4096, 4096);
        log.info("[axiNC] machine state initialized | mem={d}MB canvas={d}MB", .{
            DEFAULT_MEM_SIZE / (1024 * 1024),
            canvas.vramBytes() / (1024 * 1024),
        });
        return MachineState{
            .mem = mem,
            .memo_tables = memo_tables,
            .canvas = canvas,
        };
    }

    pub fn deinit(self: *MachineState, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.mem.deinit();
        for (&self.memo_tables) |*mt| mt.deinit();
        self.canvas.deinit();
    }

    pub fn enterDream(self: *MachineState, cycles: u64) void {
        self.dream_mode = true;
        self.dream_cycles_remaining = cycles;
        self.regs.flags.dreaming = true;
        log.info("[axiNC] entering dream mode | cycles={d}", .{cycles});
    }

    pub fn wake(self: *MachineState) void {
        self.dream_mode = false;
        self.dream_cycles_remaining = 0;
        self.regs.flags.dreaming = false;
        log.info("[axiNC] waking from dream | total_dreamed={d} cycles", .{self.total_cycles});
    }

    pub fn vramUsageBytes(self: *const MachineState) usize {
        var total: usize = @sizeOf(RegisterFile);
        total += self.mem.size;
        for (&self.memo_tables) |*mt| {
            total += mt.entry_count * @sizeOf(MemoEntry);
        }
        total += self.canvas.vramBytes();
        return total;
    }

    pub fn vramUsageMB(self: *const MachineState) usize {
        return self.vramUsageBytes() / (1024 * 1024);
    }
};

// Tests (from conv)
test "register file: zero register hardwired" {
    var rf = RegisterFile{};
    rf.setGP(31, 42);
    try std.testing.expectEqual(@as(i64, 0), rf.getGP(31));
}

test "register file: flag update" {
    var rf = RegisterFile{};
    rf.updateFlags(-1, false, false);
    try std.testing.expect(rf.flags.negative);
    try std.testing.expect(!rf.flags.zero);
    rf.updateFlags(0, false, false);
    try std.testing.expect(rf.flags.zero);
    try std.testing.expect(!rf.flags.negative);
}

test "memory: read/write 64-bit" {
    var mem = try Memory.init(std.testing.allocator, 4096);
    defer mem.deinit();
    try mem.write64(0, 0x0123456789ABCDEF);
    const val = try mem.read64(0);
    try std.testing.expectEqual(@as(i64, 0x0123456789ABCDEF), val);
}
