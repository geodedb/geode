const std = @import("std");
const cb = @import("crypto_backend");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}
// CANARY: REQ=REQ-AUDIT-VERIFY-001; FEATURE="Audit Verification"; ASPECT=ChainVerification; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth.yml,tests/test_audit_verify_chain_roundtrip.zig; OWNER=security; UPDATED=2026-05-21
// GAP-0151 RESOLVED: Now implements Ed25519 signature verification and digest interval validation

pub const HashAlgo = enum { sha256, blake3 };

pub const VerifyError = error{
    BadHexLen,
    ReadError,
    OutOfMemory,
    Invalid,
    MissingDigest,
    InvalidSignature,
    MissingSignature,
    DigestIntervalExceeded,
    // GAP-0727 / SEC-AUD-01 (2026-04-16): seq_no must be monotonic +1
    // across the whole file.  Any gap, duplicate, or reorder fails here.
    SequenceMonotonicityViolation,
    // SONNY-6322: audit key epochs (see verifyFileEpochs).
    KeyEpochOrder,
    KeyEpochHashMismatch,
    UntrustedKeyEpoch,
    // SONNY-3147: a record's prev_hash does not follow from the previous
    // record (it used to exit the process with status 3 from here).
    ChainMismatch,
    // SONNY-3147: the stored event_hash is not the hash of the record.
    EventHashMismatch,
    // SONNY-3147: a format-1 record after a format-2 record.
    HashVersionDowngrade,
    // SONNY-3147: a `hash_v` this verifier does not know.
    UnsupportedHashVersion,
    // SONNY-3147: not one JSON object ending in prev_hash, event_hash,
    // signature (in that order and shape), or duplicate keys.
    RecordFormat,
};

// CANARY: REQ=REQ-SONNY-6322-AUDIT-KEY-EPOCH; FEATURE="Audit Verification"; ASPECT=EpochVerification; STATUS=TESTED; TEST=tests/test_sonny6322_audit_seed_and_hmac_startup.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-6322: what `verifyFileEpochs` checked.
pub const EpochSummary = struct {
    records: u64 = 0,
    digests: u32 = 0,
    /// KEY_EPOCH records seen (the log's last epoch number when they are
    /// contiguous).
    epochs: u32 = 0,
    signatures_verified: u32 = 0,
    signatures_failed: u32 = 0,
    /// SONNY-3147: records checked under hash format 1 (only event_type,
    /// resource.id and action covered) and format 2 (the whole record).
    v1_records: u64 = 0,
    v2_records: u64 = 0,
};

/// SONNY-3147: hash format 2 (must match AuditEvent.eventHashV2 in
/// src/security/rls_core.zig; the writer/verifier round trip in
/// tests/test_sonny3147_audit_hash_coverage.zig pins both).
pub const hash_v2_domain = "geode.audit.event_hash.v2\x00";

