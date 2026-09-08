// CANARY: REQ=REQ-SONNY-CAPABILITY-PROFILE-001; FEATURE="SonnyCapabilityProfile"; ASPECT=PublicationContract; STATUS=TESTED; TEST=tests/test_sonny_capability_profile.zig; OWNER=execution; UPDATED=2026-09-08
//
// GEO-UP-001: Sonny consumes the immutable requirements manifest separately
// from SHOW CAPABILITIES' runtime discovery values. These tests drive the real
// statement dispatch, pin the complete independent inventories, and exercise
// every capability-builder allocation failure through production dispatch.

const std = @import("std");
const geode = @import("geode");

const testing = std.testing;
const execution = geode.execution;
const admin_ddl = execution.admin_ddl;

const ExpectedRow = struct {
    name: []const u8,
    value: []const u8,
};

const expected_rows = [_]ExpectedRow{
    .{ .name = "auth_ddl", .value = "true" },
    .{ .name = "admin_writable", .value = "true" },
    .{ .name = "role_ddl", .value = "true" },
    .{ .name = "grant_ddl", .value = "true" },
    .{ .name = "show_permissions", .value = "true" },
    .{ .name = "show_version", .value = "true" },
    .{ .name = "policy_ddl", .value = "true" },
    .{ .name = "fle_ddl", .value = "false" },
    .{ .name = "tenant_ddl", .value = "false" },
    .{ .name = "vector_knn", .value = "true" },
    .{ .name = "vector_index_metrics", .value = "true" },
    .{ .name = "knn_metric_validation", .value = "true" },
    .{ .name = "fts_search", .value = "true" },
    .{ .name = "fts_phrase_proximity", .value = "true" },
    .{ .name = "fts_rebuild", .value = "true" },
    .{ .name = "fts_bulk_merge_live_maintenance", .value = "true" },
    .{ .name = "fts_row_visibility", .value = "true" },
    .{ .name = "ts_procedures", .value = "true" },
    .{ .name = "read_only_execute", .value = "true" },
    .{ .name = "mcp_read_only", .value = "true" },
    .{ .name = "explain", .value = "true" },
    .{ .name = "profile", .value = "true" },
    .{ .name = "explain_policy", .value = "true" },
    .{ .name = "sonny_profile_version", .value = "1" },
    .{ .name = "read_only_covers_admin_ddl", .value = "false" },
    .{ .name = "strict_tenancy_production_default", .value = "false" },
    .{ .name = "tenant_scope_fail_closed", .value = "false" },
    .{ .name = "tenant_binding_server_verified", .value = "false" },
    .{ .name = "fts_strict_tenancy", .value = "false" },
    .{ .name = "fts_multi_graph", .value = "false" },
    .{ .name = "knn_row_visibility", .value = "false" },
    .{ .name = "knn_delete_liveness", .value = "false" },
    .{ .name = "knn_filtered_ann_pushdown", .value = "false" },
    .{ .name = "graph_procedure_tenancy", .value = "false" },
    .{ .name = "embedding_space_pinning", .value = "false" },
    .{ .name = "vector_index_generations", .value = "false" },
    .{ .name = "vector_generation_rollback", .value = "false" },
    .{ .name = "vector_build_bounded", .value = "false" },
    .{ .name = "vector_index_restart_rebuild", .value = "false" },
    .{ .name = "bulk_vector_index_maintenance", .value = "false" },
    .{ .name = "bulk_create_fts_maintenance", .value = "false" },
    .{ .name = "bulk_delete_batch", .value = "false" },
    .{ .name = "index_build_telemetry", .value = "false" },
    .{ .name = "retrieval_ready", .value = "false" },
    .{ .name = "traversal_multi_edge_type", .value = "false" },
    .{ .name = "traversal_bounded_nodes_cost_time", .value = "false" },
    .{ .name = "traversal_cycle_hub_control", .value = "false" },
    .{ .name = "traversal_cancellation", .value = "false" },
    .{ .name = "traversal_deterministic_ties", .value = "false" },
    .{ .name = "traversal_path_provenance", .value = "false" },
    .{ .name = "weighted_path_raw_property", .value = "false" },
    .{ .name = "temporal_traversal_predicates", .value = "false" },
    .{ .name = "cdc_ordered_resumable", .value = "false" },
    .{ .name = "cdc_tenant_bound", .value = "false" },
    .{ .name = "cdc_backpressure_dlq_observable", .value = "false" },
    .{ .name = "federation_authorization_preserved", .value = "false" },
    .{ .name = "federation_deterministic_topk", .value = "false" },
    .{ .name = "federation_partial_shard_errors", .value = "false" },
    .{ .name = "graph_community_summary_layer", .value = "false" },
};

