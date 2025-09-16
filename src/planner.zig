const std = @import("std");
const ast = @import("gql/ast.zig");
const mem = std.mem;
const temporal = @import("temporal.zig");
const printer = @import("gql/print.zig");

pub const PlannerOptions = struct {
    attempt_pushdown: bool = true,
};

pub const Plan = struct {
    ordered: bool,
    note: []const u8 = "",
};

pub const PlanError = error{ OffsetPushdownRequiresOrder, GroupByIllegal, PathPatternUnsupported };

// Path pattern execution operator (REQ-GQL-017)
pub const PathExpand = struct {
    min_hops: u32 = 1,
    max_hops: u32 = 1,
    tie_break_policy: TieBreakPolicy = .LengthId,

    pub const TieBreakPolicy = enum {
        LengthId, // UA005/UA006: (length, start_id, end_id) deterministic ordering
    };

    pub const PathResult = struct {
        start_id: u64,
        end_id: u64,
        path_length: u32,
        edge_ids: []const u64,

        pub fn compare(self: PathResult, other: PathResult, policy: TieBreakPolicy) std.math.Order {
            return switch (policy) {
                .LengthId => {
                    // First compare by path length
                    const len_cmp = std.math.order(self.path_length, other.path_length);
                    if (len_cmp != .eq) return len_cmp;

                    // Then by start_id
                    const start_cmp = std.math.order(self.start_id, other.start_id);
                    if (start_cmp != .eq) return start_cmp;

                    // Finally by end_id
                    return std.math.order(self.end_id, other.end_id);
                },
            };
        }
    };

    pub const BFSState = struct {
        current_level: u32 = 0,
        visited: std.AutoHashMap(u64, void),
        queue: std.ArrayList(struct { node_id: u64, path: []const u64 }),
        results: std.ArrayList(PathResult),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) BFSState {
            return .{
                .visited = std.AutoHashMap(u64, void).init(allocator),
                .queue = std.ArrayList(struct { node_id: u64, path: []const u64 }).init(allocator),
                .results = std.ArrayList(PathResult).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *BFSState) void {
            self.visited.deinit();

            // Free path arrays
            for (self.queue.items) |item| {
                self.allocator.free(item.path);
            }
            self.queue.deinit();

            for (self.results.items) |result| {
                self.allocator.free(result.edge_ids);
            }
            self.results.deinit();
        }
    };

    pub fn execute(self: PathExpand, start_nodes: []const u64, adjacency: *const AdjacencyList, allocator: std.mem.Allocator) ![]const PathResult {
        var state = BFSState.init(allocator);
        defer state.deinit();

        // Initialize queue with start nodes
        for (start_nodes) |start_id| {
            const initial_path = try allocator.alloc(u64, 0);
            try state.queue.append(.{ .node_id = start_id, .path = initial_path });
        }

        while (state.queue.items.len > 0 and state.current_level < self.max_hops) {
            const level_size = state.queue.items.len;
            state.current_level += 1;

            var processed: usize = 0;
            while (processed < level_size) {
                const current = state.queue.orderedRemove(0);
                processed += 1;

                // Get neighbors from adjacency list
                if (adjacency.getNeighbors(current.node_id)) |neighbors| {
                    for (neighbors) |neighbor| {
                        // Check if we've already visited this node in this path (simple path constraint)
                        var already_in_path = false;
                        for (current.path) |path_node| {
                            if (path_node == neighbor.node_id) {
                                already_in_path = true;
                                break;
                            }
                        }

                        if (!already_in_path) {
                            // Create new path
                            const new_path = try allocator.alloc(u64, current.path.len + 1);
                            @memcpy(new_path[0..current.path.len], current.path);
                            new_path[current.path.len] = neighbor.edge_id;

                            // If within hop range, add to results
                            if (state.current_level >= self.min_hops) {
                                const result = PathResult{
                                    .start_id = start_nodes[0], // Simplified - would need to track actual start
                                    .end_id = neighbor.node_id,
                                    .path_length = state.current_level,
                                    .edge_ids = try allocator.dupe(u64, new_path),
                                };
                                try state.results.append(result);
                            }

                            // Continue BFS if not at max hops
                            if (state.current_level < self.max_hops) {
                                try state.queue.append(.{ .node_id = neighbor.node_id, .path = new_path });
                            } else {
                                allocator.free(new_path);
                            }
                        }
                    }
                }

                allocator.free(current.path);
            }
        }

        // Sort results by tie-break policy for deterministic ordering
        std.sort.pdq(PathResult, state.results.items, self.tie_break_policy, struct {
            fn lessThan(policy: TieBreakPolicy, a: PathResult, b: PathResult) bool {
                return a.compare(b, policy) == .lt;
            }
        }.lessThan);

        return try allocator.dupe(PathResult, state.results.items);
    }
};

