// CANARY: LSP_PROTOCOL_TESTS
// Test suite for LSP protocol types and structures

const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");

test "RequestId - integer variant" {
    const id = protocol.RequestId{ .integer = 42 };
    try testing.expect(id == .integer);
    try testing.expectEqual(@as(i64, 42), id.integer);
}

test "RequestId - string variant" {
    const id = protocol.RequestId{ .string = "test-123" };
    try testing.expect(id == .string);
    try testing.expectEqualStrings("test-123", id.string);
}

test "Position - basic construction" {
    const pos = protocol.Position{
        .line = 10,
        .character = 5,
    };
    try testing.expectEqual(@as(u32, 10), pos.line);
    try testing.expectEqual(@as(u32, 5), pos.character);
}

test "Range - basic construction" {
    const range = protocol.Range{
        .start = .{ .line = 0, .character = 0 },
        .end = .{ .line = 0, .character = 10 },
    };
    try testing.expectEqual(@as(u32, 0), range.start.line);
    try testing.expectEqual(@as(u32, 0), range.start.character);
    try testing.expectEqual(@as(u32, 0), range.end.line);
    try testing.expectEqual(@as(u32, 10), range.end.character);
}

test "Location - URI and range" {
    const loc = protocol.Location{
        .uri = "file:///test.gql",
        .range = .{
            .start = .{ .line = 5, .character = 10 },
            .end = .{ .line = 5, .character = 20 },
        },
    };
    try testing.expectEqualStrings("file:///test.gql", loc.uri);
    try testing.expectEqual(@as(u32, 5), loc.range.start.line);
    try testing.expectEqual(@as(u32, 10), loc.range.start.character);
}

test "Diagnostic - error severity" {
    const diag = protocol.Diagnostic{
        .range = .{
            .start = .{ .line = 0, .character = 0 },
            .end = .{ .line = 0, .character = 5 },
        },
        .severity = .Error,
        .source = "geode",
        .message = "Syntax error",
    };
    try testing.expectEqual(protocol.DiagnosticSeverity.Error, diag.severity.?);
    try testing.expectEqualStrings("geode", diag.source.?);
    try testing.expectEqualStrings("Syntax error", diag.message);
}

test "Diagnostic - warning severity" {
    const diag = protocol.Diagnostic{
        .range = .{
            .start = .{ .line = 1, .character = 0 },
            .end = .{ .line = 1, .character = 10 },
        },
        .severity = .Warning,
        .message = "Deprecated syntax",
    };
    try testing.expectEqual(protocol.DiagnosticSeverity.Warning, diag.severity.?);
    try testing.expectEqualStrings("Deprecated syntax", diag.message);
}

test "DiagnosticSeverity - enum values" {
    try testing.expectEqual(@as(i32, 1), @intFromEnum(protocol.DiagnosticSeverity.Error));
    try testing.expectEqual(@as(i32, 2), @intFromEnum(protocol.DiagnosticSeverity.Warning));
    try testing.expectEqual(@as(i32, 3), @intFromEnum(protocol.DiagnosticSeverity.Information));
    try testing.expectEqual(@as(i32, 4), @intFromEnum(protocol.DiagnosticSeverity.Hint));
}

test "CompletionItemKind - enum values" {
    try testing.expectEqual(@as(i32, 1), @intFromEnum(protocol.CompletionItemKind.Text));
    try testing.expectEqual(@as(i32, 3), @intFromEnum(protocol.CompletionItemKind.Function));
    try testing.expectEqual(@as(i32, 7), @intFromEnum(protocol.CompletionItemKind.Class));
    try testing.expectEqual(@as(i32, 14), @intFromEnum(protocol.CompletionItemKind.Keyword));
}

test "CompletionItem - keyword" {
    const item = protocol.CompletionItem{
        .label = "MATCH",
        .kind = .Keyword,
        .detail = "GQL Keyword",
        .insertText = "MATCH",
    };
    try testing.expectEqualStrings("MATCH", item.label);
    try testing.expectEqual(protocol.CompletionItemKind.Keyword, item.kind.?);
    try testing.expectEqualStrings("GQL Keyword", item.detail.?);
    try testing.expectEqualStrings("MATCH", item.insertText.?);
}

