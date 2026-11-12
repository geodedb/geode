// CANARY: REQ=REQ-SONNY-3147-AUDIT-HASH-COVERAGE; FEATURE="Audit Verification"; ASPECT=FullRecordEventHash; STATUS=TESTED; TEST=tests/test_sonny3147_audit_hash_coverage.zig; OWNER=security; UPDATED=2026-11-12
//
// SONNY-3147: an audit record's event_hash covered only the previous hash,
// the event type, resource.id and the action. The timestamp, the actor, the
// tenant, the session, the client address, the reason, the result, the
// resource type and graph and the details could be edited in the log
// without breaking the chain, and `geode audit verify` never recomputed
// event_hash for an ordinary record at all.
//
// The contract (hash format v2, docs/AUDIT_LOGGING.md):
//   - every record the writer emits carries `"hash_v":2` and an event_hash
//     over a domain tag (record kind), the previous hash and the record's
//     exact canonical bytes up to `"prev_hash"`; changing any field breaks it;
//   - the verifier recomputes event_hash for every record (v1 records with
//     the old narrow rule, counted and reported as v1-only), refuses a v1
//     record after a v2 record (a downgrade), and fails with one truthful
//     verdict and a non-zero exit, naming the record and the failure class
//     but not the record's contents;
//   - deleting, reordering, inserting records fails; truncating the tail is
//     detectable only up to the last signed DIGEST (the writer emits one at
//     a clean close).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const audit = @import("audit");
const rls = @import("rls");
const verify = @import("audit_verify");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;
const posix = std.posix;
const AuditLogger = audit.AuditLogger;
const AuditEvent = rls.AuditLogger.AuditEvent;
const Sha256 = std.crypto.hash.sha2.Sha256;
const geode_binary = geode_test_bin.geode_exe;

const has_versions = @hasField(verify.EpochSummary, "v1_records");

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

fn sleepMs(ms: u64) void {
    fsIo().sleep(.fromNanoseconds(ms * std.time.ns_per_ms), .awake) catch {};
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(fsIo(), path, allocator, .limited(64 << 20));
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(fsIo(), path, .{ .truncate = true });
    defer f.close(fsIo());
    try f.writeStreamingAll(fsIo(), bytes);
}

fn hexToKey(hex: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);
    return out;
}

/// The log's lines (without the newline). Caller frees with freeLines.
fn readLines(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
    const raw = try readFileAlloc(allocator, path);
    defer allocator.free(raw);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |l| allocator.free(l);
        out.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |l| if (l.len > 0) try out.append(allocator, try allocator.dupe(u8, l));
    return out.toOwnedSlice(allocator);
}

fn freeLines(allocator: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |l| allocator.free(l);
    allocator.free(lines);
}

fn writeLines(allocator: std.mem.Allocator, path: []const u8, lines: []const []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (lines) |l| {
        try buf.appendSlice(allocator, l);
        try buf.append(allocator, '\n');
    }
    try writeFile(path, buf.items);
}

/// A detail value the test writes; the verifier must never print it.
const secret_detail = "sonny3147-detail-value";

/// Append `n` ordinary events with every optional field set (event i is
/// distinguishable), through the production writer.
fn appendRichEvents(allocator: std.mem.Allocator, logger: *AuditLogger, n: usize, base: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var details = std.StringHashMap([]const u8).init(allocator);
        defer details.deinit();
        try details.put("query", secret_detail);
        try details.put("username", "alice");
        var ev = AuditEvent{
            .timestamp = 1_700_000_000_000 + @as(i64, @intCast((base + i) * 1000)),
            .event_type = .data_access,
            .severity = .info,
            .tenant_id = "tenant-alpha",
            .user_id = 7,
            .session_id = "sess-1",
            .resource = .{ .type = "node", .id = "n42", .name = "n42", .graph = "g1", .table = null },
            .action = "read",
            .result = .success,
            .reason = "granted",
            .ip_address = "10.0.0.7",
            .details = details,
        };
        try logger.appendAuditEvent(&ev);
    }
}

