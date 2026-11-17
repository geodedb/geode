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
const fle_migration = @import("fle_migration.zig");
const schema = @import("schema");

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
const tde_mutating_set = std.StaticStringMap(void).initComptime(.{
    .{ "tde.initialize_key_hierarchy", {} },
    .{ "tde.rotate_keys", {} },
    .{ "tde.configure_kms", {} },
    .{ "tde.configure_key_provider", {} },
    .{ "tde.configure_mock_kms", {} }, // writes mock_kms_config.json on disk
    .{ "tde.configure_rotation_schedule", {} },
    .{ "tde.configure_adaptive_rotation", {} },
    .{ "tde.configure_provider", {} },
    .{ "tde.configure_rotation", {} },
    .{ "tde.configure_external_kms", {} },
    .{ "tde.zeroize_keys", {} },
    .{ "tde.cleanup_key_hierarchy", {} },
    .{ "tde.backup_encrypted", {} },
    .{ "tde.encrypt_backup", {} },
    .{ "tde.create_encrypted_backup", {} },
    .{ "tde.restore_with_keys", {} },
    .{ "tde.restore_with_historical_keys", {} },
});

/// SONNY-6334: the FLE procedures that change who reads what in plaintext.
const fle_mutating_set = std.StaticStringMap(void).initComptime(.{
    .{ "geode.fle.configurefield", {} },
    .{ "geode.fle.grantplaintext", {} },
    .{ "geode.fle.revokeplaintext", {} },
    // SONNY-6341: who may act under which FLE role.
    .{ "geode.fle.grantrole", {} },
    .{ "geode.fle.revokerole", {} },
    // SONNY-6688: encrypts a field's stored values (Admin only, audited).
    .{ "geode.fle.migrateencrypt", {} },
});

/// SONNY-6334: FLE and TDE key administration, Admin only
/// (`fle_admin.requireAdmin`). `proc_name` is lowercase.
pub fn isKeyAdministrationProcedure(proc_name: []const u8) bool {
    return fle_mutating_set.has(proc_name) or tde_mutating_set.has(proc_name);
}

/// SONNY-6334: the FLE procedures whose every run is an audit event.
pub fn isAuditedFleChange(proc_name: []const u8) bool {
    return fle_mutating_set.has(proc_name);
}

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

// CDC globals. The engine is process-global, so it lives in the process
// allocator, whichever request (or GEODE_CDC_ENABLE at startup) started it.
pub var global_cdc_engine: ?*cdc_mod.CDCEngine = null;
pub var global_cdc_mutex: std.Io.Mutex = std.Io.Mutex.init;

fn cdcEngineAllocator() std.mem.Allocator {
    return graph_store.global_allocator();
}

/// Start the process's CDC engine unless it runs (`CALL cdc.enable()` and
/// GEODE_CDC_ENABLE at startup).
pub fn enableCdc() !void {
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (global_cdc_engine != null) return;
    global_cdc_engine = cdc_mod.startCDC(cdcEngineAllocator(), .{
        .enabled = true,
        .batch_size = 100,
        .flush_interval_ms = 1000,
    }) catch return error.CdcStartupFailed;
}

// CANARY: REQ=REQ-SONNY-6561-CDC-WIRE-PARITY; FEATURE="CDCControlProtocol"; ASPECT=SharedAnswers; STATUS=TESTED; TEST=tests/test_sonny6561_cdc_transport_parity.zig; OWNER=cdc; UPDATED=2026-11-14
/// SONNY-6561: why a CDC_DIAGNOSTICS or CDC_CONTROL frame is refused, the
/// same on QUIC (an error frame) and gRPC (a grpc-status trailer whose
/// message starts with the SQLSTATE).
pub const CdcRefusal = enum {
    unauthenticated,
    not_admin,

    pub fn sqlstate(self: CdcRefusal) []const u8 {
        return switch (self) {
            .unauthenticated => "28000",
            .not_admin => "42501",
        };
    }

    pub fn message(self: CdcRefusal) []const u8 {
        return switch (self) {
            .unauthenticated => "Authentication required",
            .not_admin => "Permission denied: Admin role required for CDC diagnostics and control",
        };
    }
};

/// SONNY-6561: the CDC_DIAGNOSTICS answer for an authorized caller, the one
/// both transports send (the QUIC handler read a `ServerState` field nothing
/// assigned, so it never saw the running engine).
pub fn cdcDiagnosticsAnswer(allocator: std.mem.Allocator) !schema.CdcDiagnosticsResponse {
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (global_cdc_engine) |engine| return engine.exportDiagnostics(allocator);
    return .{
        .config = .{ .enabled = false },
        .engine = .{ .is_running = false },
        .malformed_snapshots = std.ArrayList(schema.CdcMalformedSnapshot).empty,
        .malformed_hashes = std.ArrayList(schema.CdcMalformedHash).empty,
        .version = try allocator.dupe(u8, @import("build_options").version),
        .timestamp_ms = compat_milliTimestamp(),
    };
}

