// AxiMinds axicore — Compute Savings Layer (FULL)
// Zig 0.16.0 + ZLS 0.16.0
// Tricache, INT1, ShiftAdd (now with ASM intrinsics), MEP, SMURFS, HwDispatch, zNorm etc.
// Refined from review feedback in Conv-20260628-1155pm.md.
// Uses inline asm + @bit intrinsics for critical no-MUL paths where plausible.
const std = @import("std");
const core = @import("types.zig");
const log = std.log.scoped(.axinc_axicore);

// ═══════════════════════════════════════════════════════════════════
// 1. TRICACHE — Three-Tiered Cache Hierarchy
// ═══════════════════════════════════════════════════════════════════
pub const CacheEntry = struct {
    key_hash: u64 = 0,
    value: i64 = 0,
    tag: u32 = 0,
    age: u16 = 0,
    valid: bool = false,
    dirty: bool = false,
    pub fn invalidate(self: *CacheEntry) void {
        self.valid = false;
        self.dirty = false;
    }
};

pub const TricacheL1 = struct {
    pub const SIZE: usize = 256;
    entries: [SIZE]CacheEntry = [_]CacheEntry{.{}} ** SIZE,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    pub fn lookup(self: *TricacheL1, key_hash: u64) ?i64 {
        const idx = key_hash & (SIZE - 1);
        const entry = &self.entries[idx];
        if (entry.valid and entry.key_hash == key_hash) {
            self.hits += 1;
            return entry.value;
        }
        self.misses += 1;
        return null;
    }
    pub fn store(self: *TricacheL1, key_hash: u64, value: i64, tag: u32) void {
        const idx = key_hash & (SIZE - 1);
        const entry = &self.entries[idx];
        if (entry.valid and entry.key_hash != key_hash) {
            self.evictions += 1;
        }
        entry.* = .{ .key_hash = key_hash, .value = value, .tag = tag, .valid = true };
    }
    pub fn hitRate(self: *const TricacheL1) f32 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.hits)) / @as(f32, @floatFromInt(total));
    }
};

pub const TricacheL2 = struct {
    pub const SETS: usize = 1024;
    pub const WAYS: usize = 4;
    pub const SIZE: usize = SETS * WAYS;
    entries: [SETS][WAYS]CacheEntry = [_][WAYS]CacheEntry{[_]CacheEntry{.{}} ** WAYS} ** SETS,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    pub fn lookup(self: *TricacheL2, key_hash: u64) ?i64 {
        const set_idx = key_hash & (SETS - 1);
        const set = &self.entries[set_idx];
        for (set) |*entry| {
            if (entry.valid and entry.key_hash == key_hash) {
                self.hits += 1;
                entry.age = 0;
                return entry.value;
            }
        }
        self.misses += 1;
        return null;
    }
    pub fn store(self: *TricacheL2, key_hash: u64, value: i64, tag: u32) void {
        const set_idx = key_hash & (SETS - 1);
        const set = &self.entries[set_idx];
        var victim_idx: usize = 0;
        var max_age: u16 = 0;
        for (set, 0..) |*entry, i| {
            if (!entry.valid) {
                victim_idx = i;
                break;
            }
            if (entry.age >= max_age) {
                max_age = entry.age;
                victim_idx = i;
            }
        }
        if (set[victim_idx].valid) self.evictions += 1;
        set[victim_idx] = .{ .key_hash = key_hash, .value = value, .tag = tag, .valid = true };
        for (set, 0..) |*entry, i| {
            if (i != victim_idx and entry.valid) {
                entry.age +|= 1;
            }
        }
    }
    pub fn hitRate(self: *const TricacheL2) f32 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.hits)) / @as(f32, @floatFromInt(total));
    }
};

