// CANARY: LSP_SEMANTIC_ANALYSIS
// Semantic analysis for GQL/Geode LSP
// Provides scope tracking and undefined identifier detection

const std = @import("std");
const Allocator = std.mem.Allocator;
const geode = @import("geode");
const ast = geode.ast;

pub const SemanticError = struct {
    message: []const u8,
    line: u32,
    column: u32,
};

pub const Scope = struct {
    allocator: Allocator,
    bindings: std.StringHashMap(BindingInfo),
    parent: ?*Scope = null,
    // Owned strings that need to be freed
    owned_keys: std.ArrayList([]const u8),

    pub const BindingInfo = struct {
        name: []const u8,
        kind: BindingKind,
    };

    pub const BindingKind = enum {
        node,
        relationship,
        path,
        variable, // FROM WITH/RETURN alias
        parameter, // $param
        comprehension_var, // List comprehension variable
    };

    pub fn init(allocator: Allocator) Scope {
        return .{
            .allocator = allocator,
            .bindings = std.StringHashMap(BindingInfo).init(allocator),
            .owned_keys = std.ArrayList([]const u8).initCapacity(allocator, 0) catch @panic("OOM"),
        };
    }

    pub fn deinit(self: *Scope) void {
        // Free owned keys
        for (self.owned_keys.items) |key| {
            self.allocator.free(key);
        }
        self.owned_keys.deinit(self.allocator);
        self.bindings.deinit();
    }

    pub fn define(self: *Scope, name: []const u8, kind: BindingKind) !void {
        // Store in canonical (uppercase) form for case-insensitive lookup
        const canonical = try self.canonicalize(name);
        try self.bindings.put(canonical, .{ .name = name, .kind = kind });
    }

    pub fn defineCanonical(self: *Scope, canonical: []const u8, kind: BindingKind) !void {
        try self.bindings.put(canonical, .{ .name = canonical, .kind = kind });
    }

    fn canonicalize(self: *Scope, name: []const u8) ![]const u8 {
        const upper = try self.allocator.alloc(u8, name.len);
        for (name, 0..) |c, i| {
            upper[i] = std.ascii.toUpper(c);
        }
        try self.owned_keys.append(self.allocator, upper);
        return upper;
    }

    pub fn lookup(self: *const Scope, name: []const u8) ?BindingInfo {
        // Create uppercase version for lookup
        var upper_buf: [256]u8 = undefined;
        const len = @min(name.len, 256);
        for (name[0..len], 0..) |c, i| {
            upper_buf[i] = std.ascii.toUpper(c);
        }
        const canonical = upper_buf[0..len];

        if (self.bindings.get(canonical)) |info| {
            return info;
        }
        if (self.parent) |p| {
            return p.lookup(name);
        }
        return null;
    }

    pub fn contains(self: *const Scope, name: []const u8) bool {
        return self.lookup(name) != null;
    }

    pub fn clear(self: *Scope) void {
        self.bindings.clearRetainingCapacity();
    }
};

// Simple type system for basic type checking
pub const InferredType = enum {
    unknown, // Can't determine type (variables, property access, function calls)
    boolean,
    number, // Integer or float
    string,
    list,
    map,
    null_type,
    date,
    datetime,
    time,
};

/// Calculate Levenshtein edit distance between two strings.
/// Returns the minimum number of single-character edits needed to change one string into the other.
fn levenshteinDistance(s1: []const u8, s2: []const u8) usize {
    if (s1.len == 0) return s2.len;
    if (s2.len == 0) return s1.len;

    // Use a simple O(n*m) algorithm with a single row optimization
    const n = s2.len;

    // Use stack buffer for small strings to avoid allocation
    var stack_buf: [256]usize = undefined;
    var prev_row: []usize = undefined;
    var curr_row: []usize = undefined;

    if (n + 1 <= 128) {
        prev_row = stack_buf[0 .. n + 1];
        curr_row = stack_buf[128 .. 128 + n + 1];
    } else {
        // For very long strings, just return a large distance to skip comparison
        return 100;
    }

    // Initialize first row
    for (prev_row, 0..) |*cell, j| {
        cell.* = j;
    }

    // Fill the matrix row by row
    for (s1, 0..) |c1, i| {
        curr_row[0] = i + 1;

        for (s2, 0..) |c2, j| {
            const cost: usize = if (std.ascii.toLower(c1) == std.ascii.toLower(c2)) 0 else 1;
            curr_row[j + 1] = @min(@min(
                prev_row[j + 1] + 1, // deletion
                curr_row[j] + 1, // insertion
            ), prev_row[j] + cost); // substitution
        }

        // Swap rows
        const tmp = prev_row;
        prev_row = curr_row;
        curr_row = tmp;
    }

    return prev_row[n];
}

