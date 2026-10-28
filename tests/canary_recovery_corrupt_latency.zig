// Corrupt-page recovery: fail-closed detection + detection-latency envelope.
//
// SONNY-2394 rewrite. The previous version targeted the removed single-file
// snapshot (`getPersistenceFilePath` now names the data DIRECTORY, so opening
// it failed with IsDir). Current layout: `<data_dir>/<store>/graphs/<shard>/`
// holds one set of engine files per shard (`nodes.store`, `props.store`, ...),
// 8 KiB pages, each with a 32-byte header carrying a CRC32C of the body.
//
// Asserted contract (what IS guaranteed today): after a clean shutdown,
// damaging durable page data and reopening, a LABEL scan (`MATCH (n:Person)`)
// that touches the damaged data fails with a typed error -- no crash, no
// partial "OK" result:
//   * flipped body bytes -> the pager's CRC32C check (error.ChecksumMismatch);
//   * a fully zeroed page (torn write / zeroed sectors) -> the pager treats an
//     all-zero page as FRESH, so its node records read as empty. The label scan
//     used to skip them silently (169 of 300 rows (before page 0 was damaged),
//     status OK, while count() still said 300); it now fails with
//     error.DataCorruption -- but only because the label index here is loaded
//     from its (clean) snapshot and still lists the lost ids.
//   * when the label index is instead REBUILT from the node store (a crash
//     restart, or stale snapshots: the ReleaseSafe lane hit this), the lost
//     ids vanish from it, but the graph's hydration scan now finds fewer live
//     records than the shard manifests count and fails with
//     error.DataCorruption. The graph is quarantined, and every read or write
//     of a quarantined graph fails closed (GraphQuarantineError) instead of
//     answering OK from its partial indexes.
// NOT guaranteed (engine-level gaps, root fix tracked as SONNY-2409: the pager
// must not treat a zeroed page below the written high-water mark as fresh):
//   * zeroed pages read by an UNLABELED engine-direct scan before anything
//     hydrates the graph: partial rows, status OK;
//   * a page whose 32-byte HEADER alone is zeroed: CRC verification is
//     skipped, so damage in the rest of that page can go undetected.
//
// CANARY: REQ=REQ-GQL-028; FEATURE="SnapshotCompaction"; ASPECT=CorruptPageRecoveryLatency; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_028_CorruptPageRecoveryLatency; OWNER=storage; UPDATED=2026-09-23
// CANARY: REQ=REQ-GQL-028; FEATURE="SnapshotCompaction"; ASPECT=CorruptPageRecoveryLatency; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_028_CorruptPageRecoveryLatencyVarianceEnvelope; OWNER=storage; UPDATED=2026-09-23

const std = @import("std");
const geode = @import("geode");
const perf_gate = @import("perf_gate");

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;

const PAGE_SIZE: u64 = 8192;
const PAGE_HEADER_SIZE: u64 = 32;
const NODES: usize = 300;
const READ_ALL_NAMES = "MATCH (n:Person) RETURN n.name AS name";

const Damage = enum {
    /// XOR 64 body bytes: the header (and its CRC) is intact.
    flip_body,
    /// Zero the whole page, header included (torn write / zeroed sectors).
    zero_page,
};

// Zig 0.16 has no std.Io.Dir realpath: rebuild the absolute tmp-dir path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Create NODES :Person nodes with properties and shut down CLEANLY (full
/// checkpoint + snapshots): the exact durable state a restart loads.
fn seedCleanStore(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    const labels = [_][]const u8{"Person"};
    for (0..NODES) |i| {
        const id = try store.createNode(&labels);
        var buf: [32]u8 = undefined;
        try store.setNodeProperty(id, "name", .{ .String = try std.fmt.bufPrint(&buf, "person-{d:0>5}", .{i}) });
        try store.setNodeProperty(id, "seq", .{ .Int = @intCast(i) });
    }
}

