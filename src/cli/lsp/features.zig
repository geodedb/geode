// CANARY: LSP_LANGUAGE_FEATURES
// Language features implementation for GQL/Geode LSP

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const Document = @import("document.zig").Document;
const geode = @import("geode");

// GQL Keywords for completion
const GQL_KEYWORDS = [_][]const u8{
    "MATCH",     "CREATE",   "DELETE",     "MERGE",    "SET",
    "REMOVE",    "RETURN",   "WHERE",      "ORDER",    "BY",
    "LIMIT",     "OFFSET",   "SKIP",       "WITH",     "UNWIND",
    "CALL",      "YIELD",    "UNION",      "ALL",      "OPTIONAL",
    "AS",        "DISTINCT", "AND",        "OR",       "NOT",
    "XOR",       "IN",       "IS",         "NULL",     "TRUE",
    "FALSE",     "CASE",     "WHEN",       "THEN",     "ELSE",
    "END",       "ASC",      "DESC",       "GROUP",    "HAVING",
    "INTERSECT", "EXCEPT",   "INSERT",     "UPDATE",   "DROP",
    "USE",       "GRAPH",    "CATALOG",    "SCHEMA",   "TABLE",
    "VIEW",      "INDEX",    "CONSTRAINT", "ON",       "EXISTS",
    "IF",        "NOT",      "SHOW",       "DESCRIBE", "EXPLAIN",
};

// GQL Functions for completion
const GQL_FUNCTIONS = [_][]const u8{
    "count",      "sum",        "avg",      "min",       "max",
    "collect",    "size",       "length",   "type",      "id",
    "labels",     "properties", "keys",     "nodes",     "relationships",
    "abs",        "ceil",       "floor",    "round",     "sqrt",
    "rand",       "sign",       "exp",      "log",       "log10",
    "sin",        "cos",        "tan",      "asin",      "acos",
    "atan",       "atan2",      "pi",       "e",         "degrees",
    "radians",    "toInteger",  "toFloat",  "toString",  "toBoolean",
    "head",       "last",       "tail",     "reverse",   "range",
    "split",      "substring",  "replace",  "toLower",   "toUpper",
    "trim",       "lTrim",      "rTrim",    "left",      "right",
    "startsWith", "endsWith",   "contains", "timestamp", "date",
    "time",       "datetime",   "duration", "coalesce",  "nullIf",
    "distance",   "similarity", "cosine",   "euclidean", "manhattan",
};

// GQL Types for completion
const GQL_TYPES = [_][]const u8{
    "INTEGER", "FLOAT",        "STRING",   "BOOLEAN", "DATE",
    "TIME",    "DATETIME",     "DURATION", "POINT",   "VECTOR",
    "UUID",    "BYTES",        "JSON",     "LIST",    "MAP",
    "NODE",    "RELATIONSHIP", "PATH",     "GRAPH",   "ANY",
};

pub fn provideDiagnostics(allocator: Allocator, doc: *const Document) ![]protocol.Diagnostic {
    var diagnostics = std.ArrayList(protocol.Diagnostic).initCapacity(allocator, 10) catch return error.OutOfMemory;
    errdefer diagnostics.deinit(allocator);

    // Parse the document using outcome to get better error info
    const outcome = try geode.parseGqlOutcome(doc.text, allocator, .{});

    switch (outcome) {
        .Err => |err_info| {
            // Check for double-dash comments first (GB02 warning)
            if (err_info.has_double_dash_comment) {
                const warning = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = 0, .character = 0 },
                        .end = .{ .line = 0, .character = 0 },
                    },
                    .severity = .Warning,
                    .source = "geode",
                    .message = try allocator.dupe(u8, "Double-dash (--) comments are disabled per GQL spec (GB02). Use // comments instead."),
                };
                try diagnostics.append(allocator, warning);
            }

            // Then show the parse error at the actual location
            const diag = protocol.Diagnostic{
                .range = .{
                    .start = .{ .line = err_info.line, .character = err_info.column },
                    .end = .{ .line = err_info.line, .character = err_info.column + 1 },
                },
                .severity = .Error,
                .source = "geode",
                .message = try allocator.dupe(u8, err_info.msg),
            };
            try diagnostics.append(allocator, diag);
        },
        .Ok => |result| {
            defer {
                var res = result;
                res.deinit();
            }

            // Check for double-dash comments (GB02 - show as warning)
            if (result.has_double_dash_comment) {
                const diag = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = 0, .character = 0 },
                        .end = .{ .line = 0, .character = 0 },
                    },
                    .severity = .Warning,
                    .source = "geode",
                    .message = try allocator.dupe(u8, "Double-dash (--) comments are disabled per GQL spec (GB02). Use // comments instead."),
                };
                try diagnostics.append(allocator, diag);
            }

            // Check for parser errors
            if (result.last_error) |last_err| {
                const diag = protocol.Diagnostic{
                    .range = .{
                        .start = .{ .line = 0, .character = 0 },
                        .end = .{ .line = 0, .character = 0 },
                    },
                    .severity = .Error,
                    .source = "geode",
                    .message = try allocator.dupe(u8, last_err),
                };
                try diagnostics.append(allocator, diag);
            }
        },
    }

    return diagnostics.toOwnedSlice(allocator);
}

