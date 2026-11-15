# Geode LSP Features

This document describes the Geode Language Server Protocol (LSP) implementation,
including schema-aware completion, hover, and diagnostics with per-user
permission filtering.

The plan that produced this document lives at
[`docs/superpowers/plans/2026-05-14-lsp-permission-aware-completion.md`](superpowers/plans/2026-05-14-lsp-permission-aware-completion.md);
see that file for the full task-by-task history and commit log.

## Overview

The Geode LSP server speaks LSP 3.17 over two transports:

- **stdio** (`geode lsp`) — for terminal editors (neovim, helix, VS Code over
  stdio). Used today by all command-line workflows.
- **TCP** (`geode lsp --listen tcp://HOST:PORT` or co-hosted by
  `geode serve --lsp-port=3142`) — for browser clients that reach the LSP
  through `geode-ui`'s `/ws/lsp` WebSocket bridge.

Implemented capabilities:

| Capability                          | Source                                          | Permission-aware? |
|-------------------------------------|-------------------------------------------------|-------------------|
| `textDocument/completion`           | `src/cli/lsp/features.zig:provideCompletion`    | Yes               |
| `textDocument/hover`                | `src/cli/lsp/features.zig:provideHover`         | Yes               |
| `textDocument/publishDiagnostics`   | `src/cli/lsp/features.zig:provideDiagnostics`   | Yes               |
| `textDocument/definition`           | `features.zig:provideDefinition`                | No (uses parser)  |
| `textDocument/references`           | `features.zig:provideReferences`                | No                |
| `textDocument/documentSymbol`       | `features.zig:provideDocumentSymbols`           | No                |
| `textDocument/signatureHelp`        | `features.zig:provideSignatureHelp`             | No                |
| `textDocument/semanticTokens/full`  | `features.zig:provideSemanticTokensFull`        | No                |
| `textDocument/formatting`           | `features.zig:provideFormatting`                | No                |

