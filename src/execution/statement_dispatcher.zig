const std = @import("std");
const ast = @import("../gql/ast.zig");
const graph_store = @import("../graph_store.zig");
const index_manager = @import("../index/index_manager.zig");
const catalog_mod = @import("../schema/catalog.zig");
const advanced_types = @import("../index/advanced_types_index.zig");

// GAP-0717 / issue #717 (2026-04-16): deleted a 1,114-LOC stale clone of
// executeStatementWithContext plus its private resolveLimitParam helper and
// ~15 dead execution.*/fle_*/value_types imports.  The live dispatcher lives
// in src/execution.zig (line ~919).  The three helpers below are the only
// exports still called from elsewhere (execution.zig:1264 and 1353).

// CANARY: REQ=REQ-ENG-USING-VECTOR-BUILDS-INDEX; FEATURE="VectorIndex"; ASPECT=RuntimeTypeMapping; STATUS=TESTED; TEST=tests/test_using_vector_index.zig; OWNER=index; UPDATED=2026-08-25
/// The parser maps BOTH `USING vector` and `USING HNSW` to `ast.IndexType
/// .vector`, and only `USING vector_f32` to `.vector_f32`. This function used
/// to return null for `.vector`, so the two spellings users actually write
/// created NO runtime index at all: the catalog row existed, SHOW INDEXES
/// listed it, and every knn query silently fell back to the brute-force
/// `scanVectorKnn` path. `.vector` and `.vector_f32` are the same runtime HNSW
/// index; they are only different SPELLINGS of it.
pub fn toRuntimeAdvancedIndexType(index_type: ast.IndexType) ?index_manager.IndexManager.IndexType {
    return switch (index_type) {
        .vector, .vector_f32 => .vector_f32,
        .spatial_geographic => .spatial_geographic,
        .network_cidr => .network_cidr,
        .signature_crypto => .signature_crypto,
        .interval_tree => .interval_tree,
        .jsonb_inverted => .jsonb_inverted,
        .domain_trie => .domain_trie,
        else => null,
    };
}

pub fn runtimeAdvancedIndexTypeFromCatalog(type_name: []const u8) ?index_manager.IndexManager.IndexType {
    // "vector" is the catalog spelling for both `USING vector` and
    // `USING HNSW`; it maps to the same runtime HNSW index as "vector_f32".
    // Without this the DROP path could not release the runtime index it now
    // builds for those spellings.
    if (std.mem.eql(u8, type_name, "vector_f32") or std.mem.eql(u8, type_name, "vector")) return .vector_f32;
    if (std.mem.eql(u8, type_name, "spatial_geographic")) return .spatial_geographic;
    if (std.mem.eql(u8, type_name, "network_cidr")) return .network_cidr;
    if (std.mem.eql(u8, type_name, "signature_crypto")) return .signature_crypto;
    if (std.mem.eql(u8, type_name, "interval_tree") or std.mem.eql(u8, type_name, "IntervalTree")) return .interval_tree;
    if (std.mem.eql(u8, type_name, "jsonb_inverted") or std.mem.eql(u8, type_name, "JsonbInverted")) return .jsonb_inverted;
    if (std.mem.eql(u8, type_name, "domain_trie") or std.mem.eql(u8, type_name, "DomainTrie")) return .domain_trie;
    return null;
}

