//! The statement checks every transport runs right after parsing, before any
//! path (a transport's write fast path included) runs anything. One walk of
//! the statement carries them all; each needs only the statement and the
//! request.
//!
//! - SONNY-3247, parameters (42P02, `MissingParameter`): a statement that
//!   references a parameter the request does not supply is refused, instead
//!   of reading the parameter as null. A named parameter nobody supplied
//!   evaluated to null: `SET q.name = $nosuch` erased the property, `LIMIT
//!   $nosuch` wrote every row, and a MERGE keyed on a missing parameter
//!   merged on null. Every parameter a statement names, anywhere (an
//!   expression, a property map, a SET value, a MERGE key, a subquery, a CTE
//!   body, a LIMIT or SKIP, a FOR's list), must be one the request supplies
//!   or one the statement defines itself (`LET $x = ...`). A variable a WITH,
//!   UNWIND or FOR binds is a variable, not a parameter: `WITH 5 AS k ... $k`
//!   is refused too.
//! - SONNY-3248, window values (22G03, `InvalidWindowParameter`): a SKIP or
//!   LIMIT parameter the request supplies is a non-negative integer.
//! - SONNY-3367, variable kinds (42000, `VariableKindConflict`): one name is
//!   one kind of element (`queryKindsConflict`).
//! - SONNY-3248, repeated SET targets (22G0M, `RepeatedSetTarget`): one SET
//!   clause assigns a property once (`setListRepeatsTarget`).
//! - SONNY-3245, insert patterns (42000, `InvalidInsertPattern`): a CREATE
//!   or INSERT pattern follows ISO/IEC 39075:2024 16.5 (`insertPatternInvalid`).
//! - SONNY-3318, a path variable on an OPTIONAL MATCH after the first
//!   pattern (0A000, `OptionalPathVariable`): no executor binds it (`count(p)`
//!   answered 0 of the paths matched).
//! - SONNY-6496, variable scope after a projection (42000,
//!   `VariableNotInScope`): after a WITH or NEXT only the variables it
//!   projects are in scope (scope_check.zig).
//! - SONNY-6637, function operand counts (42000, `WrongArgumentCount`): a
//!   call takes the number of operands the shared arity table gives
//!   (`scope_check.checkCallArity`, src/eval/function_arity.zig).
//!
//! The walk goes over the whole statement like the write walk
//! (write_walk.zig): iteratively, and by reflection over every AST type, so
//! a parameter in a field added later is still found.
//!
//! CANARY: REQ=REQ-SONNY-3247-MISSING-PARAMETER; FEATURE="ParameterBinding"; ASPECT=UnsuppliedParameter; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4.zig; OWNER=engine; UPDATED=2026-09-28

const std = @import("std");
const ast = @import("../gql/ast.zig");
const Value = @import("../value_types.zig").Value;
const scope_check = @import("scope_check.zig");

/// What the checks refuse (the module doc has each one): `MissingParameter`
/// (42P02), `VariableKindConflict` (42000), `RepeatedSetTarget` (22G0M),
/// `InvalidWindowParameter` (22G03), `OptionalPathVariable` (0A000) and
/// `VariableNotInScope` (42000).
pub const Error = error{ MissingParameter, OutOfMemory, VariableKindConflict, RepeatedSetTarget, InvalidWindowParameter, OptionalPathVariable, InvalidInsertPattern, VariableNotInScope, WrongArgumentCount };

/// Every statement of `program` names only parameters in `supplied` (or ones
/// it defines with LET). `values`: the supplied parameters' values (empty:
/// not known, and a SKIP or LIMIT parameter's value is not checked).
pub fn checkProgram(program: *const ast.Program, supplied: []const []const u8, values: []const Value) Error!void {
    for (program.statements) |*stmt| try checkStatement(stmt, supplied, values);
}

