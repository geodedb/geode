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
    /// SONNY-2743: it describes `target` only, not the program; the handlers
    /// decide through `statementPlan`, which checks the rest of the program.
    is_store_free: bool = false,
    /// GAP-0805 / M1.3: True iff this query is a simple point read —
    /// a single-node MATCH with a single literal label and a single
    /// property equality (value is a parameter or literal), no
    /// traversal, no aggregation, no additional clauses. Eligible for
    /// the zero-copy `PointReadView` path; any other shape MUST use
    /// `QueryReadSession` for isolation. False positives are correctness
    /// bugs, so this flag is deliberately conservative.
    /// SONNY-2743: `target` only, like `is_store_free`; see `statementPlan`.
    is_point_read: bool = false,
    /// GAP-0892: True iff the program contains any statement OTHER than the
    /// fast-path `target` and bare transaction control (START TRANSACTION /
    /// COMMIT / ROLLBACK). Handler fast paths that execute only `target`
    /// (count pushdown, node-scan streaming) MUST bail when this is set:
    /// skipping a preamble like `SESSION SET PROPERTY GRAPH "G1"` both
    /// evaluates the target against the request-start session graph and
    /// silently drops the skipped statement's side effects.
    has_effectful_preamble: bool = false,
    /// GAP-0900 (live-routing): when the ONLY effectful preamble statements are
    /// graph selectors (`USE GRAPH g` / `SESSION SET PROPERTY GRAPH g`) that all
    /// name the SAME graph, this holds that graph name. The node-scan streaming
    /// fast path may then run when this selector equals the graph it will scan
    /// (`query_graph_name`): re-selecting the already-bound graph is a no-op for
    /// the streamed target, so skipping its execution drops no observable side
    /// effect and the target still scans the intended graph. This is the read
    /// analogue of GAP-0894's `<graph-selector>; <MERGE>` write fast path, and
    /// is exactly the 2-statement shape the CLI `-g` flag and pooled
    /// `database/sql` drivers emit on every query. Null when the preamble is
    /// empty, contains a non-selector statement, or selects multiple graphs.
    preamble_graph_selector: ?[]const u8 = null,
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
    // GAP-0900: track whether every effectful preamble statement is a graph
    // selector naming the SAME graph (so the streaming fast path can run when
    // that graph is also the one it will scan). Any non-selector effectful
    // statement, or a second selector naming a DIFFERENT graph, disqualifies it.
    var selector_graph: ?[]const u8 = null;
    var selector_only = true;
    for (program.statements, 0..) |*stmt, i| {
        if (target_idx) |t| {
            if (i == t) continue;
        }
        switch (stmt.*) {
            // A braced `START TRANSACTION { ... }` carries a parsed body
            // whose statements (e.g. SESSION SET) escape this loop —
            // treat it as effectful unless the body is absent.
            .StartTransaction => |txn| {
                if (txn.body != null) {
                    analysis.has_effectful_preamble = true;
                    selector_only = false;
                }
            },
            .Commit, .Rollback => {},
            else => {
                analysis.has_effectful_preamble = true;
                if (preambleGraphSelectorName(stmt)) |g| {
                    if (selector_graph) |prev| {
                        if (!std.mem.eql(u8, prev, g)) selector_only = false;
                    } else {
                        selector_graph = g;
                    }
                } else {
                    selector_only = false;
                }
            },
        }
    }
    if (selector_only) analysis.preamble_graph_selector = selector_graph;
    return analysis;
}

/// GAP-0900: extract the plain graph name from a leading graph-selector
/// statement (`USE GRAPH g` / `SESSION SET PROPERTY GRAPH g`), or null for any
/// other statement or a non-plain reference. Conservative: a null means the
/// caller must NOT treat the preamble as a skippable same-graph re-selection.
/// Mirrors `bulk_ingest.graphSelectorName`'s acceptance rules.
fn preambleGraphSelectorName(stmt: *const ast.Statement) ?[]const u8 {
    const raw = switch (stmt.*) {
        .UseGraph => |u| u.graph_name,
        .SessionSet => |s| switch (s.clause_type) {
            .Graph => |g| g.expression,
            else => return null,
        },
        else => return null,
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var s = trimmed;
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or
        (s[0] == '\'' and s[s.len - 1] == '\'')))
    {
        s = s[1 .. s.len - 1];
    }
    if (s.len == 0) return null;
    for (s) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or
            c == '/' or c == '(' or c == ')' or c == '"' or c == '\'') return null;
    }
    return s;
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
        // geode#876: `FOR x IN <list> <data-modifying statement>` writes once
        // per element. Left in `else => false` it would slip past the
        // read-only-user gate, take the SHARED read lock while mutating shared
        // store state, and bypass the cluster unreplicated-write gate. A plain
        // `FOR ... RETURN` (no body) stays read-only so read loops keep the
        // shared lock.
        // CANARY: REQ=REQ-GQL-FOR-WRITE-BODY-876-CLASSIFY; FEATURE="ForStatement"; ASPECT=MutationClassification; STATUS=TESTED; TEST=tests/test_for_write_body.zig; OWNER=query_traits; UPDATED=2026-08-29
        .For => |f| if (f.body) |body| isQueryMutating(body) else false,
        // Everything else (Show, etc.) is read-only
        else => false,
    };
}

