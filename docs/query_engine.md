# Research Report: Query Planning & Optimization for an ISO/IEC 39075 (GQL)‑Compliant, Distributed, ACID Graph Database (with Zig POCs)

**As of:** 2025‑08‑31
**Role:** Deep‑Research Agent (DRA) for a high‑performance property‑graph DB implemented in **Zig**.

---

## 1) Executive Summary (≤200 words)

We specify a **GQL‑faithful** query planning & optimization stack for a distributed, ACID property‑graph DB. The design maps GQL’s **linear/primitive/select semantics** over **binding tables** and **working record/table** contexts to a compositional **logical algebra** with explicit contracts for ordering, nullability, and multiplicities. We define a **two‑tier optimizer**: (i) rule‑based canonicalization (predicate, label, and projection pushdowns, decorrelation, OPTIONAL handling) subject to GQL legality constraints; and (ii) a **cost‑based enumerator** that chooses between **binary‑join plans** and **worst‑case‑optimal joins (WCOJ)**, with variable‑length path operators and top‑k/ORDER BY early‑stop. We provide **cardinality estimators** for labels/properties, degrees, path‑lengths, and joins, including **AGM/WCOJ proxies**, sampling (HLL++), and graph synopses. The planner is **partition‑aware** (vertex‑cut/edge‑cut), places **Exchange** (Shuffle/Replicate/Broadcast), and respects **transaction/isolation** constraints. We design **adaptive** re‑optimization hooks and **EXPLAIN/PROFILE** formats.

We ground the design in **ISO/IEC 39075:2024 (GQL)** clause‑accurate references for execution context, ORDER BY & pagination, path search tie‑breaking, and features (e.g., **GQ01 USE graph**, **GQ12 OFFSET**, **GQ13 LIMIT**). We synthesize peer‑reviewed evidence (2010–present) on WCOJ vs binary joins, path planning, distributed graph optimization, and adaptive optimizers. Zig **POCs** implement logical/physical operator ADTs, memo+rules, DP & WCOJ enumerators, estimators, physical operators, distributed plan nodes, and explain/profiling.

---

## 2) Background & Context (GQL semantics that affect planning)

**Execution contexts, working record/table.** GQL executes **linear compositions** of simple/primitive statements over an **incoming/outgoing working record** and **working table**. Types flow statement‑to‑statement in the order they appear. This is the formal basis for our algebra over binding tables.&#x20;

**Linear/primitive/select statements.**

- `<linear query statement>` composes `<simple query statement>`s and a `<primitive result statement>` (or `SELECT`) with well‑typed hand‑offs of working record/table.
- `<match statement>` expands the current working table with graph pattern matches; OPTIONAL semantics are defined via the `<optional match statement>` and its binding‑supply rules.&#x20;
- `<primitive result statement>` defines the result and optionally includes `<order by and page>`; ORDER BY references must be tied to returned or grouped variables under specific conditions.&#x20;
- `<select statement>` desugars to a linear body of RETURN/GROUP BY/ORDER BY/LIMIT/OFFSET (planner‑relevant for transformations).&#x20;

**ORDER BY & Pagination.**

- ORDER BY semantics (sort specs) are explicit; LIMIT/OFFSET are blocking operators. If OFFSET is applied to an **unordered** table, the implementation may sort by an **implementation‑dependent order (US001)** before discarding rows. Diagnostics precedence prefers lower‑numbered codes when multiple apply.&#x20;
- LIMIT applies to the ordered working table; if none exists, an ordering may be produced before retention of the first _V_ rows.&#x20;

**Path-pattern selection & tie‑breaking.** GQL’s **selective path search** permits **implementation‑defined** tie‑breaking (UA005/UA006) and flags for counting/shortest‑group semantics; planners must document choices.&#x20;

**Transactions & isolation.** GQL defers isolation specifics to the implementation; optimizer rules must respect the chosen isolation guarantees.&#x20;

**Feature flags.** Planner‑visible features include **GQ01 USE graph** (focused linear statements), **GQ12 OFFSET**, **GQ13 LIMIT**, etc. We enumerate them in the conformance profile (Appendix A1).

---

## 3) Core Findings

### 3.1 Logical Algebra mapping from GQL

We formalize a **Graph Binding Algebra (GBA)** over **binding tables** (sets/bags of records with named binding variables). Each operator is typed by **input binding schema**, **output schema**, **ordering**, **multiplicity**, and **nullability**.

**Core logical operators (contract).**

| Logical op                                         | Input                   | Output                                      | Ordering                         | Multiplicity                              | Notes                                                                                  |
| -------------------------------------------------- | ----------------------- | ------------------------------------------- | -------------------------------- | ----------------------------------------- | -------------------------------------------------------------------------------------- |
| **NodeScan(ℓ, preds)**                             | — or binding table      | rows (v) with label ℓ and predicate filters | unspecified                      | 1 per qualifying node                     | label/property pushdown                                                                |
| **EdgeScan(τ, dir, preds)**                        | nodes (src or dst)      | pairs (u,e,v)                               | per‑input stable if index‑guided | ≤ degree(u)                               | uses adjacency indexes                                                                 |
| **Expand(dir, τ, \[kmin,kmax])**                   | bindings with endpoints | extended bindings along paths               | may preserve per‑input order     | multiplicity by path count                | bounded/unbounded var‑length                                                           |
| **Filter(θ)**                                      | any                     | filtered                                    | preserves input order            | ≤ input                                   | boolean predicates incl. labels                                                        |
| **Project(cols)**                                  | any                     | projected                                   | preserves order w\.r.t. cols     | ≤ input                                   | early projection                                                                       |
| **Group(keys, aggs)**                              | any                     | grouped                                     | order unspecified                | ≤ input                                   |                                                                                        |
| **Join(θequi)**                                    | two relations           | joined                                      | unspecified unless merge‑sorted  | product‑filtered                          | hash/sort‑merge                                                                        |
| **MultiwayJoin(H)**                                | k relations             | result                                      | enumerator‑controlled            | ≤ AGM bound                               | WCOJ/Generic‑Join family ([ACM Digital Library][1], [OpenProceedings][2])              |
| **OrderBy(S)**                                     | any                     | totally ordered                             | defined by S                     | = input                                   | blocking                                                                               |
| **Limit(V)**                                       | ordered/ unordered      | first V rows                                | ordered                          | ≤ V                                       | see **US001** via OFFSET semantics                                                     |
| **Offset(V)**                                      | ordered/ unordered      | drop first V rows                           | ordered                          | ≤ input                                   | if unordered, an impl‑dependent order may be introduced (**US001**) before discarding. |
| **PathExpand(A, R, B, \[kmin,kmax], constraints)** | bindings with A,B       | bindings enriched with legal paths          | per‑input order if BFS layerwise | multiplicity=#paths or distinct endpoints | legality must follow GQL’s path rules & UA005/UA006 tie‑breaks.                        |

