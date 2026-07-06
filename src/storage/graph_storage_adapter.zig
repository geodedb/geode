// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Graph Storage Adapter — bridges the graph-storage engine library to geode's
//! execution engine.
//!
//! Manages one `GraphEngine` instance per named graph and provides the methods
//! that geode's execution engine calls.

const std = @import("std");
const builtin = @import("builtin");
const gs = @import("graph_storage");
const sharded_store = gs.sharded_store;
const uuid = @import("uuid");
const graph_store = @import("../graph_store.zig");
const fle_integration = @import("../fle_integration.zig");
const property_codec = @import("../property_value_codec.zig");
const audit = @import("../security/audit.zig");
const ts_mod = @import("../timeseries/timeseries.zig");
const fulltext = @import("../index/fulltext.zig");
const adapter_mod = @import("fts_storage_adapter.zig");
// GAP-ENT-0048 DEFECT B: the deferred exact-index rebuild polls the read
// executor's cancel flags so a client disconnect / stall-watchdog abort frees a
// handler wedged inside the O(graph) first-access rebuild. `read_budget` is a
// leaf module (imports only std), so there is no import cycle.
const read_budget = @import("../read_budget.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.graph_storage_adapter);
// GAP-ENT-0038: checkpoint-cadence observability MUST use geode's structured
// logger, not `std.log`. This repo defines no `std_options`, so in ReleaseFast
// builds `std.log.default_level == .err` and every `log.info`/`log.warn` in
// this file is compiled OUT of the production server. That made the inline
// load-driven checkpoint (the PRIMARY deferred-mode cadence driver — it wins
// the threshold race against the persistence loop on virtually every crossing)
// completely invisible in the live server log, which read as "exactly one
// auto-checkpoint in 11 hours" during the 14.27M ingest while on-disk evidence
// (graph_registry.dat rewritten every ~33 s, 32 shard WALs totalling ~118 MB
// after 22.4M ops) proved checkpoints were landing continuously. Scope
// "storage" matches the persistence loop's visible cadence lines so operators
// can grep one scope for the full checkpoint sawtooth.
const structured_logging = @import("logging");
const slog = structured_logging.scoped("storage");
const SAttr = structured_logging.Attr;

// Re-export edge type for callers that need EdgeEntry from scan results.
pub const EdgeEntry = gs.edge.EdgeEntry;

/// GAP hydration fast-scan: sequential per-shard store streaming for the
/// loop2 first-access hydration. Re-exported so graph_store.zig can name the
/// accumulation types without importing graph_storage directly.
pub const hydration_scan = @import("hydration_scan.zig");

const LabelScanContext = struct {
    mg: *ManagedGraph,
    label_id: gs.LabelId,
};

/// Resolved handle for a CHUNKED, per-shard label slot enumeration. `begin`
/// resolves the graph + label ONCE; the caller then drives the scan one shard at
/// a time via `appendLabelScanShard`, applying its own per-slot filter + early
/// termination BETWEEN shards. This preserves the lock-safe, per-shard
/// SHARED-lock enumeration (`appendLiveNodesForLabelShard`) — NEVER the unlocked
/// lazy fan-out cursor — while letting a WHERE+LIMIT caller stop after enough
/// matches instead of materializing every live slot. `shard_count` is captured
/// at `begin`; `mg`/`label_id` mirror `getNodesByLabelCapped`'s held handle.
pub const LabelScanCursor = struct {
    mg: *ManagedGraph,
    label_id: gs.LabelId,
    shard_count: usize,
};

var g_exact_node_property_lookup_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// H4 (cold-open phase 1): number of times `rebuildExactNodePropertyIndex` has
// run process-wide. Test instrumentation for the deferred-build latch: a graph
// opened WITHOUT a persisted exact index must NOT rebuild at open (counter
// unchanged) and must rebuild EXACTLY ONCE on first index access (read or
// live-mutation). Incremented at the top of every rebuild.
var g_exact_rebuild_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-ENT-0048 DEFECT B: nodes VISITED by the exact-index rebuild scan
// (`rebuildExactNodePropertyIndex`'s per-shard scanCallback) process-wide.
// Wall-clock-independent instrumentation for the cancel contract: a read query
// whose STREAM (connection-close) cancel flag is set must abort the deferred
// rebuild at the next batch boundary, so the scan visits FAR fewer than the
// graph's node count instead of running to completion (frees a genuinely-gone
// client's handler). GAP-ENT-0048 SECONDARY narrows this to the STREAM source
// only: a proto-reader stall (WATCHDOG) abort must NOT stop a progressing build
// (see `g_exact_rebuild_heartbeats` and `CancelFlags.streamTripped`).
var g_exact_rebuild_nodes_scanned: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-ENT-0048 SECONDARY: build-progress heartbeat. Incremented once per
// cancel-poll BATCH (every `exact_rebuild_cancel_poll_batch` nodes) while the
// deferred exact-index rebuild advances. A monotonically-rising value proves the
// build is making forward progress (not wedged), which is exactly why the
// rebuild is EXEMPT from the proto-reader stall (watchdog) cancel: a handler
// that is heartbeating is building, not stuck. Reset per test.
var g_exact_rebuild_heartbeats: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-ENT-0048 (task0048d): per-shard scan tasks the most recent rebuild
// dispatched to the engine's shared thread pool (PARALLEL) vs ran INLINE on the
// calling thread (serial). At 14.27M a value of pool>=1 proves the rebuild fanned
// out across pool workers rather than degrading to a single-threaded scan (the
// coordinator's ~1.2-core observation). Reset per test.
var g_exact_rebuild_pool_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_exact_rebuild_inline_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-ENT-0048 (task0048d): registry graphs that a FULL checkpoint force-loaded
// (opened their adapter engine) so their derived exact index could be built +
// persisted even though no query had opened them this session (snapshot-served /
// counter-served graphs never enter `self.engines` — the divelife skip).
var g_full_checkpoint_forced_loads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-ENT-0048f: graphs whose exact node-property index was built + persisted
// DURING first-touch hydration (the race-free path — hydration already scans
// every node lock-free and never holds mg.rwlock, so there is no checkpoint
// rwlock race and no shutdown-checkpoint dependency). Test instrumentation.
var g_exact_hydration_builds: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// C-1 (T2b adversarial review): number of times a per-graph checkpoint's
// retired-cache reclaim (the grace window in `checkpointOneGraph`) was
// SKIPPED because the graph had an unfinished (pending or in-flight)
// first-touch hydration. The hydration merge's family threads read shallow
// Node copies whose sub-heaps live on the bounded caches' per-graph retire
// lists; freeing those mid-merge is a use-after-free whose garbage the
// persist-on-complete path then blesses as durable products. Mechanism
// instrumentation: tests assert the skip fires during an in-flight hydration
// and does NOT fire once hydration completed.
var g_hydration_reclaim_skips: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// H4 persist-on-build instrumentation (see the ForTesting getters below).
var g_exact_persist_attempts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// H4 persist-on-build kill switch (mirrors the hydration-persist switch
/// idiom in graph_store.zig).
fn exactIndexPersistOnBuildDisabled() bool {
    const raw_z = std.c.getenv("GEODE_DISABLE_EXACT_INDEX_PERSIST_ON_BUILD") orelse return false;
    const raw = std.mem.span(raw_z);
    return std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "yes");
}
var g_exact_persist_completions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_exact_persist_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-ENT-0048 PRIMARY: number of graphs whose exact node-property index was
// RELOADED from a persisted `prop_exact.idx` snapshot at open (the O(snapshot)
// bulk-load path, NOT the O(graph) rebuild). Test instrumentation for the
// reopen contract: after a clean FULL-checkpoint shutdown the reopen must LOAD
// the snapshot (this counter increments, `g_exact_rebuild_runs` stays 0), so
// the first index-served read engages with ZERO client-facing rebuild.
var g_exact_index_reloaded: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-ENT-0048 PRIMARY: number of times a FULL checkpoint EAGERLY built a
// deferred-but-unbuilt exact index from the durable pages (in parallel) so it
// could persist a COMPLETE `prop_exact.idx` instead of invalidating the file.
// This is the clean-shutdown chokepoint that guarantees a loadable snapshot for
// a graph that ran this session with the index deferred (reopened-then-appended
// stores, or any graph whose last durable checkpoint was LIGHT). Distinct from
// the lazy first-access build so a test can prove the build happened at the
// checkpoint, not on a client query.
var g_exact_eager_checkpoint_builds: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_label_scan_lookup_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// Candidate nodes examined by the verify-loop in `lookupNodeIdByLabelAndAllProps`
// (the bulk edge-endpoint resolver). A dangling composite-key endpoint whose
// unique indexed component (e.g. {source_id}) has ZERO postings must NOT seed
// the scan on a low-selectivity component (e.g. {source}, shared by ~N nodes)
// and verify N candidates — that O(N)-per-edge scan, run under the SHARED graph
// rwlock and amplified by the bounded node cache (each verify is a disk page
// pin), is the edge-phase wedge. This counter makes the fix wall-clock-
// independent: an authoritative unique-key miss examines ZERO candidates.
var g_lookup_all_props_candidates_scanned: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// Engine-direct single-property reads performed by `getNodeProperty` (each is a
// PropertyChain walk → `BufferPool.pin`, the page buffer pool). The from-dump
// EDGE phase resolves each endpoint by the {source, source_id} COMPOSITE; the
// pre-composite path SEEDS on the unique `source_id` via the resident merge
// index (no engine read) but then VERIFIES the remaining `source` filter with
// `getNodeProperty` (one engine read PER ENDPOINT). At a pool-exceeding scale
// that single verify read THRASHES the buffer pool (83% of CPU in pin) →
// ~12 edges/s. The composite merge entry resolves the WHOLE key in one resident
// probe with NO `getNodeProperty`, so this counter must NOT grow per endpoint on
// the composite path. Wall-clock-independent regression instrumentation.
var g_node_property_engine_reads: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// Live label slots VISITED (appended) by `appendLiveNodesForLabelShard` since
// the last `resetLabelSlotsEnumerated`. Each non-deleted/non-empty slot the
// label-scan path materializes increments this once. H1: the WHERE+LIMIT
// streaming read path must STOP enumerating once `offset+limit` predicate
// matches are found instead of enumerating EVERY live slot up front; this
// counter makes that bound wall-clock-independent (pre-fix == all live slots
// for the label, post-fix << N for an early-/all-matching predicate).
var g_label_slots_enumerated: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// CANARY: REQ=REQ-QUIC-HC-122; FEATURE="HighConcurrencyMutations"; ASPECT=ExactPropertyIndexSharding; STATUS=TESTED; TEST=test_graph_storage_adapter_metrics; OWNER=storage; UPDATED=2026-05-28
pub const exact_node_property_index_shard_count: usize = 64;

const graph_store_file_names = [_][]const u8{
    "nodes.store",
    "adj_out.store",
    "adj_in.store",
    "props.store",
    "var.store",
};

const free_store_header_size: usize = 16;
const free_store_path_name = "free.store";

pub fn resetLookupCounters() void {
    g_exact_node_property_lookup_count.store(0, .release);
    g_label_scan_lookup_count.store(0, .release);
    g_lookup_all_props_candidates_scanned.store(0, .release);
    g_node_property_engine_reads.store(0, .release);
    g_label_slots_enumerated.store(0, .release);
}

/// Reset the live-label-slots-enumerated counter (H1 read-path enumeration cost).
pub fn resetLabelSlotsEnumerated() void {
    g_label_slots_enumerated.store(0, .release);
}

/// Live label slots VISITED by the lock-safe label-scan enumeration
/// (`appendLiveNodesForLabelShard`) since the last reset. The WHERE+LIMIT
/// streaming read path must keep this BOUNDED (≈ enough shards to find
/// `offset+limit` predicate matches), not equal to the label's full live-node
/// count. Wall-clock-independent instrumentation for the H1 bounded-enumeration
/// fix.
pub fn getLabelSlotsEnumerated() u64 {
    return g_label_slots_enumerated.load(.acquire);
}

/// Engine-direct single-property reads (`getNodeProperty` → PropertyChain →
/// `BufferPool.pin`) since the last `resetLookupCounters`. The composite
/// endpoint-resolution path must NOT grow this per endpoint (zero node-page
/// reads); the pre-composite seed+verify path grows it ~1 per endpoint.
pub fn getNodePropertyEngineReads() u64 {
    return g_node_property_engine_reads.load(.acquire);
}

pub fn getExactNodePropertyLookupCount() u64 {
    return g_exact_node_property_lookup_count.load(.acquire);
}

/// H4 (cold-open phase 1): process-wide count of `rebuildExactNodePropertyIndex`
/// runs. Test-only: assert 0 after a deferred open and exactly 1 after first
/// index access.
pub fn getExactRebuildRunsForTesting() u64 {
    return g_exact_rebuild_runs.load(.acquire);
}

/// H4 (cold-open phase 1): reset the rebuild-runs counter (test-only).
pub fn resetExactRebuildRunsForTesting() void {
    g_exact_rebuild_runs.store(0, .release);
}

/// GAP-ENT-0048 DEFECT B: nodes visited by the exact-index rebuild scan since
/// the last reset. Test-only: a cancelled deferred rebuild must abort early, so
/// this stays far below the graph's node count (pre-fix it equalled the count).
pub fn getExactRebuildNodesScannedForTesting() u64 {
    return g_exact_rebuild_nodes_scanned.load(.acquire);
}

/// GAP-ENT-0048 DEFECT B: reset the rebuild-scan node counter (test-only).
pub fn resetExactRebuildNodesScannedForTesting() void {
    g_exact_rebuild_nodes_scanned.store(0, .release);
}

/// GAP-ENT-0048 SECONDARY: build-progress heartbeats emitted by the most recent
/// rebuild since the last reset. > 0 proves the build advanced (was not wedged).
pub fn getExactRebuildHeartbeatsForTesting() u64 {
    return g_exact_rebuild_heartbeats.load(.acquire);
}

/// GAP-ENT-0048 SECONDARY: reset the build-progress heartbeat counter.
pub fn resetExactRebuildHeartbeatsForTesting() void {
    g_exact_rebuild_heartbeats.store(0, .release);
}

/// GAP-ENT-0048 (task0048d): shard scans dispatched to the pool (parallel) vs
/// run inline (serial) by the most recent rebuild. pool>=1 proves parallelism.
pub fn getExactRebuildPoolTasksForTesting() u64 {
    return g_exact_rebuild_pool_tasks.load(.acquire);
}
pub fn getExactRebuildInlineTasksForTesting() u64 {
    return g_exact_rebuild_inline_tasks.load(.acquire);
}
pub fn resetExactRebuildDispatchCountersForTesting() void {
    g_exact_rebuild_pool_tasks.store(0, .release);
    g_exact_rebuild_inline_tasks.store(0, .release);
}

/// GAP-ENT-0048 (task0048d): FULL checkpoints that force-loaded an on-disk
/// (registry) graph so its exact index could be built + persisted (the
/// snapshot-served graph that never entered `self.engines`).
pub fn getFullCheckpointForcedLoadsForTesting() u64 {
    return g_full_checkpoint_forced_loads.load(.acquire);
}
pub fn resetFullCheckpointForcedLoadsForTesting() void {
    g_full_checkpoint_forced_loads.store(0, .release);
}

/// GAP-ENT-0048f: exact indexes built + persisted during first-touch hydration.
pub fn getExactHydrationBuildsForTesting() u64 {
    return g_exact_hydration_builds.load(.acquire);
}
pub fn resetExactHydrationBuildsForTesting() void {
    g_exact_hydration_builds.store(0, .release);
}

/// GAP-ENT-0048g: aggregate (sum over all shards) of the per-shard
/// `manifest.counter` — bumps once per durable checkpoint of any shard. Used to
/// stamp `prop_exact.idx` and gate its reload (load-if-current), the same
/// discipline `idmap.snapshot` uses.
fn mgManifestCounter(mg: *ManagedGraph) u64 {
    var counter: u64 = 0;
    for (mg.engine.shards) |shard| {
        counter +%= shard.manifest.counter;
    }
    return counter;
}

/// C-1: process-wide count of checkpoint grace windows that SKIPPED the
/// retired-cache reclaims because the graph had an unfinished first-touch
/// hydration (test instrumentation for the reclaim gate).
pub fn getHydrationReclaimSkipsForTesting() u64 {
    return g_hydration_reclaim_skips.load(.acquire);
}

/// C-1: reset the reclaim-skip counter (test-only).
pub fn resetHydrationReclaimSkipsForTesting() void {
    g_hydration_reclaim_skips.store(0, .release);
}

/// H4 persist-on-build: background graph-scoped persists of a JUST-REBUILT
/// exact node-property index (crash durability for the ~32 min first-access
/// build — see `ensureExactNodePropertyIndexBuilt`). attempts = persists
/// triggered after a successful deferred rebuild; completions = the bounded
/// graph checkpoint landed (index snapshot durable); failures = spawn
/// failure OR checkpoint error (bounded-acquire timeout, engine failure,
/// graph dropped mid-flight) — all non-fatal, the index stays correct in
/// memory and the next FULL checkpoint persists it (pre-fix behaviour).
pub fn getExactIndexPersistAttemptsForTesting() u64 {
    return g_exact_persist_attempts.load(.acquire);
}

pub fn getExactIndexPersistCompletionsForTesting() u64 {
    return g_exact_persist_completions.load(.acquire);
}

pub fn getExactIndexPersistFailuresForTesting() u64 {
    return g_exact_persist_failures.load(.acquire);
}

/// H4 persist-on-build: reset the persist counters (test-only).
pub fn resetExactIndexPersistCountersForTesting() void {
    g_exact_persist_attempts.store(0, .release);
    g_exact_persist_completions.store(0, .release);
    g_exact_persist_failures.store(0, .release);
}

/// GAP-ENT-0048 PRIMARY: graphs whose exact index was RELOADED from the
/// persisted `prop_exact.idx` snapshot at open since the last reset. Test-only:
/// a clean-shutdown reopen must LOAD (this > 0) with ZERO rebuild runs.
pub fn getExactIndexReloadedForTesting() u64 {
    return g_exact_index_reloaded.load(.acquire);
}

/// GAP-ENT-0048 PRIMARY: FULL checkpoints that eagerly built a deferred index
/// so a complete snapshot could be persisted (rather than invalidated).
pub fn getExactEagerCheckpointBuildsForTesting() u64 {
    return g_exact_eager_checkpoint_builds.load(.acquire);
}

/// GAP-ENT-0048 PRIMARY: reset the reload / eager-checkpoint-build counters.
pub fn resetExactIndexReloadCountersForTesting() void {
    g_exact_index_reloaded.store(0, .release);
    g_exact_eager_checkpoint_builds.store(0, .release);
}

/// Candidates examined by `lookupNodeIdByLabelAndAllProps`'s verify-loop since
/// the last `resetLookupCounters`. Zero for an authoritative unique-key miss
/// (the dangling-endpoint fast-negative); ~posting-length for a real seek.
pub fn getLookupAllPropsCandidatesScanned() u64 {
    return g_lookup_all_props_candidates_scanned.load(.acquire);
}

pub fn getLabelScanLookupCount() u64 {
    return g_label_scan_lookup_count.load(.acquire);
}

fn exactNodePropertyIndexHash(label_id: gs.LabelId, property_key: []const u8, value_hash: u64) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var label_buf: [4]u8 = undefined;
    var key_len_buf: [4]u8 = undefined;
    var value_buf: [8]u8 = undefined;
    std.mem.writeInt(u32, &label_buf, label_id, .little);
    std.mem.writeInt(u32, &key_len_buf, @intCast(property_key.len), .little);
    std.mem.writeInt(u64, &value_buf, value_hash, .little);
    hasher.update(&label_buf);
    hasher.update(&key_len_buf);
    hasher.update(property_key);
    hasher.update(&value_buf);
    return hasher.final();
}

fn exactNodePropertyIndexShardForParts(label_id: gs.LabelId, property_key: []const u8, value_hash: u64) usize {
    return @intCast(exactNodePropertyIndexHash(label_id, property_key, value_hash) % exact_node_property_index_shard_count);
}

fn exactNodePropertyIndexShardForEncodedKey(key: []const u8) usize {
    return @intCast(std.hash.Wyhash.hash(0, key) % exact_node_property_index_shard_count);
}

pub fn exactNodePropertyIndexShardForTest(label_id: gs.LabelId, property_key: []const u8, value_hash: u64) usize {
    return exactNodePropertyIndexShardForParts(label_id, property_key, value_hash);
}

const NodePropertyExactIndexShard = struct {
    postings: std.StringHashMap(std.ArrayList(u64)),
    mutex: std.Io.Mutex = std.Io.Mutex.init,

    fn init(allocator: Allocator) NodePropertyExactIndexShard {
        return .{ .postings = std.StringHashMap(std.ArrayList(u64)).init(allocator) };
    }

    fn deinit(self: *NodePropertyExactIndexShard, allocator: Allocator) void {
        var it = self.postings.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.postings.deinit();
    }

    fn clearLocked(self: *NodePropertyExactIndexShard, allocator: Allocator) void {
        var it = self.postings.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.postings.clearAndFree();
    }
};

const NodePropertyExactIndex = struct {
    allocator: Allocator,
    /// Exact `(label_id, property_key, value_hash) -> node ids` postings are
    /// striped so high-parallel MERGE/properties do not queue behind one global
    /// StringHashMap mutex. Checkpoint/load still take every shard in stable
    /// order to preserve a coherent on-disk snapshot.
    shards: [exact_node_property_index_shard_count]NodePropertyExactIndexShard,

    fn init(allocator: Allocator) NodePropertyExactIndex {
        var self: NodePropertyExactIndex = .{
            .allocator = allocator,
            .shards = undefined,
        };
        for (&self.shards) |*shard| {
            shard.* = NodePropertyExactIndexShard.init(allocator);
        }
        return self;
    }

    fn deinit(self: *NodePropertyExactIndex) void {
        for (&self.shards) |*shard| {
            shard.deinit(self.allocator);
        }
    }

    fn clear(self: *NodePropertyExactIndex) void {
        self.lockAllShards();
        defer self.unlockAllShards();
        self.clearLockedAll();
    }

    fn lockAllShards(self: *NodePropertyExactIndex) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        for (&self.shards) |*shard| {
            shard.mutex.lockUncancelable(io);
        }
    }

    fn unlockAllShards(self: *NodePropertyExactIndex) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        var i: usize = self.shards.len;
        while (i > 0) {
            i -= 1;
            self.shards[i].mutex.unlock(io);
        }
    }

    /// Caller must hold every shard mutex. Used by `loadFromFile`, which
    /// already locks the shards before calling; going through `clear()`
    /// there would self-deadlock (`std.Io.Mutex` is non-reentrant).
    /// See docs/bugs/2026-04-27-adapter-restart-deadlock.md.
    fn clearLockedAll(self: *NodePropertyExactIndex) void {
        for (&self.shards) |*shard| {
            shard.clearLocked(self.allocator);
        }
    }

    fn add(self: *NodePropertyExactIndex, label_id: gs.LabelId, property_key: []const u8, value_hash: u64, node_id: u64) !void {
        return self.addEx(label_id, property_key, value_hash, node_id, false);
    }

    /// GAP-0900 throughput: `assume_new=true` skips the linear de-dup scan of the
    /// posting list. The scan (O(posting-list-length) per call) exists only to
    /// avoid inserting the same node_id twice into one (label,key,value) posting.
    /// On the bulk-INSERT path the node_id is freshly reserved and has never been
    /// indexed, so it provably cannot already be present — the scan is pure waste.
    /// For a low-selectivity indexed key (e.g. a composite-MERGE key component
    /// shared by millions of nodes) the posting list grows to N, making the scan
    /// O(N) per insert and the whole bulk load O(N^2) (measured: 54.85% of CPU at
    /// ~4M nodes). Skipping it on fresh inserts restores O(1) amortized append.
    /// Update/re-index paths keep `assume_new=false` (the node may already be in
    /// the posting from a prior value).
    fn addEx(self: *NodePropertyExactIndex, label_id: gs.LabelId, property_key: []const u8, value_hash: u64, node_id: u64, assume_new: bool) !void {
        const owned_key = try self.encodeKey(label_id, property_key, value_hash);
        const shard_idx = exactNodePropertyIndexShardForEncodedKey(owned_key);
        const shard = &self.shards[shard_idx];
        const io = std.Io.Threaded.global_single_threaded.io();
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        const gop = shard.postings.getOrPut(owned_key) catch |err| {
            self.allocator.free(owned_key);
            return err;
        };
        var inserted_new = false;
        if (gop.found_existing) {
            self.allocator.free(owned_key);
            if (!assume_new) {
                for (gop.value_ptr.items) |existing_id| {
                    if (existing_id == node_id) return;
                }
            }
        } else {
            gop.value_ptr.* = std.ArrayList(u64).empty;
            inserted_new = true;
        }
        errdefer if (inserted_new) {
            if (shard.postings.fetchRemove(owned_key)) |kv| {
                self.allocator.free(kv.key);
                var list_copy = kv.value;
                list_copy.deinit(self.allocator);
            }
        };
        try gop.value_ptr.append(self.allocator, node_id);
    }

    fn remove(self: *NodePropertyExactIndex, label_id: gs.LabelId, property_key: []const u8, value_hash: u64, node_id: u64) void {
        var key_buf: [1024]u8 = undefined;
        const encoded = self.encodeKeyScratch(key_buf[0..], label_id, property_key, value_hash) catch return;
        defer if (encoded.owned) |owned| self.allocator.free(owned);
        const probe_key = encoded.key;
        const shard_idx = exactNodePropertyIndexShardForEncodedKey(probe_key);
        const shard = &self.shards[shard_idx];
        const io = std.Io.Threaded.global_single_threaded.io();
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        if (shard.postings.getPtr(probe_key)) |list| {
            var i: usize = 0;
            while (i < list.items.len) : (i += 1) {
                if (list.items[i] == node_id) {
                    _ = list.orderedRemove(i);
                    break;
                }
            }
            if (list.items.len == 0) {
                if (shard.postings.fetchRemove(probe_key)) |kv| {
                    self.allocator.free(kv.key);
                    var list_copy = kv.value;
                    list_copy.deinit(self.allocator);
                }
            }
        }
    }

    fn get(self: *NodePropertyExactIndex, label_id: gs.LabelId, property_key: []const u8, value_hash: u64) ?[]const u64 {
        var key_buf: [1024]u8 = undefined;
        const encoded = self.encodeKeyScratch(key_buf[0..], label_id, property_key, value_hash) catch return null;
        defer if (encoded.owned) |owned| self.allocator.free(owned);
        const probe_key = encoded.key;
        const shard_idx = exactNodePropertyIndexShardForEncodedKey(probe_key);
        const shard = &self.shards[shard_idx];
        const io = std.Io.Threaded.global_single_threaded.io();
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        if (shard.postings.get(probe_key)) |list| {
            return list.items;
        }
        return null;
    }

    fn copy(self: *NodePropertyExactIndex, allocator: Allocator, label_id: gs.LabelId, property_key: []const u8, value_hash: u64) ![]u64 {
        return (try self.copyIfPresent(allocator, label_id, property_key, value_hash)) orelse
            try allocator.alloc(u64, 0);
    }

    fn copyIfPresent(self: *NodePropertyExactIndex, allocator: Allocator, label_id: gs.LabelId, property_key: []const u8, value_hash: u64) !?[]u64 {
        var key_buf: [1024]u8 = undefined;
        const encoded = try self.encodeKeyScratch(key_buf[0..], label_id, property_key, value_hash);
        defer if (encoded.owned) |owned| self.allocator.free(owned);
        const probe_key = encoded.key;
        const shard_idx = exactNodePropertyIndexShardForEncodedKey(probe_key);
        const shard = &self.shards[shard_idx];
        const io = std.Io.Threaded.global_single_threaded.io();
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        if (shard.postings.get(probe_key)) |list| {
            return try allocator.dupe(u64, list.items);
        }
        return null;
    }

    fn postingLenIfPresent(self: *NodePropertyExactIndex, label_id: gs.LabelId, property_key: []const u8, value_hash: u64) !?usize {
        var key_buf: [1024]u8 = undefined;
        const encoded = try self.encodeKeyScratch(key_buf[0..], label_id, property_key, value_hash);
        defer if (encoded.owned) |owned| self.allocator.free(owned);
        const probe_key = encoded.key;
        const shard_idx = exactNodePropertyIndexShardForEncodedKey(probe_key);
        const shard = &self.shards[shard_idx];
        const io = std.Io.Threaded.global_single_threaded.io();
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        if (shard.postings.get(probe_key)) |list| {
            return list.items.len;
        }
        return null;
    }

    fn encodeKey(self: *const NodePropertyExactIndex, label_id: gs.LabelId, property_key: []const u8, value_hash: u64) ![]u8 {
        const total_len = 4 + 4 + property_key.len + 8;
        const key = try self.allocator.alloc(u8, total_len);
        _ = self.encodeKeyInto(key, label_id, property_key, value_hash) orelse unreachable;
        return key;
    }

    const EncodedKey = struct {
        key: []const u8,
        owned: ?[]u8,
    };

    fn encodeKeyScratch(self: *const NodePropertyExactIndex, scratch: []u8, label_id: gs.LabelId, property_key: []const u8, value_hash: u64) !EncodedKey {
        if (self.encodeKeyInto(scratch, label_id, property_key, value_hash)) |key| {
            return .{ .key = key, .owned = null };
        }
        const owned = try self.encodeKey(label_id, property_key, value_hash);
        return .{ .key = owned, .owned = owned };
    }

    fn encodeKeyInto(_: *const NodePropertyExactIndex, buf: []u8, label_id: gs.LabelId, property_key: []const u8, value_hash: u64) ?[]const u8 {
        const total_len = 4 + 4 + property_key.len + 8;
        if (total_len > buf.len) return null;
        std.mem.writeInt(u32, buf[0..4], label_id, .little);
        std.mem.writeInt(u32, buf[4..8], @intCast(property_key.len), .little);
        @memcpy(buf[8 .. 8 + property_key.len], property_key);
        std.mem.writeInt(u64, buf[8 + property_key.len ..][0..8], value_hash, .little);
        return buf[0..total_len];
    }

    /// Persist the index to `prop_exact.idx` inside `graph_dir_path`, stamped
    /// with the engine `manifest_counter` at persist time (GAP-ENT-0048g). The
    /// stamp mirrors the `idmap.snapshot` load-if-current discipline: on reopen
    /// the index loads ONLY if its stamp equals the engine's current manifest
    /// counter (no committed write since it was persisted). This lets a LIGHT
    /// checkpoint KEEP a current-stamped index instead of deleting it — the
    /// counter gate, not a delete, guarantees a stale copy is never loaded.
    /// Non-fatal: callers should catch and log warnings.
    fn saveToFile(self: *NodePropertyExactIndex, graph_dir_path: []const u8, manifest_counter: u64) !void {
        self.lockAllShards();
        defer self.unlockAllShards();

        const idx_path = try self.allocator.alloc(u8, graph_dir_path.len + "/prop_exact.idx".len);
        defer self.allocator.free(idx_path);
        @memcpy(idx_path[0..graph_dir_path.len], graph_dir_path);
        @memcpy(idx_path[graph_dir_path.len..], "/prop_exact.idx");

        const idx_io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(idx_io, idx_path, .{ .truncate = true });
        defer file.close(idx_io);

        var idx_wbuf: [8192]u8 = undefined;
        var idx_fw = file.writerStreaming(idx_io, &idx_wbuf);
        const writer = &idx_fw.interface;

        // 8-byte magic header (v2 = manifest-counter stamped).
        try writer.writeAll("GENPIDX2");
        // Staleness stamp: the engine manifest counter at persist time.
        try writer.writeInt(u64, manifest_counter, .little);

        // Entry count
        var count: u64 = 0;
        for (&self.shards) |*shard| {
            var count_iter = shard.postings.iterator();
            while (count_iter.next()) |_| count += 1;
        }
        try writer.writeInt(u64, count, .little);

        // Each entry: [key_len: u32][key bytes][posting_count: u64][node_ids: u64...]
        for (&self.shards) |*shard| {
            var iter = shard.postings.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const posting = entry.value_ptr.items;
                try writer.writeInt(u32, @intCast(key.len), .little);
                try writer.writeAll(key);
                try writer.writeInt(u64, @intCast(posting.len), .little);
                for (posting) |nid| {
                    try writer.writeInt(u64, nid, .little);
                }
            }
        }
        try idx_fw.flush();
    }

    /// Load the index from `prop_exact.idx` inside `graph_dir_path`, but ONLY if
    /// its manifest-counter stamp equals `expected_counter` (the engine's current
    /// counter). Returns true on a current load; false if missing, corrupt,
    /// legacy-format, or STALE (stamp != expected — a committed write advanced the
    /// counter since persist), in which case the caller rebuilds. This is the
    /// idmap.snapshot load-if-current discipline (GAP-ENT-0048g): staleness is
    /// caught by the stamp, so a stale on-disk copy is never blessed and a LIGHT
    /// checkpoint need not delete a current-stamped file.
    fn loadFromFile(self: *NodePropertyExactIndex, graph_dir_path: []const u8, expected_counter: u64) bool {
        self.lockAllShards();
        defer self.unlockAllShards();

        const idx_path = self.allocator.alloc(u8, graph_dir_path.len + "/prop_exact.idx".len) catch return false;
        defer self.allocator.free(idx_path);
        @memcpy(idx_path[0..graph_dir_path.len], graph_dir_path);
        @memcpy(idx_path[graph_dir_path.len..], "/prop_exact.idx");

        const gsa_io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(gsa_io, idx_path, .{}) catch return false;
        defer file.close(gsa_io);

        var reader_buffer: [4096]u8 = undefined;
        var file_reader = file.reader(gsa_io, &reader_buffer);
        const reader = &file_reader.interface;

        // Validate magic header — only the v2 (counter-stamped) format loads; a
        // legacy GENPIDX1 (unstamped) file is treated as stale -> rebuild.
        var magic: [8]u8 = undefined;
        reader.readSliceAll(&magic) catch return false;
        if (!std.mem.eql(u8, &magic, "GENPIDX2")) return false;

        // Staleness gate: reject unless the stamp matches the engine's current
        // manifest counter (no committed write since the index was persisted).
        const stored_counter = reader.takeInt(u64, .little) catch return false;
        if (stored_counter != expected_counter) return false;

        const entry_count = reader.takeInt(u64, .little) catch return false;

        // We already hold every shard mutex; using `clear()` would re-enter
        // the same non-reentrant `std.Io.Mutex` values and deadlock.
        // See docs/bugs/2026-04-27-adapter-restart-deadlock.md.
        self.clearLockedAll();

        var i: u64 = 0;
        while (i < entry_count) : (i += 1) {
            const key_len = reader.takeInt(u32, .little) catch return false;
            const key = self.allocator.alloc(u8, key_len) catch return false;
            reader.readSliceAll(key) catch {
                self.allocator.free(key);
                return false;
            };

            const posting_count = reader.takeInt(u64, .little) catch {
                self.allocator.free(key);
                return false;
            };
            var posting = std.ArrayList(u64).initCapacity(self.allocator, @intCast(posting_count)) catch {
                self.allocator.free(key);
                return false;
            };
            var j: u64 = 0;
            while (j < posting_count) : (j += 1) {
                const nid = reader.takeInt(u64, .little) catch {
                    posting.deinit(self.allocator);
                    self.allocator.free(key);
                    return false;
                };
                posting.appendAssumeCapacity(nid);
            }

            const shard_idx = exactNodePropertyIndexShardForEncodedKey(key);
            self.shards[shard_idx].postings.put(key, posting) catch {
                posting.deinit(self.allocator);
                self.allocator.free(key);
                return false;
            };
        }

        return true;
    }
};

// ============================================================================
// LabelStringDict — bidirectional label string ↔ LabelId mapping view
// ============================================================================

pub const LabelStringDict = struct {
    allocator: ?Allocator,
    backing: union(enum) {
        local: LocalState,
        external: *gs.label_dict.LabelDictionary,
    },

    const LocalState = struct {
        str_to_id: std.StringHashMap(gs.LabelId),
        id_to_str: std.AutoHashMap(gs.LabelId, []const u8),
        next_id: gs.LabelId,
    };

    pub fn init(allocator: Allocator) LabelStringDict {
        return .{
            .allocator = allocator,
            .backing = .{
                .local = .{
                    .str_to_id = std.StringHashMap(gs.LabelId).init(allocator),
                    .id_to_str = std.AutoHashMap(gs.LabelId, []const u8).init(allocator),
                    .next_id = 1,
                },
            },
        };
    }

    pub fn initView(dict: *gs.label_dict.LabelDictionary) LabelStringDict {
        return .{
            .allocator = null,
            .backing = .{ .external = dict },
        };
    }

    pub fn deinit(self: *LabelStringDict) void {
        switch (self.backing) {
            .local => |*local| {
                const allocator = self.allocator orelse return;
                var it = local.str_to_id.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                }
                local.str_to_id.deinit();
                local.id_to_str.deinit();
            },
            .external => {},
        }
    }

    /// Return the LabelId for `label`, assigning a new one if this is the
    /// first time the label has been seen.
    pub fn getOrCreate(self: *LabelStringDict, label: []const u8) !gs.LabelId {
        switch (self.backing) {
            .local => |*local| {
                const allocator = self.allocator orelse return error.OutOfMemory;
                if (local.str_to_id.get(label)) |id| {
                    return id;
                }

                const id = local.next_id;
                local.next_id += 1;

                const owned = try allocator.dupe(u8, label);
                errdefer allocator.free(owned);

                try local.str_to_id.put(owned, id);
                errdefer _ = local.str_to_id.remove(owned);

                try local.id_to_str.put(id, owned);
                return id;
            },
            .external => |dict| return dict.getOrAssign(label),
        }
    }

    /// Reverse lookup: LabelId → string. Returns null when the id is unknown.
    pub fn getString(self: *const LabelStringDict, id: gs.LabelId) ?[]const u8 {
        return switch (self.backing) {
            .local => |local| local.id_to_str.get(id),
            .external => |dict| dict.getName(id),
        };
    }

    /// Forward lookup: string → LabelId. Returns null when the label is unknown.
    pub fn getId(self: *const LabelStringDict, label: []const u8) ?gs.LabelId {
        return switch (self.backing) {
            .local => |local| local.str_to_id.get(label),
            .external => |dict| dict.getId(label),
        };
    }

    /// Number of labels currently tracked.
    pub fn count(self: *const LabelStringDict) u32 {
        return switch (self.backing) {
            .local => |local| @intCast(local.str_to_id.count()),
            .external => |dict| dict.count(),
        };
    }
};

// ============================================================================
// Property Value Translation
// ============================================================================

/// Convert a geode `PropertyValue` to a graph-storage `PropertyValue`.
///
/// String data is passed through as a slice reference (no copy). The caller
/// must ensure the source value outlives the returned storage value.
pub fn toStorageProperty(allocator: Allocator, val: graph_store.PropertyValue) !gs.PropertyValue {
    return switch (val) {
        .String => |s| .{ .string = s },
        .Int => |i| .{ .int = i },
        .Float => |f| .{ .float = f },
        .Bool => |b| .{ .bool = b },
        .Null => .null,
        .Decimal => |d| .{ .decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .ExtValue => blk: {
            const encoded = try property_codec.encodePropertyValue(allocator, val);
            errdefer allocator.free(encoded);
            const type_tag = if (encoded.len > 0) encoded[0] else 0;
            const payload = if (encoded.len > 1) try allocator.dupe(u8, encoded[1..]) else try allocator.dupe(u8, "");
            allocator.free(encoded);
            break :blk .{ .ext = .{ .type_tag = type_tag, .data = payload } };
        },
    };
}

/// Convert a graph-storage `PropertyValue` to a geode `PropertyValue`.
///
/// String data is duplicated into `allocator` so the returned value is
/// independently owned.
pub fn fromStorageProperty(allocator: Allocator, val: gs.PropertyValue) !graph_store.PropertyValue {
    return switch (val) {
        .string => |s| .{ .String = try allocator.dupe(u8, s) },
        .int => |i| .{ .Int = i },
        .float => |f| .{ .Float = f },
        .bool => |b| .{ .Bool = b },
        .null => .Null,
        .decimal => |d| .{ .Decimal = .{ .coeff = d.coeff, .scale = d.scale } },
        .ext => |ext| blk: {
            const encoded_len = ext.data.len + 1;
            const encoded = try allocator.alloc(u8, encoded_len);
            encoded[0] = @intCast(ext.type_tag & 0xFF);
            @memcpy(encoded[1..], ext.data);
            defer allocator.free(encoded);
            break :blk try property_codec.decodePropertyValue(allocator, encoded);
        },
    };
}

fn freeTemporaryStorageProperty(allocator: Allocator, val: gs.PropertyValue) void {
    switch (val) {
        .ext => |ext| allocator.free(ext.data),
        else => {},
    }
}

pub fn freeOwnedStorageProperty(allocator: Allocator, val: gs.PropertyValue) void {
    switch (val) {
        .string => |s| allocator.free(s),
        .ext => |ext| allocator.free(ext.data),
        else => {},
    }
}

fn hashStorageProperty(allocator: Allocator, value: gs.PropertyValue) !u64 {
    var stack_buf: [64]u8 = undefined;
    const encoded_len = gs.property.encodedSize(value);
    if (encoded_len <= stack_buf.len) {
        const used = try gs.property.encodeInto(stack_buf[0..encoded_len], value);
        return std.hash.Wyhash.hash(0, stack_buf[0..used]);
    }

    const encoded = try gs.property.encode(allocator, value);
    defer allocator.free(encoded);
    return std.hash.Wyhash.hash(0, encoded);
}

/// Hash pre-encoded property bytes directly — zero-copy, no allocation.
/// The encoded bytes must be in the canonical format produced by `gs.property.encode`.
fn hashEncodedPropertyBytes(encoded_value: []const u8) u64 {
    return std.hash.Wyhash.hash(0, encoded_value);
}

/// Pub for the hydration fast-scan merge (graph_store.zig): the streaming
/// scan accumulates ALL decoded property entries (internal keys included, the
/// merge needs the internal id/tenant tags) and applies this exact filter
/// when building the resident node/edge property maps — byte-identical to
/// the legacy getAllNodeProperties/getAllEdgeProperties exposure rule.
pub fn shouldExposePropertyKey(key: []const u8) bool {
    return !std.mem.eql(u8, key, graph_store.INTERNAL_NODE_ID_PROPERTY_KEY) and
        !std.mem.eql(u8, key, graph_store.INTERNAL_EDGE_ID_PROPERTY_KEY) and
        // GAP-0891 (RC-2): the persisted tenant tag must never surface as a
        // user-visible property (it round-trips via getNodeProperty /
        // getEdgeProperty during hydration, not via getAll*Properties).
        !std.mem.eql(u8, key, graph_store.INTERNAL_TENANT_ID_PROPERTY_KEY);
}

// ============================================================================
// ManagedGraph — one engine instance + its label dictionary
// ============================================================================

const merge_tuple_lock_count: usize = 16384;

/// Wraps a single `ShardedGraphEngine` together with its label dictionary and
/// metadata.  Owned by (and keyed inside) the `StorageAdapter`.
pub const ManagedGraph = struct {
    engine: *gs.ShardedGraphEngine,
    label_dict: LabelStringDict,
    exact_node_property_index: NodePropertyExactIndex,
    name: []const u8, // owned
    uuid: [16]u8,
    /// GAP-ENT-0008 Fix B coverage signal: number of live nodes processed by
    /// the most recent `rebuildExactNodePropertyIndex` pass. Reset to 0 at the
    /// start of each rebuild and incremented once per live node the per-shard
    /// scans visit. ATOMIC because the parallel rebuild (one worker per engine
    /// shard) increments it concurrently. After a successful rebuild it equals
    /// the live-node count, letting tests assert every node was processed.
    exact_index_rebuild_iters: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// H4 (cold-open phase 1): lazy-build latch for `exact_node_property_index`.
    /// `true`  → the index is fully built; reads/live-mutations may touch it.
    /// `false` → the index was DEFERRED at open (no/stale persisted snapshot) and
    /// must be rebuilt from the durable pages on first access, instead of paying
    /// the full O(graph) property-chain scan EAGERLY at open (~1.5-2h at 14.27M
    /// nodes — cold-open "phase 1"). Default `true` so a freshly CREATED graph
    /// (which maintains the index incrementally) and the persisted-load path are
    /// unaffected; the open path sets it `false` only when it defers. Mirrors the
    /// engine's `ensureDerivedHydrated` lazy pattern.
    exact_index_built: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    /// Serializes the one-shot deferred build so concurrent first-accessors build
    /// the index EXACTLY ONCE (a double-checked latch). Uses `std.Io.Mutex` (the
    /// file convention — the geode root module's std has no `std.Thread.Mutex`);
    /// locked via the global single-threaded io handle, like the other per-graph
    /// mutexes here. Only `ensureExactNodePropertyIndexBuilt` ever holds it, so it
    /// participates in no lock-ordering relationship and cannot deadlock.
    exact_index_build_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Per-graph audit logger writing to `{graph_dir}/audit.jsonl`.
    /// May be null if audit init failed (soft failure — graph still usable).
    audit_logger: ?*audit.AuditLogger = null,
    /// Per-graph timeseries store persisting to `{graph_dir}/timeseries/`.
    /// May be null if timeseries init failed (soft failure — graph still usable).
    ts_store: ?*ts_mod.Store = null,
    /// Per-graph full-text search index persisting to `{graph_dir}/fts/`.
    /// May be null if FTS init failed (soft failure — graph still usable).
    /// Now a thin facade over `fts_adapter`'s default named index.
    fts_index: ?*fulltext.FullTextIndex = null,
    /// Per-graph FTS storage adapter (the external fts-storage LSM engine
    /// registry) rooted at `{graph_dir}/fts`. Owns the named index engines and
    /// their child dirs; the facade in `fts_index` borrows it. May be null if
    /// FTS init failed (soft failure).
    fts_adapter: ?*adapter_mod.FtsStorageAdapter = null,
    /// The `{graph_dir}/fts` base dir, opened by `initFtsForGraph` and passed to
    /// the adapter. The adapter does NOT close base_dir — we close it here in
    /// `deinit` AFTER tearing the adapter down.
    fts_base_dir: ?std.Io.Dir = null,
    /// Owned path to the FTS subdirectory (retained for diagnostics + free).
    fts_dir: ?[]const u8 = null,
    /// A4a: registry of NAMED fulltext-index facades keyed by index name. Each
    /// facade is a thin `*FullTextIndex` wrapper over the corresponding named
    /// engine in `fts_adapter`. Lazily populated by `getFulltextIndexNamed` and
    /// eagerly populated by `CREATE INDEX ... USING fulltext`. The map OWNS each
    /// facade pointer (allocated with `allocator`, freed in `deinit`) and OWNS
    /// each key (the dupe'd index name). The transitional `fts_index` ("default")
    /// facade is NOT stored here — it is freed separately above so a graph that
    /// only ever uses the default index keeps the original teardown path.
    fts_facades: std.StringHashMapUnmanaged(*fulltext.FullTextIndex) = .{},
    /// A4b: label → fulltext indexes that cover it. Populated on
    /// `CREATE INDEX … USING fulltext`, cleared on `DROP INDEX`. The node
    /// write-maintenance hook (`fts_index_ops.maintainFulltextOnWrite`) does an
    /// O(1) lookup here per label and CHEAP-EXITS when no entry exists (the 99%
    /// common case → near-zero overhead for non-FTS graphs). All keys, spec
    /// names, and property entries are OWNED (dupe'd with the adapter allocator)
    /// and freed in `deinit`. Guarded by `fts_label_index_mutex` (brief holds
    /// only — never held across engine I/O).
    fts_label_index: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(FtsIndexSpec)) = .{},
    /// Brief-hold mutex serializing `fts_label_index` mutation/lookup. Held only
    /// for the map probe + slice copy, NEVER while the fts engine performs I/O.
    /// Uses `std.Io.Mutex` (the convention in this file — `std.Thread.Mutex` is
    /// not available in the geode root module's std) locked via the global
    /// single-threaded io handle.
    fts_label_index_mutex: std.Io.Mutex = std.Io.Mutex.init,
    /// Per-graph RwLock for concurrent read access. Queries acquire shared;
    /// mutations and persistence acquire exclusive. Part of P1 lock migration.
    rwlock: std.Io.RwLock = std.Io.RwLock.init,

    /// Explicit writer-preference counter for ALL EXCLUSIVE acquirers of
    /// `rwlock` (the periodic checkpoint AND the edge-phase schema/MERGE ops).
    ///
    /// `std.Io.RwLock` has NO writer preference: `tryLock` never sets the
    /// `writer` bit (see std/Io/RwLock.zig:28-40), so concurrent SHARED
    /// acquirers always take the lock-free fast CAS path and keep
    /// `reader_mask` non-zero. An EXCLUSIVE `tryLock` therefore NEVER observes
    /// a reader-free instant before its deadline whenever a reader recurs.
    /// Two distinct failures result, both fixed by this mechanism:
    ///   * GAP-0900: under 16 continuous bulk-ingest workers the checkpoint's
    ///     bounded `tryLock` spin SKIPS every cycle → `pending_bulk_ops` never
    ///     resets → un-checkpointed dirty pages grow without bound → OOM.
    ///   * EDGE-PHASE 40001 (2026-06-22): the edge-phase exclusive op (CREATE
    ///     INDEX ON :Taxon(source_id) / relationship MERGE) is starved by the
    ///     recurring checkpoint-loop reader and the generic read path, burning
    ///     its 2-minute deadline → `40001: Write lock acquisition timed out`.
    /// We cannot fix this with the RwLock's own writer-preferred
    /// `lockUncancelable` because that parks on the internal semaphore (the
    /// lost-wakeup wedge fixed in 9bd9b81b).
    ///
    /// Instead an EXCLUSIVE acquirer `fetchAdd(1)`s this counter before its
    /// `tryLock` spin (and `fetchSub(1)`s after via defer), and the SHARED
    /// acquirers consult it via `exclusiveWaitingBackoff`: while > 0, a
    /// would-be reader briefly naps instead of acquiring SHARED, draining the
    /// reader set so the exclusive `tryLock` wins. No thread ever parks on the
    /// RwLock semaphore, so the lost-wakeup immunity is preserved.
    ///
    /// A COUNTER (not a bool) is required so concurrent exclusive acquirers
    /// (e.g. the checkpoint and a CREATE INDEX, or two relationship-MERGE
    /// workers) compose: the flag stays "set" until the LAST pending exclusive
    /// clears, so a reader can't sneak back in and re-starve a still-spinning
    /// exclusive when an earlier one finishes. The backoff is bounded (safety
    /// valve) so a pathologically-stuck exclusive can never deadlock readers,
    /// and exclusive acquirers themselves NEVER consult the backoff, so two
    /// exclusives never wedge each other — they just race `tryLock` normally.
    exclusive_waiting: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// Per-shard rwlocks covering the N partitions of
    /// `GraphStore.nodes` / `GraphStore.edges` / adjacency.  Writers
    /// take one of these in EXCLUSIVE mode for ops routed to a
    /// specific node_id; full-graph exclusive ops
    /// (`acquireWholeGraphExclusive`) take `rwlock` EXCLUSIVE which
    /// blocks new shard writers (they take `rwlock` SHARED first).
    /// Readers that need a consistent full-graph snapshot acquire
    /// every entry in shard-index ascending order.
    ///
    /// Phase 2 of the graph-sharding plan
    /// (docs/superpowers/plans/2026-04-24-graph-sharding-and-wal-
    /// group-commit.md).  See `acquireShardWriteLock` below for the
    /// full locking protocol including cross-shard lock ordering.
    shard_locks: [sharded_store.SHARD_COUNT]std.Io.RwLock =
        [_]std.Io.RwLock{std.Io.RwLock.init} ** sharded_store.SHARD_COUNT,

    // GAP-0894 (2026-06-16): the dedicated `merge_prop_index_lock` RwLock was
    // retired. Both single- and multi-property node MERGE now serialize only
    // same-tuple writers via the striped `merge_tuple_locks` table below; the
    // `merge_prop_index` itself is self-synchronized by its own per-shard
    // internal mutexes (graph_store.MergePropertyIndex). Nothing acquired this
    // graph-global lock once the single-property path was striped, so it was
    // removed rather than left as a live-looking lock that nothing locks.

    /// CANARY: REQ=REQ-QUIC-HC-109; FEATURE="High-Concurrency Mutations"; ASPECT=MultiPropertyMergeTupleLocks; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=storage; UPDATED=2026-05-27
    /// CANARY: REQ=REQ-QUIC-HC-167; FEATURE="High-Concurrency Mutations"; ASPECT=MergeTupleLockStriping; STATUS=IMPL; TEST=test_graph_storage_adapter_metrics; OWNER=storage; UPDATED=2026-05-29
    ///
    /// Striped mutexes for node MERGE (both single- and multi-property since
    /// GAP-0894). MERGE needs to serialize
    /// only requests for the same property tuple while still allowing shard
    /// writes for unrelated tuples to proceed under `rwlock` SHARED. The
    /// stripe table is intentionally larger than the current 4096 sustained
    /// ceiling target so unrelated tuples rarely share a mutex. The table is
    /// heap-allocated per graph so increasing the stripe count does not bloat
    /// the ReleaseFast object file with a massive static mutex array.
    merge_tuple_locks: []std.Io.Mutex,

    /// Diagnostic: cumulative count of multi-property MERGE tuple-lock
    /// acquires. Paired with the wait/hold counters below to distinguish
    /// real same-tuple serialization from accidental stripe collision.
    merge_tuple_lock_acquired_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    merge_tuple_lock_wait_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    merge_tuple_lock_hold_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    merge_tuple_lock_max_wait_ns_observed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    merge_tuple_lock_max_hold_ns_observed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Brief-hold mutex covering the other outer-StringHashMap
    /// metadata operations that shard writers touch indirectly
    /// (label_index getOrPut, graphs put, id_maps init,
    /// edge_type_index getOrPut).  Holds are microseconds — the
    /// outer StringHashMap operation is a single bucket probe +
    /// optional rehash, not the per-label posting-list mutation
    /// which is already guarded by its own `LabelPosting.mutex`.
    ///
    /// Under the shard-locked write protocol (Phase 2), a shard
    /// writer holds `mg.rwlock` SHARED + `shard_locks[idx]`
    /// EXCLUSIVE for the duration of the op.  Inside that scope
    /// the writer briefly takes this mutex for the single moment
    /// it touches a string-keyed outer map.  Release before the
    /// shard lock so the mutex is always held strictly inside the
    /// shard lock scope — prevents a future consumer from taking
    /// shard lock + string_indexes_mutex in a different order and
    /// deadlocking.
    string_indexes_mutex: std.Io.Mutex = std.Io.Mutex.init,

    /// Diagnostic: cumulative count of SHARED acquires on `rwlock`.
    rwlock_shared_acquired_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Diagnostic: cumulative wall-time (ns) all SHARED acquires waited
    /// before locking. A growing value with steady acquired count signals
    /// EXCLUSIVE-side starvation.
    rwlock_shared_wait_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Diagnostic: cumulative wall-time (ns) all EXCLUSIVE acquires waited.
    rwlock_exclusive_wait_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Diagnostic: cumulative wall-time (ns) the SHARED lock was actually held
    /// (release_ts - acquire_ts, summed). Pairs with `rwlock_shared_wait_ns_total`
    /// (which counts time-to-acquire): wait grows under contention, hold grows
    /// under long critical sections.
    rwlock_shared_hold_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Diagnostic: longest SHARED hold (ns) observed so far. Updated with a
    /// non-atomic load+max+store on release — racy by design; occasional lost
    /// updates under concurrent release are acceptable for a diagnostic max.
    /// Do NOT replace with a CAS loop; the cost outweighs the precision gain
    /// for an instrumentation counter.
    rwlock_shared_max_hold_ns_observed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Per-site hold-time decomposition (added 2026-04-26 for the H5a
    // residual-bisection). The aggregate counter above sums all sites;
    // these break it out by call-site tag so we can identify which
    // acquirer is the long-hold offender without re-running gdb.
    rwlock_shared_hold_snapshot_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rwlock_shared_hold_point_read_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rwlock_shared_hold_bulk_merge_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rwlock_shared_hold_bulk_edge_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rwlock_shared_hold_fallback_ns_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Obtain the vtable-based `GraphStorage` interface for direct low-level
    /// access to the engine.
    pub fn storage(self: *ManagedGraph) gs.GraphStorage {
        return self.engine.storage();
    }

    /// Return the per-shard `GraphEngine` that owns `node_id`. Cheap: just
    /// an index into the shard array.
    pub fn shardEngineForNode(self: *ManagedGraph, node_id: u64) *gs.GraphEngine {
        return self.engine.shards[gs.shard_count.shardOfNode(node_id)];
    }

    /// A4a: resolve a NAMED fulltext facade by index name, lazily constructing
    /// (and caching in `fts_facades`) one over the backing engine when present.
    /// Returns null if FTS is uninitialised for this graph OR no engine named
    /// `index_name` exists in the adapter registry (so an unknown name yields
    /// null rather than a fabricated empty index). The returned facade is owned
    /// by `fts_facades` and freed in `deinit`; callers must NOT free it.
    pub fn getFulltextIndexNamed(self: *ManagedGraph, allocator: Allocator, index_name: []const u8) ?*fulltext.FullTextIndex {
        if (self.fts_facades.get(index_name)) |existing| return existing;
        const fa = self.fts_adapter orelse return null;
        // Lazily re-open an on-disk index that is not yet in the adapter's
        // in-memory registry. After a store restart `initFtsForGraph` builds an
        // engine-free adapter (the registry starts empty) even though the index
        // tree is durably present under {graph_dir}/fts/<name>. Without this
        // re-open, a post-restart `fulltext_search` would resolve to null and
        // silently return zero hits. `openIndex` replays the on-disk WAL/segments
        // (it errors `IndexNotFound` when no such dir exists → we fall through to
        // the null return below, preserving "unknown name → no facade"). The
        // engine captures THIS (connection/query) thread as its owner; its later
        // flush/deinit run on the same thread during store teardown
        // (`ManagedGraph.deinit` → `fts_adapter.deinit`), mirroring the lazy-open
        // already performed by `createFulltextIndexNamed`.
        if (fa.getIndex(index_name) == null) {
            fa.openIndex(index_name) catch |err| switch (err) {
                // error-policy: A — no on-disk dir: "unknown name → no facade"
                // contract, handled by the null return below.
                adapter_mod.Error.IndexNotFound => {},
                // error-policy: B — a real open failure (corrupt WAL/segments)
                // silently degrading to "zero hits" would mask data loss; warn.
                else => log.warn("fts lazy re-open failed for index '{s}': {s}", .{ index_name, @errorName(err) }),
            };
        }
        // Only build a facade for an engine that actually exists on the adapter.
        if (fa.getIndex(index_name) == null) return null;

        const facade = allocator.create(fulltext.FullTextIndex) catch return null;
        facade.* = fulltext.FullTextIndex.initBacked(allocator, fa, index_name) catch {
            allocator.destroy(facade);
            return null;
        };
        // Key the map on the facade's own owned name dupe so the map key and the
        // facade share lifetime and we don't double-own the string.
        self.fts_facades.put(allocator, facade.index_name, facade) catch {
            facade.deinit();
            allocator.destroy(facade);
            return null;
        };
        return facade;
    }

    /// A4a: drop a NAMED fulltext facade from the cache (deinit + destroy),
    /// freeing the facade and removing its map entry. The backing engine is NOT
    /// touched here — the caller drops the engine via `fts_adapter.dropIndex`.
    /// No-op if no cached facade exists for `index_name`.
    pub fn dropFulltextFacade(self: *ManagedGraph, allocator: Allocator, index_name: []const u8) void {
        if (self.fts_facades.fetchRemove(index_name)) |kv| {
            kv.value.deinit();
            allocator.destroy(kv.value);
        }
    }

    /// A4b: a single fulltext index covering some label, as recorded in
    /// `fts_label_index`. `name` is the index name; `properties` is the ordered
    /// list of string-valued properties the index tokenizes into one document.
    /// Both `name` and every `properties` entry are OWNED (dupe'd with the
    /// adapter allocator) and freed in `removeFtsLabelIndex` / `deinit`.
    pub const FtsIndexSpec = struct {
        name: []u8, // owned
        properties: [][]u8, // owned (slice + each element)
    };

    /// A4b: record that fulltext index `name` (over `properties`) covers `label`.
    /// Dupes `label`, `name`, and each property with `allocator` so the registry
    /// owns its strings independent of the caller's buffers. Idempotent on
    /// (label, name): a duplicate spec for the same label+name is not appended.
    /// Brief mutex hold only (no engine I/O).
    pub fn addFtsLabelIndex(
        self: *ManagedGraph,
        allocator: Allocator,
        label: []const u8,
        name: []const u8,
        properties: []const []const u8,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.fts_label_index_mutex.lockUncancelable(io);
        defer self.fts_label_index_mutex.unlock(io);

        const gop = try self.fts_label_index.getOrPut(allocator, label);
        if (!gop.found_existing) {
            // Own the key; init an empty spec list.
            gop.key_ptr.* = try allocator.dupe(u8, label);
            gop.value_ptr.* = .empty;
        } else {
            // De-dup: skip if this label already lists an index of this name.
            for (gop.value_ptr.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) return;
            }
        }

        // Build the owned spec.
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);

        const owned_props = try allocator.alloc([]u8, properties.len);
        var filled: usize = 0;
        errdefer {
            for (owned_props[0..filled]) |p| allocator.free(p);
            allocator.free(owned_props);
        }
        for (properties, 0..) |p, i| {
            owned_props[i] = try allocator.dupe(u8, p);
            filled = i + 1;
        }

        try gop.value_ptr.append(allocator, .{ .name = owned_name, .properties = owned_props });
    }

    /// A4b: free a single owned spec (name + each property + the props slice).
    fn freeFtsIndexSpec(allocator: Allocator, spec: FtsIndexSpec) void {
        allocator.free(spec.name);
        for (spec.properties) |p| allocator.free(p);
        allocator.free(spec.properties);
    }

    /// A4b: drop every spec named `name` from all label lists, freeing the owned
    /// strings. Label entries whose list becomes empty are removed (key freed).
    /// Brief mutex hold only.
    pub fn removeFtsLabelIndex(self: *ManagedGraph, allocator: Allocator, name: []const u8) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.fts_label_index_mutex.lockUncancelable(io);
        defer self.fts_label_index_mutex.unlock(io);

        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(allocator);

        var it = self.fts_label_index.iterator();
        while (it.next()) |entry| {
            const list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) {
                if (std.mem.eql(u8, list.items[i].name, name)) {
                    const spec = list.orderedRemove(i);
                    freeFtsIndexSpec(allocator, spec);
                } else {
                    i += 1;
                }
            }
            if (list.items.len == 0) {
                // Defer key removal until after iteration to avoid mutating the
                // map while iterating it.
                // error-policy: A — OOM here leaves an empty list entry in the
                // map until shutdown (tiny leak); correctness unaffected.
                to_remove.append(allocator, entry.key_ptr.*) catch {};
            }
        }

        for (to_remove.items) |label_key| {
            if (self.fts_label_index.fetchRemove(label_key)) |kv| {
                var list = kv.value; // mutable copy — deinit needs *ArrayListUnmanaged
                list.deinit(allocator); // empty list — frees backing array only
                allocator.free(kv.key);
            }
        }
    }

    /// A4b: covering fulltext indexes for `label`, or null if none. The returned
    /// slice borrows the registry's storage and is valid only while no concurrent
    /// add/remove mutates the list. The maintenance hook runs on the executor
    /// (connection) thread and copies the specs it needs before any engine I/O.
    pub fn coveringFtsIndexes(self: *ManagedGraph, label: []const u8) ?[]const FtsIndexSpec {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.fts_label_index_mutex.lockUncancelable(io);
        defer self.fts_label_index_mutex.unlock(io);
        const list = self.fts_label_index.getPtr(label) orelse return null;
        if (list.items.len == 0) return null;
        return list.items;
    }

    /// One (label, index-name, properties) triple deep-copied out of the
    /// `fts_label_index` registry by `snapshotFtsLabelIndex`. All strings are
    /// owned by the caller's allocator (use an arena — nothing is freed
    /// individually).
    pub const FtsRegistryEntry = struct {
        label: []const u8,
        name: []const u8,
        properties: []const []const u8,
    };

    /// Deep-copy every registry triple with `allocator` (intended: an arena).
    /// Lets the raft snapshot-install FTS rebuild enumerate the catalogued
    /// fulltext indexes WITHOUT holding `fts_label_index_mutex` across engine
    /// I/O (the registry mutex is brief-hold only). Brief mutex hold.
    pub fn snapshotFtsLabelIndex(self: *ManagedGraph, allocator: Allocator) ![]FtsRegistryEntry {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.fts_label_index_mutex.lockUncancelable(io);
        defer self.fts_label_index_mutex.unlock(io);

        var out: std.ArrayListUnmanaged(FtsRegistryEntry) = .empty;
        errdefer out.deinit(allocator);

        var it = self.fts_label_index.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |spec| {
                const props = try allocator.alloc([]const u8, spec.properties.len);
                for (spec.properties, 0..) |p, i| props[i] = try allocator.dupe(u8, p);
                try out.append(allocator, .{
                    .label = try allocator.dupe(u8, entry.key_ptr.*),
                    .name = try allocator.dupe(u8, spec.name),
                    .properties = props,
                });
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn deinit(self: *ManagedGraph, allocator: Allocator) void {
        // Teardown order matters: facade → adapter (flushes + closes each engine
        // and its child dir) → base_dir (the adapter never closes base_dir) →
        // free the owned path. Durability is owned by the engine WAL/segments;
        // `adapter.deinit` best-effort flushes each engine before closing it.
        if (self.fts_index) |fts| {
            fts.deinit();
            allocator.destroy(fts);
            self.fts_index = null;
        }
        // A4a: free every NAMED facade (deinit + destroy) and the map itself.
        // Facades borrow `fts_adapter`, so they MUST be torn down before the
        // adapter below. The keys are the dupe'd index names owned by the map.
        {
            var fit = self.fts_facades.iterator();
            while (fit.next()) |entry| {
                entry.value_ptr.*.deinit();
                allocator.destroy(entry.value_ptr.*);
            }
            self.fts_facades.deinit(allocator);
        }
        // A4b: free the label→index registry: each label key, every spec's name
        // + property strings + props slice, and each per-label ArrayList, then
        // the map itself. Done before `fts_adapter` teardown for symmetry with
        // the facade teardown above (the registry holds no engine pointers).
        {
            var lit = self.fts_label_index.iterator();
            while (lit.next()) |entry| {
                for (entry.value_ptr.items) |spec| {
                    freeFtsIndexSpec(allocator, spec);
                }
                entry.value_ptr.deinit(allocator);
                allocator.free(entry.key_ptr.*);
            }
            self.fts_label_index.deinit(allocator);
        }
        if (self.fts_adapter) |fa| {
            fa.deinit();
            self.fts_adapter = null;
        }
        if (self.fts_base_dir) |*bd| {
            bd.close(std.Io.Threaded.global_single_threaded.io());
            self.fts_base_dir = null;
        }
        if (self.fts_dir) |dir| {
            allocator.free(dir);
            self.fts_dir = null;
        }
        if (self.ts_store) |tss| {
            tss.deinit();
            allocator.destroy(tss);
            self.ts_store = null;
        }
        if (self.audit_logger) |al| {
            al.deinit();
            allocator.destroy(al);
            self.audit_logger = null;
        }
        // error-policy: A — best-effort close during teardown; WAL recovery
        // handles anything a failed close left behind.
        self.engine.close() catch {};
        self.exact_node_property_index.deinit();
        allocator.free(self.merge_tuple_locks);
        self.label_dict.deinit();
        allocator.free(self.name);
        allocator.destroy(self);
    }
};

fn resolvePersistedLabelId(mg: *ManagedGraph, label: []const u8) !gs.LabelId {
    if (mg.label_dict.getId(label)) |id| return id;
    // CANARY: REQ=REQ-QUIC-HC-171; FEATURE="High-Concurrency Mutations"; ASPECT=LabelDictionaryCheckpoint; STATUS=IMPL; TEST=tests/perf/test_group_commit_coordinator.zig; OWNER=storage; UPDATED=2026-05-29
    //
    // LabelStringDict is a view over shard 0's dictionary. Creating labels
    // through that view updates memory but does not dirty the sharded engines,
    // so checkpoint/reopen can recover nodes with label IDs whose names were
    // never persisted. Use the engine API for first sight of a label: it
    // broadcasts the mapping to every shard and dirties the dictionaries.
    const id = try mg.engine.getOrAssignLabel(label);

    // Security-graph durability (gap 0026, twin of the sync-mode carve-out
    // in createGraphLocked): the label dictionary is NOT WAL-logged — it is
    // persisted only at checkpoint (labels.dict). Per-commit WAL fsync alone
    // is therefore insufficient on a FRESH (never-checkpointed) security
    // graph: after a crash, recovery replays the user/role/policy node
    // records from the fsynced WAL but has lost the "User"/"Role"/... name→id
    // mappings, leaving every security record unreachable by label — the
    // same silent auth-state loss this gap is about. Persist the (tiny,
    // bounded — a handful of labels ever) per-shard dictionaries
    // synchronously on FIRST sight of a security-graph label, and fail the
    // mutation if the persist fails: durability before ack, fail closed.
    // saveToFile is atomic (tmp + fsync + rename), matching the checkpoint
    // writer, so a crash mid-save leaves the previous dictionary intact.
    if (std.mem.eql(u8, mg.name, "__geode_security")) {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (mg.engine.shards) |shard| {
            const labels_path = try std.fmt.bufPrint(&path_buf, "{s}/labels.dict", .{shard.graph_dir.path});
            try shard.label_dict.saveToFile(labels_path);
        }
    }
    return id;
}

/// Security-graph durability (gap 0026), workaround for an upstream
/// graph-storage WAL mis-log: `GraphEngine.addLabelTxn` logs the label block
/// with `logPage(txn, .var_store, result.head)`, but a var_store head is a
/// REFERENCE `(page_id << 16 | offset)`, not a page id — so the page image
/// that actually holds the node's label list is never WAL-logged (a bogus
/// sparse page id is logged instead). Crash recovery then replays the node
/// record (whose `label_head` points at the ref) but the referenced
/// var_store page is missing/zeroed: the node survives, its LABEL LINKAGE is
/// silently lost, and every label-indexed lookup (`getNodesByLabel(:User)`,
/// the persisted-admin probe, user reload) stops seeing the record — auth
/// state loss. Until the upstream fix ships (log `head >> 16`), re-log the
/// CORRECT var_store page inside the same txn so the corrected image commits
/// (and, on the security graph's `sync_each_commit` engines, fsyncs) with
/// the mutation. Scoped to `__geode_security`: on bulk graphs this would add
/// an extra ~8 KB WAL image per label-add (prohibitive at ingest scale), and
/// their deferred-mode durability barrier is the checkpoint, which flushes
/// the real pages directly and is unaffected by the mis-logged WAL image.
/// No-op for non-security graphs and label-less nodes.
fn relogSecurityLabelPageTxn(mg: *ManagedGraph, node_shard: anytype, node_id: u64, txn: gs.TxnId) !void {
    if (!std.mem.eql(u8, mg.name, "__geode_security")) return;
    const rec = (try node_shard.getNode(node_id)) orelse return;
    if (rec.label_head == 0) return;
    try node_shard.logPagePublic(txn, .var_store, rec.label_head >> 16);
}

/// Auto-commit variant of `relogSecurityLabelPageTxn` for the
/// `mg.engine.addLabel` (self-committing) call sites: the label add has
/// already committed, so the corrected page image is logged in its own tiny
/// follow-up txn. Security-graph only; the second commit is one extra WAL
/// fsync on an admin-rare path.
fn relogSecurityLabelPageAutoCommit(mg: *ManagedGraph, node_shard: anytype, node_id: u64) !void {
    if (!std.mem.eql(u8, mg.name, "__geode_security")) return;
    const txn = try node_shard.beginTxn();
    errdefer node_shard.abortTxn(txn) catch {};
    try relogSecurityLabelPageTxn(mg, node_shard, node_id, txn);
    try node_shard.commitTxn(txn);
}

/// Security-graph durability (gap 0026): crash-recovery self-heal for the
/// per-shard manifest counters. graph-storage's WAL replay restores PAGE
/// contents but does NOT advance `manifest.next_node_id` / `node_count` /
/// `next_txn_id` — those are persisted only at checkpoint. After a crash
/// that followed WAL-fsynced security commits, any node created since the
/// last checkpoint exists in the replayed pages, but:
///   * every scan path bounds itself by `manifest.next_node_id`
///     (`engine.scanNodes`, the derived label-index rebuild, `scanAllNodes`
///     hydration) — so the recovered user/role/policy record is INVISIBLE to
///     the persisted-admin probe, user reload, and label lookups, and
///   * `allocNode` hands out ids from the stale `next_node_id` — RE-ISSUING
///     the recovered records' slots and silently overwriting them on the
///     next insert.
/// Heal by scanning the actually-allocated node pages (bounded by on-disk
/// page counts — the security graph is tiny) and advancing the counters past
/// the highest live slot. `next_txn_id` is bumped past the WAL's replayed
/// LSN so a reused txn id can never let a later crash-recovery misclassify
/// (and discard) an older committed txn's records. Idempotent: no-ops when
/// the manifest is already current (clean restart). Scoped to
/// `__geode_security` at open; bulk graphs keep the upstream behavior —
/// their deferred-mode durability contract is checkpoint-based, and the
/// checkpoint persists the manifest.
fn healSecurityEngineCounters(mg: *ManagedGraph) void {
    if (!std.mem.eql(u8, mg.name, "__geode_security")) return;
    const stride: u64 = gs.sharded_engine.SHARD_COUNT;
    for (mg.engine.shards) |shard| {
        const pager = shard.file_manager.getPager(.nodes) orelse continue;
        const page_count = pager.pageCount() catch continue;
        if (page_count == 0) continue;
        const npp: u64 = shard.node_store.nodes_per_page;

        const Ctx = struct {
            max_id: u64 = 0,
            live: u64 = 0,
            fn cb(ctx: *@This(), id: u64, rec: gs.node.NodeRec) void {
                _ = rec;
                ctx.live += 1;
                if (id > ctx.max_id) ctx.max_id = id;
            }
        };
        var ctx = Ctx{};
        // error-policy: A — a failed heal scan leaves the stale (upstream)
        // counters in place; strictly no worse than before this fix.
        shard.node_store.scanNodes(page_count * npp, &ctx, Ctx.cb) catch continue;

        // Reused txn ids are a corruption hazard regardless of whether any
        // node survived; heal unconditionally for this shard.
        const healed_txn = shard.wal.current_lsn + 1;
        if (healed_txn > shard.manifest.next_txn_id) {
            shard.manifest.next_txn_id = healed_txn;
        }
        if (healed_txn > shard.txn_manager.next_txn_id) {
            shard.txn_manager.next_txn_id = healed_txn;
        }

        if (ctx.live == 0) continue;
        const healed_next = ctx.max_id + stride;
        if (healed_next > shard.manifest.next_node_id) {
            shard.manifest.next_node_id = healed_next;
        }
        if (ctx.live > shard.manifest.node_count) {
            shard.manifest.node_count = ctx.live;
        }
    }
}

fn initMergeTupleLocks(allocator: Allocator) ![]std.Io.Mutex {
    const locks = try allocator.alloc(std.Io.Mutex, merge_tuple_lock_count);
    for (locks) |*lock| {
        lock.* = std.Io.Mutex.init;
    }
    return locks;
}

// ============================================================================
// ShardedGraphEngine TxnId encoding helpers (mirrors sharded_engine.zig internals).
//
// ShardedGraphEngine encodes the shard index in the high 8 bits of TxnId so
// commitTxn/abortTxn can route back to the right per-shard engine.  These
// helpers replicate that layout so graph_storage_adapter.zig can decode a
// statement-txn id to determine whether a given node_id resides on the same
// shard and can therefore share the existing local txn.
//
// Layout (matches sharded_engine.zig):
//   bits [63:56] = shard_index  (high 8 bits)
//   bits [55:0]  = per-shard local TxnId
// ============================================================================

const SHARDED_TXN_SHARD_SHIFT: u6 = 56;
const SHARDED_TXN_LOCAL_MASK: u64 = (@as(u64, 1) << 56) - 1;

/// Extract the shard index from a ShardedGraphEngine-encoded TxnId.
fn shardedTxnShard(txn: gs.TxnId) usize {
    return @as(usize, @intCast(txn >> SHARDED_TXN_SHARD_SHIFT));
}

/// Extract the per-shard local TxnId from a ShardedGraphEngine-encoded TxnId.
fn shardedTxnLocal(txn: gs.TxnId) gs.TxnId {
    return txn & SHARDED_TXN_LOCAL_MASK;
}

/// Encode a shard index and per-shard local TxnId back into the
/// ShardedGraphEngine's wire format.  Used by beginStatementTxnForShard so the
/// resulting txn_id round-trips through commitTxn / abortTxn correctly.
fn encodeShardedTxn(shard_idx: usize, local: gs.TxnId) gs.TxnId {
    return (@as(gs.TxnId, @intCast(shard_idx)) << SHARDED_TXN_SHARD_SHIFT) | (local & SHARDED_TXN_LOCAL_MASK);
}

/// Return the per-shard engine TxnId to use for an operation on `node_id`
/// given an outer `stmt_txn_id` opened via `ShardedGraphEngine.beginTxn()`.
///
/// If the statement txn was opened on the same shard that owns `node_id`,
/// return the decoded local txn (batching all ops in the same fsync).
/// Otherwise return null — the caller should open a fresh local txn on the
/// node's shard.
fn shardLocalTxnForNode(stmt_txn_id: gs.TxnId, node_id: u64) ?gs.TxnId {
    const txn_shard = shardedTxnShard(stmt_txn_id);
    const node_shard = gs.shard_count.shardOfNode(node_id);
    if (txn_shard != node_shard) return null;
    return shardedTxnLocal(stmt_txn_id);
}

fn addIndexedNodeProperty(mg: *ManagedGraph, label_id: gs.LabelId, node_id: u64, property_key: []const u8, value: gs.PropertyValue) !void {
    return addIndexedNodePropertyEx(mg, label_id, node_id, property_key, value, false);
}

/// `assume_new=true` is passed by first-time-indexing callers (bulk insert, load
/// rebuild, addNodeLabel) so the exact index skips its O(posting-length) de-dup
/// scan — see NodePropertyExactIndex.addEx. GAP-0900 O(N^2) bulk-load fix.
fn addIndexedNodePropertyEx(mg: *ManagedGraph, label_id: gs.LabelId, node_id: u64, property_key: []const u8, value: gs.PropertyValue, assume_new: bool) !void {
    // GAP-0900 Layer-3 (Fix 2): in lean mode (GEODE_INDEX_MERGE_KEYS_ONLY=1),
    // only MERGE/declared keys go into the exact property index; other props are
    // never used for an exact-index lookup (the point-read fast path falls back
    // to a label scan for them — still correct). Default off: index everything.
    if (!graph_store.shouldIndexProperty(property_key)) return;
    const value_hash = try hashStorageProperty(mg.engine.allocator, value);
    try mg.exact_node_property_index.addEx(label_id, property_key, value_hash, node_id, assume_new);
}

fn removeIndexedNodeProperty(mg: *ManagedGraph, label_id: gs.LabelId, node_id: u64, property_key: []const u8, value: gs.PropertyValue) void {
    const value_hash = hashStorageProperty(mg.engine.allocator, value) catch return;
    mg.exact_node_property_index.remove(label_id, property_key, value_hash, node_id);
}

/// Zero-copy variant: index a property using pre-encoded bytes from the iterator.
/// Avoids the decode-then-re-encode round-trip that `addIndexedNodeProperty` performs.
fn addIndexedNodePropertyFromEncoded(mg: *ManagedGraph, label_id: gs.LabelId, node_id: u64, property_key: []const u8, encoded_value: []const u8, assume_new: bool) !void {
    // GAP-0900 Layer-3 (Fix 2): see addIndexedNodeProperty — skip non-merge keys
    // in lean mode. Default off: index everything.
    // `assume_new`: first-time-indexing callers skip the de-dup scan (O(N^2) fix).
    if (!graph_store.shouldIndexProperty(property_key)) return;
    const value_hash = hashEncodedPropertyBytes(encoded_value);
    try mg.exact_node_property_index.addEx(label_id, property_key, value_hash, node_id, assume_new);
}

/// Zero-copy variant: remove a property from the index using pre-encoded bytes.
fn removeIndexedNodePropertyFromEncoded(mg: *ManagedGraph, label_id: gs.LabelId, node_id: u64, property_key: []const u8, encoded_value: []const u8) void {
    const value_hash = hashEncodedPropertyBytes(encoded_value);
    mg.exact_node_property_index.remove(label_id, property_key, value_hash, node_id);
}

/// Indexes a node's properties under the given labels. Always a FIRST-TIME
/// indexing of `node_id` under `label_ids` (fresh insert, load rebuild, or a
/// newly-added label → a new (label,key,value) posting), so it passes
/// `assume_new=true` to skip the exact-index de-dup scan (GAP-0900 O(N^2) fix).
fn addNodePropertiesForLabels(mg: *ManagedGraph, node_id: u64, label_ids: []const gs.LabelId, prop_head: u64) !void {
    if (prop_head == 0 or label_ids.len == 0) return;

    // Properties live on the same shard as the owning node. Routing via
    // `mg.engine.getAllProperties(prop_head)` would hash the prop_head
    // through `shardOfNode`, but prop pages are NOT shard-striped (each
    // shard's FreeSpaceManager allocates page IDs 1, 2, 3, ... locally),
    // so the routing would land on the wrong shard. Use the node's
    // shard directly.
    var iter = try mg.shardEngineForNode(node_id).getAllProperties(prop_head);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        // Zero-copy path: hash the pre-encoded value bytes directly from the
        // iterator instead of re-fetching, decoding (which heap-allocates for
        // strings/ext), and re-encoding.
        for (label_ids) |label_id| {
            try addIndexedNodePropertyFromEncoded(mg, label_id, node_id, entry.key, entry.encoded_value, true);
        }
    }
}

fn removeNodePropertiesForLabels(mg: *ManagedGraph, node_id: u64, label_ids: []const gs.LabelId, prop_head: u64) void {
    if (prop_head == 0 or label_ids.len == 0) return;

    // Properties live on the node's shard — see addNodePropertiesForLabels
    // for why `mg.engine.getAllProperties(prop_head)` would misroute.
    var iter = mg.shardEngineForNode(node_id).getAllProperties(prop_head) catch return;
    defer iter.deinit();
    while (iter.next() catch return) |entry| {
        // Zero-copy path: hash the pre-encoded value bytes directly.
        for (label_ids) |label_id| {
            removeIndexedNodePropertyFromEncoded(mg, label_id, node_id, entry.key, entry.encoded_value);
        }
    }
}

// GAP-ENT-0008 Fix B: parallel restart-time rebuild of the exact node-property
// index. The serial version of this (a single-core cross-shard O(graph) scan,
// ~57M hashmap inserts) dominated restart recovery (~hours at 14.27M nodes).
//
// Safety invariant that makes the per-shard scans race-free in parallel:
//   * The 16 engine shards own DISJOINT node-id ranges (shardOfNode(id) == idx)
//     and their OWN stores — node_store, label_store, buffer_pool are per-shard
//     instances (only the thread pool is shared). Each worker scans exactly one
//     shard and, since a node's properties/labels live on that same shard,
//     touches ONLY that shard's stores. No two workers touch the same store.
//   * The single shared destination is `mg.exact_node_property_index`, which is
//     64-way mutex-sharded: every insert (`addEx`) takes the per-shard
//     `std.Io.Mutex`, which gives REAL cross-thread mutual exclusion (atomic CAS
//     fast path + OS futex on contention — the "single_threaded" io handle only
//     scopes the async executor, not the mutex's atomics/futex), so concurrent
//     inserts from different workers are safe.
//   * The exact-index allocator (== `mg.engine.allocator`, the adapter
//     allocator) is thread-safe in every entrypoint: the server uses
//     `std.heap.smp_allocator` (sharded per-core) and tests/CLI use
//     `std.heap.DebugAllocator`, which is thread-safe in multi-threaded builds.
//     The codebase already runs concurrent engine work (e.g. parallel buffer
//     -pool flush) through this same allocator, so its thread-safety is an
//     existing invariant.
//   * The coverage counter is atomic.
// Hence the parallel rebuild produces a posting-for-posting identical index to
// the serial one. If only one shard exists (or any other degenerate case) we
// fall back to a straight serial loop.
/// GAP-ENT-0048 DEFECT B: nodes visited between two cancel-flag polls in the
/// exact-index rebuild scan. Bounds how long a cancelled read stays wedged in
/// the per-node property-chain walk (the dominant `BufferPool.pin` cost of the
/// rebuild) before it aborts — the same batch discipline the executor's
/// scan/aggregate loops use.
const exact_rebuild_cancel_poll_batch: usize = 256;

fn rebuildExactNodePropertyIndex(mg: *ManagedGraph, cancel: read_budget.CancelFlags) !void {
    // H4 (cold-open phase 1): instrument every rebuild so tests can prove the
    // deferred-build latch rebuilds 0 times at open and exactly once on first
    // access. Counts the eager-open, test-helper, AND lazy-first-access paths.
    _ = g_exact_rebuild_runs.fetchAdd(1, .monotonic);
    mg.exact_node_property_index.clear();
    mg.exact_index_rebuild_iters.store(0, .monotonic);
    // task0048d: per-build dispatch accounting (pool vs inline shard scans).
    g_exact_rebuild_pool_tasks.store(0, .monotonic);
    g_exact_rebuild_inline_tasks.store(0, .monotonic);

    const shards = mg.engine.shards;

    // Per-shard scan context: shares only `mg` (whose exact-property index is
    // mutex-sharded) and writes its OWN `err` slot — no shared mutable scratch.
    // GAP-ENT-0048 DEFECT B: each context carries the caller's read-executor
    // cancel flags (captured on the handler thread) so the pool workers — which
    // do NOT inherit the handler's threadlocal read scope — can poll them.
    const ShardCtx = struct {
        mg: *ManagedGraph,
        shard: *gs.GraphEngine,
        cancel: read_budget.CancelFlags,
        since_poll: usize = 0,
        err: ?anyerror = null,

        fn scanCallback(self: *@This(), node_id: gs.NodeId, rec: gs.node.NodeRec) void {
            if (self.err != null) return;
            // Coverage counter: count every live node the scan presents (atomic
            // so the parallel per-shard workers compose correctly).
            _ = self.mg.exact_index_rebuild_iters.fetchAdd(1, .monotonic);
            _ = g_exact_rebuild_nodes_scanned.fetchAdd(1, .monotonic);
            // GAP-ENT-0048 DEFECT B: poll the read-executor cancel flags at a
            // batch boundary. On a client disconnect / stall-watchdog abort this
            // stops the expensive per-node property-chain walk immediately (the
            // remaining `if (self.err != null) return` fast-outs make the rest of
            // the scan a cheap no-op), so the wedged handler frees instead of
            // paying the whole O(graph) rebuild. Empty flags (write paths / no
            // read scope) never trip.
            self.since_poll += 1;
            if (self.since_poll >= exact_rebuild_cancel_poll_batch) {
                self.since_poll = 0;
                // GAP-ENT-0048 SECONDARY: emit a build-progress heartbeat, then
                // poll ONLY the STREAM (connection-close) cancel — a genuinely
                // gone client frees the handler (DEFECT B). The proto-reader
                // stall (WATCHDOG) cancel is deliberately NOT honoured here: the
                // stall fires precisely because this build makes the handler look
                // idle to the transport, yet the build IS advancing (this
                // heartbeat proves it). Aborting on the stall would leave the
                // index un-latched so the NEXT query restarts the whole O(graph)
                // rebuild — the ~60 s-stall forever-wedge. Let a progressing build
                // run to completion, latch, and persist; every later query is then
                // served from the built/persisted index.
                _ = g_exact_rebuild_heartbeats.fetchAdd(1, .monotonic);
                if (self.cancel.streamTripped()) {
                    self.err = error.ReadQueryCancelled;
                    return;
                }
            }
            if (rec.label_head == 0 or rec.prop_head == 0) return;

            const node_shard = self.mg.shardEngineForNode(node_id);
            const label_ids = node_shard.label_store.getLabels(rec.label_head, self.mg.engine.allocator) catch |err| {
                self.err = err;
                return;
            };
            defer self.mg.engine.allocator.free(label_ids);

            addNodePropertiesForLabels(self.mg, node_id, label_ids, rec.prop_head) catch |err| {
                self.err = err;
            };
        }

        fn run(self: *@This()) void {
            // GAP-ENT-0048 DEFECT B: a STREAM cancel already pending before the
            // first node bails the whole shard WITHOUT touching the node store
            // (the common "client already gone" case — zero page pins). Uses the
            // stream-only source (see SECONDARY): a pre-set stall WATCHDOG flag
            // must NOT prevent the build — the build is what the stalled handler
            // is doing, and it will complete and serve every future reader.
            if (self.cancel.streamTripped()) {
                self.err = error.ReadQueryCancelled;
                return;
            }
            // Each shard owns nodes with ids satisfying shardOfNode(id) == idx.
            self.shard.node_store.scanNodes(self.shard.manifest.next_node_id, self, scanCallback) catch |err| {
                if (self.err == null) self.err = err;
            };
        }
    };

    var ctxs: [gs.sharded_engine.SHARD_COUNT]ShardCtx = undefined;
    for (shards, 0..) |shard, idx| {
        ctxs[idx] = .{ .mg = mg, .shard = shard, .cancel = cancel };
    }

    // Serial fallback: a single shard gains nothing from the pool, and keeps a
    // straightforward path for any degenerate engine layout.
    if (shards.len <= 1) {
        for (ctxs[0..shards.len]) |*c| {
            c.run();
            if (c.err) |err| return err;
        }
        return;
    }

    // Parallel: dispatch one scan task per shard on the engine's shared thread
    // pool, then join. Derive the pool's TaskContext type from the pool itself
    // (rather than importing it) so the task signature matches regardless of how
    // the thread_pool module is wired into the build graph.
    const pool = mg.engine.shared_thread_pool;
    const TaskFnT = @typeInfo(@TypeOf(@TypeOf(pool.*).submit)).@"fn".params[1].type.?;
    const TaskCtxPtr = @typeInfo(@typeInfo(TaskFnT).pointer.child).@"fn".params[1].type.?;
    const Task = struct {
        fn run(ctx_ptr: *anyopaque, _: TaskCtxPtr) void {
            const c: *ShardCtx = @ptrCast(@alignCast(ctx_ptr));
            c.run();
        }
    };

    var wg = pool.waitGroup();
    // GAP-ENT-0048 (task0048d): a submit failure runs ONLY that shard inline and
    // KEEPS submitting the rest — the previous `catch break` serialized every
    // remaining shard onto the calling thread on the first backpressure reject,
    // which at 14.27M could collapse the whole rebuild to a single-threaded scan
    // (the coordinator's ~1.2-core symptom). Instrumented so a test / the 14.27M
    // run can prove the fan-out actually engaged (pool_tasks >= 1).
    var inline_ctxs_buf: [gs.sharded_engine.SHARD_COUNT]*ShardCtx = undefined;
    var inline_n: usize = 0;
    for (ctxs[0..shards.len]) |*c| {
        // Default backpressure (.return_error) is deadlock-safe; the wait_group
        // auto-adds on submit and auto-dones on completion.
        if (pool.submit(Task.run, c, .{ .wait_group = &wg })) |_| {
            _ = g_exact_rebuild_pool_tasks.fetchAdd(1, .monotonic);
        } else |_| {
            inline_ctxs_buf[inline_n] = c;
            inline_n += 1;
        }
    }
    // Shards that failed to submit run inline on this (non-worker) thread BEFORE
    // wg.wait(), so they still complete and are not double-counted by wg.
    for (inline_ctxs_buf[0..inline_n]) |c| {
        _ = g_exact_rebuild_inline_tasks.fetchAdd(1, .monotonic);
        c.run();
    }
    wg.wait();

    // Aggregate errors: first non-null shard error wins (don't swallow).
    for (ctxs[0..shards.len]) |*c| {
        if (c.err) |err| return err;
    }
}

/// H4 (cold-open phase 1): build the exact node-property index on first access
/// if it was DEFERRED at open. Lock-free fast path when already built; otherwise
/// the build mutex serializes a single rebuild from the durable pages (a
/// double-checked latch — concurrent first-accessors build EXACTLY once).
///
/// MUST be called at the top of EVERY public path that READS or live-MUTATES
/// `mg.exact_node_property_index`, BEFORE the index is touched — a missed
/// accessor returns wrong/empty results (read) or corrupts the index (a live
/// write onto an unbuilt index) on a deferred graph. The build itself rebuilds
/// from the durable pages, so it is crash-safe and idempotent (counter-gated by
/// `loadFromFile` on the next open).
///
/// MUST NOT be called from inside `rebuildExactNodePropertyIndex` (its internal
/// `addEx` calls would re-enter here and recurse); the rebuild uses the raw
/// helpers directly.
///
/// H4 persist-on-build: a successful REBUILD (this branch only — never the
/// snapshot-load path, which latches `built` at open without coming through
/// here) triggers a background graph-scoped persist of the just-built index
/// (`spawnExactIndexPersistAfterBuild`), so a crash before the next FULL
/// checkpoint does not re-pay the O(graph) build on reopen. Triggered
/// strictly AFTER the `exact_index_built` latch store so the persist's
/// checkpoint observes `built == true` (the 88a05773 never-persist-unbuilt
/// discipline re-checks the latch under the EXCLUSIVE rwlock).
fn ensureExactNodePropertyIndexBuilt(adapter: *StorageAdapter, mg: *ManagedGraph) !void {
    if (mg.exact_index_built.load(.acquire)) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    mg.exact_index_build_mutex.lockUncancelable(io);
    defer mg.exact_index_build_mutex.unlock(io);
    // Double-check under the mutex: a peer first-accessor may have built it
    // while we waited for the lock.
    if (mg.exact_index_built.load(.acquire)) return;
    // GAP-ENT-0048 DEFECT B: capture THIS (handler) thread's read-executor
    // cancel flags and hand them to the parallel rebuild, whose per-shard pool
    // workers run on threads that do not inherit the threadlocal read scope. If
    // the driving client genuinely DISCONNECTS (STREAM cancel) mid-rebuild, the
    // scan aborts with error.ReadQueryCancelled and the latch stays UNbuilt — the
    // next accessor retries the rebuild cleanly (idempotent: rebuild clears
    // first). GAP-ENT-0048 SECONDARY: a proto-reader STALL (watchdog) abort does
    // NOT stop the build — a progressing build is not a wedged handler, so it
    // runs to completion and latches, and every later query is served from the
    // built (and persist-on-build durable) index instead of restarting the
    // O(graph) rebuild forever. Write paths install no read scope, so
    // `activeCancelFlags` is empty for them and their rebuild is never cancelled.
    try rebuildExactNodePropertyIndex(mg, read_budget.activeCancelFlags());
    mg.exact_index_built.store(true, .release);
    adapter.spawnExactIndexPersistAfterBuild(mg.name);
}

// ============================================================================
// R8 (2026-04-22): Per-statement engine-txn batching.
//
// After R7, each adapter mutation method (createNode, setNodeProperty, ...)
// wraps its engine sub-ops in a single explicit engine transaction — so a
// single adapter call is one WAL fsync.  That still means a GQL statement
// like `CREATE (n:User {p1, p2, p3, p4, p5})` costs 1 (createNode) + 5
// (setNodeProperty) = 6 fsyncs, because the executor calls the adapter
// once per sub-step.
//
// R8 lets the caller open a *statement-scoped* engine transaction that
// subsequent adapter mutations join (skipping their own beginTxn/commitTxn
// pair) so the whole statement commits with a single fsync:
//
//   const txn = try adapter.beginStatementTxn(graph_name);
//   errdefer txn.abort();
//   // adapter.createNode / adapter.setNodeProperty etc. now join `txn`
//   try txn.commit();                  // ONE WAL fsync
//
// Rules:
//   - Uses a `threadlocal var` — only the thread that opened the txn sees
//     it.  The per-graph exclusive write lock is held across the
//     statement, so no other thread can concurrently mutate the same
//     graph — the thread-local is safe.
//   - Mutations on a DIFFERENT graph than the active StatementTxn fall
//     back to the regular auto-commit path (per-sub-op fsync).
//   - `abort()` / `commit()` clear the thread-local.  If neither is
//     called before the guarded scope exits, the engine will keep the
//     txn record as "begin without commit" until replay rolls it back,
//     which is correct but wasteful — use `errdefer txn.abort()`.
// ============================================================================

/// Per-statement engine transaction handle returned by
/// `StorageAdapter.beginStatementTxn`.
pub const StatementTxn = struct {
    mg: *ManagedGraph,
    txn_id: gs.TxnId,
    graph_name: []const u8, // non-owning — adapter's engines map owns the storage

    /// Commit the statement txn → exactly one WAL fsync.
    pub fn commit(self: *StatementTxn) !void {
        t_current_statement_txn = null;
        try self.mg.engine.commitTxn(self.txn_id);
    }

    /// Abort the statement txn (no fsync beyond the ABORT record append).
    /// Safe to call from `errdefer`.
    pub fn abort(self: *StatementTxn) void {
        t_current_statement_txn = null;
        // error-policy: A — abort() is documented errdefer-safe; a failed
        // engine abort is superseded by WAL recovery.
        self.mg.engine.abortTxn(self.txn_id) catch {};
    }
};

threadlocal var t_current_statement_txn: ?*StatementTxn = null;

// R9 (2026-04-22): session-scoped engine txn — spans an entire Geode
// BEGIN TX / COMMIT block.  The msft-graph client sends batches of the
// form `BEGIN; CREATE ... (×38); COMMIT`.  Before R9 each CREATE opened
// its own engine txn + fsync; after R9 the whole batch commits with a
// SINGLE fsync.  Separate thread-local from the per-statement slot so
// a nested per-statement txn (e.g. DDL during a Geode txn) can still
// take precedence.  `currentStatementTxnForGraph` checks the
// per-statement slot first, then falls back to the session slot.
threadlocal var t_session_engine_txn: ?*StatementTxn = null;

// R9 (2026-04-22, lazy variant): backing storage for the session
// engine txn when the executor opens it lazily (on the first mutation
// inside a Geode txn) and therefore has no `ServerState.session_engine_txn_storage`
// pointer in scope.  Lives in thread-local so the backing slot is
// automatically per-session (one QUIC stream = one thread).  Populated
// by `beginSessionTxnLazy`; cleared by `commitSessionTxn` /
// `abortSessionTxn`.
threadlocal var t_session_engine_txn_storage_lazy: StatementTxn = undefined;

/// Return the thread-local statement txn if it targets `graph_name`; else null.
/// Adapter mutation methods consult this to decide whether to batch into an
/// existing transaction or spin their own (the R7 behaviour).  Priority:
/// 1. per-statement txn (R8), 2. session txn (R9).
pub fn currentStatementTxnForGraph(graph_name: []const u8) ?*StatementTxn {
    if (t_current_statement_txn) |txn| {
        if (std.mem.eql(u8, txn.graph_name, graph_name)) return txn;
    }
    if (t_session_engine_txn) |txn| {
        if (std.mem.eql(u8, txn.graph_name, graph_name)) return txn;
    }
    return null;
}

/// True when an R9 session-scoped engine txn is active on this thread.
/// Callers use this to decide whether to open a per-statement txn (no —
/// the session txn covers us) or not.
pub fn hasSessionEngineTxn() bool {
    return t_session_engine_txn != null;
}

/// Return the graph name of the active session-scoped engine txn, if any.
pub fn sessionEngineTxnGraph() ?[]const u8 {
    if (t_session_engine_txn) |txn| return txn.graph_name;
    return null;
}

// ============================================================================
// H3-P2: value-ordered scan (16-shard k-way merge of the ordered indexes)
// ============================================================================

/// Scan direction for `StorageAdapter.orderedScan`. ASC walks values ascending
/// (each per-shard ordered tree's natural byte order); DESC walks descending.
pub const OrderedScanDir = enum { asc, desc };

const OrderedDir = gs.ordered_property_index.OrderedPropertyIndex.Direction;
const OrderedCursor = gs.ordered_property_index.OrderedPropertyIndex.Cursor;

/// Max (key,node_id) pairs pulled from one shard cursor per SHARED-lock hold.
/// Bounds how long a single batch fences a queued EXCLUSIVE checkpoint/apply on
/// that shard (wedge-avoidance), mirroring `label_scan_batch_slots`.
const ordered_scan_batch_slots: usize = 256;

/// One copied-out head from a shard cursor. `key` is an OWNED dup of the tree's
/// (order-preserving) encoded key bytes — copied under the shard lock because
/// the borrowed `OrderedBTree.Entry.key` is only valid under the lock and until
/// the next mutation of that tree.
const OrderedScanHead = struct { key: []u8, node_id: u64 };

/// Per-shard cursor + current bounded batch for the k-way merge.
const OrderedShardState = struct {
    cursor: ?OrderedCursor = null,
    opened: bool = false,
    exhausted: bool = false,
    buf: std.ArrayList(OrderedScanHead) = .empty,
    pos: usize = 0,
};

/// Advance shard `i`'s ordered cursor by a BOUNDED batch, copying (key,node_id)
/// out into owned buffers, then release the shard lock.
///
/// -- LOCK SAFETY (the subtle part) --
///   * Only this shard's adapter SHARED lock is held while reading the tree;
///     `mg.rwlock` is NEVER held across the scan (no checkpoint wedge).
///   * At most `ordered_scan_batch_slots` entries are pulled per acquire, then
///     the lock is released so a queued EXCLUSIVE checkpoint/apply on this shard
///     wins before the next batch.
///   * `exclusiveWaitingBackoff(mg)` parks BEFORE each (re)acquire so a waiting
///     EXCLUSIVE drains the reader set first (mirrors appendLiveNodesForLabelShard).
///   * `OrderedBTree.Entry.key` borrows tree-owned bytes valid only under the
///     lock and until the next tree mutation, so we `dupe` them out here.
///   * The Cursor is HELD ACROSS lock releases (between batches). This is
///     memory-safe under concurrent node insert/update/delete: OrderedBTree
///     insert/remove never free B-tree nodes (a split only shrinks+links leaves;
///     remove frees the key copy, not the node), and Cursor.next()/prev()
///     dereference only the leaf node + its prev/next back-pointers, never the
///     (possibly-relocated) tree handle. A mutation across the gap can yield a
///     torn read (a valid prefix of a consistent order), never a use-after-free.
///     The one unsafe concurrent op is a full ordered-index rebuild
///     (clearTrees) — that is DDL, takes this shard's EXCLUSIVE lock in
///     `createOrderedIndex`, and does not run during a live scan.
fn orderedScanRefill(
    mg: *ManagedGraph,
    i: usize,
    label_id: gs.LabelId,
    key: []const u8,
    dir: OrderedDir,
    st: *OrderedShardState,
    allocator: Allocator,
    io: std.Io,
) !void {
    if (st.exhausted) return;

    // Drop the previous batch's owned key copies before refilling.
    for (st.buf.items) |h| allocator.free(h.key);
    st.buf.clearRetainingCapacity();
    st.pos = 0;

    exclusiveWaitingBackoff(mg);
    mg.shard_locks[i].lockSharedUncancelable(io);
    defer mg.shard_locks[i].unlockShared(io);

    const shard = mg.engine.shards[i];
    if (!st.opened) {
        st.opened = true;
        // openOrderedCursor descends the tree (findLeaf + seek); read it under
        // the SHARED lock. Null => no ordered index registered on this shard.
        st.cursor = shard.openOrderedCursor(label_id, key, dir);
        if (st.cursor == null) {
            st.exhausted = true;
            return;
        }
    }

    var n: usize = 0;
    while (n < ordered_scan_batch_slots) : (n += 1) {
        const e = st.cursor.?.next() orelse {
            st.exhausted = true;
            break;
        };
        const kc = try allocator.dupe(u8, e.key);
        st.buf.append(allocator, .{ .key = kc, .node_id = e.node_id }) catch |err| {
            allocator.free(kc);
            return err;
        };
    }
}

// ============================================================================
// StorageAdapter — top-level adapter managing multiple named graphs
// ============================================================================

pub const StorageAdapter = struct {
    allocator: Allocator,
    data_dir: []const u8, // owned
    engines: std.StringHashMap(*ManagedGraph),
    default_engine: ?*ManagedGraph,
    config: gs.GraphConfig,
    registry: gs.registry.GraphRegistry,
    registry_path: []const u8, // owned
    mutex: std.Io.Mutex,

    // GAP-0900 (observability + checkpoint-cadence): the group-commit bulk
    // fast paths (bulkInsertNodeWithReservedId* / bulkMergeNode*) write through
    // the engine-backed adapter WITHOUT touching the legacy CDC WAL
    // (`notifyMutation`) or `GraphStore.dirty`. In `deferred` sync mode that
    // means the persistence loop's checkpoint triggers never observe the bulk
    // writes, so `checkpointAll` is never invoked between startup and shutdown
    // during a pure bulk ingest — the engine WAL + dirty pages grow unbounded
    // until OOM. These fields let a periodic trigger make an adapter-level
    // checkpoint decision that does NOT depend on the legacy signals.
    //
    //   * `checkpoints_total`  — count of completed `checkpointAll` runs.
    //     Production observability AND the assertion surface for the
    //     deferred-mode bulk-ingest checkpoint regression test.
    //   * `pending_bulk_ops`   — bulk write ops applied since the last
    //     checkpoint. The FIX wires the bulk fast paths to bump this; until
    //     then it stays 0 and `maybeCheckpoint` never fires for bulk writes.
    //   * `last_checkpoint_mono_ns` — monotonic timestamp of the last
    //     checkpoint, used for the time-based cadence trigger.
    checkpoints_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pending_bulk_ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_checkpoint_mono_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    // GAP-0900: load-driven checkpoint cadence. The timer-based persistence
    // loop is unreliable under sustained ingest (its futex timeout is starved
    // when all I/O workers are busy), so the bulk write path itself drives the
    // checkpoint: once `pending_bulk_ops` crosses `checkpoint_ops_threshold`,
    // ONE thread (winner of the `checkpoint_in_progress` CAS) runs
    // `checkpointAll` inline while the rest keep writing. `checkpoint_in_progress`
    // bounds it to a single concurrent checkpoint so writers don't stampede.
    // Threshold 0 disables load-driven checkpointing (set from env at init).
    checkpoint_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    checkpoint_ops_threshold: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    // GAP-0900 (B): write-backpressure hard cap. When `pending_bulk_ops` reaches
    // this many un-checkpointed ops, a writer that finds a checkpoint already in
    // progress BLOCKS until it drains, instead of racing ahead — bounding the
    // un-checkpointed WAL/dirty-page set even if a checkpoint is momentarily slow
    // (defense-in-depth so deferred bulk ingest can never OOM from a dirty-page
    // spike). 0 disables backpressure. Set from env at init (default = a multiple
    // of `checkpoint_ops_threshold`).
    checkpoint_max_pending: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    // GAP-ENT-0038: once-only guard for registerCheckpointMetrics (0 = not yet
    // registered). Registration is retried until the global runtime-metrics
    // registry exists, then latches.
    checkpoint_metrics_registered: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    // H4 persist-on-build: background persist threads spawned after a
    // successful deferred exact-index REBUILD (one bounded graph-scoped
    // checkpoint each — see `spawnExactIndexPersistAfterBuild`). Guarded by
    // `exact_persist_mutex`; `exact_persist_shutdown` refuses new spawns once
    // deinit begins; deinit() joins the list BEFORE any teardown.
    exact_persist_threads: std.ArrayList(std.Thread) = .empty,
    exact_persist_mutex: std.Io.Mutex = std.Io.Mutex.init,
    exact_persist_shutdown: bool = false,

    /// Create a new `StorageAdapter`.
    ///
    /// `data_dir` is the root directory under which per-graph subdirectories
    /// are created (each at `{data_dir}/graphs/{uuid_hex}/`).  The
    /// `{data_dir}/graphs/` parent directory itself is created lazily by the
    /// first writer that needs it (audit logger, property-index checkpoint,
    /// timeseries, FTS) — `createDirPath` recursively materialises parents.
    /// Eagerly creating an empty placeholder here violates the storage-layout
    /// invariant exercised by tests/test_admin_bootstrap_env_and_reset.zig
    /// because the actual sharded data lives at `{data_dir}/<graph_uuid>/...`,
    /// leaving the placeholder as a competing empty `graphs/` root.
    pub fn init(allocator: Allocator, data_dir: []const u8, config: gs.GraphConfig) !*StorageAdapter {
        const owned_dir = try allocator.dupe(u8, data_dir);
        errdefer allocator.free(owned_dir);

        // Ensure the data_dir itself exists (lazy `graphs/` creation
        // happens on first use, see comment above).
        std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), owned_dir) catch |err| {
            log.err("failed to create data directory {s}: {}", .{ owned_dir, err });
            return err;
        };

        const self = try allocator.create(StorageAdapter);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .data_dir = owned_dir,
            .engines = std.StringHashMap(*ManagedGraph).init(allocator),
            .default_engine = null,
            .config = config,
            .registry = gs.registry.GraphRegistry.init(allocator),
            .registry_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{owned_dir}),
            .mutex = std.Io.Mutex.init,
            // GAP-0900: checkpoint-cadence observability counters.
            .checkpoints_total = std.atomic.Value(u64).init(0),
            .pending_bulk_ops = std.atomic.Value(u64).init(0),
            // GAP-0900: 0 means "no checkpoint has run yet". The persistence
            // loop and tests pass a monotonic `now`; until the first
            // checkpointAll resets this to a real `monoNanosNow()`, the
            // time-based cadence is measured from process start (clock 0).
            .last_checkpoint_mono_ns = std.atomic.Value(u64).init(0),
        };
        errdefer self.registry.deinit();
        errdefer allocator.free(self.registry_path);

        self.loadRegistry() catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("failed to load graph registry {s}: {}", .{ self.registry_path, err }),
        };

        // LEAN-MERGE-KEY-SEEK (Part 1): re-register the persisted merge-key set
        // BEFORE any graph is opened. Graphs open lazily (openGraphLocked) on
        // first use, and that path rebuilds the exact node-property index from
        // the durable pages, consulting `shouldIndexProperty`. In lean mode
        // (`GEODE_INDEX_MERGE_KEYS_ONLY=1`) that predicate is true only for
        // registered merge keys, so the keys MUST already be registered here or
        // the rebuild skips them and the exact index is left INCOMPLETE for the
        // merge keys after reopen — which would make a completeness-gated seek
        // wrongly return empty for existing nodes. No-op when lean mode is off
        // (everything is always indexed) or when the sidecar is absent.
        graph_store.loadPersistedMergeIndexKeys(self.allocator, self.data_dir);

        // Caveat "B": re-register persisted COMPOSITE merge keys (e.g.
        // {source, source_id}) BEFORE any graph opens, so the per-node load
        // rebuild (`loadOneGraphFromAdapter`) repopulates the resident composite
        // merge entries for the WHOLE graph. The from-dump EDGE phase runs as a
        // separate process from the NODE phase, so without this the edges-only
        // run would find no composite entries and fall back to the slow
        // seed+verify path. No-op when the sidecar is absent (fresh data dir).
        graph_store.loadPersistedCompositeMergeKeys(self.allocator, self.data_dir);

        return self;
    }

    /// Shut down all engines, release every allocation.
    pub fn deinit(self: *StorageAdapter) void {
        // H4 persist-on-build: join in-flight background index persists
        // BEFORE any teardown — the workers take `self.mutex` and read the
        // engines map, so joining after the lock below would deadlock and
        // joining after teardown would be a use-after-free. New spawns are
        // refused from here on (`exact_persist_shutdown`). Bounded: each
        // worker is one bounded-acquire (5 s) graph checkpoint.
        {
            const io_h4 = std.Io.Threaded.global_single_threaded.io();
            self.exact_persist_mutex.lockUncancelable(io_h4);
            self.exact_persist_shutdown = true;
            var persist_threads = self.exact_persist_threads;
            self.exact_persist_threads = .empty;
            self.exact_persist_mutex.unlock(io_h4);
            for (persist_threads.items) |t| t.join();
            persist_threads.deinit(self.allocator);
        }
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());

        var it = self.engines.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator);
        }
        self.engines.deinit();
        self.default_engine = null;

        self.registry.deinit();
        self.allocator.free(self.registry_path);
        self.allocator.free(self.data_dir);
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.allocator.destroy(self);
    }

    /// Copy the names of every currently-OPEN ManagedGraph. Brief mutex hold
    /// (tier-0 lookup only — no data ops under the lock). Names are duped with
    /// `allocator` (intended: an arena — nothing is freed individually). Used
    /// by the raft snapshot-install FTS rebuild to enumerate graphs whose
    /// fulltext indexes need re-backfilling.
    pub fn listOpenGraphNames(self: *StorageAdapter, allocator: Allocator) ![][]const u8 {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const out = try allocator.alloc([]const u8, self.engines.count());
        var it = self.engines.keyIterator();
        var i: usize = 0;
        while (it.next()) |key| : (i += 1) out[i] = try allocator.dupe(u8, key.*);
        return out;
    }

    /// Return the `ManagedGraph` for `name`, creating a new `GraphEngine` if
    /// the graph has not been opened yet.
    pub fn getOrCreateGraph(self: *StorageAdapter, name: []const u8) !*ManagedGraph {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.engines.get(name)) |mg| {
            return mg;
        }

        if (self.findRegistryEntryLocked(name)) |entry| {
            return self.openGraphLocked(name, entry.uuid);
        }

        return self.createGraphLocked(name);
    }

    /// Open an existing graph by name and UUID. Uses `GraphEngine.open()` to
    /// recover the persisted on-disk data directory.
    pub fn openGraphWithUuid(self: *StorageAdapter, name: []const u8, graph_uuid: [16]u8) !*ManagedGraph {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.engines.get(name)) |mg| {
            return mg;
        }

        return self.openGraphLocked(name, graph_uuid);
    }

    /// Return the stored UUID for a loaded graph, or null if not loaded.
    pub fn getGraphUuid(self: *StorageAdapter, name: []const u8) ?[16]u8 {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.engines.get(name)) |mg| {
            return mg.uuid;
        }
        if (self.findRegistryEntryLocked(name)) |entry| {
            return entry.uuid;
        }
        return null;
    }

    /// Return the per-graph audit logger for `name`, or null if the graph
    /// does not exist or audit was not initialised.  Holds `self.mutex`
    /// only for the hash-map lookup.
    pub fn getAuditLogger(self: *StorageAdapter, name: []const u8) ?*audit.AuditLogger {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(name);
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        return if (mg) |m| m.audit_logger else null;
    }

    /// Return the per-graph timeseries store for `name`, or null if the graph
    /// does not exist or timeseries was not initialised.  Holds `self.mutex`
    /// only for the hash-map lookup.
    pub fn getTimeseriesStore(self: *StorageAdapter, name: []const u8) ?*ts_mod.Store {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(name);
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        return if (mg) |m| m.ts_store else null;
    }

    /// Return the per-graph full-text search index for `name`, or null if the
    /// graph does not exist or FTS was not initialised.  Holds `self.mutex`
    /// only for the hash-map lookup.
    pub fn getFulltextIndex(self: *StorageAdapter, name: []const u8) ?*fulltext.FullTextIndex {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(name);
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        return if (mg) |m| m.fts_index else null;
    }

    /// A4a: resolve a NAMED fulltext index facade for graph `graph_name` /
    /// index `index_name`. Distinct from `getFulltextIndex`, whose `name`
    /// parameter is the GRAPH name (it returns that graph's single "default"
    /// facade). This is the resolver the `fulltext_search(...)` query function
    /// uses. Returns null if the graph does not exist, FTS is uninitialised, or
    /// no engine named `index_name` exists. Holds `self.mutex` only for the
    /// graph-map lookup; facade construction happens after release.
    pub fn getFulltextIndexNamed(self: *StorageAdapter, graph_name: []const u8, index_name: []const u8) ?*fulltext.FullTextIndex {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(graph_name);
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const m = mg orelse return null;
        return m.getFulltextIndexNamed(self.allocator, index_name);
    }

    /// Check whether a graph with the given name exists either in memory or in
    /// the persisted registry.
    pub fn graphExists(self: *StorageAdapter, name: []const u8) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        return self.engines.contains(name) or self.findRegistryEntryLocked(name) != null;
    }

    /// Close and remove the graph identified by `name`.
    pub fn dropGraph(self: *StorageAdapter, name: []const u8) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        var dropped_uuid: ?[16]u8 = null;
        if (self.engines.fetchRemove(name)) |kv| {
            const mg = kv.value;

            // Clear default_engine if it pointed to the dropped graph.
            if (self.default_engine == mg) {
                self.default_engine = null;
            }

            dropped_uuid = mg.uuid;
            mg.deinit(self.allocator);
        } else if (self.findRegistryEntryLocked(name)) |entry| {
            dropped_uuid = entry.uuid;
        }

        if (self.registry.removeGraph(name)) {
            self.saveRegistryLocked() catch |err| {
                log.warn("failed to persist graph registry after drop of '{s}': {}", .{ name, err });
            };
        }

        if (dropped_uuid) |graph_uuid| {
            // Best-effort delete the legacy single-engine layout (if a prior
            // build wrote `<data_dir>/graphs/<uuid>/` alongside the now
            // collocated layout).  Errors are non-fatal — the dir may not
            // exist on builds that have always used the consolidated layout.
            if (gs.graph_dir.GraphDir.open(self.allocator, self.data_dir, graph_uuid)) |opened| {
                var graph_dir = opened;
                defer graph_dir.deinit();
                graph_dir.delete() catch |err| {
                    log.warn("failed to delete legacy graph directory for '{s}': {}", .{ name, err });
                };
            } else |_| {}

            // Delete the consolidated artifact + sharded-engine root at
            // `<data_dir>/<uuid_hex>` (matches `graphDirPath` and the
            // sharded engine's `graph_root`).  Pre-engine-deinit calls
            // above closed every per-shard mmap; safe to recursive-delete.
            const consolidated = graphDirPath(self.allocator, self.data_dir, graph_uuid) catch null;
            if (consolidated) |path| {
                defer self.allocator.free(path);
                const dt_io = std.Io.Threaded.global_single_threaded.io();
                // `deleteTree` is a no-op on a missing root, so we don't
                // need to special-case FileNotFound — any other error is
                // logged but non-fatal so callers continue to see the
                // graph removed from the registry.
                std.Io.Dir.cwd().deleteTree(dt_io, path) catch |err| {
                    log.warn("failed to delete consolidated graph directory for '{s}': {}", .{ name, err });
                };
            }
        }
    }

    /// Return the names of all known graphs. Caller owns the returned slice and
    /// each name string inside it.
    pub fn listGraphNames(self: *StorageAdapter, allocator: Allocator) ![][]const u8 {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |name| allocator.free(name);
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

        for (self.registry.entries.items) |entry| {
            const seen_key = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(seen_key);
            const seen_result = try seen.getOrPut(seen_key);
            if (!seen_result.found_existing) {
                try names.append(allocator, try allocator.dupe(u8, entry.name));
            } else {
                allocator.free(seen_key);
            }
        }

        var it = self.engines.iterator();
        while (it.next()) |entry| {
            const seen_key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(seen_key);
            const seen_result = try seen.getOrPut(seen_key);
            if (!seen_result.found_existing) {
                try names.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
            } else {
                allocator.free(seen_key);
            }
        }

        return names.toOwnedSlice(allocator);
    }

    /// Return the default graph, creating one named "default" if none exists.
    pub fn getDefaultGraph(self: *StorageAdapter) !*ManagedGraph {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.default_engine) |mg| {
            return mg;
        }

        const mg = if (self.engines.get("default")) |existing|
            existing
        else if (self.findRegistryEntryLocked("default")) |entry|
            try self.openGraphLocked("default", entry.uuid)
        else
            try self.createGraphLocked("default");

        self.default_engine = mg;
        return mg;
    }

    // ------------------------------------------------------------------
    // Node CRUD
    // ------------------------------------------------------------------

    /// Create a node with the given string labels in the named graph.
    /// The graph is created on-demand if it does not exist. Returns the
    /// new node ID.
    pub fn createNode(self: *StorageAdapter, graph_name: []const u8, labels: []const []const u8) !u64 {
        // OTel Task 12: record write_node op duration + outcome.
        const _om12 = @import("otel_metrics");
        const _t0_12 = @import("otel").internal.clock.unixNanoNow();
        var _ok_12 = false;
        defer {
            const _dur: f64 = @as(f64, @floatFromInt(@import("otel").internal.clock.unixNanoNow() -% _t0_12)) / @as(f64, std.time.ns_per_s);
            _om12.recordStorageOp(.write_node, _dur, if (_ok_12) .success else .error_, null);
        }
        const mg = try self.getOrCreateGraph(graph_name);

        // R7 (2026-04-22): batch every sub-op (putNode + per-label addLabel)
        // into a SINGLE storage-engine transaction so we incur exactly one
        // WAL fsync per CREATE, not one per sub-op.
        //
        // R8 (2026-04-22): if the current thread already has an open
        // `StatementTxn` on this graph, JOIN it instead of opening a fresh
        // txn — the whole GQL statement (createNode + N setNodeProperty)
        // will then commit with one fsync instead of N+1.
        //
        // The engine's auto-commit variants (putNode, addLabel,
        // putProperty) each call `txn_manager.begin()` + `commit()`, and
        // `commit()` always ends with `wal.sync()` (fsync) — see
        // `graph_storage/src/txn.zig:67-85`.
        const node_id = try mg.engine.allocNode();
        const node_shard = mg.shardEngineForNode(node_id);

        // R7/R8 (2026-04-22): batch putNode + addLabel into a single per-shard
        // txn.  Under ShardedGraphEngine, each txn is pinned to one shard; we
        // always route to the shard that owns node_id.  If a statement txn is
        // active on this graph AND was opened on the same shard, reuse its
        // local txn (one fsync for the whole statement).  Otherwise open a
        // fresh local txn on node_shard (correct isolation, one fsync per
        // createNode call instead of per sub-op).
        const stmt_txn = currentStatementTxnForGraph(graph_name);
        const local_txn: gs.TxnId = if (stmt_txn) |s|
            shardLocalTxnForNode(s.txn_id, node_id) orelse try node_shard.beginTxn()
        else
            try node_shard.beginTxn();
        const own_txn = stmt_txn == null or shardLocalTxnForNode(stmt_txn.?.txn_id, node_id) == null;
        errdefer if (own_txn) {
            // error-policy: A — best-effort rollback on an already-failing path.
            node_shard.abortTxn(local_txn) catch {};
        };

        // Write an initial node record.  The txn_stamp must be non-zero so
        // that getNode() does not treat the slot as empty (isEmpty checks all
        // fields == 0).  Using 1 as a sentinel "created" stamp.
        const rec = gs.node.NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        };
        try node_shard.putNodeTxn(node_id, rec, local_txn);

        // Attach each label via the engine (updates label blocks in var.store
        // and the label index).
        for (labels) |lbl| {
            const label_id = try resolvePersistedLabelId(mg, lbl);
            try node_shard.addLabelTxn(node_id, label_id, local_txn);
        }
        // gap 0026: WAL-log the node's REAL label page (see
        // relogSecurityLabelPageTxn) — no-op outside __geode_security.
        try relogSecurityLabelPageTxn(mg, node_shard, node_id, local_txn);

        if (own_txn) try node_shard.commitTxn(local_txn);
        _ok_12 = true;
        // OTel Task 13: graph data model mutation counter.
        _om12.recordNodeMutation(.create, graph_name, .success);
        return node_id;
    }

    /// Single-node "bulk-ingest" fast path (Task 11 of the enterprise-ingest-
    /// throughput plan).  Creates one node with `labels` and `props` in
    /// `graph_name`, returning the allocated slot's public node id.
    ///
    /// Used by the QUIC handler's fast-path dispatch for the msft-graph hot
    /// pattern `CREATE (n:Label {k: literal_or_param, ...})` (Tasks 10 + 11).
    /// Bypasses the full executor's AST traversal, row materialization, and
    /// RLS filter.  Caller is responsible for having already verified the
    /// pattern via `bulk_ingest.matchSingleStatement`.
    ///
    /// Transaction semantics:
    ///   * Joins the active session / statement engine txn (R8 / R9) via the
    ///     thread-local `t_current_statement_txn` / `t_session_engine_txn`
    ///     slots, exactly like `createNode` does.  When no statement txn is
    ///     open, opens one for the duration of this call.
    ///   * The `txn_id_opt` parameter is accepted for interface parity with
    ///     future bulk-edge / bulk-batch variants; when provided, callers
    ///     must have registered the txn id via `beginStatementTxn`
    ///     beforehand (the adapter still consults the thread-locals).
    ///
    /// Undo-log contract:
    ///   The caller MUST NOT be inside a rollback-able Geode transaction
    ///   when invoking `bulkInsertNode` — this method SKIPS the
    ///   `txn_undo_log.logCreateNode` append that `executeCreate` performs
    ///   on every CREATE statement.  That is the primary performance lever
    ///   of the bulk path (GEODE_BULK_INGEST=1 is opt-in for exactly this
    ///   reason).  Under the bulk env var, rollbacks of individual
    ///   statements are not supported; the operator is expected to either
    ///   commit the whole batch or nuke the target data directory.
    ///
    /// In-memory store consistency:
    ///   Routes through `GraphStore.createNodeWithGraph` + `setNodeProperty`
    ///   so the in-memory node map, label index, and merge-property index
    ///   stay in sync with the persistent engine state.  Reads that land
    ///   against the in-memory snapshot therefore see the newly inserted
    ///   node without waiting for a persistence flush.
    pub fn bulkInsertNode(
        self: *StorageAdapter,
        graph_name: []const u8,
        labels: []const []const u8,
        props: []const PropKV,
        txn_id_opt: ?u64,
    ) !u64 {
        _ = txn_id_opt; // reserved for future extensions; thread-local is source of truth.

        // Match the executor's R8/R9 fsync batching: if a session or
        // per-statement engine txn is already active on this thread for
        // `graph_name`, the adapter's `createNode` / `setNodeProperty`
        // will join it automatically.  Otherwise, open a per-statement
        // txn so the createNode + N×setNodeProperty sub-ops commit with
        // ONE WAL fsync instead of N+1.  Without this step the bulk
        // path regresses vs `executeCreate` because each sub-op would
        // open its own auto-commit engine txn.
        var stmt_txn: StatementTxn = undefined;
        var stmt_txn_open = false;
        const session_covers = if (sessionEngineTxnGraph()) |g|
            std.mem.eql(u8, g, graph_name)
        else
            false;
        if (!session_covers and t_current_statement_txn == null) {
            self.ensureGraphExistsForBulk(graph_name) catch |err| switch (err) {
                // Graph might not exist yet — fall through to per-sub-op
                // auto-commit; `createNode` lazily creates the graph.
                error.GraphNotFound => {},
                else => return err,
            };
            if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| {
                stmt_txn_open = true;
            } else |err| switch (err) {
                error.GraphNotFound, error.NestedStatementTxn => {},
                else => return err,
            }
        }
        errdefer if (stmt_txn_open) stmt_txn.abort();

        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const node_id = try store.createNodeWithGraph(labels, graph_name);

        // Task #33 (2026-04-24): route N properties through
        // `setNodePropertiesBatch` instead of calling `setNodeProperty` in
        // a loop.  The batch path (graph_store.zig:2058,
        // graph_storage_adapter.zig:2011) acquires the adapter mutex once,
        // allocates `label_ids` once, joins the active StatementTxn
        // (parity added in the same commit), and writes the node record
        // once after all property mutations instead of N times.  Under
        // the msft-graph 16-way parallel seed, the loop version spent
        // ~4 ms/property × 10-23 props/node on per-call overhead (label
        // lookup, N × putNodeTxn, N × adapter vtable dispatch).  The
        // batch version collapses that to one adapter call per node.
        //
        // For props.len == 0 we must still create the node — the caller
        // relies on `bulkInsertNode` returning a valid node_id for label-
        // only nodes.  Skip the batch call in that case.
        if (props.len > 0) {
            var entries_buf: [16]graph_store.GraphStore.BatchPropertyEntry = undefined;
            const entries: []graph_store.GraphStore.BatchPropertyEntry = if (props.len <= entries_buf.len)
                entries_buf[0..props.len]
            else
                try self.allocator.alloc(graph_store.GraphStore.BatchPropertyEntry, props.len);
            defer if (props.len > entries_buf.len) self.allocator.free(entries);

            for (props, 0..) |kv, i| {
                entries[i] = .{ .key = kv.key, .value = kv.value };
            }
            try store.setNodePropertiesBatch(node_id, entries);
        }

        if (stmt_txn_open) try stmt_txn.commit();
        return node_id;
    }

    /// Helper for `bulkInsertNode`: ensure the graph engine is registered
    /// before we call `beginStatementTxn` (which requires an existing
    /// graph and returns GraphNotFound otherwise).  Returns
    /// `GraphNotFound` only if `getOrCreateGraph` fails — in the normal
    /// case it populates the engines map and returns successfully.
    fn ensureGraphExistsForBulk(self: *StorageAdapter, graph_name: []const u8) !void {
        _ = try self.getOrCreateGraph(graph_name);
    }

    /// Phase 2 variant of `bulkInsertNode` that consumes a
    /// pre-allocated id (via `GraphStore.reserveNodeId`) and
    /// self-locks under the shard-locked write protocol:
    ///
    ///   1. Take `mg.rwlock` SHARED (fences whole-graph-exclusive
    ///      ops like RESTORE).
    ///   2. Take `shard_locks[shardIndex(reserved_id)]` EXCLUSIVE
    ///      (serialises writes to this shard's state).
    ///   3. Allocate the storage-engine slot from the same shard worker,
    ///      attach labels and the hidden public-id property in the active
    ///      shard statement txn, then register the public-id→slot mapping.
    ///   4. Write properties via `setNodePropertiesBatch` under the shard
    ///      lock only.
    ///
    /// Called by `ShardedCoordinator.applyShardBatch` in Task 6.
    /// Does NOT open a statement txn on its own — the coordinator
    /// wraps the whole batch in one statement txn for WAL fsync
    /// amortisation across every op in the shard batch.
    ///
    /// Same undo-log + in-memory-store contracts as `bulkInsertNode`.
    pub fn bulkInsertNodeWithReservedId(
        self: *StorageAdapter,
        graph_name: []const u8,
        reserved_id: u64,
        labels: []const []const u8,
        props: []const PropKV,
    ) !u64 {
        // GAP-0891 (RC-1): contextless/inline callers resolve the tenant from
        // the active ExecutionContext (or the per-thread map / "default"). The
        // group-commit worker path uses the *ForTenant variant with the tenant
        // captured on the handler thread at submit time (the worker thread has
        // neither a context nor a per-thread tenant).
        const id = try self.bulkInsertNodeWithReservedIdForTenant(
            graph_name,
            reserved_id,
            labels,
            props,
            fle_integration.tenantPreferringActiveContext(),
        );
        // GAP-0900: safe to checkpoint here — the ForTenant call has returned,
        // so its per-graph SHARED rwlock + shard locks are released.
        self.maybeCheckpointInline();
        return id;
    }

    // GAP-0891 (RC-1): tenant-threaded variant of bulkInsertNodeWithReservedId.
    pub fn bulkInsertNodeWithReservedIdForTenant(
        self: *StorageAdapter,
        graph_name: []const u8,
        reserved_id: u64,
        labels: []const []const u8,
        props: []const PropKV,
        request_tenant: []const u8,
    ) !u64 {
        const mg = try self.getOrCreateGraph(graph_name);
        // H4: a live write must never mutate an unbuilt (deferred) exact index.
        // Build it FIRST (before any node/index write below) so this insert's
        // posting lands on top of the fully-rebuilt index. No-op (one atomic
        // load) on a freshly-created or already-built graph — the ingest case.
        try ensureExactNodePropertyIndexBuilt(self, mg);
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const io = std.Io.Threaded.global_single_threaded.io();

        // Hold-time instrumentation pattern. Three shapes appear in this file:
        //   1. defer-after-defer (canonical) — see below; LIFO unwind runs the
        //      hold-measure BEFORE the unlock so the held duration is captured
        //      to the moment of release.
        //   2. inline before explicit unlockShared — used inside checkpointAll's
        //      for-loops (~lines 2881, 2914) where the unlock is not a defer.
        //   3. cross-function via ReadLockAcquisition.hold_start_ns — used by
        //      acquireGraphReadLock / releaseGraphReadLock (line ~3552) where
        //      the lock crosses a function boundary; timestamp is plumbed back
        //      via the returned struct (or GraphLockHandle.hold_start_ns at
        //      higher layers).
        // All three measure: release_ts - acquire_ts, monotonic-ns, saturating.
        exclusiveWaitingBackoff(mg); // GAP-0900 / edge-40001: yield to a pending exclusive (checkpoint or edge schema/MERGE).
        const _t_start = monoNanosNow();
        mg.rwlock.lockSharedUncancelable(io);
        _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
        _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
        defer mg.rwlock.unlockShared(io);
        const _hold_start = monoNanosNow();
        defer {
            const _hold_ns = monoNanosNow() -| _hold_start;
            _ = mg.rwlock_shared_hold_ns_total.fetchAdd(_hold_ns, .monotonic);
            const _cur_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
            if (_hold_ns > _cur_max) {
                mg.rwlock_shared_max_hold_ns_observed.store(_hold_ns, .monotonic);
            }
        }

        const idx = sharded_store.shardIndex(reserved_id);
        mg.shard_locks[idx].lockUncancelable(io);
        defer mg.shard_locks[idx].unlock(io);

        const node_shard = mg.engine.shards[idx];

        // REQ-QUIC-HC-016: allocate the dense engine slot from the same
        // shard the coordinator selected for the public id. The previous path
        // called GraphStore.createNodeWithReservedIdAndGraph(), which
        // re-entered adapter.createNode() and round-robined a new engine slot
        // that often belonged to another shard; property writes then missed
        // the shard-pinned statement txn and committed one-by-one.
        //
        // Keep `mg.string_indexes_mutex` out of the page/WAL work below. It
        // only protects string-keyed metadata maps (label dictionary and
        // GraphStore indexes), so holding it while doing putNode/putProperty
        // serializes otherwise-independent shard workers.
        const slot_id = try node_shard.allocNode();
        const stmt_txn = currentStatementTxnForGraph(graph_name);
        const stmt_local: ?gs.TxnId = if (stmt_txn) |s|
            shardLocalTxnForNode(s.txn_id, slot_id)
        else
            null;
        const local_txn: gs.TxnId = stmt_local orelse try node_shard.beginTxn();
        const own_txn = stmt_local == null;
        errdefer if (own_txn) {
            // error-policy: A — best-effort rollback on an already-failing path.
            node_shard.abortTxn(local_txn) catch {};
        };

        var rec = gs.node.NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        };
        try node_shard.putNodeTxn(slot_id, rec, local_txn);

        var label_ids_buf: [16]gs.LabelId = undefined;
        const label_ids: []gs.LabelId = if (labels.len <= label_ids_buf.len)
            label_ids_buf[0..labels.len]
        else
            try self.allocator.alloc(gs.LabelId, labels.len);
        defer if (labels.len > label_ids_buf.len) self.allocator.free(label_ids);

        {
            mg.string_indexes_mutex.lockUncancelable(io);
            defer mg.string_indexes_mutex.unlock(io);
            for (labels, 0..) |lbl, i| {
                label_ids[i] = try resolvePersistedLabelId(mg, lbl);
            }
        }

        for (label_ids) |label_id| {
            try node_shard.addLabelTxn(slot_id, label_id, local_txn);
        }
        // gap 0026: WAL-log the node's REAL label page (see
        // relogSecurityLabelPageTxn) — no-op outside __geode_security.
        try relogSecurityLabelPageTxn(mg, node_shard, slot_id, local_txn);

        rec = (try node_shard.getNode(slot_id)) orelse return error.NodeNotFound;
        var id_buf: [16]u8 = undefined;
        // error-policy: D — "{x:0>16}" of a u64 is exactly 16 bytes; id_buf is [16]u8.
        const id_text = std.fmt.bufPrint(&id_buf, "{x:0>16}", .{reserved_id}) catch unreachable;
        const prop_head = try node_shard.putPropertyTxn(
            rec.prop_head,
            graph_store.INTERNAL_NODE_ID_PROPERTY_KEY,
            .{ .string = id_text },
            local_txn,
        );
        rec.prop_head = prop_head;
        try node_shard.putNodeTxn(slot_id, rec, local_txn);

        // GAP-0891 (RC-2): persist the tenant tag in the SAME shard-pinned txn
        // so bulk-created nodes round-trip their tenant across restart. The
        // slot-direct bulk path bypasses the GraphStore-level
        // persistNodeTenantId, so it must mirror the internal-id write here.
        // No-op for default (absent-on-read means default — zero write
        // amplification for single-tenant ingest).
        if (!std.mem.eql(u8, request_tenant, graph_store.DEFAULT_TENANT_ID)) {
            const tenant_prop_head = try node_shard.putPropertyTxn(
                rec.prop_head,
                graph_store.INTERNAL_TENANT_ID_PROPERTY_KEY,
                .{ .string = request_tenant },
                local_txn,
            );
            rec.prop_head = tenant_prop_head;
            try node_shard.putNodeTxn(slot_id, rec, local_txn);
        }

        // CANARY: REQ=REQ-QUIC-HC-022; FEATURE="HighConcurrencyMutations"; ASPECT=ShardTxnPropertyFastPath; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=storage; UPDATED=2026-05-26
        //
        // Property writes touch the already-created node and, because the
        // slot_id was allocated from `idx`, can stay inside the same
        // shard-pinned statement txn opened by the coordinator. Do the
        // storage/index writes directly here instead of routing back through
        // GraphStore.setNodePropertiesBatch, which would re-enter the adapter
        // graph lookup mutex and redo shard routing for every bulk CREATE.
        if (props.len > 0) {
            for (props) |kv| {
                const storage_val = try toStorageProperty(self.allocator, kv.value);
                defer freeTemporaryStorageProperty(self.allocator, storage_val);
                const new_prop_head = try node_shard.putPropertyTxn(rec.prop_head, kv.key, storage_val, local_txn);
                rec.prop_head = new_prop_head;
                for (label_ids) |label_id| {
                    // GAP-0900 throughput: bulk insert reserves a FRESH slot_id
                    // that has never been indexed → skip the O(N) de-dup scan.
                    try addIndexedNodePropertyEx(mg, label_id, slot_id, kv.key, storage_val, true);
                }
            }
            try node_shard.putNodeTxn(slot_id, rec, local_txn);
        }

        {
            mg.string_indexes_mutex.lockUncancelable(io);
            defer mg.string_indexes_mutex.unlock(io);
            try store.createNodeWithReservedIdAndSlotGraphAndTenant(reserved_id, slot_id, labels, graph_name, request_tenant);
        }
        if (own_txn) try node_shard.commitTxn(local_txn);

        if (props.len > 0) {
            var entries_buf: [16]graph_store.GraphStore.BatchPropertyEntry = undefined;
            const entries: []graph_store.GraphStore.BatchPropertyEntry = if (props.len <= entries_buf.len)
                entries_buf[0..props.len]
            else
                try self.allocator.alloc(graph_store.GraphStore.BatchPropertyEntry, props.len);
            defer if (props.len > entries_buf.len) self.allocator.free(entries);

            for (props, 0..) |kv, i| {
                entries[i] = .{ .key = kv.key, .value = kv.value };
            }
            try store.setNodePropertiesBatchInMemoryOnly(reserved_id, entries);
        }
        // GAP-0900: feed the checkpoint-cadence signal. The group-commit bulk
        // fast path bypasses notifyMutation / GraphStore.dirty, so without this
        // the checkpoint cadence never sees bulk-ingest pressure and never fires
        // in deferred mode → unbounded WAL/RSS growth. The actual inline
        // checkpoint trigger (maybeCheckpointInline) is invoked by the CALLER
        // once it has released the per-graph SHARED rwlock + shard locks held
        // here — checkpointAll needs the EXCLUSIVE rwlock, so triggering it
        // while these locks are held would self-deadlock.
        _ = self.pending_bulk_ops.fetchAdd(1, .monotonic);
        return reserved_id;
    }

    /// Phase 2 shard-locked edge-insert variant.  Both endpoint ids
    /// are known to the caller, so the helper routes writes to the
    /// owning shards for source and target.
    ///
    /// Locking protocol:
    ///   1. Take `mg.rwlock` SHARED.
    ///   2. If `shardIndex(source_id) == shardIndex(target_id)`,
    ///      take that one shard's EXCLUSIVE lock.
    ///   3. Otherwise, take the lower-index shard's EXCLUSIVE lock
    ///      first, then the higher-index shard's — ascending order
    ///      to prevent deadlock with any other cross-shard op.
    ///   4. Take `mg.string_indexes_mutex` briefly for the
    ///      edge_type_index getOrPut inside `createEdgeWithGraph`.
    ///   5. Write properties via `setEdgeProperty` under the shard
    ///      locks.
    ///
    /// Race handling: re-checks source/target existence under the
    /// held locks and surfaces `SourceNodeNotFound` / `TargetNodeNotFound`
    /// if either was deleted in a prior batch.  Matches the
    /// `bulkInsertEdgeWithIds` semantics so the coordinator's
    /// orphan-edge silent-skip path still works.
    pub fn bulkInsertEdgeWithIdsShardLocked(
        self: *StorageAdapter,
        graph_name: []const u8,
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
    ) !u64 {
        // GAP-0891 (RC-1): see bulkInsertNodeWithReservedId — inline callers
        // resolve via context; the group-commit worker uses the *ForTenant
        // variant with the captured request tenant.
        return self.bulkInsertEdgeWithIdsShardLockedForTenant(
            graph_name,
            source_id,
            target_id,
            rel_type,
            props,
            fle_integration.tenantPreferringActiveContext(),
        );
    }

    // GAP-0891 (RC-1): tenant-threaded variant of bulkInsertEdgeWithIdsShardLocked.
    pub fn bulkInsertEdgeWithIdsShardLockedForTenant(
        self: *StorageAdapter,
        graph_name: []const u8,
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
        request_tenant: []const u8,
    ) !u64 {
        const mg = try self.getOrCreateGraph(graph_name);
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const io = std.Io.Threaded.global_single_threaded.io();

        // Edge co-location (Phase A): the engine edge write is now SINGLE-shard
        // on shard(source) — out-adjacency, edge body, edge_index, existence
        // index AND the incoming adjacency (engine adj_in_remote keyed by target)
        // all live on the source shard, with no cross-shard 2PC. So only the
        // SOURCE shard lock is needed; the old ascending two-lock dance for a
        // cross-shard target is gone (there is no dst-shard write to protect).
        const src_shard = sharded_store.shardIndex(source_id);

        exclusiveWaitingBackoff(mg); // GAP-0900 / edge-40001: yield to a pending exclusive (checkpoint or edge schema/MERGE).
        const _t_start = monoNanosNow();
        mg.rwlock.lockSharedUncancelable(io);
        _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
        _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
        defer mg.rwlock.unlockShared(io);
        const _hold_start = monoNanosNow();
        defer {
            const _hold_ns = monoNanosNow() -| _hold_start;
            _ = mg.rwlock_shared_hold_ns_total.fetchAdd(_hold_ns, .monotonic);
            const _cur_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
            if (_hold_ns > _cur_max) {
                mg.rwlock_shared_max_hold_ns_observed.store(_hold_ns, .monotonic);
            }
        }

        mg.shard_locks[src_shard].lockUncancelable(io);
        defer mg.shard_locks[src_shard].unlock(io);
        return self.bulkInsertEdgeInnerShardLocked(mg, store, graph_name, source_id, target_id, rel_type, props, request_tenant);
    }

    fn bulkInsertEdgeInnerShardLocked(
        self: *StorageAdapter,
        mg: *ManagedGraph,
        store: *graph_store.GraphStore,
        graph_name: []const u8,
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
        request_tenant: []const u8,
    ) !u64 {
        const io = std.Io.Threaded.global_single_threaded.io();

        // Eviction-INDEPENDENT endpoint existence (see bulkMergeEdgeInnerShardLocked
        // and GraphStore.edgeEndpointExists): the bounded node cache would
        // orphan-skip a present-but-EVICTED endpoint and silently drop the edge.
        if (!store.edgeEndpointExists(graph_name, source_id)) return error.SourceNodeNotFound;
        if (!store.edgeEndpointExists(graph_name, target_id)) return error.TargetNodeNotFound;

        mg.string_indexes_mutex.lockUncancelable(io);
        // GAP-0891 (RC-1): tag the edge with the captured request tenant.
        const create_result = store.createEdgeForRequestTenant(source_id, target_id, rel_type, graph_name, request_tenant);
        mg.string_indexes_mutex.unlock(io);
        const edge_id = try create_result;

        // Task #34 (2026-04-24): route N properties through the batch
        // helper — same motivation as the change in `bulkInsertEdgeWithIds`
        // above.  See that comment for details.
        if (props.len > 0) {
            var entries_buf: [16]graph_store.GraphStore.BatchPropertyEntry = undefined;
            const entries: []graph_store.GraphStore.BatchPropertyEntry = if (props.len <= entries_buf.len)
                entries_buf[0..props.len]
            else
                try self.allocator.alloc(graph_store.GraphStore.BatchPropertyEntry, props.len);
            defer if (props.len > entries_buf.len) self.allocator.free(entries);

            for (props, 0..) |kv, i| {
                entries[i] = .{ .key = kv.key, .value = kv.value };
            }
            try store.setEdgePropertiesBatch(edge_id, entries);
        }
        // GAP-0900: feed the checkpoint-cadence signal for bulk edge writes too
        // — like the node bulk path, this bypasses notifyMutation / dirty.
        _ = self.pending_bulk_ops.fetchAdd(1, .monotonic);
        return edge_id;
    }

    /// FIX #3 (edge-phase 40001): shard-locked relationship MERGE.
    ///
    /// The GQL `MATCH (a {k}),(b {k}) MERGE (a)-[:R]->(b)` the from-dump edge
    /// phase emits previously fell through to the regular executor's WHOLE-GRAPH
    /// EXCLUSIVE write lock (it is a MERGE with a post-SET and composite-key
    /// endpoints, so it is rejected by the CREATE-edge fast path detector). At
    /// 14.27M scale under concurrent analytical reads (which hold the graph
    /// rwlock SHARED) that exclusive acquire is starved → `40001`.
    ///
    /// This is the MERGE counterpart of `bulkInsertEdgeWithIdsShardLocked`: it
    /// takes the graph rwlock SHARED + the two endpoint shards' EXCLUSIVE locks
    /// (ascending index, single lock when co-resident) — so it COEXISTS with
    /// readers instead of being starved by them — and, under those locks, DEDUPS
    /// the relationship (MERGE semantics) before creating it. Endpoints are
    /// resolved-by-id by the caller (the fast path resolves them by index under
    /// a brief read lock first).
    ///
    /// Returns the existing edge id when an (source→target, type, scope) edge
    /// already exists, else the newly-created edge id. `SourceNodeNotFound` /
    /// `TargetNodeNotFound` if either endpoint vanished (orphan skip, same as
    /// the insert path).
    pub fn bulkMergeEdgeWithIdsShardLocked(
        self: *StorageAdapter,
        graph_name: []const u8,
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
    ) !u64 {
        return self.bulkMergeEdgeWithIdsShardLockedForTenant(
            graph_name,
            source_id,
            target_id,
            rel_type,
            props,
            fle_integration.tenantPreferringActiveContext(),
        );
    }

    pub fn bulkMergeEdgeWithIdsShardLockedForTenant(
        self: *StorageAdapter,
        graph_name: []const u8,
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
        request_tenant: []const u8,
    ) !u64 {
        const mg = try self.getOrCreateGraph(graph_name);
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const io = std.Io.Threaded.global_single_threaded.io();

        // Edge co-location (Phase A): single SOURCE-shard lock only. The engine
        // edge write (incl. the incoming adjacency, now in shard(source)'s
        // adj_in_remote keyed by target) is single-shard, so the old ascending
        // two-lock acquire for a cross-shard target is unnecessary. The O(1)
        // existence-index dedup probe in the inner already runs on the source
        // shard held EXCLUSIVE here, so two racing same-tuple MERGEs still
        // serialize and cannot both miss-then-create (no duplicate edge).
        const src_shard = sharded_store.shardIndex(source_id);

        exclusiveWaitingBackoff(mg);
        const _t_start = monoNanosNow();
        mg.rwlock.lockSharedUncancelable(io);
        _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
        _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
        defer mg.rwlock.unlockShared(io);
        const _hold_start = monoNanosNow();
        defer {
            const _hold_ns = monoNanosNow() -| _hold_start;
            _ = mg.rwlock_shared_hold_ns_total.fetchAdd(_hold_ns, .monotonic);
            _ = mg.rwlock_shared_hold_bulk_edge_ns_total.fetchAdd(_hold_ns, .monotonic);
            const _cur_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
            if (_hold_ns > _cur_max) {
                mg.rwlock_shared_max_hold_ns_observed.store(_hold_ns, .monotonic);
            }
        }

        mg.shard_locks[src_shard].lockUncancelable(io);
        defer mg.shard_locks[src_shard].unlock(io);
        return self.bulkMergeEdgeInnerShardLocked(mg, store, graph_name, source_id, target_id, rel_type, props, request_tenant);
    }

    fn bulkMergeEdgeInnerShardLocked(
        self: *StorageAdapter,
        mg: *ManagedGraph,
        store: *graph_store.GraphStore,
        graph_name: []const u8,
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
        request_tenant: []const u8,
    ) !u64 {
        // Re-check endpoint existence under the shard locks (orphan skip if a
        // prior batch deleted one — same as the insert inner). Use the
        // eviction-INDEPENDENT IdMap oracle, NOT the bounded node cache: under a
        // small cache at scale a present-but-EVICTED endpoint misses
        // `store.nodes.getPtr` and would be wrongly orphan-skipped, silently
        // dropping the edge (the itis from-dump "~2% observable" bug). The
        // create path below already resolves endpoints via the IdMap, so this
        // makes the guard agree with what the create will actually accept.
        if (!store.edgeEndpointExists(graph_name, source_id)) return error.SourceNodeNotFound;
        if (!store.edgeEndpointExists(graph_name, target_id)) return error.TargetNodeNotFound;

        // PHASE 3 (edge-engine-direct): O(1) MERGE dedup via the engine
        // edge-EXISTENCE index instead of the O(out-degree) resident adjacency
        // scan (which Phase 1 also burdened with a per-edge body hydrate). The
        // engine index is keyed on (from_slot, rel_type, to_slot) and lives on
        // the SOURCE shard — held EXCLUSIVE here — so a concurrent same-source
        // MERGE cannot insert between this probe and the create below: two racing
        // MERGEs of the same (src,dst,type) cannot both miss-then-create (no
        // duplicate edge). The probe narrows the candidates from ALL of the
        // parent's out-edges to JUST the edges with this exact tuple (≈1), then
        // the SAME scope/tenant predicates + idempotent prop-upsert run on the
        // tested public-id path — preserving EXACT MERGE semantics, multi-tenant
        // same-tuple included.
        //
        // `source_id`/`target_id` are geode PUBLIC node ids; the engine indexes
        // on dense engine SLOTS, so translate via the per-graph IdMap first. A
        // missing slot mapping means the node has no engine presence → no edge to
        // dedup against → fall through to create (which re-checks and errors).
        // `rel_type` is a geode label string; the engine keys on its u32 LabelId.
        // An unseen label has NO edges of that type → straight to create. We hold
        // the graph rwlock (SHARED) + shard locks, so we reach the per-shard
        // engine + IdMap DIRECTLY and must NOT re-enter the tier-0 self.mutex
        // (GAP-0278 lock order) via the adapter's graph-scoped getEdgeProperty/
        // getEdgeRecordBySlot wrappers.
        probe: {
            const id_map = store.getIdMap(graph_name) orelse break :probe;
            const from_slot = id_map.nodeSlot(@as(u128, source_id)) orelse break :probe;
            const to_slot = id_map.nodeSlot(@as(u128, target_id)) orelse break :probe;
            const rel_label_id = mg.label_dict.getId(rel_type) orelse break :probe;

            const src_engine = mg.shardEngineForNode(from_slot);
            var probe_buf: [16]u64 = undefined;
            const candidate_slots = try src_engine.probeEdge(from_slot, rel_label_id, to_slot, &probe_buf);
            for (candidate_slots) |edge_slot| {
                // Engine slot -> geode PUBLIC edge id (the id space the dedup
                // match/return + prop-upsert operate in). GAP-ENT-0024
                // inline-first: the edge_index entry carries the public id for
                // v2 edges (O(1), no props-page read); legacy edges
                // (public_id == 0) fall back to the persisted property, read
                // directly off the source-shard engine (no self.mutex). A slot
                // with neither is an orphan / not-yet-mapped edge → skip.
                const public_id = blk_pub: {
                    if ((src_engine.getEdge(edge_slot) catch null)) |rec| {
                        if (rec.public_id != 0) break :blk_pub rec.public_id;
                    }
                    _ = graph_store.edge_id_property_fallback_reads.fetchAdd(1, .monotonic);
                    const stored = (src_engine.getEdgeProperty(
                        from_slot,
                        edge_slot,
                        graph_store.INTERNAL_EDGE_ID_PROPERTY_KEY,
                        self.allocator,
                    ) catch null) orelse continue;
                    defer freeOwnedStorageProperty(self.allocator, stored);
                    switch (stored) {
                        .string => |text| break :blk_pub graph_store.parsePersistedPublicId(text) orelse continue,
                        else => continue,
                    }
                };
                // Apply the IDENTICAL scope/type/tenant predicates on the tested
                // public-id path (hydrate-on-miss for an evicted body). probeEdge
                // already guarantees (from,rel,to) and the engine identity covers
                // graph_name, but we keep the full check as defense-in-depth and
                // for the tenant disambiguation that the engine key cannot carry.
                const edge = store.getEdgePtrHydrated(public_id) orelse continue;
                if (edge.to_id != target_id) continue;
                if (!std.mem.eql(u8, edge.graph_name, graph_name)) continue;
                if (!std.mem.eql(u8, edge.label, rel_type)) continue;
                if (request_tenant.len != 0 and !std.mem.eql(u8, edge.tenant_id, request_tenant)) continue;
                // Already present — MERGE is a no-op create. Apply any props
                // (idempotent upsert) so a re-MERGE with edge props converges.
                if (props.len > 0) try self.applyEdgePropsLocked(store, public_id, props);
                return public_id;
            }
        }

        // Not found — create exactly like the insert inner.
        const io = std.Io.Threaded.global_single_threaded.io();
        mg.string_indexes_mutex.lockUncancelable(io);
        const create_result = store.createEdgeForRequestTenant(source_id, target_id, rel_type, graph_name, request_tenant);
        mg.string_indexes_mutex.unlock(io);
        const edge_id = try create_result;

        if (props.len > 0) try self.applyEdgePropsLocked(store, edge_id, props);
        _ = self.pending_bulk_ops.fetchAdd(1, .monotonic);
        return edge_id;
    }

    /// PHASE 4 (edge-engine-direct, low-contention apply): one entry of a batched
    /// relationship-MERGE apply. The coordinator collects a run of `bulk_merge_edge`
    /// ops from a single shard batch and hands them here so the per-op overhead
    /// (graph rwlock SHARED acquire/release, getOrCreateGraph, the source-shard
    /// lock acquire/release) is paid ONCE for the run instead of per edge — the
    /// residual per-source serialization the design (C.2) calls out. `out_id` /
    /// `out_err` receive the per-edge result the coordinator copies into the op's
    /// ApplyResult before waking the submitter.
    pub const BatchMergeEdge = struct {
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
        tenant: []const u8,
        out_id: u64 = 0,
        out_err: ?anyerror = null,
    };

    /// Apply a batch of relationship MERGEs under amortized locking.
    ///
    /// Lock protocol (preserves the per-op invariants exactly):
    ///   * graph `rwlock` SHARED for the whole batch (coexists with readers; the
    ///     per-op path took/released it per edge).
    ///   * For each edge, the SOURCE endpoint's shard lock is held EXCLUSIVE
    ///     across its probe+create (same as the per-op path) — but consecutive
    ///     edges that share a source shard reuse a single hold instead of
    ///     re-acquiring. The TARGET's shard lock (when distinct) is taken in
    ///     canonical ASCENDING index order so the two-lock acquire is
    ///     deadlock-free, identical to the per-op `min/max` discipline.
    ///
    /// Dedup / idempotency / orphan-skip / tenant disambiguation are UNCHANGED:
    /// each edge runs the same `bulkMergeEdgeInnerShardLocked` under the same
    /// endpoint shard locks, so two racing same-tuple MERGEs still serialize on
    /// the source shard and the O(1) existence index still yields exactly one
    /// edge. GAP-0278 lock order is preserved (we never re-enter tier-0
    /// self.mutex while holding shard/graph locks; getOrCreateGraph runs before
    /// any shard lock is taken).
    ///
    /// Orphan endpoints (SourceNodeNotFound / TargetNodeNotFound) are recorded as
    /// out_id = 0, out_err = null (silent skip), matching the coordinator's
    /// per-op handling; all other errors propagate via out_err.
    pub fn bulkMergeEdgesBatchShardLocked(
        self: *StorageAdapter,
        graph_name: []const u8,
        edges: []BatchMergeEdge,
    ) !void {
        if (edges.len == 0) return;
        const mg = try self.getOrCreateGraph(graph_name);
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const io = std.Io.Threaded.global_single_threaded.io();

        exclusiveWaitingBackoff(mg); // yield to a pending exclusive (checkpoint / CREATE INDEX) ONCE for the batch.
        const _t_start = monoNanosNow();
        mg.rwlock.lockSharedUncancelable(io);
        _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
        _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
        defer mg.rwlock.unlockShared(io);
        const _hold_start = monoNanosNow();
        defer {
            const _hold_ns = monoNanosNow() -| _hold_start;
            _ = mg.rwlock_shared_hold_ns_total.fetchAdd(_hold_ns, .monotonic);
            _ = mg.rwlock_shared_hold_bulk_edge_ns_total.fetchAdd(_hold_ns, .monotonic);
            const _cur_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
            if (_hold_ns > _cur_max) mg.rwlock_shared_max_hold_ns_observed.store(_hold_ns, .monotonic);
        }

        // Process edges in arrival order, holding the CURRENT source-shard lock
        // across a maximal run of consecutive edges that share that source shard.
        // Source-id routing (group_commit.shardKey) groups a worker's batch by
        // shardIndex(source_id), so for the popular-parent workload the entire
        // run shares one source shard → one lock acquire for the whole batch.
        //
        // Edge co-location (Phase A): the engine edge write is now SINGLE-shard
        // on shard(source) (the incoming adjacency lives in shard(source)'s
        // adj_in_remote keyed by target — no dst-shard write). The per-edge
        // target-shard lock (and its tryLock/drop-and-reacquire ascending dance
        // for dst < src) is therefore GONE: one source-shard lock covers the
        // whole edge, cross-endpoint included, with no cross-worker dst
        // contention. This is the lock-side half of the throughput unlock.
        var i: usize = 0;
        while (i < edges.len) {
            const src_shard = sharded_store.shardIndex(edges[i].source_id);
            mg.shard_locks[src_shard].lockUncancelable(io);

            // Drain the maximal run sharing this source shard under the one hold.
            while (i < edges.len and sharded_store.shardIndex(edges[i].source_id) == src_shard) : (i += 1) {
                self.applyOneMerge(mg, store, graph_name, &edges[i]);
            }

            mg.shard_locks[src_shard].unlock(io);
        }
    }

    /// Apply a single MERGE under already-held endpoint shard locks, recording
    /// the result on the batch entry. Orphan endpoints are a silent skip
    /// (out_id = 0, out_err = null); other errors land in out_err. The inner
    /// bumps `pending_bulk_ops` on create (the checkpoint-cadence signal), so the
    /// batch does NOT re-count.
    fn applyOneMerge(
        self: *StorageAdapter,
        mg: *ManagedGraph,
        store: *graph_store.GraphStore,
        graph_name: []const u8,
        e: *BatchMergeEdge,
    ) void {
        if (self.bulkMergeEdgeInnerShardLocked(mg, store, graph_name, e.source_id, e.target_id, e.rel_type, e.props, e.tenant)) |id| {
            e.out_id = id;
            e.out_err = null;
        } else |err| switch (err) {
            error.SourceNodeNotFound, error.TargetNodeNotFound => {
                e.out_id = 0;
                e.out_err = null;
            },
            else => {
                e.out_id = 0;
                e.out_err = err;
            },
        }
    }

    /// Apply edge properties via the batch helper (shared by the merge inner's
    /// create + dedup-upsert branches). Caller holds the endpoint shard locks.
    fn applyEdgePropsLocked(self: *StorageAdapter, store: *graph_store.GraphStore, edge_id: u64, props: []const PropKV) !void {
        var entries_buf: [16]graph_store.GraphStore.BatchPropertyEntry = undefined;
        const entries: []graph_store.GraphStore.BatchPropertyEntry = if (props.len <= entries_buf.len)
            entries_buf[0..props.len]
        else
            try self.allocator.alloc(graph_store.GraphStore.BatchPropertyEntry, props.len);
        defer if (props.len > entries_buf.len) self.allocator.free(entries);
        for (props, 0..) |kv, i| {
            entries[i] = .{ .key = kv.key, .value = kv.value };
        }
        try store.setEdgePropertiesBatch(edge_id, entries);
    }

    /// Phase 2 shard-locked MERGE variant.  Serialize only same-tuple
    /// writers on the striped `merge_tuple_locks` table (GAP-0894),
    /// probe under `rwlock` SHARED, and on miss delegate the insert to
    /// the shard-aligned `bulkInsertNodeWithReservedIdForTenant`.
    ///
    /// The `reserved_id` may be abandoned if the probe discovers an
    /// existing candidate (id-space leak is bounded by ingest size;
    /// same behaviour as the pre-sharding coordinator under race).
    pub fn bulkMergeNodeWithReservedId(
        self: *StorageAdapter,
        graph_name: []const u8,
        reserved_id: u64,
        label: []const u8,
        merge_key: []const u8,
        merge_value: graph_store.PropertyValue,
        on_create_props: []const PropKV,
        apply_on_match: bool,
    ) !u64 {
        // GAP-0891 (RC-1): see bulkInsertNodeWithReservedId.
        const id = try self.bulkMergeNodeWithReservedIdForTenant(
            graph_name,
            reserved_id,
            label,
            merge_key,
            merge_value,
            on_create_props,
            apply_on_match,
            fle_integration.tenantPreferringActiveContext(),
        );
        self.maybeCheckpointInline(); // GAP-0900: locks released; safe to checkpoint.
        return id;
    }

    // GAP-0891 (RC-1): tenant-threaded variant of bulkMergeNodeWithReservedId.
    pub fn bulkMergeNodeWithReservedIdForTenant(
        self: *StorageAdapter,
        graph_name: []const u8,
        reserved_id: u64,
        label: []const u8,
        merge_key: []const u8,
        merge_value: graph_store.PropertyValue,
        on_create_props: []const PropKV,
        apply_on_match: bool,
        request_tenant: []const u8,
    ) !u64 {
        // GAP-0900 Layer-3 (Fix 2): in lean-index mode the merge key must stay
        // indexed so dedup + edge-endpoint resolution still find this node by
        // its key. Registering is a no-op when lean mode is off. Idempotent.
        graph_store.registerMergeIndexKey(merge_key);

        const mg = try self.getOrCreateGraph(graph_name);
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const io = std.Io.Threaded.global_single_threaded.io();

        // GAP-0894: stripe single-property MERGE through the same per-tuple
        // lock table the multi-property path uses, instead of taking the
        // graph-global `merge_prop_index_lock` EXCLUSIVE on every insert.
        // Disjoint (label, merge_key, merge_value) tuples hash to different
        // stripes and proceed in parallel; only same-key MERGE races
        // serialize. The stripe hold spans probe+insert so two writers for
        // the same key cannot both miss-then-insert (no double node).
        const merge_props_1 = [_]PropKV{.{ .key = merge_key, .value = merge_value }};
        const tuple_lock_idx = mergeTupleLockIndex(label, &merge_props_1);
        const tuple_wait_start = monoNanosNow();
        mg.merge_tuple_locks[tuple_lock_idx].lockUncancelable(io);
        const tuple_hold_start = monoNanosNow();
        const tuple_wait_ns = tuple_hold_start -| tuple_wait_start;
        _ = mg.merge_tuple_lock_acquired_total.fetchAdd(1, .monotonic);
        _ = mg.merge_tuple_lock_wait_ns_total.fetchAdd(tuple_wait_ns, .monotonic);
        observeMaxAtomic(&mg.merge_tuple_lock_max_wait_ns_observed, tuple_wait_ns);
        defer {
            const tuple_hold_ns = monoNanosNow() -| tuple_hold_start;
            _ = mg.merge_tuple_lock_hold_ns_total.fetchAdd(tuple_hold_ns, .monotonic);
            observeMaxAtomic(&mg.merge_tuple_lock_max_hold_ns_observed, tuple_hold_ns);
            mg.merge_tuple_locks[tuple_lock_idx].unlock(io);
        }

        // Probe phase under `rwlock` SHARED. `lookupMergeCandidate` reads the
        // merge_prop_index under its own leaf mutex; combined with the
        // per-tuple lock (which serializes same-key writers) this is
        // sufficient — no graph-global exclusive needed.
        {
            exclusiveWaitingBackoff(mg); // GAP-0900 / edge-40001: yield to a pending exclusive (checkpoint or edge schema/MERGE).
            const _t_start = monoNanosNow();
            mg.rwlock.lockSharedUncancelable(io);
            _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
            _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
            defer mg.rwlock.unlockShared(io);
            const _hold_start = monoNanosNow();
            defer {
                const _hold_ns = monoNanosNow() -| _hold_start;
                _ = mg.rwlock_shared_hold_ns_total.fetchAdd(_hold_ns, .monotonic);
                _ = mg.rwlock_shared_hold_bulk_merge_ns_total.fetchAdd(_hold_ns, .monotonic);
                const _cur_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
                if (_hold_ns > _cur_max) {
                    mg.rwlock_shared_max_hold_ns_observed.store(_hold_ns, .monotonic);
                }
            }

            var probe_id: u64 = 0;
            switch (store.lookupMergeCandidate(graph_name, label, merge_key, merge_value, &probe_id)) {
                .found => {
                    if (apply_on_match) {
                        try store.setNodeProperty(probe_id, merge_key, merge_value);
                        for (on_create_props) |kv| {
                            if (std.mem.eql(u8, kv.key, merge_key)) continue;
                            try store.setNodeProperty(probe_id, kv.key, kv.value);
                        }
                        // GAP-0900: the on-match upsert writes to the engine WAL
                        // too — count it toward the checkpoint cadence. (The
                        // create branch is counted by the delegated bulkInsert.)
                        _ = self.pending_bulk_ops.fetchAdd(1, .monotonic);
                    }
                    return probe_id;
                },
                .not_indexable => return error.MergeValueNotIndexable,
                .not_found => {},
            }
        }

        // Insert phase: delegate to the shard-aligned bulk insert helper —
        // the same create path the multi-property MERGE uses (:2511).
        var combined_buf: [64]PropKV = undefined;
        const combined_len = 1 + on_create_props.len;
        const combined_props: []PropKV = if (combined_len <= combined_buf.len)
            combined_buf[0..combined_len]
        else
            try self.allocator.alloc(PropKV, combined_len);
        defer if (combined_len > combined_buf.len) self.allocator.free(combined_props);

        combined_props[0] = .{ .key = merge_key, .value = merge_value };
        if (on_create_props.len > 0) {
            @memcpy(combined_props[1..][0..on_create_props.len], on_create_props);
        }

        const labels_slice = [_][]const u8{label};
        return try self.bulkInsertNodeWithReservedIdForTenant(
            graph_name,
            reserved_id,
            &labels_slice,
            combined_props,
            request_tenant,
        );
    }

    /// Multi-property MERGE fast path for no-RETURN node patterns such as:
    ///
    ///     MERGE (:HCParallel {worker: 1, seq: 2})
    ///
    /// The regular executor holds the whole-graph EXCLUSIVE lock across parse
    /// environment setup, label scans, create, and property writes. Under high
    /// parallel mutation fan-out that makes every worker queue on
    /// `mg.rwlock`. This path instead serializes only matching property tuples,
    /// probes under shard read locks, then delegates the create branch to the
    /// shard-aligned bulk insert helper.
    pub fn bulkMergeNodeWithReservedIdMultiProp(
        self: *StorageAdapter,
        graph_name: []const u8,
        reserved_id: u64,
        label: []const u8,
        merge_props: []const PropKV,
        on_create_props: []const PropKV,
        apply_on_match: bool,
    ) !u64 {
        // GAP-0891 (RC-1): see bulkInsertNodeWithReservedId.
        const id = try self.bulkMergeNodeWithReservedIdMultiPropForTenant(
            graph_name,
            reserved_id,
            label,
            merge_props,
            on_create_props,
            apply_on_match,
            fle_integration.tenantPreferringActiveContext(),
        );
        self.maybeCheckpointInline(); // GAP-0900: locks released; safe to checkpoint.
        return id;
    }

    // GAP-0891 (RC-1): tenant-threaded variant of bulkMergeNodeWithReservedIdMultiProp.
    // GAP-0900: `apply_on_match` upserts `on_create_props` onto an existing
    // node found via the merge keys (bare-`SET` multi-key MERGE coalesce
    // upsert), mirroring the single-key path's on-match apply.
    pub fn bulkMergeNodeWithReservedIdMultiPropForTenant(
        self: *StorageAdapter,
        graph_name: []const u8,
        reserved_id: u64,
        label: []const u8,
        merge_props: []const PropKV,
        on_create_props: []const PropKV,
        apply_on_match: bool,
        request_tenant: []const u8,
    ) !u64 {
        if (merge_props.len == 0) return error.InvalidMergePattern;

        // GAP-0900 Layer-3 (Fix 2): keep all multi-prop MERGE keys indexed in
        // lean mode (no-op when off). Idempotent.
        for (merge_props) |mp| graph_store.registerMergeIndexKey(mp.key);

        // Caveat "B": a multi-prop MERGE defines a COMPOSITE dedup key. Register
        // it so node-create writes the resident composite merge entry and the
        // from-dump EDGE phase resolves endpoints by the SAME composite in ONE
        // zero-read probe. Idempotent; auto-registers {source, source_id} the
        // first time a from-dump Taxon is MERGEd — symmetric with the single-key
        // registration above and exactly the key the edge MATCH probes.
        if (merge_props.len >= 2) {
            var key_names_buf: [16][]const u8 = undefined;
            if (merge_props.len <= key_names_buf.len) {
                for (merge_props, 0..) |mp, i| key_names_buf[i] = mp.key;
                graph_store.registerCompositeMergeKey(key_names_buf[0..merge_props.len]);
            }
        }

        const mg = try self.getOrCreateGraph(graph_name);
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const io = std.Io.Threaded.global_single_threaded.io();

        const tuple_lock_idx = mergeTupleLockIndex(label, merge_props);
        const tuple_wait_start = monoNanosNow();
        mg.merge_tuple_locks[tuple_lock_idx].lockUncancelable(io);
        const tuple_hold_start = monoNanosNow();
        const tuple_wait_ns = tuple_hold_start -| tuple_wait_start;
        _ = mg.merge_tuple_lock_acquired_total.fetchAdd(1, .monotonic);
        _ = mg.merge_tuple_lock_wait_ns_total.fetchAdd(tuple_wait_ns, .monotonic);
        observeMaxAtomic(&mg.merge_tuple_lock_max_wait_ns_observed, tuple_wait_ns);
        defer {
            const tuple_hold_ns = monoNanosNow() -| tuple_hold_start;
            _ = mg.merge_tuple_lock_hold_ns_total.fetchAdd(tuple_hold_ns, .monotonic);
            observeMaxAtomic(&mg.merge_tuple_lock_max_hold_ns_observed, tuple_hold_ns);
            mg.merge_tuple_locks[tuple_lock_idx].unlock(io);
        }

        const existing_id = existing_blk: {
            exclusiveWaitingBackoff(mg); // GAP-0900 / edge-40001: yield to a pending exclusive (checkpoint or edge schema/MERGE).
            const _t_start = monoNanosNow();
            mg.rwlock.lockSharedUncancelable(io);
            _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
            _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
            defer mg.rwlock.unlockShared(io);
            const _hold_start = monoNanosNow();
            defer {
                const _hold_ns = monoNanosNow() -| _hold_start;
                _ = mg.rwlock_shared_hold_ns_total.fetchAdd(_hold_ns, .monotonic);
                _ = mg.rwlock_shared_hold_bulk_merge_ns_total.fetchAdd(_hold_ns, .monotonic);
                const _cur_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
                if (_hold_ns > _cur_max) {
                    mg.rwlock_shared_max_hold_ns_observed.store(_hold_ns, .monotonic);
                }
            }

            const found = try findNodeMatchingMergeProps(self, self.allocator, mg, store, graph_name, label, merge_props);
            // GAP-0900 coalesce-upsert: apply the SET props to the existing
            // node on the match branch, mirroring the single-key path
            // (~:2381). Done under the same shared-rwlock + per-tuple-lock
            // critical section as the probe so a concurrent same-key writer
            // is serialized. The merge keys themselves are re-asserted (they
            // already hold the matched values); on_create_props that name a
            // merge key are skipped to avoid clobbering the index tuple.
            if (apply_on_match) {
                if (found) |existing| {
                    for (merge_props) |kv| {
                        try store.setNodeProperty(existing, kv.key, kv.value);
                    }
                    for (on_create_props) |kv| {
                        var is_merge_key = false;
                        for (merge_props) |mp| {
                            if (std.mem.eql(u8, kv.key, mp.key)) {
                                is_merge_key = true;
                                break;
                            }
                        }
                        if (is_merge_key) continue;
                        try store.setNodeProperty(existing, kv.key, kv.value);
                    }
                    // GAP-0900: on-match upsert writes hit the engine WAL; count
                    // them toward the checkpoint cadence (create branch is
                    // counted by the delegated bulkInsert).
                    _ = self.pending_bulk_ops.fetchAdd(1, .monotonic);
                }
            }
            break :existing_blk found;
        };
        if (existing_id) |existing| {
            return existing;
        }

        var combined_buf: [64]PropKV = undefined;
        const combined_len = merge_props.len + on_create_props.len;
        const combined_props: []PropKV = if (combined_len <= combined_buf.len)
            combined_buf[0..combined_len]
        else
            try self.allocator.alloc(PropKV, combined_len);
        defer if (combined_len > combined_buf.len) self.allocator.free(combined_props);

        @memcpy(combined_props[0..merge_props.len], merge_props);
        if (on_create_props.len > 0) {
            @memcpy(combined_props[merge_props.len..][0..on_create_props.len], on_create_props);
        }

        const labels_slice = [_][]const u8{label};
        return try self.bulkInsertNodeWithReservedIdForTenant(
            graph_name,
            reserved_id,
            &labels_slice,
            combined_props,
            request_tenant,
        );
    }

    /// Key + value pair accepted by `bulkInsertNode`.  The caller owns both
    /// the key bytes and the value payload for the duration of the call; the
    /// adapter/store copies what it needs internally before returning.
    pub const PropKV = struct {
        key: []const u8,
        value: graph_store.PropertyValue,
    };

    /// Task 12 (enterprise-ingest-throughput): MATCH+CREATE edge fast path.
    ///
    /// Resolves `(src_label, filter_key=src_node_id)` and
    /// `(dst_label, filter_key=dst_node_id)` via `lookupMergeCandidate`
    /// (O(1) merge-prop index probe against the in-memory store), then
    /// creates the edge + writes each property under a single statement
    /// engine txn so the whole operation commits with ONE WAL fsync.
    ///
    /// The caller must supply BOTH endpoints' label + filter key + filter
    /// value — mirroring the msft-graph edges_*.jsonl hot-path pattern
    /// `MATCH (a:L1 {node_id: 'x'}), (b:L2 {node_id: 'y'}) CREATE
    /// (a)-[:T {props}]->(b)`.
    ///
    /// Errors:
    ///   * `error.SourceNodeNotFound` — the (src_label, src_filter_key=value)
    ///     probe returned null (or not-indexable, which means the caller
    ///     cannot use the fast path — dispatcher should fall back).
    ///   * `error.TargetNodeNotFound` — symmetric.
    ///   * anything else — propagates the underlying graph-store /
    ///     engine error.
    ///
    /// Undo-log contract: same as `bulkInsertNode` — SKIPS the undo log.
    /// The operator opts into the bulk path via `GEODE_BULK_INGEST=1` and
    /// commits or nukes the whole batch; individual-statement rollback is
    /// not supported.
    ///
    /// In-memory store consistency: routes through
    /// `GraphStore.createEdgeWithGraph` + `setEdgeProperty`, so the
    /// in-memory edge map, adjacency index, and edge-type index stay in
    /// sync with the persistent engine state.
    pub fn bulkInsertEdge(
        self: *StorageAdapter,
        graph_name: []const u8,
        src_label: []const u8,
        src_node_id: graph_store.PropertyValue,
        src_filter_key: []const u8,
        dst_label: []const u8,
        dst_node_id: graph_store.PropertyValue,
        dst_filter_key: []const u8,
        rel_type: []const u8,
        props: []const PropKV,
        txn_id_opt: ?u64,
    ) !u64 {
        _ = txn_id_opt; // thread-local statement-txn slots are source of truth.

        const store = graph_store.getGlobalStore(graph_store.global_allocator());

        // Endpoint resolution — both lookups MUST succeed for a fast-path
        // edge.  `.not_indexable` means the value type (e.g. list / map)
        // can't use the merge-prop index; dispatchers should treat that
        // as "fall back to full executor" not a user-visible error, so
        // we map it here to the same not-found error code — the caller
        // can distinguish if needed.
        var src_id: u64 = undefined;
        switch (store.lookupMergeCandidate(graph_name, src_label, src_filter_key, src_node_id, &src_id)) {
            .found => {},
            .not_found => return error.SourceNodeNotFound,
            .not_indexable => return error.SourceNodeNotFound,
        }
        var dst_id: u64 = undefined;
        switch (store.lookupMergeCandidate(graph_name, dst_label, dst_filter_key, dst_node_id, &dst_id)) {
            .found => {},
            .not_found => return error.TargetNodeNotFound,
            .not_indexable => return error.TargetNodeNotFound,
        }

        // Statement-txn batching: same pattern as `bulkInsertNode`.  Join
        // an existing session/statement txn if one is active on this
        // graph; otherwise open a per-statement txn so the addEdge +
        // per-property putProperty sub-ops commit with ONE WAL fsync.
        var stmt_txn: StatementTxn = undefined;
        var stmt_txn_open = false;
        const session_covers = if (sessionEngineTxnGraph()) |g|
            std.mem.eql(u8, g, graph_name)
        else
            false;
        if (!session_covers and t_current_statement_txn == null) {
            self.ensureGraphExistsForBulk(graph_name) catch |err| switch (err) {
                error.GraphNotFound => {},
                else => return err,
            };
            if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| {
                stmt_txn_open = true;
            } else |err| switch (err) {
                error.GraphNotFound, error.NestedStatementTxn => {},
                else => return err,
            }
        }
        errdefer if (stmt_txn_open) stmt_txn.abort();

        // Create the edge — `createEdgeWithGraph` routes through the
        // adapter vtable (which joins the statement txn internally via
        // `StorageAdapter.createEdge`) AND updates the in-memory
        // `GraphStore.edges` map / adjacency index / edge-type index.
        const edge_id = try store.createEdgeWithGraph(src_id, dst_id, rel_type, graph_name);

        // Per-property: route through `GraphStore.setEdgeProperty` which
        // hits the adapter (R12 patch keeps this inside our statement
        // txn) plus the in-memory edge property map.
        for (props) |kv| {
            try store.setEdgeProperty(edge_id, kv.key, kv.value);
        }

        if (stmt_txn_open) try stmt_txn.commit();
        return edge_id;
    }

    /// Task 15/16 (enterprise-ingest-throughput): pure MATCH-side resolver for
    /// the two-phase lock split on the bulk edge path.
    ///
    /// Returns the node id of the single node in `graph_name` that matches
    /// `(label, prop_key = prop_value)` via the merge-prop index.  On miss,
    /// returns `missing_err` — the caller passes `error.SourceNodeNotFound`
    /// or `error.TargetNodeNotFound` to keep wire-level error mapping
    /// consistent with `bulkInsertEdge`.
    ///
    /// This function is a PURE READ: it consults `merge_prop_index.get` +
    /// `nodes.get` only (see Phase 4 invariants in
    /// `docs/performance/2026-04-23-enterprise-ingest/phase4-invariants.md`),
    /// so it is safe to call under `acquireGraphReadLock`.
    ///
    /// `.not_indexable` results are mapped to `missing_err` for the same
    /// reason as `bulkInsertEdge` — the fast path cannot handle
    /// non-indexable values and must treat them as a not-found for the
    /// caller's purposes.
    pub fn lookupNodeByMergeKey(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        prop_key: []const u8,
        prop_value: graph_store.PropertyValue,
        missing_err: anyerror,
    ) !u64 {
        _ = self;
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        var id: u64 = undefined;
        switch (store.lookupMergeCandidate(graph_name, label, prop_key, prop_value, &id)) {
            .found => return id,
            .not_found, .not_indexable => return missing_err,
        }
    }

    /// Task 15/16 (enterprise-ingest-throughput): write-phase counterpart of
    /// `bulkInsertEdge` that skips the MATCH lookups.
    ///
    /// Caller must have resolved `source_id` + `target_id` via
    /// `lookupNodeByMergeKey` under a shared read lock BEFORE calling this
    /// method, and must hold the exclusive per-graph write lock for the
    /// duration of this call.
    ///
    /// Race handling: between the caller's Phase 1 read-lock lookup and
    /// this Phase 2 write-lock apply, another writer could have deleted one
    /// of the endpoint nodes.  In that case `createEdgeWithGraph` stores
    /// the edge record but the adapter-side `nodeSlot` lookup yields null
    /// and the persisted-edge branch is skipped — the in-memory edge will
    /// point at a vanished endpoint.  To surface this cleanly, we re-check
    /// `nodes.get` for both endpoints under the write lock before writing.
    /// A miss returns `error.SourceNodeNotFound` / `error.TargetNodeNotFound`
    /// — the same errors the single-phase `bulkInsertEdge` raises for a
    /// missing endpoint, so callers need no new wire mapping.
    ///
    /// Other invariants (undo-log skip, statement-txn batching, in-memory
    /// index maintenance) match `bulkInsertEdge`.
    pub fn bulkInsertEdgeWithIds(
        self: *StorageAdapter,
        graph_name: []const u8,
        source_id: u64,
        target_id: u64,
        rel_type: []const u8,
        props: []const PropKV,
        txn_id_opt: ?u64,
    ) !u64 {
        _ = txn_id_opt; // thread-local statement-txn slots are source of truth.

        const store = graph_store.getGlobalStore(graph_store.global_allocator());

        // Race re-check: the caller resolved the endpoints under the shared
        // read lock, then released it before acquiring the write lock we
        // now hold.  A concurrent writer could have deleted either node in
        // the gap.  Surface that cleanly before mutating any state.
        if (store.nodes.getPtr(source_id) == null) return error.SourceNodeNotFound;
        if (store.nodes.getPtr(target_id) == null) return error.TargetNodeNotFound;

        // Statement-txn batching: same pattern as `bulkInsertEdge`.
        var stmt_txn: StatementTxn = undefined;
        var stmt_txn_open = false;
        const session_covers = if (sessionEngineTxnGraph()) |g|
            std.mem.eql(u8, g, graph_name)
        else
            false;
        if (!session_covers and t_current_statement_txn == null) {
            self.ensureGraphExistsForBulk(graph_name) catch |err| switch (err) {
                error.GraphNotFound => {},
                else => return err,
            };
            if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| {
                stmt_txn_open = true;
            } else |err| switch (err) {
                error.GraphNotFound, error.NestedStatementTxn => {},
                else => return err,
            }
        }
        errdefer if (stmt_txn_open) stmt_txn.abort();

        const edge_id = try store.createEdgeWithGraph(source_id, target_id, rel_type, graph_name);

        // Task #34 (2026-04-24): route N properties through
        // `setEdgePropertiesBatch` instead of calling `setEdgeProperty` in
        // a loop.  The batch path acquires the adapter mutex once, does
        // exactly one `updateEdgePropHead` per direction at the end (for
        // the terminal `prop_head`), and runs `refreshPropertyChainIndex`
        // exactly once — collapsing the prior O(K²) cost to O(K).  Mirrors
        // the Task #33 conversion of `bulkInsertNode` at line 1140.  For
        // props.len == 0 we still return a valid edge_id without a no-op
        // batch call.
        if (props.len > 0) {
            var entries_buf: [16]graph_store.GraphStore.BatchPropertyEntry = undefined;
            const entries: []graph_store.GraphStore.BatchPropertyEntry = if (props.len <= entries_buf.len)
                entries_buf[0..props.len]
            else
                try self.allocator.alloc(graph_store.GraphStore.BatchPropertyEntry, props.len);
            defer if (props.len > entries_buf.len) self.allocator.free(entries);

            for (props, 0..) |kv, i| {
                entries[i] = .{ .key = kv.key, .value = kv.value };
            }
            try store.setEdgePropertiesBatch(edge_id, entries);
        }

        if (stmt_txn_open) try stmt_txn.commit();
        // GAP-0900: feed the checkpoint-cadence signal. No inline trigger here:
        // the caller holds the per-graph EXCLUSIVE write lock, so checkpointAll
        // (which re-acquires it) would self-deadlock; the node bulk paths /
        // coordinator drive the actual inline checkpoint once locks are free.
        _ = self.pending_bulk_ops.fetchAdd(1, .monotonic);
        return edge_id;
    }

    /// Bulk-ingest MERGE fast path for simple single-label, single-merge-key
    /// MERGE statements — counterpart to `bulkInsertNode` for the
    /// msft-graph nodes_*.jsonl hot path (677/677 node-phase statements
    /// were MERGEs per the Phase 1 trace).
    ///
    /// Semantics:
    ///   1. Probe the merge-prop index for `(graph, label, merge_key, merge_value)`
    ///      via `GraphStore.lookupMergeCandidate`.  If a node is found, return
    ///      its id unchanged (this is the ON MATCH no-op — the caller has
    ///      pre-screened that no `ON MATCH SET` clause is attached).
    ///   2. If not found, insert a new node with `[label]` and properties
    ///      `(merge_key, merge_value) ++ on_create_props`.  The merge key is
    ///      written as a regular property on the node (msft-graph's
    ///      `node_id` is both the merge key and a property in the output
    ///      view of the node) so a subsequent MATCH + filter path can find
    ///      it via either the merge-prop index or a property scan.
    ///
    /// Race handling: the two-phase QUIC dispatcher calls this helper after
    /// taking the per-graph exclusive write lock.  In the tests (which call
    /// the adapter directly, without an outer lock) a shared-read probe +
    /// exclusive-write insert is encoded inside this single call: both the
    /// probe and the insert go through the globally-held graph mutex via
    /// the in-memory store, so a 16-way concurrent `MERGE (n:U {id:'X'})`
    /// for the SAME id inserts exactly once (the lookup-then-insert is not
    /// atomic per-call, but the graph-store mutex serialises the
    /// `createNodeWithGraph` + `merge_prop_index.put` pair, and subsequent
    /// threads re-probe the index inside this same helper and observe the
    /// winning insertion).  The concurrent-MERGE-race test pins this
    /// invariant.
    ///
    /// Undo-log contract: same as `bulkInsertNode` — SKIPS the undo log.
    /// Callers must be running under `GEODE_BULK_INGEST=1` or equivalent
    /// opt-in (the QUIC dispatcher gates the call, and tests call the
    /// adapter directly to mirror that setup).
    ///
    /// Transaction semantics: joins the active session / statement engine
    /// txn via the R8 / R9 thread-local slots, exactly like `bulkInsertNode`.
    /// When no txn is open, opens a per-statement txn for the duration of
    /// the insert so the createNode + N × setNodeProperty sub-ops commit
    /// with ONE WAL fsync.
    ///
    /// Errors: propagates `createNodeWithGraph` / `setNodeProperty` errors
    /// unchanged.  Never returns a sentinel "found" flag — the caller can
    /// tell a creation from a match only by observing the node id
    /// (`store.nodes.count()` delta) if it cares.
    pub fn bulkMergeNode(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        merge_key: []const u8,
        merge_value: graph_store.PropertyValue,
        on_create_props: []const PropKV,
        txn_id_opt: ?u64,
        apply_on_match: bool,
    ) !u64 {
        _ = txn_id_opt; // reserved for future extensions; thread-local is source of truth.

        // GAP-0046 / GAP-0900 Layer-3 (Fix 2): in lean-index mode the merge key
        // MUST stay indexed so dedup + edge-endpoint resolution find this node
        // by its key across a reopen (the sidecar re-registers it before the
        // exact-index rebuild). The group-commit variant
        // (`bulkMergeNodeWithReservedIdForTenant`) already registers here; this
        // group-commit-OFF direct path missed it, so a lean-mode reopen left the
        // key UNindexed and the first re-MERGE created a duplicate. No-op when
        // lean mode is off. Idempotent.
        graph_store.registerMergeIndexKey(merge_key);

        const store = graph_store.getGlobalStore(graph_store.global_allocator());

        // Phase 1 (inline): merge-prop index probe.  `.not_indexable`
        // means the value type (list / map) cannot use the index; the
        // QUIC dispatcher pre-screens `isScalarPropExpr`, so hitting this
        // branch is unexpected — surface a distinct error so a
        // test / trace can differentiate "real miss" from "misclassified
        // fast-path candidate".
        //
        // When `apply_on_match` is true (bare-`SET` MERGE per GAP #59) we
        // skip the lock-free Phase-1 fast return so the SET clauses
        // commit inside the statement txn (single WAL fsync) along with
        // the merge-prop index update.
        var existing_id: u64 = undefined;
        if (!apply_on_match) {
            switch (store.lookupMergeCandidate(graph_name, label, merge_key, merge_value, &existing_id)) {
                .found => return existing_id,
                .not_found => {},
                .not_indexable => return error.MergeValueNotIndexable,
            }
        }

        // Phase 2: no node yet (or apply_on_match) — insert / upsert.
        // Match the executor's R8/R9 fsync batching: join an open
        // session/statement txn or open one so the createNode + N ×
        // setNodeProperty commit with a single WAL fsync.  See
        // `bulkInsertNode` for the full rationale.
        var stmt_txn: StatementTxn = undefined;
        var stmt_txn_open = false;
        const session_covers = if (sessionEngineTxnGraph()) |g|
            std.mem.eql(u8, g, graph_name)
        else
            false;
        if (!session_covers and t_current_statement_txn == null) {
            self.ensureGraphExistsForBulk(graph_name) catch |err| switch (err) {
                error.GraphNotFound => {},
                else => return err,
            };
            if (self.beginStatementTxn(graph_name, &stmt_txn)) |_| {
                stmt_txn_open = true;
            } else |err| switch (err) {
                error.GraphNotFound, error.NestedStatementTxn => {},
                else => return err,
            }
        }
        errdefer if (stmt_txn_open) stmt_txn.abort();

        // Re-probe under the txn.  For ON-CREATE-SET-only callers this
        // catches the narrow Phase-1-miss/Phase-2-hit race; for
        // apply_on_match callers this is the only probe (Phase 1 was
        // skipped) and on hit we apply the SET clauses to the existing
        // node before returning (true upsert semantics).
        switch (store.lookupMergeCandidate(graph_name, label, merge_key, merge_value, &existing_id)) {
            .found => {
                if (apply_on_match) {
                    try store.setNodeProperty(existing_id, merge_key, merge_value);
                    for (on_create_props) |kv| {
                        if (std.mem.eql(u8, kv.key, merge_key)) continue;
                        try store.setNodeProperty(existing_id, kv.key, kv.value);
                    }
                    if (stmt_txn_open) try stmt_txn.commit();
                    return existing_id;
                }
                if (stmt_txn_open) stmt_txn.abort();
                return existing_id;
            },
            .not_found, .not_indexable => {},
        }

        const labels = [_][]const u8{label};
        // GAP-0891 (RC-1): bulkMergeNode runs inline on the request/handler
        // thread (the GEODE_GROUP_COMMIT=off path), so the active
        // ExecutionContext / per-thread tenant is valid here — resolve it
        // explicitly and tag the merged node with it (instead of relying on the
        // implicit resolution inside createNodeWithGraph).
        const node_id = try store.createNodeForRequestTenant(&labels, graph_name, fle_integration.tenantPreferringActiveContext());

        // Write the merge key as a regular property (msft-graph's node_id
        // is both the merge key and a node property) and then all
        // ON CREATE SET properties.  `setNodeProperty` updates both the
        // adapter (via vtable → statement-txn putPropertyTxn) and the
        // in-memory map + merge-prop index.
        try store.setNodeProperty(node_id, merge_key, merge_value);
        for (on_create_props) |kv| {
            // Skip a duplicate merge_key entry in ON CREATE SET (caller
            // is allowed to specify it; we already wrote it above).
            if (std.mem.eql(u8, kv.key, merge_key)) continue;
            try store.setNodeProperty(node_id, kv.key, kv.value);
        }

        if (stmt_txn_open) try stmt_txn.commit();
        return node_id;
    }

    // CANARY: REQ=REQ-PERF-QPS-0815; FEATURE="BatchCreate"; ASPECT=AdapterBulkSlots; STATUS=TESTED; TEST=tests/test_gap0815_deep_bulk_create.zig; OWNER=performance; UPDATED=2026-04-20
    /// Allocate `n` node slots in the given graph + attach the same label set
    /// to each, under a SINGLE adapter mutex acquisition (vs N for N separate
    /// `createNode` calls). Caller owns the returned `[]u64`.
    ///
    /// Rationale: `createNode` calls `getOrCreateGraph` each invocation,
    /// which takes `self.mutex` once per call. For N homogeneous CREATE
    /// clauses this is the dominant per-clause overhead (the engine-level
    /// `allocNode` / `putNode` / `addLabel` work itself runs lock-free
    /// afterward). This variant resolves the `ManagedGraph` once and then
    /// caches label-id lookups across all N slots.
    ///
    /// Returns node slot IDs in the same order as their allocation (which
    /// is the order they are handed to the caller and the order they
    /// should be inserted into higher-level indices — e.g. GraphStore's
    /// label-posting-list append).
    pub fn createNodesBatch(
        self: *StorageAdapter,
        graph_name: []const u8,
        labels: []const []const u8,
        n: usize,
        out_allocator: Allocator,
    ) ![]u64 {
        if (n == 0) return try out_allocator.alloc(u64, 0);

        // Single adapter-mutex acquisition for the graph lookup (see
        // `getOrCreateGraph`). The ManagedGraph pointer is stable once
        // registered; subsequent engine operations don't need the adapter
        // mutex.
        const mg = try self.getOrCreateGraph(graph_name);

        // Resolve label strings → label ids once; apply to every new slot.
        var label_ids_buf: [8]gs.LabelId = undefined;
        var label_ids: []gs.LabelId = if (labels.len <= label_ids_buf.len)
            label_ids_buf[0..labels.len]
        else
            try self.allocator.alloc(gs.LabelId, labels.len);
        defer if (labels.len > label_ids_buf.len) self.allocator.free(label_ids);
        for (labels, 0..) |lbl, i| {
            label_ids[i] = try resolvePersistedLabelId(mg, lbl);
        }

        const rec_template = gs.node.NodeRec{
            .out_head = 0,
            .in_head = 0,
            .prop_head = 0,
            .label_head = 0,
            .label_count = 0,
            .flags = 0,
            ._pad = .{ 0, 0, 0, 0 },
            .txn_stamp = 1,
        };

        const out = try out_allocator.alloc(u64, n);
        errdefer out_allocator.free(out);

        // R7 (2026-04-22): batch across N nodes.  Under ShardedGraphEngine,
        // nodes are distributed across SHARD_COUNT shards (round-robin by the
        // coordinator_txn_counter).  Open one local txn per shard and commit
        // all at the end — still one fsync per shard, far fewer fsyncs than
        // the per-node auto-commit path.  Shards with no nodes in this batch
        // are skipped.
        const shard_count = gs.sharded_engine.SHARD_COUNT;
        var shard_txns: [shard_count]?gs.TxnId = [_]?gs.TxnId{null} ** shard_count;
        errdefer for (mg.engine.shards, 0..) |shard, si| {
            // error-policy: A — best-effort rollback on an already-failing path.
            if (shard_txns[si]) |t| shard.abortTxn(t) catch {};
        };

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const node_id = try mg.engine.allocNode();
            const si = gs.shard_count.shardOfNode(node_id);
            const node_shard = mg.engine.shards[si];
            if (shard_txns[si] == null) shard_txns[si] = try node_shard.beginTxn();
            const local_txn = shard_txns[si].?;
            try node_shard.putNodeTxn(node_id, rec_template, local_txn);
            for (label_ids) |label_id| {
                try node_shard.addLabelTxn(node_id, label_id, local_txn);
            }
            // gap 0026: WAL-log the node's REAL label page (see
            // relogSecurityLabelPageTxn) — no-op outside __geode_security.
            try relogSecurityLabelPageTxn(mg, node_shard, node_id, local_txn);
            out[i] = node_id;
        }

        for (mg.engine.shards, 0..) |shard, si| {
            if (shard_txns[si]) |t| try shard.commitTxn(t);
            shard_txns[si] = null;
        }
        return out;
    }

    /// Delete a node by ID in the named graph.
    pub fn deleteNode(self: *StorageAdapter, graph_name: []const u8, node_id: u64) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // H4: a live write must never mutate an unbuilt (deferred) exact index.
        try ensureExactNodePropertyIndexBuilt(self, mg);

        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
        const shard = mg.shardEngineForNode(node_id);
        const label_ids = try shard.label_store.getLabels(rec.label_head, self.allocator);
        defer self.allocator.free(label_ids);
        removeNodePropertiesForLabels(mg, node_id, label_ids, rec.prop_head);

        // R7 (2026-04-22): wrap the engine deleteNode call in an explicit
        // transaction — same fsync batching rationale as createNode.  Route
        // directly to the shard that owns node_id so the txn and the data
        // mutation are on the same single-threaded engine (ShardedGraphEngine
        // migration: Task 7).
        const txn = try shard.beginTxn();
        // error-policy: A — best-effort rollback on an already-failing path.
        errdefer shard.abortTxn(txn) catch {};
        try shard.deleteNodeTxn(node_id, txn);
        try shard.commitTxn(txn);
        // OTel Task 13: graph data model mutation counter.
        const _om13dn = @import("otel_metrics");
        _om13dn.recordNodeMutation(.delete, graph_name, .success);
    }

    /// Retrieve the string labels for a node. Caller owns the returned
    /// slice and must free both the slice and each string inside it.
    pub fn getNodeLabels(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![][]const u8 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        // Retrieve label IDs from the per-shard engine's LabelStore.
        const shard = mg.shardEngineForNode(node_id);
        const label_ids = try shard.label_store.getLabels(rec.label_head, allocator);
        defer allocator.free(label_ids);

        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |s| allocator.free(s);
            result.deinit(allocator);
        }

        for (label_ids) |label_id| {
            if (mg.label_dict.getString(label_id)) |name| {
                try result.append(allocator, try allocator.dupe(u8, name));
            }
        }

        return result.toOwnedSlice(allocator);
    }

    // ------------------------------------------------------------------
    // Edge CRUD
    // ------------------------------------------------------------------

    /// Create an edge between two nodes. Returns the edge ID.
    ///
    /// LEGACY surface (public_id = 0): the engine writes no inline public id,
    /// so the edge belongs to the property-fallback class. Kept for
    /// engine-level tests and the orphan-injection fixtures
    /// (tests/test_edge_durability_churn_repro.zig); geode's create paths go
    /// through `createEdgeWithPublicId` (GAP-ENT-0024).
    pub fn createEdge(self: *StorageAdapter, graph_name: []const u8, from_id: u64, to_id: u64, label: []const u8) !u64 {
        return self.createEdgeInternal(graph_name, from_id, to_id, label, 0);
    }

    /// GAP-ENT-0024: create an edge carrying the geode-minted 64-bit PUBLIC id
    /// INLINE in the durable adjacency records (graph-storage v0.2.24 v2
    /// blocks) — the edge needs NO `__geode_internal_edge_id` property page.
    ///
    /// `public_id == 0` is REJECTED loudly (release-review checklist:
    /// adapter-side id==0 guard). 0 is the engine's reserved "no inline id"
    /// sentinel: silently passing it would degrade the edge to the legacy
    /// fallback class WITHOUT the property being written — the edge would have
    /// no durable public id anywhere (silent data loss on restart). Geode
    /// mints nonzero time-based ids, so a 0 here is always a caller bug.
    pub fn createEdgeWithPublicId(self: *StorageAdapter, graph_name: []const u8, from_id: u64, to_id: u64, label: []const u8, public_id: u64) !u64 {
        if (public_id == 0) {
            log.err("createEdgeWithPublicId called with reserved public_id=0 on graph '{s}' — refusing (edge would lose its durable public id)", .{graph_name});
            return error.InvalidEdgePublicId;
        }
        return self.createEdgeInternal(graph_name, from_id, to_id, label, public_id);
    }

    fn createEdgeInternal(self: *StorageAdapter, graph_name: []const u8, from_id: u64, to_id: u64, label: []const u8, public_id: u64) !u64 {
        // OTel Task 12: record write_edge op duration + outcome.
        const _om12e = @import("otel_metrics");
        const _t0_12e = @import("otel").internal.clock.unixNanoNow();
        var _ok_12e = false;
        defer {
            const _dur: f64 = @as(f64, @floatFromInt(@import("otel").internal.clock.unixNanoNow() -% _t0_12e)) / @as(f64, std.time.ns_per_s);
            _om12e.recordStorageOp(.write_edge, _dur, if (_ok_12e) .success else .error_, null);
        }
        // NOTE (2026-04-29): see the matching note in
        // `graph_store.zig:createEdgeWithGraphAndTenant`. A trace span at
        // this layer was rolled back due to a BatchSpanProcessor race in
        // the upstream OTel SDK that panics under concurrent shard-worker
        // span emission. The `_om12e.recordEdgeMutation` counter below
        // continues to publish `geode.graph_store.edge_mutations_total`.
        const mg = try self.getOrCreateGraph(graph_name);
        const rel_type = try resolvePersistedLabelId(mg, label);

        // R10 (2026-04-22): join the active session/statement engine txn
        // when one exists on this graph so a whole edges_*.jsonl batch of
        // N CREATE edge statements commits with a single WAL fsync.  The
        // engine's `addEdge` auto-commit variant costs ~10 ms on SSD —
        // dominant in workloads with thousands of edges per batch (msft-
        // graph edges_signed_in_to / located_at have 8K+ rows each).
        //
        // R10 + 2026-04-27 fix: the per-shard `addEdgeTxn` fast path is
        // only safe when BOTH endpoints live on the same shard.  The
        // per-shard engine's `addEdgeTxn` does `node_store.getNode(to)`
        // on the from-shard's node_store — for a cross-shard edge that
        // returns null and surfaces as `error.NodeNotFound`.  When
        // from/to are on different shards, fall through to
        // `ShardedGraphEngine.addEdge`, which routes to the 2PC
        // `crossShardAddEdge` path that prepares + commits on both
        // shards correctly.  See
        // docs/bugs/2026-04-27-bulk-edge-id-map-silent-fallback.md §3.2.
        const same_shard = gs.shard_count.shardOfNode(from_id) == gs.shard_count.shardOfNode(to_id);
        if (same_shard) {
            const stmt_txn = currentStatementTxnForGraph(graph_name);
            if (stmt_txn) |s| {
                if (shardLocalTxnForNode(s.txn_id, from_id)) |local| {
                    // GAP-ENT-0024: the public-id-carrying path uses the
                    // CO-LOCATED txn add (the id rides both durable adjacency
                    // records; strictly fewer pages than addEdgeTxn's two-node
                    // write and no `to`-record read). The legacy public_id==0
                    // surface keeps the historical addEdgeTxn byte-for-byte.
                    const _edge_id = if (public_id != 0)
                        try mg.shardEngineForNode(from_id).addEdgeColocatedTxnWithPublicId(from_id, to_id, rel_type, local, public_id)
                    else
                        try mg.shardEngineForNode(from_id).addEdgeTxn(from_id, to_id, rel_type, local);
                    _ok_12e = true;
                    // OTel Task 13: graph data model mutation counter (fast path).
                    _om12e.recordEdgeMutation(.create, graph_name, .success);
                    return _edge_id;
                }
            }
        }
        // GAP-ENT-0024: auto-commit — ShardedGraphEngine.addEdge already
        // routes to the co-located add on shard(from); the WithPublicId
        // variant is the same single-shard WAL txn carrying the inline id.
        const _edge_id2 = if (public_id != 0)
            try mg.engine.addEdgeColocatedWithPublicId(from_id, to_id, rel_type, public_id)
        else
            try mg.engine.addEdge(from_id, to_id, rel_type);
        _ok_12e = true;
        // OTel Task 13: graph data model mutation counter.
        _om12e.recordEdgeMutation(.create, graph_name, .success);
        return _edge_id2;
    }

    /// Delete an edge by its endpoints and edge ID.
    ///
    /// Edge co-location (graph-storage Phase C): an edge `(from)-[r]->(to)` now
    /// lives ENTIRELY on shard(from) — out-adjacency, edge_index, the existence
    /// index AND the incoming adjacency (shard(from).adj_in_remote keyed by
    /// `to`). So removal is a SINGLE-shard delete on shard(from) for BOTH
    /// same-shard and cross-endpoint edges; `ShardedGraphEngine.removeEdge` no
    /// longer returns `error.CrossShardEdgeUnsupported`. The old adapter-level
    /// `removeCrossShardEdge` workaround (which tore down the legacy `dst.adj_in`
    /// in-entry) was removed: with co-location that store is empty for the edge,
    /// so it would have left a dangling reverse-traversal entry. Routing keys on
    /// shard(from) regardless of where `to` lives.
    ///
    /// R10: join the active session/statement engine txn when it lives on
    /// shard(from) (the edge's shard); otherwise auto-commit via the engine. This
    /// preserves the `2pc-rollback-edge-create-undone` regression (a rollback's
    /// undo-log replay deletes the edge so a follow-up
    /// `MATCH ()-[r]->() RETURN count(r)` returns 0).
    pub fn deleteEdge(self: *StorageAdapter, graph_name: []const u8, from_id: u64, to_id: u64, edge_id: u64) !void {
        // OTel Task 13: graph data model mutation counter (delete edge).
        const _om13de = @import("otel_metrics");
        var _ok_13de = false;
        defer if (_ok_13de) _om13de.recordEdgeMutation(.delete, graph_name, .success);
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // The edge is co-located on shard(from). Join an active stmt-txn iff it
        // is on shard(from); else single-shard auto-commit.
        if (currentStatementTxnForGraph(graph_name)) |s| {
            if (shardLocalTxnForNode(s.txn_id, from_id)) |local| {
                try mg.shardEngineForNode(from_id).removeEdgeTxn(from_id, to_id, edge_id, local);
                _ok_13de = true;
                return;
            }
        }
        try mg.engine.removeEdge(from_id, to_id, edge_id);
        _ok_13de = true;
    }

    /// Iterate all outgoing edges from a node without materializing them.
    pub fn iterateOutgoingEdges(
        self: *StorageAdapter,
        graph_name: []const u8,
        node_id: u64,
        allocator: Allocator,
    ) !gs.interface.EdgeIterator {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.storage().expandOut(node_id, null, allocator);
    }

    /// Iterate all incoming edges to a node without materializing them.
    pub fn iterateIncomingEdges(
        self: *StorageAdapter,
        graph_name: []const u8,
        node_id: u64,
        allocator: Allocator,
    ) !gs.interface.EdgeIterator {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.storage().expandIn(node_id, null, allocator);
    }

    /// Get all outgoing edges from a node.
    /// Returns a caller-owned slice built from the engine's edge iterator.
    pub fn getOutgoingEdges(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![]gs.edge.EdgeEntry {
        var result = std.ArrayList(gs.edge.EdgeEntry).empty;
        errdefer result.deinit(allocator);

        var iter = try self.iterateOutgoingEdges(graph_name, node_id, allocator);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            try result.append(allocator, entry);
        }

        return try result.toOwnedSlice(allocator);
    }

    /// Get all incoming edges to a node.
    /// Returns a caller-owned slice built from the engine's edge iterator.
    pub fn getIncomingEdges(self: *StorageAdapter, graph_name: []const u8, node_id: u64, allocator: Allocator) ![]gs.edge.EdgeEntry {
        var result = std.ArrayList(gs.edge.EdgeEntry).empty;
        errdefer result.deinit(allocator);

        var iter = try self.iterateIncomingEdges(graph_name, node_id, allocator);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            try result.append(allocator, entry);
        }

        return try result.toOwnedSlice(allocator);
    }

    // ------------------------------------------------------------------
    // Property operations
    // ------------------------------------------------------------------

    /// Set a property on a node. The value is converted from a geode
    /// `PropertyValue` to the storage engine's representation.
    ///
    /// The engine's `putProperty` returns a (potentially new) `prop_head`
    /// that must be written back to the node record.
    pub fn setNodeProperty(self: *StorageAdapter, graph_name: []const u8, node_id: u64, key: []const u8, value: graph_store.PropertyValue) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // H4: a live write must never mutate an unbuilt (deferred) exact index.
        try ensureExactNodePropertyIndexBuilt(self, mg);
        var rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
        const node_shard = mg.shardEngineForNode(node_id);
        const label_ids = try node_shard.label_store.getLabels(rec.label_head, self.allocator);
        defer self.allocator.free(label_ids);

        // Read the existing property via the node's shard. See
        // addNodePropertiesForLabels for why mg.engine.getProperty
        // would misroute.
        const old_value = if (rec.prop_head != 0) try node_shard.getProperty(rec.prop_head, key, self.allocator) else null;
        defer {
            if (old_value) |val| freeOwnedStorageProperty(self.allocator, val);
        }

        const storage_val = try toStorageProperty(self.allocator, value);
        defer freeTemporaryStorageProperty(self.allocator, storage_val);

        if (old_value) |existing| {
            for (label_ids) |label_id| {
                removeIndexedNodeProperty(mg, label_id, node_id, key, existing);
            }
        }

        // R7/R8 (2026-04-22): batch putProperty + putNode into one txn on the
        // node's shard. Join the statement txn's local txn if it is on the
        // same shard; otherwise open a fresh shard-local txn.
        const stmt_txn = currentStatementTxnForGraph(graph_name);
        const local_txn: gs.TxnId = if (stmt_txn) |s|
            shardLocalTxnForNode(s.txn_id, node_id) orelse try node_shard.beginTxn()
        else
            try node_shard.beginTxn();
        const own_txn = stmt_txn == null or shardLocalTxnForNode(stmt_txn.?.txn_id, node_id) == null;
        errdefer if (own_txn) {
            // error-policy: A — best-effort rollback on an already-failing path.
            node_shard.abortTxn(local_txn) catch {};
        };

        const new_prop_head = try node_shard.putPropertyTxn(rec.prop_head, key, storage_val, local_txn);

        // Update the node record with the (possibly changed) prop_head.
        rec.prop_head = new_prop_head;
        try node_shard.putNodeTxn(node_id, rec, local_txn);

        if (own_txn) try node_shard.commitTxn(local_txn);

        for (label_ids) |label_id| {
            try addIndexedNodeProperty(mg, label_id, node_id, key, storage_val);
        }
    }

    /// Batch property entry: a key with either a value to set or null to remove.
    pub const BatchPropertyEntry = struct {
        key: []const u8,
        value: ?graph_store.PropertyValue, // null means remove (tombstone)
    };

    /// Set or remove multiple properties on a node under a single mutex
    /// acquisition.  This avoids the per-property lock/unlock overhead of
    /// calling `setNodeProperty` / `removeNodeProperty` in a loop, which
    /// can cause severe mutex contention when the server is concurrently
    /// servicing queries against the same StorageAdapter.
    pub fn setNodePropertiesBatch(self: *StorageAdapter, graph_name: []const u8, node_id: u64, entries: []const BatchPropertyEntry) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // H4: a live write must never mutate an unbuilt (deferred) exact index.
        try ensureExactNodePropertyIndexBuilt(self, mg);
        var rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
        const node_shard = mg.shardEngineForNode(node_id);
        const label_ids = try node_shard.label_store.getLabels(rec.label_head, self.allocator);
        defer self.allocator.free(label_ids);

        // R7/R8: one txn on the node's shard covering the full N-property batch.
        const stmt_txn = currentStatementTxnForGraph(graph_name);
        const local_txn: gs.TxnId = if (stmt_txn) |s|
            shardLocalTxnForNode(s.txn_id, node_id) orelse try node_shard.beginTxn()
        else
            try node_shard.beginTxn();
        const own_txn = stmt_txn == null or shardLocalTxnForNode(stmt_txn.?.txn_id, node_id) == null;
        errdefer if (own_txn) {
            // error-policy: A — best-effort rollback on an already-failing path.
            node_shard.abortTxn(local_txn) catch {};
        };

        for (entries) |entry| {
            // Read via the node's shard — see addNodePropertiesForLabels.
            const old_value = if (rec.prop_head != 0) try node_shard.getProperty(rec.prop_head, entry.key, self.allocator) else null;
            defer {
                if (old_value) |val| freeOwnedStorageProperty(self.allocator, val);
            }

            if (entry.value) |val| {
                const storage_val = try toStorageProperty(self.allocator, val);
                defer freeTemporaryStorageProperty(self.allocator, storage_val);
                if (old_value) |existing| {
                    for (label_ids) |label_id| {
                        removeIndexedNodeProperty(mg, label_id, node_id, entry.key, existing);
                    }
                }
                const new_prop_head = try node_shard.putPropertyTxn(rec.prop_head, entry.key, storage_val, local_txn);
                rec.prop_head = new_prop_head;
                for (label_ids) |label_id| {
                    try addIndexedNodeProperty(mg, label_id, node_id, entry.key, storage_val);
                }
            } else {
                if (old_value) |existing| {
                    for (label_ids) |label_id| {
                        removeIndexedNodeProperty(mg, label_id, node_id, entry.key, existing);
                    }
                }
                const new_prop_head = try node_shard.putPropertyTxn(rec.prop_head, entry.key, .null, local_txn);
                rec.prop_head = new_prop_head;
                for (label_ids) |label_id| {
                    try addIndexedNodeProperty(mg, label_id, node_id, entry.key, .null);
                }
            }
        }

        // Write the node record once after all property mutations.
        try node_shard.putNodeTxn(node_id, rec, local_txn);
        if (own_txn) try node_shard.commitTxn(local_txn);
    }

    /// Remove a property from a node by writing a null tombstone.
    pub fn removeNodeProperty(self: *StorageAdapter, graph_name: []const u8, node_id: u64, key: []const u8) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // H4: a live write must never mutate an unbuilt (deferred) exact index.
        try ensureExactNodePropertyIndexBuilt(self, mg);
        var rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
        const node_shard = mg.shardEngineForNode(node_id);
        const label_ids = try node_shard.label_store.getLabels(rec.label_head, self.allocator);
        defer self.allocator.free(label_ids);
        // Read via the node's shard — see addNodePropertiesForLabels.
        const old_value = if (rec.prop_head != 0) try node_shard.getProperty(rec.prop_head, key, self.allocator) else null;
        defer {
            if (old_value) |val| freeOwnedStorageProperty(self.allocator, val);
        }

        if (old_value) |existing| {
            for (label_ids) |label_id| {
                removeIndexedNodeProperty(mg, label_id, node_id, key, existing);
            }
        }

        // R7: batch putProperty + putNode into one txn on the node's shard.
        const txn = try node_shard.beginTxn();
        // error-policy: A — best-effort rollback on an already-failing path.
        errdefer node_shard.abortTxn(txn) catch {};

        const new_prop_head = try node_shard.putPropertyTxn(rec.prop_head, key, .null, txn);
        rec.prop_head = new_prop_head;
        try node_shard.putNodeTxn(node_id, rec, txn);

        // Commit on the SAME per-shard engine that started the txn.
        // `mg.engine.commitTxn(txn)` (ShardedGraphEngine) decodes a shard
        // index from the high bits of `txn`, but `node_shard.beginTxn()`
        // returns a RAW local txn id (no shard-index bits encoded), so
        // routing through mg.engine.commitTxn would land on the wrong
        // shard and raise `error.TxnNotFound`. Mirrors setNodeProperty /
        // setNodePropertiesBatch / setEdgeProperty which already commit
        // through node_shard / from_shard directly.
        try node_shard.commitTxn(txn);

        for (label_ids) |label_id| {
            try addIndexedNodeProperty(mg, label_id, node_id, key, .null);
        }
    }

    /// Get a property from a node, returned in graph-storage representation.
    pub fn getNodeProperty(self: *StorageAdapter, graph_name: []const u8, node_id: u64, key: []const u8, allocator: Allocator) !?gs.PropertyValue {
        // OTel Task 12: record read_node op duration + outcome.
        const _om12r = @import("otel_metrics");
        const _t0_12r = @import("otel").internal.clock.unixNanoNow();
        var _ok_12r = false;
        defer {
            const _dur: f64 = @as(f64, @floatFromInt(@import("otel").internal.clock.unixNanoNow() -% _t0_12r)) / @as(f64, std.time.ns_per_s);
            _om12r.recordStorageOp(.read_node, _dur, if (_ok_12r) .success else .error_, null);
        }
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // Count the engine-direct property read (PropertyChain → BufferPool.pin).
        // The composite endpoint-resolution path must NOT reach here per endpoint.
        _ = g_node_property_engine_reads.fetchAdd(1, .monotonic);
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        if (rec.prop_head == 0) {
            _ok_12r = true;
            return null;
        }
        // Properties live on the same shard as the owning node — see
        // addNodePropertiesForLabels for the routing rationale.
        const _prop = try mg.shardEngineForNode(node_id).getProperty(rec.prop_head, key, allocator);
        _ok_12r = true;
        return _prop;
    }

    /// Get a node property directly from its prop_head (already known from a
    /// prior scanAllNodes), skipping the per-node getNode random read.
    /// slot_id routes to the owning shard (same as getNodeProperty); prop_head
    /// skips the getNode fetch, saving one random read per node.
    pub fn getNodePropertyByHead(self: *StorageAdapter, graph_name: []const u8, slot_id: u64, prop_head: u64, key: []const u8, allocator: Allocator) !?gs.PropertyValue {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        if (prop_head == 0) return null;
        // Cold-open H1: read the chain WITHOUT triggering the engine's full
        // derived property-chain index build (ensureDerivedHydrated). loop1 only
        // ever looks up the internal-id key which is always present, so the
        // derived index gives no benefit; getPropertyNoDerived walks the chain
        // directly and is byte-identical to getProperty for present keys.
        return try mg.shardEngineForNode(slot_id).getPropertyNoDerived(prop_head, key, allocator);
    }

    /// Return the shard index for a node slot. Mirrors shardOfNode(slot_id)
    /// used internally so callers can sort by (shard, prop_head) without
    /// importing graph_storage directly.
    pub fn shardOfSlot(_: *StorageAdapter, slot: u64) usize {
        return gs.shard_count.shardOfNode(slot);
    }

    /// Find all node IDs with the given label in a graph.
    /// Filters out deleted nodes whose slot IDs are still present in the
    /// label index (the engine's deleteNode sets NODE_FLAG_DELETED but does
    /// not remove the entry from the label posting list).
    pub fn iterateNodesByLabel(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        allocator: Allocator,
    ) !?gs.NodeIterator {
        const ctx = try self.resolveLabelScanContext(graph_name, label) orelse return null;
        return try ctx.mg.storage().scanLabelIter(ctx.label_id, allocator);
    }

    // CANARY: REQ=REQ-QUIC-HC-137; FEATURE="High-Concurrency Label Scans"; ASPECT=ShardLockedLabelCount; STATUS=TESTED; TEST=tests/test_gap0814_union_parallelism.zig; OWNER=storage; UPDATED=2026-07-05
    //
    // ENGINE-INTERNAL / ESTIMATE USE ONLY — NEVER a user-facing count.
    //
    // This sums the storage engine's per-shard `label_index` postings. Two
    // properties make that unfit to serve a user count (2026-07-05 live
    // regression at 14.27M — silent `count(n:L) = 0` after a reopen):
    //   1. Postings retain DELETED slots (engine deleteNode sets
    //      NODE_FLAG_DELETED without removing the posting) — over-count.
    //   2. The index is a DEFERRED derived structure (graph-storage Phase A):
    //      empty until materialized, and the in-memory streaming hydration
    //      never fills it — under-count/zero after a catalog-mediated open.
    // User-facing counts must read the authoritative in-memory maintained
    // refcount: `GraphStore.countNodesByLabel` (ensureGraphHydrated-guarded).
    //
    // The `ensureDerivedHydrated` guard below upholds the graph-storage
    // Phase A contract ("MUST be called ... before the index is read") so any
    // remaining engine-internal caller at least reads a MATERIALIZED index
    // (counter-gated snapshot load on clean restart, rebuild on crash) instead
    // of the deferred-empty one. Guard runs BEFORE the shard lock, the same
    // order `appendLiveNodesForLabelShard` establishes via `scanLabelIter`.
    pub fn countNodesByLabel(self: *StorageAdapter, graph_name: []const u8, label: []const u8) !u64 {
        const ctx = try self.resolveLabelScanContext(graph_name, label) orelse return 0;
        const mg = ctx.mg;
        const io = std.Io.Threaded.global_single_threaded.io();

        var total: u64 = 0;
        for (mg.engine.shards, 0..) |shard, shard_idx| {
            try shard.ensureDerivedHydrated();
            mg.shard_locks[shard_idx].lockSharedUncancelable(io);
            total += shard.label_index.count(ctx.label_id);
            mg.shard_locks[shard_idx].unlockShared(io);
        }
        return total;
    }

    pub fn getNodesByLabel(self: *StorageAdapter, graph_name: []const u8, label: []const u8, allocator: Allocator) ![]u64 {
        return self.getNodesByLabelCapped(graph_name, label, null, allocator);
    }

    /// Lock-safe label slot-id collection with an optional early-termination cap.
    ///
    /// CRASH FIX (read-stress): the streaming read path previously consumed the
    /// lazy `iterateNodesByLabel` fan-out iterator, whose per-shard
    /// `LabelIndex.scan` runs with NO shard lock held. A concurrent ingest
    /// `addNode` mutating the same shard's posting set (it holds only
    /// `mg.rwlock` SHARED + `shard_locks[idx]` EXCLUSIVE — NOT the whole-graph
    /// exclusive) races the scan's count()-sized buffer fill and hash-map
    /// iteration, producing an out-of-bounds write / corrupted iteration that
    /// PANICS the whole server (observed under 64-reader + 16-writer load).
    ///
    /// This variant materializes the slot ids one shard at a time UNDER that
    /// shard's SHARED read lock (`appendLiveNodesForLabelShard`), exactly as
    /// `getNodesByLabel` already does — fencing concurrent shard writers while
    /// other readers proceed in parallel. `cap` preserves the bounded-scan
    /// early-termination the lazy iterator gave: once `cap` live slots are
    /// collected we stop probing further shards (a per-shard overshoot beyond
    /// `cap` is harmless; the caller's LIMIT/`row_cap` bounds the final rows).
    pub fn getNodesByLabelCapped(self: *StorageAdapter, graph_name: []const u8, label: []const u8, cap: ?usize, allocator: Allocator) ![]u64 {
        _ = g_label_scan_lookup_count.fetchAdd(1, .monotonic);
        const ctx = try self.resolveLabelScanContext(graph_name, label) orelse return try allocator.alloc(u64, 0);
        var result = std.ArrayList(u64).empty;
        errdefer result.deinit(allocator);

        for (ctx.mg.engine.shards, 0..) |_, shard_idx| {
            try appendLiveNodesForLabelShard(ctx.mg, shard_idx, ctx.label_id, allocator, &result);
            if (cap) |c| {
                if (result.items.len >= c) break;
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    /// Begin a CHUNKED label slot enumeration: resolve the graph + label and
    /// capture the shard count. Returns null when the graph or label does not
    /// exist (no nodes). The caller iterates `0..cursor.shard_count`, calling
    /// `appendLabelScanShard` per shard and applying its own per-slot filter +
    /// early termination between shards. The resolved `mg` handle is held for
    /// the duration exactly as `getNodesByLabelCapped` holds it across its shard
    /// loop (same lifetime exposure, same lock-safety contract).
    pub fn beginLabelScan(self: *StorageAdapter, graph_name: []const u8, label: []const u8) !?LabelScanCursor {
        const ctx = try self.resolveLabelScanContext(graph_name, label) orelse return null;
        return LabelScanCursor{
            .mg = ctx.mg,
            .label_id = ctx.label_id,
            .shard_count = ctx.mg.engine.shards.len,
        };
    }

    /// Append ONE shard's live label slots to `result`, under that shard's
    /// SHARED read lock (via `appendLiveNodesForLabelShard` — the SAME lock-safe
    /// path `getNodesByLabelCapped` uses). `shard_idx` must be < `cursor.shard_count`.
    /// The per-shard SHARED hold is internally batched (see
    /// `label_scan_batch_slots`) so a queued EXCLUSIVE apply interleaves.
    pub fn appendLabelScanShard(
        self: *StorageAdapter,
        cursor: LabelScanCursor,
        shard_idx: usize,
        allocator: Allocator,
        result: *std.ArrayList(u64),
    ) !void {
        _ = self;
        try appendLiveNodesForLabelShard(cursor.mg, shard_idx, cursor.label_id, allocator, result);
    }

    /// Number of label slots collected per per-shard SHARED-lock hold.
    ///
    /// CHUNKING (scan-writer-progress): the slot-collection scan acquires +
    /// releases `mg.shard_locks[shard_idx]` SHARED once per batch of this many
    /// posting-list entries instead of holding it across the whole O(graph)
    /// loop. The per-shard apply (`bulkInsertNode*`) takes the SAME shard lock
    /// EXCLUSIVE, so an unbounded SHARED hold starves ingest on that shard. A
    /// bounded hold lets the EXCLUSIVE apply interleave between batches (it
    /// waits at most one batch). 1024 is small enough to bound the hold to a
    /// few hundred microseconds of raw page reads, large enough to amortise the
    /// lock acquire/release and page-pin churn across the batch.
    const label_scan_batch_slots: usize = 1024;

    fn appendLiveNodesForLabelShard(
        mg: *ManagedGraph,
        shard_idx: usize,
        label_id: gs.LabelId,
        allocator: Allocator,
        result: *std.ArrayList(u64),
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();

        const shard = mg.engine.shards[shard_idx];

        // `scanLabelIter` snapshots the label's posting list into a private,
        // IMMUTABLE owned slice up front (under the LabelIndex rwlock SHARED,
        // released before it returns) and exposes a MONOTONIC cursor. So the
        // iterator itself needs no shard lock, and we may release + reacquire
        // the shard lock between batches without re-collecting or risking
        // duplicates — the cursor never rewinds and the snapshot never changes.
        var iter = try shard.scanLabelIter(label_id);
        defer iter.deinit();

        // Filter out deleted/empty nodes whose slot IDs are still present
        // in the label index.  We read raw page bytes via the buffer pool
        // and check the record flags directly — this avoids engine.getNode()
        // which conflates "empty" and "deleted" into a single null return,
        // and whose null-based filtering caused regressions in prior attempts.
        const node_mod = gs.node;
        const NodeRec = node_mod.NodeRec;
        const hdr_size = gs.node.PAGE_HEADER_SIZE;

        const nstore = &shard.node_store;
        const bp = nstore.buffer_pool;
        const npp = nstore.nodes_per_page;

        // Process the posting-list snapshot in batches. Each batch holds the
        // shard SHARED lock for at most `label_scan_batch_slots` raw page
        // reads, then RELEASES it so a queued EXCLUSIVE apply on this shard can
        // proceed before the next batch reacquires. The page pin is dropped at
        // the batch boundary WHILE the lock is still held (a pinned frame is
        // only valid under the shard lock — once released the buffer pool may
        // evict/reuse it). Re-pinning in the next batch is safe: the `nid`s are
        // an immutable snapshot, and a node deleted across the gap simply fails
        // the per-batch isDeleted/isEmpty re-check (skipped, as it would be
        // anyway). We never release mid-node: each node's flag read completes
        // under one contiguous SHARED hold, so no torn read can be exposed.
        var exhausted = false;
        while (!exhausted) {
            mg.shard_locks[shard_idx].lockSharedUncancelable(io);

            // Scan one shard at a time under that shard's read lock. This fences
            // concurrent shard writers while preserving parallel reads, and
            // avoids the previous fan-out path that could interleave raw
            // buffer-pool pins from multiple shard cursors during parallel
            // UNION planning.
            var cached_page_id: ?u64 = null;
            var cached_frame: *gs.page_frame.PageFrame = undefined;
            var cached_frame_idx: u32 = 0;

            // On any error inside the batch, drop the pin THEN release the
            // shard lock (LIFO unwind: errdefers run bottom-up).
            errdefer mg.shard_locks[shard_idx].unlockShared(io);
            errdefer if (cached_page_id != null) bp.unpin(cached_frame_idx, false);

            var in_batch: usize = 0;
            while (in_batch < label_scan_batch_slots) : (in_batch += 1) {
                const nid = (try iter.next()) orelse {
                    exhausted = true;
                    break;
                };
                const page_id = nid / npp;

                // Page not allocated → node cannot be live (stale index entry)
                if (!nstore.free_space.isAllocated(page_id)) continue;

                // Unpin cached frame when moving to a different page.
                //
                // CRITICAL: clear the cached_page_id tracking BETWEEN the old
                // unpin and the new pin. If `bp.pin` errors,
                // `cached_frame` still points at the just-unpinned old frame,
                // and the errdefer would otherwise call `unpin`
                // again on it (`bp.unpin(cached_frame_idx, false)`).
                // The buffer pool asserts `pin_count > 0` on every unpin, so
                // that double-unpin surfaces as a SIGABRT — observed under the
                // 16-way concurrent UNION DISTINCT load in
                // test_gap0814_union_parallelism.
                if (cached_page_id == null or cached_page_id.? != page_id) {
                    if (cached_page_id != null) {
                        const old_frame_idx = cached_frame_idx;
                        cached_page_id = null;
                        bp.unpin(old_frame_idx, false);
                    }
                    cached_frame = try bp.pin(.nodes, page_id);
                    cached_frame_idx = bp.frameIndex(cached_frame);
                    cached_page_id = page_id;
                }

                const slot: u32 = @intCast(nid % npp);
                const slot_offset = hdr_size + slot * @sizeOf(NodeRec);
                const data = cached_frame.dataSlice();
                const rec = std.mem.bytesToValue(NodeRec, data[slot_offset..][0..@sizeOf(NodeRec)]);

                if (node_mod.isDeleted(&rec)) continue;
                if (node_mod.isEmpty(&rec)) continue;
                // H1 instrumentation: one live slot enumerated (materialized into
                // a label-scan result). Bounded by the WHERE+LIMIT fix once the
                // caller stops requesting shards after `offset+limit` matches.
                _ = g_label_slots_enumerated.fetchAdd(1, .monotonic);
                try result.append(allocator, nid);
            }

            // Drop the page pin BEFORE releasing the shard lock — the pinned
            // frame is only valid while the lock is held.
            if (cached_page_id != null) bp.unpin(cached_frame_idx, false);
            mg.shard_locks[shard_idx].unlockShared(io);
        }
    }

    /// Return node candidates for an exact `(label, property = value)` probe.
    /// Hash collisions are tolerated because higher layers still verify the
    /// full property map before treating a candidate as a MERGE match.
    pub fn getCandidateNodesByLabelAndProperty(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        property_key: []const u8,
        value: graph_store.PropertyValue,
        allocator: Allocator,
    ) ![]u64 {
        _ = g_exact_node_property_lookup_count.fetchAdd(1, .monotonic);

        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // H4: build the exact index on first access if it was deferred at open.
        try ensureExactNodePropertyIndexBuilt(self, mg);
        const label_id = mg.label_dict.getId(label) orelse return try allocator.alloc(u64, 0);

        const storage_value = try toStorageProperty(allocator, value);
        defer freeTemporaryStorageProperty(allocator, storage_value);
        const value_hash = try hashStorageProperty(allocator, storage_value);
        const indexed = try mg.exact_node_property_index.copy(allocator, label_id, property_key, value_hash);
        defer allocator.free(indexed);

        var result = std.ArrayList(u64).empty;
        errdefer result.deinit(allocator);

        for (indexed) |node_id| {
            if (try mg.engine.getNode(node_id) == null) continue;
            try result.append(allocator, node_id);
        }

        return try result.toOwnedSlice(allocator);
    }

    /// H3-P2: register + build a value-ordered secondary index on `(label,key)`
    /// across all 16 engine shards, so ORDER BY on an indexed property can be
    /// answered by a k-way merge of the per-shard ordered cursors
    /// (`orderedScan`). Mirrors the always-on exact (hash) index: after this an
    /// indexed property is BOTH equality- and order-seekable. Idempotent per
    /// shard (the engine call no-ops re-registration and rebuilds the tree from
    /// the shard's current live nodes).
    ///
    /// The label is interned if it does not yet exist, so CREATE INDEX may run
    /// before the first node of `label` is written (the registration then
    /// maintains the tree as nodes arrive, exactly like the exact index).
    pub fn createOrderedIndex(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        key: []const u8,
    ) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const mg = try self.getOrCreateGraph(graph_name);
        const label_id = mg.label_dict.getId(label) orelse try mg.label_dict.getOrCreate(label);

        // Per-shard registration + build-from-live-scan. The engine call
        // MUTATES the shard (registers the pair, rebuilds the tree, marks it
        // dirty for the next checkpoint), so take that shard's adapter EXCLUSIVE
        // lock — the same writer discipline every other per-shard adapter write
        // uses (e.g. createNode/mergeNode).
        for (mg.engine.shards, 0..) |shard, i| {
            mg.shard_locks[i].lockUncancelable(io);
            defer mg.shard_locks[i].unlock(io);
            try shard.createOrderedIndex(label_id, key);
        }
    }

    /// H3-P2: return node ids for `(label,key)` in global value order (`dir`),
    /// up to `limit`, by a lock-safe 16-shard k-way merge of the per-shard
    /// ordered-index cursors. Caller OWNS the returned slice.
    ///
    /// Correctness: the output equals a global `std.sort` of the union of all
    /// shards' (encoded-value, node_id) keys for `(label,key)`, truncated to
    /// `limit`, in `dir` (ties are broken by node_id, which the P0 ordered
    /// encoding embeds in the key). Deleted-but-still-posted nodes are skipped
    /// via a `getNode` liveness check, and one more head is pulled so `limit` is
    /// still reached when live nodes remain.
    ///
    /// Returns an empty slice when the label is unknown or no ordered index is
    /// registered for `(label,key)` on any shard.
    ///
    /// LOCK DISCIPLINE: see `orderedScanRefill` — bounded SHARED batches per
    /// shard, `exclusiveWaitingBackoff` before each (re)acquire, keys copied out
    /// under the lock, `mg.rwlock` never held across the scan, and the liveness
    /// `getNode` runs OUTSIDE any shard lock (it takes only its own brief lock).
    pub fn orderedScan(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        key: []const u8,
        dir: OrderedScanDir,
        limit: usize,
        allocator: Allocator,
    ) ![]u64 {
        const io = std.Io.Threaded.global_single_threaded.io();

        const ctx = (try self.resolveLabelScanContext(graph_name, label)) orelse
            return try allocator.alloc(u64, 0);
        const mg = ctx.mg;
        const label_id = ctx.label_id;

        const eng_dir: OrderedDir = switch (dir) {
            .asc => .asc,
            .desc => .desc,
        };

        const shard_count = mg.engine.shards.len;
        var states: [sharded_store.SHARD_COUNT]OrderedShardState =
            [_]OrderedShardState{.{}} ** sharded_store.SHARD_COUNT;

        // Free every copied key buffer + per-shard batch list on exit (success
        // or error). Cursors need no teardown (no deinit / no buffer-pool pins).
        defer {
            for (states[0..shard_count]) |*st| {
                for (st.buf.items) |h| allocator.free(h.key);
                st.buf.deinit(allocator);
            }
        }

        var result = std.ArrayList(u64).empty;
        errdefer result.deinit(allocator);

        // Prime every shard's cursor + first batch.
        for (states[0..shard_count], 0..) |*st, i| {
            try orderedScanRefill(mg, i, label_id, key, eng_dir, st, allocator, io);
        }

        // k-way merge: repeatedly emit the extreme head across the (<=16) shards.
        // A linear select over 16 heads is O(shard_count) per emission — for a
        // fixed 16-way fan-in this is equivalent to (and simpler than) a binary
        // heap, and the per-key cost is dominated by the liveness getNode anyway.
        while (result.items.len < limit) {
            var best: ?usize = null;
            for (states[0..shard_count], 0..) |*st, i| {
                if (st.pos >= st.buf.items.len) continue; // no current head here
                if (best == null) {
                    best = i;
                    continue;
                }
                const a = st.buf.items[st.pos].key;
                const b = states[best.?].buf.items[states[best.?].pos].key;
                const ord = std.mem.order(u8, a, b);
                const a_wins = switch (dir) {
                    .asc => ord == .lt, // smallest key first
                    .desc => ord == .gt, // largest key first
                };
                if (a_wins) best = i;
            }
            const bi = best orelse break; // every shard exhausted

            const head = states[bi].buf.items[states[bi].pos];
            // Liveness: a node deleted after it was posted is still in the
            // ordered tree; skip it but keep pulling so we can still reach
            // `limit`. getNode takes only its own brief internal lock — NO shard
            // lock is held here.
            if ((try mg.engine.getNode(head.node_id)) != null) {
                try result.append(allocator, head.node_id);
            }

            states[bi].pos += 1;
            if (states[bi].pos >= states[bi].buf.items.len and !states[bi].exhausted) {
                try orderedScanRefill(mg, bi, label_id, key, eng_dir, &states[bi], allocator, io);
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    /// H3-P3: report whether a value-ordered index is registered for
    /// `(label,key)` on EVERY engine shard. The planner serves
    /// `ORDER BY <key> LIMIT` from `orderedScan` (a global 16-shard k-way merge)
    /// only when this is true — a single shard missing the ordered tree would
    /// silently drop that shard's rows from the merge, so registration must be
    /// global (ALL-shards AND). False when the graph or label is unknown.
    pub fn isOrderedIndexRegistered(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        key: []const u8,
    ) bool {
        const ctx = (self.resolveLabelScanContext(graph_name, label) catch return false) orelse
            return false;
        for (ctx.mg.engine.shards) |shard| {
            if (!shard.hasOrderedIndex(ctx.label_id, key)) return false;
        }
        return true;
    }

    /// H3-P3: report whether `ORDER BY (label,key) LIMIT` can be SAFELY served
    /// from the ordered index with full parity to the heap full-scan — i.e. the
    /// ordered index is registered AND eligible on EVERY shard. Eligibility is
    /// per-(label,key) per shard `GraphEngine` and reflects the shard's CURRENT
    /// data: a single ineligible shard (decimal/ext/NaN, bool/null, or mixed
    /// int+float in its subset) would make the global value-ordered merge drop
    /// or mis-order rows, so the gate is ALL-shards AND. On ANY doubt the caller
    /// falls back to the proven heap path. False when graph/label is unknown.
    pub fn isOrderedIndexEligible(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        key: []const u8,
    ) bool {
        const ctx = (self.resolveLabelScanContext(graph_name, label) catch return false) orelse
            return false;
        for (ctx.mg.engine.shards) |shard| {
            if (!shard.hasOrderedIndex(ctx.label_id, key)) return false;
            if (!shard.isOrderedIndexEligible(ctx.label_id, key)) return false;
        }
        return true;
    }

    /// H3-P4: report whether the ordered index is FRESH — i.e. a registered
    /// ordered index exists AND its trees reflect EVERY committed write since the
    /// last durability-boundary rebuild on EVERY shard. The online label/property
    /// hooks only mark the tree stale; the value-ordered tree is rebuilt+cleared
    /// only at the durability boundary (full checkpoint / close). A registered,
    /// eligible, but STALE tree would serve missing/mis-ordered rows, so the
    /// planner must gate on freshness and fall back to the proven heap when any
    /// shard is stale (correct, slower). Freshness is engine-global ("no
    /// un-rebuilt writes"); per-(label,key) registration is already enforced by
    /// the registered+eligible predicates the planner checks first. False when
    /// graph/label is unknown.
    pub fn isOrderedIndexFresh(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        key: []const u8,
    ) bool {
        _ = key;
        const ctx = (self.resolveLabelScanContext(graph_name, label) catch return false) orelse
            return false;
        for (ctx.mg.engine.shards) |shard| {
            if (!shard.orderedIndexFresh()) return false;
        }
        return true;
    }

    /// Test-only: force a full rebuild of the exact node-property index for
    /// `graph_name`, exactly as restart recovery does (clear + rescan every
    /// engine shard). Exposed so `test-parallel-index-rebuild` can drive the
    /// rebuild directly and assert correctness + coverage. Takes the whole-graph
    /// exclusive lock so it mirrors the no-concurrent-mutation invariant the
    /// real restart-time rebuild relies on. See `rebuildExactNodePropertyIndex`.
    pub fn rebuildExactPropertyIndexForTesting(self: *StorageAdapter, graph_name: []const u8) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        acquireWholeGraphExclusive(mg);
        defer releaseWholeGraphExclusive(mg);
        // Test-only forced rebuild: never cancellable (no read scope semantics).
        try rebuildExactNodePropertyIndex(mg, .{});
        // H4: mark the index built so a deferred graph doesn't redundantly rebuild
        // on the next ensure (mirrors ensureExactNodePropertyIndexBuilt's latch).
        mg.exact_index_built.store(true, .release);
    }

    /// Test-only: read the coverage counter from the most recent
    /// `rebuildExactNodePropertyIndex` pass on `graph_name` (equals the
    /// live-node count after a successful rebuild).
    pub fn exactIndexRebuildItersForTesting(self: *StorageAdapter, graph_name: []const u8) !u64 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.exact_index_rebuild_iters.load(.monotonic);
    }

    /// FIX #3: resolve a node id matching a label and ALL the given property
    /// filters (a composite key, e.g. `{source, source_id}`). Picks the most
    /// selective indexed filter as the candidate seed, then verifies the
    /// remaining filters against each candidate's stored properties. Returns the
    /// first match, or `missing_err` when none. Caller resolves endpoints with
    /// this under a brief read lock before the shard-locked apply.
    ///
    /// MERGE/MATCH endpoint semantics: a node matches when, for every filter,
    /// its stored property equals the filter value. Mirrors the slow path's
    /// nodeMatchesEvaluatedProps; uses the exact-property index for the seed so
    /// it is O(posting) not O(label).
    pub fn lookupNodeIdByLabelAndAllProps(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        filters: []const PropKV,
        missing_err: anyerror,
    ) !u64 {
        if (filters.len == 0) return missing_err;

        // Seed with the most selective indexed filter (smallest posting). Fall
        // back to the first filter if none is indexed (posting len 0/absent).
        //
        // EDGE-PHASE WEDGE FIX (2026-06-24): AUTHORITATIVE unique-key MISS
        // short-circuit. The match is an AND of equalities, so if ANY filter
        // whose key the exact index COVERS (`shouldIndexProperty` — a registered
        // merge key, or every key when lean indexing is off) has a posting of
        // ZERO for its value, then NO node has that (label,key,value) and the
        // composite match is unsatisfiable — return `missing_err` WITHOUT
        // scanning. Before this, a dangling composite endpoint (e.g. the
        // from-dump edge phase's `{source, source_id}` where `source_id` is
        // absent) skipped the zero-posting `source_id` (the `len > 0` seed
        // guard) and instead SEEDED on the low-selectivity `source` (~N nodes
        // share one value), then verified all ~N candidates with a per-candidate
        // `getNodeProperty`. Under the bounded node cache each verify is an
        // engine-direct disk page pin, and the whole O(N) scan runs while the
        // bulk path (`executeBulkMatchMergeEdge`) holds the per-graph rwlock
        // SHARED — so the periodic checkpoint's EXCLUSIVE `tryLock` never sees a
        // reader-free instant (geode_nodes_total stuck at 0) and the edge
        // workers thrash the buffer pool making ~0 progress: the edge-phase
        // wedge captured via live gdb (`best_len = N`, `seed_idx = 0`, all
        // workers parked in `BufferPool.pin`). This mirrors the executor path's
        // `seekMultiNodeCandidate` authoritative-miss (KNOWN BUG #2); the bulk
        // resolver was the missed copy.
        //
        // GAP-0334 correctness: a posting of 0 is authoritative ONLY for an
        // indexed key. A non-indexed key's `countCandidate...` also returns 0
        // (the index does not cover it) — that is NOT a "no such node" signal,
        // so it must NEVER short-circuit. A unique posting of 1 is a real node
        // (possibly CREATEd, hence absent from the 1:1 merge index but present
        // in the exact index) and is verified normally below, never treated as a
        // miss.
        var seed_idx: usize = 0;
        var best_len: usize = std.math.maxInt(usize);
        for (filters, 0..) |f, i| {
            const len = self.countCandidateNodesByLabelAndProperty(graph_name, label, f.key, f.value) catch continue;
            if (len == 0) {
                // Authoritative miss only when the exact index covers this key.
                if (graph_store.shouldIndexProperty(f.key)) return missing_err;
                continue;
            }
            if (len < best_len) {
                best_len = len;
                seed_idx = i;
            }
        }

        const candidates = try self.getCandidateNodesByLabelAndProperty(graph_name, label, filters[seed_idx].key, filters[seed_idx].value, self.allocator);
        defer self.allocator.free(candidates);

        for (candidates) |node_id| {
            _ = g_lookup_all_props_candidates_scanned.fetchAdd(1, .monotonic);
            var all_match = true;
            for (filters, 0..) |f, i| {
                if (i == seed_idx) continue; // seed already matched via the index
                // getNodeProperty returns a STORAGE-domain PropertyValue (owns
                // .string/.ext bytes); convert to the high-level domain to
                // compare with the filter (a graph_store.PropertyValue).
                const stored = (self.getNodeProperty(graph_name, node_id, f.key, self.allocator) catch null) orelse {
                    all_match = false;
                    break;
                };
                defer freeOwnedStorageProperty(self.allocator, stored);
                const actual = fromStorageProperty(self.allocator, stored) catch {
                    all_match = false;
                    break;
                };
                defer property_codec.freePropertyValue(self.allocator, actual);
                if (!propertyValuesEqual(actual, f.value)) {
                    all_match = false;
                    break;
                }
            }
            if (all_match) return node_id;
        }
        return missing_err;
    }

    /// PUBLIC-ID composite-key resolver for the bulk relationship-MERGE endpoint
    /// path (`executeBulkMatchMergeEdge`). Resolves a node matching `label` and
    /// ALL `filters` (a composite key, e.g. `{source, source_id}`) and returns
    /// its **GraphStore public node id** — the id space `store.nodes` / the
    /// shard-locked edge MERGE apply (`bulkMergeEdgeWithIdsShardLockedForTenant`)
    /// operate in.
    ///
    /// EDGE-PHASE COMMIT FIX (2026-06-24): the sibling
    /// `lookupNodeIdByLabelAndAllProps` returns ENGINE-SLOT ids (from the exact
    /// property index, validated via `mg.engine.getNode`). Passing those to the
    /// edge MERGE apply, which does `store.nodes.getPtr(id)` (a public-id map),
    /// MISSED every endpoint → `error.SourceNodeNotFound` → the bulk MERGE-edge
    /// fast path silently orphan-skipped EVERY edge (the from-dump edge phase
    /// committed ZERO edges even with both endpoints loaded — a pre-existing bug
    /// independent of the O(N)-scan wedge). The CREATE-edge fast path avoids this
    /// by deferring resolution to the coordinator's `lookupNodeByMergeKey`
    /// (public-id space); this resolver gives the MERGE-edge path the same
    /// correct id space.
    ///
    /// Mirrors the executor's `match_operations.seekMultiNodeCandidate`:
    ///   * Authoritative unique-key MISS (an indexed filter with ZERO postings)
    ///     short-circuits to `missing_err` — the dangling-endpoint fast-negative
    ///     that also prevents the O(N) scan wedge.
    ///   * Resolves the seed via `store.lookupMergeCandidate` (public id), with
    ///     the GAP-0334 fallback: a unique exact posting (len 1) whose value is
    ///     absent from the 1:1 merge index (a CREATEd node) is NOT a miss — fall
    ///     back to the public-id-space scan to find it.
    ///   * Verifies the remaining filters against each candidate's stored
    ///     properties (public-id `store.getNodeProperty`), so WHICH node matches
    ///     is identical to the scan path.
    pub fn lookupPublicNodeIdByLabelAndAllProps(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        filters: []const PropKV,
        missing_err: anyerror,
    ) !u64 {
        if (filters.len == 0) return missing_err;
        const store = graph_store.getGlobalStore(graph_store.global_allocator());

        // COMPOSITE fast path (caveat "B"): if the filter set EXACTLY matches a
        // registered composite merge key (the from-dump {source, source_id}
        // endpoint key), resolve the WHOLE key in ONE resident merge-index probe
        // — NO getNodeProperty / NO node-page read — and verify existence via the
        // eviction-INDEPENDENT IdMap only. This is the zero-buffer-pool-pin hot
        // path that makes the from-dump edge phase run at enterprise speed at any
        // scale, and is collision-correct (source_id is not globally unique).
        if (graph_store.compositeKeyIndexForFilters(filters)) |composite_idx| {
            var cid: u64 = 0;
            switch (store.lookupCompositeMergeCandidate(graph_name, label, composite_idx, filters, &cid)) {
                .found => {
                    // Existence already validated against the IdMap inside
                    // lookupCompositeMergeCandidate (resolveNodeGraphSlot); the
                    // composite key encodes ALL filters, so no per-filter verify.
                    // This is the from-dump hot path: ZERO getNodeProperty.
                    return cid;
                },
                // AUTHORITATIVE composite MISS (FIX #1 of the 14.27M edge-ingest
                // wedge). The filter set EXACTLY matches a REGISTERED composite
                // merge key, so the composite index is the AUTHORITATIVE oracle
                // for that key: it captures BOTH `source` AND `source_id`, and the
                // index is COMPLETE — EVERY path that gives a live node the full
                // composite writes the entry: bulk create
                // (setNodePropertiesBatchInMemoryOnly), single set
                // (setNodeProperty), rollback / Raft-restore set
                // (setNodePropertyNoSave — GAP-A), reopen-load
                // (loadOneGraphFromAdapter, ALL nodes), index rebuild, and
                // late-registration backfill; it is removed on delete and on
                // composite-component removal (removeNodeProperty[NoSave] —
                // GAP-B); and `merge_prop_index` is process-wide and NOT evicted,
                // so the entry survives node-cache eviction. Therefore a composite
                // MISS ⇒ NO node carries that exact {source, source_id} ⇒ return
                // missing_err IMMEDIATELY: ZERO seed+verify fall-through and ZERO
                // getNodeProperty / BufferPool property-page reads.
                //
                // This is precisely what fixes the indexfungorum (source #7)
                // wedge: a dangling/cross-source target whose `source_id`
                // COLLIDES under a DIFFERENT source defeats the seed-side
                // dangling-O(1)-miss (830c0c45) — `source_id` has a posting, so
                // the seed resolves the wrong-source node and the old fall-through
                // verified `source` via getNodeProperty → BufferPool.pin →
                // deadlock at 14.27M. The composite captures BOTH props, so it
                // cannot be fooled by the collision: the {indexfungorum, X}
                // composite simply is not present → authoritative miss, no pool
                // read. (Mirrors the seed-side authoritative dangling-miss, but at
                // the composite level where it is collision-correct.)
                .not_found => return missing_err,
                // NOT a "no such node" signal: the composite cannot ENCODE this
                // probe (an unserializable value type) even though the filter
                // NAMES matched a registered composite. Fall through to the
                // generic seed+verify path, which verifies ALL filters (stays
                // collision-correct) — never reached for the from-dump
                // string-keyed {source, source_id}.
                .not_indexable => {},
            }
        }

        // Seed selection + authoritative-miss (same contract as
        // lookupNodeIdByLabelAndAllProps — see its comment).
        var seed_idx: usize = 0;
        var best_len: usize = std.math.maxInt(usize);
        for (filters, 0..) |f, i| {
            const len = self.countCandidateNodesByLabelAndProperty(graph_name, label, f.key, f.value) catch continue;
            if (len == 0) {
                if (graph_store.shouldIndexProperty(f.key)) return missing_err;
                continue;
            }
            if (len < best_len) {
                best_len = len;
                seed_idx = i;
            }
        }

        // Try the O(1) public-id merge-index seek on the seed when it is UNIQUE
        // (posting <= 1). A unique seed resolved via the merge index gives the
        // single public id directly; verify the remaining filters on it.
        if (best_len <= 1 and graph_store.shouldIndexProperty(filters[seed_idx].key)) {
            var seed_id: u64 = 0;
            switch (store.lookupMergeCandidate(graph_name, label, filters[seed_idx].key, filters[seed_idx].value, &seed_id)) {
                .found => {
                    if (try self.publicNodeMatchesRemaining(graph_name, store, seed_id, filters, seed_idx)) return seed_id;
                    return missing_err;
                },
                // Merge index miss but the exact index has it (best_len==1) ⇒ a
                // CREATEd node not in the 1:1 merge index (GAP-0334). Fall
                // through to the public-id scan to find it.
                .not_found, .not_indexable => {},
            }
        }

        // Public-id-space candidate scan over the label posting: verify ALL
        // filters (including the seed) per candidate. Reached only for a
        // non-unique seed or the GAP-0334 CREATE-seeded fallback (a node present
        // in the exact index but not the 1:1 merge index). The from-dump
        // endpoint key {source, source_id} has a UNIQUE source_id, so the O(1)
        // merge-seek above handles the hot path; this O(label) scan is the rare
        // correctness fallback, not the steady state.
        const label_nodes = store.getNodesByLabel(graph_name, label) orelse return missing_err;
        for (label_nodes) |node_id| {
            var all_match = true;
            for (filters) |f| {
                // Engine-direct single-property verify by slot — NO full-node
                // hydration (Phase 2). Same de-hydration as the merge-seek verify.
                if (!self.publicNodeFilterMatchesNoHydrate(graph_name, store, node_id, f)) {
                    all_match = false;
                    break;
                }
            }
            if (all_match) return node_id;
        }
        return missing_err;
    }

    /// Verify a single `(f.key == f.value)` filter against the PUBLIC node id's
    /// stored property WITHOUT full-materializing the node into the bounded
    /// node cache (Phase 2: de-hydrate endpoint resolution — the gdb hot path).
    ///
    /// `store.getNodeProperty(node_id, key)` reads the property via
    /// `getOrHydratePtr` → `materializeNodeFromEngine`, which rebuilds the ENTIRE
    /// candidate node (labels + ALL properties via the PropertyChain) and INSERTS
    /// it into the bounded cache. At cache << dataset that is one full-node
    /// materialize per endpoint resolution (`hydrations_total` grew ~1 per edge),
    /// the dominant cost that made edge ingest glacial.
    ///
    /// Instead resolve the public id → engine slot via the eviction-INDEPENDENT
    /// IdMap and read exactly THAT ONE property by slot via the adapter's
    /// engine-direct `getNodeProperty(graph_name, slot, key)` — it reads a single
    /// PropertyChain key and does NOT insert the node into the bounded cache.
    /// Mirrors the slot-id sibling `lookupNodeIdByLabelAndAllProps`'s verify.
    ///
    /// Fallback: a pure in-memory deployment with no adapter/IdMap (engine
    /// absent) keeps the resident `store.getNodeProperty` — there the node cache
    /// is never bounded (no hydrate hook without an engine), so the resident read
    /// is itself hydration-free and correct.
    fn publicNodeFilterMatchesNoHydrate(
        self: *StorageAdapter,
        graph_name: []const u8,
        store: *graph_store.GraphStore,
        node_id: u64,
        f: PropKV,
    ) bool {
        if (store.getIdMap(graph_name)) |id_map| {
            if (id_map.nodeSlot(@as(u128, node_id))) |slot| {
                // Engine-direct single-property read (no cache insert).
                // getNodeProperty returns a STORAGE-domain PropertyValue (owns
                // .string/.ext bytes); convert + compare like the slot sibling.
                const stored = (self.getNodeProperty(graph_name, slot, f.key, self.allocator) catch null) orelse return false;
                defer freeOwnedStorageProperty(self.allocator, stored);
                const actual = fromStorageProperty(self.allocator, stored) catch return false;
                defer property_codec.freePropertyValue(self.allocator, actual);
                return propertyValuesEqual(actual, f.value);
            }
        }
        // No engine/IdMap: resident read (unbounded cache in this mode).
        const actual = store.getNodeProperty(node_id, f.key) orelse return false;
        return propertyValuesEqual(actual, f.value);
    }

    /// Verify every filter EXCEPT `seed_idx` against the public-id node's stored
    /// properties (the seed already matched via the index/merge probe). Reads
    /// each property engine-direct by slot — NO full-node hydration (Phase 2).
    fn publicNodeMatchesRemaining(
        self: *StorageAdapter,
        graph_name: []const u8,
        store: *graph_store.GraphStore,
        node_id: u64,
        filters: []const PropKV,
        seed_idx: usize,
    ) !bool {
        for (filters, 0..) |f, i| {
            if (i == seed_idx) continue;
            if (!self.publicNodeFilterMatchesNoHydrate(graph_name, store, node_id, f)) return false;
        }
        return true;
    }

    /// Cheap selectivity probe for an exact `(label, property = value)` posting.
    /// Returns the raw posting-list length (including any stale entries) without
    /// copying the list or touching the engine — used by the read fast path to
    /// pick the most selective indexed inline property before the real seek.
    /// Returns 0 when the label is unknown or the posting is absent.
    pub fn countCandidateNodesByLabelAndProperty(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        property_key: []const u8,
        value: graph_store.PropertyValue,
    ) !usize {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // H4: build the exact index on first access if it was deferred at open.
        try ensureExactNodePropertyIndexBuilt(self, mg);
        const label_id = mg.label_dict.getId(label) orelse return 0;

        const storage_value = try toStorageProperty(self.allocator, value);
        defer freeTemporaryStorageProperty(self.allocator, storage_value);
        const value_hash = try hashStorageProperty(self.allocator, storage_value);
        return (try mg.exact_node_property_index.postingLenIfPresent(label_id, property_key, value_hash)) orelse 0;
    }

    /// GAP-ENT-0043 T1: one distinct-value posting of the exact node-property
    /// index for a given `(label, property_key)` pair. `count` is the posting
    /// length (== the number of live nodes carrying that value — the index is
    /// maintained on every set/update/delete); `representative_slot` is one
    /// member of the posting, used by the index-served aggregate fast path to
    /// recover the actual property VALUE with a single engine-direct
    /// single-property read (the index keys by value HASH, not value bytes).
    pub const PropertyPostingSummary = struct {
        value_hash: u64,
        representative_slot: u64,
        count: u64,
    };

    /// GAP-ENT-0043 T1: collect the distinct-value posting summaries for
    /// `(label, property_key)` from the IN-MEMORY MAINTAINED exact
    /// node-property index — O(distinct values) output, ZERO node
    /// materialization, no engine reads.
    ///
    /// Soundness gates (the source-split lesson — never read a deferred-empty
    /// structure):
    ///   * `ensureExactNodePropertyIndexBuilt` runs FIRST, so an H4-deferred
    ///     index is built from the durable pages before the walk (same latch
    ///     every exact-index seek uses);
    ///   * an unknown label (never interned) returns an empty slice — there
    ///     are no nodes with that label, so there are no postings;
    ///   * callers MUST additionally gate on `graph_store.shouldIndexProperty`
    ///     (index completeness per key in lean mode) — this walk reports what
    ///     the index CONTAINS and cannot know whether the key was skipped.
    ///
    /// The walk takes each of the 64 shard mutexes once (stable order), so it
    /// observes a per-shard-consistent snapshot; concurrent writers block only
    /// for the duration of one shard's iteration.
    pub fn collectPropertyPostingSummaries(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        property_key: []const u8,
        allocator: Allocator,
    ) ![]PropertyPostingSummary {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // H4: build the exact index on first access if it was deferred at open.
        try ensureExactNodePropertyIndexBuilt(self, mg);
        const label_id = mg.label_dict.getId(label) orelse
            return try allocator.alloc(PropertyPostingSummary, 0);

        var out = std.ArrayList(PropertyPostingSummary).empty;
        errdefer out.deinit(allocator);

        const io = std.Io.Threaded.global_single_threaded.io();
        const expected_key_len = 4 + 4 + property_key.len + 8;
        for (&mg.exact_node_property_index.shards) |*shard| {
            shard.mutex.lockUncancelable(io);
            defer shard.mutex.unlock(io);
            var it = shard.postings.iterator();
            while (it.next()) |entry| {
                // Encoded key layout (encodeKeyInto):
                // [label_id: u32][key_len: u32][key bytes][value_hash: u64]
                const key = entry.key_ptr.*;
                if (key.len != expected_key_len) continue;
                if (std.mem.readInt(u32, key[0..4], .little) != label_id) continue;
                if (std.mem.readInt(u32, key[4..8], .little) != property_key.len) continue;
                if (!std.mem.eql(u8, key[8 .. 8 + property_key.len], property_key)) continue;
                const value_hash = std.mem.readInt(u64, key[8 + property_key.len ..][0..8], .little);
                const posting = entry.value_ptr.items;
                if (posting.len == 0) continue; // empty postings are removed; defensive
                try out.append(allocator, .{
                    .value_hash = value_hash,
                    .representative_slot = posting[0],
                    .count = posting.len,
                });
            }
        }
        return out.toOwnedSlice(allocator);
    }

    // ------------------------------------------------------------------
    // Edge property operations
    // ------------------------------------------------------------------

    /// Set a property on an edge.
    ///
    /// R12 (2026-04-22): when a session/statement engine txn is active
    /// on this graph, replicate the engine's `setEdgeProperty` logic
    /// using `putPropertyTxn` + adjacency-list updates so the whole
    /// operation joins the active txn and incurs NO extra WAL fsync.
    /// Without this branch, the engine's auto-commit variant runs
    /// `txn_manager.begin()` + `commit()` (and thus one `wal.sync()`)
    /// per edge property — for a msft-graph edge with 5 properties and
    /// 2186 edges per batch that's >10K fsyncs per batch, overwhelming
    /// the 120 s `acquireGraphWriteLockCancelable` budget.
    pub fn setEdgeProperty(
        self: *StorageAdapter,
        graph_name: []const u8,
        from_id: u64,
        to_id: u64,
        edge_id: u64,
        key: []const u8,
        value: graph_store.PropertyValue,
    ) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        const storage_val = try toStorageProperty(self.allocator, value);
        defer freeTemporaryStorageProperty(self.allocator, storage_val);

        // Edges live on the source node's shard.
        const from_shard = mg.shardEngineForNode(from_id);
        if (currentStatementTxnForGraph(graph_name)) |s| {
            // R12: manual setEdgeProperty using Txn variants, routed to the
            // from_id's shard. Mirrors engine_edge_props.setEdgeProperty 1:1.
            const edge_entry = (try from_shard.edge_index.get(edge_id)) orelse return error.EdgeNotFound;
            if (edge_entry.from != from_id or edge_entry.neighbor != to_id) return error.EdgeNotFound;

            const from_rec = (try from_shard.node_store.getNode(from_id)) orelse return error.NodeNotFound;
            const found_prop_head = edge_entry.prop_head;

            // Use shard-local txn from the statement txn if shards match.
            const local_txn = shardLocalTxnForNode(s.txn_id, from_id) orelse try from_shard.beginTxn();
            const own_txn = shardLocalTxnForNode(s.txn_id, from_id) == null;
            // error-policy: A — best-effort rollback on an already-failing path.
            errdefer if (own_txn) from_shard.abortTxn(local_txn) catch {};

            // GAP-ENT-0020 (P7a): edge prop_heads are packed as u32 in
            // adjacency entries + the edge index, which cannot represent a
            // slab head — edge chains must stay LEGACY (one page-chain per
            // edge) even with slab_packing ON. Node writes keep putPropertyTxn.
            const new_head_u64 = try from_shard.putPropertyLegacyTxn(@as(u64, found_prop_head), key, storage_val, local_txn);
            const new_head: u32 = std.math.cast(u32, new_head_u64) orelse return error.Overflow;

            if (new_head != found_prop_head) {
                _ = try from_shard.adj_out.updateEdgePropHead(from_rec.out_head, edge_id, new_head);
                // For cross-shard edges, to_node is on a different shard; for
                // same-shard edges both adj lists are on from_shard.
                const to_shard = mg.shardEngineForNode(to_id);
                const to_rec = (try to_shard.node_store.getNode(to_id)) orelse return error.NodeNotFound;
                _ = try to_shard.adj_in.updateEdgePropHead(to_rec.in_head, edge_id, new_head);

                // v0.2.26: copy-on-write API (getPtr removed — mmap base is
                // immutable). Also set edge_index_dirty (the F1 blessed-stale
                // lesson): this manual mirror mutates the index outside
                // engine_edge_props.setEdgeProperty, so the restamp gate must
                // see it dirty or a checkpoint would re-bless a stale snapshot.
                try from_shard.edge_index.updatePropHead(edge_id, new_head);
                from_shard.edge_index_dirty = true;
            }

            if (found_prop_head != 0 and found_prop_head != new_head) {
                from_shard.property_index.removeChain(found_prop_head);
            }
            try from_shard.refreshPropertyChainIndex(new_head_u64);
            if (own_txn) try from_shard.commitTxn(local_txn);
            return;
        }

        // No active statement txn — open a local txn on the source shard
        // and replicate the same cross-shard-aware logic above.
        // The fallback `mg.engine.setEdgeProperty(from_id, to_id, edge_id, ...)`
        // routes to `shards[shardOfNode(from)].setEdgeProperty(...)`, whose
        // `engine_edge_props.setEdgeProperty` does
        // `engine.node_store.getNode(to)` against the SOURCE shard. For
        // cross-shard edges (from and to on different shards) the to node
        // does not exist on from_shard, so the call raises NodeNotFound and
        // every inline `CREATE (a)-[:R]->(b) RETURN ...` (where the
        // persistEdgePublicId post-hook is the only setter) crashes.
        const fb_edge_entry = (try from_shard.edge_index.get(edge_id)) orelse return error.EdgeNotFound;
        if (fb_edge_entry.from != from_id or fb_edge_entry.neighbor != to_id) return error.EdgeNotFound;

        const fb_from_rec = (try from_shard.node_store.getNode(from_id)) orelse return error.NodeNotFound;
        const fb_found_prop_head = fb_edge_entry.prop_head;

        const fb_local_txn = try from_shard.beginTxn();
        // error-policy: A — best-effort rollback on an already-failing path.
        errdefer from_shard.abortTxn(fb_local_txn) catch {};

        // GAP-ENT-0020 (P7a): edge chains stay legacy — see the txn branch above.
        const fb_new_head_u64 = try from_shard.putPropertyLegacyTxn(@as(u64, fb_found_prop_head), key, storage_val, fb_local_txn);
        const fb_new_head: u32 = std.math.cast(u32, fb_new_head_u64) orelse return error.Overflow;

        if (fb_new_head != fb_found_prop_head) {
            _ = try from_shard.adj_out.updateEdgePropHead(fb_from_rec.out_head, edge_id, fb_new_head);
            const fb_to_shard = mg.shardEngineForNode(to_id);
            const fb_to_rec = (try fb_to_shard.node_store.getNode(to_id)) orelse return error.NodeNotFound;
            _ = try fb_to_shard.adj_in.updateEdgePropHead(fb_to_rec.in_head, edge_id, fb_new_head);

            // v0.2.26 copy-on-write + dirty flag (see the txn-path comment).
            try from_shard.edge_index.updatePropHead(edge_id, fb_new_head);
            from_shard.edge_index_dirty = true;
        }

        if (fb_found_prop_head != 0 and fb_found_prop_head != fb_new_head) {
            from_shard.property_index.removeChain(fb_found_prop_head);
        }
        try from_shard.refreshPropertyChainIndex(fb_new_head_u64);
        try from_shard.commitTxn(fb_local_txn);
    }

    /// Set or remove multiple properties on an edge under a single mutex
    /// acquisition.  Edge counterpart to `setNodePropertiesBatch`
    /// (line 2031).
    ///
    /// Task #34 (2026-04-24): avoid the O(K²) cost of the per-property
    /// `setEdgeProperty` loop in bulk-ingest.  Each property in the
    /// old loop did:
    ///   * one adapter mutex acquire → `requireExistingGraphLocked`,
    ///   * one linear `adj_out.updateEdgePropHead` scan,
    ///   * one linear `adj_in.updateEdgePropHead` scan,
    ///   * one `refreshPropertyChainIndex` walking all previously-written
    ///     properties — the O(K²)/edge amplifier.
    ///
    /// The batch collapses all of that to:
    ///   * one adapter mutex acquire,
    ///   * N `putPropertyTxn` calls (each unavoidable),
    ///   * exactly one `updateEdgePropHead(adj_out)` + one
    ///     `updateEdgePropHead(adj_in)` at the end for the terminal
    ///     `prop_head` (intermediate heads are never read),
    ///   * exactly one `refreshPropertyChainIndex` at the end.
    ///
    /// Joins an active `StatementTxn` on this graph (parity with
    /// `setNodePropertiesBatch` + `setEdgeProperty`) so the whole batch
    /// commits with the caller's single WAL fsync.
    pub fn setEdgePropertiesBatch(
        self: *StorageAdapter,
        graph_name: []const u8,
        edge_id: u64,
        entries: []const BatchPropertyEntry,
    ) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };

        // Edges live on the source-node's shard (edge_id is shard-striped
        // by allocNode on the source shard).
        const from_shard = mg.shardEngineForNode(edge_id);
        const edge_entry = (try from_shard.edge_index.get(edge_id)) orelse return error.EdgeNotFound;
        const from_id = edge_entry.from;
        const to_id = edge_entry.neighbor;
        const from_rec = (try from_shard.node_store.getNode(from_id)) orelse return error.NodeNotFound;
        const orig_prop_head: u32 = edge_entry.prop_head;

        // R8/R12 parity: one txn on from_shard for all N property writes.
        const stmt_txn = currentStatementTxnForGraph(graph_name);
        const local_txn: gs.TxnId = if (stmt_txn) |s|
            shardLocalTxnForNode(s.txn_id, from_id) orelse try from_shard.beginTxn()
        else
            try from_shard.beginTxn();
        const own_txn = stmt_txn == null or shardLocalTxnForNode(stmt_txn.?.txn_id, from_id) == null;
        errdefer if (own_txn) {
            // error-policy: A — best-effort rollback on an already-failing path.
            from_shard.abortTxn(local_txn) catch {};
        };

        var running_prop_head: u32 = orig_prop_head;
        var last_new_head_u64: u64 = @as(u64, orig_prop_head);
        for (entries) |entry| {
            const storage_val: gs.PropertyValue = if (entry.value) |val|
                try toStorageProperty(self.allocator, val)
            else
                .null;
            defer if (entry.value != null) freeTemporaryStorageProperty(self.allocator, storage_val);

            // GAP-ENT-0020 (P7a): edge chains stay legacy (u32 prop_head) —
            // see setEdgeProperty. Node writes keep the slab-eligible path.
            const new_head_u64 = try from_shard.putPropertyLegacyTxn(@as(u64, running_prop_head), entry.key, storage_val, local_txn);
            running_prop_head = std.math.cast(u32, new_head_u64) orelse return error.Overflow;
            last_new_head_u64 = new_head_u64;
        }

        if (running_prop_head != orig_prop_head) {
            _ = try from_shard.adj_out.updateEdgePropHead(from_rec.out_head, edge_id, running_prop_head);
            const to_shard = mg.shardEngineForNode(to_id);
            const to_rec = (try to_shard.node_store.getNode(to_id)) orelse return error.NodeNotFound;
            _ = try to_shard.adj_in.updateEdgePropHead(to_rec.in_head, edge_id, running_prop_head);

            // v0.2.26 copy-on-write + dirty flag (see the txn-path comment).
            try from_shard.edge_index.updatePropHead(edge_id, running_prop_head);
            from_shard.edge_index_dirty = true;
        }

        if (orig_prop_head != 0 and orig_prop_head != running_prop_head) {
            from_shard.property_index.removeChain(orig_prop_head);
        }
        try from_shard.refreshPropertyChainIndex(last_new_head_u64);

        if (own_txn) try from_shard.commitTxn(local_txn);
    }

    /// Get a property from an edge. Delegates to the engine's
    /// `getEdgeProperty` which handles adjacency list scanning internally.
    pub fn getEdgeProperty(
        self: *StorageAdapter,
        graph_name: []const u8,
        from_id: u64,
        edge_id: u64,
        key: []const u8,
        allocator: Allocator,
    ) !?gs.PropertyValue {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.engine.getEdgeProperty(from_id, edge_id, key, allocator);
    }

    /// PHASE 1 (edge-engine-direct): the engine-side record for an edge,
    /// addressed by its ENGINE edge slot. Resolves the full edge-index entry
    /// (endpoints + rel-type + prop_head) and the rel-type's label string from
    /// the per-graph label dictionary, so geode's bounded-edge-cache hydrate can
    /// rebuild an evicted `Edge` body without a resident mirror. `label` is a
    /// caller-OWNED dupe (free with `allocator`); the slots are ENGINE slots
    /// (geode maps them back to public ids via its IdMap). Returns null if the
    /// edge slot is unknown to the engine (e.g. concurrently removed).
    pub const EdgeRecord = struct {
        from_slot: u64,
        to_slot: u64,
        rel_type: u32,
        prop_head: u32,
        label: []u8,
    };

    pub fn getEdgeRecordBySlot(
        self: *StorageAdapter,
        graph_name: []const u8,
        edge_slot: u64,
        allocator: Allocator,
    ) !?EdgeRecord {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // Edges live on the source-node's shard: the edge slot is shard-striped
        // by allocNode on the source shard, so shardOfNode(edge_slot) == source
        // shard (same addressing setEdgePropertiesBatch / getAllEdgeProperties
        // rely on).
        const from_shard = mg.shardEngineForNode(edge_slot);
        const idx_entry = (try from_shard.edge_index.get(edge_slot)) orelse return null;
        const label_str = mg.label_dict.getString(idx_entry.rel_type) orelse "UNKNOWN";
        const label_copy = try allocator.dupe(u8, label_str);
        return EdgeRecord{
            .from_slot = idx_entry.from,
            .to_slot = idx_entry.neighbor,
            .rel_type = idx_entry.rel_type,
            .prop_head = idx_entry.prop_head,
            .label = label_copy,
        };
    }

    /// GAP typed-edge enumeration (`getEdgesByType` under a bounded edge
    /// cache): append the PUBLIC id of every live edge of `rel_type` in
    /// `graph_name` to `out` by scanning each shard's edge_index — the
    /// merged mmap-BASE ⊕ OVERLAY ⊖ tombstones view via
    /// `EdgeIndexMap.forEachLive`. ONE O(total edges) sequential index-record
    /// scan: NO node iteration, NO adjacency hydration, and NO edge-body /
    /// property pages for v2 edges (each 40-byte index record already carries
    /// `rel_type` and the inline `public_id`). Legacy entries
    /// (`public_id == 0`, pre-v0.2.24 stores) fall back to the persisted
    /// `__geode_internal_edge_id` property read off the source shard —
    /// counted via `graph_store.edge_id_property_fallback_reads`, exactly
    /// like every other inline-first reader (loop1, adjacency hydrate, MERGE
    /// dedup probe).
    ///
    /// Graph scoping is structural: each geode graph owns its own
    /// ShardedGraphEngine, so scanning `graph_name`'s shards can never see
    /// another graph's edges. Tenant filtering stays with the CALLER
    /// (graph_store), which compares the hydrated edge body's tenant tag —
    /// the engine index carries no tenant information.
    ///
    /// An unseen `rel_type` (absent from the graph's label dictionary) has no
    /// edges of that type — returns without touching any shard.
    pub fn collectEdgePublicIdsByType(
        self: *StorageAdapter,
        graph_name: []const u8,
        rel_type: []const u8,
        allocator: Allocator,
        out: *std.ArrayList(u64),
    ) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        const rel_label_id = mg.label_dict.getId(rel_type) orelse return;

        const Ctx = struct {
            out: *std.ArrayList(u64),
            alloc: Allocator,
            rel: u32,
            shard: *gs.GraphEngine,
        };
        for (mg.engine.shards) |shard| {
            // Phase A (deferred derived indexes): materialize this shard's
            // edge_index before iterating it, mirroring every other
            // edge_index reader in the engine (getEdge / edgeIndexCount).
            try shard.ensureDerivedHydrated();
            var ctx = Ctx{ .out = out, .alloc = allocator, .rel = rel_label_id, .shard = shard };
            try shard.edge_index.forEachLive(&ctx, struct {
                fn visit(c: *Ctx, edge_slot: u64, entry: gs.engine.EdgeIndexEntry) anyerror!void {
                    if (entry.rel_type != c.rel) return;
                    if (entry.public_id != 0) {
                        try c.out.append(c.alloc, entry.public_id);
                        return;
                    }
                    // Legacy (v1 / pre-inline) edge: resolve the public id
                    // from the persisted property on the source shard.
                    _ = graph_store.edge_id_property_fallback_reads.fetchAdd(1, .monotonic);
                    const stored = (c.shard.getEdgeProperty(
                        entry.from,
                        edge_slot,
                        graph_store.INTERNAL_EDGE_ID_PROPERTY_KEY,
                        c.alloc,
                    ) catch null) orelse return; // orphan / not-yet-mapped: skip
                    defer freeOwnedStorageProperty(c.alloc, stored);
                    switch (stored) {
                        .string => |text| {
                            const pid = graph_store.parsePersistedPublicId(text) orelse return;
                            try c.out.append(c.alloc, pid);
                        },
                        else => {},
                    }
                }
            }.visit);
        }
    }

    // ------------------------------------------------------------------
    // Full node scanning
    // ------------------------------------------------------------------

    /// A single entry from a full node scan.
    pub const ScanEntry = struct {
        slot_id: u64,
        rec: gs.node.NodeRec,
    };

    /// Scan all live nodes in the named graph. Returns a caller-owned
    /// slice of `ScanEntry` values. Uses the engine's efficient
    /// page-scan iterator (one pin per page rather than per node).
    pub fn scanAllNodes(self: *StorageAdapter, graph_name: []const u8, allocator: Allocator) ![]ScanEntry {
        // Brief mutex hold: look up ManagedGraph, then release.
        // The ManagedGraph pointer is heap-allocated and only freed by
        // dropGraph (under mutex), so using it after unlock is safe.
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };

        const Ctx = struct {
            entries: std.ArrayList(ScanEntry),
            alloc: Allocator,
            had_error: bool = false,

            fn onNode(ctx: *@This(), node_id: u64, rec: gs.node.NodeRec) void {
                ctx.entries.append(ctx.alloc, .{ .slot_id = node_id, .rec = rec }) catch {
                    ctx.had_error = true;
                };
            }
        };

        // Fan out across all shards — each shard owns a disjoint node_id range.
        var ctx = Ctx{ .entries = .empty, .alloc = allocator };
        for (mg.engine.shards) |shard| {
            try shard.node_store.scanNodes(shard.manifest.next_node_id, &ctx, &Ctx.onNode);
        }

        if (ctx.had_error) return error.OutOfMemory;

        return ctx.entries.toOwnedSlice(allocator);
    }

    // ------------------------------------------------------------------
    // Hydration fast-scan surface (GAP hydration streaming)
    // ------------------------------------------------------------------

    /// Number of per-shard engines behind the named graph (the unit of
    /// hydration stream-scan parallelism). Errors if the graph is unknown.
    pub fn hydrationStreamShardCount(self: *StorageAdapter, graph_name: []const u8) !usize {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.engine.shards.len;
    }

    /// Stream-scan ONE shard's store files sequentially and return the
    /// decoded per-shard accumulation (see hydration_scan.zig for the pass
    /// structure and the direct-pager-read justification). Read-only against
    /// the engine; safe to run for different shards on dedicated threads
    /// (each shard owns its files and buffer pool).
    pub fn hydrationStreamScanShard(
        self: *StorageAdapter,
        graph_name: []const u8,
        shard_idx: usize,
        allocator: Allocator,
        opts: hydration_scan.ScanOptions,
    ) !hydration_scan.ShardAccum {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return hydration_scan.scanShard(allocator, mg.engine.shards[shard_idx], opts);
    }

    /// Resolve a raw label/rel-type id to its dictionary string, or null when
    /// the id is unknown (the hydration merge mirrors getNodeLabels' drop-
    /// unknown-ids rule for node labels and the legacy "UNKNOWN" fallback for
    /// edge rel types). The returned slice is owned by the dictionary and
    /// stable for the adapter's lifetime — callers dupe what they keep.
    pub fn hydrationLabelString(self: *StorageAdapter, graph_name: []const u8, label_id: u32) ?[]const u8 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.requireExistingGraphLocked(graph_name) catch return null;
        };
        return mg.label_dict.getString(label_id);
    }

    // ------------------------------------------------------------------
    // Statistics API
    // ------------------------------------------------------------------

    /// Aggregate statistics for a single graph, sourced from the engine
    /// manifest.
    pub const GraphStats = struct {
        node_count: u64,
        edge_count: u64,
        pages_used: u64,
        label_count: u32,
    };

    /// Return manifest-level statistics for the named graph, or null if
    /// the graph is not loaded.
    pub fn getGraphStats(self: *StorageAdapter, graph_name: []const u8) ?GraphStats {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.requireExistingGraphLocked(graph_name) catch return null;
        };
        // Aggregate stats across all per-shard manifests.
        var node_count: u64 = 0;
        var edge_count: u64 = 0;
        var pages_used: u64 = 0;
        var label_count: u32 = 0;
        for (mg.engine.shards) |shard| {
            const m = &shard.manifest;
            node_count += m.node_count;
            edge_count += m.edge_count;
            pages_used += m.nodes_pages + m.adj_out_pages + m.adj_in_pages +
                m.props_pages + m.var_pages + m.free_pages;
            if (m.label_count > label_count) label_count = m.label_count;
        }

        return .{
            .node_count = node_count,
            .edge_count = edge_count,
            .pages_used = pages_used,
            .label_count = label_count,
        };
    }

    /// PHASE 1b crash-safety gate: return an aggregate (sum over all shards) of
    /// the per-shard `manifest.counter` for the named graph, or null if the
    /// graph is not loaded. Each shard's `counter` bumps once per durable
    /// checkpoint, so the sum changes whenever ANY shard advances. An IdMap
    /// snapshot stamped with this aggregate is valid IFF the value matches on
    /// reopen (no committed write happened since the snapshot was written);
    /// any mismatch/absence => caller falls back to the scan-rebuild.
    pub fn graphManifestCounter(self: *StorageAdapter, graph_name: []const u8) ?u64 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.requireExistingGraphLocked(graph_name) catch return null;
        };
        return mgManifestCounter(mg);
    }

    // ------------------------------------------------------------------
    // Property iteration
    // ------------------------------------------------------------------

    /// Return all properties on a node as a hash map. Keys are
    /// heap-allocated copies owned by the map; values are converted
    /// geode `PropertyValue` instances. The caller owns the returned
    /// map and must free each key/value plus the map itself.
    pub fn getAllNodeProperties(
        self: *StorageAdapter,
        graph_name: []const u8,
        node_id: u64,
        allocator: Allocator,
    ) !std.StringHashMap(gs.PropertyValue) {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;

        var result = std.StringHashMap(gs.PropertyValue).init(allocator);
        errdefer result.deinit();

        if (rec.prop_head == 0) return result;

        // Single-pass zero-copy iteration: the PropIterator yields each
        // property's key and pre-encoded value bytes directly from pinned
        // page frames.  We decode the value inline (allocating only for
        // string/ext payloads that must outlive the iterator) instead of
        // the previous two-pass pattern (collect keys → re-fetch each).
        // Read via the node's shard — see addNodePropertiesForLabels.
        var iter = try mg.shardEngineForNode(node_id).getAllProperties(rec.prop_head);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            if (!shouldExposePropertyKey(entry.key)) continue;
            const decoded = try gs.property.decode(allocator, entry.encoded_value);
            const owned_key = try allocator.dupe(u8, entry.key);
            try result.put(owned_key, decoded.value);
        }

        return result;
    }

    /// Return all properties for an edge given its `prop_head` pointer.
    /// Works identically to `getAllNodeProperties` but takes a raw
    /// `prop_head` instead of looking up a node record — edge property
    /// heads come directly from the `EdgeEntry` returned by the
    /// adjacency iterator.
    ///
    /// `from_id` is the source node's id (edges live on the source's
    /// shard). Required because prop_head IDs are NOT shard-striped
    /// (FreeSpaceManager hands out 1, 2, 3, ... per shard), so routing
    /// via `mg.engine.getAllProperties(prop_head)` would land on the
    /// wrong shard. See `addNodePropertiesForLabels` for the same fix
    /// on the node side (commit 2385894c).
    pub fn getAllEdgeProperties(
        self: *StorageAdapter,
        graph_name: []const u8,
        from_id: u64,
        prop_head: u32,
        allocator: Allocator,
    ) !std.StringHashMap(gs.PropertyValue) {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };

        var result = std.StringHashMap(gs.PropertyValue).init(allocator);
        errdefer result.deinit();

        if (prop_head == 0) return result;

        const prop_head_u64: u64 = @intCast(prop_head);

        // Route via the source node's shard — same per-shard engine
        // that wrote the property pages.
        var iter = try mg.shardEngineForNode(from_id).getAllProperties(prop_head_u64);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            if (!shouldExposePropertyKey(entry.key)) continue;
            const decoded = try gs.property.decode(allocator, entry.encoded_value);
            const owned_key = try allocator.dupe(u8, entry.key);
            try result.put(owned_key, decoded.value);
        }

        return result;
    }

    // ------------------------------------------------------------------
    // Transaction operations
    // ------------------------------------------------------------------

    /// Begin a new transaction in the named graph.
    pub fn beginTransaction(self: *StorageAdapter, graph_name: []const u8) !u64 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.engine.beginTxn();
    }

    /// Commit a transaction.
    pub fn commitTransaction(self: *StorageAdapter, graph_name: []const u8, txn_id: u64) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        try mg.engine.commitTxn(txn_id);
    }

    /// Abort (rollback) a transaction.
    pub fn abortTransaction(self: *StorageAdapter, graph_name: []const u8, txn_id: u64) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        try mg.engine.abortTxn(txn_id);
    }

    /// Run a checkpoint on every loaded graph engine.
    /// Full checkpoint of every graph (backward-compatible wrapper).
    ///
    /// Used by the CLEAN-SHUTDOWN path and explicit/test callers so a restart
    /// loads the derived indexes from disk without a rebuild.
    pub fn checkpointAll(self: *StorageAdapter) !void {
        return self.checkpointAllEx(false, true);
    }

    /// GAP-0900 Layer-2: incremental/bounded checkpoint of every graph.
    ///
    /// Runs the LIGHT engine checkpoint (flush dirty pages, sync, manifest, WAL
    /// truncate, free store, label dict, declared B+tree indexes) but SKIPS the
    /// O(graph-size) derived-index snapshot save. This keeps the periodic
    /// load-driven checkpoint O(dirty) so it can keep pace during a multi-million
    /// node ingest in deferred mode (the full derived-index re-save was O(graph)
    /// and fell behind, letting the WAL + dirty pages grow until OOM). On reopen,
    /// graph-storage rebuilds the stale derived indexes from the durable pages.
    pub fn checkpointAllLight(self: *StorageAdapter) !void {
        return self.checkpointAllEx(true, true);
    }

    /// GAP-ENT-0048 (task0048d) test-only: is `name`'s adapter engine currently
    /// resident in `self.engines`? A graph served entirely from loop2/counter
    /// snapshots is NOT loaded (false) even though it exists on disk — the exact
    /// condition that made a FULL checkpoint skip its exact-index persist.
    pub fn isGraphEngineLoadedForTesting(self: *StorageAdapter, name: []const u8) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.engines.contains(name);
    }

    /// GAP-ENT-0048g test-only: remove the on-disk `prop_exact.idx` for a loaded
    /// graph to force the DEFERRED condition. Since GAP-ENT-0048g a LIGHT
    /// checkpoint KEEPS a current-stamped index (the counter gate handles
    /// staleness), so tests can no longer use `checkpointAllLight` to drop it.
    pub fn invalidateExactIndexFileForTesting(self: *StorageAdapter, graph_name: []const u8) void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.requireExistingGraphLocked(graph_name) catch return;
        };
        if (graphDirPath(self.allocator, self.data_dir, mg.uuid)) |dir_path| {
            defer self.allocator.free(dir_path);
            invalidateExactPropertyIndexFile(self.allocator, dir_path);
        } else |_| {}
    }

    /// GAP-ENT-0048 (task0048d): open the adapter engine of every registry graph
    /// that is not yet loaded, so a FULL checkpoint covers on-disk graphs that
    /// were served this whole session from loop2/counter snapshots (which never
    /// open the adapter engine — the `divelife` skip). MUST be called with
    /// `self.mutex` held (mutates `self.engines` via `requireExistingGraphLocked`).
    ///
    /// Registry names are snapshotted into a local buffer FIRST: opening a graph
    /// calls `upsertRegistryEntryLocked`, which updates the matching entry
    /// in place (never frees the name, never appends — the name already exists),
    /// so the captured `[]const u8` name slices stay valid and no reallocation of
    /// `registry.entries.items` occurs mid-iteration.
    fn forceLoadRegistryGraphsForFullCheckpointLocked(self: *StorageAdapter) void {
        var names_buf: [64][]const u8 = undefined;
        var n: usize = 0;
        for (self.registry.entries.items) |entry| {
            if (n >= names_buf.len) break;
            if (self.engines.contains(entry.name)) continue;
            names_buf[n] = entry.name;
            n += 1;
        }
        for (names_buf[0..n]) |nm| {
            _ = self.requireExistingGraphLocked(nm) catch |err| {
                log.warn("full checkpoint: could not load graph '{s}' to persist its exact index: {s}", .{ nm, @errorName(err) });
                continue;
            };
            _ = g_full_checkpoint_forced_loads.fetchAdd(1, .monotonic);
            slog.info("full checkpoint force-loaded snapshot-served graph for exact-index persist", &.{
                SAttr.string("graph", nm),
            });
        }
    }

    /// Core checkpoint implementation.
    ///
    /// * `light` — when true each graph runs the bounded `engine.checkpointLight()`
    ///   instead of the full `engine.checkpoint()`.
    /// * `set_writer_pref` — when true the checkpoint announces (per graph, via
    ///   `mg.exclusive_waiting`) that it is waiting for the EXCLUSIVE lock so the
    ///   SHARED apply/read paths back off (`exclusiveWaitingBackoff`) and
    ///   drain the reader set, letting this checkpoint's bounded `tryLock` spin win
    ///   even under 16+ continuous writers. GAP-0900 bug #1: `std.Io.RwLock` has no
    ///   native writer preference, so without this the LIGHT checkpoint's bounded
    ///   `tryLock` never observes a reader-free instant, SKIPS every cycle, and
    ///   `pending_bulk_ops` grows without bound → OOM. The flag is always cleared
    ///   (defer) once this graph's lock is acquired or the deadline is hit, so a
    ///   slow/stuck checkpoint can never block writers indefinitely. Pass false to
    ///   suppress the back-off (e.g. unit tests of the raw lock protocol).
    pub fn checkpointAllEx(self: *StorageAdapter, light: bool, set_writer_pref: bool) !void {
        // Collect ManagedGraph pointers under brief mutex hold.
        var graphs_buf: [64]*ManagedGraph = undefined;
        var graph_count: usize = 0;
        {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            // GAP-ENT-0048 (task0048d): a FULL checkpoint (clean shutdown /
            // explicit save) must build+persist the exact index for EVERY on-disk
            // graph — including one served this whole session from loop2/counter
            // snapshots, which NEVER opens its adapter engine and is therefore
            // absent from `self.engines`. The loop below iterates only loaded
            // engines, so such a graph (the 14.27M `divelife` case) was silently
            // skipped and never got a `prop_exact.idx`. Force-load every registry
            // graph not yet resident so it is checkpointed and, if its exact index
            // is deferred, eager-built from its durable store pages.
            if (!light) self.forceLoadRegistryGraphsForFullCheckpointLocked();
            var it = self.engines.valueIterator();
            while (it.next()) |mg| {
                if (graph_count < graphs_buf.len) {
                    graphs_buf[graph_count] = mg.*;
                    graph_count += 1;
                }
            }
        }

        // Checkpoint each graph WITHOUT holding the adapter mutex.
        // The ManagedGraph pointers remain valid because graphs are only
        // removed via dropGraph which also holds self.mutex.
        // IMPORTANT: Acquire the per-graph EXCLUSIVE write lock during
        // checkpoint. The bulk-ingest write path mutates the shared indexes
        // (label_index, edge_index, …) while holding mg.rwlock in SHARED mode
        // (see bulkMergeNodeWithReservedId*: striped per-tuple lock + rwlock
        // SHARED). A SHARED checkpoint lock does NOT exclude those SHARED
        // writers, so engine.checkpoint() → label_index.saveToFile → scan()
        // iterated hash maps that a concurrent addNode() resized mid-scan,
        // producing `index out of bounds` / use-after-free panics that CRASHED
        // the server under high write concurrency (e.g. divelife bulk seed at
        // 32+ connections). The EXCLUSIVE lock drains in-flight writers and
        // blocks new ones for the duration of the snapshot, giving a
        // consistent, race-free view. Lock ordering is safe: writers take
        // tuple_lock → rwlock; checkpoint takes only rwlock (and never
        // self.mutex here), so there is no ABBA cycle.
        //
        // NOTE: the snapshot's disk I/O runs while the exclusive lock is held,
        // so writers pause for the checkpoint duration. Correctness over a
        // crash; a future optimisation can snapshot under the lock and write
        // outside it.
        // GAP-0900 bug #2 (backpressure correctness): track whether ANY graph's
        // LIGHT checkpoint was skipped because its rwlock stayed busy past the
        // deadline. If so we must NOT reset `pending_bulk_ops` to 0 at the end —
        // dirty pages for the skipped graph are still un-flushed, and zeroing the
        // counter would tell the backpressure path "all drained", letting the
        // dirty-page set grow without bound under sustained contention (the exact
        // OOM this fix prevents). Leaving the counter high re-fires the inline
        // trigger immediately and keeps writers backpressured until a checkpoint
        // actually lands. With bug #1's writer-preference the skip should not
        // happen, but this keeps the memory bound sound even if it ever does.
        var any_skipped = false;
        for (graphs_buf[0..graph_count]) |mg| {
            // Bounded rwlock deadline for the periodic LIGHT checkpoint;
            // unbounded (null) for the durability-critical FULL checkpoint.
            const timeout_ns: ?u64 = if (light) 5 * std.time.ns_per_s else null;
            switch (self.checkpointOneGraph(mg, light, set_writer_pref, timeout_ns)) {
                .ok, .engine_failed => {},
                // GAP-0900 bug #2: an rwlock-deadline skip leaves the graph's
                // dirty pages un-flushed — any_skipped keeps the backpressure
                // counter high (see below). An engine checkpoint FAILURE is
                // handled exactly as before the extraction: logged inside,
                // loop continues, pending_bulk_ops still reset.
                .skipped_busy => any_skipped = true,
            }
        }

        // Collect manifest counts LOCKLESSLY (no per-graph rwlock, no mutex),
        // then sync the registry under the adapter mutex (no rwlock).
        //
        // EDGE-PHASE 40001 FIX #1 (2026-06-22): this phase MUST NOT take the
        // per-graph rwlock SHARED. At 14.27M scale `pending_bulk_ops` stays
        // high post-NODE-ingest, so the persistence loop fires this checkpoint
        // back-to-back; a recurring SHARED acquire here is a near-constant
        // reader on the graph. `std.Io.RwLock.tryLock` (the edge phase's
        // EXCLUSIVE acquire — CREATE INDEX ON :Taxon(source_id) and the
        // relationship MERGE — at acquireGraphWriteLockCancelable) FAILS
        // whenever `reader_mask != 0` (RwLock.zig:31), so under this recurring
        // reader the exclusive `tryLock` never observed a reader-free instant
        // within its 2-minute deadline -> `40001: Write lock acquisition timed
        // out`. Captured live via gdb on PID 1703302: checkpoint thread parked
        // in lockSharedUncancelable@here, edge exclusive spinning in
        // tryLock@5686.
        //
        // SAFETY: `shard.manifest.node_count`/`edge_count` are plain `u64`
        // monotone-ish metadata. They are mutated only inside per-shard engine
        // txns (single-writer per shard) and the cross-shard edge delete path
        // already mutates `manifest.edge_count` WITHOUT the per-graph rwlock
        // (graph_storage_adapter.zig:1236), so the SHARED lock here never
        // actually fenced all writers of these fields — it only fenced the
        // EXCLUSIVE checkpoint section. We read them with `@atomicLoad(...,
        // .monotonic)`, which is a well-defined, tear-free load of an aligned
        // u64 (a plain `mov` on x86-64) — strictly safer than the prior plain
        // read. A slightly-stale registry count is acceptable: this is
        // introspection metadata persisted to the on-disk graph registry, not
        // a correctness-critical value (the durable pages are the source of
        // truth and the counts are recomputed from them on reopen). Removing
        // the rwlock acquire eliminates the recurring reader entirely, which
        // alone unblocks the edge phase; FIX #2 (exclusive_waiting writer
        // preference) hardens the remaining SHARED read paths.
        var counts_buf: [64]struct { name: []const u8, uuid: [16]u8, node_count: u64, edge_count: u64 } = undefined;
        for (graphs_buf[0..graph_count], 0..) |mg, i| {
            var nc: u64 = 0;
            var ec: u64 = 0;
            for (mg.engine.shards) |shard| {
                nc += @atomicLoad(u64, &shard.manifest.node_count, .monotonic);
                ec += @atomicLoad(u64, &shard.manifest.edge_count, .monotonic);
            }
            counts_buf[i] = .{
                .name = mg.name,
                .uuid = mg.uuid,
                .node_count = nc,
                .edge_count = ec,
            };
        }
        {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            for (counts_buf[0..graph_count]) |c| {
                self.upsertRegistryEntryLocked(c.name, c.uuid, c.node_count, c.edge_count);
            }
            self.saveRegistryLocked() catch |err| {
                log.warn("failed to persist graph registry: {}", .{err});
            };
        }

        // GAP-0900: a checkpoint has landed — record the observable and reset
        // the cadence state so the next `maybeCheckpoint` decision starts from
        // a clean slate (pending ops drained, clock restarted).
        //
        // GAP-0900 bug #2: only zero `pending_bulk_ops` if EVERY graph was
        // actually checkpointed. If any graph was skipped (rwlock busy past the
        // LIGHT deadline) its dirty pages are still un-flushed, so we leave the
        // counter where it is — the inline trigger re-fires immediately and the
        // backpressure path keeps writers bounded until a checkpoint truly drains
        // the dirty set. (`checkpoints_total` still advances so observability and
        // the "a checkpoint cycle ran" signal remain truthful.)
        _ = self.checkpoints_total.fetchAdd(1, .monotonic);
        if (!any_skipped) {
            self.pending_bulk_ops.store(0, .release);
        }
        self.last_checkpoint_mono_ns.store(monoNanosNow(), .release);
    }

    /// Outcome of a single-graph checkpoint pass (`checkpointOneGraph`).
    const OneGraphCheckpointOutcome = enum {
        /// Engine checkpoint (and exact-index persist/invalidate + retired-
        /// cache reclaim) completed under the EXCLUSIVE per-graph rwlock.
        ok,
        /// The bounded rwlock-acquisition deadline expired — NOTHING was done
        /// for this graph (no lock held, no state touched). The caller decides
        /// whether to retry (periodic LIGHT cycle) or degrade (hydration
        /// persist-on-complete).
        skipped_busy,
        /// The lock was acquired but the ENGINE checkpoint itself failed
        /// (already logged). The exact-index persist and cache reclaim still
        /// ran, mirroring the historical checkpointAllEx behaviour.
        engine_failed,
    };

    /// Checkpoint ONE managed graph — the per-graph body of `checkpointAllEx`,
    /// extracted so the Task 3 hydration persist-on-complete path
    /// (`checkpointGraph`) can run a FULL checkpoint for a single graph
    /// without touching every other graph's rwlock.
    ///
    /// * `light` — bounded `engine.checkpointLight()` vs full `engine.checkpoint()`.
    /// * `set_writer_pref` — announce the EXCLUSIVE intent on
    ///   `mg.exclusive_waiting` so SHARED apply/read paths back off (GAP-0900
    ///   bug #1). Always cleared on exit (defer).
    /// * `acquire_timeout_ns` — bounded rwlock-acquisition deadline (relative);
    ///   null spins unboundedly (the durability-critical clean-shutdown FULL
    ///   path). The acquisition NEVER parks on the RwLock semaphore — see the
    ///   HANG FIX below.
    fn checkpointOneGraph(
        self: *StorageAdapter,
        mg: *ManagedGraph,
        light: bool,
        set_writer_pref: bool,
        acquire_timeout_ns: ?u64,
    ) OneGraphCheckpointOutcome {
        const _t_start = monoNanosNow();
        // GAP-0900 bug #1: announce that this checkpoint wants the EXCLUSIVE
        // lock so the SHARED apply/read paths back off and drain the reader
        // set (see `exclusiveWaitingBackoff` + `mg.exclusive_waiting`).
        // `fetchAdd`/`fetchSub` (counter) so this composes with the
        // edge-phase exclusive acquirers that announce on the same counter.
        // Cleared on every exit path (defer), so a slow/skipped checkpoint
        // never leaves readers backing off forever (safety valve).
        if (set_writer_pref) {
            _ = mg.exclusive_waiting.fetchAdd(1, .release);
        }
        defer if (set_writer_pref) {
            _ = mg.exclusive_waiting.fetchSub(1, .release);
        };
        // HANG FIX (2026-06-21, sustained-ingest single-conn wedge): the
        // periodic GAP-0900 checkpoint reached this site via
        // walCheckpointHook → checkpointAllEx and parked unboundedly on the
        // raw `mg.rwlock.lockUncancelable(io)`. That call's protocol
        // (std/Io/RwLock.zig `lockUncancelable`) registers the writer, sets
        // `is_writing`, then — if it observed ANY reader at that instant —
        // parks FOREVER on the RwLock's internal counting semaphore waiting
        // for the last reader's `unlockShared` to `post()`. A single missed
        // `post()` (the same lost-wakeup already fixed for
        // `acquireGraphWriteLockCancelable` @~5496 and
        // `acquireWholeGraphExclusive` @~6310) wedges the writer
        // permanently; it keeps the RwLock's internal mutex, so every
        // subsequent shard-apply reader (`bulkMergeNodeWithReservedId*` →
        // `rwlock.lockSharedUncancelable`) blocks behind it. The bulk MERGE
        // apply never completes → its ApplyResult.done never fires → the
        // submitter parks in `awaitOp` → the connection response is never
        // written → the client wedges in ReceiveProto. Reproduced
        // deterministically (single QUIC conn, ~26.6K MERGE ops) and
        // captured live via gdb: checkpoint thread in
        // `Io.Semaphore.waitUncancelable`, RwLock state reader=1/is_writing
        // with ZERO reader threads on any stack.
        //
        // The fix mirrors the two existing exclusive acquirers: never park
        // on the semaphore — re-probe via `tryLock`, which reads `rl.state`
        // directly (no semaphore) and is immune to the lost wakeup. A bounded
        // caller (periodic LIGHT cycle / hydration persist-on-complete) skips
        // this graph after the deadline; an unbounded caller (clean shutdown /
        // explicit FULL checkpoint) spins via `tryLock` so durability is never
        // sacrificed.
        const io_cp = std.Io.Threaded.global_single_threaded.io();
        if (!mg.rwlock.tryLock(io_cp)) {
            var sleep_ns: u64 = 100 * std.time.ns_per_us;
            const max_sleep_ns: u64 = 2 * std.time.ns_per_ms;
            const cp_deadline_ns: ?u64 = if (acquire_timeout_ns) |t| _t_start + t else null;
            var acquired = false;
            while (true) {
                if (cp_deadline_ns) |dl| {
                    if (monoNanosNow() >= dl) break;
                }
                const req = std.os.linux.timespec{
                    .sec = @intCast(sleep_ns / std.time.ns_per_s),
                    .nsec = @intCast(sleep_ns % std.time.ns_per_s),
                };
                var rem: std.os.linux.timespec = undefined;
                _ = std.os.linux.nanosleep(&req, &rem);
                if (mg.rwlock.tryLock(io_cp)) {
                    acquired = true;
                    break;
                }
                sleep_ns = @min(sleep_ns * 2, max_sleep_ns);
            }
            if (!acquired) {
                // Bounded deadline exhausted under sustained contention — skip
                // THIS graph this cycle (no hang, no lock held). The periodic
                // LIGHT trigger retries next cycle; the hydration persist path
                // degrades to the next full checkpoint.
                _ = mg.rwlock_exclusive_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
                const busy_state = @atomicLoad(usize, &mg.rwlock.state, .seq_cst);
                // GAP-ENT-0038: structured logger — this skip warning was a
                // `std.log.warn`, compiled out of ReleaseFast, so a graph
                // whose LIGHT checkpoints were being starved would look
                // exactly like a healthy silent cadence in the server log.
                slog.warn("bounded checkpoint skipped: rwlock busy past deadline (will retry)", &.{
                    SAttr.string("graph", mg.name),
                    SAttr.uint("rwlock_state", @intCast(busy_state)),
                });
                return .skipped_busy;
            }
        }
        _ = mg.rwlock_exclusive_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
        // GAP-0900 L2: the periodic load-driven trigger runs the LIGHT engine
        // checkpoint (O(dirty)); the shutdown / explicit path runs the FULL
        // checkpoint so a restart loads the derived indexes without a rebuild.
        // NOTE (Task 3): the FULL `engine.checkpoint()` is itself a no-op when
        // neither pages nor derived-index dirty flags are set (gs
        // checkpointEx early-return), so a read-only hydration of a clean
        // store does NOT bump the manifest counter or strand counter-stamped
        // snapshots.
        var engine_ok = true;
        if (light) {
            mg.engine.checkpointLight() catch |err| {
                log.warn("light checkpoint failed for graph '{s}': {}", .{ mg.name, err });
                engine_ok = false;
            };
        } else {
            mg.engine.checkpoint() catch |err| {
                log.warn("checkpoint failed for graph '{s}': {}", .{ mg.name, err });
                engine_ok = false;
            };
        }
        // Persist the exact property index alongside the engine checkpoint.
        // This is a FULL O(graph) re-serialize, so the light (periodic) path
        // skips it to stay O(dirty). The on-disk prop_exact.idx is removed
        // instead so a reopen (the file has no staleness counter) falls back
        // to rebuildExactNodePropertyIndex from the durable pages rather than
        // loading a stale snapshot. The clean-shutdown FULL checkpoint always
        // rewrites it fresh, so a clean restart still loads it without a rebuild.
        if (graphDirPath(self.allocator, self.data_dir, mg.uuid)) |dir_path| {
            if (!light) {
                // GAP-ENT-0048 (task0048d) diagnostic: one line per graph at every
                // FULL checkpoint so the 14.27M run can see WHY a graph is or is
                // not exact-index-persisted (name, durable manifest node count,
                // already-built vs deferred). The eager-build helper logs the
                // grace-probe / build-ran outcome for the deferred case.
                var mnc: u64 = 0;
                for (mg.engine.shards) |shard| mnc += @atomicLoad(u64, &shard.manifest.node_count, .monotonic);
                slog.info("full checkpoint: exact-index persist decision", &.{
                    SAttr.string("graph", mg.name),
                    SAttr.uint("manifest_node_count", mnc),
                    SAttr.string("state", if (mg.exact_index_built.load(.acquire)) "built" else "deferred"),
                });
            }
            if (light) {
                // GAP-ENT-0048g: KEEP a stamped `prop_exact.idx` across LIGHT
                // checkpoints instead of DELETING it. The manifest-counter stamp
                // (saveToFile/loadFromFile) makes a stale copy un-loadable on
                // reopen, so a delete is no longer needed for correctness — and
                // the delete is exactly what dropped the hydration-built index at
                // 14.27M (P1). We also do NOT re-save here: that is O(graph) and
                // would defeat the O(dirty) LIGHT contract. A LIGHT checkpoint that
                // dirtied pages bumps the manifest counter, which naturally
                // invalidates the now-stale on-disk stamp for the next reopen; a
                // no-op (clean) LIGHT leaves a current-stamped index reloadable.
            } else if (mg.exact_index_built.load(.acquire)) {
                mg.exact_node_property_index.saveToFile(dir_path, mgManifestCounter(mg)) catch |err| {
                    log.warn("failed to persist property index for graph '{s}': {}", .{ mg.name, err });
                };
            } else if (self.eagerBuildDeferredIndexForFullCheckpoint(mg)) {
                // GAP-ENT-0048 PRIMARY: the exact index was DEFERRED this session
                // (no/stale snapshot at open) and never built by a query — so the
                // in-memory index is EMPTY. Rather than invalidate the file and
                // leave the deferral in place FOREVER (every reopen then re-pays
                // the O(graph) first-access rebuild, which at 14.27M nodes blows
                // past the ~60 s proto-reader stall window and wedges the handler
                // — the escalation's read-path blocker), a FULL checkpoint (clean
                // shutdown / explicit save) EAGERLY builds the index from the
                // durable pages IN PARALLEL (reusing rebuildExactNodePropertyIndex's
                // per-shard thread-pool machinery — we hold mg.rwlock EXCLUSIVE, so
                // the scan is race-free) and latches `built`. We then fall through
                // to persist the COMPLETE snapshot below. This also supersedes the
                // old "never persist an EMPTY snapshot" hazard: we persist a
                // materialised, non-empty index, not the empty in-memory one.
                mg.exact_node_property_index.saveToFile(dir_path, mgManifestCounter(mg)) catch |err| {
                    log.warn("failed to persist eagerly-built property index for graph '{s}': {}", .{ mg.name, err });
                };
            } else {
                // Deferred and NOT eagerly built (empty graph — nothing to build —
                // or an in-flight first-touch hydration whose pages are mid-write:
                // scanning them here would be the C-1 use-after-free). Remove any
                // stale on-disk index so the next open DEFERS + rebuilds lazily
                // (correct, just not yet fast); the next clean FULL checkpoint of a
                // hydrated graph will materialise the snapshot.
                invalidateExactPropertyIndexFile(self.allocator, dir_path);
            }
            self.allocator.free(dir_path);
        } else |err| {
            log.warn("failed to build graph dir path for property index persist '{s}': {}", .{ mg.name, err });
        }
        // bound-node-mirror grace point: we hold mg.rwlock EXCLUSIVE here,
        // which has drained all rwlock-holding readers of this graph's nodes.
        // Free the node cache's retired (evicted/overwritten) entries for
        // THIS graph now — no such reader can hold a pointer to them. This
        // bounds resident RSS to ~cache cap + retire backlog since the last
        // checkpoint.
        //
        // TWO independent gates protect an in-flight first-touch hydration
        // (it runs under entry.mutex + hydration_build_mutex and never takes
        // mg.rwlock, yet its merge family threads read shallow Node copies
        // whose sub-heaps live on exactly these retire lists — reclaiming
        // mid-merge is the 14.27M SEGV bomb #2 / C-1 review UAF):
        //  1. hasUnfinishedHydration: graph-scoped `done`-latch predicate —
        //     catches THIS graph's build even between mutex-held phases.
        //  2. tryBeginCacheReclaimGrace: NON-BLOCKING tryLock of the store's
        //     hydration_build_mutex — catches any concurrent build touching
        //     the shared retire machinery (parking here under the graph-
        //     exclusive rwlock would starve readers for a multi-hour build).
        // Skipping is always safe: the backlog survives to the next grace
        // window (typically the persist-on-complete graph checkpoint fired
        // right after hydration finishes, which reclaims with done == true).
        if (graph_store.getCurrentGlobalStore()) |store| {
            if (store.hasUnfinishedHydration(mg.name)) {
                _ = g_hydration_reclaim_skips.fetchAdd(1, .monotonic);
                slog.info("checkpoint grace window: retired-cache reclaim skipped (hydration in flight)", &.{
                    SAttr.string("graph", mg.name),
                });
            } else if (store.tryBeginCacheReclaimGrace()) {
                defer store.endCacheReclaimGrace();
                store.reclaimNodeCacheRetiredForGraph(mg.name);
                // PHASE 0: same grace boundary for the bounded adjacency caches.
                // We hold mg.rwlock EXCLUSIVE, draining all SHARED readers of this
                // graph, so any `[]const u64` adjacency slice handed to an
                // in-flight reader of THIS graph is no longer live — free this
                // graph's retired (evicted/removed) adjacency lists now.
                store.reclaimAdjCacheRetiredForGraph(mg.name);
                // PHASE 1: same grace boundary for the bounded edge-body cache.
                // Under the same EXCLUSIVE mg.rwlock (all SHARED readers of THIS
                // graph drained), any `*Edge` handed to an in-flight reader of
                // this graph is no longer live — free this graph's retired
                // (evicted/removed) edge bodies now. One consistent grace window
                // covers nodes + adjacency + edges.
                store.reclaimEdgeCacheRetiredForGraph(mg.name);
            } else {
                // GAP-ENT-0038 discipline: a silently skipped grace point must
                // be visible — a build that overlaps every cycle would
                // otherwise look like a healthy cadence while the retire
                // backlog grows.
                _ = g_hydration_reclaim_skips.fetchAdd(1, .monotonic);
                slog.info("cache reclaim skipped: hydration build in flight (retire backlog deferred to next checkpoint)", &.{
                    SAttr.string("graph", mg.name),
                });
            }
        }
        mg.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());
        return if (engine_ok) .ok else .engine_failed;
    }

    /// GAP-ENT-0048 PRIMARY: at a FULL checkpoint, EAGERLY materialise a
    /// deferred-but-unbuilt exact node-property index from the durable pages so
    /// the caller can persist a COMPLETE `prop_exact.idx` (making the next reopen
    /// an O(snapshot) reload instead of a client-facing O(graph) rebuild).
    ///
    /// Returns `true` when it built and latched the index (caller persists),
    /// `false` when the build was skipped or failed (caller invalidates the
    /// stale file and the graph stays deferred — correct, just not yet fast).
    ///
    /// MUST be called only from `checkpointOneGraph`'s FULL (non-light) path,
    /// which holds `mg.rwlock` EXCLUSIVE — draining all SHARED readers so the
    /// per-shard node-store scan is race-free (the same no-concurrent-mutation
    /// invariant `rebuildExactPropertyIndexForTesting` relies on). The rebuild is
    /// PARALLEL (one scan task per engine shard on the shared thread pool) and
    /// uncancellable (empty CancelFlags — a checkpoint build has no read scope).
    ///
    /// The rebuild scans the DURABLE store pages (`node_store.scanNodes` →
    /// buffer pool → disk), so it does NOT require the graph to be resident /
    /// hydrated — it covers a graph that is POPULATED ON DISK but not fully in
    /// memory (the 14.27M lazily-hydrated main graph). The buffer pool is
    /// bounded, so the scan does not spike RSS to the fully-resident set.
    ///
    /// Skips (returns false) only when the graph has NO durable nodes (manifest
    /// count 0) — nothing to build; persisting an empty snapshot is pointless.
    ///
    /// GAP-ENT-0048e — NO hydration grace gate. Earlier iterations gated this on
    /// the store-wide `hydration_build_mutex` (via `tryBeginCacheReclaimGrace`),
    /// which was the WRONG gate and permanently skipped the build at clean
    /// shutdown: a hydration task still holds that mutex during the shutdown
    /// checkpoint window, so the tryLock failed and — there being no "next
    /// checkpoint" at shutdown — the index was never built. The grace gate was
    /// inherited from the checkpoint's cache-RECLAIM path, which FREES the bounded
    /// caches' per-graph retire lists that an in-flight hydration merge's shallow
    /// Node copies point into (the C-1 UAF). This store-scan build is a DIFFERENT
    /// operation and is safe to run concurrently with a hydration:
    ///   * It touches NONE of the C-1 UAF surface — no bounded node/adj/edge cache,
    ///     no retire lists, no shallow-Node copies. It reads the DURABLE engine
    ///     stores (`node_store.scanNodes` → buffer pool → disk pages;
    ///     `label_store.getLabels`; `getAllProperties`) and writes only the
    ///     adapter's own mutex-sharded exact index. It never frees retire memory.
    ///   * A concurrent first-touch reopen hydration is READ-ONLY on the engine
    ///     node/label/property stores (it builds the graph_store RESIDENT indexes
    ///     from a scan; it does not mutate the engine). The one exception — the
    ///     legacy-IdMap node-property backfill (`adapter.setNodeProperty` in
    ///     `loadOneGraphFromAdapterFull`, guarded by `legacy_map != null`) — runs
    ///     only for LEGACY-format stores (never the current slab format) and, even
    ///     then, goes through the engine's own concurrency-safe write path (the
    ///     same buffer-pool/page-latch path that serves concurrent query reads +
    ///     bulk-ingest writes in normal operation). The engine already supports
    ///     the 16 concurrent per-shard reads this very build issues.
    ///   * It must NOT block on `hydration_build_mutex` (the discarded Option B):
    ///     the hydration persist-on-complete path takes `hydration_build_mutex` →
    ///     `mg.rwlock` (T3 `checkpointGraph`), so blocking on that mutex while we
    ///     hold `mg.rwlock` EXCLUSIVE would be an ABBA deadlock. Decoupling from
    ///     the mutex entirely avoids it.
    /// So the build fires unconditionally (given durable nodes), concurrent with
    /// any in-flight hydration, and the clean-shutdown checkpoint persists it.
    fn eagerBuildDeferredIndexForFullCheckpoint(self: *StorageAdapter, mg: *ManagedGraph) bool {
        _ = self;
        // Nothing to materialise for a graph with no durable nodes.
        var node_count: u64 = 0;
        for (mg.engine.shards) |shard| {
            node_count += @atomicLoad(u64, &shard.manifest.node_count, .monotonic);
        }
        if (node_count == 0) return false;

        // Parallel rebuild from durable pages. `.{}` cancel flags never trip: a
        // checkpoint-time build must run to completion (it is NOT tied to any
        // client connection, unlike the lazy first-access rebuild).
        // GAP-ENT-0048 (task0048d) diagnostic: starting the
        // parallel store-scan build. Time it so the 14.27M run sees the one-time
        // cost, and the dispatch counters (pool vs inline) prove it fanned out.
        const build_start_ns = monoNanosNow();
        rebuildExactNodePropertyIndex(mg, .{}) catch |err| {
            log.warn("eager exact-index build at full checkpoint failed for graph '{s}': {} — staying deferred", .{ mg.name, err });
            return false;
        };
        mg.exact_index_built.store(true, .release);
        _ = g_exact_eager_checkpoint_builds.fetchAdd(1, .monotonic);
        slog.info("deferred exact-index eagerly built at full checkpoint from durable store (reopen will reload the snapshot)", &.{
            SAttr.string("graph", mg.name),
            SAttr.uint("nodes", node_count),
            SAttr.uint("build_ms", (monoNanosNow() -| build_start_ns) / std.time.ns_per_ms),
            SAttr.uint("pool_tasks", g_exact_rebuild_pool_tasks.load(.acquire)),
            SAttr.uint("inline_tasks", g_exact_rebuild_inline_tasks.load(.acquire)),
        });
        return true;
    }

    /// GAP-ENT-0048f: build + persist the exact node-property index DURING
    /// first-touch hydration — the RACE-FREE path that supersedes the
    /// eager-build-at-FULL-checkpoint approach. Called from
    /// `GraphStore.ensureGraphHydrated` right after hydration completes
    /// (done=true, not failed), while it holds the store-wide
    /// `hydration_build_mutex`.
    ///
    /// Runs LOCK-FREE w.r.t. `mg.rwlock` (respecting the deliberate "hydration
    /// never holds mg.rwlock" invariant): it scans the DURABLE engine node
    /// stores exactly as the hydration scan just did, populates the adapter's
    /// mutex-sharded exact index, latches `built`, and persists `prop_exact.idx`
    /// DIRECTLY (shard mutexes only — NOT the exclusive-rwlock checkpoint). This
    /// removes the shutdown-checkpoint dependency and the rwlock race that the
    /// checkpoint approach hit at 14.27M (the bounded shutdown checkpoint could
    /// not acquire mg.rwlock against the in-flight hydration scan, so on a clean
    /// shutdown — no retry — the build never ran). After this returns a
    /// seek/GROUP BY is served from the built index with NO lazy rebuild, and
    /// the next reopen reloads the persisted snapshot.
    ///
    /// No-op when the index is already built (loaded from disk at open, or built
    /// by a prior touch). The one-shot `exact_index_build_mutex` latch (shared
    /// with the lazy path) makes concurrent first-touch + hydration build exactly
    /// once. Best-effort persist: a save error leaves the index correct in memory.
    pub fn buildAndPersistExactIndexForHydratedGraph(self: *StorageAdapter, graph_name: []const u8) void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.requireExistingGraphLocked(graph_name) catch return;
        };
        if (mg.exact_index_built.load(.acquire)) return;

        // Double-checked one-shot latch (the SAME mutex the lazy first-access
        // build uses), so a concurrent lazy build + this hydration build produce
        // the index EXACTLY once. `exact_index_build_mutex` is a leaf (no path
        // takes it then reaches for mg.rwlock / hydration_build_mutex), so this
        // cannot deadlock against the hydration_build_mutex the caller holds.
        const io = std.Io.Threaded.global_single_threaded.io();
        mg.exact_index_build_mutex.lockUncancelable(io);
        defer mg.exact_index_build_mutex.unlock(io);
        if (mg.exact_index_built.load(.acquire)) return;

        // Lock-free parallel scan of the durable engine stores -> mutex-sharded
        // exact index. `.{}` cancel flags: a hydration-time build runs to
        // completion (it is NOT tied to any client connection).
        const build_start_ns = monoNanosNow();
        rebuildExactNodePropertyIndex(mg, .{}) catch |err| {
            log.warn("hydration-time exact-index build failed for graph '{s}': {} — staying deferred", .{ graph_name, err });
            return;
        };
        mg.exact_index_built.store(true, .release);
        _ = g_exact_hydration_builds.fetchAdd(1, .monotonic);

        // Persist prop_exact.idx DIRECTLY (shard mutexes only — no mg.rwlock, no
        // checkpoint). This is what removes the shutdown-checkpoint dependency.
        if (graphDirPath(self.allocator, self.data_dir, mg.uuid)) |dir_path| {
            defer self.allocator.free(dir_path);
            mg.exact_node_property_index.saveToFile(dir_path, mgManifestCounter(mg)) catch |err| {
                log.warn("hydration-time exact-index persist failed for graph '{s}': {} — index stays memory-only until the next checkpoint", .{ graph_name, err });
            };
        } else |err| {
            log.warn("hydration-time exact-index persist: dir path failed for graph '{s}': {}", .{ graph_name, err });
        }

        var node_count: u64 = 0;
        for (mg.engine.shards) |shard| node_count += @atomicLoad(u64, &shard.manifest.node_count, .monotonic);
        slog.info("exact-index built + persisted during hydration (race-free; reopen will reload)", &.{
            SAttr.string("graph", graph_name),
            SAttr.uint("nodes", node_count),
            SAttr.uint("build_ms", (monoNanosNow() -| build_start_ns) / std.time.ns_per_ms),
            SAttr.uint("pool_tasks", g_exact_rebuild_pool_tasks.load(.acquire)),
        });
    }

    /// Task 3 (hydration persist-on-complete): FULL checkpoint of a SINGLE
    /// graph's engine — flush pages, truncate the WAL, bump the manifest
    /// counter, and persist the gs-side derived-index snapshots (Lever-B
    /// disciplines: dirty indexes saved, clean+trusted restamped, clean+
    /// untrusted left alone — all inside `engine.checkpoint()`) plus the
    /// geode-side H4 exact property index IF built (invalidated otherwise —
    /// the persist-empty gate).
    ///
    /// Called by `GraphStore.persistHydrationProductsForGraph` right after a
    /// successful first-touch hydration so the graph-scoped IdMap/loop2
    /// snapshots can be stamped at a durable post-checkpoint counter.
    ///
    /// The rwlock acquisition is BOUNDED (never the FULL path's unbounded
    /// spin): the caller holds the store-wide `hydration_build_mutex`, and an
    /// unbounded exclusive spin here could live-lock against a SHARED-lock
    /// holder that is itself blocked on a hydration chokepoint (e.g. a bulk
    /// apply worker in `createNodeWithReservedIdAndSlotGraphAndTenant` →
    /// `ensureGraphHydrated`). Busy past the deadline => error; the caller
    /// logs loudly and degrades (products stay memory-only until the next
    /// full checkpoint — pre-Task-3 behaviour).
    pub fn checkpointGraph(self: *StorageAdapter, graph_name: []const u8) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        switch (self.checkpointOneGraph(mg, false, true, 5 * std.time.ns_per_s)) {
            .ok => {},
            .skipped_busy => return error.CheckpointLockBusy,
            .engine_failed => return error.CheckpointFailed,
        }

        // Registry sync for THIS graph — same lockless manifest-count read as
        // checkpointAllEx (see the EDGE-PHASE 40001 FIX #1 rationale there:
        // NEVER take the per-graph rwlock SHARED for this metadata read).
        var nc: u64 = 0;
        var ec: u64 = 0;
        for (mg.engine.shards) |shard| {
            nc += @atomicLoad(u64, &shard.manifest.node_count, .monotonic);
            ec += @atomicLoad(u64, &shard.manifest.edge_count, .monotonic);
        }
        {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            self.upsertRegistryEntryLocked(mg.name, mg.uuid, nc, ec);
            self.saveRegistryLocked() catch |err| {
                log.warn("failed to persist graph registry: {}", .{err});
            };
        }
        // Deliberately does NOT touch `checkpoints_total` /
        // `pending_bulk_ops` / `last_checkpoint_mono_ns`: those drive the
        // GAP-0900 all-graph cadence + backpressure accounting, and a
        // graph-scoped hydration persist must not masquerade as a full
        // checkpoint cycle to that machinery.
        slog.info("graph-scoped full checkpoint complete (hydration persist-on-complete)", &.{
            SAttr.string("graph", mg.name),
        });
    }

    /// H4 persist-on-build: make a JUST-REBUILT exact node-property index
    /// durable NOW instead of at the next FULL checkpoint (typically clean
    /// shutdown) — a crash in that window used to re-pay the whole O(graph)
    /// first-access rebuild (~32 min at 14.27M) on reopen.
    ///
    /// Triggered by `ensureExactNodePropertyIndexBuilt` strictly AFTER a
    /// successful REBUILD latched `exact_index_built = true` — never after a
    /// snapshot LOAD (the load path latches at open without entering the
    /// rebuild branch; re-persisting it would be a pointless full rewrite).
    ///
    /// Runs on a BACKGROUND thread (tracked in `exact_persist_threads`,
    /// joined by `deinit`) because the triggering call sites include paths
    /// that HOLD the per-graph rwlock SHARED (the multi-prop MERGE probe:
    /// bulkMergeNodeWithReservedId* → findNodeMatchingMergeProps →
    /// copySmallestMergePropCandidates), where an inline `checkpointGraph`
    /// would spin its bounded EXCLUSIVE acquire against our own SHARED hold
    /// for the full 5 s deadline and always fail — stalling a MERGE that
    /// holds the tuple lock. A fresh thread holds no locks, so the bounded
    /// acquire wins as soon as concurrent readers drain.
    ///
    /// Best-effort, non-fatal (counted + logged): the index stays correct in
    /// memory either way, and the 88a05773 never-persist-unbuilt discipline
    /// is enforced by `checkpointOneGraph`, which re-checks the built latch
    /// under the EXCLUSIVE rwlock and INVALIDATES instead of persisting if
    /// the index was torn down in between. Kill switch:
    /// GEODE_DISABLE_EXACT_INDEX_PERSIST_ON_BUILD=1.
    fn spawnExactIndexPersistAfterBuild(self: *StorageAdapter, graph_name: []const u8) void {
        if (exactIndexPersistOnBuildDisabled()) return;
        _ = g_exact_persist_attempts.fetchAdd(1, .monotonic);
        const name_copy = self.allocator.dupe(u8, graph_name) catch {
            _ = g_exact_persist_failures.fetchAdd(1, .monotonic);
            log.warn("exact-index persist-on-build skipped: OOM duping graph name '{s}'", .{graph_name});
            return;
        };
        const io = std.Io.Threaded.global_single_threaded.io();
        self.exact_persist_mutex.lockUncancelable(io);
        defer self.exact_persist_mutex.unlock(io);
        if (self.exact_persist_shutdown) {
            self.allocator.free(name_copy);
            _ = g_exact_persist_failures.fetchAdd(1, .monotonic);
            return;
        }
        // Reserve BEFORE spawning so a post-spawn OOM can never leave an
        // unjoinable (leaked) thread behind.
        self.exact_persist_threads.ensureUnusedCapacity(self.allocator, 1) catch {
            self.allocator.free(name_copy);
            _ = g_exact_persist_failures.fetchAdd(1, .monotonic);
            log.warn("exact-index persist-on-build skipped: OOM reserving thread slot for '{s}'", .{graph_name});
            return;
        };
        const t = std.Thread.spawn(.{}, exactIndexPersistWorker, .{ self, name_copy }) catch |err| {
            self.allocator.free(name_copy);
            _ = g_exact_persist_failures.fetchAdd(1, .monotonic);
            log.warn("exact-index persist-on-build skipped: thread spawn failed for '{s}': {}", .{ graph_name, err });
            return;
        };
        self.exact_persist_threads.appendAssumeCapacity(t);
    }

    /// H4 persist-on-build worker: one bounded graph-scoped FULL checkpoint
    /// (`checkpointGraph` — the T3 path: 5 s tryLock re-probe acquire, engine
    /// checkpoint, exact-index persist-if-built, registry sync). Owns and
    /// frees `graph_name`. A graph DROPped between spawn and run fails the
    /// name lookup inside and is counted as a failure (correct: nothing left
    /// to persist).
    fn exactIndexPersistWorker(self: *StorageAdapter, graph_name: []u8) void {
        defer self.allocator.free(graph_name);
        self.checkpointGraph(graph_name) catch |err| {
            _ = g_exact_persist_failures.fetchAdd(1, .monotonic);
            slog.warn("exact-index persist-on-build failed; index stays memory-only until the next full checkpoint (a crash before then re-pays the rebuild)", &.{
                SAttr.string("graph", graph_name),
                SAttr.string("error", @errorName(err)),
            });
            return;
        };
        _ = g_exact_persist_completions.fetchAdd(1, .monotonic);
        slog.info("exact-index persist-on-build complete (crash-safe)", &.{
            SAttr.string("graph", graph_name),
        });
    }

    /// Number of completed `checkpointAll` runs since process start.
    ///
    /// GAP-0900 observability: lets operators (and the deferred-mode bulk
    /// ingest regression test) confirm that the periodic checkpoint actually
    /// fires during a sustained bulk load.
    pub fn checkpointsTotal(self: *const StorageAdapter) u64 {
        return self.checkpoints_total.load(.monotonic);
    }

    /// GAP-ENT-0038: export the checkpoint-cadence counters on the /metrics
    /// endpoint so operators can verify the deferred-mode checkpoint cadence
    /// directly (`adapter_checkpoints_total` should climb steadily during a
    /// bulk ingest; `adapter_pending_bulk_ops` should sawtooth below the
    /// GEODE_CHECKPOINT_OPS threshold) instead of inferring it from log lines
    /// — the inference that misread the 14.27M ingest as "checkpointing
    /// stopped" when three of the four checkpoint drivers simply never logged.
    /// Best-effort and idempotent: no-op until the global registry exists,
    /// latched after the first successful registration. Called from
    /// coordinator metric registration (first mutation after bring-up) and
    /// safe to call from anywhere else.
    pub fn registerCheckpointMetrics(self: *StorageAdapter) void {
        const runtime_metrics = @import("runtime_metrics");
        const reg = runtime_metrics.globalRegistry() orelse return;
        if (self.checkpoint_metrics_registered.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return;
        reg.register("adapter_checkpoints_total", &self.checkpoints_total) catch {};
        reg.register("adapter_pending_bulk_ops", &self.pending_bulk_ops) catch {};
    }

    /// Bulk write ops applied since the last checkpoint.
    ///
    /// GAP-0900: the FIX wires the group-commit bulk fast paths
    /// (bulkInsertNodeWithReservedId* / bulkMergeNode*) to bump this counter so
    /// the periodic checkpoint trigger can observe bulk-ingest pressure. Until
    /// the fix lands this stays 0 even under a heavy bulk load, which is exactly
    /// the bug.
    pub fn pendingBulkOps(self: *const StorageAdapter) u64 {
        return self.pending_bulk_ops.load(.acquire);
    }

    /// GAP-0900 checkpoint-cadence decision point.
    ///
    /// This is the entry point the persistence loop calls each tick to decide
    /// whether a periodic checkpoint is due, WITHOUT consulting the legacy CDC
    /// WAL (`g_wal.needsCheckpoint`) or `GraphStore.dirty` — neither of which
    /// the group-commit bulk fast path feeds. A checkpoint is due when either:
    ///   * `pending_bulk_ops >= ops_threshold` (the byte/op cadence), or
    ///   * at least `time_threshold_ms` have elapsed since the last checkpoint
    ///     AND there is un-checkpointed work (`pending_bulk_ops > 0`).
    ///
    /// `now_mono_ns` is injected so the time trigger is deterministic in tests
    /// (production passes `monoNanosNow()`).
    ///
    /// Returns `true` iff a checkpoint was performed.
    pub fn maybeCheckpoint(
        self: *StorageAdapter,
        ops_threshold: u64,
        time_threshold_ms: u64,
        now_mono_ns: u64,
    ) !bool {
        const pending = self.pending_bulk_ops.load(.acquire);
        const last_ns = self.last_checkpoint_mono_ns.load(.acquire);
        const elapsed_ms = (now_mono_ns -| last_ns) / std.time.ns_per_ms;

        const by_ops = ops_threshold != 0 and pending >= ops_threshold;
        const by_time = pending > 0 and time_threshold_ms != 0 and elapsed_ms >= time_threshold_ms;
        if (!by_ops and !by_time) return false;

        // GAP-0900 L2: periodic trigger uses the bounded (light) checkpoint.
        try self.checkpointAllLight();
        return true;
    }

    /// GAP-0900: install the load-driven checkpoint op-count threshold.
    ///
    /// Called once at server bring-up with the configured (env-overridable)
    /// threshold. When set non-zero, the bulk write path self-checkpoints once
    /// `pending_bulk_ops` crosses it, independent of the timer-based
    /// persistence loop (which is starved under sustained ingest).
    pub fn setCheckpointOpsThreshold(self: *StorageAdapter, threshold: u64) void {
        self.checkpoint_ops_threshold.store(threshold, .release);
    }

    /// GAP-0900 (B): install the write-backpressure hard cap (un-checkpointed
    /// ops). 0 disables. See `checkpoint_max_pending`.
    pub fn setCheckpointMaxPending(self: *StorageAdapter, max_pending: u64) void {
        self.checkpoint_max_pending.store(max_pending, .release);
    }

    /// GAP-0900: load-driven inline checkpoint trigger.
    ///
    /// Invoked from the bulk write fast paths after they bump
    /// `pending_bulk_ops`. When the pending op count has crossed the configured
    /// threshold, the FIRST thread to win the `checkpoint_in_progress` CAS runs
    /// a real `checkpointAll` (flushing + truncating the engine WAL, resetting
    /// the cadence state) while every other writer proceeds unblocked. This
    /// bounds the engine WAL / dirty-page growth that the bulk fast path would
    /// otherwise let grow without limit in deferred mode (GAP-0900), and does
    /// NOT depend on the timer-based persistence loop firing.
    ///
    /// `checkpointAll` itself takes the per-graph exclusive lock for the
    /// snapshot, so concurrent writers pause only for the checkpoint duration —
    /// the same contract the persistence loop already relies on.
    pub fn maybeCheckpointInline(self: *StorageAdapter) void {
        const threshold = self.checkpoint_ops_threshold.load(.acquire);
        if (threshold == 0) return;
        const pending = self.pending_bulk_ops.load(.acquire);
        if (pending < threshold) return;
        // Only one checkpoint at a time; losers normally keep writing.
        if (self.checkpoint_in_progress.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            // GAP-0900 (B) write-backpressure: a checkpoint is already running.
            // If we have blown past the hard cap, BLOCK until it drains rather
            // than letting the un-checkpointed set grow without bound (the
            // dirty-page/WAL spike that would otherwise OOM under a slow
            // checkpoint). Bounded spin so a stuck checkpoint can never deadlock
            // the writer; the light checkpoint is O(dirty) so the wait is short.
            const max_pending = self.checkpoint_max_pending.load(.acquire);
            if (max_pending != 0 and pending >= max_pending) {
                var spins: u64 = 0;
                while (spins < 2_000_000_000 and
                    self.checkpoint_in_progress.load(.acquire) and
                    self.pending_bulk_ops.load(.acquire) >= threshold) : (spins += 1)
                {
                    std.atomic.spinLoopHint();
                }
            }
            return;
        }
        defer self.checkpoint_in_progress.store(false, .release);
        // Re-check under the guard: another thread may have just checkpointed
        // and reset the counter between our load and the CAS.
        if (self.pending_bulk_ops.load(.acquire) < threshold) return;
        // GAP-0900 L2: the load-driven trigger uses the bounded (light)
        // checkpoint so it stays O(dirty) and keeps pace during bulk ingest.
        self.checkpointAllLight() catch |err| {
            // GAP-ENT-0038: structured logger — `std.log.warn` is compiled out
            // of ReleaseFast (no std_options override), which would hide a
            // repeatedly-failing cadence checkpoint from the live server log.
            slog.warn("GAP-0900 load-driven checkpoint failed", &.{
                SAttr.string("error", @errorName(err)),
            });
            return;
        };
        // GAP-ENT-0038: structured logger so the PRIMARY deferred-mode cadence
        // driver is visible in production logs (see header comment at `slog`).
        slog.info("load-driven auto-checkpoint fired", &.{
            SAttr.uint("checkpoints_total", self.checkpoints_total.load(.monotonic)),
        });
    }

    // ------------------------------------------------------------------
    // Statistics
    // ------------------------------------------------------------------

    /// Return the number of nodes in the named graph.
    pub fn nodeCount(self: *StorageAdapter, graph_name: []const u8) !u64 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.engine.nodeCount();
    }

    /// Return the number of edges in the named graph.
    pub fn edgeCount(self: *StorageAdapter, graph_name: []const u8) !u64 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.engine.edgeCount();
    }

    // ------------------------------------------------------------------
    // Internal helpers (must be called with mutex held)
    // ------------------------------------------------------------------

    /// Build the on-disk directory path for adapter artifacts that are
    /// scoped to a single graph (audit log, timeseries store, FTS index,
    /// per-graph property index, free.store sanitizer): `{data_dir}/{uuid_hex}`.
    ///
    /// This intentionally collocates with the sharded engine's `graph_root`
    /// (set by `gs.ShardedGraphEngine.create` to `{data_dir}/{uuid_hex}`)
    /// so we don't materialise a sibling `{data_dir}/graphs/` placeholder.
    /// Pinned by tests/test_admin_bootstrap_env_and_reset.zig "offline
    /// reset-password writes a single graphs root (storage layout invariant)".
    fn graphDirPath(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8) ![]const u8 {
        const hex = std.fmt.bytesToHex(graph_uuid, .lower);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{
            data_dir,
            &hex,
        });
    }

    /// GAP-0900 L2: remove a stale `prop_exact.idx` so a reopen rebuilds the
    /// exact node-property index from pages instead of loading a snapshot that
    /// the light (periodic) checkpoint deliberately did not refresh. The file has
    /// no staleness counter, so leaving an out-of-date copy would load wrong
    /// data after a crash. Best-effort: a missing file (already invalidated, or
    /// never written) is success.
    fn invalidateExactPropertyIndexFile(allocator: Allocator, graph_dir_path: []const u8) void {
        const idx_path = std.fmt.allocPrint(allocator, "{s}/prop_exact.idx", .{graph_dir_path}) catch return;
        defer allocator.free(idx_path);
        const inv_io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteFile(inv_io, idx_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => log.warn("failed to invalidate stale prop_exact.idx: {s}", .{@errorName(err)}),
        };
    }

    fn freeStoreMaskCount(total_pages: u64) usize {
        return @intCast((total_pages + @bitSizeOf(usize) - 1) / @bitSizeOf(usize));
    }

    fn truncateFreeStoreIfPresent(allocator: Allocator, graph_dir: []const u8) !bool {
        const free_store_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ graph_dir, free_store_path_name });
        defer allocator.free(free_store_path);

        const trunc_io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(trunc_io, free_store_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close(trunc_io);

        try file.setLength(trunc_io, 0);
        return true;
    }

    fn maxPersistedPagesForStorePath(self: *StorageAdapter, graph_dir: []const u8, file_name: []const u8) !u64 {
        const store_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ graph_dir, file_name });
        defer self.allocator.free(store_path);

        const stat = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), store_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return 64,
            else => return err,
        };

        const page_count = stat.size / self.config.page_size;
        if (page_count >= std.math.maxInt(u64) / 2) return std.math.maxInt(u64);
        return @max(@as(u64, 64), page_count * 2);
    }

    fn freeStoreLooksValidLocked(self: *StorageAdapter, graph_dir: []const u8) !bool {
        const free_store_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ graph_dir, free_store_path_name });
        defer self.allocator.free(free_store_path);

        const io_fv = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io_fv, free_store_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return true,
            else => return err,
        };
        defer file.close(io_fv);

        const stat = try file.stat(io_fv);
        if (stat.size == 0) return true;

        const word_size = @sizeOf(usize);
        const min_section_size = free_store_header_size + word_size;
        const min_total_size = min_section_size * graph_store_file_names.len;
        if (stat.size < min_total_size) return false;

        var max_total_size: u64 = 0;
        for (graph_store_file_names) |file_name| {
            const max_pages = try self.maxPersistedPagesForStorePath(graph_dir, file_name);
            max_total_size += free_store_header_size + freeStoreMaskCount(max_pages) * word_size;
        }
        if (stat.size > max_total_size) return false;

        var offset: u64 = 0;
        var header_buf: [free_store_header_size]u8 = undefined;
        for (graph_store_file_names) |file_name| {
            const max_pages = try self.maxPersistedPagesForStorePath(graph_dir, file_name);
            const bytes_read = try file.readPositionalAll(io_fv, &header_buf, offset);
            if (bytes_read != header_buf.len) return false;

            const total_pages = std.mem.readInt(u64, header_buf[0..8], .little);
            const next_free_hint = std.mem.readInt(u64, header_buf[8..16], .little);
            if (total_pages < 64 or total_pages > max_pages) return false;
            if (next_free_hint == 0 or next_free_hint > total_pages) return false;

            const section_size: u64 = free_store_header_size + freeStoreMaskCount(total_pages) * word_size;
            if (offset + section_size > stat.size) return false;
            offset += section_size;
        }

        return offset == stat.size;
    }

    fn sanitizeFreeStoreBeforeOpenLocked(self: *StorageAdapter, name: []const u8, graph_uuid: [16]u8) !void {
        const graph_dir = try graphDirPath(self.allocator, self.data_dir, graph_uuid);
        defer self.allocator.free(graph_dir);

        if (!(try self.freeStoreLooksValidLocked(graph_dir))) {
            if (try truncateFreeStoreIfPresent(self.allocator, graph_dir)) {
                log.warn("graph '{s}' has invalid persisted free.store; truncating it so GraphEngine.open can rebuild from disk", .{name});
            }
        }
    }

    /// Attempt to create a per-graph audit logger. Returns null on failure
    /// (soft failure — the graph remains usable without per-graph audit).
    fn initAuditForGraph(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8) ?*audit.AuditLogger {
        const graph_dir = graphDirPath(allocator, data_dir, graph_uuid) catch |err| {
            log.warn("failed to build graph dir path for audit: {}", .{err});
            return null;
        };
        defer allocator.free(graph_dir);

        const al = allocator.create(audit.AuditLogger) catch |err| {
            log.warn("failed to allocate per-graph audit logger: {}", .{err});
            return null;
        };
        al.* = audit.AuditLogger.initForGraph(allocator, graph_dir) catch |err| {
            log.warn("failed to init per-graph audit logger: {}", .{err});
            allocator.destroy(al);
            return null;
        };
        return al;
    }

    /// Create the per-graph timeseries store.
    ///
    /// GAP-0865 (a): durability is FAIL-CLOSED by default — any error
    /// (path/mkdir/alloc/engine open, including the engine's fail-closed
    /// WAL-replay and segment-verification errors on corrupt data)
    /// propagates and the graph open/create fails, so corruption is
    /// surfaced to the operator instead of silently dropping persistence.
    /// `GEODE_TS_DURABILITY=best_effort` opts back into the legacy soft
    /// behaviour: engine errors degrade to an in-memory store (inside the
    /// wrapper) and adapter-level errors degrade to `null`.
    ///
    /// Also wires retention (`GEODE_TS_RETENTION_DAYS`) and TDE
    /// (`GEODE_TS_TDE=1` + `GEODE_TDE_KEY`) into the engine (GAP-0865 c/e).
    fn initTimeseriesForGraph(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8) !?*ts_mod.Store {
        const durability = ts_mod.durabilityFromEnv();
        return initTimeseriesForGraphInner(allocator, data_dir, graph_uuid, durability) catch |err| switch (durability) {
            .fail_closed => err,
            .best_effort => blk: {
                log.warn("per-graph timeseries init failed ({}); GEODE_TS_DURABILITY=best_effort — graph continues without persistent timeseries", .{err});
                break :blk null;
            },
        };
    }

    fn initTimeseriesForGraphInner(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8, durability: ts_mod.Durability) !?*ts_mod.Store {
        const graph_dir = try graphDirPath(allocator, data_dir, graph_uuid);
        defer allocator.free(graph_dir);

        const store = try allocator.create(ts_mod.Store);
        errdefer allocator.destroy(store);

        // The wrapper creates `{graph_dir}/timeseries` itself (the engine
        // refuses to mkdir its own data_dir) and replays the engine WAL /
        // verifies segments during init — `loadFromDisk` is a no-op kept
        // for API compatibility.
        store.* = try ts_mod.Store.initWithConfig(allocator, .{
            .data_dir = graph_dir,
            .durability = durability,
            .retention_max_age_ms = ts_mod.retentionMsFromEnv(),
            .encryption_key = try ts_mod.encryptionKeyFromEnv(),
        });
        errdefer store.deinit();

        try store.loadFromDisk();
        return store;
    }

    const FtsInitResult = struct {
        /// Transitional "default" facade. Now null by default — the fts-storage
        /// Engine (single-writer, captures its creating thread and asserts
        /// owning-thread on flush/deinit) is created LAZILY only on
        /// `CREATE INDEX ... USING fulltext` / `getFulltextIndexNamed`, not
        /// eagerly for every graph. See `getFulltextIndexNamed`.
        index: ?*fulltext.FullTextIndex,
        adapter: *adapter_mod.FtsStorageAdapter,
        base_dir: std.Io.Dir,
        dir: []const u8,
    };

    /// Attempt to set up per-graph full-text search backing, via the external
    /// fts-storage LSM engine registry (`FtsStorageAdapter`).
    ///
    /// Builds `{graph_dir}/fts`, opens it as a `std.Io.Dir`, and constructs the
    /// adapter over it. The adapter itself is engine-free (it just roots the
    /// per-index child dirs); no fts-storage Engine is created here. The Engine
    /// — which captures its creating thread and asserts owning-thread on
    /// flush/deinit — is created lazily on the first `CREATE INDEX` /
    /// `getFulltextIndexNamed`. Returns null on failure (soft failure — the
    /// graph remains usable without FTS). `load_existing` is accepted for
    /// call-site symmetry but the adapter already does the right thing
    /// regardless (the on-disk dir is the source of truth), so it is unused.
    fn initFtsForGraph(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8, load_existing: bool) ?FtsInitResult {
        _ = load_existing;
        const io = std.Io.Threaded.global_single_threaded.io();

        const graph_dir = graphDirPath(allocator, data_dir, graph_uuid) catch |err| {
            log.warn("failed to build graph dir path for FTS: {}", .{err});
            return null;
        };
        defer allocator.free(graph_dir);

        // Build the FTS subdirectory path.
        const fts_dir = std.fmt.allocPrint(allocator, "{s}/fts", .{graph_dir}) catch |err| {
            log.warn("failed to allocate FTS dir path: {}", .{err});
            return null;
        };
        errdefer allocator.free(fts_dir);

        // Create (if needed) and OPEN the FTS subdirectory — the adapter needs an
        // open base_dir to root its per-index child dirs.
        var base_dir = std.Io.Dir.cwd().createDirPathOpen(io, fts_dir, .{}) catch |err| {
            log.warn("failed to create/open FTS dir '{s}': {}", .{ fts_dir, err });
            return null;
        };
        errdefer base_dir.close(io);

        const adapter = adapter_mod.FtsStorageAdapter.init(allocator, io, base_dir, fts_dir) catch |err| {
            log.warn("failed to init FTS storage adapter for '{s}': {}", .{ fts_dir, err });
            return null;
        };
        errdefer adapter.deinit();

        // No eager default index / facade: the fts-storage Engine is created
        // lazily on demand (CREATE INDEX / getFulltextIndexNamed) so graphs that
        // never use full-text search pay nothing and never capture an owning
        // thread that would later assert on cross-thread teardown.
        return .{ .index = null, .adapter = adapter, .base_dir = base_dir, .dir = fts_dir };
    }

    fn createGraphLocked(self: *StorageAdapter, name: []const u8) !*ManagedGraph {
        const graph_uuid = generateUuid();

        var cfg = self.config;
        cfg.data_dir = self.data_dir;

        // Security-graph WAL durability carve-out (2026-07-01, data-ingest
        // security review, gap 0026): `GEODE_WAL_SYNC=deferred` (GAP-0900)
        // relaxes the per-commit WAL fsync GLOBALLY for replayable bulk
        // loads. That contract can never hold for `__geode_security`: an
        // admin credential rotation, user/role/policy/grant mutation, or
        // HMAC chain reseal is NOT replayable — losing it on an unclean
        // shutdown silently resurrects the OLD credential (observed live:
        // persisted admin hash == env seed with an empty security-graph WAL
        // after a crash). Force the security graph's engines to
        // `.sync_each_commit` regardless of the operator knob so every
        // security mutation is durable BEFORE its commit is acknowledged.
        // Cost: one WAL fsync per security-graph commit — admin ops are
        // rare; bulk ingest on other graphs keeps the adapter-wide mode
        // untouched (this `cfg` is a per-graph copy of `self.config`).
        // Mirrored in `openGraphLocked`. Test:
        // tests/test_security_wal_durability.zig.
        const is_security_graph = std.mem.eql(u8, name, "__geode_security");
        if (is_security_graph) cfg.sync_mode = .sync_each_commit;

        const engine = gs.ShardedGraphEngine.create(
            self.allocator,
            self.data_dir,
            graph_uuid,
            cfg,
        ) catch |err| {
            log.err("failed to create ShardedGraphEngine for graph '{s}': {}", .{ name, err });
            return err;
        };
        // error-policy: A — best-effort close on an already-failing path.
        errdefer engine.close() catch {};

        const mg = try self.allocator.create(ManagedGraph);
        errdefer self.allocator.destroy(mg);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const merge_tuple_locks = try initMergeTupleLocks(self.allocator);
        errdefer self.allocator.free(merge_tuple_locks);

        // GAP-0512: Only create per-graph audit for the security graph.
        // Other graphs use the global audit logger. Per-graph audit on every
        // graph caused recursive mutex deadlocks and unnecessary I/O.
        // (`is_security_graph` hoisted above for the WAL-sync carve-out.)
        mg.* = .{
            .engine = engine,
            // ShardedGraphEngine synchronises the label dictionary across all
            // shards via getOrAssignLabel. shard 0 holds the canonical copy;
            // LabelStringDict.initView binds to that copy so the string<→id
            // mapping is consistent whether the caller reads via the adapter
            // or directly via the per-shard label_store.
            .label_dict = LabelStringDict.initView(&engine.shards[0].label_dict),
            .exact_node_property_index = NodePropertyExactIndex.init(self.allocator),
            .merge_tuple_locks = merge_tuple_locks,
            .name = owned_name,
            .uuid = graph_uuid,
            .audit_logger = if (is_security_graph) initAuditForGraph(self.allocator, self.data_dir, graph_uuid) else null,
            .ts_store = try initTimeseriesForGraph(self.allocator, self.data_dir, graph_uuid),
        };

        // Initialise per-graph FTS (fresh index for new graphs).
        if (initFtsForGraph(self.allocator, self.data_dir, graph_uuid, false)) |fts_result| {
            mg.fts_index = fts_result.index;
            mg.fts_adapter = fts_result.adapter;
            mg.fts_base_dir = fts_result.base_dir;
            mg.fts_dir = fts_result.dir;
        }

        try self.engines.put(owned_name, mg);
        {
            const runtime_metrics = @import("runtime_metrics");
            if (runtime_metrics.globalRegistry()) |reg| {
                // error-policy: A (whole block) — metric registration is
                // best-effort observability; duplicate-name or OOM failures
                // must never block graph creation.
                reg.register("mg_rwlock_shared_acquired_total", &mg.rwlock_shared_acquired_total) catch {};
                reg.register("mg_rwlock_shared_wait_ns_total", &mg.rwlock_shared_wait_ns_total) catch {};
                reg.register("mg_rwlock_exclusive_wait_ns_total", &mg.rwlock_exclusive_wait_ns_total) catch {};
                // Guard: rwlock_shared_hold_ns_total counts hold-time at 6 production
                // SHARED-acquire sites in this file. The 2 acquireShardWriteLock*
                // helpers (test-only currently) increment _acquired_total but NOT
                // _hold_ns_total. If those helpers ever gain production callers, the
                // derived metric `avg_hold_ns_per_acquire = hold_ns_total / acquired_total`
                // will silently understate. See Task 2 commit a25a7a05 for the NOTE
                // comments at those acquireShardWriteLock* sites.
                reg.register("mg_rwlock_shared_hold_ns_total", &mg.rwlock_shared_hold_ns_total) catch {};
                reg.register("mg_rwlock_shared_max_hold_ns_observed", &mg.rwlock_shared_max_hold_ns_observed) catch {};
                reg.register("mg_rwlock_shared_hold_snapshot_ns_total", &mg.rwlock_shared_hold_snapshot_ns_total) catch {};
                reg.register("mg_rwlock_shared_hold_point_read_ns_total", &mg.rwlock_shared_hold_point_read_ns_total) catch {};
                reg.register("mg_rwlock_shared_hold_bulk_merge_ns_total", &mg.rwlock_shared_hold_bulk_merge_ns_total) catch {};
                reg.register("mg_rwlock_shared_hold_bulk_edge_ns_total", &mg.rwlock_shared_hold_bulk_edge_ns_total) catch {};
                reg.register("mg_rwlock_shared_hold_fallback_ns_total", &mg.rwlock_shared_hold_fallback_ns_total) catch {};
                reg.register("mg_merge_tuple_lock_acquired_total", &mg.merge_tuple_lock_acquired_total) catch {};
                reg.register("mg_merge_tuple_lock_wait_ns_total", &mg.merge_tuple_lock_wait_ns_total) catch {};
                reg.register("mg_merge_tuple_lock_hold_ns_total", &mg.merge_tuple_lock_hold_ns_total) catch {};
                reg.register("mg_merge_tuple_lock_max_wait_ns_observed", &mg.merge_tuple_lock_max_wait_ns_observed) catch {};
                reg.register("mg_merge_tuple_lock_max_hold_ns_observed", &mg.merge_tuple_lock_max_hold_ns_observed) catch {};
            }
        }
        self.upsertRegistryEntryLocked(name, graph_uuid, 0, 0);
        self.saveRegistryLocked() catch |err| {
            log.warn("failed to persist graph registry after create of '{s}': {}", .{ name, err });
        };

        log.info("created graph '{s}'", .{name});

        return mg;
    }

    /// Open an existing graph engine from a known UUID directory.
    fn openGraphLocked(self: *StorageAdapter, name: []const u8, graph_uuid: [16]u8) !*ManagedGraph {
        try self.sanitizeFreeStoreBeforeOpenLocked(name, graph_uuid);

        var cfg = self.config;
        cfg.data_dir = self.data_dir;

        // Security-graph WAL durability carve-out — see the twin comment in
        // `createGraphLocked` (gap 0026): the security graph always runs
        // per-commit WAL fsync, even when the adapter-wide mode is
        // `.deferred` (GEODE_WAL_SYNC=deferred bulk-load knob).
        const is_security_graph = std.mem.eql(u8, name, "__geode_security");
        if (is_security_graph) cfg.sync_mode = .sync_each_commit;

        const engine = gs.ShardedGraphEngine.open(
            self.allocator,
            self.data_dir,
            graph_uuid,
            cfg,
        ) catch |err| {
            log.err("failed to open ShardedGraphEngine for graph '{s}': {}", .{ name, err });
            return err;
        };
        // error-policy: A — best-effort close on an already-failing path.
        errdefer engine.close() catch {};

        const mg = try self.allocator.create(ManagedGraph);
        errdefer self.allocator.destroy(mg);

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        const merge_tuple_locks = try initMergeTupleLocks(self.allocator);
        errdefer self.allocator.free(merge_tuple_locks);

        mg.* = .{
            .engine = engine,
            .label_dict = LabelStringDict.initView(&engine.shards[0].label_dict),
            .exact_node_property_index = NodePropertyExactIndex.init(self.allocator),
            .merge_tuple_locks = merge_tuple_locks,
            .name = owned_name,
            .uuid = graph_uuid,
            .audit_logger = if (is_security_graph) initAuditForGraph(self.allocator, self.data_dir, graph_uuid) else null,
            .ts_store = try initTimeseriesForGraph(self.allocator, self.data_dir, graph_uuid),
        };

        // gap 0026: after a crash restart, advance the security graph's
        // manifest counters past the WAL-replayed state (see
        // healSecurityEngineCounters) — otherwise recovered security records
        // are scan-invisible and their slots get re-issued.
        if (is_security_graph) healSecurityEngineCounters(mg);

        // Load per-graph FTS from disk (existing graphs may have persisted data).
        if (initFtsForGraph(self.allocator, self.data_dir, graph_uuid, true)) |fts_result| {
            mg.fts_index = fts_result.index;
            mg.fts_adapter = fts_result.adapter;
            mg.fts_base_dir = fts_result.base_dir;
            mg.fts_dir = fts_result.dir;
        }

        // Try loading the persisted property index if it is CURRENT (its
        // manifest-counter stamp matches the engine's counter — GAP-ENT-0048g);
        // otherwise fall back to a lazy/hydration rebuild.
        const loaded_from_disk = blk: {
            const dir_path = graphDirPath(self.allocator, self.data_dir, graph_uuid) catch break :blk false;
            defer self.allocator.free(dir_path);
            break :blk mg.exact_node_property_index.loadFromFile(dir_path, mgManifestCounter(mg));
        };
        if (loaded_from_disk) {
            // Persisted snapshot loaded: the index is complete and ready.
            mg.exact_index_built.store(true, .release);
            // GAP-ENT-0048 PRIMARY: record the O(snapshot) reload so a test can
            // prove the reopen engaged the index WITHOUT an O(graph) rebuild.
            _ = g_exact_index_reloaded.fetchAdd(1, .monotonic);
        } else {
            // H4 (cold-open phase 1): DEFER the full O(graph) property-chain
            // rebuild to first access instead of paying it EAGERLY at open
            // (~1.5-2h at 14.27M nodes). `ensureExactNodePropertyIndexBuilt`
            // rebuilds from the durable pages on the first read/live-mutation;
            // every index accessor guards on it. Crash-safe (rebuild reads
            // durable pages; counter-gated by loadFromFile on the next open).
            mg.exact_index_built.store(false, .release);
            log.info("exact property index deferred for graph '{s}' (lazy first-access rebuild)", .{name});
        }

        try self.engines.put(owned_name, mg);
        // Aggregate node/edge counts across all shards for the registry.
        var total_nodes: u64 = 0;
        var total_edges: u64 = 0;
        for (mg.engine.shards) |shard| {
            total_nodes += shard.manifest.node_count;
            total_edges += shard.manifest.edge_count;
        }
        self.upsertRegistryEntryLocked(name, graph_uuid, total_nodes, total_edges);
        self.saveRegistryLocked() catch |err| {
            log.warn("failed to persist graph registry after open of '{s}': {}", .{ name, err });
        };

        if (loaded_from_disk) {
            log.info("opened existing graph '{s}' (property index loaded from disk)", .{name});
        } else {
            log.info("opened existing graph '{s}' (property index rebuilt from scan)", .{name});
        }

        return mg;
    }

    fn requireExistingGraphLocked(self: *StorageAdapter, graph_name: []const u8) !*ManagedGraph {
        if (self.engines.get(graph_name)) |mg| {
            return mg;
        }
        if (self.findRegistryEntryLocked(graph_name)) |entry| {
            return self.openGraphLocked(graph_name, entry.uuid);
        }
        return error.GraphNotFound;
    }

    fn findRegistryEntryLocked(self: *StorageAdapter, name: []const u8) ?gs.registry.GraphEntry {
        return self.registry.findByName(name);
    }

    fn resolveLabelScanContext(self: *StorageAdapter, graph_name: []const u8, label: []const u8) !?LabelScanContext {
        // Brief mutex hold: look up ManagedGraph and label ID, then release.
        // The ManagedGraph is stable while the caller holds the per-graph
        // rwlock, so iterator-backed scans do not need the adapter mutex.
        // Holding mutex during scans caused ABBA deadlocks with concurrent
        // ingest (QUIC handler: rwlock → mutex; ingest: mutex → rwlock).
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const mg = try self.requireExistingGraphLocked(graph_name);
        const label_id = mg.label_dict.getId(label) orelse return null;
        return .{
            .mg = mg,
            .label_id = label_id,
        };
    }

    fn upsertRegistryEntryLocked(self: *StorageAdapter, name: []const u8, graph_uuid: [16]u8, node_count: u64, edge_count: u64) void {
        for (self.registry.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.uuid = graph_uuid;
                entry.node_count = node_count;
                entry.edge_count = edge_count;
                return;
            }
        }

        self.registry.addGraph(name, graph_uuid) catch |err| {
            log.warn("failed to add graph '{s}' to registry: {}", .{ name, err });
            return;
        };
        const entry = &self.registry.entries.items[self.registry.entries.items.len - 1];
        entry.node_count = node_count;
        entry.edge_count = edge_count;
    }

    fn syncRegistryCountsLocked(self: *StorageAdapter, mg: *ManagedGraph) void {
        var total_nodes: u64 = 0;
        var total_edges: u64 = 0;
        for (mg.engine.shards) |shard| {
            total_nodes += shard.manifest.node_count;
            total_edges += shard.manifest.edge_count;
        }
        self.upsertRegistryEntryLocked(
            mg.name,
            mg.uuid,
            total_nodes,
            total_edges,
        );
    }

    fn loadPersistedManifestLocked(self: *StorageAdapter, graph_uuid: [16]u8) !gs.manifest.Manifest {
        // 2026-04-27: registry persist no longer fails when the
        // currently-not-loaded graph was created by a sharded engine.
        // Layout reminder:
        //   legacy single-engine : data_dir/graphs/<graph_uuid>/manifest.{a,b}
        //   sharded engine       : data_dir/<graph_uuid>/shard_manifest.json
        //                          + data_dir/<graph_uuid>/graphs/<per_shard_uuid>/manifest.{a,b}
        //
        // The previous implementation only walked the legacy path; for
        // a sharded graph that was created by an earlier session and is
        // not loaded into `self.engines` in the current session, the
        // legacy `manifest.a` does not exist and `Manifest.readFromFile`
        // surfaced `error.NoManifest`.  That bubbled out of
        // `refreshRegistryHeaderNextIdsLocked` and cascaded into
        // `saveRegistryLocked` failure — every subsequent
        // `createGraph` warned `failed to persist graph registry: NoManifest`
        // and the registry on disk was missing the new entry.
        //
        // Regression test: `StorageAdapter: registry header next ids include
        // unloaded graphs` (this file).
        //
        // Strategy: try sharded layout first (the standard layout in
        // current builds); if shard_manifest is missing, fall back to
        // the legacy single-engine layout.
        const uuid_hex = formatUuidHexLocal(graph_uuid);
        const sharded_root = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.data_dir, &uuid_hex });
        defer self.allocator.free(sharded_root);

        if (gs.shard_manifest.readFromDir(self.allocator, sharded_root)) |sm| {
            // Walk per-shard manifests, take the max next_node_id /
            // next_edge_id across them so the registry header reflects
            // the maximum allocated ID anywhere in this graph.
            var aggregated: gs.manifest.Manifest = .{};
            aggregated.next_node_id = 1;
            aggregated.next_edge_id = 1;

            for (sm.per_shard_uuids) |shard_uuid| {
                const shard_uuid_hex = formatUuidHexLocal(shard_uuid);
                const shard_dir = try std.fmt.allocPrint(self.allocator, "{s}/graphs/{s}", .{ sharded_root, &shard_uuid_hex });
                defer self.allocator.free(shard_dir);
                const path_a = try std.fmt.allocPrint(self.allocator, "{s}/manifest.a", .{shard_dir});
                defer self.allocator.free(path_a);
                const path_b = try std.fmt.allocPrint(self.allocator, "{s}/manifest.b", .{shard_dir});
                defer self.allocator.free(path_b);

                // Both slots can be missing for shards that never
                // committed a checkpoint; treat that as "no contribution
                // to the headers" rather than fail the whole walk.
                const ma_opt: ?gs.manifest.Manifest = gs.manifest.Manifest.readFromFile(self.allocator, path_a) catch |e1| blk: {
                    if (e1 == error.FileNotFound or e1 == error.NoManifest) break :blk null;
                    return e1;
                };
                const mb_opt: ?gs.manifest.Manifest = gs.manifest.Manifest.readFromFile(self.allocator, path_b) catch |e2| blk: {
                    if (e2 == error.FileNotFound or e2 == error.NoManifest) break :blk null;
                    return e2;
                };
                const m: ?gs.manifest.Manifest = if (ma_opt != null and mb_opt != null)
                    (gs.manifest.Manifest.selectManifest(ma_opt.?, mb_opt.?) catch ma_opt.?)
                else if (ma_opt != null)
                    ma_opt
                else
                    mb_opt;
                if (m) |mm| {
                    if (mm.next_node_id > aggregated.next_node_id) aggregated.next_node_id = mm.next_node_id;
                    if (mm.next_edge_id > aggregated.next_edge_id) aggregated.next_edge_id = mm.next_edge_id;
                }
            }
            return aggregated;
        } else |err| switch (err) {
            error.FileNotFound => {}, // fall through to legacy layout below
            else => return err,
        }

        // Legacy single-engine layout fallback.
        var graph_dir = try gs.graph_dir.GraphDir.open(self.allocator, self.data_dir, graph_uuid);
        defer graph_dir.deinit();

        const path_a = try graph_dir.manifestPath(self.allocator, .a);
        defer self.allocator.free(path_a);

        const path_b = try graph_dir.manifestPath(self.allocator, .b);
        defer self.allocator.free(path_b);

        const manifest_a = try gs.manifest.Manifest.readFromFile(self.allocator, path_a);
        const manifest_b = try gs.manifest.Manifest.readFromFile(self.allocator, path_b);
        return try gs.manifest.Manifest.selectManifest(manifest_a, manifest_b);
    }

    /// Format a 16-byte UUID as a 32-char lowercase hex slice.  Local
    /// helper so we don't depend on the package's private `uuidHex`.
    fn formatUuidHexLocal(u: [16]u8) [32]u8 {
        var buf: [32]u8 = undefined;
        const hex = "0123456789abcdef";
        for (u, 0..) |b, i| {
            buf[i * 2] = hex[(b >> 4) & 0xF];
            buf[i * 2 + 1] = hex[b & 0xF];
        }
        return buf;
    }

    fn refreshRegistryHeaderNextIdsLocked(self: *StorageAdapter) !void {
        var next_node_id: u64 = 1;
        var next_edge_id: u64 = 1;

        for (self.registry.entries.items) |entry| {
            if (self.engines.get(entry.name)) |mg| {
                for (mg.engine.shards) |shard| {
                    next_node_id = @max(next_node_id, shard.manifest.next_node_id);
                    next_edge_id = @max(next_edge_id, shard.manifest.next_edge_id);
                }
                continue;
            }

            const manifest = try self.loadPersistedManifestLocked(entry.uuid);
            next_node_id = @max(next_node_id, manifest.next_node_id);
            next_edge_id = @max(next_edge_id, manifest.next_edge_id);
        }

        self.registry.next_node_id = next_node_id;
        self.registry.next_edge_id = next_edge_id;
    }

    fn saveRegistryLocked(self: *StorageAdapter) !void {
        try self.refreshRegistryHeaderNextIdsLocked();
        try self.registry.saveToFile(self.registry_path);
    }

    fn loadRegistry(self: *StorageAdapter) !void {
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), self.registry_path, .{}) catch |err| {
            if (err == error.FileNotFound) return err;
            return err;
        };
        try self.registry.loadFromFile(self.registry_path);
    }

    // ------------------------------------------------------------------
    // Node label operations (vtable targets)
    // ------------------------------------------------------------------

    /// Add a label to a node. The label string is mapped to a numeric
    /// LabelId via the per-graph dictionary, creating a new mapping if
    /// this is the first time the label has been seen.
    pub fn addNodeLabel(self: *StorageAdapter, graph_name: []const u8, node_id: u64, label: []const u8) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // H4: a live write must never mutate an unbuilt (deferred) exact index
        // (adding a label re-indexes the node's properties under the new label).
        try ensureExactNodePropertyIndexBuilt(self, mg);
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
        const label_id = try resolvePersistedLabelId(mg, label);
        const node_shard = mg.shardEngineForNode(node_id);
        // R10: join active session/statement engine txn if on the same shard.
        if (currentStatementTxnForGraph(graph_name)) |s| {
            if (shardLocalTxnForNode(s.txn_id, node_id)) |local| {
                try node_shard.addLabelTxn(node_id, label_id, local);
                // gap 0026: WAL-log the node's REAL label page (see
                // relogSecurityLabelPageTxn) — no-op outside __geode_security.
                try relogSecurityLabelPageTxn(mg, node_shard, node_id, local);
            } else {
                try mg.engine.addLabel(node_id, label_id);
                try relogSecurityLabelPageAutoCommit(mg, node_shard, node_id);
            }
        } else {
            try mg.engine.addLabel(node_id, label_id);
            try relogSecurityLabelPageAutoCommit(mg, node_shard, node_id);
        }
        try addNodePropertiesForLabels(mg, node_id, &[_]gs.LabelId{label_id}, rec.prop_head);
    }

    /// Remove a label from a node. If the label string is not in the
    /// per-graph dictionary then there is nothing to remove.
    pub fn removeNodeLabel(self: *StorageAdapter, graph_name: []const u8, node_id: u64, label: []const u8) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // H4: a live write must never mutate an unbuilt (deferred) exact index
        // (removing a label drops the node's postings under that label).
        try ensureExactNodePropertyIndexBuilt(self, mg);
        const rec = try mg.engine.getNode(node_id) orelse return error.NodeNotFound;
        const label_id = mg.label_dict.getId(label) orelse return; // nothing to remove
        removeNodePropertiesForLabels(mg, node_id, &[_]gs.LabelId{label_id}, rec.prop_head);
        const node_shard = mg.shardEngineForNode(node_id);
        // R10: join active session/statement engine txn if on the same shard.
        if (currentStatementTxnForGraph(graph_name)) |s| {
            if (shardLocalTxnForNode(s.txn_id, node_id)) |local| {
                try node_shard.removeLabelTxn(node_id, label_id, local);
            } else {
                try mg.engine.removeLabel(node_id, label_id);
            }
        } else {
            try mg.engine.removeLabel(node_id, label_id);
        }
    }

    // ------------------------------------------------------------------
    // Edge property operations (vtable targets)
    // ------------------------------------------------------------------

    /// Remove a property from an edge. Delegates to the engine's
    /// `removeEdgeProperty` which handles adjacency list scanning internally.
    pub fn removeEdgeProperty(
        self: *StorageAdapter,
        graph_name: []const u8,
        from_id: u64,
        _: u64, // to_id — reserved for future use
        edge_id: u64,
        key: []const u8,
    ) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        try mg.engine.removeEdgeProperty(from_id, edge_id, key);
    }

    // ------------------------------------------------------------------
    // Storage inspection
    // ------------------------------------------------------------------

    /// Return storage-level statistics for the named graph.
    /// Routes to shard 0 (representative; per-shard stats are not aggregated).
    pub fn getStorageStats(self: *StorageAdapter, graph_name: []const u8) !gs.GraphEngine.StorageStats {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.engine.shards[0].getStorageStats();
    }

    /// Run an integrity check on the named graph and return the report.
    /// Routes to shard 0 (representative; full cross-shard check not yet wired).
    pub fn checkIntegrity(self: *StorageAdapter, graph_name: []const u8) !gs.GraphEngine.IntegrityReport {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        return mg.engine.shards[0].checkIntegrity();
    }

    // ------------------------------------------------------------------
    // Per-graph RwLock acquisition API (P1 lock migration)
    // ------------------------------------------------------------------

    /// Acquire a shared (read) lock on the named graph.
    /// Caller MUST call releaseGraphReadLock when done, passing back the
    /// `hold_start_ns` value from the returned `ReadLockAcquisition` so the
    /// per-graph SHARED hold-time counters get accurate per-acquisition
    /// timing data (see `ManagedGraph.rwlock_shared_hold_ns_total`).
    pub fn acquireGraphReadLock(
        self: *StorageAdapter,
        graph_name: []const u8,
    ) !ReadLockAcquisition {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(graph_name) orelse {
            self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return error.GraphNotFound;
        };
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const _t_start = monoNanosNow();
        // EDGE-PHASE 40001 FIX #2 (2026-06-22): yield to a pending EXCLUSIVE
        // acquirer (checkpoint or edge schema/MERGE) before taking SHARED, so
        // the reader set drains and the exclusive `tryLock` wins instead of
        // being starved. This is the generic read path used by query MATCH
        // (the edge phase's own MATCH→rel-create is MATCH=SHARED then
        // create=EXCLUSIVE), so without this back-off 8 edge workers' MATCH
        // readers would re-starve each other's rel-create exclusive. Bounded
        // safety valve inside `exclusiveWaitingBackoff`; no semaphore park.
        exclusiveWaitingBackoff(mg);
        mg.rwlock.lockSharedUncancelable(std.Io.Threaded.global_single_threaded.io());
        _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
        _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
        const hold_start_ns = monoNanosNow();
        return .{ .mg = mg, .hold_start_ns = hold_start_ns };
    }

    pub fn releaseGraphReadLock(_: *StorageAdapter, mg: *ManagedGraph, hold_start_ns: u64, site_tag: graph_store.LockSiteTag) void {
        const _hold_ns = monoNanosNow() -| hold_start_ns;
        _ = mg.rwlock_shared_hold_ns_total.fetchAdd(_hold_ns, .monotonic);
        const _cur_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
        if (_hold_ns > _cur_max) {
            mg.rwlock_shared_max_hold_ns_observed.store(_hold_ns, .monotonic);
        }
        switch (site_tag) {
            .snapshot => _ = mg.rwlock_shared_hold_snapshot_ns_total.fetchAdd(_hold_ns, .monotonic),
            .point_read => _ = mg.rwlock_shared_hold_point_read_ns_total.fetchAdd(_hold_ns, .monotonic),
            .bulk_merge => _ = mg.rwlock_shared_hold_bulk_merge_ns_total.fetchAdd(_hold_ns, .monotonic),
            .bulk_edge => _ = mg.rwlock_shared_hold_bulk_edge_ns_total.fetchAdd(_hold_ns, .monotonic),
            .fallback => _ = mg.rwlock_shared_hold_fallback_ns_total.fetchAdd(_hold_ns, .monotonic),
            .misc => {}, // intentionally not decomposed
        }
        mg.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
    }

    /// Test helper: look up a `*ManagedGraph` by name without acquiring
    /// the per-graph rwlock. Used by regression tests that need to read
    /// per-graph counters directly.
    pub fn lookupManagedGraph(self: *StorageAdapter, name: []const u8) !*ManagedGraph {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.engines.get(name) orelse error.GraphNotFound;
    }

    /// Acquire an exclusive (write) lock on the named graph.
    /// Caller MUST call releaseGraphWriteLock when done.
    pub fn acquireGraphWriteLock(self: *StorageAdapter, graph_name: []const u8) !*ManagedGraph {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(graph_name) orelse {
            self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return error.GraphNotFound;
        };
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        // HANG FIX (2026-05-22): re-probe via `tryLock` instead of parking
        // unboundedly on `mg.rwlock.lockUncancelable`.  See the detailed
        // rationale in `acquireGraphWriteLockCancelable` below — the
        // uncancelable path can wedge forever on the RwLock's internal
        // counting semaphore after a lost wakeup.  This non-cancelable
        // variant has no caller-supplied deadline, so it spins without a
        // hard cap, but every iteration re-reads `rl.state` directly and so
        // is immune to a lost semaphore `post()`.
        const io = std.Io.Threaded.global_single_threaded.io();
        const _t_start = monoNanosNow();
        if (mg.rwlock.tryLock(io)) {
            _ = mg.rwlock_exclusive_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
            return mg;
        }
        var sleep_ns: u64 = 100 * std.time.ns_per_us;
        const max_sleep_ns: u64 = 2 * std.time.ns_per_ms;
        while (true) {
            const req = std.os.linux.timespec{
                .sec = @intCast(sleep_ns / std.time.ns_per_s),
                .nsec = @intCast(sleep_ns % std.time.ns_per_s),
            };
            var rem: std.os.linux.timespec = undefined;
            _ = std.os.linux.nanosleep(&req, &rem);
            if (mg.rwlock.tryLock(io)) {
                _ = mg.rwlock_exclusive_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
                return mg;
            }
            sleep_ns = @min(sleep_ns * 2, max_sleep_ns);
        }
    }

    /// Deadline-aware variant of `acquireGraphWriteLock`.
    ///
    /// History: the original R2 (2026-04-22) implementation used a
    /// `tryLock` + exponential-backoff spin with a per-request
    /// deadline.  That was the FUNDAMENTAL root cause of the 48
    /// chunk-failure cascade on the morning-baseline R13 msft-graph
    /// run AND the 40001 cascades on every Phase 2 redesign.
    ///
    /// The bug: `mg.rwlock.tryLock(io)` on `std.Io.RwLock` never marks
    /// the writer as pending in `state`.  See
    /// `std/Io/RwLock.zig:28-40`:
    ///   if (rl.mutex.tryLock()) {
    ///     const state = @atomicLoad(...);
    ///     if (state & reader_mask == 0) { set is_writing; return true; }
    ///     rl.mutex.unlock(io);
    ///   }
    ///   return false;
    ///
    /// Readers entering via the fast CAS path
    /// (`state & (is_writing | writer_mask) == 0`) keep the reader
    /// count non-zero.  Under the msft-graph edge MATCH+CREATE hot
    /// path, 16 concurrent workers produce near-continuous SHARED
    /// acquire/release traffic.  `tryLock` observes a non-zero
    /// reader count on every retry and fails forever until the
    /// deadline fires → `error.Deadline` → 40001 surfaced to client
    /// → serial fallback.
    ///
    /// Fix (2026-04-23 evening, Phase 2.4): use the writer-preferred
    /// `lockUncancelable` path whenever the deadline budget is large
    /// enough to allow it (> 1 s).  `lockUncancelable` starts with
    /// `@atomicRmw(&state, .Add, writer, .seq_cst)` (see
    /// `std/Io/RwLock.zig:42-49`) which marks writer pending;
    /// subsequent reader acquires go through the slow mutex path,
    /// yielding to the writer.
    ///
    /// For callers with genuinely tight deadlines (< 1 s), preserve
    /// the old `tryLock` spin behaviour so fail-fast semantics still
    /// work — these callers explicitly asked for a short timeout.
    ///
    /// In practice all current callers pass 120 s, so they always
    /// route through the writer-preferred path and never observe
    /// `error.Deadline` under the msft-graph workload.
    pub fn acquireGraphWriteLockCancelable(
        self: *StorageAdapter,
        graph_name: []const u8,
        deadline_mono_ns: u64,
    ) !*ManagedGraph {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(graph_name) orelse {
            self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            return error.GraphNotFound;
        };
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const io = std.Io.Threaded.global_single_threaded.io();
        const _t_start = monoNanosNow();

        // EDGE-PHASE 40001 FIX #2 (2026-06-22): announce a pending EXCLUSIVE
        // acquire so SHARED acquirers (the generic read path
        // `acquireGraphReadLock`, the bulk-apply/hydrate paths, and any other
        // reader) back off via `exclusiveWaitingBackoff` and drain the reader
        // set — letting this exclusive `tryLock` win instead of being starved
        // by a recurring reader (the production 40001: CREATE INDEX ON
        // :Taxon(source_id) / relationship MERGE timed out behind the
        // continuous checkpoint loop at 14.27M scale). `std.Io.RwLock` has no
        // native writer preference (`tryLock` never sets the `writer` bit), so
        // this explicit counter is the writer-preference. It is the SAME
        // counter the checkpoint announces on, so a checkpoint + a CREATE INDEX
        // (or two relationship-MERGE workers) compose: readers stay backed off
        // until the LAST pending exclusive clears.
        //
        // DEADLOCK-FREE: announced unconditionally (covers fast + slow path),
        // cleared on EVERY return via `defer` (success, error.Deadline). The
        // backoff is consulted ONLY by SHARED acquirers — never by exclusive
        // acquirers — so two pending exclusives never wait on each other; they
        // race `tryLock` and the std RwLock serialises the loser normally. The
        // backoff is bounded (8s safety valve), so even a pathologically slow
        // exclusive can never wedge readers forever. No thread parks on the
        // RwLock semaphore, preserving the lost-wakeup immunity from 9bd9b81b.
        _ = mg.exclusive_waiting.fetchAdd(1, .release);
        defer _ = mg.exclusive_waiting.fetchSub(1, .release);

        // Fast path: uncontended acquire in one call.
        if (mg.rwlock.tryLock(io)) {
            _ = mg.rwlock_exclusive_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
            return mg;
        }

        // Contended slow path: bounded, re-probing `tryLock` spin.
        //
        // HANG FIX (2026-05-22): the previous long-deadline branch parked
        // unconditionally on `mg.rwlock.lockUncancelable(io)`.  That call's
        // internal protocol (std/Io/RwLock.zig `lockUncancelable`) registers
        // the writer, then — if it observed any reader at the moment it set
        // `is_writing` — parks FOREVER on the RwLock's internal counting
        // semaphore waiting for the last reader's `unlockShared` to `post()`.
        // Under the periodic checkpoint loop (`checkpointAll` takes the same
        // `mg.rwlock` SHARED every few seconds) that wait could be entered
        // and never woken: a single missed `post()` wedges the writer
        // permanently, the writer keeps the RwLock's internal mutex, and
        // every subsequent reader/writer (including the next checkpoint and
        // every queued connection handler) blocks behind it.  Captured live
        // twice via `gdb` on the GAP-0257 spec: one connection thread stuck
        // in `Io.Semaphore.waitUncancelable` with zero readers active.
        //
        // The fix: never park unboundedly.  `tryLock` reads `rl.state`
        // directly and touches no semaphore, so it is immune to a lost
        // wakeup — each retry re-observes the true reader count and acquires
        // the instant readers drain.  `tryLock` also takes the RwLock's
        // internal mutex for the duration of its probe, which blocks any
        // NEW slow-path reader from registering while we retry, giving the
        // writer forward progress.  The deadline is honoured: on exhaustion
        // we return `error.Deadline`, surfaced to the client as a clean,
        // retryable `40001` instead of an unbounded server-side hang.
        var sleep_ns: u64 = 100 * std.time.ns_per_us;
        const max_sleep_ns: u64 = 2 * std.time.ns_per_ms;
        while (true) {
            const now = monoNanosNow();
            if (now >= deadline_mono_ns) {
                _ = mg.rwlock_exclusive_wait_ns_total.fetchAdd(now -| _t_start, .monotonic);
                return error.Deadline;
            }
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
            if (mg.rwlock.tryLock(io)) {
                _ = mg.rwlock_exclusive_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
                return mg;
            }
            sleep_ns = @min(sleep_ns * 2, max_sleep_ns);
        }
    }

    pub fn releaseGraphWriteLock(_: *StorageAdapter, mg: *ManagedGraph) void {
        mg.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    /// R8 (2026-04-22): begin a per-statement engine transaction on `graph_name`.
    ///
    /// After this call, the current thread's subsequent adapter mutation
    /// calls on the same graph (createNode, setNodeProperty, createEdge,
    /// deleteNode, etc.) JOIN this transaction instead of opening their
    /// own engine txn.  The entire statement commits with a single WAL
    /// fsync via `StatementTxn.commit`.
    ///
    /// Caller contract:
    ///   const txn = try adapter.beginStatementTxn(graph_name);
    ///   errdefer txn.abort();
    ///   // …adapter mutation calls on `graph_name`…
    ///   try txn.commit();
    ///
    /// It is a bug to call `beginStatementTxn` while another statement
    /// txn is already active on the current thread — the per-graph
    /// exclusive write lock is expected to serialise statements on a
    /// given graph, so nested opens should be impossible in normal
    /// operation.  We log and return `error.NestedStatementTxn` rather
    /// than silently overwriting the thread-local.
    pub fn beginStatementTxn(self: *StorageAdapter, graph_name: []const u8, out: *StatementTxn) !void {
        if (t_current_statement_txn != null) {
            log.err("adapter.beginStatementTxn called with an existing statement txn on this thread (graph={s})", .{graph_name});
            return error.NestedStatementTxn;
        }

        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.engines.get(graph_name) orelse return error.GraphNotFound;
        };

        const txn_id = try mg.engine.beginTxn();
        out.* = .{
            .mg = mg,
            .txn_id = txn_id,
            .graph_name = mg.name, // owned by ManagedGraph, stable while engines map keeps the entry
        };
        t_current_statement_txn = out;
    }

    /// Task 7 (ShardedGraphEngine migration): open a statement transaction
    /// pinned to `shard_idx`'s per-shard engine.  Used by ShardedCoordinator
    /// shard workers so each worker's batch txn is confined to its own
    /// per-shard `GraphEngine`, eliminating contention on a shared
    /// TxnManager.  The resulting `StatementTxn.txn_id` is encoded with the
    /// shard index in the high 8 bits (same layout as `ShardedGraphEngine`'s
    /// own `beginTxn`), so `commitTxn` / `abortTxn` route back correctly.
    ///
    /// Caller guarantee: only one worker thread per `shard_idx` at a time
    /// (enforced by the coordinator's shard-queue design), so the per-shard
    /// engine is touched single-threadedly even though 16 workers run in
    /// parallel.
    pub fn beginStatementTxnForShard(
        self: *StorageAdapter,
        graph_name: []const u8,
        shard_idx: usize,
        out: *StatementTxn,
    ) !void {
        if (t_current_statement_txn != null) return error.NestedStatementTxn;

        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.engines.get(graph_name) orelse return error.GraphNotFound;
        };

        // Open a local txn on the shard directly, then re-encode it in the
        // ShardedGraphEngine wire format so commitTxn/abortTxn route back.
        const local_txn = try mg.engine.shards[shard_idx].beginTxn();
        const encoded_txn = encodeShardedTxn(shard_idx, local_txn);

        out.* = .{
            .mg = mg,
            .txn_id = encoded_txn,
            .graph_name = mg.name,
        };
        t_current_statement_txn = out;
    }

    /// R9 (2026-04-22): open an engine transaction that lives for the
    /// lifetime of a Geode-level logical transaction (BEGIN TX … COMMIT).
    /// All subsequent mutation calls from this thread on `graph_name`
    /// join this engine txn, so the whole Geode batch commits with a
    /// SINGLE WAL fsync.
    ///
    /// Restriction: only one session engine txn per thread at a time.
    /// If a Geode txn touches multiple graphs, the caller opens additional
    /// per-statement txns via `beginStatementTxn` (preferred) or simply
    /// lets the adapter's auto-batch (R7) path handle those sub-ops.
    pub fn beginSessionTxn(self: *StorageAdapter, graph_name: []const u8, out: *StatementTxn) !void {
        if (t_session_engine_txn != null) {
            log.err("adapter.beginSessionTxn called with an existing session txn on this thread (graph={s})", .{graph_name});
            return error.NestedSessionTxn;
        }
        if (t_current_statement_txn != null) {
            log.err("adapter.beginSessionTxn called while a per-statement txn is already open (graph={s})", .{graph_name});
            return error.NestedStatementTxn;
        }

        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.engines.get(graph_name) orelse return error.GraphNotFound;
        };

        const txn_id = try mg.engine.beginTxn();
        out.* = .{
            .mg = mg,
            .txn_id = txn_id,
            .graph_name = mg.name,
        };
        t_session_engine_txn = out;
    }

    /// R9: commit the session-scoped engine txn → ONE WAL fsync.
    pub fn commitSessionTxn(self: *StorageAdapter) !void {
        _ = self;
        const txn = t_session_engine_txn orelse return error.NoActiveSessionTxn;
        t_session_engine_txn = null;
        try txn.mg.engine.commitTxn(txn.txn_id);
    }

    /// R9: abort the session-scoped engine txn (no data-durability fsync).
    pub fn abortSessionTxn(self: *StorageAdapter) void {
        _ = self;
        const txn = t_session_engine_txn orelse return;
        t_session_engine_txn = null;
        // error-policy: A — best-effort session rollback; WAL recovery
        // supersedes a failed abort.
        txn.mg.engine.abortTxn(txn.txn_id) catch {};
    }

    /// R9 (2026-04-22, lazy): open a session-scoped engine txn using the
    /// thread-local `t_session_engine_txn_storage_lazy` backing slot.
    /// Used by the executor when it encounters the first mutation in a
    /// Geode BEGIN TX … COMMIT batch and has no direct pointer into
    /// `ServerState.session_engine_txn_storage`.  The slot is
    /// thread-local so it's naturally per-session (one QUIC stream handler
    /// runs on one pool thread).
    pub fn beginSessionTxnLazy(self: *StorageAdapter, graph_name: []const u8) !void {
        try self.beginSessionTxn(graph_name, &t_session_engine_txn_storage_lazy);
    }

    /// Acquire shared (read) locks on multiple named graphs simultaneously.
    /// Locks are acquired in alphabetical order to prevent deadlocks.
    /// Caller MUST pass the returned slice to releaseMultiGraphReadLocks when done.
    pub fn acquireMultiGraphReadLocks(
        self: *StorageAdapter,
        allocator: std.mem.Allocator,
        graph_names: []const []const u8,
    ) ![]GraphLockHandle {
        // Sort alphabetically for deadlock prevention.
        const sorted = try allocator.dupe([]const u8, graph_names);
        defer allocator.free(sorted);
        std.mem.sort([]const u8, sorted, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);

        var handles = try allocator.alloc(GraphLockHandle, sorted.len);
        var acquired: usize = 0;
        errdefer {
            while (acquired > 0) {
                acquired -= 1;
                self.releaseGraphReadLock(handles[acquired].mg, handles[acquired].hold_start_ns, .misc);
            }
            allocator.free(handles);
        }

        for (sorted) |name| {
            const acq = try self.acquireGraphReadLock(name);
            handles[acquired] = .{
                .graph_name = name,
                .mg = acq.mg,
                .hold_start_ns = acq.hold_start_ns,
            };
            acquired += 1;
        }

        return handles;
    }

    /// Release all locks acquired by acquireMultiGraphReadLocks and free the slice.
    pub fn releaseMultiGraphReadLocks(self: *StorageAdapter, allocator: std.mem.Allocator, handles: []GraphLockHandle) void {
        for (handles) |h| {
            self.releaseGraphReadLock(h.mg, h.hold_start_ns, .misc);
        }
        allocator.free(handles);
    }
};

/// Handle returned by acquireMultiGraphReadLocks, pairing a graph name with its locked ManagedGraph.
/// Carries `hold_start_ns` so the per-graph SHARED hold-time counters can be updated at release.
pub const GraphLockHandle = struct {
    graph_name: []const u8,
    mg: *ManagedGraph,
    hold_start_ns: u64,
};

fn mergeTupleLockIndex(label: []const u8, props: []const StorageAdapter.PropKV) usize {
    var h = std.hash.Wyhash.hash(0, label);
    var count_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_buf, @intCast(props.len), .little);
    h = std.hash.Wyhash.hash(h, &count_buf);

    // Order-independent combine so `{a: 1, b: 2}` and `{b: 2, a: 1}` land on
    // the same striped tuple mutex.
    for (props) |kv| {
        var ph = std.hash.Wyhash.hash(0x9e37_79b9_7f4a_7c15, kv.key);
        ph = hashPropertyValue(ph, kv.value);
        h +%= ph *% 0x9e37_79b9_7f4a_7c15;
    }

    return @intCast(h % merge_tuple_lock_count);
}

pub const merge_tuple_lock_count_for_test = merge_tuple_lock_count;

pub fn mergeTupleLockIndexForTest(label: []const u8, props: []const StorageAdapter.PropKV) usize {
    if (!builtin.is_test) @compileError("test-only helper");
    return mergeTupleLockIndex(label, props);
}

fn observeMaxAtomic(max: *std.atomic.Value(u64), value: u64) void {
    const observed = max.load(.monotonic);
    if (value > observed) {
        max.store(value, .monotonic);
    }
}

fn hashPropertyValue(seed: u64, value: graph_store.PropertyValue) u64 {
    var h = seed;
    const tag: u8 = switch (value) {
        .String => 1,
        .Int => 2,
        .Float => 3,
        .Bool => 4,
        .Null => 5,
        .ExtValue => 6,
        .Decimal => 7,
    };
    h = std.hash.Wyhash.hash(h, &[_]u8{tag});
    switch (value) {
        .String => |s| h = std.hash.Wyhash.hash(h, s),
        .Int => |i| {
            var v = i;
            h = std.hash.Wyhash.hash(h, std.mem.asBytes(&v));
        },
        .Float => |f| {
            var bits: u64 = @bitCast(f);
            h = std.hash.Wyhash.hash(h, std.mem.asBytes(&bits));
        },
        .Bool => |b| h = std.hash.Wyhash.hash(h, if (b) &[_]u8{1} else &[_]u8{0}),
        .Null => {},
        .ExtValue => {},
        .Decimal => |d| {
            var coeff = d.coeff;
            var scale = d.scale;
            h = std.hash.Wyhash.hash(h, std.mem.asBytes(&coeff));
            h = std.hash.Wyhash.hash(h, std.mem.asBytes(&scale));
        },
    }
    return h;
}

fn propertyValuesEqual(a: graph_store.PropertyValue, b: graph_store.PropertyValue) bool {
    return switch (a) {
        .String => |s| b == .String and std.mem.eql(u8, s, b.String),
        .Int => |i| b == .Int and i == b.Int,
        .Float => |f| b == .Float and f == b.Float,
        .Bool => |v| b == .Bool and v == b.Bool,
        .Null => b == .Null,
        .Decimal => |d| b == .Decimal and d.coeff == b.Decimal.coeff and d.scale == b.Decimal.scale,
        .ExtValue => false,
    };
}

const candidate_shard_mask_int = if (sharded_store.SHARD_COUNT <= 64) u64 else @compileError("candidate shard mask assumes <=64 shards");

fn candidateShardMask(candidates: []const u64) candidate_shard_mask_int {
    var mask: candidate_shard_mask_int = 0;
    for (candidates) |slot_id| {
        const shard_idx = gs.shard_count.shardOfNode(slot_id);
        mask |= @as(candidate_shard_mask_int, 1) << @intCast(shard_idx);
    }
    return mask;
}

pub fn candidateShardMaskForTest(candidates: []const u64) candidate_shard_mask_int {
    if (!builtin.is_test) @compileError("test-only helper");
    return candidateShardMask(candidates);
}

fn lockCandidateShardReads(mg: *ManagedGraph, candidates: []const u64) candidate_shard_mask_int {
    const io = std.Io.Threaded.global_single_threaded.io();
    const mask = candidateShardMask(candidates);
    for (&mg.shard_locks, 0..) |*sl, idx| {
        if ((mask & (@as(candidate_shard_mask_int, 1) << @intCast(idx))) != 0) {
            sl.lockSharedUncancelable(io);
        }
    }
    return mask;
}

fn unlockCandidateShardReads(mg: *ManagedGraph, mask: candidate_shard_mask_int) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var i: usize = sharded_store.SHARD_COUNT;
    while (i > 0) {
        i -= 1;
        if ((mask & (@as(candidate_shard_mask_int, 1) << @intCast(i))) != 0) {
            mg.shard_locks[i].unlockShared(io);
        }
    }
}

fn copySmallestMergePropCandidates(
    adapter: *StorageAdapter,
    allocator: Allocator,
    mg: *ManagedGraph,
    label: []const u8,
    props: []const StorageAdapter.PropKV,
) ![]u64 {
    // H4: build the exact index on first access if it was deferred at open
    // (this MERGE-preselect path reads postings for both probes below).
    try ensureExactNodePropertyIndexBuilt(adapter, mg);
    const io = std.Io.Threaded.global_single_threaded.io();
    const label_id = blk: {
        mg.string_indexes_mutex.lockUncancelable(io);
        defer mg.string_indexes_mutex.unlock(io);
        break :blk mg.label_dict.getId(label) orelse return try allocator.alloc(u64, 0);
    };

    // CANARY: REQ=REQ-QUIC-HC-162; FEATURE="High-Concurrency Mutations"; ASPECT=SmallestPostingPreselect; STATUS=IMPL; TEST=test_graph_storage_adapter_metrics; OWNER=storage; UPDATED=2026-05-29
    //
    // The 4096x8 mixed workload uses MERGE (:HCParallel {worker, seq}).
    // `worker` postings stay tiny while `seq` postings grow into thousands
    // of ids. The old probe copied every property posting before choosing the
    // smallest, so each mutation could copy a large `seq` list while holding
    // the graph SHARED lock. First read posting lengths under the per-shard
    // exact-index mutexes, then copy only the smallest candidate list.
    var best_key: ?[]const u8 = null;
    var best_value_hash: u64 = 0;
    var best_len: usize = std.math.maxInt(usize);
    for (props) |kv| {
        const storage_value = try toStorageProperty(allocator, kv.value);
        defer freeTemporaryStorageProperty(allocator, storage_value);
        const value_hash = try hashStorageProperty(allocator, storage_value);
        _ = g_exact_node_property_lookup_count.fetchAdd(1, .monotonic);
        const posting_len = (try mg.exact_node_property_index.postingLenIfPresent(label_id, kv.key, value_hash)) orelse {
            return try allocator.alloc(u64, 0);
        };

        if (posting_len == 0) {
            return try allocator.alloc(u64, 0);
        }

        if (posting_len < best_len) {
            best_key = kv.key;
            best_value_hash = value_hash;
            best_len = posting_len;
            if (posting_len == 1) break;
        }
    }

    const key = best_key orelse return try allocator.alloc(u64, 0);
    return (try mg.exact_node_property_index.copyIfPresent(allocator, label_id, key, best_value_hash)) orelse
        try allocator.alloc(u64, 0);
}

fn nodeMatchesMergeProps(node: *const graph_store.Node, graph_name: []const u8, label: []const u8, props: []const StorageAdapter.PropKV) bool {
    if (!std.mem.eql(u8, node.graph_name, graph_name)) return false;
    var has_label = false;
    for (node.labels) |actual| {
        if (std.mem.eql(u8, actual, label)) {
            has_label = true;
            break;
        }
    }
    if (!has_label) return false;

    for (props) |kv| {
        const actual = node.properties.get(kv.key) orelse return false;
        if (!propertyValuesEqual(actual, kv.value)) return false;
    }
    return true;
}

fn findNodeMatchingMergeProps(
    adapter: *StorageAdapter,
    allocator: Allocator,
    mg: *ManagedGraph,
    store: *graph_store.GraphStore,
    graph_name: []const u8,
    label: []const u8,
    props: []const StorageAdapter.PropKV,
) !?u64 {
    // CANARY: REQ=REQ-QUIC-HC-111; FEATURE="High-Concurrency Mutations"; ASPECT=MultiPropertyMergeIndexedProbe; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=storage; UPDATED=2026-05-27
    //
    // GAP-0046: the multi-property MERGE match MUST run behind the SAME
    // hydration chokepoint as the single-key `store.lookupMergeCandidate` and
    // the edge-endpoint `store.lookupPublicNodeIdByLabelAndAllProps`. Without
    // it, a DEFERRED (lazy-hydration) graph — the state a crash/OOM restart
    // reopens into — has an EMPTY resident IdMap (loop1) and node cache
    // (loop2): the exact-index candidate slots below resolve to a null public
    // id or a non-resident `store.nodes.getPtr` miss, so the probe reports NO
    // match and the MERGE wrongly CREATEs a duplicate. (Observed at scale as
    // ~3.2M dup :Taxon after an OOM restart re-ran the source mid-ingest — the
    // same read-path "source split" family as the deferred count fix.)
    //
    // Composite fast path (mirrors `lookupPublicNodeIdByLabelAndAllProps`): when
    // the merge props EXACTLY match a registered composite key (the from-dump
    // `{source, source_id}` node key), resolve the WHOLE key in ONE MAINTAINED,
    // eviction-INDEPENDENT merge-index probe — O(1), no node-page read, and
    // authoritative (the composite index is complete and rebuilt on hydration,
    // and survives node-cache eviction). `lookupCompositeMergeCandidate` runs
    // ensureGraphHydrated itself, so the hot path is guarded with NO redundant
    // acquire. This is the enterprise hot path and is collision-correct
    // (source_id is not globally unique).
    if (graph_store.compositeKeyIndexForFilters(props)) |composite_idx| {
        var cid: u64 = 0;
        switch (store.lookupCompositeMergeCandidate(graph_name, label, composite_idx, props, &cid)) {
            .found => return cid,
            .not_found => return null,
            // Value type can't be encoded into the composite key — fall through
            // to the exact-index candidate seek (guarded + eviction-safe below).
            .not_indexable => {},
        }
    }

    // Fallback (no registered composite, or an unencodable value type): the
    // exact-index candidate seek reads store IdMap (loop1) + node cache (loop2),
    // so it needs the same hydration chokepoint before it can trust them.
    // ensureGraphHydrated is a lock-free atomic fast-path once built.
    store.ensureGraphHydrated(graph_name);

    // Multi-property MERGE used to scan every node carrying `label` on each
    // miss. Under fan-out this made unique tuple inserts O(label cardinality).
    // Start from the smallest exact-property posting instead, then verify the
    // full tuple under shard read locks to tolerate hash collisions.
    const candidates = try copySmallestMergePropCandidates(adapter, allocator, mg, label, props);
    defer allocator.free(candidates);
    if (candidates.len == 0) return null;

    const id_map = blk: {
        mg.string_indexes_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer mg.string_indexes_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        break :blk store.getIdMap(graph_name) orelse return null;
    };

    // CANARY: REQ=REQ-QUIC-HC-121; FEATURE="High-Concurrency Mutations"; ASPECT=CandidateShardReadLocks; STATUS=TESTED; TEST=test_graph_storage_adapter_metrics; OWNER=storage; UPDATED=2026-05-28
    //
    // Multi-property MERGE probes begin from the smallest exact-property
    // posting. Unique-tuple ingest usually has zero or a handful of candidates,
    // so taking all shard read locks before every insert creates unnecessary
    // reader/writer contention against the shard workers. Lock only the shards
    // that can contain candidate slot ids; the no-candidate miss path returns
    // without touching shard locks at all.
    const candidate_mask = lockCandidateShardReads(mg, candidates);
    defer unlockCandidateShardReads(mg, candidate_mask);

    for (candidates) |slot_id| {
        const public_id = @as(u64, @truncate(id_map.nodeUuid(slot_id) orelse continue));
        // GAP-0046: hydrate-on-miss. Under a bounded node cache (or right after a
        // deferred reopen) the matching node need not be resident; a plain
        // `getPtr` would miss it and the MERGE would wrongly create a duplicate.
        const node = (store.nodes.getOrHydratePtr(public_id) catch null) orelse continue;
        if (nodeMatchesMergeProps(node, graph_name, label, props)) return public_id;
    }
    return null;
}

/// Result of `StorageAdapter.acquireGraphReadLock` — a locked `ManagedGraph`
/// plus the monotonic-ns timestamp of the acquire so the matching
/// `releaseGraphReadLock` can update the per-graph SHARED hold-time counters.
pub const ReadLockAcquisition = struct {
    mg: *ManagedGraph,
    hold_start_ns: u64,
};

/// CLOCK_MONOTONIC nanoseconds; used by the cancelable write-lock path (R2).
fn monoNanosNow() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ============================================================================
// UUID generation helper
// ============================================================================

fn generateUuid() [16]u8 {
    // error-policy: D — newV7's only error is InvalidTimestamp (system clock
    // before 1970 or beyond i64 milliseconds); impossible on a sane clock.
    return (uuid.newV7() catch unreachable).bytes;
}

// ============================================================================
// Unit Tests
// ============================================================================

test "LabelStringDict basic operations" {
    const allocator = std.testing.allocator;
    var dict = LabelStringDict.init(allocator);
    defer dict.deinit();

    // First assignment
    const id_person = try dict.getOrCreate("Person");
    try std.testing.expectEqual(@as(gs.LabelId, 1), id_person);

    // Same label returns same id
    const id_person2 = try dict.getOrCreate("Person");
    try std.testing.expectEqual(id_person, id_person2);

    // Different label gets a different id
    const id_place = try dict.getOrCreate("Place");
    try std.testing.expectEqual(@as(gs.LabelId, 2), id_place);
    try std.testing.expect(id_person != id_place);

    // Reverse lookup
    try std.testing.expectEqualStrings("Person", dict.getString(id_person).?);
    try std.testing.expectEqualStrings("Place", dict.getString(id_place).?);
    try std.testing.expectEqual(@as(?[]const u8, null), dict.getString(999));

    // Forward lookup
    try std.testing.expectEqual(id_person, dict.getId("Person").?);
    try std.testing.expectEqual(@as(?gs.LabelId, null), dict.getId("Unknown"));

    // Count
    try std.testing.expectEqual(@as(u32, 2), dict.count());
}

test "LabelStringDict starts at id 1" {
    const allocator = std.testing.allocator;
    var dict = LabelStringDict.init(allocator);
    defer dict.deinit();

    const first = try dict.getOrCreate("A");
    try std.testing.expectEqual(@as(gs.LabelId, 1), first);
}

test "toStorageProperty round-trip for scalars" {
    const allocator = std.testing.allocator;
    // Int
    const gs_int = try toStorageProperty(allocator, .{ .Int = 42 });
    try std.testing.expectEqual(@as(i64, 42), gs_int.int);

    // Float
    const gs_float = try toStorageProperty(allocator, .{ .Float = 3.14 });
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), gs_float.float, 0.001);

    // Bool
    const gs_bool = try toStorageProperty(allocator, .{ .Bool = true });
    try std.testing.expect(gs_bool.bool);

    // Null
    const gs_null = try toStorageProperty(allocator, .Null);
    try std.testing.expectEqual(gs.PropertyValue.null, gs_null);

    // String
    const gs_str = try toStorageProperty(allocator, .{ .String = "hello" });
    try std.testing.expectEqualStrings("hello", gs_str.string);

    // Decimal
    const gs_dec = try toStorageProperty(allocator, .{ .Decimal = .{ .coeff = 12345, .scale = 2 } });
    try std.testing.expectEqual(@as(i128, 12345), gs_dec.decimal.coeff);
    try std.testing.expectEqual(@as(u8, 2), gs_dec.decimal.scale);
}

test "ExtValue survives adapter property translation" {
    const allocator = std.testing.allocator;
    const nested = try allocator.dupe(u8, "nested");
    // nested ownership transfers to ext.ExtValue.List below;
    // freeDetachedExtValue will free it via the List slice.

    const ext = graph_store.PropertyValue{
        .ExtValue = .{
            .List = try allocator.dupe(@import("../eval_extended.zig").ExtValue, &.{
                .{ .Int = 7 },
                .{ .Str = nested },
            }),
        },
    };
    defer graph_store.freeDetachedExtValue(allocator, ext.ExtValue);

    const storage_val = try toStorageProperty(allocator, ext);
    defer freeTemporaryStorageProperty(allocator, storage_val);

    // The type_tag comes from the first byte of the codec encoding (property_tag_ext = 0x86)
    try std.testing.expectEqual(@as(u16, 0x86), storage_val.ext.type_tag);
    try std.testing.expect(storage_val.ext.data.len > 0);

    const roundtrip = try fromStorageProperty(allocator, storage_val);
    defer graph_store.freeDetachedExtValue(allocator, roundtrip.ExtValue);

    try std.testing.expect(roundtrip == .ExtValue);
    try std.testing.expectEqual(@as(usize, 2), roundtrip.ExtValue.List.len);
    try std.testing.expectEqual(@as(i64, 7), roundtrip.ExtValue.List[0].Int);
    try std.testing.expectEqualStrings("nested", roundtrip.ExtValue.List[1].Str);
}

test "fromStorageProperty round-trip for scalars" {
    const allocator = std.testing.allocator;

    // Int
    const geode_int = try fromStorageProperty(allocator, .{ .int = -7 });
    try std.testing.expectEqual(@as(i64, -7), geode_int.Int);

    // Float
    const geode_float = try fromStorageProperty(allocator, .{ .float = 2.72 });
    try std.testing.expectApproxEqAbs(@as(f64, 2.72), geode_float.Float, 0.001);

    // Bool
    const geode_bool = try fromStorageProperty(allocator, .{ .bool = false });
    try std.testing.expect(!geode_bool.Bool);

    // Null
    const geode_null = try fromStorageProperty(allocator, .null);
    try std.testing.expectEqual(graph_store.PropertyValue.Null, geode_null);

    // String (must free)
    const geode_str = try fromStorageProperty(allocator, .{ .string = "world" });
    defer allocator.free(geode_str.String);
    try std.testing.expectEqualStrings("world", geode_str.String);

    // Decimal
    const geode_dec = try fromStorageProperty(allocator, .{ .decimal = .{ .coeff = 99, .scale = 3 } });
    try std.testing.expectEqual(@as(i128, 99), geode_dec.Decimal.coeff);
    try std.testing.expectEqual(@as(u8, 3), geode_dec.Decimal.scale);
}

test "StorageAdapter: exact node-property lookup follows property and label mutations" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const graph = "lookup_graph";
    const node_id = try adapter.createNode(graph, &[_][]const u8{"User"});
    try adapter.setNodeProperty(graph, node_id, "node_id", .{ .Int = 7 });

    const initial = try adapter.getCandidateNodesByLabelAndProperty(graph, "User", "node_id", .{ .Int = 7 }, allocator);
    defer allocator.free(initial);
    try std.testing.expectEqual(@as(usize, 1), initial.len);
    try std.testing.expectEqual(node_id, initial[0]);

    try adapter.setNodeProperty(graph, node_id, "node_id", .{ .Int = 8 });

    const stale = try adapter.getCandidateNodesByLabelAndProperty(graph, "User", "node_id", .{ .Int = 7 }, allocator);
    defer allocator.free(stale);
    try std.testing.expectEqual(@as(usize, 0), stale.len);

    const updated = try adapter.getCandidateNodesByLabelAndProperty(graph, "User", "node_id", .{ .Int = 8 }, allocator);
    defer allocator.free(updated);
    try std.testing.expectEqual(@as(usize, 1), updated.len);
    try std.testing.expectEqual(node_id, updated[0]);

    try adapter.addNodeLabel(graph, node_id, "Admin");
    const added_label = try adapter.getCandidateNodesByLabelAndProperty(graph, "Admin", "node_id", .{ .Int = 8 }, allocator);
    defer allocator.free(added_label);
    try std.testing.expectEqual(@as(usize, 1), added_label.len);
    try std.testing.expectEqual(node_id, added_label[0]);

    try adapter.removeNodeLabel(graph, node_id, "Admin");
    const removed_label = try adapter.getCandidateNodesByLabelAndProperty(graph, "Admin", "node_id", .{ .Int = 8 }, allocator);
    defer allocator.free(removed_label);
    try std.testing.expectEqual(@as(usize, 0), removed_label.len);

    try adapter.deleteNode(graph, node_id);
    const deleted = try adapter.getCandidateNodesByLabelAndProperty(graph, "User", "node_id", .{ .Int = 8 }, allocator);
    defer allocator.free(deleted);
    try std.testing.expectEqual(@as(usize, 0), deleted.len);
}

test {
    std.testing.refAllDecls(@This());
}

// ============================================================================
// Integration Tests — StorageAdapter with real GraphEngine instances
// ============================================================================

/// Minimal GraphConfig suitable for in-process integration tests.
fn testConfig() gs.GraphConfig {
    return .{
        .page_size = 4096,
        .buffer_pool_pages = 64,
    };
}

test "StorageAdapter: create and query graph" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("test_graph");

    try std.testing.expect(adapter.graphExists("test_graph"));
    try std.testing.expect(!adapter.graphExists("nonexistent"));
}

// ===========================================================================
// Per-shard lock helpers (Phase 2, graph-sharding plan)
// ===========================================================================

/// Writer-preference back-off for the SHARED acquirers of `mg.rwlock`. When
/// ANY exclusive acquirer (the checkpoint OR an edge-phase schema/MERGE op)
/// has announced it is waiting for the per-graph EXCLUSIVE lock
/// (`mg.exclusive_waiting > 0`), a would-be SHARED acquirer naps briefly
/// instead of taking the lock, so the in-flight reader set drains and the
/// exclusive `tryLock` wins. Bounded by a hard deadline (safety valve): if the
/// exclusive holder is pathologically slow we proceed anyway rather than block
/// readers forever (no deadlock — the std RwLock then serialises us normally
/// once the exclusive op holds the lock). The light checkpoint is O(dirty) and
/// the edge schema apply is brief, so in practice the wait is sub-millisecond.
///
/// Consulted ONLY by SHARED acquirers — exclusive acquirers never call this,
/// so two pending exclusives never wedge each other (they race `tryLock`).
fn exclusiveWaitingBackoff(mg: *ManagedGraph) void {
    if (mg.exclusive_waiting.load(.acquire) == 0) return;
    const start_ns = monoNanosNow();
    // The safety-valve MUST outlast the checkpoint's own bounded acquire
    // deadline (checkpointAllEx LIGHT path: 5s). If it is shorter, backing-off
    // writers resume and re-take SHARED while the checkpoint is still spinning
    // on `tryLock`, so the reader set never reaches the zero-reader instant the
    // checkpoint needs — the checkpoint skips every cycle, `pending_bulk_ops`
    // never resets, and RSS grows without bound (observed: state always pinned
    // at exactly one reader at the 5s deadline). Park past the checkpoint
    // deadline (+margin) so the reader set genuinely drains; if the exclusive
    // holder is pathologically stuck the reader still proceeds eventually (no
    // deadlock — it then serialises on the held EXCLUSIVE lock normally). The
    // exclusive acquirer clears its `exclusive_waiting` contribution the instant
    // it acquires or gives up, so in the common case readers unpark well before
    // this cap.
    const max_wait_ns: u64 = 8 * std.time.ns_per_s;
    var sleep_ns: u64 = 50 * std.time.ns_per_us;
    const max_sleep_ns: u64 = 1 * std.time.ns_per_ms;
    while (mg.exclusive_waiting.load(.acquire) > 0) {
        if (monoNanosNow() -| start_ns >= max_wait_ns) break;
        const req = std.os.linux.timespec{
            .sec = @intCast(sleep_ns / std.time.ns_per_s),
            .nsec = @intCast(sleep_ns % std.time.ns_per_s),
        };
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.nanosleep(&req, &rem);
        sleep_ns = @min(sleep_ns * 2, max_sleep_ns);
    }
}

/// Acquire EXCLUSIVE mode on the single shard owning `key`.
/// Protocol: take `mg.rwlock` SHARED (coexists with other shard
/// writers; blocks whole-graph-exclusive ops), then take
/// `shard_locks[shardIndex(key)]` EXCLUSIVE.
///
/// Use for bulk mutations keyed by a specific `node_id`.  For
/// cross-shard ops (edge insert spanning two shards) see the
/// ascending-index acquire pattern in `bulkInsertEdgeWithIds`.
pub fn acquireShardWriteLock(mg: *ManagedGraph, key: u64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const _t_start = monoNanosNow();
    mg.rwlock.lockSharedUncancelable(io);
    _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
    _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
    // NOTE: SHARED hold-time NOT measured here. The matching
    // releaseShardWriteLock would need to be plumbed with a hold_start_ns
    // parameter (same pattern as releaseGraphReadLock at line ~3570).
    // Currently test-only; if promoted to production callers, instrument
    // before metric `avg_shared_hold_ns_per_acq` is consumed.
    const idx = sharded_store.shardIndex(key);
    mg.shard_locks[idx].lockUncancelable(io);
}

/// Release the shard lock + whole-graph SHARED acquired by
/// `acquireShardWriteLock`.
pub fn releaseShardWriteLock(mg: *ManagedGraph, key: u64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const idx = sharded_store.shardIndex(key);
    mg.shard_locks[idx].unlock(io);
    mg.rwlock.unlockShared(io);
}

/// Deadline-aware variant used by the coordinator's shard-apply
/// loop.  `deadline_mono_ns` caps waiting on the shard-lock step
/// only — the whole-graph SHARED rwlock is assumed fast because it
/// only conflicts with whole-graph EXCLUSIVE ops (RESTORE, etc.)
/// which are rare.
pub fn acquireShardWriteLockCancelable(
    mg: *ManagedGraph,
    key: u64,
    deadline_mono_ns: u64,
) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const _t_start = monoNanosNow();
    mg.rwlock.lockSharedUncancelable(io);
    _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
    _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
    // NOTE: SHARED hold-time NOT measured here. The matching
    // releaseShardWriteLock would need to be plumbed with a hold_start_ns
    // parameter (same pattern as releaseGraphReadLock at line ~3570).
    // Currently test-only; if promoted to production callers, instrument
    // before metric `avg_shared_hold_ns_per_acq` is consumed.
    errdefer mg.rwlock.unlockShared(io);
    const idx = sharded_store.shardIndex(key);
    if (mg.shard_locks[idx].tryLock(io)) return;
    var sleep_ns: u64 = 200 * std.time.ns_per_us;
    const max_sleep_ns: u64 = 4 * std.time.ns_per_ms;
    while (true) {
        const now = monoNanosNowLocal();
        if (now >= deadline_mono_ns) return error.Deadline;
        const remaining = deadline_mono_ns - now;
        const nap_ns = @min(sleep_ns, remaining);
        const req = std.os.linux.timespec{
            .sec = @intCast(nap_ns / std.time.ns_per_s),
            .nsec = @intCast(nap_ns % std.time.ns_per_s),
        };
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.nanosleep(&req, &rem);
        if (mg.shard_locks[idx].tryLock(io)) return;
        sleep_ns = @min(sleep_ns * 2, max_sleep_ns);
    }
}

/// Acquire `mg.rwlock` EXCLUSIVE + every shard lock EXCLUSIVE in
/// ascending index order.  Used by RESTORE, bulk DELETE-all, and
/// other full-graph writes that need global isolation.  The rwlock
/// EXCLUSIVE acquire blocks any new `acquireShardWriteLock` caller
/// (they take `rwlock` SHARED first) and waits for in-flight shard
/// writers to release their SHARED hold.
pub fn acquireWholeGraphExclusive(mg: *ManagedGraph) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const _t_start = monoNanosNow();
    // EDGE-PHASE 40001 FIX #2 (2026-06-22): announce a pending EXCLUSIVE
    // acquire (RESTORE/BACKUP take this path) so SHARED acquirers back off via
    // `exclusiveWaitingBackoff` and let this whole-graph exclusive win instead
    // of being starved by a recurring reader (the checkpoint loop or query
    // MATCH). Same counter + deadlock-free contract as
    // `acquireGraphWriteLockCancelable`: cleared via defer; exclusive acquirers
    // never consult the backoff, so two exclusives never wedge each other.
    _ = mg.exclusive_waiting.fetchAdd(1, .release);
    defer _ = mg.exclusive_waiting.fetchSub(1, .release);
    // HANG FIX (2026-05-22): re-probe via `tryLock` rather than parking
    // unboundedly on the RwLock's internal counting semaphore (which can be
    // wedged forever by a lost wakeup — see the rationale in
    // `StorageAdapter.acquireGraphWriteLockCancelable`).  `tryLock` reads
    // `rl.state` directly so it always re-observes the true reader count.
    if (!mg.rwlock.tryLock(io)) {
        var sleep_ns: u64 = 100 * std.time.ns_per_us;
        const max_sleep_ns: u64 = 2 * std.time.ns_per_ms;
        while (true) {
            const req = std.os.linux.timespec{
                .sec = @intCast(sleep_ns / std.time.ns_per_s),
                .nsec = @intCast(sleep_ns % std.time.ns_per_s),
            };
            var rem: std.os.linux.timespec = undefined;
            _ = std.os.linux.nanosleep(&req, &rem);
            if (mg.rwlock.tryLock(io)) break;
            sleep_ns = @min(sleep_ns * 2, max_sleep_ns);
        }
    }
    _ = mg.rwlock_exclusive_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
    for (&mg.shard_locks) |*sl| sl.lockUncancelable(io);
}

/// Release the whole-graph EXCLUSIVE acquired by
/// `acquireWholeGraphExclusive`.  Releases shard locks in reverse
/// index order (symmetry with acquire; not strictly required by
/// the rwlock contract, but keeps debug traces sane).
pub fn releaseWholeGraphExclusive(mg: *ManagedGraph) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var i: usize = sharded_store.SHARD_COUNT;
    while (i > 0) {
        i -= 1;
        mg.shard_locks[i].unlock(io);
    }
    mg.rwlock.unlock(io);
}

fn monoNanosNowLocal() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime builtin.os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "StorageAdapter: create node with labels" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const labels = &[_][]const u8{ "Person", "Employee" };
    const node_id = try adapter.createNode("test_graph", labels);
    try std.testing.expect(node_id > 0);

    const got_labels = try adapter.getNodeLabels("test_graph", node_id, allocator);
    defer {
        for (got_labels) |s| allocator.free(s);
        allocator.free(got_labels);
    }

    try std.testing.expectEqual(@as(usize, 2), got_labels.len);
}

test "StorageAdapter: create and traverse edge" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const node_a = try adapter.createNode("test_graph", &[_][]const u8{});
    const node_b = try adapter.createNode("test_graph", &[_][]const u8{});

    _ = try adapter.createEdge("test_graph", node_a, node_b, "KNOWS");

    const edges = try adapter.getOutgoingEdges("test_graph", node_a, allocator);
    defer allocator.free(edges);

    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqual(node_b, edges[0].neighbor);
}

test "StorageAdapter: drop graph" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("drop_me");
    try std.testing.expect(adapter.graphExists("drop_me"));

    adapter.dropGraph("drop_me");
    try std.testing.expect(!adapter.graphExists("drop_me"));
}

test "StorageAdapter: registry persists graph discovery across restart" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        const graph = "persisted_graph";
        const node_id = try adapter.createNode(graph, &[_][]const u8{"Person"});
        try adapter.setNodeProperty(graph, node_id, "name", .{ .String = "Alice" });
        try adapter.checkpointAll();
        try std.testing.expect(adapter.graphExists(graph));
    }

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        try std.testing.expect(adapter.graphExists("persisted_graph"));

        const names = try adapter.listGraphNames(allocator);
        defer {
            for (names) |name| allocator.free(name);
            allocator.free(names);
        }

        var found = false;
        for (names) |name| {
            if (std.mem.eql(u8, name, "persisted_graph")) found = true;
        }
        try std.testing.expect(found);

        _ = try adapter.getOrCreateGraph("persisted_graph");
        try std.testing.expectEqual(@as(u64, 1), try adapter.nodeCount("persisted_graph"));
    }
}

test "StorageAdapter: node and edge counts" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const graph = "count_graph";
    const n1 = try adapter.createNode(graph, &[_][]const u8{});
    const n2 = try adapter.createNode(graph, &[_][]const u8{});
    const n3 = try adapter.createNode(graph, &[_][]const u8{});
    _ = try adapter.createEdge(graph, n1, n2, "REL");
    _ = try adapter.createEdge(graph, n2, n3, "REL");

    try std.testing.expectEqual(@as(u64, 3), try adapter.nodeCount(graph));
    try std.testing.expectEqual(@as(u64, 2), try adapter.edgeCount(graph));
}

test "StorageAdapter: registry header next ids include unloaded graphs" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        const n1 = try adapter.createNode("persisted_graph", &[_][]const u8{});
        const n2 = try adapter.createNode("persisted_graph", &[_][]const u8{});
        _ = try adapter.createEdge("persisted_graph", n1, n2, "REL");
        try adapter.checkpointAll();
    }

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        _ = try adapter.createNode("fresh_graph", &[_][]const u8{});
        try adapter.checkpointAll();
    }

    const registry_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{path});
    defer allocator.free(registry_path);

    var registry = gs.registry.GraphRegistry.init(allocator);
    defer registry.deinit();
    try registry.loadFromFile(registry_path);

    try std.testing.expectEqual(@as(usize, 2), registry.graphCount());
    // 2026-04-27 sharded-engine update: under the legacy single-engine
    // layout the test pinned `next_node_id == 3` and `next_edge_id == 2`
    // because IDs were dense and sequential.  ShardedGraphEngine
    // (SHARD_COUNT=16) round-robins allocations across striped per-shard
    // counters: each shard's `manifest.next_node_id` starts at its base
    // (shard 0 → 16, shard k>0 → k) and advances by SHARD_COUNT on every
    // allocation.  Two allocations on shards 0 and 1 leave shard 0 at
    // `next_node_id = 32` and shard 1 at `next_node_id = 17`.  The
    // registry header takes the max across shards, so the surviving
    // contract is "monotonically advances and is large enough to never
    // collide with a re-issued id" — pin only that, not the exact value.
    try std.testing.expect(registry.next_node_id > 1);
    try std.testing.expect(registry.next_edge_id > 1);
}

test "StorageAdapter: acquireGraphReadLock and releaseGraphReadLock" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("lock_test_graph");

    // Acquire a shared read lock and verify we get back a valid ManagedGraph.
    const acq = try adapter.acquireGraphReadLock("lock_test_graph");
    try std.testing.expectEqualStrings("lock_test_graph", acq.mg.name);
    adapter.releaseGraphReadLock(acq.mg, acq.hold_start_ns, .misc);

    // Error on nonexistent graph.
    try std.testing.expectError(error.GraphNotFound, adapter.acquireGraphReadLock("no_such_graph"));
}

test "StorageAdapter: acquireGraphWriteLock and releaseGraphWriteLock" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("write_lock_graph");

    const mg = try adapter.acquireGraphWriteLock("write_lock_graph");
    try std.testing.expectEqualStrings("write_lock_graph", mg.name);
    adapter.releaseGraphWriteLock(mg);

    // Error on nonexistent graph.
    try std.testing.expectError(error.GraphNotFound, adapter.acquireGraphWriteLock("no_such_graph"));
}

test "StorageAdapter: acquireMultiGraphReadLocks acquires in alphabetical order" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("zebra");
    _ = try adapter.getOrCreateGraph("alpha");
    _ = try adapter.getOrCreateGraph("mango");

    const names = &[_][]const u8{ "zebra", "alpha", "mango" };
    const handles = try adapter.acquireMultiGraphReadLocks(allocator, names);
    defer adapter.releaseMultiGraphReadLocks(allocator, handles);

    try std.testing.expectEqual(@as(usize, 3), handles.len);

    // Verify all three graphs are locked and names are accessible.
    var found_alpha = false;
    var found_mango = false;
    var found_zebra = false;
    for (handles) |h| {
        if (std.mem.eql(u8, h.graph_name, "alpha")) found_alpha = true;
        if (std.mem.eql(u8, h.graph_name, "mango")) found_mango = true;
        if (std.mem.eql(u8, h.graph_name, "zebra")) found_zebra = true;
    }
    try std.testing.expect(found_alpha);
    try std.testing.expect(found_mango);
    try std.testing.expect(found_zebra);
}

test "StorageAdapter: acquireMultiGraphReadLocks returns error on missing graph" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    _ = try adapter.getOrCreateGraph("exists");

    const names = &[_][]const u8{ "exists", "does_not_exist" };
    try std.testing.expectError(error.GraphNotFound, adapter.acquireMultiGraphReadLocks(allocator, names));
}

// ============================================================================
// Per-graph subsystem colocation tests (Tasks 5-7)
// ============================================================================

test "StorageAdapter: per-graph audit logger is created and accessible" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const mg = try adapter.getOrCreateGraph("__geode_security");

    // Per-graph audit logger should be initialised (non-null).
    try std.testing.expect(mg.audit_logger != null);

    // Accessor on StorageAdapter returns the same logger.
    const logger = adapter.getAuditLogger("__geode_security");
    try std.testing.expect(logger != null);
    try std.testing.expect(logger.? == mg.audit_logger.?);

    // Verify audit.jsonl file exists inside the graph directory.
    const graph_dir = try StorageAdapter.graphDirPath(allocator, path, mg.uuid);
    defer allocator.free(graph_dir);

    const audit_path = try std.fmt.allocPrint(allocator, "{s}/audit.jsonl", .{graph_dir});
    defer allocator.free(audit_path);

    // statFile returns a Stat struct on success; an error means the file does not exist.
    _ = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), audit_path, .{}) catch |err| {
        std.debug.print("audit.jsonl should exist: {}\n", .{err});
        return err;
    };
}

test "StorageAdapter: per-graph timeseries store is created and accessible" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const mg = try adapter.getOrCreateGraph("ts_graph");

    // Per-graph timeseries store should be initialised (non-null).
    try std.testing.expect(mg.ts_store != null);

    // Accessor on StorageAdapter returns the same store.
    const store = adapter.getTimeseriesStore("ts_graph");
    try std.testing.expect(store != null);
    try std.testing.expect(store.? == mg.ts_store.?);

    // Verify timeseries/ subdirectory exists inside the graph directory.
    const graph_dir = try StorageAdapter.graphDirPath(allocator, path, mg.uuid);
    defer allocator.free(graph_dir);

    const ts_dir = try std.fmt.allocPrint(allocator, "{s}/timeseries", .{graph_dir});
    defer allocator.free(ts_dir);

    var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), ts_dir, .{}) catch |err| {
        std.debug.print("timeseries dir open failed: {}\n", .{err});
        return err;
    };
    dir.close(std.Io.Threaded.global_single_threaded.io());
}

test "StorageAdapter: per-graph FTS index is created, persists, and accessible" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    // Capture the graph UUID so we can reopen later.
    var graph_uuid: [16]u8 = undefined;

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        const mg = try adapter.getOrCreateGraph("fts_graph");
        graph_uuid = mg.uuid;

        // Lazy engine: no eager default index. The adapter is engine-free and
        // the legacy `fts_index` facade stays null until an index is created;
        // the fts/ base dir + adapter ARE eager.
        try std.testing.expect(mg.fts_index == null);
        try std.testing.expect(mg.fts_dir != null);
        try std.testing.expect(mg.fts_adapter != null);

        // Create the default index explicitly (builds the fts-storage Engine on
        // this thread), then drive it via the production lazy named facade.
        try mg.fts_adapter.?.createIndex("default");
        const fts = mg.getFulltextIndexNamed(allocator, "default") orelse return error.TestUnexpectedNull;

        // Index a document into the per-graph FTS index (facade → fts-storage
        // engine).
        try fts.indexDocument(42, "the quick brown fox jumps over the lazy dog");
        // Explicit checkpoint so the segment is durable for the reopen below.
        try fts.flush();

        // The just-indexed document must be searchable in this session.
        const hits = try fts.search("fox", 10);
        defer allocator.free(hits);
        try std.testing.expect(hits.len >= 1);
        try std.testing.expectEqual(@as(u64, 42), hits[0].doc_id);

        // Verify fts/ subdirectory exists inside the graph directory.
        const graph_dir = try StorageAdapter.graphDirPath(allocator, path, mg.uuid);
        defer allocator.free(graph_dir);

        const fts_dir = try std.fmt.allocPrint(allocator, "{s}/fts", .{graph_dir});
        defer allocator.free(fts_dir);

        var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), fts_dir, .{}) catch |err| {
            std.debug.print("fts dir open failed: {}\n", .{err});
            return err;
        };
        dir.close(std.Io.Threaded.global_single_threaded.io());

        // deinit flushes + tears down the fts-storage engine; durability is
        // owned by its WAL/segments.
    }

    // Reopen the adapter and verify FTS data persists (the fts-storage engine
    // replays its WAL/segments on init).
    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        const mg = try adapter.openGraphWithUuid("fts_graph", graph_uuid);

        // Lazy engine: open the persisted default index (replays WAL/segments)
        // into the adapter registry, then fetch its facade.
        try mg.fts_adapter.?.openIndex("default");
        const fts = mg.getFulltextIndexNamed(allocator, "default") orelse return error.TestUnexpectedNull;

        // The previously indexed document should be searchable after reload.
        const hits = try fts.search("fox", 10);
        defer allocator.free(hits);
        try std.testing.expect(hits.len >= 1);
        try std.testing.expectEqual(@as(u64, 42), hits[0].doc_id);
    }
}

test "StorageAdapter: reopen repairs corrupted free.store" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const graph_name = "repair_graph";
    var graph_uuid: [16]u8 = undefined;
    var node_id: u64 = 0;

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        node_id = try adapter.createNode(graph_name, &[_][]const u8{"Person"});
        try adapter.setNodeProperty(graph_name, node_id, "name", .{ .String = "Alice" });
        graph_uuid = adapter.getGraphUuid(graph_name) orelse return error.GraphNotFound;
        try adapter.checkpointAll();
    }

    const graph_dir = try StorageAdapter.graphDirPath(allocator, path, graph_uuid);
    defer allocator.free(graph_dir);

    const free_store_path = try std.fmt.allocPrint(allocator, "{s}/free.store", .{graph_dir});
    defer allocator.free(free_store_path);

    {
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io_fs, free_store_path, .{ .truncate = true });
        defer file.close(io_fs);
        try file.writeStreamingAll(io_fs, &([_]u8{0xFF} ** 64));
    }

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        _ = try adapter.openGraphWithUuid(graph_name, graph_uuid);

        const name_prop = try adapter.getNodeProperty(graph_name, node_id, "name", allocator) orelse return error.PropertyNotFound;
        defer freeOwnedStorageProperty(allocator, name_prop);

        try std.testing.expectEqualStrings("Alice", name_prop.string);
        try std.testing.expectEqual(@as(u64, 1), try adapter.nodeCount(graph_name));
        const repaired_stat = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), free_store_path, .{});
        try std.testing.expectEqual(@as(u64, 0), repaired_stat.size);
    }
}

test "StorageAdapter: dropGraph removes graph directory and subsystem data" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    const adapter = try StorageAdapter.init(allocator, path, testConfig());
    defer adapter.deinit();

    const mg = try adapter.getOrCreateGraph("__geode_security");
    const graph_uuid = mg.uuid;

    // Verify all subsystems are initialised. FTS is lazy now — the adapter is
    // eager but the legacy default `fts_index` facade is null until an index is
    // created; assert the eager adapter instead.
    try std.testing.expect(mg.audit_logger != null);
    try std.testing.expect(mg.ts_store != null);
    try std.testing.expect(mg.fts_adapter != null);
    try std.testing.expect(mg.fts_index == null);

    // Get the graph directory path before dropping.
    const graph_dir = try StorageAdapter.graphDirPath(allocator, path, graph_uuid);
    defer allocator.free(graph_dir);

    // Verify graph directory exists before drop.
    {
        var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), graph_dir, .{}) catch |err| {
            std.debug.print("graph dir should exist before drop: {}\n", .{err});
            return err;
        };
        dir.close(std.Io.Threaded.global_single_threaded.io());
    }

    // Drop the graph — this should deinit subsystems and delete the directory.
    adapter.dropGraph("__geode_security");

    // Verify graph directory is removed.
    const dir_result = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), graph_dir, .{});
    if (dir_result) |*d| {
        var dir_copy = d.*;
        dir_copy.close(std.Io.Threaded.global_single_threaded.io());
        return error.TestExpectedError; // directory should not exist
    } else |err| {
        try std.testing.expect(err == error.FileNotFound);
    }

    // Verify accessors return null after drop.
    try std.testing.expect(adapter.getAuditLogger("__geode_security") == null);
    try std.testing.expect(adapter.getTimeseriesStore("__geode_security") == null);
    try std.testing.expect(adapter.getFulltextIndex("__geode_security") == null);
    try std.testing.expect(!adapter.graphExists("__geode_security"));
}

test "StorageAdapter: getNodePropertyByHead parity with getNodeProperty" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    // Small page_size forces a multi-page property chain on node_b.
    const cfg = gs.GraphConfig{
        .page_size = 256,
        .buffer_pool_pages = 512,
    };
    const adapter = try StorageAdapter.init(allocator, path, cfg);
    defer adapter.deinit();

    const graph = "parity_test";
    const key = graph_store.INTERNAL_NODE_ID_PROPERTY_KEY;

    // (a) Normal node in shard 0.
    const node_a = try adapter.createNode(graph, &[_][]const u8{"Label"});
    try adapter.setNodeProperty(graph, node_a, key, .{ .String = "uuid-aaaa-0000" });

    // (b) Multi-page prop chain: set many props BEFORE the internal id so
    // the internal id lands past the head page. Nodes are round-robin allocated
    // so node_b lands in shard 1 (shardOfNode(1) == 1).
    const node_b = try adapter.createNode(graph, &[_][]const u8{"Label"});
    var pi: usize = 0;
    while (pi < 12) : (pi += 1) {
        const pk = try std.fmt.allocPrint(allocator, "extra_prop_{d:0>2}", .{pi});
        defer allocator.free(pk);
        try adapter.setNodeProperty(graph, node_b, pk, .{ .String = "val_0123456789abcdefghij" });
    }
    try adapter.setNodeProperty(graph, node_b, key, .{ .String = "uuid-bbbb-1111" });

    // (c) Node with no properties — prop_head stays 0 after creation.
    const node_c = try adapter.createNode(graph, &[_][]const u8{"Label"});
    _ = node_c;

    // (d) Another node with internal-id, in shard 3.
    const node_d = try adapter.createNode(graph, &[_][]const u8{"Label"});
    try adapter.setNodeProperty(graph, node_d, key, .{ .String = "uuid-dddd-3333" });

    // Verify distribution across ≥2 shards.
    try std.testing.expect(gs.shard_count.shardOfNode(node_a) != gs.shard_count.shardOfNode(node_b));

    // Scan all nodes to get ScanEntry records (carries rec.prop_head).
    const entries = try adapter.scanAllNodes(graph, allocator);
    defer allocator.free(entries);
    try std.testing.expect(entries.len >= 4);

    for (entries) |entry| {
        const by_slot = try adapter.getNodeProperty(graph, entry.slot_id, key, allocator);
        defer if (by_slot) |v| freeOwnedStorageProperty(allocator, v);

        const by_head = try adapter.getNodePropertyByHead(graph, entry.slot_id, entry.rec.prop_head, key, allocator);
        defer if (by_head) |v| freeOwnedStorageProperty(allocator, v);

        if (by_slot == null) {
            try std.testing.expectEqual(@as(?gs.PropertyValue, null), by_head);
        } else {
            try std.testing.expect(by_head != null);
            switch (by_slot.?) {
                .string => |s| try std.testing.expectEqualStrings(s, by_head.?.string),
                .int => |i| try std.testing.expectEqual(i, by_head.?.int),
                .float => |f| try std.testing.expectEqual(f, by_head.?.float),
                .bool => |b| try std.testing.expectEqual(b, by_head.?.bool),
                .null => try std.testing.expectEqual(gs.PropertyValue.null, by_head.?),
                else => try std.testing.expect(false),
            }
        }
    }
}

test "GAP-0900 throughput: addEx(assume_new) builds a complete low-selectivity posting (O(n^2) scan fix)" {
    const allocator = std.testing.allocator;

    // Low-selectivity scenario: many fresh node_ids share ONE (label,key,value),
    // so the posting list grows to N. The old `add` linear-scanned that list on
    // every insert (O(N) per op → O(N^2) total, 54.85% of CPU at ~4M nodes). The
    // bulk-insert path now calls addEx(assume_new=true) to skip the scan because a
    // freshly-reserved node_id provably can't already be present. This test locks
    // that the skip still yields a COMPLETE, correct posting (no missing ids).
    var idx = NodePropertyExactIndex.init(allocator);
    defer idx.deinit();

    const N: u64 = 20_000;
    const H: u64 = 0xA5A5_1234; // identical value_hash for all → single big posting
    var i: u64 = 1;
    while (i <= N) : (i += 1) {
        try idx.addEx(1, "source", H, i, true); // fresh insert: skip de-dup scan
    }

    const posting = idx.get(1, "source", H) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, N), posting.len);
    // Gauss sum catches any missing or duplicated id cheaply.
    var sum: u128 = 0;
    for (posting) |id| sum += id;
    try std.testing.expectEqual(@as(u128, N) * (N + 1) / 2, sum);

    // The update path (assume_new=false) must still de-dup a repeated node_id.
    var idx2 = NodePropertyExactIndex.init(allocator);
    defer idx2.deinit();
    try idx2.addEx(2, "k", H, 7, false);
    try idx2.addEx(2, "k", H, 7, false); // duplicate → scan removes the redundancy
    const p2 = idx2.get(2, "k", H) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), p2.len);
}
