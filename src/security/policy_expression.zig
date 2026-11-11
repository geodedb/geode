// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=PolicyExpressionModule; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20
// CANARY: REQ=REQ-GPS-ABAC-001; FEATURE="GPS ABAC Predicates"; ASPECT=PolicyExpressionModule; STATUS=TESTED; TEST=tests/test_gps_abac_predicates.zig; OWNER=security; UPDATED=2026-05-20
//
// policy_expression.zig — minimal expression compiler and evaluator for GPS
// policy predicates.
//
// Phase 5 (Task 5-4) scope: compile a subset of GQL-flavored predicate
// expressions into an in-memory IR and evaluate them against a
// PolicyEvalContext.  The supported grammar covers:
//
//   expr   ::= or_expr
//   or_    ::= and_ ( "OR" and_ )*
//   and_   ::= atom  ( "AND" atom )*
//   atom   ::= "(" expr ")"
//            | "true"
//            | "current_user()"  "=" string_lit
//            | "current_tenant()" "=" string_lit
//            | "current_graph()"  "=" string_lit
//            | "resource.label"   "=" string_lit
//            | "principal.attributes." identifier "=" string_lit   (Phase 6 Task 6-2)
//            | row_prop cmp_op session_fn                        (row condition)
//            | session_fn cmp_op row_prop                        (row condition)
//
//   session_fn ::= "current_user()" | "current_tenant()" | "current_graph()"
//   row_prop   ::= [A-Za-z_][A-Za-z0-9_]*   (a property of the row, e.g. owner)
//   cmp_op     ::= "=" | "<>"
//   string_lit ::= "'" [^']* "'"
//
// Row conditions compare a property of the row being read with a function of
// the session, e.g. `owner = current_user()`. The function is evaluated per
// session when the row is read, never when the policy is created. A row
// condition is known only when both sides are known strings: a missing or null
// property, a property that is not a string, or a session function with no
// value makes the comparison UNKNOWN (for `<>` too), as is every row condition
// with no row in the context (a statement-level decision). AND / OR combine
// unknown with three-valued (Kleene) logic (`evaluateTruth`). `evaluate`
// reports only TRUE as holding, so an allow policy does not match an unknown
// condition; `gps.rowPoliciesAllow` applies a DENY policy unless its condition
// is FALSE, so an unknown condition withholds the row (SONNY-4878).
//
// AND binds tighter than OR (standard SQL precedence).
// Comparisons are case-sensitive.
//
// The RLS VM (`rls_core.zig`) is NOT used here because its `compileExpression`
// is a private method on an internal struct type and operates over an
// incompatible bytecode format (row-field loads, username builtins).  A
// hand-rolled IR is more correct and smaller for this subset.

const std = @import("std");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// A single key=value attribute entry from a principal's AttributeMap.
/// Mirrors principal.AttributeMap.Entry without creating an import cycle.
pub const AttributeEntry = struct {
    key: []const u8,
    value: []const u8,
};

/// Execution context supplied by the GPS decision engine when evaluating a
/// compiled expression.  All fields are optional; a null means "unknown" and
/// an equality check against it fails rather than erroring.
///
/// Phase 6 (Task 6-2): `principal_attributes` carries the caller's
/// AttributeMap entries so that `eq_principal_attr` predicates can look up
/// arbitrary ABAC key/value pairs without importing principal.zig directly.
pub const PolicyEvalContext = struct {
    current_user: ?[]const u8,
    current_tenant: ?[]const u8,
    current_graph: ?[]const u8,
    resource_label: ?[]const u8,
    // CANARY: REQ=REQ-GPS-ABAC-001; FEATURE="GPS ABAC Predicates"; ASPECT=EvalContextAttributes; STATUS=TESTED; TEST=tests/test_gps_abac_predicates.zig; OWNER=security; UPDATED=2026-05-20
    /// Slice of principal attribute entries.  May be empty (never null) so
    /// that attribute predicates simply fail-closed when no attributes are set.
    principal_attributes: []const AttributeEntry = &.{},
    /// The row being read, for row conditions (`owner = current_user()`).
    /// Null for a statement-level decision: every row condition is then
    /// unknown (and `evaluate` reports it as not holding).
    row: ?RowAccessor = null,
};

