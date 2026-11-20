// CANARY: REQ=REQ-REFACTOR-EVAL-004; FEATURE="EvalRefactoring"; ASPECT=TypeHelpers; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
/// Type name helper functions extracted from eval.zig
/// Contains getTypeName, getExtTypeName for type() function implementation
const std = @import("std");
const value_types = @import("../value_types.zig");
const Value = value_types.Value;
const ExtValue = @import("../eval_extended.zig").ExtValue;

// ============================================================================
// Type Name Functions
// ============================================================================

// CANARY: REQ=REQ-TYPE-001; FEATURE="TypeFunctions"; ASPECT=type_name; STATUS=TESTED; TEST=geodetestlab/specs/gql_type_system_comprehensive.yml; OWNER=types; UPDATED=2025-12-22
/// Get the type name of a Value for the type() function
pub fn getTypeName(value: Value) []const u8 {
    return switch (value) {
        .Null => "NULL",
        .Bool => "BOOLEAN",
        .Int => "INTEGER",
        // SONNY-6562: Geode's fixed-point decimal is its exact numeric type
        // (ISO/IEC 39075:2024 21.2: `1.25` is an exact numeric literal); an
        // approximate value is `.Double` / `.Real`. It was named FLOAT.
        .Decimal => "DECIMAL",
        .Str => "STRING",
        .List => "LIST",
        .Map => "MAP",
        .Node => "NODE",
        .Edge => "RELATIONSHIP",
        .Path => "PATH",
        .ExtValue => |ext| getExtTypeName(ext),
        // Advanced numeric types
        .SmallInt => "SMALLINT",
        .BigInt => "BIGINT",
        .Real => "REAL",
        .Double => "DOUBLE",
        // String types
        .Char => "CHAR",
        .Varchar => "VARCHAR",
        .Text => "TEXT",
        // Date/time types
        .Date => "DATE",
        .Time => "TIME",
        .TimeTZ => "TIMETZ",
        .Timestamp => "TIMESTAMP",
        .TimestampTZ => "TIMESTAMPTZ",
        .Interval => "INTERVAL",
        // Binary and document types
        .Bytea => "BYTEA",
        .Json => "JSON",
        .Jsonb => "JSONB",
        .Xml => "XML",
        // Network and identifier types
        .Url => "URL",
        .Domain => "DOMAIN",
        .UUID => "UUID",
        // Other types
        .Enum => "ENUM",
        .BitString => "BIT",
        .VarBit => "VARBIT",
        .IntRange => "INT4RANGE",
    };
}

/// Get the type name for extended values
pub fn getExtTypeName(ext: ExtValue) []const u8 {
    return switch (ext) {
        .Null => "NULL",
        .Int => "INTEGER",
        .Bool => "BOOLEAN",
        .Str => "STRING",
        .Decimal => "DECIMAL", // SONNY-6562: exact numeric, as getTypeName
        .SmallInt => "SMALLINT",
        .BigInt => "BIGINT",
        .Real => "REAL",
        .Double => "DOUBLE",
        .Char => "CHAR",
        .Varchar => "VARCHAR",
        .Text => "TEXT",
        .Date => "DATE",
        .Time => "TIME",
        .TimeTZ => "TIMETZ",
        .Timestamp => "TIMESTAMP",
        .TimestampTZ => "TIMESTAMPTZ",
        .VectorF32 => "VECTOR",
        .VectorI32 => "VECTOR_I32",
        .IpAddr => "INET",
        .Subnet => "CIDR",
        .Mac => "MAC",
        .Hash => "HASH",
        .Currency => "CURRENCY",
        .LanguageTag => "LANGUAGE_TAG",
        .LatLon => "POINT",
        .LatLonAlt => "POINT3D",
        .Geometry => "GEOMETRY",
        .Temperature => "TEMPERATURE",
        .Pressure => "PRESSURE",
        .Array => "ARRAY",
        .List => "LIST",
        // Advanced types
        .Interval => "INTERVAL",
        .UUID => "UUID",
        .Url => "URL",
        .Domain => "DOMAIN",
        .Bytea => "BYTEA",
        .Json => "JSON",
        .Jsonb => "JSONB",
        .Xml => "XML",
        .BitString => "BIT",
        .VarBit => "VARBIT",
        .IntRange => "INT4RANGE",
        .Enum => "ENUM",
    };
}

