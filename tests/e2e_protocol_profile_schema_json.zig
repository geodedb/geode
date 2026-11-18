const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("profile_test_util.zig");

// Minimal structural validation against embedded simplified schema JSON (selected required keys)
// This avoids pulling a full JSON Schema validator into the build while giving us a guard.

const REQUIRED_TOP = [_][]const u8{ "profile_version", "ops", "memory", "total_time_ns" };
const REQUIRED_OP_FIELDS = [_][]const u8{ "op", "phase", "op_index", "bytes_alloc", "net_after_op" };

fn hasField(obj: std.json.ObjectMap, name: []const u8) bool {
    return obj.get(name) != null;
}

test "protocol: PROFILE matches core schema fields (light validator)" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const out = try util.runProfile(testing.allocator, "PROFILE RETURN 1 AS x ORDER BY x LIMIT 1", null);
    defer testing.allocator.free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();
    const prof = parsed.value.object;
    // top-level required fields
    inline for (REQUIRED_TOP) |name| try testing.expect(hasField(prof, name));
    // ops array
    const ops_val = prof.get("ops") orelse return error.MissingOps;
    if (ops_val.* != .array) return error.BadOps;
    const ops = ops_val.array.items;
    try testing.expect(ops.len > 0);
    // validate first op has the required subset fields
    const first = ops[0];
    if (first != .object) return error.FirstOpNotObject;
    const fobj = first.object;
    inline for (REQUIRED_OP_FIELDS) |fname| try testing.expect(hasField(fobj, fname));
    // memory block required fields
    const mem_val = prof.get("memory") orelse return error.MissingMemory;
    if (mem_val.* != .object) return error.BadMemory;
    const mem_obj = mem_val.object;
    inline for ([_][]const u8{ "net_bytes", "peak_bytes", "total_alloc_bytes" }) |m| try testing.expect(hasField(mem_obj, m));
}
