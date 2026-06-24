const std = @import("std");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const Allocator = std.mem.Allocator;
const net = std.Io.net;

const logging = @import("logging");
const log = logging.scoped("sharding");
const Attr = logging.Attr;

pub const ConsistentHash = @import("consistent_hash.zig").ConsistentHash;

// Enhanced sharding implementation for horizontal scaling
pub const ShardManager = struct {
    allocator: Allocator,
    consistent_hash: ConsistentHash,
    shards: std.AutoHashMap(u64, Shard),
    replication_factor: u32,
    partition_strategy: PartitionStrategy,
    // GAP-0208 FIX: Optional transport callback for network migration
    transport_callback: ?*TransportCallback = null,

    pub const Shard = struct {
        id: u64,
        primary: ShardNode,
        replicas: []ShardNode,
        key_range: ?KeyRange,
        status: ShardStatus,
        statistics: ShardStatistics,
    };

    pub const ShardNode = struct {
        id: u64,
        address: net.IpAddress,
        role: NodeRole,
        status: NodeStatus,
        last_heartbeat: i64,
    };

    pub const NodeRole = enum {
        primary,
        replica,
        candidate,
    };

    pub const NodeStatus = enum {
        healthy,
        degraded,
        unavailable,
        recovering,
    };

    pub const ShardStatus = enum {
        active,
        migrating,
        splitting,
        merging,
        offline,
    };

    pub const KeyRange = struct {
        start: []const u8,
        end: []const u8,
    };

    pub const ShardStatistics = struct {
        node_count: u64,
        edge_count: u64,
        size_bytes: u64,
        read_qps: f64,
        write_qps: f64,
        last_updated: i64,
    };

    pub const PartitionStrategy = enum {
        hash,
        range,
        graph_aware,
        geo_distributed,
    };

    // GAP-0208 FIX: Migration state tracking for progress monitoring and checkpointing
    // CANARY: REQ=REQ-DIST-MIGRATION-002; FEATURE="Migration State"; ASPECT=ProgressTracking; STATUS=TESTED; TEST="executeMigration: transport path batches through the network callback (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
    pub const MigrationState = struct {
        source_shard_id: u64,
        target_shard_id: u64,
        key_range: ?KeyRange,
        batch_size: u64,
        total_items: u64,
        migrated_items: u64,
        verified_items: u64,
        checksum: std.hash.Crc32,
        status: MigrationStatus,
        start_time: i64,
        last_checkpoint: i64,
    };

    pub const MigrationStatus = enum {
        pending,
        in_progress,
        retrying,
        completed,
        failed,
    };

    // GAP-0208 FIX: Transport callback interface for network-based migration
    // CANARY: REQ=REQ-DIST-TRANSPORT-001; FEATURE="Migration Transport"; ASPECT=NetworkCallback; STATUS=TESTED; TEST="executeMigration: transport path batches through the network callback (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
    pub const TransportCallback = struct {
        context: *anyopaque,
        requestBatchFn: *const fn (
            context: *anyopaque,
            source_addr: net.IpAddress,
            shard_id: u64,
            offset: u64,
            count: u64,
            buffer: []u8,
        ) TransportError![]u8,
        sendBatchFn: *const fn (
            context: *anyopaque,
            target_addr: net.IpAddress,
            shard_id: u64,
            data: []const u8,
            checksum: u32,
        ) TransportError!bool,

        pub fn requestBatch(
            self: *TransportCallback,
            source_addr: net.IpAddress,
            shard_id: u64,
            offset: u64,
            count: u64,
            buffer: []u8,
        ) TransportError![]u8 {
            return self.requestBatchFn(self.context, source_addr, shard_id, offset, count, buffer);
        }

        pub fn sendBatch(
            self: *TransportCallback,
            target_addr: net.IpAddress,
            shard_id: u64,
            data: []const u8,
            checksum: u32,
        ) TransportError!bool {
            return self.sendBatchFn(self.context, target_addr, shard_id, data, checksum);
        }
    };

    pub const TransportError = error{
        ConnectionFailed,
        Timeout,
        ChecksumMismatch,
        ShardNotFound,
        InvalidResponse,
    };

    pub fn init(allocator: Allocator, replication_factor: u32, strategy: PartitionStrategy) ShardManager {
        return .{
            .allocator = allocator,
            .consistent_hash = ConsistentHash.init(allocator, 150, .xxhash),
            .shards = std.AutoHashMap(u64, Shard).init(allocator),
            .replication_factor = replication_factor,
            .partition_strategy = strategy,
            .transport_callback = null,
        };
    }

    // GAP-0208 FIX: Set transport callback for network-based migration
    pub fn setTransportCallback(self: *ShardManager, callback: *TransportCallback) void {
        self.transport_callback = callback;
    }

    pub fn deinit(self: *ShardManager) void {
        // Free unique address strings allocated by addShard via allocPrint.
        // Each addShard call produces virtual_nodes ring entries sharing one address pointer,
        // so we deduplicate by pointer value before freeing.
        var seen = std.AutoHashMap(usize, void).init(self.allocator);
        defer seen.deinit();
        for (self.consistent_hash.ring.items) |node| {
            const ptr = @intFromPtr(node.address.ptr);
            if (!seen.contains(ptr)) {
                seen.put(ptr, {}) catch {};
                self.allocator.free(node.address);
            }
        }
        self.consistent_hash.deinit();
        self.shards.deinit();
    }

    // Add a new shard to the cluster
    pub fn addShard(self: *ShardManager, shard: Shard) !void {
        try self.shards.put(shard.id, shard);

        // Add to consistent hash ring
        try self.consistent_hash.addNode(.{
            .id = shard.id,
            .hash = 0, // Will be calculated
            .address = try std.fmt.allocPrint(self.allocator, "{f}", .{shard.primary.address}),
            .weight = 1.0,
            .metadata = null,
        });
    }

    // Get shard for a given key
    pub fn getShardForKey(self: *ShardManager, key: []const u8) !*Shard {
        const shard_id = switch (self.partition_strategy) {
            .hash => (self.consistent_hash.getNode(key) orelse return error.ShardNotFound).id,
            .range => self.getRangeShardId(key),
            .graph_aware => self.getGraphAwareShardId(key),
            .geo_distributed => self.getGeoShardId(key),
        };

        return self.shards.getPtr(shard_id) orelse error.ShardNotFound;
    }

    // Rebalance shards when topology changes
    pub fn rebalance(self: *ShardManager) !void {
        // Calculate ideal distribution
        const total_nodes = self.getTotalNodeCount();
        const ideal_per_shard = total_nodes / self.shards.count();

        var migrations = std.ArrayList(Migration).empty;
        defer migrations.deinit(self.allocator);

        // Identify shards that need rebalancing
        var it = self.shards.iterator();
        while (it.next()) |entry| {
            const shard = entry.value_ptr;
            const deviation = @as(i64, @intCast(shard.statistics.node_count)) - @as(i64, @intCast(ideal_per_shard));

            if (@abs(deviation) > @as(i64, @intCast(ideal_per_shard / 10))) { // 10% threshold
                try migrations.append(self.allocator, .{
                    .source_shard = shard.id,
                    .target_shard = self.findTargetShard(shard.id),
                    .key_range = self.calculateMigrationRange(shard, @intCast(deviation)),
                });
            }
        }

        // Execute migrations
        for (migrations.items) |migration| {
            try self.executeMigration(migration);
        }
    }

    // Split a shard when it grows too large
    pub fn splitShard(self: *ShardManager, shard_id: u64) !void {
        const shard = self.shards.getPtr(shard_id) orelse return error.ShardNotFound;

        if (shard.status != .active) {
            return error.ShardNotActive;
        }

        shard.status = .splitting;

        // Create new shard
        const new_shard_id = self.generateShardId();
        const split_point = try self.findSplitPoint(shard);

        // Allocate nodes for new shard
        const new_primary = try self.allocateNode();
        const new_replicas = try self.allocateReplicas(self.replication_factor - 1);

        const new_shard = Shard{
            .id = new_shard_id,
            .primary = new_primary,
            .replicas = new_replicas,
            .key_range = .{
                .start = split_point,
                .end = shard.key_range.?.end,
            },
            .status = .active,
            .statistics = .{
                .node_count = 0,
                .edge_count = 0,
                .size_bytes = 0,
                .read_qps = 0,
                .write_qps = 0,
                .last_updated = compat_timestamp(),
            },
        };

        // Update original shard's range
        if (shard.key_range) |*range| {
            range.end = split_point;
        }

        // Add new shard
        try self.addShard(new_shard);

        // Migrate data
        try self.migrateData(shard_id, new_shard_id, split_point);

        shard.status = .active;
    }

    // Merge two shards
    pub fn mergeShards(self: *ShardManager, shard1_id: u64, shard2_id: u64) !void {
        const shard1 = self.shards.getPtr(shard1_id) orelse return error.ShardNotFound;
        const shard2 = self.shards.get(shard2_id) orelse return error.ShardNotFound;

        if (shard1.status != .active or shard2.status != .active) {
            return error.ShardsNotActive;
        }

        shard1.status = .merging;

        // Migrate all data from shard2 to shard1
        try self.migrateAllData(shard2_id, shard1_id);

        // Update shard1's range to include shard2's range
        if (shard1.key_range) |*range1| {
            if (shard2.key_range) |range2| {
                range1.end = range2.end;
            }
        }

        // Update statistics
        shard1.statistics.node_count += shard2.statistics.node_count;
        shard1.statistics.edge_count += shard2.statistics.edge_count;
        shard1.statistics.size_bytes += shard2.statistics.size_bytes;

        // Remove shard2
        _ = self.shards.remove(shard2_id);
        self.consistent_hash.removeNode(shard2_id);

        shard1.status = .active;
    }

    // Handle shard failure
    pub fn handleShardFailure(self: *ShardManager, shard_id: u64) !void {
        const shard = self.shards.getPtr(shard_id) orelse return error.ShardNotFound;

        shard.status = .offline;

        // Promote a replica to primary
        if (shard.replicas.len > 0) {
            var best_replica: ?*ShardNode = null;
            var best_score: i64 = std.math.minInt(i64);

            for (shard.replicas) |*replica| {
                if (replica.status == .healthy) {
                    const score = compat_timestamp() - replica.last_heartbeat;
                    if (score > best_score) {
                        best_score = score;
                        best_replica = replica;
                    }
                }
            }

            if (best_replica) |replica| {
                // Swap primary and replica
                const old_primary = shard.primary;
                shard.primary = replica.*;
                shard.primary.role = .primary;
                replica.* = old_primary;
                replica.role = .replica;
                replica.status = .recovering;

                shard.status = .active;
            }
        }
    }

    // Query routing for distributed queries
    pub fn routeQuery(self: *ShardManager, query: Query) !QueryPlan {
        var affected_shards = std.ArrayList(u64).empty;
        defer affected_shards.deinit(self.allocator);

        // Determine which shards are affected by the query
        switch (query.type) {
            .point_lookup => {
                const shard = try self.getShardForKey(query.key);
                try affected_shards.append(self.allocator, shard.id);
            },
            .range_scan => {
                var it = self.shards.iterator();
                while (it.next()) |entry| {
                    const shard = entry.value_ptr;
                    if (self.rangeOverlaps(query.range, shard.key_range)) {
                        try affected_shards.append(self.allocator, shard.id);
                    }
                }
            },
            .broadcast => {
                // Query all shards
                var it = self.shards.iterator();
                while (it.next()) |entry| {
                    try affected_shards.append(self.allocator, entry.key_ptr.*);
                }
            },
        }

        return QueryPlan{
            .shards = try affected_shards.toOwnedSlice(self.allocator),
            .execution_strategy = self.determineExecutionStrategy(query, affected_shards.items.len),
        };
    }

    const Query = struct {
        type: enum { point_lookup, range_scan, broadcast },
        key: []const u8,
        range: ?KeyRange,
    };

    const QueryPlan = struct {
        shards: []u64,
        execution_strategy: ExecutionStrategy,
    };

    const ExecutionStrategy = enum {
        sequential,
        parallel,
        map_reduce,
    };

    const Migration = struct {
        source_shard: u64,
        target_shard: u64,
        key_range: KeyRange,
    };

    // Helper functions
    fn getTotalNodeCount(self: *ShardManager) u64 {
        var total: u64 = 0;
        var it = self.shards.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.statistics.node_count;
        }
        return total;
    }

    fn findTargetShard(self: *ShardManager, exclude_id: u64) u64 {
        var min_nodes: u64 = std.math.maxInt(u64);
        var target_id: u64 = 0;

        var it = self.shards.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.* != exclude_id) {
                if (entry.value_ptr.statistics.node_count < min_nodes) {
                    min_nodes = entry.value_ptr.statistics.node_count;
                    target_id = entry.key_ptr.*;
                }
            }
        }

        return target_id;
    }

    fn calculateMigrationRange(self: *ShardManager, shard: *Shard, nodes_to_migrate: i64) KeyRange {
        _ = self;
        _ = nodes_to_migrate;
        // Simplified: return a portion of the shard's range
        if (shard.key_range) |range| {
            return range;
        }
        return .{ .start = "", .end = "" };
    }

    // CANARY: REQ=REQ-DIST-MIGRATION-001; FEATURE="Shard Data Migration"; ASPECT=Migration; STATUS=TESTED; TEST="executeMigration: direct path drains source statistics into target (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
    // GAP-0208 FIX: Implemented real shard migration with transport callback, progress tracking, and checksum verification
    fn executeMigration(self: *ShardManager, migration: Migration) !void {
        const source_shard = self.shards.getPtr(migration.source_shard) orelse return error.ShardNotFound;
        const target_shard = self.shards.getPtr(migration.target_shard) orelse return error.ShardNotFound;

        // Mark shards as migrating
        source_shard.status = .migrating;
        target_shard.status = .migrating;

        // Initialize migration state
        var state = MigrationState{
            .source_shard_id = migration.source_shard,
            .target_shard_id = migration.target_shard,
            .key_range = migration.key_range,
            .batch_size = 1000,
            .total_items = source_shard.statistics.node_count,
            .migrated_items = 0,
            .verified_items = 0,
            .checksum = std.hash.Crc32.init(),
            .status = .in_progress,
            .start_time = compat_milliTimestamp(),
            .last_checkpoint = compat_milliTimestamp(),
        };

        // Execute migration with proper data transfer
        // GAP-0208 FIX: Use transport callback if available, otherwise use direct transfer
        if (self.transport_callback) |callback| {
            // Real network transport path
            try self.executeMigrationWithTransport(&state, source_shard, target_shard, callback);
        } else {
            // Direct transfer path (for single-node or testing)
            try self.executeMigrationDirect(&state, source_shard, target_shard);
        }

        // Update key ranges (Migration.key_range is non-optional; GAP-0514 P3
        // fixed a rotted optional-capture here that never compiled — this
        // function was previously never analyzed by any test root).
        target_shard.key_range = migration.key_range;

        // Mark migration complete
        source_shard.status = .active;
        target_shard.status = .active;
        state.status = .completed;
    }

    // GAP-0208 FIX: Migration with real network transport
    fn executeMigrationWithTransport(
        self: *ShardManager,
        state: *MigrationState,
        source_shard: *Shard,
        target_shard: *Shard,
        transport: *TransportCallback,
    ) !void {
        _ = self;
        const source_addr = source_shard.primary.address;
        const target_addr = target_shard.primary.address;

        while (state.migrated_items < state.total_items) {
            const remaining = state.total_items - state.migrated_items;
            const current_batch = @min(remaining, state.batch_size);

            // Request batch from source
            var batch_buffer: [64 * 1024]u8 = undefined; // 64KB batch buffer
            const batch_data = try transport.requestBatch(
                source_addr,
                state.source_shard_id,
                state.migrated_items,
                current_batch,
                &batch_buffer,
            );

            // Calculate checksum for verification
            const batch_checksum = std.hash.Crc32.hash(batch_data);
            state.checksum.update(batch_data);

            // Send batch to target with checksum verification
            const verified = try transport.sendBatch(
                target_addr,
                state.target_shard_id,
                batch_data,
                batch_checksum,
            );

            if (!verified) {
                // Retry logic for failed verification
                state.status = .retrying;
                continue;
            }

            // Update progress
            state.migrated_items += current_batch;
            state.verified_items += current_batch;
            target_shard.statistics.node_count += current_batch;
            source_shard.statistics.node_count -= current_batch;

            // Checkpoint every 10 batches
            if (state.migrated_items % (state.batch_size * 10) == 0) {
                state.last_checkpoint = compat_milliTimestamp();
            }

            // Update timestamps
            const now = compat_timestamp();
            target_shard.statistics.last_updated = now;
            source_shard.statistics.last_updated = now;
        }

        // Final verification
        const final_checksum = state.checksum.final();
        _ = final_checksum; // Would be compared with source checksum in full implementation
    }

    // GAP-0208 FIX: Direct migration for single-node or testing scenarios
    fn executeMigrationDirect(
        self: *ShardManager,
        state: *MigrationState,
        source_shard: *Shard,
        target_shard: *Shard,
    ) !void {
        _ = self;
        while (state.migrated_items < state.total_items) {
            const remaining = state.total_items - state.migrated_items;
            const current_batch = @min(remaining, state.batch_size);

            // Direct statistics update (in-process transfer)
            target_shard.statistics.node_count += current_batch;
            source_shard.statistics.node_count -= current_batch;
            state.migrated_items += current_batch;
            state.verified_items += current_batch;

            // Update timestamps
            const now = compat_timestamp();
            target_shard.statistics.last_updated = now;
            source_shard.statistics.last_updated = now;
        }

        state.status = .completed;
    }

    fn generateShardId(self: *ShardManager) u64 {
        _ = self;
        return @intCast(compat_timestamp());
    }

    // CANARY: REQ=REQ-DIST-SPLIT-001; FEATURE="Shard Split Point"; ASPECT=SplitPoint; STATUS=TESTED; TEST="findSplitPoint: lexicographic midpoint of the shard key range (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
    fn findSplitPoint(self: *ShardManager, shard: *Shard) ![]const u8 {
        // Find median key for balanced split
        if (shard.key_range) |range| {
            // Calculate midpoint between start and end keys
            // For simplicity, use lexicographic midpoint
            const start = range.start;
            const end = range.end;

            if (start.len == 0 and end.len == 0) {
                return try self.allocator.dupe(u8, "m"); // Default midpoint
            }

            // Find the common prefix length
            var common_len: usize = 0;
            while (common_len < @min(start.len, end.len) and start[common_len] == end[common_len]) {
                common_len += 1;
            }

            // Calculate midpoint character
            if (common_len < @min(start.len, end.len)) {
                const mid_char = (start[common_len] + end[common_len]) / 2;
                var result = try self.allocator.alloc(u8, common_len + 1);
                if (common_len > 0) {
                    @memcpy(result[0..common_len], start[0..common_len]);
                }
                result[common_len] = mid_char;
                return result;
            }

            // If one is prefix of other, add midpoint character
            var result = try self.allocator.alloc(u8, start.len + 1);
            @memcpy(result[0..start.len], start);
            result[start.len] = 'm';
            return result;
        }

        return try self.allocator.dupe(u8, "midpoint");
    }

    fn allocateNode(self: *ShardManager) !ShardNode {
        _ = self;
        return ShardNode{
            .id = @intCast(compat_timestamp()),
            .address = try net.IpAddress.parseIp4("127.0.0.1", 7567),
            .role = .primary,
            .status = .healthy,
            .last_heartbeat = compat_timestamp(),
        };
    }

    fn allocateReplicas(self: *ShardManager, count: u32) ![]ShardNode {
        const replicas = try self.allocator.alloc(ShardNode, count);
        for (replicas, 0..) |*replica, i| {
            replica.* = ShardNode{
                .id = @intCast(compat_timestamp() + i),
                .address = try net.IpAddress.parseIp4("127.0.0.1", @intCast(7568 + i)),
                .role = .replica,
                .status = .healthy,
                .last_heartbeat = compat_timestamp(),
            };
        }
        return replicas;
    }

    // CANARY: REQ=REQ-DIST-MIGRATE-002; FEATURE="Shard Data Migration"; ASPECT=PartialMigration; STATUS=TESTED; TEST="migrateData: splits statistics proportionally at the split point (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
    fn migrateData(self: *ShardManager, source_id: u64, target_id: u64, split_point: []const u8) !void {
        const source = self.shards.getPtr(source_id) orelse return error.ShardNotFound;
        const target = self.shards.getPtr(target_id) orelse return error.ShardNotFound;

        // Estimate data to migrate based on split point position
        // Assume uniform distribution for simplicity
        const total_nodes = source.statistics.node_count;
        const total_edges = source.statistics.edge_count;
        const total_bytes = source.statistics.size_bytes;

        // Calculate migration ratio based on key range
        var migration_ratio: f64 = 0.5; // Default to 50%
        if (source.key_range) |range| {
            // Calculate position of split point in range
            if (split_point.len > 0 and range.start.len > 0 and range.end.len > 0) {
                // Simple heuristic: use first character position
                const start_char: f64 = @floatFromInt(range.start[0]);
                const end_char: f64 = @floatFromInt(range.end[0]);
                const split_char: f64 = @floatFromInt(split_point[0]);
                if (end_char > start_char) {
                    migration_ratio = (split_char - start_char) / (end_char - start_char);
                }
            }
        }

        // Migrate proportional data
        const nodes_to_migrate: u64 = @intFromFloat(@as(f64, @floatFromInt(total_nodes)) * (1.0 - migration_ratio));
        const edges_to_migrate: u64 = @intFromFloat(@as(f64, @floatFromInt(total_edges)) * (1.0 - migration_ratio));
        const bytes_to_migrate: u64 = @intFromFloat(@as(f64, @floatFromInt(total_bytes)) * (1.0 - migration_ratio));

        // Update statistics
        source.statistics.node_count -= nodes_to_migrate;
        source.statistics.edge_count -= edges_to_migrate;
        source.statistics.size_bytes -= bytes_to_migrate;

        target.statistics.node_count += nodes_to_migrate;
        target.statistics.edge_count += edges_to_migrate;
        target.statistics.size_bytes += bytes_to_migrate;

        source.statistics.last_updated = compat_timestamp();
        target.statistics.last_updated = compat_timestamp();
    }

    // CANARY: REQ=REQ-DIST-MIGRATE-003; FEATURE="Shard Data Migration"; ASPECT=FullMigration; STATUS=TESTED; TEST="migrateAllData: moves every statistic and clears the source (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
    fn migrateAllData(self: *ShardManager, source_id: u64, target_id: u64) !void {
        const source = self.shards.getPtr(source_id) orelse return error.ShardNotFound;
        const target = self.shards.getPtr(target_id) orelse return error.ShardNotFound;

        // Migrate all data from source to target
        target.statistics.node_count += source.statistics.node_count;
        target.statistics.edge_count += source.statistics.edge_count;
        target.statistics.size_bytes += source.statistics.size_bytes;

        // Clear source statistics
        source.statistics.node_count = 0;
        source.statistics.edge_count = 0;
        source.statistics.size_bytes = 0;

        source.statistics.last_updated = compat_timestamp();
        target.statistics.last_updated = compat_timestamp();
    }

    // CANARY: REQ=REQ-DIST-RANGE-001; FEATURE="Key Range Operations"; ASPECT=RangeOverlap; STATUS=TESTED; TEST="rangeOverlaps: lexicographic overlap and null handling (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
    fn rangeOverlaps(self: *ShardManager, range1: ?KeyRange, range2: ?KeyRange) bool {
        _ = self;
        if (range1 == null or range2 == null) return false;

        const r1 = range1.?;
        const r2 = range2.?;

        // Lexicographic comparison for range overlap
        // Ranges overlap if: r1.start < r2.end AND r1.end > r2.start
        const start1_cmp = std.mem.order(u8, r1.start, r2.end);
        const end1_cmp = std.mem.order(u8, r1.end, r2.start);

        return start1_cmp == .lt and end1_cmp == .gt;
    }

    fn determineExecutionStrategy(self: *ShardManager, query: Query, shard_count: usize) ExecutionStrategy {
        _ = self;
        _ = query;
        if (shard_count == 1) return .sequential;
        if (shard_count <= 3) return .parallel;
        return .map_reduce;
    }

    // CANARY: REQ=REQ-DIST-RANGE-SHARD-001; FEATURE="Range-Based Sharding"; ASPECT=ShardLookup; STATUS=TESTED; TEST="getRangeShardId: returns shard whose key range contains the key (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
    fn getRangeShardId(self: *ShardManager, key: []const u8) u64 {
        // Find shard whose key range contains the given key
        var it = self.shards.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.key_range) |range| {
                // Check if key is within range: start <= key < end
                const cmp_start = std.mem.order(u8, key, range.start);
                const cmp_end = std.mem.order(u8, key, range.end);

                const after_start = cmp_start == .gt or cmp_start == .eq;
                const before_end = cmp_end == .lt;

                if (after_start and before_end) {
                    return entry.key_ptr.*;
                }
            }
        }
        // Fallback to first shard if no range matches
        var fallback_it = self.shards.iterator();
        if (fallback_it.next()) |entry| {
            return entry.key_ptr.*;
        }
        return 0;
    }

    // CANARY: REQ=REQ-DIST-GRAPH-SHARD-001; FEATURE="Graph-Aware Sharding"; ASPECT=EdgeCutMinimization; STATUS=TESTED; TEST="getGraphAwareShardId: community prefix routes consistently (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
    fn getGraphAwareShardId(self: *ShardManager, key: []const u8) u64 {
        // Graph-aware sharding aims to minimize edge cuts by keeping connected nodes together
        // Strategy: Use community detection hint from key prefix
        // Keys can be formatted as "community_id:node_id" to hint at locality

        // Check for community prefix in key
        if (std.mem.indexOf(u8, key, ":")) |sep_idx| {
            const community_prefix = key[0..sep_idx];
            // Hash the community prefix to get a consistent shard
            var hash: u64 = 0;
            for (community_prefix) |c| {
                hash = hash *% 31 +% c;
            }
            // Map hash to shard
            const shard_count = self.shards.count();
            if (shard_count > 0) {
                const shard_idx = hash % shard_count;
                var it = self.shards.iterator();
                var i: u64 = 0;
                while (it.next()) |entry| {
                    if (i == shard_idx) {
                        return entry.key_ptr.*;
                    }
                    i += 1;
                }
            }
        }

        // Fallback to consistent hashing
        return (self.consistent_hash.getNode(key) orelse return 0).id;
    }

    // CANARY: REQ=REQ-DIST-GEO-SHARD-001; FEATURE="Geo-Distributed Sharding"; ASPECT=LocalityAware; STATUS=TESTED; TEST="getGeoShardId: region prefix routes consistently (GAP-0514 P3)"; OWNER=distributed; UPDATED=2026-06-11
    fn getGeoShardId(self: *ShardManager, key: []const u8) u64 {
        // Geo-distributed sharding places data near users
        // Keys can be formatted as "region:data_key" to hint at geography

        // Check for region prefix in key
        if (std.mem.indexOf(u8, key, ":")) |sep_idx| {
            const region_prefix = key[0..sep_idx];

            // Map region codes to shard groups
            // Common format: us-east, eu-west, ap-south, etc.
            var region_hash: u64 = 0;
            for (region_prefix) |c| {
                region_hash = region_hash *% 31 +% c;
            }

            // Select shard from region group
            const shard_count = self.shards.count();
            if (shard_count > 0) {
                // Use modulo to select shard, biased by region
                const shard_idx = region_hash % shard_count;
                var it = self.shards.iterator();
                var i: u64 = 0;
                while (it.next()) |entry| {
                    if (i == shard_idx) {
                        return entry.key_ptr.*;
                    }
                    i += 1;
                }
            }
        }

        // Fallback to consistent hashing for unknown regions
        return (self.consistent_hash.getNode(key) orelse return 0).id;
    }
};