pub fn provideHover(allocator: Allocator, doc: *const Document, line: u32, character: u32) !?protocol.Hover {
    const offset = doc.getOffset(line, character) orelse return null;
    const word = doc.getWordAt(offset) orelse return null;

    // Check if it's a keyword
    const upper_word = try std.ascii.allocUpperString(allocator, word);
    defer allocator.free(upper_word);

    for (GQL_KEYWORDS) |keyword| {
        if (std.mem.eql(u8, upper_word, keyword)) {
            const doc_text = try getKeywordDocumentation(allocator, keyword);
            return protocol.Hover{
                .contents = .{
                    .kind = .markdown,
                    .value = doc_text,
                },
            };
        }
    }

    // Check if it's a function
    for (GQL_FUNCTIONS) |func| {
        if (std.mem.eql(u8, word, func)) {
            const doc_text = try getFunctionDocumentation(allocator, func);
            return protocol.Hover{
                .contents = .{
                    .kind = .markdown,
                    .value = doc_text,
                },
            };
        }
    }

    // Check if it's a type
    for (GQL_TYPES) |typ| {
        if (std.mem.eql(u8, upper_word, typ)) {
            const doc_text = try getTypeDocumentation(allocator, typ);
            return protocol.Hover{
                .contents = .{
                    .kind = .markdown,
                    .value = doc_text,
                },
            };
        }
    }

    return null;
}

pub fn provideCompletion(allocator: Allocator, doc: *const Document, line: u32, character: u32) ![]protocol.CompletionItem {
    _ = doc;
    _ = line;
    _ = character;

    var items = std.ArrayList(protocol.CompletionItem).initCapacity(allocator, 100) catch return error.OutOfMemory;
    errdefer items.deinit(allocator);

    // Add keywords
    for (GQL_KEYWORDS) |keyword| {
        try items.append(allocator, .{
            .label = keyword,
            .kind = .Keyword,
            .detail = "GQL Keyword",
            .insertText = keyword,
        });
    }

    // Add functions
    for (GQL_FUNCTIONS) |func| {
        try items.append(allocator, .{
            .label = func,
            .kind = .Function,
            .detail = "GQL Function",
            .insertText = try std.fmt.allocPrint(allocator, "{s}()", .{func}),
        });
    }

    // Add types
    for (GQL_TYPES) |typ| {
        try items.append(allocator, .{
            .label = typ,
            .kind = .Class,
            .detail = "GQL Type",
            .insertText = typ,
        });
    }

    return items.toOwnedSlice(allocator);
}

pub fn provideDefinition(allocator: Allocator, doc: *const Document, line: u32, character: u32) !?protocol.Location {
    _ = allocator;
    _ = doc;
    _ = line;
    _ = character;
    // TODO: Implement go-to-definition using AST analysis
    return null;
}

pub fn provideFormatting(allocator: Allocator, doc: *const Document) !?[]const u8 {
    _ = allocator;
    // TODO: Implement GQL formatting
    return doc.text;
}

