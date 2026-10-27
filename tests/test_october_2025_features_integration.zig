const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const execution = geode.execution;
const graph_store = geode.graph_store;
const query_arena = geode.query_arena;

// CANARY: REQ=REQ-GQL-INTEGRATION-001; FEATURE="October2025Features"; ASPECT=Integration; STATUS=TESTED; OWNER=engine; UPDATED=2025-10-09

fn makeContext(allocator: std.mem.Allocator) !execution.ExecutionContext {
    const catalog = try execution.ensureCatalogInstance(allocator);
    return execution.ExecutionContext{ .catalog = catalog };
}

/// SONNY-2394: per-test isolated global store + catalog. These tests used the
/// process-global store / catalog / undo log without ever releasing them, so
/// every allocation those singletons made on std.testing.allocator was
/// reported as a leak by whichever test first touched them, and the store
/// persisted into the shared default data dir. Each test now gets its own tmp
/// data dir and releases the globals on exit (the teardown order of
/// tests/test_gap0839_tenant_lifecycle.zig: store, then catalog).
///
/// It also installs a query scratch arena, as every production entry point
/// does (quic_connection_handler / grpc_server / query_coordinator push one
/// per query): row materialization allocates node interiors from the scratch
/// allocator (REQ-EXEC-MATERIALIZE-OWNERSHIP), which falls back to the
/// caller's allocator -- and leaks per row -- when none is installed. Heap-
/// allocated so the pushed allocator stays valid after `init` returns.
const Env = struct {
    tmp: std.testing.TmpDir,
    store: *graph_store.GraphStore,
    scratch: *std.heap.ArenaAllocator,
    prev_scratch: ?std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !Env {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        defer allocator.free(dir);
        const store = try graph_store.initGlobalStore(allocator, dir);
        errdefer graph_store.deinitGlobalStore();
        const scratch = try allocator.create(std.heap.ArenaAllocator);
        scratch.* = std.heap.ArenaAllocator.init(allocator);
        return .{
            .tmp = tmp,
            .store = store,
            .scratch = scratch,
            .prev_scratch = query_arena.pushScratchAllocator(scratch.allocator()),
        };
    }

    fn deinit(self: *Env) void {
        query_arena.popScratchAllocator(self.prev_scratch);
        self.scratch.deinit();
        testing.allocator.destroy(self.scratch);
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
        graph_store.setDataDirOverride(testing.allocator, null);
        self.tmp.cleanup();
    }
};

// Zig 0.16 has no std.Io.Dir realpath: rebuild the absolute tmp-dir path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Integration test: FILTER clause with complex graph patterns
test "Integration: FILTER clause with relationship patterns" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();
    const store = env.store;

    // Create a social network
    const labels_person = try allocator.alloc([]const u8, 1);
    defer allocator.free(labels_person);
    labels_person[0] = "Person";

    const alice_id = try store.createNode(labels_person);
    const bob_id = try store.createNode(labels_person);
    const carol_id = try store.createNode(labels_person);

    try store.setNodeProperty(alice_id, "name", .{ .String = "Alice" });
    try store.setNodeProperty(alice_id, "age", .{ .Int = 30 });
    try store.setNodeProperty(alice_id, "city", .{ .String = "Seattle" });

    try store.setNodeProperty(bob_id, "name", .{ .String = "Bob" });
    try store.setNodeProperty(bob_id, "age", .{ .Int = 25 });
    try store.setNodeProperty(bob_id, "city", .{ .String = "Portland" });

    try store.setNodeProperty(carol_id, "name", .{ .String = "Carol" });
    try store.setNodeProperty(carol_id, "age", .{ .Int = 35 });
    try store.setNodeProperty(carol_id, "city", .{ .String = "Seattle" });

    _ = try store.createEdge(alice_id, bob_id, "KNOWS");
    _ = try store.createEdge(alice_id, carol_id, "KNOWS");

    // Query with FILTER
    const query =
        \\MATCH (a:Person)-[r]->(b:Person)
        \\WHERE a.name = 'Alice'
        \\FILTER b.city = 'Seattle'
        \\RETURN b.name AS friend
    ;

    var parse_result = try geode.parseGql(query, allocator);
    defer parse_result.arena.deinit();

    const context = try makeContext(allocator);
    var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
    defer result.deinit(allocator);

    // Should only return Carol (Seattle), not Bob (Portland)
    try testing.expect(result.rows.len == 1);
    try testing.expect(result.rows[0][0] == .Str);
    try testing.expect(std.mem.eql(u8, result.rows[0][0].Str, "Carol"));
}