const LogFixture = struct {
    dir: test_scratch.ScratchDir,
    log: []u8,
    key: [32]u8,

    /// A log written by the current writer: 8 rich events with a digest
    /// every 3, closed cleanly.
    fn init(allocator: std.mem.Allocator, tag: []const u8) !LogFixture {
        var dir = try test_scratch.ScratchDir.create(tag);
        errdefer dir.remove();
        const log = try join(allocator, dir.path(), "audit.jsonl");
        errdefer allocator.free(log);
        {
            var logger = try AuditLogger.init(allocator, .{ .enabled = true, .file_path = log, .digest_interval = 3 });
            defer logger.deinit();
            try appendRichEvents(allocator, &logger, 8, 0);
        }
        const pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{log});
        defer allocator.free(pub_path);
        const pub_raw = try readFileAlloc(allocator, pub_path);
        defer allocator.free(pub_raw);
        return .{ .dir = dir, .log = log, .key = try hexToKey(std.mem.trim(u8, pub_raw, " \r\n")) };
    }

    fn deinit(self: *LogFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.log);
        self.dir.remove();
    }

    /// `lines` written as a new log beside the original.
    fn variant(self: *LogFixture, allocator: std.mem.Allocator, name: []const u8, lines: []const []const u8) ![]u8 {
        const p = try join(allocator, self.dir.path(), name);
        errdefer allocator.free(p);
        try writeLines(allocator, p, lines);
        return p;
    }
};

/// The stored event_hash (hex) of a record line: the value after the last
/// `"event_hash":"` (the record tail).
fn eventHashHex(line: []const u8) ?[]const u8 {
    const patt = "\"event_hash\":\"";
    const i = std.mem.lastIndexOf(u8, line, patt) orelse return null;
    if (line.len < i + patt.len + 64) return null;
    return line[i + patt.len ..][0..64];
}

