//! Hot RAM index: adjacency list keyed by AXION-32D address.
//! Used for sub-millisecond traversal from hot partitions.
//! Ported from AxiMinds/AxiMinds-Substrate (autonomous GH port).
const std = @import("std");
const address = @import("address.zig");
const record = @import("record.zig");

pub const AdjacencyMap = std.HashMap(
    address.Address,
    std.ArrayListUnmanaged(record.Edge),
    AddressContext,
    std.hash_map.default_max_load_percentage,
);

pub const AddressContext = struct {
    pub fn hash(_: AddressContext, key: address.Address) u64 {
        return std.hash.Wyhash.hash(0xa10c10d5_e1e574e6, &key);
    }
    pub fn eql(_: AddressContext, a: address.Address, b: address.Address) bool {
        return std.mem.eql(u8, &a, &b);
    }
};

pub const HotIndex = struct {
    allocator: std.mem.Allocator,
    adjacency: AdjacencyMap,
    edge_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) HotIndex {
        return .{
            .allocator = allocator,
            .adjacency = AdjacencyMap.init(allocator),
        };
    }

    pub fn deinit(self: *HotIndex) void {
        var it = self.adjacency.valueIterator();
        while (it.next()) |list| list.deinit(self.allocator);
        self.adjacency.deinit();
    }

    pub fn addEdge(self: *HotIndex, edge: record.Edge) !void {
        const gop = try self.adjacency.getOrPut(edge.from);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, edge);
        self.edge_count += 1;
    }

    pub fn neighbors(self: *const HotIndex, node: address.Address) []const record.Edge {
        if (self.adjacency.getPtr(node)) |list| return list.items;
        return &.{};
    }

    pub fn degree(self: *const HotIndex, node: address.Address) usize {
        return self.neighbors(node).len;
    }
};

test "hot index add and lookup" {
    var idx = HotIndex.init(std.testing.allocator);
    defer idx.deinit();

    const a: [32]u8 = @splat(1);
    const b: [32]u8 = @splat(2);
    const c: [32]u8 = @splat(3);

    try idx.addEdge(.{ .from = a, .to = b, .relation = 1, .weight = 0.5, .timestamp_ns = 0, .flags = 0 });
    try idx.addEdge(.{ .from = a, .to = c, .relation = 1, .weight = 0.7, .timestamp_ns = 0, .flags = 0 });

    try std.testing.expectEqual(@as(usize, 2), idx.degree(a));
    try std.testing.expectEqual(@as(usize, 0), idx.degree(b));
    try std.testing.expectEqual(@as(u64, 2), idx.edge_count);
}
