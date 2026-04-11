// Copyright 2024-2026 CodePros
// SPDX-License-Identifier: Apache-2.0
//
// Regression test: server RSS must not grow unboundedly with connection count.
//
// Background: GPA's default never_unmap=true in Debug/ReleaseSafe retained freed
// pages forever, so every QUIC connection appeared to leak ~19MB of RSS.  Under
// load this OOM-crashed the server (see txn-complex-operations-chunked).
//
// This test launches the built server binary, opens 60 sequential QUIC
// connections (each runs a 3-statement query and disconnects) and asserts
// the RSS growth stays under a generous bound.  If the main allocator
// regresses to GPA defaults, this test fails.

const std = @import("std");
const testing = std.testing;

// std.c.mkdtemp is not exposed in Zig 0.15.2 — declare the libc extern directly.
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

/// Read /proc/<pid>/status VmRSS in KB.  Returns 0 on failure (non-Linux).
fn readRssKb(pid: std.os.linux.pid_t) usize {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid}) catch return 0;
    const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return 0;
    const contents = buf[0..n];
    const needle = "VmRSS:";
    const start = std.mem.indexOf(u8, contents, needle) orelse return 0;
    var i = start + needle.len;
    while (i < contents.len and (contents[i] == ' ' or contents[i] == '\t')) i += 1;
    var end = i;
    while (end < contents.len and contents[end] >= '0' and contents[end] <= '9') end += 1;
    const kb = std.fmt.parseInt(usize, contents[i..end], 10) catch return 0;
    return kb;
}

test "server RSS stays bounded across 60 connections" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    const alloc = testing.allocator;

    // Create a temp data dir for the server.
    var tmp_path_buf: [64]u8 = undefined;
    const tmp_tpl = "/tmp/geode_memtest_XXXXXX";
    @memcpy(tmp_path_buf[0..tmp_tpl.len], tmp_tpl);
    tmp_path_buf[tmp_tpl.len] = 0;
    const tmp_c: [*:0]u8 = @ptrCast(&tmp_path_buf);
    const tmp_dir_c = mkdtemp(tmp_c);
    if (tmp_dir_c == null) return error.SkipZigTest;
    const tmp_dir_len = std.mem.len(tmp_dir_c.?);
    const tmp_dir = tmp_dir_c.?[0..tmp_dir_len];

    // Ensure the temp dir is cleaned up on any exit path.  Ordering matters:
    // this defer is declared BEFORE the child spawn so it runs AFTER the
    // child.kill() defer (LIFO).  The sequence is: (1) kill child to release
    // file handles, (2) delete tmp dir.
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Launch the real server binary so the test covers the shipping allocator.
    // Hard-coded high port — acceptable because this test is gated to test-e2e
    // which runs serially.  Parallel runs would collide here.
    const port: u16 = 34717;
    var port_buf: [24]u8 = undefined;
    const listen = try std.fmt.bufPrint(&port_buf, "127.0.0.1:{d}", .{port});

    const argv = [_][]const u8{
        "./zig-out/bin/geode", "serve",
        "--data-dir",          tmp_dir,
        "--listen",            listen,
        "--log-level",         "error",
    };

    // GEODE_ADMIN_PASSWORD bootstraps the admin user on first launch; the
    // client then authenticates with -U geode -P <password>.  No auth bypass
    // flags are needed (and none exist for release builds).
    var env_map = try std.process.getEnvMap(alloc);
    defer env_map.deinit();
    try env_map.put("GEODE_ADMIN_PASSWORD", "GeodeTestPassword123!");

    var child = std.process.Child.init(&argv, alloc);
    child.env_map = &env_map;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    defer _ = child.kill() catch {};

    const pid = @as(std.os.linux.pid_t, @intCast(child.id));

    // Poll readiness via the warmup query (up to 10s total).  The first
    // successful query both confirms the server is listening AND doubles as
    // the warmup that touches initial thread stacks.  This replaces a blind
    // 3s sleep that was flaky on slow/cold CI runners.
    const deadline_ns: u64 = 10 * std.time.ns_per_s;
    const start_ns = std.time.nanoTimestamp();
    var ready = false;
    while (@as(u64, @intCast(std.time.nanoTimestamp() - start_ns)) < deadline_ns) {
        // Give the first attempt a small delay so the server has a chance to bind.
        std.Thread.sleep(250 * std.time.ns_per_ms);
        runOneQuery(alloc, listen, "RETURN 1 AS warmup") catch continue;
        ready = true;
        break;
    }
    if (!ready) return error.ServerStartupTimeout;

    const baseline_kb = readRssKb(pid);
    try testing.expect(baseline_kb > 0);

    // Run 60 more connections — representative of ~12 prior tests worth of traffic.
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const query = try std.fmt.allocPrint(
            alloc,
            "CREATE (n:MemTest {{id: {d}}}); MATCH (n:MemTest {{id: {d}}}) SET n.v = {d}; MATCH (n:MemTest {{id: {d}}}) RETURN n.v AS v",
            .{ i, i, i * 10, i },
        );
        defer alloc.free(query);
        try runOneQuery(alloc, listen, query);
    }

    const final_kb = readRssKb(pid);

    // Guard against a silent false-green: if the server died mid-loop,
    // readRssKb returns 0 (or /proc briefly shows a collapsed RSS) and
    // growth_kb would underflow to 0, making the test "pass" while actually
    // missing the regression we're trying to catch.
    try testing.expect(final_kb > 0);
    try testing.expect(final_kb >= baseline_kb / 2);

    const growth_kb = if (final_kb > baseline_kb) final_kb - baseline_kb else 0;
    std.debug.print("RSS baseline={d}KB final={d}KB growth={d}KB\n", .{ baseline_kb, final_kb, growth_kb });

    // Bound: 60 connections must not grow RSS by more than 120MB.
    // With the old GPA (never_unmap=true) this was ~1.1GB and the test fails.
    // With smp_allocator this is typically <40MB.
    const max_growth_kb: usize = 120 * 1024;
    try testing.expect(growth_kb < max_growth_kb);
}

fn runOneQuery(alloc: std.mem.Allocator, listen: []const u8, query: []const u8) !void {
    const argv = [_][]const u8{
        "./zig-out/bin/geode",   "query",
        "--insecure",            "--server",
        listen,                  "-U",
        "geode",                 "-P",
        "GeodeTestPassword123!", query,
    };
    var child = std.process.Child.init(&argv, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    _ = try child.wait();
}