/// Hash format 2 as docs/AUDIT_LOGGING.md specifies it, written here
/// independently of the writer and the verifier:
/// SHA-256("geode.audit.event_hash.v2" 0x00 || kind || 0x00 || prev_hash || body).
fn hashV2(kind: []const u8, prev: [32]u8, body: []const u8) [32]u8 {
    var h = Sha256.init(.{});
    h.update("geode.audit.event_hash.v2\x00");
    h.update(kind);
    h.update(&[_]u8{0});
    h.update(&prev);
    h.update(body);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// What an attacker who knows the algorithm does to `line` to chain it after
/// `last`: a new prev_hash and a matching format-2 event_hash; the
/// signature is kept (the key is not available). Caller frees `line`.
fn rechain(allocator: std.mem.Allocator, line: []const u8, last: [32]u8) !struct { line: []u8, event_hash: [32]u8 } {
    var prev: [32]u8 = undefined;
    Sha256.hash(&last, &prev, .{});
    const pk = "\"prev_hash\":\"";
    const pi = std.mem.lastIndexOf(u8, line, pk) orelse return error.NoPrevHash;
    const body = line[0..pi];
    const kind: []const u8 = if (std.mem.indexOf(u8, line, "\"event_type\":\"DIGEST\"") != null) "digest" else "event";
    const eh = hashV2(kind, prev, body);
    const ei = std.mem.lastIndexOf(u8, line, "\"event_hash\":\"").? + "\"event_hash\":\"".len;
    const out = try std.mem.concat(allocator, u8, &.{
        body,                              pk,
        &std.fmt.bytesToHex(prev, .lower), line[pi + pk.len + 64 .. ei],
        &std.fmt.bytesToHex(eh, .lower),   line[ei + 64 ..],
    });
    return .{ .line = out, .event_hash = eh };
}

/// Index of the first ordinary (non-DIGEST) record line after `from`.
fn firstOrdinary(lines: []const []const u8, from: usize) usize {
    var i = from;
    while (i < lines.len) : (i += 1) {
        if (std.mem.indexOf(u8, lines[i], "\"event_type\":\"DIGEST\"") == null) return i;
    }
    return lines.len;
}

/// `line` with the first `old` replaced by `new` (which must differ).
fn replaced(allocator: std.mem.Allocator, line: []const u8, old: []const u8, new: []const u8) ![]u8 {
    const idx = std.mem.indexOf(u8, line, old) orelse {
        std.debug.print("SONNY-3147: tamper target {s} not in the record\n", .{old});
        return error.TamperTargetMissing;
    };
    return std.mem.concat(allocator, u8, &.{ line[0..idx], new, line[idx + old.len ..] });
}

// ===========================================================================
// (4) the tamper matrix, every field, the real writer and verifier
// ===========================================================================

test "SONNY-3147 changing any field of a record breaks verification: timestamp, actor, tenant, session, client address, reason, details, result, resource type, resource graph, resource id, action, event type" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try LogFixture.init(allocator, "sonny3147-fields");
    defer fx.deinit(allocator);

    // The clean log verifies.
    _ = try verify.verifyFileEpochs(allocator, fx.log, .sha256, 0, false, &.{fx.key}, false);

    const lines = try readLines(allocator, fx.log);
    defer freeLines(allocator, lines);
    // Tamper a record in the middle (one that a later DIGEST signs over).
    const k = firstOrdinary(lines, 1);
    try testing.expect(k + 1 < lines.len);

    const Tamper = struct { field: []const u8, old: []const u8, new: []const u8 };
    const tampers = [_]Tamper{
        .{ .field = "timestamp", .old = "\"timestamp\":\"2023-", .new = "\"timestamp\":\"2024-" },
        .{ .field = "actor", .old = "\"actor\":\"user:7\"", .new = "\"actor\":\"user:8\"" },
        .{ .field = "tenant", .old = "\"tenant\":\"tenant-alpha\"", .new = "\"tenant\":\"tenant-bravo\"" },
        .{ .field = "session", .old = "\"session\":\"sess-1\"", .new = "\"session\":\"sess-2\"" },
        .{ .field = "ip_address", .old = "\"ip_address\":\"10.0.0.7\"", .new = "\"ip_address\":\"10.0.0.8\"" },
        .{ .field = "reason", .old = "\"reason\":\"granted\"", .new = "\"reason\":\"grantee\"" },
        .{ .field = "details", .old = secret_detail, .new = "sonny3147-detail-VALUE" },
        .{ .field = "result", .old = "\"result\":\"success\"", .new = "\"result\":\"failure\"" },
        .{ .field = "resource.type", .old = "\"type\":\"node\"", .new = "\"type\":\"edge\"" },
        .{ .field = "resource.graph", .old = "\"graph\":\"g1\"", .new = "\"graph\":\"g2\"" },
        .{ .field = "resource.id", .old = "\"id\":\"n42\"", .new = "\"id\":\"n43\"" },
        .{ .field = "action", .old = "\"action\":\"read\"", .new = "\"action\":\"drop\"" },
        .{ .field = "event_type", .old = "\"event_type\":\"data_access\"", .new = "\"event_type\":\"data_export\"" },
    };
    var undetected: usize = 0;
    var missing_field: usize = 0;
    for (tampers, 0..) |t, ti| {
        const changed = replaced(allocator, lines[k], t.old, t.new) catch {
            std.debug.print("SONNY-3147: the record does not carry {s}\n", .{t.field});
            missing_field += 1;
            continue;
        };
        defer allocator.free(changed);
        var copy = try allocator.alloc([]const u8, lines.len);
        defer allocator.free(copy);
        for (lines, 0..) |l, i| copy[i] = l;
        copy[k] = changed;
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "tamper-{d}.jsonl", .{ti});
        const p = try fx.variant(allocator, name, copy);
        defer allocator.free(p);
        if (verify.verifyFileEpochs(allocator, p, .sha256, 0, false, &.{fx.key}, false)) |_| {
            std.debug.print("SONNY-3147: changing {s} in record {d} went undetected\n", .{ t.field, k + 1 });
            undetected += 1;
        } else |_| {}
    }
    try testing.expectEqual(@as(usize, 0), missing_field);
    try testing.expectEqual(@as(usize, 0), undetected);
}

