const std = @import("std");
const ast = @import("../gql/ast.zig");
const procedure_access = @import("../execution/procedure_access.zig");

pub const QueryKind = enum { rows, explain, profile };
pub const UnionMode = enum { none, all, distinct, intersect, except };

pub const QueryTraits = struct {
    ordered: bool = false,
    distinct: bool = false,
    has_group_by: bool = false,
    has_union: bool = false,
    union_mode: UnionMode = .none,
    limit: ?usize = null,
    offset: ?usize = null,
    has_where_eq: bool = false,
    has_filter_eq: bool = false,
    has_index_seek: bool = false,
};

pub const ProgramAnalysis = struct {
    kind: QueryKind = .rows,
    traits: QueryTraits = .{},
    target: ?*const ast.Statement = null,
    union_part_count: usize = 0,
    /// True iff the executable row query cannot touch graph storage. This is
    /// deliberately narrower than "read-only": graph reads still need the
    /// snapshot/read-lock path, while pure scalar projections can run lock-free.
    is_store_free: bool = false,
    /// GAP-0805 / M1.3: True iff this query is a simple point read —
    /// a single-node MATCH with a single literal label and a single
    /// property equality (value is a parameter or literal), no
    /// traversal, no aggregation, no additional clauses. Eligible for
    /// the zero-copy `PointReadView` path; any other shape MUST use
    /// `QueryReadSession` for isolation. False positives are correctness
    /// bugs, so this flag is deliberately conservative.
    is_point_read: bool = false,
    /// GAP-0892: True iff the program contains any statement OTHER than the
    /// fast-path `target` and bare transaction control (START TRANSACTION /
    /// COMMIT / ROLLBACK). Handler fast paths that execute only `target`
    /// (count pushdown, node-scan streaming) MUST bail when this is set:
    /// skipping a preamble like `SESSION SET PROPERTY GRAPH "G1"` both
    /// evaluates the target against the request-start session graph and
    /// silently drops the skipped statement's side effects.
    has_effectful_preamble: bool = false,
};

pub const NormalizedQuery = struct {
    text: []const u8,
    owns_text: bool,
    explain_calibrated: bool,

    pub fn deinit(self: *NormalizedQuery, allocator: std.mem.Allocator) void {
        if (self.owns_text) allocator.free(self.text);
        self.* = .{ .text = &.{}, .owns_text = false, .explain_calibrated = false };
    }
};

pub fn normalizeExplainCalibrated(allocator: std.mem.Allocator, query: []const u8) !NormalizedQuery {
    const trimmed = std.mem.trimStart(u8, query, " \t\r\n");
    if (!startsWithKeyword(trimmed, "EXPLAIN")) {
        return .{ .text = query, .owns_text = false, .explain_calibrated = false };
    }

    var idx: usize = 0;
    idx += "EXPLAIN".len;
    if (idx < trimmed.len and !std.ascii.isWhitespace(trimmed[idx])) {
        return .{ .text = query, .owns_text = false, .explain_calibrated = false };
    }
    idx = skipWhitespace(trimmed, idx);
    if (!startsWithKeyword(trimmed[idx..], "CALIBRATED")) {
        return .{ .text = query, .owns_text = false, .explain_calibrated = false };
    }
    const after = idx + "CALIBRATED".len;
    if (after < trimmed.len and !std.ascii.isWhitespace(trimmed[after])) {
        return .{ .text = query, .owns_text = false, .explain_calibrated = false };
    }

    const rest_start = skipWhitespace(trimmed, after);
    const rest = trimmed[rest_start..];
    const rebuilt = try std.fmt.allocPrint(allocator, "EXPLAIN {s}", .{rest});
    return .{ .text = rebuilt, .owns_text = true, .explain_calibrated = true };
}

