// SONNY-6489 item 2: `MATCH (n:L) RETURN n.k ORDER BY n.k LIMIT k` (the
// top-K heap, `match_operations.topKOrderedFastPath`) returns the first k
// rows of the full ORDER BY, for every k.
//
// Before: the heap ordered an INT against a DOUBLE or DECIMAL through f64
// (`entryLess`), and turned a DECIMAL into a DOUBLE, both for the order and
// for the row it returned; it ordered strings by raw bytes. The full sort
// (`return_and_sorting.compareValuesWithNullsPolicy`) compares numbers by
// exact value (SONNY-2807, ISO/IEC 39075 19.3: numbers compare by their
// numerical values) and strings by their NFC form (SONNY-3055). So
// 9007199254740993 and DOUBLE 2^53 tied, DECIMAL 0.1 and DOUBLE 0.1 tied, the
// heap kept either, the DECIMAL came back as 0.1d, and `LIMIT k` disagreed
// with the full order and with `<`.
//
// Each mode with a store (persisted, tenant-scoped, unbounded node cache:
// both of the heap's read paths) checks, ASC and DESC, that every LIMIT k
// equals the first k rows of the unlimited ORDER BY. The string check runs
// in the tenant-scoped mode: there the value-ordered index path, which reads
// its own encoding and serves a type-uniform column, declines (it cannot
// filter by tenant), so the heap serves deterministically.
//
// CANARY: REQ=REQ-SONNY-6489-TOPK-EXACT-ORDER; FEATURE="ValueOrdering"; ASPECT=TopKHeapSharesFullSortOrder; STATUS=TESTED; TEST=tests/test_sonny6489_topk_order.zig; OWNER=execution; UPDATED=2026-11-13

const std = @import("std");
const vs = @import("value_semantics_harness.zig");

const Session = vs.Session;
const Failures = vs.Failures;
const Param = vs.Param;

const d01: Param = .{ .name = "d", .value = .{ .Double = 0.1 } };
const d2p53: Param = .{ .name = "d", .value = .{ .Double = 9007199254740992.0 } };

fn rendered(s: *Session, query: []const u8) ![]const []const u8 {
    const aa = s.arena.allocator();
    var r = try s.run(query, &.{});
    const out = try aa.alloc([]const u8, r.rows.len);
    for (r.rows, out) |row, *o| o.* = try vs.renderRow(aa, row);
    r.deinit(aa);
    return out;
}

/// Every LIMIT k of `base` (k = 1 .. rows) equals the first k rows of `base`
/// without a LIMIT.
fn checkPrefixes(s: *Session, f: *Failures, base: []const u8) !void {
    const aa = s.arena.allocator();
    const full = try rendered(s, base);
    var k: usize = 1;
    while (k <= full.len) : (k += 1) {
        const q = try std.fmt.allocPrint(aa, "{s} LIMIT {d}", .{ base, k });
        const got = try rendered(s, q);
        const same = got.len == k and for (got, full[0..k]) |g, w| {
            if (!std.mem.eql(u8, g, w)) break false;
        } else true;
        if (!same) {
            try f.add("{s}: got [{s}], full order starts [{s}]", .{ q, try std.mem.join(aa, " | ", got), try std.mem.join(aa, " | ", full[0..k]) });
        }
    }
}

fn checkTopK(s: *Session, f: *Failures) !void {
    // Numbers that are distinct by exact value but not through f64.
    try s.exec("CREATE (:N {k: 9007199254740993})", &.{});
    try s.exec("CREATE (:N {k: $d})", &.{d2p53});
    try s.exec("CREATE (:N {k: 9007199254740991})", &.{});
    try s.exec("CREATE (:N {k: 0.1})", &.{});
    try s.exec("CREATE (:N {k: $d})", &.{d01});
    try s.exec("CREATE (:N {k: 1})", &.{});
    try checkPrefixes(s, f, "MATCH (n:N) RETURN n.k AS k ORDER BY n.k");
    try checkPrefixes(s, f, "MATCH (n:N) RETURN n.k AS k ORDER BY n.k DESC");

    if (s.mode == .tenant_scoped) {
        // 'e' + U+0301 is 'é' in NFC, which orders after 'z'; its raw
        // bytes order between 'a' and 'f'.
        try s.exec("CREATE (:S {k: 'a'})", &.{});
        try s.exec("CREATE (:S {k: 'e\u{301}'})", &.{});
        try s.exec("CREATE (:S {k: 'f'})", &.{});
        try s.exec("CREATE (:S {k: 'z'})", &.{});
        try checkPrefixes(s, f, "MATCH (n:S) RETURN n.k AS k ORDER BY n.k");
        try checkPrefixes(s, f, "MATCH (n:S) RETURN n.k AS k ORDER BY n.k DESC");
    }
}

test "SONNY-6489: ORDER BY ... LIMIT k returns the first k rows of the full ORDER BY (exact numbers, NFC strings)" {
    try vs.inModes("top-k", &.{ .persisted, .tenant_scoped, .unbounded_cache }, checkTopK);
}
