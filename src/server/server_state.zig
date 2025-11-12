const std = @import("std");

// CANARY: REQ=REQ-SERVER-REFACTOR-001; FEATURE="ServerRefactoring"; ASPECT=SERVER_STATE; STATUS=PARTIAL; OWNER=refactor; UPDATED=2025-11-12
// Phase 3 M3.1 - Server State Management Module (Incremental Extraction)
// Extracting support types and session management types

/// Value inserted during a transaction with MVCC tracking
pub const ServerStateInsertedValue = struct {
    value: []const u8,
    creator_txn: u64,
    commit_ts: ?u64 = null,
    aborted: bool = false,
};

/// Catalog schema definition for managing database schemas
pub const CatalogSchema = struct {
    name: []const u8,
    created_at: i64,
    created_by: []const u8 = "system",
    description: ?[]const u8 = null,
};

/// Catalog graph definition for managing database graphs
pub const CatalogGraph = struct {
    name: []const u8,
    schema_name: ?[]const u8 = null,
    property_graph: bool = true,
    created_at: i64,
    created_by: []const u8 = "system",
    description: ?[]const u8 = null,
    node_count: u64 = 0,
    edge_count: u64 = 0,
};

/// Session parameter value types for session configuration
pub const SessionParameterValue = union(enum) {
    String: []const u8,
    Graph: []const u8,
    BindingTable: []const u8,
    Value: []const u8,
    Integer: i64,
    Float: f64,
    Boolean: bool,
};

/// Session reset type specifying what to reset in session configuration
pub const SessionResetType = union(enum) {
    AllParameters,
    AllCharacteristics,
    Schema,
    Graph,
    TimeZone,
    Parameter: []const u8,
};

/// Session configuration managing schema, graph, timezone and parameters
pub const SessionConfiguration = struct {
    // Schema settings
    current_schema: ?[]const u8 = null,

    // Graph settings
    current_graph: ?[]const u8 = null,
    property_graph_default: bool = true,

    // Time zone settings
    time_zone: ?[]const u8 = null,

    // Session parameters (key-value pairs)
    parameters: std.StringHashMap(SessionParameterValue),

    // Allocator for parameter storage
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionConfiguration {
        return .{
            .parameters = std.StringHashMap(SessionParameterValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionConfiguration) void {
        // Free all parameter keys and values
        var iterator = self.parameters.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .String => |s| self.allocator.free(s),
                .Graph => |g| self.allocator.free(g),
                .BindingTable => |bt| self.allocator.free(bt),
                else => {},
            }
        }
        self.parameters.deinit();

        // Free schema and graph names if allocated
        if (self.current_schema) |schema| {
            self.allocator.free(schema);
        }
        if (self.current_graph) |graph| {
            self.allocator.free(graph);
        }
        if (self.time_zone) |tz| {
            self.allocator.free(tz);
        }
    }

    pub fn setParameter(self: *SessionConfiguration, name: []const u8, value: SessionParameterValue) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        try self.parameters.put(owned_name, value);
    }

    pub fn getParameter(self: *SessionConfiguration, name: []const u8) ?SessionParameterValue {
        return self.parameters.get(name);
    }

    pub fn removeParameter(self: *SessionConfiguration, name: []const u8) void {
        if (self.parameters.fetchRemove(name)) |kv| {
            self.allocator.free(kv.key);
            switch (kv.value) {
                .String => |s| self.allocator.free(s),
                .Graph => |g| self.allocator.free(g),
                .BindingTable => |bt| self.allocator.free(bt),
                else => {},
            }
        }
    }

    pub fn reset(self: *SessionConfiguration, reset_type: SessionResetType) void {
        switch (reset_type) {
            .AllParameters => {
                // Clear all parameters
                var iterator = self.parameters.iterator();
                while (iterator.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    switch (entry.value_ptr.*) {
                        .String => |s| self.allocator.free(s),
                        .Graph => |g| self.allocator.free(g),
                        .BindingTable => |bt| self.allocator.free(bt),
                        else => {},
                    }
                }
                self.parameters.clearAndFree();
            },
            .AllCharacteristics => {
                // Reset all session characteristics (schema, graph, time zone, etc.)
                if (self.current_schema) |schema| {
                    self.allocator.free(schema);
                    self.current_schema = null;
                }
                if (self.current_graph) |graph| {
                    self.allocator.free(graph);
                    self.current_graph = null;
                }
                if (self.time_zone) |tz| {
                    self.allocator.free(tz);
                    self.time_zone = null;
                }
                self.property_graph_default = true;
            },
            .Schema => {
                if (self.current_schema) |schema| {
                    self.allocator.free(schema);
                    self.current_schema = null;
                }
            },
            .Graph => {
                if (self.current_graph) |graph| {
                    self.allocator.free(graph);
                    self.current_graph = null;
                }
                self.property_graph_default = true;
            },
            .TimeZone => {
                if (self.time_zone) |tz| {
                    self.allocator.free(tz);
                    self.time_zone = null;
                }
            },
            .Parameter => |param_name| {
                self.removeParameter(param_name);
            },
        }
    }
};

/// Union operation metrics tracking input/output rows and hash table size
pub const UnionMetrics = struct {
    left_in: usize,
    right_in: usize,
    out: usize,
    hash_size: ?usize,
};

// NOTE: ServerState struct extraction deferred due to complex dependency issues discovered:
// 1. ServerState references mvcc.MVCCManager but mvcc import is commented out in main.zig (line 20)
// 2. ServerState references query_plan_cache.QueryOptimizer but import is commented out (line 22)
// 3. ServerState uses late-bound imports like @import("cdc_enhanced") at field level
// 4. ServerState depends on SessionConfiguration (now extracted above)
//
// These issues require careful resolution before safe extraction.
// Following "incremental approach mandatory" - extracting simple types and session management first.