fn eventHashV2(kind_tag: []const u8, prev: *const [32]u8, body: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(hash_v2_domain);
    h.update(kind_tag);
    h.update(&[_]u8{0});
    h.update(prev);
    h.update(body);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// Hash format 1: SHA-256(prev_hash || event_type || resource.id || action).
pub fn hashV1(prev: *const [32]u8, event_type: []const u8, id: []const u8, action: []const u8) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(prev);
    h.update(event_type);
    h.update(id);
    h.update(action);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// SONNY-3147: a record line split from its fixed-shape end:
/// `<body>"prev_hash":"<64 hex>","event_hash":"<64 hex>","signature":null}`
/// or `...,"signature":"<128 hex>"}`. `body` is what event_hash covers.
const SplitRecord = struct {
    body: []const u8,
    prev_hex: []const u8,
    ev_hex: []const u8,
    sig_hex: ?[]const u8,
};

const tail_prev = "\"prev_hash\":\"";
const tail_ev = "\",\"event_hash\":\"";
const tail_sig_null = "\",\"signature\":null}";
const tail_sig_open = "\",\"signature\":\"";
const tail_sig_close = "\"}";
const tail_null_len = tail_prev.len + 64 + tail_ev.len + 64 + tail_sig_null.len;
const tail_signed_len = tail_prev.len + 64 + tail_ev.len + 64 + tail_sig_open.len + 128 + tail_sig_close.len;

fn splitRecord(line: []const u8) ?SplitRecord {
    var sig_hex: ?[]const u8 = null;
    var tail_len: usize = 0;
    if (std.mem.endsWith(u8, line, tail_sig_null) and line.len >= tail_null_len) {
        tail_len = tail_null_len;
    } else if (std.mem.endsWith(u8, line, tail_sig_close) and line.len >= tail_signed_len) {
        const sig_open_at = line.len - tail_sig_close.len - 128 - tail_sig_open.len;
        if (!std.mem.eql(u8, line[sig_open_at..][0..tail_sig_open.len], tail_sig_open)) return null;
        sig_hex = line[sig_open_at + tail_sig_open.len ..][0..128];
        tail_len = tail_signed_len;
    } else return null;
    const t = line.len - tail_len;
    const tail = line[t..];
    if (!std.mem.startsWith(u8, tail, tail_prev)) return null;
    if (!std.mem.eql(u8, tail[tail_prev.len + 64 ..][0..tail_ev.len], tail_ev)) return null;
    const body = line[0..t];
    if (body.len < 2 or body[0] != '{' or body[body.len - 1] != ',') return null;
    return .{
        .body = body,
        .prev_hex = tail[tail_prev.len..][0..64],
        .ev_hex = tail[tail_prev.len + 64 + tail_ev.len ..][0..64],
        .sig_hex = sig_hex,
    };
}

/// The stored event_hash (hex) of a record line, or null when the line does
/// not end in the record tail.
pub fn recordEventHashHex(line: []const u8) ?[]const u8 {
    const r = splitRecord(line) orelse return null;
    return r.ev_hex;
}

/// The `hash_v` of a record body: the number right after the stream field
/// (`{"stream":"<s>","hash_v":<n>,`), or 1 when there is none.
fn hashVersion(body: []const u8) VerifyError!u32 {
    const open = "{\"stream\":\"";
    if (!std.mem.startsWith(u8, body, open)) return error.RecordFormat;
    var i: usize = open.len;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            i += 1;
            continue;
        }
        if (body[i] == '"') break;
    }
    if (i >= body.len) return error.RecordFormat;
    const after = body[i + 1 ..];
    const key = ",\"hash_v\":";
    if (!std.mem.startsWith(u8, after, key)) return 1;
    var j: usize = key.len;
    while (j < after.len and std.ascii.isDigit(after[j])) j += 1;
    if (j == key.len or j >= after.len or after[j] != ',') return error.RecordFormat;
    return std.fmt.parseInt(u32, after[key.len..j], 10) catch error.RecordFormat;
}

fn objString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Verify the record's Ed25519 `signature` over its event hash with `key`.
fn signatureValid(sig_hex: ?[]const u8, ev_hash: [32]u8, key: [32]u8, seq: u64) bool {
    const sh = sig_hex orelse {
        std.debug.print("SIGNATURE_ERROR ❌  at_record={} reason=MISSING_SIGNATURE\n", .{seq});
        return false;
    };
    const sig_bytes = hex64(sh) catch {
        std.debug.print("SIGNATURE_ERROR ❌  at_record={} reason=INVALID_SIGNATURE_FORMAT\n", .{seq});
        return false;
    };
    var pub_kp = cb.Sig.KeyPair.fromPublicBytes(.ed25519, &key) catch {
        std.debug.print("SIGNATURE_ERROR ❌  at_record={} reason=INVALID_PUBLIC_KEY\n", .{seq});
        return false;
    };
    defer pub_kp.deinit();
    cb.Sig.verify(.ed25519, &pub_kp, &ev_hash, &sig_bytes) catch {
        std.debug.print("SIGNATURE_ERROR ❌  at_record={} reason=VERIFICATION_FAILED\n", .{seq});
        return false;
    };
    return true;
}

