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

/// Convert a UserRecord to a built-in Role without consulting the graph.
/// Returns .Admin when is_superuser is true, .ReadWrite otherwise.
/// This is the legacy fallback; prefer resolveRoleFromGraph when a store
/// is available.
pub fn authRoleFromRecord(record: user_storage.UserStorageBackend.UserRecord) geode.user_management.Role {
    return if (record.is_superuser) .Admin else .ReadWrite;
}

// CANARY: REQ=REQ-GPS-PDP-008; FEATURE="GPS Canonical Principal"; ASPECT=AuthRoleGraphLookupIsolated; STATUS=TESTED; TEST=tests/test_gps_role_resolver.zig; OWNER=security; UPDATED=2026-05-20
/// Resolve the user's built-in role from the __geode_security graph by
/// traversing the HAS_ROLE edge from the user node to the role node.  Falls
/// back to authRoleFromRecord (is_superuser→Admin, else ReadWrite) when no
/// HAS_ROLE edge or recognisable role name is found.
///
/// This corrects a gap in authRoleFromRecord: it only checked is_superuser
/// and always fell back to .ReadWrite for non-admin users, even when a
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
        const name_prop = store.getNodeProperty(nid, "username") orelse continue;
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

    // Traverse outgoing HAS_ROLE edges to find the role node.
    const edge_ids = store.getOutgoingEdgeIds(uid) orelse return authRoleFromRecord(record);
    for (edge_ids) |eid| {
        const edge = store.getEdgePtr(eid) orelse continue;
        if (!std.mem.eql(u8, edge.graph_name, SECURITY_GRAPH)) continue;
        if (!std.mem.eql(u8, edge.label, HAS_ROLE)) continue;

        // Found a HAS_ROLE edge; read the role name from the target node.
        const role_name_prop = store.getNodeProperty(edge.to_id, "name") orelse continue;
        const role_name = switch (role_name_prop) {
            .String => |s| s,
            else => continue,
        };
        if (geode.user_management.Role.fromString(role_name)) |r| return r;
    }

    return authRoleFromRecord(record);
}
