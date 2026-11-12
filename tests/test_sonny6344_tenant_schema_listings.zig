// SONNY-6344 item 2: the schema listings a tenant-scoped session reads
// (`CALL db.labels()`, `db.relationshipTypes()`, `db.propertyKeys()`, SHOW
// TABLES) list exactly what that session's MATCH sees. They read per-tenant
// structures by EXACT tag, so a parent tenant missed its descendants' labels,
// types and property keys (the edge property keys were also matched by exact
// tag), while its MATCH returns those rows (GAP-0846, SONNY-6338 family).
//
// Item 1 re-check: an uncorrelated `COUNT { (a:S)-[:T]->(b:S) }` counts the
// matching paths, not the visible start nodes, for every session.
//
// Fixture (sonny6338_tenant_harness): P -> {C1, C2}; U unrelated. Real
// parse -> execute pipeline on a persisted store; no mocks.
//
// CANARY: REQ=REQ-SONNY-6344-TENANT-LISTINGS; FEATURE="PerTenantIsolation"; ASPECT=SchemaListings; STATUS=TESTED; TEST=tests/test_sonny6344_tenant_schema_listings.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const th = @import("sonny6338_tenant_harness.zig");

const Harness = th.Harness;
const P = th.P;
const C1 = th.C1;
const U = th.U;

/// Column 0 of every row as strings, sorted.
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

fn expectNames(h: *Harness, tenant: ?[]const u8, src: []const u8, want: []const []const u8) !usize {
    const got = names(h, tenant, src) catch |err| {
        std.debug.print("tenant={?s} {s}: error {s}\n", .{ tenant, src, @errorName(err) });
        return 1;
    };
    var same = got.len == want.len;
    if (same) for (got, want) |g, w| {
        if (!std.mem.eql(u8, g, w)) same = false;
    };
    if (same) return 0;
    std.debug.print("tenant={?s} {s}\n  want {any}\n  got  {any}\n", .{ tenant, src, want, got });
    return 1;
}

fn expectCount(h: *Harness, tenant: ?[]const u8, src: []const u8, want: i64) usize {
    const before = h.mismatches;
    h.expectInt(want, tenant, src);
    return h.mismatches - before;
}

fn seed(h: *Harness) !void {
    try h.exec(C1, "CREATE (:Kid6344 {ka: 1})-[:R6344 {ek: 1}]->(:Kid6344 {kb: 2})");
    try h.exec(P, "CREATE (:Par6344 {pa: 1})");
    try h.exec(U, "CREATE (:Unrel6344 {ua: 1})-[:RU6344 {uk: 1}]->(:Unrel6344 {ub: 2})");
}

const labels_q = "CALL db.labels() YIELD label RETURN label";
const types_q = "CALL db.relationshipTypes() YIELD relationshipType RETURN relationshipType";
const keys_q = "CALL db.propertyKeys() YIELD propertyKey RETURN propertyKey";
const tables_q = "SHOW TABLES";

fn checkListings(h: *Harness) !usize {
    var bad: usize = 0;
    // The parent sees its child's rows, as its MATCH does.
    bad += try expectNames(h, P, labels_q, &.{ "Kid6344", "Par6344" });
    bad += try expectNames(h, P, types_q, &.{"R6344"});
    bad += try expectNames(h, P, keys_q, &.{ "ek", "ka", "kb", "pa" });
    bad += try expectNames(h, P, tables_q, &.{ "Kid6344", "Par6344" });
    // A child sees only its own; the parent's rows stay hidden from it.
    bad += try expectNames(h, C1, labels_q, &.{"Kid6344"});
    bad += try expectNames(h, C1, types_q, &.{"R6344"});
    bad += try expectNames(h, C1, keys_q, &.{ "ek", "ka", "kb" });
    bad += try expectNames(h, C1, tables_q, &.{"Kid6344"});
    // An unrelated tenant sees only its own.
    bad += try expectNames(h, U, labels_q, &.{"Unrel6344"});
    bad += try expectNames(h, U, types_q, &.{"RU6344"});
    bad += try expectNames(h, U, keys_q, &.{ "ua", "ub", "uk" });
    // The oracle: what each session's MATCH returns.
    bad += expectCount(h, P, "MATCH (n:Kid6344) RETURN count(n)", 2);
    bad += expectCount(h, P, "MATCH (n:Unrel6344) RETURN count(n)", 0);
    bad += expectCount(h, P, "MATCH ()-[r:R6344]->() RETURN count(r)", 1);
    bad += expectCount(h, C1, "MATCH (n:Par6344) RETURN count(n)", 0);
    return bad;
}

test "SONNY-6344 item 2: db.labels / relationshipTypes / propertyKeys and SHOW TABLES list what the session's MATCH sees" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try seed(&h);
    // Not after `h.reopen()`: there every tenant-scoped listing is empty
    // while MATCH still sees the rows, with or without this change (a
    // separate defect, reported with SONNY-6344).
    const bad = try checkListings(&h);
    try testing.expectEqual(@as(usize, 0), bad);
}

test "SONNY-6344 item 1 (re-check): an uncorrelated COUNT { hop } counts matching paths for every session" {
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    // C1: s1 -T-> s2;  U: s5 -T-> s6, s5 -T-> s7;  P: s8 (no edge).
    try h.exec(C1, "CREATE (a:S6344 {k: 1})-[:T]->(b:S6344 {k: 2})");
    try h.exec(U, "CREATE (a:S6344 {k: 5})-[:T]->(b:S6344 {k: 6})");
    try h.exec(U, "MATCH (a:S6344 {k: 5}) CREATE (a)-[:T]->(:S6344 {k: 7})");
    try h.exec(P, "CREATE (:S6344 {k: 8})");
    const Case = struct { tenant: ?[]const u8, paths: i64 };
    for ([_]Case{
        .{ .tenant = C1, .paths = 1 },
        .{ .tenant = U, .paths = 2 },
        .{ .tenant = P, .paths = 1 },
        .{ .tenant = null, .paths = 3 },
    }) |c| {
        h.expectInt(c.paths, c.tenant, "MATCH (a:S6344)-[:T]->(b:S6344) RETURN count(*)");
        h.expectInt(c.paths, c.tenant, "RETURN COUNT { (a:S6344)-[:T]->(b:S6344) } AS c");
    }
    try testing.expectEqual(@as(usize, 0), h.mismatches);
}
