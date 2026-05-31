# ISO/IEC 39075:2024 (GQL) — Set-Returning / Table-Valued Operations & List Unnesting

**Question answered:** How does standard GQL surface a SET-RETURNING / table-valued operation
(e.g. full-text search returning many `(node, score)` rows), and is there a list-unnesting
construct equivalent to Cypher's `UNWIND`?

**Source of truth used.** The ISO/IEC 39075:2024 PDF was **NOT present** at the path given in the
task brief (`docs/kb/gql/ISO_IEC_39075_2024(en).pdf` does not exist; `docs/kb/gql/` contains only
the three Geode-authored crosswalk/profile/audit `.md` files). The authoritative artifact that
**is** in the repo is the normative ISO grammar itself, shipped verbatim by the standard as a
"digital artifact":

- `grammar/ISO_IEC_39075(en).bnf.txt` (3501 lines) — header reads:
  *"This file is a 'digital artifact' that contains the grammar specified by ISO/IEC 39075. This
  grammar may be used by implementers of GQL-implementations when generating parsers for the GQL
  language."*
- `grammar/ISO_IEC_39075(en).bnf.xml` (9701 lines) — same grammar, XML form.

This BNF is the actual Clause-style production set from the standard (the same `<production> ::=`
rules that appear in the ISO clauses). All citations below are **line numbers in
`grammar/ISO_IEC_39075(en).bnf.txt`**, quoting the productions verbatim. Where the brief asked for
ISO clause numbers, the BNF artifact does not carry the §-numbers inline; the production *names*
below are the standard's own non-terminal names (1:1 with the clause headings in the PDF: e.g.
`<call procedure statement>` = ISO clause "Call procedure statement"; `<for statement>` = ISO clause
"For statement").

---

## VERDICT (headline)

1. **YES — GQL has a procedure-call statement that yields a binding table.** It is
   `<call procedure statement> ::= [ OPTIONAL ] CALL <procedure call>`, and a *named* procedure call
   carries an optional `<yield clause>`. So `CALL <proc>(args) YIELD col, ...` is valid ISO GQL.
   `CALL` is the keyword; `YIELD` is the keyword for the projection. A call is one of the
   alternatives of `<simple query statement>`, so its output rows compose into the surrounding
   linear query and can be consumed by a following `MATCH` / `RETURN`.

2. **NO — there is no `UNWIND` keyword/clause in ISO GQL.** The string `UNWIND` appears **zero**
   times in the entire grammar. The standard's list-unnesting primitive is the **`FOR` statement**
   (`FOR x IN <list value expression>`), which turns a LIST value into one binding row per element —
   functionally the `UNWIND` equivalent — optionally with `WITH ORDINALITY | OFFSET`.

3. **YES — `fulltext_search` must be a PROCEDURE, not a function**, if it is to return rows.
   Only a **procedure** is invokable with `CALL` and can `YIELD` a binding table; a *value function*
   is a scalar/value-producing operator usable only inside `<value expression>` (one value, not a
   table). A table/row result is reachable only through `CALL ... YIELD`.

4. **Recommended spec-justified syntax:**

   ```gql
   CALL <schema>.fulltext_search(indexName, queryString) YIELD node, score
   RETURN node, score ORDER BY score DESC
   ```

   and composably:

   ```gql
   CALL <schema>.fulltext_search('articles', 'graph database') YIELD node, score
   MATCH (node)-[:WRITTEN_BY]->(a:Author)
   RETURN a.name, score
   ```

---

## 1. Procedure-call statement that yields a binding table (CALL … YIELD)

### The call statement and the YIELD clause

`grammar/ISO_IEC_39075(en).bnf.txt`:

```
534  <call procedure statement> ::=
535      [ OPTIONAL ] CALL <procedure call>
536
537  <procedure call> ::=
538      <inline procedure call>
539    | <named procedure call>
540
541  <inline procedure call> ::=
542      [ <variable scope clause> ] <nested procedure specification>
543
544  <variable scope clause> ::=
545      <left paren> [ <binding variable reference list> ] <right paren>
546
547  <binding variable reference list> ::=
548      <binding variable reference> [ { <comma> <binding variable reference> }... ]
549
550  <named procedure call> ::=
551      <procedure reference> <left paren> [ <procedure argument list> ] <right paren>
552          [ <yield clause> ]
553
554  <procedure argument list> ::=
555      <procedure argument> [ { <comma> <procedure argument> }... ]
556
557  <procedure argument> ::=
558      <value expression>
```

Key facts from the productions above:

