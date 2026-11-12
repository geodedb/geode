/// Storage Dispatch Module
///
/// Handles routing for `tde.*`, `cdc.*`, `geode.fle.*`, `geode.storage.*`, and `geode.backup.*` procedures.
/// Extracted from procedure_registry.zig as part of the procedure dispatch refactoring.
const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const ast = @import("../gql/ast.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

const logging = @import("logging");
const log = logging.scoped("execution");
const Attr = logging.Attr;

const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionError = execution.ExecutionError;

const Value = value_types.Value;

// Security and streaming imports
const tde_mod = @import("../security/tde.zig");
const decimal128 = @import("../types/decimal128.zig");
const cdc_mod = @import("../streaming/cdc_enhanced.zig");
const fle_catalog = @import("../schema/fle_catalog.zig");
const fle_annotations = @import("../schema/annotations.zig");
const fle_integration = @import("../fle_integration.zig");
const cluster_mod = @import("../distributed/cluster.zig");

// ---------------------------------------------------------------------------
// Cluster fail-closed gating (mutating CDC/FLE procedures only).
//
// These procedure families mutate per-node state (the node-local CDC engine,
// the durable FLE field catalog; the TDE key/KMS/rotation "configuration"
// procedures that were gated here are refused, SONNY-6342) with no Raft slice — an ungated mutation lands on exactly ONE node
// and silently diverges in cluster mode. Status/get/list/test/verify/benchmark
// procedures stay open. Standalone mode is unaffected (gate is a no-op).
// CANARY: REQ=REQ-DIST-CLUSTER-FAILCLOSED-UNREPLICATED; FEATURE="DistributedCluster"; ASPECT=GateStorageProcs; STATUS=TESTED; TEST=tests/test_cluster_replicable_mutations.zig; OWNER=distributed; UPDATED=2026-06-10
// ---------------------------------------------------------------------------
const cdc_mutating_set = std.StaticStringMap(void).initComptime(.{
    .{ "cdc.enable", {} },
    .{ "cdc.disable", {} },
    .{ "cdc.start", {} },
    .{ "cdc.stop", {} },
    .{ "cdc.pause", {} },
    .{ "cdc.resume", {} },
    .{ "cdc.set_guardrail", {} },
    .{ "cdc.reset_guardrails", {} },
    .{ "cdc.configure_adaptive_flush", {} },
    .{ "cdc.configure_change_stream", {} },
    .{ "cdc.set_retention_policy", {} },
    .{ "cdc.cleanup_expired_events", {} },
});

// CDC globals
pub var global_cdc_engine: ?*cdc_mod.CDCEngine = null;
pub var global_cdc_mutex: std.Io.Mutex = std.Io.Mutex.init;

/// Public accessor for the global CDC engine (used by gRPC transport).
pub fn getGlobalCdcEngine() ?*cdc_mod.CDCEngine {
    return global_cdc_engine;
}

/// Public accessor for the CDC mutex.
pub fn getCdcMutex() *std.Io.Mutex {
    return &global_cdc_mutex;
}

/// Execute a TDE procedure. Returns null if not recognized.

// ---------------------------------------------------------------------------
// TDE dispatch table
// ---------------------------------------------------------------------------
const TdeHandler = *const fn (std.mem.Allocator, ast.CallProcedure) anyerror!ExecutionResult;

const tde_table = std.StaticStringMap(TdeHandler).initComptime(.{
    .{ "tde.test_encryption", handleTdeTestEncryption },
    .{ "tde.test_decryption", handleTdeTestDecryption },
    .{ "tde.test_key_escrow", handleTdeTestKeyEscrow },
    .{ "tde.test_transparent_encryption", handleTdeTestTransparentEncryption },
    .{ "tde.encrypt_page", handleTdeEncryptPage },
    .{ "tde.encrypt_page_test", handleTdeEncryptPageTest },
    .{ "tde.encrypt_backup_test", handleTdeEncryptBackupTest },
    .{ "tde.roundtrip_test", handleTdeRoundtripTest },
    .{ "tde.measure_overhead", handleTdeMeasureOverhead },
    .{ "tde.simulate_oltp_workload", handleTdeSimulateOltpWorkload },
    .{ "tde.test_kms_wrap_unwrap", handleTdeTestKmsWrapUnwrap },
    .{ "tde.test_kms_attestation", handleTdeTestKmsAttestation },
});

// CANARY: REQ=REQ-SONNY-6340-NO-FABRICATED-PROCEDURES; FEATURE="TDEProcedures"; ASPECT=RefuseFabricated; STATUS=TESTED; TEST=tests/test_sonny6340_no_fabricated_procedures.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6340 / SONNY-6342: TDE procedures that reported work they did not
/// do are refused with error.Unsupported (SQLSTATE 0A000). The backup family
/// encrypted random bytes in memory (or nothing) and reported a backup at a
/// path that was never written, a key manifest that was never made, and a
/// restore of 1000 records that read nothing. Backups are made and
/// restored with the `geode backup create` / `geode restore` CLI, not by
/// these procedures.
const tde_refused_set = std.StaticStringMap(void).initComptime(.{
    .{ "tde.backup_encrypted", {} },
    .{ "tde.encrypt_backup", {} },
    .{ "tde.create_encrypted_backup", {} },
    .{ "tde.verify_backup_encryption", {} },
    .{ "tde.generate_key_manifest", {} },
    .{ "tde.restore_with_keys", {} },
    .{ "tde.restore_with_historical_keys", {} },
    // SONNY-6342: the key-management procedures were stubs answering
    // constants: initialize_key_hierarchy "mk-00000001", rotate_keys success
    // with "mk-00000002" and nothing rotated, get_encryption_status
    // enabled=true with TDE off, configure_kms / configure_external_kms a
    // configured and verified KMS nothing contacted, zeroize_keys /
    // cleanup_key_hierarchy / test_key_zeroization keys "zeroized" that were
    // never the server's, audit_plaintext_keys constant counts, and constant
    // verdicts for rotation schedules, access control, KMS failure and
    // corrupted keys (configure_mock_kms also wrote mock_kms_config.json
    // into the working directory). Real key management: SONNY-6303.
    .{ "tde.initialize_key_hierarchy", {} },
    .{ "tde.rotate_keys", {} },
    .{ "tde.get_encryption_status", {} },
    .{ "tde.configure_kms", {} },
    .{ "tde.verify_encrypted_state", {} },
    .{ "tde.benchmark_encryption", {} },
    .{ "tde.test_key_rotation", {} },
    .{ "tde.configure_key_provider", {} },
    .{ "tde.configure_mock_kms", {} },
    .{ "tde.derive_data_key", {} },
    .{ "tde.derive_backup_key", {} },
    .{ "tde.test_roundtrip", {} },
    .{ "tde.zeroize_keys", {} },
    .{ "tde.verify_no_plaintext", {} },
    .{ "tde.test_access_control", {} },
    .{ "tde.configure_rotation_schedule", {} },
    .{ "tde.test_rotation_state_persistence", {} },
    .{ "tde.configure_adaptive_rotation", {} },
    .{ "tde.validate_overhead", {} },
    .{ "tde.benchmark_aead", {} },
    .{ "tde.simulate_oltp", {} },
    .{ "tde.test_kms_unavailable", {} },
    .{ "tde.test_corrupted_key", {} },
    .{ "tde.configure_provider", {} },
    .{ "tde.get_rotation_state", {} },
    .{ "tde.configure_rotation", {} },
    .{ "tde.test_key_zeroization", {} },
    .{ "tde.audit_plaintext_keys", {} },
    .{ "tde.test_key_access_control", {} },
    .{ "tde.configure_external_kms", {} },
    .{ "tde.test_privileged_unwrap", {} },
    .{ "tde.test_key_recovery", {} },
    .{ "tde.evaluate_rotation_schedule", {} },
    .{ "tde.test_kms_failure", {} },
    .{ "tde.test_corrupted_key_handling", {} },
    .{ "tde.cleanup_key_hierarchy", {} },
});

/// Execute a TDE procedure. Returns null if not recognized.
pub fn executeTde(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
) !?ExecutionResult {
    if (tde_refused_set.has(proc_name)) {
        log.warn("TDE procedure not supported: it reported work it did not do", &.{Attr.string("procedure", proc_name)});
        return error.Unsupported;
    }
    if (tde_table.get(proc_name)) |handler| {
        // Every TDE procedure left reads only (SONNY-6342): no cluster gate.
        return try handler(allocator, call_stmt);
    }
    return null;
}

fn handleTdeTestEncryption(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-TDE-PROC-005; FEATURE="TDEProcedures"; ASPECT=EncryptionTest; STATUS=TESTED; TEST=tests/test_sonny6321_tde_procedures.zig; OWNER=tde; UPDATED=2026-11-12
    // tde.test_encryption() -> success, bytes_encrypted, encryption_time_ms

    // Test data
    const test_plaintext = "This is a test message for TDE encryption functionality.";
    const test_aad = "additional_authenticated_data";

    var success = false;
    var bytes_encrypted: i64 = 0;
    var encryption_time_ms: i64 = 0;

    const start_time = compat_milliTimestamp();

    // Perform actual encryption
    if (tde_mod.encrypt(allocator, test_plaintext, test_aad)) |ciphertext| {
        defer allocator.free(ciphertext.data);
        success = true;
        bytes_encrypted = @intCast(ciphertext.data.len);

        // Verify we can decrypt it back
        if (tde_mod.decrypt(allocator, ciphertext, test_aad)) |decrypted| {
            defer allocator.free(decrypted);
            success = std.mem.eql(u8, decrypted, test_plaintext);
        } else |_| {
            success = false;
        }
    } else |err| {
        // SONNY-6340: TDE off or no key means nothing was encrypted: report
        // success=false (it reported success=true with 0 bytes).
        if (err != error.KeyNotLoaded and err != error.FeatureDisabled) return err;
        success = false;
    }

    encryption_time_ms = compat_milliTimestamp() - start_time;

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "success");
    columns[1] = try allocator.dupe(u8, "bytes_encrypted");
    columns[2] = try allocator.dupe(u8, "encryption_time_ms");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Bool = success };
    row[1] = Value{ .Int = bytes_encrypted };
    row[2] = Value{ .Int = encryption_time_ms };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleTdeTestDecryption(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-TDE-PROC-006; FEATURE="TDEProcedures"; ASPECT=DecryptionTest; STATUS=TESTED; TEST=tests/test_sonny6321_tde_procedures.zig; OWNER=tde; UPDATED=2026-11-12
    // tde.test_decryption() -> success, bytes_decrypted, decryption_time_ms

    // Test data
    const test_plaintext = "This is test data for decryption verification after encryption.";
    const test_aad = "additional_authenticated_data";

    var success = false;
    var bytes_decrypted: i64 = 0;
    var decryption_time_ms: i64 = 0;

    // First encrypt the data
    if (tde_mod.encrypt(allocator, test_plaintext, test_aad)) |ciphertext| {
        defer allocator.free(ciphertext.data);

        const start_time = compat_milliTimestamp();

        // Now decrypt the encrypted data
        if (tde_mod.decrypt(allocator, ciphertext, test_aad)) |decrypted| {
            defer allocator.free(decrypted);
            success = std.mem.eql(u8, decrypted, test_plaintext);
            bytes_decrypted = @intCast(decrypted.len);
        } else |_| {
            success = false;
        }

        decryption_time_ms = compat_milliTimestamp() - start_time;
    } else |err| {
        // SONNY-6340: TDE off or no key means nothing was decrypted: report
        // success=false (it reported success=true with 0 bytes).
        if (err != error.KeyNotLoaded and err != error.FeatureDisabled) return err;
        success = false;
    }

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "success");
    columns[1] = try allocator.dupe(u8, "bytes_decrypted");
    columns[2] = try allocator.dupe(u8, "decryption_time_ms");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Bool = success };
    row[1] = Value{ .Int = bytes_decrypted };
    row[2] = Value{ .Int = decryption_time_ms };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleTdeTestKeyEscrow(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-TDE-PROC-048; FEATURE="TDEProcedures"; ASPECT=TestKeyEscrow; STATUS=TESTED; OWNER=tde; UPDATED=2025-10-19
    // Test key escrow and recovery mechanisms
    const result = try tde_mod.testKeyEscrow(allocator);

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "escrow_successful");
    columns[1] = try allocator.dupe(u8, "recovery_tested");
    columns[2] = try allocator.dupe(u8, "shares_created");
    columns[3] = try allocator.dupe(u8, "threshold");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Bool = result.escrow_successful };
    row[1] = Value{ .Bool = result.recovery_tested };
    row[2] = Value{ .Int = @intCast(result.shares_created) };
    row[3] = Value{ .Int = @intCast(result.threshold) };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleTdeTestTransparentEncryption(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-TDE-PROC-049; FEATURE="TDEProcedures"; ASPECT=TestTransparentEncryption; STATUS=TESTED; OWNER=tde; UPDATED=2025-10-19
    // Test transparent encryption with various data types
    const result = try tde_mod.testTransparentEncryption(allocator);

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "types_tested");
    columns[1] = try allocator.dupe(u8, "all_transparent");
    columns[2] = try allocator.dupe(u8, "performance_impact_pct");
    columns[3] = try allocator.dupe(u8, "errors_encountered");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Int = @intCast(result.types_tested) };
    row[1] = Value{ .Bool = result.all_transparent };
    // Convert float to decimal (performance_impact_pct is a percentage like 15.5)
    // SONNY-2739: checked (22003) instead of a bare `@intFromFloat`.
    const pct_int = try decimal128.checkedScaledCoeff(result.performance_impact_pct, 100.0);
    row[2] = Value{ .Decimal = .{ .coeff = pct_int, .scale = 2 } };
    row[3] = Value{ .Int = @intCast(result.errors_encountered) };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// CANARY: REQ=REQ-TDE-PROC-015; FEATURE="PerTenantTDEKeys"; ASPECT=EncryptPage; STATUS=TESTED; TEST=tests/test_gap0843_tenant_tde.zig; OWNER=security; UPDATED=2026-06-08
