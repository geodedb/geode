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
const value_order = @import("../execution/value_order.zig");
// SONNY-2806 (round 8): value equality without importing the executor.
const value_equality = @import("../execution/value_equality.zig");
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
// GAP-0064 FIX A: number of reopens that ROUTED the deferred exact-index build
// through the RACE-FREE background rebuild thread (`spawnExactIndexRebuildOnReopen`
// succeeded), for BOTH an `.absent` and a `.stale` on-disk index. Test
// instrumentation: after an `.absent` reopen this must be >= 1 (the un-fold —
// the first-touch hydration no longer runs the O(graph) build inline on the
// read path). Bumped only on a successful spawn (thread reserved + started).
var g_exact_reopen_spawns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-0064 FIX C: number of geode-driven value-ORDERED index builds
// (`createOrderedIndex` via the auto-build path) run this process. A snapshot
// RELOAD on reopen (gs GAP-0050) does NOT bump this — a nonzero count means the
// ordered tree was (re)built from a live scan, not reloaded. Test instrumentation.
var g_ordered_index_builds: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-0064 FIX C: number of BACKGROUND ordered-index build workers that ran to
// completion (register+rebuild THEN best-effort persist). Lets a test wait
// deterministically for the async auto-build (build + checkpoint) to finish
// before asserting the fast path is served.
var g_ordered_build_completions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// GAP-0064 FIX A (TEST-ONLY): a gate the background reopen rebuild worker waits
// on BEFORE it touches any lock or the exact index, so a test can hold the
// build "in flight" and prove that first-touch reads (count / label scan) return
// promptly (the fold no-op) instead of parking behind the build. 0 = open (the
// production value — never blocks), non-zero = closed. Only ever consulted from
// the worker path under `comptime is_test`, so production carries zero overhead.
var g_test_exact_build_gate: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
// GAP-0064 (adversarial review — TEST-ONLY): number of rebuild threads currently
// parked at `g_test_exact_build_gate` while HOLDING `exact_index_build_mutex`. A
// test polls this to know a build (worker or lazy) is mid-flight (mutex held)
// before it runs the concurrent FULL checkpoint that must skip its eager build.
var g_test_build_gate_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
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

/// GAP-ENT-0048 Path B (Task 5.3b) kill switch: when a reopen finds the
/// persisted `prop_exact.idx` stale (epoch mismatch or a WAL tail past its
/// covered_lsn — `loadFromFile` returned false), the deferred index is rebuilt
/// PROACTIVELY on a background thread via the RACE-FREE hydration-scan build
/// (`buildAndPersistExactIndexForHydratedGraph`), instead of leaving the whole
/// O(graph) rebuild for the first client query to pay INLINE on its handler
/// thread (the "85s lazy-on-first-query path" that, at 14.27M nodes, overran the
/// proto-reader stall window and wedged the handler). Server-ready stays
/// sub-second (open only spawns the thread); reads that need the index wait for
/// the background build (which they would anyway, the snapshot being unusable),
/// while other reads are unaffected. Set to disable (revert to pure lazy
/// first-access) for the sub-second-cold-open A/B, where no proactive build is
/// wanted.
fn eagerExactRebuildOnReopenDisabled() bool {
    // GAP-0064 FIX A: a programmatic test override (mirrors setLeanIndexingForTest)
    // so a test can deterministically exercise the eager-CHECKPOINT-build FALLBACK
    // (reopen background rebuild suppressed) WITHOUT relying on process-global env
    // ordering. `null` = consult the env (production behavior).
    if (comptime @import("builtin").is_test) {
        if (g_test_disable_eager_reopen_rebuild) |v| return v;
    }
    const raw_z = std.c.getenv("GEODE_DISABLE_EAGER_EXACT_REBUILD_ON_REOPEN") orelse return false;
    const raw = std.mem.span(raw_z);
    return std.mem.eql(u8, raw, "1") or std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "yes");
}

/// GAP-0064 FIX A (TEST-ONLY): override `eagerExactRebuildOnReopenDisabled`.
/// `true` suppresses the reopen background rebuild (so the eager-CHECKPOINT-build
/// fallback is exercised); `null` restores env-driven production behavior.
var g_test_disable_eager_reopen_rebuild: ?bool = null;
pub fn setEagerExactRebuildOnReopenDisabledForTest(disabled: ?bool) void {
    g_test_disable_eager_reopen_rebuild = disabled;
}

/// SONNY-1574 (fix pass 1574b) TEST-ONLY: force `graphDirPath` to fail the
/// next time(s) it is called, so the "graph dir path unavailable" branch of
/// `checkpointOneGraph`'s exact-index decision — in production reachable
/// only via an allocator OOM — can be driven deterministically. A
/// `std.testing.FailingAllocator` cannot aim at that one call: its
/// fail-index counts every allocation on every thread sharing the
/// allocator, including the persist worker's OWN background thread, so it
/// cannot be pointed at this call without also perturbing setup. `false`
/// (default) = normal behavior. Compiled out under `is_test == false`.
var g_test_force_graph_dir_path_failure: bool = false;
pub fn setForceGraphDirPathFailureForTesting(force: bool) void {
    g_test_force_graph_dir_path_failure = force;
}

/// GAP-0064 FIX C: the ORDER-BY auto-build (`spawnOrderedIndexBuildAsync`) is
/// ALWAYS ON in production. Under `is_test` it defaults to SUPPRESSED so the
/// existing test corpus — which runs many `ORDER BY <non-indexed> LIMIT` queries
/// and asserts the heap fallback on later identical queries — is unperturbed;
/// the dedicated auto-build suite opts IN with `setOrderedAutobuildDisabledForTest(false)`.
/// `null` restores the per-context default (production ON, tests suppressed).
var g_test_ordered_autobuild_disabled: ?bool = null;
pub fn setOrderedAutobuildDisabledForTest(disabled: ?bool) void {
    g_test_ordered_autobuild_disabled = disabled;
}
fn orderedAutobuildDisabled() bool {
    if (comptime @import("builtin").is_test) {
        if (g_test_ordered_autobuild_disabled) |d| return d;
        return true; // tests default to suppressed (production is always ON)
    }
    return false;
}
var g_exact_persist_completions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_exact_persist_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// SONNY-1574: the ONLY counter that means "an exact-index snapshot actually
// reached disk". `completions` used to be bumped by the persist worker purely
// because `checkpointGraph` RETURNED OK — including when the checkpoint's
// persist decision SKIPPED the write (tryLock lost to the build mutex) or when
// `saveToFile` failed (warn-only). That success surface lied: the test's
// attempts/completions/failures gate passed while nothing was durable, and the
// crash-reopen re-paid the O(graph) rebuild. `writes` is incremented at the one
// site that observes a successful `saveToFile`; `skips` counts a persist
// decision that deliberately wrote nothing; a `saveToFile` error now lands in
// `failures` instead of a bare log line.
var g_exact_persist_writes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_exact_persist_skips: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// SONNY-1574: persist-on-build workers that have RUN TO COMPLETION (every exit
// path, after their counters are final). A test that asserts on the outcome
// counters must wait on THIS, not on a counter the worker's own checkpoint
// bumps mid-flight — `writes` lands inside `checkpointGraphEx`, `completions`
// only after it returns.
var g_exact_persist_worker_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
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
// GAP-ENT-0048 crash-reconcile (Phase E2): number of reopens that RECONCILED a
// committed WAL tail into the prop_exact.idx snapshot in O(tail) — evicting each
// tail node's OLD postings via the persisted reverse map and re-deriving its
// CURRENT postings from the engine — INSTEAD of a full O(graph) rebuild. The
// release gate asserts this is 1 (and `g_exact_rebuild_runs` stays 0) on the
// gated crash-tail path, and 0 (rebuild fires) on the ungated multi-crash /
// reverse-map-absent path.
var g_exact_index_reconciled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
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

/// GAP-ENT-0048 crash-reconcile (Phase E1): sibling of `prop_exact.idx` holding
/// the node→[(label,key,value_hash)] reverse map used to evict a tail-changed
/// node's OLD postings on a crash-reopen reconcile. Magic-bumped + stamped with
/// the SAME (checkpoint_epoch, covered_lsn) as `prop_exact.idx`.
const prop_rev_index_file_name = "prop_rev.idx";
// GENRVIX2 (SONNY-2806): numbers hash by value; a GENRVIX1 file is stale.
const prop_rev_index_magic = "GENRVIX2";

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

/// GAP-0064 FIX A: reopens whose deferred exact-index build was routed through
/// the race-free background rebuild thread (the un-fold). >= 1 after an `.absent`
/// or `.stale` reopen; 0 before FIX A for the `.absent` case.
pub fn getExactReopenSpawnsForTesting() u64 {
    return g_exact_reopen_spawns.load(.acquire);
}
pub fn resetExactReopenSpawnsForTesting() void {
    g_exact_reopen_spawns.store(0, .release);
}

/// GAP-0064 FIX C: geode-driven value-ordered index builds (auto-build path).
/// 0 after a reopen that RELOADED the persisted ordered snapshot (no rebuild).
pub fn getOrderedIndexBuildsForTesting() u64 {
    return g_ordered_index_builds.load(.acquire);
}
pub fn resetOrderedIndexBuildsForTesting() void {
    g_ordered_index_builds.store(0, .release);
}
/// GAP-0064 FIX C: background ordered-index build+persist workers completed.
pub fn getOrderedBuildCompletionsForTesting() u64 {
    return g_ordered_build_completions.load(.acquire);
}
pub fn resetOrderedBuildCompletionsForTesting() void {
    g_ordered_build_completions.store(0, .release);
}

/// GAP-0064 FIX A (TEST-ONLY): hold the background reopen rebuild "in flight" so
/// a test can prove first-touch reads return without waiting on the build. Only
/// honored in test builds (the worker's wait is `comptime is_test`-guarded).
pub fn closeExactBuildGateForTesting() void {
    g_test_exact_build_gate.store(1, .release);
}
pub fn openExactBuildGateForTesting() void {
    g_test_exact_build_gate.store(0, .release);
}
/// GAP-0064 (review — TEST-ONLY): rebuild threads currently parked at the gate
/// while holding `exact_index_build_mutex`. A test polls `>= 1` to know a build
/// is mid-flight before running the concurrent checkpoint.
pub fn getBuildGateWaitersForTesting() u32 {
    return g_test_build_gate_waiters.load(.acquire);
}
pub fn resetBuildGateWaitersForTesting() void {
    g_test_build_gate_waiters.store(0, .release);
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

/// GAP-ENT-0048 Path B: aggregate (wrapping sum over all shards) of the
/// per-shard `manifest.checkpoint_epoch` — the durable derived-index generation
/// token gs v0.2.29 advances ONLY at `doCheckpoint`, NEVER by a WAL-tail
/// recovery (checkpoint.zig bumps it beside `counter`; recovery.zig leaves it
/// untouched). This is why it replaces `manifest.counter` as the
/// `prop_exact.idx` stamp: the counter is ALSO bumped by recovery, so a
/// deferred-WAL-tail reopen bumped it and needlessly rebuilt a valid index (the
/// GAP-ENT-0048 root cause). The epoch stays fixed across a tail replay, so an
/// epoch match means "no checkpoint has run since the snapshot" — the snapshot
/// is valid AS OF its covered_lsn (see `mgDurableFrontierLsn` for the tail
/// gate). A wrapping sum is a combined fingerprint: if ANY shard checkpoints,
/// the sum changes and the snapshot is treated as generation-mismatched.
fn mgCheckpointEpoch(mg: *ManagedGraph) u64 {
    var epoch: u64 = 0;
    for (mg.engine.shards) |shard| {
        epoch +%= shard.manifest.checkpoint_epoch;
    }
    return epoch;
}

/// GAP-ENT-0048 Path B: aggregate (wrapping sum over all shards) of the
/// per-shard `manifest.last_checkpoint_lsn` — the DURABLE COMMITTED FRONTIER.
/// It is set to the checkpoint LSN by `doCheckpoint`, and ADVANCED by a WAL-tail
/// recovery (recovery.zig sets it to `wal.currentLsn()` after replaying a
/// committed tail) — but LEFT UNCHANGED by a clean reopen that replays nothing
/// (recovery.zig returns before touching it when no WAL records are seen). So at
/// `prop_exact.idx` SAVE time (right after a FULL `engine.checkpoint()`) this is
/// exactly the LSN the persisted index covers; at reopen it is the same value
/// (clean, no tail → RELOAD) or larger (a committed tail was replayed → the
/// loaded index would be stale → REBUILD). The reload gate is therefore:
/// `stamped_epoch == mgCheckpointEpoch(mg) AND stamped_covered == this`.
/// "covered == frontier" ⟺ "no WAL tail beyond the snapshot" — mirrors gs's own
/// derived-index tail gate (engine_index.tryLoadDerivedIndexes), which compares
/// each snapshot's covered_lsn against `manifest.last_checkpoint_lsn`.
fn mgDurableFrontierLsn(mg: *ManagedGraph) u64 {
    var frontier: u64 = 0;
    for (mg.engine.shards) |shard| {
        frontier +%= shard.manifest.last_checkpoint_lsn;
    }
    return frontier;
}

/// GAP-ENT-0048 crash-reconcile (Phase E2): aggregate (wrapping sum over all
/// shards) of the per-shard `preRecoveryFrontierLsn()` (gs G2 getter =
/// `tail_pre_recovery_lsn`) — the durable committed frontier as it stood BEFORE
/// this session's recovery replayed. A SOUND single-recovery reconcile requires
/// the on-disk snapshot's covered_lsn == this: exactly one recovery has advanced
/// the frontier since the snapshot, so the WAL tail captured by Path B is
/// complete and attributable. If covered_lsn < this (a PRIOR un-checkpointed
/// recovery advanced the frontier past the snapshot — the multi-crash case), the
/// reconcile MUST fall back to a full rebuild.
///
/// SUM SOUNDNESS: each shard's durable frontier is MONOTONIC (checkpoints and
/// tail replays only advance `last_checkpoint_lsn`), so per shard
/// `preRecoveryFrontierLsn() >= snapshot covered_lsn`. Therefore
/// `sum(preRecovery) == sum(snapshot covered)` ⟺ per-shard equality for EVERY
/// shard — the summed gate is as strong as a per-shard gate (the same wrapping
/// -sum fingerprint discipline `mgCheckpointEpoch`/`mgDurableFrontierLsn` use).
fn mgPreRecoveryFrontierLsn(mg: *ManagedGraph) u64 {
    var frontier: u64 = 0;
    for (mg.engine.shards) |shard| {
        frontier +%= shard.preRecoveryFrontierLsn();
    }
    return frontier;
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

/// SONNY-1574: exact-index snapshots that ACTUALLY reached disk (a successful
/// `NodePropertyExactIndex.saveToFile` inside a FULL checkpoint's persist
/// decision). This — never `completions` — is what a durability test must wait
/// on: `completions` only means the persist worker's checkpoint returned, and a
/// checkpoint can legitimately return OK having persisted nothing.
pub fn getExactIndexPersistWritesForTesting() u64 {
    return g_exact_persist_writes.load(.acquire);
}

/// SONNY-1574: FULL-checkpoint persist decisions that deliberately wrote
/// NOTHING — the build-mutex `tryLock` skip (another build owns the index and
/// persists on completion) or an empty deferred graph (nothing to snapshot).
/// Counted separately from failures: a skip is a correct outcome, it just must
/// never be reported as a completed persist.
pub fn getExactIndexPersistSkipsForTesting() u64 {
    return g_exact_persist_skips.load(.acquire);
}

/// SONNY-1574: persist-on-build background workers that have finished (all
/// their counters final). The synchronisation point for tests.
pub fn getExactIndexPersistWorkerRunsForTesting() u64 {
    return g_exact_persist_worker_runs.load(.acquire);
}

/// H4 persist-on-build: reset the persist counters (test-only).
pub fn resetExactIndexPersistCountersForTesting() void {
    g_exact_persist_attempts.store(0, .release);
    g_exact_persist_completions.store(0, .release);
    g_exact_persist_failures.store(0, .release);
    g_exact_persist_writes.store(0, .release);
    g_exact_persist_skips.store(0, .release);
    g_exact_persist_worker_runs.store(0, .release);
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

/// GAP-ENT-0048 crash-reconcile (Phase E2): reopens that RECONCILED a committed
/// WAL tail into prop_exact.idx (O(tail)) instead of a full rebuild. The release
/// gate asserts reconciled==1 / rebuilds==0 on the gated crash-tail path.
pub fn getExactIndexReconciledForTesting() u64 {
    return g_exact_index_reconciled.load(.acquire);
}

pub fn resetExactIndexReconcileCountersForTesting() void {
    g_exact_index_reconciled.store(0, .release);
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
    /// with the gs `checkpoint_epoch` + the `covered_lsn` it reflects at persist
    /// time (GAP-ENT-0048 Path B). The stamp mirrors gs's own WAL-aware
    /// derived-index snapshot header (index_snapshot.zig: epoch + covered_lsn):
    /// on reopen the index loads ONLY if its stamped epoch equals the engine's
    /// current `checkpoint_epoch` (no checkpoint since persist) AND its
    /// covered_lsn equals the current durable frontier `last_checkpoint_lsn`
    /// (no committed WAL tail beyond it). Unlike the old `manifest.counter`
    /// stamp, the epoch is NOT bumped by recovery, so a deferred-WAL-tail reopen
    /// no longer needlessly invalidates a valid snapshot on the epoch axis — the
    /// tail is detected precisely on the covered_lsn axis instead (and a present
    /// tail routes to a SAFE rebuild; a correct O(tail) reconcile of this
    /// value→node index is not achievable with the v0.2.29 API — see the Phase 5
    /// report). Non-fatal: callers should catch and log warnings.
    fn saveToFile(self: *NodePropertyExactIndex, graph_dir_path: []const u8, checkpoint_epoch: u64, covered_lsn: u64, config_hash: u64) !void {
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

        // 8-byte magic header (v3 = checkpoint-epoch + covered-lsn stamped, the
        // WAL-aware Path B contract; v4 = SONNY-2806, a number's value hash is
        // its exact value; v5 = SONNY-6354, stamped with the indexed-key
        // configuration). GENPIDX4, GENPIDX3 (bytes-hashed numbers), GENPIDX2
        // (counter-stamped) and GENPIDX1 (unstamped) are treated as stale on
        // load → rebuild (never mis-served).
        try writer.writeAll(exact_index_magic);
        // WAL-aware staleness stamp: the gs checkpoint_epoch (derived-index
        // generation) and the durable-frontier LSN this index covers.
        try writer.writeInt(u64, checkpoint_epoch, .little);
        try writer.writeInt(u64, covered_lsn, .little);
        // SONNY-6354: which keys the index holds (`graph_store.exactIndexConfigHash`).
        try writer.writeInt(u64, config_hash, .little);

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

        // GAP-ENT-0048 crash-reconcile (Phase E1): persist the node→postings
        // REVERSE MAP alongside prop_exact.idx, stamped with the SAME (epoch,
        // covered_lsn). It lets a crash-reopen with a committed WAL tail EVICT a
        // tail-changed node's OLD postings in O(node's postings) WITHOUT
        // re-reading its (tail-overwritten) old value — the exact prerequisite
        // the Phase 5 report flagged as missing. Written in the SAME locked pass
        // (all shard mutexes held) so it is an exact inversion of the postings
        // just written. Independent stamp/magic → an inconsistent or torn
        // reverse file is rejected on load (→ safe full rebuild), never mis-used.
        try self.writeReverseMapLocked(graph_dir_path, checkpoint_epoch, covered_lsn);
    }

    /// Phase E1: write `prop_rev.idx` — the node→[(label,key,value_hash)] reverse
    /// map — by STREAMING the inversion of the forward postings (no transient
    /// in-memory map at save time). Caller must already hold every shard mutex
    /// (invoked from `saveToFile`). Format:
    ///   magic "GENRVIX2" | epoch u64 | covered_lsn u64 | pair_count u64
    ///   then pair_count × { node_id u64, key_len u32, encoded_key bytes }
    /// where `encoded_key` is the forward posting key
    /// `[label_id u32][key_len u32][key][value_hash u64]`. The value is
    /// represented by its 64-bit hash only, so the file size is bounded by the
    /// number of (node,label,key) postings and the KEY length — independent of
    /// the property VALUE length (the E1 "bounded size" contract).
    fn writeReverseMapLocked(self: *NodePropertyExactIndex, graph_dir_path: []const u8, checkpoint_epoch: u64, covered_lsn: u64) !void {
        const rev_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ graph_dir_path, prop_rev_index_file_name });
        defer self.allocator.free(rev_path);

        const rev_io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(rev_io, rev_path, .{ .truncate = true });
        defer file.close(rev_io);

        var rev_wbuf: [8192]u8 = undefined;
        var rev_fw = file.writerStreaming(rev_io, &rev_wbuf);
        const writer = &rev_fw.interface;

        try writer.writeAll(prop_rev_index_magic);
        try writer.writeInt(u64, checkpoint_epoch, .little);
        try writer.writeInt(u64, covered_lsn, .little);

        // pair_count = total (node, encoded_key) postings == sum of posting
        // lengths across every shard.
        var pair_count: u64 = 0;
        for (&self.shards) |*shard| {
            var it = shard.postings.iterator();
            while (it.next()) |entry| pair_count += entry.value_ptr.items.len;
        }
        try writer.writeInt(u64, pair_count, .little);

        for (&self.shards) |*shard| {
            var it = shard.postings.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                for (entry.value_ptr.items) |nid| {
                    try writer.writeInt(u64, nid, .little);
                    try writer.writeInt(u32, @intCast(key.len), .little);
                    try writer.writeAll(key);
                }
            }
        }
        try rev_fw.flush();
    }

    /// Phase E2: remove `node_id` from the posting for `encoded_key` (the exact
    /// forward posting key `[label_id][key_len][key][value_hash]`, as stored in
    /// the reverse map). Drops the posting entirely when it becomes empty (so a
    /// count/GROUP-BY walk never sees a zero-length bucket). Used by the
    /// crash-reopen reconcile to EVICT a tail node's OLD postings via the reverse
    /// map, WITHOUT decoding the value. No-op if the key/node is absent.
    fn removeByEncodedKey(self: *NodePropertyExactIndex, encoded_key: []const u8, node_id: u64) void {
        const shard_idx = exactNodePropertyIndexShardForEncodedKey(encoded_key);
        const shard = &self.shards[shard_idx];
        const io = std.Io.Threaded.global_single_threaded.io();
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);

        if (shard.postings.getPtr(encoded_key)) |list| {
            var i: usize = 0;
            while (i < list.items.len) : (i += 1) {
                if (list.items[i] == node_id) {
                    _ = list.orderedRemove(i);
                    break;
                }
            }
            if (list.items.len == 0) {
                if (shard.postings.fetchRemove(encoded_key)) |kv| {
                    self.allocator.free(kv.key);
                    var list_copy = kv.value;
                    list_copy.deinit(self.allocator);
                }
            }
        }
    }

    /// Load the index from `prop_exact.idx` inside `graph_dir_path`, but ONLY if
    /// it is CURRENT on the WAL-aware Path B contract (GAP-ENT-0048): its stamped
    /// `checkpoint_epoch` equals `expected_epoch` (the engine's current epoch — no
    /// checkpoint since persist) AND its stamped `covered_lsn` equals
    /// `expected_covered_lsn`. The clean-reopen caller passes the current durable
    /// frontier (`last_checkpoint_lsn` sum) so a match means "no committed WAL
    /// tail beyond the snapshot" (RELOAD); the crash-reconcile base-load caller
    /// (Phase E2) passes the snapshot's OWN stamped covered_lsn (== the
    /// pre-recovery frontier, gated by the caller) to LOAD the covered_lsn base
    /// even though a tail exists, so it can then reconcile the bounded tail.
    /// Returns:
    ///   `.loaded` — the snapshot was current and is now resident.
    ///   `.stale`  — a snapshot FILE was present but rejected: legacy format
    ///               (GENPIDX1/GENPIDX2), epoch-mismatched (a checkpoint ran since
    ///               persist), TAIL-PRESENT (covered < frontier — a recovery
    ///               replayed committed records the snapshot predates), or a torn
    ///               read. The caller REBUILDS; because a valid base existed, the
    ///               reopen proactively drives the race-free rebuild (Task 5.3b).
    ///   `.absent` — no snapshot file (or the path could not even be formed). The
    ///               caller defers to the ordinary lazy first-access rebuild — this
    ///               graph never persisted an index (legacy / LIGHT-only), so there
    ///               is nothing to "reload", and eagerly rebuilding at every open
    ///               would fight sub-second cold-open.
    /// Never blesses a stale copy: on ANY uncertainty it does NOT return `.loaded`
    /// (the "never serve a stale prop_exact.idx" invariant — a wrong exact index =
    /// silently wrong WHERE/GROUP BY/DISTINCT).
    ///
    /// SONNY-6354: and only if it holds the keys this process indexes
    /// (`expected_config`, `graph_store.exactIndexConfigHash`): a lean-mode
    /// index saved before a key was registered lacks that key's older
    /// holders, and one saved with lean mode on lacks every other key.
    fn loadFromFile(self: *NodePropertyExactIndex, graph_dir_path: []const u8, expected_epoch: u64, expected_covered_lsn: u64, expected_config: u64) ExactIndexLoadOutcome {
        self.lockAllShards();
        defer self.unlockAllShards();

        const idx_path = self.allocator.alloc(u8, graph_dir_path.len + "/prop_exact.idx".len) catch return .absent;
        defer self.allocator.free(idx_path);
        @memcpy(idx_path[0..graph_dir_path.len], graph_dir_path);
        @memcpy(idx_path[graph_dir_path.len..], "/prop_exact.idx");

        const gsa_io = std.Io.Threaded.global_single_threaded.io();
        // A file that cannot be opened is treated as ABSENT (the common
        // never-persisted / dropped case); every FAILURE PAST a successful open is
        // a present-but-unusable snapshot → `.stale` (drives the proactive rebuild).
        const file = std.Io.Dir.cwd().openFile(gsa_io, idx_path, .{}) catch return .absent;
        defer file.close(gsa_io);

        var reader_buffer: [4096]u8 = undefined;
        var file_reader = file.reader(gsa_io, &reader_buffer);
        const reader = &file_reader.interface;

        // Validate magic header — only the v5 (epoch + covered-lsn + key
        // configuration stamped, numbers hashed by value) format loads; a
        // GENPIDX4 (no key configuration), GENPIDX3 (numbers hashed by their
        // bytes), GENPIDX2 (counter-stamped) or GENPIDX1 (unstamped) file is a
        // present-but-stale snapshot -> rebuild.
        var magic: [8]u8 = undefined;
        reader.readSliceAll(&magic) catch return .stale;
        if (!std.mem.eql(u8, &magic, exact_index_magic)) return .stale;

        // WAL-aware staleness gate (Path B): reject unless BOTH the derived-index
        // generation matches (no checkpoint since persist) AND the covered LSN is
        // still the durable frontier (no committed WAL tail beyond the snapshot).
        const stored_epoch = reader.takeInt(u64, .little) catch return .stale;
        if (stored_epoch != expected_epoch) return .stale;
        const stored_covered_lsn = reader.takeInt(u64, .little) catch return .stale;
        if (stored_covered_lsn != expected_covered_lsn) return .stale;
        const stored_config = reader.takeInt(u64, .little) catch return .stale;
        if (stored_config != expected_config) return .stale;

        const entry_count = reader.takeInt(u64, .little) catch return .stale;

        // We already hold every shard mutex; using `clear()` would re-enter
        // the same non-reentrant `std.Io.Mutex` values and deadlock.
        // See docs/bugs/2026-04-27-adapter-restart-deadlock.md.
        self.clearLockedAll();

        var i: u64 = 0;
        while (i < entry_count) : (i += 1) {
            const key_len = reader.takeInt(u32, .little) catch return .stale;
            const key = self.allocator.alloc(u8, key_len) catch return .stale;
            reader.readSliceAll(key) catch {
                self.allocator.free(key);
                return .stale;
            };

            const posting_count = reader.takeInt(u64, .little) catch {
                self.allocator.free(key);
                return .stale;
            };
            var posting = std.ArrayList(u64).initCapacity(self.allocator, @intCast(posting_count)) catch {
                self.allocator.free(key);
                return .stale;
            };
            var j: u64 = 0;
            while (j < posting_count) : (j += 1) {
                const nid = reader.takeInt(u64, .little) catch {
                    posting.deinit(self.allocator);
                    self.allocator.free(key);
                    return .stale;
                };
                posting.appendAssumeCapacity(nid);
            }

            const shard_idx = exactNodePropertyIndexShardForEncodedKey(key);
            self.shards[shard_idx].postings.put(key, posting) catch {
                posting.deinit(self.allocator);
                self.allocator.free(key);
                return .stale;
            };
        }

        return .loaded;
    }
};

/// GAP-ENT-0048 Path B: outcome of a `prop_exact.idx` reopen load attempt. The
/// caller distinguishes a rejected-but-present snapshot (`.stale` → proactively
/// drive the race-free rebuild, Task 5.3b) from a never-persisted one
/// (`.absent` → defer to lazy first-access, preserving sub-second cold-open).
const ExactIndexLoadOutcome = enum { loaded, stale, absent };

/// `prop_exact.idx` format edition (see `NodePropertyExactIndex.saveToFile`).
const exact_index_magic = "GENPIDX5";

/// Phase E2: the `(checkpoint_epoch, covered_lsn)` stamp of an on-disk
/// `prop_exact.idx`, read from its header alone (no postings). `null` when the
/// file is absent, torn, or not the current (WAL-aware) format. Used by the
/// crash-reopen reconcile gate to compare the snapshot's covered_lsn against the
/// pre-recovery frontier BEFORE deciding to reconcile vs full-rebuild.
const ExactIndexStamp = struct { epoch: u64, covered_lsn: u64 };

fn readExactIndexStamp(allocator: Allocator, graph_dir_path: []const u8) ?ExactIndexStamp {
    const idx_path = std.fmt.allocPrint(allocator, "{s}/prop_exact.idx", .{graph_dir_path}) catch return null;
    defer allocator.free(idx_path);

    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.Dir.cwd().openFile(io, idx_path, .{}) catch return null;
    defer file.close(io);

    var rbuf: [64]u8 = undefined;
    var fr = file.reader(io, &rbuf);
    const reader = &fr.interface;

    var magic: [8]u8 = undefined;
    reader.readSliceAll(&magic) catch return null;
    if (!std.mem.eql(u8, &magic, exact_index_magic)) return null;
    const epoch = reader.takeInt(u64, .little) catch return null;
    const covered = reader.takeInt(u64, .little) catch return null;
    return .{ .epoch = epoch, .covered_lsn = covered };
}

