// SONNY-6528 (4): a quarantined graph (REQ-GQL-028: its first-touch
// hydration found its store damaged) refuses reads to the callers that do
// not come through the QUIC or gRPC transports too: the executor called in
// process (the embedded and test entry points) and the store's schema
// listings the LSP schema provider calls directly.
//
// SONNY-6523 checks a program's graph in the transports
// (`programQuarantineError`). Below them, the store notes a quarantined graph
// for the executor only when a read passes the hydration chokepoint
// (`ensureGraphHydrated`), and two families of reads did not:
//   * the cross-graph schema listings (`listNodeLabels`, `listEdgeTypes`,
//     `listPropertiesForLabel`: db.labels(), db.relationshipTypes(),
//     db.propertyKeys(), SHOW TABLES, the LSP schema provider) hydrate
//     through `ensureAllGraphsHydrated`, which skipped every graph whose
//     hydration had run, a failed one included, and answered from its
//     partial label maps;
//   * `geode.fts.search` (and phrase / proximity) read the fulltext engine
//     and never asked whether the graph was quarantined.
//
// The store is damaged as in test-sonny6523-quarantine-fail-closed (every
// written page of every shard's nodes.store zeroed, the derived-index
// snapshots removed), here by an in-process store that seeded it and closed
// cleanly. Each read shape runs against its own copy of the damaged store,
// after a statement has found the damage, twice; none may answer. The
// listings, called directly, must fail. DROP GRAPH of a quarantined graph
// runs, the listings then answer again, and CREATE GRAPH of the name makes a
// fresh, empty graph.
//
// CANARY: REQ=REQ-SONNY-6528-QUARANTINE-IN-PROCESS; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6528_quarantine_in_process.zig; OWNER=storage; UPDATED=2026-11-14

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;

const PAGE_SIZE: u64 = 8192;
const NODES: usize = 120;
const EDGES: usize = 40;
const G = "g6528";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn run(argv: []const []const u8) !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const r = try std.process.run(std.testing.allocator, threaded.io(), .{ .argv = argv });
    std.testing.allocator.free(r.stdout);
    std.testing.allocator.free(r.stderr);
    switch (r.term) {
        .exited => |c| if (c != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

const Outcome = union(enum) { rows: usize, failed: anyerror };

fn ask(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) Outcome {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);
    var parsed = geode.parseGql(q, allocator) catch |err| return .{ .failed = err };
    defer parsed.deinit();
    const catalog = execution.ensureCatalogInstance(allocator) catch |err| return .{ .failed = err };
    var result = execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog, .session_state = session }) catch |err| return .{ .failed = err };
    defer result.deinit(allocator);
    return .{ .rows = result.rows.len };
}

fn queryOk(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) !void {
    switch (ask(allocator, session, q)) {
        .rows => {},
        .failed => |err| {
            std.debug.print("'{s}' failed: {s}\n", .{ q, @errorName(err) });
            return err;
        },
    }
}

fn isQuarantineError(err: anyerror) bool {
    return err == error.DataCorruption or err == error.ChecksumMismatch or
        err == error.InvalidData or err == error.GraphQuarantined;
}

