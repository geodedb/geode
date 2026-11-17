// Vector-index reader use-after-free: every knn read path resolves a
// `*VectorIndexWrapper` with NO lifetime guard, while DROP INDEX and the
// non-blocking rebuild SWAP deinit+destroy that very wrapper.
//
// VERIFIED READ-ONLY against this branch before the fix:
//
//   READERS (no lock at all — snapshot-then-release means not even the graph
//   lock is held while the wrapper is dereferenced):
//     * `IndexManager.queryAdvancedVectorIndex`            (index_manager.zig:1268)
//     * `IndexManager.queryAdvancedVectorIndexWithMetric`  (index_manager.zig:1281)
//     * `IndexManager.searchAdvancedVectorIndex`           (index_manager.zig:1294)
//     * `IndexManager.findAdvancedVectorIndexForProperty`  (index_manager.zig:1803)
//       — returns `meta.name`, a MANAGER-OWNED slice that
//       `removeAdvancedPropertyIndex` frees at index_manager.zig:2481.
//     * src/eval.zig:2771 / :2775 / :2839 and
//       src/execution/statement_dispatcher.zig:145 / :174 all call the above
//       and then use the result.
//
//   WRITERS (tear the wrapper down while those readers may be inside it):
//     * the shadow SWAP in `rebuildAdvancedVectorIndexNonBlocking`
//       (index_manager.zig:2216-2239) takes `rebuild_mutex`, replaces the map
//       slot, and immediately `old.deinit()` + `destroy(old)`.
//     * `dropAdvancedIndex` (index_manager.zig:2292-2306) takes NO lock at all:
//       `fetchRemove` → `kv.value.deinit()` → `destroy` → `free(kv.key)` →
//       `removeAdvancedPropertyIndex` (which frees the metadata strings a
//       reader may still be holding).
//     * `Hnsw.deinit` does not take the index's own rw_lock, so the library
//       offers no lifetime protection either — exactly the posture
//       `fts.Engine.deinit` documents, which is why the fts adapter pins every
//       reader with a refcount.
//
// THE CONTRACT THIS SUITE PINS — the fts-storage pattern
// (src/storage/fts_storage_adapter.zig:24-47 header: registry mutex guards the
// map AND every in-flight refcount; teardown waits for quiescence on a
// condition that releases the mutex while blocked):
//
//   pub fn requireVectorIndex(self: *IndexManager, index_name: []const u8) !H
//       // Pins the live wrapper for `index_name` and returns it. `error.IndexNotFound`
//       // when absent or already retired. Taken under `rebuild_mutex`.
//   pub fn releaseVectorIndex(self: *IndexManager, handle: H) void
//       // Drops one in-flight reference; wakes a waiting drop/teardown at zero.
//
//   `H` is deliberately not over-specified: it may be `*VectorIndexWrapper`
//   itself (refcount fields added to the wrapper, keeping
//   `advanced_vector_indexes.get(name)` returning something with `.ids` /
//   `.contains` — the shape five existing tests already reach for) or a handle
//   struct with a `wrapper` / `index` member. `wrapperPtr` below accepts any of
//   those spellings, so the fixer keeps that freedom.
//
//   LIFETIME RULES the tests below assert:
//     R1. DROP INDEX must not tear the wrapper down while a reference is held:
//         the drop blocks (or otherwise defers teardown) until the last
//         `releaseVectorIndex`, and a knn through the pinned handle keeps
//         returning correct rows for the whole window.
//     R2. The rebuild SWAP must leave a pinned OLD wrapper valid for its
//         holder; a `requireVectorIndex` issued AFTER the swap resolves to the
//         NEW wrapper.
//     R3. `statistics.total_entries` tracks reality across a rebuild (a swap
//         REPLACES the entries, it does not add a second copy) and across a
//         drop (removing an index removes its entries from the total).
//     R4. Metadata handed to a caller must outlive a concurrent DROP. The
//         spelling pinned here is an explicitly-owned duplicate:
//           pub fn findAdvancedVectorIndexForPropertyAlloc(
//               self: *IndexManager, allocator, property) !?[]u8   // caller frees
//         chosen over "pin/intern the manager-owned string" because ownership
//         is then visible in the signature and cannot be silently regressed by
//         a later `free` in `removeAdvancedPropertyIndex`.
//
// Structure (harness, global-state teardown, comptime seam predicate) mirrors
// tests/test_geode875_nonblocking_backfill.zig so the red failure names the
// missing seam once instead of failing to compile.
//
// CANARY: REQ=REQ-VECTOR-INDEX-READER-QUIESCENCE-001; FEATURE="VectorIndex"; ASPECT=ReaderHandleApi; STATUS=TESTED; TEST=tests/test_vector_index_reader_quiescence.zig; OWNER=index; UPDATED=2026-09-01
// CANARY: REQ=REQ-VECTOR-INDEX-READER-QUIESCENCE-002; FEATURE="VectorIndex"; ASPECT=DropWaitsForReaders; STATUS=TESTED; TEST=tests/test_vector_index_reader_quiescence.zig; OWNER=index; UPDATED=2026-09-01
// CANARY: REQ=REQ-VECTOR-INDEX-READER-QUIESCENCE-003; FEATURE="VectorIndex"; ASPECT=SwapPinnedReader; STATUS=TESTED; TEST=tests/test_vector_index_reader_quiescence.zig; OWNER=index; UPDATED=2026-09-01
// CANARY: REQ=REQ-VECTOR-INDEX-READER-QUIESCENCE-004; FEATURE="VectorIndex"; ASPECT=EntryStatisticsNoDrift; STATUS=TESTED; TEST=tests/test_vector_index_reader_quiescence.zig; OWNER=index; UPDATED=2026-09-01
// CANARY: REQ=REQ-VECTOR-INDEX-READER-QUIESCENCE-005; FEATURE="VectorIndex"; ASPECT=MetadataOwnership; STATUS=TESTED; TEST=tests/test_vector_index_reader_quiescence.zig; OWNER=index; UPDATED=2026-09-01

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const IndexManager = index_manager.IndexManager;
const advanced_types = geode.index.advanced_types_index;
const VectorIndexWrapper = advanced_types.VectorIndexWrapper;
const VectorF32 = geode.types.vector.VectorF32;

