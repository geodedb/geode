// SONNY-738 (sweep item 0): one value pair is equal everywhere the engine
// asks "are these equal", or nowhere.
//
// SONNY-6282 made `1 = '1'` False (ISO/IEC 39075:2024 19.3 <comparison
// predicate> GR 1: values that are not essentially comparable are never
// equal; under Feature GA04 "Universal comparison" `=` is False, NOTE 307).
// The other equality sites did not follow: `1 = true` raised a type
// mismatch, which WHERE turned into an error in one session and a dropped
// row in another (so `WHERE n.k <> true` dropped the row too), `[1] = [1.0]`
// and `CASE 1 WHEN 1.0` were False while `1 = 1.0` is True, `[NULL] =
// [NULL]` and `CASE NULL WHEN NULL` were True, and a stored list never
// equalled a list value with a decimal in it.
//
// Every pair below goes through every site, in the in-memory, persisted,
// tenant-scoped and RLS-policy sessions:
//
//   * `A = B`, `B = A`, `A <> B` (19.3; `<>` is NOT (A = B), 19.3 SR);
//   * `A IN [B]` (geode extension; list membership is `A = B` for some
//     element, three-valued, as SQL's <in predicate>);
//   * simple `CASE A WHEN B` (20.7 SR: equivalent to `WHEN A = B`, so a NULL
//     operand never selects a WHEN);
//   * `[A] = [B]` and `{v: A} = {v: B}` (19.3 GR 1)b)ii)-iii): list values
//     element by element and records field by field, Unknown when an element
//     pair is Unknown and none is False);
//   * `count(DISTINCT x)` over [A, B] (22.12 Determination of distinct
//     values: comparable values that are not equal are distinct);
//   * (a recursive CTE's UNION, which drops a row not distinct from one it
//     has (22.12), is checked in tests/e2e_recursive_queries.zig: the
//     recursive CTE executor leaks on this leak-checked harness);
//   * `WHERE n.k = B`, `B = n.k`, `n.k <> B`, `n.k IN [B]` over a stored
//     property;
//   * the inline property map `{k: B}` (16.7 SR: equivalent to
//     `WHERE n.k = B`), which on the persisted sessions seeks the exact
//     property index;
//   * MERGE on the property (geode extension: it finds the node the inline
//     map matches).
//
// CANARY: REQ=REQ-SONNY-738-EQUALITY-CONSISTENCY; FEATURE="ComparisonPredicate"; ASPECT=EverySite; STATUS=TESTED; TEST=tests/test_sonny738_equality_consistency.zig; OWNER=eval; UPDATED=2026-11-13

const std = @import("std");
const harness = @import("read_semantics_batch_harness.zig");
const Value = @import("geode").value_types.Value;

const Case = harness.Case;
const Param = harness.Param;

/// The result of `A = B`.
const Tri = enum { t, f, u };

fn dec(coeff: i128, scale: u8) Value {
    return .{ .Decimal = .{ .coeff = coeff, .scale = scale } };
}

// A list-valued B reaches the stored-property sites as the parameter $b,
// and [B] as $bl: a list literal in a WHERE or an inline property map leaks
// on those paths (an evaluator-ownership defect outside this test's scope,
// listed in the SONNY-738 report).
var l_1 = [_]Value{.{ .Int = 1 }};
var l_1_0_2 = [_]Value{ dec(10, 1), .{ .Int = 2 } };
var l_1_50 = [_]Value{dec(150, 2)};
var l_s1 = [_]Value{.{ .Str = "1" }};
var ll_1 = [_]Value{.{ .List = &l_1 }};
var ll_1_0_2 = [_]Value{.{ .List = &l_1_0_2 }};
var ll_1_50 = [_]Value{.{ .List = &l_1_50 }};
var ll_s1 = [_]Value{.{ .List = &l_s1 }};

const Pair = struct {
    a: []const u8,
    b: []const u8,
    eq: Tri,
    /// `count(DISTINCT x)` over [A, B].
    distinct: u8,
    /// A can be stored as a property and MERGEd on (no null in it).
    store: bool = true,
    /// B and [B] as parameters, for the stored-property sites.
    params: ?[]const Param = null,
};

fn lp(comptime b: []Value, comptime bl: []Value) []const Param {
    return comptime &[_]Param{ .{ .name = "b", .value = .{ .List = b } }, .{ .name = "bl", .value = .{ .List = bl } } };
}

