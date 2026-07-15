// AxiMinds-zllama/src/gguf/parser.zig
// GGUF File Parser - Loads model weights from GGUF format
//
// Parses GGUF files used by llama.cpp and Ollama for LLM weights storage.
// Supports version 3 GGUF files with various quantization formats.
//
// Ported/enhanced autonomously from AxiMinds/aximinds-zllama for Swordfish real-model support.
// Copyright (c) 2024-2026 AxiMinds Corporation. All Rights Reserved.

const std = @import("std");
const fmt = @import("format.zig");
const Allocator = std.mem.Allocator;

// SVC4 integration (from agent's completed port)
const svc4 = @import("../svc4.zig");

pub const ParseError = error{
    InvalidMagic,
    UnsupportedVersion,
    InvalidMetadata,
    InvalidTensor,
    UnexpectedEndOfFile,
    InvalidString,
    InvalidArray,
    OutOfMemory,
    FileNotFound,
    ReadError,
};

// ============================================================================
// Parsed GGUF File
// ============================================================================

pub const GGUFFile = struct {
    allocator: Allocator,
    header: fmt.GGUFHeader,
    metadata: std.StringHashMap(MetadataValue),
    tensors: std.StringHashMap(TensorInfo),
    tensor_data_offset: u64,
    file_data: []align(4096) const u8,

    pub fn deinit(self: *GGUFFile) void {
        var meta_iter = self.metadata.iterator();
        while (meta_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.metadata.deinit();

        var tensor_iter = self.tensors.iterator();
        while (tensor_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.tensors.deinit();

        self.allocator.free(self.file_data);
    }

    pub fn getMetadataString(self: *const GGUFFile, key: []const u8) ?[]const u8 {
        if (self.metadata.get(key)) |value| {
            return switch (value) {
                .String => |s| s,
                else => null,
            };
        }
        return null;
    }

    pub fn getMetadataInt(self: *const GGUFFile, key: []const u8) ?i64 {
        if (self.metadata.get(key)) |value| {
            return switch (value) {
                .UInt8 => |v| @intCast(v),
                .Int8 => |v| @intCast(v),
                .UInt16 => |v| @intCast(v),
                .Int16 => |v| @intCast(v),
                .UInt32 => |v| @intCast(v),
                .Int32 => |v| @intCast(v),
                .UInt64 => |v| @intCast(v),
                .Int64 => |v| v,
                else => null,
            };
        }
        return null;
    }

    pub fn getMetadataFloat(self: *const GGUFFile, key: []const u8) ?f64 {
        if (self.metadata.get(key)) |value| {
            return switch (value) {
                .Float32 => |v| @floatCast(v),
                .Float64 => |v| v,
                else => null,
            };
        }
        return null;
    }

    /// Helper for aximinds.svc4.* and other UINT32 arrays stored as raw data.
    pub fn getMetadataUInt32Array(self: *const GGUFFile, key: []const u8, allocator: Allocator) !?[]u32 {
        const val = self.metadata.get(key) orelse return null;
        if (val != .Array) return null;
        const arr = val.Array;
        if (arr.element_type != .UINT32) return null;
        const n = arr.len;
        const out = try allocator.alloc(u32, n);
        const data = arr.data;
        for (0..n) |i| {
            const off = i * 4;
            if (off + 4 > data.len) break;
            out[i] = std.mem.readInt(u32, data[off..][0..4], .little);
        }
        return out;
    }

    pub fn getTensorData(self: *const GGUFFile, name: []const u8) ?[]const u8 {
        if (self.tensors.get(name)) |info| {
            const start = self.tensor_data_offset + info.offset;
            const end = start + info.num_bytes;
            if (end <= self.file_data.len) {
                return self.file_data[start..end];
            }
        }
        return null;
    }
};

pub const MetadataValue = union(enum) {
    UInt8: u8,
    Int8: i8,
    UInt16: u16,
    Int16: i16,
    UInt32: u32,
    Int32: i32,
    Float32: f32,
    Bool: bool,
    String: []const u8,
    Array: ArrayValue,
    UInt64: u64,
    Int64: i64,
    Float64: f64,

    pub fn deinit(self: *MetadataValue, allocator: Allocator) void {
        switch (self.*) {
            .String => |s| allocator.free(s),
            .Array => |*a| a.deinit(allocator),
            else => {},
        }
    }
};

pub const ArrayValue = struct {
    element_type: fmt.GGUFType,
    data: []const u8,
    len: u64,

    pub fn deinit(self: *ArrayValue, allocator: Allocator) void {
        allocator.free(self.data);
    }
};

pub const TensorInfo = struct {
    name: []const u8,
    n_dims: u32,
    dims: [4]u64,
    tensor_type: fmt.GGMLType,
    offset: u64,
    num_elements: u64,
    num_bytes: u64,
};

// ============================================================================
// GGUF Parser
// ============================================================================

pub const Parser = struct {
    allocator: Allocator,
    data: []const u8,
    pos: usize,

    pub fn init(allocator: Allocator, data: []const u8) Parser {
        return .{
            .allocator = allocator,
            .data = data,
            .pos = 0,
        };
    }

    fn readBytes(self: *Parser, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) {
            return ParseError.UnexpectedEndOfFile;
        }
        const result = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return result;
    }

    fn readU8(self: *Parser) !u8 {
        const bytes = try self.readBytes(1);
        return bytes[0];
    }

    fn readI8(self: *Parser) !i8 {
        return @bitCast(try self.readU8());
    }

    fn readU16(self: *Parser) !u16 {
        const bytes = try self.readBytes(2);
        return std.mem.readInt(u16, bytes[0..2], .little);
    }

    fn readI16(self: *Parser) !i16 {
        return @bitCast(try self.readU16());
    }

    fn readU32(self: *Parser) !u32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    fn readI32(self: *Parser) !i32 {
        return @bitCast(try self.readU32());
    }

    fn readU64(self: *Parser) !u64 {
        const bytes = try self.readBytes(8);
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    fn readI64(self: *Parser) !i64 {
        return @bitCast(try self.readU64());
    }

    fn readF32(self: *Parser) !f32 {
        const bytes = try self.readBytes(4);
        return @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
    }

    fn readF64(self: *Parser) !f64 {
        const bytes = try self.readBytes(8);
        return @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
    }

    fn readString(self: *Parser) ![]const u8 {
        const len = try self.readU64();
        if (len > 100 * 1024 * 1024) {
            return ParseError.InvalidString;
        }
        const bytes = try self.readBytes(@intCast(len));
        const result = try self.allocator.dupe(u8, bytes);
        return result;
    }

    fn readHeader(self: *Parser) !fmt.GGUFHeader {
        const magic = try self.readU32();
        if (magic != fmt.GGUF_MAGIC) {
            return ParseError.InvalidMagic;
        }

        const version = try self.readU32();
        if (version != 3 and version != 2) {
            return ParseError.UnsupportedVersion;
        }

        const tensor_count = try self.readU64();
        const metadata_kv_count = try self.readU64();

        return .{
            .magic = magic,
            .version = version,
            .tensor_count = tensor_count,
            .metadata_kv_count = metadata_kv_count,
        };
    }

    fn readMetadataValue(self: *Parser, value_type: fmt.GGUFType) !MetadataValue {
        return switch (value_type) {
            .UINT8 => .{ .UInt8 = try self.readU8() },
            .INT8 => .{ .Int8 = try self.readI8() },
            .UINT16 => .{ .UInt16 = try self.readU16() },
            .INT16 => .{ .Int16 = try self.readI16() },
            .UINT32 => .{ .UInt32 = try self.readU32() },
            .INT32 => .{ .Int32 = try self.readI32() },
            .FLOAT32 => .{ .Float32 = try self.readF32() },
            .BOOL => .{ .Bool = (try self.readU8()) != 0 },
            .STRING => .{ .String = try self.readString() },
            .ARRAY => blk: {
                const element_type: fmt.GGUFType = @enumFromInt(try self.readU32());
                const len = try self.readU64();

                if (element_type == .STRING) {
                    const start_pos = self.pos;
                    var total_size: usize = 0;

                    for (0..len) |_| {
                        const str_len = try self.readU64();
                        total_size += 8 + str_len;
                        _ = try self.readBytes(@intCast(str_len));
                    }

                    const data_copy = try self.allocator.dupe(u8, self.data[start_pos .. start_pos + total_size]);

                    break :blk .{
                        .Array = .{
                            .element_type = element_type,
                            .data = data_copy,
                            .len = len,
                        },
                    };
                } else {
                    const element_size = getElementSize(element_type);
                    const total_size = len * element_size;
                    if (total_size > 500 * 1024 * 1024) {
                        return ParseError.InvalidArray;
                    }

                    const array_data = try self.readBytes(@intCast(total_size));
                    const data_copy = try self.allocator.dupe(u8, array_data);

                    break :blk .{
                        .Array = .{
                            .element_type = element_type,
                            .data = data_copy,
                            .len = len,
                        },
                    };
                }
            },
            .UINT64 => .{ .UInt64 = try self.readU64() },
            .INT64 => .{ .Int64 = try self.readI64() },
            .FLOAT64 => .{ .Float64 = try self.readF64() },
        };
    }

    fn readTensorInfo(self: *Parser) !TensorInfo {
        const name = try self.readString();
        const n_dims = try self.readU32();

        var dims: [4]u64 = .{ 1, 1, 1, 1 };
        for (0..n_dims) |i| {
            dims[i] = try self.readU64();
        }

        const tensor_type_raw = try self.readU32();
        const tensor_type: fmt.GGMLType = @enumFromInt(tensor_type_raw);
        const offset = try self.readU64();

        var num_elements: u64 = 1;
        for (0..n_dims) |i| {
            num_elements *= dims[i];
        }

        const block_size = tensor_type.blockSize();
        const type_size = tensor_type.typeSize();
        const num_bytes = (num_elements / block_size) * type_size;

        return .{
            .name = name,
            .n_dims = n_dims,
            .dims = dims,
            .tensor_type = tensor_type,
            .offset = offset,
            .num_elements = num_elements,
            .num_bytes = num_bytes,
        };
    }

    pub fn parse(self: *Parser) !GGUFFile {
        const header = try self.readHeader();

        var metadata = std.StringHashMap(MetadataValue).init(self.allocator);
        errdefer {
            var iter = metadata.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            metadata.deinit();
        }

        for (0..header.metadata_kv_count) |_| {
            const key = try self.readString();
            errdefer self.allocator.free(key);

            const value_type_raw = try self.readU32();
            const value_type: fmt.GGUFType = @enumFromInt(value_type_raw);

            var value = try self.readMetadataValue(value_type);
            errdefer value.deinit(self.allocator);

            try metadata.put(key, value);
        }

        var tensors = std.StringHashMap(TensorInfo).init(self.allocator);
        errdefer {
            var iter = tensors.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            tensors.deinit();
        }

        for (0..header.tensor_count) |_| {
            const info = try self.readTensorInfo();
            const key = try self.allocator.dupe(u8, info.name);
            self.allocator.free(info.name);

            try tensors.put(key, .{
                .name = key,
                .n_dims = info.n_dims,
                .dims = info.dims,
                .tensor_type = info.tensor_type,
                .offset = info.offset,
                .num_elements = info.num_elements,
                .num_bytes = info.num_bytes,
            });
        }

        const alignment: usize = 32;
        const aligned_pos = (self.pos + alignment - 1) & ~(alignment - 1);
        self.pos = aligned_pos;

        const tensor_data_offset = self.pos;

        const file_data = try self.allocator.alignedAlloc(u8, .fromByteUnits(4096), self.data.len);
        @memcpy(file_data, self.data);

        return .{
            .allocator = self.allocator,
            .header = header,
            .metadata = metadata,
            .tensors = tensors,
            .tensor_data_offset = tensor_data_offset,
            .file_data = file_data,
        };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn getElementSize(element_type: fmt.GGUFType) u64 {
    return switch (element_type) {
        .UINT8, .INT8, .BOOL => 1,
        .UINT16, .INT16 => 2,
        .UINT32, .INT32, .FLOAT32 => 4,
        .UINT64, .INT64, .FLOAT64 => 8,
        .STRING => 8,
        .ARRAY => 8,
    };
}

// ============================================================================
// File Loading (linux syscall compat for Zig 0.16)
// ============================================================================

pub fn loadFromFile(allocator: Allocator, path: []const u8) !GGUFFile {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return ParseError.FileNotFound;

    const flags: std.os.linux.O = .{ .ACCMODE = .RDONLY };
    const rc = std.os.linux.open(path_z.ptr, flags, 0);
    const err = std.os.linux.errno(rc);
    if (err != .SUCCESS) {
        return ParseError.FileNotFound;
    }
    const fd: i32 = @intCast(rc);

    const size_rc = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.END);
    if (size_rc < 0) {
        _ = std.os.linux.close(fd);
        return ParseError.ReadError;
    }
    const size: usize = @intCast(size_rc);
    _ = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.SET);

    const data = allocator.alignedAlloc(u8, .fromByteUnits(4096), size) catch {
        _ = std.os.linux.close(fd);
        return ParseError.OutOfMemory;
    };
    errdefer allocator.free(data);

    var off: usize = 0;
    while (off < size) {
        const n = std.os.linux.read(fd, data[off..].ptr, size - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    if (off != size) {
        _ = std.os.linux.close(fd);
        return ParseError.ReadError;
    }

    _ = std.os.linux.close(fd);

    var parser = Parser.init(allocator, data);
    const gguf_file = try parser.parse();

    allocator.free(data);

    return gguf_file;
}

// ============================================================================
// SVC4 Vocab / GGUF Integration
// ============================================================================

pub fn hasAximindsSvc4(gguf: *const GGUFFile) bool {
    var it = gguf.metadata.keyIterator();
    while (it.next()) |key| {
        if (std.mem.startsWith(u8, key.*, svc4.GGUF_SVC4_PREFIX)) return true;
    }
    return false;
}

pub fn extractSvc4Metadata(gguf: *const GGUFFile, allocator: Allocator) !svc4.Svc4GGUFMetadata {
    return svc4.extractSvc4GGUFMetadata(gguf, allocator);
}

pub fn buildSvc4Remapper(gguf: *const GGUFFile, allocator: Allocator) !svc4.VocabRemapper {
    return svc4.buildRemapperFromGGUF(allocator, gguf);
}

// ============================================================================
// Model Config Extraction
// ============================================================================

pub const ModelConfig = struct {
    architecture: []const u8,
    name: []const u8,
    context_length: u32,
    embedding_length: u32,
    block_count: u32,
    feed_forward_length: u32,
    attention_head_count: u32,
    attention_head_count_kv: u32,
    rope_freq_base: f32,
    rope_dimension_count: u32,
    layer_norm_rms_epsilon: f32,
    vocab_size: u32,
    bos_token_id: u32,
    eos_token_id: u32,
};

pub fn extractModelConfig(gguf: *const GGUFFile) !ModelConfig {
    const arch = gguf.getMetadataString("general.architecture") orelse "unknown";

    var prefix: []const u8 = "llama";
    if (std.mem.eql(u8, arch, "qwen2") or std.mem.eql(u8, arch, "qwen3")) {
        prefix = arch;
    }

    // Simplified extraction (full would concat keys)
    const context = @as(u32, @intCast(gguf.getMetadataInt(prefix ++ ".context_length") orelse 2048));
    const embed = @as(u32, @intCast(gguf.getMetadataInt(prefix ++ ".embedding_length") orelse 4096));
    const blocks = @as(u32, @intCast(gguf.getMetadataInt(prefix ++ ".block_count") orelse 32));
    const ff = @as(u32, @intCast(gguf.getMetadataInt(prefix ++ ".feed_forward_length") orelse 11008));
    const heads = @as(u32, @intCast(gguf.getMetadataInt(prefix ++ ".attention.head_count") orelse 32));
    const heads_kv = @as(u32, @intCast(gguf.getMetadataInt(prefix ++ ".attention.head_count_kv") orelse 8));
    const rope_base = @floatCast(gguf.getMetadataFloat(prefix ++ ".rope.freq_base") orelse 10000.0);
    const rope_dim = @as(u32, @intCast(gguf.getMetadataInt(prefix ++ ".rope.dimension_count") orelse 128));
    const eps = @floatCast(gguf.getMetadataFloat(prefix ++ ".attention.layer_norm_rms_epsilon") orelse 1e-5);
    const vocab = @as(u32, @intCast(gguf.getMetadataInt("tokenizer.ggml.tokens") orelse 32000)); // approx
    const bos = @as(u32, @intCast(gguf.getMetadataInt("tokenizer.ggml.bos_token_id") orelse 1));
    const eos = @as(u32, @intCast(gguf.getMetadataInt("tokenizer.ggml.eos_token_id") orelse 2));

    return .{
        .architecture = arch,
        .name = gguf.getMetadataString("general.name") orelse "unknown",
        .context_length = context,
        .embedding_length = embed,
        .block_count = blocks,
        .feed_forward_length = ff,
        .attention_head_count = heads,
        .attention_head_count_kv = heads_kv,
        .rope_freq_base = rope_base,
        .rope_dimension_count = rope_dim,
        .layer_norm_rms_epsilon = eps,
        .vocab_size = vocab,
        .bos_token_id = bos,
        .eos_token_id = eos,
    };
}