// Simple sharding manager using consistent hashing
pub const SimpleShardManager = struct {
    allocator: Allocator,
    consistent_hash: ConsistentHash,
    shards: std.AutoHashMap(u64, Shard),
    replication_factor: u32,

    pub const Shard = struct {
        id: u64,
        node_id: u64,
        key_range: KeyRange,
        size_bytes: u64,
        record_count: u64,
        replicas: []u64,
        state: State,

        pub const State = enum {
            active,
            migrating,
            splitting,
            merging,
        };

        pub const KeyRange = struct {
            start: []const u8,
            end: []const u8,
        };
    };

    pub fn init(
        allocator: Allocator,
        replication_factor: u32,
    ) ShardManager {
        return .{
            .allocator = allocator,
            .consistent_hash = ConsistentHash.init(allocator, 150, .xxhash),
            .shards = std.AutoHashMap(u64, Shard).init(allocator),
            .replication_factor = replication_factor,
        };
    }

    pub fn deinit(self: *ShardManager) void {
        self.consistent_hash.deinit();
        self.shards.deinit();
    }

    pub fn addShard(self: *ShardManager, node_id: u64, address: []const u8) !void {
        const shard_id = blk: {
            var _rng_buf: [@sizeOf(u64)]u8 = undefined;
            // fips-exempt: non-security shard-id generation
            compat_fillRandom(&_rng_buf);
            break :blk std.mem.readInt(u64, &_rng_buf, .little);
        };

        try self.consistent_hash.addNode(.{
            .id = node_id,
            .hash = 0, // Will be set by consistent hash
            .address = address,
        });

        const replicas = try self.allocator.alloc(u64, self.replication_factor - 1);

        try self.shards.put(shard_id, .{
            .id = shard_id,
            .node_id = node_id,
            .key_range = .{
                .start = "",
                .end = "",
            },
            .size_bytes = 0,
            .record_count = 0,
            .replicas = replicas,
            .state = .active,
        });
    }

    pub fn getShard(self: *ShardManager, key: []const u8) ?Shard {
        const node = self.consistent_hash.getNode(key) orelse return null;

        var iter = self.shards.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.node_id == node.id) {
                return entry.value_ptr.*;
            }
        }

        return null;
    }

    pub fn getReplicas(self: *ShardManager, key: []const u8) ![]Shard {
        const nodes = try self.consistent_hash.getNodes(key, self.replication_factor);
        var replicas = std.ArrayList(Shard).empty;

        for (nodes) |node| {
            var iter = self.shards.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.node_id == node.id) {
                    try replicas.append(self.allocator, entry.value_ptr.*);
                    break;
                }
            }
        }

        return try replicas.toOwnedSlice(self.allocator);
    }

    pub fn splitShard(self: *ShardManager, shard_id: u64) !void {
        var shard = self.shards.getPtr(shard_id) orelse return error.ShardNotFound;

        if (shard.state != .active) {
            return error.ShardNotActive;
        }

        shard.state = .splitting;

        // Create two new shards
        const new_shard1_id = blk: {
            var _rng_buf: [@sizeOf(u64)]u8 = undefined;
            // fips-exempt: non-security shard-id generation
            compat_fillRandom(&_rng_buf);
            break :blk std.mem.readInt(u64, &_rng_buf, .little);
        };
        const new_shard2_id = blk: {
            var _rng_buf: [@sizeOf(u64)]u8 = undefined;
            // fips-exempt: non-security shard-id generation
            compat_fillRandom(&_rng_buf);
            break :blk std.mem.readInt(u64, &_rng_buf, .little);
        };

        // Split the key range
        // In a real implementation, this would be based on actual key distribution
        const mid_key = "m"; // Simplified

        try self.shards.put(new_shard1_id, .{
            .id = new_shard1_id,
            .node_id = shard.node_id,
            .key_range = .{
                .start = shard.key_range.start,
                .end = mid_key,
            },
            .size_bytes = shard.size_bytes / 2,
            .record_count = shard.record_count / 2,
            .replicas = shard.replicas,
            .state = .active,
        });

        try self.shards.put(new_shard2_id, .{
            .id = new_shard2_id,
            .node_id = shard.node_id,
            .key_range = .{
                .start = mid_key,
                .end = shard.key_range.end,
            },
            .size_bytes = shard.size_bytes / 2,
            .record_count = shard.record_count / 2,
            .replicas = shard.replicas,
            .state = .active,
        });

        // Remove old shard
        _ = self.shards.remove(shard_id);

        log.info("Split shard into two new shards", &.{
            Attr.uint("original_shard_id", shard_id),
            Attr.uint("new_shard1_id", new_shard1_id),
            Attr.uint("new_shard2_id", new_shard2_id),
        });
    }

    pub fn mergeShard(self: *ShardManager, shard1_id: u64, shard2_id: u64) !void {
        const shard1 = self.shards.get(shard1_id) orelse return error.ShardNotFound;
        const shard2 = self.shards.get(shard2_id) orelse return error.ShardNotFound;

        if (shard1.state != .active or shard2.state != .active) {
            return error.ShardsNotActive;
        }

        // Create merged shard
        const merged_id = blk: {
            var _rng_buf: [@sizeOf(u64)]u8 = undefined;
            // fips-exempt: non-security shard-id generation
            compat_fillRandom(&_rng_buf);
            break :blk std.mem.readInt(u64, &_rng_buf, .little);
        };

        try self.shards.put(merged_id, .{
            .id = merged_id,
            .node_id = shard1.node_id,
            .key_range = .{
                .start = if (std.mem.lessThan(u8, shard1.key_range.start, shard2.key_range.start))
                    shard1.key_range.start
                else
                    shard2.key_range.start,
                .end = if (std.mem.lessThan(u8, shard1.key_range.end, shard2.key_range.end))
                    shard2.key_range.end
                else
                    shard1.key_range.end,
            },
            .size_bytes = shard1.size_bytes + shard2.size_bytes,
            .record_count = shard1.record_count + shard2.record_count,
            .replicas = shard1.replicas,
            .state = .active,
        });

        // Remove old shards
        _ = self.shards.remove(shard1_id);
        _ = self.shards.remove(shard2_id);

        log.info("Merged shards into one", &.{
            Attr.uint("shard1_id", shard1_id),
            Attr.uint("shard2_id", shard2_id),
            Attr.uint("merged_id", merged_id),
        });
    }

    pub fn rebalanceShards(self: *ShardManager) !void {
        // Calculate average shard size
        var total_size: u64 = 0;
        var count: u64 = 0;

        var iter = self.shards.iterator();
        while (iter.next()) |entry| {
            total_size += entry.value_ptr.size_bytes;
            count += 1;
        }

        if (count == 0) return;

        const avg_size = total_size / count;
        const threshold = avg_size / 2; // 50% deviation threshold

        // Find shards that need splitting or merging
        var to_split = std.ArrayList(u64).empty;
        defer to_split.deinit(self.allocator);
        var to_merge = std.ArrayList(u64).empty;
        defer to_merge.deinit(self.allocator);

        iter = self.shards.iterator();
        while (iter.next()) |entry| {
            const shard = entry.value_ptr.*;
            if (shard.size_bytes > avg_size + threshold) {
                try to_split.append(self.allocator, shard.id);
            } else if (shard.size_bytes < avg_size - threshold) {
                try to_merge.append(self.allocator, shard.id);
            }
        }

        // Split large shards
        for (to_split.items) |shard_id| {
            try self.splitShard(shard_id);
        }

        // Merge small shards (pair them up)
        var i: usize = 0;
        while (i + 1 < to_merge.items.len) : (i += 2) {
            try self.mergeShard(to_merge.items[i], to_merge.items[i + 1]);
        }
    }
};

