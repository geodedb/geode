// Module implementation
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
    referencesProvider: bool = true,
    documentFormattingProvider: bool = true,
    documentSymbolProvider: bool = true,
    signatureHelpProvider: ?struct {
        triggerCharacters: []const []const u8 = &[_][]const u8{ "(", "," },
    } = .{},
    semanticTokensProvider: bool = true,
};

pub const Server = struct {
    allocator: Allocator,
    transport: Transport,
    documents: DocumentStore,
    initialized: bool = false,
    shutdown_requested: bool = false,
    formatting_options: features.FormattingOptions = .{},

    pub fn init(allocator: Allocator) !Server {
        return .{
            .allocator = allocator,
            .transport = try Transport.init(allocator),
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
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            try self.handleDocumentSymbol(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/signatureHelp")) {
            try self.handleSignatureHelp(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/references")) {
            try self.handleReferences(id, params);
        } else if (std.mem.eql(u8, method, "textDocument/semanticTokens/full")) {
            try self.handleSemanticTokensFull(id, params);
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
        // Parse initialization options for formatting settings
        if (params) |p| {
            if (p.object.get("initializationOptions")) |init_opts| {
                if (init_opts.object.get("format")) |format_opts| {
                    if (format_opts.object.get("foldPropertyMaps")) |fold| {
                        self.formatting_options.fold_property_maps = fold.bool;
                    }
                    if (format_opts.object.get("indentSize")) |indent| {
                        self.formatting_options.indent_size = @intCast(indent.integer);
                    }
                    if (format_opts.object.get("maxLineLength")) |max_len| {
                        self.formatting_options.max_line_length = @intCast(max_len.integer);
                    }
                    if (format_opts.object.get("minPropertiesToFold")) |min_props| {
                        self.formatting_options.min_properties_to_fold = @intCast(min_props.integer);
                    }
                }
            }
        }

        const capabilities = ServerCapabilities{};

        var response = std.json.ObjectMap{};
        defer response.deinit(self.allocator);

        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);

        var result = std.json.ObjectMap{};
        defer result.deinit(self.allocator);

        var caps = std.json.ObjectMap{};
        defer caps.deinit(self.allocator);

        try caps.put(self.allocator, "textDocumentSync", .{ .integer = capabilities.textDocumentSync });
        try caps.put(self.allocator, "hoverProvider", .{ .bool = capabilities.hoverProvider });
        try caps.put(self.allocator, "definitionProvider", .{ .bool = capabilities.definitionProvider });
        try caps.put(self.allocator, "documentFormattingProvider", .{ .bool = capabilities.documentFormattingProvider });
        try caps.put(self.allocator, "documentSymbolProvider", .{ .bool = capabilities.documentSymbolProvider });
        try caps.put(self.allocator, "referencesProvider", .{ .bool = capabilities.referencesProvider });

        var completion = std.json.ObjectMap{};
        defer completion.deinit(self.allocator);
        var triggers = std.json.Array.init(self.allocator);
        defer triggers.deinit();
        try triggers.append(.{ .string = "." });
        try triggers.append(.{ .string = ":" });
        try triggers.append(.{ .string = "$" });
        try completion.put(self.allocator, "triggerCharacters", .{ .array = triggers });
        try caps.put(self.allocator, "completionProvider", .{ .object = completion });

        // Signature help provider
        var sig_help = std.json.ObjectMap{};
        defer sig_help.deinit(self.allocator);
        var sig_triggers = std.json.Array.init(self.allocator);
        defer sig_triggers.deinit();
        try sig_triggers.append(.{ .string = "(" });
        try sig_triggers.append(.{ .string = "," });
        try sig_help.put(self.allocator, "triggerCharacters", .{ .array = sig_triggers });
        try caps.put(self.allocator, "signatureHelpProvider", .{ .object = sig_help });

        // Semantic tokens provider
        var sem_tokens = std.json.ObjectMap{};
        defer sem_tokens.deinit(self.allocator);
        try sem_tokens.put(self.allocator, "full", .{ .bool = true });

        var legend = std.json.ObjectMap{};
        defer legend.deinit(self.allocator);

        var token_types = std.json.Array.init(self.allocator);
        defer token_types.deinit();
        for (protocol.SemanticTokenTypes.types) |t| {
            try token_types.append(.{ .string = t });
        }
        try legend.put(self.allocator, "tokenTypes", .{ .array = token_types });

        var token_modifiers = std.json.Array.init(self.allocator);
        defer token_modifiers.deinit();
        for (protocol.SemanticTokenTypes.modifiers) |m| {
            try token_modifiers.append(.{ .string = m });
        }
        try legend.put(self.allocator, "tokenModifiers", .{ .array = token_modifiers });

        try sem_tokens.put(self.allocator, "legend", .{ .object = legend });
        try caps.put(self.allocator, "semanticTokensProvider", .{ .object = sem_tokens });

        try result.put(self.allocator, "capabilities", .{ .object = caps });

        var server_info = std.json.ObjectMap{};
        defer server_info.deinit(self.allocator);
        try server_info.put(self.allocator, "name", .{ .string = "geode-lsp" });
        try server_info.put(self.allocator, "version", .{ .string = "1.0.0" });
        try result.put(self.allocator, "serverInfo", .{ .object = server_info });

        try response.put(self.allocator, "result", .{ .object = result });

        try self.sendJsonValue(.{ .object = response });
    }

    fn handleShutdown(self: *Server, id: std.json.Value) !void {
        var response = std.json.ObjectMap{};
        defer response.deinit(self.allocator);

        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);
        try response.put(self.allocator, "result", .null);

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
            // Build response - don't use defer deinit as objects are nested
            var response = std.json.ObjectMap{};
            try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
            try response.put(self.allocator, "id", id);

            var result = std.json.ObjectMap{};
            var contents = std.json.ObjectMap{};
            try contents.put(self.allocator, "kind", .{ .string = h.contents.kind.toString() });
            try contents.put(self.allocator, "value", .{ .string = h.contents.value });

            try result.put(self.allocator, "contents", .{ .object = contents });
            try response.put(self.allocator, "result", .{ .object = result });

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
        // Note: Don't defer deinit - objects are owned by the response

        for (items) |item| {
            // Build completion item - don't use defer as objects are stored in array
            var obj = std.json.ObjectMap{};

            try obj.put(self.allocator, "label", .{ .string = item.label });
            if (item.kind) |k| {
                try obj.put(self.allocator, "kind", .{ .integer = @intFromEnum(k) });
            }
            if (item.detail) |d| {
                try obj.put(self.allocator, "detail", .{ .string = d });
            }
            if (item.insertText) |t| {
                try obj.put(self.allocator, "insertText", .{ .string = t });
            }

            try array.append(.{ .object = obj });
        }

        var response = std.json.ObjectMap{};
        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);
        try response.put(self.allocator, "result", .{ .array = array });

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

        const formatted = features.provideFormattingWithOptions(self.allocator, doc, self.formatting_options) catch {
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

    fn handleDocumentSymbol(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        if (params == null) {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing params");
            return;
        }

        const text_document = params.?.object.get("textDocument").?.object;
        const uri = text_document.get("uri").?.string;

        const doc = self.documents.get(uri) orelse {
            try self.sendResult(id, .{ .array = std.json.Array.init(self.allocator) });
            return;
        };

        const symbols = features.provideDocumentSymbols(self.allocator, doc) catch {
            try self.sendResult(id, .{ .array = std.json.Array.init(self.allocator) });
            return;
        };
        defer self.allocator.free(symbols);

        var array = std.json.Array.init(self.allocator);
        // Note: Don't defer deinit here - the objects are owned by the response

        for (symbols) |sym| {
            // Build symbol object - don't use defer as objects are stored in array
            var obj = std.json.ObjectMap{};

            try obj.put(self.allocator, "name", .{ .string = sym.name });
            try obj.put(self.allocator, "kind", .{ .integer = @intFromEnum(sym.kind) });

            if (sym.detail) |d| {
                try obj.put(self.allocator, "detail", .{ .string = d });
            }

            // Build range object
            var range = std.json.ObjectMap{};
            var start_pos = std.json.ObjectMap{};
            try start_pos.put(self.allocator, "line", .{ .integer = sym.range.start.line });
            try start_pos.put(self.allocator, "character", .{ .integer = sym.range.start.character });
            var end_pos = std.json.ObjectMap{};
            try end_pos.put(self.allocator, "line", .{ .integer = sym.range.end.line });
            try end_pos.put(self.allocator, "character", .{ .integer = sym.range.end.character });
            try range.put(self.allocator, "start", .{ .object = start_pos });
            try range.put(self.allocator, "end", .{ .object = end_pos });
            try obj.put(self.allocator, "range", .{ .object = range });

            // Build selection range object
            var sel_range = std.json.ObjectMap{};
            var sel_start = std.json.ObjectMap{};
            try sel_start.put(self.allocator, "line", .{ .integer = sym.selectionRange.start.line });
            try sel_start.put(self.allocator, "character", .{ .integer = sym.selectionRange.start.character });
            var sel_end = std.json.ObjectMap{};
            try sel_end.put(self.allocator, "line", .{ .integer = sym.selectionRange.end.line });
            try sel_end.put(self.allocator, "character", .{ .integer = sym.selectionRange.end.character });
            try sel_range.put(self.allocator, "start", .{ .object = sel_start });
            try sel_range.put(self.allocator, "end", .{ .object = sel_end });
            try obj.put(self.allocator, "selectionRange", .{ .object = sel_range });

            try array.append(.{ .object = obj });
        }

        var response = std.json.ObjectMap{};
        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);
        try response.put(self.allocator, "result", .{ .array = array });
        try self.sendJsonValue(.{ .object = response });
    }

    fn handleSignatureHelp(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
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

        const sig_help = features.provideSignatureHelp(self.allocator, doc, line, character) catch {
            try self.sendResult(id, .null);
            return;
        };

        if (sig_help) |sh| {
            defer {
                for (sh.signatures) |sig| {
                    self.allocator.free(sig.label);
                    if (sig.parameters) |ps| {
                        for (ps) |p| {
                            self.allocator.free(p.label);
                        }
                        self.allocator.free(ps);
                    }
                }
                self.allocator.free(sh.signatures);
            }

            // Build response - don't use defer deinit as objects are nested in the response
            var response = std.json.ObjectMap{};
            try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
            try response.put(self.allocator, "id", id);

            var result = std.json.ObjectMap{};
            var sigs = std.json.Array.init(self.allocator);

            for (sh.signatures) |sig| {
                var sig_obj = std.json.ObjectMap{};
                try sig_obj.put(self.allocator, "label", .{ .string = sig.label });

                if (sig.documentation) |doc_content| {
                    var doc_obj = std.json.ObjectMap{};
                    try doc_obj.put(self.allocator, "kind", .{ .string = doc_content.kind.toString() });
                    try doc_obj.put(self.allocator, "value", .{ .string = doc_content.value });
                    try sig_obj.put(self.allocator, "documentation", .{ .object = doc_obj });
                }

                if (sig.parameters) |ps| {
                    var params_arr = std.json.Array.init(self.allocator);

                    for (ps) |p| {
                        var param_obj = std.json.ObjectMap{};
                        try param_obj.put(self.allocator, "label", .{ .string = p.label });
                        try params_arr.append(.{ .object = param_obj });
                    }
                    try sig_obj.put(self.allocator, "parameters", .{ .array = params_arr });
                }

                if (sig.activeParameter) |ap| {
                    try sig_obj.put(self.allocator, "activeParameter", .{ .integer = ap });
                }

                try sigs.append(.{ .object = sig_obj });
            }

            try result.put(self.allocator, "signatures", .{ .array = sigs });
            if (sh.activeSignature) |as| {
                try result.put(self.allocator, "activeSignature", .{ .integer = as });
            }
            if (sh.activeParameter) |ap| {
                try result.put(self.allocator, "activeParameter", .{ .integer = ap });
            }

            try response.put(self.allocator, "result", .{ .object = result });
            try self.sendJsonValue(.{ .object = response });
        } else {
            try self.sendResult(id, .null);
        }
    }

    fn handleReferences(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        if (params == null) {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing params");
            return;
        }

        const text_document = params.?.object.get("textDocument").?.object;
        const uri = text_document.get("uri").?.string;
        const position = params.?.object.get("position").?.object;
        const line = @as(u32, @intCast(position.get("line").?.integer));
        const character = @as(u32, @intCast(position.get("character").?.integer));

        // Check for includeDeclaration in context
        var include_decl = true;
        if (params.?.object.get("context")) |ctx| {
            if (ctx.object.get("includeDeclaration")) |inc| {
                include_decl = inc.bool;
            }
        }

        const doc = self.documents.get(uri) orelse {
            try self.sendResult(id, .{ .array = std.json.Array.init(self.allocator) });
            return;
        };

        const locations = features.provideReferences(self.allocator, doc, line, character, include_decl) catch {
            try self.sendResult(id, .{ .array = std.json.Array.init(self.allocator) });
            return;
        };
        defer self.allocator.free(locations);

        var array = std.json.Array.init(self.allocator);
        // Note: Don't defer deinit - objects are owned by the response

        for (locations) |loc| {
            // Build location object - don't use defer as objects are stored in array
            var obj = std.json.ObjectMap{};

            try obj.put(self.allocator, "uri", .{ .string = loc.uri });

            var range = std.json.ObjectMap{};
            var start_pos = std.json.ObjectMap{};
            try start_pos.put(self.allocator, "line", .{ .integer = loc.range.start.line });
            try start_pos.put(self.allocator, "character", .{ .integer = loc.range.start.character });
            var end_pos = std.json.ObjectMap{};
            try end_pos.put(self.allocator, "line", .{ .integer = loc.range.end.line });
            try end_pos.put(self.allocator, "character", .{ .integer = loc.range.end.character });
            try range.put(self.allocator, "start", .{ .object = start_pos });
            try range.put(self.allocator, "end", .{ .object = end_pos });
            try obj.put(self.allocator, "range", .{ .object = range });

            try array.append(.{ .object = obj });
        }

        var response = std.json.ObjectMap{};
        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);
        try response.put(self.allocator, "result", .{ .array = array });
        try self.sendJsonValue(.{ .object = response });
    }

    fn handleSemanticTokensFull(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        if (params == null) {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing params");
            return;
        }

        const text_document = params.?.object.get("textDocument").?.object;
        const uri = text_document.get("uri").?.string;

        const doc = self.documents.get(uri) orelse {
            try self.sendResult(id, .null);
            return;
        };

        const sem_tokens = features.provideSemanticTokensFull(self.allocator, doc) catch {
            try self.sendResult(id, .null);
            return;
        };
        defer self.allocator.free(sem_tokens.data);

        // Build response - don't use defer deinit as objects are nested
        var response = std.json.ObjectMap{};
        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);

        var result = std.json.ObjectMap{};
        var data_arr = std.json.Array.init(self.allocator);

        for (sem_tokens.data) |val| {
            try data_arr.append(.{ .integer = val });
        }

        try result.put(self.allocator, "data", .{ .array = data_arr });
        try response.put(self.allocator, "result", .{ .object = result });
        try self.sendJsonValue(.{ .object = response });
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
            {
                var _tmp_buf: [64]u8 = undefined;
                const _tmp_str = std.fmt.bufPrint(&_tmp_buf, "{d}", .{diag.range.start.line}) catch return error.OutOfMemory;
                try buffer.appendSlice(alloc, _tmp_str);
            }
            try buffer.appendSlice(alloc, ",\"character\":");
            {
                var _tmp_buf: [64]u8 = undefined;
                const _tmp_str = std.fmt.bufPrint(&_tmp_buf, "{d}", .{diag.range.start.character}) catch return error.OutOfMemory;
                try buffer.appendSlice(alloc, _tmp_str);
            }
            try buffer.appendSlice(alloc, "},\"end\":{\"line\":");
            {
                var _tmp_buf: [64]u8 = undefined;
                const _tmp_str = std.fmt.bufPrint(&_tmp_buf, "{d}", .{diag.range.end.line}) catch return error.OutOfMemory;
                try buffer.appendSlice(alloc, _tmp_str);
            }
            try buffer.appendSlice(alloc, ",\"character\":");
            {
                var _tmp_buf: [64]u8 = undefined;
                const _tmp_str = std.fmt.bufPrint(&_tmp_buf, "{d}", .{diag.range.end.character}) catch return error.OutOfMemory;
                try buffer.appendSlice(alloc, _tmp_str);
            }
            try buffer.appendSlice(alloc, "}}");

            if (diag.severity) |sev| {
                try buffer.appendSlice(alloc, ",\"severity\":");
                {
                var _tmp_buf: [64]u8 = undefined;
                const _tmp_str = std.fmt.bufPrint(&_tmp_buf, "{d}", .{@intFromEnum(sev)}) catch return error.OutOfMemory;
                try buffer.appendSlice(alloc, _tmp_str);
            }
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
        var response = std.json.ObjectMap{};
        defer response.deinit(self.allocator);

        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);
        try response.put(self.allocator, "result", result);

        try self.sendJsonValue(.{ .object = response });
    }

    fn sendError(self: *Server, id: std.json.Value, code: i32, message: []const u8) !void {
        var response = std.json.ObjectMap{};
        defer response.deinit(self.allocator);

        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);

        var err = std.json.ObjectMap{};
        defer err.deinit(self.allocator);
        try err.put(self.allocator, "code", .{ .integer = code });
        try err.put(self.allocator, "message", .{ .string = message });

        try response.put(self.allocator, "error", .{ .object = err });

        try self.sendJsonValue(.{ .object = response });
    }

    fn sendJsonValue(self: *Server, value: std.json.Value) !void {
        const json_str = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(json_str);
        try self.transport.writeMessage(json_str);
    }
};