// Mock adjacency list for path expansion
pub const AdjacencyList = struct {
    neighbors: std.AutoHashMap(u64, []const Neighbor),

    pub const Neighbor = struct {
        node_id: u64,
        edge_id: u64,
    };

    pub fn init(allocator: std.mem.Allocator) AdjacencyList {
        return .{
            .neighbors = std.AutoHashMap(u64, []const Neighbor).init(allocator),
        };
    }

    pub fn deinit(self: *AdjacencyList, allocator: std.mem.Allocator) void {
        var iter = self.neighbors.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        self.neighbors.deinit();
    }

    pub fn addEdge(self: *AdjacencyList, from: u64, to: u64, edge_id: u64, allocator: std.mem.Allocator) !void {
        const entry = try self.neighbors.getOrPut(from);
        if (!entry.found_existing) {
            entry.value_ptr.* = &[_]Neighbor{};
        }

        const old_neighbors = entry.value_ptr.*;
        const new_neighbors = try allocator.alloc(Neighbor, old_neighbors.len + 1);
        @memcpy(new_neighbors[0..old_neighbors.len], old_neighbors);
        new_neighbors[old_neighbors.len] = .{ .node_id = to, .edge_id = edge_id };

        if (old_neighbors.len > 0) {
            allocator.free(old_neighbors);
        }
        entry.value_ptr.* = new_neighbors;
    }

    pub fn getNeighbors(self: *const AdjacencyList, node_id: u64) ?[]const Neighbor {
        return self.neighbors.get(node_id);
    }
};

fn hasEqPred(e: ast.Expr) bool {
    return switch (e) {
        .Binary => |b| (b.op == .Eq) or hasEqPred(b.left.*) or hasEqPred(b.right.*),
        .Unary => |u| hasEqPred(u.expr.*),
        else => false,
    };
}

pub fn planQuery(q: ast.Query, opts: PlannerOptions) PlanError!Plan {
    const ordered = q.order_by != null;
    // Policy: do not allow OFFSET pushdown without an explicit order (US001)
    if (opts.attempt_pushdown and q.offset != null and !ordered) {
        return PlanError.OffsetPushdownRequiresOrder;
    }
    // Validate GROUP BY legality (phase 1)
    // Adaptive planner: simple selectivity heuristic for index vs scan
    const use_index = if (q.where_clause) |wc| hasEqPred(wc) else false;
    const note = if (use_index) "INDEX" else "";
    try validateGroupBy(q);
    return .{ .ordered = ordered, .note = note };
}

// Session context used for temporal comparison policies (e.g., how to interpret local datetimes)
pub const SessionContext = struct {
    // Offset applied when attaching to local datetimes for comparisons against zoned values.
    session_offset_minutes: i16 = 0,
};

pub const CompareError = temporal.TemporalError;