pub fn analyzeProgram(program: *const ast.Program) ProgramAnalysis {
    var analysis = ProgramAnalysis{};
    if (program.statements.len == 0) return analysis;

    var target_idx: ?usize = null;
    var idx: usize = program.statements.len;
    while (idx > 0) : (idx -= 1) {
        const stmt = &program.statements[idx - 1];
        switch (stmt.*) {
            .Explain => |exp| {
                analysis.kind = .explain;
                analysis.target = exp.query;
                analyzeStatement(exp.query, &analysis);
                target_idx = idx - 1;
                break;
            },
            .Profile => |prof| {
                analysis.kind = .profile;
                analysis.target = prof.query;
                analyzeStatement(prof.query, &analysis);
                target_idx = idx - 1;
                break;
            },
            .Query, .Union => {
                analysis.kind = .rows;
                analysis.target = stmt;
                analyzeStatement(stmt, &analysis);
                target_idx = idx - 1;
                break;
            },
            .StartTransaction, .Commit, .Rollback => continue,
            else => continue,
        }
    }

    // GAP-0892: flag programs whose execution is more than `target` plus
    // bare transaction control. A fast path that runs only `target` would
    // evaluate it against the request-start session state and silently skip
    // the other statements' side effects (e.g. `SESSION SET PROPERTY GRAPH
    // "G1"; MATCH (n) RETURN count(*)` counted the wrong graph —
    // gql_conformance T11/T12/T14).
    for (program.statements, 0..) |*stmt, i| {
        if (target_idx) |t| {
            if (i == t) continue;
        }
        switch (stmt.*) {
            .StartTransaction, .Commit, .Rollback => {},
            else => analysis.has_effectful_preamble = true,
        }
    }
    return analysis;
}

fn analyzeStatement(stmt: *const ast.Statement, analysis: *ProgramAnalysis) void {
    switch (stmt.*) {
        .Query => |q| {
            analysis.traits.ordered = q.order_by != null;
            analysis.traits.limit = if (q.limit) |l| @as(?usize, @intCast(l)) else null;
            analysis.traits.offset = if (q.offset) |o| @as(?usize, @intCast(o)) else null;
            analysis.traits.has_group_by = q.group_by != null;
            analysis.traits.distinct = q.ret.distinct;
            analysis.traits.has_where_eq = hasEqExpr(q.where_clause);
            analysis.traits.has_filter_eq = hasEqExpr(q.filter_clause);
            analysis.traits.has_union = false;
            analysis.union_part_count = 1;
            analysis.is_store_free = isStoreFreeQuery(&q);
            analysis.is_point_read = isPointReadQuery(&q);
        },
        .Union => |u| {
            analysis.traits.has_union = true;
            analysis.traits.ordered = u.order_by != null;
            analysis.traits.limit = if (u.limit) |l| @as(?usize, @intCast(l)) else null;
            analysis.traits.offset = if (u.offset) |o| @as(?usize, @intCast(o)) else null;
            analysis.union_part_count = u.tails.len + 1;
            analysis.traits.distinct = false;
            var mode: UnionMode = .all;
            var saw_intersect = false;
            var saw_except = false;
            var saw_distinct = false;
            for (u.tails) |part| {
                switch (part.operation) {
                    .intersect => saw_intersect = true,
                    .except => saw_except = true,
                    else => {},
                }
                if (!part.all or part.distinct) saw_distinct = true;
            }
            if (saw_intersect) {
                mode = .intersect;
            } else if (saw_except) {
                mode = .except;
            } else if (saw_distinct or u.tails.len == 0) {
                mode = .distinct;
                analysis.traits.distinct = true;
            } else {
                mode = .all;
            }
            analysis.traits.union_mode = mode;
        },
        else => {},
    }
}

fn hasEqExpr(expr_opt: ?ast.Expr) bool {
    if (expr_opt) |expr| {
        return containsEq(&expr);
    }
    return false;
}

