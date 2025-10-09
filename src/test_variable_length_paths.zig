const std = @import("std");
const testing = std.testing;
const lib = @import("lib.zig");
const execution = @import("execution.zig");
const graph_store = @import("graph_store.zig");

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=ParserTests; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "Variable-length path parsing: *" {
    const query = "MATCH (a)-[r:KNOWS*]->(b) RETURN a, b";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;

    try testing.expect(prog.statements.len == 1);
    const stmt = prog.statements[0];
    try testing.expect(stmt == .Query);

    const q = stmt.Query;
    try testing.expect(q.match.chains.len == 1);
    const chain = q.match.chains[0];
    try testing.expect(chain.hops.len == 1);

    const hop = chain.hops[0];
    try testing.expect(hop.rel.min_len.? == 0);
    try testing.expect(hop.rel.max_len == null);
}

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=ParserTests; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "Variable-length path parsing: *2" {
    const query = "MATCH (a)-[r:KNOWS*2]->(b) RETURN a, b";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;

    const stmt = prog.statements[0];
    const q = stmt.Query;
    const hop = q.match.chains[0].hops[0];

    try testing.expect(hop.rel.min_len.? == 2);
    try testing.expect(hop.rel.max_len.? == 2);
}

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=ParserTests; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "Variable-length path parsing: *1..3" {
    const query = "MATCH (a)-[r:KNOWS*1..3]->(b) RETURN a, b";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;

    const stmt = prog.statements[0];
    const q = stmt.Query;
    const hop = q.match.chains[0].hops[0];

    try testing.expect(hop.rel.min_len.? == 1);
    try testing.expect(hop.rel.max_len.? == 3);
}

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=ParserTests; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "Variable-length path parsing: *..3" {
    const query = "MATCH (a)-[r:KNOWS*..3]->(b) RETURN a, b";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;

    const stmt = prog.statements[0];
    const q = stmt.Query;
    const hop = q.match.chains[0].hops[0];

    try testing.expect(hop.rel.min_len.? == 0);
    try testing.expect(hop.rel.max_len.? == 3);
}

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=ParserTests; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "Variable-length path parsing: *2.." {
    const query = "MATCH (a)-[r:KNOWS*2..]->(b) RETURN a, b";
    var parse_result = try lib.parseGql(query, testing.allocator);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;

    const stmt = prog.statements[0];
    const q = stmt.Query;
    const hop = q.match.chains[0].hops[0];

    try testing.expect(hop.rel.min_len.? == 2);
    try testing.expect(hop.rel.max_len == null);
}

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=ExecutionTests; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "Variable-length path execution: basic path expansion" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    // Create a simple graph: (a)-[:KNOWS]->(b)-[:KNOWS]->(c)
    const store = graph_store.getGlobalStore(ally);
    store.clearNodes();

    // Create nodes
    const labels_empty = try ally.alloc([]const u8, 0);
    const a_id = try store.createNode(labels_empty);
    const b_id = try store.createNode(labels_empty);
    const c_id = try store.createNode(labels_empty);

    try store.setNodeProperty(a_id, "name", .{ .String = "Alice" });
    try store.setNodeProperty(b_id, "name", .{ .String = "Bob" });
    try store.setNodeProperty(c_id, "name", .{ .String = "Charlie" });

    // Create edges
    _ = try store.createEdge(a_id, b_id, "KNOWS");
    _ = try store.createEdge(b_id, c_id, "KNOWS");

    // Test query: MATCH (a)-[r:KNOWS*1..2]->(x) WHERE a.name = 'Alice' RETURN x.name
    const query = "MATCH (a)-[r:KNOWS*1..2]->(x) WHERE a.name = 'Alice' RETURN x.name";
    var parse_result = try lib.parseGql(query, ally);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;

    var result = try execution.executeProgram(ally, &prog);
    defer result.deinit(ally);

    // Should find both Bob (1 hop) and Charlie (2 hops)
    try testing.expect(result.rows.len == 2);
}

// CANARY: REQ=REQ-GQL-080; FEATURE="VariableLengthPaths"; ASPECT=ExecutionTests; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09
test "Variable-length path execution: cycle detection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    // Create a cyclic graph: (a)-[:KNOWS]->(b)-[:KNOWS]->(a)
    const store = graph_store.getGlobalStore(ally);
    store.clearNodes();

    const labels_empty = try ally.alloc([]const u8, 0);
    const a_id = try store.createNode(labels_empty);
    const b_id = try store.createNode(labels_empty);

    try store.setNodeProperty(a_id, "name", .{ .String = "Alice" });
    try store.setNodeProperty(b_id, "name", .{ .String = "Bob" });

    _ = try store.createEdge(a_id, b_id, "KNOWS");
    _ = try store.createEdge(b_id, a_id, "KNOWS");

    // Test query: MATCH (a)-[r:KNOWS*1..5]->(x) WHERE a.name = 'Alice' RETURN x.name
    const query = "MATCH (a)-[r:KNOWS*1..5]->(x) WHERE a.name = 'Alice' RETURN x.name";
    var parse_result = try lib.parseGql(query, ally);
    defer parse_result.arena.deinit();

    const prog = parse_result.program;

    var result = try execution.executeProgram(ally, &prog);
    defer result.deinit(ally);

    // Should only find Bob (1 hop), not cycle back to Alice
    try testing.expect(result.rows.len == 1);
}