pub const TricacheL3 = struct {
    pub const DEFAULT_SIZE: usize = 65536;
    entries: []CacheEntry,
    capacity: usize,
    count: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    global_age: u16 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !TricacheL3 {
        const entries = try allocator.alloc(CacheEntry, capacity);
        @memset(entries, CacheEntry{});
        log.info("[axicore] TricacheL3 initialized | capacity={d} ({d}KB)", .{
            capacity, (capacity * @sizeOf(CacheEntry)) / 1024,
        });
        return .{ .entries = entries, .capacity = capacity, .allocator = allocator };
    }

    pub fn deinit(self: *TricacheL3) void {
        self.allocator.free(self.entries);
    }

    // Note: per review, linear scan is O(N). Future: replace with hash + LRU list.
    pub fn lookup(self: *TricacheL3, key_hash: u64) ?i64 {
        for (self.entries[0..self.capacity]) |*entry| {
            if (entry.valid and entry.key_hash == key_hash) {
                self.hits += 1;
                entry.age = 0;
                return entry.value;
            }
        }
        self.misses += 1;
        return null;
    }

    pub fn store(self: *TricacheL3, key_hash: u64, value: i64, tag: u32) void {
        // update if exists
        for (self.entries[0..self.capacity]) |*entry| {
            if (entry.valid and entry.key_hash == key_hash) {
                entry.value = value;
                entry.tag = tag;
                return;
            }
        }
        // find empty or LRU victim
        var victim: usize = 0;
        var max_age: u16 = 0;
        var found_empty = false;
        for (self.entries[0..self.capacity], 0..) |*entry, i| {
            if (!entry.valid) {
                victim = i;
                found_empty = true;
                break;
            }
            if (entry.age >= max_age) {
                max_age = entry.age;
                victim = i;
            }
        }
        if (!found_empty) self.evictions += 1;
        self.entries[victim] = .{ .key_hash = key_hash, .value = value, .tag = tag, .valid = true, .age = 0 };
        if (self.count < self.capacity) self.count += 1;
        // global age bump (per review, hacky; improved clock/pressure suggested)
        self.global_age +|= 1;
        if (self.global_age % 1024 == 0) {
            for (self.entries[0..self.capacity]) |*e| if (e.valid) e.age +|= 1;
        }
    }
};

pub const Tricache = struct {
    l1: TricacheL1 = .{},
    l2: TricacheL2 = .{},
    l3: TricacheL3,
    total_lookups: u64 = 0,
    l1_serves: u64 = 0,
    l2_serves: u64 = 0,
    l3_serves: u64 = 0,
    full_misses: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Tricache {
        const l3 = try TricacheL3.init(allocator, TricacheL3.DEFAULT_SIZE);
        return .{ .l3 = l3, .allocator = allocator };
    }

    pub fn deinit(self: *Tricache) void {
        self.l3.deinit();
    }

    pub fn lookup(self: *Tricache, key_hash: u64) ?i64 {
        self.total_lookups += 1;
        if (self.l1.lookup(key_hash)) |val| {
            self.l1_serves += 1;
            return val;
        }
        if (self.l2.lookup(key_hash)) |val| {
            self.l2_serves += 1;
            self.l1.store(key_hash, val, 0);
            return val;
        }
        if (self.l3.lookup(key_hash)) |val| {
            self.l3_serves += 1;
            self.l1.store(key_hash, val, 0);
            self.l2.store(key_hash, val, 0);
            return val;
        }
        self.full_misses += 1;
        return null;
    }

    pub fn store(self: *Tricache, key_hash: u64, value: i64, tag: u32) void {
        self.l1.store(key_hash, value, tag);
        self.l2.store(key_hash, value, tag);
        self.l3.store(key_hash, value, tag);
    }

    pub fn storeCold(self: *Tricache, key_hash: u64, value: i64, tag: u32) void {
        self.l2.store(key_hash, value, tag);
        self.l3.store(key_hash, value, tag);
    }

    pub fn stats(self: *const Tricache) TricacheStats {
        return .{
            .total_lookups = self.total_lookups,
            .l1_hit_rate = self.l1.hitRate(),
            .l2_hit_rate = self.l2.hitRate(),
            .l3_hit_rate = self.l3.hitRate(),
            .overall_hit_rate = if (self.total_lookups == 0) 0.0 else
                @as(f32, @floatFromInt(self.l1_serves + self.l2_serves + self.l3_serves)) /
                @as(f32, @floatFromInt(self.total_lookups)),
            .l1_evictions = self.l1.evictions,
            .l2_evictions = self.l2.evictions,
            .l3_evictions = self.l3.evictions,
        };
    }

    pub const TricacheStats = struct {
        total_lookups: u64,
        l1_hit_rate: f32,
        l2_hit_rate: f32,
        l3_hit_rate: f32,
        overall_hit_rate: f32,
        l1_evictions: u64,
        l2_evictions: u64,
        l3_evictions: u64,
    };
};

