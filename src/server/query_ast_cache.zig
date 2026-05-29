const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const geode = @import("geode");
const token = geode.gql.token;

// CANARY: REQ=REQ-PERF-AST-CACHE-001; FEATURE="QueryASTCache"; ASPECT=ParseHotPath; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
// CANARY: REQ=REQ-PERF-LRU-O1-001; FEATURE="O1LRUEviction"; ASPECT=CacheEviction; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
/// Cache parsed ASTs keyed by query text and parse options to avoid repeat parsing.
/// Uses an intrusive doubly-linked list keyed by hash for O(1) LRU eviction.
pub const QueryAstCache = struct {
    allocator: std.mem.Allocator,
    cache: std.AutoHashMap(u64, CachedAst),
    max_size: usize,
    hit_count: u64 = 0,
    miss_count: u64 = 0,
    lru_head: ?u64 = null, // Most recently used
    lru_tail: ?u64 = null, // Least recently used

    pub fn init(allocator: std.mem.Allocator, max_size: usize) QueryAstCache {
        return .{
            .allocator = allocator,
            .cache = std.AutoHashMap(u64, CachedAst).init(allocator),
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *QueryAstCache) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.parse_result.deinit();
            self.allocator.free(entry.value_ptr.query_text);
        }
        self.cache.deinit();
    }

    pub fn getOrParse(self: *QueryAstCache, query_text: []const u8, opts: geode.ParseOptions) !AstParseOutcome {
        const key = hashQuery(query_text, opts);

        if (self.cache.getPtr(key)) |cached| {
            if (std.mem.eql(u8, cached.query_text, query_text)) {
                self.hit_count += 1;
                cached.access_count += 1;
                cached.last_accessed = compat_timestamp();
                self.lruPromote(key);
                return .{ .Ok = .{
                    .cache = null,
                    .key = 0,
                    .parse_result = &cached.parse_result,
                } };
            }

            // Hash collision: evict the existing entry and treat as a miss.
            self.lruRemoveNode(key);
            if (self.cache.fetchRemove(key)) |kv| {
                kv.value.parse_result.deinit();
                self.allocator.free(kv.value.query_text);
            }
        }

        self.miss_count += 1;

        // Parse using a heap-allocated copy of the query text so that all AST
        // lexeme slices point into the stable copy rather than the caller's
        // transient buffer (see SharedAstCache.getOrParse for details).
        const query_text_copy = try self.allocator.dupe(u8, query_text);
        const outcome = geode.parseGqlOutcome(query_text_copy, self.allocator, opts) catch |err| {
            self.allocator.free(query_text_copy);
            return err;
        };
        switch (outcome) {
            .Err => |er| {
                self.allocator.free(query_text_copy);
                return .{
                    .Err = .{
                        .msg = er.msg,
                        .line = er.line,
                        .column = er.column,
                        .token = er.token,
                        .has_double_dash_comment = er.has_double_dash_comment,
                    },
                };
            },
            .Ok => |ok| {
                if (self.cache.count() >= self.max_size) {
                    self.evictTail();
                }

                // Use query_text_copy directly; AST lexeme slices already point into it.
                var cached_ast = CachedAst{
                    .query_text = query_text_copy,
                    .parse_result = ok,
                    .created_at = compat_timestamp(),
                    .last_accessed = compat_timestamp(),
                    .access_count = 1,
                };
                errdefer {
                    cached_ast.parse_result.deinit();
                    self.allocator.free(cached_ast.query_text);
                }

                try self.cache.put(key, cached_ast);
                self.lruInsertHead(key);
                const cached_ptr = self.cache.getPtr(key) orelse return error.InvalidState;
                return .{ .Ok = .{
                    .cache = null,
                    .key = 0,
                    .parse_result = &cached_ptr.parse_result,
                } };
            },
        }
    }

    /// O(1) eviction: remove the LRU tail entry.
    fn evictTail(self: *QueryAstCache) void {
        const tail_key = self.lru_tail orelse return;

        // Unlink tail from list before HashMap mutation.
        self.lruRemoveNode(tail_key);

        if (self.cache.fetchRemove(tail_key)) |kv| {
            kv.value.parse_result.deinit();
            self.allocator.free(kv.value.query_text);
        }
    }

    // --- LRU linked-list helpers (keyed by u64 hash) ---

    fn lruPromote(self: *QueryAstCache, key: u64) void {
        if (self.lru_head != null and self.lru_head.? == key) return;
        self.lruRemoveNode(key);
        self.lruInsertHead(key);
    }

    fn lruInsertHead(self: *QueryAstCache, key: u64) void {
        const entry = self.cache.getPtr(key) orelse return;
        entry.lru_prev = null;
        entry.lru_next = self.lru_head;
        if (self.lru_head) |old_head| {
            if (self.cache.getPtr(old_head)) |h| h.lru_prev = key;
        }
        self.lru_head = key;
        if (self.lru_tail == null) self.lru_tail = key;
    }

    fn lruRemoveNode(self: *QueryAstCache, key: u64) void {
        const entry = self.cache.getPtr(key) orelse return;
        const prev = entry.lru_prev;
        const next = entry.lru_next;
        if (prev) |pk| {
            if (self.cache.getPtr(pk)) |p| p.lru_next = next;
        } else {
            self.lru_head = next;
        }
        if (next) |nk| {
            if (self.cache.getPtr(nk)) |n| n.lru_prev = prev;
        } else {
            self.lru_tail = prev;
        }
        entry.lru_prev = null;
        entry.lru_next = null;
    }
};

