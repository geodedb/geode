// Raft apply callback — routes committed Command variants to GraphStore mutations.
//
// This module provides the bridge between the Raft consensus layer and the
// graph storage engine.  When a Raft entry is committed, `drainReady()` in
// `raft_consensus.zig` calls the registered `apply_callback`.  The callback
// dispatches on the Command variant, applies side-effects to the GraphStore,
// and returns an (optional) result payload.
//
// Thread-safety: the callback runs inside the Raft tick loop which is
// single-threaded per RaftNode.  The GraphStore itself uses internal locking,
// so concurrent access from the query engine is safe.

const std = @import("std");
const Allocator = std.mem.Allocator;
const raft_consensus = @import("raft_consensus.zig");
const Command = raft_consensus.Command;
const GraphMutation = raft_consensus.GraphMutation;
const SchemaChange = raft_consensus.SchemaChange;
const graph_store_mod = @import("../graph_store.zig");
const GraphStore = graph_store_mod.GraphStore;

const logging = @import("logging");
const log = logging.scoped("raft_apply");
const Attr = logging.Attr;

// ---------------------------------------------------------------------------
// Module-level store reference (MVP approach)
//
// The Raft apply_callback is a plain function pointer — no closure context.
// We use a module-level variable so `applyCallbackFn` can reach the store.
// `setGlobalStore` must be called once during coordinator/server init before
// the Raft node starts ticking.
// ---------------------------------------------------------------------------

var g_store: ?*GraphStore = null;

/// Register the graph store used by the apply callback.
/// Must be called before the Raft node begins processing committed entries.
pub fn setGlobalStore(store: *GraphStore) void {
    g_store = store;
}

/// Return the currently registered store (useful in tests / diagnostics).
pub fn getGlobalStore() ?*GraphStore {
    return g_store;
}

/// Reset the global store to null (for test isolation).
pub fn resetGlobalStore() void {
    g_store = null;
}

// ---------------------------------------------------------------------------
// Apply callback — matches the RaftNode.apply_callback signature
// ---------------------------------------------------------------------------

/// Function-pointer-compatible callback for `RaftNode.apply_callback`.
/// Delegates to `applyCommand` using the module-level `g_store`.
pub fn applyCallbackFn(allocator: Allocator, cmd: Command) anyerror![]u8 {
    return applyCommand(allocator, g_store, cmd);
}

// ---------------------------------------------------------------------------
// Core routing logic
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GQL-RAFT-APPLY; FEATURE="Raft Apply Callback"; ASPECT=CommandRouting; STATUS=TESTED; TEST="applyCommand: noop returns empty slice"; OWNER=distributed; UPDATED=2026-04-10

/// Route a committed Raft `Command` to the appropriate graph-store mutation.
///
/// Returns a result payload (caller-owned).  For most MVP paths this is an
/// empty slice allocated from `allocator`; the caller must free it.
pub fn applyCommand(allocator: Allocator, store: ?*GraphStore, command: Command) ![]u8 {
    switch (command) {
        // ---- no-op: nothing to apply ----
        .noop => {
            return allocator.alloc(u8, 0);
        },

        // ---- key-value write (MVP: log and return empty) ----
        .write => |data| {
            log.info("raft apply: write command received", &.{
                Attr.uint("data_len", data.len),
            });
            // MVP: we do not persist generic key-value writes yet.
            // Future: store as metadata node or in a sidecar KV map.
            return allocator.alloc(u8, 0);
        },

        // ---- graph mutation: dispatch to store ----
        .graph_mutation => |gm| {
            return applyGraphMutation(allocator, store, gm);
        },

        // ---- schema change: dispatch to store ----
        .schema_change => |sc| {
            return applySchemaChange(allocator, store, sc);
        },

        // ---- not yet implemented — log a warning and skip ----
        .config_change => {
            log.warn("raft apply: config_change not yet implemented, skipping", &.{});
            return allocator.alloc(u8, 0);
        },
        .snapshot_pointer => {
            log.warn("raft apply: snapshot_pointer not yet implemented, skipping", &.{});
            return allocator.alloc(u8, 0);
        },
        .txn_prepare => {
            log.warn("raft apply: txn_prepare not yet implemented, skipping", &.{});
            return allocator.alloc(u8, 0);
        },
        .txn_decide => {
            log.warn("raft apply: txn_decide not yet implemented, skipping", &.{});
            return allocator.alloc(u8, 0);
        },
    }
}

