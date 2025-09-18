const std = @import("std");
const testing = std.testing;
const rls = @import("../src/security/rls.zig");
const auth = @import("../src/security/auth.zig");

test "RLS - create and enforce policies for multi-tenant data" {
    const allocator = testing.allocator;

    var engine = try rls.RLSEngine.init(allocator);
    defer engine.deinit();

    // Create tenant isolation policy
    const tenant_policy = rls.RLSEngine.Policy{
        .id = 1,
        .name = "tenant_isolation",
        .description = "Isolate data by tenant",
        .graph = "multi_tenant_graph",
        .table = "customer_data",
        .operation = .all,
        .permissive = false,
        .roles = &[_]auth.RoleId{ 1, 2 }, // Admin and User roles
        .using_expr = .{
            .raw = "row.tenant_id = current_user().tenant_id",
            .parsed = null,
            .compiled = null,
            .parameters = &[_]rls.RLSEngine.Expression.Parameter{
                .{
                    .name = "current_user",
                    .type = .object,
                    .source = .current_user,
                },
            },
        },
        .check_expr = null,
        .enabled = true,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .created_by = 1,
    };

    try engine.createPolicy(tenant_policy);

    // Create security context for testing
    var context = auth.SecurityContext{
        .user = .{
            .id = 100,
            .username = "test_user",
            .tenant_id = 5,
        },
        .roles = &[_]auth.Role{
            .{ .id = 2, .name = "user" },
        },
        .session = .{
            .id = "session123",
            .created_at = std.time.milliTimestamp(),
        },
        .environment = .{
            .ip_address = "192.168.1.100",
            .user_agent = "test",
        },
    };

    // Create test row
    var row = std.StringHashMap(rls.RLSEngine.Value).init(allocator);
    defer row.deinit();
    try row.put("tenant_id", .{ .integer = 5 });
    try row.put("data", .{ .string = "sensitive data" });

    // Test access check - should allow (same tenant)
    const allowed = try engine.checkRowAccess(
        &row,
        .select,
        &context,
        "multi_tenant_graph",
        "customer_data",
    );
    try testing.expect(allowed);

    // Test with different tenant - should deny
    try row.put("tenant_id", .{ .integer = 10 });
    const denied = try engine.checkRowAccess(
        &row,
        .select,
        &context,
        "multi_tenant_graph",
        "customer_data",
    );
    try testing.expect(!denied);
}