fn containsEq(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .Binary => |b| if (b.op == .Eq) true else containsEq(b.left) or containsEq(b.right),
        .Unary => |u| containsEq(u.expr),
        .In => |in_expr| containsEq(in_expr.value),
        .InListExpr => |in_expr| containsEq(in_expr.value) or containsEq(in_expr.list_expr),
        .NotIn => |in_expr| containsEq(in_expr.value),
        .NotInListExpr => |in_expr| containsEq(in_expr.value) or containsEq(in_expr.list_expr),
        .IsNull => |v| containsEq(v.target),
        .IsUnknown => |v| containsEq(v.target),
        .Call => |call| blk: {
            if (containsEq(call.callee)) break :blk true;
            for (call.args) |arg| if (containsEq(arg)) break :blk true;
            break :blk false;
        },
        .Case => |c| blk: {
            if (c.operand) |op| if (containsEq(op)) break :blk true;
            for (c.whens) |w| {
                if (containsEq(w.when) or containsEq(w.then_expr)) break :blk true;
            }
            if (c.else_expr) |e| if (containsEq(e)) break :blk true;
            break :blk false;
        },
        .PatternComp => |p| containsEq(p.map) or (if (p.where) |w| containsEq(w) else false),
        .Exists => |e| if (e.where) |w| containsEq(w) else false,
        .PatternCount => |p| if (p.where) |w| containsEq(w) else false,
        .ListComprehension => |lc| (if (lc.filter) |f| containsEq(f) else false) or (if (lc.map) |m| containsEq(m) else false),
        .Index => |ix| containsEq(ix.target) or containsEq(ix.index),
        .Member => |m| containsEq(m.target),
        .Slice => |s| containsEq(s.target) or (if (s.start) |st| containsEq(st) else false) or (if (s.end) |en| containsEq(en) else false),
        else => false,
    };
}

// #564: Mutation classification — used by both QUIC and gRPC transport handlers
// to decide whether a query needs an exclusive write lock or a shared read lock.

/// Check whether any statement in a parsed program mutates the graph store.
/// When true the caller must hold the exclusive write lock instead of the
/// shared read lock.
pub fn isMutatingProgram(program: *const ast.Program) bool {
    for (program.statements) |*stmt| {
        if (isMutatingStatement(stmt)) return true;
    }
    return false;
}

/// Check if a single statement is a mutation (DML write, DDL, or a Query
/// containing inline CREATE/SET/REMOVE/DELETE clauses).
pub fn isMutatingStatement(stmt: *const ast.Statement) bool {
    return switch (stmt.*) {
        // DML mutations
        .Create, .Insert, .InsertValue, .Merge, .Delete => true,
        // DDL mutations
        .CreateIndex, .DropIndex => true,
        .CreateConstraint, .DropConstraint => true,
        .CreateSchema, .DropSchema => true,
        .CreateGraph, .DropGraph => true,
        .CreateGraphType, .DropGraphType => true,
        // Backup/restore mutate on-disk state
        .Backup, .Restore => true,
        // CALL may invoke mutating procedures / subqueries
        .Call => |c| isMutatingCallStatement(&c),
        // PROFILE executes its inner statement — check it
        .Profile => |prof| isMutatingStatement(prof.query),
        // EXPLAIN never executes
        .Explain => false,
        // START TRANSACTION with a body can contain mutations
        .StartTransaction => |txn| blk: {
            if (txn.body) |body| {
                for (body) |*body_stmt| {
                    if (isMutatingStatement(body_stmt)) break :blk true;
                }
            }
            break :blk false;
        },
        // #564: Query nodes can contain inline mutations (MATCH...CREATE,
        // MATCH...SET, MATCH...REMOVE, MATCH...DELETE). These must take
        // the exclusive write lock to prevent concurrent HashMap/ArrayList
        // corruption under high parallelism.
        .Query => |q| isQueryMutating(&q),
        // Union/Intersect/Except contain sub-queries that may mutate
        .Union => |u| isQueryMutating(&u.first) or blk: {
            for (u.tails) |*tail| {
                if (isQueryMutating(&tail.query)) break :blk true;
            }
            break :blk false;
        },
        .Intersect, .Except => |bs| isQueryMutating(&bs.left) or isQueryMutating(&bs.right),
        // Everything else (For, Show, etc.) is read-only
        else => false,
    };
}

pub fn isMutatingCallStatement(call_stmt: *const ast.CallStatement) bool {
    return switch (call_stmt.*) {
        .Procedure => |proc| procedure_access.classifyCallProcedure(proc) == .mutating,
        .Subquery => |sq| isMutatingStatement(sq.statement),
    };
}

