// Context-aware GQL recommendation engine
// Analyzes parsed GQL AST and produces Information/Hint diagnostics suggesting
// Geode-specific features (FLE annotations, indexes, graph algorithms, functions).

const std = @import("std");
const ast = @import("ast.zig");
const Allocator = std.mem.Allocator;

pub const SensitivityLevel = enum {
    high, // password, secret, token, etc. → suggest @encrypted
    medium, // email, phone, address, etc. → suggest @searchable
};

pub const Severity = enum {
    information,
    hint,
};

pub const Recommendation = struct {
    line: u32,
    column: u32,
    severity: Severity,
    code: []const u8,
    message: []const u8,
};

/// Maps variable names to their labels from graph patterns.
const LabelMap = std.StringHashMap([]const u8);

pub const RecommendationEngine = struct {
    allocator: Allocator,
    results: std.ArrayList(Recommendation),

    pub fn init(allocator: Allocator) RecommendationEngine {
        return .{
            .allocator = allocator,
            .results = .empty,
        };
    }

    /// Frees every recommendation's `message` (the engine owns them all)
    /// and the result list. Slices returned by `analyze` are invalid after.
    pub fn deinit(self: *RecommendationEngine) void {
        for (self.results.items) |rec| self.allocator.free(rec.message);
        self.results.deinit(self.allocator);
    }

    /// SONNY-6484: `rec.message` is heap-allocated with `self.allocator`;
    /// the engine takes ownership (freed by `deinit`, or here if the
    /// append fails).
    fn appendOwned(self: *RecommendationEngine, rec: Recommendation) !void {
        errdefer self.allocator.free(rec.message);
        try self.results.append(self.allocator, rec);
    }

    /// Analyze a parsed program and return recommendations.
    pub fn analyze(self: *RecommendationEngine, program: ast.Program) ![]const Recommendation {
        for (program.statements) |stmt| {
            try self.analyzeStatement(stmt);
        }
        return self.results.items;
    }

    fn analyzeStatement(self: *RecommendationEngine, stmt: ast.Statement) !void {
        switch (stmt) {
            .Query => |query| try self.analyzeQuery(query),
            .Create => |create| try self.analyzeGraphPattern(create.pattern),
            .Insert => |insert| try self.analyzeGraphPattern(insert.pattern),
            .Merge => |merge| try self.analyzeGraphPattern(merge.pattern),
            .CreateGraphType => |cgt| try self.analyzeCreateGraphType(cgt),
            else => {},
        }
    }

    fn analyzeQuery(self: *RecommendationEngine, query: ast.Query) !void {
        // Collect variable→label mapping from MATCH pattern
        var label_map = LabelMap.init(self.allocator);
        defer label_map.deinit();
        collectLabelVariableMap(query.match, &label_map);

        // Check MATCH pattern properties for sensitive names / vector properties
        try self.analyzeGraphPattern(query.match);

        // Check CREATE pattern within query (e.g., MATCH ... CREATE ...)
        if (query.create_pattern) |cp| {
            try self.analyzeGraphPattern(cp);
        }

        // Check WHERE clause for index hints and IS NULL → coalesce
        if (query.where_clause) |where| {
            try self.walkExprForIndexHints(where, &label_map);
            try self.walkExprForCoalesce(where);
        }

        // Check ORDER BY for index suggestions
        if (query.order_by) |ob| {
            for (ob.keys) |key| {
                if (key.expr == .PropertyAccess) {
                    const pa = key.expr.PropertyAccess;
                    const label = label_map.get(pa.object) orelse "Label";
                    const msg = try std.fmt.allocPrint(self.allocator, "Consider creating a btree index for ORDER BY: CREATE INDEX ON :{s}({s})", .{ label, pa.property });
                    try self.appendOwned(.{
                        .line = 0,
                        .column = 0,
                        .severity = .hint,
                        .code = "geode/suggest-index",
                        .message = msg,
                    });
                }
            }
        }

        // Check RETURN for count(relationship) → suggest degree functions
        for (query.ret.items) |item| {
            try self.checkForDegreeRecommendation(item.expr, &label_map);
        }

        // Check for variable-length paths → suggest path mode or shortestPath
        for (query.match.chains) |chain| {
            for (chain.hops) |hop| {
                if (hop.rel.min_len != null or hop.rel.max_len != null) {
                    if (chain.path_mode == .walk and !chain.is_shortest) {
                        try self.appendOwned(.{
                            .line = 0,
                            .column = 0,
                            .severity = .information,
                            .code = "geode/suggest-path-mode",
                            .message = try self.allocator.dupe(u8, "Variable-length path detected. Consider using a path mode (TRAIL, ACYCLIC, SIMPLE) or shortestPath() for deterministic traversal."),
                        });
                    }
                }
            }
        }

        // Check chained queries
        if (query.next_query) |nq| {
            try self.analyzeQuery(nq.*);
        }
    }

    fn analyzeGraphPattern(self: *RecommendationEngine, pattern: ast.GraphPattern) !void {
        for (pattern.chains) |chain| {
            // Check standalone head node
            if (chain.head) |head| {
                try self.checkNodePatternProperties(head);
            }
            for (chain.hops) |hop| {
                try self.checkNodePatternProperties(hop.left);
                try self.checkNodePatternProperties(hop.right);
            }
        }
    }

    fn checkNodePatternProperties(self: *RecommendationEngine, node: ast.NodePattern) !void {
        const props = node.props orelse return;
        for (props) |prop| {
            // Check for sensitive property names
            if (isSensitivePropertyName(prop.key)) |level| {
                switch (level) {
                    .high => {
                        const msg = try std.fmt.allocPrint(self.allocator, "Property '{s}' may contain sensitive data. Consider using @encrypted annotation for field-level encryption.", .{prop.key});
                        try self.appendOwned(.{
                            .line = 0,
                            .column = 0,
                            .severity = .information,
                            .code = "geode/suggest-encrypted",
                            .message = msg,
                        });
                    },
                    .medium => {
                        const msg = try std.fmt.allocPrint(self.allocator, "Property '{s}' may contain personal data. Consider using @searchable annotation for encrypted but searchable storage.", .{prop.key});
                        try self.appendOwned(.{
                            .line = 0,
                            .column = 0,
                            .severity = .hint,
                            .code = "geode/suggest-searchable",
                            .message = msg,
                        });
                    },
                }
            }

            // Check for vector/embedding property names
            if (isVectorPropertyName(prop.key)) {
                const msg = try std.fmt.allocPrint(self.allocator, "Property '{s}' appears to be a vector embedding. Consider creating a vector index: CREATE VECTOR INDEX ON :{s}({s})", .{
                    prop.key,
                    if (node.labels.len > 0) node.labels[0] else "Label",
                    prop.key,
                });
                try self.appendOwned(.{
                    .line = 0,
                    .column = 0,
                    .severity = .hint,
                    .code = "geode/suggest-vector-index",
                    .message = msg,
                });
            }
        }
    }

    fn analyzeCreateGraphType(self: *RecommendationEngine, cgt: ast.CreateGraphTypeStatement) !void {
        for (cgt.fields) |field| {
            if (isSensitivePropertyName(field.name)) |level| {
                // Check if annotation is already present
                const already_annotated = blk: {
                    for (field.annotations) |ann| {
                        if (std.ascii.eqlIgnoreCase(ann.name, "encrypted") or
                            std.ascii.eqlIgnoreCase(ann.name, "searchable"))
                        {
                            break :blk true;
                        }
                    }
                    break :blk false;
                };
                if (already_annotated) continue;

                switch (level) {
                    .high => {
                        const msg = try std.fmt.allocPrint(self.allocator, "Field '{s}' in graph type '{s}' may contain sensitive data. Consider adding @encrypted annotation.", .{ field.name, cgt.name });
                        try self.appendOwned(.{
                            .line = 0,
                            .column = 0,
                            .severity = .information,
                            .code = "geode/suggest-encrypted",
                            .message = msg,
                        });
                    },
                    .medium => {
                        const msg = try std.fmt.allocPrint(self.allocator, "Field '{s}' in graph type '{s}' may contain personal data. Consider adding @searchable annotation.", .{ field.name, cgt.name });
                        try self.appendOwned(.{
                            .line = 0,
                            .column = 0,
                            .severity = .hint,
                            .code = "geode/suggest-searchable",
                            .message = msg,
                        });
                    },
                }
            }
        }
    }

    fn walkExprForIndexHints(self: *RecommendationEngine, expr: ast.Expr, label_map: *LabelMap) !void {
        switch (expr) {
            .Binary => |bin| {
                if (bin.op == .Eq) {
                    // Check if one side is PropertyAccess
                    if (bin.left.* == .PropertyAccess) {
                        const pa = bin.left.PropertyAccess;
                        const label = label_map.get(pa.object) orelse "Label";
                        const msg = try std.fmt.allocPrint(self.allocator, "Consider creating an index for faster lookups: CREATE INDEX ON :{s}({s})", .{ label, pa.property });
                        try self.appendOwned(.{
                            .line = 0,
                            .column = 0,
                            .severity = .hint,
                            .code = "geode/suggest-index",
                            .message = msg,
                        });
                    } else if (bin.right.* == .PropertyAccess) {
                        const pa = bin.right.PropertyAccess;
                        const label = label_map.get(pa.object) orelse "Label";
                        const msg = try std.fmt.allocPrint(self.allocator, "Consider creating an index for faster lookups: CREATE INDEX ON :{s}({s})", .{ label, pa.property });
                        try self.appendOwned(.{
                            .line = 0,
                            .column = 0,
                            .severity = .hint,
                            .code = "geode/suggest-index",
                            .message = msg,
                        });
                    }
                }
                // Recurse into both sides for AND/OR chains
                try self.walkExprForIndexHints(bin.left.*, label_map);
                try self.walkExprForIndexHints(bin.right.*, label_map);
            },
            .Contains => |c| {
                if (c.value.* == .PropertyAccess) {
                    const pa = c.value.PropertyAccess;
                    const label = label_map.get(pa.object) orelse "Label";
                    const msg = try std.fmt.allocPrint(self.allocator, "CONTAINS on '{s}' may benefit from a fulltext index: CREATE FULLTEXT INDEX ON :{s}({s})", .{ pa.property, label, pa.property });
                    try self.appendOwned(.{
                        .line = 0,
                        .column = 0,
                        .severity = .hint,
                        .code = "geode/suggest-fulltext-index",
                        .message = msg,
                    });
                }
            },
            .StartsWith => |sw| {
                if (sw.value.* == .PropertyAccess) {
                    const pa = sw.value.PropertyAccess;
                    const label = label_map.get(pa.object) orelse "Label";
                    const msg = try std.fmt.allocPrint(self.allocator, "STARTS WITH on '{s}' may benefit from a fulltext index: CREATE FULLTEXT INDEX ON :{s}({s})", .{ pa.property, label, pa.property });
                    try self.appendOwned(.{
                        .line = 0,
                        .column = 0,
                        .severity = .hint,
                        .code = "geode/suggest-fulltext-index",
                        .message = msg,
                    });
                }
            },
            else => {},
        }
    }

    fn walkExprForCoalesce(self: *RecommendationEngine, expr: ast.Expr) !void {
        switch (expr) {
            .IsNull => |is_null| {
                if (!is_null.negated) {
                    if (is_null.target.* == .PropertyAccess) {
                        const pa = is_null.target.PropertyAccess;
                        const msg = try std.fmt.allocPrint(self.allocator, "Consider using coalesce({s}.{s}, default_value) as an alternative to IS NULL checks.", .{ pa.object, pa.property });
                        try self.appendOwned(.{
                            .line = 0,
                            .column = 0,
                            .severity = .hint,
                            .code = "geode/suggest-coalesce",
                            .message = msg,
                        });
                    }
                }
            },
            .Binary => |bin| {
                try self.walkExprForCoalesce(bin.left.*);
                try self.walkExprForCoalesce(bin.right.*);
            },
            else => {},
        }
    }

    fn checkForDegreeRecommendation(self: *RecommendationEngine, expr: ast.Expr, label_map: *LabelMap) !void {
        _ = label_map;
        switch (expr) {
            .Call => |call| {
                // Check for count(rel_var) where rel_var is a relationship
                if (call.callee.* == .Ident) {
                    const name = call.callee.Ident.orig;
                    if (std.ascii.eqlIgnoreCase(name, "count") and call.args.len == 1) {
                        if (call.args[0].* == .Ident and !std.mem.eql(u8, call.args[0].Ident.orig, "*")) {
                            try self.appendOwned(.{
                                .line = 0,
                                .column = 0,
                                .severity = .hint,
                                .code = "geode/suggest-degree",
                                .message = try self.allocator.dupe(u8, "count() on a relationship variable may be replaceable with indegree()/outdegree() or algo.degree.stream for better performance."),
                            });
                        }
                    }
                }
            },
            else => {},
        }
    }
};