/// The refcounted-handle seam. Kept as one comptime predicate so the red
/// failure below names the whole missing API at once instead of failing to
/// compile five tests independently.
const has_handle_api = @hasDecl(IndexManager, "requireVectorIndex") and
    @hasDecl(IndexManager, "releaseVectorIndex");

/// R4's seam, tracked separately: it is a different (metadata) lifetime bug
/// on the same read path and can land independently.
const has_metadata_alloc_api = @hasDecl(IndexManager, "findAdvancedVectorIndexForPropertyAlloc");

/// Resolve the pinned wrapper out of whatever `requireVectorIndex` returns —
/// see the header note on `H`. A compile error here is the fixer's signal that
/// the handle does not expose the wrapper at all.
fn wrapperPtr(handle: anytype) *VectorIndexWrapper {
    const T = @TypeOf(handle);
    if (T == *VectorIndexWrapper) return handle;
    const H = @typeInfo(T).pointer.child;
    if (@hasField(H, "wrapper")) {
        if (@FieldType(H, "wrapper") == *VectorIndexWrapper) return handle.wrapper;
        return &handle.wrapper;
    }
    if (@hasField(H, "index")) {
        if (@FieldType(H, "index") == *VectorIndexWrapper) return handle.index;
        return &handle.index;
    }
    @compileError("requireVectorIndex must return the pinned VectorIndexWrapper " ++
        "(directly, or as a `wrapper`/`index` member of a handle struct)");
}

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if ((if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts)) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

fn sleepMs(ms: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Real store, real catalog, real parser, real executor — identical shape to
/// tests/test_geode875_nonblocking_backfill.zig.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    pub fn run(self: *Harness, query: []const u8) !void {
        _ = try self.exec(query);
    }
};

fn mgr() *IndexManager {
    return index_manager.getGlobalIndexManager().?;
}

fn seed(h: *Harness, label: []const u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var buf: [160]u8 = undefined;
        try h.run(try std.fmt.bufPrint(
            &buf,
            "CREATE (:{s} {{i: {d}, emb: vectorf32([{d}.0, 0.0, 0.0, 0.0])}})",
            .{ label, i, i },
        ));
    }
}

fn queryVector(first: f32) VectorF32 {
    // Deliberately a value type over a caller-owned array; the callers below
    // keep the backing array alive for the whole search.
    return VectorF32{ .dim = 4, .data = &[_]f32{ first, 0.0, 0.0, 0.0 } };
}

