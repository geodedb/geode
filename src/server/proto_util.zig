// CANARY: REQ=REQ-PERF-PROTO-ARENA-001; FEATURE="ArenaProtoSerialization"; ASPECT=DataPageSerialization; STATUS=TESTED; OWNER=engine; UPDATED=2026-02-17
const std = @import("std");
const schema = @import("schema");
// Use relative imports since this file is part of the geode module
const value_types = @import("../value_types.zig");
const execution = @import("../execution.zig");
const graph_store = @import("../graph_store.zig");
const heap = @import("../storage/heap.zig");
const type_helpers = @import("../eval/type_helpers.zig");
const eval_extended = @import("../eval_extended.zig");
const property_codec = @import("../property_value_codec.zig");
const unique_constraints = @import("../execution/unique_constraints.zig");
const fle_integration = @import("../fle_integration.zig");

pub const ParamBindings = struct {
    names: []const []const u8,
    values: []const value_types.Value,
};

pub const ErrorInfo = struct {
    code: []const u8,
    message: []const u8,
};

pub fn parseParams(allocator: std.mem.Allocator, params: []const schema.Param) !ParamBindings {
    if (params.len == 0) {
        return .{ .names = &.{}, .values = &.{} };
    }

    var names = try allocator.alloc([]const u8, params.len);
    errdefer allocator.free(names);
    var values = try allocator.alloc(value_types.Value, params.len);
    errdefer allocator.free(values);
    // SONNY-2727: a refused parameter frees what the ones before it decoded
    // (the refusals the checked narrowing adds reach this path on purpose).
    var decoded: usize = 0;
    errdefer for (names[0..decoded], values[0..decoded]) |name, value| {
        allocator.free(name);
        freeParamValue(allocator, value);
    };

    for (params, 0..) |param, i| {
        const name = try allocator.dupe(u8, param.name);
        errdefer allocator.free(name);
        values[i] = if (param.value) |val| try protoValueToValue(allocator, val, 0) else .Null;
        names[i] = name;
        decoded = i + 1;
    }

    return .{ .names = names, .values = values };
}

pub fn freeParamBindings(allocator: std.mem.Allocator, bindings: ParamBindings) void {
    for (bindings.names) |name| allocator.free(name);
    for (bindings.values) |val| freeParamValue(allocator, val);
    allocator.free(bindings.names);
    allocator.free(bindings.values);
}

// CANARY: REQ=REQ-SONNY-2727-PARAM-DECODER-NARROWING; FEATURE="WireParameters"; ASPECT=CheckedNarrowing; STATUS=TESTED; TEST=tests/test_sonny2727_param_decoder_narrowing.zig; OWNER=security; UPDATED=2026-09-26
/// A client's parameter as an engine value.
///
/// SONNY-2727: every narrowing is checked. A SMALLINT outside i16, a finite
/// REAL outside f32, a CHAR or VARCHAR longer than 65535 bytes, a decimal
/// `scale` or `orig_scale` outside u8, and a decimal coefficient of the
/// smallest i128 (which has no negation, and is outside every DECIMAL) are
/// refused with `error.InvalidParams`, which the transports send as 22023.
/// Each was an unchecked cast: one parameter aborted a ReleaseSafe server.
pub fn protoValueToValue(allocator: std.mem.Allocator, value: schema.Value, depth: usize) !value_types.Value {
    if (depth > 64) return error.ParamsTooDeep;
    const kind = value.kind orelse return .Null;
    return switch (kind) {
        .null_val => .Null,
        .bool_val => |b| .{ .Bool = b },
        .int_val => |iv| switch (iv.kind) {
            .INT => .{ .Int = iv.value },
            .SMALLINT => .{ .SmallInt = std.math.cast(i16, iv.value) orelse return error.InvalidParams },
            .BIGINT => .{ .BigInt = iv.value },
            else => .{ .Int = iv.value },
        },
        .double_val => |dv| switch (dv.kind) {
            .REAL => .{ .Real = try checkedReal(dv.value) },
            .DOUBLE => .{ .Double = dv.value },
            else => .{ .Double = dv.value },
        },
        .string_val => |sv| switch (sv.kind) {
            .CHAR => .{ .Char = .{ .n = try checkedCharLen(sv.value.len), .data = try allocator.dupe(u8, sv.value) } },
            .VARCHAR => .{ .Varchar = .{ .n = try checkedCharLen(sv.value.len), .data = try allocator.dupe(u8, sv.value) } },
            .TEXT => .{ .Text = try allocator.dupe(u8, sv.value) },
            else => .{ .Str = try allocator.dupe(u8, sv.value) },
        },
        .decimal_val => |dec| blk: {
            const coeff = std.fmt.parseInt(i128, dec.coeff, 10) catch return error.InvalidParams;
            if (coeff == std.math.minInt(i128)) return error.InvalidParams;
            const scale = std.math.cast(u8, dec.scale) orelse return error.InvalidParams;
            const orig_scale = std.math.cast(u8, dec.orig_scale) orelse return error.InvalidParams;
            const orig_repr = if (dec.orig_repr.len > 0)
                try allocator.dupe(u8, dec.orig_repr)
            else
                null;
            break :blk .{ .Decimal = .{
                .coeff = coeff,
                .scale = scale,
                .orig_scale = orig_scale,
                .orig_repr = orig_repr,
            } };
        },
        .bytes_val => |bv| .{ .Bytea = try allocator.dupe(u8, bv.value) },
        .list_val => |lv| blk: {
            const list = try allocator.alloc(value_types.Value, lv.values.items.len);
            // SONNY-2727: a refused item frees the list and the items before it.
            var decoded: usize = 0;
            errdefer {
                for (list[0..decoded]) |item| freeParamValue(allocator, item);
                allocator.free(list);
            }
            for (lv.values.items, 0..) |item, idx| {
                list[idx] = try protoValueToValue(allocator, item, depth + 1);
                decoded = idx + 1;
            }
            break :blk .{ .List = list };
        },
        .map_val => |mv| blk: {
            var map = std.StringHashMap(value_types.Value).init(allocator);
            // SONNY-2727: a refused entry frees the entries before it.
            errdefer {
                var it = map.iterator();
                while (it.next()) |e| {
                    allocator.free(e.key_ptr.*);
                    freeParamValue(allocator, e.value_ptr.*);
                }
                map.deinit();
            }
            // CANARY: REQ=REQ-SONNY-2818-PARAM-MAP-DUP-KEYS; FEATURE="WireParameters"; ASPECT=DuplicateMapKeys; STATUS=TESTED; TEST=tests/test_sonny2818_param_map_dup_keys.zig; OWNER=security; UPDATED=2026-09-27
            // SONNY-2818: a repeated key frees the duplicate key and the value
            // it replaces (the last value still wins). `put` kept the stored
            // key and dropped both, so a client grew the server's memory by
            // about the size of each request (the peer path's fix, 076a7ba1).
            for (mv.entries.items) |entry| {
                const key = try allocator.dupe(u8, entry.key);
                errdefer allocator.free(key);
                const val = if (entry.value) |v|
                    try protoValueToValue(allocator, v, depth + 1)
                else
                    value_types.Value.Null;
                errdefer freeParamValue(allocator, val);
                const slot = try map.getOrPut(key);
                if (slot.found_existing) {
                    allocator.free(key);
                    freeParamValue(allocator, slot.value_ptr.*);
                }
                slot.value_ptr.* = val;
            }
            break :blk .{ .Map = map };
        },
        .ext_val => |ev| try property_codec.extValueToProjectedValue(allocator, try property_codec.protoExtendedToExtValue(allocator, ev)),
        .node_val, .edge_val, .path_val => return error.UnsupportedParamType,
    };
}

fn freeParamValue(allocator: std.mem.Allocator, value: value_types.Value) void {
    property_codec.freeValue(allocator, value);
}

/// SONNY-2727: a REAL parameter as f32. A finite value outside f32 is
/// refused; infinities and NaN are f32 values and pass.
fn checkedReal(v: f64) error{InvalidParams}!f32 {
    if (std.math.isFinite(v) and @abs(v) > std.math.floatMax(f32)) return error.InvalidParams;
    return @floatCast(v);
}

/// SONNY-2727: a CHAR or VARCHAR length as the type's u16.
fn checkedCharLen(len: usize) error{InvalidParams}!u16 {
    return std.math.cast(u16, len) orelse error.InvalidParams;
}

// CANARY: REQ=REQ-SONNY-6359-ALTER-USER-OTHER-PASSWORD; FEATURE="GQL Auth DDL"; ASPECT=AdminResetOverWire; STATUS=TESTED; TEST=tests/test_sonny6359_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6359: whether the QUIC / gRPC password intercept handles `ALTER
/// USER <target> SET PASSWORD`: the session's own password (it also runs
/// during a forced reset), and any request with no authenticated user (the
/// intercept refuses it). Another user's goes to the parser, which runs it
/// as `geode.auth.user_reset_password` (Admin only, the password policy,
/// audited), as docs/GQL_AUTH_DDL.md maps it; the intercept refused it with
/// 42501 for everyone, Admin included.
pub fn passwordInterceptApplies(authenticated_user: ?[]const u8, target: []const u8) bool {
    const user = authenticated_user orelse return true;
    return std.mem.eql(u8, user, target);
}