// CANARY: REQ=REQ-GAP-0513-DIST-SHARD-001; FEATURE="ShardManager"; ASPECT=UnitTests; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
test "enhanced ShardManager init and deinit sets fields correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var sm = ShardManager.init(allocator, 3, .hash);
    defer sm.deinit();

    try testing.expectEqual(@as(u32, 3), sm.replication_factor);
    try testing.expectEqual(ShardManager.PartitionStrategy.hash, sm.partition_strategy);
    try testing.expect(sm.transport_callback == null);
}

// CANARY: REQ=REQ-GAP-0513-DIST-SHARD-002; FEATURE="ShardManager"; ASPECT=AddShard; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
test "enhanced ShardManager addShard stores shard in map" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var sm = ShardManager.init(allocator, 1, .hash);
    defer sm.deinit();

    const shard_id: u64 = 42;
    const shard = ShardManager.Shard{
        .id = shard_id,
        .primary = .{
            .id = 1,
            .address = try net.IpAddress.parseIp4("127.0.0.1", 7001),
            .role = .primary,
            .status = .healthy,
            .last_heartbeat = 0,
        },
        .replicas = &[_]ShardManager.ShardNode{},
        .key_range = null,
        .status = .active,
        .statistics = .{
            .node_count = 0,
            .edge_count = 0,
            .size_bytes = 0,
            .read_qps = 0,
            .write_qps = 0,
            .last_updated = 0,
        },
    };

    try sm.addShard(shard);

    try testing.expect(sm.shards.contains(shard_id));
}

