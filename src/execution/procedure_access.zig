const std = @import("std");
const ast = @import("../gql/ast.zig");

pub const ProcedureAccess = enum {
    read_only,
    mutating,
};

pub const ResolvedProcedureName = struct {
    name: []const u8,
    owned: bool = false,

    pub fn deinit(self: *ResolvedProcedureName, allocator: std.mem.Allocator) void {
        if (self.owned) allocator.free(self.name);
        self.* = .{ .name = &.{}, .owned = false };
    }
};

// CANARY: REQ=REQ-GRAPH-STORAGE-CALL-001; FEATURE="ProcedureAccessClassification"; ASPECT=Execution; STATUS=IMPL; OWNER=execution; UPDATED=2026-04-01
const read_only_procedure_names = [_][]const u8{
    "algo.degree.stream",
    "degree",
    "algo.betweenness.stream",
    "betweenness",
    "algo.closeness.stream",
    "closeness",
    "algo.eigenvector.stream",
    "eigenvector",
    "algo.pagerank.stream",
    "algo.pageRank.stream",
    "pagerank",
    "algo.louvain.stream",
    "louvain",
    "algo.labelPropagation.stream",
    "labelPropagation",
    "algo.unionFind.stream",
    "unionFind",
    "algo.scc.stream",
    "scc",
    "algo.harmonic.stream",
    "harmonic",
    "algo.bridgeLeverage.stream",
    "bridgeLeverage",
    "algo.greyCardinal.stream",
    "greyCardinal",
    "algo.leiden.stream",
    "leiden",
    "algo.articulationPoints.stream",
    "articulationPoints",
    "algo.bridges.stream",
    "bridges",
    "algo.biconnectedComponents.stream",
    "biconnected",
    "algo.bfs.stream",
    "bfs",
    "algo.dfs.stream",
    "dfs",
    "algo.dijkstra.stream",
    "algo.shortestPath.dijkstra",
    "dijkstra",
    "geode.storage.stats",
    "geode.storage.integrity",
    "geode.fle.getFieldConfig",
    "geode.fle.listEncryptedFields",
    "geode.auth.user_list",
    "geode.auth.user_show",
    "geode.auth.user_permissions",
    "geode.auth.role_list",
    "geode.auth.policy_list",
    "geode.auth.apikey_list",
    "geode.auth.apikey_check_scope",
    // CANARY: REQ=REQ-RLS-DDL-001; FEATURE="RLS deny-policy procedure"; ASPECT=ReadOnlyClassification; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/rls_cross_tenant_query_shapes.yml; OWNER=security; UPDATED=2026-05-22
    "geode.rls.list_deny_policies",
    "geode.rls.policy_count",
    // CANARY: REQ=REQ-GQL-FTS-PROC-001; FEATURE="CALL geode.fts.search YIELD node,score"; ASPECT=ReadOnlyClassification; STATUS=TESTED; TEST=tests/test_fts_e2e.zig; OWNER=index; UPDATED=2026-05-31
    "geode.fts.search",
    // CANARY: REQ=REQ-GQL-TS-PROC-001; FEATURE="CALL geode.ts.* read procedures"; ASPECT=ReadOnlyClassification; STATUS=TESTED; TEST=tests/ts_ingest_roundtrip.zig; OWNER=timeseries; UPDATED=2026-05-31
    // Read-only timeseries queries. The write verbs (geode.ts.insert /
    // geode.ts.insert_many) are intentionally NOT listed here so they default to
    // .mutating (the fail-closed write classification → GPS .write action).
    "geode.ts.range",
    "geode.ts.last",
    "geode.ts.bucket_avg",
    "geode.ts.sample_by",
    "cdc.status",
    "cdc.export_diagnostics",
    "cdc.get_events",
    "cdc.get_guardrail_status",
    "cdc.get_watermark",
    "cdc.get_pending_events",
    "cdc.get_flush_metrics",
    "cdc.get_malformed_records",
    "cdc.get_corruption_analysis",
    "cdc.get_ordered_events",
    "cdc.check_duplicates",
    "cdc.get_change_status",
    "cdc.get_telemetry_metrics",
    "cdc.get_performance_alerts",
    "audit.get_recent_events",
    "audit.verify_hash_chain",
    "audit.get_merkle_digests",
    "audit.comprehensive_integrity_check",
    "tde.get_encryption_status",
    "tde.verify_encrypted_state",
    "tde.get_rotation_state",
    "tde.measure_overhead",
    "tde.audit_plaintext_keys",
    // CANARY: REQ=REQ-GPS-PROC-003; FEATURE="GPS Phase 5 Procedure"; ASPECT=MetadataReadOnly; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/gps_phase5_procedure_fle.yml; OWNER=security; UPDATED=2026-05-21
    // db.* / dbms.* introspection procedures are inherently read-only — they
    // enumerate labels, edge types, property keys, indexes, constraints, and
    // procedure/function catalogues. The Phase 5 dispatch gate would otherwise
    // classify them as .mutating (default for unlisted) and deny readonly users.
    "db.labels",
    "db.relationshipTypes",
    "db.propertyKeys",
    "db.indexes",
    "db.constraints",
    "dbms.procedures",
    "dbms.functions",
};