// Compare two temporal literal expressions for ORDER BY or filter semantics.
// Returns negative/zero/positive like strcmp: -1 if a<b, 0 if equal, 1 if a>b.
// Only handles DATE, TIME, DATETIME/LOCAL DATETIME literals; otherwise returns error.Invalid.
pub fn compareTemporalForOrder(a: ast.Expr, b: ast.Expr, ctx: SessionContext) CompareError!i8 {
    return switch (a) {
        .Date => |da| switch (b) {
            .Date => |db| temporal.compareDateParsed(da.parsed, db.parsed),
            else => CompareError.Invalid,
        },
        .Time => |ta| switch (b) {
            .Time => |tb| temporal.compareTimeParsed(ta.parsed, tb.parsed),
            else => CompareError.Invalid,
        },
        .DateTime => |dta| switch (b) {
            .DateTime => |dtb| blk: {
                const a_has = dta.parsed.time.offset_minutes != null;
                const b_has = dtb.parsed.time.offset_minutes != null;
                if (a_has and b_has) break :blk try temporal.compareDateTimeParsed(dta.parsed, dtb.parsed);
                if (!a_has and !b_has) break :blk try temporal.compareDateTimeParsed(dta.parsed, dtb.parsed);
                // Mismatch: attach session offset to the local one and compare
                if (!a_has and b_has) {
                    const a_att = temporal.attachSessionOffset(dta.parsed, ctx.session_offset_minutes);
                    break :blk try temporal.compareDateTimeParsed(a_att, dtb.parsed);
                } else if (a_has and !b_has) {
                    const b_att = temporal.attachSessionOffset(dtb.parsed, ctx.session_offset_minutes);
                    break :blk try temporal.compareDateTimeParsed(dta.parsed, b_att);
                }
                return CompareError.Invalid;
            },
            .LocalDateTime => |ldb| blk2: {
                const a_has = dta.parsed.time.offset_minutes != null;
                if (!a_has) {
                    // Both local; compare as local
                    break :blk2 try temporal.compareDateTimeParsed(dta.parsed, ldb.parsed);
                }
                // a is zoned, b is local: attach session offset to b
                const b_att = temporal.attachSessionOffset(ldb.parsed, ctx.session_offset_minutes);
                break :blk2 try temporal.compareDateTimeParsed(dta.parsed, b_att);
            },
            else => CompareError.Invalid,
        },
        .LocalDateTime => |lda| switch (b) {
            .LocalDateTime => |ldb| temporal.compareDateTimeParsed(lda.parsed, ldb.parsed),
            .DateTime => |dtb| blk3: {
                const b_has = dtb.parsed.time.offset_minutes != null;
                if (!b_has) break :blk3 try temporal.compareDateTimeParsed(lda.parsed, dtb.parsed);
                const a_att = temporal.attachSessionOffset(lda.parsed, ctx.session_offset_minutes);
                break :blk3 try temporal.compareDateTimeParsed(a_att, dtb.parsed);
            },
            else => CompareError.Invalid,
        },
        else => CompareError.Invalid,
    };
}

