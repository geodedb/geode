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
const execution = @import("../execution.zig");

// Type aliases
const ExecutionResult = execution.ExecutionResult;

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
        else => {}, // Other types don't own memory or are shallow copies
    }
}

/// P2-3: Now accepts allocator parameter for temporary allocations
pub fn writeValue(allocator: std.mem.Allocator, writer: anytype, value: Value) !void {
    switch (value) {
        .Null => try writer.writeAll("null"),
        .Int => |n| try writer.print("{d}", .{n}),
        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .Str => |s| {
            try writer.writeByte('"');
            // Unescape GQL doubled single quotes ('') to single quotes (')
            // and escape JSON special characters
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
                        // JSON requires escaping double quotes
                        try writer.writeAll("\\\"");
                        i += 1;
                    },
                    '\\' => {
                        // JSON requires escaping backslashes
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
                    else => {
                        try writer.writeByte(c);
                        i += 1;
                    },
                }
            }
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
                            // Field-Level Encryption: decrypt if configured
                            const type_name = if (node.labels.len > 0) node.labels[0] else "Unknown";
                            const user_role = fle_integration.getCurrentUserRole();
                            // P2-3: Use provided allocator instead of page_allocator
                            const fle_ctx = fle_integration.EncryptionContext{
                                .tenant_id = "default",
                                .schema_name = type_name, // Use actual node type
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
                                true, // Check RBAC
                            ) catch |err| blk_decrypt: {
                                // For SearchNotPermitted, return redacted placeholder
                                if (err == fle_integration.fle_aead_mod.Error.SearchNotPermitted) {
                                    break :blk_decrypt "[REDACTED]";
                                }
                                // Fall back to ciphertext on other errors (e.g., AEADAuthFailed)
                                break :blk_decrypt s;
                            };

                            try writer.writeByte('"');
                            try writer.writeAll(decrypted);
                            try writer.writeByte('"');
                        },
                        .Int => |i| try writer.print("{d}", .{i}),
                        .Float => |f| try writer.print("{d}", .{f}),
                        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
                        .Null => try writer.writeAll("null"),
                        .ExtValue => try writer.writeAll("\"<ExtValue>\""), // Placeholder for ExtValue serialization
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
                            // Field-Level Encryption: decrypt if configured
                            const type_name = edge.label;
                            // P2-3: Use provided allocator instead of page_allocator
                            const fle_ctx = fle_integration.EncryptionContext{
                                .tenant_id = "default",
                                .schema_name = type_name, // Use actual edge type
                                .allocator = allocator,
                                .current_user_role = fle_integration.getCurrentUserRole(),
                            };
                            const record_id_buf = try std.fmt.allocPrint(allocator, "edge_{d}", .{edge.id});
                            defer allocator.free(record_id_buf);

                            const decrypted = fle_integration.decryptFieldIfNeeded(
                                fle_ctx,
                                type_name,
                                entry.key_ptr.*,
                                s,
                                record_id_buf,
                                true, // Check RBAC
                            ) catch |err| blk_decrypt: {
                                // For SearchNotPermitted, return redacted placeholder
                                if (err == fle_integration.fle_aead_mod.Error.SearchNotPermitted) {
                                    break :blk_decrypt "[REDACTED]";
                                }
                                // Fall back to ciphertext on other errors (e.g., AEADAuthFailed)
                                break :blk_decrypt s;
                            };

                            try writer.writeByte('"');
                            try writer.writeAll(decrypted);
                            try writer.writeByte('"');
                        },
                        .Int => |i| try writer.print("{d}", .{i}),
                        .Float => |f| try writer.print("{d}", .{f}),
                        .Bool => |b| try writer.writeAll(if (b) "true" else "false"),
                        .Null => try writer.writeAll("null"),
                        .ExtValue => try writer.writeAll("\"<ExtValue>\""), // Placeholder for ExtValue serialization
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
                    try writer.writeAll(s);
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
    }
}
