// SONNY-6499 item 1: the two ORDER BY ... LIMIT fast paths
// (`match_operations.orderedScanFastPath`, served from the value-ordered
// index, and `topKOrderedFastPath`, the bounded heap) return exactly the
// first k rows of the full ORDER BY, for every k, direction and null
// ordering.
//
// Before: both skipped every node lacking the sort key (and the heap every
// stored NULL), so the NULL rows the full sort returns were missing; both
// declined an explicit NULLS FIRST / NULLS LAST. The value-ordered index
// orders strings by their raw bytes, so a column holding a string that is
// not in NFC (a decomposed 'é', U+212A KELVIN SIGN, U+212B ANGSTROM SIGN)
// came back in a different order than the full sort's (NFC, SONNY-3055).
//
// ISO/IEC 39075:2024 16.17 <sort specification list>: SR 6, the default
// <null ordering> is implementation-defined (IS001) and does not depend on
// the direction — Geode's is NULLS FIRST; GR 1 g ii, NULLS FIRST / NULLS
// LAST place the nulls before / after every value in either direction;
// GR 1 k, the relative order of peers is implementation-dependent (US006).
// So the check is differential: each limited query is compared with the
// same query without LIMIT (always the full sort), position by position,
// as peers under the full sort's own comparison
// (`return_and_sorting.compareValuesWithNullsPolicy`), and its rows must be
// rows of the full result.
//
// Every dataset runs in every mode (in-memory: neither fast path, no
// storage adapter; tenant-scoped: the heap, the index declines a tenant;
// persisted and unbounded-cache: the index where the column is eligible,
// else the heap), with a value-ordered index built (and checkpointed) on
// every label in the persisted modes, for k = 0 .. n + 1, ASC and DESC,
// default / NULLS FIRST / NULLS LAST, and with SKIP. The hit counters prove
// which fast path SERVED each query (declined where the table says so).
// The persisted session is then reopened (the index loads from its
// snapshot) and every query checked again for its rows.
//
// CANARY: REQ=REQ-SONNY-6499-ORDERBY-FASTPATH-NULLS; FEATURE="TopKOrderedFastPath"; ASPECT=FastPathsReturnFullSortPrefix; STATUS=TESTED; TEST=tests/test_sonny6499_orderby_fastpath_nulls.zig; OWNER=execution; UPDATED=2026-11-13

const std = @import("std");
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = vs.Value;
const Session = vs.Session;
const Failures = vs.Failures;
const Param = vs.Param;

/// Which fast path a dataset is served by, when one may serve it.
const Serve = enum { ordered, heap, none };

const Dataset = struct {
    label: []const u8,
    /// CREATE statements (one node each); `$d` is a DOUBLE parameter.
    nodes: []const []const u8,
    doubles: []const f64 = &.{},
    /// Stored DOUBLEs: the node created with `{f: i}` gets `k` = `floats[i]`
    /// written as a storage FLOAT (`GraphStore.setNodeProperty`), as the
    /// cluster replication codec writes a DOUBLE; a CREATE stores one as an
    /// extended value, which the value-ordered index does not admit.
    floats: []const f64 = &.{},
    /// Without a tenant, with the value-ordered index built on (label, k).
    served: Serve,
};

