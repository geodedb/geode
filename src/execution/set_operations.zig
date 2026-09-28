const std = @import("std");
const ast = @import("../gql/ast.zig");
const eval = @import("../eval.zig");
const value_types = @import("../value_types.zig");
const graph_store = @import("../graph_store.zig");

// Import from parent execution module
const execution = @import("../execution.zig");
const write_shape = @import("write_shape.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const valuesEqual = execution.valuesEqual;
const executeQueryNoLimitWithContext = execution.executeQueryNoLimitWithContext;
const executeQueryWithBindings = execution.executeQueryWithBindings;
const sortRows = execution.sortRows;

// Local type aliases
const Value = value_types.Value;
const Env = value_types.Env;

// GAP-0535: value ownership helpers (deep duplicate / free)
const value_utilities = @import("value_utilities.zig");

/// GAP-0535: copy a value out of `part_result` into the combined result.
/// When either side owns its value memory a deep duplicate is required:
///  - part owns: its deinit frees the original — a shallow copy would dangle;
///  - combined owns: its deinit frees the copy — a shallow borrow would be
///    an invalid free.
/// When neither owns, the legacy shallow copy is preserved (values are
/// borrowed from stores/AST and freed by their real owners).
///
/// Review follow-up: callers MUST normalize ownership first via
/// `ensureCombinedOwnership`, so `part_owns` implies `combined_owns` — the
/// deep duplicate is then always owned (and eventually freed) by the
/// combined result. Without that, a part-owned value copied into a
/// non-owning combined result would leak its duplicate (nothing would ever
/// free it).
fn copyPartValue(
    allocator: std.mem.Allocator,
    combined_owns: bool,
    part_owns: bool,
    val: Value,
) !Value {
    std.debug.assert(combined_owns or !part_owns);
    if (combined_owns or part_owns) {
        return value_utilities.duplicateValue(allocator, val);
    }
    return val;
}

/// GAP-0535 review follow-up: make the combined result own its value memory
/// when any part owns ("combined owns = any-part-owns"). Upgrading a
/// borrowed accumulator deep-duplicates its row values (and flag strings —
/// `ExecutionResult.deinit` frees those too when owned) in place so the
/// combined deinit's frees are uniformly valid.
///
/// On a mid-upgrade OOM the already-duplicated values leak (the flag is
/// still false, so deinit won't free them) — leaking on the OOM path is
/// preferred over an invalid free of borrowed AST/store memory.
fn ensureCombinedOwnership(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    part_owns: bool,
) !void {
    if (!part_owns or result.owns_value_memory) return;
    for (result.rows) |row| {
        for (row) |*val| {
            val.* = try value_utilities.duplicateValue(allocator, val.*);
        }
    }
    for (result.flags.items) |*flag| {
        flag.* = try allocator.dupe(u8, flag.*);
    }
    result.owns_value_memory = true;
}

/// Zero-length placeholder row used to pre-fill freshly grown rows arrays so
/// an OOM unwind through `ExecutionResult.deinit` never walks undefined row
/// slots (GAP-0535 review follow-up). `Allocator.free` on a zero-length
/// slice is a no-op, so deinit handles these safely.
const empty_row: []Value = @constCast(&[_]Value{});

/// GAP-0535: free the values of a row being dropped from `result` (dedup /
/// intersect / except / pagination) when the result owns its value memory.
fn freeDroppedRowValues(allocator: std.mem.Allocator, result: *const ExecutionResult, row: []Value) void {
    if (result.owns_value_memory) {
        for (row) |val| {
            value_utilities.freeValue(allocator, val);
        }
    }
}

/// GAP-0814 regression probe: counts successful entries into the parallel
/// UNION fork-join fast path. Tests read this before/after a UNION query
/// to verify the parallel arm-spawn decision fired, replacing prior wall-
/// clock budget assertions that flaked on contended hosts. Monotonic.
pub var parallel_union_invocations: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// SONNY-1330 regression probe: counts UNIONs that STARTED on the parallel
/// fork-join path and were thrown away because an arm needed to hydrate a
/// non-resident node/edge/adjacency (which would have mutated the shared
/// bounded caches under its sibling arms' live pointers). Every increment is
/// one UNION that produced its rows on the SERIAL path instead. Monotonic.
pub var parallel_union_serial_fallbacks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// SONNY-1330: may this arm's query be executed, thrown away, and executed
/// AGAIN (serially) without the client observing it twice?
///
/// The parallel path's safety valve is "discard every arm result and re-run the
/// whole UNION serially". That is only sound for arms with NO side effects: a
/// CREATE / MERGE / SET / REMOVE / DELETE arm that already ran would be applied
/// a SECOND time by the serial retry. `unionArmsAreParallelEligible` used to
/// reject writes only for `union_query.first` (and only CREATE/MERGE, and only
/// because of `variable_bindings`), so a `... UNION ALL CREATE (…) RETURN …`
/// TAIL was eligible — latent before this ticket, load-bearing now.
///
/// `call_clause` / `initial_call_subquery` are rejected wholesale: a procedure
/// body is opaque here and `CALL geode.*` includes mutating procedures.
/// Conservative by design — the cost of a false "not read-only" is one serial
/// UNION, the cost of a false "read-only" is a duplicated write.
///
/// SONNY-1330 review follow-up (1330b): the walk MUST descend into `cte_list`.
/// A CTE body (`CommonTableExpression.CTEBody.simple`, and both halves of
/// `.recursive`) is a FULL `*Query` — parsed by `parser.parseQueryForCTE`,
/// which delegates straight to `parseQuery`, and run by `executeCTE` — so
/// `WITH w AS (MATCH (n:T) SET n.c = n.c + 1 RETURN n) MATCH … RETURN …
/// UNION ALL …` is a writing arm. It was not merely eligible but
/// PREFERENTIALLY parallel: `predictArmRowCount` bails to `null` the moment it
/// sees `cte_list`, and `null` means "unknown → expensive → keep parallel".
/// A decline therefore re-ran the arm and applied the SET a second time.
///
/// SONNY-1330 review follow-up (1330c): clause fields are NOT the only query
/// carriers. `ast.Expr.InSubquery` / `.NotInSubquery` each hold a `*Query`
/// parsed by the full `parseQuery` (`parser.zig`, the `IN (` branch), executed
/// through `eval.evalExpr` -> `executeQueryWithEnv` ->
/// `executeQueryWithContext` — so it can carry `set_clauses`, `create`,
/// `merge`, `delete`, `remove`, `call`, `cte_list` and `next_query` of its own.
/// `MATCH (n:T) WHERE n.k IN (MATCH (m:T) SET m.c = m.c + 1 RETURN m.k)
/// RETURN n.k UNION ALL …` was the same defect class as the `cte_list` one,
/// and equally parallel-PREFERRED (`predictArmRowCount` bails on
/// `where_clause`). Every expression-bearing field of a query is therefore now
/// walked by `exprIsReadOnly`, which switches EXHAUSTIVELY over `ast.Expr` so
/// that a future variant is a compile error rather than a silent gap.
pub fn queryIsReadOnly(q: ast.Query) bool {
    if (q.create_pattern != null) return false;
    if (q.merge_statement != null) return false;
    if (q.set_clauses.len != 0) return false;
    if (q.remove_clauses.len != 0) return false;
    if (q.delete_items.len != 0) return false;
    if (q.call_clause != null) return false;
    if (q.initial_call_subquery != null) return false;
    if (q.for_statement != null) return false;

    // Expression carriers. Any of these can host an `IN (…)` / `NOT IN (…)`
    // subquery, which is a full query in its own right (see the 1330c note
    // above). Patterns are walked too: a property map inside `MATCH (n {p:
    // <expr>})` is `[]ast.Property`, whose `value` is a `*Expr`.
    if (!patternIsReadOnly(q.match)) return false;
    if (q.where_clause) |e| {
        if (!exprIsReadOnly(e)) return false;
    }
    if (q.filter_clause) |e| {
        if (!exprIsReadOnly(e)) return false;
    }
    if (q.having) |e| {
        if (!exprIsReadOnly(e)) return false;
    }
    if (q.unwind_clause) |u| {
        if (!exprIsReadOnly(u.list_expr)) return false;
    }
    for (q.let_bindings) |b| {
        if (!exprIsReadOnly(b.value)) return false;
    }
    for (q.inline_let_bindings) |b| {
        if (!exprIsReadOnly(b.value)) return false;
    }
    if (q.group_by) |g| {
        for (g.keys) |k| {
            if (!exprIsReadOnly(k)) return false;
        }
    }
    if (q.order_by) |ob| {
        if (!orderByIsReadOnly(ob)) return false;
    }
    for (q.ret.items) |item| {
        if (!exprIsReadOnly(item.expr)) return false;
    }
    if (q.with_clause) |w| {
        for (w.items) |item| {
            if (!exprIsReadOnly(item.expr)) return false;
        }
        if (w.order_by) |ob| {
            if (!orderByIsReadOnly(ob.*)) return false;
        }
    }

    // GAP-0082 CTEs: every body is a full query and runs before the main one.
    // Recursing (rather than spot-checking clauses) also covers a CTE body's
    // own `next_query` chain, `initial_call_subquery`, and nested CTEs.
    if (q.cte_list) |cte_list| {
        for (cte_list.ctes) |cte| switch (cte.body) {
            .simple => |body| {
                if (!queryIsReadOnly(body.*)) return false;
            },
            .recursive => |rec| {
                if (!queryIsReadOnly(rec.anchor.*)) return false;
                if (!queryIsReadOnly(rec.recursive_term.*)) return false;
            },
        };
    }
    // Query chaining (`... WITH ... MATCH/CREATE ...`) hangs the continuation
    // off `next_query`; walk it, or a chained CREATE slips through.
    if (q.next_query) |nq| {
        if (!queryIsReadOnly(nq.*)) return false;
    }
    return true;
}

// CANARY: REQ=REQ-SONNY-3182-EXPRESSION-WRITES; FEATURE="WriteShapeAllowlist"; ASPECT=ExpressionWalk; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist.zig; OWNER=engine; UPDATED=2026-09-27
/// SONNY-3182: whether every expression `q` itself carries is free of a
/// write (an IN / NOT IN subquery that writes), and every CTE body it defines
/// is read-only. Its clauses are not looked at, nor the parts it holds
/// (`next_query`, a FOR body, a CALL { }): the write-shape validator and
/// `query_traits.isQueryMutating` walk those. `MATCH (n) WHERE n.i IN (MATCH
/// (q) SET q.c = q.c + 1 RETURN q.i) RETURN count(*)` ran the SET once per
/// outer row, past the validator, under the read lock.
pub fn queryExpressionsAreReadOnly(q: ast.Query) bool {
    if (!patternIsReadOnly(q.match)) return false;
    if (q.create_pattern) |cp| {
        if (!patternIsReadOnly(cp)) return false;
    }
    const singles = [_]?ast.Expr{ q.where_clause, q.filter_clause, q.having, q.initial_where, q.pre_with_where, q.with_where };
    for (singles) |maybe| {
        if (maybe) |e| {
            if (!exprIsReadOnly(e)) return false;
        }
    }
    if (q.unwind_clause) |u| {
        if (!exprIsReadOnly(u.list_expr)) return false;
    }
    for (q.let_bindings) |b| {
        if (!exprIsReadOnly(b.value)) return false;
    }
    for (q.inline_let_bindings) |b| {
        if (!exprIsReadOnly(b.value)) return false;
    }
    if (q.group_by) |g| {
        for (g.keys) |k| {
            if (!exprIsReadOnly(k)) return false;
        }
    }
    if (q.order_by) |ob| {
        if (!orderByIsReadOnly(ob)) return false;
    }
    for (q.ret.items) |item| {
        if (!exprIsReadOnly(item.expr)) return false;
    }
    for ([_]?ast.WithClause{ q.with_clause, q.initial_with }) |maybe| {
        const w = maybe orelse continue;
        for (w.items) |item| {
            if (!exprIsReadOnly(item.expr)) return false;
        }
        if (w.order_by) |ob| {
            if (!orderByIsReadOnly(ob.*)) return false;
        }
    }
    for (q.set_clauses) |sc| {
        if (!setClauseIsReadOnly(sc)) return false;
    }
    if (q.merge_statement) |m| {
        if (!mergeExpressionsReadOnly(m.*)) return false;
    }
    if (q.call_clause) |cc| {
        if (!exprIsReadOnly(cc.procedure)) return false;
        if (cc.yield_items) |items| {
            for (items) |item| {
                if (!exprIsReadOnly(item.expr)) return false;
            }
        }
    }
    if (q.cte_list) |cte_list| {
        for (cte_list.ctes) |cte| switch (cte.body) {
            .simple => |body| {
                if (!queryIsReadOnly(body.*)) return false;
            },
            .recursive => |rec| {
                if (!queryIsReadOnly(rec.anchor.*)) return false;
                if (!queryIsReadOnly(rec.recursive_term.*)) return false;
            },
        };
    }
    return true;
}

/// SONNY-3182: a MERGE's property maps, SET values and RETURN.
pub fn mergeExpressionsReadOnly(m: ast.MergeStatement) bool {
    if (!patternIsReadOnly(m.pattern)) return false;
    for ([_][]const ast.SetClause{ m.on_create, m.on_match }) |actions| {
        for (actions) |sc| {
            if (!setClauseIsReadOnly(sc)) return false;
        }
    }
    if (m.return_clause) |r| {
        for (r.items) |item| {
            if (!exprIsReadOnly(item.expr)) return false;
        }
    }
    return true;
}

/// SONNY-3182: a pattern's property maps.
pub fn patternExpressionsReadOnly(p: ast.GraphPattern) bool {
    return patternIsReadOnly(p);
}

fn setClauseIsReadOnly(sc: ast.SetClause) bool {
    return switch (sc) {
        .Property => |p| exprIsReadOnly(p.value),
        .AllProperties => |a| exprIsReadOnly(a.properties),
        .Labels => true,
    };
}

fn orderByIsReadOnly(ob: ast.OrderBy) bool {
    for (ob.keys) |k| {
        if (!exprIsReadOnly(k.expr)) return false;
    }
    return true;
}

/// SONNY-1330 (1330c): property maps inside a pattern are expressions, so a
/// `*Query` can hide there too (`MATCH (n:T {p: 1 IN (MATCH … SET …)})`).
/// Walks node AND relationship property maps of every chain.
fn patternIsReadOnly(p: ast.GraphPattern) bool {
    for (p.chains) |chain| {
        if (chain.head) |head| {
            if (!nodePatternIsReadOnly(head)) return false;
        }
        for (chain.hops) |hop| {
            if (!nodePatternIsReadOnly(hop.left)) return false;
            if (!nodePatternIsReadOnly(hop.right)) return false;
            if (hop.rel.props) |props| {
                if (!propsAreReadOnly(props)) return false;
            }
        }
    }
    return true;
}

fn nodePatternIsReadOnly(n: ast.NodePattern) bool {
    if (n.props) |props| return propsAreReadOnly(props);
    return true;
}

fn propsAreReadOnly(props: []ast.Property) bool {
    for (props) |prop| {
        if (!exprIsReadOnly(prop.value.*)) return false;
    }
    return true;
}

fn exprListIsReadOnly(items: []*ast.Expr) bool {
    for (items) |it| {
        if (!exprIsReadOnly(it.*)) return false;
    }
    return true;
}

fn setPredIsReadOnly(value: *ast.Expr, set: []*ast.Expr) bool {
    return exprIsReadOnly(value.*) and exprListIsReadOnly(set);
}

fn patternWhereIsReadOnly(pattern: *ast.GraphPattern, where: ?*ast.Expr) bool {
    if (!patternIsReadOnly(pattern.*)) return false;
    if (where) |w| {
        if (!exprIsReadOnly(w.*)) return false;
    }
    return true;
}

/// SONNY-1330 (1330c): is this expression free of embedded MUTATING queries?
///
/// Only two `ast.Expr` variants carry a `*Query` — `.InSubquery` and
/// `.NotInSubquery`, both produced by the `IN (` branch of
/// `parser.parsePrimary`'s comparison tail, which calls the full `parseQuery`.
/// Everything else either has no sub-expression (literals, `Ident`, `Param`,
/// `PropertyAccess`, `HasLabel`) or must be recursed into so a subquery buried
/// under a `CASE`, a list, a map, a call argument or a comprehension cannot
/// slip past.
///
/// `Exists` / `PatternCount` / `PatternComp` / `ShortestPath` carry a
/// `*GraphPattern`, NOT a `*Query` — an `EXISTS { … }` or `COUNT { … }` body
/// is a pattern plus an optional WHERE and therefore cannot host a write
/// clause of its own. Their patterns and WHERE expressions are still walked,
/// because a property map inside the pattern is an ordinary expression that
/// CAN host an `IN (subquery)`.
///
/// The switch is EXHAUSTIVE on purpose: no `else` branch, so adding a variant
/// to `ast.Expr` fails to compile here instead of silently widening the gate.
pub fn exprIsReadOnly(e: ast.Expr) bool {
    return switch (e) {
        // --- leaves: no sub-expression, no query ---
        .Ident,
        .String,
        .Int,
        .Decimal,
        .Bool,
        .Null,
        .Date,
        .DateTime,
        .Time,
        .LocalDateTime,
        .SmallIntLit,
        .BigIntLit,
        .RealLit,
        .DoubleLit,
        .CharLit,
        .VarcharLit,
        .TextLit,
        .ByteaLit,
        .JsonLit,
        .JsonbLit,
        .XmlLit,
        .UrlLit,
        .DomainLit,
        .UuidLit,
        .EnumLit,
        .BitLit,
        .VarBitLit,
        .PropertyAccess,
        .Param,
        .HasLabel,
        => true,

        // --- THE carriers: a full `*Query`, executed via executeQueryWithEnv ---
        .InSubquery => |s| exprIsReadOnly(s.value.*) and queryIsReadOnly(s.subquery.*),
        .NotInSubquery => |s| exprIsReadOnly(s.value.*) and queryIsReadOnly(s.subquery.*),

        // --- containers ---
        .List, .ArrayLit => |items| exprListIsReadOnly(items),
        .Map => |props| propsAreReadOnly(props),

        .Member => |m| exprIsReadOnly(m.target.*),
        .Index => |i| exprIsReadOnly(i.target.*) and exprIsReadOnly(i.index.*),
        .Slice => |s| blk: {
            if (!exprIsReadOnly(s.target.*)) break :blk false;
            if (s.start) |st| {
                if (!exprIsReadOnly(st.*)) break :blk false;
            }
            if (s.end) |en| {
                if (!exprIsReadOnly(en.*)) break :blk false;
            }
            break :blk true;
        },
        .Call => |c| blk: {
            if (!exprIsReadOnly(c.callee.*)) break :blk false;
            for (c.args) |a| {
                if (!exprIsReadOnly(a.*)) break :blk false;
            }
            break :blk true;
        },
        .Unary => |u| exprIsReadOnly(u.expr.*),
        .Binary => |b| exprIsReadOnly(b.left.*) and exprIsReadOnly(b.right.*),

        // NOTE: `.In` / `.NotIn` (and the pairs below) have STRUCTURALLY
        // identical but NOMINALLY distinct anonymous struct payloads, so Zig
        // refuses a shared capture group — each gets its own prong delegating
        // to one helper.
        .In => |s| setPredIsReadOnly(s.value, s.set),
        .NotIn => |s| setPredIsReadOnly(s.value, s.set),
        .InListExpr => |s| exprIsReadOnly(s.value.*) and exprIsReadOnly(s.list_expr.*),
        .NotInListExpr => |s| exprIsReadOnly(s.value.*) and exprIsReadOnly(s.list_expr.*),

        .IsNull => |t| exprIsReadOnly(t.target.*),
        .IsUnknown => |t| exprIsReadOnly(t.target.*),
        .StartsWith => |s| exprIsReadOnly(s.value.*) and exprIsReadOnly(s.prefix.*),
        .EndsWith => |s| exprIsReadOnly(s.value.*) and exprIsReadOnly(s.suffix.*),
        .Contains => |s| exprIsReadOnly(s.value.*) and exprIsReadOnly(s.needle.*),

        .Case => |c| blk: {
            if (c.operand) |op| {
                if (!exprIsReadOnly(op.*)) break :blk false;
            }
            for (c.whens) |w| {
                if (!exprIsReadOnly(w.when.*)) break :blk false;
                if (!exprIsReadOnly(w.then_expr.*)) break :blk false;
            }
            if (c.else_expr) |el| {
                if (!exprIsReadOnly(el.*)) break :blk false;
            }
            break :blk true;
        },

        // --- pattern-bearing: `*GraphPattern`, never a `*Query` (see above) ---
        .PatternComp => |pc| patternWhereIsReadOnly(pc.pattern, pc.where) and exprIsReadOnly(pc.map.*),
        .Exists => |p| patternWhereIsReadOnly(p.pattern, p.where),
        .PatternCount => |p| patternWhereIsReadOnly(p.pattern, p.where),
        .ShortestPath => |sp| patternIsReadOnly(sp.pattern.*),

        .MapProjection => |mp| exprIsReadOnly(mp.source.*),
        .ListComprehension => |lc| blk: {
            if (!exprIsReadOnly(lc.source.*)) break :blk false;
            if (lc.filter) |f| {
                if (!exprIsReadOnly(f.*)) break :blk false;
            }
            if (lc.map) |m| {
                if (!exprIsReadOnly(m.*)) break :blk false;
            }
            break :blk true;
        },
    };
}

// CANARY: REQ=REQ-EXEC-REFACTOR-002; FEATURE="ExecutionRefactoring"; ASPECT=SET_OPERATIONS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-10-17
// Extracted set operation functions from execution.zig for better modularity (M1 Phase 2)

/// Compare two rows for equality
pub fn rowsEqual(a: []Value, b: []Value) bool {
    if (a.len != b.len) return false;

    for (a, b) |val_a, val_b| {
        if (!valuesEqual(val_a, val_b)) return false;
    }

    return true;
}

/// Execute INTERSECT query
pub fn executeIntersect(allocator: std.mem.Allocator, intersect_query: ast.BinarySet, context: ExecutionContext) !ExecutionResult {
    // Execute left and right queries
    var left_result = try executeQueryNoLimitWithContext(allocator, intersect_query.left, context);
    errdefer left_result.deinit(allocator);

    var right_result = try executeQueryNoLimitWithContext(allocator, intersect_query.right, context);
    defer right_result.deinit(allocator);

    // Validate column count match
    if (left_result.columns.len != right_result.columns.len) {
        return error.UnionColumnCountMismatch;
    }

    var new_rows = try std.ArrayList([]Value).initCapacity(allocator, left_result.rows.len);

    if (intersect_query.all) {
        // INTERSECT ALL - keep minimum occurrence count for each row.
        // GAP-0535 review follow-up: rows dropped here must NOT be freed
        // mid-loop — every iteration re-scans left_result.rows for
        // `count_in_left`, so a mid-loop free is a read-after-free (and
        // wrong counts once the allocator recycles the bytes). Mark dropped
        // rows and free them in one pass after all scans complete.
        const dropped = try allocator.alloc(bool, left_result.rows.len);
        defer allocator.free(dropped);
        @memset(dropped, false);

        for (left_result.rows, 0..) |row, row_idx| {
            var count_in_left: usize = 0;
            var count_in_right: usize = 0;

            for (left_result.rows) |r| {
                if (rowsEqual(row, r)) count_in_left += 1;
            }

            for (right_result.rows) |r| {
                if (rowsEqual(row, r)) count_in_right += 1;
            }

            const min_count = @min(count_in_left, count_in_right);
            var added_count: usize = 0;
            for (new_rows.items) |r| {
                if (rowsEqual(row, r)) added_count += 1;
            }

            if (added_count < min_count) {
                const new_row = try allocator.alloc(Value, row.len);
                for (row, 0..) |val, j| {
                    new_row[j] = val;
                }
                try new_rows.append(allocator, new_row);
            } else {
                dropped[row_idx] = true;
            }
        }

        // Post-loop pass: all occurrence scans are complete — now it is
        // safe to free the dropped rows' values when owned.
        for (left_result.rows, 0..) |row, row_idx| {
            if (dropped[row_idx]) freeDroppedRowValues(allocator, &left_result, row);
        }
    } else {
        // INTERSECT DISTINCT - keep only unique rows present in both
        for (left_result.rows) |row| {
            var found_in_right = false;
            for (right_result.rows) |right_row| {
                if (rowsEqual(row, right_row)) {
                    found_in_right = true;
                    break;
                }
            }

            if (found_in_right) {
                var already_added = false;
                for (new_rows.items) |existing_row| {
                    if (rowsEqual(row, existing_row)) {
                        already_added = true;
                        break;
                    }
                }

                if (!already_added) {
                    const new_row = try allocator.alloc(Value, row.len);
                    for (row, 0..) |val, j| {
                        new_row[j] = val;
                    }
                    try new_rows.append(allocator, new_row);
                } else {
                    // GAP-0535: dropped duplicate — free values when owned
                    freeDroppedRowValues(allocator, &left_result, row);
                }
            } else {
                // GAP-0535: row not in both sets — free values when owned
                freeDroppedRowValues(allocator, &left_result, row);
            }
        }
    }

    // Free old result rows
    for (left_result.rows) |row| {
        allocator.free(row);
    }
    allocator.free(left_result.rows);

    // Set new intersected rows
    left_result.rows = try new_rows.toOwnedSlice(allocator);
    return left_result;
}

/// Execute EXCEPT query
pub fn executeExcept(allocator: std.mem.Allocator, except_query: ast.BinarySet, context: ExecutionContext) !ExecutionResult {
    // Execute left and right queries
    var left_result = try executeQueryNoLimitWithContext(allocator, except_query.left, context);
    errdefer left_result.deinit(allocator);

    var right_result = try executeQueryNoLimitWithContext(allocator, except_query.right, context);
    defer right_result.deinit(allocator);

    // Validate column count match
    if (left_result.columns.len != right_result.columns.len) {
        return error.UnionColumnCountMismatch;
    }

    var new_rows = try std.ArrayList([]Value).initCapacity(allocator, left_result.rows.len);

    if (except_query.all) {
        // EXCEPT ALL - remove one occurrence for each match in right.
        // GAP-0535 review follow-up: rows dropped here must NOT be freed
        // mid-loop — every iteration re-scans left_result.rows for
        // `count_in_left`, so a mid-loop free is a read-after-free (and
        // wrong counts once the allocator recycles the bytes). Mark dropped
        // rows and free them in one pass after all scans complete.
        const dropped = try allocator.alloc(bool, left_result.rows.len);
        defer allocator.free(dropped);
        @memset(dropped, false);

        for (left_result.rows, 0..) |row, row_idx| {
            var count_in_right: usize = 0;
            for (right_result.rows) |right_row| {
                if (rowsEqual(row, right_row)) count_in_right += 1;
            }

            var count_in_new: usize = 0;
            for (new_rows.items) |new_row| {
                if (rowsEqual(row, new_row)) count_in_new += 1;
            }

            var count_in_left: usize = 0;
            for (left_result.rows) |r| {
                if (rowsEqual(row, r)) count_in_left += 1;
            }

            if (count_in_new < count_in_left - count_in_right) {
                const new_row = try allocator.alloc(Value, row.len);
                for (row, 0..) |val, j| {
                    new_row[j] = val;
                }
                try new_rows.append(allocator, new_row);
            } else {
                dropped[row_idx] = true;
            }
        }

        // Post-loop pass: all occurrence scans are complete — now it is
        // safe to free the dropped rows' values when owned.
        for (left_result.rows, 0..) |row, row_idx| {
            if (dropped[row_idx]) freeDroppedRowValues(allocator, &left_result, row);
        }
    } else {
        // EXCEPT DISTINCT - remove all occurrences of rows that appear in right
        for (left_result.rows) |row| {
            var found_in_right = false;
            for (right_result.rows) |right_row| {
                if (rowsEqual(row, right_row)) {
                    found_in_right = true;
                    break;
                }
            }

            if (!found_in_right) {
                var already_added = false;
                for (new_rows.items) |existing_row| {
                    if (rowsEqual(row, existing_row)) {
                        already_added = true;
                        break;
                    }
                }

                if (!already_added) {
                    const new_row = try allocator.alloc(Value, row.len);
                    for (row, 0..) |val, j| {
                        new_row[j] = val;
                    }
                    try new_rows.append(allocator, new_row);
                } else {
                    // GAP-0535: dropped duplicate — free values when owned
                    freeDroppedRowValues(allocator, &left_result, row);
                }
            } else {
                // GAP-0535: row appears in right side — free values when owned
                freeDroppedRowValues(allocator, &left_result, row);
            }
        }
    }

    // Free old result rows
    for (left_result.rows) |row| {
        allocator.free(row);
    }
    allocator.free(left_result.rows);

    // Set new excepted rows
    left_result.rows = try new_rows.toOwnedSlice(allocator);
    return left_result;
}

/// Execute UNION query with context
// CANARY: REQ=REQ-MULTI-GRAPH-UNION-002; FEATURE="MultiGraphIsolation"; ASPECT=UnionExecution; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-23
// Fixed: UNION queries now properly propagate graph context to sub-queries
pub fn executeUnionWithContext(allocator: std.mem.Allocator, union_query: ast.UnionQuery, context: ExecutionContext) !ExecutionResult {
    // GAP-0814 Task 5.1: if every tail is a pure UNION / UNION ALL and the
    // first arm did not leak variable_bindings (no CREATE-then-SELECT
    // chains), dispatch each arm onto its own thread and merge on return.
    // This halves wall-time for `A UNION B` when the two arms are
    // independent scans. Non-eligible unions (intersect/except mixed in,
    // or shared bindings from the first arm) fall through to the serial
    // path below.
    // CANARY: REQ=REQ-PERF-QPS-0814; FEATURE="ParallelUnionArms"; ASPECT=ForkJoin; STATUS=TESTED; TEST=tests/test_gap0814_union_parallelism.zig; OWNER=performance; UPDATED=2026-04-20
    if (unionArmsAreParallelEligible(union_query, context)) {
        if (try tryParallelUnion(allocator, union_query, context)) |parallel_result| {
            var result = parallel_result;
            errdefer result.deinit(allocator);
            try applyUnionPagination(allocator, &result, union_query, context);
            return result;
        }
    }

    // Execute first query with context (for graph isolation)
    var result = try executeQueryNoLimitWithContext(allocator, union_query.first, context);
    errdefer result.deinit(allocator);

    // Extract variable bindings from first query (if any) to pass to subsequent UNION parts
    // This allows SELECT in UNION to access variables from CREATE in first query
    // SONNY-3183 (I1): only when the write-shape validator's predicate says
    // the later parts run over them; it checked them as parts that run through
    // the query dispatcher otherwise, and one that writes had its write
    // dropped here.
    const shared_bindings = if (write_shape.unionTailsRunOverBindings(union_query.first)) result.variable_bindings else null;

    // Execute and append results from tail queries
    for (union_query.tails) |part| {
        // Determine the operation type
        const operation = part.operation;

        if (operation == .union_op) {
            if (part.all) {
                // UNION ALL - append all rows
                // Use shared bindings if available (for accessing CREATE variables in SELECT)
                var part_result = if (shared_bindings) |bindings|
                    try executeQueryWithBindings(allocator, part.query, bindings)
                else
                    try executeQueryNoLimitWithContext(allocator, part.query, context);
                defer part_result.deinit(allocator);

                // Validate column count match
                if (part_result.columns.len != result.columns.len) {
                    return error.UnionColumnCountMismatch;
                }

                // GAP-0535 review follow-up: combined owns = any-part-owns.
                try ensureCombinedOwnership(allocator, &result, part_result.owns_value_memory);

                // Append rows to result without ever exposing undefined row
                // slots: `copyPartValue` below is fallible, and an OOM unwind
                // runs `errdefer result.deinit`, which iterates result.rows.
                // Pre-fill the grown tail with empty rows and only install
                // each new row once it is fully built (GAP-0535 follow-up).
                const old_rows = result.rows;
                const old_len = old_rows.len;
                const combined = try allocator.alloc([]Value, old_len + part_result.rows.len);

                // Copy old rows (transfer ownership)
                for (old_rows, 0..) |row, i| {
                    combined[i] = row;
                }
                @memset(combined[old_len..], empty_row);
                result.rows = combined;

                // Free the old rows array (but not the rows themselves - they're transferred)
                allocator.free(old_rows);

                // Copy new rows (need to duplicate since part_result will be freed)
                for (part_result.rows, 0..) |row, i| {
                    // Need to duplicate the row data (GAP-0535: deep when owned)
                    const new_row = try allocator.alloc(Value, row.len);
                    var filled: usize = 0;
                    errdefer {
                        // Partially-built row: free what was duplicated and
                        // the row buffer itself — it was never installed, so
                        // result.deinit will not see it.
                        if (result.owns_value_memory) {
                            for (new_row[0..filled]) |val| {
                                value_utilities.freeValue(allocator, val);
                            }
                        }
                        allocator.free(new_row);
                    }
                    for (row, 0..) |val, j| {
                        new_row[j] = try copyPartValue(allocator, result.owns_value_memory, part_result.owns_value_memory, val);
                        filled = j + 1;
                    }
                    combined[old_len + i] = new_row;
                }
            } else {
                // UNION DISTINCT - deduplicate rows
                var part_result = if (shared_bindings) |bindings|
                    try executeQueryWithBindings(allocator, part.query, bindings)
                else
                    try executeQueryNoLimitWithContext(allocator, part.query, context);
                defer part_result.deinit(allocator);

                // Validate column count match
                if (part_result.columns.len != result.columns.len) {
                    return error.UnionColumnCountMismatch;
                }

                // GAP-0535 review follow-up: combined owns = any-part-owns.
                try ensureCombinedOwnership(allocator, &result, part_result.owns_value_memory);

                // Build a combined result with deduplication
                var new_rows = try std.ArrayList([]Value).initCapacity(allocator, result.rows.len + part_result.rows.len);

                // Add existing rows
                for (result.rows) |row| {
                    var is_duplicate = false;

                    // Check if this row already exists in new_rows
                    for (new_rows.items) |existing_row| {
                        if (rowsEqual(row, existing_row)) {
                            is_duplicate = true;
                            break;
                        }
                    }

                    if (!is_duplicate) {
                        // Duplicate the row since we're building a new array
                        const new_row = try allocator.alloc(Value, row.len);
                        for (row, 0..) |val, j| {
                            new_row[j] = val;
                        }
                        try new_rows.append(allocator, new_row);
                    } else {
                        // GAP-0535: dropped duplicate — free its values when owned
                        freeDroppedRowValues(allocator, &result, row);
                    }
                }

                // Add new rows from part_result that aren't duplicates
                for (part_result.rows) |row| {
                    var is_duplicate = false;

                    // Check if this row already exists
                    for (new_rows.items) |existing_row| {
                        if (rowsEqual(row, existing_row)) {
                            is_duplicate = true;
                            break;
                        }
                    }

                    if (!is_duplicate) {
                        // Duplicate the row since part_result will be freed
                        // (GAP-0535: deep when owned)
                        const new_row = try allocator.alloc(Value, row.len);
                        for (row, 0..) |val, j| {
                            new_row[j] = try copyPartValue(allocator, result.owns_value_memory, part_result.owns_value_memory, val);
                        }
                        try new_rows.append(allocator, new_row);
                    }
                }

                // Free old result rows
                for (result.rows) |row| {
                    allocator.free(row);
                }
                allocator.free(result.rows);

                // Set new deduplicated rows
                result.rows = try new_rows.toOwnedSlice(allocator);
            }
        } else if (operation == .intersect) {
            // INTERSECT - keep only rows that appear in both result sets
            var part_result = if (shared_bindings) |bindings|
                try executeQueryWithBindings(allocator, part.query, bindings)
            else
                try executeQueryNoLimitWithContext(allocator, part.query, context);
            defer part_result.deinit(allocator);

            // Validate column count match
            if (part_result.columns.len != result.columns.len) {
                return error.UnionColumnCountMismatch;
            }

            var new_rows = try std.ArrayList([]Value).initCapacity(allocator, result.rows.len);

            if (part.all) {
                // INTERSECT ALL - keep minimum occurrence count for each row.
                // GAP-0535 review follow-up: rows dropped here must NOT be
                // freed mid-loop — every iteration re-scans result.rows for
                // `count_in_result`, so a mid-loop free is a read-after-free
                // (and wrong counts once the allocator recycles the bytes).
                // Mark dropped rows and free them after all scans complete.
                const dropped = try allocator.alloc(bool, result.rows.len);
                defer allocator.free(dropped);
                @memset(dropped, false);

                for (result.rows, 0..) |row, row_idx| {
                    // Count occurrences in both result sets
                    var count_in_result: usize = 0;
                    var count_in_part: usize = 0;

                    for (result.rows) |r| {
                        if (rowsEqual(row, r)) count_in_result += 1;
                    }

                    for (part_result.rows) |r| {
                        if (rowsEqual(row, r)) count_in_part += 1;
                    }

                    // Add minimum count to result
                    const min_count = @min(count_in_result, count_in_part);
                    var added_count: usize = 0;
                    for (new_rows.items) |r| {
                        if (rowsEqual(row, r)) added_count += 1;
                    }

                    if (added_count < min_count) {
                        const new_row = try allocator.alloc(Value, row.len);
                        for (row, 0..) |val, j| {
                            new_row[j] = val;
                        }
                        try new_rows.append(allocator, new_row);
                    } else {
                        dropped[row_idx] = true;
                    }
                }

                // Post-loop pass: all occurrence scans are complete — now it
                // is safe to free the dropped rows' values when owned.
                for (result.rows, 0..) |row, row_idx| {
                    if (dropped[row_idx]) freeDroppedRowValues(allocator, &result, row);
                }
            } else {
                // INTERSECT DISTINCT - keep only unique rows present in both
                for (result.rows) |row| {
                    var found_in_part = false;
                    for (part_result.rows) |part_row| {
                        if (rowsEqual(row, part_row)) {
                            found_in_part = true;
                            break;
                        }
                    }

                    if (found_in_part) {
                        // Check if already added (for distinctness)
                        var already_added = false;
                        for (new_rows.items) |existing_row| {
                            if (rowsEqual(row, existing_row)) {
                                already_added = true;
                                break;
                            }
                        }

                        if (!already_added) {
                            const new_row = try allocator.alloc(Value, row.len);
                            for (row, 0..) |val, j| {
                                new_row[j] = val;
                            }
                            try new_rows.append(allocator, new_row);
                        } else {
                            // GAP-0535: dropped duplicate — free values when owned
                            freeDroppedRowValues(allocator, &result, row);
                        }
                    } else {
                        // GAP-0535: row not in both sets — free values when owned
                        freeDroppedRowValues(allocator, &result, row);
                    }
                }
            }

            // Free old result rows
            for (result.rows) |row| {
                allocator.free(row);
            }
            allocator.free(result.rows);

            // Set new intersected rows
            result.rows = try new_rows.toOwnedSlice(allocator);
        } else if (operation == .except) {
            // EXCEPT - keep rows from left that don't appear in right
            var part_result = if (shared_bindings) |bindings|
                try executeQueryWithBindings(allocator, part.query, bindings)
            else
                try executeQueryNoLimitWithContext(allocator, part.query, context);
            defer part_result.deinit(allocator);

            // Validate column count match
            if (part_result.columns.len != result.columns.len) {
                return error.UnionColumnCountMismatch;
            }

            var new_rows = try std.ArrayList([]Value).initCapacity(allocator, result.rows.len);

            if (part.all) {
                // EXCEPT ALL - remove one occurrence for each match in right.
                // GAP-0535 review follow-up: rows dropped here must NOT be
                // freed mid-loop — every iteration re-scans result.rows for
                // `count_in_result`, so a mid-loop free is a read-after-free
                // (and wrong counts once the allocator recycles the bytes —
                // deterministically reproduced by the PoisonAllocator test in
                // tests/test_gap0535_result_ownership.zig). Mark dropped rows
                // and free them after all scans complete.
                const dropped = try allocator.alloc(bool, result.rows.len);
                defer allocator.free(dropped);
                @memset(dropped, false);

                for (result.rows, 0..) |row, row_idx| {
                    var count_in_part: usize = 0;
                    for (part_result.rows) |part_row| {
                        if (rowsEqual(row, part_row)) count_in_part += 1;
                    }

                    var count_in_new: usize = 0;
                    for (new_rows.items) |new_row| {
                        if (rowsEqual(row, new_row)) count_in_new += 1;
                    }

                    // Add if we haven't reached the exclusion limit
                    var count_in_result: usize = 0;
                    for (result.rows) |r| {
                        if (rowsEqual(row, r)) count_in_result += 1;
                    }

                    if (count_in_new < count_in_result - count_in_part) {
                        const new_row = try allocator.alloc(Value, row.len);
                        for (row, 0..) |val, j| {
                            new_row[j] = val;
                        }
                        try new_rows.append(allocator, new_row);
                    } else {
                        dropped[row_idx] = true;
                    }
                }

                // Post-loop pass: all occurrence scans are complete — now it
                // is safe to free the dropped rows' values when owned.
                for (result.rows, 0..) |row, row_idx| {
                    if (dropped[row_idx]) freeDroppedRowValues(allocator, &result, row);
                }
            } else {
                // EXCEPT DISTINCT - remove all occurrences of rows that appear in right
                for (result.rows) |row| {
                    var found_in_part = false;
                    for (part_result.rows) |part_row| {
                        if (rowsEqual(row, part_row)) {
                            found_in_part = true;
                            break;
                        }
                    }

                    if (!found_in_part) {
                        // Check if already added (for distinctness)
                        var already_added = false;
                        for (new_rows.items) |existing_row| {
                            if (rowsEqual(row, existing_row)) {
                                already_added = true;
                                break;
                            }
                        }

                        if (!already_added) {
                            const new_row = try allocator.alloc(Value, row.len);
                            for (row, 0..) |val, j| {
                                new_row[j] = val;
                            }
                            try new_rows.append(allocator, new_row);
                        } else {
                            // GAP-0535: dropped duplicate — free values when owned
                            freeDroppedRowValues(allocator, &result, row);
                        }
                    } else {
                        // GAP-0535: excluded row — free its values when owned
                        freeDroppedRowValues(allocator, &result, row);
                    }
                }
            }

            // Free old result rows
            for (result.rows) |row| {
                allocator.free(row);
            }
            allocator.free(result.rows);

            // Set new excepted rows
            result.rows = try new_rows.toOwnedSlice(allocator);
        }
    }

    try applyUnionPagination(allocator, &result, union_query, context);
    return result;
}

/// Apply ORDER BY / OFFSET / LIMIT from a UNION query to the combined result.
/// Extracted from `executeUnionWithContext` so the parallel fork-join path
/// (GAP-0814 Task 5.1) can share the pagination logic.
fn applyUnionPagination(
    allocator: std.mem.Allocator,
    result: *ExecutionResult,
    union_query: ast.UnionQuery,
    context: ExecutionContext,
) !void {
    // Apply ORDER BY from the union query to the entire result
    if (union_query.order_by) |order| {
        try sortRows(allocator, result, order.*);
    }

    // Validate: OFFSET requires ORDER BY (US001) - only if strict validation enabled
    if (context.strict_offset_validation and union_query.offset != null and union_query.order_by == null) {
        return execution.ExecutionError.UnorderedPagination;
    }

    // Apply SKIP and LIMIT from the union query (applies to entire result)
    if (union_query.offset) |skip_count| {
        // Convert skip_count to usize for 32-bit platforms
        const skip_usize = if (skip_count > std.math.maxInt(usize))
            std.math.maxInt(usize)
        else
            @as(usize, @intCast(skip_count));
        if (skip_usize < result.rows.len) {
            const new_rows = try allocator.alloc([]Value, result.rows.len - skip_usize);
            // Free the skipped rows (GAP-0535: values too when owned)
            for (result.rows[0..skip_usize]) |row| {
                freeDroppedRowValues(allocator, result, row);
                allocator.free(row);
            }
            // Transfer ownership of remaining rows
            for (result.rows[skip_usize..], 0..) |row, i| {
                new_rows[i] = row;
            }
            allocator.free(result.rows);
            result.rows = new_rows;
        } else {
            // Free all rows since we're skipping everything
            for (result.rows) |row| {
                freeDroppedRowValues(allocator, result, row);
                allocator.free(row);
            }
            allocator.free(result.rows);
            result.rows = try allocator.alloc([]Value, 0);
        }
    }

    if (union_query.limit) |limit_count_u64| {
        // Convert u64 to usize for 32-bit platforms
        const limit_count = if (limit_count_u64 > std.math.maxInt(usize))
            std.math.maxInt(usize)
        else
            @as(usize, @intCast(limit_count_u64));
        // Check if LIMIT without ORDER BY - need to flag it and sort
        // But only if we don't have SKIP (which makes ordering deterministic in UNION context)
        // And only add once
        if (union_query.order_by == null and union_query.offset == null) {
            // Check if we haven't already added this flag
            var has_flag = false;
            for (result.flags.items) |flag| {
                if (std.mem.eql(u8, flag, "U:OrderTiebreak=LexJSON")) {
                    has_flag = true;
                    break;
                }
            }
            if (!has_flag) {
                // Duplicate flag if result owns memory, otherwise string literal is fine
                const flag = if (result.owns_value_memory) try allocator.dupe(u8, "U:OrderTiebreak=LexJSON") else "U:OrderTiebreak=LexJSON";
                try result.flags.append(allocator, flag);
            }

            // Sort rows lexicographically when using LexJSON tie-breaker
            if (result.rows.len > 1) {
                // Simple bubble sort for now (could optimize later)
                var i: usize = 0;
                while (i < result.rows.len - 1) : (i += 1) {
                    var j: usize = 0;
                    while (j < result.rows.len - i - 1) : (j += 1) {
                        // Compare first column values lexicographically
                        if (result.rows[j].len > 0 and result.rows[j + 1].len > 0) {
                            const val1 = result.rows[j][0];
                            const val2 = result.rows[j + 1][0];

                            // Compare integer values
                            if (val1 == .Int and val2 == .Int) {
                                if (val1.Int > val2.Int) {
                                    // Swap
                                    const temp = result.rows[j];
                                    result.rows[j] = result.rows[j + 1];
                                    result.rows[j + 1] = temp;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (limit_count < result.rows.len) {
            const new_rows = try allocator.alloc([]Value, limit_count);
            // Transfer ownership of kept rows
            for (result.rows[0..limit_count], 0..) |row, i| {
                new_rows[i] = row;
            }
            // Free the rows that are being cut off (GAP-0535: values too when owned)
            for (result.rows[limit_count..]) |row| {
                freeDroppedRowValues(allocator, result, row);
                allocator.free(row);
            }
            allocator.free(result.rows);
            result.rows = new_rows;
        }
    }
}

/// GAP-0814 Task 5.1: decide if a UNION chain's arms can safely run in parallel.
/// Only pure `UNION` / `UNION ALL` chains are eligible — if any tail is an
/// intersect or except operation, that tail's semantics depend on the
/// accumulated left-hand result so we must stay serial. A single-arm union
/// (tails.len == 0) has no parallelism to exploit.
///
/// GAP-0814-cost-model (2026-04-20): additionally gate on a rough arm-cost
/// heuristic — if EVERY arm's anchor label posting-list is below
/// `PARALLEL_UNION_MIN_POSTING_SIZE`, the thread-spawn overhead
/// (~10-15µs/arm) swamps any parallel savings, so stay serial. Arms whose
/// cost we can't cheaply predict (subquery, WHERE clause, relationship
/// hops, etc.) are treated as "expensive" and keep the parallel path — the
/// conservative default when cost is unknown.
///
/// CANARY: REQ=REQ-PERF-QPS-0814; FEATURE="ParallelUnionArms"; ASPECT=CostModelThreshold; STATUS=TESTED; TEST=tests/test_gap0814_union_parallelism.zig; OWNER=performance; UPDATED=2026-04-20
fn unionArmsAreParallelEligible(union_query: ast.UnionQuery, context: ExecutionContext) bool {
    if (union_query.tails.len == 0) return false;

    // SONNY-1330: never fan out from a thread that is ITSELF a parallel-UNION
    // arm. `beginReadOnlyHydration` is threadlocal, so freshly spawned inner
    // arms would start with hydration ENABLED and mutate the shared caches
    // right under the outer arms' live pointers — exactly what this ticket
    // closes. A nested UNION therefore runs serially inside its arm.
    if (graph_store.node_cache_mod.readOnlyHydrationActive()) return false;
    for (union_query.tails) |tail| {
        if (tail.operation != .union_op) return false;
    }

    // 2026-04-27: the first arm must NOT publish `variable_bindings`
    // for the parallel path to be safe.  If arm 0 is a CREATE / MERGE
    // (or any CREATE-then-RETURN-then-UNION chain), subsequent arms
    // expect to see arm-0's bindings via the shared-bindings branch in
    // the serial path below.  The parallel runner uses
    // `executeQueryNoLimitWithContext` which deliberately does NOT
    // forward bindings (each arm runs in its own thread/context), so
    // the tails would resolve free identifiers (`b`, `c`, …) to NULL
    // and silently produce wrong rows.  Repro:
    //   `geodetestlab-cli/specs/geode_regression_tests.yml`
    //   `order-by-node-property` —
    //   `CREATE (a:P {…}), (b:P {…}), (c:P {…}) RETURN a.name UNION ALL …`
    // expects rows for a/b/c but only the first arm's row had values.
    if (union_query.first.create_pattern != null) return false;
    if (union_query.first.merge_statement != null) return false;

    // SONNY-1330: EVERY arm must be side-effect free, not just arm 0. The
    // parallel path can now abandon its arms mid-flight and re-run the UNION
    // serially (read-only-hydration fallback below), and re-running a write arm
    // would apply it twice. See `queryIsReadOnly`.
    if (!queryIsReadOnly(union_query.first)) return false;
    for (union_query.tails) |tail| {
        if (!queryIsReadOnly(tail.query)) return false;
    }

    // Cost model: if EVERY arm has a predictably small anchor posting-list,
    // serial execution is cheaper than thread-spawn.
    const current_graph = if (context.session_state) |session| session.graph else null;
    const graph = current_graph orelse "default";

    var all_small = true;
    if (predictArmRowCount(union_query.first, graph)) |n| {
        if (n >= PARALLEL_UNION_MIN_POSTING_SIZE) all_small = false;
    } else {
        all_small = false; // unknown cost → treat as expensive (parallel)
    }

    if (all_small) {
        for (union_query.tails) |tail| {
            if (predictArmRowCount(tail.query, graph)) |n| {
                if (n >= PARALLEL_UNION_MIN_POSTING_SIZE) {
                    all_small = false;
                    break;
                }
            } else {
                all_small = false;
                break;
            }
        }
    }

    if (all_small) return false; // every arm below threshold → serial

    return true;
}

/// Below this posting-list size, serial UNION is cheaper than spawning a
/// thread per arm. 500 is the starting-point calibration from the
/// GAP-0814-cost-model A/B — tune up/down if wall-time evidence shifts.
const PARALLEL_UNION_MIN_POSTING_SIZE: usize = 500;

/// GAP-0814-cost-model: predict the row-count a single UNION arm will
/// emit, using the anchor label's posting-list size. Returns null if the
/// query shape is too complex to predict cheaply (subquery, WHERE clause,
/// multi-hop pattern, multi-chain pattern, etc.) — callers interpret null
/// as "unknown/expensive" and keep the parallel path.
fn predictArmRowCount(q: ast.Query, graph: []const u8) ?usize {
    // Only predict single-chain, no-hop, single-label MATCH shapes.
    if (q.match.chains.len != 1) return null;
    const chain = q.match.chains[0];
    if (chain.hops.len != 0) return null;
    const head = chain.head orelse return null;
    if (head.labels.len != 1) return null;

    // Too complex to predict row-count cheaply: a WHERE, UNWIND, LET, CTE
    // pattern, CALL, subquery, chain-follow-on, or CREATE-after-MATCH can
    // all drastically change the emit count. Bail so the caller treats
    // this arm as "expensive" and keeps parallel.
    if (q.where_clause != null) return null;
    if (q.filter_clause != null) return null;
    if (q.unwind_clause != null) return null;
    if (q.let_bindings.len != 0) return null;
    if (q.inline_let_bindings.len != 0) return null;
    if (q.cte_list != null) return null;
    if (q.call_clause != null) return null;
    if (q.initial_call_subquery != null) return null;
    if (q.next_query != null) return null;
    if (q.create_pattern != null) return null;
    if (q.merge_statement != null) return null;

    // Read-only: getNodesByLabel is an O(1) map lookup into the label index,
    // no allocator required (GAP-0814-cost-model Task 2.1 verified).
    const store = graph_store.getCurrentGlobalStore() orelse return null;
    const posting = store.getNodesByLabel(graph, head.labels[0]) orelse return 0;
    return posting.len;
}

const ArmJob = struct {
    query: ast.Query,
    context: ExecutionContext,
    allocator: std.mem.Allocator,
    result: ?ExecutionResult = null,
    err: ?anyerror = null,
    /// SONNY-1330: set when this arm hit a NON-RESIDENT node / edge / adjacency
    /// and was refused the hydrate-on-miss that would have mutated the shared
    /// bounded cache. The arm's rows are then INCOMPLETE and must be discarded.
    needs_hydration: bool = false,

    fn runnerEntry(self: *ArmJob) void {
        // Each thread gets its own threadlocal active context via
        // `executeQueryNoLimitWithContext` -> `executeQueryWithContext`
        // which pushes/pops `g_active_context`. No shared mutable state.
        //
        // SONNY-1330: …except the four bounded caches (`nodes`, `edges`,
        // `outgoing_edges`, `incoming_edges`). `getOrHydratePtr` INSERTS on a
        // miss, which rehashes/moves the shard's value slots and can evict live
        // entries — invalidating the raw `*Node` / `*Edge` pointers a SIBLING
        // arm is holding in its bindings and result rows. Run the arm with
        // hydration disabled on this thread; a miss records `needs_hydration`
        // and the caller throws EVERY arm away and re-runs the UNION serially.
        const scope = graph_store.node_cache_mod.beginReadOnlyHydration();
        self.result = executeQueryNoLimitWithContext(self.allocator, self.query, self.context) catch |err| {
            self.needs_hydration = graph_store.node_cache_mod.endReadOnlyHydration(scope);
            // A suppressed hydration is the LIKELY cause of this error (a
            // `try`-ing caller propagates `error.CacheHydrationSuppressed`, and
            // fail-closed read paths turn a miss into NodeNotFound). Report the
            // fallback, not the error: the serial retry is the real answer.
            if (!self.needs_hydration) self.err = err;
            return;
        };
        self.needs_hydration = graph_store.node_cache_mod.endReadOnlyHydration(scope);
    }
};

// CANARY: REQ=REQ-QUIC-HC-125; FEATURE="ParallelUnionArms"; ASPECT=ThreadSafeArmAllocator; STATUS=TESTED; TEST=test_gap0814_union_parallelism; OWNER=execution; UPDATED=2026-05-28
//
// Parallel UNION arms inherit the caller's query allocator. Tests and embedded
// callers often use an ArenaAllocator for per-query lifetime management, and
// arena mutation is not safe when multiple arm threads allocate rows at once.
// Serialize allocator traffic while leaving storage scans and expression work
// concurrent.
const LockedAllocator = struct {
    parent: std.mem.Allocator,
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    fn init(parent: std.mem.Allocator) LockedAllocator {
        return .{ .parent = parent };
    }

    fn allocator(self: *LockedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.parent.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.parent.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LockedAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.parent.rawFree(memory, alignment, ret_addr);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };
};

/// GAP-0814 Task 5.1: fork-join all union arms, then merge.
/// Returns `null` if parallelism was elected not to be used (e.g. thread
/// spawn failure), signalling the caller to take the serial path. Any
/// per-arm execution error is propagated up.
fn tryParallelUnion(
    allocator: std.mem.Allocator,
    union_query: ast.UnionQuery,
    context: ExecutionContext,
) !?ExecutionResult {
    const arm_count = union_query.tails.len + 1;
    std.debug.assert(arm_count >= 2);
    // GAP-0814 regression probe: count entries so tests can assert the
    // parallel arm-spawn path was actually taken. Incremented before any
    // failure-path return so a failed spawn still counts as "attempted".
    _ = parallel_union_invocations.fetchAdd(1, .monotonic);

    var jobs = try allocator.alloc(ArmJob, arm_count);
    defer allocator.free(jobs);
    var locked_allocator = LockedAllocator.init(allocator);
    const arm_allocator = locked_allocator.allocator();

    // Arm 0: the first query. Arms 1..N: each tail's query (preserves
    // original left-to-right order so UNION DISTINCT merge is stable).
    jobs[0] = .{ .query = union_query.first, .context = context, .allocator = arm_allocator };
    for (union_query.tails, 0..) |tail, i| {
        jobs[i + 1] = .{ .query = tail.query, .context = context, .allocator = arm_allocator };
    }

    // Spawn a thread for every arm except the last, which we run on the
    // calling thread. This keeps worker count == arm_count - 1 and avoids
    // the overhead of self-submitting the final arm to the pool.
    const spawn_count = arm_count - 1;
    var threads = try allocator.alloc(std.Thread, spawn_count);
    defer allocator.free(threads);

    var spawned: usize = 0;
    errdefer {
        // Join anything we already spawned so threads can complete their
        // alloc/free traffic against `allocator` before we return the error.
        for (threads[0..spawned]) |*t| t.join();
        // Clean up any arm results that made it back.
        for (jobs) |*job| {
            if (job.result) |*res| res.deinit(allocator);
        }
    }

    while (spawned < spawn_count) {
        threads[spawned] = std.Thread.spawn(.{}, ArmJob.runnerEntry, .{&jobs[spawned]}) catch {
            // Thread spawn failure: signal caller to fall back to serial.
            // We haven't mutated any result state yet beyond jobs[0..spawned]
            // which we tear down via errdefer. Return null through a
            // sentinel error path.
            for (threads[0..spawned]) |*t| t.join();
            for (jobs) |*job| {
                if (job.result) |*res| res.deinit(allocator);
            }
            return null;
        };
        spawned += 1;
    }

    // Run the last arm inline on the calling thread — saves one thread
    // round-trip and keeps the happy-path latency close to max(arm_ns).
    jobs[arm_count - 1].runnerEntry();

    // Join all workers.
    for (threads) |*t| t.join();
    // 2026-04-27: clear `spawned` so the outer errdefer (which re-joins
    // `threads[0..spawned]` and was wired up to clean up partial-spawn
    // failures) does NOT double-join the threads we just finished
    // joining.  Thread.join → posix.pthread_join with .SRCH (no such
    // thread) is `unreachable`, panics with "reached unreachable code"
    // on the second call.  Repro: the `union-column-count-mismatch`
    // test in `gql_set_operations_comprehensive.yml` returns
    // `error.UnionColumnCountMismatch` from the merge loop below, which
    // unwinds through this errdefer and previously crashed the server
    // (panic stack rooted at `set_operations.zig:786 in tryParallelUnion`).
    spawned = 0;

    // SONNY-1330: did ANY arm get refused a hydrate-on-miss? If so its rows are
    // incomplete (a non-resident node/edge simply did not exist as far as that
    // arm could tell), so NOTHING any arm produced may be merged. Drop every
    // arm result and return `null`, which sends the caller to the serial path
    // below — the connection thread, where hydration mutates the shared caches
    // with no sibling reader holding pointers into them.
    //
    // Checked BEFORE error propagation on purpose: a suppressed hydration
    // surfaces at fail-closed read sites as `error.CacheHydrationSuppressed`,
    // `NodeNotFound`, or simply as a missing row, and "re-run serially" is the
    // right answer for all three. Safe to re-run because
    // `unionArmsAreParallelEligible` now admits only side-effect-free arms.
    var needs_hydration = false;
    for (jobs) |*job| {
        if (job.needs_hydration) needs_hydration = true;
    }
    if (needs_hydration) {
        _ = parallel_union_serial_fallbacks.fetchAdd(1, .monotonic);
        for (jobs) |*job| {
            if (job.result) |*res| res.deinit(allocator);
            job.result = null;
        }
        return null;
    }

    // Propagate the first error, if any.
    for (jobs) |*job| {
        if (job.err) |e| {
            for (jobs) |*j2| {
                if (j2.result) |*res| res.deinit(allocator);
            }
            return e;
        }
    }

    // Merge: take arm 0 as the accumulator (takes ownership of its rows),
    // then walk arms 1..N applying UNION ALL / UNION DISTINCT semantics
    // against the accumulator in the original order.
    var result = jobs[0].result.?;
    jobs[0].result = null; // transfer ownership so defer cleanup skips it
    errdefer result.deinit(allocator);

    for (union_query.tails, 0..) |tail, tail_idx| {
        const job_idx = tail_idx + 1;
        var part_result = jobs[job_idx].result.?;
        jobs[job_idx].result = null;
        defer part_result.deinit(allocator);

        if (part_result.columns.len != result.columns.len) {
            return error.UnionColumnCountMismatch;
        }

        // GAP-0535 review follow-up: combined owns = any-part-owns.
        try ensureCombinedOwnership(allocator, &result, part_result.owns_value_memory);

        if (tail.all) {
            // UNION ALL — append all rows, duplicating values since
            // part_result will free them on deinit (GAP-0535: deep when owned).
            // OOM safety (review follow-up): never expose undefined row slots
            // to an unwinding `errdefer result.deinit` — pre-fill the grown
            // tail with empty rows and only install fully-built rows.
            const old_rows = result.rows;
            const old_len = old_rows.len;
            const combined = try allocator.alloc([]Value, old_len + part_result.rows.len);
            for (old_rows, 0..) |row, i| combined[i] = row;
            @memset(combined[old_len..], empty_row);
            result.rows = combined;
            allocator.free(old_rows);
            for (part_result.rows, 0..) |row, i| {
                const new_row = try allocator.alloc(Value, row.len);
                var filled: usize = 0;
                errdefer {
                    if (result.owns_value_memory) {
                        for (new_row[0..filled]) |val| {
                            value_utilities.freeValue(allocator, val);
                        }
                    }
                    allocator.free(new_row);
                }
                for (row, 0..) |val, j| {
                    new_row[j] = try copyPartValue(allocator, result.owns_value_memory, part_result.owns_value_memory, val);
                    filled = j + 1;
                }
                combined[old_len + i] = new_row;
            }
        } else {
            // UNION DISTINCT — deduplicate across accumulator + incoming arm.
            var new_rows = try std.ArrayList([]Value).initCapacity(
                allocator,
                result.rows.len + part_result.rows.len,
            );

            for (result.rows) |row| {
                var is_duplicate = false;
                for (new_rows.items) |existing_row| {
                    if (rowsEqual(row, existing_row)) {
                        is_duplicate = true;
                        break;
                    }
                }
                if (!is_duplicate) {
                    const new_row = try allocator.alloc(Value, row.len);
                    for (row, 0..) |val, j| new_row[j] = val;
                    try new_rows.append(allocator, new_row);
                } else {
                    // GAP-0535: dropped duplicate — free values when owned
                    freeDroppedRowValues(allocator, &result, row);
                }
            }

            for (part_result.rows) |row| {
                var is_duplicate = false;
                for (new_rows.items) |existing_row| {
                    if (rowsEqual(row, existing_row)) {
                        is_duplicate = true;
                        break;
                    }
                }
                if (!is_duplicate) {
                    const new_row = try allocator.alloc(Value, row.len);
                    for (row, 0..) |val, j| new_row[j] = try copyPartValue(allocator, result.owns_value_memory, part_result.owns_value_memory, val);
                    try new_rows.append(allocator, new_row);
                }
            }

            // Free the old accumulator rows — we've copied anything we needed.
            for (result.rows) |row| allocator.free(row);
            allocator.free(result.rows);

            result.rows = try new_rows.toOwnedSlice(allocator);
        }
    }

    // Clear any remaining job results (should be none after the merge loop).
    for (jobs) |*job| {
        if (job.result) |*res| res.deinit(allocator);
    }

    return result;
}
