// CANARY: REQ=REQ-FUZZ-DICT-001; FEATURE="FuzzDictionaries"; ASPECT=MetadataDerived; STATUS=EXEMPT; OWNER=tooling; UPDATED=2026-01-03
//! # Fuzz Dictionary Generator
//!
//! Generates fuzzing dictionaries from the unified language_metadata.zig.
//! These dictionaries help fuzzers like AFL/libFuzzer explore the GQL
//! parser more effectively by providing valid tokens.
//!
//! ## Usage
//!     zig build generate-fuzz-dict
//!
//! Output: fuzz/dictionaries/gql.dict

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
    try generateFuzzDictToFile(allocator, stdout);
}

fn generateFuzzDictToFile(allocator: std.mem.Allocator, file: std.fs.File) !void {
    var output = try std.ArrayList(u8).initCapacity(allocator, 16384);
    defer output.deinit(allocator);

    try generateFuzzDict(output.writer(allocator));
    try file.writeAll(output.items);
}

fn generateFuzzDict(writer: anytype) !void {
    // Header
    try writer.writeAll(
        \\# GQL Fuzzing Dictionary
        \\# Generated from language_metadata.zig - DO NOT EDIT MANUALLY
        \\# Format: AFL/libFuzzer compatible
        \\#
        \\# Usage with AFL:
        \\#   afl-fuzz -x fuzz/dictionaries/gql.dict -i corpus -o findings -- ./target
        \\#
        \\# Usage with libFuzzer:
        \\#   ./fuzzer -dict=fuzz/dictionaries/gql.dict corpus/
        \\
        \\
    );

    // Keywords
    try writer.writeAll("# Keywords\n");
    for (language_metadata.keywords) |kw| {
        try writer.print("\"{s}\"\n", .{kw.name});
        // Also add lowercase version
        try writer.writeAll("\"");
        for (kw.name) |c| {
            try writer.writeByte(std.ascii.toLower(c));
        }
        try writer.writeAll("\"\n");
    }

    // Functions
    try writer.writeAll("\n# Functions\n");
    for (language_metadata.functions) |f| {
        try writer.print("\"{s}\"\n", .{f.name});
        try writer.print("\"{s}(\"\n", .{f.name});
        try writer.print("\"{s}()\"\n", .{f.name});
    }

    // Types
    try writer.writeAll("\n# Types\n");
    for (language_metadata.types) |t| {
        try writer.print("\"{s}\"\n", .{t.name});
    }

    // Procedures
    try writer.writeAll("\n# Procedures\n");
    for (language_metadata.procedures) |p| {
        try writer.print("\"CALL {s}\"\n", .{p.name});
        try writer.print("\"{s}\"\n", .{p.name});
    }

    // Common patterns
    try writer.writeAll(
        \\
        \\# Common patterns
        \\"MATCH"
        \\"MATCH (n)"
        \\"MATCH (n:Label)"
        \\"MATCH (n)-[r]->(m)"
        \\"MATCH (n)-[:TYPE]->(m)"
        \\"CREATE"
        \\"CREATE (n)"
        \\"CREATE (n:Label)"
        \\"CREATE (n {prop: value})"
        \\"RETURN"
        \\"RETURN n"
        \\"RETURN *"
        \\"WHERE"
        \\"WHERE n.prop = "
        \\"ORDER BY"
        \\"ORDER BY n.prop"
        \\"ORDER BY n.prop ASC"
        \\"ORDER BY n.prop DESC"
        \\"LIMIT"
        \\"LIMIT 10"
        \\"SKIP"
        \\"SKIP 10"
        \\"WITH"
        \\"WITH n"
        \\"WITH n AS m"
        \\"UNWIND"
        \\"UNWIND list AS x"
        \\"OPTIONAL MATCH"
        \\"OPTIONAL MATCH (n)"
        \\
        \\# Operators
        \\"="
        \\"<>"
        \\"<"
        \\">"
        \\"<="
        \\">="
        \\"+"
        \\"-"
        \\"*"
        \\"/"
        \\"%"
        \\"^"
        \\"||"
        \\"=~"
        \\"!~"
        \\
        \\# Literals
        \\"null"
        \\"NULL"
        \\"true"
        \\"TRUE"
        \\"false"
        \\"FALSE"
        \\"0"
        \\"1"
        \\"-1"
        \\"0.0"
        \\"1.5"
        \\"-1.5"
        \\"1e10"
        \\"1.5e-10"
        \\
        \\# Strings
        \\"'string'"
        \\"\"string\""
        \\"''"
        \\"\"\""
        \\"'escape\\'d'"
        \\
        \\# Comments
        \\"-- comment"
        \\"// comment"
        \\"/* comment */"
        \\
        \\# Variables
        \\"$param"
        \\"$name"
        \\"$value"
        \\"$id"
        \\
        \\# Labels
        \\":Label"
        \\":Person"
        \\":Node"
        \\":Edge"
        \\
        \\# Property access
        \\"n.prop"
        \\"n.name"
        \\"n.id"
        \\"n['prop']"
        \\
        \\# List operations
        \\"[]"
        \\"[1, 2, 3]"
        \\"[0]"
        \\"[0..10]"
        \\"list[0]"
        \\
        \\# Map operations
        \\"{}"
        \\"{key: value}"
        \\"{a: 1, b: 2}"
        \\
        \\# Graph patterns
        \\"()"
        \\"(n)"
        \\"(n:L)"
        \\"(n:L {p: v})"
        \\"--"
        \\"-->"
        \\"<--"
        \\"-[]->"
        \\"<-[]-"
        \\"-[r]->"
        \\"-[:T]->"
        \\"-[r:T]->"
        \\"-[*]->"
        \\"-[*1..5]->"
        \\
    );
}

test "generate fuzz dict produces valid output" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try generateFuzzDict(output.writer());

    try std.testing.expect(std.mem.startsWith(u8, output.items, "# GQL Fuzzing Dictionary"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "MATCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "RETURN") != null);
}
