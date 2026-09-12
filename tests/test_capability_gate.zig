const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const cli_args = @import("cli_args");
const gate = geode.capability_gate;

// Independent v1 requirements oracle, never derived from discovery support.
const required_names = [_][]const u8{
    "sonny_profile_version",             "explain",                           "profile",                  "explain_policy",                 "read_only_execute",
    "read_only_covers_admin_ddl",        "strict_tenancy_production_default", "tenant_scope_fail_closed", "tenant_binding_server_verified", "fts_search",
    "fts_row_visibility",                "fts_strict_tenancy",                "fts_multi_graph",          "fts_rebuild",                    "vector_knn",
    "knn_row_visibility",                "knn_metric_validation",             "knn_delete_liveness",      "graph_procedure_tenancy",        "embedding_space_pinning",
    "vector_index_generations",          "vector_generation_rollback",        "vector_build_bounded",     "vector_index_restart_rebuild",   "bulk_vector_index_maintenance",
    "bulk_create_fts_maintenance",       "bulk_delete_batch",                 "index_build_telemetry",    "retrieval_ready",                "traversal_multi_edge_type",
    "traversal_bounded_nodes_cost_time", "traversal_cycle_hub_control",       "traversal_cancellation",   "traversal_deterministic_ties",   "traversal_path_provenance",
    "weighted_path_raw_property",        "temporal_traversal_predicates",     "cdc_ordered_resumable",    "cdc_tenant_bound",               "cdc_backpressure_dlq_observable",
};
const optional_names = [_][]const u8{ "knn_filtered_ann_pushdown", "federation_authorization_preserved", "federation_deterministic_topk", "federation_partial_shard_errors", "graph_community_summary_layer" };

fn manifestBytes() ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "release/sonny_capability_profile.json", testing.allocator, .limited((1 << 20) + 1));
}

fn positiveRows() [40]gate.CapabilityRow {
    var rows: [40]gate.CapabilityRow = undefined;
    for (required_names, 0..) |name, i| rows[i] = .{ .name = name, .value = if (i == 0) "1" else "true" };
    return rows;
}

fn changedManifest(bytes: []const u8, needle: []const u8, replacement: []const u8, expected: anyerror) !void {
    try testing.expect(std.mem.indexOf(u8, bytes, needle) != null);
    const changed = try std.mem.replaceOwned(u8, testing.allocator, bytes, needle, replacement);
    defer testing.allocator.free(changed);
    const rows = positiveRows();
    try testing.expectError(expected, gate.validateProfile(testing.allocator, changed, &rows, "0.8.14"));
}

fn expectMalformedValue(value: std.json.Value) !void {
    const encoded = try std.json.Stringify.valueAlloc(testing.allocator, value, .{});
    defer testing.allocator.free(encoded);
    const rows = positiveRows();
    try testing.expectError(error.MalformedCapabilityProfile, gate.validateProfile(testing.allocator, encoded, &rows, "0.8.14"));
}

