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

/// LSP-F-02/#770: per-document AST cache. `pub` so the out-of-tree
/// regression (tests/test_lsp_ast_cache.zig, which roots an `lsp_server`
/// named module at this file) can reach LspAstCache / DocParse / Document
/// without rooting a second module at ast_cache.zig (Zig 0.16 forbids one
/// file living in two modules of a compilation).
pub const ast_cache = @import("ast_cache.zig");

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

// ---------------------------------------------------------------------------
// GAP-0885b hardening helpers (LSP-SEC-005 / LSP-SEC-008)
// ---------------------------------------------------------------------------

/// LSP-SEC-005: RFC-3986 percent-encode a document URI before it is embedded
/// in an outgoing `textDocument/publishDiagnostics` envelope.
///
/// Policy: unreserved bytes (ALPHA / DIGIT / `-._~`) and the gen-delim /
/// sub-delim bytes that legitimately appear in a document URI
/// (`:/?[]@!$&'()*+,;=`) pass through unchanged. `%` passes through so an
/// already-encoded URI round-trips byte-identical (we never double-encode a
/// client-supplied `%20`). Everything else — space, `#`, `"`, `\`,
/// control bytes, and non-ASCII (>= 0x80) — is emitted as `%XX` (uppercase
/// hex, per RFC 3986 §2.1). Because every pass-through byte is printable
/// ASCII excluding `"` and `\`, the result is also always safe to splice
/// into the manually-built JSON string literal in `sendDiagnostics`.
pub fn percentEncodeUri(allocator: Allocator, uri: []const u8) error{OutOfMemory}![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, uri.len);
    errdefer out.deinit(allocator);
    for (uri) |b| {
        if (isUriSafeByte(b)) {
            try out.append(allocator, b);
        } else {
            const hex = "0123456789ABCDEF";
            try out.appendSlice(allocator, &[3]u8{ '%', hex[b >> 4], hex[b & 0x0F] });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn isUriSafeByte(b: u8) bool {
    return switch (b) {
        'A'...'Z', 'a'...'z', '0'...'9' => true,
        // RFC 3986 unreserved marks.
        '-', '.', '_', '~' => true,
        // gen-delims legal in a document URI. `#` is deliberately NOT here:
        // document URIs carry no fragment, and a raw `#` in a file path must
        // be escaped (LSP-SEC-005).
        ':', '/', '?', '[', ']', '@' => true,
        // sub-delims.
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=' => true,
        // Pass-through so already-encoded URIs are not double-encoded.
        '%' => true,
        else => false,
    };
}

/// LSP-SEC-008: error returned when a TCP bind configuration would expose an
/// unauthenticated LSP listener beyond the loopback interface.
pub const BindPolicyError = error{InsecureNonLoopbackBind};

/// LSP-SEC-008: single source of truth for the LSP TCP bind policy, called
/// by both bind sites (src/server/main.zig:runLspListener for the embedded
/// `geode serve` listener, src/cli/main.zig for standalone `geode lsp
/// --listen`).
///
///   - A loopback bind is always allowed (stdio has no bind at all).
///   - A non-loopback bind requires authenticated sessions: `allow_unauth`
///     (the `.none`-auth mode) is refused, and a missing verifier is refused
///     too — a fail-closed listener that can never authenticate anyone has
///     no business on a public interface (it would still expose the
///     pre-auth JSON-RPC parse surface).
///   - The legitimate authenticated `--lsp-bind-all` path (verifier present,
///     allow_unauth = false) stays legal — SEC-LSP-BIND-01's regression
///     concern is exactly that this combination must keep working while the
///     unauthenticated ones must never start working.
pub fn validateBindPolicy(policy: struct {
    loopback_only: bool,
    allow_unauth: bool,
    has_verifier: bool,
}) BindPolicyError!void {
    if (policy.loopback_only) return;
    if (policy.allow_unauth) return BindPolicyError.InsecureNonLoopbackBind;
    if (!policy.has_verifier) return BindPolicyError.InsecureNonLoopbackBind;
}

/// LSP-SEC-008: classify a bind host string as loopback. Thin alias to the
/// shared single-source implementation in `src/net_policy.zig` (exported via
/// the `geode` module) so this security control cannot drift from the MCP
/// side's `isLoopbackBind` (src/mcp/server.zig).
pub const isLoopbackHost = geode.net_policy.isLoopbackHost;

/// GAP-0832: re-export the transport module so out-of-tree test files
/// (tests/test_gap0832_lsp_decode.zig) that root the LSP server through the
/// `lsp_server` named build module can construct a `Transport.initNoop(..)`
/// without a relative `@import("transport.zig")` (which would register the
/// file in a second module and trip Zig 0.16's module-diamond check).
pub const transport_mod = transport;

/// GAP-0817: re-export the document module so out-of-tree tests
/// (tests/test_gap0817_lsp_position_encoding.zig) rooting the LSP server
/// through `lsp_server` can reach `document.PositionEncoding` /
/// `document.codeUnitsToByteColumn` without a relative `@import("document.zig")`
/// (which would register the file in a second module and trip Zig 0.16's
/// module-diamond check).
pub const document_mod = document;

/// GAP-0826: re-export the features + schema_provider modules so the
/// out-of-tree stress pack (tests/test_gap0826_lsp_stress.zig) rooting the
/// LSP server through `lsp_server` can drive `features.provideCompletion`
/// against a real, large `schema_provider.SchemaProvider` without a relative
/// `@import("features.zig")` / `@import("schema_provider.zig")` (which would
/// register those files in a second module and trip Zig 0.16's module-diamond
/// check — the exact reason transport_mod/document_mod are re-exported).
pub const features_mod = features;
pub const schema_provider_mod_export = schema_provider_mod;

/// GAP-0818 enforcement gate: re-export the auth module so the gate
/// regression pack (tests/test_gap0818_gate.zig) rooting the LSP server
/// through `lsp_server` can hand-build `AuthState` values without a
/// relative `@import("auth.zig")` (same module-diamond rationale as the
/// re-exports above).
pub const auth_mod_export = auth_mod;

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

/// GAP-0831: single source of truth for the LSP method-name string constants.
/// These name the methods; the *dispatch* and the *introspected handled-method
/// lists* are both derived from the comptime dispatch tables below
/// (`request_dispatch` / `notification_dispatch`), so a method that is no longer
/// dispatched is also no longer listed.
///
/// Lifecycle / control methods (`initialize`, `shutdown`) are dispatched but are
/// exempt from the capability mapping in the guard — they are mandated by the
/// LSP base protocol, not advertised via `ServerCapabilities`.
///
/// CANARY: REQ=REQ-LSP-CAP-001; FEATURE="CapabilityHandlerTruthfulness"; ASPECT=DispatchTable; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09
pub const Methods = struct {
    // Lifecycle / control requests (capability-exempt).
    pub const initialize = "initialize";
    pub const shutdown = "shutdown";
    // Feature requests (each MUST map to an advertised capability).
    pub const hover = "textDocument/hover";
    pub const completion = "textDocument/completion";
    pub const definition = "textDocument/definition";
    pub const formatting = "textDocument/formatting";
    pub const document_symbol = "textDocument/documentSymbol";
    pub const signature_help = "textDocument/signatureHelp";
    pub const references = "textDocument/references";
    pub const semantic_tokens_full = "textDocument/semanticTokens/full";

    // Notifications.
    pub const initialized = "initialized";
    pub const exit = "exit";
    pub const did_open = "textDocument/didOpen";
    pub const did_change = "textDocument/didChange";
    pub const did_close = "textDocument/didClose";
    // GAP-0816: cancellation control notification (LSP 3.17 §3.17.10). Under
    // the "$/" base-protocol namespace, so it is capability-exempt (see the
    // guard's `$/`-prefix exemption). Never produces a response itself.
    pub const cancel_request = "$/cancelRequest";
};

/// GAP-0831: uniform request-handler signature. Every request handler is wrapped
/// to this shape so the dispatch table can hold a single function-pointer type.
/// (`handleShutdown` ignores `params`; the wrapper below normalizes its arity.)
pub const RequestHandler = *const fn (*Server, std.json.Value, ?std.json.Value) anyerror!void;

/// GAP-0831: uniform notification-handler signature.
pub const NotificationHandler = *const fn (*Server, ?std.json.Value) anyerror!void;

/// GAP-0831: one row of the request dispatch table.
pub const RequestDispatchEntry = struct {
    method: []const u8,
    handler: RequestHandler,
};

/// GAP-0831: one row of the notification dispatch table.
pub const NotificationDispatchEntry = struct {
    method: []const u8,
    handler: NotificationHandler,
};

/// GAP-0831: THE request dispatch table — the single source of truth for both
/// (a) what `handleRequest` routes (via `inline for` over this table) and
/// (b) the introspected `handled_request_methods` list (derived at comptime
/// from this same table). Deleting a row here simultaneously removes the
/// dispatch branch AND shrinks the introspected list, so the capability
/// truthfulness guard trips (CapabilityWithoutHandler) the moment an advertised
/// feature loses its dispatch — closing the branch-removal blind spot the
/// reviewer proved against the old hand-maintained array.
pub const request_dispatch = [_]RequestDispatchEntry{
    .{ .method = Methods.initialize, .handler = Server.handleInitializeEntry },
    .{ .method = Methods.shutdown, .handler = Server.handleShutdownEntry },
    .{ .method = Methods.hover, .handler = Server.handleHover },
    .{ .method = Methods.completion, .handler = Server.handleCompletion },
    .{ .method = Methods.definition, .handler = Server.handleDefinition },
    .{ .method = Methods.formatting, .handler = Server.handleFormatting },
    .{ .method = Methods.document_symbol, .handler = Server.handleDocumentSymbol },
    .{ .method = Methods.signature_help, .handler = Server.handleSignatureHelp },
    .{ .method = Methods.references, .handler = Server.handleReferences },
    .{ .method = Methods.semantic_tokens_full, .handler = Server.handleSemanticTokensFull },
};

/// GAP-0831: THE notification dispatch table — the single source of truth for
/// both `handleNotification`'s `inline for` dispatch and the introspected
/// `handled_notification_methods` list (derived below). Notifications carry
/// varying intent but a uniform `(self, params)` signature, so the same
/// comptime-table pattern as requests applies; `initialized`/`exit` use thin
/// wrappers because they only mutate flags.
pub const notification_dispatch = [_]NotificationDispatchEntry{
    .{ .method = Methods.initialized, .handler = Server.handleInitializedEntry },
    .{ .method = Methods.exit, .handler = Server.handleExitEntry },
    .{ .method = Methods.did_open, .handler = Server.handleDidOpen },
    .{ .method = Methods.did_change, .handler = Server.handleDidChange },
    .{ .method = Methods.did_close, .handler = Server.handleDidClose },
    // GAP-0816: $/cancelRequest is a notification (no response of its own); it
    // records the target id into the cancel registry, which handleRequest then
    // consults at entry to short-circuit with -32800.
    .{ .method = Methods.cancel_request, .handler = Server.handleCancelRequestEntry },
};

/// GAP-0831: the exact set of request methods `handleRequest` dispatches,
/// DERIVED AT COMPTIME from `request_dispatch`. Iterated by the truthfulness
/// guard. Because both the dispatch and this list come from the same table, a
/// removed dispatch row removes the corresponding entry here too — there is no
/// hand-maintained array to drift out of sync.
pub const handled_request_methods = blk: {
    var arr: [request_dispatch.len][]const u8 = undefined;
    for (request_dispatch, 0..) |entry, i| arr[i] = entry.method;
    const frozen = arr;
    break :blk frozen;
};

/// GAP-0831: the exact set of notification methods `handleNotification`
/// dispatches, DERIVED AT COMPTIME from `notification_dispatch`. Notifications
/// are exempt from the capability mapping (they are driven by `textDocumentSync`
/// for the did* trio and by the base protocol for initialized/exit), but the
/// guard still asserts the did* notifications imply `textDocumentSync` is
/// advertised.
pub const handled_notification_methods = blk: {
    var arr: [notification_dispatch.len][]const u8 = undefined;
    for (notification_dispatch, 0..) |entry, i| arr[i] = entry.method;
    const frozen = arr;
    break :blk frozen;
};

/// GAP-0831: build the `capabilities` object EXACTLY as advertised in the
/// `initialize` result. `handleInitialize` calls this so there is one and only
/// one place that decides what Geode's LSP server claims to support; the
/// truthfulness guard (`tests/test_gap0831_lsp_capability_guard.zig`) also
/// calls it and walks the returned keys, making capability drift impossible.
///
/// Caller owns the returned map and MUST release it with
/// `deinitCapabilitiesObject` (recursive — the value contains nested
/// ObjectMaps and Arrays for completion/signatureHelp/semanticTokens).
///
/// CANARY: REQ=REQ-LSP-CAP-001; FEATURE="CapabilityHandlerTruthfulness"; ASPECT=AdvertisedCapabilities; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09
pub fn buildCapabilitiesObject(allocator: Allocator, position_encoding: document.PositionEncoding) !std.json.ObjectMap {
    const capabilities = ServerCapabilities{};
    var caps = std.json.ObjectMap{};
    errdefer deinitCapabilitiesObject(allocator, &caps);

    // GAP-0817: advertise the negotiated position encoding so the client knows
    // how Geode interprets `Position.character` for this session. This is a
    // data capability (a string), NOT a request-handler capability — there is
    // no method behind it, so the truthfulness guard treats it as exempt.
    try caps.put(allocator, "positionEncoding", .{ .string = position_encoding.toWire() });

    try caps.put(allocator, "textDocumentSync", .{ .integer = capabilities.textDocumentSync });
    try caps.put(allocator, "hoverProvider", .{ .bool = capabilities.hoverProvider });
    try caps.put(allocator, "definitionProvider", .{ .bool = capabilities.definitionProvider });
    try caps.put(allocator, "documentFormattingProvider", .{ .bool = capabilities.documentFormattingProvider });
    try caps.put(allocator, "documentSymbolProvider", .{ .bool = capabilities.documentSymbolProvider });
    try caps.put(allocator, "referencesProvider", .{ .bool = capabilities.referencesProvider });

    // GAP-0831 (Minor): each nested provider object is built by a helper that
    // owns its intermediate allocations via internal errdefers and returns a
    // fully-formed Value. The completed Value is transferred into `caps` with a
    // single `put`; after that the top-level `errdefer deinitCapabilitiesObject`
    // owns it. This removes the OOM-path leak windows where a half-built local
    // (e.g. `completion`/`triggers`) would be lost if a later `put`/`append`
    // failed — no local outlives its transfer, so no double-free either.
    const completion = try buildTriggerObject(allocator, &[_][]const u8{ ".", ":", "$" });
    try caps.put(allocator, "completionProvider", completion);

    const sig_help = try buildTriggerObject(allocator, &[_][]const u8{ "(", "," });
    try caps.put(allocator, "signatureHelpProvider", sig_help);

    const sem_tokens = try buildSemanticTokensObject(allocator);
    try caps.put(allocator, "semanticTokensProvider", sem_tokens);

    return caps;
}

/// GAP-0831 (Minor): build a JSON string array from `strings`, freeing the
/// partial array if any append OOMs. The returned Value owns its backing store
/// until the caller transfers it into a parent via `put`.
fn buildStringArray(allocator: Allocator, strings: []const []const u8) !std.json.Value {
    var arr = std.json.Array.init(allocator);
    errdefer arr.deinit();
    for (strings) |s| try arr.append(.{ .string = s });
    return .{ .array = arr };
}

/// GAP-0831 (Minor): build a `{ "triggerCharacters": [...] }` provider object.
/// The array is built fully before being transferred into `obj`, so no local
/// outlives its ownership transfer (no leak on OOM, no double-free).
fn buildTriggerObject(allocator: Allocator, triggers: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap{};
    var obj_value = std.json.Value{ .object = obj };
    errdefer deinitJsonValue(allocator, &obj_value);

    const triggers_arr = try buildStringArray(allocator, triggers);
    try obj.put(allocator, "triggerCharacters", triggers_arr);
    obj_value = .{ .object = obj };
    return obj_value;
}

/// GAP-0831 (Minor): build the semanticTokens provider object
/// (`{ "full": true, "legend": { "tokenTypes": [...], "tokenModifiers": [...] } }`).
/// Each nested array is fully built (via `buildStringArray`) before transfer, so
/// the only error-path owner of a given allocation is the object it was already
/// transferred into — no leak, no double-free.
fn buildSemanticTokensObject(allocator: Allocator) !std.json.Value {
    var sem_tokens = std.json.ObjectMap{};
    var sem_value = std.json.Value{ .object = sem_tokens };
    errdefer deinitJsonValue(allocator, &sem_value);

    try sem_tokens.put(allocator, "full", .{ .bool = true });
    sem_value = .{ .object = sem_tokens };

    const legend = try buildSemanticTokensLegend(allocator);
    try sem_tokens.put(allocator, "legend", legend);
    sem_value = .{ .object = sem_tokens };
    return sem_value;
}

/// GAP-0831 (Minor): build the semanticTokens `legend` object. Helper isolates
/// the two arrays so each is fully built before transfer into the legend.
fn buildSemanticTokensLegend(allocator: Allocator) !std.json.Value {
    var legend = std.json.ObjectMap{};
    var legend_value = std.json.Value{ .object = legend };
    errdefer deinitJsonValue(allocator, &legend_value);

    const token_types = try buildStringArray(allocator, &protocol.SemanticTokenTypes.types);
    try legend.put(allocator, "tokenTypes", token_types);
    legend_value = .{ .object = legend };

    const token_modifiers = try buildStringArray(allocator, &protocol.SemanticTokenTypes.modifiers);
    try legend.put(allocator, "tokenModifiers", token_modifiers);
    legend_value = .{ .object = legend };
    return legend_value;
}

/// GAP-0831: recursively release a capabilities ObjectMap built by
/// `buildCapabilitiesObject`. Walks nested objects/arrays so the test (and
/// `handleInitialize`) leak nothing under the testing allocator.
pub fn deinitCapabilitiesObject(allocator: Allocator, caps: *std.json.ObjectMap) void {
    var it = caps.iterator();
    while (it.next()) |entry| {
        deinitJsonValue(allocator, entry.value_ptr);
    }
    caps.deinit(allocator);
}

fn deinitJsonValue(allocator: Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                deinitJsonValue(allocator, entry.value_ptr);
            }
            obj.deinit(allocator);
        },
        .array => |*arr| {
            for (arr.items) |*item| {
                deinitJsonValue(allocator, item);
            }
            arr.deinit();
        },
        else => {},
    }
}

