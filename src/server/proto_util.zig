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

    for (params, 0..) |param, i| {
        names[i] = try allocator.dupe(u8, param.name);
        if (param.value) |val| {
            values[i] = try protoValueToValue(allocator, val, 0);
        } else {
            values[i] = .Null;
        }
    }

    return .{ .names = names, .values = values };
}

pub fn freeParamBindings(allocator: std.mem.Allocator, bindings: ParamBindings) void {
    for (bindings.names) |name| allocator.free(name);
    for (bindings.values) |val| freeParamValue(allocator, val);
    allocator.free(bindings.names);
    allocator.free(bindings.values);
}

pub fn protoValueToValue(allocator: std.mem.Allocator, value: schema.Value, depth: usize) !value_types.Value {
    if (depth > 64) return error.ParamsTooDeep;
    const kind = value.kind orelse return .Null;
    return switch (kind) {
        .null_val => .Null,
        .bool_val => |b| .{ .Bool = b },
        .int_val => |iv| switch (iv.kind) {
            .INT => .{ .Int = iv.value },
            .SMALLINT => .{ .SmallInt = @intCast(iv.value) },
            .BIGINT => .{ .BigInt = iv.value },
            else => .{ .Int = iv.value },
        },
        .double_val => |dv| switch (dv.kind) {
            .REAL => .{ .Real = @floatCast(dv.value) },
            .DOUBLE => .{ .Double = dv.value },
            else => .{ .Double = dv.value },
        },
        .string_val => |sv| switch (sv.kind) {
            .CHAR => .{ .Char = .{ .data = try allocator.dupe(u8, sv.value), .n = @intCast(sv.value.len) } },
            .VARCHAR => .{ .Varchar = .{ .data = try allocator.dupe(u8, sv.value), .n = @intCast(sv.value.len) } },
            .TEXT => .{ .Text = try allocator.dupe(u8, sv.value) },
            else => .{ .Str = try allocator.dupe(u8, sv.value) },
        },
        .decimal_val => |dec| blk: {
            const coeff = std.fmt.parseInt(i128, dec.coeff, 10) catch return error.InvalidParams;
            const orig_repr = if (dec.orig_repr.len > 0)
                try allocator.dupe(u8, dec.orig_repr)
            else
                null;
            break :blk .{ .Decimal = .{
                .coeff = coeff,
                .scale = @intCast(dec.scale),
                .orig_scale = @intCast(dec.orig_scale),
                .orig_repr = orig_repr,
            } };
        },
        .bytes_val => |bv| .{ .Bytea = try allocator.dupe(u8, bv.value) },
        .list_val => |lv| blk: {
            const list = try allocator.alloc(value_types.Value, lv.values.items.len);
            for (lv.values.items, 0..) |item, idx| {
                list[idx] = try protoValueToValue(allocator, item, depth + 1);
            }
            break :blk .{ .List = list };
        },
        .map_val => |mv| blk: {
            var map = std.StringHashMap(value_types.Value).init(allocator);
            errdefer map.deinit();
            for (mv.entries.items) |entry| {
                const key = try allocator.dupe(u8, entry.key);
                const val = if (entry.value) |v|
                    try protoValueToValue(allocator, v, depth + 1)
                else
                    value_types.Value.Null;
                try map.put(key, val);
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

pub fn mapError(err: anyerror) ErrorInfo {
    return switch (err) {
        error.GroupingError => .{ .code = "42000", .message = "grouping error: non-aggregated expression not in GROUP BY" },
        // GAP-0914: a GROUP BY key that resolves to no alias, variable, or
        // binding is rejected instead of collapsing rows into one null group.
        error.UnknownGroupKey => .{ .code = "42703", .message = "GROUP BY key does not resolve to any RETURN alias, variable, or binding" },
        error.UnorderedPagination => .{ .code = "US001", .message = "OFFSET requires ORDER BY clause" },
        error.TransactionAlreadyActive => .{ .code = "25001", .message = "Transaction already active" },
        // GAP-0917: statement failed mid-transaction; everything until
        // ROLLBACK is rejected and COMMIT aborts. 25P02 = in_failed_sql_transaction.
        error.TransactionAborted => .{ .code = "25P02", .message = "Current transaction is aborted; statements are rejected until ROLLBACK" },
        error.NoActiveTransaction => .{ .code = "25000", .message = "No active transaction" },
        error.UnionColumnCountMismatch => .{ .code = "42601", .message = "UNION column count mismatch" },
        error.DuplicateGraph => .{ .code = "42P07", .message = "Duplicate graph name" },
        error.GraphNotFound => .{ .code = "3F000", .message = "Graph does not exist" },
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
        error.DuplicateIndex => .{ .code = "42P07", .message = "Duplicate index name" },
        // GAP-0923: ABAC policy DDL validation (duplicate name rejected).
        error.PolicyAlreadyExists => .{ .code = "42710", .message = "Duplicate policy name" },
        error.IncompatibleIndexDataType => .{ .code = "42804", .message = "Incompatible index data type" },
        // GAP-0922: fulltext index requires a text (string) property.
        error.FulltextRequiresTextProperty => .{ .code = "42804", .message = "Fulltext index requires a text (string) property; the indexed property holds only non-string values" },
        // GAP-0918: vector index validation.
        error.InvalidIndexMetric => .{ .code = "42704", .message = "Unknown vector distance metric (supported: l2, euclidean, cosine, dot_product, inner_product)" },
        error.VectorDimensionMismatch => .{ .code = "22000", .message = "Vector dimension does not match the indexed property's established dimension" },
        error.InvalidTypeConversion => .{ .code = "22003", .message = "Invalid type conversion" },
        // GAP-0905/GAP-0907: checked numeric narrowing (CAST, MakeInterval, ...)
        // surfaces as SQLSTATE 22003 numeric_value_out_of_range.
        error.IntegerOverflow => .{ .code = "22003", .message = "Integer value out of range" },
        // GAP-0921: CAST semantic validation.
        error.InvalidCast => .{ .code = "22018", .message = "Invalid character value for cast" },
        error.UnsupportedCastTarget => .{ .code = "0A000", .message = "Unsupported CAST target type" },
        // GAP-0926: out-of-range positional parameter.
        error.MissingParameter => .{ .code = "22023", .message = "Positional parameter out of range (referenced a parameter that was not supplied)" },
        // GAP-0926: nested aggregate (sum(avg(...))) is invalid.
        error.NestedAggregate => .{ .code = "42803", .message = "Aggregate functions cannot be nested" },
        error.StringDataRightTruncation => .{ .code = "22001", .message = "String data right truncation" },
        error.InvalidKeyProvider => .{ .code = "42704", .message = "Invalid TDE key provider" },
        error.InvalidGuardrailConfiguration => .{ .code = "42704", .message = "Invalid CDC guardrail configuration" },
        error.PasswordPolicyViolation => .{ .code = "22000", .message = "password does not meet policy requirements (min 8 chars, letters and numbers)" },
        error.UnknownProcedure => .{ .code = "42883", .message = "Unknown procedure" },
        // docs/@BUGS_731.md bug 8b: an unresolved scalar function used to
        // silently evaluate to NULL; surface it with the same
        // undefined_function SQLSTATE the procedure path uses.
        error.UnknownFunction => .{ .code = "42883", .message = "Unknown function" },
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
        error.SearchNotPermitted => .{ .code = "42501", .message = "Access denied: READ_PLAINTEXT privilege required for encrypted searchable field" },
        error.InvalidIpAddress => .{ .code = "22P02", .message = "Invalid IP address format" },
        error.InvalidMac, error.InvalidMacFormat, error.InvalidMacTag => .{ .code = "22P02", .message = "Invalid MAC address format" },
        error.DivisionByZero => .{ .code = "22012", .message = "Division by zero" },
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
        // GAP (write-path OOM, 2026-07-04): the legacy write-carrying MATCH
        // executor aborted because its materialization working set crossed the
        // configured budget — a loud, clean refusal instead of the OOM killer.
        // 53200 = SQLSTATE out_of_memory (class 53, insufficient resources).
        error.WriteQueryBudgetExceeded => .{ .code = "53200", .message = "WriteQueryBudgetExceeded: this write query's working set exceeded GEODE_WRITE_EXECUTOR_BUDGET_MB (default 8192; 0 disables) and was aborted before exhausting server memory. Aborted BETWEEN row mutations: rows already written remain applied (no statement-level rollback in autocommit). Narrow the MATCH (single-node indexed-equality point writes run engine-direct) or raise the budget" },
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

fn inferColumnType(rows: [][]value_types.Value, col_idx: usize) []const u8 {
    const sample_size = @min(rows.len, 10);
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
        const val = try propertyValueToProto(allocator, entry.value_ptr.*);
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
        const val = try propertyValueToProto(allocator, entry.value_ptr.*);
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
    const abs_coeff: u128 = if (is_negative) @intCast(-coeff) else @intCast(coeff);
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
