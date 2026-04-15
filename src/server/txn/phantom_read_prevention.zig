const std = @import("std");

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
const mvcc = @import("mvcc.zig");

// CANARY: REQ=REQ-TXN-PHANTOM-001; FEATURE="Phantom Read Prevention"; ASPECT=PhantomReadPrevention; STATUS=TESTED; TEST=TestCANARY_REQ_TXN_PHANTOM_001_BasicPhantomPrevention; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-PHANTOM-002; FEATURE="Phantom Read Prevention"; ASPECT=PredicateLocks; STATUS=TESTED; TEST=TestCANARY_REQ_TXN_PHANTOM_002_PredicateLocks; OWNER=txn; UPDATED=2025-10-05
// CANARY: REQ=REQ-TXN-PHANTOM-003; FEATURE="Phantom Read Prevention"; ASPECT=RangeQueryValidation; STATUS=TESTED; TEST=TestCANARY_REQ_TXN_PHANTOM_003_RangeQueryValidation; OWNER=txn; UPDATED=2025-10-05

/// Predicate lock for phantom read prevention
pub const PredicateLock = struct {
    txn_id: mvcc.TxnId,
    label: []const u8,
    property: ?[]const u8,
    range: ?PropertyRange = null,
    condition: QueryCondition,
    timestamp: mvcc.Timestamp,

    pub fn overlaps(self: PredicateLock, other: PredicateLock) bool {
        // Check if two predicate locks overlap
        if (!std.mem.eql(u8, self.label, other.label)) {
            return false;
        }

        // Property-specific overlap check
        if (self.property) |prop1| {
            if (other.property) |prop2| {
                if (!std.mem.eql(u8, prop1, prop2)) {
                    return false;
                }
            }
        }

        // Range overlap check
        if (self.range) |range1| {
            if (other.range) |range2| {
                return range1.overlaps(range2);
            }
        }

        return self.condition.overlaps(other.condition);
    }
};

/// Property range for range queries
pub const PropertyRange = struct {
    min_value: ?PropertyValue = null,
    max_value: ?PropertyValue = null,
    min_inclusive: bool = true,
    max_inclusive: bool = true,

    pub fn overlaps(self: PropertyRange, other: PropertyRange) bool {
        // Check if two ranges overlap
        if (self.max_value) |max1| {
            if (other.min_value) |min2| {
                const cmp = comparePropertyValues(max1, min2);
                if (cmp < 0 or (cmp == 0 and (!self.max_inclusive or !other.min_inclusive))) {
                    return false;
                }
            }
        }

        if (self.min_value) |min1| {
            if (other.max_value) |max2| {
                const cmp = comparePropertyValues(min1, max2);
                if (cmp > 0 or (cmp == 0 and (!self.min_inclusive or !other.max_inclusive))) {
                    return false;
                }
            }
        }

        return true;
    }

    pub fn contains(self: PropertyRange, value: PropertyValue) bool {
        if (self.min_value) |min_val| {
            const cmp = comparePropertyValues(value, min_val);
            if (cmp < 0 or (cmp == 0 and !self.min_inclusive)) {
                return false;
            }
        }

        if (self.max_value) |max_val| {
            const cmp = comparePropertyValues(value, max_val);
            if (cmp > 0 or (cmp == 0 and !self.max_inclusive)) {
                return false;
            }
        }

        return true;
    }
};

/// Property value for range comparisons
pub const PropertyValue = union(enum) {
    Int: i64,
    Float: f64,
    String: []const u8,
    Bool: bool,
    Null,
};

/// Query condition for predicate locks
pub const QueryCondition = struct {
    type: ConditionType,
    property: ?[]const u8 = null,
    value: ?PropertyValue = null,

    pub const ConditionType = enum {
        LabelScan, // MATCH (n:Label)
        PropertyEqual, // WHERE n.prop = value
        PropertyRange, // WHERE n.prop > value, n.prop BETWEEN x AND y
        PropertyExists, // WHERE EXISTS(n.prop)
        Complex, // Complex conditions requiring conservative locking
    };

    pub fn overlaps(self: QueryCondition, other: QueryCondition) bool {
        // Conservative approach: overlapping if same type and property
        if (self.type != other.type) {
            return self.type == .Complex or other.type == .Complex;
        }

        if (self.property) |prop1| {
            if (other.property) |prop2| {
                return std.mem.eql(u8, prop1, prop2);
            }
        }

        return true; // Conservative: assume overlap if uncertain
    }
};

