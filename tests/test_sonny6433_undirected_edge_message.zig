// SONNY-6433 item 8: an undirected edge pattern is refused with a message
// that says so.
//
// ISO/IEC 39075:2024 16.5 <insert graph pattern> and 16.7 <edge pattern>
// spell an undirected edge `~[ ]~` (<full edge undirected>), with the
// abbreviation `~`, and the mixed forms `<~[ ]~`, `~[ ]~>`, `<~` and `~>`;
// all of them are Feature GH02, "Undirected edge patterns", which Geode does
// not support (it stores directed edges only). The lexer has no `~` token,
// so `CREATE (a:W)~[:T]~(b:W)` was refused with a generic parse message at
// the `~` that did not say why. It is now refused with SQLSTATE 0A000
// (feature not supported) and a message naming undirected edge patterns,
// in CREATE, INSERT and MATCH alike; `=~` and `!~` (regex match) are
// untouched.
//
// CANARY: REQ=REQ-SONNY-6433-UNDIRECTED-EDGE-MESSAGE; FEATURE="Parser"; ASPECT=UndirectedEdgeRefusal; STATUS=TESTED; TEST=tests/test_sonny6433_undirected_edge_message.zig; OWNER=parser; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

fn expectUndirectedRefusal(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var outcome = try geode.parseGqlOutcome(src, arena.allocator(), .{});
    defer outcome.deinit();
    switch (outcome) {
        .Ok => {
            std.debug.print("'{s}' parsed; expected a refusal\n", .{src});
            return error.ExpectedRefusal;
        },
        .Err => |e| {
            const names_it = std.mem.indexOf(u8, e.msg, "undirected edge") != null;
            if (!names_it or !std.mem.eql(u8, e.code, "0A000"))
                std.debug.print("'{s}': {s} {s}\n", .{ src, e.code, e.msg });
            try testing.expect(names_it);
            try testing.expectEqualStrings("0A000", e.code);
        },
    }
}

fn expectParses(src: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var outcome = try geode.parseGqlOutcome(src, arena.allocator(), .{});
    defer outcome.deinit();
    switch (outcome) {
        .Ok => {},
        .Err => |e| {
            std.debug.print("'{s}': {s} {s}\n", .{ src, e.code, e.msg });
            return error.UnexpectedRefusal;
        },
    }
}

test "SONNY-6433: an undirected edge pattern is refused with 0A000 naming it" {
    try expectUndirectedRefusal("CREATE (a:W)~[:T]~(b:W)");
    try expectUndirectedRefusal("INSERT (a:W)~[:T]~(b:W)");
    try expectUndirectedRefusal("MATCH (a:W)~[r:T]~(b:W) RETURN r");
    try expectUndirectedRefusal("MATCH (a)~(b) RETURN a");
    try expectUndirectedRefusal("MATCH (a)~[:T]~>(b) RETURN a");
    try expectUndirectedRefusal("MATCH (a)<~[:T]~(b) RETURN a");
    try expectUndirectedRefusal("MATCH (a)<~(b) RETURN a");
    try expectUndirectedRefusal("MATCH (a)-[:T]->(b)~[:U]~(c) RETURN c");
}

test "SONNY-6433: directed, any-direction and regex forms still parse" {
    try expectParses("CREATE (a:W)-[:T]->(b:W)");
    try expectParses("MATCH (a:W)-[r:T]-(b:W) RETURN r");
    try expectParses("MATCH (a)<-[:T]-(b) RETURN a");
    try expectParses("MATCH (n) WHERE n.name =~ 'a.*' RETURN n");
    try expectParses("MATCH (n) WHERE n.name !~ 'a.*' RETURN n");
}