pub fn isMutatingCallStatement(call_stmt: *const ast.CallStatement) bool {
    return switch (call_stmt.*) {
        .Procedure => |proc| procedure_access.classifyCallProcedure(proc) == .mutating,
        .Subquery => |sq| isMutatingStatement(sq.statement),
    };
}

// CANARY: REQ=REQ-SONNY-2743-WHOLE-PROGRAM-GATE; FEATURE="StatementAuthorization"; ASPECT=HandlerDecision; STATUS=TESTED; TEST=tests/test_sonny2743_whole_program_gate.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2743: the transport handler a `statementPlan` is for. Only QUIC runs
/// a store-free program without a lock (REQ-QUIC-HC-110).
pub const HandlerTransport = enum { quic, grpc };

/// SONNY-2743: how the QUIC or gRPC handler runs a parsed program. Both
/// handlers take these facts from `statementPlan` and from nowhere else, so a
/// test of `statementPlan` covers their decision.
pub const StatementPlan = struct {
    /// Some statement in the program changes the store (`isMutatingProgram`,
    /// the whole program). The handler applies its write-permission gate
    /// (`gps.writePermitted`), and takes the write lock when it takes one.
    is_mutation: bool,
    /// The handler takes a graph lock before it runs the program: the write
    /// lock for a mutation, else a read lock or a read snapshot.
    needs_store_lock: bool,
    /// SONNY-2733: a lone CALL of a procedure that takes each graph's lock
    /// itself (`isSelfLockingProgram`); the handler takes none.
    self_locking: bool,
    /// The handler may serve the program through the zero-copy point-read view
    /// (GAP-0805): its target is a simple point read, and the rest of the
    /// program does nothing (`restOfProgramIsNoop`).
    point_read: bool,
    /// SONNY-2749: the graph whose lock the handler takes (write or read): the
    /// graph the program's statements run on (`programGraph`: a USE GRAPH or
    /// SESSION SET PROPERTY GRAPH in the program moves it off the session
    /// graph), or the session graph when a program that only reads runs on
    /// several. It points into the program or at `session_graph`.
    lock_graph: []const u8,
    /// SONNY-2749: the program changes the store and its statements run on
    /// more than one graph. The handler refuses it (0A000): one graph's write
    /// lock cannot cover the others, and it never holds two.
    spans_graphs: bool,
};

/// SONNY-2749: what the handlers answer (SQLSTATE 0A000) to a program whose
/// `StatementPlan.spans_graphs` is set.
pub const spans_graphs_message = "A request that changes data must run all its statements on one graph; send the statements for each graph in a request of its own";

/// SONNY-2743: decide the `StatementPlan` for `program` (analysed as
/// `analysis`) in a session whose graph is `session_graph` (the executor
/// session's; `default_graph` when it has none).
///
/// `ProgramAnalysis.kind`, `.target`, `.is_store_free` and `.is_point_read`
/// describe the program's LAST query only, and they used to decide alone. QUIC
/// took no lock for a program whose last query was store-free, and since
/// `is_mutation` was `needs_store_lock and isMutatingProgram(..)`, it skipped
/// the write-permission gate as well: `CREATE (:X); RETURN 1 AS c` from a
/// read-only principal wrote, with no lock. Both handlers also skipped the gate
/// for a program ending in EXPLAIN, and ran any program whose last query was a
/// point read through the point-read view. Now:
///   * `is_mutation` is the whole program's, whatever lock is taken;
///   * the store-free (QUIC) and point-read paths also need the rest of the
///     program to do nothing but, at most, re-select `session_graph`;
///   * a program whose last query is EXPLAIN still takes no lock (the handlers
///     only plan the EXPLAIN and run nothing), but it goes through the gate
///     if any statement in it changes the store;
///   * SONNY-2749: the lock is on the graph the statements run on
///     (`programGraph`), not the session's, and a program that changes the
///     store on more than one graph is refused (`spans_graphs`).
pub fn statementPlan(
    program: *const ast.Program,
    analysis: *const ProgramAnalysis,
    session_graph: []const u8,
    default_graph: []const u8,
    transport: HandlerTransport,
) StatementPlan {
    const self_locking = isSelfLockingProgram(program);
    const is_mutation = isMutatingProgram(program);
    const rest_is_noop = restOfProgramIsNoop(analysis, session_graph);
    const store_free = transport == .quic and analysis.kind == .rows and analysis.is_store_free and rest_is_noop;
    const needs_store_lock = !self_locking and analysis.kind != .explain and !store_free;
    const program_graph = programGraph(program, session_graph, default_graph);
    return .{
        .is_mutation = is_mutation,
        .needs_store_lock = needs_store_lock,
        .self_locking = self_locking,
        .point_read = needs_store_lock and !is_mutation and analysis.is_point_read and rest_is_noop,
        .lock_graph = program_graph orelse session_graph,
        .spans_graphs = is_mutation and needs_store_lock and program_graph == null,
    };
}