/// The session functions a policy expression can call.
pub const SessionFn = enum {
    current_user,
    current_tenant,
    current_graph,

    pub fn sourceName(self: SessionFn) []const u8 {
        return switch (self) {
            .current_user => "current_user()",
            .current_tenant => "current_tenant()",
            .current_graph => "current_graph()",
        };
    }

    fn value(self: SessionFn, ctx: PolicyEvalContext) ?[]const u8 {
        return switch (self) {
            .current_user => ctx.current_user,
            .current_tenant => ctx.current_tenant,
            .current_graph => ctx.current_graph,
        };
    }
};

/// A comparison operator of a row condition.
pub const CmpOp = enum { eq, ne };

/// A row property as a row condition sees it. Only `string` compares; the
/// others make every comparison unknown (an allow does not match it, a deny
/// applies: SONNY-4878).
pub const RowValue = union(enum) {
    missing,
    null_,
    string: []const u8,
    /// Any non-string value (integer, float, boolean, ...).
    other,
};

/// Read access to the row being decided, supplied by the caller (the read
/// path) so this module does not depend on the store's property types.
pub const RowAccessor = struct {
    ctx: *const anyopaque,
    getFn: *const fn (ctx: *const anyopaque, name: []const u8) RowValue,

    pub fn get(self: RowAccessor, name: []const u8) RowValue {
        return self.getFn(self.ctx, name);
    }
};

// ---------------------------------------------------------------------------
// Expression IR
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=PredicateIR; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20

/// A minimal predicate IR node.  All string slices are owned by the
/// CompiledExpression.arena; no separate lifetime management is required.
pub const Predicate = union(enum) {
    literal_true,
    eq_current_user: []const u8,
    eq_current_tenant: []const u8,
    eq_current_graph: []const u8,
    eq_resource_label: []const u8,
    // CANARY: REQ=REQ-GPS-ABAC-001; FEATURE="GPS ABAC Predicates"; ASPECT=PredicateIRAttr; STATUS=TESTED; TEST=tests/test_gps_abac_predicates.zig; OWNER=security; UPDATED=2026-05-20
    /// principal.attributes.<key> = '<value>'
    eq_principal_attr: struct { key: []const u8, value: []const u8 },
    /// <row property> (= | <>) <session function>, in either order.
    row_vs_session: struct { property: []const u8, func: SessionFn, op: CmpOp },
    and_: struct { left: *const Predicate, right: *const Predicate },
    or_: struct { left: *const Predicate, right: *const Predicate },
};

