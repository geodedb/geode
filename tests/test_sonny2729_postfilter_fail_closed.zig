// SONNY-2729 part (1) regression: the transport RLS post-filter fails CLOSED.
//
// `rls_filter.applyRLSFilter`, `applyAlgorithmRLSFilter` and
// `applyRLSToFederatedResults` snapshot the session's denied labels before
// they scan the rows. When that allocation failed they returned 0 and left
// every row in place, unfiltered, and both handlers returned those rows. The
// executor filters first (SONNY-2679), so the post-filter is the second layer,
// but a filter that cannot run must not pass what it did not check.
//
// Now a filter that cannot run withholds every row of the result and returns
// error.RowSecurityFilterUnavailable, and both handlers answer with that
// error (53200) instead of the rows. The same holds when the filter cannot
// allocate the result's shorter row list: the filter used to shorten the
// list in place with a swap-remove, which reordered the rows and left
// `ExecutionResult.deinit` freeing the list with the wrong length; it now
// keeps the rows' order and reallocates the list.
//
// Each filter runs here under a failing allocator at every allocation point:
// until the allocations succeed it must return the error with no row left;
// then it must filter exactly. Leak-checked by the testing allocator.
//
// Part (2), one label-deny engine instead of two, is v0.8.24.
//
// CANARY: REQ=REQ-SONNY-2729-POSTFILTER-FAIL-CLOSED; FEATURE="RLS Query Enforcement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2729_postfilter_fail_closed.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_filter = @import("grpc_impl").rls_filter;

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

const FailingAllocator = std.testing.FailingAllocator;

/// The filters under test, called through one signature: before this fix
/// they returned a plain count, now an error union.
fn labelFilter(a: std.mem.Allocator, result: *execution.ExecutionResult, engine: *rls_filter.RLSFilterEngine) anyerror!usize {
    return rls_filter.applyRLSFilter(a, result, engine, "alice", "default");
}

fn algorithmFilter(a: std.mem.Allocator, result: *execution.ExecutionResult, engine: *rls_filter.RLSFilterEngine, store: *graph_store.GraphStore) anyerror!usize {
    return rls_filter.applyAlgorithmRLSFilter(a, result, engine, store, "alice", "default");
}

/// Rows [who, payload]: `who` is a node (borrowed), `payload` a string the
/// result owns, so a row the filter drops without freeing shows as a leak.
fn nodeRows(nodes: []const *const graph_store.Node) !execution.ExecutionResult {
    const a = testing.allocator;
    const columns = try a.alloc([]const u8, 2);
    columns[0] = try a.dupe(u8, "who");
    columns[1] = try a.dupe(u8, "payload");
    const rows = try a.alloc([]Value, nodes.len);
    for (nodes, 0..) |node, i| {
        rows[i] = try a.alloc(Value, 2);
        rows[i][0] = .{ .Node = node };
        rows[i][1] = .{ .Str = try std.fmt.allocPrint(a, "row-{d}", .{i}) };
    }
    return .{ .columns = columns, .rows = rows, .flags = .empty, .owns_value_memory = true };
}

/// Rows [nodeId, score], as an algorithm returns them.
fn idRows(ids: []const u64) !execution.ExecutionResult {
    const a = testing.allocator;
    const columns = try a.alloc([]const u8, 2);
    columns[0] = try a.dupe(u8, "nodeId");
    columns[1] = try a.dupe(u8, "score");
    const rows = try a.alloc([]Value, ids.len);
    for (ids, 0..) |id, i| {
        rows[i] = try a.alloc(Value, 2);
        rows[i][0] = .{ .Int = @intCast(id) };
        rows[i][1] = .{ .Str = try std.fmt.allocPrint(a, "score-{d}", .{i}) };
    }
    return .{ .columns = columns, .rows = rows, .flags = .empty, .owns_value_memory = true };
}

/// One outcome of a filter run under a failing allocator. With an induced
/// failure, the filter must return the error with no row left; otherwise it
/// must keep exactly `want` (payloads, in order). True once it succeeded.
fn checkOutcome(failing: *const FailingAllocator, outcome: anyerror!usize, result: *const execution.ExecutionResult, want: []const []const u8) !bool {
    if (failing.has_induced_failure) {
        if (outcome) |kept_count| {
            std.debug.print("allocation {d} failed, yet the filter returned {d} and {d} rows\n", .{ failing.alloc_index, kept_count, result.rows.len });
            return error.FilterFailedOpen;
        } else |err| try testing.expectEqual(error.RowSecurityFilterUnavailable, err);
        try testing.expectEqual(@as(usize, 0), result.rows.len);
        return false;
    }
    _ = try outcome;
    try testing.expectEqual(want.len, result.rows.len);
    for (want, result.rows) |payload, row| try testing.expectEqualStrings(payload, row[1].Str);
    return true;
}

