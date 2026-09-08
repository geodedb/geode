// CANARY: REQ=REQ-CAPABILITY-DISCOVERY-001; FEATURE="SHOW CAPABILITIES"; ASPECT=DiscoveryRows; STATUS=TESTED; TEST=tests/test_show_capabilities.zig; OWNER=execution; UPDATED=2026-08-28
//
// Task 7 (hybrid-RAG audit spec, capability discovery from trusted runtime
// metadata): SHOW CAPABILITIES must be a truthful, discovery-grade surface.
// Prior to this change `executeShowCapabilities` (src/execution/admin_ddl.zig)
// was a hardcoded 9-row list with `policy_ddl=false`, which was stale — GAP-0858
// landed durable GPS policy DDL persistence (CREATE/ALTER/DROP POLICY, incl.
// RENAME TO). This test drives the real statement dispatch
// (`admin_ddl.executeShowCapabilities`, the same function
// `statement_handlers.executeShow` calls for `.capabilities`) and asserts:
//
//   (a) all 9 legacy row names are still present (geode-ui consumes
//       `admin_writable` — renaming any legacy row would break it),
//   (b) `policy_ddl` now reports `true`,
//   (c) every new row Task 7 requires is present and reports `true`,
//   (d) the row count equals the expected total exactly, so a stale or
//       forgotten row can't silently linger.

const std = @import("std");
const geode = @import("geode");

const admin_ddl = geode.execution.admin_ddl;

const legacy_rows = [_][]const u8{
    "auth_ddl",
    "admin_writable",
    "role_ddl",
    "grant_ddl",
    "show_permissions",
    "show_version",
    "policy_ddl",
    "fle_ddl",
    "tenant_ddl",
};

// New rows added by Task 7 — all features landed in Tasks 1-6, all `true`.
const new_rows = [_][]const u8{
    "vector_knn",
    "vector_index_metrics",
    "knn_metric_validation",
    "fts_search",
    "fts_phrase_proximity",
    "fts_rebuild",
    "fts_bulk_merge_live_maintenance",
    "fts_row_visibility",
    "ts_procedures",
    "read_only_execute",
    "mcp_read_only",
    "explain",
    "profile",
    "explain_policy",
};

// GEO-UP-001 appends these rows while preserving the original 23 above.
const sonny_profile_rows = [_][]const u8{
    "sonny_profile_version",
    "read_only_covers_admin_ddl",
    "strict_tenancy_production_default",
    "tenant_scope_fail_closed",
    "tenant_binding_server_verified",
    "fts_strict_tenancy",
    "fts_multi_graph",
    "knn_row_visibility",
    "knn_delete_liveness",
    "knn_filtered_ann_pushdown",
    "graph_procedure_tenancy",
    "embedding_space_pinning",
    "vector_index_generations",
    "vector_generation_rollback",
    "vector_build_bounded",
    "vector_index_restart_rebuild",
    "bulk_vector_index_maintenance",
    "bulk_create_fts_maintenance",
    "bulk_delete_batch",
    "index_build_telemetry",
    "retrieval_ready",
    "traversal_multi_edge_type",
    "traversal_bounded_nodes_cost_time",
    "traversal_cycle_hub_control",
    "traversal_cancellation",
    "traversal_deterministic_ties",
    "traversal_path_provenance",
    "weighted_path_raw_property",
    "temporal_traversal_predicates",
    "cdc_ordered_resumable",
    "cdc_tenant_bound",
    "cdc_backpressure_dlq_observable",
    "federation_authorization_preserved",
    "federation_deterministic_topk",
    "federation_partial_shard_errors",
    "graph_community_summary_layer",
};

fn findRow(res: anytype, name: []const u8) ?[]const u8 {
    for (res.rows) |row| {
        if (std.mem.eql(u8, row[0].Str, name)) return row[1].Str;
    }
    return null;
}

test "SHOW CAPABILITIES: all legacy rows present, unrenamed" {
    const allocator = std.testing.allocator;
    var res = try admin_ddl.executeShowCapabilities(allocator);
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), res.columns.len);
    try std.testing.expectEqualStrings("feature", res.columns[0]);
    try std.testing.expectEqualStrings("supported", res.columns[1]);

    for (legacy_rows) |name| {
        const supported = findRow(res, name);
        try std.testing.expect(supported != null);
    }
}

test "SHOW CAPABILITIES: policy_ddl flipped to true (GAP-0858)" {
    const allocator = std.testing.allocator;
    var res = try admin_ddl.executeShowCapabilities(allocator);
    defer res.deinit(allocator);

    const supported = findRow(res, "policy_ddl");
    try std.testing.expect(supported != null);
    try std.testing.expectEqualStrings("true", supported.?);
}

test "SHOW CAPABILITIES: new discovery rows present and true" {
    const allocator = std.testing.allocator;
    var res = try admin_ddl.executeShowCapabilities(allocator);
    defer res.deinit(allocator);

    for (new_rows) |name| {
        const supported = findRow(res, name);
        try std.testing.expect(supported != null);
        try std.testing.expectEqualStrings("true", supported.?);
    }
}

test "SHOW CAPABILITIES: row count equals expected total exactly" {
    const allocator = std.testing.allocator;
    var res = try admin_ddl.executeShowCapabilities(allocator);
    defer res.deinit(allocator);

    const expected: usize = legacy_rows.len + new_rows.len + sonny_profile_rows.len;
    try std.testing.expectEqual(expected, res.rows.len);
}