- The keyword is **`CALL`** (line 535). `OPTIONAL CALL` is also legal (outer-join-style call).
- A **`<named procedure call>`** (line 550) is `<procedure reference> ( args ) [ <yield clause> ]`
  — i.e. **`CALL schema.proc(args) YIELD …`** is exactly the ISO form. The `<yield clause>` is the
  optional trailing element on line 552.
- The `<yield clause>` (lines 1008–1015, verbatim below) projects the procedure's output columns
  into the binding table, using the `YIELD` keyword followed by a yield-item list (each item a
  column/field name, optionally `AS <binding variable>`):

  ```
  1008  <yield clause> ::=
  1009      YIELD <yield item list>
  1011  <yield item list> ::=
  1012      <yield item> [ { <comma> <yield item> }... ]
  1014  <yield item> ::=
  1015      { <yield item name> [ <yield item alias> ] }
  1017  <yield item name> ::=
  1018      <field name>
  1020  <yield item alias> ::=
  1021      AS <binding variable>
  ```

  So `YIELD node, score` (or `YIELD raw_col AS node`) names the procedure's output columns as
  *binding variables* in the running binding table. This is the standard's mechanism for exposing the
  returned table's columns so subsequent statements can reference them. (The separate
  `<graph pattern yield clause>` at lines 569–570, `YIELD <graph pattern yield item list>`, is the
  *MATCH-pattern* yield — a different production — confirming `YIELD` is the standard projection
  keyword in both the pattern and the call contexts.)

### Why the result is a *binding table* (rows), and how it composes

A `CALL` is wired into the ordinary linear-query pipeline as a first-class
`<simple query statement>` alternative — it is **not** a side statement:

```
406  <simple linear query statement> ::=
407      <simple query statement>...

409  <simple query statement> ::=
410      <primitive query statement>
411    | <call query statement>

413  <primitive query statement> ::=
414      <match statement>
415    | <let statement>
416    | <for statement>
417    | <filter statement>
418    | <order by and page statement>

438  <call query statement> ::=
439      <call procedure statement>
```

Because `<simple linear query statement>` is a **sequence** (`<simple query statement>...`, the
`...` meaning "one or more"), a `CALL` (via `<call query statement>`) sits in the same linear chain
as `MATCH`, `LET`, `FOR`, `FILTER`, and is followed by a `<primitive result statement>`
(`RETURN …` / `FINISH`, lines 477–482). So after a `CALL … YIELD node, score` you can write
`RETURN node, score`, or feed `node` into a subsequent `MATCH (node)-[...]->(x)` and then `RETURN`.
The YIELDed columns become binding variables in the running binding table exactly like MATCH
bindings.

The call form is also available in the **data-modifying** and **catalog-modifying** pipelines, so a
procedure can participate anywhere a simple statement is allowed:

```
265  <call catalog-modifying procedure statement> ::=
266      <call procedure statement>

297  <simple data-modifying statement> ::=
298      <primitive data-modifying statement>
299    | <call data-modifying procedure statement>

357  <call data-modifying procedure statement> ::=
358      <call procedure statement>
```

**Answer to Q1:** Yes. `CALL <proc>(...) YIELD col, ...` is valid ISO GQL. The productions are
`<call procedure statement>` (`CALL` keyword), `<named procedure call>` (which carries the optional
`[ <yield clause> ]`), and `<yield clause>` (`YIELD` keyword). The yielded table composes into the
surrounding linear query because `<call query statement>` is one of the `<simple query statement>`
alternatives that make up a `<simple linear query statement>` sequence terminated by a
`RETURN`/`FINISH`.

---

## 2. Is there an UNWIND equivalent? — The `FOR` statement (no `UNWIND` keyword exists)

**`UNWIND` does not exist in ISO GQL.** Grep of the full normative grammar:
`grep -c -i unwind grammar/ISO_IEC_39075(en).bnf.txt` → **0**. There is no `<unwind …>` production
and no `UNWIND` terminal anywhere.

The standard's **list-unnesting primitive is the `FOR` statement**, a `<primitive query statement>`
(line 416). It iterates a LIST value, producing one binding row per element:

```
455  <for statement> ::=
456      FOR <for item> [ <for ordinality or offset> ]
457
458  <for item> ::=
459      <for item alias> <for item source>
460
461  <for item alias> ::=
462      <binding variable> IN
463
464  <for item source> ::=
465      <list value expression>
466    | <binding table reference value expression>
467
468  <for ordinality or offset> ::=
469      WITH { ORDINALITY
470    | OFFSET } <binding variable>
```

