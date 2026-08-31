# FOR var IN $param — parameter-bound list collapses to one null iteration

Status: **root cause not yet located; live-reproduced and isolated on dev `235fc55`**
Date: 2026-08-31
Reporter: dgx-spark-playbooks / knowledge-graph ingestion project (external caller)
Relates to: GitLab devnw/codepros/geode/geode#876 (see "Relationship to #876" below)

## Summary

`FOR var IN <list> <write-clause>` (geode's GQL+ equivalent of Cypher's `UNWIND`
for driving batch `CREATE`/`MERGE`/`MATCH...SET` from a list) works correctly
when `<list>` is an **inline literal**. The moment `<list>` is a **bound
parameter** (`$name`, supplied via `--param` / the wire protocol's params map),
the loop no longer iterates the list at all — it silently executes its body
**exactly once**, with the loop variable bound to `NULL`, regardless of the
list's length or element type. This reproduces identically for `RETURN`
projections and for write bodies (`CREATE`), and for both scalar lists and
lists of maps.

This makes `FOR...IN` unusable for real application batch-write workloads:
callers who parameter-bind their data (the only safe way to pass user/document
content without building GQL query text via string interpolation — see the
several ENG-3903-family injection-surface fixes this project has already
landed against `geode`) get one silently-empty-fielded row instead of a
population of correctly-bound rows.

## Version

- Server: `geode:dev`, build `235fc55` (image digest
  `sha256:a2aa5753a1e93ec1c581c52b8c458bdc81fe9acdfe10648d61a02c3da955379f`,
  pulled 2026-08-31).
- Client: `geode` CLI bundled in the same image (`docker exec ... geode query`).
- Isolated single-node container, QUIC transport, default auth
  (`GEODE_ADMIN_PASSWORD=geodesic`).

## Reproduction

```bash
docker run -d --name geode-forin-test -e GEODE_ADMIN_PASSWORD=geodesic \
  -p 127.0.0.1:3185:3141/udp \
  registry.gitlab.com/devnw/codepros/geode/geode:dev \
  serve --data-dir /data --listen 0.0.0.0:3141

Q() { docker exec -e GEODE_ALLOW_INSECURE_TLS=1 geode-forin-test \
        geode query --server 127.0.0.1:3141 --insecure-tls-skip-verify \
        -U geode -P geodesic "$@"; }
```

### 1. Inline literal list — works correctly (control)

```bash
Q 'FOR i IN [1,2,3] RETURN i'
```
```json
{"status_class":"00000", ...,
 "columns":[{"name":"?column?","type":"INTEGER"}],
 "rows":[{"?column?":1},{"?column?":2},{"?column?":3}]}
```
3 rows, correct values, correct order.

```bash
Q 'FOR row IN [{a:1,b:"x"},{a:2,b:"y"}] RETURN row.a AS a, row.b AS b'
```
```json
{"rows":[{"a":1,"b":"x"},{"a":2,"b":"y"}]}
```
Property (dot) access on the loop variable also works correctly for inline
lists-of-maps.

### 2. Parameter-bound scalar list — broken

```bash
Q --param nums '[10,20,30]' 'FOR n IN $nums RETURN n AS v'
```
```json
{"status_class":"00000", ...,
 "columns":[{"name":"v","type":"NULL"}],
 "rows":[{"v":null}]}
```
**Exactly one row, `v: null`.** Expected 3 rows with `v` = 10, 20, 30.

Confirmed the parameter itself deserializes correctly and is a real 3-element
list when NOT consumed by `FOR`:
```bash
Q --param nums '[10,20,30]' 'RETURN size($nums) AS n'
# -> {"rows":[{"n":3}]}   (correct — the param IS a 3-element list server-side)
```
So the defect is specific to `FOR`'s collection-expression evaluation, not to
parameter deserialization in general.

### 3. Parameter-bound list of maps — same defect, plus write body

```bash
Q --param rows '[{"docId":"a.md","seq":0,"text":"alpha"},{"docId":"a.md","seq":1,"text":"beta"}]' \
  'FOR row IN $rows RETURN row.a AS a, row.b AS b'
# -> {"rows":[{"a":null,"b":null}]}   (one row, both fields null)

Q --param rows '[{"docId":"a.md","seq":0,"text":"alpha"},{"docId":"a.md","seq":1,"text":"beta"}]' \
  'FOR row IN $rows CREATE (c:TC2 {docId: row.docId, seq: row.seq, text: row.text})'
Q 'MATCH (c:TC2) RETURN c.docId AS d, c.seq AS s, c.text AS t ORDER BY c.seq'
# -> {"status_class":"00000","rows":[{}]}                (CREATE ran once)
# -> {"rows":[{"d":null,"s":null,"t":null}]}              (single node, all-null props)
```
Only **one** `TC2` node is created (not two), and its properties are all
`NULL` — consistent with the loop body running exactly once with the loop
variable unbound/null, then property access on `NULL.docId` etc. evaluating to
`NULL`.

### 4. Confirmed the same pattern with `vectorf32`-bearing writes

```bash
Q --param rows '[{"docId":"a.md","seq":0,"text":"alpha chunk","vec":"[0.1,0.2,0.3]"},{"docId":"a.md","seq":1,"text":"beta chunk","vec":"[0.4,0.5,0.6]"}]' \
  'FOR row IN $rows MERGE (c:TC {docId: row.docId, seq: row.seq}) SET c.text = row.text, c.source = row.docId, c.emb = vectorf32(toString(row.vec))'
```
```json
{"status_class":"58000","error_code":"58000","error":"TypeMismatch"}
```
Here it doesn't even get to the null-collapse behavior — it fails outright
with `TypeMismatch` before executing. (Isolated separately: the failure here
is compounded — `toString(row.vec)` where `row` is itself already unresolved
appears to produce a value `vectorf32()` rejects before iteration semantics
even come into play. Reproduce with the simpler cases above first; this one
is included to show the failure mode a real caller hits when combining `FOR
... IN $param` with a per-row `vectorf32(toString(...))` write, which is
exactly what a bulk-ingestion caller needs.)

### 5. Inline-literal write body works fully, including vectors (control)

```bash
Q 'FOR row IN [{docId:"a.md",seq:0,text:"alpha"},{docId:"a.md",seq:1,text:"beta"}] CREATE (c:TC3 {docId: row.docId, seq: row.seq, text: row.text, emb: vectorf32([0.1,0.2,0.3])})'
Q 'MATCH (c:TC3) RETURN c.docId AS d, c.seq AS s, c.text AS t, size(c.emb) AS dim ORDER BY c.seq'
```
```json
{"rows":[{"d":"a.md","s":0,"t":"alpha","dim":3},{"d":"a.md","s":1,"t":"beta","dim":3}]}
```
Both nodes created correctly with distinct properties and 3-dim vectors. This
confirms the entire `FOR...IN <write>` pipeline (parse → per-iteration
environment binding → property access → `vectorf32` → persist) is otherwise
sound — the defect is isolated specifically to resolving the **collection
expression** when it is a parameter reference instead of a literal.

## Isolation summary

| Collection source | Iterates? | Loop var bound? |
|---|---|---|
| Inline literal list of scalars (`[1,2,3]`) | Yes, N rows | Yes, correct values |
| Inline literal list of maps (`[{...},{...}]`) | Yes, N rows | Yes, dot-access works |
| `$param` bound to a scalar list | **No — 1 row** | **No — NULL** |
| `$param` bound to a list of maps | **No — 1 row** | **No — NULL**, dot-access on NULL → NULL |
| `$param` list-of-maps as write body (`CREATE`) | **No — writes once** | **No — all properties NULL** |

`RETURN size($nums)` on the same parameter correctly reports the true list
length, proving the parameter is deserialized correctly server-side and the
defect is local to how `FOR`'s collection-expression is evaluated/iterated.

## Suspected code location (not verified — hand off to owning engineer)

A prior investigation of this codebase for the `FOR...IN` feature (undertaken
to confirm `#876` was fixed) found the relevant implementation at:

- Parser: `src/gql/parser.zig:5776-5929` (`parseForStatement`) — parses the
  `FOR var IN <collection-expr> [WITH ORDINALITY|OFFSET var] <body>` header.
  `<collection-expr>` is presumably parsed as a general expression (it would
  need to be, to accept `range(...)` calls, which are also confirmed working
  inline), so the defect is unlikely to be in the parser accepting `$param`
  syntactically — worth confirming a `$param`-sourced FOR at least *parses*
  distinctly from a literal-sourced one, vs. silently falling into a
  different (broken) execution path.
- AST: `src/gql/ast.zig:832-846` (`ForStatement`).
- Execution: `src/execution/statement_handlers.zig:608-681`
  (`executeForBody`), `:683-721` (`executeForWithBindings`), `:830-860`
  (`executeFor`). One of these is very likely where the collection expression
  gets evaluated to produce the actual Zig-side list to loop over — the
  hypothesis is that this evaluation path handles a literal list AST node
  directly but does not route a `Parameter`/`$name` expression node through
  the general expression evaluator (`evalExpr` — see `src/eval.zig`) to
  resolve it to its bound value before attempting to iterate it, so it either
  treats the unresolved parameter reference as an opaque single value (hence:
  one iteration) or fails to bind anything (hence: NULL loop variable).

None of the above file:line citations were re-verified as part of *this*
report (they carry over from an earlier investigation of the feature's happy
path) — treat them as a starting-point pointer, not a diagnosis.

## Impact

Blocks the only safe usage pattern of `FOR...IN` for real applications:
driving a batch `CREATE`/`MERGE` from **caller-supplied, parameter-bound**
data. Any caller who needs this must currently choose between:

1. **N separate single-row statements** (the status quo every downstream
   caller uses today — safe, but one round trip per row).
2. **Inlining the batch as GQL literals** — works, but reopens the
   query-string-injection and type-formatting problems that parameter binding
   was specifically adopted to close (this project's own migration off
   string-interpolated GQL, e.g. the ENG-3903/ENG-3904/ENG-3911 family of
   fixes, was undertaken for exactly this reason).

There is currently no way to get single-statement batch writes *and* keep
data out of the query string.

## Relationship to #876

The original #876 ("`UNWIND` is completely unparseable") was filed against
Cypher's `UNWIND range(1,3) AS i RETURN i` failing to parse. That report was
mis-scoped: `UNWIND` is a Cypher construct and is *intentionally* out of scope
for geode's GQL+ dialect — it is not expected to be supported, and no fix
should be made to accept it.

The actual capability gap #876 was gesturing at — a way to drive batch
writes from a list in one statement — already has a real, working GQL+
answer: `FOR var IN <list> <write-clause>`, confirmed implemented and working
for inline literals as of 2026-08-29. That part of #876 is **done**; no
further action needed there for the literal-list case.

This report captures the specific remaining gap: the parameter-bound-list
path of that same `FOR...IN` feature. Recommend closing #876 as "not
planned" for the `UNWIND` keyword itself, and tracking this document (or a
GitLab issue filed from it) as the follow-up for the `FOR...IN $param` defect.

## Suggested acceptance criteria for a fix

```bash
geode query --param nums '[10,20,30]' 'FOR n IN $nums RETURN n AS v'
# expected: 3 rows, v = 10, 20, 30 (in order)

geode query --param rows '[{"k":1,"v":"a"},{"k":2,"v":"b"}]' \
  'FOR row IN $rows CREATE (n:T {k: row.k, v: row.v})'
geode query 'MATCH (n:T) RETURN n.k AS k, n.v AS v ORDER BY n.k'
# expected: 2 rows: {k:1,v:"a"}, {k:2,v:"b"}
```
Both should behave identically to the equivalent inline-literal form already
verified working today.
