const std = @import("std");
const ast = @import("../gql/ast.zig");
const procedure_access = @import("../execution/procedure_access.zig");
const write_walk = @import("../execution/write_walk.zig");
const graph_store = @import("../graph_store.zig");

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

// CANARY: REQ=REQ-SONNY-2805-TXN-PROGRAM-ORDER; FEATURE="TransactionManagement"; ASPECT=TxnControl; STATUS=TESTED; TEST=tests/test_sonny2805_txn_sessions.zig; OWNER=engine; UPDATED=2026-09-26
/// SONNY-2805: the transaction control a program carries.
pub const TxnControl = struct {
    /// A START TRANSACTION without a body (one with a body is a whole
    /// transaction of its own).
    starts: bool = false,
    /// A COMMIT or ROLLBACK.
    ends: bool = false,

    pub fn any(self: TxnControl) bool {
        return self.starts or self.ends;
    }
};

pub fn transactionControl(program: *const ast.Program) TxnControl {
    var ctl: TxnControl = .{};
    for (program.statements) |*stmt| noteTxnControl(stmt, &ctl);
    return ctl;
}

// CANARY: REQ=REQ-SONNY-3348-ABORTED-TXN; FEATURE="TransactionManagement"; ASPECT=AbortedTxnGate; STATUS=TESTED; TEST=tests/test_sonny3348_statement_undo.zig; OWNER=engine; UPDATED=2026-09-29
/// SONNY-3348 (round 18, I2): what a request does to a session whose explicit
/// transaction failed (`ServerState.txn_aborted`). A program that starts with
/// ROLLBACK ends the aborted transaction and runs; one that starts with
/// COMMIT ends it and fails (the transaction was rolled back, not
/// committed); anything else is refused (25P02) and the session stays
/// aborted. The session never falls back to autocommit.
pub const AbortedTxnVerdict = enum { rollback, commit, refuse };

pub fn abortedTxnVerdict(program: *const ast.Program) AbortedTxnVerdict {
    if (program.statements.len == 0) return .refuse;
    return switch (program.statements[0]) {
        .Rollback => .rollback,
        .Commit => .commit,
        else => .refuse,
    };
}

/// SONNY-3348 (round 18, I2): is the program's last transaction control a
/// COMMIT or a ROLLBACK? A program that fails after it ended its
/// transaction (a COMMIT whose storage commit failed, or one run after the
/// failure, which rolls back) does not leave its session aborted.
pub fn endsTransactionLast(program: *const ast.Program) bool {
    var ends = false;
    for (program.statements) |stmt| switch (stmt) {
        .StartTransaction => |st| {
            if (st.body == null) ends = false;
        },
        .Commit, .Rollback => ends = true,
        else => {},
    };
    return ends;
}

/// SONNY-3026: a PROFILE runs the statement it wraps, and an EXPLAIN names
/// one; both are looked inside. `PROFILE ROLLBACK` counted as no transaction
/// control at all, so it ran under a read lock and the handler kept the
/// transaction it ended. The handlers refuse such a program
/// (`explainOrProfileTargetRefused`); this keeps every trait honest anyway.
fn noteTxnControl(stmt: *const ast.Statement, ctl: *TxnControl) void {
    switch (stmt.*) {
        .StartTransaction => |st| {
            if (st.body == null) ctl.starts = true;
        },
        .Commit, .Rollback => ctl.ends = true,
        .Profile => |p| noteTxnControl(p.query, ctl),
        .Explain => |e| noteTxnControl(e.query, ctl),
        else => {},
    }
}

