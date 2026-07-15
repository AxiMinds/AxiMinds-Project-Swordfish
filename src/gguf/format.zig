// AxiMinds-zllama/src/gguf/format.zig
// GGUF File Format Definitions
//
// GGUF (GGML Universal Format) is the standard format for LLM weights.
// This module defines the structures and constants for parsing GGUF files.
//
// Reference: https://github.com/ggerganov/ggml/blob/master/docs/gguf.md
//
// Copyright (c) 2024-2026 AxiMinds Corporation. All Rights Reserved.

const std = @import("std");

// ============================================================================
// GGUF Magic and Version
// ============================================================================

pub const GGUF_MAGIC: u32 = 0x46554747; // "GGUF" in little-endian
pub const GGUF_VERSION: u32 = 3;

// ============================================================================
// GGUF Value Types
// ============================================================================

pub const GGUFType = enum(u32) {
    UINT8 = 0,
    INT8 = 1,
    UINT16 = 2,
    INT16 = 3,
    UINT32 = 4,
    INT32 = 5,
    FLOAT32 = 6,
    BOOL = 7,
    STRING = 8,
    ARRAY = 9,
    UINT64 = 10,
    INT64 = 11,
    FLOAT64 = 12,
};

// ============================================================================
// GGML Tensor Types (Quantization formats)
// ============================================================================

pub const GGMLType = enum(u32) {
    F32 = 0,
    F16 = 1,
    Q4_0 = 2,
    Q4_1 = 3,
    Q5_0 = 6,
    Q5_1 = 7,
    Q8_0 = 8,
    Q8_1 = 9,
    Q2_K = 10,
    Q3_K = 11,
    Q4_K = 12,
    Q5_K = 13,
    Q6_K = 14,
    Q8_K = 15,
    IQ2_XXS = 16,
    IQ2_XS = 17,
    IQ3_XXS = 18,
    IQ1_S = 19,
    IQ4_NL = 20,
    IQ3_S = 21,
    IQ2_S = 22,
    IQ4_XS = 23,
    I8 = 24,
    I16 = 25,
    I32 = 26,
    I64 = 27,
    F64 = 28,
    BF16 = 29,

    pub fn blockSize(self: GGMLType) usize {
        return switch (self) {
            .F32, .F16, .BF16, .F64 => 1,
            .I8, .I16, .I32, .I64 => 1,
            .Q4_0, .Q4_1, .Q5_0, .Q5_1, .Q8_0, .Q8_1 => 32,
            .Q2_K, .Q3_K, .Q4_K, .Q5_K, .Q6_K, .Q8_K => 256,
            .IQ2_XXS, .IQ2_XS, .IQ3_XXS, .IQ1_S, .IQ4_NL, .IQ3_S, .IQ2_S, .IQ4_XS => 256,
        };
    }

    pub fn typeSize(self: GGMLType) usize {
        return switch (self) {
            .F32 => 4,
            .F16 => 2,
            .BF16 => 2,
            .F64 => 8,
            .I8 => 1,
            .I16 => 2,
            .I32 => 4,
            .I64 => 8,
            .Q4_0 => 18,  // 32 values in 18 bytes
            .Q4_1 => 20,
            .Q5_0 => 22,
            .Q5_1 => 24,
            .Q8_0 => 34,
            .Q8_1 => 36,
            .Q2_K => 84,
            .Q3_K => 110,
            .Q4_K => 144,
            .Q5_K => 176,
            .Q6_K => 210,
            .Q8_K => 292,
            else => 0,
        };
    }

    pub fn bytesPerElement(self: GGMLType) f32 {
        const bs = self.blockSize();
        const ts = self.typeSize();
        return @as(f32, @floatFromInt(ts)) / @as(f32, @floatFromInt(bs));
    }
};

// ============================================================================
// GGUF Header
// ============================================================================

pub const GGUFHeader = struct {
    magic: u32,
    version: u32,
    tensor_count: u64,
    metadata_kv_count: u64,
};

// ============================================================================
// GGUF String
// ============================================================================

pub const GGUFString = struct {
    len: u64,
    data: []const u8,

    pub fn toString(self: GGUFString) []const u8 {
        return self.data[0..self.len];
    }
};