/// Zero every written page of every nodes.store under `data_dir`; remove the
/// loop2 hydration snapshots and empty labels.idx, so the reopen's hydration
/// rebuilds from the damaged node store and fails (DataCorruption).
fn damage(data_dir: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io(), data_dir, .{ .iterate = true });
    defer dir.close(io());
    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();
    var zeroed: usize = 0;
    var snapshots: std.ArrayList([]u8) = .empty;
    defer {
        for (snapshots.items) |p| std.testing.allocator.free(p);
        snapshots.deinit(std.testing.allocator);
    }
    while (try walker.next(io())) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.basename, "labels.idx")) {
            var file = try entry.dir.openFile(io(), entry.basename, .{ .mode = .read_write });
            defer file.close(io());
            try file.setLength(io(), 0);
            continue;
        }
        if (std.mem.startsWith(u8, entry.basename, "hydration_") and std.mem.endsWith(u8, entry.basename, ".snap")) {
            try snapshots.append(std.testing.allocator, try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ data_dir, entry.path }));
            continue;
        }
        if (!std.mem.eql(u8, entry.basename, "nodes.store")) continue;
        var file = try entry.dir.openFile(io(), entry.basename, .{ .mode = .read_write });
        defer file.close(io());
        const len = try file.length(io());
        var page: u64 = 0;
        while ((page + 1) * PAGE_SIZE <= len) : (page += 1) {
            var header: [32]u8 = undefined;
            _ = try file.readPositionalAll(io(), &header, page * PAGE_SIZE);
            if (std.mem.allEqual(u8, &header, 0)) continue;
            const zeros = [_]u8{0} ** PAGE_SIZE;
            try file.writePositionalAll(io(), &zeros, page * PAGE_SIZE);
            zeroed += 1;
        }
    }
    for (snapshots.items) |p| try std.Io.Dir.cwd().deleteFile(io(), p);
    return zeroed;
}

/// A read that hydrates the graph: it finds the damage, and the graph is
/// quarantined from then on.
const discover = "MATCH (n:P) RETURN n.name AS name";

const read_shapes = [_][]const u8{
    "MATCH (n:P) RETURN count(n) AS c",
    "MATCH (n) RETURN count(n) AS c",
    "MATCH (n) RETURN count(*) AS c",
    "MATCH ()-[r:R]->() RETURN count(r) AS c",
    "MATCH ()-[r]->() RETURN count(r) AS c",
    "MATCH (n:P) WHERE n.i >= 0 RETURN count(n) AS c",
    "MATCH (n:P) WHERE n.name = 'p-00007' RETURN count(n) AS c",
    "MATCH (n:P) WHERE n.name = 'p-00007' RETURN n.i AS i",
    "MATCH (n:P {name: 'p-00008'}) RETURN n.i AS i",
    "MATCH (n:P) RETURN n.name AS name ORDER BY n.name LIMIT 3",
    "MATCH (n:P) RETURN n.i AS i ORDER BY n.i DESC LIMIT 1",
    "MATCH (n:P) RETURN n.name AS name",
    "MATCH (n) RETURN n.name AS name",
    "MATCH (a:P)-[r:R]->(b) RETURN r.w AS w",
    "MATCH (n:P) RETURN max(n.i) AS m",
    "CALL db.labels()",
    "CALL db.relationshipTypes()",
    "CALL db.propertyKeys()",
    "SHOW TABLES",
    "CALL geode.fts.search('p_body', 'alpha')",
    "CREATE (:P {name: 'new-1', i: 1000})",
    "MERGE (:P {name: 'p-00003'})",
    "MATCH (n:P) WHERE n.name = 'p-00004' SET n.i = 7",
};

/// The schema listings as the LSP schema provider calls them (no executor).
const Listing = enum { labels, edge_types, property_keys };

fn listing(allocator: std.mem.Allocator, store: *graph_store.GraphStore, which: Listing, tenant: ?[]const u8) !usize {
    const items = switch (which) {
        .labels => try store.listNodeLabels(allocator, tenant),
        .edge_types => try store.listEdgeTypes(allocator, tenant),
        .property_keys => try store.listPropertiesForLabel(allocator, tenant, "P"),
    };
    defer {
        for (items) |s| allocator.free(s);
        allocator.free(items);
    }
    return items.len;
}

