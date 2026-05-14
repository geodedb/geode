// Module implementation
// Main LSP server implementation for GQL/Geode
// Spec: specs/lsp/language-server-protocol/_specifications/lsp/3.17/specification.md

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const document = @import("document.zig");
const features = @import("features.zig");
const json_helpers = @import("json_helpers.zig");
const auth_mod = @import("auth.zig");
const schema_provider_mod = @import("schema_provider.zig");

// Task 12: reach the unified authentication provider and the execution
// context type via the `geode` named module. We deliberately do not pull
// these via relative `../../security/authn.zig` / `../../execution.zig`
// imports because src/cli/lsp/ is reached from two roots (geode_exe and
// the lsp_tests build module) and Zig 0.16 would treat the relative
// import as a fresh module root in the test build — triggering the
// "file exists in modules X and X0" diamond. Both build roots expose the
// `geode` named module (build.zig:580 + build.zig:2204), so the same
// import resolves in both contexts.
const geode = @import("geode");
const execution = geode.execution;
const graph_store = geode.graph_store;

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

/// F-01: per-document debounce state for didChange diagnostics.
const DebounceState = struct {
    last_change_at_ns: i128,
    pending: bool,
};

/// F-01: portable monotonic-ish nanos (Zig 0.16 removed
/// `std.time.nanoTimestamp`). Returns ns since some unspecified
/// reference; only deltas are meaningful.
fn lspMonoNanos() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else if (comptime @import("builtin").os.tag == .windows) {
        // Coarse fallback for Windows hosts running tests; production
        // builds on Windows already use a different code path.
        return @as(i128, @intCast(@as(u64, @intCast(@max(ts.sec, 0))))) * std.time.ns_per_s;
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

pub const Server = struct {
    allocator: Allocator,
    transport: Transport,
    documents: DocumentStore,
    initialized: bool = false,
    shutdown_requested: bool = false,
    formatting_options: features.FormattingOptions = .{},
    /// F-01: per-document debounce state. Keyed by URI; values track
    /// the timestamp of the last didChange and whether a diagnostic
    /// flush is still pending.
    debounce_state: std.StringHashMap(DebounceState) = undefined,
    debounce_state_initialized: bool = false,
    /// F-01: incremented every time sendDiagnostics actually transmits
    /// (or would transmit) a diagnostic frame. Test-only field; does
    /// not affect production behavior.
    diagnostics_send_count_for_test: usize = 0,

    // -------- Task 12: per-session auth + schema binding --------
    /// Verifier vtable the LSP server invokes during `initialize` to
    /// validate the client's bearer / session token. `null` is the
    /// stdio-LSP default until Task 28 plumbs the
    /// `authn.AuthProvider`-backed verifier through `geode serve`. When
    /// null the only way to pass the auth gate is `allow_unauth =
    /// true` (the `--no-auth` mode landing in Task 13). The vtable
    /// shape — `auth_mod.Verifier` — exists so the LSP server does not
    /// have to import `security/authn.zig` directly; see lib.zig's
    /// authn note for why that file is currently un-importable on
    /// Zig 0.16.
    verifier: ?auth_mod.Verifier = null,

    /// When true, `initialize` is allowed to bind a session without a
    /// verified auth token (used by `geode lsp --no-auth` in Task 13).
    /// In Task 12 this is wired to a `error.MissingToken` short-circuit
    /// because the `--no-auth` binding logic itself lands in Task 13.
    allow_unauth: bool = false,

    /// Verified-on-`initialize` session state. `null` until the client
    /// completes the auth handshake; non-null + `verified=true` is
    /// what the auth gate looks at. Owned by the Server — released in
    /// `deinit`.
    auth: ?auth_mod.AuthState = null,

    /// Lazy-fetch schema cache scoped to the verified session. Allocated
    /// on the heap so DDL notifier hooks can reference a stable address
    /// (`registerInvalidation` stores `*SchemaProvider`). The
    /// `unregisterInvalidation` call in `deinit` MUST run before the
    /// SchemaProvider is destroyed or the next DDL would dispatch on a
    /// dangling pointer.
    schema: ?*schema_provider_mod.SchemaProvider = null,

    /// Per-session execution context built from the verified
    /// AuthState. Task 12 wires the catalog pointer + role + tenant
    /// onto it; Tasks 17+ start consuming it from inside completion /
    /// hover / diagnostics handlers.
    exec_context: ?execution.ExecutionContext = null,

    /// F-01: minimum interval between successive diagnostic flushes
    /// for the same document. Real LSP clients debounce around
    /// 100 ms; 80 ms gives plenty of headroom.
    pub const DEBOUNCE_NS: i128 = 80 * std.time.ns_per_ms;

    /// Default constructor: stdio LSP path with no live verifier.
    /// Equivalent to `initWithAuth(allocator, null, false)`. Kept as a
    /// distinct entry point so the pre-Task-12 test suite continues
    /// to compile unchanged — Task 12 only adds new optional state.
    pub fn init(allocator: Allocator) !Server {
        return initWithAuth(allocator, null, false);
    }

    /// Task 12 constructor: plumb an optional `Verifier` and a
    /// `--no-auth` switch. `verifier == null` + `allow_unauth ==
    /// false` is fail-closed — every `initialize` will reject any
    /// non-empty token (and every empty one) with MissingToken /
    /// InvalidToken. Stdio callers pass `(null, false)` for now;
    /// Task 28's TCP/embedded path will pass a verifier whose ctx is
    /// the running `authn.AuthProvider` instance.
    pub fn initWithAuth(
        allocator: Allocator,
        verifier: ?auth_mod.Verifier,
        allow_unauth: bool,
    ) !Server {
        return .{
            .allocator = allocator,
            .transport = try Transport.init(allocator),
            .documents = DocumentStore.init(allocator),
            .debounce_state = std.StringHashMap(DebounceState).init(allocator),
            .debounce_state_initialized = true,
            .verifier = verifier,
            .allow_unauth = allow_unauth,
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.debounce_state_initialized) {
            self.debounce_state.deinit();
        }
        // Tear down session state in reverse order of allocation so the
        // DDL notifier never dispatches on a freed SchemaProvider.
        if (self.schema) |sp| {
            sp.unregisterInvalidation();
            sp.deinit();
            self.allocator.destroy(sp);
            self.schema = null;
        }
        if (self.auth) |a| {
            a.deinit(self.allocator);
            self.auth = null;
        }
        // exec_context is a value type holding only borrowed pointers
        // (catalog is a process-global singleton; user/tenant/role come
        // from AuthState which was freed above). No allocations to
        // release here.
        self.exec_context = null;
        self.documents.deinit();
    }

    /// F-01: record a didChange event for `uri`. Sets the pending flag
    /// and updates the last-change timestamp. Does NOT eagerly fire
    /// diagnostics — the run loop's flushPendingDiagnostics() decides
    /// when to actually send.
    pub fn markDocumentDirty(self: *Server, uri: []const u8) void {
        const now = lspMonoNanos();
        // Use the document's own URI slice as the key — it's stable
        // for the document's lifetime.
        const key = if (self.documents.get(uri)) |doc| doc.uri else uri;
        self.debounce_state.put(key, .{ .last_change_at_ns = now, .pending = true }) catch {};
    }

    /// F-01: returns true if `uri` has unflushed diagnostics pending.
    pub fn isDirty(self: *Server, uri: []const u8) bool {
        const st = self.debounce_state.get(uri) orelse return false;
        return st.pending;
    }

    /// F-01: timestamp (ns since epoch, monotonic-ish) of the last
    /// didChange for `uri`, or null if no change has been recorded.
    pub fn lastChangeNanos(self: *Server, uri: []const u8) ?i128 {
        const st = self.debounce_state.get(uri) orelse return null;
        return st.last_change_at_ns;
    }

    /// F-01: walk every dirty document and emit diagnostics for those
    /// whose debounce window (DEBOUNCE_NS) has elapsed since the last
    /// didChange. `now_ns` is supplied by callers (tests, run-loop) to
    /// keep the function deterministic.
    pub fn flushPendingDiagnostics(self: *Server, now_ns: i128) !void {
        var it = self.debounce_state.iterator();
        while (it.next()) |entry| {
            const st = entry.value_ptr.*;
            if (!st.pending) continue;
            if (now_ns - st.last_change_at_ns < DEBOUNCE_NS) continue;
            // Window elapsed — flush.
            self.sendDiagnostics(entry.key_ptr.*) catch {};
            entry.value_ptr.pending = false;
        }
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

            // F-01: after handling each message, flush any pending
            // diagnostics whose debounce window has elapsed. Naturally
            // coalesces bursts of didChange into one diagnostic frame.
            self.flushPendingDiagnostics(lspMonoNanos()) catch {};
        }

        self.transport.logMessage("INFO", "Geode LSP server shutting down");
    }

    /// LSP-SEC-004: extracted shape for textDocument-position requests.
    pub const TextDocumentPosition = struct {
        uri: []const u8,
        line: u32,
        character: u32,
    };

    /// LSP-SEC-004: shared safe extractor for the common
    /// `{textDocument: {uri}, position: {line, character}}` request shape
    /// used by hover/completion/definition/references/signatureHelp.
    fn extractTextDocumentPosition(self: *Server, params_value: std.json.Value) json_helpers.JsonError!TextDocumentPosition {
        _ = self;
        const text_document = try json_helpers.getObject(params_value, "textDocument");
        const uri = try json_helpers.getString(text_document, "uri");
        const position = try json_helpers.getObject(params_value, "position");
        const line_i64 = try json_helpers.getInteger(position, "line");
        const char_i64 = try json_helpers.getInteger(position, "character");
        return TextDocumentPosition{
            .uri = uri,
            .line = try json_helpers.castU32(line_i64),
            .character = try json_helpers.castU32(char_i64),
        };
    }

    /// LSP-SEC-004: shared safe extractor for textDocument-only requests.
    fn extractTextDocumentUri(self: *Server, params_value: std.json.Value) json_helpers.JsonError![]const u8 {
        _ = self;
        const text_document = try json_helpers.getObject(params_value, "textDocument");
        return try json_helpers.getString(text_document, "uri");
    }

    pub fn handleMessage(self: *Server, message_text: []const u8) !void {
        // LSP-SEC-003: reject deeply nested or oversized payloads BEFORE
        // entering the recursive parser. checkJsonDepth is O(n), allocation-free,
        // and aware of in-string brace characters.
        json_helpers.checkJsonDepth(message_text) catch |err| {
            self.transport.logMessage("WARN", "Rejected JSON payload (depth/size cap)");
            return err;
        };

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

    /// Task 12: the four methods that are allowed before the LSP session
    /// has authenticated. Everything else is rejected with JSON-RPC
    /// -32002 ("not authenticated"). Notification-level `initialized`
    /// and `exit` are handled in `handleNotification`; this list covers
    /// only the request side.
    fn isAuthExemptMethod(method: []const u8) bool {
        return std.mem.eql(u8, method, "initialize") or
            std.mem.eql(u8, method, "shutdown");
    }

    /// Test helper: returns true when a request bearing `method` would
    /// pass the auth gate. Kept public + side-effect-free so tests can
    /// assert the gate's behavior without driving the JSON-RPC
    /// transport (the in-stdio Transport is not test-friendly until
    /// Task 25 lands the tagged-union refactor).
    pub fn isMethodAllowed(self: *const Server, method: []const u8) bool {
        if (isAuthExemptMethod(method)) return true;
        const a = self.auth orelse return false;
        return a.verified;
    }

    fn handleRequest(self: *Server, method: []const u8, id: std.json.Value, params: ?std.json.Value) !void {
        // Task 12 auth gate: every non-init/shutdown request must
        // come from a session whose AuthState.verify succeeded during
        // the `initialize` handshake. We respond with JSON-RPC -32002
        // ("ServerNotInitialized") because LSP clients already know
        // how to drop a session on that code. The literal -32002 is
        // the LSP spec value (Microsoft LSP 3.17 §5.1.3); the local
        // `protocol.ErrorCode` enum only covers the JSON-RPC subset.
        if (!isAuthExemptMethod(method)) {
            const a = self.auth;
            if (a == null or !a.?.verified) {
                try self.sendError(id, -32002, "not authenticated");
                return;
            }
        }

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

    /// Task 12: bind the per-session AuthState + SchemaProvider +
    /// ExecutionContext on a successful `initialize`. Returns
    /// `error.AuthInitFailed` (mapped to a JSON-RPC -32002 response by
    /// `handleInitialize`) when the client did not provide a valid
    /// `initializationOptions.geode.authToken`. The `--no-auth` mode
    /// (Task 13's `bindUnauthSession`) is selected upstream in
    /// `handleInitialize`; this function always requires a verified
    /// token.
    fn bindSession(self: *Server, params: ?std.json.Value) auth_mod.AuthError!void {
        const p = params orelse return auth_mod.AuthError.MissingToken;
        if (p != .object) return auth_mod.AuthError.BadFormat;
        const init_opts = p.object.get("initializationOptions") orelse
            return auth_mod.AuthError.MissingToken;

        var state = try auth_mod.AuthState.fromInitializeOptions(self.allocator, init_opts);
        state.verify(self.allocator, self.verifier) catch |e| {
            state.deinit(self.allocator);
            return e;
        };

        // Ownership transfers to publishVerifiedState — it deinits on
        // its own error path. On success the state lives on as
        // Server.auth.
        return self.publishVerifiedState(state);
    }

    /// Task 13: `--no-auth` stdio path. Synthesize a local-admin
    /// `AuthState` from `$USER` (fallback to "local") without invoking
    /// any verifier and bind the same per-session state the token path
    /// builds. Terminal users already have filesystem access to the
    /// data dir, so granting `.Admin` is no privilege escalation
    /// versus running `geode shell` directly. This MUST NEVER be
    /// reachable from a network-listening transport — Task 28's TCP
    /// listener forces `allow_unauth = false` regardless of CLI flag.
    fn bindUnauthSession(self: *Server) auth_mod.AuthError!void {
        if (!self.allow_unauth) return auth_mod.AuthError.MissingToken;

        // Pull the username from $USER for log/audit clarity; fall back
        // to "local" if the environment is empty (common in containers).
        // Zig 0.16 removed std.posix.getenv; std.c.getenv is the non-
        // allocating equivalent (same call shape src/fle_integration.zig
        // already uses for GEODE_CURRENT_ROLE).
        const env_user: []const u8 = blk: {
            const ptr = std.c.getenv("USER") orelse break :blk "local";
            const slice = std.mem.span(ptr);
            if (slice.len == 0) break :blk "local";
            break :blk slice;
        };
        const default_graph = "default";

        // Build the synthetic AuthState. We allocate piecewise and
        // release earlier allocations explicitly on a later failure
        // so that, by the time we hand the assembled `state` to
        // publishVerifiedState, that callee owns deinit from then on
        // — no errdefer here would double-free what state.deinit
        // already releases.
        const token = self.allocator.dupe(u8, "") catch return auth_mod.AuthError.OutOfMemory;
        const user_dup = self.allocator.dupe(u8, env_user) catch {
            self.allocator.free(token);
            return auth_mod.AuthError.OutOfMemory;
        };
        const graph_dup = self.allocator.dupe(u8, default_graph) catch {
            self.allocator.free(token);
            self.allocator.free(user_dup);
            return auth_mod.AuthError.OutOfMemory;
        };

        const state = auth_mod.AuthState{
            .token = token,
            .user = user_dup,
            .role = .Admin,
            .verified = true,
            .graph = graph_dup,
            .tenant_id = null,
        };

        return self.publishVerifiedState(state);
    }

    /// Build the SchemaProvider + ExecutionContext from an already-
    /// verified `AuthState` and publish them onto `self`. Shared by
    /// `bindSession` (token path) and `bindUnauthSession` (Task 13
    /// `--no-auth` path) so both ends of the auth dispatch wire up an
    /// identical session shape. Takes ownership of `state` on success;
    /// on any failure path it releases `state` before returning.
    fn publishVerifiedState(self: *Server, state: auth_mod.AuthState) auth_mod.AuthError!void {
        var st = state;
        errdefer st.deinit(self.allocator);

        // Allocate the SchemaProvider on the heap so the DDL notifier
        // can hold a stable pointer (see registerInvalidation contract
        // in src/cli/lsp/schema_provider.zig:170-176).
        const sp = try self.allocator.create(schema_provider_mod.SchemaProvider);
        errdefer self.allocator.destroy(sp);
        const store_ptr = graph_store.getWritableGlobalStore(self.allocator);
        sp.* = schema_provider_mod.SchemaProvider.init(self.allocator, store_ptr, .{
            .user = st.user,
            .tenant_id = st.tenant_id,
            .role = st.role,
            .graph_name = st.graph orelse "default",
        });
        errdefer sp.deinit();
        try sp.registerInvalidation();

        // Build the per-session ExecutionContext. We pull the catalog
        // off the process-global singleton (same path the QUIC handler
        // takes at src/server/quic_connection_handler.zig:3242). The
        // `catalog` field is mandatory — there is no default — so we
        // must succeed at this allocation before publishing any state
        // back onto Server. `ensureCatalogInstance` returns the global
        // error set; we collapse non-OOM failures (e.g. filesystem
        // failures resolving the data dir) to `OutOfMemory` because
        // the AuthError surface does not differentiate them and the
        // LSP client would treat the -32002 response identically.
        const catalog = execution.ensureCatalogInstance(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return auth_mod.AuthError.OutOfMemory,
            else => return auth_mod.AuthError.OutOfMemory,
        };

        self.auth = st;
        self.schema = sp;
        self.exec_context = .{
            .catalog = catalog,
            .user = st.user,
            .role = st.role,
            .tenant_id = st.tenant_id,
        };
    }

    /// Emit a JSON-RPC -32002 ("ServerNotInitialized") error response
    /// for `initialize`. We map every `AuthError` to -32002 because the
    /// LSP spec only defines that one code for "this session is not
    /// usable until you re-handshake" — clients distinguish the cause
    /// by reading the `message` string.
    fn respondInitializeError(self: *Server, id: std.json.Value, err: auth_mod.AuthError) !void {
        const msg: []const u8 = switch (err) {
            auth_mod.AuthError.MissingToken => "missing auth token",
            auth_mod.AuthError.InvalidToken => "invalid auth token",
            auth_mod.AuthError.ExpiredToken => "expired auth token",
            auth_mod.AuthError.BadFormat => "malformed initializationOptions.geode block",
            auth_mod.AuthError.OutOfMemory => "out of memory",
        };
        try self.sendError(id, -32002, msg);
    }

    fn handleInitialize(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        // Task 12/13: bind the session before doing anything else with
        // the request. A failed bind short-circuits with -32002 and
        // leaves Server.auth/schema/exec_context unset so the gate in
        // handleRequest keeps every subsequent method rejected.
        //
        // Task 13: when started with `--no-auth` we synthesize a local
        // admin AuthState instead of parsing/verifying a client token
        // — used by terminal LSP clients (neovim, helix, VS Code over
        // stdio) where the caller is already a local filesystem user.
        const bind_result = if (self.allow_unauth)
            self.bindUnauthSession()
        else
            self.bindSession(params);
        bind_result catch |e| {
            return self.respondInitializeError(id, e);
        };

        // Parse initialization options for formatting settings.
        // LSP-SEC-004: silently ignore malformed entries rather than
        // panicking. The init handshake must succeed for the client to
        // recover; logged-and-defaulted is the right policy here.
        if (params) |p| if (p == .object) {
            if (p.object.get("initializationOptions")) |init_opts| if (init_opts == .object) {
                if (init_opts.object.get("format")) |format_opts| if (format_opts == .object) {
                    if (format_opts.object.get("foldPropertyMaps")) |fold| {
                        if (fold == .bool) self.formatting_options.fold_property_maps = fold.bool;
                    }
                    if (format_opts.object.get("indentSize")) |indent| {
                        if (indent == .integer) {
                            if (json_helpers.castU32(indent.integer)) |v| {
                                self.formatting_options.indent_size = v;
                            } else |_| {}
                        }
                    }
                    if (format_opts.object.get("maxLineLength")) |max_len| {
                        if (max_len == .integer) {
                            if (json_helpers.castU32(max_len.integer)) |v| {
                                self.formatting_options.max_line_length = v;
                            } else |_| {}
                        }
                    }
                    if (format_opts.object.get("minPropertiesToFold")) |min_props| {
                        if (min_props == .integer) {
                            if (json_helpers.castU32(min_props.integer)) |v| {
                                self.formatting_options.min_properties_to_fold = v;
                            } else |_| {}
                        }
                    }
                };
            };
        };

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
        const p = params orelse return;
        // LSP-SEC-004: structured access, returns InvalidParams on bad shape.
        const text_document = try json_helpers.getObject(p, "textDocument");
        const uri = try json_helpers.getString(text_document, "uri");
        const text = try json_helpers.getString(text_document, "text");
        const version = try json_helpers.castI32(try json_helpers.getInteger(text_document, "version"));

        try self.documents.open(uri, text, version);

        // Send diagnostics
        try self.sendDiagnostics(uri);
    }

    fn handleDidChange(self: *Server, params: ?std.json.Value) !void {
        const p = params orelse return;
        // LSP-SEC-004: structured access, returns InvalidParams on bad shape.
        const text_document = try json_helpers.getObject(p, "textDocument");
        const uri = try json_helpers.getString(text_document, "uri");
        const version = try json_helpers.castI32(try json_helpers.getInteger(text_document, "version"));

        if (p != .object) return json_helpers.JsonError.InvalidParams;
        const changes_v = p.object.get("contentChanges") orelse return json_helpers.JsonError.InvalidParams;
        if (changes_v != .array) return json_helpers.JsonError.InvalidParams;
        const changes = changes_v.array;

        if (changes.items.len > 0) {
            const first = changes.items[0];
            if (first != .object) return json_helpers.JsonError.InvalidParams;
            const text = try json_helpers.getString(first.object, "text");
            try self.documents.update(uri, text, version);

            // F-01: defer diagnostic emission to the run-loop debounce
            // flush instead of firing eagerly on every keystroke.
            self.markDocumentDirty(uri);
        }
    }

    fn handleDidClose(self: *Server, params: ?std.json.Value) !void {
        const p = params orelse return;
        // LSP-SEC-004: structured access, returns InvalidParams on bad shape.
        const text_document = try json_helpers.getObject(p, "textDocument");
        const uri = try json_helpers.getString(text_document, "uri");

        self.documents.close(uri);
    }

    fn handleHover(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing params");
            return;
        };
        const pos = self.extractTextDocumentPosition(p) catch {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing or malformed params");
            return;
        };
        const uri = pos.uri;
        const line = pos.line;
        const character = pos.character;

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
        const p = params orelse {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing params");
            return;
        };
        const pos = self.extractTextDocumentPosition(p) catch {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing or malformed params");
            return;
        };
        const uri = pos.uri;
        const line = pos.line;
        const character = pos.character;

        const doc = self.documents.get(uri) orelse {
            try self.sendResult(id, .{ .array = std.json.Array.init(self.allocator) });
            return;
        };

        const items = try features.provideCompletion(self.allocator, doc, line, character, self.schema);
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

    /// GAP-0056: pure helper — extracted for unit testability.
    /// Returns the goto-definition Location for `(uri, line, character)`,
    /// or null if not found / unknown / keyword.
    /// CANARY: REQ=REQ-LSP-GOTODEF-001; FEATURE="GoToDefinitionWired"; ASPECT=VariableLookup; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06
    pub fn computeDefinition(self: *Server, uri: []const u8, line: u32, character: u32) !?protocol.Location {
        const doc = self.documents.get(uri) orelse return null;
        return try features.provideDefinition(self.allocator, doc, line, character);
    }

    fn handleDefinition(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        // GAP-0056: wire textDocument/definition through to features.provideDefinition.
        const p = params orelse {
            try self.sendResult(id, .null);
            return;
        };
        const pos = self.extractTextDocumentPosition(p) catch {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing or malformed params");
            return;
        };

        const location = self.computeDefinition(pos.uri, pos.line, pos.character) catch {
            try self.sendResult(id, .null);
            return;
        };

        if (location) |loc| {
            // Build JSON-RPC response with the Location object.
            var response = std.json.ObjectMap{};
            try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
            try response.put(self.allocator, "id", id);

            var result = std.json.ObjectMap{};
            try result.put(self.allocator, "uri", .{ .string = loc.uri });

            var range = std.json.ObjectMap{};
            var start_pos = std.json.ObjectMap{};
            try start_pos.put(self.allocator, "line", .{ .integer = loc.range.start.line });
            try start_pos.put(self.allocator, "character", .{ .integer = loc.range.start.character });
            var end_pos = std.json.ObjectMap{};
            try end_pos.put(self.allocator, "line", .{ .integer = loc.range.end.line });
            try end_pos.put(self.allocator, "character", .{ .integer = loc.range.end.character });
            try range.put(self.allocator, "start", .{ .object = start_pos });
            try range.put(self.allocator, "end", .{ .object = end_pos });
            try result.put(self.allocator, "range", .{ .object = range });

            try response.put(self.allocator, "result", .{ .object = result });
            try self.sendJsonValue(.{ .object = response });
        } else {
            try self.sendResult(id, .null);
        }
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
        const p = params orelse {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing params");
            return;
        };
        const uri = self.extractTextDocumentUri(p) catch {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing or malformed params");
            return;
        };

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
        const params_v = params orelse {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing params");
            return;
        };
        const pos = self.extractTextDocumentPosition(params_v) catch {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing or malformed params");
            return;
        };
        const uri = pos.uri;
        const line = pos.line;
        const character = pos.character;

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
        const p = params orelse {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing params");
            return;
        };
        const pos = self.extractTextDocumentPosition(p) catch {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing or malformed params");
            return;
        };
        const uri = pos.uri;
        const line = pos.line;
        const character = pos.character;

        // Check for includeDeclaration in context (optional, defaults to true)
        var include_decl = true;
        if (p == .object) {
            if (p.object.get("context")) |ctx| {
                if (ctx == .object) {
                    if (ctx.object.get("includeDeclaration")) |inc| {
                        if (inc == .bool) include_decl = inc.bool;
                    }
                }
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
        const p = params orelse {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing params");
            return;
        };
        const uri = self.extractTextDocumentUri(p) catch {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing or malformed params");
            return;
        };

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
        // F-01: count every send for test introspection.
        self.diagnostics_send_count_for_test += 1;
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
