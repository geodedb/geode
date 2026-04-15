// CANARY: REQ=REQ-API-DOCS-001; FEATURE="APIDocumentation"; ASPECT=MetadataDerived; STATUS=EXEMPT; OWNER=tooling; UPDATED=2026-01-03
//! # API Documentation Generator
//!
//! Generates comprehensive API documentation (Markdown) from the unified
//! language_metadata.zig. This ensures documentation stays in sync with
//! the language definition.
//!
//! ## Usage
//!     zig build generate-api-docs
//!
//! Output: docs/API_REFERENCE.md

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const language_metadata = geode.language_metadata;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try generateApiDocsToStdout(allocator);
}

fn generateApiDocsToStdout(allocator: std.mem.Allocator) !void {
    var output = try std.ArrayList(u8).initCapacity(allocator, 65536);
    defer output.deinit(allocator);

    try generateApiDocs(allocator, &output);
    // Note: generateApiDocs uses output.appendSlice/print directly

    // Write output to stdout via Io.File.writer
    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout = std.Io.File.stdout();
    var write_buf: [8192]u8 = undefined;
    var writer = stdout.writer(io, &write_buf);
    try writer.interface.writeAll(output.items);
    try writer.interface.flush();
}

fn generateApiDocs(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {

    // Header
    try output.appendSlice(allocator,
        \\# GQL API Reference
        \\
        \\> Auto-generated from `src/gql/language_metadata.zig` - DO NOT EDIT MANUALLY
        \\>
        \\> Last updated: 2026-01-03
        \\
        \\This document provides a comprehensive reference for Geode's GQL implementation,
        \\including all keywords, functions, types, and procedures.
        \\
        \\## Table of Contents
        \\
        \\- [Keywords](#keywords)
        \\- [Functions](#functions)
        \\- [Data Types](#data-types)
        \\- [Procedures](#procedures)
        \\
        \\---
        \\
        \\## Keywords
        \\
        \\
    );

    // Group keywords by category
    try output.appendSlice(allocator, "### Clause Keywords\n\n| Keyword | Description | GQL Compliant |\n|---------|-------------|---------------|\n");
    for (language_metadata.keywords) |kw| {
        if (kw.category == .clause) {
            try output.print(allocator, "| `{s}` | {s} | {s} |\n", .{
                kw.name,
                kw.doc,
                if (kw.compliance == .iso_gql) "Yes" else "Extension",
            });
        }
    }

    try output.appendSlice(allocator, "\n### DDL Keywords\n\n| Keyword | Description | GQL Compliant |\n|---------|-------------|---------------|\n");
    for (language_metadata.keywords) |kw| {
        if (kw.category == .ddl) {
            try output.print(allocator, "| `{s}` | {s} | {s} |\n", .{
                kw.name,
                kw.doc,
                if (kw.compliance == .iso_gql) "Yes" else "Extension",
            });
        }
    }

    try output.appendSlice(allocator, "\n### Boolean & Logical Keywords\n\n| Keyword | Description |\n|---------|-------------|\n");
    for (language_metadata.keywords) |kw| {
        if (kw.category == .boolean_operator or kw.category == .literal or kw.category == .comparison) {
            try output.print(allocator, "| `{s}` | {s} |\n", .{ kw.name, kw.doc });
        }
    }

    try output.appendSlice(allocator, "\n### Transaction Keywords\n\n| Keyword | Description |\n|---------|-------------|\n");
    for (language_metadata.keywords) |kw| {
        if (kw.category == .transaction) {
            try output.print(allocator, "| `{s}` | {s} |\n", .{ kw.name, kw.doc });
        }
    }

    try output.appendSlice(allocator, "\n### Path Pattern Keywords\n\n| Keyword | Description |\n|---------|-------------|\n");
    for (language_metadata.keywords) |kw| {
        if (kw.category == .path_pattern) {
            try output.print(allocator, "| `{s}` | {s} |\n", .{ kw.name, kw.doc });
        }
    }

    try output.appendSlice(allocator, "\n### Set Operation Keywords\n\n| Keyword | Description |\n|---------|-------------|\n");
    for (language_metadata.keywords) |kw| {
        if (kw.category == .set_operation) {
            try output.print(allocator, "| `{s}` | {s} |\n", .{ kw.name, kw.doc });
        }
    }

    // Functions section
    try output.appendSlice(allocator,
        \\
        \\---
        \\
        \\## Functions
        \\
        \\
    );

    // Aggregate functions
    try output.appendSlice(allocator, "### Aggregate Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .aggregate) {
            try writeFunctionDoc(allocator, output, f);
        }
    }

    // Math functions
    try output.appendSlice(allocator, "\n### Mathematical Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .scalar_math) {
            try writeFunctionDoc(allocator, output, f);
        }
    }

    // String functions
    try output.appendSlice(allocator, "\n### String Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .scalar_string) {
            try writeFunctionDoc(allocator, output, f);
        }
    }

    // List functions
    try output.appendSlice(allocator, "\n### List Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .scalar_list) {
            try writeFunctionDoc(allocator, output, f);
        }
    }

    // Temporal functions
    try output.appendSlice(allocator, "\n### Temporal Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .temporal) {
            try writeFunctionDoc(allocator, output, f);
        }
    }

    // Graph functions
    try output.appendSlice(allocator, "\n### Graph Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .graph) {
            try writeFunctionDoc(allocator, output, f);
        }
    }

    // Path functions
    try output.appendSlice(allocator, "\n### Path Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .path) {
            try writeFunctionDoc(allocator, output, f);
        }
    }

    // Vector functions
    try output.appendSlice(allocator, "\n### Vector Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .vector) {
            try writeFunctionDoc(allocator, output, f);
        }
    }

    // Conversion functions
    try output.appendSlice(allocator, "\n### Conversion Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .conversion) {
            try writeFunctionDoc(allocator, output, f);
        }
    }

    // Predicate functions
    try output.appendSlice(allocator, "\n### Predicate Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .predicate or f.category == .null_handling) {
            try writeFunctionDoc(allocator, output, f);
        }
    }

    // Types section
    try output.appendSlice(allocator,
        \\
        \\---
        \\
        \\## Data Types
        \\
        \\| Type | Description |
        \\|------|-------------|
        \\
    );
    for (language_metadata.types) |t| {
        try output.print(allocator, "| `{s}` | {s} |\n", .{ t.name, t.doc });
    }

    // Procedures section
    try output.appendSlice(allocator,
        \\
        \\---
        \\
        \\## Procedures
        \\
        \\Procedures are invoked using `CALL procedure.name()` syntax.
        \\
        \\
    );

    // Group procedures by category
    try output.appendSlice(allocator, "### Centrality Algorithms\n\n");
    for (language_metadata.procedures) |p| {
        if (p.category == .centrality) {
            try writeProcedureDoc(allocator, output, p);
        }
    }

    try output.appendSlice(allocator, "\n### Community Detection\n\n");
    for (language_metadata.procedures) |p| {
        if (p.category == .community) {
            try writeProcedureDoc(allocator, output, p);
        }
    }

    try output.appendSlice(allocator, "\n### Connectivity Analysis\n\n");
    for (language_metadata.procedures) |p| {
        if (p.category == .connectivity) {
            try writeProcedureDoc(allocator, output, p);
        }
    }

    try output.appendSlice(allocator, "\n### Path Finding\n\n");
    for (language_metadata.procedures) |p| {
        if (p.category == .path_finding) {
            try writeProcedureDoc(allocator, output, p);
        }
    }

    try output.appendSlice(allocator, "\n### Administrative\n\n");
    for (language_metadata.procedures) |p| {
        if (p.category == .audit or p.category == .tde or p.category == .cdc) {
            try writeProcedureDoc(allocator, output, p);
        }
    }

    // Footer
    try output.appendSlice(allocator,
        \\
        \\---
        \\
        \\## See Also
        \\
        \\- [GQL Compliance](GQL_COMPLIANCE.md) - ISO/IEC 39075:2024 conformance details
        \\- [Types and Functions](TYPES_AND_FUNCTIONS.md) - Detailed type documentation
        \\- [Quick Reference](QUICK_REFERENCE.md) - Common patterns and examples
        \\
    );
}