// Integration test: type() function with real relationships
test "Integration: type() function returns relationship labels" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();
    const store = env.store;

    const labels_empty = try allocator.alloc([]const u8, 0);
    defer allocator.free(labels_empty);

    const n1 = try store.createNode(labels_empty);
    const n2 = try store.createNode(labels_empty);
    const n3 = try store.createNode(labels_empty);

    _ = try store.createEdge(n1, n2, "KNOWS");
    _ = try store.createEdge(n1, n3, "LIKES");

    const query = "MATCH (a)-[r]->(b) RETURN type(r) AS rel_type";

    var parse_result = try geode.parseGql(query, allocator);
    defer parse_result.arena.deinit();

    const context = try makeContext(allocator);
    var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
    defer result.deinit(allocator);

    // Should return 2 rows with relationship types
    try testing.expect(result.rows.len == 2);

    // Collect all relationship types
    var found_knows = false;
    var found_likes = false;

    for (result.rows) |row| {
        try testing.expect(row[0] == .Str);
        if (std.mem.eql(u8, row[0].Str, "KNOWS")) found_knows = true;
        if (std.mem.eql(u8, row[0].Str, "LIKES")) found_likes = true;
    }

    try testing.expect(found_knows);
    try testing.expect(found_likes);
}

// Integration test: SET label operations in complex query
test "Integration: SET label operations with CREATE and MATCH" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();
    const store = env.store;

    // Create node and add labels dynamically
    const create_query = "CREATE (n:Person {name: 'Alice', age: 30}) RETURN n";

    var create_result = try geode.parseGql(create_query, allocator);
    defer create_result.arena.deinit();

    const context = try makeContext(allocator);
    var create_exec = try execution.executeProgramWithContext(allocator, &create_result.program, context);
    defer create_exec.deinit(allocator);

    // Add Employee label
    const set_query = "MATCH (n:Person) WHERE n.name = 'Alice' SET n:Employee RETURN n";

    var set_result = try geode.parseGql(set_query, allocator);
    defer set_result.arena.deinit();

    var set_exec = try execution.executeProgramWithContext(allocator, &set_result.program, context);
    defer set_exec.deinit(allocator);

    // Verify label was added by checking the store
    var iter = store.nodes.iterator();
    var found_employee = false;
    while (iter.next()) |entry| {
        const node = entry.value_ptr;
        for (node.labels) |label| {
            if (std.mem.eql(u8, label, "Employee")) {
                found_employee = true;
                break;
            }
        }
    }

    try testing.expect(found_employee);
}

// Integration test: Variable-length paths with filtering
test "Integration: Variable-length paths in social network" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();
    const store = env.store;

    // Create a chain: A -> B -> C -> D
    const labels_empty = try allocator.alloc([]const u8, 0);
    defer allocator.free(labels_empty);

    const a_id = try store.createNode(labels_empty);
    const b_id = try store.createNode(labels_empty);
    const c_id = try store.createNode(labels_empty);
    const d_id = try store.createNode(labels_empty);

    try store.setNodeProperty(a_id, "name", .{ .String = "Alice" });
    try store.setNodeProperty(b_id, "name", .{ .String = "Bob" });
    try store.setNodeProperty(c_id, "name", .{ .String = "Carol" });
    try store.setNodeProperty(d_id, "name", .{ .String = "Dave" });

    _ = try store.createEdge(a_id, b_id, "KNOWS");
    _ = try store.createEdge(b_id, c_id, "KNOWS");
    _ = try store.createEdge(c_id, d_id, "KNOWS");

    // Find friends within 2 hops
    const query =
        \\MATCH (a)-[r:KNOWS*1..2]->(friend)
        \\WHERE a.name = 'Alice'
        \\RETURN friend.name AS name
    ;

    var parse_result = try geode.parseGql(query, allocator);
    defer parse_result.arena.deinit();

    const context = try makeContext(allocator);
    var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
    defer result.deinit(allocator);

    // Should find Bob (1 hop) and Carol (2 hops), but not Dave (3 hops)
    try testing.expect(result.rows.len == 2);

    var found_bob = false;
    var found_carol = false;

    for (result.rows) |row| {
        try testing.expect(row[0] == .Str);
        if (std.mem.eql(u8, row[0].Str, "Bob")) found_bob = true;
        if (std.mem.eql(u8, row[0].Str, "Carol")) found_carol = true;
    }

    try testing.expect(found_bob);
    try testing.expect(found_carol);
}

