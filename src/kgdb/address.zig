//! AXION-32D addressing: 32-byte addresses across 2^256 space.
//! Formerly STRIX-32D (renamed 2026-04-22 per aximinds-mcp decision #9).
//!
//! Layout:
//!   [0..4]   u32  model_id_hash / user_id_hash     — source attribution
//!   [4..6]   u16  source_layer / corpus_layer      — which model layer or corpus chunk
//!   [6..7]   u8   provenance                       — how this record was created
//!   [7..8]   u8   version                          — schema version for migration
//!   [8..12]  u32  primary_id                       — token_id, line_id, file_id, etc.
//!   [12..32] [20]u8 signature                      — SPZA angular signature (future)
const std = @import("std");

pub const ADDRESS_BYTES: usize = 32;
pub const Address = [ADDRESS_BYTES]u8;

pub const Provenance = enum(u8) {
    unknown = 0,
    layer_embedding = 1,
    layer_attention = 2,
    layer_ffn_up = 3,
    layer_ffn_down = 4,
    layer_unembed = 5,
    user_ingested_file = 16,
    user_ingested_line = 17,
    user_ingested_conversation = 18,
    user_ingested_email = 19,
    user_query_result = 32,
    synthesized_by_mneme = 48,
    vvv_gated = 64,
    custom = 255,
};

pub const VERSION_CURRENT: u8 = 1;

pub const AxionSpec = struct {
    model_id_hash: u32 = 0,
    source_layer: u16 = 0,
    provenance: Provenance = .unknown,
    version: u8 = VERSION_CURRENT,
    primary_id: u32 = 0,
    signature: [20]u8 = @splat(0),
};

/// Pack an AxionSpec into a 32-byte address.
pub fn axion(spec: AxionSpec) Address {
    var addr: Address = @splat(0);
    std.mem.writeInt(u32, addr[0..4], spec.model_id_hash, .little);
    std.mem.writeInt(u16, addr[4..6], spec.source_layer, .little);
    addr[6] = @intFromEnum(spec.provenance);
    addr[7] = spec.version;
    std.mem.writeInt(u32, addr[8..12], spec.primary_id, .little);
    @memcpy(addr[12..32], &spec.signature);
    return addr;
}

/// Unpack a 32-byte address into an AxionSpec.
pub fn unpack(addr: Address) AxionSpec {
    var sig: [20]u8 = undefined;
    @memcpy(&sig, addr[12..32]);
    return .{
        .model_id_hash = std.mem.readInt(u32, addr[0..4], .little),
        .source_layer = std.mem.readInt(u16, addr[4..6], .little),
        .provenance = @enumFromInt(addr[6]),
        .version = addr[7],
        .primary_id = std.mem.readInt(u32, addr[8..12], .little),
        .signature = sig,
    };
}

/// Compute the "hot partition key" — first 8 bytes, which groups records
/// by (model/user, layer, provenance). Used to colocate related records.
pub fn hotPartitionKey(addr: Address) u64 {
    return std.mem.readInt(u64, addr[0..8], .little);
}

/// Lexicographic comparator. Useful for sorted containers and B-trees.
pub fn compare(a: Address, b: Address) std.math.Order {
    return std.mem.order(u8, &a, &b);
}

/// Hash address for HashMap usage. Uses Wyhash on all 32 bytes.
pub fn hash(addr: Address) u64 {
    return std.hash.Wyhash.hash(0xa10c10d5_e1e574e6, &addr);
}

pub const Context = struct {
    pub fn hash(_: Context, key: Address) u64 {
        return @This().hashFn(key);
    }
    pub fn eql(_: Context, a: Address, b: Address) bool {
        return std.mem.eql(u8, &a, &b);
    }
    fn hashFn(key: Address) u64 {
        return std.hash.Wyhash.hash(0xa10c10d5_e1e574e6, &key);
    }
};

test "axion pack/unpack round trip" {
    var sig: [20]u8 = undefined;
    for (&sig, 0..) |*b, i| b.* = @intCast(i);

    const spec = AxionSpec{
        .model_id_hash = 0xDEADBEEF,
        .source_layer = 42,
        .provenance = .layer_embedding,
        .version = VERSION_CURRENT,
        .primary_id = 151000,
        .signature = sig,
    };
    const addr = axion(spec);
    const back = unpack(addr);

    try std.testing.expectEqual(spec.model_id_hash, back.model_id_hash);
    try std.testing.expectEqual(spec.source_layer, back.source_layer);
    try std.testing.expectEqual(spec.provenance, back.provenance);
    try std.testing.expectEqual(spec.version, back.version);
    try std.testing.expectEqual(spec.primary_id, back.primary_id);
    try std.testing.expectEqualSlices(u8, &spec.signature, &back.signature);
}

test "hot partition key groups by prefix" {
    const a = axion(.{ .model_id_hash = 1, .source_layer = 0, .provenance = .layer_embedding, .primary_id = 100 });
    const b = axion(.{ .model_id_hash = 1, .source_layer = 0, .provenance = .layer_embedding, .primary_id = 200 });
    const c = axion(.{ .model_id_hash = 2, .source_layer = 0, .provenance = .layer_embedding, .primary_id = 100 });

    try std.testing.expectEqual(hotPartitionKey(a), hotPartitionKey(b));
    try std.testing.expect(hotPartitionKey(a) != hotPartitionKey(c));
}

test "compare orders lexicographically" {
    const a = axion(.{ .model_id_hash = 1, .primary_id = 100 });
    const b = axion(.{ .model_id_hash = 1, .primary_id = 200 });
    try std.testing.expect(compare(a, b) == .lt);
    try std.testing.expect(compare(b, a) == .gt);
    try std.testing.expect(compare(a, a) == .eq);
}