/// SONNY-6570: who sent a CDC frame or ran a CDC procedure, for its audit
/// record.
pub const CdcActor = struct {
    username: []const u8 = "",
    user_id: u64 = 0,
};

// CANARY: REQ=REQ-SONNY-6570-CDC-AUDIT; FEATURE="CDCProcedures"; ASPECT=AuditedChanges; STATUS=TESTED; TEST=tests/test_sonny6570_cdc_honesty.zig; OWNER=cdc; UPDATED=2026-11-15
/// SONNY-6570: the audit record of a CDC change (`CALL cdc.enable()` ...,
/// a CDC_CONTROL frame) that ran (`failure` null) or failed. No CDC frame
/// or procedure was audited. Call it holding no CDC lock.
pub fn auditCdcChange(allocator: std.mem.Allocator, action: []const u8, actor: CdcActor, details: []const u8, failure: ?[]const u8) void {
    const audit_mod = @import("../security/audit.zig");
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll(details) catch {};
    if (failure) |f| w.print("{s}error={s}", .{ if (details.len > 0) " " else "", f }) catch {};
    audit_mod.logSecurityGraphEvent(allocator, .{
        .event_type = .configuration_change,
        .action = action,
        .user_id = actor.user_id,
        .username = actor.username,
        .details = w.buffered(),
        .result_failure = failure != null,
    });
}

/// SONNY-6570: the audit record of a refused CDC_DIAGNOSTICS / CDC_CONTROL
/// frame (`frame` names it), as `fle_admin.requireAdmin` audits a refused
/// procedure.
pub fn auditCdcFrameRefusal(allocator: std.mem.Allocator, frame: []const u8, actor: CdcActor, refusal: CdcRefusal) void {
    const audit_mod = @import("../security/audit.zig");
    audit_mod.logSecurityGraphEvent(allocator, .{
        .event_type = .access_denied,
        .action = frame,
        .user_id = actor.user_id,
        .username = actor.username,
        .details = switch (refusal) {
            .unauthenticated => "CDC administration denied: unauthenticated",
            .not_admin => "CDC administration denied: admin role required",
        },
        .result_failure = true,
    });
}

/// SONNY-6561: the CDC_CONTROL answer for an authorized caller, the one both
/// transports send. RESET_GUARDRAILS is the one action. In cluster mode the
/// frame is refused as `CALL cdc.reset_guardrails()` is (the engine is
/// node-local, `gateUnreplicatedWrite`). SONNY-6570: every answer is an
/// audit record (action `CDC_CONTROL`).
pub fn cdcControlAnswer(allocator: std.mem.Allocator, action: []const u8, actor: CdcActor) !schema.CdcControlResponse {
    const resp = try cdcControlAnswerUnaudited(allocator, action);
    var buf: [192]u8 = undefined;
    const shown = action[0..@min(action.len, 64)];
    const details = std.fmt.bufPrint(&buf, "action={s} status={s} guardrail_epoch={d}", .{ shown, resp.status, resp.guardrail_epoch }) catch "";
    auditCdcChange(allocator, "CDC_CONTROL", actor, details, if (resp.success) null else resp.status);
    return resp;
}

fn cdcControlAnswerUnaudited(allocator: std.mem.Allocator, action: []const u8) !schema.CdcControlResponse {
    cluster_mod.gateUnreplicatedWrite() catch |err| return .{
        .success = false,
        .status = try allocator.dupe(u8, switch (err) {
            error.ClusterNotLeader => "CLUSTER_NOT_LEADER",
            error.ClusterWriteNotReplicable => "CLUSTER_WRITE_NOT_REPLICABLE",
        }),
        .guardrail_epoch = 0,
    };
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const engine = global_cdc_engine orelse return .{
        .success = false,
        .status = try allocator.dupe(u8, "NO_ENGINE"),
        .guardrail_epoch = 0,
    };
    const reset = std.ascii.eqlIgnoreCase(action, "RESET_GUARDRAILS");
    if (reset) engine.resetGuardrailState();
    return .{
        .success = reset,
        .status = try allocator.dupe(u8, if (reset) "OK" else "UNSUPPORTED"),
        .guardrail_epoch = engine.guardrail_epoch,
    };
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
    // SONNY-6442: measure_overhead timed 1000 alloc+memcpy+free of 1 KiB as
    // the "baseline" against 1000 AEAD encryptions as "encrypted" and
    // answered passes_threshold = overhead < 5 %. Neither loop touches
    // storage, so it measured nothing about TDE overhead. The measurement is
    // `zig build test-sonny6435-tde-overhead` (the storage engine with page
    // and WAL encryption off vs on).
    .{ "tde.measure_overhead", {} },
});

