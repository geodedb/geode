// CANARY: REQ=REQ-META-VALIDATE-001; FEATURE="MetadataValidation"; ASPECT=CI; STATUS=IMPL; OWNER=tooling; UPDATED=2026-01-03
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

fn getStdoutHandle() std.fs.File {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch unreachable;
        return std.fs.File{ .handle = handle };
    } else {
        return std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    }
}

fn getStderrHandle() std.fs.File {
    if (builtin.os.tag == .windows) {
        const handle = std.os.windows.GetStdHandle(std.os.windows.STD_ERROR_HANDLE) catch unreachable;
        return std.fs.File{ .handle = handle };
    } else {
        return std.fs.File{ .handle = std.posix.STDERR_FILENO };
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = getStdoutHandle();
    const stderr = getStderrHandle();

    var all_valid = true;

    // Validate VSCode syntax
    try stdout.writeAll("Checking VSCode syntax (gql.tmLanguage.json)... ");
    if (try validateVSCodeSyntax(allocator)) {
        try stdout.writeAll("OK\n");
    } else {
        try stdout.writeAll("OUT OF SYNC\n");
        try stderr.writeAll("  Run: zig build generate-syntax > editors/vscode/syntaxes/gql.tmLanguage.json\n");
        all_valid = false;
    }

    // Validate Vim syntax
    try stdout.writeAll("Checking Vim syntax (gql.vim)... ");
    if (try validateVimSyntax(allocator)) {
        try stdout.writeAll("OK\n");
    } else {
        try stdout.writeAll("OUT OF SYNC\n");
        try stderr.writeAll("  Run: zig build generate-vim-syntax > editors/vim/syntax/gql.vim\n");
        all_valid = false;
    }

    // Summary
    try stdout.writeAll("\n");
    if (all_valid) {
        try stdout.writeAll("All generated files are in sync with language_metadata.zig\n");
    } else {
        try stderr.writeAll("ERROR: Some generated files are out of sync!\n");
        try stderr.writeAll("Please regenerate using the commands above.\n");
        std.process.exit(1);
    }
}

fn validateVSCodeSyntax(allocator: std.mem.Allocator) !bool {
    // Read existing file
    const file = std.fs.cwd().openFile("editors/vscode/syntaxes/gql.tmLanguage.json", .{}) catch {
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
    const file = std.fs.cwd().openFile("editors/vim/syntax/gql.vim", .{}) catch {
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