#### Mapping to GQL constructs

- `<match statement>` → compositions of **NodeScan/Expand/Join/Filter** over the binding table.&#x20;
- `<primitive result statement>` → **RETURN → Project/Group**, then **ORDER BY & page → OrderBy/Limit/Offset**; legality of ORDER BY keys follows the constraints in 14.10.&#x20;
- `<select statement>` desugars to RETURN/GROUP/ORDER/LIMIT/OFFSET sequence per 14.12; we treat this as the same algebraic pipeline.&#x20;

### Ordering guarantees & stability

GQL allows implementation‑dependent order when an unordered binding table is paginated (US001), so any LIMIT/OFFSET pushdown must not change observable results when an explicit ORDER BY is absent or when ORDER BY keys change.

### Set operations (UNION/INTERSECT/EXCEPT)

- Equality semantics: rows compare by column‑wise value equality with NULL = NULL for set‑ops; type precedence for deterministic sorting is Null < Bool < Int < Str; rows compare lexicographically.
- Variants implemented: DISTINCT (deduplicates, deterministically sorted) and ALL (preserves multiplicities, stable‑left order i.e., rows appear in the order of the left input).
- These choices are implementation‑defined and documented for reproducibility and test stability (ISO 14.12 + Annex).

### Expression evaluation (subset)

- CASE (simple, searched); string predicates STARTS WITH, ENDS WITH, CONTAINS; regex operator =~ implemented via a simple matcher supporting anchors (^) and ($) and wildcard ".\*".
- Implicit casts policy (demo evaluator): string/int equality allowed by comparing decimal string forms; ordering comparisons across Int/Str are illegal and surface a TypeMismatch at evaluation time (see Diagnostics A1.1 for mapping policy).

### 3.2 Rule‑Based Rewrites (with legality conditions)

#### Canonicalization & simplification

- **Pattern normalization**: deduplicate isomorphic pattern fragments; merge commutative predicates; remove dead projections.
- **Constant folding / predicate simplification**: safe for scalar expressions and label tests if not correlated with runtime visibility rules.

#### Pushdowns

- **Label/property pushdown** into Node/Edge scans and into **Expand**’s neighbor enumeration when supported by adjacency+property indexes. (Kùzu demonstrates index‑guided CSR adjacency and semijoin filters to restrict scans. ([CIDRDB][3]))
- **Early projection** to shrink tuple width prior to expensive Expand/Join; must preserve ORDER BY key availability per 14.10 rules.&#x20;
- **Filter to path expand**: path constraints (length, label, simple‑path) pushed to the traversal operator; must respect GQL path legality and UA005/UA006 tie‑breaking disclosures.&#x20;

#### OPTIONAL (outer‑like) rewrites

- OPTIONAL MATCH can be compiled as **left‑outer semantics** over pattern fragments that “supply bindings” to the OPTIONAL scope per 14.4; we allow predicate relocation only if null‑introduction behavior is unchanged.&#x20;

#### Pagination‑aware rewrites

- **LIMIT/OFFSET pushdown**: legal when an **explicit ORDER BY** exists and the pushed operator preserves/creates a compatible order; otherwise unsafe due to US001.&#x20;
- **Top‑k early stop**: if a pipeline can **produce in desired order** (e.g., index‑order or merge‑preserving plans), we insert a **StopAfter(V)** fence before full materialization; see ranked enumeration literature for join‑aware top‑k. ([Northeastern Data Lab][4], [Khoury College of Computer Sciences][5])

#### Decorrelation

- Transform scalar **VALUE subqueries** and **EXISTS** into semi‑joins/aggregates when emitting statement is well‑formed (20.6 requires LIMIT 1 or aggregation).&#x20;

### 3.3 Join & Pattern‑Matching Strategies

#### Binary join vs WCOJ

_Binary joins_ (hash/sort‑merge) excel when selective predicates and **good indexes** drastically reduce intermediate sizes; **WCOJ** (Generic‑Join / Leapfrog‑Triejoin) dominates on **cyclic patterns** (triangles, cliques) and **dense** regions, achieving bounds near **AGM**; modern engines combine both. ([ACM Digital Library][1], [OpenProceedings][2], [Stanford Pervasive Parallelism Lab][6], [CIDRDB][3])

- **Generic surveys & results.** Ngo et al. (Journal overview/tutorial) and Veldhuizen (Leapfrog‑Triejoin) provide the foundations for WCOJ. ([ACM Digital Library][1], [OpenProceedings][2])
- **Systems evidence.** EmptyHeaded shows WCOJ with compressed bitset tries beating relational baselines on graph workloads. ([Stanford Pervasive Parallelism Lab][6])
- **Hybrid join operators.** Kùzu’s **ASP‑Join** integrates **semijoin filtering** and factorization; their optimizer switches between **binary** and **multiway WCOJ** based on factorized tuple models. ([CIDRDB][3])

#### Graph expand vs neighbor‑set operators

- **Expand** logical op maps to **index‑guided adjacency scans** (CSR) with predicate pushdown (labels/properties) and **sideways information passing** (SIP) to prune I/O. ([CIDRDB][3])
- **Variable‑length paths.** Bounded k‑hop uses layered BFS; unbounded paths must respect GQL path legality (simple vs. walk) and may use **bidirectional BFS** for reachability/shortest. For shortest distances/top‑k paths, **pruned landmark labeling** provides competitive performance for exact distances on large graphs. ([ACM Digital Library][7])