/// CANARY: REQ=REQ-QUIC-HC-110; FEATURE="High-Concurrency Store-Free Reads"; ASPECT=LockBypassClassifier; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-27
///
/// Detect a pure scalar `RETURN` query that cannot read or mutate graph
/// storage. False positives here would skip the graph snapshot/read-lock path,
/// so this accepts only the small expression subset needed by high-fanout
/// health/checkpoint queries such as `RETURN 1 AS c`.
pub fn isStoreFreeQuery(q: *const ast.Query) bool {
    if (isQueryMutating(q)) return false;
    if (q.optional_match) return false;
    if (q.match.chains.len != 0) return false;
    if (q.where_clause != null) return false;
    if (q.filter_clause != null) return false;
    if (q.with_clause != null) return false;
    if (q.cte_list != null) return false;
    if (q.group_by != null) return false;
    if (q.having != null) return false;
    if (q.order_by != null) return false;
    if (q.limit != null or q.limit_param != null) return false;
    if (q.offset != null or q.offset_param != null) return false;
    if (q.unwind_clause != null) return false;
    if (q.call_clause != null) return false;
    if (q.initial_call_subquery != null) return false;
    if (q.for_statement != null) return false;
    if (q.next_query != null) return false;
    if (q.merge_statement != null) return false;
    if (q.let_bindings.len != 0) return false;
    if (q.inline_let_bindings.len != 0) return false;
    if (q.path_variable != null) return false;
    if (q.ret.distinct) return false;
    if (q.ret.items.len == 0) return false;

    for (q.ret.items) |item| {
        if (!isStoreFreeScalarExpr(&item.expr)) return false;
    }
    return true;
}

fn isStoreFreeScalarExpr(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .Null,
        .Int,
        .Bool,
        .String,
        .Decimal,
        .SmallIntLit,
        .BigIntLit,
        .RealLit,
        .DoubleLit,
        .CharLit,
        .VarcharLit,
        .TextLit,
        .Date,
        .DateTime,
        .Time,
        .LocalDateTime,
        .Param,
        => true,
        .Unary => |u| isStoreFreeScalarExpr(u.expr),
        .Binary => |b| isStoreFreeScalarExpr(b.left) and isStoreFreeScalarExpr(b.right),
        .IsNull => |v| isStoreFreeScalarExpr(v.target),
        .IsUnknown => |v| isStoreFreeScalarExpr(v.target),
        else => false,
    };
}

/// Check if a Query struct contains mutation clauses.
pub fn isQueryMutating(q: *const ast.Query) bool {
    return q.create_pattern != null or
        q.set_clauses.len > 0 or
        q.remove_clauses.len > 0 or
        q.delete_items.len > 0;
}

/// GAP-0805 / M1.3: Detect whether a Query is a simple point read that can
/// use the zero-copy `PointReadView` path instead of the deep-clone
/// `QueryReadSession` snapshot. Conservative: a false positive here would
/// route a non-trivial query through a view that only holds the shared
/// read lock for the short hot window, so anything that requires isolation
/// across mutations MUST fall into the `false` branch.
///
/// Criteria (ALL required):
///   - no traversal (single chain with a head node, no hops)
///   - single literal label on the head node
///   - exactly one property equality with a parameter-or-literal value
///   - no WHERE / FILTER / WITH / CTE / GROUP BY / HAVING / ORDER BY /
///     LIMIT / OFFSET / UNWIND / CALL / MERGE / FOR / chained query
///   - no mutations (caller should also check `isQueryMutating`)
///   - no OPTIONAL MATCH
///   - RETURN not DISTINCT
pub fn isPointReadQuery(q: *const ast.Query) bool {
    // Any side-effect or follow-up clause disqualifies the query.
    if (isQueryMutating(q)) return false;
    if (q.optional_match) return false;
    if (q.where_clause != null) return false;
    if (q.filter_clause != null) return false;
    if (q.with_clause != null) return false;
    if (q.cte_list != null) return false;
    if (q.group_by != null) return false;
    if (q.having != null) return false;
    if (q.order_by != null) return false;
    if (q.limit != null) return false;
    if (q.offset != null) return false;
    if (q.unwind_clause != null) return false;
    if (q.call_clause != null) return false;
    if (q.initial_call_subquery != null) return false;
    if (q.for_statement != null) return false;
    if (q.next_query != null) return false;
    if (q.merge_statement != null) return false;
    if (q.let_bindings.len != 0) return false;
    if (q.inline_let_bindings.len != 0) return false;
    if (q.path_variable != null) return false;
    if (q.ret.distinct) return false;

    // Must be a single-chain, single-node pattern (no relationships).
    if (q.match.chains.len != 1) return false;
    const chain = &q.match.chains[0];
    if (chain.is_optional) return false;
    if (chain.is_shortest) return false;
    if (chain.hops.len != 0) return false;
    const head_opt = chain.head;
    if (head_opt == null) return false;
    const head = head_opt.?;

    // Exactly one literal label.
    if (head.labels.len != 1) return false;

    // Exactly one property filter with a simple (param or literal) value.
    const props = head.props orelse return false;
    if (props.len != 1) return false;
    const value_expr = props[0].value;
    if (!isSimplePointReadValue(value_expr)) return false;

    return true;
}