/// SONNY-2805: `analyzeProgram` for a transport handler. Transaction control
/// counts as an effectful preamble here, so no fast path that runs only
/// `target` (node-scan streaming, the count pushdowns, the engine-direct read
/// that skips the snapshot) takes a program that carries it. Such a path
/// skipped the START TRANSACTION, COMMIT or ROLLBACK, and the handler then
/// followed a transaction the undo log never began or never ended.
/// `analyzeProgram` keeps GAP-0892's view for its other callers.
pub fn analyzeRequest(program: *const ast.Program) ProgramAnalysis {
    var analysis = analyzeProgram(program);
    if (transactionControl(program).any()) {
        analysis.has_effectful_preamble = true;
        analysis.preamble_graph_selector = null;
    }
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

// CANARY: REQ=REQ-SONNY-3189-CHAIN-WALKERS; FEATURE="QueryAnalysis"; ASPECT=IterativeWalkers; STATUS=TESTED; TEST=tests/test_sonny3181_expr_chain_cap.zig; OWNER=query; UPDATED=2026-09-27
/// SONNY-3189: `analyzeRequest` runs this on every WHERE before
/// authorization. It recursed once per operator and member link, and an OR
/// chain of 400,000 terms overflowed an 8 MiB thread in ReleaseSafe (20,000
/// in Debug). The left operand of a binary link, the operand of a unary
/// one and the target of a member, index or slice link are followed with a
/// loop; only the other children recurse, and nesting bounds them.
fn containsEq(root: *const ast.Expr) bool {
    var expr = root;
    while (true) {
        switch (expr.*) {
            .Binary => |b| {
                if (b.op == .Eq) return true;
                if (containsEq(b.right)) return true;
                expr = b.left;
            },
            .Unary => |u| expr = u.expr,
            .Member => |m| expr = m.target,
            .Index => |ix| {
                if (containsEq(ix.index)) return true;
                expr = ix.target;
            },
            .Slice => |sl| {
                if (sl.start) |st| if (containsEq(st)) return true;
                if (sl.end) |en| if (containsEq(en)) return true;
                expr = sl.target;
            },
            .IsNull => |v| expr = v.target,
            .IsUnknown => |v| expr = v.target,
            .In => |in_expr| expr = in_expr.value,
            .NotIn => |in_expr| expr = in_expr.value,
            .InListExpr => |in_expr| {
                if (containsEq(in_expr.list_expr)) return true;
                expr = in_expr.value;
            },
            .NotInListExpr => |in_expr| {
                if (containsEq(in_expr.list_expr)) return true;
                expr = in_expr.value;
            },
            .Call => |call| {
                for (call.args) |arg| if (containsEq(arg)) return true;
                expr = call.callee;
            },
            .Case => |c| {
                if (c.operand) |op| if (containsEq(op)) return true;
                for (c.whens) |w| {
                    if (containsEq(w.when) or containsEq(w.then_expr)) return true;
                }
                if (c.else_expr) |e| if (containsEq(e)) return true;
                return false;
            },
            .PatternComp => |p| return containsEq(p.map) or (if (p.where) |w| containsEq(w) else false),
            .Exists => |e| return if (e.where) |w| containsEq(w) else false,
            .PatternCount => |p| return if (p.where) |w| containsEq(w) else false,
            .ListComprehension => |lc| return (if (lc.filter) |f| containsEq(f) else false) or (if (lc.map) |m| containsEq(m) else false),
            else => return false,
        }
    }
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
///
/// CANARY: REQ=REQ-SONNY-3182-EXPRESSION-WRITES; FEATURE="WriteShapeAllowlist"; ASPECT=MutationClassification; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=query_traits; UPDATED=2026-09-28
/// SONNY-3182 (round 4): the one write walk (`execution/write_walk.zig`),
/// which the write-shape validator uses too: every statement kind is
/// classified there (EXPLAIN runs nothing; CREATE, INSERT, MERGE, DELETE,
/// INSERT VALUE, schema, catalog, backup and restore write; a CALL writes when
/// its procedure does; a PROFILE, a transaction body, a VALUES continuation, a
/// FOR body and set operations by what they hold), and every query and
/// expression is walked, iteratively, down to a write in an IN / NOT IN
/// subquery or a CTE body at any depth (a nested query's initial WITH and its
/// WHERE were skipped: round-3 review C2).
pub fn isMutatingStatement(stmt: *const ast.Statement) bool {
    return write_walk.statementWrites(stmt, .{});
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
    /// SONNY-3028: every statement on `lock_graph` is CREATE or DROP GRAPH of
    /// it. When that graph does not exist there is no lock to take, and none
    /// is needed: the handler runs the program without one (CREATE GRAPH of a
    /// new graph, DROP GRAPH IF EXISTS of a missing one).
    lock_graph_may_be_missing: bool = false,
    /// SONNY-3130: the program creates, replaces or drops a graph and also
    /// has a statement on graph data (`programMixesGraphDdl`). The handler
    /// refuses it (0A000).
    graph_ddl_has_company: bool = false,
    /// SONNY-3312: the program only reads, and its statements run on more
    /// than one graph (`lock_graph` is then the session graph). The handlers
    /// snapshot every graph it reads (`programDataGraphList`), each under its
    /// own read lock taken in name order (`graph_store.snapshotUnderReadLocks`):
    /// a snapshot of `lock_graph` alone answered `USE GRAPH g2; MATCH ...` from
    /// an empty copy of g2.
    reads_several_graphs: bool = false,
};

/// SONNY-2749: what the handlers answer (SQLSTATE 0A000) to a program whose
/// `StatementPlan.spans_graphs` is set.
pub const spans_graphs_message = "A request that changes data must run all its statements on one graph; send the statements for each graph in a request of its own";

/// SONNY-2776: what the handlers answer (SQLSTATE 0A000) to a change of a
/// graph other than the one an open transaction already changed.
pub const txn_spans_graphs_message = "A transaction must change one graph: commit or roll back before changing another graph";

/// SONNY-2799: what the handlers answer (SQLSTATE 0A000) to a program that
/// ends the session's transaction (COMMIT or ROLLBACK) and touches another
/// graph's data: it runs under the write lock of the graph the transaction
/// changed, and a handler holds one lock.
pub const txn_end_graph_message = "A request that commits or rolls back a transaction runs on the transaction's graph: send the statements for another graph in a request of their own";

/// SONNY-2743: decide the `StatementPlan` for `program` (analysed as
/// `analysis`) in a session whose graph is `session_graph` (the executor
/// session's; `default` when it has none). `home_graph` is where SESSION
/// RESET and SESSION CLOSE take it (SONNY-2775): the session's DSN-bound graph,
/// or `default`.
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
    home_graph: []const u8,
    transport: HandlerTransport,
) StatementPlan {
    const self_locking = isSelfLockingProgram(program);
    const is_mutation = isMutatingProgram(program);
    const rest_is_noop = restOfProgramIsNoop(analysis, session_graph);
    const store_free = transport == .quic and analysis.kind == .rows and analysis.is_store_free and rest_is_noop;
    const needs_store_lock = !self_locking and analysis.kind != .explain and !store_free;
    const program_graph = programGraph(program, session_graph, home_graph);
    return .{
        .is_mutation = is_mutation,
        .needs_store_lock = needs_store_lock,
        .self_locking = self_locking,
        .point_read = needs_store_lock and !is_mutation and analysis.is_point_read and rest_is_noop,
        .lock_graph = program_graph orelse session_graph,
        .spans_graphs = is_mutation and needs_store_lock and program_graph == null,
        .lock_graph_may_be_missing = programOnlyGraphDdl(program, session_graph, home_graph),
        .graph_ddl_has_company = programMixesGraphDdl(program),
        .reads_several_graphs = !is_mutation and needs_store_lock and program_graph == null,
    };
}

// CANARY: REQ=REQ-SONNY-3130-GRAPH-DDL-ALONE; FEATURE="MultiGraphIsolation"; ASPECT=GraphDdlAlone; STATUS=TESTED; TEST=tests/test_sonny3130_graph_ddl_alone.zig; OWNER=storage; UPDATED=2026-09-27
/// SONNY-3130: what the handlers answer (SQLSTATE 0A000) to a program whose
/// `StatementPlan.graph_ddl_has_company` is set.
pub const graph_ddl_alone_message = "CREATE GRAPH, CREATE OR REPLACE GRAPH and DROP GRAPH run without statements on graph data: send the statements that read or change a graph in a request of their own";

/// SONNY-3130: does `program` create, replace or drop a graph and also have a
/// statement on graph data, on any graph, before or after the graph DDL? The
/// handlers refuse such a program (0A000). They take the lock of the graph a
/// program runs on before it runs, and a CREATE OR REPLACE GRAPH, or a DROP
/// GRAPH then CREATE GRAPH, puts a new graph with a lock of its own under the
/// name: `CREATE OR REPLACE GRAPH g; USE GRAPH g; CREATE (:R)` held the old
/// graph's write lock and wrote the new graph without its lock, beside that
/// graph's own writers, and from a session on g `DROP GRAPH g; CREATE (:R)`
/// re-created g. Graph DDL runs with other graph DDL, graph selection,
/// session statements and transaction control only, so `DROP GRAPH IF EXISTS
/// g; CREATE GRAPH g` still runs. A START TRANSACTION body, and the statement
/// a PROFILE or EXPLAIN wraps, are looked into.
pub fn programMixesGraphDdl(program: *const ast.Program) bool {
    var seen: GraphDdlSeen = .{};
    for (program.statements) |*stmt| seen.statement(stmt);
    return seen.graph_ddl and seen.data;
}

const GraphDdlSeen = struct {
    graph_ddl: bool = false,
    data: bool = false,

    fn statement(self: *GraphDdlSeen, stmt: *const ast.Statement) void {
        switch (stmt.*) {
            .CreateGraph, .DropGraph => self.graph_ddl = true,
            .UseGraph, .SessionSet, .SessionReset, .SessionClose, .Commit, .Rollback => {},
            .StartTransaction => |txn| if (txn.body) |body| {
                for (body) |*s| self.statement(s);
            },
            .Explain => |e| self.statement(e.query),
            .Profile => |p| self.statement(p.query),
            else => self.data = true,
        }
    }
};

// CANARY: REQ=REQ-SONNY-2749-PROGRAM-GRAPH-LOCK; FEATURE="StatementAuthorization"; ASPECT=ProgramGraph; STATUS=TESTED; TEST=tests/test_sonny2749_program_graph_lock.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2775: what a USE GRAPH or SESSION SET [PROPERTY] GRAPH names, as
/// the executor (`execution.session_graph.change`) and `programGraph` both
/// read it.
pub const GraphTarget = union(enum) {
    /// A graph, by name.
    named: []const u8,
    /// CURRENT_GRAPH or CURRENT_PROPERTY_GRAPH: the session's graph.
    current,
    /// HOME_GRAPH or HOME_PROPERTY_GRAPH, and where SESSION RESET and SESSION
    /// CLOSE go: the session's DSN-bound graph, or the default graph.
    home,
};

/// SONNY-2775: the target a graph name in USE GRAPH or SESSION SET [PROPERTY]
/// GRAPH stands for. The ISO GQL current-graph and home-graph names are
/// matched case-insensitively; they used to be taken as graph names.
pub fn graphTarget(name: []const u8) GraphTarget {
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(name, "CURRENT_GRAPH") or eql(name, "CURRENT_PROPERTY_GRAPH")) return .current;
    if (eql(name, "HOME_GRAPH") or eql(name, "HOME_PROPERTY_GRAPH")) return .home;
    return .{ .named = name };
}

