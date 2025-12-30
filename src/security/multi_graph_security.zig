// CANARY: REQ=REQ-MULTI-GRAPH-SECURITY-001; FEATURE="MultiGraphSecurity"; ASPECT=RBACGraphScope; STATUS=IMPL; OWNER=security; UPDATED=2025-12-20
// Multi-Graph Security Extensions
// Extends RBAC, FLE, and Audit with graph-scoped access control

const std = @import("std");
const Allocator = std.mem.Allocator;
const auth = @import("geode_auth");

// ============================================================================
// Graph-Scoped RBAC
// ============================================================================

/// Graph-scoped role assignment
/// Allows users to have different roles in different graphs
pub const GraphRoleAssignment = struct {
    user_id: auth.UserId,
    role_id: auth.RoleId,
    graph_name: []const u8,
    granted_at: i64,
    granted_by: ?auth.UserId,
};

/// Graph-scoped permission
/// Extends base Permission with graph context
pub const GraphPermission = struct {
    id: auth.PermissionId,
    name: []const u8,
    graph_name: ?[]const u8, // null = all graphs (global permission)
    resource: []const u8,
    action: auth.Action,
    conditions: ?[]const u8,
    created_at: i64,
};

/// Composite key for graph-scoped role lookups
pub const GraphRoleKey = struct {
    user_id: auth.UserId,
    graph_name_hash: u64,

    pub fn init(user_id: auth.UserId, graph_name: []const u8) GraphRoleKey {
        return .{
            .user_id = user_id,
            .graph_name_hash = std.hash.Wyhash.hash(0, graph_name),
        };
    }
};

