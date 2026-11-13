// CANARY: REQ=REQ-GQL-TDE-OLTP-PERF-001; FEATURE="TDEOlptOverheadValidation"; ASPECT=RealStoreMeasurement; STATUS=BENCHED; BENCH=tests/test_sonny6435_tde_overhead.zig; OWNER=perf; UPDATED=2026-11-12
//
// SONNY-6435 (2): the measurement of TDE overhead. The two former
// "benchmarks" timed no encryption at all (benchmark_tde_overhead.zig hashed
// a buffer with Wyhash and called it encryption; benchmark_tde_oltp_overhead
// .zig was built by no step and used removed std APIs), while the docs
// claimed "<1%" and "<5%".
//
// What is measured: the storage engine geode opens every graph with
// (`graph_storage.ShardedGraphEngine`, the engine `StorageAdapter` wraps; it
// encrypts every page it writes and every WAL record with AES-256-GCM when
// `GraphConfig.encryption_key` is set, which is how `GEODE_TDE_KEY` reaches
// it in `graph_store.initGlobalAdapter`). Two engines run the SAME
// operation sequence, one without a key (arm A) and one with (arm B):
//   one operation = create a node, give it a 512-byte string property,
//   and read the property of an earlier node chosen at random (the same
//   sequence in both arms); every 256 operations a checkpoint.
// The engine configuration is the production default (8 KiB pages, a
// 1024-page buffer pool per shard with auto-size), so the working set stays
// cached as in an OLTP server: the encryption on the measured path is the
// WAL records of every commit and the pages every checkpoint writes. The
// engine is built ReleaseFast whatever -Doptimize says (a Debug build would
// time Debug crypto).
// Cold reads (SONNY-6452), a third measurement: reads that miss the buffer
// pool, so every miss is a page read and, in arm B, an AES-GCM decrypt.
// Both arms hold the same checkpointed store, far larger than their 8-page
// per-shard pools (auto-size off); one operation reads the property of a
// node chosen at random. The store files sit in the OS page cache, so this
// is the CPU cost of a miss (pread + decrypt), not disk latency. The step
// asserts that most reads really miss (buffer-pool misses per read, from
// the engine's own counters). Taken only once graph_storage 0.4.12 made the
// small-pool path lossless (SONNY-6441; before it, a cold read could find
// the record damaged).
// Samples are perf_gate batches, the arms interleaved batch by batch;
// overhead = (median B - median A) / median A. Two durability settings:
//   - `deferred` WAL sync: no fsync per commit, so the crypto cost is not
//     hidden behind disk latency (the CPU-bound worst case);
//   - `sync_each_commit` (the default): one WAL fsync per commit.
// What it does not include: the StorageAdapter, executor, query and
// network layers above the engine. They do the same work in both arms, so
// the overhead of a whole query is smaller than the engine figure.
//
// Correctness (always asserted): arm B really encrypts. After the run the
// plaintext marker of the property values is found in arm A's files and in
// none of arm B's. Perf claims go through perf_gate (reported by default,
// enforced with GEODE_PERF_GATES=enforce).
const std = @import("std");
const builtin = @import("builtin");
const gs = @import("graph_storage");
const perf_gate = @import("perf_gate");
const test_scratch = @import("test_scratch.zig");

const testing = std.testing;
const allocator = perf_gate.bench_allocator;

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const marker = "SONNY6435-PLAINTEXT-MARKER";
const payload_len = 512;
const checkpoint_every = 256;
const tde_key = [_]u8{0x35} ** 32;