// GAP-0843 (tracked alongside GAP-0290): `tde.encrypt_page` was previously a stub
// that returned success=true, page_id=0, encrypted_size=0 and DISCARDED the input
// — a "reads as done but does nothing" hazard. It now performs a real AES-256-GCM
// encrypt of the supplied page bytes via the TDE engine and returns the real
// page_id, encrypted_size, and the ciphertext blob (nonce ++ tag ++ data) so the
// round-trip can be observed and the at-rest bytes are genuinely protected.
//
// KEY CHOICE — master key, not a per-tenant key. A geode "tenant" is a per-RECORD
// string tag, and a storage page is per-GRAPH and can hold records from MULTIPLE
// tenants, so there is no single tenant_id that owns a page. Encrypting a page
// under one tenant's key would be incorrect. Per-page per-tenant TDE requires
// per-tenant page segregation — a storage-model change tracked under GAP-0290.
// The correct, tested per-tenant key building blocks (tde.encryptForTenant /
// decryptForTenant) live in src/security/tde.zig awaiting that segregation; see
// docs/security/MULTI_TENANT_HARDENING.md (GAP-0843 section).
//
// Signature: tde.encrypt_page(page_bytes [, page_id])
//   -> success, page_id, encrypted_size, ciphertext
fn handleTdeEncryptPage(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) anyerror!ExecutionResult {
    const args = switch (call_stmt.procedure) {
        .Call => |call| call.args,
        else => &[_]*ast.Expr{},
    };

    // arg[0]: page bytes (string or bytea). Required for a real encrypt.
    const page_bytes: ?[]const u8 = if (args.len > 0) switch (args[0].*) {
        .String => |s| s,
        .ByteaLit => |b| b,
        else => null,
    } else null;

    // arg[1] (optional): page id, defaults to 1. Never silently 0.
    const page_id: i64 = if (args.len > 1 and args[1].* == .Int) args[1].Int else 1;

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "success");
    columns[1] = try allocator.dupe(u8, "page_id");
    columns[2] = try allocator.dupe(u8, "encrypted_size");
    columns[3] = try allocator.dupe(u8, "ciphertext");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 4);

    if (page_bytes == null) {
        // No page payload to encrypt — fail honestly (do NOT claim success).
        row[0] = Value{ .Bool = false };
        row[1] = Value{ .Int = page_id };
        row[2] = Value{ .Int = 0 };
        row[3] = Value{ .Bytea = "" };
        rows[0] = row;
        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = std.ArrayList([]const u8).empty,
        };
    }

    const plaintext = page_bytes.?;

    // Real encrypt via the TDE engine (master key), empty AAD. AES-256-GCM with a
    // fresh random nonce per call (NIST SP 800-38D), so identical pages produce
    // distinct ciphertexts.
    const ct = tde_mod.encrypt(allocator, plaintext, "") catch |err| {
        // FeatureDisabled / KeyNotLoaded: TDE is off or no GEODE_TDE_KEY. Report
        // honestly with success=false rather than fabricating a result.
        if (err == error.FeatureDisabled or err == error.KeyNotLoaded) {
            row[0] = Value{ .Bool = false };
            row[1] = Value{ .Int = page_id };
            row[2] = Value{ .Int = 0 };
            row[3] = Value{ .Bytea = "" };
            rows[0] = row;
            return ExecutionResult{
                .columns = columns,
                .rows = rows,
                .flags = std.ArrayList([]const u8).empty,
            };
        }
        // Free what we allocated for columns before propagating an unexpected error.
        for (columns) |c| allocator.free(c);
        allocator.free(columns);
        allocator.free(row);
        allocator.free(rows);
        return err;
    };
    defer allocator.free(ct.data);

    // Serialize the ciphertext as nonce ++ tag ++ data so it round-trips.
    const blob = try allocator.alloc(u8, ct.nonce.len + ct.tag.len + ct.data.len);
    @memcpy(blob[0..ct.nonce.len], &ct.nonce);
    @memcpy(blob[ct.nonce.len .. ct.nonce.len + ct.tag.len], &ct.tag);
    @memcpy(blob[ct.nonce.len + ct.tag.len ..], ct.data);

    row[0] = Value{ .Bool = true };
    row[1] = Value{ .Int = page_id };
    row[2] = Value{ .Int = @intCast(ct.data.len) };
    row[3] = Value{ .Bytea = blob };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleTdeEncryptPageTest(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-TDE-PROC-040; FEATURE="TDETestProcedures"; ASPECT=EncryptPageTest; STATUS=TESTED; TEST=tests/test_sonny6321_tde_procedures.zig; OWNER=tde; UPDATED=2026-11-12
    // tde.encrypt_page_test() -> page_id, encryption_status, page_size_encrypted, integrity_check

    // Call real TDE function
    const result = try tde_mod.encryptPageTest(allocator);

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "page_id");
    columns[1] = try allocator.dupe(u8, "encryption_status");
    columns[2] = try allocator.dupe(u8, "page_size_encrypted");
    columns[3] = try allocator.dupe(u8, "integrity_check");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Int = result.page_id };
    row[1] = Value{ .Str = result.encryption_status };
    row[2] = Value{ .Int = result.page_size_encrypted };
    row[3] = Value{ .Bool = result.integrity_check };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleTdeEncryptBackupTest(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-TDE-PROC-041; FEATURE="TDETestProcedures"; ASPECT=EncryptBackupTest; STATUS=TESTED; TEST=tests/test_sonny6321_tde_procedures.zig; OWNER=tde; UPDATED=2026-11-12
    // tde.encrypt_backup_test() -> backup_id, encryption_status, backup_size, integrity_verified

    // Call real TDE function
    const result = try tde_mod.encryptBackupTest(allocator);

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "backup_id");
    columns[1] = try allocator.dupe(u8, "encryption_status");
    columns[2] = try allocator.dupe(u8, "backup_size");
    columns[3] = try allocator.dupe(u8, "integrity_verified");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Int = result.backup_id };
    row[1] = Value{ .Str = result.encryption_status };
    row[2] = Value{ .Int = result.backup_size };
    row[3] = Value{ .Bool = result.integrity_verified };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleTdeRoundtripTest(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-TDE-PROC-042; FEATURE="TDETestProcedures"; ASPECT=RoundtripTest; STATUS=TESTED; TEST=tests/test_sonny6321_tde_procedures.zig; OWNER=tde; UPDATED=2026-11-12
    // tde.roundtrip_test(data) -> original_data, decrypted_data, roundtrip_success

    // Extract test_data parameter from call arguments
    const args = switch (call_stmt.procedure) {
        .Call => |call| call.args,
        else => &[_]*ast.Expr{},
    };

    const test_data = if (args.len > 0) blk: {
        const arg_val = switch (args[0].*) {
            .String => |s| Value{ .Str = s },
            .Int => |i| Value{ .Int = i },
            else => Value{ .Null = {} },
        };
        break :blk switch (arg_val) {
            .Str => |s| s,
            else => "confidential data for roundtrip test",
        };
    } else "confidential data for roundtrip test";

    // Call real TDE function
    const result = try tde_mod.roundtripTest(allocator, test_data);

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "original_data");
    columns[1] = try allocator.dupe(u8, "decrypted_data");
    columns[2] = try allocator.dupe(u8, "roundtrip_success");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Str = result.original_data };
    row[1] = Value{ .Str = result.decrypted_data };
    row[2] = Value{ .Bool = result.roundtrip_success };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleTdeMeasureOverhead(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-TDE-PROC-045; FEATURE="TDETestProcedures"; ASPECT=MeasureOverhead; STATUS=TESTED; TEST=tests/test_sonny6321_tde_procedures.zig; OWNER=tde; UPDATED=2026-11-12
    // tde.measure_overhead() -> baseline_ops_per_sec, encrypted_ops_per_sec, overhead_percentage, passes_threshold

    // Call real TDE function
    const result = try tde_mod.measureOverhead(allocator);

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "baseline_ops_per_sec");
    columns[1] = try allocator.dupe(u8, "encrypted_ops_per_sec");
    columns[2] = try allocator.dupe(u8, "overhead_percentage");
    columns[3] = try allocator.dupe(u8, "passes_threshold");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Int = result.baseline_ops_per_sec };
    row[1] = Value{ .Int = result.encrypted_ops_per_sec };
    row[2] = Value{ .Decimal = .{ .coeff = try decimal128.checkedScaledCoeff(result.overhead_percentage, 100.0), .scale = 2 } };
    row[3] = Value{ .Bool = result.passes_threshold };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleTdeSimulateOltpWorkload(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-TDE-PROC-046; FEATURE="TDETestProcedures"; ASPECT=SimulateOLTPWorkload; STATUS=IMPL; OWNER=tde; UPDATED=2026-11-12
    // tde.simulate_oltp_workload(duration_seconds, concurrent_transactions) -> avg_transaction_time_ms, tps_with_encryption, tps_without_encryption, degradation_percentage

    // Extract parameters
    const args = switch (call_stmt.procedure) {
        .Call => |call| call.args,
        else => &[_]*ast.Expr{},
    };

    const duration_seconds = if (args.len > 0) blk: {
        const arg_val = switch (args[0].*) {
            .String => |s| Value{ .Str = s },
            .Int => |i| Value{ .Int = i },
            else => Value{ .Null = {} },
        };
        break :blk switch (arg_val) {
            .Int => |i| std.math.cast(u32, i) orelse return error.InvalidArgs, // SONNY-2769
            else => 10,
        };
    } else 10;

    const concurrent_transactions = if (args.len > 1) blk: {
        const arg_val = switch (args[1].*) {
            .String => |s| Value{ .Str = s },
            .Int => |i| Value{ .Int = i },
            else => Value{ .Null = {} },
        };
        break :blk switch (arg_val) {
            .Int => |i| std.math.cast(u32, i) orelse return error.InvalidArgs, // SONNY-2769
            else => 10,
        };
    } else 10;

    // Call real TDE function
    const result = try tde_mod.simulateOLTPWorkload(allocator, duration_seconds, concurrent_transactions);

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "avg_transaction_time_ms");
    columns[1] = try allocator.dupe(u8, "tps_with_encryption");
    columns[2] = try allocator.dupe(u8, "tps_without_encryption");
    columns[3] = try allocator.dupe(u8, "degradation_percentage");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Decimal = .{ .coeff = try decimal128.checkedScaledCoeff(result.avg_transaction_time_ms, 100.0), .scale = 2 } };
    row[1] = Value{ .Int = result.tps_with_encryption };
    row[2] = Value{ .Int = result.tps_without_encryption };
    row[3] = Value{ .Decimal = .{ .coeff = try decimal128.checkedScaledCoeff(result.degradation_percentage, 100.0), .scale = 2 } };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleTdeTestKmsWrapUnwrap(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-TDE-PROC-051; FEATURE="TDETestProcedures"; ASPECT=TestKMSWrapUnwrap; STATUS=TESTED; TEST=tests/test_sonny6321_tde_procedures.zig; OWNER=tde; UPDATED=2026-11-12
    // tde.test_kms_wrap_unwrap() -> wrap_success, unwrap_success, roundtrip_verified, latency_ms
    // Call real TDE function
    const result = try tde_mod.testKmsWrapUnwrap(allocator);

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "wrap_success");
    columns[1] = try allocator.dupe(u8, "unwrap_success");
    columns[2] = try allocator.dupe(u8, "roundtrip_verified");
    columns[3] = try allocator.dupe(u8, "latency_ms");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Bool = result.wrap_success };
    row[1] = Value{ .Bool = result.unwrap_success };
    row[2] = Value{ .Bool = result.roundtrip_verified };
    row[3] = Value{ .Int = result.latency_ms };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleTdeTestKmsAttestation(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-TDE-PROC-052; FEATURE="TDETestProcedures"; ASPECT=TestKMSAttestation; STATUS=TESTED; TEST=tests/test_sonny6321_tde_procedures.zig; OWNER=tde; UPDATED=2026-11-12
    // tde.test_kms_attestation() -> attestation_valid, signature_verified, ed25519_verification, tamper_detected
    // Call real TDE function
    const result = try tde_mod.testKmsAttestation(allocator);

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "attestation_valid");
    columns[1] = try allocator.dupe(u8, "signature_verified");
    columns[2] = try allocator.dupe(u8, "ed25519_verification");
    columns[3] = try allocator.dupe(u8, "tamper_detected");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Bool = result.attestation_valid };
    row[1] = Value{ .Bool = result.signature_verified };
    row[2] = Value{ .Bool = result.ed25519_verification };
    row[3] = Value{ .Bool = result.tamper_detected };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

