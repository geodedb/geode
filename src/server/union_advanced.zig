const std = @import("std");
const value_types = @import("../value_types.zig");

// Advanced UNION type inference and optimization system
pub const UnionTypeInference = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UnionTypeInference {
        return .{ .allocator = allocator };
    }

    // Enhanced type compatibility checking for UNION operations
    pub fn inferUnionTypes(
        self: *UnionTypeInference,
        left_cols: []const []const u8,
        right_cols: []const []const u8,
        left_rows: []const []const value_types.Value,
        right_rows: []const []const value_types.Value,
    ) ![]UnionColumnType {
        if (left_cols.len != right_cols.len) {
            return error.ColumnCountMismatch;
        }

        var result_types = try self.allocator.alloc(UnionColumnType, left_cols.len);

        for (left_cols, 0..) |left_col, i| {
            const right_col = right_cols[i];

            // Analyze types from sample data
            const left_type = try self.inferColumnType(i, left_rows);
            const right_type = try self.inferColumnType(i, right_rows);

            // Determine compatible result type
            result_types[i] = UnionColumnType{
                .name = try self.reconcileColumnName(left_col, right_col),
                .unified_type = try self.unifyTypes(left_type, right_type),
                .left_type = left_type,
                .right_type = right_type,
                .requires_conversion = !std.mem.eql(u8, left_type, right_type),
            };
        }

        return result_types;
    }

    // Infer column type from sample data
    pub fn inferColumnType(self: *UnionTypeInference, col_idx: usize, rows: []const []const value_types.Value) ![]const u8 {
        var type_counts = std.StringHashMap(u32).init(self.allocator);
        defer type_counts.deinit();

        // Sample up to 100 rows for type inference
        const sample_size = @min(rows.len, 100);

        for (rows[0..sample_size]) |row| {
            if (col_idx >= row.len) continue;
            const value = row[col_idx];
            const type_name = typeNameForValue(value);
            const current = type_counts.get(type_name) orelse 0;
            try type_counts.put(type_name, current + 1);
        }

        // Find most common type
        var max_count: u32 = 0;
        var dominant_type: []const u8 = "MIXED";

        var iter = type_counts.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* > max_count) {
                max_count = entry.value_ptr.*;
                dominant_type = entry.key_ptr.*;
            }
        }

        return self.allocator.dupe(u8, dominant_type) catch "MIXED";
    }

    // Reconcile column names from different UNION branches
    fn reconcileColumnName(self: *UnionTypeInference, left_name: []const u8, right_name: []const u8) ![]const u8 {
        if (std.mem.eql(u8, left_name, right_name)) {
            return self.allocator.dupe(u8, left_name);
        }

        // Create combined name for mismatched columns
        return std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ left_name, right_name });
    }

    // Advanced type unification with compatibility rules
    fn unifyTypes(self: *UnionTypeInference, left_type: []const u8, right_type: []const u8) ![]const u8 {
        if (std.mem.eql(u8, left_type, right_type)) {
            return self.allocator.dupe(u8, left_type);
        }

        // Numeric type unification rules
        if (isNumericType(left_type) and isNumericType(right_type)) {
            // INT + DECIMAL = DECIMAL
            if ((std.mem.eql(u8, left_type, "INT") and std.mem.eql(u8, right_type, "DECIMAL")) or
                (std.mem.eql(u8, left_type, "DECIMAL") and std.mem.eql(u8, right_type, "INT")))
            {
                return self.allocator.dupe(u8, "DECIMAL");
            }
        }

        // NULL unification rules
        if (std.mem.eql(u8, left_type, "NULL")) {
            return self.allocator.dupe(u8, right_type);
        }
        if (std.mem.eql(u8, right_type, "NULL")) {
            return self.allocator.dupe(u8, left_type);
        }

        // Default to MIXED for incompatible types
        return self.allocator.dupe(u8, "MIXED");
    }

    fn isNumericType(type_name: []const u8) bool {
        return std.mem.eql(u8, type_name, "INT") or
            std.mem.eql(u8, type_name, "DECIMAL") or
            std.mem.eql(u8, type_name, "FLOAT");
    }
};

fn typeNameForValue(value: value_types.Value) []const u8 {
    return switch (value) {
        .Null => "NULL",
        .Int, .SmallInt, .BigInt => "INT",
        .Decimal => "DECIMAL",
        .Real, .Double => "FLOAT",
        .Bool => "BOOL",
        .Str, .Text, .Char, .Varchar => "STRING",
        .List => "ARRAY",
        .Map => "OBJECT",
        .Node => "NODE",
        .Edge => "EDGE",
        .Path => "PATH",
        .ExtValue,
        .Date,
        .Time,
        .TimeTZ,
        .Timestamp,
        .TimestampTZ,
        .Interval,
        .Bytea,
        .Json,
        .Jsonb,
        .Xml,
        .Url,
        .Domain,
        => "OBJECT",
    };
}

pub const UnionColumnType = struct {
    name: []const u8,
    unified_type: []const u8,
    left_type: []const u8,
    right_type: []const u8,
    requires_conversion: bool,
};