const pairs = [_]Pair{
    // An integer and a string: not essentially comparable.
    .{ .a = "1", .b = "'1'", .eq = .f, .distinct = 2 },
    .{ .a = "9007199254740993", .b = "'9007199254740993'", .eq = .f, .distinct = 2 },
    // Numbers compare by value.
    .{ .a = "1", .b = "1.0", .eq = .t, .distinct = 1 },
    .{ .a = "1.5", .b = "1.50", .eq = .t, .distinct = 1 },
    // A Boolean is not a number, nor a string.
    .{ .a = "1", .b = "true", .eq = .f, .distinct = 2 },
    .{ .a = "0", .b = "false", .eq = .f, .distinct = 2 },
    .{ .a = "'true'", .b = "true", .eq = .f, .distinct = 2 },
    // A date is not a string.
    .{ .a = "DATE '2024-01-01'", .b = "'2024-01-01'", .eq = .f, .distinct = 2 },
    // A number is not a list.
    .{ .a = "1", .b = "[1]", .eq = .f, .distinct = 2, .params = lp(&l_1, &ll_1) },
    // Lists element by element.
    .{ .a = "[1, 2]", .b = "[1.0, 2]", .eq = .t, .distinct = 1, .params = lp(&l_1_0_2, &ll_1_0_2) },
    .{ .a = "[1.5]", .b = "[1.50]", .eq = .t, .distinct = 1, .params = lp(&l_1_50, &ll_1_50) },
    .{ .a = "[1]", .b = "['1']", .eq = .f, .distinct = 2, .params = lp(&l_s1, &ll_s1) },
    .{ .a = "[1, 2]", .b = "[1]", .eq = .f, .distinct = 2, .params = lp(&l_1, &ll_1) },
    .{ .a = "[1, null]", .b = "[2, null]", .eq = .f, .distinct = 2, .store = false },
    .{ .a = "[1, null]", .b = "[1, null]", .eq = .u, .distinct = 1, .store = false },
    // The null value (count(DISTINCT) skips it).
    .{ .a = "null", .b = "1", .eq = .u, .distinct = 1, .store = false },
    .{ .a = "null", .b = "null", .eq = .u, .distinct = 0, .store = false },
};

fn tri(t: Tri) []const u8 {
    return switch (t) {
        .t => "true",
        .f => "false",
        .u => "null",
    };
}

fn neg(t: Tri) Tri {
    return switch (t) {
        .t => .f,
        .f => .t,
        .u => .u,
    };
}

fn one(comptime s: []const u8) []const []const u8 {
    return comptime &[_][]const u8{s};
}

fn casesFor(comptime i: usize, comptime p: Pair) []const Case {
    const f = std.fmt.comptimePrint;
    const e = tri(p.eq);
    const ne = tri(neg(p.eq));
    const case_hit = if (p.eq == .t) "'y'" else "'n'";
    var list: []const Case = &.{
        .{ .q = f("RETURN {s} = {s} AS e, {s} = {s} AS r, {s} <> {s} AS ne, {s} IN [{s}] AS i", .{ p.a, p.b, p.b, p.a, p.a, p.b, p.a, p.b }), .want = one(f("{s}, {s}, {s}, {s}", .{ e, e, ne, e })) },
        .{ .q = f("RETURN CASE {s} WHEN {s} THEN 'y' ELSE 'n' END AS c", .{ p.a, p.b }), .want = one(case_hit) },
        .{ .q = f("RETURN [{s}] = [{s}] AS l, {{v: {s}}} = {{v: {s}}} AS m", .{ p.a, p.b, p.a, p.b }), .want = one(f("{s}, {s}", .{ e, e })) },
        .{ .q = f("FOR x IN [{s}, {s}] RETURN count(DISTINCT x) AS d", .{ p.a, p.b }), .want = one(f("{d}", .{p.distinct})) },
    };
    if (p.store) {
        const hit = if (p.eq == .t) "1" else "0";
        const miss = if (p.eq == .f) "1" else "0";
        const merged = if (p.eq == .t) "1" else "2";
        const b = if (p.params != null) "$b" else p.b;
        const bl = if (p.params != null) "$bl" else f("[{s}]", .{p.b});
        const ps = p.params orelse &.{};
        list = list ++ &[_]Case{
            .{ .q = f("CREATE (:E738x{d} {{k: {s}}})", .{ i, p.a }) },
            .{ .q = f("MATCH (n:E738x{d}) WHERE n.k = {s} RETURN count(*) AS c", .{ i, b }), .params = ps, .want = one(hit) },
            .{ .q = f("MATCH (n:E738x{d}) WHERE {s} = n.k RETURN count(*) AS c", .{ i, b }), .params = ps, .want = one(hit) },
            .{ .q = f("MATCH (n:E738x{d}) WHERE n.k <> {s} RETURN count(*) AS c", .{ i, b }), .params = ps, .want = one(miss) },
            .{ .q = f("MATCH (n:E738x{d}) WHERE n.k IN {s} RETURN count(*) AS c", .{ i, bl }), .params = ps, .want = one(hit) },
            .{ .q = f("MATCH (n:E738x{d} {{k: {s}}}) RETURN count(*) AS c", .{ i, b }), .params = ps, .want = one(hit) },
            .{ .q = f("MERGE (:M738x{d} {{k: {s}}})", .{ i, p.a }) },
            .{ .q = f("MERGE (:M738x{d} {{k: {s}}})", .{ i, b }), .params = ps },
            .{ .q = f("MATCH (n:M738x{d}) RETURN count(*) AS c", .{i}), .want = one(merged) },
        };
    }
    return list;
}

const cases: []const Case = blk: {
    @setEvalBranchQuota(200_000);
    var all: []const Case = &.{
        // An inline map `{k: null}` is `WHERE n.k = null`: Unknown, no row.
        .{ .q = "CREATE (:N738 {j: 1})" },
        .{ .q = "MATCH (n:N738 {k: null}) RETURN count(*) AS c", .want = one("0") },
        .{ .q = "MATCH (n:N738) WHERE n.k = null RETURN count(*) AS c", .want = one("0") },
        // A simple CASE with a null operand takes no WHEN, not even WHEN null.
        .{ .q = "RETURN CASE null WHEN null THEN 'y' ELSE 'n' END AS c", .want = one("'n'") },
    };
    for (pairs, 0..) |p, i| all = all ++ casesFor(i, p);
    break :blk all;
};

test "SONNY-738: a value pair is equal at every equality site or at none" {
    try harness.inEveryMode("SONNY-738 equality consistency", cases);
}