/// Phase E1/E2: the node→[(label,key,value_hash)] REVERSE MAP, materialized ONLY
/// transiently at crash-reopen reconcile time (loaded from `prop_rev.idx`, used
/// to evict a tail node's OLD postings, then freed). It is NOT resident during
/// normal operation — steady-state memory is unchanged. Each node maps to a list
/// of OWNED encoded posting keys `[label_id][key_len][key][value_hash]` (the
/// same bytes used as the forward posting map key), so eviction is a direct
/// `NodePropertyExactIndex.removeByEncodedKey` per key with no value decode.
const NodePropertyReverseMap = struct {
    allocator: Allocator,
    map: std.AutoHashMapUnmanaged(u64, std.ArrayListUnmanaged([]u8)) = .{},

    fn init(allocator: Allocator) NodePropertyReverseMap {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *NodePropertyReverseMap) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |key| self.allocator.free(key);
            entry.value_ptr.deinit(self.allocator);
        }
        self.map.deinit(self.allocator);
    }

    /// Append an OWNED copy of `encoded_key` to `node_id`'s key list.
    fn addKey(self: *NodePropertyReverseMap, node_id: u64, encoded_key: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, encoded_key);
        errdefer self.allocator.free(key_copy);
        const gop = try self.map.getOrPut(self.allocator, node_id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.allocator, key_copy);
    }

    /// The encoded keys currently mapped for `node_id` (borrowed; valid until the
    /// next mutation / deinit). `null` when the node has no reverse entry (e.g. a
    /// node inserted in the tail that was absent from the covered_lsn snapshot).
    fn keysFor(self: *NodePropertyReverseMap, node_id: u64) ?[]const []u8 {
        if (self.map.getPtr(node_id)) |list| return list.items;
        return null;
    }

    /// Phase E1: load `prop_rev.idx` from `graph_dir_path`, but ONLY if it is
    /// stamped with `expected_epoch` AND `expected_covered_lsn` (the same gate as
    /// the forward base-load, so a torn / inconsistent / foreign reverse file is
    /// rejected → the caller falls back to a full rebuild, never an unsound
    /// reconcile). Mirrors `NodePropertyExactIndex.loadFromFile`'s outcomes.
    fn loadFromFile(self: *NodePropertyReverseMap, graph_dir_path: []const u8, expected_epoch: u64, expected_covered_lsn: u64) ExactIndexLoadOutcome {
        const rev_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ graph_dir_path, prop_rev_index_file_name }) catch return .absent;
        defer self.allocator.free(rev_path);

        const io = std.Io.Threaded.global_single_threaded.io();
        const file = std.Io.Dir.cwd().openFile(io, rev_path, .{}) catch return .absent;
        defer file.close(io);

        var rbuf: [4096]u8 = undefined;
        var fr = file.reader(io, &rbuf);
        const reader = &fr.interface;

        var magic: [8]u8 = undefined;
        reader.readSliceAll(&magic) catch return .stale;
        if (!std.mem.eql(u8, &magic, prop_rev_index_magic)) return .stale;
        const stored_epoch = reader.takeInt(u64, .little) catch return .stale;
        if (stored_epoch != expected_epoch) return .stale;
        const stored_covered = reader.takeInt(u64, .little) catch return .stale;
        if (stored_covered != expected_covered_lsn) return .stale;

        const pair_count = reader.takeInt(u64, .little) catch return .stale;
        var i: u64 = 0;
        while (i < pair_count) : (i += 1) {
            const node_id = reader.takeInt(u64, .little) catch return .stale;
            const key_len = reader.takeInt(u32, .little) catch return .stale;
            const key = self.allocator.alloc(u8, key_len) catch return .stale;
            reader.readSliceAll(key) catch {
                self.allocator.free(key);
                return .stale;
            };
            const gop = self.map.getOrPut(self.allocator, node_id) catch {
                self.allocator.free(key);
                return .stale;
            };
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            gop.value_ptr.append(self.allocator, key) catch {
                self.allocator.free(key);
                return .stale;
            };
        }
        return .loaded;
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

/// ENG-3911: property-entry write errors, on their way to the client.
///
/// HISTORY: the storage layer used to raise `error.PropertyKeyTooLong` for TWO
/// structurally different refusals, and this function re-mapped the
/// mis-attributed one (short key, oversized VALUE) to a truthful
/// `error.PropertyValueTooLarge`.
///
/// Since graph-storage v0.4.0 the dependency makes that split itself
/// (`src/prop_store.zig`): a value too large for the inline per-entry budget
/// spills to a VarStore overflow chain, `error.PropertyValueTooLarge` names a
/// value above `GraphConfig.max_property_value_bytes` (default 1 MiB), and
/// `error.PropertyKeyTooLong` is reserved for a genuinely oversized KEY. So
/// there is nothing left to re-attribute — this is a pass-through.
///
/// It is kept (rather than deleted at its ~9 call sites) as the single named
/// seam where a property-entry error is normalized for the wire:
/// `server/proto_util.mapError` surfaces both as SQLSTATE 54000
/// (program_limit_exceeded), each with its own truthful message.
///
/// CANARY: REQ=REQ-ENG-3911-PROPERTY-VALUE-SIZE-ERROR; FEATURE="PropertyStorage"; ASPECT=OversizedValueErrorMapping; STATUS=TESTED; TEST=tests/test_eng3911_property_value_size_error.zig; OWNER=transport; UPDATED=2026-08-25
pub fn mapPropertyEntryError(err: anyerror, key: []const u8) anyerror {
    _ = key;
    return err;
}

/// Largest property KEY the storage layer accepts: `prop_store.putPropertyImpl`
/// refuses `key.len > maxInt(u16)` outright (`error.PropertyKeyTooLong`).
pub const MAX_PROPERTY_KEY_BYTES: usize = std.math.maxInt(u16);

/// Statement-atomicity pre-pass predicate: would the storage layer accept this
/// (key, value) entry?
///
/// A write statement has NO rollback under autocommit — the per-statement engine
/// txn is an fsync-batching device pinned to one shard, and the in-memory
/// `GraphStore` mirror is mutated unconditionally — so a property refused
/// half-way through a CREATE / MERGE / SET leaves the half that already landed.
/// The remedy is to refuse the whole statement BEFORE its first store mutation,
/// which requires knowing the storage layer's acceptance rule up front. This is
/// that rule, mirrored from `graph-storage/src/prop_store.zig:putPropertyImpl`:
///
///   * a key above `maxInt(u16)` is refused as `error.PropertyKeyTooLong`;
///   * an encoded value above `GraphConfig.max_property_value_bytes` (the
///     caller passes the graph's live cap — never a hardcoded constant) is
///     refused as `error.PropertyValueTooLarge`.
///
/// It is deliberately CONSERVATIVE: it must never refuse an entry the storage
/// layer would have accepted. Since graph-storage v0.4.0 an entry too large for
/// an inline property page SPILLS to a VarStore overflow chain instead of being
/// refused, so the per-page budget is no longer a ceiling and is not checked
/// here. The one residual it does not model is the dependency's secondary
/// key check (`2 + key.len + OVERFLOW_STUB_SIZE > entry_budget`, i.e. a key of
/// roughly page_size bytes), whose inputs are private to the dependency; such a
/// key still fails at the store, mid-statement.
///
/// CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=EntryFitsPredicate; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
pub fn checkPropertyEntryFits(key: []const u8, value: gs.PropertyValue, max_value_bytes: u32) !void {
    if (key.len > MAX_PROPERTY_KEY_BYTES) return error.PropertyKeyTooLong;
    if (gs.property.encodedSize(value) > max_value_bytes) return error.PropertyValueTooLarge;
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

/// Free a property map `getAllNodeProperties` / `getAllEdgeProperties` built:
/// every key and value, then the table.
fn freeReadPropertyMap(allocator: Allocator, map: *std.StringHashMap(gs.PropertyValue)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        freeOwnedStorageProperty(allocator, entry.value_ptr.*);
    }
    map.deinit();
}

// CANARY: REQ=REQ-SONNY-2463-MATERIALIZE-OOM; FEATURE="EngineDirectNodeOwnership"; ASPECT=ReadMapPartialFailure; STATUS=TESTED; TEST=tests/test_sonny2463_materialize_oom.zig; OWNER=engine; UPDATED=2026-09-25
// CANARY: REQ=REQ-SONNY-6450-DUPLICATE-STORED-KEY; FEATURE="EngineDirectNodeOwnership"; ASPECT=LaterEntryReplacesEarlier; STATUS=TESTED; TEST=tests/test_sonny6450_ownership_residuals.zig; OWNER=storage; UPDATED=2026-11-12
/// Decode `encoded` and put it into `map` under a copy of `key`. The map owns
/// both copies once the put succeeds. If a copy or the put itself fails, the
/// copies made so far are freed here, and the map is unchanged (SONNY-2463:
/// they used to leak). SONNY-6450 item 6: a key the map already holds (the
/// same key twice in a stored property chain) has its value replaced by the
/// later entry's, and the earlier value freed; `put` kept the map's key and
/// dropped both the new key copy and the earlier value. `pub` for that
/// regression.
pub fn putDecodedProperty(allocator: Allocator, map: *std.StringHashMap(gs.PropertyValue), key: []const u8, encoded: []const u8) !void {
    const decoded = try gs.property.decode(allocator, encoded);
    // CANARY: REQ=REQ-SONNY-6433-KEYS-AFTER-REMOVE; FEATURE="PropertyStorage"; ASPECT=TombstoneNotAProperty; STATUS=TESTED; TEST=tests/test_sonny6433_keys_after_remove.zig; OWNER=storage; UPDATED=2026-11-12
    // SONNY-6433: a null is the tombstone `removeNodeProperty` (REMOVE, and
    // SET to null) writes: the property is absent, not present with a null
    // value. It was copied into the map, so keys() and properties() listed
    // a removed property.
    if (decoded.value == .null) {
        if (map.fetchRemove(key)) |kv| {
            allocator.free(kv.key);
            freeOwnedStorageProperty(allocator, kv.value);
        }
        return;
    }
    errdefer freeOwnedStorageProperty(allocator, decoded.value);
    if (map.getPtr(key)) |held| {
        freeOwnedStorageProperty(allocator, held.*);
        held.* = decoded.value;
        return;
    }
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try map.putNoClobber(owned_key, decoded.value);
}

// CANARY: REQ=REQ-SONNY-2806-EXACT-INDEX-NUMBER-HASH; FEATURE="InlinePropertyMatch"; ASPECT=ExactNumberHash; STATUS=TESTED; TEST=tests/test_sonny2806_exact_property_matching.zig; OWNER=storage; UPDATED=2026-09-26
/// SONNY-2806: the exact node-property index hashes a number by its exact
/// value (`value_order.writeNumberKey`, the key GROUP BY uses), whatever its
/// representation: INT 1, DECIMAL 1.0 and 1.00, a DOUBLE 1.0 and a SMALLINT 1
/// hash alike. It hashed the encoded bytes, so an inline-property seek for
/// `{x: 1}` found no stored 1.0, and the planned read and the streaming scan
/// take an empty seek as the answer. Every other value hashes its encoded
/// bytes, as before. Format edition: prop_exact.idx GENPIDX4 and
/// prop_rev.idx GENRVIX2 (an older file is stale, and the index is rebuilt).
fn storedNumber(value: gs.PropertyValue) ?value_order.Number {
    return switch (value) {
        .int => |i| .{ .exact = .{ .coeff = i, .scale = 0 } },
        .float => |f| .{ .float = f },
        .decimal => |d| .{ .exact = .{ .coeff = d.coeff, .scale = d.scale } },
        .ext => |e| property_codec.extPayloadNumber(e.type_tag, e.data),
        else => null,
    };
}

fn numberHash(n: value_order.Number) u64 {
    // The longest key is 18 bytes ('C', the i128 coefficient, the scale).
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    value_order.writeNumberKey(&w, n) catch unreachable;
    return std.hash.Wyhash.hash(0x2806, w.buffered());
}

