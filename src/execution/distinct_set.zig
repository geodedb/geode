const std = @import("std");
const value_types = @import("../value_types.zig");
const graph_store = @import("../graph_store.zig");
const property_codec = @import("../property_value_codec.zig");
const value_order = @import("value_order.zig");
const canonical_string = @import("../unicode/canonical_string.zig");

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
//   * numbers              -> by their exact value, the comparator's
//                             (value_order.zig): 10, 10.0 and DECIMAL '10.00'
//                             are the SAME value, so are DECIMAL 0.5 and
//                             DOUBLE 0.5, and every NaN; DECIMAL 0.1 and
//                             DOUBLE 0.1 are not. (SONNY-2675: a decimal was
//                             keyed through f64, so decimals past ~16
//                             significant digits merged, and each NaN bit
//                             pattern was a value of its own.)
//   * strings              -> by the bytes of their NFC form (Str / Text /
//                             Char / Varchar alias): a precomposed 'é' and
//                             'e' + U+0301 are one value, as `=` decides
//                             (SONNY-3055: they were two).
//   * Bool                 -> by the boolean.
//   * intervals            -> by months and day-to-second length (a month is
//                             not 30 days; a day is 24 hours); a time with a
//                             time zone by its UTC time: the comparator's.
//   * everything else      -> by its type and value: dates and times by
//                             their fields, lists element by
//                             element, maps entry by entry (sorted by key),
//                             extended values by their binary encoding.
//                             (SONNY-2675: they were by a rendering into 64
//                             bytes, which had none for lists, maps, enums or
//                             bit strings, so those were one bucket per type.)
//   * NULL                 -> never a member; `add` reports it as "not new" so
//                             callers skip the row (aggregates other than
//                             COUNT(*) ignore null inputs). In a group key
//                             (`writeGroupKeyPart`) NULL is a key of its own.

