# GQL Set-Returning Query Surface — Verified Against the Authoritative ISO/IEC 39075 Grammar

## CORRECTION UP FRONT — the PDF claimed in the task does NOT exist in this checkout

The task asserted the standard PDF is at
`docs/kb/gql/ISO_IEC_39075_2024(en).pdf` and that "a prior agent missed it."
**That file is not present.** The `docs/kb/gql/` directory contains only three
Markdown files (`GQL_CONFORMANCE_PROFILE.md`, `GQL_ENGINE_CROSSWALK.md`,
`ISO_GQL_AUDIT_SUMMARY.md`) and no PDF. Every attempt to open it returned:

```
ENOENT: no such file or directory, statx
'/data/home/benji/.../docs/kb/gql/ISO_IEC_39075_2024(en).pdf'
```

A repo-wide `find` for `*39075*` and for `*.pdf` confirms there is **no copy of
the ISO/IEC 39075 PDF anywhere in the geode tree** (the only PDFs found are
`zlib.3.pdf` / `crc-doc.1.0.pdf` under `zig-pkg/`, unrelated). The prior agent
did not "miss" it — the PDF genuinely is absent from this checkout.

### Fallback used — and it is the strongest possible proxy

Per the task's own fallback instruction ("fall back to the gql library's grammar
as the conformance proxy"), I verified against the **official ISO/IEC 39075 BNF
'digital artifact'** shipped in the repo — the normative machine-readable grammar
published *by ISO alongside the standard text*:

- `grammar/ISO_IEC_39075(en).bnf.txt` (79 KB, 3501 lines). Header verbatim:
  *"This file is a 'digital artifact' that contains the grammar specified by
  ISO/IEC 39075. This grammar may be used by implementers of GQL-implementations
  when generating parsers for the GQL language."*
- `grammar/ISO_IEC_39075(en).bnf.xml` (251 KB). Header verbatim: *"The grammar is
  specified using the XML vocabulary used to specify ISO/IEC 39075 itself."*

This is **not** a secondary source or a re-implementation — it is the same set of
production rules that the standard's prose (Clauses 6/10/14) wraps in Syntax
Rules. Every quote below is verbatim, taken from BOTH artifacts and
cross-checked. Where the two agree (they do), the production is certain.