pub fn checkStatement(stmt: *const ast.Statement, supplied: []const []const u8, values: []const Value) Error!void {
    var sfa = std.heap.stackFallback(4096, std.heap.smp_allocator);
    var c = Collector{ .alloc = sfa.get(), .vars = scope_check.Checker.init(std.heap.smp_allocator) };
    defer c.deinit();
    c.push(.stmt, stmt);
    while (c.stack.pop()) |item| {
        c.scope = item.scope;
        // A query inside an expression (an IN subquery, a CTE body) sees the
        // LETs around it, as an EXISTS body and a query reached through a
        // query's own fields (a chained part, a CALL { } or FOR body) do.
        // SONNY-3248 (round 4b-1b review I-E): it was refused (42P02), while
        // an EXISTS body's WHERE was accepted, and both read null; the
        // executor now evaluates each with the statement's parameters, its
        // LETs among them (`evaluator_adapter.ExecutionCallbacks.runSubquery`).
        c.query_scope = item.scope;
        switch (item.kind) {
            .stmt => {
                const s: *const ast.Statement = @ptrCast(@alignCast(item.ptr));
                // SONNY-6525: the statement's queries start with nothing in
                // scope.
                if (!c.out_of_scope) c.vars.checkStatement(s) catch |err| switch (err) {
                    error.VariableNotInScope => c.out_of_scope = true,
                    error.OutOfMemory => c.failed = true,
                };
                switch (s.*) {
                    inline else => |*p| c.visit(@TypeOf(p.*), p),
                }
            },
            .query => {
                const q: *const ast.Query = @ptrCast(@alignCast(item.ptr));
                // SONNY-6496: the query and the parts chained after it, in
                // the scope each starts with (once per query).
                if (!c.out_of_scope) c.vars.checkQuery(q) catch |err| switch (err) {
                    error.VariableNotInScope => c.out_of_scope = true,
                    error.OutOfMemory => c.failed = true,
                };
                c.visitFields(ast.Query, q);
            },
            .expr => {
                const e: *const ast.Expr = @ptrCast(@alignCast(item.ptr));
                if (!c.isProcedure(e)) scope_check.checkCallArity(e) catch {
                    c.wrong_arity = true;
                };
                switch (e.*) {
                    .Param => |name| c.use(name),
                    inline else => |*p| c.visit(@TypeOf(p.*), p),
                }
            },
        }
    }
    if (c.failed) return error.OutOfMemory;
    if (c.kind_conflict) return error.VariableKindConflict;
    if (c.repeated_set_target) return error.RepeatedSetTarget;
    if (c.optional_path) return error.OptionalPathVariable;
    if (c.invalid_insert) return error.InvalidInsertPattern;
    if (c.wrong_arity) return error.WrongArgumentCount;
    for (c.used.items) |u| {
        if (has(supplied, u.name) or c.defines(u.scope, u.name)) continue;
        return error.MissingParameter;
    }
    if (c.out_of_scope) return error.VariableNotInScope;
    // CANARY: REQ=REQ-SONNY-3248-LIMIT-PARAM; FEATURE="Pagination"; ASPECT=InvalidWindowValue; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
    // SONNY-3248 (round 4b-1 review m-2): a SKIP or LIMIT parameter the
    // request supplies is a non-negative integer. Any other value (-1, 2.0,
    // '2', null) read as "no window", so every row came back. One a LET
    // defines is checked where the LET is evaluated (`execution.windowParam`).
    if (values.len == supplied.len) for (c.windows.items) |u| {
        if (c.defines(u.scope, u.name)) continue;
        for (supplied, values) |name, value| {
            if (!std.mem.eql(u8, name, u.name)) continue;
            if (!validWindowValue(value)) return error.InvalidWindowParameter;
            break;
        }
    };
}