// ═══════════════════════════════════════════════════════════════════
// 2. INT1 CONSENSUS
// ═══════════════════════════════════════════════════════════════════
pub const Int1Consensus = struct {
    pub const Tier = enum(u8) { quick = 3, standard = 7, high = 15, critical = 31 };

    pub const VoterFn = *const fn (a: i64, b: i64, context: u64) bool;

    pub const ConsensusResult = struct {
        result: bool,
        yes_votes: u32,
        no_votes: u32,
        confidence: f32,
        tier: Tier,
        pub fn nines(self: *const ConsensusResult) u8 {
            if (self.confidence >= 0.999) return @intCast(@min(self.yes_votes, 30));
            if (self.confidence >= 0.99) return @intCast(@min(self.yes_votes / 2, 15));
            return 1;
        }
    };

    pub fn vote(voters: []const VoterFn, a: i64, b: i64, context: u64) ConsensusResult {
        var yes: u32 = 0;
        var no: u32 = 0;
        for (voters) |voter| {
            if (voter(a, b, context)) yes += 1 else no += 1;
        }
        const total = yes + no;
        const majority = total / 2 + 1;
        return .{
            .result = yes >= majority,
            .yes_votes = yes,
            .no_votes = no,
            .confidence = @as(f32, @floatFromInt(@max(yes, no))) / @as(f32, @floatFromInt(total)),
            .tier = tierFromCount(@intCast(total)),
        };
    }

    pub fn verifyValue(value: i64, expected: i64, num_voters: u8) ConsensusResult {
        var yes: u32 = 0;
        const n: u32 = @intCast(@min(num_voters, 31));
        for (0..n) |i| {
            const shift: u6 = @intCast(i % 64);
            const mask: i64 = @bitCast(@as(u64, 0xFFFFFFFFFFFFFFFF) >> shift);
            if ((value & mask) == (expected & mask)) yes += 1;
        }
        return .{
            .result = yes > n / 2,
            .yes_votes = yes,
            .no_votes = n - yes,
            .confidence = @as(f32, @floatFromInt(yes)) / @as(f32, @floatFromInt(n)),
            .tier = tierFromCount(@intCast(n)),
        };
    }

    pub fn verifyMemo(cached: i64, recomputed: i64, tier: Tier) ConsensusResult {
        return verifyValue(cached, recomputed, @intFromEnum(tier));
    }

    fn tierFromCount(count: u8) Tier {
        if (count >= 31) return .critical;
        if (count >= 15) return .high;
        if (count >= 7) return .standard;
        return .quick;
    }
};