/// Damage every written page (non-zero header) of every `file_name` under
/// `data_dir`, page 0 included. Returns the number of pages damaged.
///
/// Page 0 is NOT metadata in `nodes.store`: `graph_storage`'s NodeStore maps a
/// node id to page `id / nodes_per_page`, so page 0 holds the first
/// nodes_per_page node records and is a CRC-checked data page like any other.
/// In `props.store` page 0 is the free-space manager's reserved page; nothing
/// writes it, so the never-written check below skips it.
fn damageFiles(data_dir: []const u8, file_name: []const u8, damage: Damage) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();
    var damaged: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, entry.basename, file_name)) continue;
        var file = try entry.dir.openFile(io, entry.basename, .{ .mode = .read_write });
        defer file.close(io);
        const len = try file.length(io);
        var page: u64 = 0;
        while ((page + 1) * PAGE_SIZE <= len) : (page += 1) {
            var header: [PAGE_HEADER_SIZE]u8 = undefined;
            _ = try file.readPositionalAll(io, &header, page * PAGE_SIZE);
            if (std.mem.allEqual(u8, &header, 0)) continue; // never written
            switch (damage) {
                .flip_body => {
                    var body: [64]u8 = undefined;
                    const at = page * PAGE_SIZE + PAGE_HEADER_SIZE + 64;
                    _ = try file.readPositionalAll(io, &body, at);
                    for (&body) |*b| b.* ^= 0xA5;
                    try file.writePositionalAll(io, &body, at);
                },
                .zero_page => {
                    const zeros = [_]u8{0} ** PAGE_SIZE;
                    try file.writePositionalAll(io, &zeros, page * PAGE_SIZE);
                },
            }
            damaged += 1;
        }
    }
    return damaged;
}

const Outcome = union(enum) { rows: usize, failed: anyerror };

/// Reopen the damaged store and read every node's name through the executor
/// (query scratch arena installed, as every production entry point does).
fn reopenAndReadAll(allocator: std.mem.Allocator, data_dir: []const u8) !Outcome {
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    // Crash-style teardown: never checkpoint over the damaged pages.
    defer graph_store.deinitGlobalStoreForTestCrash();
    defer execution.cleanupCatalogInstance();
    try store.loadFromFile();

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);

    var parsed = try geode.parseGql(READ_ALL_NAMES, allocator);
    defer parsed.deinit();
    const catalog = try execution.ensureCatalogInstance(allocator);
    const ctx = execution.ExecutionContext{ .catalog = catalog };
    var result = execution.executeProgramWithContext(allocator, &parsed.program, ctx) catch |err| return .{ .failed = err };
    defer result.deinit(allocator);
    return .{ .rows = result.rows.len };
}

fn isTypedCorruptionError(err: anyerror) bool {
    return err == error.ChecksumMismatch or err == error.DataCorruption or err == error.InvalidData;
}

test "TestCANARY_REQ_GQL_028_CorruptPageRecoveryLatency" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { file: []const u8, damage: Damage }{
        .{ .file = "nodes.store", .damage = .flip_body },
        .{ .file = "nodes.store", .damage = .zero_page },
        .{ .file = "props.store", .damage = .flip_body },
        .{ .file = "props.store", .damage = .zero_page },
    };
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        defer allocator.free(data_dir);
        defer graph_store.setDataDirOverride(allocator, null);

        try seedCleanStore(allocator, data_dir);
        // Control: the undamaged store serves every row.
        switch (try reopenAndReadAll(allocator, data_dir)) {
            .rows => |n| try std.testing.expectEqual(NODES, n),
            .failed => |e| return e,
        }

        const damaged = try damageFiles(data_dir, case.file, case.damage);
        try std.testing.expect(damaged > 0);

        switch (try reopenAndReadAll(allocator, data_dir)) {
            .rows => |n| {
                std.debug.print("SILENTLY ACCEPTED: {s}/{s} damaged ({d} pages) but the read returned OK with {d}/{d} rows\n", .{ case.file, @tagName(case.damage), damaged, n, NODES });
                return error.CorruptionSilentlyAccepted;
            },
            .failed => |err| {
                if (!isTypedCorruptionError(err)) {
                    std.debug.print("{s}/{s}: unexpected error.{s}\n", .{ case.file, @tagName(case.damage), @errorName(err) });
                    return err;
                }
            },
        }
    }
}