/// F-01: per-document debounce state for didChange diagnostics.
const DebounceState = struct {
    last_change_at_ns: i128,
    pending: bool,
};

/// GAP-0816: bounded registry of request ids the client has asked to cancel via
/// the `$/cancelRequest` notification (LSP 3.17 §3.17.10). Geode's LSP server
/// processes messages strictly synchronously one-at-a-time, so a cancel can
/// never race an in-flight handler in-process. The spec-compliant, race-free
/// realization is therefore a registry: `$/cancelRequest` records the id, and
/// `handleRequest` consults the registry AT ENTRY — if the id is registered the
/// request is answered immediately with JSON-RPC error -32800 (RequestCancelled)
/// and the entry is consumed (cleared), so a later legitimate reuse of the same
/// id is unaffected.
///
/// The registry is a fixed-capacity ring: cancelling more ids than `capacity`
/// before any are consumed evicts the OLDEST pending cancellation (FIFO). This
/// bounds memory against a hostile client that spams `$/cancelRequest` for ids
/// it never sends — the worst case is a stale eviction, never unbounded growth.
/// Ids are normalized to a compact key (sign-tagged integer text, or the raw
/// string) so integer and string ids share one comparison path; structured ids
/// are not valid JSON-RPC ids (see `idOrNull`) and are never recorded.
///
/// CANARY: REQ=REQ-LSP-CANCEL-001; FEATURE="CancelRequestRegistry"; ASPECT=BoundedRing; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09
pub const CancelRegistry = struct {
    /// Fixed ring capacity. 64 is far above the realistic count of
    /// simultaneously-cancelled-but-not-yet-delivered request ids (the
    /// synchronous loop drains each request before the next arrives) while
    /// staying tiny. Eviction is FIFO once full.
    pub const capacity = 64;
    /// Max bytes we retain for any single normalized id key. JSON-RPC string
    /// ids are client-chosen; we cap the stored key so a pathological id can't
    /// bloat a slot. A longer id is truncated for storage AND lookup (both
    /// sides go through `normalizeId`), so the cap is self-consistent: it can
    /// only ever cause two ultra-long ids sharing a prefix to collide, which
    /// at worst cancels a request the client also asked to cancel.
    pub const max_key_len = 128;

    const Slot = struct {
        used: bool = false,
        len: usize = 0,
        buf: [max_key_len]u8 = undefined,

        fn key(self: *const Slot) []const u8 {
            return self.buf[0..self.len];
        }
    };

    slots: [capacity]Slot = [_]Slot{.{}} ** capacity,
    /// Next slot to overwrite when full (FIFO eviction cursor).
    next: usize = 0,

    /// Normalize a JSON-RPC id into a comparable byte key written into `out`.
    /// Returns the populated slice, or null when the id is not a valid /
    /// recordable id (structured ids were already rejected upstream, but we
    /// fail-closed here too). Integer ids are rendered as decimal text with a
    /// leading 'i'; string ids are stored verbatim with a leading 's' so an
    /// integer id `1` never aliases the string id `"1"`. Float/null ids are
    /// not used as cancellable request ids in practice but are handled for
    /// completeness (tag 'f'/'n').
    fn normalizeId(id: std.json.Value, out: *[max_key_len]u8) ?[]const u8 {
        switch (id) {
            .integer => |i| {
                const s = std.fmt.bufPrint(out, "i{d}", .{i}) catch return null;
                return s;
            },
            .string => |s| {
                out[0] = 's';
                const n = @min(s.len, max_key_len - 1);
                @memcpy(out[1 .. 1 + n], s[0..n]);
                return out[0 .. 1 + n];
            },
            .float => |f| {
                const s = std.fmt.bufPrint(out, "f{d}", .{f}) catch return null;
                return s;
            },
            .null => {
                out[0] = 'n';
                return out[0..1];
            },
            else => return null,
        }
    }

    /// Record an id as cancelled. Idempotent: re-registering an already-present
    /// id is a no-op (does not consume a second slot). FIFO-evicts the oldest
    /// entry when full.
    pub fn cancel(self: *CancelRegistry, id: std.json.Value) void {
        var keybuf: [max_key_len]u8 = undefined;
        const key = normalizeId(id, &keybuf) orelse return;

        // Idempotency: already registered?
        for (&self.slots) |*slot| {
            if (slot.used and std.mem.eql(u8, slot.key(), key)) return;
        }
        // Find a free slot first; else FIFO-evict at `next`.
        var target: ?*Slot = null;
        for (&self.slots) |*slot| {
            if (!slot.used) {
                target = slot;
                break;
            }
        }
        const slot = target orelse blk: {
            const s = &self.slots[self.next];
            self.next = (self.next + 1) % capacity;
            break :blk s;
        };
        slot.used = true;
        slot.len = key.len;
        @memcpy(slot.buf[0..key.len], key);
    }

    /// Consume a cancellation for `id`: returns true (and clears the entry) when
    /// the id was registered, false otherwise. "Consume" semantics mean a
    /// cancelled id triggers exactly one -32800 response; a subsequent request
    /// reusing the same id is served normally.
    pub fn consume(self: *CancelRegistry, id: std.json.Value) bool {
        var keybuf: [max_key_len]u8 = undefined;
        const key = normalizeId(id, &keybuf) orelse return false;
        for (&self.slots) |*slot| {
            if (slot.used and std.mem.eql(u8, slot.key(), key)) {
                slot.used = false;
                slot.len = 0;
                return true;
            }
        }
        return false;
    }

    /// GAP-0816 (poisoning fix): unconditionally clear any pending cancellation
    /// for `id` without reporting whether one existed. Used as the belt-and-
    /// braces clear-on-response: when a request is answered we drop any same-id
    /// cancel entry so a cancel that arrived after dispatch began (but is
    /// observed before the next same-id request) cannot poison the reused id.
    /// Distinct from `consume` only in that it has no return value and is a
    /// no-op when nothing is registered.
    pub fn clear(self: *CancelRegistry, id: std.json.Value) void {
        var keybuf: [max_key_len]u8 = undefined;
        const key = normalizeId(id, &keybuf) orelse return;
        for (&self.slots) |*slot| {
            if (slot.used and std.mem.eql(u8, slot.key(), key)) {
                slot.used = false;
                slot.len = 0;
                return;
            }
        }
    }
};