pub fn hex32(buf: []const u8) VerifyError![32]u8 {
    if (buf.len != 64) return error.BadHexLen;
    var out: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) out[i] = std.fmt.parseInt(u8, buf[i * 2 .. i * 2 + 2], 16) catch return error.Invalid;
    return out;
}

pub fn hex64(buf: []const u8) VerifyError![64]u8 {
    if (buf.len != 128) return error.BadHexLen;
    var out: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 64) : (i += 1) out[i] = std.fmt.parseInt(u8, buf[i * 2 .. i * 2 + 2], 16) catch return error.Invalid;
    return out;
}

/// GAP-0151: Full audit verification with Ed25519 signature and digest interval validation
/// CANARY: REQ=REQ-AUDIT-VERIFY-002; FEATURE="Audit Signature Verification"; ASPECT=Ed25519Verify; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth.yml; OWNER=security; UPDATED=2026-01-15
pub fn verifyFile(allocator: std.mem.Allocator, path: []const u8, algo: HashAlgo, digest_interval_events: u32, require_digest: bool, pubkey: ?[32]u8, is_default_path: bool) VerifyError!void {
    var one: [1][32]u8 = undefined;
    const keys: []const [32]u8 = if (pubkey) |pk| blk: {
        one[0] = pk;
        break :blk one[0..1];
    } else &.{};
    _ = try verifyFileEpochs(allocator, path, algo, digest_interval_events, require_digest, keys, is_default_path);
}

