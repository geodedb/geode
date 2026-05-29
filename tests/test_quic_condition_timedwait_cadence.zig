// CANARY: REQ=REQ-GQL-074; FEATURE="QUIC Transport"; ASPECT=ConditionTimedWaitCadence; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-25
//! Regression tests for hand-rolled std.Io.Condition timedWait ports.
//!
//! Zig 0.16.0 removed std.Io.Condition.timedWait. The vendored QUIC
//! `waitForAccepted` path now uses a futex generation instead of a fixed
//! nanosleep cadence:
//!   - zig-pkg/quic/src/quic/endpoint.zig:~892 (accepted_generation futex)
//!
//! Geode's local PollSync path has since moved to a futex generation:
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
//! After the old fallbacks are replaced with >=1ms slices or futex waits, this
//! test must pass.
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

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;

    var count: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOf(u8, haystack[start..], needle)) |idx| {
        count += 1;
        start += idx + needle.len;
    }
    return count;
}

fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

fn sliceBetween(haystack: []const u8, start_needle: []const u8, end_needle: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, haystack, start_needle) orelse return error.MissingStartNeedle;
    const rest = haystack[start..];
    const end = std.mem.indexOf(u8, rest, end_needle) orelse rest.len;
    return rest[0..end];
}

/// Locate the active vendored quic dep directory under `zig-pkg/`. zig's
/// package manager names it `quic-<version>-<base64hash>` where the hash
/// rotates on every bump, so prefer the package hash pinned in build.zig.zon
/// and only fall back to prefix scanning when the pin is unavailable.
/// Returns null if not present (e.g. deps haven't been fetched yet — the test
/// treats that as "nothing to audit").
fn findPinnedPackageHash(allocator: std.mem.Allocator, dep_name: []const u8) !?[]u8 {
    if (try readFile(allocator, "build.zig.zon")) |zon| {
        defer allocator.free(zon);
        const dep_needle = try std.fmt.allocPrint(allocator, ".{s} = .{{", .{dep_name});
        defer allocator.free(dep_needle);
        if (std.mem.indexOf(u8, zon, dep_needle)) |dep_start| {
            const dep = zon[dep_start..@min(zon.len, dep_start + 16384)];
            if (std.mem.indexOf(u8, dep, ".hash = \"")) |hash_key| {
                const hash_start = hash_key + ".hash = \"".len;
                if (std.mem.indexOfScalar(u8, dep[hash_start..], '"')) |hash_len| {
                    return try allocator.dupe(u8, dep[hash_start .. hash_start + hash_len]);
                }
            }
        }
    }
    return null;
}

fn packageRootWithProbe(
    allocator: std.mem.Allocator,
    root: []const u8,
    probe_rel: []const u8,
) !?[]u8 {
    const probe = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, probe_rel });
    defer allocator.free(probe);
    if (try readFile(allocator, probe)) |probe_content| {
        allocator.free(probe_content);
        return try allocator.dupe(u8, root);
    }
    return null;
}

fn packageRootUnderCache(
    allocator: std.mem.Allocator,
    cache_root: []const u8,
    hash: []const u8,
    probe_rel: []const u8,
) !?[]u8 {
    const root = try std.fmt.allocPrint(allocator, "{s}/p/{s}", .{ cache_root, hash });
    defer allocator.free(root);
    return try packageRootWithProbe(allocator, root, probe_rel);
}

fn findPinnedPackageDir(allocator: std.mem.Allocator, dep_name: []const u8, probe_rel: []const u8) !?[]u8 {
    const hash = (try findPinnedPackageHash(allocator, dep_name)) orelse return null;
    defer allocator.free(hash);

    const pinned_path = try std.fmt.allocPrint(allocator, "zig-pkg/{s}", .{hash});
    defer allocator.free(pinned_path);
    if (try packageRootWithProbe(allocator, pinned_path, probe_rel)) |root| return root;

    const local_cache_path = try std.fmt.allocPrint(allocator, ".zig-cache/p/{s}", .{hash});
    defer allocator.free(local_cache_path);
    if (try packageRootWithProbe(allocator, local_cache_path, probe_rel)) |root| return root;

    if (getEnvVarOwned(allocator, "ZIG_GLOBAL_CACHE_DIR")) |cache_dir| {
        defer allocator.free(cache_dir);
        if (try packageRootUnderCache(allocator, cache_dir, hash, probe_rel)) |root| return root;
    } else |_| {}

    if (getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |cache_home| {
        defer allocator.free(cache_home);
        const zig_cache = try std.fmt.allocPrint(allocator, "{s}/zig", .{cache_home});
        defer allocator.free(zig_cache);
        if (try packageRootUnderCache(allocator, zig_cache, hash, probe_rel)) |root| return root;
    } else |_| {}

    if (getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const zig_cache = try std.fmt.allocPrint(allocator, "{s}/.cache/zig", .{home});
        defer allocator.free(zig_cache);
        if (try packageRootUnderCache(allocator, zig_cache, hash, probe_rel)) |root| return root;
    } else |_| {}

    return null;
}

fn findVendoredQuicDir(allocator: std.mem.Allocator) !?[]u8 {
    if (try findPinnedPackageDir(allocator, "quic", "src/quic/endpoint.zig")) |root| return root;

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

test "quic converted timedWait sites keep their wait-and-wake shape" {
    // Sanity: if somebody assumes Io.Condition.timedWait is back, the
    // `waitForAccepted` futex generation and PollSync futex wait should still
    // be present so we don't silently regress either path.
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
        "accepted_generation",
    ));

    try std.testing.expect(try fileContains(
        allocator,
        waitForAccepted_path,
        "futexWaitTimeout(u32, &self.accepted_generation.raw",
    ));

    try std.testing.expect(try fileContains(
        allocator,
        poll_sync_path,
        "futexWaitTimeout",
    ));

    try std.testing.expect(try fileContains(
        allocator,
        poll_sync_path,
        "notifyPoll",
    ));
}

test "quic endpoint poll cycle has a receive fairness budget" {
    // A single pollWithStats() call must return periodically during a large UDP
    // burst so Geode can wake stream handlers waiting on PollSync. Otherwise
    // high fan-out handshakes can spend seconds inside endpoint Phase 4.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const endpoint_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint.zig", .{quic_dir});
    defer allocator.free(endpoint_path);

    const maybe_endpoint = try readFile(allocator, endpoint_path);
    const endpoint = maybe_endpoint orelse return error.FileNotFound;
    defer allocator.free(endpoint);

    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-033") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "client_max_packets_per_poll_cycle") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "const client_max_packets_per_poll_cycle: usize = udp_transport_mod.UdpBatchCap;") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-142") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "server_poll_receive_batches") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "fn maxPacketsPerPollCycleForRole(role: EndpointRole) usize") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "const max_packets_this_poll = maxPacketsPerPollCycleForRole(self.role);") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "stats.packets_processed >= max_packets_this_poll") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-123") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "server_short_header_receive_batches") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "const server_short_header_receive_batches: usize = server_poll_receive_batches;") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "server_max_short_header_packets_per_poll_cycle") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, ".Server => server_max_short_header_packets_per_poll_cycle") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "maxShortHeaderPacketsPerPollCycleForRole") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "short_header_packets_processed >= max_short_header_packets_this_poll") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-059") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "maxInitialPacketsPerPollCycleForRole") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "classifyLongHeaderPacket") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "recv_slots[0..recv_limit]") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-064") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "initial_packets_processed >= max_initial_packets_this_poll") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "avoids forcing the connection-tail into PTO backoff") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-065") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "processInitialDatagramConcurrent") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "processInitialResolved") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-066") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "processHandshakeDatagramConcurrent") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "processHandshakeResolved") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-168") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "generic_long_header_dispatch_serializes_tls_for_test") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "self.processInitialDatagramConcurrent(norm_peer, packet_bytes, version);") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "self.processHandshakeDatagramConcurrent(norm_peer, packet_bytes, version, ecn_bits);") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "incoming.processInitial(&rx_ctx, norm_peer, packet_bytes, version);") == null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "incoming.processHandshake(&rx_ctx, norm_peer, packet_bytes, version, ecn_bits, rx_ctx.send_fn);") == null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "const previous_io_endpoint = current_io_endpoint;") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "stats.packets_processed += 1;") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-035") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "PtoDirtyDestroySerialization") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "pto_lifetime_mu") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "c.computeAndMaybeArmPtoHandshake(self)") != null);
}

test "quic pto dirty recompute is budgeted per poll cycle" {
    // Application ACK bursts mark many connections PTO-dirty. Draining that
    // whole set in one poll call recreates long poll overruns, so dirty PTO
    // recompute must use the set as a queue and leave unprocessed entries for
    // later poll cycles.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const endpoint_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint.zig", .{quic_dir});
    defer allocator.free(endpoint_path);
    const maybe_endpoint = try readFile(allocator, endpoint_path);
    const endpoint = maybe_endpoint orelse return error.FileNotFound;
    defer allocator.free(endpoint);

    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-090") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "max_pto_dirty_recomputes_per_poll_cycle") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "const pto_dirty_budget = @min(self.pto_dirty_set.count(), max_pto_dirty_recomputes_per_poll_cycle)") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "pto_dirty_snapshot.items.len + stale_pto_dirty_snapshot.items.len >= pto_dirty_budget") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "self.pto_dirty_count.store(self.pto_dirty_set.count(), .release)") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "self.pto_dirty_set.clearRetainingCapacity()") == null);
}

test "quic poll cycle exposes phase latency metrics" {
    // Large fan-out request runs need to identify which endpoint poll phase is
    // producing long cycles. The vendored QUIC PollStats must expose phase
    // timings and Geode must surface them through runtime gauges.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const endpoint_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint.zig", .{quic_dir});
    defer allocator.free(endpoint_path);

    const maybe_endpoint = try readFile(allocator, endpoint_path);
    const endpoint = maybe_endpoint orelse return error.FileNotFound;
    defer allocator.free(endpoint);

    const maybe_transport = try readFile(allocator, "src/transport/quic.zig");
    const transport = maybe_transport orelse return error.FileNotFound;
    defer allocator.free(transport);

    const maybe_metrics = try readFile(allocator, "src/server/quic_connection_metrics.zig");
    const metrics = maybe_metrics orelse return error.FileNotFound;
    defer allocator.free(metrics);

    const maybe_main = try readFile(allocator, "src/server/main.zig");
    const main = maybe_main orelse return error.FileNotFound;
    defer allocator.free(main);

    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-092") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-094") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-097") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "transport_poll_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "recv_process_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "recv_short_header_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "recv_short_endpoint_map_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "recv_short_rx_serial_wait_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "recv_short_conn_lock_wait_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "recv_short_decrypt_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "recv_short_frame_process_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "recv_short_ack_send_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "recv_initial_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "recv_handshake_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "recv_fallback_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "pending_hs_send_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "timer_process_ns") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "pto_dirty_ns") != null);

    try testing.expect(std.mem.indexOf(u8, transport, "poll_transport_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_recv_process_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_recv_short_header_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_recv_short_endpoint_map_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_recv_short_rx_serial_wait_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_recv_short_conn_lock_wait_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_recv_short_decrypt_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_recv_short_frame_process_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_recv_short_ack_send_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_recv_initial_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_recv_handshake_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_recv_fallback_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_pending_hs_send_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_timer_process_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "poll_pto_dirty_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "observePollCycle(stats, cycle_ns, overrun_threshold_ns)") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "observeMaxAtomic(&self.poll_transport_max_ns, stats.transport_poll_ns)") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "pub fn getPollPtoDirtyMaxNs") != null);

    try testing.expect(std.mem.indexOf(u8, metrics, "pollTransportMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollRecvProcessMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollRecvShortHeaderMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollRecvShortEndpointMapMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollRecvShortRxSerialWaitMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollRecvShortConnLockWaitMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollRecvShortDecryptMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollRecvShortFrameProcessMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollRecvShortAckSendMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollRecvInitialMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollRecvHandshakeMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollRecvFallbackMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollPendingHsSendMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollTimerProcessMaxNs") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pollPtoDirtyMaxNs") != null);

    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_transport_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_recv_process_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_recv_short_header_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_recv_short_endpoint_map_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_recv_short_rx_serial_wait_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_recv_short_conn_lock_wait_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_recv_short_decrypt_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_recv_short_frame_process_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_recv_short_ack_send_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_recv_initial_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_recv_handshake_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_recv_fallback_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_pending_hs_send_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_timer_process_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, main, "quic_poll_pto_dirty_max_ns") != null);
}

test "quic ack recovery avoids small-window parallel fork join" {
    // ACK recovery executes on the endpoint receive path. Small sent-packet
    // windows should stay sequential so short-header ACK bursts do not spend
    // poll-loop time submitting parallel loss-detection jobs.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const recovery_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/recovery/recovery.zig", .{quic_dir});
    defer allocator.free(recovery_path);
    const maybe_recovery = try readFile(allocator, recovery_path);
    const recovery = maybe_recovery orelse return error.FileNotFound;
    defer allocator.free(recovery);

    try testing.expect(std.mem.indexOf(u8, recovery, "REQ=REQ-QUIC-HC-095") != null);
    try testing.expect(std.mem.indexOf(u8, recovery, "loss_detect_parallel_threshold: usize = 1024") != null);
    try testing.expect(std.mem.indexOf(u8, recovery, "unprocessed_count >= loss_detect_parallel_threshold") != null);
    try testing.expect(std.mem.indexOf(u8, recovery, "unprocessed_count >= 64") == null);
}

test "quic ack and pto recovery mutate under connection mutex" {
    // Application ACK handling and PTO retransmission both mutate recovery
    // state plus the STREAM retransmission map. They must share Connection.mu
    // with writeStream() so a same-instant request/response burst cannot race
    // cleanup against retransmit or send-side packet accounting.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const frame_handler_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/frame_handler.zig", .{quic_dir});
    defer allocator.free(frame_handler_path);
    const endpoint_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint.zig", .{quic_dir});
    defer allocator.free(endpoint_path);

    const maybe_frame_handler = try readFile(allocator, frame_handler_path);
    const frame_handler = maybe_frame_handler orelse return error.FileNotFound;
    defer allocator.free(frame_handler);
    const maybe_endpoint = try readFile(allocator, endpoint_path);
    const endpoint = maybe_endpoint orelse return error.FileNotFound;
    defer allocator.free(endpoint);

    try testing.expect(std.mem.indexOf(u8, frame_handler, "REQ=REQ-QUIC-HC-069") != null);
    try testing.expect(std.mem.indexOf(u8, frame_handler, "AckRecoveryMutex") != null);
    try testing.expect(std.mem.indexOf(u8, frame_handler, "ctx.conn.mu.lockUncancelable") != null);
    try testing.expect(std.mem.indexOf(u8, frame_handler, "ctx.conn.onAckReceivedSpace") != null);

    const ack_fn = std.mem.indexOf(u8, frame_handler, "pub fn handleAck") orelse return error.MissingHandleAck;
    const ack_body = frame_handler[ack_fn..];
    const ack_lock = std.mem.indexOf(u8, ack_body, "ctx.conn.mu.lockUncancelable") orelse return error.MissingAckMutexLock;
    const ack_process = std.mem.indexOf(u8, ack_body, "ctx.conn.onAckReceivedSpace") orelse return error.MissingAckRecoveryProcess;
    try testing.expect(ack_lock < ack_process);

    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-070") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "PtoRecoveryMutex") != null);
    try testing.expect(countOccurrences(endpoint, "c.mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());") >= 3);
    try testing.expect(std.mem.indexOf(u8, endpoint, "c.setPtoExpiredInitial();") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "c.setPtoExpiredHandshake();") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "c.setPtoExpiredApp();") != null);
}

test "quic udp transport drains larger high fanout batches" {
    const allocator = testing.allocator;
    const maybe_endpoint_dir = try findVendoredQuicDir(allocator);
    const endpoint_dir = maybe_endpoint_dir orelse return error.FileNotFound;
    defer allocator.free(endpoint_dir);
    const udp_path = try std.fs.path.join(allocator, &.{ endpoint_dir, "src/quic/endpoint/udp_transport.zig" });
    defer allocator.free(udp_path);

    const maybe_udp = try readFile(allocator, udp_path);
    const udp = maybe_udp orelse return error.FileNotFound;
    defer allocator.free(udp);

    try testing.expect(std.mem.indexOf(u8, udp, "REQ=REQ-QUIC-HC-102") != null);
    try testing.expect(std.mem.indexOf(u8, udp, "pub const UdpBatchCap: usize = 64") != null);
    try testing.expect(std.mem.indexOf(u8, udp, "recvmmsg") != null);
    try testing.expect(std.mem.indexOf(u8, udp, "sendmmsg") != null);
}

test "quic accepted connection queue avoids front-removal and fixed sleep wait" {
    const allocator = testing.allocator;
    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const endpoint_path = try std.fs.path.join(allocator, &.{ quic_dir, "src/quic/endpoint.zig" });
    defer allocator.free(endpoint_path);
    const maybe_endpoint = try readFile(allocator, endpoint_path);
    const endpoint = maybe_endpoint orelse return error.FileNotFound;
    defer allocator.free(endpoint);

    const server_path = try std.fs.path.join(allocator, &.{ quic_dir, "src/quic/endpoint/server.zig" });
    defer allocator.free(server_path);
    const maybe_server = try readFile(allocator, server_path);
    const server = maybe_server orelse return error.FileNotFound;
    defer allocator.free(server);

    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-106") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "accepted_generation: std.atomic.Value(u32)") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "fn wakeAcceptedWaiter") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "futexWaitTimeout(u32, &self.accepted_generation.raw") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "futexWake(u32, &self.accepted_generation.raw, 1)") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-107") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "self.accepted.swapRemove(0)") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "self.accepted.orderedRemove(0)") == null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "5 * std.time.ns_per_ms; // 5 ms per check") == null);
    try testing.expect(std.mem.indexOf(u8, server, "accepted.swapRemove(0)") != null);
    try testing.expect(std.mem.indexOf(u8, server, "accepted.orderedRemove(0)") == null);
}

