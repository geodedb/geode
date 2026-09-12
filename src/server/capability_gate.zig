//! Pure, bounded validation of the immutable Sonny capability contract.
const std = @import("std");

pub const CapabilityRow = struct { name: []const u8, value: []const u8 };

/// Decode only the producer's tag prefix. Preserve every remaining byte and
/// prerelease suffix; the strict predicate still decides whether it is SemVer.
pub fn engineVersionFromBuildLabel(raw: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, raw, "v")) raw[1..] else raw;
}
pub const CapabilityGateError = error{
    MalformedCapabilityProfile,
    MalformedCapabilityRows,
    UnsupportedCapabilityProfileVersion,
    CapabilityProfileVersionMismatch,
    InvalidEngineVersion,
    IncompatibleEngineVersion,
    MandatoryCapabilityMissing,
    MandatoryCapabilityUnsupported,
};

const max_manifest_bytes = 1 << 20;
const max_depth = 8;

// Requirements metadata only. Support always comes from borrowed discovery rows.
const v1_names = [_][]const u8{
    "sonny_profile_version",             "explain",                            "profile",                       "explain_policy",                  "read_only_execute",
    "read_only_covers_admin_ddl",        "strict_tenancy_production_default",  "tenant_scope_fail_closed",      "tenant_binding_server_verified",  "fts_search",
    "fts_row_visibility",                "fts_strict_tenancy",                 "fts_multi_graph",               "fts_rebuild",                     "vector_knn",
    "knn_row_visibility",                "knn_metric_validation",              "knn_delete_liveness",           "graph_procedure_tenancy",         "embedding_space_pinning",
    "vector_index_generations",          "vector_generation_rollback",         "vector_build_bounded",          "vector_index_restart_rebuild",    "bulk_vector_index_maintenance",
    "bulk_create_fts_maintenance",       "bulk_delete_batch",                  "index_build_telemetry",         "retrieval_ready",                 "traversal_multi_edge_type",
    "traversal_bounded_nodes_cost_time", "traversal_cycle_hub_control",        "traversal_cancellation",        "traversal_deterministic_ties",    "traversal_path_provenance",
    "weighted_path_raw_property",        "temporal_traversal_predicates",      "cdc_ordered_resumable",         "cdc_tenant_bound",                "cdc_backpressure_dlq_observable",
    "knn_filtered_ann_pushdown",         "federation_authorization_preserved", "federation_deterministic_topk", "federation_partial_shard_errors", "graph_community_summary_layer",
};

// A missing optional field differs from an explicitly supplied JSON null.
const OptionalText = struct {
    value: ?[]const u8 = null,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !OptionalText {
        return .{ .value = try std.json.innerParse([]const u8, allocator, source, options) };
    }
};

const Requirement = struct {
    row: []const u8,
    required: bool,
    jira: []const u8,
    gate: OptionalText = .{},
    note: OptionalText = .{},
};

const Manifest = struct {
    profile_version: []const u8,
    profile_name: []const u8,
    engine_version_min: []const u8,
    geode_client_go_min: []const u8,
    devnw_geode_min: []const u8,
    mandatory: []const Requirement,
    generated_by: OptionalText = .{},
};

const ValidationError = CapabilityGateError || std.mem.Allocator.Error;

fn parseFailure(err: anyerror) ValidationError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.MalformedCapabilityProfile;
}

// Scanner allocation is capped before any DOM/typed parse. Terminal tokens count
// once even when an escaped string arrived as multiple partial-string tokens.
fn preflight(allocator: std.mem.Allocator, bytes: []const u8) ValidationError!void {
    if (bytes.len > max_manifest_bytes or !std.unicode.utf8ValidateSlice(bytes)) return error.MalformedCapabilityProfile;
    var scanner = std.json.Scanner.initCompleteInput(allocator, bytes);
    defer scanner.deinit();
    scanner.ensureTotalStackCapacity(max_depth + 1) catch |err| return parseFailure(err);
    var counts = [_]usize{0} ** max_depth;
    var objects = [_]bool{false} ** max_depth;
    var depth: usize = 0;
    while (true) {
        const token = scanner.next() catch |err| return parseFailure(err);
        switch (token) {
            .object_begin, .array_begin, .string, .number, .true, .false, .null => {
                if (depth > 0) {
                    counts[depth - 1] += 1;
                    const limit: usize = if (objects[depth - 1]) 128 else 256;
                    if (counts[depth - 1] > limit) return error.MalformedCapabilityProfile;
                }
                if (token == .object_begin or token == .array_begin) {
                    if (depth == max_depth) return error.MalformedCapabilityProfile;
                    counts[depth] = 0;
                    objects[depth] = token == .object_begin;
                    depth += 1;
                }
            },
            .object_end, .array_end => {
                if (depth == 0) return error.MalformedCapabilityProfile;
                depth -= 1;
            },
            .end_of_document => return,
            else => {}, // Partial token bytes are bounded by the input size.
        }
    }
}

