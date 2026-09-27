// CANARY: REQ=REQ-SONNY-2757-DURABLE-POLICY-DDL; FEATURE="GPS Policy Persistence"; ASPECT=DurableDdl; STATUS=TESTED; TEST=tests/test_sonny2757_policy_hygiene.zig; OWNER=security; UPDATED=2026-09-26
//
// SONNY-2757: the GPS policy changes, made durable or not at all. Shared by
// the policy DDL (CREATE / ALTER / DROP POLICY, execution.zig) and the
// geode.auth.policy_create / policy_delete procedures (auth_dispatch.zig).
//
// The server installs write-through hooks that persist each change to
// `__geode_security`. Before this:
// - (P25) ALTER and DROP POLICY changed the in-memory catalog, then only
//   logged a failed write-through. A revocation (a DROP, or the DISABLE of
//   an allow) held until the next restart, when the stored policy came back.
// - (P26) geode.auth.policy_create used the tolerant `addPolicy` (no length
//   limits, an expression that does not compile installed fail-closed) and
//   persisted nothing; policy_delete persisted nothing either, so a deleted
//   policy came back at the next restart.
// Now every change passes the DDL checks, and a failed write-through fails
// the statement with the catalog as it was. In a CLI or test context no
// hooks are installed and the catalog alone changes, as before.

const std = @import("std");
const policy_catalog = @import("../security/policy_catalog.zig");
const logging = @import("logging");
const log = logging.scoped("execution");
const Attr = logging.Attr;

const PolicyCatalog = policy_catalog.PolicyCatalog;

/// The policy named `name`, if the catalog has one.
fn find(pol_cat: *PolicyCatalog, name: []const u8) ?*const policy_catalog.Policy {
    for (pol_cat.listPolicies()) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// CREATE POLICY: the DDL checks (`addPolicyStrict`: lengths, a USING
/// expression that compiles, a unique name), then the write-through. If the
/// write-through fails the policy is taken out again and the error returned.
pub fn create(pol_cat: *PolicyCatalog, spec: policy_catalog.PolicySpec) !void {
    try pol_cat.addPolicyStrict(spec);
    const hooks = policy_catalog.getWriteThroughHooks() orelse return;
    hooks.persist(hooks.ctx, spec) catch |err| {
        log.warn("GPS policy persistence to __geode_security failed; the policy was not created", &.{
            Attr.string("name", spec.name),
            Attr.string("error", @errorName(err)),
        });
        pol_cat.removePolicy(spec.name) catch {};
        return err;
    };
}

pub const DropOutcome = enum { removed, not_found };

/// DROP POLICY. The stored record is deleted first, and the catalog entry
/// only once that succeeded: a failed write-through fails the statement and
/// changes nothing, so a revocation is never in memory only. A policy with no
/// stored record (the write-through reports PolicyNotFound) is dropped from
/// the catalog. `if_exists`: a missing policy is `.not_found`, not an error.
pub fn drop(pol_cat: *PolicyCatalog, name: []const u8, if_exists: bool) !DropOutcome {
    if (find(pol_cat, name) == null) {
        if (if_exists) return .not_found;
        return error.PolicyNotFound;
    }
    if (policy_catalog.getWriteThroughHooks()) |hooks| {
        hooks.drop(hooks.ctx, name) catch |err| {
            if (err != error.PolicyNotFound) {
                log.warn("GPS DROP POLICY persistence to __geode_security failed; the policy was not dropped", &.{
                    Attr.string("name", name),
                    Attr.string("error", @errorName(err)),
                });
                return err;
            }
        };
    }
    pol_cat.removePolicy(name) catch |err| {
        if (err == error.PolicyNotFound and if_exists) return .not_found;
        return err;
    };
    return .removed;
}

/// ALTER POLICY. The catalog change comes first (it checks the rename and
/// the name's length); if the write-through then fails, the catalog is put
/// back as it was (the name and the enabled flag) and the error returned.
pub fn alter(pol_cat: *PolicyCatalog, name: []const u8, set_enabled: ?bool, rename_to: ?[]const u8) !void {
    const old_enabled = (find(pol_cat, name) orelse return error.PolicyNotFound).enabled;
    try pol_cat.alterPolicy(name, set_enabled, rename_to);
    const hooks = policy_catalog.getWriteThroughHooks() orelse return;
    hooks.alter(hooks.ctx, name, set_enabled, rename_to) catch |err| {
        log.warn("GPS ALTER POLICY persistence to __geode_security failed; the change was undone", &.{
            Attr.string("name", name),
            Attr.string("error", @errorName(err)),
        });
        const current_name = rename_to orelse name;
        const back_to: ?[]const u8 = if (rename_to != null and !std.mem.eql(u8, current_name, name)) name else null;
        pol_cat.alterPolicy(current_name, old_enabled, back_to) catch |undo_err| {
            log.err("GPS ALTER POLICY could not be undone after its persistence failed; the catalog differs from __geode_security until restart", &.{
                Attr.string("name", current_name),
                Attr.string("error", @errorName(undo_err)),
            });
        };
        return err;
    };
}