/// Infer the type of an expression based on its structure.
/// Returns .unknown for expressions whose type can't be determined statically
/// (like variables, property access, and function calls).
fn inferType(expr: ast.Expr) InferredType {
    return switch (expr) {
        // Literals with known types
        .Bool => .boolean,
        .Int, .Decimal, .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit => .number,
        .String, .CharLit, .VarcharLit, .TextLit => .string,
        .List, .ArrayLit => .list,
        .Map => .map,
        .Null => .null_type,
        .Date => .date,
        .DateTime, .LocalDateTime => .datetime,
        .Time => .time,

        // Expressions that produce boolean
        .IsNull, .IsUnknown, .HasLabel => .boolean,
        .StartsWith, .EndsWith, .Contains => .boolean,
        .In, .NotIn, .InListExpr, .NotInListExpr => .boolean,
        .InSubquery, .NotInSubquery => .boolean,
        .Exists => .boolean,

        // Binary operators - some produce booleans
        .Binary => |b| switch (b.op) {
            .And, .Or, .Xor => .boolean,
            .Eq, .Ne, .Lt, .Le, .Gt, .Ge => .boolean,
            .RegexMatch, .RegexNotMatch => .boolean,
            .Add, .Sub, .Mul, .Div, .Mod, .Power => .number,
            .Concat => .string,
        },

        // Unary NOT produces boolean
        .Unary => |u| switch (u.op) {
            .Not => .boolean,
            .Neg, .Pos => .number,
        },

        // List comprehension produces a list
        .ListComprehension => .list,

        // Pattern comprehension produces a list
        .PatternComp => .list,

        // Pattern count produces a number
        .PatternCount => .number,

        // Case expressions - unknown type (depends on branches)
        .Case => .unknown,

        // These can't be typed statically
        .Ident, .PropertyAccess, .Member, .Call, .Index, .Slice => .unknown,
        .MapProjection, .ShortestPath, .Param => .unknown,
        .ByteaLit, .JsonLit, .JsonbLit, .XmlLit, .UrlLit, .DomainLit => .unknown,
        .UuidLit, .EnumLit, .BitLit, .VarBitLit => .unknown,
    };
}