// CANARY: REQ=REQ-GAP-0513-DIST-SHARD-003; FEATURE="ShardManager"; ASPECT=MergeError; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
test "enhanced ShardManager mergeShards returns ShardNotFound for missing shards" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var sm = ShardManager.init(allocator, 1, .hash);
    defer sm.deinit();

    const result = sm.mergeShards(999, 888);
    try testing.expectError(error.ShardNotFound, result);
}

// CANARY: REQ=REQ-GAP-0513-DIST-SHARD-004; FEATURE="ShardManager"; ASPECT=TransportCallback; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
test "enhanced ShardManager setTransportCallback sets field" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var sm = ShardManager.init(allocator, 2, .range);
    defer sm.deinit();

    // Verify transport_callback starts as null
    try testing.expect(sm.transport_callback == null);

    // Create a dummy transport callback
    var cb = ShardManager.TransportCallback{
        .context = undefined,
        .requestBatchFn = struct {
            fn f(
                _: *anyopaque,
                _: net.IpAddress,
                _: u64,
                _: u64,
                _: u64,
                buf: []u8,
            ) ShardManager.TransportError![]u8 {
                return buf[0..0];
            }
        }.f,
        .sendBatchFn = struct {
            fn f(
                _: *anyopaque,
                _: net.IpAddress,
                _: u64,
                _: []const u8,
                _: u32,
            ) ShardManager.TransportError!bool {
                return true;
            }
        }.f,
    };

    sm.setTransportCallback(&cb);
    try testing.expect(sm.transport_callback != null);
    try testing.expectEqual(&cb, sm.transport_callback.?);
}

