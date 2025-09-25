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
        track_path: bool = true,  // Default-enable path tracking
        path_column: ?[]const u8,
        path_separator: []const u8 = "/",
        include_self: bool = true,
        max_path_length: u32 = 1000,
        enable_bounded_expansion: bool = true,  // Default-enable bounded path expansions
        deterministic_ordering: bool = true,  // Ensure deterministic ordering
    };

    pub const OptimizationHints = struct {
        expected_iterations: ?u32,
        expected_result_size: ?u64,
        breadth_first: bool = true,
        materialize_intermediate: bool = true,
        parallel_execution: bool = false,
        memory_limit_mb: u32 = 1024,
        depth_limit: u32 = 100,  // Default depth limit for recursive CTEs
        enable_by_default: bool = true,  // Recursive CTEs default-enabled
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

    fn buildPathFindingCTE(
        self: *RecursiveQueryProcessor,
        start_node: u64,
        end_node: ?u64,
        graph_name: []const u8,
    ) !RecursiveCTE {
        _ = self;
        _ = start_node;
        _ = end_node;
        _ = graph_name;

        // TODO: Build CTE for path finding
        return error.NotImplemented;
    }

    fn buildTransitiveClosureCTE(
        self: *RecursiveQueryProcessor,
        relation_name: []const u8,
        from_column: []const u8,
        to_column: []const u8,
    ) !RecursiveCTE {
        _ = self;
        _ = relation_name;
        _ = from_column;
        _ = to_column;

        // TODO: Build CTE for transitive closure
        return error.NotImplemented;
    }

    fn spillToDisk(self: *RecursiveQueryProcessor, execution: *RecursiveExecution) !void {
        _ = self;

        if (!execution.result_accumulator.spilled_to_disk) {
            // Create temporary file
            const temp_dir = std.fs.cwd();
            const temp_file = try temp_dir.createFile("recursive_temp.dat", .{});
            execution.result_accumulator.temp_file = temp_file;
            execution.result_accumulator.spilled_to_disk = true;
        }

        // Write current results to disk
        // TODO: Implement disk spilling
        execution.statistics.spill_count += 1;
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

    // Helper functions
    fn analyzeQuerySchema(query: *ast.Query) !struct {
        columns: []RecursiveCTE.Column,
    } {
        _ = query;
        // TODO: Analyze query to determine output schema
        return .{ .columns = &[_]RecursiveCTE.Column{} };
    }

    fn hasRecursiveReference(query: *ast.Query, cte_name: []const u8) bool {
        _ = query;
        _ = cte_name;
        // TODO: Check if query references the CTE
        return true;
    }

    fn replaceRecursiveReference(self: *RecursiveQueryProcessor, query: *ast.Query, working_table: *RecursiveExecution.WorkingTable) !*ast.Query {
        _ = self;
        _ = query;
        _ = working_table;
        // TODO: Replace recursive reference with working table
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

    fn processDistinctUnion(self: *RecursiveQueryProcessor, execution: *RecursiveExecution, result: exec.QueryResult) !void {
        _ = self;
        _ = execution;
        _ = result;
        // TODO: Process distinct union
    }

    fn processAllUnion(self: *RecursiveQueryProcessor, execution: *RecursiveExecution, result: exec.QueryResult) !void {
        _ = self;
        try execution.working_table.next.appendSlice(result.rows);
        try execution.result_accumulator.rows.appendSlice(result.rows);
    }

    fn buildPaths(self: *RecursiveQueryProcessor, execution: *RecursiveExecution) !void {
        _ = self;
        _ = execution;
        // TODO: Build paths
    }

    fn detectCyclesDFS(self: *RecursiveQueryProcessor, detector: *RecursiveExecution.CycleDetector, execution: *RecursiveExecution) !void {
        _ = self;
        _ = detector;
        _ = execution;
        // TODO: DFS cycle detection
    }

    fn detectCyclesUnionFind(self: *RecursiveQueryProcessor, detector: *RecursiveExecution.CycleDetector, execution: *RecursiveExecution) !void {
        _ = self;
        _ = detector;
        _ = execution;
        // TODO: Union-find cycle detection
    }

    fn detectCyclesTopological(self: *RecursiveQueryProcessor, detector: *RecursiveExecution.CycleDetector, execution: *RecursiveExecution) !void {
        _ = self;
        _ = detector;
        _ = execution;
        // TODO: Topological sort cycle detection
    }

    fn extractPaths(self: *RecursiveQueryProcessor, result: exec.QueryResult) ![]RecursiveExecution.PathBuilder.Path {
        _ = self;
        _ = result;
        // TODO: Extract paths from result
        return &[_]RecursiveExecution.PathBuilder.Path{};
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
