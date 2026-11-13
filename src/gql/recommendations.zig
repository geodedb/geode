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
    /// 0-based line and byte column of `anchor` in the analysed source
    /// (`analyzeSource`); 0, 0 from `analyze`, which has no source.
    line: u32,
    column: u32,
    severity: Severity,
    code: []const u8,
    message: []const u8,
    /// SONNY-6511: the source token the recommendation is about (a property
    /// or field name, `count`, or the `*` of a variable-length path),
    /// borrowed from the AST. The AST carries no source positions, so
    /// `analyzeSource` finds the token in the source text.
    anchor: []const u8 = "",
    /// Byte column one past the anchor on `line` (the anchor is one token).
    end_column: u32 = 0,
};

/// A one-line source range: 0-based line, byte columns [column, end_column).
pub const SourceSpan = struct {
    line: u32,
    column: u32,
    end_column: u32,
};

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// SONNY-6511: the `nth` (0-based) occurrence of `token` in `source` outside
/// string literals and comments, compared ASCII case-insensitively; a word
/// token must be a whole word. An empty `token` finds the first byte that is
/// not whitespace or comment (the start of the first statement).
pub fn locate(source: []const u8, token: []const u8, nth: usize) ?SourceSpan {
    const word = token.len > 0 and isWordByte(token[0]);
    var seen: usize = 0;
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if (c == '\n') {
            line += 1;
            i += 1;
            line_start = i;
            continue;
        }
        // Comments: // and -- to the end of the line, /* ... */.
        if (i + 1 < source.len and ((c == '/' and source[i + 1] == '/') or (c == '-' and source[i + 1] == '-'))) {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        if (i + 1 < source.len and c == '/' and source[i + 1] == '*') {
            i += 2;
            while (i < source.len and !(source[i] == '*' and i + 1 < source.len and source[i + 1] == '/')) {
                if (source[i] == '\n') {
                    line += 1;
                    line_start = i + 1;
                }
                i += 1;
            }
            i = @min(source.len, i + 2);
            continue;
        }
        // String literals: '...' and "...", with backslash escapes and
        // doubled quotes.
        if (c == '\'' or c == '"') {
            i += 1;
            while (i < source.len) {
                if (source[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (source[i] == '\n') {
                    line += 1;
                    line_start = i + 1;
                }
                if (source[i] == c) {
                    if (i + 1 < source.len and source[i + 1] == c) {
                        i += 2;
                        continue;
                    }
                    break;
                }
                i += 1;
            }
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (token.len == 0) return .{ .line = line, .column = @intCast(i - line_start), .end_column = @intCast(i - line_start) };
        const fits = i + token.len <= source.len and std.ascii.eqlIgnoreCase(source[i .. i + token.len], token);
        const bounded = !word or ((i == 0 or !isWordByte(source[i - 1])) and (i + token.len == source.len or !isWordByte(source[i + token.len])));
        if (fits and bounded) {
            if (seen == nth) return .{ .line = line, .column = @intCast(i - line_start), .end_column = @intCast(i + token.len - line_start) };
            seen += 1;
            i += token.len;
            continue;
        }
        // Step over the rest of a word so a token never matches inside one.
        if (isWordByte(c)) {
            while (i < source.len and isWordByte(source[i])) i += 1;
        } else {
            i += 1;
        }
    }
    return null;
}

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

    /// SONNY-6511: `analyze`, then place each recommendation on its anchor
    /// in `source` (the text `program` was parsed from): the n-th
    /// recommendation naming an anchor goes to the anchor's n-th whole-word
    /// occurrence outside string literals and comments. One whose anchor is
    /// not found goes to the start of the first statement (the AST has no
    /// statement positions either).
    pub fn analyzeSource(self: *RecommendationEngine, program: ast.Program, source: []const u8) ![]const Recommendation {
        _ = try self.analyze(program);
        const fallback = locate(source, "", 0) orelse SourceSpan{ .line = 0, .column = 0, .end_column = 0 };
        for (self.results.items, 0..) |*rec, i| {
            var nth: usize = 0;
            for (self.results.items[0..i]) |prev| {
                if (std.ascii.eqlIgnoreCase(prev.anchor, rec.anchor)) nth += 1;
            }
            const span = (if (rec.anchor.len > 0) locate(source, rec.anchor, nth) else null) orelse fallback;
            rec.line = span.line;
            rec.column = span.column;
            rec.end_column = span.end_column;
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
        if (query.filter_clause) |filter| {
            try self.walkExprForIndexHints(filter, &label_map);
            try self.walkExprForCoalesce(filter);
        }

        // Check ORDER BY for index suggestions
        if (query.order_by) |ob| {
            for (ob.keys) |key| {
                if (propertyRef(key.expr)) |pa| {
                    const label = label_map.get(pa.object) orelse "Label";
                    const msg = try std.fmt.allocPrint(self.allocator, "Consider creating a btree index for ORDER BY: CREATE INDEX ON :{s}({s})", .{ label, pa.property });
                    try self.appendOwned(.{
                        .line = 0,
                        .column = 0,
                        .severity = .hint,
                        .code = "geode/suggest-index",
                        .anchor = pa.property,
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
                            .anchor = "*",
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
                            .anchor = prop.key,
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
                            .anchor = prop.key,
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
                    .anchor = prop.key,
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
                            .anchor = field.name,
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
                            .anchor = field.name,
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
                    if (propertyRef(bin.left.*)) |pa| {
                        const label = label_map.get(pa.object) orelse "Label";
                        const msg = try std.fmt.allocPrint(self.allocator, "Consider creating an index for faster lookups: CREATE INDEX ON :{s}({s})", .{ label, pa.property });
                        try self.appendOwned(.{
                            .line = 0,
                            .column = 0,
                            .severity = .hint,
                            .code = "geode/suggest-index",
                            .anchor = pa.property,
                            .message = msg,
                        });
                    } else if (propertyRef(bin.right.*)) |pa| {
                        const label = label_map.get(pa.object) orelse "Label";
                        const msg = try std.fmt.allocPrint(self.allocator, "Consider creating an index for faster lookups: CREATE INDEX ON :{s}({s})", .{ label, pa.property });
                        try self.appendOwned(.{
                            .line = 0,
                            .column = 0,
                            .severity = .hint,
                            .code = "geode/suggest-index",
                            .anchor = pa.property,
                            .message = msg,
                        });
                    }
                }
                // Recurse into both sides for AND/OR chains
                try self.walkExprForIndexHints(bin.left.*, label_map);
                try self.walkExprForIndexHints(bin.right.*, label_map);
            },
            .Contains => |c| {
                if (propertyRef(c.value.*)) |pa| {
                    const label = label_map.get(pa.object) orelse "Label";
                    const msg = try std.fmt.allocPrint(self.allocator, "CONTAINS on '{s}' may benefit from a fulltext index: CREATE FULLTEXT INDEX ON :{s}({s})", .{ pa.property, label, pa.property });
                    try self.appendOwned(.{
                        .line = 0,
                        .column = 0,
                        .severity = .hint,
                        .code = "geode/suggest-fulltext-index",
                        .anchor = pa.property,
                        .message = msg,
                    });
                }
            },
            .StartsWith => |sw| {
                if (propertyRef(sw.value.*)) |pa| {
                    const label = label_map.get(pa.object) orelse "Label";
                    const msg = try std.fmt.allocPrint(self.allocator, "STARTS WITH on '{s}' may benefit from a fulltext index: CREATE FULLTEXT INDEX ON :{s}({s})", .{ pa.property, label, pa.property });
                    try self.appendOwned(.{
                        .line = 0,
                        .column = 0,
                        .severity = .hint,
                        .code = "geode/suggest-fulltext-index",
                        .anchor = pa.property,
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
                    if (propertyRef(is_null.target.*)) |pa| {
                        const msg = try std.fmt.allocPrint(self.allocator, "Consider using coalesce({s}.{s}, default_value) as an alternative to IS NULL checks.", .{ pa.object, pa.property });
                        try self.appendOwned(.{
                            .line = 0,
                            .column = 0,
                            .severity = .hint,
                            .code = "geode/suggest-coalesce",
                            .anchor = pa.property,
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
                                .anchor = "count",
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

const PropertyRef = struct { object: []const u8, property: []const u8 };

/// SONNY-6494: the parser writes `n.prop` as `.Member` on an `.Ident`
/// target; `.PropertyAccess` is built only by internal rewrites. Matching
/// `.PropertyAccess` alone left every WHERE / ORDER BY recommendation dead.
fn propertyRef(expr: ast.Expr) ?PropertyRef {
    return switch (expr) {
        .PropertyAccess => |pa| .{ .object = pa.object, .property = pa.property },
        .Member => |m| if (m.target.* == .Ident) .{ .object = m.target.Ident.orig, .property = m.field } else null,
        else => null,
    };
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

test "recommendations: recommend encrypted for password property" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("CREATE (u:User {password: 'x'})", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expect(recs.len >= 1);
    try std.testing.expectEqualStrings("geode/suggest-encrypted", recs[0].code);
}

test "recommendations: recommend searchable for email property" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("INSERT (u:User {email: 'a@b.com'})", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expect(recs.len >= 1);
    try std.testing.expectEqualStrings("geode/suggest-searchable", recs[0].code);
}

test "recommendations: no recommendation for non-sensitive properties" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("CREATE (p:Product {price: 9.99})", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expectEqual(@as(usize, 0), recs.len);
}

test "recommendations: recommend index for WHERE equality" {
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

test "recommendations: recommend fulltext for CONTAINS" {
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

test "recommendations: recommend vector index for embedding property" {
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

test "recommendations: recommend path mode for variable-length path" {
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

test "recommendations: recommend coalesce for IS NULL" {
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

test "recommendations: recommend degree for count relationship" {
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

test "recommendations: multiple recommendations for multiple patterns" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("MATCH (u:User) WHERE u.email = 'x' RETURN u", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    // Should have at least an index suggestion for WHERE equality on email
    try std.testing.expect(recs.len >= 1);
}

test "recommendations: recommend encrypted in graph type fields" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("CREATE GRAPH TYPE T AS { password text }", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    try std.testing.expect(recs.len >= 1);
    try std.testing.expectEqualStrings("geode/suggest-encrypted", recs[0].code);
}

test "recommendations: skip recommendation when annotation already present" {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql("CREATE GRAPH TYPE T AS { ssn text @encrypted }", allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    // Should not recommend encrypted for a field already annotated
    for (recs) |rec| {
        if (std.mem.eql(u8, rec.code, "geode/suggest-encrypted")) {
            // If there's a recommendation for encrypted, it should not be for 'password'
            try std.testing.expect(std.mem.indexOf(u8, rec.message, "'ssn'") == null);
        }
    }
}

test "recommendations: isSensitivePropertyName detects high sensitivity" {
    try std.testing.expect(isSensitivePropertyName("password") == .high);
    try std.testing.expect(isSensitivePropertyName("PASSWORD") == .high);
    try std.testing.expect(isSensitivePropertyName("api_key") == .high);
    try std.testing.expect(isSensitivePropertyName("ssn") == .high);
}

test "recommendations: isSensitivePropertyName detects medium sensitivity" {
    try std.testing.expect(isSensitivePropertyName("email") == .medium);
    try std.testing.expect(isSensitivePropertyName("phone") == .medium);
    try std.testing.expect(isSensitivePropertyName("address") == .medium);
}

test "recommendations: isSensitivePropertyName returns null for non-sensitive" {
    try std.testing.expect(isSensitivePropertyName("name") == null);
    try std.testing.expect(isSensitivePropertyName("price") == null);
    try std.testing.expect(isSensitivePropertyName("count") == null);
}

fn expectCode(src: []const u8, code: []const u8, needle: []const u8) !void {
    const allocator = std.testing.allocator;
    var result = try geode.parseGql(src, allocator);
    defer result.deinit();

    var engine = RecommendationEngine.init(allocator);
    defer engine.deinit();
    const recs = try engine.analyze(result.program);
    for (recs) |rec| {
        if (std.mem.eql(u8, rec.code, code) and std.mem.indexOf(u8, rec.message, needle) != null) return;
    }
    return error.TestExpectedRecommendation;
}

test "recommendations: index for ORDER BY property names the label" {
    try expectCode("MATCH (n:Person) RETURN n ORDER BY n.age", "geode/suggest-index", "CREATE INDEX ON :Person(age)");
}

test "recommendations: index for FILTER equality" {
    try expectCode("MATCH (n:Person) FILTER n.age = 30 RETURN n", "geode/suggest-index", "CREATE INDEX ON :Person(age)");
}

test "recommendations: fulltext for STARTS WITH" {
    try expectCode("MATCH (n:Article) WHERE n.title STARTS WITH 'x' RETURN n", "geode/suggest-fulltext-index", "STARTS WITH on 'title'");
}

test "recommendations: WHERE equality names the matched label and property" {
    try expectCode("MATCH (n:Person) WHERE n.age = 30 RETURN n", "geode/suggest-index", "CREATE INDEX ON :Person(age)");
}