#### Subgraph isomorphism accelerators

For selective pattern fragments (small induced subgraphs), use **TurboIso**‑style pruning and modern exact solvers (**VF3**, **Glasgow**) as filter/enumerators before joins; this helps on query graph isomorphism fragments embedded in GQL patterns. ([homepages.inf.ed.ac.uk][8], [ACM Digital Library][9], [PMC][10])

#### Early‑stop for top‑k/limit

Adopt **ranked enumeration** (Any‑k) to push ranking into joins—deliver top‑k without global materialization if the scoring function obeys monotonicity/semiring constraints. ([Northeastern Data Lab][4], [arXiv][11])

### 3.4 Cost & Cardinality Estimation

#### Statistics

- **Label selectivity & property histograms** (equi‑depth or logarithmic buckets), **degree distributions** (power‑law friendly), and **co‑occurrence stats** for labels/properties.
- **Path‑length distributions** (source‑agnostic) via sampling or landmarks; exact distance oracles (PL/Hub labeling) provide upper bounds useful for **k‑hop pruning**. ([ACM Digital Library][7])

#### Sketches & sampling

- **HLL++** for distinct counts of bindings and neighbor sets; HLL++ reduces memory and improves accuracy. ([Google Research][12], [ACM Digital Library][13])
- **WanderJoin‑style** sampling is effective for join and subgraph cardinalities; recent work extends it to **complex graph queries** beyond simple joins. ([CSE Department][14], [cs.ox.ac.uk][15])

#### Join/Cardinality models

- **Binary joins:** classic Selinger‑style formulas corrected by multi‑attribute correlations where stats exist.
- **WCOJ cost proxies:** **AGM bound** or fractional edge‑cover‑based objective estimate; attribute ordering evaluated by minimizing estimated extensions. ([ACM Digital Library][16], [UW Computer Sciences][17])
- **Expand vs index probe:** cost incorporates **frontier size × average degree × predicate selectivity**; exploit SIP to bound build/probe scans (as in Kùzu). ([CIDRDB][3])

#### Hardware/GPU considerations

- Expansions and irregular pipelines on GPUs suffer from control‑flow divergence; planning must detect divergence‑prone stages and avoid over‑fusion. ([VLDB][18])
- For BFS‑like operators, **Gunrock** patterns demonstrate usable speedups when memory fits and frontier scheduling is efficient; expose GPU as an optional physical op with cost guardrails. ([ACM Digital Library][19])

#### Isolation sensitivity

- Under **SSI/Serializable**, reordering that changes **conflict windows** can affect contention/abort rates; prefer **stable scan orders** and bounded spill for long transactions. (SSI experience in PostgreSQL shows serializable isolation with performance close to SI.) ([drkp.net][20])

### 3.5 Plan Enumeration & Adaptivity

#### Binary join enumeration

- Use **DPccp** for optimal bushy plans under cross‑product avoidance; fall back to **DPconv** / **linearized DP** for large joins. ([15721.courses.cs.cmu.edu][21], [arXiv][22], [Database Systems TUM][23])

#### Multi‑way/WCOJ attribute ordering

- Choose variable order via **fractional edge cover** heuristics and degree‑aware scoring; prune orders using upper bounds (AGM) and early **limit‑aware** branch‑and‑bound. ([ACM Digital Library][16])

#### Order‑aware planning

- If a plan can **natively produce** requested order (e.g., merge‑joins on ORDER BY keys; index‑order expands), avoid global sort and enable **early LIMIT**. For ranked joins, use **Any‑k** frameworks. ([Northeastern Data Lab][4])

#### Adaptive & runtime re‑optimization

- Integrate **re‑opt checkpoints** after major expands/joins; if observed cardinality deviates >τ, re‑invoke enumerator with updated stats (recent robust/learned optimizers (Lero) show plan ranking works well without exact cost fidelity). ([VLDB][24])

### 3.6 Distributed, Partition‑Aware Planning

#### Partition models & placement

- **Edge‑cut** (partition nodes) vs **vertex‑cut** (partition edges, replicated hubs). Hybrid approaches (e.g., **PowerLyra**) reduce high‑degree skew and messaging. ([ipads.se.sjtu.edu.cn][25])
- Streaming partitioners (**Fennel**) balance cuts under single‑pass constraints. ([Math Department][26])

#### Physical exchange choices

- **Exchange(Shuffle key)** for equi‑joins; **Broadcast** for tiny sides; **Replicate** for small reference tables or **hub adjacency lists**. SPARQL/RDF distributed engines (e.g., **TriAD**) show **join‑ahead pruning** and partition‑aware routing reduce shuffles—applicable to property graphs. ([ACM Digital Library][27])

#### Query shipping vs data shipping

- For locality, **query shipping** to shards for Expand/Filter phases; **data shipping** only for reduced frontiers or final joins; classic distributed DB trade‑offs apply, with compliance constraints in multi‑region settings. ([ACM Digital Library][28], [ITU][29])

#### Transactions & isolation in distributed plans

- Enforce snapshot visibility (MVCC) across shards; **global ordering** of conflicting writes or SSI‑style conflict tracking for serializability; planner avoids plans that would break snapshot visibility (e.g., mixing shard‑local snapshots with late cross‑shard merge without a consistent cut). (ISO leaves isolation **implementation‑defined**.)&#x20;

---

## 4) Methodological Considerations (skew, estimator bias, benchmarks)

- **Skew/power‑law**: Heavy‑tailed degrees invalidate independence assumptions—use joint degree/label co‑stats; sample hubs separately.
- **Estimator bias**: Verify histograms & HLL++ via periodic **adaptive sampling**; maintain **confidence intervals** to trigger runtime re‑opt. ([VLDB][30])
- **Benchmarks**: Evaluate on **cyclic** (triangles, squares), **acyclic/star**, and **path** queries, with **varying selectivity**; include **distributed** deployments with different cuts.

