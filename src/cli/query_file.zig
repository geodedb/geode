//! `geode query --file` input handling: the size cap and the statement
//! assembly loop, lifted out of `cmdQuery` so both are testable.
//!
//! This file intentionally depends on nothing but `std`: the subprocess e2e
//! lane (tests/test_cli_file_chunked.zig) imports it directly as a module so
//! the 2d unit cases can drive a failing allocator without pulling the whole
//! geode import graph into the test artifact.

const std = @import("std");

/// Maximum accepted `--file` payload. Named (and printed) so an operator who
/// hits it can act on the refusal instead of guessing at a bare `1 << 24`.
/// CANARY: REQ=REQ-CLI-FILE-SIZE-CAP-001; FEATURE="QueryFileFlag"; ASPECT=SizeCap; STATUS=TESTED; TEST=tests/test_cli_file_chunked.zig; OWNER=cli; UPDATED=2026-08-31
pub const max_file_bytes: usize = 16 * 1024 * 1024;

/// Human-readable spelling of `max_file_bytes`, used in the refusal message
/// and in `geode query --help` so the two can never drift apart.
pub const max_file_size_label = "16 MiB";

/// Split `contents` into complete GQL statements.
///
/// Blank lines and `--` / `#` comment lines are dropped; continuation lines
/// are joined with a single space; a statement is complete when its last
/// non-blank line ends with `;`. A trailing fragment without a terminating
/// semicolon is discarded (same behaviour the inline loop in `cmdQuery` had).
///
/// CANARY: REQ=REQ-CLI-CHUNKED-EXEC-002; FEATURE="ChunkedExecution"; ASPECT=StatementParsing; STATUS=TESTED; TEST=tests/test_cli_file_chunked.zig; OWNER=cli; UPDATED=2026-08-31
///
/// 2d: every allocation is propagated. The nine `catch {}` sites this replaces
/// turned an OOM mid-assembly into a SILENTLY TRUNCATED statement that was
/// then executed; the contract here is all-or-nothing — either the complete
/// statement list, or `error.OutOfMemory` with nothing leaked.
pub fn assembleStatements(
    gpa: std.mem.Allocator,
    contents: []const u8,
) error{OutOfMemory}![][]const u8 {
    var statements: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (statements.items) |stmt| gpa.free(stmt);
        statements.deinit(gpa);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(gpa);

    var line_iter = std.mem.splitSequence(u8, contents, "\n");
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        // Skip empty lines and comments
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "--")) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;

        // Append line to current statement
        if (current.items.len > 0) try current.append(gpa, ' ');
        try current.appendSlice(gpa, trimmed);

        // Check if statement is complete (ends with semicolon)
        if (std.mem.endsWith(u8, trimmed, ";")) {
            const stmt_copy = try gpa.dupe(u8, current.items);
            statements.append(gpa, stmt_copy) catch |err| {
                gpa.free(stmt_copy);
                return err;
            };
            current.clearRetainingCapacity();
        }
    }

    return statements.toOwnedSlice(gpa);
}

/// Classify an assembled statement as a bare `ROLLBACK` terminator.
///
/// Semicolon- and whitespace-tolerant, case-insensitive — mirroring the
/// normalization in `main.zig`'s `isTransactionEnd`: leading/trailing whitespace
/// is trimmed, then a trailing run of `; \t` is stripped before an
/// `eqlIgnoreCase` against "ROLLBACK". The file assembler keeps the trailing
/// `;` on every statement (see `assembleStatements`), so the oversized-rollback
/// guard in `executeChunkedQueries` must accept "ROLLBACK;" — not just the bare
/// "ROLLBACK" — or it silently auto-commits a transaction the user asked to roll
/// back (#830).
///
/// CANARY: REQ=REQ-CLI-CHUNKED-EXEC-009; FEATURE="ChunkedExecution"; ASPECT=RollbackGuard; STATUS=TESTED; TEST=tests/test_cli_file_chunked.zig; OWNER=cli; UPDATED=2026-08-31
pub fn isRollback(stmt: []const u8) bool {
    const trimmed = std.mem.trim(u8, stmt, " \t\r\n");
    const normalized = std.mem.trimEnd(u8, trimmed, "; \t");
    if (normalized.len == 0) return false;
    return std.ascii.eqlIgnoreCase(normalized, "ROLLBACK");
}

/// Release a slice returned by `assembleStatements`.
pub fn freeStatements(gpa: std.mem.Allocator, stmts: [][]const u8) void {
    for (stmts) |stmt| gpa.free(stmt);
    gpa.free(stmts);
}

// Unit cover for this seam lives in tests/test_cli_file_chunked.zig (the lane
// that already owns the `--file` contract); this module is imported there as
// `cli_query_file`, so the tests run where the rest of the contract is pinned.
