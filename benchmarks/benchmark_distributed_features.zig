// Comprehensive benchmarks for distributed features
// CANARY: REQ=REQ-GQL-BENCH; FEATURE="Distributed Features Benchmark"; ASPECT=Performance; STATUS=TESTED; TEST=BenchmarkCANARY_Distributed; OWNER=bench; UPDATED=2025-09-29

const std = @import("std");
const testing = std.testing;

const lib = @import("geode");
const txn_coordinator = lib.distributed.txn_coordinator;
const raft_consensus = lib.distributed.raft_consensus;
const fulltext = lib.index.fulltext;
const leiden = lib.graph.leiden;
const wcoj = lib.planner_wcoj;

// Zig 0.16 compat: std.time.Timer removed; use clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// Minimal Timer replacement — matches old Timer.start()/read() shape so the file can be ported mechanically.
const Timer = struct {
    start_ns: u64,
    pub fn start() !Timer {
        return .{ .start_ns = nowNs() };
    }
    pub fn read(self: *Timer) u64 {
        return nowNs() - self.start_ns;
    }
};

fn benchmarkTimer() !Timer {
    return try Timer.start();
}

pub fn main() !void {
    // Zig 0.16 compat: GeneralPurposeAllocator renamed to DebugAllocator.
    var dbg_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg_alloc.deinit();
    const allocator: std.mem.Allocator = if (@import("builtin").mode == .Debug)
        dbg_alloc.allocator()
    else
        std.heap.smp_allocator;

    std.debug.print("\n=== Geode Distributed Features Benchmarks ===\n\n", .{});

    try benchmark2PC(allocator);
    try benchmarkBM25(allocator);
    try benchmarkLeiden(allocator);
    try benchmarkWCOJ(allocator);

    std.debug.print("\n=== Benchmarks Complete ===\n", .{});
}

fn benchmark2PC(allocator: std.mem.Allocator) !void {
    std.debug.print("## 2PC Transaction Coordinator Benchmarks\n", .{});

    // Benchmark: Single transaction prepare/commit
    {
        var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
        defer coordinator.deinit();

        var timer = try benchmarkTimer();

        const iterations: u32 = 10000;
        var i: u32 = 0;
        while (i < iterations) : (i += 1) {
            const prepare = raft_consensus.TxnPrepare{
                .xid = i,
                .shard_id = i % 10,
                .write_set = "key1\nkey2\nkey3",
                .metadata = "bench",
            };

            _ = try coordinator.handlePrepare(prepare);
            try coordinator.handleDecide(.{ .xid = i, .commit = true });
        }

        const elapsed = timer.read();
        const ops_per_sec = @as(f64, @floatFromInt(iterations)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed));
        std.debug.print("  Single txn throughput: {d:.0} ops/sec\n", .{ops_per_sec});
    }

    // Benchmark: Concurrent non-conflicting transactions
    {
        var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
        defer coordinator.deinit();

        var timer = try benchmarkTimer();

        const concurrent_txns: u32 = 100;
        const rounds: u32 = 100;

        var round: u32 = 0;
        while (round < rounds) : (round += 1) {
            // Prepare all
            var t: u32 = 0;
            while (t < concurrent_txns) : (t += 1) {
                const xid = round * concurrent_txns + t;
                const write_set = try std.fmt.allocPrint(allocator, "key_{}\n", .{t});
                defer allocator.free(write_set);

                const prepare = raft_consensus.TxnPrepare{
                    .xid = xid,
                    .shard_id = t % 10,
                    .write_set = write_set,
                    .metadata = "bench",
                };

                _ = try coordinator.handlePrepare(prepare);
            }

            // Commit all
            t = 0;
            while (t < concurrent_txns) : (t += 1) {
                const xid = round * concurrent_txns + t;
                try coordinator.handleDecide(.{ .xid = xid, .commit = true });
            }
        }

        const elapsed = timer.read();
        const total_txns = concurrent_txns * rounds;
        const ops_per_sec = @as(f64, @floatFromInt(total_txns)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed));
        std.debug.print("  Concurrent txn throughput: {d:.0} ops/sec\n", .{ops_per_sec});
    }

    // Benchmark: Conflict detection overhead
    {
        var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
        defer coordinator.deinit();

        // Pre-lock some keys
        const blocker = raft_consensus.TxnPrepare{
            .xid = 999999,
            .shard_id = 1,
            .write_set = "key_50",
            .metadata = "blocker",
        };
        _ = try coordinator.handlePrepare(blocker);

        var timer = try benchmarkTimer();

        const attempts: u32 = 10000;
        var conflicts: u32 = 0;
        var i: u32 = 0;
        while (i < attempts) : (i += 1) {
            const write_set = try std.fmt.allocPrint(allocator, "key_{}", .{i % 100});
            defer allocator.free(write_set);

            const prepare = raft_consensus.TxnPrepare{
                .xid = i,
                .shard_id = 2,
                .write_set = write_set,
                .metadata = "conflict_test",
            };

            const can_commit = try coordinator.handlePrepare(prepare);
            if (!can_commit) {
                conflicts += 1;
            } else {
                try coordinator.handleDecide(.{ .xid = i, .commit = false });
            }
        }

        const elapsed = timer.read();
        const checks_per_sec = @as(f64, @floatFromInt(attempts)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed));
        std.debug.print("  Conflict checks: {d:.0} checks/sec ({} conflicts)\n", .{ checks_per_sec, conflicts });
    }

    std.debug.print("\n", .{});
}

