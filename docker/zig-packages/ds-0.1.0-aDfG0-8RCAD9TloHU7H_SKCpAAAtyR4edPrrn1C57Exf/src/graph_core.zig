// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Fast non-cryptographic PRNG for generating vertex/edge IDs.
/// Seeded once from std.crypto.random; protected by a mutex for thread safety.
var id_prng: std.Random.DefaultPrng = undefined;
var id_prng_initialized: bool = false;
var id_prng_mutex: std.Thread.Mutex = .{};

fn generateIdInt() u128 {
    id_prng_mutex.lock();
    defer id_prng_mutex.unlock();

    if (!id_prng_initialized) {
        var seed: [8]u8 = undefined;
        std.crypto.random.bytes(&seed);
        id_prng = std.Random.DefaultPrng.init(@bitCast(seed));
        id_prng_initialized = true;
    }
    return id_prng.random().int(u128);
}

/// Vertex represents a graph node with an ID, value, and edges.
pub fn Vertex(comptime T: type) type {
    return struct {
        const Self = @This();
        const EdgeType = Edge(T);

        id: []const u8,
        value: T,
        edges: std.ArrayListUnmanaged(*EdgeType),
        allocator: Allocator,
        owns_id: bool, // Track if we allocated the ID string

        /// Create a new vertex with a generated UUID
        pub fn init(allocator: Allocator, value: T) Allocator.Error!*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            // Generate a simple ID (UUID would require external dependency)
            // Buffer is 36 bytes, format produces 32 hex chars - verified at comptime
            var buf: [36]u8 = undefined;
            comptime std.debug.assert(36 >= 32); // Ensure buffer can hold 32 hex chars
            const id_str = std.fmt.bufPrint(&buf, "{x:0>32}", .{generateIdInt()}) catch
                unreachable; // buffer is statically verified to be large enough
            const owned_id = try allocator.dupe(u8, id_str);

            self.* = .{
                .id = owned_id,
                .value = value,
                .edges = .{},
                .allocator = allocator,
                .owns_id = true,
            };
            return self;
        }

        /// Create a vertex with a specific ID (for parser/deserialization)
        pub fn initWithId(allocator: Allocator, id: []const u8, value: T) Allocator.Error!*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            const owned_id = try allocator.dupe(u8, id);

            self.* = .{
                .id = owned_id,
                .value = value,
                .edges = .{},
                .allocator = allocator,
                .owns_id = true,
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.owns_id) {
                self.allocator.free(self.id);
            }
            self.edges.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn addEdge(self: *Self, edge: *EdgeType) Allocator.Error!void {
            try self.edges.append(self.allocator, edge);
        }

        pub fn getEdges(self: *Self) []const *EdgeType {
            return self.edges.items;
        }

        pub fn compare(self: *Self, other: *Self) std.math.Order {
            return std.mem.order(u8, self.id, other.id);
        }

        pub fn eql(self: *Self, other: *Self) bool {
            return std.mem.eql(u8, self.id, other.id);
        }
    };
}

