// SONNY-6425 item 3: after the store is closed and opened again in the same
// process, a tenant-scoped session's schema listings (`CALL db.labels()`,
// `db.relationshipTypes()`, `db.propertyKeys()`, SHOW TABLES) still list
// what its MATCH sees. They were empty for every tenant while MATCH still
// returned the rows (found with SONNY-6344, whose test checks before a
// reopen only).
//
// Fixture (sonny6338_tenant_harness): P -> {C1, C2}; U unrelated. Real
// parse -> execute pipeline on a persisted store; no mocks.
//
// CANARY: REQ=REQ-SONNY-6425-LISTINGS-AFTER-REOPEN; FEATURE="PerTenantIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6425_tenant_listings_reopen.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const th = @import("sonny6338_tenant_harness.zig");

const Harness = th.Harness;
const P = th.P;
const C1 = th.C1;
const U = th.U;

fn names(h: *Harness, tenant: ?[]const u8, src: []const u8) ![]const []const u8 {
    const res = try h.run(tenant, src);
    const aa = h.arena.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    for (res.rows) |row| {
        if (row.len == 0) return error.NoColumns;
        switch (row[0]) {
            .Str => |s| try out.append(aa, s),
            else => return error.UnexpectedValueType,
        }
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.items;
}

fn expectNames(h: *Harness, phase: []const u8, tenant: ?[]const u8, src: []const u8, want: []const []const u8) !usize {
    const got = names(h, tenant, src) catch |err| {
        std.debug.print("[{s}] tenant={?s} {s}: error {s}\n", .{ phase, tenant, src, @errorName(err) });
        return 1;
    };
    var same = got.len == want.len;
    if (same) for (got, want) |g, w| {
        if (!std.mem.eql(u8, g, w)) same = false;
    };
    if (same) return 0;
    std.debug.print("[{s}] tenant={?s} {s}\n  want {any}\n  got  {any}\n", .{ phase, tenant, src, want, got });
    return 1;
}

const labels_q = "CALL db.labels() YIELD label RETURN label";
const types_q = "CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType";
const keys_q = "CALL db.propertyKeys() YIELD propertyKey RETURN propertyKey";
const tables_q = "SHOW TABLES";

fn checkListings(h: *Harness, phase: []const u8) !usize {
    var bad: usize = 0;
    bad += try expectNames(h, phase, P, labels_q, &.{ "Kid6425", "Par6425" });
    bad += try expectNames(h, phase, P, types_q, &.{"R6425"});
    bad += try expectNames(h, phase, P, keys_q, &.{ "ek", "ka", "kb", "pa" });
    bad += try expectNames(h, phase, P, tables_q, &.{ "Kid6425", "Par6425" });
    bad += try expectNames(h, phase, C1, labels_q, &.{"Kid6425"});
    bad += try expectNames(h, phase, C1, types_q, &.{"R6425"});
    bad += try expectNames(h, phase, C1, keys_q, &.{ "ek", "ka", "kb" });
    bad += try expectNames(h, phase, U, labels_q, &.{"Unrel6425"});
    bad += try expectNames(h, phase, U, types_q, &.{"RU6425"});
    bad += try expectNames(h, phase, U, keys_q, &.{ "ua", "ub", "uk" });
    // The unscoped session lists every tenant's.
    bad += try expectNames(h, phase, null, labels_q, &.{ "Kid6425", "Par6425", "Unrel6425" });
    // The oracle: what each session's MATCH returns.
    const before = h.mismatches;
    h.expectInt(2, P, "MATCH (n:Kid6425) RETURN count(n)");
    h.expectInt(0, P, "MATCH (n:Unrel6425) RETURN count(n)");
    h.expectInt(1, U, "MATCH ()-[r:RU6425]->() RETURN count(r)");
    h.expectInt(0, C1, "MATCH (n:Par6425) RETURN count(n)");
    bad += h.mismatches - before;
    return bad;
}

test "SONNY-6425 item 3: a tenant's schema listings list what its MATCH sees after the store is reopened" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try h.exec(C1, "CREATE (:Kid6425 {ka: 1})-[:R6425 {ek: 1}]->(:Kid6425 {kb: 2})");
    try h.exec(P, "CREATE (:Par6425 {pa: 1})");
    try h.exec(U, "CREATE (:Unrel6425 {ua: 1})-[:RU6425 {uk: 1}]->(:Unrel6425 {ub: 2})");
    var bad = try checkListings(&h, "before reopen");
    try h.reopen();
    bad += try checkListings(&h, "after reopen");
    // And once more: the second open reads what the first one wrote.
    try h.reopen();
    bad += try checkListings(&h, "after a second reopen");
    try testing.expectEqual(@as(usize, 0), bad);
}