/// A knn through an explicitly PINNED wrapper. Returns the number of rows;
/// a torn-down wrapper cannot answer this.
fn searchThroughHandle(handle: anytype, first: f32, k: u32) !usize {
    const results = try wrapperPtr(handle).search(queryVector(first), k, testing.allocator);
    defer testing.allocator.free(results);
    return results.len;
}

// ===========================================================================
// 1. THE REGRESSION TEST — the refcounted reader-handle API exists.
//    RED today: `IndexManager` has no requireVectorIndex/releaseVectorIndex at
//    all, so there is NO way for a knn reader to keep the wrapper alive across
//    a concurrent DROP INDEX or rebuild swap. Every read site listed in the
//    header dereferences a pointer the writer is free to `destroy`.
// ===========================================================================
test "vector index: readers can pin a wrapper for the duration of a knn" {
    if (comptime !has_handle_api) {
        // FIXER SEAM REQUIRED — see the file header for the exact contract.
        return error.MissingVectorIndexHandleApi;
    } else {
        var h = try Harness.init(testing.allocator);
        defer h.deinit();

        try h.run("CREATE GRAPH vq_basic");
        try h.run("USE GRAPH vq_basic");
        try seed(&h, "VqDoc", 6);
        try h.run("CREATE INDEX vq_idx ON VqDoc (emb) USING vector WITH (metric = 'l2')");

        // A pin that is never released must keep the wrapper addressable.
        const handle = try mgr().requireVectorIndex("vq_basic\x1fvq_idx");
        try testing.expect(try searchThroughHandle(handle, 2.0, 3) > 0);
        mgr().releaseVectorIndex(handle);

        // Once every reference is released the index drops cleanly.
        try testing.expect(try mgr().dropAdvancedIndex("vq_basic\x1fvq_idx", .vector_f32));

        // And a pin on a dropped/absent index is refused rather than handing
        // out a dangling pointer.
        try testing.expectError(error.IndexNotFound, mgr().requireVectorIndex("vq_basic\x1fvq_idx"));
    }
}

// ===========================================================================
// 2. R1 — DROP INDEX must not tear a wrapper down under a live reader.
//    A reader thread pins the index and keeps querying it; the main thread
//    issues the drop while that pin is held. The drop may block, but it may
//    NOT complete its teardown before the reader releases, and the reader's
//    knn must keep returning correct rows for the whole window.
// ===========================================================================
test "vector index: DROP INDEX waits for in-flight readers to quiesce" {
    if (comptime !has_handle_api) {
        return error.MissingVectorIndexHandleApi;
    } else {
        var h = try Harness.init(testing.allocator);
        defer h.deinit();

        try h.run("CREATE GRAPH vq_drop");
        try h.run("USE GRAPH vq_drop");
        try seed(&h, "VqDrop", 8);
        try h.run("CREATE INDEX vqd_idx ON VqDrop (emb) USING vector WITH (metric = 'l2')");

        const Reader = struct {
            pinned: std.atomic.Value(bool) = .init(false),
            released_at: std.atomic.Value(i64) = .init(0),
            rows_seen: std.atomic.Value(usize) = .init(0),
            failed: std.atomic.Value(bool) = .init(false),

            /// The reader ALWAYS releases after a bounded hold, so a correct
            /// fix can never make the main thread block forever here. A hang
            /// means the fix introduced a lock-ordering deadlock — the suite
            /// timeout is the backstop for that case.
            fn run(self: *@This()) void {
                const handle = mgr().requireVectorIndex("vq_drop\x1fvqd_idx") catch {
                    self.failed.store(true, .release);
                    self.pinned.store(true, .release);
                    return;
                };
                self.pinned.store(true, .release);

                // Simulate a long knn: hold the pin across real work.
                var total: usize = 0;
                var i: usize = 0;
                while (i < 5) : (i += 1) {
                    sleepMs(80);
                    total += searchThroughHandle(handle, 3.0, 3) catch {
                        self.failed.store(true, .release);
                        break;
                    };
                }
                self.rows_seen.store(total, .release);
                self.released_at.store(nowMs(), .release);
                mgr().releaseVectorIndex(handle);
            }
        };

        var reader = Reader{};
        const t = try std.Thread.spawn(.{}, Reader.run, .{&reader});

        // Wait for the pin to be established (bounded).
        const pin_deadline = nowMs() + 5_000;
        while (!reader.pinned.load(.acquire) and nowMs() < pin_deadline) sleepMs(5);
        try testing.expect(reader.pinned.load(.acquire));
        try testing.expect(!reader.failed.load(.acquire));

        const dropped = try mgr().dropAdvancedIndex("vq_drop\x1fvqd_idx", .vector_f32);
        const drop_done_at = nowMs();
        t.join();

        try testing.expect(dropped);
        try testing.expect(!reader.failed.load(.acquire));
        // The reader kept getting real answers out of the wrapper the whole time.
        try testing.expect(reader.rows_seen.load(.acquire) > 0);

        // The teardown did not observably finish before the last release.
        const released_at = reader.released_at.load(.acquire);
        if (drop_done_at < released_at) {
            std.debug.print(
                "\n[vector-index-uaf] dropAdvancedIndex returned at t={d}ms but the reader still held its pin until t={d}ms — the wrapper was destroyed under an in-flight knn\n",
                .{ drop_done_at, released_at },
            );
            return error.DropRacedInFlightReader;
        }

        // The index really is gone afterwards.
        try testing.expectError(error.IndexNotFound, mgr().requireVectorIndex("vq_drop\x1fvqd_idx"));
    }
}