// ═══════════════════════════════════════════════════════════════════
// 3. SHIFT-ADD ENGINE
// ═══════════════════════════════════════════════════════════════════
pub const ShiftAdd = struct {
    pub fn mul(a: i64, b: i64) i64 {
        const sign_a = a < 0;
        const sign_b = b < 0;
        const abs_a: u64 = if (sign_a) @intCast(-a) else @intCast(a);
        const abs_b: u64 = if (sign_b) @intCast(-b) else @intCast(b);
        var result: u64 = 0;
        var remaining = abs_b;
        var shift: u6 = 0;
        while (remaining != 0) {
            if (remaining & 1 != 0) {
                result +%= abs_a << shift;
            }
            remaining >>= 1;
            if (shift == 63) break;
            shift += 1;
        }
        const signed: i64 = @bitCast(result);
        return if (sign_a != sign_b) -signed else signed;
    }

    pub fn mulConst(a: i64, comptime b: comptime_int) i64 {
        if (b == 0) return 0;
        if (b == 1) return a;
        if (b == -1) return -a;
        if (b == 2) return a << 1;
        if (b == 4) return a << 2;
        if (b == 8) return a << 3;
        if (b == 16) return a << 4;
        if (b == 32) return a << 5;
        if (b == 64) return a << 6;
        if (b == 128) return a << 7;
        if (b == 256) return a << 8;
        if (b == 512) return a << 9;
        if (b == 1024) return a << 10;
        if (b == 3) return (a << 1) +% a;
        if (b == 5) return (a << 2) +% a;
        if (b == 6) return (a << 2) +% (a << 1);
        if (b == 7) return (a << 3) -% a;
        if (b == 9) return (a << 3) +% a;
        if (b == 10) return (a << 3) +% (a << 1);
        if (b == 15) return (a << 4) -% a;
        if (b == 17) return (a << 4) +% a;
        if (b == 255) return (a << 8) -% a;
        if (b == 257) return (a << 8) +% a;
        return mul(a, b);
    }

    pub fn scaleFixed(a: i64, num: i64, den: i64) i64 {
        if (den == 0) return 0;
        const wide_a: i128 = @intCast(a);
        const wide_num: i128 = @intCast(num);
        const wide_den: i128 = @intCast(den);
        const result = @divTrunc(wide_a * wide_num, wide_den);
        return @truncate(result);
    }

    pub fn dotProduct(a: []const i32, b: []const i32) i64 {
        const len = @min(a.len, b.len);
        var acc: i64 = 0;
        for (0..len) |i| {
            acc +%= mul(@intCast(a[i]), @intCast(b[i]));
        }
        return acc;
    }

    pub fn hashNoMul(data: []const u8) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for (data) |byte| {
            h ^= byte;
            const h40 = h << 40;
            const h8 = h << 8;
            const hb3 = (h << 7) +% (h << 5) +% (h << 4) +% (h << 1) +% h;
            h = h40 +% h8 +% hb3;
        }
        return h;
    }

    pub fn computeKey(a: i64, b: i64, op_tag: u32) u64 {
        var h: u64 = 0xcbf29ce484222325;
        h ^= @bitCast(a);
        h = (h << 40) +% (h << 8) +% h;
        h ^= @bitCast(b);
        h = (h << 40) +% (h << 8) +% h;
        h ^= @as(u64, op_tag);
        h = (h << 40) +% (h << 8) +% h;
        return h;
    }

    // -----------------------------------------------------------------
    // Zig 0.16.0 ASM Intrinsics
    // Explicit inline asm + arch-specific intrinsics for shift-add and
    // mixing. Guarantees the "zero hardware MUL" contract is visible
    // and gives the backend precise control.
    // -----------------------------------------------------------------

    /// ASM-accelerated general multiply (still decomposes to shifts+adds).
    /// Falls back to the pure Zig version. On aarch64/x86 we use asm shls.
    pub fn mulAsm(a: i64, b: i64) i64 {
        // Decompose b, but use asmShlAdd for each set bit.
        const sign_a = a < 0;
        const sign_b = b < 0;
        const abs_a: u64 = if (sign_a) @intCast(-a) else @intCast(a);
        const abs_b: u64 = if (sign_b) @intCast(-b) else @intCast(b);
        var result: u64 = 0;
        var remaining = abs_b;
        var shift: u6 = 0;
        while (remaining != 0) {
            if (remaining & 1 != 0) {
                result = @bitCast(asmShlAdd(@bitCast(result), shift, @bitCast(abs_a)));
            }
            remaining >>= 1;
            if (shift == 63) break;
            shift += 1;
        }
        const signed: i64 = @bitCast(result);
        return if (sign_a != sign_b) -signed else signed;
    }

    /// Use the asm hash mixer (makes the no-mul property extremely explicit).
    pub fn hashNoMulAsm(data: []const u8) u64 {
        var h: u64 = 0xcbf29ce484222325;
        for (data) |byte| {
            h ^= byte;
            h = asmHashMix(h, 0);
            // Still do the explicit decomposition using our mix
            const h40 = h << 40;
            const h8 = h << 8;
            const hb3 = (h << 7) +% (h << 5) +% (h << 4) +% (h << 1) +% h;
            h = h40 +% h8 +% hb3;
        }
        return h;
    }
};