fn seed(allocator: std.mem.Allocator, data_dir: []const u8, with_default: bool) !void {
    _ = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    var session = execution.SessionState.init(allocator);
    defer session.deinit();
    if (with_default) {
        for (0..NODES) |i| {
            var qb: [160]u8 = undefined;
            const body = if (i % 2 == 0) "alpha beta" else "gamma delta";
            try queryOk(allocator, &session, try std.fmt.bufPrint(&qb, "CREATE (:P {{name: 'p-{d:0>5}', i: {d}, body: '{s}'}})", .{ i, i, body }));
        }
        for (0..EDGES) |i| {
            var qb: [200]u8 = undefined;
            try queryOk(allocator, &session, try std.fmt.bufPrint(&qb, "MATCH (a:P {{name: 'p-{d:0>5}'}}), (b:P {{name: 'p-{d:0>5}'}}) CREATE (a)-[:R {{w: {d}}}]->(b)", .{ i, i + 1, i }));
        }
        try queryOk(allocator, &session, "CREATE INDEX p_name FOR (n:P) ON (n.name)");
        try queryOk(allocator, &session, "CREATE INDEX p_body FOR (n:P) ON (n.body) USING fulltext");
        // Every read shape answers on the healthy store.
        for (read_shapes) |q| {
            if (std.mem.startsWith(u8, q, "CREATE") or std.mem.startsWith(u8, q, "MERGE") or std.mem.indexOf(u8, q, " SET ") != null) continue;
            switch (ask(allocator, &session, q)) {
                .rows => |n| if (n == 0) {
                    std.debug.print("healthy store: '{s}' returned no rows\n", .{q});
                    return error.HealthyShapeEmpty;
                },
                .failed => |err| {
                    std.debug.print("healthy store: '{s}' failed: {s}\n", .{ q, @errorName(err) });
                    return err;
                },
            }
        }
    }
    try queryOk(allocator, &session, "CREATE GRAPH " ++ G);
    for (0..40) |i| {
        var qb: [120]u8 = undefined;
        try queryOk(allocator, &session, try std.fmt.bufPrint(&qb, "USE GRAPH " ++ G ++ "; CREATE (:Q {{i: {d}}})", .{i}));
    }
}

/// A fresh copy of the damaged store at `pristine`.
fn copyOf(allocator: std.mem.Allocator, pristine: []const u8, work: []const u8) !void {
    _ = allocator;
    std.Io.Dir.cwd().deleteTree(io(), work) catch {};
    try run(&.{ "cp", "-a", pristine, work });
}