pub fn mapError(err: anyerror) ErrorInfo {
    return switch (err) {
        // SONNY-2675: grouping_error (42803), the class every other grouping
        // refusal uses (a nested aggregate, an ungrouped HAVING reference, an
        // aggregate in a per-row filter); it was the generic 42000.
        error.GroupingError => .{ .code = "42803", .message = "grouping error: non-aggregated expression not in GROUP BY" },
        // GAP-0914: a GROUP BY key that resolves to no alias, variable, or
        // binding is rejected instead of collapsing rows into one null group.
        error.UnknownGroupKey => .{ .code = "42703", .message = "GROUP BY key does not resolve to any RETURN alias, variable, or binding" },
        error.UnorderedPagination => .{ .code = "US001", .message = "OFFSET requires ORDER BY clause" },
        error.TransactionAlreadyActive => .{ .code = "25001", .message = "Transaction already active" },
        // GAP-0917: statement failed mid-transaction; everything until
        // ROLLBACK is rejected and COMMIT aborts. 25P02 = in_failed_sql_transaction.
        error.TransactionAborted => .{ .code = "25P02", .message = "Current transaction is aborted; statements are rejected until ROLLBACK or COMMIT ends it (COMMIT fails with 40000)" },
        // SONNY-3348 (round 19, m3): a failed statement's undo could not undo
        // every change it made: the statement is partly applied. 40003 =
        // statement_completion_unknown; do not retry it blindly.
        error.StatementUndoIncomplete => .{ .code = "40003", .message = "The statement failed and its changes could not all be undone; it may be partly applied. Check the data before retrying" },
        // SONNY-3348 (round 19, m3): ROLLBACK could not undo every change of
        // the transaction; it is over, and may be partly applied.
        error.RollbackIncomplete => .{ .code = "40003", .message = "ROLLBACK could not undo every change of the transaction; it ended, and may be partly applied" },
        // SONNY-3031: the storage engine could not commit the transaction's
        // changes; the transaction is rolled back.
        error.SessionCommitFailed => .{ .code = "40000", .message = "The transaction's changes could not be committed to storage; the transaction was rolled back" },
        error.NoActiveTransaction => .{ .code = "25000", .message = "No active transaction" },
        // SONNY-3348 (round 18, I2): COMMIT of a transaction a failed
        // statement aborted: it was rolled back, and it is over.
        error.TransactionRolledBack => .{ .code = "40000", .message = "The transaction failed and was rolled back; COMMIT did not commit it" },
        error.UnionColumnCountMismatch => .{ .code = "42601", .message = "UNION column count mismatch" },
        // SONNY-2755: `YIELD path, path` used to free that column twice.
        error.DuplicateYieldColumn => .{ .code = "42702", .message = "YIELD names the same column more than once; name each column once" },
        // SONNY-2791: the __geode_* graphs are the engine's own.
        // SONNY-2729: the RLS post-filter could not allocate what it needs;
        // it withheld the rows rather than return them unchecked.
        error.RowSecurityFilterUnavailable => .{ .code = "53200", .message = "Out of memory: the row-level security filter could not run, so no rows were returned" },
        error.InternalGraph => .{ .code = "42501", .message = "The __geode_* graphs are internal: a statement cannot select, create or drop one" },
        // SONNY-3191 (N-7): CREATE or DROP GRAPH of a current- or home-graph name.
        error.ReservedGraphName => .{ .code = "42939", .message = "CURRENT_GRAPH, CURRENT_PROPERTY_GRAPH, HOME_GRAPH and HOME_PROPERTY_GRAPH name the session's current and home graphs: no graph can be created or dropped by these names" },
        error.DuplicateGraph => .{ .code = "42P07", .message = "Duplicate graph name" },
        error.GraphNotFound => .{ .code = "3F000", .message = "Graph does not exist" },
        // SONNY-3038: geode.auth.revoke could not save the revoke.
        // SONNY-1333: the privilege is taken away in memory first.
        error.RevokeNotPersisted => .{ .code = "58030", .message = "The revoke could not be saved to the security graph: the privilege is removed now but returns at the next start. Retry it" },
        // CANARY: REQ=REQ-SONNY-6324-FLE-CATALOG-FAIL-CLOSED; FEATURE="FieldLevelEncryption"; ASPECT=SqlstateMapping; STATUS=TESTED; TEST=tests/test_sonny6324_fle_catalog_fail_closed.zig; OWNER=security; UPDATED=2026-11-11
        // SONNY-6324: the FLE catalog fails closed (58030 io_error, as the
        // other "could not be saved / read" refusals).
        error.FleCatalogNotPersisted => .{ .code = "58030", .message = "The FLE catalog could not be saved; the change was not applied. Retry it" },
        error.FleRevokeNotPersisted => .{ .code = "58030", .message = "The plaintext-access revoke is in effect but could not be saved to the FLE catalog; the role regains access at the next start unless the revoke is retried and saved. Retry it" },
        // CANARY: REQ=REQ-SONNY-6335-NO-INDEX-ON-ENCRYPTED-FIELD; FEATURE="FieldLevelEncryption"; ASPECT=SqlstateMapping; STATUS=TESTED; TEST=tests/test_sonny6335_fle_identity_and_indexes.zig; OWNER=security; UPDATED=2026-11-12
        // SONNY-6335: no index or UNIQUE constraint over an encrypted field.
        // SONNY-6362: MERGE cannot match a randomized FLE ciphertext.
        // SONNY-6433: a MERGE key property that is null can match nothing.
        error.NullMergeKey => .{ .code = "22004", .message = "null value not allowed: a MERGE pattern's property value is null. A null property is absent, and `k = null` is never true, so the pattern can match nothing and MERGE does not create an element without the key. Give the key a value, or use CREATE" },
        error.MergeOnEncryptedField => .{ .code = "0A000", .message = "MERGE on an FLE-encrypted property is not supported: the stored value is randomized ciphertext, so a pattern value never matches it and MERGE would create a duplicate. MERGE on an unencrypted key and set the encrypted property with ON CREATE SET / SET" },
        error.IndexOnEncryptedField => .{ .code = "0A000", .message = "The field is FLE-encrypted: an index or UNIQUE / NODE KEY constraint over it would hold ciphertext (or plaintext); none can be created. Equality search over an encrypted field is not available; index or constrain an unencrypted property instead" },
        error.EncryptedFieldIndexed => .{ .code = "0A000", .message = "The field has an index or a UNIQUE / NODE KEY constraint over it; drop it before encrypting the field" },
        // SONNY-6341: CALL geode.fle.grantRole / revokeRole.
        error.FleRoleGrantNotPersisted => .{ .code = "58030", .message = "The FLE role grant could not be saved to the security graph; it was not applied. Retry it" },
        error.FleRoleRevokeNotPersisted => .{ .code = "58030", .message = "The FLE role revoke is in effect but could not be saved to the security graph; the role may return at the next start. Retry it" },
        error.FleRoleUserNotFound => .{ .code = "42704", .message = "User does not exist" },
        error.InvalidFleRole => .{ .code = "22023", .message = "An FLE role name is non-empty and uses only letters, digits, '_' and '-'" },
        error.FleCatalogUnavailable => .{ .code = "58030", .message = "The FLE catalog could not be loaded, so which fields are encrypted is unknown; string property writes and reads are refused until it is restored (see the server log)" },
        // SONNY-6327: an encrypted value the principal may read does not
        // decrypt (damaged, or written under another key or identity).
        error.FleDecryptionFailed => .{ .code = "58030", .message = "An encrypted property value could not be decrypted (damaged, or written under another FLE key); the read is refused (see the server log)" },
        error.EncryptionRequired => .{ .code = "58030", .message = "The value must be stored encrypted and could not be encrypted (FLE catalog or keys unavailable); nothing was written" },
        // SONNY-1333: geode.auth.grant could not save the grant.
        error.GrantNotPersisted => .{ .code = "58030", .message = "The grant could not be saved to the security graph; nothing was granted. Retry it" },
        // SONNY-3038: DROP USER, ALTER USER (password, role, ENABLE/DISABLE),
        // geode.auth.user_import could not save the change. The stored user
        // is unchanged; a delete, a disable, a password change or a role
        // downgrade locks the user out until a change to it is saved or the
        // next start.
        error.UserNotPersisted => .{ .code = "58030", .message = "The change to the user could not be saved to the security graph and was not made; a delete, disable, password change or role downgrade locks the user out until a change to it is saved. Retry it" },
        // SONNY-3038: CREATE ROLE (not created) or DROP ROLE (removed now,
        // but its stored record returns at the next start).
        // SONNY-6293: a security record's node could not be deleted (DROP
        // POLICY): nothing was removed, the record is still stored and in
        // force.
        error.SecurityRecordDeleteFailed => .{ .code = "58030", .message = "A record could not be deleted from the security graph; nothing was removed and it is still in force. Retry it" },
        // SONNY-3034: a geode.rls.* restriction change that could not be
        // stored in the security graph.
        // SONNY-6369: a geode.rls add / remove procedure in a process with no
        // RLS filter or expression engine (it answered 00000 "error:" rows).
        error.RlsEngineNotInitialized => .{ .code = "55000", .message = "The row-level security engine is not initialized in this process (the server was started without RLS support), so the restriction was not changed" },
        error.RlsRestrictionNotPersisted => .{ .code = "58030", .message = "The RLS restriction change could not be saved to the security graph and was not made (an add is taken out again; a removal leaves the restriction in force). Retry it" },
        error.RoleNotPersisted => .{ .code = "58030", .message = "The role change could not be saved to the security graph: CREATE ROLE created nothing; DROP ROLE removed the role now but it returns at the next start. Retry it" },
        // SONNY-3028: DROP GRAPH of the graph the session's transaction changed.
        // SONNY-3134: or another session's open transaction.
        error.ObjectInUse => .{ .code = "55006", .message = "Object in use: an open transaction (this session's or another's) changed the graph; it can be dropped or replaced once that transaction commits or rolls back" },
        // SONNY-3132: DROP GRAPH default, CREATE OR REPLACE GRAPH default.
        error.CannotDropDefaultGraph => .{ .code = "0A000", .message = "The default graph cannot be dropped or replaced" },
        // ENG-3903: a MERGE relationship endpoint that is neither bound by a
        // preceding clause nor describable by a label/property pattern is
        // rejected instead of committing an empty success (silent write loss).
        error.UnboundVariable => .{ .code = "42000", .message = "Unbound variable: the variable is not bound by a preceding clause and carries no label or property to match or create on" },
        // Task 12 (enterprise-ingest-throughput): bulk-ingest MATCH+CREATE
        // edge fast-path errors.  Map to GQL spec "graph node not found"
        // class (09000) so clients get a meaningful status rather than
        // the generic internal-error fallback.
        error.SourceNodeNotFound => .{ .code = "09000", .message = "Source node not found" },
        error.TargetNodeNotFound => .{ .code = "09000", .message = "Target node not found" },
        // CANARY: REQ=REQ-DSN-GRAPH-BIND-005; FEATURE="DSNGraphBinding"; ASPECT=GraphBoundError; STATUS=IMPL; OWNER=transport; UPDATED=2026-03-25
        error.GraphBound => .{ .code = "42000", .message = "USE GRAPH not allowed: session is bound to a graph via DSN connection string" },
        error.DuplicateSchema => .{ .code = "42P07", .message = "Duplicate schema name" },
        error.SchemaNotFound => .{ .code = "3F000", .message = "Schema does not exist" },
        error.DuplicateIndex => .{ .code = "42P07", .message = "Duplicate index name: an index of this name exists in the graph (index names are unique per graph, across labels)" },
        error.IndexAlreadyExists => .{ .code = "42P07", .message = "Duplicate index name" },
        // CANARY: REQ=REQ-SONNY-6294-DROP-INDEX-RULES; FEATURE="SchemaCatalog"; ASPECT=SqlstateMapping; STATUS=TESTED; TEST=tests/test_sonny6294_drop_index_rules.zig; OWNER=catalog; UPDATED=2026-11-11
        // SONNY-6294: a missing index or constraint is undefined_object
        // (42704); both reached clients as 58000 (system error).
        error.IndexNotFound => .{ .code = "42704", .message = "Index does not exist" },
        error.ConstraintNotFound => .{ .code = "42704", .message = "Constraint does not exist in the session's graph" },
        error.FulltextIndexInDefaultGraph => .{ .code = "0A000", .message = "A fulltext index lives in the default graph: drop it from the default graph (USE GRAPH default; DROP INDEX <name>)" },
        // SONNY-1319: the name is held in another graph by an index whose
        // runtime structure is keyed by name alone (vector and other advanced
        // indexes), so it cannot be created in this graph too.
        error.IndexNameInUseByOtherGraph => .{ .code = "42P07", .message = "Index name is in use in another graph by an index type whose runtime structure is shared by name (vector and other advanced indexes); choose another name" },
        // SONNY-2809: a second CREATE CONSTRAINT with the same name.
        error.ConstraintAlreadyExists => .{ .code = "42710", .message = "Duplicate constraint name: a constraint of this name exists in the graph (constraint names are unique per graph, across labels)" },
        // CANARY: REQ=REQ-SONNY-2846-UNIQUE-ENFORCEMENT; FEATURE="ConstraintEnforcement"; ASPECT=UniqueViolationCode; STATUS=TESTED; TEST=tests/test_sonny2846_unique_constraint_enforcement.zig; OWNER=engine; UPDATED=2026-11-11
        // SONNY-2846: a statement that would give two nodes one UNIQUE key,
        // or a CREATE CONSTRAINT over existing duplicates. 23505 is SQL's
        // unique_violation. The message names the constraint (or how many
        // duplicate groups there are), never a value.
        error.UniqueConstraintViolation => .{ .code = "23505", .message = unique_constraints.violationMessage() },
        error.UniqueConstraintCheckFailed => .{ .code = "58030", .message = "the UNIQUE constraint check could not read the store; the statement was not applied" },
        // CANARY: REQ=REQ-SONNY-6281-EXISTENCE-CONSTRAINTS; FEATURE="ConstraintEnforcement"; ASPECT=NotNullViolationCode; STATUS=TESTED; TEST=tests/test_sonny6281_existence_constraints.zig; OWNER=engine; UPDATED=2026-11-12
        // SONNY-6281: a statement that would leave a node without a property
        // a NOT NULL / EXISTS / NODE KEY constraint requires, or a CREATE
        // CONSTRAINT over nodes that lack it. 23502 is SQL's
        // not_null_violation. The message names the constraint, never a value.
        error.NotNullConstraintViolation => .{ .code = "23502", .message = unique_constraints.notNullMessage() },
        // SONNY-6281: CREATE UNIQUE INDEX built a plain index and ignored
        // UNIQUE; it is refused, and uniqueness is a constraint.
        error.UniqueIndexNotSupported => .{ .code = "0A000", .message = "CREATE UNIQUE INDEX is not supported: declare uniqueness with CREATE CONSTRAINT <name> FOR (n:Label) REQUIRE n.prop IS UNIQUE (enforced), or create a plain index with CREATE INDEX" },
        // SONNY-2846: a bulk fast-path write that reached a graph a UNIQUE
        // constraint was just created in; a retry runs through the executor,
        // which checks it.
        error.UniqueConstraintFastPathConflict => .{ .code = "40001", .message = "UniqueConstraintFastPathConflict: a constraint (UNIQUE, NODE KEY, NOT NULL or EXISTS) now applies in this graph; the write was not applied, retry it" },
        // GAP-0923: ABAC policy DDL validation (duplicate name rejected).
        error.PolicyAlreadyExists => .{ .code = "42710", .message = "Duplicate policy name" },
        error.IncompatibleIndexDataType => .{ .code = "42804", .message = "Incompatible index data type" },
        // GAP-0922: fulltext index requires a text (string) property.
        error.FulltextRequiresTextProperty => .{ .code = "42804", .message = "Fulltext index requires a text (string) property; the indexed property holds only non-string values" },
        // GAP-0918: vector index validation.
        error.InvalidIndexMetric => .{ .code = "42704", .message = "Unknown vector distance metric (supported: l2, euclidean, cosine, dot_product, inner_product)" },
        // Spec geode-vectorization-and-reranking: knn()'s query metric did not
        // match the metric the target HNSW index was built with. 42704 =
        // undefined_object, the same class the unknown-metric refusal above
        // uses.
        // CANARY: REQ=REQ-VECTOR-KNN-METRIC-VALIDATE-001; FEATURE="VectorIndex"; ASPECT=QueryMetricMatchesIndex; STATUS=TESTED; TEST=tests/test_knn_metric_mismatch.zig; OWNER=index; UPDATED=2026-08-28
        error.VectorMetricMismatch => .{ .code = "42704", .message = "knn metric does not match the vector index metric; query with the index's metric or recreate the index" },
        // ENG-3906: a WITH parameter a vector index does not implement used to be
        // silently discarded — a correctness lie about the index that was built.
        // 42704 = undefined_object, the same family the unknown-metric refusal
        // uses. (The QUIC/gRPC front ends surface parse-stage failures as 42000;
        // this arm covers in-process callers that map the error directly.)
        // CANARY: REQ=REQ-ENG-3906-INDEX-WITH-PARAM-VALIDATION; FEATURE="VectorIndex"; ASPECT=WithParameterValidation; STATUS=TESTED; TEST=tests/test_eng3906_index_with_params.zig; OWNER=index; UPDATED=2026-08-24
        error.UnknownIndexParameter => .{ .code = "42704", .message = "Unknown index parameter in the WITH clause: a vector index accepts only 'metric'; the HNSW tuning knobs m / ef_construction / ef_search are not implemented" },
        // UNSUPPORTED-AGGREGATES: an aggregate this engine recognises but does not implement
        // (percentile_cont, percentile_disc, stddev_samp, stddev_pop,
        // collect_list, stdev) used to parse and then evaluate to a silent NULL
        // inside GROUP BY. 42000 = syntax_error_or_access_rule_violation, the
        // syntax-class the front ends already use for parse-stage refusals.
        // CANARY: REQ=REQ-UNSUPPORTED-AGGREGATE-REJECTION; FEATURE="AggregateSetQuantifier"; ASPECT=SqlstateMapping; STATUS=TESTED; TEST=tests/test_unsupported_aggregates.zig; OWNER=parser; UPDATED=2026-08-25
        error.UnsupportedAggregateFunction => .{ .code = "42000", .message = "Unsupported aggregate function: this engine implements count, sum, avg, min, max and collect" },
        // RLS-POLICY-DDL: a CREATE/ALTER POLICY whose USING expression the policy
        // predicate compiler cannot compile used to be ACCEPTED and stored with
        // compiled=null, which decide() then treats as fail-closed — the policy
        // silently denied everything it was written to allow.
        // CANARY: REQ=REQ-RLS-POLICY-COMPILE-ERROR-AT-DDL; FEATURE="GPS Policy DDL"; ASPECT=SqlstateMapping; STATUS=TESTED; TEST=tests/test_rls_policy_ddl.zig; OWNER=security; UPDATED=2026-08-25
        error.UnsupportedPolicyExpression => .{ .code = "42000", .message = "Unsupported policy USING expression: the policy predicate compiler accepts only true, current_user()/current_tenant()/current_graph()/resource.label/principal.attributes.<key> compared with = to a quoted literal, combined with AND / OR / parentheses" },
        // FTS-INDEX-OPTIONS: an OPTIONS { … } key on CREATE INDEX used to be parsed and
        // thrown away, so a user who tuned a fulltext index believed a setting
        // took effect that never existed. Same 42704 family as ENG-3906.
        // CANARY: REQ=REQ-FTS-INDEX-OPTIONS-VALIDATION; FEATURE="FulltextIndex"; ASPECT=SqlstateMapping; STATUS=TESTED; TEST=tests/test_fts_index_options.zig; OWNER=index; UPDATED=2026-08-25
        error.UnknownIndexOption => .{ .code = "42704", .message = "Unknown index OPTIONS key: CREATE INDEX implements no OPTIONS keys; the BM25 knobs k1 / b and the analyzer are fixed by the fts-storage engine and are not tunable per index" },
        // ENG-3922(a): the pin belongs to the (graph, label, property), not to
        // an index — an unindexed property enforces homogeneity too — so the
        // message no longer says "indexed".
        error.VectorDimensionMismatch => .{ .code = "22000", .message = "Vector dimension does not match the property's established dimension" },
        // ENG-3910: the right-hand side of IN / NOT IN was neither a LIST nor
        // NULL. It used to fail OPEN (`NOT x IN $scalar` matched every row);
        // it is now refused as a data exception (class 22) so a mis-bound
        // parameter can never silently widen a predicate.
        // CANARY: REQ=REQ-ENG-3910-IN-PREDICATE-TYPE-SAFETY; FEATURE="InOperator"; ASPECT=NonListRightHandSide; STATUS=TESTED; TEST=tests/test_eng3910_in_type_safety.zig; OWNER=eval; UPDATED=2026-08-24
        error.ValuesNotComparable => .{ .code = "22G04", .message = "values not comparable: an ordering comparison of a year-to-month duration and a day-to-second duration (1 month is not a number of days)" },
        error.InListRequiresList => .{ .code = "22000", .message = "The right-hand side of IN / NOT IN must be a list (or NULL); a scalar value is not a list. Bind a list parameter, e.g. --param p '[1,2,3]'" },
        error.InvalidTypeConversion => .{ .code = "22003", .message = "Invalid type conversion" },
        // GAP-0905/GAP-0907: checked numeric narrowing (CAST, MakeInterval, ...)
        // surfaces as SQLSTATE 22003 numeric_value_out_of_range.
        error.IntegerOverflow => .{ .code = "22003", .message = "Integer value out of range" },
        // geode#873-B: the checked float -> DECIMAL coefficient conversion in the
        // vector scalar functions (vector_dot / vector_l2 / distance / euclidean /
        // manhattan / similarity). It used to be a bare `@intFromFloat` that
        // PANICKED the server on an out-of-range magnitude; it is now a refusal,
        // and a refusal in the same numeric_value_out_of_range class as the
        // integer narrowing above.
        // CANARY: REQ=REQ-GEODE-873-VECTOR-DECIMAL-OVERFLOW; FEATURE="VectorSimilarityFunctions"; ASPECT=CheckedFloatToDecimal; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=eval; UPDATED=2026-08-29
        error.DecimalOverflow => .{ .code = "22003", .message = "Numeric value out of range for DECIMAL" },
        // GAP-0921: CAST semantic validation.
        error.InvalidCast => .{ .code = "22018", .message = "Invalid character value for cast" },
        error.UnsupportedCastTarget => .{ .code = "0A000", .message = "Unsupported CAST target type" },
        // GAP-0926: out-of-range positional parameter.
        // SONNY-3247: a parameter the request does not supply, named or
        // positional (GAP-0926), refused before anything runs. 42P02 =
        // undefined_parameter (class 42, syntax error or access rule
        // violation).
        // SONNY-3367: a pattern names one variable as two kinds of element
        // (a relationship reused as a node pattern bound every node of the
        // graph). A syntax error, refused before anything runs.
        // SONNY-3245: ISO/IEC 39075:2024 16.5 <insert graph pattern>.
        error.InvalidInsertPattern => .{ .code = "42000", .message = "Invalid CREATE / INSERT pattern: a variable a MATCH bound, or one declared earlier in the pattern, takes no label or property (use SET), and an inserted relationship points left or right and has one type (ISO/IEC 39075 16.5)" },
        error.VariableKindConflict => .{ .code = "42000", .message = "Variable kind conflict: a pattern names one variable as two kinds of element (a node, a relationship, a variable-length relationship list or a path), or names a variable that holds a value (a WITH expression's alias, a FOR variable); name each element with a variable of its own" },
        // SONNY-3248 (round 4b-1 review m-2): a SKIP or LIMIT parameter that
        // is no non-negative integer read as "no window" (every row).
        error.InvalidWindowParameter => .{ .code = "22G03", .message = "Invalid SKIP or LIMIT value: a SKIP or LIMIT parameter must be a non-negative integer" },
        error.MissingParameter => .{ .code = "42P02", .message = "Undefined parameter: the statement references a parameter ($name or $n) that the request does not supply" },
        // GAP-0926: nested aggregate (sum(avg(...))) is invalid.
        error.NestedAggregate => .{ .code = "42803", .message = "Aggregate functions cannot be nested" },
        // SONNY-2675: a HAVING over groups reads each group's keys, projected
        // columns and aggregates; any other input column has no single value
        // for the group. The same grouping_error class as a nested aggregate.
        // CANARY: REQ=REQ-SONNY-2675-GROUPED-HAVING; FEATURE="GroupedHaving"; ASPECT=SqlstateMapping; STATUS=TESTED; TEST=tests/test_sonny2675_grouped_having.zig; OWNER=engine; UPDATED=2026-09-25
        error.UngroupedHavingReference => .{ .code = "42803", .message = "Grouping error: a HAVING (or a WHERE after an aggregating RETURN) may reference only grouping keys, projected columns and aggregates" },
        error.AggregateInRowFilter => .{ .code = "42803", .message = "Aggregate functions are not allowed in a WHERE after a RETURN that does not aggregate" },
        error.UnsupportedGroupedHavingPredicate => .{ .code = "0A000", .message = "A pattern or subquery predicate is not supported in a grouped HAVING or beside an aggregate in a RETURN or WITH item" },
        // SONNY-2675: a HAVING (or WHERE after RETURN) name that is no column,
        // binding or parameter; it used to evaluate to NULL (GAP-0926).
        error.UnknownHavingReference => .{ .code = "42703", .message = "A HAVING (or a WHERE after RETURN) names something that is no column, binding or parameter" },
        // SONNY-2696: a NEXT-chained part computes only an aggregate call and
        // arithmetic over aggregates; it answered any other expression over an
        // aggregate as NULL or as one row's value.
        error.UnsupportedAggregateExpression => .{ .code = "0A000", .message = "An aggregate inside a function call, list, map, CASE or unary operator is not supported in a NEXT-chained statement part; compute the aggregate in a WITH (WITH count(*) AS c) and use its alias" },
        // SONNY-2683: the executors of these shapes ignored a GROUP BY, HAVING
        // or WHERE after RETURN; refuse it rather than return other rows.
        // CANARY: REQ=REQ-SONNY-2683-RETURN-SHAPES; FEATURE="LegacyReturnProjection"; ASPECT=SqlstateMapping; STATUS=TESTED; TEST=tests/test_sonny2683_return_shapes.zig; OWNER=engine; UPDATED=2026-09-25
        error.UnsupportedGroupedReturn => .{ .code = "0A000", .message = "GROUP BY, HAVING and a WHERE after RETURN are not supported on a RETURN after CREATE, MERGE, DELETE or a procedure CALL" },
        // SONNY-2694: a statement that deletes returns its RETURN after the
        // DELETE frees what it deleted.
        // SONNY-2707: `SET r.x` on a variable-length relationship (a list of
        // edges) or on a path variable.
        // SONNY-3248 (round-4a review M-2): one SET clause assigned one
        // property of an element twice; the second silently won.
        // SONNY-6368: 22G0M, data exception - multiple assignments to a
        // graph element property (ISO/IEC 39075:2024 13.3 General Rule 7 a).
        // It answered 22G03 (invalid value type).
        error.RepeatedSetTarget => .{ .code = "22G0M", .message = "A SET clause assigns one property of an element more than once (or `SET n = {map}` beside another assignment to n); its values are evaluated together, so there is no order to settle them. Split it into two SET clauses" },
        // SONNY-3046: a pattern naming a variable the incoming row binds where
        // the join cannot constrain it is refused, not answered by binding
        // the name again.
        error.UnsupportedBoundVariableJoin => .{ .code = "0A000", .message = "A variable bound before this MATCH (passed on by WITH or NEXT) is named in a part with an OPTIONAL MATCH, a shortest path, a variable-length relationship, or as a path where it is a node or relationship (or the reverse); joining it there is not supported. Match the pattern with a new variable and compare it in a WHERE" },
        error.UnsupportedOptionalMatchShape => .{ .code = "0A000", .message = "A path variable or an inline LET in a query part with an OPTIONAL MATCH is not supported; return the pattern's nodes and relationships, and compute the value in a WITH after it" },
        error.OptionalPathVariable => .{ .code = "0A000", .message = "A path variable on an OPTIONAL MATCH pattern after the first is not supported; return the pattern's nodes and relationships instead" },
        error.VariableLengthPathWrite => .{ .code = "0A000", .message = "A SET or REMOVE cannot target a variable-length relationship variable (the list of its edges) or a path variable; target the path's nodes" },
        // SONNY-3384: a SET or REMOVE before a DELETE in one query runs only
        // on a variable the DELETE deletes, which the RETURN does not read.
        error.UnsupportedSetBeforeDelete => .{ .code = "0A000", .message = "A SET or REMOVE before a DELETE in one statement is supported only on a variable the statement deletes, and not read by its RETURN or ORDER BY; run the SET as a statement of its own" },
        error.DeleteReturnsDeletedElement => .{ .code = "0A000", .message = "A RETURN after DELETE cannot return an element the statement deletes (a node, an edge or a path through one), or a JSONB, XML, URL, DOMAIN, bit string or extended value; return its properties or an aggregate" },
        // SONNY-3040, SONNY-3041, SONNY-3043: a write clause the statement's
        // shape does not apply is refused, before anything is written, rather
        // than dropped.
        error.WriteClauseNotApplied => .{ .code = "0A000", .message = "This statement writes in a shape that is not supported: a statement that writes is accepted only in the allowlisted shapes (CREATE/INSERT; MERGE; MATCH ... [WHERE] SET/REMOVE/DELETE/CREATE/MERGE; MATCH ... WITH ... SET/REMOVE/DELETE, or one CREATE or MERGE; each after an optional WITH of values or an UNWIND, in a FOR body, under PROFILE, or in a UNION of MATCH ... SET parts), with every variable bound, and no write inside an expression. Split the statement" },
        error.TooManyWriteClauses => .{ .code = "54000", .message = "A query part may carry at most 1024 SET, REMOVE, CREATE and MERGE clauses" },
        // SONNY-3244: the parser's limits (gql/parser.zig `max_*`).
        error.TooManyStatements => .{ .code = "54000", .message = "A request may carry at most 1024 statements" },
        error.ParseMemoryLimit => .{ .code = "54000", .message = "Parsing the request needs more than 64 MiB" },
        // SONNY-6433: ISO/IEC 39075 Feature GH02 (the parser's own message is the same).
        error.UndirectedEdgeNotSupported => .{ .code = "0A000", .message = "undirected edges are not supported: Geode stores directed edges only, so an undirected edge pattern (~[ ]~, ~, <~[ ]~, ~[ ]~>; ISO/IEC 39075 Feature GH02) can be neither matched nor inserted. Use -[ ]-> or <-[ ]- (or -[ ]- to match either direction)" },
        // SONNY-6343: the parser's message (which names the shape) is the
        // detail where the parse outcome carries it.
        error.UnsupportedQueryShape => .{ .code = "0A000", .message = "This query shape is not supported: a NEXT after a statement with no RETURN or after a UNION, INTERSECT, EXCEPT or OTHERWISE, or an inline CALL other than a statement-level CALL { } followed by WITH, WHERE or RETURN" },
        error.QueryNestingTooDeep => .{ .code = "54001", .message = "Queries may nest at most 10 deep (WITH chain parts, CALL { }, IN (subquery), FOR bodies, CTE bodies)" },
        error.StringDataRightTruncation => .{ .code = "22001", .message = "String data right truncation" },
        error.InvalidKeyProvider => .{ .code = "42704", .message = "Invalid TDE key provider" },
        error.InvalidGuardrailConfiguration => .{ .code = "42704", .message = "Invalid CDC guardrail configuration" },
        // CANARY: REQ=REQ-SONNY-6331-ONE-PASSWORD-POLICY; FEATURE="Unified Password Policy Validation"; ASPECT=SqlstateMapping; STATUS=TESTED; TEST=tests/test_sonny6331_password_policy_paths.zig; OWNER=security; UPDATED=2026-11-12
        // SONNY-6331: a password the policy refuses (CREATE USER, ALTER USER
        // SET PASSWORD, geode.auth.user_create / user_reset_password /
        // user_change_password), with the rule it broke and the configured
        // limit; never the password. It named an older 8-character rule.
        error.PasswordTooShort,
        error.PasswordTooLong,
        error.PasswordMissingUppercase,
        error.PasswordMissingLowercase,
        error.PasswordMissingDigit,
        error.PasswordContainsSpaces,
        error.PasswordNotPassphrase,
        => blk: {
            const PasswordPolicy = @import("geode_auth").PasswordPolicy;
            break :blk .{ .code = "22000", .message = PasswordPolicy.geodeSecure().message(PasswordPolicy.violationOf(err).?) };
        },
        error.PasswordReuse => .{ .code = "22000", .message = "New password must not match the current password" },
        error.UnknownProcedure => .{ .code = "42883", .message = "Unknown procedure" },
        // docs/@BUGS_731.md bug 8b: an unresolved scalar function used to
        // silently evaluate to NULL; surface it with the same
        // undefined_function SQLSTATE the procedure path uses.
        error.UnknownFunction => .{ .code = "42883", .message = "Unknown function" },
        // geode#877 (c): knn()/vector_knn() named a property no row supplies.
        // Previously an empty list with SQLSTATE 00000 — indistinguishable from
        // "no neighbours". Same diagnostic posture as UnknownFunction above.
        // CANARY: REQ=REQ-GEODE-877-KNN-UNKNOWN-PROPERTY; FEATURE="VectorKnn"; ASPECT=UnknownPropertyDiagnostic; STATUS=TESTED; TEST=tests/test_vector_knn_silent_failures.zig; OWNER=eval; UPDATED=2026-08-29
        error.UnknownProperty => .{ .code = "42703", .message = "Unknown property: no row in scope supplies this property" },
        // docs/@BUGS_731.md bug 8d: a wrong-arity / wrong-value function call
        // (e.g. the docs' `knn(d.embedding, $q, 10)`, which is missing the
        // metric and passes a vector where a property NAME belongs) reached the
        // generic 58000 "internal error" fallback. It is a caller error:
        // 22023 = invalid_parameter_value.
        error.InvalidArgs => .{ .code = "22023", .message = "Invalid arguments for function (wrong number of arguments, or an argument value the function does not accept)" },
        error.Unauthenticated => .{ .code = "28000", .message = "Authentication required" },
        error.Unauthorized => .{ .code = "42501", .message = "Permission denied" },
        // GAP-0840: strict-tenancy rejected a tenant-scoped operation with no
        // concrete tenant scope (unset/empty/"default"). Surface as a
        // permission-denied class error rather than the generic internal fallback.
        error.TenantScopeRequired => .{ .code = "42501", .message = "Tenant scope required: strict tenancy is enabled and this session has no concrete tenant scope" },
        // SONNY-2733: geode.tenant.backfill_edge_tags refusals.
        error.TenantScopedSession => .{ .code = "42501", .message = "geode.tenant.backfill_edge_tags changes every tenant's edges; run it in a session with no tenant scope" },
        error.GraphLockHeld => .{ .code = "0A000", .message = "geode.tenant.backfill_edge_tags takes each graph's lock itself; send it as the only statement in its request" },
        error.BackfillInTransaction => .{ .code = "25000", .message = "geode.tenant.backfill_edge_tags cannot run inside a transaction: ROLLBACK would not undo its re-tags (a dry run can)" },
        error.BackfillProjection => .{ .code = "0A000", .message = "geode.tenant.backfill_edge_tags takes no RETURN or ORDER BY: it runs with no statement lock, and they would read the store; YIELD its columns instead" },
        // SONNY-2686: a MERGE whose pattern only nodes the session's row-level
        // security hides match is refused (nothing bound, updated or created)
        // rather than binding the hidden node or creating a duplicate of it.
        // CANARY: REQ=REQ-SONNY-2686-MERGE-ROW-VISIBILITY; FEATURE="MergeRowVisibility"; ASPECT=SqlstateMapping; STATUS=TESTED; TEST=tests/test_sonny2686_merge_rls.zig; OWNER=security; UPDATED=2026-09-25
        error.MergeMatchNotVisible => .{ .code = "42501", .message = "MergeMatchNotVisible: the MERGE pattern matches an existing node that row-level security hides from this session; the statement was refused, and nothing was bound, updated or created" },
        // SONNY-2817: the per-session, per-label limit on those refusals.
        error.MergeRefusalRateLimited => .{ .code = "53400", .message = "MergeRefusalRateLimited: this session was refused too many MERGEs for rows row-level security hides on a label of this graph; every MERGE naming that label is refused for 5 minutes, and nothing was bound, updated or created" },
        // SONNY-2691 item 5: the evaluator's row visibility was never
        // installed in this process; the statement is refused rather than
        // answered without the session's RLS policies.
        error.EvaluatorNotInitialized => .{ .code = "XX000", .message = "EvaluatorNotInitialized: the query evaluator's execution layer and row-level security are not initialized in this process; the statement was refused" },
        error.SearchNotPermitted => .{ .code = "42501", .message = "Access denied: READ_PLAINTEXT privilege required for encrypted searchable field" },
        error.InvalidIpAddress => .{ .code = "22P02", .message = "Invalid IP address format" },
        error.InvalidMac, error.InvalidMacFormat, error.InvalidMacTag => .{ .code = "22P02", .message = "Invalid MAC address format" },
        error.DivisionByZero => .{ .code = "22012", .message = "Division by zero" },
        // SONNY-6291: the geode.auth.apikey_* procedures (no server-side
        // API-key store).
        // SONNY-6292: GRANT ROLE / ALTER USER SET ROLE / user_assign_role
        // of a custom role (it answered "assigned" and conferred nothing).
        error.CustomRoleMembershipNotSupported => .{ .code = "0A000", .message = "A custom role cannot be granted to a user: custom roles carry no privileges, so the grant would confer nothing. Grant a built-in role (admin, readwrite, user, readonly) or per-graph privileges (GRANT READ | WRITE | SCHEMA | ALL ON GRAPH <g> TO <user>)" },
        // SONNY-6369: ALTER USER SET ROLE / user_assign_role of a role other
        // than admin to a superuser (it answered "assigned" and changed nothing).
        error.SuperuserRoleFixed => .{ .code = "0A000", .message = "The user is a superuser: a superuser always holds the admin role, so another role would never take effect; nothing was changed" },
        error.ApiKeysNotSupported => .{ .code = "0A000", .message = "API keys are not supported by the server: the geode.auth.apikey_* procedures create, list, check and revoke nothing, and the handshake does not authenticate by key" },
        // SONNY-6291: user_show / user_permissions (SHOW PERMISSIONS FOR) of
        // a user that does not exist, for an Admin.
        error.UserNotFound => .{ .code = "42704", .message = "User does not exist" },
        // SONNY-6369: user_remove_attribute of an attribute the user does not
        // have (it answered 00000 "attribute ... not set").
        error.UserAttributeNotSet => .{ .code = "42704", .message = "The user has no such attribute; nothing was removed" },
        // SONNY-6359: auth procedure failures that answered 00000 with a
        // status row starting "error:" or "note:".
        error.UserAlreadyExists => .{ .code = "42710", .message = "User already exists" },
        error.ReservedUsername => .{ .code = "42939", .message = "Reserved user name: geode-cluster is the federation node identity and cannot be a user" },
        error.UnknownPrivilege => .{ .code = "22023", .message = "Unknown privilege: expected READ, WRITE, SCHEMA or ALL" },
        // SONNY-6367: geode.auth.mfa_verify / mfa_enable / user_import
        // refusals that answered 00000 with a status row.
        error.InvalidMfaCode => .{ .code = "28000", .message = "invalid token: the MFA code does not verify against the user's TOTP secret" },
        error.MfaNotEnrolled => .{ .code = "55000", .message = "mfa_not_enrolled: the user has no TOTP secret; run geode.auth.mfa_setup first" },
        error.MfaRateLimited => .{ .code = "53400", .message = "Too many failed MFA verifications for the user: locked out for 5 minutes" },
        error.FeatureDisabled => .{ .code = "0A000", .message = "Feature disabled on this server: the operation needs a feature that is turned off (MFA: start the server with GEODE_ENABLE_MFA=1)" },
        error.FipsUnsupported => .{ .code = "0A000", .message = "Not available under FIPS mode: the operation needs a primitive that is not FIPS-approved (Argon2id, BLAKE2b)" },
        // SONNY-3135 (N7d): geode.auth.grant(..., '*') (it stored a grant on a
        // graph named '*', which no request matches).
        error.GrantWildcardNotSupported => .{ .code = "0A000", .message = "A per-graph grant needs one graph: there is no grant on every graph ('*'). Give the user a built-in role, or create an allow policy for every graph (CREATE POLICY ... ON GRAPH *); nothing was changed" },
        error.GlobalPrivilegeNotSupported => .{ .code = "0A000", .message = "GRANT / REVOKE of a privilege needs ON GRAPH <graph>: there are no global per-privilege grants (global privilege is the user's role: admin, readwrite, user, readonly); nothing was changed" },
        error.NotImplemented, error.Unsupported => .{ .code = "0A000", .message = @errorName(err) },
        // GAP-0856: distributed EXPLAIN/PROFILE is intentionally node-local only.
        error.DistributedExplainUnsupported => .{ .code = "0A000", .message = @import("../distributed/distributed_explain.zig").unsupported_message },
        // GAP-0871: GQL BACKUP/RESTORE statements are intentionally unsupported;
        // the engine-backed CLI (`geode backup create` / `geode restore`) is the
        // supported surface. Stable message names the CLI alternative.
        error.GqlBackupRestoreUnsupported => .{ .code = "0A000", .message = execution.gql_backup_restore_unsupported_message },
        // RC-2 ("committed write -> client Timeout -> retry double-insert",
        // 2026-06-12): a clustered write's outcome must NOT be conflated into the
        // generic 58000 system-error class. Three distinct outcomes, each
        // separately recognizable by a client, so a committed-but-unknown write is
        // never retried blindly (which is what minted the duplicate row):
        //
        //   * error.Timeout -> CONNECTION-EXCEPTION class (08). The write MIGHT
        //     have committed but this node could not confirm its local-apply
        //     outcome within budget. The outcome is UNKNOWN: a client may retry
        //     ONLY with an idempotency key (RC-3). 08006 = connection_failure;
        //     the message states the outcome is unknown. Distinct from the
        //     not-applied class (40) below, so the client can tell "retry only
        //     with idempotency" from "retry freely against the leader".
        //   * error.ClusterNotLeader / error.ClusterWriteNotReplicable ->
        //     TRANSACTION-ROLLBACK class (40). The write definitively did NOT
        //     apply here (this node is a follower, or the leader could not
        //     replicate the write shape). Nothing mutated; safe to retry against
        //     the leader. 40001 = serialization_failure, the canonical
        //     "rolled back, safe to retry" code; both errors SHARE class 40 so a
        //     client treats them identically.
        // CANARY: REQ=REQ-DIST-CLUSTER-WRITE-OUTCOME-SQLSTATE; FEATURE="DistributedCluster"; ASPECT=ClusterErrorSqlstateMapping; STATUS=TESTED; TEST=tests/test_proto_util_cluster_error_mapping.zig; OWNER=transport; UPDATED=2026-06-12
        // The error NAME is retained in each message (a stable, wire-discoverable
        // token) so clients and regression suites that key on `ClusterNotLeader` /
        // `ClusterWriteNotReplicable` / `Timeout` continue to recognize the
        // outcome — RC-2 only requires distinct, non-58000 codes and a non-empty
        // message, not the removal of the name.
        error.Timeout => .{ .code = "08006", .message = "Timeout: cluster write outcome unknown — the entry may have committed but local apply could not be confirmed in time; retry ONLY with an idempotency key" },
        error.ClusterNotLeader => .{ .code = "40001", .message = "ClusterNotLeader: cluster write not applied here — this node is not the leader; retry against the current leader" },
        error.ClusterWriteNotReplicable => .{ .code = "40001", .message = "ClusterWriteNotReplicable: cluster write not applied here — the leader could not replicate this write shape; retry against the current leader" },
        // SONNY-3348 (round 19): the leader could not propose a statement's
        // entry (nothing was proposed; nothing applied).
        error.ClusterProposeFailed => .{ .code = "40001", .message = "ClusterProposeFailed: cluster write not applied — the leader could not propose the statement's entry; retry against the current leader" },
        // GAP (write-path OOM, 2026-07-04): the legacy write-carrying MATCH
        // executor aborted because its materialization working set crossed the
        // configured budget — a loud, clean refusal instead of the OOM killer.
        // 53200 = SQLSTATE out_of_memory (class 53, insufficient resources).
        error.WriteQueryBudgetExceeded => .{ .code = "53200", .message = "WriteQueryBudgetExceeded: this write query's working set exceeded GEODE_WRITE_EXECUTOR_BUDGET_MB (default 8192; 0 disables) and was aborted before exhausting server memory. The statement's changes were undone (its undo record counts against the same budget). Narrow the MATCH (single-node indexed-equality point writes run engine-direct) or raise the budget" },
        // GAP-ENT-0044 (T5, 2026-07-05 live OOM): the read executor's
        // materialization working set crossed the configured budget — a loud,
        // clean refusal instead of the OOM killer taking the server.
        // 53200 = SQLSTATE out_of_memory (class 53, insufficient resources).
        error.ReadQueryBudgetExceeded => .{ .code = "53200", .message = "ReadQueryBudgetExceeded: this read query's working set exceeded GEODE_READ_EXECUTOR_BUDGET_MB (default 8192; 0 disables) and was aborted before exhausting server memory. No data was modified. Narrow the query (indexed GROUP BY/DISTINCT/count shapes are served O(distinct) from the index), add a LIMIT, or raise the budget" },
        // GAP-ENT-0045 (T5): the client's connection closed / timed out (or the
        // stall watchdog aborted a wedged handler) while the read was running;
        // the executor stopped at the next row/batch boundary instead of
        // burning CPU+RSS for an abandoned result.
        // 57014 = SQLSTATE query_canceled (class 57, operator intervention).
        error.ReadQueryCancelled => .{ .code = "57014", .message = "ReadQueryCancelled: the client disconnected or the server canceled this read (stall watchdog); execution aborted at a row/batch boundary. No data was modified" },
        // SONNY-1841: a per-stream QUIC CANCEL (or connection close / stall
        // watchdog) reached the write executor; the write-carrying mutation
        // aborted at a candidate/apply boundary and RELEASED the per-graph write
        // lock instead of holding it to the ~120 s deadline. SONNY-3348: the
        // statement's changes are undone (its undo record), as at the budget
        // abort.
        // 57014 = SQLSTATE query_canceled (class 57, operator intervention).
        error.WriteQueryCancelled => .{ .code = "57014", .message = "WriteQueryCancelled: the client canceled this write (per-stream CANCEL, disconnect, or stall watchdog); execution aborted at a row-mutation boundary and released the per-graph write lock. The statement's changes were undone" },
        // ENG-3911: an oversized property VALUE used to reach the client as
        // `PropertyKeyTooLong` under the generic 58000 system-error class — the
        // wrong noun AND a "the server broke" class for a documented resource
        // limit the caller simply crossed. Each refusal now gets its own
        // truthful arm here.
        // 54000 = SQLSTATE program_limit_exceeded (class 54, limit exceeded).
        // NOTE: since graph-storage v0.4.0 a value that overflows the ~8142-byte
        // inline per-entry budget SPILLS to a VarStore overflow chain instead of
        // failing, so this arm now fires only above the storage sanity cap
        // `GraphConfig.max_property_value_bytes` (default 1 MiB) — and the
        // storage layer raises `PropertyValueTooLarge` itself.
        // CANARY: REQ=REQ-ENG-3911-PROPERTY-VALUE-SIZE-ERROR; FEATURE="PropertyStorage"; ASPECT=OversizedValueErrorMapping; STATUS=TESTED; TEST=tests/test_eng3911_property_value_size_error.zig; OWNER=transport; UPDATED=2026-08-25
        error.PropertyValueTooLarge => .{ .code = "54000", .message = "PropertyValueTooLarge: the encoded property value exceeds the storage sanity cap on a single value (GraphConfig.max_property_value_bytes, default 1048576 bytes / 1 MiB). Values below the cap are stored in full — larger-than-page values spill to an overflow chain — so a VECTOR<f32> fits up to 262144 dimensions and a string up to ~1 MiB. Shorten the value or raise the cap deliberately" },
        error.PropertyKeyTooLong => .{ .code = "54000", .message = "PropertyKeyTooLong: the property key exceeds the 65535-byte maximum key length" },
        // ENG-3922(b): an over-cap vector literal used to be laundered
        // (VectorTooLarge -> InvalidFormat -> TypeMismatch) and land in the
        // `else` arm below as 58000 "internal system error" — a server fault
        // class for a documented resource limit the caller simply crossed. Same
        // wrong-class bug, and the same fix shape, as the ENG-3911 arms above.
        // 54000 = SQLSTATE program_limit_exceeded (class 54, limit exceeded).
        // CANARY: REQ=REQ-ENG-3922-VECTOR-DIM-GUARD; FEATURE="VectorF32"; ASPECT=OverCapErrorMapping; STATUS=TESTED; TEST=tests/test_eng3922_dim_guard.zig; OWNER=transport; UPDATED=2026-08-29
        error.VectorTooLarge => .{ .code = "54000", .message = "VectorTooLarge: the vector dimension exceeds the maximum of 65535 elements (VectorF32.dim / VectorI32.dim are u16). Reduce the embedding dimension" },
        // SONNY-3181: an expression nested deeper than the evaluating thread's
        // stack holds (lists, calls or CASE inside one another; operator and
        // member chains are evaluated with loops). 54001 = SQLSTATE
        // statement_too_complex (class 54, program limit exceeded).
        error.ExpressionTooDeep => .{ .code = "54001", .message = "ExpressionTooDeep: the expression nests too deeply to evaluate on this server thread's stack; flatten it" },
        // REQ-GQL-028: the graph's first-touch hydration failed and it is
        // quarantined; reads and writes of it fail closed until the server
        // reopens it. A storage corruption error from the build is reported
        // as itself (58000 ChecksumMismatch / DataCorruption / InvalidData).
        error.GraphQuarantined => .{ .code = "58000", .message = "GraphQuarantined: the graph's indexes could not be loaded from storage, so it is quarantined and refuses reads and writes; see the server log, then restart the server to retry" },
        else => .{ .code = "58000", .message = @errorName(err) },
    };
}