// CANARY: REQ=REQ-SONNY-3245-INSERT-PATTERN-RULES; FEATURE="CreateStatement"; ASPECT=InsertSyntaxRules; STATUS=TESTED; TEST=tests/test_sonny3245_create_merge_forms.zig; OWNER=engine; UPDATED=2026-11-12
/// SONNY-3245: does CREATE / INSERT pattern `p` break ISO/IEC 39075:2024
/// 16.5 <insert graph pattern>? `bound`: the MATCH of the same query part,
/// whose variables the pattern's bound insert element patterns name. Each
/// was accepted and did the wrong thing:
/// - SR 10 a) iii): a bound insert element pattern carries no label or
///   property specification. `MATCH (n) CREATE (n:Extra)` did nothing and
///   `CREATE (n {extra: 1})` changed the matched node.
/// - SR 10 b): only the defining (first) occurrence of a variable carries
///   them. `CREATE (a:R), (a:R)` made two nodes.
/// - Format: an inserted edge points left, right, or is `~[ ]~` (Feature
///   GH02, which Geode does not support: its edges are directed), and has a
///   <label set specification>, which joins labels with `&`, never `|`.
///   `-[:T]-` stored a directed edge and `[:T|U]` stored a T edge; a stored
///   edge has exactly one type, so neither several types nor a quantifier
///   is accepted.
fn insertPatternInvalid(p: ast.GraphPattern, bound: ?ast.GraphPattern) bool {
    var declared_buf: [64][]const u8 = undefined;
    var declared: usize = 0;
    for (p.chains) |chain| {
        // The node positions of the path: the head, or each hop's right
        // with the first hop's left (a hop's left is the hop before's right).
        const first: ?ast.NodePattern = if (chain.hops.len == 0) chain.head else chain.hops[0].left;
        if (first) |n| {
            if (nodeInvalid(n, bound, declared_buf[0..declared])) return true;
            if (n.name) |name| if (declared < declared_buf.len) {
                declared_buf[declared] = name;
                declared += 1;
            };
        }
        for (chain.hops) |hop| {
            if (hop.rel.dir == .undirected) return true;
            if (hop.rel.types.len > 1) return true;
            if (hop.rel.min_len != null or hop.rel.max_len != null) return true;
            if (nodeInvalid(hop.right, bound, declared_buf[0..declared])) return true;
            if (hop.right.name) |name| if (declared < declared_buf.len) {
                declared_buf[declared] = name;
                declared += 1;
            };
        }
    }
    return false;
}

fn nodeInvalid(n: ast.NodePattern, bound: ?ast.GraphPattern, declared: []const []const u8) bool {
    const name = n.name orelse return false;
    const specified = n.labels.len > 0 or n.props != null;
    if (!specified) return false;
    if (has(declared, name)) return true;
    const b = bound orelse return false;
    return patternNames(b, name);
}

fn patternNames(p: ast.GraphPattern, name: []const u8) bool {
    for (p.chains) |chain| {
        if (chain.head) |h| if (h.name) |n| if (std.mem.eql(u8, n, name)) return true;
        for (chain.hops) |hop| {
            if (hop.left.name) |n| if (std.mem.eql(u8, n, name)) return true;
            if (hop.right.name) |n| if (std.mem.eql(u8, n, name)) return true;
        }
    }
    return false;
}

/// A SKIP or LIMIT value: a non-negative integer.
pub fn validWindowValue(v: Value) bool {
    return switch (v) {
        .Int => |i| i >= 0,
        else => false,
    };
}