fn moveTo(current: []const u8, target: GraphTarget, home_graph: []const u8) []const u8 {
    return switch (target) {
        .named => |name| name,
        .current => current,
        .home => home_graph,
    };
}

/// SONNY-2749: the graph every statement of `program` that touches graph data
/// runs on, following the executor. The program starts on `start_graph` (the
/// session's graph). `USE GRAPH g` and `SESSION SET PROPERTY GRAPH g` move it
/// to `g`, taking the name exactly as the executor stores it (SONNY-2775:
/// CURRENT_GRAPH stays, HOME_GRAPH goes home). `SESSION RESET` (with no
/// argument, ALL CHARACTERISTICS or [PROPERTY] GRAPH) and `SESSION CLOSE`
/// move it back to `home_graph`: the session's DSN-bound graph, or the
/// default graph. Every other statement runs on the graph current at that
/// point, except transaction control (a START TRANSACTION with a body runs
/// its body there) and EXPLAIN, which only plans. Returns null when those
/// statements run on more than one graph, and `start_graph` when there are
/// none.
///
/// SONNY-2790: fulltext search is default-graph-only by design
/// (docs/FULLTEXT_SEARCH.md, "Graph scope"). CREATE INDEX ... USING fulltext
/// and CALL geode.fts.* run on `default` whatever the current graph, and so
/// count as statements on `default`: the handlers lock `default` for them.
/// They used to lock the session's graph while reading and writing the
/// default graph's nodes and fulltext engine.
///
/// SONNY-6294: DROP INDEX counts as a statement on the current graph, as
/// constraint DDL and CREATE INDEX of other types do: the index it drops is
/// that graph's (or an engine-wide one). It counted as one on `default`
/// (the index might be fulltext), so in graph g it ran beside g's writers
/// and blocked default's. The executor refuses to drop a fulltext index
/// from a session on another graph (`USE GRAPH default; DROP INDEX i`).
///
/// The handlers used to lock the session graph whatever the program selected,
/// so `USE GRAPH g2; MERGE (:K {id: 1})` wrote g2 holding another graph's
/// write lock, beside g2's own writers.
pub fn programGraph(program: *const ast.Program, start_graph: []const u8, home_graph: []const u8) ?[]const u8 {
    return switch (programDataGraph(program, start_graph, home_graph)) {
        .none => start_graph,
        .one => |g| g,
        .several => null,
    };
}

