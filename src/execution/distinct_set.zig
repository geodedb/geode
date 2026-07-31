const std = @import("std");
const value_types = @import("../value_types.zig");
const graph_store = @import("../graph_store.zig");
const property_codec = @import("../property_value_codec.zig");

const Value = value_types.Value;

// CANARY: REQ=REQ-GQL-SET-QUANTIFIER-001; FEATURE="AggregateSetQuantifier"; ASPECT=DistinctAccumulator; STATUS=TESTED; TEST=tests/test_bug731_aggregates_vectors.zig; OWNER=execution; UPDATED=2026-07-31
//
// ONE shared DISTINCT accumulator for every aggregate implementation. Before
// this existed, five sibling aggregate paths each rolled their own
// `countDistinct` handling and disagreed with each other about node identity,
// boolean handling, and the empty-group result (docs/@BUGS_731.md bug 6b).
//
// Identity rules (ISO/IEC 39075:2024 <set quantifier>):
//   * Node / Edge          -> by entity id, never by pointer.
//   * integral numerics    -> by the i64 value, so 10, 10.0 and DECIMAL '10.00'
//                             are the SAME value.
//   * fractional numerics  -> by the IEEE-754 bit pattern of the f64.
//   * strings              -> by bytes (Str / Text / Char / Varchar alias).
//   * Bool                 -> by the boolean.
//   * everything else      -> by a tag-qualified rendering of the value.
//   * NULL                 -> never a member; `add` reports it as "not new" so
//                             callers skip the row (aggregates other than
//                             COUNT(*) ignore null inputs).

/// Set of already-seen aggregate input values.
///
/// All keys are owned by an internal arena, so the set stays valid even when
/// the caller's evaluated Values are transient.
pub const DistinctSet = struct {
    arena: std.heap.ArenaAllocator,
    seen: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator) DistinctSet {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *DistinctSet) void {
        self.arena.deinit();
    }

    /// Returns true when `value` is a non-NULL value observed for the FIRST
    /// time. Returns false for NULL and for repeats.
    pub fn add(self: *DistinctSet, value: Value) !bool {
        const a = self.arena.allocator();
        const key = (try encodeKey(a, value)) orelse return false;
        const gop = try self.seen.getOrPut(a, key);
        return !gop.found_existing;
    }

    /// Number of distinct non-NULL values observed.
    pub fn count(self: *const DistinctSet) usize {
        return self.seen.count();
    }
};

/// Convenience wrapper for the node-oriented aggregate paths that hold
/// `graph_store.PropertyValue`s rather than `Value`s.
pub fn addProperty(set: *DistinctSet, prop: graph_store.PropertyValue) !bool {
    return set.add(property_codec.propertyValueToValue(prop));
}

/// Canonical hash key for a value, or null when the value is SQL NULL.
fn encodeKey(a: std.mem.Allocator, value: Value) !?[]const u8 {
    return switch (value) {
        .Null => null,
        .Node => |n| try std.fmt.allocPrint(a, "N:{d}", .{n.id}),
        .Edge => |e| try std.fmt.allocPrint(a, "E:{d}", .{e.id}),
        .Bool => |b| if (b) "B:1" else "B:0",
        .Int => |n| try encodeInt(a, n),
        .SmallInt => |n| try encodeInt(a, n),
        .BigInt => |n| try encodeInt(a, n),
        .Real => |f| try encodeFloat(a, @floatCast(f)),
        .Double => |f| try encodeFloat(a, f),
        .Decimal => |d| blk: {
            const divisor = std.math.pow(f64, 10.0, @floatFromInt(d.scale));
            break :blk try encodeFloat(a, @as(f64, @floatFromInt(d.coeff)) / divisor);
        },
        .Str => |s| try std.fmt.allocPrint(a, "S:{s}", .{s}),
        .Text => |s| try std.fmt.allocPrint(a, "S:{s}", .{s}),
        .Char => |c| try std.fmt.allocPrint(a, "S:{s}", .{c.data}),
        .Varchar => |v| try std.fmt.allocPrint(a, "S:{s}", .{v.data}),
        .Bytea => |b| try std.fmt.allocPrint(a, "X:{x}", .{b}),
        .Json => |s| try std.fmt.allocPrint(a, "J:{s}", .{s}),
        .UUID => |u| try std.fmt.allocPrint(a, "U:{x}", .{u.bytes}),
        else => blk: {
            // Fall back to the shared stringifier so structurally equal values
            // of the same tag collapse into one bucket. Values it cannot render
            // (EvalError.Unsupported) degrade to one bucket per tag — an
            // under-count that is still better than the previous behaviour of
            // ignoring the value entirely.
            var buf: [64]u8 = undefined;
            const rendered = value_types.stringify(value, &buf) catch
                break :blk try std.fmt.allocPrint(a, "?{s}", .{@tagName(value)});
            break :blk try std.fmt.allocPrint(a, "{s}:{s}", .{ @tagName(value), rendered });
        },
    };
}

fn encodeInt(a: std.mem.Allocator, n: i64) ![]const u8 {
    return try std.fmt.allocPrint(a, "I:{d}", .{n});
}

/// Integral floats share the integer key space so `10` and `10.0` are one value.
fn encodeFloat(a: std.mem.Allocator, f: f64) ![]const u8 {
    if (std.math.isFinite(f) and @floor(f) == f and
        f >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
        f <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
    {
        return encodeInt(a, @intFromFloat(f));
    }
    return try std.fmt.allocPrint(a, "F:{x}", .{@as(u64, @bitCast(f))});
}