test "SONNY-3147 a field change with every later hash recomputed (the attacker knows the algorithm) fails at the next signed DIGEST" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    if (comptime !has_versions) {
        std.debug.print("SONNY-3147: the verifier has no hash format versions (EpochSummary.v1_records)\n", .{});
        return error.TestUnexpectedResult;
    }
    const allocator = testing.allocator;
    var fx = try LogFixture.init(allocator, "sonny3147-recompute");
    defer fx.deinit(allocator);
    const lines = try readLines(allocator, fx.log);
    defer freeLines(allocator, lines);
    const k = firstOrdinary(lines, 0);
    // Rewrite record k's details and recompute k and every later record's
    // prev_hash and v2 event_hash, keeping each signature as it was.
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |l| allocator.free(l);
        owned.deinit(allocator);
    }
    var out = try allocator.alloc([]const u8, lines.len);
    defer allocator.free(out);
    var last: [32]u8 = [_]u8{0} ** 32;
    for (lines, 0..) |l, i| {
        var line: []const u8 = l;
        if (i == k) {
            const t = try replaced(allocator, l, secret_detail, "sonny3147-detail-VALUE");
            try owned.append(allocator, t);
            line = t;
        }
        if (i >= k) {
            const r = try rechain(allocator, line, last);
            try owned.append(allocator, r.line);
            line = r.line;
            last = r.event_hash;
        } else last = try verify.hex32(eventHashHex(l) orelse return error.NoHash);
        out[i] = line;
    }
    const p = try fx.variant(allocator, "recomputed.jsonl", out);
    defer allocator.free(p);
    // The chain and every record hash are consistent, so only a signature
    // can catch it: with the trusted key it fails.
    try testing.expectError(error.InvalidSignature, verify.verifyFileEpochs(allocator, p, .sha256, 0, false, &.{fx.key}, false));
}

// ===========================================================================
// (3)/(4) structural tampering and the CLI verdict, through the real binary
// ===========================================================================

const Run = struct {
    code: ?u8,
    output: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.output);
    }

    fn has(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output, needle) != null;
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("SONNY-3147 {s}: exit={?d}\n{s}\n", .{ what, self.code, self.output[0..@min(self.output.len, 4000)] });
    }
};

