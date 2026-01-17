const std = @import("std");
const geode = @import("geode");
const ServerState = @import("server_state.zig").ServerState;
const mvcc = @import("txn/mvcc.zig");
const eval = geode.eval;
const wal_mod = @import("wal");
const protocol = geode.protocol;
const diagnostics = geode.diagnostics;
const server_flags = @import("server_flags.zig");

// CANARY: REQ=REQ-SERVER-REFACTOR-011; FEATURE="ServerRefactoring"; ASPECT=SERVER_UTILITIES; STATUS=EXEMPT; OWNER=refactor; UPDATED=2025-11-14
// Phase 3 M3.3 - Server Utilities Module (Seventh Increment)
// Extracted from server/main.zig to improve modularity and reduce main() function size
// Contains helper functions for MVCC, insert values, scan values, and error formatting

// Global MVCC manager instance (shared across connections)
var g_mvcc_manager: ?*mvcc.MVCCManager = null;

/// Get or create the global MVCC manager
pub fn getOrCreateMVCCManager(allocator: std.mem.Allocator) *mvcc.MVCCManager {
    if (g_mvcc_manager) |mgr| {
        return mgr;
    }

    const mgr = allocator.create(mvcc.MVCCManager) catch unreachable;
    mgr.* = mvcc.MVCCManager.init(allocator);
    g_mvcc_manager = mgr;
    return mgr;
}

/// Execute an INSERT VALUE statement
pub fn execInsertValue(state: *ServerState, expr_val: eval.Value) !void {
    var tmp: [128]u8 = undefined; // fixed buffer for small literals
    var fba = std.heap.FixedBufferAllocator.init(&tmp);
    var list = std.ArrayList(u8).initCapacity(fba.allocator(), 0) catch return; // no OOM propagation needed
    switch (expr_val) {
        .Int => |n| std.fmt.format(list.writer(fba.allocator()), "{d}", .{n}) catch {},
        .Bool => |b| list.appendSlice(fba.allocator(), if (b) "true" else "false") catch {},
        .Str => |s| {
            list.append(fba.allocator(), '"') catch {};
            list.appendSlice(fba.allocator(), s) catch {};
            list.append(fba.allocator(), '"') catch {};
        },
        else => list.appendSlice(fba.allocator(), "null") catch {},
    }
    const stored = try state.allocator.dupe(u8, list.items);
    const creator = if (state.active_txn) |tx| tx.id else 0; // autocommit txn id 0
    state.inserted_values.append(state.allocator, .{ .value = stored, .creator_txn = creator, .commit_ts = if (creator == 0) state.global_commit_ts else null }) catch {};
    // WAL logical insert record (best-effort) for transactional inserts (creator != 0)
    if (creator != 0) {
        if (state.wal_ptr) |wp| {
            const wptr: *wal_mod.Wal = @ptrCast(@alignCast(wp));
            _ = wptr.append(creator, .Insert, stored, stored.len) catch {};
        }
    }
}

/// Build result set for SCAN VALUES statement
pub fn buildScanValuesResult(state: *ServerState) !void {
    // Build schema: single column v STRING
    state.last_columns = &.{protocol.SchemaCol{ .name = "v", .type = "STRING" }};
    state.last_ordered = false;
    state.last_order_keys = &.{};
    // Build row fragments
    var rows = std.ArrayList([]const u8).initCapacity(state.allocator, state.inserted_values.items.len) catch return;
    const snapshot = if (state.active_txn != null) state.session_snapshot_ts else state.global_commit_ts;
    const reader_txn = if (state.active_txn) |tx| tx.id else 0;
    var idx: usize = 0;
    while (idx < state.inserted_values.items.len) : (idx += 1) {
        const rec = state.inserted_values.items[idx];
        const own_uncommitted = rec.creator_txn == reader_txn and rec.commit_ts == null and !rec.aborted;
        const committed_visible = if (rec.commit_ts) |cts| cts <= snapshot else false;
        const visible = own_uncommitted or committed_visible;
        if (!visible) continue;
        const val = rec.value;
        // Build row JSON manually to avoid fmt brace issues with Zig 0.15
        const row = state.allocator.alloc(u8, 5 + val.len) catch continue; // {"v": + value + }
        // Write {"v":
        if (row.len >= 5) {
            row[0] = '{';
            row[1] = '"';
            row[2] = 'v';
            row[3] = '"';
            row[4] = ':';
        }
        if (val.len > 0) @memcpy(row[5 .. 5 + val.len], val);
        // append closing }
        const resized = state.allocator.realloc(row, row.len + 1) catch row;
        if (resized.len > row.len) resized[resized.len - 1] = '}';
        const final_row = if (resized.len > row.len) resized else row; // fallback
        // ensure null terminator not required; treat slice as bytes
        const keep = final_row;
        // Append
        rows.append(state.allocator, keep) catch {
            state.allocator.free(keep);
            break;
        };
        rows.append(state.allocator, row) catch {
            state.allocator.free(row);
            break;
        };
    }
    state.page_items = rows.toOwnedSlice(state.allocator) catch &.{};
    state.page_index = 0;
    state.active_result = true;
}

/// Write error message with protocol flags to output file
pub fn writeErrorWithFlags(
    allocator: std.mem.Allocator,
    out_file: std.fs.File,
    code: diagnostics.Code,
    message: []const u8,
    anchor: []const u8,
    additional: []const []const u8,
    has_us001_any: bool,
) void {
    const F_PROPERTY_ORDER = "U:PropOrder=LexDecl";
    const F_ILLEGAL = "U:PropOrder=Illegal";
    const g_order_keys_expr = server_flags.getOrderKeysExpr();

    var flags_buf: [3][]const u8 = .{ if (g_order_keys_expr) F_PROPERTY_ORDER else F_ILLEGAL, "U:OrderTiebreak=LexJSON", "U:US001/enforced" };
    const flag_slice = if (has_us001_any) flags_buf[0..3] else flags_buf[0..2];
    // Storage corruption treated as class 58000 (data exception) instead of generic 02000.
    const status_override: ?[]const u8 = if (code == .StoragePageChecksum) "58000" else null;
    if (protocol.buildErrorLineWithFlagsCustomStatus(allocator, diagnostics.codeName(code), message, anchor, additional, flag_slice, status_override)) |line| {
        defer allocator.free(line);
        _ = out_file.write(line) catch {};
    } else |_| {}
}