/// Execute a TDE procedure. Returns null if not recognized.
pub fn executeTde(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
) !?ExecutionResult {
    if (tde_refused_set.has(proc_name)) {
        if (std.mem.eql(u8, proc_name, "tde.measure_overhead")) {
            log.warn("tde.measure_overhead is not supported: TDE overhead is measured by `zig build test-sonny6435-tde-overhead`", &.{});
        } else {
            log.warn("TDE procedure not supported: it reported work it did not do", &.{Attr.string("procedure", proc_name)});
        }
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

    // SONNY-6448: no performance-impact column (it timed AEAD round trips
    // against memcpy, which is not TDE overhead).
    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "types_tested");
    columns[1] = try allocator.dupe(u8, "all_transparent");
    columns[2] = try allocator.dupe(u8, "errors_encountered");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Int = @intCast(result.types_tested) };
    row[1] = Value{ .Bool = result.all_transparent };
    row[2] = Value{ .Int = @intCast(result.errors_encountered) };
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

fn handleTdeSimulateOltpWorkload(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-TDE-PROC-046; FEATURE="TDETestProcedures"; ASPECT=SimulateOLTPWorkload; STATUS=TESTED; TEST=tests/test_sonny6321_tde_fle_cases.zig; OWNER=tde; UPDATED=2026-11-12
    // tde.simulate_oltp_workload(duration_seconds, concurrent_transactions) -> avg_transaction_time_ms, tps_with_encryption, tps_without_encryption, degradation_percentage, concurrent_transactions, transactions

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
    // SONNY-6348: concurrent_transactions is honoured (1..64 worker threads,
    // else error.InvalidArgs) and reported back with the transactions run.
    const result = try tde_mod.simulateOLTPWorkload(allocator, duration_seconds, concurrent_transactions);

    const columns = try allocator.alloc([]const u8, 6);
    columns[0] = try allocator.dupe(u8, "avg_transaction_time_ms");
    columns[1] = try allocator.dupe(u8, "tps_with_encryption");
    columns[2] = try allocator.dupe(u8, "tps_without_encryption");
    columns[3] = try allocator.dupe(u8, "degradation_percentage");
    columns[4] = try allocator.dupe(u8, "concurrent_transactions");
    columns[5] = try allocator.dupe(u8, "transactions");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 6);
    row[0] = Value{ .Decimal = .{ .coeff = try decimal128.checkedScaledCoeff(result.avg_transaction_time_ms, 100.0), .scale = 2 } };
    row[1] = Value{ .Int = result.tps_with_encryption };
    row[2] = Value{ .Int = result.tps_without_encryption };
    row[3] = Value{ .Decimal = .{ .coeff = try decimal128.checkedScaledCoeff(result.degradation_percentage, 100.0), .scale = 2 } };
    row[4] = Value{ .Int = result.concurrent_transactions };
    row[5] = Value{ .Int = std.math.cast(i64, result.transactions) orelse return error.InvalidArgs };
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

// CANARY: REQ=REQ-SONNY-6570-CDC-TRUTHFUL-PROCEDURES; FEATURE="CDCProcedures"; ASPECT=EngineStateOnly; STATUS=TESTED; TEST=tests/test_sonny6570_cdc_honesty.zig; OWNER=cdc; UPDATED=2026-11-15
/// SONNY-6570: the procedures that answer from the running engine or change
/// it. Change capture is not implemented (SONNY-6572): no write path feeds
/// the engine, so it holds no change events.
const cdc_table = std.StaticStringMap(CdcHandler).initComptime(.{
    .{ "cdc.enable", handleCdcEnable },
    .{ "cdc.disable", handleCdcDisable },
    .{ "cdc.status", handleCdcStatus },
    .{ "cdc.export_diagnostics", handleCdcExportDiagnostics },
    .{ "cdc.get_guardrail_status", handleCdcGetGuardrailStatus },
    .{ "cdc.reset_guardrails", handleCdcResetGuardrails },
    .{ "cdc.stop", handleCdcStop },
    .{ "cdc.start", handleCdcStart },
});