// ===========================================================================
// 3. R2 — the rebuild SWAP must not invalidate a pinned reader, and a pin
//    taken AFTER the swap must resolve to the NEW wrapper.
// ===========================================================================
test "vector index: a pinned reader survives the rebuild swap, later pins see the new wrapper" {
    if (comptime !has_handle_api) {
        return error.MissingVectorIndexHandleApi;
    } else {
        var h = try Harness.init(testing.allocator);
        defer h.deinit();

        try h.run("CREATE GRAPH vq_swap");
        try h.run("USE GRAPH vq_swap");
        try seed(&h, "VqSwap", 6);
        try h.run("CREATE INDEX vqs_idx ON VqSwap (emb) USING vector WITH (metric = 'l2')");

        const Reader = struct {
            pinned: std.atomic.Value(bool) = .init(false),
            done: std.atomic.Value(bool) = .init(false),
            rows_seen: std.atomic.Value(usize) = .init(0),
            old_ptr: std.atomic.Value(usize) = .init(0),
            failed: std.atomic.Value(bool) = .init(false),

            fn run(self: *@This()) void {
                const handle = mgr().requireVectorIndex("vq_swap\x1fvqs_idx") catch {
                    self.failed.store(true, .release);
                    self.pinned.store(true, .release);
                    return;
                };
                self.old_ptr.store(@intFromPtr(wrapperPtr(handle)), .release);
                self.pinned.store(true, .release);

                // Hold across the swap the main thread performs.
                var total: usize = 0;
                var i: usize = 0;
                while (i < 5) : (i += 1) {
                    sleepMs(80);
                    total += searchThroughHandle(handle, 1.0, 3) catch {
                        self.failed.store(true, .release);
                        break;
                    };
                }
                self.rows_seen.store(total, .release);
                mgr().releaseVectorIndex(handle);
                self.done.store(true, .release);
            }
        };

        var reader = Reader{};
        const t = try std.Thread.spawn(.{}, Reader.run, .{&reader});
        const pin_deadline = nowMs() + 5_000;
        while (!reader.pinned.load(.acquire) and nowMs() < pin_deadline) sleepMs(5);
        try testing.expect(reader.pinned.load(.acquire));
        try testing.expect(!reader.failed.load(.acquire));

        const indexed = try mgr().rebuildAdvancedVectorIndexNonBlocking(
            testing.allocator,
            "vq_swap",
            "vq_swap\x1fvqs_idx",
        );
        try testing.expectEqual(@as(usize, 6), indexed);

        t.join();
        try testing.expect(!reader.failed.load(.acquire));
        try testing.expect(reader.rows_seen.load(.acquire) > 0);

        // A pin taken after the swap resolves to the freshly built wrapper,
        // not the retired one the reader was holding.
        const fresh = try mgr().requireVectorIndex("vq_swap\x1fvqs_idx");
        defer mgr().releaseVectorIndex(fresh);
        try testing.expect(@intFromPtr(wrapperPtr(fresh)) != reader.old_ptr.load(.acquire));
        try testing.expect(try searchThroughHandle(fresh, 1.0, 3) > 0);
    }
}