pub fn buildStatus(allocator: std.mem.Allocator, status_class: []const u8, flagger_findings: []const []const u8) !schema.Status {
    return buildStatusFull(allocator, status_class, &.{}, flagger_findings);
}

pub fn buildStatusFull(
    allocator: std.mem.Allocator,
    status_class: []const u8,
    additional_statuses: []const []const u8,
    flagger_findings: []const []const u8,
) !schema.Status {
    var flags = std.ArrayList([]const u8).initCapacity(allocator, flagger_findings.len) catch return error.OutOfMemory;
    for (flagger_findings) |flag| {
        try flags.append(allocator, try allocator.dupe(u8, flag));
    }

    var additional = std.ArrayList([]const u8).initCapacity(allocator, additional_statuses.len) catch return error.OutOfMemory;
    for (additional_statuses) |status| {
        try additional.append(allocator, try allocator.dupe(u8, status));
    }

    return .{
        .status_class = try allocator.dupe(u8, status_class),
        .status_subclass = "",
        .additional_statuses = additional,
        .flagger_findings = flags,
    };
}

pub fn buildSchemaDefinition(allocator: std.mem.Allocator, result: *const execution.ExecutionResult) !schema.SchemaDefinition {
    var cols = std.ArrayList(schema.ColumnDefinition).initCapacity(allocator, result.columns.len) catch return error.OutOfMemory;
    for (result.columns, 0..) |name, idx| {
        const type_name = inferColumnType(result.rows, idx);
        const col = schema.ColumnDefinition{
            .name = try allocator.dupe(u8, name),
            .type = try allocator.dupe(u8, type_name),
        };
        try cols.append(allocator, col);
    }
    return .{ .columns = cols };
}