test "missing null and wrong typed fields including every optional entry" {
    const bytes = try manifestBytes();
    defer testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    defer parsed.deinit();
    for ([_][]const u8{ "profile_version", "profile_name", "engine_version_min", "geode_client_go_min", "devnw_geode_min", "mandatory" }) |field| {
        const original = parsed.value.object.get(field).?;
        _ = parsed.value.object.orderedRemove(field);
        try expectMalformedValue(parsed.value);
        try parsed.value.object.put(parsed.arena.allocator(), field, original);
    }
    for ([_][]const u8{ "profile_version", "profile_name", "engine_version_min", "geode_client_go_min", "devnw_geode_min", "mandatory", "generated_by" }) |field| {
        const pointer = parsed.value.object.getPtr(field).?;
        const original = pointer.*;
        for ([_]std.json.Value{ .null, .{ .integer = 1 }, .{ .bool = true } }) |invalid| {
            pointer.* = invalid;
            try expectMalformedValue(parsed.value);
        }
        pointer.* = original;
    }
    const mandatory = parsed.value.object.getPtr("mandatory").?;
    const original_array = mandatory.*;
    mandatory.array.items = mandatory.array.items[0..0];
    try expectMalformedValue(parsed.value);
    mandatory.* = original_array;
    mandatory.array.items = mandatory.array.items[0..44];
    try expectMalformedValue(parsed.value);
    mandatory.* = original_array;
    for (mandatory.array.items) |*entry| {
        for ([_][]const u8{ "row", "required", "jira" }) |field| {
            const original = entry.object.get(field).?;
            _ = entry.object.orderedRemove(field);
            try expectMalformedValue(parsed.value);
            try entry.object.put(parsed.arena.allocator(), field, original);
            const pointer = entry.object.getPtr(field).?;
            pointer.* = .null;
            try expectMalformedValue(parsed.value);
            pointer.* = original;
        }
        if (entry.object.get("gate")) |original| {
            _ = entry.object.orderedRemove("gate");
            try expectMalformedValue(parsed.value);
            try entry.object.put(parsed.arena.allocator(), "gate", .null);
            try expectMalformedValue(parsed.value);
            entry.object.getPtr("gate").?.* = original;
        } else {
            try entry.object.put(parsed.arena.allocator(), "gate", .{ .string = "sonny_feature_gate" });
            try expectMalformedValue(parsed.value);
            _ = entry.object.orderedRemove("gate");
        }
        const old_note = entry.object.get("note");
        try entry.object.put(parsed.arena.allocator(), "note", .null);
        try expectMalformedValue(parsed.value);
        if (old_note) |v| entry.object.getPtr("note").?.* = v else _ = entry.object.orderedRemove("note");
        const required = entry.object.getPtr("required").?;
        required.bool = !required.bool;
        try expectMalformedValue(parsed.value);
        required.bool = !required.bool;
    }
}

test "strict complete manifest schema and decoded duplicate keys" {
    const bytes = try manifestBytes();
    defer testing.allocator.free(bytes);
    const rows = positiveRows();
    for ([_][]const u8{ "{}", "[]", "null", "true", "1", "\"text\"", "\xef\xbb\xbf{}", "/* comment */{}", "{\"x\":\"\xff\"}" }) |bad|
        try testing.expectError(error.MalformedCapabilityProfile, gate.validateProfile(testing.allocator, bad, &rows, "0.8.14"));
    const fields = [_][]const u8{ "profile_version", "profile_name", "engine_version_min", "geode_client_go_min", "devnw_geode_min", "mandatory", "generated_by", "row", "required", "jira", "gate", "note" };
    for (fields) |field| {
        const needle = try std.fmt.allocPrint(testing.allocator, "\"{s}\":", .{field});
        defer testing.allocator.free(needle);
        const unknown = try std.fmt.allocPrint(testing.allocator, "\"unknown_{s}\":", .{field});
        defer testing.allocator.free(unknown);
        try changedManifest(bytes, needle, unknown, error.MalformedCapabilityProfile);
        for ([_][]const u8{ "null", "[]", "{}", "123" }) |value| {
            const replacement = try std.fmt.allocPrint(testing.allocator, "\"{s}\":{s},\"{s}\":", .{ field, value, field });
            defer testing.allocator.free(replacement);
            try changedManifest(bytes, needle, replacement, error.MalformedCapabilityProfile);
        }
    }
    try changedManifest(bytes, "\"profile_version\":", "\"profile_vers\\u0069on\":\"1\",\"profile_version\":", error.MalformedCapabilityProfile);
    try changedManifest(bytes, "\"row\":", "\"r\\u006fw\":\"explain\",\"row\":", error.MalformedCapabilityProfile);
    try changedManifest(bytes, "\"1\"", "1", error.MalformedCapabilityProfile);
    try changedManifest(bytes, "\"1\"", "\"01\"", error.MalformedCapabilityProfile);
    try changedManifest(bytes, "\"1\"", "\"1 \"", error.MalformedCapabilityProfile);
    try changedManifest(bytes, "\"1\"", "\"2\"", error.UnsupportedCapabilityProfileVersion);
    try changedManifest(bytes, "sonny-graphrag", "other-profile", error.MalformedCapabilityProfile);
    try changedManifest(bytes, "\"required\": true", "\"required\": false", error.MalformedCapabilityProfile);
    try changedManifest(bytes, "\"required\": false", "\"required\": true", error.MalformedCapabilityProfile);
    try changedManifest(bytes, "sonny_feature_gate", "off", error.MalformedCapabilityProfile);
    try changedManifest(bytes, "\"explain_policy\"", "\"explain\"", error.MalformedCapabilityProfile);
    try changedManifest(bytes, "\"explain_policy\"", "\"unknown_row\"", error.MalformedCapabilityProfile);
    try changedManifest(bytes, "\"jira\": \"ENG-4653\"", "\"jira\": \"eng-4653\"", error.MalformedCapabilityProfile);
    const trailing = try std.mem.concat(testing.allocator, u8, &.{ bytes, " {}" });
    defer testing.allocator.free(trailing);
    try testing.expectError(error.MalformedCapabilityProfile, gate.validateProfile(testing.allocator, trailing, &rows, "0.8.14"));
}