pub const SemanticAnalyzer = struct {
    allocator: Allocator,
    errors: std.ArrayList(SemanticError),
    scope: Scope,
    // Track labels used in patterns for typo detection
    labels: std.StringHashMap(u32), // label -> count

    pub fn init(allocator: Allocator) SemanticAnalyzer {
        return .{
            .allocator = allocator,
            .errors = std.ArrayList(SemanticError).initCapacity(allocator, 0) catch @panic("OOM"),
            .scope = Scope.init(allocator),
            .labels = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *SemanticAnalyzer) void {
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit(self.allocator);
        self.scope.deinit();
        self.labels.deinit();
    }

    pub fn analyze(self: *SemanticAnalyzer, program: ast.Program) ![]SemanticError {
        for (program.statements) |stmt| {
            try self.analyzeStatement(stmt);
        }

        // Check for potential label typos after analyzing all statements
        try self.checkLabelTypos();

        return self.errors.items;
    }

    /// Check for potential label typos by finding labels that appear only once
    /// and are very similar to other labels that appear multiple times.
    fn checkLabelTypos(self: *SemanticAnalyzer) !void {
        var it = self.labels.iterator();
        while (it.next()) |entry| {
            const label = entry.key_ptr.*;
            const count = entry.value_ptr.*;

            // Labels used only once might be typos
            if (count == 1) {
                // Check if there's a similar label with more uses
                var it2 = self.labels.iterator();
                while (it2.next()) |entry2| {
                    const other_label = entry2.key_ptr.*;
                    const other_count = entry2.value_ptr.*;

                    // Skip self-comparison
                    if (std.mem.eql(u8, label, other_label)) continue;

                    // Check if the other label is more commonly used
                    if (other_count > 1) {
                        // Skip if the labels only differ by trailing numbers (e.g., Person1 vs Person)
                        // This is a common pattern for intentionally distinct labels
                        if (isNumericSuffixVariant(label, other_label)) continue;

                        // Calculate edit distance
                        const distance = levenshteinDistance(label, other_label);

                        // If very similar (edit distance 1-2), warn about potential typo
                        if (distance > 0 and distance <= 2 and label.len >= 4) {
                            try self.addError("Label '{s}' is similar to '{s}' - possible typo?", .{ label, other_label }, 0, 0);
                            break; // Only report one potential match per label
                        }
                    }
                }
            }
        }
    }

    /// Check if two labels only differ by trailing numeric suffixes.
    /// Returns true for pairs like: (Person1, Person), (User2, User1), (Node10, Node)
    fn isNumericSuffixVariant(label1: []const u8, label2: []const u8) bool {
        const base1 = stripTrailingDigits(label1);
        const base2 = stripTrailingDigits(label2);

        // If after stripping digits they're the same (case-insensitive), they're variants
        if (base1.len == 0 or base2.len == 0) return false;
        if (base1.len != base2.len) return false;

        for (base1, base2) |c1, c2| {
            if (std.ascii.toLower(c1) != std.ascii.toLower(c2)) return false;
        }
        return true;
    }

    fn stripTrailingDigits(s: []const u8) []const u8 {
        var end = s.len;
        while (end > 0 and std.ascii.isDigit(s[end - 1])) {
            end -= 1;
        }
        return s[0..end];
    }

    /// Record a label usage for typo detection
    fn recordLabel(self: *SemanticAnalyzer, label: []const u8) void {
        if (self.labels.get(label)) |count| {
            self.labels.put(label, count + 1) catch {};
        } else {
            self.labels.put(label, 1) catch {};
        }
    }

    fn analyzeStatement(self: *SemanticAnalyzer, stmt: ast.Statement) !void {
        switch (stmt) {
            .Query => |q| try self.analyzeQuery(q),
            .Union => |u| {
                try self.analyzeQuery(u.first);
                for (u.tails) |tail| {
                    // Each union branch gets a fresh scope
                    self.scope.clear();
                    try self.analyzeQuery(tail.query);
                }
            },
            .Intersect => |i| {
                try self.analyzeQuery(i.left);
                self.scope.clear();
                try self.analyzeQuery(i.right);
            },
            .Except => |e| {
                try self.analyzeQuery(e.left);
                self.scope.clear();
                try self.analyzeQuery(e.right);
            },
            .Create => |c| try self.analyzeCreate(c),
            .Insert => |i| try self.analyzeInsert(i),
            .Merge => |m| try self.analyzeMerge(m),
            .Delete => |d| try self.analyzeDelete(d),
            .Call => |c| try self.analyzeCall(c),
            .InsertValue => |iv| try self.analyzeExpr(iv.expr),
            .For => |f| {
                try self.analyzeExpr(f.collection);
                try self.scope.define(f.variable, .variable);
                if (f.ordinality_var) |ov| try self.scope.define(ov, .variable);
                if (f.offset_var) |ov| try self.scope.define(ov, .variable);
                for (f.return_clause.items) |item| {
                    try self.analyzeExpr(item.expr);
                }
            },
            .Values => |v| {
                for (v.rows) |row| {
                    for (row) |expr| {
                        try self.analyzeExpr(expr);
                    }
                }
            },
            // Statements that don't involve expressions we need to check
            .SessionSet, .SessionReset, .SessionClose, .UseGraph => {},
            .StartTransaction, .Commit, .Rollback, .ScanValues => {},
            .CreateIndex, .DropIndex, .CreateConstraint, .DropConstraint => {},
            .Show, .Backup, .Restore => {},
            .CreateSchema, .DropSchema, .CreateGraph, .DropGraph => {},
            .CreateGraphType, .DropGraphType, .Explain, .Profile => {},
        }
    }

    fn analyzeQuery(self: *SemanticAnalyzer, query: ast.Query) !void {
        // 1. Collect bindings from LET clauses (pre-MATCH)
        for (query.let_bindings) |binding| {
            try self.analyzeExpr(binding.value);
            try self.scope.define(binding.variable, .variable);
        }

        // 2. Collect bindings from MATCH pattern
        try self.collectPatternBindings(query.match);

        // 3. Collect inline LET bindings (post-MATCH)
        for (query.inline_let_bindings) |binding| {
            try self.analyzeExpr(binding.value);
            try self.scope.define(binding.variable, .variable);
        }

        // 4. Collect bindings from CREATE pattern if present
        if (query.create_pattern) |cp| {
            try self.collectPatternBindings(cp);
        }

        // 5. Analyze WHERE clause (uses bindings from MATCH)
        if (query.where_clause) |where| {
            try self.analyzeExpr(where);
        }

        // 6. Analyze FILTER clause if present
        if (query.filter_clause) |filter| {
            try self.analyzeExpr(filter);
        }

        // 7. Analyze SET clauses
        for (query.set_clauses) |set_clause| {
            try self.analyzeSetClause(set_clause);
        }

        // 8. Analyze REMOVE clauses
        for (query.remove_clauses) |remove_clause| {
            try self.analyzeRemoveClause(remove_clause);
        }

        // 8b. Analyze DELETE items (for MATCH ... DELETE n queries)
        for (query.delete_items) |item| {
            switch (item) {
                .Variable => |v| {
                    if (!self.scope.contains(v)) {
                        try self.addError("Undefined variable: {s}", .{v}, 0, 0);
                    }
                },
                .Node => |n| {
                    if (!self.scope.contains(n)) {
                        try self.addError("Undefined variable: {s}", .{n}, 0, 0);
                    }
                },
                .Relationship => |r| {
                    if (!self.scope.contains(r)) {
                        try self.addError("Undefined variable: {s}", .{r}, 0, 0);
                    }
                },
            }
        }

        // 9. Analyze WITH clause - this creates new scope for subsequent clauses
        if (query.with_clause) |with| {
            // First check expressions reference valid identifiers
            for (with.items) |item| {
                try self.analyzeExpr(item.expr);
            }

            // Analyze WITH ORDER BY if present
            if (with.order_by) |ob| {
                for (ob.keys) |key| {
                    try self.analyzeExpr(key.expr);
                }
            }

            // Now create new scope with WITH bindings for RETURN clause
            // Clear old bindings and add new ones from WITH
            self.scope.clear();

            for (with.items) |item| {
                const name = item.alias orelse self.exprToName(item.expr);
                if (name) |n| {
                    try self.scope.define(n, .variable);
                }
            }
        }

        // 10. Analyze GROUP BY if present
        if (query.group_by) |gb| {
            for (gb.keys) |key| {
                try self.analyzeExpr(key);
            }
        }

        // 11. Analyze HAVING if present
        if (query.having) |having| {
            try self.analyzeExpr(having);
        }

        // 12. Analyze RETURN clause
        for (query.ret.items) |item| {
            try self.analyzeExpr(item.expr);
        }

        // 13. Add RETURN aliases to scope for chained queries
        for (query.ret.items) |item| {
            if (item.alias) |alias| {
                try self.scope.define(alias, .variable);
            } else {
                // Use implicit name from expression
                const name = self.exprToName(item.expr);
                if (name) |n| {
                    try self.scope.define(n, .variable);
                }
            }
        }

        // 14. Analyze ORDER BY if present
        if (query.order_by) |ob| {
            for (ob.keys) |key| {
                try self.analyzeExpr(key.expr);
            }
        }

        // 15. Analyze chained query if present
        if (query.next_query) |next| {
            try self.analyzeQuery(next.*);
        }
    }

    fn analyzeCreate(self: *SemanticAnalyzer, create: ast.CreateStatement) !void {
        // Analyze pattern property expressions that may reference existing bindings
        try self.analyzePatternExpressions(create.pattern);
        // Then collect the new bindings
        try self.collectPatternBindings(create.pattern);
        if (create.return_clause) |ret| {
            for (ret.items) |item| {
                try self.analyzeExpr(item.expr);
            }
        }
    }

    fn analyzeInsert(self: *SemanticAnalyzer, insert: ast.InsertStatement) !void {
        try self.analyzePatternExpressions(insert.pattern);
        try self.collectPatternBindings(insert.pattern);
        if (insert.return_clause) |ret| {
            for (ret.items) |item| {
                try self.analyzeExpr(item.expr);
            }
        }
    }

    fn analyzeMerge(self: *SemanticAnalyzer, merge: ast.MergeStatement) !void {
        try self.analyzePatternExpressions(merge.pattern);
        try self.collectPatternBindings(merge.pattern);

        // Analyze ON CREATE SET clauses
        for (merge.on_create) |set_clause| {
            try self.analyzeSetClause(set_clause);
        }

        // Analyze ON MATCH SET clauses
        for (merge.on_match) |set_clause| {
            try self.analyzeSetClause(set_clause);
        }

        if (merge.return_clause) |ret| {
            for (ret.items) |item| {
                try self.analyzeExpr(item.expr);
            }
        }
    }

    fn analyzeDelete(self: *SemanticAnalyzer, delete: ast.DeleteStatement) !void {
        // Collect bindings from MATCH if present
        if (delete.match_clause) |match| {
            try self.collectPatternBindings(match);
        }

        // Analyze WHERE clause
        if (delete.where_clause) |where| {
            try self.analyzeExpr(where);
        }

        // Analyze delete items
        for (delete.items) |item| {
            switch (item) {
                .Variable => |v| {
                    if (!self.scope.contains(v)) {
                        try self.addError("Undefined variable: {s}", .{v}, 0, 0);
                    }
                },
                .Node => |n| {
                    if (!self.scope.contains(n)) {
                        try self.addError("Undefined variable: {s}", .{n}, 0, 0);
                    }
                },
                .Relationship => |r| {
                    if (!self.scope.contains(r)) {
                        try self.addError("Undefined variable: {s}", .{r}, 0, 0);
                    }
                },
            }
        }

        if (delete.return_clause) |ret| {
            for (ret.items) |item| {
                try self.analyzeExpr(item.expr);
            }
        }
    }

    fn analyzeCall(self: *SemanticAnalyzer, call: ast.CallStatement) !void {
        switch (call) {
            .Procedure => |proc| {
                // Analyze procedure call expression
                try self.analyzeExpr(proc.procedure);

                // YIELD items create bindings
                if (proc.yield_items) |yield| {
                    for (yield) |item| {
                        const name = item.alias orelse self.exprToName(item.expr);
                        if (name) |n| {
                            try self.scope.define(n, .variable);
                        }
                    }
                }

                // Analyze ORDER BY
                if (proc.order_by) |ob| {
                    for (ob.keys) |key| {
                        try self.analyzeExpr(key.expr);
                    }
                }

                // Analyze RETURN clause
                if (proc.return_clause) |ret| {
                    for (ret.items) |item| {
                        try self.analyzeExpr(item.expr);
                    }
                }
            },
            .Subquery => {
                // Subquery analysis would require recursive statement handling
                // which is complex due to Zig's error set inference. Skip for now.
            },
        }
    }

    fn analyzeSetClause(self: *SemanticAnalyzer, clause: ast.SetClause) !void {
        switch (clause) {
            .Property => |p| {
                if (!self.scope.contains(p.target.object)) {
                    try self.addError("Undefined variable: {s}", .{p.target.object}, 0, 0);
                }
                try self.analyzeExpr(p.value);
            },
            .Labels => |l| {
                if (!self.scope.contains(l.node)) {
                    try self.addError("Undefined variable: {s}", .{l.node}, 0, 0);
                }
            },
            .AllProperties => |ap| {
                if (!self.scope.contains(ap.node)) {
                    try self.addError("Undefined variable: {s}", .{ap.node}, 0, 0);
                }
                try self.analyzeExpr(ap.properties);
            },
        }
    }

    fn analyzeRemoveClause(self: *SemanticAnalyzer, clause: ast.RemoveClause) !void {
        switch (clause) {
            .Property => |p| {
                if (!self.scope.contains(p.object)) {
                    try self.addError("Undefined variable: {s}", .{p.object}, 0, 0);
                }
            },
            .Labels => |l| {
                if (!self.scope.contains(l.node)) {
                    try self.addError("Undefined variable: {s}", .{l.node}, 0, 0);
                }
            },
        }
    }

    fn collectPatternBindings(self: *SemanticAnalyzer, pattern: ast.GraphPattern) !void {
        for (pattern.chains) |chain| {
            // Collect from chain name if present (path variable)
            if (chain.name) |name| {
                try self.scope.define(name, .path);
            }

            // Collect from head node if present
            if (chain.head) |head| {
                if (head.name) |name| {
                    try self.scope.define(name, .node);
                }
                // Record labels for typo detection
                for (head.labels) |label| {
                    self.recordLabel(label);
                }
            }

            // Collect from hops
            for (chain.hops) |hop| {
                if (hop.left.name) |name| {
                    try self.scope.define(name, .node);
                }
                // Record labels from left node
                for (hop.left.labels) |label| {
                    self.recordLabel(label);
                }

                if (hop.rel.name) |name| {
                    try self.scope.define(name, .relationship);
                }
                // Record relationship types for typo detection
                for (hop.rel.types) |rel_type| {
                    self.recordLabel(rel_type);
                }

                if (hop.right.name) |name| {
                    try self.scope.define(name, .node);
                }
                // Record labels from right node
                for (hop.right.labels) |label| {
                    self.recordLabel(label);
                }
            }
        }
    }

    fn analyzePatternExpressions(self: *SemanticAnalyzer, pattern: ast.GraphPattern) !void {
        for (pattern.chains) |chain| {
            // Check head node properties
            if (chain.head) |head| {
                if (head.props) |props| {
                    for (props) |prop| {
                        try self.analyzeExpr(prop.value.*);
                    }
                }
            }

            // Check hop node and relationship properties
            for (chain.hops) |hop| {
                if (hop.left.props) |props| {
                    for (props) |prop| {
                        try self.analyzeExpr(prop.value.*);
                    }
                }
                if (hop.rel.props) |props| {
                    for (props) |prop| {
                        try self.analyzeExpr(prop.value.*);
                    }
                }
                if (hop.right.props) |props| {
                    for (props) |prop| {
                        try self.analyzeExpr(prop.value.*);
                    }
                }
            }
        }
    }

    fn analyzeExpr(self: *SemanticAnalyzer, expr: ast.Expr) !void {
        switch (expr) {
            .Ident => |ident| {
                // Skip "*" - it's a special syntax for count(*)
                if (std.mem.eql(u8, ident.orig, "*")) return;

                // Check if identifier is defined (use canonical form)
                if (!self.scope.contains(ident.cnf) and !self.scope.contains(ident.orig)) {
                    try self.addError("Undefined variable: {s}", .{ident.orig}, 0, 0);
                }
            },
            .PropertyAccess => |pa| {
                // Check that the object is defined
                if (!self.scope.contains(pa.object)) {
                    try self.addError("Undefined variable: {s}", .{pa.object}, 0, 0);
                }
            },
            .Member => |m| {
                try self.analyzeExpr(m.target.*);
            },
            .Call => |c| {
                // Don't check callee name - it's a function
                // But analyze the callee if it's a member access (e.g., algo.bfs.stream)
                switch (c.callee.*) {
                    .Member => |m| try self.analyzeExpr(m.target.*),
                    else => {},
                }
                for (c.args) |arg| {
                    try self.analyzeExpr(arg.*);
                }
            },
            .Binary => |b| {
                try self.analyzeExpr(b.left.*);
                try self.analyzeExpr(b.right.*);

                // Type checking for binary operators
                const left_type = inferType(b.left.*);
                const right_type = inferType(b.right.*);

                switch (b.op) {
                    // Boolean operators require boolean operands
                    // Note: null_type is allowed (NULL propagates through boolean ops)
                    .And, .Or, .Xor => {
                        if (left_type != .unknown and left_type != .boolean and left_type != .null_type) {
                            try self.addError("Boolean operator requires boolean operand, got {s}", .{@tagName(left_type)}, 0, 0);
                        }
                        if (right_type != .unknown and right_type != .boolean and right_type != .null_type) {
                            try self.addError("Boolean operator requires boolean operand, got {s}", .{@tagName(right_type)}, 0, 0);
                        }
                    },
                    // Arithmetic operators require numeric operands
                    // Note: null_type is allowed (NULL propagates through arithmetic ops)
                    .Add, .Sub, .Mul, .Div, .Mod, .Power => {
                        // String concatenation with + is allowed
                        if (b.op == .Add and (left_type == .string or right_type == .string)) {
                            // Allow string + string
                            if (left_type == .string and right_type == .string) {
                                // OK
                            } else if (left_type != .unknown and left_type != .string and left_type != .null_type) {
                                try self.addError("Cannot concatenate {s} with string", .{@tagName(left_type)}, 0, 0);
                            } else if (right_type != .unknown and right_type != .string and right_type != .null_type) {
                                try self.addError("Cannot concatenate string with {s}", .{@tagName(right_type)}, 0, 0);
                            }
                        } else {
                            if (left_type != .unknown and left_type != .number and left_type != .null_type) {
                                try self.addError("Arithmetic operator requires numeric operand, got {s}", .{@tagName(left_type)}, 0, 0);
                            }
                            if (right_type != .unknown and right_type != .number and right_type != .null_type) {
                                try self.addError("Arithmetic operator requires numeric operand, got {s}", .{@tagName(right_type)}, 0, 0);
                            }
                        }
                    },
                    // Comparison operators - check for type compatibility
                    .Eq, .Ne => {
                        // Any types can be compared for equality
                    },
                    .Lt, .Le, .Gt, .Ge => {
                        // Comparison between incompatible known types
                        if (left_type != .unknown and right_type != .unknown) {
                            if (left_type == .boolean and right_type != .boolean) {
                                try self.addError("Cannot compare boolean with {s}", .{@tagName(right_type)}, 0, 0);
                            }
                        }
                    },
                    // String concatenation
                    .Concat => {
                        // Concat should work on strings
                    },
                    // Regex match operators
                    .RegexMatch, .RegexNotMatch => {
                        if (left_type != .unknown and left_type != .string) {
                            try self.addError("Regex match requires string operand, got {s}", .{@tagName(left_type)}, 0, 0);
                        }
                    },
                }
            },
            .Unary => |u| {
                try self.analyzeExpr(u.expr.*);

                // Type checking for unary operators
                // Note: null_type is allowed (NULL propagates through unary ops)
                const expr_type = inferType(u.expr.*);
                switch (u.op) {
                    .Not => {
                        if (expr_type != .unknown and expr_type != .boolean and expr_type != .null_type) {
                            try self.addError("NOT operator requires boolean operand, got {s}", .{@tagName(expr_type)}, 0, 0);
                        }
                    },
                    .Neg, .Pos => {
                        if (expr_type != .unknown and expr_type != .number and expr_type != .null_type) {
                            try self.addError("Numeric operator requires numeric operand, got {s}", .{@tagName(expr_type)}, 0, 0);
                        }
                    },
                }
            },
            .In => |in| {
                try self.analyzeExpr(in.value.*);
                for (in.set) |item| {
                    try self.analyzeExpr(item.*);
                }
            },
            .NotIn => |in| {
                try self.analyzeExpr(in.value.*);
                for (in.set) |item| {
                    try self.analyzeExpr(item.*);
                }
            },
            .InListExpr => |in| {
                try self.analyzeExpr(in.value.*);
                try self.analyzeExpr(in.list_expr.*);
            },
            .NotInListExpr => |in| {
                try self.analyzeExpr(in.value.*);
                try self.analyzeExpr(in.list_expr.*);
            },
            .IsNull => |is| {
                try self.analyzeExpr(is.target.*);
            },
            .IsUnknown => |is| {
                try self.analyzeExpr(is.target.*);
            },
            .Index => |idx| {
                try self.analyzeExpr(idx.target.*);
                try self.analyzeExpr(idx.index.*);
            },
            .Slice => |s| {
                try self.analyzeExpr(s.target.*);
                if (s.start) |start| try self.analyzeExpr(start.*);
                if (s.end) |end| try self.analyzeExpr(end.*);
            },
            .List => |list| {
                for (list) |item| {
                    try self.analyzeExpr(item.*);
                }
            },
            .ArrayLit => |arr| {
                for (arr) |item| {
                    try self.analyzeExpr(item.*);
                }
            },
            .Case => |case| {
                if (case.operand) |op| try self.analyzeExpr(op.*);
                for (case.whens) |when| {
                    try self.analyzeExpr(when.when.*);
                    try self.analyzeExpr(when.then_expr.*);
                }
                if (case.else_expr) |els| try self.analyzeExpr(els.*);
            },
            .StartsWith => |pred| {
                try self.analyzeExpr(pred.value.*);
                try self.analyzeExpr(pred.prefix.*);
            },
            .EndsWith => |pred| {
                try self.analyzeExpr(pred.value.*);
                try self.analyzeExpr(pred.suffix.*);
            },
            .Contains => |pred| {
                try self.analyzeExpr(pred.value.*);
                try self.analyzeExpr(pred.needle.*);
            },
            .ListComprehension => |lc| {
                // First analyze the source (it uses outer scope)
                try self.analyzeExpr(lc.source.*);

                // Create temporary binding for the comprehension variable
                try self.scope.define(lc.variable, .comprehension_var);

                // Now analyze filter and map with the variable in scope
                if (lc.filter) |f| try self.analyzeExpr(f.*);
                if (lc.map) |m| try self.analyzeExpr(m.*);

                // Note: We don't remove the binding as it doesn't hurt to leave it
            },
            .PatternComp => |pc| {
                // Analyze the inner pattern
                try self.collectPatternBindings(pc.pattern.*);
                if (pc.where) |w| try self.analyzeExpr(w.*);
                try self.analyzeExpr(pc.map.*);
            },
            .MapProjection => |mp| {
                try self.analyzeExpr(mp.source.*);
            },
            .HasLabel => |hl| {
                if (!self.scope.contains(hl.node)) {
                    try self.addError("Undefined variable: {s}", .{hl.node}, 0, 0);
                }
            },
            .Exists => |ex| {
                // Analyze the pattern in EXISTS
                try self.collectPatternBindings(ex.pattern.*);
                if (ex.where) |w| try self.analyzeExpr(w.*);
            },
            .ShortestPath => |sp| {
                // Analyze the pattern in shortestPath
                try self.collectPatternBindings(sp.pattern.*);
            },
            .PatternCount => |pc| {
                // Analyze the pattern in COUNT
                try self.collectPatternBindings(pc.pattern.*);
                if (pc.where) |w| try self.analyzeExpr(w.*);
            },
            .Map => |props| {
                for (props) |prop| {
                    try self.analyzeExpr(prop.value.*);
                }
            },
            // Literals and simple types don't need checking
            .String, .Int, .Bool, .Null, .Decimal, .Date, .DateTime, .Time => {},
            .LocalDateTime, .SmallIntLit, .BigIntLit, .RealLit, .DoubleLit => {},
            .CharLit, .VarcharLit, .TextLit, .ByteaLit, .JsonLit, .JsonbLit => {},
            .XmlLit, .UrlLit, .DomainLit, .UuidLit, .EnumLit, .Param => {},
            .BitLit, .VarBitLit => {},
            // Subquery types - would need separate scope handling
            .InSubquery, .NotInSubquery => {},
        }
    }

    fn exprToName(self: *SemanticAnalyzer, expr: ast.Expr) ?[]const u8 {
        _ = self;
        return switch (expr) {
            .Ident => |ident| ident.orig,
            .PropertyAccess => |pa| pa.property,
            .Call => |c| blk: {
                // For function calls, use function name as implicit alias
                if (c.callee.* == .Ident) {
                    break :blk c.callee.Ident.orig;
                }
                break :blk null;
            },
            else => null,
        };
    }

    fn addError(self: *SemanticAnalyzer, comptime fmt: []const u8, args: anytype, line: u32, column: u32) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.errors.append(self.allocator, .{
            .message = message,
            .line = line,
            .column = column,
        });
    }
};

