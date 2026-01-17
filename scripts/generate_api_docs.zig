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

fn getStdoutHandle() std.fs.File {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable;
        return std.fs.File{ .handle = handle };
    } else {
        return std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = getStdoutHandle();
    try generateApiDocsToFile(allocator, stdout);
}

fn generateApiDocsToFile(allocator: std.mem.Allocator, file: std.fs.File) !void {
    var output = try std.ArrayList(u8).initCapacity(allocator, 65536);
    defer output.deinit(allocator);

    try generateApiDocs(allocator, output.writer(allocator));
    try file.writeAll(output.items);
}

fn generateApiDocs(allocator: std.mem.Allocator, writer: anytype) !void {
    _ = allocator;

    // Header
    try writer.writeAll(
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
    try writer.writeAll("### Clause Keywords\n\n| Keyword | Description | GQL Compliant |\n|---------|-------------|---------------|\n");
    for (language_metadata.keywords) |kw| {
        if (kw.category == .clause) {
            try writer.print("| `{s}` | {s} | {s} |\n", .{
                kw.name,
                kw.doc,
                if (kw.compliance == .iso_gql) "Yes" else "Extension",
            });
        }
    }

    try writer.writeAll("\n### DDL Keywords\n\n| Keyword | Description | GQL Compliant |\n|---------|-------------|---------------|\n");
    for (language_metadata.keywords) |kw| {
        if (kw.category == .ddl) {
            try writer.print("| `{s}` | {s} | {s} |\n", .{
                kw.name,
                kw.doc,
                if (kw.compliance == .iso_gql) "Yes" else "Extension",
            });
        }
    }

    try writer.writeAll("\n### Boolean & Logical Keywords\n\n| Keyword | Description |\n|---------|-------------|\n");
    for (language_metadata.keywords) |kw| {
        if (kw.category == .boolean_operator or kw.category == .literal or kw.category == .comparison) {
            try writer.print("| `{s}` | {s} |\n", .{ kw.name, kw.doc });
        }
    }

    try writer.writeAll("\n### Transaction Keywords\n\n| Keyword | Description |\n|---------|-------------|\n");
    for (language_metadata.keywords) |kw| {
        if (kw.category == .transaction) {
            try writer.print("| `{s}` | {s} |\n", .{ kw.name, kw.doc });
        }
    }

    try writer.writeAll("\n### Path Pattern Keywords\n\n| Keyword | Description |\n|---------|-------------|\n");
    for (language_metadata.keywords) |kw| {
        if (kw.category == .path_pattern) {
            try writer.print("| `{s}` | {s} |\n", .{ kw.name, kw.doc });
        }
    }

    try writer.writeAll("\n### Set Operation Keywords\n\n| Keyword | Description |\n|---------|-------------|\n");
    for (language_metadata.keywords) |kw| {
        if (kw.category == .set_operation) {
            try writer.print("| `{s}` | {s} |\n", .{ kw.name, kw.doc });
        }
    }

    // Functions section
    try writer.writeAll(
        \\
        \\---
        \\
        \\## Functions
        \\
        \\
    );

    // Aggregate functions
    try writer.writeAll("### Aggregate Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .aggregate) {
            try writeFunctionDoc(writer, f);
        }
    }

    // Math functions
    try writer.writeAll("\n### Mathematical Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .scalar_math) {
            try writeFunctionDoc(writer, f);
        }
    }

    // String functions
    try writer.writeAll("\n### String Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .scalar_string) {
            try writeFunctionDoc(writer, f);
        }
    }

    // List functions
    try writer.writeAll("\n### List Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .scalar_list) {
            try writeFunctionDoc(writer, f);
        }
    }

    // Temporal functions
    try writer.writeAll("\n### Temporal Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .temporal) {
            try writeFunctionDoc(writer, f);
        }
    }

    // Graph functions
    try writer.writeAll("\n### Graph Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .graph) {
            try writeFunctionDoc(writer, f);
        }
    }

    // Path functions
    try writer.writeAll("\n### Path Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .path) {
            try writeFunctionDoc(writer, f);
        }
    }

    // Vector functions
    try writer.writeAll("\n### Vector Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .vector) {
            try writeFunctionDoc(writer, f);
        }
    }

    // Conversion functions
    try writer.writeAll("\n### Conversion Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .conversion) {
            try writeFunctionDoc(writer, f);
        }
    }

    // Predicate functions
    try writer.writeAll("\n### Predicate Functions\n\n");
    for (language_metadata.functions) |f| {
        if (f.category == .predicate or f.category == .null_handling) {
            try writeFunctionDoc(writer, f);
        }
    }

    // Types section
    try writer.writeAll(
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
        try writer.print("| `{s}` | {s} |\n", .{ t.name, t.doc });
    }

    // Procedures section
    try writer.writeAll(
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
    try writer.writeAll("### Centrality Algorithms\n\n");
    for (language_metadata.procedures) |p| {
        if (p.category == .centrality) {
            try writeProcedureDoc(writer, p);
        }
    }

    try writer.writeAll("\n### Community Detection\n\n");
    for (language_metadata.procedures) |p| {
        if (p.category == .community) {
            try writeProcedureDoc(writer, p);
        }
    }

    try writer.writeAll("\n### Connectivity Analysis\n\n");
    for (language_metadata.procedures) |p| {
        if (p.category == .connectivity) {
            try writeProcedureDoc(writer, p);
        }
    }

    try writer.writeAll("\n### Path Finding\n\n");
    for (language_metadata.procedures) |p| {
        if (p.category == .path_finding) {
            try writeProcedureDoc(writer, p);
        }
    }

    try writer.writeAll("\n### Administrative\n\n");
    for (language_metadata.procedures) |p| {
        if (p.category == .audit or p.category == .tde or p.category == .cdc) {
            try writeProcedureDoc(writer, p);
        }
    }

    // Footer
    try writer.writeAll(
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

fn writeFunctionDoc(writer: anytype, f: language_metadata.FunctionInfo) !void {
    // Format parameters
    try writer.print("#### `{s}(", .{f.name});
    for (f.params, 0..) |p, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{s}: {s}", .{ p.name, p.type_name });
    }
    try writer.print(")` -> `{s}`\n\n", .{f.return_type});
    try writer.print("{s}\n\n", .{f.doc});
    if (f.example) |example| {
        try writer.print("```gql\n{s}\n```\n\n", .{example});
    }
}

fn writeProcedureDoc(writer: anytype, p: language_metadata.ProcedureInfo) !void {
    try writer.print("#### `CALL {s}()`\n\n", .{p.name});
    try writer.print("{s}\n\n", .{p.doc});
    // Format columns
    try writer.writeAll("**Yields:** ");
    for (p.columns, 0..) |col, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("`{s}: {s}`", .{ col.name, col.type_name });
    }
    try writer.writeAll("\n\n");
    if (p.example) |example| {
        try writer.print("```gql\n{s}\n```\n\n", .{example});
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
