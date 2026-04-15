// CANARY: REQ=REQ-SYNTAX-GEN-001; FEATURE="VSCodeSyntaxGeneration"; ASPECT=MetadataDerived; STATUS=EXEMPT; OWNER=tooling; UPDATED=2026-01-03
//! # VSCode Syntax Generator
//!
//! Generates VSCode TextMate syntax highlighting (gql.tmLanguage.json) from
//! the unified language_metadata.zig. This ensures syntax highlighting stays
//! in sync with the language definition.
//!
//! ## Usage
//!     zig build-exe scripts/generate_syntax.zig -Doptimize=ReleaseFast
//!     ./generate_syntax > editors/vscode/syntaxes/gql.tmLanguage.json
//!
//! Or use the build target:
//!     zig build generate-syntax

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const language_metadata = geode.language_metadata;

const KeywordCategory = language_metadata.KeywordCategory;
const FunctionCategory = language_metadata.FunctionCategory;


pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();


    try generateSyntaxToStdout(allocator);
}

fn generateSyntaxToStdout(allocator: std.mem.Allocator) !void {
    // Build the entire output in memory, then write all at once
    var output = try std.ArrayList(u8).initCapacity(allocator, 32768);
    defer output.deinit(allocator);

    try generateSyntax(allocator, &output);

    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout = std.Io.File.stdout();
    var write_buf: [8192]u8 = undefined;
    var writer = stdout.writer(io, &write_buf);
    try writer.interface.writeAll(output.items);
    try writer.interface.flush();
}