test "high concurrency harness reports retry tails" {
    const allocator = testing.allocator;
    const maybe_harness = try readFile(allocator, "tests/e2e_quic_high_concurrency.zig");
    const harness = maybe_harness orelse return error.FileNotFound;
    defer allocator.free(harness);

    try testing.expect(std.mem.indexOf(u8, harness, "REQ=REQ-QUIC-HC-103") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "setup_attempts") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "setup_retries") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "execute_attempts") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "execute_retries") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "execute_reconnects") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "avg_first_op_ms") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "avg_followup_op_ms") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "first_op_latency_ns") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "followup_op_latency_ns") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "REQ=REQ-QUIC-HC-124") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "REQ=REQ-QUIC-HC-132") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "const default_connection_worker_count = 64") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "const high_fanout_connection_worker_cap = 64") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "GEODE_HC_CONNECTION_WORKERS") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "GEODE_QUIC_CONNECTION_WORKERS={d}") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "GEODE_HC_CONNECTION_ADMISSION_THREADS") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "GEODE_QUIC_CONNECTION_ADMISSION_THREADS={d}") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "GEODE_QUIC_DETACHED_CONNECTION_ADMISSION=1") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "const op_start_ns = monoNs();") != null);
}

test "parallel union arms serialize query allocator traffic" {
    const allocator = testing.allocator;
    const maybe_set_ops = try readFile(allocator, "src/execution/set_operations.zig");
    const set_ops = maybe_set_ops orelse return error.FileNotFound;
    defer allocator.free(set_ops);

    try testing.expect(std.mem.indexOf(u8, set_ops, "REQ=REQ-QUIC-HC-125") != null);
    try testing.expect(std.mem.indexOf(u8, set_ops, "const LockedAllocator = struct") != null);
    try testing.expect(std.mem.indexOf(u8, set_ops, "mutex: std.Io.Mutex = std.Io.Mutex.init") != null);
    try testing.expect(std.mem.indexOf(u8, set_ops, "const arm_allocator = locked_allocator.allocator();") != null);
    try testing.expect(std.mem.indexOf(u8, set_ops, ".allocator = arm_allocator") != null);
}

test "query cache misses singleflight by key without serializing unrelated misses" {
    const allocator = testing.allocator;

    const maybe_ast_cache = try readFile(allocator, "src/server/query_ast_cache.zig");
    const ast_cache = maybe_ast_cache orelse return error.FileNotFound;
    defer allocator.free(ast_cache);

    const maybe_plan_cache = try readFile(allocator, "src/server/query_plan_cache.zig");
    const plan_cache = maybe_plan_cache orelse return error.FileNotFound;
    defer allocator.free(plan_cache);

    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler);

    const ast_get_or_parse = try sliceBetween(
        ast_cache,
        "pub fn getOrParse(self: *SharedAstCache",
        "pub fn release(self: *SharedAstCache",
    );
    const plan_optimize = try sliceBetween(
        plan_cache,
        "pub fn optimizeQuery(\n        self: *SharedQueryOptimizer",
        "pub fn release(self: *SharedQueryOptimizer",
    );

    try testing.expect(std.mem.indexOf(u8, ast_get_or_parse, "REQ=REQ-QUIC-HC-104") != null);
    try testing.expect(std.mem.indexOf(u8, ast_get_or_parse, "AstMissSingleFlight") != null);
    try testing.expect(std.mem.indexOf(u8, ast_get_or_parse, "STATUS=TESTED") != null);
    try testing.expect(std.mem.indexOf(u8, ast_get_or_parse, "TEST=query_ast_cache_shared_singleflight") != null);
    try testing.expect(std.mem.indexOf(u8, ast_cache, "REQ=REQ-QUIC-HC-164") != null);
    try testing.expect(std.mem.indexOf(u8, ast_cache, "SharedAstConcurrentHits") != null);
    try testing.expect(std.mem.indexOf(u8, ast_cache, "lock: std.Io.RwLock") != null);
    try testing.expect(std.mem.indexOf(u8, ast_cache, "ref_count: std.atomic.Value(u32)") != null);
    try testing.expect(std.mem.indexOf(u8, ast_get_or_parse, "lockSharedUncancelable") != null);
    try testing.expect(std.mem.indexOf(u8, ast_get_or_parse, "hit_count.fetchAdd(1, .acq_rel)") != null);
    try testing.expect(std.mem.indexOf(u8, ast_get_or_parse, "inflight_misses") != null);
    try testing.expect(std.mem.indexOf(u8, ast_get_or_parse, "parse outside the lock") != null);
    {
        const inflight_idx = std.mem.indexOf(u8, ast_get_or_parse, "self.inflight_misses.put") orelse return error.MissingAstInflight;
        const unlock_idx = std.mem.indexOfPos(u8, ast_get_or_parse, inflight_idx, "self.lock.unlock(std.Io.Threaded.global_single_threaded.io());") orelse return error.MissingAstUnlockBeforeParse;
        const parse_idx = std.mem.indexOf(u8, ast_get_or_parse, "geode.parseGqlOutcome") orelse return error.MissingAstParse;
        const put_idx = std.mem.indexOf(u8, ast_get_or_parse, "self.cache.put(key, cached_ast)") orelse return error.MissingAstPut;
        try testing.expect(inflight_idx < unlock_idx);
        try testing.expect(unlock_idx < parse_idx);
        try testing.expect(parse_idx < put_idx);
    }

    try testing.expect(std.mem.indexOf(u8, plan_optimize, "REQ=REQ-QUIC-HC-105") != null);
    try testing.expect(std.mem.indexOf(u8, plan_optimize, "PlanMissSingleFlight") != null);
    try testing.expect(std.mem.indexOf(u8, plan_optimize, "STATUS=TESTED") != null);
    try testing.expect(std.mem.indexOf(u8, plan_optimize, "TEST=shared_query_optimizer_plan_singleflight") != null);
    try testing.expect(std.mem.indexOf(u8, plan_cache, "REQ=REQ-QUIC-HC-165") != null);
    try testing.expect(std.mem.indexOf(u8, plan_cache, "SharedPlanConcurrentHits") != null);
    try testing.expect(std.mem.indexOf(u8, plan_cache, "lock: std.Io.RwLock") != null);
    try testing.expect(std.mem.indexOf(u8, plan_cache, "ref_count: std.atomic.Value(u32)") != null);
    try testing.expect(std.mem.indexOf(u8, plan_cache, "plan: *CompiledPlan") != null);
    try testing.expect(std.mem.indexOf(u8, plan_cache, "allocator.create(CompiledPlan)") != null);
    try testing.expect(std.mem.indexOf(u8, plan_cache, "allocator.destroy") != null);
    try testing.expect(std.mem.indexOf(u8, plan_optimize, "lockSharedUncancelable") != null);
    try testing.expect(std.mem.indexOf(u8, plan_optimize, "hit_count.fetchAdd(1, .acq_rel)") != null);
    try testing.expect(std.mem.indexOf(u8, plan_optimize, "inflight_misses") != null);
    try testing.expect(std.mem.indexOf(u8, plan_optimize, "generate the real plan outside the lock") != null);
    {
        const inflight_idx = std.mem.indexOf(u8, plan_optimize, "self.inflight_misses.put") orelse return error.MissingPlanInflight;
        const unlock_idx = std.mem.indexOfPos(u8, plan_optimize, inflight_idx, "self.lock.unlock(io);") orelse return error.MissingPlanUnlockBeforeGenerate;
        const generate_idx = std.mem.indexOf(u8, plan_optimize, "generateRealPlan") orelse return error.MissingPlanGenerate;
        const put_idx = std.mem.indexOf(u8, plan_optimize, "self.plan_cache.put(key, cached_plan)") orelse return error.MissingPlanPut;
        try testing.expect(inflight_idx < unlock_idx);
        try testing.expect(unlock_idx < generate_idx);
        try testing.expect(generate_idx < put_idx);
    }

    const maybe_parse_wrapper = try readFile(allocator, "tests/test_gap0810_parse_cache_wrapper.zig");
    const parse_wrapper = maybe_parse_wrapper orelse return error.FileNotFound;
    defer allocator.free(parse_wrapper);
    try testing.expect(std.mem.indexOf(u8, parse_wrapper, "test \"query_ast_cache_shared_singleflight\"") != null);
    try testing.expect(std.mem.indexOf(u8, parse_wrapper, "test \"query_ast_cache_concurrent_hits_release_without_serializing\"") != null);
    try testing.expect(std.mem.indexOf(u8, parse_wrapper, "test \"query_ast_cache_unique_misses_do_not_collapse\"") != null);
    try testing.expect(std.mem.indexOf(u8, parse_wrapper, "std.Thread.spawn") != null);

    const maybe_plan_hit = try readFile(allocator, "tests/test_plan_cache_hit.zig");
    const plan_hit = maybe_plan_hit orelse return error.FileNotFound;
    defer allocator.free(plan_hit);
    try testing.expect(std.mem.indexOf(u8, plan_hit, "test \"shared_query_optimizer_plan_singleflight\"") != null);
    try testing.expect(std.mem.indexOf(u8, plan_hit, "test \"shared_query_optimizer_concurrent_hits_release_without_serializing\"") != null);
    try testing.expect(std.mem.indexOf(u8, plan_hit, "test \"shared_query_optimizer_unique_misses_do_not_collapse\"") != null);
    try testing.expect(std.mem.indexOf(u8, plan_hit, "std.Thread.spawn") != null);

    try testing.expect(std.mem.indexOf(u8, handler, "REQ=REQ-QUIC-HC-166") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "const program_is_mutating = isMutatingProgram(&parse_result.program);") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "if (!program_is_mutating) {") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "const is_mutation = needs_store_lock and program_is_mutating;") != null);
}

test "cooperative first stream clears running before consuming reschedule flags" {
    // If data arrives after a cooperative owner observes WouldBlock but before
    // it clears `running`, the RX callback stores `needs_reschedule`. The
    // worker must publish `running=false` before consuming that flag, otherwise
    // the only wake for the next query packet can be lost.
    const allocator = testing.allocator;
    const handler_path = "src/server/quic_connection_handler.zig";

    const maybe_handler = try readFile(allocator, handler_path);
    const handler = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler);

    const marker_idx = std.mem.indexOf(u8, handler, "const done = processCooperativeFirstStream(ctx);") orelse
        return error.MissingSchedulerWorkerLoop;
    const tail = handler[marker_idx..];
    const running_idx = std.mem.indexOf(u8, tail, "ctx.cooperative_running.store(false, .release);") orelse
        return error.MissingRunningClear;
    const force_idx = std.mem.indexOf(u8, tail, "const force = ctx.cooperative_force_ready.load(.acquire);") orelse
        return error.MissingForceReadyLoad;

    try testing.expect(running_idx < force_idx);
}

test "cooperative first stream ready queue is fifo" {
    // A LIFO ready queue lets newer HELLO streams repeatedly jump ahead of
    // older streams during large fan-out setup, producing avoidable HELLO
    // timeouts and reconnect churn.
    const allocator = testing.allocator;
    const handler_path = "src/server/quic_connection_handler.zig";

    const maybe_handler = try readFile(allocator, handler_path);
    const handler = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler);

    try testing.expect(std.mem.indexOf(u8, handler, "REQ=REQ-QUIC-HC-067") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "ready_head: usize = 0") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "self.ready_queue.items[self.ready_head]") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "self.ready_head += 1") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "orderedRemove(0)") == null);
}

test "cooperative first stream scheduler sweeps missed rx wakeups" {
    // A verifier stream can sit idle through a large close-heavy burst and
    // receive its next query after the RX-ready callback window has passed.
    // The scheduler must periodically compare per-stream RX generations so
    // that missed callbacks do not become unbounded post-load timeouts.
    const allocator = testing.allocator;
    const handler_path = "src/server/quic_connection_handler.zig";

    const maybe_handler = try readFile(allocator, handler_path);
    const handler = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler);

    try testing.expect(std.mem.indexOf(u8, handler, "REQ=REQ-QUIC-HC-100") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "first_stream_scheduler_idle_sweep_ns") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "ready_generation: std.atomic.Value(u32)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "io.futexWaitTimeout(u32, &self.ready_generation.raw, observed, timeout)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "io.futexWake(u32, &self.ready_generation.raw, 1)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "fn takeChangedContextLocked") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "ctx.stream.readGeneration()") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "ctx.cooperative_generation_seen.load(.acquire)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "current_generation != seen_generation") != null);

    const process_idx = std.mem.indexOf(u8, handler, "fn processCooperativeFirstStream") orelse
        return error.MissingProcessCooperativeFirstStream;
    const process_body = handler[process_idx..];
    const generation_idx = std.mem.indexOf(u8, process_body, "const read_generation = ctx.stream.readGeneration();") orelse
        return error.MissingReadGenerationSnapshot;
    const read_idx = std.mem.indexOf(u8, process_body, "ctx.reader.nextMessageNonBlocking() catch") orelse
        return error.MissingNonBlockingRead;
    const store_idx = std.mem.indexOf(u8, process_body, "ctx.cooperative_generation_seen.store(read_generation, .release);") orelse
        return error.MissingGenerationStore;
    try testing.expect(generation_idx < read_idx);
    try testing.expect(read_idx < store_idx);
}

test "cooperative first stream scheduler uses bounded batch budget" {
    // Persistent one-stream query clients should rotate through the scheduler
    // ready queue after each protocol message so large fan-out cannot starve
    // tail streams behind hot early clients. Empty streams must then park on
    // the read-ready notifier instead of taking a second immediate turn just
    // to discover WouldBlock.
    const allocator = testing.allocator;
    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler);

    try testing.expect(std.mem.indexOf(u8, handler, "REQ=REQ-QUIC-HC-108") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "first_stream_scheduler_messages_per_tick: u32 = 1") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "while (processed < first_stream_scheduler_messages_per_tick)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "const max_messages_per_tick: u32 = 4") == null);
    try testing.expect(std.mem.indexOf(u8, handler, "REQ=REQ-QUIC-HC-140") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "fn hasBufferedUnread") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "if (ctx.reader.hasBufferedUnread())") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "ctx.cooperative_generation_seen.store(ctx.stream.readGeneration(), .release);") != null);
}

test "cooperative first stream scheduler yields to poll workers at high fanout" {
    // The cooperative path replaced one OS thread per first stream. Once the
    // shared worker pool is large, it still needs a post-turn yield/backoff so
    // QUIC poll workers can flush request and response packets during 4k+
    // connection fan-out.
    const allocator = testing.allocator;
    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler);

    try testing.expect(std.mem.indexOf(u8, handler, "REQ=REQ-QUIC-HC-147") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "CooperativePollerFairness") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "context_count: std.atomic.Value(u32)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "self.context_count.fetchAdd(1, .acq_rel)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "self.context_count.fetchSub(1, .acq_rel)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "fn pauseAfterTurn") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "self.pauseAfterTurn();") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "active_contexts > 512") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "first_stream_scheduler_turn_delay_per_excess_ns: u64 = 2 * std.time.ns_per_us") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "first_stream_scheduler_turn_delay_cap_ns: u64 = std.time.ns_per_ms") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "excess * first_stream_scheduler_turn_delay_per_excess_ns") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "std.Thread.yield() catch {};") != null);
}

test "cooperative first stream scheduler requeues mutation overflow" {
    // A burst of mutations must not occupy every cooperative first-stream
    // worker while lock-free reads are still waiting in the ready queue.
    const allocator = testing.allocator;
    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler);

    try testing.expect(std.mem.indexOf(u8, handler, "REQ=REQ-QUIC-HC-148") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "REQ=REQ-QUIC-HC-150") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "REQ=REQ-QUIC-HC-159") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "REQ=REQ-QUIC-HC-160") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "CooperativeMutationAdmission") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "CooperativeMutationClassifier") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "PermitGatedMutationRetry") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "ShardParallelMutationAdmission") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "CooperativeMutationAdmissionClass") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "pending_packet: ?schema.ClientPacket = null") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "mutation_inflight: std.atomic.Value(u32)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "shard_parallel_mutation_inflight: std.atomic.Value(u32)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "mutation_retry_waiters: std.atomic.Value(u32)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "cooperative_mutation_waiting: std.atomic.Value(bool)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "cooperative_mutation_wait_class: std.atomic.Value(u8)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "mutation_limit") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "shard_parallel_mutation_limit") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "CooperativeMutationWindowCap") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "serial_first_stream_scheduler_mutation_limit_cap: usize = 4") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "default_first_stream_scheduler_mutation_limit_cap: usize = 512") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "max_first_stream_scheduler_mutation_limit_cap: usize = 512") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "effective_mutation_cap") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "@max(worker_count, 1) / 4") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "@min(@max(worker_count, 1), effective_mutation_cap)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "fn queryLooksShardParallelSimpleMergeForCooperativeAdmission") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "property_key_count >= 2") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "fn packetCooperativeMutationAdmissionClass") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "fn tryAcquireMutationPermit") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "fn releaseMutationPermit") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "fn markMutationRetryWaiter") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "fn clearMutationRetryWaiter") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "fn forceReadyEligible") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "fn queryCooperativeMutationAdmissionClass") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "ctx.pending_packet = packet;") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "scheduler.markMutationRetryWaiter(ctx, admission_class);") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "scheduler.clearMutationRetryWaiter(ctx);") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "ctx.cooperative_force_ready.store(true, .release);") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "parked_mutation") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "self.mutation_retry_waiters.load(.acquire) != 0") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "self.anyMutationPermitCapacity()") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "io.futexWake(u32, &self.ready_generation.raw, 1)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "scheduler.tryAcquireMutationPermit(admission_class)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "scheduler.releaseMutationPermit(mutation_class)") != null);
}

