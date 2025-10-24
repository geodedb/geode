const std = @import("std");
const geode = @import("geode");
const auth = @import("../src/security/auth.zig");
const rls_enhanced = @import("../src/security/rls_enhanced.zig");

// CANARY: REQ=REQ-RLS-ENHANCED-001; FEATURE="Enhanced RLS Implementation"; ASPECT=EnhancedPolicyEvaluation; STATUS=TESTED; TEST=test_enhanced_policy_evaluation; OWNER=security; UPDATED=2025-10-05
test "test_enhanced_policy_evaluation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var engine = try rls_enhanced.EnhancedRLSEngine.init(allocator);
    defer engine.deinit();

    // Create a test security context
    var user = auth.User{
        .id = 1,
        .username = "testuser",
        .email = "test@example.com",
        .password_hash = "dummy_hash",
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .last_login = null,
        .is_active = true,
        .is_superuser = false,
        .mfa_enabled = false,
        .mfa_secret = null,
        .attributes = std.StringHashMap([]const u8).init(allocator),
    };

    var roles = [_]auth.Role{
        auth.Role{
            .id = 1,
            .name = "user",
            .description = "Regular user",
            .permissions = std.ArrayList(auth.PermissionId).init(allocator),
            .created_at = std.time.milliTimestamp(),
            .is_system = false,
            .priority = 100,
            .parent_role = null,
        },
    };

    var environment = auth.EnvironmentInfo{
        .timestamp = std.time.milliTimestamp(),
        .ip_address = "192.168.1.100",
        .user_agent = "test-agent",
        .location = null,
        .device_id = null,
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &roles,
        .session_attributes = std.StringHashMap([]const u8).init(allocator),
        .request_attributes = std.StringHashMap([]const u8).init(allocator),
        .environment = environment,
    };

    // Create a test policy
    var base_policy = geode.rls.RLSEngine.Policy{
        .id = 1,
        .name = "Test Policy",
        .description = "Test policy for enhanced evaluation",
        .graph = "test_graph",
        .table = "users",
        .operation = .select,
        .permissive = false,
        .roles = &[_]auth.RoleId{1},
        .using_expr = null,
        .check_expr = null,
        .enabled = true,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .created_by = 1,
        .temporal = null,
        .data_classification = geode.rls.RLSEngine.DataClassification.internal,
        .audit_level = geode.rls.RLSEngine.AuditLevel.all_access,
    };

    // Create test row data
    var row_data = std.StringHashMap(geode.rls.Value).init(allocator);
    try row_data.put("user_id", geode.rls.Value{ .integer = 1 });
    try row_data.put("name", geode.rls.Value{ .string = "Test User" });

    // Test policy evaluation
    const result = try engine.evaluatePolicy(base_policy, &row_data, &context);
    try std.testing.expect(result == true); // Should allow access
}

// CANARY: REQ=REQ-RLS-ENHANCED-002; FEATURE="Enhanced RLS Implementation"; ASPECT=TemporalConstraints; STATUS=TESTED; TEST=test_temporal_constraint_evaluation; OWNER=security; UPDATED=2025-10-05
test "test_temporal_constraint_evaluation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var engine = try rls_enhanced.EnhancedRLSEngine.init(allocator);
    defer engine.deinit();

    const now = std.time.milliTimestamp();

    // Test temporal constraint with valid time range
    var temporal_constraint = geode.rls.RLSEngine.TemporalConstraint{
        .valid_from = now - 3600000, // 1 hour ago
        .valid_until = now + 3600000, // 1 hour from now
        .time_zone = "UTC",
        .recurrence = null,
    };

    // Create a simple context for testing
    var user = auth.User{
        .id = 1,
        .username = "testuser",
        .email = "test@example.com",
        .password_hash = "dummy_hash",
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .last_login = null,
        .is_active = true,
        .is_superuser = false,
        .mfa_enabled = false,
        .mfa_secret = null,
        .attributes = std.StringHashMap([]const u8).init(allocator),
    };

    var environment = auth.EnvironmentInfo{
        .timestamp = now,
        .ip_address = "192.168.1.100",
        .user_agent = "test-agent",
        .location = null,
        .device_id = null,
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &[_]auth.Role{},
        .session_attributes = std.StringHashMap([]const u8).init(allocator),
        .request_attributes = std.StringHashMap([]const u8).init(allocator),
        .environment = environment,
    };

    // Test valid temporal constraint
    const result = try engine.evaluateTemporalConstraint(temporal_constraint, &context);
    try std.testing.expect(result == true);

    // Test expired temporal constraint
    temporal_constraint.valid_until = now - 1800000; // 30 minutes ago
    const expired_result = try engine.evaluateTemporalConstraint(temporal_constraint, &context);
    try std.testing.expect(expired_result == false);
}