test "SONNY-2729: applyRLSFilter withholds every row, and errs, at every allocation it cannot make" {
    var engine = rls_filter.RLSFilterEngine.init(testing.allocator);
    defer engine.deinit();
    try engine.addDenyPolicy("default", "Secret", "alice");
    try engine.addDenyPolicy("default", "TopSecret", "");

    var secret_labels = [_][]const u8{"Secret"};
    var public_labels = [_][]const u8{"Public"};
    const secret = graph_store.Node{ .id = 1, .labels = &secret_labels, .properties = graph_store.CompactPropertyMap.init(testing.allocator) };
    const public = graph_store.Node{ .id = 2, .labels = &public_labels, .properties = graph_store.CompactPropertyMap.init(testing.allocator) };
    const nodes = [_]*const graph_store.Node{ &secret, &public, &secret, &public, &public };
    const want = [_][]const u8{ "row-1", "row-3", "row-4" };

    // Twice: with in-place shrinking allowed, and with every remap refused,
    // so the shorter row list must be allocated (and that can fail too).
    for ([_]usize{ std.math.maxInt(usize), 0 }) |resize_fail_index| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            if (fail_index > 64) return error.NeverSucceeded;
            var result = try nodeRows(&nodes);
            defer result.deinit(testing.allocator);
            var failing = FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = resize_fail_index });
            const outcome = labelFilter(failing.allocator(), &result, &engine);
            if (try checkOutcome(&failing, outcome, &result, &want)) break;
        }
    }
}

test "SONNY-2729: applyAlgorithmRLSFilter withholds every row, and errs, at every allocation it cannot make" {
    var engine = rls_filter.RLSFilterEngine.init(testing.allocator);
    defer engine.deinit();
    try engine.addDenyPolicy("default", "Secret", "alice");

    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    const secret_id = try store.createNode(&[_][]const u8{"Secret"});
    const public_id = try store.createNode(&[_][]const u8{"Public"});
    const ids = [_]u64{ public_id, secret_id, public_id, secret_id };
    const want = [_][]const u8{ "score-0", "score-2" };

    for ([_]usize{ std.math.maxInt(usize), 0 }) |resize_fail_index| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            if (fail_index > 64) return error.NeverSucceeded;
            var result = try idRows(&ids);
            defer result.deinit(testing.allocator);
            var failing = FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = resize_fail_index });
            const outcome = algorithmFilter(failing.allocator(), &result, &engine, &store);
            if (try checkOutcome(&failing, outcome, &result, &want)) break;
        }
    }
}

const FedRow = struct { cols: []const Value };
const FedResults = struct { rows: []const FedRow };

fn federationFilter(a: std.mem.Allocator, results: *FedResults, engine: *rls_filter.RLSFilterEngine) anyerror!usize {
    return rls_filter.applyRLSToFederatedResults(a, results, engine, "alice", "default");
}

test "SONNY-2729: applyRLSToFederatedResults errs, and passes no row, when it cannot snapshot the policies" {
    var engine = rls_filter.RLSFilterEngine.init(testing.allocator);
    defer engine.deinit();
    try engine.addDenyPolicy("default", "Secret", "alice");

    var secret_labels = [_][]const u8{"Secret"};
    var public_labels = [_][]const u8{"Public"};
    const secret = graph_store.Node{ .id = 1, .labels = &secret_labels, .properties = graph_store.CompactPropertyMap.init(testing.allocator) };
    const public = graph_store.Node{ .id = 2, .labels = &public_labels, .properties = graph_store.CompactPropertyMap.init(testing.allocator) };
    const cols = [_][1]Value{ .{.{ .Node = &public }}, .{.{ .Node = &secret }}, .{.{ .Node = &public }} };

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        if (fail_index > 64) return error.NeverSucceeded;
        var rows = [_]FedRow{ .{ .cols = &cols[0] }, .{ .cols = &cols[1] }, .{ .cols = &cols[2] } };
        var results = FedResults{ .rows = &rows };
        var failing = FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const outcome = federationFilter(failing.allocator(), &results, &engine);
        if (failing.has_induced_failure) {
            // The caller withholds the rows (federation.zig frees the merged
            // result and fails the query); the filter must say it did not run.
            try testing.expectError(error.RowSecurityFilterUnavailable, outcome);
            continue;
        }
        try testing.expectEqual(@as(usize, 1), try outcome);
        // The rows kept keep their order.
        try testing.expectEqual(@as(usize, 2), results.rows.len);
        try testing.expect(results.rows[0].cols[0].Node == &public);
        try testing.expect(results.rows[1].cols[0].Node == &public);
        break;
    }
}

/// `path` from the repository root (the build runs tests there).
fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, allocator, .unlimited);
}

/// Every call of a post-filter in `src` answers its error with `answer`, and
/// there are `want` of them.
fn expectEveryCallAnswers(src: []const u8, answer: []const u8, want: usize) !void {
    var calls: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "rls_filter.apply") orelse continue;
        if (std.mem.indexOf(u8, line[0..at], "//") != null) continue;
        calls += 1;
        if (std.mem.indexOf(u8, line, answer) == null) {
            std.debug.print("a post-filter result is not answered: {s}\n", .{std.mem.trim(u8, line, " ")});
            return error.PostFilterFailsOpen;
        }
    }
    try testing.expectEqual(want, calls);
}

test "SONNY-2729: both handlers answer a post-filter that cannot run with its error (source text)" {
    const quic = try readSource(testing.allocator, "src/server/quic_connection_handler.zig");
    defer testing.allocator.free(quic);
    try expectEveryCallAnswers(quic, "catch |err| return sendPostFilterError(gpa, stream, err);", 5);

    const grpc = try readSource(testing.allocator, "src/transport/grpc_server.zig");
    defer testing.allocator.free(grpc);
    try expectEveryCallAnswers(grpc, "catch |err| return postFilterErrorResponse(allocator, err);", 5);

    // The federation filter, and its callback, fail the query too.
    const fed = try readSource(testing.allocator, "src/distributed/federation.zig");
    defer testing.allocator.free(fed);
    try testing.expect(std.mem.indexOf(u8, fed, "break :blk merged_results.rows") == null);
    try expectEveryCallAnswers(fed, "catch |err| {", 1);
}