test "high concurrency harness batches workload start wake" {
    // The high-fanout harness should shape the local client wakeup as well as
    // the request send time; otherwise thousands of same-process client threads
    // can starve the child server before request_stagger_us takes effect.
    const allocator = testing.allocator;
    const maybe_e2e = try readFile(allocator, "tests/e2e_quic_high_concurrency.zig");
    const e2e = maybe_e2e orelse return error.FileNotFound;
    defer allocator.free(e2e);

    try testing.expect(std.mem.indexOf(u8, e2e, "REQ=REQ-QUIC-HC-145") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "REQ=REQ-QUIC-HC-152") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "BatchedStartBarrierWake") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "FailureLogBackpressure") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "failure_log_limit: u32 = 64") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "failure_logs: std.atomic.Value(u32)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "read_failed: std.atomic.Value(u32)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "mutation_failed: std.atomic.Value(u32)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "REQ=REQ-QUIC-HC-155") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "REQ=REQ-QUIC-HC-156") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "ExecutePhaseAggregation") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "DeferredPostWriteFlush") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "exec_timing_samples: std.atomic.Value(u32)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "first_execute_lag_ns: std.atomic.Value(u64)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "max_first_response_wait_ns: std.atomic.Value(u64)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "fn recordExecTiming") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "fn printTimingSummary") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "high-concurrency QUIC E2E timing") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "avg_ready_to_first_execute_ms") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "avg_first_response_wait_ms") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "execute_prepare_ns: std.atomic.Value(u64)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "execute_stream_write_ns: std.atomic.Value(u64)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "execute_post_write_poll_ns: std.atomic.Value(u64)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "avg_execute_prepare_ms") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "avg_execute_stream_write_ms") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "avg_execute_post_write_poll_ms") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_HC_POST_WRITE_POLL") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "worker_count < 1024") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "fn recordOperationFailure") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "suppressing additional per-worker failures; summary follows") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "fn wakeWorkloadStart") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "worker_count >= 1024 and request_stagger_us != 0") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "const wake_count = @min(remaining, @as(u32, 64));") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "sleepNs(250 * std.time.ns_per_us);") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "wakeWorkloadStart(&start, &start_generation, worker_count, request_stagger_us);") != null);
}

test "store-free scalar reads bypass graph snapshot locks" {
    const allocator = testing.allocator;

    const maybe_traits = try readFile(allocator, "src/query/query_traits.zig");
    const traits = maybe_traits orelse return error.FileNotFound;
    defer allocator.free(traits);

    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler);

    try testing.expect(std.mem.indexOf(u8, traits, "REQ=REQ-QUIC-HC-110") != null);
    try testing.expect(std.mem.indexOf(u8, traits, "is_store_free: bool = false") != null);
    try testing.expect(std.mem.indexOf(u8, traits, "pub fn isStoreFreeQuery") != null);
    try testing.expect(std.mem.indexOf(u8, traits, "q.match.chains.len != 0") != null);
    try testing.expect(std.mem.indexOf(u8, traits, "isStoreFreeScalarExpr") != null);
    try testing.expect(std.mem.indexOf(u8, traits, "RETURN 1 AS c") != null);
    try testing.expect(std.mem.indexOf(u8, traits, "MATCH (n:Person) RETURN 1 AS c") != null);

    try testing.expect(std.mem.indexOf(u8, handler, "REQ=REQ-QUIC-HC-110") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "analysis.kind == .rows and analysis.is_store_free") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "snapshotUnderReadLock(gpa, query_graph_name)") != null);
}

test "password auth coalesces concurrent identical verifies" {
    // The high-concurrency QUIC setup path authenticates many connections for
    // the same user at once. Those callers must not each burn a full Argon2id
    // verification while the workload waits behind HELLO.
    const allocator = testing.allocator;
    const maybe_auth = try readFile(allocator, "src/security/user_management.zig");
    const auth = maybe_auth orelse return error.FileNotFound;
    defer allocator.free(auth);

    try testing.expect(std.mem.indexOf(u8, auth, "REQ=REQ-QUIC-HC-068") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "REQ=REQ-QUIC-HC-091") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "REQ=REQ-QUIC-HC-130") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "AuthFlight") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "RefreshFlight") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "authFlightLane") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "beginRefreshFlight") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "finishRefreshFlight") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "beginAuthFlight") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "finishAuthFlight") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "verifyPassword(password, user_data.password_hash)") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "authenticate_concurrent_cached_user_singleflights_persistent_refresh") != null);
    try testing.expect(std.mem.indexOf(u8, auth, "return auth_flight_lane.fetchAdd(1, .acq_rel) % lanes") == null);
    try testing.expect(std.mem.indexOf(u8, auth, "return 0;") != null);
}

test "quic short header reuses endpoint connection lookup" {
    // The endpoint must look up short-header packets once for NAT rebinding and
    // pass that result into the decrypt path. Repeating the DCID sweep doubles
    // hot-path hash work under high parallel application traffic.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const endpoint_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint.zig", .{quic_dir});
    defer allocator.free(endpoint_path);
    const incoming_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/incoming.zig", .{quic_dir});
    defer allocator.free(incoming_path);
    const module_c_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/incoming/module_c.zig", .{quic_dir});
    defer allocator.free(module_c_path);

    const maybe_endpoint = try readFile(allocator, endpoint_path);
    const endpoint = maybe_endpoint orelse return error.FileNotFound;
    defer allocator.free(endpoint);
    const maybe_incoming = try readFile(allocator, incoming_path);
    const incoming = maybe_incoming orelse return error.FileNotFound;
    defer allocator.free(incoming);
    const maybe_module_c = try readFile(allocator, module_c_path);
    const module_c = maybe_module_c orelse return error.FileNotFound;
    defer allocator.free(module_c);

    try testing.expect(std.mem.indexOf(u8, module_c, "REQ=REQ-QUIC-HC-049") != null);
    try testing.expect(std.mem.indexOf(u8, module_c, "pub fn processShortHeaderResolved") != null);
    try testing.expect(std.mem.indexOf(u8, module_c, "lookup_result: lookup.LookupResult") != null);
    try testing.expect(std.mem.indexOf(u8, incoming, "pub const processShortHeaderResolved = incoming_c.processShortHeaderResolved") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "incoming.processShortHeaderResolved(&rx_ctx") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "lookup_result)") != null);
}

test "quic stream readers use per-connection rx wake generation" {
    // High-fanout one-stream clients should not all park on the endpoint-wide
    // PollSync generation. The vendored connection bumps rx_data_generation
    // when STREAM data/FIN lands, and Geode waits on that per-connection word
    // after readStream returns WouldBlock.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const conn_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/conn.zig", .{quic_dir});
    defer allocator.free(conn_path);
    const methods_a_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/connection/methods_a.zig", .{quic_dir});
    defer allocator.free(methods_a_path);

    const maybe_conn = try readFile(allocator, conn_path);
    const conn = maybe_conn orelse return error.FileNotFound;
    defer allocator.free(conn);
    const maybe_methods_a = try readFile(allocator, methods_a_path);
    const methods_a = maybe_methods_a orelse return error.FileNotFound;
    defer allocator.free(methods_a);
    const maybe_transport = try readFile(allocator, "src/transport/quic.zig");
    const transport = maybe_transport orelse return error.FileNotFound;
    defer allocator.free(transport);
    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler);

    try testing.expect(std.mem.indexOf(u8, conn, "REQ=REQ-QUIC-HC-037") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "rx_data_generation") != null);
    try testing.expect(std.mem.indexOf(u8, methods_a, "wake_readers") != null);
    try testing.expect(std.mem.indexOf(u8, methods_a, "rx_data_generation.fetchAdd") != null);
    try testing.expect(std.mem.indexOf(u8, methods_a, "futexWake(u32, &self.rx_data_generation.raw") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "pub fn readGeneration") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "pub fn waitForReadGeneration") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "&self.connection.rx_data_generation.raw") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "const read_generation = self.stream.readGeneration()") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "self.stream.waitForReadGeneration(read_generation") != null);
}

test "quic connection init resets default-backed runtime fields" {
    // The QUIC package allocates Connection as undefined memory and calls
    // init(). Field defaults do not run in that pattern, so every runtime
    // field that readers and metrics observe under fan-out must be reset
    // explicitly inside init().
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const conn_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/conn.zig", .{quic_dir});
    defer allocator.free(conn_path);
    const maybe_conn = try readFile(allocator, conn_path);
    const conn = maybe_conn orelse return error.FileNotFound;
    defer allocator.free(conn);

    try testing.expect(std.mem.indexOf(u8, conn, "REQ=REQ-QUIC-HC-046") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "connection init resets default-backed runtime fields from allocator fill bytes") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "@memset(std.mem.asBytes(&c), 0xaa)") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "self.rx_data_generation = std.atomic.Value(u32).init(0)") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "self.endpoint_rx_serial_mu = std.Io.Mutex.init") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "self.endpoint_rx_refs = std.atomic.Value(u32).init(0)") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "self.endpoint_destroying = std.atomic.Value(bool).init(false)") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "self.rtt_initial = .{}") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "self.rtt_handshake = .{}") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "self.rtt_app = .{}") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "self.zero_rtt_keys = null") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "self.pending_hs_send = false") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "self.packet_pool = .{}") != null);
}

test "quic short header processing uses endpoint rx lifetime guard" {
    // Established application packets should not hold endpoint.mu while doing
    // AEAD decrypt, frame dispatch, and ACK generation. The endpoint only uses
    // the global mutex long enough to resolve and ref the connection; destroy
    // waits for those refs before freeing the connection.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const conn_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/conn.zig", .{quic_dir});
    defer allocator.free(conn_path);
    const endpoint_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint.zig", .{quic_dir});
    defer allocator.free(endpoint_path);
    const module_c_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/incoming/module_c.zig", .{quic_dir});
    defer allocator.free(module_c_path);
    const api_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/api.zig", .{quic_dir});
    defer allocator.free(api_path);

    const maybe_conn = try readFile(allocator, conn_path);
    const conn = maybe_conn orelse return error.FileNotFound;
    defer allocator.free(conn);
    const maybe_endpoint = try readFile(allocator, endpoint_path);
    const endpoint = maybe_endpoint orelse return error.FileNotFound;
    defer allocator.free(endpoint);
    const maybe_module_c = try readFile(allocator, module_c_path);
    const module_c = maybe_module_c orelse return error.FileNotFound;
    defer allocator.free(module_c);
    const maybe_api = try readFile(allocator, api_path);
    const api = maybe_api orelse return error.FileNotFound;
    defer allocator.free(api);

    try testing.expect(std.mem.indexOf(u8, conn, "REQ=REQ-QUIC-HC-051") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "REQ=REQ-QUIC-HC-053") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "endpoint_rx_serial_mu") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "acquireEndpointRxRef") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "refs + 1") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "releaseEndpointRxRef") != null);
    try testing.expect(std.mem.indexOf(u8, conn, "beginEndpointDestroy") != null);
    try testing.expect(std.mem.indexOf(u8, api, "conn.beginEndpointDestroy();") != null);
    try testing.expect(std.mem.indexOf(u8, api, "ep.clearShortHeaderRouteCacheForConnection(conn);") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-052") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-054") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-098") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-117") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "short_header_route_cache_client_slots: usize = 256") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "short_header_route_cache_server_slots: usize = 65536") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "shortHeaderRouteCacheSlotCount(endpoint_role)") != null);
    try testing.expect(std.mem.indexOf(u8, module_c, "REQ=REQ-QUIC-HC-112") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "short_header_route_cache") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "short_header_timing_enabled") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "\"GEODE_QUIC_SHORT_HEADER_TIMING\"") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, ".short_header_timing = if (detailed_timing) &timing else null") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "tryShortHeaderRouteCache") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "rememberShortHeaderRoute") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "clearShortHeaderRouteCacheForConnection") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "ShortHeaderRxLifetimeGuard") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "processShortHeaderDatagramConcurrent") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "c.acquireEndpointRxRef()") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "defer conn.releaseEndpointRxRef();") != null);
    try testing.expect(std.mem.indexOf(u8, module_c, "conn.endpoint_rx_serial_mu.lockUncancelable") != null);
    try testing.expect(std.mem.indexOf(u8, module_c, "shortHeaderPayloadCanProcessWithoutRxSerial") != null);
    try testing.expect(std.mem.indexOf(u8, module_c, "rx_serial_locked = false") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "incoming.processShortHeaderResolved(&rx_ctx") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "if (datagram.len > 0 and (datagram[0] & 0x80) == 0)") != null);

    const fn_idx = std.mem.indexOf(u8, endpoint, "fn processShortHeaderDatagramConcurrent") orelse
        return error.MissingShortHeaderConcurrentFunction;
    const body = endpoint[fn_idx..];
    const route_cache_idx = std.mem.indexOf(u8, body, "self.tryShortHeaderRouteCache") orelse
        return error.MissingShortHeaderRouteCacheProbe;
    const lock_idx = std.mem.indexOf(u8, body, "self.mu.lockUncancelable") orelse
        return error.MissingEndpointLock;
    const unlock_idx = std.mem.indexOf(u8, body, "self.mu.unlock") orelse
        return error.MissingEndpointUnlock;
    const pin_idx = std.mem.indexOf(u8, body, "c.acquireEndpointRxRef()") orelse
        return error.MissingEndpointRxPin;
    const block_exit_idx = std.mem.indexOf(u8, body, "break :blk c;") orelse
        return error.MissingEndpointLockBlockExit;
    const map_timing_idx = std.mem.lastIndexOf(u8, body[0..block_exit_idx], "timing.endpoint_map_ns += elapsedNsSince(map_start_ns);") orelse
        return error.MissingEndpointMapTiming;
    const release_idx = std.mem.indexOf(u8, body, "defer conn.releaseEndpointRxRef();") orelse
        return error.MissingEndpointRxRelease;
    const incoming_idx = std.mem.indexOf(u8, body, "incoming.processShortHeaderResolved(&rx_ctx") orelse
        return error.MissingShortHeaderDispatch;
    const module_fn = try sliceBetween(module_c, "pub fn processShortHeaderResolved", "/// Module marker");
    const module_serial_idx = std.mem.indexOf(u8, module_fn, "conn.endpoint_rx_serial_mu.lockUncancelable") orelse
        return error.MissingPerConnectionRxLock;
    const helper_idx = std.mem.indexOf(u8, module_fn, "shortHeaderPayloadCanProcessWithoutRxSerial(dec_res.payload)") orelse
        return error.MissingShortHeaderFrameClassifier;
    const conn_unlock_idx = std.mem.indexOf(u8, module_fn, "conn.mu.unlock(std.Io.Threaded.global_single_threaded.io());") orelse
        return error.MissingConnUnlockBeforeFrames;
    const serial_unlock_rel = std.mem.indexOf(u8, module_fn[conn_unlock_idx..], "conn.endpoint_rx_serial_mu.unlock(std.Io.Threaded.global_single_threaded.io());") orelse
        return error.MissingPerConnectionRxUnlock;
    const serial_unlock_idx = conn_unlock_idx + serial_unlock_rel;
    const frames_idx = std.mem.indexOf(u8, module_fn, "const frame_result = processFrames") orelse
        return error.MissingFrameDispatch;

    try testing.expect(route_cache_idx < lock_idx);
    try testing.expect(lock_idx < unlock_idx);
    try testing.expect(pin_idx < map_timing_idx);
    try testing.expect(map_timing_idx < block_exit_idx);
    try testing.expect(pin_idx < block_exit_idx);
    try testing.expect(block_exit_idx < release_idx);
    try testing.expect(release_idx < incoming_idx);
    try testing.expect(module_serial_idx < helper_idx);
    try testing.expect(helper_idx < conn_unlock_idx);
    try testing.expect(conn_unlock_idx < serial_unlock_idx);
    try testing.expect(serial_unlock_idx < frames_idx);
}

test "quic short header diagnostics are compile-time gated" {
    // ReleaseSafe receive loops must not run debug-only packet scans or mutate
    // non-atomic diagnostic counters after logger.debugPrint compiles away.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const module_c_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/incoming/module_c.zig", .{quic_dir});
    defer allocator.free(module_c_path);
    const maybe_module_c = try readFile(allocator, module_c_path);
    const module_c = maybe_module_c orelse return error.FileNotFound;
    defer allocator.free(module_c);

    try testing.expect(std.mem.indexOf(u8, module_c, "REQ=REQ-QUIC-HC-116") != null);
    try testing.expect(std.mem.indexOf(u8, module_c, "g_app_decrypt_start = std.atomic.Value(u64).init(0)") != null);
    try testing.expect(std.mem.indexOf(u8, module_c, "g_app_decrypt_success = std.atomic.Value(u64).init(0)") != null);
    try testing.expect(std.mem.indexOf(u8, module_c, "g_app_decrypt_start.fetchAdd(1, .monotonic)") != null);
    try testing.expect(std.mem.indexOf(u8, module_c, "g_app_decrypt_success.fetchAdd(1, .monotonic)") != null);
    try testing.expect(std.mem.indexOf(u8, module_c, "g_app_decrypt_start += 1") == null);
    try testing.expect(std.mem.indexOf(u8, module_c, "g_app_decrypt_success += 1") == null);

    const guard_idx = std.mem.indexOf(u8, module_c, "if (comptime logger.enable_debug_prints) {") orelse
        return error.MissingDebugGuard;
    const stream_scan_idx = std.mem.indexOf(u8, module_c, "[APP-STREAM-SCAN]") orelse
        return error.MissingStreamScanDiagnostic;
    const payload_hex_idx = std.mem.indexOf(u8, module_c, "[APP-PAYLOAD-HEX]") orelse
        return error.MissingPayloadHexDiagnostic;
    try testing.expect(stream_scan_idx > guard_idx);
    try testing.expect(payload_hex_idx > guard_idx);
}