test "all row shapes including optional and unknown rows are validated first" {
    const bytes = try manifestBytes();
    defer testing.allocator.free(bytes);
    const initial = positiveRows();
    var rows: [41]gate.CapabilityRow = undefined;
    @memcpy(rows[0..40], &initial);
    for (optional_names ++ .{"future_boolean"}) |name| {
        rows[40] = .{ .name = name, .value = "false" };
        try gate.validateProfile(testing.allocator, bytes, &rows, "0.8.14");
        for ([_][]const u8{ "", "1", "0", "TRUE", "yes", "null", " true", "false ", "arbitrary" }) |value| {
            rows[40].value = value;
            try testing.expectError(error.MalformedCapabilityRows, gate.validateProfile(testing.allocator, bytes, &rows, "0.8.13"));
        }
    }
    for ([_][]const u8{ "", "Upper", "1name", "bad-name", "bad name", "na\x00me", "é" }) |name| {
        rows[40] = .{ .name = name, .value = "true" };
        try testing.expectError(error.MalformedCapabilityRows, gate.validateProfile(testing.allocator, bytes, &rows, "0.8.14"));
    }
    rows[40] = initial[0];
    try testing.expectError(error.MalformedCapabilityRows, gate.validateProfile(testing.allocator, bytes, &rows, "0.8.14"));
    var unknown_duplicates: [42]gate.CapabilityRow = undefined;
    @memcpy(unknown_duplicates[0..40], &initial);
    unknown_duplicates[40] = .{ .name = "unknown_boolean", .value = "true" };
    unknown_duplicates[41] = unknown_duplicates[40];
    try testing.expectError(error.MalformedCapabilityRows, gate.validateProfile(testing.allocator, bytes, &unknown_duplicates, "0.8.14"));
    for ([_][]const u8{ "true", "false", "1 ", "01", "2", "" }) |value| {
        var version_rows = initial;
        version_rows[0].value = value;
        try testing.expectError(error.CapabilityProfileVersionMismatch, gate.validateProfile(testing.allocator, bytes, &version_rows, "0.8.14"));
    }
}

