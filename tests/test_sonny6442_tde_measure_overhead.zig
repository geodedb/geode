// CANARY: REQ=REQ-SONNY-6442-TDE-MEASURE-OVERHEAD-REFUSED; FEATURE="TDEProcedures"; ASPECT=NoFakeOverheadMeasurement; STATUS=TESTED; TEST=tests/test_sonny6442_tde_measure_overhead.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-6442 (6): `CALL tde.measure_overhead()` timed 1000 x (alloc +
// memcpy + free) of 1 KiB as the "baseline" against 1000 AEAD encryptions of
// the same buffer as "encrypted", and answered `passes_threshold` = overhead
// < 5 %. Neither loop touches storage, so the percentage measures nothing
// about TDE overhead and `passes_threshold` is meaningless (an AEAD call is
// always far slower than a memcpy: it never passed). The real measurement
// is `zig build test-sonny6435-tde-overhead` (the storage engine's
// insert+read workload with page and WAL encryption off vs on).
//
// The contract: the procedure is refused with error.Unsupported (SQLSTATE
// 0A000), with TDE on and a key loaded as well as with TDE off, and the
// fake measurement (`tde.measureOverhead`) is gone.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const ast = geode.ast;
const storage_dispatch = geode.storage_dispatch;
const runtime_flags = geode.util_feature_flags;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const tde_key_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

/// Run `CALL tde.measure_overhead()` through the TDE procedure dispatch;
/// the result (if any) is discarded.
fn call(arena: std.mem.Allocator) !void {
    const name = "tde.measure_overhead";
    const callee = try arena.create(ast.Expr);
    callee.* = .{ .Ident = .{ .orig = name, .cnf = name } };
    const c: ast.CallProcedure = .{ .procedure = .{ .Call = .{ .callee = callee, .args = &.{} } } };
    const res = try storage_dispatch.executeTde(arena, name, c);
    if (res == null) return error.ProcedureNotRecognized;
}

test "SONNY-6442 (6) tde.measure_overhead is refused as unsupported with TDE on and a key loaded" {
    runtime_flags.global().tde.enableForTests();
    _ = setenv("GEODE_TDE_KEY", tde_key_hex, 1);
    defer {
        _ = unsetenv("GEODE_TDE_KEY");
        runtime_flags.global().tde.disableForTests();
    }
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.Unsupported, call(arena_state.allocator()));
}

test "SONNY-6442 (6) tde.measure_overhead is refused as unsupported with TDE off" {
    runtime_flags.global().tde.disableForTests();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.Unsupported, call(arena_state.allocator()));
}

test "SONNY-6442 (6) the fake overhead measurement is gone" {
    const src = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), "src/security/tde.zig", testing.allocator, .limited(16 << 20));
    defer testing.allocator.free(src);
    try testing.expect(std.mem.indexOf(u8, src, "pub fn measureOverhead(") == null);
    try testing.expect(std.mem.indexOf(u8, src, "passes_threshold") == null);
}