// CANARY: REQ=REQ-SONNY-6562-DECLARED-TYPE; FEATURE="ResultMetadata"; ASPECT=TypeCombination; STATUS=TESTED; TEST=tests/test_sonny6562_wire_metadata.zig; OWNER=types; UPDATED=2026-11-15
/// SONNY-6562: the declared type of a column holding values of the types
/// named `a` and `b` (names from `getTypeName` / `getExtTypeName`).
/// ISO/IEC 39075:2024 22.18 "General combination of value types" over 22.19
/// "Static combination of value types":
///   - the null type adds nothing (22.19 SR 3, 4 a);
///   - exact numerics combine to an exact numeric (SR 4 d ii 2): DECIMAL when
///     either is one, else the wider integer; an approximate numeric makes
///     the result approximate (SR 4 d ii 1): DOUBLE unless both are REAL;
///   - character strings to a character string supertype (SR 4 b): STRING;
///   - a zoned and a local datetime or time to the zoned type (SR 4 e, f);
///   - list value types to a list (SR 4 k), element types are not declared;
///   - anything else is not statically combinable: the open dynamic union
///     type, `ANY` (22.18 SR 9 c ii; 18.9 <open dynamic union type>).
/// Commutative and associative, so a column's type folds over its values.
pub fn combineTypeNames(a: []const u8, b: []const u8) []const u8 {
    if (sameName(a, b)) return a;
    if (sameName(a, "NULL")) return b;
    if (sameName(b, "NULL")) return a;
    if (sameName(a, "ANY") or sameName(b, "ANY")) return "ANY";

    const ra = exactNumericRank(a);
    const rb = exactNumericRank(b);
    const aa = isApproximateNumeric(a);
    const ab = isApproximateNumeric(b);
    if ((ra != null or aa) and (rb != null or ab)) {
        if (aa or ab) return "DOUBLE"; // REAL + REAL returned above
        return if (ra.? >= rb.?) a else b;
    }
    if (isCharacterString(a) and isCharacterString(b)) return "STRING";
    if (isOneOf(a, &.{ "TIMESTAMP", "TIMESTAMPTZ" }) and isOneOf(b, &.{ "TIMESTAMP", "TIMESTAMPTZ" })) return "TIMESTAMPTZ";
    if (isOneOf(a, &.{ "TIME", "TIMETZ" }) and isOneOf(b, &.{ "TIME", "TIMETZ" })) return "TIMETZ";
    if (isOneOf(a, &.{ "LIST", "ARRAY" }) and isOneOf(b, &.{ "LIST", "ARRAY" })) return "LIST";
    return "ANY";
}

fn sameName(a: []const u8, b: []const u8) bool {
    return (a.ptr == b.ptr and a.len == b.len) or std.mem.eql(u8, a, b);
}

fn isOneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |n| if (sameName(name, n)) return true;
    return false;
}

/// Exact numeric types, ordered so the larger can hold the smaller's values.
fn exactNumericRank(name: []const u8) ?u8 {
    if (sameName(name, "SMALLINT")) return 0;
    if (sameName(name, "INTEGER")) return 1;
    if (sameName(name, "BIGINT")) return 2;
    if (sameName(name, "DECIMAL")) return 3;
    return null;
}

fn isApproximateNumeric(name: []const u8) bool {
    return isOneOf(name, &.{ "REAL", "DOUBLE" });
}

fn isCharacterString(name: []const u8) bool {
    return isOneOf(name, &.{ "STRING", "CHAR", "VARCHAR", "TEXT" });
}
