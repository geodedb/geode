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
// NOT guaranteed (engine-level gaps, root fix tracked as SONNY-2409: the pager
// must not treat a zeroed page below the written high-water mark as fresh):
//   * zeroed pages read by an UNLABELED scan, or by a label scan after the
//     derived label index is REBUILT from the node store (engine scanNodes
//     skips empty records, so the lost ids vanish): partial rows, status OK;
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
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
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
    // Perf claims go through the shared gate (SONNY-2394): enforced only when
    // `CI` is unset -- repo convention, see tests/perf_gate.zig.
    try perf_gate.envelope("corrupt-page reopen-to-detection", cv, p95 / mean, 0.22, 2.55);
}

fn monotonicNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
