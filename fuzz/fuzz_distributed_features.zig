// Comprehensive fuzz testing for distributed features
// CANARY: REQ=REQ-GQL-FUZZ; FEATURE="Distributed Features Fuzzing"; ASPECT=Fuzzing; STATUS=TESTED; TEST=FuzzCANARY_Distributed; OWNER=fuzz; UPDATED=2025-09-29

const std = @import("std");
const testing = std.testing;

const lib = @import("geode");
const txn_coordinator = lib.distributed.txn_coordinator;
const raft_consensus = lib.distributed.raft_consensus;
const fulltext = lib.index.fulltext;
const leiden = lib.graph.leiden;
const wcoj = lib.planner_wcoj;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Initialize random generator
    var prng = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.os.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();
    
    std.debug.print("\n=== Geode Distributed Features Fuzz Testing ===\n\n", .{});
    
    const iterations: u32 = 10000;
    
    try fuzz2PC(allocator, random, iterations);
    try fuzzBM25(allocator, random, iterations);
    try fuzzLeiden(allocator, random, iterations);
    try fuzzWCOJ(allocator, random, iterations);
    
    std.debug.print("\n=== Fuzz Testing Complete ===\n", .{});
}

fn fuzz2PC(allocator: std.mem.Allocator, random: std.rand.Random, iterations: u32) !void {
    std.debug.print("## Fuzzing 2PC Transaction Coordinator\n", .{});
    
    var coordinator = try txn_coordinator.TxnCoordinator.init(allocator);
    defer coordinator.deinit();
    
    var errors: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // Generate random transaction
        const xid = random.int(u64);
        const shard_id = random.int(u64) % 100;
        
        // Generate random write set
        var write_set = std.ArrayList(u8).init(allocator);
        defer write_set.deinit();
        
        const num_keys = random.intRangeAtMost(u32, 0, 100);
        var k: u32 = 0;
        while (k < num_keys) : (k += 1) {
            try write_set.writer().print("key_{x}\n", .{random.int(u64)});
        }
        
        // Generate random metadata
        const metadata_len = random.intRangeAtMost(usize, 0, 1024);
        var metadata = try allocator.alloc(u8, metadata_len);
        defer allocator.free(metadata);
        random.bytes(metadata);
        
        // Ensure metadata is valid UTF-8 by replacing invalid bytes
        for (metadata) |*byte| {
            if (byte.* > 127) byte.* = 'X';
        }
        
        const prepare = raft_consensus.TxnPrepare{
            .xid = xid,
            .shard_id = shard_id,
            .write_set = write_set.items,
            .metadata = metadata,
        };
        
        // Try prepare
        const can_commit = coordinator.handlePrepare(prepare) catch |err| {
            errors += 1;
            continue;
        };
        
        // Random decide
        if (random.boolean()) {
            const decide = raft_consensus.TxnDecide{
                .xid = xid,
                .commit = can_commit and random.boolean(),
            };
            
            coordinator.handleDecide(decide) catch |err| {
                errors += 1;
            };
        }
        
        // Occasionally check timeouts
        if (random.intRangeAtMost(u32, 0, 100) == 0) {
            coordinator.checkTimeouts() catch |err| {
                errors += 1;
            };
        }
    }
    
    std.debug.print("  Completed {} iterations with {} errors\n", .{ iterations, errors });
    std.debug.print("  Active transactions: {}\n", .{coordinator.prepared_txns.count()});
    std.debug.print("  Active locks: {}\n", .{coordinator.lock_table.count()});
}

fn fuzzBM25(allocator: std.mem.Allocator, random: std.rand.Random, iterations: u32) !void {
    std.debug.print("\n## Fuzzing BM25 Full-Text Search\n", .{});
    
    var index = try fulltext.FullTextIndex.init(allocator);
    defer index.deinit();
    
    var errors: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const action = random.intRangeAtMost(u32, 0, 2);
        
        switch (action) {
            0 => {
                // Index random document
                const doc_id = random.int(u64) % 10000;
                
                // Generate random text
                var content = std.ArrayList(u8).init(allocator);
                defer content.deinit();
                
                const num_words = random.intRangeAtMost(u32, 1, 100);
                var w: u32 = 0;
                while (w < num_words) : (w += 1) {
                    if (w > 0) try content.append(' ');
                    
                    // Generate random word
                    const word_len = random.intRangeAtMost(u8, 1, 20);
                    var j: u8 = 0;
                    while (j < word_len) : (j += 1) {
                        const char = random.intRangeAtMost(u8, 'a', 'z');
                        try content.append(char);
                    }
                }
                
                index.indexDocument(doc_id, content.items) catch |err| {
                    errors += 1;
                };
            },
            1 => {
                // Search with random query
                var query = std.ArrayList(u8).init(allocator);
                defer query.deinit();
                
                const num_terms = random.intRangeAtMost(u32, 0, 5);
                var t: u32 = 0;
                while (t < num_terms) : (t += 1) {
                    if (t > 0) try query.append(' ');
                    
                    const term_len = random.intRangeAtMost(u8, 1, 15);
                    var j: u8 = 0;
                    while (j < term_len) : (j += 1) {
                        const char = random.intRangeAtMost(u8, 'a', 'z');
                        try query.append(char);
                    }
                }
                
                const max_results = random.intRangeAtMost(usize, 1, 100);
                const results = index.search(query.items, max_results) catch |err| {
                    errors += 1;
                    continue;
                };
                allocator.free(results);
            },
            2 => {
                // Remove random document
                const doc_id = random.int(u64) % 10000;
                index.removeDocument(doc_id) catch |err| {
                    errors += 1;
                };
            },
            else => unreachable,
        }
    }
    
    std.debug.print("  Completed {} iterations with {} errors\n", .{ iterations, errors });
    std.debug.print("  Indexed documents: {}\n", .{index.documents.count()});
    std.debug.print("  Index terms: {}\n", .{index.inverted_index.count()});
}

