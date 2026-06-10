//! Value Utilities Module (M1 Phase 12)
//! CANARY: REQ-EXEC-REFACTOR-012 - Value manipulation and serialization utilities
//!
//! This module contains utility functions for working with Values and ExecutionResults:
//! - Value duplication and memory management
//! - JSON serialization with FLE support
//! - Result set duplication

const std = @import("std");
const eval = @import("../eval.zig");
const graph_store = @import("../graph_store.zig");
const fle_integration = @import("../fle_integration.zig");
const property_codec = @import("../property_value_codec.zig");
const execution = @import("../execution.zig");
const value_types = @import("../value_types.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-019; FEATURE="JSON Library Migration"; ASPECT=ValueUtilities; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-24
const json_lib = @import("json");

// Type aliases
const ExecutionResult = execution.ExecutionResult;
const Value = value_types.Value;

/// GAP-0844 (secondary): resolve the current FLE role, preferring the active
/// ExecutionContext's request-scoped `fle_role` over the per-thread map (falls
/// back to the per-thread map when no context is active — unchanged behavior).
fn currentUserRolePreferringContext() ?[]const u8 {
    if (execution.getActiveContext()) |ctx_ptr| {
        return fle_integration.getCurrentUserRoleCtx(ctx_ptr);
    }
    return fle_integration.getCurrentUserRole();
}

/// GAP-0852: resolve the current FLE tenant, preferring the active
/// ExecutionContext's request-scoped `tenant_id` over the per-thread map (falls
/// back to the per-thread map / its documented "default" only for genuinely
/// contextless callers). Keeps decrypt-on-projection tenant-correct under a
/// future async / work-stealing executor.
fn currentTenantIdPreferringContext() []const u8 {
    if (execution.getActiveContext()) |ctx_ptr| {
        return fle_integration.getCurrentTenantIdCtx(ctx_ptr);
    }
    return fle_integration.getCurrentTenantId();
}

/// Write a string with proper RFC 8259 JSON escaping
/// Handles GQL doubled single quotes ('') -> single quote (')
/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-020; FEATURE="JSON Library Migration"; ASPECT=StringEscaping; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-24
fn writeJsonEscapedString(writer: anytype, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '\'' => {
                // Check for doubled single quote (GQL escape)
                if (i + 1 < s.len and s[i + 1] == '\'') {
                    // Skip the second quote - output only one
                    try writer.writeByte('\'');
                    i += 2;
                } else {
                    // Single quote not doubled
                    try writer.writeByte('\'');
                    i += 1;
                }
            },
            '"' => {
                try writer.writeAll("\\\"");
                i += 1;
            },
            '\\' => {
                try writer.writeAll("\\\\");
                i += 1;
            },
            '\n' => {
                try writer.writeAll("\\n");
                i += 1;
            },
            '\r' => {
                try writer.writeAll("\\r");
                i += 1;
            },
            '\t' => {
                try writer.writeAll("\\t");
                i += 1;
            },
            0x08 => { // backspace
                try writer.writeAll("\\b");
                i += 1;
            },
            0x0C => { // form feed
                try writer.writeAll("\\f");
                i += 1;
            },
            else => {
                if (c < 0x20) {
                    // Control characters: escape as \u00XX
                    try writer.print("\\u{X:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
                i += 1;
            },
        }
    }
}

/// Duplicate an ExecutionResult, allocating new memory for all fields
pub fn duplicateResult(allocator: std.mem.Allocator, original: ExecutionResult) !ExecutionResult {
    // Duplicate columns
    const columns = try allocator.alloc([]const u8, original.columns.len);
    for (original.columns, 0..) |col, i| {
        columns[i] = try allocator.dupe(u8, col);
    }

    // Duplicate rows
    const rows = try allocator.alloc([]Value, original.rows.len);
    for (original.rows, 0..) |row, i| {
        const new_row = try allocator.alloc(Value, row.len);
        for (row, 0..) |val, j| {
            new_row[j] = try duplicateValue(allocator, val);
        }
        rows[i] = new_row;
    }

    // Duplicate flags
    var flags = try std.ArrayList([]const u8).initCapacity(allocator, original.flags.items.len);
    for (original.flags.items) |flag| {
        try flags.append(allocator, try allocator.dupe(u8, flag));
    }

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = flags,
        .owns_value_memory = true, // Duplicated result owns its value memory
    };
}