test "geode enables quic deferred accept until first stream data" {
    // High-fanout setup should not admit one application handler per Initial.
    // The upstream QUIC lib keeps the legacy default, and Geode opts into
    // returning server connections from accept() only after a readable peer
    // stream exists.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const config_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/config.zig", .{quic_dir});
    defer allocator.free(config_path);
    const endpoint_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint.zig", .{quic_dir});
    defer allocator.free(endpoint_path);
    const incoming_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/incoming.zig", .{quic_dir});
    defer allocator.free(incoming_path);

    const maybe_config = try readFile(allocator, config_path);
    const config = maybe_config orelse return error.FileNotFound;
    defer allocator.free(config);
    const maybe_endpoint = try readFile(allocator, endpoint_path);
    const endpoint = maybe_endpoint orelse return error.FileNotFound;
    defer allocator.free(endpoint);
    const maybe_incoming = try readFile(allocator, incoming_path);
    const incoming = maybe_incoming orelse return error.FileNotFound;
    defer allocator.free(incoming);
    const maybe_transport = try readFile(allocator, "src/transport/quic.zig");
    const transport = maybe_transport orelse return error.FileNotFound;
    defer allocator.free(transport);

    try testing.expect(std.mem.indexOf(u8, config, "REQ=REQ-QUIC-HC-063") != null);
    try testing.expect(std.mem.indexOf(u8, config, "defer_accept_until_stream: bool = false") != null);
    try testing.expect(std.mem.indexOf(u8, incoming, "if (!ctx.cfg.defer_accept_until_stream)") != null);
    try testing.expect(std.mem.indexOf(u8, incoming, "c_new.accepted_enqueued = true") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "maybeQueueDeferredAccepted") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "c.incoming_stream_queue.items.len > 0") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "self.accept_cv.signal") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "self.maybeQueueDeferredAccepted(conn)") != null);
    try testing.expect(std.mem.indexOf(u8, transport, ".defer_accept_until_stream = true") != null);
}

test "quic server connection limit accounts for multi-key map registration" {
    // Each server connection is registered by client Initial DCID and server
    // SCID. The public max_connections setting must remain a logical
    // connection cap; otherwise a 512-client burst fills a 1024-entry map and
    // drops retry Initial packets even though only half the configured
    // connection count is active.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const incoming_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/incoming.zig", .{quic_dir});
    defer allocator.free(incoming_path);
    const maybe_incoming = try readFile(allocator, incoming_path);
    const incoming = maybe_incoming orelse return error.FileNotFound;
    defer allocator.free(incoming);

    try testing.expect(std.mem.indexOf(u8, incoming, "REQ=REQ-QUIC-HC-082") != null);
    try testing.expect(std.mem.indexOf(u8, incoming, "fn maxConnectionMapEntries(max_connections: usize) usize") != null);
    try testing.expect(std.mem.indexOf(u8, incoming, "std.math.mul(usize, max_connections, 2)") != null);
    try testing.expect(std.mem.indexOf(u8, incoming, "const max_map_entries = maxConnectionMapEntries(ctx.max_connections)") != null);
    try testing.expect(std.mem.indexOf(u8, incoming, "ctx.conns.count() >= max_map_entries") != null);
    try testing.expect(std.mem.indexOf(u8, incoming, "ctx.conns.count() >= ctx.max_connections") == null);
    try testing.expect(std.mem.indexOf(u8, incoming, "ctx.conns.count() >= ctx.cfg.max_connections") == null);
}

test "quic pending handshake retries are budgeted per poll cycle" {
    // Deferred server Handshake flights can accumulate for every concurrent
    // client. Retrying the whole set inside one endpoint poll cycle starves
    // stream handoff and creates multi-second poll overruns.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const endpoint_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint.zig", .{quic_dir});
    defer allocator.free(endpoint_path);
    const maybe_endpoint = try readFile(allocator, endpoint_path);
    const endpoint = maybe_endpoint orelse return error.FileNotFound;
    defer allocator.free(endpoint);

    try testing.expect(std.mem.indexOf(u8, endpoint, "REQ=REQ-QUIC-HC-058") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "max_pending_hs_send_retries_per_poll_cycle") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "pending_hs_send_snapshot.items.len >= max_pending_hs_send_retries_per_poll_cycle") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "self.pending_hs_send_set.remove(c)") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "self.pending_hs_send_count.store(self.pending_hs_send_set.count(), .release)") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint, "self.pending_hs_send_set.clearRetainingCapacity()") == null);
}

test "quic udp transport raises socket buffers for high fanout" {
    // The server has a single endpoint poller. Under hundreds of simultaneous
    // clients, the kernel UDP queue must absorb the burst long enough for
    // recvmmsg draining to catch up without forcing QUIC PTO recovery.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const udp_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/udp_transport.zig", .{quic_dir});
    defer allocator.free(udp_path);
    const maybe_udp = try readFile(allocator, udp_path);
    const udp = maybe_udp orelse return error.FileNotFound;
    defer allocator.free(udp);

    try testing.expect(std.mem.indexOf(u8, udp, "REQ=REQ-QUIC-HC-038") != null);
    try testing.expect(std.mem.indexOf(u8, udp, "high_concurrency_socket_buffer_bytes") != null);
    try testing.expect(std.mem.indexOf(u8, udp, "linux.SO.RCVBUF") != null);
    try testing.expect(std.mem.indexOf(u8, udp, "linux.SO.SNDBUF") != null);
    try testing.expect(std.mem.indexOf(u8, udp, "posix.SO.RCVBUF") != null);
    try testing.expect(std.mem.indexOf(u8, udp, "posix.SO.SNDBUF") != null);
    try testing.expect(std.mem.indexOf(u8, udp, "configureSocketBuffersLinux(fd)") != null);
    try testing.expect(std.mem.indexOf(u8, udp, "configureSocketBuffersPosix(fd)") != null);
}

test "quic deferred destroy removes all endpoint side-set references" {
    // Handler threads queue inner connections for main-thread destruction.
    // Before api.destroy() frees the connection, Geode must remove every
    // endpoint side-set that stores raw connection pointers.
    const allocator = testing.allocator;

    const maybe_transport = try readFile(allocator, "src/transport/quic.zig");
    const transport = maybe_transport orelse return error.FileNotFound;
    defer allocator.free(transport);

    try testing.expect(std.mem.indexOf(u8, transport, "REQ=REQ-QUIC-HC-034") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "ep.closed_conn_set.remove(inner_conn)") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "ep.pto_dirty_set.remove(inner_conn)") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "ep.pending_hs_send_set.remove(inner_conn)") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "ep.pto_lifetime_mu.lockUncancelable") != null);
    try testing.expect(std.mem.indexOf(u8, transport, "api.destroy(ep, inner_conn)") != null);
}

test "quic connection handlers are not cpu-count auto sized" {
    // Connection handlers are long-lived socket loops. A CPU-count pool can
    // accept more QUIC connections than it has workers able to read HELLO,
    // which looks like a transport deadlock to clients under fan-out.
    const allocator = testing.allocator;
    const maybe_content = try readFile(allocator, "src/server/main.zig");
    const content = maybe_content orelse return error.FileNotFound;
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-PERF-ASYNC-CONN-002") != null);
    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-132") != null);
    try testing.expect(std.mem.indexOf(u8, content, "default_quic_connection_worker_count = 64") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"GEODE_QUIC_CONNECTION_WORKERS\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "falls back to synchronous HELLO admission") != null);
    try testing.expect(std.mem.indexOf(u8, content, "quic_connection_queue_capacity = 1024") != null);
    try testing.expect(std.mem.indexOf(u8, content, ".num_threads = quic_connection_worker_count") != null);
    try testing.expect(std.mem.indexOf(u8, content, ".queue_capacity = quic_connection_queue_capacity") != null);
    try testing.expect(std.mem.indexOf(u8, content, ".blocking_workers = 0") != null);
}

test "quic connection admission can bypass pool worker ceiling" {
    // The external thread-pool dependency caps worker pools at 64. Release
    // builds use short-lived detached admission threads for HELLO fan-out, then
    // hand live streams to the bounded shared stream pool.
    const allocator = testing.allocator;
    const maybe_content = try readFile(allocator, "src/server/main.zig");
    const content = maybe_content orelse return error.FileNotFound;
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-012") != null);
    try testing.expect(std.mem.indexOf(u8, content, "ConnectionAdmissionGate") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"GEODE_QUIC_DETACHED_CONNECTION_ADMISSION\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"GEODE_QUIC_CONNECTION_ADMISSION_THREADS\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "std.Thread.spawn") != null);
    try testing.expect(std.mem.indexOf(u8, content, "handleConnectionAsync") != null);
    try testing.expect(std.mem.indexOf(u8, content, "admission_thread.detach()") != null);
    try testing.expect(std.mem.indexOf(u8, content, "gate.release()") != null);
    try testing.expect(std.mem.indexOf(u8, content, "stream_pool.submit") == null);
}

test "quic high fanout defaults avoid setup admission collapse" {
    // Release stress profiles with 768+ clients should not spend most setup
    // time rejecting accepted connections because the short-lived admission
    // gate is still capped at the old 256 default.
    const allocator = testing.allocator;

    const maybe_main = try readFile(allocator, "src/server/main.zig");
    const main_content = maybe_main orelse return error.FileNotFound;
    defer allocator.free(main_content);
    try testing.expect(std.mem.indexOf(u8, main_content, "default_quic_connection_admission_threads = if (builtin.mode == .Debug) 64 else 1024") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "quic_connection_admission_stack_size = 1024 * 1024") != null);

    const maybe_registry = try readFile(allocator, "src/server/active_stream_registry.zig");
    const registry_content = maybe_registry orelse return error.FileNotFound;
    defer allocator.free(registry_content);
    try testing.expect(std.mem.indexOf(u8, registry_content, "REQ=PERF-P1-004") != null);
    try testing.expect(std.mem.indexOf(u8, registry_content, "default_max_global_stream_threads: u32 = 1024") != null);
}

test "quic high concurrency e2e has bounded setup wait" {
    // A single lost high-fanout handshake must fail the stress test with a
    // clear setup error instead of hanging until every retry deadline expires.
    const allocator = testing.allocator;
    const maybe_content = try readFile(allocator, "tests/e2e_quic_high_concurrency.zig");
    const content = maybe_content orelse return error.FileNotFound;
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "default_setup_timeout_secs") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"GEODE_HC_SETUP_TIMEOUT_SECS\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"GEODE_HC_SETUP_GRACE_SECS\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"GEODE_HC_SETUP_HARD_TIMEOUT_SECS\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"GEODE_HC_HELLO_TIMEOUT_MS\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-131") != null);
    try testing.expect(std.mem.indexOf(u8, content, "setup_hard_timeout_secs") != null);
    try testing.expect(std.mem.indexOf(u8, content, "high-concurrency QUIC E2E setup progress") != null);
    try testing.expect(std.mem.indexOf(u8, content, "last_setup_report_ns") != null);
    try testing.expect(std.mem.indexOf(u8, content, "abort_setup: ?*std.atomic.Value(bool)") != null);
    try testing.expect(std.mem.indexOf(u8, content, "if (abort.load(.acquire)) return error.Aborted;") != null);
    try testing.expect(std.mem.indexOf(u8, content, "if (ctx.abort_setup.load(.acquire)) return;") != null);
    try testing.expect(std.mem.indexOf(u8, content, "setup_elapsed_ns >= @as(u64, setup_timeout_secs) * std.time.ns_per_s") != null);
    try testing.expect(std.mem.indexOf(u8, content, "setup_elapsed_ns >= @as(u64, setup_hard_timeout_secs) * std.time.ns_per_s") != null);
    try testing.expect(std.mem.indexOf(u8, content, "last_progress_ns") != null);
    try testing.expect(std.mem.indexOf(u8, content, "now_ns -| last_progress_ns >= @as(u64, setup_grace_secs) * std.time.ns_per_s") != null);
    try testing.expect(std.mem.indexOf(u8, content, "start_generation") != null);
    try testing.expect(std.mem.indexOf(u8, content, "futexWaitTimeout") != null);
    try testing.expect(std.mem.indexOf(u8, content, "futexWake(u32, &start_generation.raw") != null);
    try testing.expect(std.mem.indexOf(u8, content, "counters.setup_failed.fetchAdd") != null);
    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-072") != null);
    try testing.expect(std.mem.indexOf(u8, content, "settle_deadline_ns") != null);
    try testing.expect(std.mem.indexOf(u8, content, "settle_deadline_ns = monoNs() + @as(u64, setup_grace_secs) * std.time.ns_per_s") != null);
    try testing.expect(std.mem.indexOf(u8, content, "settle_deadline_ns = monoNs() + 5 * std.time.ns_per_s") == null);
    try testing.expect(std.mem.indexOf(u8, content, "if (hello_now >= worker_count) break;") != null);
    try testing.expect(std.mem.indexOf(u8, content, "var hello_after_setup = counters.hello_ok.load(.acquire);") != null);
    try testing.expect(std.mem.indexOf(u8, content, "hello_after_setup = counters.hello_ok.load(.acquire);") != null);
    try testing.expect(std.mem.indexOf(u8, content, "ready_after_setup = counters.ready.load(.acquire)") != null);
    try testing.expect(std.mem.indexOf(u8, content, "const setup_authenticated = hello_after_setup >= worker_count;") != null);
    try testing.expect(std.mem.indexOf(u8, content, "const setup_timeout_failed = setup_timed_out and !setup_authenticated and !setup_ready;") != null);
    try testing.expect(std.mem.indexOf(u8, content, "hello_after_setup={d} authenticated={}") != null);
    try testing.expect(std.mem.indexOf(u8, content, "elapsed_ms={d} execute_attempts={d}") != null);
    try testing.expect(countOccurrences(content, "hello_after_setup = counters.hello_ok.load(.acquire);") >= 2);
    try testing.expect(countOccurrences(content, "ready_after_setup = counters.ready.load(.acquire);") >= 2);
}

test "quic high concurrency e2e can shape request burst" {
    const allocator = testing.allocator;
    const maybe_content = try readFile(allocator, "tests/e2e_quic_high_concurrency.zig");
    const content = maybe_content orelse return error.FileNotFound;
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-042") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"GEODE_HC_REQUEST_STAGGER_US\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "const default_request_stagger_us = if (builtin.mode == .Debug) 0 else 100") != null);
    try testing.expect(std.mem.indexOf(u8, content, "default_request_stagger_us_for_run") != null);
    try testing.expect(std.mem.indexOf(u8, content, "envU32(\"GEODE_HC_REQUEST_STAGGER_US\", default_request_stagger_us_for_run)") != null);
    try testing.expect(std.mem.indexOf(u8, content, "ctx.request_stagger_us") != null);
    try testing.expect(std.mem.indexOf(u8, content, "ctx.worker_id") != null);
}

test "quic high concurrency e2e configures endpoint poll workers" {
    const allocator = testing.allocator;
    const maybe_e2e = try readFile(allocator, "tests/e2e_quic_high_concurrency.zig");
    const e2e = maybe_e2e orelse return error.FileNotFound;
    defer allocator.free(e2e);
    const maybe_main = try readFile(allocator, "src/server/main.zig");
    const main_content = maybe_main orelse return error.FileNotFound;
    defer allocator.free(main_content);

    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_QUIC_POLL_WORKERS={d}") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_HC_POLL_WORKERS") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "REQ=REQ-QUIC-HC-161") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_HC_SHORT_HEADER_TIMING") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_QUIC_SHORT_HEADER_TIMING=1") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_QUIC_SHORT_HEADER_TIMING=0") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "const default_poll_worker_count = if (builtin.mode == .Debug) 1 else 16") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "REQ=REQ-QUIC-HC-141") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "const high_fanout_poll_worker_cap = if (builtin.mode == .Debug) 4 else 64") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "highFanoutPollWorkerDefault(worker_count)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "default_poll_workers_for_run") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "envU32(\"GEODE_HC_POLL_WORKERS\", default_poll_workers_for_run)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "high_fanout_poll_worker_cap") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_QUIC_COOPERATIVE_FIRST_STREAM_WORKERS={d}") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_HC_COOPERATIVE_FIRST_STREAM_WORKERS") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "const default_cooperative_first_stream_worker_count = if (builtin.mode == .Debug) 16 else 256") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "highFanoutCooperativeFirstStreamWorkerDefault(worker_count)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "default_cooperative_first_stream_workers_for_run") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_GROUP_COMMIT_COALESCE_US={d}") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_HC_GROUP_COMMIT_COALESCE_US") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_HC_GROUP_COMMIT") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_GROUP_COMMIT={s}") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_HC_GROUP_COMMIT_PHASE_METRICS") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_GROUP_COMMIT_PHASE_METRICS={s}") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "high_fanout_group_commit_coalesce_us: u32 = 100") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_QUIC_MUTATION_ADMISSION_CAP={d}") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "GEODE_HC_MUTATION_ADMISSION_CAP") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "high_fanout_mutation_admission_cap: u32 = 512") != null);
    try testing.expect(std.mem.indexOf(u8, e2e, "highFanoutMutationAdmissionCapDefault(worker_count)") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "REQ=REQ-QUIC-HC-053") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "REQ=REQ-QUIC-HC-141") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "\"GEODE_QUIC_POLL_WORKERS\"") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "default_quic_poll_worker_count") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "const default_quic_poll_worker_count = if (builtin.mode == .Debug) 1 else 16") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "QUIC v0.1.21") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "64,") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, ".blocking_workers = 0") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "poll_pool.submitDefault") != null);

    const maybe_group_commit = try readFile(allocator, "src/storage/group_commit.zig");
    const group_commit = maybe_group_commit orelse return error.FileNotFound;
    defer allocator.free(group_commit);
    try testing.expect(std.mem.indexOf(u8, group_commit, "REQ=REQ-QUIC-HC-174") != null);
    try testing.expect(std.mem.indexOf(u8, group_commit, "REQ=REQ-QUIC-HC-175") != null);
    try testing.expect(std.mem.indexOf(u8, group_commit, "GEODE_GROUP_COMMIT_COALESCE_US") != null);
    try testing.expect(std.mem.indexOf(u8, group_commit, "max_shard_coalesce_wait_us: u64 = 5000") != null);
    try testing.expect(std.mem.indexOf(u8, group_commit, "shardCoalesceWaitNs()") != null);
    try testing.expect(std.mem.indexOf(u8, group_commit, "coord_submit_wait_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, group_commit, "coord_queue_wait_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, group_commit, "coord_apply_ops_loop_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, group_commit, "coord_apply_commit_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, group_commit, "GEODE_GROUP_COMMIT_PHASE_METRICS") != null);
    try testing.expect(std.mem.indexOf(u8, group_commit, "phaseMetricsEnabled()") != null);
}