pub fn buildDataPage(
    allocator: std.mem.Allocator,
    result: *const execution.ExecutionResult,
    start: usize,
    page_size: usize,
    ordered: bool,
    order_keys: []const []const u8,
) !schema.DataPage {
    const page_len = if (page_size == 0) 1000 else page_size;
    if (start >= result.rows.len) {
        return schema.DataPage{
            .rows = std.ArrayList(schema.Row).empty,
            .final = true,
            .ordered = ordered,
            .order_keys = try dupOrderKeys(allocator, order_keys),
        };
    }

    const end = @min(start + page_len, result.rows.len);
    return buildDataPageFromRows(allocator, result.rows[start..end], end == result.rows.len, ordered, order_keys);
}

pub fn buildDataPageFromRows(
    allocator: std.mem.Allocator,
    rows_slice: []const []const value_types.Value,
    final: bool,
    ordered: bool,
    order_keys: []const []const u8,
) !schema.DataPage {
    const row_count = rows_slice.len;

    var rows = std.ArrayList(schema.Row).initCapacity(allocator, row_count) catch return error.OutOfMemory;
    try rows.resize(allocator, row_count);

    // GAP-0257 fix: Use sequential serialization for all data page sizes.
    // The old parallel serialization path caused memory corruption on large
    // result sets (1000+ rows), producing "58000: Internal Server Error".
    // Sequential serialization is safe and fast enough — per-row protobuf
    // conversion is lightweight (mostly string duplication), and the cost of
    // creating/destroying a thread pool per data page exceeds any parallelism
    // benefit for typical workloads.
    for (rows_slice, 0..) |row_values, i| {
        var values = std.ArrayList(schema.Value).initCapacity(allocator, row_values.len) catch return error.OutOfMemory;
        for (row_values) |val| {
            const proto_val = try valueToProto(allocator, val);
            try values.append(allocator, proto_val);
        }
        rows.items[i] = .{ .values = values };
    }

    return schema.DataPage{
        .rows = rows,
        .final = final,
        .ordered = ordered,
        .order_keys = try dupOrderKeys(allocator, order_keys),
    };
}