// Test the semantic analyzer
test "semantic analyzer - undefined variable" {
    const allocator = std.testing.allocator;

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();

    // Create a simple test case
    // This would need actual parsing to test properly
}

test "semantic analyzer - star identifier for count(*) should not error" {
    const allocator = std.testing.allocator;

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();

    // The "*" identifier is special syntax for count(*)
    // It should not be flagged as undefined
    const star_ident = ast.Expr{ .Ident = .{ .orig = "*", .cnf = "*" } };
    try analyzer.analyzeExpr(star_ident);

    // Should have no errors
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
}

test "semantic analyzer - undefined variable should error" {
    const allocator = std.testing.allocator;

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();

    // An undefined variable should be flagged
    const undefined_ident = ast.Expr{ .Ident = .{ .orig = "undefinedVar", .cnf = "UNDEFINEDVAR" } };
    try analyzer.analyzeExpr(undefined_ident);

    // Should have one error
    try std.testing.expectEqual(@as(usize, 1), analyzer.errors.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.errors.items[0].message, "undefinedVar") != null);
}

test "semantic analyzer - defined variable should not error" {
    const allocator = std.testing.allocator;

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();

    // Define a variable in scope
    try analyzer.scope.define("myVar", .variable);

    // Reference it - should not error
    const defined_ident = ast.Expr{ .Ident = .{ .orig = "myVar", .cnf = "MYVAR" } };
    try analyzer.analyzeExpr(defined_ident);

    // Should have no errors
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
}

