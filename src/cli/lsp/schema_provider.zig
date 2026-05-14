// CANARY: REQ=REQ-LSP-SCHEMA-PROVIDER-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=LazyFetchCache; STATUS=TESTED; TEST=src/cli/lsp/schema_provider_test.zig; OWNER=lsp; UPDATED=2026-05-14
//
// LSP-side lazy-fetch wrapper around src/execution/schema_introspection.zig.
//
// Scope (Task 6 only):
//   - Lazy first-fetch caching of labels, edge types, and per-label
//     property lists, keyed by IntrospectionContext (user/tenant/role/graph).
//   - Idempotent accessor methods — calling getLabels() twice returns the
//     same cached slice (no re-fetch).
//   - Single-owner deinit that releases every cached allocation.
//
// Out of scope (deferred):
//   - TTL expiry + invalidate()                  -> Task 7
//   - Mutex / thread-safety                      -> Task 8
//   - DDL-driven schema_change_notifier hook     -> Task 9
//
// The `properties_initialized` flag exists so Task 7's `invalidate()` can
// reset the cache without forcing the StringHashMap to be re-initialized
// from scratch (deinit would otherwise double-free if invalidate runs
// after a no-op init).
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
    allocator: std.mem.Allocator,
    store: *graph_store.GraphStore,
    ctx: intro.IntrospectionContext,

    labels: ?[][]const u8 = null,
    edge_types: ?[][]const u8 = null,
    properties: std.StringHashMap([][]const u8) = undefined,
    properties_initialized: bool = false,

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
            self.properties_initialized = false;
        }
        self.labels = null;
        self.edge_types = null;
    }

    /// Lazy fetch + cache of the user's visible node-label set.
    /// First call hits schema_introspection; subsequent calls return
    /// the cached slice without re-fetching.
    pub fn getLabels(self: *SchemaProvider) ![]const []const u8 {
        if (self.labels == null) {
            self.labels = try intro.listLabelsForUser(self.allocator, self.store, self.ctx);
        }
        return self.labels.?;
    }

    /// Lazy fetch + cache of the user's visible edge-type set.
    /// First call hits schema_introspection; subsequent calls return
    /// the cached slice without re-fetching.
    pub fn getEdgeTypes(self: *SchemaProvider) ![]const []const u8 {
        if (self.edge_types == null) {
            self.edge_types = try intro.listEdgeTypesForUser(self.allocator, self.store, self.ctx);
        }
        return self.edge_types.?;
    }

    /// Lazy fetch + cache of the property-key set observed on nodes
    /// carrying `label` in the caller's tenant. The cache key is an
    /// allocator-owned copy of `label`, so callers may pass slices
    /// whose lifetime ends before deinit().
    pub fn getPropertiesFor(self: *SchemaProvider, label: []const u8) ![]const []const u8 {
        if (self.properties.get(label)) |existing| return existing;
        const key = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(key);
        const props = try intro.listPropertiesForLabelForUser(self.allocator, self.store, self.ctx, label);
        try self.properties.put(key, props);
        return props;
    }
};
