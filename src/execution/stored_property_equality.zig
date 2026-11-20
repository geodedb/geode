//! An inline property map's value against a STORED property (SONNY-2806).
//!
//! `MATCH (n:T {x: v})` asks whether the node's `x` equals `v`. The legacy
//! executor answers with `execution.valuesEqual`, which compares two numbers
//! by their exact value (value_order, the identity GROUP BY keys numbers by).
//! The planned read and the server's streaming node scan read the stored
//! property from the storage engine instead, and each compared it by
//! representation: a decimal by coefficient and scale (`{x: 1.50}` missed a
//! stored 1.5, `{x: 1.0}` a stored 1), an integer only with an integer, a
//! DOUBLE parameter never (the planned read had no DOUBLE arm, and a stored
//! DOUBLE is an extended value, which never matched), and no extended value
//! at all (a SMALLINT, a duration, a zoned time...). Both now call `matches`,
//! which gives the answer `valuesEqual` gives, for nodes and relationships,
//! with one exception: a stored string also equals a TEXT, VARCHAR or CHAR
//! value with the same characters (see `matches`).

// CANARY: REQ=REQ-SONNY-2806-STORED-PROPERTY-EQUALITY; FEATURE="InlinePropertyMatch"; ASPECT=ExactValueOnPersistedPaths; STATUS=TESTED; TEST=tests/test_sonny2806_exact_property_matching.zig; OWNER=execution; UPDATED=2026-09-26

const std = @import("std");
const gs = @import("graph_storage");
const graph_storage_adapter = @import("../storage/graph_storage_adapter.zig");
const property_codec = @import("../property_value_codec.zig");
const value_types = @import("../value_types.zig");
const value_order = @import("value_order.zig");
const value_equality = @import("value_equality.zig");
const canonical_string = @import("../unicode/canonical_string.zig");

const Value = value_types.Value;

/// Whether the stored property `actual` equals `expected`, as
/// `execution.valuesEqual` decides for the same two values, with one
/// exception: a stored string also equals a TEXT, VARCHAR or CHAR value with
/// the same characters. The executor reads a stored string as a plain string
/// (`Str`), and `valuesEqual` finds no string of another type equal to one,
/// so the legacy executor's `{s: TEXT 'a'}` misses a stored 'a'; the
/// streaming node scan matched it before SONNY-2806, and still does, and the
/// planned read now does too.
///
/// `allocator` decodes an extended value; nothing is kept. A decode failure
/// (out of memory, or a stored value the codec rejects) is returned, not
/// taken for a mismatch, which silently dropped the row.
pub fn matches(allocator: std.mem.Allocator, expected: Value, actual: gs.PropertyValue) !bool {
    return switch (actual) {
        .int => |n| numberEquals(expected, .{ .exact = .{ .coeff = n, .scale = 0 } }),
        .float => |f| numberEquals(expected, .{ .float = f }),
        .decimal => |d| numberEquals(expected, .{ .exact = .{ .coeff = d.coeff, .scale = d.scale } }),
        // SONNY-3055: by their NFC forms, as `=` compares them.
        .string => |text| switch (expected) {
            .Str => |t| try canonical_string.eql(allocator, t, text),
            .Text => |t| try canonical_string.eql(allocator, t, text),
            .Varchar => |t| try canonical_string.eql(allocator, t.data, text),
            .Char => |t| try canonical_string.eql(allocator, t.data, text),
            else => false,
        },
        .bool => |b| expected == .Bool and expected.Bool == b,
        .null => expected == .Null,
        // An extended value (a DOUBLE, a SMALLINT, a duration, a zoned
        // time, ...): decoded as the executor reads it, then compared as the
        // executor compares it.
        .ext => blk: {
            const decoded = try graph_storage_adapter.fromStorageProperty(allocator, actual);
            defer property_codec.freePropertyValue(allocator, decoded);
            break :blk value_equality.valuesEqual(property_codec.propertyValueToValue(decoded), expected);
        },
    };
}

fn numberEquals(expected: Value, stored: value_order.Number) bool {
    const n = value_order.numberOf(expected) orelse return false;
    return value_order.compareNumbers(n, stored) == 0;
}