fn auditVerify(allocator: std.mem.Allocator, dir: []const u8, log: []const u8, keys: []const [32]u8) !Run {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var hexes: std.ArrayList([64]u8) = .empty;
    defer hexes.deinit(allocator);
    for (keys) |k| try hexes.append(allocator, std.fmt.bytesToHex(k, .lower));
    try argv.appendSlice(allocator, &.{ geode_binary, "audit", "verify", "--file", log });
    for (hexes.items) |*h| try argv.appendSlice(allocator, &.{ "--pubkey", h });

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", dir);
    const out_path = try join(allocator, dir, "verify.out");
    defer allocator.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv.items,
        .environ_map = &env,
        .cwd = .{ .path = dir },
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited: u32 = 0;
    while (waited < 60_000) : (waited += 50) {
        if (linux.waitpid(pid, &status, linux.W.NOHANG) == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        sleepMs(50);
    }
    if (!exited) {
        posix.kill(pid, .KILL) catch {};
        _ = linux.waitpid(pid, &status, 0);
    }
    const code: ?u8 = if (exited and (status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else null;
    return .{ .code = code, .output = try readFileAlloc(testing.allocator, out_path) };
}

/// A failing verification: non-zero exit, one verdict that is not OK, and
/// none of the record's contents.
fn expectRefused(r: Run, what: []const u8) !void {
    const ok = r.code != null and r.code.? != 0 and !r.has("OK chain") and !r.has(secret_detail);
    if (!ok) r.dump(what);
    try testing.expect(r.code != null and r.code.? != 0);
    // SONNY-6340 (3): no "OK" summary before a failure.
    try testing.expect(!r.has("OK chain"));
    try testing.expect(!r.has(secret_detail));
}

test "SONNY-3147 geode audit verify: a clean log passes with one OK verdict; a changed field, a deleted, reordered or inserted record, a wrong key each exit non-zero without an OK line and without printing record contents" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try LogFixture.init(allocator, "sonny3147-cli");
    defer fx.deinit(allocator);
    const dir = fx.dir.path();

    {
        const r = try auditVerify(allocator, dir, fx.log, &.{fx.key});
        defer r.deinit();
        if (r.code != @as(?u8, 0)) r.dump("clean log");
        try testing.expectEqual(@as(?u8, 0), r.code);
        try testing.expect(!r.has(secret_detail));
    }

    const lines = try readLines(allocator, fx.log);
    defer freeLines(allocator, lines);
    const k = firstOrdinary(lines, 1);
    var copy = try allocator.alloc([]const u8, lines.len);
    defer allocator.free(copy);

    // A changed details value.
    {
        for (lines, 0..) |l, i| copy[i] = l;
        const changed = try replaced(allocator, lines[k], secret_detail, "sonny3147-detail-VALUE");
        defer allocator.free(changed);
        copy[k] = changed;
        const p = try fx.variant(allocator, "cli-details.jsonl", copy);
        defer allocator.free(p);
        const r = try auditVerify(allocator, dir, p, &.{fx.key});
        defer r.deinit();
        try expectRefused(r, "changed details");
        try testing.expect(!r.has("sonny3147-detail-VALUE"));
    }
    // A deleted record.
    {
        var n: usize = 0;
        for (lines, 0..) |l, i| if (i != k) {
            copy[n] = l;
            n += 1;
        };
        const p = try fx.variant(allocator, "cli-deleted.jsonl", copy[0..n]);
        defer allocator.free(p);
        const r = try auditVerify(allocator, dir, p, &.{fx.key});
        defer r.deinit();
        try expectRefused(r, "deleted record");
    }
    // Two records swapped.
    {
        for (lines, 0..) |l, i| copy[i] = l;
        copy[k] = lines[k + 1];
        copy[k + 1] = lines[k];
        const p = try fx.variant(allocator, "cli-reordered.jsonl", copy);
        defer allocator.free(p);
        const r = try auditVerify(allocator, dir, p, &.{fx.key});
        defer r.deinit();
        try expectRefused(r, "reordered records");
    }
    // A forged record inserted (a copy of a real one).
    {
        var big = try allocator.alloc([]const u8, lines.len + 1);
        defer allocator.free(big);
        var n: usize = 0;
        for (lines, 0..) |l, i| {
            big[n] = l;
            n += 1;
            if (i == k) {
                big[n] = l;
                n += 1;
            }
        }
        const p = try fx.variant(allocator, "cli-inserted.jsonl", big);
        defer allocator.free(p);
        const r = try auditVerify(allocator, dir, p, &.{fx.key});
        defer r.deinit();
        try expectRefused(r, "inserted record");
    }
    // A key that did not sign the digests (SONNY-6340 (3): it printed
    // "OK chain" and then failed).
    {
        var bogus: [32]u8 = undefined;
        _ = linux.getrandom(&bogus, bogus.len, 0);
        const r = try auditVerify(allocator, dir, fx.log, &.{bogus});
        defer r.deinit();
        try expectRefused(r, "wrong public key");
    }
}

test "SONNY-3147 tail truncation: removing records after the last signed DIGEST is not detectable from the log alone; a cleanly closed log ends with a signed DIGEST" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try LogFixture.init(allocator, "sonny3147-tail");
    defer fx.deinit(allocator);
    const lines = try readLines(allocator, fx.log);
    defer freeLines(allocator, lines);
    // 8 events with a digest every 3 and a clean close: the last record is a
    // DIGEST (signed), covering the 2 events after the second interval.
    const last = lines[lines.len - 1];
    if (std.mem.indexOf(u8, last, "\"event_type\":\"DIGEST\"") == null) {
        std.debug.print("SONNY-3147: a cleanly closed log does not end with a DIGEST, so up to digest_interval-1 trailing records can be cut without trace\n", .{});
        return error.TestUnexpectedResult;
    }
    // Cutting back to an earlier DIGEST boundary still verifies: the
    // documented limit (an external anchor of the last seq_no/hash is needed).
    var cut = lines.len - 1;
    while (cut > 0 and std.mem.indexOf(u8, lines[cut - 1], "\"event_type\":\"DIGEST\"") == null) cut -= 1;
    try testing.expect(cut > 0);
    var copy = try allocator.alloc([]const u8, cut);
    defer allocator.free(copy);
    for (lines[0..cut], 0..) |l, i| copy[i] = l;
    const p = try fx.variant(allocator, "cut.jsonl", copy);
    defer allocator.free(p);
    _ = try verify.verifyFileEpochs(allocator, p, .sha256, 0, false, &.{fx.key}, false);
}

// ===========================================================================
// (2) old (v1) logs, the upgrade, and a downgrade
// ===========================================================================

/// The v1 rule: SHA-256(prev_hash || event_type || resource.id || action).
fn hashV1(prev: [32]u8, event_type: []const u8, id: []const u8, action: []const u8) [32]u8 {
    var h = Sha256.init(.{});
    h.update(&prev);
    h.update(event_type);
    h.update(id);
    h.update(action);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

fn chainPrev(last: [32]u8) [32]u8 {
    var out: [32]u8 = undefined;
    Sha256.hash(&last, &out, .{});
    return out;
}

/// A record line exactly as the v1 writer printed it.
fn v1Line(allocator: std.mem.Allocator, seq: u64, last: [32]u8, event_type: []const u8, actor: []const u8, details: []const u8, kp: ?std.crypto.sign.Ed25519.KeyPair, out_hash: *[32]u8) ![]u8 {
    const prev = chainPrev(last);
    const is_digest = std.mem.eql(u8, event_type, "DIGEST");
    const id = if (is_digest) "digest" else "n1";
    const action = if (is_digest) "EMIT_DIGEST" else "read";
    const eh = hashV1(prev, event_type, id, action);
    out_hash.* = eh;
    var sig_buf: [140]u8 = undefined;
    const sig: []const u8 = if (kp) |k| blk: {
        const s = try k.sign(&eh, null);
        break :blk try std.fmt.bufPrint(&sig_buf, "\"{s}\"", .{std.fmt.bytesToHex(s.toBytes(), .lower)});
    } else "null";
    if (is_digest) return std.fmt.allocPrint(allocator, "{{\"stream\":\"geode\",\"seq_no\":{d},\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"event_type\":\"DIGEST\",\"actor\":\"user:0\",\"origin\":\"srv\",\"session\":\"\",\"details\":{{\"merkle_root\":\"00\"}},\"prev_hash\":\"{s}\",\"event_hash\":\"{s}\",\"signature\":{s}}}", .{
        seq, std.fmt.bytesToHex(prev, .lower), std.fmt.bytesToHex(eh, .lower), sig,
    });
    return std.fmt.allocPrint(allocator, "{{\"stream\":\"geode\",\"seq_no\":{d},\"timestamp\":\"2026-01-01T00:00:00.000Z\",\"event_type\":\"{s}\",\"actor\":\"{s}\",\"origin\":\"srv\",\"resource\":{{\"type\":\"node\",\"id\":\"{s}\"}},\"action\":\"{s}\",\"result\":\"success\",\"details\":{{\"q\":\"{s}\"}},\"prev_hash\":\"{s}\",\"event_hash\":\"{s}\",\"signature\":{s}}}", .{
        seq, event_type, actor, id, action, details, std.fmt.bytesToHex(prev, .lower), std.fmt.bytesToHex(eh, .lower), sig,
    });
}

test "SONNY-3147 an old (v1) log verifies under the v1 rule and is reported as v1-only; the new writer appends v2 records to it and the mixed log verifies; a v1 record after a v2 record is refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var dir = try test_scratch.ScratchDir.create("sonny3147-v1");
    defer dir.remove();
    const log = try join(allocator, dir.path(), "audit.jsonl");
    defer allocator.free(log);

    // The epoch-0 key pair, as the old writer kept it beside the log.
    var seed: [32]u8 = undefined;
    _ = linux.getrandom(&seed, seed.len, 0);
    const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const key = kp.public_key.toBytes();
    {
        const pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{log});
        defer allocator.free(pub_path);
        try writeFile(pub_path, &std.fmt.bytesToHex(key, .lower));
        const key_path = try std.fmt.allocPrint(allocator, "{s}.key", .{log});
        defer allocator.free(key_path);
        try writeFile(key_path, &std.fmt.bytesToHex(seed, .lower));
    }

    // Three v1 events and a v1 DIGEST signed by the key.
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| allocator.free(l);
        lines.deinit(allocator);
    }
    var last: [32]u8 = [_]u8{0} ** 32;
    var seq: u64 = 0;
    for (0..3) |_| {
        seq += 1;
        try lines.append(allocator, try v1Line(allocator, seq, last, "data_access", "user:1", "v1", null, &last));
    }
    seq += 1;
    try lines.append(allocator, try v1Line(allocator, seq, last, "DIGEST", "user:0", "", kp, &last));
    try writeLines(allocator, log, lines.items);

    if (comptime !has_versions) {
        std.debug.print("SONNY-3147: the verifier has no hash format versions: v1 records are not reported as weaker, and a downgrade cannot be detected\n", .{});
        return error.TestUnexpectedResult;
    } else {
        const s1 = try verify.verifyFileEpochs(allocator, log, .sha256, 0, false, &.{key}, false);
        try testing.expectEqual(@as(u64, 4), s1.v1_records);
        try testing.expectEqual(@as(u64, 0), s1.v2_records);

        // A v1 record's covered field (action) is still checked.
        {
            const changed = try replaced(allocator, lines.items[1], "\"action\":\"read\"", "\"action\":\"drop\"");
            defer allocator.free(changed);
            const p = try join(allocator, dir.path(), "v1-action.jsonl");
            defer allocator.free(p);
            var copy = try allocator.alloc([]const u8, lines.items.len);
            defer allocator.free(copy);
            for (lines.items, 0..) |l, i| copy[i] = l;
            copy[1] = changed;
            try writeLines(allocator, p, copy);
            try testing.expectError(error.EventHashMismatch, verify.verifyFileEpochs(allocator, p, .sha256, 0, false, &.{key}, false));
        }

        // The new writer continues the old log (same key, same epoch).
        {
            var logger = try AuditLogger.init(allocator, .{ .enabled = true, .file_path = log, .digest_interval = 3 });
            defer logger.deinit();
            try appendRichEvents(allocator, &logger, 4, 100);
        }
        const s2 = try verify.verifyFileEpochs(allocator, log, .sha256, 0, false, &.{key}, false);
        try testing.expectEqual(@as(u64, 4), s2.v1_records);
        try testing.expect(s2.v2_records >= 4);
        try testing.expectEqual(@as(u32, 0), s2.epochs);

        // A downgrade: a correctly chained v1 record after the v2 records.
        {
            const raw = try readFileAlloc(allocator, log);
            defer allocator.free(raw);
            var it = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, raw, "\n"), '\n');
            const tail = it.next().?;
            const tail_hash = try verify.hex32(eventHashHex(tail) orelse return error.NoHash);
            const sq = "\"seq_no\":";
            const j = std.mem.indexOf(u8, tail, sq).? + sq.len;
            var e = j;
            while (std.ascii.isDigit(tail[e])) e += 1;
            const tail_seq = try std.fmt.parseInt(u64, tail[j..e], 10);
            var h: [32]u8 = undefined;
            const down = try v1Line(allocator, tail_seq + 1, tail_hash, "data_access", "user:1", "down", null, &h);
            defer allocator.free(down);
            const p = try join(allocator, dir.path(), "downgrade.jsonl");
            defer allocator.free(p);
            const bytes = try std.mem.concat(allocator, u8, &.{ raw, down, "\n" });
            defer allocator.free(bytes);
            try writeFile(p, bytes);
            try testing.expectError(error.HashVersionDowngrade, verify.verifyFileEpochs(allocator, p, .sha256, 0, false, &.{key}, false));
        }
    }
}