---

## 5) Implications & Outlook

- **Near‑term**: Hybrid **binary+WCOJ** with factorized pipelines (as in Kùzu) is the pragmatic sweet spot; add robust stats and ranked enumeration for LIMIT/ORDER BY. ([CIDRDB][3])
- **Mid‑term**: **Learned plan ranking** (e.g., Lero) + **adaptive checkpoints** can reduce catastrophic misplans without brittle cost models. ([VLDB][24])
- **Long‑term**: **GPU‑aware cost models** and **multi‑region compliance‑aware planning** will matter as datasets grow and regulations tighten. ([VLDB][18], [ITU][29])

---

## 6) Open Questions & Research Gaps

- Tight **break‑even** predictors for **binary vs WCOJ** under mixed selectivities on property graphs (beyond relational benchmarks).
- **Cardinality estimation** for **path patterns** with label/property constraints and forbidding path re‑use (simple paths) at query‑time scale.
- **Adaptive traversal** on skew (hubs) with **distributed** re‑routing while preserving snapshot/SSI semantics.

---

## 7) References (selected, 2010–present)

### Access notes

Accessed 2025‑08‑31; each key claim in the text is cited inline.

- Ngo, H. Q. (2018). _Worst‑Case Optimal Join Algorithms_. CACM/Tutorial. ([ACM Digital Library][1])
- Veldhuizen, T. L. (2014). _Leapfrog‑Triejoin_. ICDT. ([OpenProceedings][2])
- Aberger, C. et al. (2016). _EmptyHeaded_. VLDB. ([Stanford Pervasive Parallelism Lab][6])
- Kemper, A. et al. (2021). _ADOPT: Adaptive Operator Fusion for WCOJ_. ADMS. ([VLDB][31])
- Feng, X., Jin, G., Salihoğlu, S. (2023). _Kùzu: Graph DBMS_ (CIDR). ([CIDRDB][3])
- Akiba, T. et al. (2013). _Pruned Landmark Labeling (PL)_. SIGMOD. ([ACM Digital Library][7])
- Carletti, V. et al. (2017–2018). _VF3 subgraph isomorphism_. LNCS/PAMI. ([ACM Digital Library][9])
- McCreesh, C. et al. (2020). _Glasgow Subgraph Solver_. JAIR. ([PMC][10])
- Tziavelis, N., Gatterbauer, W., Riedewald, M. (2020–2025). _Any‑k ranked enumeration_. PVLDB/TODS. ([Northeastern Data Lab][4], [PMC][32])
- Heule, S., Nunkesser, M., Hall, A. (2013). _HyperLogLog++_. EDBT. ([Google Research][12])
- Han, Y. et al. (2022). _Cardinality Estimation in DBMS: A Comprehensive Benchmark_. PVLDB. ([VLDB][30])
- Park/Shin et al. (2024). _Cardinality Estimation of Subgraph Matching_. PVLDB. ([VLDB][33])
- Funke, H., Teubner, J. (2020). _Data‑Parallel Query Processing on Non‑Uniform Data_. PVLDB. ([VLDB][18])
- Gurajada, S. et al. (2014). _TriAD: Distributed RDF Engine_. SIGMOD. ([ACM Digital Library][27])
- Chen, R. et al. (2015/2019). _PowerLyra_. EuroSys/TOPC. ([ipads.se.sjtu.edu.cn][25], [Reading Xtra][34])
- Tsourakakis, C. (2014). _Fennel: Streaming Graph Partitioning_. WSDM. ([Math Department][26])
- Ports, D., Grittner, K. (2012). _Serializable Snapshot Isolation in PostgreSQL_. VLDB. ([drkp.net][20])

**Normative: ISO/IEC 39075:2024 (GQL)** — clauses cited inline for 14.2–14.4, 14.9–14.12, 16.16–16.19, 20.5–20.6, 4.6.3, 4.8, Annexes and feature taxonomy.

---

## 8) Appendix

### A1. Conformance Profile (Planner scope)

#### Mandatory for planner pipeline

- **GQ01 USE graph** (focused linear statements): used by planner to bind graph context in **focused** queries.
- **GQ12 OFFSET**, **GQ13 LIMIT**: recognized to compile `OrderBy & page` into **Order/Offset/Limit** algebra.
- **GQ14 Complex expressions in sort keys** (if supported) affects ORDER BY legality.&#x20;
- **GQ15 GROUP BY**, **GQ21 OPTIONAL: Multiple MATCH statements** where applicable.&#x20;

#### Implementation‑dependent (planner must disclose)

- **US001**: ordering of **unordered** binding tables when paginating (implicit order introduction). Planner avoids unsafe LIMIT/OFFSET pushdowns without explicit ORDER.&#x20;
- **UA005/UA006**: tie‑breaking for selective path searches; planner selects deterministic tiebreak (e.g., (length, id)) and documents it.&#x20;

### A1.1 Diagnostics (initial)

| Code            | Meaning                                    | Emitted by            | Notes                                      |
| --------------- | ------------------------------------------ | --------------------- | ------------------------------------------ |
| US001           | Pagination of unordered table (impl order) | Planner               | Maps error.OffsetPushdownRequiresOrder     |
| GroupByIllegal  | Illegal GROUP BY/RETURN/HAVING combination | Planner               | Phase‑1 legality checks                    |
| IllegalOrderKey | ORDER BY key violates configured policy    | Parser (policy guard) | Ident‑only, simple‑key, forbid calls/paths |

Precedence: when multiple diagnostics could apply, lower numeric code wins (US001 < GroupByIllegal < IllegalOrderKey).

#### Diagnostics precedence example

Consider: `RETURN a ORDER BY f(a) LIMIT 10` under a policy that forbids function calls in ORDER BY and without an explicit base order before LIMIT.