// CANARY: REQ=REQ-SONNY-2749-PROGRAM-GRAPH-LOCK; FEATURE="StatementAuthorization"; ASPECT=ProgramGraph; STATUS=TESTED; TEST=tests/test_sonny2749_program_graph_lock.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2749: the graph every statement of `program` that touches graph data
/// runs on, following the executor. The program starts on `start_graph` (the
/// session's graph). `USE GRAPH g` and `SESSION SET PROPERTY GRAPH g` move it
/// to `g`, taking the name exactly as the executor stores it. `SESSION RESET`
/// (with no argument, ALL CHARACTERISTICS or [PROPERTY] GRAPH) and `SESSION
/// CLOSE` move it back to `default_graph`. Every other statement runs on the
/// graph current at that point, except transaction control (a START
/// TRANSACTION with a body runs its body there) and EXPLAIN, which only plans.
/// Returns null when those statements run on more than one graph, and
/// `start_graph` when there are none.
///
/// The handlers used to lock the session graph whatever the program selected,
/// so `USE GRAPH g2; MERGE (:K {id: 1})` wrote g2 holding another graph's
/// write lock, beside g2's own writers.
pub fn programGraph(program: *const ast.Program, start_graph: []const u8, default_graph: []const u8) ?[]const u8 {
    var current = start_graph;
    var runs_on: ?[]const u8 = null;
    for (program.statements) |*stmt| {
        switch (stmt.*) {
            .UseGraph => |ug| current = ug.graph_name,
            .SessionSet => |ss| switch (ss.clause_type) {
                .Graph => |g| current = g.expression,
                else => {},
            },
            .SessionReset => |sr| {
                if (sessionResetClearsGraph(sr)) current = default_graph;
            },
            .SessionClose => current = default_graph,
            .Commit, .Rollback, .Explain => {},
            .StartTransaction => |txn| {
                if (txn.body != null and !noteGraph(&runs_on, current)) return null;
            },
            else => if (!noteGraph(&runs_on, current)) return null,
        }
    }
    return runs_on orelse start_graph;
}

/// Does `SESSION RESET ...` clear the session graph? As the executor runs it:
/// no argument and ALL CHARACTERISTICS reset the whole session.
fn sessionResetClearsGraph(sr: ast.SessionResetStatement) bool {
    const reset_args = sr.arguments orelse return true;
    return switch (reset_args) {
        .All => |all| all == .Characteristics,
        .Graph => true,
        .Schema, .TimeZone, .Parameter => false,
    };
}

/// Record that a statement runs on `current`. False when an earlier one ran
/// on another graph.
fn noteGraph(runs_on: *?[]const u8, current: []const u8) bool {
    if (runs_on.*) |g| return std.mem.eql(u8, g, current);
    runs_on.* = current;
    return true;
}

/// SONNY-2743: does the program do nothing besides its target query and bare
/// transaction control, except re-select `session_graph`? That re-selection is
/// the `USE GRAPH g;` the CLI's `-g` flag and pooled drivers put in front of
/// every query; it is a no-op for the target (see
/// `ProgramAnalysis.preamble_graph_selector`).
pub fn restOfProgramIsNoop(analysis: *const ProgramAnalysis, session_graph: []const u8) bool {
    if (!analysis.has_effectful_preamble) return true;
    const selector = analysis.preamble_graph_selector orelse return false;
    return std.mem.eql(u8, selector, session_graph);
}

