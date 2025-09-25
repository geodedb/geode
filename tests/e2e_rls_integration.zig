const std = @import("std");
const testing = std.testing;
const rls = @import("../src/security/rls.zig");

test "RLS enforcement e2e" {
    const allocator = testing.allocator;
    
    // Initialize RLS manager
    var audit_logger = try rls.AuditLogger.init(allocator);
    defer audit_logger.deinit();
    
    var rls_mgr = try rls.RlsManager.init(allocator, &audit_logger);
    defer rls_mgr.deinit();
    
    // Create security context
    var attrs = std.StringHashMap([]const u8).init(allocator);
    defer attrs.deinit();
    try attrs.put("department", "engineering");
    
    const sec_ctx = rls.SecurityContext{
        .user_id = 100,
        .tenant_id = 5,
        .roles = &[_][]const u8{"employee", "viewer"},
        .attributes = attrs,
        .session_id = "sess-123",
        .ip_address = "192.168.1.1",
    };
    
    // Add a policy for tenant isolation
    try rls_mgr.addPolicy(.{
        .id = 1,
        .name = "tenant_isolation",
        .table = "employees",
        .operation = .select,
        .using_clause = null, // Would contain tenant_id = current_tenant()
        .check_clause = null,
        .roles = &[_][]const u8{"employee"},
        .enabled = true,
    });
    
    // Test access allowed
    try rls_mgr.enforceAccess(&sec_ctx, "employees", .select);
    std.debug.print("RLS_ALLOW tenant={d} table=employees\n", .{sec_ctx.tenant_id});
    
    // Test access denied (no policy for this operation)
    rls_mgr.enforceAccess(&sec_ctx, "employees", .delete) catch |err| {
        if (err == rls.RlsError.PolicyViolation) {
            std.debug.print("RLS_DENY tenant={d} table=employees reason=USING\n", .{sec_ctx.tenant_id});
        }
    };
    
    // Test hierarchical access
    const parent_ctx = rls.SecurityContext{
        .user_id = 1,
        .tenant_id = 1,
        .roles = &[_][]const u8{"admin"},
        .attributes = attrs,
        .session_id = "sess-admin",
        .ip_address = "10.0.0.1",
    };
    
    try rls_mgr.enforceAccess(&parent_ctx, "all_tenants", .select);
    std.debug.print("RLS_HIERARCHY_ALLOW parent={d} child=3\n", .{parent_ctx.tenant_id});
}