test "semantic analyzer - case insensitive variable lookup" {
    const allocator = std.testing.allocator;

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();

    // Define a variable with mixed case
    try analyzer.scope.define("PersonNode", .node);

    // Reference with different case - should still work (case-insensitive)
    const ident1 = ast.Expr{ .Ident = .{ .orig = "personnode", .cnf = "PERSONNODE" } };
    try analyzer.analyzeExpr(ident1);
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);

    const ident2 = ast.Expr{ .Ident = .{ .orig = "PERSONNODE", .cnf = "PERSONNODE" } };
    try analyzer.analyzeExpr(ident2);
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
}

// Type checking tests
test "type inference - literals" {
    // Test type inference for various literal types
    try std.testing.expectEqual(InferredType.boolean, inferType(ast.Expr{ .Bool = true }));
    try std.testing.expectEqual(InferredType.number, inferType(ast.Expr{ .Int = 42 }));
    try std.testing.expectEqual(InferredType.string, inferType(ast.Expr{ .String = "hello" }));
    try std.testing.expectEqual(InferredType.null_type, inferType(ast.Expr.Null));
}

test "type checking - NOT operator requires boolean" {
    const allocator = std.testing.allocator;

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();

    // NOT with number literal - should error
    const num_expr = try allocator.create(ast.Expr);
    defer allocator.destroy(num_expr);
    num_expr.* = ast.Expr{ .Int = 42 };

    const not_num = ast.Expr{ .Unary = .{ .op = .Not, .expr = num_expr } };
    try analyzer.analyzeExpr(not_num);

    // Should have one error about NOT requiring boolean
    try std.testing.expectEqual(@as(usize, 1), analyzer.errors.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.errors.items[0].message, "NOT operator requires boolean") != null);
}