So `FOR x IN <list value expression>` is the direct ISO analogue of Cypher's
`UNWIND <list> AS x`: it takes a `<list value expression>` (line 465) — e.g. a list literal, a list
property, or a list returned by a list-valued function — and unnests it into one row per element,
binding each element to `x`. `WITH ORDINALITY <var>` adds the 1-based index (and `WITH OFFSET <var>`
the 0-based index), a capability Cypher's bare `UNWIND` lacks.

`<for item source>` also accepts a `<binding table reference value expression>` (line 466), i.e. you
can iterate a whole binding-table value as well as a list — making `FOR` the general "turn a
collection value into rows" construct.

**Answer to Q2:** Definitively **no `UNWIND` clause** in ISO GQL. The prescribed list-unnesting
mechanism is the **`FOR` statement** — `FOR <var> IN <list value expression> [ WITH ORDINALITY |
OFFSET <var> ]` — which is the ISO equivalent of `UNWIND`.

---

## 3. Value-returning (function) vs table-returning (procedure) routines

ISO GQL draws the same line SQL does:

- **Procedures** are the only routines invoked with **`CALL`** and the only ones that can attach a
  **`<yield clause>`** to expose a *binding table* (rows/columns). See
  `<call procedure statement>` / `<named procedure call>` (lines 534, 550) above. Procedures are
  what `<procedure specification>`, `<inline/named procedure call>`, and the three
  `<call … procedure statement>` wrappers reference.

- **Value functions** are operators that appear **inside `<value expression>`** and produce a
  **single value**, not a table. They cannot be `CALL`ed and cannot `YIELD`. The grammar wires the
  value-function families directly under `<value expression>` (lines 1683–1696, verbatim):

  ```
  1683  <value expression> ::=
  1684      <common value expression>
  1685    | <boolean value expression>
  1687  <common value expression> ::=
  1689      <numeric value expression>
  1690    | <string value expression>
  1691    | <datetime value expression>
  1692    | <duration value expression>
  1693    | <list value expression>
  1694    | <record expression>
  1695    | <path value expression>
  1696    | <reference value expression>
  ```

  Each typed-value-expression arm carries its own function family as an alternative — e.g.
  `<numeric value function>` is an arm of `<numeric value expression>` (def. line 2011),
  `<list value function>` an arm of `<list value expression>` (def. line 1929), likewise datetime /
  duration / string / element value functions, plus `<aggregate function>` (def. line 1835) reached
  via `<value expression primary>` → `<non-parenthesized value expression primary special case>`
  (lines 1723–1745). Every one of these reduces to a **single value** usable wherever a
  `<value expression>` is (a `RETURN`/`SELECT` item, a `WHERE`/`FILTER` predicate, a `LET`
  right-hand side). There is **no grammar path** by which a function invocation contributes *rows* to
  the binding table — only `CALL … YIELD` does that.

The practical consequence: a routine that must emit **many `(node, score)` rows** is a *table-valued
routine*, and the **only** grammar path to a row result is `CALL <proc> … YIELD`. A scalar
`<value function>` can return at most one value (or a single LIST/MAP value), and the only way to
explode such a LIST into rows is then `FOR … IN <list>` (§2).

**Answer to Q3:** Yes, the spec distinguishes them. A `fulltext_search` that returns rows **must be
a PROCEDURE** (invoked via `CALL … YIELD`). It cannot be a value function, because functions live in
`<value expression>` and yield one value, never a binding table.

---

## 4. Composability: CALL … YIELD feeding a larger query

Already shown structurally in §1. Concretely, both of these are well-formed
`<simple linear query statement>` (a `<simple query statement>...` sequence) terminated by a
`<primitive result statement>`:

```gql
-- (a) call then return
CALL myschema.fulltext_search('articles', 'graph database') YIELD node, score
RETURN node, score
ORDER BY score DESC
LIMIT 10
```

```gql
-- (b) call then bind into a pattern, then return
CALL myschema.fulltext_search('articles', 'graph database') YIELD node, score
MATCH (node)-[:WRITTEN_BY]->(a:Author)
WHERE score > 0.5
RETURN a.name AS author, score
```

Grammar justification:

- `<simple linear query statement> ::= <simple query statement>...` (406–407) — a chain.
- Each link is `<simple query statement> ::= <primitive query statement> | <call query statement>`
  (409–411), so a `CALL` (438–439) and a `MATCH` (414, 420–425) sit side-by-side in one chain.
- The YIELDed columns (`node`, `score`) become binding variables in the running binding table; the
  later `MATCH (node)-[...]` references `node` as an `<element variable reference>`, and `RETURN`
  (481–482) projects from the accumulated bindings.
