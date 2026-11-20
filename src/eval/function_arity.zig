//! SONNY-6637 item 3: how many operands each function takes, in one place.
//!
//! ISO/IEC 39075:2024 4.7.3 step 4 e): a request that violates a Syntax
//! Rule fails with "syntax error or access rule violation" (42000) before
//! anything runs, and the number of operands of a function call is decided
//! by the program text. SONNY-6555 made every function's own dispatch refuse
//! a wrong count (`error.WrongArgumentCount`), but only when the call was
//! evaluated: `MATCH (n) WHERE false RETURN sqrt(1, 2)` ran, and an
//! aggregate (`sum(1, 2)`), evaluated by the projection, never checked.
//!
//! This table is read twice: by the statement check every transport runs
//! after parsing (`scope_check.checkCallArity`, from `param_check`), so a
//! wrong count is refused whether or not a row reaches the call; and once
//! before the evaluator dispatches a call (`eval.zig`), for a statement
//! built without that check. It covers the built-ins of
//! src/eval/call_handlers.zig and src/eval.zig, the extension registry of
//! src/eval_extended.zig, the quantifiers and the timeseries.* functions. A
//! name not in it is not checked here (its dispatch still checks).
//!
//! `max = null`: any number from `min` up. `form`: how a call is written
//! when the parser owns part of it (tests/test_sonny6637_function_arity.zig
//! reads it).
//!
//! CANARY: REQ=REQ-SONNY-6637-ARITY-TABLE; FEATURE="BuiltinFunctions"; ASPECT=SharedArityTable; STATUS=TESTED; TEST=tests/test_sonny6637_function_arity.zig; OWNER=eval; UPDATED=2026-11-15

const std = @import("std");
const ast = @import("../gql/ast.zig");

pub const Form = enum {
    /// `f(a, b, ...)`, operands any expression.
    call,
    /// The parser checks the operand count itself (a wrong count is a
    /// syntax error, UnexpectedToken, before this table is read).
    parser_checked,
    /// An operand is written a particular way the parser requires (`CAST(x
    /// AS T)`, a literal), so `f(NULL)` is no call of it.
    literal_operand,
};

pub const Entry = struct {
    name: []const u8,
    min: u8,
    max: ?u8,
    form: Form = .call,
};

pub const Arity = struct {
    min: u8,
    max: ?u8,

    pub fn accepts(self: Arity, n: usize) bool {
        if (n < self.min) return false;
        if (self.max) |m| return n <= m;
        return true;
    }
};