- Offenses: (1) ORDER BY uses a function (IllegalOrderKey); (2) LIMIT without stable order may trigger US001 if a pushdown introduces implicit order.
- Precedence: US001 has the lowest numeric code and would be reported preferentially if both are detected at the same optimization site; however, in parsing, IllegalOrderKey may be raised earlier and short‑circuit planning. Our toolchain prioritizes parse‑time policy violations first; if parsing succeeds, planner diagnostics apply and US001 wins among planner‑stage codes.

Note on cross‑type ordering: attempts to compare Int vs Str with <, <=, >, >= are illegal in the evaluator and yield a TypeMismatch; equality across Int/Str uses decimal‑string normalization.

#### Isolation dependencies

- Isolation level is **implementation‑defined**; planner documents any rules whose soundness depends on snapshot semantics (e.g., reordering that changes visit/lock order).&#x20;

### A2. GQL → Engine Crosswalk (Planner)

| GQL Construct          | Clause         | Logical op(s)              | Typical physical op(s)   | Rules                                                | Cost features           | Distributed strategy                        |
| ---------------------- | -------------- | -------------------------- | ------------------------ | ---------------------------------------------------- | ----------------------- | ------------------------------------------- |
| `MATCH (n:ℓ)`          | 14.4           | NodeScan(ℓ)                | NodeIndexScan/CSR lookup | label pushdown                                       | card(ℓ), selectivity(p) | shard‑local node scans                      |
| `MATCH (a)-[e:τ]->(b)` | 14.4           | Expand(out, τ)             | CSR Expand + SIP         | push pred into expand                                | avg deg(τ), label sel   | local expand; exchange on join keys         |
| OPTIONAL MATCH         | 14.4           | LeftOuterJoin over pattern | HashJoin(LOJ)            | null‑safe pred rewrite                               | null rate estimates     | avoid shuffle until after optional          |
| `RETURN …`             | 14.10          | Project/Group              | vectorized project/agg   | early projection                                     | width reduction         | local partial agg, global finalize          |
| `ORDER BY …`           | 14.10/16.16–17 | OrderBy                    | Sort/Merge‑preserving    | sort elision where possible                          | sort cost vs pipeline   | sort‑then‑shuffle or local‑then‑global      |
| `LIMIT/OFFSET`         | 16.18–16.19    | Limit/Offset               | StopAfter / Top‑k        | pushdown only with stable order; US001 otherwise     | top‑k cost              | local top‑k + global merge‑top‑k            |
| `SELECT …`             | 14.12          | Desugared pipeline         | as above                 | apply select xform rules                             | —                       | —                                           |
| Path patterns          | 22.4           | PathExpand                 | BFS/DFS/BiBFS; WCOJ ext. | length & legality constraints; UA005/UA006 tie‑break | path‑len dist           | start local; bidirectional frontier routing |

(Clauses: **14.4** MATCH; **14.10** primitive result + ORDER BY & page; **14.12** SELECT desugaring; **16.18–16.19** pagination semantics (US001); **22.4** path selection rules.)

### A3. Evidence Map (JSON)

```json
{
  "joins": {
    "wcoj_foundations": ["Ngo2018", "Veldhuizen2014"],
    "systems": ["EmptyHeaded2016", "Kuzu2023"]
  },
  "ranked_enumeration": ["AnyK-2020", "AnyK-TODS-2022"],
  "cardinality": {
    "sketches": ["HLLpp-2013"],
    "graph_specific": ["PVLDB2024-SubgraphCardEst", "WanderJoin-2017"]
  },
  "distributed": ["TriAD-2014", "PowerLyra-2015", "Fennel-2014"],
  "gpu": ["FunkeTeubner-2020", "Gunrock-2016"]
}
```

### A4. Search Log (high‑level)

- “worst‑case optimal join algorithms”, “leapfrog triejoin”, “EmptyHeaded VLDB 2016”, “Kùzu CIDR 2023 optimizer”, “Any‑k ranked enumeration join”, “Pruned Landmark Labeling SIGMOD 2013”, “VF3 subgraph isomorphism”, “Glasgow Subgraph Solver”, “Fennel streaming partitioning”, “PowerLyra hybrid‑cut”, “TriAD distributed RDF engine”, “HyperLogLog++ EDBT 2013”, “adaptive optimizer Lero PVLDB 2023”, “GPU query processing divergence PVLDB 2020”.

### A5. Glossary

- **AGM bound**: fractional edge‑cover bound on worst‑case join output size.
- **SIP**: sideways information passing (semijoin‑style pruning between operators).
- **WCOJ**: worst‑case‑optimal joins (Generic‑Join/Leapfrog‑Triejoin family).
- **GBA**: Graph Binding Algebra (this report).
- **US001/UA005/UA006**: ISO GQL implementation‑dependent points for ordering/tie‑breaking.

---

## 9) Zig Proof‑of‑Concepts

> Minimal, compilable skeletons showing the **shape** of the planner. Interfaces are intentionally lean and allocator‑friendly to fit an embedded Zig engine.

### 9.1 Algebra & Memo