// ---------------------------------------------------------------------------
// Graph mutation handler
// ---------------------------------------------------------------------------

fn applyGraphMutation(allocator: Allocator, store_opt: ?*GraphStore, gm: GraphMutation) ![]u8 {
    const store = store_opt orelse {
        log.err("raft apply: graph_mutation received but no store registered", &.{});
        return error.StoreNotAvailable;
    };

    const graph_name: []const u8 = if (gm.graph.len > 0) gm.graph else "default";

    // Ensure the target graph exists (idempotent).
    store.createGraph(graph_name) catch |err| switch (err) {
        error.GraphAlreadyExists => {}, // fine — idempotent
        else => return err,
    };

    switch (gm.mutation_type) {
        .create => {
            // MVP: create a node in the target graph.
            // The `data` field contains opaque mutation bytes — for now we
            // create an unlabelled node and attach the raw data as a property
            // so the round-trip is observable in tests.
            const labels = &[_][]const u8{};
            const node_id = try store.createNodeWithGraph(labels, graph_name);

            if (gm.data.len > 0) {
                try store.setNodeProperty(
                    node_id,
                    "_raft_data",
                    graph_store_mod.PropertyValue{ .String = gm.data },
                );
            }

            log.info("raft apply: created node via graph_mutation", &.{
                Attr.uint("node_id", node_id),
                Attr.string("graph", graph_name),
            });

            // Return the created node ID as a little-endian u64.
            const result = try allocator.alloc(u8, 8);
            std.mem.writeInt(u64, result[0..8], node_id, .little);
            return result;
        },

        .delete => {
            // MVP: log and skip — full delete routing requires node ID parsing.
            log.warn("raft apply: graph_mutation delete not fully wired, skipping", &.{
                Attr.string("graph", graph_name),
            });
            return allocator.alloc(u8, 0);
        },

        .update, .merge => {
            // MVP: log and skip.
            log.warn("raft apply: graph_mutation update/merge not fully wired, skipping", &.{
                Attr.string("graph", graph_name),
            });
            return allocator.alloc(u8, 0);
        },
    }
}

// ---------------------------------------------------------------------------
// Schema change handler
// ---------------------------------------------------------------------------

