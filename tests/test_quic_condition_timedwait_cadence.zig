// CANARY: REQ=REQ-GQL-074; FEATURE="QUIC Transport"; ASPECT=ConditionTimedWaitCadence; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-04-16
//! Regression tests for hand-rolled std.Io.Condition timedWait ports.
//!
//! Zig 0.16.0 removed std.Io.Condition.timedWait. Two sites in the QUIC
//! codebase have already been ported to a "nanosleep + re-check" pattern with
//! a sane (>=5 ms) slice:
//!   - zig-pkg/quic/src/quic/endpoint.zig:~582 (waitForAccepted, 5 ms slice)
//!   - src/transport/quic.zig:~119              (PollSync.waitForPoll)
//!
//! The triage in docs/audit/bugfix-quic-handshake-triage.md identified a third
//! site at
//!   zig-pkg/quic/src/quic/transport.zig:~788  (readLine WouldBlock retry loop)
//! still running at 500 us granularity. Under load this becomes a ~250 us
//! futex-spin on a worker thread that starves the main thread of ep.poll()
//! calls, stalling the handshake indefinitely.
//!
//! This test fails while any hand-rolled wait site in the vendored QUIC
//! source (or the `geode` transport wrapper) uses a sub-millisecond slice.
//! After the fix replaces `500 * std.time.ns_per_us` with `5 * std.time.ns_per_ms`
//! (matching the already-converted sites) this test must pass.
//!
//! The assertion is a simple substring scan — deterministic, fast, and does
//! not depend on timing. It targets the *literal* sub-ms wait patterns that
//! are the shape of the bug.

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;

/// File paths relative to the repo root that must not contain sub-ms waits.
/// The vendored quic dep lives at `zig-pkg/quic-<version>-<hash>/…`; the
/// hash changes every time the dep is bumped. Resolve the dir at runtime so
/// the test survives hash bumps (e.g. after `./scripts/update_dep_hashes.sh quic`).
const relative_quic_paths = [_][]const u8{
    "src/quic/transport.zig",
    "src/quic/endpoint.zig",
};
const geode_audited_paths = [_][]const u8{
    // Geode's local transport wrapper
    "src/transport/quic.zig",
};

/// Sub-millisecond nanosleep patterns that indicate a hand-rolled timedWait
/// port running at a cadence tight enough to starve the endpoint poll loop.
/// Anything faster than ~1 ms creates a futex-spin that monopolises a core
/// on a worker thread without giving the main thread a chance to poll.
const forbidden_patterns = [_][]const u8{
    "nanosleep(500 * std.time.ns_per_us)",
    "nanosleep(250 * std.time.ns_per_us)",
    "nanosleep(100 * std.time.ns_per_us)",
};

/// Read a file via raw Linux syscalls — avoids the Io.Dir/allocator churn
/// between Zig versions and keeps this self-contained.
fn readFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    // Null-terminate the path for syscall.
    var pathz: [4096]u8 = undefined;
    if (path.len + 1 > pathz.len) return error.PathTooLong;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;

    const open_flags: linux.O = .{ .ACCMODE = .RDONLY };
    const rc = linux.open(@ptrCast(&pathz), open_flags, 0);
    if (@as(isize, @bitCast(rc)) < 0) {
        // ENOENT etc. → treat as missing.
        return null;
    }
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var chunk: [8192]u8 = undefined;
    while (true) {
        const n_rc = linux.read(fd, &chunk, chunk.len);
        const n_signed: isize = @bitCast(n_rc);
        if (n_signed < 0) return error.ReadFailed;
        const n: usize = @intCast(n_signed);
        if (n == 0) break;
        try buf.appendSlice(allocator, chunk[0..n]);
    }
    return try buf.toOwnedSlice(allocator);
}

fn fileContains(allocator: std.mem.Allocator, path: []const u8, needle: []const u8) !bool {
    const maybe_content = try readFile(allocator, path);
    if (maybe_content) |content| {
        defer allocator.free(content);
        return std.mem.indexOf(u8, content, needle) != null;
    }
    return false; // missing file is not a violation
}

/// Locate the vendored quic dep directory under `zig-pkg/`. zig's package
/// manager names it `quic-<version>-<base64hash>` where the hash rotates on
/// every bump, so resolve it by prefix. Returns null if not present (e.g.
/// deps haven't been fetched yet — the test treats that as "nothing to audit").
fn findVendoredQuicDir(allocator: std.mem.Allocator) !?[]u8 {
    const zig_pkg = "zig-pkg";
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, zig_pkg, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.startsWith(u8, entry.name, "quic-")) {
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ zig_pkg, entry.name });
        }
    }
    return null;
}

test "quic condition timedWait ports use >=1ms cadence" {
    const allocator = testing.allocator;

    var violations: std.ArrayList(u8) = .empty;
    defer violations.deinit(allocator);

    // Build the full audit set: vendored quic dep paths (resolved by prefix)
    // plus geode's local transport wrapper.
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |p| allocator.free(p);
        owned.deinit(allocator);
    }

    if (try findVendoredQuicDir(allocator)) |quic_dir| {
        try owned.append(allocator, quic_dir);
        for (relative_quic_paths) |rel| {
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ quic_dir, rel });
            try owned.append(allocator, full);
            try paths.append(allocator, full);
        }
    }
    for (geode_audited_paths) |p| try paths.append(allocator, p);

    for (paths.items) |path| {
        for (forbidden_patterns) |pat| {
            const hit = fileContains(allocator, path, pat) catch |err| {
                const line = std.fmt.allocPrint(
                    allocator,
                    "ERROR scanning {s}: {s}\n",
                    .{ path, @errorName(err) },
                ) catch continue;
                defer allocator.free(line);
                try violations.appendSlice(allocator, line);
                continue;
            };
            if (hit) {
                const line = try std.fmt.allocPrint(
                    allocator,
                    "sub-millisecond nanosleep cadence found in {s}: {s}\n",
                    .{ path, pat },
                );
                defer allocator.free(line);
                try violations.appendSlice(allocator, line);
            }
        }
    }

    if (violations.items.len > 0) {
        std.debug.print("\n[cadence-audit] violations detected:\n{s}", .{violations.items});
        std.debug.print(
            "\n[cadence-audit] fix: replace the sub-ms cadence with " ++
                "`5 * std.time.ns_per_ms` so the hand-rolled timedWait port " ++
                "yields to the endpoint poll loop (matches " ++
                "endpoint.zig:~582 and src/transport/quic.zig:~119).\n",
            .{},
        );
        return error.SubMillisecondTimedWaitCadence;
    }
}

test "quic converted timedWait sites keep their nanosleep+re-check shape" {
    // Sanity: if somebody deletes the nanosleep fallback entirely (e.g. assumes
    // Io.Condition.timedWait is back), the `waitForAccepted` / `waitForPoll`
    // sites should still be present so we don't silently regress either.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse {
        // If the dep isn't fetched yet, skip — CI will run `zig build` first
        // which populates zig-pkg/.
        return error.SkipZigTest;
    };
    defer allocator.free(quic_dir);

    const waitForAccepted_path = try std.fmt.allocPrint(
        allocator,
        "{s}/src/quic/endpoint.zig",
        .{quic_dir},
    );
    defer allocator.free(waitForAccepted_path);
    const poll_sync_path = "src/transport/quic.zig";

    try std.testing.expect(try fileContains(
        allocator,
        waitForAccepted_path,
        "Io.Condition has no timedWait",
    ));

    try std.testing.expect(try fileContains(
        allocator,
        poll_sync_path,
        "nanosleep",
    ));
}