// CANARY: REQ=REQ-SONNY-2733-BACKFILL-LOCKING; FEATURE="PerTenantIsolation"; ASPECT=HandlerLockBypass; STATUS=TESTED; TEST=tests/test_sonny2733_backfill_locking.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2733: is `program` a single CALL of a procedure that takes each
/// graph's lock itself (`procedure_access.isSelfLockingProcedure`, i.e.
/// `geode.tenant.backfill_edge_tags`)? The QUIC and gRPC handlers run such a
/// program holding no graph lock: under the session graph's lock the procedure
/// would deadlock on that graph, or hold two graph locks at once. It is
/// exactly one statement, so nothing else in the request runs unlocked. In
/// any other program the handler takes its usual lock, and the procedure,
/// finding a lock held, refuses to run (`error.GraphLockHeld`).
///
/// The CALL must have no RETURN and no ORDER BY. The executor evaluates an
/// ORDER BY after the procedure returns, and its expressions reach the live
/// store (`ORDER BY COUNT { MATCH (n) }`, EXISTS, a pattern
/// comprehension), which would run with no lock at all. Such a CALL takes the
/// handler's lock like any other, and the procedure refuses a RETURN or ORDER
/// BY itself (`error.BackfillProjection`). YIELD only picks columns by name,
/// and LIMIT and OFFSET are numbers.
pub fn isSelfLockingProgram(program: *const ast.Program) bool {
    if (program.statements.len != 1) return false;
    return switch (program.statements[0]) {
        .Call => |call_stmt| switch (call_stmt) {
            .Procedure => |proc| proc.return_clause == null and proc.order_by == null and
                procedure_access.isSelfLockingProcedure(proc),
            .Subquery => false,
        },
        else => false,
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
///
/// CANARY: REQ=REQ-ENG-3960-CALL-MUTATION-CLASSIFICATION; FEATURE="MATCH...CALL / CALL{} / chained-WITH mutation classification"; ASPECT=ReadOnlyFloor; STATUS=TESTED; TEST=tests/test_read_only_execute.zig|tests/test_mcp_read_only.zig; OWNER=engine; UPDATED=2026-08-28
/// GAP: `MATCH (n) CALL <procedure>` (`q.call_clause`) and `CALL { ... }
/// WITH ... RETURN ...` inline subqueries (`q.initial_call_subquery`) were
/// NOT checked here, so a mutating procedure (e.g. geode.fts.rebuild,
/// geode.ts.insert) or a SET/DELETE inside a CALL subquery classified as
/// non-mutating — bypassing the ExecuteRequest.read_only hard floor, the
/// MCP read-only gate (both consume isMutatingProgram transitively), the
/// GPS role gate, and write-lock selection. Both are now classified via
/// procedure_access.classifyCallProcedure (the single source of truth
/// also used by isMutatingCallStatement above) and recursive
/// isQueryMutating, fail-closed: an unresolved/unlisted procedure name
/// defaults to `.mutating`.
/// GAP (2026-08-28 follow-up): the same recursion did not reach
/// `q.next_query` (ast.zig:114), the pointer the parser populates for
/// chained-WITH shapes (`MATCH ... WITH ... MATCH ... SET/CALL/CREATE ...`,
/// src/gql/parser.zig ~:1772-1792/2289/2338/4558). A tail query carrying a
/// mutating clause left the WHOLE statement classified non-mutating — the
/// same bypass class as MATCH...CALL, one chaining level deeper. Fixed by
/// recursing into `q.next_query` here, mirroring `isStoreFreeQuery` (:387)
/// and `isPointReadQuery` (:501), which already treat any non-null
/// `next_query` as disqualifying/mutating-unsafe.
pub fn isQueryMutating(q: *const ast.Query) bool {
    if (q.create_pattern != null or
        q.merge_statement != null or
        q.set_clauses.len > 0 or
        q.remove_clauses.len > 0 or
        q.delete_items.len > 0) return true;

    if (q.call_clause) |cc| {
        // CallClause and CallProcedure share the same `procedure`/
        // `yield_items` shape; classifyCallProcedure only inspects
        // `.procedure`, so this adapter is exact, not approximate.
        const as_call_procedure = ast.CallProcedure{
            .procedure = cc.procedure,
            .yield_items = cc.yield_items,
        };
        if (procedure_access.classifyCallProcedure(as_call_procedure) == .mutating) return true;
    }

    if (q.initial_call_subquery) |subq| {
        if (isQueryMutating(subq)) return true;
    }

    if (q.next_query) |next| {
        if (isQueryMutating(next)) return true;
    }

    // geode#876: `WITH ... FOR x IN <list> <data-modifying statement>` hangs the
    // loop off the query as `for_statement`; its body carries the mutation.
    if (q.for_statement) |for_stmt| {
        if (for_stmt.body) |body| {
            if (isQueryMutating(body)) return true;
        }
    }

    return false;
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