fn dupOrderKeys(allocator: std.mem.Allocator, keys: []const []const u8) !std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).initCapacity(allocator, keys.len) catch return error.OutOfMemory;
    for (keys) |key| {
        try list.append(allocator, try allocator.dupe(u8, key));
    }
    return list;
}

/// Leading rows `inferColumnType` samples to type a column. SONNY-1221: the
/// node-scan fast path builds exactly this many rows before its schema frame
/// (`NodeScanStream.prefetchSchemaSample`), so both paths type a column from
/// the same rows.
pub const column_type_sample_rows: usize = 10;

fn inferColumnType(rows: [][]value_types.Value, col_idx: usize) []const u8 {
    const sample_size = @min(rows.len, column_type_sample_rows);
    for (rows[0..sample_size]) |row| {
        if (col_idx >= row.len) continue;
        const val = row[col_idx];
        if (val == .Null) continue;
        return type_helpers.getTypeName(val);
    }
    return "NULL";
}

pub fn valueToProto(allocator: std.mem.Allocator, value: value_types.Value) !schema.Value {
    return switch (value) {
        .Null => .{ .kind = .{ .null_val = .{} } },
        .Bool => |b| .{ .kind = .{ .bool_val = b } },
        .Int => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .INT } } },
        .SmallInt => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .SMALLINT } } },
        .BigInt => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .BIGINT } } },
        .Real => |f| .{ .kind = .{ .double_val = .{ .value = @floatCast(f), .kind = .REAL } } },
        .Double => |f| .{ .kind = .{ .double_val = .{ .value = f, .kind = .DOUBLE } } },
        .Str => |s| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, s), .kind = .STRING } } },
        .Char => |c| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, c.data), .kind = .CHAR } } },
        .Varchar => |v| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, v.data), .kind = .VARCHAR } } },
        .Text => |t| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, t), .kind = .TEXT } } },
        .Decimal => |d| blk: {
            const coeff_str = try std.fmt.allocPrint(allocator, "{d}", .{d.coeff});
            const orig_repr = if (d.orig_repr) |repr| try allocator.dupe(u8, repr) else if (d.scale > 0) try reconstructDecimalRepr(allocator, d.coeff, d.scale) else try allocator.dupe(u8, coeff_str);
            break :blk .{ .kind = .{ .decimal_val = .{
                .coeff = coeff_str,
                .scale = d.scale,
                .orig_scale = d.orig_scale,
                .orig_repr = orig_repr,
            } } };
        },
        .Bytea => |b| .{ .kind = .{ .bytes_val = .{ .value = try allocator.dupe(u8, b), .kind = .BYTEA } } },
        .List => |list| blk: {
            var values = std.ArrayList(schema.Value).initCapacity(allocator, list.len) catch return error.OutOfMemory;
            for (list) |item| {
                try values.append(allocator, try valueToProto(allocator, item));
            }
            break :blk .{ .kind = .{ .list_val = .{ .values = values } } };
        },
        .Map => |map| blk: {
            var entries = std.ArrayList(schema.MapEntry).initCapacity(allocator, map.count()) catch return error.OutOfMemory;
            var it = map.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try valueToProto(allocator, entry.value_ptr.*);
                try entries.append(allocator, .{ .key = key, .value = val });
            }
            break :blk .{ .kind = .{ .map_val = .{ .entries = entries } } };
        },
        .Node => |node| .{ .kind = .{ .node_val = try nodeToProto(allocator, node.*) } },
        .Edge => |edge| .{ .kind = .{ .edge_val = try edgeToProto(allocator, edge.*) } },
        .Path => |path| blk: {
            var nodes = std.ArrayList(schema.NodeValue).initCapacity(allocator, path.nodes.len) catch return error.OutOfMemory;
            for (path.nodes) |n| {
                try nodes.append(allocator, try nodeToProto(allocator, n.*));
            }
            var edges = std.ArrayList(schema.EdgeValue).initCapacity(allocator, path.edges.len) catch return error.OutOfMemory;
            for (path.edges) |e| {
                try edges.append(allocator, try edgeToProto(allocator, e.*));
            }
            break :blk .{ .kind = .{ .path_val = .{ .nodes = nodes, .edges = edges } } };
        },
        .ExtValue => |ext| .{ .kind = .{ .ext_val = try extValueToProto(allocator, ext) } },
        .Date => |d| .{ .kind = .{ .ext_val = try textExt(allocator, "DATE", try d.toString(allocator)) } },
        .Time => |t| .{ .kind = .{ .ext_val = try textExt(allocator, "TIME", try t.toString(allocator)) } },
        .TimeTZ => |t| .{ .kind = .{ .ext_val = try textExt(allocator, "TIMETZ", try t.toString(allocator)) } },
        .Timestamp => |t| .{ .kind = .{ .ext_val = try textExt(allocator, "TIMESTAMP", try t.toString(allocator)) } },
        .TimestampTZ => |t| .{ .kind = .{ .ext_val = try textExt(allocator, "TIMESTAMPTZ", try t.toString(allocator)) } },
        .Interval => |i| .{ .kind = .{ .ext_val = try textExt(allocator, "INTERVAL", try i.toString(allocator)) } },
        .Json => |j| .{ .kind = .{ .ext_val = try textExt(allocator, "JSON", try allocator.dupe(u8, j)) } },
        .Jsonb => |jb| .{ .kind = .{ .ext_val = try textExt(allocator, "JSONB", try allocator.dupe(u8, jb.data)) } },
        .Xml => |x| .{ .kind = .{ .ext_val = try textExt(allocator, "XML", try allocator.dupe(u8, x.data)) } },
        .Url => |u| .{ .kind = .{ .ext_val = try textExt(allocator, "URL", try u.toString(allocator)) } },
        .Domain => |d| .{ .kind = .{ .ext_val = try textExt(allocator, "DOMAIN", try d.toString(allocator)) } },
        .UUID => |u| .{ .kind = .{ .ext_val = try textExt(allocator, "UUID", try u.toStringAlloc(allocator)) } },
        .BitString => |b| .{ .kind = .{ .ext_val = try textExt(allocator, "BIT", try b.toString(allocator)) } },
        .VarBit => |b| .{ .kind = .{ .ext_val = try textExt(allocator, "VARBIT", try b.toString(allocator)) } },
        .IntRange => |r| .{ .kind = .{ .ext_val = try textExt(allocator, "INT4RANGE", try r.toString(allocator)) } },
        .Enum => |e| .{ .kind = .{ .ext_val = try textExt(allocator, "ENUM", try std.fmt.allocPrint(allocator, "{d}:{d}", .{ e.type_id, e.value_ordinal })) } },
    };
}