test "BenchmarkCANARY_REQ_GQL_028_CorruptPageRecoveryLatencyVarianceEnvelope" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    try seedCleanStore(allocator, data_dir);
    _ = try damageFiles(data_dir, "nodes.store", .zero_page);

    // Each sample: reopen the damaged store until the corruption is DETECTED.
    const iters: usize = 24;
    var samples: [iters]f64 = undefined;
    for (&samples) |*sample| {
        const t0 = monotonicNs();
        const outcome = try reopenAndReadAll(allocator, data_dir);
        sample.* = @floatFromInt(monotonicNs() - t0);
        // Correctness (always enforced): every reopen detects the damage.
        switch (outcome) {
            .rows => return error.CorruptionSilentlyAccepted,
            .failed => |err| try std.testing.expect(isTypedCorruptionError(err)),
        }
    }

    var sum: f64 = 0;
    for (samples) |s| sum += s;
    const mean = sum / @as(f64, @floatFromInt(iters));
    var var_acc: f64 = 0;
    for (samples) |s| var_acc += (s - mean) * (s - mean);
    const cv = @sqrt(var_acc / @as(f64, @floatFromInt(iters))) / mean;
    std.sort.block(f64, &samples, {}, comptime std.sort.asc(f64));
    const p95 = samples[(iters * 95) / 100 - 1];
    std.debug.print("CORRUPT_RECOVERY_DETECT mean_ns={d:.0} cv={d:.4} p95/mean={d:.2}\n", .{ mean, cv, p95 / mean });
    // Perf claims go through the shared gate (SONNY-2394): reported unless
    // GEODE_PERF_GATES=enforce (SONNY-2439) -- see tests/perf_gate.zig.
    try perf_gate.envelope("corrupt-page reopen-to-detection", cv, p95 / mean, 0.22, 2.55);
}

/// Reopen the store, run `hook` against it before any query (it may
/// quarantine a graph or remove files), then run `query` through the executor
/// exactly like `reopenAndReadAll`.
fn reopenAndRun(
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    query: []const u8,
    comptime hook: ?fn (*graph_store.GraphStore) anyerror!void,
) !Outcome {
    const store = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStoreForTestCrash();
    defer execution.cleanupCatalogInstance();
    try store.loadFromFile();
    if (hook) |h| try h(store);

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);

    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();
    const catalog = try execution.ensureCatalogInstance(allocator);
    const ctx = execution.ExecutionContext{ .catalog = catalog };
    var result = execution.executeProgramWithContext(allocator, &parsed.program, ctx) catch |err| return .{ .failed = err };
    defer result.deinit(allocator);
    return .{ .rows = result.rows.len };
}

/// Invalidate the derived-index snapshots under `data_dir`: delete geode's
/// loop2 hydration snapshots and empty the engine's `labels.idx` (the engine
/// rebuilds a label index it cannot load). The reopen then rebuilds the label
/// index and the graph's resident indexes by scanning the node store, as
/// after a crash or once a checkpoint has made the snapshots stale.
fn invalidateDerivedIndexSnapshots(data_dir: []const u8) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(std.testing.allocator);
    defer walker.deinit();
    var invalidated: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.basename, "labels.idx")) {
            var file = try entry.dir.openFile(io, entry.basename, .{ .mode = .read_write });
            defer file.close(io);
            try file.setLength(io, 0);
            invalidated += 1;
            continue;
        }
        if (!std.mem.startsWith(u8, entry.basename, "hydration_") or !std.mem.endsWith(u8, entry.basename, ".snap")) continue;
        try entry.dir.deleteFile(io, entry.basename);
        invalidated += 1;
    }
    return invalidated;
}

