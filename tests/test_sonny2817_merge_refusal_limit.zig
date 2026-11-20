// SONNY-2817 regression: repeated MERGE visibility refusals are rate-limited
// per session and per label (SONNY-2728 follow-up).
//
// A MERGE whose only match is a row row-level security hides from the
// session is refused (MergeMatchNotVisible, 42501, SONNY-2686), and the
// refusal tells the session that some hidden row equals the pattern: an
// equality oracle over any property the pattern names (docs/kb/
// RLS_IMPLEMENTATION.md). SONNY-2728 audited every refusal; nothing limited
// how fast a session could guess. A session that collects too many refusals
// on one label of one graph within a window is now refused EVERY MERGE that
// names that label there for a cooldown, whether its pattern would have
// matched a hidden row, a visible one or none (MergeRefusalRateLimited,
// 53400), so the cooldown answers nothing; each refusal is audited
// (MERGE_REFUSAL_RATE_LIMITED). Other labels and other sessions are not
// affected.
//
// CANARY: REQ=REQ-SONNY-2817-MERGE-REFUSAL-LIMIT; FEATURE="MergeRowVisibility"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2817_merge_refusal_limit.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const h = @import("rls_session_harness.zig");

const execution = geode.execution;
const lim = geode.execution.merge_refusal_limiter;

/// What a session may collect on one label before the cooldown.
const refusal_limit = lim.refusal_limit;

test "SONNY-2817: after too many refused MERGEs on a label, every MERGE naming that label is refused for the session, with no oracle" {
    var s = try h.Session.init(.label_policy);
    defer s.deinit();
    const aa = s.arena.allocator();
    var f: h.Failures = .{};
    const audit = geode.security.audit;

    try s.execAs(null, "CREATE (:Hidden {s: 'leak', salary: 250000})");
    try s.execAs(null, "CREATE (:Doc {s: 'pub', cls: 'public'})");
    try s.restrict("Hidden");

    var session = execution.SessionState.init(testing.allocator);
    defer session.deinit();
    s.ctx.session_state = &session;

    const sink_path = try std.fmt.allocPrint(aa, "{s}/audit.jsonl", .{s.data_dir});
    const logger = try audit.AuditLogger.createHeap(testing.allocator, .{ .enabled = true, .file_path = sink_path });
    defer {
        audit.setGlobalAuditLogger(null);
        logger.deinit();
        testing.allocator.destroy(logger);
    }
    audit.setGlobalAuditLogger(logger);

    // Guesses that hit the hidden row: refused, up to the limit.
    for (0..refusal_limit) |_| {
        try h.expectError(&s, &f, "MERGE (x:Hidden {s: 'leak'}) RETURN x.s", error.MergeMatchNotVisible);
    }
    // Over the limit: a guess that would have hit the hidden row and one that
    // would have created a node get the same answer, and nothing is created.
    try h.expectError(&s, &f, "MERGE (x:Hidden {s: 'leak', salary: 250000}) RETURN x.s", error.MergeRefusalRateLimited);
    try h.expectError(&s, &f, "MERGE (x:Hidden {s: 'absent2817'}) RETURN x.s", error.MergeRefusalRateLimited);
    try h.expectError(&s, &f, "MERGE (a:Doc {s: 'pub'})-[:R]->(b:Hidden {s: 'absent2817b'})", error.MergeRefusalRateLimited);
    if (h.countWithS("absent2817") != 0 or h.countWithS("absent2817b") != 0) try f.add(aa, "a rate-limited MERGE created a node", .{});
    if (h.countWithS("leak") != 1) try f.add(aa, "{d} nodes named leak", .{h.countWithS("leak")});

    // Another label of the same session is not affected.
    try h.expectRows(&s, &f, "MERGE (x:Doc {s: 'pub'}) RETURN x.s", &.{"pub"});
    try h.expectRows(&s, &f, "MERGE (x:Doc {s: 'new2817'}) RETURN x.s", &.{"new2817"});

    // Another session is not affected.
    var other = execution.SessionState.init(testing.allocator);
    defer other.deinit();
    s.ctx.session_state = &other;
    try h.expectError(&s, &f, "MERGE (x:Hidden {s: 'leak'}) RETURN x.s", error.MergeMatchNotVisible);
    try h.expectRows(&s, &f, "MERGE (x:Hidden {s: 'mine2817'}) RETURN x.s", &.{"mine2817"});
    s.ctx.session_state = &session;

    // 53400, as the failed-MFA limiter.
    const info = geode.proto_util.mapError(error.MergeRefusalRateLimited);
    if (!std.mem.eql(u8, info.code, "53400")) try f.add(aa, "MergeRefusalRateLimited maps to {s}, want 53400", .{info.code});

    // Audited: the user, the graph and the label, never a value.
    const io = std.Io.Threaded.global_single_threaded.io();
    const sink = std.Io.Dir.cwd().readFileAlloc(io, sink_path, aa, .limited(1 << 20)) catch |err| blk: {
        try f.add(aa, "audit sink unreadable: {s}", .{@errorName(err)});
        break :blk "";
    };
    var limited: usize = 0;
    var lines = std.mem.splitScalar(u8, sink, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "MERGE_REFUSAL_RATE_LIMITED") == null) continue;
        limited += 1;
        for ([_][]const u8{ h.session_user, "access_denied", "graph=default", "Hidden" }) |want| {
            if (std.mem.indexOf(u8, line, want) == null) try f.add(aa, "a rate-limit record lacks `{s}`", .{want});
        }
        for ([_][]const u8{ "leak", "250000", "absent2817" }) |secret| {
            if (std.mem.indexOf(u8, line, secret) != null) try f.add(aa, "a rate-limit record carries the value `{s}`", .{secret});
        }
    }
    if (limited < 3) try f.add(aa, "expected a MERGE_REFUSAL_RATE_LIMITED record per limited MERGE (3), found {d}", .{limited});

    try f.finish("SONNY-2817");
}