/// Phantom read prevention manager
pub const PhantomReadPrevention = struct {
    allocator: std.mem.Allocator,
    predicate_locks: std.ArrayList(PredicateLock),
    query_tracker: QueryTracker,

    /// Track read queries to detect potential phantom reads
    pub const QueryTracker = struct {
        queries: std.AutoHashMap(mvcc.TxnId, std.ArrayList(ReadQuery)),
        allocator: std.mem.Allocator,

        pub const ReadQuery = struct {
            txn_id: mvcc.TxnId,
            label: []const u8,
            conditions: []QueryCondition,
            result_count: u32,
            timestamp: mvcc.Timestamp,
        };

        pub fn init(allocator: std.mem.Allocator) QueryTracker {
            return QueryTracker{
                .queries = std.AutoHashMap(mvcc.TxnId, std.ArrayList(ReadQuery)).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *QueryTracker) void {
            var iter = self.queries.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.queries.deinit();
        }

        pub fn recordQuery(self: *QueryTracker, query: ReadQuery) !void {
            var txn_queries = self.queries.get(query.txn_id) orelse blk: {
                const list = std.ArrayList(ReadQuery).init(self.allocator);
                try self.queries.put(query.txn_id, list);
                break :blk self.queries.get(query.txn_id).?;
            };
            try txn_queries.append(query);
        }

        pub fn getQueries(self: *QueryTracker, txn_id: mvcc.TxnId) ?[]ReadQuery {
            if (self.queries.get(txn_id)) |queries| {
                return queries.items;
            }
            return null;
        }

        pub fn clearTransaction(self: *QueryTracker, txn_id: mvcc.TxnId) void {
            if (self.queries.getPtr(txn_id)) |queries| {
                queries.deinit();
                _ = self.queries.remove(txn_id);
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) PhantomReadPrevention {
        return PhantomReadPrevention{
            .allocator = allocator,
            .predicate_locks = std.ArrayList(PredicateLock).init(allocator),
            .query_tracker = QueryTracker.init(allocator),
        };
    }

    pub fn deinit(self: *PhantomReadPrevention) void {
        self.predicate_locks.deinit();
        self.query_tracker.deinit();
    }

    /// Acquire a predicate lock for a query
    pub fn acquirePredicateLock(
        self: *PhantomReadPrevention,
        txn_id: mvcc.TxnId,
        label: []const u8,
        conditions: []QueryCondition,
        timestamp: mvcc.Timestamp,
    ) !bool {
        // Create predicate lock based on query conditions
        for (conditions) |condition| {
            const pred_lock = PredicateLock{
                .txn_id = txn_id,
                .label = try self.allocator.dupe(u8, label),
                .property = if (condition.property) |prop| try self.allocator.dupe(u8, prop) else null,
                .range = extractRange(condition),
                .condition = condition,
                .timestamp = timestamp,
            };

            // Check for conflicts with existing predicate locks
            for (self.predicate_locks.items) |existing| {
                if (existing.txn_id != txn_id and existing.overlaps(pred_lock)) {
                    // Conflict detected - wait or abort based on deadlock detection
                    return false;
                }
            }

            try self.predicate_locks.append(pred_lock);
        }

        return true;
    }

    /// Check if a write operation would violate existing predicate locks
    pub fn checkWriteConflict(
        self: *PhantomReadPrevention,
        txn_id: mvcc.TxnId,
        label: []const u8,
        properties: []const PropertyBinding,
    ) !?mvcc.ConflictInfo {
        for (self.predicate_locks.items) |pred_lock| {
            if (pred_lock.txn_id == txn_id) continue;

            // Check if write would make this tuple visible to the predicate
            if (std.mem.eql(u8, pred_lock.label, label)) {
                if (wouldSatisfyPredicate(pred_lock, properties)) {
                    return mvcc.ConflictInfo{
                        .conflicting_txn = pred_lock.txn_id,
                        .resource_id = computePredicateId(pred_lock),
                        .conflict_type = .PhantomRead,
                        .timestamp = compat_timestamp(),
                    };
                }
            }
        }

        return null;
    }

    /// Validate that read queries haven't been affected by phantom reads
    pub fn validateReadSet(
        self: *PhantomReadPrevention,
        txn_id: mvcc.TxnId,
        writes_since_snapshot: []WriteOperation,
    ) !bool {
        const queries = self.query_tracker.getQueries(txn_id) orelse return true;

        for (queries) |query| {
            // Check if any writes since snapshot would have affected this query
            for (writes_since_snapshot) |write| {
                if (std.mem.eql(u8, write.label, query.label)) {
                    // Check if the written tuple would satisfy the query conditions
                    if (wouldSatisfyConditions(query.conditions, write.properties)) {
                        // Phantom read detected
                        return false;
                    }
                }
            }
        }

        return true;
    }

    /// Release predicate locks for a transaction
    pub fn releasePredicateLocks(self: *PhantomReadPrevention, txn_id: mvcc.TxnId) void {
        var i: usize = 0;
        while (i < self.predicate_locks.items.len) {
            if (self.predicate_locks.items[i].txn_id == txn_id) {
                const removed = self.predicate_locks.swapRemove(i);
                self.allocator.free(removed.label);
                if (removed.property) |prop| {
                    self.allocator.free(prop);
                }
            } else {
                i += 1;
            }
        }

        self.query_tracker.clearTransaction(txn_id);
    }

    /// Record a read query for later validation
    pub fn recordReadQuery(
        self: *PhantomReadPrevention,
        txn_id: mvcc.TxnId,
        label: []const u8,
        conditions: []QueryCondition,
        result_count: u32,
        timestamp: mvcc.Timestamp,
    ) !void {
        const query = QueryTracker.ReadQuery{
            .txn_id = txn_id,
            .label = try self.allocator.dupe(u8, label),
            .conditions = try self.allocator.dupe(QueryCondition, conditions),
            .result_count = result_count,
            .timestamp = timestamp,
        };

        try self.query_tracker.recordQuery(query);
    }

    /// CANARY: REQ=REQ-TXN-PHANTOM-004; FEATURE="Phantom Read Prevention"; ASPECT=PredicateConflictCheck; STATUS=TESTED; TEST=geodetestlab/specs/gql_transaction_management_comprehensive.yml; OWNER=txn; UPDATED=2025-12-30
    /// Check if a write to a resource would conflict with existing predicate locks
    pub fn checkPredicateConflicts(self: *PhantomReadPrevention, txn_id: mvcc.TxnId, resource_id: u64) bool {
        // Check if any existing predicate lock from another transaction
        // would be affected by a write to this resource
        _ = resource_id; // Resource ID used for lookup in more advanced implementations

        for (self.predicate_locks.items) |pred_lock| {
            if (pred_lock.txn_id != txn_id) {
                // Conservative check: if there are any predicate locks from other transactions,
                // we consider it a potential conflict since we don't have full tuple information
                // In a more sophisticated implementation, we would check if the written tuple
                // satisfies the predicate lock's conditions
                return true;
            }
        }

        return false;
    }

    /// Get phantom read statistics for monitoring
    pub fn getStatistics(self: *PhantomReadPrevention) PhantomReadStats {
        var active_predicate_locks: u32 = 0;
        var active_transactions: u32 = 0;

        // Count active predicate locks
        active_predicate_locks = @intCast(self.predicate_locks.items.len);

        // Count active transactions with queries
        active_transactions = @intCast(self.query_tracker.queries.count());

        return PhantomReadStats{
            .active_predicate_locks = active_predicate_locks,
            .active_transactions_with_queries = active_transactions,
        };
    }
};

/// Statistics for phantom read prevention monitoring
pub const PhantomReadStats = struct {
    active_predicate_locks: u32,
    active_transactions_with_queries: u32,
};

/// Property binding for write operations
pub const PropertyBinding = struct {
    name: []const u8,
    value: PropertyValue,
};

/// Write operation for phantom read validation
pub const WriteOperation = struct {
    label: []const u8,
    properties: []PropertyBinding,
    timestamp: mvcc.Timestamp,
};

// Helper functions

fn extractRange(condition: QueryCondition) ?PropertyRange {
    return switch (condition.type) {
        .PropertyRange => if (condition.value) |val| PropertyRange{
            .min_value = val,
            .max_value = val,
        } else null,
        else => null,
    };
}

fn wouldSatisfyPredicate(pred_lock: PredicateLock, properties: []const PropertyBinding) bool {
    return switch (pred_lock.condition.type) {
        .LabelScan => true, // Any tuple with this label satisfies label scan
        .PropertyEqual => {
            if (pred_lock.condition.property) |prop_name| {
                for (properties) |prop| {
                    if (std.mem.eql(u8, prop.name, prop_name)) {
                        if (pred_lock.condition.value) |expected| {
                            return comparePropertyValues(prop.value, expected) == 0;
                        }
                    }
                }
            }
            return false;
        },
        .PropertyRange => {
            if (pred_lock.range) |range| {
                if (pred_lock.condition.property) |prop_name| {
                    for (properties) |prop| {
                        if (std.mem.eql(u8, prop.name, prop_name)) {
                            return range.contains(prop.value);
                        }
                    }
                }
            }
            return false;
        },
        .PropertyExists => {
            if (pred_lock.condition.property) |prop_name| {
                for (properties) |prop| {
                    if (std.mem.eql(u8, prop.name, prop_name)) {
                        return true;
                    }
                }
            }
            return false;
        },
        .Complex => true, // Conservative: assume complex conditions are satisfied
    };
}

fn wouldSatisfyConditions(conditions: []QueryCondition, properties: []PropertyBinding) bool {
    for (conditions) |condition| {
        // Create a temporary predicate lock to reuse logic
        const temp_pred = PredicateLock{
            .txn_id = 0,
            .label = "",
            .property = condition.property,
            .range = extractRange(condition),
            .condition = condition,
            .timestamp = 0,
        };

        if (wouldSatisfyPredicate(temp_pred, properties)) {
            return true;
        }
    }
    return false;
}

fn comparePropertyValues(a: PropertyValue, b: PropertyValue) i8 {
    return switch (a) {
        .Int => |val_a| switch (b) {
            .Int => |val_b| if (val_a < val_b) @as(i8, -1) else if (val_a > val_b) @as(i8, 1) else @as(i8, 0),
            else => 0,
        },
        .Float => |val_a| switch (b) {
            .Float => |val_b| if (val_a < val_b) @as(i8, -1) else if (val_a > val_b) @as(i8, 1) else @as(i8, 0),
            else => 0,
        },
        .String => |val_a| switch (b) {
            .String => |val_b| blk: {
                const cmp = std.mem.order(u8, val_a, val_b);
                break :blk switch (cmp) {
                    .lt => @as(i8, -1),
                    .gt => @as(i8, 1),
                    .eq => @as(i8, 0),
                };
            },
            else => 0,
        },
        .Bool => |val_a| switch (b) {
            .Bool => |val_b| if (val_a == val_b) @as(i8, 0) else if (val_a) @as(i8, 1) else @as(i8, -1),
            else => 0,
        },
        .Null => switch (b) {
            .Null => 0,
            else => -1,
        },
    };
}

fn computePredicateId(pred_lock: PredicateLock) u64 {
    // Compute a hash-based ID for the predicate lock
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(pred_lock.label);
    if (pred_lock.property) |prop| {
        hasher.update(prop);
    }
    return hasher.final();
}

// Tests for phantom read prevention

test "TestCANARY_REQ_TXN_PHANTOM_001_BasicPhantomPrevention" {
    const allocator = std.testing.allocator;

    var phantom_prev = PhantomReadPrevention.init(allocator);
    defer phantom_prev.deinit();

    // Transaction 1 reads all Person nodes
    const txn1_id: mvcc.TxnId = 1;
    const conditions = [_]QueryCondition{
        .{ .type = .LabelScan },
    };

    // Acquire predicate lock for label scan
    const acquired = try phantom_prev.acquirePredicateLock(
        txn1_id,
        "Person",
        &conditions,
        100,
    );
    try std.testing.expect(acquired);

    // Transaction 2 tries to insert a new Person
    const txn2_id: mvcc.TxnId = 2;
    const properties = [_]PropertyBinding{
        .{ .name = "name", .value = .{ .String = "Alice" } },
        .{ .name = "age", .value = .{ .Int = 30 } },
    };

    // Check for write conflict
    const conflict = try phantom_prev.checkWriteConflict(txn2_id, "Person", &properties);
    try std.testing.expect(conflict != null);
    try std.testing.expect(conflict.?.conflict_type == .PhantomRead);
    try std.testing.expect(conflict.?.conflicting_txn == txn1_id);
}

test "TestCANARY_REQ_TXN_PHANTOM_002_PredicateLocks" {
    const allocator = std.testing.allocator;

    var phantom_prev = PhantomReadPrevention.init(allocator);
    defer phantom_prev.deinit();

    // Transaction reads Person nodes with age > 25
    const txn_id: mvcc.TxnId = 1;
    const conditions = [_]QueryCondition{
        .{
            .type = .PropertyRange,
            .property = "age",
            .value = .{ .Int = 25 },
        },
    };

    const acquired = try phantom_prev.acquirePredicateLock(
        txn_id,
        "Person",
        &conditions,
        100,
    );
    try std.testing.expect(acquired);

    // Test overlapping predicate lock conflict
    const other_txn_id: mvcc.TxnId = 2;
    const overlapping_conditions = [_]QueryCondition{
        .{
            .type = .PropertyRange,
            .property = "age",
            .value = .{ .Int = 30 },
        },
    };

    const overlapping_acquired = try phantom_prev.acquirePredicateLock(
        other_txn_id,
        "Person",
        &overlapping_conditions,
        101,
    );
    try std.testing.expect(!overlapping_acquired); // Should conflict

    // Non-overlapping predicate should succeed
    const non_overlapping_conditions = [_]QueryCondition{
        .{ .type = .LabelScan },
    };

    const non_overlap_acquired = try phantom_prev.acquirePredicateLock(
        other_txn_id,
        "Company", // Different label
        &non_overlapping_conditions,
        102,
    );
    try std.testing.expect(non_overlap_acquired);
}

test "TestCANARY_REQ_TXN_PHANTOM_003_RangeQueryValidation" {
    const allocator = std.testing.allocator;

    var phantom_prev = PhantomReadPrevention.init(allocator);
    defer phantom_prev.deinit();

    // Record a range query
    const txn_id: mvcc.TxnId = 1;
    const conditions = [_]QueryCondition{
        .{
            .type = .PropertyRange,
            .property = "score",
            .value = .{ .Float = 85.0 },
        },
    };

    try phantom_prev.recordReadQuery(
        txn_id,
        "Student",
        &conditions,
        5, // Found 5 students
        100,
    );

    // Simulate writes that occurred after the query snapshot
    const writes = [_]WriteOperation{
        .{
            .label = "Student",
            .properties = &[_]PropertyBinding{
                .{ .name = "score", .value = .{ .Float = 90.0 } }, // Would satisfy query
                .{ .name = "name", .value = .{ .String = "Bob" } },
            },
            .timestamp = 105,
        },
        .{
            .label = "Student",
            .properties = &[_]PropertyBinding{
                .{ .name = "score", .value = .{ .Float = 70.0 } }, // Would not satisfy query
                .{ .name = "name", .value = .{ .String = "Charlie" } },
            },
            .timestamp = 106,
        },
    };

    // Validation should fail due to phantom read
    const is_valid = try phantom_prev.validateReadSet(txn_id, &writes);
    try std.testing.expect(!is_valid);
}

test "Property range overlap detection" {
    const range1 = PropertyRange{
        .min_value = .{ .Int = 10 },
        .max_value = .{ .Int = 20 },
    };

    const range2 = PropertyRange{
        .min_value = .{ .Int = 15 },
        .max_value = .{ .Int = 25 },
    };

    const range3 = PropertyRange{
        .min_value = .{ .Int = 25 },
        .max_value = .{ .Int = 30 },
    };

    try std.testing.expect(range1.overlaps(range2)); // [10,20] overlaps [15,25]
    try std.testing.expect(!range1.overlaps(range3)); // [10,20] doesn't overlap [25,30]
    try std.testing.expect(range2.overlaps(range3)); // [15,25] overlaps [25,30] at boundary
}

test "Property value comparison" {
    const val1 = PropertyValue{ .Int = 10 };
    const val2 = PropertyValue{ .Int = 20 };
    const val3 = PropertyValue{ .Int = 10 };

    try std.testing.expect(comparePropertyValues(val1, val2) < 0);
    try std.testing.expect(comparePropertyValues(val2, val1) > 0);
    try std.testing.expect(comparePropertyValues(val1, val3) == 0);

    const str1 = PropertyValue{ .String = "apple" };
    const str2 = PropertyValue{ .String = "banana" };

    try std.testing.expect(comparePropertyValues(str1, str2) < 0);
    try std.testing.expect(comparePropertyValues(str2, str1) > 0);
}