fn has(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

const Kind = enum(u8) { stmt, query, expr };
/// `scope`: the innermost `LET $x` in force where the item sits
/// (`Collector.lets`), or `no_scope`.
const Item = struct { ptr: *const anyopaque, kind: Kind, scope: u32 };
const no_scope = std.math.maxInt(u32);

// CANARY: REQ=REQ-SONNY-3248-LET-SCOPE; FEATURE="ParameterBinding"; ASPECT=LetScope; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3248 (round-4a review M-3): a `LET $x` defines $x for the query it
/// heads, its expressions and the queries they and its own fields hold
/// (subqueries, chained parts, CALL { } and FOR bodies), not for the whole
/// statement: `MATCH (q) WHERE q.i IN (LET $z = 1 MATCH (k) WHERE k.i = $z
/// RETURN k.i) RETURN $z` names a $z the outer query does not define, and is
/// refused with 42P02 (it read null).
/// Each LET is a link in a chain to the LET around it (`lets`); a use is
/// resolved up the chain it was found in.
const Let = struct { parent: u32, name: []const u8 };

const Collector = struct {
    alloc: std.mem.Allocator,
    stack: std.ArrayList(Item) = .empty,
    /// The parameters the statement names, each with the LET scope it is in.
    used: std.ArrayList(struct { name: []const u8, scope: u32 }) = .empty,
    /// The SKIP and LIMIT parameters among them.
    windows: std.ArrayList(struct { name: []const u8, scope: u32 }) = .empty,
    /// Every `LET $x = ...`, linked to the LET scope around it.
    lets: std.ArrayList(Let) = .empty,
    /// The LET scope of what is being visited.
    scope: u32 = no_scope,
    /// The LET scope a query found while visiting it starts in.
    query_scope: u32 = no_scope,
    failed: bool = false,
    /// SONNY-3367: a pattern names one variable as two kinds of element.
    kind_conflict: bool = false,
    /// SONNY-3248: a SET clause assigns one property of a variable twice.
    repeated_set_target: bool = false,
    /// SONNY-3318: an OPTIONAL MATCH after the first pattern names a path.
    optional_path: bool = false,
    /// SONNY-3245: a CREATE or INSERT pattern breaks ISO 16.5.
    invalid_insert: bool = false,
    /// SONNY-6496: the projection-scope check, and whether it refused.
    vars: scope_check.Checker,
    out_of_scope: bool = false,
    /// SONNY-6637: a function call with an operand count the arity table
    /// refuses; and the procedures CALL names, which are no function calls.
    wrong_arity: bool = false,
    procedures: std.ArrayList(*const ast.Expr) = .empty,

    fn deinit(c: *Collector) void {
        c.procedures.deinit(c.alloc);
        c.vars.deinit();
        c.stack.deinit(c.alloc);
        c.used.deinit(c.alloc);
        c.windows.deinit(c.alloc);
        c.lets.deinit(c.alloc);
    }

    fn push(c: *Collector, kind: Kind, ptr: *const anyopaque) void {
        const scope = if (kind == .query) c.query_scope else c.scope;
        c.stack.append(c.alloc, .{ .ptr = ptr, .kind = kind, .scope = scope }) catch {
            c.failed = true;
        };
    }

    fn use(c: *Collector, name: []const u8) void {
        c.used.append(c.alloc, .{ .name = name, .scope = c.scope }) catch {
            c.failed = true;
        };
    }

    fn defines(c: *const Collector, scope: u32, name: []const u8) bool {
        var at = scope;
        while (at != no_scope) {
            const let = c.lets.items[at];
            if (std.mem.eql(u8, let.name, name)) return true;
            at = let.parent;
        }
        return false;
    }

    fn isProcedure(c: *const Collector, e: *const ast.Expr) bool {
        for (c.procedures.items) |p| {
            if (p == e) return true;
        }
        return false;
    }

    fn visit(c: *Collector, comptime T: type, v: *const T) void {
        if (T == ast.CallProcedure or T == ast.CallClause) {
            c.procedures.append(c.alloc, &v.procedure) catch {
                c.failed = true;
            };
        }
        if (T == ast.GraphPattern) {
            // A CREATE, INSERT or MERGE statement's own pattern (a query's
            // patterns are checked together in `visitFields`).
            if (patternKindsConflict(c.alloc, &.{v.*}, null, &.{})) |conflict| {
                if (conflict) c.kind_conflict = true;
            } else |_| c.failed = true;
        }
        if (T == ast.CreateStatement or T == ast.InsertStatement) {
            if (insertPatternInvalid(v.pattern, null)) c.invalid_insert = true;
        }
        if (T == ast.ForStatement) {
            // SONNY-3367 (round 4b-1b review I-A): a FOR's variables are
            // values, not elements, in the query it runs.
            if (v.body) |body| {
                if (forKindsConflict(c.alloc, v, body, &.{})) |conflict| {
                    if (conflict) c.kind_conflict = true;
                } else |_| c.failed = true;
            }
        }
        if (T == ast.MergeStatement) {
            if (setListRepeatsTarget(v.on_create, v.on_create_ends) or setListRepeatsTarget(v.on_match, v.on_match_ends)) c.repeated_set_target = true;
            if (mergeAliasRepeatsTarget(v)) c.repeated_set_target = true;
        }
        if (comptime !holds(T)) return;
        if (T == ast.Expr) return c.push(.expr, v);
        if (T == ast.Query) return c.push(.query, v);
        if (T == ast.Statement) return c.push(.stmt, v);
        switch (@typeInfo(T)) {
            .@"struct" => c.visitFields(T, v),
            .@"union" => switch (v.*) {
                inline else => |*p| c.visit(@TypeOf(p.*), p),
            },
            .optional => |o| if (v.*) |*inner| c.visit(o.child, inner),
            .pointer => |p| switch (p.size) {
                .one => c.visit(p.child, v.*),
                .slice => for (v.*) |*elem| c.visit(p.child, elem),
                else => @compileError("param_check: a " ++ @typeName(T) ++ " in the AST"),
            },
            .array => |a| for (v) |*elem| c.visit(a.child, elem),
            else => @compileError("param_check: a " ++ @typeName(T) ++ " in the AST"),
        }
    }

    /// Every field of struct `v`: a LIMIT or SKIP parameter by name, a LET
    /// binding's parameter as defined, the rest walked.
    fn visitFields(c: *Collector, comptime T: type, v: *const T) void {
        if (T == ast.Query) {
            // `LET $x = <expr>` before a query defines $x for it and what it
            // holds; an inline `LET x = <expr>` after its MATCH defines a
            // variable, which no `$x` reads.
            // SONNY-3248 (round 4b-1 review I-6): a LET's value sees the
            // LETs before it, not itself or the ones after it (the executor
            // evaluates them in order): `LET $a = $b, $b = 1` names a $b not
            // yet defined.
            for (v.let_bindings) |*binding| {
                c.push(.expr, &binding.value);
                c.lets.append(c.alloc, .{ .parent = c.scope, .name = binding.variable }) catch {
                    c.failed = true;
                    return;
                };
                c.scope = @intCast(c.lets.items.len - 1);
            }
            c.query_scope = c.scope;
            if (queryKindsConflict(c.alloc, v)) |conflict| {
                if (conflict) c.kind_conflict = true;
            } else |_| c.failed = true;
            if (setListRepeatsTarget(v.set_clauses, v.set_clause_ends)) c.repeated_set_target = true;
            if (v.create_pattern) |cp| {
                if (insertPatternInvalid(cp, v.match)) c.invalid_insert = true;
            }
            if (v.match.chains.len > 1) for (v.match.chains[1..]) |chain| {
                if (chain.is_optional and chain.name != null) c.optional_path = true;
            };
        }
        inline for (@typeInfo(T).@"struct".fields) |field| {
            // A query's LET values are pushed above, each in its own scope.
            if (comptime T == ast.Query and std.mem.eql(u8, field.name, "let_bindings")) continue;
            const is_param_name = comptime (std.mem.eql(u8, field.name, "limit_param") or std.mem.eql(u8, field.name, "offset_param"));
            if (is_param_name) {
                if (field.type != ?[]const u8) @compileError("param_check: " ++ @typeName(T) ++ "." ++ field.name ++ " is not a parameter name");
                if (@field(v.*, field.name)) |name| {
                    c.use(name);
                    c.windows.append(c.alloc, .{ .name = name, .scope = c.scope }) catch {
                        c.failed = true;
                    };
                }
            } else {
                c.visit(field.type, &@field(v.*, field.name));
            }
        }
    }
};

/// Whether a value of type `T` can hold a statement, a query or an
/// expression (the only places a parameter is named), or names a LIMIT or
/// SKIP parameter.
fn holds(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    if (T == ast.Expr or T == ast.Query or T == ast.Statement) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            for (s.fields) |field| {
                if (std.mem.eql(u8, field.name, "limit_param") or std.mem.eql(u8, field.name, "offset_param")) break :blk true;
                if (holds(field.type)) break :blk true;
            }
            break :blk false;
        },
        .@"union" => |u| blk: {
            if (u.tag_type == null) @compileError("param_check: an untagged union " ++ @typeName(T) ++ " in the AST");
            for (u.fields) |field| {
                if (holds(field.type)) break :blk true;
            }
            break :blk false;
        },
        .optional => |o| holds(o.child),
        .pointer => |p| switch (p.size) {
            .one, .slice => holds(p.child),
            else => @compileError("param_check: a " ++ @typeName(T) ++ " in the AST"),
        },
        .array => |a| holds(a.child),
        .int, .float, .bool, .@"enum", .void => false,
        else => @compileError("param_check: a " ++ @typeName(T) ++ " in the AST"),
    };
}

