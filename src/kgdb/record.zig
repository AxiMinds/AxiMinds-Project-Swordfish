//! Core record types stored in the Substrate.
const std = @import("std");
const address = @import("address.zig");

pub const Relation = enum(u32) {
    SEMANTIC_NEIGHBOR = 1,
    ATTENTION_COACTIVATION = 2,
    FFN_CONCEPT_MAP = 3,
    FFN_OUTPUT_INFLUENCE = 4,
    UNEMBED_ALIGNMENT = 5,
    FILE_CONTAINS_LINE = 100,
    LINE_REFERENCES = 101,
    EMAIL_FROM = 200,
    EMAIL_TO = 201,
    EMAIL_REFERENCES = 202,
    CONVERSATION_TURN = 300,
    CONVERSATION_TOPIC = 301,
    USER_DEFINED_START = 10000,
};

pub const Edge = extern struct {
    from: address.Address,
    to: address.Address,
    relation: u32, // Relation enum as u32 for stable binary layout
    weight: f32,
    timestamp_ns: i64,
    flags: u32, // reserved: bit 0 = tombstone, bit 1 = verified, bit 2 = synthetic

    pub const TOMBSTONE_FLAG: u32 = 1 << 0;
    pub const VERIFIED_FLAG: u32 = 1 << 1;
    pub const SYNTHETIC_FLAG: u32 = 1 << 2;

    pub fn isTombstone(self: *const Edge) bool {
        return (self.flags & TOMBSTONE_FLAG) != 0;
    }

    /// Compute decayed weight using exponential decay: weight * exp(-lambda * age_seconds)
    /// lambda=0 means no decay (use raw weight as priority/score).
    /// For SPZA fuzzy, caller can combine with angular score.
    pub fn effectiveWeight(self: Edge, now_ns: i64, lambda: f32) f32 {
        if (self.timestamp_ns <= 0 or lambda <= 0.0) return self.weight;
        const age_ns = now_ns - self.timestamp_ns;
        if (age_ns <= 0) return self.weight;
        const age_s: f32 = @as(f32, @floatFromInt(age_ns)) / 1_000_000_000.0;
        const decayed = self.weight * @exp(-lambda * age_s);
        return if (decayed > 0.0) decayed else 0.0;
    }
};

comptime {
    // Ensure Edge is 32+32+4+4+8+4 = 84 bytes (unpacked). Align to 96 for cache.
    std.debug.assert(@sizeOf(Edge) >= 84);
}

pub const Entity = struct {
    addr: address.Address,
    type_tag: u32,
    name: []const u8,
    attributes_json: []const u8,
};

pub const Fact = struct {
    addr: address.Address,
    subject: address.Address,
    predicate: u32,
    object: address.Address,
    confidence: f32,
    source_ref: address.Address, // points to ingestion source record
};

/// File-level record produced by FileIndexer.
pub const FileRecord = struct {
    addr: address.Address,
    sha256: [32]u8,
    path: []const u8,
    size_bytes: u64,
    mtime_ns: i64,
    content_type: ContentType,
    znorm_signature: [64]f32, // file-level embedding (e.g., mean-pooled)
    num_lines: u32,
};

pub const ContentType = enum(u16) {
    unknown = 0,
    text_plain = 1,
    text_markdown = 2,
    text_code = 3,
    text_json = 4,
    text_html = 5,
    text_csv = 6,
    text_log = 7,
    binary_other = 100,
    image = 200,
    audio = 300,
    video = 400,
    archive = 500,
};

/// Line-level record produced by FileIndexer line-splitting phase.
pub const LineRecord = struct {
    addr: address.Address,
    parent_file: address.Address,
    line_idx: u32,
    sha256: [32]u8,
    znorm_signature: [64]f32,
    byte_offset: u64,
    byte_length: u32,
};

test "edge size sanity" {
    try std.testing.expect(@sizeOf(Edge) >= 84);
}

test "tombstone flag check" {
    var e: Edge = std.mem.zeroes(Edge);
    try std.testing.expect(!e.isTombstone());
    e.flags |= Edge.TOMBSTONE_FLAG;
    try std.testing.expect(e.isTombstone());
}