/// Set of already-seen aggregate input values.
///
/// All keys are owned by an internal arena, so the set stays valid even when
/// the caller's evaluated Values are transient.
pub const DistinctSet = struct {
    arena: std.heap.ArenaAllocator,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// The key of the value being tested, reused across calls.
    key: std.Io.Writer.Allocating,

    pub fn init(allocator: std.mem.Allocator) DistinctSet {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .key = .init(allocator) };
    }

    pub fn deinit(self: *DistinctSet) void {
        self.key.deinit();
        self.arena.deinit();
    }

    /// Returns true when `value` is a non-NULL value observed for the FIRST
    /// time. Returns false for NULL and for repeats.
    pub fn add(self: *DistinctSet, value: Value) !bool {
        const a = self.arena.allocator();
        self.key.clearRetainingCapacity();
        if (!try writeKey(&self.key.writer, a, value)) return false;
        const gop = try self.seen.getOrPut(a, self.key.written());
        if (gop.found_existing) return false;
        gop.key_ptr.* = try a.dupe(u8, self.key.written());
        return true;
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

// CANARY: REQ=REQ-SONNY-2675-TYPED-GROUP-KEYS; FEATURE="GroupedAggregates"; ASPECT=CanonicalKeyEncoding; STATUS=TESTED; TEST=tests/test_sonny2675_aggregate_semantics.zig; OWNER=execution; UPDATED=2026-09-25
/// One GROUP BY key of a row, appended to the row's group key. NULL is a key
/// of its own (every NULL groups together). Every key is self-delimiting (a
/// type byte, then fixed-width numbers or length-prefixed bytes), so the keys
/// of a multi-key GROUP BY cannot run into each other.
///
/// SONNY-2675: each grouping site serialized keys itself: integers and
/// strings as text, NULL as "null", anything else as "?", joined with "|". So
/// 1 and '1' were one group, 'null' and NULL were one group, every double,
/// date, decimal or text key was one group, and ('a|b', 'c') was the group of
/// ('a', 'b|c').
pub fn writeGroupKeyPart(w: *std.Io.Writer, scratch: std.mem.Allocator, value: Value) WriteKeyError!void {
    if (!try writeKey(w, scratch, value)) try w.writeByte(tag_null);
}

pub const WriteKeyError = std.Io.Writer.Error || error{OutOfMemory};

// The type byte of each key. NULL has one only inside a group key or a list.
const tag_null = '0';

/// Writes the canonical key of `value` to `w` (the identity rules above) and
/// returns true; writes nothing and returns false for NULL. `scratch` holds
/// temporary allocations (a map's sorted keys, an extended value's encoding).
pub fn writeKey(w: *std.Io.Writer, scratch: std.mem.Allocator, value: Value) WriteKeyError!bool {
    switch (value) {
        .Null => return false,
        .Node => |n| {
            try w.writeByte('N');
            try w.writeInt(u64, n.id, .little);
        },
        .Edge => |e| {
            try w.writeByte('E');
            try w.writeInt(u64, e.id, .little);
        },
        .Path => |path| {
            try w.writeByte('H');
            try w.writeInt(u32, @intCast(path.nodes.len), .little);
            for (path.nodes) |n| try w.writeInt(u64, n.id, .little);
            try w.writeInt(u32, @intCast(path.edges.len), .little);
            for (path.edges) |e| try w.writeInt(u64, e.id, .little);
        },
        .Bool => |b| try w.writeAll(if (b) "B1" else "B0"),
        .Int, .SmallInt, .BigInt, .Real, .Double, .Decimal => try value_order.writeNumberKey(w, value_order.numberOf(value).?),
        .Str => |t| try writeText(w, scratch, t),
        .Text => |t| try writeText(w, scratch, t),
        .Char => |c| try writeText(w, scratch, c.data),
        .Varchar => |c| try writeText(w, scratch, c.data),
        .Bytea => |b| try writeBytes(w, 'X', b),
        .Json => |j| try writeBytes(w, 'J', j),
        .Jsonb => |j| try writeBytes(w, 'j', j.data),
        .Xml => |x| try writeBytes(w, 'x', x.data),
        .UUID => |u| {
            try w.writeByte('U');
            try w.writeAll(&u.bytes);
        },
        .Date => |d| {
            try w.writeByte('D');
            try w.writeInt(i32, d.days_since_epoch, .little);
        },
        .Time => |t| {
            try w.writeByte('T');
            try w.writeInt(i64, t.micros_since_midnight, .little);
        },
        .TimeTZ => |t| {
            try w.writeByte('t');
            try w.writeInt(i128, value_order.timeTzUtcMicros(t), .little);
        },
        .Timestamp => |t| {
            try w.writeByte('P');
            try w.writeInt(i64, t.micros_since_epoch, .little);
        },
        .TimestampTZ => |t| {
            try w.writeByte('Z');
            try w.writeInt(i64, t.micros_since_epoch_utc, .little);
        },
        .Interval => |iv| try value_order.writeIntervalKey(w, iv),
        .Url => |u| {
            try w.writeByte('W');
            try writeBytes(w, 'S', u.scheme);
            try writeBytes(w, 'S', u.host);
            if (u.port) |port| {
                try w.writeByte(1);
                try w.writeInt(u16, port, .little);
            } else try w.writeByte(0);
            try writeBytes(w, 'S', u.path);
            try writeOptionalBytes(w, u.query);
            try writeOptionalBytes(w, u.fragment);
        },
        .Domain => |d| {
            try w.writeByte('O');
            try w.writeInt(u32, @intCast(d.labels.len), .little);
            for (d.labels) |label| try writeBytes(w, 'S', label);
        },
        .Enum => |e| {
            try w.writeByte('Q');
            try w.writeInt(u32, e.type_id, .little);
            try w.writeInt(u32, e.value_ordinal, .little);
        },
        .BitString => |b| try writeBits(w, 'b', b.bit_length, b.bytes),
        .VarBit => |b| try writeBits(w, 'v', b.bit_length, b.bytes),
        .IntRange => |r| {
            try w.writeByte('R');
            try writeOptionalI32(w, r.lower);
            try writeOptionalI32(w, r.upper);
            try w.writeByte(@intFromEnum(r.bounds));
        },
        .List => |items| {
            try w.writeByte('L');
            try w.writeInt(u32, @intCast(items.len), .little);
            for (items) |item| try writeGroupKeyPart(w, scratch, item);
        },
        .Map => |map| {
            // Sorted by key: equal maps iterate in different orders.
            const keys = try scratch.alloc([]const u8, map.count());
            defer scratch.free(keys);
            var it = map.keyIterator();
            var i: usize = 0;
            while (it.next()) |k| : (i += 1) keys[i] = k.*;
            std.mem.sort([]const u8, keys, {}, lessThanBytes);
            try w.writeByte('M');
            try w.writeInt(u32, @intCast(keys.len), .little);
            for (keys) |k| {
                try writeBytes(w, 'S', k);
                try writeGroupKeyPart(w, scratch, map.get(k).?);
            }
        },
        .ExtValue => |ext| {
            // An extended value by its binary encoding; one that cannot be
            // encoded keys by its type alone.
            if (property_codec.encodeExtValueBinary(scratch, ext)) |bytes| {
                defer scratch.free(bytes);
                try writeBytes(w, 'e', bytes);
            } else |err| {
                if (@as(anyerror, err) == error.OutOfMemory) return error.OutOfMemory;
                try writeBytes(w, '?', @tagName(ext));
            }
        },
    }
    return true;
}

/// A string's key: its NFC form (SONNY-3055).
fn writeText(w: *std.Io.Writer, scratch: std.mem.Allocator, text: []const u8) WriteKeyError!void {
    const c = try canonical_string.canonical(scratch, text);
    defer c.deinit(scratch);
    try writeBytes(w, 'S', c.bytes);
}

fn writeBytes(w: *std.Io.Writer, tag: u8, bytes: []const u8) std.Io.Writer.Error!void {
    try w.writeByte(tag);
    try w.writeInt(u32, @intCast(bytes.len), .little);
    try w.writeAll(bytes);
}

fn writeOptionalBytes(w: *std.Io.Writer, bytes: ?[]const u8) std.Io.Writer.Error!void {
    if (bytes) |b| try writeBytes(w, 'S', b) else try w.writeByte(tag_null);
}

fn writeOptionalI32(w: *std.Io.Writer, n: ?i32) std.Io.Writer.Error!void {
    if (n) |v| {
        try w.writeByte(1);
        try w.writeInt(i32, v, .little);
    } else try w.writeByte(0);
}

fn writeBits(w: *std.Io.Writer, tag: u8, bit_length: u32, bytes: []const u8) std.Io.Writer.Error!void {
    try w.writeByte(tag);
    try w.writeInt(u32, bit_length, .little);
    try writeBytes(w, 'X', bytes);
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