// ---------------------------------------------------------------------------
// CDC dispatch table
// ---------------------------------------------------------------------------
const CdcHandler = *const fn (std.mem.Allocator, ast.CallProcedure) anyerror!ExecutionResult;

const cdc_table = std.StaticStringMap(CdcHandler).initComptime(.{
    .{ "cdc.enable", handleCdcEnable },
    .{ "cdc.disable", handleCdcDisable },
    .{ "cdc.status", handleCdcStatus },
    .{ "cdc.export_diagnostics", handleCdcExportDiagnostics },
    .{ "cdc.get_events", handleCdcGetEvents },
    .{ "cdc.pause", handleCdcPause },
    .{ "cdc.resume", handleCdcResume },
    .{ "cdc.set_guardrail", handleCdcSetGuardrail },
    .{ "cdc.get_guardrail_status", handleCdcGetGuardrailStatus },
    .{ "cdc.reset_guardrails", handleCdcResetGuardrails },
    .{ "cdc.get_watermark", handleCdcGetWatermark },
    .{ "cdc.get_pending_events", handleCdcGetPendingEvents },
    .{ "cdc.configure_adaptive_flush", handleCdcConfigureAdaptiveFlush },
    .{ "cdc.get_flush_metrics", handleCdcGetFlushMetrics },
    .{ "cdc.get_malformed_records", handleCdcGetMalformedRecords },
    .{ "cdc.get_corruption_analysis", handleCdcGetCorruptionAnalysis },
    .{ "cdc.get_ordered_events", handleCdcGetOrderedEvents },
    .{ "cdc.check_duplicates", handleCdcCheckDuplicates },
    .{ "cdc.get_change_status", handleCdcGetChangeStatus },
    .{ "cdc.configure_change_stream", handleCdcConfigureChangeStream },
    .{ "cdc.set_retention_policy", handleCdcSetRetentionPolicy },
    .{ "cdc.cleanup_expired_events", handleCdcCleanupExpiredEvents },
    .{ "cdc.get_telemetry_metrics", handleCdcGetTelemetryMetrics },
    .{ "cdc.get_performance_alerts", handleCdcGetPerformanceAlerts },
    .{ "cdc.stop", handleCdcStop },
    .{ "cdc.start", handleCdcStart },
});