const ExpectedRequirement = struct {
    row: []const u8,
    required: bool,
    jira: []const u8,
    has_note: bool = false,
};

const expected_requirements = [_]ExpectedRequirement{
    .{ .row = "sonny_profile_version", .required = true, .jira = "ENG-4653" },
    .{ .row = "explain", .required = true, .jira = "ENG-4653" },
    .{ .row = "profile", .required = true, .jira = "ENG-4653" },
    .{ .row = "explain_policy", .required = true, .jira = "ENG-4653" },
    .{ .row = "read_only_execute", .required = true, .jira = "ENG-4651" },
    .{ .row = "read_only_covers_admin_ddl", .required = true, .jira = "ENG-4651" },
    .{ .row = "strict_tenancy_production_default", .required = true, .jira = "ENG-4651" },
    .{ .row = "tenant_scope_fail_closed", .required = true, .jira = "ENG-4651" },
    .{ .row = "tenant_binding_server_verified", .required = true, .jira = "ENG-4651" },
    .{ .row = "fts_search", .required = true, .jira = "ENG-4651" },
    .{ .row = "fts_row_visibility", .required = true, .jira = "ENG-4651" },
    .{ .row = "fts_strict_tenancy", .required = true, .jira = "ENG-4651" },
    .{ .row = "fts_multi_graph", .required = true, .jira = "ENG-4652" },
    .{ .row = "fts_rebuild", .required = true, .jira = "ENG-4652" },
    .{ .row = "vector_knn", .required = true, .jira = "ENG-4651" },
    .{ .row = "knn_row_visibility", .required = true, .jira = "ENG-4651" },
    .{ .row = "knn_metric_validation", .required = true, .jira = "ENG-4649" },
    .{ .row = "knn_delete_liveness", .required = true, .jira = "ENG-4649" },
    .{ .row = "graph_procedure_tenancy", .required = true, .jira = "ENG-4651" },
    .{ .row = "embedding_space_pinning", .required = true, .jira = "ENG-4649" },
    .{ .row = "vector_index_generations", .required = true, .jira = "ENG-4649" },
    .{ .row = "vector_generation_rollback", .required = true, .jira = "ENG-4649" },
    .{ .row = "vector_build_bounded", .required = true, .jira = "ENG-4649" },
    .{ .row = "vector_index_restart_rebuild", .required = true, .jira = "ENG-4649" },
    .{ .row = "bulk_vector_index_maintenance", .required = true, .jira = "ENG-4649" },
    .{ .row = "bulk_create_fts_maintenance", .required = true, .jira = "ENG-4652" },
    .{ .row = "bulk_delete_batch", .required = true, .jira = "ENG-4652" },
    .{ .row = "index_build_telemetry", .required = true, .jira = "ENG-4652" },
    .{ .row = "retrieval_ready", .required = true, .jira = "ENG-4652" },
    .{ .row = "traversal_multi_edge_type", .required = true, .jira = "ENG-4655" },
    .{ .row = "traversal_bounded_nodes_cost_time", .required = true, .jira = "ENG-4655" },
    .{ .row = "traversal_cycle_hub_control", .required = true, .jira = "ENG-4655" },
    .{ .row = "traversal_cancellation", .required = true, .jira = "ENG-4655" },
    .{ .row = "traversal_deterministic_ties", .required = true, .jira = "ENG-4655" },
    .{ .row = "traversal_path_provenance", .required = true, .jira = "ENG-4655" },
    .{ .row = "weighted_path_raw_property", .required = true, .jira = "ENG-4655" },
    .{ .row = "temporal_traversal_predicates", .required = true, .jira = "ENG-4655" },
    .{ .row = "cdc_ordered_resumable", .required = true, .jira = "ENG-4654" },
    .{ .row = "cdc_tenant_bound", .required = true, .jira = "ENG-4654" },
    .{ .row = "cdc_backpressure_dlq_observable", .required = true, .jira = "ENG-4654" },
    .{ .row = "knn_filtered_ann_pushdown", .required = false, .jira = "ENG-4651", .has_note = true },
    .{ .row = "federation_authorization_preserved", .required = false, .jira = "ENG-4654", .has_note = true },
    .{ .row = "federation_deterministic_topk", .required = false, .jira = "ENG-4654" },
    .{ .row = "federation_partial_shard_errors", .required = false, .jira = "ENG-4654" },
    .{ .row = "graph_community_summary_layer", .required = false, .jira = "ENG-4654", .has_note = true },
};