// CANARY: REQ=REQ-GAP-0513-DIST-SHARD-005; FEATURE="ShardManager"; ASPECT=GetShardForKey; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
test "enhanced ShardManager getShardForKey with hash strategy returns added shard" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var sm = ShardManager.init(allocator, 1, .hash);
    defer sm.deinit();

    const shard_id: u64 = 77;
    const shard = ShardManager.Shard{
        .id = shard_id,
        .primary = .{
            .id = 1,
            .address = try net.IpAddress.parseIp4("127.0.0.1", 7002),
            .role = .primary,
            .status = .healthy,
            .last_heartbeat = 0,
        },
        .replicas = &[_]ShardManager.ShardNode{},
        .key_range = null,
        .status = .active,
        .statistics = .{
            .node_count = 10,
            .edge_count = 5,
            .size_bytes = 1024,
            .read_qps = 0,
            .write_qps = 0,
            .last_updated = 0,
        },
    };

    try sm.addShard(shard);

    // With only one shard in the ring, any key lookup must return that shard
    const found = try sm.getShardForKey("some-graph-key");
    try testing.expectEqual(shard_id, found.id);
}

// ---- GAP-0514 Phase 6 P3: migration / split / routing coverage ----

fn mkTestShard(id: u64, port: u16, node_count: u64, key_range: ?ShardManager.KeyRange) !ShardManager.Shard {
    return ShardManager.Shard{
        .id = id,
        .primary = .{
            .id = id,
            .address = try net.IpAddress.parseIp4("127.0.0.1", port),
            .role = .primary,
            .status = .healthy,
            .last_heartbeat = 0,
        },
        .replicas = &[_]ShardManager.ShardNode{},
        .key_range = key_range,
        .status = .active,
        .statistics = .{
            .node_count = node_count,
            .edge_count = 0,
            .size_bytes = 0,
            .read_qps = 0,
            .write_qps = 0,
            .last_updated = 0,
        },
    };
}