fn isAggregateCall(e: ast.Expr) bool {
    return switch (e) {
        .Call => |c| blk: {
            const callee = c.callee.*;
            const name = switch (callee) {
                .Ident => |s| s,
                else => break :blk false,
            };
            if (std.ascii.eqlIgnoreCase(name, "count")) break :blk true;
            if (std.ascii.eqlIgnoreCase(name, "sum")) break :blk true;
            if (std.ascii.eqlIgnoreCase(name, "avg")) break :blk true;
            if (std.ascii.eqlIgnoreCase(name, "min")) break :blk true;
            if (std.ascii.eqlIgnoreCase(name, "max")) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn validateGroupBy(q: ast.Query) PlanError!void {
    if (q.group_by == null) return;
    const gb = q.group_by.?;
    // Collect allowed group-by keys (identifier or simple member) using stable stringification for comparison.
    var allowed = std.StringHashMap(void).init(std.heap.page_allocator);
    defer allowed.deinit();
    // Track allocated key strings to free after
    var allocd = std.ArrayList([]const u8).initCapacity(std.heap.page_allocator, 0) catch unreachable;
    defer {
        for (allocd.items) |s| std.heap.page_allocator.free(s);
        allocd.deinit(std.heap.page_allocator);
    }
    for (gb.keys) |k| {
        switch (k) {
            .Ident => |s| {
                _ = allowed.put(s, {}) catch {};
            },
            .Member => {
                const ss = printer.stringifyExprAlloc(std.heap.page_allocator, k, .{}) catch continue;
                _ = allowed.put(ss, {}) catch {};
                allocd.append(std.heap.page_allocator, ss) catch {};
            },
            else => {}, // keep strict for other kinds
        }
    }
    if (allowed.count() == 0) return PlanError.GroupByIllegal;
    // Return items must be either aggregate calls or belong to allowed set (by ident/member).
    // Additionally, every GROUP BY key must appear as a non-aggregate RETURN item (policy for this project).
    var nonagg = std.StringHashMap(void).init(std.heap.page_allocator);
    defer nonagg.deinit();
    for (q.ret.items) |it| {
        const e = it.expr;
        if (isAggregateCall(e)) continue;
        switch (e) {
            .Ident => |s| {
                if (!allowed.contains(s)) return PlanError.GroupByIllegal;
                _ = nonagg.put(s, {}) catch {};
            },
            .Member => {
                const ss = printer.stringifyExprAlloc(std.heap.page_allocator, e, .{}) catch return PlanError.GroupByIllegal;
                defer std.heap.page_allocator.free(ss);
                if (!allowed.contains(ss)) return PlanError.GroupByIllegal;
                _ = nonagg.put(ss, {}) catch {};
            },
            else => return PlanError.GroupByIllegal,
        }
    }
    // Ensure each group key is present in non-aggregate returns
    var it_allowed = allowed.keyIterator();
    while (it_allowed.next()) |kptr| {
        const k = kptr.*;
        if (!nonagg.contains(k)) return PlanError.GroupByIllegal;
    }
    // HAVING: must be aggregate predicate or refer only to grouped identifiers/members (strict)
    if (q.having) |hv| {
        if (!exprAllowedInGroup(hv, &allowed)) return PlanError.GroupByIllegal;
    }
}

fn exprAllowedInGroup(e: ast.Expr, allowed: *std.StringHashMap(void)) bool {
    return switch (e) {
        .Int, .Bool, .Null, .String => true,
        .Ident => |s| allowed.contains(s),
        .Member => blk: {
            const ss = printer.stringifyExprAlloc(std.heap.page_allocator, e, .{}) catch break :blk false;
            defer std.heap.page_allocator.free(ss);
            break :blk allowed.contains(ss);
        },
        .Call => isAggregateCall(e),
        .Unary => |u| exprAllowedInGroup(u.expr.*, allowed),
        .Binary => |b| exprAllowedInGroup(b.left.*, allowed) and exprAllowedInGroup(b.right.*, allowed),
        else => false, // phase 1: be strict
    };
}

test "planner: temporal compare across timezones and local attach" {
    const ctx = SessionContext{ .session_offset_minutes = 0 };
    const dt1 = ast.Expr{ .DateTime = .{ .raw = "2024-08-12T10:15Z", .parsed = try temporal.parseDateTime("2024-08-12T10:15Z", true) } };
    const dt2 = ast.Expr{ .DateTime = .{ .raw = "2024-08-12T11:15+01", .parsed = try temporal.parseDateTime("2024-08-12T11:15+01", true) } };
    try std.testing.expect((try compareTemporalForOrder(dt1, dt2, ctx)) == 0);
    // Local vs zoned with session offset
    const ldt = ast.Expr{ .LocalDateTime = .{ .raw = "2024-08-12T10:15", .parsed = try temporal.parseDateTime("2024-08-12T10:15", false) } };
    try std.testing.expect((try compareTemporalForOrder(ldt, dt1, ctx)) == 0);
}

test "planner: time compare invalid across zone mismatch" {
    const ctx = SessionContext{};
    const t1 = ast.Expr{ .Time = .{ .raw = "10:15Z", .parsed = try temporal.parseTime("10:15Z", true) } };
    const t2 = ast.Expr{ .Time = .{ .raw = "10:15", .parsed = try temporal.parseTime("10:15", true) } };
    try std.testing.expectError(CompareError.Invalid, compareTemporalForOrder(t1, t2, ctx));
}

// Adaptive planner heuristic tests
test "planner: heuristic index on equality predicate" {
    var left_expr = ast.Expr{ .Ident = "a" };
    var right_expr = ast.Expr{ .Int = 1 };
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = ast.Expr{ .Binary = .{ .op = .Eq, .left = &left_expr, .right = &right_expr } };
    q.with_clause = null;
    q.group_by = null;
    q.ret = .{ .items = &.{}, .distinct = false };
    q.order_by = null;
    q.limit = null;
    q.offset = null;
    const plan = try planQuery(q, .{});
    try std.testing.expect(std.mem.eql(u8, plan.note, "INDEX"));
}

test "planner: no index without equality predicate" {
    var left_expr = ast.Expr{ .Ident = "a" };
    var right_expr = ast.Expr{ .Int = 1 };
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = ast.Expr{ .Binary = .{ .op = .Gt, .left = &left_expr, .right = &right_expr } };
    q.with_clause = null;
    q.group_by = null;
    q.ret = .{ .items = &.{}, .distinct = false };
    q.order_by = null;
    q.limit = null;
    q.offset = null;
    const plan = try planQuery(q, .{});
    try std.testing.expect(std.mem.eql(u8, plan.note, ""));
}

test "planner: no index without where clause" {
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.group_by = null;
    q.ret = .{ .items = &.{}, .distinct = false };
    q.order_by = null;
    q.limit = null;
    q.offset = null;
    const plan = try planQuery(q, .{});
    try std.testing.expect(std.mem.eql(u8, plan.note, ""));
}

test "planner: offset pushdown rejected without order" {
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.group_by = null;
    q.ret = .{ .items = &.{}, .distinct = false };
    q.order_by = null;
    q.limit = null;
    q.offset = 5;
    try std.testing.expectError(PlanError.OffsetPushdownRequiresOrder, planQuery(q, .{ .attempt_pushdown = true }));
}

test "planner: offset allowed with explicit order" {
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.group_by = null;
    q.ret = .{ .items = &.{}, .distinct = false };
    var keys: [1]ast.OrderBy.OrderKey = undefined;
    keys[0] = .{ .expr = .{ .Ident = "n" }, .desc = false };
    q.order_by = .{ .keys = keys[0..] };
    q.limit = null;
    q.offset = 5;
    const plan = try planQuery(q, .{ .attempt_pushdown = true });
    try std.testing.expect(plan.ordered);
}

test "planner: group by legality basic" {
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.having = null;
    q.order_by = null;
    q.limit = null;
    q.offset = null;
    // GROUP BY n, RETURN n is legal
    var keys: [1]ast.Expr = .{.{ .Ident = "n" }};
    q.group_by = .{ .keys = keys[0..] };
    var items: [1]ast.ReturnItem = .{.{ .expr = .{ .Ident = "n" }, .alias = null }};
    q.ret = .{ .items = items[0..], .distinct = false };
    _ = try planQuery(q, .{});
}

test "planner: group by illegal non-grouped return" {
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.having = null;
    q.order_by = null;
    q.limit = null;
    q.offset = null;
    // GROUP BY n, RETURN m (not grouped) should be illegal
    var keys: [1]ast.Expr = .{.{ .Ident = "n" }};
    q.group_by = .{ .keys = keys[0..] };
    var items: [1]ast.ReturnItem = .{.{ .expr = .{ .Ident = "m" }, .alias = null }};
    q.ret = .{ .items = items[0..], .distinct = false };
    try std.testing.expectError(PlanError.GroupByIllegal, planQuery(q, .{}));
}

test "planner: group by legal aggregate return" {
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.having = null;
    q.order_by = null;
    q.limit = null;
    q.offset = null;
    // GROUP BY n, RETURN n, count(m) should be legal (includes the GROUP BY key)
    var keys: [1]ast.Expr = .{.{ .Ident = "n" }};
    q.group_by = .{ .keys = keys[0..] };
    var callee = ast.Expr{ .Ident = "count" };
    var arg = ast.Expr{ .Ident = "m" };
    var args = [_]*ast.Expr{&arg};
    const call = ast.Expr{ .Call = .{ .callee = &callee, .args = args[0..] } };
    var items: [2]ast.ReturnItem = .{
        .{ .expr = .{ .Ident = "n" }, .alias = null },
        .{ .expr = call, .alias = null },
    };
    q.ret = .{ .items = items[0..], .distinct = false };
    _ = try planQuery(q, .{});
}

test "planner: having legality" {
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.having = null;
    q.order_by = null;
    q.limit = null;
    q.offset = null;
    var keys: [1]ast.Expr = .{.{ .Ident = "n" }};
    q.group_by = .{ .keys = keys[0..] };
    var items: [1]ast.ReturnItem = .{.{ .expr = .{ .Ident = "n" }, .alias = null }};
    q.ret = .{ .items = items[0..], .distinct = false };
    // HAVING count(m) > 1 allowed
    var callee = ast.Expr{ .Ident = "count" };
    var arg = ast.Expr{ .Ident = "m" };
    var one = ast.Expr{ .Int = 1 };
    var args = [_]*ast.Expr{&arg};
    var call = ast.Expr{ .Call = .{ .callee = &callee, .args = args[0..] } };
    const pred = ast.Expr{ .Binary = .{ .op = .Gt, .left = &call, .right = &one } };
    q.having = pred;
    _ = try planQuery(q, .{});
    // HAVING m (non-grouped identifier) illegal
    q.having = .{ .Ident = "m" };
    try std.testing.expectError(PlanError.GroupByIllegal, planQuery(q, .{}));
}

test "planner: group-by illegality with mixed identifiers in RETURN/HAVING" {
    var q: ast.Query = undefined;
    q.optional_match = false;
    q.match = .{ .chains = &.{} };
    q.where_clause = null;
    q.with_clause = null;
    q.order_by = null;
    q.limit = null;
    q.offset = null;
    var keys: [1]ast.Expr = .{.{ .Ident = "n" }};
    q.group_by = .{ .keys = keys[0..] };
    // RETURN n, m -> illegal (m not grouped and not aggregate)
    const it0 = ast.Expr{ .Ident = "n" };
    const it1 = ast.Expr{ .Ident = "m" };
    var items: [2]ast.ReturnItem = .{ .{ .expr = it0, .alias = null }, .{ .expr = it1, .alias = null } };
    q.ret = .{ .items = items[0..], .distinct = false };
    try std.testing.expectError(PlanError.GroupByIllegal, planQuery(q, .{}));
}

test "path expand: basic BFS with tie-breaking" {
    const allocator = std.testing.allocator;

    // Create test adjacency list
    var adj = AdjacencyList.init(allocator);
    defer adj.deinit(allocator);

    // Build a simple graph: 1 -> 2 -> 3, 1 -> 4
    try adj.addEdge(1, 2, 101, allocator);
    try adj.addEdge(2, 3, 102, allocator);
    try adj.addEdge(1, 4, 103, allocator);

    // Test path expansion from node 1 with max 2 hops
    const path_expand = PathExpand{
        .min_hops = 1,
        .max_hops = 2,
        .tie_break_policy = .LengthId,
    };

    const start_nodes = [_]u64{1};
    const results = try path_expand.execute(start_nodes[0..], &adj, allocator);
    defer {
        for (results) |result| {
            allocator.free(result.edge_ids);
        }
        allocator.free(results);
    }

    // Should find paths to nodes 2, 3, and 4
    try std.testing.expect(results.len >= 2); // At least direct neighbors

    // Results should be sorted by tie-break policy (length, start_id, end_id)
    for (results[0 .. results.len - 1], results[1..]) |a, b| {
        try std.testing.expect(a.compare(b, .LengthId) != .gt);
    }
}

test "path expand: deterministic tie-breaking" {
    const allocator = std.testing.allocator;

    const result1 = PathExpand.PathResult{
        .start_id = 1,
        .end_id = 2,
        .path_length = 1,
        .edge_ids = &[_]u64{101},
    };

    const result2 = PathExpand.PathResult{
        .start_id = 1,
        .end_id = 3,
        .path_length = 1,
        .edge_ids = &[_]u64{102},
    };

    const result3 = PathExpand.PathResult{
        .start_id = 1,
        .end_id = 2,
        .path_length = 2,
        .edge_ids = &[_]u64{ 101, 103 },
    };

    // Same length, different end_id: result1 < result2
    try std.testing.expect(result1.compare(result2, .LengthId) == .lt);

    // Different length: shorter path wins
    try std.testing.expect(result1.compare(result3, .LengthId) == .lt);

    _ = allocator;
}
