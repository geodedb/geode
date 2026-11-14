// SONNY-6517 item 1: an allocation failure while parsing is OutOfMemory,
// never a syntax error.
//
// `parseGqlOutcome` (src/lib.zig), the parse entry point of the QUIC and
// gRPC servers, the LSP and the `gql` tool, caught every parser error and
// answered it as a refused statement with the error's SQLSTATE, and
// `parseErrorCode` gives 42000 to anything it does not list: a request
// that ran out of memory while parsing was told its statement was a syntax
// error. The parser's own fallbacks swallowed it too (a speculative MATCH
// ... DELETE look-ahead, an identifier's case fold, the text of an error
// message). Each statement below is parsed with its N-th allocation failing,
// for every N, and must answer error.OutOfMemory with nothing leaked
// (`std.testing.checkAllAllocationFailures`).
//
// CANARY: REQ=REQ-SONNY-6517-PARSE-OOM; FEATURE="ParserErrors"; ASPECT=OutOfMemoryIdentity; STATUS=TESTED; TEST=tests/test_sonny6517_parse_oom.zig; OWNER=parser; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

fn parseOnce(allocator: std.mem.Allocator, src: []const u8) !void {
    var outcome = try geode.parseGqlOutcome(src, allocator, .{});
    defer outcome.deinit();
    switch (outcome) {
        .Ok => {},
        .Err => |e| {
            std.debug.print("{s}: refused as {s} ({s})\n", .{ src, e.code, e.msg });
            return error.ReportedAsRefusal;
        },
    }
}

const statements = [_][]const u8{
    "RETURN 1 AS x",
    "MATCH (n:Person {name: 'a'}) WHERE n.age > 30 RETURN n.name AS name ORDER BY name LIMIT 5",
    "MATCH (a)-[r:KNOWS*1..3]->(b) WITH a, count(b) AS c WHERE c > 1 RETURN a, c",
    "MATCH (n) WHERE n.k IN (MATCH (m) WHERE m.t = n.t RETURN m.k) RETURN n",
    "MATCH (n:X) DELETE n",
    "MATCH (n:X) WHERE n.k = 1 DETACH DELETE n",
    "CREATE (:A {k: 1})-[:R {w: 2}]->(:B {s: 'x'})",
    "FOR x IN [1, 2, 3] RETURN x * 2 AS y",
    "CREATE GRAPH TYPE T AS { x STRING, n INTEGER }",
};

test "SONNY-6517: an allocation failure while parsing is OutOfMemory, never a syntax error" {
    for (statements) |src| {
        testing.checkAllAllocationFailures(testing.allocator, parseOnce, .{src}) catch |err| {
            std.debug.print("statement: {s}\n", .{src});
            return err;
        };
    }
}