fn writeFunctionDoc(allocator: std.mem.Allocator, output: *std.ArrayList(u8), f: language_metadata.FunctionInfo) !void {
    // Format parameters
    try output.print(allocator, "#### `{s}(", .{f.name});
    for (f.params, 0..) |p, i| {
        if (i > 0) try output.appendSlice(allocator, ", ");
        try output.print(allocator, "{s}: {s}", .{ p.name, p.type_name });
    }
    try output.print(allocator, ")` -> `{s}`\n\n", .{f.return_type});
    try output.print(allocator, "{s}\n\n", .{f.doc});
    if (f.example) |example| {
        try output.print(allocator, "```gql\n{s}\n```\n\n", .{example});
    }
}

fn writeProcedureDoc(allocator: std.mem.Allocator, output: *std.ArrayList(u8), p: language_metadata.ProcedureInfo) !void {
    try output.print(allocator, "#### `CALL {s}()`\n\n", .{p.name});
    try output.print(allocator, "{s}\n\n", .{p.doc});
    // Format columns
    try output.appendSlice(allocator, "**Yields:** ");
    for (p.columns, 0..) |col, i| {
        if (i > 0) try output.appendSlice(allocator, ", ");
        try output.print(allocator, "`{s}: {s}`", .{ col.name, col.type_name });
    }
    try output.appendSlice(allocator, "\n\n");
    if (p.example) |example| {
        try output.print(allocator, "```gql\n{s}\n```\n\n", .{example});
    }
}

test "generate api docs produces valid output" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try generateApiDocs(std.testing.allocator, output.writer());

    try std.testing.expect(std.mem.startsWith(u8, output.items, "# GQL API Reference"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "## Keywords") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "## Functions") != null);
}