/// Check if a property name is sensitive (case-insensitive comparison).
pub fn isSensitivePropertyName(name: []const u8) ?SensitivityLevel {
    const high_sensitivity = [_][]const u8{
        "password",   "secret",      "token",      "api_key", "apikey",
        "ssn",        "credit_card", "creditcard", "pin",     "private_key",
        "privatekey",
    };
    const medium_sensitivity = [_][]const u8{
        "email",    "phone",        "address",     "dob", "date_of_birth",
        "passport", "phone_number", "phonenumber",
    };

    for (high_sensitivity) |sensitive| {
        if (std.ascii.eqlIgnoreCase(name, sensitive)) return .high;
    }
    for (medium_sensitivity) |sensitive| {
        if (std.ascii.eqlIgnoreCase(name, sensitive)) return .medium;
    }
    return null;
}

/// Check if a property name suggests a vector/embedding.
fn isVectorPropertyName(name: []const u8) bool {
    const vector_names = [_][]const u8{
        "embedding", "embeddings", "vector", "vectors", "features",
    };
    for (vector_names) |vn| {
        if (std.ascii.eqlIgnoreCase(name, vn)) return true;
    }
    return false;
}

/// Collect variable→label mapping from a GraphPattern.
fn collectLabelVariableMap(pattern: ast.GraphPattern, map: *LabelMap) void {
    for (pattern.chains) |chain| {
        if (chain.head) |head| {
            addNodeToLabelMap(head, map);
        }
        for (chain.hops) |hop| {
            addNodeToLabelMap(hop.left, map);
            addNodeToLabelMap(hop.right, map);
        }
    }
}

