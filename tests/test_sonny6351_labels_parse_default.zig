// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6351 items 2 and 3.
//
//   2. `CALL db.labels()` on a session whose user an RLS label policy denies
//      `:Hidden` listed 'Hidden': the label of rows the user may not read.
//      Run through the SONNY-2672 batch harness (in-memory, persisted,
//      tenant-scoped and RLS-policy sessions; only the RLS session has a
//      `:X:Hidden` node, and its user `bob` is denied `:Hidden`).
//   3. The embedded `geode.parseGql` refused every ORDER BY key that is not a
//      bare identifier unless `GEODE_ORDER_KEYS_EXPR` was set, while the
//      server accepts expressions by default (ISO/IEC 39075:2024 16.16: a
//      sort key is a value expression). `GEODE_ORDER_KEYS_EXPR=0` keeps the
//      opt-in identifier-only policy, as on the server.
//
// CANARY: REQ=REQ-SONNY-6351-LABELS-PARSE-DEFAULT; FEATURE="ReadSemanticsBatch"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6351_labels_parse_default.zig; OWNER=engine; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const batch = @import("test_sonny2672_read_semantics_batch.zig");

const Case = batch.Case;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// Item 2: the labels the session may read, and no other.
const item2 = [_]Case{
    .{ .q = "CALL db.labels() YIELD label RETURN label ORDER BY label", .want = &.{ "'Q'", "'X'", "'Y'", "'Z'" }, .ordered = true },
    .{ .q = "CALL db.labels() YIELD label RETURN count(*) AS c", .want = &.{"4"} },
    .{ .q = "CALL db.labels() YIELD label RETURN label ORDER BY label LIMIT 1", .want = &.{"'Q'"} },
};

test "SONNY-6351 item 2: db.labels() omits a label the session's RLS policy denies" {
    try batch.inEveryMode("SONNY-6351 item 2", &item2);
}

test "SONNY-6351 item 3: the embedded parseGql accepts an expression ORDER BY key by default" {
    _ = unsetenv("GEODE_ORDER_KEYS_EXPR");
    const queries = [_][]const u8{
        "MATCH (n:N) RETURN n ORDER BY n.k",
        "MATCH (n:N) RETURN n.k AS k ORDER BY n.k + 1 DESC",
        "MATCH (n:N) RETURN n.s AS s ORDER BY lower(n.s)",
    };
    for (queries) |q| {
        var parsed = geode.parseGql(q, testing.allocator) catch |err| {
            std.debug.print("SONNY-6351: parseGql refused {s}: {s}\n", .{ q, @errorName(err) });
            return err;
        };
        parsed.deinit();
    }

    // The opt-in identifier-only policy, as the server's.
    if (setenv("GEODE_ORDER_KEYS_EXPR", "0", 1) != 0) return error.SetEnvFailed;
    defer _ = unsetenv("GEODE_ORDER_KEYS_EXPR");
    try testing.expectError(error.UnexpectedToken, geode.parseGql("MATCH (n:N) RETURN n ORDER BY n.k", testing.allocator));
    var ident = try geode.parseGql("MATCH (n:N) RETURN n.k AS k ORDER BY k", testing.allocator);
    ident.deinit();
    // Set to 1 (or empty), expressions are allowed, as on the server.
    if (setenv("GEODE_ORDER_KEYS_EXPR", "1", 1) != 0) return error.SetEnvFailed;
    var expr = try geode.parseGql("MATCH (n:N) RETURN n ORDER BY n.k", testing.allocator);
    expr.deinit();
}
