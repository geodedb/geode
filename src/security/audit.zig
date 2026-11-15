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

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const cb = @import("crypto_backend");
const rls = @import("rls");
const Allocator = std.mem.Allocator;
const pooled = @import("transport/thread_pool");
const logging = @import("logging");
const log = logging.scoped("security");
const Attr = logging.Attr;

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-005; FEATURE="External Library Migration"; ASPECT=SecurityAudit; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-24
// External JSON library for RFC 8259 compliant encoding in security audit reports
const json_lib = @import("json");

// Phase C2: OTel audit instrumentation. recordAuditEvent fires on the single
// write funnel (appendEventLocked); recordAuditDropped fires where a producer
// swallows an append error. Both take only bounded enum tag names.
const otel_metrics = @import("otel_metrics");

/// Map the audit Result enum onto the OTel Outcome enum. Both are bounded.
fn auditResultToOutcome(r: AuditEvent.Result) otel_metrics.Outcome {
    return switch (r) {
        .success => .success,
        .failure => .error_,
        .partial => .partial_success,
        .error_ => .error_,
    };
}

/// JSON structure for compliance reports
const ComplianceReportJson = struct {
    report_date: i64,
    start_time: i64,
    end_time: i64,
    total_events: u64,
    violations: u64,
    compliant: u64,
    compliance_rate: f64,
};

/// JSON structure for forensic package metadata
const ForensicMetadataJson = struct {
    timestamp: i64,
    system: []const u8 = "geode",
    version: []const u8 = "1.0.0",
    audit_enabled: bool,
};

/// JSON structure for export event records
const ExportEventJson = struct {
    timestamp: i64,
    event_type: []const u8 = "access_granted",
    user_id: u64,
};

// Use AuditEvent from RLS to ensure consistency and access the new fields
pub const AuditEvent = rls.AuditLogger.AuditEvent;
pub const AuditEventType = rls.AuditLogger.AuditEvent.EventType;

pub const SecurityGraphEvent = struct {
    event_type: AuditEventType = .configuration_change,
    action: []const u8,
    user_id: u64 = 0,
    username: []const u8 = "",
    details: ?[]const u8 = null,
    // GAP-0919: denials are audited too — a failure result raises severity to
    // warning and records result=failure instead of the success default.
    result_failure: bool = false,
    // SONNY-6598: the operation could not be carried out (a server-side
    // error, not a denial): severity err, result error_.
    result_error: bool = false,
    // SONNY-2728: the graph the event is about, when it is a user graph (a
    // statement refused on it) rather than the security graph.
    resource_graph: ?[]const u8 = null,
};

pub var global_audit_logger: ?*AuditLogger = null;
pub var global_audit_logger_mutex: std.Io.Mutex = std.Io.Mutex.init;

// CANARY: REQ=REQ-SONNY-6322-AUDIT-KEY-EPOCH; FEATURE="AuditDurability"; ASPECT=KeyEpochs; STATUS=TESTED; TEST=tests/test_sonny6322_audit_seed_and_hmac_startup.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-6322: audit signing-key epochs. The file-backed key pair of a log
/// `F` is `F.key` (the Ed25519 seed, 0600, never in a backup) and the public
/// key of each epoch: `F.pub` for epoch 0, `F.pub.<n>` for epoch n. A log
/// that has a public key but no seed (a restored store: backups leave the
/// seed out) starts epoch n+1 with a new pair; the old public key files are
/// never changed, and a KEY_EPOCH record is appended to the log:
/// event_type system_event, resource {type "audit_key_epoch", id
/// "epoch-<n>:<new public key hex>"} (both inside event_hash), action
/// "KEY_EPOCH", signed by the NEW key. The previous key is gone, so it cannot
/// sign the hand-over: continuity across the boundary rests on the hash chain
/// and on the operator who restored the store, not on the previous key.
pub const key_epoch_resource_type = "audit_key_epoch";
pub const key_epoch_action = "KEY_EPOCH";
/// Upper bound on the epochs scanned for `F.pub.<n>`.
pub const max_key_epochs: u32 = 4096;

