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
const Allocator = std.mem.Allocator;
const graph_store = @import("geode").graph_store;
const auth_hmac = @import("auth_lib").hmac;

// CANARY: REQ=REQ-GQL-202; FEATURE="UserStorage"; ASPECT=PersistentStorage; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_202_UserStorage; OWNER=security; UPDATED=2026-02-24

const logging = @import("logging");
const log = logging.scoped("user_storage");
const Attr = logging.Attr;

// GAP-0854 follow-up: alias the lowest-layer constant (graph_store) so the
// security-graph name cannot drift across the FLE guard, auth manager, and
// user storage.
const SECURITY_GRAPH_NAME = graph_store.SECURITY_GRAPH_NAME;
pub const USER_LABEL = "User";
const ROLE_LABEL = "Role";
const PERMISSION_LABEL = "Permission";
const POLICY_LABEL = "Policy";
const AUTH_CHAIN_ROOT_LABEL = "AuthChainRoot";
const HAS_ROLE_EDGE = "HAS_ROLE";
pub const GRAPH_GRANT_LABEL = "GraphGrant";

fn computeRecordHmacChecked(hmac_key: *const [32]u8, props: []const auth_hmac.KeyValue) [32]u8 {
    // error-policy: D — computeRecordHmac's only error is TooManyProperties
    // (>128 props); every call site passes a fixed-size props array well under that.
    return auth_hmac.computeRecordHmac(hmac_key, props) catch unreachable;
}