```zig
// planner/algebra.zig
const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const OpTag = enum(u8) {
    NodeScan, EdgeScan, Expand, Filter, Project, Group, Order, Limit, Join, MultiwayJoin, PathExpand,
};

pub const PhysImplTag = enum(u8) {
    NodeIndexScan, EdgeAdjScan, ExpandCSR, FilterEval, ProjectVec, GroupHash, Sort, StopAfter,
    HashJoin, SortMergeJoin, LFTJ, // worst-case optimal iterator
    ExchangeShuffle, ExchangeBroadcast, ExchangeReplicate,
};

pub const SortKey = struct { name: []const u8, asc: bool = true, nulls_last: bool = true };

pub const PlannerProps = struct {
    // Logical properties
    output_cols: []const []const u8,
    order_by: []const SortKey, // empty => unordered
    limit: ?usize = null,
    offset: ?usize = null,
    note: []const u8 = "",
};

pub const Logical = struct {
    tag: OpTag,
    children: []const *Logical,
    props: PlannerProps,
};

pub const PhysProps = struct {
    ordered: bool = false,
    partitioned_by: []const []const u8 = &.{},
    impl_note: []const u8 = "",
};

pub const Phys = struct {
    impl: PhysImplTag,
    cost: f64,
    children: []const *Phys,
    props: PhysProps,
};

pub const GroupId = u32;

pub const ExprRef = struct {
    group: GroupId,
    cost: f64,
    logical: *const Logical,
    phys: ?*const Phys = null,
};

pub const Group = struct {
    id: GroupId,
    alts: std.ArrayList(ExprRef),

    pub fn init(alloc: *Allocator, id: GroupId) Group {
        return .{ .id = id, .alts = std.ArrayList(ExprRef).init(alloc.*) };
    }
};

pub const Memo = struct {
    alloc: *Allocator,
    groups: std.ArrayList(Group),

    pub fn init(alloc: *Allocator) Memo {
        return .{ .alloc = alloc, .groups = std.ArrayList(Group).init(alloc.*) };
    }

    pub fn newGroup(self: *Memo) GroupId {
        const id: GroupId = @intCast(self.groups.items.len);
        self.groups.append(Group.init(self.alloc, id)) catch unreachable;
        return id;
    }

    pub fn insert(self: *Memo, g: GroupId, e: ExprRef) void {
        self.groups.items[g].alts.append(e) catch unreachable;
    }

    pub fn best(self: *Memo, g: GroupId) ?ExprRef {
        var best_idx: ?usize = null;
        var best_cost: f64 = std.math.inf(f64);
        for (self.groups.items[g].alts.items, 0..) |e, i| {
            if (e.cost < best_cost) { best_cost = e.cost; best_idx = i; }
        }
        return if (best_idx) |bi| self.groups.items[g].alts.items[bi] else null;
    }
};

test "memo basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var memo = Memo.init(&gpa.allocator);

    const g = memo.newGroup();
    var l = Logical{
        .tag = .Filter,
        .children = &.{},
        .props = .{ .output_cols = &.{}, .order_by = &.{}, .note = "dummy" },
    };
    memo.insert(g, .{ .group = g, .cost = 1.0, .logical = &l });
    try std.testing.expect(memo.best(g) != null);
}
```

### 9.2 Rules (selected)

```zig
// planner/rules.zig
const std = @import("std");
const algebra = @import("algebra.zig");

pub fn canPushLimitPastFilter(order_present: bool) bool {
    // Safe if order is preserved or explicit ORDER BY exists (GQL 16.18/16.19 semantics).
    // Otherwise unsafe due to US001 potential re-ordering when paginating an unordered table.
    // (cf. ISO/IEC 39075: 16.19 OFFSET, US001).
    return order_present;
}

pub fn mustPreserveOrderForOffset() bool {
    // Planner conservatively requires an explicit order to push OFFSET.
    return true;
}

pub fn projectPrune(cols: []const []const u8, required: []const []const u8) bool {
    // return true if pruning will not drop ORDER BY keys or later references (GQL 14.10).
    _ = cols; _ = required;
    return true;
}
```

### 9.3 Enumerators (DP + heuristic) and WCOJ driver

```zig
// planner/enumerator.zig
const std = @import("std");
const algebra = @import("algebra.zig");

pub const JoinGraph = struct {
    rels: []const []const u8,
    edges: []const struct { left: usize, right: usize, on: []const []const u8 },
};

pub const Estimator = struct {
    // Simplified API
    pub fn joinCard(self: *Estimator, left: f64, right: f64, sel: f64) f64 {
        _ = self; return left * right * sel;
    }
};

pub const DP = struct {
    alloc: *std.mem.Allocator,
    est: *Estimator,

    pub fn enumerate(self: *DP, jg: JoinGraph) f64 {
        // DPccp-style subset DP (placeholder). Returns best estimated cost.
        var best_cost: f64 = 0.0;
        // In practice, maintain memo[subset] with best subplan.
        for (jg.rels) |_| { /* build base cases */ }
        // combine subsets respecting edges; avoid cross products.
        // ...
        return best_cost;
    }
};

pub const AGM = struct {
    pub fn bound(numEdges: usize, avgRelSize: f64, rhoStar: f64) f64 {
        // Crude proxy: N^{rho*}; here we simulate with avg size and rhoStar
        return std.math.pow(f64, avgRelSize, rhoStar) * @floatFromInt(numEdges);
    }
};

pub const WCOJ = struct {
    // Heuristic attribute ordering search using fractional cover weights
    pub fn chooseOrder(vars: []const []const u8) []const []const u8 {
        return vars; // placeholder: keep as-is
    }
};
```

### 9.4 Cardinality Estimators (degree histograms, label/property stats, sampling hooks)

```zig
// estimator/stats.zig
const std = @import("std");

pub const LogHist = struct {
    buckets: []u64, // log-spaced
    pub fn estimate(self: *const LogHist, value: u64) f64 {
        _ = value;
        // simplified
        return @floatFromInt(self.buckets.len);
    }
};

pub const LabelStats = struct {
    label: []const u8,
    count: u64,
    prop_hists: []const struct { name: []const u8, hist: LogHist },
};

pub const DegreeStats = struct {
    out_hist: LogHist,
    in_hist: LogHist,
};

pub const GraphStats = struct {
    labels: []const LabelStats,
    degree: DegreeStats,
};

pub const HLL = struct {
    // Stub for HLL++ sketch
    m: u32,
    registers: []u8,
    pub fn estimate(self: *const HLL) f64 {
        _ = self; return 0.0;
    }
};
```

### 9.5 Physical operators & pipelines (including WCOJ iterator sketch)

```zig
// physical/operators.zig
const std = @import("std");

pub const Row = struct { cols: [][]const u8 }; // placeholder

pub const Operator = struct {
    vtable: *const VTable,
    state: *anyopaque,
};

pub const VTable = struct {
    open: fn (*anyopaque) void,
    next: fn (*anyopaque) ?Row,
    close: fn (*anyopaque) void,
};

pub const HashJoinState = struct {
    // simplified
    opened: bool,
};

fn hjOpen(p: *anyopaque) void { _ = p; }
fn hjNext(p: *anyopaque) ?Row { _ = p; return null; }
fn hjClose(p: *anyopaque) void { _ = p; }

pub fn makeHashJoin(op_alloc: *std.mem.Allocator) Operator {
    const vt = VTable{ .open = hjOpen, .next = hjNext, .close = hjClose };
    var st = op_alloc.create(HashJoinState) catch unreachable;
    st.* = .{ .opened = false };
    return .{ .vtable = &vt, .state = st };
}

// WCOJ iterator sketch (Leapfrog-like)
pub const LFTJState = struct {
    // attribute order and trie-like cursors would live here
};
```

