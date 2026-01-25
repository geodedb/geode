const std = @import("std");
const geode = @import("geode");
const protocol = geode.protocol;
const ServerState = @import("server_state.zig").ServerState;
const TextFormatter = @import("text_formatter").TextFormatter;
const query_executor = @import("query_executor.zig");
const server_flags = @import("server_flags.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-011; FEATURE="Structured Logging"; ASPECT=MessageHandlers; STATUS=EXEMPT; OWNER=server; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("server");
const Attr = logging.Attr;

// CANARY: REQ=REQ-SERVER-REFACTOR-010; FEATURE="ServerRefactoring"; ASPECT=MESSAGE_HANDLERS; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.2 - Message Handlers Module (Sixth Increment)
// Extracted from server/main.zig to improve modularity and reduce main() function size
// Handles CDC_DIAGNOSTICS, CDC_CONTROL, and PULL message types

/// Handle CDC_DIAGNOSTICS message
/// Returns protocol line (caller must free) or null if error
pub fn handleCdcDiagnostics(allocator: std.mem.Allocator, state: *ServerState) ?[]const u8 {
    if (state.cdc_engine) |eng| {
        if (eng.exportDiagnostics(allocator)) |payload| {
            defer allocator.free(payload);
            if (protocol.buildCdcDiagnosticsLine(allocator, payload)) |line| {
                return line;
            } else |_| {}
        } else |_| {
            if (protocol.buildCdcDiagnosticsLine(allocator, "{\"cdc_error\":\"export_failed\"}")) |line| {
                return line;
            } else |_| {}
        }
    } else {
        if (protocol.buildCdcDiagnosticsLine(allocator, "{\"cdc\":{\"enabled\":false}}")) |line| {
            return line;
        } else |_| {}
    }
    return null;
}

/// Handle CDC_CONTROL message
/// Returns protocol line (caller must free) or null if error
pub fn handleCdcControl(allocator: std.mem.Allocator, state: *ServerState, action: []const u8) ?[]u8 {
    if (state.cdc_engine) |eng| {
        if (std.ascii.eqlIgnoreCase(action, "RESET_GUARDRAILS")) {
            eng.resetGuardrailState();
            return protocol.buildCdcControlLine(allocator, action, "OK", eng.guardrail_epoch) catch null;
        } else {
            return protocol.buildCdcControlLine(allocator, action, "UNSUPPORTED", eng.guardrail_epoch) catch null;
        }
    } else {
        return protocol.buildCdcControlLine(allocator, action, "NO_ENGINE", 0) catch null;
    }
}

/// Handle PULL message - paginate result sets or emit PROFILE data
/// Takes result_format_txt to determine output format
/// Writes directly to the provided file handle
/// Returns true if successful, false if error (caller should continue)
pub fn handlePull(
    allocator: std.mem.Allocator,
    state: *ServerState,
    page_size_param: usize,
    result_format_txt: bool,
    stdout_file: std.fs.File,
) !bool {
    // Check for active result
    if (!state.active_result and state.profile_json == null) {
        const nrline = protocol.buildErrorLine(allocator, "NoResult", "no active result set", "") catch null;
        if (nrline) |l| {
            defer allocator.free(l);
            _ = stdout_file.write(l) catch {};
        }
        return false; // Signal to continue
    }

    // If PROFILE staged, emit PROFILE frame and clear profile_json; no rows to paginate.
    if (state.profile_json) |pj| {
        const dup_pj = allocator.dupe(u8, pj) catch pj;

        if (result_format_txt) {
            // Text format output for PROFILE
            var formatter = TextFormatter.init(allocator);
            const txt = formatter.formatProfile(dup_pj) catch dup_pj;
            defer if (txt.ptr != dup_pj.ptr) allocator.free(txt);
            _ = stdout_file.write(txt) catch {};
            _ = stdout_file.write("\n") catch {};
        } else {
            // JSON format output
            const pline = protocol.buildProfileLine(allocator, dup_pj, state.profile_flags) catch null;
            if (pline) |plj| {
                defer allocator.free(plj);
                _ = stdout_file.write(plj) catch {};
            }
            // silent on failure to build profile line
        }

        // PROFILE complete; clear state and mark no active result
        state.allocator.free(pj);
        state.profile_json = null;
        state.profile_flags = &.{};
        state.active_result = false;
        return false; // Signal to continue
    }

    // Paginate result set
    const page_size = if (page_size_param == 0) 1000 else page_size_param;
    const start = state.page_index;
    const end = @min(state.page_index + page_size, state.page_items.len);
    var arr_buf = std.ArrayList(u8).initCapacity(allocator, 0) catch @panic("OOM");
    const w = arr_buf.writer(allocator);
    w.writeAll("[") catch {};
    var i: usize = start;
    var first = true;
    while (i < end) : (i += 1) {
        if (!first) w.writeAll(",") catch {};
        first = false;
        w.writeAll(state.page_items[i]) catch {};
    }
    w.writeAll("]") catch {};
    const json_rows = arr_buf.toOwnedSlice(allocator) catch "[]";
    state.page_index = end;
    const is_final = end >= state.page_items.len;
    if (is_final) state.active_result = false;
    const include_final = (state.page_items.len > 1) or (page_size < state.page_items.len);

    // Emit telemetry if enabled
    if (state.telemetry_paging) {
        var ps_buf: [32]u8 = undefined;
        const ps_str = std.fmt.bufPrint(&ps_buf, "{d}", .{page_size}) catch "0";
        var rows_buf: [32]u8 = undefined;
        const rows_str = std.fmt.bufPrint(&rows_buf, "{d}", .{end - start}) catch "0";
        log.info("telemetry", &.{
            Attr.string("type", "TELEMETRY"),
            Attr.string("event", "PULL_PAGE"),
            Attr.string("page_size", ps_str),
            Attr.string("rows_emitted", rows_str),
            Attr.string("final", if (is_final) "true" else "false"),
        });
    }

    // Write bindings adaptive
    query_executor.writeBindingsAdaptive(
        stdout_file,
        state.last_ordered,
        state.last_order_keys,
        json_rows,
        is_final,
        include_final,
        server_flags.computeBaseFlags(state.last_ordered, state.last_distinct),
    );

    return true;
}