/// A compiled expression.  The `arena` owns all IR allocations including
/// Predicate nodes and string slices for literal values.  Call `deinit` when
/// no longer needed.
pub const CompiledExpression = struct {
    arena: std.heap.ArenaAllocator,
    root: *const Predicate,
    /// True when the expression has a row condition: the policy then
    /// filters rows on the read path (see gps.rowPoliciesAllow).
    reads_row: bool = false,
    /// True when the expression reads `principal.attributes.<key>`.
    reads_attributes: bool = false,

    pub fn deinit(self: *CompiledExpression) void {
        self.arena.deinit();
    }
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=Compile; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20

/// Parse and compile `source` into a `CompiledExpression`.
/// Returns `error.InvalidExpression` on any parse or structural error.
/// The caller owns the returned `CompiledExpression` and must call `deinit`.
pub fn compileExpression(allocator: std.mem.Allocator, source: []const u8) !CompiledExpression {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parser = ExprParser{ .src = source, .pos = 0, .allocator = arena.allocator() };
    const root = try parser.parseOr();
    // Ensure there is no trailing junk after the expression.
    parser.skipWs();
    if (parser.pos != parser.src.len) {
        return error.InvalidExpression;
    }
    return CompiledExpression{
        .arena = arena,
        .root = root,
        .reads_row = parser.reads_row,
        .reads_attributes = parser.reads_attributes,
    };
}

// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=Evaluate; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20

/// Evaluate a compiled expression against the given context.
/// Always returns a definite boolean: true only when the expression is TRUE
/// (fail-closed for an allow: an UNKNOWN expression does not hold). A deny
/// decision must not use this — see `evaluateTruth`.
pub fn evaluate(expr: *const CompiledExpression, ctx: PolicyEvalContext) bool {
    return evaluateTruth(expr, ctx) == .true_;
}

// CANARY: REQ=REQ-SONNY-4878-ROW-DENY-UNKNOWN; FEATURE="GPS Row Conditions"; ASPECT=ThreeValuedEval; STATUS=TESTED; TEST=tests/test_sonny4878_row_deny_unknown.zig; OWNER=security; UPDATED=2026-11-11
/// The three-valued truth of an expression. A row condition whose row
/// property or session value is unknown is UNKNOWN, and AND / OR propagate it
/// (`unknown AND false` is false, `unknown OR true` is true, otherwise
/// unknown). Equality predicates against a literal stay definite (a missing
/// value is false), as before.
pub const Truth = enum { false_, true_, unknown };

/// Evaluate a compiled expression to its three-valued truth. A deny policy
/// applies unless this is `.false_` (SONNY-4878).
pub fn evaluateTruth(expr: *const CompiledExpression, ctx: PolicyEvalContext) Truth {
    return evalPredicate(expr.root, ctx);
}

// ---------------------------------------------------------------------------
// Evaluator (private)
// ---------------------------------------------------------------------------

fn truth(b: bool) Truth {
    return if (b) .true_ else .false_;
}

fn evalPredicate(p: *const Predicate, ctx: PolicyEvalContext) Truth {
    return switch (p.*) {
        .literal_true => .true_,
        .eq_current_user => |v| truth(ctx.current_user != null and std.mem.eql(u8, ctx.current_user.?, v)),
        .eq_current_tenant => |v| truth(ctx.current_tenant != null and std.mem.eql(u8, ctx.current_tenant.?, v)),
        .eq_current_graph => |v| truth(ctx.current_graph != null and std.mem.eql(u8, ctx.current_graph.?, v)),
        .eq_resource_label => |v| truth(ctx.resource_label != null and std.mem.eql(u8, ctx.resource_label.?, v)),
        // CANARY: REQ=REQ-GPS-ABAC-001; FEATURE="GPS ABAC Predicates"; ASPECT=EvalAttrPredicate; STATUS=TESTED; TEST=tests/test_gps_abac_predicates.zig; OWNER=security; UPDATED=2026-05-20
        .eq_principal_attr => |kv| blk: {
            for (ctx.principal_attributes) |e| {
                if (std.mem.eql(u8, e.key, kv.key)) {
                    break :blk truth(std.mem.eql(u8, e.value, kv.value));
                }
            }
            // Key not present in the attribute set → fail-closed.
            break :blk .false_;
        },
        .row_vs_session => |rc| evalRowCondition(rc.property, rc.func, rc.op, ctx),
        // Kleene AND / OR: unknown propagates unless the other side decides.
        .and_ => |a| blk: {
            const l = evalPredicate(a.left, ctx);
            if (l == .false_) break :blk .false_;
            const r = evalPredicate(a.right, ctx);
            if (r == .false_) break :blk .false_;
            break :blk if (l == .unknown or r == .unknown) .unknown else .true_;
        },
        .or_ => |o| blk: {
            const l = evalPredicate(o.left, ctx);
            if (l == .true_) break :blk .true_;
            const r = evalPredicate(o.right, ctx);
            if (r == .true_) break :blk .true_;
            break :blk if (l == .unknown or r == .unknown) .unknown else .false_;
        },
    };
}

/// A row condition. UNKNOWN unless the session function has a non-empty
/// value and the row property is a string; only then does `=` or `<>`
/// compare them. With no row (a statement-level decision) it is UNKNOWN.
fn evalRowCondition(property: []const u8, func: SessionFn, op: CmpOp, ctx: PolicyEvalContext) Truth {
    const session_value = func.value(ctx) orelse return .unknown;
    if (session_value.len == 0) return .unknown;
    const row = ctx.row orelse return .unknown;
    const row_value = switch (row.get(property)) {
        .string => |v| v,
        .missing, .null_, .other => return .unknown,
    };
    const equal = std.mem.eql(u8, row_value, session_value);
    return truth(switch (op) {
        .eq => equal,
        .ne => !equal,
    });
}

// ---------------------------------------------------------------------------
// Parser (private)
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-SONNY-3191-POLICY-EXPR-BOUNDS; FEATURE="GPS Expression Compilation"; ASPECT=NestingAndLinkBounds; STATUS=TESTED; TEST=tests/test_sonny3191_round13_items.zig; OWNER=security; UPDATED=2026-09-27
/// SONNY-3191: the deepest parenthesis nesting and the most AND/OR links a
/// policy expression may have. The parser recursed once per parenthesis with
/// no limit, and `evalPredicate` recurses once per AND/OR link on every
/// decision the policy takes part in: an Admin could write a policy that
/// overflowed the stack of every request it applies to. Past either bound
/// the expression is refused (`InvalidExpression`).
const max_policy_paren_depth: u16 = 64;
const max_policy_links: u32 = 1024;

const ExprParser = struct {
    src: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    /// SONNY-3191: parentheses open, and AND/OR links so far.
    depth: u16 = 0,
    links: u32 = 0,
    reads_row: bool = false,
    reads_attributes: bool = false,

    fn countLink(self: *ExprParser) error{InvalidExpression}!void {
        self.links += 1;
        if (self.links > max_policy_links) return error.InvalidExpression;
    }

    // --- entry: OR (lowest precedence) ---

    fn parseOr(self: *ExprParser) anyerror!*const Predicate {
        var left = try self.parseAnd();
        while (true) {
            self.skipWs();
            if (!self.consumeKeyword("OR")) break;
            try self.countLink();
            const right = try self.parseAnd();
            const node = try self.allocator.create(Predicate);
            node.* = .{ .or_ = .{ .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    // --- AND (higher precedence than OR) ---

    fn parseAnd(self: *ExprParser) anyerror!*const Predicate {
        var left = try self.parseAtom();
        while (true) {
            self.skipWs();
            if (!self.consumeKeyword("AND")) break;
            try self.countLink();
            const right = try self.parseAtom();
            const node = try self.allocator.create(Predicate);
            node.* = .{ .and_ = .{ .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    // --- atoms ---

    fn parseAtom(self: *ExprParser) anyerror!*const Predicate {
        self.skipWs();
        if (self.pos >= self.src.len) return error.InvalidExpression;

        // Parenthesised sub-expression.
        if (self.src[self.pos] == '(') {
            self.pos += 1;
            // SONNY-3191: at most `max_policy_paren_depth` deep.
            self.depth += 1;
            defer self.depth -= 1;
            if (self.depth > max_policy_paren_depth) return error.InvalidExpression;
            const inner = try self.parseOr();
            self.skipWs();
            if (self.pos >= self.src.len or self.src[self.pos] != ')') {
                return error.InvalidExpression;
            }
            self.pos += 1;
            return inner;
        }

        // "true"
        if (self.consumeKeyword("true")) {
            const node = try self.allocator.create(Predicate);
            node.* = .literal_true;
            return node;
        }

        // "<session_fn> = '<lit>'" or "<session_fn> (= | <>) <row_prop>"
        if (self.parseSessionFn()) |func| {
            const node = try self.allocator.create(Predicate);
            self.skipWs();
            const op = try self.parseCmpOp();
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == '\'') {
                // Session function against a literal: `=` only.
                if (op != .eq) return error.InvalidExpression;
                const lit = try self.parseQuotedLiteral();
                node.* = switch (func) {
                    .current_user => .{ .eq_current_user = lit },
                    .current_tenant => .{ .eq_current_tenant = lit },
                    .current_graph => .{ .eq_current_graph = lit },
                };
                return node;
            }
            const property = try self.parseRowProperty();
            self.reads_row = true;
            node.* = .{ .row_vs_session = .{ .property = property, .func = func, .op = op } };
            return node;
        }

        // "resource.label = '<lit>'"
        if (self.consumeExact("resource.label")) {
            const lit = try self.parseEqLiteral();
            const node = try self.allocator.create(Predicate);
            node.* = .{ .eq_resource_label = lit };
            return node;
        }

        // CANARY: REQ=REQ-GPS-ABAC-001; FEATURE="GPS ABAC Predicates"; ASPECT=ParseAttrPredicate; STATUS=TESTED; TEST=tests/test_gps_abac_predicates.zig; OWNER=security; UPDATED=2026-05-20
        // "principal.attributes.<key> = '<lit>'"
        // The prefix "principal.attributes." is consumed first; then we scan a
        // bare identifier (alphanumeric + underscore + hyphen) as the key name.
        if (self.consumeExact("principal.attributes.")) {
            const key = try self.parseAttributeKey();
            const lit = try self.parseEqLiteral();
            const node = try self.allocator.create(Predicate);
            node.* = .{ .eq_principal_attr = .{ .key = key, .value = lit } };
            self.reads_attributes = true;
            return node;
        }

        // "<row_prop> (= | <>) <session_fn>"
        if (isIdentStart(self.src[self.pos])) {
            const property = try self.parseRowProperty();
            self.skipWs();
            const op = try self.parseCmpOp();
            self.skipWs();
            const func = self.parseSessionFn() orelse return error.InvalidExpression;
            self.reads_row = true;
            const node = try self.allocator.create(Predicate);
            node.* = .{ .row_vs_session = .{ .property = property, .func = func, .op = op } };
            return node;
        }

        return error.InvalidExpression;
    }

    /// Consume a session function call, if one is next.
    fn parseSessionFn(self: *ExprParser) ?SessionFn {
        inline for (.{ SessionFn.current_user, SessionFn.current_tenant, SessionFn.current_graph }) |func| {
            if (self.consumeExact(func.sourceName())) return func;
        }
        return null;
    }

    /// Consume `=` or `<>`.
    fn parseCmpOp(self: *ExprParser) error{InvalidExpression}!CmpOp {
        const rest = self.src[self.pos..];
        if (std.mem.startsWith(u8, rest, "<>")) {
            self.pos += 2;
            return .ne;
        }
        if (rest.len > 0 and rest[0] == '=') {
            self.pos += 1;
            return .eq;
        }
        return error.InvalidExpression;
    }

    /// Scan a row property name: an identifier that is not followed by `.`
    /// or `(` (a variable-qualified `n.owner` or an unknown function call is
    /// not a row property). Returns a copy owned by the arena.
    fn parseRowProperty(self: *ExprParser) ![]const u8 {
        const start = self.pos;
        if (self.pos >= self.src.len or !isIdentStart(self.src[self.pos])) return error.InvalidExpression;
        while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_')) {
            self.pos += 1;
        }
        const name = self.src[start..self.pos];
        if (self.pos < self.src.len and (self.src[self.pos] == '.' or self.src[self.pos] == '(')) return error.InvalidExpression;
        // The connectives and the literal `true` are not property names.
        for ([_][]const u8{ "AND", "OR", "true" }) |kw| {
            if (std.ascii.eqlIgnoreCase(name, kw)) return error.InvalidExpression;
        }
        return self.allocator.dupe(u8, name);
    }

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    /// Scan a bare attribute key: one or more alphanumeric, underscore, or
    /// hyphen characters.  Returns a copy owned by the arena.
    fn parseAttributeKey(self: *ExprParser) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const ch = self.src[self.pos];
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') {
                self.pos += 1;
            } else {
                break;
            }
        }
        if (self.pos == start) return error.InvalidExpression; // empty key
        return self.allocator.dupe(u8, self.src[start..self.pos]);
    }

    // --- helpers ---

    fn skipWs(self: *ExprParser) void {
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\r', '\n' => self.pos += 1,
                else => break,
            }
        }
    }

    /// Try to consume `kw` (case-insensitive) at the current position.
    /// Requires that the character after the keyword is not an identifier
    /// character (so "AND" does not match "ANDROID").  Returns true on match.
    fn consumeKeyword(self: *ExprParser, kw: []const u8) bool {
        const rest = self.src[self.pos..];
        if (rest.len < kw.len) return false;
        if (!std.ascii.eqlIgnoreCase(rest[0..kw.len], kw)) return false;
        // Check boundary: must not be followed by an alphanumeric or '_'.
        if (rest.len > kw.len) {
            const next = rest[kw.len];
            if (std.ascii.isAlphanumeric(next) or next == '_') return false;
        }
        self.pos += kw.len;
        return true;
    }

    /// Consume an exact byte-identical prefix (used for builtins like
    /// "current_user()" where the trailing "()" already acts as a delimiter).
    fn consumeExact(self: *ExprParser, prefix: []const u8) bool {
        const rest = self.src[self.pos..];
        if (rest.len < prefix.len) return false;
        if (!std.mem.eql(u8, rest[0..prefix.len], prefix)) return false;
        self.pos += prefix.len;
        return true;
    }

    /// Expect " = '<literal>'" and return a copy of the literal string.
    fn parseEqLiteral(self: *ExprParser) ![]const u8 {
        self.skipWs();
        if (self.pos >= self.src.len or self.src[self.pos] != '=') {
            return error.InvalidExpression;
        }
        self.pos += 1; // consume '='
        self.skipWs();
        return self.parseQuotedLiteral();
    }

    /// Expect "'<literal>'" and return a copy of the literal string.
    fn parseQuotedLiteral(self: *ExprParser) ![]const u8 {
        if (self.pos >= self.src.len or self.src[self.pos] != '\'') {
            return error.InvalidExpression;
        }
        self.pos += 1; // consume opening quote
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '\'') : (self.pos += 1) {}
        if (self.pos >= self.src.len) return error.InvalidExpression; // unterminated
        const lit = self.src[start..self.pos];
        self.pos += 1; // consume closing quote
        // Duplicate the literal into the arena so it survives the source string.
        return self.allocator.dupe(u8, lit);
    }
};
