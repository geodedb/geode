// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros
//
// CANARY: REQ=REQ-GAP-0838-DNS-SEARCH; FEATURE="ClusterPeerDNS"; ASPECT=ResolvConfSearchExpansion; STATUS=TESTED; TEST=src/transport/dns_search.zig; OWNER=transport; UPDATED=2026-06-02
//
//! resolv.conf `search`-domain + `ndots` aware hostname expansion.
//!
//! GAP-0838 / 2026-06-02 k8s cluster bug (Bug A): the bundled `dns` library
//! resolves a hostname *verbatim* (a bare A lookup with no search-domain
//! expansion). In a Kubernetes pod the peer addresses are short headless
//! names like `geode-0.geode`, which only resolve once the resolv.conf
//! `search` list (`geode-qa.svc.cluster.local svc.cluster.local …`) is
//! appended -- exactly what glibc's `getaddrinfo` does and our custom
//! resolver did not. The result was `error.InvalidAddress` for every
//! short peer name, so a cluster could only form with fully-qualified
//! peer names.
//!
//! This module is the pure, std-only core of the fix: it parses the
//! relevant resolv.conf directives and produces the *ordered* list of
//! candidate FQDNs to try, following the glibc stub-resolver algorithm
//! (ndots decides whether the bare name or the search-expanded names are
//! tried first). The I/O glue (calling the actual DNS client per
//! candidate) lives in `transport/quic.zig`'s `resolveHostToIp`.

const std = @import("std");

/// Parsed view of the resolv.conf directives we care about.
/// `search` is an owned slice of owned domain strings (may be empty).
pub const Parsed = struct {
    search: []const []const u8,
    /// glibc default is 1 when `options ndots:N` is absent.
    ndots: u8,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        for (self.search) |s| allocator.free(s);
        allocator.free(self.search);
    }
};

/// glibc caps ndots at 15; values above are clamped.
const max_ndots: u8 = 15;

/// Parse `search`, `domain`, and `options ndots:N` from a resolv.conf body.
///
/// Precedence matches glibc: an explicit `search` line wins over `domain`;
/// the LAST `search`/`domain` line in the file takes effect. `ndots`
/// defaults to 1 and is clamped to [0, 15]. Lines starting with `#` or `;`
/// are comments. Caller owns the returned `Parsed` (free via `deinit`).
pub fn parseResolvConf(allocator: std.mem.Allocator, text: []const u8) !Parsed {
    var search: std.ArrayList([]const u8) = .empty;
    errdefer freeCandidatesList(allocator, &search);
    var ndots: u8 = 1;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';') continue;

        var toks = std.mem.tokenizeAny(u8, line, " \t");
        const directive = toks.next() orelse continue;

        if (std.mem.eql(u8, directive, "search")) {
            // `search a b c` -- replace any prior search/domain (last wins).
            freeCandidatesList(allocator, &search);
            search = .empty;
            while (toks.next()) |dom| {
                try search.append(allocator, try allocator.dupe(u8, dom));
            }
        } else if (std.mem.eql(u8, directive, "domain")) {
            // `domain d` is the single-domain legacy form; last search/domain
            // line wins, so it replaces a prior `search` too.
            if (toks.next()) |dom| {
                freeCandidatesList(allocator, &search);
                search = .empty;
                try search.append(allocator, try allocator.dupe(u8, dom));
            }
        } else if (std.mem.eql(u8, directive, "options")) {
            while (toks.next()) |opt| {
                const prefix = "ndots:";
                if (std.mem.startsWith(u8, opt, prefix)) {
                    const n = std.fmt.parseInt(u8, opt[prefix.len..], 10) catch continue;
                    ndots = @min(n, max_ndots);
                }
            }
        }
    }

    return .{ .search = try search.toOwnedSlice(allocator), .ndots = ndots };
}

/// Build the ordered list of candidate names to resolve for `host`,
/// applying the resolv.conf `search` list under the `ndots` rule.
///
/// glibc behavior reproduced here:
///   * A trailing `.` makes the name fully-qualified -> only the bare
///     (dot-stripped) name is tried, never search-expanded.
///   * Otherwise, if the host already contains >= `ndots` dots, the bare
///     name is tried FIRST, then each `host.<search>` suffix.
///   * If it contains fewer than `ndots` dots, each `host.<search>` suffix
///     is tried FIRST, then the bare name as a last resort.
///   * With no search domains, the only candidate is the bare name.
///
/// Caller owns the returned slice and every element (free via
/// `freeCandidates`).
pub fn buildCandidates(
    allocator: std.mem.Allocator,
    host: []const u8,
    search: []const []const u8,
    ndots: u8,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer freeCandidatesList(allocator, &list);

    // A trailing dot makes the name fully-qualified: strip it and try only
    // the absolute name (no search expansion).
    if (host.len > 0 and host[host.len - 1] == '.') {
        try list.append(allocator, try allocator.dupe(u8, host[0 .. host.len - 1]));
        return list.toOwnedSlice(allocator);
    }

    // No search list -> only the bare name is a candidate.
    if (search.len == 0) {
        try list.append(allocator, try allocator.dupe(u8, host));
        return list.toOwnedSlice(allocator);
    }

    const dots = std.mem.count(u8, host, ".");

    if (dots >= ndots) {
        // Enough dots already: try the bare name first, then the search list.
        try list.append(allocator, try allocator.dupe(u8, host));
        for (search) |dom| {
            try list.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ host, dom }));
        }
    } else {
        // Too few dots: try the search-expanded names first, bare name last.
        for (search) |dom| {
            try list.append(allocator, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ host, dom }));
        }
        try list.append(allocator, try allocator.dupe(u8, host));
    }

    return list.toOwnedSlice(allocator);
}

