# Geode MCP Server — Protocol Subset & Capability Contract

**Last updated:** 2026-11-14
**Owner:** mcp
**Status:** Authoritative reference for the MCP method subset Geode
implements, and for the resource-subscription contract (GAP-0516).

The Geode MCP (Model Context Protocol) server (`src/mcp/server.zig`)
exposes graph-database operations and the GQL language bridge to
AI/LLM clients over the MCP JSON-RPC protocol (stdio and HTTP
transports). It is built on the pinned `mcp` library (`build.zig.zon`
`.mcp` = v0.1.22).

This document records exactly which MCP methods Geode implements,
which it intentionally does not, and the one upstream-library caveat
operators and client authors must understand.

## Implemented method subset

| MCP method | Geode behaviour |
|---|---|
| `initialize` | Negotiates protocol version, returns `serverInfo` (`geode-mcp`) and a capabilities object. |
| `notifications/initialized` | Accepted; flips the server to the initialized state. |
| `ping` | Standard liveness reply. |
| `tools/list` | Lists Geode tools: `query`, `schema`, `explain`, `graphs`, `validate`, `complete`, `hover`, `diagnostics`. There is no `catalogs` tool (SONNY-6559): geode has no catalog object to list (see below). |
| `tools/call` | Dispatches to the named tool (`src/mcp/tools.zig`). Backend tools (`query`/`schema`/`explain`/`graphs`) require a configured geode endpoint; the language tools (`validate`/`complete`/`hover`/`diagnostics`) are pure and need no backend; `validate` and `diagnostics` include the recommendations listed in [LSP_FEATURES.md](LSP_FEATURES.md#recommendations). See [MCP_LSP_BRIDGE.md](MCP_LSP_BRIDGE.md). |
| `resources/list` | Lists Geode resources (`geode://default/default/schema`, `geode://default/default/stats`, `geode://config`). |
| `resources/read` | Reads a resource by URI (grammar below). |
| `resources/templates/list` | Lists resource templates: `geode://{catalog}/{graph}/schema`, `/stats`, `/node/{label}`, `/relationship/{type}`; each is read by `resources/read`. |
| `prompts/list` / `prompts/get` | Lists / fetches the Geode prompt catalog; `prompts/get` writes the argument values into the prompt text. |

## Result shapes and error codes (SONNY-6552)

The pinned `mcp` library implements MCP revision **2025-11-25**
(`mcp.ProtocolVersion`, negotiated in `initialize`). Every result is the
object that revision's schema (`schema/2025-11-25/schema.ts`) gives the
method, serialized on **one line**: the stdio transport delimits messages
by newlines and a message "MUST NOT contain embedded newlines".

| Method | Result (2025-11-25 schema) |
|---|---|
| `tools/list` | `ListToolsResult` `{"tools":[{name, description, inputSchema}]}` |
| `tools/call` | `CallToolResult` `{"content":[{"type":"text","text":...}],"isError":bool}` |
| `resources/list` | `ListResourcesResult` `{"resources":[{uri, name, description, mimeType}]}` |
| `resources/templates/list` | `ListResourceTemplatesResult` `{"resourceTemplates":[{uriTemplate, name, description}]}` |
| `resources/read` | `ReadResourceResult` `{"contents":[{uri, mimeType, text}]}` |
| `prompts/list` | `ListPromptsResult` `{"prompts":[{name, description, arguments:[{name, description, required}]}]}` |
| `prompts/get` | `GetPromptResult` `{"description":..., "messages":[{"role":"user","content":{"type":"text","text":...}}]}` |
| `completion/complete` | `CompleteResult` `{"completion":{"values":[],"total":0,"hasMore":false}}` |

Every list is a single page: no `nextCursor` is returned.

Errors are JSON-RPC errors (the `message` is the Zig error name the
library reports, e.g. `InvalidParams`):

| Request | Error code |
|---|---|
| `tools/call` with an unknown tool name | `-32602` (the spec's protocol error for an unknown tool) |
| `prompts/get` with an unknown prompt name | `-32602` |
| `prompts/get` missing a required argument, with an argument the prompt does not take, or with a non-string argument value | `-32602` |
| `tools/list`, `resources/list`, `prompts/list` with a `cursor` (geode never issues one) | `-32602` (pagination: an invalid cursor) |
| `resources/read` of a URI geode does not serve | `-32002` (resource not found) |
| `resources/subscribe` / `resources/unsubscribe` | `-32601` (see below) |

Tool **execution** failures are not protocol errors: they are a
`CallToolResult` with `"isError":true` and the reason in the text. That
covers bad tool arguments, an argument a tool does not advertise (the
`query` tool refuses `catalog` / `graph`, the `graphs` tool takes no
arguments), a backend that cannot be reached, and a statement the server
reports as failed (for `query`, `schema`, `explain` and `graphs`
alike). A `resources/read` whose endpoint DSN is unusable answers
the resource with a `{"error": "<reason>"}` text document (the library can
only report a Zig error name, which would drop the reason). When the
server is unreachable, every resource answers
`{"error": "Server unavailable (<error>): nothing was read"}`. Before
SONNY-6586, `schema` and `stats` answered `"node_labels": []` /
`"node_count": 0` with a `"Server unavailable"` note, which read as an
empty graph.

The `query` tool's `parameters` object maps each name to a JSON value:
`null`, a boolean, a number, a string, an array (a GQL LIST) or an object
(a GQL MAP), nested up to 64 deep. Before SONNY-6586 an array or object
was refused (`UnsupportedParamType`).

Before SONNY-6552 the lists were pretty-printed bare arrays,
`resources/read` was a bare `{uri,mimeType,text}`, an unknown prompt or
URI was a success carrying `{"error": ...}`, an unknown tool was
`-32603`, the `query` tool advertised `catalog` / `graph` and the `graphs`
tool `catalog` without using them, `prompts/get` ignored its arguments,
and `query` failed every call that passed `parameters`.

## Resources and the backend tools (SONNY-6559)

A resource URI is exactly one of:

| URI | Text (`application/json`) |
|---|---|
| `geode://config` | `{"version", "gql_compliance", "transport"}` (local; no server round trip) |
| `geode://default/<graph>/schema` | `{"graph", "node_labels": [label sets, up to 100], "relationship_types": [up to 100]}` |
| `geode://default/<graph>/stats` | `{"graph", "node_count", "relationship_count"}` |
| `geode://default/<graph>/node/<label>` | `{"graph", "label", "count", "sample": [up to 25 nodes]}` |
| `geode://default/<graph>/relationship/<type>` | `{"graph", "type", "count", "sample": [up to 25 relationships]}` |

`<graph>`, `<label>` and `<type>` are GQL identifiers
(`[A-Za-z_][A-Za-z0-9_]*`); a graph that does not exist, any other path, a
query string, a fragment or another scheme is `-32002`. The catalog
segment is always `default`: geode keeps its graphs in one namespace and
has no catalog object (an ISO/IEC 39075 catalog holds schemas that hold
graphs), so there is no other catalog to name and no catalogs tool. The
statements run through the normal client path with the endpoint's
credentials (`USE GRAPH <graph>` first), so the endpoint user's
permissions and row-level security apply to every count and sample.

The backend tools and resources decode results with geode's own wire
schema, as `geode query` does: nodes, relationships, paths, lists and maps
come back whole, and `explain` returns the plan (`{"explain": {...}}`, the
object `geode query "EXPLAIN ..." --format json` prints). Before SONNY-6559
the client library's decoder kept scalars only (the `schema` tool's label
lists and every node were `null`) and dropped the plan (`explain` answered
`{"columns":[],"rows":[]}`), the node/relationship templates were
advertised and answered `-32002`, `{catalog}/{graph}` was ignored, any URI
holding `config` or `/schema` matched, and the `catalogs` tool sent `SHOW
CATALOGS`, which does not parse.

Regression: `zig build test-sonny6559-mcp-backend` (a real `geode mcp
--stdio` session against a real server).

Regression: `zig build test-sonny6552-mcp-result-shapes` checks each
response field by field through the real `mcp.Server.processMessage` and
a real `geode mcp --stdio` session (one JSON-RPC message per stdout line).

The library maps `error.ToolNotFound` and `error.PromptNotFound` to
`-32002`, the code the 2025-11-25 spec gives only to a missing resource;
geode does not use them.
| `completion/complete` | Argument-completion provider (MCP spec §4.4). Geode does not maintain a per-tool argument-suggestion index, so it returns an empty CompleteResult, `{"completion":{"values":[],"total":0,"hasMore":false}}` — a spec-compliant "no suggestions" response (it returned a bare `[]` before SONNY-6544, which has no `completion` object). Regression: `zig build test-sonny6544-mcp-completion`. |
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

### Handler result ownership (upstream v0.1.22, SONNY-6531)

Since `mcp` v0.1.22 the server frees the result of **every** handler
callback that returns `[]const u8` (`listTools`, `callTool`,
`listResources`, `readResource`, `listResourceTemplates`, `listPrompts`,
`getPrompt`, `complete`) with the allocator passed to `mcp.Server.init`:
after the JSON-RPC response is built, for a notification (no response),
and when building the response fails. A callback that returns an error
hands nothing over. It also frees the JSON it stringifies to pass
`prompts/get` arguments and `completion/complete` params to the handler.

History: through v0.1.11 no handler result was freed, so every
`tools/call` response leaked; v0.1.12 (commit `956b07d`) freed
`tools/call` results only, so every `resources/read` response (and the
stringified `prompts/get` arguments and `completion/complete` params)
still leaked for the lifetime of a long-running `geode mcp` server.

Geode's side of the contract (`src/mcp/server.zig`): `GeodeMcpServer.init`
passes its own `allocator` to `mcp.Server.init`, and every handler returns
bytes from that allocator. `tools/call` and `resources/read` results are
built with it (`src/mcp/tools.zig`, `src/mcp/resources.zig`, including the
unreachable-server error documents); the resource and prompt results are
serialized with it (SONNY-6552), and the tool listing and the empty
CompleteResult are handed over as `ownedCopy` copies. Returning a string
literal would be an invalid free.

Regression proof (all under the strict `std.testing.allocator`, which
fails on a leak and panics on an invalid free):

- `zig build test-sonny6531-mcp-ownership` drives every method Geode
  implements through the real `mcp.Server.processMessage` dispatch (every
  tool incl. `isError` results and an unknown tool, every resource incl.
  unknown URIs and an unreachable server, every prompt incl. unknown,
  completion, logging, subscribe/unsubscribe, notifications and a batch),
  with no backend, an undialable DSN, a dead endpoint and a real
  `geode serve`; then a real Debug `geode mcp --stdio` session answers
  every request and exits 0 with no leak report on stderr (an invalid
  free aborts it). Since SONNY-6552 `geode mcp` returns through `main`
  instead of ending with `std.process.exit`, so `main`'s
  `DebugAllocator.deinit` runs and reports a leak of the session.
- `zig build test-gap0516`, `test-mcp-read-only`,
  `test-sonny6494-mcp-dsn-errors` and `test-sonny6544-mcp-completion` run
  their `resources/read` and `completion/complete` cases leak-checked
  (they used `std.heap.smp_allocator` / skipped them before).
- `zig build test-sonny6484-inline` runs the handlers' inline tests.

### Known upstream advertisement caveat

The pinned `mcp` library (v0.1.22) **hardcodes**
`"resources":{"subscribe":true,"listChanged":true}` in the
`initialize` response (`mcp.zig` `handleInitialize`, ~line 3193) and
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
  `geode mcp --token <token>` or `GEODE_MCP_TOKEN` (`Options.bearer_token`),
  or explicitly opt into `--no-auth` (`auth_mode = .none`) for `--stdio` or
  a debug build's HTTP transport. `geode mcp` refuses an option it does not
  read, a value option without its value and a `--port` that is not a port
  (exit 2, SONNY-6560); HTTP is the transport unless `--stdio` is given.
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

### Backend endpoint DSN errors

`geode mcp --endpoint <dsn>` checks the DSN at startup and refuses a
malformed one (exit 2, `Error: --endpoint: <message>`; the DSN is not
echoed). A tool call or resource read on a server whose endpoint is
malformed answers with the same message instead of a generic failure. The
host must be a name, an IPv4 address or a bracketed IPv6 address
(`quic://[::1]:3141`, IPv6 servers are reachable since geode-client-zig
v0.3.16); the port 1-65535 (0 is refused); the scheme `quic://` or
`grpc://`. See [DSN.md](DSN.md#ipv6-addresses) for the error table
(SONNY-6494). A `connect_timeout` (`timeout`) or `timeout_ms` parameter
bounds the wait for the QUIC handshake and the HELLO answer: a tool on a
server that does not answer reports `Timeout` after it (SONNY-6589,
geode-client-zig v0.3.18; before, the parameter was refused because the
library waited a fixed 30 s). Since v0.3.19 (SONNY-6617) query,
transaction and ping requests wait the same timeout for their answers
([DSN.md](DSN.md#timeout-parameters)).
Without a `hello_name` the HELLO names the client `geode-mcp`, with geode's
version. A `grpc://` endpoint needs `tls=0`: geode-client-zig's gRPC client
has no TLS and refuses rather than send in plaintext, and the tools and
resources answer that, not a bare `ConnectionFailed` (SONNY-6617).

## Verification

- `zig build test-gap0516` — drives the real MCP dispatch:
  `initialize` returns `serverInfo` + capabilities;
  `resources/subscribe` and `resources/unsubscribe` return `-32601`;
  the implemented subset (`tools/list`, `resources/list`,
  `resources/templates/list`, `prompts/list`, `logging/setLevel`)
  returns success; and the upstream advertisement caveat is pinned.
- `zig build test-sonny6552-mcp-result-shapes` — every result shape and
  error code above, in-process and over a real `geode mcp --stdio`.
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