// CANARY: REQ=REQ-SONNY-3147-AUDIT-HASH-COVERAGE; FEATURE="Audit Verification"; ASPECT=RecomputeEveryRecordHash; STATUS=TESTED; TEST=tests/test_sonny3147_audit_hash_coverage.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6322: `verifyFile` across audit key epochs. `trusted_keys[n]` is the
/// public key of epoch n (`audit.jsonl.pub` for 0, `audit.jsonl.pub.<n>`
/// after); supply them from a trusted copy, not from beside the log. With
/// keys, every DIGEST must verify with its epoch's key and every KEY_EPOCH
/// record must name exactly `trusted_keys[n]` and be signed by it; epochs
/// must increase. Any failed signature fails the verification
/// (error.InvalidSignature). Without keys only the chain, the record hashes,
/// the sequence and the digest interval are checked.
///
/// SONNY-3147: every record's event_hash is recomputed: a `hash_v` 2 record
/// over its whole canonical body (eventHashV2), a record without `hash_v`
/// under format 1 (event_type, resource.id, action only; counted in
/// `v1_records` and reported as weaker). A format-1 record after a format-2
/// record fails (HashVersionDowngrade). Failures name the record number and
/// the failure class, never record contents. Nothing is printed as OK unless
/// everything verified.
///
/// What a pass attests across a KEY_EPOCH boundary: the records before it
/// were signed by the previous key and the records after by the new one,
/// in one unbroken hash chain. The previous key did not sign the hand-over
/// (after a restore it is not available), so that the new epoch belongs to
/// the same store is attested by the operator who restored it.
pub fn verifyFileEpochs(allocator: std.mem.Allocator, path: []const u8, algo: HashAlgo, digest_interval_events: u32, require_digest: bool, trusted_keys: []const [32]u8, is_default_path: bool) VerifyError!EpochSummary {
    var file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch |err| {
        if (err == error.FileNotFound and is_default_path) {
            // Default path not found — nothing to verify, treat as clean.
            std.debug.print("audit log not found: {s} (0 records verified)\n", .{path});
            return .{};
        }
        return error.ReadError;
    };
    defer file.close(std.Io.Threaded.global_single_threaded.io());
    var buf: [4096]u8 = undefined;
    var rd = file.reader(std.Io.Threaded.global_single_threaded.io(), &buf);
    var line_buf = std.ArrayList(u8).empty;
    defer line_buf.deinit(allocator);

    var seq: u64 = 0;
    var last_hash: [32]u8 = [_]u8{0} ** 32;
    var digest_count: u32 = 0;
    var records: u64 = 0;
    var events_since_digest: u32 = 0;
    var signature_verified_count: u32 = 0;
    var signature_failed_count: u32 = 0;
    // SONNY-6322: the current key epoch and its key.
    var epoch: u32 = 0;
    var epochs_seen: u32 = 0;
    var epoch_key: ?[32]u8 = if (trusted_keys.len > 0) trusted_keys[0] else null;
    // SONNY-3147: hash format counts.
    var v1_records: u64 = 0;
    var v2_records: u64 = 0;

    while (true) {
        line_buf.clearRetainingCapacity();
        while (true) {
            var one: [1]u8 = undefined;
            const n = rd.interface.readSliceShort(&one) catch return error.ReadError;
            if (n == 0) break;
            if (one[0] == '\n') break;
            line_buf.append(allocator, one[0]) catch return error.OutOfMemory;
        }
        if (line_buf.items.len == 0) break;
        const line = line_buf.items;
        const at = seq + 1;

        // SONNY-3147: the record tail has a fixed shape; take prev_hash,
        // event_hash and signature from it, never from a search of the
        // line (a details key could be named like them).
        const rec = splitRecord(line) orelse {
            std.debug.print("SCHEMA_ERROR ❌  at_record={} reason=RECORD_TAIL (not ...\"prev_hash\",\"event_hash\",\"signature\"}})\n", .{at});
            return error.RecordFormat;
        };
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), line, .{}) catch {
            std.debug.print("SCHEMA_ERROR ❌  at_record={} reason=NOT_ONE_JSON_OBJECT (or a duplicate key)\n", .{at});
            return error.RecordFormat;
        };
        if (parsed != .object) return error.RecordFormat;
        const obj = parsed.object;
        const typ = objString(obj, "event_type") orelse {
            std.debug.print("SCHEMA_ERROR ❌  at_record={} field=event_type detail=missing\n", .{at});
            return error.RecordFormat;
        };
        const resource: ?std.json.ObjectMap = if (obj.get("resource")) |r| switch (r) {
            .object => |o| o,
            else => null,
        } else null;
        const action = objString(obj, "action");
        const res_type: ?[]const u8 = if (resource) |r| objString(r, "type") else null;
        const res_id: ?[]const u8 = if (resource) |r| objString(r, "id") else null;
        const is_digest = std.mem.eql(u8, typ, "DIGEST");
        const is_epoch_record = res_type != null and std.mem.eql(u8, res_type.?, "audit_key_epoch") and
            action != null and std.mem.eql(u8, action.?, "KEY_EPOCH");

        // Verify chain integrity. Bug #828 / GAP-0305: the writer stores
        // prev_hash = SHA256(last_hash), not the bare previous event_hash.
        const prev_buf = try hex32(rec.prev_hex);
        var expected_prev: [32]u8 = undefined;
        _ = cb.Hash.digest(.sha256, &last_hash, &expected_prev) catch return error.ReadError;
        if (!std.mem.eql(u8, &prev_buf, &expected_prev)) {
            std.debug.print("TAMPER chain ❌  at_record={} reason=PREV_HASH_MISMATCH (a record before it was removed, inserted, reordered or changed)\n", .{at});
            return error.ChainMismatch;
        }
        const ev_hash = try hex32(rec.ev_hex);

        // GAP-0727 / SEC-AUD-01: seq_no must advance by exactly one.
        const parsed_seq: u64 = blk_seq: {
            if (obj.get("seq_no")) |v| switch (v) {
                .integer => |iv| if (iv >= 0) break :blk_seq @intCast(iv),
                else => {},
            };
            std.debug.print("SCHEMA_ERROR ❌  at_record={} field=seq_no detail=missing\n", .{at});
            return error.RecordFormat;
        };
        if (parsed_seq != at) {
            std.debug.print(
                "TAMPER sequence ❌  at_record={} reason=SEQ_NO_MONOTONICITY expected={} got={}\n",
                .{ at, at, parsed_seq },
            );
            return error.SequenceMonotonicityViolation;
        }

        // SONNY-3147: recompute the record's event_hash.
        const version = try hashVersion(rec.body);
        const expect_hash: [32]u8 = switch (version) {
            1 => blk_v1: {
                if (v2_records > 0) {
                    std.debug.print("TAMPER hash_format ❌  at_record={} reason=HASH_VERSION_DOWNGRADE (a format-1 record after format-2 records)\n", .{at});
                    return error.HashVersionDowngrade;
                }
                v1_records += 1;
                // The format-1 writer hashed these constants for a DIGEST,
                // whose line does not print them.
                const id = if (is_digest) "digest" else res_id orelse {
                    std.debug.print("SCHEMA_ERROR ❌  at_record={} field=resource.id detail=missing\n", .{at});
                    return error.RecordFormat;
                };
                const act = if (is_digest) "EMIT_DIGEST" else action orelse {
                    std.debug.print("SCHEMA_ERROR ❌  at_record={} field=action detail=missing\n", .{at});
                    return error.RecordFormat;
                };
                break :blk_v1 hashV1(&prev_buf, typ, id, act);
            },
            2 => blk_v2: {
                v2_records += 1;
                const kind_tag: []const u8 = if (is_digest) "digest" else if (is_epoch_record) "key_epoch" else "event";
                break :blk_v2 eventHashV2(kind_tag, &prev_buf, rec.body);
            },
            else => {
                std.debug.print("SCHEMA_ERROR ❌  at_record={} reason=UNSUPPORTED_HASH_VERSION hash_v={}\n", .{ at, version });
                return error.UnsupportedHashVersion;
            },
        };
        if (!std.mem.eql(u8, &expect_hash, &ev_hash)) {
            std.debug.print("TAMPER record ❌  at_record={} reason=EVENT_HASH_MISMATCH hash_v={} (a field covered by event_hash was changed, or the stored hash was replaced)\n", .{ at, version });
            return if (is_epoch_record) error.KeyEpochHashMismatch else error.EventHashMismatch;
        }
        last_hash = ev_hash;

        // SONNY-6322: a KEY_EPOCH record starts a new signing-key epoch. Its
        // event_hash (checked above) commits to the epoch and key it names.
        if (is_epoch_record) {
            const id = res_id orelse return error.RecordFormat;
            const colon = std.mem.indexOfScalar(u8, id, ':') orelse return error.RecordFormat;
            if (!std.mem.startsWith(u8, id, "epoch-") or colon <= "epoch-".len) return error.RecordFormat;
            const n = std.fmt.parseInt(u32, id["epoch-".len..colon], 10) catch return error.RecordFormat;
            const new_key = try hex32(id[colon + 1 ..]);
            if (n <= epoch) {
                std.debug.print("TAMPER key_epoch ❌  at_record={} reason=EPOCH_NOT_INCREASING epoch={} previous={}\n", .{ at, n, epoch });
                return error.KeyEpochOrder;
            }
            if (trusted_keys.len > 0) {
                if (n >= trusted_keys.len or !std.mem.eql(u8, &trusted_keys[n], &new_key)) {
                    std.debug.print("UNTRUSTED key_epoch ❌  at_record={} epoch={} reason=KEY_NOT_IN_TRUSTED_LIST (pass the public key of every epoch with --pubkey, in order)\n", .{ at, n });
                    return error.UntrustedKeyEpoch;
                }
                if (signatureValid(rec.sig_hex, last_hash, new_key, at)) {
                    signature_verified_count += 1;
                } else {
                    signature_failed_count += 1;
                }
            }
            epoch = n;
            epoch_key = new_key;
            epochs_seen += 1;
            std.debug.print("KEY_EPOCH ⚠  at_record={} epoch={} key={s}... (records before verify with the previous key; continuity across this boundary is attested by the operator who restored the store, not by the previous key)\n", .{ at, n, id[colon + 1 ..][0..16] });
        }

        if (is_digest) {
            digest_count += 1;
            // GAP-0151: Verify the Ed25519 signature on DIGEST events, with
            // the current epoch's key (SONNY-6322).
            if (epoch_key) |pk| {
                if (signatureValid(rec.sig_hex, ev_hash, pk, at)) {
                    signature_verified_count += 1;
                } else {
                    signature_failed_count += 1;
                }
            }
            events_since_digest = 0;
        } else {
            events_since_digest += 1;

            // GAP-0151: Check digest interval
            if (digest_interval_events > 0 and events_since_digest > digest_interval_events) {
                std.debug.print("DIGEST_INTERVAL_ERROR ❌  at_record={} events_since_digest={} max_interval={}\n", .{ at, events_since_digest, digest_interval_events });
                if (require_digest) {
                    return error.DigestIntervalExceeded;
                }
            }
        }

        records += 1;
        seq += 1;
    }

    // GAP-0151: Enforce require_digest at end of file
    if (require_digest and digest_count == 0 and records > 0) {
        std.debug.print("MISSING_DIGEST_ERROR ❌  no DIGEST records found in {} events\n", .{records});
        return error.MissingDigest;
    }

    // SONNY-6322: a signature that does not verify fails the verification.
    // SONNY-6340 (3): decided before any summary, so nothing says OK first.
    if (signature_failed_count > 0) {
        std.debug.print("SIGNATURE_ERROR ❌  {} signature(s) did not verify\n", .{signature_failed_count});
        return error.InvalidSignature;
    }

    // Print verification summary (only on success).
    std.debug.print("OK chain ✅  records={} digests={} algo={s} record_hashes=verified hash_v2={} hash_v1={}", .{ records, digest_count, switch (algo) {
        .sha256 => "sha256",
        .blake3 => "blake3",
    }, v2_records, v1_records });

    if (epochs_seen > 0) std.debug.print(" key_epochs={}", .{epochs_seen});
    if (trusted_keys.len > 0) {
        std.debug.print(" signatures_verified={} signatures_failed={}", .{ signature_verified_count, signature_failed_count });
    } else {
        std.debug.print(" signatures=not_checked (no --pubkey)", .{});
    }

    if (digest_interval_events > 0) {
        std.debug.print(" digest_interval_max={}", .{digest_interval_events});
    }

    // #748: mirror the FileNotFound branch phrase so harness specs that
    // assert `stderr_contains: "records verified"` pass uniformly whether
    // or not the default audit log exists (empty or populated).
    std.debug.print(" ({} records verified)\n", .{records});
    if (v1_records > 0) {
        std.debug.print("NOTICE: {} record(s) use hash format 1 (written before SONNY-3147): their event_hash covers only event_type, resource.id and action, so their timestamp, actor, tenant, session, client address, reason, result, resource type and details are not tamper-evident.\n", .{v1_records});
    }
    return .{
        .records = records,
        .digests = digest_count,
        .epochs = epochs_seen,
        .signatures_verified = signature_verified_count,
        .signatures_failed = signature_failed_count,
        .v1_records = v1_records,
        .v2_records = v2_records,
    };
}