fn getKeywordDocumentation(allocator: Allocator, keyword: []const u8) ![]const u8 {
    const docs = std.StaticStringMap([]const u8).initComptime(.{
        .{ "MATCH", "**MATCH** - Specifies a graph pattern to search for in the graph.\n\nExample:\n```gql\nMATCH (n:Person)-[:KNOWS]->(m:Person)\nRETURN n, m\n```" },
        .{ "CREATE", "**CREATE** - Creates new nodes and relationships in the graph.\n\nExample:\n```gql\nCREATE (n:Person {name: 'Alice', age: 30})\n```" },
        .{ "RETURN", "**RETURN** - Specifies what values to return from a query.\n\nExample:\n```gql\nMATCH (n:Person)\nRETURN n.name, n.age\n```" },
        .{ "WHERE", "**WHERE** - Filters results based on conditions.\n\nExample:\n```gql\nMATCH (n:Person)\nWHERE n.age > 25\nRETURN n\n```" },
        .{ "ORDER", "**ORDER BY** - Sorts results by one or more expressions.\n\nExample:\n```gql\nMATCH (n:Person)\nRETURN n.name\nORDER BY n.age DESC\n```" },
        .{ "LIMIT", "**LIMIT** - Limits the number of results returned.\n\nExample:\n```gql\nMATCH (n:Person)\nRETURN n\nLIMIT 10\n```" },
        .{ "DELETE", "**DELETE** - Deletes nodes and relationships.\n\nExample:\n```gql\nMATCH (n:Person {name: 'Alice'})\nDELETE n\n```" },
        .{ "MERGE", "**MERGE** - Ensures a pattern exists, creating it if necessary.\n\nExample:\n```gql\nMERGE (n:Person {email: 'alice@example.com'})\n```" },
    });

    // Always return an allocated copy so caller can safely free
    if (docs.get(keyword)) |doc_text| {
        return try allocator.dupe(u8, doc_text);
    } else {
        return try std.fmt.allocPrint(allocator, "**{s}** - GQL keyword", .{keyword});
    }
}

fn getFunctionDocumentation(allocator: Allocator, func: []const u8) ![]const u8 {
    const docs = std.StaticStringMap([]const u8).initComptime(.{
        .{ "count", "**count**(*expression*) → INTEGER\n\nReturns the number of values or rows.\n\nExample:\n```gql\nMATCH (n:Person)\nRETURN count(n)\n```" },
        .{ "sum", "**sum**(*expression*) → NUMBER\n\nReturns the sum of a set of numeric values.\n\nExample:\n```gql\nMATCH (n:Person)\nRETURN sum(n.age)\n```" },
        .{ "avg", "**avg**(*expression*) → NUMBER\n\nReturns the average of a set of numeric values.\n\nExample:\n```gql\nMATCH (n:Person)\nRETURN avg(n.age)\n```" },
        .{ "distance", "**distance**(*vector1*, *vector2*, *metric*) → FLOAT\n\nCalculates distance between two vectors using the specified metric (L2, cosine, etc.).\n\nExample:\n```gql\nRETURN distance([1.0, 2.0, 3.0], [4.0, 5.0, 6.0], 'L2')\n```" },
        .{ "similarity", "**similarity**(*vector1*, *vector2*) → FLOAT\n\nCalculates cosine similarity between two vectors.\n\nExample:\n```gql\nRETURN similarity([1.0, 0.0], [0.5, 0.866])\n```" },
    });

    // Always return an allocated copy so caller can safely free
    if (docs.get(func)) |doc_text| {
        return try allocator.dupe(u8, doc_text);
    } else {
        return try std.fmt.allocPrint(allocator, "**{s}**() - GQL function", .{func});
    }
}

fn getTypeDocumentation(allocator: Allocator, typ: []const u8) ![]const u8 {
    const docs = std.StaticStringMap([]const u8).initComptime(.{
        .{ "INTEGER", "**INTEGER** - 64-bit signed integer type.\n\nExample: `42`, `-1`, `0`" },
        .{ "FLOAT", "**FLOAT** - 64-bit floating-point type.\n\nExample: `3.14`, `-0.5`, `1.0e10`" },
        .{ "STRING", "**STRING** - UTF-8 text type.\n\nExample: `'hello'`, `\"world\"`" },
        .{ "BOOLEAN", "**BOOLEAN** - True or false value.\n\nExample: `TRUE`, `FALSE`" },
        .{ "VECTOR", "**VECTOR** - Multi-dimensional numeric array for embeddings.\n\nExample: `[1.0, 2.0, 3.0]`\n\nSupports HNSW indexing for similarity search." },
        .{ "UUID", "**UUID** - Universally unique identifier.\n\nExample: `uuid('550e8400-e29b-41d4-a716-446655440000')`" },
        .{ "DATETIME", "**DATETIME** - Date and time with timezone support.\n\nExample: `datetime('2025-01-15T10:30:00Z')`" },
    });

    // Always return an allocated copy so caller can safely free
    if (docs.get(typ)) |doc_text| {
        return try allocator.dupe(u8, doc_text);
    } else {
        return try std.fmt.allocPrint(allocator, "**{s}** - GQL type", .{typ});
    }
}