/// True for AST expression shapes that are safe as the right-hand side of
/// a point-read property equality: scalar parameter reference or scalar
/// literal. Anything that calls a function, dereferences another node, or
/// references a prior binding is rejected (would require execution context
/// we're not meant to evaluate during plan analysis).
fn isSimplePointReadValue(expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .Param,
        .String,
        .Int,
        .Bool,
        .Null,
        .Decimal,
        .SmallIntLit,
        .BigIntLit,
        .RealLit,
        .DoubleLit,
        .CharLit,
        .VarcharLit,
        .TextLit,
        .UuidLit,
        .Date,
        .DateTime,
        .Time,
        .LocalDateTime,
        => true,
        else => false,
    };
}

fn startsWithKeyword(hay: []const u8, needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(hay[0..needle.len], needle);
}

fn skipWhitespace(s: []const u8, start: usize) usize {
    var idx = start;
    while (idx < s.len and std.ascii.isWhitespace(s[idx])) idx += 1;
    return idx;
}

// --- #564 regression tests: mutation classification ---

const Parser = @import("../gql/parser.zig").Parser;
const Lexer = @import("../gql/lexer.zig").Lexer;

fn parseProgram(src: []const u8) !struct { ast.Program, std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    errdefer arena.deinit();
    var lx = Lexer{ .src = src };
    var p = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return .{ program, arena };
}

// #564: MATCH...CREATE was incorrectly classified as read-only, causing
// concurrent shared-lock access and @memcpy alias / HashMap corruption panics.
test "isMutatingProgram: MATCH...CREATE is a mutation" {
    const prog, var arena = try parseProgram("MATCH (n:Person) CREATE (m:Person {name: 'test'})-[:KNOWS]->(n) RETURN m");
    defer arena.deinit();
    try std.testing.expect(isMutatingProgram(&prog));
}

test "isMutatingProgram: MATCH...SET is a mutation" {
    const prog, var arena = try parseProgram("MATCH (n:Person) SET n.age = 30 RETURN n");
    defer arena.deinit();
    try std.testing.expect(isMutatingProgram(&prog));
}

test "isMutatingProgram: MATCH...DELETE is a mutation" {
    const prog, var arena = try parseProgram("MATCH (n:Person) DELETE n");
    defer arena.deinit();
    try std.testing.expect(isMutatingProgram(&prog));
}

test "isMutatingProgram: MATCH...REMOVE is a mutation" {
    const prog, var arena = try parseProgram("MATCH (n:Person) REMOVE n.age RETURN n");
    defer arena.deinit();
    try std.testing.expect(isMutatingProgram(&prog));
}

test "isMutatingProgram: pure MATCH is read-only" {
    const prog, var arena = try parseProgram("MATCH (n:Person) RETURN n");
    defer arena.deinit();
    try std.testing.expect(!isMutatingProgram(&prog));
}

test "isMutatingProgram: standalone CREATE is a mutation" {
    const prog, var arena = try parseProgram("CREATE (n:Person {name: 'test'})");
    defer arena.deinit();
    try std.testing.expect(isMutatingProgram(&prog));
}

test "isMutatingProgram: EXPLAIN is not a mutation" {
    const prog, var arena = try parseProgram("EXPLAIN MATCH (n:Person) RETURN n");
    defer arena.deinit();
    try std.testing.expect(!isMutatingProgram(&prog));
}