fn showCapabilities(allocator: std.mem.Allocator, catalog: *geode.catalog.Catalog) !execution.ExecutionResult {
    var parsed = try geode.parseGql("SHOW CAPABILITIES", allocator);
    defer parsed.deinit();
    return execution.executeStatementWithContext(
        allocator,
        parsed.program.statements[0],
        execution.ExecutionContext{ .catalog = catalog },
    );
}

fn asString(value: geode.value_types.Value) ![]const u8 {
    return switch (value) {
        .Str => |text| text,
        else => error.CapabilityCellNotString,
    };
}

fn readManifest(allocator: std.mem.Allocator) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(
        io,
        "release/sonny_capability_profile.json",
        allocator,
        .limited(1 << 20),
    );
}

fn initCatalog(allocator: std.mem.Allocator) !*geode.catalog.Catalog {
    return geode.catalog.Catalog.init(allocator, "/nonexistent/geode-sonny-capability-profile-test");
}

fn deinitCatalog(allocator: std.mem.Allocator, catalog: *geode.catalog.Catalog) void {
    catalog.deinit();
    allocator.destroy(catalog);
}

const AllocationEvent = struct {
    len: usize,
    alignment: std.mem.Alignment,
    return_address: usize,
};

const RecordingAllocator = struct {
    backing: std.mem.Allocator,
    events: [1024]AllocationEvent = undefined,
    event_count: usize = 0,
    resize_count: usize = 0,
    remap_count: usize = 0,

    fn init(backing: std.mem.Allocator) RecordingAllocator {
        return .{ .backing = backing };
    }

    fn allocator(self: *RecordingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *RecordingAllocator = @ptrCast(@alignCast(context));
        if (self.event_count >= self.events.len) return null;
        self.events[self.event_count] = .{
            .len = len,
            .alignment = alignment,
            .return_address = return_address,
        };
        self.event_count += 1;
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *RecordingAllocator = @ptrCast(@alignCast(context));
        self.resize_count += 1;
        return self.backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *RecordingAllocator = @ptrCast(@alignCast(context));
        self.remap_count += 1;
        return self.backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *RecordingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, return_address);
    }

    fn slice(self: *RecordingAllocator) []const AllocationEvent {
        return self.events[0..self.event_count];
    }
};

fn sameAllocationEvent(left: AllocationEvent, right: AllocationEvent) bool {
    return left.len == right.len and
        left.alignment == right.alignment and
        left.return_address == right.return_address;
}

