// /home/jdare/AI/development/AxiMinds-zllama/src/svc4.zig
// SVC4 (Symbolic Vocabulary Compression, 4-byte) module for AxiMinds-zllama.
// Dict reader (mmap + BLAKE3), VQ tags, 20k namespace, GGUF remap via aximinds.svc4.* keys + provenance.
// Ported concepts from AxiMinds-VocabWalk/src/svc4_dict_format.zig + AxiMinds-SVC4-llama-cpp/encoder/svc4_dict_reader.py + SVC4_SPEC_v1_0_0.md (via gh).
// Vocab-focused for tokenizer / embed remap + pre-FFN. Weight-phrase VQ is separate phase.
// Modules kept strictly separate under src/. Prepares for single-binary relink (imported in main.zig).
// All paths absolute; order-of-operations critical for parse/remap integrity.
// No bare filenames; first-line path comment.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// SVC4 Namespace (20k x 20k restricted Chinese-symbol) per SPEC §3
// ============================================================================

pub const SVC4_N: u32 = 20_000; // base symbols per column
pub const SVC4_R: u32 = 1_000; // reserved first-column prefix symbols
pub const SVC4_A: u32 = SVC4_N - SVC4_R; // 19_000 active first-column
pub const SVC4_ACTIVE_NAMESPACE: u64 = @as(u64, SVC4_A) * @as(u64, SVC4_N); // 380_000_000

/// Pack active_index (0-based in active space) into 32-bit SVC4 code.
/// first_symbol = R + (i / N), second = i % N
pub fn activeIndexToSvc4(active_index: u32) u32 {
    const first_symbol: u32 = SVC4_R + (active_index / SVC4_N);
    const second_symbol: u32 = active_index % SVC4_N;
    return (first_symbol << 16) | second_symbol;
}

/// Unpack SVC4 code to active_index. Returns null for reserved range.
pub fn svc4ToActiveIndex(code: u32) ?u32 {
    const first_symbol: u32 = code >> 16;
    const second_symbol: u32 = code & 0xFFFF;
    if (first_symbol < SVC4_R) return null;
    return (first_symbol - SVC4_R) * SVC4_N + second_symbol;
}

// ============================================================================
// Entry Tags (for dict reader + VQ) - ported/adapted
// ============================================================================

pub const Tag = enum(u8) {
    padding = 0,
    vocab = 1, // Phase A: vocab token
    weight_phrase = 2, // Phase B: VQ weight phrase (future full decode in kernels)
    nested = 3,
    vector_ref = 4,
    tombstone = 255,
};

pub const CanonicalKind = enum(u8) {
    none = 0,
    leading_sentencepiece = 1, // ▁
    leading_gpt_space = 2, // Ġ
    leading_ascii_space = 3,
    leading_tab = 4,
    leading_newline = 5,
};

pub const CentroidDtype = enum(u8) {
    bf16 = 0,
    fp16 = 1,
    fp32 = 2,

    pub fn byteSize(self: CentroidDtype) u8 {
        return switch (self) {
            .bf16, .fp16 => 2,
            .fp32 => 4,
        };
    }
};

pub const BlockVariant = enum(u8) {
    a_code_scale = 0, // 6B / phrase
    b_code_scale_delta = 1, // 7B / phrase (recommended)
    c_code_only = 2, // 4B + shared tile scale
};

// ============================================================================
// GGUF aximinds.svc4.* Keys + Provenance (per task + correction note)
// ============================================================================

pub const GGUF_SVC4_PREFIX: []const u8 = "aximinds.svc4.";

pub const Svc4GGUFKeys = struct {
    pub const version = "aximinds.svc4.version";
    pub const dict_blake3 = "aximinds.svc4.dict_blake3";
    pub const provenance_json = "aximinds.svc4.provenance";
    pub const vocab_remapped = "aximinds.svc4.vocab_remapped"; // bool or u32 count
    pub const namespace_capacity = "aximinds.svc4.namespace_capacity";
    pub const active_count = "aximinds.svc4.active_count";
};

pub const Svc4Provenance = struct {
    dict_version: []const u8,
    build_timestamp: []const u8,
    source_model_count: u32,
    source_models: []const []const u8, // caller owns or duped
    blake3: [32]u8,
    notes: []const u8,

    pub fn deinit(self: *Svc4Provenance, allocator: Allocator) void {
        allocator.free(self.dict_version);
        allocator.free(self.build_timestamp);
        for (self.source_models) |m| allocator.free(m);
        allocator.free(self.source_models);
        allocator.free(self.notes);
    }
};