/// Graph-aware RBAC policy manager
pub const GraphRBACPolicy = struct {
    allocator: Allocator,

    /// Graph-scoped role assignments: (user_id, graph_hash) -> roles
    graph_user_roles: std.AutoHashMap(GraphRoleKey, std.ArrayList(auth.RoleId)),

    /// Global role assignments (apply to all graphs)
    global_user_roles: std.AutoHashMap(auth.UserId, std.ArrayList(auth.RoleId)),

    /// Role permissions (unchanged - roles have same permissions across graphs)
    role_permissions: std.AutoHashMap(auth.RoleId, std.ArrayList(auth.Permission)),

    /// Role hierarchy
    role_hierarchy: std.AutoHashMap(auth.RoleId, std.ArrayList(auth.RoleId)),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .graph_user_roles = std.AutoHashMap(GraphRoleKey, std.ArrayList(auth.RoleId)).init(allocator),
            .global_user_roles = std.AutoHashMap(auth.UserId, std.ArrayList(auth.RoleId)).init(allocator),
            .role_permissions = std.AutoHashMap(auth.RoleId, std.ArrayList(auth.Permission)).init(allocator),
            .role_hierarchy = std.AutoHashMap(auth.RoleId, std.ArrayList(auth.RoleId)).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Free graph user roles
        var git = self.graph_user_roles.iterator();
        while (git.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.graph_user_roles.deinit();

        // Free global user roles
        var uit = self.global_user_roles.iterator();
        while (uit.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.global_user_roles.deinit();

        // Free role permissions
        var pit = self.role_permissions.iterator();
        while (pit.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.role_permissions.deinit();

        // Free role hierarchy
        var hit = self.role_hierarchy.iterator();
        while (hit.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.role_hierarchy.deinit();
    }

    /// Assign a role to a user for a specific graph
    pub fn assignRoleForGraph(
        self: *Self,
        user_id: auth.UserId,
        role_id: auth.RoleId,
        graph_name: []const u8,
    ) !void {
        const key = GraphRoleKey.init(user_id, graph_name);

        if (self.graph_user_roles.getPtr(key)) |roles| {
            // Check if already assigned
            for (roles.items) |rid| {
                if (rid == role_id) return;
            }
            try roles.append(self.allocator, role_id);
        } else {
            var roles = try std.ArrayList(auth.RoleId).initCapacity(self.allocator, 1);
            try roles.append(self.allocator, role_id);
            try self.graph_user_roles.put(key, roles);
        }
    }

    /// Assign a global role (applies to all graphs)
    pub fn assignGlobalRole(
        self: *Self,
        user_id: auth.UserId,
        role_id: auth.RoleId,
    ) !void {
        if (self.global_user_roles.getPtr(user_id)) |roles| {
            for (roles.items) |rid| {
                if (rid == role_id) return;
            }
            try roles.append(self.allocator, role_id);
        } else {
            var roles = try std.ArrayList(auth.RoleId).initCapacity(self.allocator, 1);
            try roles.append(self.allocator, role_id);
            try self.global_user_roles.put(user_id, roles);
        }
    }

    /// Revoke a role from a user for a specific graph
    pub fn revokeRoleForGraph(
        self: *Self,
        user_id: auth.UserId,
        role_id: auth.RoleId,
        graph_name: []const u8,
    ) !void {
        const key = GraphRoleKey.init(user_id, graph_name);

        if (self.graph_user_roles.getPtr(key)) |roles| {
            for (roles.items, 0..) |rid, i| {
                if (rid == role_id) {
                    _ = roles.swapRemove(i);
                    return;
                }
            }
        }
    }

    /// Check if user has permission for a resource in a specific graph
    pub fn hasPermission(
        self: *Self,
        user_id: auth.UserId,
        graph_name: []const u8,
        resource: []const u8,
        action: auth.Action,
    ) bool {
        // Check graph-specific roles first
        const key = GraphRoleKey.init(user_id, graph_name);
        if (self.graph_user_roles.get(key)) |roles| {
            for (roles.items) |rid| {
                if (self.checkRolePermission(rid, resource, action)) return true;
            }
        }

        // Fall back to global roles
        if (self.global_user_roles.get(user_id)) |roles| {
            for (roles.items) |rid| {
                if (self.checkRolePermission(rid, resource, action)) return true;
            }
        }

        return false;
    }

    /// Get all roles for a user in a specific graph (including global)
    pub fn getRolesForGraph(
        self: *Self,
        allocator: Allocator,
        user_id: auth.UserId,
        graph_name: []const u8,
    ) ![]auth.RoleId {
        var result = std.ArrayList(auth.RoleId).init(allocator);
        errdefer result.deinit();

        // Add graph-specific roles
        const key = GraphRoleKey.init(user_id, graph_name);
        if (self.graph_user_roles.get(key)) |roles| {
            for (roles.items) |rid| {
                try result.append(rid);
            }
        }

        // Add global roles
        if (self.global_user_roles.get(user_id)) |roles| {
            for (roles.items) |rid| {
                // Avoid duplicates
                var found = false;
                for (result.items) |existing| {
                    if (existing == rid) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try result.append(rid);
                }
            }
        }

        return result.toOwnedSlice();
    }

    fn checkRolePermission(self: *Self, role_id: auth.RoleId, resource: []const u8, action: auth.Action) bool {
        if (self.role_permissions.get(role_id)) |perms| {
            for (perms.items) |perm| {
                if (std.mem.eql(u8, perm.resource, resource) and (perm.action == action or perm.action == .all)) {
                    return true;
                }
            }
        }
        // Check parent roles
        if (self.role_hierarchy.get(role_id)) |parents| {
            for (parents.items) |p| {
                if (self.checkRolePermission(p, resource, action)) return true;
            }
        }
        return false;
    }
};

// ============================================================================
// Graph-Scoped Security Context
// ============================================================================

/// Extended security context with graph awareness
pub const GraphSecurityContext = struct {
    user: *auth.User,
    roles: []const auth.Role,
    current_graph: ?[]const u8,
    session_attributes: std.StringHashMap([]const u8),
    request_attributes: std.StringHashMap([]const u8),
    environment: auth.EnvironmentInfo,

    /// Check if context has a specific permission in the current graph
    pub fn hasPermission(self: *const GraphSecurityContext, rbac: *GraphRBACPolicy, resource: []const u8, action: auth.Action) bool {
        if (self.user.is_superuser) return true;
        const graph = self.current_graph orelse return false;
        return rbac.hasPermission(self.user.id, graph, resource, action);
    }
};

// ============================================================================
// Graph-Scoped FLE Catalog
// ============================================================================

/// Graph-scoped FLE type key
pub const GraphTypeKey = struct {
    graph_name: []const u8,
    type_name: []const u8,

    pub fn format(self: GraphTypeKey, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}.{s}", .{ self.graph_name, self.type_name });
    }
};

/// Graph-aware FLE schema catalog wrapper
/// Manages per-graph type encryption metadata
pub const GraphSchemaCatalog = struct {
    allocator: Allocator,
    mutex: std.Thread.Mutex = .{},

    /// Map of "graph.type" -> type metadata
    schemas: std.StringHashMap(*@import("../schema/annotations.zig").TypeMetadata),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .schemas = std.StringHashMap(*@import("../schema/annotations.zig").TypeMetadata).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.schemas.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.schemas.deinit();
    }

    /// Register a type for a specific graph
    pub fn registerTypeForGraph(
        self: *Self,
        graph_name: []const u8,
        type_name: []const u8,
        type_meta: @import("../schema/annotations.zig").TypeMetadata,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ graph_name, type_name });
        errdefer self.allocator.free(key);

        if (self.schemas.contains(key)) {
            self.allocator.free(key);
            return error.TypeAlreadyExists;
        }

        const type_meta_ptr = try self.allocator.create(@import("../schema/annotations.zig").TypeMetadata);
        type_meta_ptr.* = type_meta;
        try self.schemas.put(key, type_meta_ptr);
    }

    /// Check if a field is encrypted for a type in a specific graph
    pub fn isFieldEncrypted(
        self: *Self,
        graph_name: []const u8,
        type_name: []const u8,
        field_name: []const u8,
    ) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ graph_name, type_name }) catch return false;

        if (self.schemas.get(key)) |type_meta_ptr| {
            return type_meta_ptr.isFieldEncrypted(field_name);
        }
        return false;
    }

    /// Grant plaintext access for a field in a specific graph
    pub fn grantPlaintextAccessForGraph(
        self: *Self,
        graph_name: []const u8,
        type_name: []const u8,
        field_name: []const u8,
        role: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ graph_name, type_name }) catch return error.InvalidKey;

        const type_meta_ptr = self.schemas.getPtr(key) orelse return error.TypeNotFound;
        const type_meta = type_meta_ptr.*;

        const field_meta_ptr = type_meta.fields.getPtr(field_name) orelse return error.FieldNotFound;

        // Check if role already has access
        for (field_meta_ptr.visibility.to_roles) |existing| {
            if (std.mem.eql(u8, existing, role)) return;
        }

        // Add role
        const new_roles = try self.allocator.alloc([]const u8, field_meta_ptr.visibility.to_roles.len + 1);
        if (field_meta_ptr.visibility.to_roles.len > 0) {
            @memcpy(new_roles[0..field_meta_ptr.visibility.to_roles.len], field_meta_ptr.visibility.to_roles);
        }
        new_roles[field_meta_ptr.visibility.to_roles.len] = try self.allocator.dupe(u8, role);
        field_meta_ptr.visibility.to_roles = new_roles;
    }
};