const datasets = [_]Dataset{
    // INTEGERs, two nodes without the key: an eligible INTEGER column.
    .{ .label = "I", .served = .ordered, .nodes = &.{
        "CREATE (:I {k: 5})",                "CREATE (:I {k: -3})", "CREATE (:I {x: 1})",
        "CREATE (:I {k: 9007199254740993})", "CREATE (:I {k: 0})",  "CREATE (:I)",
        "CREATE (:I {k: 42})",
    } },
    // DOUBLEs (0.1, which no double holds exactly, and extremes; a stored
    // DOUBLE cannot be infinite), one node without the key. CREATE stores
    // them as extended values: not index-eligible, the heap.
    .{ .label = "D", .served = .heap, .doubles = &.{ 0.1, 2.5, -1e300, 9007199254740992.0, 1e300, -0.5 }, .nodes = &.{
        "CREATE (:D {k: $d})", "CREATE (:D {k: $d})", "CREATE (:D {k: $d})", "CREATE (:D {k: $d})",
        "CREATE (:D {k: $d})", "CREATE (:D {k: $d})", "CREATE (:D)",
    } },
    // The same DOUBLEs stored as storage FLOATs: an eligible DOUBLE column.
    .{ .label = "F", .served = .ordered, .floats = &.{ 0.1, 2.5, -1e300, 9007199254740992.0, 1e300, -0.5 }, .nodes = &.{
        "CREATE (:F {f: 0})", "CREATE (:F {f: 1})", "CREATE (:F {f: 2})", "CREATE (:F {f: 3})",
        "CREATE (:F {f: 4})", "CREATE (:F {f: 5})", "CREATE (:F)",
    } },
    // INTEGERs and storage FLOATs on different nodes (so, likely, on
    // different shards, each of one class): the index ordered every INTEGER
    // before every DOUBLE. Declined: the heap.
    .{ .label = "W", .served = .heap, .floats = &.{ 0.5, 3.5 }, .nodes = &.{
        "CREATE (:W {k: 5})", "CREATE (:W {f: 0})", "CREATE (:W {k: 1})", "CREATE (:W {f: 1})",
        "CREATE (:W)",
    } },
    // Exact DECIMALs, INTEGERs and DOUBLEs together (0.1 and 0.1d differ;
    // 2^53 + 1 and the DOUBLE 2^53 differ): not index-eligible, the heap.
    .{ .label = "M", .served = .heap, .doubles = &.{ 0.1, 9007199254740992.0 }, .nodes = &.{
        "CREATE (:M {k: 0.1})", "CREATE (:M {k: $d})", "CREATE (:M {k: 9007199254740993})",
        "CREATE (:M {k: $d})",  "CREATE (:M {k: 1})",  "CREATE (:M {k: 2.50})",
        "CREATE (:M)",
    } },
    // ASCII strings: an eligible STRING column.
    .{ .label = "S", .served = .ordered, .nodes = &.{
        "CREATE (:S {k: 'b'})", "CREATE (:S {k: 'a'})", "CREATE (:S)", "CREATE (:S {k: 'aa'})",
        "CREATE (:S {k: 'c'})", "CREATE (:S)",
    } },
    // Non-ASCII strings that are all in NFC, a non-BMP character among them:
    // their bytes order as their NFC forms, so the index may serve.
    .{ .label = "C", .served = .ordered, .nodes = &.{
        "CREATE (:C {k: 'z'})", "CREATE (:C {k: '\u{e9}'})",    "CREATE (:C {k: '\u{1F600}'})",
        "CREATE (:C {k: 'a'})", "CREATE (:C {k: '\u{1D538}'})", "CREATE (:C)",
    } },
    // Strings not in NFC: a decomposed 'é' (its bytes order before 'f', its
    // NFC form after 'z'), the precomposed 'é' (a peer of it), U+212A
    // KELVIN SIGN (NFC 'K', its bytes after every ASCII string) and U+212B
    // ANGSTROM SIGN (NFC U+00C5, before 'é'; its bytes after 'é'). The index
    // orders them by bytes: the heap serves.
    .{ .label = "U", .served = .heap, .nodes = &.{
        "CREATE (:U {k: 'a'})",        "CREATE (:U {k: 'e\u{301}'})", "CREATE (:U {k: '\u{e9}'})",
        "CREATE (:U {k: 'f'})",        "CREATE (:U {k: 'z'})",        "CREATE (:U {k: '\u{1F600}'})",
        "CREATE (:U {k: '\u{212A}'})", "CREATE (:U {k: 'L'})",        "CREATE (:U {k: '\u{212B}'})",
        "CREATE (:U {k: '\u{c4}'})",   "CREATE (:U)",
    } },
    // INTEGERs with explicit NULLs and a node without the key. A NULL
    // property value is not stored (the node lacks the key), so the column
    // is an eligible INTEGER one.
    .{ .label = "N", .served = .ordered, .nodes = &.{
        "CREATE (:N {k: 3})", "CREATE (:N {k: null})", "CREATE (:N {k: 1})", "CREATE (:N {k: null})",
        "CREATE (:N {k: 2})", "CREATE (:N)",
    } },
    // Numbers and strings together: the full sort orders them by kind
    // (numbers first, 16.17 GR 1 i: implementation-dependent); the heap
    // shares that comparison. The index declines a column whose classes
    // differ across shards (each shard's own values may be of one class).
    .{ .label = "X", .served = .heap, .nodes = &.{
        "CREATE (:X {k: 'b'})", "CREATE (:X {k: 2})", "CREATE (:X)", "CREATE (:X {k: 'a'})",
        "CREATE (:X {k: 1})",
    } },
    // A BOOLEAN among numbers: neither fast path orders it; the full sort
    // serves every query.
    .{ .label = "B", .served = .none, .nodes = &.{
        "CREATE (:B {k: true})", "CREATE (:B {k: 1})", "CREATE (:B)", "CREATE (:B {k: false})",
    } },
    // No node has the key: every row is NULL.
    .{ .label = "Z", .served = .ordered, .nodes = &.{ "CREATE (:Z)", "CREATE (:Z {x: 1})", "CREATE (:Z)" } },
};