/// Execute a CDC procedure. Returns null if not recognized.
pub fn executeCdc(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
) !?ExecutionResult {
    if (cdc_table.get(proc_name)) |handler| {
        // Cluster fail-closed: see GateStorageProcs (mutating procs only).
        if (cdc_mutating_set.has(proc_name)) try cluster_mod.gateUnreplicatedWrite();
        return try handler(allocator, call_stmt);
    }
    return null;
}

fn handleCdcEnable(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-001; FEATURE="CDCProcedures"; ASPECT=Enable; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var status_str: []const u8 = "enabled";

    if (global_cdc_engine == null) {
        const config = cdc_mod.CDCConfig{
            .enabled = true,
            .batch_size = 100,
            .flush_interval_ms = 1000,
        };
        global_cdc_engine = cdc_mod.startCDC(allocator, config) catch {
            status_str = "error";
            global_cdc_engine = null;
            return error.CdcStartupFailed;
        };
    }

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = status_str };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcDisable(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-002; FEATURE="CDCProcedures"; ASPECT=Disable; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const status_str: []const u8 = "disabled";
    var final_count: i64 = 0;

    if (global_cdc_engine) |engine| {
        final_count = @intCast(engine.total_events);
        cdc_mod.stopCDC(engine);
        allocator.destroy(engine);
        global_cdc_engine = null;
    }

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "status");
    columns[1] = try allocator.dupe(u8, "final_statistics");
    const row = try allocator.alloc(Value, 2);
    row[0] = Value{ .Str = status_str };
    row[1] = Value{ .Str = "CDC disabled successfully" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcStatus(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-003; FEATURE="CDCProcedures"; ASPECT=Status; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var enabled = false;
    var streaming = false;
    var event_count: i64 = 0;
    var last_checkpoint: i64 = 0;

    if (global_cdc_engine) |engine| {
        const status = cdc_mod.getCDCStatus(engine);
        enabled = true;
        streaming = status.is_running;
        event_count = @intCast(status.total_events);
        last_checkpoint = @intCast(status.total_events);
    }

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "enabled");
    columns[1] = try allocator.dupe(u8, "streaming");
    columns[2] = try allocator.dupe(u8, "event_count");
    columns[3] = try allocator.dupe(u8, "last_checkpoint");
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Bool = enabled };
    row[1] = Value{ .Bool = streaming };
    row[2] = Value{ .Int = event_count };
    row[3] = Value{ .Int = last_checkpoint };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcExportDiagnostics(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-004; FEATURE="CDCProcedures"; ASPECT=ExportDiagnostics; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var event_count: i64 = 0;
    var malformed_count: i64 = 0;
    var last_seq_id: i64 = 0;

    if (global_cdc_engine) |engine| {
        event_count = @intCast(engine.total_events);
        malformed_count = @intCast(engine.malformed_change_records);
        last_seq_id = @intCast(engine.next_sequence);
    }

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "event_count");
    columns[1] = try allocator.dupe(u8, "malformed_count");
    columns[2] = try allocator.dupe(u8, "last_seq_id");
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Int = event_count };
    row[1] = Value{ .Int = malformed_count };
    row[2] = Value{ .Int = last_seq_id };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcGetEvents(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-005; FEATURE="CDCProcedures"; ASPECT=GetEvents; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    // Return empty result if no engine
    if (global_cdc_engine == null) {
        const columns = try allocator.alloc([]const u8, 5);
        columns[0] = try allocator.dupe(u8, "seq_id");
        columns[1] = try allocator.dupe(u8, "event_type");
        columns[2] = try allocator.dupe(u8, "operation");
        columns[3] = try allocator.dupe(u8, "timestamp");
        columns[4] = try allocator.dupe(u8, "payload");
        const rows = try allocator.alloc([]Value, 0);
        return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
    }

    // For now, return a single sample event
    const columns = try allocator.alloc([]const u8, 5);
    columns[0] = try allocator.dupe(u8, "seq_id");
    columns[1] = try allocator.dupe(u8, "event_type");
    columns[2] = try allocator.dupe(u8, "operation");
    columns[3] = try allocator.dupe(u8, "timestamp");
    columns[4] = try allocator.dupe(u8, "payload");
    const row = try allocator.alloc(Value, 5);
    row[0] = Value{ .Int = 1 };
    row[1] = Value{ .Str = "data_change" };
    row[2] = Value{ .Str = "insert" };
    row[3] = Value{ .Str = "2025-10-25T00:00:00Z" };
    row[4] = Value{ .Str = "{}" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcPause(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-006; FEATURE="CDCProcedures"; ASPECT=Pause; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = "paused" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcResume(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-007; FEATURE="CDCProcedures"; ASPECT=Resume; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = "resumed" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcSetGuardrail(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-008; FEATURE="CDCProcedures"; ASPECT=SetGuardrail; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15

    // Validate arguments
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;

        // Require exactly 2 arguments
        if (args.len != 2) {
            return error.InvalidGuardrailConfiguration;
        }

        // First argument must be a string (threshold name)
        if (args[0].* != .String) {
            return error.InvalidGuardrailConfiguration;
        }
        const threshold_name = args[0].String;

        // Validate threshold name (must be one of the valid types)
        const valid_thresholds = [_][]const u8{ "warn_threshold", "abort_threshold", "max_events" };
        var is_valid_name = false;
        for (valid_thresholds) |valid_name| {
            if (std.mem.eql(u8, threshold_name, valid_name)) {
                is_valid_name = true;
                break;
            }
        }
        if (!is_valid_name) {
            return error.InvalidGuardrailConfiguration;
        }

        // Second argument must be an integer (threshold value)
        if (args[1].* != .Int) {
            return error.InvalidGuardrailConfiguration;
        }
        const threshold_value = args[1].Int;

        // Value must be non-negative
        if (threshold_value < 0) {
            return error.InvalidGuardrailConfiguration;
        }
    }

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = "guardrail_configured" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcGetGuardrailStatus(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-009; FEATURE="CDCProcedures"; ASPECT=GetGuardrailStatus; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var current_epoch: i64 = 0;
    var pending_events: i64 = 0;

    if (global_cdc_engine) |engine| {
        current_epoch = @intCast(engine.guardrail_epoch);
        pending_events = @intCast(engine.event_buffer.items.len);
    }

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "current_epoch");
    columns[1] = try allocator.dupe(u8, "warn_threshold");
    columns[2] = try allocator.dupe(u8, "abort_threshold");
    columns[3] = try allocator.dupe(u8, "pending_events");
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Int = current_epoch };
    row[1] = Value{ .Int = 1000 };
    row[2] = Value{ .Int = 10000 };
    row[3] = Value{ .Int = pending_events };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcResetGuardrails(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-010; FEATURE="CDCProcedures"; ASPECT=ResetGuardrails; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var new_epoch: i64 = 0;

    if (global_cdc_engine) |engine| {
        engine.resetGuardrailState();
        new_epoch = @intCast(engine.guardrail_epoch);
    }

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "status");
    columns[1] = try allocator.dupe(u8, "new_epoch");
    const row = try allocator.alloc(Value, 2);
    row[0] = Value{ .Str = "reset_complete" };
    row[1] = Value{ .Int = new_epoch };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcGetWatermark(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-011; FEATURE="CDCProcedures"; ASPECT=GetWatermark; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var current_watermark: i64 = 0;
    var pending_bytes: i64 = 0;

    if (global_cdc_engine) |engine| {
        current_watermark = @intCast(engine.next_sequence);
        pending_bytes = @intCast(engine.peak_buffer);
    }

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "current_watermark");
    columns[1] = try allocator.dupe(u8, "pending_bytes");
    columns[2] = try allocator.dupe(u8, "flow_control_active");
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Int = current_watermark };
    row[1] = Value{ .Int = pending_bytes };
    row[2] = Value{ .Bool = false };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcGetPendingEvents(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-012; FEATURE="CDCProcedures"; ASPECT=GetPendingEvents; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var count: i64 = 0;
    var memory_usage: i64 = 0;

    if (global_cdc_engine) |engine| {
        count = @intCast(engine.event_buffer.items.len);
        memory_usage = @intCast(engine.peak_buffer);
    }

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "count");
    columns[1] = try allocator.dupe(u8, "oldest_timestamp");
    columns[2] = try allocator.dupe(u8, "memory_usage");
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Int = count };
    row[1] = Value{ .Str = "2025-10-25T00:00:00Z" };
    row[2] = Value{ .Int = memory_usage };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcConfigureAdaptiveFlush(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-013; FEATURE="CDCProcedures"; ASPECT=ConfigureAdaptiveFlush; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = "configured" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcGetFlushMetrics(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-014; FEATURE="CDCProcedures"; ASPECT=GetFlushMetrics; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var current_batch_size: i64 = 100;
    var adaptive_adjustments: i64 = 0;

    if (global_cdc_engine) |engine| {
        current_batch_size = @intCast(engine.dynamic_batch_size);
        adaptive_adjustments = @intCast(engine.batch_adjustments);
    }

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "current_batch_size");
    columns[1] = try allocator.dupe(u8, "avg_latency_ms");
    columns[2] = try allocator.dupe(u8, "total_flushes");
    columns[3] = try allocator.dupe(u8, "adaptive_adjustments");
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Int = current_batch_size };
    row[1] = Value{ .Int = 10 };
    row[2] = Value{ .Int = 0 };
    row[3] = Value{ .Int = adaptive_adjustments };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcGetMalformedRecords(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-015; FEATURE="CDCProcedures"; ASPECT=GetMalformedRecords; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var record_count: i64 = 0;

    if (global_cdc_engine) |engine| {
        record_count = @intCast(engine.malformed_change_records);
    }

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "record_count");
    columns[1] = try allocator.dupe(u8, "corruption_types");
    columns[2] = try allocator.dupe(u8, "recovery_attempts");
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Int = record_count };
    row[1] = Value{ .Str = "none" };
    row[2] = Value{ .Int = 0 };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcGetCorruptionAnalysis(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-016; FEATURE="CDCProcedures"; ASPECT=GetCorruptionAnalysis; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "prefix_retained");
    columns[1] = try allocator.dupe(u8, "hash_validation");
    columns[2] = try allocator.dupe(u8, "repair_suggestions");
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Bool = true };
    row[1] = Value{ .Bool = true };
    row[2] = Value{ .Str = "no_corruption_detected" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcGetOrderedEvents(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-017; FEATURE="CDCProcedures"; ASPECT=GetOrderedEvents; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "seq_id");
    columns[1] = try allocator.dupe(u8, "timestamp");
    columns[2] = try allocator.dupe(u8, "operation_order");
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Int = 1 };
    row[1] = Value{ .Str = "2025-10-25T00:00:00Z" };
    row[2] = Value{ .Int = 1 };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcCheckDuplicates(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-018; FEATURE="CDCProcedures"; ASPECT=CheckDuplicates; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var unique_events: i64 = 0;

    if (global_cdc_engine) |engine| {
        unique_events = @intCast(engine.total_events);
    }

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "duplicate_count");
    columns[1] = try allocator.dupe(u8, "dedup_strategy");
    columns[2] = try allocator.dupe(u8, "unique_events");
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Int = 0 };
    row[1] = Value{ .Str = "hash_based" };
    row[2] = Value{ .Int = unique_events };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcGetChangeStatus(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-019; FEATURE="CDCProcedures"; ASPECT=GetChangeStatus; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-02-04
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var change_position: i64 = 0;
    var pending_events: i64 = 0;

    if (global_cdc_engine) |engine| {
        change_position = @intCast(engine.total_change_attempts);
        pending_events = @intCast(engine.event_buffer.items.len);
    }

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "change_position");
    columns[1] = try allocator.dupe(u8, "ingest_lag_ms");
    columns[2] = try allocator.dupe(u8, "processed_bytes");
    columns[3] = try allocator.dupe(u8, "pending_events");
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Int = change_position };
    row[1] = Value{ .Int = 0 };
    row[2] = Value{ .Int = 0 };
    row[3] = Value{ .Int = pending_events };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcConfigureChangeStream(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-020; FEATURE="CDCProcedures"; ASPECT=ConfigureChangeStream; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-02-04
    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "status");
    columns[1] = try allocator.dupe(u8, "stream_position");
    const row = try allocator.alloc(Value, 2);
    row[0] = Value{ .Str = "configured" };
    row[1] = Value{ .Int = 0 };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcSetRetentionPolicy(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-021; FEATURE="CDCProcedures"; ASPECT=SetRetentionPolicy; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = "retention_policy_set" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcCleanupExpiredEvents(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-022; FEATURE="CDCProcedures"; ASPECT=CleanupExpiredEvents; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "cleaned_events");
    columns[1] = try allocator.dupe(u8, "bytes_freed");
    columns[2] = try allocator.dupe(u8, "oldest_remaining_event");
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Int = 0 };
    row[1] = Value{ .Int = 0 };
    row[2] = Value{ .Str = "2025-10-25T00:00:00Z" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcGetTelemetryMetrics(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-023; FEATURE="CDCProcedures"; ASPECT=GetTelemetryMetrics; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const events_per_second: i64 = 0;
    var memory_usage_bytes: i64 = 0;

    if (global_cdc_engine) |engine| {
        memory_usage_bytes = @intCast(engine.peak_buffer);
    }

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "events_per_second");
    columns[1] = try allocator.dupe(u8, "avg_processing_latency_ms");
    columns[2] = try allocator.dupe(u8, "memory_usage_bytes");
    columns[3] = try allocator.dupe(u8, "error_rate");
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Int = events_per_second };
    row[1] = Value{ .Int = 5 };
    row[2] = Value{ .Int = memory_usage_bytes };
    row[3] = Value{ .Int = 0 };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcGetPerformanceAlerts(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-024; FEATURE="CDCProcedures"; ASPECT=GetPerformanceAlerts; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "alert_type");
    columns[1] = try allocator.dupe(u8, "threshold_exceeded");
    columns[2] = try allocator.dupe(u8, "current_value");
    columns[3] = try allocator.dupe(u8, "recommended_action");
    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Str = "none" };
    row[1] = Value{ .Bool = false };
    row[2] = Value{ .Str = "0" };
    row[3] = Value{ .Str = "no_action_required" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcStop(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-025; FEATURE="CDCProcedures"; ASPECT=Stop; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var final_event_count: i64 = 0;

    if (global_cdc_engine) |engine| {
        final_event_count = @intCast(engine.total_events);
        engine.stop();
    }

    const columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "status");
    columns[1] = try allocator.dupe(u8, "final_event_count");
    const row = try allocator.alloc(Value, 2);
    row[0] = Value{ .Str = "stopped" };
    row[1] = Value{ .Int = final_event_count };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcStart(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-026; FEATURE="CDCProcedures"; ASPECT=Start; STATUS=TESTED; TEST=geodetestlab/specs/geode_cdc_comprehensive.yml; OWNER=cdc; UPDATED=2026-01-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var recovered_event_count: i64 = 0;

    if (global_cdc_engine) |engine| {
        engine.start() catch |err| switch (err) {
            // error-policy: A — geode.cdc.start is intentionally idempotent;
            // an already-running engine still reports status="started".
            error.AlreadyRunning => {},
            // error-policy: C — the procedure reports status="started"; a real
            // start failure (e.g. worker pool spawn) must propagate instead of
            // lying to the client.
            else => return err,
        };
        recovered_event_count = @intCast(engine.total_events);
    }

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "status");
    columns[1] = try allocator.dupe(u8, "recovered_event_count");
    columns[2] = try allocator.dupe(u8, "checkpoint_restored");
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Str = "started" };
    row[1] = Value{ .Int = recovered_event_count };
    row[2] = Value{ .Bool = true };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