// ---------------------------------------------------------------------------
// The shape checks that ride on the walk.

// CANARY: REQ=REQ-SONNY-3367-VARIABLE-KIND; FEATURE="PatternVariables"; ASPECT=KindConflict; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3367 (round 4b-1 review C-1): what a pattern variable binds. One
/// name is one kind of element in a query part: a node, a relationship, the
/// list of relationships a quantified hop walked, or a path. `value`: a name
/// a part before bound to something that is no element (`WITH r.w AS r`,
/// `WITH collect(g) AS l`, a FOR's variable), which no pattern may name.
pub const VarKind = enum { node, relationship, relationship_list, path, value };

const Named = struct { name: []const u8, kind: VarKind };

fn addNamed(alloc: std.mem.Allocator, seen: *std.ArrayList(Named), name: ?[]const u8, kind: VarKind) !bool {
    const n = name orelse return false;
    for (seen.items) |s| {
        if (!std.mem.eql(u8, s.name, n)) continue;
        return s.kind != kind;
    }
    try seen.append(alloc, .{ .name = n, .kind = kind });
    return false;
}

/// Whether `patterns` (and `path_var`, and the variables `carried` from a
/// part before) name one variable as two kinds of element: `MATCH (g)-[r:R]->
/// (x), (r) DETACH DELETE r` read `(r)` as a node pattern with an unbound
/// variable, so r was every node of the graph beside the relationship r, and
/// the DETACH DELETE deleted the graph (over gRPC, returning r read a node
/// as a relationship and aborted the server). A node variable used as a
/// relationship (`(a)-[a]->(b)`) was joined the same way. Geode refuses a
/// variable declared as two kinds of element as a syntax error (42000),
/// before anything runs.
fn patternKindsConflict(alloc: std.mem.Allocator, patterns: []const ast.GraphPattern, path_var: ?[]const u8, carried: []const Named) !bool {
    var seen: std.ArrayList(Named) = .empty;
    defer seen.deinit(alloc);
    try seen.appendSlice(alloc, carried);
    return collectKinds(alloc, &seen, patterns, path_var);
}