fn benchmarkBM25(allocator: std.mem.Allocator) !void {
    std.debug.print("## BM25 Full-Text Search Benchmarks\n", .{});

    // Benchmark: Document indexing speed
    {
        var index = try fulltext.FullTextIndex.init(allocator);
        defer index.deinit();

        var timer = try benchmarkTimer();

        const num_docs: u64 = 1000;
        var i: u64 = 0;
        while (i < num_docs) : (i += 1) {
            const content = try std.fmt.allocPrint(allocator, "Document {} contains various words including lorem ipsum dolor sit amet consectetur adipiscing elit", .{i});
            defer allocator.free(content);
            try index.indexDocument(i, content);
        }

        const elapsed = timer.read();
        const docs_per_sec = @as(f64, @floatFromInt(num_docs)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed));
        std.debug.print("  Indexing throughput: {d:.0} docs/sec\n", .{docs_per_sec});
    }

    // Benchmark: Search performance
    {
        var index = try fulltext.FullTextIndex.init(allocator);
        defer index.deinit();

        // Pre-index documents
        var i: u64 = 0;
        while (i < 5000) : (i += 1) {
            const content = try std.fmt.allocPrint(allocator, "The quick brown fox jumps over the lazy dog. Document {} has unique content with keywords alpha beta gamma delta epsilon zeta eta theta", .{i});
            defer allocator.free(content);
            try index.indexDocument(i, content);
        }

        var timer = try benchmarkTimer();

        const searches: u32 = 1000;
        const search_terms = [_][]const u8{
            "quick brown",
            "lazy dog",
            "alpha beta",
            "unique content",
            "document keywords",
        };

        i = 0;
        while (i < searches) : (i += 1) {
            const query = search_terms[i % search_terms.len];
            const results = try index.search(query, 10);
            allocator.free(results);
        }

        const elapsed = timer.read();
        const searches_per_sec = @as(f64, @floatFromInt(searches)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed));
        std.debug.print("  Search throughput: {d:.0} searches/sec\n", .{searches_per_sec});
    }

    // Benchmark: Large corpus search
    {
        var index = try fulltext.FullTextIndex.init(allocator);
        defer index.deinit();

        // Build large corpus
        var i: u64 = 0;
        while (i < 10000) : (i += 1) {
            const content = try std.fmt.allocPrint(allocator, "Article {} discusses {s} and {s} in the context of {s}", .{ i, if (i % 3 == 0) "technology" else "science", if (i % 5 == 0) "innovation" else "research", if (i % 7 == 0) "development" else "discovery" });
            defer allocator.free(content);
            try index.indexDocument(i, content);
        }

        var timer = try benchmarkTimer();

        // Search for rare combinations
        const results = try index.search("technology innovation development", 100);
        defer allocator.free(results);

        const elapsed = timer.read();
        const ms = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms;
        std.debug.print("  Large corpus search: {d:.1} ms for 10k docs\n", .{ms});
    }

    std.debug.print("\n", .{});
}

