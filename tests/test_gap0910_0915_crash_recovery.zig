// CANARY: REQ=REQ-GAP-0915-LABEL-INDEX-CRASH-REBUILD; FEATURE="CrashRecovery"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0910_0915_crash_recovery.zig:1; OWNER=storage; UPDATED=2026-07-10
//
// Regression tests for:
//
//   GAP-0915 — "label index not rebuilt after an unclean crash". After a
//   SIGKILL crash + reopen, `MATCH (n:Label) RETURN count(n)` returned 0
//   while `MATCH (n) RETURN count(n)` returned the full committed set —
//   row data survives but the label-indexed MATCH path consults an index
//   that the unclean-crash reopen never rebuilt. (Distinct from the
//   graceful-path count fix in commit 9a255a83.)
//
//   GAP-0910 — "`labels(n), properties(n)` after crash+restart segfaults".
//   The projected label list / property map borrowed pointers into node
//   storage (labels() returned the node's own label slices; properties()
//   put the node's own key slices into the result map), so any deep free /
//   duplicate of the result touched node-owned or dangling hydration
//   memory. Both now duplicate into caller-owned memory.
//
// Crash simulation follows tests/test_security_wal_durability.zig: mutate,
// then abandon the store WITHOUT close/checkpoint
// (graph_store.abandonGlobalStoreForCrashSim) so the reopen exercises real
// page-store + WAL recovery. The crash phase allocates from an arena by
// design (a hard-killed process leaks everything).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn execIn(
    alloc: std.mem.Allocator,
    ctx: execution.ExecutionContext,
    query: []const u8,
) !execution.ExecutionResult {
    var parsed = try geode.parseGqlOptions(query, alloc, .{});
    defer parsed.deinit();
    return execution.executeStatementWithContext(alloc, parsed.program.statements[0], ctx);
}

fn firstInt(res: execution.ExecutionResult) !i64 {
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    return switch (res.rows[0][0]) {
        .Int => |i| i,
        else => error.ExpectedInt,
    };
}

test "GAP-0915/GAP-0910: unclean crash + reopen keeps labeled MATCH and labels()/properties() working" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    // ---------------- Phase A: seed, then hard-crash ----------------
    // Arena: everything the "killed process" held leaks by design.
    var crash_arena = std.heap.ArenaAllocator.init(allocator);
    defer crash_arena.deinit();
    const aa = crash_arena.allocator();

    {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, data_dir);
        _ = try graph_store.initGlobalStore(aa, data_dir);

        const catalog = try execution.ensureCatalogInstance(aa);
        var session = execution.SessionState.init(aa);
        var ctx = execution.ExecutionContext{ .catalog = catalog };
        ctx.session_state = &session;

        _ = try execIn(aa, ctx, "CREATE GRAPH crashg");
        _ = try execIn(aa, ctx, "USE GRAPH crashg");
        _ = try execIn(aa, ctx, "CREATE (:CrashL {v: 1})");
        _ = try execIn(aa, ctx, "CREATE (:CrashL {v: 2})");
        _ = try execIn(aa, ctx, "CREATE (:CrashL {v: 3})");
        _ = try execIn(aa, ctx, "CREATE (:CrashL {v: 4})");

        // Sanity before the crash: labeled count sees all four, and the
        // writes reached the engine (otherwise the crash sim is vacuous).
        {
            const res = try execIn(aa, ctx, "MATCH (n:CrashL) RETURN count(n)");
            try testing.expectEqual(@as(i64, 4), try firstInt(res));
        }
        {
            const ad = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
            const slots = try ad.getNodesByLabelCapped("crashg", "CrashL", null, aa);
            try testing.expectEqual(@as(usize, 4), slots.len);
        }

        // Hard crash: no close, no checkpoint, no catalog cleanup.
        graph_store.abandonGlobalStoreForCrashSim();
        execution.cleanupCatalogInstance();
    }

    // ---------------- Phase B: reopen and verify ----------------
    var reopen_arena = std.heap.ArenaAllocator.init(allocator);
    defer reopen_arena.deinit();
    const ra = reopen_arena.allocator();

    _ = try graph_store.initGlobalStore(ra, data_dir);
    defer {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    const catalog = try execution.ensureCatalogInstance(ra);
    var session = execution.SessionState.init(ra);
    var ctx = execution.ExecutionContext{ .catalog = catalog };
    ctx.session_state = &session;

    _ = try execIn(ra, ctx, "USE GRAPH crashg");

    // GAP-0915 (root): the engine label-scan path (the MATCH (n:Label)
    // source at scale) must see the four committed rows after the unclean
    // reopen — the raw deferred-derived posting list is empty until
    // ensureDerivedHydrated rebuilds it, and the label-scan path did not run
    // the guard.
    {
        const ad = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        const slots = try ad.getNodesByLabelCapped("crashg", "CrashL", null, ra);
        try testing.expectEqual(@as(usize, 4), slots.len);
    }

    // Behavioral checks mirror the live server, whose read paths hydrate the
    // graph before serving (the in-process exec harness needs the explicit
    // nudge the server's startup/read guards provide).
    graph_store.getGlobalStore(ra).ensureGraphHydrated("crashg");

    // Oracle: the committed rows survived (label-less scan).
    {
        const res = try execIn(ra, ctx, "MATCH (n) RETURN count(n)");
        try testing.expectEqual(@as(i64, 4), try firstInt(res));
    }

    // GAP-0915: the labeled count must see the same four rows.
    {
        const res = try execIn(ra, ctx, "MATCH (n:CrashL) RETURN count(n)");
        try testing.expectEqual(@as(i64, 4), try firstInt(res));
    }

    // GAP-0910: labels()/properties() after the unclean reopen must neither
    // crash nor return empty projections.
    {
        const res = try execIn(ra, ctx, "MATCH (n) RETURN labels(n), properties(n)");
        try testing.expectEqual(@as(usize, 4), res.rows.len);
        for (res.rows) |row| {
            switch (row[0]) {
                .List => |labels| {
                    try testing.expectEqual(@as(usize, 1), labels.len);
                    try testing.expectEqualStrings("CrashL", labels[0].Str);
                },
                else => return error.ExpectedLabelsList,
            }
            switch (row[1]) {
                .Map => |m| {
                    var map = m;
                    try testing.expect(map.get("v") != null);
                },
                else => return error.ExpectedPropertiesMap,
            }
        }
    }
}