test "server stream WouldBlock wait is event driven with high fanout backoff" {
    // The poll generation futex still wakes handlers immediately when packets
    // are delivered. The fallback timeout must stay substantially above the
    // poll hot-loop cadence so idle 100s-of-client tests do not make every
    // stream handler re-enter readStream every 2ms and starve poll().
    const allocator = testing.allocator;

    const maybe_transport = try readFile(allocator, "src/transport/quic.zig");
    const transport_content = maybe_transport orelse return error.FileNotFound;
    defer allocator.free(transport_content);
    try testing.expect(std.mem.indexOf(u8, transport_content, "REQ=REQ-QUIC-HC-025") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "server_handler_wait_for_poll_ns: u64 = 100 * std.time.ns_per_ms") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "const overrun_threshold_ns: u64 = server_handler_wait_for_poll_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "REQ=REQ-QUIC-HC-075") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "server_writer_wait_for_poll_ns: u64 = 1 * std.time.ns_per_ms") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "REQ=REQ-QUIC-HC-083") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "server_writer_max_blocked_ns: u64 = 60 * std.time.ns_per_s") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "fn waitForServerWriterProgress") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "server_writer_retry_yield_every: usize = 64") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "monoNsRaw() -| blocked_start_ns > server_writer_max_blocked_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "err == error.FlowControlBlocked or err == error.WouldBlock") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "ps.waitForPoll(server_writer_wait_for_poll_ns)") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "REQ=REQ-QUIC-HC-036") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "poll_wake_batch_size: u32 = 256") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "futexWake(u32, &self.poll_generation.raw, poll_wake_batch_size)") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "poll_cv") == null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "self.poll_cv.broadcast") == null);

    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler_content = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler_content);
    try testing.expect(std.mem.indexOf(u8, handler_content, "waitForPoll(quic_transport.server_handler_wait_for_poll_ns)") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "waitForPoll(2 * std.time.ns_per_ms)") == null);
}

test "persistent QUIC stream loop yields after each request" {
    // A single persistent stream should not immediately consume a second
    // request while other first-stream owner threads have not yet run their
    // first request. At very high fanout, yielding alone is too weak, so the
    // loop adds a bounded sleep proportional to stream-owner pressure.
    const allocator = testing.allocator;
    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler_content = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler_content);

    try testing.expect(std.mem.indexOf(u8, handler_content, "REQ=REQ-QUIC-HC-026") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "PersistentStreamFairness") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "REQ=REQ-QUIC-HC-027") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "PersistentFollowupBackoff") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "active_stream_handlers > 512") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "excess * 10 * std.time.ns_per_us") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "std.Thread.yield() catch {};") != null);
}

test "quic execute response batches schema and first page" {
    // Small read responses should not emit schema and first page as two separate
    // stream writes under high fan-out. Batching preserves the length-prefixed
    // protocol while cutting the initial response packet burst in half.
    const allocator = testing.allocator;
    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler_content = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler_content);

    try testing.expect(std.mem.indexOf(u8, handler_content, "REQ=REQ-QUIC-HC-077") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "fn sendQuicMessagesBatched") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "try framed.appendSlice(allocator, &len_buf)") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "try stream.writeAll(framed.items)") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "const batched = [_]schema.QuicServerMessage") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "try sendQuicMessagesBatched(ra, stream, &batched)") != null);
}

test "quic empty mutation success responses use batched writes" {
    // Empty CREATE/MERGE/edge success responses are common in mutation-heavy
    // high-fanout workloads. Keep them on the same single-write path as small
    // read responses so each mutation does not double its QUIC write pressure.
    const allocator = testing.allocator;
    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler_content = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler_content);

    try testing.expect(std.mem.indexOf(u8, handler_content, "REQ=REQ-QUIC-HC-089") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "fn sendEmptySuccessResult") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "try sendQuicMessagesBatched(ra, stream, &batched)") != null);
    try testing.expect(countOccurrences(handler_content, "try sendEmptySuccessResult(gpa, stream);") >= 3);

    const create_idx = std.mem.indexOf(u8, handler_content, "fn executeBulkSimpleCreate") orelse return error.MissingBulkCreate;
    const create_body = handler_content[create_idx..];
    const create_record_idx = std.mem.indexOf(u8, create_body, "mut_sample.record(\"bulk_simple_create\")") orelse return error.MissingBulkCreateRecord;
    const create_prefix = create_body[0..create_record_idx];
    try testing.expect(std.mem.indexOf(u8, create_prefix, "try sendQuicMessage") == null);

    const merge_idx = std.mem.indexOf(u8, handler_content, "fn executeBulkSimpleMerge") orelse return error.MissingBulkMerge;
    const merge_body = handler_content[merge_idx..];
    const merge_record_idx = std.mem.indexOf(u8, merge_body, "mut_sample.record(\"bulk_simple_merge\")") orelse return error.MissingBulkMergeRecord;
    const merge_prefix = merge_body[0..merge_record_idx];
    try testing.expect(std.mem.indexOf(u8, merge_prefix, "try sendQuicMessage") == null);
}

test "multi-property merge mutations avoid whole graph writer lock" {
    const allocator = testing.allocator;

    const maybe_bulk = try readFile(allocator, "src/execution/bulk_ingest.zig");
    const bulk_content = maybe_bulk orelse return error.FileNotFound;
    defer allocator.free(bulk_content);
    try testing.expect(std.mem.indexOf(u8, bulk_content, "REQ=REQ-QUIC-HC-109") != null);
    try testing.expect(std.mem.indexOf(u8, bulk_content, "merge_props: []const PropExpr") != null);
    try testing.expect(std.mem.indexOf(u8, bulk_content, "props.len == 0 or props.len > max_merge_props") != null);

    const maybe_adapter = try readFile(allocator, "src/storage/graph_storage_adapter.zig");
    const adapter_content = maybe_adapter orelse return error.FileNotFound;
    defer allocator.free(adapter_content);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "merge_tuple_locks") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "bulkMergeNodeWithReservedIdMultiProp") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "findNodeMatchingMergeProps") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "bulkInsertNodeWithReservedId") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "REQ=REQ-QUIC-HC-111") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "REQ=REQ-QUIC-HC-121") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "REQ=REQ-QUIC-HC-122") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "REQ=REQ-QUIC-HC-162") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "copySmallestMergePropCandidates") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "postingLenIfPresent") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "copy only the smallest candidate list") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "exact_node_property_index.copy") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "copyIfPresent") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "REQ=REQ-QUIC-HC-167") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "const merge_tuple_lock_count: usize = 16384") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "merge_tuple_lock_wait_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "merge_tuple_lock_hold_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "mg_merge_tuple_lock_wait_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "exact_node_property_index_shard_count") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "NodePropertyExactIndexShard") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "exactNodePropertyIndexShardForEncodedKey") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "lockAllShards") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "lockCandidateShardReads") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "if (candidates.len == 0) return null;") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "id_map.nodeUuid(slot_id)") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "store.getNodesByLabel(graph_name, label)") == null);

    const maybe_group = try readFile(allocator, "src/storage/group_commit.zig");
    const group_content = maybe_group orelse return error.FileNotFound;
    defer allocator.free(group_content);
    try testing.expect(std.mem.indexOf(u8, group_content, "bulk_merge_node_props") != null);

    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler_content = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler_content);
    try testing.expect(std.mem.indexOf(u8, handler_content, "merge_kvs.len > 1") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "bulkMergeNodeWithReservedIdMultiProp") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "graph_store.acquireGraphWriteLockCancelable") != null);
}

test "quic response write metrics expose downstream stalls" {
    // High-concurrency failures can happen after the server has decoded every
    // request. Keep response-write counters on the existing runtime metrics
    // surface so regression runs distinguish query execution from QUIC send
    // backpressure and PTO/recovery stalls.
    const allocator = testing.allocator;

    const maybe_metrics = try readFile(allocator, "src/transport/quic_response_metrics.zig");
    const metrics_content = maybe_metrics orelse return error.FileNotFound;
    defer allocator.free(metrics_content);
    try testing.expect(std.mem.indexOf(u8, metrics_content, "REQ=REQ-QUIC-HC-078") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_content, "quic_stream_write_blocked_retries_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_content, "quic_response_messages_completed_total") != null);

    const maybe_transport = try readFile(allocator, "src/transport/quic.zig");
    const transport_content = maybe_transport orelse return error.FileNotFound;
    defer allocator.free(transport_content);
    try testing.expect(std.mem.indexOf(u8, transport_content, "quic_response_metrics.recordStreamWriteStart") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "quic_response_metrics.recordStreamWriteBlocked") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "quic_response_metrics.recordStreamWriteZeroReturn") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "quic_response_metrics.recordStreamWriteSuccess") != null);

    const maybe_main = try readFile(allocator, "src/server/main.zig");
    const main_content = maybe_main orelse return error.FileNotFound;
    defer allocator.free(main_content);
    try testing.expect(std.mem.indexOf(u8, main_content, "try quic_response_metrics.registerAll(metrics_registry)") != null);
}

test "high concurrency harness scrapes runtime diagnostics from metrics endpoint" {
    const allocator = testing.allocator;

    const maybe_metrics_server = try readFile(allocator, "src/monitoring/metrics_server.zig");
    const metrics_server = maybe_metrics_server orelse return error.FileNotFound;
    defer allocator.free(metrics_server);
    try testing.expect(std.mem.indexOf(u8, metrics_server, "REQ=REQ-QUIC-HC-172") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_server, "RuntimeMetricsScrape") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_server, "pub const RuntimeSnapshotCallback") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_server, "setRuntimeSnapshotCallback") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_server, "g_runtime_snapshot_mu") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_server, "g_runtime_snapshot_mu.lockUncancelable") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_server, "runtime_body") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_server, "MetricsAcceptWake") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_server, "fn wakeAcceptLoop") != null);
    try testing.expect(std.mem.indexOf(u8, metrics_server, "wakeAcceptLoop(self.port)") != null);

    const maybe_main = try readFile(allocator, "src/server/main.zig");
    const main_content = maybe_main orelse return error.FileNotFound;
    defer allocator.free(main_content);
    try testing.expect(std.mem.indexOf(u8, main_content, "runtimeMetricsPrometheusSnapshot") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "registry.snapshotInto") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "metrics_server.setRuntimeSnapshotCallback(runtimeMetricsPrometheusSnapshot, metrics_registry)") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "metrics_server.setRuntimeSnapshotCallback(null, null)") != null);

    const maybe_harness = try readFile(allocator, "tests/e2e_quic_high_concurrency.zig");
    const harness = maybe_harness orelse return error.FileNotFound;
    defer allocator.free(harness);
    try testing.expect(std.mem.indexOf(u8, harness, "GEODE_HC_METRICS_SCRAPE") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "GEODE_METRICS_PORT={d}") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "printRuntimeMetricsSnapshot") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "quic_stream_write_elapsed_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "quic_first_stream_query_execute_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "quic_first_stream_read_query_execute_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "quic_first_stream_mutation_query_execute_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "quic_poll_cycle_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "quic_poll_overrun_total") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "mg_merge_tuple_lock_wait_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "mg_rwlock_shared_hold_bulk_merge_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "coord_apply_batches_total") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "coord_apply_ops_total") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "coord_submit_wait_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "coord_queue_wait_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "coord_apply_ops_loop_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, harness, "coord_apply_commit_ns_total") != null);

    const maybe_lifecycle = try readFile(allocator, "tests/test_metrics_server_lifecycle.zig");
    const lifecycle = maybe_lifecycle orelse return error.FileNotFound;
    defer allocator.free(lifecycle);
    try testing.expect(std.mem.indexOf(u8, lifecycle, "MetricsServer /metrics appends runtime high-concurrency counters") != null);
    try testing.expect(std.mem.indexOf(u8, lifecycle, "quic_stream_write_elapsed_ns_total 42") != null);
    try testing.expect(std.mem.indexOf(u8, lifecycle, "mg_merge_tuple_lock_wait_ns_total 99") != null);
}

test "quic app ack path sends normal ack packet once" {
    // Under high response fan-out, duplicating every normal ACK-only packet
    // doubles UDP pressure and holds senders in congestion-window zero-return
    // loops. The ACK helper must be the only send/accounting path.
    const allocator = testing.allocator;

    const quic_dir = (try findVendoredQuicDir(allocator)) orelse return error.FileNotFound;
    defer allocator.free(quic_dir);
    const module_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/incoming/module_b2.zig", .{quic_dir});
    defer allocator.free(module_path);

    const maybe_module = try readFile(allocator, module_path);
    const module_content = maybe_module orelse return error.FileNotFound;
    defer allocator.free(module_content);

    try testing.expect(std.mem.indexOf(u8, module_content, "REQ=REQ-QUIC-HC-086") != null);
    try testing.expect(std.mem.indexOf(u8, module_content, "normal ACK send failed") == null);
    const helper_idx = std.mem.indexOf(u8, module_content, "const sent_ok = sendAppPacketAndTrack(ack_ctx, pkt, false, \"normal ACK\")") orelse return error.MissingNormalAckHelperSend;
    const send_end_idx = std.mem.indexOf(u8, module_content[helper_idx..], "const send_end_ns") orelse return error.MissingNormalAckTimingEnd;
    try testing.expect(send_end_idx > 0);
    try testing.expectEqual(@as(usize, 1), countOccurrences(module_content, "sendAppPacketAndTrack(ack_ctx, pkt, false, \"normal ACK\")"));
}

test "quic server writers wait on per-connection tx credit" {
    // Response writers blocked on congestion credit should wake when ACK
    // processing frees this connection's bytes-in-flight, not on every
    // endpoint poll cycle for unrelated connections.
    const allocator = testing.allocator;

    const quic_dir = (try findVendoredQuicDir(allocator)) orelse return error.FileNotFound;
    defer allocator.free(quic_dir);

    const conn_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/conn.zig", .{quic_dir});
    defer allocator.free(conn_path);
    const maybe_conn = try readFile(allocator, conn_path);
    const conn_content = maybe_conn orelse return error.FileNotFound;
    defer allocator.free(conn_content);
    try testing.expect(std.mem.indexOf(u8, conn_content, "REQ=REQ-QUIC-HC-087") != null);
    try testing.expect(std.mem.indexOf(u8, conn_content, "tx_credit_generation: std.atomic.Value(u32)") != null);

    const methods_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/connection/methods_b.zig", .{quic_dir});
    defer allocator.free(methods_path);
    const maybe_methods = try readFile(allocator, methods_path);
    const methods_content = maybe_methods orelse return error.FileNotFound;
    defer allocator.free(methods_content);
    try testing.expect(std.mem.indexOf(u8, methods_content, "if (res.bytes_acked > 0)") != null);
    try testing.expect(std.mem.indexOf(u8, methods_content, "space == .Application and res.bytes_acked > 0") == null);
    try testing.expect(std.mem.indexOf(u8, methods_content, "self.tx_credit_generation.fetchAdd(1, .release)") != null);
    try testing.expect(std.mem.indexOf(u8, methods_content, "futexWake(u32, &self.tx_credit_generation.raw") != null);

    const tx_credit_test_path = try std.fmt.allocPrint(allocator, "{s}/tests/test_tx_credit_generation.zig", .{quic_dir});
    defer allocator.free(tx_credit_test_path);
    const maybe_tx_credit_test = try readFile(allocator, tx_credit_test_path);
    const tx_credit_test_content = maybe_tx_credit_test orelse return error.FileNotFound;
    defer allocator.free(tx_credit_test_content);
    try testing.expect(std.mem.indexOf(u8, tx_credit_test_content, "tx_credit_generation_initializes_from_allocator_fill_bytes") != null);
    try testing.expect(std.mem.indexOf(u8, tx_credit_test_content, "tx_credit_generation_advances_for_handshake_space_ack_credit") != null);

    const maybe_transport = try readFile(allocator, "src/transport/quic.zig");
    const transport_content = maybe_transport orelse return error.FileNotFound;
    defer allocator.free(transport_content);
    try testing.expect(std.mem.indexOf(u8, transport_content, "server_writer_credit_wait_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "stream.connection.tx_credit_generation.raw") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "const observed_credit_generation = self.connection.tx_credit_generation.load(.acquire)") != null);
}

test "geode configures larger initial quic congestion window" {
    const allocator = testing.allocator;

    const quic_dir = (try findVendoredQuicDir(allocator)) orelse return error.FileNotFound;
    defer allocator.free(quic_dir);

    const config_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/config.zig", .{quic_dir});
    defer allocator.free(config_path);
    const maybe_config = try readFile(allocator, config_path);
    const config_content = maybe_config orelse return error.FileNotFound;
    defer allocator.free(config_content);
    try testing.expect(std.mem.indexOf(u8, config_content, "REQ=REQ-QUIC-HC-088") != null);
    try testing.expect(std.mem.indexOf(u8, config_content, "initial_congestion_window_packets: u16 = 10") != null);

    const recovery_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/recovery/recovery.zig", .{quic_dir});
    defer allocator.free(recovery_path);
    const maybe_recovery = try readFile(allocator, recovery_path);
    const recovery_content = maybe_recovery orelse return error.FileNotFound;
    defer allocator.free(recovery_content);
    try testing.expect(std.mem.indexOf(u8, recovery_content, "pub fn setInitialCongestionWindowPackets") != null);
    try testing.expect(std.mem.indexOf(u8, recovery_content, "self.cc.cwnd = mulSaturatingUsize(self.cc.mds, clamped_packets)") != null);

    const maybe_transport = try readFile(allocator, "src/transport/quic.zig");
    const transport_content = maybe_transport orelse return error.FileNotFound;
    defer allocator.free(transport_content);
    try testing.expect(std.mem.indexOf(u8, transport_content, "const high_concurrency_initial_cwnd_packets: u16 = 64") != null);
    try testing.expect(countOccurrences(transport_content, ".initial_congestion_window_packets = high_concurrency_initial_cwnd_packets") >= 3);
}

test "quic metrics watchdog does not consume connection handler worker" {
    // The metrics/stall watchdog is long-lived. It must not run on the
    // connection-handler pool because every occupied worker lowers the number
    // of concurrent clients that can complete HELLO.
    const allocator = testing.allocator;
    const maybe_content = try readFile(allocator, "src/server/main.zig");
    const content = maybe_content orelse return error.FileNotFound;
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-010") != null);
    try testing.expect(std.mem.indexOf(u8, content, "const metrics_pool = thread_pool.ThreadPool.init") != null);
    try testing.expect(std.mem.indexOf(u8, content, "try metrics_pool.submitBlocking") != null);
    try testing.expect(std.mem.indexOf(u8, content, "pool.submitDefault(.{ .context = @ptrCast(metrics_ctx), .callback = metricsLoop })") == null);
}

test "quic dependency uses Geode serial parallel facade" {
    // Geode owns the server-side concurrency pools and configures their idle
    // park cadence through transport/thread_pool. The QUIC package's optional
    // internal pool uses raw defaults, so Geode disables it and wires a serial
    // facade for the recovery modules that still import "parallel".
    const allocator = testing.allocator;
    const maybe_content = try readFile(allocator, "build.zig");
    const content = maybe_content orelse return error.FileNotFound;
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-003") != null);
    try testing.expect(std.mem.indexOf(u8, content, ".thread_pool = false") != null);
    try testing.expect(std.mem.indexOf(u8, content, "quic_parallel_serial.zig") != null);
    try testing.expect(std.mem.indexOf(u8, content, "zig_client_real_mod.addImport(\"quic\", quic_ext_mod)") != null);
}

test "quic shutdown signals handlers before stopping poll loop" {
    // The poll loop must outlive connection-handler pool teardown. Otherwise
    // handlers parked in PollSync.waitForPoll cannot observe close/EOF during
    // SIGTERM and server shutdown can hang waiting for the pool to join.
    const allocator = testing.allocator;

    const maybe_main = try readFile(allocator, "src/server/main.zig");
    const main_content = maybe_main orelse return error.FileNotFound;
    defer allocator.free(main_content);

    const poll_order = std.mem.indexOf(u8, main_content, "REQ=REQ-QUIC-HC-004") orelse return error.MissingPollLifetimeCanary;
    const stream_pool_order = std.mem.indexOf(u8, main_content, "REQ=REQ-PERF-STREAM-POOL-001") orelse return error.MissingStreamPoolCanary;
    try testing.expect(poll_order < stream_pool_order);
    try testing.expect(std.mem.indexOf(u8, main_content, "transport.requestShutdown();") != null);

    const maybe_transport = try readFile(allocator, "src/transport/quic.zig");
    const transport_content = maybe_transport orelse return error.FileNotFound;
    defer allocator.free(transport_content);
    try testing.expect(std.mem.indexOf(u8, transport_content, "REQ=REQ-QUIC-HC-004") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "pub fn requestShutdown(self: *QuicTransport)") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "shutdown_requested") != null);
}