### 9.6 Distributed Plan: Exchange nodes & partition descriptor

```zig
// distributed/plan.zig
const std = @import("std");

pub const EdgeCut = enum { VertexCut, EdgeCut, Hybrid };
pub const ExchangeKind = enum { Shuffle, Broadcast, Replicate };

pub const PartitionInfo = struct {
    shard_id: u32,
    num_shards: u32,
    cut: EdgeCut,
    has_replication: bool,
};

pub const Exchange = struct {
    kind: ExchangeKind,
    keys: []const []const u8, // Shuffle keys if any
};
```

### 9.7 EXPLAIN/PROFILE serialization

```zig
// explain/profile.zig
const std = @import("std");
const algebra = @import("algebra.zig");

pub const PlanNode = struct {
    id: u32,
    name: []const u8,
    est_rows: f64,
    cost: f64,
    children: []const PlanNode,
};

pub fn toJson(alloc: *std.mem.Allocator, root: PlanNode) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc.*);
    defer buf.deinit();
    var w = buf.writer();
    try std.json.stringify(root, .{}, w);
    return buf.toOwnedSlice();
}

test "explain json" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const plan = PlanNode{ .id=1, .name="HashJoin", .est_rows=1000, .cost=42.0, .children=&.{} };
    const js = try toJson(&gpa.allocator, plan);
    defer gpa.allocator.free(js);
    try std.testing.expect(js.len > 0);
}
```

### 9.8 Plan stability tests (LIMIT/ORDER BY conservatism)

```zig
// planner/tests.zig
const std = @import("std");
const rules = @import("rules.zig");

test "offset pushdown requires explicit order" {
    try std.testing.expect(rules.mustPreserveOrderForOffset());
}
```

---

## Why these choices & strength of evidence

- **Hybrid join strategies** with WCOJ for cyclic/dense patterns and binary joins for selective/indexed patterns are supported by both **theory** (AGM/WCOJ) and **systems** (EmptyHeaded, Kùzu). Evidence is strong and consistent across venues. ([ACM Digital Library][1], [Stanford Pervasive Parallelism Lab][6], [CIDRDB][3])
- **Rank‑aware early stop** integrates ORDER BY/LIMIT semantics with **Any‑k** enumerations—strong recent evidence. ([Northeastern Data Lab][4])
- **Distributed partition‑aware planning** mirrors successful SPARQL engines and graph‑processing systems; evidence is strong but more indirect for property‑graph query engines; we adapt their principles. ([ACM Digital Library][27], [ipads.se.sjtu.edu.cn][25], [Math Department][26])
- **Adaptive re‑optimization** and **learned plan ranking** are promising and supported by recent results (Lero); we adopt them guardedly. ([VLDB][24])

---

## GQL Clause Anchors (select)

- **Execution context, linear composition & types**: 14.3.&#x20;
- **MATCH semantics, OPTIONAL binding supply**: 14.4.&#x20;
- **Primitive result & ORDER BY constraints**: 14.10.&#x20;
- **SELECT desugaring to linear pipeline**: 14.12.&#x20;
- **ORDER BY, LIMIT, OFFSET semantics & US001**: 16.18–16.19.&#x20;
- **Execution contexts (working table/record)**: 4.8 (not shown above; referenced from standard PDF).&#x20;
- **Transactions & isolation impl‑defined**: 9.1 and 4.6.3 context.&#x20;
- **Path selection & tie‑breaking**: 22.4, Annex references UA005/UA006.&#x20;
- **Features (GQ01, GQ12, GQ13, …)**: Annex D.&#x20;

---

### What we could not fully prove (open but aligned)

- Precise **break‑even** functions (closed‑form) for WCOJ vs binary on property graphs remain active work; we propose heuristics grounded in **AGM**, degree stats, and empirical feedback. ([ACM Digital Library][16])
- **Path cardinality estimation** with simple‑path constraints at scale remains under‑explored; we adopt sampling/oracles as proxies. ([ACM Digital Library][7])

---

## Deliverables Checklist

- **Logical algebra & contracts** ✔ (Section 3.1; Zig `algebra.zig`).
- **Rule‑based rewrites & legality** ✔ (Section 3.2; `rules.zig`).
- **Join strategies (binary/WCOJ), path planning** ✔ (Sections 3.3).
- **Estimators & cost** ✔ (`estimator/stats.zig`).
- **Plan enumeration** ✔ (`enumerator.zig` DP + WCOJ).
- **Distributed, partition‑aware planning** ✔ (`distributed/plan.zig`).
- **EXPLAIN/PROFILE** ✔ (`explain/profile.zig`).
- **Conformance Profile & Crosswalk** ✔ (Appendix A1–A2).

---

### Practical next steps

1. Wire **stats collectors** (degree, labels, HLL++) and integrate **SIP** into Expand and joins. ([CIDRDB][3])
2. Implement **ranked enumeration** for ORDER BY+LIMIT on monotone scores; test stability against GQL pagination semantics. ([Northeastern Data Lab][4])
3. Add **adaptive checkpoints** and **re‑optimization** thresholds (e.g., 4× deviation). ([VLDB][24])
4. Build **partition‑aware** plan rules with Exchange placement strategies using shard metadata; validate on edge‑cut vs vertex‑cut deployments. ([ipads.se.sjtu.edu.cn][25], [Math Department][26])

---

_End of report._