// CANARY: REQ=REQ-SONNY-6570-CDC-REFUSED-PROCEDURES; FEATURE="CDCProcedures"; ASPECT=RefuseNotImplemented; STATUS=TESTED; TEST=tests/test_sonny6570_cdc_honesty.zig; OWNER=cdc; UPDATED=2026-11-15
/// SONNY-6570: the procedures that cannot answer truthfully while change
/// capture is not implemented, and why. They returned an invented event,
/// fixed rows or fixed numbers, or changed nothing and reported success;
/// they are refused with `error.CdcNotImplemented` (SQLSTATE 0A000).
// SONNY-6570: these were STATUS=TESTED against a geodetestlab spec while
// they answered invented data; they are not implemented (refused 0A000)
// until change capture is (SONNY-6572).
// CANARY: REQ=REQ-CDC-PROC-005; FEATURE="CDCProcedures"; ASPECT=GetEvents; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-006; FEATURE="CDCProcedures"; ASPECT=Pause; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-007; FEATURE="CDCProcedures"; ASPECT=Resume; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-008; FEATURE="CDCProcedures"; ASPECT=SetGuardrail; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-011; FEATURE="CDCProcedures"; ASPECT=GetWatermark; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-012; FEATURE="CDCProcedures"; ASPECT=GetPendingEvents; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-013; FEATURE="CDCProcedures"; ASPECT=ConfigureAdaptiveFlush; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-014; FEATURE="CDCProcedures"; ASPECT=GetFlushMetrics; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-015; FEATURE="CDCProcedures"; ASPECT=GetMalformedRecords; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-016; FEATURE="CDCProcedures"; ASPECT=GetCorruptionAnalysis; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-017; FEATURE="CDCProcedures"; ASPECT=GetOrderedEvents; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-018; FEATURE="CDCProcedures"; ASPECT=CheckDuplicates; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-019; FEATURE="CDCProcedures"; ASPECT=GetChangeStatus; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-020; FEATURE="CDCProcedures"; ASPECT=ConfigureChangeStream; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-021; FEATURE="CDCProcedures"; ASPECT=SetRetentionPolicy; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-022; FEATURE="CDCProcedures"; ASPECT=CleanupExpiredEvents; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-023; FEATURE="CDCProcedures"; ASPECT=GetTelemetryMetrics; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
// CANARY: REQ=REQ-CDC-PROC-024; FEATURE="CDCProcedures"; ASPECT=GetPerformanceAlerts; STATUS=STUB; OWNER=cdc; UPDATED=2026-11-15
const cdc_refused = std.StaticStringMap([]const u8).initComptime(.{
    .{ "cdc.get_events", "no change is captured, so there are no change events to return" },
    .{ "cdc.get_ordered_events", "no change is captured, so there are no change events to order" },
    .{ "cdc.get_pending_events", "no change is captured, so no change event is pending" },
    .{ "cdc.check_duplicates", "no change is captured, so there are no change events to check for duplicates" },
    .{ "cdc.get_change_status", "there is no change stream, so it has no position, lag or byte count" },
    .{ "cdc.get_watermark", "there is no change stream, so it has no watermark or flow control" },
    .{ "cdc.get_flush_metrics", "the engine flushes no change events and keeps no flush latency or flush count" },
    .{ "cdc.get_telemetry_metrics", "the engine keeps no event rate, latency, memory use or error rate" },
    .{ "cdc.get_performance_alerts", "the engine raises no performance alerts" },
    .{ "cdc.get_malformed_records", "no change record is ingested, so none is malformed (the engine's malformed-record counters are in CALL cdc.export_diagnostics())" },
    .{ "cdc.get_corruption_analysis", "no change record is ingested, so none is analysed for corruption" },
    .{ "cdc.pause", "the engine has no paused state (CALL cdc.stop() and CALL cdc.start() stop and start it)" },
    .{ "cdc.resume", "the engine has no paused state (CALL cdc.stop() and CALL cdc.start() stop and start it)" },
    .{ "cdc.set_guardrail", "the engine does not use these thresholds (its guardrails are the malformed-record ratios GEODE_CDC_MALFORMED_WARN_PCT and GEODE_CDC_MALFORMED_ABORT_PCT)" },
    .{ "cdc.configure_adaptive_flush", "the engine flushes no change events, and the procedure configured nothing" },
    .{ "cdc.configure_change_stream", "there is no change stream to configure" },
    .{ "cdc.set_retention_policy", "the engine retains no change events" },
    .{ "cdc.cleanup_expired_events", "the engine retains no change events to clean up" },
});

threadlocal var t_cdc_refusal_buf: [512]u8 = undefined;
threadlocal var t_cdc_refusal_len: usize = 0;

const cdc_refusal_generic = "This cdc.* procedure is not implemented: change capture is not implemented (see SONNY-6572)";

/// The message of this thread's latest `error.CdcNotImplemented`
/// (proto_util.mapError reads it on the same thread).
pub fn cdcNotImplementedMessage() []const u8 {
    if (t_cdc_refusal_len == 0) return cdc_refusal_generic;
    return t_cdc_refusal_buf[0..t_cdc_refusal_len];
}

fn setCdcRefusal(proc_name: []const u8, reason: []const u8) void {
    const text = std.fmt.bufPrint(&t_cdc_refusal_buf, "CALL {s}() is not implemented: change capture is not implemented (see SONNY-6572); {s}", .{ proc_name, reason }) catch {
        t_cdc_refusal_len = 0;
        return;
    };
    t_cdc_refusal_len = text.len;
}

/// SONNY-6570: every `cdc.*` procedure is CDC administration, Admin only, as
/// the CDC_DIAGNOSTICS / CDC_CONTROL frames are. `proc_name` is lowercase.
pub fn isCdcProcedure(proc_name: []const u8) bool {
    return std.mem.startsWith(u8, proc_name, "cdc.");
}

/// SONNY-6570: the CDC procedures that change (or would change) the engine;
/// every run is an audit event, success or failure.
pub fn isAuditedCdcChange(proc_name: []const u8) bool {
    return cdc_mutating_set.has(proc_name);
}