// ═══════════════════════════════════════════════════════════════════
// 4. MEP — Minimum Energy Path
// ═══════════════════════════════════════════════════════════════════
pub const MEP = struct {
    pub const Path = enum(u2) { cached = 0, shift_add = 1, full = 2 };
    pub const PrecisionReq = enum(u8) { approximate = 0, exact = 1, verified = 2 };

    pub fn route(
        cache: *Tricache,
        key_hash: u64,
        precision: PrecisionReq,
        compute_fn: *const fn () i64,
    ) struct { value: i64, path: Path } {
        switch (precision) {
            .approximate => {
                if (cache.lookup(key_hash)) |cached| return .{ .value = cached, .path = .cached };
                const result = compute_fn();
                cache.storeCold(key_hash, result, 0);
                return .{ .value = result, .path = .shift_add };
            },
            .exact => {
                if (cache.lookup(key_hash)) |cached| return .{ .value = cached, .path = .cached };
                const result = compute_fn();
                cache.store(key_hash, result, 0);
                return .{ .value = result, .path = .shift_add };
            },
            .verified => {
                const result = compute_fn();
                if (cache.lookup(key_hash)) |cached| {
                    const c = Int1Consensus.verifyMemo(cached, result, .standard);
                    if (c.result) return .{ .value = cached, .path = .cached };
                }
                cache.store(key_hash, result, 0);
                return .{ .value = result, .path = .shift_add };
            },
        }
    }

    pub fn energyCost(path: Path) u32 {
        return switch (path) {
            .cached => 1,
            .shift_add => 10,
            .full => 100,
        };
    }
};

// ═══════════════════════════════════════════════════════════════════
// SMURFS 4D State (persona blending etc.)
// ═══════════════════════════════════════════════════════════════════
pub const SMURFS_SCALE: i128 = 1 << 60;

pub const SmurfsState = struct {
    theta: i64 = 0,
    phi: i64 = 0,
    psi: i64 = 0,
    tau: i64 = 0,

    pub fn blend(self: SmurfsState, other: SmurfsState, alpha: u16) SmurfsState {
        const a: i64 = @intCast(alpha);
        const inv_a: i64 = 1024 - a;
        return .{
            .theta = @divTrunc(ShiftAdd.mul(self.theta, inv_a) +% ShiftAdd.mul(other.theta, a), 1024),
            .phi = @divTrunc(ShiftAdd.mul(self.phi, inv_a) +% ShiftAdd.mul(other.phi, a), 1024),
            .psi = @divTrunc(ShiftAdd.mul(self.psi, inv_a) +% ShiftAdd.mul(other.psi, a), 1024),
            .tau = @divTrunc(ShiftAdd.mul(self.tau, inv_a) +% ShiftAdd.mul(other.tau, a), 1024),
        };
    }

    pub fn manhattanDistance(self: SmurfsState, other: SmurfsState) i64 {
        return @abs(self.theta - other.theta) + @abs(self.phi - other.phi) +
            @abs(self.psi - other.psi) + @abs(self.tau - other.tau);
    }
};

// ═══════════════════════════════════════════════════════════════════
// AxicoreContext (top level container)
// ═══════════════════════════════════════════════════════════════════
pub const AxicoreContext = struct {
    tricache: Tricache,
    hw: HwDispatch,
    smurfs: SmurfsState = .{},
    total_shift_add_ops: u64 = 0,
    energy_saved_estimate: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !AxicoreContext {
        const tc = try Tricache.init(allocator);
        const hw = HwDispatch.detect();
        log.info("[axicore] context ready | hw={s}", .{@tagName(hw.primary)});
        return .{ .tricache = tc, .hw = hw, .allocator = allocator };
    }

    pub fn deinit(self: *AxicoreContext) void {
        self.tricache.deinit();
    }

    pub fn memoizedMul(self: *AxicoreContext, a: i64, b: i64) i64 {
        const key = ShiftAdd.computeKey(a, b, 0x4D554C);
        if (self.tricache.lookup(key)) |v| {
            self.energy_saved_estimate += MEP.energyCost(.cached);
            return v;
        }
        const result = ShiftAdd.mul(a, b);
        self.tricache.store(key, result, 0x4D554C);
        self.total_shift_add_ops += 1;
        self.energy_saved_estimate += MEP.energyCost(.shift_add);
        return result;
    }
};

// ═══════════════════════════════════════════════════════════════════
// HwDispatch (Hardware abstraction - stubs per current phase)
// ═══════════════════════════════════════════════════════════════════
pub const HwBackend = enum { scalar, neon, cuda, rknn2, metal, vulkan, unknown };

pub const HwDispatch = struct {
    primary: HwBackend = .scalar,
    supports_neon: bool = false,
    supports_cuda: bool = false,

    pub fn detect() HwDispatch {
        // TODO: real detection (cpuid, cudaGetDevice, /dev/rknpu etc.)
        // For now default to scalar (safe everywhere). Reviews noted RKNN2/NEON/CUDA priority.
        var d = HwDispatch{ .primary = .scalar };
        // Placeholder: could query builtin or env
        return d;
    }

    pub fn dispatchAdd(self: *const HwDispatch, a: i64, b: i64) i64 {
        _ = self;
        return a +% b; // native for now
    }
};