/// Every function, lowercase, in name order.
pub const entries = [_]Entry{
    .{ .name = "abs", .min = 1, .max = 1, .form = .parser_checked },
    .{ .name = "acos", .min = 1, .max = 1 },
    .{ .name = "algo.asnode", .min = 1, .max = 1 },
    .{ .name = "algo.similarity.cosine", .min = 2, .max = 2 },
    .{ .name = "algo.similarity.jaccard", .min = 2, .max = 2 },
    .{ .name = "all", .min = 1, .max = 1 },
    .{ .name = "all_shortest_paths", .min = 1, .max = 2 },
    .{ .name = "allshortestpaths", .min = 1, .max = 2, .form = .parser_checked },
    .{ .name = "alt_ref", .min = 1, .max = 1 },
    .{ .name = "altitude", .min = 1, .max = 1 },
    .{ .name = "any", .min = 1, .max = 1 },
    .{ .name = "array", .min = 1, .max = 1 },
    .{ .name = "array_contains", .min = 2, .max = 2 },
    .{ .name = "array_length", .min = 1, .max = 1 },
    .{ .name = "asin", .min = 1, .max = 1 },
    .{ .name = "asnode", .min = 1, .max = 1 },
    .{ .name = "atan", .min = 1, .max = 1 },
    .{ .name = "atan2", .min = 2, .max = 2 },
    .{ .name = "avg", .min = 1, .max = 1 },
    .{ .name = "bigint", .min = 1, .max = 1 },
    .{ .name = "bit", .min = 1, .max = 1 },
    .{ .name = "bit_and", .min = 2, .max = 2 },
    .{ .name = "bit_count", .min = 1, .max = 1 },
    .{ .name = "bool", .min = 1, .max = 1 },
    .{ .name = "bytea", .min = 1, .max = 1 },
    .{ .name = "cast", .min = 2, .max = 2, .form = .literal_operand },
    .{ .name = "ceil", .min = 1, .max = 1 },
    .{ .name = "char", .min = 2, .max = 2 },
    .{ .name = "coalesce", .min = 1, .max = null, .form = .parser_checked },
    .{ .name = "collect", .min = 1, .max = 1 },
    .{ .name = "contains", .min = 2, .max = 2 },
    .{ .name = "cos", .min = 1, .max = 1 },
    .{ .name = "cosine", .min = 2, .max = 2 },
    .{ .name = "count", .min = 1, .max = 1 },
    .{ .name = "currency", .min = 1, .max = 1 },
    .{ .name = "current_date", .min = 0, .max = 0 },
    .{ .name = "current_time", .min = 0, .max = 0 },
    .{ .name = "current_timestamp", .min = 0, .max = 0 },
    .{ .name = "current_user", .min = 0, .max = 0 },
    .{ .name = "date", .min = 0, .max = 1 },
    .{ .name = "date_part", .min = 2, .max = 2 },
    .{ .name = "datetime", .min = 0, .max = 1 },
    .{ .name = "decimal", .min = 1, .max = 2 },
    .{ .name = "decimal_add", .min = 2, .max = 2 },
    .{ .name = "decimal_div", .min = 2, .max = 2 },
    .{ .name = "decimal_mul", .min = 2, .max = 2 },
    .{ .name = "decimal_sub", .min = 2, .max = 2 },
    .{ .name = "degrees", .min = 1, .max = 1 },
    .{ .name = "distance", .min = 2, .max = 3 },
    .{ .name = "distance_haversine", .min = 2, .max = 2 },
    .{ .name = "domain", .min = 1, .max = 1 },
    .{ .name = "domain_labels", .min = 1, .max = 1 },
    .{ .name = "domain_root", .min = 1, .max = 1 },
    .{ .name = "domain_suffix_match", .min = 2, .max = 2 },
    .{ .name = "double", .min = 1, .max = 1 },
    .{ .name = "duration", .min = 1, .max = 1 },
    .{ .name = "duration_add", .min = 2, .max = 2 },
    .{ .name = "duration_sub", .min = 2, .max = 2 },
    .{ .name = "e", .min = 0, .max = 0 },
    .{ .name = "endswith", .min = 2, .max = 2 },
    .{ .name = "euclidean", .min = 2, .max = 2 },
    .{ .name = "exp", .min = 1, .max = 1 },
    .{ .name = "floor", .min = 1, .max = 1 },
    .{ .name = "from_hex", .min = 1, .max = 1 },
    .{ .name = "geo_bearing", .min = 2, .max = 2 },
    .{ .name = "geo_lat", .min = 1, .max = 1 },
    .{ .name = "geo_lon", .min = 1, .max = 1 },
    .{ .name = "geobox_contains", .min = 3, .max = 3 },
    .{ .name = "geometryfromtext", .min = 1, .max = 1, .form = .literal_operand },
    .{ .name = "hash", .min = 2, .max = 2 },
    .{ .name = "hash_alg", .min = 1, .max = 1 },
    .{ .name = "hash_equals", .min = 2, .max = 2 },
    .{ .name = "head", .min = 1, .max = 1 },
    .{ .name = "icontains", .min = 2, .max = 2 },
    .{ .name = "indegree", .min = 1, .max = 1 },
    .{ .name = "int", .min = 1, .max = 1 },
    .{ .name = "interval", .min = 1, .max = 1 },
    .{ .name = "interval_contains", .min = 2, .max = 2 },
    .{ .name = "interval_overlaps", .min = 2, .max = 2 },
    .{ .name = "intrange", .min = 4, .max = 4 },
    .{ .name = "ip_contains", .min = 2, .max = 2 },
    .{ .name = "ip_family", .min = 1, .max = 1 },
    .{ .name = "ip_is_private", .min = 1, .max = 1 },
    .{ .name = "ip_netmask", .min = 2, .max = 2 },
    .{ .name = "ip_network", .min = 1, .max = 1 },
    .{ .name = "ip_overlaps", .min = 2, .max = 2 },
    .{ .name = "ipaddr", .min = 1, .max = 1 },
    .{ .name = "jaccard", .min = 2, .max = 2 },
    .{ .name = "json", .min = 1, .max = 1 },
    .{ .name = "json_get", .min = 2, .max = 2 },
    .{ .name = "jsonb", .min = 1, .max = 1, .form = .literal_operand },
    .{ .name = "jsonb_exists", .min = 2, .max = 2 },
    .{ .name = "jsonb_get", .min = 2, .max = 2 },
    .{ .name = "jsonb_typeof", .min = 1, .max = 1 },
    .{ .name = "keys", .min = 1, .max = 1, .form = .parser_checked },
    .{ .name = "knn", .min = 4, .max = 4 },
    .{ .name = "lang_canonicalize", .min = 1, .max = 1 },
    .{ .name = "lang_match", .min = 2, .max = 2 },
    .{ .name = "languagetag", .min = 1, .max = 1 },
    .{ .name = "last", .min = 1, .max = 1 },
    .{ .name = "latitude", .min = 1, .max = 1 },
    .{ .name = "latlon", .min = 1, .max = 2, .form = .literal_operand },
    .{ .name = "latlonalt", .min = 1, .max = 4, .form = .literal_operand },
    .{ .name = "left", .min = 2, .max = 2 },
    .{ .name = "length", .min = 1, .max = 1, .form = .parser_checked },
    .{ .name = "localdatetime", .min = 0, .max = 1 },
    .{ .name = "localtime", .min = 0, .max = 1 },
    .{ .name = "log", .min = 1, .max = 1 },
    .{ .name = "log10", .min = 1, .max = 1 },
    .{ .name = "longitude", .min = 1, .max = 1 },
    .{ .name = "lower", .min = 1, .max = 1 },
    .{ .name = "ltrim", .min = 1, .max = 1 },
    .{ .name = "mac", .min = 1, .max = 1 },
    .{ .name = "mac_is_local", .min = 1, .max = 1 },
    .{ .name = "mac_is_multicast", .min = 1, .max = 1 },
    .{ .name = "makeinterval", .min = 3, .max = 3 },
    .{ .name = "manhattan", .min = 2, .max = 2 },
    .{ .name = "max", .min = 1, .max = 1 },
    .{ .name = "min", .min = 1, .max = 1 },
    .{ .name = "minor_units", .min = 1, .max = 1 },
    .{ .name = "mod", .min = 2, .max = 2 },
    .{ .name = "nodes", .min = 1, .max = 1 },
    .{ .name = "none", .min = 1, .max = 1 },
    .{ .name = "nullif", .min = 2, .max = 2 },
    .{ .name = "oui", .min = 1, .max = 1 },
    .{ .name = "outdegree", .min = 1, .max = 1 },
    .{ .name = "pi", .min = 0, .max = 0 },
    .{ .name = "polygon_area", .min = 1, .max = 1 },
    .{ .name = "pow", .min = 2, .max = 2 },
    .{ .name = "power", .min = 2, .max = 2 },
    .{ .name = "pressure", .min = 2, .max = 2 },
    .{ .name = "properties", .min = 1, .max = 1 },
    .{ .name = "radians", .min = 1, .max = 1 },
    .{ .name = "rand", .min = 0, .max = 0 },
    .{ .name = "random", .min = 0, .max = 0 },
    .{ .name = "range", .min = 2, .max = 4 },
    .{ .name = "range_contains", .min = 2, .max = 2 },
    .{ .name = "range_overlaps", .min = 2, .max = 2 },
    .{ .name = "real", .min = 1, .max = 1 },
    .{ .name = "relationships", .min = 1, .max = 1 },
    .{ .name = "replace", .min = 3, .max = 3 },
    .{ .name = "reverse", .min = 1, .max = 1 },
    .{ .name = "right", .min = 2, .max = 2 },
    .{ .name = "round", .min = 1, .max = 2 },
    .{ .name = "rtrim", .min = 1, .max = 1 },
    .{ .name = "shortest_path", .min = 1, .max = 2 },
    .{ .name = "shortestpath", .min = 1, .max = 2, .form = .parser_checked },
    .{ .name = "sign", .min = 1, .max = 1 },
    .{ .name = "similarity", .min = 2, .max = 3 },
    .{ .name = "sin", .min = 1, .max = 1 },
    .{ .name = "single", .min = 1, .max = 1 },
    .{ .name = "size", .min = 1, .max = 1 },
    .{ .name = "smallint", .min = 1, .max = 1 },
    .{ .name = "split", .min = 2, .max = 2 },
    .{ .name = "sqrt", .min = 1, .max = 1 },
    .{ .name = "st_area", .min = 1, .max = 1 },
    .{ .name = "st_asgeojson", .min = 1, .max = 1 },
    .{ .name = "st_astext", .min = 1, .max = 1 },
    .{ .name = "st_buffer", .min = 2, .max = 2 },
    .{ .name = "st_centroid", .min = 1, .max = 1 },
    .{ .name = "st_contains", .min = 2, .max = 2 },
    .{ .name = "st_distance", .min = 2, .max = 2 },
    .{ .name = "st_intersects", .min = 2, .max = 2 },
    .{ .name = "st_point", .min = 2, .max = 2 },
    .{ .name = "st_within", .min = 2, .max = 2 },
    .{ .name = "st_x", .min = 1, .max = 1 },
    .{ .name = "st_y", .min = 1, .max = 1 },
    .{ .name = "startswith", .min = 2, .max = 2 },
    .{ .name = "subnet", .min = 1, .max = 1 },
    .{ .name = "subnet_prefix_length", .min = 1, .max = 1 },
    .{ .name = "substring", .min = 2, .max = 3 },
    .{ .name = "sum", .min = 1, .max = 1 },
    .{ .name = "tail", .min = 1, .max = 1 },
    .{ .name = "tan", .min = 1, .max = 1 },
    .{ .name = "temperature", .min = 2, .max = 2 },
    .{ .name = "text", .min = 1, .max = 1 },
    .{ .name = "time", .min = 0, .max = 1 },
    .{ .name = "time_part", .min = 2, .max = 2 },
    .{ .name = "timeseries.change_points", .min = 6, .max = 6 },
    .{ .name = "timeseries.derivative", .min = 3, .max = 3 },
    .{ .name = "timeseries.extract_features", .min = 4, .max = 4 },
    .{ .name = "timeseries.interpolate", .min = 4, .max = 4 },
    .{ .name = "timeseries.last_value", .min = 2, .max = 2 },
    .{ .name = "timeseries.matrix_profile", .min = 5, .max = 5 },
    .{ .name = "timeseries.moving_avg", .min = 4, .max = 4 },
    .{ .name = "timeseries.rate", .min = 3, .max = 3 },
    .{ .name = "timeseries.sample_by", .min = 6, .max = 6 },
    .{ .name = "timeseries.time_bucket", .min = 5, .max = 5 },
    .{ .name = "timeseries.value", .min = 3, .max = 3 },
    .{ .name = "timeseries.value_at", .min = 3, .max = 3 },
    .{ .name = "timestamp", .min = 0, .max = 1 },
    .{ .name = "timestamptz", .min = 1, .max = 1 },
    .{ .name = "timetz", .min = 1, .max = 2 },
    .{ .name = "to_hex", .min = 1, .max = 1 },
    .{ .name = "tobool", .min = 1, .max = 1 },
    .{ .name = "toboolean", .min = 1, .max = 1 },
    .{ .name = "todouble", .min = 1, .max = 1 },
    .{ .name = "tofloat", .min = 1, .max = 1 },
    .{ .name = "toint", .min = 1, .max = 1 },
    .{ .name = "tointeger", .min = 1, .max = 1, .form = .parser_checked },
    .{ .name = "tolower", .min = 1, .max = 1 },
    .{ .name = "toreal", .min = 1, .max = 1 },
    .{ .name = "tostring", .min = 1, .max = 1, .form = .parser_checked },
    .{ .name = "toupper", .min = 1, .max = 1 },
    .{ .name = "trim", .min = 1, .max = 1 },
    .{ .name = "type", .min = 1, .max = 1, .form = .parser_checked },
    .{ .name = "upper", .min = 1, .max = 1 },
    .{ .name = "url", .min = 1, .max = 1 },
    .{ .name = "url_host", .min = 1, .max = 1 },
    .{ .name = "url_origin", .min = 1, .max = 1 },
    .{ .name = "url_path", .min = 1, .max = 1 },
    .{ .name = "url_query", .min = 1, .max = 1 },
    .{ .name = "url_scheme", .min = 1, .max = 1 },
    .{ .name = "uuid", .min = 0, .max = 1 },
    .{ .name = "uuid_equal", .min = 2, .max = 2 },
    .{ .name = "uuid_v4", .min = 0, .max = 0 },
    .{ .name = "uuid_v7", .min = 0, .max = 0 },
    .{ .name = "values", .min = 1, .max = 1, .form = .parser_checked },
    .{ .name = "valuetype", .min = 1, .max = 1 },
    .{ .name = "varbit", .min = 1, .max = 1 },
    .{ .name = "varchar", .min = 2, .max = 2 },
    .{ .name = "vector", .min = 1, .max = 1 },
    .{ .name = "vector_cosine", .min = 2, .max = 2 },
    .{ .name = "vector_dot", .min = 2, .max = 2 },
    .{ .name = "vector_knn", .min = 4, .max = 4 },
    .{ .name = "vector_l2", .min = 2, .max = 2 },
    .{ .name = "vectorf32", .min = 1, .max = 1, .form = .literal_operand },
    .{ .name = "vectori32", .min = 1, .max = 1, .form = .literal_operand },
    .{ .name = "xml", .min = 1, .max = 1 },
    .{ .name = "xml_is_well_formed", .min = 1, .max = 1 },
};

