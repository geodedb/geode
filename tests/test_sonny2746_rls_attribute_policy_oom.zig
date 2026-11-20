// SONNY-2746 regression: `CALL geode.rls.add_attribute_policy` frees what it
// allocated when an allocation fails, and a failed call changes nothing.
//
// The handler copies the policy's strings into the expression engine's
// allocator and hands them to `RLSEngine.createPolicy`, which keeps them for
// the life of the server. When an allocation failed partway (a later copy,
// the compiled bytecode, the policy map or list), the copies made so far
// leaked, and so did the status row's partial allocations. Freeing the
// copies on failure is only safe because the engine no longer keeps a map
// entry whose key points into them: `installPolicy` inserted the (graph,
// table) entry before its last two fallible steps and left it behind when
// one of them failed.
//
// The sweep fails each allocation of one call in turn. A single
// FailingAllocator backs both the request and the engine, so the sweep covers
// both allocators. Each run must end in one of two ways:
//   * error.OutOfMemory, with the engine exactly as it was: no policy and no
//     map entry;
//   * success, only when the failed allocation was the best-effort audit
//     detail, with the policy installed.
// And after the run's cleanup nothing is left allocated.
//
// CANARY: REQ=REQ-SONNY-2746-RLS-ATTRIBUTE-POLICY-OOM; FEATURE="RLS deny-policy procedure"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2746_rls_attribute_policy_oom.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");

const execution = geode.execution;
const rls_dispatch = execution.rls_dispatch;

const proc_name = "geode.rls.add_attribute_policy";
const query = "CALL geode.rls.add_attribute_policy('default', 'Doc', 'dept', 'department')";

/// Free the engine, and with it what the handler gave it (every installed
/// policy's strings and compiled expression, in the engine's allocator).
fn freeEngine(engine: *rls.RLSEngine) void {
    // SONNY-2773: the engine owns the policy's strings (`owns_strings`) and
    // the code it compiled, and frees them; this freed them by hand.
    engine.deinit();
}

fn policyCount(engine: *rls.RLSEngine) usize {
    var n: usize = 0;
    var it = engine.policies.iterator();
    while (it.next()) |entry| n += entry.value_ptr.items.len;
    return n;
}

test "SONNY-2746: add_attribute_policy frees every allocation when any one of them fails" {
    const allocator = testing.allocator;

    var parsed = try geode.parseGql(query, allocator);
    defer parsed.deinit();
    const call = switch (parsed.program.statements[0]) {
        .Call => |c| switch (c) {
            .Procedure => |p| p,
            else => return error.UnexpectedStatement,
        },
        else => return error.UnexpectedStatement,
    };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    const catalog = try geode.catalog.Catalog.init(allocator, data_dir);
    defer {
        catalog.deinit();
        allocator.destroy(catalog);
    }
    // An admin: the procedure is refused to anyone else when auth is on.
    const ctx = execution.ExecutionContext{ .catalog = catalog, .role = .Admin };

    var fail_index: usize = 0;
    var failed_runs: usize = 0;
    while (true) : (fail_index += 1) {
        // The error return trace fills up with the OOMs the sweep catches, so
        // name the run that broke an invariant.
        errdefer std.debug.print("SONNY-2746 sweep: the run failing allocation {d} of the call broke an invariant\n", .{fail_index});
        var failing = testing.FailingAllocator.init(allocator, .{});
        const fa = failing.allocator();
        var engine = try rls.RLSEngine.init(fa);
        // Arm the failure `fail_index` allocations into the call itself.
        failing.fail_index = failing.alloc_index + fail_index;

        rls_types.setGlobalExprRLSEngine(@ptrCast(&engine));
        const outcome = rls_dispatch.execute(fa, proc_name, call, ctx);
        rls_types.setGlobalExprRLSEngine(null);

        const induced = failing.has_induced_failure;
        if (outcome) |maybe_result| {
            var result = maybe_result orelse return error.ProcedureNotDispatched;
            result.deinit(fa);
            try testing.expectEqual(@as(usize, 1), policyCount(&engine));
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(induced);
            // A failed add left the engine as it was: no policy, no entry.
            try testing.expectEqual(@as(usize, 0), policyCount(&engine));
            try testing.expect(engine.policies.count() == 0);
        }
        freeEngine(&engine);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);

        // A run that failed nothing: every allocation point has been failed.
        if (!induced) break;
        failed_runs += 1;
    }
    // The call allocates at least the reply (message, 2 columns, row, status
    // string, rows) and the policy (expression, name, description, graph,
    // table); compiling it and storing it allocate more.
    try testing.expect(failed_runs > 11);
}

// Absolute path of a `testing.tmpDir` (it lives under .zig-cache/tmp).
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}
