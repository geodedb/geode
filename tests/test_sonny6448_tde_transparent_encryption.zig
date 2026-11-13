// CANARY: REQ=REQ-SONNY-6448-TDE-TRANSPARENT-NO-FAKE-IMPACT; FEATURE="TDEProcedures"; ASPECT=NoFakePerformanceImpact; STATUS=TESTED; TEST=tests/test_sonny6448_tde_transparent_encryption.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6448 (4): `CALL tde.test_transparent_encryption()` answered a
// `performance_impact_pct` that timed five alloc+memcpy+free copies against
// five AEAD encrypt+decrypt round trips of the same buffers. Neither loop
// touches storage, so the percentage said nothing about TDE overhead (the
// same flaw as tde.measure_overhead, SONNY-6442; the real measurement is
// `zig build test-sonny6435-tde-overhead`).
//
// The contract: the procedure still runs its functional self-test (every
// type round-trips through the server's TDE key) and answers exactly
// types_tested, all_transparent and errors_encountered; with TDE off it
// fails with FeatureDisabled; the fake metric is gone from the source.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const ast = geode.ast;
const storage_dispatch = geode.storage_dispatch;
const runtime_flags = geode.util_feature_flags;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const tde_key_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
const name = "tde.test_transparent_encryption";

fn call(arena: std.mem.Allocator) !geode.execution.ExecutionResult {
    const callee = try arena.create(ast.Expr);
    callee.* = .{ .Ident = .{ .orig = name, .cnf = name } };
    const c: ast.CallProcedure = .{ .procedure = .{ .Call = .{ .callee = callee, .args = &.{} } } };
    return (try storage_dispatch.executeTde(arena, name, c)) orelse error.ProcedureNotRecognized;
}

test "SONNY-6448 (4) tde.test_transparent_encryption answers the self-test without a performance figure" {
    runtime_flags.global().tde.enableForTests();
    _ = setenv("GEODE_TDE_KEY", tde_key_hex, 1);
    defer {
        _ = unsetenv("GEODE_TDE_KEY");
        runtime_flags.global().tde.disableForTests();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try call(arena_state.allocator());

    const want = [_][]const u8{ "types_tested", "all_transparent", "errors_encountered" };
    try testing.expectEqual(want.len, res.columns.len);
    for (want, res.columns) |w, got| try testing.expectEqualStrings(w, got);
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    const row = res.rows[0];
    try testing.expectEqual(@as(i64, 5), row[0].Int);
    try testing.expect(row[1].Bool);
    try testing.expectEqual(@as(i64, 0), row[2].Int);
}

test "SONNY-6448 (4) tde.test_transparent_encryption fails with TDE off" {
    runtime_flags.global().tde.disableForTests();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.FeatureDisabled, call(arena_state.allocator()));
}

test "SONNY-6448 (4) the memcpy-vs-AEAD performance figure is gone" {
    const io = std.Io.Threaded.global_single_threaded.io();
    for ([_][]const u8{ "src/security/tde.zig", "src/execution/storage_dispatch.zig" }) |path| {
        const src = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(16 << 20));
        defer testing.allocator.free(src);
        if (std.mem.indexOf(u8, src, "performance_impact_pct") != null) {
            std.debug.print("SONNY-6448: {s} still reports performance_impact_pct\n", .{path});
            return error.TestUnexpectedResult;
        }
    }
}
