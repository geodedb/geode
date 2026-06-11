// Per-document AST cache for the GQL/Geode LSP (LSP-F-02 / #770).
//
// Problem: every parsing feature provider (diagnostics, go-to-definition,
// document symbols) re-ran `geode.parseGqlOutcome(doc.text, ...)` on each
// request, so a didOpen followed by a definition and an outline request
// parsed the identical document text three times. The parser is by far the
// most expensive stage of an LSP request (~100x the planner per
// docs/performance/2026-04-20-query-bench/FINAL.md §6), making it the
// keystone for the deferred LSP perf items F-05/F-06/F-12/F-15/F-16.
//
// Design:
//   - `LspAstCache` is owned by `Server` (one per LSP session) and keyed by
//     document URI; an entry is a hit only when its recorded (version,
//     parse-options, text) all match the live document. Keying on the full
//     URI string makes collisions impossible (unlike the hash-keyed
//     server-side SharedAstCache).
//   - MEMORY OWNERSHIP: parse results are arena-backed and the lexer is
//     zero-copy (AST lexeme slices point into the source buffer), so each
//     entry parses from its OWN heap copy of the document text. A cached
//     AST therefore never dangles when `Document.update` frees the old
//     `doc.text`. The cache frees the outcome + text copy + uri key on
//     invalidation, staleness replacement, eviction, and deinit.
//   - EVICTION: bounded entry count (default 16 open documents) with
//     simple least-recently-used eviction via a logical tick — an O(n)
//     scan over <=max_entries entries, which is negligible at this bound.
//   - INVALIDATION: `Server.handleDidChange` / `handleDidOpen` /
//     `handleDidClose` invalidate the URI eagerly. Even without the eager
//     hook, the (version, text) check on lookup makes a stale entry a miss,
//     never a wrong answer.
//   - THREADING: the LSP server is single-threaded per session — `run()`
//     reads one message and fully handles it before reading the next, and
//     the embedded TCP listener (`runLspSession` in src/server/main.zig)
//     spawns one thread per connection, each with its OWN `Server` and
//     therefore its own cache. The provider hookup below uses a
//     `threadlocal` active-cache pointer, so caches are never shared
//     across threads and no mutex is needed (this is NOT a new lock tier).
//
// Provider hookup: the feature providers receive only `*const Document`,
// and their signatures are consumed by many out-of-tree tests (GAP-0818,
// e2e). To avoid churning every call site, the providers call
// `parseDocument(...)` below, which consults the thread's active cache
// (installed by `Server.handleMessage` and the public compute helpers) and
// falls back to a direct, caller-owned parse when no cache is active —
// e.g. when tests drive a provider function directly.
//
// CANARY: REQ=REQ-LSP-AST-CACHE-001; FEATURE="LspAstCache"; ASPECT=PerDocumentCache; STATUS=TESTED; TEST=tests/test_lsp_ast_cache.zig; OWNER=lsp; UPDATED=2026-06-11
// CANARY: REQ=REQ-LSP-AST-CACHE-002; FEATURE="LspAstCache"; ASPECT=ProviderFallback; STATUS=TESTED; TEST=tests/test_lsp_ast_cache.zig; OWNER=lsp; UPDATED=2026-06-11

const std = @import("std");
const geode = @import("geode");

/// Re-export so the out-of-tree regression (tests/test_lsp_ast_cache.zig,
/// reached through the `lsp_server` named module) can construct Documents
/// without rooting a second module at document.zig (Zig 0.16 forbids a
/// file living in two modules of one compilation).
pub const Document = @import("document.zig").Document;

/// Default bound on cached documents per LSP session. Editors rarely hold
/// more than a handful of GQL buffers open; 16 keeps worst-case memory at
/// 16 parsed ASTs + text copies.
pub const DEFAULT_MAX_ENTRIES: usize = 16;

pub const Stats = struct {
    hits: u64,
    misses: u64,
    invalidations: u64,
    evictions: u64,
};

