const std = @import("std");
const geode = @import("geode");
const token = @import("../gql/token.zig");

// CANARY: REQ=REQ-PERF-AST-CACHE-001; FEATURE="QueryASTCache"; ASPECT=ParseHotPath; STATUS=IMPL; OWNER=engine; UPDATED=2026-01-27
/// Cache parsed ASTs keyed by query text and parse options to avoid repeat parsing.
pub const QueryAstCache = struct {
    allocator: std.mem.Allocator,
    cache: std.AutoHashMap(u64, CachedAst),
    max_size: usize,
    hit_count: u64 = 0,
    miss_count: u64 = 0,

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
                return .{ .Ok = .{
                    .cache = null,
                    .key = 0,
                    .parse_result = &cached.parse_result,
                } };
            }

            // Hash collision: evict the existing entry and treat as a miss.
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
                    try self.evictLeastUsed();
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
                const cached_ptr = self.cache.getPtr(key) orelse return error.InvalidState;
                return .{ .Ok = .{
                    .cache = null,
                    .key = 0,
                    .parse_result = &cached_ptr.parse_result,
                } };
            },
        }
    }

    fn evictLeastUsed(self: *QueryAstCache) !void {
        var oldest_time: i64 = std.math.maxInt(i64);
        var oldest_key: u64 = 0;
        var found = false;

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.last_accessed < oldest_time) {
                oldest_time = entry.value_ptr.last_accessed;
                oldest_key = entry.key_ptr.*;
                found = true;
            }
        }

        if (!found) return;

        if (self.cache.fetchRemove(oldest_key)) |kv| {
            kv.value.parse_result.deinit();
            self.allocator.free(kv.value.query_text);
        }
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
};

// Shared, thread-safe AST cache for cross-connection reuse.
// Uses ref-counting to prevent eviction while entries are in use.
pub const SharedAstCache = struct {
    allocator: std.mem.Allocator,
    cache: std.AutoHashMap(u64, SharedCachedAst),
    max_size: usize,
    hit_count: u64 = 0,
    miss_count: u64 = 0,
    lock: std.Thread.Mutex = .{},

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
                        return .{ .Ok = AstHandle{
                            .cache = self,
                            .key = key,
                            .parse_result = existing.parse_result,
                        } };
                    }
                }

                if (self.cache.count() >= self.max_size) {
                    // Best-effort eviction; skip entries that are in use.
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

    fn evictLeastUsedUnlocked(self: *SharedAstCache) void {
        var oldest_time: i64 = std.math.maxInt(i64);
        var oldest_key: u64 = 0;
        var found = false;

        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.ref_count != 0) continue;
            if (entry.value_ptr.last_accessed < oldest_time) {
                oldest_time = entry.value_ptr.last_accessed;
                oldest_key = entry.key_ptr.*;
                found = true;
            }
        }

        if (!found) return;

        if (self.cache.fetchRemove(oldest_key)) |kv| {
            kv.value.parse_result.deinit();
            self.allocator.destroy(kv.value.parse_result);
            self.allocator.free(kv.value.query_text);
        }
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