pub const Svc4GGUFMetadata = struct {
    enabled: bool = false,
    version: u32 = 0,
    dict_blake3: ?[32]u8 = null,
    dict_blake3_hex: ?[]const u8 = null,
    provenance: ?Svc4Provenance = null,
    vocab_remapped: bool = false,
    namespace_capacity: u64 = SVC4_ACTIVE_NAMESPACE,
    active_count: u64 = 0,

    pub fn deinit(self: *Svc4GGUFMetadata, allocator: Allocator) void {
        if (self.dict_blake3_hex) |h| allocator.free(h);
        if (self.provenance) |*p| p.deinit(allocator);
    }
};

// Extract aximinds.svc4.* keys + provenance from any GGUF metadata hashmap.
// Returns populated struct (enabled=true) if any keys present. Safe no-op otherwise.
pub fn extractSvc4GGUFMetadata(gguf: *const @import("gguf/parser.zig").GGUFFile, allocator: Allocator) !Svc4GGUFMetadata {
    var meta: Svc4GGUFMetadata = .{};

    // Check for presence of any aximinds.svc4. key
    var iter = gguf.metadata.iterator();
    while (iter.next()) |entry| {
        if (std.mem.startsWith(u8, entry.key_ptr.*, GGUF_SVC4_PREFIX)) {
            meta.enabled = true;
            break;
        }
    }
    if (!meta.enabled) return meta;

    // Version
    if (gguf.getMetadataInt(Svc4GGUFKeys.version)) |v| {
        meta.version = @intCast(v);
    }

    // BLAKE3 (stored as string hex or bytes? prefer string for GGUF portability)
    if (gguf.getMetadataString(Svc4GGUFKeys.dict_blake3)) |hex| {
        if (hex.len >= 64) {
            var b: [32]u8 = undefined;
            var ok = true;
            for (0..32) |i| {
                const hi = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 1], 16) catch {
                    ok = false;
                    break;
                };
                const lo = std.fmt.parseInt(u8, hex[i * 2 + 1 .. i * 2 + 2], 16) catch {
                    ok = false;
                    break;
                };
                b[i] = (hi << 4) | lo;
            }
            if (ok) meta.dict_blake3 = b;
        }
        meta.dict_blake3_hex = try allocator.dupe(u8, hex);
    }

    // Namespace info
    if (gguf.getMetadataInt(Svc4GGUFKeys.namespace_capacity)) |v| {
        meta.namespace_capacity = @intCast(v);
    }
    if (gguf.getMetadataInt(Svc4GGUFKeys.active_count)) |v| {
        meta.active_count = @intCast(v);
    }

    // Vocab remapped flag
    if (gguf.getMetadataInt(Svc4GGUFKeys.vocab_remapped)) |v| {
        meta.vocab_remapped = (v != 0);
    } else if (gguf.getMetadataString(Svc4GGUFKeys.vocab_remapped)) |s| {
        meta.vocab_remapped = std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1");
    }

    // Provenance (JSON string in metadata)
    if (gguf.getMetadataString(Svc4GGUFKeys.provenance_json)) |pjson| {
        // Minimal parse for key fields (production would use full json parser)
        var prov: Svc4Provenance = .{
            .dict_version = try allocator.dupe(u8, "unknown"),
            .build_timestamp = try allocator.dupe(u8, "unknown"),
            .source_model_count = 0,
            .source_models = &.{},
            .blake3 = meta.dict_blake3 orelse .{0} ** 32,
            .notes = try allocator.dupe(u8, pjson),
        };
        // Best-effort extraction from json-like (no full dep)
        if (std.mem.indexOf(u8, pjson, "\"version\":")) |idx| {
            // simplistic slice; real impl would parse properly
            const start = idx + 10;
            if (std.mem.indexOf(u8, pjson[start..], "\"")) |end| {
                allocator.free(prov.dict_version);
                prov.dict_version = try allocator.dupe(u8, pjson[start .. start + end]);
            }
        }
        meta.provenance = prov;
    }

    return meta;
}

// ============================================================================
// Simple Vocab Remapper (for GGUF vocab integration + tokenizer use)
// Applies active-namespace remap when vocab_remapped. Identity otherwise.
// Used "for vocab if possible" at load / encode time.
// ============================================================================