pub const UserStorageBackend = struct {
    allocator: Allocator,
    store: *graph_store.GraphStore,

    // In-memory cache for fast lookups
    user_cache: std.AutoHashMap(u64, UserRecord),
    role_cache: std.AutoHashMap(u64, RoleRecord),
    permission_cache: std.AutoHashMap(u64, PermissionRecord),
    policy_cache: std.AutoHashMap(u64, PolicyRecord),

    // Map entity id -> GraphStore node id
    user_nodes: std.AutoHashMap(u64, u64),
    role_nodes: std.AutoHashMap(u64, u64),
    permission_nodes: std.AutoHashMap(u64, u64),
    policy_nodes: std.AutoHashMap(u64, u64),
    graph_grant_nodes: std.AutoHashMap(u64, u64),

    // AuthChainRoot singleton node ID (null if not yet created)
    chain_root_node: ?u64,

    const Self = @This();

    // Persistent record structures
    pub const UserRecord = extern struct {
        id: u64,
        username: [64]u8,
        username_len: u16,
        email: [128]u8,
        email_len: u16,
        password_hash: [256]u8,
        password_hash_len: u16,
        salt: [32]u8,
        is_active: bool,
        is_superuser: bool,
        mfa_enabled: bool,
        mfa_secret: [64]u8,
        mfa_secret_len: u16,
        failed_login_attempts: u16,
        lockout_until: i64,
        last_login: i64,
        created_at: i64,
        updated_at: i64,
        // HMAC chain integrity fields (added for auth storage migration)
        password_changed_at: i64, // timestamp for password expiry policy
        hash_algorithm: [16]u8, // stores "argon2id" or "blake2b"
        hash_algorithm_len: u16,
        is_default_user: bool, // auto-created admin flag
        password_reset_required: bool, // force password change on next login
        auth_version: u64, // monotonic session invalidation version
        attributes_json: [2048]u8,
        attributes_json_len: u16,
        // Variable-length attributes section follows (unused in GraphStore backend)
        attributes_len: u32,

        pub fn getUsername(self: *const UserRecord) []const u8 {
            return self.username[0..self.username_len];
        }

        pub fn getEmail(self: *const UserRecord) []const u8 {
            return self.email[0..self.email_len];
        }

        pub fn getPasswordHash(self: *const UserRecord) []const u8 {
            return self.password_hash[0..self.password_hash_len];
        }

        pub fn getMFASecret(self: *const UserRecord) ?[]const u8 {
            if (self.mfa_secret_len == 0) return null;
            return self.mfa_secret[0..self.mfa_secret_len];
        }

        pub fn getHashAlgorithm(self: *const UserRecord) []const u8 {
            return self.hash_algorithm[0..self.hash_algorithm_len];
        }

        pub fn getAttributesJson(self: *const UserRecord) ?[]const u8 {
            if (self.attributes_json_len == 0) return null;
            return self.attributes_json[0..self.attributes_json_len];
        }
    };

    pub const RoleRecord = extern struct {
        id: u64,
        name: [64]u8,
        name_len: u16,
        description: [256]u8,
        description_len: u16,
        parent_role: u64, // 0 = no parent
        priority: u32,
        is_system: bool,
        created_at: i64,
        updated_at: i64,

        pub fn getName(self: *const RoleRecord) []const u8 {
            return self.name[0..self.name_len];
        }

        pub fn getDescription(self: *const RoleRecord) []const u8 {
            return self.description[0..self.description_len];
        }
    };

    pub const PermissionRecord = extern struct {
        id: u64,
        name: [64]u8,
        name_len: u16,
        resource: [128]u8,
        resource_len: u16,
        action: u8, // Encoded Action enum
        conditions: [512]u8,
        conditions_len: u16,
        created_at: i64,

        pub fn getName(self: *const PermissionRecord) []const u8 {
            return self.name[0..self.name_len];
        }

        pub fn getResource(self: *const PermissionRecord) []const u8 {
            return self.resource[0..self.resource_len];
        }

        pub fn getConditions(self: *const PermissionRecord) ?[]const u8 {
            if (self.conditions_len == 0) return null;
            return self.conditions[0..self.conditions_len];
        }
    };

    // CANARY: REQ=REQ-SONNY-2750-POLICY-RECORD-KIND; FEATURE="GPS Policy Persistence"; ASPECT=RecordKind; STATUS=TESTED; TEST=tests/test_sonny2750_policy_record_kind.zig; OWNER=security; UPDATED=2026-09-25
    /// SONNY-2750: which policy system a :Policy record in `__geode_security`
    /// belongs to. GPS (`policy_persistence`, CREATE POLICY) and RLS (the
    /// geode-auth CLI through `user_manager`, and `geode auth policy create`)
    /// write the same record type, with different meanings for `operation`,
    /// `permissive` and the USING text. GPS startup hydration loaded every
    /// record as a GPS policy, so an RLS `update` policy came back as a GPS
    /// "allow write on `default` for everyone". Stored as the `kind` property;
    /// see `fromProperty`.
    pub const PolicyKind = enum(u8) {
        /// No `kind` property: written before SONNY-2750. `effectiveKind`
        /// classifies it by shape.
        legacy = 0,
        gps = 1,
        rls = 2,
        /// A `kind` property that is neither "gps" nor "rls". No loader
        /// accepts it.
        invalid = 3,

        /// Strict decoding of a stored `kind` property: exactly "gps" or
        /// "rls"; any other value, or another type, is `.invalid`; a missing
        /// property is `.legacy`.
        pub fn fromProperty(value: ?graph_store.PropertyValue) PolicyKind {
            const v = value orelse return .legacy;
            if (v != .String) return .invalid;
            if (std.mem.eql(u8, v.String, "gps")) return .gps;
            if (std.mem.eql(u8, v.String, "rls")) return .rls;
            return .invalid;
        }

        /// The stored form of a kind a writer may persist.
        pub fn property(self: PolicyKind) ?[]const u8 {
            return switch (self) {
                .gps => "gps",
                .rls => "rls",
                .legacy, .invalid => null,
            };
        }
    };

    pub const PolicyRecord = extern struct {
        id: u64,
        name: [64]u8,
        name_len: u16,
        description: [256]u8,
        description_len: u16,
        graph: [64]u8,
        graph_len: u16,
        table: [64]u8,
        table_len: u16,
        operation: u8, // Encoded operation
        permissive: bool,
        enabled: bool,
        using_clause: [512]u8,
        using_clause_len: u16,
        check_clause: [512]u8,
        check_clause_len: u16,
        audit_level: u8,
        created_at: i64,
        updated_at: i64,
        created_by: u64,
        /// SONNY-2750: see `PolicyKind`.
        kind: PolicyKind,
        /// SONNY-2750: for a `.legacy` record, the writer its stored
        /// properties show (`legacyPolicyShape`), decided when it was
        /// loaded; `.invalid` otherwise.
        legacy_shape: PolicyKind,
        /// SONNY-2750: a property a policy needs was missing or of the wrong
        /// type when the record was loaded (`loadPoliciesFromGraph`). The
        /// defaults stand in for it, so no loader may use the record.
        malformed: bool,

        pub fn getName(self: *const PolicyRecord) []const u8 {
            return self.name[0..self.name_len];
        }

        /// SONNY-2750: the record's kind; for a `.legacy` record (no `kind`
        /// property, written before SONNY-2750), the writer its stored
        /// properties show (`legacy_shape`), which is `.invalid` when a
        /// property that decides it is missing.
        pub fn effectiveKind(self: *const PolicyRecord) PolicyKind {
            return if (self.kind == .legacy) self.legacy_shape else self.kind;
        }

        pub fn getDescription(self: *const PolicyRecord) []const u8 {
            return self.description[0..self.description_len];
        }

        pub fn getGraph(self: *const PolicyRecord) []const u8 {
            return self.graph[0..self.graph_len];
        }

        pub fn getTable(self: *const PolicyRecord) []const u8 {
            return self.table[0..self.table_len];
        }

        pub fn getUsingClause(self: *const PolicyRecord) ?[]const u8 {
            if (self.using_clause_len == 0) return null;
            return self.using_clause[0..self.using_clause_len];
        }

        pub fn getCheckClause(self: *const PolicyRecord) ?[]const u8 {
            if (self.check_clause_len == 0) return null;
            return self.check_clause[0..self.check_clause_len];
        }
    };

    // CANARY: REQ=REQ-AUTH-GRANT-PERSIST-001; FEATURE="GQL Auth DDL Persistence"; ASPECT=Storage; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_ddl_persistence.yml; OWNER=security; UPDATED=2026-05-12
    pub const GraphGrantRecord = extern struct {
        id: u64,
        user_id: u64,
        graph_name: [128]u8,
        graph_name_len: u16,
        action: u8, // 0=Read, 1=Write, 2=Schema (mirrors PermissionRecord.action encoding)
        granted_at: i64,
        granted_by: u64,

        pub fn getGraphName(self: *const GraphGrantRecord) []const u8 {
            return self.graph_name[0..self.graph_name_len];
        }
    };

    pub fn init(allocator: Allocator, store: *graph_store.GraphStore) !Self {
        try ensureSecurityGraph(store);

        var self = Self{
            .allocator = allocator,
            .store = store,
            .user_cache = std.AutoHashMap(u64, UserRecord).init(allocator),
            .role_cache = std.AutoHashMap(u64, RoleRecord).init(allocator),
            .permission_cache = std.AutoHashMap(u64, PermissionRecord).init(allocator),
            .policy_cache = std.AutoHashMap(u64, PolicyRecord).init(allocator),
            .user_nodes = std.AutoHashMap(u64, u64).init(allocator),
            .role_nodes = std.AutoHashMap(u64, u64).init(allocator),
            .permission_nodes = std.AutoHashMap(u64, u64).init(allocator),
            .policy_nodes = std.AutoHashMap(u64, u64).init(allocator),
            .graph_grant_nodes = std.AutoHashMap(u64, u64).init(allocator),
            .chain_root_node = null,
        };

        try self.loadCache();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.user_cache.deinit();
        self.role_cache.deinit();
        self.permission_cache.deinit();
        self.policy_cache.deinit();
        self.user_nodes.deinit();
        self.role_nodes.deinit();
        self.permission_nodes.deinit();
        self.policy_nodes.deinit();
        self.graph_grant_nodes.deinit();
    }

    fn ensureSecurityGraph(store: *graph_store.GraphStore) !void {
        store.createGraph(SECURITY_GRAPH_NAME) catch |err| switch (err) {
            error.GraphAlreadyExists => {},
            else => return err,
        };
    }

    fn loadCache(self: *Self) !void {
        try self.loadUsersFromGraph();
        try self.loadRolesFromGraph();
        try self.loadPermissionsFromGraph();
        try self.loadPoliciesFromGraph();
        try self.loadGraphGrantsFromGraph();
        // Hydrate `chain_root_node` from the persisted AuthChainRoot node so
        // a subsequent `persistChainRoot` call (e.g. during offline
        // reset-password rewriting the seal) updates the existing node
        // instead of creating a duplicate. Without this, repeated CLI
        // invocations against the same data dir leave multiple
        // AuthChainRoot nodes, and `verifyChain` on reload picks the
        // stale one and reports `ChainHashMismatch`.
        _ = self.loadChainRoot();
    }

    fn loadUsersFromGraph(self: *Self) !void {
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, USER_LABEL);
        if (nodes_opt == null) return;

        for (nodes_opt.?) |node_id| {
            const record = loadUserRecordFromNode(self.store, node_id) orelse continue;
            try self.user_cache.put(record.id, record);
            try self.user_nodes.put(record.id, node_id);
        }
    }

    fn loadUserRecordFromNode(store: *graph_store.GraphStore, node_id: u64) ?UserRecord {
        // Gap 0034 discipline, extended (merge interaction with the loop2
        // warm-hydration path): a snapshot-served reopen restores the label
        // postings WITHOUT materializing resident node bodies (engine scan
        // skipped — see loadOneGraphFromAdapterFull), so the raw `getNodePtr`
        // conflated "not yet resident" with "missing" and every persisted
        // security record became invisible after a clean-shutdown reopen
        // (admin login failed, bootstrap refused fail-closed). Read the body
        // HYDRATE-ON-MISS like loadChainRoot: null now really means the node
        // is absent from cache AND engine.
        const node = store.getNodePtrHydrated(node_id) orelse return null;
        if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) return null;

        const id_val = getIntProp(store, node_id, "id", -1);
        if (id_val < 0) return null;
        const user_id: u64 = @intCast(id_val);

        var record = blankUserRecord(user_id);
        record.username_len = copyIntoField(&record.username, getStringProp(store, node_id, "username", ""));
        record.email_len = copyIntoField(&record.email, getStringProp(store, node_id, "email", ""));
        record.password_hash_len = copyIntoField(&record.password_hash, getStringProp(store, node_id, "password_hash", ""));
        _ = copyIntoField(&record.salt, getStringProp(store, node_id, "salt", ""));
        record.is_active = getBoolProp(store, node_id, "is_active", true);
        record.is_superuser = getBoolProp(store, node_id, "is_superuser", false);
        record.mfa_enabled = getBoolProp(store, node_id, "mfa_enabled", false);
        record.mfa_secret_len = copyIntoField(&record.mfa_secret, getStringProp(store, node_id, "mfa_secret", ""));
        // SONNY-2757 (P29): out of range, the record is tampered: not loaded.
        record.failed_login_attempts = storedInt(u16, getIntProp(store, node_id, "failed_login_attempts", 0), "failed_login_attempts", user_id) orelse return null;
        record.lockout_until = getIntProp(store, node_id, "lockout_until", 0);
        record.last_login = getIntProp(store, node_id, "last_login", 0);
        record.created_at = getIntProp(store, node_id, "created_at", compat_milliTimestamp());
        record.updated_at = getIntProp(store, node_id, "updated_at", record.created_at);
        record.hash_algorithm_len = copyIntoField(&record.hash_algorithm, getStringProp(store, node_id, "hash_algorithm", ""));
        record.is_default_user = getBoolProp(store, node_id, "is_default_user", false);
        record.password_reset_required = getBoolProp(store, node_id, "password_reset_required", false);
        record.auth_version = @intCast(@max(1, getIntProp(store, node_id, "auth_version", 1)));
        record.attributes_json_len = copyIntoField(&record.attributes_json, getStringProp(store, node_id, "attributes_json", ""));
        record.password_changed_at = getIntProp(store, node_id, "password_changed_at", 0);
        return record;
    }

    // -----------------------------------------------------------------------
    // GAP-0061: engine-direct (slot-space) security-graph :User reads.
    //
    // The in-memory GraphStore hydration of `__geode_security` can QUARANTINE
    // the whole graph on a single unreadable node/edge blob: the streaming
    // slab reader raises `error.DataCorruption`, `loadOneGraphFromAdapterFull`
    // catches it and marks the graph done+failed. After that,
    // `store.getNodesByLabel(__geode_security, ...)` returns null even though
    // the storage ENGINE still holds intact, individually-readable :User
    // records. This locked admins out of a crash-reopened database: the server
    // login resolver (`findUserByUsernameInGraph`) returned null → every query
    // failed with "Authentication failed", while the admin-bootstrap guard
    // CORRECTLY refused to re-seed (the engine confirmed the persisted
    // credential still exists) — so the persisted credential could never load.
    //
    // These helpers read the label slots + node properties straight from the
    // storage engine (the EXACT reads the bootstrap guard's
    // `countCredentialBearingPersistedUsers` already proves succeed
    // post-crash), entirely independent of the GraphStore in-memory hydration
    // and IdMap. The static `*InGraph` lookups below fall back to them whenever
    // the in-memory path yields no match, so the persisted admin credential
    // always LOADS — even when hydration is degraded. This does NOT weaken the
    // persisted-credential-wins policy; it makes that credential reliably
    // loadable after a crash. `adapter` is passed as `anytype` (the same
    // pattern `auth_graph_manager.countCredentialBearingPersistedUsers` uses)
    // to avoid a circular `graph_storage` import in this module.
    // -----------------------------------------------------------------------

    fn edGetInt(allocator: Allocator, adapter: anytype, slot: u64, key: []const u8, default: i64) i64 {
        const maybe = adapter.getNodeProperty(SECURITY_GRAPH_NAME, slot, key, allocator) catch return default;
        const v = maybe orelse return default;
        switch (v) {
            .int => |i| return i,
            .string => |s| {
                allocator.free(s);
                return default;
            },
            .ext => |e| {
                allocator.free(e.data);
                return default;
            },
            else => return default,
        }
    }

    fn edGetBool(allocator: Allocator, adapter: anytype, slot: u64, key: []const u8, default: bool) bool {
        const maybe = adapter.getNodeProperty(SECURITY_GRAPH_NAME, slot, key, allocator) catch return default;
        const v = maybe orelse return default;
        switch (v) {
            .bool => |b| return b,
            .string => |s| {
                allocator.free(s);
                return default;
            },
            .ext => |e| {
                allocator.free(e.data);
                return default;
            },
            else => return default,
        }
    }

    /// Copy an engine string property into the fixed `dest` field, freeing the
    /// transient engine-owned string. Returns bytes written (0 when absent or
    /// not a string), leaving `dest` zeroed via `copyIntoField(dest, "")`.
    fn edCopyStr(allocator: Allocator, adapter: anytype, slot: u64, key: []const u8, dest: []u8) u16 {
        const maybe = adapter.getNodeProperty(SECURITY_GRAPH_NAME, slot, key, allocator) catch return copyIntoField(dest, "");
        const v = maybe orelse return copyIntoField(dest, "");
        switch (v) {
            .string => |s| {
                defer allocator.free(s);
                return copyIntoField(dest, s);
            },
            .ext => |e| {
                allocator.free(e.data);
                return copyIntoField(dest, "");
            },
            else => return copyIntoField(dest, ""),
        }
    }

    /// Rebuild one :User record from the engine by slot id (mirrors
    /// `loadUserRecordFromNode`, but reads engine-direct via the adapter rather
    /// than the in-memory GraphStore). Returns null when the slot carries no
    /// valid `id` property.
    fn loadUserRecordEngineDirect(allocator: Allocator, adapter: anytype, slot: u64) ?UserRecord {
        const id_val = edGetInt(allocator, adapter, slot, "id", -1);
        if (id_val < 0) return null;
        const user_id: u64 = @intCast(id_val);

        var record = blankUserRecord(user_id);
        record.username_len = edCopyStr(allocator, adapter, slot, "username", &record.username);
        record.email_len = edCopyStr(allocator, adapter, slot, "email", &record.email);
        record.password_hash_len = edCopyStr(allocator, adapter, slot, "password_hash", &record.password_hash);
        _ = edCopyStr(allocator, adapter, slot, "salt", &record.salt);
        record.is_active = edGetBool(allocator, adapter, slot, "is_active", true);
        record.is_superuser = edGetBool(allocator, adapter, slot, "is_superuser", false);
        record.mfa_enabled = edGetBool(allocator, adapter, slot, "mfa_enabled", false);
        record.mfa_secret_len = edCopyStr(allocator, adapter, slot, "mfa_secret", &record.mfa_secret);
        // SONNY-2757 (P29): out of range, the record is tampered: not loaded.
        record.failed_login_attempts = storedInt(u16, edGetInt(allocator, adapter, slot, "failed_login_attempts", 0), "failed_login_attempts", user_id) orelse return null;
        record.lockout_until = edGetInt(allocator, adapter, slot, "lockout_until", 0);
        record.last_login = edGetInt(allocator, adapter, slot, "last_login", 0);
        record.created_at = edGetInt(allocator, adapter, slot, "created_at", compat_milliTimestamp());
        record.updated_at = edGetInt(allocator, adapter, slot, "updated_at", record.created_at);
        record.hash_algorithm_len = edCopyStr(allocator, adapter, slot, "hash_algorithm", &record.hash_algorithm);
        record.is_default_user = edGetBool(allocator, adapter, slot, "is_default_user", false);
        record.password_reset_required = edGetBool(allocator, adapter, slot, "password_reset_required", false);
        record.auth_version = @intCast(@max(1, edGetInt(allocator, adapter, slot, "auth_version", 1)));
        record.attributes_json_len = edCopyStr(allocator, adapter, slot, "attributes_json", &record.attributes_json);
        record.password_changed_at = edGetInt(allocator, adapter, slot, "password_changed_at", 0);
        return record;
    }

    /// GAP-0061 fallback: engine-direct scan for a user by username, used when
    /// the in-memory security-graph hydration is quarantined/empty.
    ///
    /// ENG-3954: reports `error.SecurityStoreUnavailable` when the engine could
    /// not be scanned at all (no adapter, or the scan failed) so the auth path
    /// can tell that apart from a complete scan that found no match.
    fn findUserByUsernameEngineDirect(allocator: Allocator, username: []const u8) !?UserRecord {
        const adapter = graph_store.getGlobalAdapter() orelse return SecurityStoreUnavailable;
        const slots = adapter.getNodesByLabel(SECURITY_GRAPH_NAME, USER_LABEL, allocator) catch return SecurityStoreUnavailable;
        defer allocator.free(slots);
        for (slots) |slot| {
            const record = loadUserRecordEngineDirect(allocator, adapter, slot) orelse continue;
            if (std.mem.eql(u8, record.getUsername(), username)) return record;
        }
        return null;
    }

    /// GAP-0061 fallback: engine-direct list of every persisted :User record.
    fn listUsersEngineDirect(allocator: Allocator) ![]UserRecord {
        const adapter = graph_store.getGlobalAdapter() orelse return allocator.alloc(UserRecord, 0);
        const slots = adapter.getNodesByLabel(SECURITY_GRAPH_NAME, USER_LABEL, allocator) catch return allocator.alloc(UserRecord, 0);
        defer allocator.free(slots);
        var records = std.ArrayList(UserRecord).empty;
        defer records.deinit(allocator);
        for (slots) |slot| {
            const record = loadUserRecordEngineDirect(allocator, adapter, slot) orelse continue;
            try records.append(allocator, record);
        }
        return records.toOwnedSlice(allocator);
    }

    pub fn hasUserRecordsInGraph(store: *graph_store.GraphStore) bool {
        if (store.getNodesByLabel(SECURITY_GRAPH_NAME, USER_LABEL)) |nodes| {
            if (nodes.len > 0) return true;
        }
        // GAP-0061: the in-memory hydration may be quarantined (getNodesByLabel
        // returns null even though the engine holds records). Ask the engine.
        if (graph_store.getGlobalAdapter()) |adapter| {
            const n = adapter.countNodesByLabel(SECURITY_GRAPH_NAME, USER_LABEL) catch return false;
            return n > 0;
        }
        return false;
    }

    /// ENG-3954 / #874: the security store could not be consulted at all, so
    /// "no such user" is not a supportable answer. Callers on the auth path
    /// must surface this as "unavailable" rather than laundering it into a
    /// credential rejection that arms the per-IP brute-force lockout.
    pub const SecurityStoreUnavailable = error.SecurityStoreUnavailable;

    /// Locate a persisted `:User` record, distinguishing "definitively absent"
    /// (null) from "the store could not answer" (`error.SecurityStoreUnavailable`).
    ///
    /// Absent means the engine-direct scan RAN to completion and the username was
    /// not in it. Unavailable means it could not run at all: the engine adapter is
    /// absent or the slot scan failed.
    ///
    /// ENG-3954: an in-memory HIT still resolves without the engine (GAP-0061's
    /// healthy path), but a MISS on the in-memory postings is NOT evidence of
    /// absence. The posting is set by mere presence of a `__geode_security:User`
    /// label entry — true for an empty posting, for one whose node bodies are
    /// unreadable (`loadUserRecordFromNode ... orelse continue`), and for a
    /// partially-hydrated posting that is simply missing this principal. Those are
    /// exactly the degraded states the engine-direct fallback was added for, so
    /// letting the posting vouch for "no such user" is circular: it trusts the
    /// path we already decided not to trust, and the resulting `null` becomes
    /// `error.Unauthenticated` upstream, which the per-IP limiter COUNTS.
    /// CANARY: REQ=REQ-SEC-AUTH-UNAVAILABLE-002; FEATURE="AuthOutcomeClassification"; ASPECT=StorageLookup; STATUS=TESTED; TEST=tests/test_auth_unavailable_classification.zig; OWNER=security; UPDATED=2026-08-29
    pub fn findUserByUsernameInGraphChecked(store: *graph_store.GraphStore, username: []const u8) !?UserRecord {
        if (store.getNodesByLabel(SECURITY_GRAPH_NAME, USER_LABEL)) |nodes| {
            for (nodes) |node_id| {
                const record = loadUserRecordFromNode(store, node_id) orelse continue;
                if (std.mem.eql(u8, record.getUsername(), username)) {
                    return record;
                }
            }
        }
        // GAP-0061: engine-direct fallback when the in-memory path had no match
        // (quarantined hydration, or an unreadable resident node body). Without
        // this the persisted admin credential is unloadable after a crash and
        // every query returns "Authentication failed". Its
        // `error.SecurityStoreUnavailable` propagates: with no trustworthy
        // enumeration, "no such user" is not a supportable answer. The verdict is
        // identical for every unresolvable principal, so this adds no
        // username-enumeration oracle (#829).
        return try findUserByUsernameEngineDirect(store.allocator, username);
    }

    /// Legacy option-returning lookup, kept for the non-auth callers (bootstrap,
    /// password-reset tooling, durability tests) that only care about presence.
    /// Auth-path callers must use `findUserByUsernameInGraphChecked` instead:
    /// this one still collapses "could not answer" into "no such user".
    pub fn findUserByUsernameInGraph(store: *graph_store.GraphStore, username: []const u8) ?UserRecord {
        return findUserByUsernameInGraphChecked(store, username) catch null;
    }

    pub fn listUsersFromGraph(allocator: Allocator, store: *graph_store.GraphStore) ![]UserRecord {
        if (store.getNodesByLabel(SECURITY_GRAPH_NAME, USER_LABEL)) |nodes| {
            if (nodes.len > 0) {
                var records = std.ArrayList(UserRecord).empty;
                defer records.deinit(allocator);
                for (nodes) |node_id| {
                    const record = loadUserRecordFromNode(store, node_id) orelse continue;
                    try records.append(allocator, record);
                }
                return records.toOwnedSlice(allocator);
            }
        }
        // GAP-0061: engine-direct fallback (quarantined/empty in-memory path).
        return listUsersEngineDirect(allocator);
    }

    pub fn findUserAuthVersionByUsernameInGraph(store: *graph_store.GraphStore, username: []const u8) ?u64 {
        const record = findUserByUsernameInGraph(store, username) orelse return null;
        return @max(@as(u64, 1), record.auth_version);
    }

    fn loadRolesFromGraph(self: *Self) !void {
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, ROLE_LABEL);
        if (nodes_opt == null) return;

        for (nodes_opt.?) |node_id| {
            // Gap 0034 discipline (see loadUserRecordFromNode): hydrate-on-miss
            // so a snapshot-served/evicted body still resolves from the engine.
            const node = self.store.getNodePtrHydrated(node_id) orelse continue;
            if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) continue;

            const id_val = getIntProp(self.store, node_id, "id", -1);
            if (id_val < 0) continue;
            const role_id: u64 = @intCast(id_val);

            var record = blankRoleRecord(role_id);
            record.name_len = copyIntoField(&record.name, getStringProp(self.store, node_id, "name", ""));
            record.description_len = copyIntoField(&record.description, getStringProp(self.store, node_id, "description", ""));
            record.parent_role = @intCast(@max(0, getIntProp(self.store, node_id, "parent_role", 0)));
            // SONNY-2757 (P29): out of range, the record is tampered: not loaded.
            record.priority = storedInt(u32, getIntProp(self.store, node_id, "priority", 0), "priority", role_id) orelse continue;
            record.is_system = getBoolProp(self.store, node_id, "is_system", false);
            record.created_at = getIntProp(self.store, node_id, "created_at", compat_milliTimestamp());
            record.updated_at = getIntProp(self.store, node_id, "updated_at", record.created_at);

            try self.role_cache.put(role_id, record);
            try self.role_nodes.put(role_id, node_id);
        }
    }

    fn loadPermissionsFromGraph(self: *Self) !void {
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, PERMISSION_LABEL);
        if (nodes_opt == null) return;

        for (nodes_opt.?) |node_id| {
            // Gap 0034 discipline (see loadUserRecordFromNode): hydrate-on-miss
            // so a snapshot-served/evicted body still resolves from the engine.
            const node = self.store.getNodePtrHydrated(node_id) orelse continue;
            if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) continue;

            const id_val = getIntProp(self.store, node_id, "id", -1);
            if (id_val < 0) continue;
            const perm_id: u64 = @intCast(id_val);

            var record = blankPermissionRecord(perm_id);
            record.name_len = copyIntoField(&record.name, getStringProp(self.store, node_id, "name", ""));
            record.resource_len = copyIntoField(&record.resource, getStringProp(self.store, node_id, "resource", ""));
            // SONNY-2757 (P29): out of range, the record is tampered: not loaded.
            record.action = storedInt(u8, getIntProp(self.store, node_id, "action", 0), "action", perm_id) orelse continue;
            record.conditions_len = copyIntoField(&record.conditions, getStringProp(self.store, node_id, "conditions", ""));
            record.created_at = getIntProp(self.store, node_id, "created_at", compat_milliTimestamp());

            try self.permission_cache.put(perm_id, record);
            try self.permission_nodes.put(perm_id, node_id);
        }
    }

    fn loadPoliciesFromGraph(self: *Self) !void {
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, POLICY_LABEL);
        if (nodes_opt == null) return;

        for (nodes_opt.?) |node_id| {
            // Gap 0034 discipline (see loadUserRecordFromNode): hydrate-on-miss
            // so a snapshot-served/evicted body still resolves from the engine.
            const node = self.store.getNodePtrHydrated(node_id) orelse continue;
            if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) continue;

            const id_val = getIntProp(self.store, node_id, "id", -1);
            if (id_val < 0) continue;
            const policy_id: u64 = @intCast(id_val);

            var record = blankPolicyRecord(policy_id);
            const stored_name = getStringProp(self.store, node_id, "name", "");
            const stored_graph = getStringProp(self.store, node_id, "graph", "");
            const stored_using = getStringProp(self.store, node_id, "using_clause", "");
            const stored_check = getStringProp(self.store, node_id, "check_clause", "");
            record.name_len = copyIntoField(&record.name, stored_name);
            record.description_len = copyIntoField(&record.description, getStringProp(self.store, node_id, "description", ""));
            record.graph_len = copyIntoField(&record.graph, stored_graph);
            record.table_len = copyIntoField(&record.table, getStringProp(self.store, node_id, "table", ""));
            // SONNY-2757 (P29): an operation or audit level out of range makes
            // the record malformed (below): it loads nowhere, and its HMAC no
            // longer verifies. It used to abort a safe build here, at
            // startup, before the chain was checked.
            const stored_operation = storedInt(u8, getIntProp(self.store, node_id, "operation", 0), "operation", policy_id);
            record.operation = stored_operation orelse 0;
            record.permissive = getBoolProp(self.store, node_id, "permissive", false);
            record.enabled = getBoolProp(self.store, node_id, "enabled", true);
            // SONNY-2750: the kind, decoded strictly, and whether a property
            // the policy needs is missing: its default must not stand in for
            // it (an absent `enabled` read as true, an absent USING text as
            // "true").
            record.kind = PolicyKind.fromProperty(self.store.getNodeProperty(node_id, "kind"));
            if (record.kind == .legacy) record.legacy_shape = legacyPolicyShape(self.store, node_id);
            record.malformed = !hasProp(self.store, node_id, "name", .String) or
                !hasProp(self.store, node_id, "graph", .String) or
                !hasProp(self.store, node_id, "operation", .Int) or
                !hasProp(self.store, node_id, "permissive", .Bool) or
                !hasProp(self.store, node_id, "enabled", .Bool) or
                // Since SONNY-2750 a GPS record stores its USING text even
                // when it is "true"; a legacy one omitted it for "true".
                (record.kind == .gps and !hasProp(self.store, node_id, "using_clause", .String));
            // CANARY: REQ=REQ-SONNY-2731-POLICY-TEXT-LIMITS; FEATURE="GPS Policy Persistence"; ASPECT=OverlongStoredPolicy; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-09-25
            // SONNY-2731: a stored name, graph or clause longer than its field
            // (persistPolicy never writes one; an older or foreign writer
            // could) used to be cut to fit, and the cut policy text compiled
            // at startup as a different policy. Such a policy is now loaded
            // with a USING text that never compiles, so the catalog keeps it
            // fail-closed (it grants nothing, and lists as invalid).
            const overlong = stored_name.len > record.name.len or stored_graph.len > record.graph.len or
                stored_using.len > record.using_clause.len or stored_check.len > record.check_clause.len;
            if (overlong) {
                log.warn("stored policy has a field longer than its record; loaded fail-closed", &.{
                    Attr.uint("policy_id", policy_id),
                    Attr.uint("using_len", @intCast(stored_using.len)),
                });
                record.using_clause_len = copyIntoField(&record.using_clause, overlong_policy_text);
                record.check_clause_len = 0;
            } else {
                record.using_clause_len = copyIntoField(&record.using_clause, stored_using);
                record.check_clause_len = copyIntoField(&record.check_clause, stored_check);
            }
            const stored_audit_level = storedInt(u8, getIntProp(self.store, node_id, "audit_level", 0), "audit_level", policy_id);
            record.audit_level = stored_audit_level orelse 0;
            if (stored_operation == null or stored_audit_level == null) record.malformed = true;
            record.created_at = getIntProp(self.store, node_id, "created_at", compat_milliTimestamp());
            record.updated_at = getIntProp(self.store, node_id, "updated_at", record.created_at);
            record.created_by = @intCast(@max(0, getIntProp(self.store, node_id, "created_by", 0)));

            try self.policy_cache.put(policy_id, record);
            try self.policy_nodes.put(policy_id, node_id);
        }
    }

    /// The id of a per-graph grant: a 64-bit hash of who, which graph and
    /// which action. The auth graph manager keys `graph_grant_nodes` and each
    /// grant's HMAC by it.
    pub fn graphGrantId(user_id: u64, graph_name: []const u8, action: u8) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&user_id));
        h.update(graph_name);
        h.update(&[_]u8{action});
        return h.final();
    }

    /// The id of the grant stored at `node_id`, derived from its fields, or
    /// null when they are missing or out of range.
    ///
    /// The id is a 64-bit hash, so about half of all grants have one above
    /// `maxInt(i64)`. It was written through `safeI64`, which clamped those to
    /// `maxInt(i64)`, and read back from that property. A revoke then removed
    /// the wrong `graph_grant_nodes` key and left the deleted node in the map,
    /// so resealing the chain failed with NodeNotFound (SQLSTATE 58030). At
    /// startup every clamped grant collapsed onto one key, and its HMAC (sealed
    /// under the real id) failed to verify. Deriving the id from the fields the
    /// HMAC already covers gives the real id for new and existing records.
    fn graphGrantIdFromNode(store: *graph_store.GraphStore, node_id: u64) ?u64 {
        const uid_val = getIntProp(store, node_id, "user_id", -1);
        if (uid_val < 0) return null;
        const action_val = getIntProp(store, node_id, "action", -1);
        if (action_val < 0 or action_val > std.math.maxInt(u8)) return null;
        const graph = getStringProp(store, node_id, "graph_name", "");
        return graphGrantId(@intCast(uid_val), graph, @intCast(action_val));
    }

    fn loadGraphGrantsFromGraph(self: *Self) !void {
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, GRAPH_GRANT_LABEL);
        if (nodes_opt == null) return;

        for (nodes_opt.?) |node_id| {
            // Gap 0034 discipline (see loadUserRecordFromNode): hydrate-on-miss
            // so a snapshot-served/evicted body still resolves from the engine.
            const node = self.store.getNodePtrHydrated(node_id) orelse continue;
            if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) continue;

            // A record whose fields do not give an id (tampered: SONNY-2757) is
            // still mapped, under its stored id, so the chain verification
            // sees it and its HMAC fails rather than the record being skipped.
            const grant_id = graphGrantIdFromNode(self.store, node_id) orelse
                @as(u64, @bitCast(getIntProp(self.store, node_id, "id", -1)));

            try self.graph_grant_nodes.put(grant_id, node_id);
        }
    }

    // GraphGrant operations
    pub fn persistGraphGrant(self: *Self, grant_id: u64, user_id: u64, graph_name: []const u8, action: u8) !void {
        if (graph_name.len > 127) {
            return error.FieldTooLong;
        }

        var record = blankGraphGrantRecord(grant_id);
        record.user_id = user_id;
        record.graph_name_len = copyIntoField(&record.graph_name, graph_name);
        record.action = action;
        record.granted_at = compat_timestamp();
        record.granted_by = 0;

        try self.upsertGraphGrantNode(record);
    }

    pub fn revokeGraphGrant(self: *Self, user_id: u64, graph_name: []const u8, action: u8) !bool {
        // Scan graph_grant_nodes to find the matching node by user_id, graph_name, action
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, GRAPH_GRANT_LABEL);
        if (nodes_opt == null) return false;

        for (nodes_opt.?) |node_id| {
            // Gap 0034 discipline (see loadUserRecordFromNode): hydrate-on-miss
            // so a snapshot-served/evicted body still resolves from the engine.
            const node = self.store.getNodePtrHydrated(node_id) orelse continue;
            if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) continue;

            const grant_id = graphGrantIdFromNode(self.store, node_id) orelse continue;

            const uid_val = getIntProp(self.store, node_id, "user_id", -1);
            if (uid_val < 0) continue;
            const stored_user_id: u64 = @intCast(uid_val);
            if (stored_user_id != user_id) continue;

            // SONNY-2757 (P29): an action out of range matches nothing.
            const stored_action = storedInt(u8, getIntProp(self.store, node_id, "action", -1), "action", grant_id) orelse continue;
            if (stored_action != action) continue;

            const stored_graph = getStringProp(self.store, node_id, "graph_name", "");
            if (!std.mem.eql(u8, stored_graph, graph_name)) continue;

            // Found the matching grant
            _ = self.graph_grant_nodes.remove(grant_id);
            self.store.deleteNode(node_id);
            return true;
        }
        return false;
    }

    pub fn listGraphGrants(self: *Self, allocator: Allocator) ![]GraphGrantRecord {
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, GRAPH_GRANT_LABEL);
        if (nodes_opt == null or nodes_opt.?.len == 0) {
            return allocator.alloc(GraphGrantRecord, 0);
        }

        var records = std.ArrayList(GraphGrantRecord).empty;
        defer records.deinit(allocator);

        for (nodes_opt.?) |node_id| {
            // Gap 0034 discipline (see loadUserRecordFromNode): hydrate-on-miss
            // so a snapshot-served/evicted body still resolves from the engine.
            const node = self.store.getNodePtrHydrated(node_id) orelse continue;
            if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) continue;

            const grant_id = graphGrantIdFromNode(self.store, node_id) orelse continue;

            var record = blankGraphGrantRecord(grant_id);
            const uid_val = getIntProp(self.store, node_id, "user_id", 0);
            record.user_id = if (uid_val >= 0) @intCast(uid_val) else 0;
            record.graph_name_len = copyIntoField(&record.graph_name, getStringProp(self.store, node_id, "graph_name", ""));
            // SONNY-2757 (P29): out of range, the record is tampered: not listed.
            record.action = storedInt(u8, getIntProp(self.store, node_id, "action", 0), "action", grant_id) orelse continue;
            record.granted_at = getIntProp(self.store, node_id, "granted_at", compat_timestamp());
            const gb_val = getIntProp(self.store, node_id, "granted_by", 0);
            record.granted_by = if (gb_val >= 0) @intCast(gb_val) else 0;

            try records.append(allocator, record);
        }
        return records.toOwnedSlice(allocator);
    }

    // User operations
    pub fn persistUser(self: *Self, user_id: u64, username: []const u8, email: []const u8, password_hash: []const u8, salt: []const u8) !void {
        if (username.len > 63 or email.len > 127 or password_hash.len > 255 or salt.len > 31) {
            return error.FieldTooLong;
        }

        var record = blankUserRecord(user_id);
        record.username_len = copyIntoField(&record.username, username);
        record.email_len = copyIntoField(&record.email, email);
        record.password_hash_len = copyIntoField(&record.password_hash, password_hash);
        _ = copyIntoField(&record.salt, salt);
        record.created_at = compat_milliTimestamp();
        record.updated_at = record.created_at;
        record.auth_version = 1;

        try self.user_cache.put(user_id, record);
        try self.upsertUserNode(record);
    }

    pub fn updateUser(self: *Self, user_id: u64, email: ?[]const u8, password_hash: ?[]const u8, is_active: ?bool, mfa_enabled: ?bool, mfa_secret: ?[]const u8) !void {
        var record = self.user_cache.get(user_id) orelse return error.UserNotFound;
        var bump_auth_version = false;

        if (email) |e| {
            if (e.len > 127) return error.FieldTooLong;
            record.email_len = copyIntoField(&record.email, e);
        }

        if (password_hash) |ph| {
            if (ph.len > 127) return error.FieldTooLong;
            if (!std.mem.eql(u8, record.getPasswordHash(), ph)) {
                bump_auth_version = true;
                record.password_changed_at = compat_milliTimestamp();
            }
            record.password_hash_len = copyIntoField(&record.password_hash, ph);
        }

        if (is_active) |active| {
            if (record.is_active != active) bump_auth_version = true;
            record.is_active = active;
        }
        if (mfa_enabled) |enabled| {
            if (record.mfa_enabled != enabled) bump_auth_version = true;
            record.mfa_enabled = enabled;
        }

        if (mfa_secret) |secret| {
            if (secret.len > 63) return error.FieldTooLong;
            if (record.getMFASecret()) |existing| {
                if (!std.mem.eql(u8, existing, secret)) bump_auth_version = true;
            } else {
                bump_auth_version = true;
            }
            record.mfa_secret_len = copyIntoField(&record.mfa_secret, secret);
        }

        record.updated_at = compat_milliTimestamp();
        if (bump_auth_version) {
            record.auth_version += 1;
        }

        try self.user_cache.put(user_id, record);
        try self.upsertUserNode(record);
    }

    pub const ManagedUserUpsert = struct {
        user_id: u64,
        username: []const u8,
        email: []const u8,
        password_hash: []const u8,
        is_active: bool = true,
        is_superuser: bool = false,
        mfa_enabled: bool = false,
        mfa_secret: ?[]const u8 = null,
        password_reset_required: bool = false,
        attributes_json: ?[]const u8 = null,
        bump_auth_version: bool = false,
    };

    pub fn upsertManagedUser(self: *Self, opts: ManagedUserUpsert) !u64 {
        if (opts.username.len > 63 or opts.email.len > 127 or opts.password_hash.len > 255) {
            return error.FieldTooLong;
        }
        if (opts.mfa_secret) |secret| {
            if (secret.len > 63) return error.FieldTooLong;
        }
        if (opts.attributes_json) |attrs| {
            if (attrs.len > 2047) return error.FieldTooLong;
        }

        var record = self.user_cache.get(opts.user_id) orelse blankUserRecord(opts.user_id);
        const is_new_record = self.user_cache.get(opts.user_id) == null;

        record.username_len = copyIntoField(&record.username, opts.username);
        record.email_len = copyIntoField(&record.email, opts.email);
        const password_hash_changed = !std.mem.eql(u8, record.getPasswordHash(), opts.password_hash);
        record.password_hash_len = copyIntoField(&record.password_hash, opts.password_hash);
        record.is_active = opts.is_active;
        record.is_superuser = opts.is_superuser;
        record.mfa_enabled = opts.mfa_enabled;
        record.password_reset_required = opts.password_reset_required;
        record.mfa_secret_len = if (opts.mfa_secret) |secret| copyIntoField(&record.mfa_secret, secret) else 0;
        if (opts.attributes_json) |attrs| {
            record.attributes_json_len = copyIntoField(&record.attributes_json, attrs);
        } else {
            @memset(record.attributes_json[0..], 0);
            record.attributes_json_len = 0;
        }

        const now = compat_milliTimestamp();
        if (is_new_record) {
            record.created_at = now;
            record.auth_version = 1;
        }
        if ((opts.bump_auth_version or password_hash_changed) and !is_new_record) {
            record.auth_version = record.auth_version + 1;
        }
        if (password_hash_changed) {
            record.password_changed_at = now;
        }
        record.updated_at = now;

        try self.user_cache.put(opts.user_id, record);
        try self.upsertUserNode(record);
        return record.auth_version;
    }

    pub fn bumpUserAuthVersion(self: *Self, user_id: u64) !u64 {
        var record = self.user_cache.get(user_id) orelse return error.UserNotFound;
        record.auth_version += 1;
        record.updated_at = compat_milliTimestamp();
        try self.user_cache.put(user_id, record);
        try self.upsertUserNode(record);
        return record.auth_version;
    }

    pub fn assignUserRole(self: *Self, user_id: u64, role_id: u64) !bool {
        const user_node_id = self.user_nodes.get(user_id) orelse return error.UserNotFound;
        const role_node_id = self.role_nodes.get(role_id) orelse return error.RoleNotFound;

        if (self.store.getOutgoingEdgeIds(user_node_id)) |edge_ids| {
            for (edge_ids) |edge_id| {
                const edge = self.store.getEdgePtr(edge_id) orelse continue;
                if (!std.mem.eql(u8, edge.graph_name, SECURITY_GRAPH_NAME)) continue;
                if (!std.mem.eql(u8, edge.label, HAS_ROLE_EDGE)) continue;
                if (edge.to_id == role_node_id) return false;
            }
        }

        _ = try self.store.createEdgeWithGraph(user_node_id, role_node_id, HAS_ROLE_EDGE, SECURITY_GRAPH_NAME);
        return true;
    }

    pub fn revokeUserRole(self: *Self, user_id: u64, role_id: u64) !bool {
        const user_node_id = self.user_nodes.get(user_id) orelse return error.UserNotFound;
        const role_node_id = self.role_nodes.get(role_id) orelse return error.RoleNotFound;

        if (self.store.getOutgoingEdgeIds(user_node_id)) |edge_ids| {
            for (edge_ids) |edge_id| {
                const edge = self.store.getEdgePtr(edge_id) orelse continue;
                if (!std.mem.eql(u8, edge.graph_name, SECURITY_GRAPH_NAME)) continue;
                if (!std.mem.eql(u8, edge.label, HAS_ROLE_EDGE)) continue;
                if (edge.to_id == role_node_id) {
                    self.store.deleteEdge(edge_id);
                    return true;
                }
            }
        }
        return false;
    }

    pub fn listUserRoleIds(self: *Self, allocator: Allocator, user_id: u64) ![]u64 {
        const user_node_id = self.user_nodes.get(user_id) orelse return allocator.alloc(u64, 0);
        var result = std.ArrayList(u64).empty;
        defer result.deinit(allocator);

        if (self.store.getOutgoingEdgeIds(user_node_id)) |edge_ids| {
            for (edge_ids) |edge_id| {
                const edge = self.store.getEdgePtr(edge_id) orelse continue;
                if (!std.mem.eql(u8, edge.graph_name, SECURITY_GRAPH_NAME)) continue;
                if (!std.mem.eql(u8, edge.label, HAS_ROLE_EDGE)) continue;

                var it = self.role_nodes.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == edge.to_id) {
                        try result.append(allocator, entry.key_ptr.*);
                        break;
                    }
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn removeUser(self: *Self, user_id: u64) !void {
        _ = self.user_cache.remove(user_id);
        if (self.user_nodes.fetchRemove(user_id)) |kv| {
            self.store.deleteNode(kv.value);
        }
    }

    pub fn getUser(self: *Self, user_id: u64) ?UserRecord {
        return self.user_cache.get(user_id);
    }

    pub fn getUserByUsername(self: *Self, username: []const u8) ?UserRecord {
        var it = self.user_cache.valueIterator();
        while (it.next()) |record| {
            if (std.mem.eql(u8, record.getUsername(), username)) {
                return record.*;
            }
        }
        return null;
    }

    // HMAC-aware user persist
    pub fn persistUserWithHmac(self: *Self, user_id: u64, username: []const u8, email: []const u8, password_hash: []const u8, salt: []const u8, hmac_key: *const [32]u8) !void {
        // Persist the user record first (creates/updates node in graph)
        try self.persistUser(user_id, username, email, password_hash, salt);

        // Compute HMAC over all user properties (sorted by key name)
        var id_buf: [20]u8 = undefined;
        const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{user_id}) catch "0";

        const record = self.user_cache.get(user_id) orelse return error.UserNotFound;

        var created_buf: [20]u8 = undefined;
        const created_str = std.fmt.bufPrint(&created_buf, "{d}", .{record.created_at}) catch "0";
        var updated_buf: [20]u8 = undefined;
        const updated_str = std.fmt.bufPrint(&updated_buf, "{d}", .{record.updated_at}) catch "0";
        var pwd_changed_buf: [20]u8 = undefined;
        const pwd_changed_str = std.fmt.bufPrint(&pwd_changed_buf, "{d}", .{record.password_changed_at}) catch "0";
        var lockout_buf: [20]u8 = undefined;
        const lockout_str = std.fmt.bufPrint(&lockout_buf, "{d}", .{record.lockout_until}) catch "0";
        var last_login_buf: [20]u8 = undefined;
        const last_login_str = std.fmt.bufPrint(&last_login_buf, "{d}", .{record.last_login}) catch "0";
        var failed_buf: [10]u8 = undefined;
        const failed_str = std.fmt.bufPrint(&failed_buf, "{d}", .{record.failed_login_attempts}) catch "0";
        var auth_version_buf: [20]u8 = undefined;
        const auth_version_str = std.fmt.bufPrint(&auth_version_buf, "{d}", .{record.auth_version}) catch "0";

        const mfa_secret = record.getMFASecret() orelse "";
        const attributes_json = record.getAttributesJson() orelse "";

        const props = [_]auth_hmac.KeyValue{
            .{ .key = "attributes_json", .value = attributes_json },
            .{ .key = "auth_version", .value = auth_version_str },
            .{ .key = "created_at", .value = created_str },
            .{ .key = "email", .value = email },
            .{ .key = "failed_login_attempts", .value = failed_str },
            .{ .key = "hash_algorithm", .value = record.getHashAlgorithm() },
            .{ .key = "id", .value = id_str },
            .{ .key = "is_active", .value = if (record.is_active) "true" else "false" },
            .{ .key = "is_default_user", .value = if (record.is_default_user) "true" else "false" },
            .{ .key = "is_superuser", .value = if (record.is_superuser) "true" else "false" },
            .{ .key = "last_login", .value = last_login_str },
            .{ .key = "lockout_until", .value = lockout_str },
            .{ .key = "mfa_enabled", .value = if (record.mfa_enabled) "true" else "false" },
            .{ .key = "mfa_secret", .value = mfa_secret },
            .{ .key = "password_changed_at", .value = pwd_changed_str },
            .{ .key = "password_hash", .value = password_hash },
            .{ .key = "password_reset_required", .value = if (record.password_reset_required) "true" else "false" },
            .{ .key = "salt", .value = salt },
            .{ .key = "updated_at", .value = updated_str },
            .{ .key = "username", .value = username },
        };

        const hmac_bytes = computeRecordHmacChecked(hmac_key, &props);
        const hmac_hex = auth_hmac.hmacToHex(&hmac_bytes);

        // Store the HMAC hex string as a node property
        const node_id = self.user_nodes.get(user_id) orelse return error.UserNotFound;
        try self.store.setNodeProperty(node_id, "hmac", .{ .String = &hmac_hex });
    }

    // ChainRootRecord for HMAC chain integrity
    pub const ChainRootRecord = struct {
        chain_hash: [64]u8, // hex string
        chain_hash_len: u16,
        record_count: u64,
        last_verified: i64,
        hmac_key_id: [64]u8,
        hmac_key_id_len: u16,
        node_id: ?u64, // graph store node ID, null if not yet created
    };

    pub fn loadChainRoot(self: *Self) ?ChainRootRecord {
        const nodes_opt = self.store.getNodesByLabel(SECURITY_GRAPH_NAME, AUTH_CHAIN_ROOT_LABEL);
        if (nodes_opt == null) return null;
        const nodes = nodes_opt.?;
        if (nodes.len == 0) return null;

        const node_id = nodes[0];
        // Gap 0034: read the root's node body HYDRATE-ON-MISS. The raw
        // `getNodePtr` conflated "evicted from the bounded resident node
        // cache" with "missing from the store": a bulk ingest evicts the
        // bootstrap-era AuthChainRoot body (FIFO-oldest), the raw lookup
        // returns null, and every periodic HMAC verify round then reports
        // MissingChainRoot — a false "POSSIBLE TAMPERING" alarm on a
        // perfectly healthy fresh store, every 5 minutes until restart.
        // Hydration rebuilds the body from the durable engine, so null here
        // now really means "no chain root exists" — the genuine tamper
        // signal (root deleted/corrupted on disk) stays loud.
        const node = self.store.getNodePtrHydrated(node_id) orelse return null;
        if (!std.mem.eql(u8, node.graph_name, SECURITY_GRAPH_NAME)) return null;

        self.chain_root_node = node_id;

        var record = ChainRootRecord{
            .chain_hash = [_]u8{0} ** 64,
            .chain_hash_len = 0,
            .record_count = 0,
            .last_verified = 0,
            .hmac_key_id = [_]u8{0} ** 64,
            .hmac_key_id_len = 0,
            .node_id = node_id,
        };

        record.chain_hash_len = copyIntoField(&record.chain_hash, getStringProp(self.store, node_id, "chain_hash", ""));
        const count_val = getIntProp(self.store, node_id, "record_count", 0);
        record.record_count = if (count_val >= 0) @intCast(count_val) else 0;
        record.last_verified = getIntProp(self.store, node_id, "last_verified", 0);
        record.hmac_key_id_len = copyIntoField(&record.hmac_key_id, getStringProp(self.store, node_id, "hmac_key_id", ""));

        // Only return if we actually have a chain hash stored
        if (record.chain_hash_len == 0) return null;

        return record;
    }

    pub fn persistChainRoot(self: *Self, chain_hash_hex: []const u8, record_count: u64, hmac_key_id: []const u8) !void {
        const node_id = self.chain_root_node orelse blk: {
            const new_id = try self.createEntityNode(AUTH_CHAIN_ROOT_LABEL);
            self.chain_root_node = new_id;
            break :blk new_id;
        };

        try self.store.setNodeProperty(node_id, "chain_hash", .{ .String = chain_hash_hex });
        try self.store.setNodeProperty(node_id, "record_count", .{ .Int = safeI64(record_count) });
        try self.store.setNodeProperty(node_id, "last_verified", .{ .Int = compat_milliTimestamp() });
        try self.store.setNodeProperty(node_id, "hmac_key_id", .{ .String = hmac_key_id });
    }

    // Role operations
    pub fn persistRole(self: *Self, role_id: u64, name: []const u8, description: []const u8, parent_role: u64, priority: u32, is_system: bool) !void {
        if (name.len > 63 or description.len > 255) {
            return error.FieldTooLong;
        }

        var record = blankRoleRecord(role_id);
        record.name_len = copyIntoField(&record.name, name);
        record.description_len = copyIntoField(&record.description, description);
        record.parent_role = parent_role;
        record.priority = priority;
        record.is_system = is_system;
        record.created_at = compat_milliTimestamp();
        record.updated_at = record.created_at;

        try self.role_cache.put(role_id, record);
        try self.upsertRoleNode(record);
    }

    // CANARY: REQ=REQ-SONNY-6293-CHECKED-AUTH-DELETE; FEATURE="Checked security record deletion"; ASPECT=Role; STATUS=TESTED; TEST=tests/test_sonny6293_checked_auth_delete.zig; OWNER=security; UPDATED=2026-11-11
    pub fn removeRole(self: *Self, role_id: u64) !void {
        if (self.role_nodes.get(role_id)) |node_id| {
            try self.store.deleteNodeChecked(node_id);
            _ = self.role_nodes.remove(role_id);
        }
        _ = self.role_cache.remove(role_id);
    }

    pub fn getRole(self: *Self, role_id: u64) ?RoleRecord {
        return self.role_cache.get(role_id);
    }

    pub fn getRoleByName(self: *Self, name: []const u8) ?RoleRecord {
        var it = self.role_cache.valueIterator();
        while (it.next()) |record| {
            if (std.mem.eql(u8, record.getName(), name)) {
                return record.*;
            }
        }
        return null;
    }

    // CANARY: REQ=REQ-GPS-CATALOG-002; FEATURE="GPS Policy Persistence"; ASPECT=GetPolicyByName; STATUS=TESTED; TEST=tests/test_gps_policy_persistence.zig; OWNER=security; UPDATED=2026-05-20
    pub fn getPolicyByName(self: *Self, name: []const u8) ?PolicyRecord {
        var it = self.policy_cache.valueIterator();
        while (it.next()) |record| {
            if (std.mem.eql(u8, record.getName(), name)) {
                return record.*;
            }
        }
        return null;
    }

    // Permission operations
    pub fn persistPermission(self: *Self, permission_id: u64, name: []const u8, resource: []const u8, action: u8, conditions: ?[]const u8) !void {
        if (name.len > 63 or resource.len > 127) {
            return error.FieldTooLong;
        }

        var record = blankPermissionRecord(permission_id);
        record.name_len = copyIntoField(&record.name, name);
        record.resource_len = copyIntoField(&record.resource, resource);
        record.action = action;
        if (conditions) |cond| {
            if (cond.len > 511) return error.FieldTooLong;
            record.conditions_len = copyIntoField(&record.conditions, cond);
        }
        record.created_at = compat_milliTimestamp();

        try self.permission_cache.put(permission_id, record);
        try self.upsertPermissionNode(record);
    }

    // CANARY: REQ=REQ-SONNY-3037-REVOKE-PRINCIPAL; FEATURE="OfflineAuthStoreSafety"; ASPECT=PermissionIdSequence; STATUS=TESTED; TEST=tests/test_sonny3037_revoke_principal.zig; OWNER=security; UPDATED=2026-09-27
    /// SONNY-3037: the id for a new permission record: one more than any
    /// permission record's, loaded or not (as `nextPolicyId`). `geode grant`
    /// took the next user id, the same in every run over one set of users,
    /// so each grant replaced the previous one.
    pub fn nextPermissionId(self: *Self) u64 {
        var max_id: u64 = 0;
        var cached = self.permission_cache.keyIterator();
        while (cached.next()) |id| max_id = @max(max_id, id.*);
        var nodes = self.permission_nodes.keyIterator();
        while (nodes.next()) |id| max_id = @max(max_id, id.*);
        return max_id + 1;
    }

    pub fn removePermission(self: *Self, permission_id: u64) !void {
        _ = self.permission_cache.remove(permission_id);
        if (self.permission_nodes.fetchRemove(permission_id)) |kv| {
            self.store.deleteNode(kv.value);
        }
    }

    pub fn getPermission(self: *Self, permission_id: u64) ?PermissionRecord {
        return self.permission_cache.get(permission_id);
    }

    // Policy operations
    pub const PolicyPersistOptions = struct {
        policy_id: u64,
        name: []const u8,
        description: []const u8,
        graph: []const u8,
        table: []const u8,
        operation: u8,
        permissive: bool,
        enabled: bool,
        using_clause: ?[]const u8,
        check_clause: ?[]const u8,
        audit_level: u8,
        created_by: u64,
        /// GAP-0858: creation timestamp. `null` (the default, used by the
        /// create path) stamps the current time. Update-path callers (e.g.
        /// AuthGraphManager.alterPolicy) pass the existing record's
        /// `created_at` so an enable/disable/rename does NOT falsify the
        /// original creation timestamp in the HMAC-chained security graph.
        created_at: ?i64 = null,
        /// SONNY-2750: which system the record belongs to: `.gps` or `.rls`.
        /// Required, with no default, so no writer can leave it out.
        kind: PolicyKind,
        /// SONNY-2777: whether the record is new or replaces one. Required,
        /// with no default.
        mode: PersistMode,
    };

    /// SONNY-2777: `.create` writes a record whose id no record has
    /// (`error.PolicyIdInUse` otherwise). `.replace` rewrites an existing
    /// record of the same kind (`error.PolicyNotFound`,
    /// `error.PolicyKindMismatch`). A create used to reuse the node of any
    /// record with its id: `geode auth policy create` took its id from the
    /// next *user* id, and overwrote a GPS policy that had it.
    pub const PersistMode = enum { create, replace };

    // CANARY: REQ=REQ-SONNY-2777-POLICY-IDS; FEATURE="GPS Policy Persistence"; ASPECT=PolicyIdSequence; STATUS=TESTED; TEST=tests/test_sonny2777_policy_ids.zig; OWNER=security; UPDATED=2026-09-26
    /// SONNY-2777: the id for a new policy record: one more than any policy
    /// record's, loaded or not. Every policy writer takes its id here (GPS,
    /// `geode auth policy create`, the geode-auth tool), so no two share one.
    pub fn nextPolicyId(self: *Self) u64 {
        var max_id: u64 = 0;
        var cached = self.policy_cache.keyIterator();
        while (cached.next()) |id| max_id = @max(max_id, id.*);
        var nodes = self.policy_nodes.keyIterator();
        while (nodes.next()) |id| max_id = @max(max_id, id.*);
        return max_id + 1;
    }

    pub fn persistPolicy(self: *Self, opts: PolicyPersistOptions) !void {
        if (opts.name.len > 63 or opts.description.len > 255 or opts.graph.len > 63 or opts.table.len > 63) {
            return error.FieldTooLong;
        }
        if (opts.kind.property() == null) return error.InvalidPolicyKind;
        switch (opts.mode) {
            .create => if (self.policy_cache.contains(opts.policy_id) or self.policy_nodes.contains(opts.policy_id)) return error.PolicyIdInUse,
            .replace => {
                const existing = self.policy_cache.get(opts.policy_id) orelse return error.PolicyNotFound;
                if (existing.effectiveKind() != opts.kind) return error.PolicyKindMismatch;
            },
        }

        var record = blankPolicyRecord(opts.policy_id);
        record.name_len = copyIntoField(&record.name, opts.name);
        record.description_len = copyIntoField(&record.description, opts.description);
        record.graph_len = copyIntoField(&record.graph, opts.graph);
        record.table_len = copyIntoField(&record.table, opts.table);
        record.operation = opts.operation;
        record.permissive = opts.permissive;
        record.enabled = opts.enabled;
        if (opts.using_clause) |uc| {
            if (uc.len > 511) return error.FieldTooLong;
            record.using_clause_len = copyIntoField(&record.using_clause, uc);
        }
        if (opts.check_clause) |cc| {
            if (cc.len > 511) return error.FieldTooLong;
            record.check_clause_len = copyIntoField(&record.check_clause, cc);
        }
        record.audit_level = opts.audit_level;
        const now = compat_milliTimestamp();
        // GAP-0858: preserve the original creation timestamp on the update
        // path (alterPolicy passes existing.created_at); only the create path
        // (created_at == null) stamps "now". updated_at always advances.
        record.created_at = opts.created_at orelse now;
        record.updated_at = now;
        record.created_by = opts.created_by;
        record.kind = opts.kind;

        try self.policy_cache.put(opts.policy_id, record);
        try self.upsertPolicyNode(record);
    }

    // CANARY: REQ=REQ-SONNY-6293-CHECKED-AUTH-DELETE; FEATURE="Checked security record deletion"; ASPECT=Policy; STATUS=TESTED; TEST=tests/test_sonny6293_checked_auth_delete.zig; OWNER=security; UPDATED=2026-11-11
    pub fn removePolicy(self: *Self, policy_id: u64) !void {
        if (self.policy_nodes.get(policy_id)) |node_id| {
            try self.store.deleteNodeChecked(node_id);
            _ = self.policy_nodes.remove(policy_id);
        }
        _ = self.policy_cache.remove(policy_id);
    }

    pub fn getPolicy(self: *Self, policy_id: u64) ?PolicyRecord {
        return self.policy_cache.get(policy_id);
    }

    pub fn userIterator(self: *Self) std.AutoHashMap(u64, UserRecord).ValueIterator {
        return self.user_cache.valueIterator();
    }

    pub fn roleIterator(self: *Self) std.AutoHashMap(u64, RoleRecord).ValueIterator {
        return self.role_cache.valueIterator();
    }

    pub fn permissionIterator(self: *Self) std.AutoHashMap(u64, PermissionRecord).ValueIterator {
        return self.permission_cache.valueIterator();
    }

    pub fn policyIterator(self: *Self) std.AutoHashMap(u64, PolicyRecord).ValueIterator {
        return self.policy_cache.valueIterator();
    }

    pub fn blankUserRecord(user_id: u64) UserRecord {
        return UserRecord{
            .id = user_id,
            .username = [_]u8{0} ** 64,
            .username_len = 0,
            .email = [_]u8{0} ** 128,
            .email_len = 0,
            .password_hash = [_]u8{0} ** 256,
            .password_hash_len = 0,
            .salt = [_]u8{0} ** 32,
            .is_active = true,
            .is_superuser = false,
            .mfa_enabled = false,
            .mfa_secret = [_]u8{0} ** 64,
            .mfa_secret_len = 0,
            .failed_login_attempts = 0,
            .lockout_until = 0,
            .last_login = 0,
            .created_at = compat_milliTimestamp(),
            .updated_at = compat_milliTimestamp(),
            .password_changed_at = 0,
            .hash_algorithm = [_]u8{0} ** 16,
            .hash_algorithm_len = 0,
            .is_default_user = false,
            .password_reset_required = false,
            .auth_version = 1,
            .attributes_json = [_]u8{0} ** 2048,
            .attributes_json_len = 0,
            .attributes_len = 0,
        };
    }

    fn blankRoleRecord(role_id: u64) RoleRecord {
        return RoleRecord{
            .id = role_id,
            .name = [_]u8{0} ** 64,
            .name_len = 0,
            .description = [_]u8{0} ** 256,
            .description_len = 0,
            .parent_role = 0,
            .priority = 0,
            .is_system = false,
            .created_at = compat_milliTimestamp(),
            .updated_at = compat_milliTimestamp(),
        };
    }

    fn blankPermissionRecord(permission_id: u64) PermissionRecord {
        return PermissionRecord{
            .id = permission_id,
            .name = [_]u8{0} ** 64,
            .name_len = 0,
            .resource = [_]u8{0} ** 128,
            .resource_len = 0,
            .action = 0,
            .conditions = [_]u8{0} ** 512,
            .conditions_len = 0,
            .created_at = compat_milliTimestamp(),
        };
    }

    fn blankPolicyRecord(policy_id: u64) PolicyRecord {
        return PolicyRecord{
            .id = policy_id,
            .name = [_]u8{0} ** 64,
            .name_len = 0,
            .description = [_]u8{0} ** 256,
            .description_len = 0,
            .graph = [_]u8{0} ** 64,
            .graph_len = 0,
            .table = [_]u8{0} ** 64,
            .table_len = 0,
            .operation = 0,
            .permissive = false,
            .enabled = true,
            .using_clause = [_]u8{0} ** 512,
            .using_clause_len = 0,
            .check_clause = [_]u8{0} ** 512,
            .check_clause_len = 0,
            .audit_level = 0,
            .created_at = compat_milliTimestamp(),
            .updated_at = compat_milliTimestamp(),
            .created_by = 0,
            .kind = .legacy,
            .legacy_shape = .invalid,
            .malformed = false,
        };
    }

    fn blankGraphGrantRecord(grant_id: u64) GraphGrantRecord {
        return GraphGrantRecord{
            .id = grant_id,
            .user_id = 0,
            .graph_name = [_]u8{0} ** 128,
            .graph_name_len = 0,
            .action = 0,
            .granted_at = compat_timestamp(),
            .granted_by = 0,
        };
    }

    fn upsertGraphGrantNode(self: *Self, record: GraphGrantRecord) !void {
        const node_id = self.graph_grant_nodes.get(record.id) orelse try self.createEntityNode(GRAPH_GRANT_LABEL);
        try self.graph_grant_nodes.put(record.id, node_id);

        // The id is a 64-bit hash: store its bit pattern, not a clamped value.
        // Readers derive it from the fields (`graphGrantIdFromNode`).
        try self.store.setNodeProperty(node_id, "id", .{ .Int = @bitCast(record.id) });
        try self.store.setNodeProperty(node_id, "user_id", .{ .Int = safeI64(record.user_id) });
        try self.store.setNodeProperty(node_id, "graph_name", .{ .String = record.getGraphName() });
        try self.store.setNodeProperty(node_id, "action", .{ .Int = record.action });
        try self.store.setNodeProperty(node_id, "granted_at", .{ .Int = record.granted_at });
        try self.store.setNodeProperty(node_id, "granted_by", .{ .Int = safeI64(record.granted_by) });
    }

    /// SONNY-2731: the USING text a policy is loaded with when a stored field
    /// is longer than its record. No policy compiler accepts it, so the
    /// policy is kept fail-closed.
    pub const overlong_policy_text = "<stored policy text longer than the record holds>";

    pub fn copyIntoField(dest: []u8, src: []const u8) u16 {
        const max_len = dest.len;
        const len = @min(src.len, max_len);
        @memset(dest, 0);
        @memcpy(dest[0..len], src[0..len]);
        if (src.len > max_len) {
            log.warn("User storage field truncated", &.{
                Attr.uint("max", @intCast(max_len)),
                Attr.uint("actual", @intCast(src.len)),
            });
        }
        return @intCast(len);
    }

    fn getStringProp(store: *graph_store.GraphStore, node_id: u64, key: []const u8, default: []const u8) []const u8 {
        if (store.getNodeProperty(node_id, key)) |val| {
            if (val == .String) return val.String;
        }
        return default;
    }

    // CANARY: REQ=REQ-SONNY-2757-STORED-INT-CAST; FEATURE="AuthDDLPersistence"; ASPECT=CheckedStoredCasts; STATUS=TESTED; TEST=tests/test_sonny2757_policy_hygiene.zig; OWNER=security; UPDATED=2026-09-26
    /// SONNY-2757 (P29): a stored integer read into a narrower field. Such values
    /// were `@intCast` (negatives clamped to 0 first), which aborts a safe build
    /// on a value out of range while the security graph loads, before any
    /// signature check. Null (logged) when the value does not fit: the caller
    /// treats the record as tampered.
    fn storedInt(comptime T: type, value: i64, field: []const u8, record_id: u64) ?T {
        return std.math.cast(T, value) orelse {
            log.warn("security record has an out-of-range value; treated as tampered", &.{
                Attr.uint("record_id", record_id),
                Attr.string("field", field),
                Attr.int("value", value),
            });
            return null;
        };
    }

    fn getIntProp(store: *graph_store.GraphStore, node_id: u64, key: []const u8, default: i64) i64 {
        if (store.getNodeProperty(node_id, key)) |val| {
            if (val == .Int) return val.Int;
        }
        return default;
    }

    /// SONNY-2750: does node `node_id` have property `key`, of type `tag`?
    fn hasProp(store: *graph_store.GraphStore, node_id: u64, key: []const u8, tag: std.meta.Tag(graph_store.PropertyValue)) bool {
        const val = store.getNodeProperty(node_id, key) orelse return false;
        return val == tag;
    }

    /// SONNY-2750: which writer stored a :Policy record that has no `kind`
    /// (written before SONNY-2750), by the properties each one wrote. GPS
    /// (`AuthGraphManager.createPolicy`) wrote its scope graph (a name or
    /// "*"), an empty description and table, no CHECK clause, and a zero
    /// audit level and creator. The RLS writers do not: the geode-auth CLI
    /// (`user_manager`) writes the description "RLS policy" and a table, and
    /// `geode auth policy create` a table and an empty graph. A record that
    /// lacks a property this reads, or has one of another type, is
    /// `.invalid`: a missing property is never read as the value GPS wrote.
    fn legacyPolicyShape(store: *graph_store.GraphStore, node_id: u64) PolicyKind {
        const description = exactStringProp(store, node_id, "description") orelse return .invalid;
        const graph = exactStringProp(store, node_id, "graph") orelse return .invalid;
        const table = exactStringProp(store, node_id, "table") orelse return .invalid;
        const audit_level = exactIntProp(store, node_id, "audit_level") orelse return .invalid;
        const created_by = exactIntProp(store, node_id, "created_by") orelse return .invalid;
        const has_check = store.getNodeProperty(node_id, "check_clause") != null;
        const gps_shape = description.len == 0 and table.len == 0 and graph.len != 0 and !has_check and
            audit_level == 0 and created_by == 0;
        return if (gps_shape) .gps else .rls;
    }

    fn exactStringProp(store: *graph_store.GraphStore, node_id: u64, key: []const u8) ?[]const u8 {
        const val = store.getNodeProperty(node_id, key) orelse return null;
        return if (val == .String) val.String else null;
    }

    fn exactIntProp(store: *graph_store.GraphStore, node_id: u64, key: []const u8) ?i64 {
        const val = store.getNodeProperty(node_id, key) orelse return null;
        return if (val == .Int) val.Int else null;
    }

    fn getBoolProp(store: *graph_store.GraphStore, node_id: u64, key: []const u8, default: bool) bool {
        if (store.getNodeProperty(node_id, key)) |val| {
            if (val == .Bool) return val.Bool;
        }
        return default;
    }

    pub fn upsertUserNode(self: *Self, record: UserRecord) !void {
        const node_id = self.user_nodes.get(record.id) orelse try self.createEntityNode(USER_LABEL);
        try self.user_nodes.put(record.id, node_id);

        // Build a batch of all property mutations so the underlying
        // StorageAdapter mutex is acquired only once instead of 17+ times.
        // This prevents the CLI from hanging when the server is
        // concurrently servicing queries against the same adapter.
        const Entry = graph_store.GraphStore.BatchPropertyEntry;
        const PV = graph_store.PropertyValue;

        // Maximum possible entries: 20 (all conditional branches taken).
        var buf: [20]Entry = undefined;
        var n: usize = 0;

        buf[n] = .{ .key = "id", .value = PV{ .Int = safeI64(record.id) } };
        n += 1;
        buf[n] = .{ .key = "username", .value = PV{ .String = record.getUsername() } };
        n += 1;
        buf[n] = .{ .key = "email", .value = PV{ .String = record.getEmail() } };
        n += 1;
        buf[n] = .{ .key = "password_hash", .value = PV{ .String = record.getPasswordHash() } };
        n += 1;
        if (sliceUntilZero(&record.salt)) |salt_str| {
            buf[n] = .{ .key = "salt", .value = PV{ .String = salt_str } };
            n += 1;
        }
        buf[n] = .{ .key = "is_active", .value = PV{ .Bool = record.is_active } };
        n += 1;
        buf[n] = .{ .key = "is_superuser", .value = PV{ .Bool = record.is_superuser } };
        n += 1;
        buf[n] = .{ .key = "mfa_enabled", .value = PV{ .Bool = record.mfa_enabled } };
        n += 1;
        if (record.getMFASecret()) |mfa| {
            buf[n] = .{ .key = "mfa_secret", .value = PV{ .String = mfa } };
        } else {
            buf[n] = .{ .key = "mfa_secret", .value = null }; // remove
        }
        n += 1;
        buf[n] = .{ .key = "failed_login_attempts", .value = PV{ .Int = record.failed_login_attempts } };
        n += 1;
        buf[n] = .{ .key = "lockout_until", .value = PV{ .Int = record.lockout_until } };
        n += 1;
        buf[n] = .{ .key = "last_login", .value = PV{ .Int = record.last_login } };
        n += 1;
        buf[n] = .{ .key = "created_at", .value = PV{ .Int = record.created_at } };
        n += 1;
        buf[n] = .{ .key = "updated_at", .value = PV{ .Int = record.updated_at } };
        n += 1;
        if (record.hash_algorithm_len > 0) {
            buf[n] = .{ .key = "hash_algorithm", .value = PV{ .String = record.getHashAlgorithm() } };
            n += 1;
        }
        buf[n] = .{ .key = "is_default_user", .value = PV{ .Bool = record.is_default_user } };
        n += 1;
        buf[n] = .{ .key = "password_reset_required", .value = PV{ .Bool = record.password_reset_required } };
        n += 1;
        buf[n] = .{ .key = "auth_version", .value = PV{ .Int = safeI64(record.auth_version) } };
        n += 1;
        if (record.getAttributesJson()) |attrs| {
            buf[n] = .{ .key = "attributes_json", .value = PV{ .String = attrs } };
        } else {
            buf[n] = .{ .key = "attributes_json", .value = null }; // remove
        }
        n += 1;
        buf[n] = .{ .key = "password_changed_at", .value = PV{ .Int = record.password_changed_at } };
        n += 1;

        try self.store.setNodePropertiesBatch(node_id, buf[0..n]);
    }

    fn upsertRoleNode(self: *Self, record: RoleRecord) !void {
        const node_id = self.role_nodes.get(record.id) orelse try self.createEntityNode(ROLE_LABEL);
        try self.role_nodes.put(record.id, node_id);

        try self.store.setNodeProperty(node_id, "id", .{ .Int = safeI64(record.id) });
        try self.store.setNodeProperty(node_id, "name", .{ .String = record.getName() });
        try self.store.setNodeProperty(node_id, "description", .{ .String = record.getDescription() });
        try self.store.setNodeProperty(node_id, "parent_role", .{ .Int = safeI64(record.parent_role) });
        try self.store.setNodeProperty(node_id, "priority", .{ .Int = record.priority });
        try self.store.setNodeProperty(node_id, "is_system", .{ .Bool = record.is_system });
        try self.store.setNodeProperty(node_id, "created_at", .{ .Int = record.created_at });
        try self.store.setNodeProperty(node_id, "updated_at", .{ .Int = record.updated_at });
    }

    fn upsertPermissionNode(self: *Self, record: PermissionRecord) !void {
        const node_id = self.permission_nodes.get(record.id) orelse try self.createEntityNode(PERMISSION_LABEL);
        try self.permission_nodes.put(record.id, node_id);

        try self.store.setNodeProperty(node_id, "id", .{ .Int = safeI64(record.id) });
        try self.store.setNodeProperty(node_id, "name", .{ .String = record.getName() });
        try self.store.setNodeProperty(node_id, "resource", .{ .String = record.getResource() });
        try self.store.setNodeProperty(node_id, "action", .{ .Int = record.action });
        if (record.getConditions()) |cond| {
            try self.store.setNodeProperty(node_id, "conditions", .{ .String = cond });
        }
        try self.store.setNodeProperty(node_id, "created_at", .{ .Int = record.created_at });
    }

    fn upsertPolicyNode(self: *Self, record: PolicyRecord) !void {
        const node_id = self.policy_nodes.get(record.id) orelse try self.createEntityNode(POLICY_LABEL);
        try self.policy_nodes.put(record.id, node_id);

        try self.store.setNodeProperty(node_id, "id", .{ .Int = safeI64(record.id) });
        try self.store.setNodeProperty(node_id, "name", .{ .String = record.getName() });
        try self.store.setNodeProperty(node_id, "description", .{ .String = record.getDescription() });
        try self.store.setNodeProperty(node_id, "graph", .{ .String = record.getGraph() });
        try self.store.setNodeProperty(node_id, "table", .{ .String = record.getTable() });
        try self.store.setNodeProperty(node_id, "operation", .{ .Int = record.operation });
        try self.store.setNodeProperty(node_id, "permissive", .{ .Bool = record.permissive });
        try self.store.setNodeProperty(node_id, "enabled", .{ .Bool = record.enabled });
        if (record.getUsingClause()) |uc| {
            try self.store.setNodeProperty(node_id, "using_clause", .{ .String = uc });
        }
        if (record.getCheckClause()) |cc| {
            try self.store.setNodeProperty(node_id, "check_clause", .{ .String = cc });
        }
        try self.store.setNodeProperty(node_id, "audit_level", .{ .Int = record.audit_level });
        try self.store.setNodeProperty(node_id, "created_at", .{ .Int = record.created_at });
        try self.store.setNodeProperty(node_id, "updated_at", .{ .Int = record.updated_at });
        try self.store.setNodeProperty(node_id, "created_by", .{ .Int = safeI64(record.created_by) });
        // SONNY-2750: persistPolicy admits only a kind with a stored form.
        try self.store.setNodeProperty(node_id, "kind", .{ .String = record.kind.property() orelse return error.InvalidPolicyKind });
    }

    fn createEntityNode(self: *Self, label: []const u8) !u64 {
        const labels = [_][]const u8{label};
        return self.store.createNodeWithGraph(@constCast(&labels), SECURITY_GRAPH_NAME);
    }

    fn safeI64(value: u64) i64 {
        const max = std.math.maxInt(i64);
        if (value > @as(u64, @intCast(max))) {
            log.warn("User storage value truncated to i64", &.{Attr.uint("value", value)});
            return max;
        }
        return @intCast(value);
    }

    fn sliceUntilZero(bytes: []const u8) ?[]const u8 {
        var len: usize = 0;
        while (len < bytes.len) : (len += 1) {
            if (bytes[len] == 0) break;
        }
        if (len == 0) return null;
        return bytes[0..len];
    }
};

