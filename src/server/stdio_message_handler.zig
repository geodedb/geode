const std = @import("std");
const geode = @import("geode");
const protocol = geode.protocol;
const diagnostics = geode.diagnostics;
const ServerState = @import("server_state.zig").ServerState;
const transaction_handlers = @import("transaction_handlers.zig");
const message_handlers = @import("message_handlers.zig");
const protocol_handler = @import("protocol_handler.zig");
const quic_connection_handler = @import("quic_connection_handler.zig");
const server_flags = @import("server_flags.zig");
const server_utilities = @import("server_utilities.zig");
const query_executor = @import("query_executor.zig");

// CANARY: REQ=REQ-SERVER-REFACTOR-013; FEATURE="ServerRefactoring"; ASPECT=STDIO_HANDLER; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.3 - Stdio Message Handler Module (Twelfth Increment)
// Unified message processing for stdio mode, delegating to existing handlers and eliminating duplication

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-015; FEATURE="Structured Logging"; ASPECT=StdioHandler; STATUS=IMPL; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-014; FEATURE="JSON Library Migration"; ASPECT=StdioHandler; STATUS=TESTED; OWNER=server; UPDATED=2026-01-24
const json_lib = @import("json");

const computeBaseFlags = server_flags.computeBaseFlags;
const writeBindingsAdaptive = query_executor.writeBindingsAdaptive;

/// Error response type for stdio message handling
const StdioErrorResponse = struct {
    status_class: []const u8 = "58000",
    @"error": []const u8,
};

/// Process a parsed protocol message in stdio mode and write the response to stdout
/// This is a wrapper around the existing quic_connection_handler.processMessage that
/// handles stdio-specific concerns like writing to stdout_file.
///
/// Returns true to continue processing messages, false to break the loop.
pub fn processStdioMessage(
    gpa: std.mem.Allocator,
    state: *ServerState,
    msg: protocol.ClientMessage,
    stdout_file: std.fs.File,
    result_format_txt: bool,
    disable_estimates: bool,
    compact_profile: bool,
    memcurve_profile: bool,
    env_wal_compact_interval: usize,
    raw_line: []const u8,
) bool {
    switch (msg) {
        .HELLO => |_| {
            // No-op HELLO on stdio (authentication not required for stdio mode)
            return true;
        },
        .CDC_DIAGNOSTICS => |_| {
            if (message_handlers.handleCdcDiagnostics(gpa, state)) |line| {
                defer gpa.free(line);
                _ = stdout_file.write(line) catch {};
            }
            return true;
        },
        .CDC_CONTROL => |cc| {
            if (message_handlers.handleCdcControl(gpa, state, cc.action)) |out_line| {
                defer gpa.free(out_line);
                _ = stdout_file.write(out_line) catch {};
            }
            return true;
        },
        .BEGIN => |_| {
            const response = transaction_handlers.handleBegin(gpa, state) catch return true;
            if (response) |resp| {
                defer gpa.free(resp);
                _ = stdout_file.write(resp) catch {};
            }
            return true;
        },
        .SAVEPOINT => |sp| {
            _ = sp; // prototype: no actual stack; future store sp.name
            // ACK
            writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
            return true;
        },
        .ROLLBACK_TO => |sp| {
            _ = sp; // prototype: ignore
            writeBindingsAdaptive(stdout_file, false, &.{}, "[]", true, false, computeBaseFlags(false, false));
            return true;
        },
        .PING => |_| {
            // Simple health check
            const ok = "{\"ok\":true}";
            if (protocol.buildBindingsLine(gpa, false, &.{}, ok, true, &.{}, computeBaseFlags(false, false))) |line| {
                defer gpa.free(line);
                _ = stdout_file.write(line) catch {};
            } else |_| {}
            return true;
        },
        .COMMIT => |_| {
            const response = transaction_handlers.handleCommit(gpa, state, env_wal_compact_interval) catch return true;
            if (response) |resp| {
                defer gpa.free(resp);
                _ = stdout_file.write(resp) catch {};
            }
            return true;
        },
        .ROLLBACK => |_| {
            const response = transaction_handlers.handleRollback(gpa, state) catch return true;
            if (response) |resp| {
                defer gpa.free(resp);
                _ = stdout_file.write(resp) catch {};
            }
            return true;
        },
        .RUN_GQL, .PULL, .BACKUP, .RESTORE, .UPLOAD_BACKUP => {
            // For these message types, delegate to quic_connection_handler.processMessage
            // which has the complete implementation, then write the result to stdout
            const response = quic_connection_handler.processMessage(
                gpa,
                state,
                raw_line,
                result_format_txt,
                disable_estimates,
                compact_profile,
                memcurve_profile,
            ) catch |err| {
                // Write error to stdout using JSON library for proper encoding
                const err_response = StdioErrorResponse{ .@"error" = @errorName(err) };
                const json_str = json_lib.encode(gpa, err_response, .{}) catch return true;
                defer gpa.free(json_str);

                // Write JSON with newline
                _ = stdout_file.write(json_str) catch {};
                _ = stdout_file.write("\n") catch {};
                return true;
            };
            defer if (response.len > 0) gpa.free(response);

            if (response.len > 0) {
                _ = stdout_file.write(response) catch {};
            }
            return true;
        },
    }
}
