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

// Import recursion handler for member path building
const recursion_handler = @import("recursion_handler.zig");

// CANARY: REQ=REQ-EXEC-REFACTOR-006; FEATURE="ExecutionRefactoring"; ASPECT=PROCEDURE_REGISTRY; STATUS=TESTED; TEST=tests/test_performance_integration.zig; OWNER=refactor; UPDATED=2026-01-15

// ==================== Domain Dispatch Modules ====================
const algo_dispatch = @import("algo_dispatch.zig");
const audit_dispatch = @import("audit_dispatch.zig");
const storage_dispatch = @import("storage_dispatch.zig");
const auth_dispatch = @import("auth_dispatch.zig");
const meta_dispatch = @import("meta_dispatch.zig");

// ==================== Re-exported Public Accessors ====================
// These must remain on procedure_registry since external code imports them.

/// Public accessor so other transports (gRPC) can read the global CDC engine.
pub fn getGlobalCdcEngine() ?*@import("../streaming/cdc_enhanced.zig").CDCEngine {
    return storage_dispatch.getGlobalCdcEngine();
}

/// Public accessor for the CDC mutex so external transports (gRPC) can
/// acquire it before accessing the CDC engine.
pub fn getCdcMutex() *std.Io.Mutex {
    return storage_dispatch.getCdcMutex();
}

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

    // Get the procedure name from the Call expression, normalized to ASCII
    // lowercase for case-insensitive dispatch per ISO/IEC 39075:2024 RQ-0022.
    // CANARY: REQ=REQ-GQL-CASE-INSENSITIVE-002; FEATURE="CaseInsensitiveProcedures"; ASPECT=Dispatch; STATUS=TESTED; TEST=src/execution/procedure_registry.zig; OWNER=execution; UPDATED=2026-04-10
    const proc_name = try extractNormalizedProcName(allocator, call_stmt);
    defer allocator.free(proc_name);

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
        if (try storage_dispatch.executeCdc(allocator, proc_name, call_stmt)) |result| {
            return result;
        }
    }

    // ---- geode.fle.* procedures (field-level encryption) ----
    if (std.mem.startsWith(u8, proc_name, "geode.fle.")) {
        if (try storage_dispatch.executeFle(allocator, proc_name, call_stmt)) |result| {
            return result;
        }
    }

    // ---- geode.auth.* procedures (user management, roles, MFA, API keys) ----
    if (std.mem.startsWith(u8, proc_name, "geode.auth.")) {
        if (try auth_dispatch.execute(allocator, proc_name, call_stmt, context)) |result| {
            return result;
        }
    }

    // ---- geode.storage.* procedures (storage inspection) ----
    if (std.mem.startsWith(u8, proc_name, "geode.storage.")) {
        if (try storage_dispatch.executeStorage(allocator, proc_name, call_stmt)) |result| {
            return result;
        }
    }

    // Unknown procedure
    log.warn("Unknown procedure", &.{
        Attr.string("procedure", proc_name),
    });
    return ExecutionError.UnknownProcedure;
}