fn nodeToProto(allocator: std.mem.Allocator, node: graph_store.Node) !schema.NodeValue {
    var labels = std.ArrayList([]const u8).initCapacity(allocator, node.labels.len) catch return error.OutOfMemory;
    for (node.labels) |label| {
        try labels.append(allocator, try allocator.dupe(u8, label));
    }
    var props = std.ArrayList(schema.MapEntry).initCapacity(allocator, node.properties.count()) catch return error.OutOfMemory;
    var it = node.properties.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        // SONNY-6327: a string through the FLE read policy (RETURN n sent
        // the stored bytes: ciphertext, to every principal).
        const val = try entityPropertyToProto(allocator, .node, if (node.labels.len > 0) node.labels[0] else "Unknown", node.id, node.tenant_id, entry.key_ptr.*, entry.value_ptr.*);
        try props.append(allocator, .{ .key = key, .value = val });
    }
    return .{
        .id = node.id,
        .labels = labels,
        .properties = props,
    };
}

fn edgeToProto(allocator: std.mem.Allocator, edge: graph_store.Edge) !schema.EdgeValue {
    var props = std.ArrayList(schema.MapEntry).initCapacity(allocator, edge.properties.count()) catch return error.OutOfMemory;
    var it = edge.properties.iterator();
    while (it.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        const val = try entityPropertyToProto(allocator, .edge, edge.label, edge.id, edge.tenant_id, entry.key_ptr.*, entry.value_ptr.*);
        try props.append(allocator, .{ .key = key, .value = val });
    }
    return .{
        .id = edge.id,
        .from_id = edge.from_id,
        .to_id = edge.to_id,
        .label = try allocator.dupe(u8, edge.label),
        .properties = props,
    };
}

