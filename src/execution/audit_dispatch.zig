/// Audit Dispatch Module
///
/// Handles routing for all `audit.*` procedure calls.
/// Extracted from procedure_registry.zig as part of the procedure dispatch refactoring.
const std = @import("std");
const cb = @import("crypto_backend");

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
const ast = @import("../gql/ast.zig");
const value_types = @import("../value_types.zig");

const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;

const Value = value_types.Value;

const audit_mod = @import("../security/audit.zig");

const log = std.log.scoped(.audit_dispatch);

const graph_store = @import("../graph_store.zig");

// CANARY: REQ=REQ-SONNY-6325-NO-FIXED-TMP; FEATURE="Secret File Hygiene"; ASPECT=AuditDiagnosticsPrivateFiles; STATUS=TESTED; TEST=tests/test_sonny6325_no_fixed_tmp_paths.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-6325: the files the audit diagnostic procedures write live in
/// `<data dir>/audit-diagnostics/` (0700, files 0600, opened without
/// following a symbolic link). They used fixed paths in the shared /tmp
/// (created and truncated through any link planted there, with the logger's
/// signing key beside them), and `audit.cleanup_test_artifacts` deleted
/// those paths and /etc/geode/geode_audit.jsonl.
const diagnostics_dir_name = "audit-diagnostics";

/// `<data dir>/audit-diagnostics`, a private directory (graph_store.ensurePrivateDir).
/// Allocated with `allocator`; caller frees.
fn diagnosticsDir(allocator: std.mem.Allocator) ![]u8 {
    const data_dir = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(data_dir);
    const dir = try std.fs.path.join(allocator, &.{ data_dir, diagnostics_dir_name });
    errdefer allocator.free(dir);
    try graph_store.ensurePrivateDir(dir);
    return dir;
}

/// `<data dir>/audit-diagnostics/<name>`, allocated with the process
/// allocator because it may become the long-lived diagnostic logger's file
/// path. Caller owns it.
fn diagnosticPath(name: []const u8) ![]u8 {
    const gpa = std.heap.smp_allocator;
    const dir = try diagnosticsDir(gpa);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, name });
}

/// Create or truncate the diagnostic file `path`, mode 0600, never through a
/// symbolic link (error.SymLinkLoop).
fn openDiagnosticFile(path: []const u8) !std.Io.File {
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0o600);
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    errdefer file.close(std.Io.Threaded.global_single_threaded.io());
    try file.setPermissions(std.Io.Threaded.global_single_threaded.io(), std.Io.File.Permissions.fromMode(0o600));
    return file;
}

/// The diagnostic audit logger's file path once it has one (kept for the
/// process lifetime with the logger).
var diagnostic_logger_path: ?[]u8 = null;

/// Initialize the dispatch module's diagnostic logger on `name` in the
/// diagnostics directory when there is none. Caller holds
/// global_audit_logger_mutex. SONNY-6340: the logger lives for the process,
/// so it is made with the process allocator, never a query's (it was handed
/// the per-query allocator and kept it after the query ended).
fn initDiagnosticLoggerLocked(name: []const u8, redact_pii: bool) void {
    if (global_audit_logger != null) return;
    const gpa = std.heap.smp_allocator;
    const path = diagnosticPath(name) catch |err| {
        log.warn("audit diagnostics directory unavailable: {s}", .{@errorName(err)});
        return;
    };
    // The logger opens the file itself; make sure it is a regular file of
    // ours first (no link is followed into it).
    if (openDiagnosticFile(path)) |f| {
        f.close(std.Io.Threaded.global_single_threaded.io());
    } else |err| {
        log.warn("audit diagnostic file refused: {s}", .{@errorName(err)});
        gpa.free(path);
        return;
    }
    global_audit_logger = audit_mod.AuditLogger.init(gpa, .{
        .enabled = true,
        .file_path = path,
        .redact_pii = redact_pii,
        .log_denies_only = false,
    }) catch null;
    if (global_audit_logger == null) {
        gpa.free(path);
        return;
    }
    diagnostic_logger_path = path;
}

/// The diagnostic logger of the audit test procedures (never the server's
/// audit log).
pub var global_audit_logger: ?audit_mod.AuditLogger = null;
pub var global_audit_logger_mutex: std.Io.Mutex = std.Io.Mutex.init;