// CANARY: REQ=REQ-ENG-3912-VECTOR-DIM-LIFECYCLE; FEATURE="VectorIndex"; ASPECT=DimValidationRehydrate; STATUS=TESTED; TEST=tests/test_eng3912_dim_pinning.zig; OWNER=index; UPDATED=2026-08-25
/// ENG-3912(d): make sure the vector dimension guard is armed for the
/// (label, property) a vector is about to be written to.
///
/// `registerVectorDimValidation` used to be called ONLY from DDL execution, so
/// the guard existed for exactly as long as the process that ran the
/// `CREATE INDEX` did. After a restart the catalog still listed the index,
/// `SHOW INDEXES` still reported it, and a mixed-dimension write was accepted
/// without a murmur.
///
/// The re-arming is LAZY — driven from the write chokepoint rather than from
/// catalog load — for two reasons:
///   * it allocates only for properties that are actually vector-indexed AND
///     actually written to, instead of adding process-global state to every
///     caller that merely opens a catalog;
///   * the catalog is the source of truth for which (label, property) pairs
///     are indexed, and it is already loaded by the time any write runs.
///
/// The DIMENSION is not persisted anywhere; `IndexManager.seedVectorDim`
/// derives it from the first vector already committed under the pair, which
/// keeps the on-disk catalog format unchanged and cannot pin a dimension no
/// stored vector has.
///
/// Idempotent and cheap after the first call: `registerVectorDimValidation`
/// returns immediately for a name it already holds.
pub fn armVectorDimGuard(
    allocator: std.mem.Allocator,
    labels: []const []const u8,
    property: []const u8,
) !void {
    if (labels.len == 0) return;
    const execution = @import("../execution.zig");
    const catalog = execution.getCatalogInstanceIfPresent() orelse return;

    var iter = catalog.indexes.iterator();
    while (iter.next()) |entry| {
        const info = entry.value_ptr.*;
        if (info.columns.len != 1) continue;
        if (!std.mem.eql(u8, info.columns[0], property)) continue;
        if (!std.mem.eql(u8, info.index_type, "vector") and
            !std.mem.eql(u8, info.index_type, "vector_f32")) continue;
        var covers = false;
        for (labels) |label| {
            if (std.mem.eql(u8, info.table_name, label)) {
                covers = true;
                break;
            }
        }
        if (!covers) continue;

        const manager = try index_manager.ensureGlobalIndexManager(allocator);
        try manager.registerVectorDimValidation(info.name, info.table_name, info.columns[0]);
    }
}

// CANARY: REQ=REQ-ADVANCED-INDEX-RESTART-REBUILD; FEATURE="VectorIndex"; ASPECT=LazyRebuildAfterRestart; STATUS=TESTED; TEST=tests/test_advanced_index_restart.zig; OWNER=index; UPDATED=2026-08-25
/// Rebuild the advanced (HNSW) vector index for `property` from the catalog, if
/// one is recorded there and the runtime has none.
///
/// ADVANCED-INDEX-RESTART: `ensureAdvancedRuntimeIndex` below is the ONLY site
/// that builds an advanced index, and it runs from CREATE INDEX execution only.
/// Nothing rebuilt on catalog reload, so after a restart the catalog (and
/// SHOW INDEXES) still described a vector index that no longer existed, and
/// `evalVectorKnn` quietly fell back to the brute-force `scanVectorKnn` — right
/// answers, O(n) per query, no diagnostic. The database advertised an index it
/// was not using.
///
/// The rebuild is LAZY — driven from the knn read path, the same shape as
/// `armVectorDimGuard` above — rather than eager at startup:
///   * it pays the scan only for a property that is actually queried, instead
///     of adding an unbounded startup cost proportional to every vector index
///     in the catalog (a cost every restart would pay even for indexes nothing
///     touches);
///   * the catalog is the source of truth and is already loaded by the time any
///     query runs, so there is no ordering constraint to satisfy;
///   * it is bounded: exactly one rebuild per index per process, because the
///     first call registers the index and every later call returns at the
///     `findAdvancedVectorIndexForProperty` check below.
///
/// The rebuilt index gets the metric the DDL recorded (persisted with the
/// catalog row — see `IndexInfo.metric`), not a guessed `l2`, and it arms the
/// ENG-3912 dimension guard exactly as the DDL path does.
///
/// The catalog map is read WITHOUT taking `catalog.rwlock`, matching
/// `armVectorDimGuard` above. Taking it here would risk the exclusive-then-
/// shared self-deadlock this codebase has already been bitten by (see the
/// CREATE INDEX note in src/execution.zig), because this runs deep inside
/// expression evaluation with no knowledge of what the statement above holds.
/// The residual is a narrow race with a concurrent DROP INDEX; every string the
/// build below keeps is duplicated by the index manager, so the exposure is
/// limited to this call's own reads.
pub fn ensureAdvancedVectorIndexForProperty(allocator: std.mem.Allocator, property: []const u8) !void {
    // Already registered in this process — the overwhelmingly common case, and
    // what keeps a per-query call cheap.
    if (index_manager.getGlobalIndexManager()) |existing| {
        // Existence probe only — `hasAdvancedVectorIndexForProperty` resolves
        // it under the registry mutex and lets nothing escape, unlike
        // `findAdvancedVectorIndexForProperty`, whose borrowed `meta.name` a
        // concurrent DROP INDEX frees.
        if (existing.hasAdvancedVectorIndexForProperty(property)) return;
    }

    const execution = @import("../execution.zig");
    const catalog = execution.getCatalogInstanceIfPresent() orelse return;

    // Find the catalog row BEFORE touching the index manager, so a property
    // with no recorded vector index never causes one to be created.
    var iter = catalog.indexes.iterator();
    const info = while (iter.next()) |entry| {
        const candidate = entry.value_ptr.*;
        if (candidate.columns.len != 1) continue;
        if (!std.mem.eql(u8, candidate.columns[0], property)) continue;
        if (!std.mem.eql(u8, candidate.index_type, "vector") and
            !std.mem.eql(u8, candidate.index_type, "vector_f32")) continue;
        break candidate;
    } else return;

    // The index manager and every HNSW graph inside it are PROCESS-lifetime, so
    // they must not be built from the caller's allocator here: this runs inside
    // a read query, whose allocator is the per-request arena. A manager created
    // from that arena keeps a dangling vtable pointer the moment the request
    // ends, and the next search faults inside the hnsw library (verified: a GP
    // fault in `searchLayer`). `smp_allocator` is the governance-approved
    // process-lifetime choice — page_allocator is forbidden in src/ — and is
    // the same precedent the adapter-registry lifetime fix set in
    // src/eval_extended.zig. If a manager already exists this argument is
    // ignored, so no other call site's ownership changes.
    const manager = try index_manager.ensureGlobalIndexManager(std.heap.smp_allocator);
    if (manager.hasAdvancedVectorIndexForProperty(property)) return;

    // Same order as ensureAdvancedRuntimeIndex: arm the dimension guard, create
    // the (empty, dimension-0) wrapper with the RECORDED metric, register the
    // property mapping, then populate from the store.
    try manager.registerVectorDimValidation(info.name, info.table_name, info.columns[0]);
    try manager.createAdvancedVectorIndex(info.name, 0, toRuntimeVectorMetric(info.metric));
    try manager.registerAdvancedPropertyIndex(info.name, info.table_name, info.columns[0], .vector_f32);
    // Run inline rather than through `queueOrRunAdvancedIndexBackfill`: the
    // deferral queue exists to get a backfill out of the CREATE INDEX EXCLUSIVE
    // write lock, and this path runs under a read query, which holds no
    // exclusive lock and needs the index for the query in hand.
    try manager.rebuildAdvancedIndex(graph_store.getGlobalStore(allocator), info.name);
}

