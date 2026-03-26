const graph_store_mod = @import("../graph_store.zig");

/// GraphStore is the sole storage layer (legacy PageManager/WAL removed).
pub const GraphStore = graph_store_mod.GraphStore;
pub const Node = graph_store_mod.Node;
pub const Edge = graph_store_mod.Edge;
pub const PropertyValue = graph_store_mod.PropertyValue;

/// Storage utilities for GraphStore
pub const backup = @import("backup.zig");
pub const tde_file_encryption = @import("tde_file_encryption.zig");
pub const heap = @import("heap.zig");
/// graph-storage adapter (primary per-graph storage engine)
pub const graph_storage_adapter = @import("graph_storage_adapter.zig");