fn collectKinds(alloc: std.mem.Allocator, seen: *std.ArrayList(Named), patterns: []const ast.GraphPattern, path_var: ?[]const u8) !bool {
    if (try addNamed(alloc, seen, path_var, .path)) return true;
    for (patterns) |pattern| for (pattern.chains) |chain| {
        if (try addNamed(alloc, seen, chain.name, .path)) return true;
        if (chain.head) |head| if (try addNamed(alloc, seen, head.name, .node)) return true;
        for (chain.hops) |hop| {
            if (try addNamed(alloc, seen, hop.left.name, .node)) return true;
            const quantified = hop.rel.min_len != null or hop.rel.max_len != null;
            if (try addNamed(alloc, seen, hop.rel.name, if (quantified) .relationship_list else .relationship)) return true;
            if (try addNamed(alloc, seen, hop.right.name, .node)) return true;
        }
    };
    return false;
}

/// The variables a WITH passes on to the part after it, with their kinds
/// (`seen`: what the part named). SONNY-3367 (round 4b-1b review I-A):
/// `WITH *` passes every variable on, so `MATCH (g)-[r:R]->(x) WITH * MATCH
/// (r)` bound `(r)` to every node, as `WITH r` did before round 4b-1b.
/// `WITH <expression> AS v` binds a value, which no later pattern may name
/// (`WITH r.w AS r MATCH (r)` bound every node). A name the part did not
/// bind (a procedure's YIELD, an UNWIND) is not known here, and not carried.
fn carryThrough(alloc: std.mem.Allocator, items: []const ast.ReturnItem, seen: []const Named, carried: *std.ArrayList(Named)) !void {
    carried.clearRetainingCapacity();
    for (items) |item| {
        switch (item.expr) {
            .Ident => |id| if (std.mem.eql(u8, id.orig, "*")) {
                for (seen) |s| try putCarried(alloc, carried, s);
            } else for (seen) |s| {
                if (!std.mem.eql(u8, s.name, id.orig)) continue;
                try putCarried(alloc, carried, .{ .name = item.alias orelse id.orig, .kind = s.kind });
                break;
            },
            else => if (item.alias) |alias| try putCarried(alloc, carried, .{ .name = alias, .kind = .value }),
        }
    }
}

/// `n` in `carried`, replacing a name carried already (`WITH *, x AS r`: the
/// alias wins).
fn putCarried(alloc: std.mem.Allocator, carried: *std.ArrayList(Named), n: Named) !void {
    for (carried.items) |*c| {
        if (std.mem.eql(u8, c.name, n.name)) {
            c.* = n;
            return;
        }
    }
    try carried.append(alloc, n);
}