test "SONNY-6528 (4): a quarantined graph refuses reads to in-process callers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(base);
    const pristine = try std.fmt.allocPrint(allocator, "{s}/damaged", .{base});
    defer allocator.free(pristine);
    const work = try std.fmt.allocPrint(allocator, "{s}/work", .{base});
    defer allocator.free(work);
    defer graph_store.setDataDirOverride(allocator, null);
    try std.Io.Dir.cwd().createDirPath(io(), pristine);

    try seed(allocator, pristine, true);
    const zeroed = try damage(pristine);
    std.debug.print("SONNY-6528 (4) zeroed {d} node page(s)\n", .{zeroed});
    try std.testing.expect(zeroed > 0);

    var failures: usize = 0;
    // Through the executor, in process, once a statement has found the graph
    // damaged (its hydration failed: it is quarantined), twice.
    for (read_shapes) |q| {
        try copyOf(allocator, pristine, work);
        const store = try graph_store.initGlobalStore(allocator, work);
        defer graph_store.deinitGlobalStoreForTestCrash();
        defer execution.cleanupCatalogInstance();
        try store.loadFromFile();
        var session = execution.SessionState.init(allocator);
        defer session.deinit();
        switch (ask(allocator, &session, discover)) {
            .rows => return error.DamageNotFound,
            .failed => |err| try std.testing.expect(isQuarantineError(err)),
        }
        for ([_][]const u8{ "once", "again" }) |when| {
            switch (ask(allocator, &session, q)) {
                .rows => |n| {
                    failures += 1;
                    std.debug.print("FAIL-OPEN ({s}): '{s}' answered {d} row(s)\n", .{ when, q, n });
                },
                .failed => |err| if (!isQuarantineError(err)) {
                    failures += 1;
                    std.debug.print("({s}): '{s}' failed with {s}, not a quarantine error\n", .{ when, q, @errorName(err) });
                },
            }
        }
    }

    // The listings called directly (the LSP schema provider), after a
    // statement found the graph damaged, unscoped and tenant-scoped.
    {
        try copyOf(allocator, pristine, work);
        const store = try graph_store.initGlobalStore(allocator, work);
        defer graph_store.deinitGlobalStoreForTestCrash();
        defer execution.cleanupCatalogInstance();
        try store.loadFromFile();
        var session = execution.SessionState.init(allocator);
        defer session.deinit();
        switch (ask(allocator, &session, discover)) {
            .rows => return error.DamageNotFound,
            .failed => |err| try std.testing.expect(isQuarantineError(err)),
        }
        for ([_]Listing{ .labels, .edge_types, .property_keys }) |which| {
            for ([_]?[]const u8{ null, "default" }) |tenant| {
                if (listing(allocator, store, which, tenant)) |n| {
                    failures += 1;
                    std.debug.print("FAIL-OPEN: the {s} listing (tenant {?s}) answered {d} item(s)\n", .{ @tagName(which), tenant, n });
                } else |err| if (!isQuarantineError(err)) {
                    failures += 1;
                    std.debug.print("the {s} listing failed with {s}, not a quarantine error\n", .{ @tagName(which), @errorName(err) });
                }
            }
        }
    }

    // A store whose only damaged graph is G: DROP GRAPH of it runs, the
    // listings answer again, and CREATE GRAPH of the name makes an empty one.
    {
        const only_g = try std.fmt.allocPrint(allocator, "{s}/only-g", .{base});
        defer allocator.free(only_g);
        try std.Io.Dir.cwd().createDirPath(io(), only_g);
        try seed(allocator, only_g, false);
        try std.testing.expect(try damage(only_g) > 0);
        const store = try graph_store.initGlobalStore(allocator, only_g);
        defer graph_store.deinitGlobalStoreForTestCrash();
        defer execution.cleanupCatalogInstance();
        try store.loadFromFile();
        var session = execution.SessionState.init(allocator);
        defer session.deinit();
        switch (ask(allocator, &session, "USE GRAPH " ++ G ++ "; MATCH (n:Q) RETURN count(n) AS c")) {
            .rows => |n| {
                failures += 1;
                std.debug.print("FAIL-OPEN: the damaged graph " ++ G ++ " answered a count ({d} row(s))\n", .{n});
            },
            .failed => {},
        }
        if (listing(allocator, store, .labels, null)) |n| {
            failures += 1;
            std.debug.print("FAIL-OPEN: the labels listing answered {d} item(s) with " ++ G ++ " quarantined\n", .{n});
        } else |_| {}
        switch (ask(allocator, &session, "USE GRAPH default; DROP GRAPH " ++ G)) {
            .rows => {},
            .failed => |err| {
                failures += 1;
                std.debug.print("DROP GRAPH of the quarantined graph failed: {s}\n", .{@errorName(err)});
            },
        }
        _ = listing(allocator, store, .labels, null) catch |err| {
            failures += 1;
            std.debug.print("after DROP GRAPH the labels listing still fails: {s}\n", .{@errorName(err)});
        };
        try queryOk(allocator, &session, "CREATE GRAPH " ++ G);
        switch (ask(allocator, &session, "USE GRAPH " ++ G ++ "; MATCH (n) RETURN count(n) AS c")) {
            .rows => {},
            .failed => |err| {
                failures += 1;
                std.debug.print("the graph created again under the dropped name fails a count: {s}\n", .{@errorName(err)});
            },
        }
    }

    if (failures > 0) {
        std.debug.print("SONNY-6528 (4): {d} fail-open answer(s) for a quarantined graph in process\n", .{failures});
        return error.QuarantineFailOpen;
    }
}
