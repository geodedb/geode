// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// CANARY: REQ=REQ-STORAGE-FTS-ADAPTER-001; FEATURE="FTS storage adapter"; ASPECT=Wrapper; STATUS=TESTED; OWNER=core; UPDATED=2026-05-30
//
//! geode-shaped wrapper around the external `fts-storage` library.
//!
//! This file is a pure storage seam: it imports ONLY `std` and the
//! `fts_storage_lib` external module. It deliberately pulls in NO geode
//! internals (no graph_store, no tokenizer, no otel) so it stays cheap to
//! compile and test in isolation via the dedicated `test-fts-storage-adapter`
//! build step. Geode-specific glue (tokenization, node scanning, GQL dispatch)
//! lives in a later layer that consumes this adapter.
//!
//! ## Model
//!
//! - A registry of per-named-index `fts.Engine` instances, each rooted at
//!   `{base_dir}/<name>` where `base_dir` is `{graph_dir}/fts` supplied by the
//!   caller (a later task wires the per-graph fts directory). The adapter owns
//!   the per-index child directories but NOT `base_dir` itself — the caller
//!   opened `base_dir` and must close it AFTER `deinit`.
//! - `doc_id == node_id` (u64) — identity mapping, no translation table.
//!
//! ## Locking (GAP-0278 tiers)
//!
//! - `mu` is a brief registry mutex. It guards the `indexes` map AND every
//!   `IndexEngine.refs` in-flight reference count: acquire, look up / insert /
//!   remove / count, release. It is NEVER held across index or search I/O
//!   (the quiescence wait in `dropIndex` uses `drained.waitUncancelable`,
//!   which releases `mu` while blocked).
//! - Each `IndexEngine.write_mu` is a leaf-level mutex that serializes WRITES
//!   to that one engine, honoring the fts-storage single-writer contract.
//! - Searches do NOT take `write_mu`; multiple concurrent searches against
//!   the same engine are allowed, and the library's internal shared rw-lock
//!   covers reader/writer overlap while the engine is ALIVE. Engine LIFETIME
//!   is NOT covered by that rw-lock — `fts.Engine.deinit` does not take it
//!   and explicitly delegates its quiescence contract to the caller — so
//!   every reader AND writer path pins the engine with an in-flight
//!   reference (`requireIndex` / paired `releaseIndex`), and `dropIndex`
//!   tears an engine down only after its refcount drains to zero. Each
//!   `TermIterator` is fully drained and deinited before returning, so
//!   writers are never starved by a leaked reader.
//! - Lock/wait ordering: `write_mu` is acquired only while holding no other
//!   adapter lock; `releaseIndex` acquires `mu` only after `write_mu` was
//!   released (defer order in the write paths); `dropIndex` never waits for
//!   quiescence while holding `mu` (the condition wait releases it) or
//!   `write_mu` (never taken there at all).
//! - Same-name `createIndex` racing a DRAINING `dropIndex`'s `deleteTree`
//!   (i.e. one thread recreating `name` while another is still inside the
//!   post-quiescence teardown/delete for the SAME name) is only safe because
//!   ALL production callers that invoke `dropIndex` then `createIndex` for
//!   the same name back-to-back — `DROP INDEX` followed by a later
//!   `CREATE INDEX` DDL statement, and `CALL geode.fts.rebuild`'s internal
//!   drop→create — are themselves serialized by the per-graph exclusive
//!   write lock (each is a "mutating" GQL statement; see
//!   `src/execution/procedure_access.zig` classification and
//!   `docs/GQL_AUTH_DDL.md`). That serialization is what guarantees no two
//!   drop→create sequences for the SAME index name ever interleave today. A
//!   future caller that invokes `dropIndex`/`createIndex` directly — outside
//!   statement execution, bypassing that per-graph lock — would reintroduce
//!   the race.
//! - `rebuilds` (Task 3, geode-vectorization-and-reranking): a SEPARATE small
//!   registry, also guarded by `mu`, that lets `CALL geode.fts.rebuild`
//!   queue concurrent writers across its drop→create→backfill window instead
//!   of either erroring on a momentarily-absent engine or double-indexing
//!   past the backfill snapshot. See the `rebuilds` field doc comment for
//!   the full model, including a documented narrow-race residual.

const std = @import("std");
const fts = @import("fts_storage_lib");

/// A single search result. `node_id == doc_id` by construction.
pub const Hit = struct {
    node_id: u64,
    score: f32,
};

/// A search result carrying the term's token-positions inside the document.
/// Positions are the raw-stream token ordinals supplied at index time (the
/// fts-storage positional contract — see the lib's `TermIterator.Match`).
/// `positions` is owned by the caller (duped out of the iterator, which only
/// lends its slice until the next `next()`); free each entry's positions and
/// the outer slice — or use `freePositionalHits`.
pub const PositionalHit = struct {
    node_id: u64,
    score: f32,
    positions: []u32,
};

