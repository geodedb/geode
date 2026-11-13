# Geode MCP Server — Protocol Subset & Capability Contract

**Last updated:** 2026-06-10
**Owner:** mcp
**Status:** Authoritative reference for the MCP method subset Geode
implements, and for the resource-subscription contract (GAP-0516).

The Geode MCP (Model Context Protocol) server (`src/mcp/server.zig`)
exposes graph-database operations and the GQL language bridge to
AI/LLM clients over the MCP JSON-RPC protocol (stdio and HTTP
transports). It is built on the pinned `mcp` library (`build.zig.zon`
`.mcp` = v0.1.12).

This document records exactly which MCP methods Geode implements,
which it intentionally does not, and the one upstream-library caveat
operators and client authors must understand.

## Implemented method subset

| MCP method | Geode behaviour |
|---|---|
| `initialize` | Negotiates protocol version, returns `serverInfo` (`geode-mcp`) and a capabilities object. |
| `notifications/initialized` | Accepted; flips the server to the initialized state. |
| `ping` | Standard liveness reply. |
| `tools/list` | Lists Geode tools: `query`, `schema`, `explain`, `catalogs`, `graphs`, `validate`, `complete`, `hover`, `diagnostics`. |
| `tools/call` | Dispatches to the named tool (`src/mcp/tools.zig`). Backend tools (`query`/`schema`/`explain`/`catalogs`/`graphs`) require a configured geode endpoint; the language tools (`validate`/`complete`/`hover`/`diagnostics`) are pure and need no backend; `validate` and `diagnostics` include the recommendations listed in [LSP_FEATURES.md](LSP_FEATURES.md#recommendations). See [MCP_LSP_BRIDGE.md](MCP_LSP_BRIDGE.md). |
| `resources/list` | Lists Geode resources. |
| `resources/read` | Reads a resource by URI. |
| `resources/templates/list` | Lists resource templates. |
| `prompts/list` / `prompts/get` | Lists / fetches the Geode prompt catalog. |
| `completion/complete` | Argument-completion provider (MCP spec §4.4). Geode does not maintain a per-tool argument-suggestion index, so it returns an empty array `[]` — a spec-compliant "no suggestions" response. |
| `logging/setLevel` | Tolerated success (MCP spec §7.2). Geode log levels are fixed at startup (`--log-level`); the request is acknowledged without changing runtime verbosity, which the spec explicitly permits. |

## Intentionally unimplemented: resource subscriptions (GAP-0516)

`resources/subscribe` and `resources/unsubscribe` are **not**
implemented. The handlers in `src/mcp/server.zig`
(`subscribeResourceHandler` / `unsubscribeResourceHandler`) return
`error.MethodNotFound`, which the MCP library maps to JSON-RPC error
**`-32601` ("Method not found")** per spec §4.5 — the canonical
"this server does not implement this method" signal.

**Why unimplemented:** MCP resource subscriptions (spec §6.2) require
the server to push `notifications/resources/updated` when a subscribed
resource changes. Geode's query engine is synchronous
request/response, and graph-topology changes are not wired to a
background event producer. Accepting a subscription and then never
firing a notification would be a silent lie; returning `-32601` is the
honest contract.

**Client guidance:** clients that need change tracking should **poll**
via `resources/read` on an interval. There is no server-push path.

**Future:** when Geode gains a graph-topology event producer, swap the
two handlers to a real implementation and update this section, the
CANARY markers, and `tests/test_gap0516_mcp_capabilities.zig`.

### Fixed: `tools/call` result leak (upstream v0.1.11 → v0.1.12)

The pinned `mcp` library's `tools/call` dispatch (`mcp.zig` `handleMethod`)
hardcoded `.owned = false` on every `callTool` result through v0.1.11, while
the JSON-RPC response free site only frees results marked `owned`. Every
dynamically-allocated tool response Geode's `query`/`schema`/`explain`/etc.
handlers return therefore leaked for the lifetime of a long-running
`geode mcp` server. Fixed upstream in v0.1.12 (commit `956b07d`): the
`tools/call` dispatch site now returns `.owned = true`, and
`Handler.callTool`'s doc comment states the ownership contract ("callTool
implementations must return bytes allocated with the allocator the server
frees with"). `tools/list`/`resources/*`/`prompts/*` results are
unaffected — audited and intentionally left `owned = false` because the
library's own demo/example handlers may return static strings there.
Regression proof: `tests/test_mcp_read_only.zig` drives real `tools/call`
round trips under the strict `std.testing.allocator` (previously worked
around with `std.heap.page_allocator` to dodge the upstream leak).

### Known upstream advertisement caveat

The pinned `mcp` library (v0.1.12) **hardcodes**
`"resources":{"subscribe":true,"listChanged":true}` in the
`initialize` response (`mcp.zig` `buildInitialize`, ~line 3127) and
exposes **no `ServerOptions` field to override it**. Geode therefore
cannot make the advertised capability string match its handler
behaviour without forking the dependency.

The **authoritative, runtime-truthful contract is the handler
response**, not the advertised capability string:

- A client that actually sends `resources/subscribe` receives
  `-32601 MethodNotFound`.
- A client that trusts the advertised `subscribe:true` and waits for
  notifications will simply never receive any (and should fall back to
  polling).

This caveat is pinned by
`tests/test_gap0516_mcp_capabilities.zig`: the regression suite drives
the real `mcp.Server.processMessage` dispatch and asserts both facts —
the stale advertisement string AND the honest `-32601` handler
response. If a future library bump drops the stale advertisement, the
caveat test fails on purpose to prompt a refresh of this document and
the source CANARY markers.

## Authentication posture

- Default `auth_mode` is `.bearer` (SEC-08): the server **refuses to
  start** without a bearer token (`error.MissingBearerToken`). Set
  `--mcp-token` (or `Options.bearer_token`), or explicitly opt into
  `auth_mode = .none` for a trusted, non-production environment.
- A single per-server `Principal` is derived from the bearer token at
  init time (GPS Phase 5, `source = .mcp_handler`, username from
  `Options.mcp_username`, default `mcp`). Per-connection multi-user
  MCP is deferred (Phase 6+).
- See [MCP_LSP_BRIDGE.md](MCP_LSP_BRIDGE.md) for the language-bridge
  RLS pre-condition (GAP-0818).

### Backend endpoint TLS

The geode endpoint DSN is verified against its `ca=` bundle. A DSN with
`insecure=true` (or `insecure_tls_skip_verify=true`, `skip_verify=true`)
follows the CLI's `--insecure-tls-skip-verify` rule (SONNY-6453): refused
under production conditions (a release build or `GEODE_ENV=production`)
unless `GEODE_ALLOW_INSECURE_TLS=1` is set, and logged as a warning on
stderr whenever it is accepted.

## Verification

- `zig build test-gap0516` — drives the real MCP dispatch:
  `initialize` returns `serverInfo` + capabilities;
  `resources/subscribe` and `resources/unsubscribe` return `-32601`;
  the implemented subset (`tools/list`, `resources/list`,
  `resources/templates/list`, `prompts/list`, `logging/setLevel`)
  returns success; and the upstream advertisement caveat is pinned.
- Inline handler-level tests live in `src/mcp/server.zig` (the
  `GAP-0516:` test blocks) and cover the handlers directly,
  independent of transport.

## Cross-references

- GAP-0516 (this contract) — closed 2026-06-10.
- MCP spec §4.5 (Method not found), §6.2 (resource subscriptions),
  §4.4 (completion), §7.2 (logging/setLevel).
- [MCP_LSP_BRIDGE.md](MCP_LSP_BRIDGE.md) — the GQL language-bridge tools.
- GitLab tracking issue: `#668`.

CANARY: REQ=REQ-DOC-MCP-SERVER-SUBSET; FEATURE="MCPServerSubsetDoc"; ASPECT=Documentation; STATUS=EXEMPT; OWNER=mcp; UPDATED=2026-06-10