// ===========================================================================
// 4. R3 — entry statistics track reality. Expressible against the CURRENT API,
//    so this one is RED today on its own:
//      * the swap at index_manager.zig:2226 does `total_entries += indexed`
//        without ever subtracting the entries the retired wrapper carried, so
//        one rebuild of an N-row index reports 2N;
//      * `dropAdvancedIndex` decrements `total_indexes` but never
//        `total_entries`, so a dropped index's rows stay in the total forever.
//    Both are the same bookkeeping the refcounted teardown has to own.
// ===========================================================================
test "vector index: total_entries does not drift across rebuild and drop" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    try h.run("CREATE GRAPH vq_stats");
    try h.run("USE GRAPH vq_stats");
    try seed(&h, "VqStat", 5);
    try h.run("CREATE INDEX vqst_idx ON VqStat (emb) USING vector WITH (metric = 'l2')");

    const after_create = mgr().statistics.total_entries;
    try testing.expectEqual(@as(u64, 5), after_create);

    const indexed = try mgr().rebuildAdvancedVectorIndexNonBlocking(
        testing.allocator,
        "vq_stats",
        "vq_stats\x1fvqst_idx",
    );
    try testing.expectEqual(@as(usize, 5), indexed);

    const after_rebuild = mgr().statistics.total_entries;
    if (after_rebuild != 5) {
        std.debug.print(
            "\n[vector-index-uaf] after rebuilding a 5-row index, statistics.total_entries={d}; expected 5 — the swap adds the shadow's rows without retiring the old wrapper's\n",
            .{after_rebuild},
        );
        return error.RebuildDoubleCountsEntries;
    }

    try testing.expect(try mgr().dropAdvancedIndex("vq_stats\x1fvqst_idx", .vector_f32));
    const after_drop = mgr().statistics.total_entries;
    if (after_drop != 0) {
        std.debug.print(
            "\n[vector-index-uaf] after dropping the only vector index, statistics.total_entries={d}; expected 0 — dropAdvancedIndex decrements total_indexes but never total_entries\n",
            .{after_drop},
        );
        return error.DropLeavesEntriesInStatistics;
    }
}

// ===========================================================================
// 5. R4 — metadata handed to a caller outlives a concurrent DROP.
//    RED today: `findAdvancedVectorIndexForProperty` returns `meta.name`, the
//    manager's own allocation, and `removeAdvancedPropertyIndex`
//    (index_manager.zig:2478-2485) frees it out from under every caller in
//    eval.zig / statement_dispatcher.zig. The owned-duplicate spelling is
//    pinned here (see R4 in the header) so the fix cannot regress to a
//    borrowed slice without failing this test.
// ===========================================================================
test "vector index: the index name resolved for a property is owned by the caller" {
    if (comptime !has_metadata_alloc_api) {
        // FIXER SEAM REQUIRED:
        //   pub fn findAdvancedVectorIndexForPropertyAlloc(
        //       self: *IndexManager,
        //       allocator: std.mem.Allocator,
        //       property: []const u8,
        //   ) !?[]u8   // caller frees; must be a duplicate, never `meta.name`
        return error.MissingVectorIndexMetadataOwnershipApi;
    } else {
        var h = try Harness.init(testing.allocator);
        defer h.deinit();

        try h.run("CREATE GRAPH vq_meta");
        try h.run("USE GRAPH vq_meta");
        try seed(&h, "VqMeta", 4);
        try h.run("CREATE INDEX vqm_idx ON VqMeta (emb) USING vector WITH (metric = 'l2')");

        const name = (try mgr().findAdvancedVectorIndexForPropertyAlloc(testing.allocator, "emb")) orelse
            return error.VectorIndexNotResolvedForProperty;
        defer testing.allocator.free(name);
        try testing.expectEqualStrings("vq_meta\x1fvqm_idx", name);

        // The DROP frees every manager-owned metadata string. A borrowed
        // result would be dangling on the next line; an owned duplicate is
        // still readable and still correct.
        try testing.expect(try mgr().dropAdvancedIndex("vq_meta\x1fvqm_idx", .vector_f32));
        try testing.expectEqualStrings("vq_meta\x1fvqm_idx", name);

        // ...and the property no longer resolves to anything.
        const gone = try mgr().findAdvancedVectorIndexForPropertyAlloc(testing.allocator, "emb");
        if (gone) |g| {
            defer testing.allocator.free(g);
            return error.DroppedIndexStillResolvesForProperty;
        }
    }
}