/// Free a slice returned by `searchPositions`.
pub fn freePositionalHits(allocator: std.mem.Allocator, hits: []PositionalHit) void {
    for (hits) |h| allocator.free(h.positions);
    if (hits.len > 0) allocator.free(hits);
}

pub const Error = error{
    IndexExists,
    IndexNotFound,
    /// Task 3 (geode-vectorization-and-reranking): `beginRebuild` was called
    /// for an index name that is already mid-rebuild (a prior `beginRebuild`
    /// has not yet been paired with `endRebuild`).
    RebuildInProgress,
};

pub const FtsStorageAdapter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// `{graph_dir}/fts`. Owned by the caller — do NOT close in `deinit`.
    base_dir: std.Io.Dir,
    /// Owned copy of the base dir path, retained for diagnostics / future
    /// path-building needs. Child dirs are created base_dir-relative.
    base_path: []const u8,
    /// Registry of name -> engine wrapper. Guarded by `mu`.
    indexes: std.StringHashMapUnmanaged(*IndexEngine) = .{},
    /// Registry-lookup mutex (brief; never held across I/O). This Zig 0.16
    /// toolchain exposes the Io-integrated `std.Io.Mutex` (lock/unlock take the
    /// `io`) rather than `std.Thread.Mutex`; we use it so the scheduler can see
    /// contention. Stored `self.io` is passed to every lock/unlock.
    mu: std.Io.Mutex = .init,
    /// Paired with `mu`: `dropIndex` waits on this until the target engine's
    /// `refs` drains to zero; `releaseIndex` broadcasts when the last
    /// reference on a dropped engine goes away. Shared adapter-wide (drops
    /// are rare), hence broadcast rather than signal — a single wake could
    /// otherwise land on a dropper waiting for a DIFFERENT engine and be
    /// swallowed by its predicate re-check.
    drained: std.Io.Condition = .init,

    /// Task 3 (geode-vectorization-and-reranking): rebuild-state registry,
    /// keyed by index name. An entry is present while `CALL geode.fts.rebuild`
    /// is mid-flight for that name (between `beginRebuild` and `endRebuild`),
    /// absent otherwise. Guarded by `mu`, same as `indexes` — the two maps
    /// are keyed identically (index name) but are otherwise independent:
    /// `rebuilds` survives the ENGINE's absence (it exists precisely across
    /// the drop→create gap where `indexes` has no entry for the name).
    ///
    /// The value is the deduped set of node ids a concurrent writer observed
    /// via `noteWriteDuringRebuild` during the window, instead of writing
    /// them into the (possibly absent, mid drop→create) engine.
    /// `noteWriteDuringRebuild` is called from
    /// `fts_index_ops.maintainFulltextOnWrite`'s per-node write hook BEFORE
    /// it would otherwise call `indexNode`/`deleteNode` — the caller MUST
    /// skip that write on a `true` return. The rebuild's backfill phase does
    /// NOT consult this map (it re-reads current store state directly);
    /// only the POST-backfill drain in `fts_index_ops.rebuildFulltextIndex`
    /// does, via `endRebuild`, reindexing every pending id NOT already
    /// covered by the backfill snapshot with a plain `.create`-style write —
    /// NEVER delete-then-reindex (fts-storage tombstones are permanent per
    /// doc_id, so a stray delete on a doc_id backfill just wrote would
    /// permanently hide it). A node deleted mid-rebuild whose id ends up
    /// pending is still handled correctly with no special casing: the
    /// drain's write reads the store fresh and naturally no-ops for a node
    /// that no longer exists.
    ///
    /// KNOWN RESIDUAL (narrow TOCTOU, accepted): `noteWriteDuringRebuild`'s
    /// check and the write's own `indexNode`/`deleteNode` call (which
    /// separately pins the engine via `requireIndex`) are two SEPARATE `mu`
    /// critical sections, not one atomic operation — a write whose
    /// pre-check observed "not rebuilding" can still lose a race against
    /// `beginRebuild` immediately followed by `dropIndex`'s registry
    /// removal, landing `Error.IndexNotFound` (silently caught+logged by
    /// every write-hook caller — the SAME fallback behavior every missing-
    /// index write already had before this fix). This window is bounded by
    /// the CPU-only gap between `beginRebuild` and `dropIndex`'s
    /// `fetchRemove` (a couple of statements, no I/O) — NOT by `dropIndex`'s
    /// teardown I/O or the backfill duration, which is what this queue
    /// closes (the dominant, I/O-bound share of the window). Closing the
    /// residual fully would require folding "check rebuilding" and "pin the
    /// engine" into one `mu` critical section shared by every write caller —
    /// but `indexNode`/`deleteNode` are ALSO called directly by the
    /// backfill loop itself (the rebuild's own authoritative writer, which
    /// must NEVER be queued); gating at that shared low level with no
    /// caller-identity signal would silently break backfill instead of
    /// closing the residual. Accepted for now, same posture as the other
    /// documented residuals in this codebase (see CLAUDE.md Known
    /// Limitations).
    rebuilds: std.StringHashMapUnmanaged(std.AutoHashMapUnmanaged(u64, void)) = .{},

    pub const IndexEngine = struct {
        engine: *fts.Engine,
        /// `{base_dir}/<name>`. Opened by the adapter; closed in `deinit`.
        dir: std.Io.Dir,
        /// Owned copy of the index name.
        name: []u8,
        /// Serializes writes to THIS engine (single-writer lib contract).
        write_mu: std.Io.Mutex = .init,
        /// Segment-order guard (Task 13, cluster FTS symmetry): the library's
        /// segment writer DELTA-ENCODES each term's posting doc_ids at flush
        /// time assuming they were appended in ASCENDING order — a smaller
        /// doc_id after a larger one in the same memtable integer-overflows
        /// `doc_id - last_doc_id` (fts-storage src/segment.zig:327). Executor
        /// writes use monotonically-increasing time-based node ids, so this
        /// never fired pre-cluster; raft-apply writes use the GNC2 id band
        /// (~2^40, BELOW the ~2^57 time-based floor), so interleaving the two
        /// produces descending ids. The adapter tracks the largest doc_id
        /// indexed into the CURRENT memtable and force-flushes (sealing the
        /// in-order memtable into a segment) before indexing a smaller id.
        /// Per-segment delta decoding makes overlapping id ranges ACROSS
        /// segments fine. Guarded by `write_mu`; conservative-high after an
        /// engine-internal auto-flush (worst case: one redundant no-op flush).
        max_doc_id_since_flush: u64 = 0,
        /// In-flight reference count, guarded by the ADAPTER's `mu` (never by
        /// `write_mu`). `requireIndex` increments it under `mu` before handing
        /// this pointer out; `releaseIndex` decrements it under `mu` after the
        /// operation fully completes (deferred AFTER the `write_mu` unlock in
        /// write paths, and after iterator teardown in search paths).
        /// `dropIndex` tears the engine down only once this drains to zero, so
        /// a pinned `IndexEngine` — including `engine`, `dir`, `name`, and the
        /// memory `write_mu` itself lives in — is guaranteed alive for the
        /// whole operation (REQ-FTS-DROP-WRITER-RACE-001).
        refs: u32 = 0,
        /// Set true by `dropIndex` (atomic store, inside its `mu` critical
        /// section) the moment the index is removed from the registry — i.e.
        /// BEFORE teardown, while the engine is still alive. Write paths
        /// (`indexNode`, `indexNodeBatch`, `deleteNode`, `flush`) load it
        /// immediately after acquiring `write_mu` and bail with
        /// `Error.IndexNotFound`. That check is a SEMANTIC refusal (don't
        /// apply a write to an index whose on-disk tree is about to be
        /// deleted), NOT the memory-safety mechanism — lifetime is guaranteed
        /// by `refs` above. Atomic because it is written under `mu` but read
        /// under `write_mu`; no single lock covers both sides. Searches
        /// deliberately skip the check: a search that pinned the engine before
        /// the drop simply completes against the still-alive engine (benign:
        /// results for a just-dropped index).
        dropped: std.atomic.Value(bool) = .init(false),
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        base_dir: std.Io.Dir,
        base_path: []const u8,
    ) !*FtsStorageAdapter {
        const self = try allocator.create(FtsStorageAdapter);
        errdefer allocator.destroy(self);

        const path_copy = try allocator.dupe(u8, base_path);
        errdefer allocator.free(path_copy);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .base_dir = base_dir,
            .base_path = path_copy,
            .indexes = .{},
            .mu = .init,
            .drained = .init,
        };
        return self;
    }

    /// Flush + tear down every engine, close each index dir, free names and the
    /// registry map and base_path, then destroy self. Does NOT close base_dir
    /// (caller owns it and must close it after this returns). Shutdown-time
    /// quiescence is the CALLER's contract (no in-flight adapter operations may
    /// exist when this runs) — `refs` is not consulted here.
    pub fn deinit(self: *FtsStorageAdapter) void {
        var it = self.indexes.iterator();
        while (it.next()) |entry| {
            const ie = entry.value_ptr.*;
            // error-policy: A — best-effort durability: fts.Engine.deinit does
            // NOT flush, so we flush here before tearing the engine down.
            // Swallow errors — deinit must not fail, and a flush failure on
            // shutdown leaves the WAL as the recovery source of truth.
            ie.engine.flush() catch {};
            ie.engine.deinit();
            ie.dir.close(self.io);
            self.allocator.free(ie.name);
            self.allocator.destroy(ie);
        }
        self.indexes.deinit(self.allocator);

        // Defensive: a rebuild should always have paired begin/end by the
        // time shutdown runs (no in-flight adapter operations may exist per
        // this function's contract), but free any leftover entries rather
        // than leak.
        var rit = self.rebuilds.iterator();
        while (rit.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.rebuilds.deinit(self.allocator);

        self.allocator.free(self.base_path);
        self.allocator.destroy(self);
    }

    /// Create-vs-open intent for `openOrCreate`. `create` requires the on-disk
    /// index dir to NOT already exist; `open` requires it to already exist.
    /// This makes the two public entry points clean complements across adapter
    /// restarts: the on-disk dir is the source of truth, not just the in-memory
    /// registry (a fresh adapter's registry is empty even when an index is
    /// durably present on disk).
    const Intent = enum { create, open };

    /// True if `{base_dir}/<name>` already exists on disk. Uses `access`, which
    /// is a pure existence probe — no directory is created as a side effect.
    fn indexDirExists(self: *FtsStorageAdapter, name: []const u8) bool {
        self.base_dir.access(self.io, name, .{}) catch return false;
        return true;
    }

    /// Create a brand-new index named `name`. Errors `IndexExists` if one is
    /// already registered in-memory OR already present on disk. Creates
    /// `{base_dir}/<name>/` and initializes a fresh engine over it.
    pub fn createIndex(self: *FtsStorageAdapter, name: []const u8) !void {
        try self.openOrCreate(name, .create);
    }

    /// Open an EXISTING on-disk index named `name`, replaying its WAL/segments
    /// via `Engine.init`. Errors `IndexExists` if already registered in-memory,
    /// or `IndexNotFound` if no on-disk dir exists for `name`. A later task
    /// decides create-vs-open at the call site; both are implemented here so
    /// reopen-after-restart is exercised.
    pub fn openIndex(self: *FtsStorageAdapter, name: []const u8) !void {
        try self.openOrCreate(name, .open);
    }

    /// Shared create/open path. `intent` gates on the on-disk dir's prior
    /// existence (see `Intent`); both paths then `createDirPathOpen` the child
    /// dir and `Engine.init` over it (Engine.init replays whatever is on disk,
    /// so it is correct for both a fresh and an existing directory).
    fn openOrCreate(self: *FtsStorageAdapter, name: []const u8, intent: Intent) !void {
        // Pre-check the in-memory registry (brief lock) and the on-disk state
        // before doing any allocation or directory I/O. The definitive
        // duplicate-name guard is re-checked under the lock at insert time.
        {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            if (self.indexes.contains(name)) return Error.IndexExists;
        }
        const exists = self.indexDirExists(name);
        switch (intent) {
            .create => if (exists) return Error.IndexExists,
            .open => if (!exists) return Error.IndexNotFound,
        }

        // Open (creating if needed) the per-index child dir base_dir-relative
        // via std.Io.Dir.createDirPathOpen(dir, io, sub_path, options) — this
        // is the same call the fts-storage example uses, but rooted at our
        // base_dir instead of cwd so child paths stay tidy.
        var child = try self.base_dir.createDirPathOpen(self.io, name, .{});
        errdefer child.close(self.io);

        // single_writer_thread_check = false: geode's QUIC server drives the engine
        // from a worker-thread pool, so init and a later flush/deinit/index/delete
        // can run on different threads. Concurrency is still enforced by the
        // adapter's per-engine write_mu plus the engine's rw_lock (writers
        // exclusive / readers shared); only the thread-identity debug assert is
        // disabled. Without this, DROP INDEX / teardown on a different worker thread
        // tripped assertOwnedByCurrentThread and crashed the server (fts-storage 0.1.1).
        const engine = try fts.Engine.initWithConfig(self.io, self.allocator, child, .{
            .single_writer_thread_check = false,
        });
        errdefer engine.deinit();

        // Segment-order guard priming (WAL-replay reopen hole): Engine.init
        // replays the WAL into a fresh memtable, which may already contain
        // high (time-band, ~2^57) doc_ids — but IndexEngine starts with
        // max_doc_id_since_flush = 0, so a subsequent SMALLER (GNC2-band,
        // ~2^40) id would pass guardPostingOrder and hit the segment-flush
        // delta-encoding overflow. Force one flush right after `.open`: an
        // empty replayed memtable makes this a no-op (engine.zig:1024), and a
        // non-empty one gets sealed into a segment — either way tracker=0 is
        // then truthful.
        if (intent == .open) try engine.flush();

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const ie = try self.allocator.create(IndexEngine);
        errdefer self.allocator.destroy(ie);
        ie.* = .{
            .engine = engine,
            .dir = child,
            .name = name_copy,
            .write_mu = .init,
        };

        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        // Re-check under the lock to close the create/open race: another thread
        // may have inserted the same name between our pre-check and here.
        if (self.indexes.contains(name)) {
            // Roll back everything we built optimistically.
            engine.deinit();
            child.close(self.io);
            self.allocator.free(name_copy);
            self.allocator.destroy(ie);
            return Error.IndexExists;
        }
        try self.indexes.put(self.allocator, name_copy, ie);
    }

    /// Remove the registry entry, wait for every in-flight reference to
    /// drain, then flush + tear down the engine, close its dir, best-effort
    /// delete its on-disk tree, and free the wrapper. Errors `IndexNotFound`
    /// if no such index.
    ///
    /// Refcounted quiescence (REQ-FTS-DROP-WRITER-RACE-001): every operation
    /// that touches `ie.engine` — writers (`indexNode`, `indexNodeBatch`,
    /// `deleteNode`, `flush`) AND searches (`search`, `searchPositions`) —
    /// pins the wrapper via `requireIndex` (refs++ under `mu`) and releases it
    /// only after the operation fully completes. After the map removal below,
    /// `requireIndex` can hand out no NEW references; waiting for `refs == 0`
    /// therefore guarantees no thread holds (or will ever again obtain) this
    /// pointer before we deinit the engine and free the allocation. This is
    /// what makes teardown safe: the library's `Engine.deinit` takes no
    /// internal lock and delegates its quiescence contract to the caller, and
    /// a straggler locking/unlocking `write_mu` inside a freed `IndexEngine`
    /// would be a use-after-free even if it never touched `engine`.
    ///
    /// The wait uses the adapter's `drained` condition paired with `mu`
    /// (`waitUncancelable` releases `mu` while blocked, so registry lookups
    /// for OTHER indexes are never stalled), and no lock is held during the
    /// teardown I/O. Teardown stays SYNCHRONOUS by design: `geode.fts.rebuild`
    /// does drop→create on the same name, so the on-disk tree must be gone
    /// before this returns.
    // CANARY: REQ=REQ-FTS-DROP-WRITER-RACE-001; FEATURE="FullText"; ASPECT=DropDrainsWriters; STATUS=TESTED; TEST=tests/test_fts_storage_adapter.zig; OWNER=fts; UPDATED=2026-08-29
    pub fn dropIndex(self: *FtsStorageAdapter, name: []const u8) !void {
        self.mu.lockUncancelable(self.io);
        const kv = self.indexes.fetchRemove(name) orelse {
            self.mu.unlock(self.io);
            return Error.IndexNotFound;
        };
        const ie = kv.value;
        // Semantic refusal marker for stragglers that pinned `ie` before the
        // removal above but haven't reached their `write_mu` section yet: they
        // observe `dropped` and return `Error.IndexNotFound` instead of
        // applying a write to an index whose on-disk tree is about to be
        // deleted. (Their memory safety comes from the refcount, not this.)
        ie.dropped.store(true, .release);
        // Quiescence: drain every in-flight reader/writer. The predicate is
        // re-checked under `mu` on every wake, and `releaseIndex` broadcasts
        // when the last reference on a dropped engine goes away.
        while (ie.refs != 0) self.drained.waitUncancelable(self.io, &self.mu);
        self.mu.unlock(self.io);

        // Sole owner from here: the map entry is gone and refs drained to
        // zero, so no other thread holds this pointer. Lock-free teardown.
        // error-policy: A — the index is being dropped and its on-disk tree
        // deleted below; a failed final flush cannot lose anything we keep.
        ie.engine.flush() catch {};
        ie.engine.deinit();
        ie.dir.close(self.io);
        // error-policy: A — best-effort on-disk cleanup. std.Io.Dir.deleteTree
        // exists, so we can recursively remove the child tree base_dir-relative.
        // Failure (e.g. ENOENT, EACCES) is non-fatal: the index is already gone
        // from the registry and a stale on-disk dir is harmless until next boot.
        self.base_dir.deleteTree(self.io, name) catch {};
        self.allocator.free(ie.name);
        self.allocator.destroy(ie);
    }

    /// Resolve the engine wrapper for `name`, or null. Brief registry lookup.
    /// Takes NO in-flight reference — the returned pointer is NOT protected
    /// against a concurrent `dropIndex`. External callers use this strictly
    /// as an existence probe (`== null`); any operation that dereferences the
    /// engine must go through the adapter's own methods, which pin via
    /// `requireIndex`.
    pub fn getIndex(self: *FtsStorageAdapter, name: []const u8) ?*IndexEngine {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.indexes.get(name);
    }

    /// Resolve the engine wrapper for `name` and pin it with an in-flight
    /// reference (refs++ under `mu`). EVERY caller must pair this with
    /// `releaseIndex` via a `defer` placed on the line IMMEDIATELY after this
    /// call, before any other early return can fire — the reference is what
    /// keeps `dropIndex` from deiniting the engine and freeing the wrapper
    /// out from under the operation. Never call twice for the same operation
    /// without releasing in between.
    fn requireIndex(self: *FtsStorageAdapter, name: []const u8) !*IndexEngine {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const ie = self.indexes.get(name) orelse return Error.IndexNotFound;
        ie.refs += 1;
        return ie;
    }

    /// Drop the in-flight reference taken by `requireIndex`. When the last
    /// reference on a dropped engine drains, wakes `dropIndex`'s quiescence
    /// wait. In write paths the pairing `defer` runs AFTER the `write_mu`
    /// unlock (LIFO defer order), so `mu` is never acquired while `write_mu`
    /// is held.
    fn releaseIndex(self: *FtsStorageAdapter, ie: *IndexEngine) void {
        self.mu.lockUncancelable(self.io);
        ie.refs -= 1;
        const wake = ie.refs == 0 and ie.dropped.load(.acquire);
        self.mu.unlock(self.io);
        // Broadcast, not signal: `drained` is shared adapter-wide, and a
        // single wake could land on a dropper waiting for a different engine
        // (whose predicate re-check would swallow it). Waking outside the
        // critical section is safe — the waiter registered itself before
        // releasing `mu` inside `waitUncancelable`, so no wakeup is lost.
        // Mechanically (lib/std/Io.zig `Condition.waitInner`): a waiter
        // increments `state.waiters` and captures the current `epoch` BEFORE
        // calling `mutex.unlock(io)` to park — so by the time we can even
        // acquire `mu` above (`dropIndex` must have already unlocked it to
        // reach `waitInner`'s futex wait), it is already counted. `broadcast`
        // claims that count via a CAS loop and bumps `epoch` before
        // futex-waking; the waiter's futex wait compares against the epoch
        // it captured, so the wake is observed whether it lands just before
        // the futex call (the CAS/epoch bump already happened) or while
        // parked (the futex wake fires) — no lost-wakeup window either way.
        // This deliberately DIFFERS from `group_commit.zig`'s
        // `signal(io)`-while-`queue_mutex`-held idiom: holding the lock
        // across signal is also correct there, just sometimes wasteful (a
        // woken waiter can immediately re-block on the still-held lock).
        // Here `dropIndex`'s `waitUncancelable` reacquires `mu` on every wake
        // specifically to re-check `refs`, so broadcasting AFTER releasing
        // `mu` avoids handing the woken waiter a lock we are still holding.
        if (wake) self.drained.broadcast(self.io);
    }

    /// Task 3 (geode-vectorization-and-reranking): register `index_name` as
    /// currently rebuilding — see the `rebuilds` field doc comment for the
    /// full model. Errors `Error.RebuildInProgress` if `index_name` is
    /// already rebuilding (a concurrent `CALL geode.fts.rebuild` on the SAME
    /// index is refused rather than two drop→create sequences racing each
    /// other for the same on-disk tree).
    // CANARY: REQ=REQ-FTS-REBUILD-WINDOW-001; FEATURE="CALL geode.fts.rebuild"; ASPECT=RebuildStateRegistry; STATUS=TESTED; TEST=tests/test_fts_rebuild.zig; OWNER=fts; UPDATED=2026-08-29
    pub fn beginRebuild(self: *FtsStorageAdapter, index_name: []const u8) !void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.rebuilds.contains(index_name)) return Error.RebuildInProgress;
        const name_copy = try self.allocator.dupe(u8, index_name);
        errdefer self.allocator.free(name_copy);
        try self.rebuilds.put(self.allocator, name_copy, .{});
    }

    /// MUST be called with `mu` already held. Shared by `noteWriteDuringRebuild`
    /// (the public pre-check called from `maintainFulltextOnWrite`, before it
    /// would otherwise reach `indexNode`/`deleteNode`) — kept as a tiny
    /// locked-body helper so both call sites stay in sync.
    fn queueIfRebuildingLocked(self: *FtsStorageAdapter, index_name: []const u8, node_id: u64) bool {
        const pending = self.rebuilds.getPtr(index_name) orelse return false;
        // error-policy: A — best-effort queue insert. An OOM here during an
        // active rebuild is already a broader failure mode; still returning
        // `true` (skip the live write) is strictly safer than the
        // alternative of writing to a possibly-absent engine mid
        // drop→create — a lost queue entry degrades to the SAME
        // caught+logged `IndexNotFound` outcome writes already tolerated
        // before this fix, rather than a new failure mode.
        pending.put(self.allocator, node_id, {}) catch {};
        return true;
    }

    /// Task 3: if `index_name` is currently rebuilding, queue `node_id` into
    /// its pending set (deduped — re-queuing the same id is a no-op) and
    /// return `true`. The caller (`fts_index_ops.maintainFulltextOnWrite`)
    /// MUST skip the live engine write for this id on a `true` return — the
    /// rebuild's post-backfill drain (`endRebuild`) will reindex it from
    /// current store state. Returns `false` when `index_name` is not
    /// rebuilding (the normal path — nothing queued, caller proceeds as
    /// usual). See the `rebuilds` field doc comment for the documented
    /// narrow-race residual this pre-check does not fully close on its own.
    // CANARY: REQ=REQ-FTS-REBUILD-WINDOW-001; FEATURE="CALL geode.fts.rebuild"; ASPECT=ConcurrentWriteQueued; STATUS=TESTED; TEST=tests/test_fts_rebuild.zig; OWNER=fts; UPDATED=2026-08-29
    pub fn noteWriteDuringRebuild(self: *FtsStorageAdapter, index_name: []const u8, node_id: u64) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.queueIfRebuildingLocked(index_name, node_id);
    }

    /// Task 3: atomically clear the rebuilding flag for `index_name` and
    /// return its drained pending node ids as an `allocator`-owned slice
    /// (caller frees it). After this returns, `noteWriteDuringRebuild`
    /// returns `false` again for `index_name`. A name that was never
    /// rebuilding (or already drained) returns an empty slice — defensive;
    /// every real call site pairs this with a prior successful
    /// `beginRebuild`.
    // CANARY: REQ=REQ-FTS-REBUILD-WINDOW-001; FEATURE="CALL geode.fts.rebuild"; ASPECT=RebuildStateRegistry; STATUS=TESTED; TEST=tests/test_fts_rebuild.zig; OWNER=fts; UPDATED=2026-08-29
    pub fn endRebuild(self: *FtsStorageAdapter, index_name: []const u8, allocator: std.mem.Allocator) ![]u64 {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const kv = self.rebuilds.fetchRemove(index_name) orelse return &[_]u64{};
        var pending = kv.value;
        defer pending.deinit(self.allocator);
        self.allocator.free(kv.key);

        const out = try allocator.alloc(u64, pending.count());
        var it = pending.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) out[i] = k.*;
        return out;
    }

    /// Segment-order guard helper (see `IndexEngine.max_doc_id_since_flush`):
    /// MUST be called with `ie.write_mu` held. Seals the current memtable into
    /// a segment when `incoming_min_doc_id` would land out of order, then
    /// resets the tracker. Equal ids are fine (delta 0), so only strictly
    /// smaller ids force the flush.
    fn guardPostingOrder(ie: *IndexEngine, incoming_min_doc_id: u64) !void {
        if (incoming_min_doc_id < ie.max_doc_id_since_flush) {
            try ie.engine.flush();
            ie.max_doc_id_since_flush = 0;
        }
    }

    /// Index (or re-index) `node_id` with `terms` into `name`. Serialized per
    /// engine via `write_mu`.
    pub fn indexNode(
        self: *FtsStorageAdapter,
        name: []const u8,
        node_id: u64,
        terms: []const fts.TermPosting,
    ) !void {
        const ie = try self.requireIndex(name);
        defer self.releaseIndex(ie);
        ie.write_mu.lockUncancelable(self.io);
        defer ie.write_mu.unlock(self.io);
        // Tail of the dropIndex/writer race (REQ-FTS-DROP-WRITER-RACE-001):
        // this `ie` may have been pinned via requireIndex BEFORE dropIndex
        // removed it from the registry. Our reference keeps the engine alive
        // (dropIndex drains refs before teardown); this check is the semantic
        // refusal — don't apply a write to an index being dropped.
        if (ie.dropped.load(.acquire)) return Error.IndexNotFound;
        try guardPostingOrder(ie, node_id);
        try ie.engine.indexDocument(node_id, terms);
        if (node_id > ie.max_doc_id_since_flush) ie.max_doc_id_since_flush = node_id;
    }

    /// Bulk index a batch of documents (one fsync per batch) into `name`.
    pub fn indexNodeBatch(
        self: *FtsStorageAdapter,
        name: []const u8,
        docs: []const fts.DocBatch,
    ) !void {
        const ie = try self.requireIndex(name);
        defer self.releaseIndex(ie);
        ie.write_mu.lockUncancelable(self.io);
        defer ie.write_mu.unlock(self.io);
        // Tail of the dropIndex/writer race (REQ-FTS-DROP-WRITER-RACE-001) —
        // see the identical check in `indexNode`.
        if (ie.dropped.load(.acquire)) return Error.IndexNotFound;
        // Segment-order guard: flush ahead of the batch if ANY id in it would
        // land below the memtable's running max, then track the batch max.
        // CALLER CONTRACT: ids WITHIN one batch MUST be ascending — callers
        // (bulk-MERGE reindex) pass store-ordered ascending ids; a fully
        // general per-batch sort is deliberately avoided on this hot path
        // (the debug assert below pins the contract). The single-doc
        // `indexNode` path (executor + raft apply) is fully guarded.
        var batch_min: u64 = std.math.maxInt(u64);
        var batch_max: u64 = 0;
        var prev_id: u64 = 0;
        for (docs, 0..) |d, di| {
            // Within-batch ascending contract (see comment above): a
            // descending pair would delta-overflow the segment writer.
            if (di > 0) std.debug.assert(d.doc_id >= prev_id);
            prev_id = d.doc_id;
            if (d.doc_id < batch_min) batch_min = d.doc_id;
            if (d.doc_id > batch_max) batch_max = d.doc_id;
        }
        if (docs.len > 0) try guardPostingOrder(ie, batch_min);
        try ie.engine.indexDocumentBatch(docs);
        if (batch_max > ie.max_doc_id_since_flush) ie.max_doc_id_since_flush = batch_max;
    }

    /// Tombstone `node_id` in `name`.
    pub fn deleteNode(self: *FtsStorageAdapter, name: []const u8, node_id: u64) !void {
        const ie = try self.requireIndex(name);
        defer self.releaseIndex(ie);
        ie.write_mu.lockUncancelable(self.io);
        defer ie.write_mu.unlock(self.io);
        // Tail of the dropIndex/writer race (REQ-FTS-DROP-WRITER-RACE-001) —
        // see the identical check in `indexNode`.
        if (ie.dropped.load(.acquire)) return Error.IndexNotFound;
        try ie.engine.deleteDocument(node_id);
    }

    /// Force a synchronous flush of `name`'s memtable to a segment.
    pub fn flush(self: *FtsStorageAdapter, name: []const u8) !void {
        const ie = try self.requireIndex(name);
        defer self.releaseIndex(ie);
        ie.write_mu.lockUncancelable(self.io);
        defer ie.write_mu.unlock(self.io);
        // Tail of the dropIndex/writer race (REQ-FTS-DROP-WRITER-RACE-001) —
        // see the identical check in `indexNode`.
        if (ie.dropped.load(.acquire)) return Error.IndexNotFound;
        try ie.engine.flush();
        // Memtable sealed — reset the segment-order tracker.
        ie.max_doc_id_since_flush = 0;
    }

    /// Search `name` for `term`, returning up to `max_results` hits sorted by
    /// score descending (`max_results == 0` means unlimited). The caller owns
    /// the returned slice and must free it with `allocator`.
    ///
    /// The iterator is fully drained and deinited BEFORE returning so the
    /// library's shared rw-lock is released and writers are never blocked by a
    /// leaked reader. No `write_mu` is taken — concurrent searches are allowed
    /// — but the engine IS pinned via the `requireIndex`/`releaseIndex`
    /// in-flight reference for the whole search: the library's rw-lock only
    /// covers reader/writer overlap on a live engine, not engine lifetime
    /// (`Engine.deinit` takes no lock), so the reference is what keeps a
    /// concurrent `dropIndex` from deiniting the engine mid-search. A search
    /// that pinned the engine before a drop completes normally against the
    /// still-alive engine (benign: results for a just-dropped index).
    pub fn search(
        self: *FtsStorageAdapter,
        name: []const u8,
        allocator: std.mem.Allocator,
        term: []const u8,
        max_results: usize,
    ) ![]Hit {
        const ie = try self.requireIndex(name);
        defer self.releaseIndex(ie);

        var hits: std.ArrayListUnmanaged(Hit) = .empty;
        defer hits.deinit(allocator);

        {
            var it = try fts.TermIterator.init(allocator, ie.engine, term);
            defer it.deinit();
            while (try it.next()) |m| {
                try hits.append(allocator, .{ .node_id = m.doc_id, .score = m.score });
            }
        }

        // Sort by score DESC; tie-break on node_id ASC for deterministic order.
        std.mem.sort(Hit, hits.items, {}, lessByScoreDesc);

        const n = if (max_results == 0)
            hits.items.len
        else
            @min(max_results, hits.items.len);

        const out = try allocator.alloc(Hit, n);
        @memcpy(out, hits.items[0..n]);
        return out;
    }

    fn lessByScoreDesc(_: void, a: Hit, b: Hit) bool {
        if (a.score != b.score) return a.score > b.score;
        return a.node_id < b.node_id;
    }

    /// Search `name` for `term`, returning EVERY hit with its token-positions
    /// (no cap — phrase/proximity callers must see all candidate docs before
    /// positional gating). Positions are duped: the lib's `Match.positions` is
    /// only valid until the iterator advances, so each slice is copied out
    /// before `next()` is called again. Sorted by node_id ascending for
    /// deterministic downstream intersection. Caller owns the result; free with
    /// `freePositionalHits`.
    ///
    /// Same locking posture as `search`: iterator fully drained + deinited
    /// before returning, no `write_mu` taken, engine pinned against a
    /// concurrent `dropIndex` via the `requireIndex`/`releaseIndex` in-flight
    /// reference for the whole search.
    // CANARY: REQ=REQ-GQL-FTS-ADV-001; FEATURE="Advanced FTS"; ASPECT=PositionalSearch; STATUS=TESTED; TEST=tests/test_fts_storage_adapter.zig; OWNER=index; UPDATED=2026-06-10
    pub fn searchPositions(
        self: *FtsStorageAdapter,
        name: []const u8,
        allocator: std.mem.Allocator,
        term: []const u8,
    ) ![]PositionalHit {
        const ie = try self.requireIndex(name);
        defer self.releaseIndex(ie);

        var hits: std.ArrayListUnmanaged(PositionalHit) = .empty;
        errdefer {
            for (hits.items) |h| allocator.free(h.positions);
            hits.deinit(allocator);
        }

        {
            var it = try fts.TermIterator.init(allocator, ie.engine, term);
            defer it.deinit();
            while (try it.next()) |m| {
                const pos_copy = try allocator.dupe(u32, m.positions);
                errdefer allocator.free(pos_copy);
                try hits.append(allocator, .{
                    .node_id = m.doc_id,
                    .score = m.score,
                    .positions = pos_copy,
                });
            }
        }

        std.mem.sort(PositionalHit, hits.items, {}, struct {
            fn lessThan(_: void, a: PositionalHit, b: PositionalHit) bool {
                return a.node_id < b.node_id;
            }
        }.lessThan);

        return try hits.toOwnedSlice(allocator);
    }
};