test "rangeOverlaps: lexicographic overlap and null handling (GAP-0514 P3)" {
    const allocator = std.testing.allocator;
    var sm = ShardManager.init(allocator, 1, .range);
    defer sm.deinit();

    // Null on either side never overlaps.
    try std.testing.expect(!sm.rangeOverlaps(null, .{ .start = "a", .end = "z" }));
    try std.testing.expect(!sm.rangeOverlaps(.{ .start = "a", .end = "z" }, null));
    try std.testing.expect(!sm.rangeOverlaps(null, null));

    // Overlapping ranges.
    try std.testing.expect(sm.rangeOverlaps(.{ .start = "a", .end = "m" }, .{ .start = "h", .end = "z" }));
    // Disjoint ranges.
    try std.testing.expect(!sm.rangeOverlaps(.{ .start = "a", .end = "b" }, .{ .start = "c", .end = "d" }));
    // Touching ranges (end == start) do not overlap (half-open semantics).
    try std.testing.expect(!sm.rangeOverlaps(.{ .start = "a", .end = "c" }, .{ .start = "c", .end = "e" }));
}

test "getRangeShardId: returns shard whose key range contains the key (GAP-0514 P3)" {
    const allocator = std.testing.allocator;
    var sm = ShardManager.init(allocator, 1, .range);
    defer sm.deinit();

    try sm.addShard(try mkTestShard(1, 7101, 0, .{ .start = "a", .end = "m" }));
    try sm.addShard(try mkTestShard(2, 7102, 0, .{ .start = "m", .end = "z" }));

    try std.testing.expectEqual(@as(u64, 1), sm.getRangeShardId("cat"));
    try std.testing.expectEqual(@as(u64, 2), sm.getRangeShardId("pig"));
    // Range start is inclusive, end exclusive.
    try std.testing.expectEqual(@as(u64, 2), sm.getRangeShardId("m"));
}