fn applySchemaChange(allocator: Allocator, store_opt: ?*GraphStore, sc: SchemaChange) ![]u8 {
    const store = store_opt orelse {
        log.err("raft apply: schema_change received but no store registered", &.{});
        return error.StoreNotAvailable;
    };

    switch (sc.operation) {
        .create_graph => {
            store.createGraph(sc.graph) catch |err| switch (err) {
                error.GraphAlreadyExists => {}, // idempotent
                else => return err,
            };
            log.info("raft apply: created graph via schema_change", &.{
                Attr.string("graph", sc.graph),
            });
        },

        .drop_graph => {
            store.dropGraph(sc.graph) catch |err| switch (err) {
                error.GraphNotFound => {}, // idempotent
                error.CannotDropDefaultGraph => {
                    log.warn("raft apply: attempted to drop default graph, ignoring", &.{});
                },
                else => return err,
            };
            log.info("raft apply: dropped graph via schema_change", &.{
                Attr.string("graph", sc.graph),
            });
        },

        .alter_graph => {
            log.warn("raft apply: alter_graph not yet implemented, skipping", &.{
                Attr.string("graph", sc.graph),
            });
        },
    }

    return allocator.alloc(u8, 0);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "applyCommand: noop returns empty slice" {
    const allocator = std.testing.allocator;
    const result = try applyCommand(allocator, null, .noop);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "applyCommand: write returns empty slice (MVP)" {
    const allocator = std.testing.allocator;
    const result = try applyCommand(allocator, null, .{ .write = "key=value" });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "applyCommand: config_change returns empty slice" {
    const allocator = std.testing.allocator;
    const result = try applyCommand(allocator, null, .{ .config_change = .{
        .change_type = .add_server,
        .server_id = 42,
        .server_endpoint = "10.0.0.1",
    } });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "applyCommand: snapshot_pointer returns empty slice" {
    const allocator = std.testing.allocator;
    const result = try applyCommand(allocator, null, .{ .snapshot_pointer = .{
        .last_included_index = 1,
        .last_included_term = 1,
        .size_bytes = 0,
        .checksum = 0,
    } });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "applyCommand: txn_prepare returns empty slice" {
    const allocator = std.testing.allocator;
    const result = try applyCommand(allocator, null, .{ .txn_prepare = .{
        .xid = 1,
        .shard_id = 0,
        .write_set = "",
        .metadata = "",
    } });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "applyCommand: txn_decide returns empty slice" {
    const allocator = std.testing.allocator;
    const result = try applyCommand(allocator, null, .{ .txn_decide = .{
        .xid = 1,
        .commit = true,
    } });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "applyCommand: graph_mutation without store returns StoreNotAvailable" {
    const allocator = std.testing.allocator;
    const result = applyCommand(allocator, null, .{ .graph_mutation = .{
        .graph = "test_graph",
        .mutation_type = .create,
        .data = "test",
        .txn_id = null,
    } });
    try std.testing.expectError(error.StoreNotAvailable, result);
}

test "applyCommand: schema_change without store returns StoreNotAvailable" {
    const allocator = std.testing.allocator;
    const result = applyCommand(allocator, null, .{ .schema_change = .{
        .operation = .create_graph,
        .graph = "new_graph",
        .schema = "",
    } });
    try std.testing.expectError(error.StoreNotAvailable, result);
}

test "applyCommand: graph_mutation create with store creates node" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const result = try applyCommand(allocator, &store, .{ .graph_mutation = .{
        .graph = "test_graph",
        .mutation_type = .create,
        .data = "hello",
        .txn_id = null,
    } });
    defer allocator.free(result);

    // Result should contain a u64 node ID
    try std.testing.expectEqual(@as(usize, 8), result.len);
    const node_id = std.mem.readInt(u64, result[0..8], .little);
    try std.testing.expect(node_id > 0);

    // Verify the graph was created
    try std.testing.expect(store.graphs.contains("test_graph"));
}

test "applyCommand: schema_change create_graph creates graph" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    const result = try applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .create_graph,
        .graph = "my_graph",
        .schema = "",
    } });
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);

    // Graph should exist
    try std.testing.expect(store.graphs.contains("my_graph"));
}

test "applyCommand: schema_change create_graph is idempotent" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    // Create once
    const r1 = try applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .create_graph,
        .graph = "idem_graph",
        .schema = "",
    } });
    defer allocator.free(r1);

    // Create again — should not error
    const r2 = try applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .create_graph,
        .graph = "idem_graph",
        .schema = "",
    } });
    defer allocator.free(r2);
}

test "applyCommand: schema_change drop_graph drops graph" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    try store.createGraph("temp_graph");
    try std.testing.expect(store.graphs.contains("temp_graph"));

    const result = try applyCommand(allocator, &store, .{ .schema_change = .{
        .operation = .drop_graph,
        .graph = "temp_graph",
        .schema = "",
    } });
    defer allocator.free(result);

    try std.testing.expect(!store.graphs.contains("temp_graph"));
}

test "setGlobalStore and getGlobalStore round-trip" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(?*GraphStore, null), getGlobalStore());

    setGlobalStore(&store);
    try std.testing.expectEqual(@as(?*GraphStore, &store), getGlobalStore());

    resetGlobalStore();
    try std.testing.expectEqual(@as(?*GraphStore, null), getGlobalStore());
}

test "applyCallbackFn delegates to applyCommand via g_store" {
    const allocator = std.testing.allocator;
    var store = try GraphStore.init(allocator);
    defer store.deinit();

    setGlobalStore(&store);
    defer resetGlobalStore();

    // Use the function-pointer-compatible callback
    const result = try applyCallbackFn(allocator, .noop);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
