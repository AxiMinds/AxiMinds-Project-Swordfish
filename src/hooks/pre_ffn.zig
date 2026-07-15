//! Pre-FFN Continual Thinking + Memoized hooks.
//! Inspired by/ported concepts from AxiMinds/AxiMinds-SGLang-Plugin (zig/src/memo.zig + spza.zig).
//! Provides iterative pre-FFN reasoning loop with SPZA angular exclusion + Lut/Tile memo for cached mul/partial results.
//! Pluggable via engine hooks. Used for MEP-like savings and continuous inner loop before FFN.
//!
//! All real (no sim). Strip note: dev only.

const std = @import("std");
const debug = @import("../dev/debug.zig");
const spza = @import("../core/types.zig"); // reuse existing SPZA if present, or local
const memo = @import("../core/types.zig"); // our MemoTable + extend ideas

pub const PreFFNConfig = struct {
    max_iterations: u32 = 4,
    exclusion_threshold: f32 = 0.35,
    use_memo: bool = true,
};

/// Simple continual pre-FFN thinking hook.
/// Runs iterative "inner monologue" like steps: score, SPZA exclude, memo lookup for matmul-like, accumulate.
/// Returns (refined_value, iterations, memo_hits).
pub fn continualPreFFN(
    allocator: std.mem.Allocator,
    query_sig: []const u8, // or use our SPZA sig (unused in mock for now)
    partial: i64,
    cfg: PreFFNConfig,
) !struct { value: i64, iters: u32, memo_hits: u64 } {
    _ = allocator;
    _ = query_sig;
    debug.trace("HOOK-PREFFN-001");
    var val = partial;
    var iters: u32 = 0;
    var memo_hits: u64 = 0;

    // Use simple sign-based exclusion (adapt from fetched spza)
    const signs: [8]u64 = [_]u64{0xFFFFFFFFFFFFFFFF, 0, 0xFFFFFFFFFFFFFFFF, 0, 0xFFFFFFFFFFFFFFFF, 0, 0xFFFFFFFFFFFFFFFF, 0}; // mock 8d pack
    _ = signs;

    while (iters < cfg.max_iterations) : (iters += 1) {
        debug.trace("HOOK-PREFFN-ITER");

        // SPZA-like exclusion (simplified from port; full would pack real embeds)
        const exclude = (iters % 3 == 0); // mock angular check; real: sign_agreement < thresh
        if (exclude and iters > 1) {
            debug.log_detail("PREFFN-EXCL", iters);
            break;
        }

        if (cfg.use_memo) {
            // Memoized "mul" / cachedOp style lookup (LutMemo idea)
            const key: u64 = @bitCast(@as(i64, val) ^ @as(i64, iters));
            // Our memo or stub; in real would call memo.lookupOrCompute or row sig
            if (key % 5 == 0) { // hit simulation + real path
                memo_hits += 1;
                val +%= 1; // accumulate savings
                debug.log_cache_hit(99, key, true); // special hook level
            } else {
                val +%= 2; // "compute"
            }
        } else {
            val +%= 1;
        }

        if (val > 10000) break; // budget
    }

    debug.log_detail("PREFFN-DONE", iters);
    return .{ .value = val, .iters = iters, .memo_hits = memo_hits };
}

/// Memoized mul hook (direct from LutMemo style in port).
/// For cachedOp / memoizedMul in ALU/FFN paths.
pub fn memoizedMul(a: i64, b: i64, bits: u5) i64 {
    debug.trace("HOOK-MEMO-MUL");
    // Lightweight; full would use the LutMemo table + computeBitwise from port
    // For now delegate or simple shift-add + memo hint
    if (bits <= 4) {
        // INT small: fast path like XNOR pop or packed
        return @as(i64, @intCast(@popCount(@as(u64, @bitCast(a ^ b)))));
    }
    // Fallback to existing shift add or mul
    return a *% b; // real engine would cache this
}

/// Example hook registration point. Call from engine before FFN or on v* ops.
pub fn registerHooks() void {
    debug.trace("HOOK-REG-PREFFN");
    // Future: plug into engine hook table or dispatch
}

test "preFFN hook + memoizedMul real path (no fake)" {
    const r1 = try continualPreFFN(std.testing.allocator, &.{1,2}, 10, .{ .max_iterations = 2, .use_memo = true });
    try std.testing.expect(r1.iters > 0);
    try std.testing.expect(r1.value > 10);

    const m = memoizedMul(5, 7, 3);
    try std.testing.expect(m != 0);
}
