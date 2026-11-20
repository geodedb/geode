// CANARY: REQ=REQ-GPS-PDP-008; FEATURE="GPS Canonical Principal"; ASPECT=RoleResolverModule; STATUS=TESTED; TEST=tests/test_gps_role_resolver.zig; OWNER=security; UPDATED=2026-05-20
//
// role_resolver.zig — extract authRoleFromRecord + resolveRoleFromGraph from
// src/server/main.zig so they can be used and unit-tested in isolation.
//
// Both functions are pure graph-traversal logic with no server-state
// dependencies; the only runtime inputs are a *GraphStore and a UserRecord.
// Moving them here gives the policy decision path (GPS Phase 4+) a stable
// import without pulling in the full server entrypoint.

const std = @import("std");
const geode = @import("geode");
// user_storage is a named module (not inside the geode lib module tree because
// user_storage itself imports geode, which would be circular). It is wired by
// build.zig as the "user_storage" named import on the role_resolver module.
const user_storage = @import("user_storage");

// CANARY: REQ=REQ-SEC-DEFAULT-ROLE-FAIL-CLOSED; FEATURE="FailClosedDefaultRole"; ASPECT=RecordFallback; STATUS=TESTED; TEST=tests/test_default_role_fail_closed.zig; OWNER=security; UPDATED=2026-10-11
/// Convert a UserRecord to a built-in Role without consulting the graph.
/// Returns .Admin when is_superuser is true, .None otherwise.
/// This is the fallback for a user with no stored role; prefer
/// resolveRoleFromGraph when a store is available.
///
/// Fail-closed default (2026-10): the fallback used to be .ReadWrite, so a
/// user whose record carried no built-in role (no HAS_ROLE edge, or one to a
/// role name that is not built in) could read and write every graph. It is
/// now .None: no global permission, and access only to the graphs the user
/// holds a per-graph grant on.
pub fn authRoleFromRecord(record: user_storage.UserStorageBackend.UserRecord) geode.user_management.Role {
    return if (record.is_superuser) .Admin else .None;
}

// CANARY: REQ=REQ-GPS-PDP-008; FEATURE="GPS Canonical Principal"; ASPECT=AuthRoleGraphLookupIsolated; STATUS=TESTED; TEST=tests/test_gps_role_resolver.zig; OWNER=security; UPDATED=2026-05-20
/// Resolve the user's built-in role from the __geode_security graph by
/// traversing the HAS_ROLE edge from the user node to the role node.  Falls
/// back to authRoleFromRecord (is_superuser→Admin, else None) when no
/// HAS_ROLE edge or recognisable role name is found.
///
/// This corrects a gap in authRoleFromRecord: it only checked is_superuser
/// and always fell back to the default role for non-admin users, even when a
/// `readonly` or `user` role had been persisted via writerCreateUser /
/// writerSetRole (which writes a HAS_ROLE edge + bumps auth_version, causing
/// the cache to be re-fetched from the graph on the next authentication).
pub fn resolveRoleFromGraph(store: *geode.graph_store.GraphStore, record: user_storage.UserStorageBackend.UserRecord) geode.user_management.Role {
    if (record.is_superuser) return .Admin;

    const SECURITY_GRAPH = "__geode_security";
    const USER_LABEL = "User";
    const HAS_ROLE = "HAS_ROLE";

    // Locate the user node by scanning User-labelled nodes in the security graph.
    const user_nodes_opt = store.getNodesByLabel(SECURITY_GRAPH, USER_LABEL);
    const user_nodes = user_nodes_opt orelse return authRoleFromRecord(record);

    const username = record.getUsername();
    var user_node_id: ?u64 = null;
    for (user_nodes) |nid| {
        // SONNY-6612 (1): a user node that cannot be read fails closed.
        const name_prop = (store.getNodePropertyOrError(nid, "username") catch return .None) orelse continue;
        const name_str = switch (name_prop) {
            .String => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, name_str, username)) {
            user_node_id = nid;
            break;
        }
    }
    const uid = user_node_id orelse return authRoleFromRecord(record);

    // Traverse outgoing HAS_ROLE edges and pick the role from the most
    // recently created edge (highest edge_id, which is monotonic).
    //
    // Pre-fix this loop returned the first HAS_ROLE edge HashMap
    // iteration surfaced — which, after an `ALTER USER ... SET ROLE`
    // (which only appends a new HAS_ROLE edge — see
    // storage/user_storage.zig:assignUserRole), gave a non-deterministic
    // result.  geode_auth_ddl_persistence.yml's
    // persist-permissions-after-restart test caught it intermittently:
    // the user landed back at the OLD role after every other restart.
    //
    // Writers now also revoke prior built-in HAS_ROLE edges on every
    // ALTER USER ... SET ROLE (server/server_init.zig:writerSetRole),
    // so new on-disk data never accumulates more than one built-in
    // HAS_ROLE edge.  This last-write-wins resolver is a compat shield
    // for legacy state written by pre-fix versions of geode (and a
    // belt-and-braces guarantee against any future writer that forgets
    // to revoke first).
    // SONNY-6607 (1): an adjacency list that cannot be read is not "no
    // HAS_ROLE edges" (that fell back to the record's role, which a newer
    // edge may have demoted). Fail closed: no global role.
    const edge_ids = (store.getOutgoingEdgeIdsOrError(uid) catch return .None) orelse return authRoleFromRecord(record);
    var best_role: ?geode.user_management.Role = null;
    var best_eid: u64 = 0;
    for (edge_ids) |eid| {
        // SONNY-6567 (2): a HAS_ROLE edge that cannot be read may be the
        // newest one (a demotion): resolving from the others could grant an
        // older, higher role. Fail closed: no global role.
        const edge = (store.getEdgePtrHydratedChecked(eid) catch return .None) orelse continue;
        if (!std.mem.eql(u8, edge.graph_name, SECURITY_GRAPH)) continue;
        if (!std.mem.eql(u8, edge.label, HAS_ROLE)) continue;

        // SONNY-6607 (1): an unreadable role node fails closed, as above.
        const role_name_prop = (store.getNodePropertyOrError(edge.to_id, "name") catch return .None) orelse continue;
        const role_name = switch (role_name_prop) {
            .String => |s| s,
            else => continue,
        };
        const parsed = geode.user_management.Role.fromString(role_name) orelse continue;
        if (best_role == null or eid > best_eid) {
            best_role = parsed;
            best_eid = eid;
        }
    }

    return best_role orelse authRoleFromRecord(record);
}