test "canonical SemVer syntax precedence and immutable floors" {
    const bytes = try manifestBytes();
    defer testing.allocator.free(bytes);
    const rows = positiveRows();
    for ([_][]const u8{ "0.8.14", "0.8.14+build.01", "0.9.0-alpha.1", "1.0.0", "4294967295.4294967295.4294967295" }) |v|
        try gate.validateProfile(testing.allocator, bytes, &rows, v);
    for ([_][]const u8{ "0.8.13", "0.8.14-rc.1", "0.8.14-1+build", "0.0.0" }) |v|
        try testing.expectError(error.IncompatibleEngineVersion, gate.validateProfile(testing.allocator, bytes, &rows, v));
    for ([_][]const u8{ "", "dev", "0.8", "0.8.14.0", "v0.8.14", "vv0.8.14", " 0.8.14", "0.8.14 ", "00.8.14", "+0.8.14", "0.08.14", "0.8.014", "0.8.-1", "0.8.14-", "0.8.14+", "0.8.14-a..b", "0.8.14-01", "0.8.14-4294967296", "4294967296.0.0", "0.8.14-a_b", "0.8.14+a+b", "0.8.14-ä" }) |v| {
        try testing.expectError(error.InvalidEngineVersion, gate.validateProfile(testing.allocator, bytes, &rows, v));
        try changedManifest(bytes, "0.8.14", v, error.MalformedCapabilityProfile);
    }
    for ([_][]const u8{ "0.8.13", "0.8.15", "0.8.14+changed" }) |v|
        try changedManifest(bytes, "0.8.14", v, error.MalformedCapabilityProfile);
    for ([_][]const u8{ "0.1.28", "vv0.1.28", "v0.1.27", "v0.1.29", "v0.1.028", "v4294967296.0.0" }) |v|
        try changedManifest(bytes, "v0.1.28", v, error.MalformedCapabilityProfile);
    try changedManifest(bytes, "v0.0.3", "v0.0.4", error.MalformedCapabilityProfile);
}

fn validateAllocation(allocator: std.mem.Allocator, bytes: []const u8, malformed: bool) !void {
    const rows = positiveRows();
    if (malformed) {
        gate.validateProfile(allocator, bytes, &rows, "0.8.14") catch |err| {
            if (err == error.OutOfMemory) return err;
            return testing.expectEqual(error.MalformedCapabilityProfile, err);
        };
        return error.ExpectedMalformedProfile;
    } else try gate.validateProfile(allocator, bytes, &rows, "0.8.14");
}

test "pure allocation failures preserve OOM and borrowed input" {
    const bytes = try manifestBytes();
    defer testing.allocator.free(bytes);
    const copy = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(copy);
    try testing.checkAllAllocationFailures(testing.allocator, validateAllocation, .{ bytes, false });
    const malformed = try std.mem.replaceOwned(u8, testing.allocator, bytes, "sonny_feature_gate", "wrong_feature_gate");
    defer testing.allocator.free(malformed);
    try testing.checkAllAllocationFailures(testing.allocator, validateAllocation, .{ malformed, true });
    try testing.expectEqualSlices(u8, copy, bytes);
}