/// Helper function to duplicate a Value
pub fn duplicateValue(allocator: std.mem.Allocator, value: Value) !Value {
    return switch (value) {
        .Null, .Int, .Bool, .Decimal => value, // These are copy-by-value
        .Str => |s| .{ .Str = try allocator.dupe(u8, s) },
        .List => |list| blk: {
            const new_list = try allocator.alloc(Value, list.len);
            for (list, 0..) |item, i| {
                new_list[i] = try duplicateValue(allocator, item);
            }
            break :blk .{ .List = new_list };
        },
        .Map => |map_const| blk: {
            var map = map_const;
            var new_map = std.StringHashMap(Value).init(allocator);
            var it = map.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try duplicateValue(allocator, entry.value_ptr.*);
                try new_map.put(key, val);
            }
            break :blk .{ .Map = new_map };
        },
        .Node, .Edge, .Path => value, // These contain pointers but we'll shallow copy for now
        else => value, // Fallback for any other types
    };
}

/// Helper function to free a Value's allocated memory
pub fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .Str => |s| allocator.free(s),
        .List => |list| {
            for (list) |item| {
                freeValue(allocator, item);
            }
            allocator.free(list);
        },
        .Map => |map_const| {
            var map = map_const;
            var it = map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeValue(allocator, entry.value_ptr.*);
            }
            map.deinit();
        },
        else => {}, // Other types don't own memory or are shallow copies
    }
}