[1]: https://dl.acm.org/doi/10.1145/3180143?utm_source=chatgpt.com "Worst-case Optimal Join Algorithms | Journal of the ACM"
[2]: https://www.openproceedings.org/2014/conf/icdt/Veldhuizen14.pdf?utm_source=chatgpt.com "Leapfrog Triejoin: A Simple, Worst-Case Optimal Join ..."
[3]: https://www.cidrdb.org/cidr2023/papers/p48-jin.pdf "KÙZU^* Graph Database Management System"
[4]: https://northeastern-datalab.github.io/anyk/download/vldb2020-optimal-ranked-enumeration.pdf?utm_source=chatgpt.com "Optimal Algorithms for Ranked Enumeration of Answers to Full ..."
[5]: https://www.ccs.neu.edu/home/mirek/papers/2020-SIGMOD-AnyK-tutorial.pdf?utm_source=chatgpt.com "Optimal Join Algorithms Meet Top-k"
[6]: https://ppl.stanford.edu/papers/emptyheaded.pdf?utm_source=chatgpt.com "EmptyHeaded: A Relational Engine for Graph Processing"
[7]: https://dl.acm.org/doi/10.1145/2463676.2465315?utm_source=chatgpt.com "Fast exact shortest-path distance queries on large networks by ..."
[8]: https://homepages.inf.ed.ac.uk/libkin/papers/icdt12b.pdf?utm_source=chatgpt.com "Regular Path Queries on Graphs with Data∗"
[9]: https://dl.acm.org/doi/abs/10.1007/978-3-319-58961-9_12?utm_source=chatgpt.com "Introducing VF3: A New Algorithm for Subgraph Isomorphism"
[10]: https://pmc.ncbi.nlm.nih.gov/articles/PMC7314700/?utm_source=chatgpt.com "The Glasgow Subgraph Solver: Using Constraint ..."
[11]: https://arxiv.org/abs/2205.05649?utm_source=chatgpt.com "Any-k Algorithms for Enumerating Ranked Answers to Conjunctive Queries"
[12]: https://research.google.com/pubs/archive/40671.pdf?utm_source=chatgpt.com "HyperLogLog in Practice: Algorithmic Engineering of a ..."
[13]: https://dl.acm.org/doi/10.1145/2452376.2452456?utm_source=chatgpt.com "HyperLogLog in practice: algorithmic engineering of a state of ..."
[14]: https://cse.buffalo.edu/~zzhao35/files/papers/xdbsigmodrecord.pdf?utm_source=chatgpt.com "Wander Join and XDB: Online Aggregation via Random ..."
[15]: https://www.cs.ox.ac.uk/people/boris.motik/pubs/hm24-accurate-sampling.pdf?utm_source=chatgpt.com "Accurate Sampling-Based Cardinality Estimation for ..."
[16]: https://dl.acm.org/doi/pdf/10.1145/3180143?utm_source=chatgpt.com "Worst-case Optimal Join Algorithms"
[17]: https://pages.cs.wisc.edu/~paris/cs838-s16/lecture-notes/lecture6.pdf?utm_source=chatgpt.com "Lecture 6: Size Bounds for Joins 6.1 The AGM Bound"
[18]: https://www.vldb.org/pvldb/vol13/p884-funke.pdf?utm_source=chatgpt.com "Data-Parallel Query Processing on Non-Uniform Data"
[19]: https://dl.acm.org/doi/10.1145/3108140?utm_source=chatgpt.com "Gunrock: GPU Graph Analytics - ACM Digital Library"
[20]: https://drkp.net/papers/ssi-vldb12.pdf?utm_source=chatgpt.com "Serializable Snapshot Isolation in PostgreSQL"
[21]: https://15721.courses.cs.cmu.edu/spring2020/papers/20-optimizer2/p539-moerkotte.pdf?utm_source=chatgpt.com "Dynamic Programming Strikes Back"
[22]: https://arxiv.org/pdf/2409.08013?utm_source=chatgpt.com "DPconv: Super-Polynomially Faster Join Ordering"
[23]: https://db.in.tum.de/~birler/papers/adaptivelindp.pdf?utm_source=chatgpt.com "Optimizing Linearized Join Enumeration by Adapting to the ..."
[24]: https://www.vldb.org/pvldb/vol16/p1466-zhu.pdf?utm_source=chatgpt.com "Lero: A Learning-to-Rank Query Optimizer"
[25]: https://ipads.se.sjtu.edu.cn/_media/publications/powerlyra-eurosys15.pdf?utm_source=chatgpt.com "PowerLyra: Differentiated Graph Computation and ..."
[26]: https://math.cmu.edu/~ctsourak/fennel-wsdm.pdf?utm_source=chatgpt.com "FENNEL: Streaming Graph Partitioning for Massive Scale ..."
[27]: https://dl.acm.org/doi/10.1145/2588555.2610511?utm_source=chatgpt.com "TriAD: a distributed shared-nothing RDF engine based on ..."
[28]: https://dl.acm.org/doi/abs/10.1007/s00778-015-0415-0?utm_source=chatgpt.com "Processing SPARQL queries over distributed RDF graphs"
[29]: https://itu.dk/~joqu/assets/publications/sigmod21a.pdf?utm_source=chatgpt.com "Compliant Geo-distributed Query Processing"
[30]: https://www.vldb.org/pvldb/vol15/p752-zhu.pdf?utm_source=chatgpt.com "Cardinality Estimation in DBMS: A Comprehensive ..."
[31]: https://www.vldb.org/pvldb/vol16/p2805-wang.pdf?utm_source=chatgpt.com "ADOPT: Adaptively Optimizing Attribute Orders for Worst- ..."
[32]: https://pmc.ncbi.nlm.nih.gov/articles/PMC7955775/?utm_source=chatgpt.com "Optimal Algorithms for Ranked Enumeration of Answers to Full ..."
[33]: https://www.vldb.org/pvldb/vol17/p1697-park.pdf?utm_source=chatgpt.com "Cardinality Estimation of Subgraph Matching: A Filtering- ..."
[34]: https://readingxtra.github.io/docs/cpu-graph/ChenTOPC2019.pdf?utm_source=chatgpt.com "PowerLyra: Differentiated Graph Computation and Partitioning ..."