test "inclusive manifest string row count and SemVer bounds" {
    const bytes = try manifestBytes();
    defer testing.allocator.free(bytes);
    const rows = positiveRows();
    const padded = try testing.allocator.alloc(u8, (1 << 20) + 1);
    defer testing.allocator.free(padded);
    @memset(padded, ' ');
    @memcpy(padded[0..bytes.len], bytes);
    try gate.validateProfile(testing.allocator, padded[0 .. 1 << 20], &rows, "0.8.14");
    try testing.expectError(error.MalformedCapabilityProfile, gate.validateProfile(testing.allocator, padded, &rows, "0.8.14"));
    var metadata: [4097]u8 = @splat('a');
    for ([_]usize{ 4096, 4097 }) |length| {
        const altered = try std.mem.replaceOwned(u8, testing.allocator, bytes, "docs/SONNY_CAPABILITY_PROFILE.md", metadata[0..length]);
        defer testing.allocator.free(altered);
        if (length == 4096) try gate.validateProfile(testing.allocator, altered, &rows, "0.8.14") else try testing.expectError(error.MalformedCapabilityProfile, gate.validateProfile(testing.allocator, altered, &rows, "0.8.14"));
    }
    var version: [129]u8 = @splat('a');
    @memcpy(version[0..7], "0.8.14+");
    try gate.validateProfile(testing.allocator, bytes, &rows, version[0..128]);
    try testing.expectError(error.InvalidEngineVersion, gate.validateProfile(testing.allocator, bytes, &rows, &version));
    var name: [129]u8 = @splat('a');
    var many: [257]gate.CapabilityRow = undefined;
    @memcpy(many[0..40], &rows);
    var names: [217][20]u8 = undefined;
    for (many[40..], 0..) |*row, i| row.* = .{ .name = try std.fmt.bufPrint(&names[i], "future_{d}", .{i}), .value = "true" };
    try gate.validateProfile(testing.allocator, bytes, many[0..256], "0.8.14");
    try testing.expectError(error.MalformedCapabilityRows, gate.validateProfile(testing.allocator, bytes, &many, "0.8.14"));
    many[40].name = name[0..128];
    try gate.validateProfile(testing.allocator, bytes, many[0..41], "0.8.14");
    many[40].name = &name;
    try testing.expectError(error.MalformedCapabilityRows, gate.validateProfile(testing.allocator, bytes, many[0..41], "0.8.14"));
    many[40].name = "future_value";
    many[40].value = name[0..128];
    try testing.expectError(error.MalformedCapabilityRows, gate.validateProfile(testing.allocator, bytes, many[0..41], "0.8.14"));
    var version_rows = rows;
    version_rows[0].value = name[0..128];
    try testing.expectError(error.CapabilityProfileVersionMismatch, gate.validateProfile(testing.allocator, bytes, &version_rows, "0.8.14"));
    version_rows[0].value = &name;
    try testing.expectError(error.MalformedCapabilityRows, gate.validateProfile(testing.allocator, bytes, &version_rows, "0.8.14"));
    var jira: [65]u8 = @splat('1');
    @memcpy(jira[0..2], "A-");
    for ([_]usize{ 64, 65 }) |length| {
        const altered = try std.mem.replaceOwned(u8, testing.allocator, bytes, "ENG-4653", jira[0..length]);
        defer testing.allocator.free(altered);
        if (length == 64) try gate.validateProfile(testing.allocator, altered, &rows, "0.8.14") else try testing.expectError(error.MalformedCapabilityProfile, gate.validateProfile(testing.allocator, altered, &rows, "0.8.14"));
    }
    for ([_]usize{ 128, 129 }) |length| {
        var identity: [129]u8 = @splat('2');
        const quoted = try std.fmt.allocPrint(testing.allocator, "\"{s}\"", .{identity[0..length]});
        defer testing.allocator.free(quoted);
        try changedManifest(bytes, "\"1\"", quoted, if (length == 128) error.UnsupportedCapabilityProfileVersion else error.MalformedCapabilityProfile);
    }
    const escaped = "\\u0061" ** 4096;
    const escaped_manifest = try std.mem.replaceOwned(u8, testing.allocator, bytes, "docs/SONNY_CAPABILITY_PROFILE.md", escaped);
    defer testing.allocator.free(escaped_manifest);
    try gate.validateProfile(testing.allocator, escaped_manifest, &rows, "0.8.14");
    try changedManifest(bytes, "docs/SONNY_CAPABILITY_PROFILE.md", escaped ++ "\\u0061", error.MalformedCapabilityProfile);
}

test "pure canonical parser control accepts all required support and absent optional support" {
    const bytes = try manifestBytes();
    defer testing.allocator.free(bytes);
    const rows = positiveRows();
    try gate.validateProfile(testing.allocator, bytes, &rows, "0.8.14");
}

