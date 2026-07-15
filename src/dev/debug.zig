// src/dev/debug.zig
// Pluggable dev debugging module.
// When build_options.dev_debug = false (default), all functions are no-ops (zero cost in release).
// Enable with: zig build -Ddev-debug=true for full tracing, error codes, etc. during dev.
// The stripped/obfuscated/encrypted binaries step is ONLY necessary at the very last step before production.
// All other dev/debug suggestions are great for development.
// Error codes are non-descript (e.g. LM-409) to protect IP even in logs.
// See debug-codebook.md for mapping to locations/flow steps.

const std = @import("std");
const build_options = @import("build_options");

/// Log an error with code (e.g. "LM-409") and optional context.
/// When disabled, completely bypassed.
pub fn log_error(comptime code: []const u8, context: []const u8) void {
    if (!build_options.dev_debug) return;
    std.debug.print("[DEV-ERR {s}] {s}\n", .{ code, context });
}

/// Trace a point in flow (e.g. "engine.execute.001").
/// Use for identifying where in process (e.g. before/after cache lookup).
pub fn trace(comptime point: []const u8) void {
    if (!build_options.dev_debug) return;
    std.debug.print("[DEV-TRACE] {s}\n", .{point});
}

/// Log a metric or detail (real runtime value).
pub fn log_detail(comptime key: []const u8, value: anytype) void {
    if (!build_options.dev_debug) return;
    std.debug.print("[DEV-DETAIL {s}] {}\n", .{ key, value });
}

/// For cache/memo hits etc.
pub fn log_cache_hit(level: u8, key_hash: u64, hit: bool) void {
    if (!build_options.dev_debug) return;
    std.debug.print("[DEV-CACHE L{d}] key={d} hit={}\n", .{ level, key_hash, hit });
}

/// General pluggable hook for future (e.g. custom tracers).
pub fn hook(event: []const u8, data: anytype) void {
    if (!build_options.dev_debug) return;
    std.debug.print("[DEV-HOOK {s}] {}\n", .{ event, data });
}