// CANARY: REQ=REQ-ENG-USING-VECTOR-BUILDS-INDEX; FEATURE="VectorIndex"; ASPECT=MetricThreading; STATUS=TESTED; TEST=tests/test_using_vector_index.zig; OWNER=index; UPDATED=2026-08-25
/// Map the metric string the DDL validated (execution.zig, GAP-0918) onto the
/// runtime wrapper's metric. The build site used to hardcode `.l2`, so a
/// validated `metric = 'cosine'` was accepted, recorded nowhere, and the index
/// was built and QUERIED with Euclidean distance — wrong neighbours, no error.
/// An absent metric keeps the historical `.l2` default.
fn toRuntimeVectorMetric(metric: ?[]const u8) advanced_types.VectorIndexWrapper.DistanceMetric {
    const m = metric orelse return .l2;
    if (std.ascii.eqlIgnoreCase(m, "cosine")) return .cosine;
    if (std.ascii.eqlIgnoreCase(m, "dot") or
        std.ascii.eqlIgnoreCase(m, "dot_product") or
        std.ascii.eqlIgnoreCase(m, "inner_product")) return .dot_product;
    // "l2" / "euclidean" and anything the DDL validator already accepted.
    return .l2;
}

pub fn ensureAdvancedRuntimeIndex(
    allocator: std.mem.Allocator,
    index_name: []const u8,
    label: []const u8,
    properties: [][]const u8,
    index_type: ast.IndexType,
    metric: ?[]const u8,
) !void {
    // CANARY: REQ=REQ-GAP-0918-VECTOR-INDEX-VALIDATION; FEATURE="VectorIndex"; ASPECT=DimValidationRegistration; STATUS=TESTED; TEST=tests/test_gap0918_vector_validation.zig; OWNER=index; UPDATED=2026-07-10
    // GAP-0918: register vector-indexed (label, property) pairs for the
    // dimension write-check. This is a lightweight validation registry —
    // deliberately NOT the advanced wrapper machinery, whose per-write
    // drop/recreate churns the hnsw thread pool.
    if ((index_type == .vector or index_type == .vector_f32) and properties.len == 1) {
        const manager = try index_manager.ensureGlobalIndexManager(allocator);
        try manager.registerVectorDimValidation(index_name, label, properties[0]);
    }

    const runtime_type = toRuntimeAdvancedIndexType(index_type) orelse return;
    if (properties.len != 1) return error.Unsupported;

    const manager = try index_manager.ensureGlobalIndexManager(allocator);
    switch (runtime_type) {
        .vector_f32 => try manager.createAdvancedVectorIndex(index_name, 0, toRuntimeVectorMetric(metric)),
        .spatial_geographic => try manager.createAdvancedSpatialIndex(index_name),
        .network_cidr => try manager.createAdvancedNetworkIndex(index_name),
        .signature_crypto => try manager.createAdvancedSignatureIndex(index_name),
        .interval_tree => try manager.createAdvancedIntervalIndex(index_name),
        .jsonb_inverted => try manager.createAdvancedJsonbIndex(index_name),
        .domain_trie => try manager.createAdvancedDomainIndex(index_name),
        else => return,
    }
    try manager.registerAdvancedPropertyIndex(index_name, label, properties[0], runtime_type);
    try queueOrRunAdvancedIndexBackfill(allocator, manager, index_name);
}

