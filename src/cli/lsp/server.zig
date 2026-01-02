// CANARY: LSP_SERVER_IMPLEMENTATION
// Main LSP server implementation for GQL/Geode
// Spec: specs/lsp/language-server-protocol/_specifications/lsp/3.17/specification.md

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const document = @import("document.zig");
const features = @import("features.zig");

const Transport = transport.Transport;
const DocumentStore = document.DocumentStore;

pub const ServerCapabilities = struct {
    textDocumentSync: i32 = 1, // Full sync
    hoverProvider: bool = true,
    completionProvider: ?struct {
        triggerCharacters: []const []const u8 = &[_][]const u8{ ".", ":", "$" },
    } = .{},
    definitionProvider: bool = true,
    referencesProvider: bool = false,
    documentFormattingProvider: bool = true,
    documentSymbolProvider: bool = false,
};

pub const Server = struct {
    allocator: Allocator,
    transport: Transport,
    documents: DocumentStore,
    initialized: bool = false,
    shutdown_requested: bool = false,

    pub fn init(allocator: Allocator) Server {
        return .{
            .allocator = allocator,
            .transport = Transport.init(allocator),
            .documents = DocumentStore.init(allocator),
        };
    }

    pub fn deinit(self: *Server) void {
        self.documents.deinit();
    }

    pub fn run(self: *Server) !void {
        self.transport.logMessage("INFO", "Geode LSP server starting...");

        while (!self.shutdown_requested) {
            const message_text = self.transport.readMessage() catch |err| {
                // EndOfStream means client disconnected gracefully
                if (err == error.EndOfStream) {
                    self.transport.logMessage("INFO", "Client disconnected");
                    break;
                }
                // ReadFailed means connection error
                if (err == error.ReadFailed) {
                    self.transport.logMessage("ERROR", "Connection lost");
                    break;
                }
                // Log other errors but don't spam
                if (std.fmt.allocPrint(self.allocator, "Read error: {}", .{err})) |error_msg| {
                    defer self.allocator.free(error_msg);
                    self.transport.logMessage("ERROR", error_msg);
                } else |_| {
                    self.transport.logMessage("ERROR", "Unknown read error");
                }
                continue;
            };
            defer self.allocator.free(message_text);

            self.handleMessage(message_text) catch |err| {
                self.transport.logMessage("ERROR", "Failed to handle message");
                const error_msg = std.fmt.allocPrint(self.allocator, "Error: {}", .{err}) catch continue;
                defer self.allocator.free(error_msg);
                self.transport.logMessage("ERROR", error_msg);
            };
        }

        self.transport.logMessage("INFO", "Geode LSP server shutting down");
    }

    fn handleMessage(self: *Server, message_text: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message_text, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const method = if (root.get("method")) |m| m.string else null;
        const id = root.get("id");

        if (method) |m| {
            if (id != null) {
                // Request
                try self.handleRequest(m, id.?, root.get("params"));
            } else {
                // Notification
                try self.handleNotification(m, root.get("params"));
            }
        }
    }

    fn handleRequest(self: *Server, method: []const u8, id: std.json.Value, params: ?std.json.Value) !void {
        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(id, params);
        } else if (std.mem.eql(u8, method, "shutdown")) {
            try self.handleShutdown(id);
        } else if (std.mem.eql(u8, method, "textDocument/hover")) {
            try self.handleHover(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/completion")) {
            try self.handleCompletion(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/definition")) {
            try self.handleDefinition(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
            try self.handleFormatting(id, params);
        } else {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.MethodNotFound), "Method not found");
        }
    }

    fn handleNotification(self: *Server, method: []const u8, params: ?std.json.Value) !void {
        if (std.mem.eql(u8, method, "initialized")) {
            self.initialized = true;
            self.transport.logMessage("INFO", "Client initialized");
        } else if (std.mem.eql(u8, method, "exit")) {
            self.shutdown_requested = true;
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(params);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(params);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.handleDidClose(params);
        }
    }

    fn handleInitialize(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        _ = params;

        const capabilities = ServerCapabilities{};

        var response = std.json.ObjectMap.init(self.allocator);
        defer response.deinit();

        try response.put("jsonrpc", .{ .string = "2.0" });
        try response.put("id", id);

        var result = std.json.ObjectMap.init(self.allocator);
        defer result.deinit();

        var caps = std.json.ObjectMap.init(self.allocator);
        defer caps.deinit();

        try caps.put("textDocumentSync", .{ .integer = capabilities.textDocumentSync });
        try caps.put("hoverProvider", .{ .bool = capabilities.hoverProvider });
        try caps.put("definitionProvider", .{ .bool = capabilities.definitionProvider });
        try caps.put("documentFormattingProvider", .{ .bool = capabilities.documentFormattingProvider });

        var completion = std.json.ObjectMap.init(self.allocator);
        defer completion.deinit();
        var triggers = std.json.Array.init(self.allocator);
        defer triggers.deinit();
        try triggers.append(.{ .string = "." });
        try triggers.append(.{ .string = ":" });
        try triggers.append(.{ .string = "$" });
        try completion.put("triggerCharacters", .{ .array = triggers });
        try caps.put("completionProvider", .{ .object = completion });

        try result.put("capabilities", .{ .object = caps });

        var server_info = std.json.ObjectMap.init(self.allocator);
        defer server_info.deinit();
        try server_info.put("name", .{ .string = "geode-lsp" });
        try server_info.put("version", .{ .string = "1.0.0" });
        try result.put("serverInfo", .{ .object = server_info });

        try response.put("result", .{ .object = result });

        try self.sendJsonValue(.{ .object = response });
    }

    fn handleShutdown(self: *Server, id: std.json.Value) !void {
        var response = std.json.ObjectMap.init(self.allocator);
        defer response.deinit();

        try response.put("jsonrpc", .{ .string = "2.0" });
        try response.put("id", id);
        try response.put("result", .null);

        try self.sendJsonValue(.{ .object = response });
    }

    fn handleDidOpen(self: *Server, params: ?std.json.Value) !void {
        if (params == null) return;

        const text_document = params.?.object.get("textDocument").?.object;
        const uri = text_document.get("uri").?.string;
        const text = text_document.get("text").?.string;
        const version = @as(i32, @intCast(text_document.get("version").?.integer));

        try self.documents.open(uri, text, version);

        // Send diagnostics
        try self.sendDiagnostics(uri);
    }

    fn handleDidChange(self: *Server, params: ?std.json.Value) !void {
        if (params == null) return;

        const text_document = params.?.object.get("textDocument").?.object;
        const uri = text_document.get("uri").?.string;
        const version = @as(i32, @intCast(text_document.get("version").?.integer));
        const changes = params.?.object.get("contentChanges").?.array;

        if (changes.items.len > 0) {
            const change = changes.items[0].object;
            const text = change.get("text").?.string;
            try self.documents.update(uri, text, version);

            // Send diagnostics
            try self.sendDiagnostics(uri);
        }
    }

    fn handleDidClose(self: *Server, params: ?std.json.Value) !void {
        if (params == null) return;

        const text_document = params.?.object.get("textDocument").?.object;
        const uri = text_document.get("uri").?.string;

        self.documents.close(uri);
    }

    fn handleHover(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        if (params == null) {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing params");
            return;
        }

        const text_document = params.?.object.get("textDocument").?.object;
        const uri = text_document.get("uri").?.string;
        const position = params.?.object.get("position").?.object;
        const line = @as(u32, @intCast(position.get("line").?.integer));
        const character = @as(u32, @intCast(position.get("character").?.integer));

        const doc = self.documents.get(uri) orelse {
            try self.sendResult(id, .null);
            return;
        };

        const hover = try features.provideHover(self.allocator, doc, line, character);
        defer if (hover) |h| self.allocator.free(h.contents.value);

        if (hover) |h| {
            var response = std.json.ObjectMap.init(self.allocator);
            defer response.deinit();

            try response.put("jsonrpc", .{ .string = "2.0" });
            try response.put("id", id);

            var result = std.json.ObjectMap.init(self.allocator);
            defer result.deinit();

            var contents = std.json.ObjectMap.init(self.allocator);
            defer contents.deinit();
            try contents.put("kind", .{ .string = h.contents.kind.toString() });
            try contents.put("value", .{ .string = h.contents.value });

            try result.put("contents", .{ .object = contents });
            try response.put("result", .{ .object = result });

            try self.sendJsonValue(.{ .object = response });
        } else {
            try self.sendResult(id, .null);
        }
    }

    fn handleCompletion(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        if (params == null) {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing params");
            return;
        }

        const text_document = params.?.object.get("textDocument").?.object;
        const uri = text_document.get("uri").?.string;
        const position = params.?.object.get("position").?.object;
        const line = @as(u32, @intCast(position.get("line").?.integer));
        const character = @as(u32, @intCast(position.get("character").?.integer));

        const doc = self.documents.get(uri) orelse {
            try self.sendResult(id, .{ .array = std.json.Array.init(self.allocator) });
            return;
        };

        const items = try features.provideCompletion(self.allocator, doc, line, character);
        defer {
            for (items) |item| {
                if (item.insertText) |text| {
                    if (!std.mem.eql(u8, text, item.label)) {
                        self.allocator.free(text);
                    }
                }
            }
            self.allocator.free(items);
        }

        var array = std.json.Array.init(self.allocator);
        defer array.deinit();

        for (items) |item| {
            var obj = std.json.ObjectMap.init(self.allocator);
            defer obj.deinit();

            try obj.put("label", .{ .string = item.label });
            if (item.kind) |k| {
                try obj.put("kind", .{ .integer = @intFromEnum(k) });
            }
            if (item.detail) |d| {
                try obj.put("detail", .{ .string = d });
            }
            if (item.insertText) |t| {
                try obj.put("insertText", .{ .string = t });
            }

            try array.append(.{ .object = obj });
        }

        var response = std.json.ObjectMap.init(self.allocator);
        defer response.deinit();

        try response.put("jsonrpc", .{ .string = "2.0" });
        try response.put("id", id);
        try response.put("result", .{ .array = array });

        try self.sendJsonValue(.{ .object = response });
    }

    fn handleDefinition(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        _ = params;
        // Not implemented yet
        try self.sendResult(id, .null);
    }

    fn handleFormatting(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse {
            try self.sendResult(id, .null);
            return;
        };

        const text_doc = p.object.get("textDocument") orelse {
            try self.sendResult(id, .null);
            return;
        };

        const uri = text_doc.object.get("uri") orelse {
            try self.sendResult(id, .null);
            return;
        };

        const doc = self.documents.get(uri.string) orelse {
            try self.sendResult(id, .null);
            return;
        };

        const formatted = features.provideFormatting(self.allocator, doc) catch {
            try self.sendResult(id, .null);
            return;
        };

        if (formatted) |new_text| {
            defer self.allocator.free(new_text);

            // Count lines in original document for range
            var line_count: u32 = 0;
            var last_line_len: u32 = 0;
            for (doc.text, 0..) |c, idx| {
                if (c == '\n') {
                    line_count += 1;
                    last_line_len = 0;
                } else {
                    last_line_len += 1;
                }
                _ = idx;
            }

            // Build JSON response with TextEdit array
            var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 1024);
            defer buffer.deinit(self.allocator);

            try buffer.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");

            // Serialize the id
            switch (id) {
                .integer => |i| {
                    var num_buf: [32]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch "0";
                    try buffer.appendSlice(self.allocator, num_str);
                },
                .string => |s| {
                    try buffer.append(self.allocator, '"');
                    try buffer.appendSlice(self.allocator, s);
                    try buffer.append(self.allocator, '"');
                },
                else => try buffer.appendSlice(self.allocator, "null"),
            }

            try buffer.appendSlice(self.allocator, ",\"result\":[{\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":");

            // Add end line
            var line_buf: [32]u8 = undefined;
            const line_str = std.fmt.bufPrint(&line_buf, "{d}", .{line_count}) catch "0";
            try buffer.appendSlice(self.allocator, line_str);

            try buffer.appendSlice(self.allocator, ",\"character\":");

            // Add end character
            var char_buf: [32]u8 = undefined;
            const char_str = std.fmt.bufPrint(&char_buf, "{d}", .{last_line_len}) catch "0";
            try buffer.appendSlice(self.allocator, char_str);

            try buffer.appendSlice(self.allocator, "}},\"newText\":\"");

            // Escape the new text for JSON
            for (new_text) |c| {
                switch (c) {
                    '\n' => try buffer.appendSlice(self.allocator, "\\n"),
                    '\r' => try buffer.appendSlice(self.allocator, "\\r"),
                    '\t' => try buffer.appendSlice(self.allocator, "\\t"),
                    '"' => try buffer.appendSlice(self.allocator, "\\\""),
                    '\\' => try buffer.appendSlice(self.allocator, "\\\\"),
                    else => try buffer.append(self.allocator, c),
                }
            }

            try buffer.appendSlice(self.allocator, "\"}]}");

            try self.transport.writeMessage(buffer.items);
        } else {
            try self.sendResult(id, .null);
        }
    }

    fn sendDiagnostics(self: *Server, uri: []const u8) !void {
        const doc = self.documents.get(uri) orelse return;

        const diagnostics = try features.provideDiagnostics(self.allocator, doc);
        defer {
            for (diagnostics) |diag| {
                self.allocator.free(diag.message);
            }
            self.allocator.free(diagnostics);
        }

        // Build JSON manually as a string to avoid object lifetime issues
        var buffer = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch return error.OutOfMemory;
        defer buffer.deinit(self.allocator);

        try buffer.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
        try buffer.appendSlice(self.allocator, uri);
        try buffer.appendSlice(self.allocator, "\",\"diagnostics\":[");

        const alloc = self.allocator;
        var first = true;
        for (diagnostics) |diag| {
            if (!first) try buffer.append(alloc, ',');
            first = false;

            try buffer.appendSlice(alloc, "{\"range\":{\"start\":{\"line\":");
            try std.fmt.format(buffer.writer(alloc), "{d}", .{diag.range.start.line});
            try buffer.appendSlice(alloc, ",\"character\":");
            try std.fmt.format(buffer.writer(alloc), "{d}", .{diag.range.start.character});
            try buffer.appendSlice(alloc, "},\"end\":{\"line\":");
            try std.fmt.format(buffer.writer(alloc), "{d}", .{diag.range.end.line});
            try buffer.appendSlice(alloc, ",\"character\":");
            try std.fmt.format(buffer.writer(alloc), "{d}", .{diag.range.end.character});
            try buffer.appendSlice(alloc, "}}");

            if (diag.severity) |sev| {
                try buffer.appendSlice(alloc, ",\"severity\":");
                try std.fmt.format(buffer.writer(alloc), "{d}", .{@intFromEnum(sev)});
            }

            try buffer.appendSlice(alloc, ",\"message\":\"");
            // Escape the message for JSON
            for (diag.message) |c| {
                switch (c) {
                    '"' => try buffer.appendSlice(alloc, "\\\""),
                    '\\' => try buffer.appendSlice(alloc, "\\\\"),
                    '\n' => try buffer.appendSlice(alloc, "\\n"),
                    '\r' => try buffer.appendSlice(alloc, "\\r"),
                    '\t' => try buffer.appendSlice(alloc, "\\t"),
                    else => try buffer.append(alloc, c),
                }
            }
            try buffer.appendSlice(alloc, "\"");

            if (diag.source) |src| {
                try buffer.appendSlice(alloc, ",\"source\":\"");
                try buffer.appendSlice(alloc, src);
                try buffer.appendSlice(alloc, "\"");
            }

            try buffer.append(alloc, '}');
        }

        try buffer.appendSlice(alloc, "]}}");

        try self.transport.writeMessage(buffer.items);
    }

    fn sendResult(self: *Server, id: std.json.Value, result: std.json.Value) !void {
        var response = std.json.ObjectMap.init(self.allocator);
        defer response.deinit();

        try response.put("jsonrpc", .{ .string = "2.0" });
        try response.put("id", id);
        try response.put("result", result);

        try self.sendJsonValue(.{ .object = response });
    }

    fn sendError(self: *Server, id: std.json.Value, code: i32, message: []const u8) !void {
        var response = std.json.ObjectMap.init(self.allocator);
        defer response.deinit();

        try response.put("jsonrpc", .{ .string = "2.0" });
        try response.put("id", id);

        var err = std.json.ObjectMap.init(self.allocator);
        defer err.deinit();
        try err.put("code", .{ .integer = code });
        try err.put("message", .{ .string = message });

        try response.put("error", .{ .object = err });

        try self.sendJsonValue(.{ .object = response });
    }

    fn sendJsonValue(self: *Server, value: std.json.Value) !void {
        const json_str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(json_str);
        try self.transport.writeMessage(json_str);
    }
};
