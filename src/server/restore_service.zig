//! Shared QUIC/gRPC restore implementation. Transport entry points must perform
//! current-session Admin authorization before calling handle, including polls.
const std = @import("std");
const schema = @import("schema");
const graph_store = @import("../graph_store.zig");
const jobs = @import("restore_jobs.zig");
const cluster = @import("../distributed/cluster.zig");
const audit = @import("../security/audit.zig");

var installed: ?*jobs.Manager = null;
var install_mutex: std.Io.Mutex = .init;

/// Install before admitting connections; uninstall after draining requests.
/// The owner must preserve the manager and source store through shutdown.
pub fn install(current_manager: ?*jobs.Manager) void {
    install_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer install_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    installed = current_manager;
}

fn manager() !*jobs.Manager {
    install_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer install_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    return installed orelse error.RestoreServiceUnavailable;
}

pub fn shutdown() void {
    if (manager()) |current| current.shutdown() else |_| {}
}

fn response(allocator: std.mem.Allocator, status: jobs.Snapshot) !schema.RestoreResponse {
    errdefer status.deinit(allocator);
    const state = try allocator.dupe(u8, @tagName(status.state));
    errdefer allocator.free(state);
    const phase = try allocator.dupe(u8, @tagName(status.progress.phase));
    errdefer allocator.free(phase);
    const message = switch (status.state) {
        .queued, .running => try allocator.dupe(u8, "Restore pending; poll job_id for progress. The server still serves its current data."),
        .completed => try std.fmt.allocPrint(allocator, "Restore verified and staged. The server still serves its current data; restart with --data-dir {s} to use the restored copy.", .{status.restore_dir}),
        .failed => try std.fmt.allocPrint(allocator, "Restore failed: {s}", .{status.error_name}),
    };
    // Transfer owned snapshot strings into the response. All other fields are
    // owned copies too, so normal protobuf deinitialization is sufficient.
    return .{ .success = status.state == .completed, .message = message, .restore_dir = status.restore_dir, .job_id = status.job_id, .job_state = state, .phase = phase, .completed_files = status.progress.completed_files, .total_files = status.progress.total_files, .restore_timestamp = status.finished_at_ms };
}

// CANARY: REQ=REQ-SONNY-6300; FEATURE="Restore jobs"; ASPECT=SharedTransport; STATUS=TESTED; TEST=tests/test_sonny6300_restore_transport.zig; OWNER=storage; UPDATED=2026-11-11
pub fn handle(allocator: std.mem.Allocator, request: schema.RestoreRequest, username: []const u8) !schema.RestoreResponse {
    const current = try manager();
    if (request.job_id.len > 0) return response(allocator, try current.get(allocator, request.job_id));
    if (!request.confirm) return error.RestoreRequiresConfirmation;
    try cluster.gateUnreplicatedWrite();
    const target_time: i64 = if (request.target_time.len > 0)
        std.fmt.parseInt(i64, request.target_time, 10) catch return error.InvalidRestoreTime
    else
        std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
    const adapter = graph_store.getGlobalAdapter() orelse return error.StorageNotInitialized;
    // Jobs outlive requests; never borrow a thread's query-read snapshot.
    const store = graph_store.getLiveGlobalStore(allocator);
    const status = if (request.async_restore)
        try current.start(allocator, store, "./server_backups", adapter.data_dir, target_time)
    else
        try current.startAndWait(allocator, store, "./server_backups", adapter.data_dir, target_time);
    // Synchronous callers retain completion semantics and pin their result
    // until it has been returned; async acceptance is never success.
    const detail = std.fmt.allocPrint(allocator, "job {s}: {s}; live data unchanged", .{ status.job_id, @tagName(status.state) }) catch null;
    defer if (detail) |owned| allocator.free(owned);
    audit.logSecurityGraphEvent(allocator, .{ .event_type = .configuration_change, .action = "SERVER_RESTORE", .username = username, .details = detail orelse "offline restore requested; live data unchanged", .result_failure = status.state == .failed });
    return response(allocator, status);
}