- `OPTIONAL CALL …` (line 535, `[ OPTIONAL ] CALL`) gives left-outer-join semantics for the call,
  mirroring `OPTIONAL MATCH`.

**Answer to Q4:** Yes — `RETURN node, score` directly after the call is valid, and the YIELDed
variables can be bound into a subsequent `MATCH`/`WHERE`/`RETURN` because the call is a member of
the same linear-query statement sequence.

---

## 5. Inline vs named procedures; schema-qualified names

`<procedure call>` (537) has two arms:

- **`<inline procedure call>`** (541) — `[ <variable scope clause> ] <nested procedure specification>`
  — an *anonymous* procedure body specified inline (a nested sub-procedure), with a
  `<variable scope clause>` `( v1, v2, ... )` (544) importing the named outer binding variables into
  the call's scope. This is `CALL { <subquery> }`-style inline composition.

- **`<named procedure call>`** (550) — `<procedure reference> ( args ) [ <yield clause> ]` — invoking
  a **named** (built-in or catalog) procedure. The procedure is identified by a
  **`<procedure reference>`**, which the grammar defines (lines 1127–1141, verbatim) as a
  schema-qualified catalog object name:

  ```
  1127  <procedure reference> ::=
  1128      <catalog procedure parent and name>
  1130  <catalog procedure parent and name> ::=
  1131      <catalog object parent and name>
  1133  <catalog object parent and name> ::=
  1134      [ <object name path prefix> ] <object name>
  1136  <object name> ::=
  1137      <identifier>
  ```

  So a procedure reference is `[ <object name path prefix> ] <object name>` — i.e. an optional
  multi-part catalog/schema path prefix followed by the object identifier. A multi-part name such as
  **`geode.fts.search`** or **`<schema>.fulltext_search`** is exactly what `<procedure reference>`
  denotes. The current session schema (set via `SESSION SET SCHEMA <schema reference>`, lines 31–38;
  `<schema reference>` defined at 1060+ with `HOME_SCHEMA` / `CURRENT_SCHEMA` predefined references)
  supplies the default qualifier when the name path prefix is omitted.

**Answer to Q5:** Yes — GQL supports `CALL` of a **named** procedure (e.g. `CALL geode.fts.search(...)`)
via `<named procedure call>` → `<procedure reference>`, and procedure references are
schema-qualified catalog names. It also supports **inline** (anonymous, nested) procedure calls via
`<inline procedure call>` with a `<variable scope clause>`.

---

## RECOMMENDED GQL FOR FULL-TEXT SEARCH (spec-justified)

Surface `fulltext_search` as a **named PROCEDURE** in a Geode schema, invoked with `CALL … YIELD`:

```gql
-- minimal: rows of (node, score)
CALL geode.fts.fulltext_search($index, $query) YIELD node, score
RETURN node, score
ORDER BY score DESC
LIMIT $k
```

```gql
-- composed into a graph traversal
CALL geode.fts.fulltext_search('articles', 'graph database') YIELD node, score
MATCH (node)-[:WRITTEN_BY]->(a:Author)
RETURN a.name AS author, node.title AS title, score
ORDER BY score DESC
```

Why this is the ISO-correct shape:

1. A row set is reachable **only** through `CALL … YIELD` (`<call procedure statement>` 534,
   `<named procedure call>` 550, `<yield clause>`). → fulltext_search **must be a procedure**, not a
   value function (§3).
2. `YIELD node, score` names the output columns as binding variables (`<yield clause>`), so they
   flow into the running binding table (§1).
3. The call is a `<call query statement>` inside the `<simple linear query statement>` chain, so a
   following `MATCH`/`WHERE`/`RETURN`/`ORDER BY`/`LIMIT` composes naturally (§1, §4).
4. The procedure name is a schema-qualified `<procedure reference>` (e.g. `geode.fts.fulltext_search`)
   (§5).
5. `OPTIONAL CALL geode.fts.fulltext_search(...) YIELD …` is available for outer-join semantics
   (line 535).

If a result ever arrives as a **single LIST value** (e.g. a scalar `<value function>` returning a
list of hits) rather than a procedure binding table, the ISO way to turn that list into rows is the
**`FOR` statement** (§2):

```gql
LET hits = geode.fts.search_list($index, $query)        -- a LIST value
FOR hit IN hits WITH ORDINALITY rank
RETURN hit.node AS node, hit.score AS score, rank
```