/// Edge types using tagged union
pub fn Edge(comptime T: type) type {
    return union(enum) {
        const Self = @This();
        const VertexType = Vertex(T);

        basic: BasicEdge(T),
        directed: DirectedEdge(T),
        weighted: WeightedEdge(T),
        directed_weighted: DirectedWeightedEdge(T),

        pub fn getVertices(self: *const Self) [2]*VertexType {
            return switch (self.*) {
                .basic => |*e| .{ e.parent, e.child },
                .directed => |*e| .{ e.basic.parent, e.basic.child },
                .weighted => |*e| .{ e.basic.parent, e.basic.child },
                .directed_weighted => |*e| .{ e.weighted.basic.parent, e.weighted.basic.child },
            };
        }

        pub fn getValue(self: *const Self) T {
            return switch (self.*) {
                .basic => |*e| e.value,
                .directed => |*e| e.basic.value,
                .weighted => |*e| e.basic.value,
                .directed_weighted => |*e| e.weighted.basic.value,
            };
        }

        pub fn getParent(self: *const Self) ?*VertexType {
            return switch (self.*) {
                .directed => |*e| e.basic.parent,
                .directed_weighted => |*e| e.weighted.basic.parent,
                else => null,
            };
        }

        pub fn getChild(self: *const Self) ?*VertexType {
            return switch (self.*) {
                .directed => |*e| e.basic.child,
                .directed_weighted => |*e| e.weighted.basic.child,
                else => null,
            };
        }

        pub fn getWeight(self: *const Self) ?f64 {
            return switch (self.*) {
                .weighted => |*e| e.weight,
                .directed_weighted => |*e| e.weighted.weight,
                else => null,
            };
        }

        /// Set the weight on a weighted edge variant.
        /// Returns true if the weight was applied, false for non-weighted edges.
        pub fn setWeight(self: *Self, weight: f64) bool {
            switch (self.*) {
                .weighted => |*e| {
                    e.weight = weight;
                    return true;
                },
                .directed_weighted => |*e| {
                    e.weighted.weight = weight;
                    return true;
                },
                else => return false,
            }
        }

        pub fn isDirected(self: *const Self) bool {
            return switch (self.*) {
                .directed, .directed_weighted => true,
                else => false,
            };
        }

        pub fn isWeighted(self: *const Self) bool {
            return switch (self.*) {
                .weighted, .directed_weighted => true,
                else => false,
            };
        }

        /// Free the ID owned by this edge
        pub fn deinit(self: *Self, allocator: Allocator) void {
            switch (self.*) {
                .basic => |*e| {
                    if (e.owns_id) {
                        e.allocator.free(e.id);
                    }
                },
                .directed => |*e| {
                    if (e.basic.owns_id) {
                        e.basic.allocator.free(e.basic.id);
                    }
                },
                .weighted => |*e| {
                    if (e.basic.owns_id) {
                        e.basic.allocator.free(e.basic.id);
                    }
                },
                .directed_weighted => |*e| {
                    if (e.weighted.basic.owns_id) {
                        e.weighted.basic.allocator.free(e.weighted.basic.id);
                    }
                },
            }
            allocator.destroy(self);
        }
    };
}

pub fn BasicEdge(comptime T: type) type {
    return struct {
        id: []const u8,
        parent: *Vertex(T),
        child: *Vertex(T),
        value: T,
        allocator: Allocator,
        owns_id: bool,

        pub fn init(allocator: Allocator, parent: *Vertex(T), child: *Vertex(T), value: T) Allocator.Error!*@This() {
            const self = try allocator.create(@This());
            errdefer allocator.destroy(self);

            // Buffer is 36 bytes, format produces 32 hex chars - verified at comptime
            var buf: [36]u8 = undefined;
            comptime std.debug.assert(36 >= 32);
            const id_str = std.fmt.bufPrint(&buf, "{x:0>32}", .{generateIdInt()}) catch
                unreachable; // buffer is statically verified to be large enough
            const owned_id = try allocator.dupe(u8, id_str);

            self.* = .{
                .id = owned_id,
                .parent = parent,
                .child = child,
                .value = value,
                .allocator = allocator,
                .owns_id = true,
            };
            return self;
        }

        /// Create a stack-allocated BasicEdge value (no heap alloc for the struct itself).
        /// Used by createEdge to avoid a temporary heap allocation per edge.
        fn initValue(allocator: Allocator, parent: *Vertex(T), child: *Vertex(T), value: T) Allocator.Error!@This() {
            var buf: [36]u8 = undefined;
            comptime std.debug.assert(36 >= 32);
            const id_str = std.fmt.bufPrint(&buf, "{x:0>32}", .{generateIdInt()}) catch
                unreachable;
            const owned_id = try allocator.dupe(u8, id_str);
            return .{
                .id = owned_id,
                .parent = parent,
                .child = child,
                .value = value,
                .allocator = allocator,
                .owns_id = true,
            };
        }

        pub fn deinit(self: *@This()) void {
            if (self.owns_id) {
                self.allocator.free(self.id);
            }
            self.allocator.destroy(self);
        }
    };
}

pub fn DirectedEdge(comptime T: type) type {
    return struct {
        basic: BasicEdge(T),
    };
}

pub fn WeightedEdge(comptime T: type) type {
    return struct {
        basic: BasicEdge(T),
        weight: f64,
    };
}

pub fn DirectedWeightedEdge(comptime T: type) type {
    return struct {
        weighted: WeightedEdge(T),
    };
}

/// Edge builder options
pub const EdgeOptions = struct {
    directed: bool = false,
    weighted: bool = false,
    weight: f64 = 0.0,
};