test "SONNY-3147 the verifier recomputes every ordinary record's event_hash: a record whose stored event_hash was replaced is refused even when nothing else changed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var fx = try LogFixture.init(allocator, "sonny3147-recompute-check");
    defer fx.deinit(allocator);
    const lines = try readLines(allocator, fx.log);
    defer freeLines(allocator, lines);
    // Replace the last record's event_hash (no DIGEST or later record covers
    // it, so only a per-record recomputation can notice).
    const li = lines.len - 1;
    const old_hex = eventHashHex(lines[li]) orelse return error.NoHash;
    var bogus: [32]u8 = undefined;
    _ = linux.getrandom(&bogus, bogus.len, 0);
    const changed = try replaced(allocator, lines[li], old_hex, &std.fmt.bytesToHex(bogus, .lower));
    defer allocator.free(changed);
    var copy = try allocator.alloc([]const u8, lines.len);
    defer allocator.free(copy);
    for (lines, 0..) |l, i| copy[i] = l;
    copy[li] = changed;
    const p = try fx.variant(allocator, "rehash.jsonl", copy);
    defer allocator.free(p);
    // Without keys (chain and hashes only) and with keys.
    try testing.expect(std.meta.isError(verify.verifyFileEpochs(allocator, p, .sha256, 0, false, &.{}, false)));
    try testing.expect(std.meta.isError(verify.verifyFileEpochs(allocator, p, .sha256, 0, false, &.{fx.key}, false)));
}

// ===========================================================================
// (5) throughput, informational (Debug build)
// ===========================================================================

test "SONNY-3147 audit append throughput (informational, this build mode)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var dir = try test_scratch.ScratchDir.create("sonny3147-perf");
    defer dir.remove();
    const log = try join(allocator, dir.path(), "audit.jsonl");
    defer allocator.free(log);
    var logger = try AuditLogger.init(allocator, .{ .enabled = true, .file_path = log });
    defer logger.deinit();
    const n: usize = 3000;
    var t0: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t0);
    try appendRichEvents(allocator, &logger, n, 0);
    var t1: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &t1);
    const ns: u64 = @intCast((t1.sec - t0.sec) * std.time.ns_per_s + (t1.nsec - t0.nsec));
    std.debug.print("SONNY-3147 throughput: {d} rich events in {d} ms = {d} events/s ({s})\n", .{ n, ns / std.time.ns_per_ms, n * std.time.ns_per_s / @max(ns, 1), @tagName(builtin.mode) });
}