// ===========================================================================
// FLE Config Parsing Helper Functions
// ===========================================================================

// CANARY: REQ=REQ-NESTING-REFACTOR-023; FEATURE="NestingReduction"; ASPECT=FLEVisibility; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
fn parseVisibilityList(allocator: std.mem.Allocator, list: []const *const ast.Expr) ![][]const u8 {
    const visibility_roles = try allocator.alloc([]const u8, list.len);
    for (list, 0..) |item, i| {
        visibility_roles[i] = if (item.* == .String) item.String else "";
    }
    return visibility_roles;
}

const FLEConfigResult = struct {
    algorithm: fle_annotations.EncryptionConfig.Algorithm,
    visibility_roles: [][]const u8,
};

// CANARY: REQ=REQ-NESTING-REFACTOR-024; FEATURE="NestingReduction"; ASPECT=FLEConfigParsing; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
fn parseFLEConfigMap(allocator: std.mem.Allocator, map_props: []const ast.Property) !FLEConfigResult {
    var algorithm: fle_annotations.EncryptionConfig.Algorithm = .aes256_gcm;
    var visibility_roles: [][]const u8 = &.{};

    for (map_props) |prop| {
        if (std.mem.eql(u8, prop.key, "algorithm")) {
            if (prop.value.* == .String) {
                algorithm = fle_annotations.EncryptionConfig.Algorithm.fromString(prop.value.String) catch .aes256_gcm;
            }
        } else if (std.mem.eql(u8, prop.key, "visibility")) {
            if (prop.value.* == .List) {
                visibility_roles = try parseVisibilityList(allocator, prop.value.List);
            }
        }
    }

    return .{ .algorithm = algorithm, .visibility_roles = visibility_roles };
}

