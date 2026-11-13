// SONNY-2681 regression: the legacy MATCH executor's read-view fallback
// snapshot was freed while the rows it returned still pointed into it.
//
// `executeMatchQueryImpl` read through `graph_store.ReadView`: it recorded
// the process-wide mutation epoch, and if any write (to any graph, any
// tenant, any store) bumped it before `getReadStore`, it deep-copied the
// store and read the copy. `defer read_view.deinit()` freed the copy when
// the function returned, but the rows hold the copy's nodes and property
// strings, which the shared projection and every caller read afterwards: a
// use-after-free. The copy bought no consistency either: the epoch is
// checked once, so a write after the check reached the live store's read
// all the same. The executor now reads the store `getGlobalStore` gives it
// (the transport's installed snapshot, or the live store), as every other
// legacy read does.
//
// A second thread performs real writes on a private store (each bumps the
// process-wide epoch, as a write to another graph does) while the in-memory,
// tenant-scoped and RLS sessions (the legacy executor) run traversals whose
// rows carry nodes and borrowed strings. Every cell is read after the
// statement returns, before the result is released, on a leak-checking
// allocator, which poisons freed memory. No mocks.
//
// CANARY: REQ=REQ-SONNY-2681-READ-VIEW-LIFETIME; FEATURE="LegacyMatchExecutor"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2681_read_view_snapshot_lifetime.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("statement_leak_harness.zig");

const graph_store = geode.graph_store;

const Writer = struct {
    stop: std.atomic.Value(bool) = .init(false),
    writes: std.atomic.Value(usize) = .init(0),

    /// Create and delete nodes on a private store until stopped: each write
    /// bumps the process-wide mutation epoch.
    fn run(self: *Writer) void {
        var store = graph_store.GraphStore.init(std.heap.smp_allocator) catch return;
        defer store.deinit();
        var labels = [_][]const u8{"Elsewhere"};
        while (!self.stop.load(.acquire)) {
            const id = store.createNodeWithGraph(&labels, "elsewhere") catch continue;
            store.deleteNode(id);
            _ = self.writes.fetchAdd(1, .monotonic);
        }
    }
};

const visible = [_][]const u8{
    "CREATE (:P {s: 'p-zero'})-[:R {w: 'edge-zero'}]->(:Q {s: 'q-zero'})",
    "CREATE (:P {s: 'p-one'})-[:R {w: 'edge-one'}]->(:Q {s: 'q-one'})",
};
const hidden = [_][]const u8{"CREATE (:P{H} {s: 'hidden'})-[:R {w: 'hidden'}]->(:Q{H} {s: 'hidden'})"};

const Case = struct { q: []const u8, want: []const []const u8 };
const cases = [_]Case{
    .{ .q = "MATCH (a:P)-[r:R]->(b:Q) RETURN a.s, r.w, b.s", .want = &.{ "'p-one', 'edge-one', 'q-one'", "'p-zero', 'edge-zero', 'q-zero'" } },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q) RETURN b", .want = &.{ "(:Q)", "(:Q)" } },
    .{ .q = "MATCH (a:P)-[:R]->(b:Q) WHERE b.s <> 'x' RETURN a.s || '/' || b.s AS x", .want = &.{ "'p-one/q-one'", "'p-zero/q-zero'" } },
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "SONNY-2681: rows of the legacy executor stay valid while other writes land (in-memory, tenant-scoped, RLS)" {
    var failures: usize = 0;
    for ([_]h.Mode{ .in_memory, .tenant_scoped, .rls_policy }) |mode| {
        var s = try h.Session.init(mode);
        defer s.deinit();
        try s.seed(&visible, &hidden);

        var writer: Writer = .{};
        const thread = try std.Thread.spawn(.{}, Writer.run, .{&writer});
        defer {
            writer.stop.store(true, .release);
            thread.join();
        }
        while (writer.writes.load(.monotonic) == 0) std.Thread.yield() catch {};

        for (0..60) |_| {
            for (cases) |c| {
                const o = try h.run(&s, .embedded, c.q, &.{}, false);
                const aa = s.arena.allocator();
                if (o.err) |err| {
                    std.debug.print("[{s}] {s}: error {s}\n", .{ @tagName(mode), c.q, @errorName(err) });
                    failures += 1;
                    continue;
                }
                const got = try aa.dupe([]const u8, o.rows.?);
                std.mem.sort([]const u8, got, {}, lessThan);
                const same = got.len == c.want.len and for (got, c.want) |g, w| {
                    if (!std.mem.eql(u8, g, w)) break false;
                } else true;
                if (!same or o.leaked) {
                    std.debug.print("[{s}] {s}: leaked={} got {{{s}}}\n", .{ @tagName(mode), c.q, o.leaked, try std.mem.join(aa, " | ", got) });
                    failures += 1;
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
