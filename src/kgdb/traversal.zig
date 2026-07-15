//! Multi-hop traversal over the substrate. BFS with weight threshold and hop budget.
//! Ported from AxiMinds/AxiMinds-Substrate (autonomous GH port).
const std = @import("std");
const address = @import("address.zig");
const record = @import("record.zig");
const hot = @import("index_hot.zig");

pub const TraverseOptions = struct {
    max_hops: u32 = 2,
    min_weight: f32 = 0.0,
    relation_filter: ?u32 = null,
    max_results: u32 = 1024,
    /// If >0, apply exponential decay using Edge.effectiveWeight(now, lambda)
    now_ns: i64 = 0,
    decay_lambda: f32 = 0.0,
};

pub const TraverseResult = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(address.Address),
    hop_distances: std.ArrayListUnmanaged(u32),

    pub fn deinit(self: *TraverseResult) void {
        self.nodes.deinit(self.allocator);
        self.hop_distances.deinit(self.allocator);
    }
};

pub fn traverse(
    allocator: std.mem.Allocator,
    index: *const hot.HotIndex,
    start: address.Address,
    opts: TraverseOptions,
) !TraverseResult {
    var result = TraverseResult{
        .allocator = allocator,
        .nodes = .empty,
        .hop_distances = .empty,
    };
    errdefer result.deinit();

    var visited: std.HashMap(address.Address, void, hot.AddressContext, std.hash_map.default_max_load_percentage) = .init(allocator);
    defer visited.deinit();

    var frontier: std.ArrayListUnmanaged(address.Address) = .empty;
    defer frontier.deinit(allocator);
    try frontier.append(allocator, start);
    try visited.put(start, {});

    var hop: u32 = 0;
    while (hop < opts.max_hops and frontier.items.len > 0) : (hop += 1) {
        var next_frontier: std.ArrayListUnmanaged(address.Address) = .empty;
        defer next_frontier.deinit(allocator);

        for (frontier.items) |node| {
            const edges = index.neighbors(node);
            for (edges) |edge| {
                const w = if (opts.decay_lambda > 0.0) edge.effectiveWeight(opts.now_ns, opts.decay_lambda) else edge.weight;
                if (w < opts.min_weight) continue;
                if (opts.relation_filter) |r| if (edge.relation != r) continue;

                const gop = try visited.getOrPut(edge.to);
                if (gop.found_existing) continue;

                try result.nodes.append(allocator, edge.to);
                try result.hop_distances.append(allocator, hop + 1);
                try next_frontier.append(allocator, edge.to);

                if (result.nodes.items.len >= opts.max_results) return result;
            }
        }

        frontier.clearRetainingCapacity();
        try frontier.appendSlice(allocator, next_frontier.items);
    }

    return result;
}

test "traverse 2-hop chain" {
    var idx = hot.HotIndex.init(std.testing.allocator);
    defer idx.deinit();

    const a: [32]u8 = @splat(1);
    const b: [32]u8 = @splat(2);
    const c: [32]u8 = @splat(3);
    const d: [32]u8 = @splat(4);

    // a → b → c → d
    try idx.addEdge(.{ .from = a, .to = b, .relation = 1, .weight = 0.9, .timestamp_ns = 0, .flags = 0 });
    try idx.addEdge(.{ .from = b, .to = c, .relation = 1, .weight = 0.8, .timestamp_ns = 0, .flags = 0 });
    try idx.addEdge(.{ .from = c, .to = d, .relation = 1, .weight = 0.7, .timestamp_ns = 0, .flags = 0 });

    var result = try traverse(std.testing.allocator, &idx, a, .{ .max_hops = 2, .min_weight = 0.0 });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.nodes.items.len);
    try std.testing.expectEqual(@as(u32, 1), result.hop_distances.items[0]);
    try std.testing.expectEqual(@as(u32, 2), result.hop_distances.items[1]);
}

test "traverse filters by weight" {
    var idx = hot.HotIndex.init(std.testing.allocator);
    defer idx.deinit();

    const a: [32]u8 = @splat(1);
    const b: [32]u8 = @splat(2);
    const c: [32]u8 = @splat(3);

    try idx.addEdge(.{ .from = a, .to = b, .relation = 1, .weight = 0.3, .timestamp_ns = 0, .flags = 0 });
    try idx.addEdge(.{ .from = a, .to = c, .relation = 1, .weight = 0.9, .timestamp_ns = 0, .flags = 0 });

    var result = try traverse(std.testing.allocator, &idx, a, .{ .max_hops = 1, .min_weight = 0.5 });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.nodes.items.len);
}