test "optional metadata does not change requirements and note bounds count decoded bytes" {
    const bytes = try manifestBytes();
    defer testing.allocator.free(bytes);
    const rows = positiveRows();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bytes, .{});
    defer parsed.deinit();
    _ = parsed.value.object.orderedRemove("generated_by");
    const entries = parsed.value.object.getPtr("mandatory").?.array.items;
    for (entries) |*entry| {
        _ = entry.object.orderedRemove("note");
        entry.object.getPtr("jira").?.* = .{ .string = "A-0" };
    }
    std.mem.reverse(std.json.Value, entries);
    const without_metadata = try std.json.Stringify.valueAlloc(testing.allocator, parsed.value, .{});
    defer testing.allocator.free(without_metadata);
    try gate.validateProfile(testing.allocator, without_metadata, &rows, "0.8.14");
    const note = "é" ** 2048;
    try entries[0].object.put(parsed.arena.allocator(), "note", .{ .string = note });
    const exact = try std.json.Stringify.valueAlloc(testing.allocator, parsed.value, .{});
    defer testing.allocator.free(exact);
    try gate.validateProfile(testing.allocator, exact, &rows, "0.8.14");
    entries[0].object.getPtr("note").?.* = .{ .string = note ++ "a" };
    try expectMalformedValue(parsed.value);
}

test "pure gate rejects every missing required row and every false required boolean" {
    const bytes = try manifestBytes();
    defer testing.allocator.free(bytes);
    for (required_names, 0..) |_, i| {
        var rows = positiveRows();
        const removed = rows[i];
        rows[i] = rows[rows.len - 1];
        try testing.expectError(error.MandatoryCapabilityMissing, gate.validateProfile(testing.allocator, bytes, rows[0 .. rows.len - 1], "0.8.14"));
        if (i == 0) continue;
        rows[i] = .{ .name = removed.name, .value = "false" };
        try testing.expectError(error.MandatoryCapabilityUnsupported, gate.validateProfile(testing.allocator, bytes, &rows, "0.8.14"));
    }
}

test "real discovery refuses the actual engine floor" {
    const bytes = try manifestBytes();
    defer testing.allocator.free(bytes);
    var caps = try geode.execution.admin_ddl.executeShowCapabilities(testing.allocator);
    defer caps.deinit(testing.allocator);
    var rows: [59]gate.CapabilityRow = undefined;
    try testing.expectEqual(rows.len, caps.rows.len);
    for (caps.rows, 0..) |row, i| rows[i] = .{ .name = row[0].Str, .value = row[1].Str };
    try testing.expectError(error.InvalidEngineVersion, gate.validateProfile(testing.allocator, bytes, &rows, @import("build_options").version));
    // The running build's refusal reason is version-relative: below the engine
    // floor the gate stops at the version check, at or above it the still-false
    // mandatory rows decide. Both are refusals; only the reason moves.
    const running_label = gate.engineVersionFromBuildLabel(@import("build_options").version);
    const running = try std.SemanticVersion.parse(running_label);
    const floor: std.SemanticVersion = .{ .major = 0, .minor = 8, .patch = 14 };
    const expected_running: anyerror = if (running.order(floor) == .lt) error.IncompatibleEngineVersion else error.MandatoryCapabilityUnsupported;
    try testing.expectError(expected_running, gate.validateProfile(testing.allocator, bytes, &rows, running_label));
    // Floor refusal stays covered deterministically, independent of the build.
    try testing.expectError(error.IncompatibleEngineVersion, gate.validateProfile(testing.allocator, bytes, &rows, "0.8.13"));
    try testing.expectError(error.IncompatibleEngineVersion, gate.validateProfile(testing.allocator, bytes, &rows, "0.8.14-2-g080f1737"));
    try testing.expectError(error.MandatoryCapabilityUnsupported, gate.validateProfile(testing.allocator, bytes, &rows, "0.8.14"));
}