pub const LspAstCache = struct {
    allocator: std.mem.Allocator,
    /// Keyed by the entry's own `uri` copy. Values are heap-allocated so
    /// `*Entry` (and `&entry.outcome`) stay stable across map rehashes.
    entries: std.StringHashMap(*Entry),
    max_entries: usize,
    hits: u64 = 0,
    misses: u64 = 0,
    invalidations: u64 = 0,
    evictions: u64 = 0,
    /// Logical clock for LRU ordering; bumped on every lookup.
    tick: u64 = 0,

    const Entry = struct {
        uri: []u8,
        version: i32,
        opts_bits: u64,
        /// Owned stable copy of the document text at parse time. The AST's
        /// lexeme slices point into THIS buffer (zero-copy lexer), so it
        /// must live exactly as long as `outcome`.
        text: []u8,
        outcome: geode.ParseOutcome,
        last_used: u64,
    };

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) LspAstCache {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(*Entry).init(allocator),
            .max_entries = @max(max_entries, 1),
        };
    }

    pub fn deinit(self: *LspAstCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            self.destroyEntry(entry_ptr.*);
        }
        self.entries.deinit();
    }

    /// Look up (or parse and insert) the AST for `doc` under `opts`. The
    /// returned outcome is BORROWED from the cache: the caller must not
    /// deinit it, and must not retain the pointer past the next cache
    /// mutation (getOrParse miss, invalidate, deinit). In the
    /// single-threaded LSP request loop a provider's usage — consume the
    /// outcome before returning, no cache calls in between — satisfies
    /// this contract by construction.
    pub fn getOrParse(self: *LspAstCache, doc: *const Document, opts: geode.ParseOptions) !*const geode.ParseOutcome {
        self.tick += 1;
        const bits = optionsBits(opts);

        if (self.entries.get(doc.uri)) |entry| {
            if (entry.version == doc.version and
                entry.opts_bits == bits and
                std.mem.eql(u8, entry.text, doc.text))
            {
                self.hits += 1;
                entry.last_used = self.tick;
                return &entry.outcome;
            }
            // Stale (didChange raced ahead of an eager invalidate, or a
            // re-open reused the version): replace as part of the miss.
            if (self.entries.fetchRemove(doc.uri)) |kv| {
                self.destroyEntry(kv.value);
            }
        }

        self.misses += 1;
        if (self.entries.count() >= self.max_entries) {
            self.evictLru();
        }

        const uri_copy = try self.allocator.dupe(u8, doc.uri);
        errdefer self.allocator.free(uri_copy);
        // Parse from a stable heap copy — see MEMORY OWNERSHIP above.
        const text_copy = try self.allocator.dupe(u8, doc.text);
        errdefer self.allocator.free(text_copy);
        var outcome = try geode.parseGqlOutcome(text_copy, self.allocator, opts);
        errdefer outcome.deinit();
        const entry = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .uri = uri_copy,
            .version = doc.version,
            .opts_bits = bits,
            .text = text_copy,
            .outcome = outcome,
            .last_used = self.tick,
        };
        try self.entries.put(uri_copy, entry);
        return &entry.outcome;
    }

    /// Drop the cached AST for `uri` (didChange / didOpen / didClose).
    /// No-op when nothing is cached.
    pub fn invalidate(self: *LspAstCache, uri: []const u8) void {
        if (self.entries.fetchRemove(uri)) |kv| {
            self.invalidations += 1;
            self.destroyEntry(kv.value);
        }
    }

    pub fn stats(self: *const LspAstCache) Stats {
        return .{
            .hits = self.hits,
            .misses = self.misses,
            .invalidations = self.invalidations,
            .evictions = self.evictions,
        };
    }

    fn evictLru(self: *LspAstCache) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_tick: u64 = std.math.maxInt(u64);
        var it = self.entries.valueIterator();
        while (it.next()) |entry_ptr| {
            if (entry_ptr.*.last_used < oldest_tick) {
                oldest_tick = entry_ptr.*.last_used;
                oldest_key = entry_ptr.*.uri;
            }
        }
        const key = oldest_key orelse return;
        if (self.entries.fetchRemove(key)) |kv| {
            self.evictions += 1;
            self.destroyEntry(kv.value);
        }
    }

    fn destroyEntry(self: *LspAstCache, entry: *Entry) void {
        entry.outcome.deinit();
        self.allocator.free(entry.text);
        self.allocator.free(entry.uri);
        self.allocator.destroy(entry);
    }
};

// ---------------------------------------------------------------------------
// Per-thread active cache + provider entry point
// ---------------------------------------------------------------------------

/// The session's cache, installed by `Server.handleMessage` (and the public
/// compute helpers tests drive directly). `threadlocal` because the
/// embedded TCP listener runs one session per thread — each thread only
/// ever sees its own Server's cache, so this is data-race-free without a
/// mutex.
threadlocal var active_cache: ?*LspAstCache = null;

pub fn setActive(cache: ?*LspAstCache) void {
    active_cache = cache;
}

/// Clear the active pointer iff it still points at `cache`. Called from
/// `Server.deinit` so a later direct provider call on this thread (e.g. a
/// features_test running after a server_test in the same test binary) can
/// never dereference a dangling cache.
pub fn clearActiveIf(cache: *LspAstCache) void {
    if (active_cache == cache) active_cache = null;
}

/// Result of `parseDocument`: either a borrowed cache entry (do not free)
/// or a caller-owned direct parse (freed by `deinit`). Providers treat
/// both uniformly:
///
///     var dp = try ast_cache.parseDocument(allocator, doc, .{});
///     defer dp.deinit();
///     switch (dp.outcome().*) { .Ok => ..., .Err => ... }
pub const DocParse = union(enum) {
    cached: *const geode.ParseOutcome,
    owned: geode.ParseOutcome,

    pub fn outcome(self: *const DocParse) *const geode.ParseOutcome {
        return switch (self.*) {
            .cached => |ptr| ptr,
            .owned => |*o| o,
        };
    }

    pub fn deinit(self: *DocParse) void {
        switch (self.*) {
            .cached => {},
            .owned => |*o| o.deinit(),
        }
    }
};

/// Parse `doc` through the thread's active cache when one is installed,
/// falling back to a direct caller-owned `parseGqlOutcome` otherwise (or
/// when the cache itself fails to allocate). This is the single parse
/// entry point for the LSP feature providers.
pub fn parseDocument(allocator: std.mem.Allocator, doc: *const Document, opts: geode.ParseOptions) !DocParse {
    if (active_cache) |cache| {
        if (cache.getOrParse(doc, opts)) |ptr| {
            return .{ .cached = ptr };
        } else |_| {
            // Cache-side allocation failure: degrade to an uncached parse
            // rather than failing the request outright.
        }
    }
    return .{ .owned = try geode.parseGqlOutcome(doc.text, allocator, opts) };
}

fn optionsBits(opts: geode.ParseOptions) u64 {
    var bits: u64 = 0;
    if (opts.strict_order_keys) bits |= 1 << 0;
    if (opts.ident_order_only) bits |= 1 << 1;
    if (opts.forbid_orderby_calls) bits |= 1 << 2;
    if (opts.forbid_orderby_paths) bits |= 1 << 3;
    if (opts.ts_extensions) bits |= 1 << 4;
    return bits;
}
