/// Procedure Registry — Thin Dispatch Router
///
/// Routes procedure calls to domain-specific dispatch modules:
///   - algo_dispatch:    algo.* (centrality, community detection, traversals, graph stats)
///   - audit_dispatch:   audit.* (logging, integrity, SIEM, compliance)
///   - storage_dispatch: tde.*, cdc.*, geode.fle.*, geode.storage.*, geode.backup.*
///   - auth_dispatch:    geode.auth.* (user management, roles, policies, API keys, MFA)
///
/// Originally a 5,300+ line monolith; refactored into domain modules for maintainability.
const std = @import("std");
const ast = @import("../gql/ast.zig");
const graph_store = @import("../graph_store.zig");
const value_types = @import("../value_types.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-SLOG-003; FEATURE="Structured Logging"; ASPECT=Execution; STATUS=EXEMPT; OWNER=execution; UPDATED=2026-01-24
const logging = @import("logging");
const log = logging.scoped("execution");
const Attr = logging.Attr;

const execution = @import("../execution.zig");
const ExecutionResult = execution.ExecutionResult;
const ExecutionContext = execution.ExecutionContext;
const ExecutionError = execution.ExecutionError;

const procedure_access = @import("procedure_access.zig");
const execution_helpers = @import("execution_helpers.zig");
const gps = @import("../security/gps.zig");
const session_graph = @import("session_graph.zig");

// Import recursion handler for member path building
const recursion_handler = @import("recursion_handler.zig");

// CANARY: REQ=REQ-EXEC-REFACTOR-006; FEATURE="ExecutionRefactoring"; ASPECT=PROCEDURE_REGISTRY; STATUS=TESTED; TEST=tests/test_gap0883_algo_procedures.zig; OWNER=refactor; UPDATED=2026-11-12

// ==================== Domain Dispatch Modules ====================
const algo_dispatch = @import("algo_dispatch.zig");
const audit_dispatch = @import("audit_dispatch.zig");
const storage_dispatch = @import("storage_dispatch.zig");
const auth_dispatch = @import("auth_dispatch.zig");
const meta_dispatch = @import("meta_dispatch.zig");
const rls_dispatch = @import("rls_dispatch.zig");
const fts_dispatch = @import("fts_dispatch.zig");
const ts_dispatch = @import("ts_dispatch.zig");
const tenant_dispatch = @import("tenant_dispatch.zig");
const fle_admin = @import("fle_admin.zig");

// ==================== Re-exported Public Accessors ====================
// These must remain on procedure_registry since external code imports them.

/// SONNY-6561: the CDC_DIAGNOSTICS / CDC_CONTROL frames, answered the same on
/// every transport.
pub const CdcRefusal = storage_dispatch.CdcRefusal;
pub const cdcDiagnosticsAnswer = storage_dispatch.cdcDiagnosticsAnswer;
pub const cdcControlAnswer = storage_dispatch.cdcControlAnswer;
pub const CdcActor = storage_dispatch.CdcActor;
pub const auditCdcFrameRefusal = storage_dispatch.auditCdcFrameRefusal;

// ==================== Main Dispatch Entry Point ====================

/// Extract the original-case procedure name from a CallProcedure AST node.
/// Returns an owned slice for member paths (caller must free) or a borrowed
/// slice for identifier callees (valid for the lifetime of the AST).
/// The `out_owned` flag tells the caller whether the returned slice was
/// heap-allocated and must be freed.
pub fn extractOriginalProcName(
    allocator: std.mem.Allocator,
    call_stmt: ast.CallProcedure,
    out_owned: *bool,
) ![]const u8 {
    out_owned.* = false;
    return switch (call_stmt.procedure) {
        .Call => |call| blk: {
            if (call.callee.* == .Ident) {
                break :blk call.callee.Ident.orig;
            } else if (call.callee.* == .Member) {
                var name_parts = std.ArrayList(u8).empty;
                defer name_parts.deinit(allocator);
                try recursion_handler.buildMemberPath(allocator, call.callee, &name_parts);
                out_owned.* = true;
                break :blk try name_parts.toOwnedSlice(allocator);
            }
            break :blk "unknown";
        },
        else => "unknown",
    };
}

/// Extract the procedure name and normalize it to ASCII lowercase for
/// case-insensitive dispatch, per ISO/IEC 39075:2024 RQ-0022.
/// The returned slice is always owned by the caller and must be freed.
pub fn extractNormalizedProcName(
    allocator: std.mem.Allocator,
    call_stmt: ast.CallProcedure,
) ![]u8 {
    var orig_owned = false;
    const orig = try extractOriginalProcName(allocator, call_stmt, &orig_owned);
    defer if (orig_owned) allocator.free(orig);
    return try std.ascii.allocLowerString(allocator, orig);
}

pub fn executeCallProcedure(allocator: std.mem.Allocator, call_stmt: ast.CallProcedure, context: ExecutionContext) !ExecutionResult {
    // SONNY-2755: a YIELD that names a column twice is refused before the
    // procedure runs (the YIELD filter would free that column twice, and a
    // procedure that changes something must not run for a failing statement).
    if (call_stmt.yield_items) |items| try execution_helpers.requireDistinctYieldNames(items);

    // Get the procedure name from the Call expression, normalized to ASCII
    // lowercase for case-insensitive dispatch per ISO/IEC 39075:2024 RQ-0022.
    // CANARY: REQ=REQ-GQL-CASE-INSENSITIVE-002; FEATURE="CaseInsensitiveProcedures"; ASPECT=Dispatch; STATUS=TESTED; TEST=src/execution/procedure_registry.zig; OWNER=execution; UPDATED=2026-04-10
    const proc_name = try extractNormalizedProcName(allocator, call_stmt);
    defer allocator.free(proc_name);

    // CANARY: REQ=REQ-GPS-PROC-001; FEATURE="GPS Procedure Enforcement"; ASPECT=DispatchGate; STATUS=TESTED; TEST=tests/test_gps_procedure_enforcement.zig; OWNER=security; UPDATED=2026-05-20
    // CANARY: REQ=REQ-GPS-INVARIANT-001; FEATURE="GPS Fail-Open Catalog"; ASPECT=ClassifierUnused; STATUS=COMPLETE; OWNER=security; UPDATED=2026-05-20
    // Phase 5 task 5-1: mandatory GPS decision before any procedure body executes.
    // The procedure_access classifier maps proc_name to .read_only or .mutating;
    // we remap to the corresponding GPS action (.read / .write) so that the
    // builtin-role evaluation in decide() produces bit-identical results to the
    // legacy hasPermission() gate. For procedures with no entry in the classifier
    // table (unknown), we fall back to the raw .execute_procedure action, which
    // requires an explicit Policy match (or Admin role) — preserving fail-closed.
    // SONNY-6334: FLE and TDE key administration is Admin only (it was the
    // GPS `.write` gate below, so a ReadWrite user could grant its own FLE
    // role plaintext access). Checked first, so every refusal is audited.
    if (storage_dispatch.isKeyAdministrationProcedure(proc_name)) try fle_admin.requireAdmin(allocator, proc_name, context);
    // SONNY-6570: every cdc.* procedure is CDC administration, Admin only as
    // the CDC_DIAGNOSTICS / CDC_CONTROL frames are (a readwrite or readonly
    // user read cdc.status() and ran cdc.enable() / cdc.disable()).
    if (storage_dispatch.isCdcProcedure(proc_name)) try fle_admin.requireAdminFor(allocator, proc_name, context, "CDC administration");

    if (context.principal) |princ| {
        const access_class = procedure_access.classifyProcedureName(proc_name);
        const action_for_gate: gps.Action = switch (access_class) {
            .read_only => .read,
            .mutating => .write,
        };
        // SONNY-2753: and no deny scoped to the graph the procedure runs on
        // (the default graph for the fulltext procedures, SONNY-2790). A
        // deny scoped to one graph used to match every procedure, on every
        // graph.
        const proc_graph = if (procedure_access.isDefaultGraphProcedure(call_stmt)) graph_store.DEFAULT_GRAPH_NAME else session_graph.current(context);
        if (!try gps.procedurePermitted(allocator, princ, action_for_gate, proc_name, proc_graph)) return error.Unauthorized;
    }

    // Get the graph store
    const store = graph_store.getGlobalStore(allocator);

    // ---- db.* and dbms.* introspection procedures (GAP-0531) ----
    // db.labels(), db.relationshipTypes(), db.propertyKeys(), db.indexes(),
    // db.constraints(), dbms.procedures(), dbms.functions()
    if (std.mem.startsWith(u8, proc_name, "db.") or std.mem.startsWith(u8, proc_name, "dbms.")) {
        if (try meta_dispatch.execute(allocator, proc_name, store, call_stmt, context)) |result| {
            return result;
        }
    }

    // ---- algo.* procedures (centrality, community, traversals, graph stats) ----
    if (try algo_dispatch.execute(allocator, proc_name, store, call_stmt, context)) |result| {
        return result;
    }

    // ---- audit.* procedures (logging, integrity, SIEM, compliance) ----
    if (std.mem.startsWith(u8, proc_name, "audit.")) {
        if (try audit_dispatch.execute(allocator, proc_name, call_stmt)) |result| {
            return result;
        }
    }

    // ---- tde.* procedures (encryption, key management) ----
    if (std.mem.startsWith(u8, proc_name, "tde.")) {
        if (try storage_dispatch.executeTde(allocator, proc_name, call_stmt)) |result| {
            return result;
        }
    }

    // ---- cdc.* procedures (change data capture) ----
    if (std.mem.startsWith(u8, proc_name, "cdc.")) {
        // SONNY-6570: a change to the CDC engine is an audit event, whether
        // it succeeds or fails.
        const audited = storage_dispatch.isAuditedCdcChange(proc_name);
        const actor: storage_dispatch.CdcActor = .{
            .username = context.user orelse "",
            .user_id = if (context.principal) |p| (p.user_id orelse 0) else 0,
        };
        const cdc_result = storage_dispatch.executeCdc(allocator, proc_name, call_stmt) catch |err| {
            if (audited) storage_dispatch.auditCdcChange(allocator, proc_name, actor, "", @errorName(err));
            return err;
        };
        if (cdc_result) |result| {
            if (audited) storage_dispatch.auditCdcChange(allocator, proc_name, actor, "", null);
            return result;
        }
    }

    // ---- geode.fle.* procedures (field-level encryption) ----
    if (std.mem.startsWith(u8, proc_name, "geode.fle.")) {
        // SONNY-6334: a configureField / grant / revoke is an audit event,
        // whether it succeeds or fails.
        const audited = storage_dispatch.isAuditedFleChange(proc_name);
        // SONNY-6688: the migration needs the session (tenant, graph gate).
        if (std.mem.eql(u8, proc_name, "geode.fle.migrateencrypt")) {
            const migrated = storage_dispatch.executeFleMigrate(allocator, call_stmt, context) catch |err| {
                fle_admin.auditChange(allocator, proc_name, call_stmt, context, err);
                return err;
            };
            fle_admin.auditChange(allocator, proc_name, call_stmt, context, null);
            return migrated;
        }
        const fle_result = storage_dispatch.executeFle(allocator, proc_name, call_stmt) catch |err| {
            if (audited) fle_admin.auditChange(allocator, proc_name, call_stmt, context, err);
            return err;
        };
        if (fle_result) |result| {
            if (audited) fle_admin.auditChange(allocator, proc_name, call_stmt, context, null);
            return result;
        }
    }

    // ---- geode.auth.* procedures (user management, roles, MFA, API keys) ----
    if (std.mem.startsWith(u8, proc_name, "geode.auth.")) {
        if (try auth_dispatch.execute(allocator, proc_name, call_stmt, context)) |result| {
            return result;
        }
    }

    // ---- geode.rls.* procedures (row-level-security deny policies) ----
    if (std.mem.startsWith(u8, proc_name, "geode.rls.")) {
        if (try rls_dispatch.execute(allocator, proc_name, call_stmt, context)) |result| {
            return result;
        }
    }

    // ---- geode.storage.* procedures (storage inspection) ----
    if (std.mem.startsWith(u8, proc_name, "geode.storage.")) {
        if (try storage_dispatch.executeStorage(allocator, proc_name, call_stmt, context)) |result| {
            return result;
        }
    }

    // ---- geode.fts.* procedures (full-text search) ----
    // CANARY: REQ=REQ-GQL-FTS-PROC-001; FEATURE="CALL geode.fts.search YIELD node,score"; ASPECT=Dispatch; STATUS=TESTED; TEST=tests/test_fts_e2e.zig; OWNER=index; UPDATED=2026-05-31
    if (std.mem.startsWith(u8, proc_name, "geode.fts.")) {
        if (try fts_dispatch.execute(allocator, proc_name, call_stmt, context)) |result| {
            return result;
        }
    }

    // ---- geode.ts.* procedures (timeseries: insert/insert_many/range/last/bucket_avg/sample_by) ----
    // CANARY: REQ=REQ-GQL-TS-PROC-001; FEATURE="CALL geode.ts.* native timeseries surface"; ASPECT=Dispatch; STATUS=TESTED; TEST=tests/ts_ingest_roundtrip.zig; OWNER=timeseries; UPDATED=2026-05-31
    if (std.mem.startsWith(u8, proc_name, "geode.ts.")) {
        if (try ts_dispatch.execute(allocator, proc_name, call_stmt, context)) |result| {
            return result;
        }
    }

    // ---- geode.tenant.* procedures (tenant lifecycle: create/list/show/drop/set_quota) ----
    // CANARY: REQ=REQ-TENANT-LIFECYCLE-002; FEATURE="CALL geode.tenant.* native tenant lifecycle surface"; ASPECT=Dispatch; STATUS=TESTED; TEST=tests/test_gap0839_tenant_lifecycle.zig; OWNER=security; UPDATED=2026-06-08
    // GAP-0839: each handler re-checks the admin_tenant GPS action internally
    // (the generic gate above only maps to .read/.write); see tenant_dispatch.
    if (std.mem.startsWith(u8, proc_name, "geode.tenant.")) {
        if (try tenant_dispatch.execute(allocator, proc_name, call_stmt, context)) |result| {
            return result;
        }
    }

    // Unknown procedure
    log.warn("Unknown procedure", &.{
        Attr.string("procedure", proc_name),
    });
    return ExecutionError.UnknownProcedure;
}