const Variant = struct { order: []const u8, skip: usize = 0 };

const variants = [_]Variant{
    .{ .order = "" },
    .{ .order = " DESC" },
    .{ .order = " ASC NULLS FIRST" },
    .{ .order = " ASC NULLS LAST" },
    .{ .order = " DESC NULLS FIRST" },
    .{ .order = " DESC NULLS LAST" },
    .{ .order = "", .skip = 1 },
    .{ .order = " DESC NULLS LAST", .skip = 2 },
};

fn seed(s: *Session) !void {
    for (datasets) |ds| {
        var next_double: usize = 0;
        for (ds.nodes) |stmt| {
            if (std.mem.indexOf(u8, stmt, "$d") != null) {
                const p: Param = .{ .name = "d", .value = .{ .Double = ds.doubles[next_double] } };
                next_double += 1;
                try s.exec(stmt, &.{p});
            } else try s.exec(stmt, &.{});
        }
        if (ds.floats.len == 0) continue;
        const aa = s.arena.allocator();
        const q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) WHERE n.f IS NOT NULL RETURN n, n.f", .{ds.label});
        var r = try s.run(q, &.{});
        defer r.deinit(aa);
        if (r.rows.len != ds.floats.len) return error.SeedFailed;
        const store = graph_store.getGlobalStore(std.testing.allocator);
        for (r.rows) |row| {
            const i: usize = @intCast(row[1].Int);
            try store.setNodeProperty(row[0].Node.id, "k", .{ .Float = ds.floats[i] });
        }
    }
}

/// Register and build the value-ordered index on every (label, k), then
/// checkpoint, so it is registered, fresh and (where the column allows)
/// eligible on every shard.
fn buildOrderedIndexes() !void {
    const adapter = graph_store.getGlobalAdapter() orelse return error.WrongDeployment;
    for (datasets) |ds| try adapter.createOrderedIndex(graph_store.DEFAULT_GRAPH_NAME, ds.label, "k");
    try adapter.checkpointAll();
}

fn expectedServe(mode: vs.Mode, ds: Dataset, k: usize, skip: usize) Serve {
    if (k == 0 or skip != 0) return .none;
    return switch (mode) {
        .in_memory => .none,
        .tenant_scoped => if (ds.served == .none) .none else .heap,
        .persisted, .unbounded_cache => ds.served,
    };
}

