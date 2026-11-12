// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6383 item 7: a standalone CALL's RETURN dropped the procedure
// result's flags: `projectCallReturn` (execution.zig) built the projection
// and freed the procedure's result, flags and all. No procedure in the tree
// emits a flag today, so the projection is driven directly with a result
// that carries one.
//
// CANARY: REQ=REQ-SONNY-6383-CALL-RETURN-FLAGS; FEATURE="ProcedureYield"; ASPECT=FlagsKept; STATUS=TESTED; TEST=tests/test_sonny6383_call_return_flags.zig; OWNER=engine; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const Value = geode.value_types.Value;

test "SONNY-6383 item 7: a CALL's RETURN keeps the procedure result's flags" {
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parsed = try geode.parseGqlOptions("CALL db.labels() YIELD label AS l RETURN l", arena.allocator(), .{});
    defer parsed.deinit();
    const proc = parsed.program.statements[0].Call.Procedure;

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "label");
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = try allocator.alloc(Value, 1);
    rows[0][0] = .{ .Str = try allocator.dupe(u8, "Q") };
    var flags: std.ArrayList([]const u8) = .empty;
    try flags.append(allocator, try allocator.dupe(u8, "W:ProcedureWarning"));
    var result = execution.ExecutionResult{ .columns = columns, .rows = rows, .flags = flags, .owns_value_memory = true };
    defer result.deinit(allocator);

    execution.cleanupCatalogInstance();
    defer execution.cleanupCatalogInstance();
    const catalog = try execution.ensureCatalogInstance(allocator);
    try execution.projectCallReturn(allocator, &result, proc, .{ .catalog = catalog });
    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try testing.expectEqualStrings("l", result.columns[0]);
    try testing.expectEqual(@as(usize, 1), result.flags.items.len);
    try testing.expectEqualStrings("W:ProcedureWarning", result.flags.items[0]);
}
