// Live FFN consumer for axiNC — drives the shipped C ABI FFN tap (not a mock).
// Used by CLI (`ffn-consumer` / `live-demo`) and dual-run verification scripts.
//
// Host flow: init → load axiASM → ffn_tap(cycles) → stats JSON → optional model forward.

const std = @import("std");
const bridge = @import("../bridge_lib.zig");
const models = @import("../models/host.zig");
const forward = @import("../models/forward.zig");

pub const ConsumerResult = struct {
    cycles_ran: u64,
    stats_json: []u8,
    axiasm_ops: i32,
    /// Optional secondary infer / forward transcript (owned)
    forward_text: ?[]u8 = null,

    pub fn deinit(self: *ConsumerResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stats_json);
        if (self.forward_text) |t| allocator.free(t);
        self.* = .{ .cycles_ran = 0, .stats_json = &[_]u8{}, .axiasm_ops = 0 };
    }
};

/// Default NC program: arithmetic + halt — guarantees nonzero cycles on tap.
pub const DEFAULT_AXIASM =
    \\MOVI R1, 10
    \\MOVI R2, 3
    \\MUL R3, R1, R2
    \\ADD R4, R3, R1
    \\MOVI R5, 7
    \\MUL R6, R4, R5
    \\HALT
;

/// Run live FFN consumer against global C ABI (real `axinc_ffn_tap`).
/// Caller must not have conflicting global bridge state; this init/shutdown wraps the session.
pub fn runLive(
    allocator: std.mem.Allocator,
    cycle_budget: u64,
    axiasm_src: []const u8,
) !ConsumerResult {
    const rc = bridge.axinc_init();
    if (rc != 0) return error.InitFailed;
    errdefer bridge.axinc_shutdown();

    // NUL-terminate for C ABI
    const z = try allocator.allocSentinel(u8, axiasm_src.len, 0);
    defer allocator.free(z);
    @memcpy(z[0..axiasm_src.len], axiasm_src);

    const n_ops = bridge.axinc_load_axiasm(z.ptr);
    if (n_ops < 0) return error.LoadAsmFailed;

    const ran = bridge.axinc_ffn_tap(cycle_budget);
    if (ran == 0) return error.ZeroCycles;

    var buf: [2048]u8 = undefined;
    const n = bridge.axinc_get_stats_json(&buf, buf.len);
    if (n == 0) return error.NoStats;
    const stats = try allocator.dupe(u8, buf[0..n]);

    return .{
        .cycles_ran = ran,
        .stats_json = stats,
        .axiasm_ops = n_ops,
        .forward_text = null,
    };
}

/// Live consumer + GGUF forward on the same session (register model, infer, then FFN tap).
pub fn runLiveWithGgufForward(
    allocator: std.mem.Allocator,
    io: std.Io,
    cycle_budget: u64,
    gguf_path: []const u8,
    prompt: []const u8,
    max_new_tokens: u32,
) !ConsumerResult {
    const rc = bridge.axinc_init();
    if (rc != 0) return error.InitFailed;
    errdefer bridge.axinc_shutdown();

    const z = try allocator.allocSentinel(u8, DEFAULT_AXIASM.len, 0);
    defer allocator.free(z);
    @memcpy(z[0..DEFAULT_AXIASM.len], DEFAULT_AXIASM);

    const n_ops = bridge.axinc_load_axiasm(z.ptr);
    if (n_ops < 0) return error.LoadAsmFailed;

    // Register via C ABI (real path)
    const path_z = try allocator.allocSentinel(u8, gguf_path.len, 0);
    defer allocator.free(path_z);
    @memcpy(path_z[0..gguf_path.len], gguf_path);
    const slot = bridge.axinc_model_register(1, path_z.ptr);
    if (slot < 0) return error.ModelRegisterFailed;

    // Direct forward (same stack as ModelHost.infer) for full transcript
    const fr = try forward.forwardAuto(allocator, io, gguf_path, prompt, max_new_tokens);
    // also exercise C ABI infer
    var out: [4096]u8 = undefined;
    const prompt_z = try allocator.allocSentinel(u8, prompt.len, 0);
    defer allocator.free(prompt_z);
    @memcpy(prompt_z[0..prompt.len], prompt);
    const infer_n = bridge.axinc_model_infer(slot, prompt_z.ptr, &out, out.len);
    _ = infer_n;

    // FFN tap after model work (live interaction pattern)
    const ran = bridge.axinc_ffn_tap(cycle_budget);
    if (ran == 0) {
        fr.deinit(allocator);
        return error.ZeroCycles;
    }

    var buf: [2048]u8 = undefined;
    const n = bridge.axinc_get_stats_json(&buf, buf.len);
    const stats = try allocator.dupe(u8, buf[0..n]);

    return .{
        .cycles_ran = ran,
        .stats_json = stats,
        .axiasm_ops = n_ops,
        .forward_text = fr.text,
    };
}

pub fn shutdownSession() void {
    bridge.axinc_shutdown();
}

test "live FFN consumer nonzero cycles + stats" {
    const a = std.testing.allocator;
    var r = try runLive(a, 128, DEFAULT_AXIASM);
    defer {
        r.deinit(a);
        shutdownSession();
    }
    try std.testing.expect(r.cycles_ran > 0);
    try std.testing.expect(r.axiasm_ops >= 4);
    try std.testing.expect(std.mem.indexOf(u8, r.stats_json, "cycles") != null);
    // cycles field in JSON should be > 0
    try std.testing.expect(std.mem.indexOf(u8, r.stats_json, "\"cycles\":0") == null);
}

test "live FFN consumer dual-run consistent success" {
    const a = std.testing.allocator;
    var r1 = try runLive(a, 64, DEFAULT_AXIASM);
    const c1 = r1.cycles_ran;
    r1.deinit(a);
    shutdownSession();

    var r2 = try runLive(a, 64, DEFAULT_AXIASM);
    const c2 = r2.cycles_ran;
    r2.deinit(a);
    shutdownSession();

    try std.testing.expect(c1 > 0);
    try std.testing.expect(c2 > 0);
    // Same program → same cycle count
    try std.testing.expectEqual(c1, c2);
}

// Ensure models module linked
comptime {
    _ = models.ModelHost;
}
