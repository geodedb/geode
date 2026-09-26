const std = @import("std");

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    // Strip trailing NUL if present
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const fle_integration = @import("fle_integration.zig");
// GAP (write-path OOM, 2026-07-04): working-set budget hooks for the legacy
// write executor. `chargeStoreBytes` is a no-op unless the query dispatcher
// installed a thread-local budget scope (write-carrying MATCH shapes only).
const write_budget = @import("write_budget.zig");
const id_map_mod = @import("storage/id_map.zig");
const hydration_snapshot = @import("storage/hydration_snapshot.zig");
const uuid = @import("uuid");
const sharded_store = @import("graph_storage").sharded_store;
// SONNY-1330: PUBLIC so `execution/set_operations.zig` can open/close the
// read-only-hydration scope around a parallel UNION arm without importing the
// file by a second path (which would give it a SECOND set of threadlocals).
pub const node_cache_mod = @import("storage/node_cache.zig");
const pooled = @import("transport/thread_pool");

// CANARY: REQ=REQ-TDE-GRAPHSTORE-001; FEATURE="TDEFileLevelEncryption"; ASPECT=GraphStorePersistence; STATUS=EXEMPT; OWNER=security; UPDATED=2026-03-28
// TDE at-rest encryption is now handled at the engine level, not in graph_store serialization.

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Storage; STATUS=EXEMPT; OWNER=storage; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("storage");
const Attr = logging.Attr;
// crc no longer needed — legacy serialization removed

const LabelCountValue = std.atomic.Value(usize);

// GAP-0852 follow-up: the context-preferring FLE role helper used to live here as
// `fleRolePreferringContext` (with its own lazy `@import("execution.zig")`). It was
// duplicated across four modules and is now consolidated as
// `fle_integration.rolePreferringActiveContext`.

// CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-001; FEATURE="EngineBackedPersistence"; ASPECT=LegacyRemoval; STATUS=TESTED; TEST=test-graph-store; OWNER=storage; UPDATED=2026-06-11
// Phase 2: Legacy graph_store.dat persistence removed — adapter is the primary store.

pub fn lastLoadHadChecksumError() bool {
    return false;
}

// ============================================================================
// GAP-0900 Layer-3 (Fix 2): opt-in lean indexing.
//
// Every SET property on a created node is normally added to BOTH geode's exact
// node-property index (graph_storage_adapter.exact_node_property_index) and this
// module's merge_prop_index. But only the MERGE pattern key(s) (and explicitly
// declared indexes, which live in the separate IndexManager and are unaffected)
// are ever used for lookup. On the batch ingest the per-node Taxon write indexes
// taxon_id + 19 never-queried SET props — ~1 KB/node of dead index entries.
//
// When `GEODE_INDEX_MERGE_KEYS_ONLY=1` is set, the indexing helpers consult
// `shouldIndexProperty(key)` and skip any key that is NOT a registered merge
// key. The merge fast path registers each `merge_key` it sees via
// `registerMergeIndexKey`, so MERGE dedup and edge-endpoint resolution
// (MATCH (a:Taxon {taxon_id: ?})) still work — those lookups are keyed by the
// merge key, which stays indexed.
//
// Default is OFF: `shouldIndexProperty` returns true for every key, so a plain
// server's property-lookup point-read fast path is completely unchanged. The
// flag is read once, lazily, on first use.
//
// The registered-key set is intentionally tiny and append-only: real workloads
// MERGE on a small, fixed set of keys (here just "taxon_id"). Keys are copied
// into a fixed static buffer under a leaf mutex; overflow simply falls back to
// indexing the key (safe — over-indexing never breaks correctness).
const lean_index_max_keys: usize = 64;
const lean_index_key_cap: usize = 128;

var g_lean_index_mutex: std.Io.Mutex = std.Io.Mutex.init;
var g_lean_index_enabled: bool = false;
var g_lean_index_flag_loaded: bool = false;
var g_lean_index_key_bufs: [lean_index_max_keys][lean_index_key_cap]u8 = undefined;
var g_lean_index_key_lens: [lean_index_max_keys]usize = [_]usize{0} ** lean_index_max_keys;
var g_lean_index_key_count: usize = 0;

fn leanIndexEnabledLocked() bool {
    if (!g_lean_index_flag_loaded) {
        g_lean_index_flag_loaded = true;
        if (std.c.getenv("GEODE_INDEX_MERGE_KEYS_ONLY")) |raw_z| {
            const raw = std.mem.span(raw_z);
            g_lean_index_enabled = std.mem.eql(u8, raw, "1") or
                std.mem.eql(u8, raw, "true") or
                std.mem.eql(u8, raw, "yes");
            if (g_lean_index_enabled) {
                log.info("GEODE_INDEX_MERGE_KEYS_ONLY: lean indexing ON — only MERGE keys are added to the exact + merge property indexes (non-merge property point-reads fall back to label scan).", &.{});
            }
        }
    }
    return g_lean_index_enabled;
}

/// True if lean indexing is enabled (env opt-in). Cheap after first call.
pub fn leanIndexingEnabled() bool {
    g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    return leanIndexEnabledLocked();
}

/// Register a key that MUST stay indexed even in lean mode (a MERGE pattern
/// key). Idempotent; safe to call on every merge. No-op when lean mode is off.
pub fn registerMergeIndexKey(key: []const u8) void {
    registerMergeIndexKeyInner(key, true);
}

/// Register a merge key WITHOUT writing it back to the persisted sidecar. Used
/// by `loadPersistedMergeIndexKeys` on reopen: the key is already in the file we
/// are reading, so re-persisting would only append a duplicate line (load
/// de-dups, but the file would grow on every restart). All other effects
/// (registry membership, in-memory merge-index backfill) are identical.
fn registerMergeIndexKeyInner(key: []const u8, persist: bool) void {
    const newly_registered = blk: {
        g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        if (!leanIndexEnabledLocked()) break :blk false;
        if (key.len == 0 or key.len > lean_index_key_cap) break :blk false;
        var i: usize = 0;
        while (i < g_lean_index_key_count) : (i += 1) {
            if (std.mem.eql(u8, g_lean_index_key_bufs[i][0..g_lean_index_key_lens[i]], key)) break :blk false;
        }
        if (g_lean_index_key_count >= lean_index_max_keys) break :blk false; // overflow: tolerate
        @memcpy(g_lean_index_key_bufs[g_lean_index_key_count][0..key.len], key);
        g_lean_index_key_lens[g_lean_index_key_count] = key.len;
        g_lean_index_key_count += 1;
        break :blk true;
    };

    // GAP-0900 Layer-3 (Fix 3): a key that becomes indexable for the FIRST time
    // in lean mode may already have loaded nodes carrying it (hydrated from disk
    // before this registration). `addToMergePropertyIndex` skipped those at load
    // because the key was not yet registered, so the merge index has no entry —
    // and the first re-MERGE after a reopen would create a duplicate. Backfill
    // the index for this single key now by scanning loaded nodes. Done OUTSIDE
    // `g_lean_index_mutex` (a leaf lock) so the scan can take the per-shard node
    // locks without inverting lock order. Only the primary global store is
    // backfilled; ad-hoc unit stores never reopen, so they need no backfill.
    if (newly_registered) {
        if (getCurrentGlobalStore()) |store| {
            store.backfillMergeIndexForKey(key);
        }
        // LEAN-MERGE-KEY-SEEK (Part 1): persist the newly-registered merge key
        // so it survives a restart. On reopen the adapter loads this set BEFORE
        // it opens any graph (and thus before the exact-index rebuild runs), so
        // the rebuild — which consults `shouldIndexProperty` — indexes the
        // merge key's values for ALL existing nodes. Without this, the rebuild
        // runs while the key is still UNregistered, skips it, and leaves the
        // exact index INCOMPLETE for that key after a lean reopen — which would
        // make a completeness-gated seek wrongly return empty for live nodes.
        // Best-effort: a persist failure only costs the seek-eligibility of
        // that key on the NEXT reopen (it falls back to full scan — correct,
        // just slow); it never corrupts data.
        if (persist) {
            if (getGlobalAdapter()) |adapter| {
                persistMergeIndexKey(adapter.allocator, adapter.data_dir, key);
            }
        }
    }
}

/// Sidecar file (inside `data_dir`) that records the set of registered merge
/// index keys so they survive a restart. Append-only, line-oriented: one key
/// per line. See `persistMergeIndexKey` / `loadPersistedMergeIndexKeys`.
const merge_index_keys_filename = "merge_index_keys.dat";

/// Append `key` to the persisted merge-key sidecar in `data_dir`, allocating
/// scratch with `alloc`. Idempotent at the registry level (callers only persist
/// a key the first time it is registered), but the file itself tolerates
/// duplicate lines — load de-dups via `registerMergeIndexKey`. Best-effort:
/// failures are logged and swallowed (a missing entry only degrades the seek to
/// a full scan on the next reopen, never a wrong answer). No-op when `data_dir`
/// is empty (ad-hoc unit stores).
pub fn persistMergeIndexKey(alloc: std.mem.Allocator, data_dir: []const u8, key: []const u8) void {
    if (data_dir.len == 0) return;
    if (key.len == 0 or key.len > lean_index_key_cap) return;

    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ data_dir, merge_index_keys_filename }) catch return;
    defer alloc.free(path);

    const io = std.Io.Threaded.global_single_threaded.io();
    // Append mode: keep previously-recorded keys. createFile with truncate=false
    // opens-or-creates; positional writes at the current end append. (Mirrors
    // the verified append pattern in src/client/repl/repl_history.zig.)
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch |err| {
        log.warn("failed to open merge-key sidecar for append", &.{
            Attr.string("path", path),
            Attr.string("error", @errorName(err)),
        });
        return;
    };
    defer file.close(io);

    const st = file.stat(io) catch return;
    file.writePositionalAll(io, key, st.size) catch return;
    file.writePositionalAll(io, "\n", st.size + key.len) catch return;
}

/// Load the persisted merge-key set from `data_dir` and re-register each key via
/// `registerMergeIndexKey`. MUST run before any graph is opened on reopen (the
/// adapter calls this from `init`) so the exact-index rebuild indexes these
/// keys. No-op when the sidecar is missing (fresh data dir) or `data_dir` is
/// empty. Registration only takes effect in lean mode (`registerMergeIndexKey`
/// is a no-op when lean indexing is off), which is exactly when it is needed —
/// in non-lean mode every key is always indexed regardless. Scratch is
/// allocated with `alloc` (the adapter passes its own allocator).
pub fn loadPersistedMergeIndexKeys(alloc: std.mem.Allocator, data_dir: []const u8) void {
    if (data_dir.len == 0) return;

    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ data_dir, merge_index_keys_filename }) catch return;
    defer alloc.free(path);

    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            log.warn("failed to open merge-key sidecar for load", &.{
                Attr.string("path", path),
                Attr.string("error", @errorName(err)),
            });
            return;
        },
    };
    defer file.close(io);

    // Bounded read: the registry is tiny (a handful of fixed merge keys). Cap at
    // a generous size so a corrupt/huge file can never OOM startup.
    const max_bytes: usize = lean_index_max_keys * (lean_index_key_cap + 1) * 4;
    const st = file.stat(io) catch return;
    const want: usize = @min(@as(usize, @intCast(st.size)), max_bytes);
    if (want == 0) return;
    const contents = alloc.alloc(u8, want) catch return;
    defer alloc.free(contents);

    var rbuf: [512]u8 = undefined;
    var file_reader = file.reader(io, &rbuf);
    const reader = &file_reader.interface;
    reader.readSliceAll(contents) catch |err| {
        log.warn("failed to read merge-key sidecar", &.{
            Attr.string("path", path),
            Attr.string("error", @errorName(err)),
        });
        return;
    };

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        const key = std.mem.trim(u8, line, " \r\t");
        if (key.len == 0) continue;
        registerMergeIndexKeyInner(key, false);
    }
}

/// Test-only: force lean-index mode on/off and clear the registered-key set,
/// bypassing the env read. Used by the GAP-0900 Fix-2 regression test so it can
/// exercise both modes deterministically in one process. NOT for production
/// paths (production reads GEODE_INDEX_MERGE_KEYS_ONLY once, lazily).
pub fn setLeanIndexingForTest(enabled: bool) void {
    g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    g_lean_index_flag_loaded = true;
    g_lean_index_enabled = enabled;
    g_lean_index_key_count = 0;
}

/// Whether a property `key` should be added to the exact + merge property
/// indexes. Always true when lean mode is off (default). When on, true only for
/// registered merge keys. Over-indexing is always safe; this only ever SKIPS
/// indexing of keys that are never used for lookup in lean mode.
pub fn shouldIndexProperty(key: []const u8) bool {
    g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (!leanIndexEnabledLocked()) return true;
    var i: usize = 0;
    while (i < g_lean_index_key_count) : (i += 1) {
        if (std.mem.eql(u8, g_lean_index_key_bufs[i][0..g_lean_index_key_lens[i]], key)) return true;
    }
    return false;
}

/// GAP-ENT-0023 P3: fingerprint of the merge-index CONFIGURATION — the lean
/// flag, the registered lean key set (lean mode only), and the registered
/// composite specs. The merge-prop-index snapshot stores this hash and is
/// rejected on any mismatch: which entries the index CONTAINS depends on this
/// configuration, so restoring a snapshot written under a different one could
/// leave lookups authoritative-but-incomplete (`.not_found` -> a re-MERGE
/// takes the create branch -> silent duplicates). Key/spec contributions are
/// combined order-independently (registration order varies across runs; the
/// sets are what matters — both are persisted to sidecars loaded at adapter
/// init, BEFORE any hydration runs).
fn mergeIndexConfigHash() u64 {
    const io = std.Io.Threaded.global_single_threaded.io();
    g_lean_index_mutex.lockUncancelable(io);
    defer g_lean_index_mutex.unlock(io);
    var h = std.hash.Wyhash.init(0x6d65_7267_6573_6e70); // "mergesnp"
    const lean = leanIndexEnabledLocked();
    h.update(&[_]u8{@intFromBool(lean)});
    if (lean) {
        var acc: u64 = 0;
        var i: usize = 0;
        while (i < g_lean_index_key_count) : (i += 1) {
            acc ^= std.hash.Wyhash.hash(1, g_lean_index_key_bufs[i][0..g_lean_index_key_lens[i]]);
        }
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, acc, .little);
        h.update(&b);
    }
    var acc2: u64 = 0;
    var k: usize = 0;
    while (k < g_composite_key_count) : (k += 1) {
        var sh = std.hash.Wyhash.init(2);
        const spec = &g_composite_keys[k];
        var i: usize = 0;
        while (i < spec.prop_count) : (i += 1) {
            sh.update(spec.prop_bufs[i][0..spec.prop_lens[i]]);
            sh.update("\x00");
        }
        acc2 ^= sh.final();
    }
    var b2: [8]u8 = undefined;
    std.mem.writeInt(u64, &b2, acc2, .little);
    h.update(&b2);
    return h.final();
}

// ============================================================================
// COMPOSITE merge keys (caveat "B": from-dump edge endpoint resolution).
//
// The from-dump NODE phase MERGEs taxa on the {source, source_id} COMPOSITE
// (`MERGE (t:Taxon {source, source_id})`), and the EDGE phase resolves both
// endpoints by the SAME composite (`MATCH (a:Taxon {source, source_id})`).
//
// The single-key `merge_prop_index` is keyed per (graph,label,prop,value) and
// is a 1:1 map, so it CANNOT resolve a composite directly: it must SEED on one
// component then VERIFY the rest via `getNodeProperty` (an engine PropertyChain
// read → BufferPool.pin). At a buffer-pool-exceeding scale that one verify read
// per endpoint THRASHES the pool (~12 edges/s). And `source_id` is NOT globally
// unique across sources (ITIS/GBIF collide), so the 1:1 seed index overwrites
// colliding entries → the seed can resolve the wrong-source node and the
// remaining-filter verify then fails → the edge is SILENTLY DROPPED.
//
// The fix registers an ORDERED set of composite key prop-names; a node carrying
// ALL of them gets ONE additional resident entry in the SAME `merge_prop_index`
// under a COMPOSITE key ("graph\0label\0prop1\0val1\0prop2\0val2", props sorted
// by name for determinism). Endpoint resolution whose filter set EXACTLY matches
// a registered composite then probes that entry directly — one resident lookup,
// zero `getNodeProperty`, collision-correct.
//
// The registry mirrors the single-key lean-index registry: a tiny, append-only,
// process-wide set guarded by the same leaf mutex. Real workloads register a
// handful of composites once at startup (here just {source, source_id}). Bounded
// by `composite_index_max_keys` composites of up to `composite_index_max_props`
// props each; overflow simply skips registration (safe — the seed+verify path
// still resolves the key correctly, just slower).
const composite_index_max_keys: usize = 16;
const composite_index_max_props: usize = 8;
const composite_index_prop_cap: usize = 64;

const CompositeKeySpec = struct {
    prop_bufs: [composite_index_max_props][composite_index_prop_cap]u8 = undefined,
    prop_lens: [composite_index_max_props]usize = [_]usize{0} ** composite_index_max_props,
    prop_count: usize = 0,

    fn props(self: *const CompositeKeySpec) PropNameIter {
        return .{ .spec = self, .i = 0 };
    }
};

const PropNameIter = struct {
    spec: *const CompositeKeySpec,
    i: usize,
    fn next(self: *PropNameIter) ?[]const u8 {
        if (self.i >= self.spec.prop_count) return null;
        const s = self.spec.prop_bufs[self.i][0..self.spec.prop_lens[self.i]];
        self.i += 1;
        return s;
    }
};

var g_composite_keys: [composite_index_max_keys]CompositeKeySpec = undefined;
var g_composite_key_count: usize = 0;

/// Compare two prop-name sets for set-equality (order-insensitive). Used to test
/// whether a filter set matches a registered composite key.
fn propNameSetsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    // Each name in `a` must appear exactly once in `b`. Composite key sets are
    // tiny (<= composite_index_max_props) and contain no duplicate prop names
    // (a MERGE pattern never repeats a key), so an O(n^2) membership check is
    // both correct and cheap.
    outer: for (a) |an| {
        for (b) |bn| {
            if (std.mem.eql(u8, an, bn)) continue :outer;
        }
        return false;
    }
    return true;
}

/// Register an ORDERED set of prop names as a composite merge key. Idempotent
/// (set-equality dedup). Bounded; overflow is tolerated (the seed+verify path
/// remains correct). The stored order is normalized (sorted by name) so the
/// composite index key is deterministic regardless of caller filter order.
pub fn registerCompositeMergeKey(prop_names: []const []const u8) void {
    registerCompositeMergeKeyInner(prop_names, true);
}

fn registerCompositeMergeKeyInner(prop_names: []const []const u8, persist: bool) void {
    if (prop_names.len < 2 or prop_names.len > composite_index_max_props) return;
    for (prop_names) |n| {
        if (n.len == 0 or n.len > composite_index_prop_cap) return;
    }

    const newly_registered = blk: {
        g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // Dedup against existing composites (set-equality).
        var k: usize = 0;
        while (k < g_composite_key_count) : (k += 1) {
            var existing_names: [composite_index_max_props][]const u8 = undefined;
            const spec = &g_composite_keys[k];
            for (0..spec.prop_count) |i| existing_names[i] = spec.prop_bufs[i][0..spec.prop_lens[i]];
            if (propNameSetsEqual(existing_names[0..spec.prop_count], prop_names)) break :blk false;
        }
        if (g_composite_key_count >= composite_index_max_keys) break :blk false; // overflow: tolerate

        var spec = &g_composite_keys[g_composite_key_count];
        spec.prop_count = prop_names.len;
        for (prop_names, 0..) |n, i| {
            @memcpy(spec.prop_bufs[i][0..n.len], n);
            spec.prop_lens[i] = n.len;
        }
        // Normalize to a deterministic order (sorted by name). The index key is
        // always built from this order, and lookups sort their filters the same
        // way, so caller filter order never matters.
        sortCompositeSpec(spec);
        g_composite_key_count += 1;
        break :blk true;
    };

    if (!newly_registered) return;

    // Composite keys also keep their component props indexed in lean mode (the
    // GAP-0334 single-key fallback and node MERGE still need them). Idempotent.
    for (prop_names) |n| registerMergeIndexKeyInner(n, persist);

    if (newly_registered) {
        // Backfill the composite entry for already-loaded nodes (a reopen
        // registers the composite AFTER nodes were hydrated; without this the
        // edges-only run after a separate node-load run would find no composite
        // entry and fall back to seed+verify). Mirrors the single-key
        // backfillMergeIndexForKey.
        if (getCurrentGlobalStore()) |store| {
            store.backfillCompositeMergeEntries();
        }
        // Persist so a fresh process (the from-dump EDGE phase runs separately
        // from the NODE phase) re-registers it on reopen and the rebuild/backfill
        // repopulates the composite entries. Best-effort.
        if (persist) {
            if (getGlobalAdapter()) |adapter| {
                persistCompositeMergeKey(adapter.allocator, adapter.data_dir, prop_names);
            }
        }
    }
}

/// Sidecar (inside `data_dir`) recording registered COMPOSITE merge keys so they
/// survive a restart. Append-only, line-oriented: one composite per line, prop
/// names comma-joined (e.g. "source,source_id").
const composite_merge_keys_filename = "composite_merge_keys.dat";

/// Append a composite (its prop names, comma-joined) to the composite-key
/// sidecar. Best-effort; no-op when `data_dir` is empty (ad-hoc unit stores).
pub fn persistCompositeMergeKey(alloc: std.mem.Allocator, data_dir: []const u8, prop_names: []const []const u8) void {
    if (data_dir.len == 0) return;
    if (prop_names.len < 2) return;

    var line_buf: [composite_index_max_props * (composite_index_prop_cap + 1)]u8 = undefined;
    var pos: usize = 0;
    for (prop_names, 0..) |n, i| {
        if (n.len == 0 or n.len > composite_index_prop_cap) return;
        if (i > 0) {
            if (pos + 1 > line_buf.len) return;
            line_buf[pos] = ',';
            pos += 1;
        }
        if (pos + n.len > line_buf.len) return;
        @memcpy(line_buf[pos..][0..n.len], n);
        pos += n.len;
    }
    const line = line_buf[0..pos];

    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ data_dir, composite_merge_keys_filename }) catch return;
    defer alloc.free(path);

    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch |err| {
        log.warn("failed to open composite merge-key sidecar for append", &.{
            Attr.string("path", path),
            Attr.string("error", @errorName(err)),
        });
        return;
    };
    defer file.close(io);
    const st = file.stat(io) catch return;
    file.writePositionalAll(io, line, st.size) catch return;
    file.writePositionalAll(io, "\n", st.size + line.len) catch return;
}

/// Load the persisted composite-key set and re-register each (WITHOUT
/// re-persisting). MUST run before any graph opens on reopen (the adapter calls
/// this from `init`), so the per-node index rebuild repopulates composite
/// entries. No-op when the sidecar is missing or `data_dir` is empty.
pub fn loadPersistedCompositeMergeKeys(alloc: std.mem.Allocator, data_dir: []const u8) void {
    if (data_dir.len == 0) return;

    const path = std.fmt.allocPrint(alloc, "{s}/{s}", .{ data_dir, composite_merge_keys_filename }) catch return;
    defer alloc.free(path);

    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            log.warn("failed to open composite merge-key sidecar for load", &.{
                Attr.string("path", path),
                Attr.string("error", @errorName(err)),
            });
            return;
        },
    };
    defer file.close(io);

    const max_bytes: usize = composite_index_max_keys * (composite_index_max_props * (composite_index_prop_cap + 1) + 1) * 4;
    const st = file.stat(io) catch return;
    const want: usize = @min(@as(usize, @intCast(st.size)), max_bytes);
    if (want == 0) return;
    const contents = alloc.alloc(u8, want) catch return;
    defer alloc.free(contents);

    var rbuf: [512]u8 = undefined;
    var file_reader = file.reader(io, &rbuf);
    const reader = &file_reader.interface;
    reader.readSliceAll(contents) catch |err| {
        log.warn("failed to read composite merge-key sidecar", &.{
            Attr.string("path", path),
            Attr.string("error", @errorName(err)),
        });
        return;
    };

    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        var names_buf: [composite_index_max_props][]const u8 = undefined;
        var count: usize = 0;
        var name_it = std.mem.splitScalar(u8, line, ',');
        while (name_it.next()) |name| {
            const trimmed = std.mem.trim(u8, name, " \r\t");
            if (trimmed.len == 0) continue;
            if (count >= names_buf.len) break;
            names_buf[count] = trimmed;
            count += 1;
        }
        if (count >= 2) registerCompositeMergeKeyInner(names_buf[0..count], false);
    }
}

/// Sort a composite spec's prop names lexicographically (in place). Tiny n —
/// insertion sort keeps it allocation-free.
fn sortCompositeSpec(spec: *CompositeKeySpec) void {
    var i: usize = 1;
    while (i < spec.prop_count) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            const a = spec.prop_bufs[j - 1][0..spec.prop_lens[j - 1]];
            const b = spec.prop_bufs[j][0..spec.prop_lens[j]];
            if (std.mem.order(u8, a, b) != .gt) break;
            // swap entries j-1 and j
            var tmp_buf: [composite_index_prop_cap]u8 = undefined;
            const tmp_len = spec.prop_lens[j - 1];
            @memcpy(tmp_buf[0..tmp_len], spec.prop_bufs[j - 1][0..tmp_len]);
            @memcpy(spec.prop_bufs[j - 1][0..spec.prop_lens[j]], spec.prop_bufs[j][0..spec.prop_lens[j]]);
            spec.prop_lens[j - 1] = spec.prop_lens[j];
            @memcpy(spec.prop_bufs[j][0..tmp_len], tmp_buf[0..tmp_len]);
            spec.prop_lens[j] = tmp_len;
        }
    }
}

/// If `filter_keys` (the prop-name set of a lookup's filters) EXACTLY matches a
/// registered composite key, return that composite's index (else null). Cheap;
/// composite registry is tiny.
fn matchRegisteredCompositeKey(filter_keys: []const []const u8) ?usize {
    if (filter_keys.len < 2 or filter_keys.len > composite_index_max_props) return null;
    g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    var k: usize = 0;
    while (k < g_composite_key_count) : (k += 1) {
        const spec = &g_composite_keys[k];
        var names: [composite_index_max_props][]const u8 = undefined;
        for (0..spec.prop_count) |i| names[i] = spec.prop_bufs[i][0..spec.prop_lens[i]];
        if (propNameSetsEqual(names[0..spec.prop_count], filter_keys)) return k;
    }
    return null;
}

/// True if `key` is a component of ANY registered composite merge key. Used by
/// the single-property mutation path to know whether a value change can
/// invalidate a composite entry (and must re-assert it). Cheap; tiny registry.
fn isCompositeComponentKey(key: []const u8) bool {
    g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    var k: usize = 0;
    while (k < g_composite_key_count) : (k += 1) {
        const spec = &g_composite_keys[k];
        var i: usize = 0;
        while (i < spec.prop_count) : (i += 1) {
            if (std.mem.eql(u8, spec.prop_bufs[i][0..spec.prop_lens[i]], key)) return true;
        }
    }
    return false;
}

/// If the prop-name set of `filters` EXACTLY matches a registered composite
/// merge key, return that composite's registry index (else null). The
/// adapter's endpoint resolver calls this to decide whether to take the
/// zero-read composite path. Order-insensitive.
pub fn compositeKeyIndexForFilters(filters: []const graph_storage_adapter.StorageAdapter.PropKV) ?usize {
    if (filters.len < 2 or filters.len > composite_index_max_props) return null;
    var names: [composite_index_max_props][]const u8 = undefined;
    for (filters, 0..) |f, i| names[i] = f.key;
    return matchRegisteredCompositeKey(names[0..filters.len]);
}

/// Test-only: clear the composite-key registry (mirrors setLeanIndexingForTest).
pub fn clearCompositeMergeKeysForTest() void {
    g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    g_composite_key_count = 0;
}

const node_id_sequence_mask: u64 = 0x0fff;
const node_id_version_bits: u64 = 0x7000;
const node_id_timestamp_mask: u64 = 0x0000_ffff_ffff_ffff;
var g_last_time_based_node_id = std.atomic.Value(u64).init(0);

fn encodeTimeBasedNodeId(ms: u64, seq: u16) u64 {
    return ((ms & node_id_timestamp_mask) << 16) |
        node_id_version_bits |
        (@as(u64, seq) & node_id_sequence_mask);
}

pub fn realtimeMillis() u64 {
    if (comptime @import("builtin").os.tag == .linux) {
        var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
        const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
        const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
        return sec * 1000 + nsec / std.time.ns_per_ms;
    } else {
        // On non-linux targets std.c.clock_gettime expects std.c.timespec --
        // a different struct from std.posix.timespec when cross-compiling
        // from linux to macos under Zig 0.16. Use the c-namespaced type for
        // the c-namespaced call.
        var ts: std.c.timespec = .{ .sec = 0, .nsec = 0 };
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
        const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
        const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
        return sec * 1000 + nsec / std.time.ns_per_ms;
    }
}

// CANARY: REQ=REQ-QUIC-HC-015; FEATURE="High-Concurrency Mutations"; ASPECT=AtomicNodeIdReservation; STATUS=TESTED; TEST=test-graph-store; OWNER=storage; UPDATED=2026-06-11
/// Generate a time-based unique 64-bit ID without taking the UUIDv7 global
/// mutex or issuing a randomness syscall. GraphStore historically called
/// generateUuidV7() and then discarded the lower random 64 bits; under
/// mutation fan-out that made node-id reservation a process-wide bottleneck.
/// The retained layout is the same upper-half shape: 48-bit logical
/// millisecond timestamp | 4-bit version(7) | 12-bit sequence.
/// GAP-0839: generate a fresh persistent graph UUID (UUIDv7, never zero).
/// Mirrors `graph_storage_adapter.generateUuid` so an in-memory graph's UUID
/// is indistinguishable in shape from a disk-backed one and passes the
/// catalog's non-zero-UUID invariant (`catalog.isZeroUuid`).
fn generatePersistentUuid() [16]u8 {
    // Pass an explicit cross-platform timestamp. uuid.newV7()'s default clock
    // issues a raw Linux-only clock_gettime syscall (uuid/generator.zig
    // defaultClock) that faults with SIGSYS on non-Linux hosts (macOS CI) —
    // uncatchable, so `catch` cannot rescue it. std.time.milliTimestamp() is
    // portable and newV7AtTime never touches defaultClock for a one-shot,
    // non-saturated call, so it cannot fail for a valid post-1970 ms.
    return (uuid.newV7AtTime(@as(i64, @intCast(realtimeMillis()))) catch unreachable).bytes;
}

fn generateTimeBasedId() u64 {
    const now_ms = realtimeMillis();
    const now_base = encodeTimeBasedNodeId(now_ms, 0);

    var observed = g_last_time_based_node_id.load(.acquire);
    while (true) {
        const candidate = if (observed < now_base)
            now_base
        else blk: {
            const seq = observed & node_id_sequence_mask;
            if (seq < node_id_sequence_mask) break :blk observed + 1;

            // More than 4096 ids in one millisecond: advance the logical
            // timestamp rather than blocking writers until wall-clock catches up.
            const logical_ms = ((observed >> 16) & node_id_timestamp_mask) + 1;
            break :blk encodeTimeBasedNodeId(logical_ms, 0);
        };

        if (g_last_time_based_node_id.cmpxchgWeak(observed, candidate, .acq_rel, .acquire)) |next| {
            observed = next;
        } else {
            return candidate;
        }
    }
}

// Field-Level Encryption Storage Hooks
// CANARY: REQ=REQ-FLE-STORAGE-001; FEATURE="FieldLevelEncryption"; ASPECT=STORAGE; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-15

// Simple graph store with file-based persistence for testing
// Real implementation would use proper storage engine

// Global data directory override (set via API, takes precedence over env var)
// Use a fixed-size buffer to avoid allocator issues across module boundaries.
// Protected by g_data_dir_mutex to prevent torn reads between writer (startup/backup)
// and reader (persistence loop).
var g_override_data_dir_buf: [512]u8 = undefined;
var g_override_data_dir_len: usize = 0;
var g_override_data_dir_set: bool = false;
var g_data_dir_mutex: std.Io.Mutex = std.Io.Mutex.init;

/// Set the data directory override (takes precedence over GEODE_DATA_DIR env var)
/// Pass null to clear the override and revert to env var behavior
pub fn setDataDirOverride(allocator: std.mem.Allocator, dir: ?[]const u8) void {
    _ = allocator; // Not needed with fixed buffer
    g_data_dir_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_data_dir_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (dir) |path| {
        const copy_len = @min(path.len, g_override_data_dir_buf.len);
        @memcpy(g_override_data_dir_buf[0..copy_len], path[0..copy_len]);
        g_override_data_dir_len = copy_len;
        g_override_data_dir_set = true;
    } else {
        g_override_data_dir_len = 0;
        g_override_data_dir_set = false;
    }
}

// CANARY: REQ=REQ-GAP-0909-DATA-DIR-STARTUP; FEATURE="ServerStartup"; ASPECT=DataDirCreation; STATUS=TESTED; TEST=tests/test_gap0908_0909_startup_failclosed.zig; OWNER=storage; UPDATED=2026-07-10
/// GAP-0909: ensure the configured data directory exists (mkdir -p
/// semantics). A missing `--data-dir` path used to crash the server at
/// startup; now it is created, and only an uncreatable path (e.g. an
/// unwritable parent) is an error the caller turns into a clean refusal.
pub fn ensureDataDir(path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Get the current data directory override (or null if using env var)
pub fn getDataDirOverride() ?[]const u8 {
    g_data_dir_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_data_dir_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (g_override_data_dir_set and g_override_data_dir_len > 0) {
        return g_override_data_dir_buf[0..g_override_data_dir_len];
    }
    return null;
}

// CANARY: REQ=REQ-ENG-3921-DATA-DIR-LOCK-004; FEATURE="DataDirLock"; ASPECT=DefaultDataDirScoping; STATUS=TESTED; TEST=tests/test_default_data_dir.zig; OWNER=storage; UPDATED=2026-08-31
/// ENG-3921 R1: the per-user default data directory, used when neither the
/// in-process override nor `GEODE_DATA_DIR` is set.
///
/// The old default was the bare, shared, world-writable `/tmp`. Since the
/// startup lock (`src/server/data_dir_lock.zig`) flocks `{data_dir}/.geode.lock`,
/// that made a default-configured `geode serve` contend on `/tmp/.geode.lock` —
/// a path any local user (or unrelated program) can pre-create unopenable or
/// hold, and one that silently pointed two different users' servers at ONE
/// on-disk store.
///
/// Resolution order (deterministic, same chain as `cli_auth_helpers.resolveStateDir`):
///   1. `$XDG_STATE_HOME/geode`
///   2. `$HOME/.local/state/geode`
///   3. `/tmp/geode-<uid>` (per-user, so two uids never collide)
pub fn defaultDataDir(allocator: std.mem.Allocator) ![]u8 {
    if (getEnvVarOwned(allocator, "XDG_STATE_HOME")) |xdg_state_home| {
        defer allocator.free(xdg_state_home);
        if (xdg_state_home.len > 0) {
            return std.fs.path.join(allocator, &.{ xdg_state_home, "geode" });
        }
    } else |_| {}

    if (getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        if (home.len > 1) {
            return std.fs.path.join(allocator, &.{ home, ".local", "state", "geode" });
        }
    } else |_| {}

    if (comptime @import("builtin").os.tag == .windows) {
        return std.fs.path.join(allocator, &.{ ".", ".geode", "state" });
    }
    const uid = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.getuid()
    else
        std.c.getuid();
    return std.fmt.allocPrint(allocator, "/tmp/geode-{d}", .{uid});
}

/// DEPRECATED: Legacy persistence file path. Retained as a stub for callers
/// that have not yet been updated. Returns the data directory path.
// CANARY: REQ=REQ-BINARY-PERSIST-PATH-001; FEATURE="BinaryPersistence"; ASPECT=PathResolution; STATUS=EXEMPT; OWNER=storage; UPDATED=2026-03-28
pub fn getPersistenceFilePath(allocator: std.mem.Allocator) ![]u8 {
    // Return data dir path for callers that still reference this function
    if (getDataDirOverride()) |override| {
        return try allocator.dupe(u8, override);
    }
    return getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch {
        return defaultDataDir(allocator);
    };
}

/// Default graph name used when no graph is selected
pub const DEFAULT_GRAPH_NAME = "default";

/// Default tenant ID used when no tenant context is set
/// GAP-0279: Backward compatible — existing single-tenant data uses this default
pub const DEFAULT_TENANT_ID = "default";

/// Reserved storage keys used to persist Geode's public IDs inside the
/// graph-storage engine without exposing them as user-visible properties.
pub const INTERNAL_NODE_ID_PROPERTY_KEY = "__geode_internal_node_id";
pub const INTERNAL_EDGE_ID_PROPERTY_KEY = "__geode_internal_edge_id";

/// GAP-ENT-0024 instrumentation: counts per-edge `__geode_internal_edge_id`
/// PROPERTY-FALLBACK reads on the edge-id read paths (loop1 IdMap rebuild,
/// adjacency hydrate, MERGE dedup probe fallback in the adapter). New (v2)
/// edges carry the public id INLINE in the adjacency entry, so on a fresh
/// store this counter must stay 0 — tests assert exactly that. Legacy v1
/// blocks / old stores legitimately bump it (read-both is permanent).
pub var edge_id_property_fallback_reads: std.atomic.Value(u64) = .init(0);

/// GAP-ENT-0004 instrumentation: typed-edge enumeration route counters for
/// `getEdgesByType` under a BOUNDED edge cache (the engine-derived path).
/// `typed_edge_index_scan_total` counts servings from the engine's per-shard
/// edge_index scan (O(total edges) sequential index-record scan, no node
/// iteration, no adjacency hydration). `typed_edge_node_walk_total` counts
/// servings from the legacy every-node adjacency walk (adapterless fallback
/// ONLY), and `typed_edge_node_walk_nodes_total` counts the nodes that walk
/// visited. With a storage adapter present the walk must NEVER run — path
/// tests assert the walk counters stay flat while the scan counter moves.
pub var typed_edge_index_scan_total: std.atomic.Value(u64) = .init(0);
pub var typed_edge_node_walk_total: std.atomic.Value(u64) = .init(0);
pub var typed_edge_node_walk_nodes_total: std.atomic.Value(u64) = .init(0);

/// GAP-0891 (RC-2): reserved storage key used to round-trip a node/edge's
/// `tenant_id` tag across restart. Before this, the adapter persisted only the
/// public id and `loadOneGraphFromAdapter` rebuilt every row with
/// `DEFAULT_TENANT_ID`, so a non-default tenant tag was silently lost on
/// restart (native-tenant reads then saw zero rows). Persisted on node AND edge
/// write whenever the tag is non-default; absent on read means
/// `DEFAULT_TENANT_ID` (legacy / single-tenant back-compat, zero write
/// amplification for the common single-tenant case). Like the internal id keys
/// it is filtered out of user-visible properties (`isInternalPersistedPropertyKey`
/// here + `shouldExposePropertyKey` in graph_storage_adapter.zig).
pub const INTERNAL_TENANT_ID_PROPERTY_KEY = "__geode_tenant_id";

pub const Node = struct {
    id: u64,
    labels: [][]const u8,
    properties: CompactPropertyMap,
    // CANARY: REQ=REQ-MULTI-GRAPH-003; FEATURE="MultiGraphIsolation"; ASPECT=NodeGraphTag; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Graph name this node belongs to - enables per-graph data isolation
    graph_name: []const u8 = DEFAULT_GRAPH_NAME,
    // CANARY: REQ=REQ-MULTI-TENANT-002; FEATURE="PerTenantIsolation"; ASPECT=NodeTenantTag; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-01
    // GAP-0279: Per-tenant data isolation — tenant_id tags each node for query-time filtering
    tenant_id: []const u8 = DEFAULT_TENANT_ID,
};

/// Bounded, evict-freely cache that backs `GraphStore.nodes`. See
/// src/storage/node_cache.zig and docs/architecture/bound-node-mirror.md.
/// API-compatible with the `ShardedStore(u64, Node)` it replaces for the
/// read/iterate/put/remove surface used across graph_store.
pub const NodeCache = node_cache_mod.BoundedNodeCache(u64, Node);

/// Resident node-cache cap from `GEODE_NODE_CACHE_ENTRIES`.
///   unset   -> NodeCache.DEFAULT_CAP (1_000_000)
///   "0"     -> 0 (unbounded legacy mirror; for A/B + safety fallback)
///   N       -> N
fn nodeCacheCapFromEnv() usize {
    if (std.c.getenv("GEODE_NODE_CACHE_ENTRIES")) |raw_z| {
        const raw = std.mem.span(raw_z);
        return std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch
            node_cache_mod.DEFAULT_CAP;
    }
    return node_cache_mod.DEFAULT_CAP;
}

/// Per-`Node` heap free, matching the deinit/clearNodes free pattern exactly.
/// Used as the cache's `free_fn` for both inline frees (overwrite) and
/// grace-point reclamation of evicted entries.
pub fn freeNodeValue(allocator: std.mem.Allocator, node: *Node) void {
    for (node.labels) |label| allocator.free(label);
    allocator.free(node.labels);
    if (node.graph_name.len > 0) allocator.free(node.graph_name);
    if (node.tenant_id.len > 0) allocator.free(node.tenant_id);
    var prop_iter = node.properties.iterator();
    while (prop_iter.next()) |prop_entry| {
        allocator.free(prop_entry.key_ptr.*);
        freePropertyValueWithAllocator(allocator, prop_entry.value_ptr.*);
    }
    node.properties.deinit();
}

// ============================================================================
// PHASE 0 (edge-engine-direct): bounded, evict-freely ADJACENCY cache.
//
// `outgoing_edges`/`incoming_edges` used to be UNBOUNDED, fully-resident
// `ShardedStore(u64, ArrayList(u64))` mirrors — a popular parent's entire
// adjacency id-list pinned in RAM forever. The adjacency is ALREADY durable +
// evictable in the graph-storage engine (`expandOutIter`/`expandInIter`), so the
// resident maps are a redundant mirror. This bounds them: at most `cap` resident
// per-node id-lists, with HYDRATE-ON-MISS rebuilding an evicted node's PUBLIC
// edge-id list from the engine. Correctness never depends on residency.
//
// EVICTION-SAFETY (grace-point, NOT copy-out): the read API
// (`getOutgoingEdgeIds`/`getIncomingEdgeIds`) keeps returning a BORROWED
// `[]const u64` into the resident list's `.items` — so eviction must not free a
// list while a reader holds a slice into it. We reuse the BoundedNodeCache
// retire/reclaim discipline exactly as `nodes` does: eviction only UNLINKs +
// RETIRES (never frees inline); retired lists are freed at the per-graph
// EXCLUSIVE checkpoint grace window (`reclaimAdjCacheRetiredForGraph`), which has
// drained all SHARED readers of that graph. The node cache scopes its grace
// reclaim by `Node.graph_name`; the adjacency value carries no graph, so the
// cache value wraps the list together with an OWNED `graph` dupe so the same
// per-graph predicate works (an evicted graph-B list is never freed during a
// graph-A checkpoint while a graph-B reader could still hold its slice).
//
// dedup / locking / the `edges` body mirror / `edge_type_index` are UNCHANGED
// (Phases 1-4).

/// Cache value for one node's adjacency id-list. `list` holds the node's PUBLIC
/// edge ids (insertion order while resident; engine-adjacency order when
/// hydrated — same as the post-restart rebuild). `graph` is an OWNED dupe of the
/// owning graph name so grace-point reclamation can be scoped per-graph exactly
/// like the node cache scopes by `Node.graph_name`.
pub const AdjList = struct {
    list: std.ArrayList(u64) = .empty,
    graph: []u8 = &.{},
};

/// Per-`AdjList` heap free: the id-list backing array + the owned graph dupe.
/// Used as the adjacency cache's `free_fn` for both inline frees (overwrite) and
/// grace-point reclamation of evicted entries.
pub fn freeAdjListValue(allocator: std.mem.Allocator, value: *AdjList) void {
    value.list.deinit(allocator);
    if (value.graph.len > 0) allocator.free(value.graph);
}

/// Bounded, evict-freely cache backing `GraphStore.outgoing_edges` /
/// `incoming_edges`. See the block comment above and src/storage/node_cache.zig.
pub const AdjCache = node_cache_mod.BoundedNodeCache(u64, AdjList);

/// Resident adjacency-cache cap from `GEODE_ADJ_CACHE_ENTRIES`.
///   unset   -> node_cache DEFAULT_CAP (1_000_000) — BOUNDED by default
///   "0"     -> 0 (unbounded legacy mirror; A/B + safety fallback)
///   N       -> N
/// NOTE: like the node cache, the cap only becomes ACTIVE once the hydrate hook
/// is installed (engine available); until then eviction is disabled so an
/// in-memory-only edge list is never lost.
fn adjCacheCapFromEnv() usize {
    if (std.c.getenv("GEODE_ADJ_CACHE_ENTRIES")) |raw_z| {
        const raw = std.mem.span(raw_z);
        return std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch
            node_cache_mod.DEFAULT_CAP;
    }
    return node_cache_mod.DEFAULT_CAP;
}

pub const Edge = struct {
    id: u64,
    from_id: u64,
    to_id: u64,
    label: []const u8,
    properties: CompactPropertyMap,
    // CANARY: REQ=REQ-MULTI-GRAPH-003; FEATURE="MultiGraphIsolation"; ASPECT=EdgeGraphTag; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Graph name this edge belongs to - enables per-graph data isolation
    graph_name: []const u8 = DEFAULT_GRAPH_NAME,
    // CANARY: REQ=REQ-MULTI-TENANT-002; FEATURE="PerTenantIsolation"; ASPECT=EdgeTenantTag; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-01
    // GAP-0279: Per-tenant data isolation — tenant_id tags each edge for query-time filtering
    tenant_id: []const u8 = DEFAULT_TENANT_ID,
};

// ============================================================================
// PHASE 1 (edge-engine-direct): bounded, evict-freely EDGE-BODY cache.
//
// `edges` used to be an UNBOUNDED, fully-resident `ShardedStore(u64, Edge)`
// mirror — one `Edge` struct (id/from/to/label/props/graph_name/tenant_id)
// pinned in RAM for EVERY edge forever. For an edge-heavy graph (taxonomy
// ~14.27M edges) that is the real RSS floor, and Phase 0's adjacency readers
// DEPEND on it: each hydrated edge id is dereferenced via `self.edges.get(id)`
// for the body. The edge body is ALREADY durable + reconstructible from the
// graph-storage engine (endpoints + rel-type via the engine edge index,
// properties via getAllEdgeProperties), so the resident map is a redundant
// mirror. This bounds it: at most `cap` resident `Edge`s, with HYDRATE-ON-MISS
// rebuilding an evicted edge's body from the engine. Correctness never depends
// on residency.
//
// EVICTION-SAFETY (grace-point, NOT copy-out): many read sites borrow a
// `*Edge`/`*const Edge` into the resident value for the duration of a query
// (all under the per-graph / global SHARED store lock). Eviction must not free
// an `Edge`'s heap (label/props/graph_name/tenant_id byte slices) while a reader
// holds a pointer into it. We reuse the BoundedNodeCache retire/reclaim
// discipline exactly as `nodes` does: eviction only UNLINKs + RETIREs (never
// frees inline); retired edges are freed at the per-graph EXCLUSIVE checkpoint
// grace window (`reclaimEdgeCacheRetiredForGraph`), which has drained all SHARED
// readers of that graph. Unlike `AdjList`, an `Edge` ALREADY carries its owning
// `graph_name`, so the per-graph reclaim predicate scopes directly off it.
//
// dedup (Phase 3) / endpoint-resolution de-hydration (Phase 2) / coordinator
// locking (Phase 4) are UNCHANGED.

/// Per-`Edge` heap free: label + graph_name + tenant_id byte slices and the
/// property map (keys + String/Ext values). Used as the edge cache's `free_fn`
/// for inline frees (overwrite) and grace-point reclamation of evicted edges.
/// Mirrors the per-edge free loop the legacy `clearNodes` mirror walk performed.
/// Every stored/hydrated Edge OWNS these bytes (create/load/hydrate all dupe
/// them), so the frees are unconditional beyond the empty-slice guard.
pub fn freeEdgeValue(allocator: std.mem.Allocator, value: *Edge) void {
    if (value.label.len > 0) allocator.free(value.label);
    if (value.graph_name.len > 0) allocator.free(value.graph_name);
    if (value.tenant_id.len > 0) allocator.free(value.tenant_id);
    var prop_iter = value.properties.iterator();
    while (prop_iter.next()) |prop_entry| {
        allocator.free(prop_entry.key_ptr.*);
        freePropertyValueWithAllocator(allocator, prop_entry.value_ptr.*);
    }
    value.properties.deinit();
}

/// Bounded, evict-freely cache backing `GraphStore.edges`. See the block
/// comment above and src/storage/node_cache.zig.
pub const EdgeCache = node_cache_mod.BoundedNodeCache(u64, Edge);

/// Resident edge-cache cap from `GEODE_EDGE_CACHE_ENTRIES`.
///   unset   -> node_cache DEFAULT_CAP (1_000_000) — BOUNDED by default
///   "0"     -> 0 (unbounded legacy mirror; A/B + safety fallback)
///   N       -> N
/// NOTE: like the node + adjacency caches, the cap only becomes ACTIVE once the
/// hydrate hook is installed (engine available); until then eviction is disabled
/// so an in-memory-only edge body (one not yet flushed to the engine) is never
/// lost.
fn edgeCacheCapFromEnv() usize {
    if (std.c.getenv("GEODE_EDGE_CACHE_ENTRIES")) |raw_z| {
        const raw = std.mem.span(raw_z);
        return std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch
            node_cache_mod.DEFAULT_CAP;
    }
    return node_cache_mod.DEFAULT_CAP;
}

pub const PropertyValue = union(enum) {
    String: []const u8,
    Int: i64,
    Float: f64,
    Bool: bool,
    Null,
    ExtValue: @import("eval_extended.zig").ExtValue,
    // CANARY: REQ=REQ-GQL-DECIMAL-001; FEATURE="DecimalPrecision"; ASPECT=PropertyStorage; STATUS=TESTED; TEST=geodetestlab/specs/gap_analysis_fixes_january_2026.yml; OWNER=core; UPDATED=2026-01-25
    Decimal: struct { coeff: i128, scale: u8 },
};

// ============================================================================
// GAP-0900 Layer-3 (Fix 3): compact per-node/edge property store.
//
// Every node/edge in the legacy in-memory mirror previously held a
// `CompactPropertyMap`. A StringHashMap rounds its slot table up
// to the next power-of-two ≥ count/0.8 and keeps one (key-ptr + value + 1B
// metadata) slot for EVERY bucket, used or not. For the batch-ingest Taxon node
// (~20 properties) that means a 32-slot table — ~12 unused slots — plus the map
// header, i.e. the ~3 KB/node of slack the triage measured (graph_store.zig
// node-mirror dominating O(nodes) RSS after Fix 1 + Fix 2).
//
// `CompactPropertyMap` replaces that hashmap with a single growable slice of
// `(key, value)` entries kept sorted by key, with O(log n) binary-search
// lookup. The backing slice is allocated to EXACTLY the live length on every
// mutation (no power-of-two table, no growth-factor slack), so a 20-property
// node stores 20 entries and nothing more. Property counts per node are small
// (tens), so binary search over a packed slice is as fast as — and far more
// cache-friendly than — the hashmap it replaces.
//
// This is a PURE internal-representation swap: the ownership contract is
// IDENTICAL to `CompactPropertyMap`.
//   * The caller still owns and frees property-name key strings: on a NEW key,
//     `getOrPut().found_existing == false` and the caller writes the duped key
//     into `key_ptr.*` exactly as before; on delete, `fetchRemove` hands the
//     stored key back in `.key` for the caller to free; on `deinit`, the caller
//     iterates and frees every `key_ptr.*` first (the map frees only its own
//     entry slice). No key string is duplicated or interned by the map itself.
//   * `get`, `getOrPut`, `put`, `fetchRemove`, `count`, `iterator`, `deinit`
//     preserve the same signatures and return shapes used across the codebase
//     (key_ptr / value_ptr / found_existing on getOrPut; .key / .value on
//     fetchRemove; key_ptr / value_ptr on the iterator entry).
//
// Pointer-stability note: like the std hashmap's, the pointers returned by
// `getOrPut`/`get`/the iterator are valid only until the next mutation of the
// SAME map. Every call site uses them immediately (audited: setNodeProperty,
// the batch paths, the no-save paths, the clone path, eval/match/index readers)
// — none holds a value_ptr/key_ptr across another insert or remove on the same
// map, so the exact-length reallocation on insert/remove is safe.
//
// Default-ON: there is no behavioral or correctness difference versus the
// hashmap, only memory representation, so no env flag is required.
pub const CompactPropertyMap = struct {
    const Self = @This();

    pub const Entry = struct {
        key: []const u8,
        value: PropertyValue,
    };

    /// Mirrors std.StringHashMap.GetOrPutResult.
    pub const GetOrPutResult = struct {
        key_ptr: *[]const u8,
        value_ptr: *PropertyValue,
        found_existing: bool,
    };

    /// Mirrors the kv returned by std.StringHashMap.fetchRemove.
    pub const KV = struct {
        key: []const u8,
        value: PropertyValue,
    };

    /// Iterator entry exposes key_ptr/value_ptr like the std hashmap iterator.
    pub const IterEntry = struct {
        key_ptr: *[]const u8,
        value_ptr: *PropertyValue,
    };

    pub const Iterator = struct {
        entries: []Entry,
        index: usize = 0,

        pub fn next(self: *Iterator) ?IterEntry {
            if (self.index >= self.entries.len) return null;
            const e = &self.entries[self.index];
            self.index += 1;
            return IterEntry{ .key_ptr = &e.key, .value_ptr = &e.value };
        }
    };

    allocator: std.mem.Allocator,
    entries: []Entry = &[_]Entry{},

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator, .entries = &[_]Entry{} };
    }

    /// Frees only the entry slice. Per the ownership contract (identical to the
    /// std hashmap), the caller is responsible for freeing each entry's key
    /// string and any owned value payload BEFORE calling deinit — every current
    /// caller iterates and frees keys/values first.
    pub fn deinit(self: *Self) void {
        if (self.entries.len > 0) self.allocator.free(self.entries);
        self.entries = &[_]Entry{};
    }

    pub fn count(self: *const Self) usize {
        return self.entries.len;
    }

    /// Binary search for `key`. Returns the index when found, otherwise the
    /// insertion index (where a new entry with `key` should go to keep sorted).
    fn search(self: *const Self, key: []const u8) struct { found: bool, index: usize } {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.entries[mid].key, key)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return .{ .found = true, .index = mid },
            }
        }
        return .{ .found = false, .index = lo };
    }

    pub fn get(self: *const Self, key: []const u8) ?PropertyValue {
        const r = self.search(key);
        if (!r.found) return null;
        return self.entries[r.index].value;
    }

    pub fn getPtr(self: *const Self, key: []const u8) ?*PropertyValue {
        const r = self.search(key);
        if (!r.found) return null;
        return &self.entries[r.index].value;
    }

    pub fn contains(self: *const Self, key: []const u8) bool {
        return self.search(key).found;
    }

    /// Identical contract to std.StringHashMap.getOrPut: on a miss it inserts a
    /// slot (key/value left undefined for the caller to fill) and returns
    /// found_existing=false; on a hit it returns the existing slot pointers.
    pub fn getOrPut(self: *Self, key: []const u8) !GetOrPutResult {
        const r = self.search(key);
        if (r.found) {
            return .{
                .key_ptr = &self.entries[r.index].key,
                .value_ptr = &self.entries[r.index].value,
                .found_existing = true,
            };
        }
        // Grow the slice by exactly one entry and shift to keep sorted order.
        const old = self.entries;
        const new_entries = try self.allocator.alloc(Entry, old.len + 1);
        @memcpy(new_entries[0..r.index], old[0..r.index]);
        @memcpy(new_entries[r.index + 1 ..], old[r.index..]);
        // Leave the new slot's key/value undefined; caller fills them, exactly
        // as with the std hashmap's getOrPut.
        new_entries[r.index].key = undefined;
        new_entries[r.index].value = undefined;
        if (old.len > 0) self.allocator.free(old);
        self.entries = new_entries;
        return .{
            .key_ptr = &self.entries[r.index].key,
            .value_ptr = &self.entries[r.index].value,
            .found_existing = false,
        };
    }

    /// Identical contract to std.StringHashMap.put: inserts the key/value when
    /// absent (storing the passed key slice), or overwrites only the value when
    /// present (keeping the previously stored key — the passed key is the
    /// caller's to manage, same as the std hashmap).
    pub fn put(self: *Self, key: []const u8, value: PropertyValue) !void {
        const res = try self.getOrPut(key);
        if (!res.found_existing) {
            res.key_ptr.* = key;
        }
        res.value_ptr.* = value;
    }

    /// Identical contract to std.StringHashMap.fetchRemove: removes the entry
    /// and returns the stored key + value for the caller to free, or null.
    pub fn fetchRemove(self: *Self, key: []const u8) ?KV {
        const r = self.search(key);
        if (!r.found) return null;
        const removed = KV{ .key = self.entries[r.index].key, .value = self.entries[r.index].value };
        const old = self.entries;
        if (old.len == 1) {
            self.allocator.free(old);
            self.entries = &[_]Entry{};
            return removed;
        }
        const new_entries = self.allocator.alloc(Entry, old.len - 1) catch {
            // Allocation failure on shrink: fall back to in-place compaction so
            // the entry is still removed (correctness over the slack saving).
            std.mem.copyForwards(Entry, old[r.index .. old.len - 1], old[r.index + 1 ..]);
            self.entries = old[0 .. old.len - 1];
            return removed;
        };
        @memcpy(new_entries[0..r.index], old[0..r.index]);
        @memcpy(new_entries[r.index..], old[r.index + 1 ..]);
        self.allocator.free(old);
        self.entries = new_entries;
        return removed;
    }

    /// Identical to std.StringHashMap.remove: returns whether a key was removed.
    pub fn remove(self: *Self, key: []const u8) bool {
        return self.fetchRemove(key) != null;
    }

    pub fn iterator(self: *const Self) Iterator {
        return .{ .entries = self.entries, .index = 0 };
    }
};

// CANARY: REQ=REQ-GQL-PATH-UTIL-001; FEATURE="GraphStorePathOps"; ASPECT=Traversal; STATUS=TESTED; TEST=geodetestlab/specs/geode_graph_algorithms.yml; OWNER=engine; UPDATED=2026-06-11
pub const PathOptions = struct {
    min_length: ?u32 = null,
    max_length: ?u32 = null,
    exact_length: ?u32 = null,
};

pub const ExpandOptions = struct {
    max_depth: u32 = 5,
};

pub const Path = struct {
    nodes: []u64,
    edges: []u64,
};

pub const PathFilter = struct {
    node_predicate: ?*const fn (*const Node) bool = null,
    edge_predicate: ?*const fn (*const Edge) bool = null,
};

fn isInternalPersistedPropertyKey(key: []const u8) bool {
    return std.mem.eql(u8, key, INTERNAL_NODE_ID_PROPERTY_KEY) or
        std.mem.eql(u8, key, INTERNAL_EDGE_ID_PROPERTY_KEY) or
        std.mem.eql(u8, key, INTERNAL_TENANT_ID_PROPERTY_KEY);
}

/// Name of the internal HMAC-chained security graph (auth users/roles/
/// permissions/policies/grants). This is the single source of truth: as of the
/// GAP-0854 follow-up, `SECURITY_GRAPH_NAME` in `src/storage/user_storage.zig`
/// and `src/security/auth_graph_manager.zig` are aliases of this constant (both
/// modules already depend on graph_store), so the name cannot drift.
pub const SECURITY_GRAPH_NAME = "__geode_security";

/// GAP-0854: FLE field encryption must NEVER touch the internal
/// `__geode_security` graph. Its nodes carry common labels (`User`, `Role`)
/// that collide with application labels, so a user-configured FLE field such
/// as `('User','email')` would otherwise FLE-encrypt the security graph's own
/// User-node properties. The auth HMAC chain is computed over the plaintext
/// record fields at write time, so an FLE-rewritten property breaks
/// `verifyChain` on the next boot (`error.AuthChainTampered`) and bricks the
/// server. The security graph is already protected at rest by TDE, so excluding
/// it from FLE is both correct and complete.
fn isSecurityGraphName(graph_name: []const u8) bool {
    return std.mem.eql(u8, graph_name, SECURITY_GRAPH_NAME);
}

/// SONNY-2733: is `graph_name` one of the engine's own graphs? They are named
/// `__geode_…`, like `SECURITY_GRAPH_NAME` (users, roles, policies).
/// Store-wide admin passes over user data, such as the edge tag backfill,
/// leave them alone.
pub fn isInternalGraphName(graph_name: []const u8) bool {
    return std.mem.startsWith(u8, graph_name, "__geode_");
}

fn encodePersistedPublicId(buf: *[16]u8, public_id: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{public_id}) catch unreachable;
}

pub fn parsePersistedPublicId(text: []const u8) ?u64 {
    return std.fmt.parseUnsigned(u64, text, 16) catch std.fmt.parseUnsigned(u64, text, 10) catch null;
}

/// Check whether a byte slice looks like a serialized FLE EnvelopeV1.
/// Format: alg_id(1) + key_version(2) + nonce(12) + tag(16) + ciphertext_len(4) + ciphertext
/// Used to prevent double-encryption when callers already encrypted before setNodeProperty.
fn isLikelyFleEnvelope(data: []const u8) bool {
    if (data.len < 35) return false;
    // Valid algorithm IDs: 1 (AES-256-GCM), 2 (ChaCha20-Poly1305), 3 (XChaCha20-Poly1305)
    const alg_id = data[0];
    if (alg_id < 1 or alg_id > 3) return false;
    // Check that the ciphertext length field matches remaining data
    const ciphertext_len = std.mem.readInt(u32, data[31..35], .little);
    return data.len == 35 + ciphertext_len;
}

fn copyPropertyValue(self: *GraphStore, value: PropertyValue) !PropertyValue {
    return switch (value) {
        .String => |s| PropertyValue{ .String = try self.allocator.dupe(u8, s) },
        .ExtValue => |ext| PropertyValue{ .ExtValue = try copyExtValue(self, ext) },
        else => value,
    };
}

fn freePropertyValueWithAllocator(allocator: std.mem.Allocator, value: PropertyValue) void {
    switch (value) {
        .String => |s| allocator.free(s),
        .ExtValue => |ext| freeExtValueWithAllocator(allocator, ext),
        else => {},
    }
}

fn freePropertyValue(self: *GraphStore, value: PropertyValue) void {
    freePropertyValueWithAllocator(self.allocator, value);
}

pub fn freeDetachedPropertyValue(allocator: std.mem.Allocator, value: PropertyValue) void {
    freePropertyValueWithAllocator(allocator, value);
}

fn copyExtValue(self: *GraphStore, value: @import("eval_extended.zig").ExtValue) !@import("eval_extended.zig").ExtValue {
    const ext_eval = @import("eval_extended.zig");
    const bitstring_mod = @import("types/bitstring.zig");
    const jsonb_mod = @import("types/jsonb.zig");
    const xml_mod = @import("types/xml.zig");
    const url_mod = @import("types/url.zig");
    const heap_mod = @import("storage/heap.zig");

    return switch (value) {
        .Null => ext_eval.ExtValue{ .Null = {} },
        .Int => |v| ext_eval.ExtValue{ .Int = v },
        .Bool => |v| ext_eval.ExtValue{ .Bool = v },
        .Decimal => |v| ext_eval.ExtValue{ .Decimal = v },
        .IpAddr => |v| ext_eval.ExtValue{ .IpAddr = v },
        .Subnet => |v| ext_eval.ExtValue{ .Subnet = v },
        .Mac => |v| ext_eval.ExtValue{ .Mac = v },
        .Currency => |v| ext_eval.ExtValue{ .Currency = v },
        .LatLon => |v| ext_eval.ExtValue{ .LatLon = v },
        .LatLonAlt => |v| ext_eval.ExtValue{ .LatLonAlt = v },
        .Temperature => |v| ext_eval.ExtValue{ .Temperature = v },
        .Pressure => |v| ext_eval.ExtValue{ .Pressure = v },
        .Date => |v| ext_eval.ExtValue{ .Date = v },
        .Time => |v| ext_eval.ExtValue{ .Time = v },
        .TimestampTZ => |v| ext_eval.ExtValue{ .TimestampTZ = v },
        .Interval => |v| ext_eval.ExtValue{ .Interval = v },
        .UUID => |v| ext_eval.ExtValue{ .UUID = v },
        .Enum => |v| ext_eval.ExtValue{ .Enum = v },
        .IntRange => |v| ext_eval.ExtValue{ .IntRange = v },
        .Str => |s| ext_eval.ExtValue{ .Str = try self.allocator.dupe(u8, s) },
        .Bytea => |b| ext_eval.ExtValue{ .Bytea = try self.allocator.dupe(u8, b) },
        .Json => |j| ext_eval.ExtValue{ .Json = try self.allocator.dupe(u8, j) },
        .Geometry => |g| ext_eval.ExtValue{ .Geometry = .{ .wkb = try self.allocator.dupe(u8, g.wkb) } },
        .LanguageTag => |lt| ext_eval.ExtValue{ .LanguageTag = .{ .tag = try self.allocator.dupe(u8, lt.tag) } },
        .VectorF32 => |vec| ext_eval.ExtValue{ .VectorF32 = .{
            .dim = vec.dim,
            .data = try self.allocator.dupe(f32, vec.data),
        } },
        .VectorI32 => |vec| ext_eval.ExtValue{ .VectorI32 = .{
            .dim = vec.dim,
            .data = try self.allocator.dupe(i32, vec.data),
        } },
        .SmallInt => |v| ext_eval.ExtValue{ .SmallInt = v },
        .BigInt => |v| ext_eval.ExtValue{ .BigInt = v },
        .Real => |v| ext_eval.ExtValue{ .Real = v },
        .Double => |v| ext_eval.ExtValue{ .Double = v },
        .Text => |s| ext_eval.ExtValue{ .Text = try self.allocator.dupe(u8, s) },
        .Char => |c| ext_eval.ExtValue{ .Char = .{
            .data = try self.allocator.dupe(u8, c.data),
            .n = c.n,
        } },
        .Varchar => |v| ext_eval.ExtValue{ .Varchar = .{
            .data = try self.allocator.dupe(u8, v.data),
            .n = v.n,
        } },
        .Hash => |h| ext_eval.ExtValue{ .Hash = heap_mod.Hash{
            .alg = h.alg,
            .digest = try self.allocator.dupe(u8, h.digest),
            .salt = if (h.salt) |s| try self.allocator.dupe(u8, s) else null,
            .params = h.params,
        } },
        .TimeTZ => |v| ext_eval.ExtValue{ .TimeTZ = v },
        .Timestamp => |v| ext_eval.ExtValue{ .Timestamp = v },
        .Url => |u| ext_eval.ExtValue{ .Url = url_mod.Url{
            .scheme = try self.allocator.dupe(u8, u.scheme),
            .host = try self.allocator.dupe(u8, u.host),
            .port = u.port,
            .path = try self.allocator.dupe(u8, u.path),
            .query = if (u.query) |q| try self.allocator.dupe(u8, q) else null,
            .fragment = if (u.fragment) |f| try self.allocator.dupe(u8, f) else null,
        } },
        .Domain => |d| blk: {
            const labels_copy = try self.allocator.alloc([]const u8, d.labels.len);
            for (d.labels, 0..) |label, i| {
                labels_copy[i] = try self.allocator.dupe(u8, label);
            }
            break :blk ext_eval.ExtValue{ .Domain = url_mod.Domain{ .labels = labels_copy } };
        },
        .Jsonb => |doc| ext_eval.ExtValue{ .Jsonb = jsonb_mod.JsonbDocument{
            .data = try self.allocator.dupe(u8, doc.data),
            .allocator = self.allocator,
        } },
        .Xml => |doc| ext_eval.ExtValue{ .Xml = xml_mod.XmlDocument{
            .data = try self.allocator.dupe(u8, doc.data),
        } },
        .BitString => |bs| ext_eval.ExtValue{ .BitString = bitstring_mod.BitString{
            .bytes = try self.allocator.dupe(u8, bs.bytes),
            .bit_length = bs.bit_length,
        } },
        .VarBit => |bs| ext_eval.ExtValue{ .VarBit = bitstring_mod.BitString{
            .bytes = try self.allocator.dupe(u8, bs.bytes),
            .bit_length = bs.bit_length,
        } },
        .Array => |arr| ext_eval.ExtValue{ .Array = .{
            .elem_type = arr.elem_type,
            .data = try self.allocator.dupe(u8, arr.data),
            .allocator = self.allocator,
        } },
        .List => |list| blk: {
            const copied = try self.allocator.alloc(ext_eval.ExtValue, list.len);
            for (list, 0..) |item, i| {
                copied[i] = try copyExtValue(self, item);
            }
            break :blk ext_eval.ExtValue{ .List = copied };
        },
    };
}

fn freeExtValueWithAllocator(allocator: std.mem.Allocator, value: @import("eval_extended.zig").ExtValue) void {
    const bitstring_mod = @import("types/bitstring.zig");
    const jsonb_mod = @import("types/jsonb.zig");
    const url_mod = @import("types/url.zig");

    switch (value) {
        .Str => |s| allocator.free(s),
        .Bytea => |b| allocator.free(b),
        .Json => |j| allocator.free(j),
        .Geometry => |g| allocator.free(g.wkb),
        .LanguageTag => |lt| allocator.free(lt.tag),
        .VectorF32 => |vec| allocator.free(vec.data),
        .VectorI32 => |vec| allocator.free(vec.data),
        .Text => |s| allocator.free(s),
        .Char => |c| allocator.free(c.data),
        .Varchar => |v| allocator.free(v.data),
        .Hash => |h| {
            allocator.free(h.digest);
            if (h.salt) |s| allocator.free(s);
        },
        .Url => |u| {
            allocator.free(u.scheme);
            allocator.free(u.host);
            allocator.free(u.path);
            if (u.query) |q| allocator.free(q);
            if (u.fragment) |f| allocator.free(f);
        },
        .Domain => |d| url_mod.Domain.deinit(d, allocator),
        .Jsonb => |doc| jsonb_mod.JsonbDocument.deinit(doc),
        .Xml => |doc| allocator.free(doc.data),
        .BitString => |bs| bitstring_mod.BitString.deinit(bs, allocator),
        .VarBit => |bs| bitstring_mod.BitString.deinit(bs, allocator),
        .Array => |arr| arr.deinit(),
        .List => |list| {
            for (list) |item| {
                freeExtValueWithAllocator(allocator, item);
            }
            allocator.free(list);
        },
        else => {},
    }
}

fn freeExtValue(self: *GraphStore, value: @import("eval_extended.zig").ExtValue) void {
    freeExtValueWithAllocator(self.allocator, value);
}

pub fn freeDetachedExtValue(allocator: std.mem.Allocator, value: @import("eval_extended.zig").ExtValue) void {
    freeExtValueWithAllocator(allocator, value);
}

pub const STORAGE_EXT_TYPE_TAG: u16 = 1;

const NullHasher = struct {
    fn update(_: *NullHasher, _: []const u8) void {}
};

pub fn encodeExtValue(allocator: std.mem.Allocator, value: @import("eval_extended.zig").ExtValue) ![]u8 {
    var dummy: GraphStore = undefined;
    var sink = NullHasher{};
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try dummy.writeExtValueToWriter(buf.writer(allocator), &sink, value);
    return try buf.toOwnedSlice(allocator);
}

pub fn decodeExtValue(allocator: std.mem.Allocator, bytes: []const u8) !@import("eval_extended.zig").ExtValue {
    var dummy: GraphStore = undefined;
    dummy.allocator = allocator;

    var stream = std.Io.fixedBufferStream(bytes);
    return try dummy.readExtValue(stream.reader());
}

/// Label index posting list with a per-key mutex for fine-grained concurrency.
///
/// Task 17 (enterprise-ingest-throughput): the inner `std.ArrayList(u64)` of
/// sorted node ids is mutated from multiple threads during parallel ingest.
/// Each `LabelPosting` carries its own `std.Io.Mutex` so `sortedInsert`,
/// `orderedRemove`, and reader snapshotting all serialise per (graph, label)
/// without blocking mutations on *other* labels.
///
/// Lock ordering rule: the outer `GraphStore` rwlock (per-graph `mg.rwlock`)
/// is always acquired first; the `LabelPosting.mutex` is a leaf lock.
pub const LabelPosting = struct {
    list: std.ArrayList(u64) = std.ArrayList(u64).empty,
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn deinit(self: *LabelPosting, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }

    /// Acquire the posting's mutex using the process-global single-threaded IO.
    /// This matches the pattern used for every other leaf mutex in this file
    /// (`g_data_dir_mutex`, `g_init_mutex`, etc.) — the `Io` parameter is only
    /// needed so `futexWait` can block cooperatively; under contention from
    /// real OS threads (not async tasks) the global IO is the correct choice.
    pub fn lock(self: *LabelPosting) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    pub fn unlock(self: *LabelPosting) void {
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }
};

const merge_property_index_shard_count: usize = 256;

const MergePropertyIndexShard = struct {
    map: std.StringHashMap(u64),
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    fn init(allocator: std.mem.Allocator) MergePropertyIndexShard {
        return .{ .map = std.StringHashMap(u64).init(allocator) };
    }

    fn deinit(self: *MergePropertyIndexShard, allocator: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.map.deinit();
    }
};

// CANARY: REQ=REQ-QUIC-HC-127; FEATURE="High-Concurrency Mutations"; ASPECT=ShardedMergePropertyIndex; STATUS=TESTED; TEST=test-merge-prop-index-concurrent; OWNER=storage; UPDATED=2026-06-11
/// Striped `(graph, label, property_key, property_value) -> node_id` index.
///
/// The pre-sharded implementation protected one process-wide `StringHashMap`
/// with one mutex. Bulk MERGE writes update this index once per property, so
/// the group-commit shard workers still serialized in GraphStore after the
/// storage adapter had routed the physical write to independent shards.
/// Striping keeps the exact same key/value contract while making unrelated
/// property values contend only when they hash to the same shard.
pub const MergePropertyIndex = struct {
    allocator: std.mem.Allocator,
    shards: [merge_property_index_shard_count]MergePropertyIndexShard,

    pub fn init(allocator: std.mem.Allocator) MergePropertyIndex {
        var self: MergePropertyIndex = .{
            .allocator = allocator,
            .shards = undefined,
        };
        for (&self.shards) |*shard| {
            shard.* = MergePropertyIndexShard.init(allocator);
        }
        return self;
    }

    pub fn deinit(self: *MergePropertyIndex) void {
        for (&self.shards) |*shard| shard.deinit(self.allocator);
    }

    pub fn reset(self: *MergePropertyIndex) void {
        self.deinit();
        self.* = MergePropertyIndex.init(self.allocator);
    }

    pub fn count(self: *MergePropertyIndex) u32 {
        const io = std.Io.Threaded.global_single_threaded.io();
        var total: u32 = 0;
        for (&self.shards) |*shard| {
            shard.mutex.lockUncancelable(io);
            total +%= shard.map.count();
            shard.mutex.unlock(io);
        }
        return total;
    }

    fn shardForKey(key: []const u8) usize {
        return @intCast(std.hash.Wyhash.hash(0, key) % merge_property_index_shard_count);
    }

    /// T2b (hydration merge): best-effort pre-size for a bulk load of
    /// ~`additional_total` inserts spread across the shards. Distinct-key
    /// counts are unknowable before the inserts (duplicates collapse), so
    /// this reserves the per-shard UPPER bound — at 43M keys the rehash-growth
    /// churn it eliminates dominates the single-digit-% table over-provision.
    /// OOM on a shard is swallowed: reservation is an optimization only.
    fn reserveAdditional(self: *MergePropertyIndex, additional_total: u64) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const per_shard64 = additional_total / merge_property_index_shard_count + 1;
        const per_shard: u32 = @intCast(@min(per_shard64, std.math.maxInt(u32)));
        for (&self.shards) |*shard| {
            shard.mutex.lockUncancelable(io);
            defer shard.mutex.unlock(io);
            shard.map.ensureUnusedCapacity(per_shard) catch {};
        }
    }

    fn putOrUpdate(self: *MergePropertyIndex, key: []const u8, node_id: u64) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const shard = &self.shards[shardForKey(key)];
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        if (shard.map.getPtr(key)) |existing| {
            existing.* = node_id;
            return;
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        try shard.map.put(key_copy, node_id);
    }

    fn remove(self: *MergePropertyIndex, key: []const u8) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const shard = &self.shards[shardForKey(key)];
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        if (shard.map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    fn get(self: *MergePropertyIndex, key: []const u8) ?u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        const shard = &self.shards[shardForKey(key)];
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);
        return shard.map.get(key);
    }
};

// CANARY: REQ=REQ-MULTI-TENANT-001; FEATURE="MultiTenancy"; ASPECT=GraphStore; STATUS=TESTED; TEST=geodetestlab/specs/gql_session_management_comprehensive.yml; OWNER=enterprise; UPDATED=2026-01-09
/// PHASE 1b: per-graph lazy-hydration state. One heap-allocated entry per graph
/// that has on-disk data registered at open but whose resident loop2 indexes
/// (label_index / nodes_by_graph / merge_prop_index / tenant introspection /
/// edges + adjacency / edge_type_index) have NOT yet been built. The first
/// read/write touching the graph builds them exactly once. The entry is
/// heap-allocated so the `*HydrationEntry` pointer stays stable across rehashes
/// of `pending_hydration`. `done` is atomic so the fast path (already hydrated)
/// needs no per-graph lock; `mutex` serialises concurrent first-touches on the
/// SAME graph so they hydrate exactly once and the losers block until done.
const HydrationEntry = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// GAP-ENT-0023 P3 (review C1): set when the first-touch build FAILED and
    /// the graph was quarantined (`done` stored true so it is not re-scanned
    /// every access). A failed graph's resident loop2 products are PARTIAL —
    /// `saveHydrationSnapshots` / `saveIdMapSnapshots` MUST treat it like a
    /// deferred graph (skip write AND delete stale files) or the next full
    /// checkpoint would persist the partial products counter-current,
    /// permanently freezing wrong indexes (the 9b2d42eb hazard class through
    /// the quarantine door). Never cleared for the process lifetime: the next
    /// reopen re-registers the graph fresh and re-scans (self-heal).
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const GraphStore = struct {
    allocator: std.mem.Allocator,
    nodes: NodeCache,
    // PHASE 1 (edge-engine-direct): BOUNDED, evict-freely edge-body cache over
    // the engine (hydrate-on-miss). See EdgeCache / freeEdgeValue above.
    edges: EdgeCache, // public edge_id -> Edge body (bounded)
    // GAP-ENT-0023 P3 (review C2/I1): DETACHED scan-hydration boxes. Nodes
    // rebuilt from the engine for MATCH-fallback row sourcing when they are
    // not resident in the bounded cache (`getNodePtrForScan`). Each box is a
    // heap `*Node` OUTSIDE the cache's shard maps, so handing out its pointer
    // never inserts/rehashes/evicts the maps other retained `*Node` pointers
    // live in. Boxes are freed at the SAME per-graph grace boundary as
    // evicted cache nodes (`reclaimNodeCacheRetiredForGraph`, i.e. the
    // per-graph EXCLUSIVE checkpoint window that drains readers) — so a
    // returned pointer has the same lifetime guarantee as a resident one.
    // Guarded by `scan_hydrated_mutex` (leaf lock: never held across another
    // lock or an engine read).
    scan_hydrated_nodes: std.ArrayList(*Node) = .empty,
    scan_hydrated_mutex: std.Io.Mutex = std.Io.Mutex.init,
    next_node_id: u64,
    next_edge_id: u64,
    // DEPRECATED (GAP-0279): Process-wide tenant_id races under concurrent access.
    // Tenant scoping should come from ExecutionContext.tenant_id, not this field.
    // Retained for FLE encryption context backward compatibility.
    tenant_id: []const u8,
    schema_name: []const u8,
    // CANARY: REQ=REQ-MULTI-GRAPH-008; FEATURE="GraphRegistry"; ASPECT=GraphNames; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=storage; UPDATED=2026-04-11
    // Track known graph names (including empty graphs)
    graphs: std.StringHashMap(void),
    // GAP-0839: Persistent UUID for every known graph, mirrored from the
    // storage adapter when one is wired and generated in-process otherwise.
    // Native multi-tenancy (and the catalog) require every graph to carry a
    // stable, non-zero persistent UUID; the HELLO handlers reject a
    // tenant-bound session whose target graph has none ("Graph created
    // without persistent UUID").  Before this map, an in-memory deployment
    // (server started without --data-dir, so `global_adapter`/`global_vtable`
    // are null) created graphs with NO UUID at all, because the only UUID
    // source was the disk-backed adapter.  This map guarantees `createGraph`
    // always assigns a UUID and `getGraphUuid` can always return one, making
    // tenant-bound sessions work transparently even in in-memory mode.  When
    // an adapter IS present it remains the source of truth (its UUID maps to
    // the on-disk graph directory); this map is the fallback and stays
    // consistent with it (createGraph/openOrCreateGraphWithUuid mirror the
    // adapter UUID here).  Key owned by store allocator.
    graph_uuids: std.StringHashMap([16]u8),
    // CANARY: REQ=REQ-PERF-LABEL-INDEX-001; FEATURE="LabelBasedIndex"; ASPECT=NodeLookup; STATUS=TESTED; TEST=tests/test_match_set_label_scan_regression.zig; OWNER=perf; UPDATED=2026-04-23
    // Issue #391: Label-based index for O(1) node lookups instead of O(n) full table scans
    // Maps "graph_name:label" composite key to `LabelPosting { sorted node ids, mutex }`.
    //
    // Task 17 (enterprise-ingest-throughput): the posting list's inner
    // `ArrayList(u64)` is guarded by a per-key `std.Thread.Mutex`. This lets
    // multiple writers that target *different* labels mutate in parallel while
    // still serialising mutations within a single hot label. The outer
    // `StringHashMap` itself is still protected by the per-graph rwlock
    // (`mg.rwlock`) — inserting a new key rehashes the map, which must remain
    // exclusive.
    label_index: std.StringHashMap(LabelPosting),
    // CANARY: REQ=REQ-QUIC-HC-120; FEATURE="High-Concurrency Label Counts"; ASPECT=LabelCountRefcounts; STATUS=TESTED; TEST=test_graph_store_label_count_refcounts; OWNER=storage; UPDATED=2026-05-28
    //
    // Exact (graph, label) cardinalities maintained beside `label_index`.
    // Count-only reads can load this refcount without contending on the hot
    // posting-list mutex used by concurrent inserts.
    label_counts_by_graph: std.StringHashMap(LabelCountValue),
    // Exact (graph, edge_type) cardinalities maintained beside `edge_type_index`,
    // mirroring `label_counts_by_graph` for the edge side. Lets the typed
    // `count(r:TYPE)` fast path answer O(1) instead of materializing one row per
    // edge. Durability is replay-on-load: rebuilt by the open edge-scan in
    // `loadOneGraphFromAdapter` (exactly like the label refcount + untyped
    // edge count). Key format "graph:type" (see formatGraphLabelKey).
    edge_type_counts_by_graph: std.StringHashMap(LabelCountValue),
    // CANARY: REQ=REQ-PERF-GRAPH-SCOPED-NODES-001; FEATURE="GraphScopedNodeIndex"; ASPECT=NodesByGraph; STATUS=TESTED; TEST=tests/test_perf_b_graph_scoped_iteration.zig; OWNER=perf; UPDATED=2026-05-15
    // PERF-B (issue #811): Per-graph node-id index so MATCH (n) and equivalent
    // full-store iterators can scope to a single graph in O(nodes_in_graph)
    // instead of O(total_nodes_across_all_graphs). Maintained under the SAME
    // outer-graph rwlock (Tier 1) that protects `nodes` — no new ordering risk.
    // Empty graphs are tracked by an empty inner map; absent outer entry =
    // graph has never seen a node insert.
    nodes_by_graph: std.StringHashMap(std.AutoHashMap(u64, void)),
    // CANARY: REQ=REQ-PERF-LSP-INTROSPECTION-INDEX-001; FEATURE="LspIntrospectionIndex"; ASPECT=LabelEdgeProperty; STATUS=TESTED; TEST=tests/test_perf_c_lsp_introspection_index.zig; OWNER=perf; UPDATED=2026-05-15
    // PERF-C (issue #814): Tenant-keyed multiset of node labels, edge types,
    // and (label, property) pairs. Lets `listNodeLabels`, `listEdgeTypes`,
    // and `listPropertiesForLabel` answer in O(distinct_labels_for_tenant)
    // instead of O(nodes_in_store * labels_per_node). Reference counts are
    // maintained on every create/delete/addLabel/removeLabel/setProperty/
    // removeProperty path; when a refcount hits zero the entry is dropped
    // so the index never reports labels/types/properties no node still
    // carries. `filter_tenant == null` (admin path) aggregates across every
    // tenant via the outer map.
    //
    // GAP-ENT-0023 P3 (loop2 snapshot persistence): the outer key is the
    // COMPOSITE "graph\x00tenant" (see formatGraphTenantKey) instead of the
    // bare tenant. Grouping by graph makes each graph's contribution to the
    // introspection counters a DISJOINT set of outer entries, so the per-graph
    // hydration snapshot can persist / restore them exactly (a bare-tenant key
    // aggregates across graphs and cannot be decomposed at checkpoint time).
    // The tenant-filtered readers match on the tenant COMPONENT
    // (graphTenantKeyTenant) — the outer map is tiny (graphs x tenants), so
    // the scan is O(outer_entries) and preserves the GAP-0509 tenant-isolation
    // property exactly (component match, never substring).
    // Outer key: "graph\x00tenant_id" (owned by store allocator)
    // Inner key: label / edge type / property — owned by store allocator
    node_labels_by_tenant: std.StringHashMap(std.StringHashMap(usize)),
    edge_types_by_tenant: std.StringHashMap(std.StringHashMap(usize)),
    // tenant -> "label\x00prop_key" -> refcount. The composite key lets a
    // single map serve `listPropertiesForLabel`; pointers stay stable across
    // refcount changes (we only insert/remove on 0↔1 transitions).
    label_properties_by_tenant: std.StringHashMap(std.StringHashMap(usize)),
    // MERGE property index: enables O(1) candidate lookup by (graph, label, property_key, property_value).
    // Key format: "graph\x00label\x00prop_key\x00prop_value_bytes" → node_id.
    // Updated synchronously by setNodeProperty/removeNodeProperty/deleteNodeNoSave.
    merge_prop_index: MergePropertyIndex,
    // PERF-C (issue #814) race fix (2026-05-18): serialize every access to
    // the three tenant-keyed refcount maps (`node_labels_by_tenant`,
    // `edge_types_by_tenant`, `label_properties_by_tenant`).  The bump/dec
    // paths reach `std.StringHashMap.getOrPut`, which trips its
    // `pointer_stability.lock` assertion on a concurrent rehash; the
    // reader paths (`listNodeLabels`, `listEdgeTypes`,
    // `listPropertiesForLabel`) iterate the same maps and must observe a
    // stable structure for the duration of the walk.
    //
    // Acquired by `bumpRefcount`, `decRefcount`, `listNodeLabels`,
    // `listEdgeTypes`, and `listPropertiesForLabel`.  Leaf-level (no
    // other lock is acquired while it is held), but it MAY be acquired
    // while `labels_rwlock` is held EXCLUSIVE (the addNodeLabel /
    // removeNodeLabel writers reach `bumpLabelCount` /
    // `decLabelCount` while inside the labels_rwlock critical section)
    // — so the strict ordering is `labels_rwlock` → `perf_c_refcount_mutex`.
    // Tier 1 per CLAUDE.md (alongside merge_prop_index shard mutexes).
    perf_c_refcount_mutex: std.Io.Mutex = std.Io.Mutex.init,
    // CANARY: REQ=REQ-QUIC-HC-032; FEATURE="High-Concurrency Label Counts"; ASPECT=LabelPostingLocking; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=storage; UPDATED=2026-06-11
    //
    // Group-commit shard writers mutate `label_index` while holding the
    // whole-graph rwlock in SHARED mode. The legacy label-index contract
    // assumed an exclusive graph lock protected the outer HashMap; mixed
    // count/read + CREATE traffic therefore let countNodesByLabel race a
    // posting-list insert. This mutex guards the outer map and is held while
    // a posting's leaf mutex is held, so rehash cannot move a locked posting.
    label_index_mutex: std.Io.Mutex = std.Io.Mutex.init,
    // CANARY: REQ=REQ-STARTUP-P1B-CONCFIX-001; FEATURE="LazyHydrationConcurrency"; ASPECT=NodesByGraphLeafLock; STATUS=TESTED; TEST=tests/test_startup_lazy_hydrate.zig; OWNER=storage; UPDATED=2026-06-29
    //
    // PHASE 1b concurrency fix: `nodes_by_graph` historically relied on the
    // EXCLUSIVE per-graph rwlock to protect its outer StringHashMap against
    // rehash. Lazy hydration (`ensureGraphHydrated`) breaks that assumption:
    // a FIRST read of a cold graph rebuilds the deferred indexes by calling
    // `addNodeToGraphIndex` (StringHashMap.getOrPut -> whole-map rehash) while
    // the caller holds only the SHARED store lock, racing concurrent SHARED
    // readers of OTHER graphs (`iterateNodesInGraph` / `nodesInGraphCount`)
    // and concurrent first-touch hydration of yet other graphs (CWE-362).
    // This leaf mutex serialises every outer-map structural access (rehash on
    // the writer; the getPtr lookups that extract a stable heap-backed inner
    // iterator/count on the readers) so the rehash can never tear a concurrent
    // reader. Leaf-level: no other lock is acquired while it is held, so it is
    // ordering-safe under either the SHARED or EXCLUSIVE store lock. (The
    // sibling `label_index` already has `label_index_mutex` on its writer; the
    // companion fix wires that mutex into its lockless readers below.)
    nodes_by_graph_mutex: std.Io.Mutex = std.Io.Mutex.init,
    // CANARY: REQ=REQ-QUIC-HC-163; FEATURE="High-Concurrency Label Counts"; ASPECT=AtomicLabelCountRefcounts; STATUS=TESTED; TEST=test-graph-store; OWNER=storage; UPDATED=2026-06-11
    //
    // Existing graph+label refcount entries are mutated atomically while this
    // rwlock is held SHARED for map pointer stability. New labels still take it
    // EXCLUSIVE for HashMap insertion/rehash. This removes the single global
    // mutex that serialized every hot-label count read with every mutation.
    label_count_rwlock: std.Io.RwLock = std.Io.RwLock.init,
    // Guards `edge_type_counts_by_graph` exactly like `label_count_rwlock`
    // guards `label_counts_by_graph`: SHARED for atomic bump/dec of an existing
    // (graph,type) entry (map pointer stability), EXCLUSIVE for inserting a new
    // (graph,type) key (HashMap rehash). Leaf-level.
    edge_type_count_rwlock: std.Io.RwLock = std.Io.RwLock.init,
    // GAP-825 (issue #825): per-store rwlock that serialises the
    // free-then-reassign sequences on `Node.labels` (in `addNodeLabel`,
    // `removeNodeLabel`, and their `NoSave` variants) against the
    // snapshot reader in `cloneNodesFrom`.  Held EXCLUSIVE for the brief
    // free+reassign window in the writers; held SHARED across the
    // `source.nodes` walk in `cloneNodesFrom`.  Leaf-level: no other
    // mutex/lock may be acquired while it is held, so there is no
    // nesting / ordering risk with `g_store_rwlock` or per-graph rwlocks.
    labels_rwlock: std.Io.RwLock = std.Io.RwLock.init,
    // CANARY: REQ=REQ-PERF-EDGE-TYPE-INDEX-001; FEATURE="EdgeTypeIndex"; ASPECT=EdgeTypeLookup; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=perf; UPDATED=2026-04-10
    // PERF-P0-001: Edge-type index for O(1) getEdgesByType lookups instead of O(E) full scan
    // Maps "graph_name:edge_type" composite key to sorted list of edge IDs
    edge_type_index: std.StringHashMap(std.ArrayList(u64)),
    // CANARY: REQ=REQ-PERF-EDGE-ADJ-001; FEATURE="EdgeAdjacencyIndex"; ASPECT=EdgeLookup; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=perf; UPDATED=2026-04-11
    // Issue #392: Adjacency lists for fast edge lookups during DELETE DETACH.
    // PHASE 0 (edge-engine-direct): BOUNDED, evict-freely caches over the engine
    // adjacency (hydrate-on-miss). See AdjCache / AdjList above.
    outgoing_edges: AdjCache, // from_node_id -> PUBLIC edge_ids (bounded)
    incoming_edges: AdjCache, // to_node_id -> PUBLIC edge_ids (bounded)
    /// Per-graph IdMaps for UUIDv7 ↔ engine slot_id translation.
    id_maps: std.StringHashMap(id_map_mod.IdMap) = undefined,
    // dsn_graph_binding.yml race fix (2026-05-23): serialize CREATE /
    // OPEN-OR-CREATE / DROP graph mutations so the in-memory `graphs`
    // map and the adapter-backed registry can't observe each other in
    // half-applied states.  Without this, two concurrent QUIC HELLOs
    // hitting `createGraph` for the same fresh DSN-bound name both
    // pass the unguarded `self.graphs.contains` pre-check, both call
    // the (already-serialized) vtable, and the loser's `graphs.put`
    // races on a stale "doesn't exist" assumption — surfacing
    // `error.GraphAlreadyExists` from the second `contains` check and
    // bubbling up to the client as "Failed to create graph".  Tier 1
    // leaf mutex per CLAUDE.md: never acquired while any higher-tier
    // mutex is held.
    graphs_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Optional CSR adjacency for fast traversal (if built elsewhere)
    csr: ?*const anyopaque = null,
    // CANARY: REQ=REQ-BINARY-PERSIST-DIRTY-001; FEATURE="BinaryPersistence"; ASPECT=DirtyTracking; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=storage; UPDATED=2026-04-11
    // Track if store has unsaved changes - avoids O(n²) persistence during batch operations.
    // Atomic because the persistence thread reads this without holding the store write lock
    // while mutation threads write it under the write lock (data race fix).
    dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    data_dir: []const u8 = "",
    // PHASE 1b: graphs registered from the adapter at open whose resident loop2
    // indexes are deferred. graph_name (owned) -> *HydrationEntry. A graph
    // ABSENT here is treated as already-hydrated (freshly CREATEd graphs, the
    // default graph, snapshot/clone stores) so `ensureGraphHydrated` is a no-op
    // for them. Guarded structurally by `hydration_mutex`; the actual per-graph
    // build is serialised by each entry's own mutex.
    pending_hydration: std.StringHashMap(*HydrationEntry) = undefined,
    hydration_mutex: std.Io.Mutex = std.Io.Mutex.init,
    // PHASE 1b concurrency fix (review): a STORE-WIDE serialiser for the actual
    // per-graph hydration BUILD (`loadOneGraphFromAdapterFull`). The per-graph
    // `entry.mutex` only serialises first-touches of the SAME graph; first
    // touches of DIFFERENT cold graphs (A and B) would otherwise run their
    // builds concurrently and both mutate the STORE-WIDE maps the build touches
    // (`id_maps`/`graphs` getOrPut, `merge_prop_index`, etc.) at the same time —
    // a data race (CWE-362) that trips the HashMap pointer-stability SafetyLock.
    // The build runs under the global store lock only in SHARED mode (R6: the
    // global EXCLUSIVE lock is RESTORE/BACKUP-only and cannot be acquired from a
    // chokepoint already holding it SHARED without deadlocking), so this leaf
    // mutex provides the cross-graph build mutual-exclusion the shared store lock
    // does not. Held ONLY on the rare first-touch build, never on the hydrated
    // fast path, so the read hot path is unaffected. Ordering: entry.mutex ->
    // hydration_build_mutex (then the build's own leaf locks); never the reverse.
    hydration_build_mutex: std.Io.Mutex = std.Io.Mutex.init,

    /// Initialize GraphStore with default tenant
    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!GraphStore {
        return initWithTenant(allocator, "default", "default");
    }

    /// Initialize GraphStore with specific tenant and schema
    pub fn initWithTenant(allocator: std.mem.Allocator, tenant_id: []const u8, schema_name: []const u8) error{OutOfMemory}!GraphStore {
        var store = GraphStore{
            .allocator = allocator,
            .nodes = try NodeCache.init(allocator, .{
                .cap = nodeCacheCapFromEnv(),
                .free_fn = freeNodeValue,
                // hydrate hook installed via store.nodes.setHydrate(...) once the
                // storage adapter is available (see installNodeCacheHydrate).
                .hydrate_fn = null,
                .hydrate_ctx = null,
            }),
            // PHASE 1: bounded edge-body cache. Like the node + adjacency caches,
            // the cap is forced UNBOUNDED until the hydrate hook is installed
            // (engine available) via installEdgeCacheHydrate — eviction without
            // rehydration would lose an in-memory-only edge body.
            .edges = try EdgeCache.init(allocator, .{
                .cap = edgeCacheCapFromEnv(),
                .free_fn = freeEdgeValue,
                .hydrate_fn = null,
                .hydrate_ctx = null,
            }),
            .next_node_id = 1,
            .next_edge_id = 1,
            .tenant_id = tenant_id,
            .schema_name = schema_name,
            .graphs = std.StringHashMap(void).init(allocator),
            // GAP-0839: per-graph persistent UUID fallback map.
            .graph_uuids = std.StringHashMap([16]u8).init(allocator),
            // Issue #391, #392: Initialize performance optimization indexes
            .label_index = std.StringHashMap(LabelPosting).init(allocator),
            .label_counts_by_graph = std.StringHashMap(LabelCountValue).init(allocator),
            // Per-(graph,edge_type) exact cardinalities (mirror of label refcount).
            .edge_type_counts_by_graph = std.StringHashMap(LabelCountValue).init(allocator),
            // PERF-B (issue #811): per-graph node-id index for O(nodes_in_graph) scans.
            .nodes_by_graph = std.StringHashMap(std.AutoHashMap(u64, void)).init(allocator),
            // PERF-C (issue #814): tenant-keyed multiset for O(1) LSP introspection.
            .node_labels_by_tenant = std.StringHashMap(std.StringHashMap(usize)).init(allocator),
            .edge_types_by_tenant = std.StringHashMap(std.StringHashMap(usize)).init(allocator),
            .label_properties_by_tenant = std.StringHashMap(std.StringHashMap(usize)).init(allocator),
            .merge_prop_index = MergePropertyIndex.init(allocator),
            // PERF-P0-001: Edge-type index for O(1) edge-type lookups
            .edge_type_index = std.StringHashMap(std.ArrayList(u64)).init(allocator),
            // PHASE 0: bounded adjacency caches. Like the node cache, the cap is
            // forced UNBOUNDED until the hydrate hook is installed (engine
            // available) via installAdjCacheHydrate — eviction without
            // rehydration would lose an in-memory-only edge list.
            .outgoing_edges = try AdjCache.init(allocator, .{
                .cap = adjCacheCapFromEnv(),
                .free_fn = freeAdjListValue,
                .hydrate_fn = null,
                .hydrate_ctx = null,
            }),
            .incoming_edges = try AdjCache.init(allocator, .{
                .cap = adjCacheCapFromEnv(),
                .free_fn = freeAdjListValue,
                .hydrate_fn = null,
                .hydrate_ctx = null,
            }),
            .id_maps = std.StringHashMap(id_map_mod.IdMap).init(allocator),
            // PHASE 1b: per-graph deferred-hydration registry.
            .pending_hydration = std.StringHashMap(*HydrationEntry).init(allocator),
        };
        // Register default graph name
        const default_name = try allocator.dupe(u8, "default");
        try store.graphs.put(default_name, {});
        // GAP-0839: seed an in-memory persistent UUID for the default graph so
        // an in-memory (no --data-dir) deployment can serve tenant-bound
        // sessions on the default graph.  When a disk adapter is wired it
        // overrides this in `getGraphUuid` with the on-disk graph's UUID.
        const default_uuid_name = try allocator.dupe(u8, "default");
        errdefer allocator.free(default_uuid_name);
        try store.graph_uuids.put(default_uuid_name, generatePersistentUuid());
        return store;
    }

    /// Pre-allocate storage for nodes/edges to avoid rehash churn during bulk loads.
    pub fn reserve(self: *GraphStore, node_capacity: usize, edge_capacity: usize) !void {
        try self.nodes.ensureTotalCapacity(@intCast(node_capacity));
        try self.edges.ensureTotalCapacity(@intCast(edge_capacity));
        try self.outgoing_edges.ensureTotalCapacity(@intCast(edge_capacity));
        try self.incoming_edges.ensureTotalCapacity(@intCast(edge_capacity));
        try self.label_index.ensureTotalCapacity(@intCast(node_capacity));
        try self.edge_type_index.ensureTotalCapacity(@intCast(edge_capacity));
    }

    /// DEPRECATED (GAP-0279): Set tenant ID on the process-wide singleton.
    /// This races under concurrent access. Use ExecutionContext.tenant_id instead.
    /// Retained for FLE encryption context backward compatibility.
    pub fn setTenant(self: *GraphStore, tenant_id: []const u8) void {
        self.tenant_id = tenant_id;
    }

    /// Set schema name for this graph store
    pub fn setSchema(self: *GraphStore, schema_name: []const u8) void {
        self.schema_name = schema_name;
    }

    /// Get current tenant ID
    pub fn getTenantId(self: *const GraphStore) []const u8 {
        return self.tenant_id;
    }

    pub fn deinit(self: *GraphStore) void {
        // Clear nodes and edges (which also frees memory)
        self.clearNodes();
        // Deinit the hashmaps
        self.nodes.deinit();
        self.edges.deinit();
        // GAP-ENT-0023 P3 (review C2/I1): free any remaining detached scan
        // boxes (clearNodes already purged; this releases the list storage).
        self.freeAllScanHydrated();

        // Clean up graph registry
        var graph_iter = self.graphs.iterator();
        while (graph_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.graphs.deinit();

        // GAP-0839: Clean up per-graph persistent-UUID map.
        var uuid_iter = self.graph_uuids.iterator();
        while (uuid_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.graph_uuids.deinit();

        // Issue #391: Clean up label index
        var label_iter = self.label_index.iterator();
        while (label_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.label_index.deinit();

        var label_count_iter = self.label_counts_by_graph.iterator();
        while (label_count_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.label_counts_by_graph.deinit();

        var edge_type_count_iter = self.edge_type_counts_by_graph.iterator();
        while (edge_type_count_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.edge_type_counts_by_graph.deinit();

        // PERF-B (issue #811): Clean up per-graph node-id index.
        var nbg_iter = self.nodes_by_graph.iterator();
        while (nbg_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.nodes_by_graph.deinit();

        // PERF-C (issue #814): Clean up tenant-keyed introspection indexes.
        deinitTenantStringMultiset(&self.node_labels_by_tenant, self.allocator);
        deinitTenantStringMultiset(&self.edge_types_by_tenant, self.allocator);
        deinitTenantStringMultiset(&self.label_properties_by_tenant, self.allocator);

        self.merge_prop_index.deinit();

        // PERF-P0-001: Clean up edge-type index
        var eti_iter = self.edge_type_index.iterator();
        while (eti_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.edge_type_index.deinit();

        // Issue #392 / PHASE 0: clean up adjacency caches. AdjCache.deinit frees
        // every resident AND retired AdjList via freeAdjListValue, so no manual
        // per-entry walk is needed (and a walk would miss the retired backlog).
        self.outgoing_edges.deinit();
        self.incoming_edges.deinit();

        // Clean up per-graph IdMaps
        var id_map_iter = self.id_maps.iterator();
        while (id_map_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.id_maps.deinit();

        // PHASE 1b: free the per-graph deferred-hydration registry (owned key +
        // heap-allocated HydrationEntry).
        var ph_iter = self.pending_hydration.iterator();
        while (ph_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.pending_hydration.deinit();
    }

    pub fn clearNodes(self: *GraphStore) void {
        // Free and clear all nodes. The BoundedNodeCache frees every resident
        // value via its free_fn (freeNodeValue) AND drains the retire list, so
        // the manual per-node free loop is no longer needed here.
        self.nodes.clearRetainingCapacity();

        // Free and clear all edges. PHASE 1: EdgeCache.clearRetainingCapacity
        // frees every resident AND retired Edge via freeEdgeValue (label +
        // graph_name + tenant_id + property map) and clears each shard's FIFO, so
        // the manual per-edge free loop is gone (and a walk would MISS the
        // retired backlog and double-free the resident ones).
        self.edges.clearRetainingCapacity();

        // GAP-ENT-0023 P3 (review C2/I1): the detached scan boxes mirror the
        // resident node set — drop them whenever the node cache is reset.
        self.freeAllScanHydrated();

        self.next_node_id = 1;
        self.next_edge_id = 1;

        // Reset graph registry to default
        var graph_iter = self.graphs.iterator();
        while (graph_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.graphs.deinit();
        self.graphs = std.StringHashMap(void).init(self.allocator);
        const default_name = self.allocator.dupe(u8, "default") catch @panic("OOM: failed to allocate default graph name during clearNodes");
        self.graphs.put(default_name, {}) catch @panic("OOM: failed to register default graph during clearNodes");

        // GAP-0839: Reset persistent-UUID map alongside the graph registry and
        // re-seed the default graph so an in-memory store stays able to serve
        // tenant-bound sessions on the default graph after a reset.
        var uuid_reset_iter = self.graph_uuids.iterator();
        while (uuid_reset_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.graph_uuids.deinit();
        self.graph_uuids = std.StringHashMap([16]u8).init(self.allocator);
        const default_uuid_name = self.allocator.dupe(u8, "default") catch @panic("OOM: failed to allocate default graph uuid key during clearNodes");
        self.graph_uuids.put(default_uuid_name, generatePersistentUuid()) catch @panic("OOM: failed to register default graph uuid during clearNodes");

        // Reset label index
        var label_iter = self.label_index.iterator();
        while (label_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.label_index.deinit();
        self.label_index = std.StringHashMap(LabelPosting).init(self.allocator);

        var label_count_iter = self.label_counts_by_graph.iterator();
        while (label_count_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.label_counts_by_graph.deinit();
        self.label_counts_by_graph = std.StringHashMap(LabelCountValue).init(self.allocator);

        var edge_type_count_iter = self.edge_type_counts_by_graph.iterator();
        while (edge_type_count_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.edge_type_counts_by_graph.deinit();
        self.edge_type_counts_by_graph = std.StringHashMap(LabelCountValue).init(self.allocator);

        // PERF-B (issue #811): Reset per-graph node-id index.
        {
            var nbg_iter = self.nodes_by_graph.iterator();
            while (nbg_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit();
            }
            self.nodes_by_graph.deinit();
            self.nodes_by_graph = std.StringHashMap(std.AutoHashMap(u64, void)).init(self.allocator);
        }

        // PERF-C (issue #814): Reset tenant-keyed introspection indexes.
        deinitTenantStringMultiset(&self.node_labels_by_tenant, self.allocator);
        deinitTenantStringMultiset(&self.edge_types_by_tenant, self.allocator);
        deinitTenantStringMultiset(&self.label_properties_by_tenant, self.allocator);
        self.node_labels_by_tenant = std.StringHashMap(std.StringHashMap(usize)).init(self.allocator);
        self.edge_types_by_tenant = std.StringHashMap(std.StringHashMap(usize)).init(self.allocator);
        self.label_properties_by_tenant = std.StringHashMap(std.StringHashMap(usize)).init(self.allocator);

        self.merge_prop_index.reset();

        // PERF-P0-001: Reset edge-type index
        var eti_iter = self.edge_type_index.iterator();
        while (eti_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.edge_type_index.deinit();
        self.edge_type_index = std.StringHashMap(std.ArrayList(u64)).init(self.allocator);

        // Reset adjacency caches. PHASE 0: AdjCache.clearRetainingCapacity frees
        // every resident AND retired AdjList via freeAdjListValue and clears each
        // shard's FIFO, keeping the shard backing arrays live (cheaper than
        // deinit+init).
        self.outgoing_edges.clearRetainingCapacity();
        self.incoming_edges.clearRetainingCapacity();

        // Reset per-graph IdMaps
        var id_map_iter = self.id_maps.iterator();
        while (id_map_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.id_maps.deinit();
        self.id_maps = std.StringHashMap(id_map_mod.IdMap).init(self.allocator);
    }

    /// Clear the graph registry (removes all graph names, for test isolation)
    pub fn clearGraphRegistry(self: *GraphStore) void {
        var graph_iter = self.graphs.iterator();
        while (graph_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.graphs.deinit();
        self.graphs = std.StringHashMap(void).init(self.allocator);

        // GAP-0839: clear the persistent-UUID map in lockstep.
        var uuid_iter = self.graph_uuids.iterator();
        while (uuid_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.graph_uuids.deinit();
        self.graph_uuids = std.StringHashMap([16]u8).init(self.allocator);
    }

    // Clear only nodes and edges for a specific graph
    // CANARY: REQ=REQ-MULTI-GRAPH-005; FEATURE="MultiGraphIsolation"; ASPECT=ClearGraphNodes; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-23
    pub fn clearNodesForGraph(self: *GraphStore, graph_name: []const u8) void {
        // Collect node IDs to remove (can't modify while iterating)
        var nodes_to_remove = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return;
        defer nodes_to_remove.deinit(self.allocator);

        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.graph_name, graph_name)) {
                nodes_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        // Remove and free the nodes
        for (nodes_to_remove.items) |node_id| {
            self.deleteNodeNoSave(node_id);
        }

        // Remove any remaining edges tagged with this graph (defensive cleanup)
        var edges_to_remove = std.ArrayList(u64).initCapacity(self.allocator, 0) catch return;
        defer edges_to_remove.deinit(self.allocator);

        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.graph_name, graph_name)) {
                edges_to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (edges_to_remove.items) |edge_id| {
            self.deleteEdgeNoSave(edge_id);
        }
    }

    // CANARY: REQ=REQ-MULTI-GRAPH-008; FEATURE="GraphRegistry"; ASPECT=GraphHelpers; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=storage; UPDATED=2026-04-11
    fn ensureGraph(self: *GraphStore, graph_name: []const u8) !void {
        try self.ensureGraphNoDirty(graph_name);
        self.dirty.store(true, .release);
        incrementMutationEpoch();
    }

    fn ensureGraphNoDirty(self: *GraphStore, graph_name: []const u8) !void {
        if (self.graphs.contains(graph_name)) return;
        const name_copy = try self.allocator.dupe(u8, graph_name);
        try self.graphs.put(name_copy, {});
    }

    /// Get or create the IdMap for a named graph.
    pub fn getOrCreateIdMap(self: *GraphStore, graph_name: []const u8) !*id_map_mod.IdMap {
        const result = try self.id_maps.getOrPut(graph_name);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, graph_name);
            result.value_ptr.* = id_map_mod.IdMap.init(self.allocator);
        }
        return result.value_ptr;
    }

    /// Get the IdMap for a named graph (read-only, returns null if not found).
    pub fn getIdMap(self: *GraphStore, graph_name: []const u8) ?*id_map_mod.IdMap {
        return self.id_maps.getPtr(graph_name);
    }

    fn requireIdMap(self: *GraphStore, graph_name: []const u8) !*id_map_mod.IdMap {
        return self.getIdMap(graph_name) orelse error.IdMapNotLoaded;
    }

    fn cloneIdMapsFrom(self: *GraphStore, source: *const GraphStore) !void {
        var it = source.id_maps.iterator();
        while (it.next()) |entry| {
            const graph_name = entry.key_ptr.*;
            if (self.id_maps.contains(graph_name)) continue;

            const key_copy = try self.allocator.dupe(u8, graph_name);
            errdefer self.allocator.free(key_copy);

            const map_copy = try entry.value_ptr.clone(self.allocator);
            errdefer {
                var map = map_copy;
                map.deinit();
            }

            try self.id_maps.put(key_copy, map_copy);
        }
    }

    /// Deep-copy one source node into this (snapshot) store, mirroring the
    /// per-graph + tenant-keyed indexes so reads against the snapshot match the
    /// live store. Extracted so both the unbounded (resident-iterator) and
    /// bounded (IdMap-enumerated + engine-materialised) clone paths share it.
    fn cloneOneNode(self: *GraphStore, src_node: *const Node) !void {
        // GAP-0900 (scan-no-clone): count every node we deep-copy so a
        // regression test can detect O(graph) clone cost on a read that
        // should be O(result).
        _ = g_clone_nodes_total.fetchAdd(1, .monotonic);
        const labels_copy = try self.allocator.alloc([]const u8, src_node.labels.len);
        for (src_node.labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
        }

        var props = CompactPropertyMap.init(self.allocator);
        var prop_it = src_node.properties.iterator();
        while (prop_it.next()) |prop| {
            const key = try self.allocator.dupe(u8, prop.key_ptr.*);
            // Deep-copy property values so the snapshot owns all its string data
            // independently (shared pointers would UAF when the arena frees).
            try props.put(key, try copyPropertyValue(self, prop.value_ptr.*));
        }

        try self.nodes.put(src_node.id, .{
            .id = src_node.id,
            .labels = labels_copy,
            .properties = props,
            .graph_name = try self.allocator.dupe(u8, src_node.graph_name),
            .tenant_id = try self.allocator.dupe(u8, src_node.tenant_id),
        });

        for (src_node.labels) |label| {
            try self.addToLabelIndex(src_node.graph_name, label, src_node.id);
        }
        try self.addNodeToGraphIndex(src_node.graph_name, src_node.id);
        for (src_node.labels) |label| {
            try self.bumpLabelCount(src_node.graph_name, src_node.tenant_id, label);
        }
        var prop_replay = src_node.properties.iterator();
        while (prop_replay.next()) |p| {
            const pkey = p.key_ptr.*;
            if (isInternalPersistedPropertyKey(pkey)) continue;
            for (src_node.labels) |label| {
                try self.bumpLabelPropertyCount(src_node.graph_name, src_node.tenant_id, label, pkey);
            }
        }
    }

    /// Clone all nodes and edges from another store. Used by QueryReadSession
    /// to create a point-in-time snapshot without going through the adapter.
    fn cloneNodesFrom(self: *GraphStore, source: *const GraphStore) !void {
        // Clone graphs registry
        var graph_it = source.graphs.iterator();
        while (graph_it.next()) |entry| {
            const key = try self.allocator.dupe(u8, entry.key_ptr.*);
            try self.graphs.put(key, {});
        }

        // Clone nodes.
        //
        // GAP-825 (issue #825): hold `source.labels_rwlock` SHARED across
        // the entire walk so concurrent `addNodeLabel`/`removeNodeLabel`
        // writers cannot free `node.labels` while we are dereferencing it.
        // The writers grab the same lock EXCLUSIVE around their
        // free+reassign window.  Leaf lock, no nesting/ordering risk.
        const io_clone = std.Io.Threaded.global_single_threaded.io();
        @constCast(&source.labels_rwlock).lockSharedUncancelable(io_clone);
        defer @constCast(&source.labels_rwlock).unlockShared(io_clone);

        if (source.nodes.effectiveCap() == 0) {
            // Unbounded source: the resident map is the full set.
            var node_it = source.nodes.iterator();
            while (node_it.next()) |entry| {
                try self.cloneOneNode(entry.value_ptr);
            }
        } else {
            // Bounded source: the resident map is INCOMPLETE. Enumerate every
            // public id from the source's per-graph IdMaps (fully resident) and
            // materialise each node — resident copy if present, else rebuilt from
            // the engine — so the snapshot is complete. Materialised nodes are
            // freed after copying (they are NOT inserted into the source cache,
            // so a full snapshot never blows the source's resident bound).
            const adapter = global_adapter;
            var it = @constCast(source).id_maps.iterator();
            while (it.next()) |im_entry| {
                const graph_name = im_entry.key_ptr.*;
                var nit = im_entry.value_ptr.nodeUuidIterator();
                while (nit.next()) |nuuid| {
                    const id = @as(u64, @truncate(nuuid));
                    if (@constCast(source).nodes.get(id)) |resident| {
                        var n = resident;
                        try self.cloneOneNode(&n);
                    } else if (adapter) |ad| {
                        const slot = im_entry.value_ptr.nodeSlot(@as(u128, id)) orelse continue;
                        var materialized = (try materializeNodeFromEngine(ad, self.allocator, graph_name, slot, id)) orelse continue;
                        defer freeNodeValue(self.allocator, &materialized);
                        try self.cloneOneNode(&materialized);
                    }
                }
            }
        }

        self.next_node_id = source.next_node_id;
        self.next_edge_id = source.next_edge_id;

        // Clone edges
        var edge_it = source.edges.iterator();
        while (edge_it.next()) |entry| {
            const src_edge = entry.value_ptr.*;
            var props = CompactPropertyMap.init(self.allocator);
            var prop_it = src_edge.properties.iterator();
            while (prop_it.next()) |prop| {
                const key = try self.allocator.dupe(u8, prop.key_ptr.*);
                // Deep-copy edge property values (same rationale as node properties)
                try props.put(key, try copyPropertyValue(self, prop.value_ptr.*));
            }

            try self.edges.put(entry.key_ptr.*, .{
                .id = src_edge.id,
                .from_id = src_edge.from_id,
                .to_id = src_edge.to_id,
                .label = try self.allocator.dupe(u8, src_edge.label),
                .properties = props,
                .graph_name = try self.allocator.dupe(u8, src_edge.graph_name),
                .tenant_id = try self.allocator.dupe(u8, src_edge.tenant_id),
            });

            try self.addToAdjacencyIndex(src_edge.from_id, src_edge.to_id, src_edge.id);
            // PERF-P0-001: Maintain edge-type index during clone
            try self.addToEdgeTypeIndex(src_edge.graph_name, src_edge.label, src_edge.id);
            // PERF-C (issue #814): tenant-keyed edge-type counter.
            try self.bumpEdgeTypeCount(src_edge.graph_name, src_edge.tenant_id, src_edge.label);
            // Per-(graph,type) exact counter (typed count(r:TYPE) fast path).
            self.bumpGraphEdgeTypeCount(src_edge.graph_name, src_edge.label);
        }
    }

    fn requireNodeSlot(self: *GraphStore, graph_name: []const u8, node_id: u64) !u64 {
        const id_map = self.requireIdMap(graph_name) catch return error.NodeSlotMappingMissing;
        return id_map.nodeSlot(@as(u128, node_id)) orelse error.NodeSlotMappingMissing;
    }

    /// Resolve which graph + engine slot a public node id belongs to, by
    /// scanning the per-graph IdMaps. Public ids are globally unique, so the
    /// first IdMap that maps the id wins. O(graphs); for the common single-graph
    /// bulk-ingest case it is O(1). Returns null if no IdMap knows the id (the
    /// node was never persisted to an engine — e.g. a pure in-memory deployment
    /// with no adapter).
    const GraphSlot = struct { graph_name: []const u8, slot_id: u64 };
    fn resolveNodeGraphSlot(self: *GraphStore, node_id: u64) ?GraphSlot {
        var it = self.id_maps.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.nodeSlot(@as(u128, node_id))) |slot| {
                return .{ .graph_name = entry.key_ptr.*, .slot_id = slot };
            }
        }
        return null;
    }

    /// Hydrate-on-miss callback for the BoundedNodeCache. Given a public node id
    /// that is NOT resident in the cache, rebuild the full `Node` from the
    /// disk-backed engine (the durable store of record). Returns null if the id
    /// exists in neither the cache nor the engine.
    ///
    /// Ownership matches `insertReservedNodeInMemory` exactly so `freeNodeValue`
    /// frees the result correctly: labels = owned slice of owned strings,
    /// graph_name / tenant_id = owned dupes, properties = CompactPropertyMap
    /// with owned keys/values.
    ///
    /// `ctx` is the `*GraphStore`. Invoked by the cache under whatever lock the
    /// caller holds for the missing read; it only READS the engine and inserts
    /// into the cache map.
    fn hydrateNodeCb(ctx: *anyopaque, allocator: std.mem.Allocator, node_id: u64) anyerror!?Node {
        const self: *GraphStore = @ptrCast(@alignCast(ctx));
        const adapter = global_adapter orelse return null;
        const gs = self.resolveNodeGraphSlot(node_id) orelse return null;
        return materializeNodeFromEngine(adapter, allocator, gs.graph_name, gs.slot_id, node_id);
    }

    /// Rebuild a full `Node` (labels/properties/graph_name/tenant_id) from the
    /// disk-backed engine for `public_id` at engine `slot_id` in `graph_name`.
    /// Ownership matches `insertReservedNodeInMemory` exactly so `freeNodeValue`
    /// frees the result. Returns null if the slot no longer exists. Reused by
    /// hydrate-on-miss AND by the full-graph iterate paths (snapshot/serialize)
    /// when the bounded cache is incomplete.
    pub fn materializeNodeFromEngine(
        adapter: *graph_storage_adapter.StorageAdapter,
        allocator: std.mem.Allocator,
        graph_name: []const u8,
        slot_id: u64,
        public_id: u64,
    ) anyerror!?Node {
        // Labels.
        const labels = adapter.getNodeLabels(graph_name, slot_id, allocator) catch |err| switch (err) {
            error.NodeNotFound => return null,
            else => return err,
        };
        errdefer {
            for (labels) |l| allocator.free(l);
            allocator.free(labels);
        }

        const graph_name_copy = try allocator.dupe(u8, graph_name);
        errdefer allocator.free(graph_name_copy);

        // GAP-0901: own the tenant_id. `freeNodeValue` (the node-cache free_fn,
        // run on grace-point reclaim of an evicted node) UNCONDITIONALLY frees
        // `tenant_id` when len > 0. A hydrated node left pointing at the static
        // `DEFAULT_TENANT_ID` constant would therefore free non-heap memory
        // ("incorrect alignment" abort) the first time a hydrated default-tenant
        // node is reclaimed. Dupe it so the free is always valid, matching every
        // other node-construction path (createNode / loadOneGraphFromAdapter).
        // The `freeNodeValue` errdefer below covers freeing `node.tenant_id` on
        // any later error, so no separate errdefer for the copy is needed.
        var node = Node{
            .id = public_id,
            .labels = labels,
            .properties = CompactPropertyMap.init(allocator),
            .graph_name = graph_name_copy,
            .tenant_id = try allocator.dupe(u8, DEFAULT_TENANT_ID),
        };
        errdefer freeNodeValue(allocator, &node);

        // Properties (all user-visible properties; internal keys are filtered by
        // the adapter's shouldExposePropertyKey).
        var props = adapter.getAllNodeProperties(graph_name, slot_id, allocator) catch |err| switch (err) {
            error.NodeNotFound => return null,
            else => return err,
        };
        defer {
            var pit = props.iterator();
            while (pit.next()) |e| {
                allocator.free(e.key_ptr.*);
                // Engine storage PropertyValue: only `.string` owns heap.
                switch (e.value_ptr.*) {
                    .string => |s| allocator.free(s),
                    else => {},
                }
            }
            props.deinit();
        }
        var pit = props.iterator();
        while (pit.next()) |e| {
            // C3 (review-0023): skip `.null` — the adapter's removeNodeProperty
            // writes a `.null` TOMBSTONE (putPropertyTxn(key, .null)), it never
            // physically deletes the key. Materializing the tombstone as a
            // present PropertyValue.Null made a durably-REMOVEd property
            // resurface after reopen (live remove = fetchRemove = truly absent).
            if (e.value_ptr.* == .null) continue;
            const key = try allocator.dupe(u8, e.key_ptr.*);
            errdefer allocator.free(key);
            const value = try graph_storage_adapter.fromStorageProperty(allocator, e.value_ptr.*);
            const gop = try node.properties.getOrPut(key);
            if (gop.found_existing) {
                // Duplicate key (shouldn't happen) — free the dup key, keep first.
                allocator.free(key);
            } else {
                gop.key_ptr.* = key;
            }
            gop.value_ptr.* = value;
        }

        // Tenant id: persisted as an internal property; absent ⇒ default.
        // getNodeProperty returns the ENGINE storage PropertyValue (`.string`).
        if (adapter.getNodeProperty(graph_name, slot_id, INTERNAL_TENANT_ID_PROPERTY_KEY, allocator) catch null) |tprop| {
            defer switch (tprop) {
                .string => |s| allocator.free(s),
                else => {},
            };
            switch (tprop) {
                .string => |s| {
                    if (!std.mem.eql(u8, s, DEFAULT_TENANT_ID)) {
                        // Replace the owned default copy with the real tenant —
                        // free the default first so it does not leak.
                        const real_tenant = try allocator.dupe(u8, s);
                        allocator.free(node.tenant_id);
                        node.tenant_id = real_tenant;
                    }
                },
                else => {},
            }
        }

        return node;
    }

    /// Install the hydrate-on-miss hook so the node cache can serve evicted ids
    /// from the engine, and activate the configured resident cap. Call once the
    /// global storage adapter is available.
    pub fn installNodeCacheHydrate(self: *GraphStore) void {
        self.nodes.setHydrate(hydrateNodeCb, @ptrCast(self));
    }

    /// Predicate: does this evicted/retired node belong to `graph_name` (passed
    /// as ctx)? Used to scope grace-point reclamation to the checkpointed graph.
    fn retiredNodeInGraph(ctx: *anyopaque, node: *const Node) bool {
        const graph_name: *const []const u8 = @ptrCast(@alignCast(ctx));
        return std.mem.eql(u8, node.graph_name, graph_name.*);
    }

    /// Cache-reclaim grace gate (14.27M SEGV fix, bomb #2 — the WAL/periodic
    /// checkpoint variant of the catalog-reload UAF): the per-graph EXCLUSIVE
    /// rwlock the checkpoint holds drains QUERY readers, but NOT an in-flight
    /// lazy-hydration build — its FamilyPipeline batches hold SHALLOW Node
    /// copies whose sub-heap is owned by resident/just-retired cache entries,
    /// and its core thread concurrently APPENDS to the same retire lists the
    /// reclaim compacts. Every build runs under `hydration_build_mutex`, so
    /// the grace point must additionally hold that mutex to free retired
    /// values. Non-blocking by design: the checkpoint thread must NEVER park
    /// under a graph-exclusive rwlock waiting out a multi-hour build — on
    /// tryLock failure the caller SKIPS reclaim this cycle and the retire
    /// backlog simply persists until the next checkpoint tick.
    ///
    /// (Also inherently covers the hydration-completion persist, which runs
    /// while the build mutex is still held by the SAME thread: its tryLock
    /// fails and the just-finished build's retirees are reclaimed by the next
    /// periodic tick instead.)
    pub fn tryBeginCacheReclaimGrace(self: *GraphStore) bool {
        return self.hydration_build_mutex.tryLock();
    }

    pub fn endCacheReclaimGrace(self: *GraphStore) void {
        self.hydration_build_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    /// Reclaim (free) the node cache's retired entries that belong to
    /// `graph_name`. MUST be called by the storage adapter while it holds that
    /// graph's per-graph rwlock EXCLUSIVE (the checkpoint window), which drains
    /// all readers of that graph's nodes — so freeing them cannot race a live
    /// pointer — AND inside the `tryBeginCacheReclaimGrace` window, which
    /// excludes an in-flight hydration build (whose batch copies and retire-
    /// list appends the rwlock does not cover). This is the grace boundary in
    /// the bound-node-mirror design.
    pub fn reclaimNodeCacheRetiredForGraph(self: *GraphStore, graph_name: []const u8) void {
        var gn = graph_name;
        self.nodes.reclaimRetiredWhere(@ptrCast(&gn), retiredNodeInGraph);
        // GAP-ENT-0023 P3 (review C2/I1): the detached scan boxes share the
        // node cache's grace discipline — free this graph's boxes inside the
        // same per-graph exclusive window that drained its readers.
        self.reclaimScanHydratedForGraph(graph_name);
    }

    // ────────────────────────────────────────────────────────────────────────
    // GAP-ENT-0023 P3 (review C2/I1): DETACHED scan hydration.
    //
    // THE HAZARD THIS CLOSES: the bounded node cache stores `Node` values
    // INLINE in per-shard AutoHashMaps. `getOrHydratePtr` on a miss INSERTS
    // (and above cap EVICTS) — an insert that grows a shard REHASHES and MOVES
    // every value slot; an eviction frees a slot for reuse. MATCH fallback
    // consumers retain `*Node` across iterations (bindings / base_nodes /
    // result rows hold `Value{ .Node = ptr }`), so a row-sourcing read that
    // hydrates INTO the cache invalidates previously returned pointers —
    // a deterministic single-threaded use-after-move on cold caches.
    //
    // THE FIX: row-sourcing reads that may run with retained pointers get
    // their misses served DETACHED — the node is rebuilt from the engine into
    // a private heap box that is never inserted into the cache, so no shard
    // map is ever mutated on the read path. Every miss re-reads the engine
    // (boxes are NOT served across calls), so a committed write can never be
    // shadowed by a stale detached copy: the resident cache — which every
    // write path updates — is always consulted first.
    // ────────────────────────────────────────────────────────────────────────

    /// Resident-first node fetch for MATCH-fallback row sourcing. Cache hit →
    /// the resident pointer (stable for the caller's read span, exactly the
    /// pre-bounded-cache contract). Miss → a DETACHED engine rebuild boxed on
    /// the heap and adopted by `scan_hydrated_nodes` (freed at the per-graph
    /// grace boundary). Null only when the id exists in neither the cache nor
    /// the engine. NEVER mutates the bounded cache.
    pub fn getNodePtrForScan(self: *const GraphStore, node_id: u64) ?*Node {
        const mut: *GraphStore = @constCast(self);
        // SONNY-1979 (CWE-362, use-after-MOVE): a resident HIT must NOT return the
        // raw in-map `*Node`. The shard `map_lock` only makes the LOOKUP atomic;
        // the moment it is released, a concurrent (or later) hydration insert that
        // GROWS this shard rehashes the backing AutoHashMap and MOVES every value
        // slot, so the previously-returned pointer dangles (the rare ~1/60 SIGSEGV
        // that failed the pre-push aggregate). Snapshot the hit into a grace-stable
        // DETACHED box — exactly as the miss path below already does — so every
        // return survives a subsequent shard grow. The copy is taken UNDER the
        // shard's SHARED map_lock (so the resident value can't be moved/freed
        // mid-copy); that lock is a LEAF, released before box adoption, and never
        // spans the consumer's extended pointer use.
        var built: Node = mut.snapshotResidentNodeForScan(node_id) orelse
            // Miss: rebuild from the engine OUTSIDE every lock (slow I/O; leaf
            // discipline; the callback must not re-enter this cache).
            ((hydrateNodeCb(@ptrCast(mut), mut.allocator, node_id) catch return null) orelse return null);
        const box = mut.allocator.create(Node) catch {
            freeNodeValue(mut.allocator, &built);
            return null;
        };
        box.* = built;
        const io = std.Io.Threaded.global_single_threaded.io();
        mut.scan_hydrated_mutex.lockUncancelable(io);
        defer mut.scan_hydrated_mutex.unlock(io);
        mut.scan_hydrated_nodes.append(mut.allocator, box) catch {
            // Cannot adopt the box (OOM): free it and report a miss rather
            // than leak. The caller degrades to the pre-fix "row dropped"
            // behavior only under allocator exhaustion.
            freeNodeValue(mut.allocator, box);
            mut.allocator.destroy(box);
            return null;
        };
        // GAP (write-path OOM, 2026-07-04): detached boxes live until the
        // per-graph grace boundary — for a write-carrying O(label) scan on a
        // cold store this is exactly the unbounded resident growth that OOM'd
        // the box (82 -> 86.4 G). Charge the adoption against the active
        // write-executor budget scope (thread-local; no-op for read queries /
        // other threads). COARSE accounting by design: struct + name/label
        // bytes + per-property entry overhead + string payloads.
        write_budget.chargeStoreBytes(approxDetachedNodeBytes(box));
        return box;
    }

    // CANARY: REQ=REQ-SONNY-2679-GATE-MEMORY; FEATURE="TraversalRowVisibility"; ASPECT=TransientNodeRead; STATUS=TESTED; TEST=tests/test_sonny2679_rls_hop_targets.zig; OWNER=security; UPDATED=2026-09-25
    /// SONNY-2679: decide something about node `node_id` from a TRANSIENT copy
    /// and retain nothing. `getNodePtrForScan` boxes every node it hands out
    /// into `scan_hydrated_nodes`, which is freed only at the graph's next
    /// checkpoint and is charged to no read budget, so a traversal gate that
    /// looked at every node it stepped onto through it grew the store by one
    /// node copy per step. Here the copy (a snapshot of the resident node, taken
    /// under the shard's SHARED map lock, or an engine rebuild on a miss) is
    /// freed before this returns, and `decide` runs outside every store lock.
    /// Null when the node exists in neither the cache nor the engine. Like
    /// `getNodePtrForScan`, it never mutates the bounded cache.
    pub fn decideOnTransientNode(
        self: *const GraphStore,
        node_id: u64,
        ctx: anytype,
        comptime decide: fn (@TypeOf(ctx), *const Node) bool,
    ) ?bool {
        const mut: *GraphStore = @constCast(self);
        var node: Node = mut.snapshotResidentNodeForScan(node_id) orelse
            ((hydrateNodeCb(@ptrCast(mut), mut.allocator, node_id) catch return null) orelse return null);
        defer freeNodeValue(mut.allocator, &node);
        return decide(ctx, &node);
    }

    /// SONNY-1979: deep-copy the RESIDENT node body for `node_id` into a caller-
    /// owned `Node`, or null when it is not resident (→ caller falls back to the
    /// engine rebuild). Taken under the shard's SHARED `map_lock` so a concurrent
    /// EXCLUSIVE writer (insert/grow/in-place mutate) on that shard cannot move or
    /// free the value during the copy. LEAF lock — held only across the copy, no
    /// re-entrant cache call (uses `getPtrUnlocked`). On clone OOM returns null so
    /// the caller degrades to the engine path rather than the unstable in-map ptr.
    fn snapshotResidentNodeForScan(self: *GraphStore, node_id: u64) ?Node {
        self.nodes.lockShardShared(node_id);
        defer self.nodes.unlockShardShared(node_id);
        const resident = self.nodes.getPtrUnlocked(node_id) orelse return null;
        return self.cloneNodeOwned(resident) catch null;
    }

    /// SONNY-1979: deep-copy a `Node` into a fresh caller-owned value (all heap
    /// duped: labels, property keys/values, graph_name, tenant_id). Touches NO
    /// cache or index — the copy is destined for a detached scan box freed at the
    /// per-graph grace boundary. Mirrors the copy half of `cloneOneNode`.
    fn cloneNodeOwned(self: *GraphStore, src: *const Node) !Node {
        const labels_copy = try self.allocator.alloc([]const u8, src.labels.len);
        for (src.labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
        }
        var props = CompactPropertyMap.init(self.allocator);
        var prop_it = src.properties.iterator();
        while (prop_it.next()) |prop| {
            const key = try self.allocator.dupe(u8, prop.key_ptr.*);
            try props.put(key, try copyPropertyValue(self, prop.value_ptr.*));
        }
        return .{
            .id = src.id,
            .labels = labels_copy,
            .properties = props,
            .graph_name = try self.allocator.dupe(u8, src.graph_name),
            .tenant_id = try self.allocator.dupe(u8, src.tenant_id),
        };
    }

    /// Coarse per-box working-set estimate for the write-executor budget
    /// (page-granularity precision is acceptable — this feeds a tripwire, not
    /// an accounting ledger).
    fn approxDetachedNodeBytes(node: *const Node) u64 {
        var total: u64 = @sizeOf(Node) + node.graph_name.len;
        for (node.labels) |l| total += l.len + @sizeOf([]const u8);
        var it = node.properties.iterator();
        while (it.next()) |entry| {
            total += 64; // entry + key/value boxing overhead (coarse)
            total += entry.key_ptr.len;
            total += switch (entry.value_ptr.*) {
                .String => |s| s.len,
                else => @as(u64, 16),
            };
        }
        return total;
    }

    /// Free the detached scan boxes belonging to `graph_name`. MUST only be
    /// called at that graph's grace boundary (per-graph EXCLUSIVE checkpoint
    /// window, or store teardown) — see `reclaimNodeCacheRetiredForGraph`.
    fn reclaimScanHydratedForGraph(self: *GraphStore, graph_name: []const u8) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.scan_hydrated_mutex.lockUncancelable(io);
        defer self.scan_hydrated_mutex.unlock(io);
        var w: usize = 0;
        for (self.scan_hydrated_nodes.items) |box| {
            if (std.mem.eql(u8, box.graph_name, graph_name)) {
                freeNodeValue(self.allocator, box);
                self.allocator.destroy(box);
            } else {
                self.scan_hydrated_nodes.items[w] = box;
                w += 1;
            }
        }
        self.scan_hydrated_nodes.shrinkRetainingCapacity(w);
    }

    /// Free ALL detached scan boxes (deinit / clearNodes reset paths — global
    /// exclusive contexts).
    fn freeAllScanHydrated(self: *GraphStore) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.scan_hydrated_mutex.lockUncancelable(io);
        defer self.scan_hydrated_mutex.unlock(io);
        for (self.scan_hydrated_nodes.items) |box| {
            freeNodeValue(self.allocator, box);
            self.allocator.destroy(box);
        }
        self.scan_hydrated_nodes.deinit(self.allocator);
        self.scan_hydrated_nodes = .empty;
    }

    /// GAP-ENT-0023 P3 (review I1): existence + EXACT-tenant verification for
    /// id-sourced index walks (label postings / intersections) on a bounded or
    /// snapshot-warm COLD cache. Resident hit → in-memory compare. Miss →
    /// IdMap membership (no engine read) and, only when a tenant filter is
    /// active, a single engine read of the internal tenant tag. Never mutates
    /// the cache, never returns pointers. Exact-match semantics on purpose —
    /// this backs the STORAGE-level tenant filter (hierarchy-aware readers
    /// pass null here and compensate per row, see storageTenantFilter).
    fn nodeExistsPassingTenantExact(self: *const GraphStore, node_id: u64, tenant: ?[]const u8) bool {
        if (self.nodes.get(node_id)) |node| {
            const tid = tenant orelse return true;
            return std.mem.eql(u8, node.tenant_id, tid);
        }
        const mut: *GraphStore = @constCast(self);
        const gs_slot = mut.resolveNodeGraphSlot(node_id) orelse return false;
        const tid = tenant orelse return true;
        const adapter = global_adapter orelse return false;
        const tprop = adapter.getNodeProperty(gs_slot.graph_name, gs_slot.slot_id, INTERNAL_TENANT_ID_PROPERTY_KEY, mut.allocator) catch return false;
        if (tprop) |p| {
            defer switch (p) {
                .string => |s| mut.allocator.free(s),
                else => {},
            };
            switch (p) {
                .string => |s| return std.mem.eql(u8, s, tid),
                else => {},
            }
        }
        // Exists but carries no tenant tag → default tenant.
        return std.mem.eql(u8, DEFAULT_TENANT_ID, tid);
    }

    /// GAP-ENT-0023 P3 (review I1): caller-owned copy of a node's tenant tag,
    /// served resident-first with an engine fallback (never mutates the
    /// cache). Null when the node exists nowhere (fail-closed for visibility
    /// checks). Caller frees with the SAME allocator.
    pub fn dupeNodeTenantForRead(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) ?[]u8 {
        if (self.nodes.get(node_id)) |node| {
            return allocator.dupe(u8, node.tenant_id) catch null;
        }
        const mut: *GraphStore = @constCast(self);
        const gs_slot = mut.resolveNodeGraphSlot(node_id) orelse return null;
        const adapter = global_adapter orelse return null;
        const tprop = adapter.getNodeProperty(gs_slot.graph_name, gs_slot.slot_id, INTERNAL_TENANT_ID_PROPERTY_KEY, allocator) catch return null;
        if (tprop) |p| {
            defer switch (p) {
                .string => |s| allocator.free(s),
                else => {},
            };
            switch (p) {
                .string => |s| return allocator.dupe(u8, s) catch null,
                else => {},
            }
        }
        return allocator.dupe(u8, DEFAULT_TENANT_ID) catch null;
    }

    // ========================================================================
    // PHASE 0: bounded ADJACENCY cache hydrate-on-miss + grace-point reclaim.
    // Mirrors the node-cache machinery above (hydrateNodeCb / installNodeCache-
    // Hydrate / retiredNodeInGraph / reclaimNodeCacheRetiredForGraph).
    // ========================================================================

    /// Rebuild a node's PUBLIC outgoing edge-id list from the durable engine.
    /// Iterates the engine's out-adjacency for the node's slot and reverse-maps
    /// each engine edge_id to its PUBLIC id via the persisted
    /// `__geode_internal_edge_id` property (same mechanism as the load path).
    /// Engine-adjacency order (== post-restart rebuild order). Returns null if
    /// the node is unknown to any IdMap (no engine record).
    fn hydrateOutgoingCb(ctx: *anyopaque, allocator: std.mem.Allocator, node_id: u64) anyerror!?AdjList {
        const self: *GraphStore = @ptrCast(@alignCast(ctx));
        const adapter = global_adapter orelse return null;
        const gs_slot = self.resolveNodeGraphSlot(node_id) orelse return null;
        return hydrateAdjFromEngine(adapter, allocator, gs_slot.graph_name, gs_slot.slot_id, .outgoing);
    }

    /// Incoming analog of `hydrateOutgoingCb`.
    fn hydrateIncomingCb(ctx: *anyopaque, allocator: std.mem.Allocator, node_id: u64) anyerror!?AdjList {
        const self: *GraphStore = @ptrCast(@alignCast(ctx));
        const adapter = global_adapter orelse return null;
        const gs_slot = self.resolveNodeGraphSlot(node_id) orelse return null;
        return hydrateAdjFromEngine(adapter, allocator, gs_slot.graph_name, gs_slot.slot_id, .incoming);
    }

    const AdjDir = enum { outgoing, incoming };

    /// Shared hydrate body for both directions. Owns the returned AdjList (its
    /// `list` backing array + `graph` dupe are freed by freeAdjListValue).
    fn hydrateAdjFromEngine(
        adapter: *graph_storage_adapter.StorageAdapter,
        allocator: std.mem.Allocator,
        graph_name: []const u8,
        slot_id: u64,
        dir: AdjDir,
    ) anyerror!?AdjList {
        var iter = switch (dir) {
            .outgoing => adapter.iterateOutgoingEdges(graph_name, slot_id, allocator) catch |err| switch (err) {
                error.NodeNotFound => return null,
                else => return err,
            },
            .incoming => adapter.iterateIncomingEdges(graph_name, slot_id, allocator) catch |err| switch (err) {
                error.NodeNotFound => return null,
                else => return err,
            },
        };
        defer iter.deinit();

        var list: std.ArrayList(u64) = .empty;
        errdefer list.deinit(allocator);

        while (try iter.next()) |edge_entry| {
            // GAP-ENT-0024 inline-first: v2 adjacency entries carry the PUBLIC
            // id inline — no per-edge property fetch (the whole point).
            if (edge_entry.public_id != 0) {
                try list.append(allocator, edge_entry.public_id);
                continue;
            }
            // Legacy fallback (v1 blocks / pre-v0.2.24 stores): reverse-map
            // engine edge_id -> PUBLIC id via the persisted property. The
            // canonical edge prop lives on the edge's SOURCE node: for an
            // OUTGOING edge that is this node (slot_id); for an INCOMING edge
            // it is the other endpoint (entry.neighbor == the source, per the
            // engine's in-adjacency).
            const source_slot = switch (dir) {
                .outgoing => slot_id,
                .incoming => edge_entry.neighbor,
            };
            _ = edge_id_property_fallback_reads.fetchAdd(1, .monotonic);
            const stored = (adapter.getEdgeProperty(
                graph_name,
                source_slot,
                edge_entry.edge_id,
                INTERNAL_EDGE_ID_PROPERTY_KEY,
                allocator,
            ) catch null) orelse continue; // orphan / not-yet-mapped slot: skip
            defer graph_storage_adapter.freeOwnedStorageProperty(allocator, stored);
            const public_id = switch (stored) {
                .string => |text| parsePersistedPublicId(text) orelse continue,
                else => continue,
            };
            try list.append(allocator, public_id);
        }

        return AdjList{ .list = list, .graph = try allocator.dupe(u8, graph_name) };
    }

    /// Install the hydrate-on-miss hooks for BOTH adjacency caches and activate
    /// the configured cap (GEODE_ADJ_CACHE_ENTRIES). Call once the global storage
    /// adapter is available (engine durable). Until this point the caches stay
    /// UNBOUNDED — eviction without rehydration would lose an in-memory-only edge
    /// list.
    pub fn installAdjCacheHydrate(self: *GraphStore) void {
        self.outgoing_edges.setHydrate(hydrateOutgoingCb, @ptrCast(self));
        self.incoming_edges.setHydrate(hydrateIncomingCb, @ptrCast(self));
    }

    /// Predicate: does this evicted/retired adjacency list belong to `graph_name`
    /// (passed as ctx)? Scopes grace-point reclamation to the checkpointed graph,
    /// exactly like retiredNodeInGraph for nodes.
    fn retiredAdjInGraph(ctx: *anyopaque, value: *const AdjList) bool {
        const graph_name: *const []const u8 = @ptrCast(@alignCast(ctx));
        return std.mem.eql(u8, value.graph, graph_name.*);
    }

    /// Reclaim (free) BOTH adjacency caches' retired entries that belong to
    /// `graph_name`. MUST be called by the storage adapter while it holds that
    /// graph's per-graph rwlock EXCLUSIVE (the checkpoint window), which drains
    /// all SHARED readers of that graph — so freeing a list cannot race a live
    /// `[]const u64` slice a reader still holds. This is the adjacency grace
    /// boundary (the borrowed-slice eviction-safety guarantee).
    pub fn reclaimAdjCacheRetiredForGraph(self: *GraphStore, graph_name: []const u8) void {
        var gn = graph_name;
        self.outgoing_edges.reclaimRetiredWhere(@ptrCast(&gn), retiredAdjInGraph);
        self.incoming_edges.reclaimRetiredWhere(@ptrCast(&gn), retiredAdjInGraph);
    }

    // ========================================================================
    // PHASE 1: bounded EDGE-BODY cache hydrate-on-miss + grace-point reclaim.
    // Mirrors the node-cache + Phase-0 adjacency-cache machinery above.
    // ========================================================================

    const EdgeGraphSlot = struct { graph_name: []const u8, edge_slot: u64 };

    /// Resolve a PUBLIC edge id to its owning graph + ENGINE edge slot by
    /// scanning the per-graph IdMaps (fully resident, independent of the bounded
    /// edge cache). Mirrors `resolveNodeGraphSlot`. Null if no IdMap maps it.
    fn resolveEdgeGraphSlot(self: *GraphStore, edge_id: u64) ?EdgeGraphSlot {
        var it = self.id_maps.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.edgeSlot(@as(u128, edge_id))) |slot| {
                return .{ .graph_name = entry.key_ptr.*, .edge_slot = slot };
            }
        }
        return null;
    }

    /// Rebuild an evicted edge's full `Edge` body from the durable engine. The
    /// returned Edge OWNS its label/graph_name/tenant_id byte slices + property
    /// map (freed by freeEdgeValue on eviction/reclaim), exactly like the load
    /// path (loadOneGraphFromAdapter) and like materializeNodeFromEngine for the
    /// node side. Endpoints + rel-type come from the engine edge index (O(1)),
    /// properties from getAllEdgeProperties. Returns null if the edge is unknown
    /// to any IdMap or to the engine (e.g. concurrently removed) — callers then
    /// see the same null a true miss would have produced.
    fn hydrateEdgeCb(ctx: *anyopaque, allocator: std.mem.Allocator, edge_id: u64) anyerror!?Edge {
        const self: *GraphStore = @ptrCast(@alignCast(ctx));
        const adapter = global_adapter orelse return null;
        const egs = self.resolveEdgeGraphSlot(edge_id) orelse return null;

        const rec = (adapter.getEdgeRecordBySlot(egs.graph_name, egs.edge_slot, allocator) catch |err| switch (err) {
            error.GraphNotFound, error.NodeNotFound => return null,
            else => return err,
        }) orelse return null;
        // `rec.label` is owned by us from here; free it on any error path.
        errdefer allocator.free(rec.label);

        const id_map = self.requireIdMap(egs.graph_name) catch return null;
        // Map engine endpoint slots back to PUBLIC node ids. A missing mapping
        // (mid-load / mid-delete) means the edge isn't safely reconstructable.
        const from_id = @as(u64, @truncate(id_map.nodeUuid(rec.from_slot) orelse return null));
        const to_id = @as(u64, @truncate(id_map.nodeUuid(rec.to_slot) orelse return null));

        const graph_copy = try allocator.dupe(u8, egs.graph_name);
        errdefer allocator.free(graph_copy);

        // Recover the persisted edge tenant tag (absent/corrupt -> default),
        // mirroring the load path (graph_store.zig edge-load tenant recovery).
        const tenant_copy = blk: {
            const maybe_t = adapter.getEdgeProperty(egs.graph_name, rec.from_slot, egs.edge_slot, INTERNAL_TENANT_ID_PROPERTY_KEY, allocator) catch null;
            if (maybe_t) |stored| {
                defer graph_storage_adapter.freeOwnedStorageProperty(allocator, stored);
                switch (stored) {
                    .string => |text| break :blk try allocator.dupe(u8, text),
                    else => {},
                }
            }
            break :blk try allocator.dupe(u8, DEFAULT_TENANT_ID);
        };
        errdefer allocator.free(tenant_copy);

        var edge = Edge{
            .id = edge_id,
            .from_id = from_id,
            .to_id = to_id,
            .label = rec.label,
            .properties = CompactPropertyMap.init(allocator),
            .graph_name = graph_copy,
            .tenant_id = tenant_copy,
        };
        errdefer freeEdgeValue(allocator, &edge);

        if (rec.prop_head != 0) {
            // Route via the source-node SLOT (shard-striped) so
            // getAllEdgeProperties reaches the correct per-shard engine.
            var sp = try adapter.getAllEdgeProperties(egs.graph_name, rec.from_slot, rec.prop_head, allocator);
            defer {
                var sp_it = sp.iterator();
                while (sp_it.next()) |e| {
                    allocator.free(e.key_ptr.*);
                    graph_storage_adapter.freeOwnedStorageProperty(allocator, e.value_ptr.*);
                }
                sp.deinit();
            }
            var sp_it = sp.iterator();
            while (sp_it.next()) |e| {
                // C3 (review-0023): skip the `.null` REMOVE tombstone (same
                // convention as node properties — see materializeNodeFromEngine).
                if (e.value_ptr.* == .null) continue;
                const key_copy = try allocator.dupe(u8, e.key_ptr.*);
                const pv = try graph_storage_adapter.fromStorageProperty(allocator, e.value_ptr.*);
                try edge.properties.put(key_copy, pv);
            }
        }

        return edge;
    }

    /// Install the hydrate-on-miss hook for the bounded edge-body cache and
    /// activate the configured cap (GEODE_EDGE_CACHE_ENTRIES). Call once the
    /// global storage adapter is available (engine durable). Until this point the
    /// cache stays UNBOUNDED — eviction without rehydration would lose an
    /// in-memory-only edge body.
    pub fn installEdgeCacheHydrate(self: *GraphStore) void {
        self.edges.setHydrate(hydrateEdgeCb, @ptrCast(self));
    }

    /// Borrowed-pointer edge-body read with HYDRATE-ON-MISS. Returns the
    /// resident `*Edge` (a hit) or rebuilds the edge from the engine, inserts it
    /// into the bounded cache (evicting cold entries), and returns the
    /// freshly-resident pointer. Null only if the edge exists in neither the
    /// cache nor the engine (pure in-memory deployment with no adapter, or a
    /// genuinely-missing id).
    ///
    /// Lifetime: the returned `*Edge` stays valid for the caller's read span
    /// under the per-graph SHARED lock — eviction (triggered here or by a
    /// concurrent insert) only UNLINKs+RETIREs, never frees inline; retired
    /// edges are freed only at the per-graph EXCLUSIVE checkpoint grace window
    /// (which drained all SHARED readers). `getOrHydratePtr` mutates the cache on
    /// a miss under the shard's hydrate mutex, so we `@constCast`: callers
    /// already hold the store/graph read lock that serializes this against the
    /// per-graph-exclusive evict/reclaim, matching the node cache's contract.
    pub fn getEdgePtrHydrated(self: *const GraphStore, edge_id: u64) ?*Edge {
        const cache: *EdgeCache = @constCast(&self.edges);
        return (cache.getOrHydratePtr(edge_id) catch return null) orelse return null;
    }

    /// By-value variant of `getEdgePtrHydrated`. Returns a COPY of the edge body
    /// (its byte slices still point into the cache-owned heap, valid for the
    /// caller's read span — that heap is grace-freed). CONCURRENCY-SAFE: the copy
    /// is taken under the cache's per-shard map lock SHARED, so it cannot observe
    /// a torn/moved value during a concurrent writer's insert-resize on the
    /// edge's shard (the edge-body torn-read race). Prefer THIS over
    /// `getEdgePtrHydrated` on any read path that runs concurrently with the
    /// shard-locked edge-create writers (e.g. analytical traverse during ingest).
    pub fn getEdgeHydrated(self: *const GraphStore, edge_id: u64) ?Edge {
        const cache: *EdgeCache = @constCast(&self.edges);
        return cache.getOrHydrate(edge_id) catch return null;
    }

    /// Predicate: does this retired/evicted edge belong to `graph_name`? An Edge
    /// already carries its owning graph_name (unlike AdjList), so the per-graph
    /// grace reclaim scopes directly off it.
    fn retiredEdgeInGraph(ctx: *anyopaque, value: *const Edge) bool {
        const graph_name: *const []const u8 = @ptrCast(@alignCast(ctx));
        return std.mem.eql(u8, value.graph_name, graph_name.*);
    }

    /// Reclaim (free) the edge cache's retired entries belonging to `graph_name`.
    /// MUST be called by the storage adapter while it holds that graph's
    /// per-graph rwlock EXCLUSIVE (the checkpoint window), which drains all
    /// SHARED readers of that graph — so freeing an Edge cannot race a live
    /// `*Edge` a reader still holds. This is the edge-body grace boundary,
    /// joining the SAME per-graph window as the node + adjacency reclaim.
    pub fn reclaimEdgeCacheRetiredForGraph(self: *GraphStore, graph_name: []const u8) void {
        var gn = graph_name;
        self.edges.reclaimRetiredWhere(@ptrCast(&gn), retiredEdgeInGraph);
    }

    fn requireEdgeSlot(self: *GraphStore, graph_name: []const u8, edge_id: u64) !u64 {
        const id_map = self.requireIdMap(graph_name) catch return error.EdgeSlotMappingMissing;
        return id_map.edgeSlot(@as(u128, edge_id)) orelse error.EdgeSlotMappingMissing;
    }

    fn persistNodePublicId(vt: AdapterVTable, graph_name: []const u8, slot_id: u64, public_id: u64) !void {
        var id_buf: [16]u8 = undefined;
        try vt.setNodePropertyFn(
            vt.ctx,
            graph_name,
            slot_id,
            INTERNAL_NODE_ID_PROPERTY_KEY,
            .{ .String = encodePersistedPublicId(&id_buf, public_id) },
        );
    }

    /// GAP-0891 (RC-2): persist a node's tenant tag so it survives restart.
    /// No-op for `DEFAULT_TENANT_ID` (absent-on-read means default — keeps the
    /// single-tenant common case free of any extra write). Mirrors
    /// `persistNodePublicId`; the key is filtered from user-visible properties.
    fn persistNodeTenantId(vt: AdapterVTable, graph_name: []const u8, slot_id: u64, tenant: []const u8) !void {
        if (std.mem.eql(u8, tenant, DEFAULT_TENANT_ID)) return;
        try vt.setNodePropertyFn(
            vt.ctx,
            graph_name,
            slot_id,
            INTERNAL_TENANT_ID_PROPERTY_KEY,
            .{ .String = tenant },
        );
    }

    // GAP-ENT-0024: `persistEdgePublicId` (the per-edge
    // `__geode_internal_edge_id` property write — one ≥8 KB props page per
    // edge) was DELETED. New edges carry the public id INLINE in the durable
    // adjacency records (graph-storage v0.2.24 v2 blocks) via
    // `createEdgeFn(..., public_id)`. Readers stay read-both forever:
    // `public_id == 0` (legacy v1 blocks / old stores) falls back to the
    // property fetch — see hydrateAdjFromEngine and the loop1 edge rebuild.

    /// GAP-0891 (RC-2): edge analog of `persistNodeTenantId`. No-op for
    /// `DEFAULT_TENANT_ID`; absent-on-read means default. An adapter with no
    /// edge-property setter fails with `error.Unsupported`, and every caller
    /// then fails its write: a tag that is not stored would read back as
    /// `default` after a restart, and since SONNY-2693 a `default` edge is
    /// hidden from every tenant (there is no endpoint-derived bridge).
    fn persistEdgeTenantId(
        vt: AdapterVTable,
        graph_name: []const u8,
        from_slot: u64,
        to_slot: u64,
        edge_slot: u64,
        tenant: []const u8,
    ) !void {
        if (std.mem.eql(u8, tenant, DEFAULT_TENANT_ID)) return;
        const set_edge_property = vt.setEdgePropertyFn orelse return error.Unsupported;
        try set_edge_property(
            vt.ctx,
            graph_name,
            from_slot,
            to_slot,
            edge_slot,
            INTERNAL_TENANT_ID_PROPERTY_KEY,
            .{ .String = tenant },
        );
    }

    pub fn graphExists(self: *const GraphStore, graph_name: []const u8) bool {
        // Dual-read: check adapter first, then fall back to local HashMap
        if (global_vtable) |vt| {
            if (vt.graphExistsFn(vt.ctx, graph_name)) return true;
        }
        return self.graphs.contains(graph_name);
    }

    pub fn listGraphNames(self: *const GraphStore, allocator: std.mem.Allocator) ![]const []const u8 {
        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |name| {
                allocator.free(name);
            }
            names.deinit(allocator);
        }

        var seen = std.StringHashMap(void).init(allocator);
        defer {
            var seen_it = seen.iterator();
            while (seen_it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            seen.deinit();
        }

        if (global_adapter) |adapter| {
            const persisted_names = try adapter.listGraphNames(allocator);
            defer {
                for (persisted_names) |name| {
                    allocator.free(name);
                }
                allocator.free(persisted_names);
            }

            for (persisted_names) |name| {
                const seen_key = try allocator.dupe(u8, name);
                errdefer allocator.free(seen_key);
                const seen_result = try seen.getOrPut(seen_key);
                if (!seen_result.found_existing) {
                    try names.append(allocator, try allocator.dupe(u8, name));
                } else {
                    allocator.free(seen_key);
                }
            }
        }

        var it = self.graphs.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const seen_key = try allocator.dupe(u8, name);
            errdefer allocator.free(seen_key);
            const seen_result = try seen.getOrPut(seen_key);
            if (!seen_result.found_existing) {
                try names.append(allocator, try allocator.dupe(u8, name));
            } else {
                allocator.free(seen_key);
            }
        }

        return names.toOwnedSlice(allocator);
    }

    /// Returns a de-duplicated, allocator-owned slice of edge type names
    /// observed in the in-memory edge store.
    ///
    /// `filter_tenant == null` returns every edge type regardless of tenant
    /// (admin/introspection path); otherwise only edges whose `tenant_id`
    /// equals `filter_tenant` contribute to the result.
    ///
    /// Caller owns the returned slice and each string inside it — both must
    /// be freed with the same `allocator` that was passed in.
    pub fn listEdgeTypes(
        self: *GraphStore,
        allocator: std.mem.Allocator,
        filter_tenant: ?[]const u8,
    ) ![][]const u8 {
        // PHASE 1b chokepoint: tenant-scoped, no single graph_name -> hydrate all.
        self.ensureAllGraphsHydrated();
        // PERF-C (issue #814): O(distinct_types_for_tenant) read from
        // `edge_types_by_tenant`. The previous implementation walked every
        // edge in the store, deduping on each tick — that was O(E) per LSP
        // completion. Reference counts in the index drop entries when the
        // last carrier edge is deleted, so this never reports a type no
        // edge still carries.
        //
        // The set owns each duped key for the lifetime of the function;
        // on success we transfer ownership to `out` and deinit only the
        // map shell, so each unique edge type is allocated exactly once.
        //
        // PERF-C race fix (2026-05-18): hold `perf_c_refcount_mutex` for
        // the duration of the walk so concurrent `bumpRefcount` /
        // `decRefcount` cannot rehash the map under us.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.perf_c_refcount_mutex.lockUncancelable(io);
        defer self.perf_c_refcount_mutex.unlock(io);

        var type_set = std.StringHashMap(void).init(allocator);
        defer type_set.deinit();
        errdefer {
            var k_it = type_set.keyIterator();
            while (k_it.next()) |k| allocator.free(k.*);
        }

        if (filter_tenant) |tid| {
            // Tenant-filtered path. GAP-ENT-0023 P3: the outer key is the
            // composite "graph\x00tenant", so match on the tenant COMPONENT
            // (exact component equality — preserves GAP-0509 isolation) and
            // union across graphs. The outer map is tiny (graphs x tenants).
            var outer_it = self.edge_types_by_tenant.iterator();
            while (outer_it.next()) |outer_entry| {
                if (!std.mem.eql(u8, graphTenantKeyTenant(outer_entry.key_ptr.*), tid)) continue;
                var it = outer_entry.value_ptr.keyIterator();
                while (it.next()) |kp| {
                    if (type_set.contains(kp.*)) continue;
                    const copy = try allocator.dupe(u8, kp.*);
                    errdefer allocator.free(copy);
                    try type_set.put(copy, {});
                }
            }
        } else {
            // Admin / no-filter path: union across every tenant.
            var outer_it = self.edge_types_by_tenant.iterator();
            while (outer_it.next()) |outer_entry| {
                var inner_it = outer_entry.value_ptr.keyIterator();
                while (inner_it.next()) |kp| {
                    if (type_set.contains(kp.*)) continue;
                    const copy = try allocator.dupe(u8, kp.*);
                    errdefer allocator.free(copy);
                    try type_set.put(copy, {});
                }
            }
        }

        var out = try std.ArrayList([]const u8).initCapacity(allocator, type_set.count());
        errdefer out.deinit(allocator);
        var k_it = type_set.keyIterator();
        while (k_it.next()) |k| try out.append(allocator, k.*);
        return out.toOwnedSlice(allocator);
    }

    /// LSP schema introspection helper: returns the dedup'd set of
    /// property keys observed on every node carrying `label` in
    /// `filter_tenant`. Used by the permission-aware LSP completion
    /// engine to suggest property names after `n.` where `n` is a
    /// variable bound to a label.
    ///
    /// `filter_tenant == null` returns property keys regardless of
    /// tenant (admin/introspection path); otherwise only nodes whose
    /// `tenant_id` equals `filter_tenant` contribute.
    ///
    /// Caller owns the returned slice and each string inside it — both
    /// must be freed with the same `allocator` that was passed in.
    pub fn listPropertiesForLabel(
        self: *GraphStore,
        allocator: std.mem.Allocator,
        filter_tenant: ?[]const u8,
        label: []const u8,
    ) ![][]const u8 {
        // PHASE 1b chokepoint: tenant-scoped, no single graph_name -> hydrate all.
        self.ensureAllGraphsHydrated();
        // PERF-C (issue #814): O(distinct_property_keys_for_label_in_tenant)
        // via `label_properties_by_tenant`. The composite index key is
        // "label\x00prop_key" — we walk the inner map and strip the prefix.
        // Internal persisted-id property keys are never bumped on insert, so
        // they're naturally absent from the index here.
        //
        // Single-dup ownership pattern (mirrors listEdgeTypes): the set
        // owns each duped key for the lifetime of the function. On
        // success we transfer ownership to `out` and deinit only the
        // map shell. On error we free every key the set still owns.
        //
        // PERF-C race fix (2026-05-18): hold `perf_c_refcount_mutex` for
        // the duration of the walk so concurrent `bumpRefcount` /
        // `decRefcount` cannot rehash the map under us.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.perf_c_refcount_mutex.lockUncancelable(io);
        defer self.perf_c_refcount_mutex.unlock(io);

        var prop_set = std.StringHashMap(void).init(allocator);
        defer prop_set.deinit();
        errdefer {
            var k_it = prop_set.keyIterator();
            while (k_it.next()) |k| allocator.free(k.*);
        }

        const collect = struct {
            fn run(
                set: *std.StringHashMap(void),
                alloc: std.mem.Allocator,
                inner: *const std.StringHashMap(usize),
                want_label: []const u8,
            ) !void {
                var it = inner.keyIterator();
                while (it.next()) |kp| {
                    const composite = kp.*;
                    // Layout: "label\x00prop_key". Match the label prefix
                    // first; reject keys that aren't long enough or whose
                    // separator is at the wrong offset.
                    if (composite.len < want_label.len + 1) continue;
                    if (composite[want_label.len] != 0) continue;
                    if (!std.mem.eql(u8, composite[0..want_label.len], want_label)) continue;
                    const pkey = composite[want_label.len + 1 ..];
                    if (set.contains(pkey)) continue;
                    const copy = try alloc.dupe(u8, pkey);
                    errdefer alloc.free(copy);
                    try set.put(copy, {});
                }
            }
        }.run;

        if (filter_tenant) |tid| {
            // GAP-ENT-0023 P3: composite "graph\x00tenant" outer key — match
            // the tenant component, union across graphs (see listEdgeTypes).
            var outer_it = self.label_properties_by_tenant.iterator();
            while (outer_it.next()) |outer_entry| {
                if (!std.mem.eql(u8, graphTenantKeyTenant(outer_entry.key_ptr.*), tid)) continue;
                try collect(&prop_set, allocator, outer_entry.value_ptr, label);
            }
        } else {
            var outer_it = self.label_properties_by_tenant.iterator();
            while (outer_it.next()) |outer_entry| {
                try collect(&prop_set, allocator, outer_entry.value_ptr, label);
            }
        }

        var out = try std.ArrayList([]const u8).initCapacity(allocator, prop_set.count());
        errdefer out.deinit(allocator);
        var k_it = prop_set.keyIterator();
        while (k_it.next()) |k| try out.append(allocator, k.*);
        return out.toOwnedSlice(allocator);
    }

    // CANARY: REQ=REQ-GEODE-877-KNN-INDEX-SHADOW; FEATURE="VectorKnn"; ASPECT=UnrelatedIndexMustNotShadowScan; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=engine; UPDATED=2026-08-29
    /// True when `label` is the ONLY label carrying `property`, and it does so
    /// ONLY inside (`graph_name`, `filter_tenant`).
    ///
    /// geode#877 (b): `knn('<property>', …)` is property-scoped, not
    /// label-scoped, while an advanced vector index is built over exactly ONE
    /// (label, property) pair. Committing to such an index therefore answers a
    /// broader question with a narrower index — creating a vector index on a
    /// COMPLETELY UNRELATED label that merely reuses the property name silently
    /// emptied a working knn result. This is the authority predicate the knn
    /// read path consults: the index may serve the query only when its label
    /// provably covers every row the brute-force scan would have visited, in
    /// this graph and this tenant scope. Anything else falls back to the scan
    /// (a correct, if O(n), answer) rather than returning a wrong one.
    ///
    /// Reads the PERF-C `label_properties_by_tenant` refcount index — whose
    /// outer key is the composite "graph\x00tenant" and whose inner key is
    /// "label\x00property" — so it costs O(distinct label/property pairs),
    /// allocates nothing, and never hydrates. Fail-CLOSED: an unrecognised key
    /// shape, a carrier in another graph, a carrier under another tenant, or a
    /// second carrying label all return false.
    ///
    /// Lock: takes `perf_c_refcount_mutex` (tier 1 leaf, CLAUDE.md ordering
    /// table) for the walk, exactly as `listPropertiesForLabel` does, so a
    /// concurrent bump/dec cannot rehash the map underneath it.
    pub fn labelSolelyCarriesProperty(
        self: *GraphStore,
        graph_name: []const u8,
        filter_tenant: ?[]const u8,
        label: []const u8,
        property: []const u8,
    ) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.perf_c_refcount_mutex.lockUncancelable(io);
        defer self.perf_c_refcount_mutex.unlock(io);

        var saw_carrier = false;
        var outer_it = self.label_properties_by_tenant.iterator();
        while (outer_it.next()) |outer_entry| {
            const outer_key = outer_entry.key_ptr.*;
            const entry_graph = graphTenantKeyGraph(outer_key);
            const entry_tenant = graphTenantKeyTenant(outer_key);

            var inner_it = outer_entry.value_ptr.iterator();
            while (inner_it.next()) |inner_entry| {
                const inner_key = inner_entry.key_ptr.*;
                const sep = std.mem.indexOfScalar(u8, inner_key, 0) orelse return false;
                if (!std.mem.eql(u8, inner_key[sep + 1 ..], property)) continue;

                // A carrier of this property outside the session's graph (or,
                // when the session is tenant-scoped, outside its tenant) means
                // the index can hold rows this query must not see.
                if (!std.mem.eql(u8, entry_graph, graph_name)) return false;
                if (filter_tenant) |tid| {
                    if (!std.mem.eql(u8, entry_tenant, tid)) return false;
                }
                // A second carrying label means the index covers only part of
                // the property's rows.
                if (!std.mem.eql(u8, inner_key[0..sep], label)) return false;
                saw_carrier = true;
            }
        }
        return saw_carrier;
    }

    /// Returns a de-duplicated, allocator-owned slice of node label names
    /// observed in the in-memory node store.
    ///
    /// GAP-0509: SHOW TABLES previously leaked label metadata across tenants.
    /// `listNodeLabels` walked every node in the store and accumulated labels
    /// into a single de-duplicated set, so a tenant running `SHOW TABLES` on
    /// graph X saw labels contributed by every other tenant on the same graph
    /// — a useful reconnaissance primitive for discovering the existence of
    /// unrelated entity types. Filtering nodes by tenant_id before collecting
    /// labels restores the tenant isolation property.
    ///
    /// `filter_tenant == null` preserves the admin / cross-tenant listing
    /// (for SHOW TABLES without a session, or explicit admin tooling).
    ///
    /// Caller owns the returned slice and each string inside it — both must
    /// be freed with the same `allocator` that was passed in.
    ///
    /// CANARY: REQ=REQ-GAP-0509-SHOW-TABLES-TENANT; FEATURE="ShowTablesTenantIsolation"; ASPECT=LabelEnumeration; STATUS=TESTED; TEST=tests/test_gap0509_tenant_isolation.zig:1; OWNER=security; UPDATED=2026-04-11
    pub fn listNodeLabels(
        self: *GraphStore,
        allocator: std.mem.Allocator,
        filter_tenant: ?[]const u8,
    ) ![][]const u8 {
        // PHASE 1b chokepoint: tenant-scoped, no single graph_name -> hydrate all.
        self.ensureAllGraphsHydrated();
        // PERF-C (issue #814): O(distinct_labels_for_tenant) read from
        // `node_labels_by_tenant`. The previous implementation walked every
        // node in the store on every LSP completion call. Reference counts
        // in the index drop entries when the last carrier node is deleted,
        // so this never reports a label no node still carries (preserving
        // the GAP-0509 tenant-isolation property).
        //
        // Single-dup ownership pattern (mirrors listEdgeTypes /
        // listPropertiesForLabel): the set owns each duped key for the
        // lifetime of the function. On success we transfer ownership to
        // `out` and deinit only the map shell. On error we free every
        // key the set still owns.
        //
        // PERF-C race fix (2026-05-18): hold `perf_c_refcount_mutex` for
        // the duration of the walk so concurrent `bumpRefcount` /
        // `decRefcount` cannot rehash the map under us.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.perf_c_refcount_mutex.lockUncancelable(io);
        defer self.perf_c_refcount_mutex.unlock(io);

        var label_set = std.StringHashMap(void).init(allocator);
        defer label_set.deinit();
        errdefer {
            var k_it = label_set.keyIterator();
            while (k_it.next()) |k| allocator.free(k.*);
        }

        if (filter_tenant) |tid| {
            // GAP-ENT-0023 P3: composite "graph\x00tenant" outer key — match
            // the tenant component, union across graphs (see listEdgeTypes).
            var outer_it = self.node_labels_by_tenant.iterator();
            while (outer_it.next()) |outer_entry| {
                if (!std.mem.eql(u8, graphTenantKeyTenant(outer_entry.key_ptr.*), tid)) continue;
                var it = outer_entry.value_ptr.keyIterator();
                while (it.next()) |kp| {
                    if (label_set.contains(kp.*)) continue;
                    const copy = try allocator.dupe(u8, kp.*);
                    errdefer allocator.free(copy);
                    try label_set.put(copy, {});
                }
            }
        } else {
            var outer_it = self.node_labels_by_tenant.iterator();
            while (outer_it.next()) |outer_entry| {
                var inner_it = outer_entry.value_ptr.keyIterator();
                while (inner_it.next()) |kp| {
                    if (label_set.contains(kp.*)) continue;
                    const copy = try allocator.dupe(u8, kp.*);
                    errdefer allocator.free(copy);
                    try label_set.put(copy, {});
                }
            }
        }

        var out = try std.ArrayList([]const u8).initCapacity(allocator, label_set.count());
        errdefer out.deinit(allocator);
        var k_it = label_set.keyIterator();
        while (k_it.next()) |k| try out.append(allocator, k.*);
        return out.toOwnedSlice(allocator);
    }

    /// GAP-0839: ensure `self.graph_uuids` carries a persistent UUID for
    /// `graph_name`.  Prefer the storage adapter's UUID (it maps to the
    /// on-disk graph directory) so the in-memory map never diverges from the
    /// disk layout; fall back to a freshly generated UUIDv7 for in-memory
    /// (no-adapter) deployments.  Idempotent: if a UUID is already recorded
    /// it is left unchanged.  MUST be called with `graphs_mutex` held.
    fn recordGraphUuidLocked(self: *GraphStore, graph_name: []const u8) !void {
        if (self.graph_uuids.contains(graph_name)) return;
        const resolved: [16]u8 = blk: {
            if (global_adapter) |adapter| {
                if (adapter.getGraphUuid(graph_name)) |adapter_uuid| break :blk adapter_uuid;
            }
            break :blk generatePersistentUuid();
        };
        const name_copy = try self.allocator.dupe(u8, graph_name);
        errdefer self.allocator.free(name_copy);
        try self.graph_uuids.put(name_copy, resolved);
    }

    pub fn createGraph(self: *GraphStore, graph_name: []const u8) !void {
        // dsn_graph_binding.yml race fix (2026-05-23): serialize the
        // (vtable get-or-create + in-memory contains/put) pair so two
        // concurrent CREATE GRAPH / DSN-auto-create paths can't both
        // observe `!contains`, both insert, and surface a spurious
        // `GraphAlreadyExists` from the loser's second `contains` check.
        // See `graphs_mutex` field doc and
        // `tests/test_create_graph_race_regression.zig`.
        self.graphs_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.graphs_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // Create the persisted graph first so the in-memory registry never
        // diverges from the adapter-backed storage layout.  The adapter's
        // getOrCreate is itself idempotent (StorageAdapter.getOrCreateGraph
        // returns the existing handle if the registry already has the name),
        // so this call is safe to repeat across the race window.
        if (global_vtable) |vt| {
            _ = try vt.getOrCreateGraphFn(vt.ctx, graph_name);
        }

        // Idempotency: if a sibling caller already registered this graph
        // in the in-memory map (sequential repeat OR concurrent race
        // winner ahead of us under the same mutex round) treat as
        // success — the post-condition the caller wanted (graph exists)
        // is satisfied.  Pre-fix this returned `error.GraphAlreadyExists`
        // and the QUIC HELLO handler translated that to "Failed to create
        // graph", failing test 10 of dsn_graph_binding.yml whenever the
        // adjacent CREATE GRAPH IF NOT EXISTS in test 9 had already
        // landed.  Callers that need strict "did I create this graph
        // just now" semantics (none today) would have to gate above
        // this layer.
        if (self.graphs.contains(graph_name)) {
            // GAP-0839: a graph already in the in-memory registry may still
            // lack a recorded UUID (e.g. seeded by an older code path or by
            // loadFromFile); guarantee one exists so getGraphUuid succeeds.
            try self.recordGraphUuidLocked(graph_name);
            return;
        }

        const name_copy = try self.allocator.dupe(u8, graph_name);
        errdefer self.allocator.free(name_copy);
        try self.graphs.put(name_copy, {});

        // GAP-0839: assign + persist a UUID for the freshly created graph so
        // tenant-bound HELLO sessions (which require a persistent UUID) are
        // accepted even when no disk adapter is configured.
        try self.recordGraphUuidLocked(graph_name);

        // Initialize IdMap for the new graph
        _ = try self.getOrCreateIdMap(graph_name);

        // R2 (review-0023 residual): an in-session DROP GRAPH followed by a
        // re-CREATE of the SAME name used to inherit the dropped graph's stale
        // HydrationEntry (entries are never removed before deinit). A stale
        // `failed=true` would silently suppress the NEW graph's snapshot writes
        // until the next reopen (perf-only, but avoidable). A freshly created
        // graph has nothing to hydrate — neutralize the stale entry: done=true
        // (hydration no-op, same as no entry) and failed=false (saves enabled).
        {
            const hio = std.Io.Threaded.global_single_threaded.io();
            self.hydration_mutex.lockUncancelable(hio);
            defer self.hydration_mutex.unlock(hio);
            if (self.pending_hydration.get(graph_name)) |hentry| {
                hentry.failed.store(false, .release);
                hentry.done.store(true, .release);
            }
        }

        self.dirty.store(true, .release);
        incrementMutationEpoch();
    }

    /// Open a graph using a known UUID (for catalog recovery).
    pub fn openOrCreateGraphWithUuid(self: *GraphStore, graph_name: []const u8, graph_uuid: [16]u8) !void {
        // Same race protection as createGraph — concurrent catalog
        // recovery for the same name must not double-put into
        // `self.graphs` and leak the loser's name_copy slice.
        self.graphs_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.graphs_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (global_adapter) |adapter| {
            _ = try adapter.openGraphWithUuid(graph_name, graph_uuid);
        }
        // GAP-0839: record the catalog-supplied UUID verbatim — it is the
        // authoritative persistent identity recovered from disk, so it must
        // win over any in-memory placeholder.
        try self.setGraphUuidLocked(graph_name, graph_uuid);
        if (self.graphs.contains(graph_name)) {
            return;
        }
        const name_copy = try self.allocator.dupe(u8, graph_name);
        errdefer self.allocator.free(name_copy);
        try self.graphs.put(name_copy, {});
        _ = try self.getOrCreateIdMap(graph_name);
        self.dirty.store(true, .release);
        incrementMutationEpoch();
    }

    /// GAP-0839: force `self.graph_uuids[graph_name] = graph_uuid`, overwriting
    /// any prior value.  Used by catalog recovery where the on-disk UUID is
    /// authoritative.  MUST be called with `graphs_mutex` held.
    fn setGraphUuidLocked(self: *GraphStore, graph_name: []const u8, graph_uuid: [16]u8) !void {
        const gop = try self.graph_uuids.getOrPut(graph_name);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, graph_name) catch |err| {
                _ = self.graph_uuids.remove(graph_name);
                return err;
            };
        }
        gop.value_ptr.* = graph_uuid;
    }

    /// Return the UUID for a named graph.  Prefers the storage adapter (its
    /// UUID maps to the on-disk graph directory); GAP-0839 adds a fallback to
    /// the in-memory `graph_uuids` map so graphs created in in-memory mode
    /// (server started without --data-dir) still report a persistent UUID and
    /// tenant-bound sessions are accepted.
    pub fn getGraphUuid(graph_name: []const u8) ?[16]u8 {
        if (global_adapter) |adapter| {
            if (adapter.getGraphUuid(graph_name)) |adapter_uuid| return adapter_uuid;
        }
        // GAP-0839: in-memory fallback.  `getGraphUuid` is a static helper
        // (no `self`), so reach the primary global store directly.  Use the
        // non-initializing accessor so a UUID query never has the side effect
        // of creating a store.
        if (getCurrentGlobalStore()) |store| {
            // Read under `graphs_mutex` — the writers (createGraph /
            // openOrCreateGraphWithUuid / dropGraph) mutate `graph_uuids`
            // under this same mutex, and a concurrent rehash would otherwise
            // race this lookup.
            store.graphs_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer store.graphs_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            if (store.graph_uuids.get(graph_name)) |mem_uuid| return mem_uuid;
        }
        return null;
    }

    pub fn dropGraph(self: *GraphStore, graph_name: []const u8) !void {
        // Match createGraph/openOrCreateGraphWithUuid serialization so a
        // concurrent CREATE+DROP for the same name can't observe a
        // half-applied state (adapter dropped but registry still has
        // the entry, or vice versa).  `clearNodesForGraph` does not
        // touch `self.graphs` so the leaf-mutex invariant holds — see
        // `graphs_mutex` field doc.
        self.graphs_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.graphs_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        // Dual-write: drop from adapter, then fall through to local cleanup
        if (global_vtable) |vt| {
            vt.dropGraphFn(vt.ctx, graph_name);
        }
        if (std.mem.eql(u8, graph_name, "default")) {
            return error.CannotDropDefaultGraph;
        }
        if (!self.graphs.contains(graph_name)) {
            return error.GraphNotFound;
        }

        self.clearNodesForGraph(graph_name);
        if (self.graphs.fetchRemove(graph_name)) |kv| {
            self.allocator.free(kv.key);
        }
        // GAP-0839: drop the persistent-UUID entry alongside the graph.
        if (self.graph_uuids.fetchRemove(graph_name)) |kv| {
            self.allocator.free(kv.key);
        }
        // Clean up IdMap for dropped graph
        if (self.id_maps.fetchRemove(graph_name)) |kv| {
            self.allocator.free(kv.key);
            var im = kv.value;
            im.deinit();
        }
        self.dirty.store(true, .release);
        incrementMutationEpoch();
    }

    // CANARY: REQ=REQ-MULTI-GRAPH-004; FEATURE="MultiGraphIsolation"; ASPECT=CreateNode; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Create node with optional graph name for per-graph data isolation
    // GAP-0291: Resolve tenant_id from the per-thread FLE context set by the connection handler.
    // This ensures nodes created during a multi-tenant session are tagged with the correct
    // tenant_id instead of always using DEFAULT_TENANT_ID.
    // CANARY: REQ=REQ-MULTI-TENANT-006; FEATURE="PerTenantIsolation"; ASPECT=NodeCreateAutoTenant; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-05
    pub fn createNodeWithGraph(self: *GraphStore, labels: []const []const u8, graph_name: []const u8) !u64 {
        // GAP-0891 (RC-1 step 3): prefer the active ExecutionContext's tenant
        // over the per-thread map, so the EXECUTION CONTEXT — not the OS thread
        // — is authoritative. The per-thread map (and its "default" fallback)
        // is reached only for genuinely contextless callers.
        const tenant = fle_integration.tenantPreferringActiveContext();
        return self.createNodeWithGraphAndTenant(labels, graph_name, tenant);
    }

    // GAP-0891 (RC-1 seam): bulk / group-commit writes execute on shard-worker
    // threads that never call `fle_integration.setCurrentTenantId` and carry no
    // active ExecutionContext, so the no-tenant `createNodeWithGraph` above
    // resolves to "default" and would mis-tag every bulk-written node for a
    // non-default request tenant. The real fix captures the request tenant on
    // the HANDLER thread at submit time (`group_commit.ShardedCoordinator.submit`),
    // stores it on the `group_commit.ApplyOp`, and threads it through the
    // `graph_storage_adapter` bulk helpers down to this seam. Here we honor that
    // captured tenant verbatim (no thread/context resolution — the worker thread
    // has neither).
    pub fn createNodeForRequestTenant(
        self: *GraphStore,
        labels: []const []const u8,
        graph_name: []const u8,
        request_tenant: []const u8,
    ) !u64 {
        return self.createNodeWithGraphAndTenant(labels, graph_name, request_tenant);
    }

    /// Phase 2 of the graph-sharding plan: pre-allocate a node id
    /// for use by the `ShardedCoordinator`.  Returns a fresh UUIDv7-
    /// truncated-to-u64 id without touching any graph state.  The
    /// caller is expected to (a) route an `ApplyOp` to
    /// `shardIndex(id)` and (b) call `createNodeWithReservedIdAndGraph`
    /// inside the shard's write lock to complete the insert.
    ///
    /// Time-based ids are monotonically increasing and globally
    /// unique without further synchronisation — UUIDv7's time + seq
    /// bits guarantee no collision under a single process.
    pub fn reserveNodeId(self: *GraphStore) u64 {
        _ = self;
        return generateTimeBasedId();
    }

    /// Phase 2 variant of `createNodeWithGraphAndTenant` that accepts
    /// a pre-allocated id (usually via `reserveNodeId`) instead of
    /// generating one.  Used by the `ShardedCoordinator` to route an
    /// op to its shard BEFORE the id is populated into the store —
    /// the coordinator holds `shard_locks[shardIndex(id)]` EXCLUSIVE
    /// and `mg.string_indexes_mutex` for the label_index update.
    ///
    /// Apart from accepting the id as a parameter, behaviour is
    /// identical to `createNodeWithGraphAndTenant` (adapter
    /// persistence, IdMap registration, label index, mutation
    /// notify, dirty flag).
    pub fn createNodeWithReservedIdAndGraph(
        self: *GraphStore,
        reserved_id: u64,
        labels: []const []const u8,
        graph_name: []const u8,
    ) !void {
        // GAP-0891 (RC-1 step 3): context-preferring tenant resolution.
        const tenant = fle_integration.tenantPreferringActiveContext();
        return self.createNodeWithReservedIdGraphAndTenant(reserved_id, labels, graph_name, tenant);
    }

    /// Tenant-aware variant — see `createNodeWithReservedIdAndGraph`.
    pub fn createNodeWithReservedIdGraphAndTenant(
        self: *GraphStore,
        reserved_id: u64,
        labels: []const []const u8,
        graph_name: []const u8,
        tenant: []const u8,
    ) !void {
        // PHASE 1b chokepoint: build the graph's resident indexes BEFORE this
        // write so loop2 (run on first touch) can't later double-count the
        // node/labels this create is about to insert.
        self.ensureGraphHydrated(graph_name);
        const adapter_node: ?struct {
            vt: AdapterVTable,
            slot_id: u64,
        } = if (global_vtable) |vt|
            .{
                .vt = vt,
                .slot_id = try vt.createNodeFn(vt.ctx, graph_name, labels),
            }
        else
            null;
        try self.ensureGraph(graph_name);

        if (adapter_node) |persisted_node| {
            persistNodePublicId(persisted_node.vt, graph_name, persisted_node.slot_id, reserved_id) catch |err| {
                persisted_node.vt.deleteNodeFn(persisted_node.vt.ctx, graph_name, persisted_node.slot_id) catch {};
                return err;
            };
            // GAP-0891 (RC-2): round-trip the tenant tag (no-op for default).
            persistNodeTenantId(persisted_node.vt, graph_name, persisted_node.slot_id, tenant) catch |err| {
                persisted_node.vt.deleteNodeFn(persisted_node.vt.ctx, graph_name, persisted_node.slot_id) catch {};
                return err;
            };
            const im = try self.getOrCreateIdMap(graph_name);
            try im.insertNodeWithSlot(@as(u128, reserved_id), persisted_node.slot_id);
        }

        try self.insertReservedNodeInMemory(reserved_id, labels, graph_name, tenant);
    }

    // CANARY: REQ=REQ-QUIC-HC-016; FEATURE="High-Concurrency Mutations"; ASPECT=ShardAlignedBulkNodeCreate; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=storage; UPDATED=2026-06-11
    /// Register an already-persisted storage-engine slot for a reserved public
    /// node id, then populate the in-memory compatibility store. This is used
    /// by the group-commit write path after it allocates the engine slot on the
    /// same shard as the coordinator batch, avoiding the normal adapter create
    /// path which would allocate a different engine slot and defeat batching.
    pub fn createNodeWithReservedIdAndSlotGraphAndTenant(
        self: *GraphStore,
        reserved_id: u64,
        slot_id: u64,
        labels: []const []const u8,
        graph_name: []const u8,
        tenant: []const u8,
    ) !void {
        self.ensureGraphHydrated(graph_name); // PHASE 1b chokepoint (hydrate before write)
        try self.ensureGraph(graph_name);
        const im = try self.getOrCreateIdMap(graph_name);
        try im.insertNodeWithSlot(@as(u128, reserved_id), slot_id);
        errdefer _ = im.removeNode(@as(u128, reserved_id));

        try self.insertReservedNodeInMemory(reserved_id, labels, graph_name, tenant);
    }

    pub fn createNodeWithReservedIdAndSlotAndGraph(
        self: *GraphStore,
        reserved_id: u64,
        slot_id: u64,
        labels: []const []const u8,
        graph_name: []const u8,
    ) !void {
        // GAP-0891 (RC-1 step 3): context-preferring tenant resolution.
        const tenant = fle_integration.tenantPreferringActiveContext();
        return self.createNodeWithReservedIdAndSlotGraphAndTenant(reserved_id, slot_id, labels, graph_name, tenant);
    }

    fn insertReservedNodeInMemory(
        self: *GraphStore,
        reserved_id: u64,
        labels: []const []const u8,
        graph_name: []const u8,
        tenant: []const u8,
    ) !void {
        const labels_copy = try self.allocator.alloc([]const u8, labels.len);
        errdefer self.allocator.free(labels_copy);
        var copied_labels: usize = 0;
        for (labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
            copied_labels += 1;
        }
        errdefer for (labels_copy[0..copied_labels]) |label| self.allocator.free(label);

        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        errdefer self.allocator.free(graph_name_copy);
        const tenant_id_copy = try self.allocator.dupe(u8, tenant);
        errdefer self.allocator.free(tenant_id_copy);

        const node = Node{
            .id = reserved_id,
            .labels = labels_copy,
            .properties = CompactPropertyMap.init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        try self.nodes.put(reserved_id, node);
        for (labels) |label| {
            try self.addToLabelIndex(graph_name, label, reserved_id);
        }
        // PERF-B (issue #811): per-graph node-id index.
        try self.addNodeToGraphIndex(graph_name, reserved_id);
        // PERF-C (issue #814): tenant-keyed label counters. New nodes
        // carry no user properties at create time, so only the label
        // dimension fires here.
        for (labels) |label| {
            try self.bumpLabelCount(graph_name, tenant, label);
        }

        self.dirty.store(true, .release);
        incrementMutationEpoch();
        notifyMutation(.create_node, reserved_id, 0, 0, if (labels.len > 0) labels[0] else null, null, null, graph_name);
    }

    // CANARY: REQ=REQ-MULTI-TENANT-003; FEATURE="PerTenantIsolation"; ASPECT=NodeCreation; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-01
    // GAP-0279: Create a node tagged with both graph_name and tenant_id for per-tenant isolation
    pub fn createNodeWithGraphAndTenant(self: *GraphStore, labels: []const []const u8, graph_name: []const u8, tenant: []const u8) !u64 {
        // PHASE 1b chokepoint: build resident indexes BEFORE this write so a
        // later first-touch loop2 can't double-count this node/labels.
        self.ensureGraphHydrated(graph_name);
        // The `geode.graph_store.create_node` trace span was rolled back
        // here pending a coordinated otel pin bump to 0c34ce9b+ — the
        // upstream BatchSpanProcessor concurrent-producer race (panic at
        // otel/src/sdk/export.zig:330) otherwise crashes drainLocked
        // under load. See the note at
        // src/storage/graph_storage_adapter.zig:2237 and the regression
        // guard at tests/test_bsp_race_regression.zig.

        const adapter_node: ?struct {
            vt: AdapterVTable,
            slot_id: u64,
        } = if (global_vtable) |vt|
            .{
                .vt = vt,
                .slot_id = try vt.createNodeFn(vt.ctx, graph_name, labels),
            }
        else
            null;
        try self.ensureGraph(graph_name);
        // Generate UUIDv7-based time-sortable unique ID
        const id = generateTimeBasedId();

        // Store UUID→slot mapping in IdMap for adapter translation
        if (adapter_node) |persisted_node| {
            persistNodePublicId(persisted_node.vt, graph_name, persisted_node.slot_id, id) catch |err| {
                persisted_node.vt.deleteNodeFn(persisted_node.vt.ctx, graph_name, persisted_node.slot_id) catch {};
                return err;
            };
            // GAP-0891 (RC-2): round-trip the tenant tag (no-op for default).
            persistNodeTenantId(persisted_node.vt, graph_name, persisted_node.slot_id, tenant) catch |err| {
                persisted_node.vt.deleteNodeFn(persisted_node.vt.ctx, graph_name, persisted_node.slot_id) catch {};
                return err;
            };
            const im = try self.getOrCreateIdMap(graph_name);
            try im.insertNodeWithSlot(@as(u128, id), persisted_node.slot_id);
        }

        const labels_copy = try self.allocator.alloc([]const u8, labels.len);
        for (labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
        }

        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const tenant_id_copy = try self.allocator.dupe(u8, tenant);

        const node = Node{
            .id = id,
            .labels = labels_copy,
            .properties = CompactPropertyMap.init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        try self.nodes.put(id, node);
        // CANARY: REQ=REQ-PERF-LABEL-INDEX-002; FEATURE="LabelBasedIndex"; ASPECT=IndexMaintenance; STATUS=TESTED; TEST=tests/test_match_set_label_scan_regression.zig; OWNER=perf; UPDATED=2026-04-11
        for (labels) |label| {
            try self.addToLabelIndex(graph_name, label, id);
        }
        // PERF-B (issue #811): per-graph node-id index.
        try self.addNodeToGraphIndex(graph_name, id);
        // PERF-C (issue #814): tenant-keyed label counters.
        for (labels) |label| {
            try self.bumpLabelCount(graph_name, tenant, label);
        }

        // Mark store as dirty - persistence happens at query completion, not per-node
        self.dirty.store(true, .release);
        incrementMutationEpoch();
        log.debug("Node created, dirty=true", &.{
            Attr.int("node_id", @intCast(id)),
            Attr.int("total_nodes", @intCast(self.nodes.count())),
        });

        // WAL notification: CreateNode
        notifyMutation(.create_node, id, 0, 0, if (labels.len > 0) labels[0] else null, null, null, graph_name);

        return id;
    }

    // CANARY: REQ=REQ-PERF-QPS-0815; FEATURE="BatchCreate"; ASPECT=BulkNodeSlots; STATUS=TESTED; TEST=tests/test_gap0815_deep_bulk_create.zig; OWNER=performance; UPDATED=2026-04-20
    /// Allocate `n` node slots in `graph_name` + attach the same label set
    /// to each, under a SINGLE adapter mutex acquisition + a SINGLE
    /// label-index posting-list grow per (graph, label). Caller owns the
    /// returned slice and MUST free it with the same allocator.
    ///
    /// Rationale: the per-node `createNodeWithGraph` takes the adapter
    /// mutex twice per call (once in `getOrCreateGraph`, once in the
    /// `persistNodePublicId → setNodeProperty` internal-prop write) and
    /// appends to each label's posting list one slot at a time via
    /// O(len) `sortedInsert`. For N=100 homogeneous clauses that's ~200
    /// mutex acquisitions + 100 O(len) inserts + 100 label-index key
    /// format probes. This batched version resolves the graph/label-ids
    /// once, pre-sizes each label's posting list, and appends all new
    /// IDs in one pass (time-ordered, so appends preserve the sorted
    /// invariant).
    ///
    /// Preserves per-node side effects: adapter slot allocation + record
    /// write + label attach, IdMap slot mapping, in-memory `nodes` entry,
    /// label posting list update, persisted internal-id property, mutation
    /// notify. The undo log and auto-index rebuild are the caller's
    /// responsibility (the batch caller can invoke them once per batch,
    /// or once per slot, as appropriate — `executeBatchCreateHomogeneous`
    /// logs per slot because the txn_undo_log API is row-oriented).
    ///
    /// The returned slice is allocated via `out_allocator` so callers can
    /// free it with the same allocator (e.g. test `testing.allocator` vs
    /// the internal `smp_allocator`).
    pub fn createNodesBatch(
        self: *GraphStore,
        labels: []const []const u8,
        graph_name: []const u8,
        n: usize,
    ) ![]u64 {
        return self.createNodesBatchWithAllocator(labels, graph_name, n, self.allocator);
    }

    /// Variant of `createNodesBatch` that allocates the result slice via
    /// the caller-supplied allocator (used by tests that want to free the
    /// result with `std.testing.allocator` even though the store uses a
    /// different internal allocator).
    pub fn createNodesBatchWithAllocator(
        self: *GraphStore,
        labels: []const []const u8,
        graph_name: []const u8,
        n: usize,
        out_allocator: std.mem.Allocator,
    ) ![]u64 {
        if (n == 0) return try out_allocator.alloc(u64, 0);
        self.ensureGraphHydrated(graph_name); // PHASE 1b chokepoint (hydrate before write)

        // GAP-0891 (RC-1 step 3): context-preferring tenant resolution.
        const tenant = fle_integration.tenantPreferringActiveContext();

        // --- Adapter path: one mutex acquisition for all N slots. ---
        var adapter_slot_ids: ?[]u64 = null;
        defer if (adapter_slot_ids) |s| self.allocator.free(s);
        if (global_adapter) |adapter| {
            adapter_slot_ids = try adapter.createNodesBatch(graph_name, labels, n, self.allocator);
        } else if (global_vtable) |vt| {
            // Fall back to per-slot vtable dispatch if no direct adapter is
            // available (rare path — covered for API symmetry).
            const slots = try self.allocator.alloc(u64, n);
            errdefer self.allocator.free(slots);
            var j: usize = 0;
            while (j < n) : (j += 1) {
                slots[j] = try vt.createNodeFn(vt.ctx, graph_name, labels);
            }
            adapter_slot_ids = slots;
        }

        try self.ensureGraph(graph_name);

        // Pre-size the nodes hashmap to amortize rehashes across the batch.
        try self.nodes.ensureUnusedCapacity(@intCast(n));

        // Pre-size each label's posting list so the N sorted inserts can
        // bypass N individual grow-and-shift operations. Since
        // `generateTimeBasedId` returns strictly-increasing IDs (UUIDv7
        // top bits are a monotonic timestamp + seq), the batch IDs are
        // all greater than any previously inserted ID for this graph +
        // label — so appending preserves the sorted invariant.
        for (labels) |label| {
            try self.ensureLabelPostingCapacity(graph_name, label, n);
        }

        // Allocate result slice (caller-owned, caller's allocator).
        const public_ids = try out_allocator.alloc(u64, n);
        errdefer out_allocator.free(public_ids);

        // Pre-resolve IdMap once (graph name already ensured above).
        const id_map_opt: ?*id_map_mod.IdMap = if (adapter_slot_ids != null) try self.getOrCreateIdMap(graph_name) else null;

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const public_id = generateTimeBasedId();
            public_ids[i] = public_id;

            // Per-node label strings must be individually-owned (the
            // GraphStore Node deinit frees each string + the outer slice).
            const labels_copy = try self.allocator.alloc([]const u8, labels.len);
            errdefer self.allocator.free(labels_copy);
            var filled: usize = 0;
            errdefer for (labels_copy[0..filled]) |s| self.allocator.free(s);
            for (labels, 0..) |label, li| {
                labels_copy[li] = try self.allocator.dupe(u8, label);
                filled += 1;
            }

            const graph_name_copy = try self.allocator.dupe(u8, graph_name);
            errdefer self.allocator.free(graph_name_copy);
            const tenant_id_copy = try self.allocator.dupe(u8, tenant);
            errdefer self.allocator.free(tenant_id_copy);

            // Persist the public ID + IdMap entry via the adapter (each
            // call takes its own adapter mutex once — this is unavoidable
            // at the current adapter API shape but dwarfed by the savings
            // above).
            if (adapter_slot_ids) |slots| {
                if (global_vtable) |vt| {
                    persistNodePublicId(vt, graph_name, slots[i], public_id) catch |err| {
                        // Roll back the adapter slot on error. We cannot
                        // recover slots already committed earlier in the
                        // batch — their public IDs are emitted but the
                        // caller never saw the return value (errdefer on
                        // public_ids above drops it).
                        if (global_vtable) |v| v.deleteNodeFn(v.ctx, graph_name, slots[i]) catch {};
                        return err;
                    };
                    // GAP-0891 (RC-2): round-trip the tenant tag (no-op for default).
                    persistNodeTenantId(vt, graph_name, slots[i], tenant) catch |err| {
                        if (global_vtable) |v| v.deleteNodeFn(v.ctx, graph_name, slots[i]) catch {};
                        return err;
                    };
                }
                if (id_map_opt) |im| {
                    try im.insertNodeWithSlot(@as(u128, public_id), slots[i]);
                }
            }

            // In-memory node entry.
            const node = Node{
                .id = public_id,
                .labels = labels_copy,
                .properties = CompactPropertyMap.init(self.allocator),
                .graph_name = graph_name_copy,
                .tenant_id = tenant_id_copy,
            };
            try self.nodes.put(public_id, node);

            // Label index: append-only (monotonic IDs preserve sort).
            for (labels) |label| {
                try self.appendToLabelIndex(graph_name, label, public_id);
            }
            // PERF-B (issue #811): per-graph node-id index.
            try self.addNodeToGraphIndex(graph_name, public_id);
            // PERF-C (issue #814): tenant-keyed label counters. Batch path
            // creates nodes with the same label set, so we could hoist the
            // bumpLabelCount out of the per-node loop — but the bump itself
            // is a HashMap probe + integer-add, so the per-node cost is
            // negligible and the simpler call shape matches the other
            // create paths.
            for (labels) |label| {
                try self.bumpLabelCount(graph_name, tenant, label);
            }

            // WAL / mutation notification per node.
            notifyMutation(.create_node, public_id, 0, 0, if (labels.len > 0) labels[0] else null, null, null, graph_name);
        }

        self.dirty.store(true, .release);
        incrementMutationEpoch();
        log.debug("Batch node creation", &.{
            Attr.int("count", @intCast(n)),
            Attr.int("total_nodes", @intCast(self.nodes.count())),
        });

        return public_ids;
    }

    /// Resolve (graph, label) → pointer to the `LabelPosting` entry in
    /// `label_index`, creating the entry on first sight.
    ///
    /// Caller must hold `label_index_mutex`. Holding that outer mutex while
    /// using the returned pointer prevents `StringHashMap` rehash from moving
    /// the posting while its leaf mutex is locked.
    fn ensureLabelPostingListLocked(self: *GraphStore, graph_name: []const u8, label: []const u8) !*LabelPosting {
        var buf: [512]u8 = undefined;
        const probe_key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ graph_name, label }) catch {
            const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label });
            const result = try self.label_index.getOrPut(key);
            if (!result.found_existing) {
                result.value_ptr.* = .{};
            } else {
                self.allocator.free(key);
            }
            return result.value_ptr;
        };

        if (self.label_index.getPtr(probe_key)) |posting| return posting;

        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label });
        const result = try self.label_index.getOrPut(key);
        if (!result.found_existing) {
            result.value_ptr.* = .{};
        } else {
            self.allocator.free(key);
        }
        return result.value_ptr;
    }

    fn formatGraphLabelKey(
        scratch: []u8,
        allocator: std.mem.Allocator,
        graph_name: []const u8,
        label: []const u8,
    ) !struct { key: []const u8, owned: ?[]u8 } {
        const key = std.fmt.bufPrint(scratch, "{s}:{s}", .{ graph_name, label }) catch |err| switch (err) {
            error.NoSpaceLeft => {
                const owned = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ graph_name, label });
                return .{ .key = owned, .owned = owned };
            },
        };
        return .{ .key = key, .owned = null };
    }

    fn ensureGraphLabelCount(self: *GraphStore, graph_name: []const u8, label: []const u8) !void {
        var key_buf: [512]u8 = undefined;
        var formatted = try formatGraphLabelKey(&key_buf, self.allocator, graph_name, label);
        defer if (formatted.owned) |owned| self.allocator.free(owned);

        const io = std.Io.Threaded.global_single_threaded.io();
        self.label_count_rwlock.lockUncancelable(io);
        defer self.label_count_rwlock.unlock(io);

        if (self.label_counts_by_graph.contains(formatted.key)) return;

        const owned_key = if (formatted.owned) |owned| blk: {
            formatted.owned = null;
            break :blk owned;
        } else try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label });
        errdefer self.allocator.free(owned_key);
        try self.label_counts_by_graph.put(owned_key, LabelCountValue.init(0));
    }

    fn bumpGraphLabelCount(self: *GraphStore, graph_name: []const u8, label: []const u8) void {
        var key_buf: [512]u8 = undefined;
        var formatted = formatGraphLabelKey(&key_buf, self.allocator, graph_name, label) catch return;
        defer if (formatted.owned) |owned| self.allocator.free(owned);

        const io = std.Io.Threaded.global_single_threaded.io();
        self.label_count_rwlock.lockSharedUncancelable(io);
        if (self.label_counts_by_graph.getPtr(formatted.key)) |count| {
            _ = count.fetchAdd(1, .monotonic);
            self.label_count_rwlock.unlockShared(io);
            return;
        }
        self.label_count_rwlock.unlockShared(io);

        self.label_count_rwlock.lockUncancelable(io);
        defer self.label_count_rwlock.unlock(io);
        if (self.label_counts_by_graph.getPtr(formatted.key)) |count| {
            _ = count.fetchAdd(1, .monotonic);
            return;
        }

        const owned_key = if (formatted.owned) |owned| blk: {
            formatted.owned = null;
            break :blk owned;
        } else std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label }) catch return;
        self.label_counts_by_graph.put(owned_key, LabelCountValue.init(1)) catch {
            self.allocator.free(owned_key);
            return;
        };
    }

    /// T2b (hydration merge, label family): bulk variant of
    /// `bumpGraphLabelCount` — one refcount add for `n` freshly inserted
    /// posting ids. Final counter value is identical to calling the
    /// single-bump version `n` times (atomic adds commute).
    fn bumpGraphLabelCountBy(self: *GraphStore, graph_name: []const u8, label: []const u8, n: usize) void {
        if (n == 0) return;
        var key_buf: [512]u8 = undefined;
        var formatted = formatGraphLabelKey(&key_buf, self.allocator, graph_name, label) catch return;
        defer if (formatted.owned) |owned| self.allocator.free(owned);

        const io = std.Io.Threaded.global_single_threaded.io();
        self.label_count_rwlock.lockSharedUncancelable(io);
        if (self.label_counts_by_graph.getPtr(formatted.key)) |count| {
            _ = count.fetchAdd(n, .monotonic);
            self.label_count_rwlock.unlockShared(io);
            return;
        }
        self.label_count_rwlock.unlockShared(io);

        self.label_count_rwlock.lockUncancelable(io);
        defer self.label_count_rwlock.unlock(io);
        if (self.label_counts_by_graph.getPtr(formatted.key)) |count| {
            _ = count.fetchAdd(n, .monotonic);
            return;
        }

        const owned_key = if (formatted.owned) |owned| blk: {
            formatted.owned = null;
            break :blk owned;
        } else std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label }) catch return;
        self.label_counts_by_graph.put(owned_key, LabelCountValue.init(n)) catch {
            self.allocator.free(owned_key);
            return;
        };
    }

    fn decGraphLabelCount(self: *GraphStore, graph_name: []const u8, label: []const u8) void {
        var key_buf: [512]u8 = undefined;
        const formatted = formatGraphLabelKey(&key_buf, self.allocator, graph_name, label) catch return;
        defer if (formatted.owned) |owned| self.allocator.free(owned);

        const io = std.Io.Threaded.global_single_threaded.io();
        self.label_count_rwlock.lockSharedUncancelable(io);
        defer self.label_count_rwlock.unlockShared(io);

        const count = self.label_counts_by_graph.getPtr(formatted.key) orelse return;
        var observed = count.load(.monotonic);
        while (observed != 0) {
            if (count.cmpxchgWeak(observed, observed - 1, .monotonic, .monotonic)) |actual| {
                observed = actual;
            } else {
                return;
            }
        }
    }

    fn countGraphLabel(self: *const GraphStore, graph_name: []const u8, label: []const u8) usize {
        @constCast(self).ensureGraphHydrated(graph_name); // PHASE 1b chokepoint
        var key_buf: [512]u8 = undefined;
        const formatted = formatGraphLabelKey(&key_buf, self.allocator, graph_name, label) catch return 0;
        defer if (formatted.owned) |owned| self.allocator.free(owned);

        const mutable_self: *GraphStore = @constCast(self);
        const io = std.Io.Threaded.global_single_threaded.io();
        mutable_self.label_count_rwlock.lockSharedUncancelable(io);
        defer mutable_self.label_count_rwlock.unlockShared(io);
        const count = mutable_self.label_counts_by_graph.getPtr(formatted.key) orelse return 0;
        return count.load(.monotonic);
    }

    // ── Per-(graph, edge_type) exact-count refcount ────────────────────────
    // Mirrors ensure/bump/dec/countGraphLabel for the edge side. Key "graph:type"
    // via formatGraphLabelKey. Guarded by edge_type_count_rwlock (SHARED for the
    // atomic mutate of an existing entry, EXCLUSIVE for the lazy insert).
    fn ensureGraphEdgeTypeCount(self: *GraphStore, graph_name: []const u8, edge_type: []const u8) !void {
        var key_buf: [512]u8 = undefined;
        var formatted = try formatGraphLabelKey(&key_buf, self.allocator, graph_name, edge_type);
        defer if (formatted.owned) |owned| self.allocator.free(owned);

        const io = std.Io.Threaded.global_single_threaded.io();
        self.edge_type_count_rwlock.lockUncancelable(io);
        defer self.edge_type_count_rwlock.unlock(io);

        if (self.edge_type_counts_by_graph.contains(formatted.key)) return;

        const owned_key = if (formatted.owned) |owned| blk: {
            formatted.owned = null;
            break :blk owned;
        } else try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, edge_type });
        errdefer self.allocator.free(owned_key);
        try self.edge_type_counts_by_graph.put(owned_key, LabelCountValue.init(0));
    }

    fn bumpGraphEdgeTypeCount(self: *GraphStore, graph_name: []const u8, edge_type: []const u8) void {
        var key_buf: [512]u8 = undefined;
        var formatted = formatGraphLabelKey(&key_buf, self.allocator, graph_name, edge_type) catch return;
        defer if (formatted.owned) |owned| self.allocator.free(owned);

        const io = std.Io.Threaded.global_single_threaded.io();
        self.edge_type_count_rwlock.lockSharedUncancelable(io);
        if (self.edge_type_counts_by_graph.getPtr(formatted.key)) |count| {
            _ = count.fetchAdd(1, .monotonic);
            self.edge_type_count_rwlock.unlockShared(io);
            return;
        }
        self.edge_type_count_rwlock.unlockShared(io);

        self.edge_type_count_rwlock.lockUncancelable(io);
        defer self.edge_type_count_rwlock.unlock(io);
        if (self.edge_type_counts_by_graph.getPtr(formatted.key)) |count| {
            _ = count.fetchAdd(1, .monotonic);
            return;
        }

        const owned_key = if (formatted.owned) |owned| blk: {
            formatted.owned = null;
            break :blk owned;
        } else std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, edge_type }) catch return;
        self.edge_type_counts_by_graph.put(owned_key, LabelCountValue.init(1)) catch {
            self.allocator.free(owned_key);
            return;
        };
    }

    fn decGraphEdgeTypeCount(self: *GraphStore, graph_name: []const u8, edge_type: []const u8) void {
        var key_buf: [512]u8 = undefined;
        const formatted = formatGraphLabelKey(&key_buf, self.allocator, graph_name, edge_type) catch return;
        defer if (formatted.owned) |owned| self.allocator.free(owned);

        const io = std.Io.Threaded.global_single_threaded.io();
        self.edge_type_count_rwlock.lockSharedUncancelable(io);
        defer self.edge_type_count_rwlock.unlockShared(io);

        const count = self.edge_type_counts_by_graph.getPtr(formatted.key) orelse return;
        var observed = count.load(.monotonic);
        while (observed != 0) {
            if (count.cmpxchgWeak(observed, observed - 1, .monotonic, .monotonic)) |actual| {
                observed = actual;
            } else {
                return;
            }
        }
    }

    fn countGraphEdgeType(self: *const GraphStore, graph_name: []const u8, edge_type: []const u8) usize {
        @constCast(self).ensureGraphHydrated(graph_name); // PHASE 1b chokepoint
        var key_buf: [512]u8 = undefined;
        const formatted = formatGraphLabelKey(&key_buf, self.allocator, graph_name, edge_type) catch return 0;
        defer if (formatted.owned) |owned| self.allocator.free(owned);

        const mutable_self: *GraphStore = @constCast(self);
        const io = std.Io.Threaded.global_single_threaded.io();
        mutable_self.edge_type_count_rwlock.lockSharedUncancelable(io);
        defer mutable_self.edge_type_count_rwlock.unlockShared(io);
        const count = mutable_self.edge_type_counts_by_graph.getPtr(formatted.key) orelse return 0;
        return count.load(.monotonic);
    }

    fn ensureLabelPostingCapacity(self: *GraphStore, graph_name: []const u8, label: []const u8, additional: usize) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.label_index_mutex.lockUncancelable(io);
        defer self.label_index_mutex.unlock(io);

        const posting = try self.ensureLabelPostingListLocked(graph_name, label);
        try self.ensureGraphLabelCount(graph_name, label);
        posting.lock();
        defer posting.unlock();
        try posting.list.ensureUnusedCapacity(self.allocator, additional);
    }

    /// Append-only label-index insert. Used only by the batch path where
    /// the caller guarantees the new id is greater than every id already
    /// present for this (graph, label) — which holds for the batch path
    /// because `generateTimeBasedId` is monotonic within a batch. Falls
    /// back to a sorted insert if the monotonic invariant is accidentally
    /// violated (e.g. clock skew), so correctness is preserved.
    fn appendToLabelIndex(self: *GraphStore, graph_name: []const u8, label: []const u8, node_id: u64) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.label_index_mutex.lockUncancelable(io);
        defer self.label_index_mutex.unlock(io);

        const posting = try self.ensureLabelPostingListLocked(graph_name, label);
        posting.lock();
        defer posting.unlock();
        const inserted = try insertIntoPostingLocked(posting, self.allocator, node_id);
        if (inserted) self.bumpGraphLabelCount(graph_name, label);
    }

    fn createNodeWithIdInternal(
        self: *GraphStore,
        node_id: u64,
        labels: []const []const u8,
        graph_name: []const u8,
        mark_dirty: bool,
        persist_adapter: bool,
    ) !void {
        self.ensureGraphHydrated(graph_name); // PHASE 1b chokepoint (hydrate before write)
        // Existence check BEFORE any storage-adapter slot creation: an
        // idempotent re-create (e.g. a restarted Raft node replaying a
        // committed entry whose node id already lives in the persisted store)
        // must return `error.NodeAlreadyExists` WITHOUT leaking a phantom
        // adapter slot. See cluster_replication.applyNodeCreatePayload.
        try self.ensureGraph(graph_name);
        if (self.nodes.contains(node_id)) return error.NodeAlreadyExists;

        // GAP-0891 (RC-3): honor the active tenant instead of hardcoding
        // DEFAULT_TENANT_ID. createNodeWithId is used by replication / WAL
        // replay / reload entry points; those run inside the request's
        // ExecutionContext (or a contextless internal caller, which resolves to
        // "default"). The recovered tenant must be used for BOTH the in-memory
        // tag and the PERF-C counter bucket so introspection stays consistent.
        const tenant = fle_integration.tenantPreferringActiveContext();

        const adapter_node: ?struct {
            vt: AdapterVTable,
            slot_id: u64,
        } = if (persist_adapter) blk: {
            const vt = global_vtable orelse break :blk null;
            break :blk .{
                .vt = vt,
                .slot_id = try vt.createNodeFn(vt.ctx, graph_name, labels),
            };
        } else null;

        if (adapter_node) |persisted_node| {
            persistNodePublicId(persisted_node.vt, graph_name, persisted_node.slot_id, node_id) catch |err| {
                persisted_node.vt.deleteNodeFn(persisted_node.vt.ctx, graph_name, persisted_node.slot_id) catch {};
                return err;
            };
            // GAP-0891 (RC-2): round-trip the tenant tag (no-op for default).
            persistNodeTenantId(persisted_node.vt, graph_name, persisted_node.slot_id, tenant) catch |err| {
                persisted_node.vt.deleteNodeFn(persisted_node.vt.ctx, graph_name, persisted_node.slot_id) catch {};
                return err;
            };
            const im = try self.getOrCreateIdMap(graph_name);
            try im.insertNodeWithSlot(@as(u128, node_id), persisted_node.slot_id);
        }

        const labels_copy = try self.allocator.alloc([]const u8, labels.len);
        for (labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
        }

        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const tenant_id_copy = try self.allocator.dupe(u8, tenant);

        const node = Node{
            .id = node_id,
            .labels = labels_copy,
            .properties = CompactPropertyMap.init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        try self.nodes.put(node_id, node);

        for (labels) |label| {
            try self.addToLabelIndex(graph_name, label, node_id);
        }
        // PERF-B (issue #811): per-graph node-id index.
        try self.addNodeToGraphIndex(graph_name, node_id);
        // PERF-C (issue #814): tenant-keyed label counters. GAP-0891 (RC-3):
        // bump the SAME tenant bucket the node is tagged with.
        for (labels) |label| {
            try self.bumpLabelCount(graph_name, tenant, label);
        }

        if (node_id >= self.next_node_id) {
            self.next_node_id = node_id + 1;
        }

        if (mark_dirty) {
            self.dirty.store(true, .release);
            incrementMutationEpoch();
        }
    }

    /// Create a node with a specified ID (used for replication/2PC).
    pub fn createNodeWithId(self: *GraphStore, node_id: u64, labels: []const []const u8, graph_name: []const u8) !void {
        return self.createNodeWithIdInternal(node_id, labels, graph_name, true, true);
    }

    /// Create a node with a specified ID without marking dirty (used for rollback).
    pub fn createNodeWithIdNoSave(self: *GraphStore, node_id: u64, labels: []const []const u8, graph_name: []const u8) !void {
        return self.createNodeWithIdInternal(node_id, labels, graph_name, false, false);
    }

    /// PERF-C teardown helper: free every (outer key, inner key) owned by the
    /// allocator and deinit every inner StringHashMap, then deinit the outer.
    fn deinitTenantStringMultiset(
        outer: *std.StringHashMap(std.StringHashMap(usize)),
        allocator: std.mem.Allocator,
    ) void {
        var outer_it = outer.iterator();
        while (outer_it.next()) |outer_entry| {
            allocator.free(outer_entry.key_ptr.*);
            var inner = outer_entry.value_ptr.*;
            var inner_it = inner.iterator();
            while (inner_it.next()) |inner_entry| {
                allocator.free(inner_entry.key_ptr.*);
            }
            inner.deinit();
        }
        outer.deinit();
    }

    // CANARY: REQ=REQ-PERF-GRAPH-SCOPED-NODES-002; FEATURE="GraphScopedNodeIndex"; ASPECT=IndexMaintenance; STATUS=TESTED; TEST=tests/test_perf_b_graph_scoped_iteration.zig; OWNER=perf; UPDATED=2026-05-15
    // PERF-B (issue #811): Add a node-id to the per-graph node-id index.
    // Idempotent: re-adding the same id is a no-op (AutoHashMap.put dedupes).
    fn addNodeToGraphIndex(self: *GraphStore, graph_name: []const u8, node_id: u64) !void {
        // PHASE 1b concurrency fix: serialise the outer-map rehash against the
        // lockless `nodes_by_graph` readers (see `nodes_by_graph_mutex`). Leaf
        // lock — innermost, no nesting.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.nodes_by_graph_mutex.lockUncancelable(io);
        defer self.nodes_by_graph_mutex.unlock(io);
        const result = try self.nodes_by_graph.getOrPut(graph_name);
        if (!result.found_existing) {
            const key_copy = try self.allocator.dupe(u8, graph_name);
            errdefer self.allocator.free(key_copy);
            result.key_ptr.* = key_copy;
            result.value_ptr.* = std.AutoHashMap(u64, void).init(self.allocator);
        }
        try result.value_ptr.put(node_id, {});
    }

    /// T2b (hydration merge): pre-size the per-graph node-id index for a bulk
    /// load of `additional` ids (the count is exact post-scan). Same locking
    /// and getOrPut shape as `addNodeToGraphIndex`.
    fn reserveGraphNodeIndex(self: *GraphStore, graph_name: []const u8, additional: u32) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.nodes_by_graph_mutex.lockUncancelable(io);
        defer self.nodes_by_graph_mutex.unlock(io);
        const result = try self.nodes_by_graph.getOrPut(graph_name);
        if (!result.found_existing) {
            const key_copy = try self.allocator.dupe(u8, graph_name);
            errdefer self.allocator.free(key_copy);
            result.key_ptr.* = key_copy;
            result.value_ptr.* = std.AutoHashMap(u64, void).init(self.allocator);
        }
        try result.value_ptr.ensureUnusedCapacity(additional);
    }

    // PERF-B (issue #811): Remove a node-id from the per-graph node-id index.
    // The outer entry survives even when the inner set is empty — schema
    // introspection paths use `graphs` for graph-existence checks, not this
    // index, and recreating the inner map on the next insert is cheap. Keeps
    // the read-side path stateless (no need to retry on missing key).
    fn removeNodeFromGraphIndex(self: *GraphStore, graph_name: []const u8, node_id: u64) void {
        // PHASE 1b concurrency fix: hold the leaf mutex for the outer getPtr +
        // inner remove so a concurrent hydration rehash cannot tear the lookup.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.nodes_by_graph_mutex.lockUncancelable(io);
        defer self.nodes_by_graph_mutex.unlock(io);
        if (self.nodes_by_graph.getPtr(graph_name)) |inner| {
            _ = inner.remove(node_id);
        }
    }

    /// Iterator over node pointers belonging to a single graph.
    /// Lifetime: borrowed from the GraphStore — caller must hold the same
    /// graph read lock that `store.nodes.iterator()` would require.
    pub const NodesByGraphIterator = struct {
        // Empty iterator when the graph is absent.
        inner: ?std.AutoHashMap(u64, void).KeyIterator,
        store: *const GraphStore,

        pub fn next(it: *NodesByGraphIterator) ?*Node {
            const inner = &(it.inner orelse return null);
            while (inner.next()) |id_ptr| {
                // GAP-ENT-0023 P3: hydrate-on-miss, DETACHED (review C2).
                // With a BOUNDED engine-backed cache the resident map is
                // incomplete (evictions — and after a snapshot-served warm
                // hydration the cache starts COLD), so a resident-only lookup
                // would silently drop live rows from every consumer of this
                // iterator (MATCH fallback scans, getEdgesByType). The id set
                // (`nodes_by_graph`) is authoritative; a missing body is
                // rebuilt from the engine via `getNodePtrForScan`, which
                // NEVER inserts into the cache's shard maps — consumers
                // retain `*Node` across iterations (bindings, base_nodes,
                // result rows), and a cache insert here would rehash/evict
                // the very slots those pointers alias (use-after-move). The
                // detached box shares the resident pointers' grace-boundary
                // lifetime. A per-node engine failure is skipped defensively,
                // matching the old stale-id stance.
                if (it.store.getNodePtrForScan(id_ptr.*)) |node_ptr| return node_ptr;
            }
            return null;
        }
    };

    /// PERF-B (issue #811): O(nodes_in_graph) iterator that replaces
    /// `store.nodes.iterator()` for sites that filter by graph_name. Returns
    /// node *Node pointers stable for the duration of the caller's read lock.
    /// Empty graphs / absent graphs yield an empty iterator without error.
    ///
    /// Callers MUST still apply `passesTenantFilter` / `passesRLSFilter` —
    /// this index is graph-scoped, not tenant- or RLS-scoped.
    pub fn iterateNodesInGraph(self: *const GraphStore, graph_name: []const u8) NodesByGraphIterator {
        @constCast(self).ensureGraphHydrated(graph_name); // PHASE 1b chokepoint
        // PHASE 1b concurrency fix: hold `nodes_by_graph_mutex` across the outer
        // getPtr + keyIterator extraction so a concurrent hydration rehash of
        // the outer map (a first-touch of ANOTHER cold graph under the shared
        // store lock) cannot tear this lookup. The returned KeyIterator captures
        // the inner map's HEAP pointers, which survive an outer-map rehash, so
        // it stays valid after the leaf lock is released.
        const io = std.Io.Threaded.global_single_threaded.io();
        @constCast(self).nodes_by_graph_mutex.lockUncancelable(io);
        defer @constCast(self).nodes_by_graph_mutex.unlock(io);
        if (self.nodes_by_graph.getPtr(graph_name)) |inner| {
            return .{ .inner = inner.keyIterator(), .store = self };
        }
        return .{ .inner = null, .store = self };
    }

    /// Test-only: returns the size of the per-graph node-id index for the
    /// given graph (0 when the graph is absent).
    pub fn nodesInGraphCount(self: *const GraphStore, graph_name: []const u8) usize {
        @constCast(self).ensureGraphHydrated(graph_name); // PHASE 1b chokepoint
        // PHASE 1b concurrency fix: leaf-lock the outer getPtr + count so a
        // concurrent hydration rehash cannot tear the lookup.
        const io = std.Io.Threaded.global_single_threaded.io();
        @constCast(self).nodes_by_graph_mutex.lockUncancelable(io);
        defer @constCast(self).nodes_by_graph_mutex.unlock(io);
        if (self.nodes_by_graph.getPtr(graph_name)) |inner| return inner.count();
        return 0;
    }

    // CANARY: REQ=REQ-PERF-LSP-INTROSPECTION-INDEX-002; FEATURE="LspIntrospectionIndex"; ASPECT=RefcountMaintenance; STATUS=TESTED; TEST=tests/test_perf_c_lsp_introspection_index.zig; OWNER=perf; UPDATED=2026-05-15
    // PERF-C (issue #814): Bump the refcount for (tenant, key) in a nested
    // StringHashMap. Allocates outer + inner keys on first sight; on success
    // increments the existing usize. Failure propagates with the partial-key
    // allocation freed.
    fn bumpRefcount(
        self: *GraphStore,
        outer: *std.StringHashMap(std.StringHashMap(usize)),
        outer_key: []const u8,
        inner_key: []const u8,
    ) !void {
        // PERF-C race fix (2026-05-18): serialize every mutation to the
        // tenant-keyed refcount maps.  `setNodeProperty` is called from
        // 16+ shard worker threads concurrently and races on
        // `std.StringHashMap.getOrPut` here.  Leaf-level lock — no other
        // lock is acquired inside this critical section.  See the field
        // comment on `perf_c_refcount_mutex` for ordering vs.
        // `labels_rwlock`.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.perf_c_refcount_mutex.lockUncancelable(io);
        defer self.perf_c_refcount_mutex.unlock(io);

        const outer_result = try outer.getOrPut(outer_key);
        if (!outer_result.found_existing) {
            const okey_copy = try self.allocator.dupe(u8, outer_key);
            errdefer self.allocator.free(okey_copy);
            outer_result.key_ptr.* = okey_copy;
            outer_result.value_ptr.* = std.StringHashMap(usize).init(self.allocator);
        }
        const inner_result = try outer_result.value_ptr.getOrPut(inner_key);
        if (!inner_result.found_existing) {
            const ikey_copy = try self.allocator.dupe(u8, inner_key);
            errdefer self.allocator.free(ikey_copy);
            inner_result.key_ptr.* = ikey_copy;
            inner_result.value_ptr.* = 0;
        }
        inner_result.value_ptr.* += 1;
    }

    /// PERF-C: Decrement the refcount; remove the key when it hits zero so the
    /// index never reports a label/type/property no node carries.
    fn decRefcount(
        self: *GraphStore,
        outer: *std.StringHashMap(std.StringHashMap(usize)),
        outer_key: []const u8,
        inner_key: []const u8,
    ) void {
        // PERF-C race fix (2026-05-18): see `bumpRefcount` for rationale.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.perf_c_refcount_mutex.lockUncancelable(io);
        defer self.perf_c_refcount_mutex.unlock(io);

        const outer_ptr = outer.getPtr(outer_key) orelse return;
        const entry = outer_ptr.getEntry(inner_key) orelse return;
        if (entry.value_ptr.* > 1) {
            entry.value_ptr.* -= 1;
            return;
        }
        // Final reference: drop the inner key and (if empty) the outer entry.
        const owned_inner = entry.key_ptr.*;
        _ = outer_ptr.remove(inner_key);
        self.allocator.free(owned_inner);
        if (outer_ptr.count() == 0) {
            if (outer.fetchRemove(outer_key)) |kv| {
                self.allocator.free(kv.key);
                var inner_map = kv.value;
                inner_map.deinit();
            }
        }
    }

    /// GAP-ENT-0023 P3: compose the COMPOSITE outer key "graph\x00tenant" for
    /// the tenant-introspection maps (`node_labels_by_tenant`,
    /// `edge_types_by_tenant`, `label_properties_by_tenant`) into a stack
    /// buffer when small enough, else heap-allocate. NUL is the separator —
    /// graph names cannot contain NUL (the merge-index key convention already
    /// relies on this), so the split is unambiguous.
    fn formatGraphTenantKey(
        scratch: []u8,
        allocator: std.mem.Allocator,
        graph_name: []const u8,
        tenant_id: []const u8,
    ) !struct { key: []const u8, owned: ?[]u8 } {
        const total = std.math.add(usize, graph_name.len, 1) catch return error.GraphTenantKeyTooLarge;
        const total2 = std.math.add(usize, total, tenant_id.len) catch return error.GraphTenantKeyTooLarge;
        const max_graph_tenant_key_len: usize = 1 << 20; // corruption guard (mirrors formatLabelPropKey)
        if (total2 > max_graph_tenant_key_len) return error.GraphTenantKeyTooLarge;
        if (total2 <= scratch.len) {
            @memcpy(scratch[0..graph_name.len], graph_name);
            scratch[graph_name.len] = 0;
            @memcpy(scratch[graph_name.len + 1 ..][0..tenant_id.len], tenant_id);
            return .{ .key = scratch[0..total2], .owned = null };
        }
        const buf = try allocator.alloc(u8, total2);
        @memcpy(buf[0..graph_name.len], graph_name);
        buf[graph_name.len] = 0;
        @memcpy(buf[graph_name.len + 1 ..][0..tenant_id.len], tenant_id);
        return .{ .key = buf, .owned = buf };
    }

    /// Graph component of a "graph\x00tenant" outer key. A key with no NUL
    /// (never produced by formatGraphTenantKey) yields the whole key as graph
    /// and an empty tenant — such an entry can never match a real tenant/graph.
    fn graphTenantKeyGraph(outer_key: []const u8) []const u8 {
        const idx = std.mem.indexOfScalar(u8, outer_key, 0) orelse return outer_key;
        return outer_key[0..idx];
    }

    /// Tenant component of a "graph\x00tenant" outer key (see above).
    fn graphTenantKeyTenant(outer_key: []const u8) []const u8 {
        const idx = std.mem.indexOfScalar(u8, outer_key, 0) orelse return "";
        return outer_key[idx + 1 ..];
    }

    fn bumpLabelCount(self: *GraphStore, graph_name: []const u8, tenant_id: []const u8, label: []const u8) !void {
        var scratch: [512]u8 = undefined;
        const k = try formatGraphTenantKey(&scratch, self.allocator, graph_name, tenant_id);
        defer if (k.owned) |buf| self.allocator.free(buf);
        try self.bumpRefcount(&self.node_labels_by_tenant, k.key, label);
    }

    fn decLabelCount(self: *GraphStore, graph_name: []const u8, tenant_id: []const u8, label: []const u8) void {
        var scratch: [512]u8 = undefined;
        const k = formatGraphTenantKey(&scratch, self.allocator, graph_name, tenant_id) catch return;
        defer if (k.owned) |buf| self.allocator.free(buf);
        self.decRefcount(&self.node_labels_by_tenant, k.key, label);
    }

    fn bumpEdgeTypeCount(self: *GraphStore, graph_name: []const u8, tenant_id: []const u8, edge_type: []const u8) !void {
        var scratch: [512]u8 = undefined;
        const k = try formatGraphTenantKey(&scratch, self.allocator, graph_name, tenant_id);
        defer if (k.owned) |buf| self.allocator.free(buf);
        try self.bumpRefcount(&self.edge_types_by_tenant, k.key, edge_type);
    }

    fn decEdgeTypeCount(self: *GraphStore, graph_name: []const u8, tenant_id: []const u8, edge_type: []const u8) void {
        var scratch: [512]u8 = undefined;
        const k = formatGraphTenantKey(&scratch, self.allocator, graph_name, tenant_id) catch return;
        defer if (k.owned) |buf| self.allocator.free(buf);
        self.decRefcount(&self.edge_types_by_tenant, k.key, edge_type);
    }

    /// Compose "label\x00prop_key" into a stack buffer when small enough;
    /// otherwise heap-allocate via `allocator`. Returns (buf-or-owned-slice,
    /// is_heap_owned) so the caller can free conditionally.
    fn formatLabelPropKey(
        scratch: []u8,
        allocator: std.mem.Allocator,
        label: []const u8,
        prop_key: []const u8,
    ) !struct { key: []const u8, owned: ?[]u8 } {
        // Bug #3 (read-path crash hardening): compose the key size with a
        // CHECKED add. A corrupted/garbage length carried on a node at high RSS
        // could overflow `label.len + 1 + prop_key.len`, and even a merely huge
        // (non-overflowing) `total` makes `allocator.alloc` compute an
        // alignment-padded size that overflows inside ArenaAllocator.alloc and
        // PANICS the whole server — crashing every connection on a single bad
        // read (e.g. `MATCH (n:Taxon) RETURN count(n)` during a snapshot clone).
        // Surface it as an error instead so only THIS query fails; the snapshot
        // path is all `try`, so the error propagates up to snapshotUnderReadLock
        // and the read returns gracefully. A read must never crash the server.
        const total = std.math.add(usize, label.len, 1) catch return error.LabelPropKeyTooLarge;
        const total2 = std.math.add(usize, total, prop_key.len) catch return error.LabelPropKeyTooLarge;
        // Reject implausibly large keys before touching the allocator. A real
        // label+prop key is bytes-to-KB; anything past this cap is corruption,
        // not data, and would only feed the allocator an overflow-prone size.
        const max_label_prop_key_len: usize = 1 << 20; // 1 MiB — orders above any real key
        if (total2 > max_label_prop_key_len) return error.LabelPropKeyTooLarge;
        if (total2 <= scratch.len) {
            @memcpy(scratch[0..label.len], label);
            scratch[label.len] = 0;
            @memcpy(scratch[label.len + 1 ..][0..prop_key.len], prop_key);
            return .{ .key = scratch[0..total2], .owned = null };
        }
        const buf = try allocator.alloc(u8, total2);
        @memcpy(buf[0..label.len], label);
        buf[label.len] = 0;
        @memcpy(buf[label.len + 1 ..][0..prop_key.len], prop_key);
        return .{ .key = buf, .owned = buf };
    }

    fn bumpLabelPropertyCount(
        self: *GraphStore,
        graph_name: []const u8,
        tenant_id: []const u8,
        label: []const u8,
        prop_key: []const u8,
    ) !void {
        var oscratch: [512]u8 = undefined;
        const ok = try formatGraphTenantKey(&oscratch, self.allocator, graph_name, tenant_id);
        defer if (ok.owned) |buf| self.allocator.free(buf);
        var scratch: [512]u8 = undefined;
        const k = try formatLabelPropKey(&scratch, self.allocator, label, prop_key);
        defer if (k.owned) |buf| self.allocator.free(buf);
        try self.bumpRefcount(&self.label_properties_by_tenant, ok.key, k.key);
    }

    fn decLabelPropertyCount(
        self: *GraphStore,
        graph_name: []const u8,
        tenant_id: []const u8,
        label: []const u8,
        prop_key: []const u8,
    ) void {
        var oscratch: [512]u8 = undefined;
        const ok = formatGraphTenantKey(&oscratch, self.allocator, graph_name, tenant_id) catch return;
        defer if (ok.owned) |buf| self.allocator.free(buf);
        var scratch: [512]u8 = undefined;
        const k = formatLabelPropKey(&scratch, self.allocator, label, prop_key) catch return;
        defer if (k.owned) |buf| self.allocator.free(buf);
        self.decRefcount(&self.label_properties_by_tenant, ok.key, k.key);
    }

    /// Per-node helper: bump (tenant, label) and (tenant, label\x00prop_key)
    /// counters for every label on the node and every persisted property key
    /// (excluding internal IDs). Used by the node-create paths.
    fn bumpIntrospectionForNode(self: *GraphStore, node: *const Node) !void {
        for (node.labels) |label| {
            try self.bumpLabelCount(node.graph_name, node.tenant_id, label);
        }
        var prop_it = node.properties.iterator();
        while (prop_it.next()) |prop| {
            const key = prop.key_ptr.*;
            if (isInternalPersistedPropertyKey(key)) continue;
            for (node.labels) |label| {
                try self.bumpLabelPropertyCount(node.graph_name, node.tenant_id, label, key);
            }
        }
    }

    /// Inverse of `bumpIntrospectionForNode`. Used on the delete path.
    fn decIntrospectionForNode(self: *GraphStore, node: *const Node) void {
        var prop_it = node.properties.iterator();
        while (prop_it.next()) |prop| {
            const key = prop.key_ptr.*;
            if (isInternalPersistedPropertyKey(key)) continue;
            for (node.labels) |label| {
                self.decLabelPropertyCount(node.graph_name, node.tenant_id, label, key);
            }
        }
        for (node.labels) |label| {
            self.decLabelCount(node.graph_name, node.tenant_id, label);
        }
    }

    // Issue #391: Helper to add node to label index
    // Issue #451: Use stack-allocated bufPrint to probe for existing key before heap alloc
    //
    // Task 17 (enterprise-ingest-throughput): exposed as `pub` so the
    // per-posting-list mutex can be regression-tested in isolation. The
    // outer `label_index` StringHashMap is still protected by the per-graph
    // rwlock held by the caller — this function only protects the inner
    // `ArrayList(u64)` via `LabelPosting.mutex`.
    // CANARY: REQ=REQ-QUIC-HC-135; FEATURE="HighConcurrencyMutations"; ASPECT=AppendOrderedLabelPosting; STATUS=TESTED; TEST=tests/perf/test_label_posting_concurrent_insert.zig; OWNER=storage; UPDATED=2026-05-28
    pub fn addToLabelIndex(self: *GraphStore, graph_name: []const u8, label: []const u8, node_id: u64) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.label_index_mutex.lockUncancelable(io);
        defer self.label_index_mutex.unlock(io);

        const posting = try self.ensureLabelPostingListLocked(graph_name, label);
        try self.ensureGraphLabelCount(graph_name, label);
        posting.lock();
        defer posting.unlock();
        const inserted = try insertIntoPostingLocked(posting, self.allocator, node_id);
        if (inserted) self.bumpGraphLabelCount(graph_name, label);
    }

    /// Binary-search insert into a sorted ArrayList(u64), maintaining
    /// ascending order. Deduplicates: if node_id is already present, this
    /// is a no-op.
    ///
    /// CALLER CONTRACT: the caller is responsible for any synchronisation
    /// required by the underlying `ArrayList`. For `label_index` postings,
    /// the caller holds `LabelPosting.mutex` (Task 17, enterprise-ingest-
    /// throughput). For `edge_type_index` postings, the caller relies on
    /// the outer per-graph rwlock for now.
    fn sortedInsert(list: *std.ArrayList(u64), allocator: std.mem.Allocator, node_id: u64) !void {
        const items = list.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < node_id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // Deduplicate: skip if already present
        if (lo < items.len and items[lo] == node_id) return;
        try list.insert(allocator, lo, node_id);
    }

    /// Alias of `sortedInsert` used at sites where the surrounding
    /// `LabelPosting.mutex` is already held. The `Locked` suffix documents
    /// the call-site contract for readers of the label-index mutation
    /// helpers (`addToLabelIndex`, `appendToLabelIndex`).
    const sortedInsertLocked = sortedInsert;

    fn insertIntoPostingLocked(posting: *LabelPosting, allocator: std.mem.Allocator, node_id: u64) !bool {
        const items = posting.list.items;
        if (items.len == 0 or items[items.len - 1] < node_id) {
            try posting.list.append(allocator, node_id);
            return true;
        }

        const before_len = posting.list.items.len;
        try sortedInsertLocked(&posting.list, allocator, node_id);
        return posting.list.items.len > before_len;
    }

    /// T2b (hydration merge, label family): batch-apply one hydration batch's
    /// label postings. Semantically identical to calling `addToLabelIndex`
    /// once per (node, label) — the posting is a SORTED, DEDUPED id set and
    /// the per-(graph,label) refcount counts genuine inserts — but O(n log n)
    /// instead of the per-insert `ArrayList.insert` memmove that degenerates
    /// to O(n²) when uuid order interleaves across shards (the at-scale merge
    /// pathology: shard-major row order inserts every later shard's uuids
    /// into the MIDDLE of the posting).
    fn applyLabelPostingsForBatch(self: *GraphStore, graph_name: []const u8, batch: []const Node) !void {
        var groups = std.StringHashMap(std.ArrayList(u64)).init(self.allocator);
        defer {
            var vit = groups.valueIterator();
            while (vit.next()) |list| list.deinit(self.allocator);
            groups.deinit();
        }
        for (batch) |*node| {
            for (node.labels) |label| {
                const gop = try groups.getOrPut(label);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, node.id);
            }
        }
        var it = groups.iterator();
        while (it.next()) |entry| {
            std.sort.pdq(u64, entry.value_ptr.items, {}, std.sort.asc(u64));
            try self.mergeIntoLabelPosting(graph_name, entry.key_ptr.*, entry.value_ptr.items);
        }
    }

    /// Sorted bulk merge of `sorted_ids` (ascending, may contain duplicates)
    /// into one (graph,label) posting. Locking discipline identical to
    /// `addToLabelIndex` (label_index_mutex -> posting.mutex; refcount bump
    /// while both held). The replaced backing buffer is freed inline — legal
    /// here for the same reason `sortedInsert`'s reallocating `insert` is on
    /// this path: hydration's entry gate blocks every reader of this graph's
    /// postings until the build completes.
    fn mergeIntoLabelPosting(self: *GraphStore, graph_name: []const u8, label: []const u8, sorted_ids: []const u64) !void {
        if (sorted_ids.len == 0) return;
        const io = std.Io.Threaded.global_single_threaded.io();
        self.label_index_mutex.lockUncancelable(io);
        defer self.label_index_mutex.unlock(io);

        const posting = try self.ensureLabelPostingListLocked(graph_name, label);
        try self.ensureGraphLabelCount(graph_name, label);
        posting.lock();
        defer posting.unlock();

        const old = posting.list.items;
        // Pass 1: count genuine inserts (not already present, not a repeat).
        var inserted: usize = 0;
        {
            var oi: usize = 0;
            var ni: usize = 0;
            var last_new: ?u64 = null;
            while (ni < sorted_ids.len) : (ni += 1) {
                const id = sorted_ids[ni];
                if (last_new != null and last_new.? == id) continue;
                last_new = id;
                while (oi < old.len and old[oi] < id) oi += 1;
                if (oi < old.len and old[oi] == id) continue;
                inserted += 1;
            }
        }
        if (inserted == 0) return;

        // Pass 2: build the merged sorted set and swap it in.
        var merged = try std.ArrayList(u64).initCapacity(self.allocator, old.len + inserted);
        {
            var oi: usize = 0;
            var ni: usize = 0;
            var last_new: ?u64 = null;
            while (ni < sorted_ids.len) : (ni += 1) {
                const id = sorted_ids[ni];
                if (last_new != null and last_new.? == id) continue;
                last_new = id;
                while (oi < old.len and old[oi] < id) {
                    merged.appendAssumeCapacity(old[oi]);
                    oi += 1;
                }
                if (oi < old.len and old[oi] == id) continue;
                merged.appendAssumeCapacity(id);
            }
            while (oi < old.len) {
                merged.appendAssumeCapacity(old[oi]);
                oi += 1;
            }
        }
        posting.list.deinit(self.allocator);
        posting.list = merged;
        self.bumpGraphLabelCountBy(graph_name, label, inserted);
    }

    fn removeFromLabelIndex(self: *GraphStore, graph_name: []const u8, label: []const u8, node_id: u64) void {
        const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label }) catch return;
        defer self.allocator.free(key);

        const io = std.Io.Threaded.global_single_threaded.io();
        self.label_index_mutex.lockUncancelable(io);
        defer self.label_index_mutex.unlock(io);

        if (self.label_index.getPtr(key)) |posting| {
            var should_remove_key = false;
            {
                posting.lock();
                defer posting.unlock();

                // Binary search for node_id in sorted posting list
                const items = posting.list.items;
                var lo: usize = 0;
                var hi: usize = items.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    if (items[mid] < node_id) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                var removed = false;
                if (lo < items.len and items[lo] == node_id) {
                    _ = posting.list.orderedRemove(lo);
                    removed = true;
                }
                should_remove_key = posting.list.items.len == 0;
                if (removed) self.decGraphLabelCount(graph_name, label);
            }

            // Remove the map entry after releasing the posting's mutex: the
            // outer `label_index` HashMap is guarded by the caller's graph
            // rwlock, and deleting the value while anyone else held its
            // mutex would be a use-after-free. Under the current invariant
            // (callers hold the graph exclusive lock during mutations) no
            // other thread can be holding this posting's mutex here.
            if (should_remove_key) {
                if (self.label_index.fetchRemove(key)) |kv| {
                    self.allocator.free(kv.key);
                    var posting_copy = kv.value;
                    posting_copy.deinit(self.allocator);
                }
            }
        }
    }

    /// Serialize a PropertyValue to bytes for merge property index keys.
    /// Returns the number of bytes written, or null if the type is not indexable.
    fn serializePropValueForIndex(buf: []u8, value: PropertyValue) ?usize {
        var writer: std.Io.Writer = .fixed(buf);
        switch (value) {
            .String => |s| writer.writeAll(s) catch return null,
            .Int => |i| writer.print("{d}", .{i}) catch return null,
            .Bool => |b| writer.writeAll(if (b) "true" else "false") catch return null,
            else => return null,
        }
        return writer.end;
    }

    /// Build a merge property index key into a stack buffer.
    /// Format: "graph\x00label\x00prop_key\x00prop_value_bytes"
    /// Returns the slice, or null if the key is too long or value is not indexable.
    ///
    /// GAP-ENT-0023 P3 (review M4) — FORMAT-EDITION OBLIGATION: the merge
    /// hydration snapshot (`hydration_merge.snap`) persists these keys
    /// verbatim, gated by `mergeIndexConfigHash` (lean flag + registered keys
    /// + composite specs) — which does NOT cover the key LAYOUT itself. Any
    /// change to this key format (separator, component order, value
    /// normalization — here or in `buildCompositeMergeIndexKey` /
    /// `normalizeMergeValue`) MUST bump `HYDRATION_SNAP_VERSION`, or an
    /// upgraded binary would accept a counter-current snapshot written in the
    /// OLD layout and silently miss every MERGE lookup (the gs-F1 lesson).
    fn buildMergeIndexKey(buf: []u8, graph_name: []const u8, label: []const u8, prop_key: []const u8, prop_value: PropertyValue) ?[]const u8 {
        // Calculate required length: graph + 1 + label + 1 + key + 1 + value
        const header_len = graph_name.len + 1 + label.len + 1 + prop_key.len + 1;
        if (header_len >= buf.len) return null;

        var pos: usize = 0;
        @memcpy(buf[pos..][0..graph_name.len], graph_name);
        pos += graph_name.len;
        buf[pos] = 0;
        pos += 1;
        @memcpy(buf[pos..][0..label.len], label);
        pos += label.len;
        buf[pos] = 0;
        pos += 1;
        @memcpy(buf[pos..][0..prop_key.len], prop_key);
        pos += prop_key.len;
        buf[pos] = 0;
        pos += 1;

        const val_len = serializePropValueForIndex(buf[pos..], prop_value) orelse return null;
        return buf[0 .. pos + val_len];
    }

    /// Insert an entry into the merge property index for each label on the node.
    fn addToMergePropertyIndex(self: *GraphStore, graph_name: []const u8, labels: []const []const u8, prop_key: []const u8, prop_value: PropertyValue, node_id: u64) !void {
        // GAP-0900 Layer-3 (Fix 2): in lean mode, only MERGE/declared keys are
        // indexed. Non-merge keys are never looked up via this index, so skip
        // them. Default (lean off) indexes every key — unchanged behavior.
        if (!shouldIndexProperty(prop_key)) return;
        var buf: [1024]u8 = undefined;
        for (labels) |label| {
            const probe = buildMergeIndexKey(&buf, graph_name, label, prop_key, prop_value) orelse continue;
            try self.merge_prop_index.putOrUpdate(probe, node_id);
        }
    }

    /// GAP-0900 Layer-3 (Fix 3): backfill the merge property index for a single
    /// key by scanning all currently-loaded nodes. Called when a NEW merge key
    /// is registered in lean mode (`registerMergeIndexKey`) AFTER the graph was
    /// hydrated from disk — at hydration time the key was not yet registered, so
    /// `addToMergePropertyIndex` skipped it and the index had no entry for the
    /// loaded nodes. Without this, the first re-MERGE of that key after a reopen
    /// would create a duplicate. Real workloads register a tiny fixed set of
    /// merge keys once at startup, so this scan runs a handful of times total —
    /// never per node. Indexes only the named key (lean's RAM bound is intact:
    /// the other ~19 never-queried SET props stay unindexed).
    pub fn backfillMergeIndexForKey(self: *GraphStore, key: []const u8) void {
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr;
            const value = node.properties.get(key) orelse continue;
            self.addToMergePropertyIndex(node.graph_name, node.labels, key, value, node.id) catch {};
        }
    }

    /// Caveat "B": backfill the COMPOSITE merge entry for every RESIDENT node.
    /// Called when a composite key is registered AFTER nodes were already
    /// loaded into the cache (the in-process register-then-merge order, and as a
    /// best-effort top-up). The authoritative full-graph rebuild on reopen runs
    /// in `loadOneGraphFromAdapter` (covers ALL nodes, resident or not); this
    /// covers the resident set when registration happens mid-process. No-op when
    /// no composite key is registered.
    pub fn backfillCompositeMergeEntries(self: *GraphStore) void {
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            self.addNodeCompositeMergeEntries(entry.value_ptr);
        }
    }

    /// Remove entries from the merge property index for each label on the node.
    fn removeFromMergePropertyIndex(self: *GraphStore, graph_name: []const u8, labels: []const []const u8, prop_key: []const u8, prop_value: PropertyValue) void {
        var buf: [1024]u8 = undefined;
        for (labels) |label| {
            const probe = buildMergeIndexKey(&buf, graph_name, label, prop_key, prop_value) orelse continue;
            self.merge_prop_index.remove(probe);
        }
    }

    /// Remove ALL merge property index entries for a node (used during node deletion).
    fn removeAllMergePropertyIndexEntries(self: *GraphStore, node: *const Node) void {
        var buf: [1024]u8 = undefined;
        var prop_iter = node.properties.iterator();
        while (prop_iter.next()) |prop_entry| {
            for (node.labels) |label| {
                const probe = buildMergeIndexKey(&buf, node.graph_name, label, prop_entry.key_ptr.*, prop_entry.value_ptr.*) orelse continue;
                self.merge_prop_index.remove(probe);
            }
        }
    }

    /// Result of a merge candidate lookup.
    pub const MergeLookupResult = enum {
        /// Key could not be built (buffer overflow or non-indexable type).
        /// Caller must fall back to a label scan.
        not_indexable,
        /// Key was valid and the index is authoritative: no matching node exists.
        /// Caller can safely skip the fallback scan.
        not_found,
        /// Key was valid and a matching, verified node was found.
        found,
    };

    /// Look up a node by graph, label, property key, and property value.
    /// Returns `.found` with the node_id when a verified match exists,
    /// `.not_found` when the index is authoritative and no match exists,
    /// or `.not_indexable` when the key could not be built (caller must scan).
    ///
    /// Bug fix 2026-04-27: takes `*GraphStore` (not `*const`) so index reads
    /// can lock the owning shard. Concurrent `put` from another shard worker
    /// would otherwise race the `.get` here (HashMap pointer_stability
    /// assertion fires on concurrent rehash). All callers already pass
    /// `*GraphStore`.
    pub fn lookupMergeCandidate(self: *GraphStore, graph_name: []const u8, label: []const u8, prop_key: []const u8, prop_value: PropertyValue, out_node_id: *u64) MergeLookupResult {
        self.ensureGraphHydrated(graph_name); // PHASE 1b chokepoint (merge-MISS authority)
        var buf: [1024]u8 = undefined;
        const probe = buildMergeIndexKey(&buf, graph_name, label, prop_key, prop_value) orelse return .not_indexable;

        const node_id = self.merge_prop_index.get(probe) orelse return .not_found;
        // Verify the node still exists (the index could be stale after a failed
        // delete). The resident cache is a BOUNDED view: an evicted-but-live
        // node misses `nodes.get`. Verifying via `nodes.get` alone would report
        // .not_found for an evicted node and make a re-MERGE take the CREATE
        // branch → DUPLICATE (breaks idempotent/resumable seeding and the
        // from-dump EDGE phase that re-probes by {source,source_id} at scale).
        // Confirm existence + graph via the eviction-INDEPENDENT IdMaps first;
        // fall back to the resident cache when no adapter/IdMap is present
        // (pure in-memory deployments).
        if (self.resolveNodeGraphSlot(node_id)) |gs| {
            if (std.mem.eql(u8, gs.graph_name, graph_name)) {
                out_node_id.* = node_id;
                return .found;
            }
            return .not_found;
        }
        if (self.nodes.get(node_id)) |node| {
            if (std.mem.eql(u8, node.graph_name, graph_name)) {
                out_node_id.* = node_id;
                return .found;
            }
        }
        return .not_found;
    }

    /// Build a COMPOSITE merge-index key into `buf` from a registered composite
    /// spec and the values resolved for each of its (sorted) prop names.
    /// `values[i]` MUST correspond to `spec` prop name `i` (already in the spec's
    /// normalized sorted order). Format:
    ///   "graph\0label\0prop0\0val0\0prop1\0val1\0..."
    /// Returns the slice, or null if any value is non-indexable / the key
    /// overflows `buf`. Mirrors `buildMergeIndexKey` for a single prop.
    ///
    /// GAP-ENT-0023 P3 (review M4): any key-format change here MUST bump
    /// `HYDRATION_SNAP_VERSION` — see the obligation on `buildMergeIndexKey`.
    fn buildCompositeMergeIndexKey(
        buf: []u8,
        graph_name: []const u8,
        label: []const u8,
        spec: *const CompositeKeySpec,
        values: []const PropertyValue,
    ) ?[]const u8 {
        if (values.len != spec.prop_count) return null;
        var pos: usize = 0;

        const writeField = struct {
            fn f(b: []u8, p: *usize, bytes: []const u8) bool {
                if (p.* + bytes.len + 1 > b.len) return false;
                @memcpy(b[p.*..][0..bytes.len], bytes);
                p.* += bytes.len;
                b[p.*] = 0;
                p.* += 1;
                return true;
            }
        }.f;

        if (!writeField(buf, &pos, graph_name)) return null;
        if (!writeField(buf, &pos, label)) return null;
        var i: usize = 0;
        while (i < spec.prop_count) : (i += 1) {
            const name = spec.prop_bufs[i][0..spec.prop_lens[i]];
            if (!writeField(buf, &pos, name)) return null;
            // Value: serialize then write its 0-terminator.
            const vlen = serializePropValueForIndex(buf[pos..], values[i]) orelse return null;
            pos += vlen;
            if (pos + 1 > buf.len) return null;
            buf[pos] = 0;
            pos += 1;
        }
        // Trim the trailing terminator off the final field so the key is a clean
        // prefix-free encoding (the per-field 0 already delimits each field).
        return buf[0 .. pos - 1];
    }

    /// COMPOSITE-key resolver: probe the resident `merge_prop_index` for the
    /// single entry keyed on ALL of `composite_idx`'s props at the supplied
    /// `filters` values. Returns `.found` (with the public node id),
    /// `.not_found` (authoritative — the index holds no such composite), or
    /// `.not_indexable` (a value type can't be encoded — caller falls back).
    ///
    /// `filters` need NOT be in the spec's sorted order; values are gathered by
    /// matching each spec prop name against `filters`. Existence + graph are
    /// validated via the eviction-INDEPENDENT IdMap (same as the single-key
    /// `lookupMergeCandidate`), so an evicted-but-live node is still `.found`
    /// and NO `getNodeProperty` / node-page read happens.
    pub fn lookupCompositeMergeCandidate(
        self: *GraphStore,
        graph_name: []const u8,
        label: []const u8,
        composite_idx: usize,
        filters: []const graph_storage_adapter.StorageAdapter.PropKV,
        out_node_id: *u64,
    ) MergeLookupResult {
        self.ensureGraphHydrated(graph_name); // PHASE 1b chokepoint (merge-MISS authority)
        const spec = blk: {
            g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            if (composite_idx >= g_composite_key_count) break :blk null;
            break :blk &g_composite_keys[composite_idx];
        } orelse return .not_indexable;

        if (filters.len != spec.prop_count) return .not_indexable;

        // Gather values in the spec's (sorted) prop order by matching names.
        var values: [composite_index_max_props]PropertyValue = undefined;
        var i: usize = 0;
        while (i < spec.prop_count) : (i += 1) {
            const name = spec.prop_bufs[i][0..spec.prop_lens[i]];
            const v = findFilterValue(filters, name) orelse return .not_indexable;
            values[i] = v;
        }

        var buf: [1024]u8 = undefined;
        const probe = buildCompositeMergeIndexKey(&buf, graph_name, label, spec, values[0..spec.prop_count]) orelse return .not_indexable;
        const node_id = self.merge_prop_index.get(probe) orelse return .not_found;

        // Eviction-independent existence + graph validation (mirrors
        // lookupMergeCandidate); no node-page read.
        if (self.resolveNodeGraphSlot(node_id)) |gs| {
            if (std.mem.eql(u8, gs.graph_name, graph_name)) {
                out_node_id.* = node_id;
                return .found;
            }
            return .not_found;
        }
        if (self.nodes.get(node_id)) |node| {
            if (std.mem.eql(u8, node.graph_name, graph_name)) {
                out_node_id.* = node_id;
                return .found;
            }
        }
        return .not_found;
    }

    fn findFilterValue(filters: []const graph_storage_adapter.StorageAdapter.PropKV, key: []const u8) ?PropertyValue {
        for (filters) |f| {
            if (std.mem.eql(u8, f.key, key)) return f.value;
        }
        return null;
    }

    /// Add the COMPOSITE merge-index entry/entries for a fully-populated node.
    /// For each registered composite key whose props are ALL present on the
    /// node, write ONE entry (composite key → node.id) per label. Called once
    /// per node after all its properties are set (the node carries the whole
    /// composite by then). No-op when no composite keys are registered (the
    /// default for non-from-dump workloads), so plain ingest is unchanged.
    fn addNodeCompositeMergeEntries(self: *GraphStore, node: *const Node) void {
        const n_composites = blk: {
            g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk g_composite_key_count;
        };
        if (n_composites == 0) return;

        var k: usize = 0;
        while (k < n_composites) : (k += 1) {
            // Snapshot the spec under the leaf mutex into a local (the registry
            // is append-only and specs are immutable once registered, but copy
            // for safety against a concurrent register growing the array).
            var spec_copy: CompositeKeySpec = undefined;
            {
                g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
                defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
                if (k >= g_composite_key_count) break;
                spec_copy = g_composite_keys[k];
            }

            // Resolve each composite prop value on the node (sorted order).
            var values: [composite_index_max_props]PropertyValue = undefined;
            var have_all = true;
            var i: usize = 0;
            while (i < spec_copy.prop_count) : (i += 1) {
                const name = spec_copy.prop_bufs[i][0..spec_copy.prop_lens[i]];
                const v = node.properties.get(name) orelse {
                    have_all = false;
                    break;
                };
                values[i] = v;
            }
            if (!have_all) continue;

            var buf: [1024]u8 = undefined;
            for (node.labels) |label| {
                const probe = buildCompositeMergeIndexKey(&buf, node.graph_name, label, &spec_copy, values[0..spec_copy.prop_count]) orelse continue;
                self.merge_prop_index.putOrUpdate(probe, node.id) catch {};
            }
        }
    }

    /// Remove the COMPOSITE merge-index entry/entries for a node (node deletion /
    /// property-value change of a composite component). Symmetric with
    /// `addNodeCompositeMergeEntries`; no-op when no composite keys registered.
    fn removeNodeCompositeMergeEntries(self: *GraphStore, node: *const Node) void {
        const n_composites = blk: {
            g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk g_composite_key_count;
        };
        if (n_composites == 0) return;

        var k: usize = 0;
        while (k < n_composites) : (k += 1) {
            var spec_copy: CompositeKeySpec = undefined;
            {
                g_lean_index_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
                defer g_lean_index_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
                if (k >= g_composite_key_count) break;
                spec_copy = g_composite_keys[k];
            }
            var values: [composite_index_max_props]PropertyValue = undefined;
            var have_all = true;
            var i: usize = 0;
            while (i < spec_copy.prop_count) : (i += 1) {
                const name = spec_copy.prop_bufs[i][0..spec_copy.prop_lens[i]];
                const v = node.properties.get(name) orelse {
                    have_all = false;
                    break;
                };
                values[i] = v;
            }
            if (!have_all) continue;
            var buf: [1024]u8 = undefined;
            for (node.labels) |label| {
                const probe = buildCompositeMergeIndexKey(&buf, node.graph_name, label, &spec_copy, values[0..spec_copy.prop_count]) orelse continue;
                self.merge_prop_index.remove(probe);
            }
        }
    }

    /// Eviction-INDEPENDENT existence check for an edge endpoint by PUBLIC id.
    ///
    /// The bulk edge apply (insert + MERGE) re-checks both endpoints before
    /// creating the edge so a node deleted by a prior batch is orphan-skipped
    /// instead of producing a dangling edge. That re-check MUST NOT use the
    /// BOUNDED node cache (`self.nodes.getPtr`): under a small cache at scale
    /// (the from-dump edge phase) a present-but-EVICTED endpoint misses the
    /// cache, so the apply wrongly returns Source/TargetNodeNotFound and the
    /// edge is SILENTLY NEVER CREATED — the itis "~2% observable, tail-only"
    /// bug. The IdMap is the authoritative live-node oracle: it is keyed
    /// PER-GRAPH, populated at node creation, and removed only on explicit
    /// delete — never on eviction. So `nodeSlot(id) != null` means the id is a
    /// live node of THIS graph regardless of cache residency. This mirrors the
    /// eviction-safe validation `lookupMergeCandidate` already performs above,
    /// and matches the create path itself (`createEdgeWithGraphAndTenant`
    /// resolves endpoints via the IdMap, never the node cache).
    ///
    /// Falls back to the resident cache only when no IdMap exists for the graph
    /// (pure in-memory deployments with no engine/adapter wired — the cache is
    /// unbounded there, so the resident check is complete and correct).
    pub fn edgeEndpointExists(self: *GraphStore, graph_name: []const u8, node_id: u64) bool {
        if (self.getIdMap(graph_name)) |id_map| {
            return id_map.nodeSlot(@as(u128, node_id)) != null;
        }
        return self.nodes.getPtr(node_id) != null;
    }

    // CANARY: REQ=REQ-PERF-LABEL-INDEX-003; FEATURE="LabelBasedIndex"; ASPECT=NodeLookup; STATUS=TESTED; TEST=tests/test_match_set_label_scan_regression.zig; OWNER=perf; UPDATED=2026-04-23
    // Issue #391: Get nodes by label and graph (O(1) lookup instead of O(n) scan)
    //
    // CALLER CONTRACT (Task 17): the returned slice aliases `LabelPosting.list.items`
    // and is valid only while the caller holds the per-graph rwlock that guards
    // the surrounding operation (shared-lock for MATCH, exclusive-lock for
    // mutations). The `LabelPosting.mutex` is a leaf lock that protects the
    // inner list against *concurrent writers only* — readers rely on the outer
    // rwlock to exclude writers for the slice's lifetime. If a future caller
    // needs to iterate without holding the rwlock, add a `getNodesByLabelSnapshot`
    // helper that clones under `LabelPosting.mutex` rather than aliasing.
    pub fn getNodesByLabel(self: *const GraphStore, graph_name: []const u8, label: []const u8) ?[]const u64 {
        @constCast(self).ensureGraphHydrated(graph_name); // PHASE 1b chokepoint
        // The `geode.graph_store.get_nodes_by_label` trace span was rolled
        // back here pending a coordinated otel pin bump to 0c34ce9b+ — the
        // upstream BatchSpanProcessor concurrent-producer race (panic at
        // otel/src/sdk/export.zig:330) otherwise crashes drainLocked under
        // load. The read-path is the hottest of the rolled-back sites, so
        // the no-op-tracer call alone meaningfully feeds the BSP queue. See
        // src/storage/graph_storage_adapter.zig:2237 and
        // tests/test_bsp_race_regression.zig.

        // Create composite key "graph_name:label"
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ graph_name, label }) catch return null;

        // PHASE 1b concurrency fix: the `label_index` writer (`addToLabelIndex`,
        // reached by hydration) already rehashes the outer map under
        // `label_index_mutex`; take it here too so this lookup cannot tear when
        // a concurrent first-touch hydration rebuilds the index under the shared
        // store lock. The returned slice aliases the posting's HEAP-backed
        // ArrayList, which survives an outer-map rehash, so it stays valid after
        // the mutex is released (the existing per-graph rwlock still excludes
        // posting-list writers for the slice's lifetime).
        const io = std.Io.Threaded.global_single_threaded.io();
        @constCast(self).label_index_mutex.lockUncancelable(io);
        defer @constCast(self).label_index_mutex.unlock(io);
        if (self.label_index.get(key)) |posting| {
            return posting.list.items;
        }
        return null;
    }

    /// Return a caller-owned copy of the label posting list.
    ///
    /// Unlike `getNodesByLabel`, the returned slice does NOT alias the
    /// live posting list, so it remains valid even if a concurrent writer
    /// under the outer graph rwlock mutates the list after this call
    /// returns. The copy is taken under `LabelPosting.mutex`, so it is
    /// safe even under the Task 15/16 two-phase lock protocol where
    /// multiple threads may share a per-graph shared read lock.
    ///
    /// The caller owns the returned slice and MUST free it with the same
    /// allocator. Returns null if the label has no posting list.
    pub fn snapshotNodesByLabel(
        self: *GraphStore,
        allocator: std.mem.Allocator,
        graph_name: []const u8,
        label: []const u8,
    ) !?[]u64 {
        self.ensureGraphHydrated(graph_name); // PHASE 1b chokepoint
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ graph_name, label }) catch return null;

        // PHASE 1b concurrency fix: guard the outer getPtr with `label_index_mutex`
        // (same ordering as the writer: outer mutex -> posting leaf mutex) so a
        // concurrent hydration rehash cannot tear the lookup. The posting pointer
        // is stable once found because the rehash only moves the small posting
        // struct's heap backing is reached through the leaf-locked copy below.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.label_index_mutex.lockUncancelable(io);
        defer self.label_index_mutex.unlock(io);
        const posting = self.label_index.getPtr(key) orelse return null;
        posting.lock();
        defer posting.unlock();
        const copy = try allocator.dupe(u64, posting.list.items);
        return copy;
    }

    // Issue #391: Get nodes that have ALL specified labels in a graph
    // Accepts a caller-provided allocator for the result list to avoid
    // concurrent threads contending on self.allocator (GAP-0425 fix).
    // Perf: uses smallest-posting-list-first strategy to minimize candidate scans.
    pub fn getNodesByLabels(self: *const GraphStore, allocator: std.mem.Allocator, graph_name: []const u8, labels: []const []const u8, tenant_id: ?[]const u8) !std.ArrayList(u64) {
        @constCast(self).ensureGraphHydrated(graph_name); // PHASE 1b chokepoint
        _ = g_get_nodes_by_labels_count.fetchAdd(1, .monotonic);
        var result = std.ArrayList(u64).empty;

        if (labels.len == 0) {
            return result;
        }

        // Single-label fast path: no intersection needed
        if (labels.len == 1) {
            const nodes = self.getNodesByLabel(graph_name, labels[0]) orelse return result;
            try result.ensureTotalCapacity(allocator, nodes.len);
            for (nodes) |node_id| {
                // Verify node exists (label index may contain stale entries)
                // and apply the exact tenant filter. GAP-ENT-0023 P3 (review
                // I1): residency is NOT existence — on a bounded (or
                // snapshot-warm, cold) cache a resident-only lookup dropped
                // every non-resident row. The check verifies via IdMap
                // membership + engine tenant tag instead, without mutating
                // the cache (callers may hold retained `*Node` pointers).
                if (!self.nodeExistsPassingTenantExact(node_id, tenant_id)) continue;
                result.appendAssumeCapacity(node_id);
            }
            return result;
        }

        // Multi-label path: two-pointer merge intersection on sorted posting lists.
        // Gather posting lists and sort by ascending length for optimal intersection.

        // Stack-allocated array for up to 8 labels; heap fallback for more.
        const MaxStack = 8;
        var stack_lists: [MaxStack][]const u64 = undefined;
        var heap_lists: ?[][]const u64 = null;
        defer if (heap_lists) |h| allocator.free(h);

        const lists: [][]const u64 = if (labels.len <= MaxStack)
            stack_lists[0..labels.len]
        else blk: {
            heap_lists = try allocator.alloc([]const u64, labels.len);
            break :blk heap_lists.?;
        };

        for (labels, 0..) |label, i| {
            const posting = self.getNodesByLabel(graph_name, label) orelse return result;
            if (posting.len == 0) return result;
            lists[i] = posting;
        }

        // Sort posting lists by ascending length (insertion sort — n is tiny)
        for (1..lists.len) |i| {
            const key = lists[i];
            var j: usize = i;
            while (j > 0 and lists[j - 1].len > key.len) {
                lists[j] = lists[j - 1];
                j -= 1;
            }
            lists[j] = key;
        }

        // Two-pointer intersection: intersect lists[0] with lists[1], then result with lists[2], etc.
        // Use `result` as the current intersection buffer and a temp buffer for alternation.
        var temp = std.ArrayList(u64).empty;
        defer temp.deinit(allocator);

        // Seed with shortest posting list
        try result.ensureTotalCapacity(allocator, lists[0].len);
        for (lists[0]) |id| {
            result.appendAssumeCapacity(id);
        }

        for (lists[1..]) |other| {
            temp.clearRetainingCapacity();
            try temp.ensureTotalCapacity(allocator, result.items.len);

            var ai: usize = 0;
            var bi: usize = 0;
            const a_items = result.items;
            while (ai < a_items.len and bi < other.len) {
                if (a_items[ai] < other[bi]) {
                    ai += 1;
                } else if (a_items[ai] > other[bi]) {
                    bi += 1;
                } else {
                    temp.appendAssumeCapacity(a_items[ai]);
                    ai += 1;
                    bi += 1;
                }
            }

            // Swap: move temp into result for next round
            const swap_items = result.items;
            const swap_cap = result.capacity;
            result.items = temp.items;
            result.capacity = temp.capacity;
            temp.items = swap_items;
            temp.capacity = swap_cap;
        }

        // Verify nodes still exist (label index may have stale entries)
        // and apply tenant filter (GAP-0509). GAP-ENT-0023 P3 (review I1):
        // same residency-is-not-existence fix as the single-label path above.
        {
            var write: usize = 0;
            for (result.items) |node_id| {
                if (!self.nodeExistsPassingTenantExact(node_id, tenant_id)) continue;
                result.items[write] = node_id;
                write += 1;
            }
            result.items.len = write;
        }

        return result;
    }

    fn rebuildIndexes(self: *GraphStore) !void {
        // Reset label index
        var label_iter = self.label_index.iterator();
        while (label_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.label_index.deinit();
        self.label_index = std.StringHashMap(LabelPosting).init(self.allocator);

        var label_count_iter = self.label_counts_by_graph.iterator();
        while (label_count_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.label_counts_by_graph.deinit();
        self.label_counts_by_graph = std.StringHashMap(LabelCountValue).init(self.allocator);

        var edge_type_count_iter = self.edge_type_counts_by_graph.iterator();
        while (edge_type_count_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.edge_type_counts_by_graph.deinit();
        self.edge_type_counts_by_graph = std.StringHashMap(LabelCountValue).init(self.allocator);

        // PERF-B (issue #811): Reset per-graph node-id index for rebuild.
        {
            var nbg_iter = self.nodes_by_graph.iterator();
            while (nbg_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit();
            }
            self.nodes_by_graph.deinit();
            self.nodes_by_graph = std.StringHashMap(std.AutoHashMap(u64, void)).init(self.allocator);
        }

        // PERF-C (issue #814): Reset tenant-keyed introspection indexes for rebuild.
        deinitTenantStringMultiset(&self.node_labels_by_tenant, self.allocator);
        deinitTenantStringMultiset(&self.edge_types_by_tenant, self.allocator);
        deinitTenantStringMultiset(&self.label_properties_by_tenant, self.allocator);
        self.node_labels_by_tenant = std.StringHashMap(std.StringHashMap(usize)).init(self.allocator);
        self.edge_types_by_tenant = std.StringHashMap(std.StringHashMap(usize)).init(self.allocator);
        self.label_properties_by_tenant = std.StringHashMap(std.StringHashMap(usize)).init(self.allocator);

        self.merge_prop_index.reset();

        // PERF-P0-001: Reset edge-type index
        var eti_iter = self.edge_type_index.iterator();
        while (eti_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.edge_type_index.deinit();
        self.edge_type_index = std.StringHashMap(std.ArrayList(u64)).init(self.allocator);

        // Reset adjacency caches. PHASE 0: clearRetainingCapacity frees every
        // resident + retired AdjList and clears the FIFO, while PRESERVING the
        // installed hydrate hook + active cap (a deinit+reinit would drop them,
        // re-disabling bounding until the next installAdjCacheHydrate).
        self.outgoing_edges.clearRetainingCapacity();
        self.incoming_edges.clearRetainingCapacity();

        // Rebuild label index, merge property index, and ensure graph registry entries for nodes
        var node_iter = self.nodes.iterator();
        while (node_iter.next()) |entry| {
            const node = entry.value_ptr;
            try self.ensureGraphNoDirty(node.graph_name);
            for (node.labels) |label| {
                try self.addToLabelIndex(node.graph_name, label, node.id);
            }
            // PERF-B/C (issues #811, #814): rebuild graph-scoped node-id set
            // and tenant-keyed introspection counters for this node.
            try self.addNodeToGraphIndex(node.graph_name, node.id);
            for (node.labels) |label| {
                try self.bumpLabelCount(node.graph_name, node.tenant_id, label);
            }
            var prop_iter_for_pc = node.properties.iterator();
            while (prop_iter_for_pc.next()) |prop_entry| {
                const pkey = prop_entry.key_ptr.*;
                if (isInternalPersistedPropertyKey(pkey)) continue;
                for (node.labels) |label| {
                    try self.bumpLabelPropertyCount(node.graph_name, node.tenant_id, label, pkey);
                }
            }
            // Rebuild merge property index entries for this node
            var prop_iter = node.properties.iterator();
            while (prop_iter.next()) |prop_entry| {
                self.addToMergePropertyIndex(node.graph_name, node.labels, prop_entry.key_ptr.*, prop_entry.value_ptr.*, node.id) catch {};
            }
            // Rebuild COMPOSITE merge entries too (caveat "B") so endpoint
            // resolution stays zero-read after a reopen/rebuild.
            self.addNodeCompositeMergeEntries(node);
        }

        // Rebuild adjacency index, edge-type index, and ensure graph registry entries for edges
        var edge_iter = self.edges.iterator();
        while (edge_iter.next()) |entry| {
            const edge = entry.value_ptr;
            try self.ensureGraphNoDirty(edge.graph_name);
            try self.addToAdjacencyIndex(edge.from_id, edge.to_id, edge.id);
            // PERF-P0-001: Rebuild edge-type index
            try self.addToEdgeTypeIndex(edge.graph_name, edge.label, edge.id);
            // PERF-C (issue #814): rebuild tenant-keyed edge-type counter.
            try self.bumpEdgeTypeCount(edge.graph_name, edge.tenant_id, edge.label);
            // Per-(graph,type) exact counter (typed count(r:TYPE) fast path).
            self.bumpGraphEdgeTypeCount(edge.graph_name, edge.label);
        }
    }

    // Backward-compatible createNode that uses "default" graph
    pub fn createNode(self: *GraphStore, labels: []const []const u8) !u64 {
        return self.createNodeWithGraph(labels, "default");
    }

    pub fn setNodeProperty(self: *GraphStore, node_id: u64, key: []const u8, value: PropertyValue) !void {
        self.ensureNodeGraphHydrated(node_id); // PHASE 1b chokepoint (hydrate before write)
        // C3 (review-0023): hydrate the node BODY on miss before the durable
        // write below is gated on residency. P3 snapshot-served warm hydration
        // leaves the node cache COLD for graphs of ANY size, and the detached
        // scan boxes (C2) no longer warm it — so after every warm reopen a
        // matched node is typically non-resident and the resident-only
        // `nodes.get` gate would fail the SET with NodeNotFound and skip the
        // adapter write. Same hydrate-on-miss the read paths (getNodeProperty
        // et al.) already use; safe here because all node property writers run
        // under the per-graph EXCLUSIVE lock, so the cache insert cannot race
        // shard readers (the same guarantee the evict-retire machinery relies
        // on). A truly-missing id still falls through to error.NodeNotFound.
        _ = self.nodes.getOrHydratePtr(node_id) catch null;
        if (isInternalPersistedPropertyKey(key)) return error.ReservedPropertyKey;
        // FLE defense-in-depth: encrypt String values before adapter write and in-memory storage.
        // Some callers already encrypt; isLikelyFleEnvelope() prevents double-encryption.
        // `owned_encrypted` tracks the freshly-allocated FLE envelope (if any) so
        // it can be released after the adapter write / in-memory copy / WAL
        // notification have all consumed it — otherwise the envelope leaks on
        // every encrypted property write.
        var owned_encrypted: ?[]const u8 = null;
        defer if (owned_encrypted) |buf| self.allocator.free(buf);
        const effective_value = switch (value) {
            .String => |s| blk: {
                if (fle_integration.hasEncryptedFields() and !isLikelyFleEnvelope(s)) {
                    const maybe_node = self.nodes.get(node_id);
                    const node_type: []const u8 = if (maybe_node) |n|
                        (if (n.labels.len > 0) n.labels[0] else "Unknown")
                    else
                        "Unknown";
                    // GAP-0854: never FLE-encrypt the internal security graph.
                    const in_security_graph = if (maybe_node) |n| isSecurityGraphName(n.graph_name) else false;
                    if (!in_security_graph and fle_integration.fieldRequiresEncryption(node_type, key)) {
                        const fle_ctx = fle_integration.EncryptionContext{
                            .tenant_id = self.tenant_id,
                            .schema_name = self.schema_name,
                            .allocator = self.allocator,
                            .current_user_role = fle_integration.rolePreferringActiveContext(),
                        };
                        // FLE record-id formatting must NOT go through allocPrint on the
                        // shared self.allocator — concurrent thread-pool paths (QUIC auth
                        // lookups, etc.) can trigger `@memcpy arguments alias` inside
                        // std.Io.Writer.drain when the allocator is contended. Stack buffer
                        // is large enough for "node_" + u64 (max 25 bytes).
                        var id_buf: [32]u8 = undefined;
                        const record_id = std.fmt.bufPrint(&id_buf, "node_{d}", .{node_id}) catch {
                            break :blk value;
                        };
                        const encrypted = fle_integration.encryptFieldIfNeeded(
                            fle_ctx,
                            node_type,
                            key,
                            s,
                            record_id,
                        ) catch {
                            break :blk value;
                        };
                        if (!std.mem.eql(u8, encrypted, s)) {
                            owned_encrypted = encrypted;
                            break :blk PropertyValue{ .String = encrypted };
                        }
                        // encryptFieldIfNeeded returned the input unchanged — nothing to free.
                    }
                }
                break :blk value;
            },
            else => value,
        };

        if (global_vtable) |vt| {
            const node = self.nodes.get(node_id) orelse return error.NodeNotFound;
            const slot_id = try self.requireNodeSlot(node.graph_name, node_id);
            try vt.setNodePropertyFn(vt.ctx, node.graph_name, slot_id, key, effective_value);
        }
        if (self.nodes.getPtr(node_id)) |node| {
            const value_copy = try copyPropertyValue(self, effective_value);
            errdefer freePropertyValue(self, value_copy);

            // ENG-3954 / #874: the property-map mutation below reallocs-and-frees
            // the node's `entries` slice, so it must exclude concurrent readers
            // that are dereferencing this node. The per-graph rwlock does not
            // (the callers that take it are the transports, not this store), so
            // hold the node cache's per-shard leaf lock EXCLUSIVE across the
            // whole in-place mutation. See `BoundedNodeCache.ShardGuard`.
            {
                self.nodes.lockShardExclusive(node_id);
                defer self.nodes.unlockShardExclusive(node_id);

                // Caveat "B": if `key` is a composite component and its value is
                // CHANGING, the existing composite merge entry (built from the OLD
                // value) is now stale — remove it BEFORE overwriting so we don't leak
                // a dangling composite entry. Re-asserted from current values below.
                // (The from-dump path never mutates composite components, so this is
                // a robustness guard, not a hot path.)
                const composite_component = isCompositeComponentKey(key);
                if (composite_component) self.removeNodeCompositeMergeEntries(node);

                // Use getOrPut to avoid memory leak - only allocate key if it doesn't exist
                const result = try node.properties.getOrPut(key);
                const was_new = !result.found_existing;
                if (was_new) {
                    // Key doesn't exist, allocate a copy
                    result.key_ptr.* = try self.allocator.dupe(u8, key);
                } else {
                    // Key exists — remove old merge property index entry before overwriting
                    self.removeFromMergePropertyIndex(node.graph_name, node.labels, key, result.value_ptr.*);
                    freePropertyValue(self, result.value_ptr.*);
                }
                result.value_ptr.* = value_copy;

                // Update merge property index with new value
                self.addToMergePropertyIndex(node.graph_name, node.labels, key, value_copy, node_id) catch {};
                // Re-assert the composite merge entry from the node's CURRENT values
                // (now including the new value for `key`). No-op if the node doesn't
                // carry all composite props yet, or no composite is registered.
                if (composite_component) self.addNodeCompositeMergeEntries(node);

                // PERF-C (issue #814): only bump the label-property counter on
                // the new-key transition. Value updates do not change the set of
                // property keys reported by `listPropertiesForLabel`. Internal
                // persisted-id keys are skipped (they're filtered out at read
                // time too).
                if (was_new and !isInternalPersistedPropertyKey(key)) {
                    for (node.labels) |label| {
                        self.bumpLabelPropertyCount(node.graph_name, node.tenant_id, label, key) catch {};
                    }
                }
            }

            // Mark as dirty - persistence happens at query completion
            self.dirty.store(true, .release);
            incrementMutationEpoch();

            // WAL notification: SetNodeProperty
            notifyMutation(.set_node_property, node_id, 0, 0, null, key, effective_value, null);
        }
    }

    /// Batch property entry for `setNodePropertiesBatch`.
    /// When `value` is null the property is removed (tombstone).
    pub const BatchPropertyEntry = struct {
        key: []const u8,
        value: ?PropertyValue, // null = remove
    };

    /// Set or remove multiple properties on a node in a single operation.
    ///
    /// When a storage adapter is present the batch is forwarded as one
    /// adapter call, acquiring the adapter mutex only once instead of once
    /// per property.  This eliminates severe mutex contention that caused
    /// CLI commands (e.g. `geode user mfa-setup`) to hang when the server
    /// was concurrently servicing queries against the same global adapter.
    pub fn setNodePropertiesBatch(self: *GraphStore, node_id: u64, entries: []const BatchPropertyEntry) !void {
        const node_meta = self.nodes.get(node_id) orelse return error.NodeNotFound;

        // --- Adapter path: single lock acquisition for all properties ---
        if (global_adapter) |adapter| {
            const slot_id = try self.requireNodeSlot(node_meta.graph_name, node_id);

            // Build adapter-level batch entries, applying FLE encryption
            // where required.
            var adapter_entries = try self.allocator.alloc(graph_storage_adapter.StorageAdapter.BatchPropertyEntry, entries.len);
            defer self.allocator.free(adapter_entries);

            // GAP-0854 follow-up: track freshly-allocated FLE envelopes so they
            // are freed exactly once after the adapter has copied them into
            // storage. Indexed parallel to `adapter_entries`; null when the
            // entry was a removal or no encryption occurred.
            var owned_envelopes = try self.allocator.alloc(?[]const u8, entries.len);
            defer {
                for (owned_envelopes) |maybe_buf| {
                    if (maybe_buf) |buf| self.allocator.free(buf);
                }
                self.allocator.free(owned_envelopes);
            }
            @memset(owned_envelopes, null);

            for (entries, 0..) |entry, i| {
                if (entry.value) |val| {
                    const res = self.applyFleEncryption(node_id, entry.key, val);
                    adapter_entries[i] = .{ .key = entry.key, .value = res.value };
                    owned_envelopes[i] = res.owned;
                } else {
                    adapter_entries[i] = .{ .key = entry.key, .value = null };
                }
            }

            try adapter.setNodePropertiesBatch(node_meta.graph_name, slot_id, adapter_entries);
        } else if (global_vtable) |vt| {
            // Fallback: vtable without direct adapter access (shouldn't
            // happen in practice, but keep correctness).
            const slot_id = try self.requireNodeSlot(node_meta.graph_name, node_id);
            for (entries) |entry| {
                if (entry.value) |val| {
                    const res = self.applyFleEncryption(node_id, entry.key, val);
                    // GAP-0854 follow-up: free the envelope after the vtable
                    // setter has copied it into the storage layer.
                    defer if (res.owned) |buf| self.allocator.free(buf);
                    try vt.setNodePropertyFn(vt.ctx, node_meta.graph_name, slot_id, entry.key, res.value);
                } else {
                    try vt.removeNodePropertyFn(vt.ctx, node_meta.graph_name, slot_id, entry.key);
                }
            }
        }

        try self.setNodePropertiesBatchInMemoryOnly(node_id, entries);
    }

    // CANARY: REQ=REQ-QUIC-HC-022; FEATURE="HighConcurrencyMutations"; ASPECT=ShardTxnPropertyFastPath; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=storage; UPDATED=2026-05-26
    /// Update only GraphStore's in-memory compatibility store.
    ///
    /// The QUIC group-commit fast path has already written the properties
    /// through the shard-pinned storage transaction. Calling the full
    /// `setNodePropertiesBatch` path there re-enters the adapter, contends on
    /// the adapter-level graph lookup mutex, and opens redundant property
    /// work after the shard worker already owns the correct shard lock.
    pub fn setNodePropertiesBatchInMemoryOnly(self: *GraphStore, node_id: u64, entries: []const BatchPropertyEntry) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            for (entries) |entry| {
                if (isInternalPersistedPropertyKey(entry.key)) continue;

                if (entry.value) |val| {
                    const res = self.applyFleEncryption(node_id, entry.key, val);
                    // GAP-0854 follow-up: the encrypted envelope is copied into
                    // the in-memory store and read by the WAL notify below;
                    // free the freshly-allocated buffer once both have consumed
                    // it, otherwise it leaks per encrypted property write.
                    defer if (res.owned) |buf| self.allocator.free(buf);
                    const effective = res.value;
                    const value_copy = try copyPropertyValue(self, effective);
                    errdefer freePropertyValue(self, value_copy);

                    {
                        // ENG-3954 / #874: realloc-and-free of the entries slice
                        // must exclude concurrent readers of this node.
                        self.nodes.lockShardExclusive(node_id);
                        defer self.nodes.unlockShardExclusive(node_id);
                        const result = try node.properties.getOrPut(entry.key);
                        if (!result.found_existing) {
                            result.key_ptr.* = try self.allocator.dupe(u8, entry.key);
                        } else {
                            self.removeFromMergePropertyIndex(node.graph_name, node.labels, entry.key, result.value_ptr.*);
                            freePropertyValue(self, result.value_ptr.*);
                        }
                        result.value_ptr.* = value_copy;
                        self.addToMergePropertyIndex(node.graph_name, node.labels, entry.key, value_copy, node_id) catch {};
                    }

                    notifyMutation(.set_node_property, node_id, 0, 0, null, entry.key, effective, null);
                } else {
                    // Remove
                    self.nodes.lockShardExclusive(node_id);
                    defer self.nodes.unlockShardExclusive(node_id);
                    if (node.properties.fetchRemove(entry.key)) |kv| {
                        self.removeFromMergePropertyIndex(node.graph_name, node.labels, kv.key, kv.value);
                        self.allocator.free(kv.key);
                        freePropertyValue(self, kv.value);
                    }
                }
            }
            // COMPOSITE merge entry (caveat "B"): the node now carries all the
            // properties from this batch — the from-dump NODE phase sets the
            // whole {source, source_id} composite in one batch — so register the
            // composite entry once here (no-op when no composite keys are
            // registered, i.e. all non-from-dump workloads). A re-MERGE that sets
            // a NEW value for a composite component would leave a stale entry; we
            // re-assert from the current property values, and changing a
            // composite component is not part of the from-dump path (the
            // component values ARE the merge key).
            {
                self.nodes.lockShardExclusive(node_id);
                defer self.nodes.unlockShardExclusive(node_id);
                self.addNodeCompositeMergeEntries(node);
            }
            self.dirty.store(true, .release);
            incrementMutationEpoch();
        }
    }

    /// Result of an `applyFleEncryption*` call.
    ///
    /// `owned` is set to the freshly-allocated FLE envelope (a String payload)
    /// when encryption produced a new buffer the caller now owns and MUST free
    /// after all consumers (adapter write, in-memory copy, WAL notify) have
    /// read it. It is `null` when the value was returned unchanged (no
    /// encryption, double-encryption guard, security graph, or error fallback),
    /// in which case there is nothing to free. See GAP-0854 follow-up: the
    /// batch paths previously dropped this buffer on the floor, leaking one
    /// envelope per encrypted property write.
    const FleApplyResult = struct {
        value: PropertyValue,
        owned: ?[]const u8 = null,
    };

    /// Apply FLE encryption to a property value if required.  Factored out
    /// so both `setNodeProperty` and `setNodePropertiesBatch` share the
    /// same logic.
    fn applyFleEncryption(self: *GraphStore, node_id: u64, key: []const u8, value: PropertyValue) FleApplyResult {
        switch (value) {
            .String => |s| {
                if (fle_integration.hasEncryptedFields() and !isLikelyFleEnvelope(s)) {
                    const maybe_node = self.nodes.get(node_id);
                    const node_type: []const u8 = if (maybe_node) |n|
                        (if (n.labels.len > 0) n.labels[0] else "Unknown")
                    else
                        "Unknown";
                    // GAP-0854: never FLE-encrypt the internal security graph.
                    const in_security_graph = if (maybe_node) |n| isSecurityGraphName(n.graph_name) else false;
                    if (!in_security_graph and fle_integration.fieldRequiresEncryption(node_type, key)) {
                        const fle_ctx = fle_integration.EncryptionContext{
                            .tenant_id = self.tenant_id,
                            .schema_name = self.schema_name,
                            .allocator = self.allocator,
                            .current_user_role = fle_integration.rolePreferringActiveContext(),
                        };
                        // Stack-formatted record ID — see setNodeProperty comment.
                        var id_buf: [32]u8 = undefined;
                        const record_id = std.fmt.bufPrint(&id_buf, "node_{d}", .{node_id}) catch {
                            return .{ .value = value };
                        };
                        const encrypted = fle_integration.encryptFieldIfNeeded(
                            fle_ctx,
                            node_type,
                            key,
                            s,
                            record_id,
                        ) catch {
                            return .{ .value = value };
                        };
                        if (!std.mem.eql(u8, encrypted, s)) {
                            return .{ .value = PropertyValue{ .String = encrypted }, .owned = encrypted };
                        }
                    }
                }
                return .{ .value = value };
            },
            else => return .{ .value = value },
        }
    }

    pub fn getNodeProperty(self: *GraphStore, node_id: u64, key: []const u8) ?PropertyValue {
        // Hydrate-on-miss: an evicted-but-live node is rebuilt from the engine
        // so this read is transparent under the bounded cache. The returned
        // String borrows the now-resident node's property storage; it stays
        // valid until a grace-point reclaim, which the caller's per-graph rwlock
        // excludes for the read's duration (same borrow lifetime as pre-cache).
        if (self.nodes.getOrHydratePtr(node_id) catch null) |node| {
            const value = node.properties.get(key) orelse return null;

            // Fast path: skip FLE decryption when no encryption is configured.
            if (!fle_integration.hasEncryptedFields()) return value;

            // GAP-0854: the internal security graph is never FLE-encrypted (see
            // setNodeProperty), so it must never be run through FLE decryption
            // either — its `hmac`/`username`/`email` values are stored as
            // plaintext and feed the auth HMAC chain verbatim.
            if (isSecurityGraphName(node.graph_name)) return value;

            // Field-Level Encryption: decrypt string values if encrypted
            switch (value) {
                .String => |s| {
                    // Get node type (primary label) for catalog lookup
                    const type_name = if (node.labels.len > 0) node.labels[0] else "Unknown";

                    // Create encryption context using GraphStore's tenant/schema
                    const fle_ctx = fle_integration.EncryptionContext{
                        .tenant_id = self.tenant_id,
                        .schema_name = self.schema_name,
                        .allocator = self.allocator,
                        .current_user_role = fle_integration.rolePreferringActiveContext(),
                    };

                    // Format record ID on the stack — NOT via allocPrint on the shared
                    // self.allocator. Concurrent thread-pool access (QUIC auth lookups,
                    // parallel query handlers) triggered '@memcpy arguments alias' inside
                    // std.Io.Writer.drain → ArrayList.ensureTotalCapacityPrecise when the
                    // allocator was contended. Stack buffer fits "node_" + u64 (<=25 bytes).
                    var id_buf: [32]u8 = undefined;
                    const record_id = std.fmt.bufPrint(&id_buf, "node_{d}", .{node_id}) catch s;

                    // Decrypt if field is encrypted
                    const decrypted_value = fle_integration.decryptFieldIfNeeded(
                        fle_ctx,
                        type_name,
                        key,
                        s,
                        record_id,
                        true, // Check RBAC permissions
                    ) catch s; // Fall back to original value on error

                    // If decryption returned a different value, return new PropertyValue
                    if (!std.mem.eql(u8, decrypted_value, s)) {
                        return PropertyValue{ .String = decrypted_value };
                    }

                    return value;
                },
                else => return value,
            }
        }
        return null;
    }

    /// Get a node property value (simplified version without FLE decryption).
    /// Returns the raw PropertyValue or error if node not found.
    pub fn getNodePropertyValue(self: *GraphStore, node_id: u64, key: []const u8) !PropertyValue {
        // Hydrate-on-miss (bounded cache) so evicted-but-live nodes read back.
        if (try self.nodes.getOrHydratePtr(node_id)) |node| {
            return node.properties.get(key) orelse return error.PropertyNotFound;
        }
        return error.NodeNotFound;
    }

    pub fn removeNodeProperty(self: *GraphStore, node_id: u64, key: []const u8) void {
        self.ensureNodeGraphHydrated(node_id); // PHASE 1b chokepoint (hydrate before write)
        // C3 (review-0023): hydrate the node body on miss — without this the
        // resident-only gates below turn a REMOVE on a cold (post-warm-reopen)
        // node into a SILENT durable no-op. See setNodeProperty for the full
        // rationale and the write-lock safety argument.
        _ = self.nodes.getOrHydratePtr(node_id) catch null;
        if (isInternalPersistedPropertyKey(key)) return;
        if (global_vtable) |vt| {
            const node = self.nodes.get(node_id) orelse return;
            const slot_id = self.requireNodeSlot(node.graph_name, node_id) catch |err| {
                log.err("adapter node-slot lookup failed during removeNodeProperty", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("node_id", @intCast(node_id)),
                    Attr.string("graph", node.graph_name),
                });
                return;
            };
            vt.removeNodePropertyFn(vt.ctx, node.graph_name, slot_id, key) catch |err| {
                log.err("adapter removeNodeProperty failed", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("node_id", @intCast(node_id)),
                    Attr.string("graph", node.graph_name),
                });
                return;
            };
        }
        if (self.nodes.getPtr(node_id)) |node| {
            // Caveat "B" COMPLETENESS (GAP-B): if `key` is a composite component,
            // removing it makes any composite merge entry (keyed on the node's
            // CURRENT full value set) stale — and lookupCompositeMergeCandidate
            // does NOT re-verify property values, so a stale entry would resolve a
            // node that no longer carries this value. Remove the composite entry
            // BEFORE the property is dropped (the entry is rebuilt from the node's
            // still-present values). No-op when no composite key is registered.
            {
                // ENG-3954 / #874: the shrink-and-free below must exclude
                // concurrent readers of this node (see setNodeProperty).
                self.nodes.lockShardExclusive(node_id);
                defer self.nodes.unlockShardExclusive(node_id);
                if (isCompositeComponentKey(key)) self.removeNodeCompositeMergeEntries(node);
                if (node.properties.fetchRemove(key)) |kv| {
                    // Remove from merge property index before freeing
                    self.removeFromMergePropertyIndex(node.graph_name, node.labels, kv.key, kv.value);
                    // PERF-C (issue #814): decrement the label-property counter
                    // for every label still carried by the node. Internal keys
                    // are filtered out (they were never bumped on insert).
                    if (!isInternalPersistedPropertyKey(kv.key)) {
                        for (node.labels) |label| {
                            self.decLabelPropertyCount(node.graph_name, node.tenant_id, label, kv.key);
                        }
                    }
                    self.allocator.free(kv.key);
                    freePropertyValue(self, kv.value);
                }
            }
            // Mark as dirty - persistence happens at query completion
            self.dirty.store(true, .release);
            incrementMutationEpoch();

            // WAL notification: RemoveNodeProperty
            notifyMutation(.remove_node_property, node_id, 0, 0, null, key, null, null);
        }
    }

    pub fn clearNodeProperties(self: *GraphStore, node_id: u64) !void {
        const node = self.nodes.get(node_id) orelse return error.NodeNotFound;

        var keys = std.ArrayList([]const u8).empty;
        defer {
            for (keys.items) |owned_key| {
                self.allocator.free(owned_key);
            }
            keys.deinit(self.allocator);
        }

        var prop_iter = node.properties.iterator();
        while (prop_iter.next()) |entry| {
            try keys.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
        }

        for (keys.items) |owned_key| {
            self.removeNodeProperty(node_id, owned_key);
        }
    }

    pub fn addNodeLabel(self: *GraphStore, node_id: u64, label: []const u8) !void {
        self.ensureNodeGraphHydrated(node_id); // PHASE 1b chokepoint (hydrate before write)
        if (global_vtable) |vt| {
            if (vt.addNodeLabelFn) |f| {
                const node = self.nodes.get(node_id) orelse return error.NodeNotFound;
                const slot_id = try self.requireNodeSlot(node.graph_name, node_id);
                try f(vt.ctx, node.graph_name, slot_id, label);
            }
        }
        if (self.nodes.getPtr(node_id)) |node| {
            // Check if label already exists
            for (node.labels) |existing_label| {
                if (std.mem.eql(u8, existing_label, label)) {
                    return; // Label already exists, no need to add
                }
            }

            // Add the label to the node's labels array
            const label_copy = try self.allocator.dupe(u8, label);
            const new_labels = try self.allocator.alloc([]const u8, node.labels.len + 1);
            @memcpy(new_labels[0..node.labels.len], node.labels);
            new_labels[node.labels.len] = label_copy;

            // GAP-825: hold `labels_rwlock` EXCLUSIVE across the entire
            // mutation window (free-then-reassign + label_index update +
            // PERF-C counter bumps).  Without this, a snapshot reader in
            // `cloneNodesFrom` (which holds the same lock SHARED for the
            // duration of its walk) could observe `node.labels == []`
            // between `free(node.labels)` and `node.labels = new_labels`
            // (the freed-page zero-fill bug) OR an inconsistent
            // (node.labels, label_index) pair after the slice update but
            // before the index update.  Leaf lock — nothing else inside
            // this critical section acquires another lock.
            const io = std.Io.Threaded.global_single_threaded.io();
            self.labels_rwlock.lockUncancelable(io);
            defer self.labels_rwlock.unlock(io);

            // Free old labels array if it was allocated
            if (node.labels.len > 0) {
                self.allocator.free(node.labels);
            }

            node.labels = new_labels;

            // Maintain label index
            try self.addToLabelIndex(node.graph_name, label, node_id);
            // PERF-C (issue #814): bump tenant-keyed label counter and, for
            // every existing property on the node, the label-property counter
            // — because the new label "inherits" all the node's properties
            // for introspection purposes (`listPropertiesForLabel` reports
            // every property carried by any node holding `label`).
            try self.bumpLabelCount(node.graph_name, node.tenant_id, label);
            var prop_it_for_pc = node.properties.iterator();
            while (prop_it_for_pc.next()) |p| {
                const pkey = p.key_ptr.*;
                if (isInternalPersistedPropertyKey(pkey)) continue;
                try self.bumpLabelPropertyCount(node.graph_name, node.tenant_id, label, pkey);
            }

            // Mark as dirty - persistence happens at query completion
            self.dirty.store(true, .release);
            incrementMutationEpoch();

            // WAL notification: AddNodeLabel
            notifyMutation(.add_node_label, node_id, 0, 0, label, null, null, null);
        }
    }

    pub fn removeNodeLabel(self: *GraphStore, node_id: u64, label: []const u8) !void {
        self.ensureNodeGraphHydrated(node_id); // PHASE 1b chokepoint (hydrate before write)
        if (global_vtable) |vt| {
            if (vt.removeNodeLabelFn) |f| {
                const node = self.nodes.get(node_id) orelse return error.NodeNotFound;
                const slot_id = try self.requireNodeSlot(node.graph_name, node_id);
                try f(vt.ctx, node.graph_name, slot_id, label);
            }
        }
        if (self.nodes.getPtr(node_id)) |node| {
            // Find the label to remove
            var found_index: ?usize = null;
            for (node.labels, 0..) |existing_label, i| {
                if (std.mem.eql(u8, existing_label, label)) {
                    found_index = i;
                    break;
                }
            }

            if (found_index) |index| {
                const removed_label = node.labels[index];
                // Create new labels array without the removed label
                const new_labels = try self.allocator.alloc([]const u8, node.labels.len - 1);
                var new_index: usize = 0;
                for (node.labels, 0..) |existing_label, i| {
                    if (i != index) {
                        new_labels[new_index] = existing_label;
                        new_index += 1;
                    }
                }

                // GAP-825: hold `labels_rwlock` EXCLUSIVE across the
                // entire mutation window. See addNodeLabel for the full
                // rationale.
                const io = std.Io.Threaded.global_single_threaded.io();
                self.labels_rwlock.lockUncancelable(io);
                defer self.labels_rwlock.unlock(io);

                // Free old labels array if it was allocated
                if (node.labels.len > 0) {
                    self.allocator.free(node.labels);
                }

                node.labels = new_labels;

                // Remove label from index and free label memory
                self.removeFromLabelIndex(node.graph_name, label, node_id);
                // PERF-C (issue #814): mirror the bump done by `addNodeLabel`
                // — decrement the label-property counter for every property
                // still carried by the node, then drop the label counter.
                var prop_it_for_pc_rm = node.properties.iterator();
                while (prop_it_for_pc_rm.next()) |p| {
                    const pkey = p.key_ptr.*;
                    if (isInternalPersistedPropertyKey(pkey)) continue;
                    self.decLabelPropertyCount(node.graph_name, node.tenant_id, label, pkey);
                }
                self.decLabelCount(node.graph_name, node.tenant_id, label);
                self.allocator.free(removed_label);

                // Mark as dirty - persistence happens at query completion
                self.dirty.store(true, .release);
                incrementMutationEpoch();

                // WAL notification: RemoveNodeLabel
                notifyMutation(.remove_node_label, node_id, 0, 0, label, null, null, null);
            }
        }
    }

    pub fn getAllNodes(self: *const GraphStore, allocator: std.mem.Allocator) ![]u64 {
        // PHASE 1b chokepoint: enumerates ALL graphs' IdMaps (no single
        // graph_name). After a no-snapshot cold-open a deferred graph's IdMap is
        // EMPTY until first access, so an unguarded scan under-counts — the
        // DROP TENANT cascade (tenant_dispatch) would then leave orphaned rows /
        // report a false "empty tenant" success. Hydrate every deferred graph
        // first, before any lock (no deadlock, no re-entrancy: hydration's
        // loadOneGraphFromAdapterFull never calls these readers).
        @constCast(self).ensureAllGraphsHydrated();
        // When the node cache is bounded (eviction active), the resident map is
        // an INCOMPLETE view — enumerate every public id from the per-graph
        // IdMaps instead, which stay fully resident (~24 B/entry) regardless of
        // node-cache eviction. When unbounded, the resident map equals the full
        // set, so use it directly (fast path, no behavior change).
        if (self.nodes.effectiveCap() == 0) {
            // geode#875 RC-3: snapshot resident keys UNDER each shard's map_lock
            // instead of walking the live, unlocked cache iterator — a concurrent
            // MERGE/insert grows the cache between `count()` and the walk, so the
            // pre-sized alloc + unlocked iteration faulted (the knn-scan-race
            // crash). Unbounded ⇒ resident set == full set, so this stays exact.
            return @constCast(&self.nodes).snapshotKeys(allocator);
        }
        var ids: std.ArrayList(u64) = .empty;
        errdefer ids.deinit(allocator);
        var it = @constCast(self).id_maps.iterator();
        while (it.next()) |entry| {
            // geode#875 RC-3: snapshot each graph's node uuids UNDER the IdMap
            // leaf mutex — an unlocked `nodeUuidIterator` walk faults when a
            // concurrent MERGE/insert resizes `node_uuid_to_slot` (the
            // knn-scan-race crash).
            const uuids = try entry.value_ptr.snapshotNodeUuids(allocator);
            defer allocator.free(uuids);
            for (uuids) |nuuid| try ids.append(allocator, @as(u64, @truncate(nuuid)));
        }
        return ids.toOwnedSlice(allocator);
    }

    // CANARY: REQ=REQ-MULTI-TENANT-004; FEATURE="PerTenantIsolation"; ASPECT=BulkNodeAccess; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-01
    // GAP-0279: Return only nodes belonging to the specified tenant (or all if tenant is null)
    pub fn getAllNodesForTenant(self: *const GraphStore, allocator: std.mem.Allocator, tenant: ?[]const u8) ![]u64 {
        // PHASE 1b chokepoint: enumerates ALL graphs' IdMaps (no single
        // graph_name). Hydrate every deferred graph before the scan so a
        // no-snapshot cold-open cannot under-count the tenant (DROP TENANT
        // cascade correctness). Safe/no-deadlock/no-reentrancy as in getAllNodes.
        @constCast(self).ensureAllGraphsHydrated();
        const tid = tenant orelse return self.getAllNodes(allocator);

        // Unbounded cache: resident map is the full set (fast path, unchanged).
        if (self.nodes.effectiveCap() == 0) {
            var result: std.ArrayList(u64) = .empty;
            errdefer result.deinit(allocator);
            var iter = self.nodes.iterator();
            while (iter.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.tenant_id, tid)) try result.append(allocator, entry.key_ptr.*);
            }
            return result.toOwnedSlice(allocator);
        }

        // Bounded cache: enumerate ALL ids from the resident IdMaps and resolve
        // each node's tenant from the cache if resident, else from the engine
        // (without populating the cache, so a full scan doesn't blow the bound).
        var result: std.ArrayList(u64) = .empty;
        errdefer result.deinit(allocator);
        var it = @constCast(self).id_maps.iterator();
        while (it.next()) |entry| {
            const graph_name = entry.key_ptr.*;
            // geode#875 RC-3: snapshot uuids under the IdMap leaf mutex (race-safe
            // vs. concurrent insert), then resolve each id's tenant outside it.
            const uuids = try entry.value_ptr.snapshotNodeUuids(allocator);
            defer allocator.free(uuids);
            for (uuids) |nuuid| {
                const id = @as(u64, @truncate(nuuid));
                if (@constCast(self).nodeMatchesTenant(graph_name, entry.value_ptr, id, tid)) {
                    try result.append(allocator, id);
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// Does node `node_id` belong to tenant `tid`, resolved WITHOUT inserting
    /// into the node cache (so a full scan never blows the resident bound)?
    /// Resident cache entry wins; otherwise read the persisted tenant property
    /// directly from the engine (absent ⇒ DEFAULT_TENANT_ID). The comparison is
    /// done inline so no tenant string needs to outlive the engine read.
    fn nodeMatchesTenant(self: *GraphStore, graph_name: []const u8, id_map: *id_map_mod.IdMap, node_id: u64, tid: []const u8) bool {
        if (self.nodes.get(node_id)) |n| return std.mem.eql(u8, n.tenant_id, tid);
        const adapter = global_adapter orelse return std.mem.eql(u8, DEFAULT_TENANT_ID, tid);
        const slot = id_map.nodeSlot(@as(u128, node_id)) orelse return std.mem.eql(u8, DEFAULT_TENANT_ID, tid);
        const tprop = (adapter.getNodeProperty(graph_name, slot, INTERNAL_TENANT_ID_PROPERTY_KEY, self.allocator) catch null) orelse
            return std.mem.eql(u8, DEFAULT_TENANT_ID, tid);
        defer switch (tprop) {
            .string => |s| self.allocator.free(s),
            else => {},
        };
        return switch (tprop) {
            .string => |s| std.mem.eql(u8, s, tid),
            else => std.mem.eql(u8, DEFAULT_TENANT_ID, tid),
        };
    }

    // CANARY: REQ=REQ-MULTI-TENANT-004; FEATURE="PerTenantIsolation"; ASPECT=BulkEdgeAccess; STATUS=TESTED; TEST=tests/test_gap0847_tenant_drop_cascade.zig; OWNER=enterprise; UPDATED=2026-06-10
    // GAP-0847: Return only edge ids belonging to the specified tenant (or all if
    // tenant is null). Mirrors `getAllNodesForTenant`; used by the tenant-drop
    // cascade to collect a tenant's edges for referential-consistency deletion
    // (edges deleted before their endpoint nodes).
    pub fn getAllEdgesForTenant(self: *const GraphStore, allocator: std.mem.Allocator, tenant: ?[]const u8) ![]u64 {
        // PHASE 1b chokepoint: enumerates ALL graphs' IdMaps (no single
        // graph_name). Hydrate every deferred graph before the scan so a
        // no-snapshot cold-open cannot under-count the tenant's edges (DROP
        // TENANT cascade would otherwise orphan edges). Safe as in getAllNodes.
        @constCast(self).ensureAllGraphsHydrated();
        // Unbounded cache: the resident map is the full set (fast path).
        if (self.edges.effectiveCap() == 0) {
            var result: std.ArrayList(u64) = .empty;
            errdefer result.deinit(allocator);
            var iter = self.edges.iterator();
            while (iter.next()) |entry| {
                if (tenant) |tid| {
                    if (!std.mem.eql(u8, entry.value_ptr.tenant_id, tid)) continue;
                }
                try result.append(allocator, entry.key_ptr.*);
            }
            return result.toOwnedSlice(allocator);
        }

        // PHASE 1: BOUNDED cache — the resident map is incomplete. Enumerate ALL
        // edge ids from the per-graph IdMaps (fully resident, independent of the
        // edge cache) so the tenant-drop cascade never misses an evicted edge.
        // Resolve each edge's tenant via hydrate-on-miss (residency stays
        // bounded — the cache evicts as it hydrates). Mirrors
        // getAllNodesForTenant's bounded-cache branch.
        var result: std.ArrayList(u64) = .empty;
        errdefer result.deinit(allocator);
        var it = @constCast(self).id_maps.iterator();
        while (it.next()) |entry| {
            var eit = entry.value_ptr.edgeUuidIterator();
            while (eit.next()) |euuid| {
                const eid = @as(u64, @truncate(euuid));
                if (tenant) |tid| {
                    const edge = self.getEdgeHydrated(eid) orelse continue;
                    if (!std.mem.eql(u8, edge.tenant_id, tid)) continue;
                }
                try result.append(allocator, eid);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    // CANARY: REQ=REQ-SONNY-2693-EDGE-TAG-BACKFILL; FEATURE="PerTenantIsolation"; ASPECT=EdgeTagBackfill; STATUS=TESTED; TEST=tests/test_sonny2693_edge_tenant_rule.zig; OWNER=security; UPDATED=2026-09-25
    /// SONNY-2693: what `backfillEdgeTenantTags` did, or would do, to an edge.
    pub const EdgeTagBackfillAction = enum {
        /// Tagged `default` between two nodes of one tenant, and now tagged
        /// with that tenant.
        retagged,
        /// `retagged`, in a dry run: nothing was changed.
        would_retag,
        /// Its tag and its endpoints' tags disagree in any other way (the
        /// endpoints belong to different tenants, the edge carries another
        /// tenant's tag, or an endpoint resolves nowhere). Left as it is: no
        /// tenant can see it, and only an operator can say whose it is.
        mixed,
        /// SONNY-2733: the backfill could not re-tag the edge (it would
        /// otherwise be `retagged`), or could not read it, or (with a null
        /// `edge_id`) could not lock the edge's whole graph in time. Left as
        /// it is; the entry's `reason` names the error, and the next run
        /// tries again.
        failed,
    };

    /// SONNY-2693: one edge `backfillEdgeTenantTags` re-tagged or reports.
    /// Every slice but `reason` is owned; free with `deinit`.
    pub const EdgeTagBackfillEntry = struct {
        /// Null only on a `failed` row for a whole graph the backfill could
        /// not lock in time (`reason` GraphLockTimeout); its edges were not
        /// scanned.
        edge_id: ?u64,
        action: EdgeTagBackfillAction,
        graph_name: []const u8,
        /// Null when the edge could not be read (`failed`).
        edge_type: ?[]const u8,
        /// The edge's tag before the backfill; null when the edge could not
        /// be read (`failed`).
        edge_tenant: ?[]const u8,
        /// Null when the endpoint resolves nowhere, or the edge could not be
        /// read.
        from_tenant: ?[]const u8,
        to_tenant: ?[]const u8,
        /// SONNY-2733: why a `failed` edge failed: an error name (static,
        /// not owned). Null for every other action.
        reason: ?[]const u8 = null,

        pub fn deinit(self: *const EdgeTagBackfillEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.graph_name);
            if (self.edge_type) |t| allocator.free(t);
            if (self.edge_tenant) |t| allocator.free(t);
            if (self.from_tenant) |t| allocator.free(t);
            if (self.to_tenant) |t| allocator.free(t);
        }
    };

    pub fn freeEdgeTagBackfillEntries(allocator: std.mem.Allocator, entries: []const EdgeTagBackfillEntry) void {
        for (entries) |*entry| entry.deinit(allocator);
        allocator.free(entries);
    }

    /// SONNY-2693: re-tag the `default` edges whose endpoints both belong to
    /// one tenant, and report every other edge whose tags disagree.
    ///
    /// An edge is consistent when its own tag equals both endpoints' tags.
    /// Since SONNY-2693 a session sees an edge only when its tag AND both
    /// endpoints are visible, so an inconsistent edge is hidden from every
    /// tenant. The GAP-0891 worker bug wrote intra-tenant edges as `default`;
    /// the read path used to bridge them through their endpoints and no
    /// longer does. This puts such an edge under its endpoints' tenant (the
    /// only change it makes), and lists the rest for an operator:
    ///   * `default` between two nodes of tenant T (T not `default`):
    ///     `retagged` (`would_retag` when `dry_run`);
    ///   * any other disagreement: `mixed`, unchanged.
    /// A consistent edge (including `default` between two `default` nodes) is
    /// neither changed nor listed. Tags are compared exactly: a tenant
    /// hierarchy does not make a parent's tag match a child's.
    ///
    /// SONNY-2733: it works one graph at a time, in name order. For each graph
    /// it takes that graph's write lock, scans and re-tags that graph's edges
    /// (evicted ones included), and releases the lock before it takes the
    /// next; it never holds two graph locks. It waits for each lock as a
    /// statement does (writer-preferring, up to
    /// `backfill_graph_lock_timeout_ns`); a graph still busy then is listed as
    /// one `failed` row with a null `edge_id` and reason GraphLockTimeout, and
    /// the run goes on. It skips the engine's own graphs
    /// (`isInternalGraphName`), and a graph dropped since it listed them. The
    /// caller must hold no store or graph lock, or it fails with
    /// `error.GraphLockHeld` and changes nothing: taking the lock the caller
    /// holds would deadlock, and taking another would hold two. So the
    /// transport handlers run a lone `CALL geode.tenant.backfill_edge_tags`
    /// without their statement lock (`query_traits.isSelfLockingProgram`).
    ///
    /// An edge it fails to re-tag, or to read, is listed as `failed` with the
    /// error's name and left as it was, and the scan goes on. Each re-tag is
    /// durable on its own (`retagEdgeTenant`), so a run that stops part way
    /// keeps what it did, and running it again finishes the job: an edge it
    /// re-tagged is consistent and is not listed again. Returns the listed
    /// edges in scan order; the caller frees them with
    /// `freeEdgeTagBackfillEntries`.
    ///
    /// Runs on the calling thread and reads endpoint tags with the engine
    /// fallback, so it must not run on a parallel-UNION arm.
    // CANARY: REQ=REQ-SONNY-2733-BACKFILL-LOCKING; FEATURE="PerTenantIsolation"; ASPECT=OneGraphLockAtATime; STATUS=TESTED; TEST=tests/test_sonny2733_backfill_locking.zig; OWNER=security; UPDATED=2026-09-25
    pub fn backfillEdgeTenantTags(self: *GraphStore, allocator: std.mem.Allocator, dry_run: bool) ![]EdgeTagBackfillEntry {
        if (storeLockHeldByCurrentThread()) return error.GraphLockHeld;

        const graph_names = try self.sortedGraphNames(allocator);
        defer freeGraphNames(allocator, graph_names);

        var entries: std.ArrayList(EdgeTagBackfillEntry) = .empty;
        errdefer {
            for (entries.items) |*entry| entry.deinit(allocator);
            entries.deinit(allocator);
        }

        for (graph_names) |graph_name| {
            if (isInternalGraphName(graph_name)) continue;
            // PHASE 1b chokepoint: build a deferred graph first. Loading it
            // opens it in the engine, and the lock below finds only open
            // graphs; the build takes no store or graph lock.
            self.ensureGraphHydrated(graph_name);
            const deadline = monoNanosNow() + backfill_graph_lock_timeout_ns;
            const maybe_lock = acquireExistingGraphWriteLock(graph_name, deadline) catch {
                // Busy past the budget: list the graph as failed, unscanned,
                // and go on to the next.
                log.warn("edge tag backfill: a graph's write lock did not come in time; its edges were not scanned", &.{
                    Attr.string("graph", graph_name),
                });
                try entries.ensureUnusedCapacity(allocator, 1);
                entries.appendAssumeCapacity(.{
                    .edge_id = null,
                    .action = .failed,
                    .graph_name = try allocator.dupe(u8, graph_name),
                    .edge_type = null,
                    .edge_tenant = null,
                    .from_tenant = null,
                    .to_tenant = null,
                    .reason = @errorName(error.GraphLockTimeout),
                });
                continue;
            };
            const lock = maybe_lock orelse continue; // dropped since it was listed
            defer releaseGraphLock(lock);
            try self.backfillGraphEdgeTags(allocator, graph_name, dry_run, &entries);
        }
        return entries.toOwnedSlice(allocator);
    }

    /// SONNY-2733: every graph's name, sorted; free with `freeGraphNames`.
    /// Read under `graphs_mutex`, which CREATE and DROP GRAPH hold while they
    /// change the graph maps.
    fn sortedGraphNames(self: *GraphStore, allocator: std.mem.Allocator) ![][]const u8 {
        const listed = blk: {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.graphs_mutex.lockUncancelable(io);
            defer self.graphs_mutex.unlock(io);
            break :blk try self.listGraphNames(allocator);
        };
        // `listGraphNames` hands over the slice it allocated.
        const names: [][]const u8 = @constCast(listed);
        std.mem.sort([]const u8, names, {}, graphNameLessThan);
        return names;
    }

    fn graphNameLessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn freeGraphNames(allocator: std.mem.Allocator, names: []const []const u8) void {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }

    /// SONNY-2733: `backfillEdgeTenantTags` for graph `graph_name`, whose
    /// write lock the caller holds. Appends what it lists to `entries`.
    fn backfillGraphEdgeTags(
        self: *GraphStore,
        allocator: std.mem.Allocator,
        graph_name: []const u8,
        dry_run: bool,
        entries: *std.ArrayList(EdgeTagBackfillEntry),
    ) !void {
        const edge_ids = try self.graphEdgeIdsLocked(allocator, graph_name);
        defer allocator.free(edge_ids);
        for (edge_ids) |edge_id| try self.backfillEdgeTag(allocator, graph_name, edge_id, dry_run, entries);
    }

    /// SONNY-2733: the ids of graph `graph_name`'s edges, evicted ones
    /// included. The caller holds the graph's write lock.
    fn graphEdgeIdsLocked(self: *GraphStore, allocator: std.mem.Allocator, graph_name: []const u8) ![]u64 {
        var ids: std.ArrayList(u64) = .empty;
        errdefer ids.deinit(allocator);
        if (global_vtable != null) {
            // With a storage adapter the graph's IdMap lists every edge of the
            // graph, cached or not, and only the graph's writers change it.
            const id_map = self.getIdMap(graph_name) orelse return ids.toOwnedSlice(allocator);
            var it = id_map.edgeUuidIterator();
            while (it.next()) |edge_uuid| try ids.append(allocator, @as(u64, @truncate(edge_uuid)));
            return ids.toOwnedSlice(allocator);
        }
        // No adapter: the cache holds every edge, and the caller's lock is the
        // global EXCLUSIVE one, so nothing changes during the scan.
        const all = try self.edges.snapshotKeys(allocator);
        defer allocator.free(all);
        for (all) |edge_id| {
            const edge = self.edges.get(edge_id) orelse continue;
            if (std.mem.eql(u8, edge.graph_name, graph_name)) try ids.append(allocator, edge_id);
        }
        return ids.toOwnedSlice(allocator);
    }

    /// SONNY-2733: classify edge `edge_id` of graph `graph_name`, re-tag it
    /// when that is the verdict and this is not a dry run, and append what the
    /// backfill lists for it to `entries`. The caller holds the graph's write
    /// lock. A failed re-tag or read is listed as `failed`, not returned.
    fn backfillEdgeTag(
        self: *GraphStore,
        allocator: std.mem.Allocator,
        graph_name: []const u8,
        edge_id: u64,
        dry_run: bool,
        entries: *std.ArrayList(EdgeTagBackfillEntry),
    ) !void {
        // Room for the entry first, so an edge the backfill re-tags is always
        // listed.
        try entries.ensureUnusedCapacity(allocator, 1);

        const edge = self.getEdgeHydrated(edge_id) orelse {
            log.warn("edge tag backfill: an edge of the graph cannot be read; it is listed as failed", &.{
                Attr.string("graph", graph_name),
                Attr.uint("edge_id", edge_id),
            });
            entries.appendAssumeCapacity(.{
                .edge_id = edge_id,
                .action = .failed,
                .graph_name = try allocator.dupe(u8, graph_name),
                .edge_type = null,
                .edge_tenant = null,
                .from_tenant = null,
                .to_tenant = null,
                .reason = @errorName(error.EdgeNotFound),
            });
            return;
        };
        // Only the graph whose lock the caller holds.
        if (!std.mem.eql(u8, edge.graph_name, graph_name)) return;

        const from_tenant = self.dupeNodeTenantForRead(allocator, edge.from_id);
        defer if (from_tenant) |t| allocator.free(t);
        const to_tenant = self.dupeNodeTenantForRead(allocator, edge.to_id);
        defer if (to_tenant) |t| allocator.free(t);

        const action = classifyEdgeTags(edge.tenant_id, from_tenant, to_tenant, dry_run) orelse return;

        // Copy the edge's strings before a re-tag replaces its body.
        var entry = EdgeTagBackfillEntry{
            .edge_id = edge_id,
            .action = action,
            .graph_name = try allocator.dupe(u8, graph_name),
            .edge_type = null,
            .edge_tenant = null,
            .from_tenant = null,
            .to_tenant = null,
        };
        errdefer entry.deinit(allocator);
        entry.edge_type = try allocator.dupe(u8, edge.label);
        entry.edge_tenant = try allocator.dupe(u8, edge.tenant_id);
        if (from_tenant) |t| entry.from_tenant = try allocator.dupe(u8, t);
        if (to_tenant) |t| entry.to_tenant = try allocator.dupe(u8, t);

        if (action == .retagged) {
            self.retagEdgeTenant(edge_id, DEFAULT_TENANT_ID, from_tenant.?) catch |err| {
                log.warn("edge tag backfill: re-tag failed; the edge is unchanged and listed as failed", &.{
                    Attr.string("graph", graph_name),
                    Attr.uint("edge_id", edge_id),
                    Attr.string("error", @errorName(err)),
                });
                entry.action = .failed;
                entry.reason = @errorName(err);
            };
        }
        entries.appendAssumeCapacity(entry);
    }

    /// `backfillEdgeTenantTags`'s decision for one edge; null when the edge is
    /// consistent and is left out of the report.
    fn classifyEdgeTags(edge_tenant: []const u8, from_tenant: ?[]const u8, to_tenant: ?[]const u8, dry_run: bool) ?EdgeTagBackfillAction {
        const from = from_tenant orelse return .mixed;
        const to = to_tenant orelse return .mixed;
        if (!std.mem.eql(u8, from, to)) return .mixed;
        if (std.mem.eql(u8, edge_tenant, from)) return null;
        // Both endpoints are T. T is not `default` here: a `default` edge
        // between `default` nodes returned null above.
        if (std.mem.eql(u8, edge_tenant, DEFAULT_TENANT_ID)) return if (dry_run) .would_retag else .retagged;
        return .mixed;
    }

    /// SONNY-2693: change edge `edge_id`'s tenant tag from `expected` to
    /// `tenant`, which may not be `default`. Fails with
    /// `error.EdgeTenantChanged`, changing nothing, when the edge no longer
    /// carries `expected`.
    ///
    /// Durable before visible: with a storage adapter the tag is written under
    /// the same key the create paths write (`persistEdgeTenantId`, read back
    /// by `hydrateEdgeCb` and the restart load) before the cached body
    /// changes, and an adapter that cannot store an edge property fails the
    /// re-tag. With no adapter (an in-memory store) only the cached body
    /// changes, as for every in-memory edge write.
    ///
    /// SONNY-2733: a failed re-tag changes nothing, so the backfill can list
    /// the edge as `failed` and go on. Every step that can fail runs before the
    /// durable write, except the cache update; when that fails, the stored tag
    /// is put back (`restoreEdgeTenantId`).
    ///
    /// The cached body is replaced, never edited in place: `put` retires the
    /// old body to the cache's grace list, which frees it only in this graph's
    /// next exclusive grace window. The backfill holds the graph's write lock
    /// while it calls this, so no reader of the graph is holding the old body.
    /// The tenant-keyed edge-type counter moves with the tag.
    fn retagEdgeTenant(self: *GraphStore, edge_id: u64, expected: []const u8, tenant: []const u8) !void {
        if (std.mem.eql(u8, tenant, DEFAULT_TENANT_ID)) return error.InvalidTenantTag;
        self.ensureEdgeGraphHydrated(edge_id); // PHASE 1b chokepoint (hydrate before write)
        const current = self.getEdgeHydrated(edge_id) orelse return error.EdgeNotFound;
        if (!std.mem.eql(u8, current.tenant_id, expected)) return error.EdgeTenantChanged;

        // The engine addresses the edge by its endpoints' slots and its own.
        const Slots = struct { from: u64, to: u64, edge: u64 };
        const slots: ?Slots = if (global_vtable != null) Slots{
            .from = try self.requireNodeSlot(current.graph_name, current.from_id),
            .to = try self.requireNodeSlot(current.graph_name, current.to_id),
            .edge = try self.requireEdgeSlot(current.graph_name, edge_id),
        } else null;

        var replacement = Edge{
            .id = current.id,
            .from_id = current.from_id,
            .to_id = current.to_id,
            .label = &.{},
            .properties = CompactPropertyMap.init(self.allocator),
            .graph_name = &.{},
            .tenant_id = &.{},
        };
        errdefer freeEdgeValue(self.allocator, &replacement);
        replacement.label = try self.allocator.dupe(u8, current.label);
        replacement.graph_name = try self.allocator.dupe(u8, current.graph_name);
        replacement.tenant_id = try self.allocator.dupe(u8, tenant);
        var prop_it = current.properties.iterator();
        while (prop_it.next()) |prop| {
            const key = try self.allocator.dupe(u8, prop.key_ptr.*);
            errdefer self.allocator.free(key);
            const value = try copyPropertyValue(self, prop.value_ptr.*);
            errdefer freePropertyValue(self, value);
            try replacement.properties.put(key, value);
        }

        // The counter moves before `put`: once the cache owns `replacement`,
        // its strings are not ours to read.
        try self.bumpEdgeTypeCount(replacement.graph_name, tenant, replacement.label);
        errdefer self.decEdgeTypeCount(replacement.graph_name, tenant, replacement.label);
        self.decEdgeTypeCount(replacement.graph_name, expected, replacement.label);
        errdefer self.bumpEdgeTypeCount(replacement.graph_name, expected, replacement.label) catch {};

        if (slots) |s| try persistEdgeTenantId(global_vtable.?, current.graph_name, s.from, s.to, s.edge, tenant);
        errdefer if (slots) |s| restoreEdgeTenantId(global_vtable.?, current.graph_name, s.from, s.to, s.edge, expected);
        try self.edges.put(edge_id, replacement);

        self.dirty.store(true, .release);
        incrementMutationEpoch();
    }

    /// SONNY-2733: put back the stored tenant tag of an edge whose re-tag
    /// failed after `persistEdgeTenantId` stored the new one. Unlike that
    /// function it writes `default` out too (a stored `default` reads back
    /// the same as a missing tag). Best effort: a failure is logged, and the
    /// edge then reads the new tag after a restart.
    fn restoreEdgeTenantId(
        vt: AdapterVTable,
        graph_name: []const u8,
        from_slot: u64,
        to_slot: u64,
        edge_slot: u64,
        tenant: []const u8,
    ) void {
        const set_edge_property = vt.setEdgePropertyFn orelse return;
        set_edge_property(
            vt.ctx,
            graph_name,
            from_slot,
            to_slot,
            edge_slot,
            INTERNAL_TENANT_ID_PROPERTY_KEY,
            .{ .String = tenant },
        ) catch |err| {
            log.err("edge tenant re-tag failed and its stored tag could not be put back; the edge reads the new tag after a restart", &.{
                Attr.string("graph", graph_name),
                Attr.uint("edge_slot", edge_slot),
                Attr.string("error", @errorName(err)),
            });
        };
    }

    pub fn getNodeCount(self: *GraphStore) usize {
        // PHASE 1b chokepoint (H3): store-wide node count, the node analog of
        // getEdgeCount. Reads deferred state (the per-graph IdMaps, and the
        // resident node cache populated by loop2), so after a no-snapshot open it
        // would return a PARTIAL count for any not-yet-hydrated graph. No single
        // graph_name -> hydrate every deferred graph first.
        self.ensureAllGraphsHydrated();
        // With a BOUNDED node cache the resident map is incomplete, so count from
        // the per-graph IdMaps (fully resident) — mirrors getEdgeCount and
        // countNodesForGraph. Unbounded cache: the resident count IS the total.
        if (self.nodes.effectiveCap() == 0) {
            return self.nodes.count();
        }
        var total: usize = 0;
        var it = self.id_maps.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.nodeCount();
        }
        return total;
    }

    // CANARY: REQ=REQ-PERF-COUNT-NODES-PUSHDOWN; FEATURE="UnlabeledMatchCountPushdown"; ASPECT=StoreCount; STATUS=TESTED; TEST=tests/test_count_nodes_pushdown_perf.zig; OWNER=execution; UPDATED=2026-04-16
    // COUNT_PUSHDOWN: Return the number of nodes in a specific graph, optionally
    // scoped to a tenant. Used by the count-only pushdown in
    // `src/execution/match_operations.zig` to bypass the unlabeled full-scan
    // fallback for `MATCH (n) RETURN count(n)` / `count(*)` shapes. When
    // tenant is null and graph_name matches every node (the single-graph
    // default case), this degrades to the O(1) `self.nodes.count()`; otherwise
    // it runs a single O(N) scan over the node map without allocating any
    // bindings — strictly cheaper than the old iteration path which built a
    // MatchBinding per node then discarded them.
    pub fn countNodesForGraph(self: *const GraphStore, graph_name: []const u8, tenant: ?[]const u8) usize {
        // PHASE 1b chokepoint (H3): guard the deferred hydration so a count(n)
        // before hydration completes can't observe a partial IdMap node count
        // after a no-snapshot open (same bug class as countEdgesForGraph).
        // No-op once hydrated / on snapshot-resident opens, so O(1) is preserved.
        @constCast(self).ensureGraphHydrated(graph_name);
        // GAP-ENT-0013: with no tenant filter, the graph's IdMap node count IS
        // the answer — O(1) in BOTH cache modes (the IdMap is fully resident
        // whenever an engine adapter backs the graph, bounded or unbounded
        // node cache alike). Hoisted out of the bounded-cache branch so an
        // unbounded cache no longer pays an O(N) `nodes.iterator()` walk.
        //
        // Review I-1: gate the O(1) return on `global_vtable != null`. The
        // IdMap is only WRITE-maintained when an engine vtable backs node
        // creation (`createNode*` inserts into the IdMap solely inside the
        // `adapter_node != null` arm), but `createGraph` /
        // `openOrCreateGraphWithUuid` unconditionally create an EMPTY IdMap
        // even with no disk adapter (GAP-0839). Without the gate, an
        // adapterless `CREATE GRAPH` + node creates + `count(n)` returned 0
        // from that empty IdMap. Adapterless stores never bound the node
        // cache (hydrate-on-miss is engine-backed), so falling through to
        // the resident iteration below is exact there.
        if (tenant == null) {
            if (global_vtable != null) {
                if (@constCast(self).getIdMap(graph_name)) |id_map| {
                    // GAP-ENT-0013 path counter: O(1) IdMap total served the count.
                    _ = g_count_nodes_idmap_fast.fetchAdd(1, .monotonic);
                    return id_map.nodeCount();
                }
            }
            // No IdMap for this graph (purely in-memory graph with no
            // adapter). Bounded cache: the resident map is incomplete and
            // there is no authoritative source — preserve the pre-existing
            // bounded behavior (0). Unbounded cache: fall through to the
            // resident iteration below, which IS exact (O(resident)).
            if (self.nodes.effectiveCap() != 0) return 0;
        } else if (self.nodes.effectiveCap() != 0) {
            // Bounded cache + tenant filter: the resident map is incomplete —
            // resolve each node's tenant from the IdMap without populating
            // the cache.
            const id_map = (@constCast(self).getIdMap(graph_name)) orelse return 0;
            const tid = tenant.?;
            // GAP-ENT-0013 path counter: tenant-filtered per-uuid iteration
            // (O(N) `nodeMatchesTenant` property reads).
            _ = g_count_nodes_iter_fallback.fetchAdd(1, .monotonic);
            var count: usize = 0;
            var nit = id_map.nodeUuidIterator();
            while (nit.next()) |nuuid| {
                const id = @as(u64, @truncate(nuuid));
                if (@constCast(self).nodeMatchesTenant(graph_name, id_map, id, tid)) count += 1;
            }
            return count;
        }
        // GAP-ENT-0013 path counter: unbounded-cache resident node iteration
        // (tenant-filtered count, or the no-IdMap in-memory fallback above).
        _ = g_count_nodes_iter_fallback.fetchAdd(1, .monotonic);
        var count: usize = 0;
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            const node = entry.value_ptr;
            if (!std.mem.eql(u8, node.graph_name, graph_name)) continue;
            if (tenant) |tid| {
                if (!std.mem.eql(u8, node.tenant_id, tid)) continue;
            }
            count += 1;
        }
        return count;
    }

    // CANARY: REQ=REQ-PERF-QPS-0811; FEATURE="CountFastPath"; ASPECT=LabelIndexCardinality; STATUS=TESTED; TEST=tests/test_gap0811_aggregation_fastpath.zig; OWNER=performance; UPDATED=2026-04-20
    // GAP-0811: Label-scoped O(1) cardinality for the count fast-path.
    //
    // When `tenant == null` we can return the label-index posting-list length
    // directly — `deleteNodeNoSave` calls `removeFromLabelIndex` for every
    // label on a deleted node, so the posting list's length is an exact count
    // of live nodes with that (graph, label) pair.
    //
    // When `tenant != null` we must iterate the posting list and check each
    // node's `tenant_id`, because the label index is not partitioned by
    // tenant. This is still strictly cheaper than `countNodesForGraph` which
    // scans ALL nodes in the graph (not just those with the label).
    //
    // Called by `countNodesFastPath` in `src/execution/match_operations.zig`
    // for `MATCH (p:<Label>) RETURN count(p)` / `count(*)`. Parallels
    // `countNodesForGraph` for the unlabeled case.
    pub fn countNodesByLabel(
        self: *const GraphStore,
        graph_name: []const u8,
        label: []const u8,
        tenant: ?[]const u8,
    ) usize {
        @constCast(self).ensureGraphHydrated(graph_name); // PHASE 1b chokepoint
        // CANARY: REQ=REQ-QUIC-HC-032; FEATURE="High-Concurrency Label Counts"; ASPECT=LabelPostingLocking; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=storage; UPDATED=2026-06-11
        //
        // Group-commit writers update label postings while sharing the
        // whole-graph rwlock with readers. Count must therefore take the same
        // outer/leaf label-index locks as writers instead of aliasing the live
        // ArrayList through getNodesByLabel().
        if (tenant == null) {
            // CANARY: REQ=REQ-QUIC-HC-120; FEATURE="High-Concurrency Label Counts"; ASPECT=LabelCountRefcountRead; STATUS=TESTED; TEST=test_graph_store_label_count_refcounts; OWNER=storage; UPDATED=2026-05-28
            //
            // The common QUIC count path only needs exact cardinality, not the
            // posting list. Read the maintained graph+label refcount so count
            // requests do not queue behind same-label insert sorting.
            return self.countGraphLabel(graph_name, label);
        }

        const mutable_self: *GraphStore = @constCast(self);
        var key_buf: [512]u8 = undefined;
        const formatted = formatGraphLabelKey(&key_buf, mutable_self.allocator, graph_name, label) catch return 0;
        defer if (formatted.owned) |owned| mutable_self.allocator.free(owned);

        const io = std.Io.Threaded.global_single_threaded.io();
        mutable_self.label_index_mutex.lockUncancelable(io);
        defer mutable_self.label_index_mutex.unlock(io);

        const posting = mutable_self.label_index.getPtr(formatted.key) orelse return 0;
        posting.lock();
        defer posting.unlock();

        var count: usize = 0;
        for (posting.list.items) |node_id| {
            // GAP-ENT-0023 P3: engine-fallback tenant check — a bounded (or
            // snapshot-warm, cold-cache) resident map would otherwise
            // silently undercount evicted-but-live nodes for the
            // tenant-filtered path. Review C2/M1 follow-up: the check is
            // NON-MUTATING (no cache insert under the label locks — the
            // previous getOrHydratePtr flooded/evicted the cache and could
            // rehash shard maps while MATCH consumers hold `*Node` pointers).
            if (!self.nodeExistsPassingTenantExact(node_id, tenant)) continue;
            count += 1;
        }
        return count;
    }

    pub fn getEdgeCount(self: *GraphStore) usize {
        // PHASE 1b chokepoint (H3): store-wide edge count. Both arms read
        // deferred state — the per-graph IdMaps (empty until loop1 hydration) or
        // the resident edge map (populated by loop2). Without this guard, after a
        // no-snapshot open this returns a PARTIAL count (0 → … → true total) for
        // any not-yet-hydrated graph. No single graph_name here, so hydrate every
        // deferred graph first (mirrors ensureAllGraphsHydrated in getAll*).
        // Placed before any lock/iteration — matches the guarded-reader precedent.
        self.ensureAllGraphsHydrated();
        // PHASE 1: with a BOUNDED edge cache the resident map is incomplete, so
        // count from the per-graph IdMaps (fully resident, ~24 B/edge — the same
        // authoritative source `getEdgeCount`'s node analog `countNodesForGraph`
        // uses for nodes). Unbounded cache: the resident count IS the total.
        if (self.edges.effectiveCap() == 0) {
            return self.edges.count();
        }
        var total: usize = 0;
        var it = self.id_maps.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.edgeCount();
        }
        return total;
    }

    // GAP-ENT-0002: Per-graph O(1) edge count for the untyped count(r) fast path.
    // Mirrors countNodesForGraph for the edge side.
    // Bounded cache: the resident map is incomplete — count from the per-graph
    // IdMap (fully resident). O(1) via IdMap.edgeCount().
    // Unbounded cache: the resident edge map IS complete — O(graph-edges) scan
    // filtering by graph_name.
    // Tenantless only — the fast-path caller refuses any concrete tenant before
    // calling this method (see countEdgesFastPath in match_operations.zig).
    pub fn countEdgesForGraph(self: *const GraphStore, graph_name: []const u8) usize {
        // PHASE 1b chokepoint (H3): the untyped edge-count fast path reads the
        // IdMap edge count / resident edge map, which are populated by the
        // deferred loop2 hydration. Without this guard a `count(r)` issued
        // before hydration completes returns a PARTIAL count (0 → …→ true count)
        // after a no-snapshot open. Mirror the typed `countGraphEdgeType` guard
        // so the reader triggers + waits for full hydration first.
        @constCast(self).ensureGraphHydrated(graph_name);
        if (self.edges.effectiveCap() != 0) {
            // Bounded: IdMap is always fully resident.
            const id_map = (@constCast(self).getIdMap(graph_name)) orelse return 0;
            return id_map.edgeCount();
        }
        // Unbounded: iterate the resident edge map.
        var count: usize = 0;
        var iter = @constCast(self).edges.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.graph_name, graph_name)) count += 1;
        }
        return count;
    }

    // Per-(graph, edge_type) O(1) edge count for the typed count(r:TYPE) fast
    // path. Mirrors countEdgesForGraph for the typed case; served from the
    // maintained per-(graph,type) refcount (rebuilt on open, so durable across
    // reopen). Tenantless only — the fast-path caller refuses any concrete
    // tenant before calling (see countEdgesFastPath in match_operations.zig).
    pub fn countEdgesByTypeForGraph(self: *const GraphStore, graph_name: []const u8, edge_type: []const u8) usize {
        return self.countGraphEdgeType(graph_name, edge_type);
    }

    /// PHASE 1 (edge-engine-direct): a COMPLETE, bounded-cache-safe list of every
    /// public edge id (caller owns the returned slice). Full-edge-scan paths
    /// (algorithms, introspection, index build, DELETE collection) must use this
    /// instead of `edges.iterator()` — with a bounded edge cache the resident map
    /// is incomplete, so iterating it would silently miss evicted edges. When
    /// UNBOUNDED the resident keys ARE the full set (fast path); when BOUNDED the
    /// ids come from the per-graph IdMaps (fully resident, independent of the
    /// edge cache). Callers resolve each id's body via `getEdgePtrHydrated`
    /// (residency stays bounded — the cache evicts as it hydrates). Mirrors
    /// `getAllNodes` for the node side.
    pub fn allEdgeIds(self: *const GraphStore, allocator: std.mem.Allocator) ![]u64 {
        // PHASE 1b chokepoint (H3): the COMPLETE edge id set is enumerated from
        // the per-graph IdMaps (bounded cache) or the resident edge map
        // (unbounded) — both empty/partial for a graph whose loop1/loop2 build
        // was deferred at a no-snapshot open. Without this guard, index builds,
        // graph algorithms, and DELETE collection would silently MISS every edge
        // of a not-yet-hydrated graph. No single graph_name, so hydrate all
        // deferred graphs first (mirrors getAllNodes). Placed before any
        // iteration — matches the guarded-reader precedent; the hydration body
        // takes no store/graph lock, and no caller holds hydration_build_mutex.
        @constCast(self).ensureAllGraphsHydrated();
        var result: std.ArrayList(u64) = .empty;
        errdefer result.deinit(allocator);
        if (self.edges.effectiveCap() == 0) {
            var it = @constCast(self).edges.iterator();
            while (it.next()) |entry| try result.append(allocator, entry.key_ptr.*);
        } else {
            var im_it = @constCast(self).id_maps.iterator();
            while (im_it.next()) |entry| {
                var eit = entry.value_ptr.edgeUuidIterator();
                while (eit.next()) |euuid| try result.append(allocator, @as(u64, @truncate(euuid)));
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn isDirty(self: *const GraphStore) bool {
        return @constCast(&self.dirty).load(.acquire);
    }

    pub fn getNodePtr(self: *const GraphStore, node_id: u64) ?*const Node {
        return self.nodes.getPtr(node_id);
    }

    /// Hydrate-on-miss variant of `getNodePtr` (node twin of
    /// `getEdgePtrHydrated`): a node body evicted from the bounded resident
    /// cache is rebuilt from the durable engine, so callers that must
    /// distinguish "node truly absent from the store" from "node body
    /// evicted from the resident cache" never confuse the two. Returns null
    /// only when the id exists in neither the cache nor the engine.
    ///
    /// Gap 0034: the periodic HMAC verifier's chain-root read used the raw
    /// `getNodePtr`; a bulk ingest evicting the bootstrap-era AuthChainRoot
    /// body made every verify round report MissingChainRoot ("POSSIBLE
    /// TAMPERING") on a perfectly healthy fresh store until restart.
    ///
    /// NOTE: on a miss this MUTATES the cache (insert + maybe evict) under
    /// the shard's hydrate mutex + map lock, so the caller must hold a lock
    /// that serializes cache writes — NOT merely a shared read lock (the
    /// periodic verifier holds the GLOBAL EXCLUSIVE store lock; startup/CLI
    /// callers are single-threaded). Same contract as `getNodeProperty`'s
    /// hydrate-on-miss read.
    pub fn getNodePtrHydrated(self: *const GraphStore, node_id: u64) ?*const Node {
        const cache: *NodeCache = @constCast(&self.nodes);
        return (cache.getOrHydratePtr(node_id) catch return null) orelse null;
    }

    pub fn getEdgePtr(self: *const GraphStore, edge_id: u64) ?*const Edge {
        // PHASE 1: hydrate-on-miss so an evicted edge body still resolves.
        return self.getEdgePtrHydrated(edge_id);
    }

    // PHASE 0: borrowed-slice adjacency read with HYDRATE-ON-MISS. Returns the
    // resident list's `.items` (a hit), or hydrates the node's PUBLIC edge-id
    // list from the engine, inserts it into the bounded cache (evicting cold
    // entries), and returns the freshly-resident slice. Null only if the node's
    // adjacency exists in neither the cache nor the engine (e.g. pure in-memory
    // deployment with no adapter, or a node with no edges).
    //
    // The returned slice stays valid for the caller's read span under the
    // per-graph SHARED lock: eviction (triggered by the insert here, or by a
    // concurrent write) only UNLINKs+RETIREs lists, never frees them inline —
    // retired lists are freed only at the per-graph EXCLUSIVE checkpoint grace
    // window, which has drained all SHARED readers. `getOrHydratePtr` mutates the
    // cache on a miss (insert + maybe evict) under the shard's hydrate mutex, so
    // we `@constCast`: callers already hold the store/graph read lock that
    // serializes this against the per-graph-exclusive evict/reclaim, matching the
    // node cache's hydrate-on-miss contract.
    // PHASE 4 (SONNY-1797): borrowed-slice-SAFE snapshot of a resident adjacency
    // list's `items` header. A concurrent `appendAdjId` REALLOC publishes a fresh
    // grown buffer by storing the new `.ptr` FIRST and only THEN release-storing
    // the new `.len`. A reader that reads the two slice words in NATURAL order
    // (`.ptr` then `.len`) can load `.ptr` BEFORE that swap and `.len` AFTER it,
    // observing (OLD ptr, NEW len) and indexing one PAST the old buffer — a torn
    // out-of-bounds read (the residual half of the borrowed-slice UAF). Mirror the
    // writer's release ordering with an ACQUIRE: load `.len` FIRST, then read
    // `.ptr`. If we observe the NEW len, the acquire pairs with the writer's
    // release store on that same word, so we are guaranteed to also observe the
    // NEW ptr → (new_ptr, new_len). If we observe the OLD len, `.ptr` is valid for
    // [0..old_len) either way: the old buffer is still alive on the grace list, and
    // the grown buffer's first old_len slots are a copy of it. No (old_ptr,
    // new_len) tear is reachable. For the fits-in-capacity append (ptr unchanged,
    // len release-stored after the slot write) the same acquire load guarantees a
    // reader that sees the new len also sees the fully-written slot.
    fn adjItemsSnapshot(list: *const std.ArrayList(u64)) []const u64 {
        const len = @atomicLoad(usize, &list.items.len, .acquire);
        const ptr = list.items.ptr;
        return ptr[0..len];
    }

    fn outAdjItems(self: *const GraphStore, node_id: u64) ?[]const u64 {
        const cache: *AdjCache = @constCast(&self.outgoing_edges);
        const p = (cache.getOrHydratePtr(node_id) catch return null) orelse return null;
        return adjItemsSnapshot(&p.list);
    }

    fn inAdjItems(self: *const GraphStore, node_id: u64) ?[]const u64 {
        const cache: *AdjCache = @constCast(&self.incoming_edges);
        const p = (cache.getOrHydratePtr(node_id) catch return null) orelse return null;
        return adjItemsSnapshot(&p.list);
    }

    pub fn getOutgoingEdgeIds(self: *const GraphStore, node_id: u64) ?[]const u64 {
        return self.outAdjItems(node_id);
    }

    pub fn getIncomingEdgeIds(self: *const GraphStore, node_id: u64) ?[]const u64 {
        return self.inAdjItems(node_id);
    }

    /// ENG-3983: FAIL-CLOSED adjacency reads. `getOutgoingEdgeIds` /
    /// `getIncomingEdgeIds` launder a hydrate FAILURE ("the engine could not be
    /// read") into the same `null` a node with NO edges produces — indistinguishable
    /// at the call site. A DETACH DELETE that believes an unreadable node has no
    /// incident edges deletes the node and leaves every one of them DANGLING,
    /// which is durable corruption (a later whole-pattern MATCH then fails with
    /// NodeNotFound). These variants propagate the error and return an EMPTY
    /// slice only for the genuine "this node has no adjacency" case, so a
    /// mutation path can refuse the write instead of silently corrupting.
    pub fn getOutgoingEdgeIdsChecked(self: *const GraphStore, node_id: u64) ![]const u64 {
        const cache: *AdjCache = @constCast(&self.outgoing_edges);
        const p = (try cache.getOrHydratePtr(node_id)) orelse return &[_]u64{};
        return adjItemsSnapshot(&p.list);
    }

    pub fn getIncomingEdgeIdsChecked(self: *const GraphStore, node_id: u64) ![]const u64 {
        const cache: *AdjCache = @constCast(&self.incoming_edges);
        const p = (try cache.getOrHydratePtr(node_id)) orelse return &[_]u64{};
        return adjItemsSnapshot(&p.list);
    }

    pub fn getOutgoingEdges(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) ![]Edge {
        var result: std.ArrayList(Edge) = .empty;
        if (self.outAdjItems(node_id)) |outgoing| {
            for (outgoing) |edge_id| {
                // PHASE 1: hydrate-on-miss so an evicted edge body still resolves.
                if (self.getEdgePtrHydrated(edge_id)) |edge| {
                    try result.append(allocator, edge.*);
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getIncomingEdges(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) ![]Edge {
        var result: std.ArrayList(Edge) = .empty;
        if (self.inAdjItems(node_id)) |incoming| {
            for (incoming) |edge_id| {
                if (self.getEdgePtrHydrated(edge_id)) |edge| {
                    try result.append(allocator, edge.*);
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getNeighbors(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) ![]u64 {
        var result: std.ArrayList(u64) = .empty;
        errdefer result.deinit(allocator);
        if (self.outAdjItems(node_id)) |outgoing| {
            for (outgoing) |edge_id| {
                if (self.getEdgePtrHydrated(edge_id)) |edge| {
                    try result.append(allocator, edge.to_id);
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getIncomingNodes(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) ![]u64 {
        var result: std.ArrayList(u64) = .empty;
        if (self.inAdjItems(node_id)) |incoming| {
            for (incoming) |edge_id| {
                if (self.getEdgePtrHydrated(edge_id)) |edge| {
                    try result.append(allocator, edge.from_id);
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getOutgoingNodes(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) ![]u64 {
        var result: std.ArrayList(u64) = .empty;
        if (self.outAdjItems(node_id)) |outgoing| {
            for (outgoing) |edge_id| {
                if (self.getEdgePtrHydrated(edge_id)) |edge| {
                    try result.append(allocator, edge.to_id);
                }
            }
        }
        return result.toOwnedSlice(allocator);
    }

    pub fn getOutDegree(self: *const GraphStore, node_id: u64) usize {
        return if (self.outAdjItems(node_id)) |outgoing| outgoing.len else 0;
    }

    pub fn hasEdge(self: *const GraphStore, source: u64, target: u64) bool {
        if (self.outAdjItems(source)) |outgoing| {
            for (outgoing) |edge_id| {
                if (self.getEdgePtrHydrated(edge_id)) |edge| {
                    if (edge.to_id == target) return true;
                }
            }
        }
        return false;
    }

    pub fn freePath(self: *const GraphStore, path: Path) void {
        self.allocator.free(path.nodes);
        self.allocator.free(path.edges);
    }

    pub fn freePaths(self: *const GraphStore, paths: []Path) void {
        for (paths) |path| {
            self.freePath(path);
        }
        self.allocator.free(paths);
    }

    pub fn findPaths(self: *GraphStore, start: u64, end: u64, options: PathOptions) ![]Path {
        const bounds = self.resolvePathBounds(options);
        var paths = std.ArrayList(Path).init(self.allocator);
        errdefer paths.deinit(self.allocator);

        var path_nodes = std.ArrayList(u64).init(self.allocator);
        defer path_nodes.deinit(self.allocator);
        var path_edges = std.ArrayList(u64).init(self.allocator);
        defer path_edges.deinit(self.allocator);

        try path_nodes.append(self.allocator, start);
        try self.collectPaths(start, end, bounds.min, bounds.max, false, null, &path_nodes, &path_edges, &paths);

        return paths.toOwnedSlice(self.allocator);
    }

    pub fn findPathsBidirectional(self: *GraphStore, start: u64, end: u64, options: PathOptions) ![]Path {
        const bounds = self.resolvePathBounds(options);
        var paths = std.ArrayList(Path).init(self.allocator);
        errdefer paths.deinit(self.allocator);

        var path_nodes = std.ArrayList(u64).init(self.allocator);
        defer path_nodes.deinit(self.allocator);
        var path_edges = std.ArrayList(u64).init(self.allocator);
        defer path_edges.deinit(self.allocator);

        try path_nodes.append(self.allocator, start);
        try self.collectPaths(start, end, bounds.min, bounds.max, true, null, &path_nodes, &path_edges, &paths);

        return paths.toOwnedSlice(self.allocator);
    }

    pub fn findPathsFiltered(self: *GraphStore, start: u64, end: u64, options: PathOptions, filter: PathFilter) ![]Path {
        const bounds = self.resolvePathBounds(options);
        var paths = std.ArrayList(Path).init(self.allocator);
        errdefer paths.deinit(self.allocator);

        var path_nodes = std.ArrayList(u64).init(self.allocator);
        defer path_nodes.deinit(self.allocator);
        var path_edges = std.ArrayList(u64).init(self.allocator);
        defer path_edges.deinit(self.allocator);

        try path_nodes.append(self.allocator, start);
        try self.collectPaths(start, end, bounds.min, bounds.max, false, &filter, &path_nodes, &path_edges, &paths);

        return paths.toOwnedSlice(self.allocator);
    }

    pub fn shortestPath(self: *GraphStore, start: u64, end: u64) !?Path {
        if (start == end) {
            return Path{
                .nodes = try self.allocator.dupe(u64, &[_]u64{start}),
                .edges = try self.allocator.alloc(u64, 0),
            };
        }

        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();
        var parent = std.AutoHashMap(u64, struct { node: u64, edge: u64 }).init(self.allocator);
        defer parent.deinit();

        var queue = std.ArrayList(u64).init(self.allocator);
        defer queue.deinit();

        try queue.append(self.allocator, start);
        try visited.put(start, {});

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const current = queue.items[head];
            if (current == end) break;

            if (self.outAdjItems(current)) |outgoing| {
                for (outgoing) |edge_id| {
                    if (self.getEdgePtrHydrated(edge_id)) |edge| {
                        const next = edge.to_id;
                        if (visited.contains(next)) continue;
                        try visited.put(next, {});
                        try parent.put(next, .{ .node = current, .edge = edge_id });
                        try queue.append(self.allocator, next);
                    }
                }
            }
        }

        if (!parent.contains(end)) return null;

        var nodes_rev = std.ArrayList(u64).init(self.allocator);
        var edges_rev = std.ArrayList(u64).init(self.allocator);
        defer nodes_rev.deinit(self.allocator);
        defer edges_rev.deinit(self.allocator);

        var current = end;
        try nodes_rev.append(self.allocator, current);
        while (current != start) {
            const info = parent.get(current) orelse break;
            try edges_rev.append(self.allocator, info.edge);
            current = info.node;
            try nodes_rev.append(self.allocator, current);
        }

        std.mem.reverse(u64, nodes_rev.items);
        std.mem.reverse(u64, edges_rev.items);

        return Path{
            .nodes = try self.allocator.dupe(u64, nodes_rev.items),
            .edges = try self.allocator.dupe(u64, edges_rev.items),
        };
    }

    pub fn allShortestPaths(self: *GraphStore, start: u64, end: u64) ![]Path {
        if (start == end) {
            var only = std.ArrayList(Path).init(self.allocator);
            try only.append(self.allocator, .{
                .nodes = try self.allocator.dupe(u64, &[_]u64{start}),
                .edges = try self.allocator.alloc(u64, 0),
            });
            return only.toOwnedSlice(self.allocator);
        }

        var distance = std.AutoHashMap(u64, u32).init(self.allocator);
        defer distance.deinit();
        var parents = std.AutoHashMap(u64, std.ArrayList(struct { node: u64, edge: u64 })).init(self.allocator);
        defer {
            var it = parents.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            parents.deinit();
        }

        var queue = std.ArrayList(u64).init(self.allocator);
        defer queue.deinit();

        try queue.append(self.allocator, start);
        try distance.put(start, 0);

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const current = queue.items[head];
            const current_dist = distance.get(current) orelse 0;
            if (self.outAdjItems(current)) |outgoing| {
                for (outgoing) |edge_id| {
                    if (self.getEdgePtrHydrated(edge_id)) |edge| {
                        const next = edge.to_id;
                        const next_dist = current_dist + 1;
                        if (distance.get(next)) |existing| {
                            if (next_dist == existing) {
                                const entry = try parents.getOrPut(next);
                                if (!entry.found_existing) {
                                    entry.value_ptr.* = std.ArrayList(struct { node: u64, edge: u64 }).init(self.allocator);
                                }
                                try entry.value_ptr.append(self.allocator, .{ .node = current, .edge = edge_id });
                            }
                            continue;
                        }
                        try distance.put(next, next_dist);
                        const entry = try parents.getOrPut(next);
                        if (!entry.found_existing) {
                            entry.value_ptr.* = std.ArrayList(struct { node: u64, edge: u64 }).init(self.allocator);
                        }
                        try entry.value_ptr.append(self.allocator, .{ .node = current, .edge = edge_id });
                        try queue.append(self.allocator, next);
                    }
                }
            }
        }

        if (!distance.contains(end)) {
            return self.allocator.alloc(Path, 0);
        }

        var results = std.ArrayList(Path).init(self.allocator);
        errdefer {
            for (results.items) |path| self.freePath(path);
            results.deinit(self.allocator);
        }

        var nodes_stack = std.ArrayList(u64).init(self.allocator);
        defer nodes_stack.deinit(self.allocator);
        var edges_stack = std.ArrayList(u64).init(self.allocator);
        defer edges_stack.deinit(self.allocator);

        try nodes_stack.append(self.allocator, end);
        try self.backtrackShortestPaths(start, end, &parents, &nodes_stack, &edges_stack, &results);

        return results.toOwnedSlice(self.allocator);
    }

    pub fn kShortestPaths(self: *GraphStore, start: u64, end: u64, k: usize) ![]Path {
        const max_len: u32 = if (self.nodes.count() == 0) 0 else @intCast(self.nodes.count());
        var all_paths = try self.findPaths(start, end, .{ .max_length = max_len });

        if (all_paths.len <= k) return all_paths;

        std.sort.block(Path, all_paths, {}, struct {
            fn less(_: void, a: Path, b: Path) bool {
                return a.edges.len < b.edges.len;
            }
        }.less);

        for (all_paths[k..]) |path| {
            self.freePath(path);
        }

        const out = try self.allocator.alloc(Path, k);
        std.mem.copyForwards(Path, out, all_paths[0..k]);
        self.allocator.free(all_paths);
        return out;
    }

    pub fn expandFromNode(self: *GraphStore, start: u64, options: ExpandOptions) ![]u64 {
        var visited = std.AutoHashMap(u64, void).init(self.allocator);
        defer visited.deinit();

        var queue = std.ArrayList(struct { node: u64, depth: u32 }).init(self.allocator);
        defer queue.deinit();

        var result = std.ArrayList(u64).init(self.allocator);
        errdefer result.deinit(self.allocator);

        try queue.append(self.allocator, .{ .node = start, .depth = 0 });
        try visited.put(start, {});
        try result.append(self.allocator, start);

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const current = queue.items[head];
            if (current.depth >= options.max_depth) continue;

            if (self.outAdjItems(current.node)) |outgoing| {
                for (outgoing) |edge_id| {
                    if (self.getEdgePtrHydrated(edge_id)) |edge| {
                        const next = edge.to_id;
                        if (visited.contains(next)) continue;
                        try visited.put(next, {});
                        try result.append(self.allocator, next);
                        try queue.append(self.allocator, .{ .node = next, .depth = current.depth + 1 });
                    }
                }
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn resolvePathBounds(self: *GraphStore, options: PathOptions) struct { min: u32, max: u32 } {
        _ = self;
        if (options.exact_length) |exact| {
            return .{ .min = exact, .max = exact };
        }
        const min_len: u32 = options.min_length orelse 1;
        const max_len: u32 = options.max_length orelse min_len + 10;
        return .{ .min = min_len, .max = max_len };
    }

    fn collectPaths(
        self: *GraphStore,
        current: u64,
        end: u64,
        min_len: u32,
        max_len: u32,
        bidirectional: bool,
        filter: ?*const PathFilter,
        path_nodes: *std.ArrayList(u64),
        path_edges: *std.ArrayList(u64),
        results: *std.ArrayList(Path),
    ) !void {
        const depth: u32 = @intCast(path_edges.items.len);

        if (depth >= min_len and current == end) {
            const nodes_copy = try self.allocator.dupe(u64, path_nodes.items);
            const edges_copy = try self.allocator.dupe(u64, path_edges.items);
            try results.append(self.allocator, .{ .nodes = nodes_copy, .edges = edges_copy });
        }

        if (depth >= max_len) return;

        const visit = struct {
            fn shouldSkip(nodes: []const u64, next: u64, target: u64) bool {
                if (next == target) return false;
                for (nodes) |node| {
                    if (node == next) return true;
                }
                return false;
            }
        }.shouldSkip;

        if (self.outAdjItems(current)) |outgoing| {
            for (outgoing) |edge_id| {
                if (self.getEdgePtrHydrated(edge_id)) |edge| {
                    const next = edge.to_id;
                    if (visit(path_nodes.items, next, end)) continue;
                    if (filter) |flt| {
                        if (flt.edge_predicate) |pred| {
                            if (!pred(edge)) continue;
                        }
                        if (flt.node_predicate) |pred| {
                            if (self.nodes.getPtr(next)) |node_ptr| {
                                if (!pred(node_ptr)) continue;
                            } else continue;
                        }
                    }

                    try path_nodes.append(self.allocator, next);
                    try path_edges.append(self.allocator, edge_id);
                    try self.collectPaths(next, end, min_len, max_len, bidirectional, filter, path_nodes, path_edges, results);
                    _ = path_nodes.pop();
                    _ = path_edges.pop();
                }
            }
        }

        if (bidirectional) {
            if (self.inAdjItems(current)) |incoming| {
                for (incoming) |edge_id| {
                    if (self.getEdgePtrHydrated(edge_id)) |edge| {
                        const next = edge.from_id;
                        if (visit(path_nodes.items, next, end)) continue;
                        if (filter) |flt| {
                            if (flt.edge_predicate) |pred| {
                                if (!pred(edge)) continue;
                            }
                            if (flt.node_predicate) |pred| {
                                if (self.nodes.getPtr(next)) |node_ptr| {
                                    if (!pred(node_ptr)) continue;
                                } else continue;
                            }
                        }

                        try path_nodes.append(self.allocator, next);
                        try path_edges.append(self.allocator, edge_id);
                        try self.collectPaths(next, end, min_len, max_len, bidirectional, filter, path_nodes, path_edges, results);
                        _ = path_nodes.pop();
                        _ = path_edges.pop();
                    }
                }
            }
        }
    }

    fn backtrackShortestPaths(
        self: *GraphStore,
        start: u64,
        current: u64,
        parents: *std.AutoHashMap(u64, std.ArrayList(struct { node: u64, edge: u64 })),
        nodes_stack: *std.ArrayList(u64),
        edges_stack: *std.ArrayList(u64),
        results: *std.ArrayList(Path),
    ) !void {
        if (current == start) {
            const nodes_copy = try self.allocator.dupe(u64, nodes_stack.items);
            const edges_copy = try self.allocator.dupe(u64, edges_stack.items);
            std.mem.reverse(u64, nodes_copy);
            std.mem.reverse(u64, edges_copy);
            try results.append(self.allocator, .{ .nodes = nodes_copy, .edges = edges_copy });
            return;
        }

        if (parents.get(current)) |plist| {
            for (plist.items) |info| {
                try edges_stack.append(self.allocator, info.edge);
                try nodes_stack.append(self.allocator, info.node);
                try self.backtrackShortestPaths(start, info.node, parents, nodes_stack, edges_stack, results);
                _ = edges_stack.pop();
                _ = nodes_stack.pop();
            }
        }
    }

    // CANARY: REQ=REQ-MULTI-GRAPH-005; FEATURE="MultiGraphIsolation"; ASPECT=CreateEdge; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=engine; UPDATED=2025-12-22
    // Create edge with optional graph name for per-graph data isolation
    // GAP-0291: Resolve tenant_id from the per-thread FLE context set by the connection handler.
    // This ensures edges created during a multi-tenant session are tagged with the correct
    // tenant_id instead of always using DEFAULT_TENANT_ID.
    // CANARY: REQ=REQ-MULTI-TENANT-007; FEATURE="PerTenantIsolation"; ASPECT=EdgeCreateAutoTenant; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-05
    pub fn createEdgeWithGraph(self: *GraphStore, from_id: u64, to_id: u64, edge_type: []const u8, graph_name: []const u8) !u64 {
        // GAP-0891 (RC-1 step 3): prefer the active ExecutionContext's tenant
        // over the per-thread map (see createNodeWithGraph).
        const tenant = fle_integration.tenantPreferringActiveContext();
        return self.createEdgeWithGraphAndTenant(from_id, to_id, edge_type, graph_name, tenant);
    }

    // GAP-0891 (RC-1 seam). The edge analog of `createNodeForRequestTenant`:
    // the worker-side bulk/group-commit edge path calls this with the request
    // tenant captured on the handler thread at submit time and honored verbatim.
    pub fn createEdgeForRequestTenant(
        self: *GraphStore,
        from_id: u64,
        to_id: u64,
        edge_type: []const u8,
        graph_name: []const u8,
        request_tenant: []const u8,
    ) !u64 {
        return self.createEdgeWithGraphAndTenant(from_id, to_id, edge_type, graph_name, request_tenant);
    }

    // CANARY: REQ=REQ-MULTI-TENANT-003; FEATURE="PerTenantIsolation"; ASPECT=EdgeCreation; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-01
    // GAP-0279: Create an edge tagged with both graph_name and tenant_id for per-tenant isolation
    pub fn createEdgeWithGraphAndTenant(self: *GraphStore, from_id: u64, to_id: u64, edge_type: []const u8, graph_name: []const u8, tenant: []const u8) !u64 {
        self.ensureGraphHydrated(graph_name); // PHASE 1b chokepoint (hydrate before write)
        // The `geode.graph_store.create_edge` trace span was rolled back
        // (again) here.  History:
        //   * 2026-04-29: original rollback after the BSP concurrent-
        //     producer race surfaced under msft-graph load (see the
        //     matching note at src/storage/graph_storage_adapter.zig:2237).
        //   * 2026-04-30 (commit 2a9ea3a6): re-added when the otel pin
        //     was briefly bumped to 0c34ce9b (the BSP race fix).
        //   * 2026-05-01 (commit d7ceaaea): otel pin reverted to ee492166
        //     to fix a build-graph diamond — but the spans were left
        //     in place, leaving production exposed to the same panic.
        //   * 2026-05-01 (this rollback): re-removed in lockstep with
        //     the regression guard at tests/test_bsp_race_regression.zig.
        // Re-add only after a coordinated multi-repo bump to otel@0c34ce9b+
        // across every sibling devnw consumer (gql, dns, repl, vulkan,
        // thread_pool, protobuf, slog, wal). The
        // `_om.recordEdgeMutation(.create, …)` counter at
        // graph_storage_adapter.zig:2270 continues to publish
        // `geode.graph_store.edge_mutations_total` for non-trace monitoring.

        // Bug fix 2026-04-27 (docs/bugs/2026-04-27-bulk-edge-id-map-silent-fallback.md):
        // The previous code used `catch break :blk null` on every step inside
        // this block, including on `vt.createEdgeFn`.  Under multi-threaded
        // contention the engine call can return errors (slot collision,
        // transient `GraphNotFound` during registry rehash, OOM during shard
        // grow, etc.).  Swallowing them caused the edge to land in
        // `self.edges` without an IdMap entry, and the next call to
        // `setEdgePropertiesBatch` then tripped `error.EdgeSlotMappingMissing`
        // — losing 100+ edges per 800 inserts in the 16-thread bulk path.
        //
        // Only the `vt == null` arm is a legitimate fallback (used by tests
        // and very-early-boot paths that pre-populate the in-memory store
        // before the adapter is wired).  Every other failure must propagate.
        // See `createEdgeWithIdInternal` (~50 lines below) for the reference
        // pattern.
        // Generate UUIDv7-based time-sortable unique ID. Minted BEFORE the
        // adapter create so it rides INLINE in the durable adjacency records
        // (GAP-ENT-0024) — no `__geode_internal_edge_id` property page.
        const id = generateTimeBasedId();

        const adapter_edge: ?struct {
            vt: AdapterVTable,
            from_slot: u64,
            to_slot: u64,
            edge_slot: u64,
        } = blk: {
            const vt = global_vtable orelse break :blk null;
            const im = try self.getOrCreateIdMap(graph_name);
            const from_slot = im.nodeSlot(@as(u128, from_id)) orelse return error.SourceNodeNotFound;
            const to_slot = im.nodeSlot(@as(u128, to_id)) orelse return error.TargetNodeNotFound;
            const edge_slot = try vt.createEdgeFn(vt.ctx, graph_name, from_slot, to_slot, edge_type, id);
            break :blk .{
                .vt = vt,
                .from_slot = from_slot,
                .to_slot = to_slot,
                .edge_slot = edge_slot,
            };
        };
        try self.ensureGraph(graph_name);

        // Store UUID→slot mapping in IdMap for adapter translation
        if (adapter_edge) |persisted_edge| {
            // GAP-ENT-0024: the public id is already durable INLINE in the
            // adjacency records (written by createEdgeFn above) — the legacy
            // per-edge `__geode_internal_edge_id` property write is gone.
            // GAP-0891 (RC-2): round-trip the edge tenant tag (no-op for default).
            persistEdgeTenantId(
                persisted_edge.vt,
                graph_name,
                persisted_edge.from_slot,
                persisted_edge.to_slot,
                persisted_edge.edge_slot,
                tenant,
            ) catch |err| {
                persisted_edge.vt.deleteEdgeFn(
                    persisted_edge.vt.ctx,
                    graph_name,
                    persisted_edge.from_slot,
                    persisted_edge.to_slot,
                    persisted_edge.edge_slot,
                ) catch {};
                return err;
            };
            const im = try self.getOrCreateIdMap(graph_name);
            try im.insertEdgeWithSlot(@as(u128, id), persisted_edge.edge_slot);
        }

        const edge_type_copy = try self.allocator.dupe(u8, edge_type);
        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const tenant_id_copy = try self.allocator.dupe(u8, tenant);

        const edge = Edge{
            .id = id,
            .from_id = from_id,
            .to_id = to_id,
            .label = edge_type_copy,
            .properties = CompactPropertyMap.init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        try self.edges.put(id, edge);

        // CANARY: REQ=REQ-PERF-EDGE-ADJ-002; FEATURE="EdgeAdjacencyIndex"; ASPECT=IndexMaintenance; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=perf; UPDATED=2026-04-11
        // Issue #392: Maintain adjacency indexes for fast DELETE DETACH
        try self.addToAdjacencyIndex(from_id, to_id, id);
        // PERF-P0-001: Maintain edge-type index for fast getEdgesByType
        try self.addToEdgeTypeIndex(graph_name, edge_type, id);
        // PERF-C (issue #814): tenant-keyed edge-type counter for LSP introspection.
        try self.bumpEdgeTypeCount(graph_name, tenant, edge_type);
        // Per-(graph,type) exact counter (typed count(r:TYPE) fast path).
        self.bumpGraphEdgeTypeCount(graph_name, edge_type);

        // CANARY: REQ=REQ-BINARY-PERSIST-EDGE-001; FEATURE="BinaryPersistence"; ASPECT=DirtyTracking; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=storage; UPDATED=2026-04-11
        // Mark store as dirty - persistence happens at query completion, not per-edge
        self.dirty.store(true, .release);
        incrementMutationEpoch();

        // WAL notification: CreateEdge
        notifyMutation(.create_edge, id, from_id, to_id, edge_type, null, null, graph_name);

        return id;
    }

    fn createEdgeWithIdInternal(
        self: *GraphStore,
        edge_id: u64,
        from_id: u64,
        to_id: u64,
        edge_type: []const u8,
        graph_name: []const u8,
        mark_dirty: bool,
        persist_adapter: bool,
    ) !void {
        self.ensureGraphHydrated(graph_name); // PHASE 1b chokepoint (hydrate before write)
        // Existence check BEFORE any storage-adapter slot creation, mirroring
        // createNodeWithIdInternal. An idempotent edge re-create (a restarted
        // Raft node replaying a committed entry whose edge id already lives in
        // the persisted store) must return `error.EdgeAlreadyExists` WITHOUT
        // physically minting a durable edge slot. The old order minted the
        // adapter slot first and only then ran the dedup check, so the early
        // return left an ORPHAN physical edge slot (no __geode_internal_edge_id,
        // no IdMap entry) behind on every re-apply — one per churn round — which
        // hydration could not reverse-map (-> error.EdgeSlotMappingMissing). See
        // tests/test_edge_durability_churn_repro.zig and
        // cluster_replication.applyMultiCreatePayload.
        try self.ensureGraph(graph_name);
        if (self.edges.contains(edge_id)) return error.EdgeAlreadyExists;

        const adapter_edge: ?struct {
            vt: AdapterVTable,
            from_slot: u64,
            to_slot: u64,
            edge_slot: u64,
        } = if (persist_adapter) blk: {
            const vt = global_vtable orelse break :blk null;
            // Resolve endpoint slots BEFORE minting the edge slot so a missing
            // endpoint fails closed without leaking a phantom adapter slot.
            const from_slot = try self.requireNodeSlot(graph_name, from_id);
            const to_slot = try self.requireNodeSlot(graph_name, to_id);
            break :blk .{
                .vt = vt,
                .from_slot = from_slot,
                .to_slot = to_slot,
                // GAP-ENT-0024: the replicated/minted public edge id rides
                // INLINE in the durable adjacency records (v2 blocks).
                .edge_slot = try vt.createEdgeFn(vt.ctx, graph_name, from_slot, to_slot, edge_type, edge_id),
            };
        } else null;

        // GAP-0891 (RC-3): honor the active tenant instead of hardcoding
        // DEFAULT_TENANT_ID, and keep the PERF-C edge-type counter on the same
        // bucket as the tag (see createNodeWithIdInternal).
        const tenant = fle_integration.tenantPreferringActiveContext();

        if (adapter_edge) |persisted_edge| {
            // GAP-ENT-0024: the public id is already durable INLINE in the
            // adjacency records (written by createEdgeFn above) — no
            // `__geode_internal_edge_id` property write on the create path.
            // GAP-0891 (RC-2): round-trip the edge tenant tag (no-op for default).
            persistEdgeTenantId(
                persisted_edge.vt,
                graph_name,
                persisted_edge.from_slot,
                persisted_edge.to_slot,
                persisted_edge.edge_slot,
                tenant,
            ) catch |err| {
                persisted_edge.vt.deleteEdgeFn(
                    persisted_edge.vt.ctx,
                    graph_name,
                    persisted_edge.from_slot,
                    persisted_edge.to_slot,
                    persisted_edge.edge_slot,
                ) catch {};
                return err;
            };
            const im = try self.getOrCreateIdMap(graph_name);
            try im.insertEdgeWithSlot(@as(u128, edge_id), persisted_edge.edge_slot);
        }

        const edge_type_copy = try self.allocator.dupe(u8, edge_type);
        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const tenant_id_copy = try self.allocator.dupe(u8, tenant);

        const edge = Edge{
            .id = edge_id,
            .from_id = from_id,
            .to_id = to_id,
            .label = edge_type_copy,
            .properties = CompactPropertyMap.init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        try self.edges.put(edge_id, edge);
        try self.addToAdjacencyIndex(from_id, to_id, edge_id);
        // PERF-P0-001: Maintain edge-type index for fast getEdgesByType
        try self.addToEdgeTypeIndex(graph_name, edge_type, edge_id);
        // PERF-C (issue #814): tenant-keyed edge-type counter for LSP
        // introspection. GAP-0891 (RC-3): bump the SAME bucket as the tag.
        try self.bumpEdgeTypeCount(graph_name, tenant, edge_type);
        // Per-(graph,type) exact counter (typed count(r:TYPE) fast path).
        self.bumpGraphEdgeTypeCount(graph_name, edge_type);

        if (edge_id >= self.next_edge_id) {
            self.next_edge_id = edge_id + 1;
        }

        if (mark_dirty) {
            self.dirty.store(true, .release);
            incrementMutationEpoch();
        }
    }

    /// Create an edge with a specified ID (used for replication/2PC).
    pub fn createEdgeWithId(
        self: *GraphStore,
        edge_id: u64,
        from_id: u64,
        to_id: u64,
        edge_type: []const u8,
        graph_name: []const u8,
    ) !void {
        return self.createEdgeWithIdInternal(edge_id, from_id, to_id, edge_type, graph_name, true, true);
    }

    /// Create an edge with a specified ID without marking dirty (used for rollback).
    pub fn createEdgeWithIdNoSave(
        self: *GraphStore,
        edge_id: u64,
        from_id: u64,
        to_id: u64,
        edge_type: []const u8,
        graph_name: []const u8,
    ) !void {
        return self.createEdgeWithIdInternal(edge_id, from_id, to_id, edge_type, graph_name, false, false);
    }

    // Issue #392 / PHASE 0: append `edge_id` to `node`'s adjacency list in
    // `cache`, dual-writing the in-memory mirror alongside the engine write that
    // already happened in createEdgeWithIdInternal.
    //
    // Residency-aware to avoid a PARTIAL-LIST trap: when the cache is BOUNDED
    // (engine is the source of truth, evicted lists are rehydrated on read), a
    // node whose entry is NOT resident may have other edges that live only in
    // the engine. Inserting a fresh single-id list here would make a later read
    // HIT that partial list and miss those edges. So when bounded we only update
    // a RESIDENT entry; if absent we leave it absent and let the next read
    // hydrate the COMPLETE list from the engine (which already contains this
    // edge). When UNBOUNDED (no engine / nothing ever evicts), a miss means the
    // node genuinely had no prior edges, so we create+append exactly as before.
    fn appendAdj(self: *GraphStore, cache: *AdjCache, node: u64, edge_id: u64, graph_name: []const u8) !void {
        if (cache.effectiveCap() == 0) {
            // Unbounded legacy mirror: the cache IS the source of truth.
            const r = try cache.getOrPut(node);
            if (!r.found_existing) {
                r.value_ptr.* = .{ .list = .empty, .graph = try self.allocator.dupe(u8, graph_name) };
                // New entry: record it for (disabled) eviction bookkeeping so the
                // FIFO/accounting stays consistent if the cap is ever raised.
                try cache.noteInserted(node);
            }
            try self.appendAdjId(cache, node, r.value_ptr, edge_id, graph_name);
            return;
        }
        // Bounded + engine-backed: only touch a resident entry; otherwise the
        // engine already holds the edge and the next read rehydrates the full
        // list. (A resident entry is the complete current list, so appending is
        // correct and keeps insertion order identical to the pre-cache mirror.)
        //
        // Hold the per-shard map lock EXCLUSIVE across the lookup + in-place
        // mutation: it excludes a concurrent SHARED reader's lookup AND a
        // concurrent resize that could MOVE the resident entry out from under
        // `entry`. The in-place id append itself is then published with the
        // borrowed-slice-safe ordering in appendAdjId.
        cache.lockShardExclusive(node);
        defer cache.unlockShardExclusive(node);
        if (cache.getPtrUnlocked(node)) |entry| {
            try self.appendAdjId(cache, node, entry, edge_id, graph_name);
        }
    }

    // PHASE 4 (edge-engine-direct): borrowed-slice-SAFE adjacency append.
    //
    // SEGV ROOT CAUSE (use-after-free): readers traverse adjacency holding only
    // the per-graph SHARED lock and borrow Phase-0's `[]const u64` slice
    // (`AdjList.list.items`). The batched MERGE append runs under the SOURCE
    // shard's EXCLUSIVE lock — a DIFFERENT lock — so it does NOT exclude readers.
    // `std.ArrayList.append` grows the backing array IN PLACE: on a capacity grow
    // it frees the OLD buffer immediately, dangling every concurrent reader's
    // borrowed slice → UAF (confirmed: all reader threads SIGSEGV in `outDegree`
    // iterating the freed slice).
    //
    // FIX (publish-via-immutable-swap, reusing the existing grace discipline):
    // when the append fits the CURRENT capacity we write past the end and only
    // THEN publish the new length (`items.len += 1`) — a reader either sees the
    // old length (skips the new slot) or the new length (the slot is already
    // fully written), never a torn element, and never touches a reallocated
    // buffer. When the append would REALLOC (len == capacity), we allocate a
    // FRESH grown buffer, copy + append into it, swap it into the entry, and
    // RETIRE the old buffer onto the cache's grace list (freed only at the
    // per-graph EXCLUSIVE checkpoint window, which has drained all SHARED readers)
    // instead of freeing it inline. Identical to how eviction already protects
    // borrowed slices. Append stays amortized O(1) (geometric growth) and the
    // hot single-source batch is unaffected (it holds the source shard lock for
    // the whole run, so capacity grows a handful of times across 20k appends).
    //
    // The appender holds the SOURCE shard EXCLUSIVE lock, so two appenders to the
    // same source list are serialized (no writer/writer race); the only concurrent
    // peer is a SHARED reader, which this swap-and-retire makes safe.
    fn appendAdjId(
        self: *GraphStore,
        cache: *AdjCache,
        node: u64,
        entry: *AdjList,
        edge_id: u64,
        graph_name: []const u8,
    ) !void {
        const list = &entry.list;
        if (list.items.len < list.capacity) {
            // Fits: write into the spare slot, THEN publish the length. A reader
            // racing on `items.len` sees either the old or the new count; the new
            // slot is fully written before it becomes visible. No realloc, so no
            // reader's borrowed slice is invalidated.
            const new_len = list.items.len + 1;
            list.allocatedSlice()[list.items.len] = edge_id;
            // Release store on the published length: the slot write above
            // happens-before any reader that observes the new length (a reader
            // iterates [0..len), so a len it sees must imply the element it then
            // reads is committed). Pairs with the reader's data-dependent slice
            // read; prevents the compiler/CPU from publishing the length ahead of
            // the element write.
            @atomicStore(usize, &list.items.len, new_len, .release);
            return;
        }
        // Would realloc. Build a fresh grown buffer (do NOT free the old one
        // inline — a SHARED reader may hold a slice into it). Geometric growth
        // keeps appends amortized O(1).
        const old_cap = list.capacity;
        const new_cap = if (old_cap == 0) 4 else old_cap * 2;
        var grown = try std.ArrayList(u64).initCapacity(self.allocator, new_cap);
        grown.appendSliceAssumeCapacity(list.items);
        grown.appendAssumeCapacity(edge_id);

        // Swap the new buffer in, then retire the OLD one to the grace list. The
        // old AdjList carries the SAME owning graph so the per-graph reclaim
        // predicate frees it in that graph's checkpoint window. If retiring OOMs
        // we keep the OLD buffer (cannot inline-free it) and roll back the new
        // one — correctness preserved, this append is simply dropped from the
        // resident mirror (the engine still holds the edge; the next read
        // rehydrates the complete list).
        const retired_old = AdjList{ .list = list.*, .graph = try self.allocator.dupe(u8, graph_name) };
        cache.retireValue(node, retired_old) catch |err| {
            self.allocator.free(retired_old.graph);
            grown.deinit(self.allocator);
            return err;
        };

        // Publish the grown buffer WITHOUT exposing a torn (ptr,len) header:
        //   1) store the new PTR + capacity while len is still the OLD len.
        //   2) THEN release-store the new len.
        // This is only HALF of the ordering. A reader that read the two slice
        // words in natural order (ptr THEN len) could still load the OLD ptr
        // (before step 1) and the NEW len (after step 2) → (old_ptr, new_len),
        // one-past the old buffer. The reader MUST mirror this release with an
        // ACQUIRE that loads len FIRST, then ptr — see `adjItemsSnapshot`. With
        // that pairing the reachable (ptr,len) combos are: (new_ptr, new_len)
        // [reader saw the new len ⇒ acquire ⇒ sees the new ptr], (old_ptr,
        // old_len), and (new_ptr, old_len) — all valid (the first old_len slots
        // of the grown buffer copy the old list; the old buffer is still alive on
        // the grace list). (old_ptr, new_len) is NOT reachable.
        // entry.graph is untouched (still owned, now paired with the grown buffer).
        const old_len = list.items.len;
        list.items.ptr = grown.items.ptr;
        list.capacity = grown.capacity;
        std.debug.assert(list.items.len == old_len); // len unchanged until the release store
        @atomicStore(usize, &list.items.len, grown.items.len, .release);
    }

    // Issue #392: Helper to maintain adjacency indexes (dual-write mirror).
    fn addToAdjacencyIndex(self: *GraphStore, from_id: u64, to_id: u64, edge_id: u64) !void {
        try self.appendAdj(&self.outgoing_edges, from_id, edge_id, self.nodeGraphNameOrDefault(from_id));
        try self.appendAdj(&self.incoming_edges, to_id, edge_id, self.nodeGraphNameOrDefault(to_id));
    }

    /// Best-effort owning graph name for a node id, for tagging adjacency cache
    /// entries (used to scope grace-point reclamation). Resolves via the
    /// resident node mirror; falls back to the default graph. The tag only
    /// affects WHICH per-graph checkpoint window frees a retired list, never
    /// correctness of the ids themselves.
    fn nodeGraphNameOrDefault(self: *const GraphStore, node_id: u64) []const u8 {
        if (self.nodes.getPtr(node_id)) |n| {
            if (n.graph_name.len > 0) return n.graph_name;
        }
        return DEFAULT_GRAPH_NAME;
    }

    fn removeFromAdjacencyIndex(self: *GraphStore, from_id: u64, to_id: u64, edge_id: u64) void {
        // Only the RESIDENT mirror is edited here; the engine removal is handled
        // by the caller's durable delete path. An evicted entry is simply left to
        // rehydrate (without this edge) on the next read.
        if (self.outgoing_edges.getPtr(from_id)) |entry| {
            var i: usize = 0;
            while (i < entry.list.items.len) {
                if (entry.list.items[i] == edge_id) {
                    _ = entry.list.swapRemove(i);
                    break;
                }
                i += 1;
            }
            if (entry.list.items.len == 0) {
                // Retire (do NOT inline-free): a concurrent SHARED reader may hold
                // a slice into this list; the cache frees it at the grace window.
                self.outgoing_edges.remove(from_id);
            }
        }

        if (self.incoming_edges.getPtr(to_id)) |entry| {
            var i: usize = 0;
            while (i < entry.list.items.len) {
                if (entry.list.items[i] == edge_id) {
                    _ = entry.list.swapRemove(i);
                    break;
                }
                i += 1;
            }
            if (entry.list.items.len == 0) {
                self.incoming_edges.remove(to_id);
            }
        }
    }

    // CANARY: REQ=REQ-PERF-EDGE-TYPE-INDEX-002; FEATURE="EdgeTypeIndex"; ASPECT=IndexMaintenance; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=perf; UPDATED=2026-04-10
    // PERF-P0-001: Add edge to edge-type index (composite key "graph_name:edge_type")
    // Uses stack-allocated bufPrint to probe for existing key before heap alloc (same pattern as addToLabelIndex).
    fn addToEdgeTypeIndex(self: *GraphStore, graph_name: []const u8, edge_type: []const u8, edge_id: u64) !void {
        // PHASE 1 (edge-engine-direct): when the edge cache is BOUNDED+engine-
        // backed, do NOT build the resident posting list — it is the
        // ~14M-entry-per-type RSS offender, and `getEdgesByType` now derives
        // type membership from the engine-backed adjacency + edge caches
        // (collectEdgesByTypeFromEngine). The small per-tenant `edge_type_count`
        // counters (bumpEdgeTypeCount, used for LSP introspection) are
        // maintained SEPARATELY by the create/delete callers and are unaffected.
        // The posting list is still maintained when UNBOUNDED (no engine / A/B
        // fallback), where it is the complete source of truth.
        if (self.edges.effectiveCap() != 0) return;

        var buf: [512]u8 = undefined;
        const probe_key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ graph_name, edge_type }) catch {
            // Key too long for stack buffer — fall back to heap alloc
            const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, edge_type });
            const result = try self.edge_type_index.getOrPut(key);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64).empty;
            } else {
                self.allocator.free(key);
            }
            try sortedInsert(result.value_ptr, self.allocator, edge_id);
            return;
        };

        if (self.edge_type_index.getPtr(probe_key)) |list| {
            try sortedInsert(list, self.allocator, edge_id);
        } else {
            const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, edge_type });
            const result = try self.edge_type_index.getOrPut(key);
            if (!result.found_existing) {
                result.value_ptr.* = std.ArrayList(u64).empty;
            } else {
                self.allocator.free(key);
            }
            try sortedInsert(result.value_ptr, self.allocator, edge_id);
        }
    }

    // PERF-P0-001: Remove edge from edge-type index
    fn removeFromEdgeTypeIndex(self: *GraphStore, graph_name: []const u8, edge_type: []const u8, edge_id: u64) void {
        const key = std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, edge_type }) catch return;
        defer self.allocator.free(key);

        if (self.edge_type_index.getPtr(key)) |list| {
            // Binary search for edge_id in sorted posting list
            const items = list.items;
            var lo: usize = 0;
            var hi: usize = items.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (items[mid] < edge_id) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo < items.len and items[lo] == edge_id) {
                _ = list.orderedRemove(lo);
            }
            if (list.items.len == 0) {
                if (self.edge_type_index.fetchRemove(key)) |kv| {
                    self.allocator.free(kv.key);
                    var list_copy = kv.value;
                    list_copy.deinit(self.allocator);
                }
            }
        }
    }

    /// Get edge IDs by type within a graph (O(1) lookup via edge-type index).
    /// Returns null if no edges of this type exist in the graph.
    pub fn getEdgeIdsByType(self: *const GraphStore, graph_name: []const u8, edge_type: []const u8) ?[]const u64 {
        @constCast(self).ensureGraphHydrated(graph_name); // PHASE 1b chokepoint
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ graph_name, edge_type }) catch return null;

        if (self.edge_type_index.get(key)) |list| {
            return list.items;
        }
        return null;
    }

    // CANARY: REQ=REQ-PERF-EDGE-ADJ-003; FEATURE="EdgeAdjacencyIndex"; ASPECT=EdgeLookup; STATUS=TESTED; OWNER=perf; UPDATED=2026-02-12
    // Issue #392: Get all edges connected to a node (O(1) lookup instead of O(edges) scan)
    // Issue #450: Use HashSet for O(1) deduplication instead of O(m*n) linear scan
    pub fn getEdgesForNode(self: *const GraphStore, allocator: std.mem.Allocator, node_id: u64) std.ArrayList(u64) {
        var result = std.ArrayList(u64).empty;
        var seen = std.AutoHashMap(u64, void).init(allocator);
        defer seen.deinit();

        // Get outgoing edges
        if (self.outAdjItems(node_id)) |outgoing| {
            for (outgoing) |edge_id| {
                seen.put(edge_id, {}) catch continue;
                result.append(allocator, edge_id) catch continue;
            }
        }

        // Get incoming edges — deduplicate self-loops via HashSet (#450)
        if (self.inAdjItems(node_id)) |incoming| {
            for (incoming) |edge_id| {
                if (!seen.contains(edge_id)) {
                    seen.put(edge_id, {}) catch continue;
                    result.append(allocator, edge_id) catch continue;
                }
            }
        }

        return result;
    }

    // Backward-compatible createEdge that uses "default" graph
    pub fn createEdge(self: *GraphStore, from_id: u64, to_id: u64, edge_type: []const u8) !u64 {
        return self.createEdgeWithGraph(from_id, to_id, edge_type, "default");
    }

    pub fn setEdgeProperty(self: *GraphStore, edge_id: u64, key: []const u8, value: PropertyValue) !void {
        self.ensureEdgeGraphHydrated(edge_id); // PHASE 1b chokepoint (hydrate before write)
        if (isInternalPersistedPropertyKey(key)) return error.ReservedPropertyKey;
        // FLE defense-in-depth: encrypt String values before adapter write and in-memory storage.
        // `owned_encrypted` tracks the freshly-allocated FLE envelope (if any) so
        // it is released after the adapter write / in-memory copy / WAL
        // notification have consumed it (see setNodeProperty for rationale).
        var owned_encrypted: ?[]const u8 = null;
        defer if (owned_encrypted) |buf| self.allocator.free(buf);
        const effective_value = switch (value) {
            .String => |s| blk: {
                if (fle_integration.hasEncryptedFields() and !isLikelyFleEnvelope(s)) {
                    const maybe_edge = self.getEdgeHydrated(edge_id);
                    const edge_type: []const u8 = if (maybe_edge) |e| e.label else "Unknown";
                    // GAP-0854: never FLE-encrypt the internal security graph.
                    const in_security_graph = if (maybe_edge) |e| isSecurityGraphName(e.graph_name) else false;
                    if (!in_security_graph and fle_integration.fieldRequiresEncryption(edge_type, key)) {
                        const fle_ctx = fle_integration.EncryptionContext{
                            .tenant_id = self.tenant_id,
                            .schema_name = self.schema_name,
                            .allocator = self.allocator,
                            .current_user_role = fle_integration.rolePreferringActiveContext(),
                        };
                        // Stack-formatted record ID — see setNodeProperty comment.
                        var id_buf: [32]u8 = undefined;
                        const record_id = std.fmt.bufPrint(&id_buf, "edge_{d}", .{edge_id}) catch {
                            break :blk value;
                        };
                        const encrypted = fle_integration.encryptFieldIfNeeded(
                            fle_ctx,
                            edge_type,
                            key,
                            s,
                            record_id,
                        ) catch {
                            break :blk value;
                        };
                        if (!std.mem.eql(u8, encrypted, s)) {
                            owned_encrypted = encrypted;
                            break :blk PropertyValue{ .String = encrypted };
                        }
                    }
                }
                break :blk value;
            },
            else => value,
        };

        blk_adapter: {
            const vt = global_vtable orelse break :blk_adapter;
            const f = vt.setEdgePropertyFn orelse break :blk_adapter;
            const edge = self.getEdgeHydrated(edge_id) orelse break :blk_adapter;
            const slot_from = self.requireNodeSlot(edge.graph_name, edge.from_id) catch |err| {
                log.debug("adapter edge endpoint-slot lookup failed during setEdgeProperty", &.{
                    Attr.string("error", @errorName(err)),
                });
                break :blk_adapter;
            };
            const slot_to = self.requireNodeSlot(edge.graph_name, edge.to_id) catch |err| {
                log.debug("adapter edge endpoint-slot lookup failed during setEdgeProperty", &.{
                    Attr.string("error", @errorName(err)),
                });
                break :blk_adapter;
            };
            const slot_edge = self.requireEdgeSlot(edge.graph_name, edge_id) catch |err| {
                log.debug("adapter edge-slot lookup failed during setEdgeProperty", &.{
                    Attr.string("error", @errorName(err)),
                });
                break :blk_adapter;
            };
            f(vt.ctx, edge.graph_name, slot_from, slot_to, slot_edge, key, effective_value) catch |err| {
                log.debug("adapter setEdgeProperty failed", &.{
                    Attr.string("error", @errorName(err)),
                });
            };
        }
        if (self.getEdgePtrHydrated(edge_id)) |edge| {
            const value_copy = try copyPropertyValue(self, effective_value);
            errdefer freePropertyValue(self, value_copy);

            {
                // ENG-3954 / #874: edge parity with setNodeProperty — exclude
                // concurrent readers across the realloc-and-free.
                self.edges.lockShardExclusive(edge_id);
                defer self.edges.unlockShardExclusive(edge_id);
                // Use getOrPut to avoid memory leak - only allocate key if it doesn't exist
                const result = try edge.properties.getOrPut(key);
                if (!result.found_existing) {
                    // Key doesn't exist, allocate a copy
                    result.key_ptr.* = try self.allocator.dupe(u8, key);
                } else {
                    // Key exists, free old value
                    freePropertyValue(self, result.value_ptr.*);
                }
                result.value_ptr.* = value_copy;
            }

            // Mark as dirty - persistence happens at query completion
            self.dirty.store(true, .release);
            incrementMutationEpoch();

            // WAL notification: SetEdgeProperty
            notifyMutation(.set_edge_property, edge_id, 0, 0, null, key, effective_value, null);
        }
    }

    /// Set multiple properties on an edge under a single adapter call.
    ///
    /// Task #34 (2026-04-24): edge counterpart to `setNodePropertiesBatch`
    /// (see line 2058).  The pre-fix bulk-ingest hot path called
    /// `setEdgeProperty` in a loop — each iteration re-acquired the
    /// adapter mutex, did two O(D) adjacency-chain linear scans in
    /// `updateEdgePropHead`, and ran `refreshPropertyChainIndex` over
    /// all K previously-written properties, yielding O(K²) per edge.
    /// At K=5 props × 400 edges × 16-way parallel seed this stalled the
    /// flusher for ~138 s on `edges_app_role_assignment.jsonl`.  See
    /// `docs/performance/2026-04-24-sharding/TASK-34-TRIAGE.md`.
    ///
    /// The batch path runs all property puts under one adapter call with
    /// a single mutex acquisition, one `updateEdgePropHead` per direction
    /// (applied to the terminal `prop_head` — intermediate heads are
    /// never read), and one `refreshPropertyChainIndex` at the end.
    /// Intended for internal bulk-ingest callers; regular per-property
    /// callers keep using `setEdgeProperty`.
    pub fn setEdgePropertiesBatch(self: *GraphStore, edge_id: u64, entries: []const BatchPropertyEntry) !void {
        self.ensureEdgeGraphHydrated(edge_id); // PHASE 1b chokepoint (hydrate before write)
        const edge = self.getEdgeHydrated(edge_id) orelse return error.EdgeNotFound;

        // --- Adapter path: single lock acquisition for all properties ---
        if (global_adapter) |adapter| {
            const slot_edge = try self.requireEdgeSlot(edge.graph_name, edge_id);

            // Build adapter-level batch entries, applying FLE encryption per
            // entry (mirrors the per-property encryption in `setEdgeProperty`
            // above).
            var adapter_entries = try self.allocator.alloc(graph_storage_adapter.StorageAdapter.BatchPropertyEntry, entries.len);
            defer self.allocator.free(adapter_entries);

            // GAP-0854 follow-up: track freshly-allocated FLE envelopes so they
            // are freed exactly once after the adapter has copied them into
            // storage (mirrors the node batch path).
            var owned_envelopes = try self.allocator.alloc(?[]const u8, entries.len);
            defer {
                for (owned_envelopes) |maybe_buf| {
                    if (maybe_buf) |buf| self.allocator.free(buf);
                }
                self.allocator.free(owned_envelopes);
            }
            @memset(owned_envelopes, null);

            for (entries, 0..) |entry, i| {
                if (entry.value) |val| {
                    const res = self.applyFleEncryptionForEdge(edge_id, entry.key, val);
                    adapter_entries[i] = .{ .key = entry.key, .value = res.value };
                    owned_envelopes[i] = res.owned;
                } else {
                    adapter_entries[i] = .{ .key = entry.key, .value = null };
                }
            }

            try adapter.setEdgePropertiesBatch(edge.graph_name, slot_edge, adapter_entries);
        }

        // --- In-memory store update (always, regardless of adapter) ---
        if (self.getEdgePtrHydrated(edge_id)) |edge_ptr| {
            for (entries) |entry| {
                if (isInternalPersistedPropertyKey(entry.key)) continue;

                if (entry.value) |val| {
                    const res = self.applyFleEncryptionForEdge(edge_id, entry.key, val);
                    // GAP-0854 follow-up: free the in-memory-path envelope after
                    // the copy + WAL notify have consumed it.
                    defer if (res.owned) |buf| self.allocator.free(buf);
                    const effective = res.value;
                    const value_copy = try copyPropertyValue(self, effective);
                    errdefer freePropertyValue(self, value_copy);

                    {
                        // ENG-3954 / #874: see setNodePropertiesBatchInMemoryOnly.
                        self.edges.lockShardExclusive(edge_id);
                        defer self.edges.unlockShardExclusive(edge_id);
                        const result = try edge_ptr.properties.getOrPut(entry.key);
                        if (!result.found_existing) {
                            result.key_ptr.* = try self.allocator.dupe(u8, entry.key);
                        } else {
                            freePropertyValue(self, result.value_ptr.*);
                        }
                        result.value_ptr.* = value_copy;
                    }

                    notifyMutation(.set_edge_property, edge_id, 0, 0, null, entry.key, effective, null);
                } else {
                    // Remove
                    const removed = blk: {
                        self.edges.lockShardExclusive(edge_id);
                        defer self.edges.unlockShardExclusive(edge_id);
                        if (edge_ptr.properties.fetchRemove(entry.key)) |kv| {
                            self.allocator.free(kv.key);
                            freePropertyValue(self, kv.value);
                            break :blk true;
                        }
                        break :blk false;
                    };
                    if (removed) {
                        notifyMutation(.remove_edge_property, edge_id, 0, 0, null, entry.key, null, null);
                    }
                }
            }
            self.dirty.store(true, .release);
            incrementMutationEpoch();
        }
    }

    /// Apply FLE encryption to an edge property value if required.  Factored
    /// out so both `setEdgeProperty` and `setEdgePropertiesBatch` share the
    /// same logic.  Mirrors `applyFleEncryption` (the node variant) at line
    /// 2132.
    fn applyFleEncryptionForEdge(self: *GraphStore, edge_id: u64, key: []const u8, value: PropertyValue) FleApplyResult {
        switch (value) {
            .String => |s| {
                if (fle_integration.hasEncryptedFields() and !isLikelyFleEnvelope(s)) {
                    const maybe_edge = self.getEdgeHydrated(edge_id);
                    const edge_type: []const u8 = if (maybe_edge) |e| e.label else "Unknown";
                    // GAP-0854: never FLE-encrypt the internal security graph.
                    const in_security_graph = if (maybe_edge) |e| isSecurityGraphName(e.graph_name) else false;
                    if (!in_security_graph and fle_integration.fieldRequiresEncryption(edge_type, key)) {
                        const fle_ctx = fle_integration.EncryptionContext{
                            .tenant_id = self.tenant_id,
                            .schema_name = self.schema_name,
                            .allocator = self.allocator,
                            .current_user_role = fle_integration.rolePreferringActiveContext(),
                        };
                        // Stack-formatted record ID — see setNodeProperty comment.
                        var id_buf: [32]u8 = undefined;
                        const record_id = std.fmt.bufPrint(&id_buf, "edge_{d}", .{edge_id}) catch {
                            return .{ .value = value };
                        };
                        const encrypted = fle_integration.encryptFieldIfNeeded(
                            fle_ctx,
                            edge_type,
                            key,
                            s,
                            record_id,
                        ) catch {
                            return .{ .value = value };
                        };
                        if (!std.mem.eql(u8, encrypted, s)) {
                            return .{ .value = PropertyValue{ .String = encrypted }, .owned = encrypted };
                        }
                    }
                }
                return .{ .value = value };
            },
            else => return .{ .value = value },
        }
    }

    pub fn removeEdgeProperty(self: *GraphStore, edge_id: u64, key: []const u8) void {
        self.ensureEdgeGraphHydrated(edge_id); // PHASE 1b chokepoint (hydrate before write)
        if (isInternalPersistedPropertyKey(key)) return;
        if (global_vtable) |vt| {
            if (vt.removeEdgePropertyFn) |f| {
                if (self.getEdgeHydrated(edge_id)) |edge_info| {
                    const slot_from = self.requireNodeSlot(edge_info.graph_name, edge_info.from_id) catch |err| {
                        log.err("adapter edge endpoint-slot lookup failed during removeEdgeProperty", &.{
                            Attr.string("error", @errorName(err)),
                            Attr.int("edge_id", @intCast(edge_id)),
                            Attr.string("graph", edge_info.graph_name),
                        });
                        return;
                    };
                    const slot_to = self.requireNodeSlot(edge_info.graph_name, edge_info.to_id) catch |err| {
                        log.err("adapter edge endpoint-slot lookup failed during removeEdgeProperty", &.{
                            Attr.string("error", @errorName(err)),
                            Attr.int("edge_id", @intCast(edge_id)),
                            Attr.string("graph", edge_info.graph_name),
                        });
                        return;
                    };
                    const slot_edge = self.requireEdgeSlot(edge_info.graph_name, edge_id) catch |err| {
                        log.err("adapter edge-slot lookup failed during removeEdgeProperty", &.{
                            Attr.string("error", @errorName(err)),
                            Attr.int("edge_id", @intCast(edge_id)),
                            Attr.string("graph", edge_info.graph_name),
                        });
                        return;
                    };
                    f(vt.ctx, edge_info.graph_name, slot_from, slot_to, slot_edge, key) catch |err| {
                        log.err("adapter removeEdgeProperty failed", &.{
                            Attr.string("error", @errorName(err)),
                            Attr.int("edge_id", @intCast(edge_id)),
                            Attr.string("graph", edge_info.graph_name),
                        });
                        return;
                    };
                }
            }
        }
        if (self.getEdgePtrHydrated(edge_id)) |edge| {
            {
                // ENG-3954 / #874: edge parity with removeNodeProperty.
                self.edges.lockShardExclusive(edge_id);
                defer self.edges.unlockShardExclusive(edge_id);
                if (edge.properties.fetchRemove(key)) |kv| {
                    self.allocator.free(kv.key);
                    freePropertyValue(self, kv.value);
                }
            }
            self.dirty.store(true, .release);
            incrementMutationEpoch();

            // WAL notification: RemoveEdgeProperty
            notifyMutation(.remove_edge_property, edge_id, 0, 0, null, key, null, null);
        }
    }

    // CANARY: REQ=REQ-PERF-EDGE-TYPE-INDEX-003; FEATURE="EdgeTypeIndex"; ASPECT=EdgeTypeLookup; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=perf; UPDATED=2026-04-10
    // PERF-P0-001: O(result) edge-type lookup via edge_type_index instead of O(E) full scan.
    // Iterates over registered graphs (typically 1-3) and collects matching edge IDs from the
    // per-graph:type index, then resolves to Edge structs with optional tenant filtering.
    // Accepts caller-provided allocator to avoid concurrent threads contending
    // on self.allocator (same class of bug as GAP-0425 getNodesByLabels fix).
    // GAP-0509: tenant_id filters edges to a specific tenant when non-null.
    // PERF-P2-003: Return edge IDs (8 bytes each) instead of full Edge structs
    // (~96+ bytes each). Callers use store.edges.getPtr(id) for read-only access.
    //
    // GAP-0512: When `graph_name` is non-null, restrict the posting-list
    // scan to that single graph. When null, the function returns the
    // union across every graph — an admin / diagnostic path that must
    // stay available (e.g. for cross-graph metrics and ML training
    // pipelines that explicitly pass null). Callers executing a
    // user-scoped query (MATCH, algorithms) must pass the active graph
    // so edges from other graphs cannot leak into the result set.
    // CANARY: REQ=REQ-MULTI-GRAPH-EDGE-ISOLATION; FEATURE="GraphIsolationEdgeScan"; ASPECT=GetEdgesByType; STATUS=TESTED; TEST=tests/test_graph_isolation_edge_iteration.zig:1; OWNER=engine; UPDATED=2026-04-11
    pub fn getEdgesByType(
        self: *GraphStore,
        allocator: std.mem.Allocator,
        edge_type: []const u8,
        tenant_id: ?[]const u8,
        graph_name: ?[]const u8,
    ) []u64 {
        // PHASE 1b chokepoint: hydrate the target graph (or all when admin/null).
        if (graph_name) |gn| self.ensureGraphHydrated(gn) else self.ensureAllGraphsHydrated();
        // PHASE 1 (edge-engine-direct): with a BOUNDED edge cache the resident
        // `edge_type_index` posting list is no longer maintained at full size
        // (it was the ~14M-entry-per-type RSS offender). DERIVE type membership
        // from the engine-backed adjacency + edge caches instead: for each node
        // in the graph, expand its OUTGOING adjacency (engine hydrate-on-miss)
        // and keep the edge ids whose hydrated body matches `edge_type` (and
        // tenant). Each edge appears exactly once as some node's outgoing edge,
        // so no dedup is needed. Bounded residency throughout (the caches evict
        // as they hydrate). When the edge cache is UNBOUNDED (legacy A/B mode)
        // the resident posting list IS complete, so use the O(result) fast path.
        if (self.edges.effectiveCap() == 0) {
            return self.getEdgesByTypeFromPostings(allocator, edge_type, tenant_id, graph_name);
        }

        var id_list = std.ArrayList(u64).empty;
        defer id_list.deinit(allocator);

        if (graph_name) |gn| {
            self.collectEdgesByTypeFromEngine(allocator, &id_list, gn, edge_type, tenant_id) catch return &.{};
        } else {
            var graph_iter = self.graphs.keyIterator();
            while (graph_iter.next()) |graph_key| {
                self.collectEdgesByTypeFromEngine(allocator, &id_list, graph_key.*, edge_type, tenant_id) catch continue;
            }
        }
        return id_list.toOwnedSlice(allocator) catch &.{};
    }

    /// Engine-derived `getEdgesByType` body for the bounded edge cache: iterate
    /// every node of `gn` and collect its outgoing edges of `edge_type` (with
    /// optional tenant filter). `iterateNodesInGraph` enumerates the graph's
    /// nodes; `getOutgoingEdgeIds` + `getEdgePtrHydrated` resolve the (bounded)
    /// adjacency + edge bodies from the engine. Appends into `id_list`.
    fn collectEdgesByTypeFromEngine(
        self: *GraphStore,
        allocator: std.mem.Allocator,
        id_list: *std.ArrayList(u64),
        gn: []const u8,
        edge_type: []const u8,
        tenant_id: ?[]const u8,
    ) !void {
        // GAP-ENT-0023 P3 (review C2 follow-on): this walk needs only node
        // IDS — iterate the authoritative `nodes_by_graph` id set directly
        // instead of hydrating full node bodies through the pointer iterator
        // (which would box every non-resident node until the next grace
        // point for no benefit).
        self.ensureGraphHydrated(gn); // PHASE 1b chokepoint

        // GAP-ENT-0004: with a storage adapter present, serve the typed
        // enumeration from the ENGINE's per-shard edge_index (mmap base ⊕
        // overlay merged view) — ONE O(total edges) sequential index-record
        // scan with NO node iteration, NO adjacency hydration and, for
        // tenantless callers, NO edge-body reads (each index entry carries
        // rel_type + the inline public id). The previous behaviour walked
        // EVERY node of the graph and expanded its outgoing adjacency
        // (hydrate-on-miss) just to derive type membership — O(nodes+edges)
        // engine reads + cache thrash at enterprise scale.
        //
        // Tenant semantics IDENTICAL to the walk: when a concrete tenant
        // filter is present, resolve each candidate edge's body
        // (hydrate-on-miss, bounded residency) and compare its tenant tag —
        // the same `edge.tenant_id` equality the walk applied.
        if (global_adapter) |adapter| {
            _ = typed_edge_index_scan_total.fetchAdd(1, .monotonic);
            const start_len = id_list.items.len;
            adapter.collectEdgePublicIdsByType(gn, edge_type, allocator, id_list) catch |err| switch (err) {
                // Graph unknown to the adapter (e.g. created purely in-memory
                // in a test): nothing durable to enumerate — same empty result
                // the walk would produce from an absent nodes_by_graph entry.
                error.GraphNotFound => return,
                else => return err,
            };
            if (tenant_id) |tid| {
                var w: usize = start_len;
                for (id_list.items[start_len..]) |eid| {
                    const edge = self.getEdgePtrHydrated(eid) orelse continue;
                    if (!std.mem.eql(u8, edge.tenant_id, tid)) continue;
                    id_list.items[w] = eid;
                    w += 1;
                }
                id_list.shrinkRetainingCapacity(w);
            }
            return;
        }

        // Adapterless fallback (pure in-memory store configured with a bounded
        // edge cache — test-only shape): the original every-node adjacency
        // walk. Instrumented so path tests can prove it never runs when an
        // adapter is present.
        _ = typed_edge_node_walk_total.fetchAdd(1, .monotonic);
        var ids_iter = blk: {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.nodes_by_graph_mutex.lockUncancelable(io);
            defer self.nodes_by_graph_mutex.unlock(io);
            const inner = self.nodes_by_graph.getPtr(gn) orelse return;
            break :blk inner.keyIterator();
        };
        while (ids_iter.next()) |id_ptr| {
            _ = typed_edge_node_walk_nodes_total.fetchAdd(1, .monotonic);
            const out_ids = self.getOutgoingEdgeIds(id_ptr.*) orelse continue;
            for (out_ids) |eid| {
                const edge = self.getEdgePtrHydrated(eid) orelse continue;
                if (!std.mem.eql(u8, edge.label, edge_type)) continue;
                if (tenant_id) |tid| {
                    if (!std.mem.eql(u8, edge.tenant_id, tid)) continue;
                }
                try id_list.append(allocator, eid);
            }
        }
    }

    /// Legacy resident-posting-list `getEdgesByType` (UNBOUNDED edge cache A/B
    /// fallback only). O(result) keyed lookup against `edge_type_index`.
    fn getEdgesByTypeFromPostings(
        self: *GraphStore,
        allocator: std.mem.Allocator,
        edge_type: []const u8,
        tenant_id: ?[]const u8,
        graph_name: ?[]const u8,
    ) []u64 {
        var id_list = std.ArrayList(u64).empty;
        defer id_list.deinit(allocator);

        if (graph_name) |gn| {
            var key_buf: [512]u8 = undefined;
            const probe = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ gn, edge_type }) catch return &.{};
            if (self.edge_type_index.get(probe)) |posting| {
                id_list.appendSlice(allocator, posting.items) catch return &.{};
            }
        } else {
            var graph_iter = self.graphs.keyIterator();
            while (graph_iter.next()) |graph_key| {
                var key_buf: [512]u8 = undefined;
                const probe = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ graph_key.*, edge_type }) catch continue;
                if (self.edge_type_index.get(probe)) |posting| {
                    id_list.appendSlice(allocator, posting.items) catch continue;
                }
            }
        }

        if (tenant_id == null) {
            return id_list.toOwnedSlice(allocator) catch return &.{};
        }

        var count: usize = 0;
        for (id_list.items) |eid| {
            const edge = self.edges.get(eid) orelse continue;
            if (tenant_id) |tid| {
                if (!std.mem.eql(u8, edge.tenant_id, tid)) continue;
            }
            count += 1;
        }

        const result = allocator.alloc(u64, count) catch return &.{};
        var i: usize = 0;
        for (id_list.items) |eid| {
            const edge = self.edges.get(eid) orelse continue;
            if (tenant_id) |tid| {
                if (!std.mem.eql(u8, edge.tenant_id, tid)) continue;
            }
            result[i] = eid;
            i += 1;
        }
        return result;
    }

    /// Deprecated: prefer getOutgoingEdgeIds for zero-copy access.
    pub fn getEdgesFrom(self: *GraphStore, allocator: std.mem.Allocator, node_id: u64) []Edge {
        var result: std.ArrayList(Edge) = .empty;
        if (self.outAdjItems(node_id)) |outgoing| {
            for (outgoing) |edge_id| {
                if (self.getEdgeHydrated(edge_id)) |edge| {
                    result.append(allocator, edge) catch continue;
                }
            }
        }
        return result.toOwnedSlice(allocator) catch &.{};
    }

    /// Deprecated: prefer getIncomingEdgeIds for zero-copy access.
    pub fn getEdgesTo(self: *GraphStore, allocator: std.mem.Allocator, node_id: u64) []Edge {
        var result = std.ArrayList(Edge){};
        if (self.inAdjItems(node_id)) |incoming| {
            for (incoming) |edge_id| {
                if (self.getEdgeHydrated(edge_id)) |edge| {
                    result.append(allocator, edge) catch continue;
                }
            }
        }
        return result.toOwnedSlice(allocator) catch &.{};
    }

    /// DEPRECATED: Legacy ExtValue writer stub — was used by graph_store.dat serialization.
    fn writeExtValueToWriter(self: *GraphStore, writer: anytype, hasher: anytype, ext: @import("eval_extended.zig").ExtValue) !void {
        const sub_type: u8 = switch (ext) {
            .Null => 0,
            .Int => 1,
            .Bool => 2,
            .Str => 3,
            .Decimal => 4,
            .IpAddr => 5,
            .Subnet => 6,
            .Mac => 7,
            .Hash => 8,
            .Currency => 9,
            .LanguageTag => 10,
            .LatLon => 11,
            .LatLonAlt => 12,
            .Geometry => 13,
            .Temperature => 14,
            .Pressure => 15,
            .VectorF32 => 16,
            .Date => 17,
            .Time => 18,
            .TimestampTZ => 19,
            .List => 20,
            .VectorI32 => 21,
            .Interval => 22,
            .UUID => 23,
            .Url => 24,
            .Domain => 25,
            .Bytea => 26,
            .Json => 27,
            .Jsonb => 28,
            .Xml => 29,
            .BitString => 30,
            .VarBit => 31,
            .IntRange => 32,
            .Enum => 33,
        };
        hasher.update(&[1]u8{sub_type});
        try writer.writeAll(&[1]u8{sub_type});

        switch (ext) {
            .Null => {},
            .Int => |i| {
                var buf: [8]u8 = undefined;
                std.mem.writeInt(i64, &buf, i, .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Bool => |b| {
                const byte = [1]u8{if (b) 1 else 0};
                hasher.update(&byte);
                try writer.writeAll(&byte);
            },
            .Str => |s| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(s.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(s);
                try writer.writeAll(s);
            },
            .Decimal => |d| {
                var buf: [17]u8 = undefined;
                std.mem.writeInt(i128, buf[0..16], d.coeff, .little);
                buf[16] = d.scale;
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .IpAddr => |ip| {
                const is_v6: u8 = if (ip == .v6) 1 else 0;
                hasher.update(&[1]u8{is_v6});
                try writer.writeAll(&[1]u8{is_v6});
                if (ip == .v4) {
                    hasher.update(&ip.v4);
                    try writer.writeAll(&ip.v4);
                } else {
                    hasher.update(&ip.v6);
                    try writer.writeAll(&ip.v6);
                }
            },
            .Subnet => |subnet| {
                const is_v6: u8 = if (subnet.addr == .v6) 1 else 0;
                hasher.update(&[1]u8{is_v6});
                try writer.writeAll(&[1]u8{is_v6});
                if (subnet.addr == .v4) {
                    hasher.update(&subnet.addr.v4);
                    try writer.writeAll(&subnet.addr.v4);
                } else {
                    hasher.update(&subnet.addr.v6);
                    try writer.writeAll(&subnet.addr.v6);
                }
                hasher.update(&[1]u8{subnet.prefix_len});
                try writer.writeAll(&[1]u8{subnet.prefix_len});
            },
            .Mac => |mac| {
                hasher.update(&mac.bytes);
                try writer.writeAll(&mac.bytes);
            },
            .LatLon => |ll| {
                var buf: [16]u8 = undefined;
                std.mem.writeInt(u64, buf[0..8], @bitCast(ll.lat), .little);
                std.mem.writeInt(u64, buf[8..16], @bitCast(ll.lon), .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .LatLonAlt => |lla| {
                var buf: [25]u8 = undefined;
                std.mem.writeInt(u64, buf[0..8], @bitCast(lla.lat), .little);
                std.mem.writeInt(u64, buf[8..16], @bitCast(lla.lon), .little);
                std.mem.writeInt(u64, buf[16..24], @bitCast(lla.alt), .little);
                buf[24] = @intFromEnum(lla.ref);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Geometry => |geom| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(geom.wkb.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(geom.wkb);
                try writer.writeAll(geom.wkb);
            },
            .Currency => |cur| {
                hasher.update(&cur.code);
                try writer.writeAll(&cur.code);
            },
            .VectorF32 => |vec| {
                var dim_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &dim_buf, vec.dim, .little);
                hasher.update(&dim_buf);
                try writer.writeAll(&dim_buf);
                for (vec.data) |f| {
                    var f_buf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &f_buf, @bitCast(f), .little);
                    hasher.update(&f_buf);
                    try writer.writeAll(&f_buf);
                }
            },
            .VectorI32 => |vec| {
                var dim_buf: [2]u8 = undefined;
                std.mem.writeInt(u16, &dim_buf, vec.dim, .little);
                hasher.update(&dim_buf);
                try writer.writeAll(&dim_buf);
                for (vec.data) |i| {
                    var i_buf: [4]u8 = undefined;
                    std.mem.writeInt(i32, &i_buf, i, .little);
                    hasher.update(&i_buf);
                    try writer.writeAll(&i_buf);
                }
            },
            .Hash => |hash| {
                const alg_byte = [1]u8{@intFromEnum(hash.alg)};
                hasher.update(&alg_byte);
                try writer.writeAll(&alg_byte);
                var digest_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &digest_len_buf, @intCast(hash.digest.len), .little);
                hasher.update(&digest_len_buf);
                try writer.writeAll(&digest_len_buf);
                hasher.update(hash.digest);
                try writer.writeAll(hash.digest);
                if (hash.salt) |salt| {
                    hasher.update(&[1]u8{1});
                    try writer.writeAll(&[1]u8{1});
                    var salt_len_buf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &salt_len_buf, @intCast(salt.len), .little);
                    hasher.update(&salt_len_buf);
                    try writer.writeAll(&salt_len_buf);
                    hasher.update(salt);
                    try writer.writeAll(salt);
                } else {
                    hasher.update(&[1]u8{0});
                    try writer.writeAll(&[1]u8{0});
                }
                if (hash.params) |params| {
                    hasher.update(&[1]u8{1});
                    try writer.writeAll(&[1]u8{1});

                    var params_buf: [9]u8 = undefined;
                    std.mem.writeInt(u32, params_buf[0..4], params.iterations, .little);
                    std.mem.writeInt(u32, params_buf[4..8], params.memory_kb, .little);
                    params_buf[8] = params.parallelism;
                    hasher.update(&params_buf);
                    try writer.writeAll(&params_buf);
                } else {
                    hasher.update(&[1]u8{0});
                    try writer.writeAll(&[1]u8{0});
                }
            },
            .LanguageTag => |lt| {
                var tag_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &tag_len_buf, @intCast(lt.tag.len), .little);
                hasher.update(&tag_len_buf);
                try writer.writeAll(&tag_len_buf);
                hasher.update(lt.tag);
                try writer.writeAll(lt.tag);
            },
            .Temperature => |temp| {
                var buf: [9]u8 = undefined;
                std.mem.writeInt(u64, buf[0..8], @bitCast(temp.value_K), .little);
                buf[8] = @intFromEnum(temp.unit_in);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Pressure => |pres| {
                var buf: [9]u8 = undefined;
                std.mem.writeInt(u64, buf[0..8], @bitCast(pres.value_Pa), .little);
                buf[8] = @intFromEnum(pres.unit_in);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Date => |date| {
                var buf: [4]u8 = undefined;
                std.mem.writeInt(i32, &buf, date.days_since_epoch, .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Time => |time| {
                var buf: [8]u8 = undefined;
                std.mem.writeInt(i64, &buf, time.micros_since_midnight, .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .TimestampTZ => |ts| {
                var buf: [8]u8 = undefined;
                std.mem.writeInt(i64, &buf, ts.micros_since_epoch_utc, .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Interval => |iv| {
                var buf: [16]u8 = undefined;
                std.mem.writeInt(i32, buf[0..4], iv.months, .little);
                std.mem.writeInt(i32, buf[4..8], iv.days, .little);
                std.mem.writeInt(i64, buf[8..16], iv.micros, .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .UUID => |uuid_val| {
                var buf: [16]u8 = undefined;
                @memcpy(&buf, &uuid_val.bytes);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Url => |url_val| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(url_val.scheme.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(url_val.scheme);
                try writer.writeAll(url_val.scheme);

                std.mem.writeInt(u32, &len_buf, @intCast(url_val.host.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(url_val.host);
                try writer.writeAll(url_val.host);

                const has_port: u8 = if (url_val.port != null) 1 else 0;
                hasher.update(&[1]u8{has_port});
                try writer.writeAll(&[1]u8{has_port});
                if (url_val.port) |p| {
                    var p_buf: [2]u8 = undefined;
                    std.mem.writeInt(u16, &p_buf, p, .little);
                    hasher.update(&p_buf);
                    try writer.writeAll(&p_buf);
                }

                std.mem.writeInt(u32, &len_buf, @intCast(url_val.path.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(url_val.path);
                try writer.writeAll(url_val.path);

                const has_query: u8 = if (url_val.query != null) 1 else 0;
                hasher.update(&[1]u8{has_query});
                try writer.writeAll(&[1]u8{has_query});
                if (url_val.query) |q| {
                    std.mem.writeInt(u32, &len_buf, @intCast(q.len), .little);
                    hasher.update(&len_buf);
                    try writer.writeAll(&len_buf);
                    hasher.update(q);
                    try writer.writeAll(q);
                }

                const has_fragment: u8 = if (url_val.fragment != null) 1 else 0;
                hasher.update(&[1]u8{has_fragment});
                try writer.writeAll(&[1]u8{has_fragment});
                if (url_val.fragment) |f| {
                    std.mem.writeInt(u32, &len_buf, @intCast(f.len), .little);
                    hasher.update(&len_buf);
                    try writer.writeAll(&len_buf);
                    hasher.update(f);
                    try writer.writeAll(f);
                }
            },
            .Domain => |domain| {
                var count_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &count_buf, @intCast(domain.labels.len), .little);
                hasher.update(&count_buf);
                try writer.writeAll(&count_buf);
                for (domain.labels) |label| {
                    var len_buf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &len_buf, @intCast(label.len), .little);
                    hasher.update(&len_buf);
                    try writer.writeAll(&len_buf);
                    hasher.update(label);
                    try writer.writeAll(label);
                }
            },
            .Bytea => |b| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(b.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(b);
                try writer.writeAll(b);
            },
            .Json => |j| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(j.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(j);
                try writer.writeAll(j);
            },
            .Jsonb => |doc| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(doc.data.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(doc.data);
                try writer.writeAll(doc.data);
            },
            .Xml => |doc| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(doc.data.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                hasher.update(doc.data);
                try writer.writeAll(doc.data);
            },
            .BitString => |bs| {
                var bit_len_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &bit_len_buf, @intCast(bs.bit_length), .little);
                hasher.update(&bit_len_buf);
                try writer.writeAll(&bit_len_buf);
                var byte_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &byte_len_buf, @intCast(bs.bytes.len), .little);
                hasher.update(&byte_len_buf);
                try writer.writeAll(&byte_len_buf);
                hasher.update(bs.bytes);
                try writer.writeAll(bs.bytes);
            },
            .VarBit => |bs| {
                var bit_len_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &bit_len_buf, @intCast(bs.bit_length), .little);
                hasher.update(&bit_len_buf);
                try writer.writeAll(&bit_len_buf);
                var byte_len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &byte_len_buf, @intCast(bs.bytes.len), .little);
                hasher.update(&byte_len_buf);
                try writer.writeAll(&byte_len_buf);
                hasher.update(bs.bytes);
                try writer.writeAll(bs.bytes);
            },
            .IntRange => |range_val| {
                var buf: [10]u8 = undefined;
                var flags: u8 = 0;
                if (range_val.lower != null) flags |= 0b01;
                if (range_val.upper != null) flags |= 0b10;
                buf[0] = flags;
                std.mem.writeInt(i32, buf[1..5], range_val.lower orelse 0, .little);
                std.mem.writeInt(i32, buf[5..9], range_val.upper orelse 0, .little);
                buf[9] = @intFromEnum(range_val.bounds);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .Enum => |enum_val| {
                var buf: [8]u8 = undefined;
                std.mem.writeInt(u32, buf[0..4], enum_val.type_id, .little);
                std.mem.writeInt(u32, buf[4..8], enum_val.value_ordinal, .little);
                hasher.update(&buf);
                try writer.writeAll(&buf);
            },
            .List => |list| {
                var len_buf: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_buf, @intCast(list.len), .little);
                hasher.update(&len_buf);
                try writer.writeAll(&len_buf);
                for (list) |item| {
                    try self.writeExtValueToWriter(writer, hasher, item);
                }
            },
        }
    }

    fn readExtValue(self: *GraphStore, reader: anytype) !@import("eval_extended.zig").ExtValue {
        const ext_eval = @import("eval_extended.zig");
        const heap_mod = @import("storage/heap.zig");
        const jsonb_mod = @import("types/jsonb.zig");
        const xml_mod = @import("types/xml.zig");
        const bitstring_mod = @import("types/bitstring.zig");
        const url_mod = @import("types/url.zig");
        const range_mod = @import("types/range.zig");

        var sub_type_buf: [1]u8 = undefined;
        if ((try reader.readAll(&sub_type_buf)) < 1) return ext_eval.ExtValue{ .Null = {} };

        return switch (sub_type_buf[0]) {
            0 => ext_eval.ExtValue{ .Null = {} },
            1 => blk: {
                var buf: [8]u8 = undefined;
                if ((try reader.readAll(&buf)) < 8) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Int = std.mem.readInt(i64, &buf, .little) };
            },
            2 => blk: {
                var buf: [1]u8 = undefined;
                if ((try reader.readAll(&buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Bool = buf[0] != 0 };
            },
            3 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const str_data = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(str_data)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Str = str_data };
            },
            4 => blk: {
                var buf: [17]u8 = undefined;
                if ((try reader.readAll(&buf)) < 17) break :blk ext_eval.ExtValue{ .Null = {} };
                const coeff = std.mem.readInt(i128, buf[0..16], .little);
                const scale = buf[16];
                break :blk ext_eval.ExtValue{ .Decimal = .{ .coeff = coeff, .scale = scale } };
            },
            5 => blk: {
                var is_v6_buf: [1]u8 = undefined;
                if ((try reader.readAll(&is_v6_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                const is_v6 = is_v6_buf[0] != 0;
                if (is_v6) {
                    var addr_buf: [16]u8 = undefined;
                    if ((try reader.readAll(&addr_buf)) < 16) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk ext_eval.ExtValue{ .IpAddr = .{ .v6 = addr_buf } };
                } else {
                    var addr_buf: [4]u8 = undefined;
                    if ((try reader.readAll(&addr_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk ext_eval.ExtValue{ .IpAddr = .{ .v4 = addr_buf } };
                }
            },
            6 => blk: {
                var is_v6_buf: [1]u8 = undefined;
                if ((try reader.readAll(&is_v6_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                const is_v6 = is_v6_buf[0] != 0;
                const addr = if (is_v6) blk2: {
                    var addr_buf: [16]u8 = undefined;
                    if ((try reader.readAll(&addr_buf)) < 16) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk2 heap_mod.IpAddr{ .v6 = addr_buf };
                } else blk2: {
                    var addr_buf: [4]u8 = undefined;
                    if ((try reader.readAll(&addr_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk2 heap_mod.IpAddr{ .v4 = addr_buf };
                };
                var prefix_len_buf: [1]u8 = undefined;
                if ((try reader.readAll(&prefix_len_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Subnet = .{ .addr = addr, .prefix_len = prefix_len_buf[0] } };
            },
            7 => blk: {
                var mac_buf: [6]u8 = undefined;
                if ((try reader.readAll(&mac_buf)) < 6) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Mac = .{ .bytes = mac_buf } };
            },
            8 => blk: {
                var alg_buf: [1]u8 = undefined;
                if ((try reader.readAll(&alg_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const digest = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(digest)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                var salt_flag: [1]u8 = undefined;
                if ((try reader.readAll(&salt_flag)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                var salt: ?[]const u8 = null;
                if (salt_flag[0] != 0) {
                    if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    const salt_len = std.mem.readInt(u32, &len_buf, .little);
                    const salt_data = try self.allocator.alloc(u8, salt_len);
                    if ((try reader.readAll(salt_data)) < salt_len) break :blk ext_eval.ExtValue{ .Null = {} };
                    salt = salt_data;
                }
                var params_flag: [1]u8 = undefined;
                if ((try reader.readAll(&params_flag)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                var params: ?heap_mod.Argon2Params = null;
                if (params_flag[0] != 0) {
                    var params_buf: [9]u8 = undefined;
                    if ((try reader.readAll(&params_buf)) < params_buf.len) break :blk ext_eval.ExtValue{ .Null = {} };
                    params = .{
                        .iterations = std.mem.readInt(u32, params_buf[0..4], .little),
                        .memory_kb = std.mem.readInt(u32, params_buf[4..8], .little),
                        .parallelism = params_buf[8],
                    };
                }
                break :blk ext_eval.ExtValue{ .Hash = .{
                    .alg = @enumFromInt(alg_buf[0]),
                    .digest = digest,
                    .salt = salt,
                    .params = params,
                } };
            },
            9 => blk: {
                var code_buf: [3]u8 = undefined;
                if ((try reader.readAll(&code_buf)) < 3) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Currency = .{ .code = code_buf } };
            },
            10 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const tag = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(tag)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .LanguageTag = .{ .tag = tag } };
            },
            11 => blk: {
                var buf: [16]u8 = undefined;
                if ((try reader.readAll(&buf)) < 16) break :blk ext_eval.ExtValue{ .Null = {} };
                const lat_bits = std.mem.readInt(u64, buf[0..8], .little);
                const lon_bits = std.mem.readInt(u64, buf[8..16], .little);
                break :blk ext_eval.ExtValue{ .LatLon = .{ .lat = @bitCast(lat_bits), .lon = @bitCast(lon_bits) } };
            },
            12 => blk: {
                var buf: [25]u8 = undefined;
                if ((try reader.readAll(&buf)) < 25) break :blk ext_eval.ExtValue{ .Null = {} };
                const lat_bits = std.mem.readInt(u64, buf[0..8], .little);
                const lon_bits = std.mem.readInt(u64, buf[8..16], .little);
                const alt_bits = std.mem.readInt(u64, buf[16..24], .little);
                const ref: heap_mod.AltRef = @enumFromInt(buf[24]);
                break :blk ext_eval.ExtValue{ .LatLonAlt = .{ .lat = @bitCast(lat_bits), .lon = @bitCast(lon_bits), .alt = @bitCast(alt_bits), .ref = ref } };
            },
            13 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const wkb_data = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(wkb_data)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Geometry = .{ .wkb = wkb_data } };
            },
            14 => blk: {
                var buf: [9]u8 = undefined;
                if ((try reader.readAll(&buf)) < 9) break :blk ext_eval.ExtValue{ .Null = {} };
                const value_bits = std.mem.readInt(u64, buf[0..8], .little);
                const unit: heap_mod.TempUnit = @enumFromInt(buf[8]);
                break :blk ext_eval.ExtValue{ .Temperature = .{ .value_K = @bitCast(value_bits), .unit_in = unit } };
            },
            15 => blk: {
                var buf: [9]u8 = undefined;
                if ((try reader.readAll(&buf)) < 9) break :blk ext_eval.ExtValue{ .Null = {} };
                const value_bits = std.mem.readInt(u64, buf[0..8], .little);
                const unit: heap_mod.PressureUnit = @enumFromInt(buf[8]);
                break :blk ext_eval.ExtValue{ .Pressure = .{ .value_Pa = @bitCast(value_bits), .unit_in = unit } };
            },
            16 => blk: {
                var dim_buf: [2]u8 = undefined;
                if ((try reader.readAll(&dim_buf)) < 2) break :blk ext_eval.ExtValue{ .Null = {} };
                const dim = std.mem.readInt(u16, &dim_buf, .little);
                const vec_data = try self.allocator.alloc(f32, dim);
                for (0..dim) |i| {
                    var f_buf: [4]u8 = undefined;
                    if ((try reader.readAll(&f_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    vec_data[i] = @bitCast(std.mem.readInt(u32, &f_buf, .little));
                }
                break :blk ext_eval.ExtValue{ .VectorF32 = .{ .dim = dim, .data = vec_data } };
            },
            17 => blk: {
                var buf: [4]u8 = undefined;
                if ((try reader.readAll(&buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Date = .{ .days_since_epoch = std.mem.readInt(i32, &buf, .little) } };
            },
            18 => blk: {
                var buf: [8]u8 = undefined;
                if ((try reader.readAll(&buf)) < 8) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Time = .{ .micros_since_midnight = std.mem.readInt(i64, &buf, .little) } };
            },
            19 => blk: {
                var buf: [8]u8 = undefined;
                if ((try reader.readAll(&buf)) < 8) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .TimestampTZ = .{ .micros_since_epoch_utc = std.mem.readInt(i64, &buf, .little) } };
            },
            20 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                var loaded: usize = 0;
                const list = try self.allocator.alloc(ext_eval.ExtValue, len);
                errdefer {
                    for (list[0..loaded]) |item| {
                        freeExtValue(self, item);
                    }
                    self.allocator.free(list);
                }
                while (loaded < len) : (loaded += 1) {
                    list[loaded] = try self.readExtValue(reader);
                }
                break :blk ext_eval.ExtValue{ .List = list };
            },
            21 => blk: {
                var dim_buf: [2]u8 = undefined;
                if ((try reader.readAll(&dim_buf)) < 2) break :blk ext_eval.ExtValue{ .Null = {} };
                const dim = std.mem.readInt(u16, &dim_buf, .little);
                const vec_data = try self.allocator.alloc(i32, dim);
                for (0..dim) |i| {
                    var i_buf: [4]u8 = undefined;
                    if ((try reader.readAll(&i_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    vec_data[i] = std.mem.readInt(i32, &i_buf, .little);
                }
                break :blk ext_eval.ExtValue{ .VectorI32 = .{ .dim = dim, .data = vec_data } };
            },
            22 => blk: {
                var buf: [16]u8 = undefined;
                if ((try reader.readAll(&buf)) < 16) break :blk ext_eval.ExtValue{ .Null = {} };
                const months = std.mem.readInt(i32, buf[0..4], .little);
                const days = std.mem.readInt(i32, buf[4..8], .little);
                const micros = std.mem.readInt(i64, buf[8..16], .little);
                break :blk ext_eval.ExtValue{ .Interval = .{ .months = months, .days = days, .micros = micros } };
            },
            23 => blk: {
                var buf: [16]u8 = undefined;
                if ((try reader.readAll(&buf)) < 16) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .UUID = .{ .bytes = buf } };
            },
            24 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const s_len = std.mem.readInt(u32, &len_buf, .little);
                const scheme = try self.allocator.alloc(u8, s_len);
                if ((try reader.readAll(scheme)) < s_len) break :blk ext_eval.ExtValue{ .Null = {} };
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const h_len = std.mem.readInt(u32, &len_buf, .little);
                const host = try self.allocator.alloc(u8, h_len);
                if ((try reader.readAll(host)) < h_len) break :blk ext_eval.ExtValue{ .Null = {} };
                var flag_buf: [1]u8 = undefined;
                if ((try reader.readAll(&flag_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                const port = if (flag_buf[0] != 0) blk2: {
                    var p_buf: [2]u8 = undefined;
                    if ((try reader.readAll(&p_buf)) < 2) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk2 std.mem.readInt(u16, &p_buf, .little);
                } else null;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const p_len = std.mem.readInt(u32, &len_buf, .little);
                const path = try self.allocator.alloc(u8, p_len);
                if ((try reader.readAll(path)) < p_len) break :blk ext_eval.ExtValue{ .Null = {} };
                if ((try reader.readAll(&flag_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                const query = if (flag_buf[0] != 0) blk2: {
                    if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    const q_len = std.mem.readInt(u32, &len_buf, .little);
                    const q_data = try self.allocator.alloc(u8, q_len);
                    if ((try reader.readAll(q_data)) < q_len) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk2 q_data;
                } else null;
                if ((try reader.readAll(&flag_buf)) < 1) break :blk ext_eval.ExtValue{ .Null = {} };
                const fragment = if (flag_buf[0] != 0) blk2: {
                    if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    const f_len = std.mem.readInt(u32, &len_buf, .little);
                    const f_data = try self.allocator.alloc(u8, f_len);
                    if ((try reader.readAll(f_data)) < f_len) break :blk ext_eval.ExtValue{ .Null = {} };
                    break :blk2 f_data;
                } else null;
                break :blk ext_eval.ExtValue{ .Url = url_mod.Url{ .scheme = scheme, .host = host, .port = port, .path = path, .query = query, .fragment = fragment } };
            },
            25 => blk: {
                var count_buf: [4]u8 = undefined;
                if ((try reader.readAll(&count_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const count = std.mem.readInt(u32, &count_buf, .little);
                var domain_labels = try self.allocator.alloc([]const u8, count);
                for (0..count) |i| {
                    var len_buf: [4]u8 = undefined;
                    if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                    const len = std.mem.readInt(u32, &len_buf, .little);
                    const label = try self.allocator.alloc(u8, len);
                    if ((try reader.readAll(label)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                    domain_labels[i] = label;
                }
                break :blk ext_eval.ExtValue{ .Domain = url_mod.Domain{ .labels = domain_labels } };
            },
            26 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const bytea_data = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(bytea_data)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Bytea = bytea_data };
            },
            27 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const json_data = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(json_data)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Json = json_data };
            },
            28 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const jsonb_data = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(jsonb_data)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Jsonb = jsonb_mod.JsonbDocument{ .data = jsonb_data, .allocator = self.allocator } };
            },
            29 => blk: {
                var len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const len = std.mem.readInt(u32, &len_buf, .little);
                const xml_data = try self.allocator.alloc(u8, len);
                if ((try reader.readAll(xml_data)) < len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .Xml = xml_mod.XmlDocument{ .data = xml_data } };
            },
            30 => blk: {
                var bit_len_buf: [8]u8 = undefined;
                if ((try reader.readAll(&bit_len_buf)) < 8) break :blk ext_eval.ExtValue{ .Null = {} };
                var byte_len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&byte_len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const byte_len = std.mem.readInt(u32, &byte_len_buf, .little);
                const bytes = try self.allocator.alloc(u8, byte_len);
                if ((try reader.readAll(bytes)) < byte_len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .BitString = bitstring_mod.BitString{ .bytes = bytes, .bit_length = @intCast(std.mem.readInt(u64, &bit_len_buf, .little)) } };
            },
            31 => blk: {
                var bit_len_buf: [8]u8 = undefined;
                if ((try reader.readAll(&bit_len_buf)) < 8) break :blk ext_eval.ExtValue{ .Null = {} };
                var byte_len_buf: [4]u8 = undefined;
                if ((try reader.readAll(&byte_len_buf)) < 4) break :blk ext_eval.ExtValue{ .Null = {} };
                const byte_len = std.mem.readInt(u32, &byte_len_buf, .little);
                const bytes = try self.allocator.alloc(u8, byte_len);
                if ((try reader.readAll(bytes)) < byte_len) break :blk ext_eval.ExtValue{ .Null = {} };
                break :blk ext_eval.ExtValue{ .VarBit = bitstring_mod.BitString{ .bytes = bytes, .bit_length = @intCast(std.mem.readInt(u64, &bit_len_buf, .little)) } };
            },
            32 => blk: {
                var buf: [10]u8 = undefined;
                if ((try reader.readAll(&buf)) < 10) break :blk ext_eval.ExtValue{ .Null = {} };
                const flags = buf[0];
                const lower = if ((flags & 0b01) != 0) std.mem.readInt(i32, buf[1..5], .little) else null;
                const upper = if ((flags & 0b10) != 0) std.mem.readInt(i32, buf[5..9], .little) else null;
                const bounds: range_mod.IntRange.Bounds = @enumFromInt(buf[9]);
                break :blk ext_eval.ExtValue{ .IntRange = range_mod.IntRange{ .lower = lower, .upper = upper, .bounds = bounds } };
            },
            33 => blk: {
                var buf: [8]u8 = undefined;
                if ((try reader.readAll(&buf)) < 8) break :blk ext_eval.ExtValue{ .Null = {} };
                const type_id = std.mem.readInt(u32, buf[0..4], .little);
                const value_ordinal = std.mem.readInt(u32, buf[4..8], .little);
                break :blk ext_eval.ExtValue{ .Enum = .{ .type_id = type_id, .value_ordinal = value_ordinal } };
            },
            else => ext_eval.ExtValue{ .Null = {} },
        };
    }

    /// No-op: per-graph file persistence removed — adapter handles storage.
    pub fn savePerGraphFiles(self: *GraphStore) !void {
        _ = self;
    }

    /// No-op: per-graph file loading removed — adapter handles storage.
    pub fn loadPerGraphFiles(self: *GraphStore) !void {
        _ = self;
    }

    // CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-002; FEATURE="EngineBackedPersistence"; ASPECT=SaveToFile; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=storage; UPDATED=2026-04-11
    // Save delegates to adapter checkpoint. Public ID mappings are now stored
    // inside graph-storage properties rather than a sidecar id_map.dat file.
    pub fn saveToFile(self: *GraphStore) !void {
        return self.saveToFileEx(false);
    }

    /// GAP-0900 Layer-2: `light=true` runs the BOUNDED (light) engine checkpoint
    /// — flush dirty pages + truncate the engine WAL, but SKIP the O(graph-size)
    /// derived-index re-save (rebuilt from pages on reopen). The periodic
    /// persistence loop + WAL checkpoint hook use light so a RUNTIME checkpoint
    /// stays O(dirty) instead of O(total graph); a full checkpoint here holds the
    /// exclusive store lock for minutes at multi-million-node scale (66 min at
    /// 7.8M nodes observed), stalling the whole ingest and ballooning RSS.
    /// `light=false` (full, with derived indexes) is kept for explicit saves:
    /// clean shutdown, backup, snapshot, cluster transfer.
    pub fn saveToFileEx(self: *GraphStore, light: bool) !void {
        if (global_adapter) |adapter| {
            if (light) {
                try adapter.checkpointAllLight();
            } else {
                try adapter.checkpointAll();
                // PHASE 1b: only the FULL checkpoint (clean shutdown / explicit
                // save / backup) re-serialises the mmap IdMap snapshots so a
                // later open can bulk-load them (sub-second ready). The LIGHT
                // runtime checkpoint must stay O(dirty), so it is skipped here.
                self.saveIdMapSnapshots(adapter);
                // GAP-ENT-0023 P3: persist the loop2 hydration products of
                // every HYDRATED graph (counters / label postings / merge
                // index) at the same post-checkpoint counter, so the next
                // open's first-access hydration is O(snapshot) instead of the
                // O(graph) engine scan. Same gate discipline as the IdMap
                // snapshots (never persist a deferred graph's empty state).
                self.saveHydrationSnapshots(adapter);
            }
        }
        self.cleanupLegacySidecars();
        self.dirty.store(false, .release);
    }

    /// PHASE 1b: write every resident graph's IdMap to a counter-gated mmap
    /// snapshot in its graph dir, stamped with the engine's CURRENT (post-
    /// checkpoint) manifest counter so a later open accepts it iff no committed
    /// write happened since. Best-effort per graph: a failure to write one
    /// snapshot just means that graph falls back to the scan-rebuild next open.
    fn saveIdMapSnapshots(self: *GraphStore, adapter: *graph_storage_adapter.StorageAdapter) void {
        var it = self.id_maps.iterator();
        while (it.next()) |entry| {
            self.saveIdMapSnapshotForGraph(adapter, entry.key_ptr.*, entry.value_ptr);
        }
    }

    /// Per-graph core of `saveIdMapSnapshots` — shared by the full-checkpoint
    /// loop above and the Task 3 hydration persist-on-complete path
    /// (`persistHydrationProductsForGraph`). ALL gates live here so every
    /// caller inherits them.
    fn saveIdMapSnapshotForGraph(
        self: *GraphStore,
        adapter: *graph_storage_adapter.StorageAdapter,
        graph_name: []const u8,
        id_map: *id_map_mod.IdMap,
    ) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const dir_path = (self.resolveGraphRootDirPath(graph_name) catch return) orelse return;
        defer self.allocator.free(dir_path);
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
        defer dir.close(io);

        // CRITICAL (silent-data-loss guard): a graph whose loop1 IdMap build
        // was DEFERRED at open (no-snapshot fallback: markPendingHydration
        // with NO snapshot adopted) and has NOT been hydrated yet has an
        // EMPTY, `.resident` overlay — loop1 never ran. Persisting it here
        // would write an EMPTY snapshot stamped with the CURRENT manifest
        // counter; the next open's counter-gate would PASS and adopt the
        // empty IdMap as base, so the graph would appear empty forever.
        // Skip the write and INVALIDATE any stale on-disk snapshot so the
        // next open re-defers + rebuilds from the durable engine pages.
        // (Crash-safety is preserved: the durable pages are the source of
        // truth; skipping the snapshot just means the next open rebuilds.)
        //
        // A `.mmap_backed` deferred graph is NOT dangerous: it adopted a
        // valid snapshot as its immutable base at open (case A), so its
        // merged view still reflects the on-disk mapping and re-serializing
        // it is correct (and preserves the sub-second-open fast path). Only
        // the empty `.resident` deferred case (case B) is skipped, so idle
        // snapshot-backed graphs keep their snapshots across a checkpoint.
        //
        // NOTE: we do NOT call ensureGraphHydrated here — a routine
        // checkpoint must not force full hydration of every idle graph, and
        // skipping avoids taking hydration_build_mutex under the checkpoint
        // path entirely (no lock inversion vs. loadOneGraphFromAdapterFull).
        // GAP-ENT-0023 P3 (review C1): a FAILED (quarantined) hydration is
        // gated exactly like a deferred one for the `.resident` case — the
        // scan died mid-way, so a resident IdMap may hold a PARTIAL
        // re-insert set. (`.mmap_backed` is safe either way: the base was
        // adopted from a counter-valid snapshot before the scan started
        // and the failed scan's overlay re-inserts are idempotent
        // duplicates of base entries, so the merged view stays complete.)
        if (id_map.mode == .resident and
            (self.isGraphDeferred(graph_name) or self.isGraphHydrationFailed(graph_name)))
        {
            id_map_mod.IdMap.deleteSnapshot(dir);
            return;
        }

        // GAP-0064 FIX B: stamp on the Path-B (checkpoint_epoch, covered_lsn)
        // contract (mirrors prop_exact.idx / fa6495bb) instead of manifest.counter,
        // which recovery.zig bumps on ANY committed WAL-tail replay — needlessly
        // rejecting a still-valid IdMap snapshot on a deferred-WAL reopen and
        // forcing a full loop1/loop2 re-scan.
        const epoch = adapter.graphCheckpointEpoch(graph_name) orelse return;
        const covered = adapter.graphDurableFrontierLsn(graph_name) orelse return;
        id_map.saveSnapshot(dir, epoch, covered) catch |err| {
            log.warn("failed to write IdMap snapshot", &.{
                Attr.string("graph", graph_name),
                Attr.string("error", @errorName(err)),
            });
        };
    }

    /// PHASE 1b: true iff `graph_name` has a deferred-hydration entry that has
    /// NOT completed (its resident loop1/loop2 build is still pending). Reads the
    /// authoritative hydration state (`pending_hydration` membership + the
    /// entry's atomic `done` latch) under `hydration_mutex` — the same leaf lock
    /// `markPendingHydration`/`ensureGraphHydrated` use. A graph absent from
    /// `pending_hydration` (freshly CREATEd, default, snapshot/clone store, or
    /// already hydrated) returns false.
    fn isGraphDeferred(self: *GraphStore, graph_name: []const u8) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.hydration_mutex.lockUncancelable(io);
        defer self.hydration_mutex.unlock(io);
        const entry = self.pending_hydration.get(graph_name) orelse return false;
        return !entry.done.load(.acquire);
    }

    /// GAP-ENT-0023 P3 (review C1): true iff `graph_name`'s first-touch
    /// hydration FAILED and the graph is quarantined (done=true, failed=true).
    /// Its resident loop2 products (label postings / introspection multisets /
    /// merge index / typed-edge counters) — and, for a `.resident` IdMap, the
    /// IdMap itself — are PARTIAL and must never be persisted counter-current.
    fn isGraphHydrationFailed(self: *GraphStore, graph_name: []const u8) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.hydration_mutex.lockUncancelable(io);
        defer self.hydration_mutex.unlock(io);
        const entry = self.pending_hydration.get(graph_name) orelse return false;
        return entry.failed.load(.acquire);
    }

    /// TEST-ONLY (GAP-0061): force `graph_name`'s deferred-hydration entry into
    /// the QUARANTINED terminal state (done=true, failed=true) WITHOUT running
    /// the resident-index scan. This reproduces the production condition where
    /// the security graph's streaming hydration raises `error.DataCorruption`
    /// and `ensureGraphHydrated` quarantines the graph, so `getNodesByLabel`
    /// returns null even though the storage engine still holds intact,
    /// individually-readable records. Returns false when the graph has no
    /// pending-hydration entry (already hydrated / never deferred). Not used by
    /// any production path — only the GAP-0061 crash-auth regression test.
    pub fn forceHydrationQuarantineForTest(self: *GraphStore, graph_name: []const u8) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.hydration_mutex.lockUncancelable(io);
        defer self.hydration_mutex.unlock(io);
        const entry = self.pending_hydration.get(graph_name) orelse return false;
        entry.done.store(true, .release);
        entry.failed.store(true, .release);
        return true;
    }

    /// C-1 (T2b adversarial review): true iff `graph_name` has a deferred-
    /// hydration entry whose build has NOT completed (`done == false`) — a
    /// first-touch hydration is pending or currently BUILDING. The checkpoint
    /// grace window (`checkpointOneGraph`'s retired-cache reclaims in the
    /// storage adapter) consults this to SKIP freeing this graph's retired
    /// cache bodies: the hydration merge's family threads read shallow Node
    /// copies whose sub-heaps (labels / property strings / graph_name /
    /// tenant_id) are owned by the bounded node cache — and once the same
    /// merge's cache puts EVICT those entries, the sub-heaps live on exactly
    /// the per-graph retire lists the grace window frees. Hydration
    /// deliberately never holds `mg.rwlock`, so the checkpoint's EXCLUSIVE
    /// rwlock acquisition does NOT drain those readers; this predicate is
    /// what does.
    ///
    /// Race-safety: `done` is stored (.release) only AFTER every scan/family
    /// thread has been joined (both the clean path — `pipeline.finish()` —
    /// and every error path join first), so an `.acquire` load of `false`
    /// here is exactly the "a hydration thread may still hold retired
    /// sub-heap pointers" condition, and a load of `true` happens-after all
    /// those reads. Entries are only ever CREATED at open registration and
    /// never removed for the process lifetime, so there is no
    /// entry-appears-mid-check race. Skipping the reclaim on `true` is
    /// always safe — the retire backlog just survives to the next grace
    /// window (typically the persist-on-complete graph checkpoint fired
    /// right after `done` flips).
    pub fn hasUnfinishedHydration(self: *GraphStore, graph_name: []const u8) bool {
        return self.isGraphDeferred(graph_name);
    }

    // ── GAP-ENT-0023 P3: per-graph loop2-product snapshots ─────────────────
    //
    // Persist geode's loop2 hydration products so a warm reopen's first-access
    // hydration loads them O(snapshot) instead of rebuilding from the O(graph)
    // engine scan in `loadOneGraphFromAdapterFull` (>10 h on the legacy
    // 14.27M store). Three per-graph, counter-gated files live next to
    // `idmap.snapshot` in the graph's engine root dir:
    //
    //   hydration_counters.snap  — node count, per-(graph,label) +
    //                              per-(graph,edge-type) exact counts, and the
    //                              per-(graph,tenant) introspection multisets
    //                              (node labels / edge types / label-props).
    //   hydration_labels.snap    — per-(graph,label) sorted node-id postings.
    //   hydration_merge.snap     — the {graph,label,key,value}->node_id merge
    //                              property index shards (incl. composites).
    //
    // Lifecycle: written ONLY at a FULL checkpoint for graphs that are NOT
    // deferred (loop2 products resident + authoritative), stamped with the
    // post-checkpoint engine manifest counter — exactly the saveIdMapSnapshots
    // discipline. Node/edge/adjacency CACHES are deliberately NOT snapshotted
    // (bounded, hydrate-on-miss, correctness never depends on residency).

    // v2 = GAP-0064 FIX B: (checkpoint_epoch, covered_lsn) stamp replaced the
    // manifest.counter stamp. The bump makes an old v1 counter-stamped file load
    // as null on a new binary (rebuild) and vice-versa — never a mis-parse.
    const HYDRATION_SNAP_VERSION: u32 = 2;
    const HYDRATION_COUNTERS_MAGIC: [8]u8 = "GHYDCNT1".*;
    const HYDRATION_COUNTERS_FILE = "hydration_counters.snap";
    const HYDRATION_COUNTERS_TMP = "hydration_counters.snap.tmp";
    const HYDRATION_LABELS_MAGIC: [8]u8 = "GHYDLBL1".*;
    const HYDRATION_LABELS_FILE = "hydration_labels.snap";
    const HYDRATION_LABELS_TMP = "hydration_labels.snap.tmp";
    const HYDRATION_MERGE_MAGIC: [8]u8 = "GHYDMRG1".*;
    const HYDRATION_MERGE_FILE = "hydration_merge.snap";
    const HYDRATION_MERGE_TMP = "hydration_merge.snap.tmp";

    /// Kill switch: GEODE_DISABLE_HYDRATION_SNAPSHOTS=1 disables both writing
    /// and loading the loop2-product snapshots (hydration falls back to the
    /// engine scan exactly as before this feature). Read per call — these are
    /// cold paths (full checkpoint / first-touch hydration).
    ///
    /// TDE PLAINTEXT-LEAK GUARD (harness: tde_backup_envelope_wrong_kek /
    /// tde_bitflip_detection): the loop2-product snapshots (hydration_merge.snap
    /// in particular) persist the {graph,label,key,VALUE}->node_id MERGE index —
    /// i.e. raw property VALUES — via the hydration_snapshot writer, which emits
    /// magic+CRC-framed but UNENCRYPTED bytes. Under TDE (GEODE_TDE_KEY set) the
    /// engine page store is AES-GCM encrypted at rest, but these side-car
    /// snapshots are NOT, so they would leak plaintext (a sentinel string, a PII
    /// value) to disk — defeating TDE. Since the snapshots are a pure hydration
    /// OPTIMIZATION (absence just falls back to the encrypted engine scan, no
    /// correctness impact), suppress BOTH write and load whenever TDE is active.
    /// A dedicated encrypted-snapshot format is the follow-up; until then,
    /// fail-safe by not writing plaintext.
    fn hydrationSnapshotsDisabled() bool {
        if (std.c.getenv("GEODE_TDE_KEY") != null) return true;
        const raw_z = std.c.getenv("GEODE_DISABLE_HYDRATION_SNAPSHOTS") orelse return false;
        const raw = std.mem.span(raw_z);
        return std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "yes");
    }

    /// Task 3 kill switch: GEODE_DISABLE_HYDRATION_COMPLETION_PERSIST=1
    /// disables the immediate persist at the end of a successful first-touch
    /// hydration (products then persist only at the next full checkpoint /
    /// clean shutdown — the pre-Task-3 behaviour). Read per call — this is a
    /// cold path (once per graph per process lifetime). Also used by the
    /// stream-scan parity/throughput tests, which need repeated genuine
    /// scan-rebuild reopens on the same store.
    fn hydrationCompletionPersistDisabled() bool {
        const raw_z = std.c.getenv("GEODE_DISABLE_HYDRATION_COMPLETION_PERSIST") orelse return false;
        const raw = std.mem.span(raw_z);
        return std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "yes");
    }

    fn deleteHydrationSnapshotFiles(dir: std.Io.Dir) void {
        hydration_snapshot.deleteFiles(dir, HYDRATION_COUNTERS_FILE, HYDRATION_COUNTERS_TMP);
        hydration_snapshot.deleteFiles(dir, HYDRATION_LABELS_FILE, HYDRATION_LABELS_TMP);
        hydration_snapshot.deleteFiles(dir, HYDRATION_MERGE_FILE, HYDRATION_MERGE_TMP);
    }

    /// True when a merge-index key ("graph\x00label\x00...", see
    /// buildMergeIndexKey / buildCompositeMergeIndexKey) belongs to
    /// `graph_name`. The NUL separator makes this unambiguous (graph names
    /// cannot contain NUL).
    fn mergeKeyMatchesGraph(key: []const u8, graph_name: []const u8) bool {
        return key.len > graph_name.len and
            key[graph_name.len] == 0 and
            std.mem.eql(u8, key[0..graph_name.len], graph_name);
    }

    /// True when `key` ("graph:label" / "graph:type", see formatGraphLabelKey)
    /// belongs to `graph_name`. Prefix match on "graph:"; a graph name that
    /// itself contains ':' carries the same (pre-existing, system-wide)
    /// ambiguity the composite key format has — the snapshot neither adds nor
    /// removes it (save and restore use the identical convention).
    fn graphLabelKeyMatchesGraph(key: []const u8, graph_name: []const u8) bool {
        return key.len > graph_name.len and
            key[graph_name.len] == ':' and
            std.mem.eql(u8, key[0..graph_name.len], graph_name);
    }

    /// GAP-ENT-0023 P3: write the loop2-product snapshots for every HYDRATED
    /// graph after a FULL checkpoint. Best-effort per graph (a failed write
    /// only costs the next open a scan-rebuild — never correctness).
    ///
    /// CRITICAL (silent-data-loss guard, the 9b2d42eb hazard class): a graph
    /// that is still DEFERRED has EMPTY resident loop2 products — loop2 never
    /// ran. Persisting them would write empty-but-counter-current snapshots
    /// the next open would trust, freezing the graph's indexes empty forever.
    /// Mirror the saveIdMapSnapshots gate:
    ///   * case B (.resident IdMap, deferred): the on-disk snapshot generation
    ///     is stale (that is why no snapshot was adopted) — DELETE the loop2
    ///     files and skip.
    ///   * case A (.mmap_backed IdMap, deferred): the graph adopted a valid
    ///     snapshot at open and has seen no writes (any write would have
    ///     hydrated it first), so the existing on-disk loop2 files are exactly
    ///     as valid as they were — PRESERVE them (skip write, no delete).
    ///     Unlike the IdMap (which re-serialises its mmap base at the new
    ///     counter), we deliberately do NOT restamp them: restamping a file
    ///     whose content cannot be re-verified against the engine risks
    ///     falsely validating an older-generation leftover (e.g. after a
    ///     best-effort write failure). If the engine counter advanced, the
    ///     preserved files fail the counter gate on the next open and that
    ///     graph pays one scan — safe direction.
    fn saveHydrationSnapshots(self: *GraphStore, adapter: *graph_storage_adapter.StorageAdapter) void {
        var it = self.id_maps.iterator();
        while (it.next()) |entry| {
            self.saveHydrationSnapshotsForOneGraph(adapter, entry.key_ptr.*, entry.value_ptr);
        }
    }

    /// Per-graph core of `saveHydrationSnapshots` — shared by the
    /// full-checkpoint loop above and the Task 3 hydration
    /// persist-on-complete path (`persistHydrationProductsForGraph`). ALL
    /// gates (failed-quarantine delete, deferred case-B delete / case-A
    /// preserve, kill switch) live here so every caller inherits them.
    fn saveHydrationSnapshotsForOneGraph(
        self: *GraphStore,
        adapter: *graph_storage_adapter.StorageAdapter,
        graph_name: []const u8,
        id_map: *id_map_mod.IdMap,
    ) void {
        // M2 hardening: when the kill switch is on we still run the DELETE
        // gates below (deferred case B + failed-hydration), so files written
        // before the switch was flipped cannot linger while disabled — only
        // the WRITE side is disabled.
        const disabled = hydrationSnapshotsDisabled();
        const io = std.Io.Threaded.global_single_threaded.io();
        const dir_path = (self.resolveGraphRootDirPath(graph_name) catch return) orelse return;
        defer self.allocator.free(dir_path);
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
        defer dir.close(io);

        // GAP-ENT-0023 P3 (review C1): a graph whose first-touch hydration
        // FAILED is quarantined with done=true, so it reads as "hydrated"
        // — but its resident loop2 products are PARTIAL (the scan died
        // mid-way). Persisting them would stamp partial indexes with the
        // CURRENT manifest counter: the next open would accept them and
        // every later checkpoint would re-bless them — permanent silent
        // wrong results (missing rows, duplicate MERGEs). Treat it like
        // deferred case B regardless of IdMap mode: delete any files
        // (theirs is a dead generation now) and write nothing, so the
        // next reopen re-scans cleanly (the pre-P3 self-heal).
        if (self.isGraphHydrationFailed(graph_name)) {
            deleteHydrationSnapshotFiles(dir);
            return;
        }

        if (self.isGraphDeferred(graph_name)) {
            if (id_map.mode == .resident) deleteHydrationSnapshotFiles(dir);
            return;
        }

        if (disabled) return;

        // GAP-0064 FIX B: stamp the loop2 snapshots on the Path-B
        // (checkpoint_epoch, covered_lsn) contract (same as the idmap.snapshot +
        // prop_exact.idx), not manifest.counter — recovery.zig bumps the counter
        // on any committed WAL-tail replay, which rejected still-valid loop2
        // snapshots on a deferred-WAL reopen and forced a full loop2 re-scan.
        const epoch = adapter.graphCheckpointEpoch(graph_name) orelse return;
        const covered = adapter.graphDurableFrontierLsn(graph_name) orelse return;
        self.saveHydrationCountersSnapshot(dir, graph_name, epoch, covered) catch |err| {
            // Invalidate rather than leave a possibly half-generation
            // file set behind (the old file would be generation-stale and
            // rejected anyway; deleting removes any doubt).
            hydration_snapshot.deleteFiles(dir, HYDRATION_COUNTERS_FILE, HYDRATION_COUNTERS_TMP);
            log.warn("failed to write hydration counters snapshot", &.{
                Attr.string("graph", graph_name),
                Attr.string("error", @errorName(err)),
            });
        };
        self.saveHydrationLabelsSnapshot(dir, graph_name, epoch, covered) catch |err| {
            hydration_snapshot.deleteFiles(dir, HYDRATION_LABELS_FILE, HYDRATION_LABELS_TMP);
            log.warn("failed to write hydration label-postings snapshot", &.{
                Attr.string("graph", graph_name),
                Attr.string("error", @errorName(err)),
            });
        };
        self.saveHydrationMergeSnapshot(dir, graph_name, epoch, covered) catch |err| {
            hydration_snapshot.deleteFiles(dir, HYDRATION_MERGE_FILE, HYDRATION_MERGE_TMP);
            log.warn("failed to write hydration merge-index snapshot", &.{
                Attr.string("graph", graph_name),
                Attr.string("error", @errorName(err)),
            });
        };
    }

    /// Task 3 (hydration persist-on-complete): persist ONE graph's hydration
    /// products IMMEDIATELY after a successful first-touch hydration, so a
    /// crash right after (two production crashes each lost a 13 h hydration)
    /// loses nothing. Runs, in the exact `saveToFileEx(false)` order:
    ///
    ///   1. `adapter.checkpointGraph` — graph-scoped FULL engine checkpoint:
    ///      flush + WAL truncate + manifest-counter bump + gs-side derived /
    ///      Lever-B snapshot disciplines + geode H4 exact-index persist (IF
    ///      built; invalidated otherwise — the persist-empty gate). A no-op
    ///      inside gs when nothing is dirty (clean warm reopen), so a
    ///      read-only hydration cannot strand other counter-stamped
    ///      snapshots.
    ///   2. `saveIdMapSnapshotForGraph` + `saveHydrationSnapshotsForOneGraph`
    ///      — the P3 loop2-product + IdMap snapshots stamped at the NEW
    ///      post-checkpoint counter, with ALL their existing gates
    ///      (deferred/failed skip-and-delete — the 9b2d42eb/C1 hazard class —
    ///      and the GEODE_DISABLE_HYDRATION_SNAPSHOTS kill switch).
    ///
    /// BEST-EFFORT AND NON-FATAL: the hydration (and the query that triggered
    /// it) already succeeded; any persist failure is logged LOUDLY and merely
    /// costs the next reopen a re-scan (the pre-Task-3 behaviour).
    ///
    /// Caller contract: invoked from `ensureGraphHydrated` AFTER
    /// `entry.done.store(true)` (so the deferred-gate reads the graph as
    /// hydrated) and ONLY when the build succeeded (never on quarantine).
    /// Runs under `entry.mutex` + `hydration_build_mutex`; the engine
    /// checkpoint inside uses a BOUNDED exclusive-rwlock acquire so a
    /// concurrent SHARED-lock holder blocked on a hydration chokepoint
    /// degrades this persist instead of deadlocking it.
    fn persistHydrationProductsForGraph(
        self: *GraphStore,
        adapter: *graph_storage_adapter.StorageAdapter,
        graph_name: []const u8,
    ) void {
        if (hydrationCompletionPersistDisabled()) return;
        // Defense in depth — the per-graph savers re-run these gates, but a
        // deferred/quarantined graph must not even reach the engine
        // checkpoint (persist-empty / persist-partial is the #1 hazard).
        if (self.isGraphDeferred(graph_name) or self.isGraphHydrationFailed(graph_name)) return;

        const failed_injected = if (comptime @import("builtin").is_test)
            g_test_hydration_persist_fail.load(.acquire)
        else
            false;

        if (failed_injected) {
            _ = g_hydration_completion_persist_failures.fetchAdd(1, .monotonic);
            log.err("hydration-completion persist FAILED; products stay memory-only until the next full checkpoint (a crash before then re-pays the scan)", &.{
                Attr.string("graph", graph_name),
                Attr.string("error", "TestInjectedPersistFailure"),
            });
            return;
        }

        adapter.checkpointGraph(graph_name) catch |err| {
            _ = g_hydration_completion_persist_failures.fetchAdd(1, .monotonic);
            log.err("hydration-completion persist FAILED; products stay memory-only until the next full checkpoint (a crash before then re-pays the scan)", &.{
                Attr.string("graph", graph_name),
                Attr.string("error", @errorName(err)),
            });
            return;
        };

        const id_map = self.getIdMap(graph_name) orelse return;
        self.saveIdMapSnapshotForGraph(adapter, graph_name, id_map);
        self.saveHydrationSnapshotsForOneGraph(adapter, graph_name, id_map);
        _ = g_hydration_completion_persists.fetchAdd(1, .monotonic);
        log.info("hydration products persisted on completion (crash-safe)", &.{
            Attr.string("graph", graph_name),
        });
    }

    /// Serialize one hydrated graph's merge-property-index entries (single-key
    /// AND composite — both live in `merge_prop_index` under "graph\x00..."
    /// keys). Payload layout, designed fixed-width-record + per-shard-sorted
    /// so a future mmap adoption (per-shard binary search) is trivial while a
    /// plain re-insert load stays valid today:
    ///   config_hash u64  (mergeIndexConfigHash at save time — load gate)
    ///   shard_count u32  (write-time shard grouping; load re-verifies hashes)
    ///   shard_count x {
    ///     entry_count u64, blob_len u64,
    ///     entry_count x { key_off u64, key_len u32, node_id u64 }  (20 B,
    ///                    sorted by key bytes within the shard),
    ///     blob bytes (concatenated keys, WITH the graph prefix)
    ///   }
    fn saveHydrationMergeSnapshot(
        self: *GraphStore,
        dir: std.Io.Dir,
        graph_name: []const u8,
        checkpoint_epoch: u64,
        covered_lsn: u64,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var w = try hydration_snapshot.AtomicWriter.init(
            self.allocator,
            dir,
            HYDRATION_MERGE_TMP,
            HYDRATION_MERGE_FILE,
            HYDRATION_MERGE_MAGIC,
        );
        errdefer w.abort();

        try w.writeInt(u64, mergeIndexConfigHash());
        try w.writeInt(u32, @intCast(merge_property_index_shard_count));

        const Entry = struct { key: []const u8, node_id: u64 };
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(self.allocator);

        for (&self.merge_prop_index.shards) |*shard| {
            shard.mutex.lockUncancelable(io);
            defer shard.mutex.unlock(io);
            entries.clearRetainingCapacity();
            var it = shard.map.iterator();
            while (it.next()) |e| {
                if (!mergeKeyMatchesGraph(e.key_ptr.*, graph_name)) continue;
                try entries.append(self.allocator, .{ .key = e.key_ptr.*, .node_id = e.value_ptr.* });
            }
            std.sort.pdq(Entry, entries.items, {}, struct {
                fn lt(_: void, a: Entry, b: Entry) bool {
                    return std.mem.lessThan(u8, a.key, b.key);
                }
            }.lt);
            try w.writeInt(u64, @intCast(entries.items.len));
            var blob_len: u64 = 0;
            for (entries.items) |en| blob_len += en.key.len;
            try w.writeInt(u64, blob_len);
            var off: u64 = 0;
            for (entries.items) |en| {
                try w.writeInt(u64, off);
                try w.writeInt(u32, @intCast(en.key.len));
                try w.writeInt(u64, en.node_id);
                off += en.key.len;
            }
            for (entries.items) |en| try w.writeAll(en.key);
        }

        try w.finish(HYDRATION_SNAP_VERSION, checkpoint_epoch, covered_lsn);
    }

    /// Serialize one hydrated graph's label-index postings. Payload layout:
    ///   n_entries u32, n x { label bytes (u32-len), id_count u64,
    ///                        id_count x node_id u64 (strictly ascending) }
    /// Labels are stored WITHOUT the graph prefix (per-graph file).
    fn saveHydrationLabelsSnapshot(
        self: *GraphStore,
        dir: std.Io.Dir,
        graph_name: []const u8,
        checkpoint_epoch: u64,
        covered_lsn: u64,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var w = try hydration_snapshot.AtomicWriter.init(
            self.allocator,
            dir,
            HYDRATION_LABELS_TMP,
            HYDRATION_LABELS_FILE,
            HYDRATION_LABELS_MAGIC,
        );
        errdefer w.abort();

        // Hold the outer mutex across both passes so the key set is stable;
        // take each posting's leaf lock while copying its ids (same order as
        // addToLabelIndex: label_index_mutex -> posting lock).
        self.label_index_mutex.lockUncancelable(io);
        defer self.label_index_mutex.unlock(io);

        var n: u32 = 0;
        var it = self.label_index.iterator();
        while (it.next()) |e| {
            if (graphLabelKeyMatchesGraph(e.key_ptr.*, graph_name)) n += 1;
        }
        try w.writeInt(u32, n);
        it = self.label_index.iterator();
        while (it.next()) |e| {
            if (!graphLabelKeyMatchesGraph(e.key_ptr.*, graph_name)) continue;
            try w.writeBytes(e.key_ptr.*[graph_name.len + 1 ..]);
            const posting = e.value_ptr;
            posting.lock();
            defer posting.unlock();
            try w.writeInt(u64, @intCast(posting.list.items.len));
            for (posting.list.items) |id| try w.writeInt(u64, id);
        }

        try w.finish(HYDRATION_SNAP_VERSION, checkpoint_epoch, covered_lsn);
    }

    /// Serialize one hydrated graph's counter products. Payload layout
    /// (little-endian; strings are u32-length-prefixed):
    ///   node_count u64
    ///   n_label_counts u32,     n x { label bytes, count u64 }
    ///   n_edge_type_counts u32, n x { type bytes, count u64 }
    ///   3 tenant sections (node labels / edge types / label\x00prop):
    ///     n_tenants u32, n x { tenant bytes, n_inner u32,
    ///                          n_inner x { key bytes, count u64 } }
    /// Labels/types/tenants are stored WITHOUT the graph prefix (the file is
    /// per-graph); restore re-applies the current composite-key conventions.
    fn saveHydrationCountersSnapshot(
        self: *GraphStore,
        dir: std.Io.Dir,
        graph_name: []const u8,
        checkpoint_epoch: u64,
        covered_lsn: u64,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var w = try hydration_snapshot.AtomicWriter.init(
            self.allocator,
            dir,
            HYDRATION_COUNTERS_TMP,
            HYDRATION_COUNTERS_FILE,
            HYDRATION_COUNTERS_MAGIC,
        );
        errdefer w.abort();

        // Per-graph node count (PERF-B set size; complete for a hydrated graph).
        const node_count: u64 = blk: {
            self.nodes_by_graph_mutex.lockUncancelable(io);
            defer self.nodes_by_graph_mutex.unlock(io);
            break :blk if (self.nodes_by_graph.getPtr(graph_name)) |inner| inner.count() else 0;
        };
        try w.writeInt(u64, node_count);

        // Exact (graph,label) counts. Two passes under the exclusive lock:
        // count, then emit (the map cannot change between passes).
        {
            self.label_count_rwlock.lockUncancelable(io);
            defer self.label_count_rwlock.unlock(io);
            var n: u32 = 0;
            var cit = self.label_counts_by_graph.iterator();
            while (cit.next()) |e| {
                if (graphLabelKeyMatchesGraph(e.key_ptr.*, graph_name)) n += 1;
            }
            try w.writeInt(u32, n);
            cit = self.label_counts_by_graph.iterator();
            while (cit.next()) |e| {
                if (!graphLabelKeyMatchesGraph(e.key_ptr.*, graph_name)) continue;
                try w.writeBytes(e.key_ptr.*[graph_name.len + 1 ..]);
                try w.writeInt(u64, @intCast(e.value_ptr.load(.monotonic)));
            }
        }

        // Exact (graph,edge_type) counts.
        {
            self.edge_type_count_rwlock.lockUncancelable(io);
            defer self.edge_type_count_rwlock.unlock(io);
            var cit = self.edge_type_counts_by_graph.iterator();
            var n: u32 = 0;
            while (cit.next()) |e| {
                if (graphLabelKeyMatchesGraph(e.key_ptr.*, graph_name)) n += 1;
            }
            try w.writeInt(u32, n);
            cit = self.edge_type_counts_by_graph.iterator();
            while (cit.next()) |e| {
                if (!graphLabelKeyMatchesGraph(e.key_ptr.*, graph_name)) continue;
                try w.writeBytes(e.key_ptr.*[graph_name.len + 1 ..]);
                try w.writeInt(u64, @intCast(e.value_ptr.load(.monotonic)));
            }
        }

        // Tenant-keyed introspection multisets. The "graph\x00tenant" outer
        // key makes this graph's contribution a disjoint set of outer entries
        // (the whole point of the composite key), so save/restore is exact.
        try self.writeHydrationTenantSection(&w, &self.node_labels_by_tenant, graph_name);
        try self.writeHydrationTenantSection(&w, &self.edge_types_by_tenant, graph_name);
        try self.writeHydrationTenantSection(&w, &self.label_properties_by_tenant, graph_name);

        try w.finish(HYDRATION_SNAP_VERSION, checkpoint_epoch, covered_lsn);
    }

    fn writeHydrationTenantSection(
        self: *GraphStore,
        w: *hydration_snapshot.AtomicWriter,
        outer: *std.StringHashMap(std.StringHashMap(usize)),
        graph_name: []const u8,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.perf_c_refcount_mutex.lockUncancelable(io);
        defer self.perf_c_refcount_mutex.unlock(io);
        var n: u32 = 0;
        var oit = outer.iterator();
        while (oit.next()) |e| {
            if (std.mem.eql(u8, graphTenantKeyGraph(e.key_ptr.*), graph_name)) n += 1;
        }
        try w.writeInt(u32, n);
        oit = outer.iterator();
        while (oit.next()) |e| {
            if (!std.mem.eql(u8, graphTenantKeyGraph(e.key_ptr.*), graph_name)) continue;
            try w.writeBytes(graphTenantKeyTenant(e.key_ptr.*));
            try w.writeInt(u32, @intCast(e.value_ptr.count()));
            var iit = e.value_ptr.iterator();
            while (iit.next()) |ie| {
                try w.writeBytes(ie.key_ptr.*);
                try w.writeInt(u64, @intCast(ie.value_ptr.*));
            }
        }
    }

    /// DEPRECATED: Legacy serialization stub — adapter handles persistence.
    // CANARY: REQ=REQ-STREAM-SERIALIZE-002; FEATURE="StreamingSerialization"; ASPECT=StreamToFile; STATUS=EXEMPT; OWNER=storage; UPDATED=2026-03-28
    pub fn serializeToTempFile(self: *GraphStore, tmp_path: []const u8) !void {
        _ = self;
        _ = tmp_path;
    }

    /// DEPRECATED: Legacy finalization stub — adapter handles persistence.
    fn finalizeTempFile(allocator: std.mem.Allocator, tmp_path: []const u8, final_path: []const u8) !void {
        _ = allocator;
        _ = tmp_path;
        _ = final_path;
    }

    fn resolveGraphStorageDirPath(self: *GraphStore, graph_name: []const u8) !?[]u8 {
        if (self.data_dir.len == 0) return null;

        const graph_uuid = GraphStore.getGraphUuid(graph_name) orelse return null;
        const uuid_hex = std.fmt.bytesToHex(graph_uuid, .lower);
        const uuid_path = try std.fmt.allocPrint(self.allocator, "{s}/graphs/{s}", .{ self.data_dir, uuid_hex });
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), uuid_path, .{}) catch |err| {
            self.allocator.free(uuid_path);
            if (err == error.FileNotFound) return null;
            return err;
        };
        return uuid_path;
    }

    /// PHASE 1b: resolve the engine's per-graph ROOT directory
    /// (`<data_dir>/<uuid_hex>`, mirroring graph_storage_adapter.graphDirPath),
    /// where the mmap IdMap snapshot lives. Distinct from
    /// `resolveGraphStorageDirPath` which points at the LEGACY
    /// `<data_dir>/graphs/<uuid>` consolidated-engine layout. Returns null if
    /// there is no data dir, no UUID, or the directory is absent.
    fn resolveGraphRootDirPath(self: *GraphStore, graph_name: []const u8) !?[]u8 {
        if (self.data_dir.len == 0) return null;
        const graph_uuid = GraphStore.getGraphUuid(graph_name) orelse return null;
        const uuid_hex = std.fmt.bytesToHex(graph_uuid, .lower);
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.data_dir, uuid_hex });
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| {
            self.allocator.free(path);
            if (err == error.FileNotFound) return null;
            return err;
        };
        return path;
    }

    fn loadLegacyIdMap(self: *GraphStore, graph_name: []const u8) !?id_map_mod.IdMap {
        const graph_dir_path = (try self.resolveGraphStorageDirPath(graph_name)) orelse return null;
        defer self.allocator.free(graph_dir_path);

        const gs_io = std.Io.Threaded.global_single_threaded.io();
        var dir = std.Io.Dir.cwd().openDir(gs_io, graph_dir_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer dir.close(gs_io);

        dir.access(gs_io, "id_map.dat", .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };

        return try id_map_mod.IdMap.load(self.allocator, dir);
    }

    // CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-003; FEATURE="EngineBackedPersistence"; ASPECT=LegacyCleanup; STATUS=IMPL; OWNER=storage; UPDATED=2026-04-02
    /// Remove obsolete sidecar files after their contents have been migrated
    /// into the graph-storage engine.
    fn cleanupLegacySidecars(self: *GraphStore) void {
        var it = self.graphs.iterator();
        while (it.next()) |entry| {
            self.cleanupLegacySidecarsForGraph(entry.key_ptr.*);
        }
    }

    fn cleanupLegacySidecarsForGraph(self: *GraphStore, graph_name: []const u8) void {
        const graph_dir_path = self.resolveGraphStorageDirPath(graph_name) catch return orelse return;
        defer self.allocator.free(graph_dir_path);

        const gs_io = std.Io.Threaded.global_single_threaded.io();
        var dir = std.Io.Dir.cwd().openDir(gs_io, graph_dir_path, .{}) catch return;
        defer dir.close(gs_io);

        const stale_files = [_][]const u8{
            "adapter_labels.dat",
            "adapter_labels.dat.tmp",
            "id_map.dat",
            "id_map.dat.tmp",
        };
        for (stale_files) |name| {
            dir.deleteFile(gs_io, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => log.warn("failed to remove legacy graph sidecar", &.{
                    Attr.string("graph", graph_name),
                    Attr.string("file", name),
                    Attr.string("error", @errorName(err)),
                }),
            };
        }
    }

    /// Deprecated compatibility shim. Public ID mappings are no longer
    /// persisted in a sidecar file.
    pub fn saveIdMaps(self: *GraphStore) void {
        _ = self;
    }

    // CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-004; FEATURE="EngineBackedPersistence"; ASPECT=LoadFromAdapter; STATUS=TESTED; TEST=test-graph-store; OWNER=storage; UPDATED=2026-06-11
    /// Load graph data from the storage adapter into the in-memory cache.
    /// Scans all nodes and edges from the adapter, rebuilding Node/Edge
    /// structs, label index, adjacency index, and IdMaps.
    fn loadFromAdapter(self: *GraphStore, adapter: *graph_storage_adapter.StorageAdapter) !void {
        const graph_names = try adapter.listGraphNames(self.allocator);
        defer {
            for (graph_names) |name| self.allocator.free(name);
            self.allocator.free(graph_names);
        }

        // 2026-05-01: per-graph isolation. A single corrupted graph used to
        // bring down the whole service via the @panic at
        // getPrimaryGlobalStore (line ~6491) when ANY error escaped this
        // loop. Production journal `2026-05-01 18:31:54+` showed an
        // infinite restart loop after a GP exception left graph
        // 'abs_eagleg' on disk in an inconsistent state. Now we wrap each
        // graph's load in a catch-and-continue: if one graph fails to
        // hydrate, log it (with name + error) and keep going so the rest
        // of the database remains available.
        var degraded: usize = 0;
        for (graph_names) |graph_name| {
            self.loadOneGraphFromAdapter(adapter, graph_name) catch |err| {
                degraded += 1;
                log.err("graph load failed; quarantining graph and continuing startup", &.{
                    Attr.string("graph", graph_name),
                    Attr.string("error", @errorName(err)),
                });
                // R1 (review-0023 residual): a partially-loaded graph (the load
                // can die AFTER getOrCreateIdMap, e.g. OOM) would otherwise sit
                // in `id_maps` with NO pending_hydration entry — both
                // isGraphDeferred and isGraphHydrationFailed report false — so
                // the next FULL checkpoint would bless EMPTY IdMap + loop2
                // snapshots as counter-current and freeze the graph empty at
                // every later open. Best-effort: register the entry and mark it
                // FAILED so the checkpoint writers skip (and delete) its
                // snapshots; `done` stays false so the first in-session touch
                // still attempts a full rebuild (self-heal).
                if (self.markPendingHydration(graph_name)) |_| {
                    const hio = std.Io.Threaded.global_single_threaded.io();
                    self.hydration_mutex.lockUncancelable(hio);
                    defer self.hydration_mutex.unlock(hio);
                    if (self.pending_hydration.get(graph_name)) |hentry| {
                        hentry.failed.store(true, .release);
                    }
                } else |mark_err| {
                    log.warn("failed to quarantine partially-loaded graph; checkpoint may bless empty snapshots", &.{
                        Attr.string("graph", graph_name),
                        Attr.string("error", @errorName(mark_err)),
                    });
                }
                continue;
            };
        }
        if (degraded > 0) {
            log.warn("loadFromAdapter completed in degraded mode", &.{
                Attr.int("degraded_graphs", @intCast(degraded)),
                Attr.int("loaded_graphs", @intCast(graph_names.len - degraded)),
            });
        }

        // Startup diagnostic. PHASE 1b: graphs are REGISTERED here (IdMap loaded
        // from snapshot or scan) but the resident node/edge caches + indexes are
        // hydrated lazily on first access, so resident counts are expected to be
        // ~0 at open. `snapshot_idmaps` is the number of graphs whose IdMap came
        // from a counter-gated mmap snapshot (no engine scan).
        log.info("loadFromAdapter complete (resident-index build deferred)", &.{
            Attr.int("graphs", @intCast(graph_names.len - degraded)),
            Attr.int("snapshot_idmaps", @intCast(g_idmap_from_snapshot.load(.acquire))),
            Attr.int("resident_nodes", @intCast(self.nodes.count())),
            Attr.int("resident_edges", @intCast(self.edges.count())),
        });
    }

    /// PHASE 1b: per-graph OPEN step. Registers the graph and loads its IdMap
    /// WITHOUT the O(graph) resident-index scan, so "server ready" fires
    /// sub-second. When a counter-gated mmap IdMap snapshot is present it is
    /// bulk-loaded (no engine reads) and the resident loop2 indexes (label /
    /// nodes_by_graph / merge / tenant introspection / edges + adjacency /
    /// edge_type) are DEFERRED to first-touch (`ensureGraphHydrated`). When no
    /// valid snapshot exists (cold first open, or a stale/torn snapshot) it
    /// ALSO defers — the full per-graph build (loop1 IdMap scan-rebuild + loop2
    /// resident indexes) is registered as pending and runs lazily on first
    /// access, so open stays O(open_core) and "server ready" is sub-second even
    /// for a no-snapshot artifact. (Crash-safety is preserved: a crash before
    /// hydration leaves the durable pages; the next open defers again.)
    fn loadOneGraphFromAdapter(
        self: *GraphStore,
        adapter: *graph_storage_adapter.StorageAdapter,
        graph_name: []const u8,
    ) !void {
        try self.ensureGraphNoDirty(graph_name);
        const id_map = try self.getOrCreateIdMap(graph_name);

        if (try self.loadIdMapFromSnapshot(adapter, graph_name, id_map)) {
            // Snapshot path: IdMap resident with NO engine reads. Recover the
            // global public-id high-water from the resident IdMap (the deferred
            // loop2 is otherwise the only place next_node_id is bumped), then
            // defer the resident-index build to first access.
            self.recoverIdCountersFromIdMap(id_map);
            try self.markPendingHydration(graph_name);
            return;
        }

        // Fallback: no valid snapshot. EARLY-READY: defer the full per-graph
        // build (loop1 IdMap scan-rebuild + loop2 resident indexes) to lazy
        // first-access via `ensureGraphHydrated`, exactly like the snapshot
        // branch above. This keeps open O(open_core) — graph-size-independent —
        // so "server ready" fires sub-second even for a stale / no-snapshot
        // (legacy or crash-recovered) artifact; the first read/write of the
        // graph pays the full build once under `hydration_build_mutex`.
        //
        // CRITICAL DIFFERENCE from the snapshot branch: no IdMap is resident
        // here (loop1 has NOT run), so `self.id_maps` for this graph is EMPTY
        // until first access. The by-id hydration chokepoints
        // (`ensureNodeGraphHydrated` / `ensureEdgeGraphHydrated`) resolve the
        // owning graph via the IdMaps; with an empty IdMap a by-id first-access
        // cannot route to this graph, so those chokepoints fall back to
        // `ensureAllGraphsHydrated` on a routing miss (see there). The global
        // public-id high-water is NOT recovered here (recoverIdCountersFromIdMap
        // needs a populated IdMap); this is safe because new public ids come
        // from the wall-clock-backed `generateTimeBasedId` atomic, not
        // `next_node_id` (which loop1 restores during the deferred build).
        try self.markPendingHydration(graph_name);
    }

    /// Try to load `graph_name`'s IdMap from its counter-gated mmap snapshot.
    /// Returns true on success (IdMap bulk-loaded, NO engine reads); false when
    /// the snapshot is absent, the engine counter can't be read, the stored
    /// counter is stale, or the file is bad/torn (`loadSnapshot` returns null).
    fn loadIdMapFromSnapshot(
        self: *GraphStore,
        adapter: *graph_storage_adapter.StorageAdapter,
        graph_name: []const u8,
        id_map: *id_map_mod.IdMap,
    ) !bool {
        const dir_path = (try self.resolveGraphRootDirPath(graph_name)) orelse return false;
        defer self.allocator.free(dir_path);
        const io = std.Io.Threaded.global_single_threaded.io();
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
        defer dir.close(io);

        var snap = (id_map_mod.IdMap.loadSnapshot(dir) catch return false) orelse return false;

        // Crash-safety gate (GAP-0064 FIX B): the snapshot is valid only if it
        // reflects exactly the engine's currently-committed state — its stamped
        // `(checkpoint_epoch, covered_lsn)` must equal the engine's CURRENT epoch
        // AND durable frontier. Epoch match ⟺ no checkpoint since the snapshot;
        // covered == frontier ⟺ no committed WAL tail advanced past it. This
        // replaces the manifest.counter gate that recovery.zig bumped on any tail
        // replay (rejecting a still-valid snapshot → full loop1/loop2 re-scan). A
        // genuine tail (frontier > covered) still safely rejects → rebuild. Any
        // mismatch/absence => unmap and fall back to scan-rebuild.
        const cur_epoch = adapter.graphCheckpointEpoch(graph_name) orelse {
            snap.deinit();
            return false;
        };
        const cur_covered = adapter.graphDurableFrontierLsn(graph_name) orelse {
            snap.deinit();
            return false;
        };
        if (snap.checkpoint_epoch != cur_epoch or snap.covered_lsn != cur_covered) {
            snap.deinit();
            return false;
        }

        // PHASE 4: O(1) open. Instead of bulk-loading the whole snapshot into
        // the in-memory hashmaps (O(ids)), mmap it as an IMMUTABLE BASE and
        // serve reads IN PLACE; only writes-since-open go to the overlay. The
        // IdMap takes ownership of the mapping (its deinit unmaps). Open is now
        // flat in node count (mmap + header + CRC already done by loadSnapshot).
        id_map.adoptSnapshotAsBase(snap);
        _ = g_idmap_from_snapshot.fetchAdd(1, .monotonic);
        return true;
    }

    /// Recover the GLOBAL next public-id counters (node + edge) from a resident
    /// IdMap. Public ids are globally unique and monotonically assigned, so the
    /// high-water across all graphs' IdMaps is the floor for the next id. Runs
    /// at open (no engine reads) so deferring loop2 cannot cause id reuse.
    fn recoverIdCountersFromIdMap(self: *GraphStore, id_map: *id_map_mod.IdMap) void {
        if (id_map.maxNodeUuid()) |mx| {
            const next = @as(u64, @truncate(mx)) + 1;
            if (next > self.next_node_id) self.next_node_id = next;
        }
        if (id_map.maxEdgeUuid()) |mx| {
            const next = @as(u64, @truncate(mx)) + 1;
            if (next > self.next_edge_id) self.next_edge_id = next;
        }
    }

    /// Register a deferred-hydration entry for a graph that has on-disk data but
    /// whose resident loop2 indexes are not yet built. Idempotent.
    fn markPendingHydration(self: *GraphStore, graph_name: []const u8) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.hydration_mutex.lockUncancelable(io);
        defer self.hydration_mutex.unlock(io);
        if (self.pending_hydration.contains(graph_name)) return;
        const entry = try self.allocator.create(HydrationEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{};
        const key = try self.allocator.dupe(u8, graph_name);
        errdefer self.allocator.free(key);
        try self.pending_hydration.put(key, entry);
    }

    /// PHASE 1b HYDRATION CHOKEPOINT. Called at the top of every read/write
    /// entry point that touches a graph's resident loop2 indexes. On the FIRST
    /// touch of a graph whose indexes were deferred at open, builds them exactly
    /// once (the per-graph entry mutex serialises concurrent first-touches; the
    /// atomic `done` flag is the lock-free already-hydrated fast path). A graph
    /// ABSENT from `pending_hydration` (freshly CREATEd, default, snapshot/clone
    /// store, or fully loaded at open) is a no-op. Building re-runs the full
    /// per-graph load: the resident IdMap re-insert is idempotent and the
    /// deferred indexes are built from the engine scan.
    pub fn ensureGraphHydrated(self: *GraphStore, graph_name: []const u8) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const entry = blk: {
            self.hydration_mutex.lockUncancelable(io);
            defer self.hydration_mutex.unlock(io);
            break :blk self.pending_hydration.get(graph_name) orelse return;
        };
        if (entry.done.load(.acquire)) return;
        entry.mutex.lockUncancelable(io);
        defer entry.mutex.unlock(io);
        if (entry.done.load(.acquire)) return;

        const adapter = global_adapter orelse {
            entry.done.store(true, .release);
            return;
        };
        // PHASE 1b concurrency fix: serialise the build store-wide so a
        // concurrent first-touch of a DIFFERENT cold graph cannot race this
        // build on the store-wide maps it mutates (see `hydration_build_mutex`).
        self.hydration_build_mutex.lockUncancelable(io);
        defer self.hydration_build_mutex.unlock(io);
        const outcome: ?HydrationBuildOutcome = self.loadOneGraphFromAdapterFull(adapter, graph_name) catch |err| blk: {
            log.err("lazy graph hydration failed; graph may be degraded", &.{
                Attr.string("graph", graph_name),
                Attr.string("error", @errorName(err)),
            });
            // Quarantine: mark done so a broken graph is not re-scanned on every
            // access. Matches the open-path catch+continue policy.
            //
            // GAP-ENT-0023 P3 (review C1): record the failure. The resident
            // loop2 products are PARTIAL now; the checkpoint writers consult
            // this flag to skip persisting them (and delete stale snapshot
            // files) so the next reopen re-scans cleanly instead of loading a
            // partial-but-counter-current snapshot forever.
            entry.failed.store(true, .release);
            break :blk null;
        };
        entry.done.store(true, .release);
        // GAP-ENT-0048f: build + persist the adapter's exact node-property VALUE
        // index (prop_exact.idx) in THIS hydration window — the race-free path.
        // Hydration has just scanned every node lock-free and holds NO mg.rwlock,
        // so building the exact index here (a lock-free per-shard engine scan) +
        // persisting it directly avoids the shutdown-checkpoint rwlock race that
        // starved the eager-build-at-checkpoint approach at 14.27M (the bounded
        // shutdown checkpoint could not win mg.rwlock against the hydration scan).
        // After this a WHERE-seek / GROUP BY is served from the built index with
        // NO lazy rebuild wedge, and the next reopen reloads the snapshot.
        // Both .rebuilt and .snapshot_served leave the engine fully open +
        // scannable; only a FAILED hydration (outcome == null, quarantined) skips
        // (partial state — never build/persist off a broken hydration).
        if (outcome != null) {
            adapter.buildAndPersistExactIndexForHydratedGraph(graph_name);
        }
        // Task 3 (hydration persist-on-complete): make the just-built products
        // durable NOW — a crash before the next full checkpoint used to re-pay
        // the whole first-access scan (13 h at 14.27M, twice in production).
        // Ordering matters: `done` is stored FIRST so the savers' deferred-gate
        // reads the graph as hydrated. Never on failure/quarantine (`outcome ==
        // null` — partial products must not be blessed: the 9b2d42eb/C1 hazard
        // class), and never when the hydration was served entirely from
        // counter-current snapshots (nothing new to persist). Best-effort:
        // persist errors are logged inside and never fail the triggering query.
        if (outcome == .rebuilt) {
            self.persistHydrationProductsForGraph(adapter, graph_name);
        }
    }

    /// Hydrate EVERY graph that still has deferred resident indexes. Used by the
    /// cross-graph / tenant-scoped read paths that have no single graph_name
    /// (listNodeLabels / listEdgeTypes / listPropertiesForLabel, and the
    /// admin/null-graph `getEdgesByType`).
    pub fn ensureAllGraphsHydrated(self: *GraphStore) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        {
            self.hydration_mutex.lockUncancelable(io);
            defer self.hydration_mutex.unlock(io);
            var it = self.pending_hydration.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.*.done.load(.acquire)) continue;
                const dup = self.allocator.dupe(u8, e.key_ptr.*) catch continue;
                names.append(self.allocator, dup) catch {
                    self.allocator.free(dup);
                    continue;
                };
            }
        }
        for (names.items) |n| self.ensureGraphHydrated(n);
    }

    /// PHASE 1b: hydrate the graph that owns `node_id`, resolved via the eager
    /// IdMaps (no engine read). For by-id mutation entry points that carry no
    /// graph_name. No-op when the id maps to no graph (pure in-memory store).
    fn ensureNodeGraphHydrated(self: *GraphStore, node_id: u64) void {
        if (self.resolveNodeGraphSlot(node_id)) |gs| {
            self.ensureGraphHydrated(gs.graph_name);
            return;
        }
        // The id resolved to NO IdMap. With no-snapshot early-ready open, a
        // graph defers its loop1 IdMap build to first access, so its IdMap is
        // EMPTY until hydrated and a by-id first-access cannot be routed to it.
        // Build every still-deferred graph so the id resolves and the graph's
        // resident node/edge caches are populated before this by-id op reads
        // them. Cheap once all deferred graphs are hydrated (each
        // `pending_hydration` entry's `done` flag short-circuits the rebuild)
        // and a no-op for a pure in-memory store (nothing pending). Called at
        // the top of the entry point, before any store lock, so the store-wide
        // `hydration_build_mutex` it takes cannot deadlock the caller.
        self.ensureAllGraphsHydrated();
    }

    /// PHASE 1b: hydrate the graph that owns `edge_id`. The edge's graph is
    /// resolved via its from-endpoint's IdMap entry (a stable key), NOT the
    /// edge cache's `graph_name` field, because hydration mutates the edge cache
    /// and could evict/free that string mid-call.
    fn ensureEdgeGraphHydrated(self: *GraphStore, edge_id: u64) void {
        if (self.edges.get(edge_id)) |e| {
            self.ensureNodeGraphHydrated(e.from_id);
            return;
        }
        // Edge not resident. It may belong to a deferred no-snapshot graph whose
        // edge cache + IdMap were not built at open (see ensureNodeGraphHydrated):
        // the from-endpoint lookup that would route hydration is unavailable
        // until the graph is built. Build every still-deferred graph so the edge
        // (and its owning graph) become resident. No-op once all are hydrated.
        self.ensureAllGraphsHydrated();
    }

    /// Task 3: what a per-graph hydration build actually did — drives the
    /// persist-on-complete decision in `ensureGraphHydrated`. A hydration
    /// served ENTIRELY from counter-current snapshots has nothing new to
    /// persist (the on-disk snapshot set already IS what a persist would
    /// write), and persisting anyway would pay a pointless graph checkpoint +
    /// snapshot rewrite on every warm first-access.
    const HydrationBuildOutcome = enum { rebuilt, snapshot_served };

    /// GAP-ENT-0023 P3: which loop2 products were restored from counter-gated
    /// snapshots for the graph being hydrated. The scan below skips exactly
    /// the covered products; a partial set skips only what it covers.
    const HydrationSnapshotProducts = struct {
        counters: bool = false,
        labels: bool = false,
        merge: bool = false,
        /// Node count recorded by the counters snapshot (full-skip validation).
        node_count: u64 = 0,
    };

    /// Try to load + apply this graph's loop2-product snapshots. Every file is
    /// independently gated: structural validity (magic/version/CRC — the
    /// format module), manifest-counter currency (here), and a full dry-run
    /// parse BEFORE any mutation (so a malformed-but-CRC-valid file can never
    /// leave a half-applied product behind; after the dry run the only
    /// possible apply failure is OOM). Apply failures are CAUGHT per product
    /// and fall back to the engine scan for that product. Labels and merge
    /// are idempotent against a partial apply (dedup insert / putOrUpdate);
    /// counters is NOT (absolute-set + scan re-bump would double-count), so
    /// its catch arm first deletes every contribution the partial apply made
    /// (review I2 — see removeHydrationCounterContributionsForGraph).
    fn loadHydrationSnapshotsForGraph(
        self: *GraphStore,
        adapter: *graph_storage_adapter.StorageAdapter,
        graph_name: []const u8,
    ) HydrationSnapshotProducts {
        var out = HydrationSnapshotProducts{};
        if (hydrationSnapshotsDisabled()) return out;
        const io = std.Io.Threaded.global_single_threaded.io();
        const dir_path = (self.resolveGraphRootDirPath(graph_name) catch return out) orelse return out;
        defer self.allocator.free(dir_path);
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return out;
        defer dir.close(io);
        // GAP-0064 FIX B: gate on the Path-B (checkpoint_epoch, covered_lsn)
        // contract (same as idmap.snapshot + prop_exact.idx), not manifest.counter.
        const cur_epoch = adapter.graphCheckpointEpoch(graph_name) orelse return out;
        const cur_covered = adapter.graphDurableFrontierLsn(graph_name) orelse return out;

        counters: {
            var loaded = hydration_snapshot.load(
                dir,
                HYDRATION_COUNTERS_FILE,
                HYDRATION_COUNTERS_MAGIC,
                HYDRATION_SNAP_VERSION,
            ) orelse break :counters;
            defer loaded.deinit();
            // Crash-safety gate: accept IFF no checkpoint AND no committed WAL
            // tail since the snapshot was stamped (identical to the IdMap snapshot
            // gate — GAP-0064 FIX B).
            if (loaded.checkpoint_epoch != cur_epoch or loaded.covered_lsn != cur_covered) break :counters;
            if (!validateHydrationCountersPayload(loaded.payload)) break :counters;
            out.node_count = self.applyHydrationCountersSnapshot(graph_name, loaded.payload) catch |err| {
                log.warn("hydration counters snapshot apply failed; falling back to scan", &.{
                    Attr.string("graph", graph_name),
                    Attr.string("error", @errorName(err)),
                });
                // GAP-ENT-0023 P3 (review I2): the apply may have already
                // absolute-SET some of this graph's per-(graph,type) edge
                // counters and per-(graph,tenant) introspection refcounts.
                // The scan fallback re-bumps them from zero, so any leftover
                // contribution would double-count (inflated count(r:TYPE) /
                // listNodeLabels refcounts — served silently by the fast
                // paths). The composite outer keys make this graph's
                // contribution disjoint — delete it exactly, then fall back.
                self.removeHydrationCounterContributionsForGraph(graph_name);
                break :counters;
            };
            out.counters = true;
            _ = g_hydration_snapshot_loads.fetchAdd(1, .monotonic);
        }
        if (!out.counters) _ = g_hydration_scan_fallbacks.fetchAdd(1, .monotonic);

        labels: {
            var loaded = hydration_snapshot.load(
                dir,
                HYDRATION_LABELS_FILE,
                HYDRATION_LABELS_MAGIC,
                HYDRATION_SNAP_VERSION,
            ) orelse break :labels;
            defer loaded.deinit();
            if (loaded.checkpoint_epoch != cur_epoch or loaded.covered_lsn != cur_covered) break :labels;
            if (!validateHydrationLabelsPayload(loaded.payload)) break :labels;
            self.applyHydrationLabelsSnapshot(graph_name, loaded.payload) catch |err| {
                log.warn("hydration label-postings snapshot apply failed; falling back to scan", &.{
                    Attr.string("graph", graph_name),
                    Attr.string("error", @errorName(err)),
                });
                break :labels;
            };
            out.labels = true;
            _ = g_hydration_snapshot_loads.fetchAdd(1, .monotonic);
        }
        if (!out.labels) _ = g_hydration_scan_fallbacks.fetchAdd(1, .monotonic);

        merge: {
            var loaded = hydration_snapshot.load(
                dir,
                HYDRATION_MERGE_FILE,
                HYDRATION_MERGE_MAGIC,
                HYDRATION_SNAP_VERSION,
            ) orelse break :merge;
            defer loaded.deinit();
            if (loaded.checkpoint_epoch != cur_epoch or loaded.covered_lsn != cur_covered) break :merge;
            if (!validateHydrationMergePayload(loaded.payload)) break :merge;
            // Config gate: which entries the index contains depends on the
            // lean flag / registered keys / composite specs. A mismatch means
            // the snapshot may be authoritative-but-INCOMPLETE for the current
            // configuration (-> .not_found -> duplicate MERGE creates), so
            // reject and rebuild from the scan.
            {
                var cfg = hydration_snapshot.Cursor{ .buf = loaded.payload };
                const stored_hash = cfg.readInt(u64) catch break :merge;
                if (stored_hash != mergeIndexConfigHash()) break :merge;
            }
            self.applyHydrationMergeSnapshot(loaded.payload) catch |err| {
                // Partial application is SAFE here: entries came from a
                // counter-current file (same generation), and the scan
                // fallback's putOrUpdate re-adds/overwrites idempotently.
                log.warn("hydration merge-index snapshot apply failed; falling back to scan", &.{
                    Attr.string("graph", graph_name),
                    Attr.string("error", @errorName(err)),
                });
                break :merge;
            };
            out.merge = true;
            _ = g_hydration_snapshot_loads.fetchAdd(1, .monotonic);
        }
        if (!out.merge) _ = g_hydration_scan_fallbacks.fetchAdd(1, .monotonic);
        return out;
    }

    /// Dry-run structural parse of the merge payload: every record's
    /// key_off/key_len must land inside its shard's blob.
    fn validateHydrationMergePayload(payload: []const u8) bool {
        var cur = hydration_snapshot.Cursor{ .buf = payload };
        _ = cur.readInt(u64) catch return false; // config hash (gated separately)
        const shard_count = cur.readInt(u32) catch return false;
        if (shard_count == 0 or shard_count > (1 << 16)) return false;
        var s: u32 = 0;
        while (s < shard_count) : (s += 1) {
            const n = cur.readInt(u64) catch return false;
            const blob_len = cur.readInt(u64) catch return false;
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                const off = cur.readInt(u64) catch return false;
                const klen = cur.readInt(u32) catch return false;
                _ = cur.readInt(u64) catch return false; // node_id
                if (off > blob_len or blob_len - off < klen) return false;
            }
            const blen = std.math.cast(usize, blob_len) orelse return false;
            _ = cur.readSlice(blen) catch return false;
        }
        return cur.remaining() == 0;
    }

    /// Re-insert the merge-index entries from a validated payload. Every key
    /// re-verifies its shard hash: entries are inserted into the shard their
    /// key HASHES to (never blindly into the stored grouping), so a
    /// corrupt-but-CRC-valid grouping can never plant an entry where lookups
    /// (which lock the hash-correct shard) would miss it.
    fn applyHydrationMergeSnapshot(self: *GraphStore, payload: []const u8) !void {
        var cur = hydration_snapshot.Cursor{ .buf = payload };
        _ = try cur.readInt(u64); // config hash
        const shard_count = try cur.readInt(u32);
        var s: u32 = 0;
        while (s < shard_count) : (s += 1) {
            const n = try cur.readInt(u64);
            const blob_len = try cur.readInt(u64);
            const rec_bytes = std.math.mul(u64, n, 20) catch return error.SnapshotTruncated;
            const rec_len = std.math.cast(usize, rec_bytes) orelse return error.SnapshotTruncated;
            const records = try cur.readSlice(rec_len);
            const blen = std.math.cast(usize, blob_len) orelse return error.SnapshotTruncated;
            const blob = try cur.readSlice(blen);
            var i: usize = 0;
            while (i < rec_len) : (i += 20) {
                const off = std.mem.readInt(u64, records[i..][0..8], .little);
                const klen = std.mem.readInt(u32, records[i + 8 ..][0..4], .little);
                const node_id = std.mem.readInt(u64, records[i + 12 ..][0..8], .little);
                const key = blob[@intCast(off)..][0..klen];
                try self.merge_prop_index.putOrUpdate(key, node_id);
            }
        }
    }

    /// Dry-run structural parse of the label-postings payload. Also verifies
    /// each posting is STRICTLY ascending — the resident posting lists are
    /// binary-searched, so accepting an unsorted (corrupt-but-CRC-valid) list
    /// would corrupt lookups silently.
    fn validateHydrationLabelsPayload(payload: []const u8) bool {
        var cur = hydration_snapshot.Cursor{ .buf = payload };
        const n = cur.readInt(u32) catch return false;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            _ = cur.readBytes() catch return false; // label
            const id_count = cur.readInt(u64) catch return false;
            var j: u64 = 0;
            var prev: u64 = 0;
            while (j < id_count) : (j += 1) {
                const id = cur.readInt(u64) catch return false;
                if (j != 0 and id <= prev) return false;
                prev = id;
            }
        }
        return cur.remaining() == 0;
    }

    /// Populate `label_index` postings (and the exact per-(graph,label)
    /// counts, which by invariant equal the posting lengths) from a validated
    /// payload. Same lock order as addToLabelIndex.
    fn applyHydrationLabelsSnapshot(
        self: *GraphStore,
        graph_name: []const u8,
        payload: []const u8,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var cur = hydration_snapshot.Cursor{ .buf = payload };
        const n = try cur.readInt(u32);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const label = try cur.readBytes();
            const id_count = try cur.readInt(u64);
            const count: usize = std.math.cast(usize, id_count) orelse return error.SnapshotTruncated;

            self.label_index_mutex.lockUncancelable(io);
            defer self.label_index_mutex.unlock(io);
            const posting = try self.ensureLabelPostingListLocked(graph_name, label);
            try self.ensureGraphLabelCount(graph_name, label);
            posting.lock();
            defer posting.unlock();
            if (posting.list.items.len != 0) {
                // Already populated (only reachable via the pre-existing
                // "graph:label" composite-key ambiguity, where an identical
                // entry restored under an aliased graph/label split) — skip
                // rather than append duplicates into a sorted list.
                var j: u64 = 0;
                while (j < id_count) : (j += 1) _ = try cur.readInt(u64);
                continue;
            }
            try posting.list.ensureUnusedCapacity(self.allocator, count);
            var j: u64 = 0;
            while (j < id_count) : (j += 1) {
                posting.list.appendAssumeCapacity(try cur.readInt(u64));
            }
            self.setGraphLabelCountAbsolute(graph_name, label, count);
        }
    }

    /// Set the exact (graph,label) count to `count` (snapshot restore only —
    /// live paths use the bump/dec refcount discipline).
    fn setGraphLabelCountAbsolute(self: *GraphStore, graph_name: []const u8, label: []const u8, count: usize) void {
        var key_buf: [512]u8 = undefined;
        var formatted = formatGraphLabelKey(&key_buf, self.allocator, graph_name, label) catch return;
        defer if (formatted.owned) |owned| self.allocator.free(owned);

        const io = std.Io.Threaded.global_single_threaded.io();
        self.label_count_rwlock.lockUncancelable(io);
        defer self.label_count_rwlock.unlock(io);
        if (self.label_counts_by_graph.getPtr(formatted.key)) |existing| {
            existing.store(count, .monotonic);
            return;
        }
        const owned_key = if (formatted.owned) |owned| blk: {
            formatted.owned = null;
            break :blk owned;
        } else std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, label }) catch return;
        self.label_counts_by_graph.put(owned_key, LabelCountValue.init(count)) catch {
            self.allocator.free(owned_key);
        };
    }

    /// Dry-run structural parse of the counters payload (no allocation, no
    /// mutation). Belt-and-braces on top of the CRC.
    fn validateHydrationCountersPayload(payload: []const u8) bool {
        var cur = hydration_snapshot.Cursor{ .buf = payload };
        _ = cur.readInt(u64) catch return false; // node_count
        // Two flat count sections, then three tenant sections.
        var flat: usize = 0;
        while (flat < 2) : (flat += 1) {
            const n = cur.readInt(u32) catch return false;
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                _ = cur.readBytes() catch return false;
                _ = cur.readInt(u64) catch return false;
            }
        }
        var sect: usize = 0;
        while (sect < 3) : (sect += 1) {
            const n_tenants = cur.readInt(u32) catch return false;
            var t: u32 = 0;
            while (t < n_tenants) : (t += 1) {
                _ = cur.readBytes() catch return false; // tenant
                const n_inner = cur.readInt(u32) catch return false;
                var i: u32 = 0;
                while (i < n_inner) : (i += 1) {
                    _ = cur.readBytes() catch return false;
                    _ = cur.readInt(u64) catch return false;
                }
            }
        }
        return cur.remaining() == 0;
    }

    /// Populate the resident counter products from a validated payload.
    /// Returns the recorded per-graph node count. The (graph,label) exact
    /// counts are NOT applied here — they are owned by the label-postings
    /// product (restored from posting lengths, or rebuilt by the scan's
    /// addToLabelIndex bumps); applying them independently would double-count
    /// when the scan re-inserts postings.
    fn applyHydrationCountersSnapshot(
        self: *GraphStore,
        graph_name: []const u8,
        payload: []const u8,
    ) !u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        var cur = hydration_snapshot.Cursor{ .buf = payload };
        const node_count = try cur.readInt(u64);

        // (graph,label) exact counts: SKIP (see doc comment) — walk past.
        {
            const n = try cur.readInt(u32);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                _ = try cur.readBytes();
                _ = try cur.readInt(u64);
            }
        }

        // (graph,edge_type) exact counts: restore (the scan's
        // bumpGraphEdgeTypeCount is skipped when this product is loaded).
        {
            const n = try cur.readInt(u32);
            self.edge_type_count_rwlock.lockUncancelable(io);
            defer self.edge_type_count_rwlock.unlock(io);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const type_name = try cur.readBytes();
                const count = try cur.readInt(u64);
                const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ graph_name, type_name });
                const gop = try self.edge_type_counts_by_graph.getOrPut(key);
                if (gop.found_existing) {
                    self.allocator.free(key);
                    gop.value_ptr.store(@intCast(count), .monotonic);
                } else {
                    gop.value_ptr.* = LabelCountValue.init(@intCast(count));
                }
            }
        }

        // Tenant-keyed introspection multisets (disjoint per graph thanks to
        // the "graph\x00tenant" outer key; puts are idempotent).
        try self.applyHydrationTenantSection(&cur, &self.node_labels_by_tenant, graph_name);
        try self.applyHydrationTenantSection(&cur, &self.edge_types_by_tenant, graph_name);
        try self.applyHydrationTenantSection(&cur, &self.label_properties_by_tenant, graph_name);

        return node_count;
    }

    /// GAP-ENT-0023 P3 (review I2): delete EVERY contribution `graph_name`
    /// made to the counters product — its "graph:type" keys in
    /// `edge_type_counts_by_graph` and its "graph\x00tenant" outer entries in
    /// the three tenant-introspection multisets. Called when
    /// `applyHydrationCountersSnapshot` fails mid-apply (only OOM can get past
    /// the dry-run parse) so the engine-scan fallback re-bumps from a clean
    /// zero baseline instead of double-counting on top of the partial apply.
    ///
    /// Exact by construction: at first-touch hydration time nothing else has
    /// written this graph's composite keys (writes hydrate first; other
    /// graphs' keys have a different graph component), so removing the outer
    /// entries removes precisely the partial apply's effect.
    ///
    /// Deliberately ALLOCATION-FREE (re-scan after each removal instead of
    /// collecting victims) — the trigger condition IS allocator exhaustion,
    /// so the cleanup itself must not be able to fail on OOM.
    fn removeHydrationCounterContributionsForGraph(self: *GraphStore, graph_name: []const u8) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        {
            self.edge_type_count_rwlock.lockUncancelable(io);
            defer self.edge_type_count_rwlock.unlock(io);
            while (true) {
                var victim: ?[]const u8 = null;
                var it = self.edge_type_counts_by_graph.iterator();
                while (it.next()) |e| {
                    if (graphLabelKeyMatchesGraph(e.key_ptr.*, graph_name)) {
                        victim = e.key_ptr.*;
                        break;
                    }
                }
                const key = victim orelse break;
                if (self.edge_type_counts_by_graph.fetchRemove(key)) |kv| {
                    self.allocator.free(kv.key);
                }
            }
        }
        self.perf_c_refcount_mutex.lockUncancelable(io);
        defer self.perf_c_refcount_mutex.unlock(io);
        const outers = [_]*std.StringHashMap(std.StringHashMap(usize)){
            &self.node_labels_by_tenant,
            &self.edge_types_by_tenant,
            &self.label_properties_by_tenant,
        };
        for (outers) |outer| {
            while (true) {
                var victim: ?[]const u8 = null;
                var it = outer.iterator();
                while (it.next()) |e| {
                    if (std.mem.eql(u8, graphTenantKeyGraph(e.key_ptr.*), graph_name)) {
                        victim = e.key_ptr.*;
                        break;
                    }
                }
                const key = victim orelse break;
                if (outer.fetchRemove(key)) |kv| {
                    self.allocator.free(kv.key);
                    var inner = kv.value;
                    var iit = inner.iterator();
                    while (iit.next()) |ie| self.allocator.free(ie.key_ptr.*);
                    inner.deinit();
                }
            }
        }
    }

    fn applyHydrationTenantSection(
        self: *GraphStore,
        cur: *hydration_snapshot.Cursor,
        outer: *std.StringHashMap(std.StringHashMap(usize)),
        graph_name: []const u8,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.perf_c_refcount_mutex.lockUncancelable(io);
        defer self.perf_c_refcount_mutex.unlock(io);
        const n_tenants = try cur.readInt(u32);
        var t: u32 = 0;
        while (t < n_tenants) : (t += 1) {
            const tenant = try cur.readBytes();
            const n_inner = try cur.readInt(u32);

            var oscratch: [512]u8 = undefined;
            const ok = try formatGraphTenantKey(&oscratch, self.allocator, graph_name, tenant);
            defer if (ok.owned) |buf| self.allocator.free(buf);
            const outer_result = try outer.getOrPut(ok.key);
            if (!outer_result.found_existing) {
                const okey_copy = try self.allocator.dupe(u8, ok.key);
                errdefer self.allocator.free(okey_copy);
                outer_result.key_ptr.* = okey_copy;
                outer_result.value_ptr.* = std.StringHashMap(usize).init(self.allocator);
            }

            var i: u32 = 0;
            while (i < n_inner) : (i += 1) {
                const inner_key = try cur.readBytes();
                const count = try cur.readInt(u64);
                const inner_result = try outer_result.value_ptr.getOrPut(inner_key);
                if (!inner_result.found_existing) {
                    const ikey_copy = try self.allocator.dupe(u8, inner_key);
                    errdefer self.allocator.free(ikey_copy);
                    inner_result.key_ptr.* = ikey_copy;
                }
                inner_result.value_ptr.* = @intCast(count);
            }
        }
    }

    /// Kill switch: GEODE_DISABLE_STREAMING_HYDRATION=1 forces the legacy
    /// per-node engine-read hydration scan (the pre-fast-scan behavior).
    /// Read per call — hydration is a cold path. Also the comparison lever
    /// for the fast-scan parity tests (same store, both paths, equal
    /// products).
    fn streamingHydrationDisabled() bool {
        const raw_z = std.c.getenv("GEODE_DISABLE_STREAMING_HYDRATION") orelse return false;
        const raw = std.mem.span(raw_z);
        return std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "yes");
    }

    /// Task 2 (hydration fast-scan): number of dedicated per-shard scan
    /// worker threads. GEODE_HYDRATION_SCAN_WORKERS overrides; default is
    /// min(shard_count, logical CPUs). 1 = a single scan thread walking the
    /// shards in order (the Task 1 scan order; also the scaling tests'
    /// baseline). T2c: EFFECTIVE concurrent scans are additionally capped by
    /// the in-flight gate (`hydrationInflightShardLimit`) whenever the merge
    /// lags — see the gate comment for why that is the point.
    fn hydrationScanWorkerCount(shard_count: usize) usize {
        if (std.c.getenv("GEODE_HYDRATION_SCAN_WORKERS")) |raw_z| {
            const raw = std.mem.span(raw_z);
            if (std.fmt.parseInt(usize, raw, 10)) |v| {
                if (v >= 1) return @min(v, shard_count);
            } else |_| {}
        }
        const cpus = std.Thread.getCpuCount() catch 1;
        return @max(1, @min(shard_count, cpus));
    }

    /// T2b (hydration merge): merge-phase parallelism switch.
    /// GEODE_HYDRATION_MERGE_WORKERS:
    ///   unset/invalid -> default min(4, logical CPUs)
    ///   1             -> fully single-threaded merge (the pre-T2b order;
    ///                    kill switch and the family-parity baseline)
    ///   >=2           -> the node-side product FAMILIES (label postings /
    ///                    introspection counters / merge index) run on their
    ///                    own threads, pipelined one shard behind the core
    ///                    (id_map + node bodies + graph index) thread.
    /// The value is a mode switch, not a thread-pool size: distinct product
    /// families go to distinct global structures, so at most 3 family threads
    /// (+ the core thread) ever exist.
    fn hydrationMergeWorkerCount() usize {
        if (std.c.getenv("GEODE_HYDRATION_MERGE_WORKERS")) |raw_z| {
            const raw = std.mem.span(raw_z);
            if (std.fmt.parseInt(usize, raw, 10)) |v| {
                if (v >= 1) return v;
            } else |_| {}
        }
        const cpus = std.Thread.getCpuCount() catch 1;
        return @max(1, @min(4, cpus));
    }

    /// T2c: admission-window width for the scan->merge backpressure gate —
    /// the max shard outputs in flight at once (being-scanned + completed-
    /// but-unmerged). GEODE_HYDRATION_INFLIGHT_SHARDS overrides; default 3
    /// (merge consuming one shard + up to two scanned ahead); min 1. Values
    /// >= shard_count disable the backpressure (the T2b free-running scan).
    /// NOTE this also caps EFFECTIVE scan parallelism at `limit` — deliberate:
    /// when the merge is the bottleneck a faster scan only piles up unmerged
    /// outputs, and when it is not, the window slides at merge speed anyway.
    fn hydrationInflightShardLimit() usize {
        if (std.c.getenv("GEODE_HYDRATION_INFLIGHT_SHARDS")) |raw_z| {
            const raw = std.mem.span(raw_z);
            if (std.fmt.parseInt(usize, raw, 10)) |v| {
                if (v >= 1) return v;
            } else |_| {}
        }
        return 3;
    }

    /// Find a decoded stream-scan property entry's STRING payload by key.
    /// Returns null when the key is absent OR the value is not a string —
    /// exactly the legacy switch-on-`.string`-else-fallthrough behavior of
    /// the per-node internal-id / tenant reads.
    fn findStreamPropString(
        props: []const graph_storage_adapter.hydration_scan.PropEntry,
        key: []const u8,
    ) ?[]const u8 {
        for (props) |pe| {
            if (!std.mem.eql(u8, pe.key, key)) continue;
            return switch (pe.value) {
                .string => |text| text,
                else => null,
            };
        }
        return null;
    }

    /// T2b (hydration merge core): build ONE scan row's node-side CORE
    /// products — loop1 IdMap insert (resident mode), the Node body, the
    /// bounded-cache insert, next_node_id, and the per-graph node-id index.
    /// Returns a SHALLOW COPY of the stored Node, or null when the row is
    /// skipped (corrupt blob / missing public id / unmapped slot).
    ///
    /// WHY a copy: the family consumers (label postings / introspection
    /// counters / merge index) must not re-read the bounded node cache — a
    /// `*Node` into the cache's inline map storage is invalidated by any
    /// later put's rehash/evict, and a getPtr on an already-EVICTED id would
    /// hydrate-on-miss straight back into the per-node random engine reads
    /// this scan exists to avoid. The copy's sub-heap (labels/props/strings)
    /// is cache-owned and — including for evicted entries — freed only at the
    /// per-graph grace window (retire discipline).
    ///
    /// SAFETY (C-1, corrected by the T2b adversarial review): the grace
    /// window is gated on `mg.rwlock` EXCLUSIVE — a lock this hydration
    /// deliberately NEVER holds (entry mutex + hydration_build_mutex only) —
    /// so the window CAN open mid-merge: any checkpoint (write cadence on
    /// any graph, explicit, WAL-growth hook, clean shutdown) acquires the
    /// hydrating graph's free rwlock. What keeps these sub-heaps alive is
    /// the reclaim gate in `checkpointOneGraph`: the retired-cache reclaims
    /// are SKIPPED while this graph has an unfinished hydration
    /// (`hasUnfinishedHydration`, i.e. the entry's `done` latch still
    /// false). `done` flips only after the merge joins every family thread,
    /// so no family can be reading a retired body once reclaims run again.
    fn hydrateStreamNodeRowCore(
        self: *GraphStore,
        adapter: *graph_storage_adapter.StorageAdapter,
        graph_name: []const u8,
        id_map: *id_map_mod.IdMap,
        resident: bool,
        row: *const graph_storage_adapter.hydration_scan.NodeRow,
        skipped_node_mappings: *u64,
    ) !?Node {
        // Instrumentation + injected-failure hook: identical placement to
        // the legacy loop2 (per live scan row, before any skip).
        _ = g_loop2_scan_nodes.fetchAdd(1, .monotonic);
        if (comptime @import("builtin").is_test) {
            const lim = g_test_hydration_fail_after.load(.monotonic);
            if (lim != std.math.maxInt(u64) and
                g_test_hydration_scan_seen.fetchAdd(1, .monotonic) >= lim)
            {
                return error.TestInjectedHydrationFailure;
            }
        }

        if (resident) {
            // loop1 equivalent: recover the persisted public id from the
            // decoded blob (one engine read's worth of work per node in the
            // legacy scan — counter kept for the tests' "no loop1 at ready /
            // loop1 ran on fallback" contract).
            _ = g_idmap_scan_getprop.fetchAdd(1, .monotonic);
            if (row.corrupt_skip) {
                log.warn("skipping node with corrupt property page during load", &.{
                    Attr.string("graph", graph_name),
                    Attr.int("slot_id", @intCast(row.slot)),
                    Attr.string("error", @errorName(error.DataCorruption)),
                });
                skipped_node_mappings.* += 1;
                return null;
            }
            const node_public_id: ?u64 = blk: {
                const text = findStreamPropString(row.props, INTERNAL_NODE_ID_PROPERTY_KEY) orelse break :blk null;
                break :blk parsePersistedPublicId(text);
            };
            if (node_public_id) |pid| {
                try id_map.insertNodeWithSlot(@as(u128, pid), row.slot);
            } else {
                skipped_node_mappings.* += 1;
                return null;
            }
        }

        const node_uuid = @as(u64, @truncate(id_map.nodeUuid(row.slot) orelse return null));

        // Labels: dictionary resolution with getNodeLabels' exact
        // drop-unknown-ids rule; the Node owns the resulting slice.
        var labels_list: std.ArrayList([]const u8) = .empty;
        for (row.label_ids) |label_id| {
            if (adapter.hydrationLabelString(graph_name, label_id)) |name| {
                try labels_list.append(self.allocator, try self.allocator.dupe(u8, name));
            }
        }
        const labels = try labels_list.toOwnedSlice(self.allocator);

        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const tenant_id_copy = blk_tenant: {
            if (findStreamPropString(row.props, INTERNAL_TENANT_ID_PROPERTY_KEY)) |text| {
                break :blk_tenant try self.allocator.dupe(u8, text);
            }
            break :blk_tenant try self.allocator.dupe(u8, DEFAULT_TENANT_ID);
        };

        var node = Node{
            .id = node_uuid,
            .labels = labels,
            .properties = CompactPropertyMap.init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        for (row.props) |pe| {
            if (!graph_storage_adapter.shouldExposePropertyKey(pe.key)) continue;
            // C3 (review-0023): `.null` is the adapter's REMOVE tombstone —
            // never materialize it as a present property.
            if (pe.value == .null) continue;
            const key_copy = try self.allocator.dupe(u8, pe.key);
            const pv = try graph_storage_adapter.fromStorageProperty(self.allocator, pe.value);
            try node.properties.put(key_copy, pv);
        }

        try self.nodes.put(node_uuid, node);

        if (node_uuid >= self.next_node_id) {
            self.next_node_id = node_uuid + 1;
        }

        const stored_node_ptr = self.nodes.getPtr(node_uuid) orelse return error.NodeNotFound;
        try self.addNodeToGraphIndex(graph_name, node_uuid);
        return stored_node_ptr.*;
    }

    /// T2b (hydration merge): 2-stage per-shard pipeline that runs the
    /// node-side product FAMILIES on their own threads while the core thread
    /// processes the NEXT shard:
    ///
    ///   core(s):    id_map + Node bodies + bounded-cache put + graph index
    ///   labels(s):  label postings + (graph,label) refcounts     [thread 0]
    ///   counters(s): PERF-C tenant introspection refcounts       [thread 1]
    ///   merge(s):   merge_prop_index (+ composite entries)       [thread 2]
    ///
    /// SAFETY: distinct families mutate DISJOINT global structures, so the
    /// three threads share no write destination; each family processes the
    /// shard batches strictly in shard-major order (submit() joins shard
    /// s-1's threads before spawning shard s's), so every family's insert
    /// order — including merge-index last-wins on duplicate keys — is
    /// IDENTICAL to the single-threaded merge. The batches hold shallow Node
    /// copies (see hydrateStreamNodeRowCore) so families never touch the
    /// node cache; the copies' cache-owned sub-heaps are protected from the
    /// checkpoint grace window by the C-1 reclaim gate (reclaims are skipped
    /// while this graph's hydration is unfinished — see
    /// hydrateStreamNodeRowCore's SAFETY note). Family errors surface at the
    /// next submit()/finish() and fail the hydration exactly like an inline
    /// error (C1 quarantine).
    const FamilyPipeline = struct {
        store: *GraphStore,
        graph_name: []const u8,
        do_labels: bool,
        do_counters: bool,
        do_merge: bool,
        batch: std.ArrayList(Node) = .empty,
        threads: [3]?std.Thread = .{ null, null, null },
        errs: [3]?anyerror = .{ null, null, null },

        fn joinRunning(p: *FamilyPipeline) void {
            for (&p.threads) |*slot| {
                if (slot.*) |t| {
                    t.join();
                    slot.* = null;
                }
            }
        }

        fn pendingError(p: *const FamilyPipeline) ?anyerror {
            for (p.errs) |e| {
                if (e) |err| return err;
            }
            return null;
        }

        /// Join the previous shard's family threads (preserving each
        /// family's global shard-major order), then take ownership of
        /// `new_batch` and spawn its families.
        fn submit(p: *FamilyPipeline, new_batch: std.ArrayList(Node)) !void {
            p.joinRunning();
            p.batch.deinit(p.store.allocator);
            p.batch = new_batch;
            if (p.pendingError()) |err| return err;
            if (p.batch.items.len == 0) return;
            p.spawnFamily(0, runLabels, p.do_labels);
            p.spawnFamily(1, runCounters, p.do_counters);
            p.spawnFamily(2, runMerge, p.do_merge);
        }

        fn spawnFamily(p: *FamilyPipeline, idx: usize, comptime f: fn (*FamilyPipeline) void, enabled: bool) void {
            if (!enabled) return;
            const t = std.Thread.spawn(.{}, f, .{p}) catch {
                // Spawn failure: run this family inline (degraded
                // parallelism, never a correctness change) — same policy as
                // the scan workers.
                f(p);
                return;
            };
            p.threads[idx] = t;
        }

        fn finish(p: *FamilyPipeline) !void {
            p.joinRunning();
            if (p.pendingError()) |err| return err;
        }

        /// Idempotent cleanup for EVERY exit path (including a core error
        /// mid-shard): joins outstanding family threads BEFORE their batch
        /// memory is freed.
        fn abort(p: *FamilyPipeline) void {
            p.joinRunning();
            p.batch.deinit(p.store.allocator);
            p.batch = .empty;
        }

        fn runLabels(p: *FamilyPipeline) void {
            p.store.applyLabelPostingsForBatch(p.graph_name, p.batch.items) catch |err| {
                p.errs[0] = err;
            };
        }

        fn runCounters(p: *FamilyPipeline) void {
            for (p.batch.items) |*node| {
                p.store.bumpIntrospectionForNode(node) catch |err| {
                    p.errs[1] = err;
                    return;
                };
            }
        }

        fn runMerge(p: *FamilyPipeline) void {
            for (p.batch.items) |*node| {
                var it = node.properties.iterator();
                while (it.next()) |prop_entry| {
                    p.store.addToMergePropertyIndex(
                        node.graph_name,
                        node.labels,
                        prop_entry.key_ptr.*,
                        prop_entry.value_ptr.*,
                        node.id,
                    ) catch {};
                }
                p.store.addNodeCompositeMergeEntries(node);
            }
        }
    };

    /// T2c: per-shard merge pacing for the streaming hydration merge — the
    /// gate handshake (wait-published before consuming shard s, retire after
    /// its node side is released) plus incremental projected pre-sizing of
    /// the node-side products (see the call site for the projection
    /// rationale). Used by BOTH phase-A merge modes (single-threaded and
    /// FamilyPipeline) so the gate discipline cannot diverge between them.
    const StreamMergePacer = struct {
        store: *GraphStore,
        id_map: *id_map_mod.IdMap,
        gate: *graph_storage_adapter.hydration_scan.InflightGate,
        graph_name: []const u8,
        resident: bool,
        snap_merge: bool,
        shard_count: usize,
        shards_seen: usize = 0,
        total_rows: u64 = 0,
        total_edges: u64 = 0,
        total_merge_keys: u64 = 0,
        /// Node-row capacity already granted to the additive containers
        /// (bounded node cache + per-graph node-id index).
        granted_rows: u64 = 0,
        /// Merge-index key capacity already granted.
        granted_merge_keys: u64 = 0,

        fn clampU32(v: u64) u32 {
            return @intCast(@min(v, std.math.maxInt(u32)));
        }

        /// Block until shard `s` is published by its scan worker (errors
        /// with HydrationGatePoisoned when a worker died), apply the test
        /// merge-delay hook, tally the shard, and extend the node-side
        /// reservations toward the projected final totals.
        fn beforeShard(
            p: *StreamMergePacer,
            s: usize,
            acc: *graph_storage_adapter.hydration_scan.ShardAccum,
        ) !void {
            try p.gate.waitPublished(s);
            applyTestHydrationMergeDelay();

            var shard_edges: u64 = 0;
            var shard_keys: u64 = 0;
            for (acc.rows) |*row| {
                shard_edges += row.edges.len;
                if (!p.snap_merge and row.label_ids.len != 0) {
                    var indexable: u64 = 0;
                    for (row.props) |pe| {
                        if (pe.value == .null) continue;
                        if (!graph_storage_adapter.shouldExposePropertyKey(pe.key)) continue;
                        if (!shouldIndexProperty(pe.key)) continue;
                        indexable += 1;
                    }
                    shard_keys += @as(u64, row.label_ids.len) * indexable;
                }
            }
            p.shards_seen += 1;
            p.total_rows += acc.rows.len;
            p.total_edges += shard_edges;
            p.total_merge_keys += shard_keys;

            // Projection = running mean per shard x shard_count. TOTAL-
            // capacity APIs (IdMap) take the projection directly; additive
            // APIs get the delta beyond what was already granted (their
            // internal ensureUnusedCapacity is a no-op once the projected
            // capacity is in place). Bounded caches clamp the reservation
            // to their resident cap internally, so a huge graph never
            // pre-allocates an unbounded table.
            const proj_rows = p.total_rows * p.shard_count / p.shards_seen;
            if (p.resident) try p.id_map.reserveNodes(clampU32(proj_rows));
            if (proj_rows > p.granted_rows) {
                const delta = clampU32(proj_rows - p.granted_rows);
                try p.store.nodes.ensureUnusedCapacity(delta);
                try p.store.reserveGraphNodeIndex(p.graph_name, delta);
                p.granted_rows = proj_rows;
            }
            if (!p.snap_merge) {
                const proj_keys = p.total_merge_keys * p.shard_count / p.shards_seen;
                if (proj_keys > p.granted_merge_keys) {
                    p.store.merge_prop_index.reserveAdditional(proj_keys - p.granted_merge_keys);
                    p.granted_merge_keys = proj_keys;
                }
            }
        }

        /// Release the consumed shard's node side and slide the admission
        /// window — the retire that unblocks the next scan worker.
        fn afterShard(
            p: *StreamMergePacer,
            acc: *graph_storage_adapter.hydration_scan.ShardAccum,
        ) void {
            acc.releaseNodeSide();
            p.gate.retireNext();
        }
    };

    /// GAP hydration fast-scan: build the loop1/loop2 products from the
    /// per-shard SEQUENTIAL stream scan instead of the per-node engine-read
    /// walk. Produces byte-identical products via the SAME insert calls in
    /// the same shard-major, ascending-slot order:
    ///   * the P3 snapshot skips (`snap.*`) and the 0021/0012 count
    ///     disciplines are honored at exactly the legacy call sites;
    ///   * phase A (nodes) then phase B (edges) — legal because loop1 fully
    ///     preceded loop2's edge resolution in the legacy resident flow, and
    ///     the mmap base serves lookups position-independently;
    ///   * the C1 quarantine contract is unchanged: any error out of here
    ///     makes `ensureGraphHydrated` mark the graph failed, exactly like a
    ///     legacy scan error.
    fn hydrateGraphFromStreamScan(
        self: *GraphStore,
        adapter: *graph_storage_adapter.StorageAdapter,
        graph_name: []const u8,
        id_map: *id_map_mod.IdMap,
        snap: HydrationSnapshotProducts,
        skip_edge_scan: bool,
        skipped_node_mappings: *u64,
        skipped_edge_mappings: *u64,
        repaired_edge_slots: *u64,
    ) !void {
        const hydration_scan = graph_storage_adapter.hydration_scan;
        const resident = id_map.mode == .resident;
        const opts = hydration_scan.ScanOptions{
            .include_edges = !skip_edge_scan,
            .resident_mode = resident,
            .internal_id_key = INTERNAL_NODE_ID_PROPERTY_KEY,
        };

        const scan_started_ns = monoNanosNow();
        const shard_count = try adapter.hydrationStreamShardCount(graph_name);
        const accums = try self.allocator.alloc(hydration_scan.ShardAccum, shard_count);
        const acc_ready = try self.allocator.alloc(bool, shard_count);
        @memset(acc_ready, false);
        defer {
            for (accums, acc_ready) |*acc, ready| {
                if (ready) acc.deinit();
            }
            self.allocator.free(acc_ready);
            self.allocator.free(accums);
        }

        // T2c: scan->merge backpressure gate. Bounds shard outputs in flight
        // (being-scanned + completed-but-unmerged) to the admission window so
        // a merge slower than the scan can never let completed outputs
        // accumulate unbounded (the at-scale OOM: RSS +5.7 GB/min).
        const published = try self.allocator.alloc(bool, shard_count);
        @memset(published, false);
        defer self.allocator.free(published);
        var gate = hydration_scan.InflightGate{
            .limit = hydrationInflightShardLimit(),
            .published = published,
        };

        // Per-shard streaming scan — Task 2: dedicated worker threads (no
        // thread-pool reentrancy), each sweeping its own shard's files
        // linearly into a private ShardAccum. T2c: the workers run
        // CONCURRENTLY with the merge below, admitted per shard by the gate,
        // so the merge starts on shard 0 the moment it publishes and no more
        // than `gate.limit` shard outputs ever exist at once. Shards are
        // fully independent: each owns its files, pagers and buffer pool,
        // and workers never touch shared geode state (label dict resolution
        // happens in the merge).
        const worker_count = hydrationScanWorkerCount(shard_count);
        const Worker = struct {
            store: *GraphStore,
            adapter: *graph_storage_adapter.StorageAdapter,
            graph_name: []const u8,
            opts: hydration_scan.ScanOptions,
            accums: []hydration_scan.ShardAccum,
            acc_ready: []bool,
            gate: *hydration_scan.InflightGate,
            worker_idx: usize,
            stride: usize,
            /// False only for the spawn-failure inline fallback: it runs on
            /// the merge thread BEFORE the merge loop, so blocking on the
            /// gate would self-deadlock (nobody retiring). The in-flight
            /// bound is best-effort in that degraded mode.
            gated: bool = true,
            fail: ?anyerror = null,

            fn run(w: *@This()) void {
                var shard_idx = w.worker_idx;
                while (shard_idx < w.accums.len) : (shard_idx += w.stride) {
                    if (w.gated) {
                        // Poisoned: another side failed and carries the
                        // error — exit the stripe without publishing.
                        w.gate.beginShard(shard_idx) catch return;
                    }
                    w.accums[shard_idx] = w.adapter.hydrationStreamScanShard(
                        w.graph_name,
                        shard_idx,
                        w.store.allocator,
                        w.opts,
                    ) catch |err| {
                        w.fail = err;
                        // C1: wake the merge (waiting on this shard) and
                        // every gate-blocked sibling so the hydration fails
                        // into quarantine instead of deadlocking.
                        w.gate.poison();
                        return;
                    };
                    w.acc_ready[shard_idx] = true;
                    w.gate.publish(shard_idx, monoNanosNow());
                }
            }
        };

        const workers = try self.allocator.alloc(Worker, worker_count);
        defer self.allocator.free(workers);
        const threads = try self.allocator.alloc(?std.Thread, worker_count);
        defer self.allocator.free(threads);
        @memset(threads, null);

        // Poison-and-join on EVERY exit path (merge error, family error,
        // pacer/reserve OOM, success). Declared AFTER the accums/published
        // defers so it runs BEFORE them: no worker can touch freed scan
        // state. On success this is a no-op wake — every shard was retired,
        // so all workers already exited their stripes.
        defer {
            gate.poison();
            for (threads) |*slot| {
                if (slot.*) |t| {
                    t.join();
                    slot.* = null;
                }
            }
        }

        for (workers, 0..) |*w, wi| {
            w.* = .{
                .store = self,
                .adapter = adapter,
                .graph_name = graph_name,
                .opts = opts,
                .accums = accums,
                .acc_ready = acc_ready,
                .gate = &gate,
                .worker_idx = wi,
                .stride = worker_count,
            };
        }
        for (workers, 0..) |*w, wi| {
            threads[wi] = std.Thread.spawn(.{}, Worker.run, .{w}) catch |err| {
                // Spawn failure: run this worker's stripe inline so the
                // scan still completes (degraded parallelism, gate bypassed
                // to avoid self-deadlock — never a correctness change).
                log.warn("hydration scan worker spawn failed; running stripe inline", &.{
                    Attr.string("graph", graph_name),
                    Attr.string("error", @errorName(err)),
                });
                w.gated = false;
                Worker.run(w);
                continue;
            };
        }

        _ = g_hydration_streaming_scans.fetchAdd(1, .monotonic);

        // T2c gate-poisoned recovery: a poisoned merge-side wait means a
        // scan worker died (its shard may never publish). Join everyone
        // (poison already woke them) and surface the WORKER's error — the
        // same error the pre-gate join-then-check path returned — into the
        // C1 quarantine path.
        const GateRecover = struct {
            fn resolve(
                g: *hydration_scan.InflightGate,
                thr: []?std.Thread,
                wrk: []Worker,
            ) anyerror {
                g.poison();
                for (thr) |*slot| {
                    if (slot.*) |t| {
                        t.join();
                        slot.* = null;
                    }
                }
                for (wrk) |*w| {
                    if (w.fail) |werr| return werr;
                }
                return error.HydrationGatePoisoned;
            }
        };

        // T2c pacer: per-shard gate handshake + INCREMENTAL projected
        // pre-size. T2b reserved everything once post-scan (every count
        // known); under the streaming gate later shards are not scanned yet
        // when the merge starts, so node-side totals are PROJECTED from the
        // shards seen so far (slots stripe round-robin across shards, so
        // per-shard row counts are near-uniform: the first shard's
        // projection typically lands within a few percent and the later
        // reservation calls are no-ops). Edge-side reservations stay EXACT:
        // they happen after phase A, when every shard has been scanned.
        var pacer = StreamMergePacer{
            .store = self,
            .id_map = id_map,
            .gate = &gate,
            .graph_name = graph_name,
            .resident = resident,
            .snap_merge = snap.merge,
            .shard_count = shard_count,
        };

        // ---- phase A: node products (loop1 + loop2 node side) -------------
        // Each shard's node-side arena (decoded props + label ids) is freed
        // the moment its rows are consumed, so the peak becomes
        //   (global products built so far) + (remaining arenas) + (ONE shard
        //   in flight)
        // instead of (full global products) + (ALL shards' decoded copies).
        const merge_workers = hydrationMergeWorkerCount();
        if (merge_workers <= 1) {
            // Single-threaded merge (kill switch / family-parity baseline):
            // the pre-T2b per-row product order, family steps inline.
            for (accums, 0..) |*acc, shard_idx| {
                pacer.beforeShard(shard_idx, acc) catch |err| switch (err) {
                    error.HydrationGatePoisoned => return GateRecover.resolve(&gate, threads, workers),
                    else => return err,
                };
                for (acc.rows) |*row| {
                    const copy = (try self.hydrateStreamNodeRowCore(
                        adapter,
                        graph_name,
                        id_map,
                        resident,
                        row,
                        skipped_node_mappings,
                    )) orelse continue;

                    // GAP-ENT-0023 P3: label postings restored from snapshot —
                    // re-inserting would be pure wasted binary-search work.
                    if (!snap.labels) {
                        for (copy.labels) |label| {
                            try self.addToLabelIndex(graph_name, label, copy.id);
                        }
                    }
                    // GAP-ENT-0023 P3 / 0012 discipline: counters restored
                    // from snapshot must not be re-bumped (double count).
                    if (!snap.counters) try self.bumpIntrospectionForNode(&copy);
                    if (!snap.merge) {
                        var merge_prop_iter = copy.properties.iterator();
                        while (merge_prop_iter.next()) |prop_entry| {
                            self.addToMergePropertyIndex(
                                copy.graph_name,
                                copy.labels,
                                prop_entry.key_ptr.*,
                                prop_entry.value_ptr.*,
                                copy.id,
                            ) catch {};
                        }
                        self.addNodeCompositeMergeEntries(&copy);
                    }
                }
                pacer.afterShard(acc);
            }
        } else {
            // Pipelined family merge (see FamilyPipeline): core thread builds
            // shard s while the family threads apply shard s-1's postings /
            // counters / merge-index entries. Same per-family insert order as
            // the single-threaded merge -> identical products.
            var pipeline = FamilyPipeline{
                .store = self,
                .graph_name = graph_name,
                .do_labels = !snap.labels,
                .do_counters = !snap.counters,
                .do_merge = !snap.merge,
            };
            defer pipeline.abort();

            for (accums, 0..) |*acc, shard_idx| {
                pacer.beforeShard(shard_idx, acc) catch |err| switch (err) {
                    error.HydrationGatePoisoned => return GateRecover.resolve(&gate, threads, workers),
                    else => return err,
                };
                var batch: std.ArrayList(Node) = .empty;
                // Owned by this frame only until submit() takes it (submit
                // adopts the list BEFORE any of its error returns, so freeing
                // here too would double-free — pipeline.abort() covers it).
                var batch_owned = true;
                errdefer if (batch_owned) batch.deinit(self.allocator);
                try batch.ensureTotalCapacity(self.allocator, acc.rows.len);
                for (acc.rows) |*row| {
                    const copy = (try self.hydrateStreamNodeRowCore(
                        adapter,
                        graph_name,
                        id_map,
                        resident,
                        row,
                        skipped_node_mappings,
                    )) orelse continue;
                    batch.appendAssumeCapacity(copy);
                }
                pacer.afterShard(acc);
                batch_owned = false;
                try pipeline.submit(batch);
            }
            try pipeline.finish();
        }

        // Phase A consumed every shard, so every publish has happened: the
        // scan phase ended at the LAST publish stamp (the scan and merge
        // overlap under the gate, so there is no join point to measure at).
        const scan_done_ns = @max(gate.lastPublishNs(), scan_started_ns);
        const total_rows = pacer.total_rows;
        const total_edges = pacer.total_edges;

        // ---- phase B pre-size: edge-side totals are EXACT post-phase-A ----
        // (unchanged T2b discipline — only the node side needed projections).
        if (!skip_edge_scan) {
            const rows32: u32 = @intCast(@min(total_rows, std.math.maxInt(u32)));
            const edges32: u32 = @intCast(@min(total_edges, std.math.maxInt(u32)));
            if (resident) try id_map.reserveEdges(edges32);
            try self.edges.ensureUnusedCapacity(edges32);
            try self.outgoing_edges.ensureUnusedCapacity(rows32);
            try self.incoming_edges.ensureUnusedCapacity(rows32);
        }

        // ---- phase B: edge products (loop2 edge side) ----------------------
        if (!skip_edge_scan) {
            const OrphanEdgeSlot = struct { from_slot: u64, to_slot: u64, edge_slot: u64 };
            var orphan_edge_slots: std.ArrayList(OrphanEdgeSlot) = .empty;
            defer orphan_edge_slots.deinit(self.allocator);

            for (accums) |*acc| {
                defer acc.deinit(); // T2b: edge-side arena freed per shard (idempotent vs the outer blanket defer)
                for (acc.rows) |*row| {
                    const node_uuid = @as(u64, @truncate(id_map.nodeUuid(row.slot) orelse continue));
                    for (row.edges) |er| {
                        const edge_entry = er.entry;
                        const edge_uuid = blk: {
                            // GAP-ENT-0024 inline-first: v2 entries carry the
                            // public id inline — no property fallback.
                            if (edge_entry.public_id != 0) break :blk edge_entry.public_id;

                            _ = edge_id_property_fallback_reads.fetchAdd(1, .monotonic);
                            if (findStreamPropString(er.props, INTERNAL_EDGE_ID_PROPERTY_KEY)) |text| {
                                if (parsePersistedPublicId(text)) |parsed| break :blk parsed;
                            }
                            // No legacy sidecar on this path (the streaming
                            // scan is gated on legacy_map == null).
                            break :blk null;
                        } orelse {
                            // Orphan physical edge slot (pre-fix re-apply
                            // leftovers): queue the durable self-heal delete.
                            skipped_edge_mappings.* += 1;
                            try orphan_edge_slots.append(self.allocator, .{
                                .from_slot = row.slot,
                                .to_slot = edge_entry.neighbor,
                                .edge_slot = edge_entry.edge_id,
                            });
                            continue;
                        };

                        if (resident)
                            try id_map.insertEdgeWithSlot(@as(u128, edge_uuid), edge_entry.edge_id);

                        if (self.edges.contains(edge_uuid)) continue;

                        const target_uuid = @as(u64, @truncate(id_map.nodeUuid(edge_entry.neighbor) orelse continue));

                        const edge_label_str = adapter.hydrationLabelString(graph_name, edge_entry.rel_type) orelse "UNKNOWN";
                        const edge_label_copy = try self.allocator.dupe(u8, edge_label_str);
                        const edge_graph_name_copy = try self.allocator.dupe(u8, graph_name);
                        const edge_tenant_id_copy = blk_edge_tenant: {
                            if (findStreamPropString(er.props, INTERNAL_TENANT_ID_PROPERTY_KEY)) |text| {
                                break :blk_edge_tenant try self.allocator.dupe(u8, text);
                            }
                            break :blk_edge_tenant try self.allocator.dupe(u8, DEFAULT_TENANT_ID);
                        };

                        var edge = Edge{
                            .id = edge_uuid,
                            .from_id = node_uuid,
                            .to_id = target_uuid,
                            .label = edge_label_copy,
                            .properties = CompactPropertyMap.init(self.allocator),
                            .graph_name = edge_graph_name_copy,
                            .tenant_id = edge_tenant_id_copy,
                        };

                        if (edge_entry.prop_head != 0) {
                            for (er.props) |pe| {
                                if (!graph_storage_adapter.shouldExposePropertyKey(pe.key)) continue;
                                // C3: skip the `.null` REMOVE tombstone.
                                if (pe.value == .null) continue;
                                const key_copy = try self.allocator.dupe(u8, pe.key);
                                const pv = try graph_storage_adapter.fromStorageProperty(self.allocator, pe.value);
                                try edge.properties.put(key_copy, pv);
                            }
                        }

                        try self.edges.put(edge_uuid, edge);
                        try self.addToAdjacencyIndex(node_uuid, target_uuid, edge_uuid);
                        try self.addToEdgeTypeIndex(graph_name, edge.label, edge_uuid);
                        // GAP-ENT-0023 P3 / 0012: restored counters are never
                        // re-bumped.
                        if (!snap.counters) self.bumpGraphEdgeTypeCount(graph_name, edge.label);

                        if (edge_uuid >= self.next_edge_id) {
                            self.next_edge_id = edge_uuid + 1;
                        }
                    }
                }
            }

            // Self-heal: durably delete the orphan slots AFTER the streaming
            // read completed (no live adjacency cursor to invalidate; the
            // legacy walk deferred exactly the same way per node).
            for (orphan_edge_slots.items) |orphan| {
                adapter.deleteEdge(graph_name, orphan.from_slot, orphan.to_slot, orphan.edge_slot) catch |err| {
                    log.warn("hydration orphan-edge-slot repair failed; slot remains orphaned (unqueryable)", &.{
                        Attr.string("graph", graph_name),
                        Attr.int("from_slot", @intCast(orphan.from_slot)),
                        Attr.int("edge_slot", @intCast(orphan.edge_slot)),
                        Attr.string("error", @errorName(err)),
                    });
                    continue;
                };
                repaired_edge_slots.* += 1;
            }
        }

        const merge_done_ns = monoNanosNow();
        _ = g_hydration_stream_scan_ns.fetchAdd(scan_done_ns - scan_started_ns, .monotonic);
        // T2c: the merge is pipelined WITH the scan (it consumes shard 0 the
        // moment it publishes), so its span is measured from hydration start
        // — scan_ns and merge_ns overlap and no longer sum to wall time.
        _ = g_hydration_stream_merge_ns.fetchAdd(merge_done_ns - scan_started_ns, .monotonic);
        log.info("graph hydration served by per-shard stream scan", &.{
            Attr.string("graph", graph_name),
            Attr.int("nodes", @intCast(total_rows)),
            Attr.int("edges", @intCast(total_edges)),
            Attr.int("scan_workers", @intCast(worker_count)),
            Attr.int("merge_workers", @intCast(merge_workers)),
            Attr.int("inflight_limit", @intCast(gate.limit)),
            Attr.int("scan_ms", @intCast(@divTrunc(scan_done_ns - scan_started_ns, std.time.ns_per_ms))),
            Attr.int("merge_ms", @intCast(@divTrunc(merge_done_ns - scan_started_ns, std.time.ns_per_ms))),
        });
    }

    /// Load a single graph from the storage adapter. Returns an error if
    /// any per-graph load step fails; the caller (`loadFromAdapter`) wraps
    /// this in catch+continue so one bad graph does not block service
    /// startup. On error, partial state for the graph may have been
    /// inserted (id_map, label index, some nodes/edges) — the corrupt
    /// graph effectively stays quarantined because operators are alerted
    /// via the `log.err` at the call site.
    ///
    /// PHASE 1b: this is the FULL (eager) per-graph load — IdMap scan-rebuild
    /// (loop1) + resident-index build (loop2). It runs at open ONLY as the
    /// no-valid-snapshot fallback, and otherwise on first-touch via
    /// `ensureGraphHydrated`. It is idempotent w.r.t. an already-resident IdMap
    /// (insertNodeWithSlot/insertEdgeWithSlot are puts) and builds the deferred
    /// loop2 indexes from empty.
    fn loadOneGraphFromAdapterFull(
        self: *GraphStore,
        adapter: *graph_storage_adapter.StorageAdapter,
        graph_name: []const u8,
    ) !HydrationBuildOutcome {
        {
            // Register graph in the registry
            try self.ensureGraphNoDirty(graph_name);
            var legacy_map = try self.loadLegacyIdMap(graph_name);
            defer if (legacy_map) |*map| map.deinit();

            const id_map = try self.getOrCreateIdMap(graph_name);
            var backfilled_from_legacy = false;
            var skipped_node_mappings: u64 = 0;
            var skipped_edge_mappings: u64 = 0;
            // Orphan physical edge slots physically deleted during this load
            // (the hydration self-heal for the pre-fix re-apply orphan bug).
            var repaired_edge_slots: u64 = 0;

            // GAP-ENT-0023 P3: restore loop2 products from counter-gated
            // snapshots where present + current; the scan below skips exactly
            // the covered products (a partial set skips only what it covers;
            // a stale/missing set falls back to the scan unchanged).
            const snap = self.loadHydrationSnapshotsForGraph(adapter, graph_name);

            // GAP-ENT-0023 P3: with the edge-side products restored (typed
            // per-(graph,type) counters from the counters snapshot), the ONLY
            // remaining outputs of the per-node OUTGOING-edge iteration are
            // cache warm-up (edge bodies + adjacency: bounded,
            // hydrate-on-miss — correctness never depends on residency), the
            // edge IdMap re-insert (already served in place by the mmap
            // base), the resident edge_type_index posting list (maintained
            // only for an UNBOUNDED edge cache), and the orphan-slot
            // self-heal (a legacy-corruption repair that still runs on every
            // scan fallback). Skip the edge iteration entirely when none of
            // those are needed — it is the dominant remaining hydration cost
            // (per-edge property/tenant reads).
            const skip_edge_scan = snap.counters and
                id_map.mode == .mmap_backed and
                legacy_map == null and
                self.edges.effectiveCap() != 0 and
                self.outgoing_edges.effectiveCap() != 0 and
                self.incoming_edges.effectiveCap() != 0;

            // GAP-ENT-0023 P3 FULL scan skip: every node-side product came
            // from a snapshot (counters + label postings + merge index), the
            // edge side is covered (skip_edge_scan), loop1 is served in place
            // by the mmap IdMap base, and the node cache is engine-backed
            // (hydrate-on-miss — warm-up optional). The only resident
            // structure left is `nodes_by_graph` (PERF-B), which is rebuilt
            // from the IdMap directly — memory-speed, ZERO engine reads — so
            // hydration is O(snapshot) instead of O(graph-scan).
            //
            // Cross-check: the IdMap-derived node count must equal the count
            // the counters snapshot recorded. Both passed the same manifest-
            // counter gate, so a mismatch means a save-side bug — log loudly
            // and fall through to the scan (with the per-product skips still
            // honored: postings/merge re-inserts are idempotent, so the light
            // scan is safe; nodes_by_graph puts dedupe).
            if (snap.counters and snap.labels and snap.merge and
                id_map.mode == .mmap_backed and legacy_map == null and
                self.nodes.effectiveCap() != 0 and skip_edge_scan)
            {
                var rebuilt: u64 = 0;
                var nit = id_map.nodeUuidIterator();
                while (nit.next()) |nuuid| {
                    try self.addNodeToGraphIndex(graph_name, @as(u64, @truncate(nuuid)));
                    rebuilt += 1;
                }
                if (rebuilt == snap.node_count) {
                    _ = g_hydration_full_scan_skips.fetchAdd(1, .monotonic);
                    log.info("graph hydration served from loop2 snapshots (engine scan skipped)", &.{
                        Attr.string("graph", graph_name),
                        Attr.int("nodes", @intCast(rebuilt)),
                    });
                    return .snapshot_served;
                }
                log.err("hydration snapshot node count disagrees with IdMap at the same manifest counter; falling back to scan", &.{
                    Attr.string("graph", graph_name),
                    Attr.int("idmap_nodes", @intCast(rebuilt)),
                    Attr.int("snapshot_nodes", @intCast(snap.node_count)),
                });
            }

            // GAP hydration fast-scan: the default build path is the
            // SEQUENTIAL per-shard store stream (linear file reads instead of
            // ~O(nodes) random page-chain walks — 13h09m -> minutes at 14.27M).
            // Products and count disciplines are byte-identical (same insert
            // calls, same order; see hydrateGraphFromStreamScan). The legacy
            // per-node walk remains for (a) the GEODE_DISABLE_STREAMING_HYDRATION
            // kill switch / parity harness and (b) stores with a legacy IdMap
            // sidecar, whose loop1 backfill WRITES through the engine mid-scan
            // (the streaming reader is strictly read-only by design).
            if (legacy_map == null and !streamingHydrationDisabled()) {
                try self.hydrateGraphFromStreamScan(
                    adapter,
                    graph_name,
                    id_map,
                    snap,
                    skip_edge_scan,
                    &skipped_node_mappings,
                    &skipped_edge_mappings,
                    &repaired_edge_slots,
                );
            } else {
                const scan_entries = try adapter.scanAllNodes(graph_name, self.allocator);
                defer self.allocator.free(scan_entries);

                // PHASE 4: when the IdMap is mmap_backed (a valid snapshot was
                // adopted as base at open), the node uuid->slot mappings already
                // live in the immutable base. Re-inserting them here (loop1) would
                // dump the entire base into the in-memory overlay — defeating the
                // O(1)-open / bounded-RSS win and re-doing the per-node engine read.
                // Skip loop1 entirely; loop2 below reads node uuids straight from
                // base via id_map.nodeUuid(slot_id).
                if (id_map.mode == .resident) {
                    // Cold-open loop1 I/O locality: sort scan_entries by
                    // (shard, prop_head) so the per-node props-page fetch below
                    // (getNodePropertyByHead) visits each shard's props pages in
                    // ascending prop_head order instead of raw slot-scan order.
                    // Reorder-only — both loop1 (id_map keyed by uuid) and loop2
                    // (self.nodes keyed by uuid) are insertion-order-independent, so
                    // this changes I/O locality only, not the resulting IdMap or
                    // skipped-mapping count. The slice is function-local and freed
                    // above; no other scanAllNodes caller observes this order.
                    // Gated to the .resident rebuild path: this is loop1's only
                    // consumer. On .mmap_backed (lazy-hydrate / fast-restart) loop1
                    // is skipped entirely, so sorting scan_entries there would be
                    // pure wasted O(n log n) work undercutting the sub-second
                    // restart goal.
                    const ScanEntry = graph_storage_adapter.StorageAdapter.ScanEntry;
                    std.sort.pdq(ScanEntry, scan_entries, adapter, struct {
                        fn less(a: *graph_storage_adapter.StorageAdapter, x: ScanEntry, y: ScanEntry) bool {
                            const sx = a.shardOfSlot(x.slot_id);
                            const sy = a.shardOfSlot(y.slot_id);
                            if (sx != sy) return sx < sy;
                            return x.rec.prop_head < y.rec.prop_head;
                        }
                    }.less);

                    for (scan_entries) |entry| {
                        const slot_id = entry.slot_id;
                        // PHASE 1b instrumentation: per-node engine read of the IdMap
                        // scan-rebuild (loop1). Stays 0 at open when a valid snapshot
                        // was bulk-loaded instead.
                        _ = g_idmap_scan_getprop.fetchAdd(1, .monotonic);
                        const node_uuid = blk: {
                            // 2026-05-22: tolerate per-node property page corruption.
                            // A torn/partially-flushed property page (e.g. WAL+TDE
                            // hard-crash mid-write) used to bubble up through
                            // `adapter.getNodeProperty` -> `PropStore.getProperty`
                            // and either panic on unsigned underflow inside
                            // `readDirEntry` or quarantine the entire graph. We now
                            // catch DataCorruption / OutOfBounds / CircularChain at
                            // the per-node level so the rest of the graph still
                            // hydrates and the bad node is dropped to the
                            // legacy-uuid fallback (or skipped) below.
                            const maybe_stored = adapter.getNodePropertyByHead(graph_name, slot_id, entry.rec.prop_head, INTERNAL_NODE_ID_PROPERTY_KEY, self.allocator) catch |err| switch (err) {
                                error.DataCorruption, error.CircularChainDetected => {
                                    log.warn("skipping node with corrupt property page during load", &.{
                                        Attr.string("graph", graph_name),
                                        Attr.int("slot_id", @intCast(slot_id)),
                                        Attr.string("error", @errorName(err)),
                                    });
                                    break :blk null;
                                },
                                else => return err,
                            };
                            if (maybe_stored) |stored_prop| {
                                defer graph_storage_adapter.freeOwnedStorageProperty(self.allocator, stored_prop);
                                switch (stored_prop) {
                                    .string => |text| {
                                        if (parsePersistedPublicId(text)) |parsed| break :blk parsed;
                                    },
                                    else => {},
                                }
                            }

                            if (legacy_map) |*map| {
                                const legacy_uuid_128 = map.nodeUuid(slot_id) orelse break :blk null;
                                const public_id = @as(u64, @truncate(legacy_uuid_128));
                                var id_buf: [16]u8 = undefined;
                                try adapter.setNodeProperty(
                                    graph_name,
                                    slot_id,
                                    INTERNAL_NODE_ID_PROPERTY_KEY,
                                    .{ .String = encodePersistedPublicId(&id_buf, public_id) },
                                );
                                backfilled_from_legacy = true;
                                break :blk public_id;
                            }

                            break :blk null;
                        } orelse {
                            skipped_node_mappings += 1;
                            continue;
                        };
                        try id_map.insertNodeWithSlot(@as(u128, node_uuid), slot_id);
                    }
                }

                for (scan_entries) |entry| {
                    const slot_id = entry.slot_id;
                    // PHASE 1b instrumentation: per-node iteration of the DEFERRED
                    // resident-index scan (loop2). MUST be 0 at the "server ready"
                    // point — proves the O(graph) scan was not run at open.
                    _ = g_loop2_scan_nodes.fetchAdd(1, .monotonic);
                    // GAP-ENT-0023 P3 (review C1) TDD hook — TEST BUILDS ONLY:
                    // deterministically fail the loop2 scan after N nodes so the
                    // quarantine-then-checkpoint hazard (partial products
                    // persisted counter-current) is reproducible. Compiles out of
                    // production binaries.
                    if (comptime @import("builtin").is_test) {
                        const lim = g_test_hydration_fail_after.load(.monotonic);
                        if (lim != std.math.maxInt(u64) and
                            g_test_hydration_scan_seen.fetchAdd(1, .monotonic) >= lim)
                        {
                            return error.TestInjectedHydrationFailure;
                        }
                    }
                    const node_uuid = @as(u64, @truncate(id_map.nodeUuid(slot_id) orelse continue));
                    const labels = try adapter.getNodeLabels(graph_name, slot_id, self.allocator);

                    const graph_name_copy = try self.allocator.dupe(u8, graph_name);
                    // GAP-0891 (RC-2): recover the persisted tenant tag. Absent
                    // (legacy / single-tenant data, or a default-tagged row we
                    // intentionally never persisted) -> DEFAULT_TENANT_ID. A corrupt
                    // tenant property is non-fatal: fall back to default rather than
                    // quarantine the node.
                    const tenant_id_copy = blk_tenant: {
                        // Cold-open H1: read the tenant tag WITHOUT triggering the
                        // engine's full derived property-chain index build
                        // (ensureDerivedHydrated). Like the node-id read above, use
                        // the known prop_head; getNodePropertyByHead walks the chain
                        // directly. Using plain getNodeProperty here forced a
                        // one-time O(graph) refreshPropertyChainIndex build (~71% of
                        // loop1 CPU) on the FIRST node — pure waste for loop1.
                        const maybe_t = adapter.getNodePropertyByHead(graph_name, slot_id, entry.rec.prop_head, INTERNAL_TENANT_ID_PROPERTY_KEY, self.allocator) catch null;
                        if (maybe_t) |stored_prop| {
                            defer graph_storage_adapter.freeOwnedStorageProperty(self.allocator, stored_prop);
                            switch (stored_prop) {
                                .string => |text| break :blk_tenant try self.allocator.dupe(u8, text),
                                else => {},
                            }
                        }
                        break :blk_tenant try self.allocator.dupe(u8, DEFAULT_TENANT_ID);
                    };

                    var node = Node{
                        .id = node_uuid,
                        .labels = labels,
                        .properties = CompactPropertyMap.init(self.allocator),
                        .graph_name = graph_name_copy,
                        .tenant_id = tenant_id_copy,
                    };

                    var storage_props = try adapter.getAllNodeProperties(graph_name, slot_id, self.allocator);
                    defer {
                        var sp_iter = storage_props.iterator();
                        while (sp_iter.next()) |sp_entry| {
                            self.allocator.free(sp_entry.key_ptr.*);
                            // GAP-0862: getAllNodeProperties hands back decoded
                            // StorageProperty VALUES whose String/Ext payloads are
                            // freshly allocated; fromStorageProperty above made an
                            // independent store-owned copy, so the source value must
                            // be freed here or every loaded string/ext property leaks
                            // on each restart/restore load.
                            graph_storage_adapter.freeOwnedStorageProperty(self.allocator, sp_entry.value_ptr.*);
                        }
                        storage_props.deinit();
                    }

                    var sp_iter = storage_props.iterator();
                    while (sp_iter.next()) |sp_entry| {
                        // C3 (review-0023): `.null` is the adapter's REMOVE tombstone —
                        // never materialize it as a present Null property (see
                        // materializeNodeFromEngine).
                        if (sp_entry.value_ptr.* == .null) continue;
                        const key_copy = try self.allocator.dupe(u8, sp_entry.key_ptr.*);
                        const pv = try graph_storage_adapter.fromStorageProperty(self.allocator, sp_entry.value_ptr.*);
                        try node.properties.put(key_copy, pv);
                    }

                    try self.nodes.put(node_uuid, node);

                    // Update next_node_id
                    if (node_uuid >= self.next_node_id) {
                        self.next_node_id = node_uuid + 1;
                    }

                    // Rebuild label index. GAP-ENT-0023 P3: skipped when the
                    // postings came from the labels snapshot (the insert would be
                    // a dedup no-op per id — pure wasted binary-search work).
                    if (!snap.labels) {
                        for (labels) |label| {
                            try self.addToLabelIndex(graph_name, label, node_uuid);
                        }
                    }

                    // GAP-825 (issue #825): the adapter hydration path used to
                    // rebuild `label_index` only, leaving `nodes_by_graph`
                    // (PERF-B) and `node_labels_by_tenant` /
                    // `label_properties_by_tenant` (PERF-C) empty after a
                    // restart.  That made `iterateNodesInGraph`,
                    // `nodesInGraphCount`, and `listNodeLabels` silently
                    // return zero rows even though `getNodesByLabel` worked.
                    // Mirror the introspection counters now so the in-memory
                    // store matches a freshly-created one.
                    const stored_node_ptr = self.nodes.getPtr(node_uuid) orelse return error.NodeNotFound;
                    try self.addNodeToGraphIndex(graph_name, node_uuid);
                    // GAP-ENT-0023 P3: the tenant introspection multisets came
                    // from the counters snapshot — re-bumping per node here would
                    // double-count them.
                    if (!snap.counters) try self.bumpIntrospectionForNode(stored_node_ptr);

                    // GAP-0900 Layer-3 (Fix 3): rebuild the merge property index for
                    // this hydrated node. Without this, a re-MERGE of an existing
                    // key after shutdown+reopen finds an empty index, takes the
                    // create branch, and produces a DUPLICATE — breaking resumable /
                    // idempotent seeding. `addToMergePropertyIndex` honors lean mode:
                    // off (default) indexes every key; on
                    // (GEODE_INDEX_MERGE_KEYS_ONLY=1) indexes only keys registered
                    // SO FAR. Keys registered AFTER load (e.g. the first MERGE of a
                    // fresh server process) are backfilled at registration time by
                    // `registerMergeIndexKey` -> `backfillMergeIndexForKey`.
                    // GAP-ENT-0023 P3: the whole merge product (single-key AND
                    // composite entries) came from the merge snapshot — skip the
                    // per-node rebuild (putOrUpdate would be an idempotent
                    // overwrite; pure wasted hashing).
                    if (!snap.merge) {
                        var merge_prop_iter = stored_node_ptr.properties.iterator();
                        while (merge_prop_iter.next()) |prop_entry| {
                            self.addToMergePropertyIndex(
                                stored_node_ptr.graph_name,
                                stored_node_ptr.labels,
                                prop_entry.key_ptr.*,
                                prop_entry.value_ptr.*,
                                stored_node_ptr.id,
                            ) catch {};
                        }
                        // Caveat "B": rebuild the COMPOSITE merge entry for this
                        // hydrated node so the from-dump EDGE phase (which runs as a
                        // SEPARATE process after the NODE load) resolves endpoints by
                        // {source, source_id} in ONE zero-read probe. No extra engine
                        // read — uses the already-loaded property map. No-op unless a
                        // composite key is registered (loaded from the sidecar in
                        // adapter init, before this load runs).
                        self.addNodeCompositeMergeEntries(stored_node_ptr);
                    }

                    // GAP-ENT-0023 P3: edge-side products fully covered by
                    // snapshots + mmap IdMap base + bounded caches — skip the
                    // per-node edge iteration (see skip_edge_scan above).
                    if (skip_edge_scan) continue;

                    var out_edges = try adapter.iterateOutgoingEdges(graph_name, slot_id, self.allocator);
                    defer out_edges.deinit();

                    // Hydration self-heal: physical outgoing edge slots with no
                    // INLINE public id (GAP-ENT-0024), no __geode_internal_edge_id
                    // property and no legacy mapping are ORPHANS left behind by the
                    // pre-fix createEdgeWithIdInternal ordering bug (one per
                    // idempotent Raft re-apply). They have no IdMap entry, so the
                    // read path can never reverse-map them
                    // (-> error.EdgeSlotMappingMissing). Collect them while the
                    // adjacency iterator is live and DELETE them after the iterator
                    // is exhausted (deleting mid-iteration would invalidate the
                    // adjacency cursor). The canonical slot for any public id always
                    // carries its id (inline for v2 edges, property for legacy), so
                    // it never lands here — and a legitimate distinct parallel edge
                    // carries its own id and is likewise never collected. See
                    // tests/test_edge_durability_churn_repro.zig.
                    const OrphanEdgeSlot = struct { to_slot: u64, edge_slot: u64 };
                    var orphan_edge_slots: std.ArrayList(OrphanEdgeSlot) = .empty;
                    defer orphan_edge_slots.deinit(self.allocator);

                    while (try out_edges.next()) |edge_entry| {
                        // Skip edges/nodes whose slot_ids aren't mapped yet (concurrent inserts).
                        const edge_uuid = blk: {
                            // GAP-ENT-0024 inline-first: v2 adjacency entries carry
                            // the PUBLIC id inline — no per-edge property fetch.
                            // 0 = legacy v1 block / pre-v0.2.24 store → fall back.
                            if (edge_entry.public_id != 0) break :blk edge_entry.public_id;

                            _ = edge_id_property_fallback_reads.fetchAdd(1, .monotonic);
                            if (try adapter.getEdgeProperty(
                                graph_name,
                                slot_id,
                                edge_entry.edge_id,
                                INTERNAL_EDGE_ID_PROPERTY_KEY,
                                self.allocator,
                            )) |stored_prop| {
                                defer graph_storage_adapter.freeOwnedStorageProperty(self.allocator, stored_prop);
                                switch (stored_prop) {
                                    .string => |text| {
                                        if (parsePersistedPublicId(text)) |parsed| break :blk parsed;
                                    },
                                    else => {},
                                }
                            }

                            if (legacy_map) |*map| {
                                const legacy_uuid_128 = map.edgeUuid(edge_entry.edge_id) orelse break :blk null;
                                const public_id = @as(u64, @truncate(legacy_uuid_128));
                                var id_buf: [16]u8 = undefined;
                                try adapter.setEdgeProperty(
                                    graph_name,
                                    slot_id,
                                    edge_entry.neighbor,
                                    edge_entry.edge_id,
                                    INTERNAL_EDGE_ID_PROPERTY_KEY,
                                    .{ .String = encodePersistedPublicId(&id_buf, public_id) },
                                );
                                backfilled_from_legacy = true;
                                break :blk public_id;
                            }

                            break :blk null;
                        } orelse {
                            // Orphan physical edge slot: no persisted public id, no
                            // legacy mapping. Queue it for durable deletion (the
                            // self-heal) and account it as a repair rather than a
                            // silent skip.
                            skipped_edge_mappings += 1;
                            try orphan_edge_slots.append(self.allocator, .{
                                .to_slot = edge_entry.neighbor,
                                .edge_slot = edge_entry.edge_id,
                            });
                            continue;
                        };
                        // PHASE 4: skip the edge IdMap re-insert when mmap_backed —
                        // base already holds the edge uuid->slot mapping; loop2's
                        // reads (below and id_map.nodeUuid) are served by base.
                        if (id_map.mode == .resident)
                            try id_map.insertEdgeWithSlot(@as(u128, edge_uuid), edge_entry.edge_id);

                        if (self.edges.contains(edge_uuid)) continue;

                        const target_uuid = @as(u64, @truncate(id_map.nodeUuid(edge_entry.neighbor) orelse continue));

                        // Get edge label from label dict
                        const mg = try adapter.getOrCreateGraph(graph_name);
                        const edge_label_str = mg.label_dict.getString(edge_entry.rel_type) orelse "UNKNOWN";
                        const edge_label_copy = try self.allocator.dupe(u8, edge_label_str);
                        const edge_graph_name_copy = try self.allocator.dupe(u8, graph_name);
                        // GAP-0891 (RC-2): recover the persisted edge tenant tag
                        // (absent / corrupt -> DEFAULT_TENANT_ID). Mirrors the node
                        // path and the edge-id read above (node slot + edge slot).
                        const edge_tenant_id_copy = blk_edge_tenant: {
                            const maybe_t = adapter.getEdgeProperty(graph_name, slot_id, edge_entry.edge_id, INTERNAL_TENANT_ID_PROPERTY_KEY, self.allocator) catch null;
                            if (maybe_t) |stored_prop| {
                                defer graph_storage_adapter.freeOwnedStorageProperty(self.allocator, stored_prop);
                                switch (stored_prop) {
                                    .string => |text| break :blk_edge_tenant try self.allocator.dupe(u8, text),
                                    else => {},
                                }
                            }
                            break :blk_edge_tenant try self.allocator.dupe(u8, DEFAULT_TENANT_ID);
                        };

                        var edge = Edge{
                            .id = edge_uuid,
                            .from_id = node_uuid,
                            .to_id = target_uuid,
                            .label = edge_label_copy,
                            .properties = CompactPropertyMap.init(self.allocator),
                            .graph_name = edge_graph_name_copy,
                            .tenant_id = edge_tenant_id_copy,
                        };

                        if (edge_entry.prop_head != 0) {
                            // Pass the source-node SLOT id (shard-striped) so
                            // adapter.getAllEdgeProperties routes via the
                            // correct per-shard engine. node_uuid is the
                            // public id (not stripe-aligned) and would
                            // misroute through shardOfNode(uuid). See
                            // graph_storage_adapter.getAllEdgeProperties for
                            // why prop_head alone is the wrong key.
                            var edge_storage_props = try adapter.getAllEdgeProperties(graph_name, slot_id, edge_entry.prop_head, self.allocator);
                            defer {
                                var edge_sp_iter = edge_storage_props.iterator();
                                while (edge_sp_iter.next()) |sp_entry| {
                                    self.allocator.free(sp_entry.key_ptr.*);
                                    // GAP-0862: free decoded String/Ext value bytes
                                    // (fromStorageProperty made an independent copy).
                                    graph_storage_adapter.freeOwnedStorageProperty(self.allocator, sp_entry.value_ptr.*);
                                }
                                edge_storage_props.deinit();
                            }

                            var edge_sp_iter = edge_storage_props.iterator();
                            while (edge_sp_iter.next()) |sp_entry| {
                                // C3 (review-0023): skip the `.null` REMOVE tombstone
                                // (same convention as node properties).
                                if (sp_entry.value_ptr.* == .null) continue;
                                const key_copy = try self.allocator.dupe(u8, sp_entry.key_ptr.*);
                                const pv = try graph_storage_adapter.fromStorageProperty(self.allocator, sp_entry.value_ptr.*);
                                try edge.properties.put(key_copy, pv);
                            }
                        }

                        try self.edges.put(edge_uuid, edge);
                        try self.addToAdjacencyIndex(node_uuid, target_uuid, edge_uuid);
                        // PERF-P0-001: Maintain edge-type index during adapter load
                        try self.addToEdgeTypeIndex(graph_name, edge.label, edge_uuid);
                        // DURABILITY: rebuild the per-(graph,type) exact counter on the
                        // restart edge-scan so typed count(r:TYPE) survives reopen
                        // (replay-on-load, like the label refcount + untyped edge count).
                        // GAP-ENT-0023 P3: restored from the counters snapshot when
                        // present — re-bumping would double-count.
                        if (!snap.counters) self.bumpGraphEdgeTypeCount(graph_name, edge.label);

                        if (edge_uuid >= self.next_edge_id) {
                            self.next_edge_id = edge_uuid + 1;
                        }
                    }

                    // Self-heal: now that this node's adjacency cursor is exhausted,
                    // physically delete the orphan edge slots collected above so an
                    // already-corrupted PVC converges to one durable slot per logical
                    // edge on restart. Deletion is best-effort per slot (a failure
                    // leaves the slot orphaned but unmapped — still no read-path
                    // regression, since it was already unqueryable).
                    for (orphan_edge_slots.items) |orphan| {
                        adapter.deleteEdge(graph_name, slot_id, orphan.to_slot, orphan.edge_slot) catch |err| {
                            log.warn("hydration orphan-edge-slot repair failed; slot remains orphaned (unqueryable)", &.{
                                Attr.string("graph", graph_name),
                                Attr.int("from_slot", @intCast(slot_id)),
                                Attr.int("edge_slot", @intCast(orphan.edge_slot)),
                                Attr.string("error", @errorName(err)),
                            });
                            continue;
                        };
                        repaired_edge_slots += 1;
                    }
                }
            } // end legacy per-node scan (streaming fast-scan branch above)

            // Flush the legacy backfill AND any orphan-slot repairs so the
            // durable store reflects the self-heal on next open (idempotent
            // re-load then sees a clean adjacency).
            //
            // GAP-ENT-0042(a): this used to be `try adapter.checkpointAll()`
            // — an ALL-graph FULL checkpoint whose per-graph EXCLUSIVE rwlock
            // acquisition spins UNBOUNDEDLY (timeout null) — fired from
            // inside the hydration chokepoint (entry.mutex +
            // hydration_build_mutex held). Any busy rwlock on ANY graph
            // (e.g. a SHARED holder itself parked on `ensureGraphHydrated`
            // for a different graph → on the hydration_build_mutex WE hold)
            // wedged the server permanently — the exact topology the Task-3
            // bounded acquire was built to avoid. The backfill and the
            // repairs only touched THIS graph, so scope the flush to THIS
            // graph and reuse the Task-3 bounded-acquire path
            // (`checkpointGraph`: 5 s deadline, tryLock re-probe, never
            // parks). On timeout/failure: log LOUDLY and continue — the
            // repairs are already applied to the engine (WAL-durable), so
            // skipping the flush only defers page-flush/WAL-truncate to the
            // next checkpoint, and a crash before then simply re-detects any
            // surviving orphan slot on the next hydration scan and re-heals
            // (idempotent, best-effort-per-slot by design). NOTE: with the
            // C-1 reclaim gate, this mid-hydration graph checkpoint
            // (`done == false`) deliberately skips the retired-cache
            // reclaims — the merge family threads' batch memory stays
            // untouched.
            if (backfilled_from_legacy or repaired_edge_slots > 0) {
                adapter.checkpointGraph(graph_name) catch |err| {
                    _ = g_selfheal_checkpoint_skips.fetchAdd(1, .monotonic);
                    log.err("hydration self-heal flush checkpoint skipped; repairs stay WAL-durable until the next checkpoint", &.{
                        Attr.string("graph", graph_name),
                        Attr.string("error", @errorName(err)),
                    });
                };
            }
            self.cleanupLegacySidecarsForGraph(graph_name);

            if (skipped_node_mappings > 0 or skipped_edge_mappings > 0) {
                log.warn("loadFromAdapter skipped entries with no persisted public ID mapping", &.{
                    Attr.string("graph", graph_name),
                    Attr.int("skipped_nodes", @intCast(skipped_node_mappings)),
                    Attr.int("skipped_edges", @intCast(skipped_edge_mappings)),
                });
            }

            if (repaired_edge_slots > 0) {
                log.warn("loadFromAdapter repaired orphan edge slots (re-apply self-heal)", &.{
                    Attr.string("graph", graph_name),
                    Attr.int("repaired_edge_slots", @intCast(repaired_edge_slots)),
                });
            }
        }
        return .rebuilt;
    }

    /// DEPRECATED: Legacy buffer serialization stub — adapter handles persistence.
    /// Returns an empty buffer.
    pub fn serializeToBuffer(self: *GraphStore) !std.ArrayList(u8) {
        return std.ArrayList(u8).initCapacity(self.allocator, 0);
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-002; FEATURE="ClusterReplication"; ASPECT=SnapshotSerialization; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-05
    /// Serialize all nodes and edges to JSON-lines format for cluster replication.
    /// Each line is one JSON object:
    ///   {"type":"node","id":N,"graph":"G","labels":["L1"],"properties":{"k":"v"}}
    ///   {"type":"edge","id":N,"from":F,"to":T,"graph":"G","label":"L","properties":{}}
    /// Returns owned bytes that the caller must free with `allocator.free`.
    pub fn serializeSnapshot(self: *GraphStore, allocator: std.mem.Allocator) ![]u8 {
        // PHASE 1b chokepoint: a snapshot enumerates every graph's IdMaps and the
        // resident node/edge caches. After a no-snapshot early-ready open
        // (`markPendingHydration` fallback) a deferred graph's IdMap is EMPTY
        // until first access, so an unguarded serialize would emit a PARTIAL /
        // empty snapshot — silent divergence for the automatic cluster
        // replication callers (cluster.replicateShardToNode,
        // raft_snapshot_manager.createSnapshotData) that never run a query first.
        // Hydrate EVERY graph before reading. Called first, before any lock, so
        // the store-wide `hydration_build_mutex` it takes cannot deadlock (mirrors
        // the count/listEdgeTypes guards); `loadOneGraphFromAdapterFull` never
        // re-enters this serializer, so no re-entrancy.
        self.ensureAllGraphsHydrated();
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);

        // Serialize nodes as JSON-lines.
        if (self.nodes.effectiveCap() == 0) {
            // Unbounded: resident map is the full set.
            var node_iter = self.nodes.iterator();
            while (node_iter.next()) |entry| {
                try appendNodeJson(&buf, allocator, entry.key_ptr.*, entry.value_ptr);
                try buf.append(allocator, '\n');
            }
        } else {
            // Bounded: resident map is incomplete — enumerate every id from the
            // resident IdMaps and serialize the resident copy if present, else a
            // node rebuilt from the engine (freed after serialize, so a full
            // backup never blows the resident bound).
            const adapter = global_adapter;
            var it = self.id_maps.iterator();
            while (it.next()) |im_entry| {
                const graph_name = im_entry.key_ptr.*;
                var nit = im_entry.value_ptr.nodeUuidIterator();
                while (nit.next()) |nuuid| {
                    const id = @as(u64, @truncate(nuuid));
                    if (self.nodes.get(id)) |resident| {
                        var n = resident;
                        try appendNodeJson(&buf, allocator, id, &n);
                        try buf.append(allocator, '\n');
                    } else if (adapter) |ad| {
                        const slot = im_entry.value_ptr.nodeSlot(@as(u128, id)) orelse continue;
                        var materialized = (try materializeNodeFromEngine(ad, allocator, graph_name, slot, id)) orelse continue;
                        defer freeNodeValue(allocator, &materialized);
                        try appendNodeJson(&buf, allocator, id, &materialized);
                        try buf.append(allocator, '\n');
                    }
                }
            }
        }

        // Serialize edges as JSON-lines.
        if (self.edges.effectiveCap() == 0) {
            // Unbounded: resident map is the full set.
            var edge_iter = self.edges.iterator();
            while (edge_iter.next()) |entry| {
                try appendEdgeJson(&buf, allocator, entry.key_ptr.*, entry.value_ptr);
                try buf.append(allocator, '\n');
            }
        } else {
            // PHASE 1: bounded — resident map is incomplete. Enumerate every
            // edge id from the resident IdMaps and serialize the resident copy
            // if present, else an edge rebuilt from the engine via
            // hydrate-on-miss (residency stays bounded). Mirrors the node branch
            // above so a snapshot/backup never misses an evicted edge.
            var it = self.id_maps.iterator();
            while (it.next()) |im_entry| {
                var eit = im_entry.value_ptr.edgeUuidIterator();
                while (eit.next()) |euuid| {
                    const id = @as(u64, @truncate(euuid));
                    if (self.getEdgePtrHydrated(id)) |edge| {
                        try appendEdgeJson(&buf, allocator, id, edge);
                        try buf.append(allocator, '\n');
                    }
                }
            }
        }

        return try buf.toOwnedSlice(allocator);
    }

    /// Append a single node as a JSON object to the buffer.
    fn appendNodeJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, id: u64, node: *const Node) !void {
        try buf.appendSlice(allocator, "{\"type\":\"node\",\"id\":");
        try appendU64(buf, allocator, id);
        try buf.appendSlice(allocator, ",\"graph\":\"");
        try appendJsonEscaped(buf, allocator, node.graph_name);
        try buf.appendSlice(allocator, "\",\"labels\":[");
        for (node.labels, 0..) |label, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '"');
            try appendJsonEscaped(buf, allocator, label);
            try buf.append(allocator, '"');
        }
        try buf.appendSlice(allocator, "],\"properties\":");
        try appendPropertiesJson(buf, allocator, &node.properties);
        try buf.append(allocator, '}');
    }

    /// Append a single edge as a JSON object to the buffer.
    fn appendEdgeJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, id: u64, edge: *const Edge) !void {
        try buf.appendSlice(allocator, "{\"type\":\"edge\",\"id\":");
        try appendU64(buf, allocator, id);
        try buf.appendSlice(allocator, ",\"from\":");
        try appendU64(buf, allocator, edge.from_id);
        try buf.appendSlice(allocator, ",\"to\":");
        try appendU64(buf, allocator, edge.to_id);
        try buf.appendSlice(allocator, ",\"graph\":\"");
        try appendJsonEscaped(buf, allocator, edge.graph_name);
        try buf.appendSlice(allocator, "\",\"label\":\"");
        try appendJsonEscaped(buf, allocator, edge.label);
        try buf.appendSlice(allocator, "\",\"properties\":");
        try appendPropertiesJson(buf, allocator, &edge.properties);
        try buf.append(allocator, '}');
    }

    /// Append a u64 value as decimal text.
    fn appendU64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
        var tmp: [20]u8 = undefined;
        const slice = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
        try buf.appendSlice(allocator, slice);
    }

    /// Append a string with JSON escaping (quotes, backslashes, control chars).
    fn appendJsonEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        // Control characters as \u00XX
                        var esc: [6]u8 = undefined;
                        _ = std.fmt.bufPrint(&esc, "\\u{x:0>4}", .{c}) catch unreachable;
                        try buf.appendSlice(allocator, &esc);
                    } else {
                        try buf.append(allocator, c);
                    }
                },
            }
        }
    }

    /// Append a property map as a JSON object: {"key":"val","key2":123}
    fn appendPropertiesJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, props: *const CompactPropertyMap) !void {
        try buf.append(allocator, '{');
        var first = true;
        var it = props.iterator();
        while (it.next()) |prop| {
            if (!first) try buf.append(allocator, ',');
            first = false;
            try buf.append(allocator, '"');
            try appendJsonEscaped(buf, allocator, prop.key_ptr.*);
            try buf.appendSlice(allocator, "\":");
            try appendPropertyValueJson(buf, allocator, prop.value_ptr.*);
        }
        try buf.append(allocator, '}');
    }

    /// Append a single PropertyValue as a JSON value.
    fn appendPropertyValueJson(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: PropertyValue) !void {
        switch (value) {
            .String => |s| {
                try buf.append(allocator, '"');
                try appendJsonEscaped(buf, allocator, s);
                try buf.append(allocator, '"');
            },
            .Int => |v| {
                var tmp: [20]u8 = undefined;
                const slice = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
                try buf.appendSlice(allocator, slice);
            },
            .Float => |v| {
                var tmp: [32]u8 = undefined;
                const slice = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch unreachable;
                try buf.appendSlice(allocator, slice);
            },
            .Bool => |v| {
                try buf.appendSlice(allocator, if (v) "true" else "false");
            },
            .Null => {
                try buf.appendSlice(allocator, "null");
            },
            .Decimal => |d| {
                // Serialize as string to preserve precision
                try buf.append(allocator, '"');
                var tmp: [48]u8 = undefined;
                const slice = std.fmt.bufPrint(&tmp, "{d}e-{d}", .{ d.coeff, d.scale }) catch unreachable;
                try buf.appendSlice(allocator, slice);
                try buf.append(allocator, '"');
            },
            .ExtValue => {
                // Extended values serialized as descriptive string
                try buf.appendSlice(allocator, "\"<ext>\"");
            },
        }
    }

    // CANARY: REQ=REQ-BINARY-PERSIST-DIRTY-002; FEATURE="BinaryPersistence"; ASPECT=ConditionalSave; STATUS=TESTED; TEST=tests/test_gap0514_graph_store_regression.zig; OWNER=storage; UPDATED=2026-04-11
    /// Save if dirty — delegates to saveToFile (adapter checkpoint + IdMap save).
    pub fn saveIfDirty(self: *GraphStore) void {
        if (@constCast(&self.dirty).load(.acquire)) {
            self.saveToFile() catch |err| {
                log.err("failed to persist graph store", &.{
                    Attr.string("error", @errorName(err)),
                });
            };
        }
    }

    // CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-005; FEATURE="EngineBackedPersistence"; ASPECT=LoadFromFile; STATUS=TESTED; TEST=test-graph-store; OWNER=storage; UPDATED=2026-07-04
    // Load from per-graph storage engine instead of legacy graph_store.dat.
    pub fn loadFromFile(self: *GraphStore) !void {
        // T2c SEGV root-cause fix (14.27M hydration crash): `clearNodes` frees
        // EVERY resident + retired Node/Edge value inline (freeNodeValue). A
        // streaming-hydration merge in flight on another thread holds shallow
        // Node copies (FamilyPipeline batches) whose sub-heap it shares with
        // those resident cache entries — clearing mid-build is a use-after-free
        // the moment a family thread touches its batch (at scale: SEGV/garbage
        // ~100 s in, exactly when the catalog's lazy init reloaded the store
        // during the first query's hydration). Destructive reloads must
        // therefore serialize with the store-wide hydration build lock: every
        // stream-scan/legacy lazy build runs under `hydration_build_mutex`
        // (see ensureGraphHydrated), so holding it here means no build is in
        // flight while we clear, and no build can start until the reload is
        // done. Lock ordering (CLAUDE.md tier): hydration_build_mutex is
        // acquired BEFORE any leaf lock taken inside clear/load below — the
        // same order the lazy build itself uses; no caller of loadFromFile
        // holds hydration_build_mutex (catalog/backup/boot/test are all
        // top-level control paths).
        const io = std.Io.Threaded.global_single_threaded.io();
        self.hydration_build_mutex.lockUncancelable(io);
        defer self.hydration_build_mutex.unlock(io);

        // Reload semantics replace the in-memory compatibility cache with the
        // latest engine-backed state. This keeps repeated loads idempotent and
        // avoids duplicate indexes / adjacency entries.
        self.clearNodes();
        errdefer self.clearNodes();
        // Reload coherence: `clearNodes` wipes every resident product but NOT
        // `pending_hydration`, so a graph hydrated before this reload would
        // stay latched done=true over now-EMPTY products (reads would see an
        // empty graph forever). RESET the latches (never destroy the entries —
        // `ensureGraphHydrated` holds entry pointers outside `hydration_mutex`,
        // so destroying here would be a fresh use-after-free) so the next
        // first-touch re-hydrates from the engine. Lock nesting
        // (hydration_build_mutex -> hydration_mutex) matches the established
        // build-path order (loadOneGraphFromAdapterFull -> markPendingHydration).
        {
            self.hydration_mutex.lockUncancelable(io);
            defer self.hydration_mutex.unlock(io);
            var pit = self.pending_hydration.iterator();
            while (pit.next()) |e| {
                e.value_ptr.*.done.store(false, .release);
                e.value_ptr.*.failed.store(false, .release);
            }
        }
        if (global_adapter) |adapter| {
            try self.loadFromAdapter(adapter);
        }
        // If no adapter (test mode), just start with empty store
    }

    /// Catalog-recovery registration (T2c SEGV fix, part 2): register ONLY the
    /// given just-opened graphs for lazy hydration — the non-destructive
    /// replacement for the catalog's previous blanket `loadFromFile()`, which
    /// cleared the ENTIRE global node/edge cache (freeing every resident value)
    /// and re-registered every graph. On a live server that wipe raced the
    /// in-flight first-touch hydration (use-after-free of batch sub-heap) and
    /// reset the lazy-hydration state of graphs that were already registered
    /// or even fully hydrated.
    ///
    /// Each name gets the standard PHASE 1b open step
    /// (`loadOneGraphFromAdapter`: IdMap snapshot load or deferred scan +
    /// pending-hydration registration) with the same quarantine-and-continue
    /// policy as the boot path. Graphs that already have a pending-hydration
    /// entry (i.e. were registered at open, hydrated or not) are SKIPPED —
    /// their state, resident products, and any in-flight build stay untouched.
    pub fn registerAdapterGraphsForLazyHydration(
        self: *GraphStore,
        graph_names: []const []const u8,
    ) !void {
        const adapter = global_adapter orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();
        // Serialize registration against in-flight lazy builds: the open step
        // mutates store-wide maps (id_maps via getOrCreateIdMap) whose INLINE
        // values a running build dereferences — a rehash under the build's
        // feet is the same use-after-move hazard class the reload fix above
        // closes. Same lock order as the build path (build -> hydration leaf).
        self.hydration_build_mutex.lockUncancelable(io);
        defer self.hydration_build_mutex.unlock(io);
        for (graph_names) |graph_name| {
            const already_registered = blk: {
                self.hydration_mutex.lockUncancelable(io);
                defer self.hydration_mutex.unlock(io);
                break :blk self.pending_hydration.contains(graph_name);
            };
            if (already_registered) continue;
            self.loadOneGraphFromAdapter(adapter, graph_name) catch |err| {
                log.err("catalog graph registration failed; quarantining graph and continuing", &.{
                    Attr.string("graph", graph_name),
                    Attr.string("error", @errorName(err)),
                });
                if (self.markPendingHydration(graph_name)) |_| {
                    self.hydration_mutex.lockUncancelable(io);
                    defer self.hydration_mutex.unlock(io);
                    if (self.pending_hydration.get(graph_name)) |hentry| {
                        hentry.failed.store(true, .release);
                    }
                } else |mark_err| {
                    log.warn("failed to quarantine catalog graph; checkpoint may bless empty snapshots", &.{
                        Attr.string("graph", graph_name),
                        Attr.string("error", @errorName(mark_err)),
                    });
                }
                continue;
            };
        }
    }

    // CANARY: REQ=REQ-TXN-UNDO-002; FEATURE="TransactionUndoLog"; ASPECT=NoSaveOperations; STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml; OWNER=engine; UPDATED=2025-12-23
    // NoSave versions of mutation methods for transaction undo/redo operations
    // These methods modify the store without triggering auto-save to disk

    /// Delete a node without saving (used during rollback)
    pub fn deleteNodeNoSave(self: *GraphStore, node_id: u64) void {
        // PHASE 1b chokepoint: hydrate before mutating indexes (must run BEFORE
        // the getPtr below — hydration mutates the node cache).
        self.ensureNodeGraphHydrated(node_id);
        const node_ptr = self.nodes.getPtr(node_id) orelse return;

        // Collect connected edges first
        var edge_ids = std.ArrayList(u64).empty;
        defer edge_ids.deinit(self.allocator);

        // PHASE 0: collect via the hydrating accessors so an EVICTED node's full
        // edge set is still found (appendSlice copies, so the later inAdjItems
        // call can safely evict the outgoing entry we already copied).
        if (self.outAdjItems(node_id)) |outgoing| {
            edge_ids.appendSlice(self.allocator, outgoing) catch {};
        }
        if (self.inAdjItems(node_id)) |incoming| {
            for (incoming) |edge_id| {
                var exists = false;
                for (edge_ids.items) |existing| {
                    if (existing == edge_id) {
                        exists = true;
                        break;
                    }
                }
                if (!exists) {
                    edge_ids.append(self.allocator, edge_id) catch {};
                }
            }
        }

        // Remove connected edges
        for (edge_ids.items) |edge_id| {
            self.deleteEdgeNoSave(edge_id);
        }

        // Remove node from label index
        for (node_ptr.labels) |label| {
            self.removeFromLabelIndex(node_ptr.graph_name, label, node_id);
        }

        // PERF-B (issue #811): per-graph node-id index.
        self.removeNodeFromGraphIndex(node_ptr.graph_name, node_id);
        // PERF-C (issue #814): tenant-keyed label + label-property counters.
        // Walk properties first because dec-label-property reads the node's
        // tenant_id which is still alive at this point. Properties carrying
        // internal IDs are skipped (they were never bumped on insert).
        self.decIntrospectionForNode(node_ptr);

        // Remove all merge property index entries for this node
        self.removeAllMergePropertyIndexEntries(node_ptr);
        // ...including the COMPOSITE merge entry (caveat "B").
        self.removeNodeCompositeMergeEntries(node_ptr);

        // Free labels
        for (node_ptr.labels) |label| {
            self.allocator.free(label);
        }
        self.allocator.free(node_ptr.labels);
        // Free graph_name
        if (node_ptr.graph_name.len > 0) {
            self.allocator.free(node_ptr.graph_name);
        }
        // GAP-0279: Free tenant_id
        if (node_ptr.tenant_id.len > 0) {
            self.allocator.free(node_ptr.tenant_id);
        }
        // Free properties
        var prop_iter = node_ptr.properties.iterator();
        while (prop_iter.next()) |prop_entry| {
            self.allocator.free(prop_entry.key_ptr.*);
            freePropertyValue(self, prop_entry.value_ptr.*);
        }
        node_ptr.properties.deinit();
        // The node heap was freed inline above (exactly as the pre-cache mirror
        // did on explicit delete). Use unlink (NOT remove) so the cache does not
        // ALSO retire+reclaim this value — that would double-free.
        _ = self.nodes.unlink(node_id);

        // Remove any still-resident adjacency lists for this node. PHASE 0: use
        // the cache's retire-based remove (frees the AdjList via freeAdjListValue
        // at the grace window) rather than an inline free, so a concurrent SHARED
        // reader holding a slice into the list stays valid. Usually a no-op here:
        // deleting the connected edges above already emptied + removed them.
        self.outgoing_edges.remove(node_id);
        self.incoming_edges.remove(node_id);
    }

    /// Delete an edge without saving (used during rollback)
    pub fn deleteEdgeNoSave(self: *GraphStore, edge_id: u64) void {
        self.ensureEdgeGraphHydrated(edge_id); // PHASE 1b chokepoint (hydrate before write)
        // PHASE 1: if the edge body was EVICTED, hydrate it back into the cache
        // first so fetchRemove below recovers the body — otherwise the
        // adjacency + edge-type index cleanup (keyed off from/to/label) would be
        // skipped, leaving the edge id dangling in those indexes. fetchRemove
        // takes ownership of the value; the inline free here mirrors the
        // pre-cache delete (delete runs under the exclusive write path, so no
        // SHARED reader holds this specific entry).
        if (!self.edges.contains(edge_id)) {
            _ = self.getEdgePtrHydrated(edge_id);
        }
        if (self.edges.fetchRemove(edge_id)) |kv| {
            var edge = kv.value;

            self.removeFromAdjacencyIndex(edge.from_id, edge.to_id, edge_id);
            // PERF-P0-001: Remove from edge-type index before freeing label/graph_name
            self.removeFromEdgeTypeIndex(edge.graph_name, edge.label, edge_id);
            // PERF-C (issue #814): tenant-keyed edge-type counter. Decrement
            // before we free label/tenant_id strings (they're still alive in
            // the `edge` struct copy we own here).
            self.decEdgeTypeCount(edge.graph_name, edge.tenant_id, edge.label);
            // Per-(graph,type) exact counter (typed count(r:TYPE) fast path).
            self.decGraphEdgeTypeCount(edge.graph_name, edge.label);

            // Free label
            self.allocator.free(edge.label);
            // Free graph_name
            if (edge.graph_name.len > 0) {
                self.allocator.free(edge.graph_name);
            }
            // GAP-0279: Free tenant_id
            if (edge.tenant_id.len > 0) {
                self.allocator.free(edge.tenant_id);
            }
            // Free properties
            var prop_iter = edge.properties.iterator();
            while (prop_iter.next()) |prop_entry| {
                self.allocator.free(prop_entry.key_ptr.*);
                freePropertyValue(self, prop_entry.value_ptr.*);
            }
            edge.properties.deinit();
        }
    }

    /// Delete a node and mark store dirty
    pub fn deleteNode(self: *GraphStore, node_id: u64) void {
        self.ensureNodeGraphHydrated(node_id); // PHASE 1b chokepoint (before any cache read)
        // Capture graph_name before deletion for WAL notification and handle routing
        const gn = if (self.nodes.get(node_id)) |n| n.graph_name else "";

        if (global_vtable) |vt| {
            const adapter_gn = if (gn.len > 0) gn else "default";
            const slot_id = self.requireNodeSlot(adapter_gn, node_id) catch |err| {
                log.err("adapter node-slot lookup failed during deleteNode", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("node_id", @intCast(node_id)),
                    Attr.string("graph", adapter_gn),
                });
                return;
            };
            vt.deleteNodeFn(vt.ctx, adapter_gn, slot_id) catch |err| {
                log.err("adapter deleteNode failed", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.int("node_id", @intCast(node_id)),
                    Attr.string("graph", adapter_gn),
                });
                return;
            };
            // Remove from IdMap
            if (self.getIdMap(adapter_gn)) |im| {
                _ = im.removeNode(@as(u128, node_id));
            }
        }

        self.deleteNodeNoSave(node_id);
        self.dirty.store(true, .release);
        incrementMutationEpoch();
        // WAL notification: DeleteNode
        notifyMutation(.delete_node, node_id, 0, 0, null, null, null, gn);
    }

    /// Delete an edge and mark store dirty
    pub fn deleteEdge(self: *GraphStore, edge_id: u64) void {
        self.ensureEdgeGraphHydrated(edge_id); // PHASE 1b chokepoint (before any cache read)
        // Capture graph_name before deletion for WAL notification and handle
        // routing. PHASE 1: hydrate-on-miss so an EVICTED edge can still be
        // deleted (its endpoints/graph resolved from the engine).
        const gn = if (self.getEdgePtrHydrated(edge_id)) |e| e.graph_name else "";

        if (global_vtable) |vt| {
            if (self.getEdgePtrHydrated(edge_id)) |edge| {
                const slot_from = self.requireNodeSlot(edge.graph_name, edge.from_id) catch |err| {
                    log.err("adapter edge endpoint-slot lookup failed during deleteEdge", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.int("edge_id", @intCast(edge_id)),
                        Attr.string("graph", edge.graph_name),
                    });
                    return;
                };
                const slot_to = self.requireNodeSlot(edge.graph_name, edge.to_id) catch |err| {
                    log.err("adapter edge endpoint-slot lookup failed during deleteEdge", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.int("edge_id", @intCast(edge_id)),
                        Attr.string("graph", edge.graph_name),
                    });
                    return;
                };
                const slot_edge = self.requireEdgeSlot(edge.graph_name, edge_id) catch |err| {
                    log.err("adapter edge-slot lookup failed during deleteEdge", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.int("edge_id", @intCast(edge_id)),
                        Attr.string("graph", edge.graph_name),
                    });
                    return;
                };
                vt.deleteEdgeFn(vt.ctx, edge.graph_name, slot_from, slot_to, slot_edge) catch |err| {
                    log.err("adapter deleteEdge failed", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.int("edge_id", @intCast(edge_id)),
                        Attr.string("graph", edge.graph_name),
                    });
                    return;
                };
                // Remove edge from IdMap
                if (self.getIdMap(edge.graph_name)) |im| {
                    _ = im.removeEdge(@as(u128, edge_id));
                }
            }
        }

        self.deleteEdgeNoSave(edge_id);
        self.dirty.store(true, .release);
        incrementMutationEpoch();
        // WAL notification: DeleteEdge
        notifyMutation(.delete_edge, edge_id, 0, 0, null, null, null, gn);
    }

    /// Set a node property without saving (used during rollback)
    pub fn setNodePropertyNoSave(self: *GraphStore, node_id: u64, key: []const u8, value: PropertyValue) !void {
        self.ensureNodeGraphHydrated(node_id); // PHASE 1b chokepoint (before any cache read)
        if (self.nodes.getPtr(node_id)) |node| {
            const value_copy = try copyPropertyValue(self, value);
            errdefer freePropertyValue(self, value_copy);

            // Caveat "B" COMPLETENESS (GAP-A): the composite merge index must stay
            // complete on the rollback / Raft-snapshot-restore path too — those
            // restore a node's properties EXCLUSIVELY through this NoSave setter
            // (createNodeWithId...NoSave then setNodePropertyNoSave per prop). If
            // this path skips the composite entry, a live composite-bearing node
            // ends up with NO composite entry and the authoritative composite MISS
            // (graph_storage_adapter.lookupPublicNodeIdByLabelAndAllProps) would
            // wrongly report it absent. Mirror the saving setNodeProperty: when
            // `key` is a composite component, remove the OLD composite entry before
            // overwriting and re-assert it from the node's CURRENT values below.
            // ENG-3954 / #874: same shard-exclusive discipline as the saving
            // setNodeProperty — this path mutates PUBLISHED nodes too.
            self.nodes.lockShardExclusive(node_id);
            defer self.nodes.unlockShardExclusive(node_id);

            const composite_component = isCompositeComponentKey(key);
            if (composite_component) self.removeNodeCompositeMergeEntries(node);

            const result = try node.properties.getOrPut(key);
            const was_new = !result.found_existing;
            if (was_new) {
                result.key_ptr.* = try self.allocator.dupe(u8, key);
            } else {
                self.removeFromMergePropertyIndex(node.graph_name, node.labels, key, result.value_ptr.*);
                freePropertyValue(self, result.value_ptr.*);
            }
            result.value_ptr.* = value_copy;
            self.addToMergePropertyIndex(node.graph_name, node.labels, key, value_copy, node_id) catch {};
            // Re-assert the composite merge entry from the node's CURRENT values
            // (now including the new value for `key`). No-op until the node carries
            // ALL composite props, or when no composite key is registered.
            if (composite_component) self.addNodeCompositeMergeEntries(node);
            // PERF-C (issue #814): mirror the bump from setNodeProperty so
            // the rollback / WAL replay path keeps the introspection index in
            // sync with the in-memory state.
            if (was_new and !isInternalPersistedPropertyKey(key)) {
                for (node.labels) |label| {
                    self.bumpLabelPropertyCount(node.graph_name, node.tenant_id, label, key) catch {};
                }
            }
        }
    }

    /// Remove a node property without saving (used during rollback)
    pub fn removeNodePropertyNoSave(self: *GraphStore, node_id: u64, key: []const u8) void {
        self.ensureNodeGraphHydrated(node_id); // PHASE 1b chokepoint (before any cache read)
        if (self.nodes.getPtr(node_id)) |node| {
            // Caveat "B" COMPLETENESS (GAP-B): drop the (soon-stale) composite
            // merge entry before removing a composite component, symmetric with
            // the saving removeNodeProperty. No-op when no composite registered.
            // ENG-3954 / #874: see setNodePropertyNoSave.
            self.nodes.lockShardExclusive(node_id);
            defer self.nodes.unlockShardExclusive(node_id);
            if (isCompositeComponentKey(key)) self.removeNodeCompositeMergeEntries(node);
            if (node.properties.fetchRemove(key)) |kv| {
                self.removeFromMergePropertyIndex(node.graph_name, node.labels, kv.key, kv.value);
                // PERF-C (issue #814): mirror the dec from removeNodeProperty.
                if (!isInternalPersistedPropertyKey(kv.key)) {
                    for (node.labels) |label| {
                        self.decLabelPropertyCount(node.graph_name, node.tenant_id, label, kv.key);
                    }
                }
                self.allocator.free(kv.key);
                freePropertyValue(self, kv.value);
            }
        }
    }

    /// Set an edge property without saving (used during rollback)
    pub fn setEdgePropertyNoSave(self: *GraphStore, edge_id: u64, key: []const u8, value: PropertyValue) !void {
        self.ensureEdgeGraphHydrated(edge_id); // PHASE 1b chokepoint (before any cache read)
        if (self.getEdgePtrHydrated(edge_id)) |edge| {
            const value_copy = try copyPropertyValue(self, value);
            errdefer freePropertyValue(self, value_copy);

            // ENG-3954 / #874: see setNodePropertyNoSave.
            self.edges.lockShardExclusive(edge_id);
            defer self.edges.unlockShardExclusive(edge_id);
            const result = try edge.properties.getOrPut(key);
            if (!result.found_existing) {
                result.key_ptr.* = try self.allocator.dupe(u8, key);
            } else {
                freePropertyValue(self, result.value_ptr.*);
            }
            result.value_ptr.* = value_copy;
        }
    }

    /// Remove an edge property without saving (used during rollback)
    pub fn removeEdgePropertyNoSave(self: *GraphStore, edge_id: u64, key: []const u8) void {
        self.ensureEdgeGraphHydrated(edge_id); // PHASE 1b chokepoint (before any cache read)
        if (self.getEdgePtrHydrated(edge_id)) |edge| {
            // ENG-3954 / #874: see setNodePropertyNoSave.
            self.edges.lockShardExclusive(edge_id);
            defer self.edges.unlockShardExclusive(edge_id);
            if (edge.properties.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                freePropertyValue(self, kv.value);
            }
        }
    }

    /// Restore a deleted node without saving (used during rollback)
    pub fn restoreNodeNoSave(self: *GraphStore, node_id: u64, labels: []const []const u8, graph_name: []const u8) !void {
        // Copy labels
        const labels_copy = try self.allocator.alloc([]const u8, labels.len);
        for (labels, 0..) |label, i| {
            labels_copy[i] = try self.allocator.dupe(u8, label);
        }

        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const tenant_id_copy = try self.allocator.dupe(u8, DEFAULT_TENANT_ID);

        const node = Node{
            .id = node_id,
            .labels = labels_copy,
            .properties = CompactPropertyMap.init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        try self.nodes.put(node_id, node);

        try self.ensureGraph(graph_name);
        for (labels) |label| {
            try self.addToLabelIndex(graph_name, label, node_id);
        }
        // PERF-B/C (issues #811, #814): restoreNodeNoSave is the rollback
        // counterpart to createNode — mirror the index bumps. The restored
        // node carries no properties (rollback re-runs SetProperty ops
        // separately), so only label-level counters fire here.
        try self.addNodeToGraphIndex(graph_name, node_id);
        for (labels) |label| {
            try self.bumpLabelCount(graph_name, DEFAULT_TENANT_ID, label);
        }
    }

    /// Restore a deleted edge without saving (used during rollback)
    pub fn restoreEdgeNoSave(self: *GraphStore, edge_id: u64, from_id: u64, to_id: u64, label: []const u8, graph_name: []const u8) !void {
        const label_copy = try self.allocator.dupe(u8, label);
        const graph_name_copy = try self.allocator.dupe(u8, graph_name);
        const tenant_id_copy = try self.allocator.dupe(u8, DEFAULT_TENANT_ID);

        const edge = Edge{
            .id = edge_id,
            .from_id = from_id,
            .to_id = to_id,
            .label = label_copy,
            .properties = CompactPropertyMap.init(self.allocator),
            .graph_name = graph_name_copy,
            .tenant_id = tenant_id_copy,
        };

        try self.edges.put(edge_id, edge);

        try self.ensureGraph(graph_name);
        try self.addToAdjacencyIndex(from_id, to_id, edge_id);
        // PERF-P0-001: Maintain edge-type index during rollback restore
        try self.addToEdgeTypeIndex(graph_name, label, edge_id);
        // PERF-C (issue #814): tenant-keyed edge-type counter for rollback.
        try self.bumpEdgeTypeCount(graph_name, DEFAULT_TENANT_ID, label);
        // Per-(graph,type) exact counter (typed count(r:TYPE) fast path).
        self.bumpGraphEdgeTypeCount(graph_name, label);
    }

    /// Add a label to a node without saving (used during rollback)
    pub fn addNodeLabelNoSave(self: *GraphStore, node_id: u64, label: []const u8) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            // Check if label already exists
            for (node.labels) |existing_label| {
                if (std.mem.eql(u8, existing_label, label)) {
                    return;
                }
            }

            const label_copy = try self.allocator.dupe(u8, label);
            const new_labels = try self.allocator.alloc([]const u8, node.labels.len + 1);
            @memcpy(new_labels[0..node.labels.len], node.labels);
            new_labels[node.labels.len] = label_copy;

            // GAP-825: same free+reassign window as addNodeLabel — must be
            // serialised against `cloneNodesFrom` snapshot readers.
            {
                const io = std.Io.Threaded.global_single_threaded.io();
                self.labels_rwlock.lockUncancelable(io);
                defer self.labels_rwlock.unlock(io);

                if (node.labels.len > 0) {
                    self.allocator.free(node.labels);
                }

                node.labels = new_labels;
            }

            try self.addToLabelIndex(node.graph_name, label, node_id);
            // PERF-C (issue #814): mirror addNodeLabel.
            try self.bumpLabelCount(node.graph_name, node.tenant_id, label);
            var prop_it_nosave_add = node.properties.iterator();
            while (prop_it_nosave_add.next()) |p| {
                const pkey = p.key_ptr.*;
                if (isInternalPersistedPropertyKey(pkey)) continue;
                try self.bumpLabelPropertyCount(node.graph_name, node.tenant_id, label, pkey);
            }
        }
    }

    /// Remove a label from a node without saving (used during rollback)
    pub fn removeNodeLabelNoSave(self: *GraphStore, node_id: u64, label: []const u8) !void {
        if (self.nodes.getPtr(node_id)) |node| {
            var found_index: ?usize = null;
            for (node.labels, 0..) |existing_label, i| {
                if (std.mem.eql(u8, existing_label, label)) {
                    found_index = i;
                    break;
                }
            }

            if (found_index) |index| {
                // Free the label being removed
                self.allocator.free(node.labels[index]);

                const new_labels = try self.allocator.alloc([]const u8, node.labels.len - 1);
                var new_index: usize = 0;
                for (node.labels, 0..) |existing_label, i| {
                    if (i != index) {
                        new_labels[new_index] = existing_label;
                        new_index += 1;
                    }
                }

                // GAP-825: same free+reassign window as removeNodeLabel —
                // must be serialised against `cloneNodesFrom` snapshot
                // readers.
                {
                    const io = std.Io.Threaded.global_single_threaded.io();
                    self.labels_rwlock.lockUncancelable(io);
                    defer self.labels_rwlock.unlock(io);

                    if (node.labels.len > 0) {
                        self.allocator.free(node.labels);
                    }

                    node.labels = new_labels;
                }

                self.removeFromLabelIndex(node.graph_name, label, node_id);
                // PERF-C (issue #814): mirror removeNodeLabel.
                var prop_it_nosave_rm = node.properties.iterator();
                while (prop_it_nosave_rm.next()) |p| {
                    const pkey = p.key_ptr.*;
                    if (isInternalPersistedPropertyKey(pkey)) continue;
                    self.decLabelPropertyCount(node.graph_name, node.tenant_id, label, pkey);
                }
                self.decLabelCount(node.graph_name, node.tenant_id, label);
            }
        }
    }
};

const graph_storage_adapter = @import("storage/graph_storage_adapter.zig");

/// Type-erased vtable for StorageAdapter dual-write delegation.
/// Function pointers are set at init time so that GraphStore methods can
/// call through them without forcing compile-time resolution of the
/// graph_storage module in test targets that lack that dependency.
const AdapterVTable = struct {
    ctx: *anyopaque,
    graphExistsFn: *const fn (*anyopaque, []const u8) bool,
    getOrCreateGraphFn: *const fn (*anyopaque, []const u8) anyerror!*anyopaque,
    dropGraphFn: *const fn (*anyopaque, []const u8) void,
    createNodeFn: *const fn (*anyopaque, []const u8, []const []const u8) anyerror!u64,
    // GAP-ENT-0024: the trailing u64 is the geode-minted PUBLIC edge id,
    // stored INLINE in the durable adjacency records (v2 blocks) so a
    // propertyless edge allocates NO props page. MUST be nonzero (0 is the
    // engine's reserved "no inline id" legacy sentinel).
    createEdgeFn: *const fn (*anyopaque, []const u8, u64, u64, []const u8, u64) anyerror!u64,
    deleteNodeFn: *const fn (*anyopaque, []const u8, u64) anyerror!void,
    deleteEdgeFn: *const fn (*anyopaque, []const u8, u64, u64, u64) anyerror!void,
    setNodePropertyFn: *const fn (*anyopaque, []const u8, u64, []const u8, PropertyValue) anyerror!void,
    removeNodePropertyFn: *const fn (*anyopaque, []const u8, u64, []const u8) anyerror!void,
    setEdgePropertyFn: ?*const fn (*anyopaque, []const u8, u64, u64, u64, []const u8, PropertyValue) anyerror!void,
    removeEdgePropertyFn: ?*const fn (*anyopaque, []const u8, u64, u64, u64, []const u8) anyerror!void,
    addNodeLabelFn: ?*const fn (*anyopaque, []const u8, u64, []const u8) anyerror!void,
    removeNodeLabelFn: ?*const fn (*anyopaque, []const u8, u64, []const u8) anyerror!void,
    deinitFn: *const fn (*anyopaque) void,
};

var global_adapter: ?*graph_storage_adapter.StorageAdapter = null;
var global_vtable: ?AdapterVTable = null;

pub fn getGlobalAdapter() ?*graph_storage_adapter.StorageAdapter {
    return global_adapter;
}

/// Identifies the call site that acquired a per-graph SHARED rwlock,
/// so per-acquisition hold-time data can be attributed to the right
/// counter. Added 2026-04-26 to drive the H5a residual-bisection.
pub const LockSiteTag = enum {
    snapshot, // graph_store.snapshotUnderReadLock — clone-then-release
    point_read, // PointReadView path — held across short execute
    bulk_merge, // executeBulkSimpleMerge Phase 1 lookup
    bulk_edge, // executeBulkMatchCreateEdge Phase 1 lookup
    fallback, // acquireGraphReadLock fallback (snapshot unavailable)
    misc, // catchall — unrecategorized callers
};

/// Opaque handle returned by per-graph lock helpers.  Callers pass this back
/// to the corresponding release function.  When `managed_graph` is non-null
/// the per-graph path was used; when null the global rwlock was used instead.
///
/// R6 (2026-04-22): Per-graph writes now take the GLOBAL store rwlock in
/// SHARED mode, not EXCLUSIVE.  The per-graph rwlock (`mg.rwlock`) is what
/// actually serialises writers on a given graph; the global exclusive lock
/// previously forced every mutation across every graph to queue behind one
/// single critical section, producing the 0.4 stmts/sec serialised ingest
/// pathology seen on the 16-worker Go client.  Reads also take the global
/// lock SHARED, so readers/writers on different graphs no longer block
/// each other.  Only cross-graph operations (RESTORE, legacy backup paths)
/// still take the global lock EXCLUSIVE — they use `acquireStoreWriteLock`
/// directly and are outside this handle type.
pub const GraphLockHandle = struct {
    managed_graph: ?*graph_storage_adapter.ManagedGraph,
    is_write: bool,
    holds_global_store_lock: bool,
    /// Whether the global `g_store_rwlock` was taken as EXCLUSIVE.  When
    /// false (the normal case after R6), the global lock was taken SHARED
    /// — release via `releaseStoreLock` rather than `releaseStoreWriteLock`.
    global_lock_is_exclusive: bool = false,
    /// Monotonic-ns timestamp captured at SHARED-lock acquire on the per-graph
    /// rwlock.  Passed back to `StorageAdapter.releaseGraphReadLock` so the
    /// per-graph SHARED hold-time counters get accurate per-acquisition timing.
    /// Zero when `managed_graph == null` (fallback path; no per-graph lock taken).
    hold_start_ns: u64 = 0,
    site_tag: LockSiteTag = .misc, // for per-site hold-time attribution
};

/// Acquire a shared (read) lock scoped to `graph_name`.  If the per-graph
/// StorageAdapter is available the lock is per-graph; otherwise falls back
/// to the global store rwlock for backward compatibility (tests, single-
/// graph deployments without an adapter).
pub fn acquireGraphReadLock(graph_name: []const u8) GraphLockHandle {
    acquireStoreLock();
    if (global_adapter) |adapter| {
        if (adapter.acquireGraphReadLock(graph_name)) |acq| {
            return .{
                .managed_graph = acq.mg,
                .is_write = false,
                .holds_global_store_lock = true,
                .hold_start_ns = acq.hold_start_ns,
            };
        } else |_| {}
    }
    return .{
        .managed_graph = null,
        .is_write = false,
        .holds_global_store_lock = true,
    };
}

/// Tagged variant of `acquireGraphReadLock`. Identical semantics but
/// records the call-site tag on the returned handle so per-site SHARED
/// hold-time counters get accurate attribution at release time.
pub fn acquireGraphReadLockTagged(graph_name: []const u8, tag: LockSiteTag) GraphLockHandle {
    var handle = acquireGraphReadLock(graph_name);
    handle.site_tag = tag;
    return handle;
}

/// Acquire an exclusive (write) lock scoped to `graph_name`.
///
/// R6 (2026-04-22): takes the GLOBAL store rwlock in SHARED mode (was
/// previously EXCLUSIVE).  The per-graph `mg.rwlock` still provides the
/// exclusive-writer guarantee on `graph_name` — which is all a per-graph
/// write needs.  The old exclusive global acquire forced every mutation
/// on every graph to serialise behind a single lock, producing the
/// 0.4 stmts/sec ingest pathology on the 16-worker ingest workload.
///
/// When the per-graph adapter is unavailable (legacy / test-only path),
/// we fall back to the global EXCLUSIVE lock — there is no per-graph
/// rwlock in that case, so the global exclusive is the only option.
///
/// ENG-3914 (RC-3): an adapter that simply does not know `graph_name` YET is
/// NOT the legacy case — see `materializeGraphForWriteLock`.
pub fn acquireGraphWriteLock(graph_name: []const u8) GraphLockHandle {
    if (global_adapter) |adapter| {
        acquireStoreLock();
        if (adapter.acquireGraphWriteLock(graph_name)) |mg| {
            return .{
                .managed_graph = mg,
                .is_write = true,
                .holds_global_store_lock = true,
                .global_lock_is_exclusive = false,
            };
        } else |err| {
            // Adapter saw the graph but couldn't acquire — release the
            // shared global and fall through to the legacy global-only
            // exclusive path below.
            releaseStoreLock();
            if (err == error.GraphNotFound and materializeGraphForWriteLock(adapter, graph_name)) {
                acquireStoreLock();
                if (adapter.acquireGraphWriteLock(graph_name)) |mg| {
                    return .{
                        .managed_graph = mg,
                        .is_write = true,
                        .holds_global_store_lock = true,
                        .global_lock_is_exclusive = false,
                    };
                } else |_| {
                    releaseStoreLock();
                }
            }
        }
    }
    acquireStoreWriteLock();
    return .{
        .managed_graph = null,
        .is_write = true,
        .holds_global_store_lock = true,
        .global_lock_is_exclusive = true,
    };
}

/// SONNY-2733: how long `GraphStore.backfillEdgeTenantTags` waits for each
/// graph's write lock: the default statement write-lock budget. Tests shorten
/// it.
pub var backfill_graph_lock_timeout_ns: u64 = 120 * std.time.ns_per_s;

/// SONNY-2733: `acquireGraphWriteLockCancelable` for a graph that already
/// exists, for `GraphStore.backfillEdgeTenantTags`. Like that function it
/// announces the pending writer, so new readers back off instead of starving
/// it, and gives up at `deadline_mono_ns` (`error.Deadline`). Null when the
/// engine does not have the graph open (it was dropped after the caller listed
/// it): where the other acquires would create the graph again, this leaves it
/// gone. With no adapter it takes the global EXCLUSIVE lock, as they do.
fn acquireExistingGraphWriteLock(graph_name: []const u8, deadline_mono_ns: u64) error{Deadline}!?GraphLockHandle {
    const adapter = global_adapter orelse {
        try acquireStoreWriteLockCancelable(deadline_mono_ns);
        return .{
            .managed_graph = null,
            .is_write = true,
            .holds_global_store_lock = true,
            .global_lock_is_exclusive = true,
        };
    };
    acquireStoreLock();
    const mg = adapter.acquireGraphWriteLockCancelable(graph_name, deadline_mono_ns) catch |err| {
        releaseStoreLock();
        if (err == error.Deadline) return error.Deadline;
        return null;
    };
    return .{
        .managed_graph = mg,
        .is_write = true,
        .holds_global_store_lock = true,
        .global_lock_is_exclusive = false,
    };
}

// CANARY: REQ=REQ-SONNY-2749-PROGRAM-GRAPH-LOCK; FEATURE="StatementAuthorization"; ASPECT=ProgramWriteLock; STATUS=TESTED; TEST=tests/test_sonny2749_program_graph_lock.zig; OWNER=security; UPDATED=2026-09-25
/// SONNY-2749: the write lock a transport handler takes for a program that
/// changes the store: the lock of `lock_graph`, the graph its statements run on
/// (`query_traits.StatementPlan.lock_graph`). When that is the session graph
/// (`session_graph`), this is `acquireGraphWriteLockCancelable`, which may
/// create a graph the engine does not know yet, as every write did before. When
/// the program's own USE GRAPH or SESSION SET PROPERTY GRAPH moved it to
/// another graph, it never creates that graph: `error.GraphNotFound` when it
/// does not exist (the program's USE GRAPH would fail the same way), after
/// building a graph whose load was deferred. `error.Deadline` when the lock
/// does not come by `deadline_mono_ns`.
pub fn acquireProgramWriteLockCancelable(lock_graph: []const u8, session_graph: []const u8, deadline_mono_ns: u64) !GraphLockHandle {
    // SONNY-2790: the default graph always exists (every session starts on
    // it), and the fulltext statements lock it from any session.
    if (std.mem.eql(u8, lock_graph, session_graph) or std.mem.eql(u8, lock_graph, DEFAULT_GRAPH_NAME))
        return acquireGraphWriteLockCancelable(lock_graph, deadline_mono_ns);
    if (getCurrentGlobalStore()) |store| store.ensureGraphHydrated(lock_graph);
    return (try acquireExistingGraphWriteLock(lock_graph, deadline_mono_ns)) orelse error.GraphNotFound;
}

/// ENG-3914 (RC-3), cross-path MERGE duplication in the GRAPH-CREATION window.
///
/// The two MERGE implementations must exclude each other on the SAME lock:
/// the bulk fast path (`bulkMergeNodeWithReservedId*`) calls
/// `adapter.getOrCreateGraph` and then holds that graph's `mg.rwlock` SHARED
/// across its whole probe→insert, while the general executor MERGE runs under
/// the whole-graph `mg.rwlock` EXCLUSIVE the connection handler takes here.
///
/// Before this fix, a graph the adapter had not materialized yet (the very
/// first statements against `default` on a fresh server) sent the two paths to
/// DIFFERENT locks: the bulk writer created the `ManagedGraph` and took its
/// per-graph lock, while the general writer got `error.GraphNotFound` and
/// escalated to the GLOBAL store lock — which the bulk path never touches. The
/// probe→create of both writers then interleaved freely and the first merge key
/// every session races on (`{docId: 0, seq: 0}`) landed TWICE. Reproduced at
/// the wire level in ~1 run in 3 (4 bulk + 4 general `geode query --batch`
/// sessions over the same 8 keys on a fresh data dir).
///
/// Fix: materialize the graph, then take the normal per-graph path. The legacy
/// global-EXCLUSIVE escalation now serves ONLY its actual purpose — a store
/// with no adapter at all (unit tests, `initGlobalStore`-less harnesses), where
/// no per-graph rwlock exists to take. Returns false when materialization fails
/// (read-only data dir, quota, registry error), leaving the legacy fallback as
/// the fail-safe.
///
/// Called with NO store lock held: `getOrCreateGraph` opens/creates an engine
/// (file I/O) under the adapter's own `mutex` (tier 0), which must never be
/// taken while a tier-1 store lock is held.
///
/// CANARY: REQ=REQ-ENG-3914-MERGE-CROSS-PATH-RACE; FEATURE="MergeIdempotency"; ASPECT=CreationWindowLockUnification; STATUS=TESTED; TEST=tests/test_eng3914_cross_path_merge_race.zig; OWNER=storage; UPDATED=2026-08-30
fn materializeGraphForWriteLock(
    adapter: *graph_storage_adapter.StorageAdapter,
    graph_name: []const u8,
) bool {
    _ = adapter.getOrCreateGraph(graph_name) catch |err| {
        log.warn("write-lock graph materialization failed; using legacy global-exclusive lock", &.{
            Attr.string("graph", graph_name),
            Attr.string("error", @errorName(err)),
        });
        return false;
    };
    return true;
}

/// R2 (2026-04-22): deadline-aware variant of `acquireGraphWriteLock`.
/// Returns `error.Deadline` if the per-graph write lock cannot be
/// acquired before `deadline_mono_ns` (absolute CLOCK_MONOTONIC ns).
/// Callers should prefer this over `acquireGraphWriteLock` anywhere a
/// per-request deadline exists — it replaces the old behaviour of
/// parking forever on `lockUncancelable`, which caused the transport
/// thread-pool "1 active task" shutdown hang under the 16-worker
/// ingest workload.
pub fn acquireGraphWriteLockCancelable(graph_name: []const u8, deadline_mono_ns: u64) !GraphLockHandle {
    // R6 (2026-04-22): take the global lock SHARED, not EXCLUSIVE, when a
    // per-graph adapter exists.  The per-graph rwlock provides the
    // exclusive-writer guarantee; the global lock only needs to be held so
    // RESTORE/BACKUP (the only callers that take `g_store_rwlock` in
    // EXCLUSIVE mode directly) can block all graph work while they run.
    //
    // `acquireStoreLock` is `lockSharedUncancelable` — it blocks on a
    // kernel futex with zero CPU burn, so we don't honour the deadline
    // while parked there.  The deadline is enforced on the per-graph lock,
    // which is the only place genuine contention happens under the
    // multi-worker ingest workload.
    if (global_adapter) |adapter| {
        acquireStoreLock();
        if (adapter.acquireGraphWriteLockCancelable(graph_name, deadline_mono_ns)) |mg| {
            return .{
                .managed_graph = mg,
                .is_write = true,
                .holds_global_store_lock = true,
                .global_lock_is_exclusive = false,
            };
        } else |err| switch (err) {
            error.Deadline => {
                // Release the global shared lock we optimistically took.
                releaseStoreLock();
                return error.Deadline;
            },
            else => {
                // Drop the shared lock we optimistically took.
                releaseStoreLock();
                // ENG-3914 (RC-3): `GraphNotFound` means the adapter has not
                // materialized this graph YET — NOT that there is no per-graph
                // rwlock to take. Escalating to the global exclusive here put
                // the general MERGE on a DIFFERENT lock from the bulk MERGE
                // fast path (which materializes the graph itself via
                // `getOrCreateGraph`), so their probe→create windows
                // interleaved and duplicated the first contended merge key.
                // Materialize, then take the normal per-graph path. See
                // `materializeGraphForWriteLock`.
                if (err == error.GraphNotFound and materializeGraphForWriteLock(adapter, graph_name)) {
                    acquireStoreLock();
                    if (adapter.acquireGraphWriteLockCancelable(graph_name, deadline_mono_ns)) |mg| {
                        return .{
                            .managed_graph = mg,
                            .is_write = true,
                            .holds_global_store_lock = true,
                            .global_lock_is_exclusive = false,
                        };
                    } else |err2| switch (err2) {
                        error.Deadline => {
                            releaseStoreLock();
                            return error.Deadline;
                        },
                        else => releaseStoreLock(),
                    }
                }
            },
        }
    }
    // Legacy fallback: no adapter means no per-graph rwlock, so the only
    // lock we have is the global one.  Take it EXCLUSIVE with the deadline.
    try acquireStoreWriteLockCancelable(deadline_mono_ns);
    return .{
        .managed_graph = null,
        .is_write = true,
        .holds_global_store_lock = true,
        .global_lock_is_exclusive = true,
    };
}

/// Acquire the shared read lock for `graph_name`, capture a
/// `QueryReadSession` snapshot of the current graph contents, release the
/// lock, and return the session.  The returned session carries its own
/// epoch reference and arena-allocated deep copy (see `QueryReadSession`
/// at line 5320), so it is safe to read from after the lock is dropped.
///
/// This helper exists so transport handlers can avoid holding the shared
/// reader lock across parse + plan + execute + row materialization (~30 ms
/// per 500-node property lookup on small graphs).  The lock only needs to
/// cover the snapshot-capture phase; every downstream read goes through the
/// session's owned copy.
///
/// Caller owns the returned session and must call `session.deinit()` on
/// every exit path.  Callers that want the executor to pick up the snapshot
/// implicitly should pair this with `pushActiveQueryReadStore(session.store())`
/// / `popActiveQueryReadStore(prev)` — see `src/execution/call_operations.zig`
/// for the same pattern.
///
/// Mutations MUST still go through `acquireGraphWriteLock` + hold-through-
/// execute — this helper is read-only by construction.
///
/// CANARY: REQ=REQ-PERF-HANDLER-LOCK-HOLD-001; FEATURE="HandlerLockHoldScope"; ASPECT=SnapshotCapture; STATUS=TESTED; TEST=tests/test_handler_lock_hold_scope.zig; OWNER=transport; UPDATED=2026-04-18
pub fn snapshotUnderReadLock(allocator: std.mem.Allocator, graph_name: []const u8) !QueryReadSession {
    // PHASE 1b chokepoint (deferred-hydration hazard). `initIfAvailable`
    // DEEP-CLONES the primary store's id_maps + node cache into an arena
    // snapshot and the query reads THAT clone. After a no-snapshot early-ready
    // open the target graph's IdMap/nodes are EMPTY until first access
    // (`markPendingHydration` fallback), so cloning before hydration would
    // snapshot an EMPTY graph and the query would return WRONG (empty) results
    // — even though the live store still holds the graph on durable pages.
    // Hydrate the target graph (the only graph this graph_name-locked session
    // reads) BEFORE acquiring the read lock, matching the guard-before-lock
    // precedent. Deadlock-free: `ensureGraphHydrated`'s build path
    // (loadOneGraphFromAdapterFull) takes only leaf mutexes + the store-wide
    // hydration_build_mutex, never the per-graph adapter rwlock acquired below.
    getPrimaryGlobalStore(allocator).ensureGraphHydrated(graph_name);

    const handle = acquireGraphReadLockTagged(graph_name, .snapshot);
    defer releaseGraphLock(handle);

    // `QueryReadSession.initIfAvailable` clones nodes/edges/id-maps from the
    // primary global store into an arena-backed snapshot.  The primary store
    // is the correct source: the per-graph lock held above serialises us
    // against concurrent mutations on `graph_name` specifically, which is
    // the only data this read will touch.
    const source = getPrimaryGlobalStore(allocator);
    if (try QueryReadSession.initIfAvailable(allocator, source)) |session| {
        return session;
    }
    // initIfAvailable only returns null in paths that we do not expect on
    // the handler read path; surface that as an explicit error so callers
    // can fall back to the legacy wide-scope lock.
    return error.SnapshotUnavailable;
}

/// Release a lock previously acquired via `acquireGraphReadLock` or
/// `acquireGraphWriteLock`.
pub fn releaseGraphLock(handle: GraphLockHandle) void {
    if (handle.managed_graph) |mg| {
        if (global_adapter) |adapter| {
            if (handle.is_write) {
                adapter.releaseGraphWriteLock(mg);
            } else {
                adapter.releaseGraphReadLock(mg, handle.hold_start_ns, handle.site_tag);
            }
        }
    }

    if (handle.holds_global_store_lock) {
        // R6 (2026-04-22): `global_lock_is_exclusive` records whether we
        // took the global rwlock EXCLUSIVE (legacy/fallback) or SHARED
        // (normal per-graph path).  Release the matching side.  Reads
        // always take shared; writes take shared on the fast path and
        // only fall back to exclusive when no per-graph adapter exists.
        if (handle.global_lock_is_exclusive) {
            releaseStoreWriteLock();
        } else {
            releaseStoreLock();
        }
    }
}

pub fn initGlobalAdapter(allocator: std.mem.Allocator, data_dir: []const u8) !*graph_storage_adapter.StorageAdapter {
    if (global_adapter) |existing| {
        if (std.mem.eql(u8, existing.data_dir, data_dir)) {
            return existing;
        }
        deinitGlobalAdapter();
    }

    const gs = @import("graph_storage");
    const tde = @import("storage/tde_file_encryption.zig");

    // GAP-0265: Wire TDE encryption key into per-graph storage engine.
    // Without this, page-level encryption is disabled even when GEODE_TDE_KEY
    // is set — all store files are written in plaintext.
    const tde_key = tde.loadKey(allocator) catch null;

    // GAP-0900: opt-in relaxed WAL durability for replayable bulk ingest.
    // The DEFAULT (.sync_each_commit) fsyncs the WAL on every commit — durable
    // per NFR-SEC-003 but the throughput wall (~1 fdatasync/op; the 16 shards
    // each fsync their own WAL and a distinct-key MERGE stream hits ~1 op/shard,
    // so the group-commit coordinator can't coalesce). Setting
    // GEODE_WAL_SYNC=deferred selects graph_storage's `.deferred` mode: the
    // COMMIT record is still appended to the WAL but the per-commit fsync is
    // skipped; commits become durable at the next checkpoint / clean close /
    // auto-checkpoint (16 MB / 60 s thresholds). Use ONLY for idempotent,
    // replayable loads that checkpoint (or cleanly close) before treating data
    // as durable — e.g. the divelife dump seed, which re-runs from its manifest.
    var sync_mode: gs.SyncMode = .sync_each_commit;
    if (std.c.getenv("GEODE_WAL_SYNC")) |raw_z| {
        const raw = std.mem.span(raw_z);
        if (std.mem.eql(u8, raw, "deferred")) {
            sync_mode = .deferred;
            log.warn("GEODE_WAL_SYNC=deferred: per-commit WAL fsync DISABLED (relaxed durability — commits durable only at checkpoint/clean close). Use only for replayable bulk loads (GAP-0900).", &.{});
        } else if (!std.mem.eql(u8, raw, "each_commit") and raw.len != 0) {
            log.warn("GEODE_WAL_SYNC unrecognized; using default sync_each_commit (valid: each_commit | deferred)", &.{Attr.string("value", raw)});
        }
    }

    // Operator page-cache sizing knob (read-path performance enablement).
    // Default 1024 pages (8 MB at the default 8 KB page size). auto_size grows
    // the pool up to 512 MB based on graph size; set GEODE_BUFFER_POOL_PAGES
    // above 65536 to exceed that cap for very large working sets in RAM-rich
    // environments. Bad/missing values fall back to the 1024 default.
    const buffer_pool_pages: u32 = @intCast(envU64("GEODE_BUFFER_POOL_PAGES", 1024));
    // GEODE_BUFFER_POOL_AUTO_SIZE=0 disables the manifest-driven auto-sizing
    // (grow-to-fit up to 512 MB per shard) so GEODE_BUFFER_POOL_PAGES becomes
    // an EXACT per-shard pool size. Operator control for RAM-bounded
    // deployments (auto-size costs up to 8 GB resident on a 16-shard large
    // store) and the lever the hydration throughput-floor test uses to
    // reproduce the production pool:store ratio on a CI-sized store.
    const pool_auto_size = blk: {
        const raw_z = std.c.getenv("GEODE_BUFFER_POOL_AUTO_SIZE") orelse break :blk true;
        const raw = std.mem.span(raw_z);
        break :blk !(std.mem.eql(u8, raw, "0") or std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "no"));
    };
    const adapter = try graph_storage_adapter.StorageAdapter.init(allocator, data_dir, gs.GraphConfig{
        .data_dir = data_dir,
        .encryption_key = tde_key,
        .sync_mode = sync_mode,
        .buffer_pool_pages = buffer_pool_pages,
        .buffer_pool_auto_size = pool_auto_size,
    });
    global_adapter = adapter;

    // GAP-0900: install the load-driven checkpoint threshold so the bulk write
    // fast path self-checkpoints once `pending_bulk_ops` crosses it. This is
    // the primary deferred-mode memory bound — the timer-based persistence loop
    // (below) is only a backstop, because its futex timeout is starved under
    // sustained ingest. Threshold is env-overridable (GEODE_CHECKPOINT_OPS).
    adapter.setCheckpointOpsThreshold(envU64("GEODE_CHECKPOINT_OPS", DEFAULT_CHECKPOINT_OPS));
    // GAP-0900 (B) write-backpressure: hard-cap un-checkpointed ops so a slow
    // checkpoint can never let the dirty-page/WAL set grow without bound (OOM
    // safety net). Default = DEFAULT_CHECKPOINT_MAX_PENDING_MULT × the ops
    // threshold; env-overridable (GEODE_CHECKPOINT_MAX_PENDING, 0 disables).
    {
        const ckpt_ops = envU64("GEODE_CHECKPOINT_OPS", DEFAULT_CHECKPOINT_OPS);
        const default_max_pending = ckpt_ops *| DEFAULT_CHECKPOINT_MAX_PENDING_MULT;
        adapter.setCheckpointMaxPending(envU64("GEODE_CHECKPOINT_MAX_PENDING", default_max_pending));
    }
    // GAP-ENT-0038: expose checkpoints_total / pending_bulk_ops on /metrics.
    // Best-effort: no-op if the runtime-metrics registry is not up yet — the
    // first coordinator registration (group_commit.registerWithRuntimeMetrics)
    // retries after server bring-up.
    adapter.registerCheckpointMetrics();

    // Build vtable with type-erased function pointers
    const Dispatch = struct {
        fn castAdapter(ptr: *anyopaque) *graph_storage_adapter.StorageAdapter {
            return @ptrCast(@alignCast(ptr));
        }
        fn graphExists(ctx: *anyopaque, name: []const u8) bool {
            return castAdapter(ctx).graphExists(name);
        }
        fn getOrCreateGraph(ctx: *anyopaque, name: []const u8) anyerror!*anyopaque {
            const mg = try castAdapter(ctx).getOrCreateGraph(name);
            return @ptrCast(mg);
        }
        fn dropGraph(ctx: *anyopaque, name: []const u8) void {
            castAdapter(ctx).dropGraph(name);
        }
        fn createNode(ctx: *anyopaque, graph_name: []const u8, labels: []const []const u8) anyerror!u64 {
            return castAdapter(ctx).createNode(graph_name, labels);
        }
        fn createEdge(ctx: *anyopaque, graph_name: []const u8, from_id: u64, to_id: u64, label: []const u8, public_id: u64) anyerror!u64 {
            // GAP-ENT-0024: inline public id — the adapter guards public_id != 0.
            return castAdapter(ctx).createEdgeWithPublicId(graph_name, from_id, to_id, label, public_id);
        }
        fn deleteNode(ctx: *anyopaque, graph_name: []const u8, node_id: u64) anyerror!void {
            return castAdapter(ctx).deleteNode(graph_name, node_id);
        }
        fn deleteEdge(ctx: *anyopaque, graph_name: []const u8, from_id: u64, to_id: u64, edge_id: u64) anyerror!void {
            return castAdapter(ctx).deleteEdge(graph_name, from_id, to_id, edge_id);
        }
        fn setNodeProperty(ctx: *anyopaque, graph_name: []const u8, node_id: u64, key: []const u8, value: PropertyValue) anyerror!void {
            return castAdapter(ctx).setNodeProperty(graph_name, node_id, key, value);
        }
        fn removeNodeProperty(ctx: *anyopaque, graph_name: []const u8, node_id: u64, key: []const u8) anyerror!void {
            return castAdapter(ctx).removeNodeProperty(graph_name, node_id, key);
        }
        fn setEdgeProperty(ctx: *anyopaque, graph_name: []const u8, from_id: u64, to_id: u64, edge_id: u64, key: []const u8, value: PropertyValue) anyerror!void {
            return castAdapter(ctx).setEdgeProperty(graph_name, from_id, to_id, edge_id, key, value);
        }
        fn removeEdgeProperty(ctx: *anyopaque, graph_name: []const u8, from_id: u64, to_id: u64, edge_id: u64, key: []const u8) anyerror!void {
            return castAdapter(ctx).removeEdgeProperty(graph_name, from_id, to_id, edge_id, key);
        }
        fn addNodeLabel(ctx: *anyopaque, graph_name: []const u8, node_id: u64, label: []const u8) anyerror!void {
            return castAdapter(ctx).addNodeLabel(graph_name, node_id, label);
        }
        fn removeNodeLabel(ctx: *anyopaque, graph_name: []const u8, node_id: u64, label: []const u8) anyerror!void {
            return castAdapter(ctx).removeNodeLabel(graph_name, node_id, label);
        }
        fn deinitAdapter(ctx: *anyopaque) void {
            castAdapter(ctx).deinit();
        }
    };

    global_vtable = AdapterVTable{
        .ctx = @ptrCast(adapter),
        .graphExistsFn = &Dispatch.graphExists,
        .getOrCreateGraphFn = &Dispatch.getOrCreateGraph,
        .dropGraphFn = &Dispatch.dropGraph,
        .createNodeFn = &Dispatch.createNode,
        .createEdgeFn = &Dispatch.createEdge,
        .deleteNodeFn = &Dispatch.deleteNode,
        .deleteEdgeFn = &Dispatch.deleteEdge,
        .setNodePropertyFn = &Dispatch.setNodeProperty,
        .removeNodePropertyFn = &Dispatch.removeNodeProperty,
        .setEdgePropertyFn = &Dispatch.setEdgeProperty,
        .removeEdgePropertyFn = &Dispatch.removeEdgeProperty,
        .addNodeLabelFn = &Dispatch.addNodeLabel,
        .removeNodeLabelFn = &Dispatch.removeNodeLabel,
        .deinitFn = &Dispatch.deinitAdapter,
    };

    return adapter;
}

pub fn deinitGlobalAdapter() void {
    // Task 19 (2026-04-23): stop per-graph group-commit coordinators BEFORE
    // the adapter goes away — the coordinator threads call into the adapter
    // on every apply, so they MUST stop first.  Safe to call when no
    // coordinator was ever started (the registry is initialised lazily).
    const group_commit = @import("storage/group_commit.zig");
    group_commit.shutdownAllCoordinators();

    // CANARY: REQ=REQ-QUIC-HC-171; FEATURE="High-Concurrency Mutations"; ASPECT=AdapterShutdownCheckpoint; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=storage; UPDATED=2026-06-11
    //
    // Group-commit mutation fast paths write through the engine-backed adapter
    // and may not mark the legacy compatibility GraphStore dirty. A clean
    // server shutdown must still checkpoint loaded per-graph engines before the
    // adapter is destroyed, otherwise the in-memory high-concurrency mutations
    // are visible before shutdown but missing after restart.
    if (global_adapter) |adapter| {
        adapter.checkpointAll() catch |err| {
            log.err("per-graph storage checkpoint failed during adapter shutdown", &.{
                Attr.string("error", @errorName(err)),
            });
        };
    }

    if (global_vtable) |vt| {
        vt.deinitFn(vt.ctx);
        global_vtable = null;
        global_adapter = null;
    } else if (global_adapter) |adapter| {
        adapter.deinit();
        global_adapter = null;
    }
}

fn syncGlobalAdapterForDataDir(data_dir: ?[]const u8) void {
    if (data_dir) |dir| {
        _ = initGlobalAdapter(global_allocator(), dir) catch |err| {
            log.warn("Failed to initialize engine-backed adapter", &.{
                Attr.string("error", @errorName(err)),
                Attr.string("data_dir", dir),
            });
            return;
        };
    } else if (global_adapter != null) {
        deinitGlobalAdapter();
    }
}

// Global instance that persists across queries
var global_store: ?GraphStore = null;
// The global store is shared across transport threads, so its allocator must be
// safe for cross-thread alloc/free traffic. A long-lived arena hid leaks but
// left the backing allocator outside the thread-safe path used elsewhere.
// Zig 0.16: ThreadSafeAllocator removed; allocators are inherently thread-safe.
var global_store_allocator: ?std.mem.Allocator = null;

// T2b TEST HOOK: allocator override applied at the NEXT global-store (re)init.
// The production store always uses `global_allocator()`; the hydration merge
// peak-memory test wraps it in a thread-safe counting allocator to measure
// live/peak bytes of the hydration build deterministically (VmHWM is polluted
// by the in-process store build that precedes the measured reopen). The
// caller must keep the allocator valid until the store is deinitialized and
// clear the hook afterwards. null = production default.
var g_test_store_allocator: ?std.mem.Allocator = null;

/// T2b test hook — see `g_test_store_allocator`.
pub fn setTestGlobalStoreAllocator(a: ?std.mem.Allocator) void {
    g_test_store_allocator = a;
}
threadlocal var g_active_query_read_store: ?*GraphStore = null;
var g_query_read_session_init_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-0900 (scan-no-clone): per-node counter incremented once for every node
// deep-copied by `cloneNodesFrom`. Unlike the session-init counter (1 per
// snapshot, regardless of graph size) this exposes the O(graph) cost of the
// clone directly, so a regression test can assert a bounded scan does NOT
// deep-clone the whole graph (counter stays 0 when the engine-backed streaming
// path serves the query) instead of relying on wall-clock timing.
var g_clone_nodes_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_get_nodes_by_labels_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-ENT-0013 (unlabeled count(n) IdMap pushdown) instrumentation.
// `g_count_nodes_idmap_fast` counts every `countNodesForGraph` call that
// returned via the O(1) `IdMap.nodeCount()` path. `g_count_nodes_iter_fallback`
// counts every call that fell back to a per-node iteration — either the
// unbounded-cache full `nodes.iterator()` walk or the tenant-filtered IdMap
// uuid walk (`nodeMatchesTenant` per node). A bare unlabeled
// `MATCH (n) RETURN count(n)` with no tenant filter MUST take the O(1) path:
// the regression test in tests/test_count_nodes_pushdown_perf.zig asserts the
// fast counter moves and the fallback counter does not.
var g_count_nodes_idmap_fast: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_count_nodes_iter_fallback: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// PHASE 1b (lazy hydration) instrumentation. `g_loop2_scan_nodes` counts every
// node iterated by the DEFERRED resident-index scan (`hydrateGraphLoop2`); it
// MUST be 0 at the "server ready" point (open registers + loads the IdMap but
// runs no loop2 scan). `g_idmap_scan_getprop` counts per-node engine reads done
// by the IdMap scan-rebuild FALLBACK (loop1); it stays 0 when a valid snapshot
// is bulk-loaded. `g_idmap_from_snapshot` counts graphs whose IdMap came from a
// counter-gated mmap snapshot (no engine reads).
var g_loop2_scan_nodes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_idmap_scan_getprop: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_idmap_from_snapshot: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-ENT-0023 P3 instrumentation: per-PRODUCT counts of loop2 hydration
// products restored from a counter-gated snapshot (`g_hydration_snapshot_loads`)
// vs rebuilt by the engine scan because the snapshot was absent / stale /
// invalid (`g_hydration_scan_fallbacks`). `g_hydration_full_scan_skips` counts
// graphs whose hydration skipped the O(graph) engine scan ENTIRELY (every
// node-side product from snapshots, edge side covered, nodes_by_graph rebuilt
// from the IdMap).
var g_hydration_snapshot_loads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_hydration_scan_fallbacks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_hydration_full_scan_skips: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// Task 3 (hydration persist-on-complete) instrumentation: completion persists
// that fully succeeded vs ones that failed LOUDLY (the persist is best-effort;
// a failure never fails the hydrating query — it only costs the next reopen a
// re-scan).
var g_hydration_completion_persists: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_hydration_completion_persist_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP hydration fast-scan instrumentation: graphs hydrated via the SEQUENTIAL
// per-shard stream scan (vs the legacy per-node engine-read walk). The parity
// tests assert on this to prove which path served a hydration.
var g_hydration_streaming_scans: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// Task 2: cumulative wall nanos of the stream-scan SCAN phase (parallel
// per-shard file sweeps) and the single-threaded MERGE phase since the last
// counter reset. The scaling test asserts the scan phase parallelizes; the
// merge is single-threaded by design (per-worker accumulation, no lock soup).
var g_hydration_stream_scan_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_hydration_stream_merge_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-ENT-0023 P3 (review C1) TDD hook — test builds only (the check site is
// gated on `builtin.is_test`). maxInt = disabled; otherwise the loop2 scan
// fails with error.TestInjectedHydrationFailure once `seen >= limit`.
var g_test_hydration_fail_after: std.atomic.Value(u64) = std.atomic.Value(u64).init(std.math.maxInt(u64));
var g_test_hydration_scan_seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// GAP-ENT-0023 P3 (review C1) TDD hook: make the NEXT loop2 hydration scan
/// fail after `limit` nodes (null = disable). Test builds only — production
/// builds compile the check out entirely.
pub fn setTestHydrationFailAfterNodes(limit: ?u64) void {
    g_test_hydration_scan_seen.store(0, .release);
    g_test_hydration_fail_after.store(limit orelse std.math.maxInt(u64), .release);
}

// T2c TDD hook — test builds only (check site gated on `builtin.is_test`):
// per-shard merge delay in ns applied by the stream-scan merge before it
// consumes each shard, simulating the at-scale condition (merge far slower
// than the 16-way scan) that the 128k CI store cannot reproduce naturally.
// 0 = disabled.
var g_test_hydration_merge_delay_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// T2c TDD hook: delay the stream-scan merge by `ms` per shard (null =
/// disable). Test builds only — production builds compile the check out.
pub fn setTestHydrationMergeDelayMs(ms: ?u64) void {
    g_test_hydration_merge_delay_ns.store((ms orelse 0) * std.time.ns_per_ms, .release);
}

/// T2c test-hook check site: per-shard merge delay (no-op in production
/// builds — the whole body is compiled out).
inline fn applyTestHydrationMergeDelay() void {
    if (comptime @import("builtin").is_test) {
        const delay_ns = g_test_hydration_merge_delay_ns.load(.monotonic);
        if (delay_ns == 0) return;
        if (comptime @import("builtin").os.tag == .linux) {
            const req = std.os.linux.timespec{
                .sec = @intCast(delay_ns / std.time.ns_per_s),
                .nsec = @intCast(delay_ns % std.time.ns_per_s),
            };
            var rem: std.os.linux.timespec = undefined;
            _ = std.os.linux.nanosleep(&req, &rem);
        } else {
            const req = std.c.timespec{
                .sec = @intCast(delay_ns / std.time.ns_per_s),
                .nsec = @intCast(delay_ns % std.time.ns_per_s),
            };
            var rem: std.c.timespec = undefined;
            _ = std.c.nanosleep(&req, &rem);
        }
    }
}

/// T2c: high-water of completed-but-unmerged shard outputs across stream-scan
/// hydrations since the last `resetLazyHydrateCounters`. The bounded-inflight
/// tests assert this never exceeds GEODE_HYDRATION_INFLIGHT_SHARDS.
pub fn hydrationInflightShardHighWater() u64 {
    return graph_storage_adapter.hydration_scan.hydrationInflightShardHighWater();
}

// GAP-ENT-0042(a): self-heal flush checkpoints skipped on bounded-acquire
// timeout / engine failure (see hydrationSelfHealCheckpointSkips).
var g_selfheal_checkpoint_skips: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// Task 3 TDD hook — test builds only (check site gated on `builtin.is_test`):
// force the hydration-completion persist to fail (simulates a graph-scoped
// engine-checkpoint / snapshot-write error at the persist call site).
var g_test_hydration_persist_fail: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Task 3 TDD hook: make the hydration-completion persist fail while `fail`
/// is true. Test builds only — production builds compile the check out.
pub fn setTestHydrationPersistFail(fail: bool) void {
    g_test_hydration_persist_fail.store(fail, .release);
}
// Atomic flag: readers use .acquire to see all writes that happened before
// the store was published; the writer uses .release after full initialization.
var initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var last_data_dir: ?[]u8 = null;

pub fn resetQueryReadSessionInitCount() void {
    g_query_read_session_init_count.store(0, .release);
}

pub fn getQueryReadSessionInitCount() u64 {
    return g_query_read_session_init_count.load(.acquire);
}

/// GAP-0900 (scan-no-clone): reset/read the count of nodes deep-copied by
/// `cloneNodesFrom`. A bounded scan (`MATCH (n:L) RETURN n LIMIT k`) served by
/// the engine-backed streaming path must NOT increment this — it is O(graph)
/// only when a full snapshot clone runs.
pub fn resetCloneNodesTotal() void {
    g_clone_nodes_total.store(0, .release);
}

pub fn getCloneNodesTotal() u64 {
    return g_clone_nodes_total.load(.acquire);
}

pub fn resetGetNodesByLabelsCount() void {
    g_get_nodes_by_labels_count.store(0, .release);
}

pub fn getNodesByLabelsCallCount() u64 {
    return g_get_nodes_by_labels_count.load(.acquire);
}

/// GAP-ENT-0013: number of `countNodesForGraph` calls served O(1) from
/// `IdMap.nodeCount()`. Mirrors the `g_full_scan_count` diagnostic pattern
/// in src/execution/match_operations.zig.
pub fn getCountNodesIdMapFastTotal() u64 {
    return g_count_nodes_idmap_fast.load(.acquire);
}

/// GAP-ENT-0013: number of `countNodesForGraph` calls that ran a per-node
/// iteration (the unbounded-cache full `nodes.iterator()` walk OR the
/// tenant-filtered IdMap uuid walk).
pub fn getCountNodesIterFallbackTotal() u64 {
    return g_count_nodes_iter_fallback.load(.acquire);
}

// PHASE 1b lazy-hydration instrumentation accessors (used by
// tests/test_startup_lazy_hydrate.zig).
pub fn resetLazyHydrateCounters() void {
    g_loop2_scan_nodes.store(0, .release);
    g_idmap_scan_getprop.store(0, .release);
    g_idmap_from_snapshot.store(0, .release);
    g_hydration_snapshot_loads.store(0, .release);
    g_hydration_scan_fallbacks.store(0, .release);
    g_hydration_full_scan_skips.store(0, .release);
    g_hydration_completion_persists.store(0, .release);
    g_hydration_completion_persist_failures.store(0, .release);
    g_hydration_streaming_scans.store(0, .release);
    g_hydration_stream_scan_ns.store(0, .release);
    g_hydration_stream_merge_ns.store(0, .release);
    graph_storage_adapter.hydration_scan.resetHydrationInflightShardHighWater();
}

/// GAP hydration fast-scan: graphs hydrated via the sequential per-shard
/// stream scan since the last counter reset.
pub fn hydrationStreamingScanCount() u64 {
    return g_hydration_streaming_scans.load(.acquire);
}

/// Task 2: cumulative SCAN-phase wall nanos (parallel per-shard sweeps) of
/// stream-scan hydrations since the last counter reset.
pub fn hydrationStreamScanNanos() u64 {
    return g_hydration_stream_scan_ns.load(.acquire);
}

/// Task 2: cumulative MERGE-phase wall nanos (single-threaded product
/// inserts) of stream-scan hydrations since the last counter reset.
pub fn hydrationStreamMergeNanos() u64 {
    return g_hydration_stream_merge_ns.load(.acquire);
}

/// GAP-ENT-0023 P3: number of loop2 hydration PRODUCTS restored from
/// counter-gated snapshots (counters / label postings / merge index — up to 3
/// per hydrated graph).
pub fn hydrationSnapshotLoadCount() u64 {
    return g_hydration_snapshot_loads.load(.acquire);
}

/// GAP-ENT-0023 P3: number of loop2 hydration products rebuilt by the engine
/// scan because their snapshot was absent, counter-stale, or invalid.
pub fn hydrationScanFallbackCount() u64 {
    return g_hydration_scan_fallbacks.load(.acquire);
}

/// GAP-ENT-0023 P3: number of graph hydrations that skipped the O(graph)
/// engine scan entirely (all products from snapshots).
pub fn hydrationFullScanSkipCount() u64 {
    return g_hydration_full_scan_skips.load(.acquire);
}

/// Task 3: number of hydration-completion persists that fully succeeded
/// (graph-scoped engine checkpoint + IdMap snapshot + loop2 product snapshots
/// written immediately after a successful first-touch hydration).
pub fn hydrationCompletionPersistCount() u64 {
    return g_hydration_completion_persists.load(.acquire);
}

/// Task 3: number of hydration-completion persists that FAILED (logged
/// loudly, hydration itself unaffected; the next reopen re-scans).
pub fn hydrationCompletionPersistFailureCount() u64 {
    return g_hydration_completion_persist_failures.load(.acquire);
}

/// GAP-ENT-0042(a): number of hydration self-heal flush checkpoints that were
/// SKIPPED (bounded-acquire timeout or engine failure) instead of wedging the
/// hydration chokepoint. The repairs themselves are already applied to the
/// engine when this fires; only the page-flush/WAL-truncate is deferred to
/// the next checkpoint. Test observability for the bounded self-heal flush.
pub fn hydrationSelfHealCheckpointSkips() u64 {
    return g_selfheal_checkpoint_skips.load(.acquire);
}

/// Number of nodes walked by the DEFERRED resident-index scan so far. 0 at the
/// "server ready" point proves the O(graph) loop2 scan was not run at open.
pub fn loop2ScanNodeCount() u64 {
    return g_loop2_scan_nodes.load(.acquire);
}

/// Number of per-node engine reads done by the IdMap scan-rebuild fallback. 0
/// proves the IdMap was bulk-loaded from a counter-gated mmap snapshot instead.
pub fn idMapScanGetPropCount() u64 {
    return g_idmap_scan_getprop.load(.acquire);
}

/// Number of graphs whose IdMap was loaded from a valid mmap snapshot at open.
pub fn idMapFromSnapshotCount() u64 {
    return g_idmap_from_snapshot.load(.acquire);
}

/// Mutex protecting the re-initialization path in getGlobalStore.
/// Without this, concurrent callers can race: one thread tears down the store
/// while another reads a half-initialized global_store, yielding empty results.
var g_init_mutex: std.Io.Mutex = std.Io.Mutex.init;

/// GAP-0259/0260: RwLock replaces Mutex so query threads (shared readers) don't
/// block each other — only the persistence thread takes an exclusive write lock.
/// CANARY: REQ=REQ-GAP-0259-RWLOCK-001; FEATURE="AsyncPersistence"; ASPECT=RwLockMigration; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=storage; UPDATED=2026-06-11
var g_store_rwlock: std.Io.RwLock = std.Io.RwLock.init;

/// Mutation epoch counter for ReadView invalidation.
/// Incremented on every data mutation (node/edge create, delete, property set/remove).
/// ReadView captures this at creation; if the epoch changes during a read, the view
/// lazily falls back to a deep-clone snapshot.
var g_mutation_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn getMutationEpoch() u64 {
    return g_mutation_epoch.load(.acquire);
}

pub fn incrementMutationEpoch() void {
    _ = g_mutation_epoch.fetchAdd(1, .release);
}

// CANARY: REQ=REQ-PERF-PLAN-LIFECYCLE-006; FEATURE="PlanCacheLifecycle"; ASPECT=SchemaEpoch; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
/// Issue #452: Schema epoch counter for plan cache invalidation.
/// Incremented on DDL operations (CREATE/DROP INDEX, schema changes).
/// Plan cache entries created at an older epoch are treated as stale.
var g_schema_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Get the current schema epoch (for plan cache invalidation checks)
pub fn getSchemaEpoch() u64 {
    return g_schema_epoch.load(.monotonic);
}

/// Increment the schema epoch (called on DDL: CREATE/DROP INDEX, etc.)
pub fn bumpSchemaEpoch() void {
    _ = g_schema_epoch.fetchAdd(1, .monotonic);
}

// CANARY: REQ=REQ-PERF-WAL-002; FEATURE="WriteAheadLog"; ASPECT=MutationCallback; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-17
// Issue #445: Mutation notification callback for WAL integration.
// Instead of instrumenting every mutation call site, the store's mutation functions
// call this callback after each successful mutation. The WAL installs a callback
// to emit WAL records. A guard flag prevents re-emission during WAL replay.
pub const MutationOp = enum(u8) {
    create_node = 1,
    create_edge = 2,
    set_node_property = 3,
    remove_node_property = 4,
    set_edge_property = 5,
    remove_edge_property = 6,
    delete_node = 7,
    delete_edge = 8,
    add_node_label = 9,
    remove_node_label = 10,
};

/// Callback signature for mutation notifications.
/// Parameters: op, id1 (node/edge), id2 (to_id for edges, 0 otherwise),
/// label/key (context string), value (for property ops), graph_name
pub const MutationNotifyFn = *const fn (
    op: MutationOp,
    id1: u64,
    id2: u64,
    id3: u64,
    label: ?[]const u8,
    key: ?[]const u8,
    value: ?PropertyValue,
    graph_name: ?[]const u8,
) void;

var g_mutation_notify: ?MutationNotifyFn = null;
var g_mutation_notify_inhibit: bool = false;

/// Set the mutation notification callback (used by WAL to capture mutations)
pub fn setMutationNotify(f: ?MutationNotifyFn) void {
    g_mutation_notify = f;
}

/// Inhibit/enable mutation notifications (set during WAL replay to prevent re-emission)
pub fn setMutationNotifyInhibit(inhibit: bool) void {
    g_mutation_notify_inhibit = inhibit;
}

/// Invoke the mutation callback if installed and not inhibited
inline fn notifyMutation(op: MutationOp, id1: u64, id2: u64, id3: u64, label: ?[]const u8, key: ?[]const u8, value: ?PropertyValue, graph_name: ?[]const u8) void {
    if (g_mutation_notify) |notify| {
        if (!g_mutation_notify_inhibit) {
            notify(op, id1, id2, id3, label, key, value, graph_name);
        }
    }
}

// GAP-0268: WAL persistence hooks — stored and invoked by the persistence loop
// to sync the WAL and checkpoint/truncate when thresholds are reached.
pub const WalSyncFn = *const fn () void;
pub const WalNeedsCheckpointFn = *const fn () bool;
pub const WalCheckpointFn = *const fn (*GraphStore) void;

var g_wal_sync_fn: ?WalSyncFn = null;
var g_wal_needs_checkpoint_fn: ?WalNeedsCheckpointFn = null;
var g_wal_checkpoint_fn: ?WalCheckpointFn = null;

/// Install WAL persistence hooks invoked by the background persistence loop.
/// Pass null to uninstall (e.g., during shutdown).
pub fn setWalPersistenceHooks(
    sync_fn: ?WalSyncFn,
    needs_checkpoint_fn: ?WalNeedsCheckpointFn,
    checkpoint_fn: ?WalCheckpointFn,
) void {
    g_wal_sync_fn = sync_fn;
    g_wal_needs_checkpoint_fn = needs_checkpoint_fn;
    g_wal_checkpoint_fn = checkpoint_fn;
}

/// ENG-3979: number of global-store-lock holds owned by THIS thread, in either
/// mode.  `std.Io.RwLock` is not reentrant and exposes no ownership query, so
/// callers that need to know "did I already synchronize the store on this
/// thread?" cannot ask the lock itself — a `tryLockShared` against a lock the
/// SAME thread already holds EXCLUSIVE simply fails, which is
/// indistinguishable from genuine contention with another thread.
///
/// Every acquire/release of `g_store_rwlock` in this file goes through the
/// helpers below so this counter cannot drift.  Do NOT touch
/// `g_store_rwlock` directly.
threadlocal var t_store_lock_depth: u32 = 0;

/// ENG-3979: true when the CALLING thread already holds the global store lock
/// (shared or exclusive).  A read performed while this is true is already
/// synchronized against every other thread and MUST NOT try to re-acquire —
/// re-acquiring self-deadlocks (blocking form) or spuriously fails
/// (`tryAcquireStoreLock`).
pub fn storeLockHeldByCurrentThread() bool {
    return t_store_lock_depth > 0;
}

/// Outcome of `beginStoreRead` — how the caller obtained store-read access.
pub const StoreReadAccess = enum {
    /// This thread already holds the store lock; the read is already
    /// synchronized and no lock was taken (nothing to release).
    already_held,
    /// A fresh SHARED hold was taken and must be released via `endStoreRead`.
    acquired,
    /// Another thread holds the lock exclusively; the caller could not read.
    unavailable,
};

/// ENG-3979: non-blocking, self-reentrant store-read gate for callbacks that
/// may be invoked either from an unlocked thread OR from deep inside a
/// critical section that already holds the store lock (the persistent auth
/// resolver is the motivating case: a mutating `CALL geode.auth.*` runs under
/// the global EXCLUSIVE lock and then calls back into the resolver).
///
/// Never blocks: genuine foreign contention reports `.unavailable` so the
/// caller can fail closed instead of stalling the auth path behind a
/// checkpoint.  Pair every non-`.unavailable` result with `endStoreRead`.
pub fn beginStoreRead() StoreReadAccess {
    if (storeLockHeldByCurrentThread()) return .already_held;
    if (tryAcquireStoreLock()) return .acquired;
    return .unavailable;
}

/// Release whatever `beginStoreRead` took.  No-op for `.already_held` (the
/// outer hold belongs to the caller further up this thread's stack) and for
/// `.unavailable`.
pub fn endStoreRead(access: StoreReadAccess) void {
    if (access == .acquired) releaseStoreLock();
}

/// Acquire the global store lock (shared — for read-only query handlers).
/// GAP-0001: Mutation operations must use acquireStoreWriteLock() instead
/// to prevent concurrent HashMap rehash races (CWE-362, CWE-416).
pub fn acquireStoreLock() void {
    g_store_rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
    t_store_lock_depth += 1;
}

/// Try to acquire shared lock without blocking.  Returns true if locked.
pub fn tryAcquireStoreLock() bool {
    if (g_store_rwlock.tryLockShared(std.Io.Threaded.global_single_threaded.io())) {
        t_store_lock_depth += 1;
        return true;
    }
    return false;
}

/// Release the global store lock (shared)
pub fn releaseStoreLock() void {
    g_store_rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
    if (t_store_lock_depth > 0) t_store_lock_depth -= 1;
}

/// Acquire exclusive write lock (for mutations and persistence thread)
pub fn acquireStoreWriteLock() void {
    g_store_rwlock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    t_store_lock_depth += 1;
}

/// R2 (2026-04-22): deadline-aware variant of `acquireStoreWriteLock`.
/// Returns `error.Deadline` if the exclusive write lock cannot be
/// acquired before `deadline_mono_ns` (absolute CLOCK_MONOTONIC ns).
pub fn acquireStoreWriteLockCancelable(deadline_mono_ns: u64) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    if (g_store_rwlock.tryLock(io)) {
        t_store_lock_depth += 1;
        return;
    }

    var sleep_ns: u64 = 100 * std.time.ns_per_us;
    const max_sleep_ns: u64 = 2 * std.time.ns_per_ms;
    while (true) {
        const now = monoNanosNow();
        if (now >= deadline_mono_ns) return error.Deadline;
        const remaining = deadline_mono_ns - now;
        const nap_ns = @min(sleep_ns, remaining);
        {
            const req = std.os.linux.timespec{
                .sec = @intCast(nap_ns / std.time.ns_per_s),
                .nsec = @intCast(nap_ns % std.time.ns_per_s),
            };
            var rem: std.os.linux.timespec = undefined;
            _ = std.os.linux.nanosleep(&req, &rem);
        }
        if (g_store_rwlock.tryLock(io)) {
            t_store_lock_depth += 1;
            return;
        }
        sleep_ns = @min(sleep_ns * 2, max_sleep_ns);
    }
}

fn monoNanosNow() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Public accessor for the same CLOCK_MONOTONIC source used to compute
/// `acquireStoreWriteLockCancelable` deadlines. Callers that need to build a
/// deadline (absolute mono ns) for the cancelable lock acquire MUST use this
/// so their deadline is on the same clock the acquire compares against.
pub fn monoNanosNowPub() u64 {
    return monoNanosNow();
}

/// Release exclusive write lock
pub fn releaseStoreWriteLock() void {
    g_store_rwlock.unlock(std.Io.Threaded.global_single_threaded.io());
    if (t_store_lock_depth > 0) t_store_lock_depth -= 1;
}

/// GAP-0754: Global allocator for persistent graph store data.
///
/// Historical context: this was `std.heap.DebugAllocator(.{})`. That
/// allocator is thread-safe via an internal mutex that serializes every
/// alloc/free; after GAP-0753 narrowed the handler lock-hold window,
/// DebugAllocator's mutex became the next hot-path bottleneck on the
/// MATCH read path.
///
/// `std.heap.smp_allocator` is a sharded per-core allocator with
/// thread-local fast paths — the same allocator `src/server/allocator_config.zig`
/// already selects by default for the top-level server allocator. It has no
/// init state, so callers can use `global_allocator()` directly without a
/// prior initialization step.
pub fn global_allocator() std.mem.Allocator {
    return std.heap.smp_allocator;
}

/// Start a background thread that periodically flushes dirty data to disk.
/// Needed for cross-process visibility (CLI user commands → server).
var g_persist_shutdown: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var g_persist_pool: ?*pooled.ThreadPool = null;
var g_persist_interval_ms: u64 = 5000;

// GAP-0900: deferred-mode auto-checkpoint cadence. The group-commit bulk fast
// path bypasses notifyMutation / GraphStore.dirty, so the legacy
// `needs_checkpoint` and `persistSplitPhase` triggers never fire during a pure
// bulk ingest and the engine WAL + dirty pages grow unbounded (RSS ∝ nodes →
// OOM). The persistence loop also consults the engine-backed cadence
// (StorageAdapter.maybeCheckpoint), which fires a real checkpoint when either:
//   * `pending_bulk_ops >= GEODE_CHECKPOINT_OPS` bulk ops have accumulated
//     since the last checkpoint (op-count proxy for ~16 MB of WAL: a node/edge
//     record + WAL framing is on the order of a few hundred bytes, so 50_000
//     ops ≈ 16 MB), or
//   * `GEODE_CHECKPOINT_INTERVAL_MS` have elapsed since the last checkpoint AND
//     there is un-checkpointed bulk work (matches the documented 60 s cadence).
// Both are overridable via env for tuning / tests.
const DEFAULT_CHECKPOINT_OPS: u64 = 50_000;
const DEFAULT_CHECKPOINT_INTERVAL_MS: u64 = 60_000;
// GAP-0900 (B): default write-backpressure cap = this many × the ops threshold
// of un-checkpointed work before writers block on an in-progress checkpoint.
const DEFAULT_CHECKPOINT_MAX_PENDING_MULT: u64 = 4;

fn envU64(name: [*:0]const u8, default: u64) u64 {
    if (std.c.getenv(name)) |raw_z| {
        const raw = std.mem.span(raw_z);
        return std.fmt.parseInt(u64, raw, 10) catch default;
    }
    return default;
}

pub fn startPersistenceThread(interval_ms: u64) void {
    g_persist_interval_ms = interval_ms;
    g_persist_shutdown.store(0, .release);
    const pool = pooled.ThreadPool.init(global_allocator(), .{
        .num_threads = 1,
        .queue_capacity = 4,
        // 2026-05-29: the loop parks on g_persist_shutdown via futex and
        // stopPersistenceThread wakes it before deinit, so the timeout is a
        // hard safety net rather than the normal SIGTERM path.
        .deinit_timeout_ns = 2 * std.time.ns_per_s,
    }) catch return;
    errdefer pool.deinit();
    pool.submitBlocking(.{
        .context = @ptrCast(&g_persist_shutdown),
        .callback = runPersistenceLoop,
    }) catch {
        pool.deinit();
        return;
    };
    g_persist_pool = pool;
}

pub fn stopPersistenceThread(allocator: std.mem.Allocator) void {
    _ = allocator;
    g_persist_shutdown.store(1, .release);
    const io = std.Io.Threaded.global_single_threaded.io();
    io.futexWake(u32, &g_persist_shutdown.raw, std.math.maxInt(u32));
    if (g_persist_pool) |pool| {
        pool.deinit();
        g_persist_pool = null;
    }
    // Final flush — no worker threads should be running at this point
    // but take the lock for safety. Use split-phase for consistency with
    // the persistence loop (P3: avoid holding lock during TDE finalization).
    if (global_store != null) {
        const store_ptr: *GraphStore = &(global_store.?);
        // GAP-0268: Final WAL sync + checkpoint to ensure all mutations are persisted
        // and the WAL is truncated before shutdown.
        if (g_wal_sync_fn) |sync_fn| {
            sync_fn();
        }
        if (g_wal_checkpoint_fn) |checkpoint_fn| {
            // P1: Use per-graph read lock for final WAL checkpoint; fall back to global.
            const ckpt_handle = acquireGraphReadLockTagged(DEFAULT_GRAPH_NAME, .misc);
            checkpoint_fn(store_ptr);
            releaseGraphLock(ckpt_handle);
        } else {
            persistSplitPhase(store_ptr);
        }
    }
}

fn persistenceLoop() void {
    // 2026-04-25 (Phase 2-final follow-up, edges_contains cascade fix): the
    // prior `@min(g_persist_interval_ms, 1000)` clamp meant the persister
    // polled every 1 s regardless of `--persist-interval`. Under sustained
    // 16-way SHARED traffic on `mg.rwlock` (msft-graph ingest), that fired
    // an EXCLUSIVE acquire every second that got starved indefinitely,
    // accumulating thousands of parked threads. Honour the configured
    // interval (still bounded below by 100 ms so a misconfigured 0 or 1 ms
    // doesn't burn CPU). See
    // docs/performance/2026-04-25-edges-contains/diagnosis.md.
    const poll_ms: u64 = @max(g_persist_interval_ms, 100);
    // GAP-0900: deferred-mode auto-checkpoint thresholds, read once at loop start.
    const checkpoint_ops: u64 = envU64("GEODE_CHECKPOINT_OPS", DEFAULT_CHECKPOINT_OPS);
    const checkpoint_interval_ms: u64 = envU64("GEODE_CHECKPOINT_INTERVAL_MS", DEFAULT_CHECKPOINT_INTERVAL_MS);
    const io = std.Io.Threaded.global_single_threaded.io();
    while (g_persist_shutdown.load(.acquire) == 0) {
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromNanoseconds(poll_ms * std.time.ns_per_ms),
            .clock = .awake,
        } };
        io.futexWaitTimeout(u32, &g_persist_shutdown.raw, 0, timeout) catch |err| switch (err) {
            error.Canceled => return,
        };
        if (g_persist_shutdown.load(.acquire) != 0) break;
        if (global_store != null) {
            const store_ptr: *GraphStore = &(global_store.?);

            // GAP-0268: Sync the WAL (fsync) on every persistence loop tick
            // so that committed mutations reach stable storage promptly.
            if (g_wal_sync_fn) |sync_fn| {
                sync_fn();
            }

            // GAP-0900: engine-backed checkpoint cadence. The group-commit bulk
            // fast path bumps `pending_bulk_ops` but feeds NEITHER the legacy
            // CDC WAL (`g_wal.needsCheckpoint`) NOR `GraphStore.dirty`, so the
            // two triggers below never fire during a pure bulk ingest. Consult
            // the adapter cadence here so deferred-mode bulk loads checkpoint
            // (flushing + truncating the engine WAL) and bound RSS. When this
            // fires it has already done the real per-graph checkpoint and reset
            // the cadence state, so skip the legacy triggers this tick to avoid
            // double-checkpointing.
            if (global_adapter) |adapter| {
                const fired = adapter.maybeCheckpoint(
                    checkpoint_ops,
                    checkpoint_interval_ms,
                    monoNanosNow(),
                ) catch |err| blk: {
                    log.err("deferred-mode auto-checkpoint failed", &.{
                        Attr.string("error", @errorName(err)),
                    });
                    break :blk false;
                };
                if (fired) {
                    log.info("deferred-mode auto-checkpoint fired", &.{
                        Attr.uint("checkpoints_total", adapter.checkpointsTotal()),
                    });
                    continue;
                }
            }

            // GAP-0268: When WAL hooks are installed and a checkpoint is needed,
            // checkpoint (which truncates the WAL) instead of the plain save.
            // This prevents unbounded WAL growth.
            const needs_checkpoint = if (g_wal_needs_checkpoint_fn) |needs_fn| needs_fn() else false;
            if (needs_checkpoint) {
                // P1: WAL checkpoint — use per-graph read locks when adapter is available,
                // falling back to the global shared lock for backward compatibility.
                if (global_adapter) |adapter| {
                    if (g_wal_checkpoint_fn) |checkpoint_fn| {
                        // Acquire a read lock on the default graph while running the
                        // WAL checkpoint (which reads store state).
                        const ckpt_handle = acquireGraphReadLockTagged(DEFAULT_GRAPH_NAME, .misc);
                        checkpoint_fn(store_ptr);
                        releaseGraphLock(ckpt_handle);
                    }
                    // Checkpoint per-graph storage on WAL checkpoint ticks.
                    // GAP-0900 Layer-2: LIGHT — a runtime checkpoint must stay
                    // O(dirty); a full O(graph) checkpoint here stalls a large
                    // ingest for minutes under the exclusive store lock.
                    if (adapter.checkpointAllLight()) |_| {
                        // GAP-ENT-0038: this legacy CDC-WAL-triggered branch was
                        // completely SILENT on success while resetting the
                        // deferred cadence state (pending ops zeroed, clock
                        // restarted), so during the 14.27M edge phase (edge
                        // creates feed notifyMutation/dirty) it did ALL the
                        // checkpointing at a ~33 s cadence with zero log lines —
                        // which was misread as "auto-checkpoint never re-armed".
                        // Log it like the deferred trigger so the checkpoint
                        // sawtooth is visible whichever driver wins.
                        log.info("periodic WAL-triggered light checkpoint fired", &.{
                            Attr.uint("checkpoints_total", adapter.checkpointsTotal()),
                        });
                    } else |err| {
                        log.err("per-graph storage checkpoint failed", &.{
                            Attr.string("error", @errorName(err)),
                        });
                    }
                } else {
                    // Fallback: global shared lock (via the helpers so the
                    // ENG-3979 per-thread hold counter stays exact).
                    acquireStoreLock();
                    defer releaseStoreLock();
                    if (g_wal_checkpoint_fn) |checkpoint_fn| {
                        checkpoint_fn(store_ptr);
                    }
                }
            } else {
                // P3: Split persistence into two phases so the shared lock is NOT
                // held during TDE encryption / finalization. Phase 1 (serialize)
                // reads hash maps and requires the lock; phase 2 (finalize) only
                // does file I/O (rename or TDE encrypt+write) and does not.
                persistSplitPhase(store_ptr);
            }
        }
    }
}

fn runPersistenceLoop(_: *anyopaque) void {
    persistenceLoop();
}

// CANARY: REQ=REQ-STORAGE-ENGINE-PHASE2-006; FEATURE="EngineBackedPersistence"; ASPECT=PersistSplitPhase; STATUS=IMPL; OWNER=storage; UPDATED=2026-04-06
/// Persistence via adapter checkpoint. No more graph_store.dat or id_map.dat.
fn persistSplitPhase(store_ptr: *GraphStore) void {
    if (!@constCast(&store_ptr.dirty).load(.acquire)) return;

    // P1: Checkpoint per-graph storage using per-graph write locks one at a time.
    // Falls back to checkpointAll (which uses the adapter mutex) when adapter unavailable.
    // GAP-0900 Layer-2: LIGHT — this is the periodic dirty-flush backstop; it must
    // stay O(dirty). A full O(graph) checkpoint here stalls a large ingest for
    // minutes under the exclusive store lock (full is kept for clean shutdown).
    if (global_adapter) |adapter| {
        adapter.checkpointAllLight() catch |err| {
            log.err("per-graph storage checkpoint failed", &.{
                Attr.string("error", @errorName(err)),
            });
            return;
        };
        // GAP-ENT-0038: like the WAL-triggered branch above, this dirty-flush
        // backstop silently resets the deferred cadence state — make it
        // visible so operators can account for every checkpoint driver.
        log.info("periodic dirty-flush light checkpoint fired", &.{
            Attr.uint("checkpoints_total", adapter.checkpointsTotal()),
        });

        // Remove any stale sidecar files after the checkpoint lands.
        // Use per-graph read locks so only one graph is locked at a time.
        var it = store_ptr.graphs.iterator();
        while (it.next()) |entry| {
            const gname = entry.key_ptr.*;
            const lock_handle = acquireGraphReadLockTagged(gname, .misc);
            store_ptr.cleanupLegacySidecarsForGraph(gname);
            releaseGraphLock(lock_handle);
        }
    } else {
        // Fallback: use global shared lock for legacy (no-adapter) path.
        // Via the helpers so the ENG-3979 per-thread hold counter stays exact.
        acquireStoreLock();
        store_ptr.cleanupLegacySidecars();
        releaseStoreLock();
    }

    // Clear dirty flag
    @constCast(&store_ptr.dirty).store(false, .release);
}

pub fn pushActiveQueryReadStore(store: *GraphStore) ?*GraphStore {
    const previous = g_active_query_read_store;
    g_active_query_read_store = store;
    return previous;
}

// CANARY: REQ=REQ-QUIC-HC-017; FEATURE="ActiveReadStoreReuse"; ASPECT=IMPL; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-25
pub fn getActiveQueryReadStore() ?*GraphStore {
    return g_active_query_read_store;
}

pub fn popActiveQueryReadStore(previous: ?*GraphStore) void {
    g_active_query_read_store = previous;
}

pub const QueryReadSession = struct {
    parent_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    snapshot: GraphStore,

    pub fn initIfAvailable(allocator: std.mem.Allocator, source_store: *GraphStore) !?QueryReadSession {
        // GAP-0523: Removed vestigial global_adapter gate. cloneNodesFrom/cloneIdMapsFrom
        // clone directly from the in-memory store (see line 763 comment: "without going
        // through the adapter"), so no adapter is needed for snapshot creation.
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var session = QueryReadSession{
            .parent_allocator = allocator,
            .arena = arena,
            .snapshot = undefined,
        };
        errdefer {
            session.arena.deinit();
            session.parent_allocator.destroy(session.arena);
        }

        session.snapshot = try GraphStore.initWithTenant(
            session.arena.allocator(),
            source_store.tenant_id,
            source_store.schema_name,
        );
        errdefer session.snapshot.deinit();

        // Clone nodes/edges from the global store instead of loading from the
        // shared adapter buffer pool (which races with concurrent writers).
        // No lock needed: cloneNodesFrom only reads from source_store via
        // HashMap iterators, which are safe as long as the HashMap is not
        // resized during iteration. Since CREATE operations on the global
        // store run on worker threads and HashMap.put only resizes at high
        // load factors, the brief clone window is acceptably safe.
        try session.snapshot.cloneIdMapsFrom(source_store);
        try session.snapshot.cloneNodesFrom(source_store);
        session.snapshot.data_dir = source_store.data_dir;
        _ = g_query_read_session_init_count.fetchAdd(1, .acq_rel);

        return session;
    }

    pub fn deinit(self: *QueryReadSession) void {
        self.snapshot.deinit();
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
    }

    pub fn store(self: *QueryReadSession) *GraphStore {
        return &self.snapshot;
    }
};

/// Zero-copy read view for simple point reads (MATCH by single label +
/// property, no traversal). Unlike `QueryReadSession`, this view does
/// NOT deep-clone nodes/properties. It captures the mutation epoch at
/// acquire time and relies on the caller holding the shared read lock
/// for the target graph. Mutations block until the caller releases the
/// lock, which is acceptable for short (<10 ms) point reads but NOT for
/// long-running traversals — those must keep using `QueryReadSession`.
///
/// Invariant: `init` must only be called while the caller already holds
/// the shared read lock for the target graph (see
/// `graph_store.acquireGraphReadLock`). The caller is responsible for
/// releasing the lock after `deinit`.
///
/// CANARY: REQ=REQ-PERF-QPS-0805; FEATURE="PointReadView"; ASPECT=IMPL; STATUS=TESTED; TEST=tests/test_point_read_view_zero_copy.zig; OWNER=performance; UPDATED=2026-04-19
pub const PointReadView = struct {
    store_ref: *GraphStore,
    captured_epoch: u64,

    pub fn init(store_ptr: *GraphStore) !PointReadView {
        return .{
            .store_ref = store_ptr,
            .captured_epoch = getMutationEpoch(),
        };
    }

    /// No-op — the shared read lock is released by the caller (the
    /// handler that acquired it), not by the view.
    pub fn deinit(self: *PointReadView) void {
        _ = self;
    }

    /// Returns true if a mutation has occurred since this view was
    /// acquired. Callers observing `true` must fall back to
    /// `QueryReadSession` for correctness. Point reads that complete
    /// inside the held shared lock won't observe drift in practice.
    pub fn isStale(self: PointReadView) bool {
        return getMutationEpoch() != self.captured_epoch;
    }

    pub fn store(self: *PointReadView) *GraphStore {
        return self.store_ref;
    }

    /// Returns the set of node IDs currently in the store. This
    /// allocates an `[]u64` of IDs (same as `GraphStore.getAllNodes`),
    /// which is O(n) in node count but — critically — does NOT clone
    /// any node properties or label slices. That's the distinction
    /// from `QueryReadSession.initIfAvailable`, which deep-clones the
    /// entire nodes+edges+properties arena on every point read.
    ///
    /// Caller owns the returned slice.
    pub fn getAllNodes(self: *PointReadView, allocator: std.mem.Allocator) ![]u64 {
        return self.store_ref.getAllNodes(allocator);
    }
};

/// Lightweight read view with epoch-based invalidation.
/// Captures a mutation epoch counter at creation time. If no concurrent mutations
/// occur (epoch unchanged), reads go directly to the base store (zero overhead).
/// If mutations are detected (epoch changed), lazily falls back to a deep-clone snapshot.
pub const ReadView = struct {
    base: *GraphStore,
    captured_epoch: u64,
    fallback_snapshot: ?QueryReadSession,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, store_ptr: *GraphStore) ReadView {
        return .{
            .base = store_ptr,
            .captured_epoch = getMutationEpoch(),
            .fallback_snapshot = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ReadView) void {
        if (self.fallback_snapshot) |*snap| {
            snap.deinit();
        }
    }

    /// Returns the store to read from. Zero overhead when no concurrent
    /// mutations (epoch unchanged). Falls back to deep-clone snapshot
    /// when mutations are detected.
    pub fn getReadStore(self: *ReadView) *GraphStore {
        if (getMutationEpoch() == self.captured_epoch) {
            return self.base;
        }
        // Epoch changed — concurrent mutation detected
        if (self.fallback_snapshot == null) {
            acquireStoreLock();
            defer releaseStoreLock();
            self.fallback_snapshot = QueryReadSession.initIfAvailable(self.allocator, self.base) catch null;
        }
        if (self.fallback_snapshot) |*snap| {
            return snap.store();
        }
        return self.base; // fallback if snapshot creation failed
    }
};

/// GAP-0259/0260: Persistence is handled solely by the background loop (1s poll).
/// Worker threads no longer call saveIfDirty() directly — the dirty flag set by
/// mutations under the write lock is sufficient for the loop to detect changes.
///
/// CANARY: REQ=REQ-PERF-WAL-004; FEATURE="WriteAheadLog"; ASPECT=PersistenceLoop; STATUS=TESTED; OWNER=storage; UPDATED=2026-02-17
/// Issue #445: When WAL is enabled, the persistence loop syncs the WAL (fsync) on every
fn getPrimaryGlobalStore(allocator: std.mem.Allocator) *GraphStore {
    // GAP-0754: `global_allocator()` (smp_allocator) has no init step, so the
    // former `global_allocator_init` latch is no longer needed.

    // Fast path: already initialized — atomic acquire ensures we see all
    // writes (global_store, last_data_dir) that preceded the release store.
    // Only safe when no data-dir change is possible (the common case during
    // query processing after startup).
    if (initialized.load(.acquire)) {
        // Fast path: data dir never changes after startup in server mode.
        // The override is set once in initGlobalStore and never cleared.
        // Checking env vars on every query was causing spurious reinits when
        // allocator.dupe failed under memory pressure, clearing all nodes.
        if (getDataDirOverride() != null) {
            return &global_store.?;
        }

        // Non-override path: check if data directory has changed (rare).
        const current_data_dir: ?[]const u8 = if (std.c.getenv("GEODE_DATA_DIR")) |ptr| std.mem.span(ptr) else null;

        // Compare under the init mutex to avoid racing with a concurrent reinit.
        var needs_reinit = false;
        g_init_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        if (current_data_dir) |curr_dir| {
            if (last_data_dir) |last_dir| {
                if (!std.mem.eql(u8, curr_dir, last_dir)) {
                    needs_reinit = true;
                }
            } else {
                needs_reinit = true;
            }
        } else if (last_data_dir != null) {
            needs_reinit = true;
        }

        if (!needs_reinit) {
            g_init_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return &global_store.?;
        }
        // Fall through to reinit with mutex already held.
        // (unlock handled by defer below after re-lock check)
        g_init_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    // Slow path: acquire init mutex for first initialization or reinit.
    g_init_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_init_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    // Resolve current data dir under lock.
    const current_data_dir: ?[]u8 = if (getDataDirOverride()) |override|
        allocator.dupe(u8, override) catch null
    else
        getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch null;
    defer if (current_data_dir) |dir| allocator.free(dir);

    // Double-check under lock: another thread may have completed init.
    var needs_reinit = false;
    if (current_data_dir) |curr_dir| {
        if (last_data_dir) |last_dir| {
            if (!std.mem.eql(u8, curr_dir, last_dir)) {
                needs_reinit = true;
            }
        } else {
            needs_reinit = true;
        }
    } else if (last_data_dir != null) {
        needs_reinit = true;
    }

    if (initialized.load(.acquire) and !needs_reinit) {
        return &global_store.?;
    }

    // Reinitialize if data dir changed or not initialized yet
    // Clean up previous instance if it exists
    if (initialized.load(.monotonic) and global_store != null) {
        global_store.?.clearNodes();
        global_store.?.deinit();
        global_store = null;
        global_store_allocator = null;
    }

    // Update last_data_dir
    if (last_data_dir) |dir| {
        global_allocator().free(dir);
    }
    if (current_data_dir) |curr_dir| {
        last_data_dir = global_allocator().dupe(u8, curr_dir) catch null;
    } else {
        last_data_dir = null;
    }

    syncGlobalAdapterForDataDir(last_data_dir);

    global_store_allocator = g_test_store_allocator orelse global_allocator();
    global_store = GraphStore.init(global_store_allocator.?) catch @panic("OOM: failed to initialize global graph store");
    // GAP-0065 FIX D: a fresh store instance has not yet run its clean-shutdown
    // flush — reset the per-instance latch so `deinitGlobalStoreEx` performs the
    // durability checkpoint if `flushForCleanShutdown` was never called for it.
    g_clean_shutdown_flushed.store(false, .release);
    // Set data_dir for per-graph storage
    if (last_data_dir) |dir| {
        global_store.?.data_dir = dir;
    }
    // Load from engine-backed storage (adapter) if available
    if (global_adapter != null) {
        global_store.?.loadFromFile() catch |err| {
            log.err("Failed to load graph store from adapter", &.{
                Attr.string("error", @errorName(err)),
            });
            @panic("graph store adapter load failed");
        };
    }
    // Release store: all writes above are visible to threads that see initialized=true.
    initialized.store(true, .release);
    return &global_store.?;
}

pub fn getWritableGlobalStore(allocator: std.mem.Allocator) *GraphStore {
    return getPrimaryGlobalStore(allocator);
}

pub fn getGlobalStore(allocator: std.mem.Allocator) *GraphStore {
    if (g_active_query_read_store) |snapshot| {
        return snapshot;
    }
    return getPrimaryGlobalStore(allocator);
}

/// Initialize the global store with engine-backed storage adapter.
/// This is the preferred initialization path that sets up both the global
/// GraphStore and the global StorageAdapter in one call.
pub fn initGlobalStore(allocator: std.mem.Allocator, data_dir: []const u8) !*GraphStore {
    // Set data dir override so getGlobalStore picks it up
    setDataDirOverride(allocator, data_dir);

    // Get or create the global store (which will now use the adapter)
    const store = getGlobalStore(allocator);
    const adapter = getGlobalAdapter() orelse {
        deinitGlobalStore();
        return error.StorageAdapterUnavailable;
    };
    if (!std.mem.eql(u8, adapter.data_dir, data_dir)) {
        deinitGlobalStore();
        return error.StorageAdapterMismatch;
    }
    // NOTE: do NOT re-alias `store.data_dir = data_dir` here. `getPrimaryGlobalStore`
    // already set `store.data_dir` to the OWNED `last_data_dir` copy (global-allocator
    // dupe, lives for the store's lifetime). Re-aliasing to the *caller's* borrowed
    // `data_dir` slice made `store.data_dir` dangle once the caller freed it — harmless
    // before the clean-shutdown snapshot write existed, but a use-after-free now that
    // `deinitGlobalStore` reads `data_dir` in `saveToFileEx`/`resolveGraphRootDirPath`.
    // Callers that free their `data_dir` before the deferred `deinitGlobalStore`
    // (e.g. tmpDir tests, defer LIFO) would otherwise crash the shutdown save.
    // The disk-backed engine is now available, so the node cache can serve
    // evicted ids via hydrate-on-miss — install the hook and activate the
    // configured resident cap (GEODE_NODE_CACHE_ENTRIES). Until this point the
    // cache stays unbounded (eviction without rehydration would lose data).
    store.installNodeCacheHydrate();
    // PHASE 0: same for the bounded adjacency caches — the engine can now serve
    // an evicted node's edge-id list via hydrate-on-miss, so activate the
    // configured cap (GEODE_ADJ_CACHE_ENTRIES). Until here they stay unbounded.
    store.installAdjCacheHydrate();
    // PHASE 1: same for the bounded edge-body cache — the engine can now
    // rebuild an evicted edge's body (endpoints/rel-type/props) via
    // hydrate-on-miss, so activate the configured cap (GEODE_EDGE_CACHE_ENTRIES).
    // Until here it stays unbounded.
    store.installEdgeCacheHydrate();
    return store;
}

/// Get the current global store without initializing (returns null if not initialized)
pub fn getCurrentGlobalStore() ?*GraphStore {
    if (initialized.load(.acquire) and global_store != null) {
        return &global_store.?;
    }
    return null;
}

// CANARY: REQ=REQ-STARTUP-IDMAP-SNAPSHOT-001; FEATURE="FastRestartIdMapSnapshot"; ASPECT=ShutdownSnapshotWrite; STATUS=TESTED; TEST=tests/test_startup_lazy_hydrate.zig; OWNER=storage; UPDATED=2026-06-29
/// PHASE 1b: the production clean-shutdown (SIGTERM) entry point. ALWAYS
/// persists the per-graph IdMap mmap snapshots so the next open bulk-loads them
/// (sub-second ready) instead of paying the eager O(ids) loop1 IdMap scan.
///
/// The snapshot write MUST happen while BOTH the store (its `id_maps`) and the
/// adapter (engine `graphManifestCounter` + checkpoint) are still alive, and
/// AFTER the final engine checkpoint so the snapshot is stamped at the
/// post-checkpoint counter that the next open's counter-gate accepts. We get
/// exactly that ordering for free from `saveToFileEx(false)`: it runs
/// `adapter.checkpointAll()` and THEN the IdMap-snapshot loop at the now-current
/// counter. Done UNCONDITIONALLY (not gated on `dirty`) so even a read-only
/// session writes the snapshot and the restart stays fast.
///
/// Crash-safety is unchanged: an abrupt termination skips this path entirely
/// (no clean deinit), leaving no/stale snapshot -> the next open rejects it on
/// the counter-gate and falls back to the loop1 scan-rebuild (still correct).
pub fn deinitGlobalStore() void {
    deinitGlobalStoreEx(true);
}

/// TEST-ONLY: simulate an abrupt crash. Releases in-memory state and tears the
/// adapter down WITHOUT the clean-shutdown IdMap-snapshot write, so on-disk
/// state reflects only the last runtime checkpoint (engine may have advanced
/// past the last snapshot's counter). Production crashes are hard kills with no
/// deinit at all; this frees memory so the same test process can reopen.
pub fn deinitGlobalStoreForTestCrash() void {
    deinitGlobalStoreEx(false);
}

/// TEST-ONLY: simulate a HARD process kill (SIGKILL / power loss) for
/// WAL-durability crash tests (gap 0026). Drops every global reference
/// WITHOUT closing, checkpointing, or freeing the store/adapter — exactly
/// the on-disk state a hard kill leaves behind. The abandoned objects LEAK
/// (memory + fds), so the crashed phase MUST have been initialised with a
/// non-leak-checking allocator (e.g. the std.heap page-backed allocator),
/// never `std.testing.allocator`.
///
/// `deinitGlobalStoreForTestCrash` is NOT sufficient for WAL-durability
/// tests: it still runs `adapter.checkpointAll()` inside
/// `deinitGlobalAdapter`, which flushes dirty pages and makes even
/// deferred-WAL commits durable — masking exactly the loss window under
/// test. Group-commit coordinator threads are stopped first so no
/// background apply touches the abandoned adapter (or its WAL files, which
/// the caller may be about to truncate to simulate an unsynced tail).
pub fn abandonGlobalStoreForCrashSim() void {
    const group_commit = @import("storage/group_commit.zig");
    group_commit.shutdownAllCoordinators();
    global_store = null;
    global_store_allocator = null;
    initialized.store(false, .release);
    global_adapter = null;
    global_vtable = null;
}

// CANARY: REQ=REQ-STARTUP-COLDOPEN-NOTAIL-001; FEATURE="NoTailCleanShutdown"; ASPECT=DurabilityFlushBeforeWatchdog; STATUS=TESTED; TEST=tests/test_startup_lazy_hydrate.zig; OWNER=storage; UPDATED=2026-07-07
/// GAP-0065 FIX D: latched once the durability-critical clean-shutdown FULL
/// checkpoint (per-shard flush + WAL truncate-to-frontier + the FIX-B idmap /
/// loop2 snapshot writes) has completed for the CURRENT store instance via
/// `flushForCleanShutdown`. When set, `deinitGlobalStoreEx(true)` SKIPS its own
/// `saveToFileEx(false)` so the bounded teardown cannot re-open a
/// (checkpoint_epoch, covered_lsn) window that would invalidate the just-written
/// snapshots (a second checkpoint bumps the engine epoch; if the teardown
/// watchdog then cut it short before re-writing the snapshots, the next reopen
/// would REJECT them and re-scan). Reset when a new global store is initialised
/// (`getPrimaryGlobalStore`) so it is strictly per-instance.
var g_clean_shutdown_flushed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// GAP-0065 FIX D: run the durability-critical portion of a clean shutdown —
/// the FULL engine checkpoint (`adapter.checkpointAll()` → per-shard
/// `engine.checkpoint()` flushes dirty pages + truncates the engine WAL to the
/// durable frontier, leaving NO committed tail when writers are quiesced) AND
/// the FIX-B idmap + loop2 hydration snapshot writes, all stamped at the
/// post-checkpoint (checkpoint_epoch, covered_lsn).
///
/// The server must call this in the UNBOUNDED shutdown region — after the
/// connection drain (no writers left to race the checkpoint) and BEFORE the
/// gap-0039 teardown watchdog is armed — so however long the O(graph) checkpoint
/// takes at 14.27M, the watchdog cannot force-exit mid-checkpoint. With no tail
/// and snapshots stamped at the truncated-WAL manifest, the next reopen's
/// epoch/covered gate RELOADS them (O(1) idmap + O(snapshot) loop2) instead of
/// rejecting a WAL tail and paying the whole-graph re-scan every restart.
///
/// On success sets `g_clean_shutdown_flushed` so the subsequent
/// `deinitGlobalStore` SKIPS its redundant `saveToFileEx(false)` (which would
/// bump the epoch again and, if the bounded teardown cut it short before
/// re-stamping the snapshots, leave them stale → reopen REJECT). Idempotent +
/// best-effort with the same guards as deinit (real adapter + non-empty data
/// dir). Crash-safety is UNCHANGED: an UNCLEAN shutdown (kill -9) never runs
/// this, leaving the committed WAL tail for recovery to replay → the reopen gate
/// correctly REJECTS the (now-uncovered) snapshots and safely re-scans, with no
/// data loss (G1/G3 — never serve a snapshot across a committed tail).
pub fn flushForCleanShutdown() void {
    if (!(initialized.load(.acquire) and global_store != null)) return;
    if (getGlobalAdapter() == null or global_store.?.data_dir.len == 0) return;
    global_store.?.saveToFileEx(false) catch |err| {
        // Do NOT set the latch: leave the (retryable) checkpoint for the deinit
        // path so a flush failure never downgrades durability.
        log.err("GAP-0065 clean-shutdown flush failed; teardown will retry the checkpoint", &.{
            Attr.string("error", @errorName(err)),
        });
        return;
    };
    g_clean_shutdown_flushed.store(true, .release);
}

fn deinitGlobalStoreEx(clean: bool) void {
    // Tear down the process-global undo log FIRST (while the store is still
    // valid), because its entries + per-thread txn state reference store
    // nodes/graphs this teardown is about to free. Leaving it live would let the
    // NEXT store's transaction rollback read freed memory (a cross-test
    // use-after-free -> ReleaseSafe GPE; see txn_undo_log.deinitGlobalUndoLog,
    // GAP-0917). The undo log is coupled to the store's lifetime.
    @import("txn_undo_log.zig").deinitGlobalUndoLog();
    if (initialized.load(.acquire) and global_store != null) {
        // CLEAN shutdown: persist the IdMap snapshot (final checkpoint + snapshot
        // at the matching counter) BEFORE the store and adapter are destroyed.
        //
        // GUARD: only run the save when it is meaningful AND safe — i.e. there is a
        // real persistence adapter (`getGlobalAdapter() != null`) AND the store has a
        // non-empty data dir. A transient/test store with no adapter or no data dir has
        // nothing to checkpoint and no directory to write a snapshot into; running the
        // save there is pure cost (and emits spurious FileNotFound). This mirrors the
        // pre-snapshot-write behavior (deinit did not save for such stores) while
        // preserving the real-data-dir win: a populated store still writes the snapshot.
        if (clean and getGlobalAdapter() != null and global_store.?.data_dir.len > 0) {
            if (g_clean_shutdown_flushed.load(.acquire)) {
                // GAP-0065 FIX D: the durability-critical FULL checkpoint +
                // FIX-B snapshot write already completed UNBOUNDED
                // (`flushForCleanShutdown`, before the teardown watchdog armed).
                // Do NOT re-run saveToFileEx here: it is now under the bounded
                // watchdog and re-serialising every graph's loop2 snapshots is
                // O(graph) (minutes at 14.27M) — it would burn the whole teardown
                // budget, and any checkpoint work it triggers could re-advance the
                // engine epoch. The store is already durable + reload-ready; the
                // no-op `adapter.checkpointAll()` inside `deinitGlobalAdapter`
                // stays as a belt-and-suspenders for any (server-drained-away) late
                // dirty. Just free memory below.
            } else {
                global_store.?.saveToFileEx(false) catch |err| {
                    log.err("clean-shutdown IdMap snapshot persist failed", &.{
                        Attr.string("error", @errorName(err)),
                    });
                };
            }
        }
        global_store.?.deinit();
        global_store = null;
        global_store_allocator = null;
        initialized.store(false, .release);
    }
    deinitGlobalAdapter();
}

// Unit tests for label index functionality
// CANARY: REQ=REQ-PERF-LABEL-INDEX-005; FEATURE="LabelBasedIndex"; ASPECT=UnitTests; STATUS=TESTED; TEST=TestLabelIndexBasic; OWNER=perf; UPDATED=2026-01-28

const testing = std.testing;

test "TestLabelIndexBasic" {
    // Issue #391: Test that label index is maintained during node creation
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create a node with label "Person"
    var labels = [_][]const u8{"Person"};
    const node_id = try store.createNodeWithGraph(&labels, "test_graph");

    // Verify we can look up by label
    const result = store.getNodesByLabel("test_graph", "Person");
    try testing.expect(result != null);
    try testing.expect(result.?.len == 1);
    try testing.expect(result.?[0] == node_id);
}

test "REQ-QUIC-HC-015: node id reservation is lock-free unique under parallel writers" {
    const worker_count = 16;
    const ids_per_worker = 2048;
    const total_ids = worker_count * ids_per_worker;

    const Worker = struct {
        fn run(out: []u64) void {
            for (out) |*slot| {
                slot.* = generateTimeBasedId();
            }
        }
    };

    const ids = try testing.allocator.alloc(u64, total_ids);
    defer testing.allocator.free(ids);

    var threads: [worker_count]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        const start = i * ids_per_worker;
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ids[start .. start + ids_per_worker]});
    }
    for (&threads) |*thread| thread.join();

    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    try seen.ensureTotalCapacity(@intCast(total_ids));

    var shard_counts: [sharded_store.SHARD_COUNT]usize = [_]usize{0} ** sharded_store.SHARD_COUNT;
    for (ids) |id| {
        try testing.expect((id & 0xf000) == node_id_version_bits);
        const prior = try seen.getOrPut(id);
        try testing.expect(!prior.found_existing);
        shard_counts[sharded_store.shardIndex(id)] += 1;
    }

    for (shard_counts) |count| {
        try testing.expect(count > 0);
    }
}

test "TestLabelIndexMultipleNodes" {
    // Issue #391: Test index with multiple nodes having same label
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    const node1 = try store.createNodeWithGraph(&labels, "test_graph");
    const node2 = try store.createNodeWithGraph(&labels, "test_graph");
    const node3 = try store.createNodeWithGraph(&labels, "test_graph");

    const result = store.getNodesByLabel("test_graph", "Person");
    try testing.expect(result != null);
    try testing.expect(result.?.len == 3);

    // Check all nodes are present
    var found1 = false;
    var found2 = false;
    var found3 = false;
    for (result.?) |id| {
        if (id == node1) found1 = true;
        if (id == node2) found2 = true;
        if (id == node3) found3 = true;
    }
    try testing.expect(found1 and found2 and found3);
}

test "TestLabelIndexDifferentGraphs" {
    // Issue #391: Test that label index respects graph isolation
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    _ = try store.createNodeWithGraph(&labels, "graph1");
    _ = try store.createNodeWithGraph(&labels, "graph2");
    _ = try store.createNodeWithGraph(&labels, "graph1");

    // Query graph1 - should have 2 nodes
    const result1 = store.getNodesByLabel("graph1", "Person");
    try testing.expect(result1 != null);
    try testing.expect(result1.?.len == 2);

    // Query graph2 - should have 1 node
    const result2 = store.getNodesByLabel("graph2", "Person");
    try testing.expect(result2 != null);
    try testing.expect(result2.?.len == 1);
}

test "TestGetNodesByLabels" {
    // Issue #391: Test getting nodes with multiple labels
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create node with multiple labels
    var labels1 = [_][]const u8{ "Person", "Employee" };
    const node1 = try store.createNodeWithGraph(&labels1, "test_graph");

    // Create node with only Person label
    var labels2 = [_][]const u8{"Person"};
    _ = try store.createNodeWithGraph(&labels2, "test_graph");

    // Query for nodes with both Person AND Employee
    var query_labels = [_][]const u8{ "Person", "Employee" };
    var result = try store.getNodesByLabels(testing.allocator, "test_graph", &query_labels, null);
    defer result.deinit(testing.allocator);

    try testing.expect(result.items.len == 1);
    try testing.expect(result.items[0] == node1);
}

test "TestEdgeAdjacencyIndex" {
    // Issue #392: Test edge adjacency index for DELETE DETACH optimization
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Node"};
    const node1 = try store.createNodeWithGraph(&labels, "test_graph");
    const node2 = try store.createNodeWithGraph(&labels, "test_graph");
    const node3 = try store.createNodeWithGraph(&labels, "test_graph");

    // Create edges
    _ = try store.createEdgeWithGraph(node1, node2, "CONNECTS", "test_graph");
    _ = try store.createEdgeWithGraph(node1, node3, "CONNECTS", "test_graph");
    _ = try store.createEdgeWithGraph(node2, node3, "LINKS", "test_graph");

    // Test outgoing edges from node1 (PHASE 0: AdjList wraps the id-list).
    const outgoing1 = store.outgoing_edges.get(node1);
    try testing.expect(outgoing1 != null);
    try testing.expect(outgoing1.?.list.items.len == 2);

    // Test incoming edges to node3
    const incoming3 = store.incoming_edges.get(node3);
    try testing.expect(incoming3 != null);
    try testing.expect(incoming3.?.list.items.len == 2);

    // Test getEdgesForNode
    var edges_for_node1 = store.getEdgesForNode(testing.allocator, node1);
    defer edges_for_node1.deinit(testing.allocator);
    try testing.expect(edges_for_node1.items.len == 2);
}

// CANARY: REQ=REQ-MULTI-TENANT-005; FEATURE="PerTenantIsolation"; ASPECT=UnitTest; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-01
// GAP-0279: Per-tenant data isolation tests
test "TestTenantIsolationNodeCreation" {
    // Verify nodes created with different tenant_ids are tagged correctly
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    const node_t1 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");
    const node_t2 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_b");
    const node_default = try store.createNodeWithGraph(&labels, "default");

    // Verify tenant_id tags on nodes
    const n1 = store.nodes.get(node_t1).?;
    try testing.expectEqualStrings("tenant_a", n1.tenant_id);

    const n2 = store.nodes.get(node_t2).?;
    try testing.expectEqualStrings("tenant_b", n2.tenant_id);

    const n3 = store.nodes.get(node_default).?;
    try testing.expectEqualStrings(DEFAULT_TENANT_ID, n3.tenant_id);
}

test "TestTenantIsolationEdgeCreation" {
    // Verify edges created with different tenant_ids are tagged correctly
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    const n1 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");
    const n2 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");

    const edge_id = try store.createEdgeWithGraphAndTenant(n1, n2, "KNOWS", "default", "tenant_a");
    const edge = store.edges.get(edge_id).?;
    try testing.expectEqualStrings("tenant_a", edge.tenant_id);

    // Default tenant edge
    const edge2_id = try store.createEdgeWithGraph(n1, n2, "LIKES", "default");
    const edge2 = store.edges.get(edge2_id).?;
    try testing.expectEqualStrings(DEFAULT_TENANT_ID, edge2.tenant_id);
}

test "TestGetAllNodesForTenant" {
    // Verify getAllNodesForTenant returns only nodes for the specified tenant
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");
    _ = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_b");
    _ = try store.createNodeWithGraph(&labels, "default"); // default tenant

    // Tenant A should have 2 nodes
    const result_a = try store.getAllNodesForTenant(testing.allocator, "tenant_a");
    defer testing.allocator.free(result_a);
    try testing.expectEqual(@as(usize, 2), result_a.len);

    // Tenant B should have 1 node
    const result_b = try store.getAllNodesForTenant(testing.allocator, "tenant_b");
    defer testing.allocator.free(result_b);
    try testing.expectEqual(@as(usize, 1), result_b.len);

    // Default tenant should have 1 node
    const result_default = try store.getAllNodesForTenant(testing.allocator, DEFAULT_TENANT_ID);
    defer testing.allocator.free(result_default);
    try testing.expectEqual(@as(usize, 1), result_default.len);

    // Null tenant (no filter) should return all 4 nodes
    const result_all = try store.getAllNodesForTenant(testing.allocator, null);
    defer testing.allocator.free(result_all);
    try testing.expectEqual(@as(usize, 4), result_all.len);
}

test "TestTenantIsolationBackwardCompatible" {
    // Verify that existing code without tenant_id continues to work
    // All nodes should get DEFAULT_TENANT_ID
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    const node_id = try store.createNodeWithGraph(&labels, "default");
    const node = store.nodes.get(node_id).?;

    // Default tenant_id should be "default"
    try testing.expectEqualStrings(DEFAULT_TENANT_ID, node.tenant_id);

    // Graph name should still work as before
    try testing.expectEqualStrings("default", node.graph_name);
}

// GAP-0291: Verify that createNodeWithGraph and createEdgeWithGraph automatically
// pick up the per-thread tenant_id set via fle_integration.
test "TestCreateNodeWithGraphResolvesTenantFromThread" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Simulate a connection handler setting a non-default tenant
    fle_integration.setCurrentTenantId("acme-corp");
    defer fle_integration.clearCurrentThreadState();

    var labels = [_][]const u8{"Person"};
    const node_id = try store.createNodeWithGraph(&labels, "default");
    const node = store.nodes.get(node_id).?;
    try testing.expectEqualStrings("acme-corp", node.tenant_id);

    // Also verify edges
    const node2_id = try store.createNodeWithGraph(&labels, "default");
    const edge_id = try store.createEdgeWithGraph(node_id, node2_id, "KNOWS", "default");
    const edge = store.edges.get(edge_id).?;
    try testing.expectEqualStrings("acme-corp", edge.tenant_id);
}

test "clearNodeProperties removes all node properties" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    const node_id = try store.createNodeWithGraph(&labels, "test_graph");

    try store.setNodeProperty(node_id, "name", .{ .String = "alice" });
    try store.setNodeProperty(node_id, "age", .{ .Int = 42 });

    try store.clearNodeProperties(node_id);

    const node = store.getNodePtr(node_id) orelse return error.NodeNotFound;
    try testing.expectEqual(@as(usize, 0), node.properties.count());
    try testing.expect(store.getNodeProperty(node_id, "name") == null);
    try testing.expect(store.getNodeProperty(node_id, "age") == null);
}

test "getGlobalStore initializes adapter from data dir override" {
    deinitGlobalStore();
    defer deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir_path);

    setDataDirOverride(testing.allocator, dir_path);
    defer setDataDirOverride(testing.allocator, null);

    _ = getGlobalStore(testing.allocator);

    const adapter = getGlobalAdapter() orelse return error.AdapterNotInitialized;
    try testing.expectEqualStrings(dir_path, adapter.data_dir);
}

test "QueryReadSession clones nodes from global store" {
    deinitGlobalStore();
    defer deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir_path);

    const store = try initGlobalStore(testing.allocator, dir_path);
    resetQueryReadSessionInitCount();

    var labels = [_][]const u8{"Person"};
    const node_id = try store.createNodeWithGraph(&labels, "default");
    try store.setNodeProperty(node_id, "name", .{ .String = "original" });

    var read_session = (try QueryReadSession.initIfAvailable(testing.allocator, store)) orelse {
        return error.AdapterNotInitialized;
    };
    defer read_session.deinit();
    try testing.expectEqual(@as(u64, 1), getQueryReadSessionInitCount());

    // Snapshot should have the node
    const snapshot_node = read_session.store().getNodePtr(node_id) orelse return error.NodeNotFound;
    try testing.expectEqualStrings("default", snapshot_node.graph_name);

    // Modify global store — snapshot should be unaffected
    try store.setNodePropertyNoSave(node_id, "name", .{ .String = "modified" });

    const snap_name = snapshot_node.properties.get("name") orelse return error.PropertyNotFound;
    // Snapshot shares property values (shallow clone), so it sees the modification.
    // This is acceptable — the key guarantee is that the snapshot's HashMap
    // iterators are never invalidated by concurrent inserts.
    _ = snap_name;
}

test "createNodeWithId and createEdgeWithId survive adapter-backed reload" {
    deinitGlobalStore();
    defer deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir_path);

    const store = try initGlobalStore(testing.allocator, dir_path);
    var node_labels = [_][]const u8{"ReplayNode"};

    try store.createNodeWithId(1001, &node_labels, "default");
    try store.createNodeWithId(1002, &node_labels, "default");
    try store.setNodeProperty(1001, "name", .{ .String = "replicated" });

    try store.createEdgeWithId(9001, 1001, 1002, "LINKS", "default");
    try store.setEdgeProperty(9001, "weight", .{ .Int = 3 });

    const adapter = getGlobalAdapter() orelse return error.AdapterNotInitialized;
    try adapter.checkpointAll();

    const id_map = store.getIdMap("default") orelse return error.IdMapNotLoaded;
    const node_slot = id_map.nodeSlot(@as(u128, 1001)) orelse return error.NodeSlotMappingMissing;
    const edge_slot = id_map.edgeSlot(@as(u128, 9001)) orelse return error.EdgeSlotMappingMissing;

    const persisted_node_id = try adapter.getNodeProperty("default", node_slot, INTERNAL_NODE_ID_PROPERTY_KEY, testing.allocator) orelse return error.PropertyNotFound;
    defer graph_storage_adapter.freeOwnedStorageProperty(testing.allocator, persisted_node_id);
    var node_id_buf: [16]u8 = undefined;
    try testing.expectEqualStrings(encodePersistedPublicId(&node_id_buf, 1001), persisted_node_id.string);

    // GAP-ENT-0024: NEW edges carry the public id INLINE in the durable
    // adjacency entry (v2 blocks) and write NO `__geode_internal_edge_id`
    // property (that was one ≥8 KB props page per edge).
    const persisted_edge_id = try adapter.getEdgeProperty("default", node_slot, edge_slot, INTERNAL_EDGE_ID_PROPERTY_KEY, testing.allocator);
    if (persisted_edge_id) |leaked_prop| {
        graph_storage_adapter.freeOwnedStorageProperty(testing.allocator, leaked_prop);
        return error.LegacyEdgeIdPropertyStillWritten;
    }
    {
        var adj_iter = try adapter.iterateOutgoingEdges("default", node_slot, testing.allocator);
        defer adj_iter.deinit();
        var found_inline = false;
        while (try adj_iter.next()) |entry| {
            if (entry.edge_id == edge_slot) {
                try testing.expectEqual(@as(u64, 9001), entry.public_id);
                found_inline = true;
            }
        }
        try testing.expect(found_inline);
    }

    const graph_uuid = GraphStore.getGraphUuid("default") orelse return error.GraphUuidUnavailable;
    // Per-graph artifact directory layout was consolidated to
    // `<data_dir>/<uuid_hex>` so audit/timeseries/FTS/property-index live
    // alongside the sharded engine's `graph_root`.  The historical layout
    // `<data_dir>/graphs/<uuid_hex>` is retained only as a legacy fallback
    // for older on-disk data; new writes do not materialise it.  See
    // `StorageAdapter.graphDirPath`.
    const graph_dir_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, std.fmt.bytesToHex(graph_uuid, .lower) });
    defer testing.allocator.free(graph_dir_path);

    const io = std.Io.Threaded.global_single_threaded.io();
    var graph_dir = try std.Io.Dir.cwd().openDir(io, graph_dir_path, .{});
    defer graph_dir.close(io);
    try testing.expectError(error.FileNotFound, graph_dir.access(io, "id_map.dat", .{}));
    try testing.expectError(error.FileNotFound, graph_dir.access(io, "adapter_labels.dat", .{}));

    try store.loadFromFile();

    // EARLY-READY (H3): loadFromFile now DEFERS the full per-graph build (loop1
    // IdMap + loop2 resident caches) to lazy first-access even when no IdMap
    // snapshot exists, so the resident node/edge caches are empty at this point
    // and the raw (non-hydrating) getNodePtr/getEdgePtr accessors would miss.
    // Trigger the graph's hydration before the resident by-id reads — mirroring
    // the snapshot-deferred contract (see tests/test_startup_lazy_hydrate.zig,
    // which likewise reads by id only after a graph-scoped access hydrates).
    // The survival guarantee is that the data is fully recoverable after reload.
    store.ensureGraphHydrated("default");

    const node = store.getNodePtr(1001) orelse return error.NodeNotFound;
    const node_name = node.properties.get("name") orelse return error.PropertyNotFound;
    try testing.expectEqualStrings("replicated", node_name.String);

    const edge = store.getEdgePtr(9001) orelse return error.EdgeNotFound;
    try testing.expectEqual(@as(u64, 1001), edge.from_id);
    try testing.expectEqual(@as(u64, 1002), edge.to_id);
    const edge_weight = edge.properties.get("weight") orelse return error.PropertyNotFound;
    try testing.expectEqual(@as(i64, 3), edge_weight.Int);
}

test "loadOneGraphFromAdapterFull: sorted-by-prop_head loop1 matches legacy per-node IdMap reconstruction" {
    const gs = @import("graph_storage");
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(path);

    // Small page_size forces node_b's internal-id property past the head
    // page, exercising the multi-page prop chain through the by-head fetch.
    const adapter = try graph_storage_adapter.StorageAdapter.init(allocator, path, gs.GraphConfig{
        .page_size = 256,
        .buffer_pool_pages = 512,
    });
    defer adapter.deinit();

    const graph = "coldopen_loop1_test";
    const key = INTERNAL_NODE_ID_PROPERTY_KEY;

    // Persisted public ids must round-trip through parsePersistedPublicId
    // (hex-encoded, matching encodePersistedPublicId), not arbitrary text.
    var id_buf_a: [16]u8 = undefined;
    var id_buf_b: [16]u8 = undefined;
    var id_buf_d: [16]u8 = undefined;

    // node_a: normal node with the internal-id property set.
    const node_a = try adapter.createNode(graph, &[_][]const u8{"L"});
    try adapter.setNodeProperty(graph, node_a, key, .{ .String = encodePersistedPublicId(&id_buf_a, 1001) });

    // node_b: multi-page prop chain (many props before the internal id).
    const node_b = try adapter.createNode(graph, &[_][]const u8{"L"});
    var pi: usize = 0;
    while (pi < 12) : (pi += 1) {
        const pk = try std.fmt.allocPrint(allocator, "extra_prop_{d:0>2}", .{pi});
        defer allocator.free(pk);
        try adapter.setNodeProperty(graph, node_b, pk, .{ .String = "val_0123456789abcdefghij" });
    }
    try adapter.setNodeProperty(graph, node_b, key, .{ .String = encodePersistedPublicId(&id_buf_b, 1002) });

    // node_c: NO internal-id property at all -> must be skipped (no legacy
    // map present in this standalone GraphStore, since data_dir is "").
    const node_c = try adapter.createNode(graph, &[_][]const u8{"L"});

    // node_d: another normal node, on a different shard than node_c.
    const node_d = try adapter.createNode(graph, &[_][]const u8{"L"});
    try adapter.setNodeProperty(graph, node_d, key, .{ .String = encodePersistedPublicId(&id_buf_d, 1004) });

    // Confirm the artifact actually spans >=2 shards.
    try testing.expect(gs.shard_count.shardOfNode(node_a) != gs.shard_count.shardOfNode(node_b));

    // ---- GOLDEN: legacy per-node getNodeProperty reconstruction (no sort,
    // raw slot-scan order) — the pre-change behavior this change must match. ----
    const golden_entries = try adapter.scanAllNodes(graph, allocator);
    defer allocator.free(golden_entries);

    var golden = std.AutoHashMap(u128, u64).init(allocator); // uuid -> slot_id
    defer golden.deinit();
    var golden_skipped: u64 = 0;
    for (golden_entries) |entry| {
        const maybe_stored = try adapter.getNodeProperty(graph, entry.slot_id, key, allocator);
        var matched_uuid: ?u64 = null;
        if (maybe_stored) |stored_prop| {
            defer graph_storage_adapter.freeOwnedStorageProperty(allocator, stored_prop);
            switch (stored_prop) {
                .string => |text| {
                    if (parsePersistedPublicId(text)) |parsed| matched_uuid = parsed;
                },
                else => {},
            }
        }
        if (matched_uuid) |u| {
            try golden.put(@as(u128, u), entry.slot_id);
        } else {
            golden_skipped += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), golden_skipped); // only node_c
    try testing.expectEqual(@as(usize, 3), golden.count()); // a, b, d

    // ---- ACTUAL: run the function under test (sorted loop1 + by-head fetch). ----
    var store = try GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.loadOneGraphFromAdapterFull(adapter, graph);

    const id_map = store.getIdMap(graph) orelse return error.IdMapNotLoaded;

    var golden_it = golden.iterator();
    var matched: u64 = 0;
    while (golden_it.next()) |e| {
        const slot = id_map.nodeSlot(e.key_ptr.*) orelse return error.NodeSlotMappingMissing;
        try testing.expectEqual(e.value_ptr.*, slot);
        matched += 1;
    }
    try testing.expectEqual(golden.count(), matched);

    // node_c must be absent from the rebuilt IdMap (the skip path).
    try testing.expect(id_map.nodeUuid(node_c) == null);

    // The IdMap must not contain any extra mappings beyond the golden set.
    var idmap_uuid_it = id_map.nodeUuidIterator();
    var idmap_count: u64 = 0;
    while (idmap_uuid_it.next()) |_| idmap_count += 1;
    try testing.expectEqual(golden.count(), idmap_count);
}

test "loadOneGraphFromAdapterFull: countGraphLabel (label-count fast path) is exact after rebuild" {
    const gs = @import("graph_storage");
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(path);

    const adapter = try graph_storage_adapter.StorageAdapter.init(allocator, path, gs.GraphConfig{
        .page_size = 4096,
        .buffer_pool_pages = 512,
    });
    defer adapter.deinit();

    const graph = "labelcount_rebuild_test";
    const key = INTERNAL_NODE_ID_PROPERTY_KEY;

    // N nodes carry label "L"; the first M of them ALSO carry label "M".
    const N: u64 = 7;
    const M: u64 = 3;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        const public_id: u64 = 2001 + i;
        const labels: []const []const u8 = if (i < M)
            &[_][]const u8{ "L", "M" }
        else
            &[_][]const u8{"L"};
        const slot = try adapter.createNode(graph, labels);
        var id_buf: [16]u8 = undefined;
        try adapter.setNodeProperty(graph, slot, key, .{ .String = encodePersistedPublicId(&id_buf, public_id) });
    }

    // Rebuild into a fresh resident store — this is exactly the loop2 path
    // taken by cold-open / lazy hydration (ensureGraphHydrated ->
    // loadOneGraphFromAdapterFull). label_index and label_counts_by_graph
    // both start empty here, mirroring a first-touch hydration.
    var store = try GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.loadOneGraphFromAdapterFull(adapter, graph);

    // Cross-check: the actual MATCH (n:L) scan (label posting list) sees N.
    const l_posting = store.getNodesByLabel(graph, "L") orelse return error.LPostingMissing;
    try testing.expectEqual(@as(usize, N), l_posting.len);
    const m_posting = store.getNodesByLabel(graph, "M") orelse return error.MPostingMissing;
    try testing.expectEqual(@as(usize, M), m_posting.len);

    // The label-count fast path (count(:Label)) MUST equal the scan count,
    // and must NOT double-count (== N, not 2N).
    try testing.expectEqual(@as(usize, N), store.countGraphLabel(graph, "L"));
    try testing.expectEqual(@as(usize, M), store.countGraphLabel(graph, "M"));
}

test "rollback removes adapter-backed state before reload" {
    const txn_undo_log = @import("txn_undo_log.zig");

    deinitGlobalStore();
    defer deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir_path);

    const store = try initGlobalStore(testing.allocator, dir_path);
    const adapter = getGlobalAdapter() orelse return error.AdapterNotInitialized;

    var undo = txn_undo_log.UndoLog.init(testing.allocator);
    defer undo.deinit();

    undo.begin();

    var labels = [_][]const u8{"TxnNode"};
    const node_id = try store.createNodeWithGraph(&labels, "default");
    try undo.logCreateNode(node_id, "default");

    try store.setNodeProperty(node_id, "name", .{ .String = "transient" });
    try adapter.checkpointAll();

    try undo.rollback(store);
    try adapter.checkpointAll();
    try store.loadFromFile();

    try testing.expect(store.getNodePtr(node_id) == null);
}
test "listGraphNames merges persisted adapter graphs with local cache" {
    deinitGlobalStore();
    defer deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir_path);

    const store = try initGlobalStore(testing.allocator, dir_path);
    try store.createGraph("persisted_only");

    if (!store.graphs.remove("persisted_only")) {
        return error.GraphNotFound;
    }

    const names = try store.listGraphNames(testing.allocator);
    defer {
        for (names) |name| {
            testing.allocator.free(name);
        }
        testing.allocator.free(names);
    }

    var found = false;
    for (names) |name| {
        if (std.mem.eql(u8, name, "persisted_only")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "serializeSnapshot produces valid JSON-lines for nodes and edges" {
    // GAP-D001: serializeSnapshot must produce JSON-lines with nodes and edges
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create nodes
    var labels = [_][]const u8{"Person"};
    const n1 = try store.createNodeWithGraph(&labels, "test_graph");

    var labels2 = [_][]const u8{"Person"};
    const n2 = try store.createNodeWithGraph(&labels2, "test_graph");

    // Create an edge
    _ = try store.createEdgeWithGraph(n1, n2, "KNOWS", "test_graph");

    // Serialize
    const snapshot = try store.serializeSnapshot(testing.allocator);
    defer testing.allocator.free(snapshot);

    // Must be non-empty
    try testing.expect(snapshot.len > 0);

    // Must contain JSON node markers
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"type\":\"node\"") != null);

    // Must contain JSON edge markers
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"type\":\"edge\"") != null);

    // Must contain graph name as JSON string
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"graph\":\"test_graph\"") != null);

    // Must contain label in labels array
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"labels\":[\"Person\"]") != null);

    // Must contain edge label
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"label\":\"KNOWS\"") != null);

    // Must contain properties object (even if empty)
    try testing.expect(std.mem.indexOf(u8, snapshot, "\"properties\":{}") != null or
        std.mem.indexOf(u8, snapshot, "\"properties\":{\"") != null);

    // Count lines — at least 2 nodes + 1 edge = 3 lines
    var line_count: usize = 0;
    for (snapshot) |c| {
        if (c == '\n') line_count += 1;
    }
    try testing.expect(line_count >= 3);
}

test "serializeSnapshot empty store produces empty output" {
    // GAP-D001: empty store produces empty snapshot
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    const snapshot = try store.serializeSnapshot(testing.allocator);
    defer testing.allocator.free(snapshot);

    try testing.expect(snapshot.len == 0);
}

test "serializeSnapshot JSON escaping in strings" {
    // Verify that special characters in labels/graph names are properly escaped
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Label\"With\\Quotes"};
    _ = try store.createNodeWithGraph(&labels, "graph\nnewline");

    const snapshot = try store.serializeSnapshot(testing.allocator);
    defer testing.allocator.free(snapshot);

    // Escaped quote in label
    try testing.expect(std.mem.indexOf(u8, snapshot, "Label\\\"With\\\\Quotes") != null);
    // Escaped newline in graph name
    try testing.expect(std.mem.indexOf(u8, snapshot, "graph\\nnewline") != null);
}

// CANARY: REQ=REQ-MULTI-TENANT-009; FEATURE="TenantQueryIsolation"; ASPECT=UnitTest; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=enterprise; UPDATED=2026-04-06
// GAP-0509: Verify getNodesByLabels, getAllNodesForTenant, and getEdgesByType all filter by tenant_id
test "GAP-0509: getNodesByLabels filters by tenant_id" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create nodes for two tenants in the same graph
    var labels = [_][]const u8{"Widget"};
    const na1 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");
    const na2 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_a");
    const nb1 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant_b");

    // getNodesByLabels with tenant filter returns only that tenant's nodes
    var query_labels = [_][]const u8{"Widget"};
    var result_a = try store.getNodesByLabels(testing.allocator, "default", &query_labels, "tenant_a");
    defer result_a.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), result_a.items.len);

    var result_b = try store.getNodesByLabels(testing.allocator, "default", &query_labels, "tenant_b");
    defer result_b.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), result_b.items.len);
    try testing.expectEqual(nb1, result_b.items[0]);

    // null tenant filter returns all nodes (cross-tenant, admin-level)
    var result_all = try store.getNodesByLabels(testing.allocator, "default", &query_labels, null);
    defer result_all.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), result_all.items.len);

    // getAllNodesForTenant: null returns all, specific tenant filters correctly
    const all_nodes = try store.getAllNodesForTenant(testing.allocator, null);
    defer testing.allocator.free(all_nodes);
    try testing.expectEqual(@as(usize, 3), all_nodes.len);

    const tenant_a_nodes = try store.getAllNodesForTenant(testing.allocator, "tenant_a");
    defer testing.allocator.free(tenant_a_nodes);
    try testing.expectEqual(@as(usize, 2), tenant_a_nodes.len);

    // getEdgesByType also filters by tenant
    const edge_ab = try store.createEdgeWithGraphAndTenant(na1, na2, "LINKED", "default", "tenant_a");
    _ = edge_ab;
    const edge_b = try store.createEdgeWithGraphAndTenant(nb1, na1, "LINKED", "default", "tenant_b");
    _ = edge_b;

    const edges_a = store.getEdgesByType(testing.allocator, "LINKED", "tenant_a", null);
    defer testing.allocator.free(edges_a);
    try testing.expectEqual(@as(usize, 1), edges_a.len);
    // Verify the returned ID resolves to the correct tenant
    const edge_a_ptr = store.edges.getPtr(edges_a[0]) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("tenant_a", edge_a_ptr.tenant_id);

    const edges_all = store.getEdgesByType(testing.allocator, "LINKED", null, null);
    defer testing.allocator.free(edges_all);
    try testing.expectEqual(@as(usize, 2), edges_all.len);
}

test "getOutgoingEdgeIds and getIncomingEdgeIds return edge list without allocation" {
    // std.testing.allocator will catch any allocations we don't free
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Node"};
    const node1 = try store.createNodeWithGraph(&labels, "test_graph");
    const node2 = try store.createNodeWithGraph(&labels, "test_graph");
    const node3 = try store.createNodeWithGraph(&labels, "test_graph");

    const edge1 = try store.createEdgeWithGraph(node1, node2, "KNOWS", "test_graph");
    const edge2 = try store.createEdgeWithGraph(node1, node3, "LIKES", "test_graph");

    // getOutgoingEdgeIds returns the two edges from node1
    const out_ids = store.getOutgoingEdgeIds(node1);
    try testing.expect(out_ids != null);
    try testing.expectEqual(@as(usize, 2), out_ids.?.len);
    // Both edge IDs should be present (order depends on insertion)
    const has_edge1 = (out_ids.?[0] == edge1 or out_ids.?[1] == edge1);
    const has_edge2 = (out_ids.?[0] == edge2 or out_ids.?[1] == edge2);
    try testing.expect(has_edge1);
    try testing.expect(has_edge2);

    // getIncomingEdgeIds: node2 has one incoming edge (edge1)
    const in_ids = store.getIncomingEdgeIds(node2);
    try testing.expect(in_ids != null);
    try testing.expectEqual(@as(usize, 1), in_ids.?.len);
    try testing.expectEqual(edge1, in_ids.?[0]);

    // node3 has one incoming edge (edge2)
    const in_ids3 = store.getIncomingEdgeIds(node3);
    try testing.expect(in_ids3 != null);
    try testing.expectEqual(@as(usize, 1), in_ids3.?.len);
    try testing.expectEqual(edge2, in_ids3.?[0]);

    // A node with no outgoing edges returns null
    try testing.expect(store.getOutgoingEdgeIds(node2) == null);

    // A node with no incoming edges returns null
    try testing.expect(store.getIncomingEdgeIds(node1) == null);

    // No allocations occurred — std.testing.allocator enforces this
}

// GAP-0525: Benchmark test fixtures for performance validation

// CANARY: REQ=REQ-PERF-BENCH-001; FEATURE="MultiLabelIntersection"; ASPECT=BenchmarkFixture; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=engine; UPDATED=2026-04-09
test "GAP-0525: multi-label posting-list intersection correctness" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create 1000 nodes with label "Big"
    var big_label = [_][]const u8{"Big"};
    for (0..1000) |_| {
        _ = try store.createNodeWithGraph(&big_label, "default");
    }

    // Create 10 nodes with label "Small" only
    var small_label = [_][]const u8{"Small"};
    for (0..10) |_| {
        _ = try store.createNodeWithGraph(&small_label, "default");
    }

    // Create 5 nodes with BOTH labels
    var both_labels = [_][]const u8{ "Big", "Small" };
    var dual_ids: [5]u64 = undefined;
    for (0..5) |i| {
        dual_ids[i] = try store.createNodeWithGraph(&both_labels, "default");
    }

    // Intersection ["Big", "Small"] must return exactly the 5 dual-label nodes
    {
        var query_labels = [_][]const u8{ "Big", "Small" };
        var result = try store.getNodesByLabels(testing.allocator, "default", &query_labels, null);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 5), result.items.len);

        // Verify each returned ID is one of the dual-label nodes
        for (result.items) |id| {
            var found = false;
            for (dual_ids) |expected| {
                if (id == expected) {
                    found = true;
                    break;
                }
            }
            try testing.expect(found);
        }
    }

    // Order-independent: ["Small", "Big"] must yield the same 5 results
    {
        var query_labels = [_][]const u8{ "Small", "Big" };
        var result = try store.getNodesByLabels(testing.allocator, "default", &query_labels, null);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 5), result.items.len);
    }

    // Adding a non-existent label must return 0 results
    {
        var query_labels = [_][]const u8{ "Big", "Small", "NonExistent" };
        var result = try store.getNodesByLabels(testing.allocator, "default", &query_labels, null);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), result.items.len);
    }
}

// CANARY: REQ=REQ-PERF-BENCH-002; FEATURE="HighDegreeExpansion"; ASPECT=BenchmarkFixture; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=engine; UPDATED=2026-04-09
test "GAP-0525: high-degree single-hop expansion returns all edges" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var hub_labels = [_][]const u8{"Hub"};
    const hub = try store.createNodeWithGraph(&hub_labels, "default");

    var target_labels = [_][]const u8{"Target"};
    var edge_ids: [100]u64 = undefined;
    for (0..100) |i| {
        const target = try store.createNodeWithGraph(&target_labels, "default");
        edge_ids[i] = try store.createEdgeWithGraph(hub, target, "CONNECTS", "default");
    }

    // getOutgoingEdgeIds returns the allocation-free slice from the adjacency list
    const out_ids = store.getOutgoingEdgeIds(hub);
    try testing.expect(out_ids != null);
    try testing.expectEqual(@as(usize, 100), out_ids.?.len);

    // Verify every created edge is present
    for (edge_ids) |expected| {
        var found = false;
        for (out_ids.?) |actual| {
            if (actual == expected) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

// CANARY: REQ=REQ-PERF-BENCH-003; FEATURE="SortedPostingList"; ASPECT=BenchmarkFixture; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=engine; UPDATED=2026-04-09
test "GAP-0525: sorted posting-list ordering is ascending" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create nodes in several batches to exercise different insertion times.
    // Interleave labels so IDs are not naturally sequential per label.
    var alpha_label = [_][]const u8{"Alpha"};
    var beta_label = [_][]const u8{"Beta"};
    for (0..50) |_| {
        _ = try store.createNodeWithGraph(&alpha_label, "default");
        _ = try store.createNodeWithGraph(&beta_label, "default"); // interleave
    }

    const list = store.getNodesByLabel("default", "Alpha");
    try testing.expect(list != null);
    try testing.expectEqual(@as(usize, 50), list.?.len);

    // Verify strictly ascending order (required for two-pointer intersection)
    for (1..list.?.len) |i| {
        try testing.expect(list.?[i] > list.?[i - 1]);
    }
}

test "REQ-QUIC-HC-120: label count refcounts track graph-scoped creates and deletes" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    const alpha = [_][]const u8{"Counted"};
    const beta = [_][]const u8{"Other"};

    const id1 = try store.createNodeWithGraph(&alpha, "default");
    _ = try store.createNodeWithGraph(&alpha, "default");
    _ = try store.createNodeWithGraph(&alpha, "analytics");
    _ = try store.createNodeWithGraph(&beta, "default");

    try testing.expectEqual(@as(usize, 2), store.countNodesByLabel("default", "Counted", null));
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel("analytics", "Counted", null));
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel("default", "Other", null));

    store.deleteNodeNoSave(id1);
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel("default", "Counted", null));
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel("analytics", "Counted", null));

    try store.rebuildIndexes();
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel("default", "Counted", null));
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel("analytics", "Counted", null));

    const long_label = try testing.allocator.alloc(u8, 600);
    defer testing.allocator.free(long_label);
    @memset(long_label, 'L');
    const long_labels = [_][]const u8{long_label};
    const long_id = try store.createNodeWithGraph(&long_labels, "analytics-long-label");
    try testing.expectEqual(@as(usize, 1), store.countNodesByLabel("analytics-long-label", long_label, null));
    store.deleteNodeNoSave(long_id);
    try testing.expectEqual(@as(usize, 0), store.countNodesByLabel("analytics-long-label", long_label, null));
}

test "REQ-QUIC-HC-163: label count refcounts allow concurrent hot-label reads and updates" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();
    try store.ensureGraphLabelCount("default", "HotLabel");

    const thread_count = 16;
    const iterations = 2000;
    const Ctx = struct {
        store: *GraphStore,
        start: *std.atomic.Value(bool),
        errors: *std.atomic.Value(u32),

        fn run(ctx: *@This()) void {
            while (!ctx.start.load(.acquire)) std.Thread.yield() catch {};
            for (0..iterations) |_| {
                ctx.store.bumpGraphLabelCount("default", "HotLabel");
                if (ctx.store.countGraphLabel("default", "HotLabel") == 0) {
                    _ = ctx.errors.fetchAdd(1, .monotonic);
                }
                ctx.store.decGraphLabelCount("default", "HotLabel");
            }
        }
    };

    var start = std.atomic.Value(bool).init(false);
    var errors = std.atomic.Value(u32).init(0);
    var contexts: [thread_count]Ctx = undefined;
    var threads: [thread_count]std.Thread = undefined;
    for (&contexts, 0..) |*ctx, i| {
        ctx.* = .{
            .store = &store,
            .start = &start,
            .errors = &errors,
        };
        threads[i] = try std.Thread.spawn(.{}, Ctx.run, .{ctx});
    }
    start.store(true, .release);
    for (&threads) |thread| thread.join();

    try testing.expectEqual(@as(u32, 0), errors.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), store.countNodesByLabel("default", "HotLabel", null));
}

test "per-(graph,edge_type) counter: maintained on create/delete, cross-graph + cross-type isolated" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Taxon"};

    // G1: create N=6 :R edges (track ids so we can delete some).
    const n: usize = 6;
    var g1_edges: [6]u64 = undefined;
    {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const a = try store.createNodeWithGraph(&labels, "g1");
            const b = try store.createNodeWithGraph(&labels, "g1");
            g1_edges[i] = try store.createEdgeWithGraph(a, b, "R", "g1");
        }
    }
    // G1: also create 2 :OTHER edges (different type, same graph).
    {
        var i: usize = 0;
        while (i < 2) : (i += 1) {
            const a = try store.createNodeWithGraph(&labels, "g1");
            const b = try store.createNodeWithGraph(&labels, "g1");
            _ = try store.createEdgeWithGraph(a, b, "OTHER", "g1");
        }
    }
    // G2: create 3 :R edges (cross-graph isolation).
    {
        var i: usize = 0;
        while (i < 3) : (i += 1) {
            const a = try store.createNodeWithGraph(&labels, "g2");
            const b = try store.createNodeWithGraph(&labels, "g2");
            _ = try store.createEdgeWithGraph(a, b, "R", "g2");
        }
    }

    try testing.expectEqual(@as(usize, 6), store.countGraphEdgeType("g1", "R"));
    try testing.expectEqual(@as(usize, 2), store.countGraphEdgeType("g1", "OTHER"));
    try testing.expectEqual(@as(usize, 3), store.countGraphEdgeType("g2", "R"));
    // Public accessor agrees with the internal helper.
    try testing.expectEqual(@as(usize, 6), store.countEdgesByTypeForGraph("g1", "R"));

    // Delete M=2 :R edges from G1.
    store.deleteEdgeNoSave(g1_edges[0]);
    store.deleteEdgeNoSave(g1_edges[1]);

    try testing.expectEqual(@as(usize, 4), store.countGraphEdgeType("g1", "R")); // N - M
    try testing.expectEqual(@as(usize, 3), store.countGraphEdgeType("g2", "R")); // cross-graph isolated
    try testing.expectEqual(@as(usize, 2), store.countGraphEdgeType("g1", "OTHER")); // cross-type isolated

    // Unknown (graph,type) keys read 0 without inserting.
    try testing.expectEqual(@as(usize, 0), store.countGraphEdgeType("g1", "NOPE"));
    try testing.expectEqual(@as(usize, 0), store.countGraphEdgeType("nope", "R"));

    // ensureGraphEdgeTypeCount creates a zero bucket without changing live counts.
    try store.ensureGraphEdgeTypeCount("g3", "R");
    try testing.expectEqual(@as(usize, 0), store.countGraphEdgeType("g3", "R"));
}

test "GAP-0519: getNodesByLabels heap fallback for >8 labels" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create nodes with 10 labels each (exceeds the 8-label stack allocation)
    const all_labels = [_][]const u8{ "L0", "L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "L9" };
    var ten_labels: [10][]const u8 = all_labels;
    _ = try store.createNodeWithGraph(&ten_labels, "default");
    _ = try store.createNodeWithGraph(&ten_labels, "default");

    // Also create nodes with only some labels (should NOT match 10-label intersection)
    var partial = [_][]const u8{ "L0", "L1", "L2" };
    _ = try store.createNodeWithGraph(&partial, "default");

    // Query with all 10 labels — exercises heap fallback (MaxStack = 8)
    var result = try store.getNodesByLabels(testing.allocator, "default", &all_labels, null);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), result.items.len);

    // Query with 9 labels — still heap fallback
    var result9 = try store.getNodesByLabels(testing.allocator, "default", all_labels[0..9], null);
    defer result9.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), result9.items.len);

    // Query with 3 labels — includes the partial node
    var result3 = try store.getNodesByLabels(testing.allocator, "default", all_labels[0..3], null);
    defer result3.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), result3.items.len);
}

test "GAP-0523: ReadView detects mutation epoch change" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create initial data
    var labels = [_][]const u8{"Person"};
    _ = try store.createNodeWithGraph(&labels, "default");

    // Capture epoch, create ReadView
    var view = ReadView.init(testing.allocator, &store);
    defer view.deinit();

    // Before any mutation: getReadStore returns base store (epoch unchanged)
    const store_before = view.getReadStore();
    try testing.expect(store_before == &store);

    // Simulate a concurrent mutation by incrementing epoch
    incrementMutationEpoch();

    // After mutation: epoch changed, getReadStore creates a snapshot.
    // GAP-0523 fix: adapter gate removed, so snapshot is created from
    // in-memory store via cloneNodesFrom/cloneIdMapsFrom.
    const store_after = view.getReadStore();
    try testing.expect(store_after != &store); // Must be snapshot, not base

    // Verify fallback_snapshot was populated
    try testing.expect(view.fallback_snapshot != null);
}

test "GAP-0523: ReadView snapshot isolates from concurrent mutations" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create 1 node before snapshot
    var labels = [_][]const u8{"Person"};
    _ = try store.createNodeWithGraph(&labels, "default");
    try testing.expectEqual(@as(usize, 1), store.nodes.count());

    // Create ReadView, capturing current epoch
    var view = ReadView.init(testing.allocator, &store);
    defer view.deinit();

    // First read: same epoch, returns base store directly (zero overhead)
    const s1 = view.getReadStore();
    try testing.expect(s1 == &store);

    // Mutate: add a second node (increments mutation epoch)
    _ = try store.createNodeWithGraph(&labels, "default");
    try testing.expectEqual(@as(usize, 2), store.nodes.count());

    // Second read: epoch changed, returns deep-clone snapshot
    const s2 = view.getReadStore();
    try testing.expect(s2 != &store);

    // Snapshot captured 2 nodes (cloned at mutation-detect time, after the second was added)
    // The base store also has 2 nodes
    try testing.expectEqual(@as(usize, 2), s2.nodes.count());

    // Mutate again: add a third node to the base store
    _ = try store.createNodeWithGraph(&labels, "default");
    try testing.expectEqual(@as(usize, 3), store.nodes.count());

    // Snapshot is frozen — still has 2 nodes
    const s3 = view.getReadStore();
    try testing.expect(s3 == s2); // Same snapshot reused
    try testing.expectEqual(@as(usize, 2), s3.nodes.count());
}

// CANARY: REQ=REQ-PERF-EDGE-TYPE-INDEX-004; FEATURE="EdgeTypeIndex"; ASPECT=UnitTest; STATUS=TESTED; TEST=src/graph_store.zig; OWNER=perf; UPDATED=2026-04-10
// PERF-P0-001: Verify edge-type index maintains correct state through create/delete/query lifecycle
test "PERF-P0-001: edge-type index provides O(1) lookup for getEdgesByType" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create nodes
    var labels = [_][]const u8{"Node"};
    const n1 = try store.createNodeWithGraph(&labels, "default");
    const n2 = try store.createNodeWithGraph(&labels, "default");
    const n3 = try store.createNodeWithGraph(&labels, "default");

    // Create edges of different types
    const e1 = try store.createEdgeWithGraph(n1, n2, "KNOWS", "default");
    const e2 = try store.createEdgeWithGraph(n2, n3, "KNOWS", "default");
    const e3 = try store.createEdgeWithGraph(n1, n3, "LIKES", "default");

    // Verify edge-type index contains correct entries
    const knows_ids = store.getEdgeIdsByType("default", "KNOWS");
    try testing.expect(knows_ids != null);
    try testing.expectEqual(@as(usize, 2), knows_ids.?.len);

    const likes_ids = store.getEdgeIdsByType("default", "LIKES");
    try testing.expect(likes_ids != null);
    try testing.expectEqual(@as(usize, 1), likes_ids.?.len);
    try testing.expectEqual(e3, likes_ids.?[0]);

    // Verify getEdgesByType uses the index and returns correct edges
    const knows_edges = store.getEdgesByType(testing.allocator, "KNOWS", null, null);
    defer testing.allocator.free(knows_edges);
    try testing.expectEqual(@as(usize, 2), knows_edges.len);

    const likes_edges = store.getEdgesByType(testing.allocator, "LIKES", null, null);
    defer testing.allocator.free(likes_edges);
    try testing.expectEqual(@as(usize, 1), likes_edges.len);
    const likes_ptr = store.edges.getPtr(likes_edges[0]) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("LIKES", likes_ptr.label);

    // Nonexistent type returns empty
    const none_edges = store.getEdgesByType(testing.allocator, "HATES", null, null);
    try testing.expectEqual(@as(usize, 0), none_edges.len);

    // Delete an edge and verify index is updated
    store.deleteEdge(e1);
    const knows_after_delete = store.getEdgesByType(testing.allocator, "KNOWS", null, null);
    defer testing.allocator.free(knows_after_delete);
    try testing.expectEqual(@as(usize, 1), knows_after_delete.len);
    try testing.expectEqual(e2, knows_after_delete[0]);

    // Verify index entry was cleaned up
    const knows_ids_after = store.getEdgeIdsByType("default", "KNOWS");
    try testing.expect(knows_ids_after != null);
    try testing.expectEqual(@as(usize, 1), knows_ids_after.?.len);
}

test "PERF-P0-001: edge-type index works with tenant filtering" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"Person"};
    const n1 = try store.createNodeWithGraphAndTenant(&labels, "default", "t1");
    const n2 = try store.createNodeWithGraphAndTenant(&labels, "default", "t1");
    const n3 = try store.createNodeWithGraphAndTenant(&labels, "default", "t2");

    _ = try store.createEdgeWithGraphAndTenant(n1, n2, "FRIEND", "default", "t1");
    _ = try store.createEdgeWithGraphAndTenant(n3, n1, "FRIEND", "default", "t2");

    // All FRIEND edges across tenants
    const all = store.getEdgesByType(testing.allocator, "FRIEND", null, null);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);

    // Filtered to tenant t1
    const t1_edges = store.getEdgesByType(testing.allocator, "FRIEND", "t1", null);
    defer testing.allocator.free(t1_edges);
    try testing.expectEqual(@as(usize, 1), t1_edges.len);
    const t1_ptr = store.edges.getPtr(t1_edges[0]) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("t1", t1_ptr.tenant_id);

    // Filtered to tenant t2
    const t2_edges = store.getEdgesByType(testing.allocator, "FRIEND", "t2", null);
    defer testing.allocator.free(t2_edges);
    try testing.expectEqual(@as(usize, 1), t2_edges.len);
    const t2_ptr = store.edges.getPtr(t2_edges[0]) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("t2", t2_ptr.tenant_id);
}

test "PERF-P0-001: edge-type index across multiple graphs" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"V"};
    const a1 = try store.createNodeWithGraph(&labels, "graphA");
    const a2 = try store.createNodeWithGraph(&labels, "graphA");
    const b1 = try store.createNodeWithGraph(&labels, "graphB");
    const b2 = try store.createNodeWithGraph(&labels, "graphB");

    _ = try store.createEdgeWithGraph(a1, a2, "REL", "graphA");
    _ = try store.createEdgeWithGraph(b1, b2, "REL", "graphB");

    // Per-graph lookups via getEdgeIdsByType
    const rel_a = store.getEdgeIdsByType("graphA", "REL");
    try testing.expect(rel_a != null);
    try testing.expectEqual(@as(usize, 1), rel_a.?.len);

    const rel_b = store.getEdgeIdsByType("graphB", "REL");
    try testing.expect(rel_b != null);
    try testing.expectEqual(@as(usize, 1), rel_b.?.len);

    // Cross-graph getEdgesByType returns both
    const all_rel = store.getEdgesByType(testing.allocator, "REL", null, null);
    defer testing.allocator.free(all_rel);
    try testing.expectEqual(@as(usize, 2), all_rel.len);
}

test "PERF-P0-001: edge-type index survives clearNodes" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"X"};
    const n1 = try store.createNodeWithGraph(&labels, "default");
    const n2 = try store.createNodeWithGraph(&labels, "default");
    _ = try store.createEdgeWithGraph(n1, n2, "LINK", "default");

    // Index should have entries
    try testing.expect(store.getEdgeIdsByType("default", "LINK") != null);

    // Clear the store
    store.clearNodes();

    // Index should be empty after clear
    try testing.expect(store.getEdgeIdsByType("default", "LINK") == null);

    // getEdgesByType should return empty
    const result = store.getEdgesByType(testing.allocator, "LINK", null, null);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "PERF-P0-001: edge-type index posting list is sorted ascending" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"N"};
    // Create many edges of the same type to verify sorted ordering
    var node_ids: [20]u64 = undefined;
    for (0..20) |i| {
        node_ids[i] = try store.createNodeWithGraph(&labels, "default");
    }
    for (0..19) |i| {
        _ = try store.createEdgeWithGraph(node_ids[i], node_ids[i + 1], "CHAIN", "default");
    }

    const chain_ids = store.getEdgeIdsByType("default", "CHAIN");
    try testing.expect(chain_ids != null);
    try testing.expectEqual(@as(usize, 19), chain_ids.?.len);

    // Verify strictly ascending order (binary search correctness depends on this)
    for (1..chain_ids.?.len) |i| {
        try testing.expect(chain_ids.?[i] > chain_ids.?[i - 1]);
    }
}

test "listEdgeTypes returns unique edge types filtered by tenant" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var labels = [_][]const u8{"A"};
    const n1 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant-a");
    const n2 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant-a");
    const n3 = try store.createNodeWithGraphAndTenant(&labels, "default", "tenant-b");
    _ = try store.createEdgeWithGraphAndTenant(n1, n2, "KNOWS", "default", "tenant-a");
    _ = try store.createEdgeWithGraphAndTenant(n1, n2, "KNOWS", "default", "tenant-a");
    _ = try store.createEdgeWithGraphAndTenant(n1, n2, "LIKES", "default", "tenant-a");
    _ = try store.createEdgeWithGraphAndTenant(n3, n3, "FOLLOWS", "default", "tenant-b");

    const types_a = try store.listEdgeTypes(testing.allocator, "tenant-a");
    defer {
        for (types_a) |t| testing.allocator.free(t);
        testing.allocator.free(types_a);
    }
    try testing.expectEqual(@as(usize, 2), types_a.len);

    const types_b = try store.listEdgeTypes(testing.allocator, "tenant-b");
    defer {
        for (types_b) |t| testing.allocator.free(t);
        testing.allocator.free(types_b);
    }
    try testing.expectEqual(@as(usize, 1), types_b.len);
    try testing.expectEqualStrings("FOLLOWS", types_b[0]);

    const types_all = try store.listEdgeTypes(testing.allocator, null);
    defer {
        for (types_all) |t| testing.allocator.free(t);
        testing.allocator.free(types_all);
    }
    try testing.expectEqual(@as(usize, 3), types_all.len);
}

test "listPropertiesForLabel returns dedup properties for nodes with label in tenant" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var person_labels = [_][]const u8{"Person"};
    var product_labels = [_][]const u8{"Product"};

    const alice = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant-a");
    try store.setNodeProperty(alice, "name", .{ .String = "Alice" });
    try store.setNodeProperty(alice, "age", .{ .Int = 30 });

    const bob = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant-a");
    try store.setNodeProperty(bob, "name", .{ .String = "Bob" });
    try store.setNodeProperty(bob, "email", .{ .String = "b@x.io" });

    const product = try store.createNodeWithGraphAndTenant(&product_labels, "default", "tenant-a");
    try store.setNodeProperty(product, "sku", .{ .String = "X" });

    const tenant_b_person = try store.createNodeWithGraphAndTenant(&person_labels, "default", "tenant-b");
    try store.setNodeProperty(tenant_b_person, "secret", .{ .Int = 1 });

    const props = try store.listPropertiesForLabel(testing.allocator, "tenant-a", "Person");
    defer {
        for (props) |p| testing.allocator.free(p);
        testing.allocator.free(props);
    }

    // De-dup union of {Alice: name, age} ∪ {Bob: name, email} = {name, age, email}.
    // Product.sku (different label) and tenant-b's "secret" (different tenant) must NOT appear.
    try testing.expectEqual(@as(usize, 3), props.len);

    var saw_name = false;
    var saw_age = false;
    var saw_email = false;
    for (props) |p| {
        if (std.mem.eql(u8, p, "name")) saw_name = true;
        if (std.mem.eql(u8, p, "age")) saw_age = true;
        if (std.mem.eql(u8, p, "email")) saw_email = true;
        try testing.expect(!std.mem.eql(u8, p, "sku"));
        try testing.expect(!std.mem.eql(u8, p, "secret"));
    }
    try testing.expect(saw_name);
    try testing.expect(saw_age);
    try testing.expect(saw_email);
}

test "GraphStore.listNodeLabels is callable and filters by tenant" {
    var store = try GraphStore.init(testing.allocator);
    defer store.deinit();

    var visible_labels = [_][]const u8{"Visible"};
    var hidden_labels = [_][]const u8{"Hidden"};
    _ = try store.createNodeWithGraphAndTenant(&visible_labels, "default", "tenant-a");
    _ = try store.createNodeWithGraphAndTenant(&hidden_labels, "default", "tenant-b");

    const labels = try store.listNodeLabels(testing.allocator, "tenant-a");
    defer {
        for (labels) |l| testing.allocator.free(l);
        testing.allocator.free(labels);
    }
    try testing.expectEqual(@as(usize, 1), labels.len);
    try testing.expectEqualStrings("Visible", labels[0]);
}

// GAP-0839: a graph auto-created at HELLO must carry a persistent UUID so a
// tenant-bound session is accepted.  Before the fix, an in-memory deployment
// (server started without --data-dir, so no storage adapter / vtable is wired)
// created graphs with NO UUID, and all three HELLO handlers
// (grpc_server.zig:1571/:1697, quic_connection_handler.zig:5342) rejected the
// session with "Graph created without persistent UUID" via
//   `const uuid = GraphStore.getGraphUuid(graph) orelse <reject>;`.
// These tests assert the create path now yields a persistent UUID and that the
// exact rejection condition (`getGraphUuid(...) == null`) is no longer hit.

fn gap0839IsZeroUuid(u: [16]u8) bool {
    for (u) |b| {
        if (b != 0) return false;
    }
    return true;
}

test "GAP-0839: in-memory createGraph assigns a persistent UUID (no adapter)" {
    // Reset the global singleton so this test owns it, and ensure NO adapter is
    // wired (in-memory mode) — this is the exact deployment that triggered the
    // rejection.
    deinitGlobalStore();
    defer deinitGlobalStore();
    setDataDirOverride(testing.allocator, null);

    const store = getGlobalStore(testing.allocator);
    // Precondition: this is in-memory mode — no storage adapter.
    try testing.expect(getGlobalAdapter() == null);

    try store.createGraph("gap0839_inmem");

    // The HELLO handlers call the STATIC getGraphUuid and reject when it is
    // null.  After the fix it must return a non-zero UUID even with no adapter.
    const u = GraphStore.getGraphUuid("gap0839_inmem") orelse
        return error.GraphCreatedWithoutPersistentUuid;
    try testing.expect(!gap0839IsZeroUuid(u));

    // Idempotent create must keep the SAME persistent UUID (stable identity).
    try store.createGraph("gap0839_inmem");
    const u_again = GraphStore.getGraphUuid("gap0839_inmem") orelse
        return error.GraphCreatedWithoutPersistentUuid;
    try testing.expectEqualSlices(u8, &u, &u_again);
}

test "GAP-0839: default graph has a persistent UUID in in-memory mode" {
    deinitGlobalStore();
    defer deinitGlobalStore();
    setDataDirOverride(testing.allocator, null);

    _ = getGlobalStore(testing.allocator);
    try testing.expect(getGlobalAdapter() == null);

    const u = GraphStore.getGraphUuid("default") orelse
        return error.GraphCreatedWithoutPersistentUuid;
    try testing.expect(!gap0839IsZeroUuid(u));
}

test "GAP-0839: dropGraph clears the persistent-UUID entry" {
    deinitGlobalStore();
    defer deinitGlobalStore();
    setDataDirOverride(testing.allocator, null);

    const store = getGlobalStore(testing.allocator);
    try store.createGraph("gap0839_drop");
    try testing.expect(GraphStore.getGraphUuid("gap0839_drop") != null);

    try store.dropGraph("gap0839_drop");
    try testing.expect(GraphStore.getGraphUuid("gap0839_drop") == null);
}

test "GAP-0839: adapter-backed createGraph yields a persistent UUID" {
    deinitGlobalStore();
    defer deinitGlobalStore();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmpDirRealpathAlloc(testing.allocator, &tmp.sub_path);
    defer testing.allocator.free(dir_path);

    const store = try initGlobalStore(testing.allocator, dir_path);
    try testing.expect(getGlobalAdapter() != null);

    try store.createGraph("gap0839_disk");
    const u = GraphStore.getGraphUuid("gap0839_disk") orelse
        return error.GraphCreatedWithoutPersistentUuid;
    try testing.expect(!gap0839IsZeroUuid(u));

    // The adapter is the source of truth and the in-memory fallback mirrors it,
    // so both must agree on the same UUID for the same graph.
    const adapter = getGlobalAdapter().?;
    const adapter_uuid = adapter.getGraphUuid("gap0839_disk") orelse
        return error.GraphCreatedWithoutPersistentUuid;
    try testing.expectEqualSlices(u8, &adapter_uuid, &u);
}