/// A query part's patterns (its MATCH, its CREATE, its MERGE), and each part
/// chained after it: a WITH item that passes a variable on keeps its kind in
/// the next part (`carryThrough`); a FOR after a WITH runs its body with the
/// WITH's variables and its own (`forKindsConflict`).
fn queryKindsConflict(alloc: std.mem.Allocator, head: *const ast.Query) !bool {
    return partsKindsConflict(alloc, head, &.{});
}

fn partsKindsConflict(alloc: std.mem.Allocator, head: *const ast.Query, initial: []const Named) std.mem.Allocator.Error!bool {
    var carried: std.ArrayList(Named) = .empty;
    defer carried.deinit(alloc);
    try carried.appendSlice(alloc, initial);
    var seen: std.ArrayList(Named) = .empty;
    defer seen.deinit(alloc);
    var part: ?*const ast.Query = head;
    while (part) |q| : (part = q.next_query) {
        seen.clearRetainingCapacity();
        try seen.appendSlice(alloc, carried.items);
        // A WITH before the part's MATCH binds its values for it
        // (`WITH 1 AS r MATCH (r)`).
        if (q.initial_with) |iw| {
            var initial_values: std.ArrayList(Named) = .empty;
            defer initial_values.deinit(alloc);
            try carryThrough(alloc, iw.items, seen.items, &initial_values);
            for (initial_values.items) |n| try putCarried(alloc, &seen, n);
        }
        var patterns: [3]ast.GraphPattern = undefined;
        var n: usize = 0;
        patterns[n] = q.match;
        n += 1;
        if (q.create_pattern) |cp| {
            patterns[n] = cp;
            n += 1;
        }
        if (q.merge_statement) |m| {
            patterns[n] = m.pattern;
            n += 1;
        }
        if (try collectKinds(alloc, &seen, patterns[0..n], q.path_variable)) return true;
        const wc = q.with_clause orelse break;
        if (q.is_initial_with) break;
        try carryThrough(alloc, wc.items, seen.items, &carried);
        if (q.for_statement) |f| if (f.body) |body| {
            if (try forKindsConflict(alloc, f, body, carried.items)) return true;
        };
    }
    return false;
}

/// A FOR's body, with the variables `carried` into it and the FOR's own,
/// which are values.
fn forKindsConflict(alloc: std.mem.Allocator, f: *const ast.ForStatement, body: *const ast.Query, carried: []const Named) std.mem.Allocator.Error!bool {
    var initial: std.ArrayList(Named) = .empty;
    defer initial.deinit(alloc);
    try initial.appendSlice(alloc, carried);
    for ([_]?[]const u8{ f.variable, f.ordinality_var, f.offset_var }) |maybe| {
        if (maybe) |name| try putCarried(alloc, &initial, .{ .name = name, .kind = .value });
    }
    return partsKindsConflict(alloc, body, initial.items);
}

// CANARY: REQ=REQ-SONNY-3248-REPEATED-SET-TARGET; FEATURE="SetClauseSemantics"; ASPECT=StaticRefusal; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-28
/// SONNY-3248 (round 4b-1 review I-2, I-3): whether one SET clause of
/// `clauses` (ending at `ends`, `ast.SetClauseGroups`) assigns one property
/// of one variable twice, or `SET n = {map}` beside another assignment to n.
/// The executors refused it only when they applied the clause: after a
/// CREATE or MERGE had inserted what it created (so a refused `CREATE (z:Z)
/// SET z.a = 1, z.a = 2` left z behind), and never on the QUIC MERGE fast
/// path (last one won). Checked on the statement now, before any path runs
/// it. Two variables bound to one element are still refused where the
/// executor binds them (`write_scope.refuseRepeatedTargets`).
pub fn setListRepeatsTarget(clauses: []const ast.SetClause, ends: []const usize) bool {
    var groups = ast.SetClauseGroups.init(clauses, ends);
    while (groups.next()) |group| {
        for (group, 0..) |a, i| {
            if (a == .Labels) continue;
            for (group[i + 1 ..]) |b| {
                if (b == .Labels) continue;
                if (!std.mem.eql(u8, targetOf(a), targetOf(b))) continue;
                const clash = switch (a) {
                    .Property => |pa| switch (b) {
                        .Property => |pb| std.mem.eql(u8, pa.target.property, pb.target.property),
                        else => true,
                    },
                    else => true,
                };
                if (clash) return true;
            }
        }
    }
    return false;
}