test "GAP-0910: labels()/properties() projections own their memory (no borrowed node pointers)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
    graph_store.setDataDirOverride(allocator, data_dir);
    _ = try graph_store.initGlobalStore(aa, data_dir);
    defer {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    const catalog = try execution.ensureCatalogInstance(aa);
    var session = execution.SessionState.init(aa);
    var ctx = execution.ExecutionContext{ .catalog = catalog };
    ctx.session_state = &session;

    _ = try execIn(aa, ctx, "CREATE GRAPH owng");
    _ = try execIn(aa, ctx, "USE GRAPH owng");
    _ = try execIn(aa, ctx, "CREATE (:OwnL {k: 'val'})");

    // Project the node itself alongside labels()/properties(): the row's own
    // Node value is exactly the storage object the projections were built
    // from, so pointer equality against it detects borrowing precisely.
    const res = try execIn(aa, ctx, "MATCH (n:OwnL) RETURN n, labels(n), properties(n)");
    try testing.expectEqual(@as(usize, 1), res.rows.len);

    const node = switch (res.rows[0][0]) {
        .Node => |n| n,
        else => return error.ExpectedNode,
    };
    try testing.expectEqual(@as(usize, 1), node.labels.len);
    var node_key_ptr: ?[*]const u8 = null;
    {
        var pit = node.properties.iterator();
        while (pit.next()) |pe| {
            if (std.mem.eql(u8, pe.key_ptr.*, "k")) node_key_ptr = pe.key_ptr.*.ptr;
        }
    }
    try testing.expect(node_key_ptr != null);

    // labels(n): the projected strings must be copies, not the node's slices.
    switch (res.rows[0][1]) {
        .List => |labels| {
            try testing.expectEqual(@as(usize, 1), labels.len);
            try testing.expectEqualStrings("OwnL", labels[0].Str);
            try testing.expect(labels[0].Str.ptr != node.labels[0].ptr);
        },
        else => return error.ExpectedLabelsList,
    }

    // properties(n): the projected map keys must be copies, not the node's.
    switch (res.rows[0][2]) {
        .Map => |m| {
            var map = m;
            var it = map.iterator();
            var saw_k = false;
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "k")) {
                    saw_k = true;
                    try testing.expect(entry.key_ptr.*.ptr != node_key_ptr.?);
                }
            }
            try testing.expect(saw_k);
        },
        else => return error.ExpectedPropertiesMap,
    }
}