// ─── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "blankUserRecord initializes new HMAC fields correctly" {
    const record = UserStorageBackend.blankUserRecord(42);

    // Verify new fields are initialized to defaults
    try testing.expectEqual(@as(u16, 0), record.hash_algorithm_len);
    try testing.expect(std.mem.eql(u8, record.hash_algorithm[0..16], &([_]u8{0} ** 16)));
    try testing.expectEqual(false, record.is_default_user);
    try testing.expectEqual(false, record.password_reset_required);
    try testing.expectEqual(@as(i64, 0), record.password_changed_at);

    // Verify existing fields still initialized correctly
    try testing.expectEqual(@as(u64, 42), record.id);
    try testing.expectEqual(true, record.is_active);
    try testing.expectEqual(false, record.is_superuser);
    try testing.expectEqual(@as(u32, 0), record.attributes_len);
}

test "blankUserRecord getHashAlgorithm returns empty for default" {
    const record = UserStorageBackend.blankUserRecord(1);
    try testing.expectEqual(@as(usize, 0), record.getHashAlgorithm().len);
}

test "persistUserWithHmac stores hmac property on graph node" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    const hmac_key = [_]u8{0xab} ** 32;
    try backend.persistUserWithHmac(1, "alice", "alice@example.com", "hashed_pw", "salt123", &hmac_key);

    // Verify user was persisted
    const user = backend.getUser(1);
    try testing.expect(user != null);
    try testing.expect(std.mem.eql(u8, user.?.getUsername(), "alice"));

    // Verify the hmac property is stored on the graph node (64 hex chars)
    const node_id = backend.user_nodes.get(1);
    try testing.expect(node_id != null);
    const hmac_prop = store.getNodeProperty(node_id.?, "hmac");
    try testing.expect(hmac_prop != null);
    try testing.expect(hmac_prop.? == .String);
    try testing.expectEqual(@as(usize, 64), hmac_prop.?.String.len);

    // Verify all chars are valid hex
    for (hmac_prop.?.String) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "persistUserWithHmac produces deterministic HMAC" {
    var store1 = try graph_store.GraphStore.init(testing.allocator);
    defer store1.deinit();
    var backend1 = try UserStorageBackend.init(testing.allocator, &store1);
    defer backend1.deinit();

    var store2 = try graph_store.GraphStore.init(testing.allocator);
    defer store2.deinit();
    var backend2 = try UserStorageBackend.init(testing.allocator, &store2);
    defer backend2.deinit();

    const hmac_key = [_]u8{0x42} ** 32;

    try backend1.persistUserWithHmac(1, "bob", "bob@example.com", "pw_hash", "saltsalt", &hmac_key);
    try backend2.persistUserWithHmac(1, "bob", "bob@example.com", "pw_hash", "saltsalt", &hmac_key);

    const node_id1 = backend1.user_nodes.get(1).?;
    const node_id2 = backend2.user_nodes.get(1).?;

    const hmac1 = store1.getNodeProperty(node_id1, "hmac").?.String;
    const hmac2 = store2.getNodeProperty(node_id2, "hmac").?.String;

    try testing.expect(std.mem.eql(u8, hmac1, hmac2));
}