const Arm = struct {
    eng: *gs.ShardedGraphEngine,
    dir: []u8,
    ids: std.ArrayListUnmanaged(gs.NodeId) = .empty,
    rng: std.Random.DefaultPrng,
    ops: u64 = 0,
    /// Checkpoint every this many operations; 0 = only when asked.
    checkpoint_every: u64,
    payload: [payload_len]u8 = undefined,

    fn init(root: []const u8, name: []const u8, sync_mode: gs.SyncMode, every: u64, key: ?[32]u8) !Arm {
        return initPool(root, name, sync_mode, every, key, null);
    }

    /// `pool_pages`: an exact per-shard buffer pool (auto-size off); null =
    /// the production default.
    fn initPool(root: []const u8, name: []const u8, sync_mode: gs.SyncMode, every: u64, key: ?[32]u8, pool_pages: ?u32) !Arm {
        const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, name });
        errdefer allocator.free(dir);
        try std.Io.Dir.cwd().createDirPath(fsIo(), dir);
        var cfg: gs.GraphConfig = .{
            .data_dir = dir,
            .encryption_key = key,
            .sync_mode = sync_mode,
        };
        if (pool_pages) |p| {
            cfg.buffer_pool_pages = p;
            cfg.buffer_pool_auto_size = false;
        }
        const eng = try gs.ShardedGraphEngine.create(allocator, dir, [_]u8{0x64} ** 16, cfg);
        var arm: Arm = .{ .eng = eng, .dir = dir, .rng = .init(0x6435), .checkpoint_every = every };
        @memcpy(arm.payload[0..marker.len], marker);
        return arm;
    }

    fn deinit(self: *Arm) void {
        self.eng.close() catch {};
        self.ids.deinit(allocator);
        allocator.free(self.dir);
    }

    /// One OLTP operation: insert a node with a property, read an earlier one.
    fn step(self: *Arm) !u64 {
        const r = self.rng.random();
        // Bytes after the marker vary per node (no two pages alike).
        r.bytes(self.payload[marker.len..]);
        const id = try self.eng.allocNode();
        // txn_stamp 1, as StorageAdapter.createNode: an all-zero record is an empty slot.
        try self.eng.putNode(id, gs.test_support.emptyNode(1));
        var rec = (try self.eng.getNode(id)) orelse return error.NodeMissingAfterPut;
        rec.prop_head = try self.eng.putNodeProperty(id, rec.prop_head, "payload", .{ .string = &self.payload });
        try self.eng.putNode(id, rec);
        try self.ids.append(allocator, id);

        const earlier = self.ids.items[r.uintLessThan(usize, self.ids.items.len)];
        const erec = (try self.eng.getNode(earlier)) orelse return error.EarlierNodeMissing;
        const got = (try self.eng.getNodeProperty(earlier, erec.prop_head, "payload", allocator)) orelse return error.PropertyMissing;
        defer switch (got) {
            .string => |s| allocator.free(s),
            else => {},
        };
        if (got != .string or got.string.len != payload_len) return error.PropertyMismatch;

        self.ops += 1;
        if (self.checkpoint_every != 0 and self.ops % self.checkpoint_every == 0) try self.eng.checkpoint();
        return id;
    }

    /// One cold read: the property of a node chosen at random.
    fn read(self: *Arm) !u64 {
        const id = self.ids.items[self.rng.random().uintLessThan(usize, self.ids.items.len)];
        const rec = (try self.eng.getNode(id)) orelse return error.NodeMissing;
        const got = (try self.eng.getNodeProperty(id, rec.prop_head, "payload", allocator)) orelse return error.PropertyMissing;
        defer switch (got) {
            .string => |str| allocator.free(str),
            else => {},
        };
        if (got != .string or got.string.len != payload_len or !std.mem.eql(u8, got.string[0..marker.len], marker)) return error.PropertyMismatch;
        self.ops += 1;
        return id;
    }

    /// Buffer-pool misses summed over the shards.
    fn misses(self: *const Arm) u64 {
        var n: u64 = 0;
        for (self.eng.shards) |sh| n += sh.metrics.buffer_misses;
        return n;
    }
};

const Ctx = struct {
    plain: Arm,
    enc: Arm,

    fn opPlain(self: *Ctx) !u64 {
        return self.plain.step();
    }

    fn opEnc(self: *Ctx) !u64 {
        return self.enc.step();
    }

    fn readPlain(self: *Ctx) !u64 {
        return self.plain.read();
    }

    fn readEnc(self: *Ctx) !u64 {
        return self.enc.read();
    }
};

/// Count the files under `dir` that contain `needle`.
fn filesContaining(dir_path: []const u8, needle: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), dir_path, .{ .iterate = true });
    defer dir.close(fsIo());
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var hits: usize = 0;
    while (try walker.next(fsIo())) |entry| {
        if (entry.kind != .file) continue;
        const data = try dir.readFileAlloc(fsIo(), entry.path, allocator, .limited(1 << 30));
        defer allocator.free(data);
        if (std.mem.indexOf(u8, data, needle) != null) hits += 1;
    }
    return hits;
}

const Result = struct { plain: perf_gate.Robust, enc: perf_gate.Robust, overhead: f64 };

