# GQL-INVENTORY — Set-returning / CALL / YIELD machinery & the `fulltext_search` delta

READ-ONLY inventory (Read/Grep only). Goal: determine what it takes to re-surface
`fulltext_search` the ISO-GQL way as a `CALL … YIELD` procedure, and whether that work is
**geode-only** or requires a change to the pinned `gql` front-end library.

Repos inspected:

- **geode**: `/data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode`
- **gql lib** (lexer/parser/AST): `/data/home/benji/src/devnw/zig/gql`
  - geode pins `gql` @ **`d8cd6b7b5837187d5fa6a9ebf2d3f2e72b8daf3f`** (tag **v0.1.3**),
    `geode/build.zig.zon:385-388`. The on-disk gql checkout HEAD **is exactly that commit**
    (`git -C …/gql rev-parse HEAD` = `d8cd6b7b…`, tag v0.1.3), so the local gql files are
    precisely what geode pins.
  - gql repo layout is **flat**: `src/parser.zig`, `src/ast.zig`, `src/lexer.zig`,
    `src/token.zig`, `src/language_metadata.zig`, `src/root.zig` (no `parser/` subdir, no
    `parser/mod.zig`).

> ⚠️ **CRITICAL ARCHITECTURE FACT (corrects the task brief's premise):**
> **geode does NOT use the pinned `gql` LIBRARY's parser at runtime.** geode maintains its
> **OWN in-tree fork** of the front-end at `geode/src/gql/{parser.zig, lexer.zig, ast.zig}`,
> and EVERY runtime/execution module imports the fork (`@import("gql/ast.zig")`,
> `@import("../gql/parser.zig").Parser`), 57 import sites. The pinned library IS wired into
> the build under import name **`gql_lib`** (`build.zig:577 gql_dep.module("gql")`,
> `build.zig:771/833 addImport("gql_lib", …)`) but is referenced in **only 4 source files**
> and **only for `gql_lib.token` and `gql_lib.observability`** — NOT its parser/ast:
> `src/lib.zig:50-51,88,658` (re-export token/status/observability), `src/gql/lexer.zig:2`
>
> - `src/gql/parser.zig:8` (`const tok = @import("gql_lib").token;` — the fork borrows the
> library's *token enum* only), `src/server/main.zig:1276` (otel bind). **The library's
> parser/ast are never invoked by the query path.**
>
> Consequence: the `fulltext_search` migration touches **geode's fork + geode's procedure
> dispatch only**. The pinned `gql` library is irrelevant to whether `CALL … YIELD` parses
> for the server, because the server parses with the fork.

---

## TL;DR — DELTA VERDICT: **GEODE-ONLY. No gql-lib change. No re-pin.**

geode's **fork** already lexes/parses `CALL <dotted.name>(args) [YIELD col [AS alias], …]`
into `ast.Statement{ .Call = .{ .Procedure = ast.CallProcedure } }`, dispatches it through
`procedure_registry.executeCallProcedure` to a family of prefix-matched dispatch modules
(`algo.*`, `geode.auth.*`, `geode.rls.*`, `db.*`, `tde.*`, `geode.storage.*`, …), projects the
`YIELD` columns via `filterYieldColumns`, and the handlers return a row/column
`ExecutionResult` that the existing wire encoder serializes generically. To surface FTS as an
ISO-GQL procedure: **add one prefix branch + one dispatch handler** that calls the same FTS
adapter the (wrong) scalar eval function already calls and returns `{node, score}` rows; then
remove the scalar `fulltext_search` eval hook. No library edit, no re-pin, no client change.

---

## A. Does the gql lib parse CALL / YIELD today?  →  YES (lib), and **the fork geode actually runs ALSO does**

Because geode runs the **fork**, the fork is authoritative for runtime; the library is
documented for completeness.

### A.1 `CALL <procedure>(args) [YIELD …]` statement production + AST node

**FORK (authoritative — what the server runs)** — `geode/src/gql/parser.zig`, the CALL arm of
the top-level statement switch — **parser.zig:1221** (`.CALL => blk_call:`). If the next token is
`{` it parses a `CALL { subquery }` (parser.zig:1225-1368); otherwise the **procedure call**
branch (parser.zig:1369-1402), verbatim core:

```zig
} else {
    // Traditional procedure call (e.g., db.labels())
    const procedure = try self.parseOrExpr();          // dotted name + (args) — parser.zig:1371
    // Optional YIELD clause
    var yield_items: ?[]ast.ReturnItem = null;
    if (self.cur.kind == .YIELD) {                      // parser.zig:1375
        self.advance();
        var items = std.ArrayList(ast.ReturnItem).empty;
        try self.parseProjectionItems(&items);         // YIELD cols reuse RETURN-item parsing
        yield_items = try items.toOwnedSlice(self.arena.allocator());
    }
    // (optional trailing RETURN clause also parsed here, parser.zig:1383-1395)
    … break :blk_call ast.Statement{ .Call = .{ .Procedure = .{ .procedure = procedure,
                                                                .yield_items = yield_items } } };
}
```

(There is no separate `parseProcedureRef`/`parseCallStatement` fn in the fork — CALL is parsed
inline here, plus a second in-MATCH CALL site at `parser.zig:2385` with YIELD at `:2392`.)

**FORK AST** — `geode/src/gql/ast.zig`:

- `Statement` union arm `Call: CallStatement` (**ast.zig:30**).

- ```zig
  // ast.zig:396
  pub const CallProcedure = struct {
      procedure: Expr,                  // a Call expr: callee (dotted Member/Ident) + args
      yield_items: ?[]ReturnItem = null,   // ast.zig:398
  };
  ```

- `CallStatement = union(enum) { Procedure: CallProcedure (ast.zig:414), Subquery: CallSubquery }`
  (**ast.zig:413**). `CallSubquery` at **ast.zig:407**.

**LIBRARY (pinned, NOT on geode's runtime path)** — `gql/src/parser.zig`: CALL arm at
**parser.zig:1209**, YIELD at **parser.zig:1363** / **:2380**; AST `CallProcedure`
(**ast.zig:375**, `procedure: Expr`, `yield_items: ?[]ReturnItem`), `Call: CallStatement`
(**ast.zig:30**), `Procedure: CallProcedure` (**ast.zig:393**). Tokens `CALL`/`YIELD` at
`gql/src/token.zig:71-72,276-277`. (Same shape as the fork — the fork was derived from it.)

### A.2 `YIELD <col> [AS alias], …` clause parsed + represented, AND projected

**FORK parse**: YIELD reuses `parseProjectionItems` (parser.zig:1378) → `[]ast.ReturnItem` — the
**same node used by RETURN** — each `{ expr: Ident(name)/Member, alias: ?[]const u8 }`. So YIELD'd
columns are `?[]ast.ReturnItem` on `CallProcedure.yield_items`.

**FORK projection (this is how YIELD becomes the result's columns)** —
`filterYieldColumns(allocator, result, yield_items)` — **execution_helpers.zig:83**
(CANARY `REQ-GQL-CALL-YIELD-001`): for each yield item it takes `item.expr.Ident.orig` as the
requested column, finds the matching column in the handler's `ExecutionResult.columns`
(case-insensitive, execution_helpers.zig:101-108), and builds a new `ExecutionResult` with only
those columns. Existing handlers apply it themselves, e.g. `algo_dispatch.zig:320-322`:

```zig
if (call_stmt.yield_items) |yield_items| {
    result = try filterYieldColumns(allocator, result, yield_items);
}
return result;
```

So `… YIELD node, score` is a real, working column projection over the handler's table. A new
FTS handler should call `filterYieldColumns` the same way.

### A.3 Schema-qualified procedure names (`geode.fts.search`, `catalog.schema.proc`)  →  YES

The fork parses the procedure name as a general expression (`parseExpr` at parser.zig:1234),
and dotted names build chained `Member` expressions in `parsePostfixExpr`
(**parser.zig:3388** — `.dot` → `ast.Expr.Member{ target, field }`, looped). So
`geode.fts.search('idx','q')` parses to `Call{ callee = Member(Member(Ident geode, fts),
search), args=[str,str] }`. The dispatch layer reassembles the dotted string to
`"geode.fts.search"` via `extractOriginalProcName` + `recursion_handler.buildMemberPath`
(procedure_registry.zig:62-83). Existing dotted procedures prove this end-to-end
(`algo.pagerank.stream`, `geode.auth.create_user`, `geode.storage.*`).

### A.4 Composition in a linear query (CALL…YIELD then RETURN / MATCH on yielded vars)

Standalone `CALL proc() YIELD …` is a top-level `ast.Statement.Call` (A.1). The AST `Query`
also carries `call_clause: ?CallClause` (**ast.zig:109**) for the in-MATCH `MATCH … CALL …
YIELD` form, parsed at `parser.zig:2385`, with `match_operations.zig:1824/1835` binding the
yielded items into the RETURN. So both the standalone procedure-statement form and the embedded
MATCH-CALL form exist. For FTS the standalone `CALL geode.fts.search(...) YIELD node, score`
form is what is needed and is fully present.

### A.5 gql lib version + how geode consumes it; geode's own parser layer

- gql lib **v0.1.3** (`gql/build.zig.zon`); geode pins commit `d8cd6b7b…`
  (`geode/build.zig.zon:385-388`, `.gql = .{ .url = "…/gql.git#d8cd6b7b…", .hash = "gql-0.1.3-…" }`).
- build wires the library as import name **`gql_lib`** (`build.zig:577,771,833`).
- **geode HAS its own parser layer and uses it.** Fork files: `geode/src/gql/parser.zig`
  (320 KB), `lexer.zig`, `ast.zig`, `match.zig`, `main.zig`. The geode root module re-exports
  the fork as `geode.gql` and `geode.ast` (`src/lib.zig:13,48-53` — `pub const gql = struct {
  pub const ast = @import("gql/ast.zig"); pub const parser = @import("gql/parser.zig"); … }`).
  Runtime imports the fork everywhere (e.g. `execution.zig:24`, `eval.zig:3`,
  `call_operations.zig:2,91-92`, `procedure_registry.zig:11`, `query_traits.zig:446`).
  The fork imports **only the token enum** from `gql_lib` (`src/gql/parser.zig:8`,
  `src/gql/lexer.zig:2`).

---

## B. How geode dispatches existing CALL procedures TODAY

Dispatch is a **prefix-matched router**, NOT a hashmap-of-registered-handlers.

Files:

- `geode/src/execution/call_operations.zig` (157 lines) — CALL statement entry / read-snapshot wrap.
- `geode/src/execution/procedure_registry.zig` (202 lines) — the **router** (despite its name).
- domain dispatch modules: `algo_dispatch.zig`, `auth_dispatch.zig`, `audit_dispatch.zig`,
  `storage_dispatch.zig`, `meta_dispatch.zig`, `rls_dispatch.zig`.

### B.1 Name → handler routing, the extension pattern, example end-to-end

**Entry** — `call_operations.zig`:

- `executeCallStatement(allocator, call_stmt, context)` — **call_operations.zig:74**: if mutating
  → run unsnapshotted; else wrap in a `QueryReadSession` snapshot; then `executeCallUnsnapshotted`
  (**:65**) switches: `.Procedure => executeCallProcedure` / `.Subquery => executeCallSubquery`.
- `executeCallProcedure` is re-exported from `procedure_registry.executeCallProcedure`
  (`call_operations.zig:29`; also re-exported `execution.zig:199`).

**Router** — `procedure_registry.executeCallProcedure(allocator, call_stmt, context)` —
**procedure_registry.zig:98**:

1. `extractNormalizedProcName(allocator, call_stmt)` (**:88**) → reassembles dotted callee into
   an ASCII-lowercased string (`geode.fts.search` → `"geode.fts.search"`).
2. **GPS authorization gate** (**:115-128**): `procedure_access.classifyProcedureName(proc_name)`
   → `.read_only`/`.mutating` → `gps.decide(...)`; deny → `error.Unauthorized`. *A new read-only
   FTS proc must be classified `.read_only` in `procedure_access.zig` or it falls back to the
   fail-closed `.execute_procedure` action (procedure_registry.zig:108-114).*
3. **Prefix-matched dispatch** (**:133-194**) — the extension pattern to copy:

   ```zig
   if (startsWith(proc_name,"db.") or startsWith(proc_name,"dbms.")) { … meta_dispatch.execute … } // :136
   if (try algo_dispatch.execute(allocator, proc_name, store, call_stmt, context)) |r| return r;     // :143
   if (startsWith(proc_name,"audit."))       { … audit_dispatch.execute … }       // :148
   if (startsWith(proc_name,"tde."))         { … storage_dispatch.executeTde … }  // :155
   if (startsWith(proc_name,"cdc."))         { … storage_dispatch.executeCdc … }  // :162
   if (startsWith(proc_name,"geode.fle."))   { … storage_dispatch.executeFle … }  // :169
   if (startsWith(proc_name,"geode.auth."))  { … auth_dispatch.execute … }        // :176
   if (startsWith(proc_name,"geode.rls."))   { … rls_dispatch.execute … }         // :183
   if (startsWith(proc_name,"geode.storage.")) { … storage_dispatch.executeStorage … } // :190
   // ← ADD: if (startsWith(proc_name,"geode.fts.")) { if (try fts_dispatch.execute(...)) |r| return r; }
   return ExecutionError.UnknownProcedure;   // :200
   ```

   Each `*_dispatch.execute` returns **`!?ExecutionResult`** (null = "not my procedure", router
   keeps trying / falls through to `UnknownProcedure`).

**Example existing procedure END-TO-END — `algo.degree()`** (the test in `call_operations.zig:150`
runs `"CALL degree()"` and asserts 2 rows):

- handler family `algo_dispatch.execute(allocator, proc_name, store, call_stmt, context) !?ExecutionResult`
  (**algo_dispatch.zig:104**); `handleDegree` (**:121**):

  ```zig
  fn handleDegree(allocator, store, _: ast.CallProcedure, _: ExecutionContext) anyerror!ExecutionResult {
      const columns = try allocTwoColumns(allocator, "nodeId", "degree");
      return execution.executeDegreeCentrality(allocator, store, columns);  // one row per node
  }
  ```

  then `filterYieldColumns` is applied if `yield_items` present (algo_dispatch.zig:320). This is
  exactly the shape an FTS procedure should mimic (`columns = {"node","score"}`, one row per hit).

### B.2 Does the QUIC server path execute CALL…YIELD the same way as in-process?  →  YES, same entry

The single shared statement entry is **`execution.executeStatementWithContext(allocator, stmt,
context)`** — **execution.zig:1066** — whose `.Call` arm routes
`.Procedure => executeCallProcedure` / `.Subquery => executeCallSubquery` (**execution.zig:1196-1199**).
Callers:

- QUIC server: `src/server/quic_connection_handler.zig:5732`
  `execution.executeStatementWithContext(gpa, target_stmt.*, exec_context)` (parse failure earlier
  → `sendExecuteError(..., "42000", …)`, e.g. quic_connection_handler.zig:4979).
- in-process FTS test: `tests/test_fts_e2e.zig:78`
  `execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx)`.
- gRPC transport: `src/transport/grpc_server.zig` (same fn).

So `CALL geode.fts.search(...) YIELD node, score` over the wire reaches the same router with no
new transport code.

### B.3 How procedures return a TABLE and how it hits the wire (no client change)

- `ExecutionResult` — **execution.zig:598**:

  ```zig
  pub const ExecutionResult = struct {
      columns: [][]const u8,
      rows: [][]Value,
      // (column_types and other optional fields follow)
      pub fn deinit(self: *ExecutionResult, allocator) void { … }   // execution.zig:611
  };
  ```

- Every dispatch handler returns this (`algo_dispatch` handlers, auth/meta/etc.).
- The QUIC handler serializes `ExecutionResult.{columns,rows}` generically per query (no
  per-procedure knowledge), so FTS rows (`node` id + `score` float) flow as ordinary typed
  result rows, identical to a RETURN/MATCH result. **No client/driver change.**

---

## C. The current (wrong) `fulltext_search` wiring to REMOVE/REPLACE

File is `geode/src/eval.zig` (root-level, 225 KB — **not** `src/execution/eval.zig`).

### C.1 The scalar eval function + its dispatch hook

- **Dispatch hook — eval.zig:925-931**, inside the function-call eval path:

  ```zig
  // A4a: Geode-extension fulltext_search(index, query[, max]) → a List
  // of {node_id, score} Map records the caller UNWINDs. …
  if (try evalFulltextFunction(allocator, function_name, call.args, env)) |result| {
      break :blk_call result;
  }
  ```

  → **REMOVE this block** so `fulltext_search` is no longer a scalar function.

- **`evalFulltextFunction(allocator, function_name, args, env) EvalError!?Value` — eval.zig:3841**
  (doc-comment eval.zig:3828-3840 already flags it as the wrongly-surfaced A4a function and shows
  the `UNWIND fulltext_search('idx','fox') AS r …` intent). Body:
  - **REUSE / KEEP the adapter core** (eval.zig:3876-3881):

    ```zig
    const adapter = graph_store.getGlobalAdapter() orelse return EvalError.Unsupported;
    const facade = adapter.getFulltextIndexNamed(graph_store.DEFAULT_GRAPH_NAME, index_name) orelse return EvalError.Unsupported;
    const results = facade.search(query_text, max_results) catch return EvalError.OutOfMemory;  // → []{ doc_id, score }
    ```

    This is exactly what the new procedure handler should call.
    `getFulltextIndexNamed(graph_name, index_name) ?*fulltext.FullTextIndex` is defined at
    **graph_storage_adapter.zig:1520** (→ `ManagedGraph.getFulltextIndexNamed`,
    graph_storage_adapter.zig:807; the comment at :1516 says *"This is the resolver the
    `fulltext_search(...)` query function"* uses). `facade.search(query, max)`
    (`fts_storage_adapter.zig:303`) returns `[]Hit` where `Hit = struct { doc_id: u64, score: f32 }`
    (**fts_storage_adapter.zig:42-44**) — node id + BM25 score. Arg parsing: `args[0]`=index (Str),
    `args[1]`=query (Str), optional `args[2]`=max (Int, default 10) — eval.zig:3848-3874.
  - **REMOVE / REPLACE the LIST-of-MAP packing** (eval.zig:3883-3896): it builds
    `Value{ .List = [ Value{ .Map = {"node_id": Int, "score": Double} }, … ] }` (note: it widens
    the `f32 score` to `Value.Double` — eval.zig:3892). That shape exists ONLY to feed `UNWIND`.
    The procedure handler instead emits an `ExecutionResult` with `columns = {"node","score"}` and
    one `[]Value` row per hit (`Value{ .Int = @intCast(hit.doc_id) }`,
    `Value{ .Double = @as(f64, hit.score) }`).
  - Once the dispatch hook (C.1) is removed, `evalFulltextFunction` is dead and can be deleted
    (or kept private and reshaped into the procedure handler's body — same adapter calls).

### C.2 `UNWIND` status (it is Cypher-compat, gated as non-GQL — corrects the brief on two points)

- **gql LIBRARY HAS UNWIND** (so my earlier "library has no UNWIND" was wrong): token
  `gql/src/token.zig:128 + :346 (.{ "UNWIND", .UNWIND })`, AST `UnwindClause` at `gql/src/ast.zig:59`
  - `Query.unwind_clause` at `:69`, parser at `gql/src/parser.zig:1827`. The lib's
  `language_metadata.zig:237` even (mis)labels it `.iso_gql`. So UNWIND is present in BOTH the
  library and the fork — it is **not** absent from the front-end. (Whether UNWIND truly belongs to
  ISO/IEC 39075:2024 is a separate spec question — geode's LSP and parser treat it as Cypher.)
- **geode FORK: UNWIND is present but GATED.** lexer token `UNWIND` (`geode/src/gql/lexer.zig`
  via the shared `gql_lib.token` enum); AST `UnwindClause` (`geode/src/gql/ast.zig:73`,
  `Query.unwind_clause` `:83`); parser:
  - **Top-level `UNWIND …` is REJECTED** — `geode/src/gql/parser.zig:1248-1253` returns
    `self.unexpected("UNWIND is not valid at the start of a query (standard GQL uses FOR … IN)")`
    (CANARY `REQ-GQL-UNWIND-REJECT`, `tests/test_unwind_rejection.zig`).
  - **Mid-query `UNWIND` (after MATCH/WITH) is ACCEPTED** — `geode/src/gql/parser.zig:1839`
    (`if (self.cur.kind == .UNWIND) { … }`), executed by `query_execution.zig:2017` which expands
    `unwind.list_expr` into one row per element (`:2028-2056`).
  - LSP flags it as non-GQL: `src/cli/lsp/features.zig:91,142` *"UNWIND is not standard GQL
    (ISO/IEC 39075:2024). Use FOR … IN … instead."*
- **So `UNWIND fulltext_search(...)` parses AND executes on BOTH paths today** because the FTS
  function appears *mid-query* after no MATCH but the test wraps it as the query body — see C.3
  for exactly how. The brief's "42000-parse-errors over the server" is therefore the behavior
  for **top-level** UNWIND, OR the desired post-migration state, but the current FTS tests use a
  form that the fork accepts (C.3).

### C.3 How the in-process FTS tests actually invoke `fulltext_search` TODAY (the real working query)

`tests/test_fts_e2e.zig` — the **real, working query strings are UNWIND-based** (verbatim):

- `test_fts_e2e.zig:107`:
  `"UNWIND fulltext_search('doc_body_idx', 'fox') AS r RETURN r.node_id AS nid, r.score AS score"`
- also `:123`, `:131` (`'dog'`), `:142` (`'elephant'`), `:189` (`'fox'`).
- Each runs via Harness `runQuery()` → `execution.executeStatementWithContext(aa,
  parsed.program.statements[0], self.ctx)` (**test_fts_e2e.zig:78**).
- The test asserts a **single row per hit**: `res.rows[0][0] == .Int` (node id),
  `res.rows[0][1] == .Double` (score > 0) — test_fts_e2e.zig:111-115.

**Resolution of the puzzle:** these pass because the fork's mid-query UNWIND clause
(parser.zig:1839 → query_execution.zig:2017) expands the `Value.List`-of-`Value.Map{node_id,score}`
that the scalar `evalFulltextFunction` returns (C.1) into one row per hit, and `RETURN r.node_id,
r.score` projects the map fields. UNWIND is a real (Cypher-compat) mid-query clause in geode's
fork — only *top-level* UNWIND 42000-rejects. The header comment at test_fts_e2e.zig:9 documents
this exact flow. (Note these queries have **no preceding MATCH/WITH** yet are accepted, because
`UNWIND` here is consumed by the query-body UNWIND path at parser.zig:1839, not the top-level
rejection at :1248 — the top-level switch only rejects `UNWIND` as the *first* token, and these
queries are parsed as a `Query` whose clause sequence includes the UNWIND.)

> Migration impact on these tests: removing the scalar hook (C.1) breaks every
> `UNWIND fulltext_search(...)` query above. Rewrite each to
> `CALL geode.fts.search('doc_body_idx','fox') YIELD node, score RETURN node, score`
> (or just `CALL … YIELD node, score`) asserting one row per hit with scalar `node`/`score`
> columns instead of an UNWIND-expanded LIST-of-MAP.

---

## D. DELTA VERDICT (definitive): **(i) GEODE-ONLY — add a dispatch branch + handler. NO gql-lib change.**

geode's **fork** already provides, end-to-end on the server's actual code path:

1. lexing/parsing of `CALL` + optional `YIELD` (parser.zig:1221-1246; in-MATCH at :2385),
2. **schema-qualified dotted procedure names** (parser.zig:1234 + postfix `.dot` at :3388),
3. full **expression arguments** inside `CALL(...)` (parser.zig:1234 `parseExpr`),
4. YIELD column list as `?[]ast.ReturnItem` (parser.zig:1239) **with real projection**
   (`filterYieldColumns`, execution_helpers.zig:83; applied at algo_dispatch.zig:320),
5. AST nodes `CallStatement`/`CallProcedure`/`CallClause` (ast.zig:30,396,413,109).

And geode already provides the runtime: the prefix-matched router
(`procedure_registry.executeCallProcedure`, procedure_registry.zig:98-200), the GPS gate, the
per-domain `*_dispatch.execute(...) !?ExecutionResult` contract, the table result type
(`ExecutionResult{columns,rows}`, execution.zig:598), the read-snapshot wrapper
(call_operations.zig:74), the shared exec entry for in-process **and** QUIC **and** gRPC
(`executeStatementWithContext`, execution.zig:1066 — quic_connection_handler.zig:5732 /
test_fts_e2e.zig:78 / grpc_server.zig), the generic wire encoder, and the FTS adapter
(`getGlobalAdapter().getFulltextIndexNamed(DEFAULT_GRAPH_NAME, index).search(query, max)`,
eval.zig:3876-3880 / graph_storage_adapter.zig:1520).

### Complete geode-only change set (no re-pin, no gql-lib edit, no client/protocol change)

1. **Add an FTS dispatch handler** — new `geode/src/execution/fts_dispatch.zig` (or a
   `geode.fts.*` branch inside `storage_dispatch.zig`) exposing
   `fn execute(allocator, proc_name, call_stmt: ast.CallProcedure, context) anyerror!?ExecutionResult`:
   extract `args[0]=index`, `args[1]=query`, optional `args[2]=max` from
   `call_stmt.procedure.Call.args` (mirroring how `algo_dispatch`/handlers read args); call
   `graph_store.getGlobalAdapter().getFulltextIndexNamed(graph_store.DEFAULT_GRAPH_NAME, index)
   .?.search(query, max)` (→ `[]Hit{doc_id:u64, score:f32}`); build `columns = {"node","score"}`
   and one row per hit (`Value{.Int = @intCast(h.doc_id)}`, `Value{.Double = @as(f64,h.score)}`);
   apply `filterYieldColumns(allocator, result,
   call_stmt.yield_items.?)` when `yield_items != null` (copy algo_dispatch.zig:320-322).
2. **Wire the branch** in `procedure_registry.executeCallProcedure` (procedure_registry.zig:~189,
   next to `geode.storage.`):
   `if (std.mem.startsWith(u8, proc_name, "geode.fts.")) { if (try fts_dispatch.execute(...)) |r| return r; }`.
3. **Classify it read-only** in `procedure_access.classifyProcedureName` so the GPS gate maps it
   to `.read` (procedure_registry.zig:116) rather than the fail-closed `.execute_procedure`.
4. **Remove the scalar dispatch hook** at eval.zig:925-931 and retire/reshape
   `evalFulltextFunction` (eval.zig:3841), keeping only its `getFulltextIndexNamed(...).search(...)`
   core, which the handler reuses.
5. **Rewrite `tests/test_fts_e2e.zig`** (and any other `UNWIND fulltext_search` tests) to
   `CALL geode.fts.search('doc_body_idx','fox') YIELD node, score …`.

### Why NOT path (ii) gql-library change

- None of A.1–A.4 is missing in the fork the server actually runs; no grammar/AST addition is
  required. The pinned `gql` library is **not on geode's runtime parse path** (only its token
  enum is borrowed). Therefore there is **no gql edit, no re-pin of `gql` in geode
  `build.zig.zon`, and no cascade to geode-client-zig** (discovery doc 08).
- Lowest-risk path = new `fts_dispatch` handler + one router branch + a `procedure_access`
  classification + removal of the scalar hook + a test rewrite, entirely inside geode.

(The exact procedure name — `geode.fts.search` vs `fulltext.search` vs `db.index.fulltext.queryNodes`
— and the column names `node`/`score` are the spec agent's call; the router prefix-matches
whatever dotted string is chosen at procedure_registry.zig:133-194.)