test "producer adapter borrows exact remainder after at most one lowercase v" {
    for ([_][]const u8{ "", "v", "vv0.8.14", "v0.8.13-2-g080f1737", "0.8.14+build", " v0.8.14", "V0.8.14", "unknown", "080f1737" }) |raw| {
        const expected = if (std.mem.startsWith(u8, raw, "v")) raw[1..] else raw;
        const actual = gate.engineVersionFromBuildLabel(raw);
        try testing.expectEqualStrings(expected, actual);
        try testing.expect(expected.ptr == actual.ptr);
    }
}

test "capability path rejects malformed CLI selection" {
    for ([_][]const u8{ "", "   ", "\t", "bad\npath", "bad\x00path", "--strict-tenancy" }) |path| {
        const result = cli_args.parseArgsFromSlice(testing.allocator, &.{ "geode", "--require-capability-profile", path });
        if (result) |value| {
            if (value) |v| {
                var config = v;
                config.deinit(testing.allocator);
            }
            return error.ExpectedInvalidCapabilityProfilePath;
        } else |err| try testing.expectEqual(error.InvalidCapabilityProfilePath, err);
    }
}

test "capability argument rejects missing and duplicate values" {
    try testing.expectError(error.MissingArgument, cli_args.parseArgsFromSlice(testing.allocator, &.{ "geode", "--require-capability-profile" }));
    try testing.expectError(error.DuplicateCapabilityProfileArgument, cli_args.parseArgsFromSlice(testing.allocator, &.{ "geode", "--require-capability-profile", "first", "--require-capability-profile", "second" }));
}

test "explicit missing config must refuse rather than disable the gate" {
    const result = cli_args.parseArgsFromSlice(testing.allocator, &.{ "geode", "--config", "./.task2-missing-config.json" });
    if (result) |maybe_config| {
        if (maybe_config) |value| {
            var config = value;
            config.deinit(testing.allocator);
        }
        return error.ExpectedConfigReadFailure;
    } else |err| try testing.expectEqual(error.FileNotFound, err);
}

test "explicit config flag requires a path" {
    const result = cli_args.parseArgsFromSlice(testing.allocator, &.{ "geode", "--config" });
    if (result) |maybe_config| {
        if (maybe_config) |value| {
            var config = value;
            config.deinit(testing.allocator);
        }
        return error.ExpectedMissingConfigPath;
    } else |err| try testing.expectEqual(error.MissingArgument, err);
}

test "explicit capability path cannot be empty" {
    const result = cli_args.parseArgsFromSlice(testing.allocator, &.{ "geode", "--require-capability-profile", "" });
    if (result) |maybe_config| {
        if (maybe_config) |value| {
            var config = value;
            config.deinit(testing.allocator);
        }
        return error.ExpectedInvalidCapabilityProfilePath;
    } else |err| try testing.expectEqual(error.InvalidCapabilityProfilePath, err);
}

extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;

fn parsePath(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var config = (try cli_args.parseArgsFromSlice(allocator, argv)) orelse return error.ExpectedConfig;
    defer config.deinit(allocator);
    try testing.expectEqualStrings("./profile.json", config.require_capability_profile.?);
}

test "CLI path owns its bytes and bounds are inclusive" {
    const source = try testing.allocator.dupe(u8, "./profile.json");
    var config = (try cli_args.parseArgsFromSlice(testing.allocator, &.{ "geode", "--require-capability-profile", source })).?;
    defer config.deinit(testing.allocator);
    @memset(source, 'x');
    testing.allocator.free(source);
    try testing.expectEqualStrings("./profile.json", config.require_capability_profile.?);
    var long: [4097]u8 = @splat('p');
    var exact = (try cli_args.parseArgsFromSlice(testing.allocator, &.{ "geode", "--require-capability-profile", long[0..4096] })).?;
    defer exact.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4096), exact.require_capability_profile.?.len);
    try testing.expectError(error.InvalidCapabilityProfilePath, cli_args.parseArgsFromSlice(testing.allocator, &.{ "geode", "--require-capability-profile", &long }));
}