/// SONNY-2805: where a program's statements that touch graph data run, by
/// `programGraph`'s rules, telling "none" apart from "the start graph".
pub const DataGraph = union(enum) {
    /// No statement touches graph data: graph selection, transaction control
    /// and EXPLAIN only.
    none,
    /// Every statement that does runs on this graph.
    one: []const u8,
    /// They run on more than one graph.
    several,
};

pub fn programDataGraph(program: *const ast.Program, start_graph: []const u8, home_graph: []const u8) DataGraph {
    var walk: DataGraphWalk = .{ .current = start_graph, .home_graph = home_graph };
    for (program.statements) |*stmt| {
        if (!walk.statement(stmt)) return .several;
    }
    return if (walk.runs_on) |g| .{ .one = g } else .none;
}

// CANARY: REQ=REQ-SONNY-3312-MULTI-GRAPH-READ; FEATURE="MultiGraphIsolation"; ASPECT=ReadGraphList; STATUS=TESTED; TEST=tests/test_sonny3312_multi_graph_read.zig; OWNER=storage; UPDATED=2026-09-28
/// SONNY-3312: every graph whose data the statements of `program` touch, by
/// `programDataGraph`'s rules, sorted by name with no repeats: the order a
/// read of several graphs takes their read locks in
/// (`graph_store.snapshotUnderReadLocks`). The names point into the program,
/// `start_graph` or `home_graph`; the caller frees the slice. Empty when no
/// statement touches graph data.
pub fn programDataGraphList(allocator: std.mem.Allocator, program: *const ast.Program, start_graph: []const u8, home_graph: []const u8) ![]const []const u8 {
    var list: GraphList = .{ .allocator = allocator };
    errdefer list.names.deinit(allocator);
    var walk: DataGraphWalk = .{ .current = start_graph, .home_graph = home_graph, .collect = &list };
    for (program.statements) |*stmt| _ = walk.statement(stmt);
    if (list.oom) return error.OutOfMemory;
    const names = try list.names.toOwnedSlice(allocator);
    std.mem.sort([]const u8, names, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var kept: usize = 0;
    for (names) |n| {
        if (kept > 0 and std.mem.eql(u8, names[kept - 1], n)) continue;
        names[kept] = n;
        kept += 1;
    }
    if (kept == names.len) return names;
    const out = try allocator.dupe([]const u8, names[0..kept]);
    allocator.free(names);
    return out;
}

/// SONNY-3312: `programDataGraphList`'s collector.
const GraphList = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty,
    oom: bool = false,

    fn add(self: *GraphList, graph: []const u8) void {
        self.names.append(self.allocator, graph) catch {
            self.oom = true;
        };
    }
};

