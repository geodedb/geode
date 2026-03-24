const std = @import("std");

// =============================================================================
// Re-export range types from the external advanced_types library.
//
// The external library provides Range(T) with inclusive bounds [lower, upper],
// containment checks, overlap detection, intersection, union, formatting, and
// parsing. Geode's legacy Range(T) additionally supports:
//   - Optional lower/upper bounds (unbounded ranges)
//   - Bounds enum (inclusive_inclusive, inclusive_exclusive, etc.)
//   - DateRange alias
//
// The external library's Range is re-exported here alongside the Geode-specific
// Range for backward compatibility with existing consumers that use optional
// bounds and bound types.
// =============================================================================
const advanced_types = @import("advanced_types_lib");

/// External library's Range generic — inclusive [lower, upper] with required bounds.
/// Provides: init, contains, containsRange, overlaps, intersection, union_, span,
/// isPoint, eql, format, parse.
pub const ExtRange = advanced_types.Range;

/// External library convenience aliases
pub const ExtIntRange = advanced_types.IntRange;
pub const ExtUintRange = advanced_types.UintRange;
pub const ExtFloatRange = advanced_types.FloatRange;

/// External library error type
pub const RangeError = advanced_types.range.RangeError;

// =============================================================================
// Geode's Range(T) with optional bounds and bound types (preserve existing API)
// =============================================================================

pub fn Range(comptime T: type) type {
    return struct {
        const Self = @This();

        lower: ?T,
        upper: ?T,
        bounds: Bounds,

        pub const Bounds = enum(u8) {
            inclusive_inclusive = 0b00, // [a,b]
            inclusive_exclusive = 0b01, // [a,b)
            exclusive_inclusive = 0b10, // (a,b]
            exclusive_exclusive = 0b11, // (a,b)

            pub fn toString(self: Bounds) []const u8 {
                return switch (self) {
                    .inclusive_inclusive => "[]",
                    .inclusive_exclusive => "[)",
                    .exclusive_inclusive => "(]",
                    .exclusive_exclusive => "()",
                };
            }

            pub fn fromString(str: []const u8) ?Bounds {
                if (std.mem.eql(u8, str, "[]")) return .inclusive_inclusive;
                if (std.mem.eql(u8, str, "[)")) return .inclusive_exclusive;
                if (std.mem.eql(u8, str, "(]")) return .exclusive_inclusive;
                if (std.mem.eql(u8, str, "()")) return .exclusive_exclusive;
                return null;
            }
        };

        pub const Error = error{
            InvalidBounds,
            OutOfMemory,
        };

        pub fn init(lower: ?T, upper: ?T, bounds: Bounds) Error!Self {
            if (lower != null and upper != null) {
                const l = lower.?;
                const u = upper.?;

                if (compare(T, l, u) > 0) return Error.InvalidBounds;
                if (compare(T, l, u) == 0) {
                    switch (bounds) {
                        .exclusive_exclusive, .inclusive_exclusive, .exclusive_inclusive => return Error.InvalidBounds,
                        .inclusive_inclusive => {},
                    }
                }
            }

            return Self{ .lower = lower, .upper = upper, .bounds = bounds };
        }

        pub fn contains(self: Self, value: T) bool {
            if (self.lower) |l| {
                const cmp = compare(T, value, l);
                if (cmp < 0) return false;
                if (cmp == 0 and (self.bounds == .exclusive_inclusive or self.bounds == .exclusive_exclusive)) return false;
            }

            if (self.upper) |u| {
                const cmp = compare(T, value, u);
                if (cmp > 0) return false;
                if (cmp == 0 and (self.bounds == .inclusive_exclusive or self.bounds == .exclusive_exclusive)) return false;
            }

            return true;
        }

        pub fn overlaps(self: Self, other: Self) bool {
            if (self.upper != null and other.lower != null) {
                const cmp = compare(T, self.upper.?, other.lower.?);
                if (cmp < 0) return false;
                if (cmp == 0) {
                    const self_upper_exclusive = (self.bounds == .inclusive_exclusive or self.bounds == .exclusive_exclusive);
                    const other_lower_exclusive = (other.bounds == .exclusive_inclusive or other.bounds == .exclusive_exclusive);
                    if (self_upper_exclusive or other_lower_exclusive) return false;
                }
            }

            if (other.upper != null and self.lower != null) {
                const cmp = compare(T, other.upper.?, self.lower.?);
                if (cmp < 0) return false;
                if (cmp == 0) {
                    const other_upper_exclusive = (other.bounds == .inclusive_exclusive or other.bounds == .exclusive_exclusive);
                    const self_lower_exclusive = (self.bounds == .exclusive_inclusive or self.bounds == .exclusive_exclusive);
                    if (other_upper_exclusive or self_lower_exclusive) return false;
                }
            }

            return true;
        }

        pub fn toString(self: Self, allocator: std.mem.Allocator) ![]u8 {
            const lower_str = if (self.lower) |l| try formatValue(T, allocator, l) else try allocator.dupe(u8, "");
            defer if (self.lower != null) allocator.free(lower_str);

            const upper_str = if (self.upper) |u| try formatValue(T, allocator, u) else try allocator.dupe(u8, "");
            defer if (self.upper != null) allocator.free(upper_str);

            const bounds_str = self.bounds.toString();
            const left_bracket = bounds_str[0];
            const right_bracket = bounds_str[1];

            return std.fmt.allocPrint(allocator, "{c}{s},{s}{c}", .{ left_bracket, lower_str, upper_str, right_bracket });
        }

        fn compare(comptime ValueType: type, a: ValueType, b: ValueType) i8 {
            return switch (@typeInfo(ValueType)) {
                .int, .float => if (a < b) -1 else if (a > b) 1 else 0,
                else => @compileError("Unsupported type for range comparison"),
            };
        }

        fn formatValue(comptime ValueType: type, allocator: std.mem.Allocator, value: ValueType) ![]u8 {
            return std.fmt.allocPrint(allocator, "{any}", .{value});
        }
    };
}

pub const IntRange = Range(i32);
pub const DateRange = Range(@import("datetime.zig").Date);

test "range operations" {
    const range_val = try IntRange.init(1, 4, .inclusive_exclusive);

    std.testing.expect(range_val.contains(3)) catch unreachable;
    std.testing.expect(!range_val.contains(4)) catch unreachable;

    const range2 = try IntRange.init(3, 6, .inclusive_exclusive);
    std.testing.expect(range_val.overlaps(range2)) catch unreachable;
}