test "type checking - NOT operator with boolean is OK" {
    const allocator = std.testing.allocator;

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();

    // NOT with boolean literal - should be OK
    const bool_expr = try allocator.create(ast.Expr);
    defer allocator.destroy(bool_expr);
    bool_expr.* = ast.Expr{ .Bool = true };

    const not_bool = ast.Expr{ .Unary = .{ .op = .Not, .expr = bool_expr } };
    try analyzer.analyzeExpr(not_bool);

    // Should have no errors
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
}

test "type checking - AND operator requires boolean operands" {
    const allocator = std.testing.allocator;

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();

    // AND with string literals - should error for both operands
    const str1 = try allocator.create(ast.Expr);
    defer allocator.destroy(str1);
    str1.* = ast.Expr{ .String = "hello" };

    const str2 = try allocator.create(ast.Expr);
    defer allocator.destroy(str2);
    str2.* = ast.Expr{ .String = "world" };

    const and_expr = ast.Expr{ .Binary = .{ .op = .And, .left = str1, .right = str2 } };
    try analyzer.analyzeExpr(and_expr);

    // Should have two errors (one for each operand)
    try std.testing.expectEqual(@as(usize, 2), analyzer.errors.items.len);
}

test "type checking - arithmetic with string should error" {
    const allocator = std.testing.allocator;

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();

    // Subtraction with string - should error
    const str_expr = try allocator.create(ast.Expr);
    defer allocator.destroy(str_expr);
    str_expr.* = ast.Expr{ .String = "hello" };

    const num_expr = try allocator.create(ast.Expr);
    defer allocator.destroy(num_expr);
    num_expr.* = ast.Expr{ .Int = 5 };

    const sub_expr = ast.Expr{ .Binary = .{ .op = .Sub, .left = str_expr, .right = num_expr } };
    try analyzer.analyzeExpr(sub_expr);

    // Should have one error about string in arithmetic
    try std.testing.expectEqual(@as(usize, 1), analyzer.errors.items.len);
    try std.testing.expect(std.mem.indexOf(u8, analyzer.errors.items[0].message, "Arithmetic operator requires numeric") != null);
}

