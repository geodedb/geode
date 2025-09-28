// ISO/IEC 39075:2024 GQL Status and Diagnostics
const std = @import("std");

pub const StatusClass = enum {
    SUCCESS,
    WARNING,
    ERROR,
};

pub const GqlStatus = struct {
    sqlstate: [5]u8,
    class: StatusClass,
    message: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
    token: ?[]const u8 = null,
    diagnostics: []const Diagnostic = &.{},
};

pub const Diagnostic = struct {
    code: []const u8,
    message: []const u8,
    severity: StatusClass,
};

// Common SQLSTATE codes per ISO
pub const SQLSTATE = struct {
    pub const SUCCESS = "00000".*;
    pub const WARNING = "01000".*;
    pub const NO_DATA = "02000".*;
    pub const FEATURE_NOT_SUPPORTED = "0A000".*;
    pub const CARDINALITY_VIOLATION = "21000".*;
    pub const DATA_EXCEPTION = "22000".*;
    pub const INVALID_CHARACTER = "22018".*;
    pub const INTEGRITY_CONSTRAINT = "23000".*;
    pub const INVALID_CURSOR_STATE = "24000".*;
    pub const INVALID_TRANSACTION_STATE = "25000".*;
    pub const SYNTAX_ERROR = "42601".*;
    pub const UNDEFINED_OBJECT = "42703".*;
    pub const DUPLICATE_ALIAS = "42712".*;
    pub const INVALID_SCHEMA = "42000".*;
};

// Create standard error statuses
pub fn syntaxError(message: []const u8, line: u32, column: u32, token: ?[]const u8) GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.SYNTAX_ERROR,
        .class = .ERROR,
        .message = message,
        .line = line,
        .column = column,
        .token = token,
    };
}

pub fn undefinedIdentifier(name: []const u8, line: u32, column: u32) GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.UNDEFINED_OBJECT,
        .class = .ERROR,
        .message = "undefined identifier or alias",
        .line = line,
        .column = column,
        .token = name,
    };
}

pub fn duplicateAlias(name: []const u8, line: u32, column: u32) GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.DUPLICATE_ALIAS,
        .class = .ERROR,
        .message = "duplicate identifier (case-insensitive collision)",
        .line = line,
        .column = column,
        .token = name,
    };
}

pub fn featureNotSupported(feature: []const u8) GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.FEATURE_NOT_SUPPORTED,
        .class = .ERROR,
        .message = feature,
    };
}

pub fn invalidCharacter(message: []const u8, line: u32, column: u32) GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.INVALID_CHARACTER,
        .class = .ERROR,
        .message = message,
        .line = line,
        .column = column,
    };
}

pub fn success() GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.SUCCESS,
        .class = .SUCCESS,
        .message = "OK",
    };
}

// Write JSON diagnostics with stable key order
pub fn writeJson(writer: anytype, status: GqlStatus) !void {
    try writer.writeByte('{');

    // Always include sqlstate first
    try writer.print("\"sqlstate\":\"{s}\"", .{status.sqlstate});

    // Then class
    const class_str = switch (status.class) {
        .SUCCESS => "SUCCESS",
        .WARNING => "WARNING",
        .ERROR => "ERROR",
    };
    try writer.print(",\"class\":\"{s}\"", .{class_str});

    // Then message
    try writer.print(",\"message\":\"{s}\"", .{status.message});

    // Optional fields in order
    if (status.line) |l| {
        try writer.print(",\"line\":{}", .{l});
    }
    if (status.column) |c| {
        try writer.print(",\"column\":{}", .{c});
    }
    if (status.token) |t| {
        try writer.print(",\"token\":\"{s}\"", .{t});
    }

    // Diagnostics array
    try writer.writeAll(",\"diagnostics\":[");
    for (status.diagnostics, 0..) |diag, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.print("\"code\":\"{s}\",", .{diag.code});
        try writer.print("\"message\":\"{s}\",", .{diag.message});
        const sev_str = switch (diag.severity) {
            .SUCCESS => "SUCCESS",
            .WARNING => "WARNING",
            .ERROR => "ERROR",
        };
        try writer.print("\"severity\":\"{s}\"", .{sev_str});
        try writer.writeByte('}');
    }
    try writer.writeAll("]");

    try writer.writeByte('}');
}