fn render(aa: std.mem.Allocator, rows: []const []const Value) ![]const u8 {
    var parts = try aa.alloc([]const u8, rows.len);
    for (rows, 0..) |row, i| parts[i] = try vs.renderRow(aa, row);
    return std.mem.join(aa, " | ", parts);
}

fn checkDataset(s: *Session, f: *Failures, ds: Dataset, check_path: bool) !void {
    const aa = s.arena.allocator();
    for (variants) |variant| {
        const base = try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN n.k AS k ORDER BY n.k{s}", .{ ds.label, variant.order });
        var full = s.run(base, &.{}) catch |err| {
            try f.add("[{s}] {s}: error {s}", .{ @tagName(s.mode), base, @errorName(err) });
            continue;
        };
        defer full.deinit(aa);
        const n = full.rows.len;
        if (n != ds.nodes.len) try f.add("[{s}] {s}: {d} rows, {d} nodes", .{ @tagName(s.mode), base, n, ds.nodes.len });

        var k: usize = 0;
        while (k <= n + 1) : (k += 1) {
            const q = if (variant.skip != 0)
                try std.fmt.allocPrint(aa, "{s} SKIP {d} LIMIT {d}", .{ base, variant.skip, k })
            else
                try std.fmt.allocPrint(aa, "{s} LIMIT {d}", .{ base, k });
            const ordered_before = execution.getOrderedScanFastPathHits();
            const heap_before = execution.getTopKFastPathHits();
            var got = s.run(q, &.{}) catch |err| {
                try f.add("[{s}] {s}: error {s}", .{ @tagName(s.mode), q, @errorName(err) });
                continue;
            };
            defer got.deinit(aa);
            const served: Serve = if (execution.getOrderedScanFastPathHits() != ordered_before)
                .ordered
            else if (execution.getTopKFastPathHits() != heap_before)
                .heap
            else
                .none;

            const lo = @min(variant.skip, n);
            const want = full.rows[lo..@min(lo + k, n)];
            var same = got.rows.len == want.len;
            if (same) {
                for (got.rows, want) |g, w| {
                    if (execution.compareValuesWithNullsPolicy(g[0], w[0], .default) != 0) same = false;
                }
            }
            // Every row returned is a row of the full result (peers may be
            // any of the tied rows, but not some other value).
            if (same) {
                var used = try aa.alloc(bool, n);
                @memset(used, false);
                for (got.rows) |g| {
                    const gr = try vs.renderRow(aa, g);
                    const found = for (full.rows, 0..) |w, i| {
                        if (!used[i] and std.mem.eql(u8, gr, try vs.renderRow(aa, w))) {
                            used[i] = true;
                            break true;
                        }
                    } else false;
                    if (!found) same = false;
                }
            }
            if (!same) {
                try f.add("[{s}] {s} (served by {s}): got [{s}], full sort gives [{s}]", .{
                    @tagName(s.mode), q, @tagName(served), try render(aa, got.rows), try render(aa, want),
                });
            }
            if (check_path) {
                const expect = expectedServe(s.mode, ds, k, variant.skip);
                if (served != expect) try f.add("[{s}] {s}: served by {s}, expected {s}", .{ @tagName(s.mode), q, @tagName(served), @tagName(expect) });
            }
        }
    }
}

fn checkAll(s: *Session, f: *Failures) !void {
    try seed(s);
    if (s.mode != .in_memory) try buildOrderedIndexes();
    for (datasets) |ds| try checkDataset(s, f, ds, true);
    if (s.mode == .persisted) {
        try s.reopen();
        for (datasets) |ds| try checkDataset(s, f, ds, false);
    }
}

test "SONNY-6499: ORDER BY ... LIMIT fast paths return the first k rows of the full sort (NULLs, NULLS FIRST/LAST, NFC strings, doubles)" {
    try vs.inModes("orderby-fastpath", &vs.all_modes, checkAll);
}