fn benchmarkLeiden(allocator: std.mem.Allocator) !void {
    std.debug.print("## Leiden Community Detection Benchmarks\n", .{});

    // Benchmark: Small graph (100 nodes)
    {
        var detector = leiden.LeidenDetector.init(allocator, 1.0);
        detector.max_iterations = 50;

        var nodes = std.ArrayList(u64).init(allocator);
        defer nodes.deinit();
        var edges = std.ArrayList(leiden.LeidenDetector.Edge).init(allocator);
        defer edges.deinit();

        const num_nodes: u64 = 100;
        var i: u64 = 0;
        while (i < num_nodes) : (i += 1) {
            try nodes.append(i);
        }

        // Create community structure
        var n1: u64 = 0;
        while (n1 < num_nodes) : (n1 += 1) {
            var n2 = n1 + 1;
            while (n2 < num_nodes and n2 < n1 + 5) : (n2 += 1) {
                const weight: f64 = if ((n1 / 20) == (n2 / 20)) 10.0 else 0.1;
                try edges.append(.{ .source = n1, .target = n2, .weight = weight });
            }
        }

        const graph = leiden.LeidenDetector.Graph{
            .nodes = nodes.items,
            .edges = edges.items,
            .node_weights = null,
        };

        var timer = try benchmarkTimer();

        const result = try detector.detectCommunities(graph);
        defer {
            for (result.communities) |*comm| {
                comm.nodes.deinit();
            }
            allocator.free(result.communities);
        }

        const elapsed = timer.read();
        const ms = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms;
        std.debug.print("  Small graph (100 nodes): {d:.1} ms, {} communities, modularity={d:.3}\n", .{ ms, result.communities.len, result.modularity });
    }

    // Benchmark: Medium graph (1000 nodes)
    {
        var detector = leiden.LeidenDetector.init(allocator, 1.0);
        detector.max_iterations = 20;

        var nodes = std.ArrayList(u64).init(allocator);
        defer nodes.deinit();
        var edges = std.ArrayList(leiden.LeidenDetector.Edge).init(allocator);
        defer edges.deinit();

        const num_nodes: u64 = 1000;
        const num_communities: u64 = 10;
        const nodes_per_comm = num_nodes / num_communities;

        var i: u64 = 0;
        while (i < num_nodes) : (i += 1) {
            try nodes.append(i);
        }

        // Create dense communities with sparse inter-community edges
        var c: u64 = 0;
        while (c < num_communities) : (c += 1) {
            const start = c * nodes_per_comm;
            const end = start + nodes_per_comm;

            var n1 = start;
            while (n1 < end) : (n1 += 1) {
                var n2 = n1 + 1;
                while (n2 < end and n2 < n1 + 10) : (n2 += 1) {
                    try edges.append(.{ .source = n1, .target = n2, .weight = 5.0 });
                }
            }

            // Add weak inter-community edge
            if (c < num_communities - 1) {
                try edges.append(.{ .source = start, .target = (c + 1) * nodes_per_comm, .weight = 0.1 });
            }
        }

        const graph = leiden.LeidenDetector.Graph{
            .nodes = nodes.items,
            .edges = edges.items,
            .node_weights = null,
        };

        var timer = try benchmarkTimer();

        const result = try detector.detectCommunities(graph);
        defer {
            for (result.communities) |*comm| {
                comm.nodes.deinit();
            }
            allocator.free(result.communities);
        }

        const elapsed = timer.read();
        const ms = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms;
        std.debug.print("  Medium graph (1000 nodes): {d:.1} ms, {} communities\n", .{ ms, result.communities.len });
    }

    std.debug.print("\n", .{});
}