test "loadChainRoot returns null when no chain root exists" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    const root = backend.loadChainRoot();
    try testing.expect(root == null);
}

test "persistChainRoot creates and loadChainRoot retrieves" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    // Persist a chain root
    const chain_hash_hex = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    try backend.persistChainRoot(chain_hash_hex, 5, "key-id-001");

    // Load and verify
    const root = backend.loadChainRoot();
    try testing.expect(root != null);
    const r = root.?;
    try testing.expectEqual(@as(u64, 5), r.record_count);
    try testing.expect(r.node_id != null);
    try testing.expect(r.last_verified > 0);
    try testing.expect(std.mem.eql(u8, r.chain_hash[0..r.chain_hash_len], chain_hash_hex));
    try testing.expect(std.mem.eql(u8, r.hmac_key_id[0..r.hmac_key_id_len], "key-id-001"));
}

test "persistChainRoot updates existing chain root" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    const hash1 = "1111111111111111111111111111111111111111111111111111111111111111";
    const hash2 = "2222222222222222222222222222222222222222222222222222222222222222";

    try backend.persistChainRoot(hash1, 3, "key-v1");
    try backend.persistChainRoot(hash2, 7, "key-v2");

    const root = backend.loadChainRoot();
    try testing.expect(root != null);
    const r = root.?;
    try testing.expectEqual(@as(u64, 7), r.record_count);
    try testing.expect(std.mem.eql(u8, r.chain_hash[0..r.chain_hash_len], hash2));
    try testing.expect(std.mem.eql(u8, r.hmac_key_id[0..r.hmac_key_id_len], "key-v2"));
}