// CANARY: REQ=REQ-ENG-CREATE-INDEX-BACKFILL-OUTSIDE-WRITE-LOCK; FEATURE="AdvancedIndex"; ASPECT=DeferredBackfill; STATUS=TESTED; TEST=tests/test_create_index_backfill_deferral.zig; OWNER=index; UPDATED=2026-08-25
/// CREATE INDEX used to run its whole backfill INSIDE the per-graph EXCLUSIVE
/// write lock the transport handler holds for the duration of a mutating
/// statement, so every unrelated write in the database — any label, any
/// session — queued behind a full scan of the indexed label (verified >150s of
/// dead air on a large graph).
///
/// The deferral machinery already exists for the incremental rebuilds
/// (`ExecutionContext.pending_index_rebuilds`, GAP-0511): both the QUIC and
/// gRPC handlers RELEASE the exclusive lock and only then call
/// `rebuildPendingIndexes`, which re-takes a SHARED lock. Enqueuing here puts
/// the CREATE INDEX backfill on that same path, so unrelated writers proceed
/// while it runs.
///
/// Falls back to running the backfill inline when there is no queue to put it
/// on (CLI, embedded and test callers, which hold no transport lock and so
/// block nobody).
///
/// REMAINING LIMITATION, stated plainly: the backfill still runs before the
/// statement's response is written, so the CREATING SESSION still waits for
/// it, and it still takes a shared graph lock for the scan, so a concurrent
/// writer on the SAME graph can still be delayed by lock hand-off. Making the
/// backfill genuinely asynchronous (and keeping the index consistent with
/// writes that land while it runs) needs the incremental-maintenance design
/// this cycle deliberately does not attempt.
fn queueOrRunAdvancedIndexBackfill(
    allocator: std.mem.Allocator,
    manager: *index_manager.IndexManager,
    index_name: []const u8,
) !void {
    const execution = @import("../execution.zig");
    if (execution.getActiveContext()) |ctx| {
        if (ctx.pending_index_rebuilds) |rebuilds| {
            // The keys are freed by the handler that owns the map, so they must
            // be duped with ITS allocator.
            const alloc = ctx.pending_index_rebuilds_allocator orelse allocator;
            const name_copy = try alloc.dupe(u8, index_name);
            const gop = rebuilds.getOrPut(name_copy) catch |err| {
                alloc.free(name_copy);
                return err;
            };
            if (gop.found_existing) alloc.free(name_copy);
            return;
        }
    }

    try manager.rebuildAdvancedIndex(graph_store.getGlobalStore(allocator), index_name);
}