fn hashStorageProperty(allocator: Allocator, value: gs.PropertyValue) !u64 {
    if (storedNumber(value)) |n| return numberHash(n);
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
/// A number hashes by its exact value, as in `hashStorageProperty` (SONNY-2806).
fn hashEncodedPropertyBytes(encoded_value: []const u8) u64 {
    if (gs.property.decodeView(encoded_value)) |decoded| {
        if (storedNumber(decoded.value)) |n| return numberHash(n);
    } else |_| {}
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
    /// SONNY-6354: the lean late-key generation (`graph_store.leanLateGenMax`)
    /// the exact index is complete for. A lean key registered at runtime after
    /// it has holders written while it was unregistered, so unindexed; the
    /// index serves (and is saved) only once `catchUpExactLeanKeysLocked` has
    /// added them (`exactIndexCurrent`). Written under
    /// `exact_index_build_mutex`.
    exact_lean_gen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// GAP-0064 FIX A: `true` while a RACE-FREE background reopen rebuild
    /// (`spawnExactIndexRebuildOnReopen` → `exactIndexRebuildOnReopenWorker`)
    /// owns this graph's exact-index build. Set at a successful reopen spawn
    /// (for an `.absent` OR `.stale` on-disk index), cleared by the worker when
    /// the build finishes/aborts. Two readers consult it, both non-blocking:
    ///   * the first-touch hydration FOLD (`buildAndPersistExactIndexForHydratedGraph`
    ///     called from `GraphStore.ensureGraphHydrated`) NO-OPs when it is set —
    ///     so hydration returns after resident loop1/loop2 instead of parking
    ///     every reader (even O(1) count) behind the ~14-min index build; and
    ///   * `checkpointOneGraph`'s FULL-path exact-index decision SKIPs the eager
    ///     build + the stale-file invalidation when it is set — so the
    ///     hydration-completion checkpoint cannot run a SECOND concurrent
    ///     `rebuildExactNodePropertyIndex` against the background worker's (two
    ///     concurrent rebuilds double-insert into the mutex-sharded index).
    /// The worker stores `exact_index_built = true` (.release) BEFORE clearing
    /// this flag (.release), so an observer that reads `inflight == false` is
    /// guaranteed to also read `built == true` — the checkpoint ladder relies on
    /// this to read `inflight` FIRST and treat a cleared flag as "build done".
    exact_rebuild_inflight: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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
    // CANARY: REQ=REQ-SONNY-3028-DROP-GRAPH-PINS; FEATURE="MultiGraphIsolation"; ASPECT=Pins; STATUS=TESTED; TEST=tests/test_sonny3028_drop_graph_in_use.zig; OWNER=storage; UPDATED=2026-09-27
    /// SONNY-3028: the threads that hold this graph through the adapter while
    /// it may be dropped (low bits), and whether it was (`dropped_bit`). A pin
    /// is taken under the adapter's `mutex` while the graph is in `engines`:
    /// by the graph lock API for every holder and waiter of `rwlock`
    /// (`acquireGraphReadLock`, `acquireGraphWriteLock*`, until the matching
    /// release), a group-commit batch, a checkpoint, and a session engine
    /// transaction's commit or abort. `dropGraph` takes the graph out of
    /// `engines` under the same mutex, so it sees every pin: with none it
    /// frees the graph, and otherwise the last `unpinGraph` does. A waiter that
    /// gets the lock of a dropped graph lets it go (`GraphNotFound`).
    /// `dropGraph` freed the graph under its lock's holders and waiters, whose
    /// release was then a use-after-free.
    pins: std.atomic.Value(u32) = .init(0),
    // CANARY: REQ=REQ-SONNY-3029-GROUP-COMMIT-TXN-GATE; FEATURE="High-Concurrency Mutations"; ASPECT=TxnGate; STATUS=TESTED; TEST=tests/test_sonny3029_group_commit_txn_gate.zig; OWNER=storage; UPDATED=2026-09-27
    /// SONNY-3029: group-commit batches with a statement transaction open on
    /// this graph (`enterBatchTxn`), and threads that hold or wait for its
    /// write lock (`acquireGraphWriteLock*`, `claimWriteLock`). A batch opens
    /// its transaction only while no writer is there, and a writer takes the
    /// lock only once every open batch has committed, so no batch
    /// transaction is open while another thread holds the graph's write lock.
    /// A batch keeps its transaction open across the SHARED holds of its ops;
    /// between two of them the graph's write lock could be taken, and the
    /// writer's engine transactions then overlapped the batch's (review probe
    /// P7: 15,314 of 864,308 samples), the SONNY-2978 class that loses
    /// committed writes on crash recovery.
    batch_txns_open: std.atomic.Value(u32) = .init(0),
    write_lock_claims: std.atomic.Value(u32) = .init(0),
    // CANARY: REQ=REQ-SONNY-3135-LOCKLESS-DROP-WAITS; FEATURE="MultiGraphIsolation"; ASPECT=WriteHolder; STATUS=TESTED; TEST=tests/test_sonny3135_lockless_drop_waits.zig; OWNER=storage; UPDATED=2026-11-12
    /// SONNY-3135 (N7c): the id (plus one) of the thread that holds `rwlock`
    /// EXCLUSIVE through the graph lock API (`acquireGraphWriteLock*`, until
    /// `releaseGraphWriteLock`), 0 when none does. `GraphStore.dropGraph`
    /// takes the write lock itself unless the calling thread holds it
    /// (`threadHoldsGraphWriteLock`), so a drop waits for the graph's
    /// holders without waiting for its own caller.
    write_holder: std.atomic.Value(u64) = .init(0),

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

    pub const dropped_bit: u32 = 1 << 31;

    /// SONNY-3028: was this graph dropped (it is out of `engines`, and its
    /// last pin frees it)?
    pub fn isDropped(self: *const ManagedGraph) bool {
        return self.pins.load(.acquire) & dropped_bit != 0;
    }

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

    fn deinit(self: *ManagedGraph, allocator: Allocator, crash: bool) void {
        // Teardown order matters: facade → adapter (flushes + closes each engine
        // and its child dir) → base_dir (the adapter never closes base_dir) →
        // free the owned path. Durability is owned by the engine WAL/segments;
        // `adapter.deinit` best-effort flushes each engine before closing it.
        //
        // `crash` (test-only): when true, tear the engine down via `deinit()`
        // (memory-only, NO final checkpoint) instead of `close()` (which
        // checkpoints when dirty). Committed txns are already durable in the WAL
        // (per-commit fsync), so this leaves a genuine committed WAL TAIL for the
        // next open's recovery to replay — a faithful kill-9 crash simulation.
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
        if (crash) {
            self.engine.deinit(); // no checkpoint → committed WAL tail survives
        } else {
            self.engine.close() catch {};
        }
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

    // Label-dictionary durability (gap 0026 for the security graph;
    // GAP-0915 extended it to EVERY graph): the label dictionary is NOT
    // WAL-logged — it is persisted only at checkpoint (labels.dict).
    // Per-commit WAL fsync alone is therefore insufficient on a FRESH
    // (never-checkpointed) graph: after an unclean crash, recovery replays
    // the node records from the fsynced WAL but has lost the name→id
    // mappings, leaving every record unreachable BY LABEL — labeled MATCH
    // returned 0 while `MATCH (n)` saw the full committed set. Persist the
    // (tiny, bounded — a handful of labels ever) per-shard dictionaries
    // synchronously on FIRST sight of a label, and fail the mutation if the
    // persist fails: durability before ack, fail closed. saveToFile is
    // atomic (tmp + fsync + rename), matching the checkpoint writer, so a
    // crash mid-save leaves the previous dictionary intact.
    // CANARY: REQ=REQ-GAP-0915-LABEL-INDEX-CRASH-REBUILD; FEATURE="CrashRecovery"; ASPECT=LabelDictFirstSightPersist; STATUS=TESTED; TEST=tests/test_gap0910_0915_crash_recovery.zig; OWNER=storage; UPDATED=2026-07-10
    {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        for (mg.engine.shards) |shard| {
            const labels_path = try std.fmt.bufPrint(&path_buf, "{s}/labels.dict", .{shard.graph_dir.path});
            try shard.label_dict.saveToFile(labels_path);
        }
    }
    return id;
}

/// Security-graph durability (gap 0026), belt-and-suspenders re-log of the
/// node's label var_store page inside the mutating txn so it commits (and, on
/// the security graph's `sync_each_commit` engines, fsyncs) with the mutation.
///
/// HISTORY: this began as a workaround for an upstream graph-storage WAL
/// mis-log — `GraphEngine.addLabelTxn` used to log the label block with
/// `logPage(txn, .var_store, result.head)`, imaging a bogus page id instead of
/// the real label-block page, so labels written since the last checkpoint
/// vanished on crash recovery. That upstream defect is FIXED as of gs v0.3.2:
/// `addLabelTxn` now images the var page via `logVarChain`, which correctly
/// decodes both encodings (see below). This re-log is therefore redundant with
/// the engine's own WAL image, but is retained as defensive durability.
///
/// SLAB-HEAD DECODE (the crash this function itself caused before the fix):
/// a var head is EITHER a legacy page-chain ref `first_page << 16` (page id =
/// `head >> 16`) OR a slab-packed head with bit 63 set (`TAG | page<<24 | slot`,
/// page id = `slabHeadPageId(head)`). The previous `head >> 16` decode was
/// correct ONLY for the legacy form; for a slab head it produced a ~2^47 page
/// id (e.g. 0x800000000100). Recovery replayed that bogus page image into a
/// dirty buffer-pool frame, and `flushAll` then issued a `pwrite` at an ~1.15 EB
/// offset → `EFBIG` → `error.FileTooBig`, so the ENTIRE `__geode_security`
/// engine failed to reopen after a crash of a never-checkpointed security graph
/// (a real durability loss: the acknowledged security mutation became
/// unrecoverable). Decode slab-aware — exactly as `gs`'s own `logVarChain` does.
///
/// Scoped to `__geode_security`; no-op for non-security graphs and label-less
/// nodes.
fn relogSecurityLabelPageTxn(mg: *ManagedGraph, node_shard: anytype, node_id: u64, txn: gs.TxnId) !void {
    if (!std.mem.eql(u8, mg.name, "__geode_security")) return;
    const rec = (try node_shard.getNode(node_id)) orelse return;
    const head = rec.label_head;
    if (head == 0) return;
    const page_id = if (gs.var_store.isSlabHead(head))
        gs.var_store.slabHeadPageId(head)
    else
        head >> 16;
    try node_shard.logPagePublic(txn, .var_store, page_id);
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

// CANARY: REQ=REQ-SONNY-6384-WAL-LSN-ANCHOR; FEATURE="Auth DDL Persistence"; ASPECT=WalLsnAnchorAtOpen; STATUS=TESTED; TEST=tests/test_sonny6384_offline_change_crash_durability.zig; OWNER=storage; UPDATED=2026-11-12
/// SONNY-6384: keep each shard WAL's LSN at or past its manifest's
/// `last_checkpoint_lsn` before anything writes to the graph.
///
/// A full checkpoint sets `last_checkpoint_lsn = L` and compacts the WAL up
/// to L; when that leaves the WAL empty, the WAL library deletes its
/// `graph.wal.ckpt` sidecar, the only record of the WAL's LSN for an empty
/// file (the clean close rewrites it). A process that ends after such a
/// checkpoint without closing the engine (a SIGKILL, or the offline CLI,
/// which never closes it) leaves the next open numbering the WAL from 0, while
/// recovery replays from L by that same numbering: every record written
/// afterwards is skipped by the next crash recovery (lost), or, once more
/// than L were written, only a torn tail of them is replayed.
///
/// Heal: append one no-op `checkpoint_marker` at exactly LSN L and fsync it,
/// the anchor the clean close would have left. Recovery replays from L + 1,
/// so it never replays the marker; the next checkpoint compacts it away.
/// Records already skipped by an earlier recovery are not recovered here.
/// A failure fails the open: serving the graph would acknowledge writes that
/// the next crash recovery drops.
fn healWalLsnAnchor(engine: *gs.ShardedGraphEngine) !void {
    for (engine.shards) |shard| {
        if (shard.read_only) continue;
        const covered = shard.manifest.last_checkpoint_lsn;
        if (shard.wal.inner.currentLsn() >= covered) continue;
        var rec = gs.wal_record.WalRecord{
            .lsn = covered,
            .txn_id = 0,
            .record_type = .checkpoint_marker,
            .file_id = 0,
            .page_id = 0,
            .payload = &.{},
            .checksum = 0,
        };
        var buf: [64]u8 = undefined;
        const n = try rec.serializeInto(&buf);
        _ = try shard.wal.inner.appendWithLsn(covered, buf[0..n]);
        try shard.wal.inner.sync();
        if (shard.wal.current_lsn < covered) shard.wal.current_lsn = covered;
        log.warn("healed shard WAL LSN anchor: the WAL numbered below its last checkpoint LSN {d} (an empty WAL left by a checkpoint and no clean close)", .{covered});
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

/// SONNY-6354: `addNodePropertiesForLabels` restricted to the lean keys
/// registered at runtime after generation `since`
/// (`catchUpExactLeanKeysLocked`). The node may already be in a posting (a
/// write after the registration indexed it), so the de-dup scan stays on.
fn addNodeLateKeyPropertiesForLabels(mg: *ManagedGraph, node_id: u64, label_ids: []const gs.LabelId, prop_head: u64, since: u64) !void {
    if (prop_head == 0 or label_ids.len == 0) return;
    var iter = try mg.shardEngineForNode(node_id).getAllProperties(prop_head);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        if (!graph_store.leanKeyRegisteredAfter(entry.key, since)) continue;
        for (label_ids) |label_id| {
            try addIndexedNodePropertyFromEncoded(mg, label_id, node_id, entry.key, entry.encoded_value, false);
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
    // SONNY-6354: the rebuild indexes every key registered when it reads the
    // node, so it is complete for the late keys registered before it began.
    const lean_gen = graph_store.leanLateGenMax();
    try scanExactNodePropertyIndex(mg, cancel, null);
    mg.exact_lean_gen.store(lean_gen, .release);
}

/// SONNY-6354: is the exact index built and complete for every lean key
/// registered so far (`ManagedGraph.exact_lean_gen`)? Lock-free.
fn exactIndexCurrent(mg: *ManagedGraph) bool {
    if (!mg.exact_index_built.load(.acquire)) return false;
    return mg.exact_lean_gen.load(.acquire) >= graph_store.leanLateGenMax();
}

// CANARY: REQ=REQ-SONNY-6354-LEAN-LATE-KEY-INDEXES; FEATURE="MergeIdempotency"; ASPECT=ExactIndexLateKeyCatchUp; STATUS=TESTED; TEST=tests/test_sonny6354_lean_late_key_indexes.zig; OWNER=storage; UPDATED=2026-11-12
/// SONNY-6354: add to a BUILT exact index the postings of the lean keys
/// registered at runtime since it was last complete (`exact_lean_gen`): the
/// nodes that carried such a key before it was registered were not indexed
/// for it (`addIndexedNodePropertyEx` skips unregistered keys), and every
/// seek trusts the index as complete for a registered key
/// (`graph_store.shouldIndexProperty`). Nothing is removed and no other key
/// is touched, so a reader of another key is unaffected; a posting a live
/// write added meanwhile is de-duplicated. Repeats until no key was
/// registered during the scan. Caller holds `exact_index_build_mutex`.
fn catchUpExactLeanKeysLocked(mg: *ManagedGraph, cancel: read_budget.CancelFlags) !void {
    while (true) {
        const target = graph_store.leanLateGenMax();
        const since = mg.exact_lean_gen.load(.acquire);
        if (target <= since) return;
        try scanExactNodePropertyIndex(mg, cancel, since);
        mg.exact_lean_gen.store(target, .release);
    }
}

/// SONNY-6354: make a built exact index complete for every registered key
/// (`catchUpExactLeanKeysLocked`) before it is saved, and return the key
/// configuration to stamp it with. The configuration is read FIRST, so every
/// key it names is one the catch-up then covers. Caller holds
/// `exact_index_build_mutex`.
fn prepareExactIndexSaveLocked(mg: *ManagedGraph) !u64 {
    const config = graph_store.exactIndexConfigHash();
    try catchUpExactLeanKeysLocked(mg, .{});
    return config;
}

/// The per-shard node scan behind the rebuild (`late_since == null`: clear,
/// then index every registered key) and the late-key catch-up
/// (`late_since == g`: add only the postings of lean keys registered after
/// generation `g`, clearing nothing).
fn scanExactNodePropertyIndex(mg: *ManagedGraph, cancel: read_budget.CancelFlags, late_since: ?u64) !void {
    if (late_since == null) {
        // H4 (cold-open phase 1): instrument every rebuild so tests can prove the
        // deferred-build latch rebuilds 0 times at open and exactly once on first
        // access. Counts the eager-open, test-helper, AND lazy-first-access paths.
        _ = g_exact_rebuild_runs.fetchAdd(1, .monotonic);
        mg.exact_node_property_index.clear();
        mg.exact_index_rebuild_iters.store(0, .monotonic);
        // task0048d: per-build dispatch accounting (pool vs inline shard scans).
        g_exact_rebuild_pool_tasks.store(0, .monotonic);
        g_exact_rebuild_inline_tasks.store(0, .monotonic);
    }

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
        late_since: ?u64,
        since_poll: usize = 0,
        err: ?anyerror = null,

        fn scanCallback(self: *@This(), node_id: gs.NodeId, rec: gs.node.NodeRec) void {
            if (self.err != null) return;
            // Coverage counter: count every live node the scan presents (atomic
            // so the parallel per-shard workers compose correctly).
            if (self.late_since == null) {
                _ = self.mg.exact_index_rebuild_iters.fetchAdd(1, .monotonic);
                _ = g_exact_rebuild_nodes_scanned.fetchAdd(1, .monotonic);
            }
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

            if (self.late_since) |since| {
                addNodeLateKeyPropertiesForLabels(self.mg, node_id, label_ids, rec.prop_head, since) catch |err| {
                    self.err = err;
                };
                return;
            }
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
        ctxs[idx] = .{ .mg = mg, .shard = shard, .cancel = cancel, .late_since = late_since };
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
            if (late_since == null) _ = g_exact_rebuild_pool_tasks.fetchAdd(1, .monotonic);
        } else |_| {
            inline_ctxs_buf[inline_n] = c;
            inline_n += 1;
        }
    }
    // Shards that failed to submit run inline on this (non-worker) thread BEFORE
    // wg.wait(), so they still complete and are not double-counted by wg.
    for (inline_ctxs_buf[0..inline_n]) |c| {
        if (late_since == null) _ = g_exact_rebuild_inline_tasks.fetchAdd(1, .monotonic);
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
/// discipline re-checks the latch under the EXCLUSIVE rwlock), and — SONNY-1574
/// — strictly AFTER `exact_index_build_mutex` is RELEASED, so the worker's
/// checkpoint can never lose its non-blocking `tryLock` to the very build it is
/// persisting (the lost persist).
fn ensureExactNodePropertyIndexBuilt(adapter: *StorageAdapter, mg: *ManagedGraph) !void {
    return ensureExactIndex(adapter, mg, .wait);
}

// CANARY: REQ=REQ-SONNY-6362-READ-NO-BUILD-WAIT; FEATURE="ExactPropertyIndex"; ASPECT=ReadFallsBackDuringBuild; STATUS=TESTED; TEST=tests/test_sonny6362_exact_index_read_fallback.zig; OWNER=storage; UPDATED=2026-11-12
/// SONNY-6362 item 6: `ensureExactNodePropertyIndexBuilt` for an index-served
/// READ. While another thread holds `exact_index_build_mutex` (a deferred
/// build or a late-key catch-up, O(graph)) a read parked on it for the whole
/// build; it now answers `error.ExactIndexBusy` at once, and every read
/// caller treats an error as "no index answer" and scans. With the mutex
/// free the read builds (or catches up) the index itself, as before. Write
/// paths and the MERGE resolver keep waiting: they must see a complete index.
fn ensureExactIndexForRead(adapter: *StorageAdapter, mg: *ManagedGraph) !void {
    return ensureExactIndex(adapter, mg, .no_wait);
}

fn ensureExactIndex(adapter: *StorageAdapter, mg: *ManagedGraph, comptime mode: enum { wait, no_wait }) !void {
    // SONNY-6354: built AND complete for every lean key registered so far.
    if (exactIndexCurrent(mg)) return;
    const io = std.Io.Threaded.global_single_threaded.io();
    // SONNY-1574: the build runs in an INNER scope so `exact_index_build_mutex`
    // is released BEFORE the persist worker is spawned (see the spawn below).
    const built_here = blk: {
        switch (mode) {
            .wait => mg.exact_index_build_mutex.lockUncancelable(io),
            .no_wait => if (!mg.exact_index_build_mutex.tryLock()) return error.ExactIndexBusy,
        }
        defer mg.exact_index_build_mutex.unlock(io);
        // Double-check under the mutex: a peer first-accessor may have built it
        // while we waited for the lock. A built index may still lack a lean
        // key registered since (SONNY-6354): add its older holders.
        if (mg.exact_index_built.load(.acquire)) {
            try catchUpExactLeanKeysLocked(mg, read_budget.activeCancelFlags());
            break :blk false;
        }
        // GAP-0064 (adversarial review — TEST-ONLY): hold the LAZY build "in flight"
        // (mutex held, mid-build) so a test can prove a concurrent FULL checkpoint's
        // eager build does NOT run a second concurrent rebuild (the lazy-vs-checkpoint
        // double-insert race). Reuses the same gate the worker path uses; never blocks
        // in production (gate == 0).
        if (comptime @import("builtin").is_test) {
            if (g_test_exact_build_gate.load(.acquire) != 0) {
                _ = g_test_build_gate_waiters.fetchAdd(1, .acq_rel);
                while (g_test_exact_build_gate.load(.acquire) != 0) {
                    std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(1), .awake) catch {};
                }
                _ = g_test_build_gate_waiters.fetchSub(1, .acq_rel);
            }
        }
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
        break :blk true;
    };
    // SONNY-1574 (lost persist under load): spawn the background persist ONLY
    // after the build mutex above has been RELEASED. Previously this call was
    // the last statement of the function while the `defer unlock` had not yet
    // fired, so the worker's checkpoint could reach
    // `checkpointPersistExactIndexLocked` — whose acquire is a deliberate
    // NON-BLOCKING `tryLock` (it holds mg.rwlock EXCLUSIVE and must not park
    // behind a ~14-min rebuild) — while THIS thread still held the mutex. The
    // worker then skipped the persist against a build that was already
    // FINISHED and whose only persist action was spawning that very worker:
    // nothing was written, and (pre-fix) the worker reported a completion
    // anyway. Under normal load the builder returned first and the tryLock won;
    // under the pre-push shard load (145-175) it lost.
    //
    // The documented invariant is preserved: the spawn still happens strictly
    // AFTER the `exact_index_built` latch store, so the persist's checkpoint
    // observes `built == true` (the 88a05773 never-persist-unbuilt discipline
    // re-checks the latch under the EXCLUSIVE rwlock). The invariant is about
    // the LATCH, not the mutex.
    //
    // No deadlock is introduced (this strictly SHORTENS a lock hold and adds no
    // acquire), and no double-persist: `built` is already true, so no peer
    // re-enters the rebuild branch, and every writer of `prop_exact.idx` holds
    // the same build mutex around `saveToFile` — concurrent persists serialize
    // and each writes the same (now immutable-until-mutation) index.
    if (built_here) adapter.spawnExactIndexPersistAfterBuild(mg.name);
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

// CANARY: REQ=REQ-SONNY-2823-SESSION-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=SessionSlot; STATUS=TESTED; TEST=tests/test_sonny2823_session_engine_txn.zig; OWNER=storage; UPDATED=2026-09-27
/// SONNY-2823: a session's engine transaction (R9). It lives in the session
/// (`ServerState.session_engine_txn`), is on a thread only while one of the
/// session's requests runs there (`enterSessionEngineTxn` /
/// `leaveSessionEngineTxn`), and never outlives the program that opened it:
/// the executor commits it when its outermost entry point returns, under the
/// request's graph lock, unless a ROLLBACK aborted it first.
///
/// R9 opened the transaction into a thread-local slot and kept it open until
/// the Geode transaction's COMMIT, as if one thread served one session. gRPC
/// serves a session's requests on any worker thread, and QUIC's cooperative
/// scheduler and mutation offload pool serve many sessions on one thread.
/// And only QUIC's COMMIT and ROLLBACK messages ended it. So it stayed open
/// on the thread: a committed transaction's writes on its shard had no
/// COMMIT record, and every later write on that thread, from any session,
/// joined it and was lost with it.
///
/// It does not span requests either. An engine transaction holds its shard
/// WAL's record batch from `begin` to commit (GAP-0900), so the page images
/// it logged are appended at commit, after the images other transactions
/// logged and committed in between. Recovery replays in log order, so its
/// older image of a shared page overwrote their newer one, and a crash lost
/// their committed writes. Inside one program the request's graph write lock
/// keeps every other writer off the graph.
pub const SessionEngineTxn = struct {
    txn: StatementTxn = undefined,
    /// The UUID of the graph `txn` was opened on: DROP GRAPH frees the
    /// graph's `ManagedGraph` (`txn.mg`) whatever is open on it, and a graph
    /// created again may reuse the address, never the UUID.
    graph_uuid: [16]u8 = undefined,
    /// `txn` is an open engine transaction. Kept by `beginSessionTxnLazy`
    /// and the commit and abort functions.
    open: bool = false,
    /// SONNY-3135 (N7b): the session's request failed inside its transaction
    /// (`noteSessionTxnFailed`), which the handler rolls back: its engine
    /// transaction is aborted, never committed (`settleAtWriteRelease`).
    /// Cleared when a request of the session starts and ends.
    failed: bool = false,
};

/// SONNY-2823: the session slot installed on this thread, or null. With none,
/// no session engine transaction is opened (`beginSessionTxnLazy`), and a
/// transaction's statements use per-statement engine transactions (R8).
threadlocal var t_session_engine_slot: ?*SessionEngineTxn = null;

/// SONNY-2823: what `enterSessionEngineTxn` changed on the thread.
pub const SessionEngineTxnScope = struct {
    prev: ?*SessionEngineTxn = null,
    /// The slot was already installed (a rollback or teardown inside the
    /// session's own request): the matching leave changes nothing.
    nested: bool = false,
};

/// SONNY-2823: install `slot` on this thread for one request of its session.
pub fn enterSessionEngineTxn(slot: *SessionEngineTxn) SessionEngineTxnScope {
    if (t_session_engine_slot == slot) return .{ .prev = slot, .nested = true };
    slot.failed = false;
    const prev = t_session_engine_slot;
    t_session_engine_slot = slot;
    t_session_engine_txn = if (slot.open) &slot.txn else null;
    return .{ .prev = prev };
}

// CANARY: REQ=REQ-SONNY-3027-PROFILE-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=Instrumentation; STATUS=TESTED; TEST=tests/test_sonny3027_profile_engine_txn.zig; OWNER=storage; UPDATED=2026-09-27
/// SONNY-3027: releases of a graph's write lock that found a session engine
/// transaction still open on the releasing thread (`settleAtWriteRelease`).
/// The request's handler commits it before it lets go; each one counted here
/// is a path that did not. Zero in a correct server.
pub var session_txn_open_at_write_release_total: std.atomic.Value(u64) = .init(0);
/// SONNY-3027: requests that ended with their session engine transaction
/// still open (`leaveSessionEngineTxn`'s backstop), which aborts it. Zero in a
/// correct server.
pub var session_txn_backstop_total: std.atomic.Value(u64) = .init(0);

/// SONNY-2823: the request is over. The thread keeps no session engine
/// transaction, and no per-statement one either: neither may outlive the
/// request on a pooled thread, where the next request's writes, from any
/// session, would join it.
///
/// SONNY-3027: true when the backstop ran: the session's engine transaction
/// was still open. The request's write lock is released by now, so it is
/// aborted, never committed (a commit here, outside the lock, overlapped the
/// transactions of the graph's next writer: the SONNY-2978 class), and the
/// caller fails the session's transaction.
pub fn leaveSessionEngineTxn(slot: *SessionEngineTxn, scope: SessionEngineTxnScope) bool {
    if (scope.nested) return false;
    var backstop = false;
    if (slot.open and t_session_engine_txn == &slot.txn) {
        // The executor commits it when the program that opened it returns,
        // and the handler before it releases the program's write lock; one
        // still open is a bug. A warning: the failure is handled, and the
        // client sees it (its transaction fails); the counter tells.
        log.warn("a session engine txn outlived its request's write lock; aborting it and failing its transaction", .{});
        _ = session_txn_backstop_total.fetchAdd(1, .monotonic);
        abortThreadSessionTxn();
        backstop = true;
    }
    if (t_session_commit_failure) |err| {
        // SONNY-3031: a commit of the session's engine transaction failed in
        // this request, and no handler reported it: its transaction failed.
        log.warn("a session engine txn commit failed and was not reported; failing its transaction: {s}", .{@errorName(err)});
        t_session_commit_failure = null;
        backstop = true;
    }
    slot.open = false;
    slot.failed = false;
    t_session_engine_slot = scope.prev;
    t_session_engine_txn = if (scope.prev) |p| (if (p.open) &p.txn else null) else null;
    if (scope.prev == null and t_current_statement_txn != null) {
        // A statement opens its per-statement transaction in its own frame
        // and ends it there, so one still set here is a bug, and its handle
        // lives in a frame that has returned: it is not read. The thread
        // forgets it; WAL recovery rolls back a transaction never committed.
        log.err("a statement engine txn was left open at the end of a request; the thread forgets it", .{});
        t_current_statement_txn = null;
    }
    return backstop;
}

// CANARY: REQ=REQ-SONNY-3027-PROFILE-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=CommitBeforeRelease; STATUS=TESTED; TEST=tests/test_sonny3027_profile_engine_txn.zig; OWNER=storage; UPDATED=2026-09-27
/// SONNY-3027: the transport handlers call this while they still hold the
/// request's graph write lock, before they release it: the session engine
/// transaction the request left on this thread is committed under the lock.
/// The executor's entry points commit it when the program ends; a path that
/// ran a change without passing one (the PROFILE arm) left it open, and only
/// the backstop committed it, after the lock was released. An error fails the
/// request, and the handler rolls back the session's transaction.
///
/// SONNY-3031: it also reports a commit that failed earlier in the request
/// where no error could be returned (`noteSessionCommitFailure`, the end of
/// the executor's program). Either failure is `error.SessionCommitFailed`
/// (40000): the transaction's changes are not durable, so the request fails
/// and the handler rolls the transaction back.
pub fn settleThreadSessionTxn() error{SessionCommitFailed}!void {
    if (t_session_commit_failure) |err| {
        t_session_commit_failure = null;
        log.warn("session engine txn commit failed: {s}", .{@errorName(err)});
        abortThreadSessionTxn();
        return error.SessionCommitFailed;
    }
    commitThreadSessionTxn() catch |err| {
        log.warn("session engine txn commit failed: {s}", .{@errorName(err)});
        return error.SessionCommitFailed;
    };
}

// CANARY: REQ=REQ-SONNY-3031-SESSION-COMMIT-FAILURE; FEATURE="TransactionManagement"; ASPECT=NotedFailure; STATUS=TESTED; TEST=tests/test_sonny3031_session_commit_failure.zig; OWNER=storage; UPDATED=2026-09-27
/// SONNY-3031: a session engine commit that failed where its error could
/// not be returned (the executor's program end, `graph_store.releaseGraphLock`),
/// kept for the request's handler (`settleThreadSessionTxn`) or, failing that,
/// the backstop (`leaveSessionEngineTxn`). It was only logged: the request
/// and the transaction's COMMIT reported success.
threadlocal var t_session_commit_failure: ?anyerror = null;

pub fn noteSessionCommitFailure(err: anyerror) void {
    if (t_session_commit_failure == null) t_session_commit_failure = err;
}

/// SONNY-3031 fault injection for tests: the next N commits of a session
/// engine transaction fail (`error.InjectedSessionCommitFailure`) before
/// they reach the engine, as a failed WAL append or fsync would.
pub var session_commit_fault_injections: std.atomic.Value(u32) = .init(0);

fn takeInjectedCommitFault() bool {
    var n = session_commit_fault_injections.load(.monotonic);
    while (n > 0) {
        n = session_commit_fault_injections.cmpxchgWeak(n, n - 1, .monotonic, .monotonic) orelse return true;
    }
    return false;
}

/// SONNY-3027: `graph_store.releaseGraphLock` of a write lock, before it lets
/// go. A session engine transaction still open on this thread is committed
/// now, under the lock, rather than after it (by then another writer may hold
/// the lock and have transactions of its own open on the graph). Its handler
/// should have committed it first (`settleThreadSessionTxn`), so it is
/// counted and logged.
///
/// CANARY: REQ=REQ-SONNY-3135-FAILED-TXN-ABORT; FEATURE="TransactionManagement"; ASPECT=SettleAtWriteRelease; STATUS=TESTED; TEST=tests/test_sonny3135_profile_allowlist_failed_txn.zig; OWNER=storage; UPDATED=2026-09-27
/// SONNY-3135 (N7b): the transaction of a request that failed
/// (`noteSessionTxnFailed`) is aborted instead: the handler rolls it back
/// once the lock is released, and a commit made the failed changes durable
/// until then (the SONNY-2979 crash window).
pub fn settleAtWriteRelease() void {
    if (t_session_engine_txn == null) return;
    _ = session_txn_open_at_write_release_total.fetchAdd(1, .monotonic);
    if (sessionTxnFailed()) {
        // The structured logger, at error level: the path is a handled
        // failure, and std.log's error level fails a test that drives it.
        slog.err("a graph write lock was released with a failed request's session engine txn open; aborting it under the lock", &.{});
        abortThreadSessionTxn();
        return;
    }
    log.err("a graph write lock was released with a session engine txn open; committing it under the lock", .{});
    commitThreadSessionTxn() catch |err| noteSessionCommitFailure(err);
}

/// SONNY-3135 (N7b): the request running on this thread failed inside its
/// session's transaction, which its handler rolls back: the session engine
/// transaction is aborted, not committed, wherever it is settled
/// (`settleAtWriteRelease`, the executor's program end). No-op without a
/// session slot on the thread.
pub fn noteSessionTxnFailed() void {
    if (t_session_engine_slot) |slot| slot.failed = true;
}

/// SONNY-3135 (N7b): did the request running on this thread fail inside its
/// session's transaction (`noteSessionTxnFailed`)?
pub fn sessionTxnFailed() bool {
    const slot = t_session_engine_slot orelse return false;
    return slot.failed;
}

/// SONNY-2823: take this thread's session engine transaction off the thread
/// (and out of its slot), or null for none. Null too when its graph was
/// dropped: the transaction went with the graph's engine, and `txn.mg`,
/// freed, is not read.
///
/// SONNY-3028: the graph comes back pinned (`ManagedGraph.pins`), so a
/// `dropGraph` on another thread cannot free it between the check and the
/// commit or abort; the caller unpins it (`unpinTaken`). The check and the use
/// were two steps, with the adapter's mutex released between them.
fn takeThreadSessionTxn() ?*StatementTxn {
    const txn = t_session_engine_txn orelse return null;
    t_session_engine_txn = null;
    const slot = t_session_engine_slot orelse return txn;
    if (&slot.txn != txn) return txn;
    slot.open = false;
    const ad = graph_store.getGlobalAdapter() orelse return null;
    if (!ad.pinIfOpen(slot.txn.mg, slot.graph_uuid)) {
        log.warn("the graph of a session engine txn was dropped; the txn went with it", .{});
        return null;
    }
    return txn;
}

/// SONNY-3028: the pin `takeThreadSessionTxn` took on `txn`'s graph.
fn unpinTaken(txn: *StatementTxn) void {
    const slot = t_session_engine_slot orelse return;
    if (&slot.txn != txn) return;
    const ad = graph_store.getGlobalAdapter() orelse return;
    ad.unpinGraph(txn.mg);
}

/// SONNY-2823: commit this thread's session engine transaction, if it has
/// one: ONE WAL fsync for its writes on its shard.
///
/// SONNY-3031: a commit that fails aborts the transaction, so the engine
/// forgets it: it stayed in the shard's `active_txns` forever.
pub fn commitThreadSessionTxn() !void {
    const txn = takeThreadSessionTxn() orelse return;
    defer unpinTaken(txn);
    const result = if (takeInjectedCommitFault())
        error.InjectedSessionCommitFailure
    else
        txn.mg.engine.commitTxn(txn.txn_id);
    result catch |err| {
        txn.mg.engine.abortTxn(txn.txn_id) catch |abort_err| {
            log.err("session engine txn abort after a failed commit failed: {s}", .{@errorName(abort_err)});
        };
        return err;
    };
}

/// SONNY-3348 (round 19): does this thread have a session engine
/// transaction open?
pub fn hasThreadSessionTxn() bool {
    return t_session_engine_txn != null;
}

/// SONNY-2823: abort this thread's session engine transaction, if it has
/// one. Callers abort BEFORE the undo log replays, so the replay's own
/// changes commit on their own and do not join the aborted transaction.
pub fn abortThreadSessionTxn() void {
    const txn = takeThreadSessionTxn() orelse return;
    defer unpinTaken(txn);
    // error-policy: A — best-effort session rollback; WAL recovery
    // supersedes a failed abort.
    txn.mg.engine.abortTxn(txn.txn_id) catch {};
}

/// SONNY-3028: does this thread have an engine transaction open on `mg` (its
/// session's, or a statement's)? `dropGraph` refuses to drop that graph.
fn threadTxnOn(mg: *const ManagedGraph) bool {
    if (t_session_engine_txn) |t| if (t.mg == mg) return true;
    if (t_current_statement_txn) |t| if (t.mg == mg) return true;
    return false;
}

/// Return the thread-local statement txn if it targets `graph_name`; else null.
/// Adapter mutation methods consult this to decide whether to batch into an
/// existing transaction or spin their own (the R7 behaviour).  Priority:
/// 1. per-statement txn (R8), 2. session txn (R9).
// CANARY: REQ=REQ-SONNY-2978-OVERLAPPING-ENGINE-TXN; FEATURE="TransactionManagement"; ASPECT=UnbatchedSpanningTxn; STATUS=TESTED; TEST=tests/test_sonny2978_overlapping_engine_txn_crash.zig; OWNER=storage; UPDATED=2026-11-13
/// SONNY-2978: give back the shard WAL record batch (GAP-0900) that
/// `beginTxn` opened for the engine transaction `txn_id` of `mg`, before
/// anything is logged in it. Its page images are then written to the log
/// as they are made, like any other transaction's.
///
/// A batched transaction's images are numbered when made but written only
/// at its commit, and recovery replays the log in written order. A
/// statement or session engine transaction stays open across many adapter
/// calls, and some of them commit their own engine transaction on its shard
/// (a REMOVE, a DELETE, an edge-property REMOVE, any change on a shard the
/// statement transaction is not on that later gets one). Batched, the
/// spanning transaction's older image of a page they share reached the log
/// after theirs, and after a crash undid their committed change. Only
/// `beginStatementTxnForShard` (group commit) keeps its batch: its worker
/// writes only its own shard (REQ-QUIC-HC-016), and no writer holds the
/// graph's write lock while the batch is open (SONNY-3029).
fn releaseSpanningTxnWalBatch(mg: *ManagedGraph, txn_id: gs.TxnId) !void {
    const shard = mg.engine.shards[shardedTxnShard(txn_id)];
    try shard.txn_manager.wal.flushBatchFor(shardedTxnLocal(txn_id));
}

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

/// Max ordered-tree entries one shard batch visits per lock hold. Bounds how
/// long a single batch fences a queued EXCLUSIVE checkpoint/apply on that
/// shard (wedge-avoidance), mirroring `label_scan_batch_slots`.
const ordered_scan_batch_slots: usize = 256;

/// One copied-out head from a shard's ordered tree. `key` is an OWNED dup of
/// the tree's (order-preserving) encoded key bytes — copied under the locks
/// because the borrowed `OrderedBTree.Entry.key` is only valid under them and
/// until the next mutation of that tree.
const OrderedScanHead = struct { key: []u8, node_id: u64 };

/// Per-shard resume point + current bounded batch for the k-way merge.
const OrderedShardState = struct {
    /// OWNED copy of the last tree key the previous batch visited (live or
    /// not); null before the first batch. The next batch starts strictly
    /// after it in scan order.
    resume_key: ?[]u8 = null,
    exhausted: bool = false,
    buf: std.ArrayList(OrderedScanHead) = .empty,
    pos: usize = 0,
};

/// SONNY-6375: the graphs whose `rwlock` this thread holds through the
/// graph-lock API (`acquireGraphReadLock`, `acquireGraphWriteLock`,
/// `acquireGraphWriteLockCancelable`, and the `graph_store` handles built on
/// them), so a reader that takes `mg.rwlock` SHARED itself (`orderedScan`)
/// skips it when its own thread already holds the lock. `std.Io.RwLock` is not
/// reentrant: SHARED under this thread's EXCLUSIVE never returns, and a
/// second SHARED behind a waiting writer can wedge.
///
/// CANARY: REQ=REQ-SONNY-6433-ORDERED-INDEX-LOCKING; FEATURE="OrderedIndex"; ASPECT=GraphLockTrackingGrows; STATUS=TESTED; TEST=tests/test_sonny6433_ordered_index_locking.zig; OWNER=storage; UPDATED=2026-11-12
/// SONNY-6433: the table grows past its 16 inline slots
/// (`t_held_graph_locks_overflow`), so every lock is tracked by graph. It
/// used to count a 17th lock without its graph, and while one was held every
/// graph counted as held: an ordered scan of a graph this thread did not lock
/// then read it with no `rwlock`. The room for the next entry is reserved
/// BEFORE the lock is taken (`reserveGraphLockSlot`), so recording it cannot
/// fail; an acquisition that cannot get the room fails (out of memory) with
/// no lock taken. The overflow list is freed when it empties.
const max_tracked_graph_locks = 16;
threadlocal var t_held_graph_locks: [max_tracked_graph_locks]?*const ManagedGraph = @splat(null);
threadlocal var t_held_graph_locks_overflow: std.ArrayListUnmanaged(*const ManagedGraph) = .empty;
const graph_lock_overflow_allocator = std.heap.smp_allocator;

/// SONNY-6433: room to record one more graph lock on this thread. Call it
/// before taking the lock.
fn reserveGraphLockSlot() error{OutOfMemory}!void {
    for (t_held_graph_locks) |slot| {
        if (slot == null) return;
    }
    try t_held_graph_locks_overflow.ensureUnusedCapacity(graph_lock_overflow_allocator, 1);
}

fn noteGraphLockTaken(mg: *const ManagedGraph) void {
    for (&t_held_graph_locks) |*slot| {
        if (slot.* == null) {
            slot.* = mg;
            return;
        }
    }
    // Room reserved by `reserveGraphLockSlot` before the lock was taken.
    t_held_graph_locks_overflow.append(graph_lock_overflow_allocator, mg) catch
        @panic("SONNY-6433: no room to record a graph lock that was reserved before it was taken");
}

fn noteGraphLockReleased(mg: *const ManagedGraph) void {
    for (&t_held_graph_locks) |*slot| {
        if (slot.* == mg) {
            slot.* = null;
            return;
        }
    }
    for (t_held_graph_locks_overflow.items, 0..) |held, i| {
        if (held == mg) {
            _ = t_held_graph_locks_overflow.swapRemove(i);
            break;
        }
    }
    if (t_held_graph_locks_overflow.items.len == 0 and t_held_graph_locks_overflow.capacity != 0)
        t_held_graph_locks_overflow.clearAndFree(graph_lock_overflow_allocator);
}

/// SONNY-6375: does this thread hold `mg.rwlock` (SHARED or EXCLUSIVE) through
/// the graph-lock API? See `t_held_graph_locks`.
pub fn threadHoldsGraphLock(mg: *const ManagedGraph) bool {
    for (t_held_graph_locks) |held| {
        if (held == mg) return true;
    }
    for (t_held_graph_locks_overflow.items) |held| {
        if (held == mg) return true;
    }
    return false;
}

/// SONNY-6375 test seam (test builds only): runs on the scanning thread
/// between two batches of one `orderedScan`, when it holds no graph or shard
/// lock — the window a concurrent write or ordered-index rebuild can use.
pub const OrderedScanBatchHook = struct { ctx: *anyopaque, run: *const fn (*anyopaque) void };
pub threadlocal var test_ordered_scan_between_batches: ?OrderedScanBatchHook = null;

/// Refill shard `i`'s batch with at least one live head, or mark the shard
/// exhausted. A batch whose visited entries were all deleted nodes comes back
/// empty; an empty, non-exhausted shard would otherwise drop out of the merge.
fn orderedScanRefill(
    mg: *ManagedGraph,
    i: usize,
    label_id: gs.LabelId,
    key: []const u8,
    dir: OrderedDir,
    st: *OrderedShardState,
    holds_graph_lock: bool,
    allocator: Allocator,
    io: std.Io,
) !void {
    while (true) {
        try orderedScanBatch(mg, i, label_id, key, dir, st, holds_graph_lock, allocator, io);
        if (st.buf.items.len > 0 or st.exhausted) return;
    }
}

/// Read shard `i`'s next BOUNDED batch of its ordered tree for `(label_id,
/// key)`, copying the (key, node_id) of every live node out into owned
/// buffers, then release the locks.
///
/// -- LOCK SAFETY (SONNY-6375) --
///   graph_storage's `OrderedBTree` has no internal locking, and
///   `openOrderedCursor` documents that the cursor borrows the live tree, which
///   must not be mutated while it is iterated. Its writers are:
///   * the online label/delete hooks (`addLabel`, `removeLabel`, `deleteNode`),
///     run by write statements under `mg.rwlock` EXCLUSIVE and by the bulk
///     paths under `mg.rwlock` SHARED + this shard's `shard_locks[i]`
///     EXCLUSIVE;
///   * the rebuilds (`clearTrees` + rescan, which FREES the tree nodes):
///     `createOrderedIndex` (`mg.rwlock` SHARED + `shard_locks[i]` EXCLUSIVE)
///     and the full checkpoint / close (`mg.rwlock` EXCLUSIVE).
///   So each batch holds `mg.rwlock` SHARED and then `shard_locks[i]` SHARED
///   (tier 1, rwlock before shard lock, the order `createOrderedIndex` uses),
///   which excludes all of them. When this thread already holds `mg.rwlock`
///   (`holds_graph_lock`: a point-read / fallback read under SHARED, or a read
///   statement of a write program under EXCLUSIVE) it is not taken again —
///   `std.Io.RwLock` is not reentrant — and the exclusive-waiting back-off is
///   skipped (a waiting writer cannot get in while this thread holds the lock).
///   * Both locks are released after at most `ordered_scan_batch_slots`
///     visited entries, so a queued EXCLUSIVE checkpoint/apply wins before the
///     next batch; `exclusiveWaitingBackoff(mg)` parks BEFORE each acquire so a
///     waiting EXCLUSIVE drains the reader set first.
///   * NO cursor survives a release: a rebuild in the gap frees the nodes a
///     held cursor points into. Each batch opens a fresh cursor and re-seeks
///     strictly past `st.resume_key` (keys are unique: the ordered encoding
///     embeds node_id). A mutation in the gap can still give a torn read (a
///     valid prefix of a consistent order), never a use-after-free.
///   * The liveness check (`getNode`) of each visited node runs under the same
///     hold; the ordered tree keeps deleted-but-still-posted nodes.
fn orderedScanBatch(
    mg: *ManagedGraph,
    i: usize,
    label_id: gs.LabelId,
    key: []const u8,
    dir: OrderedDir,
    st: *OrderedShardState,
    holds_graph_lock: bool,
    allocator: Allocator,
    io: std.Io,
) !void {
    if (st.exhausted) return;

    // Drop the previous batch's owned key copies before refilling.
    for (st.buf.items) |h| allocator.free(h.key);
    st.buf.clearRetainingCapacity();
    st.pos = 0;

    if (!holds_graph_lock) {
        exclusiveWaitingBackoff(mg);
        mg.rwlock.lockSharedUncancelable(io);
    }
    defer if (!holds_graph_lock) mg.rwlock.unlockShared(io);
    // SONNY-6433: dropped between two batches (the scan's pin keeps it
    // allocated; its engine is closed), as `lockedUnlessDropped` answers.
    if (mg.isDropped()) return error.GraphNotFound;
    mg.shard_locks[i].lockSharedUncancelable(io);
    defer mg.shard_locks[i].unlockShared(io);

    // Null => no ordered index registered on this shard.
    var cursor = mg.engine.shards[i].openOrderedCursor(label_id, key, dir) orelse {
        st.exhausted = true;
        return;
    };
    if (st.resume_key) |rk| {
        // Park at the first key >= rk; DESC then steps backward from there,
        // or from the last key when every key is < rk.
        cursor.inner.seek(rk);
        if (dir == .desc and cursor.inner.leaf == null) cursor.inner.seekToLast();
    }

    var last_visited: ?[]const u8 = null;
    var visited: usize = 0;
    while (visited < ordered_scan_batch_slots) {
        const e = cursor.next() orelse {
            st.exhausted = true;
            break;
        };
        if (st.resume_key) |rk| {
            const ord = std.mem.order(u8, e.key, rk);
            const already_visited = switch (dir) {
                .asc => ord != .gt,
                .desc => ord != .lt,
            };
            if (already_visited) continue;
        }
        visited += 1;
        last_visited = e.key;
        if ((try mg.engine.getNode(e.node_id)) == null) continue;
        const kc = try allocator.dupe(u8, e.key);
        st.buf.append(allocator, .{ .key = kc, .node_id = e.node_id }) catch |err| {
            allocator.free(kc);
            return err;
        };
    }
    if (last_visited) |lk| {
        const owned = try allocator.dupe(u8, lk);
        if (st.resume_key) |old| allocator.free(old);
        st.resume_key = owned;
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
    // GAP-0064 FIX C: dedup set for in-flight BACKGROUND value-ordered index
    // builds, keyed by "graph\x00label\x00key" (owned). Guards against spawning a
    // second build for the same (graph,label,key) while one is already running
    // (the planner re-triggers on every ORDER BY until the index is registered).
    // Guarded by `exact_persist_mutex` (the same lock that gates spawn lifecycle);
    // the worker removes+frees its key on completion, deinit frees any remainder.
    ordered_build_inflight: std.StringHashMapUnmanaged(void) = .{},
    /// GAP-0064 (adversarial review — shutdown-stall fix): cancel source for any
    /// in-flight BACKGROUND index build. `deinit` sets it BEFORE joining
    /// `exact_persist_threads`, so a graceful shutdown shortly after a large
    /// `.absent` reopen aborts the ~14-min uncancellable O(graph) build at its
    /// next 256-node poll (`rebuildExactNodePropertyIndex` polls
    /// `CancelFlags.streamTripped`) instead of blocking teardown for the whole
    /// build. Wired to the worker's rebuild as the STREAM cancel flag. A cancelled
    /// build leaves the index deferred (built stays false) → the next reopen
    /// rebuilds cleanly; nothing partial is ever served (accessors gate on built).
    ///
    /// GAP-0064 INTEGRATION: the ORDER-BY ordered-index auto-build worker REUSES
    /// `exact_persist_threads`, so it too honors this flag — `createOrderedIndex`
    /// polls it between shards (see there) and aborts the multi-minute 16-shard
    /// ordered rebuild at a shard boundary, keeping the `deinit` join bounded
    /// instead of re-introducing the uncancellable shutdown stall for ORDER BY.
    exact_build_shutdown_cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

        // CANARY: REQ=REQ-SONNY-6430-REGISTRY-FAIL-CLOSED; FEATURE="Storage Adapter"; ASPECT=UnloadableRegistryRefuses; STATUS=TESTED; TEST=tests/test_sonny6430_storage_open_fail_closed.zig; OWNER=storage; UPDATED=2026-11-12
        // SONNY-6430: a registry that exists but cannot be loaded is an
        // error. It was a warning, and the adapter started with no graphs.
        self.loadRegistry() catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                // The caller reports the refusal (the server exits with it).
                log.warn("cannot load the graph registry {s}: {}; refusing to open the data directory without its graphs", .{ self.registry_path, err });
                return err;
            },
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
        // H4 persist-on-build + GAP-0064 reopen rebuild: join in-flight background
        // workers BEFORE any teardown — they take `self.mutex` and read the engines
        // map, so joining after the lock below would deadlock and joining after
        // teardown would be a use-after-free. New spawns are refused from here on
        // (`exact_persist_shutdown`).
        //
        // GAP-0064 (adversarial review — shutdown-stall fix): FIX A now spawns the
        // UNCANCELLABLE O(graph) reopen rebuild for every `.absent` graph, so a
        // graceful shutdown shortly after a large reopen would otherwise block this
        // join for the full ~14-min build. Set `exact_build_shutdown_cancel` FIRST
        // so the in-flight rebuild aborts at its next 256-node poll → the join is
        // bounded (the persist-after-build workers remain bounded graph checkpoints).
        {
            const io_h4 = std.Io.Threaded.global_single_threaded.io();
            self.exact_build_shutdown_cancel.store(true, .release);
            self.exact_persist_mutex.lockUncancelable(io_h4);
            self.exact_persist_shutdown = true;
            var persist_threads = self.exact_persist_threads;
            self.exact_persist_threads = .empty;
            self.exact_persist_mutex.unlock(io_h4);
            for (persist_threads.items) |t| t.join();
            persist_threads.deinit(self.allocator);
        }
        // GAP-0064 FIX C: workers are joined; free any leftover in-flight keys.
        self.freeOrderedBuildInflight();
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());

        var it = self.engines.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator, false);
        }
        self.engines.deinit();
        self.default_engine = null;

        self.registry.deinit();
        self.allocator.free(self.registry_path);
        self.allocator.free(self.data_dir);
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.allocator.destroy(self);
    }

    /// GAP-0064 FIX C: free every key still in `ordered_build_inflight` and empty
    /// the map. Called from teardown AFTER all build workers are joined (so no
    /// worker can concurrently touch the map).
    fn freeOrderedBuildInflight(self: *StorageAdapter) void {
        var oit = self.ordered_build_inflight.keyIterator();
        while (oit.next()) |k| self.allocator.free(k.*);
        self.ordered_build_inflight.deinit(self.allocator);
        self.ordered_build_inflight = .{};
    }

    /// TEST-ONLY: tear the adapter down as if the process was kill-9'd — each
    /// engine is `deinit()`'d (memory-only, NO final checkpoint) instead of
    /// `close()`'d, so committed-but-uncheckpointed writes stay in the durable
    /// WAL as a committed TAIL for the next open's recovery to replay. Frees all
    /// adapter memory exactly like `deinit` (so `testing.allocator` sees no leak)
    /// while deliberately NOT absorbing the tail. Reopening the same data dir
    /// then exercises the crash-reopen `prop_exact.idx` reconcile path.
    pub fn simulateCrashForTesting(self: *StorageAdapter) void {
        {
            const io_h4 = std.Io.Threaded.global_single_threaded.io();
            // GAP-0064 INTEGRATION: mirror `deinit` — cancel any in-flight
            // exact-index / ordered-index build FIRST so the join below is bounded
            // even when a crash-sim test tears down mid-build.
            self.exact_build_shutdown_cancel.store(true, .release);
            self.exact_persist_mutex.lockUncancelable(io_h4);
            self.exact_persist_shutdown = true;
            var persist_threads = self.exact_persist_threads;
            self.exact_persist_threads = .empty;
            self.exact_persist_mutex.unlock(io_h4);
            for (persist_threads.items) |t| t.join();
            persist_threads.deinit(self.allocator);
        }
        self.freeOrderedBuildInflight();
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());

        var it = self.engines.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(self.allocator, true); // crash teardown
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

    // CANARY: REQ=REQ-SONNY-3028-DROP-GRAPH-PINS; FEATURE="MultiGraphIsolation"; ASPECT=DropGraph; STATUS=TESTED; TEST=tests/test_sonny3028_drop_graph_in_use.zig; OWNER=storage; UPDATED=2026-09-27
    /// Close and remove the graph identified by `name`.
    ///
    /// SONNY-3028: the graph leaves `engines` and the registry now, and is
    /// freed when no thread holds it (`ManagedGraph.pins`): at once, or by the
    /// last of its lock's holders and waiters, its group-commit batch or its
    /// checkpoint to let go. A waiter that gets the lock of a dropped graph
    /// lets it go (`GraphNotFound`). It was freed under them. `ObjectInUse`
    /// when this thread has an engine transaction open on it (a program that
    /// changed the graph in its transaction, then drops it): the graph stays.
    ///
    /// SONNY-3132: the default graph is refused (`CannotDropDefaultGraph`),
    /// whoever calls. `GraphStore.dropGraph` checked for it only after this
    /// drop had deleted the default graph's engine and files.
    pub fn dropGraph(self: *StorageAdapter, name: []const u8) error{ ObjectInUse, CannotDropDefaultGraph }!void {
        // CANARY: REQ=REQ-SONNY-3132-DROP-DEFAULT-GRAPH; FEATURE="MultiGraphIsolation"; ASPECT=AdapterRefusesDefault; STATUS=TESTED; TEST=tests/test_sonny3132_drop_default_graph.zig; OWNER=storage; UPDATED=2026-09-27
        if (std.mem.eql(u8, name, graph_store.DEFAULT_GRAPH_NAME)) return error.CannotDropDefaultGraph;
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (self.engines.get(name)) |mg| {
            if (threadTxnOn(mg)) return error.ObjectInUse;
        }

        var dropped_uuid: ?[16]u8 = null;
        if (self.engines.fetchRemove(name)) |kv| {
            const mg = kv.value;

            // Clear default_engine if it pointed to the dropped graph.
            if (self.default_engine == mg) {
                self.default_engine = null;
            }

            dropped_uuid = mg.uuid;
            // SONNY-3028: pinned graphs are freed by their last unpin.
            const prev = mg.pins.fetchOr(ManagedGraph.dropped_bit, .acq_rel);
            if (prev == 0) mg.deinit(self.allocator, false);
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
        // CANARY: REQ=REQ-SONNY-6425-CREATE-ONE-SHARD; FEATURE="StatementTxnBatching"; ASPECT=AllocOnStatementShard; STATUS=TESTED; TEST=tests/test_sonny6425_create_one_shard_commit.zig; OWNER=storage; UPDATED=2026-11-12
        // SONNY-6425: with a statement txn open on this graph, the node is
        // allocated on that txn's shard, so its record, labels and
        // properties join the statement's one commit. `allocNode` and
        // `beginTxn` pick their shard round-robin from the SAME counter, so
        // the node always landed on another shard and committed in its own
        // transactions (3-6 commits, each a WAL fsync, for a one-node CREATE).
        const stmt_txn = currentStatementTxnForGraph(graph_name);
        const node_id = if (stmt_txn) |s|
            try mg.engine.shards[shardedTxnShard(s.txn_id)].allocNode()
        else
            try mg.engine.allocNode();
        const node_shard = mg.shardEngineForNode(node_id);

        // R7/R8 (2026-04-22): batch putNode + addLabel into a single per-shard
        // txn.  Under ShardedGraphEngine, each txn is pinned to one shard; we
        // always route to the shard that owns node_id.  If a statement txn is
        // active on this graph AND was opened on the same shard, reuse its
        // local txn (one fsync for the whole statement).  Otherwise open a
        // fresh local txn on node_shard (correct isolation, one fsync per
        // createNode call instead of per sub-op).
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
        try graph_store.refuseIfUniqueFenced(graph_name); // SONNY-2846: under the graph lock (see `uniqueFenced`)
        try graph_store.refuseIfFleConfigured(); // SONNY-6327: before any engine write
        _ = txn_id_opt; // reserved for future extensions; thread-local is source of truth.

        // Statement-atomicity pre-pass. This path SKIPS the undo log by design
        // and creates the in-memory node before `setNodePropertiesBatch` can
        // fail, so a refused property left a PHANTOM row — present in memory,
        // gone after restart. Refuse the whole insert before anything is
        // created.
        // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=BulkInsertPrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
        for (props) |kv| try self.checkPropertyEntryWritable(kv.key, kv.value);

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
        try graph_store.refuseFlaggedNodeId(reserved_id); // SONNY-6362
        // Statement-atomicity pre-pass — see `bulkInsertNode`.
        // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=BulkInsertPrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
        for (props) |kv| try self.checkPropertyEntryWritable(kv.key, kv.value);

        const mg = try self.getOrCreateGraph(graph_name);
        // H4: a live write must never mutate an unbuilt (deferred) exact index.
        // Build it FIRST (before any node/index write below) so this insert's
        // posting lands on top of the fully-rebuilt index. No-op (one atomic
        // load) on a freshly-created or already-built graph — the ingest case.
        try ensureExactNodePropertyIndexBuilt(self, mg);
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
        try graph_store.refuseIfUniqueFenced(graph_name); // SONNY-2846: under the graph lock (see `uniqueFenced`)
        try graph_store.refuseIfFleConfigured(); // SONNY-6327: before any engine write
        const _hold_start = monoNanosNow();
        defer {
            const _hold_ns = monoNanosNow() -| _hold_start;
            _ = mg.rwlock_shared_hold_ns_total.fetchAdd(_hold_ns, .monotonic);
            const _cur_max = mg.rwlock_shared_max_hold_ns_observed.load(.monotonic);
            if (_hold_ns > _cur_max) {
                mg.rwlock_shared_max_hold_ns_observed.store(_hold_ns, .monotonic);
            }
        }

        return self.bulkInsertNodeWithReservedIdGraphLocked(
            mg,
            graph_name,
            reserved_id,
            labels,
            props,
            request_tenant,
        );
    }

    /// ENG-3914 (RC-2): the shard-locked body of
    /// `bulkInsertNodeWithReservedIdForTenant`, factored out so the bulk MERGE
    /// paths can run their probe AND this insert inside ONE continuous
    /// `mg.rwlock` SHARED hold (same wrapper/inner shape as
    /// `bulkInsertEdgeWithIdsShardLockedForTenant` /
    /// `bulkInsertEdgeInnerShardLocked`).
    ///
    /// CONTRACT — the caller MUST already hold `mg.rwlock` SHARED and MUST
    /// have run `ensureExactNodePropertyIndexBuilt` beforehand. `std.Io.RwLock`
    /// is not reentrant and `exclusiveWaitingBackoff` would park this thread
    /// behind a pending exclusive that can never win while the caller's own
    /// SHARED hold is outstanding, so neither may be re-done here.
    fn bulkInsertNodeWithReservedIdGraphLocked(
        self: *StorageAdapter,
        mg: *ManagedGraph,
        graph_name: []const u8,
        reserved_id: u64,
        labels: []const []const u8,
        props: []const PropKV,
        request_tenant: []const u8,
    ) !u64 {
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const io = std.Io.Threaded.global_single_threaded.io();

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
                const new_prop_head = node_shard.putPropertyTxn(rec.prop_head, kv.key, storage_val, local_txn) catch |err|
                    return mapPropertyEntryError(err, kv.key);
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
        try graph_store.refuseIfFleConfigured(); // SONNY-6327: before any engine write
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
        try graph_store.refuseIfFleConfigured(); // SONNY-6327: before any engine write
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
        try graph_store.refuseIfFleConfigured(); // SONNY-6327: before any engine write
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

    /// Task 4 (geode-vectorization-and-reranking A4b §6, review Finding 1):
    /// result of a `bulkMergeNode*` call.  `wrote` distinguishes a genuine
    /// data-changing write (fresh insert, or an on-match `SET` apply) from a
    /// pure hit-with-no-write (an idempotent MERGE re-run against an
    /// already-indexed node with no `ON MATCH SET`/bare-`SET` clause).
    /// Callers that drive live FTS maintenance off this result MUST gate on
    /// `wrote` — the fts-storage engine is append-only, so re-maintaining a
    /// no-write hit double-appends postings for the same doc_id. See
    /// `src/execution/fts_index_ops.zig` (`maintainFulltextOnWrite` doc
    /// comment) and the bulk-MERGE fast path call sites in
    /// `src/server/quic_connection_handler.zig`.
    pub const MergeResult = struct {
        id: u64,
        wrote: bool,
    };

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
    ) !MergeResult {
        // GAP-0891 (RC-1): see bulkInsertNodeWithReservedId.
        const result = try self.bulkMergeNodeWithReservedIdForTenant(
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
        return result;
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
    ) !MergeResult {
        try graph_store.refuseFlaggedNodeId(reserved_id); // SONNY-6362
        // Statement-atomicity pre-pass — see `bulkInsertNode`.
        // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=BulkMergePrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
        try self.checkPropertyEntryWritable(merge_key, merge_value);
        for (on_create_props) |kv| try self.checkPropertyEntryWritable(kv.key, kv.value);

        // GAP-0900 Layer-3 (Fix 2): in lean-index mode the merge key must stay
        // indexed so dedup + edge-endpoint resolution still find this node by
        // its key. Registering is a no-op when lean mode is off. Idempotent.
        graph_store.registerMergeIndexKey(merge_key);

        const mg = try self.getOrCreateGraph(graph_name);
        // ENG-3914 (RC-2): the delegated insert below runs under THIS
        // function's SHARED hold, so its deferred exact-index build has to
        // happen out here — before that hold is taken. Idempotent; a no-op
        // atomic load once built.
        try ensureExactNodePropertyIndexBuilt(self, mg);
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

        // ENG-3914 (RC-2): ONE continuous `rwlock` SHARED hold spanning BOTH
        // the probe and the insert.
        //
        // This span used to be two disjoint SHARED holds (probe here, insert
        // inside the delegated `bulkInsertNodeWithReservedIdForTenant`). The
        // gap between them was a zero-reader instant, which is exactly what
        // the general MERGE path's whole-graph EXCLUSIVE acquire
        // (`acquireGraphWriteLockCancelable`, taken by the connection handler
        // around `executeMerge`) waits for. A general-path writer could
        // therefore land its whole probe→CREATE inside a bulk writer's
        // probe→insert gap and both would mint a node for one merge key: the
        // two implementations shared NO mutual exclusion, because the general
        // path never touches `merge_tuple_locks`.
        //
        // Holding SHARED across the whole span closes it without introducing a
        // new lock-order edge: the acquisition order stays tuple→rwlock, the
        // general path takes only the rwlock, and SHARED still admits every
        // other concurrent bulk writer (distinct keys stay fully parallel;
        // same-key bulk writers remain serialized by the tuple lock above).
        //
        // `lookupMergeCandidate` reads the merge_prop_index under its own leaf
        // mutex; combined with the per-tuple lock this is sufficient — no
        // graph-global exclusive needed.
        exclusiveWaitingBackoff(mg); // GAP-0900 / edge-40001: yield to a pending exclusive (checkpoint or edge schema/MERGE).
        const _t_start = monoNanosNow();
        mg.rwlock.lockSharedUncancelable(io);
        _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
        _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
        defer mg.rwlock.unlockShared(io);
        try graph_store.refuseIfUniqueFenced(graph_name); // SONNY-2846: under the graph lock (see `uniqueFenced`)
        try graph_store.refuseIfFleConfigured(); // SONNY-6327: before any engine write
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

        // SONNY-2976: match only within the request's tenant (see
        // `mergeTenantScope`); a same-key node of another tenant is a miss.
        if (try self.findMergeNode(store, graph_name, label, merge_key, merge_value, mergeTenantScope(request_tenant))) |probe_id| {
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
            // Task 4 review Finding 1: `wrote` is true only when the
            // on-match SET clauses actually ran above. A plain hit with
            // no `apply_on_match` changed nothing — callers must not
            // re-append it into an append-only FTS index.
            return .{ .id = probe_id, .wrote = apply_on_match };
        }

        // Insert phase: delegate to the shard-aligned bulk insert helper —
        // the same create path the multi-property MERGE uses (:2511). The
        // graph-locked variant is required: our SHARED hold is still
        // outstanding and `std.Io.RwLock` is not reentrant.
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
        const new_id = try self.bulkInsertNodeWithReservedIdGraphLocked(
            mg,
            graph_name,
            reserved_id,
            &labels_slice,
            combined_props,
            request_tenant,
        );
        return .{ .id = new_id, .wrote = true };
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
    ) !MergeResult {
        // GAP-0891 (RC-1): see bulkInsertNodeWithReservedId.
        const result = try self.bulkMergeNodeWithReservedIdMultiPropForTenant(
            graph_name,
            reserved_id,
            label,
            merge_props,
            on_create_props,
            apply_on_match,
            fle_integration.tenantPreferringActiveContext(),
        );
        self.maybeCheckpointInline(); // GAP-0900: locks released; safe to checkpoint.
        return result;
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
    ) !MergeResult {
        if (merge_props.len == 0) return error.InvalidMergePattern;
        try graph_store.refuseFlaggedNodeId(reserved_id); // SONNY-6362

        // Statement-atomicity pre-pass — see `bulkInsertNode`.
        // CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=BulkMergePrePass; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
        for (merge_props) |kv| try self.checkPropertyEntryWritable(kv.key, kv.value);
        for (on_create_props) |kv| try self.checkPropertyEntryWritable(kv.key, kv.value);

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
        // ENG-3914 (RC-2): see the single-property path — the delegated insert
        // now runs inside this function's SHARED hold, so the deferred
        // exact-index build must happen before that hold is taken.
        try ensureExactNodePropertyIndexBuilt(self, mg);
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

        // ENG-3914 (RC-2): ONE continuous `rwlock` SHARED hold spanning BOTH
        // the probe and the insert — see the single-property path for the full
        // interleave this closes. The probe→insert gap used to be a zero-reader
        // instant in which the general MERGE path (`executeMerge` under the
        // connection handler's whole-graph EXCLUSIVE) could complete an entire
        // probe→CREATE for the SAME merge key, duplicating the node.
        exclusiveWaitingBackoff(mg); // GAP-0900 / edge-40001: yield to a pending exclusive (checkpoint or edge schema/MERGE).
        const _t_start = monoNanosNow();
        mg.rwlock.lockSharedUncancelable(io);
        _ = mg.rwlock_shared_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
        _ = mg.rwlock_shared_acquired_total.fetchAdd(1, .monotonic);
        defer mg.rwlock.unlockShared(io);
        try graph_store.refuseIfUniqueFenced(graph_name); // SONNY-2846: under the graph lock (see `uniqueFenced`)
        try graph_store.refuseIfFleConfigured(); // SONNY-6327: before any engine write
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

        // SONNY-2976: match only within the request's tenant.
        const existing_id = try findNodeMatchingMergeProps(self, self.allocator, mg, store, graph_name, label, merge_props, mergeTenantScope(request_tenant));
        if (existing_id) |existing| {
            // GAP-0900 coalesce-upsert: apply the SET props to the existing
            // node on the match branch, mirroring the single-key path
            // (~:2381). Done under the same shared-rwlock + per-tuple-lock
            // critical section as the probe so a concurrent same-key writer
            // is serialized. The merge keys themselves are re-asserted (they
            // already hold the matched values); on_create_props that name a
            // merge key are skipped to avoid clobbering the index tuple.
            if (apply_on_match) {
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
            // Task 4 review Finding 1: this is the multi-property MERGE hit
            // branch that previously had NO wrote signal at all — the handler
            // set `fts_should_maintain = true` unconditionally for every
            // `merge_kvs.len > 1` call, double-appending FTS postings on every
            // idempotent re-MERGE. `wrote` is true only when the on-match SET
            // clauses actually ran above (`apply_on_match`); a plain
            // `ON CREATE SET`-only hit changed nothing.
            return .{ .id = existing, .wrote = apply_on_match };
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

        // Graph-locked variant: our SHARED hold is still outstanding and
        // `std.Io.RwLock` is not reentrant.
        const labels_slice = [_][]const u8{label};
        const new_id = try self.bulkInsertNodeWithReservedIdGraphLocked(
            mg,
            graph_name,
            reserved_id,
            &labels_slice,
            combined_props,
            request_tenant,
        );
        return .{ .id = new_id, .wrote = true };
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
    ///   * `error.SourceNodeNotFound` — no node holds (src_label,
    ///     src_filter_key=value) (the executor's MATCH has no row).
    ///   * `error.TargetNodeNotFound` — symmetric.
    ///   * `error.MergeKeyNotUnique` — an endpoint key more nodes may hold,
    ///     or one MERGE's index cannot answer for (a value it cannot hold, or,
    ///     SONNY-6436, a key lean indexing left out of it): nothing is
    ///     written, and the caller falls back to the executor. Endpoints are
    ///     resolved as the MATCH ... CREATE edge fast path resolves them
    ///     (`lookupSoleNodeByMergeKey`); an unindexable key was answered as
    ///     no holder, and the edge skipped.
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
        try graph_store.refuseIfFleConfigured(); // SONNY-6327: before any engine write
        _ = txn_id_opt; // thread-local statement-txn slots are source of truth.

        const store = graph_store.getGlobalStore(graph_store.global_allocator());

        // Endpoint resolution — both lookups MUST succeed for a fast-path
        // edge. SONNY-6436: a key MERGE's index cannot answer for declines
        // (`error.MergeKeyNotUnique`); it was answered as "not found".
        const src_id = try self.lookupSoleNodeByMergeKey(graph_name, src_label, src_filter_key, src_node_id, error.SourceNodeNotFound);
        const dst_id = try self.lookupSoleNodeByMergeKey(graph_name, dst_label, dst_filter_key, dst_node_id, error.TargetNodeNotFound);

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
    /// It reads the graph, and is safe to call under `acquireGraphReadLock`
    /// (see Phase 4 invariants in
    /// `docs/performance/2026-04-23-enterprise-ingest/phase4-invariants.md`).
    /// It is not a pure read of MERGE's index: SONNY-2806 (round 7) made
    /// `lookupMergeCandidate` settle an entry it cannot trust (unresolved,
    /// or naming a deleted node) by finding the key's holders and writing
    /// the entry. Writers run beside it under the same SHARED lock, so the
    /// settle writes only if nothing wrote the index shard since the lookup
    /// read the entry (round 8, `MergePropertyIndex.settle`); a holder
    /// inserted meanwhile keeps its entry.
    ///
    /// SONNY-6436: when MERGE's index cannot answer (`.not_indexable`: a
    /// value it cannot hold, or a key lean indexing left out of it), this is
    /// `error.MergeKeyNotUnique`, never `missing_err`: the index cannot know
    /// that no node holds the key, and the caller falls back to the executor.
    /// (It was `missing_err`, so the bulk edge path skipped the edge.)
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
            .not_found => return missing_err,
            .not_indexable => return error.MergeKeyNotUnique,
        }
    }

    // CANARY: REQ=REQ-SONNY-3241-FAST-PATH-PARITY; FEATURE="WriteFastPathParity"; ASPECT=SoleHolderEndpoint; STATUS=TESTED; TEST=tests/test_sonny3241_fast_path_parity_wire.zig; OWNER=storage; UPDATED=2026-11-12
    /// SONNY-3241: `lookupNodeByMergeKey` for the MATCH ... CREATE edge fast
    /// path, which writes ONE edge: the node holding the key when it is the
    /// key's only holder; `missing_err` when no node holds it (the executor's
    /// MATCH has no row, and creates nothing); `error.MergeKeyNotUnique` when
    /// more nodes may hold it, or MERGE's index cannot hold the value (a
    /// non-integer number, an over-long key, or, SONNY-6429, a key lean
    /// indexing leaves out of it). The executor creates an edge
    /// per matched pair, and finds a value the index cannot hold by a scan,
    /// so the caller declines to it. (The lowest holder was taken as the
    /// only one, and an unindexable value as none.)
    pub fn lookupSoleNodeByMergeKey(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        prop_key: []const u8,
        prop_value: graph_store.PropertyValue,
        missing_err: anyerror,
    ) !u64 {
        _ = self;
        // SONNY-6429: a key lean indexing leaves out of MERGE's index (no
        // MERGE registered it) has no entry whoever holds it; the probe
        // below would answer that as no holder, and the edge was skipped
        // where the executor makes it.
        if (!graph_store.shouldIndexProperty(prop_key)) return error.MergeKeyNotUnique;
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        var id: u64 = undefined;
        // Settles an entry left unresolved by a removed holder first.
        switch (store.lookupMergeCandidate(graph_name, label, prop_key, prop_value, &id)) {
            .found => {},
            .not_found => return missing_err,
            .not_indexable => return error.MergeKeyNotUnique,
        }
        return switch (store.lookupOnlyMergeHolder(graph_name, label, prop_key, prop_value, &id)) {
            .found => id,
            .not_found => missing_err,
            .not_indexable => error.MergeKeyNotUnique,
        };
    }

    /// SONNY-2976: `lookupNodeByMergeKey` for a request of `request_tenant`
    /// (the tag its writes carry): only a node of that tenant answers, unless
    /// the request is unscoped (`mergeTenantScope`). The bulk MERGE's phase-1
    /// probe and the bulk edge paths' endpoint resolution use it, so a key
    /// held only by another tenant's node is a miss. SONNY-6436: an index
    /// that cannot answer is `error.MergeKeyNotUnique`, as for
    /// `lookupNodeByMergeKey`.
    pub fn lookupNodeByMergeKeyForTenant(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        prop_key: []const u8,
        prop_value: graph_store.PropertyValue,
        request_tenant: []const u8,
        missing_err: anyerror,
    ) !u64 {
        _ = self;
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        var id: u64 = undefined;
        switch (store.lookupMergeCandidateForTenant(graph_name, label, prop_key, prop_value, mergeTenantScope(request_tenant), &id)) {
            .found => return id,
            .not_found => return missing_err,
            .not_indexable => return error.MergeKeyNotUnique,
        }
    }

    // CANARY: REQ=REQ-SONNY-3241-FAST-PATH-PARITY; FEATURE="WriteFastPathParity"; ASPECT=SoleHolderEndpointTenantScope; STATUS=TESTED; TEST=tests/test_sonny3241_fast_path_parity_wire.zig; OWNER=storage; UPDATED=2026-11-12
    /// SONNY-3241 with SONNY-2976: `lookupSoleNodeByMergeKey` for a request
    /// of `request_tenant` (the tag its writes carry), for the MATCH ...
    /// CREATE edge fast path's endpoints. An unscoped request
    /// (`mergeTenantScope`) is answered as `lookupSoleNodeByMergeKey`
    /// answers. A scoped one: the node of that tenant holding the key when it
    /// is that tenant's only holder; `missing_err` when none of its nodes
    /// holds it (another tenant's node is a miss);
    /// `error.MergeKeyNotUnique` when more of its nodes may hold it, or the
    /// holders could not all be read (the caller declines to the executor).
    pub fn lookupSoleNodeByMergeKeyForTenant(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        prop_key: []const u8,
        prop_value: graph_store.PropertyValue,
        request_tenant: []const u8,
        missing_err: anyerror,
    ) !u64 {
        const scope = mergeTenantScope(request_tenant) orelse
            return self.lookupSoleNodeByMergeKey(graph_name, label, prop_key, prop_value, missing_err);
        if (!graph_store.shouldIndexProperty(prop_key)) return error.MergeKeyNotUnique; // SONNY-6429, as above
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        var id: u64 = undefined;
        // Settles an entry left unresolved by a removed holder first.
        switch (store.lookupMergeCandidate(graph_name, label, prop_key, prop_value, &id)) {
            .found => {},
            .not_found => return missing_err,
            .not_indexable => return error.MergeKeyNotUnique,
        }
        return switch (store.lookupOnlyMergeHolderForTenant(graph_name, label, prop_key, prop_value, scope, &id)) {
            .found => id,
            .not_found => missing_err,
            .not_indexable => error.MergeKeyNotUnique,
        };
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
        try graph_store.refuseIfFleConfigured(); // SONNY-6327: before any engine write
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

    // CANARY: REQ=REQ-SONNY-2806-MERGE-EQUAL-HOLDERS; FEATURE="MergeIdempotency"; ASPECT=BulkMergeResolution; STATUS=TESTED; TEST=tests/test_sonny2806_merge_equal_holders.zig; OWNER=storage; UPDATED=2026-09-27
    /// The node a single-property MERGE matches, as the executor finds it:
    /// the LOWEST node id among the nodes of `label` whose `key` equals
    /// `value`, or null.
    ///
    /// MERGE's property index (graph_store) answers an integer, a string or
    /// a boolean. SONNY-2806 (round 7): it keeps no other number, so a
    /// DOUBLE or DECIMAL key such as 1.5 is resolved by value
    /// (`GraphStore.lowestMergeHolderByValue`; the executor scans the label).
    /// Such a key failed the server's MERGE with MergeValueNotIndexable
    /// before round 6, and was indexed at the cost of one entry per such
    /// property per node in round 6.
    ///
    /// Round 8: that search reads the exact node-property index only when
    /// the index can answer, and otherwise scans the label: in lean mode
    /// (GEODE_INDEX_MERGE_KEYS_ONLY) the index holds no value of a key
    /// registered after its nodes were written, so `CREATE (:T {x: 1.5})`
    /// then the first bulk `MERGE (:T {x: 1.5})` created a second node; and
    /// while the index is deferred or rebuilding, the search does not build
    /// it under the caller's graph lock.
    ///
    /// SONNY-2976: `tenant` (from `mergeTenantScope`) confines the match to
    /// the nodes tagged with it, as the executor's MERGE confines it to the
    /// session's tenant; null matches in every tenant (an unscoped request).
    fn findMergeNode(
        self: *StorageAdapter,
        store: *graph_store.GraphStore,
        graph_name: []const u8,
        label: []const u8,
        key: []const u8,
        value: graph_store.PropertyValue,
        tenant: ?[]const u8,
    ) !?u64 {
        _ = self;
        var id: u64 = 0;
        switch (store.lookupMergeCandidateForTenant(graph_name, label, key, value, tenant, &id)) {
            .found => return id,
            .not_found => return null,
            // Any other value the index cannot key (a null, a list, a key
            // past 1024 bytes) is refused, as before.
            .not_indexable => if (!graph_store.GraphStore.isNumberProperty(value)) return error.MergeValueNotIndexable,
        }
        return store.lowestMergeHolderByValueForTenant(graph_name, label, key, value, tenant);
    }

    // CANARY: REQ=REQ-SONNY-2806-MERGE-RESOLVE-EXACT; FEATURE="MergeIdempotency"; ASPECT=ExactIndexCandidates; STATUS=TESTED; TEST=tests/test_sonny2806_merge_resolve.zig; OWNER=storage; UPDATED=2026-09-27
    /// SONNY-2806 (round 8): for MERGE's index to find the holders of a key
    /// in O(holders) (`GraphStore.findMergeHolders`): the public ids of the
    /// nodes of `label` in `graph_name` that the exact node-property index
    /// lists under the value of one of `props` (the smallest posting). The
    /// index keys a value by its hash, so the caller checks each node. Null
    /// when the index cannot answer, and the caller scans the label instead:
    ///   * lean mode (GEODE_INDEX_MERGE_KEYS_ONLY): the index holds no value
    ///     of a key registered after its nodes were written;
    ///   * the index is deferred or being rebuilt (`exact_index_built`).
    ///     This never builds it or waits for it: the caller holds the graph
    ///     lock, and the build can run for minutes (about 14 at 14M nodes);
    ///   * no such graph.
    pub fn exactIndexMergeCandidates(
        self: *StorageAdapter,
        store: *graph_store.GraphStore,
        allocator: Allocator,
        graph_name: []const u8,
        label: []const u8,
        props: []const PropKV,
    ) !?[]u64 {
        if (graph_store.leanIndexingEnabled()) return null;
        const io = std.Io.Threaded.global_single_threaded.io();
        const mg = blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            break :blk self.requireExistingGraphLocked(graph_name) catch |err| switch (err) {
                error.GraphNotFound => return null,
                else => return err,
            };
        };
        if (!mg.exact_index_built.load(.acquire)) return null;
        const slots = try copySmallestExactCandidates(allocator, mg, label, props);
        defer allocator.free(slots);
        const id_map = blk: {
            mg.string_indexes_mutex.lockUncancelable(io);
            defer mg.string_indexes_mutex.unlock(io);
            break :blk store.getIdMap(graph_name);
        } orelse return try allocator.alloc(u64, 0);
        var ids: std.ArrayList(u64) = .empty;
        errdefer ids.deinit(allocator);
        try ids.ensureTotalCapacity(allocator, slots.len);
        for (slots) |slot_id| {
            const public_id = id_map.nodeUuid(slot_id) orelse continue;
            ids.appendAssumeCapacity(@truncate(public_id));
        }
        return try ids.toOwnedSlice(allocator);
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
    ) !MergeResult {
        try graph_store.refuseIfUniqueFenced(graph_name); // SONNY-2846: under the graph lock (see `uniqueFenced`)
        try graph_store.refuseIfFleConfigured(); // SONNY-6327: before any engine write
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
        // GAP-0891 (RC-1) / SONNY-2976: the request's tenant, resolved on this
        // (handler) thread: the tag a created node carries and the scope a
        // match is confined to.
        const request_tenant = fle_integration.tenantPreferringActiveContext();
        const tenant_scope = mergeTenantScope(request_tenant);

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
        if (!apply_on_match) {
            // Task 4 review Finding 1: this early return only runs when
            // `!apply_on_match`, so it is always a pure hit with no write.
            if (try self.findMergeNode(store, graph_name, label, merge_key, merge_value, tenant_scope)) |existing_id| {
                return .{ .id = existing_id, .wrote = false };
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
        if (try self.findMergeNode(store, graph_name, label, merge_key, merge_value, tenant_scope)) |existing_id| {
            if (apply_on_match) {
                try store.setNodeProperty(existing_id, merge_key, merge_value);
                for (on_create_props) |kv| {
                    if (std.mem.eql(u8, kv.key, merge_key)) continue;
                    try store.setNodeProperty(existing_id, kv.key, kv.value);
                }
                if (stmt_txn_open) try stmt_txn.commit();
                return .{ .id = existing_id, .wrote = true };
            }
            if (stmt_txn_open) stmt_txn.abort();
            // Task 4 review Finding 1: a concurrent writer won the race
            // between our Phase-1 miss and this re-probe — still a pure
            // hit with no write from THIS call's perspective.
            return .{ .id = existing_id, .wrote = false };
        }

        const labels = [_][]const u8{label};
        // GAP-0891 (RC-1): bulkMergeNode runs inline on the request/handler
        // thread (the GEODE_GROUP_COMMIT=off path), so the active
        // ExecutionContext / per-thread tenant is valid here — resolve it
        // explicitly and tag the merged node with it (instead of relying on the
        // implicit resolution inside createNodeWithGraph).
        const node_id = try store.createNodeForRequestTenant(&labels, graph_name, request_tenant);

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
        return .{ .id = node_id, .wrote = true };
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
                // SONNY-2463: room first, so a failed append cannot drop the
                // copy.
                try result.ensureUnusedCapacity(allocator, 1);
                result.appendAssumeCapacity(try allocator.dupe(u8, name));
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

    /// The per-value sanity cap that applies to every graph this adapter
    /// serves. `openGraphLocked` / `createGraphLocked` hand `self.config`
    /// straight to the engine (only `data_dir` / `sync_mode` are adjusted), and
    /// `engine_persist` installs `cfg.max_property_value_bytes` on the shard's
    /// prop-store, so this is the live cap without needing a graph lookup or
    /// the adapter mutex on a write-path pre-pass.
    pub fn maxPropertyValueBytes(self: *StorageAdapter) u32 {
        return self.config.max_property_value_bytes;
    }

    /// Statement-atomicity pre-pass over ONE geode-level property entry: refuse
    /// an entry the storage layer would refuse, BEFORE the statement's first
    /// store mutation. See `checkPropertyEntryFits`.
    ///
    /// CANARY: REQ=REQ-PROPERTY-WRITE-ATOMICITY; FEATURE="PropertyStorage"; ASPECT=EntryFitsPredicate; STATUS=TESTED; TEST=tests/test_property_write_atomicity.zig; OWNER=engine; UPDATED=2026-08-25
    pub fn checkPropertyEntryWritable(
        self: *StorageAdapter,
        key: []const u8,
        value: graph_store.PropertyValue,
    ) !void {
        if (key.len > MAX_PROPERTY_KEY_BYTES) return error.PropertyKeyTooLong;
        const storage_val = try toStorageProperty(self.allocator, value);
        defer freeTemporaryStorageProperty(self.allocator, storage_val);
        try checkPropertyEntryFits(key, storage_val, self.maxPropertyValueBytes());
    }

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

        const new_prop_head = node_shard.putPropertyTxn(rec.prop_head, key, storage_val, local_txn) catch |err|
            return mapPropertyEntryError(err, key);

        // Update the node record with the (possibly changed) prop_head.
        rec.prop_head = new_prop_head;
        try node_shard.putNodeTxn(node_id, rec, local_txn);

        if (own_txn) try node_shard.commitTxn(local_txn);

        // RC-4: the OLD value's exact-index posting is dropped only once the
        // durable write has SUCCEEDED. Dropping it up-front (as this used to,
        // before `putPropertyTxn`) left DURABLE index/value divergence on ANY
        // failure — the node kept its old value but became invisible to
        // `MATCH (n:L {k: <old>})`, and the divergence survived restart. Every
        // fallible step now precedes both index mutations, so the index can
        // only ever move from "old value" to "new value", never to neither.
        if (old_value) |existing| {
            for (label_ids) |label_id| {
                removeIndexedNodeProperty(mg, label_id, node_id, key, existing);
            }
        }
        for (label_ids) |label_id| {
            try addIndexedNodeProperty(mg, label_id, node_id, key, storage_val);
        }
    }

    /// Batch property entry: a key with either a value to set or null to remove.
    pub const BatchPropertyEntry = struct {
        key: []const u8,
        value: ?graph_store.PropertyValue, // null means remove (tombstone)
    };

    /// RC-4 bookkeeping for `setNodePropertiesBatch`: one deferred exact-index
    /// transition (drop `old_value`'s posting, add `new_value`'s) held back
    /// until the whole batch has committed. Both values are owned by the
    /// pending list and freed with it.
    const PendingIndexUpdate = struct {
        key: []const u8,
        old_value: ?gs.PropertyValue,
        new_value: gs.PropertyValue,
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

        // RC-4: every exact-index mutation of the batch is DEFERRED until the
        // last fallible step has succeeded. The old shape mutated the index
        // per-entry, up-front, so an entry that failed part-way through a batch
        // left the index describing a value the aborted txn never wrote — the
        // node stayed findable only by a value it does not hold, durably and
        // across restart. Nothing here mutates the index until `commitTxn`.
        var pending = std.ArrayList(PendingIndexUpdate).empty;
        defer {
            for (pending.items) |p| {
                if (p.old_value) |val| freeOwnedStorageProperty(self.allocator, val);
                freeTemporaryStorageProperty(self.allocator, p.new_value);
            }
            pending.deinit(self.allocator);
        }

        for (entries) |entry| {
            // Read via the node's shard — see addNodePropertiesForLabels.
            const old_value = if (rec.prop_head != 0) try node_shard.getProperty(rec.prop_head, entry.key, self.allocator) else null;
            errdefer if (old_value) |val| freeOwnedStorageProperty(self.allocator, val);

            // A null entry is a tombstone: same write, `.null` as the value.
            const storage_val: gs.PropertyValue = if (entry.value) |val|
                try toStorageProperty(self.allocator, val)
            else
                .null;
            errdefer freeTemporaryStorageProperty(self.allocator, storage_val);

            const new_prop_head = node_shard.putPropertyTxn(rec.prop_head, entry.key, storage_val, local_txn) catch |err|
                return mapPropertyEntryError(err, entry.key);
            rec.prop_head = new_prop_head;

            try pending.append(self.allocator, .{
                .key = entry.key,
                .old_value = old_value,
                .new_value = storage_val,
            });
        }

        // Write the node record once after all property mutations.
        try node_shard.putNodeTxn(node_id, rec, local_txn);
        if (own_txn) try node_shard.commitTxn(local_txn);

        for (pending.items) |p| {
            if (p.old_value) |existing| {
                for (label_ids) |label_id| {
                    removeIndexedNodeProperty(mg, label_id, node_id, p.key, existing);
                }
            }
            for (label_ids) |label_id| {
                try addIndexedNodeProperty(mg, label_id, node_id, p.key, p.new_value);
            }
        }
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

        // RC-4: drop the old posting only once the tombstone is durable —
        // a failure before this point must leave the index describing the
        // value the node still holds.
        if (old_value) |existing| {
            for (label_ids) |label_id| {
                removeIndexedNodeProperty(mg, label_id, node_id, key, existing);
            }
        }
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

        // CANARY: REQ=REQ-GAP-0915-LABEL-INDEX-CRASH-REBUILD; FEATURE="CrashRecovery"; ASPECT=LabelScanHydrationGuard; STATUS=TESTED; TEST=tests/test_gap0910_0915_crash_recovery.zig; OWNER=storage; UPDATED=2026-07-10
        // GAP-0915: the label posting list is deferred-derived — EMPTY after a
        // reopen (and rebuilt from durable pages only on demand). Every reader
        // must run the Phase A guard before consuming it; without this, the
        // first label scan after an UNCLEAN crash returned 0 rows while the
        // row data itself had fully survived. Guard runs BEFORE the shard
        // lock, the same order countNodesByLabel (9a255a83) establishes.
        try shard.ensureDerivedHydrated();

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
                // SONNY-2394 fail-closed: this slot is LISTED in the label
                // posting list and its page is allocated, yet its record is
                // all-zero ("empty"). The engine never zeroes a node record
                // (deleteNode only sets NODE_FLAG_DELETED, handled above), so
                // this is lost/zeroed page data -- e.g. a torn write the pager
                // accepts as a fresh all-zero page (it skips the CRC for a
                // zero header). Skipping it (the old `continue`) silently
                // dropped every node on the page from label scans while
                // count() still reported them.
                //
                // Scope (SONNY-2394 review): this catches the loss only while
                // the label posting list still names the slot, i.e. the label
                // index came from its snapshot. It is NOT a general guarantee:
                // an unlabeled scan, or a label index REBUILT from the node
                // store (engine scanNodes skips empty records), no longer
                // references the lost ids and returns partial rows silently.
                // The root fix -- the pager must not treat a zeroed page below
                // the written high-water mark as fresh -- is SONNY-2409.
                if (node_mod.isEmpty(&rec)) {
                    // warn, not err: the typed error below is the contract the
                    // caller surfaces (std.log.err would also fail every test
                    // that deliberately exercises this path).
                    log.warn("label scan: indexed node record is empty (lost or zeroed page) -- refusing to serve partial results (shard={d} slot={d} page={d})", .{ shard_idx, nid, page_id });
                    return error.DataCorruption;
                }
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
    /// Index-served read: `error.ExactIndexBusy` while a build of the index
    /// is in flight (SONNY-6362 item 6; the caller scans instead).
    pub fn getCandidateNodesByLabelAndProperty(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        property_key: []const u8,
        value: graph_store.PropertyValue,
        allocator: Allocator,
    ) ![]u64 {
        return self.getCandidateNodesImpl(graph_name, label, property_key, value, allocator, false);
    }

    fn getCandidateNodesImpl(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        property_key: []const u8,
        value: graph_store.PropertyValue,
        allocator: Allocator,
        comptime wait_for_build: bool,
    ) ![]u64 {
        _ = g_exact_node_property_lookup_count.fetchAdd(1, .monotonic);

        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // H4: build the exact index on first access if it was deferred at open.
        if (wait_for_build) try ensureExactNodePropertyIndexBuilt(self, mg) else try ensureExactIndexForRead(self, mg);
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

        // Per-shard registration + build-from-live-scan. The engine call MUTATES
        // the shard (registers the pair, rebuilds the tree via a live scan, marks
        // it dirty for the next checkpoint).
        //
        // GAP-0064 INTEGRATION (ordered double-build race — the analog of the
        // exact-index CRITICAL): the FULL checkpoint's OWN ordered rebuild lives
        // INSIDE gs (`engine_persist.checkpointEx` → `rebuildOrderedIndex`, gated
        // only on `ordered_property_index.count() > 0`) and runs under `mg.rwlock`
        // EXCLUSIVE with NO shard lock. This background build (and the explicit
        // `CREATE INDEX` path) previously took ONLY `shard_locks[i]`, so the two
        // `clearTrees()+rescan` paths mutated the SAME per-shard ordered tree under
        // DISJOINT locks → double-build / torn B-tree (identical hazard to the
        // exact-index checkpoint-vs-worker race). Fix: take `mg.rwlock` SHARED (the
        // same discipline `createNode`/`mergeNode` use) so the checkpoint's
        // EXCLUSIVE hold mutually excludes this rebuild; the per-shard
        // `shard_locks[i]` still serializes it against the online write-path
        // ordered-maintenance and any second concurrent builder. Held+released PER
        // SHARD (not across the whole 16-shard scan) so a waiting checkpoint /
        // LIGHT-checkpoint slips in at a shard boundary — bounded hold, no whole-
        // graph read stall, and the rebuild is idempotent so an interleaved
        // checkpoint refresh is harmless.
        //
        // SHUTDOWN-CANCEL (integration with the CRITICAL shutdown-stall fix): the
        // ORDER-BY worker REUSES `exact_persist_threads`, and this O(graph)
        // 16-shard rebuild is otherwise uncancellable — a SIGTERM mid-build would
        // block `deinit`'s join for the full (multi-minute at 14.27M) build,
        // re-introducing exactly the stall the CRITICAL closed for the exact index.
        // Poll `exact_build_shutdown_cancel` at each shard boundary and abort
        // promptly: the partial registration leaves `isOrderedIndexRegistered`
        // false (needs ALL shards), so the next reopen's first ORDER BY simply
        // re-triggers a clean build. Nothing partial is ever served.
        for (mg.engine.shards, 0..) |shard, i| {
            if (self.exact_build_shutdown_cancel.load(.acquire))
                return error.OrderedBuildCancelledByShutdown;
            exclusiveWaitingBackoff(mg); // yield to a pending exclusive (checkpoint / CREATE INDEX).
            mg.rwlock.lockSharedUncancelable(io);
            defer mg.rwlock.unlockShared(io);
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
    /// LOCK DISCIPLINE: see `orderedScanBatch` (SONNY-6375) — bounded batches
    /// per shard, each under `mg.rwlock` SHARED (skipped when this thread
    /// already holds the graph lock) then `shard_locks[i]` SHARED,
    /// `exclusiveWaitingBackoff` before each acquire, keys copied out and the
    /// liveness `getNode` run under that hold, no lock and no cursor kept
    /// between batches.
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

        // SONNY-6433: pinned (SONNY-3028) for the whole scan: its locks are
        // let go between batches, and a DROP GRAPH in that gap freed the
        // graph the next batch read. A batch that finds it dropped fails the
        // scan with GraphNotFound (`orderedScanBatch`).
        const ctx = (try self.pinLabelScanContext(graph_name, label)) orelse
            return try allocator.alloc(u64, 0);
        const mg = ctx.mg;
        defer self.unpinGraph(mg);
        const label_id = ctx.label_id;

        const eng_dir: OrderedDir = switch (dir) {
            .asc => .asc,
            .desc => .desc,
        };

        const shard_count = mg.engine.shards.len;
        var states: [sharded_store.SHARD_COUNT]OrderedShardState =
            [_]OrderedShardState{.{}} ** sharded_store.SHARD_COUNT;

        // Free every copied key buffer, resume key and per-shard batch list on
        // exit (success or error).
        defer {
            for (states[0..shard_count]) |*st| {
                for (st.buf.items) |h| allocator.free(h.key);
                st.buf.deinit(allocator);
                if (st.resume_key) |rk| allocator.free(rk);
            }
        }

        // SONNY-6375: a caller that already holds this graph's lock (SHARED
        // or EXCLUSIVE) on this thread must not take `mg.rwlock` again.
        const holds_graph_lock = threadHoldsGraphLock(mg);

        var result = std.ArrayList(u64).empty;
        errdefer result.deinit(allocator);

        // Prime every shard's cursor + first batch.
        for (states[0..shard_count], 0..) |*st, i| {
            try orderedScanRefill(mg, i, label_id, key, eng_dir, st, holds_graph_lock, allocator, io);
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

            // Batches hold only live heads (deleted-but-still-posted nodes
            // were skipped under the batch's locks).
            try result.append(allocator, states[bi].buf.items[states[bi].pos].node_id);

            states[bi].pos += 1;
            if (states[bi].pos >= states[bi].buf.items.len and !states[bi].exhausted) {
                if (comptime @import("builtin").is_test) {
                    if (test_ordered_scan_between_batches) |h| h.run(h.ctx);
                }
                try orderedScanRefill(mg, bi, label_id, key, eng_dir, &states[bi], holds_graph_lock, allocator, io);
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
        return self.orderedIndexGate(graph_name, label, key, .registered);
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
        return self.orderedIndexGate(graph_name, label, key, .eligible);
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
        return self.orderedIndexGate(graph_name, label, key, .fresh);
    }

    const OrderedIndexGate = enum { registered, eligible, fresh };

    // CANARY: REQ=REQ-SONNY-6433-ORDERED-INDEX-LOCKING; FEATURE="OrderedIndex"; ASPECT=LockedPlannerGates; STATUS=TESTED; TEST=tests/test_sonny6433_ordered_index_locking.zig; OWNER=storage; UPDATED=2026-11-12
    /// SONNY-6433: the three planner gates, ALL shards ANDed. They read each
    /// shard's ordered-index registry, eligibility and freshness, which
    /// `createOrderedIndex` (CREATE INDEX, the ORDER BY auto-build's
    /// background worker) changes under `mg.rwlock` SHARED + `shard_locks[i]`
    /// EXCLUSIVE and the full checkpoint under `mg.rwlock` EXCLUSIVE; they
    /// read it with no lock. Now the graph is pinned, `mg.rwlock` is held
    /// SHARED (unless this thread already holds the graph lock: it is not
    /// reentrant) and each shard is read under `shard_locks[i]` SHARED, the
    /// order `createOrderedIndex` takes them (tier 1: rwlock, then shard).
    /// A dropped graph answers false.
    fn orderedIndexGate(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        key: []const u8,
        comptime gate: OrderedIndexGate,
    ) bool {
        const ctx = (self.pinLabelScanContext(graph_name, label) catch return false) orelse
            return false;
        const mg = ctx.mg;
        defer self.unpinGraph(mg);
        const io = std.Io.Threaded.global_single_threaded.io();
        const holds_graph_lock = threadHoldsGraphLock(mg);
        if (!holds_graph_lock) {
            exclusiveWaitingBackoff(mg);
            mg.rwlock.lockSharedUncancelable(io);
        }
        defer if (!holds_graph_lock) mg.rwlock.unlockShared(io);
        if (mg.isDropped()) return false;
        for (mg.engine.shards, 0..) |shard, i| {
            mg.shard_locks[i].lockSharedUncancelable(io);
            defer mg.shard_locks[i].unlockShared(io);
            const ok = switch (gate) {
                .registered => shard.hasOrderedIndex(ctx.label_id, key),
                .eligible => shard.hasOrderedIndex(ctx.label_id, key) and shard.isOrderedIndexEligible(ctx.label_id, key),
                .fresh => shard.orderedIndexFresh(),
            };
            if (!ok) return false;
        }
        return true;
    }

    // ========================================================================
    // GAP-0064 FIX C: AUTO-BUILD the value-ordered index on a FRESH store.
    //
    // The value-ordered index (`createOrderedIndex` / `orderedScan`, GAP-0050)
    // is only ever registered by an explicit `CREATE INDEX`, so a from-dump /
    // freshly-ingested store has NONE and `ORDER BY <prop> LIMIT k` falls back
    // to the full-label top-K heap (the ~6.7 s-at-1M / times-out-at-14.27M path)
    // even though the planner `orderedScanFastPath` is fully wired.
    //
    // FIX C makes it materialize WITHOUT a manual CREATE INDEX: the planner, on
    // a shape-eligible ORDER-BY-<prop>-LIMIT query whose ordered index is not yet
    // registered, calls `spawnOrderedIndexBuildAsync`, which builds it exactly
    // once per (graph,label,key) on a BACKGROUND, uncancellable, deduped worker
    // (register + rebuild via the same `createOrderedIndex` CREATE INDEX uses,
    // then a best-effort full checkpoint to persist it). The triggering query is
    // served from the heap (correct, slower); every later ORDER BY on that prop —
    // and the NEXT reopen (gs reloads the persisted snapshot on the Path-B
    // contract) — is index-served. NOT a per-query cost: a re-trigger while a
    // build is in flight, or after the index is registered, is a no-op.
    //
    // SCOPE NOTE: the build is triggered lazily by the FIRST ORDER BY of each
    // distinct (label,key), so only properties that are actually ordered-by pay
    // the (one-time) build — never every property. This is the bounded variant
    // (a graph with N distinct ORDER-BY keys builds N ordered trees, one-time);
    // auto-building an ordered tree for EVERY indexed property at open would be
    // N_keys * O(nodes) B-tree inserts, prohibitive at 14.27M.
    // ========================================================================

    /// GAP-0064 FIX C core: register + build the value-ordered index for
    /// `(graph,label,key)` SYNCHRONOUSLY and uncancellably (idempotent). No-op
    /// when the index is already registered. Reuses `createOrderedIndex` (the
    /// exact path `CREATE INDEX` drives), so registration is global (all shards),
    /// the trees are rebuilt from a live scan, and gs marks them dirty for the
    /// next full-checkpoint persist. Bumps the FIX-C build counter on a real build.
    pub fn ensureOrderedIndexForKey(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        key: []const u8,
    ) !void {
        if (self.isOrderedIndexRegistered(graph_name, label, key)) return;
        try self.createOrderedIndex(graph_name, label, key);
        _ = g_ordered_index_builds.fetchAdd(1, .monotonic);
    }

    /// TEST-ONLY alias for `ensureOrderedIndexForKey` — deterministic (no thread)
    /// synchronous auto-build, exercising the SAME register+rebuild core the
    /// background worker runs, so a reopen test can assert persist+reload.
    pub fn buildOrderedIndexSyncForTesting(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        key: []const u8,
    ) !void {
        try self.ensureOrderedIndexForKey(graph_name, label, key);
    }

    /// GAP-0064 FIX C: kick off a ONE-TIME, uncancellable, deduped BACKGROUND
    /// build of the value-ordered index for `(graph,label,key)`. Best-effort and
    /// non-blocking: the caller (the planner) returns its heap result immediately.
    ///
    /// Dedup: no-op when the index is already registered, or when a build for the
    /// SAME (graph,label,key) is already in flight (the planner re-triggers on
    /// every matching ORDER BY until the index shows up). The in-flight set +
    /// thread lifecycle reuse the H4 persist-thread machinery (joined by deinit;
    /// `exact_persist_shutdown` refuses new spawns once teardown begins).
    pub fn spawnOrderedIndexBuildAsync(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        key: []const u8,
    ) void {
        // GAP-0064 FIX C (TEST-ONLY): allow suppression so heap-fallback tests
        // for non-indexed props stay deterministic.
        if (orderedAutobuildDisabled()) return;
        // Fast pre-check OUTSIDE the lock: already registered -> nothing to do.
        if (self.isOrderedIndexRegistered(graph_name, label, key)) return;

        const io = std.Io.Threaded.global_single_threaded.io();
        self.exact_persist_mutex.lockUncancelable(io);
        defer self.exact_persist_mutex.unlock(io);
        if (self.exact_persist_shutdown) return;

        // Dedup key "graph\x00label\x00key" (NUL-joined; graph/label/key never
        // contain NUL, so this is an unambiguous composite key).
        const dedup_key = std.fmt.allocPrint(self.allocator, "{s}\x00{s}\x00{s}", .{ graph_name, label, key }) catch return;
        var free_dedup_key = true;
        defer if (free_dedup_key) self.allocator.free(dedup_key);
        if (self.ordered_build_inflight.contains(dedup_key)) return; // already building

        // Owned copies for the worker thread (freed by the worker).
        const graph_copy = self.allocator.dupe(u8, graph_name) catch return;
        var free_graph = true;
        defer if (free_graph) self.allocator.free(graph_copy);
        const label_copy = self.allocator.dupe(u8, label) catch return;
        var free_label = true;
        defer if (free_label) self.allocator.free(label_copy);
        const key_copy = self.allocator.dupe(u8, key) catch return;
        var free_key = true;
        defer if (free_key) self.allocator.free(key_copy);

        // Reserve thread + dedup slots BEFORE spawning so a post-spawn OOM can
        // never leave an unjoinable thread or a stuck dedup entry.
        self.exact_persist_threads.ensureUnusedCapacity(self.allocator, 1) catch return;
        self.ordered_build_inflight.put(self.allocator, dedup_key, {}) catch return;
        var remove_dedup = true;
        defer if (remove_dedup) {
            if (self.ordered_build_inflight.fetchRemove(dedup_key)) |kv| self.allocator.free(kv.key);
        };

        const t = std.Thread.spawn(.{}, orderedIndexBuildWorker, .{ self, graph_copy, label_copy, key_copy }) catch return;
        self.exact_persist_threads.appendAssumeCapacity(t);
        // Success: the worker now owns the three copies AND the dedup entry.
        free_dedup_key = false;
        free_graph = false;
        free_label = false;
        free_key = false;
        remove_dedup = false;
    }

    /// GAP-0064 FIX C worker: build the ordered index (uncancellable) then persist
    /// it with a best-effort full checkpoint, and clear the in-flight dedup entry.
    /// Owns + frees `graph`, `label`, `key`. Best-effort throughout: any failure
    /// leaves the index correct-in-memory (or simply un-built, to be re-triggered
    /// by the next ORDER BY).
    fn orderedIndexBuildWorker(self: *StorageAdapter, graph: []u8, label: []u8, key: []u8) void {
        defer {
            // Clear the dedup entry (free its owned key) under the persist mutex.
            const io = std.Io.Threaded.global_single_threaded.io();
            self.exact_persist_mutex.lockUncancelable(io);
            const dedup_key = std.fmt.allocPrint(self.allocator, "{s}\x00{s}\x00{s}", .{ graph, label, key }) catch null;
            if (dedup_key) |dk| {
                if (self.ordered_build_inflight.fetchRemove(dk)) |kv| self.allocator.free(kv.key);
                self.allocator.free(dk);
            }
            self.exact_persist_mutex.unlock(io);
            self.allocator.free(graph);
            self.allocator.free(label);
            self.allocator.free(key);
            _ = g_ordered_build_completions.fetchAdd(1, .monotonic);
        }

        self.ensureOrderedIndexForKey(graph, label, key) catch |err| {
            slog.warn("ordered-index auto-build failed; ORDER BY stays heap-served for this key", &.{
                SAttr.string("graph", graph),
                SAttr.string("label", label),
                SAttr.string("key", key),
                SAttr.string("error", @errorName(err)),
            });
            return;
        };
        // Persist the freshly-registered ordered index so a reopen RELOADS it
        // (gs saves the ordered snapshot on the FULL-checkpoint path only; the
        // periodic LIGHT checkpoint does not). Best-effort: a clean shutdown's
        // close() persists it regardless, and a crash before then simply
        // re-triggers the build on the next ORDER BY.
        self.checkpointGraph(graph) catch |err| {
            slog.warn("ordered-index auto-build: persist checkpoint failed (index stays memory-only until the next full checkpoint / close)", &.{
                SAttr.string("graph", graph),
                SAttr.string("error", @errorName(err)),
            });
        };
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

    /// SONNY-6362 test instrumentation: add the posting `(label, key = value)
    /// -> node_slot` to `graph_name`'s exact property index, as a value-hash
    /// collision or a posting left stale reads to a lookup (the posting
    /// names a node whose value is another).
    pub fn addExactIndexPostingForTesting(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        key: []const u8,
        value: graph_store.PropertyValue,
        node_slot: u64,
    ) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        try ensureExactNodePropertyIndexBuilt(self, mg);
        const label_id = mg.label_dict.getId(label) orelse return error.LabelNotFound;
        const storage_value = try toStorageProperty(self.allocator, value);
        defer freeTemporaryStorageProperty(self.allocator, storage_value);
        const value_hash = try hashStorageProperty(self.allocator, storage_value);
        try mg.exact_node_property_index.addEx(label_id, key, value_hash, node_slot, false);
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
            const len = self.countCandidateNodesImpl(graph_name, label, f.key, f.value, true) catch continue;
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

        // SONNY-6362 item 6: a MERGE lookup waits for an in-flight build.
        const candidates = try self.getCandidateNodesImpl(graph_name, label, filters[seed_idx].key, filters[seed_idx].value, self.allocator, true);
        defer self.allocator.free(candidates);

        for (candidates) |node_id| {
            _ = g_lookup_all_props_candidates_scanned.fetchAdd(1, .monotonic);
            var all_match = true;
            // CANARY: REQ=REQ-SONNY-6362-SEED-RECHECK; FEATURE="MergeIdempotency"; ASPECT=SeedFilterVerified; STATUS=TESTED; TEST=tests/test_sonny6362_merge_index_residuals.zig; OWNER=storage; UPDATED=2026-11-12
            // SONNY-6362: every filter, the seed's included. The seed's
            // posting is a value HASH (a collision names a node holding
            // another value) and may be stale; it was trusted unchecked.
            for (filters) |f| {
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
                    //
                    // SONNY-6436: the entry names the LOWEST holder. The
                    // executor's MATCH binds every node holding the key, and
                    // MERGEs an edge per matched pair, so only the key's sole
                    // holder answers; more is `error.MergeKeyNotUnique` (the
                    // caller declines to the executor), as the scan below.
                    // The lookup above settled the entry.
                    return switch (store.lookupOnlyCompositeMergeHolder(graph_name, label, composite_idx, filters, &cid)) {
                        .found => cid,
                        .not_found => missing_err,
                        .not_indexable => error.MergeKeyNotUnique,
                    };
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
            const len = self.countCandidateNodesImpl(graph_name, label, f.key, f.value, true) catch continue;
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
                    if (try self.publicNodeMatchesAll(graph_name, store, seed_id, filters)) return seed_id;
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
        //
        // SONNY-6429: the scan reads every candidate, and a second node
        // matching every filter is `error.MergeKeyNotUnique`: the executor's
        // MATCH binds each, and MERGEs an edge per matched pair, where the
        // first match alone was taken (the caller declines to the executor).
        const label_nodes = store.getNodesByLabel(graph_name, label) orelse return missing_err;
        var matched: ?u64 = null;
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
            if (!all_match) continue;
            if (matched != null) return error.MergeKeyNotUnique;
            matched = node_id;
        }
        return matched orelse missing_err;
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

    // CANARY: REQ=REQ-SONNY-6447-MERGE-EDGE-ENDPOINT-TENANT; FEATURE="WriteFastPathParity"; ASPECT=CompositeEndpointTenantScope; STATUS=TESTED; TEST=tests/test_sonny6429_sole_holder_tenant_wire.zig; OWNER=storage; UPDATED=2026-11-12
    /// SONNY-6447: `lookupPublicNodeIdByLabelAndAllProps` for a request of
    /// `request_tenant` (the tag its writes carry), for the MATCH ... MERGE
    /// edge fast path's endpoints. An unscoped request (`mergeTenantScope`)
    /// is answered as `lookupPublicNodeIdByLabelAndAllProps` answers. A
    /// scoped one: that resolver's sole match (of any tenant) when it is the
    /// request's tenant's node; `missing_err` when no node matches, or the
    /// sole match is another tenant's (so none of this tenant's does);
    /// `error.MergeKeyNotUnique` when more nodes match (some may be this
    /// tenant's), or the match's tenant could not be read. Another tenant's
    /// node is never the answer, whatever gate the caller passed.
    pub fn lookupPublicNodeIdByLabelAndAllPropsForTenant(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        filters: []const PropKV,
        request_tenant: []const u8,
        missing_err: anyerror,
    ) !u64 {
        const scope = mergeTenantScope(request_tenant);
        const id = try self.lookupPublicNodeIdByLabelAndAllProps(graph_name, label, filters, missing_err);
        const tenant = scope orelse return id;
        const store = graph_store.getGlobalStore(graph_store.global_allocator());
        const own = store.nodeInGraphAndTenant(id, graph_name, tenant) catch return error.MergeKeyNotUnique;
        return if (own) id else missing_err;
    }

    /// Verify every filter against the public-id node's stored properties.
    /// Reads each property engine-direct by slot — NO full-node hydration
    /// (Phase 2). SONNY-6362: the seed's filter too; the merge probe that
    /// named the node checks only that it exists in the graph.
    fn publicNodeMatchesAll(
        self: *StorageAdapter,
        graph_name: []const u8,
        store: *graph_store.GraphStore,
        node_id: u64,
        filters: []const PropKV,
    ) !bool {
        for (filters) |f| {
            if (!self.publicNodeFilterMatchesNoHydrate(graph_name, store, node_id, f)) return false;
        }
        return true;
    }

    /// Cheap selectivity probe for an exact `(label, property = value)` posting.
    /// Returns the raw posting-list length (including any stale entries) without
    /// copying the list or touching the engine — used by the read fast path to
    /// pick the most selective indexed inline property before the real seek.
    /// Returns 0 when the label is unknown or the posting is absent.
    /// Index-served read: `error.ExactIndexBusy` while a build of the index
    /// is in flight (SONNY-6362 item 6; the caller scans instead).
    pub fn countCandidateNodesByLabelAndProperty(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        property_key: []const u8,
        value: graph_store.PropertyValue,
    ) !usize {
        return self.countCandidateNodesImpl(graph_name, label, property_key, value, false);
    }

    fn countCandidateNodesImpl(
        self: *StorageAdapter,
        graph_name: []const u8,
        label: []const u8,
        property_key: []const u8,
        value: graph_store.PropertyValue,
        comptime wait_for_build: bool,
    ) !usize {
        // This probes the exact node-property index by value hash exactly like
        // getCandidateNodesByLabelAndProperty — count it as an exact-index lookup
        // so probe-counting callers/tests (GAP-ENT-0019) see the seek fire.
        _ = g_exact_node_property_lookup_count.fetchAdd(1, .monotonic);
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        // H4: build the exact index on first access if it was deferred at open.
        if (wait_for_build) try ensureExactNodePropertyIndexBuilt(self, mg) else try ensureExactIndexForRead(self, mg);
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
        try ensureExactIndexForRead(self, mg); // SONNY-6362 item 6
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

    /// TEST-ONLY (Phase E2 gate): one exact-index posting — its encoded key
    /// `[label_id][key_len][key][value_hash]` and the SORTED node ids it holds.
    pub const ExactIndexPostingDump = struct {
        key: []u8,
        nodes: []u64,
    };

    /// TEST-ONLY (Phase E2 gate): dump EVERY posting of the in-memory exact index
    /// (all shards), each with its sorted node list, sorted by encoded key. Two
    /// dumps are EQUAL iff the indexes are key-for-key AND count-for-count (the
    /// sorted node lists, whose lengths are the posting counts) identical — the
    /// exact "reconcile == full rebuild" release-gate comparison. Does NOT build a
    /// deferred index (reads whatever is resident) so a reconciled vs. a
    /// force-rebuilt index can be compared without a rebuild side effect. Caller
    /// frees each entry's `key` + `nodes` and the outer slice.
    pub fn dumpExactIndexPostingsForTesting(self: *StorageAdapter, graph_name: []const u8, allocator: Allocator) ![]ExactIndexPostingDump {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };

        var out = std.ArrayList(ExactIndexPostingDump).empty;
        errdefer {
            for (out.items) |e| {
                allocator.free(e.key);
                allocator.free(e.nodes);
            }
            out.deinit(allocator);
        }

        const io = std.Io.Threaded.global_single_threaded.io();
        for (&mg.exact_node_property_index.shards) |*shard| {
            shard.mutex.lockUncancelable(io);
            defer shard.mutex.unlock(io);
            var it = shard.postings.iterator();
            while (it.next()) |entry| {
                const posting = entry.value_ptr.items;
                if (posting.len == 0) continue;
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_copy);
                const nodes_copy = try allocator.dupe(u64, posting);
                std.mem.sort(u64, nodes_copy, {}, std.sort.asc(u64));
                try out.append(allocator, .{ .key = key_copy, .nodes = nodes_copy });
            }
        }

        const items = try out.toOwnedSlice(allocator);
        std.mem.sort(ExactIndexPostingDump, items, {}, struct {
            fn lt(_: void, a: ExactIndexPostingDump, b: ExactIndexPostingDump) bool {
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lt);
        return items;
    }

    /// TEST-ONLY (Phase E1): byte size of the persisted `prop_rev.idx`, or null
    /// if absent. Used to prove the reverse map is BOUNDED — it stores the 8-byte
    /// value_hash, not the full value, so its size is independent of value length.
    pub fn reverseMapFileSizeForTesting(self: *StorageAdapter, graph_name: []const u8) ?u64 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.requireExistingGraphLocked(graph_name) catch return null;
        };
        const dir_path = graphDirPath(self.allocator, self.data_dir, mg.uuid) catch return null;
        defer self.allocator.free(dir_path);
        const rev_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, prop_rev_index_file_name }) catch return null;
        defer self.allocator.free(rev_path);
        const stat = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), rev_path, .{}) catch return null;
        return stat.size;
    }

    /// SONNY-1574 test-only: size of the persisted `prop_exact.idx` snapshot, or
    /// null when the file is absent. The ground truth behind the persist
    /// counters — a test can prove that a "completed" persist really did put a
    /// snapshot on disk (and that a SKIPPED one did not).
    pub fn exactIndexFileSizeForTesting(self: *StorageAdapter, graph_name: []const u8) ?u64 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.requireExistingGraphLocked(graph_name) catch return null;
        };
        const dir_path = graphDirPath(self.allocator, self.data_dir, mg.uuid) catch return null;
        defer self.allocator.free(dir_path);
        const idx_path = std.fmt.allocPrint(self.allocator, "{s}/prop_exact.idx", .{dir_path}) catch return null;
        defer self.allocator.free(idx_path);
        const stat = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), idx_path, .{}) catch return null;
        return stat.size;
    }

    /// TEST-ONLY (Phase E1): load the persisted `prop_rev.idx` reverse map and
    /// return it as a flat, key-sorted list of (node_id, encoded_key) pairs, so a
    /// round-trip test can assert it equals the inversion of the forward index.
    /// `expected_epoch`/`expected_covered` must be the stamp the file was written
    /// with (a mismatch → null, proving the load gate). Caller frees each `key`
    /// and the slice.
    pub const ReverseMapPairDump = struct { node_id: u64, key: []u8 };

    pub fn dumpReverseMapForTesting(
        self: *StorageAdapter,
        graph_name: []const u8,
        expected_epoch: u64,
        expected_covered: u64,
        allocator: Allocator,
    ) !?[]ReverseMapPairDump {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        const dir_path = try graphDirPath(self.allocator, self.data_dir, mg.uuid);
        defer self.allocator.free(dir_path);

        var rev = NodePropertyReverseMap.init(allocator);
        defer rev.deinit();
        if (rev.loadFromFile(dir_path, expected_epoch, expected_covered) != .loaded) return null;

        var out = std.ArrayList(ReverseMapPairDump).empty;
        errdefer {
            for (out.items) |e| allocator.free(e.key);
            out.deinit(allocator);
        }
        var it = rev.map.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |key| {
                try out.append(allocator, .{ .node_id = entry.key_ptr.*, .key = try allocator.dupe(u8, key) });
            }
        }
        const items = try out.toOwnedSlice(allocator);
        std.mem.sort(ReverseMapPairDump, items, {}, struct {
            fn lt(_: void, a: ReverseMapPairDump, b: ReverseMapPairDump) bool {
                if (a.node_id != b.node_id) return a.node_id < b.node_id;
                return std.mem.lessThan(u8, a.key, b.key);
            }
        }.lt);
        return items;
    }

    /// TEST-ONLY (Phase E2): the aggregate (epoch, covered_lsn, pre_recovery
    /// frontier) the reconcile gate compares. Lets a test assert the crash-tail
    /// state it constructed actually satisfies (or fails) the single-recovery
    /// gate before relying on the reconcile/rebuild outcome.
    pub const ReconcileGateState = struct { epoch: u64, covered_lsn: u64, frontier: u64, pre_recovery: u64 };

    pub fn reconcileGateStateForTesting(self: *StorageAdapter, graph_name: []const u8) ?ReconcileGateState {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.requireExistingGraphLocked(graph_name) catch return null;
        };
        const dir_path = graphDirPath(self.allocator, self.data_dir, mg.uuid) catch return null;
        defer self.allocator.free(dir_path);
        const stamp = readExactIndexStamp(self.allocator, dir_path) orelse
            return .{ .epoch = mgCheckpointEpoch(mg), .covered_lsn = 0, .frontier = mgDurableFrontierLsn(mg), .pre_recovery = mgPreRecoveryFrontierLsn(mg) };
        return .{
            .epoch = stamp.epoch,
            .covered_lsn = stamp.covered_lsn,
            .frontier = mgDurableFrontierLsn(mg),
            .pre_recovery = mgPreRecoveryFrontierLsn(mg),
        };
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
        // ENG-3983: both branches below reach into the DEFERRED `edge_index`
        // directly; on a cold reopen it is empty until materialized, so an
        // unhydrated lookup would report `error.EdgeNotFound` for a live edge.
        // Mirrors `GraphEngine.getEdge`'s own hydrate-then-read contract.
        try from_shard.ensureDerivedHydrated();
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

            // GAP-0060: edge prop_heads are now a full u64 in both the
            // adjacency entry (WIDE v3/slab-v3 record) and the edge index, so
            // edge property chains slab-pack exactly like node props. Gated on
            // the SAME shard config flag as gs `engine_edge_props.setEdgeProperty`
            // (edge_prop_slab_packing, default ON) — a slab head is only ever
            // produced for a store whose adjacency can hold it. When off, keep
            // the legacy one-page-per-edge writer (still a u64 head, hi=0).
            const new_head: u64 = if (from_shard.config.edge_prop_slab_packing)
                from_shard.putPropertyTxn(found_prop_head, key, storage_val, local_txn) catch |err|
                    return mapPropertyEntryError(err, key)
            else
                from_shard.putPropertyLegacyTxn(found_prop_head, key, storage_val, local_txn) catch |err|
                    return mapPropertyEntryError(err, key);

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
            try from_shard.refreshPropertyChainIndex(new_head);
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

        // GAP-0060: edge prop chains slab-pack (u64 head), gated on the shard
        // config — see the txn branch above.
        const fb_new_head: u64 = if (from_shard.config.edge_prop_slab_packing)
            from_shard.putPropertyTxn(fb_found_prop_head, key, storage_val, fb_local_txn) catch |err|
                return mapPropertyEntryError(err, key)
        else
            from_shard.putPropertyLegacyTxn(fb_found_prop_head, key, storage_val, fb_local_txn) catch |err|
                return mapPropertyEntryError(err, key);

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
        try from_shard.refreshPropertyChainIndex(fb_new_head);
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
        // ENG-3983: `edge_index` is deferred — hydrate before the direct read so a
        // cold-reopen batch does not report `error.EdgeNotFound` for a live edge.
        try from_shard.ensureDerivedHydrated();
        const edge_entry = (try from_shard.edge_index.get(edge_id)) orelse return error.EdgeNotFound;
        const from_id = edge_entry.from;
        const to_id = edge_entry.neighbor;
        const from_rec = (try from_shard.node_store.getNode(from_id)) orelse return error.NodeNotFound;
        const orig_prop_head: u64 = edge_entry.prop_head;

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

        var running_prop_head: u64 = orig_prop_head;
        var last_new_head_u64: u64 = orig_prop_head;
        for (entries) |entry| {
            const storage_val: gs.PropertyValue = if (entry.value) |val|
                try toStorageProperty(self.allocator, val)
            else
                .null;
            defer if (entry.value != null) freeTemporaryStorageProperty(self.allocator, storage_val);

            // GAP-0060: edge prop chains slab-pack (u64 head), gated on the shard
            // config — see setEdgeProperty.
            const new_head_u64 = if (from_shard.config.edge_prop_slab_packing)
                from_shard.putPropertyTxn(running_prop_head, entry.key, storage_val, local_txn) catch |err|
                    return mapPropertyEntryError(err, entry.key)
            else
                from_shard.putPropertyLegacyTxn(running_prop_head, entry.key, storage_val, local_txn) catch |err|
                    return mapPropertyEntryError(err, entry.key);
            running_prop_head = new_head_u64;
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
        // GAP-0060: edge prop_head is a full u64 (may be a slab head, bit 63).
        prop_head: u64,
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
        // ENG-3983: `edge_index` is a DEFERRED derived index — on a cold reopen it
        // is empty until `ensureDerivedHydrated` materializes it (the engine's own
        // `GraphEngine.getEdge` hydrates before every `edge_index.get`). Reaching
        // into it unhydrated returned null for EVERY live edge, which surfaced as
        // geode's bounded-edge-cache hydrate-on-miss failing after restart: a
        // cold `MATCH ()-[r:T]->() DELETE r` resolved the edge through the
        // typed-edge scan (which DOES hydrate, see collectEdgePublicIdsByType)
        // and then silently deleted nothing, and a cold `DETACH DELETE` orphaned
        // every incident edge. Hydration is idempotent and atomically gated, so
        // this is a one-time cost per shard per open.
        try from_shard.ensureDerivedHydrated();
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
        errdefer ctx.entries.deinit(allocator);
        for (mg.engine.shards) |shard| {
            const found_before = ctx.entries.items.len;
            const live_before = @atomicLoad(u64, &shard.manifest.node_count, .monotonic);
            try shard.node_store.scanNodes(shard.manifest.next_node_id, &ctx, &Ctx.onNode);
            if (ctx.had_error) return error.OutOfMemory;
            // CANARY: REQ=REQ-SONNY-2409-ZEROED-PAGE-FAIL-CLOSED; FEATURE="StorageIntegrity"; ASPECT=UnlabeledScanLiveCount; STATUS=TESTED; TEST=tests/test_sonny2409_zeroed_page_header.zig; OWNER=storage; UPDATED=2026-11-13
            // SONNY-2409: graph_storage's pager reads a zeroed page (torn
            // write, zeroed sectors) as a fresh one, so its node records look
            // empty and `scanNodes` skips them: an unlabeled scan answered OK
            // with those nodes missing. Fewer live records than the shard
            // manifest counts means lost node data: fail closed, as the
            // hydration scan does (REQ-GQL-028, same kill switch). The
            // smaller of the counts read before and after the scan is used.
            const live = @min(live_before, @atomicLoad(u64, &shard.manifest.node_count, .monotonic));
            const found = ctx.entries.items.len - found_before;
            if (found < live and !hydration_scan.liveCountCheckDisabled()) {
                log.warn("scanAllNodes: graph {s} shard found {d} live node record(s) but its manifest counts {d}: node pages lost or zeroed", .{ graph_name, found, live });
                return error.DataCorruption;
            }
        }

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

    /// GAP-0064 FIX B: the graph's durable derived-index generation token
    /// (aggregate `manifest.checkpoint_epoch`), bumped ONLY at checkpoint, never
    /// by a WAL-tail recovery. Used to stamp + reload-gate the idmap.snapshot and
    /// the hydration loop2 snapshots on the SAME (epoch, covered_lsn) contract as
    /// prop_exact.idx (fa6495bb), replacing the manifest.counter that recovery.zig
    /// bumps on any tail (which needlessly rejected a valid snapshot). See
    /// `mgCheckpointEpoch`.
    pub fn graphCheckpointEpoch(self: *StorageAdapter, graph_name: []const u8) ?u64 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.requireExistingGraphLocked(graph_name) catch return null;
        };
        return mgCheckpointEpoch(mg);
    }

    /// GAP-0064 FIX B: the graph's DURABLE COMMITTED FRONTIER (aggregate
    /// `manifest.last_checkpoint_lsn`) — set at checkpoint AND advanced by a
    /// committed WAL-tail recovery, but left unchanged by a clean reopen that
    /// replays nothing. Reload gate: `stamped_epoch == graphCheckpointEpoch AND
    /// stamped_covered == this` ⟺ "no checkpoint AND no tail since the snapshot".
    /// See `mgDurableFrontierLsn`.
    pub fn graphDurableFrontierLsn(self: *StorageAdapter, graph_name: []const u8) ?u64 {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.requireExistingGraphLocked(graph_name) catch return null;
        };
        return mgDurableFrontierLsn(mg);
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
        // SONNY-2463: a failure part way frees every key and value already
        // put, not only the table.
        errdefer freeReadPropertyMap(allocator, &result);

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
            try putDecodedProperty(allocator, &result, entry.key, entry.encoded_value);
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
        // GAP-0060: edge prop_head is a full u64 (may be a slab head, bit 63).
        prop_head: u64,
        allocator: Allocator,
    ) !std.StringHashMap(gs.PropertyValue) {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };

        var result = std.StringHashMap(gs.PropertyValue).init(allocator);
        // SONNY-2463: as in `getAllNodeProperties`.
        errdefer freeReadPropertyMap(allocator, &result);

        if (prop_head == 0) return result;

        const prop_head_u64: u64 = prop_head;

        // Route via the source node's shard — same per-shard engine
        // that wrote the property pages.
        var iter = try mg.shardEngineForNode(from_id).getAllProperties(prop_head_u64);
        defer iter.deinit();

        while (try iter.next()) |entry| {
            if (!shouldExposePropertyKey(entry.key)) continue;
            try putDecodedProperty(allocator, &result, entry.key, entry.encoded_value);
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

    /// SONNY-1574 test-only: take `mg.exact_index_build_mutex` from the CALLING
    /// thread and keep holding it, standing in for an in-flight rebuild (the
    /// background-reopen worker or a lazy first-access build). Lets a test drive
    /// a FULL checkpoint's exact-index persist decision straight into the
    /// `tryLock` skip branch DETERMINISTICALLY, instead of waiting for the
    /// scheduler to lose the production race under load. Must be paired with
    /// `releaseExactIndexBuildMutexForTesting` FROM THE SAME THREAD.
    pub fn holdExactIndexBuildMutexForTesting(self: *StorageAdapter, graph_name: []const u8) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        mg.exact_index_build_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    /// SONNY-1574 test-only: release a hold taken by
    /// `holdExactIndexBuildMutexForTesting`.
    pub fn releaseExactIndexBuildMutexForTesting(self: *StorageAdapter, graph_name: []const u8) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk try self.requireExistingGraphLocked(graph_name);
        };
        mg.exact_index_build_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    /// SONNY-1574 test-only: fire the persist-on-build background worker exactly
    /// as `ensureExactNodePropertyIndexBuilt` does after a successful rebuild —
    /// same attempt counting, same thread tracking (joined by `deinit`) — without
    /// having to stage a real deferred rebuild. Used to pin the worker's counter
    /// contract (a persist that wrote nothing must never report a completion).
    pub fn spawnExactIndexPersistForTesting(self: *StorageAdapter, graph_name: []const u8) void {
        self.spawnExactIndexPersistAfterBuild(graph_name);
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
                    // SONNY-3028: pinned while this checkpoint uses it, so a
                    // concurrent `dropGraph` cannot free it under the pointer.
                    _ = mg.*.pins.fetchAdd(1, .acq_rel);
                    graphs_buf[graph_count] = mg.*;
                    graph_count += 1;
                }
            }
        }
        defer for (graphs_buf[0..graph_count]) |mg| self.unpinGraph(mg);

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
            switch (self.checkpointOneGraph(mg, light, set_writer_pref, timeout_ns, null)) {
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
        var counts_buf: [64]struct { mg: *ManagedGraph, node_count: u64, edge_count: u64 } = undefined;
        for (graphs_buf[0..graph_count], 0..) |mg, i| {
            var nc: u64 = 0;
            var ec: u64 = 0;
            for (mg.engine.shards) |shard| {
                nc += @atomicLoad(u64, &shard.manifest.node_count, .monotonic);
                ec += @atomicLoad(u64, &shard.manifest.edge_count, .monotonic);
            }
            counts_buf[i] = .{
                .mg = mg,
                .node_count = nc,
                .edge_count = ec,
            };
        }
        {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            for (counts_buf[0..graph_count]) |c| {
                // SONNY-3028: a graph dropped during this checkpoint left the
                // registry; it is not written back.
                if (c.mg.isDropped()) continue;
                self.upsertRegistryEntryLocked(c.mg.name, c.mg.uuid, c.node_count, c.edge_count);
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

    /// SONNY-1574: what a FULL checkpoint's exact-index persist decision
    /// ACTUALLY did. Reported out of `checkpointPersistExactIndexLocked` (and,
    /// optionally, out of `checkpointOneGraph` / `checkpointGraphEx`) so a
    /// caller can distinguish "the snapshot is durable" from "the checkpoint
    /// returned OK having written nothing" — the distinction whose absence let
    /// the persist-on-build worker report a completion for a skipped persist.
    pub const ExactIndexPersistOutcome = enum {
        /// No persist decision ran for this checkpoint (LIGHT checkpoint, engine
        /// checkpoint failed, graph dir path unavailable, or the graph rwlock
        /// was busy past the deadline). SONNY-1574 (fix pass 1574b, gated
        /// correctly in 1574c): the graph-dir-path-unavailable cause is ALSO
        /// counted in `g_exact_persist_failures`, at the decision site
        /// (`checkpointOneGraph`'s dir-path branch) — but ONLY when this is a
        /// FULL checkpoint (`!light`) whose engine checkpoint SUCCEEDED
        /// (`engine_ok`). A FULL checkpoint that "succeeded" (`.ok`) while
        /// never even reaching the persist decision must not silently report
        /// zero writes, zero skips, zero failures, and zero completions. The
        /// other causes need no extra counting at this decision site: a LIGHT
        /// checkpoint deliberately never attempts this decision (the
        /// dir-path branch runs before the light/!light split, so it is
        /// reachable from LIGHT too, but is deliberately NOT counted there),
        /// an engine-checkpoint failure is already reported as the enclosing
        /// checkpoint's own distinct `OneGraphCheckpointOutcome.engine_failed`
        /// (double-counting it here would bump `g_exact_persist_failures`
        /// twice for one failed attempt, since `checkpointGraphEx` turns
        /// `.engine_failed` into `error.CheckpointFailed` and the worker's
        /// outer `catch` bumps it again), and a busy rwlock is reported as
        /// `OneGraphCheckpointOutcome.skipped_busy`.
        not_attempted,
        /// `saveToFile` succeeded — a fresh `prop_exact.idx` (+ reverse map) is
        /// on disk, stamped at this checkpoint's (epoch, covered_lsn).
        wrote,
        /// `saveToFile` was called and FAILED — nothing durable. Counted in
        /// `g_exact_persist_failures`.
        write_failed,
        /// The build-mutex `tryLock` lost: another build owns the index and
        /// persists on its own completion. Nothing written here.
        skipped_build_locked,
        /// A deferred graph with no durable nodes: nothing to snapshot, any
        /// stale file invalidated.
        skipped_empty,
    };

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
    /// * `exact_out` — SONNY-1574: optional out-param that receives what the
    ///   FULL path's exact-index persist decision actually did. Left at
    ///   `.not_attempted` on every path that runs no decision (LIGHT, busy
    ///   rwlock, failed engine checkpoint, dir-path error).
    fn checkpointOneGraph(
        self: *StorageAdapter,
        mg: *ManagedGraph,
        light: bool,
        set_writer_pref: bool,
        acquire_timeout_ns: ?u64,
        exact_out: ?*ExactIndexPersistOutcome,
    ) OneGraphCheckpointOutcome {
        if (exact_out) |o| o.* = .not_attempted;
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
                std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
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
        // SONNY-3028: dropped while this checkpoint waited for its lock (the
        // caller pinned it): there is nothing left to save.
        if (mg.isDropped()) {
            mg.rwlock.unlock(io_cp);
            return .ok;
        }
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
                // checkpoints instead of DELETING it. The (epoch, covered_lsn)
                // stamp (saveToFile/loadFromFile) makes a stale copy un-loadable
                // on reopen, so a delete is no longer needed for correctness — and
                // the delete is exactly what dropped the hydration-built index at
                // 14.27M (P1). We also do NOT re-save here: that is O(graph) and
                // would defeat the O(dirty) LIGHT contract. A LIGHT checkpoint that
                // dirtied pages advances the epoch + frontier, which naturally
                // invalidates the now-stale on-disk stamp for the next reopen; a
                // no-op (clean) LIGHT leaves a current-stamped index reloadable.
            } else if (!engine_ok) {
                // GAP-ENT-0048 Task 5.3a: the engine FULL checkpoint FAILED — an
                // interrupted big-deferred-WAL shutdown leaves a WAL tail, so the
                // durable frontier/pages did not cleanly advance to the in-memory
                // state. Persisting `prop_exact.idx` NOW would stamp it with a
                // frontier that a subsequent reopen might match (covered ==
                // frontier) while the index does NOT reflect the true durable
                // committed state → a PRESENT-BUT-STALE snapshot that reloads
                // wrong WHERE/GROUP BY/DISTINCT answers. So do NOT write a fresh
                // stamp. The PRIOR on-disk file (from the last SUCCESSFUL
                // checkpoint) is left untouched: on reopen, recovery replays the
                // tail and advances the frontier past that file's covered_lsn, so
                // the covered<frontier tail gate rejects it and rebuilds (and if
                // the failure left no tail, that older file is still valid and
                // reloads). Either way, never a stale serve.
                slog.warn("skipping exact-index persist: engine checkpoint failed (tail may remain; not writing a possibly-stale stamp)", &.{
                    SAttr.string("graph", mg.name),
                });
            } else {
                // GAP-0064 (adversarial review — CRITICAL double-insert fix):
                // build/persist the exact index UNDER the shared
                // `exact_index_build_mutex` (non-blocking tryLock). This serializes
                // the checkpoint's eager build with BOTH the background-reopen
                // worker AND the lazy-first-access build (`ensureExactNodePropertyIndexBuilt`),
                // closing BOTH double-insert races (two concurrent
                // `rebuildExactNodePropertyIndex` → `addEx(assume_new=true)` skips
                // dedup → duplicated postings / inflated GROUP BY/DISTINCT/count).
                // The prior `exact_rebuild_inflight`-only skip covered only the
                // worker, not the lazy build. tryLock never blocks, so the
                // checkpoint (holding mg.rwlock EXCLUSIVE) never waits ~14 min.
                const exact_outcome = self.checkpointPersistExactIndexLocked(mg, dir_path);
                if (exact_out) |o| o.* = exact_outcome;
            }
            self.allocator.free(dir_path);
        } else |err| {
            // SONNY-1574 (fix pass 1574b, corrected in 1574c): this left
            // `exact_out` at `.not_attempted` while a FULL checkpoint whose
            // engine checkpoint SUCCEEDED still returned `.ok` — so a caller
            // like the persist-on-build worker saw a checkpoint that
            // "succeeded" having made NO exact-index persist decision at all,
            // and its warn-only handling counted nothing: zero writes, zero
            // skips, zero failures, zero completions for a run that
            // materially happened. Count it as a FAILURE here, at the
            // decision site — the same place a `saveToFile` failure is
            // counted (`checkpointPersistExactIndexLocked`'s two
            // `write_failed` arms) — so every persist decision stays
            // observable even when the failure is "we could not even ask the
            // question."
            //
            // Gated on `!light and engine_ok` (1574c fix): `graphDirPath` is
            // called before the light/!light split, so this `else` arm is
            // also reachable from a LIGHT checkpoint (`exact_out == null`) —
            // the enum doc comment above states a LIGHT checkpoint
            // deliberately never attempts this decision, so it must not be
            // counted as a failure either. And when the engine checkpoint
            // itself already failed, `checkpointOneGraph` returns
            // `.engine_failed`, which `checkpointGraphEx` turns into
            // `error.CheckpointFailed` — the worker's outer `catch` already
            // bumps `g_exact_persist_failures` for that one attempt, so
            // bumping it again here would double-count a single failed
            // attempt as two failures.
            if (!light and engine_ok) {
                _ = g_exact_persist_failures.fetchAdd(1, .monotonic);
            }
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
    /// GAP-0064 (adversarial review — CRITICAL): the FULL-checkpoint exact-index
    /// build/persist decision, run UNDER the shared `exact_index_build_mutex` so it
    /// can never run a `rebuildExactNodePropertyIndex` concurrently with the
    /// background-reopen worker OR the lazy-first-access build (both take the same
    /// mutex) — the two-concurrent-rebuild double-insert corruption.
    ///
    /// Acquires the mutex NON-BLOCKING (`tryLock`): the checkpoint holds mg.rwlock
    /// EXCLUSIVE, so a blocking acquire against an in-flight ~14-min build would
    /// stall every operation on the graph for the whole build. On tryLock failure a
    /// build already owns the index and will persist on completion — skip WITHOUT
    /// invalidating (dropping its soon-to-be-persisted file would only cost a
    /// needless reopen rebuild). Caller MUST hold mg.rwlock EXCLUSIVE (the FULL,
    /// non-light checkpoint path).
    ///
    /// SONNY-1574: RETURNS what it actually did. Every "wrote nothing" path is
    /// now observable (and counted) instead of silently returning `void` while
    /// the enclosing `checkpointGraph` reported success — the lost-persist bug:
    /// the tryLock skip fired, nothing was written, and the persist-on-build
    /// worker still bumped `completions`.
    fn checkpointPersistExactIndexLocked(self: *StorageAdapter, mg: *ManagedGraph, dir_path: []const u8) ExactIndexPersistOutcome {
        const io = std.Io.Threaded.global_single_threaded.io();
        if (!mg.exact_index_build_mutex.tryLock()) {
            // A background-reopen worker or a lazy-first-access build holds the
            // mutex (it is mid-scan). It latches `built` + persists on completion;
            // do NOT run a second rebuild here and do NOT invalidate its file.
            //
            // SONNY-1574: KEPT non-blocking (a blocking acquire here would park
            // the checkpoint — which holds mg.rwlock EXCLUSIVE — behind a ~14-min
            // O(graph) rebuild and freeze every operation on the graph; that is
            // exactly why 6e9a7e34/GAP-0064 chose tryLock). The lost persist is
            // fixed at the SOURCE instead: `ensureExactNodePropertyIndexBuilt` no
            // longer spawns its persist while still holding this mutex. What
            // changes here is only the REPORTING — a skip is counted as a skip
            // and never laundered into a completion.
            _ = g_exact_persist_skips.fetchAdd(1, .monotonic);
            slog.info("skipping exact-index persist: a rebuild holds the build mutex (background worker or lazy first-access) — it persists on completion", &.{
                SAttr.string("graph", mg.name),
            });
            return .skipped_build_locked;
        }
        defer mg.exact_index_build_mutex.unlock(io);

        if (mg.exact_index_built.load(.acquire)) {
            // Built (reloaded at open, or built by a prior touch/this checkpoint).
            // Persist the current index — under the build mutex, so no concurrent
            // rebuild mutates it during the save. SONNY-6354: complete for every
            // registered key first, and stamped with that key set.
            const config = prepareExactIndexSaveLocked(mg) catch |err| {
                _ = g_exact_persist_failures.fetchAdd(1, .monotonic);
                log.warn("failed to complete property index for graph '{s}' before persisting it: {}", .{ mg.name, err });
                return .write_failed;
            };
            mg.exact_node_property_index.saveToFile(dir_path, mgCheckpointEpoch(mg), mgDurableFrontierLsn(mg), config) catch |err| {
                // SONNY-1574: a failed save is a FAILURE, not a warning the
                // success surface swallows.
                _ = g_exact_persist_failures.fetchAdd(1, .monotonic);
                log.warn("failed to persist property index for graph '{s}': {}", .{ mg.name, err });
                return .write_failed;
            };
            _ = g_exact_persist_writes.fetchAdd(1, .monotonic);
            return .wrote;
        }

        // Deferred AND no build in flight (we hold the mutex): materialise it now
        // from the durable pages — race-free (mg.rwlock EXCLUSIVE drains readers;
        // the build mutex excludes the worker/lazy builds) — then persist. An empty
        // (0-node) deferred graph has nothing to build → invalidate any stale file.
        if (self.eagerBuildDeferredIndexForFullCheckpoint(mg)) {
            const config = prepareExactIndexSaveLocked(mg) catch |err| {
                _ = g_exact_persist_failures.fetchAdd(1, .monotonic);
                log.warn("failed to complete eagerly-built property index for graph '{s}' before persisting it: {}", .{ mg.name, err });
                return .write_failed;
            };
            mg.exact_node_property_index.saveToFile(dir_path, mgCheckpointEpoch(mg), mgDurableFrontierLsn(mg), config) catch |err| {
                _ = g_exact_persist_failures.fetchAdd(1, .monotonic);
                log.warn("failed to persist eagerly-built property index for graph '{s}': {}", .{ mg.name, err });
                return .write_failed;
            };
            _ = g_exact_persist_writes.fetchAdd(1, .monotonic);
            return .wrote;
        }
        invalidateExactPropertyIndexFile(self.allocator, dir_path);
        _ = g_exact_persist_skips.fetchAdd(1, .monotonic);
        return .skipped_empty;
    }

    fn eagerBuildDeferredIndexForFullCheckpoint(self: *StorageAdapter, mg: *ManagedGraph) bool {
        _ = self;
        // GAP-0064 (adversarial review): now ALWAYS called from
        // `checkpointPersistExactIndexLocked` while it holds BOTH mg.rwlock
        // EXCLUSIVE and `exact_index_build_mutex` — so the per-shard scan is
        // race-free against the background-reopen worker + lazy builds too, not just
        // live mutations. (Previously called directly from the checkpoint ladder
        // under mg.rwlock only, which left the lazy-build-vs-eager-build race open.)
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
        // FOLD caller (`GraphStore.ensureGraphHydrated` first-touch). NO-OP when a
        // race-free background reopen rebuild owns this graph's build (GAP-0064
        // FIX A) — so hydration returns after resident loop1/loop2 instead of
        // parking every reader behind the O(graph) index build.
        self.buildAndPersistExactIndexForHydratedGraphEx(graph_name, false);
    }

    /// Core of `buildAndPersistExactIndexForHydratedGraph`.
    ///
    /// `is_background_worker`:
    ///   * `false` (the hydration FOLD): NO-OP when `exact_rebuild_inflight` is
    ///     set — a spawned reopen rebuild already owns this build, and the fold
    ///     waiting on it would re-couple readers to the ~14-min build. It only
    ///     runs the build itself when NO background rebuild is in flight (spawn
    ///     failed / disabled) — the pre-FIX-A fallback.
    ///   * `true` (the spawned `exactIndexRebuildOnReopenWorker`): bypasses the
    ///     inflight NO-OP gate (it IS the owner) and CLEARS `exact_rebuild_inflight`
    ///     when finished/aborted, so `checkpointOneGraph`'s inflight-gated
    ///     exact-index branch re-opens once the build is done.
    fn buildAndPersistExactIndexForHydratedGraphEx(self: *StorageAdapter, graph_name: []const u8, is_background_worker: bool) void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            break :blk self.requireExistingGraphLocked(graph_name) catch return;
        };
        // GAP-0064 FIX A: the fold defers to an in-flight background rebuild; the
        // worker proceeds and clears the flag on every return path below.
        if (!is_background_worker and mg.exact_rebuild_inflight.load(.acquire)) return;
        defer if (is_background_worker) mg.exact_rebuild_inflight.store(false, .release);
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

        // GAP-0064 FIX A (TEST-ONLY): hold the background build "in flight" so a
        // test can prove first-touch reads return (via the fold no-op) while the
        // exact index is still building. Never blocks in production (gate == 0).
        if (comptime @import("builtin").is_test) {
            if (is_background_worker and g_test_exact_build_gate.load(.acquire) != 0) {
                _ = g_test_build_gate_waiters.fetchAdd(1, .acq_rel);
                while (g_test_exact_build_gate.load(.acquire) != 0) {
                    std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(1), .awake) catch {};
                }
                _ = g_test_build_gate_waiters.fetchSub(1, .acq_rel);
            }
        }

        // Lock-free parallel scan of the durable engine stores -> mutex-sharded
        // exact index. GAP-0064 (review — shutdown-stall fix): the BACKGROUND
        // worker's build is cancellable ONLY by process shutdown
        // (`exact_build_shutdown_cancel`, wired as the STREAM cancel flag that the
        // rebuild polls every 256 nodes), so a graceful SIGTERM aborts it promptly
        // instead of stalling teardown ~14 min. The FOLD path stays uncancellable
        // (`.{}`) — it runs inline on the hydration thread. A shutdown-aborted build
        // returns here without latching `built`, so the index stays deferred and
        // the next reopen rebuilds cleanly (accessors gate on `built`).
        const build_cancel: read_budget.CancelFlags = if (is_background_worker)
            .{ .cancel = &self.exact_build_shutdown_cancel }
        else
            .{};
        const build_start_ns = monoNanosNow();
        rebuildExactNodePropertyIndex(mg, build_cancel) catch |err| {
            log.warn("hydration-time exact-index build failed/cancelled for graph '{s}': {} — staying deferred", .{ graph_name, err });
            return;
        };
        mg.exact_index_built.store(true, .release);
        _ = g_exact_hydration_builds.fetchAdd(1, .monotonic);

        // Persist prop_exact.idx DIRECTLY (shard mutexes only — no mg.rwlock, no
        // checkpoint). This is what removes the shutdown-checkpoint dependency.
        // Stamped on the Path B (epoch, covered_lsn) contract. NOTE: this direct
        // persist does NOT run a checkpoint, so `covered_lsn` = the CURRENT
        // durable frontier `last_checkpoint_lsn` (which may lag the just-scanned
        // pages if committed writes since the last checkpoint sit in the WAL). If
        // such a tail exists, the NEXT reopen's covered<frontier gate REBUILDS
        // (safe, never a stale serve); a subsequent FULL checkpoint re-stamps it
        // reloadably (covered == frontier). The in-memory index is complete and
        // correct either way; this persist buys crash-safety, not a reload
        // guarantee under a still-open WAL tail.
        if (graphDirPath(self.allocator, self.data_dir, mg.uuid)) |dir_path| {
            defer self.allocator.free(dir_path);
            // SONNY-6354: complete for a key registered during the build, and
            // stamped with the key set.
            if (prepareExactIndexSaveLocked(mg)) |config| {
                mg.exact_node_property_index.saveToFile(dir_path, mgCheckpointEpoch(mg), mgDurableFrontierLsn(mg), config) catch |err| {
                    log.warn("hydration-time exact-index persist failed for graph '{s}': {} — index stays memory-only until the next checkpoint", .{ graph_name, err });
                };
            } else |err| {
                log.warn("hydration-time exact-index persist skipped for graph '{s}': {} — index stays memory-only until the next checkpoint", .{ graph_name, err });
            }
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
        return self.checkpointGraphEx(graph_name, null);
    }

    /// SONNY-1574: `checkpointGraph` + the exact-index persist outcome. A caller
    /// that runs this checkpoint FOR the index snapshot (the persist-on-build
    /// worker) must know whether the snapshot actually reached disk — a
    /// successful return alone does not imply it did.
    pub fn checkpointGraphEx(
        self: *StorageAdapter,
        graph_name: []const u8,
        exact_out: ?*ExactIndexPersistOutcome,
    ) !void {
        const mg = blk: {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            const found = try self.requireExistingGraphLocked(graph_name);
            // SONNY-3028: pinned while this checkpoint uses it.
            _ = found.pins.fetchAdd(1, .acq_rel);
            break :blk found;
        };
        defer self.unpinGraph(mg);
        switch (self.checkpointOneGraph(mg, false, true, 5 * std.time.ns_per_s, exact_out)) {
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
            // CANARY: REQ=REQ-SONNY-3131-CHECKPOINT-DROPPED-GRAPH; FEATURE="MultiGraphIsolation"; ASPECT=GraphCheckpointRegistry; STATUS=TESTED; TEST=tests/test_sonny3131_checkpoint_dropped_graph.zig; OWNER=storage; UPDATED=2026-09-27
            // SONNY-3131: a graph dropped while this checkpoint waited (it
            // returned `.ok` with nothing saved) left the registry; it is not
            // written back, as `checkpointAllEx` does not. The upsert put the
            // dropped graph back, whose files are gone: CREATE GRAPH of the
            // name answered 42P07, and every later registry save failed. The
            // dropped bit is set under this mutex, so the check is exact.
            if (mg.isDropped()) return;
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
        // SONNY-1574: ask the checkpoint what its exact-index persist decision
        // actually DID. A successful `checkpointGraph` is NOT evidence that a
        // snapshot reached disk.
        // Bumped LAST (every exit path): publishes "this worker's counters are
        // final" to any observer.
        defer _ = g_exact_persist_worker_runs.fetchAdd(1, .release);
        var outcome: ExactIndexPersistOutcome = .not_attempted;
        self.checkpointGraphEx(graph_name, &outcome) catch |err| {
            _ = g_exact_persist_failures.fetchAdd(1, .monotonic);
            slog.warn("exact-index persist-on-build failed; index stays memory-only until the next full checkpoint (a crash before then re-pays the rebuild)", &.{
                SAttr.string("graph", graph_name),
                SAttr.string("error", @errorName(err)),
            });
            return;
        };
        switch (outcome) {
            .wrote => {
                _ = g_exact_persist_completions.fetchAdd(1, .monotonic);
                slog.info("exact-index persist-on-build complete (crash-safe)", &.{
                    SAttr.string("graph", graph_name),
                });
            },
            // Already counted in `g_exact_persist_failures` at the write site.
            .write_failed => slog.warn("exact-index persist-on-build wrote NOTHING: the snapshot save failed; a crash before the next full checkpoint re-pays the rebuild", &.{
                SAttr.string("graph", graph_name),
            }),
            // Already counted in `g_exact_persist_skips` at the decision site.
            // NOT a completion: post-fix the spawn happens outside the build
            // mutex, so reaching here means a DIFFERENT build owns the index and
            // will persist on its own completion.
            .skipped_build_locked, .skipped_empty => slog.warn("exact-index persist-on-build persisted nothing (skipped); the index stays memory-only until another build or checkpoint persists it", &.{
                SAttr.string("graph", graph_name),
                SAttr.string("outcome", @tagName(outcome)),
            }),
            // SONNY-1574 (fix pass 1574b): this worker always drives a FULL
            // (non-light) checkpoint (`checkpointGraphEx` calls
            // `checkpointOneGraph` with `light = false`), so reaching `.ok`
            // with `exact_out` still `.not_attempted` here can ONLY mean the
            // graph-dir-path resolution failed — the busy-rwlock and
            // engine-checkpoint-failed cases return `.skipped_busy` /
            // `.engine_failed` from `checkpointOneGraph`, never `.ok`
            // (handled by the `catch` above via the propagated error), and a
            // LIGHT checkpoint is never run from this worker. Already counted
            // in `g_exact_persist_failures` at the decision site
            // (`checkpointOneGraph`'s dir-path branch): this is a genuine
            // failure to even DECIDE, not a benign skip, so it gets its own
            // arm rather than being lumped in with the skip log above.
            .not_attempted => slog.warn("exact-index persist-on-build persisted nothing: the exact-index persist decision never ran (graph dir path unavailable)", &.{
                SAttr.string("graph", graph_name),
            }),
        }
    }

    /// GAP-ENT-0048 crash-reconcile (Phase E2): on a `.stale` reopen (a present
    /// prop_exact.idx snapshot rejected because a committed WAL tail advanced the
    /// durable frontier past its covered_lsn), attempt an O(tail) RECONCILE of
    /// the snapshot instead of the O(graph) full rebuild — but ONLY when it is
    /// provably SOUND. Returns `true` iff the reconcile completed and the
    /// in-memory index is now correct-as-of the recovered tail (caller latches
    /// `exact_index_built`); `false` on ANY doubt (caller falls back to the safe
    /// full rebuild). A WRONG reconcile = silently-wrong WHERE/GROUP-BY/DISTINCT,
    /// so every uncertain branch returns `false`.
    ///
    /// Called INLINE from `openGraphLocked` before the graph is published to
    /// `self.engines` (so no other thread can touch the index) — the most
    /// race-free routing, and O(tail)-bounded (unlike the O(graph) rebuild that
    /// must be deferred to a background thread).
    ///
    /// Gate (identical to gs's own Path B derived-index gate, mirrored on geode's
    /// aggregate stamp): stamped_epoch == current epoch (no checkpoint since the
    /// snapshot) AND current durable frontier > stamped covered_lsn (a tail
    /// exists) AND stamped covered_lsn == pre-recovery frontier (EXACTLY one
    /// recovery since the snapshot — never reconcile across >1 recovery). On any
    /// gate miss, or a null/absent tail node set (overflow / unattributable
    /// props), or a missing/torn reverse map, or a per-node re-derive error →
    /// `false` (full rebuild).
    fn tryReconcileExactIndexOnReopen(self: *StorageAdapter, mg: *ManagedGraph, graph_dir_path: []const u8) bool {
        // 1) Read the snapshot's (epoch, covered_lsn) stamp from its header.
        const stamp = readExactIndexStamp(self.allocator, graph_dir_path) orelse return false;

        // 2) Gate on the WAL-aware single-recovery contract.
        const cur_epoch = mgCheckpointEpoch(mg);
        const cur_frontier = mgDurableFrontierLsn(mg);
        const pre_recovery = mgPreRecoveryFrontierLsn(mg);
        if (stamp.epoch != cur_epoch) return false; // a checkpoint ran since the snapshot → rebuild
        if (cur_frontier <= stamp.covered_lsn) return false; // no committed tail → the caller's .stale path shouldn't reach here, but be safe
        if (stamp.covered_lsn != pre_recovery) return false; // multi-crash / >1 recovery since the snapshot → rebuild

        // 3) Resolve the tail-affected node ids FIRST — before any base load or
        //    per-node re-derive — because gs frees `tail_affected_pages` on its
        //    first derived-hydration access (the G1 lifecycle contract). Three-way
        //    signal: null → full rebuild required; empty → nothing to reconcile;
        //    non-empty → the (super)set of tail-affected node ids.
        const maybe_ids = mg.engine.tailAffectedNodeIds(self.allocator) catch return false;
        const ids = maybe_ids orelse return false; // null → rebuild
        defer self.allocator.free(ids);

        // 4) Load the covered_lsn BASE postings (the snapshot as it stood at the
        //    last checkpoint). `expected_covered_lsn == stamp.covered_lsn` (==
        //    pre_recovery, gated) so the file loads despite the tail.
        // SONNY-6354: the late-key generation is read before the key
        // configuration the file must match, so a key registered in between
        // leaves the index behind (caught up on first access), never ahead.
        const lean_gen = graph_store.leanLateGenMax();
        const base_outcome = mg.exact_node_property_index.loadFromFile(graph_dir_path, cur_epoch, stamp.covered_lsn, graph_store.exactIndexConfigHash());
        if (base_outcome != .loaded) return false;
        // From here a `false` return MUST leave the index EMPTY (a partial index
        // is worse than a rebuild): every failure branch below calls `clear()`
        // before `return false` (this fn returns `bool`, so `errdefer` cannot).

        if (ids.len == 0) {
            // A committed tail advanced the frontier but touched NO node-owning
            // pages (e.g. edge-only) → the node-property base is already correct.
            _ = g_exact_index_reconciled.fetchAdd(1, .monotonic);
            mg.exact_lean_gen.store(lean_gen, .release);
            return true;
        }

        // 5) Load the reverse map (node → old encoded posting keys), stamped
        //    IDENTICALLY to the base. Missing/torn/mismatched → clear + rebuild.
        var rev = NodePropertyReverseMap.init(self.allocator);
        defer rev.deinit();
        if (rev.loadFromFile(graph_dir_path, cur_epoch, stamp.covered_lsn) != .loaded) {
            mg.exact_node_property_index.clear();
            return false;
        }

        // 6) Reconcile each tail-affected node: EVICT its OLD postings (reverse
        //    map) then RE-DERIVE its CURRENT postings from the engine (identical
        //    to how the full rebuild derives them, so the result is key-for-key
        //    AND count-for-count equal to a rebuild). Handles all shapes:
        //      * INSERT (no old entry → nothing to evict; add current),
        //      * in-place VALUE change (evict old value posting; add new value —
        //        the count moves from old value to new),
        //      * DELETE (evict old; getNode == null → add nothing),
        //      * unchanged page-mate (evict then re-add the SAME → net no-op).
        //    A superset from `tailAffectedNodeIds` is harmless (idempotent).
        for (ids) |node_id| {
            // (a) EVICT old postings via the reverse map (no value decode).
            if (rev.keysFor(node_id)) |old_keys| {
                for (old_keys) |encoded_key| {
                    mg.exact_node_property_index.removeByEncodedKey(encoded_key, node_id);
                }
            }

            // (b) RE-DERIVE current postings from the engine's CURRENT state.
            const node_shard = mg.shardEngineForNode(node_id);
            const maybe_rec = node_shard.getNode(node_id) catch {
                mg.exact_node_property_index.clear();
                return false;
            };
            const rec = maybe_rec orelse continue; // deleted/tombstoned → evict-only
            // Mirror rebuildExactNodePropertyIndex's per-node derivation EXACTLY.
            if (rec.label_head == 0 or rec.prop_head == 0) continue;
            const label_ids = node_shard.label_store.getLabels(rec.label_head, mg.engine.allocator) catch {
                mg.exact_node_property_index.clear();
                return false;
            };
            defer mg.engine.allocator.free(label_ids);
            addNodePropertiesForLabels(mg, node_id, label_ids, rec.prop_head) catch {
                mg.exact_node_property_index.clear();
                return false;
            };
        }

        _ = g_exact_index_reconciled.fetchAdd(1, .monotonic);
        mg.exact_lean_gen.store(lean_gen, .release);
        return true;
    }

    /// GAP-ENT-0048 Task 5.3b: spawn a BACKGROUND thread that rebuilds a
    /// reopen-deferred (stale-snapshot) exact index via the RACE-FREE
    /// hydration-scan build (`buildAndPersistExactIndexForHydratedGraph`:
    /// parallel `rebuildExactNodePropertyIndex` under the build mutex + a direct
    /// shard-mutex-only persist — no `mg.rwlock`, no checkpoint rwlock race),
    /// instead of leaving the whole O(graph) rebuild for the first client query
    /// to pay INLINE. Tracked in `exact_persist_threads` (joined by `deinit`,
    /// which sets `exact_persist_shutdown` first so a late reopen refuses to
    /// spawn). Reuses the H4 persist-on-build lifecycle + `graph_name` ownership
    /// (dupe here, worker frees). Best-effort and non-fatal: on ANY spawn failure
    /// the index simply stays deferred and the first access rebuilds it (the
    /// pre-5.3b behaviour). Idempotent against a racing first-access build — both
    /// gate on the `exact_index_built` latch under the build mutex.
    fn spawnExactIndexRebuildOnReopen(self: *StorageAdapter, mg: *ManagedGraph, graph_name: []const u8) void {
        const name_copy = self.allocator.dupe(u8, graph_name) catch {
            log.warn("reopen eager exact-index rebuild skipped: OOM duping graph name '{s}'", .{graph_name});
            return;
        };
        const io = std.Io.Threaded.global_single_threaded.io();
        self.exact_persist_mutex.lockUncancelable(io);
        defer self.exact_persist_mutex.unlock(io);
        if (self.exact_persist_shutdown) {
            self.allocator.free(name_copy);
            return;
        }
        // Reserve BEFORE spawning so a post-spawn OOM never leaks an unjoinable
        // thread.
        self.exact_persist_threads.ensureUnusedCapacity(self.allocator, 1) catch {
            self.allocator.free(name_copy);
            log.warn("reopen eager exact-index rebuild skipped: OOM reserving thread slot for '{s}'", .{graph_name});
            return;
        };
        // GAP-0064 FIX A: publish "a background rebuild owns this build" BEFORE
        // the worker exists, so the worker (which CLEARS this flag when done) can
        // never race ahead of this store and leave it stuck true. Cleared again
        // if the spawn itself fails (below). While set: the hydration fold no-ops
        // and `checkpointOneGraph` skips the (double-inserting) eager build.
        mg.exact_rebuild_inflight.store(true, .release);
        const t = std.Thread.spawn(.{}, exactIndexRebuildOnReopenWorker, .{ self, name_copy }) catch |err| {
            mg.exact_rebuild_inflight.store(false, .release);
            self.allocator.free(name_copy);
            log.warn("reopen eager exact-index rebuild skipped: thread spawn failed for '{s}': {}", .{ graph_name, err });
            return;
        };
        self.exact_persist_threads.appendAssumeCapacity(t);
        _ = g_exact_reopen_spawns.fetchAdd(1, .monotonic);
    }

    /// Worker for `spawnExactIndexRebuildOnReopen`: run the race-free build (which
    /// no-ops if a first-access build already latched `built`) and free the owned
    /// name. `buildAndPersistExactIndexForHydratedGraph` is itself best-effort and
    /// logs its own outcome; a graph DROPped between spawn and run fails the name
    /// lookup inside and leaves nothing to build (correct).
    fn exactIndexRebuildOnReopenWorker(self: *StorageAdapter, graph_name: []u8) void {
        defer self.allocator.free(graph_name);
        // GAP-0064 FIX A: `true` = the owning background worker — bypass the fold
        // no-op gate, run the build, and clear `exact_rebuild_inflight` on exit.
        self.buildAndPersistExactIndexForHydratedGraphEx(graph_name, true);
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
        if (comptime @import("builtin").is_test) {
            // SONNY-1574 (fix pass 1574b): test-only fault injection — see
            // `setForceGraphDirPathFailureForTesting`.
            if (g_test_force_graph_dir_path_failure) return error.OutOfMemory;
        }
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

    // CANARY: REQ=REQ-SONNY-6430-SECURITY-AUDIT-FAIL-CLOSED; FEATURE="Security Graph Audit"; ASPECT=NoUnauditedOpen; STATUS=TESTED; TEST=tests/test_sonny6430_storage_open_fail_closed.zig; OWNER=security; UPDATED=2026-11-12
    /// The security graph's audit logger (only `__geode_security` has one).
    /// Every failure is an error, so the graph never opens unaudited.
    /// SONNY-6422 made an unusable GEODE_AUDIT_PUB/GEODE_AUDIT_SEC pair an
    /// error; SONNY-6430: so is everything else. An audit log that cannot be
    /// opened (EACCES, a read-only directory), whose tail does not verify, or
    /// any allocation failure returned null, and the security graph opened
    /// with no audit logger: every auth change went unaudited. No error is
    /// one to carry on past: the open fails and the caller (the server's
    /// startup, or the CLI) reports it. SONNY-6435: hence no optional in the
    /// type; the caller owns the returned logger.
    pub fn initAuditForGraph(allocator: Allocator, data_dir: []const u8, graph_uuid: [16]u8) !*audit.AuditLogger {
        if (try audit.AuditLogger.loadEnvSigningKey(allocator)) |kp| {
            var k = kp;
            k.deinit();
        }
        const graph_dir = try graphDirPath(allocator, data_dir, graph_uuid);
        defer allocator.free(graph_dir);

        const al = try allocator.create(audit.AuditLogger);
        errdefer allocator.destroy(al);
        al.* = audit.AuditLogger.initForGraph(allocator, graph_dir) catch |err| {
            // The caller reports the refusal (the server does not start).
            log.warn("cannot open the security graph's audit log in {s}: {}; refusing to open the graph unaudited", .{ graph_dir, err });
            return err;
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
            .audit_logger = if (is_security_graph) try initAuditForGraph(self.allocator, self.data_dir, graph_uuid) else null,
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

        // SONNY-6384: before any write can land in a WAL that recovery would skip.
        healWalLsnAnchor(engine) catch |err| {
            log.err("failed to anchor the WAL LSNs of graph '{s}' at their last checkpoint: {}", .{ name, err });
            return err;
        };

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
            .audit_logger = if (is_security_graph) try initAuditForGraph(self.allocator, self.data_dir, graph_uuid) else null,
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

        // Try loading the persisted property index if it is CURRENT on the
        // WAL-aware Path B contract (GAP-ENT-0048): its `checkpoint_epoch` stamp
        // matches the engine's current epoch AND no committed WAL tail advanced
        // the durable frontier past its covered_lsn. Otherwise fall back to a
        // race-free hydration/lazy rebuild (never a stale serve).
        // SONNY-6354: the late-key generation is read before the key
        // configuration the file must match (see `tryReconcileExactIndexOnReopen`).
        const load_lean_gen = graph_store.leanLateGenMax();
        const load_outcome: ExactIndexLoadOutcome = blk: {
            const dir_path = graphDirPath(self.allocator, self.data_dir, graph_uuid) catch break :blk .absent;
            defer self.allocator.free(dir_path);
            break :blk mg.exact_node_property_index.loadFromFile(dir_path, mgCheckpointEpoch(mg), mgDurableFrontierLsn(mg), graph_store.exactIndexConfigHash());
        };
        const loaded_from_disk = load_outcome == .loaded;
        if (loaded_from_disk) {
            // Persisted snapshot loaded: the index is complete and ready.
            mg.exact_lean_gen.store(load_lean_gen, .release);
            mg.exact_index_built.store(true, .release);
            // GAP-ENT-0048 PRIMARY: record the O(snapshot) reload so a test can
            // prove the reopen engaged the index WITHOUT an O(graph) rebuild.
            _ = g_exact_index_reloaded.fetchAdd(1, .monotonic);
        } else {
            // H4 (cold-open phase 1): the persisted snapshot was stale (epoch
            // mismatch or a WAL tail past its covered_lsn — GAP-ENT-0048 Path B),
            // so the index must be REBUILT from the durable pages. DEFER it out of
            // the open path (a synchronous O(graph) rebuild would blow the
            // sub-second cold-open budget — ~1.5-2h at 14.27M). Every index
            // accessor guards on `exact_index_built`; the eventual rebuild goes
            // through the race-free parallel scan (`rebuildExactNodePropertyIndex`)
            // and re-persists on the epoch contract (checkpointOneGraph →
            // saveToFile), so the NEXT reopen reloads it. Crash-safe (rebuild
            // reads durable pages; epoch/covered-gated by loadFromFile on reopen).
            mg.exact_index_built.store(false, .release);

            // GAP-0064 FIX A: PROACTIVELY drive the deferred rebuild through the
            // RACE-FREE hydration-scan build on a background thread NOW for BOTH a
            // `.stale` (snapshot present but epoch-mismatched / WAL-tail-past-covered)
            // AND an `.absent` (never persisted — from-dump bulk ingest, legacy,
            // LIGHT-only) reopen, rather than leaving the O(graph) build to be
            // FOLDED synchronously onto the first-touch hydration read path (the
            // 14.27M "reopen blocks ALL reads ~30 min" enterprise blocker) or paid
            // INLINE on the first client query (the "85s lazy-on-first-query"
            // wedge). Open itself only SPAWNS the thread — server-ready is
            // unchanged, and the fold (`buildAndPersistExactIndexForHydratedGraph`)
            // no-ops while `exact_rebuild_inflight` is set, so `count(:Taxon)` /
            // label scans return after resident loop1/loop2 (not after the build).
            //
            // CAVEAT (adversarial review — residual): index-served reads (WHERE-seek
            // / GROUP BY / DISTINCT) issued DURING the background build do NOT
            // scan-fallback today — `ensureExactNodePropertyIndexBuilt` acquires the
            // shared `exact_index_build_mutex` (uncancellable), so such a query
            // BLOCKS behind the in-flight build until it publishes (up to ~14 min at
            // 14.27M on the FIRST reopen of a from-dump store). count/label scans are
            // unaffected. The 2nd reopen reloads the persisted index, so this window
            // only exists on the one-time first-reopen build. A future refinement
            // (decline the exact-index fast-path → scan while a build is in flight)
            // would keep those queries responsive during the build.
            //
            // Was (pre-FIX-A): only `.stale` spawned; `.absent` stayed on the lazy
            // path and its build was folded into hydration (blocking every reader).
            if (!eagerExactRebuildOnReopenDisabled()) {
                var reconciled = false;
                if (load_outcome == .stale) {
                    // GAP-ENT-0048 crash-reconcile (Phase E2): for a present-but-
                    // stale snapshot, first attempt an O(tail) RECONCILE of the
                    // committed WAL tail into it (evict each tail node's OLD
                    // postings via the reverse map + re-derive its CURRENT postings
                    // from the engine). Sound ONLY on the single-recovery gate; on
                    // ANY doubt it returns false and we fall back to the background
                    // rebuild. Inline + pre-publish → race-free, O(tail)-bounded.
                    // (`.absent` has no persisted base to reconcile into — skip
                    // straight to the background rebuild.)
                    reconciled = blk: {
                        const dir_path = graphDirPath(self.allocator, self.data_dir, graph_uuid) catch break :blk false;
                        defer self.allocator.free(dir_path);
                        break :blk self.tryReconcileExactIndexOnReopen(mg, dir_path);
                    };
                }
                if (reconciled) {
                    mg.exact_index_built.store(true, .release);
                    log.info("exact property index RECONCILED from WAL tail for graph '{s}' (O(tail), no rebuild)", .{name});
                } else {
                    self.spawnExactIndexRebuildOnReopen(mg, owned_name);
                    log.info("exact property index deferred for graph '{s}' ({s} → race-free background rebuild)", .{
                        name,
                        if (load_outcome == .stale) "stale snapshot" else "absent snapshot",
                    });
                }
            } else {
                log.info("exact property index deferred for graph '{s}' (lazy first-access rebuild; eager reopen rebuild disabled)", .{name});
            }
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

    /// SONNY-6433: `resolveLabelScanContext` with the graph pinned
    /// (SONNY-3028), so it stays allocated while the caller reads it between
    /// lock holds. The caller unpins it (`unpinGraph`); null pins nothing.
    fn pinLabelScanContext(self: *StorageAdapter, graph_name: []const u8, label: []const u8) !?LabelScanContext {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const mg = try self.requireExistingGraphLocked(graph_name);
        const label_id = mg.label_dict.getId(label) orelse return null;
        _ = mg.pins.fetchAdd(1, .acq_rel);
        return .{
            .mg = mg,
            .label_id = label_id,
        };
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

    // CANARY: REQ=REQ-SONNY-3131-CHECKPOINT-DROPPED-GRAPH; FEATURE="MultiGraphIsolation"; ASPECT=RegistryHeaderSkipsLostEntry; STATUS=TESTED; TEST=tests/test_sonny3131_checkpoint_dropped_graph.zig; OWNER=storage; UPDATED=2026-09-27
    /// The registry header's next node and edge ids: the largest of every
    /// entry's, read from the engine of a loaded graph and from the manifest
    /// on disk of one that is not.
    ///
    /// SONNY-3131: an entry whose manifest cannot be read (its files are gone)
    /// is skipped and logged at error level, and the header's current ids are
    /// kept as a floor, so the skipped entry cannot lower them. Its error failed
    /// the whole save, on every save that followed: graphs created later were
    /// never written to the registry, and were gone after a restart.
    fn refreshRegistryHeaderNextIdsLocked(self: *StorageAdapter) void {
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

            const manifest = self.loadPersistedManifestLocked(entry.uuid) catch |err| {
                slog.err("graph registry entry has no readable manifest; it is skipped in the registry header's next ids", &.{
                    SAttr.string("graph", entry.name),
                    SAttr.err("error", err),
                });
                next_node_id = @max(next_node_id, self.registry.next_node_id);
                next_edge_id = @max(next_edge_id, self.registry.next_edge_id);
                continue;
            };
            next_node_id = @max(next_node_id, manifest.next_node_id);
            next_edge_id = @max(next_edge_id, manifest.next_edge_id);
        }

        self.registry.next_node_id = next_node_id;
        self.registry.next_edge_id = next_edge_id;
    }

    fn saveRegistryLocked(self: *StorageAdapter) !void {
        self.refreshRegistryHeaderNextIdsLocked();
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
        try reserveGraphLockSlot(); // SONNY-6433
        const mg = self.pinGraph(graph_name) orelse return error.GraphNotFound;
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
        // SONNY-3028: dropped while this thread waited for its lock.
        if (mg.isDropped()) {
            mg.rwlock.unlockShared(std.Io.Threaded.global_single_threaded.io());
            self.unpinGraph(mg);
            return error.GraphNotFound;
        }
        const hold_start_ns = monoNanosNow();
        noteGraphLockTaken(mg); // SONNY-6375
        noteReadLockTaken(mg);
        return .{ .mg = mg, .hold_start_ns = hold_start_ns };
    }

    pub fn releaseGraphReadLock(self: *StorageAdapter, mg: *ManagedGraph, hold_start_ns: u64, site_tag: graph_store.LockSiteTag) void {
        // SONNY-3028: the pin `acquireGraphReadLock` took goes with the lock.
        defer self.unpinGraph(mg);
        noteReadLockReleased(mg);
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
        noteGraphLockReleased(mg); // SONNY-6375
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
        try reserveGraphLockSlot(); // SONNY-6433
        // SONNY-3028: pinned until `releaseGraphWriteLock`.
        const mg = self.pinGraph(graph_name) orelse return error.GraphNotFound;
        errdefer self.unpinGraph(mg);
        // SONNY-3029: no group-commit batch transaction stays open under it.
        claimWriteLock(mg, null) catch unreachable;
        errdefer unclaimWriteLock(mg);
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
            return lockedUnlessDropped(mg);
        }
        var sleep_ns: u64 = 100 * std.time.ns_per_us;
        const max_sleep_ns: u64 = 2 * std.time.ns_per_ms;
        while (true) {
            const req = std.os.linux.timespec{
                .sec = @intCast(sleep_ns / std.time.ns_per_s),
                .nsec = @intCast(sleep_ns % std.time.ns_per_s),
            };
            std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
            if (mg.rwlock.tryLock(io)) {
                _ = mg.rwlock_exclusive_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
                return lockedUnlessDropped(mg);
            }
            sleep_ns = @min(sleep_ns * 2, max_sleep_ns);
        }
    }

    /// SONNY-3029: open a group-commit batch's statement transaction on `mg`
    /// (see `ManagedGraph.batch_txns_open`): waits while a thread holds or
    /// waits for the graph's write lock. The caller holds no graph lock, and
    /// calls `leaveBatchTxn` once the transaction committed or aborted.
    pub fn enterBatchTxn(_: *StorageAdapter, mg: *ManagedGraph) void {
        var nap_ns: u64 = 20 * std.time.ns_per_us;
        while (true) {
            if (mg.write_lock_claims.load(.seq_cst) == 0) {
                _ = mg.batch_txns_open.fetchAdd(1, .seq_cst);
                if (mg.write_lock_claims.load(.seq_cst) == 0) return;
                _ = mg.batch_txns_open.fetchSub(1, .seq_cst);
            }
            napNs(nap_ns);
            nap_ns = @min(nap_ns * 2, std.time.ns_per_ms);
        }
    }

    pub fn leaveBatchTxn(_: *StorageAdapter, mg: *ManagedGraph) void {
        _ = mg.batch_txns_open.fetchSub(1, .seq_cst);
    }

    /// SONNY-3029: announce this thread's claim on `mg`'s write lock, and wait
    /// until no group-commit batch has a transaction open on it (`Deadline`
    /// past `deadline_mono_ns`, the claim withdrawn). Batches opening one
    /// wait meanwhile. `unclaimWriteLock` withdraws it.
    fn claimWriteLock(mg: *ManagedGraph, deadline_mono_ns: ?u64) error{Deadline}!void {
        _ = mg.write_lock_claims.fetchAdd(1, .seq_cst);
        var nap_ns: u64 = 20 * std.time.ns_per_us;
        while (mg.batch_txns_open.load(.seq_cst) != 0) {
            if (deadline_mono_ns) |dl| {
                if (monoNanosNow() >= dl) {
                    unclaimWriteLock(mg);
                    return error.Deadline;
                }
            }
            napNs(nap_ns);
            nap_ns = @min(nap_ns * 2, std.time.ns_per_ms);
        }
    }

    fn unclaimWriteLock(mg: *ManagedGraph) void {
        _ = mg.write_lock_claims.fetchSub(1, .seq_cst);
    }

    fn napNs(ns: u64) void {
        const req = std.os.linux.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
    }

    /// SONNY-3028: `mg`, whose write lock this thread just took, or
    /// `GraphNotFound` (the lock let go again) when it was dropped while the
    /// thread waited. The caller's errdefer unpins it.
    fn lockedUnlessDropped(mg: *ManagedGraph) !*ManagedGraph {
        if (mg.isDropped()) {
            mg.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());
            return error.GraphNotFound;
        }
        mg.write_holder.store(currentThreadTag(), .release);
        noteGraphLockTaken(mg); // SONNY-6375
        return mg;
    }

    /// SONNY-6425 item 5: the graphs whose read lock this thread holds
    /// through `acquireGraphReadLock` (a graph held twice has depth 2); see
    /// `threadHoldsGraphReadLock`. A thread holds a handful at most; one
    /// taken while all slots are in use is counted in
    /// `t_read_locks_untracked`.
    const HeldReadLock = struct { mg: ?*ManagedGraph = null, depth: u32 = 0 };
    threadlocal var t_read_locks: [8]HeldReadLock = [_]HeldReadLock{.{}} ** 8;
    threadlocal var t_read_locks_untracked: u32 = 0;

    fn noteReadLockTaken(mg: *ManagedGraph) void {
        for (&t_read_locks) |*held| {
            if (held.mg == mg) {
                held.depth += 1;
                return;
            }
        }
        for (&t_read_locks) |*held| {
            if (held.depth == 0) {
                held.* = .{ .mg = mg, .depth = 1 };
                return;
            }
        }
        t_read_locks_untracked += 1;
    }

    fn noteReadLockReleased(mg: *ManagedGraph) void {
        for (&t_read_locks) |*held| {
            if (held.mg == mg and held.depth > 0) {
                held.depth -= 1;
                if (held.depth == 0) held.mg = null;
                return;
            }
        }
        if (t_read_locks_untracked > 0) t_read_locks_untracked -= 1;
    }

    /// SONNY-3135 (N7c): this thread's tag for `ManagedGraph.write_holder`.
    fn currentThreadTag() u64 {
        return @as(u64, std.Thread.getCurrentId()) + 1;
    }

    // CANARY: REQ=REQ-SONNY-6425-DROP-OWN-READ-LOCK; FEATURE="MultiGraphIsolation"; ASPECT=ReadHolderTracking; STATUS=TESTED; TEST=tests/test_sonny6425_drop_under_own_read_lock.zig; OWNER=storage; UPDATED=2026-11-12
    /// SONNY-6425 item 5: does the calling thread hold `graph_name`'s read
    /// lock through the graph lock API (`acquireGraphReadLock`)? `dropGraph`
    /// refuses then: its write-lock acquire would wait for this thread's own
    /// shared hold forever. True also when the thread holds more read locks
    /// than the per-thread table records (it cannot tell, so it refuses). A
    /// brief lookup under `mutex` (tier 0); no graph lock is taken.
    pub fn threadHoldsGraphReadLock(self: *StorageAdapter, graph_name: []const u8) bool {
        if (t_read_locks_untracked > 0) return true;
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(graph_name) orelse return false;
        for (t_read_locks) |held| {
            if (held.mg == mg and held.depth > 0) return true;
        }
        return false;
    }

    /// SONNY-3135 (N7c): does the calling thread hold `graph_name`'s write
    /// lock through the graph lock API? A brief lookup under `mutex` (tier
    /// 0); no graph lock is taken.
    pub fn threadHoldsGraphWriteLock(self: *StorageAdapter, graph_name: []const u8) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(graph_name) orelse return false;
        return mg.write_holder.load(.acquire) == currentThreadTag();
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
        try reserveGraphLockSlot(); // SONNY-6433
        // SONNY-3028: pinned until `releaseGraphWriteLock`.
        const mg = self.pinGraph(graph_name) orelse return error.GraphNotFound;
        errdefer self.unpinGraph(mg);
        // SONNY-3029: no group-commit batch transaction stays open under it.
        try claimWriteLock(mg, deadline_mono_ns);
        errdefer unclaimWriteLock(mg);

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
            return lockedUnlessDropped(mg);
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
                std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
            }
            if (mg.rwlock.tryLock(io)) {
                _ = mg.rwlock_exclusive_wait_ns_total.fetchAdd(monoNanosNow() -| _t_start, .monotonic);
                return lockedUnlessDropped(mg);
            }
            sleep_ns = @min(sleep_ns * 2, max_sleep_ns);
        }
    }

    pub fn releaseGraphWriteLock(self: *StorageAdapter, mg: *ManagedGraph) void {
        mg.write_holder.store(0, .release);
        noteGraphLockReleased(mg); // SONNY-6375
        mg.rwlock.unlock(std.Io.Threaded.global_single_threaded.io());
        unclaimWriteLock(mg);
        // SONNY-3028: and the pin the acquire took. A graph this thread
        // dropped while it held the lock is freed here, when no other thread
        // holds or waits for it.
        self.unpinGraph(mg);
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
        // SONNY-2978: the statement's transaction must not hold its shard's
        // WAL batch across the adapter calls it spans.
        releaseSpanningTxnWalBatch(mg, txn_id) catch |err| {
            // error-policy: A — nothing was logged in it; the abort record
            // is best-effort, recovery treats an unfinished txn as aborted.
            mg.engine.abortTxn(txn_id) catch {};
            return err;
        };
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
        // SONNY-2978: the session's transaction must not hold its shard's
        // WAL batch across the adapter calls it spans.
        releaseSpanningTxnWalBatch(mg, txn_id) catch |err| {
            // error-policy: A — nothing was logged in it; the abort record
            // is best-effort, recovery treats an unfinished txn as aborted.
            mg.engine.abortTxn(txn_id) catch {};
            return err;
        };
        out.* = .{
            .mg = mg,
            .txn_id = txn_id,
            .graph_name = mg.name,
        };
        t_session_engine_txn = out;
    }

    /// R9: commit the session-scoped engine txn → ONE WAL fsync.
    /// SONNY-2823: `commitThreadSessionTxn`, reporting a missing one.
    pub fn commitSessionTxn(self: *StorageAdapter) !void {
        _ = self;
        if (t_session_engine_txn == null) return error.NoActiveSessionTxn;
        try commitThreadSessionTxn();
    }

    /// R9: abort the session-scoped engine txn (no data-durability fsync).
    pub fn abortSessionTxn(self: *StorageAdapter) void {
        _ = self;
        abortThreadSessionTxn();
    }

    /// R9 (2026-04-22, lazy): open a session-scoped engine txn, for the
    /// executor's first mutation in a Geode BEGIN TX … COMMIT.
    ///
    /// SONNY-2823: into the slot of the session whose request runs on this
    /// thread; with no slot installed, `error.NoSessionEngineTxnSlot` (the
    /// caller uses a per-statement transaction). It used a thread-local slot,
    /// which outlived the request on a pooled thread.
    pub fn beginSessionTxnLazy(self: *StorageAdapter, graph_name: []const u8) !void {
        const slot = t_session_engine_slot orelse return error.NoSessionEngineTxnSlot;
        try self.beginSessionTxn(graph_name, &slot.txn);
        slot.graph_uuid = slot.txn.mg.uuid;
        slot.open = true;
    }

    /// SONNY-2823: is `mg`, of the graph with UUID `graph_uuid`, one of this
    /// adapter's open graphs? `mg` is compared as a pointer first, and read
    /// only once it is found in the map: it may have been freed with a
    /// dropped graph. The UUID tells a graph created again at the freed
    /// address from the one the transaction was opened on.
    /// SONNY-3028: `engineIsOpen`, and when it is, a pin on `mg`
    /// (`ManagedGraph.pins`) under the same hold of the adapter's mutex. The
    /// caller unpins it (`unpinGraph`).
    pub fn pinIfOpen(self: *StorageAdapter, mg: *ManagedGraph, graph_uuid: [16]u8) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        var it = self.engines.valueIterator();
        while (it.next()) |v| {
            if (v.* == mg) {
                if (!std.mem.eql(u8, &mg.uuid, &graph_uuid)) return false;
                _ = mg.pins.fetchAdd(1, .acq_rel);
                return true;
            }
        }
        return false;
    }

    /// SONNY-3033: open `graph_name`'s graph when it exists (loaded, or in
    /// the registry), without creating it: `GraphNotFound` otherwise.
    pub fn openExistingGraph(self: *StorageAdapter, graph_name: []const u8) !*ManagedGraph {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        return self.requireExistingGraphLocked(graph_name);
    }

    /// SONNY-3028: pin `graph_name`'s graph (`ManagedGraph.pins`) for a caller
    /// that uses it outside the adapter's mutex, or null when it is not open.
    /// The caller unpins it (`unpinGraph`).
    pub fn pinGraph(self: *StorageAdapter, graph_name: []const u8) ?*ManagedGraph {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const mg = self.engines.get(graph_name) orelse return null;
        _ = mg.pins.fetchAdd(1, .acq_rel);
        return mg;
    }

    /// SONNY-3028: drop a pin on `mg`. The last pin of a dropped graph frees
    /// it; `dropGraph` already took it out of `engines`, deleted its files and
    /// its registry entry, so nothing is checkpointed.
    pub fn unpinGraph(self: *StorageAdapter, mg: *ManagedGraph) void {
        const prev = mg.pins.fetchSub(1, .acq_rel);
        if (prev == (ManagedGraph.dropped_bit | 1)) mg.deinit(self.allocator, true);
    }

    pub fn engineIsOpen(self: *StorageAdapter, mg: *const ManagedGraph, graph_uuid: [16]u8) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        var it = self.engines.valueIterator();
        while (it.next()) |v| {
            if (v.* == mg) return std.mem.eql(u8, &mg.uuid, &graph_uuid);
        }
        return false;
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

/// A property value's part of a MERGE tuple lock's hash
/// (`mergeTupleLockIndex`). Two values MERGE finds equal must hash alike, or
/// two concurrent MERGEs of the key take different locks and both create a
/// node.
///
/// SONNY-2806 (round 8): a number hashes by its value
/// (`value_order.writeNumberKey`, the bytes MERGE's index and the exact index
/// compare), whatever its representation: INT 7, DECIMAL 7.0, a SMALLINT 7
/// and a DOUBLE 7.0 alike, and DOUBLE 7.5 with DECIMAL 7.50. It hashed its
/// representation, and every extended value (a DOUBLE, a SMALLINT) one tag,
/// so two bulk MERGEs of 7 and 7.0 created two nodes (6000 nodes for 3000
/// keys in the round-7 review's probe). Any other extended value still
/// hashes by its tag alone: equal ones share a lock, as do unequal ones.
fn hashPropertyValue(seed: u64, value: graph_store.PropertyValue) u64 {
    var h = seed;
    if (graph_store.GraphStore.numberOfProperty(value)) |n| {
        // The longest key is 18 bytes ('C', the i128 coefficient, the scale).
        var buf: [32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        value_order.writeNumberKey(&w, n) catch unreachable;
        h = std.hash.Wyhash.hash(h, "N");
        return std.hash.Wyhash.hash(h, w.buffered());
    }
    const tag: u8 = switch (value) {
        .String => 1,
        .Bool => 4,
        .Null => 5,
        .ExtValue => 6,
        // Numbers hash by value above.
        .Int, .Float, .Decimal => unreachable,
    };
    h = std.hash.Wyhash.hash(h, &[_]u8{tag});
    switch (value) {
        .String => |s| h = std.hash.Wyhash.hash(h, s),
        .Bool => |b| h = std.hash.Wyhash.hash(h, if (b) &[_]u8{1} else &[_]u8{0}),
        .Null, .ExtValue => {},
        .Int, .Float, .Decimal => unreachable,
    }
    return h;
}

/// Whether two stored properties are equal, as the executor's
/// `execution.valuesEqual` decides: numbers by exact value (1 and 1.0), a
/// duration by its length, and every extended value (a DOUBLE, a SMALLINT, a
/// date, ...) decoded first. SONNY-2806 (round 7): this compared by
/// representation and an extended value never, so the multi-property MERGE
/// fallback created a node on every `MERGE (:T {a: 1, d: date(...)})`, and
/// `{a: 1}` did not find a stored 1.0.
fn propertyValuesEqual(a: graph_store.PropertyValue, b: graph_store.PropertyValue) bool {
    return value_equality.valuesEqual(property_codec.propertyValueToValue(a), property_codec.propertyValueToValue(b));
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
    return copySmallestExactCandidates(allocator, mg, label, props);
}

/// `copySmallestMergePropCandidates` on an index already built: the slot ids
/// of the smallest exact-index posting among `props`' values (empty when any
/// value has no posting).
fn copySmallestExactCandidates(
    allocator: Allocator,
    mg: *ManagedGraph,
    label: []const u8,
    props: []const StorageAdapter.PropKV,
) ![]u64 {
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

// CANARY: REQ=REQ-SONNY-2976-MERGE-TENANT-SCOPE; FEATURE="MergeRowVisibility"; ASPECT=BulkMergeTenantScope; STATUS=TESTED; TEST=tests/test_sonny2976_merge_fast_path_tenant_scope.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-2976: the tenant a bulk MERGE of a request tagged `request_tenant`
/// matches within: that tenant, or null (every tenant) for an unscoped
/// request (`default` or empty). The same rule as
/// `tenancy.resolveTenantFilter` in non-strict mode (under strict tenancy
/// the QUIC gate refuses an unscoped request before any fast path), and as
/// the general executor's MERGE, which confines a match to the session's
/// exact tenant (`crud_operations.nodeMatchesPattern`). MERGE's property
/// index has no tenant in its key, so without this a request of tenant B
/// matched, rewrote and answered tenant A's node.
fn mergeTenantScope(request_tenant: []const u8) ?[]const u8 {
    if (request_tenant.len == 0 or std.mem.eql(u8, request_tenant, graph_store.DEFAULT_TENANT_ID)) return null;
    return request_tenant;
}

fn nodeMatchesMergeProps(node: *const graph_store.Node, graph_name: []const u8, label: []const u8, props: []const StorageAdapter.PropKV, tenant: ?[]const u8) bool {
    if (!std.mem.eql(u8, node.graph_name, graph_name)) return false;
    if (tenant) |t| if (!std.mem.eql(u8, node.tenant_id, t)) return false;
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
    tenant: ?[]const u8,
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
            // The composite merge index is a MAINTAINED, EXACT node-property
            // index keyed on ALL merge props (see registerCompositeMergeKey /
            // addNodeCompositeMergeEntries). An authoritative composite probe is
            // therefore an exact node-property index SEEK — the indexed dedup
            // fast path, NOT a label scan. Count it toward the same instrument
            // the single-prop (getCandidateNodesByLabelAndProperty) and the
            // exact-fallback (copySmallestMergePropCandidates) probes bump, so a
            // caller (REQ-QUIC-HC-109) can assert the fast indexed path was taken
            // (getExactNodePropertyLookupCount > 0) and no label scan happened
            // (getLabelScanLookupCount == 0). Instrumentation only — the dedup
            // result and durability are unchanged.
            .found => {
                _ = g_exact_node_property_lookup_count.fetchAdd(1, .monotonic);
                // SONNY-2976: the composite entry names the lowest holder in
                // ANY tenant. Of another tenant, it is not this request's
                // match and does not prove it has none: search the request's
                // holders below.
                const t = tenant orelse return cid;
                if (try store.nodeTaggedTenant(cid, t)) return cid;
            },
            .not_found => {
                _ = g_exact_node_property_lookup_count.fetchAdd(1, .monotonic);
                return null;
            },
            // Value type can't be encoded into the composite key — fall through
            // to the exact-index candidate seek (guarded + eviction-safe below),
            // which bumps the exact-lookup instrument itself.
            .not_indexable => {},
        }
    }

    // Fallback (no registered composite, or an unencodable value type): the
    // exact-index candidate seek reads store IdMap (loop1) + node cache (loop2),
    // so it needs the same hydration chokepoint before it can trust them.
    // ensureGraphHydrated is a lock-free atomic fast-path once built.
    store.ensureGraphHydrated(graph_name);

    // SONNY-2806 (round 8): in lean mode (GEODE_INDEX_MERGE_KEYS_ONLY) the
    // exact index holds no value of a key registered after its nodes were
    // written, so the MERGE that registers the key would find none of them
    // and create a second node (`{a: 1.5, b: 'k'}` after
    // `CREATE (:T {a: 1.5, b: 'k'})`). Scan the label instead.
    if (graph_store.leanIndexingEnabled()) return lowestLabelNodeMatchingMergeProps(allocator, store, graph_name, label, props, tenant);

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

    // SONNY-2806 (round 7): the LOWEST matching node id, the node the merge
    // index and the executor's label scan answer with, whatever the posting
    // order.
    var lowest: ?u64 = null;
    for (candidates) |slot_id| {
        const public_id = @as(u64, @truncate(id_map.nodeUuid(slot_id) orelse continue));
        if (lowest) |l| if (public_id >= l) continue;
        // GAP-0046: hydrate-on-miss. Under a bounded node cache (or right after a
        // deferred reopen) the matching node need not be resident; a plain
        // `getPtr` would miss it and the MERGE would wrongly create a duplicate.
        const node = (store.nodes.getOrHydratePtr(public_id) catch null) orelse continue;
        if (nodeMatchesMergeProps(node, graph_name, label, props, tenant)) lowest = public_id;
    }
    return lowest;
}

/// The lowest node of `label` matching every `props` value, by a scan of the
/// label's postings in ascending id order (lean mode; `findNodeMatchingMergeProps`).
fn lowestLabelNodeMatchingMergeProps(
    allocator: Allocator,
    store: *graph_store.GraphStore,
    graph_name: []const u8,
    label: []const u8,
    props: []const StorageAdapter.PropKV,
    tenant: ?[]const u8,
) !?u64 {
    const ids = (try store.snapshotNodesByLabel(allocator, graph_name, label)) orelse return null;
    defer allocator.free(ids);
    const Check = struct {
        graph_name: []const u8,
        label: []const u8,
        props: []const StorageAdapter.PropKV,
        tenant: ?[]const u8,

        fn matches(c: @This(), node: *const graph_store.Node) bool {
            return nodeMatchesMergeProps(node, c.graph_name, c.label, c.props, c.tenant);
        }
    };
    const check = Check{ .graph_name = graph_name, .label = label, .props = props, .tenant = tenant };
    for (ids) |id| {
        if (try store.residentNodeSatisfies(id, check, Check.matches)) return id;
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
    // Pass an explicit cross-platform timestamp: uuid.newV7()'s default clock
    // issues a raw Linux-only clock_gettime syscall that faults (SIGSYS,
    // uncatchable) on non-Linux hosts (macOS CI). std.time.milliTimestamp()
    // is portable; newV7AtTime never touches that clock for a one-shot call.
    return (uuid.newV7AtTime(@as(i64, @intCast(graph_store.realtimeMillis()))) catch unreachable).bytes;
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
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
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
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
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
            std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
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

    try adapter.dropGraph("drop_me");
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
    try adapter.dropGraph("__geode_security");

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

// CANARY: REQ=REQ-SONNY-6345-AUTH-VERIFY-NO-STATE; FEATURE="OfflineAuthStoreSafety"; ASPECT=ReadOnlyRegistryProbe; STATUS=TESTED; TEST=tests/test_sonny6345_auth_cli_and_grant.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6345: whether the store in `data_dir` registers a graph named
/// `name`, read from its `graph_registry.dat` without opening, creating or
/// locking anything (`StorageAdapter.init` creates the directory and the
/// registry). False when the directory or the registry does not exist.
pub fn graphRegisteredOnDisk(allocator: std.mem.Allocator, data_dir: []const u8, name: []const u8) !bool {
    const registry_path = try std.fmt.allocPrint(allocator, "{s}/graph_registry.dat", .{data_dir});
    defer allocator.free(registry_path);
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), registry_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    var registry = gs.registry.GraphRegistry.init(allocator);
    defer registry.deinit();
    try registry.loadFromFile(registry_path);
    return registry.findByName(name) != null;
}