// CANARY: REQ=REQ-RLS-ENHANCED-003; FEATURE="Enhanced RLS Implementation"; ASPECT=DataClassification; STATUS=TESTED; TEST=test_data_classification_evaluation; OWNER=security; UPDATED=2025-10-05
test "test_data_classification_evaluation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var engine = try rls_enhanced.EnhancedRLSEngine.init(allocator);
    defer engine.deinit();

    // Create test context
    var user = auth.User{
        .id = 1,
        .username = "testuser",
        .email = "test@example.com",
        .password_hash = "dummy_hash",
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .last_login = null,
        .is_active = true,
        .is_superuser = false,
        .mfa_enabled = false,
        .mfa_secret = null,
        .attributes = std.StringHashMap([]const u8).init(allocator),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &[_]auth.Role{},
        .session_attributes = std.StringHashMap([]const u8).init(allocator),
        .request_attributes = std.StringHashMap([]const u8).init(allocator),
        .environment = auth.EnvironmentInfo{
            .timestamp = std.time.milliTimestamp(),
            .ip_address = "192.168.1.100",
            .user_agent = "test-agent",
            .location = null,
            .device_id = null,
        },
    };

    // Test public data classification (should allow)
    const public_result = try engine.evaluateDataClassification(geode.rls.RLSEngine.DataClassification.public, &context);
    try std.testing.expect(public_result == true);

    // Test internal data classification (should allow based on default clearance)
    const internal_result = try engine.evaluateDataClassification(geode.rls.RLSEngine.DataClassification.internal, &context);
    try std.testing.expect(internal_result == true);

    // Test top secret data classification (should deny based on default clearance)
    const top_secret_result = try engine.evaluateDataClassification(geode.rls.RLSEngine.DataClassification.top_secret, &context);
    try std.testing.expect(top_secret_result == false);
}

// CANARY: REQ=REQ-RLS-ENHANCED-004; FEATURE="Enhanced RLS Implementation"; ASPECT=ExpressionCompiler; STATUS=TESTED; TEST=test_expression_compiler; OWNER=security; UPDATED=2025-10-05
test "test_expression_compiler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var compiler = try rls_enhanced.ExpressionCompiler.init(allocator);
    defer compiler.deinit();

    // Create test context
    var user = auth.User{
        .id = 123,
        .username = "testuser",
        .email = "test@example.com",
        .password_hash = "dummy_hash",
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .last_login = null,
        .is_active = true,
        .is_superuser = false,
        .mfa_enabled = false,
        .mfa_secret = null,
        .attributes = std.StringHashMap([]const u8).init(allocator),
    };

    var role = auth.Role{
        .id = 1,
        .name = "user",
        .description = "Regular user",
        .permissions = std.ArrayList(auth.PermissionId).init(allocator),
        .created_at = std.time.milliTimestamp(),
        .is_system = false,
        .priority = 100,
        .parent_role = null,
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &[_]auth.Role{role},
        .session_attributes = std.StringHashMap([]const u8).init(allocator),
        .request_attributes = std.StringHashMap([]const u8).init(allocator),
        .environment = auth.EnvironmentInfo{
            .timestamp = std.time.milliTimestamp(),
            .ip_address = "192.168.1.100",
            .user_agent = "test-agent",
            .location = null,
            .device_id = null,
        },
    };

    // Test user ID comparison expression
    var expression = geode.rls.RLSEngine.Expression{
        .raw = "user_id = current_user()",
        .parsed = null,
        .compiled = null,
        .parameters = &[_]geode.rls.RLSEngine.Expression.Parameter{},
    };

    var row_data = std.StringHashMap(geode.rls.Value).init(allocator);
    try row_data.put("user_id", geode.rls.Value{ .integer = 123 }); // Matches user ID

    const result = try compiler.evaluate(expression, &row_data, &context);
    try std.testing.expect(result == true);

    // Test with non-matching user ID
    try row_data.put("user_id", geode.rls.Value{ .integer = 456 }); // Different user ID
    const non_match_result = try compiler.evaluate(expression, &row_data, &context);
    try std.testing.expect(non_match_result == false);

    // Test role-based expression
    expression.raw = "has_role('user')";
    const role_result = try compiler.evaluate(expression, &row_data, &context);
    try std.testing.expect(role_result == true);

    // Test non-existing role
    expression.raw = "has_role('admin')";
    const admin_result = try compiler.evaluate(expression, &row_data, &context);
    try std.testing.expect(admin_result == false);
}