// ============================================================================
// Graph-Scoped Audit Events
// ============================================================================

/// Extended audit event with graph context
pub const GraphAuditEvent = struct {
    timestamp: i64,
    event_type: auth.AuditEventType,
    user_id: auth.UserId,
    graph_name: ?[]const u8, // Graph context for the event
    details: []const u8,
    ip_address: ?[]const u8,
    session_id: ?[]const u8,
};

/// Graph-aware audit logger
pub const GraphAuditLog = struct {
    allocator: Allocator,
    entries: std.ArrayList(GraphAuditEvent),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(GraphAuditEvent).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.details);
            if (entry.graph_name) |g| self.allocator.free(g);
            if (entry.ip_address) |ip| self.allocator.free(ip);
            if (entry.session_id) |sid| self.allocator.free(sid);
        }
        self.entries.deinit();
    }

    /// Log an event with graph context
    pub fn logWithGraph(
        self: *Self,
        event_type: auth.AuditEventType,
        user_id: auth.UserId,
        graph_name: ?[]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const details = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(details);

        const graph_copy = if (graph_name) |g| try self.allocator.dupe(u8, g) else null;

        try self.entries.append(.{
            .timestamp = std.time.milliTimestamp(),
            .event_type = event_type,
            .user_id = user_id,
            .graph_name = graph_copy,
            .details = details,
            .ip_address = null,
            .session_id = null,
        });
    }

    /// Log role assignment for a specific graph
    pub fn logRoleAssignedForGraph(self: *Self, user_id: auth.UserId, role_id: auth.RoleId, graph_name: []const u8) !void {
        try self.logWithGraph(.role_assigned, user_id, graph_name, "Role {} assigned for graph {s}", .{ role_id, graph_name });
    }

    /// Log role revocation for a specific graph
    pub fn logRoleRevokedForGraph(self: *Self, user_id: auth.UserId, role_id: auth.RoleId, graph_name: []const u8) !void {
        try self.logWithGraph(.role_revoked, user_id, graph_name, "Role {} revoked from graph {s}", .{ role_id, graph_name });
    }

    /// Log access granted for a specific graph
    pub fn logAccessGrantedForGraph(self: *Self, user_id: auth.UserId, graph_name: []const u8, resource: []const u8, action: auth.Action) !void {
        try self.logWithGraph(.access_granted, user_id, graph_name, "Access granted: {s} on {s} in graph {s}", .{ @tagName(action), resource, graph_name });
    }

    /// Log access denied for a specific graph
    pub fn logAccessDeniedForGraph(self: *Self, user_id: auth.UserId, graph_name: []const u8, resource: []const u8, action: auth.Action, reason: []const u8) !void {
        try self.logWithGraph(.access_denied, user_id, graph_name, "Access denied: {s} on {s} in graph {s} - {s}", .{ @tagName(action), resource, graph_name, reason });
    }

    /// Get audit events for a specific graph
    pub fn getEventsForGraph(self: *Self, allocator: Allocator, graph_name: []const u8) ![]GraphAuditEvent {
        var result = std.ArrayList(GraphAuditEvent).init(allocator);
        errdefer result.deinit();

        for (self.entries.items) |entry| {
            if (entry.graph_name) |g| {
                if (std.mem.eql(u8, g, graph_name)) {
                    try result.append(entry);
                }
            }
        }

        return result.toOwnedSlice();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "GraphRBACPolicy - assign and check graph-scoped roles" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var rbac = GraphRBACPolicy.init(allocator);
    defer rbac.deinit();

    // Assign role to user for graph1
    try rbac.assignRoleForGraph(1, 100, "graph1");

    // Add permission to the role
    var perms = try std.ArrayList(auth.Permission).initCapacity(allocator, 1);
    try perms.append(allocator, .{
        .id = 1,
        .name = "read_nodes",
        .resource = "node",
        .action = .read,
        .conditions = null,
        .created_at = 0,
    });
    try rbac.role_permissions.put(100, perms);

    // User should have permission in graph1
    try testing.expect(rbac.hasPermission(1, "graph1", "node", .read));

    // User should NOT have permission in graph2
    try testing.expect(!rbac.hasPermission(1, "graph2", "node", .read));
}