fn findAllocationSequence(all: []const AllocationEvent, sequence: []const AllocationEvent) !usize {
    if (sequence.len == 0 or sequence.len > all.len) return error.AllocationSequenceMissing;
    var match_count: usize = 0;
    var match_start: usize = 0;
    for (0..all.len - sequence.len + 1) |start| {
        for (sequence, all[start .. start + sequence.len]) |expected, actual| {
            if (!sameAllocationEvent(expected, actual)) break;
        } else {
            match_count += 1;
            match_start = start;
        }
    }
    if (match_count != 1) return error.AllocationSequenceNotUnique;
    return match_start;
}

fn requireJsonString(object: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.MissingManifestField;
    return switch (value) {
        .string => |text| text,
        else => error.ManifestFieldWrongType,
    };
}

test "SHOW CAPABILITIES emits the exact ordered 59-row typed value oracle" {
    const catalog = try initCatalog(testing.allocator);
    defer deinitCatalog(testing.allocator, catalog);
    var result = try showCapabilities(testing.allocator, catalog);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), result.columns.len);
    try testing.expectEqualStrings("feature", result.columns[0]);
    try testing.expectEqualStrings("supported", result.columns[1]);
    try testing.expect(result.owns_value_memory);
    try testing.expectEqual(expected_rows.len, result.rows.len);

    var unique_names = std.StringHashMap(void).init(testing.allocator);
    defer unique_names.deinit();

    for (expected_rows, result.rows) |expected, actual| {
        try testing.expectEqual(@as(usize, 2), actual.len);
        const name = try asString(actual[0]);
        const value = try asString(actual[1]);
        try testing.expectEqualStrings(expected.name, name);
        try testing.expectEqualStrings(expected.value, value);
        try testing.expect(!unique_names.contains(name));
        try unique_names.put(name, {});
    }
    try testing.expectEqual(expected_rows.len, unique_names.count());
}

test "SHOW CAPABILITIES production dispatch cleans every capability-builder allocation failure" {
    const catalog = try initCatalog(testing.allocator);
    defer deinitCatalog(testing.allocator, catalog);
    var parsed = try geode.parseGql("SHOW CAPABILITIES", testing.allocator);
    defer parsed.deinit();
    const statement = parsed.program.statements[0];
    const context = execution.ExecutionContext{ .catalog = catalog };

    // The real SHOW dispatcher first builds a query-read snapshot. Its OOM
    // handling belongs to that subsystem, so identify the terminal builder's
    // exact allocation sequence and fail each of those allocations only.
    var builder_trace = RecordingAllocator.init(testing.allocator);
    var direct_result = try admin_ddl.executeShowCapabilities(builder_trace.allocator());
    direct_result.deinit(builder_trace.allocator());
    const expected_builder_allocation_count: usize = 4 + 3 * expected_rows.len;
    try testing.expectEqual(expected_builder_allocation_count, builder_trace.event_count);
    try testing.expectEqual(@as(usize, 0), builder_trace.resize_count);
    try testing.expectEqual(@as(usize, 0), builder_trace.remap_count);

    var dispatch_trace = RecordingAllocator.init(testing.allocator);
    var dispatched_result = try execution.executeStatementWithContext(dispatch_trace.allocator(), statement, context);
    dispatched_result.deinit(dispatch_trace.allocator());
    const first_builder_allocation = try findAllocationSequence(dispatch_trace.slice(), builder_trace.slice());

    for (builder_trace.slice(), 0..) |_, builder_index| {
        const fail_index = first_builder_allocation + builder_index;
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        if (execution.executeStatementWithContext(allocator, statement, context)) |result_value| {
            var result = result_value;
            result.deinit(allocator);
            return error.ExpectedOutOfMemory;
        } else |err| {
            if (err != error.OutOfMemory) return err;
        }
        try testing.expect(failing.has_induced_failure);
        try testing.expectEqual(fail_index, failing.fail_index);
        try testing.expectEqual(fail_index, failing.alloc_index);
        if (failing.allocated_bytes != failing.freed_bytes) return error.MemoryLeakDetected;
    }
}