/// GAP-0816 (poisoning fix): bounded ring of request ids that have ALREADY been
/// answered. In a strictly-synchronous server a `$/cancelRequest` almost always
/// arrives AFTER its target request was fully processed and answered (the
/// common case — there is never an in-flight handler to interrupt). LSP 3.17
/// §3.17.10 says a cancel for an already-completed request is a no-op; the
/// server simply ignores it. Without tracking answered ids the cancel would be
/// recorded into `CancelRegistry` and then wrongly fire a `-32800` against the
/// NEXT request that reuses the id (id reuse is routine: editors recycle small
/// integer ids). This ring lets `handleCancelRequestEntry` recognize a
/// late/no-op cancel and SKIP recording it.
///
/// Same normalization (`CancelRegistry.normalizeId`) and the same fixed-capacity
/// FIFO discipline as `CancelRegistry`, so integer/string ids never alias and a
/// hostile client cannot grow it without bound. Eviction only widens the window
/// in which a late cancel for a long-ago id could slip through and (combined
/// with a reuse of that exact id) cost one spurious `-32800`; the clear-on-
/// response belt-and-braces in `CancelRegistry.clear` shrinks that further.
///
/// CANARY: REQ=REQ-LSP-CANCEL-001; FEATURE="CancelRequestRegistry"; ASPECT=AnsweredRing; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09
pub const AnsweredRing = struct {
    pub const capacity = CancelRegistry.capacity;
    pub const max_key_len = CancelRegistry.max_key_len;

    const Slot = struct {
        used: bool = false,
        len: usize = 0,
        buf: [max_key_len]u8 = undefined,

        fn key(self: *const Slot) []const u8 {
            return self.buf[0..self.len];
        }
    };

    slots: [capacity]Slot = [_]Slot{.{}} ** capacity,
    next: usize = 0,

    /// Record `id` as answered. Idempotent (re-recording an already-present id
    /// refreshes nothing and consumes no extra slot). FIFO-evicts the oldest
    /// entry when full. Shares `CancelRegistry.normalizeId` so the key space is
    /// identical to the cancel registry's.
    pub fn record(self: *AnsweredRing, id: std.json.Value) void {
        var keybuf: [CancelRegistry.max_key_len]u8 = undefined;
        const key = CancelRegistry.normalizeId(id, &keybuf) orelse return;
        for (&self.slots) |*slot| {
            if (slot.used and std.mem.eql(u8, slot.key(), key)) return;
        }
        var target: ?*Slot = null;
        for (&self.slots) |*slot| {
            if (!slot.used) {
                target = slot;
                break;
            }
        }
        const slot = target orelse blk: {
            const s = &self.slots[self.next];
            self.next = (self.next + 1) % capacity;
            break :blk s;
        };
        slot.used = true;
        slot.len = key.len;
        @memcpy(slot.buf[0..key.len], key);
    }

    /// True when `id` is currently recorded as answered. Read-only (does not
    /// evict). Used by `handleCancelRequestEntry` to detect a late/no-op cancel.
    pub fn contains(self: *const AnsweredRing, id: std.json.Value) bool {
        var keybuf: [CancelRegistry.max_key_len]u8 = undefined;
        const key = CancelRegistry.normalizeId(id, &keybuf) orelse return false;
        for (&self.slots) |*slot| {
            if (slot.used and std.mem.eql(u8, slot.key(), key)) return true;
        }
        return false;
    }
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
    /// GAP-0827: tracks whether the `initialize` REQUEST has been received and
    /// successfully processed. Distinct from `initialized` (which the
    /// `initialized` NOTIFICATION sets) — the LSP 3.17 lifecycle (§Lifecycle
    /// Messages) gates on the `initialize` request, not the post-handshake
    /// notification. Used by `handleRequest` to (a) reject any non-`initialize`
    /// request received before `initialize` with JSON-RPC -32002
    /// (ServerNotInitialized) and (b) reject a SECOND `initialize` with -32600
    /// (InvalidRequest). Set true at the END of a successful `handleInitialize`.
    initialize_received: bool = false,
    /// GAP-0827: set true once a `shutdown` REQUEST has been processed. Per LSP
    /// 3.17 (§Lifecycle — Shutdown) the server enters a state where it rejects
    /// every further REQUEST with -32600 InvalidRequest but still processes the
    /// `exit` NOTIFICATION (which terminates the run loop). This is distinct
    /// from `shutdown_requested`: the latter is the run-loop's termination flag
    /// (set by `exit`), so setting it on `shutdown` would tear the loop down
    /// before `exit` ever arrives. The gate in `handleRequest` checks THIS
    /// flag.
    shutdown_received: bool = false,
    shutdown_requested: bool = false,
    formatting_options: features.FormattingOptions = .{},
    /// GAP-0817: negotiated position encoding for this session. Resolved in
    /// `handleInitialize` from the client's
    /// `capabilities.general.positionEncodings` (LSP 3.17). Geode advertises
    /// the chosen one in the `initialize` result and uses it to translate every
    /// incoming `Position.character` (in the negotiated encoding's code units)
    /// to a UTF-8 byte column before indexing the document. Defaults to the
    /// LSP protocol default (UTF-16) until `initialize` resolves it.
    position_encoding: document.PositionEncoding = .utf16,
    /// F-01: per-document debounce state. Keyed by URI; values track
    /// the timestamp of the last didChange and whether a diagnostic
    /// flush is still pending.
    debounce_state: std.StringHashMap(DebounceState) = undefined,
    debounce_state_initialized: bool = false,
    /// F-01: incremented every time sendDiagnostics actually transmits
    /// (or would transmit) a diagnostic frame. Test-only field; does
    /// not affect production behavior.
    diagnostics_send_count_for_test: usize = 0,

    /// GAP-0816: registry of request ids the client asked to cancel via
    /// `$/cancelRequest`. Consulted at the top of `handleRequest`; a hit
    /// short-circuits with JSON-RPC -32800 (RequestCancelled) and consumes the
    /// entry. Inline value (no allocation) — bounded ring, see `CancelRegistry`.
    cancel_registry: CancelRegistry = .{},

    /// GAP-0816 (poisoning fix): bounded ring of request ids already answered.
    /// Populated in `sendResult`/`sendError` (every response path); consulted by
    /// `handleCancelRequestEntry` to recognize a late cancel for a completed
    /// request and skip recording it — preventing the reused-id poisoning the
    /// reviewer found. Inline value (no allocation) — see `AnsweredRing`.
    answered_ids: AnsweredRing = .{},

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

    /// LSP-F-02/#770: per-document AST cache for the parsing feature
    /// providers (diagnostics / definition / symbols). One per session;
    /// installed as this thread's active cache at every message entry
    /// point (see `activateAstCache`) and invalidated by
    /// didOpen/didChange/didClose. Single-threaded by the run-loop
    /// contract — no mutex (not a lock-table tier).
    ast_cache: ast_cache.LspAstCache,

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
            .transport = try Transport.initStdio(allocator),
            .documents = DocumentStore.init(allocator),
            .debounce_state = std.StringHashMap(DebounceState).init(allocator),
            .debounce_state_initialized = true,
            .ast_cache = ast_cache.LspAstCache.init(allocator, ast_cache.DEFAULT_MAX_ENTRIES),
            .verifier = verifier,
            .allow_unauth = allow_unauth,
        };
    }

    /// Task 27: same as `initWithAuth` but accepts a pre-constructed
    /// `Transport` (typically a `Transport.initTcp(..)` value built by
    /// `geode lsp --listen` or the embedded LSP listener inside
    /// `geode serve`). The Server takes ownership of `tx` — its
    /// `deinit` will tear the transport down. Stdio callers should keep
    /// using `initWithAuth`, which constructs the stdio transport
    /// internally.
    pub fn initWithTransport(
        allocator: Allocator,
        tx: Transport,
        verifier: ?auth_mod.Verifier,
        allow_unauth: bool,
    ) !Server {
        return .{
            .allocator = allocator,
            .transport = tx,
            .documents = DocumentStore.init(allocator),
            .debounce_state = std.StringHashMap(DebounceState).init(allocator),
            .debounce_state_initialized = true,
            .ast_cache = ast_cache.LspAstCache.init(allocator, ast_cache.DEFAULT_MAX_ENTRIES),
            .verifier = verifier,
            .allow_unauth = allow_unauth,
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.debounce_state_initialized) {
            self.debounce_state.deinit();
        }
        // LSP-F-02: clear the thread's active-cache pointer if it still
        // points at us (so a later direct provider call on this thread —
        // e.g. a features_test running after a server_test in the same
        // test binary — can never dereference a freed cache), then free
        // every cached AST.
        ast_cache.clearActiveIf(&self.ast_cache);
        self.ast_cache.deinit();
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
        // Task 27: tear the transport down so a TCP-backed session
        // closes its socket FD. For stdio the dispatch is a no-op
        // (StdioTransport has no `deinit` decl; the union guards on
        // `@hasDecl`). Safe to call from every Server constructor.
        self.transport.deinit();
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
        const text_document = try json_helpers.getObject(params_value, "textDocument");
        const uri = try json_helpers.getString(text_document, "uri");
        const position = try json_helpers.getObject(params_value, "position");
        const line_i64 = try json_helpers.getInteger(position, "line");
        const char_i64 = try json_helpers.getInteger(position, "character");
        const line = try json_helpers.castU32(line_i64);
        const wire_character = try json_helpers.castU32(char_i64);

        // GAP-0817: the incoming `character` is in the negotiated encoding's
        // CODE UNITS. Geode's document internals are UTF-8 byte slices, so
        // translate it to a UTF-8 byte column within the target line before it
        // reaches the byte-based `getOffset` in the feature providers. For a
        // utf-8 session (or an ASCII-only line) the column is unchanged; for a
        // utf-16/utf-32 session on a multi-byte line this is the fix that lands
        // the cursor on the right token instead of drifting past it. When the
        // document is not open yet we cannot translate (no line text), so we
        // pass the value through — the handlers answer null/empty for an
        // unknown document anyway.
        const character = blk: {
            if (self.position_encoding == .utf8) break :blk wire_character;
            const doc = self.documents.get(uri) orelse break :blk wire_character;
            const line_text = doc.getLineContent(line) orelse break :blk wire_character;
            break :blk document.codeUnitsToByteColumn(line_text, wire_character, self.position_encoding);
        };

        return TextDocumentPosition{
            .uri = uri,
            .line = line,
            .character = character,
        };
    }

    /// GAP-0817 (outbound): translate a UTF-8 BYTE column (as produced by the
    /// feature providers in `features.zig`, which compute `offset - line_start`)
    /// into the negotiated encoding's code-unit column for an OUTBOUND
    /// `Position.character`. For a utf-8 session this is an identity passthrough;
    /// for utf-16/utf-32 it is the inverse of the inbound `codeUnitsToByteColumn`
    /// conversion and is the fix that lands a definition/range/diagnostic at the
    /// right column on a multi-byte line. When the document or its line text is
    /// unavailable we pass the byte column through unchanged (degraded but
    /// bounded — the alternative would be to drop the position entirely).
    pub fn outboundChar(self: *const Server, uri: []const u8, line: i64, byte_char: i64) i64 {
        if (self.position_encoding == .utf8) return byte_char;
        if (byte_char <= 0 or line < 0) return byte_char;
        const doc = self.documents.get(uri) orelse return byte_char;
        const line_u32 = std.math.cast(u32, line) orelse return byte_char;
        const byte_u32 = std.math.cast(u32, byte_char) orelse return byte_char;
        const line_text = doc.getLineContent(line_u32) orelse return byte_char;
        return document.byteColumnToCodeUnits(line_text, byte_u32, self.position_encoding);
    }

    /// LSP-SEC-004: shared safe extractor for textDocument-only requests.
    fn extractTextDocumentUri(self: *Server, params_value: std.json.Value) json_helpers.JsonError![]const u8 {
        _ = self;
        const text_document = try json_helpers.getObject(params_value, "textDocument");
        return try json_helpers.getString(text_document, "uri");
    }

    /// GAP-0832: validated JSON-RPC envelope. `decodeEnvelope` produces
    /// one of these from an already-parsed `std.json.Value`, replacing the
    /// pre-fix `parsed.value.object` / `m.string` chain that panicked on a
    /// non-object root or a non-string `method`.
    pub const Envelope = struct {
        /// The `method` string. Always non-null for a well-formed JSON-RPC
        /// message that we should dispatch (a message without `method` is a
        /// response, which an LSP *server* never receives — we drop it).
        method: []const u8,
        /// The request id. Non-null ⇒ Request; null ⇒ Notification.
        id: ?std.json.Value,
        /// The `params` member, forwarded untouched to the handler (handlers
        /// validate their own param shape via json_helpers).
        params: ?std.json.Value,
    };

    /// GAP-0832: result of decoding the envelope. `drop` means the payload
    /// is structurally valid JSON but not a dispatchable client→server
    /// message (e.g. a response object, or a notification we don't route)
    /// and should be silently ignored per JSON-RPC 2.0 §5 (servers MUST NOT
    /// reply to malformed notifications). `bad_request` carries the id (if
    /// any) so the caller can emit a JSON-RPC -32600 error response.
    pub const DecodeResult = union(enum) {
        envelope: Envelope,
        drop,
        bad_request: ?std.json.Value,
    };

    /// GAP-0832: pure, allocation-free validator for the top-level
    /// JSON-RPC envelope. Pulled out of `handleMessage` so the
    /// malformed-input matrix (non-object root, non-string method,
    /// missing method) is unit-testable without a transport.
    ///
    /// CANARY: REQ=REQ-LSP-SEC-004; FEATURE="EnvelopeValidatedDecode"; ASPECT=SafeUnwrap; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09
    ///
    /// Rules (JSON-RPC 2.0 / LSP 3.17 §3):
    ///   - root MUST be an object → otherwise -32600 (Invalid Request).
    ///   - `method`, when present, MUST be a string → otherwise -32600.
    ///   - a message with no `method` is a response (servers ignore) → drop.
    ///   - `id`, when present, is forwarded verbatim (string|number|null per
    ///     spec); its absence selects the notification path.
    pub fn decodeEnvelope(value: std.json.Value) DecodeResult {
        if (value != .object) return .{ .bad_request = null };
        const root = value.object;

        const method_v = root.get("method") orelse {
            // No method member: this is a response, not a request or
            // notification. LSP servers do not consume responses; drop it.
            return .drop;
        };
        if (method_v != .string) {
            // Present but wrong-typed method ⇒ Invalid Request. Preserve
            // the id (if any, and only if it's a valid id type) so the
            // error response can be correlated by the client.
            return .{ .bad_request = idOrNull(root.get("id")) };
        }

        // GAP-0827 (deferred item a): an `id` member that is present but a
        // structurally-invalid type (object/array/bool) makes this a malformed
        // REQUEST, not a notification. Per JSON-RPC 2.0 §4 an id must be a
        // String, Number, or Null. The pre-fix code ran the id through
        // `idOrNull` (which maps a structured id to null) and then — because
        // a null id selects the notification path — silently dispatched it as
        // a notification, never answering the client. We now detect the
        // present-but-invalid case explicitly and surface a -32600 with a null
        // response id (we MUST NOT echo the attacker-controlled structured
        // value). A genuinely ABSENT id member still selects the notification
        // path (envelope with id == null).
        if (root.get("id")) |raw_id| {
            if (idOrNull(raw_id) == null) {
                // id member present but not a valid id type ⇒ Invalid Request.
                return .{ .bad_request = null };
            }
        }

        return .{ .envelope = .{
            .method = method_v.string,
            .id = idOrNull(root.get("id")),
            .params = root.get("params"),
        } };
    }

    /// GAP-0832: normalize the `id` member. Per JSON-RPC 2.0 §4 an id is a
    /// String, Number, or Null; anything else (object/array/bool) is not a
    /// valid id and is treated as absent so we never echo an attacker-
    /// controlled structured value back as the response id.
    fn idOrNull(maybe_id: ?std.json.Value) ?std.json.Value {
        const id = maybe_id orelse return null;
        return switch (id) {
            .string, .integer, .float, .null => id,
            else => null,
        };
    }

    /// LSP-F-02: install this session's AST cache as the thread's active
    /// cache so the parsing feature providers (which only receive
    /// `*const Document`) can consult it. Called at every entry point
    /// that can reach a provider: `handleMessage` (the run-loop path),
    /// `computeDefinition` (public helper tests drive directly), and
    /// `sendDiagnostics` (also reached from the run-loop debounce flush).
    /// A threadlocal store — cheap enough to repeat per message.
    fn activateAstCache(self: *Server) void {
        ast_cache.setActive(&self.ast_cache);
    }

    pub fn handleMessage(self: *Server, message_text: []const u8) !void {
        self.activateAstCache();

        // LSP-SEC-003: reject deeply nested or oversized payloads BEFORE
        // entering the recursive parser. checkJsonDepth is O(n), allocation-free,
        // and aware of in-string brace characters.
        json_helpers.checkJsonDepth(message_text) catch |err| {
            self.transport.logMessage("WARN", "Rejected JSON payload (depth/size cap)");
            return err;
        };

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message_text, .{});
        defer parsed.deinit();

        // GAP-0832: validated decode. The pre-fix code did
        // `parsed.value.object` (panic on non-object root) and `m.string`
        // (panic on non-string method). Both are now structurally
        // validated; a malformed envelope yields a JSON-RPC -32600 error
        // response (when an id is present) or is dropped per JSON-RPC §5.
        switch (decodeEnvelope(parsed.value)) {
            .drop => return,
            .bad_request => |maybe_id| {
                // GAP-0827 (deferred item b): a -32600 Invalid Request with no
                // valid id MUST still be answered with `"id": null` — the
                // JSON-RPC 2.0 §5 worked example for a malformed/invalid
                // request shows exactly `{"jsonrpc":"2.0","id":null,"error":…}`.
                // The pre-fix code only answered when an id was present and
                // silently dropped the no-id case, leaving a malformed request
                // unanswered. We now always emit the error, defaulting the
                // response id to JSON null when none could be recovered.
                const id = maybe_id orelse std.json.Value{ .null = {} };
                try self.sendError(
                    id,
                    @intFromEnum(protocol.ErrorCode.InvalidRequest),
                    "Invalid Request: malformed JSON-RPC envelope",
                );
                return;
            },
            .envelope => |env| {
                if (env.id) |id| {
                    try self.handleRequest(env.method, id, env.params);
                } else {
                    try self.handleNotification(env.method, env.params);
                }
            },
        }
    }

    /// Task 12: the four methods that are allowed before the LSP session
    /// has authenticated. Everything else is rejected with JSON-RPC
    /// -32002 ("not authenticated"). Notification-level `initialized`
    /// and `exit` are handled in `handleNotification`; this list covers
    /// only the request side.
    fn isAuthExemptMethod(method: []const u8) bool {
        return std.mem.eql(u8, method, Methods.initialize) or
            std.mem.eql(u8, method, Methods.shutdown);
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
        // GAP-0816: cancellation gate. Consulted BEFORE the auth gate and
        // before dispatch so a request the client already asked to cancel
        // (via a prior `$/cancelRequest` notification) is answered exactly
        // once with JSON-RPC -32800 (RequestCancelled) and the registry entry
        // is consumed. Because the server processes messages synchronously
        // one-at-a-time, this is the spec-compliant realization of LSP 3.17
        // §3.17.10: there is no in-flight handler to interrupt, so the cancel
        // is observed at the next safe point — the request's own entry. An
        // un-cancelled (or already-consumed) id falls straight through.
        if (self.cancel_registry.consume(id)) {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.RequestCancelled), "request cancelled");
            return;
        }

        // GAP-0816 (poisoning fix): from here on this id WILL be answered (one
        // of the branches below sends a result or error). Record it as answered
        // and clear any pending cancel for it so that:
        //   - a `$/cancelRequest` for this id that arrives later is recognized
        //     as a no-op late cancel (see `handleCancelRequestEntry`), and
        //   - the belt-and-braces `clear` drops a cancel entry that slipped in
        //     between dispatch start and now (covers response paths that build
        //     JSON manually instead of going through `sendResult`/`sendError`).
        // `record`/`clear` reuse `idOrNull`'s key space; both are no-ops for a
        // non-recordable id. Done before dispatch returns so it runs regardless
        // of which response path the handler takes.
        self.answered_ids.record(id);
        self.cancel_registry.clear(id);

        // GAP-0827: LSP 3.17 lifecycle gate. Enforced BEFORE the auth gate so
        // the lifecycle (-32002 server-not-initialized / -32600 double-init /
        // -32600 post-shutdown) takes precedence over the per-session auth
        // gate. These are protocol-state rules, independent of credentials.
        const is_initialize = std.mem.eql(u8, method, Methods.initialize);

        // (1) Post-shutdown: per spec, after a `shutdown` request the server
        //     rejects any further REQUEST with InvalidRequest (-32600). The
        //     only valid follow-up is the `exit` NOTIFICATION (handled in
        //     handleNotification, which has no gate). `shutdown` itself is
        //     idempotent-ish but a second shutdown after shutdown is still a
        //     post-shutdown request and is rejected.
        if (self.shutdown_received) {
            try self.sendError(
                id,
                @intFromEnum(protocol.ErrorCode.InvalidRequest),
                "Invalid Request: server is shutting down",
            );
            return;
        }

        // (2) Double initialize: a second `initialize` request after one has
        //     already been processed is an InvalidRequest (-32600) per LSP
        //     3.17 (§Lifecycle — initialize may be sent exactly once).
        if (is_initialize and self.initialize_received) {
            try self.sendError(
                id,
                @intFromEnum(protocol.ErrorCode.InvalidRequest),
                "Invalid Request: initialize may only be sent once",
            );
            return;
        }

        // (3) Pre-initialize: any request OTHER than `initialize` that arrives
        //     before `initialize` has been processed is answered with -32002
        //     ServerNotInitialized. This is the LIFECYCLE gate; it is distinct
        //     from (and precedes) the auth gate below, which ALSO uses -32002
        //     but with the "not authenticated" message. Note `shutdown` is
        //     NOT lifecycle-exempt here: a `shutdown` before `initialize` is a
        //     protocol error, even though it is auth-exempt.
        if (!is_initialize and !self.initialize_received) {
            try self.sendError(
                id,
                @intFromEnum(protocol.ErrorCode.ServerNotInitialized),
                "server not initialized",
            );
            return;
        }

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

        // GAP-0831: dispatch is an `inline for` over the comptime
        // `request_dispatch` table, which is ALSO the source `handled_request_methods`
        // is derived from. Removing a table row removes both the branch and the
        // introspected entry, so the truthfulness guard catches an advertised
        // capability that has lost its dispatch (the branch-removal blind spot).
        inline for (request_dispatch) |entry| {
            if (std.mem.eql(u8, method, entry.method)) {
                return entry.handler(self, id, params);
            }
        }
        try self.sendError(id, @intFromEnum(protocol.ErrorCode.MethodNotFound), "Method not found");
    }

    fn handleNotification(self: *Server, method: []const u8, params: ?std.json.Value) !void {
        // GAP-0827: LSP 3.17 lifecycle gate for notifications. Per spec, any
        // notification received BEFORE the `initialize` request — EXCEPT `exit`
        // — MUST be dropped. (The `initialized` notification is the client's
        // post-`initialize` ack; `exit` must always be honored so a client can
        // bail out of a half-open session.) A notification never produces a
        // response, so a dropped pre-initialize notification is simply ignored.
        if (!self.initialize_received and !std.mem.eql(u8, method, Methods.exit)) {
            return;
        }

        // GAP-0831: dispatch is an `inline for` over the comptime
        // `notification_dispatch` table, the same source `handled_notification_methods`
        // is derived from. A method not in the table is silently ignored, per
        // JSON-RPC 2.0 §5 (servers MUST NOT reply to unknown notifications).
        inline for (notification_dispatch) |entry| {
            if (std.mem.eql(u8, method, entry.method)) {
                return entry.handler(self, params);
            }
        }
    }

    /// GAP-0831: uniform-signature wrapper for `handleInitialize` so it can sit
    /// in `request_dispatch` alongside the other request handlers.
    fn handleInitializeEntry(self: *Server, id: std.json.Value, params: ?std.json.Value) anyerror!void {
        return self.handleInitialize(id, params);
    }

    /// GAP-0831: uniform-signature wrapper for `handleShutdown` (which takes no
    /// params) so it matches the `RequestHandler` type in `request_dispatch`.
    fn handleShutdownEntry(self: *Server, id: std.json.Value, params: ?std.json.Value) anyerror!void {
        _ = params;
        return self.handleShutdown(id);
    }

    /// GAP-0831: uniform-signature wrapper for the `initialized` notification,
    /// which only flips a flag. Lets it live in `notification_dispatch`.
    fn handleInitializedEntry(self: *Server, params: ?std.json.Value) anyerror!void {
        _ = params;
        self.initialized = true;
        self.transport.logMessage("INFO", "Client initialized");
    }

    /// GAP-0831: uniform-signature wrapper for the `exit` notification.
    fn handleExitEntry(self: *Server, params: ?std.json.Value) anyerror!void {
        _ = params;
        self.shutdown_requested = true;
    }

    /// GAP-0816: `$/cancelRequest` notification handler. Per LSP 3.17 §3.17.10
    /// the params are `{ "id": <number|string> }`. A missing/malformed id (or a
    /// structurally-invalid id type) is a silent no-op — a notification never
    /// produces a response, and cancelling an unknown id must not error.
    ///
    /// GAP-0816 (poisoning fix): a cancel for a request that was ALREADY
    /// answered is a spec no-op. In this strictly-synchronous server that is the
    /// COMMON case — the request was fully processed and answered before the
    /// cancel notification was even read, so there is never an in-flight handler
    /// to interrupt. Recording such a late cancel would poison the next request
    /// that reuses the id (editors recycle small integer ids), wrongly firing a
    /// `-32800` against it. We therefore consult the answered-ids ring first and
    /// SKIP recording when the id was already answered.
    ///
    /// Ordering matrix (cancel C{id}, request R{id}, answered ring A, cancel
    /// registry CR; the server reads one message at a time):
    ///   1. C then R (genuine pre-emptive cancel): C sees id ∉ A → records in
    ///      CR. R's entry-gate `CR.consume` hits → one `-32800`. Correct.
    ///   2. R then C then R' (reviewer's poisoning case): R answered →
    ///      `sendResult/sendError` records id in A AND `CR.clear(id)` (no-op,
    ///      nothing pending). C sees id ∈ A → SKIP. R' → CR empty → answered
    ///      normally. Poisoning eliminated.
    ///   3. C then R then C' then R' (cancel, serve, late dup-cancel, reuse):
    ///      step 1 yields the `-32800` for R (sendError records id in A). C'
    ///      sees id ∈ A → SKIP. R' answered normally. Correct.
    ///   4. C for an id never sent: id ∉ A → recorded in CR; lingers until a
    ///      same-id request consumes it (then behaves as case 1) or FIFO
    ///      eviction reclaims the slot. Bounded, harmless.
    ///   5. Residual: if the answered id was FIFO-evicted from A before a very
    ///      late C arrives, C is recorded and a future reuse R' eats one
    ///      spurious `-32800`. The window is bounded by `AnsweredRing.capacity`;
    ///      `CR.clear` on every response shrinks it further.
    ///
    /// CANARY: REQ=REQ-LSP-CANCEL-001; FEATURE="CancelRequestRegistry"; ASPECT=NotificationHandler; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09
    fn handleCancelRequestEntry(self: *Server, params: ?std.json.Value) anyerror!void {
        const p = params orelse return;
        if (p != .object) return;
        const id_v = p.object.get("id") orelse return;
        // Reuse the same id-validity gate the response path uses so an
        // attacker-controlled structured id is never recorded.
        const id = idOrNull(id_v) orelse return;
        // Late cancel (request already answered) = LSP no-op. Do NOT record it,
        // or the reused id would be wrongly cancelled. See the matrix above.
        if (self.answered_ids.contains(id)) return;
        self.cancel_registry.cancel(id);
    }

    /// GAP-0816: test accessor — the most recent raw JSON-RPC frame written to
    /// the transport when the Server was built with a capturing Noop transport
    /// (`Transport.initNoop` + `NoopTransport.initCapturing`). Returns null for
    /// non-capturing transports. Side-effect-free.
    pub fn lastWrittenForTest(self: *const Server) ?[]const u8 {
        return switch (self.transport) {
            .noop => |*n| n.lastMessage(),
            else => null,
        };
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
    /// Public so the GAP-0818 gate regression (tests/test_gap0818_gate.zig)
    /// can pin the unverified-refusal path without driving the JSON-RPC
    /// transport; production callers remain `bindSession` / `bindUnauthSession`.
    pub fn publishVerifiedState(self: *Server, state: auth_mod.AuthState) auth_mod.AuthError!void {
        var st = state;
        errdefer st.deinit(self.allocator);

        // GAP-0818 enforcement gate: refuse to publish a session whose
        // principal was never verified. The SchemaProvider and
        // ExecutionContext built below both carry the (client-asserted)
        // tenant — publishing them for an unverified AuthState would let
        // tenant-scoped schema / RLS-filtered data be served to a caller
        // auth never vouched for. `bindSession` only reaches here after
        // `AuthState.verify` succeeds and `bindUnauthSession` synthesizes
        // a verified null-tenant state, so this is a chokepoint assert
        // against future callers/refactors, pinned by
        // tests/test_gap0818_gate.zig.
        if (!st.verified) return auth_mod.AuthError.InvalidToken;

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

    /// GAP-0818: build the caller-identity context the feature providers
    /// (completion / hover / definition) enforce their tenant gate
    /// against. Pulled from the verified per-session `AuthState`. When no
    /// session is bound (the providers reject requests before
    /// `initialize` anyway) this returns the unauthenticated stdio
    /// default — a null tenant that only matches a null-tenant schema.
    ///
    /// The returned slices borrow from `self.auth` (freed in `deinit`);
    /// callers must use the context only for the duration of a single
    /// request handler, which is always synchronous here.
    ///
    /// CANARY: REQ=REQ-LSP-CALLER-IDENTITY-001; FEATURE="LspCallerIdentity"; ASPECT=VerifiedPrincipalGate; STATUS=TESTED; TEST=tests/test_gap0818_gate.zig:"callerContext for an unverified principal exposes no tenant"; OWNER=lsp; UPDATED=2026-06-10
    pub fn callerContext(self: *const Server) features.LspContext {
        if (self.auth == null) return features.LspContext.stdio;
        // Borrow directly from the stored AuthState (not a by-value copy)
        // so the derived session-handle slice points at the inline buffer
        // that lives for the duration of the request handler.
        const a: *const auth_mod.AuthState = &self.auth.?;
        // GAP-0818 enforcement gate: the tenant in AuthState is
        // CLIENT-ASSERTED (initializeOptions.geode.tenant). Only a
        // principal that passed `AuthState.verify` may have its asserted
        // identity exposed to the data-serving providers. With no
        // verified principal the context collapses to the anonymous
        // stdio default — whose null tenant can never match a
        // tenant-scoped SchemaProvider (`LspContext.schemaTenantMatches`),
        // so tenant-scoped schema is unreachable regardless of what the
        // request gate upstream did. Pinned by tests/test_gap0818_gate.zig.
        if (!a.verified) return features.LspContext.stdio;
        return .{
            .tenant_id = a.tenant_id,
            .user_id = if (a.user.len > 0) a.user else null,
            // GAP-0818 follow-up: never expose the raw bearer token. Use the
            // derived, non-reversible Wyhash-hex handle (null for stdio).
            .session_id = a.sessionHandle(),
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
            auth_mod.AuthError.AuthUnavailable => "authentication temporarily unavailable: the token could not be checked (a server-side error, not an invalid token); retry",
        };
        // SONNY-6600: a check that could not run is a server-side error
        // (-32603 InternalError), not the -32002 refusal of a bad token.
        const code: i32 = if (err == auth_mod.AuthError.AuthUnavailable) -32603 else -32002;
        try self.sendError(id, code, msg);
    }

    /// GAP-0817: choose the session position encoding from the client's
    /// `initialize` params. The client lists the encodings it supports, in
    /// preference order, under `capabilities.general.positionEncodings` (LSP
    /// 3.17). Geode PREFERS `utf-8` whenever the client offers it (anywhere in
    /// the list) — it is the cheapest for our UTF-8 byte-slice internals (no
    /// code-unit translation on the hot path). If utf-8 is absent, it takes the
    /// FIRST recognized encoding in the client's stated preference order (so
    /// `utf-32` is chosen only when it is the first recognized non-utf-8 offer).
    /// It falls back to the protocol DEFAULT, `utf-16`, when the client offers
    /// nothing, an empty list, or only encodings we don't implement. This is a
    /// pure function of the params so it is unit-testable without a transport.
    ///
    /// CANARY: REQ=REQ-LSP-POSENC-001; FEATURE="PositionEncodingNegotiation"; ASPECT=Negotiate; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09
    pub fn negotiatePositionEncoding(params: ?std.json.Value) document.PositionEncoding {
        const p = params orelse return .utf16;
        if (p != .object) return .utf16;
        const caps = p.object.get("capabilities") orelse return .utf16;
        if (caps != .object) return .utf16;
        const general = caps.object.get("general") orelse return .utf16;
        if (general != .object) return .utf16;
        const encodings = general.object.get("positionEncodings") orelse return .utf16;
        if (encodings != .array) return .utf16;

        // Prefer utf-8 if offered anywhere; else take the FIRST recognized
        // encoding in the client's stated preference order; else default.
        var first_recognized: ?document.PositionEncoding = null;
        for (encodings.array.items) |item| {
            if (item != .string) continue;
            const enc = document.PositionEncoding.fromWire(item.string) orelse continue;
            if (enc == .utf8) return .utf8;
            if (first_recognized == null) first_recognized = enc;
        }
        return first_recognized orelse .utf16;
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

        // GAP-0817: negotiate the position encoding from the client's
        // `capabilities.general.positionEncodings` BEFORE building the
        // advertised capabilities (which echoes the chosen one back).
        self.position_encoding = negotiatePositionEncoding(params);

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

        var response = std.json.ObjectMap{};
        defer response.deinit(self.allocator);

        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);

        var result = std.json.ObjectMap{};
        defer result.deinit(self.allocator);

        // GAP-0831: build the advertised capabilities through the single
        // shared builder so the `initialize` result and the truthfulness
        // guard observe identical key sets (no drift possible).
        var caps = try buildCapabilitiesObject(self.allocator, self.position_encoding);
        defer deinitCapabilitiesObject(self.allocator, &caps);

        try result.put(self.allocator, "capabilities", .{ .object = caps });

        var server_info = std.json.ObjectMap{};
        defer server_info.deinit(self.allocator);
        try server_info.put(self.allocator, "name", .{ .string = "geode-lsp" });
        try server_info.put(self.allocator, "version", .{ .string = "1.0.0" });
        try result.put(self.allocator, "serverInfo", .{ .object = server_info });

        try response.put(self.allocator, "result", .{ .object = result });

        try self.sendJsonValue(.{ .object = response });

        // GAP-0827: mark the lifecycle as initialized only AFTER a successful
        // initialize result has been emitted. A failed bind short-circuits via
        // `respondInitializeError` above and never reaches here, so the
        // pre-initialize gate stays closed (the client must re-handshake). A
        // second `initialize` is rejected by the gate in `handleRequest` before
        // ever reaching this function.
        self.initialize_received = true;
    }

    fn handleShutdown(self: *Server, id: std.json.Value) !void {
        var response = std.json.ObjectMap{};
        defer response.deinit(self.allocator);

        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);
        try response.put(self.allocator, "result", .null);

        try self.sendJsonValue(.{ .object = response });

        // GAP-0827: enter the post-shutdown state. The next REQUEST (any
        // method, including a second `shutdown`) is rejected by the lifecycle
        // gate with -32600; only the `exit` NOTIFICATION is still honored. We
        // do NOT set `shutdown_requested` here — that is the run-loop's
        // termination flag and is reserved for `exit` so the loop stays alive
        // to receive `exit`.
        self.shutdown_received = true;
    }

    fn handleDidOpen(self: *Server, params: ?std.json.Value) !void {
        const p = params orelse return;
        // LSP-SEC-004: structured access, returns InvalidParams on bad shape.
        const text_document = try json_helpers.getObject(p, "textDocument");
        const uri = try json_helpers.getString(text_document, "uri");
        const text = try json_helpers.getString(text_document, "text");
        const version = try json_helpers.castI32(try json_helpers.getInteger(text_document, "version"));

        try self.documents.open(uri, text, version);
        // LSP-F-02: a re-open replaces the document — drop any cached AST.
        self.ast_cache.invalidate(uri);

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
            // LSP-F-02: the cached AST is for the old (version, text) —
            // drop it eagerly so the next provider request re-parses.
            // (The cache's version/text check would also catch this; the
            // eager invalidate just frees the memory immediately.)
            self.ast_cache.invalidate(uri);

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
        // LSP-F-02: free the closed document's cached AST.
        self.ast_cache.invalidate(uri);
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

        // GAP-0344: same hardening as handleCompletion — provideHover must
        // never leave the request unanswered. Errors collapse to a null
        // result so the client unblocks instead of waiting for its read
        // timeout.
        const hover = features.provideHover(self.allocator, doc, line, character, self.schema, self.callerContext()) catch {
            try self.sendResult(id, .null);
            return;
        };
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

            try self.sendOwnedJsonValue(.{ .object = response });
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

        // GAP-0344: provideCompletion has historically been allowed to throw
        // (e.g. OOM on a large schema scan, malformed cursor position). The
        // request handler MUST always respond to the client — propagating
        // an error here leaves the LSP client hanging until its read timeout
        // because the main loop only logs the error without sending a
        // JSON-RPC error reply. Catch + return an empty completion list so
        // the client always observes a response; downstream features such as
        // hover/definition use the same pattern.
        const items = features.provideCompletion(self.allocator, doc, line, character, self.schema, self.callerContext()) catch {
            try self.sendResult(id, .{ .array = std.json.Array.init(self.allocator) });
            return;
        };
        defer {
            for (items) |item| {
                if (item.insertText) |text| {
                    if (!std.mem.eql(u8, text, item.label)) {
                        self.allocator.free(text);
                    }
                }
                // GAP-0826: free the allocator-owned `.detail`. The
                // features.provideCompletion ownership contract is: the
                // schema-LABEL / edge-type branches use a STATIC literal detail
                // (kind == .Class / .Reference), while the keyword / function /
                // type / procedure / property branches allocPrint their detail.
                // The historical cleanup here freed only `insertText`, leaking
                // every allocated `.detail` once completion produced non-label
                // items for an OPEN document — surfaced by the GAP-0826 stress
                // pack. Mirror the ownership split features_test.zig already
                // encodes: free detail for every kind EXCEPT the static-detail
                // label/edge kinds.
                if (item.detail) |detail| {
                    if (item.kind != .Class and item.kind != .Reference) {
                        self.allocator.free(detail);
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

        try self.sendOwnedJsonValue(.{ .object = response });
    }

    /// GAP-0056: pure helper — extracted for unit testability.
    /// Returns the goto-definition Location for `(uri, line, character)`,
    /// or null if not found / unknown / keyword.
    /// CANARY: REQ=REQ-LSP-GOTODEF-001; FEATURE="GoToDefinitionWired"; ASPECT=VariableLookup; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06
    pub fn computeDefinition(self: *Server, uri: []const u8, line: u32, character: u32) !?protocol.Location {
        // LSP-F-02: public helper is also a provider entry point (tests
        // drive it without going through handleMessage).
        self.activateAstCache();
        const doc = self.documents.get(uri) orelse return null;
        return try features.provideDefinition(self.allocator, doc, line, character, self.callerContext());
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

            // GAP-0817 (outbound): the feature provider returns BYTE columns;
            // convert to the negotiated encoding's code units against the
            // target document's line text before emitting.
            var range = std.json.ObjectMap{};
            var start_pos = std.json.ObjectMap{};
            try start_pos.put(self.allocator, "line", .{ .integer = loc.range.start.line });
            try start_pos.put(self.allocator, "character", .{ .integer = self.outboundChar(loc.uri, loc.range.start.line, loc.range.start.character) });
            var end_pos = std.json.ObjectMap{};
            try end_pos.put(self.allocator, "line", .{ .integer = loc.range.end.line });
            try end_pos.put(self.allocator, "character", .{ .integer = self.outboundChar(loc.uri, loc.range.end.line, loc.range.end.character) });
            try range.put(self.allocator, "start", .{ .object = start_pos });
            try range.put(self.allocator, "end", .{ .object = end_pos });
            try result.put(self.allocator, "range", .{ .object = range });

            try response.put(self.allocator, "result", .{ .object = result });
            try self.sendOwnedJsonValue(.{ .object = response });
        } else {
            try self.sendResult(id, .null);
        }
    }

    fn handleFormatting(self: *Server, id: std.json.Value, params: ?std.json.Value) !void {
        const p = params orelse {
            try self.sendResult(id, .null);
            return;
        };

        // GAP-0832: validated decode. The pre-fix code unwrapped
        // `p.object.get("textDocument").object.get("uri").string` with no
        // type checks — a non-object root, a non-object textDocument, or a
        // non-string uri each panicked. Route through the shared safe
        // extractor and answer InvalidParams (-32602) on a bad shape so the
        // client unblocks instead of crashing the server.
        const uri = self.extractTextDocumentUri(p) catch {
            try self.sendError(id, @intFromEnum(protocol.ErrorCode.InvalidParams), "Missing or malformed params");
            return;
        };

        const doc = self.documents.get(uri) orelse {
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

            // Build range object. GAP-0817 (outbound): convert BYTE columns to
            // negotiated code units against this document's line text.
            var range = std.json.ObjectMap{};
            var start_pos = std.json.ObjectMap{};
            try start_pos.put(self.allocator, "line", .{ .integer = sym.range.start.line });
            try start_pos.put(self.allocator, "character", .{ .integer = self.outboundChar(uri, sym.range.start.line, sym.range.start.character) });
            var end_pos = std.json.ObjectMap{};
            try end_pos.put(self.allocator, "line", .{ .integer = sym.range.end.line });
            try end_pos.put(self.allocator, "character", .{ .integer = self.outboundChar(uri, sym.range.end.line, sym.range.end.character) });
            try range.put(self.allocator, "start", .{ .object = start_pos });
            try range.put(self.allocator, "end", .{ .object = end_pos });
            try obj.put(self.allocator, "range", .{ .object = range });

            // Build selection range object (same outbound conversion).
            var sel_range = std.json.ObjectMap{};
            var sel_start = std.json.ObjectMap{};
            try sel_start.put(self.allocator, "line", .{ .integer = sym.selectionRange.start.line });
            try sel_start.put(self.allocator, "character", .{ .integer = self.outboundChar(uri, sym.selectionRange.start.line, sym.selectionRange.start.character) });
            var sel_end = std.json.ObjectMap{};
            try sel_end.put(self.allocator, "line", .{ .integer = sym.selectionRange.end.line });
            try sel_end.put(self.allocator, "character", .{ .integer = self.outboundChar(uri, sym.selectionRange.end.line, sym.selectionRange.end.character) });
            try sel_range.put(self.allocator, "start", .{ .object = sel_start });
            try sel_range.put(self.allocator, "end", .{ .object = sel_end });
            try obj.put(self.allocator, "selectionRange", .{ .object = sel_range });

            try array.append(.{ .object = obj });
        }

        var response = std.json.ObjectMap{};
        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);
        try response.put(self.allocator, "result", .{ .array = array });
        try self.sendOwnedJsonValue(.{ .object = response });
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
            try self.sendOwnedJsonValue(.{ .object = response });
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

            // GAP-0817 (outbound): convert BYTE columns to negotiated code units
            // against the referenced document's line text.
            var range = std.json.ObjectMap{};
            var start_pos = std.json.ObjectMap{};
            try start_pos.put(self.allocator, "line", .{ .integer = loc.range.start.line });
            try start_pos.put(self.allocator, "character", .{ .integer = self.outboundChar(loc.uri, loc.range.start.line, loc.range.start.character) });
            var end_pos = std.json.ObjectMap{};
            try end_pos.put(self.allocator, "line", .{ .integer = loc.range.end.line });
            try end_pos.put(self.allocator, "character", .{ .integer = self.outboundChar(loc.uri, loc.range.end.line, loc.range.end.character) });
            try range.put(self.allocator, "start", .{ .object = start_pos });
            try range.put(self.allocator, "end", .{ .object = end_pos });
            try obj.put(self.allocator, "range", .{ .object = range });

            try array.append(.{ .object = obj });
        }

        var response = std.json.ObjectMap{};
        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);
        try response.put(self.allocator, "result", .{ .array = array });
        try self.sendOwnedJsonValue(.{ .object = response });
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
        try self.sendOwnedJsonValue(.{ .object = response });
    }

    fn sendDiagnostics(self: *Server, uri: []const u8) !void {
        // LSP-F-02: also reached from the run-loop debounce flush (not
        // just handleMessage), so install the cache here too.
        self.activateAstCache();
        // F-01: count every send for test introspection.
        self.diagnostics_send_count_for_test += 1;
        const doc = self.documents.get(uri) orelse return;

        const diagnostics = try features.provideDiagnostics(self.allocator, doc, self.schema, self.callerContext());
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
        // LSP-SEC-005: never splice the client-supplied URI into the JSON
        // envelope raw — spaces, `#`, non-ASCII, and JSON-breaking bytes
        // (`"`, `\`, control chars) are RFC-3986 percent-encoded.
        const encoded_uri = try percentEncodeUri(self.allocator, uri);
        defer self.allocator.free(encoded_uri);
        try buffer.appendSlice(self.allocator, encoded_uri);
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
                // GAP-0817 (outbound): the diagnostic provider emits BYTE
                // columns; convert to the negotiated encoding's code units
                // against this document's line text (the doc IS open — see the
                // `documents.get(uri)` early-return at the top of this fn).
                const _out_char = self.outboundChar(uri, diag.range.start.line, diag.range.start.character);
                var _tmp_buf: [64]u8 = undefined;
                const _tmp_str = std.fmt.bufPrint(&_tmp_buf, "{d}", .{_out_char}) catch return error.OutOfMemory;
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
                const _out_char = self.outboundChar(uri, diag.range.end.line, diag.range.end.character);
                var _tmp_buf: [64]u8 = undefined;
                const _tmp_str = std.fmt.bufPrint(&_tmp_buf, "{d}", .{_out_char}) catch return error.OutOfMemory;
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
        // GAP-0816 (poisoning fix): a response for `id` means the request is
        // complete. Record it as answered and clear any lingering cancel so a
        // late `$/cancelRequest` for it is treated as a no-op (see
        // `handleCancelRequestEntry`). Idempotent with the `handleRequest`-level
        // record/clear; both run so this also covers any future direct caller.
        self.answered_ids.record(id);
        self.cancel_registry.clear(id);

        var response = std.json.ObjectMap{};
        defer response.deinit(self.allocator);

        try response.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try response.put(self.allocator, "id", id);
        try response.put(self.allocator, "result", result);

        try self.sendJsonValue(.{ .object = response });
    }

    fn sendError(self: *Server, id: std.json.Value, code: i32, message: []const u8) !void {
        // GAP-0816 (poisoning fix): see `sendResult`. Recording here means the
        // `-32800` cancellation response ALSO marks the id answered, so a
        // duplicate late cancel for the same id is a no-op.
        self.answered_ids.record(id);
        self.cancel_registry.clear(id);

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

    /// GAP-0826: serialize + send `value`, then RECURSIVELY release the
    /// container allocations (ObjectMaps / Arrays) it owns. The feature
    /// handlers (completion / documentSymbol / references / semanticTokens /
    /// hover / signatureHelp / definition) build a nested JSON-RPC response
    /// tree by hand and historically called bare `sendJsonValue`, which only
    /// serializes — leaving every ObjectMap/Array backing buffer leaked once a
    /// real (non-empty) response was produced for an OPEN document. (The
    /// unknown-document early-returns route through `sendResult`, whose own
    /// `defer response.deinit` hid the leak from the existing tests, which only
    /// ever query unopened documents.) The leak-detecting stress pack
    /// (tests/test_gap0826_lsp_stress.zig) surfaced it via 500+ requests on an
    /// OPEN document. `deinitJsonValue` frees only the `.object`/`.array`
    /// container backings — it never touches `.string` bytes (which are static
    /// literals or borrowed from the parsed request / schema cache here), so
    /// this is leak-free AND double-free-free.
    fn sendOwnedJsonValue(self: *Server, value: std.json.Value) !void {
        var v = value;
        defer deinitJsonValue(self.allocator, &v);
        try self.sendJsonValue(v);
    }
};