fn measure(root: []const u8, tag: []const u8, sync_mode: gs.SyncMode, every: u64, preload_nodes: usize, batch: usize, comptime samples: usize) !Result {
    var name_buf: [64]u8 = undefined;
    var ctx: Ctx = .{
        .plain = try Arm.init(root, try std.fmt.bufPrint(&name_buf, "{s}-plain", .{tag}), sync_mode, every, null),
        .enc = undefined,
    };
    defer ctx.plain.deinit();
    ctx.enc = try Arm.init(root, try std.fmt.bufPrint(&name_buf, "{s}-tde", .{tag}), sync_mode, every, tde_key);
    defer ctx.enc.deinit();

    // A store written the same way in both arms, checkpointed.
    for (0..preload_nodes) |_| {
        _ = try ctx.plain.step();
        _ = try ctx.enc.step();
    }
    try ctx.plain.eng.checkpoint();
    try ctx.enc.eng.checkpoint();
    var warm_a: [4]f64 = undefined;
    var warm_b: [4]f64 = undefined;
    try perf_gate.interleavedAB(&ctx, Ctx.opPlain, Ctx.opEnc, batch, &warm_a, &warm_b);

    var a: [samples]f64 = undefined;
    var b: [samples]f64 = undefined;
    try perf_gate.interleavedAB(&ctx, Ctx.opPlain, Ctx.opEnc, batch, &a, &b);
    const ra = perf_gate.robust(&a);
    const rb = perf_gate.robust(&b);

    // Correctness: arm B wrote no plaintext; arm A did (so the marker test
    // can tell the two apart).
    try ctx.plain.eng.checkpoint();
    try ctx.enc.eng.checkpoint();
    const plain_hits = try filesContaining(ctx.plain.dir, marker);
    const enc_hits = try filesContaining(ctx.enc.dir, marker);
    std.debug.print("SONNY-6435 TDE [{s}] files holding the plaintext marker: plain={d} tde={d}\n", .{ tag, plain_hits, enc_hits });
    try testing.expect(plain_hits > 0);
    try testing.expectEqual(@as(usize, 0), enc_hits);

    return .{ .plain = ra, .enc = rb, .overhead = perf_gate.medianOverhead(ra, rb) };
}

const ColdResult = struct { r: Result, plain_misses_per_read: f64, enc_misses_per_read: f64 };

/// Cold reads: two stores of `nodes` nodes, written the same way, each with
/// an exact `pool_pages` pool per shard; time random property reads.
fn measureCold(root: []const u8, nodes: usize, pool_pages: u32, batch: usize, comptime samples: usize) !ColdResult {
    var ctx: Ctx = .{
        .plain = try Arm.initPool(root, "cold-plain", .deferred, 0, null, pool_pages),
        .enc = undefined,
    };
    defer ctx.plain.deinit();
    ctx.enc = try Arm.initPool(root, "cold-tde", .deferred, 0, tde_key, pool_pages);
    defer ctx.enc.deinit();
    for (0..nodes) |_| {
        _ = try ctx.plain.step();
        _ = try ctx.enc.step();
    }
    try ctx.plain.eng.checkpoint();
    try ctx.enc.eng.checkpoint();
    var warm_a: [4]f64 = undefined;
    var warm_b: [4]f64 = undefined;
    try perf_gate.interleavedAB(&ctx, Ctx.readPlain, Ctx.readEnc, batch, &warm_a, &warm_b);

    const ops0 = .{ ctx.plain.ops, ctx.enc.ops };
    const miss0 = .{ ctx.plain.misses(), ctx.enc.misses() };
    var a: [samples]f64 = undefined;
    var b: [samples]f64 = undefined;
    try perf_gate.interleavedAB(&ctx, Ctx.readPlain, Ctx.readEnc, batch, &a, &b);
    const plain_mpr = @as(f64, @floatFromInt(ctx.plain.misses() - miss0[0])) / @as(f64, @floatFromInt(ctx.plain.ops - ops0[0]));
    const enc_mpr = @as(f64, @floatFromInt(ctx.enc.misses() - miss0[1])) / @as(f64, @floatFromInt(ctx.enc.ops - ops0[1]));
    const ra = perf_gate.robust(&a);
    const rb = perf_gate.robust(&b);

    const plain_hits = try filesContaining(ctx.plain.dir, marker);
    const enc_hits = try filesContaining(ctx.enc.dir, marker);
    std.debug.print("SONNY-6452 TDE [cold reads] files holding the plaintext marker: plain={d} tde={d}; buffer-pool misses per read: plain={d:.2} tde={d:.2}\n", .{ plain_hits, enc_hits, plain_mpr, enc_mpr });
    try testing.expect(plain_hits > 0);
    try testing.expectEqual(@as(usize, 0), enc_hits);
    return .{ .r = .{ .plain = ra, .enc = rb, .overhead = perf_gate.medianOverhead(ra, rb) }, .plain_misses_per_read = plain_mpr, .enc_misses_per_read = enc_mpr };
}

fn report(tag: []const u8, batch: usize, samples: usize, r: Result) void {
    std.debug.print(
        "SONNY-6435 TDE [{s}] batch={d} samples={d}: plain median={d:.0}ns/op (rel_iqr {d:.3}), tde median={d:.0}ns/op (rel_iqr {d:.3}), overhead={d:.1}%\n",
        .{ tag, batch, samples, r.plain.median, r.plain.rel_iqr, r.enc.median, r.enc.rel_iqr, r.overhead * 100.0 },
    );
}