// CANARY: REQ=REQ-SONNY-6327-FLE-READ-POLICY; FEATURE="FieldLevelEncryption"; ASPECT=WireEncoding; STATUS=TESTED; TEST=tests/test_sonny6327_fle_read_gaps.zig; OWNER=security; UPDATED=2026-11-11
/// SONNY-6327: a property of a whole node, edge or path on the wire. A
/// string goes through the shared FLE read policy for a whole entity
/// (`fle_integration.readStoredStringForEntity`).
fn entityPropertyToProto(
    allocator: std.mem.Allocator,
    kind: fle_integration.EntityKind,
    type_name: []const u8,
    id: u64,
    record_tenant: []const u8,
    key: []const u8,
    value: graph_store.PropertyValue,
) !schema.Value {
    if (value == .String) {
        const shown = try fle_integration.readStoredStringForEntity(allocator, kind, type_name, key, value.String, id, record_tenant);
        return .{ .kind = .{ .string_val = .{ .value = shown, .kind = .STRING } } };
    }
    return propertyValueToProto(allocator, value);
}

fn propertyValueToProto(allocator: std.mem.Allocator, value: graph_store.PropertyValue) !schema.Value {
    return switch (value) {
        .Null => .{ .kind = .{ .null_val = .{} } },
        .Bool => |b| .{ .kind = .{ .bool_val = b } },
        .Int => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .INT } } },
        .Float => |f| .{ .kind = .{ .double_val = .{ .value = f, .kind = .DOUBLE } } },
        .String => |s| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, s), .kind = .STRING } } },
        .Decimal => |d| blk: {
            const coeff_str = try std.fmt.allocPrint(allocator, "{d}", .{d.coeff});
            const repr = if (d.scale > 0) try reconstructDecimalRepr(allocator, d.coeff, d.scale) else try allocator.dupe(u8, coeff_str);
            break :blk .{ .kind = .{ .decimal_val = .{
                .coeff = coeff_str,
                .scale = d.scale,
                .orig_scale = d.scale,
                .orig_repr = repr,
            } } };
        },
        .ExtValue => |ext| .{ .kind = .{ .ext_val = try extValueToProto(allocator, ext) } },
    };
}