pub const ParseError = struct {
    msg: []const u8,
    line: u32,
    column: u32,
    token: token.TokenKind,
    has_double_dash_comment: bool,
};

pub const AstParseOutcome = union(enum) {
    Ok: AstHandle,
    Err: ParseError,
};

const CachedAst = struct {
    query_text: []const u8,
    parse_result: geode.ParseResult,
    created_at: i64,
    last_accessed: i64,
    access_count: u64,
    lru_prev: ?u64 = null,
    lru_next: ?u64 = null,
};

// Shared, thread-safe AST cache for cross-connection reuse.
// Uses ref-counting to prevent eviction while entries are in use.
// O(1) LRU eviction via intrusive doubly-linked list (Issue #456).
pub const SharedAstCache = struct {
    allocator: std.mem.Allocator,
    cache: std.AutoHashMap(u64, SharedCachedAst),
    max_size: usize,
    hit_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    miss_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    // CANARY: REQ=REQ-QUIC-HC-164; FEATURE="High-Concurrency Query Cache"; ASPECT=SharedAstConcurrentHits; STATUS=IMPL; TEST=query_ast_cache_shared_singleflight; OWNER=engine; UPDATED=2026-05-29
    //
    // Same-query fan-out used to serialize every cache hit behind this lock's
    // old mutex form. Hits now take the lock SHARED and bump atomic counters /
    // refcounts; misses and eviction still take it EXCLUSIVE for HashMap
    // structural changes.
    lock: std.Io.RwLock = std.Io.RwLock.init,
    inflight_misses: std.AutoHashMap(u64, void),
    miss_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    lru_head: ?u64 = null,
    lru_tail: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) SharedAstCache {
        return .{
            .allocator = allocator,
            .cache = std.AutoHashMap(u64, SharedCachedAst).init(allocator),
            .inflight_misses = std.AutoHashMap(u64, void).init(allocator),
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *SharedAstCache) void {
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.parse_result.deinit();
            self.allocator.destroy(entry.value_ptr.parse_result);
            self.allocator.free(entry.value_ptr.query_text);
        }
        self.inflight_misses.deinit();
        self.cache.deinit();
    }

    // CANARY: REQ=REQ-PERF-QPS-0810; FEATURE="ParseCacheWrapper"; ASPECT=StatsAccessor; STATUS=TESTED; TEST=tests/test_gap0810_parse_cache_wrapper.zig; OWNER=performance; UPDATED=2026-04-20
    // GAP-0810: hit/miss counters are atomic so callers can observe a
    // consistent snapshot without blocking concurrent `getOrParse` hits.
    pub fn stats(self: *SharedAstCache) struct { hit_count: u64, miss_count: u64 } {
        return .{
            .hit_count = self.hit_count.load(.acquire),
            .miss_count = self.miss_count.load(.acquire),
        };
    }

    pub fn getOrParse(self: *SharedAstCache, query_text: []const u8, opts: geode.ParseOptions) !AstParseOutcome {
        const key = hashQuery(query_text, opts);
        const io = std.Io.Threaded.global_single_threaded.io();

        // CANARY: REQ=REQ-QUIC-HC-104; FEATURE="High-Concurrency Query Cache"; ASPECT=AstMissSingleFlight; STATUS=TESTED; TEST=query_ast_cache_shared_singleflight; OWNER=engine; UPDATED=2026-05-27
        // First-burst fan-out needs same-query singleflight, but holding the
        // global cache mutex while parsing serializes unrelated mutation query
        // shapes. Mark only this key as in-flight, parse outside the lock, then
        // wake waiters so identical queries hit the cached AST.
        while (true) {
            self.lock.lockSharedUncancelable(io);
            if (self.cache.getPtr(key)) |cached| {
                if (std.mem.eql(u8, cached.query_text, query_text)) {
                    _ = self.hit_count.fetchAdd(1, .acq_rel);
                    _ = cached.access_count.fetchAdd(1, .monotonic);
                    cached.last_accessed.store(compat_timestamp(), .monotonic);
                    _ = cached.ref_count.fetchAdd(1, .acq_rel);
                    const handle = AstHandle{
                        .cache = self,
                        .key = key,
                        .parse_result = cached.parse_result,
                    };
                    self.lock.unlockShared(io);
                    return .{ .Ok = handle };
                }
            }
            self.lock.unlockShared(io);

            self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            if (self.cache.getPtr(key)) |cached| {
                if (std.mem.eql(u8, cached.query_text, query_text)) {
                    _ = self.hit_count.fetchAdd(1, .acq_rel);
                    _ = cached.access_count.fetchAdd(1, .monotonic);
                    cached.last_accessed.store(compat_timestamp(), .monotonic);
                    _ = cached.ref_count.fetchAdd(1, .acq_rel);
                    self.lruPromoteUnlocked(key);
                    const handle = AstHandle{
                        .cache = self,
                        .key = key,
                        .parse_result = cached.parse_result,
                    };
                    self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
                    return .{ .Ok = handle };
                }

                // Hash collision: evict existing entry if safe. If it is still
                // referenced, wait for a release and retry rather than overwriting
                // a live cached AST under the same hash key.
                if (cached.ref_count.load(.acquire) == 0) {
                    self.lruRemoveNodeUnlocked(key);
                    if (self.cache.fetchRemove(key)) |kv| {
                        kv.value.parse_result.deinit();
                        self.allocator.destroy(kv.value.parse_result);
                        self.allocator.free(kv.value.query_text);
                    }
                } else {
                    const observed_generation = self.miss_generation.load(.acquire);
                    self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
                    self.waitForMissGeneration(observed_generation);
                    continue;
                }
            }

            if (self.inflight_misses.contains(key)) {
                const observed_generation = self.miss_generation.load(.acquire);
                self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
                self.waitForMissGeneration(observed_generation);
                continue;
            }

            self.inflight_misses.put(key, {}) catch |err| {
                self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
                return err;
            };
            _ = self.miss_count.fetchAdd(1, .acq_rel);
            self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
            break;
        }

        // Allocate a stable copy of the query text BEFORE parsing. The Geode lexer
        // uses zero-copy slices into its source buffer (lexeme = src[start..end]),
        // so all AST string references (identifiers, labels, aliases, etc.) point
        // directly into whatever buffer is passed as `src`. By parsing with this
        // heap-allocated copy, we guarantee that AST strings remain valid for the
        // entire lifetime of the cached ParseResult, independent of the caller's
        // transient query buffer (e.g., normalized.text freed per-connection).
        const query_text_copy = try self.allocator.dupe(u8, query_text);
        const outcome = geode.parseGqlOutcome(query_text_copy, self.allocator, opts) catch |err| {
            self.allocator.free(query_text_copy);
            self.finishInflightMiss(key);
            return err;
        };
        switch (outcome) {
            .Err => |er| {
                // Parse error - not caching, free the copy.
                self.allocator.free(query_text_copy);
                self.finishInflightMiss(key);
                return .{
                    .Err = .{
                        .msg = er.msg,
                        .line = er.line,
                        .column = er.column,
                        .token = er.token,
                        .has_double_dash_comment = er.has_double_dash_comment,
                    },
                };
            },
            .Ok => |ok| {
                // Move parse result into heap allocation for stable pointer storage.
                const pr_ptr = self.allocator.create(geode.ParseResult) catch |err| {
                    var mutable_ok = ok;
                    mutable_ok.deinit();
                    self.allocator.free(query_text_copy);
                    self.finishInflightMiss(key);
                    return err;
                };
                pr_ptr.* = ok;

                self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
                defer self.lock.unlock(std.Io.Threaded.global_single_threaded.io());

                if (self.cache.count() >= self.max_size) {
                    self.evictLeastUsedUnlocked();
                }

                // Use query_text_copy directly as the cached query_text.
                // AST lexeme slices already point into this buffer, so no
                // second dupe is needed.
                var cached_ast = SharedCachedAst{
                    .query_text = query_text_copy,
                    .parse_result = pr_ptr,
                    .created_at = compat_timestamp(),
                    .last_accessed = std.atomic.Value(i64).init(compat_timestamp()),
                    .access_count = std.atomic.Value(u64).init(1),
                    .ref_count = std.atomic.Value(u32).init(1),
                };
                errdefer {
                    cached_ast.parse_result.deinit();
                    self.allocator.destroy(cached_ast.parse_result);
                    self.allocator.free(cached_ast.query_text);
                }

                self.cache.put(key, cached_ast) catch |err| {
                    _ = self.inflight_misses.remove(key);
                    _ = self.miss_generation.fetchAdd(1, .release);
                    std.Io.Threaded.global_single_threaded.io().futexWake(u32, &self.miss_generation.raw, std.math.maxInt(u32));
                    return err;
                };
                self.lruInsertHeadUnlocked(key);
                _ = self.inflight_misses.remove(key);
                _ = self.miss_generation.fetchAdd(1, .release);
                std.Io.Threaded.global_single_threaded.io().futexWake(u32, &self.miss_generation.raw, std.math.maxInt(u32));
                return .{ .Ok = AstHandle{
                    .cache = self,
                    .key = key,
                    .parse_result = pr_ptr,
                } };
            },
        }
    }

    pub fn release(self: *SharedAstCache, key: u64) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        if (self.cache.getPtr(key)) |entry| {
            var observed = entry.ref_count.load(.acquire);
            while (observed > 0) {
                if (entry.ref_count.cmpxchgWeak(observed, observed - 1, .acq_rel, .acquire)) |actual| {
                    observed = actual;
                } else {
                    if (observed == 1) {
                        _ = self.miss_generation.fetchAdd(1, .release);
                        std.Io.Threaded.global_single_threaded.io().futexWake(u32, &self.miss_generation.raw, std.math.maxInt(u32));
                    }
                    return;
                }
            }
            if (observed == 0) {
                if (entry.ref_count.load(.acquire) == 0) {
                    _ = self.miss_generation.fetchAdd(1, .release);
                    std.Io.Threaded.global_single_threaded.io().futexWake(u32, &self.miss_generation.raw, std.math.maxInt(u32));
                }
            }
        }
    }

    fn waitForMissGeneration(self: *SharedAstCache, observed_generation: u32) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const timeout: std.Io.Timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms),
            .clock = .awake,
        } };
        io.futexWaitTimeout(u32, &self.miss_generation.raw, observed_generation, timeout) catch |err| switch (err) {
            error.Canceled => {},
        };
    }

    fn finishInflightMiss(self: *SharedAstCache, key: u64) void {
        self.lock.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        _ = self.inflight_misses.remove(key);
        _ = self.miss_generation.fetchAdd(1, .release);
        self.lock.unlock(std.Io.Threaded.global_single_threaded.io());
        std.Io.Threaded.global_single_threaded.io().futexWake(u32, &self.miss_generation.raw, std.math.maxInt(u32));
    }

    /// O(1) eviction: walk backward from tail, skip entries with ref_count > 0.
    fn evictLeastUsedUnlocked(self: *SharedAstCache) void {
        var key_opt = self.lru_tail;
        while (key_opt) |key| {
            const entry = self.cache.getPtr(key) orelse return;
            if (entry.ref_count.load(.acquire) == 0) {
                self.lruRemoveNodeUnlocked(key);
                if (self.cache.fetchRemove(key)) |kv| {
                    kv.value.parse_result.deinit();
                    self.allocator.destroy(kv.value.parse_result);
                    self.allocator.free(kv.value.query_text);
                }
                return;
            }
            key_opt = entry.lru_prev;
        }
    }

    // --- LRU linked-list helpers (caller holds lock) ---

    fn lruPromoteUnlocked(self: *SharedAstCache, key: u64) void {
        if (self.lru_head != null and self.lru_head.? == key) return;
        self.lruRemoveNodeUnlocked(key);
        self.lruInsertHeadUnlocked(key);
    }

    fn lruInsertHeadUnlocked(self: *SharedAstCache, key: u64) void {
        const entry = self.cache.getPtr(key) orelse return;
        entry.lru_prev = null;
        entry.lru_next = self.lru_head;
        if (self.lru_head) |old_head| {
            if (self.cache.getPtr(old_head)) |h| h.lru_prev = key;
        }
        self.lru_head = key;
        if (self.lru_tail == null) self.lru_tail = key;
    }

    fn lruRemoveNodeUnlocked(self: *SharedAstCache, key: u64) void {
        const entry = self.cache.getPtr(key) orelse return;
        const prev = entry.lru_prev;
        const next = entry.lru_next;
        if (prev) |pk| {
            if (self.cache.getPtr(pk)) |p| p.lru_next = next;
        } else {
            self.lru_head = next;
        }
        if (next) |nk| {
            if (self.cache.getPtr(nk)) |n| n.lru_prev = prev;
        } else {
            self.lru_tail = prev;
        }
        entry.lru_prev = null;
        entry.lru_next = null;
    }
};

pub const AstHandle = struct {
    cache: ?*SharedAstCache,
    key: u64,
    parse_result: *const geode.ParseResult,

    pub fn release(self: *AstHandle) void {
        if (self.cache) |cache| {
            cache.release(self.key);
        }
    }
};

const SharedCachedAst = struct {
    query_text: []const u8,
    parse_result: *geode.ParseResult,
    created_at: i64,
    last_accessed: std.atomic.Value(i64),
    access_count: std.atomic.Value(u64),
    ref_count: std.atomic.Value(u32),
    lru_prev: ?u64 = null,
    lru_next: ?u64 = null,
};

fn hashQuery(query_text: []const u8, opts: geode.ParseOptions) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(query_text);
    const bits = optionsBits(opts);
    const bits_bytes = std.mem.asBytes(&bits);
    hasher.update(bits_bytes);
    return hasher.final();
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