// CANARY: REQ=REQ-SONNY-3248-REPEATED-SET-TARGET; FEATURE="SetClauseSemantics"; ASPECT=MergeAliases; STATUS=TESTED; TEST=tests/test_sonny_write_allowlist_r4b.zig; OWNER=engine; UPDATED=2026-09-29
/// SONNY-3248 (round 4b-1b review m-c): whether a chained MERGE's SET list
/// assigns one property through two variables that bind one node: two MERGE
/// node patterns with the same labels and the same literal key (`MERGE (a:W
/// {k: 1}) MERGE (b:W {k: 1}) SET a.x = 1, b.x = 2`), where the second
/// always matches the node the first created or matched. It was refused
/// only where the executor bound the two (`write_scope.refuseRepeatedTargets`),
/// after the first MERGE had created the node, which stayed.
fn mergeAliasRepeatsTarget(m: *const ast.MergeStatement) bool {
    if (m.last_clause_start == null) return false;
    var patterns: [64]ast.NodePattern = undefined;
    var n: usize = 0;
    for (m.pattern.chains) |chain| {
        if (chain.head) |head| {
            if (n < patterns.len) patterns[n] = head;
            n += 1;
        }
        for (chain.hops) |hop| for ([_]ast.NodePattern{ hop.left, hop.right }) |np| {
            if (n < patterns.len) patterns[n] = np;
            n += 1;
        };
    }
    if (n > patterns.len) return false;
    for (patterns[0..n], 0..) |a, i| {
        const an = a.name orelse continue;
        for (patterns[i + 1 .. n]) |b| {
            const bn = b.name orelse continue;
            if (std.mem.eql(u8, an, bn) or !samePattern(a, b)) continue;
            if (setsBoth(m.on_create, m.on_create_ends, an, bn) or setsBoth(m.on_match, m.on_match_ends, an, bn)) return true;
        }
    }
    return false;
}

/// Whether one SET clause of `clauses` assigns one property of `a` and of
/// `b`, or replaces one's properties beside any assignment to the other.
fn setsBoth(clauses: []const ast.SetClause, ends: []const usize, a: []const u8, b: []const u8) bool {
    var groups = ast.SetClauseGroups.init(clauses, ends);
    while (groups.next()) |group| {
        for (group) |x| {
            if (x == .Labels or !std.mem.eql(u8, targetOf(x), a)) continue;
            for (group) |y| {
                if (y == .Labels or !std.mem.eql(u8, targetOf(y), b)) continue;
                const clash = switch (x) {
                    .Property => |px| switch (y) {
                        .Property => |py| std.mem.eql(u8, px.target.property, py.target.property),
                        else => true,
                    },
                    else => true,
                };
                if (clash) return true;
            }
        }
    }
    return false;
}

/// The same labels and the same literal properties, in the same order: two
/// MERGE patterns that match the same nodes. A property that is no literal
/// (a parameter, an expression) is not compared: not the same.
fn samePattern(a: ast.NodePattern, b: ast.NodePattern) bool {
    if (a.labels.len == 0 or a.labels.len != b.labels.len) return false;
    for (a.labels, b.labels) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    const ap = a.props orelse return false;
    const bp = b.props orelse return false;
    if (ap.len == 0 or ap.len != bp.len) return false;
    for (ap, bp) |x, y| {
        if (!std.mem.eql(u8, x.key, y.key)) return false;
        const same = switch (x.value.*) {
            .Int => |i| y.value.* == .Int and y.value.Int == i,
            .String => |str| y.value.* == .String and std.mem.eql(u8, y.value.String, str),
            .Bool => |v| y.value.* == .Bool and y.value.Bool == v,
            else => false,
        };
        if (!same) return false;
    }
    return true;
}

fn targetOf(sc: ast.SetClause) []const u8 {
    return switch (sc) {
        .Property => |p| p.target.object,
        .Labels => |l| l.node,
        .AllProperties => |a| a.node,
    };
}