test "shipped profile is the exact immutable 45-requirement contract" {
    const manifest_bytes = try readManifest(testing.allocator);
    defer testing.allocator.free(manifest_bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, manifest_bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.ManifestRootNotObject;
    const manifest = parsed.value.object;

    try testing.expectEqual(@as(usize, 7), manifest.count());
    try testing.expectEqualStrings("1", try requireJsonString(manifest, "profile_version"));
    try testing.expectEqualStrings("sonny-graphrag", try requireJsonString(manifest, "profile_name"));
    try testing.expectEqualStrings("0.8.14", try requireJsonString(manifest, "engine_version_min"));
    try testing.expectEqualStrings("v0.1.28", try requireJsonString(manifest, "geode_client_go_min"));
    try testing.expectEqualStrings("v0.0.3", try requireJsonString(manifest, "devnw_geode_min"));
    try testing.expectEqualStrings("docs/SONNY_CAPABILITY_PROFILE.md", try requireJsonString(manifest, "generated_by"));

    const mandatory_value = manifest.get("mandatory") orelse return error.MissingManifestField;
    if (mandatory_value != .array) return error.ManifestFieldWrongType;
    try testing.expectEqual(expected_requirements.len, mandatory_value.array.items.len);

    var required_count: usize = 0;
    var optional_count: usize = 0;
    var unique_names = std.StringHashMap(void).init(testing.allocator);
    defer unique_names.deinit();

    for (expected_requirements, mandatory_value.array.items) |expected, actual_value| {
        if (actual_value != .object) return error.ManifestRequirementNotObject;
        const actual = actual_value.object;
        const expected_field_count: usize = if (expected.required) 3 else if (expected.has_note) 5 else 4;
        try testing.expectEqual(expected_field_count, actual.count());

        const row = try requireJsonString(actual, "row");
        try testing.expectEqualStrings(expected.row, row);
        try testing.expect(!unique_names.contains(row));
        try unique_names.put(row, {});

        const required_value = actual.get("required") orelse return error.MissingManifestField;
        if (required_value != .bool) return error.ManifestFieldWrongType;
        try testing.expectEqual(expected.required, required_value.bool);
        try testing.expectEqualStrings(expected.jira, try requireJsonString(actual, "jira"));
        try testing.expect(actual.get("supported") == null);

        if (expected.required) {
            required_count += 1;
            try testing.expect(actual.get("gate") == null);
            try testing.expect(actual.get("note") == null);
        } else {
            optional_count += 1;
            try testing.expectEqualStrings("sonny_feature_gate", try requireJsonString(actual, "gate"));
            if (expected.has_note) {
                try testing.expect((try requireJsonString(actual, "note")).len > 0);
            } else {
                try testing.expect(actual.get("note") == null);
            }
        }
    }

    try testing.expectEqual(@as(usize, 40), required_count);
    try testing.expectEqual(@as(usize, 5), optional_count);
    try testing.expectEqual(expected_requirements.len, unique_names.count());
}

test "every requirement names an actually emitted discovery row" {
    const manifest_bytes = try readManifest(testing.allocator);
    defer testing.allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, manifest_bytes, .{});
    defer parsed.deinit();

    const catalog = try initCatalog(testing.allocator);
    defer deinitCatalog(testing.allocator, catalog);
    var result = try showCapabilities(testing.allocator, catalog);
    defer result.deinit(testing.allocator);
    var emitted = std.StringHashMap(void).init(testing.allocator);
    defer emitted.deinit();
    for (result.rows) |row| try emitted.put(try asString(row[0]), {});

    const mandatory = parsed.value.object.get("mandatory") orelse return error.MissingManifestField;
    for (mandatory.array.items) |entry| {
        const row = try requireJsonString(entry.object, "row");
        try testing.expect(emitted.contains(row));
    }
}