/// Execute a CDC procedure. Returns null if not recognized.
pub fn executeCdc(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
) !?ExecutionResult {
    if (cdc_refused.get(proc_name)) |reason| {
        setCdcRefusal(proc_name, reason);
        return error.CdcNotImplemented;
    }
    if (cdc_table.get(proc_name)) |handler| {
        // Cluster fail-closed: see GateStorageProcs (mutating procs only).
        if (cdc_mutating_set.has(proc_name)) try cluster_mod.gateUnreplicatedWrite();
        return try handler(allocator, call_stmt);
    }
    return null;
}

fn oneRow(allocator: std.mem.Allocator, names: []const []const u8, values: []const Value) !ExecutionResult {
    const columns = try allocator.alloc([]const u8, names.len);
    for (names, 0..) |n, i| columns[i] = try allocator.dupe(u8, n);
    const row = try allocator.dupe(Value, values);
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleCdcEnable(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-001; FEATURE="CDCProcedures"; ASPECT=Enable; STATUS=TESTED; TEST=tests/test_sonny6570_cdc_honesty.zig; OWNER=cdc; UPDATED=2026-11-15
    try enableCdc();
    return oneRow(allocator, &.{"status"}, &.{Value{ .Str = "enabled" }});
}

fn handleCdcDisable(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-002; FEATURE="CDCProcedures"; ASPECT=Disable; STATUS=TESTED; TEST=tests/test_sonny6570_cdc_honesty.zig; OWNER=cdc; UPDATED=2026-11-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_cdc_engine) |engine| {
        engine.deinit();
        cdcEngineAllocator().destroy(engine);
        global_cdc_engine = null;
    }
    return oneRow(allocator, &.{ "status", "final_statistics" }, &.{ Value{ .Str = "disabled" }, Value{ .Str = "CDC disabled successfully" } });
}

fn handleCdcStatus(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-003; FEATURE="CDCProcedures"; ASPECT=Status; STATUS=TESTED; TEST=tests/test_sonny6570_cdc_honesty.zig; OWNER=cdc; UPDATED=2026-11-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    // SONNY-6570: last_checkpoint was total_events again; the engine has no
    // checkpoint.
    var enabled = false;
    var streaming = false;
    var event_count: i64 = 0;
    if (global_cdc_engine) |engine| {
        const status = cdc_mod.getCDCStatus(engine);
        enabled = true;
        streaming = status.is_running;
        event_count = @intCast(status.total_events);
    }
    return oneRow(allocator, &.{ "enabled", "streaming", "event_count" }, &.{ Value{ .Bool = enabled }, Value{ .Bool = streaming }, Value{ .Int = event_count } });
}

fn handleCdcExportDiagnostics(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-004; FEATURE="CDCProcedures"; ASPECT=ExportDiagnostics; STATUS=TESTED; TEST=tests/test_sonny6570_cdc_honesty.zig; OWNER=cdc; UPDATED=2026-11-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    var event_count: i64 = 0;
    var malformed_count: i64 = 0;
    var last_seq_id: i64 = 0;
    if (global_cdc_engine) |engine| {
        event_count = @intCast(engine.total_events);
        malformed_count = @intCast(engine.malformed_change_records);
        // SONNY-6570: next_sequence is the next number to assign (it was
        // reported as the last one assigned).
        last_seq_id = @intCast(engine.next_sequence -| 1);
    }
    return oneRow(allocator, &.{ "event_count", "malformed_count", "last_seq_id" }, &.{ Value{ .Int = event_count }, Value{ .Int = malformed_count }, Value{ .Int = last_seq_id } });
}

fn handleCdcGetGuardrailStatus(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-009; FEATURE="CDCProcedures"; ASPECT=GetGuardrailStatus; STATUS=TESTED; TEST=tests/test_sonny6570_cdc_honesty.zig; OWNER=cdc; UPDATED=2026-11-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    // SONNY-6570: the thresholds are the engine's malformed-record ratios
    // (they were 1000 and 10000, which nothing used); with no engine there
    // are none.
    var current_epoch: i64 = 0;
    var warn_threshold: Value = .Null;
    var abort_threshold: Value = .Null;
    var pending_events: i64 = 0;
    if (global_cdc_engine) |engine| {
        current_epoch = @intCast(engine.guardrail_epoch);
        warn_threshold = .{ .Double = engine.config.malformed_warn_pct };
        abort_threshold = .{ .Double = engine.config.malformed_abort_pct };
        pending_events = @intCast(engine.event_buffer.items.len);
    }
    return oneRow(allocator, &.{ "current_epoch", "warn_threshold", "abort_threshold", "pending_events" }, &.{ Value{ .Int = current_epoch }, warn_threshold, abort_threshold, Value{ .Int = pending_events } });
}

fn handleCdcResetGuardrails(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-010; FEATURE="CDCProcedures"; ASPECT=ResetGuardrails; STATUS=TESTED; TEST=tests/test_sonny6570_cdc_honesty.zig; OWNER=cdc; UPDATED=2026-11-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    // SONNY-6570: with no engine nothing is reset (it answered
    // "reset_complete").
    const engine = global_cdc_engine orelse return error.CdcNotEnabled;
    engine.resetGuardrailState();
    return oneRow(allocator, &.{ "status", "new_epoch" }, &.{ Value{ .Str = "reset_complete" }, Value{ .Int = @intCast(engine.guardrail_epoch) } });
}

