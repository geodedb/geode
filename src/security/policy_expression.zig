// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=PolicyExpressionModule; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20
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
//
//   string_lit ::= "'" [^']* "'"
//
// AND binds tighter than OR (standard SQL precedence).
// Comparisons are case-sensitive.
//
// The RLS VM (`rls_core.zig`) is NOT used here because its `compileExpression`
// is a private method on an internal struct type and operates over an
// incompatible bytecode format (row-field loads, username builtins).  A
// hand-rolled IR is more correct and smaller for this 4-builtin subset.

const std = @import("std");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// Execution context supplied by the GPS decision engine when evaluating a
/// compiled expression.  All fields are optional; a null means "unknown" and
/// an equality check against it fails rather than erroring.
pub const PolicyEvalContext = struct {
    current_user: ?[]const u8,
    current_tenant: ?[]const u8,
    current_graph: ?[]const u8,
    resource_label: ?[]const u8,
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
    and_: struct { left: *const Predicate, right: *const Predicate },
    or_: struct { left: *const Predicate, right: *const Predicate },
};

/// A compiled expression.  The `arena` owns all IR allocations including
/// Predicate nodes and string slices for literal values.  Call `deinit` when
/// no longer needed.
pub const CompiledExpression = struct {
    arena: std.heap.ArenaAllocator,
    root: *const Predicate,

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
    return CompiledExpression{ .arena = arena, .root = root };
}

// CANARY: REQ=REQ-GPS-EXPR-001; FEATURE="GPS Expression Compilation"; ASPECT=Evaluate; STATUS=TESTED; TEST=tests/test_gps_policy_expression.zig; OWNER=security; UPDATED=2026-05-20

/// Evaluate a compiled expression against the given context.
/// Always returns a definite boolean (fail-closed: unknown values evaluate
/// to false for equality predicates).
pub fn evaluate(expr: *const CompiledExpression, ctx: PolicyEvalContext) bool {
    return evalPredicate(expr.root, ctx);
}

// ---------------------------------------------------------------------------
// Evaluator (private)
// ---------------------------------------------------------------------------

fn evalPredicate(p: *const Predicate, ctx: PolicyEvalContext) bool {
    return switch (p.*) {
        .literal_true => true,
        .eq_current_user => |v| ctx.current_user != null and std.mem.eql(u8, ctx.current_user.?, v),
        .eq_current_tenant => |v| ctx.current_tenant != null and std.mem.eql(u8, ctx.current_tenant.?, v),
        .eq_current_graph => |v| ctx.current_graph != null and std.mem.eql(u8, ctx.current_graph.?, v),
        .eq_resource_label => |v| ctx.resource_label != null and std.mem.eql(u8, ctx.resource_label.?, v),
        .and_ => |a| evalPredicate(a.left, ctx) and evalPredicate(a.right, ctx),
        .or_ => |o| evalPredicate(o.left, ctx) or evalPredicate(o.right, ctx),
    };
}

// ---------------------------------------------------------------------------
// Parser (private)
// ---------------------------------------------------------------------------

const ExprParser = struct {
    src: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    // --- entry: OR (lowest precedence) ---

    fn parseOr(self: *ExprParser) anyerror!*const Predicate {
        var left = try self.parseAnd();
        while (true) {
            self.skipWs();
            if (!self.consumeKeyword("OR")) break;
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

        // "current_user() = '<lit>'"
        if (self.consumeExact("current_user()")) {
            const lit = try self.parseEqLiteral();
            const node = try self.allocator.create(Predicate);
            node.* = .{ .eq_current_user = lit };
            return node;
        }

        // "current_tenant() = '<lit>'"
        if (self.consumeExact("current_tenant()")) {
            const lit = try self.parseEqLiteral();
            const node = try self.allocator.create(Predicate);
            node.* = .{ .eq_current_tenant = lit };
            return node;
        }

        // "current_graph() = '<lit>'"
        if (self.consumeExact("current_graph()")) {
            const lit = try self.parseEqLiteral();
            const node = try self.allocator.create(Predicate);
            node.* = .{ .eq_current_graph = lit };
            return node;
        }

        // "resource.label = '<lit>'"
        if (self.consumeExact("resource.label")) {
            const lit = try self.parseEqLiteral();
            const node = try self.allocator.create(Predicate);
            node.* = .{ .eq_resource_label = lit };
            return node;
        }

        return error.InvalidExpression;
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
