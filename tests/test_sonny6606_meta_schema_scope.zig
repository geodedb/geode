// SONNY-6606 (1): `CALL db.labels()`, `db.relationshipTypes()`,
// `db.propertyKeys()` and `SHOW TABLES` listed the schema of every graph,
// `__geode_security` included (its `User` / `Role` / `AuthChainRoot` labels
// and `password_hash` / `hmac` keys), to every session, whatever graph it was
// on and whatever it may read. They now list the session graph's schema only.
//
// Drives a real `geode serve` over QUIC: an admin and a readonly user granted
// READ on one graph, three graphs with distinct labels, edge types and keys.
//
// CANARY: REQ=REQ-SONNY-6606-META-SCHEMA-SCOPE; FEATURE="GPS Metadata Isolation"; ASPECT=SessionGraphOnly; STATUS=TESTED; TEST=tests/test_sonny6606_meta_schema_scope.zig; OWNER=security; UPDATED=2026-11-15
const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const scratch = @import("test_scratch.zig");

const testing = std.testing;

const alice = "alice6606";
const alice_pw = "Alice Meta Sonny Passphrase 6606";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Every string cell of `q`'s rows, joined by '|' (caller frees).
fn listing(allocator: std.mem.Allocator, client: *util.QuicProtoClient, q: []const u8) ![]u8 {
    var r = try client.executeAndCollect(allocator, q, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6606: '{s}' failed: {s} {s}\n", .{ q, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (r.rows) |row| for (row) |cell| switch (cell) {
        .string => |s| {
            try out.appendSlice(allocator, s);
            try out.append(allocator, '|');
        },
        else => {},
    };
    return out.toOwnedSlice(allocator);
}

fn run(allocator: std.mem.Allocator, client: *util.QuicProtoClient, q: []const u8) !void {
    var r = try client.executeAndCollect(allocator, q, util.emptyParams(), 10);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6606: setup '{s}' failed: {s} {s}\n", .{ q, code, r.error_message orelse "" });
        return error.SetupFailed;
    }
}

const Expect = struct {
    has: []const []const u8,
    lacks: []const []const u8,
};

/// Names of every graph's schema; each session must see its own graph's only.
const internal = [_][]const u8{ "AuthChainRoot", "User|", "Role|", "password_hash", "hmac", "chain_hash" };

fn check(allocator: std.mem.Allocator, client: *util.QuicProtoClient, who: []const u8, q: []const u8, want: Expect) !usize {
    const text = try listing(allocator, client, q);
    defer allocator.free(text);
    var bad: usize = 0;
    for (want.has) |n| if (std.mem.indexOf(u8, text, n) == null) {
        std.debug.print("SONNY-6606: {s}: {s} lacks '{s}': {s}\n", .{ who, q, n, text });
        bad += 1;
    };
    for (want.lacks) |n| if (std.mem.indexOf(u8, text, n) != null) {
        std.debug.print("SONNY-6606: {s}: {s} leaks '{s}': {s}\n", .{ who, q, n, text });
        bad += 1;
    };
    for (internal) |n| if (std.mem.indexOf(u8, text, n) != null) {
        std.debug.print("SONNY-6606: {s}: {s} leaks the security graph's '{s}': {s}\n", .{ who, q, n, text });
        bad += 1;
    };
    return bad;
}

fn checkSession(allocator: std.mem.Allocator, client: *util.QuicProtoClient, who: []const u8, own: []const []const u8, others: []const []const u8) !usize {
    var bad: usize = 0;
    // own[0] label, own[1] edge type, own[2] node key, own[3] edge key.
    bad += try check(allocator, client, who, "CALL db.labels()", .{ .has = own[0..1], .lacks = others });
    bad += try check(allocator, client, who, "SHOW TABLES", .{ .has = own[0..1], .lacks = others });
    if (own.len > 1) bad += try check(allocator, client, who, "CALL db.relationshipTypes()", .{ .has = own[1..2], .lacks = others });
    bad += try check(allocator, client, who, "CALL db.propertyKeys()", .{ .has = own[2..], .lacks = others });
    return bad;
}