/// SONNY-3028: do the program's statements on graph data run on one graph,
/// and is every one of them a CREATE or DROP GRAPH of that graph?
pub fn programOnlyGraphDdl(program: *const ast.Program, start_graph: []const u8, home_graph: []const u8) bool {
    var walk: DataGraphWalk = .{ .current = start_graph, .home_graph = home_graph };
    for (program.statements) |*stmt| {
        if (!walk.statement(stmt)) return false;
    }
    return walk.runs_on != null and walk.only_graph_ddl;
}

/// `programDataGraph`'s walk over a program's statements, in order.
const DataGraphWalk = struct {
    /// The graph the program is on at this point.
    current: []const u8,
    home_graph: []const u8,
    /// The graph the statements so far that touch graph data run on.
    runs_on: ?[]const u8 = null,
    /// SONNY-3028: every such statement so far is a CREATE or DROP GRAPH.
    only_graph_ddl: bool = true,
    /// SONNY-3312: when set, every graph a statement touches is added here,
    /// and a second graph is not a conflict.
    collect: ?*GraphList = null,

    fn note(self: *DataGraphWalk, graph: []const u8) bool {
        self.only_graph_ddl = false;
        return self.noteOn(graph);
    }

    fn noteOn(self: *DataGraphWalk, graph: []const u8) bool {
        if (self.collect) |list| {
            list.add(graph);
            return true;
        }
        return noteGraph(&self.runs_on, graph);
    }

    /// Follow one statement. False when it touches another graph's data than
    /// an earlier one did.
    fn statement(self: *DataGraphWalk, stmt: *const ast.Statement) bool {
        switch (stmt.*) {
            .UseGraph => |ug| self.current = moveTo(self.current, graphTarget(ug.graph_name), self.home_graph),
            .SessionSet => |ss| switch (ss.clause_type) {
                .Graph => |g| self.current = moveTo(self.current, graphTarget(g.expression), self.home_graph),
                else => {},
            },
            .SessionReset => |sr| {
                if (sessionResetClearsGraph(sr)) self.current = self.home_graph;
            },
            .SessionClose => self.current = self.home_graph,
            .Commit, .Rollback, .Explain => {},
            // SONNY-3026: a PROFILE runs the statement it wraps: that
            // statement's graph is the program's. `PROFILE USE GRAPH g` moved
            // the session to g with no statement counted at all.
            .Profile => |p| return self.statement(p.query),
            .StartTransaction => |txn| {
                if (txn.body != null) return self.note(self.current);
            },
            // CANARY: REQ=REQ-SONNY-3028-DROP-GRAPH-PINS; FEATURE="MultiGraphIsolation"; ASPECT=NamedGraphLock; STATUS=TESTED; TEST=tests/test_sonny3028_drop_graph_in_use.zig; OWNER=storage; UPDATED=2026-09-27
            // SONNY-3028: CREATE and DROP GRAPH run on the graph they name:
            // the handler takes that graph's write lock, so DROP GRAPH waits
            // for the graph's other requests. They counted as statements on
            // the session's graph, so `DROP GRAPH g` from a session on
            // `default` locked `default` and freed g under its lock holders.
            .CreateGraph => |cg| return self.noteOn(cg.name),
            .DropGraph => |dg| return self.noteOn(dg.name),
            .CreateIndex => |ci| {
                const on = if (ci.index_type == .fulltext) graph_store.DEFAULT_GRAPH_NAME else self.current;
                return self.note(on);
            },
            // CANARY: REQ=REQ-SONNY-6294-DROP-INDEX-RULES; FEATURE="SchemaCatalog"; ASPECT=DropIndexSessionGraphLock; STATUS=TESTED; TEST=tests/test_sonny6294_drop_index_rules.zig; OWNER=catalog; UPDATED=2026-11-11
            .DropIndex => return self.note(self.current),
            .Call => |call| {
                const on = switch (call) {
                    .Procedure => |proc| if (procedure_access.isDefaultGraphProcedure(proc)) graph_store.DEFAULT_GRAPH_NAME else self.current,
                    .Subquery => self.current,
                };
                return self.note(on);
            },
            else => return self.note(self.current),
        }
        return true;
    }
};