// ============================================================================
// GGUF Metadata Value
// ============================================================================

pub const GGUFValue = union(GGUFType) {
    UINT8: u8,
    INT8: i8,
    UINT16: u16,
    INT16: i16,
    UINT32: u32,
    INT32: i32,
    FLOAT32: f32,
    BOOL: bool,
    STRING: GGUFString,
    ARRAY: GGUFArray,
    UINT64: u64,
    INT64: i64,
    FLOAT64: f64,
};

pub const GGUFArray = struct {
    type: GGUFType,
    len: u64,
    data: []const u8,
};

// ============================================================================
// GGUF Metadata Key-Value
// ============================================================================

pub const GGUFMetadataKV = struct {
    key: GGUFString,
    value_type: GGUFType,
    value: GGUFValue,
};

// ============================================================================
// GGUF Tensor Info
// ============================================================================

pub const GGUFTensorInfo = struct {
    name: GGUFString,
    n_dims: u32,
    dims: [4]u64,
    tensor_type: GGMLType,
    offset: u64,

    pub fn numElements(self: GGUFTensorInfo) u64 {
        var n: u64 = 1;
        for (0..self.n_dims) |i| {
            n *= self.dims[i];
        }
        return n;
    }

    pub fn numBytes(self: GGUFTensorInfo) u64 {
        const ne = self.numElements();
        const bs = self.tensor_type.blockSize();
        const ts = self.tensor_type.typeSize();
        return (ne / bs) * ts;
    }
};

// ============================================================================
// Common Metadata Keys
// ============================================================================

pub const MetadataKeys = struct {
    // General
    pub const general_architecture = "general.architecture";
    pub const general_name = "general.name";
    pub const general_file_type = "general.file_type";
    pub const general_quantization_version = "general.quantization_version";

    // LLM
    pub const context_length = "llama.context_length";
    pub const embedding_length = "llama.embedding_length";
    pub const block_count = "llama.block_count";
    pub const feed_forward_length = "llama.feed_forward_length";
    pub const attention_head_count = "llama.attention.head_count";
    pub const attention_head_count_kv = "llama.attention.head_count_kv";
    pub const attention_layer_norm_rms_epsilon = "llama.attention.layer_norm_rms_epsilon";
    pub const rope_freq_base = "llama.rope.freq_base";
    pub const rope_dimension_count = "llama.rope.dimension_count";

    // Qwen specific
    pub const qwen2_context_length = "qwen2.context_length";
    pub const qwen2_embedding_length = "qwen2.embedding_length";
    pub const qwen2_block_count = "qwen2.block_count";
    pub const qwen2_feed_forward_length = "qwen2.feed_forward_length";
    pub const qwen2_attention_head_count = "qwen2.attention.head_count";
    pub const qwen2_attention_head_count_kv = "qwen2.attention.head_count_kv";

    // Tokenizer
    pub const tokenizer_model = "tokenizer.ggml.model";
    pub const tokenizer_tokens = "tokenizer.ggml.tokens";
    pub const tokenizer_scores = "tokenizer.ggml.scores";
    pub const tokenizer_token_type = "tokenizer.ggml.token_type";
    pub const tokenizer_bos_id = "tokenizer.ggml.bos_token_id";
    pub const tokenizer_eos_id = "tokenizer.ggml.eos_token_id";
};

// ============================================================================
// Tensor Name Patterns for Qwen/LLaMA
// ============================================================================

pub const TensorNames = struct {
    pub const token_embd = "token_embd.weight";
    pub const output_norm = "output_norm.weight";
    pub const output = "output.weight";

    // Layer patterns (replace {n} with layer number)
    pub const attn_norm = "blk.{n}.attn_norm.weight";
    pub const attn_q = "blk.{n}.attn_q.weight";
    pub const attn_k = "blk.{n}.attn_k.weight";
    pub const attn_v = "blk.{n}.attn_v.weight";
    pub const attn_output = "blk.{n}.attn_output.weight";
    pub const ffn_norm = "blk.{n}.ffn_norm.weight";
    pub const ffn_gate = "blk.{n}.ffn_gate.weight";
    pub const ffn_up = "blk.{n}.ffn_up.weight";
    pub const ffn_down = "blk.{n}.ffn_down.weight";
};