test "GraphRBACPolicy - global roles apply to all graphs" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var rbac = GraphRBACPolicy.init(allocator);
    defer rbac.deinit();

    // Assign global admin role
    try rbac.assignGlobalRole(1, 1);

    // Add all permission to the role
    var perms = try std.ArrayList(auth.Permission).initCapacity(allocator, 1);
    try perms.append(allocator, .{
        .id = 1,
        .name = "admin",
        .resource = "node",
        .action = .all,
        .conditions = null,
        .created_at = 0,
    });
    try rbac.role_permissions.put(1, perms);

    // User should have permission in any graph
    try testing.expect(rbac.hasPermission(1, "graph1", "node", .read));
    try testing.expect(rbac.hasPermission(1, "graph2", "node", .read));
    try testing.expect(rbac.hasPermission(1, "any_graph", "node", .delete));
}

test "GraphAuditLog - log events with graph context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var audit = GraphAuditLog.init(allocator);
    defer audit.deinit();

    // Log events for different graphs
    try audit.logRoleAssignedForGraph(1, 100, "graph1");
    try audit.logAccessDeniedForGraph(2, "graph2", "edge", .delete, "insufficient permissions");

    // Get events for graph1
    const graph1_events = try audit.getEventsForGraph(allocator, "graph1");
    defer allocator.free(graph1_events);

    try testing.expectEqual(@as(usize, 1), graph1_events.len);
    try testing.expectEqual(auth.AuditEventType.role_assigned, graph1_events[0].event_type);
}

test "GraphRBACPolicy - revoke graph role" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var rbac = GraphRBACPolicy.init(allocator);
    defer rbac.deinit();

    // Assign and then revoke
    try rbac.assignRoleForGraph(1, 100, "graph1");

    var perms = try std.ArrayList(auth.Permission).initCapacity(allocator, 1);
    try perms.append(allocator, .{
        .id = 1,
        .name = "read",
        .resource = "node",
        .action = .read,
        .conditions = null,
        .created_at = 0,
    });
    try rbac.role_permissions.put(100, perms);

    try testing.expect(rbac.hasPermission(1, "graph1", "node", .read));

    try rbac.revokeRoleForGraph(1, 100, "graph1");

    try testing.expect(!rbac.hasPermission(1, "graph1", "node", .read));
}

test "GraphRBACPolicy - get all roles for graph" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var rbac = GraphRBACPolicy.init(allocator);
    defer rbac.deinit();

    // Assign graph-specific and global roles
    try rbac.assignRoleForGraph(1, 100, "graph1");
    try rbac.assignRoleForGraph(1, 101, "graph1");
    try rbac.assignGlobalRole(1, 999);

    const roles = try rbac.getRolesForGraph(allocator, 1, "graph1");
    defer allocator.free(roles);

    try testing.expectEqual(@as(usize, 3), roles.len);
}