test "new UserRecord fields persist and reload from graph" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    var backend = try UserStorageBackend.init(testing.allocator, &store);
    defer backend.deinit();

    // Create a user and manually set new fields
    try backend.persistUser(10, "admin", "admin@db.local", "argon2hash", "randomsalt");
    var record = backend.getUser(10).?;

    // Set the new HMAC-related fields
    record.hash_algorithm_len = UserStorageBackend.copyIntoField(&record.hash_algorithm, "argon2id");
    record.is_default_user = true;
    record.password_reset_required = true;
    record.password_changed_at = 1700000000;

    // Update cache and persist to graph
    try backend.user_cache.put(10, record);
    try backend.upsertUserNode(record);

    // Verify values in the graph node
    const node_id = backend.user_nodes.get(10).?;
    const algo = store.getNodeProperty(node_id, "hash_algorithm");
    try testing.expect(algo != null);
    try testing.expect(std.mem.eql(u8, algo.?.String, "argon2id"));

    const default_user = store.getNodeProperty(node_id, "is_default_user");
    try testing.expect(default_user != null);
    try testing.expect(default_user.?.Bool == true);

    const reset_req = store.getNodeProperty(node_id, "password_reset_required");
    try testing.expect(reset_req != null);
    try testing.expect(reset_req.?.Bool == true);

    const pwd_changed = store.getNodeProperty(node_id, "password_changed_at");
    try testing.expect(pwd_changed != null);
    try testing.expectEqual(@as(i64, 1700000000), pwd_changed.?.Int);
}

// CANARY: REQ=REQ-AUTH-HMAC-002; FEATURE="UserStorageHmac"; ASPECT=Integration; STATUS=TESTED; TEST=test_persistUserWithHmac_stores_hmac; OWNER=security; UPDATED=2026-02-24