fn handleCdcStop(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-025; FEATURE="CDCProcedures"; ASPECT=Stop; STATUS=TESTED; TEST=tests/test_sonny6570_cdc_honesty.zig; OWNER=cdc; UPDATED=2026-11-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const engine = global_cdc_engine orelse return error.CdcNotEnabled;
    const final_event_count: i64 = @intCast(engine.total_events);
    engine.stop();
    return oneRow(allocator, &.{ "status", "final_event_count" }, &.{ Value{ .Str = "stopped" }, Value{ .Int = final_event_count } });
}

fn handleCdcStart(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-CDC-PROC-026; FEATURE="CDCProcedures"; ASPECT=Start; STATUS=TESTED; TEST=tests/test_sonny6570_cdc_honesty.zig; OWNER=cdc; UPDATED=2026-11-15
    global_cdc_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_cdc_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    // SONNY-6570: with no engine nothing starts (it answered "started" with
    // checkpoint_restored = true; the engine has no checkpoint, and
    // recovered_event_count recovered nothing).
    const engine = global_cdc_engine orelse return error.CdcNotEnabled;
    engine.start() catch |err| switch (err) {
        // error-policy: A — geode.cdc.start is intentionally idempotent;
        // an already-running engine still reports status="started".
        error.AlreadyRunning => {},
        // error-policy: C — the procedure reports status="started"; a real
        // start failure (e.g. worker pool spawn) must propagate instead of
        // lying to the client.
        else => return err,
    };
    return oneRow(allocator, &.{ "status", "event_count" }, &.{ Value{ .Str = "started" }, Value{ .Int = @intCast(engine.total_events) } });
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
            // SONNY-6334: a list literal parses as `.ArrayLit`; only `.List`
            // was read, so `{visibility: [...]}` was dropped and the field
            // was readable by nobody.
            switch (prop.value.*) {
                .List => |items| visibility_roles = try parseVisibilityList(allocator, items),
                .ArrayLit => |items| visibility_roles = try parseVisibilityList(allocator, items),
                else => {},
            }
        } else if (std.mem.eql(u8, prop.key, "searchable")) {
            // SONNY-6348: equality search on encrypted fields (blind
            // indexes) is not available, and the key used to be dropped
            // silently, configuring a field that reported searchable=false.
            // Refuse a request for it rather than pretend; `false` is the
            // only behaviour there is.
            if (!(prop.value.* == .Bool and !prop.value.Bool)) return error.SearchableFieldsUnsupported;
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
    .{ "geode.fle.revokeplaintext", handleGeodeFleRevokeplaintext },
    .{ "geode.fle.grantrole", handleGeodeFleGrantrole },
    .{ "geode.fle.revokerole", handleGeodeFleRevokerole },
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
        if (fle_mutating_set.has(proc_name)) try cluster_mod.gateUnreplicatedWrite();
        return try handler(allocator, call_stmt);
    }
    return null;
}