pub fn resolveProcedureName(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) !ResolvedProcedureName {
    return switch (call_stmt.procedure) {
        .Call => |call| resolveProcedureCalleeName(allocator, call.callee),
        else => .{ .name = "unknown" },
    };
}

pub fn classifyCallProcedure(call_stmt: ast.CallProcedure) ProcedureAccess {
    for (read_only_procedure_names) |name| {
        if (callProcedureMatchesName(call_stmt, name)) return .read_only;
    }
    return .mutating;
}

pub fn classifyProcedureName(proc_name: []const u8) ProcedureAccess {
    for (read_only_procedure_names) |name| {
        if (std.ascii.eqlIgnoreCase(proc_name, name)) return .read_only;
    }
    return .mutating;
}

fn resolveProcedureCalleeName(allocator: std.mem.Allocator, callee: *const ast.Expr) !ResolvedProcedureName {
    return switch (callee.*) {
        .Ident => |ident| .{ .name = ident.orig },
        .Member => blk: {
            var name_parts = std.ArrayList(u8).empty;
            defer name_parts.deinit(allocator);

            try appendMemberPath(allocator, callee, &name_parts);
            break :blk .{
                .name = try name_parts.toOwnedSlice(allocator),
                .owned = true,
            };
        },
        else => .{ .name = "unknown" },
    };
}

fn callProcedureMatchesName(call_stmt: ast.CallProcedure, expected_name: []const u8) bool {
    return switch (call_stmt.procedure) {
        .Call => |call| calleeMatchesName(call.callee, expected_name),
        else => false,
    };
}

fn calleeMatchesName(callee: *const ast.Expr, expected_name: []const u8) bool {
    return switch (callee.*) {
        .Ident => |ident| std.ascii.eqlIgnoreCase(ident.orig, expected_name),
        .Member => |member| blk: {
            const dot_index = std.mem.lastIndexOfScalar(u8, expected_name, '.') orelse break :blk false;
            if (!std.ascii.eqlIgnoreCase(member.field, expected_name[dot_index + 1 ..])) break :blk false;
            break :blk calleeMatchesName(member.target, expected_name[0..dot_index]);
        },
        else => false,
    };
}

fn appendMemberPath(allocator: std.mem.Allocator, expr: *const ast.Expr, result: *std.ArrayList(u8)) !void {
    switch (expr.*) {
        .Member => |member| {
            try appendMemberPath(allocator, member.target, result);
            try result.append(allocator, '.');
            try result.appendSlice(allocator, member.field);
        },
        .Ident => |ident| try result.appendSlice(allocator, ident.orig),
        else => try result.appendSlice(allocator, "unknown"),
    }
}