test "SONNY-6606 (1): db.labels, db.relationshipTypes, db.propertyKeys and SHOW TABLES list the session graph only" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var dir = try scratch.ScratchDir.create("sonny6606-meta");
    defer dir.remove();
    const data_dir = try std.fs.path.join(allocator, &.{ dir.path(), "data" });
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);
    const port = try util.getRandomPort();
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, util.TestEnv.standard());
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 60_000);

    {
        var admin = try util.QuicProtoClient.connect(allocator, addr);
        defer admin.deinit();
        var h = try admin.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        try testing.expect(h.success);
        for ([_][]const u8{
            "CREATE (:Dflt6606 {dflt_prop6606: 1})",
            "CREATE GRAPH ga6606",
            "CREATE GRAPH gb6606",
            "USE GRAPH ga6606",
            "CREATE (:VisA6606 {visa_prop6606: 1})-[:VREL6606 {vrel_prop6606: 1}]->(:VisA6606)",
            "USE GRAPH gb6606",
            "CREATE (:SecB6606 {secb_prop6606: 1})-[:SREL6606 {srel_prop6606: 1}]->(:SecB6606)",
            "CREATE USER " ++ alice ++ " SET PASSWORD '" ++ alice_pw ++ "' ROLE readonly",
            "GRANT READ ON GRAPH ga6606 TO " ++ alice,
        }) |q| try run(allocator, &admin, q);
    }

    const ga_names = [_][]const u8{ "VisA6606", "VREL6606", "visa_prop6606", "vrel_prop6606" };
    const gb_names = [_][]const u8{ "SecB6606", "SREL6606", "secb_prop6606", "srel_prop6606" };
    const dflt_names = [_][]const u8{ "Dflt6606", "dflt_prop6606" };
    const not_ga = gb_names ++ dflt_names;
    const not_gb = ga_names ++ dflt_names;
    const not_dflt = ga_names ++ gb_names;

    var bad: usize = 0;
    // The admin on the default graph, then on gb6606.
    {
        var c = try util.QuicProtoClient.connect(allocator, addr);
        defer c.deinit();
        var h = try c.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        try testing.expect(h.success);
        bad += try check(allocator, &c, "admin on default", "CALL db.labels()", .{ .has = dflt_names[0..1], .lacks = &not_dflt });
        bad += try check(allocator, &c, "admin on default", "SHOW TABLES", .{ .has = dflt_names[0..1], .lacks = &not_dflt });
        bad += try check(allocator, &c, "admin on default", "CALL db.relationshipTypes()", .{ .has = &.{}, .lacks = &not_dflt });
        bad += try check(allocator, &c, "admin on default", "CALL db.propertyKeys()", .{ .has = dflt_names[1..], .lacks = &not_dflt });
    }
    {
        var c = try util.QuicProtoClient.connect(allocator, addr);
        defer c.deinit();
        var h = try c.helloWithGraph(allocator, util.defaultUsername(), util.defaultPassword(), "gb6606");
        defer h.deinit(allocator);
        try testing.expect(h.success);
        bad += try checkSession(allocator, &c, "admin on gb6606", &gb_names, &not_gb);
    }
    // alice (readonly, READ on ga6606 only) on ga6606.
    {
        var c = try util.QuicProtoClient.connect(allocator, addr);
        defer c.deinit();
        var h = try c.helloWithGraph(allocator, alice, alice_pw, "ga6606");
        defer h.deinit(allocator);
        if (!h.success) std.debug.print("SONNY-6606: alice could not bind ga6606: {s}\n", .{h.error_message});
        try testing.expect(h.success);
        bad += try checkSession(allocator, &c, "alice on ga6606", &ga_names, &not_ga);
    }
    try testing.expectEqual(@as(usize, 0), bad);
}
