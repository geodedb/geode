// SONNY-2670 regression: the FLE key-manager and blind-index singletons are
// created on a process-lifetime allocator.
//
// fle_integration.getGlobalKeyManager / getGlobalBlindIndex created the
// process-wide singletons lazily, on whatever allocator the first caller
// held: the executor's per-request arena, the read-budget metered allocator,
// a per-node scratch arena. Once that allocator was torn down, the singleton
// held freed memory, and the next encrypt or decrypt used it. Because of
// this the engine-direct node scan kept a WHERE on the server's main
// allocator whenever an FLE field was configured, so every extended value a
// WHERE read there leaked (SONNY-2656's predicate-side leak, on FLE
// deployments only).
//
// Now both singletons are created on the process allocator (as the FLE
// catalog is), and the node scan runs a WHERE on its per-node scratch arena
// on FLE deployments too.
//
// CANARY: REQ=REQ-SONNY-2670-FLE-SINGLETONS-PROCESS-ALLOCATOR; FEATURE="FieldLevelEncryption"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2670_fle_singletons_process_allocator.zig; OWNER=security; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const fle_integration = geode.fle_integration;
const fle_catalog = fle_integration.catalog_mod;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const master_key = "2670a2670a2670a2670a2670a2670a2670a2670a2670a2670a2670a2670a2670";

/// An FLE master key, an empty FLE catalog, no singletons yet.
fn fleUp() void {
    _ = setenv("GEODE_MASTER_KEY", master_key, 1);
    fle_integration.resetGlobalKeyStateForTesting();
    fle_catalog.resetGlobalCatalog(testing.allocator);
    fle_integration.setHasEncryptedFields(false);
}

fn fleDown() void {
    fle_catalog.resetGlobalCatalog(testing.allocator);
    fle_integration.setHasEncryptedFields(false);
    fle_integration.resetGlobalKeyStateForTesting();
    _ = unsetenv("GEODE_MASTER_KEY");
}

fn encryptField(type_name: []const u8, field: []const u8, searchable: bool) !void {
    const catalog = try fle_catalog.globalCatalog(testing.allocator);
    var roles = [_][]const u8{"pii"};
    try catalog.configureField(type_name, .{
        .field_name = field,
        .encryption = .{ .enabled = true },
        .search = .{ .enabled = searchable },
        .visibility = .{ .to_roles = &roles },
    });
    fle_integration.setHasEncryptedFields(true);
}

/// Encrypt `plain` as record `record_id` of `type_name`.`field`, on
/// `allocator`, and return a copy owned by `out`.
fn encryptCopy(allocator: std.mem.Allocator, out: std.mem.Allocator, type_name: []const u8, field: []const u8, plain: []const u8, record_id: []const u8) ![]u8 {
    const ctx = fle_integration.EncryptionContext{ .tenant_id = "default", .schema_name = type_name, .allocator = allocator };
    const env = try fle_integration.encryptFieldIfNeeded(ctx, type_name, field, plain, record_id);
    if (env.ptr == plain.ptr) return error.NotEncrypted;
    return out.dupe(u8, env);
}

fn decrypt(type_name: []const u8, field: []const u8, envelope: []const u8, record_id: []const u8) ![]const u8 {
    const ctx = fle_integration.EncryptionContext{ .tenant_id = "default", .schema_name = type_name, .allocator = testing.allocator };
    return fle_integration.decryptFieldIfNeeded(ctx, type_name, field, envelope, record_id, false);
}

test "SONNY-2670: the key manager made by a first encrypt under a transient arena outlives the arena" {
    fleUp();
    defer fleDown();
    try encryptField("T2670", "ssn", false);

    // The first encrypt in the process, on an arena that is then torn down
    // (as a request arena is at the end of the request).
    var first = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const env1 = try encryptCopy(first.allocator(), testing.allocator, "T2670", "ssn", "first", "1");
    defer testing.allocator.free(env1);
    first.deinit();

    // The singleton is used afterwards, on another allocator.
    const env2 = try encryptCopy(testing.allocator, testing.allocator, "T2670", "ssn", "second", "2");
    defer testing.allocator.free(env2);
    const p1 = try decrypt("T2670", "ssn", env1, "1");
    defer testing.allocator.free(p1);
    const p2 = try decrypt("T2670", "ssn", env2, "2");
    defer testing.allocator.free(p2);
    try testing.expectEqualStrings("first", p1);
    try testing.expectEqualStrings("second", p2);
}

test "SONNY-2670: the blind index made by a first searchable encrypt under a transient arena outlives the arena" {
    fleUp();
    defer fleDown();
    // `configureField` (the CALL) refuses searchable fields (SONNY-6335);
    // the catalog API, as a deployment that predates that, still has them.
    try encryptField("S2670", "email", true);

    var first = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const env1 = try encryptCopy(first.allocator(), testing.allocator, "S2670", "email", "a@example.com", "1");
    defer testing.allocator.free(env1);
    first.deinit();

    // A second searchable encrypt adds to the blind index made above.
    const env2 = try encryptCopy(testing.allocator, testing.allocator, "S2670", "email", "b@example.com", "2");
    defer testing.allocator.free(env2);
    const p2 = try decrypt("S2670", "email", env2, "2");
    defer testing.allocator.free(p2);
    try testing.expectEqualStrings("b@example.com", p2);
}

test "SONNY-2670: on an FLE deployment the node-scan WHERE frees what it reads (runs on its scratch arena)" {
    harness.silenceEngineLogs();
    var h = try harness.Harness.init(testing.allocator);
    defer h.deinit();
    fleUp();
    defer fleDown();
    // An encrypted field elsewhere: FLE is on for the deployment.
    try encryptField("Other2670", "x", false);

    try h.seed(&.{
        "CREATE (:K2670 {s: 'k0', v: Text('hello')})",
        "CREATE (:K2670 {s: 'k1', v: Text('world')})",
        "CREATE (:K2670 {s: 'k2', v: Text('again')})",
    });
    var qa = std.heap.ArenaAllocator.init(testing.allocator);
    defer qa.deinit();

    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = counting.allocator();
    var rows: usize = 0;
    {
        var stream = try harness.openStream(&h, allocator, &qa, "MATCH (n:K2670) WHERE n.v IS NOT NULL RETURN n.s");
        defer stream.deinit();
        var pages: usize = 0;
        while (true) : (pages += 1) {
            if (pages > 5) return error.NeverFinal;
            var page = try stream.buildNextPage(allocator, 2);
            defer page.result.deinit(allocator);
            rows += page.result.rows.len;
            if (page.final) break;
        }
    }
    try testing.expectEqual(@as(usize, 3), rows);
    const leaked = counting.allocations - counting.deallocations;
    if (leaked != 0) std.debug.print("the WHERE leaked {d} allocations on the stream's allocator\n", .{leaked});
    try testing.expectEqual(@as(usize, 0), leaked);
}