/// Reconstruct a decimal string from coefficient and scale.
/// e.g., coeff=1999, scale=2 → "19.99"; coeff=5, scale=2 → "0.05"
fn reconstructDecimalRepr(allocator: std.mem.Allocator, coeff: i128, scale: u8) ![]const u8 {
    const is_negative = coeff < 0;
    // SONNY-2727, SONNY-2769: `@abs` has a u128 result, so the smallest i128
    // has a magnitude too; `-coeff` overflowed for minInt(i128).
    const abs_coeff: u128 = @abs(coeff);
    const digits = try std.fmt.allocPrint(allocator, "{d}", .{abs_coeff});
    defer allocator.free(digits);

    if (scale == 0 or digits.len == 0) {
        if (is_negative) return try std.fmt.allocPrint(allocator, "-{s}", .{digits});
        return try allocator.dupe(u8, digits);
    }

    // Pre-compute exact size to avoid ArrayList capacity mismatch on free
    const neg_len: usize = if (is_negative) 1 else 0;
    const total_len = if (digits.len <= scale)
        neg_len + 2 + (scale - digits.len) + digits.len // "-" + "0." + padding zeros + digits
    else
        neg_len + digits.len + 1; // "-" + integer part + "." + fractional part

    const buf = try allocator.alloc(u8, total_len);
    var pos: usize = 0;

    if (is_negative) {
        buf[pos] = '-';
        pos += 1;
    }

    if (digits.len <= scale) {
        // e.g., coeff=5, scale=2 → "0.05"
        buf[pos] = '0';
        buf[pos + 1] = '.';
        pos += 2;
        const pad = scale - digits.len;
        @memset(buf[pos .. pos + pad], '0');
        pos += pad;
        @memcpy(buf[pos .. pos + digits.len], digits);
    } else {
        // e.g., coeff=1999, scale=2 → "19.99"
        const int_end = digits.len - scale;
        @memcpy(buf[pos .. pos + int_end], digits[0..int_end]);
        pos += int_end;
        buf[pos] = '.';
        pos += 1;
        @memcpy(buf[pos .. pos + scale], digits[int_end..]);
    }
    return buf;
}

fn extValueToProto(allocator: std.mem.Allocator, ext: eval_extended.ExtValue) !schema.ExtendedValue {
    const type_name = type_helpers.getExtTypeName(ext);
    return switch (ext) {
        .Null => .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, "null") } },
        .Int => |i| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .int_val = i } },
        .Bool => |b| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .bool_val = b } },
        .SmallInt => |i| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .int_val = i } },
        .BigInt => |i| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .int_val = i } },
        .Real => |f| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .double_val = f } },
        .Double => |f| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .double_val = f } },
        .Str => |s| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, s) } },
        .Text => |s| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, s) } },
        .Char => |c| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, c.data) } },
        .Varchar => |v| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, v.data) } },
        .Decimal => |d| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = if (d.scale > 0) try reconstructDecimalRepr(allocator, d.coeff, d.scale) else try std.fmt.allocPrint(allocator, "{d}", .{d.coeff}) } },
        .Bytea => |b| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .bytes = try allocator.dupe(u8, b) } },
        .Json => |j| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, j) } },
        .Jsonb => |jb| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, jb.data) } },
        .Xml => |x| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, x.data) } },
        .Date => |d| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try d.toString(allocator) } },
        .Time => |t| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try t.toString(allocator) } },
        .TimeTZ => |t| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try t.toString(allocator) } },
        .Timestamp => |t| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try t.toString(allocator) } },
        .TimestampTZ => |t| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try t.toString(allocator) } },
        .Interval => |i| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try i.toString(allocator) } },
        .UUID => |u| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try u.toStringAlloc(allocator) } },
        .Url => |u| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try u.toString(allocator) } },
        .Domain => |d| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try d.toString(allocator) } },
        .BitString => |b| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try b.toString(allocator) } },
        .VarBit => |b| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try b.toString(allocator) } },
        .IntRange => |r| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try r.toString(allocator) } },
        .LanguageTag => |lt| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .text = try allocator.dupe(u8, lt.tag) } },
        .Geometry => |g| .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .bytes = try allocator.dupe(u8, g.wkb) } },
        else => blk: {
            const encoded = try property_codec.encodeExtValueBinary(allocator, ext);
            break :blk .{ .type_name = try allocator.dupe(u8, type_name), .data = .{ .bytes = encoded } };
        },
    };
}

fn textExt(allocator: std.mem.Allocator, type_name: []const u8, text: []const u8) !schema.ExtendedValue {
    return .{
        .type_name = try allocator.dupe(u8, type_name),
        .data = .{ .text = text },
    };
}
