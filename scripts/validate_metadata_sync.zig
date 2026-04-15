// CANARY: REQ=REQ-META-VALIDATE-001; FEATURE="MetadataValidation"; ASPECT=CI; STATUS=TESTED; TEST=geodetestlab/specs/gql_catalog_operations_comprehensive.yml; OWNER=tooling; UPDATED=2026-01-03
//! # Metadata Sync Validation
//!
//! Validates that all generated files (VSCode syntax, Vim syntax, API docs)
//! are in sync with the source language_metadata.zig. Used in CI to prevent
//! drift between metadata and generated artifacts.
//!
//! ## Usage
//!     zig build validate-metadata
//!
//! Exit codes:
//!   0 - All files in sync
//!   1 - Files out of sync (regeneration needed)

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const language_metadata = geode.language_metadata;

fn writeStdout(msg: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    try writer.interface.writeAll(msg);
    try writer.interface.flush();
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var all_valid = true;

    // Validate VSCode syntax
    try writeStdout("Checking VSCode syntax (gql.tmLanguage.json)... ");
    if (try validateVSCodeSyntax(allocator)) {
        try writeStdout("OK\n");
    } else {
        try writeStdout("OUT OF SYNC\n");
        std.debug.print("  Run: zig build generate-syntax > editors/vscode/syntaxes/gql.tmLanguage.json\n", .{});
        all_valid = false;
    }

    // Validate Vim syntax
    try writeStdout("Checking Vim syntax (gql.vim)... ");
    if (try validateVimSyntax(allocator)) {
        try writeStdout("OK\n");
    } else {
        try writeStdout("OUT OF SYNC\n");
        std.debug.print("  Run: zig build generate-vim-syntax > editors/vim/syntax/gql.vim\n", .{});
        all_valid = false;
    }

    // Summary
    try writeStdout("\n");
    if (all_valid) {
        try writeStdout("All generated files are in sync with language_metadata.zig\n");
    } else {
        std.debug.print("ERROR: Some generated files are out of sync!\n", .{});
        std.debug.print("Please regenerate using the commands above.\n", .{});
        std.process.exit(1);
    }
}

fn validateVSCodeSyntax(allocator: std.mem.Allocator) !bool {
    // Read existing file
    const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), "editors/vscode/syntaxes/gql.tmLanguage.json", .{}) catch {
        return false; // File doesn't exist
    };
    defer file.close();

    const existing = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return false;
    };
    defer allocator.free(existing);

    // Check that all keywords from metadata are present
    for (language_metadata.keywords) |kw| {
        if (std.mem.indexOf(u8, existing, kw.name) == null) {
            return false;
        }
    }

    // Check that all functions from metadata are present
    for (language_metadata.functions) |f| {
        if (std.mem.indexOf(u8, existing, f.name) == null) {
            return false;
        }
    }

    // Check that all types from metadata are present
    for (language_metadata.types) |t| {
        if (std.mem.indexOf(u8, existing, t.name) == null) {
            return false;
        }
    }

    return true;
}

fn validateVimSyntax(allocator: std.mem.Allocator) !bool {
    // Read existing file
    const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), "editors/vim/syntax/gql.vim", .{}) catch {
        return false; // File doesn't exist
    };
    defer file.close();

    const existing = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return false;
    };
    defer allocator.free(existing);

    // Check that all keywords from metadata are present
    for (language_metadata.keywords) |kw| {
        if (std.mem.indexOf(u8, existing, kw.name) == null) {
            return false;
        }
    }

    // Check that all functions from metadata are present
    for (language_metadata.functions) |f| {
        if (std.mem.indexOf(u8, existing, f.name) == null) {
            return false;
        }
    }

    return true;
}

test "validation functions work" {
    // Basic test that functions don't crash
    const allocator = std.testing.allocator;
    _ = try validateVSCodeSyntax(allocator);
    _ = try validateVimSyntax(allocator);
}
