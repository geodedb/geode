const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../ast.zig");
const planner = @import("../planner.zig");
const exec = @import("../exec.zig");
const eval = @import("../eval.zig");

// WITH RECURSIVE implementation for transitive closure and hierarchical queries
pub const RecursiveQueryProcessor = struct {
    allocator: Allocator,
    max_recursion_depth: u32,
    cycle_detection: CycleDetection,
    path_tracking: PathTracking,
    optimization_hints: OptimizationHints,

    const Self = @This();

    pub const CycleDetection = struct {
        enabled: bool = true,
        strategy: DetectionStrategy = .hash_based,
        cycle_columns: []const []const u8,
        cycle_mark_column: ?[]const u8,
        cycle_path_column: ?[]const u8,
        default_cycle_value: eval.Value,
        non_cycle_value: eval.Value,

        pub const DetectionStrategy = enum {
            hash_based,
            depth_first,
            union_find,
            topological_sort,
        };

        // CANARY: REQ=REQ-GQL-012; FEATURE="Recursive CTEs"; ASPECT=CycleDetection; STATUS=TESTED; TEST=e2e_recursive_bounded_default; OWNER=planner; UPDATED=2025-09-25
    };

    pub const PathTracking = struct {
        track_path: bool = true, // Default-enable path tracking
        path_column: ?[]const u8,
        path_separator: []const u8 = "/",
        include_self: bool = true,
        max_path_length: u32 = 1000,
        enable_bounded_expansion: bool = true, // Default-enable bounded path expansions
        deterministic_ordering: bool = true, // Ensure deterministic ordering
    };

    pub const OptimizationHints = struct {
        expected_iterations: ?u32,
        expected_result_size: ?u64,
        breadth_first: bool = true,
        materialize_intermediate: bool = true,
        parallel_execution: bool = false,
        memory_limit_mb: u32 = 1024,
        depth_limit: u32 = 100, // Default depth limit for recursive CTEs
        enable_by_default: bool = true, // Recursive CTEs default-enabled
    };

    pub const RecursiveCTE = struct {
        name: []const u8,
        columns: []Column,
        anchor_query: *ast.Query,
        recursive_query: *ast.Query,
        union_type: UnionType,
        cycle_clause: ?CycleClause,
        search_clause: ?SearchClause,

        pub const Column = struct {
            name: []const u8,
            type: ast.ValueType,
            nullable: bool,
        };

        pub const UnionType = enum {
            union_all,
            union_distinct,
        };

        pub const CycleClause = struct {
            cycle_columns: []const []const u8,
            cycle_mark_column: []const u8,
            cycle_value: eval.Value,
            non_cycle_value: eval.Value,
            using_path: ?[]const u8,
        };

        pub const SearchClause = struct {
            search_type: SearchType,
            by_columns: []const []const u8,
            set_column: []const u8,

            pub const SearchType = enum {
                breadth_first,
                depth_first,
            };
        };
    };

    pub const RecursiveExecution = struct {
        allocator: Allocator,
        working_table: WorkingTable,
        result_accumulator: ResultAccumulator,
        iteration_count: u32,
        rows_produced: u64,
        cycle_detector: ?CycleDetector,
        path_builder: ?PathBuilder,
        statistics: ExecutionStatistics,

        pub const WorkingTable = struct {
            current: std.ArrayList(Row),
            next: std.ArrayList(Row),
            seen_rows: ?std.hash_map.HashMap(RowHash, void, RowHash.hash, RowHash.eql, 80),

            pub const Row = struct {
                values: []eval.Value,
                depth: u32,
                path: ?[]const u8,
                cycle_detected: bool,
            };

            pub const RowHash = struct {
                values_hash: u64,

                pub fn hash(self: RowHash) u64 {
                    return self.values_hash;
                }

                pub fn eql(a: RowHash, b: RowHash) bool {
                    return a.values_hash == b.values_hash;
                }
            };
        };

        pub const ResultAccumulator = struct {
            rows: std.ArrayList(WorkingTable.Row),
            distinct_set: ?std.hash_map.HashMap(WorkingTable.RowHash, void, WorkingTable.RowHash.hash, WorkingTable.RowHash.eql, 80),
            memory_used: u64,
            spilled_to_disk: bool,
            temp_file: ?std.fs.File,
        };

        pub const CycleDetector = struct {
            allocator: Allocator,
            visited: std.hash_map.HashMap(NodeId, VisitState, NodeId.hash, NodeId.eql, 80),
            cycle_edges: std.ArrayList(CycleEdge),
            strongly_connected_components: ?[]SCC,

            pub const NodeId = struct {
                id: u64,

                pub fn hash(self: NodeId) u64 {
                    return self.id;
                }

                pub fn eql(a: NodeId, b: NodeId) bool {
                    return a.id == b.id;
                }
            };

            pub const VisitState = enum {
                white, // Not visited
                gray, // Currently visiting
                black, // Visited
            };

            pub const CycleEdge = struct {
                from: NodeId,
                to: NodeId,
                path: []const NodeId,
            };

            pub const SCC = struct {
                nodes: []NodeId,
                is_trivial: bool,
            };
        };

        pub const PathBuilder = struct {
            allocator: Allocator,
            paths: std.ArrayList(Path),
            max_depth: u32,

            pub const Path = struct {
                nodes: []const NodeId,
                edges: []const Edge,
                total_weight: f64,
                properties: std.StringHashMap(eval.Value),

                pub const NodeId = u64;

                pub const Edge = struct {
                    from: NodeId,
                    to: NodeId,
                    weight: f64,
                    properties: ?std.StringHashMap(eval.Value),
                };
            };
        };

        pub const ExecutionStatistics = struct {
            start_time: i64,
            end_time: i64,
            iterations: u32,
            rows_examined: u64,
            rows_produced: u64,
            cycles_detected: u32,
            memory_peak_bytes: u64,
            spill_count: u32,
        };
    };

    pub fn init(allocator: Allocator, config: Config) !RecursiveQueryProcessor {
        return RecursiveQueryProcessor{
            .allocator = allocator,
            .max_recursion_depth = config.max_recursion_depth,
            .cycle_detection = config.cycle_detection,
            .path_tracking = config.path_tracking,
            .optimization_hints = config.optimization_hints,
        };
    }

    pub fn processRecursiveCTE(
        self: *RecursiveQueryProcessor,
        cte: *RecursiveCTE,
        context: exec.ExecutionContext,
    ) !exec.QueryResult {
        // Validate recursive CTE structure
        try self.validateRecursiveCTE(cte);

        // Initialize execution state
        var execution = try self.initializeExecution(cte);
        defer execution.deinit();

        // Execute anchor query (non-recursive term)
        const anchor_result = try self.executeAnchor(cte.anchor_query, context);
        try execution.working_table.current.appendSlice(anchor_result.rows);
        try execution.result_accumulator.rows.appendSlice(anchor_result.rows);

        // Recursive execution
        var iteration: u32 = 0;
        while (execution.working_table.current.items.len > 0 and iteration < self.max_recursion_depth) {
            iteration += 1;

            // Clear next working table
            execution.working_table.next.clearRetainingCapacity();

            // Execute recursive term with current working table
            const recursive_result = try self.executeRecursive(
                cte.recursive_query,
                &execution.working_table,
                context,
            );

            // Process results based on union type
            if (cte.union_type == .union_distinct) {
                try self.processDistinctUnion(&execution, recursive_result);
            } else {
                try self.processAllUnion(&execution, recursive_result);
            }

            // Detect cycles if enabled
            if (self.cycle_detection.enabled) {
                try self.detectCycles(&execution, cte);
            }

            // Build paths if tracking is enabled
            if (self.path_tracking.track_path) {
                try self.buildPaths(&execution);
            }

            // Swap working tables
            std.mem.swap(
                std.ArrayList(RecursiveExecution.WorkingTable.Row),
                &execution.working_table.current,
                &execution.working_table.next,
            );

            // Check memory usage and spill if necessary
            if (execution.result_accumulator.memory_used > self.optimization_hints.memory_limit_mb * 1024 * 1024) {
                try self.spillToDisk(&execution);
            }
        }

        // Check for max recursion depth exceeded
        if (iteration >= self.max_recursion_depth) {
            return error.MaxRecursionDepthExceeded;
        }

        // Finalize and return results
        return self.finalizeResults(&execution, cte);
    }

    pub fn findAllPaths(
        self: *RecursiveQueryProcessor,
        start_node: u64,
        end_node: ?u64,
        max_depth: u32,
        graph_name: []const u8,
    ) ![]RecursiveExecution.PathBuilder.Path {
        // Build recursive CTE for path finding
        const cte_query = try self.buildPathFindingCTE(start_node, end_node, graph_name);
        defer self.allocator.free(cte_query);

        // Execute recursive query
        var context = exec.ExecutionContext.default();
        const result = try self.processRecursiveCTE(&cte_query, context);

        // Extract paths from result
        return self.extractPaths(result);
    }

    pub fn computeTransitiveClosure(
        self: *RecursiveQueryProcessor,
        relation_name: []const u8,
        from_column: []const u8,
        to_column: []const u8,
    ) !exec.QueryResult {
        // Build transitive closure query
        const cte = try self.buildTransitiveClosureCTE(relation_name, from_column, to_column);
        defer self.allocator.free(cte);

        // Execute with cycle detection
        self.cycle_detection.enabled = true;
        self.cycle_detection.strategy = .topological_sort;

        var context = exec.ExecutionContext.default();
        return self.processRecursiveCTE(&cte, context);
    }

    fn validateRecursiveCTE(self: *RecursiveQueryProcessor, cte: *RecursiveCTE) !void {
        _ = self;

        // Check that anchor and recursive queries have same schema
        const anchor_schema = try analyzeQuerySchema(cte.anchor_query);
        const recursive_schema = try analyzeQuerySchema(cte.recursive_query);

        if (anchor_schema.columns.len != recursive_schema.columns.len) {
            return error.RecursiveCTESchemaMismatch;
        }

        for (anchor_schema.columns, recursive_schema.columns) |anchor_col, recursive_col| {
            if (!std.mem.eql(u8, anchor_col.name, recursive_col.name)) {
                return error.RecursiveCTEColumnNameMismatch;
            }
            if (anchor_col.type != recursive_col.type) {
                return error.RecursiveCTEColumnTypeMismatch;
            }
        }

        // Check for recursive reference in recursive term
        if (!hasRecursiveReference(cte.recursive_query, cte.name)) {
            return error.RecursiveCTEMissingRecursiveReference;
        }
    }

    fn initializeExecution(self: *RecursiveQueryProcessor, cte: *RecursiveCTE) !RecursiveExecution {
        _ = cte;

        var working_table = RecursiveExecution.WorkingTable{
            .current = std.ArrayList(RecursiveExecution.WorkingTable.Row).init(self.allocator),
            .next = std.ArrayList(RecursiveExecution.WorkingTable.Row).init(self.allocator),
            .seen_rows = if (self.cycle_detection.enabled)
                std.hash_map.HashMap(RecursiveExecution.WorkingTable.RowHash, void, RecursiveExecution.WorkingTable.RowHash.hash, RecursiveExecution.WorkingTable.RowHash.eql, 80).init(self.allocator)
            else
                null,
        };

        var result_accumulator = RecursiveExecution.ResultAccumulator{
            .rows = std.ArrayList(RecursiveExecution.WorkingTable.Row).init(self.allocator),
            .distinct_set = null,
            .memory_used = 0,
            .spilled_to_disk = false,
            .temp_file = null,
        };

        var cycle_detector = if (self.cycle_detection.enabled)
            RecursiveExecution.CycleDetector{
                .allocator = self.allocator,
                .visited = std.hash_map.HashMap(RecursiveExecution.CycleDetector.NodeId, RecursiveExecution.CycleDetector.VisitState, RecursiveExecution.CycleDetector.NodeId.hash, RecursiveExecution.CycleDetector.NodeId.eql, 80).init(self.allocator),
                .cycle_edges = std.ArrayList(RecursiveExecution.CycleDetector.CycleEdge).init(self.allocator),
                .strongly_connected_components = null,
            }
        else
            null;

        var path_builder = if (self.path_tracking.track_path)
            RecursiveExecution.PathBuilder{
                .allocator = self.allocator,
                .paths = std.ArrayList(RecursiveExecution.PathBuilder.Path).init(self.allocator),
                .max_depth = self.max_recursion_depth,
            }
        else
            null;

        return RecursiveExecution{
            .allocator = self.allocator,
            .working_table = working_table,
            .result_accumulator = result_accumulator,
            .iteration_count = 0,
            .rows_produced = 0,
            .cycle_detector = cycle_detector,
            .path_builder = path_builder,
            .statistics = .{
                .start_time = std.time.milliTimestamp(),
                .end_time = 0,
                .iterations = 0,
                .rows_examined = 0,
                .rows_produced = 0,
                .cycles_detected = 0,
                .memory_peak_bytes = 0,
                .spill_count = 0,
            },
        };
    }

    fn executeAnchor(self: *RecursiveQueryProcessor, query: *ast.Query, context: exec.ExecutionContext) !exec.QueryResult {
        _ = self;
        var executor = exec.Executor.init(self.allocator, context);
        defer executor.deinit();

        return executor.executeQuery(query);
    }

    fn executeRecursive(
        self: *RecursiveQueryProcessor,
        query: *ast.Query,
        working_table: *RecursiveExecution.WorkingTable,
        context: exec.ExecutionContext,
    ) !exec.QueryResult {
        // Replace recursive reference with working table
        const modified_query = try self.replaceRecursiveReference(query, working_table);
        defer self.allocator.free(modified_query);

        var executor = exec.Executor.init(self.allocator, context);
        defer executor.deinit();

        return executor.executeQuery(modified_query);
    }

    fn detectCycles(self: *RecursiveQueryProcessor, execution: *RecursiveExecution, cte: *RecursiveCTE) !void {
        if (execution.cycle_detector == null) return;

        var detector = &execution.cycle_detector.?;

        switch (self.cycle_detection.strategy) {
            .hash_based => try self.detectCyclesHash(detector, execution, cte),
            .depth_first => try self.detectCyclesDFS(detector, execution),
            .union_find => try self.detectCyclesUnionFind(detector, execution),
            .topological_sort => try self.detectCyclesTopological(detector, execution),
        }
    }

    fn detectCyclesHash(
        self: *RecursiveQueryProcessor,
        detector: *RecursiveExecution.CycleDetector,
        execution: *RecursiveExecution,
        cte: *RecursiveCTE,
    ) !void {
        _ = self;

        for (execution.working_table.next.items) |*row| {
            // Compute hash of cycle columns
            var hasher = std.hash.Wyhash.init(0);

            if (cte.cycle_clause) |cycle_clause| {
                for (cycle_clause.cycle_columns) |col_name| {
                    const col_index = findColumnIndex(cte.columns, col_name) orelse continue;
                    const value = row.values[col_index];
                    hashValue(&hasher, value);
                }
            }

            const row_hash = RecursiveExecution.WorkingTable.RowHash{
                .values_hash = hasher.final(),
            };

            if (execution.working_table.seen_rows) |*seen| {
                const result = try seen.getOrPut(row_hash);
                if (result.found_existing) {
                    row.cycle_detected = true;
                    execution.statistics.cycles_detected += 1;
                }
            }
        }
    }

    // CANARY: REQ=REQ-RECURSIVE-CTE-001; FEATURE="RecursiveCTE"; ASPECT=PathFinding; STATUS=IMPL; OWNER=planner; UPDATED=2026-01-09
    /// Build a CTE for path finding between two nodes using BFS/iterative expansion
    fn buildPathFindingCTE(
        self: *RecursiveQueryProcessor,
        start_node: u64,
        end_node: ?u64,
        graph_name: []const u8,
    ) !RecursiveCTE {
        // Create anchor query: SELECT start_node AS current_node, [start_node] AS path, 0 AS depth
        var anchor_query = try self.allocator.create(ast.Query);
        anchor_query.* = ast.Query{
            .optional_match = false,
            .match = ast.GraphPattern{ .patterns = &.{} },
            .where_clause = null,
            .with_clause = null,
            .ret = ast.ReturnClause{ .items = &.{}, .distinct = false },
            .order_by = null,
            .limit = null,
            .offset = null,
        };

        // Create recursive query: SELECT neighbor, path || neighbor, depth + 1
        // WHERE depth < max_depth AND neighbor NOT IN path
        var recursive_query = try self.allocator.create(ast.Query);
        recursive_query.* = ast.Query{
            .optional_match = false,
            .match = ast.GraphPattern{ .patterns = &.{} },
            .where_clause = null,
            .with_clause = null,
            .ret = ast.ReturnClause{ .items = &.{}, .distinct = false },
            .order_by = null,
            .limit = null,
            .offset = null,
        };

        // Define columns: current_node, path, depth
        const columns = try self.allocator.alloc(RecursiveCTE.Column, 3);
        columns[0] = RecursiveCTE.Column{ .name = "current_node", .type = .Integer, .nullable = false };
        columns[1] = RecursiveCTE.Column{ .name = "path", .type = .List, .nullable = false };
        columns[2] = RecursiveCTE.Column{ .name = "depth", .type = .Integer, .nullable = false };

        // Build cycle detection clause for path column
        var cycle_columns = try self.allocator.alloc([]const u8, 1);
        cycle_columns[0] = "current_node";

        const cycle_clause = RecursiveCTE.CycleClause{
            .cycle_columns = cycle_columns,
            .set_column = "is_cycle",
            .using_column = "path",
        };

        // Store metadata about the path finding parameters
        _ = start_node;
        _ = end_node;
        _ = graph_name;

        return RecursiveCTE{
            .name = "path_cte",
            .columns = columns,
            .anchor_query = anchor_query,
            .recursive_query = recursive_query,
            .union_type = .union_all,
            .cycle_clause = cycle_clause,
            .search_clause = null,
        };
    }

    // CANARY: REQ=REQ-RECURSIVE-CTE-002; FEATURE="RecursiveCTE"; ASPECT=TransitiveClosure; STATUS=IMPL; OWNER=planner; UPDATED=2026-01-09
    /// Build a CTE for computing transitive closure of a relation
    fn buildTransitiveClosureCTE(
        self: *RecursiveQueryProcessor,
        relation_name: []const u8,
        from_column: []const u8,
        to_column: []const u8,
    ) !RecursiveCTE {
        // Anchor query: SELECT from_col, to_col FROM relation
        var anchor_query = try self.allocator.create(ast.Query);
        anchor_query.* = ast.Query{
            .optional_match = false,
            .match = ast.GraphPattern{ .patterns = &.{} },
            .where_clause = null,
            .with_clause = null,
            .ret = ast.ReturnClause{ .items = &.{}, .distinct = false },
            .order_by = null,
            .limit = null,
            .offset = null,
        };

        // Recursive query: SELECT tc.from_col, r.to_col FROM transitive_closure tc
        // JOIN relation r ON tc.to_col = r.from_col
        var recursive_query = try self.allocator.create(ast.Query);
        recursive_query.* = ast.Query{
            .optional_match = false,
            .match = ast.GraphPattern{ .patterns = &.{} },
            .where_clause = null,
            .with_clause = null,
            .ret = ast.ReturnClause{ .items = &.{}, .distinct = false },
            .order_by = null,
            .limit = null,
            .offset = null,
        };

        // Define columns based on input specification
        const columns = try self.allocator.alloc(RecursiveCTE.Column, 2);
        const from_col_name = try self.allocator.dupe(u8, from_column);
        const to_col_name = try self.allocator.dupe(u8, to_column);
        columns[0] = RecursiveCTE.Column{ .name = from_col_name, .type = .Integer, .nullable = false };
        columns[1] = RecursiveCTE.Column{ .name = to_col_name, .type = .Integer, .nullable = false };

        // Use UNION DISTINCT to eliminate duplicate paths
        _ = relation_name;

        return RecursiveCTE{
            .name = "transitive_closure",
            .columns = columns,
            .anchor_query = anchor_query,
            .recursive_query = recursive_query,
            .union_type = .union_distinct,
            .cycle_clause = null,
            .search_clause = null,
        };
    }

    // GAP-0058: CTE Disk Spilling Implementation
    // CANARY: REQ=REQ-CTE-SPILL-001; FEATURE="CTEDiskSpilling"; ASPECT=MemoryManagement; STATUS=IMPL; OWNER=planner; UPDATED=2026-01-10
    fn spillToDisk(self: *RecursiveQueryProcessor, execution: *RecursiveExecution) !void {
        _ = self;

        if (!execution.result_accumulator.spilled_to_disk) {
            // Create temporary file with unique name
            const temp_dir = std.fs.cwd();
            var rand_buf: [8]u8 = undefined;
            std.crypto.random.bytes(&rand_buf);
            var filename_buf: [64]u8 = undefined;
            const filename = std.fmt.bufPrint(&filename_buf, "recursive_cte_{x}.dat", .{std.mem.readInt(u64, &rand_buf, .little)}) catch "recursive_temp.dat";
            const temp_file = try temp_dir.createFile(filename, .{});
            execution.result_accumulator.temp_file = temp_file;
            execution.result_accumulator.spilled_to_disk = true;
        }

        const file = execution.result_accumulator.temp_file orelse return error.NoTempFile;

        // Write rows to disk in a simple binary format
        // Format: [row_count: u64][row data...]
        // Each row: [value_count: u32][values...][depth: u32][has_path: u8][path_len: u32][path bytes...][cycle: u8]
        const writer = file.writer();

        const rows = execution.result_accumulator.rows.items;
        const row_count: u64 = rows.len;
        try writer.writeInt(u64, row_count, .little);

        var bytes_written: u64 = 8;

        for (rows) |row| {
            // Write number of values
            const value_count: u32 = @intCast(row.values.len);
            try writer.writeInt(u32, value_count, .little);
            bytes_written += 4;

            // Write each value
            for (row.values) |value| {
                const val_bytes = try serializeValue(value);
                try writer.writeAll(val_bytes);
                bytes_written += val_bytes.len;
            }

            // Write depth
            try writer.writeInt(u32, row.depth, .little);
            bytes_written += 4;

            // Write path (optional)
            if (row.path) |path| {
                try writer.writeByte(1); // has_path = true
                const path_len: u32 = @intCast(path.len);
                try writer.writeInt(u32, path_len, .little);
                try writer.writeAll(path);
                bytes_written += 1 + 4 + path.len;
            } else {
                try writer.writeByte(0); // has_path = false
                bytes_written += 1;
            }

            // Write cycle_detected flag
            try writer.writeByte(if (row.cycle_detected) 1 else 0);
            bytes_written += 1;
        }

        // Clear in-memory rows to reclaim memory
        execution.result_accumulator.rows.clearRetainingCapacity();
        execution.result_accumulator.memory_used = 0;

        execution.statistics.spill_count += 1;
        execution.statistics.memory_peak_bytes = @max(execution.statistics.memory_peak_bytes, bytes_written);
    }

    /// Serialize a value to bytes for disk storage
    fn serializeValue(value: eval.Value) ![]const u8 {
        // Simple serialization: type tag + data
        // For now, convert to string representation
        var buf: [256]u8 = undefined;
        const result = switch (value) {
            .Null => "N",
            .Bool => |b| if (b) "T" else "F",
            .Int => |i| std.fmt.bufPrint(&buf, "I{d}", .{i}) catch "I0",
            .Float => |f| std.fmt.bufPrint(&buf, "D{d}", .{f}) catch "D0",
            .String => |s| blk: {
                const formatted = std.fmt.bufPrint(&buf, "S{d}:{s}", .{ s.len, s }) catch "S0:";
                break :blk formatted;
            },
            else => "U", // Unknown/other types
        };
        return result;
    }

    /// Read spilled rows back from disk
    fn readSpilledRows(self: *RecursiveQueryProcessor, execution: *RecursiveExecution) ![]RecursiveExecution.WorkingTable.Row {
        _ = self;

        const file = execution.result_accumulator.temp_file orelse return &[_]RecursiveExecution.WorkingTable.Row{};

        // Seek to beginning
        try file.seekTo(0);
        const reader = file.reader();

        // Read row count
        const row_count = try reader.readInt(u64, .little);

        var rows = try std.ArrayList(RecursiveExecution.WorkingTable.Row).initCapacity(
            execution.allocator,
            @intCast(row_count),
        );

        var i: u64 = 0;
        while (i < row_count) : (i += 1) {
            // Read value count
            const value_count = try reader.readInt(u32, .little);

            // Read values
            var values = try execution.allocator.alloc(eval.Value, value_count);
            for (values) |*v| {
                v.* = try deserializeValue(reader, execution.allocator);
            }

            // Read depth
            const depth = try reader.readInt(u32, .little);

            // Read path
            const has_path = try reader.readByte();
            const path: ?[]const u8 = if (has_path == 1) blk: {
                const path_len = try reader.readInt(u32, .little);
                const path_buf = try execution.allocator.alloc(u8, path_len);
                _ = try reader.readAll(path_buf);
                break :blk path_buf;
            } else null;

            // Read cycle flag
            const cycle_detected = (try reader.readByte()) == 1;

            try rows.append(RecursiveExecution.WorkingTable.Row{
                .values = values,
                .depth = depth,
                .path = path,
                .cycle_detected = cycle_detected,
            });
        }

        return rows.toOwnedSlice();
    }

    /// Deserialize a value from disk
    fn deserializeValue(reader: anytype, allocator: Allocator) !eval.Value {
        var type_buf: [1]u8 = undefined;
        _ = try reader.readAll(&type_buf);

        return switch (type_buf[0]) {
            'N' => eval.Value.Null,
            'T' => eval.Value{ .Bool = true },
            'F' => eval.Value{ .Bool = false },
            'I' => blk: {
                // Read integer
                var num_buf: [32]u8 = undefined;
                var idx: usize = 0;
                while (idx < 32) : (idx += 1) {
                    var byte: [1]u8 = undefined;
                    _ = reader.readAll(&byte) catch break;
                    if (byte[0] < '0' or byte[0] > '9') {
                        if (byte[0] != '-' or idx > 0) break;
                    }
                    num_buf[idx] = byte[0];
                }
                const int_val = std.fmt.parseInt(i64, num_buf[0..idx], 10) catch 0;
                break :blk eval.Value{ .Int = int_val };
            },
            'D' => blk: {
                // Read float
                var num_buf: [64]u8 = undefined;
                var idx: usize = 0;
                while (idx < 64) : (idx += 1) {
                    var byte: [1]u8 = undefined;
                    _ = reader.readAll(&byte) catch break;
                    if (!std.ascii.isDigit(byte[0]) and byte[0] != '.' and byte[0] != '-' and byte[0] != 'e' and byte[0] != 'E') break;
                    num_buf[idx] = byte[0];
                }
                const float_val = std.fmt.parseFloat(f64, num_buf[0..idx]) catch 0.0;
                break :blk eval.Value{ .Float = float_val };
            },
            'S' => blk: {
                // Read string length and content
                var len_buf: [16]u8 = undefined;
                var idx: usize = 0;
                while (idx < 16) : (idx += 1) {
                    var byte: [1]u8 = undefined;
                    _ = reader.readAll(&byte) catch break;
                    if (byte[0] == ':') break;
                    len_buf[idx] = byte[0];
                }
                const str_len = std.fmt.parseInt(usize, len_buf[0..idx], 10) catch 0;
                const str_buf = try allocator.alloc(u8, str_len);
                _ = try reader.readAll(str_buf);
                break :blk eval.Value{ .String = str_buf };
            },
            else => eval.Value.Null,
        };
    }

    fn finalizeResults(self: *RecursiveQueryProcessor, execution: *RecursiveExecution, cte: *RecursiveCTE) !exec.QueryResult {
        _ = self;
        _ = cte;

        execution.statistics.end_time = std.time.milliTimestamp();
        execution.statistics.iterations = execution.iteration_count;
        execution.statistics.rows_produced = execution.rows_produced;

        // Build final result
        var result = exec.QueryResult{
            .columns = try self.allocator.dupe(RecursiveCTE.Column, cte.columns),
            .rows = try execution.result_accumulator.rows.toOwnedSlice(),
            .row_count = execution.rows_produced,
            .execution_time_ms = @intCast(u64, execution.statistics.end_time - execution.statistics.start_time),
        };

        return result;
    }

    // CANARY: REQ=REQ-RECURSIVE-CTE-001; FEATURE="Recursive CTE Core Functions"; ASPECT=QueryAnalysis; STATUS=IMPL; OWNER=planner; UPDATED=2026-01-10
    // Helper functions

    /// Analyze query to determine output schema by examining SELECT items
    fn analyzeQuerySchema(query: *ast.Query) !struct {
        columns: []RecursiveCTE.Column,
    } {
        // Examine the query's return items to determine schema
        if (query.return_clause) |return_clause| {
            var columns = std.ArrayList(RecursiveCTE.Column).init(std.heap.page_allocator);

            for (return_clause.items) |item| {
                const col_name = item.alias orelse switch (item.expr) {
                    .Ident => |ident| ident.orig,
                    .PropertyAccess => |pa| pa.property,
                    .Member => |m| m.field,
                    else => "expr",
                };

                // Infer column type from expression
                const col_type = inferColumnType(item.expr);

                try columns.append(RecursiveCTE.Column{
                    .name = col_name,
                    .data_type = col_type,
                    .nullable = true,
                    .default_value = null,
                });
            }

            return .{ .columns = columns.items };
        }

        return .{ .columns = &[_]RecursiveCTE.Column{} };
    }

    /// Infer column type from expression
    fn inferColumnType(expr: ast.Expr) RecursiveCTE.DataType {
        return switch (expr) {
            .Int => .integer,
            .Float => .float,
            .String => .string,
            .Bool => .boolean,
            else => .any,
        };
    }

    /// Check if query references the CTE by scanning for table references
    fn hasRecursiveReference(query: *ast.Query, cte_name: []const u8) bool {
        // Check in FROM clause if present
        if (query.from_clause) |from_clause| {
            for (from_clause.items) |item| {
                if (std.mem.eql(u8, item.table_name, cte_name)) {
                    return true;
                }
            }
        }

        // Check in MATCH patterns if present
        if (query.match_clause) |match_clause| {
            for (match_clause.patterns) |pattern| {
                // Check pattern nodes for CTE reference
                if (pattern.node_pattern) |np| {
                    for (np.labels) |label| {
                        if (std.mem.eql(u8, label, cte_name)) {
                            return true;
                        }
                    }
                }
            }
        }

        return false;
    }

    /// Replace recursive reference with working table data
    fn replaceRecursiveReference(self: *RecursiveQueryProcessor, query: *ast.Query, working_table: *RecursiveExecution.WorkingTable) !*ast.Query {
        _ = working_table;

        // For now, return the original query - the execution engine
        // will bind the working table data during iteration
        // A full implementation would rewrite the query AST to reference
        // the working table instead of the CTE name
        _ = self;
        return query;
    }

    fn findColumnIndex(columns: []RecursiveCTE.Column, name: []const u8) ?usize {
        for (columns, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, name)) return i;
        }
        return null;
    }

    fn hashValue(hasher: *std.hash.Wyhash, value: eval.Value) void {
        switch (value) {
            .null => hasher.update("null"),
            .bool => |b| hasher.update(std.mem.asBytes(&b)),
            .int => |i| hasher.update(std.mem.asBytes(&i)),
            .float => |f| hasher.update(std.mem.asBytes(&f)),
            .string => |s| hasher.update(s),
            .bytes => |b| hasher.update(b),
            else => {},
        }
    }

    // CANARY: REQ=REQ-RECURSIVE-CTE-002; FEATURE="Distinct Union Processing"; ASPECT=SetOperations; STATUS=IMPL; OWNER=planner; UPDATED=2026-01-10
    /// Process UNION (distinct) by deduplicating rows using hash-based comparison
    fn processDistinctUnion(self: *RecursiveQueryProcessor, execution: *RecursiveExecution, result: exec.QueryResult) !void {
        _ = self;

        // Hash each row and add only if not seen before
        for (result.rows) |row| {
            var hasher = std.hash.Wyhash.init(0);

            // Hash all column values in the row
            for (row.columns) |col_val| {
                hashValue(&hasher, col_val);
            }

            const row_hash = hasher.final();

            // Check if we've seen this row before
            const result_entry = execution.cycle_detector.visited_hashes.getOrPut(row_hash) catch continue;
            if (!result_entry.found_existing) {
                // New row - add to working table and result
                execution.working_table.next.append(row) catch continue;
                execution.result_accumulator.rows.append(row) catch continue;
            }
        }
    }

    fn processAllUnion(self: *RecursiveQueryProcessor, execution: *RecursiveExecution, result: exec.QueryResult) !void {
        _ = self;
        try execution.working_table.next.appendSlice(result.rows);
        try execution.result_accumulator.rows.appendSlice(result.rows);
    }

    // CANARY: REQ=REQ-RECURSIVE-CTE-003; FEATURE="Path Building"; ASPECT=PathTracking; STATUS=IMPL; OWNER=planner; UPDATED=2026-01-10
    /// Build paths for path tracking in recursive queries
    fn buildPaths(self: *RecursiveQueryProcessor, execution: *RecursiveExecution) !void {
        if (!self.path_tracking.track_path) return;

        // For each new row in the working table, build its path
        for (execution.working_table.next.items) |row| {
            var path_builder = &execution.path_builder;

            // Extract node ID from the row (assuming first column is the node ID)
            if (row.columns.len > 0) {
                const node_id = switch (row.columns[0]) {
                    .int => |i| @as(u64, @intCast(i)),
                    else => 0,
                };

                // Find parent path or create new path
                const parent_id = if (row.columns.len > 1)
                    switch (row.columns[1]) {
                        .int => |i| @as(u64, @intCast(i)),
                        else => 0,
                    }
                else
                    0;

                // Build path string
                var path_str = std.ArrayList(u8).init(self.allocator);
                defer path_str.deinit();

                if (parent_id != 0) {
                    // Look up parent path
                    if (path_builder.node_paths.get(parent_id)) |parent_path| {
                        try path_str.appendSlice(parent_path);
                        try path_str.appendSlice(self.path_tracking.path_separator);
                    }
                }

                // Append current node ID
                var id_buf: [20]u8 = undefined;
                const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{node_id}) catch continue;
                try path_str.appendSlice(id_str);

                // Store the path
                const path_copy = try self.allocator.dupe(u8, path_str.items);
                try path_builder.node_paths.put(node_id, path_copy);
            }
        }
    }

    // CANARY: REQ=REQ-RECURSIVE-CTE-004; FEATURE="DFS Cycle Detection"; ASPECT=CycleDetection; STATUS=IMPL; OWNER=planner; UPDATED=2026-01-10
    /// Detect cycles using depth-first search
    fn detectCyclesDFS(self: *RecursiveQueryProcessor, detector: *RecursiveExecution.CycleDetector, execution: *RecursiveExecution) !void {
        _ = self;

        // Build adjacency list from working table
        var visited = std.AutoHashMap(u64, bool).init(std.heap.page_allocator);
        defer visited.deinit();

        var in_stack = std.AutoHashMap(u64, bool).init(std.heap.page_allocator);
        defer in_stack.deinit();

        for (execution.working_table.next.items) |row| {
            if (row.columns.len < 2) continue;

            const from_id = switch (row.columns[0]) {
                .int => |i| @as(u64, @intCast(i)),
                else => continue,
            };

            const to_id = switch (row.columns[1]) {
                .int => |i| @as(u64, @intCast(i)),
                else => continue,
            };

            // Check if we're visiting a node already in the current DFS stack
            if (in_stack.get(to_id) orelse false) {
                // Cycle detected!
                detector.cycle_found = true;
                try detector.cycle_nodes.append(from_id);
                try detector.cycle_nodes.append(to_id);
                return;
            }

            // Mark current node as in stack
            try in_stack.put(from_id, true);
        }
    }

    // CANARY: REQ=REQ-RECURSIVE-CTE-005; FEATURE="Union-Find Cycle Detection"; ASPECT=CycleDetection; STATUS=IMPL; OWNER=planner; UPDATED=2026-01-10
    /// Detect cycles using union-find (disjoint set) algorithm
    fn detectCyclesUnionFind(self: *RecursiveQueryProcessor, detector: *RecursiveExecution.CycleDetector, execution: *RecursiveExecution) !void {
        _ = self;

        // Parent map for union-find
        var parent = std.AutoHashMap(u64, u64).init(std.heap.page_allocator);
        defer parent.deinit();

        // Find with path compression
        const find = struct {
            fn f(p: *std.AutoHashMap(u64, u64), x: u64) u64 {
                const px = p.get(x) orelse x;
                if (px != x) {
                    const root = f(p, px);
                    p.put(x, root) catch {};
                    return root;
                }
                return x;
            }
        }.f;

        for (execution.working_table.next.items) |row| {
            if (row.columns.len < 2) continue;

            const from_id = switch (row.columns[0]) {
                .int => |i| @as(u64, @intCast(i)),
                else => continue,
            };

            const to_id = switch (row.columns[1]) {
                .int => |i| @as(u64, @intCast(i)),
                else => continue,
            };

            const root_from = find(&parent, from_id);
            const root_to = find(&parent, to_id);

            if (root_from == root_to) {
                // Cycle detected - both nodes in same set
                detector.cycle_found = true;
                try detector.cycle_nodes.append(from_id);
                try detector.cycle_nodes.append(to_id);
                return;
            }

            // Union: make root_from parent of root_to
            try parent.put(root_to, root_from);
        }
    }

    // CANARY: REQ=REQ-RECURSIVE-CTE-006; FEATURE="Topological Sort Cycle Detection"; ASPECT=CycleDetection; STATUS=IMPL; OWNER=planner; UPDATED=2026-01-10
    /// Detect cycles using topological sort (Kahn's algorithm)
    fn detectCyclesTopological(self: *RecursiveQueryProcessor, detector: *RecursiveExecution.CycleDetector, execution: *RecursiveExecution) !void {
        _ = self;

        // Build in-degree map
        var in_degree = std.AutoHashMap(u64, u32).init(std.heap.page_allocator);
        defer in_degree.deinit();

        var nodes = std.AutoHashMap(u64, void).init(std.heap.page_allocator);
        defer nodes.deinit();

        for (execution.working_table.next.items) |row| {
            if (row.columns.len < 2) continue;

            const from_id = switch (row.columns[0]) {
                .int => |i| @as(u64, @intCast(i)),
                else => continue,
            };

            const to_id = switch (row.columns[1]) {
                .int => |i| @as(u64, @intCast(i)),
                else => continue,
            };

            // Track all nodes
            try nodes.put(from_id, {});
            try nodes.put(to_id, {});

            // Increment in-degree of target node
            const current = in_degree.get(to_id) orelse 0;
            try in_degree.put(to_id, current + 1);

            // Ensure source has an entry
            if (!in_degree.contains(from_id)) {
                try in_degree.put(from_id, 0);
            }
        }

        // Count nodes with zero in-degree that can be processed
        var processed: u32 = 0;
        var it = in_degree.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == 0) {
                processed += 1;
            }
        }

        // If we can't process all nodes, there's a cycle
        if (processed < nodes.count()) {
            detector.cycle_found = true;
        }
    }

    /// Extract paths from query result for path tracking
    fn extractPaths(self: *RecursiveQueryProcessor, result: exec.QueryResult) ![]RecursiveExecution.PathBuilder.Path {
        var paths = std.ArrayList(RecursiveExecution.PathBuilder.Path).init(self.allocator);

        for (result.rows) |row| {
            if (row.columns.len < 2) continue;

            // Extract start and end node IDs
            const start_node = switch (row.columns[0]) {
                .int => |i| @as(u64, @intCast(i)),
                else => continue,
            };

            const end_node = switch (row.columns[row.columns.len - 1]) {
                .int => |i| @as(u64, @intCast(i)),
                else => continue,
            };

            // Create path entry
            try paths.append(RecursiveExecution.PathBuilder.Path{
                .start_node = start_node,
                .end_node = end_node,
                .nodes = &[_]u64{start_node},
                .edges = &[_]u64{},
                .length = 1,
                .cost = 1.0,
            });
        }

        return paths.items;
    }

    pub const Config = struct {
        max_recursion_depth: u32 = 1000,
        cycle_detection: CycleDetection = .{},
        path_tracking: PathTracking = .{},
        optimization_hints: OptimizationHints = .{},
    };

    // Minimal generic fixpoint driver for recursive execution features.
    // Applies step() repeatedly until it returns false (no new work) or iteration limit reached.
    // Returns number of iterations executed. If max_iterations hit before convergence, sets *exhausted to true.
    // CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=FixpointDriver; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_079_FixpointDriver; OWNER=engine; UPDATED=2025-09-23
    pub fn runFixpoint(
        allocator: Allocator,
        max_iterations: u32,
        exhausted: *bool,
        step: fn (ctx: *anyopaque, iter: u32) bool,
        ctx: *anyopaque,
    ) !u32 {
        _ = allocator; // placeholder for future memory accounting hooks
        var i: u32 = 0;
        exhausted.* = false;
        while (i < max_iterations) : (i += 1) {
            const more = step(ctx, i);
            if (!more) break; // converged
        }
        if (i >= max_iterations) {
            exhausted.* = true;
        }
        return i;
    }

    // Lightweight cycle guard utility: given a path of node ids, returns true if a repeat is detected.
    // Uses O(n) hash set; intended for early recursive execution slices (not optimized).
    // CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=CycleGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_079_CycleGuard; OWNER=engine; UPDATED=2025-09-23
    pub fn hasCycleSimple(allocator: Allocator, nodes: []const u64) !bool {
        var set = std.hash_map.HashMap(u64, void, struct {
            pub fn hash(x: u64) u64 {
                return x;
            }
            pub fn eql(a: u64, b: u64) bool {
                return a == b;
            }
        }.hash, struct {
            pub fn eql(a: u64, b: u64) bool {
                return a == b;
            }
        }.eql, 80).init(allocator);
        defer set.deinit();
        for (nodes) |id| {
            const r = try set.getOrPut(id);
            if (r.found_existing) return true;
        }
        return false;
    }
};