pub const VocabRemapper = struct {
    allocator: Allocator,
    info: Svc4GGUFMetadata,
    // Optional: in-memory map original_id -> svc4_code for non-linear remaps (loaded from GGUF array if present)
    id_map: ?std.AutoHashMap(u32, u32) = null,

    pub fn init(allocator: Allocator, info: Svc4GGUFMetadata) VocabRemapper {
        return .{
            .allocator = allocator,
            .info = info,
        };
    }

    pub fn deinit(self: *VocabRemapper) void {
        if (self.id_map) |*m| m.deinit();
        self.info.deinit(self.allocator);
    }

    /// Core remap: for vocab-remapped models, token id from tokenizer becomes svc4 code.
    /// If linear active-index mapping, use formula. Else lookup.
    pub fn remap(self: *const VocabRemapper, original_token_id: u32) u32 {
        if (!self.info.enabled or !self.info.vocab_remapped) return original_token_id;
        if (self.id_map) |m| {
            return m.get(original_token_id) orelse original_token_id;
        }
        // Default: treat original id as active index in the surveyed vocab
        return activeIndexToSvc4(original_token_id);
    }

    /// Reverse for decode (svc4 code -> display id or original). For now return active or identity.
    pub fn unmap(self: *const VocabRemapper, svc4_code: u32) u32 {
        if (!self.info.enabled or !self.info.vocab_remapped) return svc4_code;
        if (self.id_map) |m| {
            var it = m.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* == svc4_code) return kv.key_ptr.*;
            }
        }
        return svc4ToActiveIndex(svc4_code) orelse svc4_code;
    }
};

// ============================================================================
// Dict Reader (port of core from VocabWalk svc4_dict_format + py reader)
// Supports external .axi dict (mmap, BLAKE3 verified) for full provenance/dict use.
// Vocab-only iterator for now; weight-phrase VQ stubs included for completeness.
// ============================================================================

pub const FILE_MAGIC: [8]u8 = .{ 'A', 'X', 'S', 'C', '4', 'D', 'I', 'C' };
pub const HEADER_BYTES: usize = 128;
pub const ENTRY_HEADER_BYTES: usize = 12;
pub const INDEX_ENTRY_BYTES: usize = 16;

