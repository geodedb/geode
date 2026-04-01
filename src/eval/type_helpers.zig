// CANARY: REQ=REQ-REFACTOR-EVAL-004; FEATURE="EvalRefactoring"; ASPECT=TypeHelpers; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
/// Type name helper functions extracted from eval.zig
/// Contains getTypeName, getExtTypeName for type() function implementation
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
        .Decimal => "FLOAT",
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
        .Decimal => "FLOAT",
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