fn canonicalDecimal(value: []const u8) bool {
    if (value.len == 0 or (value.len > 1 and value[0] == '0')) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn boundedNumber(value: []const u8) bool {
    if (!canonicalDecimal(value)) return false;
    _ = std.fmt.parseUnsigned(u32, value, 10) catch return false;
    return true;
}

fn semanticVersion(value: []const u8) ?std.SemanticVersion {
    if (value.len == 0 or value.len > 128) return null;
    const core_end = std.mem.indexOfAny(u8, value, "-+") orelse value.len;
    var parts = std.mem.splitScalar(u8, value[0..core_end], '.');
    for (0..3) |_| if (!boundedNumber(parts.next() orelse return null)) return null;
    if (parts.next() != null) return null;
    const version = std.SemanticVersion.parse(value) catch return null;
    if (version.pre) |pre| {
        var ids = std.mem.splitScalar(u8, pre, '.');
        while (ids.next()) |id| {
            const numeric = for (id) |byte| {
                if (!std.ascii.isDigit(byte)) break false;
            } else true;
            if (numeric and !boundedNumber(id)) return null;
        }
    }
    return version;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or !std.ascii.isLower(name[0])) return false;
    for (name[1..]) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_') return false;
    return true;
}

fn validJira(value: []const u8) bool {
    if (value.len == 0 or value.len > 64 or !std.ascii.isUpper(value[0])) return false;
    const dash = std.mem.indexOfScalar(u8, value, '-') orelse return false;
    for (value[1..dash]) |byte| if (!std.ascii.isUpper(byte) and !std.ascii.isDigit(byte)) return false;
    if (dash + 1 == value.len) return false;
    for (value[dash + 1 ..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn validateManifest(manifest: Manifest) CapabilityGateError!void {
    if (manifest.profile_version.len > 128 or !canonicalDecimal(manifest.profile_version) or manifest.profile_name.len > 128)
        return error.MalformedCapabilityProfile;
    if (semanticVersion(manifest.engine_version_min) == null) return error.MalformedCapabilityProfile;
    for ([_][]const u8{ manifest.geode_client_go_min, manifest.devnw_geode_min }) |floor| {
        if (floor.len < 2 or floor.len > 128 or floor[0] != 'v' or semanticVersion(floor[1..]) == null) return error.MalformedCapabilityProfile;
    }
    if (!std.mem.eql(u8, manifest.engine_version_min, "0.8.14") or
        !std.mem.eql(u8, manifest.geode_client_go_min, "v0.1.28") or
        !std.mem.eql(u8, manifest.devnw_geode_min, "v0.0.3")) return error.MalformedCapabilityProfile;
    if (manifest.generated_by.value) |v| if (v.len > 4096) return error.MalformedCapabilityProfile;
    if (manifest.mandatory.len != v1_names.len) return error.MalformedCapabilityProfile;
    var seen = [_]bool{false} ** v1_names.len;
    for (manifest.mandatory) |requirement| {
        if (!validName(requirement.row) or !validJira(requirement.jira)) return error.MalformedCapabilityProfile;
        if (requirement.note.value) |v| if (v.len > 4096) return error.MalformedCapabilityProfile;
        const index = for (v1_names, 0..) |name, i| {
            if (std.mem.eql(u8, name, requirement.row)) break i;
        } else return error.MalformedCapabilityProfile;
        if (seen[index] or requirement.required != (index < 40)) return error.MalformedCapabilityProfile;
        seen[index] = true;
        if (index < 40) {
            if (requirement.gate.value != null) return error.MalformedCapabilityProfile;
        } else if (!std.mem.eql(u8, requirement.gate.value orelse return error.MalformedCapabilityProfile, "sonny_feature_gate")) return error.MalformedCapabilityProfile;
    }
}

fn rowValue(rows: []const CapabilityRow, name: []const u8) ?[]const u8 {
    for (rows) |row| if (std.mem.eql(u8, row.name, name)) return row.value;
    return null;
}

// CANARY: REQ=REQ-SONNY-CAPABILITY-PROFILE-002; FEATURE="SonnyCapabilityProfile"; ASPECT=PureValidation; STATUS=IMPL; TEST=tests/test_capability_gate.zig; OWNER=server; UPDATED=2026-09-08
pub fn validateProfile(allocator: std.mem.Allocator, manifest_json: []const u8, rows: []const CapabilityRow, engine_version: []const u8) ValidationError!void {
    try preflight(allocator, manifest_json);
    const parsed = std.json.parseFromSlice(Manifest, allocator, manifest_json, .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = 4096,
    }) catch |err| return parseFailure(err);
    defer parsed.deinit();
    const manifest = parsed.value;
    try validateManifest(manifest);
    const running = semanticVersion(engine_version) orelse return error.InvalidEngineVersion;
    if (rows.len > 256) return error.MalformedCapabilityRows;
    for (rows, 0..) |row, i| {
        if (!validName(row.name) or row.value.len > 128 or !std.unicode.utf8ValidateSlice(row.value)) return error.MalformedCapabilityRows;
        for (rows[0..i]) |earlier| if (std.mem.eql(u8, earlier.name, row.name)) return error.MalformedCapabilityRows;
        if (!std.mem.eql(u8, row.name, "sonny_profile_version") and
            !std.mem.eql(u8, row.value, "true") and !std.mem.eql(u8, row.value, "false")) return error.MalformedCapabilityRows;
    }
    if (!std.mem.eql(u8, manifest.profile_name, "sonny-graphrag")) return error.MalformedCapabilityProfile;
    if (!std.mem.eql(u8, manifest.profile_version, "1")) return error.UnsupportedCapabilityProfileVersion;
    const version_row = rowValue(rows, "sonny_profile_version") orelse return error.MandatoryCapabilityMissing;
    if (!std.mem.eql(u8, version_row, manifest.profile_version)) return error.CapabilityProfileVersionMismatch;
    const floor: std.SemanticVersion = .{ .major = 0, .minor = 8, .patch = 14 };
    if (running.order(floor) == .lt) return error.IncompatibleEngineVersion;
    for (v1_names[1..40]) |name| {
        const value = rowValue(rows, name) orelse return error.MandatoryCapabilityMissing;
        if (std.mem.eql(u8, value, "false")) return error.MandatoryCapabilityUnsupported;
    }
}

test "scanner enforces inclusive depth members and array limits before typed parsing" {
    const allocator = std.testing.allocator;
    try preflight(allocator, "[[[[[[[{}]]]]]]]");
    try std.testing.expectError(error.MalformedCapabilityProfile, preflight(allocator, "[[[[[[[[{}]]]]]]]]"));
    try preflight(allocator, "{" ++ ("\"x\":0," ** 63) ++ "\"x\":0}");
    try std.testing.expectError(error.MalformedCapabilityProfile, preflight(allocator, "{" ++ ("\"x\":0," ** 64) ++ "\"x\":0}"));
    try preflight(allocator, "[" ++ ("0," ** 255) ++ "0]");
    try std.testing.expectError(error.MalformedCapabilityProfile, preflight(allocator, "[" ++ ("0," ** 256) ++ "0]"));
    // Escaped scalar tokens count once, never once per scanner fragment.
    try preflight(allocator, "{" ++ ("\"\\u0061\":\"\\u0062\"," ** 63) ++ "\"a\":\"b\"}");
    try std.testing.expectError(error.MalformedCapabilityProfile, preflight(allocator, "{" ++ ("\"\\u0061\":\"\\u0062\"," ** 64) ++ "\"a\":\"b\"}"));
}