test "CompletionItem - function with snippet" {
    const item = protocol.CompletionItem{
        .label = "count",
        .kind = .Function,
        .detail = "GQL Function",
        .insertText = "count()",
    };
    try testing.expectEqualStrings("count", item.label);
    try testing.expectEqual(protocol.CompletionItemKind.Function, item.kind.?);
    try testing.expectEqualStrings("count()", item.insertText.?);
}

test "MarkupKind - toString" {
    try testing.expectEqualStrings("plaintext", protocol.MarkupKind.plaintext.toString());
    try testing.expectEqualStrings("markdown", protocol.MarkupKind.markdown.toString());
}

test "MarkupContent - plaintext" {
    const content = protocol.MarkupContent{
        .kind = .plaintext,
        .value = "Simple text",
    };
    try testing.expectEqual(protocol.MarkupKind.plaintext, content.kind);
    try testing.expectEqualStrings("Simple text", content.value);
}

test "MarkupContent - markdown" {
    const content = protocol.MarkupContent{
        .kind = .markdown,
        .value = "**Bold** text",
    };
    try testing.expectEqual(protocol.MarkupKind.markdown, content.kind);
    try testing.expectEqualStrings("**Bold** text", content.value);
}

test "Hover - with markdown content" {
    const hover = protocol.Hover{
        .contents = .{
            .kind = .markdown,
            .value = "# Header\n\nSome documentation",
        },
    };
    try testing.expectEqual(protocol.MarkupKind.markdown, hover.contents.kind);
    try testing.expectEqualStrings("# Header\n\nSome documentation", hover.contents.value);
}

test "ErrorCode - all values" {
    try testing.expectEqual(@as(i32, -32700), @intFromEnum(protocol.ErrorCode.ParseError));
    try testing.expectEqual(@as(i32, -32600), @intFromEnum(protocol.ErrorCode.InvalidRequest));
    try testing.expectEqual(@as(i32, -32601), @intFromEnum(protocol.ErrorCode.MethodNotFound));
    try testing.expectEqual(@as(i32, -32602), @intFromEnum(protocol.ErrorCode.InvalidParams));
    try testing.expectEqual(@as(i32, -32603), @intFromEnum(protocol.ErrorCode.InternalError));
}

test "Request - basic structure" {
    const req = protocol.Request{
        .jsonrpc = protocol.JsonRpcVersion,
        .id = .{ .integer = 1 },
        .method = "initialize",
        .params = null,
    };
    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expectEqual(@as(i64, 1), req.id.integer);
    try testing.expectEqualStrings("initialize", req.method);
    try testing.expect(req.params == null);
}

test "Response - success" {
    const resp = protocol.Response{
        .jsonrpc = protocol.JsonRpcVersion,
        .id = .{ .integer = 1 },
        .result = null,
        .@"error" = null,
    };
    try testing.expectEqualStrings("2.0", resp.jsonrpc);
    try testing.expectEqual(@as(i64, 1), resp.id.integer);
    try testing.expect(resp.result == null);
    try testing.expect(resp.@"error" == null);
}

test "Notification - basic structure" {
    const notif = protocol.Notification{
        .jsonrpc = protocol.JsonRpcVersion,
        .method = "initialized",
        .params = null,
    };
    try testing.expectEqualStrings("2.0", notif.jsonrpc);
    try testing.expectEqualStrings("initialized", notif.method);
    try testing.expect(notif.params == null);
}

test "ResponseError - construction" {
    const err = protocol.ResponseError{
        .code = @intFromEnum(protocol.ErrorCode.InvalidParams),
        .message = "Missing required parameter",
        .data = null,
    };
    try testing.expectEqual(@as(i32, -32602), err.code);
    try testing.expectEqualStrings("Missing required parameter", err.message);
    try testing.expect(err.data == null);
}