// CANARY: REQ=REQ-RLS-ENHANCED-005; FEATURE="Enhanced RLS Implementation"; ASPECT=RecurrenceRules; STATUS=TESTED; TEST=test_recurrence_rule_evaluation; OWNER=security; UPDATED=2025-10-05
test "test_recurrence_rule_evaluation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var engine = try rls_enhanced.EnhancedRLSEngine.init(allocator);
    defer engine.deinit();

    // Create test context
    var user = auth.User{
        .id = 1,
        .username = "testuser",
        .email = "test@example.com",
        .password_hash = "dummy_hash",
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .last_login = null,
        .is_active = true,
        .is_superuser = false,
        .mfa_enabled = false,
        .mfa_secret = null,
        .attributes = std.StringHashMap([]const u8).init(allocator),
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &[_]auth.Role{},
        .session_attributes = std.StringHashMap([]const u8).init(allocator),
        .request_attributes = std.StringHashMap([]const u8).init(allocator),
        .environment = auth.EnvironmentInfo{
            .timestamp = std.time.milliTimestamp(),
            .ip_address = "192.168.1.100",
            .user_agent = "test-agent",
            .location = null,
            .device_id = null,
        },
    };

    // Test daily recurrence rule
    var daily_rule = geode.rls.RLSEngine.RecurrenceRule{
        .frequency = geode.rls.RLSEngine.RecurrenceRule.Frequency.daily,
        .interval = 1,
        .by_day = null,
        .by_hour = null,
    };

    const now = std.time.milliTimestamp();
    const daily_result = try engine.evaluateRecurrenceRule(daily_rule, now, &context);
    try std.testing.expect(daily_result == true); // Should be valid for daily frequency

    // Test weekly recurrence with specific days
    var weekdays = [_]geode.rls.RLSEngine.RecurrenceRule.DayOfWeek{
        geode.rls.RLSEngine.RecurrenceRule.DayOfWeek.monday,
        geode.rls.RLSEngine.RecurrenceRule.DayOfWeek.wednesday,
        geode.rls.RLSEngine.RecurrenceRule.DayOfWeek.friday,
    };

    var weekly_rule = geode.rls.RLSEngine.RecurrenceRule{
        .frequency = geode.rls.RLSEngine.RecurrenceRule.Frequency.weekly,
        .interval = 1,
        .by_day = &weekdays,
        .by_hour = null,
    };

    const weekly_result = try engine.evaluateRecurrenceRule(weekly_rule, now, &context);
    // Result depends on current day of week, but function should execute without error
    _ = weekly_result; // We just verify it doesn't crash

    // Test hourly constraints
    var business_hours = [_]u8{ 9, 10, 11, 12, 13, 14, 15, 16, 17 }; // 9 AM to 5 PM

    var hourly_rule = geode.rls.RLSEngine.RecurrenceRule{
        .frequency = geode.rls.RLSEngine.RecurrenceRule.Frequency.daily,
        .interval = 1,
        .by_day = null,
        .by_hour = &business_hours,
    };

    const hourly_result = try engine.evaluateRecurrenceRule(hourly_rule, now, &context);
    // Result depends on current hour, but function should execute without error
    _ = hourly_result; // We just verify it doesn't crash
}