test "type checking - arithmetic with numbers is OK" {
    const allocator = std.testing.allocator;

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();

    // Addition with two numbers - should be OK
    const num1 = try allocator.create(ast.Expr);
    defer allocator.destroy(num1);
    num1.* = ast.Expr{ .Int = 10 };

    const num2 = try allocator.create(ast.Expr);
    defer allocator.destroy(num2);
    num2.* = ast.Expr{ .Int = 20 };

    const add_expr = ast.Expr{ .Binary = .{ .op = .Add, .left = num1, .right = num2 } };
    try analyzer.analyzeExpr(add_expr);

    // Should have no errors
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
}

test "type checking - unknown types are not flagged" {
    const allocator = std.testing.allocator;

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();

    // Define a variable so it's not flagged as undefined
    try analyzer.scope.define("x", .variable);

    // Variable in AND - type is unknown, should not error
    const var_expr = try allocator.create(ast.Expr);
    defer allocator.destroy(var_expr);
    var_expr.* = ast.Expr{ .Ident = .{ .orig = "x", .cnf = "X" } };

    const bool_expr = try allocator.create(ast.Expr);
    defer allocator.destroy(bool_expr);
    bool_expr.* = ast.Expr{ .Bool = true };

    const and_expr = ast.Expr{ .Binary = .{ .op = .And, .left = var_expr, .right = bool_expr } };
    try analyzer.analyzeExpr(and_expr);

    // Should have no errors (unknown type is not flagged)
    try std.testing.expectEqual(@as(usize, 0), analyzer.errors.items.len);
}