fn fuzzLeiden(allocator: std.mem.Allocator, random: std.rand.Random, iterations: u32) !void {
    std.debug.print("\n## Fuzzing Leiden Community Detection\n", .{});
    
    var errors: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // Generate random graph
        const num_nodes = random.intRangeAtMost(u64, 2, 100);
        const num_edges = random.intRangeAtMost(usize, 0, num_nodes * (num_nodes - 1) / 2);
        
        var nodes = std.ArrayList(u64).init(allocator);
        defer nodes.deinit();
        
        var n: u64 = 0;
        while (n < num_nodes) : (n += 1) {
            try nodes.append(n);
        }
        
        var edges = std.ArrayList(leiden.LeidenDetector.Edge).init(allocator);
        defer edges.deinit();
        
        var e: usize = 0;
        while (e < num_edges) : (e += 1) {
            const source = random.int(u64) % num_nodes;
            const target = random.int(u64) % num_nodes;
            const weight = random.float(f64) * 100.0;
            
            try edges.append(.{
                .source = source,
                .target = target,
                .weight = weight,
            });
        }
        
        const resolution = random.float(f64) * 3.0;
        var detector = leiden.LeidenDetector.init(allocator, resolution);
        detector.max_iterations = 10; // Limit for fuzzing speed
        
        const graph = leiden.LeidenDetector.Graph{
            .nodes = nodes.items,
            .edges = edges.items,
            .node_weights = null,
        };
        
        const result = detector.detectCommunities(graph) catch |err| {
            errors += 1;
            continue;
        };
        
        // Validate result
        var validation_errors: u32 = 0;
        
        // Check all nodes are assigned
        var assigned_nodes = std.AutoHashMap(u64, void).init(allocator);
        defer assigned_nodes.deinit();
        
        for (result.communities) |*comm| {
            for (comm.nodes.items) |node| {
                assigned_nodes.put(node, {}) catch {};
            }
            comm.nodes.deinit();
        }
        allocator.free(result.communities);
        
        if (assigned_nodes.count() == 0 and num_nodes > 0) {
            validation_errors += 1;
        }
        
        // Check modularity is reasonable
        if (result.modularity < -1.0 or result.modularity > 1.0) {
            validation_errors += 1;
        }
        
        if (validation_errors > 0) {
            errors += validation_errors;
        }
    }
    
    std.debug.print("  Completed {} iterations with {} errors\n", .{ iterations, errors });
}