But the **preferred** design is the procedure form (`CALL … YIELD`), because it yields a true
binding table directly and avoids constructing an intermediate list. `FOR … IN` is the
`UNWIND`-equivalent fallback, not the primary set-return mechanism.

---

## CITATION INDEX (all line numbers in `grammar/ISO_IEC_39075(en).bnf.txt`)

| Production (ISO non-terminal) | Line(s) | Role |
|---|---|---|
| `<call procedure statement> ::= [ OPTIONAL ] CALL <procedure call>` | 534–535 | the `CALL` statement |
| `<procedure call>` (inline / named) | 537–539 | dispatch |
| `<inline procedure call>` + `<variable scope clause>` | 541–545 | anonymous/nested call, var import |
| `<named procedure call> ::= <procedure reference> ( [args] ) [ <yield clause> ]` | 550–552 | `CALL name(args) YIELD …` |
| `<procedure argument list>` / `<procedure argument> ::= <value expression>` | 554–558 | call arguments |
| `<yield clause> ::= YIELD <yield item list>` | 1008–1009 | the `YIELD` projection |
| `<yield item> ::= { <yield item name> [ <yield item alias> ] }` | 1014–1015 | one output column |
| `<yield item name> ::= <field name>` / `<yield item alias> ::= AS <binding variable>` | 1017–1021 | column name + alias |
| `<procedure reference> ::= <catalog procedure parent and name>` (→ `[ <object name path prefix> ] <object name>`) | 1127–1137 | schema-qualified proc name |
| `<value expression> ::= <common value expression> | …` (function families per typed arm) | 1683–1696 | functions live in expressions (1 value) |
| `<numeric value function>` / `<list value function>` / `<aggregate function>` | 2011 / 1929 / 1835 | scalar value functions |
| `<procedure body> ::= [<at schema clause>] [<binding variable definition block>] <statement block>` | 129–131 | procedure body = statements |
| `<next statement> ::= NEXT [ <yield clause> ] <statement>` | 148–149 | YIELD also chains statement blocks |
| `<graph pattern yield clause> ::= YIELD …` | 569–570 | (separate) MATCH-pattern yield |
| `<simple linear query statement> ::= <simple query statement>...` | 406–407 | linear chain (sequence) |
| `<simple query statement> ::= <primitive query statement> | <call query statement>` | 409–411 | call is first-class in the chain |
| `<primitive query statement>` (MATCH/LET/FOR/FILTER/ORDER BY) | 413–418 | siblings of CALL |
| `<call query statement> ::= <call procedure statement>` | 438–439 | CALL inside a query |
| `<call data-modifying procedure statement>` | 357–358 | CALL inside data-modifying pipeline |
| `<call catalog-modifying procedure statement>` | 265–266 | CALL inside catalog pipeline |
| `<for statement> ::= FOR <for item> [ <for ordinality or offset> ]` | 455–456 | **UNWIND equivalent** |
| `<for item> / <for item alias> ::= <binding variable> IN` | 458–462 | `FOR x IN …` |
| `<for item source> ::= <list value expression> | <binding table reference value expression>` | 464–466 | unnest a LIST (or table) |
| `<for ordinality or offset> ::= WITH { ORDINALITY | OFFSET } <binding variable>` | 468–470 | index column |
| `<primitive result statement> ::= <return statement> [...] | FINISH` | 477–479 | terminates the chain |
| `<return statement> ::= RETURN <return statement body>` | 481–482 | project results |
| `SESSION SET SCHEMA <schema reference>` | 31–38 | default schema qualifier |
| `UNWIND` (terminal/production) | **absent — 0 occurrences** | confirms no UNWIND |

**Note on missing PDF.** The ISO PDF was not in the repo (the brief's path
`docs/kb/gql/ISO_IEC_39075_2024(en).pdf` does not exist; that directory holds only Geode-authored
`.md` files). All citations above are to the standard's own normative grammar artifact,
`grammar/ISO_IEC_39075(en).bnf.txt`, whose header self-identifies as *"the grammar specified by
ISO/IEC 39075"*. This BNF is authoritative for every syntax question asked here, and its non-terminal
names are the standard's own (they map 1:1 to the ISO clause titles, e.g. `<call procedure statement>`,
`<for statement>`, `<yield clause>`). Every production cited above — including the full bodies of
`<yield clause>` (1008–1021), `<procedure reference>` (1127–1137), `<value expression>` /
`<common value expression>` (1683–1696), and `<for statement>` (455–470) — is quoted verbatim from
that file. The `UNWIND`
absence was verified mechanically (`grep -c -i unwind` = 0 over all 3501 lines).