test "SONNY-2817: an executor with no session (embedded) keeps refusing with MergeMatchNotVisible, never rate-limited" {
    var s = try h.Session.init(.label_policy);
    defer s.deinit();
    var f: h.Failures = .{};
    try s.execAs(null, "CREATE (:Hidden {s: 'leak'})");
    try s.restrict("Hidden");
    for (0..refusal_limit + 3) |_| {
        try h.expectError(&s, &f, "MERGE (x:Hidden {s: 'leak'}) RETURN x.s", error.MergeMatchNotVisible);
    }
    try f.finish("SONNY-2817 no session");
}

// ---------------------------------------------------------------------------
// The limiter itself, on a clock the test drives.
// ---------------------------------------------------------------------------

test "SONNY-2817 MergeRefusalLimiter: the limit starts a cooldown for that label only, which ends on its own" {
    var l = lim.MergeRefusalLimiter.init(testing.allocator);
    defer l.deinit();
    const t0: i64 = 1_000_000;
    var i: u32 = 0;
    while (i + 1 < lim.refusal_limit) : (i += 1) {
        try testing.expect(!l.noteRefusal("g", "Hidden", t0 + i));
        try testing.expect(!l.isLimited("g", "Hidden", t0 + i));
    }
    try testing.expect(l.noteRefusal("g", "Hidden", t0 + i));
    try testing.expect(l.isLimited("g", "Hidden", t0 + i));
    try testing.expect(!l.isLimited("g", "Doc", t0 + i));
    try testing.expect(!l.isLimited("g2", "Hidden", t0 + i));
    try testing.expect(l.isLimited("g", "Hidden", t0 + i + lim.cooldown_ms - 1));
    try testing.expect(!l.isLimited("g", "Hidden", t0 + i + lim.cooldown_ms));
    // The count starts again after a cooldown.
    try testing.expect(!l.noteRefusal("g", "Hidden", t0 + i + lim.cooldown_ms + 1));
}

test "SONNY-2817 MergeRefusalLimiter: refusals further apart than the window do not add up" {
    var l = lim.MergeRefusalLimiter.init(testing.allocator);
    defer l.deinit();
    var t: i64 = 0;
    for (0..refusal_limit * 3) |_| {
        try testing.expect(!l.noteRefusal("g", "Hidden", t));
        t += @divTrunc(lim.window_ms, lim.refusal_limit - 1) + 1;
    }
    try testing.expect(!l.isLimited("g", "Hidden", t));
}

test "SONNY-2817 MergeRefusalLimiter: at most max_tracked pairs; a running cooldown is not dropped to make room" {
    var l = lim.MergeRefusalLimiter.init(testing.allocator);
    defer l.deinit();
    for (0..refusal_limit) |_| _ = l.noteRefusal("g", "Hidden", 0);
    try testing.expect(l.isLimited("g", "Hidden", 1));
    var name: [16]u8 = undefined;
    for (0..lim.max_tracked * 2) |k| {
        const label = try std.fmt.bufPrint(&name, "L{d}", .{k});
        _ = l.noteRefusal("g", label, @intCast(10 + k));
    }
    try testing.expect(l.entries.count() <= lim.max_tracked);
    try testing.expect(l.isLimited("g", "Hidden", 20));
}

test "SONNY-2817 MergeRefusalLimiter: a pair that cannot be stored is not counted, and nothing leaks" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var l = lim.MergeRefusalLimiter.init(failing.allocator());
    defer l.deinit();
    try testing.expect(!l.noteRefusal("g", "Hidden", 0));
    try testing.expectEqual(@as(u32, 0), l.entries.count());
}
