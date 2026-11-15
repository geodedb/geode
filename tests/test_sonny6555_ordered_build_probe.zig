// SONNY-6555 item 3 (SONNY-6518 item 6): an ORDER BY ... LIMIT on a column
// the value-ordered index cannot serve does not start the index's background
// build.
//
// `orderedScanFastPath` (src/execution/match_operations.zig) starts a
// one-time background build of the value-ordered index for (label, key)
// when none is registered (`spawnOrderedIndexBuildAsync`), and later
// declines to serve a column whose values are of more than one order class
// (INTEGER, DOUBLE, STRING) or whose strings are not all their own NFC form
// (`orderedIndexColumn`, SONNY-6499): the trees order by type rank and
// bytes, the full ORDER BY by value and NFC form. The build was started
// before anything knew the column's class, so a column the fast path will
// always decline paid a full build (and a checkpoint to persist it) for
// nothing. The adapter now probes the column first
// (`StorageAdapter.probeOrderedColumnClass`) and a column that is mixed, or
// holds a non-canonical string or a value of no ordered class, is declined
// before the build starts. A column of one class with canonical strings
// still builds.
//
// The query is served by the full sort either way; the rows are checked.
//
// CANARY: REQ=REQ-SONNY-6555-ORDERED-BUILD-PROBE; FEATURE="OrderedIndex"; ASPECT=ColumnClassProbe; STATUS=TESTED; TEST=tests/test_sonny6555_ordered_build_probe.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");
const adapter_mod = geode.graph_storage_adapter;

fn waitCompletions(want: u64, ms: u64) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var waited: u64 = 0;
    while (adapter_mod.getOrderedBuildCompletionsForTesting() < want and waited < ms) : (waited += 20) {
        std.Io.sleep(io, .fromMilliseconds(20), .real) catch {};
    }
}

/// Runs `order_by` once, waits for any build it started, and returns how
/// many builds ran.
fn buildsAfter(s: *vs.Session, f: *vs.Failures, order_by: []const u8, want_rows: []const []const u8) !u64 {
    adapter_mod.resetOrderedIndexBuildsForTesting();
    adapter_mod.resetOrderedBuildCompletionsForTesting();
    try vs.expectOrdered(s, f, order_by, &.{}, want_rows);
    waitCompletions(1, 3000);
    return adapter_mod.getOrderedIndexBuildsForTesting();
}

fn checkProbe(s: *vs.Session, f: *vs.Failures) !void {
    adapter_mod.setOrderedAutobuildDisabledForTest(false);
    defer adapter_mod.setOrderedAutobuildDisabledForTest(null);

    // Mixed classes: INTEGER and STRING.
    try s.exec("CREATE (:M6555 {k: 2}), (:M6555 {k: 'a'}), (:M6555 {k: 1})", &.{});
    const mixed = try buildsAfter(s, f, "MATCH (n:M6555) RETURN n.k ORDER BY n.k LIMIT 3", &.{ "1", "2", "'a'" });
    if (mixed != 0) try f.add("mixed INTEGER/STRING column: {d} ordered-index build(s) started, want 0", .{mixed});

    // Mixed numeric classes: INTEGER and DOUBLE.
    try s.exec("CREATE (:D6555 {k: 2}), (:D6555 {k: CAST(1.5 AS FLOAT)})", &.{});
    const numeric = try buildsAfter(s, f, "MATCH (n:D6555) RETURN n.k ORDER BY n.k LIMIT 2", &.{ "1.5d", "2" });
    if (numeric != 0) try f.add("mixed INTEGER/DOUBLE column: {d} build(s), want 0", .{numeric});

    // A string that is not its own NFC form (e + combining acute).
    try s.exec("CREATE (:N6555 {k: 'b'}), (:N6555 {k: 'e\u{301}'})", &.{});
    const non_canonical = try buildsAfter(s, f, "MATCH (n:N6555) RETURN n.k ORDER BY n.k LIMIT 1", &.{"'b'"});
    if (non_canonical != 0) try f.add("non-canonical string column: {d} build(s), want 0", .{non_canonical});

    // A value of no ordered class (a list).
    try s.exec("CREATE (:L6555b {k: 1}), (:L6555b {k: [1, 2]})", &.{});
    const listy = try buildsAfter(s, f, "MATCH (n:L6555b) RETURN n.k ORDER BY n.k LIMIT 1", &.{"1"});
    if (listy != 0) try f.add("column with a LIST value: {d} build(s), want 0", .{listy});

    // Control: one class, canonical strings (and a node without the key):
    // the build starts.
    try s.exec("CREATE (:S6555 {k: 'b'}), (:S6555 {k: 'a'}), (:S6555 {other: 1})", &.{});
    const single = try buildsAfter(s, f, "MATCH (n:S6555) RETURN n.k ORDER BY n.k NULLS LAST LIMIT 2", &.{ "'a'", "'b'" });
    if (single != 1) try f.add("single-class canonical column: {d} build(s), want 1", .{single});
}

test "SONNY-6555 item 3: a column the ordered index cannot serve is declined before its build starts" {
    try vs.inModes("ordered-build-probe", &.{ .persisted, .unbounded_cache }, checkProbe);
}