// CANARY: REQ=REQ-SONNY-6688-FLE-MIGRATE-PROCEDURE; FEATURE="FieldLevelEncryption"; ASPECT=MigrateEncryptProcedure; STATUS=TESTED; TEST=tests/test_sonny6688_fle_migrate_encrypt.zig; OWNER=security; UPDATED=2026-11-16
/// SONNY-6688: `CALL geode.fle.migrateEncrypt(type, field [, batch_size
/// [, tenant [, graph]]])`: encrypt the field's values stored before it was
/// configured as encrypted (`fle_migration.migrateField`). Admin only and
/// audited (`fle_mutating_set`), refused in cluster mode (no replicated
/// slice). The tenant is the session's: one naming another is refused
/// (`Unauthorized`, 42501); an unscoped session may name one (null: every
/// tenant). The graph passes the gate every graph-naming procedure takes
/// (`storageGraph`). YIELDs graph, scanned, encrypted, already_encrypted,
/// non_string, skipped_tenant, skipped_rls, batches, complete.
pub fn executeFleMigrate(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure, context: execution.ExecutionContext) !ExecutionResult {
    try cluster_mod.gateUnreplicatedWrite();
    const args: []const *ast.Expr = if (call_stmt.procedure == .Call) call_stmt.procedure.Call.args else &.{};
    if (args.len < 2 or args.len > 5) return error.InvalidArgs;
    if (args[0].* != .String or args[1].* != .String) return error.InvalidArgs;
    var opts = fle_migration.Options{ .type_name = args[0].String, .field_name = args[1].String };
    if (opts.type_name.len == 0 or opts.field_name.len == 0) return error.InvalidArgs;
    if (args.len >= 3) switch (args[2].*) {
        .Int => |n| opts.batch_size = std.math.cast(usize, n) orelse return error.InvalidArgs,
        .Null => {},
        else => return error.InvalidArgs,
    };
    opts.tenant = context.tenant_id;
    if (args.len >= 4) switch (args[3].*) {
        .String => |t| {
            if (context.tenant_id) |own| {
                if (!std.mem.eql(u8, own, t)) return error.Unauthorized;
            }
            opts.tenant = t;
        },
        .Null => {},
        else => return error.InvalidArgs,
    };
    if (args.len >= 5) {
        if (args[4].* != .String) return error.InvalidArgs;
        opts.graph = args[4].String;
    }
    try execution.session_graph.refuseInternal(opts.graph);
    if (!execution.session_graph.mayBind(context.principal, opts.graph)) return error.Unauthorized;
    if (!execution.session_graph.exists(context.catalog, opts.graph)) return error.GraphNotFound;

    const store = graph_store.getGlobalStore(allocator);
    const report = fle_migration.migrateField(allocator, store, opts) catch |err| switch (err) {
        error.InvalidBatchSize => return error.InvalidArgs,
        else => return err,
    };

    const names = [_][]const u8{ "graph", "scanned", "encrypted", "already_encrypted", "non_string", "skipped_tenant", "skipped_rls", "batches", "complete", "dead_pages_zeroed", "dead_bytes_zeroed" };
    const columns = try allocator.alloc([]const u8, names.len);
    for (names, columns) |n, *c| c.* = try allocator.dupe(u8, n);
    const row = try allocator.alloc(Value, names.len);
    row[0] = .{ .Str = try allocator.dupe(u8, opts.graph) };
    row[1] = .{ .Int = @intCast(report.scanned) };
    row[2] = .{ .Int = @intCast(report.encrypted) };
    row[3] = .{ .Int = @intCast(report.already_encrypted) };
    row[4] = .{ .Int = @intCast(report.non_string) };
    row[5] = .{ .Int = @intCast(report.skipped_tenant) };
    row[6] = .{ .Int = @intCast(report.skipped_rls) };
    row[7] = .{ .Int = @intCast(report.batches) };
    row[8] = .{ .Bool = report.complete() };
    row[9] = .{ .Int = @intCast(report.dead_pages_zeroed) };
    row[10] = .{ .Int = @intCast(report.dead_bytes_zeroed) };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
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

    // CANARY: REQ=REQ-SONNY-6335-NO-INDEX-ON-ENCRYPTED-FIELD; FEATURE="FieldLevelEncryption"; ASPECT=ConfigureFieldRefused; STATUS=TESTED; TEST=tests/test_sonny6335_fle_identity_and_indexes.zig; OWNER=security; UPDATED=2026-11-12
    // SONNY-6335: a field with an index or a UNIQUE / NODE KEY constraint
    // over it is not encrypted until that is dropped: the index would keep
    // (or get) the field's plaintext, or index ciphertext.
    // SONNY-6347: checked and configured with the index DDL mutex held, and
    // an index DDL in flight (past its own check, row not yet recorded)
    // counts as an index.
    fle_integration.lockIndexDdl();
    defer fle_integration.unlockIndexDdl();
    if (fle_integration.indexFieldReservedLocked(type_name, field_name)) {
        log.warn("FLE configureField refused: an index or unique constraint over the field is being created", &.{
            Attr.string("type", type_name),
            Attr.string("field", field_name),
        });
        return error.EncryptedFieldIndexed;
    }
    if (execution.existingCatalogInstance()) |schema_catalog| {
        if (try schema_catalog.indexOrUniqueOnField(allocator, type_name, field_name)) |name| {
            log.warn("FLE configureField refused: the field has an index or unique constraint; drop it first", &.{
                Attr.string("type", type_name),
                Attr.string("field", field_name),
                Attr.string("index", name),
            });
            return error.EncryptedFieldIndexed;
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
    // byte-for-byte identical to the offline grant. SONNY-6324: a failed save
    // undoes the grant and fails the call (FleCatalogNotPersisted, 58030).
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

// CANARY: REQ=REQ-SONNY-6327-FLE-ONLINE-REVOKE; FEATURE="FieldLevelEncryption"; ASPECT=RevokePlaintextProcedure; STATUS=TESTED; TEST=tests/test_sonny6327_fle_read_gaps.zig; OWNER=security; UPDATED=2026-11-11
fn handleGeodeFleRevokeplaintext(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) anyerror!ExecutionResult {
    // geode.fle.revokePlaintext(type_name, field_name, role) -> status
    // SONNY-6327: the ONLINE equivalent of the offline `geode fle
    // revoke-plaintext` command, mirroring geode.fle.grantPlaintext: the
    // same GPS gate (a mutating procedure: `.write`, see
    // procedure_access.classifyProcedureName; not on any read-only list),
    // the same cluster refusal (executeFle), the same global catalog the
    // read path consults, and the same call the offline command makes
    // (SchemaCatalog.revokePlaintextAccess). The role loses plaintext access
    // for every read that starts after this returns: the catalog is the
    // only decision source (no decision cache). SONNY-6324: it fails
    // closed: a save that fails leaves the revoke applied in memory and
    // reports FleRevokeNotPersisted (58030); a retry saves it.
    //
    // Example: CALL geode.fle.revokePlaintext('User', 'ssn', 'analyst')
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

    const catalog = try fle_catalog.globalCatalog(allocator);
    catalog.revokePlaintextAccess(type_name, field_name, role) catch |err| {
        if (err == error.FleRevokeNotPersisted) {
            log.warn("FLE plaintext access revoked (online) but not saved", &.{
                Attr.string("type", type_name),
                Attr.string("field", field_name),
                Attr.string("role", role),
            });
        }
        return err;
    };

    log.info("FLE plaintext access revoked (online)", &.{
        Attr.string("type", type_name),
        Attr.string("field", field_name),
        Attr.string("role", role),
    });

    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = "revoked" };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

// CANARY: REQ=REQ-SONNY-6341-FLE-ROLE-GRANT-PROC; FEATURE="FieldLevelEncryption"; ASPECT=GrantRevokeFleRole; STATUS=TESTED; TEST=tests/test_sonny6341_fle_role_binding.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6341: the (user, role) arguments of grantRole / revokeRole: two
/// string literals, the role in the HELLO role alphabet, and (with
/// authentication on) a user that exists.
fn fleRoleArgs(call_stmt: ast.CallProcedure) ![2][]const u8 {
    if (call_stmt.procedure != .Call) return error.InvalidArgs;
    const args = call_stmt.procedure.Call.args;
    if (args.len != 2 or args[0].* != .String or args[1].* != .String) return error.InvalidArgs;
    const user = args[0].String;
    const role = fle_integration.helloFleRole(args[1].String) orelse return error.InvalidFleRole;
    const user_mgmt = @import("../security/user_management.zig");
    if (user.len == 0) return error.FleRoleUserNotFound;
    if (user_mgmt.isAuthEnabled() and user_mgmt.getUser(user) == null) return error.FleRoleUserNotFound;
    return .{ user, role };
}

fn statusResult(allocator: std.mem.Allocator, status: []const u8) !ExecutionResult {
    const columns = try allocator.alloc([]const u8, 1);
    columns[0] = try allocator.dupe(u8, "status");
    const row = try allocator.alloc(Value, 1);
    row[0] = Value{ .Str = status };
    const rows = try allocator.alloc([]Value, 1);
    rows[0] = row;
    return .{ .columns = columns, .rows = rows, .flags = std.ArrayList([]const u8).empty };
}

fn handleGeodeFleGrantrole(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) anyerror!ExecutionResult {
    // geode.fle.grantRole(user, role) -> status
    // SONNY-6341: `user` may act under FLE role `role` (the role its HELLO
    // names). Admin only and audited (procedure_registry: fle_admin),
    // refused in cluster mode (executeFle), stored in the security graph
    // before it takes effect: a failed save applies nothing (58030).
    const args = try fleRoleArgs(call_stmt);
    const fle_role_grants = @import("../security/fle_role_grants.zig");
    fle_role_grants.grant(args[0], args[1]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            log.warn("FLE role grant not saved", &.{Attr.string("error", @errorName(err))});
            return error.FleRoleGrantNotPersisted;
        },
    };
    return statusResult(allocator, "granted");
}

fn handleGeodeFleRevokerole(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure) anyerror!ExecutionResult {
    // geode.fle.revokeRole(user, role) -> status
    // SONNY-6341: the mirror of grantRole. In force at once (every session
    // of `user` stops acting under `role` from its next request); a save
    // that fails leaves it in force and reports 58030.
    if (call_stmt.procedure != .Call) return error.InvalidArgs;
    const args = call_stmt.procedure.Call.args;
    if (args.len != 2 or args[0].* != .String or args[1].* != .String) return error.InvalidArgs;
    const fle_role_grants = @import("../security/fle_role_grants.zig");
    const held = try fle_role_grants.revoke(args[0].String, args[1].String);
    return statusResult(allocator, if (held) "revoked" else "not granted");
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

    // SONNY-6327: the policy by value, read under the catalog mutex (it
    // returned the catalog's field struct, borrowed, after unlocking).
    if (catalog.fieldPolicy(type_name, field_name)) |policy| {
        encrypted = policy.encrypted;
        if (policy.encrypted) {
            algorithm_str = @tagName(policy.algorithm);
        }
        searchable = policy.searchable;
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

    // SONNY-6327: copies made under the catalog mutex, in the query's
    // allocator (it iterated the catalog's own field map after unlocking,
    // and the rows borrowed field names a reconfigure frees).
    if (try catalog.copyTypeFields(allocator, type_name)) |fields| {
        defer fle_catalog.freeFieldCopies(allocator, fields);
        for (fields) |field_meta| {
            if (field_meta.isEncrypted()) {
                const row = try allocator.alloc(Value, 3);
                row[0] = Value{ .Str = try allocator.dupe(u8, field_meta.field_name) };
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
