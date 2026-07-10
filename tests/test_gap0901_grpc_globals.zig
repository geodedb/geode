// CANARY: REQ=REQ-GAP-0901-GRPC-GLOBAL-INIT; FEATURE="GrpcTransport"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0901_grpc_globals.zig:1; OWNER=transport; UPDATED=2026-07-10
//
// Regression test for GAP-0901: "gRPC transport is wholesale non-functional".
//
// Root cause (repo-side): the transport-agnostic globals the RLS deny-policy
// DDL procedures consult — the RLS dispatch callbacks — were initialized ONLY
// inside the `if (listen_quic)` block of src/server/main.zig. A gRPC-only
// serve path (`grpc_server.start(); return;`) never reached them, so a gRPC
// handler running `CALL geode.rls.add_deny_policy(...)` hit the null-callback
// path and returned "RLS filter engine not initialized". The fix hoists that
// wiring (rate limiter + RLS engines + RLS callbacks) to before the gRPC serve
// path, exactly as the GAP-0848 tenant-state block was.
//
// This test is transport-independent: it pins the WIRING contract the fix
// depends on. With the callbacks reset (the pre-fix gRPC-only state), the DDL
// reports "not initialized"; once wired the same way the hoisted block wires
// them, the DDL succeeds and the policy is registered. (End-to-end gRPC
// verification stays blocked by the vendor grpc_zig crash, GAP-0893.)

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const rls_dispatch = execution.rls_dispatch;

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        const catalog = try execution.ensureCatalogInstance(allocator);
        // geode.rls.* DDL is admin-gated (auth defaults enabled) — this test
        // exercises the wiring, not authorization, so authenticate as admin.
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .ctx = .{ .catalog = catalog, .role = .Admin, .user = "admin" } };
    }
    fn deinit(self: *Harness) void {
        execution.cleanupCatalogInstance();
        self.arena.deinit();
    }
    fn run(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

fn firstCellStr(res: execution.ExecutionResult) []const u8 {
    if (res.rows.len == 0 or res.rows[0].len == 0) return "";
    return switch (res.rows[0][0]) {
        .Str => |s| s,
        else => "",
    };
}

test "GAP-0901: RLS deny-policy DDL reports 'not initialized' when callbacks are unwired (pre-fix gRPC-only state)" {
    rls_dispatch.resetCallbacks();
    defer rls_dispatch.resetCallbacks();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.run("CALL geode.rls.add_deny_policy('g', 'Secret', 'alice')");
    // The null-callback path returns a single status row naming the missing wiring.
    try testing.expect(std.mem.indexOf(u8, firstCellStr(res), "not initialized") != null);
}

test "GAP-0901: once the callbacks are wired, the RLS DDL succeeds (post-hoist state both transports see)" {
    // Wire callbacks with a simple in-test policy sink, mirroring what the
    // hoisted server block does (which now runs for gRPC too).
    const Sink = struct {
        var count: usize = 0;
        fn add(_: ?*anyopaque, _: []const u8, _: []const u8, _: []const u8) anyerror!void {
            count += 1;
        }
        fn cnt(_: ?*anyopaque) usize {
            return count;
        }
    };
    Sink.count = 0;
    rls_dispatch.setCallbacks(.{
        .ctx = null,
        .add_deny_fn = Sink.add,
        .policy_count_fn = Sink.cnt,
    });
    defer rls_dispatch.resetCallbacks();

    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const res = try h.run("CALL geode.rls.add_deny_policy('g', 'Secret', 'alice')");
    // The wired path does NOT return the "not initialized" error.
    try testing.expect(std.mem.indexOf(u8, firstCellStr(res), "not initialized") == null);
    try testing.expectEqual(@as(usize, 1), Sink.count);
}