pub const DictReader = struct {
    allocator: Allocator,
    mapped: []align(std.heap.page_size_min) const u8,
    header: Header,
    manifest_json: []const u8,
    fd: std.posix.fd_t,
    closed: bool = false,

    pub const Header = struct {
        magic: [8]u8,
        version_major: u16,
        version_minor: u16,
        version_patch: u16,
        body_blake3: [32]u8,
        manifest_offset: u64,
        manifest_length: u64,
        entry_table_offset: u64,
        entry_table_length: u64,
        index_offset: u64,
        index_length: u64,
        entry_count: u64,
        namespace_capacity: u64,
        flags: u64,
    };

    pub const Entry = struct {
        tag: Tag,
        flags: u8,
        svc4_code: u32,
        payload: []const u8,
    };

    pub fn open(allocator: Allocator, path: []const u8) !DictReader {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const rc = std.os.linux.open(path_z.ptr, std.os.linux.O{}, 0);
        if (rc < 0) return error.FileOpenFailed;
        const fd: i32 = @intCast(rc);
        errdefer _ = std.os.linux.close(fd);

        const size_rc = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.END);
        if (size_rc < 0) {
            _ = std.os.linux.close(fd);
            return error.SeekFailed;
        }
        const size: usize = @intCast(size_rc);
        _ = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.SET);

        const mapped = try std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        errdefer std.posix.munmap(mapped);

        const header = try parseHeader(mapped[0..HEADER_BYTES]);

        // BLAKE3 verify body
        const body_start: usize = HEADER_BYTES;
        const body_end: usize = @intCast(header.index_offset + header.index_length);
        if (body_end > mapped.len) return error.FileTruncated;

        var blake = std.crypto.hash.Blake3.init(.{});
        blake.update(mapped[body_start..body_end]);
        var computed: [32]u8 = undefined;
        blake.final(&computed);
        if (!std.mem.eql(u8, &computed, &header.body_blake3)) return error.Blake3Mismatch;

        const mstart: usize = @intCast(header.manifest_offset);
        const mend: usize = mstart + @as(usize, @intCast(header.manifest_length));
        const manifest_json = mapped[mstart..mend];

        return .{
            .allocator = allocator,
            .mapped = mapped,
            .header = header,
            .manifest_json = manifest_json,
            .fd = fd,
        };
    }

    fn parseHeader(buf: []const u8) !Header {
        if (buf.len < HEADER_BYTES) return error.HeaderTruncated;
        if (!std.mem.eql(u8, buf[0..8], &FILE_MAGIC)) return error.BadMagic;
        return .{
            .magic = buf[0..8].*,
            .version_major = std.mem.readInt(u16, buf[8..10], .little),
            .version_minor = std.mem.readInt(u16, buf[10..12], .little),
            .version_patch = std.mem.readInt(u16, buf[12..14], .little),
            .body_blake3 = buf[16..48].*,
            .manifest_offset = std.mem.readInt(u64, buf[48..56], .little),
            .manifest_length = std.mem.readInt(u64, buf[56..64], .little),
            .entry_table_offset = std.mem.readInt(u64, buf[64..72], .little),
            .entry_table_length = std.mem.readInt(u64, buf[72..80], .little),
            .index_offset = std.mem.readInt(u64, buf[80..88], .little),
            .index_length = std.mem.readInt(u64, buf[88..96], .little),
            .entry_count = std.mem.readInt(u64, buf[96..104], .little),
            .namespace_capacity = std.mem.readInt(u64, buf[104..112], .little),
            .flags = std.mem.readInt(u64, buf[112..120], .little),
        };
    }

    pub fn close(self: *DictReader) void {
        if (self.closed) return;
        std.posix.munmap(self.mapped);
        _ = std.os.linux.close(self.fd);
        self.closed = true;
    }

    pub fn deinit(self: *DictReader) void {
        self.close();
    }

    /// Binary search index for exact code.
    pub fn lookup(self: *const DictReader, code: u32) ?Entry {
        const n: usize = @intCast(self.header.entry_count);
        if (n == 0) return null;
        const idx_base: usize = @intCast(self.header.index_offset);
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const off = idx_base + mid * INDEX_ENTRY_BYTES;
            const mid_code = std.mem.readInt(u32, self.mapped[off..][0..4], .little);
            if (mid_code == code) {
                const entry_off = std.mem.readInt(u64, self.mapped[off + 8 ..][0..8], .little);
                return self.parseEntryAt(@intCast(entry_off));
            }
            if (mid_code < code) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn parseEntryAt(self: *const DictReader, off: usize) Entry {
        const tag: Tag = @enumFromInt(self.mapped[off]);
        const flags: u8 = self.mapped[off + 1];
        const code = std.mem.readInt(u32, self.mapped[off + 4 ..][0..4], .little);
        const plen = std.mem.readInt(u32, self.mapped[off + 8 ..][0..4], .little);
        const pstart = off + ENTRY_HEADER_BYTES;
        return .{
            .tag = tag,
            .flags = flags,
            .svc4_code = code,
            .payload = self.mapped[pstart .. pstart + plen],
        };
    }

    pub fn iterVocabEntries(self: *const DictReader, allocator: Allocator) !std.ArrayList(struct { code: u32, token_bytes: []const u8, kind: CanonicalKind }) {
        var list: std.ArrayList(struct { code: u32, token_bytes: []const u8, kind: CanonicalKind }) = .empty;
        const off0 = self.header.entry_table_offset;
        const end = off0 + self.header.entry_table_length;
        var off = off0;
        while (off < end) {
            const tag = @as(Tag, @enumFromInt(self.mapped[off]));
            if (tag != .vocab) {
                const plen = std.mem.readInt(u32, self.mapped[off + 8 ..][0..4], .little);
                off += ENTRY_HEADER_BYTES + plen;
                continue;
            }
            const code = std.mem.readInt(u32, self.mapped[off + 4 ..][0..4], .little);
            const plen = std.mem.readInt(u32, self.mapped[off + 8 ..][0..4], .little);
            const pstart = off + ENTRY_HEADER_BYTES;
            const kind: CanonicalKind = @enumFromInt(self.mapped[pstart]);
            const tlen = std.mem.readInt(u16, self.mapped[pstart + 2 ..][0..2], .little);
            const tbytes = self.mapped[pstart + 4 .. pstart + 4 + tlen];
            const duped = try allocator.dupe(u8, tbytes);
            try list.append(allocator, .{ .code = code, .token_bytes = duped, .kind = kind });
            off += ENTRY_HEADER_BYTES + plen;
        }
        return list;
    }
};

// ============================================================================
// Public integration helpers (for tokenizer, main, transformer)
// ============================================================================

pub fn applyRemap(remapper: *const VocabRemapper, tokens: []u32) void {
    for (tokens) |*t| {
        t.* = remapper.remap(t.*);
    }
}

pub fn buildRemapperFromGGUF(allocator: Allocator, gguf: *const @import("gguf/parser.zig").GGUFFile) !VocabRemapper {
    const info = try extractSvc4GGUFMetadata(gguf, allocator);
    const rem = VocabRemapper.init(allocator, info);
    // TODO: if GGUF embeds explicit remap array under aximinds.svc4.* , populate rem.id_map here
    // For now linear active index is sufficient for Phase A vocab remap demo.
    return rem;
}

// VQ decode stub (for future fused kernel use; does not expand full tensor)
pub fn vqDecodePhrase(code: u32, scale: u16, centroid: []const u8, out: []f16) void {
    _ = code;
    _ = scale;
    _ = centroid;
    // Placeholder: in real, lookup dict + scale * centroid (bf16) -> f16 tile. Separate from vocab path.
    @memset(out, 0);
}
