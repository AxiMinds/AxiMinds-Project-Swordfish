// Multi-model host for axiNC MVP.
// Secondary models: Ollama tags (live inference) or GGUF files (metadata + probe via zllama parser).
//
// SOURCES:
//   - aximinds-zllama/src/gguf/parser.zig (GGUF load)
//   - AxiMinds-Claude-Remote ollama orchestrator (chat)
//   - AxiMinds-Discovery multi-model roles

const std = @import("std");
const ollama = @import("../bridge/ollama_client.zig");
const gguf_parser = @import("../gguf/parser.zig");
const gguf_fmt = @import("../gguf/format.zig");

pub const ModelKind = enum { ollama, gguf };

pub const ModelSlot = struct {
    kind: ModelKind,
    /// Ollama tag or filesystem path (owned)
    name: []u8,
    /// Optional architecture string from GGUF
    architecture: []u8 = &[_]u8{},
    context_length: u32 = 0,
    embedding_length: u32 = 0,
    block_count: u32 = 0,
    tensor_count: u64 = 0,
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
            // Real GGUF header parse (zllama port)
            var file = try gguf_parser.loadFromFile(self.allocator, name_or_path);
            defer file.deinit();
            slot.tensor_count = file.header.tensor_count;
            if (file.getMetadataString(gguf_fmt.MetadataKeys.general_architecture)) |arch| {
                slot.architecture = try self.allocator.dupe(u8, arch);
            } else if (file.getMetadataString("general.architecture")) |arch| {
                slot.architecture = try self.allocator.dupe(u8, arch);
            }
            // Try both llama.* and qwen2.* / qwen3.* keys
            slot.context_length = @intCast(file.getMetadataInt(gguf_fmt.MetadataKeys.context_length) orelse
                file.getMetadataInt(gguf_fmt.MetadataKeys.qwen2_context_length) orelse
                file.getMetadataInt("qwen3.context_length") orelse 0);
            slot.embedding_length = @intCast(file.getMetadataInt(gguf_fmt.MetadataKeys.embedding_length) orelse
                file.getMetadataInt(gguf_fmt.MetadataKeys.qwen2_embedding_length) orelse
                file.getMetadataInt("qwen3.embedding_length") orelse 0);
            slot.block_count = @intCast(file.getMetadataInt(gguf_fmt.MetadataKeys.block_count) orelse
                file.getMetadataInt(gguf_fmt.MetadataKeys.qwen2_block_count) orelse
                file.getMetadataInt("qwen3.block_count") orelse 0);
            slot.loaded = true;
        } else {
            // Ollama: mark registered; live check on first infer
            slot.loaded = true;
        }

        const id = self.n;
        self.slots[id] = slot;
        self.n += 1;
        return id;
    }

    /// Infer on slot. Ollama → real chat; GGUF → structured metadata response (full decode is next-phase).
    pub fn infer(self: *ModelHost, allocator: std.mem.Allocator, io: std.Io, slot_id: usize, prompt: []const u8) ![]u8 {
        if (slot_id >= self.n) return error.InvalidSlot;
        const slot = self.slots[slot_id] orelse return error.InvalidSlot;

        switch (slot.kind) {
            .ollama => {
                const cfg = ollama.Config{ .model = slot.name };
                const r = try ollama.chat(allocator, io, cfg, prompt, "You are a secondary model hosted by axiNC ModelHost.");
                if (!r.ok) {
                    defer r.deinit(allocator);
                    return error.InferFailed;
                }
                // transfer ownership
                return r.text;
            },
            .gguf => {
                // MVP: return real parsed metadata + prompt acknowledgment (weights path ready via getTensorData)
                return try std.fmt.allocPrint(allocator,
                    \\[axiNC GGUF model slot={d} path={s}]
                    \\architecture={s} tensors={d} ctx={d} emb={d} blocks={d}
                    \\prompt_received={d} bytes
                    \\status=metadata_ready (full forward pass hooks to zllama Transformer next)
                , .{
                    slot_id,
                    slot.name,
                    if (slot.architecture.len > 0) slot.architecture else "unknown",
                    slot.tensor_count,
                    slot.context_length,
                    slot.embedding_length,
                    slot.block_count,
                    prompt.len,
                });
            },
        }
    }
};

test "model host ollama register slot" {
    const a = std.testing.allocator;
    var host = ModelHost.init(a);
    defer host.deinit();
    const id = try host.register(.ollama, "qwen3.5:0.8B");
    try std.testing.expectEqual(@as(usize, 0), id);
    try std.testing.expectEqual(@as(usize, 1), host.count());
}