// Integration test: Session management with graph switching
test "Integration: Session management graph switching" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();

    // Create session state
    var session_state = execution.SessionState.init(allocator);
    defer session_state.deinit();

    // SONNY-2775: SESSION SET GRAPH checks that the graph exists.
    try env.store.createGraph("test_graph");

    // Set graph
    const set_query = "SESSION SET GRAPH test_graph";
    var set_result = try geode.parseGql(set_query, allocator);
    defer set_result.arena.deinit();

    var context = try makeContext(allocator);
    context.session_state = &session_state;
    var exec_result = try execution.executeStatementWithContext(allocator, set_result.program.statements[0], context);
    defer exec_result.deinit(allocator);

    // Verify graph was set
    try testing.expect(session_state.graph != null);
    try testing.expect(std.mem.eql(u8, session_state.graph.?, "test_graph"));

    // Reset graph
    const reset_query = "SESSION RESET GRAPH";
    var reset_result = try geode.parseGql(reset_query, allocator);
    defer reset_result.arena.deinit();

    var reset_exec = try execution.executeStatementWithContext(allocator, reset_result.program.statements[0], context);
    defer reset_exec.deinit(allocator);

    // Verify graph was reset
    try testing.expect(session_state.graph == null);
}

// Integration test: Transaction lifecycle
test "Integration: Transaction lifecycle START/COMMIT/ROLLBACK" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();

    // Start transaction
    const start_query = "START TRANSACTION";
    var start_result = try geode.parseGql(start_query, allocator);
    defer start_result.arena.deinit();

    var context = try makeContext(allocator);
    var start_exec = try execution.executeStatementWithContext(allocator, start_result.program.statements[0], context);
    defer start_exec.deinit(allocator);

    // Verify transaction started
    try testing.expect(start_exec.rows.len == 1);
    try testing.expect(start_exec.rows[0][0] == .Str);

    // Commit transaction
    context.transaction_state = .Active;
    const commit_query = "COMMIT";
    var commit_result = try geode.parseGql(commit_query, allocator);
    defer commit_result.arena.deinit();

    var commit_exec = try execution.executeStatementWithContext(allocator, commit_result.program.statements[0], context);
    defer commit_exec.deinit(allocator);

    try testing.expect(commit_exec.rows.len == 1);
}

// Integration test: Combined features in realistic scenario
test "Integration: Combined features - social network analysis" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();
    const store = env.store;

    // Create session
    var session_state = execution.SessionState.init(allocator);
    defer session_state.deinit();

    // SONNY-2775: SESSION SET GRAPH checks that the graph exists.
    try store.createGraph("social_network");

    // Set up session
    const session_query = "SESSION SET GRAPH social_network";
    var session_result = try geode.parseGql(session_query, allocator);
    defer session_result.arena.deinit();

    var context = try makeContext(allocator);
    context.session_state = &session_state;
    var session_exec = try execution.executeStatementWithContext(allocator, session_result.program.statements[0], context);
    defer session_exec.deinit(allocator);

    // Create network
    const labels_person = try allocator.alloc([]const u8, 1);
    defer allocator.free(labels_person);
    labels_person[0] = "Person";

    // SONNY-2394: the session above selects graph `social_network`, and MATCH
    // is graph-scoped, so the fixture must live in that graph -- created in
    // the default graph (store.createNode/createEdge) the query saw 0 rows.
    const social = "social_network";
    const alice_id = try store.createNodeWithGraph(labels_person, social);
    const bob_id = try store.createNodeWithGraph(labels_person, social);
    const carol_id = try store.createNodeWithGraph(labels_person, social);
    const dave_id = try store.createNodeWithGraph(labels_person, social);

    try store.setNodeProperty(alice_id, "name", .{ .String = "Alice" });
    try store.setNodeProperty(alice_id, "age", .{ .Int = 30 });
    try store.setNodeProperty(alice_id, "city", .{ .String = "Seattle" });

    try store.setNodeProperty(bob_id, "name", .{ .String = "Bob" });
    try store.setNodeProperty(bob_id, "age", .{ .Int = 25 });
    try store.setNodeProperty(bob_id, "city", .{ .String = "Portland" });

    try store.setNodeProperty(carol_id, "name", .{ .String = "Carol" });
    try store.setNodeProperty(carol_id, "age", .{ .Int = 35 });
    try store.setNodeProperty(carol_id, "city", .{ .String = "Seattle" });

    try store.setNodeProperty(dave_id, "name", .{ .String = "Dave" });
    try store.setNodeProperty(dave_id, "age", .{ .Int = 40 });
    try store.setNodeProperty(dave_id, "city", .{ .String = "Seattle" });

    _ = try store.createEdgeWithGraph(alice_id, bob_id, "KNOWS", social);
    _ = try store.createEdgeWithGraph(bob_id, carol_id, "KNOWS", social);
    _ = try store.createEdgeWithGraph(carol_id, dave_id, "KNOWS", social);
    _ = try store.createEdgeWithGraph(alice_id, carol_id, "KNOWS", social);

    // Complex query combining all features:
    // - Variable-length paths (1..2 hops)
    // - type() function
    // - FILTER clause
    // - SET label operation
    const query =
        \\MATCH (a:Person)-[r:KNOWS*1..2]->(friend:Person)
        \\WHERE a.name = 'Alice'
        \\FILTER friend.city = 'Seattle' AND friend.age > 30
        \\RETURN friend.name AS name, type(r) AS relationship
    ;

    var parse_result = try geode.parseGql(query, allocator);
    defer parse_result.arena.deinit();

    var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
    defer result.deinit(allocator);

    // Should find Carol (1 hop, Seattle, age 35) and Dave (2 hops, Seattle, age 40)
    // But not Bob (Portland)
    try testing.expect(result.rows.len >= 1);

    // Verify at least one result matches our criteria
    var found_valid = false;
    for (result.rows) |row| {
        if (row[0] == .Str) {
            const name = row[0].Str;
            if (std.mem.eql(u8, name, "Carol") or std.mem.eql(u8, name, "Dave")) {
                found_valid = true;
                break;
            }
        }
    }

    try testing.expect(found_valid);
}

