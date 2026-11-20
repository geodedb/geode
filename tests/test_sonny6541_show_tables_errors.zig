// SONNY-6541 (4): SHOW TABLES fails when its label listing fails; it does not
// answer an empty table list.
//
// `statement_handlers.executeShow` listed the labels with
// `tenant_visibility.listNodeLabelsVisible(...) catch &.{}`: any error of
// the listing (out of memory, a quarantined graph) became zero rows, a
// successful and wrong answer. A quarantined graph failed closed only
// because the store also notes it for the statement gate
// (`takeQuarantinedReadError`); nothing else did.
//
// A real listing failure, in process: SHOW TABLES runs through the executor
// with every allocation the request makes counted, and allocation number k
// fails (`std.testing.FailingAllocator`), for every k until a run makes no
// failing allocation. Each run must either fail or list both labels. A run
// that succeeds with fewer rows answered from a listing that failed.
//
// CANARY: REQ=REQ-SONNY-6541-SHOW-TABLES-ERRORS; FEATURE="SHOW TABLES"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6541_show_tables_errors.zig; OWNER=execution; UPDATED=2026-11-14

const std = @import("std");
const geode = @import("geode");

const graph_store = geode.graph_store;
const execution = geode.execution;
const query_arena = geode.query_arena;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn run(allocator: std.mem.Allocator, session: *execution.SessionState, q: []const u8) !usize {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const prev_scratch = query_arena.pushScratchAllocator(scratch.allocator());
    defer query_arena.popScratchAllocator(prev_scratch);
    var parsed = try geode.parseGql(q, allocator);
    defer parsed.deinit();
    const catalog = try execution.ensureCatalogInstance(std.testing.allocator);
    var result = try execution.executeProgramWithContext(allocator, &parsed.program, .{ .catalog = catalog, .session_state = session });
    defer result.deinit(allocator);
    return result.rows.len;
}

test "SONNY-6541 (4): SHOW TABLES fails when its label listing fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    defer graph_store.setDataDirOverride(allocator, null);

    _ = try graph_store.initGlobalStore(allocator, data_dir);
    defer graph_store.deinitGlobalStore();
    defer execution.cleanupCatalogInstance();
    var session = execution.SessionState.init(allocator);
    defer session.deinit();
    _ = try run(allocator, &session, "CREATE (:TabA6541 {k: 1})");
    _ = try run(allocator, &session, "CREATE (:TabB6541 {k: 2})");
    try std.testing.expectEqual(@as(usize, 2), try run(allocator, &session, "SHOW TABLES"));

    // The failing runs may leave what they allocated before the failure
    // behind (an error path of the executor, not this listing): counted
    // against the page allocator, which checks no leak.
    var wrong: usize = 0;
    var failed: usize = 0;
    var k: usize = 0;
    while (k < 4096) : (k += 1) {
        var fa = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = k });
        const rows = run(fa.allocator(), &session, "SHOW TABLES") catch {
            failed += 1;
            continue;
        };
        if (!fa.has_induced_failure) break;
        if (rows != 2) {
            wrong += 1;
            std.debug.print("SONNY-6541 (4): allocation {d} failed, and SHOW TABLES answered {d} row(s) instead of failing\n", .{ k, rows });
        }
    }
    std.debug.print("SONNY-6541 (4): {d} failing allocation(s) tried; {d} failed the statement, {d} answered wrongly\n", .{ k, failed, wrong });
    try std.testing.expect(k < 4096);
    try std.testing.expectEqual(@as(usize, 0), wrong);
}