/// Create a key file with O_CREAT | O_EXCL | O_NOFOLLOW, mode 0600 (set again
/// on the open file): nothing already at the path is followed or replaced.
fn writeKeyFileExclusive(path: []const u8, bytes: []const u8) !void {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0o600) catch |err| switch (err) {
        error.PathAlreadyExists => return error.AuditKeyFileExists,
        else => return err,
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    const file = std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(io);
    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try file.setPermissions(io, std.Io.File.Permissions.fromMode(0o600));
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

fn keyFileExists(path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

// GAP-0282: Per-thread tenant_id for audit event enrichment.
// Set from the QUIC connection handler before query execution so that all
// audit events created on this thread carry the correct tenant context.
// CANARY: REQ=REQ-AUDIT-TENANT-001; FEATURE="AuditTenantId"; ASPECT=PerThreadTenant; STATUS=IMPL; OWNER=security; UPDATED=2026-04-05
var audit_tenant_mutex: std.Io.Mutex = std.Io.Mutex.init;
var audit_tenant_gpa: std.heap.DebugAllocator(.{}) = std.heap.DebugAllocator(.{}){};
var per_thread_audit_tenants: std.AutoHashMap(std.Thread.Id, []const u8) = std.AutoHashMap(std.Thread.Id, []const u8).init(audit_tenant_gpa.allocator());

/// Set the current tenant_id for audit events on this thread.
pub fn setCurrentAuditTenantId(tenant_id: ?[]const u8) void {
    audit_tenant_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer audit_tenant_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const tid = std.Thread.getCurrentId();
    if (tenant_id) |t| {
        per_thread_audit_tenants.put(tid, t) catch {
            _ = per_thread_audit_tenants.remove(tid);
        };
    } else {
        _ = per_thread_audit_tenants.remove(tid);
    }
}

/// Get the current tenant_id for audit events. Returns null if not set.
pub fn getCurrentAuditTenantId() ?[]const u8 {
    audit_tenant_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer audit_tenant_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    return per_thread_audit_tenants.get(std.Thread.getCurrentId());
}

pub fn setGlobalAuditLogger(logger: ?*AuditLogger) void {
    global_audit_logger_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_audit_logger_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    global_audit_logger = logger;
}

pub fn logSecurityGraphEvent(allocator: Allocator, event: SecurityGraphEvent) void {
    global_audit_logger_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    const logger = global_audit_logger;
    global_audit_logger_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    if (logger == null or !logger.?.enabled) return;

    var detail_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = detail_map.iterator();
        while (it.next()) |entry| allocator.free(entry.value_ptr.*);
        detail_map.deinit();
    }

    if (event.username.len != 0) {
        detail_map.put("username", allocator.dupe(u8, event.username) catch return) catch return;
    }
    if (event.details) |details| {
        detail_map.put("details", allocator.dupe(u8, details) catch return) catch return;
    }

    // GAP-0282: Populate tenant_id from per-thread audit context
    var audit_event = AuditEvent{
        .timestamp = compat_milliTimestamp(),
        .event_type = event.event_type,
        .severity = if (event.result_error) .err else if (event.result_failure) .warning else .info,
        .tenant_id = getCurrentAuditTenantId(),
        .user_id = event.user_id,
        .session_id = "",
        .resource = .{
            .type = "graph",
            .id = event.resource_graph orelse "__geode_security",
            .name = event.resource_graph orelse "__geode_security",
            .graph = event.resource_graph orelse "__geode_security",
            .table = null,
        },
        .action = event.action,
        .result = if (event.result_error) .error_ else if (event.result_failure) .failure else .success,
        .details = detail_map,
    };
    logger.?.appendAuditEvent(&audit_event) catch |err| {
        log.warn("Failed to append security graph audit event", &.{
            Attr.string("action", event.action),
            Attr.string("error", @errorName(err)),
        });
        // Phase C2: a security-graph audit event was produced but its append
        // failed and is being swallowed here — a genuine drop. The reason is a
        // bounded constant (the append error type, not user content).
        otel_metrics.recordAuditDropped(.append_error);
    };
}

// CANARY: REQ=REQ-SONNY-6598-AUTH-ERROR-AUDIT; FEATURE="AuthOutcomeClassification"; ASPECT=LoginRefusalAudit; STATUS=TESTED; TEST=tests/test_sonny6598_kdf_error_hello.zig; OWNER=security; UPDATED=2026-11-15
/// SONNY-6598: the audit record of a HELLO that did not log in (both
/// transports), from `authenticate()`'s error. A rejected credential
/// (`error.Unauthenticated`) is a failed login: authentication_failure,
/// action LOGIN, result failure. Any other error is a check the server could
/// not carry out (the password KDF out of memory, an unusable stored hash,
/// the security store unavailable): system_event, action AUTH_ERROR, result
/// error_, with the error name. The user name is the one the client sent
/// (at most 256 bytes of it); the password is never recorded.
pub fn logLoginRefusal(allocator: Allocator, username: []const u8, err: anyerror) void {
    const name = username[0..@min(username.len, 256)];
    if (err == error.Unauthenticated) {
        logSecurityGraphEvent(allocator, .{
            .event_type = .authentication_failure,
            .action = "LOGIN",
            .username = name,
            .details = "credentials rejected",
            .result_failure = true,
        });
        return;
    }
    var buf: [160]u8 = undefined;
    const details = std.fmt.bufPrint(&buf, "auth-system error, not a failed login: {s}", .{@errorName(err)}) catch "auth-system error, not a failed login";
    logSecurityGraphEvent(allocator, .{
        .event_type = .system_event,
        .action = "AUTH_ERROR",
        .username = name,
        .details = details,
        .result_error = true,
    });
}

pub const AuditLogger = struct {
    const DigestBuf = std.ArrayList([32]u8);
    /// SONNY-6322: a KEY_EPOCH record to append once the chain tail is loaded.
    const PendingEpoch = struct {
        n: u32,
        public_hex: [64]u8,
        previous_public_hex: [64]u8,
    };
    allocator: Allocator,
    file: ?std.Io.File,
    mutex: std.Io.Mutex,
    config: Config,

    // State for chaining and signing
    enabled: bool,
    last_hash: [32]u8,
    last_seq: u64,
    digest_buf: std.ArrayList([32]u8),
    digest_interval_events: u32,

    // Signing keys
    signing_key: ?cb.Sig.KeyPair,

    // Heap-allocated file path owned by this logger (set by `initForGraph`).
    // When non-null, freed in `deinit`. Avoids @constCast on Config.file_path.
    owned_path: ?[]u8 = null,

    // SONNY-6322: the signing key's epoch (0 = `F.pub`, n = `F.pub.<n>`), the
    // KEY_EPOCH record still to append once the chain tail is loaded, and
    // whether the record being appended is that internal record (the only
    // one allowed to use the reserved resource type).
    key_epoch: u32 = 0,
    pending_epoch: ?PendingEpoch = null,
    appending_epoch_record: bool = false,

    // Config fields from original file (preserved/extended)
    retention_days: u32,
    tamper_protected: bool,
    encrypted: bool,
    log_access_events: bool,

    // GAP-0920: mid-run audit-write-failure health. `write_degraded` latches
    // true on the first failed record write and clears on the next success;
    // `write_failure_count` monotonically counts drops. Both are queryable so
    // operators/health checks can observe a silent audit gap.
    write_degraded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    write_failure_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// GAP-0920: true iff the most recent record write failed (audit integrity
    /// is degraded until the next successful write).
    pub fn isWriteDegraded(self: *const AuditLogger) bool {
        return self.write_degraded.load(.acquire);
    }

    /// GAP-0920: total number of audit records dropped by write failures.
    pub fn writeFailureCount(self: *const AuditLogger) u64 {
        return self.write_failure_count.load(.acquire);
    }

    /// SONNY-3147: the uncovered tail of a record line and its newline.
    fn finishLine(w: *std.Io.Writer, ev: *const AuditEvent) !void {
        try AuditEvent.writeHashSuffix(w, ev);
        try w.writeAll("\n");
    }

    /// GAP-0920: positionally append one serialized record line. Extracted
    /// so the write funnel can catch its failure in one place.
    fn writeChain(f: std.Io.File, line: []const u8) !void {
        const io_aw = std.Io.Threaded.global_single_threaded.io();
        const st = try f.stat(io_aw);
        try f.writePositionalAll(io_aw, line, st.size);
    }

    pub const Config = struct {
        enabled: bool = false, // Disabled by default; enable with GEODE_AUDIT_ENABLED=1 or via config
        file_path: []const u8 = "audit.jsonl",
        redact_pii: bool = true,
        log_denies_only: bool = false,
        rotation_size_mb: u32 = 100,
        retention_days: u32 = 90,
        tamper_protected: bool = false,
        encrypted: bool = false,
        log_access_events: bool = true,
        digest_interval: u32 = 100,
    };

    pub fn init(allocator: Allocator, config: Config) !AuditLogger {
        var logger = AuditLogger{
            .allocator = allocator,
            .file = null,
            .mutex = std.Io.Mutex.init,
            .config = config,
            .enabled = config.enabled,
            .last_hash = [_]u8{0} ** 32,
            .last_seq = 0,
            .digest_buf = try DigestBuf.initCapacity(allocator, 32),
            .digest_interval_events = config.digest_interval,
            .signing_key = null,
            .retention_days = config.retention_days,
            .tamper_protected = config.tamper_protected,
            .encrypted = config.encrypted,
            .log_access_events = config.log_access_events,
        };
        // Ensure cleanup of digest_buf on error after this point
        errdefer logger.digest_buf.deinit(allocator);

        if (config.enabled) {
            // 1. Open File
            logger.file = std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.io(), config.file_path, .{
                .truncate = false,
                .read = true, // Needed for initFromTail
                .exclusive = false,
                .permissions = std.Io.File.Permissions.fromMode(0o600),
            }) catch |err| {
                return err;
            };
            // Ensure file is closed on subsequent errors
            errdefer if (logger.file) |f| f.close(std.Io.Threaded.global_single_threaded.io());

            // 2. Load Keys
            try logger.loadKeys();

            // 3. Init from Tail (Recover state)
            try logger.initFromTail();

            // 4. SONNY-6322: a new key epoch is recorded in the chain.
            if (logger.pending_epoch) |pe| {
                try logger.appendKeyEpochLocked(pe);
                logger.pending_epoch = null;
            }
        }

        return logger;
    }

    // CANARY: REQ=REQ-GAP-0908-AUDIT-SINK-FAILCLOSED; FEATURE="AuditStartup"; ASPECT=LeakSafeCreate; STATUS=TESTED; TEST=tests/test_gap0908_0909_startup_failclosed.zig; OWNER=security; UPDATED=2026-07-10
    /// GAP-0908: heap-create the process-global audit logger with a leak-safe
    /// error path. An unopenable sink (e.g. EACCES) propagates as a typed
    /// error with the allocation released, so the caller can refuse startup
    /// cleanly (fail-closed) instead of crashing with an unhandled error and
    /// leaking the logger allocation.
    pub fn createHeap(allocator: Allocator, config: Config) !*AuditLogger {
        const logger = try allocator.create(AuditLogger);
        errdefer allocator.destroy(logger);
        logger.* = try AuditLogger.init(allocator, config);
        return logger;
    }

    /// Create an audit logger that writes to `{graph_dir}/audit.jsonl`.
    /// The caller-supplied `graph_dir` path is duped and owned by the
    /// returned logger (freed on `deinit`).
    pub fn initForGraph(allocator: Allocator, graph_dir: []const u8) !AuditLogger {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/audit.jsonl", .{graph_dir});
        errdefer allocator.free(file_path);

        // Ensure the graph directory exists so the file create succeeds.
        std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), graph_dir) catch |err| {
            log.warn("failed to create graph audit dir", &.{
                Attr.string("path", graph_dir),
                Attr.string("error", @errorName(err)),
            });
            return err;
        };

        var cfg = Config{
            .enabled = true,
            .file_path = file_path,
        };

        // Inherit env-based overrides for redaction / rotation.
        if (getEnvVarOwned(allocator, "GEODE_AUDIT_REDACT_PII")) |v| {
            cfg.redact_pii = std.mem.eql(u8, v, "1");
            allocator.free(v);
        } else |_| {}

        var logger = try init(allocator, cfg);
        logger.owned_path = file_path;
        return logger;
    }

    pub fn deinit(self: *AuditLogger) void {
        // SONNY-3147: a clean close signs the records written since the last
        // DIGEST, so a cleanly closed log ends with a signed DIGEST.
        if (self.config.enabled and self.file != null and self.digest_buf.items.len > 0) {
            self.emitDigestLocked() catch |err| {
                log.warn("Failed to emit the closing audit digest", &.{Attr.string("error", @errorName(err))});
            };
        }
        self.digest_buf.deinit(self.allocator);
        if (self.file) |f| {
            f.close(std.Io.Threaded.global_single_threaded.io());
        }
        if (self.owned_path) |p| {
            self.allocator.free(p);
        }
        if (self.signing_key) |*kp| kp.deinit();
    }

    fn loadKeys(self: *AuditLogger) !void {
        if (try loadEnvSigningKey(self.allocator)) |kp| {
            self.signing_key = kp;
            return;
        }
        try self.loadOrCreateFileBackedKeys();
    }

    // CANARY: REQ=REQ-SONNY-6422-ENV-KEY-FAIL-CLOSED; FEATURE="Key configuration"; ASPECT=AuditKeyPairComplete; STATUS=TESTED; TEST=tests/test_sonny6422_env_key_fail_closed.zig; OWNER=security; UPDATED=2026-11-12
    /// The audit signing key from GEODE_AUDIT_PUB (64 hex characters, the
    /// Ed25519 public key) and GEODE_AUDIT_SEC (64 hex characters, the seed;
    /// the legacy 128-character secret key is accepted), or null when
    /// neither is set (an empty value counts as unset): the logger then uses
    /// file-based keys beside the log.
    ///
    /// SONNY-6422: only one of the two set, a malformed value, or a public
    /// key that is not the seed's is an error. One of the pair alone used to
    /// fall back to generating file-based keys, so a half-configured pair
    /// signed with a key the operator never saw. No key bytes are logged.
    pub fn loadEnvSigningKey(allocator: Allocator) !?cb.Sig.KeyPair {
        const pub_raw = getEnvVarOwned(allocator, "GEODE_AUDIT_PUB") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        defer if (pub_raw) |p| allocator.free(p);
        const sec_raw = getEnvVarOwned(allocator, "GEODE_AUDIT_SEC") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        defer if (sec_raw) |s| {
            std.crypto.secureZero(u8, s);
            allocator.free(s);
        };
        const pub_hex: ?[]const u8 = if (pub_raw) |p| (if (p.len == 0) null else p) else null;
        const sec_hex: ?[]const u8 = if (sec_raw) |s| (if (s.len == 0) null else s) else null;

        if (pub_hex == null and sec_hex == null) return null;
        if (pub_hex == null or sec_hex == null) {
            log.err("GEODE_AUDIT_PUB and GEODE_AUDIT_SEC must be set together; only one is set", &.{
                Attr.boolean("pub_set", pub_hex != null),
                Attr.boolean("sec_set", sec_hex != null),
            });
            return error.AuditKeyPairIncomplete;
        }
        const ph = pub_hex.?;
        const sh = sec_hex.?;
        if (ph.len != 64 or (sh.len != 64 and sh.len != 128)) {
            log.err("Invalid key length in env vars", &.{
                Attr.int("pub_key_len", @intCast(ph.len)),
                Attr.int("sec_key_len", @intCast(sh.len)),
                Attr.int("expected_pub_len", 64),
                Attr.int("expected_sec_len", 64),
            });
            return error.AuditKeyInvalid;
        }
        const seed_hex: []const u8 = if (sh.len == 128) blk: {
            log.warn("GEODE_AUDIT_SEC legacy 128-char format; using embedded 32-byte seed — re-export the 64-char seed to silence.", &.{});
            break :blk sh[0..64];
        } else sh;
        var seed: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed);
        _ = std.fmt.hexToBytes(&seed, seed_hex) catch return error.AuditKeyInvalid;
        var want_pub: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&want_pub, ph) catch return error.AuditKeyInvalid;
        var kp = try cb.Sig.KeyPair.fromPrivateBytes(.ed25519, &seed);
        errdefer kp.deinit();
        var got_pub: [32]u8 = undefined;
        _ = try kp.publicBytes(&got_pub);
        if (!std.mem.eql(u8, &got_pub, &want_pub)) {
            log.err("GEODE_AUDIT_PUB is not the public key of GEODE_AUDIT_SEC", &.{});
            return error.AuditKeyMismatch;
        }
        return kp;
    }

    fn loadOrCreateFileBackedKeys(self: *AuditLogger) !void {
        const pub_path = try std.fmt.allocPrint(self.allocator, "{s}.pub", .{self.config.file_path});
        defer self.allocator.free(pub_path);
        const sec_path = try std.fmt.allocPrint(self.allocator, "{s}.key", .{self.config.file_path});
        defer self.allocator.free(sec_path);

        // SONNY-6322: the newest epoch's public key file (`F.pub.<n>`, else `F.pub`).
        var newest: u32 = 0;
        while (newest < max_key_epochs) : (newest += 1) {
            var nbuf: [std.fs.max_path_bytes]u8 = undefined;
            const p = std.fmt.bufPrint(&nbuf, "{s}.pub.{d}", .{ self.config.file_path, newest + 1 }) catch break;
            if (!keyFileExists(p)) break;
        }
        const newest_pub_path = if (newest == 0)
            try self.allocator.dupe(u8, pub_path)
        else
            try std.fmt.allocPrint(self.allocator, "{s}.pub.{d}", .{ self.config.file_path, newest });
        defer self.allocator.free(newest_pub_path);

        const io_rf = std.Io.Threaded.global_single_threaded.io();
        const pub_hex_raw = std.Io.Dir.cwd().readFileAlloc(io_rf, newest_pub_path, self.allocator, .limited(256)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (pub_hex_raw) |bytes| self.allocator.free(bytes);
        const pub_hex: ?[]const u8 = if (pub_hex_raw) |b| std.mem.trim(u8, b, " \t\r\n") else null;

        const sec_hex_raw = std.Io.Dir.cwd().readFileAlloc(io_rf, sec_path, self.allocator, .limited(512)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (sec_hex_raw) |bytes| {
            std.crypto.secureZero(u8, bytes);
            self.allocator.free(bytes);
        };
        const sec_hex: ?[]const u8 = if (sec_hex_raw) |b| std.mem.trim(u8, b, " \t\r\n") else null;

        if (sec_hex) |sh| {
            if (sh.len != 64 and sh.len != 128) return error.ConfigError;
            if (pub_hex) |ph| if (ph.len != 64) return error.ConfigError;
            const seed_hex: []const u8 = if (sh.len == 128) blk: {
                log.warn("GEODE_AUDIT_SEC legacy 128-char format; using embedded 32-byte seed — re-export the 64-char seed to silence.", &.{});
                break :blk sh[0..64];
            } else sh;
            var seed: [32]u8 = undefined;
            defer std.crypto.secureZero(u8, &seed);
            _ = try std.fmt.hexToBytes(&seed, seed_hex);
            var kp = try cb.Sig.KeyPair.fromPrivateBytes(.ed25519, &seed);
            if (pub_hex == null) {
                // A seed without a public key file: record the public key
                // (exclusively; nothing existing is replaced).
                var pb: [32]u8 = undefined;
                _ = try kp.publicBytes(&pb);
                const ph = std.fmt.bytesToHex(pb, .lower);
                writeKeyFileExclusive(newest_pub_path, &ph) catch |err| {
                    kp.deinit();
                    return err;
                };
            }
            self.signing_key = kp;
            self.key_epoch = newest;
            return;
        }

        var kp = try cb.Sig.generate(.ed25519);
        errdefer kp.deinit();
        var pub_bytes: [32]u8 = undefined;
        _ = try kp.publicBytes(&pub_bytes);
        var seed_bytes: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &seed_bytes);
        _ = try kp.privateSeed(&seed_bytes);
        const generated_pub = std.fmt.bytesToHex(pub_bytes, .lower);
        var generated_sec = std.fmt.bytesToHex(seed_bytes, .lower);
        defer std.crypto.secureZero(u8, &generated_sec);

        if (pub_hex) |old_pub| {
            // SONNY-6322: a public key but no seed — a restored store (backups
            // leave the seed out). The old public key file must keep
            // verifying the entries it signed, so it is never truncated:
            // start epoch newest+1 with a new pair in `F.pub.<n>`.
            if (old_pub.len != 64) return error.ConfigError;
            const n = newest + 1;
            if (n > max_key_epochs) return error.TooManyAuditKeyEpochs;
            const new_pub_path = try std.fmt.allocPrint(self.allocator, "{s}.pub.{d}", .{ self.config.file_path, n });
            defer self.allocator.free(new_pub_path);
            try writeKeyFileExclusive(new_pub_path, &generated_pub);
            try writeKeyFileExclusive(sec_path, &generated_sec);
            var prev: [64]u8 = undefined;
            @memcpy(&prev, old_pub[0..64]);
            self.pending_epoch = .{ .n = n, .public_hex = generated_pub, .previous_public_hex = prev };
            self.key_epoch = n;
            log.warn("audit signing seed missing (restored store?); started a new audit key epoch", &.{
                Attr.string("path", self.config.file_path),
                Attr.int("epoch", @intCast(n)),
            });
            std.debug.print(
                "[audit] {s}: the signing seed is missing (a restored store?); started audit key epoch {d}, public key in {s}. " ++
                    "Entries before it verify with the previous public key ({s}); continuity across the boundary is attested by the operator who restored the store, not by the previous key.\n",
                .{ self.config.file_path, n, new_pub_path, newest_pub_path },
            );
        } else {
            try writeKeyFileExclusive(pub_path, &generated_pub);
            try writeKeyFileExclusive(sec_path, &generated_sec);
            self.key_epoch = 0;
            log.info("Generated audit signing keys", &.{Attr.string("path", self.config.file_path)});
        }
        self.signing_key = kp;

        std.log.warn("Audit signing keys stored as files. Set GEODE_AUDIT_PUB and GEODE_AUDIT_SEC env vars for production.", .{});
    }

    /// SONNY-6322: append the KEY_EPOCH record of `pe`, signed by the new key
    /// (see `key_epoch_resource_type`). Caller holds the mutex or is `init`.
    fn appendKeyEpochLocked(self: *AuditLogger, pe: PendingEpoch) !void {
        var id_buf: [96]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "epoch-{d}:{s}", .{ pe.n, &pe.public_hex });
        var epoch_buf: [16]u8 = undefined;
        const epoch_str = try std.fmt.bufPrint(&epoch_buf, "{d}", .{pe.n});
        var details = std.StringHashMap([]const u8).init(self.allocator);
        defer details.deinit();
        try details.put("epoch", epoch_str);
        try details.put("previous_public_key", &pe.previous_public_hex);
        try details.put("continuity", "attested by the restore operator; the previous key did not sign this record");
        var ev = AuditEvent{
            .timestamp = compat_milliTimestamp(),
            .event_type = .system_event,
            .severity = .warning,
            .user_id = 0,
            .session_id = "",
            .resource = .{ .type = key_epoch_resource_type, .id = id, .name = "audit key epoch", .graph = null, .table = null },
            .action = key_epoch_action,
            .result = .success,
            .details = details,
        };
        self.appending_epoch_record = true;
        defer self.appending_epoch_record = false;
        try self.appendEventLocked(&ev);
    }

    fn initFromTail(self: *AuditLogger) !void {
        const f = self.file orelse return;
        const io_tail = std.Io.Threaded.global_single_threaded.io();
        const stat = try f.stat(io_tail);
        if (stat.size == 0) return;

        const read_size = @min(stat.size, 4096);
        const start_pos = stat.size - read_size;

        const buf = try self.allocator.alloc(u8, read_size);
        defer self.allocator.free(buf);
        const n = try f.readPositionalAll(io_tail, buf, start_pos);
        const data = buf[0..n];

        var last_line: []const u8 = "";
        var it = std.mem.splitBackwardsScalar(u8, data, '\n');

        while (it.next()) |line| {
            if (line.len > 0) {
                last_line = line;
                break;
            }
        }

        if (last_line.len == 0) return;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, last_line, .{}) catch |err| {
            log.warn("Ignored trailing partial record (non-fatal)", &.{
                Attr.string("error", @errorName(err)),
            });
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root.object.get("seq_no")) |val| {
            self.last_seq = @intCast(val.integer);
        }
        if (root.object.get("event_hash")) |val| {
            const hex = val.string;
            if (hex.len == 64) {
                // Decode into a scratch buffer so a mid-decode failure cannot
                // leave self.last_hash partially overwritten.
                var decoded: [32]u8 = undefined;
                if (std.fmt.hexToBytes(&decoded, hex)) |_| {
                    self.last_hash = decoded;
                } else |err| {
                    // error-policy: B — a malformed tail anchor must not brick
                    // startup, but silently restarting the hash chain would hide
                    // tampering or corruption; warn loudly and keep the zero anchor.
                    log.warn("audit tail event_hash undecodable; hash chain restarts from zero anchor", &.{
                        Attr.string("error", @errorName(err)),
                    });
                }
            }
        }
        // Note: Zig 0.16 removed seekFromEnd. File appends now use
        // writePositionalAll with explicit stat().size offsets instead.
    }

    pub fn appendAuditEvent(self: *AuditLogger, ev: *AuditEvent) !void {
        // Defense-in-depth: short-circuit when auditing is disabled so no
        // mutex acquire, no hash chain work, no fsync happen on a logger
        // whose init skipped file creation anyway.  Matches the gate in
        // `logEvent` (line 544).  Callers already check
        // `resolveAuditLogger` (`src/server/quic_connection_handler.zig:
        // 2140-2163`) which returns null for non-security graphs in the
        // default config, but this gate makes the invariant local.
        if (!self.config.enabled) return;
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        try self.appendEventLocked(ev);
    }

    /// Core event append logic — MUST be called with self.mutex already held.
    /// GAP-0512: Extracted from appendAuditEvent to break the recursive mutex
    /// deadlock where appendAuditEvent → emitDigest → appendAuditEvent caused
    /// SIGABRT from Zig's deadlock detector.
    fn appendEventLocked(self: *AuditLogger, ev: *AuditEvent) !void {
        // SONNY-6322: only the logger writes (and signs) a key-epoch record.
        const is_epoch_record = std.mem.eql(u8, ev.resource.type, key_epoch_resource_type);
        if (is_epoch_record and !self.appending_epoch_record) return error.ReservedAuditRecord;

        // GAP-0282: Enrich event with per-thread tenant_id if not already set
        if (ev.tenant_id == null) {
            ev.tenant_id = getCurrentAuditTenantId();
        }

        // GAP-0920: snapshot the chain state so a write failure can roll the
        // seq/hash advance back (see the write funnel below) — otherwise a
        // failed record still bumps the counter and hash, silently corrupting
        // the chain for the NEXT event.
        const prev_seq_snapshot = self.last_seq;
        const prev_hash_snapshot = self.last_hash;

        self.last_seq += 1;
        ev.seq_no = self.last_seq;

        var new_prev_hash: [32]u8 = undefined;
        _ = try cb.Hash.digest(.sha256, &self.last_hash, &new_prev_hash);
        ev.prev_hash = new_prev_hash;

        // CANARY: REQ=REQ-SONNY-3147-AUDIT-HASH-COVERAGE; FEATURE="AuditDurability"; ASPECT=WriterHashesWholeRecord; STATUS=TESTED; TEST=tests/test_sonny3147_audit_hash_coverage.zig; OWNER=security; UPDATED=2026-11-12
        // SONNY-3147: the event hash covers the whole record: the canonical
        // bytes the line is made of up to "prev_hash" (every field written,
        // in a fixed order), under the record kind's tag, with the previous
        // hash (AuditEvent.eventHashV2, hash format 2). It covered only
        // event_type, resource.id and action, so the timestamp, actor,
        // tenant, session, client address, reason, result, resource type and
        // details could be edited without breaking the chain. The body is
        // serialized once and hashed in place.
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        AuditEvent.writeCanonicalBody(&aw.writer, "geode", ev) catch |err| {
            self.last_seq = prev_seq_snapshot;
            return err;
        };
        const kind: AuditEvent.RecordKind = if (ev.event_type == .DIGEST)
            .digest
        else if (is_epoch_record)
            .key_epoch
        else
            .event;
        ev.event_hash = AuditEvent.eventHashV2(kind, &ev.prev_hash, aw.written());

        // Sign if it is a DIGEST, or the KEY_EPOCH record (SONNY-6322)
        if ((ev.event_type == .DIGEST or is_epoch_record) and self.signing_key != null) {
            var sig_out: [64]u8 = undefined;
            _ = cb.Sig.sign(.ed25519, &self.signing_key.?, ev.event_hash[0..], &sig_out) catch |err| {
                self.last_seq = prev_seq_snapshot;
                return err;
            };
            ev.signature = sig_out;
        }
        finishLine(&aw.writer, ev) catch |err| {
            self.last_seq = prev_seq_snapshot;
            return err;
        };

        self.last_hash = ev.event_hash;

        if (self.file) |f| {
            // CANARY: REQ=REQ-GAP-0920-AUDIT-WRITE-FAILURE-DIAGNOSTIC; FEATURE="AuditDurability"; ASPECT=MidRunWriteFailure; STATUS=TESTED; TEST=tests/test_gap0920_audit_write_failure.zig; OWNER=security; UPDATED=2026-07-10
            // GAP-0920: a genuine mid-run write failure (e.g. under
            // `prlimit --fsize` → EFBIG, or a full disk → ENOSPC) used to
            // produce zero diagnostic anywhere — a silent, invisible audit
            // gap. Emit a LOUD diagnostic at the single write funnel (so no
            // swallowing caller can hide it), flag the logger degraded, roll
            // the chain state back to keep it consistent, and re-raise.
            writeChain(f, aw.written()) catch |err| {
                self.last_seq = prev_seq_snapshot;
                self.last_hash = prev_hash_snapshot;
                self.write_degraded.store(true, .release);
                _ = self.write_failure_count.fetchAdd(1, .monotonic);
                log.err("AUDIT WRITE FAILED — event dropped, chain not advanced; audit integrity is DEGRADED", &.{
                    Attr.string("action", ev.action),
                    Attr.string("event_type", @tagName(ev.event_type)),
                    Attr.string("error", @errorName(err)),
                    Attr.string("sink", self.config.file_path),
                });
                otel_metrics.recordAuditDropped(.write_error);
                return err;
            };
            self.write_degraded.store(false, .release);
        }

        // Trigger digest after N events (but not for DIGEST events themselves)
        if (ev.event_type != .DIGEST) {
            try self.digest_buf.append(self.allocator, ev.event_hash);
            if (self.digest_buf.items.len >= self.digest_interval_events) {
                // Call emitDigestLocked directly — no re-locking needed
                self.emitDigestLocked() catch |err| {
                    log.warn("Failed to emit audit digest", &.{
                        Attr.string("error", @errorName(err)),
                    });
                };
            }
        }

        // Phase C2: this is the single funnel through which every audit event is
        // actually written. Reached only after the hash-chain + file write
        // succeed (the `try`s above propagate failures before this point), so a
        // sample here means the event was genuinely emitted. Both attributes are
        // bounded enum tag names — @tagName(EventType) and the mapped Result.
        otel_metrics.recordAuditEvent(@tagName(ev.event_type), auditResultToOutcome(ev.result));
    }

    /// Emit a Merkle digest event — MUST be called with self.mutex already held.
    /// GAP-0512: Renamed from emitDigest and calls appendEventLocked instead of
    /// appendAuditEvent to avoid recursive mutex acquisition.
    fn emitDigestLocked(self: *AuditLogger) anyerror!void {
        var hasher = try cb.Hash.Stream.init(.sha256);
        defer hasher.deinit();
        for (self.digest_buf.items) |h| {
            try hasher.update(&h);
        }
        var digest: [32]u8 = undefined;
        _ = try hasher.final(&digest);

        self.digest_buf.clearRetainingCapacity();

        var details = std.StringHashMap([]const u8).init(self.allocator);
        defer details.deinit();
        var hex_digest: [64]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (digest, 0..) |b, i| {
            hex_digest[i * 2] = hex_chars[b >> 4];
            hex_digest[i * 2 + 1] = hex_chars[b & 0x0F];
        }
        try details.put("merkle_root", &hex_digest);

        var ev = AuditEvent{
            .timestamp = compat_milliTimestamp(),
            .event_type = .DIGEST,
            .severity = .info,
            .user_id = 0,
            .session_id = "",
            .resource = .{ .type = "system", .id = "digest", .name = "merkle_digest", .graph = null, .table = null },
            .action = "EMIT_DIGEST",
            .result = .success,
            .details = details,
        };

        // Directly call the locked version — mutex is already held by caller
        try self.appendEventLocked(&ev);
    }

    pub fn logEvent(self: *AuditLogger, ev_in: anytype) !void {
        if (!self.config.enabled) return;

        const EvType = @TypeOf(ev_in);
        if (EvType == AuditEvent) {
            return self.appendAuditEvent(@constCast(&ev_in));
        }

        // Adapter for generic calls
        const resource_id: []const u8 = if (@hasField(EvType, "resource")) ev_in.resource else "unknown";
        const action: []const u8 = if (@hasField(EvType, "action")) ev_in.action else "unknown";
        const event_type_tag = if (@hasField(EvType, "event_type")) @tagName(ev_in.event_type) else "system_event";

        const et: AuditEventType = std.meta.stringToEnum(AuditEventType, event_type_tag) orelse .system_event;

        var detail_map: ?std.StringHashMap([]const u8) = null;
        if (@hasField(EvType, "tenant_id") or @hasField(EvType, "reason")) {
            var dm = std.StringHashMap([]const u8).init(self.allocator);
            if (@hasField(EvType, "tenant_id")) {
                const tid_any = ev_in.tenant_id;
                const is_opt = switch (@typeInfo(@TypeOf(tid_any))) {
                    .optional => true,
                    else => false,
                };
                const tid_opt: ?u64 = if (is_opt) tid_any else tid_any;
                if (tid_opt) |tid| {
                    var buf: [32]u8 = undefined;
                    const s = try std.fmt.bufPrint(&buf, "{}", .{tid});
                    try dm.put("tenant_id", try self.allocator.dupe(u8, s));
                }
            }
            if (@hasField(EvType, "reason")) {
                const r_any = ev_in.reason;
                const is_opt_r = switch (@typeInfo(@TypeOf(r_any))) {
                    .optional => true,
                    else => false,
                };
                const r_opt: ?[]const u8 = if (is_opt_r) r_any else r_any;
                if (r_opt) |r| {
                    try dm.put("reason", try self.allocator.dupe(u8, r));
                }
            }
            detail_map = dm;
        }

        var real_ev = AuditEvent{
            .timestamp = compat_milliTimestamp(),
            .event_type = et,
            .severity = .info,
            .user_id = 0,
            .session_id = "",
            .resource = .{ .type = "legacy", .id = resource_id, .name = resource_id, .graph = null, .table = null },
            .action = action,
            .result = .success,
            .details = detail_map,
        };

        try self.appendAuditEvent(&real_ev);

        if (detail_map) |*dm| {
            var it = dm.iterator();
            while (it.next()) |e| self.allocator.free(e.value_ptr.*);
            dm.deinit();
        }
    }

    pub fn logRlsDeny(self: *AuditLogger, ctx: *const rls.SecurityContext, resource: []const u8, reason: []const u8) !void {
        var dm = std.StringHashMap([]const u8).init(self.allocator);
        try dm.put("reason", try self.allocator.dupe(u8, reason));

        var ev = AuditEvent{
            .timestamp = compat_milliTimestamp(),
            .event_type = .policy_violation, // rls.AuditEventType
            .severity = .warning,
            .user_id = ctx.user_id,
            .session_id = ctx.session_id,
            .resource = .{ .type = "data", .id = resource, .name = resource, .graph = null, .table = null },
            .action = "read",
            .result = .failure,
            .details = dm,
        };
        try self.appendAuditEvent(&ev);

        var it = dm.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.*);
        dm.deinit();
    }

    pub fn logAbacDeny(self: *AuditLogger, ctx: *const rls.SecurityContext, rule: []const u8, resource: []const u8) !void {
        var dm = std.StringHashMap([]const u8).init(self.allocator);
        try dm.put("rule", try self.allocator.dupe(u8, rule));

        var ev = AuditEvent{
            .timestamp = compat_milliTimestamp(),
            .event_type = .policy_violation,
            .severity = .warning,
            .user_id = ctx.user_id,
            .session_id = ctx.session_id,
            .resource = .{ .type = "data", .id = resource, .name = resource, .graph = null, .table = null },
            .action = "access",
            .result = .failure,
            .details = dm,
        };
        try self.appendAuditEvent(&ev);

        var it = dm.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.*);
        dm.deinit();
    }

    // CANARY: REQ=REQ-SONNY-6346-NO-SILENT-DEGRADE; FEATURE="AuditDurability"; ASPECT=CleanupOwnDirectory; STATUS=TESTED; TEST=tests/test_sonny6346_silent_degrade_audit_housekeeping.zig; OWNER=security; UPDATED=2026-11-12
    /// Delete this log's rotated files (`<log file name>.<ms>`, beside the
    /// log) whose timestamp is older than `retention_days`. SONNY-6346: it
    /// scanned the WORKING directory for `audit.jsonl.<ts>`, so the log's
    /// own rotated files were never removed, a log of another name never
    /// cleaned, and matching files in the working directory deleted.
    pub fn cleanupOldLogs(self: *AuditLogger) !struct { files_deleted: u32, bytes_freed: u64 } {
        var files_deleted: u32 = 0;
        var bytes_freed: u64 = 0;

        const io_cl = std.Io.Threaded.global_single_threaded.io();
        const log_dir = std.fs.path.dirname(self.config.file_path) orelse ".";
        const base = std.fs.path.basename(self.config.file_path);
        var dir = try std.Io.Dir.cwd().openDir(io_cl, log_dir, .{ .iterate = true });
        defer dir.close(io_cl);

        var iter = dir.iterate();
        const cutoff_time = compat_milliTimestamp() - (@as(i64, @intCast(self.config.retention_days)) * 24 * 60 * 60 * 1000);

        while (try iter.next(io_cl)) |entry| {
            if (entry.kind != .file) continue;
            if (entry.name.len <= base.len + 1) continue;
            if (!std.mem.startsWith(u8, entry.name, base) or entry.name[base.len] != '.') continue;
            const timestamp_str = entry.name[base.len + 1 ..];
            const all_digits = for (timestamp_str) |c| {
                if (!std.ascii.isDigit(c)) break false;
            } else true;
            if (!all_digits) continue;
            const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch continue;
            if (timestamp >= cutoff_time) continue;

            const stat = try dir.statFile(io_cl, entry.name, .{ .follow_symlinks = false });
            try dir.deleteFile(io_cl, entry.name);
            files_deleted += 1;
            bytes_freed += stat.size;

            log.info("Audit log cleaned up", &.{
                Attr.string("deleted", entry.name),
                Attr.int("size", @intCast(stat.size)),
            });
        }

        return .{ .files_deleted = files_deleted, .bytes_freed = bytes_freed };
    }
};