test "quic protocol clients do not impose 10ms read retry floors" {
    // High-concurrency E2E and CLI query paths use the same protocol client
    // wrappers as regular tests. A fixed 10ms sleep/poll in every
    // WouldBlock retry caps apparent request throughput and can hide server
    // improvements behind client-side latency.
    const allocator = testing.allocator;

    const maybe_proto = try readFile(allocator, "tests/proto_test_util.zig");
    const proto_content = maybe_proto orelse return error.FileNotFound;
    defer allocator.free(proto_content);
    try testing.expect(std.mem.indexOf(u8, proto_content, "REQ=REQ-QUIC-HC-005") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "REQ=REQ-QUIC-HC-041") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "REQ=REQ-QUIC-HC-043") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "REQ=REQ-QUIC-HC-149") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "REQ=REQ-QUIC-HC-154") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "REQ=REQ-QUIC-HC-120") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "pub const ExecTiming = struct") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "executeAndCollectWithTimeoutTiming") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "first_response_wait_ns") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "timed_out_before_first_response") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "const MessageWriteTiming = struct") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "fn writeMessageTimed") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "post_write_poll: bool = true") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "execute_stream_write_ns") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "execute_post_write_poll_ns") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "measured.stream_write_ns") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "measured.post_write_poll_ns") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "if (self.post_write_poll)") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "try self.stream.writeAll(framed)") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "try self.stream.writeAll(&len_buf)") == null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "try self.client.poll(0)") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "return packet;") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "try self.client.poll(1)") == null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "read_wait_misses: u32 = 0") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "self.read_wait_misses +|= 1") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "100 * std.time.ns_per_us") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "250 * std.time.ns_per_us") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "std.time.ns_per_ms") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "self.resetReadWaitMisses();") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "fn waitForReadProgress") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "timeout_ms / 10") == null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "compat_sleep(10 * std.time.ns_per_ms)") == null);

    const maybe_transport = try readFile(allocator, "src/transport/quic.zig");
    const transport_content = maybe_transport orelse return error.FileNotFound;
    defer allocator.free(transport_content);
    try testing.expect(std.mem.indexOf(u8, transport_content, "REQ=REQ-QUIC-HC-005") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "recordStreamWriteSuccess(written, monoNsRaw() -| write_start_ns)") != null);
    try testing.expect(countOccurrences(transport_content, "err == error.FlowControlBlocked or err == error.WouldBlock") >= 2);
    try testing.expect(std.mem.indexOf(u8, transport_content, "api.poll(self.endpoint, 10) catch {}; // Best-effort poll for incoming data") == null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "api.poll(self.endpoint, 5) catch {}; // Best-effort poll for flow control") == null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "api.poll(self.endpoint, 5) catch {}; // Best-effort poll for congestion") == null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "REQ=REQ-QUIC-HC-084") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "client_writer_max_blocked_ns: u64 = 60 * std.time.ns_per_s") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "const max_blocked_ns: u64 = client_writer_max_blocked_ns") != null);
    try testing.expect(std.mem.indexOf(u8, transport_content, "const max_blocked_ns: u64 = 10 * std.time.ns_per_s") == null);
}

test "quic response metrics expose stream write latency counters" {
    const allocator = testing.allocator;

    const maybe_metrics = try readFile(allocator, "src/transport/quic_response_metrics.zig");
    const metrics = maybe_metrics orelse return error.FileNotFound;
    defer allocator.free(metrics);

    try testing.expect(std.mem.indexOf(u8, metrics, "REQ=REQ-QUIC-HC-153") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "ResponseWriteLatency") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "stream_write_elapsed_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "stream_write_elapsed_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "fn recordMax") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "pub fn recordStreamWriteSuccess(bytes: usize, elapsed_ns: u64)") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "quic_stream_write_elapsed_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "quic_stream_write_elapsed_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "REQ=REQ-QUIC-HC-157") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "FirstStreamSchedulerLatency") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "first_stream_ready_queue_wait_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "first_stream_ready_queue_wait_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "first_stream_packet_process_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "first_stream_packet_process_max_ns") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "first_stream_mutation_deferrals_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "quic_first_stream_ready_queue_wait_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "quic_first_stream_packet_process_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "REQ=REQ-QUIC-HC-169") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "FirstStreamPhaseLatency") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "first_stream_query_prepare_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "first_stream_query_execute_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "first_stream_response_send_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "REQ=REQ-QUIC-HC-173") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "ReadMutationExecuteSplit") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "first_stream_read_query_execute_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "first_stream_mutation_query_execute_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "beginFirstStreamPhaseSample") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "endFirstStreamPhaseSample") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "recordFirstStreamQueryPrepare") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "recordFirstStreamQueryExecute") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "recordFirstStreamReadQueryExecute") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "recordFirstStreamMutationQueryExecute") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "recordFirstStreamResponseSend") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "quic_first_stream_query_prepare_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "quic_first_stream_query_execute_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "quic_first_stream_read_query_execute_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "quic_first_stream_mutation_query_execute_ns_total") != null);
    try testing.expect(std.mem.indexOf(u8, metrics, "quic_first_stream_response_send_ns_total") != null);

    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler);
    try testing.expect(std.mem.indexOf(u8, handler, "cooperative_enqueued_ns: std.atomic.Value(u64)") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "recordFirstStreamReadyEnqueued") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "recordFirstStreamReadyDequeued") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "recordFirstStreamPacketStart") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "recordFirstStreamPacketComplete") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "recordFirstStreamMutationDeferral") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "const packet_process_start_ns = monoNsFromHandler();") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "beginFirstStreamPhaseSample") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "endFirstStreamPhaseSample") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "recordFirstStreamResponseSend") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "recordFirstStreamQueryPrepare") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "recordFirstStreamReadQueryExecute") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "recordFirstStreamMutationQueryExecute") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "const first_stream_prepare_start_ns = monoNsFromHandler();") != null);
    try testing.expect(std.mem.indexOf(u8, handler, "const first_stream_execute_start_ns = monoNsFromHandler();") != null);
}

test "quic ack packets are tracked only after successful sends" {
    // ACK-only/control packets are sent directly from endpoint receive handling,
    // not through Connection.send(). Under UDP send-buffer pressure they must not
    // advance packet-number/recovery state unless the datagram actually left the
    // process; otherwise future STREAM sends inherit false recovery state.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const module_b2_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/incoming/module_b2.zig", .{quic_dir});
    defer allocator.free(module_b2_path);
    const maybe_module_b2 = try readFile(allocator, module_b2_path);
    const module_b2 = maybe_module_b2 orelse return error.FileNotFound;
    defer allocator.free(module_b2);

    try testing.expect(std.mem.indexOf(u8, module_b2, "REQ=REQ-QUIC-HC-074") != null);
    try testing.expect(std.mem.indexOf(u8, module_b2, "fn sendAppPacketAndTrack") != null);
    try testing.expect(std.mem.indexOf(u8, module_b2, "const sent = ack_ctx.send_fn(ack_ctx.peer, pkt) catch") != null);
    try testing.expect(std.mem.indexOf(u8, module_b2, "if (sent != pkt.len)") != null);
    try testing.expect(std.mem.indexOf(u8, module_b2, "ack_ctx.conn.onShortHeaderPacketSent(pkt.len, ack_eliciting)") != null);
    try testing.expect(countOccurrences(module_b2, "sendAppPacketAndTrack(ack_ctx, pkt") >= 5);
}

test "quic server app packet receive path avoids contended standalone control work" {
    // Request STREAM packets should wake application handlers quickly. The
    // upstream QUIC receive path must keep request ACKs and initial receive
    // flow-control feedback immediate while avoiding contended ACK-frame mutex
    // waits that can block endpoint poll workers.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const frame_handler_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/frame_handler.zig", .{quic_dir});
    defer allocator.free(frame_handler_path);
    const module_c_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/incoming/module_c.zig", .{quic_dir});
    defer allocator.free(module_c_path);
    const methods_a_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/connection/methods_a.zig", .{quic_dir});
    defer allocator.free(methods_a_path);
    const methods_b_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/connection/methods_b.zig", .{quic_dir});
    defer allocator.free(methods_b_path);

    const maybe_frame_handler = try readFile(allocator, frame_handler_path);
    const frame_handler = maybe_frame_handler orelse return error.FileNotFound;
    defer allocator.free(frame_handler);
    const maybe_module_c = try readFile(allocator, module_c_path);
    const module_c = maybe_module_c orelse return error.FileNotFound;
    defer allocator.free(module_c);
    const maybe_methods_a = try readFile(allocator, methods_a_path);
    const methods_a = maybe_methods_a orelse return error.FileNotFound;
    defer allocator.free(methods_a);
    const maybe_methods_b = try readFile(allocator, methods_b_path);
    const methods_b = maybe_methods_b orelse return error.FileNotFound;
    defer allocator.free(methods_b);

    try testing.expect(std.mem.indexOf(u8, frame_handler, "REQ=REQ-QUIC-HC-143") != null);
    try testing.expect(std.mem.indexOf(u8, frame_handler, "ctx.conn.mu.tryLock()") != null);
    try testing.expect(std.mem.indexOf(u8, frame_handler, "if (!ctx.conn.mu.tryLock()) return .{};") != null);
    try testing.expect(std.mem.indexOf(u8, frame_handler, "saw_stream: bool = false") != null);
    try testing.expect(std.mem.indexOf(u8, frame_handler, ".saw_stream = true") != null);
    try testing.expect(std.mem.indexOf(u8, module_c, "defer_server_stream_ack") == null);
    try testing.expect(std.mem.indexOf(u8, module_c, "REQ=REQ-QUIC-HC-144") == null);
    try testing.expect(std.mem.indexOf(u8, module_c, "if ((frame_result.saw_ack_eliciting or conn.ecn_app_ack_pending) and conn.app_tx_keys != null)") != null);
    try testing.expect(std.mem.indexOf(u8, methods_a, "REQ=REQ-QUIC-HC-145") == null);
    const immediate_fc_idx = std.mem.indexOf(u8, methods_a, "s.last_sent_max_stream_data == 0") orelse return error.MissingImmediateFlowControlBlock;
    const immediate_fc_block = methods_a[immediate_fc_idx..@min(methods_a.len, immediate_fc_idx + 1000)];
    try testing.expect(std.mem.indexOf(u8, immediate_fc_block, "self.markStreamFlowControlDirty(stream_id);") != null);
    try testing.expect(std.mem.indexOf(u8, immediate_fc_block, "self.advertiseInitialFlowControl();") != null);
    try testing.expect(std.mem.indexOf(u8, methods_b, "REQ=REQ-QUIC-HC-145") == null);
    try testing.expect(std.mem.indexOf(u8, methods_b, "self.appendDirtyMaxStreamDataFrames(frame_stream.writer(), 64)") == null);
}

test "quic app pto retransmit state advances only after full sends" {
    // Application PTO is the recovery path for high-fanout request packets that
    // are dropped before the server reads them. A failed or partial UDP send
    // must leave the original STREAM retransmit entry in place instead of
    // advancing the packet number and bytes-in-flight accounting.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const methods_b_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/connection/methods_b.zig", .{quic_dir});
    defer allocator.free(methods_b_path);
    const maybe_methods_b = try readFile(allocator, methods_b_path);
    const methods_b = maybe_methods_b orelse return error.FileNotFound;
    defer allocator.free(methods_b);

    try testing.expect(std.mem.indexOf(u8, methods_b, "REQ=REQ-QUIC-HC-079") != null);
    try testing.expect(std.mem.indexOf(u8, methods_b, "REQ=REQ-QUIC-HC-080") != null);
    try testing.expect(std.mem.indexOf(u8, methods_b, "tracked.retransmit_count >= 8") == null);
    try testing.expect(std.mem.indexOf(u8, methods_b, "recordAppStreamRetransmitAttempt") != null);
    try testing.expect(std.mem.indexOf(u8, methods_b, "const sent = self.send(pkt) catch") != null);
    try testing.expect(std.mem.indexOf(u8, methods_b, "if (sent != pkt.len)") != null);
    try testing.expect(std.mem.indexOf(u8, methods_b, "self.app_stream_retx.put(lost_pn, tracked)") != null);
    try testing.expect(std.mem.indexOf(u8, methods_b, "if (sent == pkt.len)") != null);
    try testing.expect(std.mem.indexOf(u8, methods_b, "self.app_stream_retx.put(probe_pn, tracked)") != null);

    const pto_canary = std.mem.indexOf(u8, methods_b, "REQ=REQ-QUIC-HC-079") orelse return error.MissingAppPtoAccountingCanary;
    const pto_block = methods_b[pto_canary..@min(methods_b.len, pto_canary + 8000)];
    try testing.expect(std.mem.indexOf(u8, pto_block, "if (sent == pkt.len)") != null);
    try testing.expect(std.mem.indexOf(u8, pto_block, "self.onShortHeaderPacketSent(pkt.len, true)") != null);
    try testing.expect(std.mem.indexOf(u8, pto_block, "logger.warn(\"PTO App send failed") != null);
}