// CANARY: REQ=REQ-RLS-ENHANCED-006; FEATURE="Enhanced RLS Implementation"; ASPECT=QueryRewriting; STATUS=TESTED; TEST=test_enhanced_query_rewriting; OWNER=security; UPDATED=2025-10-05
test "test_enhanced_query_rewriting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var engine = try rls_enhanced.EnhancedRLSEngine.init(allocator);
    defer engine.deinit();

    // Create test context
    var user = auth.User{
        .id = 1,
        .username = "testuser",
        .email = "test@example.com",
        .password_hash = "dummy_hash",
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .last_login = null,
        .is_active = true,
        .is_superuser = false,
        .mfa_enabled = false,
        .mfa_secret = null,
        .attributes = std.StringHashMap([]const u8).init(allocator),
    };

    var role = auth.Role{
        .id = 1,
        .name = "user",
        .description = "Regular user",
        .permissions = std.ArrayList(auth.PermissionId).init(allocator),
        .created_at = std.time.milliTimestamp(),
        .is_system = false,
        .priority = 100,
        .parent_role = null,
    };

    var context = auth.SecurityContext{
        .user = &user,
        .roles = &[_]auth.Role{role},
        .session_attributes = std.StringHashMap([]const u8).init(allocator),
        .request_attributes = std.StringHashMap([]const u8).init(allocator),
        .environment = auth.EnvironmentInfo{
            .timestamp = std.time.milliTimestamp(),
            .ip_address = "192.168.1.100",
            .user_agent = "test-agent",
            .location = null,
            .device_id = null,
        },
    };

    // Test query rewriting without existing WHERE clause
    const original_query = "SELECT * FROM users";
    const rewritten_query = try engine.rewriteQueryEnhanced(original_query, &context, "test_graph");
    defer allocator.free(rewritten_query);

    try std.testing.expect(std.mem.indexOf(u8, rewritten_query, "WHERE") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten_query, "SELECT * FROM users") != null);

    // Test query rewriting with existing WHERE clause
    const query_with_where = "SELECT * FROM users WHERE active = 1";
    const rewritten_with_where = try engine.rewriteQueryEnhanced(query_with_where, &context, "test_graph");
    defer allocator.free(rewritten_with_where);

    try std.testing.expect(std.mem.indexOf(u8, rewritten_with_where, "AND") != null);
    try std.testing.expect(std.mem.indexOf(u8, rewritten_with_where, "active = 1") != null);
}

// CANARY: REQ=REQ-RLS-ENHANCED-007; FEATURE="Enhanced RLS Implementation"; ASPECT=CacheManager; STATUS=TESTED; TEST=test_enhanced_cache_manager; OWNER=security; UPDATED=2025-10-05
test "test_enhanced_cache_manager" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var cache_manager = try rls_enhanced.EnhancedCacheManager.init(allocator);
    defer cache_manager.deinit();

    // Create test row data for cache key generation
    var row_data = std.StringHashMap(geode.rls.Value).init(allocator);
    try row_data.put("user_id", geode.rls.Value{ .integer = 123 });
    try row_data.put("name", geode.rls.Value{ .string = "Test User" });

    // Generate cache key
    const cache_key = try cache_manager.generateCacheKey(1, 123, &row_data);

    // Test cache miss
    const miss_result = cache_manager.get(cache_key);
    try std.testing.expect(miss_result == null);

    // Test cache put and get
    try cache_manager.put(cache_key, true);
    const hit_result = cache_manager.get(cache_key);
    try std.testing.expect(hit_result != null);
    try std.testing.expect(hit_result.? == true);

    // Test cache with different result
    try cache_manager.put(cache_key, false);
    const updated_result = cache_manager.get(cache_key);
    try std.testing.expect(updated_result != null);
    try std.testing.expect(updated_result.? == false);

    // Test cache with different key
    const different_key = try cache_manager.generateCacheKey(2, 456, &row_data);
    const different_result = cache_manager.get(different_key);
    try std.testing.expect(different_result == null);

    try cache_manager.put(different_key, true);
    const different_hit = cache_manager.get(different_key);
    try std.testing.expect(different_hit != null);
    try std.testing.expect(different_hit.? == true);
}

// CANARY: REQ=REQ-RLS-ENHANCED-008; FEATURE="Enhanced RLS Implementation"; ASPECT=StatisticsCollector; STATUS=TESTED; TEST=test_statistics_collector; OWNER=security; UPDATED=2025-10-05
test "test_statistics_collector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stats_collector = try rls_enhanced.RLSStatisticsCollector.init(allocator);
    defer stats_collector.deinit();

    // Test initial state
    const initial_global_stats = stats_collector.getGlobalStatistics();
    try std.testing.expect(initial_global_stats.total_evaluations == 0);
    try std.testing.expect(initial_global_stats.total_cache_hits == 0);
    try std.testing.expect(initial_global_stats.total_cache_misses == 0);

    // Test recording policy evaluation
    try stats_collector.recordPolicyEvaluation(1);
    try stats_collector.recordPolicyEvaluation(1);
    try stats_collector.recordPolicyEvaluation(2);

    const after_evaluations = stats_collector.getGlobalStatistics();
    try std.testing.expect(after_evaluations.total_evaluations == 3);

    // Test recording cache hits and misses
    try stats_collector.recordCacheHit(1);
    try stats_collector.recordCacheHit(1);
    try stats_collector.recordCacheMiss(2);

    const after_cache = stats_collector.getGlobalStatistics();
    try std.testing.expect(after_cache.total_cache_hits == 2);
    try std.testing.expect(after_cache.total_cache_misses == 1);

    // Test cache hit ratio calculation
    const hit_ratio = stats_collector.getCacheHitRatio();
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), hit_ratio, 0.01);

    // Test policy-specific statistics
    const policy_stats = stats_collector.getPolicyStatistics(1);
    try std.testing.expect(policy_stats != null);
    try std.testing.expect(policy_stats.?.evaluations == 2);
    try std.testing.expect(policy_stats.?.cache_hits == 2);

    const policy2_stats = stats_collector.getPolicyStatistics(2);
    try std.testing.expect(policy2_stats != null);
    try std.testing.expect(policy2_stats.?.evaluations == 1);
    try std.testing.expect(policy2_stats.?.cache_misses == 1);
}

