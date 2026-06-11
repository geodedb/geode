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
//! - `mu` is a brief registry-lookup mutex. It guards the `indexes` map only:
//!   acquire, look up / insert / remove a pointer, release. It is NEVER held
//!   across index or search I/O.
//! - Each `IndexEngine.write_mu` is a leaf-level mutex that serializes WRITES
//!   to that one engine, honoring the fts-storage single-writer contract.
//! - Searches do NOT take `write_mu`. They rely on the library's own internal
//!   shared rw-lock (held for the lifetime of a `TermIterator`), so multiple
//!   concurrent searches against the same engine are allowed; a search blocks
//!   writers only for the duration the iterator is alive. The adapter fully
//!   drains and deinits each iterator before returning, so writers are never
//!   starved by a leaked reader.

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

    pub const IndexEngine = struct {
        engine: *fts.Engine,
        /// `{base_dir}/<name>`. Opened by the adapter; closed in `deinit`.
        dir: std.Io.Dir,
        /// Owned copy of the index name.
        name: []u8,
        /// Serializes writes to THIS engine (single-writer lib contract).
        write_mu: std.Io.Mutex = .init,
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
        };
        return self;
    }

    /// Flush + tear down every engine, close each index dir, free names and the
    /// registry map and base_path, then destroy self. Does NOT close base_dir
    /// (caller owns it and must close it after this returns).
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

    /// Flush + tear down the engine, close its dir, best-effort delete its
    /// on-disk tree, then drop the registry entry and free the name. Errors
    /// `IndexNotFound` if no such index.
    pub fn dropIndex(self: *FtsStorageAdapter, name: []const u8) !void {
        self.mu.lockUncancelable(self.io);
        const kv = self.indexes.fetchRemove(name) orelse {
            self.mu.unlock(self.io);
            return Error.IndexNotFound;
        };
        self.mu.unlock(self.io);

        const ie = kv.value;
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
    pub fn getIndex(self: *FtsStorageAdapter, name: []const u8) ?*IndexEngine {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        return self.indexes.get(name);
    }

    fn requireIndex(self: *FtsStorageAdapter, name: []const u8) !*IndexEngine {
        return self.getIndex(name) orelse Error.IndexNotFound;
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
        ie.write_mu.lockUncancelable(self.io);
        defer ie.write_mu.unlock(self.io);
        try ie.engine.indexDocument(node_id, terms);
    }

    /// Bulk index a batch of documents (one fsync per batch) into `name`.
    pub fn indexNodeBatch(
        self: *FtsStorageAdapter,
        name: []const u8,
        docs: []const fts.DocBatch,
    ) !void {
        const ie = try self.requireIndex(name);
        ie.write_mu.lockUncancelable(self.io);
        defer ie.write_mu.unlock(self.io);
        try ie.engine.indexDocumentBatch(docs);
    }

    /// Tombstone `node_id` in `name`.
    pub fn deleteNode(self: *FtsStorageAdapter, name: []const u8, node_id: u64) !void {
        const ie = try self.requireIndex(name);
        ie.write_mu.lockUncancelable(self.io);
        defer ie.write_mu.unlock(self.io);
        try ie.engine.deleteDocument(node_id);
    }

    /// Force a synchronous flush of `name`'s memtable to a segment.
    pub fn flush(self: *FtsStorageAdapter, name: []const u8) !void {
        const ie = try self.requireIndex(name);
        ie.write_mu.lockUncancelable(self.io);
        defer ie.write_mu.unlock(self.io);
        try ie.engine.flush();
    }

    /// Search `name` for `term`, returning up to `max_results` hits sorted by
    /// score descending (`max_results == 0` means unlimited). The caller owns
    /// the returned slice and must free it with `allocator`.
    ///
    /// The iterator is fully drained and deinited BEFORE returning so the
    /// library's shared rw-lock is released and writers are never blocked by a
    /// leaked reader. No `write_mu` is taken — concurrent searches are allowed.
    pub fn search(
        self: *FtsStorageAdapter,
        name: []const u8,
        allocator: std.mem.Allocator,
        term: []const u8,
        max_results: usize,
    ) ![]Hit {
        const ie = try self.requireIndex(name);

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
    /// before returning, no `write_mu` taken.
    // CANARY: REQ=REQ-GQL-FTS-ADV-001; FEATURE="Advanced FTS"; ASPECT=PositionalSearch; STATUS=TESTED; TEST=tests/test_fts_storage_adapter.zig; OWNER=index; UPDATED=2026-06-10
    pub fn searchPositions(
        self: *FtsStorageAdapter,
        name: []const u8,
        allocator: std.mem.Allocator,
        term: []const u8,
    ) ![]PositionalHit {
        const ie = try self.requireIndex(name);

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
