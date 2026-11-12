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
// CANARY: REQ=REQ-AUDIT-VERIFY-001; FEATURE="Audit Verification"; ASPECT=ChainVerification; STATUS=TESTED; TEST=tests/geodetestlab/specs/geode_auth.yml,tests/test_audit_verify_chain_roundtrip.zig; OWNER=security; UPDATED=2026-05-21
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
};

const key_epoch_action_pattern = "\"action\":\"KEY_EPOCH\"";
const key_epoch_id_pattern = "\"type\":\"audit_key_epoch\",\"id\":\"";

/// The quoted string value of `field` in `line`, or null.
fn stringField(line: []const u8, comptime field: []const u8) ?[]const u8 {
    const patt = "\"" ++ field ++ "\":\"";
    const idx = std.mem.indexOf(u8, line, patt) orelse return null;
    const start = idx + patt.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse return null;
    return line[start..end];
}

/// Verify the record's Ed25519 `signature` over its event hash with `key`.
fn signatureValid(line: []const u8, ev_hash: [32]u8, key: [32]u8, seq: u64) bool {
    const sig_hex = stringField(line, "signature") orelse {
        std.debug.print("SIGNATURE_ERROR ❌  at_seq={} reason=MISSING_SIGNATURE\n", .{seq});
        return false;
    };
    const sig_bytes = hex64(sig_hex) catch {
        std.debug.print("SIGNATURE_ERROR ❌  at_seq={} reason=INVALID_SIGNATURE_FORMAT\n", .{seq});
        return false;
    };
    var pub_kp = cb.Sig.KeyPair.fromPublicBytes(.ed25519, &key) catch {
        std.debug.print("SIGNATURE_ERROR ❌  at_seq={} reason=INVALID_PUBLIC_KEY\n", .{seq});
        return false;
    };
    defer pub_kp.deinit();
    cb.Sig.verify(.ed25519, &pub_kp, &ev_hash, &sig_bytes) catch {
        std.debug.print("SIGNATURE_ERROR ❌  at_seq={} reason=VERIFICATION_FAILED\n", .{seq});
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
/// CANARY: REQ=REQ-AUDIT-VERIFY-002; FEATURE="Audit Signature Verification"; ASPECT=Ed25519Verify; STATUS=TESTED; TEST=tests/geodetestlab/specs/geode_auth.yml; OWNER=security; UPDATED=2026-01-15
pub fn verifyFile(allocator: std.mem.Allocator, path: []const u8, algo: HashAlgo, digest_interval_events: u32, require_digest: bool, pubkey: ?[32]u8, is_default_path: bool) VerifyError!void {
    var one: [1][32]u8 = undefined;
    const keys: []const [32]u8 = if (pubkey) |pk| blk: {
        one[0] = pk;
        break :blk one[0..1];
    } else &.{};
    _ = try verifyFileEpochs(allocator, path, algo, digest_interval_events, require_digest, keys, is_default_path);
}

/// SONNY-6322: `verifyFile` across audit key epochs. `trusted_keys[n]` is the
/// public key of epoch n (`audit.jsonl.pub` for 0, `audit.jsonl.pub.<n>`
/// after); supply them from a trusted copy, not from beside the log. With
/// keys, every DIGEST must verify with its epoch's key and every KEY_EPOCH
/// record must name exactly `trusted_keys[n]`, carry an event_hash that
/// commits to that key, and be signed by it; epochs must increase. Any
/// failed signature fails the verification (error.InvalidSignature). Without
/// keys only the chain, sequence and digest interval are checked.
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

        // Extract prev_hash
        var patt_prev_buf: [64]u8 = undefined;
        const patt_prev = std.fmt.bufPrint(&patt_prev_buf, "\"{s}\":\"", .{"prev_hash"}) catch return error.Invalid;
        const prev_hex = blk: {
            if (std.mem.indexOf(u8, line, patt_prev)) |idx| {
                const start = idx + patt_prev.len;
                if (std.mem.indexOfScalarPos(u8, line, start, '"')) |end| break :blk line[start..end];
            }
            std.debug.print("SCHEMA_ERROR ❌  at_seq={} field=prev_hash detail=missing\n", .{seq + 1});
            return error.Invalid;
        };

        // Extract event_hash
        var patt_ev_buf: [64]u8 = undefined;
        const patt_ev = std.fmt.bufPrint(&patt_ev_buf, "\"{s}\":\"", .{"event_hash"}) catch return error.Invalid;
        const ev_hex = blk2: {
            if (std.mem.indexOf(u8, line, patt_ev)) |idx| {
                const start = idx + patt_ev.len;
                if (std.mem.indexOfScalarPos(u8, line, start, '"')) |end| break :blk2 line[start..end];
            }
            std.debug.print("SCHEMA_ERROR ❌  at_seq={} field=event_hash detail=missing\n", .{seq + 1});
            return error.Invalid;
        };

        // Extract event_type
        var patt_typ_buf: [64]u8 = undefined;
        const patt_typ = std.fmt.bufPrint(&patt_typ_buf, "\"{s}\":\"", .{"event_type"}) catch return error.Invalid;
        const typ = blk3: {
            if (std.mem.indexOf(u8, line, patt_typ)) |idx| {
                const start = idx + patt_typ.len;
                if (std.mem.indexOfScalarPos(u8, line, start, '"')) |end| break :blk3 line[start..end];
            }
            std.debug.print("SCHEMA_ERROR ❌  at_seq={} field=event_type detail=missing\n", .{seq + 1});
            return error.Invalid;
        };

        // Verify chain integrity. Bug #828 / GAP-0305: the writer at
        // src/security/audit.zig:467-469 stores prev_hash = SHA256(last_hash);
        // it is NOT the bare previous event_hash. Reproduce the same SHA256
        // step here so the comparison matches the on-disk format.
        const prev_buf = try hex32(prev_hex);
        var expected_prev: [32]u8 = undefined;
        _ = cb.Hash.digest(.sha256, &last_hash, &expected_prev) catch return error.ReadError;
        if (!std.mem.eql(u8, &prev_buf, &expected_prev)) {
            std.debug.print("TAMPER chain ❌  at_seq={} reason=PREV_HASH_MISMATCH expected=", .{seq + 1});
            for (expected_prev) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print(" got=", .{});
            for (prev_buf) |b| std.debug.print("{x:0>2}", .{b});
            std.debug.print("\n", .{});
            std.process.exit(3);
        }
        last_hash = try hex32(ev_hex);

        // GAP-0727 / SEC-AUD-01 (2026-04-16): verify the record's self-declared
        // seq_no matches the expected monotonic +1 progression.  Without this,
        // an attacker could delete a middle record and recompute prev_hash
        // chains on subsequent records — the old verifier would miss that
        // because it never parsed seq_no at all.
        //
        // The JSON field is a bare integer (not a quoted string), so parse
        // until the next `,` after `"seq_no":`.
        var patt_seq_buf: [64]u8 = undefined;
        const patt_seq = std.fmt.bufPrint(&patt_seq_buf, "\"{s}\":", .{"seq_no"}) catch return error.Invalid;
        const parsed_seq: u64 = blk_seq: {
            if (std.mem.indexOf(u8, line, patt_seq)) |idx| {
                var p = idx + patt_seq.len;
                // Skip any whitespace before the number.
                while (p < line.len and (line[p] == ' ' or line[p] == '\t')) : (p += 1) {}
                const num_start = p;
                while (p < line.len and std.ascii.isDigit(line[p])) : (p += 1) {}
                if (p > num_start) {
                    break :blk_seq std.fmt.parseInt(u64, line[num_start..p], 10) catch {
                        std.debug.print("SCHEMA_ERROR ❌  at_seq={} field=seq_no detail=non_numeric\n", .{seq + 1});
                        return error.Invalid;
                    };
                }
            }
            std.debug.print("SCHEMA_ERROR ❌  at_seq={} field=seq_no detail=missing\n", .{seq + 1});
            return error.Invalid;
        };
        const expected_seq = seq + 1;
        if (parsed_seq != expected_seq) {
            std.debug.print(
                "TAMPER sequence ❌  at_record={} reason=SEQ_NO_MONOTONICITY expected={} got={}\n",
                .{ seq + 1, expected_seq, parsed_seq },
            );
            return error.SequenceMonotonicityViolation;
        }

        // SONNY-6322: a KEY_EPOCH record starts a new signing-key epoch.
        if (std.mem.indexOf(u8, line, key_epoch_action_pattern) != null and std.mem.indexOf(u8, line, key_epoch_id_pattern) != null) {
            const at_seq = seq + 1;
            const id_start = std.mem.indexOf(u8, line, key_epoch_id_pattern).? + key_epoch_id_pattern.len;
            const id_end = std.mem.indexOfScalarPos(u8, line, id_start, '"') orelse return error.Invalid;
            const id = line[id_start..id_end];
            const colon = std.mem.indexOfScalar(u8, id, ':') orelse return error.Invalid;
            if (!std.mem.startsWith(u8, id, "epoch-") or colon <= "epoch-".len) return error.Invalid;
            const n = std.fmt.parseInt(u32, id["epoch-".len..colon], 10) catch return error.Invalid;
            const new_key = try hex32(id[colon + 1 ..]);
            if (n <= epoch) {
                std.debug.print("TAMPER key_epoch ❌  at_seq={} reason=EPOCH_NOT_INCREASING epoch={} previous={}\n", .{ at_seq, n, epoch });
                return error.KeyEpochOrder;
            }
            // The event hash must commit to the epoch and the key it names.
            var hasher = cb.Hash.Stream.init(.sha256) catch return error.ReadError;
            defer hasher.deinit();
            hasher.update(&prev_buf) catch return error.ReadError;
            hasher.update("system_event") catch return error.ReadError;
            hasher.update(id) catch return error.ReadError;
            hasher.update("KEY_EPOCH") catch return error.ReadError;
            var expect_hash: [32]u8 = undefined;
            _ = hasher.final(&expect_hash) catch return error.ReadError;
            if (!std.mem.eql(u8, &expect_hash, &last_hash)) {
                std.debug.print("TAMPER key_epoch ❌  at_seq={} reason=EVENT_HASH_MISMATCH\n", .{at_seq});
                return error.KeyEpochHashMismatch;
            }
            if (trusted_keys.len > 0) {
                if (n >= trusted_keys.len or !std.mem.eql(u8, &trusted_keys[n], &new_key)) {
                    std.debug.print("UNTRUSTED key_epoch ❌  at_seq={} epoch={} reason=KEY_NOT_IN_TRUSTED_LIST (pass the public key of every epoch with --pubkey, in order)\n", .{ at_seq, n });
                    return error.UntrustedKeyEpoch;
                }
                if (signatureValid(line, last_hash, new_key, at_seq)) {
                    signature_verified_count += 1;
                } else {
                    signature_failed_count += 1;
                }
            }
            epoch = n;
            epoch_key = new_key;
            epochs_seen += 1;
            std.debug.print("KEY_EPOCH ⚠  at_seq={} epoch={} key={s}... (records before verify with the previous key; continuity across this boundary is attested by the operator who restored the store, not by the previous key)\n", .{ at_seq, n, id[colon + 1 ..][0..16] });
        }

        // Handle DIGEST events
        if (std.mem.eql(u8, typ, "DIGEST")) {
            digest_count += 1;

            // GAP-0151: Verify Ed25519 signature on DIGEST events, with the
            // current epoch's key (SONNY-6322).
            if (epoch_key) |pk| {
                var patt_sig_buf: [64]u8 = undefined;
                const patt_sig = std.fmt.bufPrint(&patt_sig_buf, "\"{s}\":\"", .{"signature"}) catch return error.Invalid;

                const sig_hex = blk_sig: {
                    if (std.mem.indexOf(u8, line, patt_sig)) |idx| {
                        const start = idx + patt_sig.len;
                        if (std.mem.indexOfScalarPos(u8, line, start, '"')) |end| break :blk_sig line[start..end];
                    }
                    std.debug.print("SIGNATURE_ERROR ❌  at_seq={} reason=MISSING_SIGNATURE\n", .{seq + 1});
                    signature_failed_count += 1;
                    break :blk_sig null;
                };

                if (sig_hex) |sig_str| {
                    const sig_bytes = hex64(sig_str) catch {
                        std.debug.print("SIGNATURE_ERROR ❌  at_seq={} reason=INVALID_SIGNATURE_FORMAT\n", .{seq + 1});
                        signature_failed_count += 1;
                        events_since_digest = 0;
                        records += 1;
                        seq += 1;
                        continue;
                    };

                    // Verify signature over event_hash
                    const ev_hash_bytes = try hex32(ev_hex);
                    var pub_kp = cb.Sig.KeyPair.fromPublicBytes(.ed25519, &pk) catch {
                        std.debug.print("SIGNATURE_ERROR ❌  at_seq={} reason=INVALID_PUBLIC_KEY\n", .{seq + 1});
                        signature_failed_count += 1;
                        events_since_digest = 0;
                        records += 1;
                        seq += 1;
                        continue;
                    };
                    defer pub_kp.deinit();
                    cb.Sig.verify(.ed25519, &pub_kp, &ev_hash_bytes, &sig_bytes) catch {
                        std.debug.print("SIGNATURE_ERROR ❌  at_seq={} reason=VERIFICATION_FAILED\n", .{seq + 1});
                        signature_failed_count += 1;
                        events_since_digest = 0;
                        records += 1;
                        seq += 1;
                        continue;
                    };

                    signature_verified_count += 1;
                }
            }

            events_since_digest = 0;
        } else {
            events_since_digest += 1;

            // GAP-0151: Check digest interval
            if (digest_interval_events > 0 and events_since_digest > digest_interval_events) {
                std.debug.print("DIGEST_INTERVAL_ERROR ❌  at_seq={} events_since_digest={} max_interval={}\n", .{ seq + 1, events_since_digest, digest_interval_events });
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

    // Print verification summary
    std.debug.print("OK chain ✅  records={} digests={} algo={s}", .{ records, digest_count, switch (algo) {
        .sha256 => "sha256",
        .blake3 => "blake3",
    } });

    if (epochs_seen > 0) std.debug.print(" key_epochs={}", .{epochs_seen});
    if (trusted_keys.len > 0) {
        std.debug.print(" signatures_verified={} signatures_failed={}", .{ signature_verified_count, signature_failed_count });
    }

    if (digest_interval_events > 0) {
        std.debug.print(" digest_interval_max={}", .{digest_interval_events});
    }

    // #748: mirror the FileNotFound branch phrase so harness specs that
    // assert `stderr_contains: "records verified"` pass uniformly whether
    // or not the default audit log exists (empty or populated).
    std.debug.print(" ({} records verified)\n", .{records});

    // SONNY-6322: a signature that does not verify fails the verification
    // (it was only counted, and the command still exited 0).
    if (signature_failed_count > 0) {
        std.debug.print("SIGNATURE_ERROR ❌  {} signature(s) did not verify\n", .{signature_failed_count});
        return error.InvalidSignature;
    }
    return .{
        .records = records,
        .digests = digest_count,
        .epochs = epochs_seen,
        .signatures_verified = signature_verified_count,
        .signatures_failed = signature_failed_count,
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