test "quic initial and handshake state advances only after full sends" {
    // The 512-client setup path was failing one tail connection after the QUIC
    // sender reported failure/short-write while Initial or Handshake state was
    // still advanced. All handshake send paths must gate PN/recovery/accounting
    // on a full datagram send, and buffered coalesced flights must stay queued
    // until that happens.
    const allocator = testing.allocator;

    const quic_dir = try findVendoredQuicDir(allocator) orelse return error.SkipZigTest;
    defer allocator.free(quic_dir);

    const handshake_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/handshake_integration.zig", .{quic_dir});
    defer allocator.free(handshake_path);
    const module_b_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/incoming/module_b.zig", .{quic_dir});
    defer allocator.free(module_b_path);
    const methods_a_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/connection/methods_a.zig", .{quic_dir});
    defer allocator.free(methods_a_path);
    const methods_b_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/connection/methods_b.zig", .{quic_dir});
    defer allocator.free(methods_b_path);
    const pto_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint/pto.zig", .{quic_dir});
    defer allocator.free(pto_path);

    const maybe_handshake = try readFile(allocator, handshake_path);
    const handshake = maybe_handshake orelse return error.FileNotFound;
    defer allocator.free(handshake);
    const maybe_module_b = try readFile(allocator, module_b_path);
    const module_b = maybe_module_b orelse return error.FileNotFound;
    defer allocator.free(module_b);
    const maybe_methods_a = try readFile(allocator, methods_a_path);
    const methods_a = maybe_methods_a orelse return error.FileNotFound;
    defer allocator.free(methods_a);
    const maybe_methods_b = try readFile(allocator, methods_b_path);
    const methods_b = maybe_methods_b orelse return error.FileNotFound;
    defer allocator.free(methods_b);
    const maybe_pto = try readFile(allocator, pto_path);
    const pto = maybe_pto orelse return error.FileNotFound;
    defer allocator.free(pto);

    try testing.expect(countOccurrences(handshake, "REQ=REQ-QUIC-HC-081") >= 1);
    try testing.expect(countOccurrences(module_b, "REQ=REQ-QUIC-HC-081") >= 1);
    try testing.expect(countOccurrences(methods_a, "REQ=REQ-QUIC-HC-081") >= 1);
    try testing.expect(countOccurrences(methods_b, "REQ=REQ-QUIC-HC-081") >= 1);
    try testing.expect(countOccurrences(pto, "REQ=REQ-QUIC-HC-081") >= 1);

    try testing.expect(std.mem.indexOf(u8, handshake, "fn sendDatagramFull") != null);
    try testing.expect(std.mem.indexOf(u8, handshake, "if (sent != data.len)") != null);
    try testing.expect(std.mem.indexOf(u8, handshake, "try sendDatagramFull(ctx, coalesced_buf[0..coalesced_len])") != null);
    try testing.expect(std.mem.indexOf(u8, handshake, "conn.onPacketSent(.Initial, conn.pn_initial_tx, initial_pkt.len, true)") != null);
    try testing.expect(std.mem.indexOf(u8, handshake, "conn.onPacketSent(.Handshake, conn.pn_handshake_tx, hs_pkt.len, true)") != null);
    try testing.expect(std.mem.indexOf(u8, handshake, "conn.pending_hs_messages = null; // Clear immediately") == null);

    const send_packets_idx = std.mem.indexOf(u8, handshake, "pub fn sendHandshakePackets") orelse return error.MissingSendHandshakePackets;
    const send_packets = handshake[send_packets_idx..];
    const coalesced_send_idx = std.mem.indexOf(u8, send_packets, "try sendDatagramFull(ctx, coalesced_buf[0..coalesced_len])") orelse return error.MissingCoalescedFullSend;
    const coalesced_initial_account_idx = std.mem.indexOf(u8, send_packets, "conn.onPacketSent(.Initial, conn.pn_initial_tx, initial_pkt.len, true)") orelse return error.MissingCoalescedInitialAccount;
    const coalesced_handshake_account_idx = std.mem.indexOf(u8, send_packets, "conn.onPacketSent(.Handshake, conn.pn_handshake_tx, pkt.len, true)") orelse return error.MissingCoalescedHandshakeAccount;
    try testing.expect(coalesced_send_idx < coalesced_initial_account_idx);
    try testing.expect(coalesced_send_idx < coalesced_handshake_account_idx);

    try testing.expect(std.mem.indexOf(u8, module_b, "fn sendHandshakeDatagramFull") != null);
    try testing.expect(std.mem.indexOf(u8, module_b, "if (sent != data.len)") != null);
    try testing.expect(std.mem.indexOf(u8, module_b, "if (!sendHandshakeDatagramFull(send_fn, peer, bytes_out, \"Handshake CRYPTO\")) return") != null);
    try testing.expect(std.mem.indexOf(u8, module_b, "if (sendHandshakeDatagramFull(send_fn, peer, bytes_out, \"Handshake ACK\"))") != null);

    try testing.expect(std.mem.indexOf(u8, methods_a, "sendInitialCrypto short send") != null);
    try testing.expect(std.mem.indexOf(u8, methods_a, "sendHandshakeCrypto short send") != null);
    try testing.expect(std.mem.indexOf(u8, methods_b, "PTO Initial CRYPTO retx short send") != null);
    try testing.expect(std.mem.indexOf(u8, methods_b, "PTO Handshake CRYPTO retx short send") != null);
    try testing.expect(std.mem.indexOf(u8, pto, "fn sendPtoDatagramFull") != null);
    try testing.expect(std.mem.indexOf(u8, pto, "try sendPtoDatagramFull(ctx, pkt)") != null);
}

test "quic e2e harness hard-stops child servers after stress failures" {
    // The high-fanout E2E deliberately starts throwaway child servers. If a
    // failed stress run leaves the server's graceful shutdown path waiting on
    // a stuck worker, the harness must still reap the child so later tests do
    // not inherit a live server process.
    const allocator = testing.allocator;

    const maybe_proto = try readFile(allocator, "tests/proto_test_util.zig");
    const proto_content = maybe_proto orelse return error.FileNotFound;
    defer allocator.free(proto_content);

    try testing.expect(std.mem.indexOf(u8, proto_content, "REQ=REQ-QUIC-HC-057") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "posix.kill(pid, .KILL)") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "self.child.wait(io)") != null);
}

test "quic non-transactional simple mutations use default fast paths" {
    // The direct adapter paths keep no-RETURN scalar CREATE/MERGE and
    // match-create-edge write critical sections short. They must stay active
    // for ordinary QUIC traffic, not only opt-in bulk-ingest runs.
    const allocator = testing.allocator;
    const maybe_content = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const content = maybe_content orelse return error.FileNotFound;
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-006") != null);
    const block_start = std.mem.indexOf(u8, content, "if (is_mutation and !state.in_txn and !geode.bulk_ingest.isEnabled() and graph_store.getGlobalAdapter() != null)") orelse return error.MissingDefaultFastPathBlock;
    const block = content[block_start..@min(content.len, block_start + 1800)];
    try testing.expect(std.mem.indexOf(u8, block, "bulk_shape == .simple_node_create") != null);
    try testing.expect(std.mem.indexOf(u8, block, "executeBulkSimpleCreate") != null);
    try testing.expect(std.mem.indexOf(u8, block, "bulk_shape == .match_create_edge") != null);
    try testing.expect(std.mem.indexOf(u8, block, "executeBulkMatchCreateEdge") != null);
    try testing.expect(std.mem.indexOf(u8, block, "bulk_shape == .simple_node_merge") != null);
    try testing.expect(std.mem.indexOf(u8, block, "executeBulkSimpleMerge") != null);
}

test "quic session auth validation uses epoch fast path" {
    // Persistent auth graph version checks must not run on every request. The
    // session state carries the observed invalidation epoch and only re-enters
    // user_management when an auth mutation changes that epoch.
    const allocator = testing.allocator;

    const maybe_auth = try readFile(allocator, "src/security/user_management.zig");
    const auth_content = maybe_auth orelse return error.FileNotFound;
    defer allocator.free(auth_content);
    try testing.expect(std.mem.indexOf(u8, auth_content, "REQ=REQ-QUIC-HC-007") != null);
    try testing.expect(std.mem.indexOf(u8, auth_content, "auth_invalidation_epoch") != null);
    try testing.expect(std.mem.indexOf(u8, auth_content, "pub fn isSessionAuthCurrentCached") != null);

    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler_content = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler_content);
    try testing.expect(std.mem.indexOf(u8, handler_content, "authenticated_auth_validation_epoch") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "isSessionAuthCurrentCached") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "authInvalidationEpoch()") != null);
}

test "quic count-only reads bypass query snapshot clone" {
    // Count-only reads should reach the existing O(1) count fast path before
    // the handler captures a deep QueryReadSession snapshot.
    const allocator = testing.allocator;
    const maybe_content = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const content = maybe_content orelse return error.FileNotFound;
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-008") != null);
    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-146") != null);
    const direct_count = std.mem.indexOf(u8, content, "execution.countNodesLabelRefcountFastPath") orelse return error.MissingGraphLockFreeCountPath;
    const point_read_lock = std.mem.indexOf(u8, content, "graph_store.acquireGraphReadLockTagged(query_graph_name, .point_read)") orelse return error.MissingPointReadLock;
    try testing.expect(direct_count < point_read_lock);
    const fast_path = std.mem.indexOf(u8, content, "execution.countNodesFastPath") orelse return error.MissingCountFastPath;
    const snapshot_path = std.mem.indexOf(u8, content, "graph_store.snapshotUnderReadLock(gpa, query_graph_name)") orelse return error.MissingSnapshotPath;
    try testing.expect(fast_path < snapshot_path);
    try testing.expect(std.mem.indexOf(u8, content, "graph_store.acquireGraphReadLockTagged(query_graph_name, .point_read)") != null);
}

test "quic count fast path batches schema and page responses" {
    // Count-only reads are the hot read side of the mixed high-concurrency
    // workload. They should not regress to two separate stream writes after
    // the read lock has already been released.
    const allocator = testing.allocator;
    const maybe_content = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const content = maybe_content orelse return error.FileNotFound;
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-119") != null);

    const fast_path_start = std.mem.indexOf(u8, content, "execution.countNodesFastPath") orelse return error.MissingCountFastPath;
    const fast_path_rest = content[fast_path_start..];
    const audit_idx = std.mem.indexOf(u8, fast_path_rest, "auditQueryExecution(state, query_text, is_mutation)") orelse return error.MissingCountFastPathAudit;
    const fast_path_body = fast_path_rest[0..audit_idx];

    try testing.expect(std.mem.indexOf(u8, fast_path_body, "try sendSinglePageExecutionResultBatched(gpa, stream, &exec_result)") != null);
    try testing.expect(std.mem.indexOf(u8, fast_path_body, "try sendQuicMessage(") == null);

    const helper_start = std.mem.indexOf(u8, content, "fn sendSinglePageExecutionResultBatched") orelse return error.MissingBatchedCountHelper;
    const helper_body = content[helper_start..];
    try testing.expect(std.mem.indexOf(u8, helper_body, "const batched = [_]schema.QuicServerMessage") != null);
    try testing.expect(std.mem.indexOf(u8, helper_body, "try sendQuicMessagesBatched(ra, stream, &batched)") != null);
}

test "quic count fast path reuses active read store without nested ReadView" {
    // Mixed read/write QUIC load installs an active read store under the
    // handler's graph read lock. The count fast path must use that store
    // directly instead of creating a ReadView that can re-enter the global
    // store lock after a concurrent mutation epoch change.
    const allocator = testing.allocator;

    const maybe_match_ops = try readFile(allocator, "src/execution/match_operations.zig");
    const match_ops = maybe_match_ops orelse return error.FileNotFound;
    defer allocator.free(match_ops);

    try testing.expect(std.mem.indexOf(u8, match_ops, "REQ-QUIC-HC-017") != null);
    try testing.expect(std.mem.indexOf(u8, match_ops, "REQ-QUIC-HC-146") != null);
    try testing.expect(std.mem.indexOf(u8, match_ops, "pub fn countNodesLabelRefcountFastPath") != null);
    try testing.expect(std.mem.indexOf(u8, match_ops, "graph_store.getGlobalStore(allocator)") != null);

    const fn_start = std.mem.indexOf(u8, match_ops, "pub fn countNodesFastPath") orelse return error.MissingCountFastPath;
    const count_fast_path = match_ops[fn_start..];
    const active_store = std.mem.indexOf(u8, count_fast_path, "graph_store.getActiveQueryReadStore()") orelse return error.MissingActiveReadStoreReuse;
    const read_view = std.mem.indexOf(u8, count_fast_path, "graph_store.ReadView.init") orelse return error.MissingReadViewFallback;
    try testing.expect(active_store < read_view);

    const maybe_graph_store = try readFile(allocator, "src/graph_store.zig");
    const graph_store_content = maybe_graph_store orelse return error.FileNotFound;
    defer allocator.free(graph_store_content);
    try testing.expect(std.mem.indexOf(u8, graph_store_content, "pub fn getActiveQueryReadStore()") != null);
    try testing.expect(std.mem.indexOf(u8, graph_store_content, "REQ=REQ-QUIC-HC-032") != null);
    try testing.expect(std.mem.indexOf(u8, graph_store_content, "REQ=REQ-QUIC-HC-120") != null);
    try testing.expect(std.mem.indexOf(u8, graph_store_content, "REQ=REQ-QUIC-HC-163") != null);
    try testing.expect(std.mem.indexOf(u8, graph_store_content, "label_index_mutex") != null);
    try testing.expect(std.mem.indexOf(u8, graph_store_content, "label_counts_by_graph") != null);
    try testing.expect(std.mem.indexOf(u8, graph_store_content, "LabelCountValue") != null);
    try testing.expect(std.mem.indexOf(u8, graph_store_content, "label_count_rwlock") != null);
    try testing.expect(std.mem.indexOf(u8, graph_store_content, "count.fetchAdd(1, .monotonic)") != null);
    try testing.expect(std.mem.indexOf(u8, graph_store_content, "count.cmpxchgWeak") != null);
    try testing.expect(std.mem.indexOf(u8, graph_store_content, "return self.countGraphLabel(graph_name, label);") != null);
    try testing.expect(std.mem.indexOf(u8, graph_store_content, "posting.lock()") != null);
}

test "empty RLS engines do not disable high-concurrency read fast paths" {
    // Server startup registers empty RLS engines so policy procedures can
    // populate them later. Empty engines are default-allow and must not route
    // every authenticated read through the snapshot clone path.
    const allocator = testing.allocator;

    const maybe_match_ops = try readFile(allocator, "src/execution/match_operations.zig");
    const match_ops = maybe_match_ops orelse return error.FileNotFound;
    defer allocator.free(match_ops);

    try testing.expect(std.mem.indexOf(u8, match_ops, "REQ-QUIC-HC-158") != null);
    try testing.expect(std.mem.indexOf(u8, match_ops, "fn activeRlsPoliciesConfigured() bool") != null);
    try testing.expect(std.mem.indexOf(u8, match_ops, "filter_engine.policyCount() != 0") != null);
    try testing.expect(std.mem.indexOf(u8, match_ops, "expr_engine.hasPolicies()") != null);
    try testing.expect(std.mem.indexOf(u8, match_ops, "return activeRlsPoliciesConfigured();") != null);
    try testing.expect(std.mem.indexOf(u8, match_ops, "if (!countFastPathRlsAllowed()) return null;") != null);

    const maybe_rls_core = try readFile(allocator, "src/security/rls_core.zig");
    const rls_core = maybe_rls_core orelse return error.FileNotFound;
    defer allocator.free(rls_core);

    try testing.expect(std.mem.indexOf(u8, rls_core, "pub fn hasPolicies(self: *Self) bool") != null);
}

test "optimized server builds use high-concurrency allocator" {
    // DebugAllocator is valuable for leak detection in Debug builds, but it is
    // the wrong allocator for optimized high-concurrency request serving.
    const allocator = testing.allocator;
    const maybe_content = try readFile(allocator, "src/server/main.zig");
    const content = maybe_content orelse return error.FileNotFound;
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-009") != null);
    try testing.expect(std.mem.indexOf(u8, content, "const ServerAllocator = if (builtin.mode == .Debug)") != null);
    try testing.expect(std.mem.indexOf(u8, content, "std.heap.DebugAllocator") != null);
    try testing.expect(std.mem.indexOf(u8, content, "return std.heap.smp_allocator") != null);
}

test "optimized quic stream pools are tunable for high fanout" {
    // Stream and acceptor workers are long-lived per connection/stream loops.
    // Keep their defaults and env knobs pinned so high fan-out tests are not
    // silently capped by a 64-worker pool.
    const allocator = testing.allocator;
    const maybe_content = try readFile(allocator, "src/server/main.zig");
    const content = maybe_content orelse return error.FileNotFound;
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-018") != null);
    try testing.expect(std.mem.indexOf(u8, content, "const default_quic_stream_worker_count = 64") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"GEODE_QUIC_STREAM_WORKERS\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"GEODE_QUIC_STREAM_QUEUE_CAPACITY\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"GEODE_QUIC_ACCEPTOR_WORKERS\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, "\"GEODE_QUIC_ACCEPTOR_QUEUE_CAPACITY\"") != null);
    try testing.expect(std.mem.indexOf(u8, content, ".blocking_workers = 0") != null);
}

test "quic global stream throttle is configurable and registry is preallocated" {
    const allocator = testing.allocator;

    const maybe_main = try readFile(allocator, "src/server/main.zig");
    const main_content = maybe_main orelse return error.FileNotFound;
    defer allocator.free(main_content);
    try testing.expect(std.mem.indexOf(u8, main_content, "REQ=REQ-QUIC-HC-020") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "\"GEODE_QUIC_MAX_GLOBAL_STREAM_THREADS\"") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "quic_connection_handler.setMaxGlobalStreamThreads") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "reserveProtoReaderRegistryCapacity") != null);

    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler_content = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler_content);
    try testing.expect(std.mem.indexOf(u8, handler_content, "pub fn reserveProtoReaderRegistryCapacity") != null);

    const maybe_registry = try readFile(allocator, "src/server/proto_reader_registry.zig");
    const registry_content = maybe_registry orelse return error.FileNotFound;
    defer allocator.free(registry_content);
    try testing.expect(std.mem.indexOf(u8, registry_content, "pub fn reserveCapacity") != null);
    try testing.expect(std.mem.indexOf(u8, registry_content, "ensureTotalCapacity") != null);
}