// CANARY: REQ=REQ-GQL-028; FEATURE="SnapshotCompaction"; ASPECT=QuarantinedGraphFailClosed; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_028_QuarantinedGraphFailsClosed; OWNER=storage; UPDATED=2026-10-19
// A graph whose lazy hydration failed is quarantined (its resident indexes
// are partial). A query that reads it must fail with a typed error, never
// answer OK from the partial indexes (which read as empty).
test "TestCANARY_REQ_GQL_028_QuarantinedGraphFailsClosed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    try seedCleanStore(allocator, data_dir);
    const Quarantine = struct {
        fn hook(store: *graph_store.GraphStore) anyerror!void {
            if (!store.forceHydrationQuarantineForTest(graph_store.DEFAULT_GRAPH_NAME)) return error.GraphNotDeferred;
        }
    };
    const queries = [_][]const u8{
        READ_ALL_NAMES,
        "MATCH (n) RETURN n.name AS name",
        "MATCH (n:Person) RETURN count(n) AS c",
    };
    for (queries) |q| {
        switch (try reopenAndRun(allocator, data_dir, q, Quarantine.hook)) {
            .rows => |n| {
                std.debug.print("QUARANTINED GRAPH READ OK: '{s}' returned {d} row(s)\n", .{ q, n });
                return error.QuarantinedGraphReadSucceeded;
            },
            .failed => |err| try std.testing.expectEqual(error.GraphQuarantined, err),
        }
    }
    // A clean reopen re-registers the graph and serves every row again.
    switch (try reopenAndReadAll(allocator, data_dir)) {
        .rows => |n| try std.testing.expectEqual(NODES, n),
        .failed => |e| return e,
    }
}

// CANARY: REQ=REQ-GQL-028; FEATURE="SnapshotCompaction"; ASPECT=ZeroedPageRebuildFailClosed; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_028_ZeroedPagesFailHydrationRebuild; OWNER=storage; UPDATED=2026-10-19
// Zeroed node pages read as fresh, so a hydration that rebuilds the resident
// indexes from the node store (no counter-current loop2 snapshot) used to
// find 0 of 300 nodes and serve 0 rows with status OK. The rebuild now
// checks the scan against each shard's durable live-node count and fails
// with error.DataCorruption, which quarantines the graph and fails the read.
test "TestCANARY_REQ_GQL_028_ZeroedPagesFailHydrationRebuild" {
    const allocator = std.testing.allocator;
    // The label scan only: an UNLABELED scan of zeroed pages still reads the
    // engine without hydrating and returns partial rows (SONNY-2409).
    const queries = [_][]const u8{ READ_ALL_NAMES, "MATCH (n:Person) RETURN count(n) AS c" };
    for (queries) |q| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        defer allocator.free(data_dir);
        defer graph_store.setDataDirOverride(allocator, null);

        try seedCleanStore(allocator, data_dir);
        try std.testing.expect(try damageFiles(data_dir, "nodes.store", .zero_page) > 0);
        try std.testing.expect(try invalidateDerivedIndexSnapshots(data_dir) > 0);
        // Twice: the failed rebuild must not persist its partial products
        // (the next reopen would otherwise load an empty snapshot as truth).
        for (0..2) |_| {
            switch (try reopenAndRun(allocator, data_dir, q, null)) {
                .rows => |n| {
                    std.debug.print("SILENTLY ACCEPTED: '{s}' returned {d}/{d} rows over zeroed node pages\n", .{ q, n, NODES });
                    return error.CorruptionSilentlyAccepted;
                },
                .failed => |err| {
                    if (!isTypedCorruptionError(err)) {
                        std.debug.print("'{s}': unexpected error.{s}\n", .{ q, @errorName(err) });
                        return err;
                    }
                },
            }
        }
    }
}

fn monotonicNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