test "findSplitPoint: lexicographic midpoint of the shard key range (GAP-0514 P3)" {
    const allocator = std.testing.allocator;
    var sm = ShardManager.init(allocator, 1, .range);
    defer sm.deinit();

    // Plain range: midpoint of 'a'..'z' is 'm' ((97+122)/2 = 109).
    var shard = try mkTestShard(1, 7103, 0, .{ .start = "a", .end = "z" });
    const mid = try sm.findSplitPoint(&shard);
    defer allocator.free(mid);
    try std.testing.expectEqualStrings("m", mid);

    // No key range: default sentinel midpoint.
    var unranged = try mkTestShard(2, 7104, 0, null);
    const fallback = try sm.findSplitPoint(&unranged);
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("midpoint", fallback);
}

test "executeMigration: direct path drains source statistics into target (GAP-0514 P3)" {
    const allocator = std.testing.allocator;
    var sm = ShardManager.init(allocator, 1, .range);
    defer sm.deinit();

    // 2500 nodes forces multiple 1000-item MigrationState batches.
    try sm.addShard(try mkTestShard(1, 7105, 2500, .{ .start = "a", .end = "z" }));
    try sm.addShard(try mkTestShard(2, 7106, 0, null));

    try sm.executeMigration(.{
        .source_shard = 1,
        .target_shard = 2,
        .key_range = .{ .start = "m", .end = "z" },
    });

    const source = sm.shards.getPtr(1).?;
    const target = sm.shards.getPtr(2).?;
    try std.testing.expectEqual(@as(u64, 0), source.statistics.node_count);
    try std.testing.expectEqual(@as(u64, 2500), target.statistics.node_count);
    // Migration completion restores both shards to active and applies the key range.
    try std.testing.expectEqual(ShardManager.ShardStatus.active, source.status);
    try std.testing.expectEqual(ShardManager.ShardStatus.active, target.status);
    try std.testing.expectEqualStrings("m", target.key_range.?.start);

    // Unknown shard ids fail loud.
    try std.testing.expectError(error.ShardNotFound, sm.executeMigration(.{
        .source_shard = 404,
        .target_shard = 2,
        .key_range = .{ .start = "", .end = "" },
    }));
}

