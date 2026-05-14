// CANARY: REQ=REQ-LSP-SCHEMA-PROVIDER-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=LazyFetchCache; STATUS=TESTED; TEST=src/cli/lsp/schema_provider_test.zig; OWNER=lsp; UPDATED=2026-05-14
//
// LSP-side lazy-fetch wrapper around src/execution/schema_introspection.zig.
//
// Scope (Tasks 6-7):
//   - Lazy first-fetch caching of labels, edge types, and per-label
//     property lists, keyed by IntrospectionContext (user/tenant/role/graph).
//   - Idempotent accessor methods — calling getLabels() twice returns the
//     same cached slice (no re-fetch).
//   - TTL expiry (DEFAULT_TTL_NS = 5s); stale entries are transparently
//     re-fetched on the next accessor call.
//   - `invalidate()` drops every cached allocation in O(N) and resets
//     all fetch timestamps so the next accessor call re-fetches.
//   - Single-owner deinit that releases every cached allocation.
//
// Out of scope (deferred):
//   - DDL-driven schema_change_notifier hook     -> Task 9
//
// Thread-safety (Task 8):
//   - A single `std.Io.Mutex` (`mu`) serialises every accessor entry
//     point (`getLabels`, `getEdgeTypes`, `getPropertiesFor`) plus
//     `invalidate()`. We hold the lock for the full body — including
//     the in-cache fast path — because the simplicity of "always
//     lock" is preferable to a double-checked / atomic pattern, and
//     the contention surface (a single LSP server thread + the
//     schema_change_notifier worker) is too low to justify the
//     complexity. `deinit()` is intentionally NOT locked — the caller
//     owns the SchemaProvider's lifetime and must guarantee no other
//     thread is touching it at teardown.
//
//     Zig 0.16 retired `std.Thread.Mutex`. We follow the same
//     `std.Io.Mutex` + `std.Io.Threaded.global_single_threaded.io()`
//     pattern used everywhere else in geode (`graph_store.zig:422`,
//     `session_storage.zig:285`, etc.). The `lockHere()` /
//     `unlockHere()` helpers below keep the call sites readable.
//
// The `properties_initialized` flag exists so `invalidate()` can
// reset the cache without forcing the StringHashMap to be re-initialized
// from scratch (deinit would otherwise double-free if invalidate runs
// after a no-op init).
//
// The monotonic clock helper `nowNs()` mirrors `lspMonoNanos` in
// src/cli/lsp/server.zig:41 — `std.posix.clock_gettime` is not stable
// in Zig 0.16, so we go through `std.os.linux` / `std.c` directly.
//
// Imports use the NAMED-module style (`geode`, `schema_introspection`)
// rather than relative file paths, because this file is registered as
// its own build module (`schema_provider_mod` in build.zig). That is the
// same module-diamond escape hatch Tasks 4 and 5 used; importing
// `../../graph_store.zig` directly would re-declare `graph_store` in
// two modules and trigger Zig 0.16's "file exists in modules X and X0"
// error.

const std = @import("std");
const geode = @import("geode");
const intro = @import("schema_introspection");

const graph_store = geode.graph_store;