// CANARY: REQ=REQ-RLS-ENHANCED-009; FEATURE="Enhanced RLS Implementation"; ASPECT=PolicyOptimizer; STATUS=TESTED; TEST=test_policy_optimizer; OWNER=security; UPDATED=2025-10-05
test "test_policy_optimizer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var policy_optimizer = try rls_enhanced.PolicyOptimizer.init(allocator);
    defer policy_optimizer.deinit();

    // Create test policies with different complexities
    var simple_policy = geode.rls.RLSEngine.Policy{
        .id = 1,
        .name = "Simple Policy",
        .description = "Simple test policy",
        .graph = "test_graph",
        .table = "users",
        .operation = .select,
        .permissive = false,
        .roles = &[_]auth.RoleId{1},
        .using_expr = geode.rls.RLSEngine.Expression{
            .raw = "user_id = 1",
            .parsed = null,
            .compiled = null,
            .parameters = &[_]geode.rls.RLSEngine.Expression.Parameter{},
        },
        .check_expr = null,
        .enabled = true,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .created_by = 1,
        .temporal = null,
        .data_classification = null,
        .audit_level = geode.rls.RLSEngine.AuditLevel.all_access,
    };

    var complex_policy = geode.rls.RLSEngine.Policy{
        .id = 2,
        .name = "Complex Policy",
        .description = "Complex test policy",
        .graph = "test_graph",
        .table = "users",
        .operation = .select,
        .permissive = false,
        .roles = &[_]auth.RoleId{1},
        .using_expr = geode.rls.RLSEngine.Expression{
            .raw = "user_id = current_user() AND status = 'active' AND created_at > '2023-01-01'",
            .parsed = null,
            .compiled = null,
            .parameters = &[_]geode.rls.RLSEngine.Expression.Parameter{},
        },
        .check_expr = null,
        .enabled = true,
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .created_by = 1,
        .temporal = null,
        .data_classification = null,
        .audit_level = geode.rls.RLSEngine.AuditLevel.all_access,
    };

    var disabled_policy = geode.rls.RLSEngine.Policy{
        .id = 3,
        .name = "Disabled Policy",
        .description = "Disabled test policy",
        .graph = "test_graph",
        .table = "users",
        .operation = .select,
        .permissive = false,
        .roles = &[_]auth.RoleId{1},
        .using_expr = geode.rls.RLSEngine.Expression{
            .raw = "1 = 1",
            .parsed = null,
            .compiled = null,
            .parameters = &[_]geode.rls.RLSEngine.Expression.Parameter{},
        },
        .check_expr = null,
        .enabled = false, // Disabled
        .created_at = std.time.milliTimestamp(),
        .updated_at = std.time.milliTimestamp(),
        .created_by = 1,
        .temporal = null,
        .data_classification = null,
        .audit_level = geode.rls.RLSEngine.AuditLevel.all_access,
    };

    const policies = [_]geode.rls.RLSEngine.Policy{ complex_policy, disabled_policy, simple_policy };

    // Test policy optimization
    var optimized_policies = try policy_optimizer.optimizePolicies(&policies);
    defer optimized_policies.deinit();

    // Verify policies are present in optimized list
    try std.testing.expect(optimized_policies.items.len == 3);

    // Simple policies should generally be sorted before complex ones
    // (though the exact ordering depends on the optimization algorithm)
    var found_simple = false;
    var found_complex = false;
    for (optimized_policies.items) |policy| {
        if (policy.id == 1) found_simple = true;
        if (policy.id == 2) found_complex = true;
    }

    try std.testing.expect(found_simple);
    try std.testing.expect(found_complex);
}