// ---------------------------------------------------------------------------
// Zig 0.16.0 ASM + intrinsics helpers (top-level for easy use by ALU/lower)
// ---------------------------------------------------------------------------

pub fn asmShlAdd(a: i64, shift: u6, b: i64) i64 {
    const builtin = @import("builtin");
    const arch = builtin.target.cpu.arch;
    return switch (arch) {
        .x86_64 => asmShlAddX64(a, shift, b),
        .aarch64 => asmShlAddAarch64(a, shift, b),
        else => (a << shift) +% b,
    };
}

inline fn asmShlAddX64(a: i64, shift: u6, b: i64) i64 {
    const sc: u64 = @as(u64, 1) << @min(shift, 3);
    return asm ("lea %[out], [%[a] + %[b] * %[sc]]"
        : [out] "=r" (-> i64),
        : [a] "r" (a),
          [b] "r" (b),
          [sc] "i" (sc),
    );
}

inline fn asmShlAddAarch64(a: i64, shift: u6, b: i64) i64 {
    var tmp: i64 = undefined;
    return asm ("lsl %[tmp], %[a], %[sh]\n\tadd %[out], %[tmp], %[b]"
        : [out] "=r" (-> i64),
          [tmp] "=&r" (tmp),
        : [a] "r" (a),
          [b] "r" (b),
          [sh] "i" (shift),
        : "cc"
    );
}

pub fn asmHashMix(h: u64, x: u64) u64 {
    var res = h ^ x;
    const arch = @import("builtin").target.cpu.arch;
    if (arch == .x86_64 or arch == .aarch64) {
        var out: u64 = undefined;
        _ = asm ("mov %[out], %[v]\n\tshl %[out], 40\n\tadd %[out], %[v]\n\tshl %[v], 8\n\tadd %[out], %[v]"
            : [out] "=r" (out),
            : [v] "r" (res),
        );
        return out;
    }
    const v40 = res << 40;
    const v8 = res << 8;
    return v40 +% v8 +% res;
}

// Tests from conv log
test "shift-add: multiply" {
    try std.testing.expectEqual(@as(i64, 42), ShiftAdd.mul(7, 6));
    try std.testing.expectEqual(@as(i64, -42), ShiftAdd.mul(-7, 6));
    try std.testing.expectEqual(@as(i64, 42), ShiftAdd.mul(-7, -6));
    try std.testing.expectEqual(@as(i64, 0), ShiftAdd.mul(0, 12345));
    try std.testing.expectEqual(@as(i64, 10000), ShiftAdd.mul(100, 100));
}

test "shift-add: mulConst" {
    try std.testing.expectEqual(@as(i64, 30), ShiftAdd.mulConst(10, 3));
    try std.testing.expectEqual(@as(i64, 50), ShiftAdd.mulConst(10, 5));
    try std.testing.expectEqual(@as(i64, 70), ShiftAdd.mulConst(10, 7));
    try std.testing.expectEqual(@as(i64, 10240), ShiftAdd.mulConst(10, 1024));
}

test "shift-add: hash no mul" {
    const h1 = ShiftAdd.hashNoMul("hello");
    const h2 = ShiftAdd.hashNoMul("hello");
    const h3 = ShiftAdd.hashNoMul("world");
    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != h3);
}

test "asm intrinsics: shlAdd + hashMix" {
    const v = asmShlAdd(10, 2, 3); // (10<<2) + 3 = 43
    try std.testing.expectEqual(@as(i64, 43), v);
    const hm = asmHashMix(0x1234, 0xAB);
    try std.testing.expect(hm != 0);
}

test "asm intrinsics: mulAsm" {
    try std.testing.expectEqual(@as(i64, 42), ShiftAdd.mulAsm(7, 6));
}

test "int1 consensus: verifyValue" {
    const r1 = Int1Consensus.verifyValue(42, 42, 7);
    try std.testing.expect(r1.result);
    try std.testing.expect(r1.yes_votes >= 4);
    const r2 = Int1Consensus.verifyValue(42, 43, 7);
    try std.testing.expect(!r2.result or r2.yes_votes < 4); // low bits differ
}