/// The server's audit logger (the process-global logger main.zig opens on
/// GEODE_AUDIT_LOG_PATH or `<data dir>/audit.jsonl`), when it writes a log.
/// SONNY-6340 / SONNY-6346: the procedures that read or manage "the" audit
/// log used a fixed /etc/geode/geode_audit.jsonl, or a logger of their own
/// in the working directory, unrelated to the log the server writes.
fn serverAuditLogger() ?*audit_mod.AuditLogger {
    audit_mod.global_audit_logger_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer audit_mod.global_audit_logger_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const logger = audit_mod.global_audit_logger orelse return null;
    if (!logger.config.enabled) return null;
    return logger;
}

// CANARY: REQ=REQ-SONNY-6340-NO-FABRICATED-PROCEDURES; FEATURE="AuditProcedures"; ASPECT=RefuseFabricated; STATUS=TESTED; TEST=tests/test_sonny6340_no_fabricated_procedures.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6340: audit.* procedures that reported work they did not do are
/// refused with error.Unsupported (SQLSTATE 0A000). They returned
/// `compliant` / `passed` / `valid` with no check, named report and export
/// files under /tmp that were never written, said `logged=true` without
/// logging, counted hard-coded "anomalies", "threat indicators", "SIEM
/// alerts" and "privilege escalations", reported disk space and memory
/// figures that were constants, wrote synthetic events (one second of them,
/// or 1000) into the server's real audit log, or "configured" a logger of
/// their own in the working directory that the server never used. None of
/// them is implemented; verify the audit log offline with `geode audit
/// verify --file <log> --pubkey <trusted key>`.
const refused_procedures = std.StaticStringMap(void).initComptime(.{
    .{ "audit.configure", {} },
    .{ "audit.log_auth_event", {} },
    .{ "audit.log_lifecycle_event", {} },
    .{ "audit.get_recent_events", {} },
    .{ "audit.verify_hash_chain", {} },
    .{ "audit.comprehensive_integrity_check", {} },
    .{ "audit.test_command_categories", {} },
    .{ "audit.test_data_access_categories", {} },
    .{ "audit.configure_rotation", {} },
    .{ "audit.simulate_windows_eventlog", {} },
    .{ "audit.simulate_syslog_output", {} },
    .{ "audit.test_combined_output", {} },
    .{ "audit.test_siem_correlation", {} },
    .{ "audit.test_siem_alerts", {} },
    .{ "audit.generate_compliance_report", {} },
    .{ "audit.test_powershell_compatibility", {} },
    .{ "audit.test_rotation_continuity", {} },
    .{ "audit.configure_retention", {} },
    .{ "audit.detect_anomalies", {} },
    .{ "audit.extract_threat_indicators", {} },
    .{ "audit.detect_privilege_escalation", {} },
    .{ "audit.performance_test", {} },
    .{ "audit.memory_usage_test", {} },
    .{ "audit.concurrent_access_test", {} },
    .{ "audit.test_disk_space_handling", {} },
    .{ "audit.test_corruption_handling", {} },
    .{ "audit.test_invalid_config", {} },
    .{ "audit.export_for_verification", {} },
    .{ "audit.prepare_forensic_package", {} },
    .{ "audit.compliance_verification", {} },
});

// ---------------------------------------------------------------------------
// StaticStringMap dispatch table — O(1) lookup.
// All handlers share a uniform signature: (allocator, call_stmt) -> !ExecutionResult.
// ---------------------------------------------------------------------------
const AuditHandler = *const fn (std.mem.Allocator, ast.CallProcedure) anyerror!ExecutionResult;

const dispatch_table = std.StaticStringMap(AuditHandler).initComptime(.{
    .{ "audit.test_signature_verification", handleAuditTestSignatureVerification },
    .{ "audit.get_merkle_digests", handleAuditGetMerkleDigests },
    .{ "audit.test_file_output", handleAuditTestFileOutput },
    .{ "audit.test_auth_categories", handleAuditTestAuthCategories },
    .{ "audit.cleanup_log_files", handleAuditCleanupLogFiles },
    .{ "audit.cleanup_test_artifacts", handleAuditCleanupTestArtifacts },
});

