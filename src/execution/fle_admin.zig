//! SONNY-6334: authorization and audit of FLE / TDE key administration.
//!
//! `geode.fle.configureField`, `grantPlaintext`, `revokePlaintext` and the
//! key-affecting `tde.*` procedures decide who reads which encrypted field in
//! plaintext, or change the keys. They were gated by the GPS `.write` action
//! like a data write, so a ReadWrite user could grant its own FLE role
//! plaintext access. They are security administration: Admin only, as the
//! auth DDL (`auth_dispatch.execute`) and the policy DDL
//! (`execution.requirePolicyDdlAdmin`) are, with the same contract:
//!   * authentication off (embedded use, tests): every caller is an
//!     implicit admin;
//!   * `--insecure-allow-all`: its documented bypass of authorization;
//!   * no authenticated role: 28000-class `Unauthenticated`;
//!   * any role but Admin: 42501 `Unauthorized`;
//! every refusal an `access_denied` audit event (GAP-0919), and every
//! configureField / grant / revoke an audit event, success or failure.
//! The offline `geode fle ...` CLI acts on the data directory with the
//! server stopped: whoever can run it owns the files (local admin).

const std = @import("std");
const ast = @import("../gql/ast.zig");
const execution = @import("../execution.zig");
const ExecutionContext = execution.ExecutionContext;

// CANARY: REQ=REQ-SONNY-6334-FLE-ADMIN-GATE; FEATURE="FieldLevelEncryption"; ASPECT=AdminOnlyKeyAdministration; STATUS=TESTED; TEST=tests/test_sonny6334_fle_authorization.zig; OWNER=security; UPDATED=2026-11-11
/// Admin only, or the refusal (audited). `proc_name` is lowercase.
pub fn requireAdmin(allocator: std.mem.Allocator, proc_name: []const u8, context: ExecutionContext) !void {
    return requireAdminFor(allocator, proc_name, context, "key administration");
}

/// `requireAdmin` for another kind of administration (`what` names it in
/// the refusal's audit record; SONNY-6570: CDC administration).
pub fn requireAdminFor(allocator: std.mem.Allocator, proc_name: []const u8, context: ExecutionContext, what: []const u8) !void {
    const gps = @import("../security/gps.zig");
    const user_mgmt = @import("../security/user_management.zig");
    if (gps.isInsecureAllowAll()) return;
    if (!user_mgmt.isAuthEnabled()) return;
    const om = @import("otel_metrics");
    const audit_mod = @import("../security/audit.zig");
    const duration = om.DurationTimer.start();
    var details_buf: [128]u8 = undefined;
    // The session's authenticated role; a context that carries only a
    // principal (in-process callers) is judged by the principal's roles.
    const authenticated = context.role != null or
        (if (context.principal) |p| p.username != null else false);
    const is_admin = if (context.role) |r| r == .Admin else principalIsAdmin(context);
    if (!authenticated) {
        om.recordAuthzCheck(.deny, .rbac, duration.seconds());
        audit_mod.logSecurityGraphEvent(allocator, .{
            .event_type = .access_denied,
            .action = proc_name,
            .username = context.user orelse "",
            .details = deniedDetails(&details_buf, what, "unauthenticated"),
            .result_failure = true,
        });
        return error.Unauthenticated;
    }
    if (!is_admin) {
        om.recordAuthzCheck(.deny, .rbac, duration.seconds());
        audit_mod.logSecurityGraphEvent(allocator, .{
            .event_type = .access_denied,
            .action = proc_name,
            .user_id = if (context.principal) |p| (p.user_id orelse 0) else 0,
            .username = context.user orelse "",
            .details = deniedDetails(&details_buf, what, "admin role required"),
            .result_failure = true,
        });
        return error.Unauthorized;
    }
    om.recordAuthzCheck(.allow, .rbac, duration.seconds());
}

fn deniedDetails(buf: []u8, what: []const u8, why: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s} denied: {s}", .{ what, why }) catch why;
}

fn principalIsAdmin(context: ExecutionContext) bool {
    const p = context.principal orelse return false;
    for (p.roles) |r| {
        if (std.mem.eql(u8, r, "Admin")) return true;
    }
    return false;
}

// CANARY: REQ=REQ-SONNY-6334-FLE-ADMIN-AUDIT; FEATURE="FieldLevelEncryption"; ASPECT=AuditedGrantRevokeConfigure; STATUS=TESTED; TEST=tests/test_sonny6334_fle_authorization.zig; OWNER=security; UPDATED=2026-11-11
/// The audit event of a configureField / grantPlaintext / revokePlaintext
/// that ran (`failure` null) or failed: the actor, the procedure, the
/// field as `type.field`, and the role (grant/revoke) or visibility roles
/// (configure). It carries no key material: these procedures handle none.
pub fn auditChange(
    allocator: std.mem.Allocator,
    proc_name: []const u8,
    call_stmt: ast.CallProcedure,
    context: ExecutionContext,
    failure: ?anyerror,
) void {
    const audit_mod = @import("../security/audit.zig");
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    describe(&w, proc_name, call_stmt) catch {};
    if (failure) |err| w.print(" error={s}", .{@errorName(err)}) catch {};
    audit_mod.logSecurityGraphEvent(allocator, .{
        .event_type = .configuration_change,
        .action = proc_name,
        .user_id = if (context.principal) |p| (p.user_id orelse 0) else 0,
        .username = context.user orelse "",
        .details = w.buffered(),
        .result_failure = failure != null,
    });
}

fn stringArg(args: []const *ast.Expr, i: usize) []const u8 {
    if (i >= args.len) return "?";
    return switch (args[i].*) {
        .String => |s| s,
        else => "?",
    };
}

/// `type.field role=<r>` or `type.field visibility=[a,b]`; for the FLE
/// role grants (SONNY-6341) `user=<u> role=<r>`.
fn describe(w: *std.Io.Writer, proc_name: []const u8, call_stmt: ast.CallProcedure) !void {
    if (call_stmt.procedure != .Call) return;
    const args = call_stmt.procedure.Call.args;
    if (std.mem.endsWith(u8, proc_name, "role")) {
        return w.print("user={s} role={s}", .{ stringArg(args, 0), stringArg(args, 1) });
    }
    try w.print("{s}.{s}", .{ stringArg(args, 0), stringArg(args, 1) });
    if (args.len < 3) return;
    switch (args[2].*) {
        .String => |r| try w.print(" role={s}", .{r}),
        .Map => |props| for (props) |prop| {
            if (!std.mem.eql(u8, prop.key, "visibility")) continue;
            const items: []const *ast.Expr = switch (prop.value.*) {
                .List => |l| l,
                .ArrayLit => |l| l,
                else => continue,
            };
            try w.writeAll(" visibility=[");
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeAll(",");
                if (item.* == .String) try w.writeAll(item.String);
            }
            try w.writeAll("]");
        },
        else => {},
    }
}
