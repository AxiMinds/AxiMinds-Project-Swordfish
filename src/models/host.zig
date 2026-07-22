// Multi-model host for axiNC.
// Secondary models: Ollama tags (live chat) or GGUF files (full forward: in-proc F32 or zllama/llama-cli).
//
// SOURCES:
//   - aximinds-zllama/src/gguf/parser.zig + transformer.forward (via zllama binary / in-proc embd path)
//   - AxiMinds-Claude-Remote ollama orchestrator (chat)
//   - AxiMinds-Discovery multi-model roles

const std = @import("std");
const ollama = @import("../bridge/ollama_client.zig");
const gguf_parser = @import("../gguf/parser.zig");
const gguf_fmt = @import("../gguf/format.zig");
const forward = @import("forward.zig");

pub const ModelKind = enum { ollama, gguf };

/// Test / CI inject boundary for Ollama replies (honest secondary path without live daemon).
/// When non-null, `infer(.ollama, ...)` returns a dupe of this string instead of calling the network.
pub var test_ollama_reply: ?[]const u8 = null;

pub const ModelSlot = struct {
    kind: ModelKind,
    /// Ollama tag or filesystem path (owned)
    name: []u8,
    architecture: []u8 = &[_]u8{},
    context_length: u32 = 0,
    embedding_length: u32 = 0,
    block_count: u32 = 0,
    tensor_count: u64 = 0,
    /// Cached at register for GGUF: first tensor name (owned, may be empty)
    primary_tensor: []u8 = &[_]u8{},
    /// Sum of first probe_count F32 values from primary tensor (or bitcast u32 sum for non-F32)
    weight_probe_sum_f32: f64 = 0,
    weight_probe_count: u32 = 0,
    /// XOR-fold of first up-to-4KiB of primary tensor bytes (real weight fingerprint)
    weight_fingerprint: u64 = 0,
    loaded: bool = false,
};

pub const ModelHost = struct {
    allocator: std.mem.Allocator = undefined,
    slots: [8]?ModelSlot = [_]?ModelSlot{null} ** 8,
    n: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ModelHost {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ModelHost) void {
        for (&self.slots) |*slot| {
            if (slot.*) |*s| {
                self.allocator.free(s.name);
                if (s.architecture.len > 0) self.allocator.free(s.architecture);
                if (s.primary_tensor.len > 0) self.allocator.free(s.primary_tensor);
                slot.* = null;
            }
        }
        self.n = 0;
    }

    pub fn count(self: *const ModelHost) usize {
        return self.n;
    }

    pub fn register(self: *ModelHost, kind: ModelKind, name_or_path: []const u8) !usize {
        if (self.n >= self.slots.len) return error.SlotsFull;
        const name = try self.allocator.dupe(u8, name_or_path);
        errdefer self.allocator.free(name);

        var slot = ModelSlot{ .kind = kind, .name = name, .loaded = false };

        if (kind == .gguf) {
            var file = try gguf_parser.loadFromFile(self.allocator, name_or_path);
            defer file.deinit();
            slot.tensor_count = file.header.tensor_count;
            if (file.getMetadataString(gguf_fmt.MetadataKeys.general_architecture)) |arch| {
                slot.architecture = try self.allocator.dupe(u8, arch);
            } else if (file.getMetadataString("general.architecture")) |arch| {
                slot.architecture = try self.allocator.dupe(u8, arch);
            }
            slot.context_length = @intCast(file.getMetadataInt(gguf_fmt.MetadataKeys.context_length) orelse
                file.getMetadataInt(gguf_fmt.MetadataKeys.qwen2_context_length) orelse
                file.getMetadataInt("qwen3.context_length") orelse 0);
            slot.embedding_length = @intCast(file.getMetadataInt(gguf_fmt.MetadataKeys.embedding_length) orelse
                file.getMetadataInt(gguf_fmt.MetadataKeys.qwen2_embedding_length) orelse
                file.getMetadataInt("qwen3.embedding_length") orelse 0);
            slot.block_count = @intCast(file.getMetadataInt(gguf_fmt.MetadataKeys.block_count) orelse
                file.getMetadataInt(gguf_fmt.MetadataKeys.qwen2_block_count) orelse
                file.getMetadataInt("qwen3.block_count") orelse 0);

            // Real weight probe at register time (drives MVP infer without re-parse races)
            const probe = try probePrimaryTensor(self.allocator, &file);
            slot.primary_tensor = probe.name;
            slot.weight_probe_sum_f32 = probe.sum_f32;
            slot.weight_probe_count = probe.count;
            slot.weight_fingerprint = probe.fingerprint;
            slot.loaded = true;
        } else {
            slot.loaded = true;
        }

        const id = self.n;
        self.slots[id] = slot;
        self.n += 1;
        return id;
    }

    /// Infer on slot.
    /// - Ollama: real /api/chat (or test_ollama_reply inject)
    /// - GGUF: full forward (in-process F32 embd→logits, or zllama/llama-cli transformer)
    pub fn infer(self: *ModelHost, allocator: std.mem.Allocator, io: std.Io, slot_id: usize, prompt: []const u8) ![]u8 {
        if (slot_id >= self.n) return error.InvalidSlot;
        const slot = self.slots[slot_id] orelse return error.InvalidSlot;

        switch (slot.kind) {
            .ollama => {
                // Inject boundary for tests/CI (package var — honest secondary path without network)
                if (test_ollama_reply) |mock| {
                    return try allocator.dupe(u8, mock);
                }
                const cfg = ollama.Config{ .model = slot.name };
                const r = try ollama.chat(allocator, io, cfg, prompt, "You are a secondary model hosted by axiNC ModelHost.");
                if (!r.ok) {
                    defer r.deinit(allocator);
                    return error.InferFailed;
                }
                return r.text;
            },
            .gguf => {
                // Full forward path (not probe-only). Append probe diagnostics for vet.
                const fr = try forward.forwardAuto(allocator, io, slot.name, prompt, 8);
                defer fr.deinit(allocator);
                return try std.fmt.allocPrint(allocator,
                    \\{s}
                    \\[slot={d} architecture={s} tensors={d} primary_tensor={s}]
                    \\weight_probe_count={d} weight_probe_sum_f32={d:.6} weight_fingerprint=0x{x:0>16}
                    \\forward_backend={s}
                , .{
                    fr.text,
                    slot_id,
                    if (slot.architecture.len > 0) slot.architecture else "unknown",
                    slot.tensor_count,
                    if (slot.primary_tensor.len > 0) slot.primary_tensor else "(none)",
                    slot.weight_probe_count,
                    slot.weight_probe_sum_f32,
                    slot.weight_fingerprint,
                    fr.backend,
                });
            },
        }
    }
};