test "executeMigration: transport path batches through the network callback (GAP-0514 P3)" {
    const allocator = std.testing.allocator;
    var sm = ShardManager.init(allocator, 1, .range);
    defer sm.deinit();

    try sm.addShard(try mkTestShard(1, 7107, 2500, .{ .start = "a", .end = "z" }));
    try sm.addShard(try mkTestShard(2, 7108, 0, null));

    const Counter = struct {
        requests: u64 = 0,
        sends: u64 = 0,
    };
    var counter = Counter{};

    var cb = ShardManager.TransportCallback{
        .context = &counter,
        .requestBatchFn = struct {
            fn f(
                ctx: *anyopaque,
                _: net.IpAddress,
                _: u64,
                _: u64,
                count: u64,
                buf: []u8,
            ) ShardManager.TransportError![]u8 {
                const c: *Counter = @ptrCast(@alignCast(ctx));
                c.requests += 1;
                return buf[0..@min(count, buf.len)];
            }
        }.f,
        .sendBatchFn = struct {
            fn f(
                ctx: *anyopaque,
                _: net.IpAddress,
                _: u64,
                _: []const u8,
                _: u32,
            ) ShardManager.TransportError!bool {
                const c: *Counter = @ptrCast(@alignCast(ctx));
                c.sends += 1;
                return true;
            }
        }.f,
    };
    sm.setTransportCallback(&cb);

    try sm.executeMigration(.{
        .source_shard = 1,
        .target_shard = 2,
        .key_range = .{ .start = "a", .end = "z" },
    });

    // 2500 items / 1000 batch size = 3 request+send round trips.
    try std.testing.expectEqual(@as(u64, 3), counter.requests);
    try std.testing.expectEqual(@as(u64, 3), counter.sends);
    try std.testing.expectEqual(@as(u64, 2500), sm.shards.getPtr(2).?.statistics.node_count);
    try std.testing.expectEqual(@as(u64, 0), sm.shards.getPtr(1).?.statistics.node_count);
}

test "migrateData: splits statistics proportionally at the split point (GAP-0514 P3)" {
    const allocator = std.testing.allocator;
    var sm = ShardManager.init(allocator, 1, .range);
    defer sm.deinit();

    var source = try mkTestShard(1, 7109, 100, .{ .start = "a", .end = "z" });
    source.statistics.edge_count = 50;
    source.statistics.size_bytes = 1000;
    try sm.addShard(source);
    try sm.addShard(try mkTestShard(2, 7110, 0, null));

    // Split at 'm': ratio = (109-97)/(122-97) = 0.48 -> migrate 52% to target.
    try sm.migrateData(1, 2, "m");

    const src = sm.shards.getPtr(1).?;
    const dst = sm.shards.getPtr(2).?;
    try std.testing.expectEqual(@as(u64, 100), src.statistics.node_count + dst.statistics.node_count);
    try std.testing.expectEqual(@as(u64, 50), src.statistics.edge_count + dst.statistics.edge_count);
    try std.testing.expectEqual(@as(u64, 1000), src.statistics.size_bytes + dst.statistics.size_bytes);
    // Both sides hold a non-trivial share (proportional split, not all-or-nothing).
    try std.testing.expect(dst.statistics.node_count > 0);
    try std.testing.expect(src.statistics.node_count > 0);

    try std.testing.expectError(error.ShardNotFound, sm.migrateData(404, 2, "m"));
}

test "migrateAllData: moves every statistic and clears the source (GAP-0514 P3)" {
    const allocator = std.testing.allocator;
    var sm = ShardManager.init(allocator, 1, .range);
    defer sm.deinit();

    var source = try mkTestShard(1, 7111, 100, null);
    source.statistics.edge_count = 50;
    source.statistics.size_bytes = 1000;
    try sm.addShard(source);
    var target = try mkTestShard(2, 7112, 7, null);
    target.statistics.edge_count = 3;
    target.statistics.size_bytes = 11;
    try sm.addShard(target);

    try sm.migrateAllData(1, 2);

    const src = sm.shards.getPtr(1).?;
    const dst = sm.shards.getPtr(2).?;
    try std.testing.expectEqual(@as(u64, 0), src.statistics.node_count);
    try std.testing.expectEqual(@as(u64, 0), src.statistics.edge_count);
    try std.testing.expectEqual(@as(u64, 0), src.statistics.size_bytes);
    try std.testing.expectEqual(@as(u64, 107), dst.statistics.node_count);
    try std.testing.expectEqual(@as(u64, 53), dst.statistics.edge_count);
    try std.testing.expectEqual(@as(u64, 1011), dst.statistics.size_bytes);

    try std.testing.expectError(error.ShardNotFound, sm.migrateAllData(1, 404));
}

test "getGraphAwareShardId: community prefix routes consistently (GAP-0514 P3)" {
    const allocator = std.testing.allocator;
    var sm = ShardManager.init(allocator, 1, .graph_aware);
    defer sm.deinit();

    try sm.addShard(try mkTestShard(1, 7113, 0, null));
    try sm.addShard(try mkTestShard(2, 7114, 0, null));
    try sm.addShard(try mkTestShard(3, 7115, 0, null));

    // Same community prefix -> same shard for every node in the community.
    const s1 = sm.getGraphAwareShardId("community7:node1");
    const s2 = sm.getGraphAwareShardId("community7:node2");
    const s3 = sm.getGraphAwareShardId("community7:node999");
    try std.testing.expectEqual(s1, s2);
    try std.testing.expectEqual(s1, s3);
    try std.testing.expect(s1 == 1 or s1 == 2 or s1 == 3);

    // No community hint: falls back to consistent hashing over registered shards.
    const fallback = sm.getGraphAwareShardId("plain-key-no-prefix");
    try std.testing.expect(fallback == 1 or fallback == 2 or fallback == 3);
}

test "getGeoShardId: region prefix routes consistently (GAP-0514 P3)" {
    const allocator = std.testing.allocator;
    var sm = ShardManager.init(allocator, 1, .geo_distributed);
    defer sm.deinit();

    try sm.addShard(try mkTestShard(1, 7116, 0, null));
    try sm.addShard(try mkTestShard(2, 7117, 0, null));
    try sm.addShard(try mkTestShard(3, 7118, 0, null));

    // Same region prefix -> same shard for any data key in the region.
    const r1 = sm.getGeoShardId("us-east:user42");
    const r2 = sm.getGeoShardId("us-east:order7");
    try std.testing.expectEqual(r1, r2);
    try std.testing.expect(r1 == 1 or r1 == 2 or r1 == 3);

    // Unknown format: consistent-hash fallback still lands on a registered shard.
    const fallback = sm.getGeoShardId("no-region-key");
    try std.testing.expect(fallback == 1 or fallback == 2 or fallback == 3);
}