test "full CLI parse allocation failures remain explicit including dependency failures" {
    try testing.checkAllAllocationFailures(testing.allocator, parsePath, .{@as([]const []const u8, &.{ "geode", "--require-capability-profile", "./profile.json" })});
}

test "file env CLI precedence retains owned path after config arena destruction" {
    const env_name = "GEODE_REQUIRE_CAPABILITY_PROFILE";
    const old = if (std.c.getenv(env_name)) |p| try testing.allocator.dupeZ(u8, std.mem.span(p)) else null;
    defer {
        if (old) |p| {
            _ = setenv(env_name, p, 1);
            testing.allocator.free(p);
        } else _ = unsetenv(env_name);
    }
    _ = unsetenv(env_name);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = "{\"require_capability_profile\":\"./profile.json\"}" });
    const path = try tmp.dir.realPathFileAlloc(io, "config.json", testing.allocator);
    defer testing.allocator.free(path);
    try parsePath(testing.allocator, &.{ "geode", "--config", path });
    try testing.expectEqual(@as(c_int, 0), setenv(env_name, "env-profile", 1));
    var env_config = (try cli_args.parseArgsFromSlice(testing.allocator, &.{ "geode", "--config", path })).?;
    defer env_config.deinit(testing.allocator);
    try testing.expectEqualStrings("env-profile", env_config.require_capability_profile.?);
    try parsePath(testing.allocator, &.{ "geode", "--config", path, "--require-capability-profile", "./profile.json" });
    try testing.expectEqual(@as(c_int, 0), setenv(env_name, "", 1));
    try testing.expectError(error.InvalidCapabilityProfilePath, cli_args.parseArgsFromSlice(testing.allocator, &.{ "geode", "--config", path, "--require-capability-profile", "./profile.json" }));
    _ = unsetenv(env_name);
    for ([_][]const u8{ "null", "false", "123", "[]", "{}", "\"\"", "\"   \"" }) |invalid| {
        const contents = try std.fmt.allocPrint(testing.allocator, "{{\"require_capability_profile\":{s}}}", .{invalid});
        defer testing.allocator.free(contents);
        try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = contents });
        try testing.expectError(error.InvalidCapabilityProfilePath, cli_args.parseArgsFromSlice(testing.allocator, &.{ "geode", "--config", path, "--require-capability-profile", "./profile.json" }));
    }
}

test "full config file parsing allocation failures remain explicit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = "{\"require_capability_profile\":\"./profile.json\"}" });
    const path = try tmp.dir.realPathFileAlloc(io, "config.json", testing.allocator);
    defer testing.allocator.free(path);
    try testing.checkAllAllocationFailures(testing.allocator, parsePath, .{@as([]const []const u8, &.{ "geode", "--config", path })});
    try testing.checkAllAllocationFailures(testing.allocator, parsePath, .{@as([]const []const u8, &.{ "geode", "--config", path, "--require-capability-profile", "./profile.json" })});
}

test "full file env CLI replacement allocation failures remain explicit" {
    const env_name = "GEODE_REQUIRE_CAPABILITY_PROFILE";
    const old = if (std.c.getenv(env_name)) |p| try testing.allocator.dupeZ(u8, std.mem.span(p)) else null;
    defer {
        if (old) |p| {
            _ = setenv(env_name, p, 1);
            testing.allocator.free(p);
        } else _ = unsetenv(env_name);
    }
    try testing.expectEqual(@as(c_int, 0), setenv(env_name, "env-profile", 1));
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    try tmp.dir.writeFile(io, .{ .sub_path = "config.json", .data = "{\"require_capability_profile\":\"./profile.json\"}" });
    const path = try tmp.dir.realPathFileAlloc(io, "config.json", testing.allocator);
    defer testing.allocator.free(path);
    try testing.checkAllAllocationFailures(testing.allocator, parsePath, .{@as([]const []const u8, &.{ "geode", "--config", path, "--require-capability-profile", "./profile.json" })});
}