const ProbeResult = struct {
    name: []u8,
    sum_f32: f64,
    count: u32,
    fingerprint: u64,
};

/// Walk GGUF tensors; prefer token_embd.weight / *.weight; probe real bytes.
fn probePrimaryTensor(allocator: std.mem.Allocator, file: *const gguf_parser.GGUFFile) !ProbeResult {
    var chosen_name: ?[]const u8 = null;
    var chosen_data: ?[]const u8 = null;

    var it = file.tensors.iterator();
    while (it.next()) |e| {
        const n = e.key_ptr.*;
        const data = file.getTensorData(n) orelse continue;
        if (data.len == 0) continue;
        // Prefer embedding-like names
        if (std.mem.indexOf(u8, n, "token_embd") != null or std.mem.indexOf(u8, n, "embd") != null) {
            chosen_name = n;
            chosen_data = data;
            break;
        }
        if (chosen_name == null) {
            chosen_name = n;
            chosen_data = data;
        }
    }

    if (chosen_name == null or chosen_data == null) {
        return .{
            .name = try allocator.dupe(u8, ""),
            .sum_f32 = 0,
            .count = 0,
            .fingerprint = 0,
        };
    }

    const data = chosen_data.?;
    var sum: f64 = 0;
    var count: u32 = 0;
    // Interpret as F32 stream (fixture and many embd tables are F32; still valid byte probe if not)
    const max_floats = @min(data.len / 4, 256);
    var i: usize = 0;
    while (i < max_floats) : (i += 1) {
        const bits = std.mem.readInt(u32, data[i * 4 ..][0..4], .little);
        const f: f32 = @bitCast(bits);
        // skip non-finite so Q types still yield a defined sum when bitcast
        if (!std.math.isNan(f) and !std.math.isInf(f)) {
            sum += @floatCast(f);
            count += 1;
        }
    }

    var fp: u64 = 0xcbf29ce484222325;
    const nbytes = @min(data.len, 4096);
    for (data[0..nbytes]) |b| {
        fp ^= b;
        fp *%= 0x100000001b3;
    }

    return .{
        .name = try allocator.dupe(u8, chosen_name.?),
        .sum_f32 = sum,
        .count = count,
        .fingerprint = fp,
    };
}

test "model host ollama register slot" {
    const a = std.testing.allocator;
    var host = ModelHost.init(a);
    defer host.deinit();
    const id = try host.register(.ollama, "qwen3.5:0.8B");
    try std.testing.expectEqual(@as(usize, 0), id);
    try std.testing.expectEqual(@as(usize, 1), host.count());
}

test "model host GGUF weight probe at register (fixture)" {
    const a = std.testing.allocator;
    var host = ModelHost.init(a);
    defer host.deinit();

    // Path relative to package cwd when tests run from project root
    const path = "src/models/fixtures/tiny.gguf";
    const id = try host.register(.gguf, path);
    try std.testing.expect(host.slots[id].?.weight_probe_count > 0);
    // Fixture floats: 0.5 + 1.5 + ... + 31.5 = 512.0
    try std.testing.expect(@abs(host.slots[id].?.weight_probe_sum_f32 - 512.0) < 0.01);
}

test "model host GGUF full forward infer (fixture)" {
    const a = std.testing.allocator;
    var host = ModelHost.init(a);
    defer host.deinit();

    const path = "src/models/fixtures/tiny.gguf";
    const id = try host.register(.gguf, path);

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const out = try host.infer(a, threaded.io(), id, "hello");
    defer a.free(out);
    // Real forward path — not probe-only
    try std.testing.expect(std.mem.indexOf(u8, out, "status=forward_ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "generated=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "top_logit=") != null or std.mem.indexOf(u8, out, "generated_tokens=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "weight_probe_sum_f32=512") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "token_embd.weight") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "forward_backend=inproc_f32") != null);
}

test "model host ollama infer via inject boundary" {
    const a = std.testing.allocator;
    var host = ModelHost.init(a);
    defer host.deinit();
    const id = try host.register(.ollama, "any-tag");
    test_ollama_reply = "SECONDARY_OK_42";
    defer test_ollama_reply = null;

    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const out = try host.infer(a, threaded.io(), id, "ping");
    defer a.free(out);
    try std.testing.expectEqualStrings("SECONDARY_OK_42", out);
}