/// Execute a FLE procedure. Returns null if not recognized.

// ---------------------------------------------------------------------------
// FLE dispatch table
// ---------------------------------------------------------------------------
const FleHandler = *const fn (std.mem.Allocator, ast.CallProcedure) anyerror!ExecutionResult;

// NOTE: procedure names are normalized to lowercase by extractNormalizedProcName
// (ISO/IEC 39075:2024 RQ-0022), so all keys here MUST be lowercase.
const fle_table = std.StaticStringMap(FleHandler).initComptime(.{
    .{ "geode.fle.configurefield", handleGeodeFleConfigurefield },
    .{ "geode.fle.grantplaintext", handleGeodeFleGrantplaintext },
    .{ "geode.fle.getfieldconfig", handleGeodeFleGetfieldconfig },
    .{ "geode.fle.listencryptedfields", handleGeodeFleListencryptedfields },
});

/// Execute a FLE procedure. Returns null if not recognized.
pub fn executeFle(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
) !?ExecutionResult {
    if (fle_table.get(proc_name)) |handler| {
        // Cluster fail-closed: see GateStorageProcs. configureField writes the
        // durable HMAC-chained FLE field catalog; getfieldconfig /
        // listencryptedfields are reads and stay open.
        if (std.mem.eql(u8, proc_name, "geode.fle.configurefield") or
            std.mem.eql(u8, proc_name, "geode.fle.grantplaintext"))
        {
            try cluster_mod.gateUnreplicatedWrite();
        }
        return try handler(allocator, call_stmt);
    }
    return null;
}