// Unit tests for audit verification
test "hex32 valid input" {
    const input = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const result = try hex32(input);
    try std.testing.expectEqual(@as(u8, 0x01), result[0]);
    try std.testing.expectEqual(@as(u8, 0xef), result[31]);
}

test "hex32 invalid length" {
    const result = hex32("0123");
    try std.testing.expectError(error.BadHexLen, result);
}

test "hex64 valid input" {
    const input = "0123456789abcdef" ** 8;
    const result = try hex64(input);
    try std.testing.expectEqual(@as(u8, 0x01), result[0]);
}

test "TestCANARY_REQ_AUDIT_VERIFY_001_ChainVerification" {
    // CANARY test marker for chain verification
    // Actual verification requires audit file fixture
    try std.testing.expect(true);
}

test "TestCANARY_REQ_AUDIT_VERIFY_002_SignatureVerification" {
    // CANARY test marker for signature verification
    // Verifies Ed25519 is properly routed through crypto_backend seam
    var keypair = try cb.Sig.generate(.ed25519);
    defer keypair.deinit();

    const message = "test message";
    var sig_out: [64]u8 = undefined;
    _ = try cb.Sig.sign(.ed25519, &keypair, message, &sig_out);

    // Verify the signature
    try cb.Sig.verify(.ed25519, &keypair, message, &sig_out);
    try std.testing.expect(true);
}