/// P2-3: Now accepts allocator parameter for temporary allocations
/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-021; FEATURE="JSON Library Migration"; ASPECT=WriteValue; STATUS=TESTED; OWNER=execution; UPDATED=2026-01-24
pub fn writeValue(allocator: std.mem.Allocator, writer: anytype, value: Value) !void {
    switch (value) {
        .Null => try writer.writeAll("null"),
        .Int => |n| try writer.print("{d}", .{n}),
        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .Str => |s| {
            try writer.writeByte('"');
            // Use RFC 8259 compliant JSON string escaping with GQL quote handling
            try writeJsonEscapedString(writer, s);
            try writer.writeByte('"');
        },
        .Decimal => |d| {
            // Format decimal with proper scale
            if (d.scale == 0) {
                try writer.print("{d}", .{d.coeff});
            } else {
                const divisor = std.math.pow(i64, 10, d.scale);
                const whole = @divTrunc(d.coeff, divisor);
                const frac = @rem(d.coeff, divisor);
                if (frac == 0) {
                    try writer.print("{d}", .{whole});
                } else {
                    // Format with decimal point
                    const f: f64 = @as(f64, @floatFromInt(d.coeff)) / @as(f64, @floatFromInt(divisor));
                    try writer.print("{d}", .{f});
                }
            }
        },
        .List => |list| {
            try writer.writeByte('[');
            for (list, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeValue(allocator, writer, item);
            }
            try writer.writeByte(']');
        },
        .Node => |node| {
            // For now, output node as a JSON object with its properties
            try writer.writeAll("{");
            try writer.print("\"id\":{d}", .{node.id});
            if (node.labels.len > 0) {
                try writer.writeAll(",\"labels\":[");
                for (node.labels, 0..) |label, i| {
                    if (i > 0) try writer.writeAll(",");
                    try writer.writeByte('"');
                    try writer.writeAll(label);
                    try writer.writeByte('"');
                }
                try writer.writeAll("]");
            }
            // Add properties if any
            if (node.properties.count() > 0) {
                try writer.writeAll(",\"properties\":{");
                var iter = node.properties.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.writeByte('"');
                    try writer.writeAll(entry.key_ptr.*);
                    try writer.writeAll("\":");
                    switch (entry.value_ptr.*) {
                        .String => |s| {
                            // GAP-0203: Skip FLE entirely when no encrypted fields configured
                            // CANARY: REQ=REQ-PERF-FLE-SKIP-003; FEATURE="FLESkipOptimization"; ASPECT=NodePropertyWrite; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
                            if (fle_integration.hasEncryptedFields()) {
                                // Field-Level Encryption: decrypt if configured
                                const type_name = if (node.labels.len > 0) node.labels[0] else "Unknown";
                                const user_role = currentUserRolePreferringContext();
                                const fle_ctx = fle_integration.EncryptionContext{
                                    .tenant_id = currentTenantIdPreferringContext(),
                                    .schema_name = type_name,
                                    .allocator = allocator,
                                    .current_user_role = user_role,
                                };
                                const record_id_buf = try std.fmt.allocPrint(allocator, "{d}", .{node.id});
                                defer allocator.free(record_id_buf);

                                const decrypted = fle_integration.decryptFieldIfNeeded(
                                    fle_ctx,
                                    type_name,
                                    entry.key_ptr.*,
                                    s,
                                    record_id_buf,
                                    true,
                                ) catch |err| blk_decrypt: {
                                    if (err == fle_integration.fle_aead_mod.Error.SearchNotPermitted) {
                                        break :blk_decrypt "[REDACTED]";
                                    }
                                    break :blk_decrypt s;
                                };

                                try writer.writeByte('"');
                                try writer.writeAll(decrypted);
                                try writer.writeByte('"');
                            } else {
                                // Fast path: no FLE configured, write string directly
                                try writer.writeByte('"');
                                try writeJsonEscapedString(writer, s);
                                try writer.writeByte('"');
                            }
                        },
                        .Int => |i| try writer.print("{d}", .{i}),
                        .Float => |f| try writer.print("{d}", .{f}),
                        .Decimal => |d| {
                            // Format decimal with exact precision
                            if (d.scale == 0) {
                                try writer.print("{d}", .{d.coeff});
                            } else {
                                var divisor: i128 = 1;
                                var sc = d.scale;
                                while (sc > 0) : (sc -= 1) {
                                    divisor *= 10;
                                }
                                const int_part = @divTrunc(d.coeff, divisor);
                                const frac_part_signed = @rem(d.coeff, divisor);
                                const frac_part = if (frac_part_signed < 0) -frac_part_signed else frac_part_signed;
                                // Format with leading zeros for fractional part
                                var frac_buf: [32]u8 = undefined;
                                const frac_str = std.fmt.bufPrint(&frac_buf, "{d}", .{frac_part}) catch "0";
                                try writer.print("{d}.", .{int_part});
                                // Add leading zeros
                                const zeros_needed: usize = if (d.scale > frac_str.len) d.scale - @as(u8, @intCast(frac_str.len)) else 0;
                                var z: usize = 0;
                                while (z < zeros_needed) : (z += 1) {
                                    try writer.writeByte('0');
                                }
                                try writer.writeAll(frac_str);
                            }
                        },
                        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
                        .Null => try writer.writeAll("null"),
                        .ExtValue => {
                            const projected = try property_codec.propertyValueToProjectedValue(allocator, entry.value_ptr.*);
                            defer property_codec.freeValue(allocator, projected);
                            try writeValue(allocator, writer, projected);
                        },
                    }
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("}");
        },
        .Edge => |edge| {
            // Output edge as a JSON object with its properties
            try writer.writeAll("{");
            try writer.print("\"id\":{d},\"from\":{d},\"to\":{d},\"type\":\"{s}\"", .{ edge.id, edge.from_id, edge.to_id, edge.label });
            // Add properties if any
            if (edge.properties.count() > 0) {
                try writer.writeAll(",\"properties\":{");
                var iter = edge.properties.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (!first) try writer.writeAll(",");
                    first = false;
                    try writer.writeByte('"');
                    try writer.writeAll(entry.key_ptr.*);
                    try writer.writeAll("\":");
                    const prop_value = entry.value_ptr.*;
                    switch (prop_value) {
                        .String => |s| {
                            // GAP-0203: Skip FLE entirely when no encrypted fields configured
                            // CANARY: REQ=REQ-PERF-FLE-SKIP-004; FEATURE="FLESkipOptimization"; ASPECT=EdgePropertyWrite; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
                            if (fle_integration.hasEncryptedFields()) {
                                const type_name = edge.label;
                                const fle_ctx = fle_integration.EncryptionContext{
                                    .tenant_id = currentTenantIdPreferringContext(),
                                    .schema_name = type_name,
                                    .allocator = allocator,
                                    .current_user_role = currentUserRolePreferringContext(),
                                };
                                const record_id_buf = try std.fmt.allocPrint(allocator, "edge_{d}", .{edge.id});
                                defer allocator.free(record_id_buf);

                                const decrypted = fle_integration.decryptFieldIfNeeded(
                                    fle_ctx,
                                    type_name,
                                    entry.key_ptr.*,
                                    s,
                                    record_id_buf,
                                    true,
                                ) catch |err| blk_decrypt: {
                                    if (err == fle_integration.fle_aead_mod.Error.SearchNotPermitted) {
                                        break :blk_decrypt "[REDACTED]";
                                    }
                                    break :blk_decrypt s;
                                };

                                try writer.writeByte('"');
                                try writer.writeAll(decrypted);
                                try writer.writeByte('"');
                            } else {
                                // Fast path: no FLE configured, write string directly
                                try writer.writeByte('"');
                                try writeJsonEscapedString(writer, s);
                                try writer.writeByte('"');
                            }
                        },
                        .Int => |i| try writer.print("{d}", .{i}),
                        .Float => |f| try writer.print("{d}", .{f}),
                        .Decimal => |d| {
                            // Format decimal with exact precision
                            if (d.scale == 0) {
                                try writer.print("{d}", .{d.coeff});
                            } else {
                                var divisor: i128 = 1;
                                var sc = d.scale;
                                while (sc > 0) : (sc -= 1) {
                                    divisor *= 10;
                                }
                                const int_part = @divTrunc(d.coeff, divisor);
                                const frac_part_signed = @rem(d.coeff, divisor);
                                const frac_part = if (frac_part_signed < 0) -frac_part_signed else frac_part_signed;
                                // Format with leading zeros for fractional part
                                var frac_buf: [32]u8 = undefined;
                                const frac_str = std.fmt.bufPrint(&frac_buf, "{d}", .{frac_part}) catch "0";
                                try writer.print("{d}.", .{int_part});
                                // Add leading zeros
                                const zeros_needed: usize = if (d.scale > frac_str.len) d.scale - @as(u8, @intCast(frac_str.len)) else 0;
                                var z: usize = 0;
                                while (z < zeros_needed) : (z += 1) {
                                    try writer.writeByte('0');
                                }
                                try writer.writeAll(frac_str);
                            }
                        },
                        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
                        .Null => try writer.writeAll("null"),
                        .ExtValue => {
                            const projected = try property_codec.propertyValueToProjectedValue(allocator, prop_value);
                            defer property_codec.freeValue(allocator, projected);
                            try writeValue(allocator, writer, projected);
                        },
                    }
                }
                try writer.writeAll("}");
            }
            try writer.writeAll("}");
        },
        .Map => |map| {
            try writer.writeByte('{');
            var iter = map.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try writer.writeAll(",");
                first = false;
                try writer.writeByte('"');
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll("\":");
                try writeValue(allocator, writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        .ExtValue => |ext| {
            // Convert extended types to JSON strings
            switch (ext) {
                .Null => try writer.writeAll("null"),
                .Int => |n| try writer.print("{d}", .{n}),
                .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
                .Str => |s| {
                    try writer.writeByte('"');
                    try writeJsonEscapedString(writer, s);
                    try writer.writeByte('"');
                },
                .Decimal => |d| {
                    // Format decimal with proper scale
                    if (d.scale == 0) {
                        try writer.print("{d}", .{d.coeff});
                    } else {
                        const divisor = std.math.pow(i64, 10, d.scale);
                        const f: f64 = @as(f64, @floatFromInt(d.coeff)) / @as(f64, @floatFromInt(divisor));
                        try writer.print("{d}", .{f});
                    }
                },
                .VectorF32 => {
                    try writer.writeAll("\"[vector]\"");
                },
                .IpAddr => |ip| {
                    try writer.writeByte('"');
                    switch (ip) {
                        .v4 => |octets| try writer.print("{d}.{d}.{d}.{d}", .{ octets[0], octets[1], octets[2], octets[3] }),
                        .v6 => |bytes| {
                            var segments: [8]u16 = undefined;
                            for (0..8) |i| {
                                segments[i] = (@as(u16, bytes[i * 2]) << 8) | @as(u16, bytes[i * 2 + 1]);
                            }
                            try writer.print("{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{ segments[0], segments[1], segments[2], segments[3], segments[4], segments[5], segments[6], segments[7] });
                        },
                    }
                    try writer.writeByte('"');
                },
                .Subnet => |subnet| {
                    try writer.writeByte('"');
                    switch (subnet.addr) {
                        .v4 => |octets| try writer.print("{d}.{d}.{d}.{d}/{d}", .{ octets[0], octets[1], octets[2], octets[3], subnet.prefix_len }),
                        .v6 => |bytes| {
                            var segments: [8]u16 = undefined;
                            for (0..8) |i| {
                                segments[i] = (@as(u16, bytes[i * 2]) << 8) | @as(u16, bytes[i * 2 + 1]);
                            }
                            try writer.print("{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}/{d}", .{ segments[0], segments[1], segments[2], segments[3], segments[4], segments[5], segments[6], segments[7], subnet.prefix_len });
                        },
                    }
                    try writer.writeByte('"');
                },
                .Mac => |mac| {
                    try writer.print("\"{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}\"", .{ mac.bytes[0], mac.bytes[1], mac.bytes[2], mac.bytes[3], mac.bytes[4], mac.bytes[5] });
                },
                .Hash => |hash| {
                    try writer.print("\"[hash:{s}]\"", .{@tagName(hash.alg)});
                },
                .LatLon => |latlon| {
                    try writer.print("\"({d:.6},{d:.6})\"", .{ latlon.lat, latlon.lon });
                },
                .LatLonAlt => |latlonalt| {
                    try writer.print("\"({d:.6},{d:.6},{d:.2}m)\"", .{ latlonalt.lat, latlonalt.lon, latlonalt.alt });
                },
                .Date => |date| {
                    // Format date as YYYY-MM-DD using civil calendar algorithm
                    // Convert days since Unix epoch (1970-01-01) to Gregorian Y-M-D

                    // Shift from Unix epoch to use algorithm starting from 0000-03-01
                    const z: i64 = @as(i64, date.days_since_epoch) + 719468; // Days from 0000-03-01 to 1970-01-01
                    const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
                    const doe: u32 = @intCast(z - era * 146097); // Day of era [0, 146096]
                    const yoe: u32 = @intCast(@divFloor(doe - doe / 1460 + doe / 36524 - doe / 146096, 365)); // Year of era [0, 399]
                    const y_tmp: i64 = @as(i64, yoe) + era * 400;
                    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100); // Day of year [0, 365]
                    const mp: u32 = @intCast(@divFloor(5 * doy + 2, 153)); // Month' [0, 11]
                    const d: u32 = doy - @divFloor(153 * mp + 2, 5) + 1; // Day [1, 31]
                    const m: u32 = if (mp < 10) mp + 3 else mp - 9; // Month [1, 12]
                    const y: i64 = y_tmp + @as(i64, if (m <= 2) @as(u32, 1) else @as(u32, 0));

                    try writer.print("\"{:0>4}-{:0>2}-{:0>2}\"", .{ @abs(y), m, d });
                },
                .Time => |time| {
                    // Format time as HH:MM:SS.ffffff
                    const micros = time.micros_since_midnight;
                    const hours: u32 = @intCast(@divFloor(micros, 3600 * 1_000_000));
                    const remaining_after_hours = micros - @as(i64, hours) * 3600 * 1_000_000;
                    const minutes: u32 = @intCast(@divFloor(remaining_after_hours, 60 * 1_000_000));
                    const remaining_after_mins = remaining_after_hours - @as(i64, minutes) * 60 * 1_000_000;
                    const seconds: u32 = @intCast(@divFloor(remaining_after_mins, 1_000_000));
                    const microseconds: u32 = @intCast(remaining_after_mins - @as(i64, seconds) * 1_000_000);

                    try writer.print("\"{:0>2}:{:0>2}:{:0>2}.{:0>6}\"", .{ hours, minutes, seconds, microseconds });
                },
                .TimestampTZ => |ts| {
                    // Format timestamp as ISO8601: YYYY-MM-DDTHH:MM:SS.ffffffZ
                    const micros = ts.micros_since_epoch_utc;
                    const seconds_since_epoch = @divFloor(micros, 1_000_000);
                    const days_since_epoch: i64 = @divFloor(seconds_since_epoch, 86400);

                    // Calculate time of day, handling negative timestamps correctly
                    var time_of_day_micros = @mod(micros, 86400 * 1_000_000);
                    if (time_of_day_micros < 0) {
                        time_of_day_micros += 86400 * 1_000_000;
                    }

                    // Date part using civil calendar algorithm
                    const z: i64 = days_since_epoch + 719468; // Days from 0000-03-01 to 1970-01-01
                    const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
                    const doe: u32 = @intCast(z - era * 146097); // Day of era [0, 146096]
                    const yoe: u32 = @intCast(@divFloor(doe - doe / 1460 + doe / 36524 - doe / 146096, 365)); // Year of era [0, 399]
                    const y_tmp: i64 = @as(i64, yoe) + era * 400;
                    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100); // Day of year [0, 365]
                    const mp: u32 = @intCast(@divFloor(5 * doy + 2, 153)); // Month' [0, 11]
                    const d: u32 = doy - @divFloor(153 * mp + 2, 5) + 1; // Day [1, 31]
                    const m: u32 = if (mp < 10) mp + 3 else mp - 9; // Month [1, 12]
                    const y: i64 = y_tmp + @as(i64, if (m <= 2) @as(u32, 1) else @as(u32, 0));

                    // Time part
                    const hours: u32 = @intCast(@divFloor(time_of_day_micros, 3600 * 1_000_000));
                    const rem_after_hours = time_of_day_micros - @as(i64, hours) * 3600 * 1_000_000;
                    const minutes: u32 = @intCast(@divFloor(rem_after_hours, 60 * 1_000_000));
                    const rem_after_mins = rem_after_hours - @as(i64, minutes) * 60 * 1_000_000;
                    const secs: u32 = @intCast(@divFloor(rem_after_mins, 1_000_000));
                    const microseconds: u32 = @intCast(rem_after_mins - @as(i64, secs) * 1_000_000);

                    try writer.print("\"{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>6}Z\"", .{ @abs(y), m, d, hours, minutes, secs, microseconds });
                },
                else => try writer.writeAll("\"[advanced_type]\""),
            }
        },
        .Path => |path| {
            // Output path as JSON object with nodes and edges
            try writer.writeAll("{\"nodes\":[");
            for (path.nodes, 0..) |node, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{d}", .{node.id});
            }
            try writer.writeAll("],\"edges\":[");
            for (path.edges, 0..) |edge, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{d}", .{edge.id});
            }
            try writer.writeAll("]}");
        },
        // Advanced numeric types
        .SmallInt => |n| try writer.print("{d}", .{n}),
        .BigInt => |n| try writer.print("{d}", .{n}),
        .Real => |f| try writer.print("{d}", .{f}),
        .Double => |f| try writer.print("{d}", .{f}),
        // String types
        .Char => |c| {
            try writer.writeByte('"');
            try writer.writeAll(c.data);
            try writer.writeByte('"');
        },
        .Varchar => |v| {
            try writer.writeByte('"');
            try writer.writeAll(v.data);
            try writer.writeByte('"');
        },
        .Text => |t| {
            try writer.writeByte('"');
            try writer.writeAll(t);
            try writer.writeByte('"');
        },
        // Date/time types
        .Date => |date| {
            // Format date as YYYY-MM-DD
            const z: i64 = @as(i64, date.days_since_epoch) + 719468;
            const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
            const doe: u32 = @intCast(z - era * 146097);
            const yoe: u32 = @intCast(@divFloor(doe - doe / 1460 + doe / 36524 - doe / 146096, 365));
            const y_tmp: i64 = @as(i64, yoe) + era * 400;
            const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
            const mp: u32 = @intCast(@divFloor(5 * doy + 2, 153));
            const d: u32 = doy - @divFloor(153 * mp + 2, 5) + 1;
            const m: u32 = if (mp < 10) mp + 3 else mp - 9;
            const y: i64 = y_tmp + @as(i64, if (m <= 2) @as(u32, 1) else @as(u32, 0));
            try writer.print("\"{:0>4}-{:0>2}-{:0>2}\"", .{ @abs(y), m, d });
        },
        .Time => |time| {
            const micros = time.micros_since_midnight;
            const hours: u32 = @intCast(@divFloor(micros, 3600 * 1_000_000));
            const remaining_after_hours = micros - @as(i64, hours) * 3600 * 1_000_000;
            const minutes: u32 = @intCast(@divFloor(remaining_after_hours, 60 * 1_000_000));
            const remaining_after_mins = remaining_after_hours - @as(i64, minutes) * 60 * 1_000_000;
            const seconds: u32 = @intCast(@divFloor(remaining_after_mins, 1_000_000));
            const microseconds: u32 = @intCast(remaining_after_mins - @as(i64, seconds) * 1_000_000);
            try writer.print("\"{:0>2}:{:0>2}:{:0>2}.{:0>6}\"", .{ hours, minutes, seconds, microseconds });
        },
        .TimeTZ => |t| {
            const micros = t.time.micros_since_midnight;
            const hours: u32 = @intCast(@divFloor(micros, 3600 * 1_000_000));
            const remaining_after_hours = micros - @as(i64, hours) * 3600 * 1_000_000;
            const minutes: u32 = @intCast(@divFloor(remaining_after_hours, 60 * 1_000_000));
            const remaining_after_mins = remaining_after_hours - @as(i64, minutes) * 60 * 1_000_000;
            const seconds: u32 = @intCast(@divFloor(remaining_after_mins, 1_000_000));
            // offset_seconds is in seconds, convert to hours:minutes
            const offset_hours = @divTrunc(@abs(t.offset_seconds), 3600);
            const offset_mins = @divTrunc(@rem(@abs(t.offset_seconds), 3600), 60);
            if (t.offset_seconds >= 0) {
                try writer.print("\"{:0>2}:{:0>2}:{:0>2}+{:0>2}:{:0>2}\"", .{ hours, minutes, seconds, offset_hours, offset_mins });
            } else {
                try writer.print("\"{:0>2}:{:0>2}:{:0>2}-{:0>2}:{:0>2}\"", .{ hours, minutes, seconds, offset_hours, offset_mins });
            }
        },
        .Timestamp => |ts| {
            const micros = ts.micros_since_epoch;
            const seconds_since_epoch = @divFloor(micros, 1_000_000);
            const days_since_epoch: i64 = @divFloor(seconds_since_epoch, 86400);
            var time_of_day_micros = @mod(micros, 86400 * 1_000_000);
            if (time_of_day_micros < 0) time_of_day_micros += 86400 * 1_000_000;
            const z: i64 = days_since_epoch + 719468;
            const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
            const doe: u32 = @intCast(z - era * 146097);
            const yoe: u32 = @intCast(@divFloor(doe - doe / 1460 + doe / 36524 - doe / 146096, 365));
            const y_tmp: i64 = @as(i64, yoe) + era * 400;
            const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
            const mp: u32 = @intCast(@divFloor(5 * doy + 2, 153));
            const day: u32 = doy - @divFloor(153 * mp + 2, 5) + 1;
            const month: u32 = if (mp < 10) mp + 3 else mp - 9;
            const year: i64 = y_tmp + @as(i64, if (month <= 2) @as(u32, 1) else @as(u32, 0));
            const hours: u32 = @intCast(@divFloor(time_of_day_micros, 3600 * 1_000_000));
            const rem_after_hours = time_of_day_micros - @as(i64, hours) * 3600 * 1_000_000;
            const mins: u32 = @intCast(@divFloor(rem_after_hours, 60 * 1_000_000));
            const rem_after_mins = rem_after_hours - @as(i64, mins) * 60 * 1_000_000;
            const secs: u32 = @intCast(@divFloor(rem_after_mins, 1_000_000));
            const microseconds: u32 = @intCast(rem_after_mins - @as(i64, secs) * 1_000_000);
            try writer.print("\"{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>6}\"", .{ @abs(year), month, day, hours, mins, secs, microseconds });
        },
        .TimestampTZ => |ts| {
            const micros = ts.micros_since_epoch_utc;
            const seconds_since_epoch = @divFloor(micros, 1_000_000);
            const days_since_epoch: i64 = @divFloor(seconds_since_epoch, 86400);
            var time_of_day_micros = @mod(micros, 86400 * 1_000_000);
            if (time_of_day_micros < 0) time_of_day_micros += 86400 * 1_000_000;
            const z: i64 = days_since_epoch + 719468;
            const era: i64 = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
            const doe: u32 = @intCast(z - era * 146097);
            const yoe: u32 = @intCast(@divFloor(doe - doe / 1460 + doe / 36524 - doe / 146096, 365));
            const y_tmp: i64 = @as(i64, yoe) + era * 400;
            const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
            const mp: u32 = @intCast(@divFloor(5 * doy + 2, 153));
            const day: u32 = doy - @divFloor(153 * mp + 2, 5) + 1;
            const month: u32 = if (mp < 10) mp + 3 else mp - 9;
            const year: i64 = y_tmp + @as(i64, if (month <= 2) @as(u32, 1) else @as(u32, 0));
            const hours: u32 = @intCast(@divFloor(time_of_day_micros, 3600 * 1_000_000));
            const rem_after_hours = time_of_day_micros - @as(i64, hours) * 3600 * 1_000_000;
            const mins: u32 = @intCast(@divFloor(rem_after_hours, 60 * 1_000_000));
            const rem_after_mins = rem_after_hours - @as(i64, mins) * 60 * 1_000_000;
            const secs: u32 = @intCast(@divFloor(rem_after_mins, 1_000_000));
            const microseconds: u32 = @intCast(rem_after_mins - @as(i64, secs) * 1_000_000);
            try writer.print("\"{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>6}Z\"", .{ @abs(year), month, day, hours, mins, secs, microseconds });
        },
        .Interval => |i| {
            try writer.print("\"P{d}M{d}DT{d}S\"", .{ i.months, i.days, @divFloor(i.micros, 1_000_000) });
        },
        // Binary and document types
        .Bytea => |b| {
            try writer.writeAll("\"\\\\x");
            for (b) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.writeByte('"');
        },
        .Json => |j| {
            // JSON is already valid JSON, write directly
            try writer.writeAll(j);
        },
        .Jsonb => |j| {
            try writer.writeAll(j.data);
        },
        .Xml => |x| {
            try writer.writeByte('"');
            try writer.writeAll(x.data);
            try writer.writeByte('"');
        },
        // Network and identifier types
        .Url => |u| {
            try writer.writeByte('"');
            try writer.writeAll(u.scheme);
            try writer.writeAll("://");
            try writer.writeAll(u.host);
            if (u.port) |port| {
                try writer.print(":{d}", .{port});
            }
            try writer.writeAll(u.path);
            if (u.query) |query| {
                try writer.writeByte('?');
                try writer.writeAll(query);
            }
            if (u.fragment) |fragment| {
                try writer.writeByte('#');
                try writer.writeAll(fragment);
            }
            try writer.writeByte('"');
        },
        .Domain => |d| {
            try writer.writeByte('"');
            for (d.labels, 0..) |label, i| {
                if (i > 0) try writer.writeByte('.');
                try writer.writeAll(label);
            }
            try writer.writeByte('"');
        },
        .UUID => |u| {
            try writer.print("\"{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}\"", .{
                std.mem.readInt(u32, u.bytes[0..4], .big),
                std.mem.readInt(u16, u.bytes[4..6], .big),
                std.mem.readInt(u16, u.bytes[6..8], .big),
                std.mem.readInt(u16, u.bytes[8..10], .big),
                std.mem.readInt(u48, u.bytes[10..16], .big),
            });
        },
        // Other types
        .Enum => |e| {
            try writer.print("\"enum({d}:{d})\"", .{ e.type_id, e.value_ordinal });
        },
        .BitString => |b| {
            try writer.writeAll("\"B'");
            for (0..b.bit_length) |i| {
                const byte_idx = i / 8;
                const bit_idx: u3 = @intCast(7 - (i % 8));
                const bit = (b.bytes[byte_idx] >> bit_idx) & 1;
                try writer.writeByte(if (bit == 1) '1' else '0');
            }
            try writer.writeAll("'\"");
        },
        .VarBit => |b| {
            try writer.writeAll("\"B'");
            for (0..b.bit_length) |i| {
                const byte_idx = i / 8;
                const bit_idx: u3 = @intCast(7 - (i % 8));
                const bit = (b.bytes[byte_idx] >> bit_idx) & 1;
                try writer.writeByte(if (bit == 1) '1' else '0');
            }
            try writer.writeAll("'\"");
        },
        .IntRange => |r| {
            // Output range with proper bounds notation
            const bounds_str = r.bounds.toString();
            const lower_str = if (r.lower) |l| l else null;
            const upper_str = if (r.upper) |u| u else null;
            try writer.writeByte('"');
            try writer.writeByte(bounds_str[0]);
            if (lower_str) |l| {
                try writer.print("{d}", .{l});
            }
            try writer.writeByte(',');
            if (upper_str) |u| {
                try writer.print("{d}", .{u});
            }
            try writer.writeByte(bounds_str[1]);
            try writer.writeByte('"');
        },
    }
}