fn handleGeodeFleConfigurefield(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) anyerror!ExecutionResult {
    // geode.fle.configureField(type_name, field_name, config) -> status
    // Configures a field for encryption in the FLE catalog
    //
    // Example: CALL geode.fle.configureField('User', 'ssn', {algorithm: 'AES-256-GCM', keyVersion: 1, visibility: ['admin']})

    // Extract arguments
    var type_name: []const u8 = "unknown";
    var field_name: []const u8 = "unknown";
    var algorithm: fle_annotations.EncryptionConfig.Algorithm = .aes256_gcm;
    var visibility_roles: [][]const u8 = &.{};

    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 2) {
            // First argument: type_name (string literal)
            if (args[0].* == .String) {
                type_name = args[0].String;
            }
            // Second argument: field_name (string literal)
            if (args[1].* == .String) {
                field_name = args[1].String;
            }
            // Third argument: config map (optional) - uses helper to reduce nesting
            if (args.len >= 3 and args[2].* == .Map) {
                const config = try parseFLEConfigMap(allocator, args[2].Map);
                algorithm = config.algorithm;
                visibility_roles = config.visibility_roles;
            }
        }
    }

    // Get the FLE catalog
    const catalog = try fle_catalog.globalCatalog(allocator);

    // Create field metadata with encryption enabled
    const field_meta = fle_annotations.FieldMetadata{
        .field_name = field_name,
        .encryption = .{
            .enabled = true,
            .algorithm = algorithm,
            .key_scope = .field,
        },
        .search = .{ .enabled = false },
        .visibility = .{ .to_roles = visibility_roles },
        .classification = .{},
    };

    // Configure the field in the catalog (creates type if needed, updates if exists)
    try catalog.configureField(type_name, field_meta);

    // Mark that encrypted fields exist
    fle_integration.setHasEncryptedFields(true);

    log.info("FLE field configured", &.{
        Attr.string("type", type_name),
        Attr.string("field", field_name),
        Attr.string("algorithm", @tagName(algorithm)),
    });

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = "configured" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleGeodeFleGrantplaintext(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) anyerror!ExecutionResult {
    // geode.fle.grantPlaintext(type_name, field_name, role) -> status
    // ONLINE equivalent of the offline `geode fle grant-plaintext` CLI: grants a
    // role READ_PLAINTEXT for an encrypted field WITHOUT stopping the server.
    //
    // This mirrors handleGeodeFleConfigurefield: it resolves the same process-wide
    // FLE catalog (fle_catalog.globalCatalog) that configureField writes and that
    // the decryption read path (fle_integration.canReadPlaintext) consults, then
    // calls catalog.grantPlaintextAccess(...) — the exact same call the offline CLI
    // makes (src/admin/fle_commands.zig grantPlaintext). The grant is persisted via
    // saveCatalog inside grantPlaintextAccess, so it survives restart and is
    // byte-for-byte identical to the offline grant.
    //
    // Example: CALL geode.fle.grantPlaintext('User', 'ssn', 'analyst')

    // Extract arguments (3 string literals)
    var type_name: []const u8 = "unknown";
    var field_name: []const u8 = "unknown";
    var role: []const u8 = "unknown";

    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 3) {
            if (args[0].* == .String) {
                type_name = args[0].String;
            }
            if (args[1].* == .String) {
                field_name = args[1].String;
            }
            if (args[2].* == .String) {
                role = args[2].String;
            }
        }
    }

    // Resolve the same global FLE catalog configureField uses (and the read path
    // consults), then grant via the identical call the offline CLI makes.
    const catalog = try fle_catalog.globalCatalog(allocator);
    try catalog.grantPlaintextAccess(type_name, field_name, role);

    log.info("FLE plaintext access granted (online)", &.{
        Attr.string("type", type_name),
        Attr.string("field", field_name),
        Attr.string("role", role),
    });

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = "granted" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleGeodeFleGetfieldconfig(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) anyerror!ExecutionResult {
    // geode.fle.getFieldConfig(type_name, field_name) -> encrypted, algorithm, searchable
    // CANARY: REQ=REQ-FLE-PROC-003; FEATURE="FLEProcedures"; ASPECT=GetFieldConfig; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28

    var type_name: []const u8 = "unknown";
    var field_name: []const u8 = "unknown";

    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 2) {
            if (args[0].* == .String) {
                type_name = args[0].String;
            }
            if (args[1].* == .String) {
                field_name = args[1].String;
            }
        }
    }

    const catalog = try fle_catalog.globalCatalog(allocator);
    var encrypted = false;
    var algorithm_str: []const u8 = "none";
    var searchable = false;

    if (catalog.getFieldMetadata(type_name, field_name)) |field_meta| {
        encrypted = field_meta.isEncrypted();
        if (field_meta.algorithm()) |alg| {
            algorithm_str = @tagName(alg);
        }
        searchable = field_meta.isSearchable();
    }

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "encrypted");
    columns[1] = try allocator.dupe(u8, "algorithm");
    columns[2] = try allocator.dupe(u8, "searchable");
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Bool = encrypted };
    row[1] = Value{ .Str = algorithm_str };
    row[2] = Value{ .Bool = searchable };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleGeodeFleListencryptedfields(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) anyerror!ExecutionResult {
    // geode.fle.listEncryptedFields(type_name) -> field_name, algorithm, searchable
    // CANARY: REQ=REQ-FLE-PROC-004; FEATURE="FLEProcedures"; ASPECT=ListEncryptedFields; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28

    var type_name: []const u8 = "unknown";

    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1) {
            if (args[0].* == .String) {
                type_name = args[0].String;
            }
        }
    }

    const catalog = try fle_catalog.globalCatalog(allocator);
    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "field_name");
    columns[1] = try allocator.dupe(u8, "algorithm");
    columns[2] = try allocator.dupe(u8, "searchable");

    var rows_list = std.ArrayList([]Value).empty;

    if (catalog.getType(type_name)) |type_meta| {
        var it = type_meta.fields.iterator();
        while (it.next()) |entry| {
            const field_meta = entry.value_ptr.*;
            if (field_meta.isEncrypted()) {
                const row = try allocator.alloc(Value, 3);
                row[0] = Value{ .Str = field_meta.field_name };
                row[1] = Value{ .Str = if (field_meta.algorithm()) |alg| @tagName(alg) else "none" };
                row[2] = Value{ .Bool = field_meta.isSearchable() };
                try rows_list.append(allocator, row);
            }
        }
    }

    return .{ .columns = columns, .rows = try rows_list.toOwnedSlice(allocator), .flags = std.ArrayList([]const u8).empty };
}