/// Execute an audit.* procedure. Returns null if not recognized.
pub fn execute(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
) !?ExecutionResult {
    if (refused_procedures.has(proc_name)) {
        log.warn("{s} is not supported: it reported results it did not produce (SONNY-6340); verify the audit log offline with `geode audit verify --file <log> --pubkey <trusted key>`", .{proc_name});
        return error.Unsupported;
    }
    if (dispatch_table.get(proc_name)) |handler| {
        return try handler(allocator, call_stmt);
    }

    // Not an audit.* procedure we recognize
    return null;
}

// ===========================================================================
// Handler functions
// ===========================================================================

fn handleAuditTestSignatureVerification(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-AUDIT-PROC-006; FEATURE="AuditProcedures"; ASPECT=SignatureVerification; STATUS=TESTED; TEST=geodetestlab/specs/geode_audit_logging_enterprise.yml; OWNER=audit; UPDATED=2026-01-15
    // audit.test_signature_verification() -> verified, signatures_checked, failures

    // Test Ed25519 signature verification
    var signatures_checked: i64 = 0;
    var failures: i64 = 0;
    var verified = true;

    // Generate a test keypair via the FIPS seam
    var keypair = cb.Sig.generate(.ed25519) catch {
        // Return error if keypair generation fails
        const columns = try allocator.alloc([]const u8, 3);
        columns[0] = try allocator.dupe(u8, "verified");
        columns[1] = try allocator.dupe(u8, "signatures_checked");
        columns[2] = try allocator.dupe(u8, "failures");

        const rows = try allocator.alloc([]Value, 1);
        const row = try allocator.alloc(Value, 3);
        row[0] = Value{ .Bool = false };
        row[1] = Value{ .Int = 0 };
        row[2] = Value{ .Int = 1 };
        rows[0] = row;

        return ExecutionResult{
            .columns = columns,
            .rows = rows,
            .flags = std.ArrayList([]const u8).empty,
        };
    };
    defer keypair.deinit();

    // Create test messages and sign them
    const messages = [_][]const u8{
        "Test audit event 1",
        "Test audit event 2",
        "Test audit event 3",
    };

    for (messages) |msg| {
        // Sign the message via the FIPS seam
        var sig_buf: [128]u8 = undefined;
        const sig_len = cb.Sig.sign(.ed25519, &keypair, msg, &sig_buf) catch {
            failures += 1;
            verified = false;
            continue;
        };
        signatures_checked += 1;

        // Verify the signature via the FIPS seam
        cb.Sig.verify(.ed25519, &keypair, msg, sig_buf[0..sig_len]) catch {
            failures += 1;
            verified = false;
        };

        // Test invalid signature detection: corrupt the first byte
        var bad_sig_buf: [128]u8 = undefined;
        @memcpy(bad_sig_buf[0..sig_len], sig_buf[0..sig_len]);
        bad_sig_buf[0] ^= 0xFF;
        signatures_checked += 1;

        cb.Sig.verify(.ed25519, &keypair, msg, bad_sig_buf[0..sig_len]) catch {
            // This should fail - expected behavior
            continue;
        };

        // If we get here, the bad signature was incorrectly accepted
        failures += 1;
        verified = false;
    }

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "verified");
    columns[1] = try allocator.dupe(u8, "signatures_checked");
    columns[2] = try allocator.dupe(u8, "failures");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Bool = verified };
    row[1] = Value{ .Int = signatures_checked };
    row[2] = Value{ .Int = failures };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleAuditGetMerkleDigests(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-SONNY-6340-NO-FABRICATED-PROCEDURES; FEATURE="AuditProcedures"; ASPECT=MerkleOfServerLog; STATUS=TESTED; TEST=tests/test_sonny6340_no_fabricated_procedures.zig; OWNER=security; UPDATED=2026-11-12
    // audit.get_merkle_digests() -> root_hash, leaf_count, tree_height
    // A Merkle tree over the lines of the server's audit log: SHA-256 of each
    // non-empty line as the leaves, pairs hashed level by level, an odd node
    // paired with itself. SONNY-6340 / SONNY-6346 item 4: it read the fixed
    // /etc/geode/geode_audit.jsonl (empty tree when absent) and only its
    // first MiB. The whole file is read under the logger's mutex, so no
    // half-written record is hashed. Without a server audit log it refuses.
    const logger = serverAuditLogger() orelse {
        log.warn("audit.get_merkle_digests: the server writes no audit log (enable it with GEODE_AUDIT_ENABLED=1)", .{});
        return error.Unsupported;
    };

    var leaves = try std.ArrayList([32]u8).initCapacity(allocator, 16);
    defer leaves.deinit(allocator);
    {
        const io_ad2 = std.Io.Threaded.global_single_threaded.io();
        logger.mutex.lockUncancelable(io_ad2);
        defer logger.mutex.unlock(io_ad2);
        const content = try std.Io.Dir.cwd().readFileAlloc(io_ad2, logger.config.file_path, allocator, .unlimited);
        defer allocator.free(content);
        var lines_iter = std.mem.splitScalar(u8, content, '\n');
        while (lines_iter.next()) |line| {
            if (line.len == 0) continue;
            var leaf_hash: [32]u8 = undefined;
            _ = try cb.Hash.digest(.sha256, line, &leaf_hash);
            try leaves.append(allocator, leaf_hash);
        }
    }

    // Calculate tree height
    const leaf_count = leaves.items.len;
    var tree_height: i64 = 0;
    if (leaf_count > 0) {
        var n = leaf_count;
        while (n > 1) : (n = (n + 1) / 2) {
            tree_height += 1;
        }
    }

    // Compute Merkle root
    var root_hash: [32]u8 = [_]u8{0} ** 32;
    if (leaves.items.len > 0) {
        // Build the tree level by level
        var current_level = try allocator.alloc([32]u8, leaves.items.len);
        defer allocator.free(current_level);
        @memcpy(current_level, leaves.items);

        while (current_level.len > 1) {
            const next_size = (current_level.len + 1) / 2;
            const next_level = try allocator.alloc([32]u8, next_size);

            var i: usize = 0;
            var j: usize = 0;
            while (i < current_level.len) : ({
                i += 2;
                j += 1;
            }) {
                var hasher = try cb.Hash.Stream.init(.sha256);
                defer hasher.deinit();
                try hasher.update(&current_level[i]);
                if (i + 1 < current_level.len) {
                    try hasher.update(&current_level[i + 1]);
                } else {
                    // Odd number of nodes - duplicate the last one
                    try hasher.update(&current_level[i]);
                }
                _ = try hasher.final(&next_level[j]);
            }

            allocator.free(current_level);
            current_level = next_level;
        }

        root_hash = current_level[0];
    }

    const hex_buf = std.fmt.bytesToHex(root_hash, .lower);

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "root_hash");
    columns[1] = try allocator.dupe(u8, "leaf_count");
    columns[2] = try allocator.dupe(u8, "tree_height");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Str = try allocator.dupe(u8, &hex_buf) };
    row[1] = Value{ .Int = @intCast(leaf_count) };
    row[2] = Value{ .Int = tree_height };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleAuditTestFileOutput(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-AUDIT-PROC-009; FEATURE="AuditProcedures"; ASPECT=FileOutput; STATUS=TESTED; TEST=geodetestlab/specs/geode_audit_logging_enterprise.yml; OWNER=audit; UPDATED=2026-01-15
    // audit.test_file_output() -> success, file_path, events_written

    // SONNY-6325: a private file in the data directory (was a fixed /tmp path).
    const test_file_path = try diagnosticPath("test_file_output.jsonl");
    defer std.heap.smp_allocator.free(test_file_path);

    var success = false;
    var events_written: i64 = 0;

    // Write test audit events to file
    const io_ad3 = std.Io.Threaded.global_single_threaded.io();
    if (openDiagnosticFile(test_file_path)) |file| {
        defer file.close(io_ad3);

        // Write sample audit events in JSONL format
        const test_events = [_][]const u8{
            "{\"timestamp\":1729350000000,\"event_type\":\"access_granted\",\"resource\":\"table1\",\"action\":\"SELECT\",\"user_id\":1001}",
            "{\"timestamp\":1729350001000,\"event_type\":\"access_denied\",\"resource\":\"table2\",\"action\":\"UPDATE\",\"user_id\":1002}",
            "{\"timestamp\":1729350002000,\"event_type\":\"authentication_failure\",\"resource\":\"login\",\"action\":\"authenticate\",\"user_id\":null}",
        };

        var cur_offset: u64 = 0;
        for (test_events) |event| {
            file.writePositionalAll(io_ad3, event, cur_offset) catch continue;
            cur_offset += event.len;
            file.writePositionalAll(io_ad3, "\n", cur_offset) catch continue;
            cur_offset += 1;
            events_written += 1;
        }

        success = true;

        // Also write using the global audit logger if initialized
        global_audit_logger_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_audit_logger_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        initDiagnosticLoggerLocked("audit_diagnostics.jsonl", false);

        if (global_audit_logger) |*logger| {
            // Log additional test event
            if (logger.logEvent(.{
                .timestamp = compat_milliTimestamp(),
                .event_type = .access_granted,
                .user_id = 1003,
                .tenant_id = null,
                .resource = "test_file_output",
                .action = "TEST",
                .policy_id = null,
                .reason = null,
                .ip_address = null,
                .session_id = null,
                .query_hash = null,
                .additional_context = null,
            })) |_| {
                events_written += 1;
            } else |err| {
                // error-policy: C — the procedure reports events_written; do not
                // count an event the logger failed to write.
                log.warn("audit test event write failed: {s}", .{@errorName(err)});
            }
        }
    } else |_| {
        success = false;
    }

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "success");
    columns[1] = try allocator.dupe(u8, "file_path");
    columns[2] = try allocator.dupe(u8, "events_written");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Bool = success };
    row[1] = Value{ .Str = try allocator.dupe(u8, test_file_path) };
    row[2] = Value{ .Int = events_written };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleAuditTestAuthCategories(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-AUDIT-PROC-010; FEATURE="AuditProcedures"; ASPECT=AuthCategories; STATUS=TESTED; TEST=geodetestlab/specs/geode_audit_logging_enterprise.yml; OWNER=audit; UPDATED=2026-01-15
    // audit.test_auth_categories() -> category, events_logged, success

    // Test different authentication event categories
    const auth_categories = [_]struct {
        category: []const u8,
        event_type: audit_mod.AuditEventType,
        resource: []const u8,
        action: []const u8,
    }{
        .{ .category = "login_success", .event_type = .access_granted, .resource = "system", .action = "LOGIN" },
        .{ .category = "login_failure", .event_type = .authentication_failure, .resource = "system", .action = "LOGIN" },
        .{ .category = "logout", .event_type = .access_granted, .resource = "system", .action = "LOGOUT" },
        .{ .category = "token_auth", .event_type = .access_granted, .resource = "api", .action = "TOKEN_AUTH" },
        .{ .category = "mfa_challenge", .event_type = .access_granted, .resource = "mfa", .action = "VERIFY" },
    };

    // Initialize audit logger if needed
    global_audit_logger_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_audit_logger_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    initDiagnosticLoggerLocked("audit_diagnostics.jsonl", false);

    // Create result rows for multiple categories
    const rows = try allocator.alloc([]Value, auth_categories.len);

    for (auth_categories, 0..) |cat, i| {
        var events_logged: i64 = 0;
        var success = false;

        if (global_audit_logger) |*logger| {
            // Log test event for this category
            if (logger.logEvent(.{
                .timestamp = compat_milliTimestamp(),
                .event_type = cat.event_type,
                .user_id = 1000 + @as(u64, @intCast(i)),
                .tenant_id = null,
                .resource = cat.resource,
                .action = cat.action,
                .policy_id = null,
                .reason = cat.category,
                .ip_address = "127.0.0.1",
                .session_id = "test_session",
                .query_hash = null,
                .additional_context = null,
            })) |_| {
                events_logged = 1;
                success = true;
            } else |err| {
                // error-policy: C — the per-category row reports events_logged/
                // success; do not claim success for a failed audit write.
                log.warn("audit category test event write failed ({s}): {s}", .{ cat.category, @errorName(err) });
            }
        }

        const row = try allocator.alloc(Value, 3);
        row[0] = Value{ .Str = try allocator.dupe(u8, cat.category) };
        row[1] = Value{ .Int = events_logged };
        row[2] = Value{ .Bool = success };
        rows[i] = row;
    }

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "category");
    columns[1] = try allocator.dupe(u8, "events_logged");
    columns[2] = try allocator.dupe(u8, "success");

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleAuditCleanupLogFiles(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-AUDIT-PROC-023; FEATURE="AuditProcedures"; ASPECT=LogCleanup; STATUS=TESTED; TEST=tests/test_sonny6346_silent_degrade_audit_housekeeping.zig; OWNER=audit; UPDATED=2026-11-12
    // audit.cleanup_log_files() -> success, files_deleted, space_freed_bytes
    // Deletes the server audit log's rotated files older than its retention.
    // SONNY-6340: it opened a logger of its own (on the query's allocator) in
    // the working directory when the dispatch module had none, and cleaned
    // that, not the server's log. Without a server audit log it refuses.
    const logger = serverAuditLogger() orelse {
        log.warn("audit.cleanup_log_files: the server writes no audit log (enable it with GEODE_AUDIT_ENABLED=1)", .{});
        return error.Unsupported;
    };
    const cleanup_result = try logger.cleanupOldLogs();

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "success");
    columns[1] = try allocator.dupe(u8, "files_deleted");
    columns[2] = try allocator.dupe(u8, "space_freed_bytes");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Bool = true };
    row[1] = Value{ .Int = @intCast(cleanup_result.files_deleted) };
    row[2] = Value{ .Int = @intCast(cleanup_result.bytes_freed) };
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}

