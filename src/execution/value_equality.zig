// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Whether two values are equal, as the executor compares them
//! (`execution.valuesEqual`; MERGE and an inline property map among others).
//!
//! SONNY-2806 (round 8): moved out of execution.zig, unchanged, so the
//! storage adapter (its multi-property MERGE compares stored values this way)
//! and `stored_property_equality` no longer import the executor for it.
//! It needs only the value types and value_order.

const std = @import("std");
const value_types = @import("../value_types.zig");
const value_order = @import("value_order.zig");
const property_codec = @import("../property_value_codec.zig");
const ExtValue = @import("../eval_extended.zig").ExtValue;

const Value = value_types.Value;

pub fn valuesEqual(a: Value, b: Value) bool {
    // Handle nulls
    if (a == .Null and b == .Null) return true;
    if (a == .Null or b == .Null) return false;

    // Compare same types
    if (a == .Int and b == .Int) return a.Int == b.Int;
    if (a == .Bool and b == .Bool) return a.Bool == b.Bool;
    if (a == .Str and b == .Str) return std.mem.eql(u8, a.Str, b.Str);

    // SONNY-2769 (round 5): two numbers are equal when their exact values
    // are (value_order, the identity GROUP BY and DISTINCT key them by): 1.5
    // equals 1.50, and 1 equals 1.0. The decimal arm aligned the scales in
    // i128 (`multiplier *= 10`, `coeff * multiplier`), which overflowed and
    // aborted the server past 10^38: an inline property map
    // (`MATCH (n:T {x: <a scale-40 decimal>})`) and MERGE reached it.
    if (value_order.numberOf(a)) |na| {
        if (value_order.numberOf(b)) |nb| return value_order.compareNumbers(na, nb) == 0;
    }

    // Node and Edge comparison by pointer
    if (a == .Node and b == .Node) return a.Node == b.Node;
    if (a == .Edge and b == .Edge) return a.Edge == b.Edge;

    // List comparison (element by element)
    if (a == .List and b == .List) {
        if (a.List.len != b.List.len) return false;
        for (a.List, b.List) |av, bv| {
            if (!valuesEqual(av, bv)) return false;
        }
        return true;
    }

    // CANARY: REQ=REQ-SONNY-6433-MERGE-KEYS; FEATURE="MergeStatement"; ASPECT=ListKeyByValue; STATUS=TESTED; TEST=tests/test_sonny6433_merge_keys.zig; OWNER=engine; UPDATED=2026-11-12
    // SONNY-6433: a stored list reads back as an extended list
    // (`ExtValue.List`), while a list literal or parameter is a `Value.List`;
    // the two never compared equal, so `MERGE (n:L {k: [1, 2]})` created a
    // duplicate on every run and an inline `{k: [1, 2]}` matched nothing.
    // Lists are equal when their elements are, in order (ISO/IEC 39075:2024
    // 19.3 <comparison predicate>, list value equality).
    if (a == .List and b == .ExtValue and b.ExtValue == .List) return listEqualsExtList(a.List, b.ExtValue.List);
    if (b == .List and a == .ExtValue and a.ExtValue == .List) return listEqualsExtList(b.List, a.ExtValue.List);

    // String types
    if (a == .Char and b == .Char) return std.mem.eql(u8, a.Char.data, b.Char.data);
    if (a == .Varchar and b == .Varchar) return std.mem.eql(u8, a.Varchar.data, b.Varchar.data);
    if (a == .Text and b == .Text) return std.mem.eql(u8, a.Text, b.Text);
    if (a == .Bytea and b == .Bytea) return std.mem.eql(u8, a.Bytea, b.Bytea);
    if (a == .Json and b == .Json) return std.mem.eql(u8, a.Json, b.Json);
    if (a == .Jsonb and b == .Jsonb) return std.mem.eql(u8, a.Jsonb.data, b.Jsonb.data);
    if (a == .Xml and b == .Xml) return std.mem.eql(u8, a.Xml.data, b.Xml.data);

    // Temporal and identifier types
    if (a == .Date and b == .Date) return std.meta.eql(a.Date, b.Date);
    if (a == .Time and b == .Time) return std.meta.eql(a.Time, b.Time);
    // SONNY-2675 (round 6): a zoned time by its UTC time of day and a
    // duration by its months and day-to-second length, as `=` and GROUP BY
    // compare them (`{v: duration('PT24H')}` missed a stored P1D, and MERGE
    // duplicated it). A zoned datetime is its UTC instant already.
    if (a == .TimeTZ and b == .TimeTZ) return a.TimeTZ.utcMicros() == b.TimeTZ.utcMicros();
    if (a == .Timestamp and b == .Timestamp) return std.meta.eql(a.Timestamp, b.Timestamp);
    if (a == .TimestampTZ and b == .TimestampTZ) return std.meta.eql(a.TimestampTZ, b.TimestampTZ);
    if (a == .Interval and b == .Interval) return a.Interval.eql(b.Interval);
    if (a == .UUID and b == .UUID) return std.meta.eql(a.UUID, b.UUID);
    if (a == .Enum and b == .Enum) return std.meta.eql(a.Enum, b.Enum);
    if (a == .IntRange and b == .IntRange) return std.meta.eql(a.IntRange, b.IntRange);

    if (a == .BitString and b == .BitString) {
        return a.BitString.bit_length == b.BitString.bit_length and
            std.mem.eql(u8, a.BitString.bytes, b.BitString.bytes);
    }
    if (a == .VarBit and b == .VarBit) {
        return a.VarBit.bit_length == b.VarBit.bit_length and
            std.mem.eql(u8, a.VarBit.bytes, b.VarBit.bytes);
    }

    if (a == .Url and b == .Url) {
        return std.mem.eql(u8, a.Url.scheme, b.Url.scheme) and
            std.mem.eql(u8, a.Url.host, b.Url.host) and
            a.Url.port == b.Url.port and
            std.mem.eql(u8, a.Url.path, b.Url.path) and
            ((a.Url.query == null and b.Url.query == null) or
                (a.Url.query != null and b.Url.query != null and std.mem.eql(u8, a.Url.query.?, b.Url.query.?))) and
            ((a.Url.fragment == null and b.Url.fragment == null) or
                (a.Url.fragment != null and b.Url.fragment != null and std.mem.eql(u8, a.Url.fragment.?, b.Url.fragment.?)));
    }

    if (a == .Domain and b == .Domain) {
        if (a.Domain.labels.len != b.Domain.labels.len) return false;
        for (a.Domain.labels, b.Domain.labels) |lhs, rhs| {
            if (!std.mem.eql(u8, lhs, rhs)) return false;
        }
        return true;
    }

    if (a == .ExtValue and b == .ExtValue) return value_types.eqExtValues(a.ExtValue, b.ExtValue);

    // For other types, default to false (different types or unsupported comparison)
    return false;
}

fn listEqualsExtList(values: []const Value, ext: []const ExtValue) bool {
    if (values.len != ext.len) return false;
    for (values, ext) |v, e| {
        if (!valuesEqual(v, property_codec.extValueToValue(e))) return false;
    }
    return true;
}