**Explicit non-support (honest, tested — GAP-0820..0824):**
`textDocument/codeAction`, `workspace/executeCommand`, `workspace/symbol`,
`workspace/applyEdit`, `workspace/configuration`, `textDocument/rename`,
`textDocument/prepareRename`, `textDocument/inlayHint`, and
`textDocument/willSaveWaitUntil` are **deliberately unadvertised**; a request for
any of them is answered with JSON-RPC **-32601 (MethodNotFound)** (id echoed), and
`workspace/didChangeWorkspaceFolders` / `textDocument/willSave` /
`textDocument/didSave` notifications are silently tolerated. This is not a stub:
the contract is pinned by `tests/test_gap0820_0824_lsp_nonsupport.zig`
(`zig build test-gap0820-0824`) and the inverse-direction guard in
`tests/test_gap0831_lsp_capability_guard.zig`. See
[`docs/LSP_IMPLEMENTATION.md`](LSP_IMPLEMENTATION.md#explicit-non-support-capability-trimmed-tested)
for the full matrix. (`textDocument/rangeFormatting` is likewise not advertised —
only whole-document `formatting`.)

## Architecture

```
+----------------------+        WebSocket          +----------------------+
|  Browser (Monaco)    | <-----------------------> | geode-ui Go backend  |
|  monaco-languageclient|        /ws/lsp           | wsLspHandler          |
+----------------------+                          +----------+-----------+
                                                              | TCP (127.0.0.1:3142)
                                                              v
                                                  +----------------------+
                                                  |   geode serve         |
                                                  |   LSP listener thread |
                                                  |   per-session thread  |
                                                  +----------+-----------+
                                                              | in-process
                                                              v
                                                  +----------------------+
                                                  |  SchemaProvider       |
                                                  |  (TTL cache, mutex)   |
                                                  +----------+-----------+
                                                              | direct call
                                                              v
                                                  +----------------------+
                                                  |  schema_introspection |
                                                  |  + GraphStore + auth  |
                                                  +----------------------+
```

The LSP shares the same in-process `GraphStore`, `Catalog`, and auth modules as
the QUIC query handler, so schema lookups never round-trip through the network.

## Authentication

Every LSP session except `--no-auth` stdio MUST authenticate before any
non-`initialize` request is honored. The handshake is:

1. Client sends `initialize` with the credentials of a QUIC HELLO:

   ```json
   "initializationOptions": {
     "geode": {
       "username": "alice",
       "password": "<her password>",
       "graph": "sales",
       "tenant": "<tenant id, optional>"
     }
   }
   ```

   (`geode.authToken`, an API-key or session token, is still parsed, but
   the server issues no such tokens (SONNY-6554), so a token is always
   refused.)
2. The Server parses it into an `AuthState` (`src/cli/lsp/auth.zig`).
3. `AuthState.verify(allocator, verifier)` checks it through the
   `Verifier` the transport plugged in. `geode serve`'s embedded listener
   checks a user name and password as a HELLO's
   (`user_management.authenticate`, behind the same per-(peer IP, user)
   brute-force rate limiter, `lspCredentialsVerifyFn` in
   `src/server/main.zig`); a user who must change their password first is
   refused. The password is zeroed and freed as soon as it is checked.
4. On success the Server caches a per-session `AuthState` (the user and
   their role), builds a `SchemaProvider` and `ExecutionContext`, and opens
   the request gate.
5. A refused `initialize` gets JSON-RPC `-32002` ("missing auth token" when
   no credential was given, "invalid auth token" when it was wrong), and
   every later request `-32002` too: no schema is served.

Before SONNY-6589 the embedded listener's `AuthProvider` was never
populated, so every `initialize` was refused and no client could use the
TCP LSP.

### Per-user filtering

An authenticated session's completions, hover and diagnostics read the
schema of **its graph only** (`geode.graph`, `default` when absent): the
labels, edge types and property keys of nodes in that graph, in the
session's tenant scope. They read nothing of a graph the user may not bind
and read: the checks a HELLO naming the graph and a MATCH on it pass
(`session_graph.mayBind`, `gps.graphReadPermitted`: the user's role, live
`GRANT ... ON GRAPH` grants and policies; an Admin sees every graph). Labels
an RLS label policy denies the user are dropped (issue #817). A user with no
stored role sees only the graphs a grant gives them. Pinned by
`zig build test-sonny6589-lsp-auth` (two users of different roles on a real
server).

### Stdio and `geode lsp --listen`

The standalone `geode lsp` process has no user store and no server-side
grants, so it authenticates nobody: stdio without `--no-auth` and
`geode lsp --listen` refuse every `initialize` (fail closed). For a
completion that knows a server's schema, use the listener `geode serve`
co-hosts.

### `--no-auth` mode

`geode lsp --no-auth` (stdio only) synthesizes a local-admin AuthState from
`$USER` (fallback `"local"`) without invoking a verifier. The flag is
incompatible with `--listen` and the embedded TCP listener inside
`geode serve` forces `allow_unauth=false` regardless of CLI flags. This means
the TCP path **always** requires real authentication; only stdio LSP from a
terminal editor can run without it.

## Schema-aware completion

`completion_context.analyze(text, pos)` inspects the cursor's left context and
returns a `Kind` tag. `provideCompletion` then branches:

| Cursor position    | `Kind`       | Suggestions                                        |
|--------------------|--------------|----------------------------------------------------|
| `MATCH (n:` or `:` | `label`      | Node labels the user can see (from SchemaProvider) |
| `[r:` or `]-[r:`   | `edge_type`  | Edge types the user can see                        |
| `<var>.`           | `property`   | Properties of `<var>`'s resolved label             |
| `$`                | `parameter`  | Static parameter suggestion list                   |
| Default            | `keyword`    | Static keywords/functions/types/procedures         |

Every branch honors `ctx.prefix` so partial typed prefixes
(e.g. `MATCH (n:Per`) narrow the result set. The static fallback uses a
case-insensitive `startsWithCI` filter.

Schema-derived items borrow string slices from the SchemaProvider's TTL cache
(no per-completion dup); the LSP serializer copies them before any expiry
could race.

## Schema-aware hover

`provideHover` checks the hovered identifier against the SchemaProvider:

- **Label hover** (e.g. cursor on `Person` in `(n:Person)`) renders a
  Markdown panel: label name plus the property list observed on nodes
  carrying that label, filtered by tenant.
- **Edge-type hover** (cursor on `KNOWS` in `[r:KNOWS]`) renders a brief
  usage hint with the canonical pattern `()-[r:KNOWS]->()`.
- **Property hover** (cursor on `age` in `n.age`) resolves the variable's
  label via `resolveVarLabel` and shows the owning label.
- Other words fall through to the existing keyword/function/type/procedure
  metadata paths.

## Schema-aware diagnostics

`provideDiagnostics` runs after the parser and tokenizer diagnostics, with a
two-pass label/edge-type scan that emits `Warning` diagnostics for any
reference the schema doesn't know about. A Levenshtein-bounded
("did you mean `Person`?") hint is included when the closest known label
is within edit distance 2.

The diagnostic is identified by `source: "geode-lsp"` (distinct from
`"geode"` used by parser-level errors) so clients can attribute the warning
separately.

## Recommendations

After a document parses, the recommendation engine
(`src/gql/recommendations.zig`) adds `Information` and `Hint` diagnostics
(`source: "geode"`) suggesting Geode features. The MCP `validate` and
`diagnostics` tools return the same suggestions. They are static: the
engine reads the query only, not the schema or the indexes that exist.

Each suggestion's range covers the token it is about (SONNY-6511): the
property or field name, `count`, or the `*` of a variable-length path. The
AST carries no source positions, so the engine finds the token in the
document text: the n-th suggestion naming a token goes to its n-th whole-word
occurrence outside string literals and comments, and one whose token is not
found goes to the start of the first statement. LSP ranges are 0-based; the
MCP `validate` tool reports 1-based lines and columns, like its parse
errors, with an exclusive end column. An error of the engine (out of memory)
fails the request instead of answering without suggestions.

| Code | Severity | Fires on |
| ---- | -------- | -------- |
| `geode/suggest-encrypted` | Information | A pattern property or graph-type field named `password`, `secret`, `token`, `api_key`, `apikey`, `ssn`, `credit_card`, `creditcard`, `pin`, `private_key` or `privatekey` (a graph-type field already annotated `@encrypted` or `@searchable` is skipped) |
| `geode/suggest-searchable` | Hint | The same for `email`, `phone`, `address`, `dob`, `date_of_birth`, `passport`, `phone_number`, `phonenumber` |
| `geode/suggest-vector-index` | Hint | A pattern property named `embedding`, `embeddings`, `vector`, `vectors` or `features` |
| `geode/suggest-index` | Hint | `n.p = …` in a `WHERE` or `FILTER`, and `ORDER BY n.p` |
| `geode/suggest-fulltext-index` | Hint | `n.p CONTAINS …` or `n.p STARTS WITH …` in a `WHERE` or `FILTER` |
| `geode/suggest-coalesce` | Hint | `n.p IS NULL` in a `WHERE` or `FILTER` |
| `geode/suggest-path-mode` | Information | A variable-length relationship (`-[*1..5]->`) under the default `WALK` mode, outside a shortest-path search |
| `geode/suggest-degree` | Hint | `count(x)` of a variable in `RETURN` |

The label in an index suggestion is the first label of the node the
variable is bound to in the `MATCH` (`Label` when it has none).

## TTL cache and DDL invalidation

`SchemaProvider` (`src/cli/lsp/schema_provider.zig`) sits between the LSP
features and the in-process schema introspection layer. It:

- Caches `getLabels()`, `getEdgeTypes()`, and `getPropertiesFor(label)` for
  `DEFAULT_TTL_NS = 5s` (configurable via `provider.ttl_ns`).
- Holds a `std.Io.Mutex` so concurrent semantic-tokens + completion requests
  on the same session are safe.
- Registers an invalidation callback with `schema_change_notifier` so that
  any successful `CREATE GRAPH`, `DROP GRAPH`, `GRANT … ON GRAPH …`, or
  `REVOKE …` fires `notify()` and drops the cache.

Without a notifier the TTL alone bounds staleness to ≤5 seconds.

## Limitations

- **Tokens are refused.** The embedded listener still checks an
  `authToken` against its own `AuthProvider` (`verifierFromAuthProvider`),
  which holds no API keys or session tokens: log in with a user name and
  password (above). The geode-ui WS bridge must send them in
  `initializationOptions.geode`. The listener stops on SIGTERM: it closes
  open sessions and waits up to 5 s for them before it frees the provider
  (SONNY-6374).
- **Property completion is empty for nodes written since boot through the
  write fast paths.** The schema index the LSP reads (the primary store's
  label-property counters) is not maintained by `executeBulkSimpleCreate`
  and the other storage-adapter fast paths, so `n.` offers no keys for such
  nodes (labels are listed). Reported with SONNY-6589.
- **Property catalog is a live scan.** `listPropertiesForLabel` walks every
  node carrying the requested label in the requested tenant on every call
  (cached for the TTL window). This is O(n) in matching nodes; a persistent
  incremental property catalog is follow-on work (Plan E in the original
  plan).
- **Hot-path DDL is not in the notifier set.** Per-row writes that introduce
  a new label or edge type via `CREATE`/`MERGE` do not fire
  `schema_change_notifier.notify()` — the TTL handles freshness within the
  5-second window. The notifier covers structural DDL only (CREATE/DROP
  GRAPH, GRANT/REVOKE).
- **Auth verifier is a vtable.** `AuthState.verify` takes a `?Verifier`
  rather than depending directly on `src/security/authn.zig`. This decouples
  the LSP from the live AuthProvider so that the LSP's own tests can pass
  without the authn migration. The adapter from `*authn.AuthProvider` to
  `Verifier` is a single small function that takes a token and tries
  `.bearer_token` then `.session_token` against the provider — the same
  precedence the QUIC handler uses.

## Follow-on work (out of scope for this plan)

> **Current state (GAP-0820..0824, 2026-06-10):** the methods named in Plans B–D
> below currently ship as **honest non-support** (-32601, unadvertised) — see the
> "Explicit non-support" note above. These plans would *replace* that
> non-support contract if/when pursued; until then the -32601 behavior is the
> tested, intended contract, not a missing wire-up.

- **Plan B**: `textDocument/codeAction` quick fixes (auto-rename to closest
  label, add `LIMIT`, wrap `CREATE` as `MERGE`, etc.).
- **Plan C**: `workspace/executeCommand` for `geode.explainQuery`,
  `geode.profileQuery`, `geode.refreshSchema`.
- **Plan D**: `workspace/symbol` cross-document search and
  `textDocument/rename` for variables-in-scope.
- **Plan E**: Persistent incremental property catalog (replace
  `listPropertiesForLabel`'s live scan with O(1) lookups on writes).
- **Plan F**: UI affordances in `geode-ui` — schema browser panel that
  mirrors LSP data, "Run with EXPLAIN" button, format-on-save, settings
  page for completion sources.
- **Token auth**: the embedded listener takes a user name and password
  (SONNY-6589). Tokens would need the server to issue API keys or session
  tokens, which it does not (SONNY-6554).

## Build & test reference

```bash
# Build the geode binary (includes embedded LSP listener).
zig build

# Run only the LSP-touching unit suites (fast).
zig build test-schema-provider      # 5 tests
zig build test-completion-context   # 7 tests
zig build test-auth                 # 6 tests
zig build test-tcp-transport        # 1 test
zig build test-lsp-embedded-e2e     # 1 test

# Run the standalone LSP TCP listener (no auth — terminal editor mode).
./zig-out/bin/geode lsp --no-auth

# A network-listening standalone LSP: it has no user store, so every
# initialize is refused (fail closed); use geode serve's listener.
./zig-out/bin/geode lsp --listen=tcp://127.0.0.1:3142

# Run the embedded LSP listener alongside QUIC.
./zig-out/bin/geode serve --listen 0.0.0.0:3141 --lsp-port=3142
# (--lsp-port=0 disables; --lsp-bind-all opens 0.0.0.0 instead of loopback.)
# Without --lsp-port the port comes from GEODE_LSP_PORT, else 3142; the flag
# wins over the variable. GEODE_LSP_PORT=0 disables the listener (the test
# build sets it for every test that spawns geode, SONNY-6332).
```

geode-ui side (browser/Monaco client):

```bash
cd ../geode-ui
npm test                     # full Jest suite (includes LSP client tests)
go test ./internal/server/   # Go bridge tests (incl. /ws/lsp)
```