test "quic high fanout connection limits and setup retries are tunable" {
    const allocator = testing.allocator;

    const maybe_main = try readFile(allocator, "src/server/main.zig");
    const main_content = maybe_main orelse return error.FileNotFound;
    defer allocator.free(main_content);
    try testing.expect(std.mem.indexOf(u8, main_content, "REQ=REQ-QUIC-HC-021") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "\"GEODE_QUIC_MAX_CONNECTIONS\"") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "quic_init_cfg.max_connections = if (config.max_connections > 0)") != null);

    const maybe_transport = try readFile(allocator, "src/transport/quic.zig");
    const transport_content = maybe_transport orelse return error.FileNotFound;
    defer allocator.free(transport_content);
    try testing.expect(std.mem.indexOf(u8, transport_content, "max_connections: usize = 10000") != null);

    const maybe_cli_args = try readFile(allocator, "src/server/cli_args.zig");
    const cli_args_content = maybe_cli_args orelse return error.FileNotFound;
    defer allocator.free(cli_args_content);
    try testing.expect(std.mem.indexOf(u8, cli_args_content, "default: 10000") != null);

    const maybe_e2e = try readFile(allocator, "tests/e2e_quic_high_concurrency.zig");
    const e2e_content = maybe_e2e orelse return error.FileNotFound;
    defer allocator.free(e2e_content);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_CONNECT_ATTEMPTS\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_CONNECT_BACKOFF_MS\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_HANDSHAKE_TIMEOUT_SECS\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "REQ=REQ-QUIC-HC-118") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "const high_concurrency_worker_stack_size = 1024 * 1024") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, ".{ .stack_size = high_concurrency_worker_stack_size }") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "REQ=REQ-QUIC-HC-101") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "const default_hello_timeout_ms = 1000") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "REQ=REQ-QUIC-HC-126") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "default_connect_attempts_for_run") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "default_hello_timeout_ms_for_run") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "default_setup_timeout_secs_for_run") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "default_request_stagger_us_for_run") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "highFanoutConnectionWorkerDefault(worker_count)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "REQ=REQ-QUIC-HC-128") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "highFanoutCooperativeFirstStreamWorkerDefault(worker_count)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "const high_fanout_worker_threshold = 64") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "const high_fanout_connection_worker_cap = 64") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "default_connection_admission_threads_for_run") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "REQ=REQ-QUIC-HC-138") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "const high_fanout_cooperative_first_stream_worker_cap = if (builtin.mode == .Debug) 64 else 512") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "envU32(\"GEODE_HC_HELLO_TIMEOUT_MS\", default_hello_timeout_ms_for_run)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_CONNECT_STAGGER_US\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "envU32(\"GEODE_HC_REQUEST_STAGGER_US\", default_request_stagger_us_for_run)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_MAX_CONNECTIONS\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "REQ=REQ-QUIC-HC-085") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "const default_max_connections = std.math.mul(u32, worker_count, 4)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "envU32(\"GEODE_HC_MAX_CONNECTIONS\", default_max_connections)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "envU32(\"GEODE_HC_MAX_CONNECTIONS\", worker_count + 128)") == null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "--max-connections") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "connectAndHelloWithRetry(") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "ctx.connect_attempts") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "setup_failed") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "connected") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "hello_ok") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "ops_started") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "high-concurrency QUIC E2E incomplete") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "abort_setup") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "return error.SetupFailures") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_EXEC_TIMEOUT_SECS\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "const default_execute_timeout_secs = if (builtin.mode == .Debug) 5 else 10") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "envU32(\"GEODE_HC_EXEC_TIMEOUT_SECS\", default_execute_timeout_secs)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_EXEC_RETRIES\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "MERGE (:HCParallel") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "executeAndCollectWithTimeout") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "REQ=REQ-QUIC-HC-099") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "InWorkloadMutationVerifier") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "release_clients") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "verify_after_workload") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "verify_done") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "waitForClientRelease(ctx)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "releaseAllClients(&release_clients, &release_generation)") != null);
    try testing.expect(countOccurrences(e2e_content, "connectAndHelloWithRetry(") >= 1);

    const maybe_proto = try readFile(allocator, "tests/proto_test_util.zig");
    const proto_content = maybe_proto orelse return error.FileNotFound;
    defer allocator.free(proto_content);
    try testing.expect(std.mem.indexOf(u8, proto_content, "REQ=REQ-QUIC-HC-023") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "REQ=REQ-QUIC-HC-031") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "pub fn connectWithHandshakeTimeout") != null);
    try testing.expect(std.mem.indexOf(u8, proto_content, "pub fn executeAndCollectWithTimeout") != null);
}

test "quic high fanout e2e runs in single stream stress mode" {
    const allocator = testing.allocator;

    const maybe_init = try readFile(allocator, "src/server/server_init.zig");
    const init_content = maybe_init orelse return error.FileNotFound;
    defer allocator.free(init_content);
    try testing.expect(std.mem.indexOf(u8, init_content, "REQ=REQ-QUIC-HC-030") != null);
    try testing.expect(std.mem.indexOf(u8, init_content, "quic_stream_multiplexing_enabled: bool = true") != null);
    try testing.expect(std.mem.indexOf(u8, init_content, "\"GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING\"") != null);
    try testing.expect(std.mem.indexOf(u8, init_content, "REQ=REQ-QUIC-HC-054") != null);
    try testing.expect(std.mem.indexOf(u8, init_content, "quic_cooperative_first_streams_enabled: bool = false") != null);
    try testing.expect(std.mem.indexOf(u8, init_content, "\"GEODE_QUIC_COOPERATIVE_FIRST_STREAMS\"") != null);

    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler_content = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler_content);
    try testing.expect(std.mem.indexOf(u8, handler_content, "env_config.quic_stream_multiplexing_enabled") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "env_config.quic_cooperative_first_streams_enabled") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "pub const FirstStreamScheduler = struct") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "ready_queue") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "ready_head") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "firstStreamReadyCallback") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "setReadReadyNotifier") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "nextMessageNonBlocking") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "processCooperativeFirstStream") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "setFirstStreamScheduler") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "StreamAcceptorContext.create(") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "REQ=REQ-QUIC-HC-073") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "cleanupFirstStreamOwnerAsync") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "REQ=REQ-QUIC-HC-044") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "g_first_stream_detach_gate.tryAcquire()") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "setMaxDetachedFirstStreamOwners") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "const default_detached_first_stream_owner_threads: u32 = if (builtin.mode == .Debug) 64 else 256") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "REQ=REQ-QUIC-HC-129") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "const first_stream_owner_stack_size = 2 * 1024 * 1024") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "REQ=REQ-QUIC-HC-139") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, ".{ .stack_size = first_stream_owner_stack_size }, workerMain") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "REQ=REQ-QUIC-HC-140") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "hasBufferedUnread") != null);

    const maybe_e2e = try readFile(allocator, "tests/e2e_quic_high_concurrency.zig");
    const e2e_content = maybe_e2e orelse return error.FileNotFound;
    defer allocator.free(e2e_content);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "REQ=REQ-QUIC-HC-030") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING=0\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "envBool(\"GEODE_HC_COOPERATIVE_FIRST_STREAMS\", true)") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_COOPERATIVE_FIRST_STREAMS\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_QUIC_COOPERATIVE_FIRST_STREAMS=1\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_QUIC_COOPERATIVE_FIRST_STREAMS=0\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "cooperative_first_streams_env") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_DETACHED_FIRST_STREAM_THREADS\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "REQ=REQ-QUIC-HC-071") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "default_detached_first_stream_threads") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "const default_detached_first_stream_threads = if (builtin.mode == .Debug) 64 else 256") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "max_connections,") == null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_QUIC_DETACHED_FIRST_STREAM_THREADS={d}\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_QUIC_MAX_GLOBAL_STREAM_THREADS={d}\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "detached_first_stream_env") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "max_global_stream_env") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "waitForServerReady(allocator, addr, 60000)") != null);

    const maybe_main = try readFile(allocator, "src/server/main.zig");
    const main_content = maybe_main orelse return error.FileNotFound;
    defer allocator.free(main_content);
    try testing.expect(std.mem.indexOf(u8, main_content, "REQ=REQ-QUIC-HC-044") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "\"GEODE_QUIC_DETACHED_FIRST_STREAM_THREADS\"") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "setMaxDetachedFirstStreamOwners") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "const default_quic_detached_first_stream_threads = if (builtin.mode == .Debug) 64 else 256") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "default_quic_cooperative_first_stream_worker_count") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "const default_quic_cooperative_first_stream_worker_count = if (builtin.mode == .Debug) 16 else 256") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "\"GEODE_QUIC_COOPERATIVE_FIRST_STREAM_WORKERS\"") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "\"GEODE_QUIC_MUTATION_ADMISSION_CAP\"") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "default_first_stream_scheduler_mutation_limit_cap") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "max_first_stream_scheduler_mutation_limit_cap") != null);
    try testing.expect(std.mem.indexOf(u8, main_content, "first_stream_scheduler.init") != null);
}

test "quic endpoint timers use indexed cancellation" {
    const allocator = testing.allocator;

    const quic_dir = (try findVendoredQuicDir(allocator)) orelse return error.FileNotFound;
    defer allocator.free(quic_dir);
    const endpoint_path = try std.fmt.allocPrint(allocator, "{s}/src/quic/endpoint.zig", .{quic_dir});
    defer allocator.free(endpoint_path);
    const maybe_endpoint = try readFile(allocator, endpoint_path);
    const endpoint_content = maybe_endpoint orelse return error.FileNotFound;
    defer allocator.free(endpoint_content);

    try testing.expect(std.mem.indexOf(u8, endpoint_content, "REQ=REQ-QUIC-HC-045") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint_content, "timer_index: std.AutoHashMap(u64, usize)") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint_content, "fn timerPushIndexed(") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint_content, "fn timerRemoveAtIndexed(") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint_content, "const idx = self.timer_index.get(id) orelse return false") != null);
    try testing.expect(std.mem.indexOf(u8, endpoint_content, "test \"endpoint timers keep index consistent across heap operations\"") != null);
}

test "quic high concurrency harness exposes objective gate evidence" {
    const allocator = testing.allocator;

    const maybe_e2e = try readFile(allocator, "tests/e2e_quic_high_concurrency.zig");
    const e2e_content = maybe_e2e orelse return error.FileNotFound;
    defer allocator.free(e2e_content);

    try testing.expect(std.mem.indexOf(u8, e2e_content, "REQ=REQ-QUIC-HC-170") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_OBJECTIVE_GATE\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "objective_worker_count: u32 = 16_384") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "objective_ops_per_worker: u32 = 8") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "objective_min_completion_ppm: u32 = 999_500") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "objective_min_mutation_ppm: u32 = 250_000") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "objective_min_qps: u32 = 10_000") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "computeLatencyPercentiles") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "high-concurrency QUIC E2E latency_percentiles") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_P50_MAX_MS\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_P95_MAX_MS\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_P99_MAX_MS\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_P999_MAX_MS\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_REQUIRE_ZERO_FIRST_RESPONSE_TIMEOUTS\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_GRAPH_ISOLATION_VERIFY\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_RESTART_VERIFY\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_HC_MEMORY_GROWTH_MAX_KB\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "verifyGraphIsolation") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "verifyRestartRecovery") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "high-concurrency QUIC E2E gate objective={}") != null);
}

test "quic parallel facade uses bounded smp allocator pool" {
    const allocator = testing.allocator;

    const maybe_parallel = try readFile(allocator, "src/transport/quic_parallel_serial.zig");
    const parallel_content = maybe_parallel orelse return error.FileNotFound;
    defer allocator.free(parallel_content);
    try testing.expect(std.mem.indexOf(u8, parallel_content, "REQ=REQ-QUIC-HC-029") != null);
    try testing.expect(std.mem.indexOf(u8, parallel_content, "std.heap.smp_allocator") != null);
    try testing.expect(std.mem.indexOf(u8, parallel_content, "std.heap.page_allocator") == null);
    try testing.expect(std.mem.indexOf(u8, parallel_content, "\"GEODE_QUIC_PARALLEL_WORKERS\"") != null);
    try testing.expect(std.mem.indexOf(u8, parallel_content, "\"GEODE_QUIC_PARALLEL_QUEUE_CAPACITY\"") != null);
    try testing.expect(std.mem.indexOf(u8, parallel_content, "REQ=REQ-QUIC-HC-060") != null);
    try testing.expect(std.mem.indexOf(u8, parallel_content, "PartialSubmitWaitGroup") != null);
    try testing.expect(std.mem.indexOf(u8, parallel_content, "worker tasks cannot call done() on a returned stack") != null);
    try testing.expect(countOccurrences(parallel_content, "wg.wait();") >= 4);

    const thread_pool_dir = (try findPinnedPackageDir(allocator, "thread_pool", "src/types.zig")) orelse return error.FileNotFound;
    defer allocator.free(thread_pool_dir);
    const wait_group_path = try std.fmt.allocPrint(allocator, "{s}/src/types.zig", .{thread_pool_dir});
    defer allocator.free(wait_group_path);
    const maybe_wait_group = try readFile(allocator, wait_group_path);
    const wait_group_content = maybe_wait_group orelse return error.FileNotFound;
    defer allocator.free(wait_group_content);
    try testing.expect(std.mem.indexOf(u8, wait_group_content, "REQ=REQ-QUIC-HC-061") != null);
    const lock_idx = std.mem.indexOf(u8, wait_group_content, "self.mutex.lock();") orelse return error.MissingWaitGroupLock;
    const decrement_idx = std.mem.indexOf(u8, wait_group_content, "const previous = self.pending.fetchSub(1, .acq_rel);") orelse return error.MissingWaitGroupDecrement;
    try testing.expect(lock_idx < decrement_idx);

    const maybe_build = try readFile(allocator, "build.zig");
    const build_content = maybe_build orelse return error.FileNotFound;
    defer allocator.free(build_content);
    try testing.expect(std.mem.indexOf(u8, build_content, "quic_parallel_serial_mod.addImport(\"thread_pool\"") != null);
    try testing.expect(std.mem.indexOf(u8, build_content, "test-quic-parallel-facade") != null);
}

test "quic group commit keeps bulk create properties in shard transaction" {
    const allocator = testing.allocator;

    const maybe_store = try readFile(allocator, "src/graph_store.zig");
    const store_content = maybe_store orelse return error.FileNotFound;
    defer allocator.free(store_content);
    try testing.expect(std.mem.indexOf(u8, store_content, "REQ=REQ-QUIC-HC-022") != null);
    try testing.expect(std.mem.indexOf(u8, store_content, "pub fn setNodePropertiesBatchInMemoryOnly") != null);
    try testing.expect(std.mem.indexOf(u8, store_content, "REQ=REQ-QUIC-HC-171") != null);
    try testing.expect(std.mem.indexOf(u8, store_content, "adapter.checkpointAll() catch |err|") != null);
    try testing.expect(std.mem.indexOf(u8, store_content, "checkpoint failed during adapter shutdown") != null);

    const maybe_adapter = try readFile(allocator, "src/storage/graph_storage_adapter.zig");
    const adapter_content = maybe_adapter orelse return error.FileNotFound;
    defer allocator.free(adapter_content);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "REQ=REQ-QUIC-HC-171") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "resolvePersistedLabelId") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "mg.engine.getOrAssignLabel(label)") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "REQ=REQ-QUIC-HC-022") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "node_shard.putPropertyTxn(rec.prop_head, kv.key, storage_val, local_txn)") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "addIndexedNodeProperty(mg, label_id, slot_id, kv.key, storage_val)") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "setNodePropertiesBatchInMemoryOnly") != null);
    try testing.expect(std.mem.indexOf(u8, adapter_content, "store.setNodePropertiesBatch(reserved_id, entries)") == null);

    const maybe_group_commit_test = try readFile(allocator, "tests/perf/test_group_commit_coordinator.zig");
    const group_commit_test_content = maybe_group_commit_test orelse return error.FileNotFound;
    defer allocator.free(group_commit_test_content);
    try testing.expect(std.mem.indexOf(u8, group_commit_test_content, "REQ-QUIC-HC-171: group commit inserts survive adapter reopen") != null);
    try testing.expect(std.mem.indexOf(u8, group_commit_test_content, "RecoveredGroupCommit") != null);
    try testing.expect(std.mem.indexOf(u8, group_commit_test_content, "reopened.countNodesByLabel") != null);
}

test "quic first stream is detached from connection admission worker" {
    // After HELLO, the first stream must move to bounded detached ownership.
    // Keeping its blocking query loop inline in handleQuicConnection pins a
    // connection
    // worker per live client; routing it through the 64-worker stream pool
    // also caps 128+ client fan-out.
    const allocator = testing.allocator;
    const maybe_content = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const content = maybe_content orelse return error.FileNotFound;
    defer allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "REQ=REQ-QUIC-HC-011") != null);
    try testing.expect(std.mem.indexOf(u8, content, "const FirstStreamOwnerContext = struct") != null);
    try testing.expect(std.mem.indexOf(u8, content, "fn handleFirstStreamOwner") != null);
    try testing.expect(std.mem.indexOf(u8, content, "runStreamQueryLoopWithReader") != null);
    try testing.expect(std.mem.indexOf(u8, content, "g_stream_throttle.acquire(10 * std.time.ns_per_ms)") != null);
    try testing.expect(std.mem.indexOf(u8, content, "first_thread.detach()") != null);
    try testing.expect(std.mem.indexOf(u8, content, "stream_throttle_acquired") != null);
    try testing.expect(std.mem.indexOf(u8, content, "falling back to shared stream pool") != null);
    try testing.expect(std.mem.indexOf(u8, content, "line_reader_handed_off = true") != null);
    try testing.expect(std.mem.indexOf(u8, content, "stream_handed_off = true") != null);
    try testing.expect(std.mem.indexOf(u8, content, "destroy_conn = false") != null);
    try testing.expect(std.mem.indexOf(u8, content, "First stream query loop (inline)") == null);
}

test "quic hello admission has bounded lifetime" {
    // Detached admission threads must not wait forever after a peer opens a
    // stream but never sends HELLO; shutdown waits for these short-lived
    // handlers before tearing down server-owned transport state.
    const allocator = testing.allocator;

    const maybe_handler = try readFile(allocator, "src/server/quic_connection_handler.zig");
    const handler_content = maybe_handler orelse return error.FileNotFound;
    defer allocator.free(handler_content);
    try testing.expect(std.mem.indexOf(u8, handler_content, "REQ=REQ-QUIC-HC-014") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "hello_read_timeout_ns") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "env_config.quic_hello_read_timeout_ms * std.time.ns_per_ms") != null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "5 * std.time.ns_per_s") == null);
    try testing.expect(std.mem.indexOf(u8, handler_content, "Timed out waiting for QUIC HELLO message") != null);

    const maybe_init = try readFile(allocator, "src/server/server_init.zig");
    const init_content = maybe_init orelse return error.FileNotFound;
    defer allocator.free(init_content);
    try testing.expect(std.mem.indexOf(u8, init_content, "REQ=REQ-QUIC-HC-114") != null);
    try testing.expect(std.mem.indexOf(u8, init_content, "quic_hello_read_timeout_ms: u64 = 1_000") != null);
    try testing.expect(std.mem.indexOf(u8, init_content, "\"GEODE_QUIC_HELLO_READ_TIMEOUT_MS\"") != null);

    const maybe_e2e = try readFile(allocator, "tests/e2e_quic_high_concurrency.zig");
    const e2e_content = maybe_e2e orelse return error.FileNotFound;
    defer allocator.free(e2e_content);
    try testing.expect(std.mem.indexOf(u8, e2e_content, "\"GEODE_QUIC_HELLO_READ_TIMEOUT_MS={d}\"") != null);
    try testing.expect(std.mem.indexOf(u8, e2e_content, ".{hello_timeout_ms}") != null);

    const maybe_main = try readFile(allocator, "src/server/main.zig");
    const main_content = maybe_main orelse return error.FileNotFound;
    defer allocator.free(main_content);
    try testing.expect(std.mem.indexOf(u8, main_content, "g_connection_admission_gate.waitForZero(10 * std.time.ns_per_s)") != null);
}