fn generateSyntax(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    // Categorize keywords - use comptime arrays to avoid ArrayList API issues
    var clause_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 32);
    defer clause_keywords.deinit(allocator);
    var boolean_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 32);
    defer boolean_keywords.deinit(allocator);
    var case_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer case_keywords.deinit(allocator);
    var other_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 64);
    defer other_keywords.deinit(allocator);
    var ddl_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer ddl_keywords.deinit(allocator);
    var transaction_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer transaction_keywords.deinit(allocator);
    var path_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer path_keywords.deinit(allocator);
    var set_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer set_keywords.deinit(allocator);

    for (language_metadata.keywords) |kw| {
        switch (kw.category) {
            .clause => try clause_keywords.append(allocator, kw.name),
            .boolean_operator, .literal, .comparison => try boolean_keywords.append(allocator, kw.name),
            .modifier => {
                // CASE/WHEN/THEN/ELSE/END go to case keywords
                if (std.mem.eql(u8, kw.name, "CASE") or std.mem.eql(u8, kw.name, "WHEN") or
                    std.mem.eql(u8, kw.name, "THEN") or std.mem.eql(u8, kw.name, "ELSE") or
                    std.mem.eql(u8, kw.name, "END"))
                {
                    try case_keywords.append(allocator, kw.name);
                } else {
                    try other_keywords.append(allocator, kw.name);
                }
            },
            .ddl => try ddl_keywords.append(allocator, kw.name),
            .transaction => try transaction_keywords.append(allocator, kw.name),
            .path_pattern => try path_keywords.append(allocator, kw.name),
            .set_operation => try set_keywords.append(allocator, kw.name),
            .ordering, .aggregation, .type_keyword, .temporal, .session, .reserved => try other_keywords.append(allocator, kw.name),
        }
    }

    // Categorize functions
    var aggregate_functions = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer aggregate_functions.deinit(allocator);
    var scalar_functions = try std.ArrayList([]const u8).initCapacity(allocator, 32);
    defer scalar_functions.deinit(allocator);
    var math_functions = try std.ArrayList([]const u8).initCapacity(allocator, 32);
    defer math_functions.deinit(allocator);
    var string_functions = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer string_functions.deinit(allocator);
    var temporal_functions = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer temporal_functions.deinit(allocator);
    var vector_functions = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer vector_functions.deinit(allocator);
    var other_functions = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer other_functions.deinit(allocator);

    for (language_metadata.functions) |f| {
        switch (f.category) {
            .aggregate => try aggregate_functions.append(allocator, f.name),
            .scalar_math => try math_functions.append(allocator, f.name),
            .scalar_string => try string_functions.append(allocator, f.name),
            .scalar_list => try scalar_functions.append(allocator, f.name),
            .conversion => try scalar_functions.append(allocator, f.name),
            .temporal => try temporal_functions.append(allocator, f.name),
            .graph => try scalar_functions.append(allocator, f.name),
            .path => try scalar_functions.append(allocator, f.name),
            .vector => try vector_functions.append(allocator, f.name),
            .predicate => try other_functions.append(allocator, f.name),
            .null_handling => try other_functions.append(allocator, f.name),
        }
    }

    // Collect type names
    var type_names = try std.ArrayList([]const u8).initCapacity(allocator, 32);
    defer type_names.deinit(allocator);
    for (language_metadata.types) |t| {
        try type_names.append(allocator, t.name);
    }

    // Generate JSON
    try output.appendSlice(allocator,
        \\{
        \\  "$schema": "https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json",
        \\  "name": "GQL",
        \\  "scopeName": "source.gql",
        \\  "fileTypes": ["gql", "geode"],
        \\  "patterns": [
        \\    { "include": "#comments" },
        \\    { "include": "#strings" },
        \\    { "include": "#numbers" },
        \\    { "include": "#keywords" },
        \\    { "include": "#functions" },
        \\    { "include": "#types" },
        \\    { "include": "#operators" },
        \\    { "include": "#variables" },
        \\    { "include": "#labels" }
        \\  ],
        \\  "repository": {
        \\    "comments": {
        \\      "patterns": [
        \\        {
        \\          "name": "comment.line.double-dash.gql",
        \\          "match": "--.*$"
        \\        },
        \\        {
        \\          "name": "comment.line.double-slash.gql",
        \\          "match": "//.*$"
        \\        },
        \\        {
        \\          "name": "comment.block.gql",
        \\          "begin": "/\\*",
        \\          "end": "\\*/",
        \\          "beginCaptures": {
        \\            "0": { "name": "punctuation.definition.comment.begin.gql" }
        \\          },
        \\          "endCaptures": {
        \\            "0": { "name": "punctuation.definition.comment.end.gql" }
        \\          },
        \\          "patterns": []
        \\        }
        \\      ]
        \\    },
        \\    "strings": {
        \\      "patterns": [
        \\        {
        \\          "name": "string.quoted.single.gql",
        \\          "begin": "'",
        \\          "end": "'",
        \\          "beginCaptures": {
        \\            "0": { "name": "punctuation.definition.string.begin.gql" }
        \\          },
        \\          "endCaptures": {
        \\            "0": { "name": "punctuation.definition.string.end.gql" }
        \\          },
        \\          "patterns": [
        \\            {
        \\              "name": "constant.character.escape.gql",
        \\              "match": "\\\\."
        \\            }
        \\          ]
        \\        },
        \\        {
        \\          "name": "string.quoted.double.gql",
        \\          "begin": "\"",
        \\          "end": "\"",
        \\          "beginCaptures": {
        \\            "0": { "name": "punctuation.definition.string.begin.gql" }
        \\          },
        \\          "endCaptures": {
        \\            "0": { "name": "punctuation.definition.string.end.gql" }
        \\          },
        \\          "patterns": [
        \\            {
        \\              "name": "constant.character.escape.gql",
        \\              "match": "\\\\."
        \\            }
        \\          ]
        \\        }
        \\      ]
        \\    },
        \\    "numbers": {
        \\      "patterns": [
        \\        {
        \\          "name": "constant.numeric.float.gql",
        \\          "match": "\\b\\d+\\.\\d+([eE][+-]?\\d+)?\\b"
        \\        },
        \\        {
        \\          "name": "constant.numeric.integer.gql",
        \\          "match": "\\b\\d+\\b"
        \\        }
        \\      ]
        \\    },
        \\    "keywords": {
        \\      "patterns": [
        \\
    );

    // Clause keywords (MATCH, CREATE, DELETE, etc.)
    try output.appendSlice(allocator, "        {\n          \"name\": \"keyword.control.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, clause_keywords.items);
    try output.appendSlice(allocator, ")\\\\b\"\n        },\n");

    // Boolean/logical keywords (AND, OR, NOT, TRUE, FALSE, NULL, etc.)
    try output.appendSlice(allocator, "        {\n          \"name\": \"keyword.operator.logical.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, boolean_keywords.items);
    try output.appendSlice(allocator, ")\\\\b\"\n        },\n");

    // Case keywords (CASE, WHEN, THEN, ELSE, END)
    try output.appendSlice(allocator, "        {\n          \"name\": \"keyword.control.case.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, case_keywords.items);
    try output.appendSlice(allocator, ")\\\\b\"\n        },\n");

    // DDL keywords (CREATE, DROP, GRAPH, SCHEMA, etc.)
    try output.appendSlice(allocator, "        {\n          \"name\": \"keyword.other.ddl.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, ddl_keywords.items);
    try output.appendSlice(allocator, ")\\\\b\"\n        },\n");

    // Transaction keywords (BEGIN, COMMIT, ROLLBACK, etc.)
    try output.appendSlice(allocator, "        {\n          \"name\": \"keyword.control.transaction.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, transaction_keywords.items);
    try output.appendSlice(allocator, ")\\\\b\"\n        },\n");

    // Path pattern keywords (SHORTEST, ACYCLIC, SIMPLE, etc.)
    try output.appendSlice(allocator, "        {\n          \"name\": \"keyword.other.path.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, path_keywords.items);
    try output.appendSlice(allocator, ")\\\\b\"\n        },\n");

    // Set operation keywords (UNION, INTERSECT, EXCEPT)
    try output.appendSlice(allocator, "        {\n          \"name\": \"keyword.operator.set.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, set_keywords.items);
    try output.appendSlice(allocator, ")\\\\b\"\n        },\n");

    // Other keywords (AS, DISTINCT, ORDER, BY, etc.)
    try output.appendSlice(allocator, "        {\n          \"name\": \"keyword.other.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, other_keywords.items);
    try output.appendSlice(allocator, ")\\\\b\"\n        }\n");

    try output.appendSlice(allocator,
        \\      ]
        \\    },
        \\    "functions": {
        \\      "patterns": [
        \\
    );

    // Aggregate functions
    try output.appendSlice(allocator, "        {\n          \"name\": \"support.function.aggregate.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, aggregate_functions.items);
    try output.appendSlice(allocator, ")\\\\b(?=\\\\s*\\\\()\"\n        },\n");

    // Scalar functions
    try output.appendSlice(allocator, "        {\n          \"name\": \"support.function.scalar.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, scalar_functions.items);
    try output.appendSlice(allocator, ")\\\\b(?=\\\\s*\\\\()\"\n        },\n");

    // Math functions
    try output.appendSlice(allocator, "        {\n          \"name\": \"support.function.math.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, math_functions.items);
    try output.appendSlice(allocator, ")\\\\b(?=\\\\s*\\\\()\"\n        },\n");

    // String functions
    try output.appendSlice(allocator, "        {\n          \"name\": \"support.function.string.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, string_functions.items);
    try output.appendSlice(allocator, ")\\\\b(?=\\\\s*\\\\()\"\n        },\n");

    // Temporal functions
    try output.appendSlice(allocator, "        {\n          \"name\": \"support.function.temporal.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, temporal_functions.items);
    try output.appendSlice(allocator, ")\\\\b(?=\\\\s*\\\\()\"\n        },\n");

    // Vector functions
    try output.appendSlice(allocator, "        {\n          \"name\": \"support.function.vector.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, vector_functions.items);
    try output.appendSlice(allocator, ")\\\\b(?=\\\\s*\\\\()\"\n        },\n");

    // Other functions
    try output.appendSlice(allocator, "        {\n          \"name\": \"support.function.other.gql\",\n          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, other_functions.items);
    try output.appendSlice(allocator, ")\\\\b(?=\\\\s*\\\\()\"\n        }\n");

    try output.appendSlice(allocator,
        \\      ]
        \\    },
        \\    "types": {
        \\      "patterns": [
        \\        {
        \\          "name": "storage.type.gql",
        \\
    );
    try output.appendSlice(allocator, "          \"match\": \"\\\\b(?i:");
    try writeKeywordList(allocator, output, type_names.items);
    try output.appendSlice(allocator, ")\\\\b\"\n");

    try output.appendSlice(allocator,
        \\        }
        \\      ]
        \\    },
        \\    "operators": {
        \\      "patterns": [
        \\        {
        \\          "name": "keyword.operator.comparison.gql",
        \\          "match": "(=|<>|<|>|<=|>=|=~|!~)"
        \\        },
        \\        {
        \\          "name": "keyword.operator.arithmetic.gql",
        \\          "match": "(\\+|-|\\*|/|%|\\^)"
        \\        },
        \\        {
        \\          "name": "keyword.operator.concatenation.gql",
        \\          "match": "\\|\\|"
        \\        },
        \\        {
        \\          "name": "keyword.operator.arrow.gql",
        \\          "match": "(->|<-|=>)"
        \\        }
        \\      ]
        \\    },
        \\    "variables": {
        \\      "patterns": [
        \\        {
        \\          "name": "variable.parameter.gql",
        \\          "match": "\\$[a-zA-Z_][a-zA-Z0-9_]*"
        \\        }
        \\      ]
        \\    },
        \\    "labels": {
        \\      "patterns": [
        \\        {
        \\          "name": "entity.name.tag.label.gql",
        \\          "match": ":[a-zA-Z_][a-zA-Z0-9_]*"
        \\        }
        \\      ]
        \\    }
        \\  }
        \\}
        \\
    );
}

fn writeKeywordList(allocator: std.mem.Allocator, output: *std.ArrayList(u8), items: []const []const u8) !void {
    for (items, 0..) |item, i| {
        if (i > 0) try output.appendSlice(allocator, "|");
        try output.appendSlice(allocator, item);
    }
}

test "generate syntax produces valid output" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try generateSyntax(std.testing.allocator, output.writer());

    // Check it starts with JSON
    try std.testing.expect(std.mem.startsWith(u8, output.items, "{"));
    // Check it contains expected patterns
    try std.testing.expect(std.mem.indexOf(u8, output.items, "\"scopeName\": \"source.gql\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "keyword.control.gql") != null);
}