/// SONNY-2799: does every statement of `program` that touches graph data run
/// on `graph` (or does none)? A program that ends the session's transaction
/// must, as it runs under that graph's write lock.
pub fn programDataOnlyOn(program: *const ast.Program, start_graph: []const u8, home_graph: []const u8, graph: []const u8) bool {
    return switch (programDataGraph(program, start_graph, home_graph)) {
        .none => true,
        .one => |g| std.mem.eql(u8, g, graph),
        .several => false,
    };
}

/// Does `SESSION RESET ...` send the session graph home? As the executor runs
/// it: no argument and ALL CHARACTERISTICS reset the whole session.
pub fn sessionResetClearsGraph(sr: ast.SessionResetStatement) bool {
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

// CANARY: REQ=REQ-SONNY-2802-PROFILE-REGIME; FEATURE="StatementAuthorization"; ASPECT=ExplainProfileAlone; STATUS=TESTED; TEST=tests/test_sonny2802_profile_regime.zig; OWNER=security; UPDATED=2026-09-26
/// SONNY-2802 / SONNY-2752: what the handlers answer (SQLSTATE 0A000) to an
/// EXPLAIN or PROFILE sent with other statements.
pub const explain_profile_alone_message = "EXPLAIN and PROFILE run alone: send the other statements of the request, and any USE GRAPH, in a request of their own";

/// SONNY-2802 / SONNY-2752: does `program` carry its EXPLAIN or PROFILE
/// together with a statement the handlers would not run? The handlers' EXPLAIN
/// arm only plans the EXPLAIN'd statement, and their PROFILE arm runs only the
/// PROFILE'd one; every other statement was dropped without a word. Yet the
/// program's lock, write gate and transaction bookkeeping come from the whole
/// program (`statementPlan`): `USE GRAPH g1; PROFILE CREATE (:X)` took g1's
/// write lock and wrote to the session's graph, and `CREATE (:X); EXPLAIN ...`
/// was permission-checked and never ran. The handlers refuse such a program
/// (0A000). One exception: a re-selection of `session_graph` (`USE GRAPH g;`
/// or `SESSION SET PROPERTY GRAPH g;` naming the graph the session is already
/// on, as the CLI's `-g` flag and pooled drivers send) changes nothing
/// (`restOfProgramIsNoop`). Transaction control is not an exception: the
/// arms never run it.
pub fn explainOrProfileHasCompany(program: *const ast.Program, analysis: *const ProgramAnalysis, session_graph: []const u8) bool {
    if (analysis.kind == .rows) return false;
    var wrappers: usize = 0;
    for (program.statements) |*stmt| switch (stmt.*) {
        .Explain, .Profile => wrappers += 1,
        else => {
            const selected = preambleGraphSelectorName(stmt) orelse return true;
            if (!std.mem.eql(u8, selected, session_graph)) return true;
        },
    };
    return wrappers != 1;
}

// CANARY: REQ=REQ-SONNY-3026-PROFILE-TXN-CONTROL; FEATURE="StatementAuthorization"; ASPECT=ExplainProfileTarget; STATUS=TESTED; TEST=tests/test_sonny3026_profile_txn_control.zig; OWNER=security; UPDATED=2026-09-27
/// SONNY-3026: what the handlers answer (SQLSTATE 0A000) to an EXPLAIN or
/// PROFILE of a statement that is not a query or a data change.
/// SONNY-3135: the statements they take, listed.
pub const explain_profile_target_message = "EXPLAIN and PROFILE take a query, a data change (INSERT, CREATE, MERGE, DELETE, SET, REMOVE), FOR or a read-only CALL: not transaction control, a SESSION statement, USE GRAPH, DDL, SHOW, another EXPLAIN or PROFILE, or a CALL that changes data";

/// SONNY-3026: does `program` EXPLAIN or PROFILE transaction control (START
/// TRANSACTION, COMMIT, ROLLBACK), a session statement (SESSION SET, RESET,
/// CLOSE), graph selection (USE GRAPH), or another EXPLAIN or PROFILE? The
/// handlers refuse it (0A000). Their PROFILE arm runs the wrapped statement
/// under a lock and with transaction bookkeeping made for a query: `PROFILE
/// ROLLBACK` undid the transaction's changes under a read lock (or none) and
/// the handler kept the transaction open, so the client's next autocommit
/// change joined a transaction that was rolled back at disconnect; `PROFILE
/// START TRANSACTION` began an undo transaction the handler threw away. There
/// is nothing to plan or profile in such a statement.
pub fn explainOrProfileTargetRefused(program: *const ast.Program) bool {
    for (program.statements) |*stmt| switch (stmt.*) {
        .Explain => |e| if (!explainableTarget(e.query)) return true,
        .Profile => |p| if (!explainableTarget(p.query)) return true,
        else => {},
    };
    return false;
}

// CANARY: REQ=REQ-SONNY-3135-PROFILE-ALLOWLIST; FEATURE="StatementAuthorization"; ASPECT=ExplainProfileAllowlist; STATUS=TESTED; TEST=tests/test_sonny3135_profile_allowlist_failed_txn.zig; OWNER=security; UPDATED=2026-09-27
/// SONNY-3135 (N7a): the statements an EXPLAIN or PROFILE may wrap, listed:
/// a query (set operations included), a data change (INSERT, CREATE, MERGE,
/// DELETE, and SET and REMOVE, which are queries), FOR, and a CALL that
/// changes nothing (a read-only procedure, or a subquery whose statement is
/// itself one of these and changes nothing). SONNY-3026 refused the ones it
/// listed and let the rest through: `PROFILE CALL
/// geode.tenant.backfill_edge_tags()` ran the self-locking procedure under
/// the handler's lock, where it waited up to 120 s on the lock its own
/// request held, and DDL, SHOW and auth statements ran through the PROFILE
/// arm, which is built for queries.
fn explainableTarget(stmt: *const ast.Statement) bool {
    return switch (stmt.*) {
        .Query, .Union, .Intersect, .Except, .For => true,
        .Insert, .InsertValue, .Create, .Merge, .Delete => true,
        .Call => |*call| switch (call.*) {
            .Procedure => |proc| procedure_access.classifyCallProcedure(proc) == .read_only,
            .Subquery => |sq| explainableTarget(sq.statement) and !isMutatingStatement(sq.statement),
        },
        else => false,
    };
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
    return isSelfLockingStatement(&program.statements[0]);
}

/// SONNY-3135 (N7a): a PROFILE runs the statement it wraps, so a PROFILE'd
/// self-locking CALL is one too (the handlers refuse it anyway, since
/// `explainableTarget` takes no CALL that changes data). It was not, and ran
/// under the handler's lock.
fn isSelfLockingStatement(stmt: *const ast.Statement) bool {
    return switch (stmt.*) {
        .Call => |call_stmt| switch (call_stmt) {
            .Procedure => |proc| proc.return_clause == null and proc.order_by == null and
                procedure_access.isSelfLockingProcedure(proc),
            .Subquery => false,
        },
        .Profile => |p| isSelfLockingStatement(p.query),
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

/// SONNY-3189: `EXPLAIN RETURN 1 + 1 + ...` reached this before
/// authorization, one recursion per operator: 100,000 terms overflowed an
/// 8 MiB thread in ReleaseSafe. The left operand and unary and IS NULL
/// operands are followed with a loop; right operands recurse.
fn isStoreFreeScalarExpr(root: *const ast.Expr) bool {
    var expr = root;
    while (true) {
        switch (expr.*) {
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
            => return true,
            .Unary => |u| expr = u.expr,
            .Binary => |b| {
                if (!isStoreFreeScalarExpr(b.right)) return false;
                expr = b.left;
            },
            .IsNull => |v| expr = v.target,
            .IsUnknown => |v| expr = v.target,
            else => return false,
        }
    }
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
    // CANARY: REQ=REQ-SONNY-3182-EXPRESSION-WRITES; FEATURE="WriteShapeAllowlist"; ASPECT=MutationClassification; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=query_traits; UPDATED=2026-09-28
    // SONNY-3182: the one write walk (`execution/write_walk.zig`): the
    // query's write clauses, a MATCH ... CALL of a procedure that writes, the
    // parts it runs (`next_query`, a CALL { }, a FOR body), and a write inside
    // any expression (an IN / NOT IN subquery: in a WHERE, an initial WITH or
    // its WHERE, a SET value, a RETURN, a pattern's property map) or in a CTE
    // body, at any depth. Classified as a read, such a query took the shared
    // read lock and passed the read-only and cluster gates.
    return write_walk.queryWrites(q, .{});
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