const table = blk: {
    var kvs: [entries.len]struct { []const u8, Arity } = undefined;
    for (entries, &kvs) |e, *kv| kv.* = .{ e.name, .{ .min = e.min, .max = e.max } };
    break :blk std.StaticStringMap(Arity).initComptime(kvs);
};

/// The arity of function `name` (any case), or null when it is not here.
pub fn lookup(name: []const u8) ?Arity {
    var buf: [64]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, buf[0..name.len]) |c, *o| o.* = std.ascii.toLower(c);
    return table.get(buf[0..name.len]);
}

/// Refuse `n` operands for function `name` when this table says it takes
/// another number.
pub fn check(name: []const u8, n: usize) error{WrongArgumentCount}!void {
    const arity = lookup(name) orelse return;
    if (!arity.accepts(n)) return error.WrongArgumentCount;
}

/// The name a call's callee spells (`f`, `timeseries.value`,
/// `algo.similarity.jaccard`), in `buf`; null for any other callee.
pub fn calleeName(callee: *const ast.Expr, buf: []u8) ?[]const u8 {
    var parts: [8][]const u8 = undefined;
    var count: usize = 0;
    var at = callee;
    while (true) {
        if (count == parts.len) return null;
        switch (at.*) {
            .Ident => |id| {
                parts[count] = id.orig;
                count += 1;
                break;
            },
            .Member => |m| {
                parts[count] = m.field;
                count += 1;
                at = m.target;
            },
            else => return null,
        }
    }
    var len: usize = 0;
    var i = count;
    while (i > 0) {
        i -= 1;
        const sep: usize = if (i + 1 < count) 1 else 0;
        if (len + sep + parts[i].len > buf.len) return null;
        if (sep == 1) {
            buf[len] = '.';
            len += 1;
        }
        @memcpy(buf[len..][0..parts[i].len], parts[i]);
        len += parts[i].len;
    }
    return buf[0..len];
}

test "function_arity: names are lowercase, unique and sorted; ranges are sane" {
    for (entries, 0..) |e, i| {
        for (e.name) |c| try std.testing.expect(!std.ascii.isUpper(c));
        if (i > 0) try std.testing.expect(std.mem.lessThan(u8, entries[i - 1].name, e.name));
        if (e.max) |m| try std.testing.expect(e.min <= m);
    }
    try std.testing.expect(lookup("SQRT").?.accepts(1));
    try std.testing.expectError(error.WrongArgumentCount, check("sqrt", 2));
    try check("no_such_function", 9);
}