fn handleAuditCleanupTestArtifacts(allocator: std.mem.Allocator, _: ast.CallProcedure) anyerror!ExecutionResult {
    // CANARY: REQ=REQ-AUDIT-PROC-036; FEATURE="AuditProcedures"; ASPECT=TestCleanup; STATUS=TESTED; TEST=geodetestlab/specs/geode_audit_logging_enterprise.yml; OWNER=audit; UPDATED=2026-01-15
    // audit.cleanup_test_artifacts() -> files_cleaned, logs_archived, test_data_removed

    // SONNY-6325: remove the diagnostic files in <data dir>/audit-diagnostics
    // only (never following a link out of it). This used to delete fixed
    // /tmp paths and /etc/geode/geode_audit.jsonl. The diagnostic logger's
    // own file and keys stay while the logger is open.
    var files_cleaned: i64 = 0;
    var removed_all = true;
    global_audit_logger_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_audit_logger_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const io_ct = std.Io.Threaded.global_single_threaded.io();
    if (diagnosticsDir(allocator)) |dir_path| {
        defer allocator.free(dir_path);
        if (std.Io.Dir.cwd().openDir(io_ct, dir_path, .{ .iterate = true })) |dir_const| {
            var dir = dir_const;
            defer dir.close(io_ct);
            const keep: []const u8 = if (diagnostic_logger_path) |p| std.fs.path.basename(p) else "";
            var it = dir.iterate();
            while (it.next(io_ct) catch null) |entry| {
                if (entry.kind != .file and entry.kind != .sym_link) continue;
                if (keep.len > 0 and std.mem.startsWith(u8, entry.name, keep)) continue;
                dir.deleteFile(io_ct, entry.name) catch {
                    removed_all = false;
                    continue;
                };
                files_cleaned += 1;
            }
        } else |_| {
            removed_all = false;
        }
    } else |err| {
        removed_all = false;
        log.warn("audit diagnostics directory unavailable: {s}", .{@errorName(err)});
    }

    const columns = try allocator.alloc([]const u8, 3);
    columns[0] = try allocator.dupe(u8, "files_cleaned");
    columns[1] = try allocator.dupe(u8, "logs_archived");
    columns[2] = try allocator.dupe(u8, "test_data_removed");

    const rows = try allocator.alloc([]Value, 1);
    const row = try allocator.alloc(Value, 3);
    row[0] = Value{ .Int = files_cleaned };
    // SONNY-6340: nothing is archived, and the data was removed only if
    // every file could be deleted (both were a constant true).
    row[1] = Value{ .Bool = false }; // logs_archived
    row[2] = Value{ .Bool = removed_all }; // test_data_removed
    rows[0] = row;

    return ExecutionResult{
        .columns = columns,
        .rows = rows,
        .flags = std.ArrayList([]const u8).empty,
    };
}