// Advanced UNION optimization system
pub const UnionOptimizer = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) UnionOptimizer {
        return .{ .allocator = allocator };
    }

    // Choose optimal UNION algorithm based on data characteristics
    pub fn optimizeUnionExecution(self: *UnionOptimizer, left_size: usize, right_size: usize, has_duplicates: bool, memory_limit: usize) UnionStrategy {
        _ = self;
        const total_size = left_size + right_size;

        if (!has_duplicates) {
            // UNION ALL - simple concatenation
            return .{ .algorithm = .concatenation, .memory_estimate = total_size * 100 };
        }

        // UNION DISTINCT - choose based on size and memory
        const hash_memory_estimate = total_size * 150; // Hash table overhead
        const sort_memory_estimate = total_size * 120; // Sort buffer requirement

        if (hash_memory_estimate <= memory_limit and total_size > 10000) {
            // Large dataset - use hash-based deduplication
            return .{ .algorithm = .hash_dedup, .memory_estimate = hash_memory_estimate };
        } else if (sort_memory_estimate <= memory_limit) {
            // Medium dataset - use sort-based deduplication
            return .{ .algorithm = .sort_dedup, .memory_estimate = sort_memory_estimate };
        } else {
            // Memory constrained - use external sort
            return .{ .algorithm = .external_sort, .memory_estimate = memory_limit };
        }
    }

    // Multi-way UNION optimization for multiple branches
    pub fn optimizeMultiWayUnion(self: *UnionOptimizer, branch_sizes: []const usize, memory_limit: usize) MultiWayStrategy {
        _ = self;
        const total_size: usize = blk: {
            var sum: usize = 0;
            for (branch_sizes) |size| sum += size;
            break :blk sum;
        };

        if (total_size * 100 <= memory_limit) {
            // Fit in memory - use tree reduction
            return .{ .approach = .tree_reduction, .batch_size = branch_sizes.len };
        } else {
            // Use streaming merge with batching
            const batch_size = memory_limit / (total_size / branch_sizes.len + 1);
            return .{ .approach = .streaming_merge, .batch_size = @max(2, batch_size) };
        }
    }
};

pub const UnionStrategy = struct {
    algorithm: Algorithm,
    memory_estimate: usize,

    pub const Algorithm = enum {
        concatenation, // Simple append for UNION ALL
        hash_dedup, // Hash-based deduplication
        sort_dedup, // Sort-based deduplication
        external_sort, // External sort for large datasets
    };
};

pub const MultiWayStrategy = struct {
    approach: Approach,
    batch_size: usize,

    pub const Approach = enum {
        tree_reduction, // Binary tree reduction
        streaming_merge, // Streaming merge with spilling
    };
};

// Enhanced set operations beyond basic UNION
pub const SetOperations = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SetOperations {
        return .{ .allocator = allocator };
    }

    // INTERSECT operation - common rows between sets
    pub fn intersect(self: *SetOperations, left_rows: []const []const u8, right_rows: []const []const u8, all_mode: bool) ![][]const u8 {
        if (all_mode) {
            return self.intersectAll(left_rows, right_rows);
        } else {
            return self.intersectDistinct(left_rows, right_rows);
        }
    }

    // EXCEPT operation - rows in left but not in right
    pub fn except(self: *SetOperations, left_rows: []const []const u8, right_rows: []const []const u8, all_mode: bool) ![][]const u8 {
        if (all_mode) {
            return self.exceptAll(left_rows, right_rows);
        } else {
            return self.exceptDistinct(left_rows, right_rows);
        }
    }

    fn intersectAll(self: *SetOperations, left_rows: []const []const u8, right_rows: []const []const u8) ![][]const u8 {
        var result = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer result.deinit(self.allocator);

        // Build frequency map of right rows
        var right_freq = std.StringHashMap(u32).init(self.allocator);
        defer right_freq.deinit();

        for (right_rows) |row| {
            const current = right_freq.get(row) orelse 0;
            try right_freq.put(row, current + 1);
        }

        // For each left row, check if it exists in right and consume frequency
        for (left_rows) |row| {
            if (right_freq.getPtr(row)) |freq_ptr| {
                if (freq_ptr.* > 0) {
                    try result.append(self.allocator, row);
                    freq_ptr.* -= 1;
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn intersectDistinct(self: *SetOperations, left_rows: []const []const u8, right_rows: []const []const u8) ![][]const u8 {
        var result = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer result.deinit(self.allocator);

        // Build set of right rows
        var right_set = std.StringHashMap(void).init(self.allocator);
        defer right_set.deinit();

        for (right_rows) |row| {
            try right_set.put(row, {});
        }

        // Deduplicated left rows that exist in right
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        for (left_rows) |row| {
            if (right_set.contains(row) and !seen.contains(row)) {
                try result.append(self.allocator, row);
                try seen.put(row, {});
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn exceptAll(self: *SetOperations, left_rows: []const []const u8, right_rows: []const []const u8) ![][]const u8 {
        var result = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer result.deinit(self.allocator);

        // Build frequency map of right rows
        var right_freq = std.StringHashMap(u32).init(self.allocator);
        defer right_freq.deinit();

        for (right_rows) |row| {
            const current = right_freq.get(row) orelse 0;
            try right_freq.put(row, current + 1);
        }

        // For each left row, include if not in right or after consuming right frequency
        for (left_rows) |row| {
            if (right_freq.getPtr(row)) |freq_ptr| {
                if (freq_ptr.* > 0) {
                    freq_ptr.* -= 1; // Consume one occurrence
                } else {
                    try result.append(self.allocator, row); // No more occurrences to cancel
                }
            } else {
                try result.append(self.allocator, row); // Not in right set
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn exceptDistinct(self: *SetOperations, left_rows: []const []const u8, right_rows: []const []const u8) ![][]const u8 {
        var result = std.ArrayList([]const u8).initCapacity(self.allocator, 0) catch return error.OutOfMemory;
        defer result.deinit(self.allocator);

        // Build set of right rows
        var right_set = std.StringHashMap(void).init(self.allocator);
        defer right_set.deinit();

        for (right_rows) |row| {
            try right_set.put(row, {});
        }

        // Deduplicated left rows that don't exist in right
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        for (left_rows) |row| {
            if (!right_set.contains(row) and !seen.contains(row)) {
                try result.append(self.allocator, row);
                try seen.put(row, {});
            }
        }

        return result.toOwnedSlice(self.allocator);
    }
};