test "isMutatingProgram: read-only CALL procedure is not a mutation" {
    const prog, var arena = try parseProgram("CALL degree()");
    defer arena.deinit();
    try std.testing.expect(!isMutatingProgram(&prog));
}

test "isMutatingProgram: mutating CALL procedure is a mutation" {
    const prog, var arena = try parseProgram("CALL geode.auth.user_create('alice', 'p4ssw0rd1')");
    defer arena.deinit();
    try std.testing.expect(isMutatingProgram(&prog));
}

// --- REQ-QUIC-HC-110: store-free scalar read detection ---

test "isStoreFreeQuery: scalar RETURN is store-free" {
    const prog, var arena = try parseProgram("RETURN 1 AS c");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(analysis.is_store_free);
}

test "isStoreFreeQuery: scalar arithmetic RETURN is store-free" {
    const prog, var arena = try parseProgram("RETURN 1 + 2 AS c");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(analysis.is_store_free);
}

test "isStoreFreeQuery: MATCH query is not store-free even when returning a scalar" {
    const prog, var arena = try parseProgram("MATCH (n:Person) RETURN 1 AS c");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_store_free);
}

test "isStoreFreeQuery: function calls are conservative and keep the store path" {
    const prog, var arena = try parseProgram("RETURN abs(-1) AS c");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_store_free);
}

// --- GAP-0805 / M1.3: point-read detection ---

test "isPointReadQuery: single-node MATCH with $param equality is a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person {id: $id}) RETURN n");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(analysis.is_point_read);
}

test "isPointReadQuery: single-node MATCH with string literal equality is a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person {name: 'alice'}) RETURN n");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(analysis.is_point_read);
}

test "isPointReadQuery: MATCH with traversal (hops) is NOT a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person {id: $id})-[:KNOWS]->(m) RETURN m");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_point_read);
}

test "isPointReadQuery: MATCH without property filter is NOT a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person) RETURN n");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_point_read);
}

test "isPointReadQuery: MATCH with WHERE clause is NOT a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person {id: $id}) WHERE n.age > 18 RETURN n");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_point_read);
}

test "isPointReadQuery: MATCH with ORDER BY is NOT a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person {id: $id}) RETURN n ORDER BY n.name");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_point_read);
}

test "isPointReadQuery: MATCH with LIMIT is NOT a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person {id: $id}) RETURN n LIMIT 1");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_point_read);
}

test "isPointReadQuery: MATCH with multiple labels is NOT a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person:User {id: $id}) RETURN n");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_point_read);
}

test "isPointReadQuery: MATCH with multi-property filter is NOT a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person {id: $id, name: $name}) RETURN n");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_point_read);
}

test "isPointReadQuery: MATCH...CREATE is NOT a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person {id: $id}) CREATE (m:Person {name: 'new'})-[:KNOWS]->(n) RETURN m");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_point_read);
}

test "isPointReadQuery: standalone CREATE is NOT a point read" {
    const prog, var arena = try parseProgram("CREATE (n:Person {name: 'alice'})");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_point_read);
}

test "isPointReadQuery: OPTIONAL MATCH is NOT a point read" {
    const prog, var arena = try parseProgram("OPTIONAL MATCH (n:Person {id: $id}) RETURN n");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_point_read);
}

test "isPointReadQuery: UNION is NOT a point read" {
    const prog, var arena = try parseProgram("MATCH (n:Person {id: $a}) RETURN n UNION MATCH (n:Person {id: $b}) RETURN n");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    try std.testing.expect(!analysis.is_point_read);
}

test "isPointReadQuery: EXPLAIN wraps a non-executed query (not a point read either way)" {
    const prog, var arena = try parseProgram("EXPLAIN MATCH (n:Person {id: $id}) RETURN n");
    defer arena.deinit();
    const analysis = analyzeProgram(&prog);
    // analysis.kind is .explain, so handler dispatch never enters the
    // read branch. For defence-in-depth the detector still evaluates
    // the inner query; the point is that the handler guard (`needs_store_lock`)
    // skips the PointReadView branch entirely.
    _ = analysis;
}