// Levenshtein distance tests
test "levenshtein - identical strings" {
    try std.testing.expectEqual(@as(usize, 0), levenshteinDistance("hello", "hello"));
    try std.testing.expectEqual(@as(usize, 0), levenshteinDistance("Person", "Person"));
}

test "levenshtein - single character difference" {
    try std.testing.expectEqual(@as(usize, 1), levenshteinDistance("Person", "Persn")); // deletion
    try std.testing.expectEqual(@as(usize, 1), levenshteinDistance("Persn", "Person")); // insertion
    try std.testing.expectEqual(@as(usize, 1), levenshteinDistance("Person", "Persen")); // substitution
}

test "levenshtein - two character difference" {
    try std.testing.expectEqual(@as(usize, 2), levenshteinDistance("Person", "Prsn")); // two deletions
    try std.testing.expectEqual(@as(usize, 2), levenshteinDistance("Person", "Parsun")); // two substitutions (e→a, o→u)
}

test "levenshtein - empty strings" {
    try std.testing.expectEqual(@as(usize, 0), levenshteinDistance("", ""));
    try std.testing.expectEqual(@as(usize, 5), levenshteinDistance("hello", ""));
    try std.testing.expectEqual(@as(usize, 5), levenshteinDistance("", "world"));
}

test "levenshtein - case insensitive" {
    // The implementation is case-insensitive
    try std.testing.expectEqual(@as(usize, 0), levenshteinDistance("Person", "person"));
    try std.testing.expectEqual(@as(usize, 0), levenshteinDistance("PERSON", "person"));
}

// Label typo detection tests
test "label tracking - records labels" {
    const allocator = std.testing.allocator;

    var analyzer = SemanticAnalyzer.init(allocator);
    defer analyzer.deinit();

    analyzer.recordLabel("Person");
    analyzer.recordLabel("Person");
    analyzer.recordLabel("Company");

    try std.testing.expectEqual(@as(u32, 2), analyzer.labels.get("Person").?);
    try std.testing.expectEqual(@as(u32, 1), analyzer.labels.get("Company").?);
}
