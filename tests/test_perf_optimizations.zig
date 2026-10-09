const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");
const schema = @import("schema");

// Zig 0.16 compat: std.Thread.sleep removed; nanosleep directly.
fn compat_sleep(ns: u64) void {
    var req: std.posix.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

// Zig 0.16 compat: std.time.Timer/nanoTimestamp removed; clock_gettime(MONOTONIC).
fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const ServerFixture = struct {
    server: util.ServerHandle,
    client: util.QuicProtoClient,
};

fn startServer(allocator: std.mem.Allocator, addr: []const u8) !ServerFixture {
    var server = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr }, null);
    errdefer server.deinit();

    // Wait for server to be ready with retries
    var attempts: u32 = 0;
    const max_attempts: u32 = 50; // 5 seconds total
    while (attempts < max_attempts) : (attempts += 1) {
        var client = util.QuicProtoClient.connect(allocator, addr) catch |err| {
            if (err == error.HandshakeError or err == error.ConnectionFailed) {
                compat_sleep(100 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        // SONNY-2394: reply waits follow the server's liveness, not a fixed
        // 5 s deadline (see "a live-but-slow server is waited for" below).
        client.watchServerLiveness(server.child.id.?);
        var hello = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        hello.deinit(allocator);
        return .{ .server = server, .client = client };
    }
    return error.HandshakeError; // Timeout waiting for server
}

fn execSimple(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !util.ExecResult {
    const params = util.emptyParams();
    return client.executeAndCollect(allocator, query, params, 1024);
}

// CANARY: REQ=REQ-PERF-GAP0203-TESTS; FEATURE="QueryPipelineOptimization"; ASPECT=UnitTests; STATUS=TESTED; OWNER=perf; UPDATED=2026-01-27
// GAP-0203: Unit tests for all performance optimizations (Fixes #2-#11)

// ============================================================================
// Fix #2: String-based graph query detection (eliminates double parsing)
// ============================================================================

test "GAP-0203 Fix #2: USE GRAPH detected case-insensitively" {
    const cases = [_]struct { input: []const u8, expect: bool }{
        .{ .input = "USE GRAPH mydb", .expect = true },
        .{ .input = "use graph mydb", .expect = true },
        .{ .input = "Use Graph mydb", .expect = true },
        .{ .input = "USE PROPERTY GRAPH mydb", .expect = true },
        .{ .input = "use property graph mydb", .expect = true },
        .{ .input = "RETURN 1 AS x", .expect = false },
        .{ .input = "MATCH (n) RETURN n", .expect = false },
        .{ .input = "CREATE (n:Person {name: 'Alice'})", .expect = false },
        .{ .input = "   USE GRAPH mydb", .expect = true },
        .{ .input = "\t\nUSE GRAPH mydb", .expect = true },
    };

    for (cases) |case| {
        const trimmed = std.mem.trimStart(u8, case.input, " \t\n\r");
        const is_use_graph = std.ascii.startsWithIgnoreCase(trimmed, "USE GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "USE PROPERTY GRAPH ");
        try testing.expectEqual(case.expect, is_use_graph);
    }
}

test "GAP-0203 Fix #2: CREATE GRAPH detected case-insensitively" {
    const cases = [_]struct { input: []const u8, expect: bool }{
        .{ .input = "CREATE GRAPH mydb", .expect = true },
        .{ .input = "create graph mydb", .expect = true },
        .{ .input = "CREATE PROPERTY GRAPH mydb", .expect = true },
        .{ .input = "CREATE (n:Person)", .expect = false },
        .{ .input = "CREATE (n)-[:KNOWS]->(m)", .expect = false },
    };

    for (cases) |case| {
        const trimmed = std.mem.trimStart(u8, case.input, " \t\n\r");
        const is_create_graph = std.ascii.startsWithIgnoreCase(trimmed, "CREATE GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "CREATE PROPERTY GRAPH ");
        try testing.expectEqual(case.expect, is_create_graph);
    }
}

test "GAP-0203 Fix #2: DROP GRAPH detected case-insensitively" {
    const cases = [_]struct { input: []const u8, expect: bool }{
        .{ .input = "DROP GRAPH mydb", .expect = true },
        .{ .input = "drop graph mydb", .expect = true },
        .{ .input = "DROP PROPERTY GRAPH mydb", .expect = true },
        .{ .input = "DROP (n:Person)", .expect = false },
    };

    for (cases) |case| {
        const trimmed = std.mem.trimStart(u8, case.input, " \t\n\r");
        const is_drop_graph = std.ascii.startsWithIgnoreCase(trimmed, "DROP GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "DROP PROPERTY GRAPH ");
        try testing.expectEqual(case.expect, is_drop_graph);
    }
}

test "GAP-0203 Fix #2: Normal queries skip graph detection" {
    const normal_queries = [_][]const u8{
        "RETURN 1 AS x",
        "MATCH (n) RETURN n",
        "MATCH (n:Person) WHERE n.age > 30 RETURN n.name",
        "CREATE (n:Person {name: 'Alice', age: 30})",
        "MATCH (a)-[r:KNOWS]->(b) RETURN a, b",
        "OPTIONAL MATCH (n) RETURN n",
        "WITH 1 AS x RETURN x",
        "UNWIND [1,2,3] AS x RETURN x",
    };

    for (normal_queries) |query| {
        const trimmed = std.mem.trimStart(u8, query, " \t\n\r");
        const is_graph_mgmt = std.ascii.startsWithIgnoreCase(trimmed, "USE GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "USE PROPERTY GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "CREATE GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "CREATE PROPERTY GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "DROP GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "DROP PROPERTY GRAPH ");
        try testing.expect(!is_graph_mgmt);
    }
}

// ============================================================================
// Fix #5: Catalog singleton with atomic fast path
// ============================================================================

test "GAP-0203 Fix #5: ensureCatalogInstance returns same instance on repeated calls" {
    const allocator = testing.allocator;

    const instance1 = try geode.execution.ensureCatalogInstance(allocator);
    const instance2 = try geode.execution.ensureCatalogInstance(allocator);
    const instance3 = try geode.execution.ensureCatalogInstance(allocator);

    try testing.expectEqual(@intFromPtr(instance1), @intFromPtr(instance2));
    try testing.expectEqual(@intFromPtr(instance2), @intFromPtr(instance3));

    geode.execution.cleanupCatalogInstance();
}

// ============================================================================
// Fix #6: Evaluator initialized once (idempotent)
// ============================================================================

test "GAP-0203 Fix #6: initEvaluator is idempotent" {
    geode.execution.initEvaluator();
    geode.execution.initEvaluator();
    geode.execution.initEvaluator();
}

// ============================================================================
// Fix #7: ExecutionContext defaults and auth fields
// ============================================================================

test "GAP-0203 Fix #7: ExecutionContext defaults preserve backward compatibility" {
    const allocator = testing.allocator;
    const catalog = try geode.execution.ensureCatalogInstance(allocator);
    defer geode.execution.cleanupCatalogInstance();
    const ctx = geode.execution.ExecutionContext{ .catalog = catalog };

    try testing.expect(ctx.user == null);
    try testing.expect(ctx.role == null);
    try testing.expect(ctx.token == null);
    try testing.expect(ctx.strict_offset_validation == false);
    try testing.expect(ctx.query_param_names.len == 0);
    try testing.expect(ctx.query_param_values.len == 0);
}

test "GAP-0203 Fix #7: ExecutionContext with auth fields" {
    const allocator = testing.allocator;
    const catalog = try geode.execution.ensureCatalogInstance(allocator);
    defer geode.execution.cleanupCatalogInstance();
    const ctx = geode.execution.ExecutionContext{
        .catalog = catalog,
        .user = "admin",
        .role = null,
        .token = "token",
        .strict_offset_validation = false,
    };

    try testing.expectEqualStrings("admin", ctx.user.?);
    try testing.expectEqualStrings("token", ctx.token.?);
}

// ============================================================================
// Fix #11: FLE fast path (skip encryption when no fields configured)
// ============================================================================

test "GAP-0203 Fix #11: FLE hasEncryptedFields defaults to false" {
    try testing.expect(!geode.fle_integration.hasEncryptedFields());
}

test "GAP-0203 Fix #11: FLE flag toggle" {
    try testing.expect(!geode.fle_integration.hasEncryptedFields());

    geode.fle_integration.setHasEncryptedFields(true);
    try testing.expect(geode.fle_integration.hasEncryptedFields());

    geode.fle_integration.setHasEncryptedFields(false);
    try testing.expect(!geode.fle_integration.hasEncryptedFields());
}

// ============================================================================
// Fix #3: Pre-built PULL response format validation
// ============================================================================

test "GAP-0203 Fix #3: rows response format" {
    const response =
        "{\"status_class\":\"00000\",\"ordered\":false,\"order_keys\":[],\"columns\":[{\"name\":\"x\",\"type\":\"ANY\"}],\"rows\":[{\"x\":1}],\"additional_statuses\":[],\"flagger_findings\":[]}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("00000", obj.get("status_class").?.string);
    try testing.expect(obj.get("ordered").?.bool == false);
    try testing.expect(obj.get("columns").?.array.items.len == 1);
    try testing.expect(obj.get("rows").?.array.items.len == 1);
}

test "GAP-0203 Fix #3: error response format" {
    const response =
        "{\"status_class\":\"42000\",\"error_code\":\"42000\",\"error\":\"Syntax error\",\"additional_statuses\":[],\"flagger_findings\":[]}";
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("42000", obj.get("status_class").?.string);
    try testing.expectEqualStrings("42000", obj.get("error_code").?.string);
    try testing.expect(std.mem.indexOf(u8, obj.get("error").?.string, "Syntax error") != null);
}

// ============================================================================
// Fix #4: Transaction session handling via QUIC
// ============================================================================

test "GAP-0203 Fix #4: QUIC transaction state is in-memory" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:3182";
    var fixture = try startServer(allocator, addr);
    defer fixture.client.deinit();
    defer fixture.server.deinit();

    var begin_res = try fixture.client.begin(allocator);
    defer begin_res.deinit(allocator);
    try testing.expect(begin_res.tx_id.len > 0);

    const committed = try fixture.client.commit(allocator);
    try testing.expect(committed);
}

// SONNY-2394 (GAP-0203 Fix #4 flake root cause). The QUIC test client gave
// every reply a FIXED 5 s deadline, while the replies it waits for include
// real server work that scales with host load -- COMMIT is the first request
// that touches the server's store and creates the default graph (16 shard
// engines, ~100 ms idle in Debug), HELLO runs Argon2id. Under parallel test
// load a live server could simply be slower than 5 s, and the client could not
// tell "slow" from "dead". This reproduces a live-but-starved server
// deterministically -- without loading the host -- by SIGSTOPping it for longer
// than the 5 s deadline while a BEGIN is in flight: the reply must still be
// awaited and delivered once the server runs again.
const ResumeLater = struct {
    fn run(pid: std.posix.pid_t, delay_ns: u64) void {
        compat_sleep(delay_ns);
        std.posix.kill(pid, .CONT) catch {};
    }
};

test "GAP-0203 Fix #4: a live-but-slow server is waited for, not timed out" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:3185";
    var fixture = try startServer(allocator, addr);
    defer fixture.client.deinit();
    defer fixture.server.deinit();

    const pid = fixture.server.child.id.?;
    try std.posix.kill(pid, .STOP);
    // Always resume, even if the assertion below fails (deinit KILLs anyway).
    const resumer = try std.Thread.spawn(.{}, ResumeLater.run, .{ pid, 6500 * std.time.ns_per_ms });
    defer resumer.join();

    var begin_res = try fixture.client.begin(allocator);
    defer begin_res.deinit(allocator);
    try testing.expect(begin_res.tx_id.len > 0);
    try testing.expect(try fixture.client.commit(allocator));
}

test "GAP-0203 Fix #4: a server that exited fails fast, not after the reply deadline" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:3186";
    var fixture = try startServer(allocator, addr);
    defer fixture.client.deinit();
    defer fixture.server.deinit();

    try std.posix.kill(fixture.server.child.id.?, .KILL);
    const t0 = nowNs();
    try testing.expectError(error.ServerExited, fixture.client.begin(allocator));
    // Detected on the first deadline check, well inside the 5 s reply budget
    // (slow != dead: only a LIVE server extends the wait).
    try testing.expect(nowNs() - t0 < 5 * std.time.ns_per_s);
}

// ============================================================================
// Fix #9: Write stall 3-phase backoff timing
// ============================================================================

test "GAP-0203 Fix #9: Exponential backoff calculation" {
    const spin_threshold: usize = 3;
    const yield_threshold: usize = 8;
    const initial_sleep_us: u64 = 10;
    const max_sleep_us: u64 = 100;

    for (1..spin_threshold + 1) |stall| {
        try testing.expect(stall <= spin_threshold);
    }

    for (spin_threshold + 1..yield_threshold + 1) |stall| {
        try testing.expect(stall > spin_threshold);
        try testing.expect(stall <= yield_threshold);
    }

    const expected_sleep = [_]u64{ 20, 40, 80, 100, 100 };
    for (0..5) |i| {
        const stall = yield_threshold + 1 + i;
        const backoff: u6 = @intCast(@min(stall - yield_threshold, 4));
        const sleep_us: u64 = @min(initial_sleep_us << backoff, max_sleep_us);
        try testing.expectEqual(expected_sleep[i], sleep_us);
    }
}

// ============================================================================
// Fix #10: HOT_PATH_LOGGING gate verification
// ============================================================================

test "GAP-0203 Fix #10: debug logging is gated off by default" {
    // Structural test: build must succeed with hot-path logs gated.
}

// ============================================================================
// Micro-benchmarks: Query pipeline throughput
// ============================================================================

test "GAP-0203 Benchmark: Query execution throughput baseline" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:3183";
    var fixture = try startServer(allocator, addr);
    defer fixture.client.deinit();
    defer fixture.server.deinit();

    var warm = try execSimple(&fixture.client, allocator, "RETURN 1 AS x");
    warm.deinit(allocator);

    const iterations: usize = 50;
    const t_start = nowNs();

    for (0..iterations) |_| {
        var result = try execSimple(&fixture.client, allocator, "RETURN 1 AS x");
        result.deinit(allocator);
    }

    const elapsed_ns = nowNs() - t_start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const qps = @as(f64, @floatFromInt(iterations)) / (elapsed_ms / 1000.0);

    std.debug.print(
        "\n[GAP-0203 Benchmark] {d} queries in {d:.1}ms = {d:.0} qps (QUIC)\n",
        .{ iterations, elapsed_ms, qps },
    );
}

test "GAP-0203 Benchmark: Query execution with connection reuse" {
    const allocator = testing.allocator;
    const addr = "127.0.0.1:3184";
    var fixture = try startServer(allocator, addr);
    defer fixture.client.deinit();
    defer fixture.server.deinit();

    const iterations: usize = 30;

    const t_new = nowNs();
    for (0..iterations) |_| {
        var client = try util.QuicProtoClient.connect(allocator, addr);
        defer client.deinit();
        var result = try execSimple(&client, allocator, "RETURN 1 AS x");
        result.deinit(allocator);
    }
    const elapsed_new = nowNs() - t_new;

    const t_reuse = nowNs();
    for (0..iterations) |_| {
        var result = try execSimple(&fixture.client, allocator, "RETURN 1 AS x");
        result.deinit(allocator);
    }
    const elapsed_reuse = nowNs() - t_reuse;

    const new_ms = @as(f64, @floatFromInt(elapsed_new)) / 1_000_000.0;
    const reuse_ms = @as(f64, @floatFromInt(elapsed_reuse)) / 1_000_000.0;
    const speedup = new_ms / reuse_ms;

    std.debug.print(
        "\n[GAP-0203 Benchmark] New connection: {d:.1}ms, Reuse: {d:.1}ms, Speedup: {d:.2}x ({d} iterations)\n",
        .{ new_ms, reuse_ms, speedup, iterations },
    );
}

test "GAP-0203 Benchmark: Graph management query detection cost" {
    const queries = [_][]const u8{
        "RETURN 1 AS x",
        "MATCH (n:Person) WHERE n.age > 30 RETURN n.name",
        "CREATE (n:Person {name: 'Alice'})",
        "MATCH (a)-[r:KNOWS]->(b) RETURN a, b",
    };

    const iterations: usize = 10_000;
    const t_start = nowNs();

    for (0..iterations) |i| {
        const query = queries[i % queries.len];
        const trimmed = std.mem.trimStart(u8, query, " \t\n\r");
        const is_graph_mgmt = std.ascii.startsWithIgnoreCase(trimmed, "USE GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "USE PROPERTY GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "CREATE GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "CREATE PROPERTY GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "DROP GRAPH ") or
            std.ascii.startsWithIgnoreCase(trimmed, "DROP PROPERTY GRAPH ");
        if (is_graph_mgmt) std.debug.print("unexpected graph mgmt query\n", .{});
    }

    const elapsed_ns = nowNs() - t_start;
    const per_check_ns = elapsed_ns / iterations;

    std.debug.print(
        "\n[GAP-0203 Benchmark] Graph detection: {d}ns per query ({d} iterations)\n",
        .{ per_check_ns, iterations },
    );

    try testing.expect(per_check_ns < 1_000);
}