> **STATED LOUDLY:** because the PDF is absent, I CANNOT supply real ISO clause
> numbers (the prior agent's guessed §14.1/§14.2 cannot be confirmed here) nor
> printed page numbers. What I CAN and DO prove is the exact normative grammar,
> which is what governs syntactic conformance. Anyone needing the § / page
> citations must obtain the PDF and re-pin them; the grammar productions below
> will not change.

I cite line numbers in `…bnf.txt` (`L<n>`) for every production.

---

## TL;DR verdict on the five claims

| # | Claim | Verdict against the normative BNF |
|---|-------|-----------------------------------|
| 1 | `<call procedure statement>` with `CALL … [yield clause]`, `<yield clause> ::= YIELD <yield item list>` | **CONFIRMED** (verbatim below). Clause #/page guess (§14.1/§14.2) **UNVERIFIABLE** — no PDF. |
| 2 | No UNWIND / no list-unnesting clause | **CONFIRMED** — `UNWIND`/`UNNEST`/`LATERAL`/`FLATTEN`/`FOREACH`/`EXPLODE` appear **0 times** in both artifacts. |
| 3 | Only a PROCEDURE (via CALL) yields a binding table; functions are scalar | **CONFIRMED** — every function lives under `<common value expression>` (scalar). No function production carries a YIELD/table output. |
| 4 | Schema-qualified/dotted procedure name (`geode.fts.search`) is a valid `<procedure reference>` | **CONFIRMED** — `<catalog object parent reference>` supplies the repeated `{ <object name> <period> }...` dotted prefix. |
| 5 | After `CALL … YIELD a, b`, a trailing `RETURN a, b ORDER BY b` is valid composition | **CONFIRMED** — `<call query statement>` is a `<simple query statement>`; `<simple linear query statement> ::= <simple query statement>...` sequences it ahead of the `<primitive result statement>` (RETURN + ORDER BY). |

**No prior claim was technically wrong.** Two corrections, both about naming /
citations, NOT about syntax:

1. **The PDF is missing**, so the guessed clause numbers (§14.1, §14.2) cannot be
   confirmed from this repo.
2. The standard's spelling differs from a couple of names a prior agent used:
   the result node is **`<primitive result statement>`** (not "primary result
   statement"); the sub-statement node is **`<primitive query statement>`** (not
   "primary query statement"); and GQL has **no production literally named
   `<value function>`** — scalar functions are reached via
   `<common value expression>`. The substance of every claim still holds.

---

## Claim 1 — `<call procedure statement>` + `<yield clause>` — **CONFIRMED**

Verbatim from `…bnf.txt` (L534–558, L1008–1021):

```
<call procedure statement> ::=                                   (L534)
    [ OPTIONAL ] CALL <procedure call>

<procedure call> ::=                                            (L537)
    <inline procedure call>
  | <named procedure call>

<inline procedure call> ::=                                     (L541)
    [ <variable scope clause> ] <nested procedure specification>

<named procedure call> ::=                                      (L550)
    <procedure reference> <left paren> [ <procedure argument list> ] <right paren>
         [ <yield clause> ]

<procedure argument list> ::=                                   (L554)
    <procedure argument> [ { <comma> <procedure argument> }... ]

<procedure argument> ::=                                        (L557)
    <value expression>

<yield clause> ::=                                              (L1008)
    YIELD <yield item list>

<yield item list> ::=                                           (L1011)
    <yield item> [ { <comma> <yield item> }... ]

<yield item> ::=                                                (L1014)
    { <yield item name> [ <yield item alias> ] }

<yield item name> ::=                                           (L1017)
    <field name>                       (<field name> ::= <identifier>)

<yield item alias> ::=                                          (L1020)
    AS <binding variable>
```

(The XML artifact confirms each of these BNFdefs identically.)

**EXACT-syntax answers for `CALL proc(...) YIELD col1, col2`:**

- **Commas between columns?** YES — `<yield item list> ::= <yield item>
  [ { <comma> <yield item> }... ]`. Comma-separated.
- **AS aliases?** YES, optional — `<yield item alias> ::= AS <binding variable>`.
  So `YIELD score AS s` is legal.
- **A WHERE after YIELD?** NO. `<yield clause>` is *only* `YIELD <yield item
  list>` — no WHERE/FILTER token inside it. Post-call filtering uses a *separate*
  `<filter statement>` (see Claim 5 note), not the yield clause.
- The leading `[ OPTIONAL ]` is the optional-call modifier; not required for a
  normal call.

**`CALL geode.fts.search('term') YIELD node, score` is valid GQL.** Aliases
(`YIELD node AS n, score AS s`) are valid. `YIELD … WHERE …` is NOT part of the
yield clause.

---

## Claim 2 — NO UNWIND / no list-unnesting clause — **CONFIRMED (loudly)**

Whole-file, case-insensitive search of BOTH normative BNF artifacts:

| Token | Occurrences in `…bnf.txt` AND `…bnf.xml` |
|-------|------------------------------------------|
| `UNWIND`  | **0** |
| `UNNEST`  | **0** |
| `LATERAL` | **0** |
| `FLATTEN` | **0** |
| `FOREACH` | **0** |
| `EXPLODE` | **0** |

By contrast `CALL` and `YIELD` are present as keywords (`<kw>CALL</kw>`,
`<kw>YIELD</kw>` in the productions above).

**Definitive statement:** ISO/IEC 39075 has **no `<unwind clause>`, no UNWIND
keyword, and no list-unnesting / lateral / table-function clause of any kind.**
The closest thing — `<for statement> ::= FOR <for item> …` (L455), whose
`<for item source>` may be a `<list value expression>` — iterates a list but is a
`<primitive query statement>`, not a column-yielding table source, and is not
"UNWIND." The prescribed way to introduce a row set / binding table into a query
is **`CALL <procedure> … YIELD …`** (Claim 1). That is exactly why a set-returning
operation such as full-text search must be modeled as a **procedure**, not a
function. (Cypher's `UNWIND` is a Neo4j extension and is NOT in the ISO grammar.)

---

## Claim 3 — Procedure (yields a table) vs scalar functions — **CONFIRMED**

There is **no production literally named `<value function>`** in the artifact
(prior wording was loose). Scalar functions are the alternatives of
`<common value expression>`, reached only through `<value expression>`:

```
<value expression> ::=                                          (L1683)
    <common value expression>
  | <boolean value expression>

<common value expression> ::=     (XML BNFdef)
    <numeric value expression>
  | <string value expression>
  | <datetime value expression>
  | <duration value expression>
  | <list value expression>
  | <record expression>
  | <path value expression>
  | <reference value expression>
```

The concrete scalar function productions (`<numeric value function>` L2011,
`<datetime value function>` L2235, `<duration value function>` L2317,
`<list value function>` L1929, character/byte-string functions, etc.) are all
reached inside those `*-value expression` branches. **Every one returns a single
value** and appears only in scalar/value-expression position. **None** carries a
`YIELD` or produces multiple columns of rows.

The **only** construct that exports yielded columns into a query is the
`<call procedure statement>` via its `<yield clause>` (Claim 1).

**Conclusion:** a set-returning `fulltext_search` (rows of `(node, score)`)
**MUST be a PROCEDURE called with `CALL … YIELD …`**, never a scalar value
function. A value function could only return one scalar value.

---

## Claim 4 — Schema-qualified / dotted `<procedure reference>` — **CONFIRMED**

Verbatim (`…bnf.txt` L1127–1136):

```
<procedure reference> ::=                                       (L1127)
    <catalog procedure parent and name>
  | <reference parameter specification>

<catalog procedure parent and name> ::=                         (L1131)
    [ <catalog object parent reference> ] <procedure name>

<catalog object parent reference> ::=                           (L1134)
    <schema reference> [ <solidus> ] [ { <object name> <period> }... ]
  | { <object name> <period> }...

<object name> ::=  <identifier>      (XML BNFdef)
```

The second alternative — `{ <object name> <period> }...` — is the **dotted
prefix**. So `geode.fts.search` parses as:

- `geode` `.` `fts` `.`  → two `{ <object name> <period> }` items inside the
  `<catalog object parent reference>`, and
- `search` → the trailing `<procedure name>`.

**Dotted / schema-qualified procedure names ARE in the grammar.**
`geode.fts.search` is a valid `<procedure reference>`. (The first alternative
additionally allows an absolute schema path via `<schema reference> [ <solidus> ]`,
e.g. `/some/schema/geode.fts.search`; the plain dotted form suffices.)

---

## Claim 5 — Composition: `CALL … YIELD a, b` then `RETURN a, b ORDER BY b` — **CONFIRMED**

Verbatim (`…bnf.txt` L402–411, L438–439, L472–482):

```
<call query statement> ::=                                      (L438)
    <call procedure statement>

<simple query statement> ::=                                    (L409)
    <primitive query statement>
  | <call query statement>

<primitive query statement> ::=                                 (L413)
    <match statement>
  | <let statement>
  | <for statement>
  | <filter statement>
  | <order by and page statement>

<simple linear query statement> ::=                             (L406)
    <simple query statement>...                <-- one OR MORE, sequenced

<ambient linear query statement> ::=                            (L402)
    [ <simple linear query statement> ] <primitive result statement>
  | <nested query specification>

<primitive result statement> ::=                                (L477)
    <return statement> [ <order by and page statement> ]
  | FINISH

<return statement> ::=                                          (L481)
    RETURN <return statement body>

<return statement body> ::=                                     (L484)
    [ <set quantifier> ] { <asterisk> | <return item list> } [ <group by clause> ]
  | NO BINDINGS

<order by and page statement> ::=                               (L472)
    <order by clause> [ <offset clause> ] [ <limit clause> ]
  | <offset clause> [ <limit clause> ]
  | <limit clause>

<order by clause> ::=                                           (L1036)
    ORDER BY <sort specification list>
```

**Why the composition is legal, step by step:**

1. `CALL geode.fts.search('term') YIELD node, score` is a
   `<call procedure statement>` → which IS a `<call query statement>` (L438) →
   which IS a `<simple query statement>` (L409).
2. `<simple linear query statement> ::= <simple query statement>...` (L406) allows
   a **sequence** of simple query statements, so the CALL can be followed by more
   statements in the same linear query, then closed by a `<primitive result
   statement>` (per `<ambient linear query statement>` L402).
3. The yielded `node, score` become binding variables of the working binding
   table (the `<yield clause>` exports them via `<yield item alias>`/`<binding
   variable>`), so they are in scope downstream.
4. `RETURN node, score ORDER BY score DESC` is a `<return statement>` +
   `<order by and page statement>` — together the `<primitive result statement>`
   (L477) that closes the linear query — consuming those bindings.

**A `CALL … YIELD` contributes bindings that a trailing `RETURN … ORDER BY …`
consumes. That is exactly the standard grammar's linear-query composition.**

---

## SPEC-BLESSED EXACT SYNTAX for full-text search as a procedure

```gql
CALL geode.fts.search('search terms')
  YIELD node, score
RETURN node, score
  ORDER BY score DESC
```

Grammar-backed properties:

- `CALL geode.fts.search( … )` — `<call procedure statement>` →
  `[ OPTIONAL ] CALL <procedure call>` → `<named procedure call> ::=
  <procedure reference> ( [ <procedure argument list> ] ) [ <yield clause> ]`.
  Arguments are `<value expression>`s, comma-separated.
- `geode.fts.search` — a dotted `<procedure reference>`: `geode` `.` `fts` `.`
  are `{ <object name> <period> }...` items; `search` is the `<procedure name>`.
- `YIELD node, score` — `<yield clause> ::= YIELD <yield item list>`,
  `<yield item list> ::= <yield item> [ { <comma> <yield item> }... ]`. Optional
  aliases: `YIELD node AS n, score AS s`.
- The yielded `node, score` are binding variables, in scope downstream.
- `RETURN node, score ORDER BY score DESC` — `<primitive result statement>` =
  `<return statement> [ <order by and page statement> ]`, composed after the call
  in the same `<simple linear query statement>`.

**Hard NO's the grammar imposes:**

- Do NOT model set-returning FTS as a scalar value function — functions live
  under `<common value expression>` (Claim 3) and cannot yield a row set.
- There is NO `UNWIND`/`UNNEST` (Claim 2) — do not invent or rely on one;
  `CALL … YIELD` is the only way to introduce a binding table.
- The `<yield clause>` has NO trailing `WHERE`. To filter, add a separate
  `<filter statement>` after the call — verbatim `<filter statement> ::= FILTER
  { <where clause> | <search condition> }` (L441) — e.g.
  `CALL … YIELD node, score FILTER score > 0.5 RETURN node, score ORDER BY score DESC`.

---

## Citation index (production → `…bnf.txt` line; XML confirms each)

| Production | .txt line |
|------------|-----------|
| `<call procedure statement>` | 534 |
| `<procedure call>` / `<inline procedure call>` / `<named procedure call>` | 537 / 541 / 550 |
| `<procedure argument list>` / `<procedure argument>` | 554 / 557 |
| `<yield clause>` | 1008 |
| `<yield item list>` / `<yield item>` / `<yield item name>` / `<yield item alias>` | 1011 / 1014 / 1017 / 1020 |
| `<procedure reference>` / `<catalog procedure parent and name>` / `<catalog object parent reference>` | 1127 / 1131 / 1134 |
| `<value expression>` | 1683 |
| `<common value expression>` (scalar function home) | XML BNFdef |
| scalar function prods (`<numeric/datetime/duration/list value function>` …) | 2011 / 2235 / 2317 / 1929 |
| `<call query statement>` | 438 |
| `<simple query statement>` / `<primitive query statement>` | 409 / 413 |
| `<simple linear query statement>` / `<ambient linear query statement>` | 406 / 402 |
| `<primitive result statement>` (RETURN + ORDER BY) | 477 |
| `<return statement>` / `<return statement body>` / `<return item list>` / `<return item>` | 481 / 484 / 489 / 492 |
| `<order by and page statement>` / `<order by clause>` | 472 / 1036 |
| `<filter statement>` / `<where clause>` (post-call filtering) | 441 / 1005 |
| UNWIND/UNNEST/LATERAL/FLATTEN/FOREACH/EXPLODE | NOT PRESENT (0 occurrences) |

> **Reminder:** these are NORMATIVE GRAMMAR positions, not ISO clause/page
> numbers. The PDF that would supply §-numbers and printed pages is **absent from
> this checkout** (see top of file). The grammar — proven here verbatim — is the
> conformance source of truth for syntax; the prose clause numbers remain to be
> pinned once a PDF copy is obtained.

*Verified 2026-05-31 against `grammar/ISO_IEC_39075(en).bnf.txt` and
`grammar/ISO_IEC_39075(en).bnf.xml` (the official ISO/IEC 39075 BNF digital
artifacts shipped in this repo).*