// Integration test: Error handling in transactions
test "Integration: Transaction error handling" {
    const allocator = testing.allocator;
    var env = try Env.init(allocator);
    defer env.deinit();

    // Try to commit without active transaction
    const commit_query = "COMMIT";
    var commit_result = try geode.parseGql(commit_query, allocator);
    defer commit_result.arena.deinit();

    const context = try makeContext(allocator);
    var result = try execution.executeStatementWithContext(allocator, commit_result.program.statements[0], context);
    defer result.deinit(allocator);

    // SONNY-2394: this used to expect error.NoActiveTransaction. Since
    // 2025-10-12 (after this test was written) COMMIT without an active
    // transaction is a deliberate no-op per the SQL/GQL standards
    // (execution.zig `.Commit`, REQ-GQL-082): it succeeds with a status row.
    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try testing.expect(result.rows[0][0] == .Str);
    try testing.expectEqualStrings("no transaction active", result.rows[0][0].Str);

    // Try to start transaction when one is already active
    const start_query = "START TRANSACTION";
    var start_result = try geode.parseGql(start_query, allocator);
    defer start_result.arena.deinit();

    var active_context = try makeContext(allocator);
    active_context.transaction_state = .Active;
    const start_twice = execution.executeStatementWithContext(allocator, start_result.program.statements[0], active_context);

    // Should return TransactionAlreadyActive error
    try testing.expectError(error.TransactionAlreadyActive, start_twice);
}

// Integration test: Memory leak prevention
test "Integration: Memory management in complex scenarios" {
    const allocator = testing.allocator;

    // Run multiple iterations to detect memory leaks. SONNY-2394: each
    // iteration gets a fresh isolated store. It used to "reset" with
    // store.clearNodes(), which only wipes the in-memory cache (the reload
    // primitive loadFromFile uses) and leaves the durable engine's edges in
    // place; the next engine read then found edge slots whose IdMap entries
    // had been cleared (error.EdgeSlotMappingMissing).
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var env = try Env.init(allocator);
        defer env.deinit();
        const store = env.store;

        // Create and destroy nodes
        const labels_empty = try allocator.alloc([]const u8, 0);
        defer allocator.free(labels_empty);

        const n1 = try store.createNode(labels_empty);
        const n2 = try store.createNode(labels_empty);

        _ = try store.createEdge(n1, n2, "KNOWS");

        // Run query
        const query = "MATCH (a)-[r]->(b) RETURN type(r)";
        var parse_result = try geode.parseGql(query, allocator);
        defer parse_result.arena.deinit();

        const context = try makeContext(allocator);
        var result = try execution.executeProgramWithContext(allocator, &parse_result.program, context);
        defer result.deinit(allocator);
    }

    // If we reach here without OOM, memory management is working
    try testing.expect(true);
}