/// Create an edge with options
pub fn createEdge(
    comptime T: type,
    allocator: Allocator,
    parent: *Vertex(T),
    child: *Vertex(T),
    value: T,
    options: EdgeOptions,
) Allocator.Error!*Edge(T) {
    const edge_ptr = try allocator.create(Edge(T));
    errdefer allocator.destroy(edge_ptr);

    // Use stack-allocated BasicEdge (no temp heap alloc per edge)
    const basic = try BasicEdge(T).initValue(allocator, parent, child, value);
    errdefer allocator.free(basic.id);

    if (options.directed and options.weighted) {
        edge_ptr.* = .{
            .directed_weighted = .{
                .weighted = .{
                    .basic = basic,
                    .weight = options.weight,
                },
            },
        };
    } else if (options.directed) {
        edge_ptr.* = .{
            .directed = .{
                .basic = basic,
            },
        };
    } else if (options.weighted) {
        edge_ptr.* = .{
            .weighted = .{
                .basic = basic,
                .weight = options.weight,
            },
        };
    } else {
        edge_ptr.* = .{ .basic = basic };
    }

    // Add edge to both vertices
    try parent.addEdge(edge_ptr);
    try child.addEdge(edge_ptr);

    return edge_ptr;
}

test "Vertex - basic operations" {
    const testing = std.testing;

    const v1 = try Vertex(i32).init(testing.allocator, 42);
    defer v1.deinit();

    try testing.expectEqual(@as(i32, 42), v1.value);
    try testing.expect(v1.id.len > 0);
    try testing.expectEqual(@as(usize, 0), v1.edges.items.len);
}

test "Vertex - with custom ID" {
    const testing = std.testing;

    const v1 = try Vertex([]const u8).initWithId(testing.allocator, "node1", "value1");
    defer v1.deinit();

    try testing.expectEqualStrings("node1", v1.id);
    try testing.expectEqualStrings("value1", v1.value);
}

test "Edge - basic edge" {
    const testing = std.testing;

    const v1 = try Vertex(i32).init(testing.allocator, 1);
    defer v1.deinit();
    const v2 = try Vertex(i32).init(testing.allocator, 2);
    defer v2.deinit();

    var edge = try createEdge(i32, testing.allocator, v1, v2, 10, .{});
    defer edge.deinit(testing.allocator);

    try testing.expect(!edge.isDirected());
    try testing.expect(!edge.isWeighted());
    try testing.expectEqual(@as(i32, 10), edge.getValue());

    const vertices = edge.getVertices();
    try testing.expect(vertices[0].eql(v1));
    try testing.expect(vertices[1].eql(v2));
}

test "Edge - directed edge" {
    const testing = std.testing;

    const v1 = try Vertex(i32).init(testing.allocator, 1);
    defer v1.deinit();
    const v2 = try Vertex(i32).init(testing.allocator, 2);
    defer v2.deinit();

    var edge = try createEdge(i32, testing.allocator, v1, v2, 10, .{ .directed = true });
    defer edge.deinit(testing.allocator);

    try testing.expect(edge.isDirected());
    try testing.expect(!edge.isWeighted());
    try testing.expect(edge.getParent().?.eql(v1));
    try testing.expect(edge.getChild().?.eql(v2));
}

test "Edge - weighted edge" {
    const testing = std.testing;

    const v1 = try Vertex(i32).init(testing.allocator, 1);
    defer v1.deinit();
    const v2 = try Vertex(i32).init(testing.allocator, 2);
    defer v2.deinit();

    var edge = try createEdge(i32, testing.allocator, v1, v2, 10, .{ .weighted = true, .weight = 5.5 });
    defer edge.deinit(testing.allocator);

    try testing.expect(!edge.isDirected());
    try testing.expect(edge.isWeighted());
    try testing.expectEqual(@as(?f64, 5.5), edge.getWeight());

    try testing.expect(edge.setWeight(7.5));
    try testing.expectEqual(@as(?f64, 7.5), edge.getWeight());
}

test "Edge - directed weighted edge" {
    const testing = std.testing;

    const v1 = try Vertex(i32).init(testing.allocator, 1);
    defer v1.deinit();
    const v2 = try Vertex(i32).init(testing.allocator, 2);
    defer v2.deinit();

    var edge = try createEdge(i32, testing.allocator, v1, v2, 10, .{
        .directed = true,
        .weighted = true,
        .weight = 3.14,
    });
    defer edge.deinit(testing.allocator);

    try testing.expect(edge.isDirected());
    try testing.expect(edge.isWeighted());
    try testing.expectEqual(@as(?f64, 3.14), edge.getWeight());
    try testing.expect(edge.getParent().?.eql(v1));
    try testing.expect(edge.getChild().?.eql(v2));
}