fn freeCandidatesList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |c| allocator.free(c);
    list.deinit(allocator);
}

/// Free a candidate list returned by `buildCandidates` / `candidatesForHost`.
pub fn freeCandidates(allocator: std.mem.Allocator, candidates: []const []const u8) void {
    for (candidates) |c| allocator.free(c);
    allocator.free(candidates);
}

/// Best-effort: read `/etc/resolv.conf`, parse it, and build the candidate
/// list for `host`. On ANY I/O or parse failure (no resolv.conf, unreadable,
/// etc.) falls back to a single candidate equal to `host` -- i.e. the
/// pre-fix behavior -- so this never regresses environments that worked
/// before. Caller owns the result (free via `freeCandidates`).
pub fn candidatesForHost(allocator: std.mem.Allocator, host: []const u8) ![]const []const u8 {
    var parsed = readResolvConf(allocator) catch {
        return buildCandidates(allocator, host, &.{}, 1);
    };
    defer parsed.deinit(allocator);
    return buildCandidates(allocator, host, parsed.search, parsed.ndots);
}

/// resolv.conf is small; cap the read so a pathological file can't OOM us.
const resolv_conf_cap: usize = 64 * 1024;

fn readResolvConf(allocator: std.mem.Allocator) !Parsed {
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = try std.Io.Dir.cwd().openFile(io, "/etc/resolv.conf", .{});
    defer file.close(io);
    const st = try file.stat(io);
    const size: usize = @intCast(@min(st.size, resolv_conf_cap));
    const text = try allocator.alloc(u8, size);
    defer allocator.free(text);
    _ = try file.readPositionalAll(io, text, 0);
    return parseResolvConf(allocator, text);
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

test "parseResolvConf: k8s search list + ndots:5" {
    const a = std.testing.allocator;
    const sample =
        \\nameserver 10.96.0.10
        \\search geode-qa.svc.cluster.local svc.cluster.local cluster.local
        \\options ndots:5
        \\
    ;
    var parsed = try parseResolvConf(a, sample);
    defer parsed.deinit(a);

    try std.testing.expectEqual(@as(u8, 5), parsed.ndots);
    try std.testing.expectEqual(@as(usize, 3), parsed.search.len);
    try std.testing.expectEqualStrings("geode-qa.svc.cluster.local", parsed.search[0]);
    try std.testing.expectEqualStrings("svc.cluster.local", parsed.search[1]);
    try std.testing.expectEqualStrings("cluster.local", parsed.search[2]);
}

test "parseResolvConf: defaults ndots to 1 and ignores comments" {
    const a = std.testing.allocator;
    const sample =
        \\# a comment
        \\; another comment
        \\nameserver 1.1.1.1
        \\search example.com
        \\
    ;
    var parsed = try parseResolvConf(a, sample);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(u8, 1), parsed.ndots);
    try std.testing.expectEqual(@as(usize, 1), parsed.search.len);
    try std.testing.expectEqualStrings("example.com", parsed.search[0]);
}

test "parseResolvConf: `domain` used only when no `search`" {
    const a = std.testing.allocator;
    const sample = "domain corp.example\n";
    var parsed = try parseResolvConf(a, sample);
    defer parsed.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), parsed.search.len);
    try std.testing.expectEqualStrings("corp.example", parsed.search[0]);
}

test "buildCandidates: short k8s headless name expands search-first under ndots:5" {
    const a = std.testing.allocator;
    const search = [_][]const u8{
        "geode-qa.svc.cluster.local",
        "svc.cluster.local",
        "cluster.local",
    };
    const cands = try buildCandidates(a, "geode-0.geode", &search, 5);
    defer freeCandidates(a, cands);

    // 3 search-expanded + the bare name as a last resort.
    try std.testing.expectEqual(@as(usize, 4), cands.len);
    // The pod's real A record is the search-expanded FQDN; it MUST be tried
    // before the bare name (which NXDOMAINs in k8s).
    try std.testing.expectEqualStrings("geode-0.geode.geode-qa.svc.cluster.local", cands[0]);
    try std.testing.expectEqualStrings("geode-0.geode.svc.cluster.local", cands[1]);
    try std.testing.expectEqualStrings("geode-0.geode.cluster.local", cands[2]);
    try std.testing.expectEqualStrings("geode-0.geode", cands[3]);
}

test "buildCandidates: name with >= ndots dots tries the bare name first" {
    const a = std.testing.allocator;
    const search = [_][]const u8{"svc.cluster.local"};
    // 3 dots, ndots default 1 -> bare name tried first, then expanded.
    const cands = try buildCandidates(a, "a.b.c.example", &search, 1);
    defer freeCandidates(a, cands);
    try std.testing.expectEqual(@as(usize, 2), cands.len);
    try std.testing.expectEqualStrings("a.b.c.example", cands[0]);
    try std.testing.expectEqualStrings("a.b.c.example.svc.cluster.local", cands[1]);
}

test "buildCandidates: empty search list -> bare name only" {
    const a = std.testing.allocator;
    const cands = try buildCandidates(a, "geode-0.geode", &.{}, 5);
    defer freeCandidates(a, cands);
    try std.testing.expectEqual(@as(usize, 1), cands.len);
    try std.testing.expectEqualStrings("geode-0.geode", cands[0]);
}

test "buildCandidates: trailing dot is absolute -> no search expansion, dot stripped" {
    const a = std.testing.allocator;
    const search = [_][]const u8{"svc.cluster.local"};
    const cands = try buildCandidates(a, "geode-0.geode.", &search, 5);
    defer freeCandidates(a, cands);
    try std.testing.expectEqual(@as(usize, 1), cands.len);
    try std.testing.expectEqualStrings("geode-0.geode", cands[0]);
}
