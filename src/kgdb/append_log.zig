//! Append-only log backend.
//! Simple, robust, high-write-throughput. Edges appended as they arrive.
//! Compaction to LSM happens later (Phase 2).
const std = @import("std");
const record = @import("record.zig");

pub const LogHeader = extern struct {
    magic: u64 = MAGIC,
    version: u32 = 1,
    reserved: u32 = 0,
    record_count: u64 = 0,
};

pub const MAGIC: u64 = 0xa3103234_5105746e; // AXION32D-inspired magic (valid hex)

/// Blocking writeAll using low-level syscall (no Io context needed).
fn writeAll(fd: std.posix.fd_t, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = std.os.linux.write(fd, data[off..].ptr, data.len - off);
        if (std.os.linux.errno(rc) != .SUCCESS) return;
        off += @intCast(rc);
    }
}

pub const AppendLog = struct {
    allocator: std.mem.Allocator,
    fd: std.posix.fd_t,
    header: LogHeader,
    write_offset: u64,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !AppendLog {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        // RDWR + CREAT, do not truncate so we can read existing header
        const flags: std.posix.O = .{ .ACCMODE = .RDWR, .CREAT = true };
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path_z, flags, 0o644);
        errdefer _ = std.os.linux.close(fd);

        // Determine size via lseek to end then back
        const size_raw = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.END);
        const size: usize = @intCast(@max(0, size_raw));
        _ = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.SET);

        var header: LogHeader = .{};

        if (size == 0) {
            // New file — write header
            _ = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.SET);
            writeAll(fd, std.mem.asBytes(&header));
        } else {
            // Existing file — read header
            _ = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.SET);
            const n = try std.posix.read(fd, std.mem.asBytes(&header));
            if (n < @sizeOf(LogHeader)) return error.TruncatedHeader;
            if (header.magic != MAGIC) return error.BadMagic;
        }

        // Position at end for appends
        const write_offset_raw = std.os.linux.lseek(fd, 0, std.os.linux.SEEK.END);
        const write_offset: u64 = @intCast(@max(0, write_offset_raw));

        return .{
            .allocator = allocator,
            .fd = fd,
            .header = header,
            .write_offset = write_offset,
        };
    }

    pub fn close(self: *AppendLog) void {
        self.syncHeader() catch {};
        _ = std.os.linux.close(self.fd);
    }

    pub fn appendEdge(self: *AppendLog, edge: record.Edge) !void {
        _ = std.os.linux.lseek(self.fd, @intCast(self.write_offset), std.os.linux.SEEK.SET);
        const bytes = std.mem.asBytes(&edge);
        writeAll(self.fd, bytes);
        self.write_offset += @sizeOf(record.Edge);
        self.header.record_count += 1;
    }

    pub fn appendEdgesBatch(self: *AppendLog, edges: []const record.Edge) !void {
        if (edges.len == 0) return;
        _ = std.os.linux.lseek(self.fd, @intCast(self.write_offset), std.os.linux.SEEK.SET);
        const bytes = std.mem.sliceAsBytes(edges);
        writeAll(self.fd, bytes);
        self.write_offset += bytes.len;
        self.header.record_count += edges.len;
    }

    pub fn syncHeader(self: *AppendLog) !void {
        _ = std.os.linux.lseek(self.fd, 0, std.os.linux.SEEK.SET);
        writeAll(self.fd, std.mem.asBytes(&self.header));
        // fsync
        _ = std.os.linux.fsync(self.fd);
    }

    /// Scan all edges. Caller-provided callback receives each edge.
    pub fn scanEdges(
        self: *AppendLog,
        ctx: *anyopaque,
        callback: *const fn (ctx: *anyopaque, edge: *const record.Edge) bool,
    ) !void {
        var pos: u64 = @sizeOf(LogHeader);
        _ = std.os.linux.lseek(self.fd, @intCast(pos), std.os.linux.SEEK.SET);

        var batch: [256]record.Edge = undefined;
        while (pos < self.write_offset) {
            const remaining = self.write_offset - pos;
            const to_read_bytes: usize = @intCast(@min(remaining, batch.len * @sizeOf(record.Edge)));
            const count: usize = to_read_bytes / @sizeOf(record.Edge);
            if (count == 0) break;

            const buf = std.mem.sliceAsBytes(batch[0..count]);
            const n = try std.posix.read(self.fd, buf);
            if (n < count * @sizeOf(record.Edge)) break;

            for (batch[0..count]) |*e| {
                if (!callback(ctx, e)) return;
            }
            pos += n;
        }
    }
};

test "append-log basic write/read cycle" {
    const path = "substrate-test-log-tmp.bin";
    var path_z: [256:0]u8 = undefined;
    const plen = @min(path.len, 255);
    @memcpy(path_z[0..plen], path[0..plen]);
    path_z[plen] = 0;
    _ = std.os.linux.unlink(&path_z); // best effort cleanup
    defer _ = std.os.linux.unlink(&path_z);

    {
        var log = try AppendLog.open(std.testing.allocator, path);
        defer log.close();

        const addr1: [32]u8 = @splat(1);
        const addr2: [32]u8 = @splat(2);
        const e = record.Edge{
            .from = addr1,
            .to = addr2,
            .relation = 1,
            .weight = 0.5,
            .timestamp_ns = 1000,
            .flags = 0,
        };
        try log.appendEdge(e);
        try log.syncHeader();

        try std.testing.expectEqual(@as(u64, 1), log.header.record_count);
    }

    // Reopen and verify
    {
        var log = try AppendLog.open(std.testing.allocator, path);
        defer log.close();
        try std.testing.expectEqual(@as(u64, 1), log.header.record_count);
    }
}