test "SONNY-6435 (2) TDE overhead of the storage engine, page and WAL encryption off vs on, same workload, interleaved" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var root = try test_scratch.ScratchDir.create("sonny6435-tde");
    defer root.remove();

    // The commit path's CPU cost: no WAL fsync, no checkpoint in the timed
    // window (a checkpoint in some batches made the samples bimodal,
    // p95/median ~300; one in every batch is all fsync, 11.8 ms/op).
    const deferred = try measure(root.path(), "deferred", .deferred, 0, 4000, 64, 41);
    report("deferred WAL sync, no checkpoint", 64, 41, deferred);
    // The default durability, checkpointing every 256 operations.
    const durable = try measure(root.path(), "sync_each_commit", .sync_each_commit, checkpoint_every, 256, 8, 31);
    report("sync_each_commit", 8, 31, durable);

    // The claims the docs make (docs/TDE_FILE_LEVEL_ENCRYPTION.md
    // "Measured overhead"): every arm measured stably, and the bounds below.
    inline for (.{ .{ "deferred plain", deferred.plain }, .{ "deferred tde", deferred.enc }, .{ "sync plain", durable.plain }, .{ "sync tde", durable.enc } }) |arm| {
        try perf_gate.robustEnvelope("SONNY-6435 TDE overhead sample stability: " ++ arm[0], arm[1], 0.30, 2.55);
    }
    try perf_gate.check("SONNY-6435 TDE engine overhead, deferred WAL sync, below " ++ deferred_bound_text, deferred.overhead < deferred_bound, "overhead={d:.1}%", .{deferred.overhead * 100.0});
    try perf_gate.check("SONNY-6435 TDE engine overhead, sync_each_commit, below " ++ durable_bound_text, durable.overhead < durable_bound, "overhead={d:.1}%", .{durable.overhead * 100.0});
}

test "SONNY-6452 (3) TDE overhead of reads that miss the buffer pool, page encryption off vs on, interleaved" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var root = try test_scratch.ScratchDir.create("sonny6452-tde-cold");
    defer root.remove();

    // 16000 nodes with a 512-byte property: ~65 property pages and 6 node
    // pages per shard against an 8-page pool.
    const cold = try measureCold(root.path(), cold_nodes, cold_pool_pages, 256, 41);
    report("cold reads, 8-page pool per shard", 256, 41, cold.r);

    // The measurement is of misses: most reads miss in both arms (the
    // engine's own counters, not an assumption).
    try testing.expect(cold.plain_misses_per_read >= cold_min_misses_per_read);
    try testing.expect(cold.enc_misses_per_read >= cold_min_misses_per_read);
    inline for (.{ .{ "cold plain", cold.r.plain }, .{ "cold tde", cold.r.enc } }) |arm| {
        try perf_gate.robustEnvelope("SONNY-6452 TDE cold-read sample stability: " ++ arm[0], arm[1], 0.30, 2.55);
    }
    try perf_gate.check("SONNY-6452 TDE cold-read overhead below " ++ cold_bound_text, cold.r.overhead < cold_bound, "overhead={d:.1}%", .{cold.r.overhead * 100.0});
}

const cold_nodes = 16000;
const cold_pool_pages = 8;
const cold_min_misses_per_read: f64 = 0.5;

// The claims docs/TDE_FILE_LEVEL_ENCRYPTION.md ("Measured overhead") makes,
// from the 2026-11-13 runs with graph_storage 0.4.14 on a shared, loaded dev
// host (16-core Threadripper PRO 3955WX): durable -0.0% to +1.2% over four
// runs (fsync-bound, 51-61 ms per operation), commit path without fsync
// +28.8% to +29.6% over three and +38.1% in a fourth at load average 99.
// 0.4.14 checksums WAL records with hardware CRC32C, which took about 50 us
// off both arms; the encryption itself still costs about 26 us per
// operation, a larger share of a faster path. (graph_storage 0.4.13: -0.5%
// to +1.9% and +18.7% to +20.9% over four; 0.4.12: -1.3% to +0.7% over
// four, +19.5% to +21.0% over three.)
const deferred_bound: f64 = 0.35;
const deferred_bound_text = "35%";
const durable_bound: f64 = 0.05;
const durable_bound_text = "5%";
// The cold-read claim docs/TDE_FILE_LEVEL_ENCRYPTION.md makes (SONNY-6452),
// from the runs recorded there: +57.2% to +61.9% over four runs with
// graph_storage 0.4.14 (0.4.13: +55.7% to +61.4%), whose hardware CRC32C
// makes a plaintext miss about 6.0-6.6 us/op against about 9.7-10.6 us/op
// encrypted. With the software CRC of
// 0.4.12 and older the plaintext miss was the slower one (-72.5%), which the
// former 10% bound described.
const cold_bound: f64 = 0.80;
const cold_bound_text = "80%";