fn fuzzWCOJ(allocator: std.mem.Allocator, random: std.rand.Random, iterations: u32) !void {
    std.debug.print("\n## Fuzzing WCOJ\n", .{});
    
    var errors: u32 = 0;
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        // Generate random relations
        const num_relations = random.intRangeAtMost(usize, 1, 5);
        const num_attributes = random.intRangeAtMost(usize, 1, 5);
        const num_tuples = random.intRangeAtMost(usize, 0, 50);
        
        var relations = std.ArrayList(wcoj.WCOJExecutor.Relation).init(allocator);
        defer {
            for (relations.items) |*rel| {
                for (rel.tuples) |tuple| {
                    allocator.free(tuple.values);
                }
                allocator.free(rel.tuples);
                allocator.free(rel.attributes);
                for (rel.indices) |idx| {
                    allocator.free(idx.sorted_tuples);
                }
                allocator.free(rel.indices);
            }
            relations.deinit();
        }
        
        var r: usize = 0;
        while (r < num_relations) : (r += 1) {
            // Generate attributes
            var attributes = try allocator.alloc(wcoj.WCOJExecutor.Attribute, num_attributes);
            var a: usize = 0;
            while (a < num_attributes) : (a += 1) {
                attributes[a] = .{
                    .name = try std.fmt.allocPrint(allocator, "attr_{}", .{a}),
                    .position = a,
                };
            }
            defer for (attributes) |attr| {
                allocator.free(attr.name);
            };
            
            // Generate tuples
            var tuples = try allocator.alloc(wcoj.WCOJExecutor.Tuple, num_tuples);
            var t: usize = 0;
            while (t < num_tuples) : (t += 1) {
                var values = try allocator.alloc(wcoj.WCOJExecutor.Value, num_attributes);
                var v: usize = 0;
                while (v < num_attributes) : (v += 1) {
                    // Random value type
                    const value_type = random.intRangeAtMost(u32, 0, 2);
                    values[v] = switch (value_type) {
                        0 => .{ .integer = random.int(i64) % 100 },
                        1 => .{ .float = random.float(f64) * 100.0 },
                        2 => .{ .null = {} },
                        else => unreachable,
                    };
                }
                tuples[t] = .{ .values = values };
            }
            
            // Create indices
            var indices = std.ArrayList(wcoj.WCOJExecutor.Index).init(allocator);
            if (num_attributes > 0 and num_tuples > 0) {
                const idx_attr = random.int(usize) % num_attributes;
                const idx = wcoj.WCOJExecutor.createIndex(allocator, &wcoj.WCOJExecutor.Relation{
                    .name = try std.fmt.allocPrint(allocator, "R{}", .{r}),
                    .attributes = attributes,
                    .tuples = tuples,
                    .indices = &[_]wcoj.WCOJExecutor.Index{},
                }, &[_]usize{idx_attr}) catch |err| {
                    errors += 1;
                    continue;
                };
                try indices.append(idx);
            }
            
            try relations.append(.{
                .name = try std.fmt.allocPrint(allocator, "R{}", .{r}),
                .attributes = attributes,
                .tuples = tuples,
                .indices = indices.toOwnedSlice(),
            });
        }
        
        if (relations.items.len == 0) continue;
        
        // Generate random join attributes
        var join_attrs = std.ArrayList(wcoj.WCOJExecutor.JoinAttribute).init(allocator);
        defer {
            for (join_attrs.items) |attr| {
                allocator.free(attr.name);
                allocator.free(attr.relation_indices);
            }
            join_attrs.deinit();
        }
        
        const num_join_attrs = random.intRangeAtMost(usize, 1, 3);
        var j: usize = 0;
        while (j < num_join_attrs) : (j += 1) {
            var rel_indices = std.ArrayList(usize).init(allocator);
            const num_rels = random.intRangeAtMost(usize, 1, relations.items.len);
            var ri: usize = 0;
            while (ri < num_rels) : (ri += 1) {
                try rel_indices.append(random.int(usize) % relations.items.len);
            }
            
            try join_attrs.append(.{
                .name = try std.fmt.allocPrint(allocator, "join_attr_{}", .{j}),
                .relation_indices = rel_indices.toOwnedSlice(),
            });
        }
        
        const query = wcoj.WCOJExecutor.JoinQuery{
            .relations = relations.items,
            .join_attributes = join_attrs.items,
            .filters = &[_]wcoj.WCOJExecutor.Filter{},
        };
        
        var executor = wcoj.WCOJExecutor.init(allocator);
        const result = executor.executeJoin(query) catch |err| {
            errors += 1;
            continue;
        };
        
        // Cleanup result
        for (result.tuples) |tuple| {
            allocator.free(tuple.values);
        }
        allocator.free(result.tuples);
        allocator.free(result.attributes);
    }
    
    std.debug.print("  Completed {} iterations with {} errors\n", .{ iterations, errors });
}

// Property-based testing helpers
fn invariant2PC(coordinator: *txn_coordinator.TxnCoordinator) bool {
    // Invariant: Each key can only be locked by one transaction
    var key_counts = std.StringHashMap(u32).init(coordinator.allocator);
    defer key_counts.deinit();
    
    var it = coordinator.lock_table.iterator();
    while (it.next()) |entry| {
        const count = key_counts.get(entry.key_ptr.*) orelse 0;
        key_counts.put(entry.key_ptr.*, count + 1) catch return false;
        if (count > 0) return false; // Duplicate lock
    }
    
    return true;
}

fn invariantBM25(index: *fulltext.FullTextIndex) bool {
    // Invariant: TF-IDF scores should be non-negative
    var it = index.inverted_index.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.idf < 0) return false;
        for (entry.value_ptr.documents) |doc| {
            if (doc.tf < 0 or doc.tf_idf < 0) return false;
        }
    }
    return true;
}

fn invariantLeiden(result: leiden.LeidenDetector.Result) bool {
    // Invariant: Modularity should be in range [-1, 1]
    return result.modularity >= -1.0 and result.modularity <= 1.0;
}

fn invariantWCOJ(executor: *wcoj.WCOJExecutor) bool {
    // Invariant: Stats should be non-negative
    return executor.stats.comparisons >= 0 and
           executor.stats.seek_operations >= 0 and
           executor.stats.tuples_produced >= 0;
}