fn addNodeToLabelMap(node: ast.NodePattern, map: *LabelMap) void {
    if (node.name) |name| {
        if (node.labels.len > 0) {
            map.put(name, node.labels[0]) catch {};
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

const geode = @import("../lib.zig");

test "recommend encrypted for password property" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("CREATE (u:User {password: 'x'})", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expect(recs.len >= 1);
    try std.testing.expectEqualStrings("geode/suggest-encrypted", recs[0].code);
}

test "recommend searchable for email property" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("INSERT (u:User {email: 'a@b.com'})", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expect(recs.len >= 1);
    try std.testing.expectEqualStrings("geode/suggest-searchable", recs[0].code);
}

test "no recommendation for non-sensitive properties" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("CREATE (p:Product {price: 9.99})", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expectEqual(@as(usize, 0), recs.len);
}

test "recommend index for WHERE equality" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("MATCH (n:Person) WHERE n.email = 'x' RETURN n", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    // Should have at least a suggest-index recommendation (possibly also suggest-searchable)
    var found_index = false;
    for (recs) |rec| {
        if (std.mem.eql(u8, rec.code, "geode/suggest-index")) found_index = true;
    }
    try std.testing.expect(found_index);
}

test "recommend fulltext for CONTAINS" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("MATCH (n:Article) WHERE n.content CONTAINS 'x' RETURN n", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expect(recs.len >= 1);
    var found = false;
    for (recs) |rec| {
        if (std.mem.eql(u8, rec.code, "geode/suggest-fulltext-index")) found = true;
    }
    try std.testing.expect(found);
}

test "recommend vector index for embedding property" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("CREATE (d:Doc {embedding: [1.0]})", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expect(recs.len >= 1);
    var found = false;
    for (recs) |rec| {
        if (std.mem.eql(u8, rec.code, "geode/suggest-vector-index")) found = true;
    }
    try std.testing.expect(found);
}

test "recommend path mode for variable-length path" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("MATCH (a)-[*1..5]->(b) RETURN a", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expect(recs.len >= 1);
    var found = false;
    for (recs) |rec| {
        if (std.mem.eql(u8, rec.code, "geode/suggest-path-mode")) found = true;
    }
    try std.testing.expect(found);
}

test "recommend coalesce for IS NULL" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("MATCH (n:Person) WHERE n.nick IS NULL RETURN n", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expect(recs.len >= 1);
    var found = false;
    for (recs) |rec| {
        if (std.mem.eql(u8, rec.code, "geode/suggest-coalesce")) found = true;
    }
    try std.testing.expect(found);
}

test "recommend degree for count relationship" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("MATCH (n)-[r]->() RETURN n, count(r)", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expect(recs.len >= 1);
    var found = false;
    for (recs) |rec| {
        if (std.mem.eql(u8, rec.code, "geode/suggest-degree")) found = true;
    }
    try std.testing.expect(found);
}

test "multiple recommendations for multiple patterns" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("MATCH (u:User) WHERE u.email = 'x' RETURN u", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    // Should have at least an index suggestion for WHERE equality on email
    try std.testing.expect(recs.len >= 1);
}

test "recommend encrypted in graph type fields" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("CREATE GRAPH TYPE T (password STRING)", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expect(recs.len >= 1);
    try std.testing.expectEqualStrings("geode/suggest-encrypted", recs[0].code);
}

test "skip recommendation when annotation already present" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("CREATE GRAPH TYPE T (password STRING @encrypted)", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    // Should not recommend encrypted for a field already annotated
    for (recs) |rec| {
        if (std.mem.eql(u8, rec.code, "geode/suggest-encrypted")) {
            // If there's a recommendation for encrypted, it should not be for 'password'
            try std.testing.expect(std.mem.indexOf(u8, rec.message, "'password'") == null);
        }
    }
}

test "isSensitivePropertyName detects high sensitivity" {
    try std.testing.expect(isSensitivePropertyName("password") == .high);
    try std.testing.expect(isSensitivePropertyName("PASSWORD") == .high);
    try std.testing.expect(isSensitivePropertyName("api_key") == .high);
    try std.testing.expect(isSensitivePropertyName("ssn") == .high);
}

test "isSensitivePropertyName detects medium sensitivity" {
    try std.testing.expect(isSensitivePropertyName("email") == .medium);
    try std.testing.expect(isSensitivePropertyName("phone") == .medium);
    try std.testing.expect(isSensitivePropertyName("address") == .medium);
}

test "isSensitivePropertyName returns null for non-sensitive" {
    try std.testing.expect(isSensitivePropertyName("name") == null);
    try std.testing.expect(isSensitivePropertyName("price") == null);
    try std.testing.expect(isSensitivePropertyName("count") == null);
}