pub const SchemaProvider = struct {
    pub const DEFAULT_TTL_NS: i128 = 5 * std.time.ns_per_s;

    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: intro.IntrospectionContext,

    labels: ?[][]const u8 = null,
    edge_types: ?[][]const u8 = null,
    properties: std.StringHashMap([][]const u8) = undefined,
    properties_initialized: bool = false,

    ttl_ns: i128 = DEFAULT_TTL_NS,
    labels_fetched_at_ns: i128 = 0,
    edge_types_fetched_at_ns: i128 = 0,
    properties_fetched_at_ns: std.StringHashMap(i128) = undefined,

    mu: std.Io.Mutex = std.Io.Mutex.init,

    fn lockHere(self: *SchemaProvider) void {
        self.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }

    fn unlockHere(self: *SchemaProvider) void {
        self.mu.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    pub fn init(
        allocator: std.mem.Allocator,
        store: *graph_store.GraphStore,
        ctx: intro.IntrospectionContext,
    ) SchemaProvider {
        return .{
            .allocator = allocator,
            .store = store,
            .ctx = ctx,
            .properties = std.StringHashMap([][]const u8).init(allocator),
            .properties_initialized = true,
            .properties_fetched_at_ns = std.StringHashMap(i128).init(allocator),
        };
    }

    pub fn deinit(self: *SchemaProvider) void {
        if (self.labels) |ls| intro.freeStringList(self.allocator, ls);
        if (self.edge_types) |es| intro.freeStringList(self.allocator, es);
        if (self.properties_initialized) {
            var it = self.properties.iterator();
            while (it.next()) |e| {
                self.allocator.free(e.key_ptr.*);
                intro.freeStringList(self.allocator, e.value_ptr.*);
            }
            self.properties.deinit();
            // `properties_fetched_at_ns` shares the same duped-key
            // lifetime as `properties`, so its keys are already freed
            // above. Tear down only the bucket array here.
            self.properties_fetched_at_ns.deinit();
            self.properties_initialized = false;
        }
        self.labels = null;
        self.edge_types = null;
    }

    /// Drop every cached allocation and reset all fetch timestamps so
    /// the next accessor call re-fetches. Keeps the StringHashMap
    /// bucket arrays around (clearRetainingCapacity) so the typical
    /// "drop after DDL → immediate re-warm" path doesn't churn the
    /// allocator.
    pub fn invalidate(self: *SchemaProvider) void {
        self.lockHere();
        defer self.unlockHere();

        if (self.labels) |ls| intro.freeStringList(self.allocator, ls);
        self.labels = null;
        self.labels_fetched_at_ns = 0;

        if (self.edge_types) |es| intro.freeStringList(self.allocator, es);
        self.edge_types = null;
        self.edge_types_fetched_at_ns = 0;

        var it = self.properties.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            intro.freeStringList(self.allocator, e.value_ptr.*);
        }
        self.properties.clearRetainingCapacity();
        self.properties_fetched_at_ns.clearRetainingCapacity();
    }

    /// Lazy fetch + cache of the user's visible node-label set.
    /// First call (or first call after TTL expiry / invalidate()) hits
    /// schema_introspection; otherwise returns the cached slice.
    pub fn getLabels(self: *SchemaProvider) ![]const []const u8 {
        self.lockHere();
        defer self.unlockHere();

        const now = nowNs();
        const stale = self.labels == null or (now - self.labels_fetched_at_ns) >= self.ttl_ns;
        if (stale) {
            if (self.labels) |ls| intro.freeStringList(self.allocator, ls);
            self.labels = try intro.listLabelsForUser(self.allocator, self.store, self.ctx);
            self.labels_fetched_at_ns = now;
        }
        return self.labels.?;
    }

    /// Lazy fetch + cache of the user's visible edge-type set.
    /// First call (or first call after TTL expiry / invalidate()) hits
    /// schema_introspection; otherwise returns the cached slice.
    pub fn getEdgeTypes(self: *SchemaProvider) ![]const []const u8 {
        self.lockHere();
        defer self.unlockHere();

        const now = nowNs();
        const stale = self.edge_types == null or (now - self.edge_types_fetched_at_ns) >= self.ttl_ns;
        if (stale) {
            if (self.edge_types) |es| intro.freeStringList(self.allocator, es);
            self.edge_types = try intro.listEdgeTypesForUser(self.allocator, self.store, self.ctx);
            self.edge_types_fetched_at_ns = now;
        }
        return self.edge_types.?;
    }

    /// Lazy fetch + cache of the property-key set observed on nodes
    /// carrying `label` in the caller's tenant. The cache key is an
    /// allocator-owned copy of `label`, so callers may pass slices
    /// whose lifetime ends before deinit(). Per-label TTL is tracked
    /// in `properties_fetched_at_ns` keyed by the same duped key as
    /// the `properties` map.
    pub fn getPropertiesFor(self: *SchemaProvider, label: []const u8) ![]const []const u8 {
        self.lockHere();
        defer self.unlockHere();

        const now = nowNs();
        if (self.properties.getEntry(label)) |entry| {
            const fetched_at = self.properties_fetched_at_ns.get(label) orelse 0;
            if ((now - fetched_at) < self.ttl_ns) {
                return entry.value_ptr.*;
            }
            // Stale: refetch in place, reusing the duped key.
            const owned_key = entry.key_ptr.*;
            intro.freeStringList(self.allocator, entry.value_ptr.*);
            const fresh = try intro.listPropertiesForLabelForUser(self.allocator, self.store, self.ctx, label);
            entry.value_ptr.* = fresh;
            try self.properties_fetched_at_ns.put(owned_key, now);
            return fresh;
        }

        const key = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(key);
        const props = try intro.listPropertiesForLabelForUser(self.allocator, self.store, self.ctx, label);
        errdefer intro.freeStringList(self.allocator, props);
        try self.properties.put(key, props);
        try self.properties_fetched_at_ns.put(key, now);
        return props;
    }
};

/// Monotonic-ish nanos. Mirrors `lspMonoNanos` in src/cli/lsp/server.zig:41.
/// We hit `std.os.linux` / `std.c` directly because `std.posix.clock_gettime`
/// is not stable in Zig 0.16. Only deltas are meaningful; on the unsupported
/// fallback this returns 0, which makes every call look "fresh enough" — but
/// the production targets (linux / macOS) both take the real branch.
fn nowNs() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else if (comptime @import("builtin").os.tag == .windows) {
        return @as(i128, @intCast(@as(u64, @intCast(@max(ts.sec, 0))))) * std.time.ns_per_s;
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}
