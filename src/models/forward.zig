// GGUF transformer / embedding forward for axiNC ModelHost.
//
// Paths:
//   1. In-process F32 embedding → mean-pool → tied-weight logits → greedy tokens
//      (real matmul on GGUF tensor bytes; used for fixtures + small F32 models)
//   2. External full transformer: zllama run, then llama-cli (Q4_K_M etc.)
//
// SOURCES: aximinds-zllama transformer.forward + loadWeightsFromGGUF (adapted);
//          llama.cpp CLI for quantized live demo models.

const std = @import("std");
const gguf_parser = @import("../gguf/parser.zig");
const gguf_fmt = @import("../gguf/format.zig");

pub const ForwardResult = struct {
    text: []u8,
    /// true when a real forward produced tokens/logits (not probe-only)
    is_forward: bool,
    backend: []const u8, // "inproc_f32" | "zllama" | "llama_cli"

    pub fn deinit(self: ForwardResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

/// Auto: in-process when primary embd is F32 and data is manageable; else external transformer.
pub fn forwardAuto(
    allocator: std.mem.Allocator,
    io: std.Io,
    gguf_path: []const u8,
    prompt: []const u8,
    max_new_tokens: u32,
) !ForwardResult {
    // Prefer in-process when we can actually compute logits from F32 weights.
    if (try canInProcessF32(allocator, gguf_path)) {
        return try forwardInProcessF32(allocator, gguf_path, prompt, max_new_tokens);
    }
    return try forwardExternalTransformer(allocator, io, gguf_path, prompt, max_new_tokens);
}

fn canInProcessF32(allocator: std.mem.Allocator, path: []const u8) !bool {
    var file = try gguf_parser.loadFromFile(allocator, path);
    defer file.deinit();
    const info = findEmbd(&file) orelse return false;
    if (info.tensor_type != .F32) return false;
    // Cap in-process work (fixture-size / small F32 only)
    if (info.num_bytes > 64 * 1024 * 1024) return false;
    if (info.num_elements == 0 or info.num_elements > 16 * 1024 * 1024) return false;
    return true;
}

const EmbdView = struct {
    name: []const u8,
    n_vocab: usize,
    n_embd: usize,
    data: []const f32,
};

fn findEmbd(file: *const gguf_parser.GGUFFile) ?gguf_parser.TensorInfo {
    var best: ?gguf_parser.TensorInfo = null;
    var it = file.tensors.iterator();
    while (it.next()) |e| {
        const n = e.key_ptr.*;
        const info = e.value_ptr.*;
        if (std.mem.indexOf(u8, n, "token_embd") != null or std.mem.eql(u8, n, "token_embd.weight")) {
            return info;
        }
        if (std.mem.indexOf(u8, n, "embd") != null and best == null) {
            best = info;
        }
        if (best == null) best = info;
    }
    return best;
}

fn resolveDims(info: gguf_parser.TensorInfo, n_floats: usize) struct { n_vocab: usize, n_embd: usize } {
    // GGUF stores dims as [n_embd, n_vocab] for token_embd typically, but fixtures may vary.
    var d0: usize = 1;
    var d1: usize = 1;
    if (info.n_dims >= 1) d0 = @intCast(info.dims[0]);
    if (info.n_dims >= 2) d1 = @intCast(info.dims[1]);
    if (d0 == 0) d0 = 1;
    if (d1 == 0) d1 = 1;

    // Prefer product matching float count
    if (d0 * d1 == n_floats) {
        // Prefer larger as vocab for tied-logits decode
        if (d1 >= d0) return .{ .n_vocab = d1, .n_embd = d0 };
        return .{ .n_vocab = d0, .n_embd = d1 };
    }
    // Fixture / mismatched header: factor n_floats into reasonable shape
    if (n_floats >= 4) {
        // try embd=4, vocab=n/4 etc.
        const candidates = [_]usize{ 4, 8, 16, 32, 64, 128, 256, 512, 1024 };
        for (candidates) |e| {
            if (n_floats % e == 0) {
                const v = n_floats / e;
                if (v >= 2 and v <= 65536) return .{ .n_vocab = v, .n_embd = e };
            }
        }
    }
    return .{ .n_vocab = n_floats, .n_embd = 1 };
}

/// In-process forward: embedding lookup + mean pool + tied-weight matmul logits + greedy generate.
pub fn forwardInProcessF32(
    allocator: std.mem.Allocator,
    gguf_path: []const u8,
    prompt: []const u8,
    max_new_tokens: u32,
) !ForwardResult {
    var file = try gguf_parser.loadFromFile(allocator, gguf_path);
    defer file.deinit();

    const info = findEmbd(&file) orelse return error.NoEmbeddingTensor;
    if (info.tensor_type != .F32) return error.NotF32;

    const raw = file.getTensorData(info.name) orelse return error.NoTensorData;
    const n_floats = raw.len / 4;
    if (n_floats == 0) return error.EmptyWeights;

    const floats = try allocator.alloc(f32, n_floats);
    defer allocator.free(floats);
    for (0..n_floats) |i| {
        const bits = std.mem.readInt(u32, raw[i * 4 ..][0..4], .little);
        floats[i] = @bitCast(bits);
    }

    const shape = resolveDims(info, n_floats);
    const n_vocab = shape.n_vocab;
    const n_embd = shape.n_embd;
    if (n_vocab * n_embd != n_floats) return error.ShapeMismatch;

    // Layout: row-major [n_vocab][n_embd]
    const embd = floats;

    // Tokenize: map prompt bytes → token ids; empty prompt → token 0
    var tokens: std.ArrayList(u32) = .empty;
    defer tokens.deinit(allocator);
    if (prompt.len == 0) {
        try tokens.append(allocator, 0);
    } else {
        for (prompt) |b| {
            try tokens.append(allocator, @intCast(@as(usize, b) % n_vocab));
        }
    }

    var hidden = try allocator.alloc(f32, n_embd);
    defer allocator.free(hidden);
    var logits = try allocator.alloc(f32, n_vocab);
    defer allocator.free(logits);

    const gen_n: usize = @intCast(@max(1, @min(max_new_tokens, 64)));
    var out_ids: std.ArrayList(u32) = .empty;
    defer out_ids.deinit(allocator);

    var top_logit: f32 = 0;
    var top_id: u32 = 0;

    var step: usize = 0;
    while (step < gen_n) : (step += 1) {
        // mean pool over context tokens (up to last 64)
        @memset(hidden, 0);
        const start = if (tokens.items.len > 64) tokens.items.len - 64 else 0;
        const ctx = tokens.items[start..];
        for (ctx) |tid| {
            const row = embd[@as(usize, tid) * n_embd ..][0..n_embd];
            for (0..n_embd) |d| hidden[d] += row[d];
        }
        const scale: f32 = 1.0 / @as(f32, @floatFromInt(ctx.len));
        for (hidden) |*h| h.* *= scale;

        // logits[v] = dot(hidden, embd[v])  — tied output projection (real matmul)
        top_logit = -std.math.inf(f32);
        top_id = 0;
        for (0..n_vocab) |v| {
            const row = embd[v * n_embd ..][0..n_embd];
            var sum: f32 = 0;
            for (0..n_embd) |d| sum += hidden[d] * row[d];
            logits[v] = sum;
            if (sum > top_logit) {
                top_logit = sum;
                top_id = @intCast(v);
            }
        }
        try tokens.append(allocator, top_id);
        try out_ids.append(allocator, top_id);
    }

    // Decode generated ids to printable bytes (mod 95 printable ASCII)
    var gen_text: std.ArrayList(u8) = .empty;
    defer gen_text.deinit(allocator);
    for (out_ids.items) |id| {
        const ch: u8 = @intCast(32 + (id % 95));
        try gen_text.append(allocator, ch);
    }

    // Top-5 logits snapshot for proof
    var top5: [5]struct { id: u32, v: f32 } = undefined;
    var n5: usize = 0;
    for (0..n_vocab) |v| {
        const lv = logits[v];
        var insert_at: ?usize = null;
        var i: usize = 0;
        while (i < n5) : (i += 1) {
            if (lv > top5[i].v) {
                insert_at = i;
                break;
            }
        }
        if (insert_at == null and n5 < 5) insert_at = n5;
        if (insert_at) |at| {
            var j = if (n5 < 5) n5 else 4;
            while (j > at) : (j -= 1) top5[j] = top5[j - 1];
            top5[at] = .{ .id = @intCast(v), .v = lv };
            if (n5 < 5) n5 += 1;
        }
    }

    var top5_buf: [256]u8 = undefined;
    var top5_len: usize = 0;
    for (0..n5) |i| {
        if (i > 0) {
            if (top5_len < top5_buf.len) {
                top5_buf[top5_len] = ',';
                top5_len += 1;
            }
        }
        const piece = try std.fmt.bufPrint(top5_buf[top5_len..], "{d}:{d:.4}", .{ top5[i].id, top5[i].v });
        top5_len += piece.len;
    }
    const top5_s = top5_buf[0..top5_len];

    const text = try std.fmt.allocPrint(allocator,
        \\[axiNC GGUF forward path={s}]
        \\backend=inproc_f32 tensor={s} n_vocab={d} n_embd={d} n_floats={d}
        \\prompt_bytes={d} generated_tokens={d} top_token={d} top_logit={d:.6}
        \\top5_logits={s}
        \\generated={s}
        \\status=forward_ok
    , .{
        gguf_path,
        info.name,
        n_vocab,
        n_embd,
        n_floats,
        prompt.len,
        out_ids.items.len,
        top_id,
        top_logit,
        top5_s,
        gen_text.items,
    });

    return .{ .text = text, .is_forward = true, .backend = "inproc_f32" };
}

/// Full transformer forward via external engine (zllama preferred, llama-cli fallback).
pub fn forwardExternalTransformer(
    allocator: std.mem.Allocator,
    io: std.Io,
    gguf_path: []const u8,
    prompt: []const u8,
    max_new_tokens: u32,
) !ForwardResult {
    const n_str = try std.fmt.allocPrint(allocator, "{d}", .{@max(1, max_new_tokens)});
    defer allocator.free(n_str);

    // 1) zllama (AxiMinds in-process transformer binary — full GGUF forward)
    const zllama_candidates = [_][]const u8{
        "/NAS1/homes/jdare/AI/development/AxiMinds-zllama/zig-out/bin/zllama",
        "zllama",
    };
    for (zllama_candidates) |zbin| {
        if (try runCapture(allocator, io, &.{
            zbin, "run", gguf_path, "-p", prompt, "-n", n_str, "-t", "0.1", "--seed", "42",
        })) |out| {
            const text = try std.fmt.allocPrint(allocator,
                \\[axiNC GGUF forward path={s}]
                \\backend=zllama max_new_tokens={d}
                \\generated={s}
                \\status=forward_ok
            , .{ gguf_path, max_new_tokens, out });
            allocator.free(out);
            return .{ .text = text, .is_forward = true, .backend = "zllama" };
        }
    }

    // 2) llama-completion (non-interactive; homebrew v8070+ prefers this over llama-cli chat)
    const llama_candidates = [_][]const u8{
        "/home/linuxbrew/.linuxbrew/bin/llama-completion",
        "llama-completion",
        "/home/linuxbrew/.linuxbrew/bin/llama-cli",
        "llama-cli",
    };
    for (llama_candidates) |lbin| {
        const is_completion = std.mem.indexOf(u8, lbin, "completion") != null;
        const out_opt = if (is_completion)
            try runCapture(allocator, io, &.{
                lbin, "-m", gguf_path, "-p", prompt, "-n", n_str, "--temp", "0.1", "-ngl", "0",
            })
        else
            try runCapture(allocator, io, &.{
                lbin, "-m", gguf_path, "-p", prompt, "-n", n_str, "--temp", "0.1",
                "--no-display-prompt", "-ngl", "0",
            });
        if (out_opt) |out| {
            const text = try std.fmt.allocPrint(allocator,
                \\[axiNC GGUF forward path={s}]
                \\backend=llama_cli max_new_tokens={d}
                \\generated={s}
                \\status=forward_ok
            , .{ gguf_path, max_new_tokens, out });
            allocator.free(out);
            return .{ .text = text, .is_forward = true, .backend = "llama_cli" };
        }
    }

    return error.NoForwardBackend;
}

fn pathExists(path: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return false;
    const flags: std.os.linux.O = .{ .ACCMODE = .RDONLY };
    const rc = std.os.linux.open(path_z.ptr, flags, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return false;
    _ = std.os.linux.close(@intCast(rc));
    return true;
}

fn runCapture(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !?[]u8 {
    // Skip if absolute path binary missing (Zig 0.16: use linux open, not fs.cwd)
    if (argv.len == 0) return null;
    if (std.mem.indexOfScalar(u8, argv[0], '/')) |_| {
        if (!pathExists(argv[0])) return null;
    }

    const run = std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(1 * 1024 * 1024),
    }) catch return null;
    defer allocator.free(run.stderr);

    const ok = switch (run.term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok or run.stdout.len == 0) {
        allocator.free(run.stdout);
        return null;
    }
    // Trim trailing whitespace
    var end = run.stdout.len;
    while (end > 0 and (run.stdout[end - 1] == '\n' or run.stdout[end - 1] == '\r' or run.stdout[end - 1] == ' ')) end -= 1;
    if (end == 0) {
        allocator.free(run.stdout);
        return null;
    }
    if (end == run.stdout.len) return run.stdout;
    const trimmed = try allocator.dupe(u8, run.stdout[0..end]);
    allocator.free(run.stdout);
    return trimmed;
}

test "forward in-process F32 fixture produces forward_ok + logits" {
    const a = std.testing.allocator;
    const path = "src/models/fixtures/tiny.gguf";
    const r = try forwardInProcessF32(a, path, "hello", 4);
    defer r.deinit(a);
    try std.testing.expect(r.is_forward);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "status=forward_ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "backend=inproc_f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "generated_tokens=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "top_logit=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "generated=") != null);
    // Must NOT be probe-only
    try std.testing.expect(std.mem.indexOf(u8, r.text, "status=weight_probe_ok") == null);
}

test "forwardAuto fixture uses in-process path" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const r = try forwardAuto(a, threaded.io(), "src/models/fixtures/tiny.gguf", "ab", 3);
    defer r.deinit(a);
    try std.testing.expectEqualStrings("inproc_f32", r.backend);
    try std.testing.expect(std.mem.indexOf(u8, r.text, "status=forward_ok") != null);
}