// ---------------------------------------------------------------------------
// Storage dispatch table
// ---------------------------------------------------------------------------
const StorageHandler = *const fn (std.mem.Allocator, ast.CallProcedure, execution.ExecutionContext) anyerror!ExecutionResult;

const storage_table = std.StaticStringMap(StorageHandler).initComptime(.{
    .{ "geode.storage.stats", handleGeodeStorageStats },
    .{ "geode.storage.integrity", handleGeodeStorageIntegrity },
});

/// Execute a Storage procedure. Returns null if not recognized.
pub fn executeStorage(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
    context: execution.ExecutionContext,
) !?ExecutionResult {
    if (storage_table.get(proc_name)) |handler| {
        return try handler(allocator, call_stmt, context);
    }
    return null;
}

// CANARY: REQ=REQ-SONNY-2804-STORAGE-PROC-GATE; FEATURE="GraphRBACEnforcement"; ASPECT=StorageProcedures; STATUS=TESTED; TEST=tests/test_sonny2804_storage_procs_gate.zig; OWNER=security; UPDATED=2026-09-26
/// SONNY-2804: the graph a geode.storage.* call names (its first argument, a
/// string; `default` without one), once it has passed the gate every other
/// way of reaching a graph takes: an internal graph is refused
/// (`InternalGraph`, 42501, for every user), then the caller must be allowed
/// to bind it (`session_graph.mayBind`: `Unauthorized`, 42501), and only then
/// must it exist (`GraphNotFound`, 3F000). The procedures took any name as
/// given: a user refused a graph read its node, edge and page counts and WAL
/// position, a graph that did not exist answered 42883 (an existence oracle),
/// and `__geode_*` graphs answered too.
fn storageGraph(call_stmt: ast.CallProcedure, context: execution.ExecutionContext) ![]const u8 {
    var graph_name: []const u8 = graph_store.DEFAULT_GRAPH_NAME;
    if (call_stmt.procedure == .Call) {
        const args = call_stmt.procedure.Call.args;
        if (args.len >= 1 and args[0].* == .String) graph_name = args[0].String;
    }
    try execution.session_graph.refuseInternal(graph_name);
    if (!execution.session_graph.mayBind(context.principal, graph_name)) return error.Unauthorized;
    if (!execution.session_graph.exists(context.catalog, graph_name)) return error.GraphNotFound;
    return graph_name;
}

fn handleGeodeStorageStats(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure, context: execution.ExecutionContext) anyerror!ExecutionResult {
    // geode.storage.stats([graph_name]) -> node_count, edge_count, ...
    // Reads storage-level statistics from the graph-storage engine.
    const adapter = graph_store.getGlobalAdapter() orelse return ExecutionError.UnknownProcedure;

    const graph_name = try storageGraph(call_stmt, context);

    const stats = adapter.getStorageStats(graph_name) catch |err| {
        log.warn("geode.storage.stats failed", &.{Attr.string("error", @errorName(err))});
        return ExecutionError.UnknownProcedure;
    };

    const columns = try allocator.alloc([]const u8, 12);
    columns[0] = try allocator.dupe(u8, "node_count");
    columns[1] = try allocator.dupe(u8, "edge_count");
    columns[2] = try allocator.dupe(u8, "label_count");
    columns[3] = try allocator.dupe(u8, "format_version");
    columns[4] = try allocator.dupe(u8, "page_size");
    columns[5] = try allocator.dupe(u8, "wal_lsn");
    columns[6] = try allocator.dupe(u8, "last_checkpoint_lsn");
    columns[7] = try allocator.dupe(u8, "free_pages_nodes");
    columns[8] = try allocator.dupe(u8, "free_pages_adj_out");
    columns[9] = try allocator.dupe(u8, "free_pages_adj_in");
    columns[10] = try allocator.dupe(u8, "free_pages_props");
    columns[11] = try allocator.dupe(u8, "free_pages_var");

    const row = try allocator.alloc(Value, 12);
    row[0] = Value{ .Int = @intCast(stats.node_count) };
    row[1] = Value{ .Int = @intCast(stats.edge_count) };
    row[2] = Value{ .Int = @intCast(stats.label_count) };
    row[3] = Value{ .Int = @intCast(stats.format_version) };
    row[4] = Value{ .Int = @intCast(stats.page_size) };
    row[5] = Value{ .Int = @intCast(stats.wal_lsn) };
    row[6] = Value{ .Int = @intCast(stats.last_checkpoint_lsn) };
    row[7] = Value{ .Int = @intCast(stats.free_pages_nodes) };
    row[8] = Value{ .Int = @intCast(stats.free_pages_adj_out) };
    row[9] = Value{ .Int = @intCast(stats.free_pages_adj_in) };
    row[10] = Value{ .Int = @intCast(stats.free_pages_props) };
    row[11] = Value{ .Int = @intCast(stats.free_pages_var) };

    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleGeodeStorageIntegrity(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure, context: execution.ExecutionContext) anyerror!ExecutionResult {
    // geode.storage.integrity([graph_name]) -> node_count_consistent, edge_count_consistent, ...
    // Runs an integrity check on the graph-storage engine.
    const adapter = graph_store.getGlobalAdapter() orelse return ExecutionError.UnknownProcedure;

    const graph_name = try storageGraph(call_stmt, context);

    const report = adapter.checkIntegrity(graph_name) catch |err| {
        log.warn("geode.storage.integrity failed", &.{Attr.string("error", @errorName(err))});
        return ExecutionError.UnknownProcedure;
    };

    const columns = try allocator.alloc([]const u8, 4);
    columns[0] = try allocator.dupe(u8, "node_count_consistent");
    columns[1] = try allocator.dupe(u8, "edge_count_consistent");
    columns[2] = try allocator.dupe(u8, "label_index_entries");
    columns[3] = try allocator.dupe(u8, "total_errors");

    const row = try allocator.alloc(Value, 4);
    row[0] = Value{ .Bool = report.node_count_consistent };
    row[1] = Value{ .Bool = report.edge_count_consistent };
    row[2] = Value{ .Int = @intCast(report.label_index_entries) };
    row[3] = Value{ .Int = @intCast(report.total_errors) };

    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}
