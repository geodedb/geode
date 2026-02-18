const std = @import("std");
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
                cached.last_accessed = std.time.timestamp();
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

        const outcome = try geode.parseGqlOutcome(query_text, self.allocator, opts);
        switch (outcome) {
            .Err => |er| {
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
                // Ensure we clean up the parse result on any later failure.
                errdefer {
                    var tmp = ok;
                    tmp.deinit();
                }

                if (self.cache.count() >= self.max_size) {
                    self.evictTail();
                }

                var cached_ast = CachedAst{
                    .query_text = try self.allocator.dupe(u8, query_text),
                    .parse_result = ok,
                    .created_at = std.time.timestamp(),
                    .last_accessed = std.time.timestamp(),
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
    hit_count: u64 = 0,
    miss_count: u64 = 0,
    lock: std.Thread.Mutex = .{},
    lru_head: ?u64 = null,
    lru_tail: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, max_size: usize) SharedAstCache {
        return .{
            .allocator = allocator,
            .cache = std.AutoHashMap(u64, SharedCachedAst).init(allocator),
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *SharedAstCache) void {
        self.lock.lock();
        defer self.lock.unlock();
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.parse_result.deinit();
            self.allocator.destroy(entry.value_ptr.parse_result);
            self.allocator.free(entry.value_ptr.query_text);
        }
        self.cache.deinit();
    }

    pub fn getOrParse(self: *SharedAstCache, query_text: []const u8, opts: geode.ParseOptions) !AstParseOutcome {
        const key = hashQuery(query_text, opts);

        // Fast lookup under lock.
        self.lock.lock();
        if (self.cache.getPtr(key)) |cached| {
            if (std.mem.eql(u8, cached.query_text, query_text)) {
                self.hit_count += 1;
                cached.access_count += 1;
                cached.last_accessed = std.time.timestamp();
                cached.ref_count += 1;
                self.lruPromoteUnlocked(key);
                const handle = AstHandle{
                    .cache = self,
                    .key = key,
                    .parse_result = cached.parse_result,
                };
                self.lock.unlock();
                return .{ .Ok = handle };
            }

            // Hash collision: evict existing entry (if not in use).
            if (cached.ref_count == 0) {
                self.lruRemoveNodeUnlocked(key);
                if (self.cache.fetchRemove(key)) |kv| {
                    kv.value.parse_result.deinit();
                    self.allocator.destroy(kv.value.parse_result);
                    self.allocator.free(kv.value.query_text);
                }
            }
        }
        self.lock.unlock();

        self.miss_count += 1;

        // Parse outside the lock to avoid blocking concurrent lookups.
        const outcome = try geode.parseGqlOutcome(query_text, self.allocator, opts);
        switch (outcome) {
            .Err => |er| {
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
                const pr_ptr = try self.allocator.create(geode.ParseResult);
                pr_ptr.* = ok;

                // Insert into cache under lock (double-check for races).
                self.lock.lock();
                defer self.lock.unlock();

                if (self.cache.getPtr(key)) |existing| {
                    if (std.mem.eql(u8, existing.query_text, query_text)) {
                        // Another thread inserted the same entry; discard ours.
                        pr_ptr.deinit();
                        self.allocator.destroy(pr_ptr);
                        existing.access_count += 1;
                        existing.last_accessed = std.time.timestamp();
                        existing.ref_count += 1;
                        self.lruPromoteUnlocked(key);
                        return .{ .Ok = AstHandle{
                            .cache = self,
                            .key = key,
                            .parse_result = existing.parse_result,
                        } };
                    }
                }

                if (self.cache.count() >= self.max_size) {
                    self.evictLeastUsedUnlocked();
                }

                var cached_ast = SharedCachedAst{
                    .query_text = try self.allocator.dupe(u8, query_text),
                    .parse_result = pr_ptr,
                    .created_at = std.time.timestamp(),
                    .last_accessed = std.time.timestamp(),
                    .access_count = 1,
                    .ref_count = 1,
                };
                errdefer {
                    cached_ast.parse_result.deinit();
                    self.allocator.destroy(cached_ast.parse_result);
                    self.allocator.free(cached_ast.query_text);
                }

                try self.cache.put(key, cached_ast);
                self.lruInsertHeadUnlocked(key);
                return .{ .Ok = AstHandle{
                    .cache = self,
                    .key = key,
                    .parse_result = pr_ptr,
                } };
            },
        }
    }

    pub fn release(self: *SharedAstCache, key: u64) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.cache.getPtr(key)) |entry| {
            if (entry.ref_count > 0) entry.ref_count -= 1;
        }
    }

    /// O(1) eviction: walk backward from tail, skip entries with ref_count > 0.
    fn evictLeastUsedUnlocked(self: *SharedAstCache) void {
        var key_opt = self.lru_tail;
        while (key_opt) |key| {
            const entry = self.cache.getPtr(key) orelse return;
            if (entry.ref_count == 0) {
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
    last_accessed: i64,
    access_count: u64,
    ref_count: u32,
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