fn benchmarkWCOJ(allocator: std.mem.Allocator) !void {
    std.debug.print("## WCOJ (Worst-Case Optimal Join) Benchmarks\n", .{});

    // Benchmark: Two-way join
    {
        var executor = wcoj.WCOJExecutor.init(allocator);

        // Create relations
        var r_tuples = std.ArrayList(wcoj.WCOJExecutor.Tuple).init(allocator);
        defer {
            for (r_tuples.items) |tuple| {
                allocator.free(tuple.values);
            }
            r_tuples.deinit();
        }

        var s_tuples = std.ArrayList(wcoj.WCOJExecutor.Tuple).init(allocator);
        defer {
            for (s_tuples.items) |tuple| {
                allocator.free(tuple.values);
            }
            s_tuples.deinit();
        }

        const size: i64 = 1000;
        var i: i64 = 0;
        while (i < size) : (i += 1) {
            const r_values = try allocator.alloc(wcoj.WCOJExecutor.Value, 2);
            r_values[0] = .{ .integer = i };
            r_values[1] = .{ .integer = i % 100 };
            try r_tuples.append(.{ .values = r_values });

            const s_values = try allocator.alloc(wcoj.WCOJExecutor.Value, 2);
            s_values[0] = .{ .integer = i % 100 };
            s_values[1] = .{ .integer = i * 2 };
            try s_tuples.append(.{ .values = s_values });
        }

        var r = wcoj.WCOJExecutor.Relation{
            .name = "R",
            .attributes = &[_]wcoj.WCOJExecutor.Attribute{
                .{ .name = "A", .position = 0 },
                .{ .name = "B", .position = 1 },
            },
            .tuples = r_tuples.items,
            .indices = &[_]wcoj.WCOJExecutor.Index{},
        };

        var s = wcoj.WCOJExecutor.Relation{
            .name = "S",
            .attributes = &[_]wcoj.WCOJExecutor.Attribute{
                .{ .name = "B", .position = 0 },
                .{ .name = "C", .position = 1 },
            },
            .tuples = s_tuples.items,
            .indices = &[_]wcoj.WCOJExecutor.Index{},
        };

        const r_idx = try wcoj.WCOJExecutor.createIndex(allocator, &r, &[_]usize{1});
        const s_idx = try wcoj.WCOJExecutor.createIndex(allocator, &s, &[_]usize{0});
        defer allocator.free(r_idx.sorted_tuples);
        defer allocator.free(s_idx.sorted_tuples);

        r.indices = &[_]wcoj.WCOJExecutor.Index{r_idx};
        s.indices = &[_]wcoj.WCOJExecutor.Index{s_idx};

        const query = wcoj.WCOJExecutor.JoinQuery{
            .relations = &[_]wcoj.WCOJExecutor.Relation{ r, s },
            .join_attributes = &[_]wcoj.WCOJExecutor.JoinAttribute{
                .{ .name = "B", .relation_indices = &[_]usize{ 0, 1 } },
            },
            .filters = &[_]wcoj.WCOJExecutor.Filter{},
        };

        var timer = try benchmarkTimer();

        const result = try executor.executeJoin(query);
        defer {
            for (result.tuples) |tuple| {
                allocator.free(tuple.values);
            }
            allocator.free(result.tuples);
            allocator.free(result.attributes);
        }

        const elapsed = timer.read();
        const ms = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms;
        std.debug.print("  Two-way join (1000x1000): {d:.1} ms, {} results, {} comparisons\n", .{ ms, result.tuples.len, executor.stats.comparisons });
    }

    // Benchmark: Three-way triangle join
    {
        var executor = wcoj.WCOJExecutor.init(allocator);

        // Create triangle graph
        var r_tuples = std.ArrayList(wcoj.WCOJExecutor.Tuple).init(allocator);
        defer {
            for (r_tuples.items) |tuple| {
                allocator.free(tuple.values);
            }
            r_tuples.deinit();
        }

        const num_nodes: i64 = 100;
        const edge_prob: f64 = 0.1;

        // Generate edges
        var prng = std.Random.DefaultPrng.init(42);
        const random = prng.random();

        var i: i64 = 0;
        while (i < num_nodes) : (i += 1) {
            var j = i + 1;
            while (j < num_nodes) : (j += 1) {
                if (random.float(f64) < edge_prob) {
                    const values = try allocator.alloc(wcoj.WCOJExecutor.Value, 2);
                    values[0] = .{ .integer = i };
                    values[1] = .{ .integer = j };
                    try r_tuples.append(.{ .values = values });
                }
            }
        }

        var r = wcoj.WCOJExecutor.Relation{
            .name = "Edges",
            .attributes = &[_]wcoj.WCOJExecutor.Attribute{
                .{ .name = "A", .position = 0 },
                .{ .name = "B", .position = 1 },
            },
            .tuples = r_tuples.items,
            .indices = &[_]wcoj.WCOJExecutor.Index{},
        };

        const indices = [_]wcoj.WCOJExecutor.Index{
            try wcoj.WCOJExecutor.createIndex(allocator, &r, &[_]usize{0}),
            try wcoj.WCOJExecutor.createIndex(allocator, &r, &[_]usize{1}),
        };
        defer for (indices) |idx| {
            allocator.free(idx.sorted_tuples);
        };

        r.indices = &indices;

        var timer = try benchmarkTimer();

        // Triangle query: Find (A,B), (B,C), (A,C)
        const query = wcoj.WCOJExecutor.JoinQuery{
            .relations = &[_]wcoj.WCOJExecutor.Relation{ r, r, r },
            .join_attributes = &[_]wcoj.WCOJExecutor.JoinAttribute{
                .{ .name = "A", .relation_indices = &[_]usize{ 0, 2 } },
                .{ .name = "B", .relation_indices = &[_]usize{ 0, 1 } },
            },
            .filters = &[_]wcoj.WCOJExecutor.Filter{},
        };

        const result = try executor.executeJoin(query);
        defer {
            for (result.tuples) |tuple| {
                allocator.free(tuple.values);
            }
            allocator.free(result.tuples);
            allocator.free(result.attributes);
        }

        const elapsed = timer.read();
        const ms = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_ms;
        std.debug.print("  Triangle join: {d:.1} ms, {} triangles found\n", .{ ms, result.tuples.len });
    }

    std.debug.print("\n", .{});
}