test "RLS - hierarchical tenant access control" {
    const allocator = testing.allocator;

    var engine = try rls.RLSEngine.init(allocator);
    defer engine.deinit();

    // Set up tenant hierarchy
    try engine.hierarchy_manager.tenant_hierarchy.put(1, .{
        .id = 1,
        .parent_id = null,
        .children = std.ArrayList(u64).init(allocator),
        .level = 0,
        .path = &[_]u64{1},
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    try engine.hierarchy_manager.tenant_hierarchy.put(2, .{
        .id = 2,
        .parent_id = 1,
        .children = std.ArrayList(u64).init(allocator),
        .level = 1,
        .path = &[_]u64{ 1, 2 },
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    try engine.hierarchy_manager.tenant_hierarchy.put(3, .{
        .id = 3,
        .parent_id = 2,
        .children = std.ArrayList(u64).init(allocator),
        .level = 2,
        .path = &[_]u64{ 1, 2, 3 },
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    // Test parent can access child tenant
    const parent_can_access = try engine.hierarchy_manager.canAccessTenant(1, 3);
    try testing.expect(parent_can_access);

    // Test child cannot access parent tenant
    const child_cannot_access = try engine.hierarchy_manager.canAccessTenant(3, 1);
    try testing.expect(!child_cannot_access);

    // Test sibling access (should fail)
    try engine.hierarchy_manager.tenant_hierarchy.put(4, .{
        .id = 4,
        .parent_id = 2,
        .children = std.ArrayList(u64).init(allocator),
        .level = 2,
        .path = &[_]u64{ 1, 2, 4 },
        .metadata = std.StringHashMap([]const u8).init(allocator),
    });

    const sibling_cannot_access = try engine.hierarchy_manager.canAccessTenant(3, 4);
    try testing.expect(!sibling_cannot_access);
}

test "RLS - attribute-based access control (ABAC)" {
    const allocator = testing.allocator;

    var engine = try rls.RLSEngine.init(allocator);
    defer engine.deinit();

    // Define attributes
    try engine.attribute_controller.attribute_definitions.put("department", .{
        .name = "department",
        .type = .string,
        .source = .user,
        .validators = &[_]rls.AttributeBasedAccessControl.AttributeDefinition.Validator{
            .{
                .type = .enum_values,
                .params = "engineering,sales,hr,finance",
            },
        },
        .transformers = &[_]rls.AttributeBasedAccessControl.AttributeDefinition.Transformer{},
    });

    try engine.attribute_controller.attribute_definitions.put("clearance_level", .{
        .name = "clearance_level",
        .type = .number,
        .source = .user,
        .validators = &[_]rls.AttributeBasedAccessControl.AttributeDefinition.Validator{
            .{
                .type = .range,
                .params = "1,5",
            },
        },
        .transformers = &[_]rls.AttributeBasedAccessControl.AttributeDefinition.Transformer{},
    });

    // Create ABAC rule
    const abac_rule = rls.AttributeBasedAccessControl.AttributeRule{
        .id = 1,
        .name = "classified_access",
        .condition = .{
            .expression = "user.clearance_level >= resource.classification_level",
            .required_attributes = &[_][]const u8{ "clearance_level", "classification_level" },
        },
        .effect = .permit,
        .priority = 1,
        .obligations = &[_]rls.AttributeBasedAccessControl.AttributeRule.Obligation{
            .{
                .type = .audit,
                .params = std.StringHashMap([]const u8).init(allocator),
            },
        },
    };

    try engine.attribute_controller.attribute_rules.append(abac_rule);

    // Test attribute evaluation
    var attributes = std.StringHashMap(rls.RLSEngine.Value).init(allocator);
    defer attributes.deinit();

    try attributes.put("clearance_level", .{ .integer = 3 });
    try attributes.put("classification_level", .{ .integer = 2 });

    const permitted = try engine.attribute_controller.attribute_evaluator.evaluate(
        abac_rule,
        attributes,
    );
    try testing.expect(permitted);

    // Test with insufficient clearance
    try attributes.put("clearance_level", .{ .integer = 1 });
    try attributes.put("classification_level", .{ .integer = 4 });

    const denied = try engine.attribute_controller.attribute_evaluator.evaluate(
        abac_rule,
        attributes,
    );
    try testing.expect(!denied);
}

test "RLS - temporal constraints on policies" {
    const allocator = testing.allocator;

    var engine = try rls.RLSEngine.init(allocator);
    defer engine.deinit();

    const now = std.time.milliTimestamp();

    // Create time-bound policy
    const temporal_policy = rls.RLSEngine.Policy{
        .id = 1,
        .name = "business_hours_only",
        .description = "Access only during business hours",
        .graph = "sensitive_data",
        .table = "financial_records",
        .operation = .select,
        .permissive = false,
        .roles = &[_]auth.RoleId{1},
        .using_expr = .{
            .raw = "true",
            .parsed = null,
            .compiled = null,
            .parameters = &[_]rls.RLSEngine.Expression.Parameter{},
        },
        .check_expr = null,
        .enabled = true,
        .temporal = .{
            .valid_from = now - 1000,
            .valid_until = now + 1000,
            .time_zone = "UTC",
            .recurrence = .{
                .frequency = .daily,
                .interval = 1,
                .by_day = null,
                .by_hour = &[_]u8{ 9, 10, 11, 12, 13, 14, 15, 16, 17 },
            },
        },
        .created_at = now,
        .updated_at = now,
        .created_by = 1,
    };

    try engine.createPolicy(temporal_policy);

    // Test temporal constraint check
    const constraint_valid = engine.checkTemporalConstraint(temporal_policy.temporal.?);
    try testing.expect(constraint_valid);

    // Test expired constraint
    const expired_constraint = rls.RLSEngine.TemporalConstraint{
        .valid_from = now - 10000,
        .valid_until = now - 5000,
        .time_zone = "UTC",
        .recurrence = null,
    };

    const expired = engine.checkTemporalConstraint(expired_constraint);
    try testing.expect(!expired);
}

test "RLS - audit logging of security events" {
    const allocator = testing.allocator;

    var engine = try rls.RLSEngine.init(allocator);
    defer engine.deinit();

    // Configure audit policy
    try engine.audit_logger.audit_policies.append(.{
        .event_types = &[_]rls.AuditLogger.AuditEvent.EventType{
            .authorization,
            .policy_violation,
        },
        .severity_threshold = .info,
        .include_details = true,
        .retention_days = 30,
    });

    // Log security event
    const audit_event = rls.AuditLogger.AuditEvent{
        .timestamp = std.time.milliTimestamp(),
        .event_type = .authorization,
        .severity = .warning,
        .user_id = 100,
        .session_id = "session123",
        .resource = .{
            .type = "graph",
            .id = "graph1",
            .name = "customer_graph",
            .graph = "customer_graph",
            .table = "orders",
        },
        .action = "SELECT",
        .result = .failure,
        .details = null,
    };

    try engine.audit_logger.logEvent(audit_event);

    // Verify event was queued
    try testing.expect(engine.audit_logger.event_queue.items.len > 0);

    // Test flush
    try engine.audit_logger.flush();
    try testing.expectEqual(@as(usize, 0), engine.audit_logger.event_queue.items.len);
}
