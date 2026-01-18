// Module implementation
// JSON-RPC 2.0 protocol implementation for Language Server Protocol
// Spec: specs/lsp/language-server-protocol/_specifications/base/0.9/specification.md

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const JsonRpcVersion = "2.0";

pub const RequestId = union(enum) {
    integer: i64,
    string: []const u8,
    null_id,

    pub fn format(self: RequestId, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .integer => |i| try writer.print("{d}", .{i}),
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .null_id => try writer.writeAll("null"),
        }
    }
};

pub const ErrorCode = enum(i32) {
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603,
    RequestFailed = -32803,
    ServerCancelled = -32802,
    ContentModified = -32801,
    RequestCancelled = -32800,
};

pub const ResponseError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

pub const Message = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,
};

pub const Request = struct {
    jsonrpc: []const u8 = JsonRpcVersion,
    id: RequestId,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const Response = struct {
    jsonrpc: []const u8 = JsonRpcVersion,
    id: RequestId,
    result: ?std.json.Value = null,
    @"error": ?ResponseError = null,
};

pub const Notification = struct {
    jsonrpc: []const u8 = JsonRpcVersion,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const TextDocumentIdentifier = struct {
    uri: []const u8,
};

pub const VersionedTextDocumentIdentifier = struct {
    uri: []const u8,
    version: i32,
};

pub const TextDocumentItem = struct {
    uri: []const u8,
    languageId: []const u8,
    version: i32,
    text: []const u8,
};

pub const TextDocumentContentChangeEvent = struct {
    range: ?Range = null,
    rangeLength: ?u32 = null,
    text: []const u8,
};

pub const DiagnosticSeverity = enum(u8) {
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4,
};

pub const Diagnostic = struct {
    range: Range,
    severity: ?DiagnosticSeverity = null,
    code: ?std.json.Value = null,
    source: ?[]const u8 = null,
    message: []const u8,
    relatedInformation: ?[]const u8 = null,
};

pub const CompletionItemKind = enum(u8) {
    Text = 1,
    Method = 2,
    Function = 3,
    Constructor = 4,
    Field = 5,
    Variable = 6,
    Class = 7,
    Interface = 8,
    Module = 9,
    Property = 10,
    Unit = 11,
    Value = 12,
    Enum = 13,
    Keyword = 14,
    Snippet = 15,
    Color = 16,
    File = 17,
    Reference = 18,
};

pub const CompletionItem = struct {
    label: []const u8,
    kind: ?CompletionItemKind = null,
    detail: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
};

pub const MarkupKind = enum {
    plaintext,
    markdown,

    pub fn toString(self: MarkupKind) []const u8 {
        return switch (self) {
            .plaintext => "plaintext",
            .markdown => "markdown",
        };
    }
};

pub const MarkupContent = struct {
    kind: MarkupKind,
    value: []const u8,
};

pub const Hover = struct {
    contents: MarkupContent,
    range: ?Range = null,
};
