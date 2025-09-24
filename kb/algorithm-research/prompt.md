Below is a **ready‑to‑run research prompt** you (or your team/agent) can execute to compile a comprehensive, implementation‑ready catalog of graph algorithms for use in a graph database. It sets scope, required outputs, evidence rules, and includes exemplar **pseudocode** and **DB‑usage snippets** so the final deliverable is concrete rather than theoretical.

**As of 2025‑09‑21.**

---

## Research Prompt — _Comprehensive Graph Algorithms Catalog for a Graph Database_

### 0) Goal & Success Criteria

**Goal.** Produce an implementation‑ready catalog of graph algorithms covering traversal, paths, connectivity, cuts/flows, centrality, community detection, similarity/link prediction, matching, spanning structures, clustering/triangles, embeddings, isomorphism/queries. Each entry must include: what it does, input/output contracts, complexity, directed/undirected & weighted/unweighted support, **pseudocode**, and **how to run it in leading graph databases** (Neo4j GDS, TinkerPop/Gremlin, TigerGraph GSQL, ArangoDB Pregel; optional: Memgraph MAGE, NebulaGraph).

**Success =** (a) coverage across families below; (b) runnable examples in at least **two** DBs per algorithm; (c) clear evidence (primary sources, docs) with DOI/URL + accessed date; (d) reproducible tests.

---

### 1) Scope & Sub‑questions (SQs)

1. **Coverage.** Which canonical algorithms belong to each family (below) and which variants matter in production?
2. **Contracts.** For each algorithm: required graph features (directed? weighted?), parameters, outputs, complexity and typical caveats.
3. **Implementation.** What **pseudocode** best reflects standard references, and what implementation notes matter for property‑graph databases?
4. **DB Usage.** For each algorithm, what are the exact calls in **Neo4j GDS**, **Gremlin/TinkerPop**, **TigerGraph GSQL**, **ArangoDB Pregel** (plus Memgraph/NebulaGraph where appropriate)?
5. **Performance.** What data sizes and time/memory profiles are typical; how to project graphs to in‑memory representations safely?
6. **Validation.** What datasets and assertions verify correctness (e.g., Karate, Les Misérables, SNAP datasets)?
7. **Alternatives.** When multiple algorithms solve the same task, how to choose (assumptions, trade‑offs, license/availability)?

---

### 2) Deliverables

- **D1. Algorithms Catalog (Markdown/HTML)** — one page per algorithm (“Algorithm Card”) using the schema in §3.
- **D2. Code Annex** — pseudocode + runnable examples for at least 2 DBs per algorithm; include sample inputs/outputs.
- **D3. Test Harness** — scripts/queries to reproduce results on toy datasets; include performance notes and edge cases.
- **D4. References** — tiered bibliography (peer‑reviewed/regulator docs first), **with DOI/URL and Accessed date**.
- **(Optional) D5. Evidence Map (JSON)** — trace claims ↔ sources (template at the end).

---

### 3) Required Algorithm Card Schema (use for each algorithm)

- **Name**; **Family** (Traversal/Path, Connectivity, Flow/Cut, Centrality, Community, Similarity/Link Prediction, Matching/Assignment, Spanning, Triangles/Clustering, Embedding, Isomorphism, Misc).
- **Problem Statement** (inputs/outputs, graph assumptions: directed/undirected; weighted/unweighted; multi‑edges).
- **Complexity** (time/space; note data structures).
- **Pseudocode** (indented code; language‑agnostic).
- **Implementation Notes** (pitfalls, heuristics, numeric stability).
- **DB Usage**

  - **Neo4j GDS**: projection + `CALL gds.*` example. ([Graph Database & Analytics][1])
  - **Gremlin/TinkerPop**: `withComputer().V().pageRank()…` or `ConnectedComponentVertexProgram` etc. ([tinkerpop.apache.org][2])
  - **TigerGraph GSQL**: packaged `CALL` or `RUN QUERY tg_*` usage. ([TigerGraph Documentation][3])
  - **ArangoDB Pregel**: REST `/_api/control_pregel` or driver; algorithm names. ([ArangoDB Docs][4])
  - _(Optional)_ **Memgraph MAGE** (`CALL pagerank.get()` etc.) and **NebulaGraph Algorithm**. ([Memgraph][5])

- **Example Query & Result Snippet** (small graph; copy‑paste runnable).
- **Primary Source(s)** (paper/docs with DOI/URL + accessed date).
- **Known Variants** (e.g., _Personalized_ PageRank; _Leiden_ vs _Louvain_; _Dinic_ vs _Edmonds–Karp_).

---

### 4) Coverage Checklist (include at minimum)

- **Traversal/Paths:** BFS, DFS; Dijkstra; Bellman–Ford; Floyd–Warshall; Johnson; A\* (with admissible heuristic). ([SpringerLink][6])
- **Connectivity/Ordering:** Weak/Strongly Connected Components (Tarjan, Kosaraju); Topological Sort (Kahn). ([SIAM E-Books][7])
- **Spanning Structures:** Minimum Spanning Tree (Kruskal/Prim/Borůvka). ([SCIRP][8])
- **Flows/Cuts:** Max‑Flow/Min‑Cut (_Edmonds–Karp_, _Dinic_, _Push‑Relabel_), Global Min‑Cut (Stoer–Wagner), Gomory–Hu tree. ([Jamie Heller][9])
- **Centrality:** Degree, Closeness, Betweenness (Brandes), Eigenvector (Bonacich), PageRank, HITS. ([SNAP][10])
- **Communities:** Louvain, Leiden, Label Propagation, Girvan–Newman, Infomap (optional). ([arXiv][11])
- **Similarity/Link Prediction:** Jaccard, Adamic–Adar, Resource Allocation, Katz. ([E-Periodica][12])
- **Matching/Assignment:** Hopcroft–Karp (bipartite), Hungarian/Kuhn–Munkres. ([SIAM E-Books][13])
- **Triangles/Clustering:** Triangle counting; local/global clustering coefficient (Watts–Strogatz). ([SpringerLink][14])
- **Embeddings:** DeepWalk, Node2Vec. ([ACM Digital Library][15])
- **Isomorphism/Subgraph Search:** Ullmann; VF2/VF2++/VF3. ([ACM Digital Library][16])
- **Planarity (optional):** Hopcroft–Tarjan planarity. ([ACM Digital Library][17])

---

## 5) Exemplars — Pseudocode + DB Usage

> Use these as patterns when you fill the catalog. Complexities assume adjacency lists; $n=|V|, m=|E|$.

### 5.1 Breadth‑First Search (BFS) — _Traversal/Unweighted SSSP_

**Complexity:** $O(n+m)$.
**Pseudocode**

```text
BFS(G=(V,E), s):
  for v in V: dist[v] := ∞; parent[v] := NIL
  dist[s] := 0
  Q := queue([s])
  while Q not empty:
    u := pop(Q)
    for each v where (u,v) ∈ E:
      if dist[v] = ∞:
        dist[v] := dist[u] + 1
        parent[v] := u
        push(Q, v)
  return dist, parent
```

**Neo4j GDS (project + run):**

```cypher
// Project (undirected, unweighted)
CALL gds.graph.project('g', 'Node', {REL:{orientation:'UNDIRECTED'}});

// Unweighted SSSP via BFS behavior (Dijkstra with unit weights)
MATCH (s:Node {id:$sid})
CALL gds.shortestPath.dijkstra.stream('g', {sourceNode:id(s)})
YIELD targetNode, totalCost
RETURN gds.util.asNode(targetNode).id AS id, totalCost ORDER BY totalCost;
```

GDS Dijkstra acts as BFS when all weights are 1. ([Graph Database & Analytics][18])
**Gremlin (outline):**

```groovy
// Layered expansion for k hops
g.V().has('id', sid).repeat(out()).times(k).path()
```

For true BFS distances, prefer DB‑provided shortest‑path facilities. (Gremlin shortestPath is OLAP/GraphComputer‑specific.) ([Stack Overflow][19])
**Primary sources:** standard texts; Tarjan’s DFS frameworks. ([SIAM E-Books][7])

---

### 5.2 Dijkstra (Single‑Source Shortest Paths, non‑negative weights)

**Complexity:** $O((n+m)\log n)$ with binary heap.
**Pseudocode**

```text
Dijkstra(G,w,s):
  for v in V: dist[v]:=∞; parent[v]:=NIL
  dist[s]:=0; H:=minPQ(); push(H,(0,s))
  while H not empty:
    (du,u):=extractMin(H)
    if du>dist[u]: continue
    for each (u,v) in E:
      alt := du + w(u,v)
      if alt < dist[v]:
        dist[v]:=alt; parent[v]:=u
        push(H,(alt,v))   // or decrease-key
  return dist, parent
```

**Neo4j GDS:**

```cypher
CALL gds.graph.project('g','Node',{ROAD:{properties:'cost'}});
MATCH (s:Node {id:$sid}), (t:Node {id:$tid})
CALL gds.shortestPath.dijkstra.stream('g',{
  sourceNode: id(s), targetNode: id(t), relationshipWeightProperty:'cost'
})
YIELD totalCost, nodeIds
RETURN totalCost, [n IN gds.util.asNodes(nodeIds) | n.id] AS path;
```

([Graph Database & Analytics][18])
**Primary source:** Dijkstra (1959). ([SpringerLink][6])

---

### 5.3 PageRank (Centrality)

**Update:** $PR^{(t+1)} = (1-\alpha)\tfrac{1}{n}{\bf 1} + \alpha \, P^\top PR^{(t)}$.
**Pseudocode**

```text
PageRank(G, α=0.85, T=20):
  PR[v] := 1/|V| for all v
  for t in 1..T:
    next[v] := (1-α)/|V|
  for each edge (u->v):
    next[v] += α * PR[u] / outdeg(u)
  PR := next
  handle dangling mass uniformly each iteration
return PR
```

**Neo4j GDS:**

```cypher
CALL gds.graph.project('g','Page',{LINK:{orientation:'NATURAL'}});
CALL gds.pageRank.write('g',{maxIterations:20,dampingFactor:0.85,
                             writeProperty:'pagerank'})
YIELD nodePropertiesWritten, ranIterations;
```

([Graph Database & Analytics][1])
**Gremlin/TinkerPop (OLAP/GraphComputer):**

```groovy
g.withComputer().V().pageRank().by('weight').by('rank').valueMap('rank')
```

`pageRank()` is a `VertexComputing` step. ([tinkerpop.apache.org][2])
**TigerGraph (GSQL library):** `CALL` packaged algorithm or `RUN QUERY tg_pagerank(...)` depending on server version. ([TigerGraph Documentation][3])
**ArangoDB Pregel (HTTP):** `POST /_api/control_pregel` with `{"algorithm":"pagerank","graphName":"G"}`; fetch results from vertex documents. ([ArangoDB Docs][20])
**Primary sources:** Brin & Page (1998). ([Infolab][21])

---

### 5.4 Betweenness Centrality (Brandes)

**Complexity:** $O(nm)$ (unweighted); $O(nm + n^2 \log n)$ (weighted).
**Pseudocode (Brandes 2001, unweighted)**

```text
for v in V: BC[v] := 0
for s in V:
  S := empty stack
  P[w] := empty list for all w
  σ[t] := 0 for all t; σ[s] := 1
  d[t] := -1 for all t; d[s] := 0
  Q := queue([s])
  while Q not empty:
    v := pop(Q); push(S, v)
    for w in N(v):
      if d[w] < 0: d[w] := d[v]+1; push(Q, w)
      if d[w] = d[v]+1: σ[w] += σ[v]; append v to P[w]
  δ[v] := 0 for all v
  while S not empty:
    w := pop(S)
    for v in P[w]: δ[v] += (σ[v]/σ[w]) * (1 + δ[w])
    if w ≠ s: BC[w] += δ[w]
return BC
```

**Neo4j GDS:** `CALL gds.betweenness.stream('g')`. ([Graph Database & Analytics][22])
**Primary source:** Brandes (2001). ([SNAP][10])

---

### 5.5 Louvain / Leiden (Community Detection)

**Idea:** modularity optimization; Leiden refines Louvain and guarantees well‑connected communities.
**Pseudocode (Louvain, high‑level)**

```text
Louvain(G):
  assign each node to its own community
  improved := true
  while improved:
    improved := false
    // Phase 1: local moving
    for v in V (random order):
      move v to neighbor community that maximizes Δ modularity (or stay)
    // Phase 2: aggregation
    build super-graph of communities; if #communities unchanged: break
    improved := true; G := super-graph
  return communities
```

**Neo4j GDS:**
`CALL gds.louvain.write('g',{writeProperty:'community'})`. ([Graph Database & Analytics][23])
**Leiden (reference):** guarantees connectedness; often faster/better partitions. ([Nature][24])
**TigerGraph:** `CALL louvain(...)` packaged or `RUN QUERY tg_louvain(...)`. ([TigerGraph Documentation][25])
**ArangoDB:** Pregel includes community/label‑propagation variants. ([ArangoDB Docs][26])
**Primary sources:** Blondel et al. (2008) Louvain; Traag et al. (2019) Leiden. ([arXiv][11])

---

### 5.6 Tarjan’s Strongly Connected Components (SCC)

**Complexity:** $O(n+m)$.
**Pseudocode (stack & lowlink)**

```text
index := 0; S := empty stack
for v in V: index[v]:=undef; onstack[v]:=false
SCC := []

function strongconnect(v):
  index[v] := low[v] := index; index := index + 1
  push(S, v); onstack[v] := true
  for w in N⁺(v):
    if index[w] is undef: strongconnect(w); low[v] := min(low[v], low[w])
    else if onstack[w]:   low[v] := min(low[v], index[w])
  if low[v] = index[v]:
    C := {}
    repeat: x := pop(S); onstack[x]:=false; add x to C
    until x = v; append C to SCC

for v in V: if index[v] is undef: strongconnect(v)
return SCC
```

**Neo4j GDS:** `CALL gds.stronglyConnectedComponents.stream('g')`. ([Graph Database & Analytics][27])
**Primary source:** Tarjan (1972). ([SIAM E-Books][7])

---

### 5.7 Minimum Spanning Tree — Kruskal

**Complexity:** $O(m\log m)$.
**Pseudocode**

```text
Kruskal(G,w):
  A := ∅; make-set(v) for v∈V
  sort edges E by w(e)
  for e=(u,v) in E (increasing):
    if find(u) ≠ find(v): A := A ∪ {e}; union(u,v)
  return A
```

**Notes:** requires disjoint‑set union with path compression & union‑by‑rank. ([ACM Digital Library][28])
**Primary sources:** Kruskal (1956), Prim (1957). ([SCIRP][8])

---

### 5.8 Max‑Flow — Dinic (a.k.a. Dinitz)

**Complexity:** $O(n^2 m)$ general; faster on unit networks.
**Pseudocode (high‑level)**

```text
Dinic(G,s,t):
  maxflow := 0
  while BFS builds level graph L from s to t:
    while blocking flow exists in L:
      send flow via DFS along admissible edges; update residuals
      maxflow += augment
  return maxflow
```

**Primary sources:** Dinic (1970); Edmonds–Karp (1972) alternative; Goldberg–Tarjan (1988) push‑relabel. ([Wikipedia][29])

---

### 5.9 Label Propagation (Communities)

**Pseudocode**

```text
init label[v] := id(v)
repeat until convergence or maxIters:
  for v in V (random order):
    label[v] := argmax_c count{u ∈ N(v) : label[u]=c} (break ties randomly)
```

**Primary source:** Raghavan et al. (2007). ([Physical Review Link Manager][30])

---

### 5.10 Triangle Counting (per‑node & global clustering)

**Pseudocode (ordered set intersection)**

```text
sort vertices by degree (tie by id); orient edges from lower → higher
for u in V:
  for v in N⁺(u):
    triangles[u] += |N⁺(u) ∩ N⁺(v)|
```

Compute local clustering: $C_u = 2T_u/(d_u(d_u-1))$. ([SpringerLink][14])
**Neo4j GDS:** `CALL gds.triangleCount.stream('g')`. ([Graph Database & Analytics][31])

---

### 5.11 Hopcroft–Karp (Maximum Bipartite Matching)

**Pseudocode (layered BFS + DFS of disjoint shortest augmenting paths)**

```text
M := ∅
repeat:
  build layers by BFS from free U across alternating unmatched/matched edges
  P := maximal set of vertex-disjoint shortest augmenting paths via DFS
  if P empty: break else M := M ⊕ P
return M
```

**Primary source:** Hopcroft & Karp (1973). ([SIAM E-Books][13])

---

### 5.12 Subgraph Isomorphism — VF2

**Idea:** DFS with feasibility rules and state pruning; good on sparse labeled graphs.
**Primary sources:** Ullmann (1976); Cordella et al. (2004, VF2); Jüttner et al. (2018, VF2++). ([ACM Digital Library][16])

> **Note (linear‑algebraic backend):** Some engines implement algorithms via **GraphBLAS** (sparse linear algebra on semirings). For the API and rationale, see GraphBLAS C API and SuiteSparse\:GraphBLAS. ([Welcome to the GraphBLAS Forum][32])

---

## 6) How to Use These in Graph Databases (patterns)

### 6.1 Neo4j Graph Data Science (GDS)

1. **Project** a subgraph into the GDS in‑memory graph:

```cypher
CALL gds.graph.project('g',
  {Node:{}},
  {REL:{orientation:'NATURAL', properties:'weight'}} );
```

2. **Run** in _stream_, _mutate_, or _write_ mode. Example — Louvain write:

```cypher
CALL gds.louvain.write('g',{writeProperty:'community'});
```

3. **Interpret** results and index written properties for downstream queries. ([Graph Database & Analytics][22])

Key docs: PageRank, Louvain, Dijkstra, TriangleCount. ([Graph Database & Analytics][1])

---

### 6.2 Gremlin / Apache TinkerPop

- OLAP algorithms (PageRank, Connected Components, PeerPressure/LPA) run via **GraphComputer**:

```groovy
g.withComputer().V().pageRank().by('weight').by('rank').iterate()
g.withComputer().V().connectedComponent().by('component').iterate()
```

`pageRank()` is a `VertexComputing` step; ensure OLAP engine (e.g., SparkGraphComputer). ([tinkerpop.apache.org][2])
Class docs: `PageRankVertexProgram`, `ConnectedComponentVertexProgram`. ([tinkerpop.apache.org][33])

---

### 6.3 TigerGraph (GSQL Graph Data Science Library)

- **Packaged algorithms** (Server ≥3.8):
  `CALL pagerank(…);` `CALL louvain(…);` parameters documented; or use legacy `RUN QUERY tg_pagerank(...)`. ([TigerGraph Documentation][3])
- Louvain documentation & supported graph characteristics. ([TigerGraph Documentation][25])

---

### 6.4 ArangoDB Pregel

- Start algorithm via REST:

```http
POST /_api/control_pregel
{"algorithm":"pagerank","graphName":"G","params":{"maxGSS":20}}
```

- Inspect vertex results (algorithm writes properties to vertices). ([ArangoDB Docs][20])

---

### 6.5 (Optional) Memgraph MAGE & NebulaGraph

- **Memgraph:** `CALL pagerank.get() YIELD node, rank SET node.rank = rank`. ([Memgraph][5])
- **NebulaGraph:** offloaded analytics via **Nebula Algorithm** (GraphX). ([Nebula Graph Docs][34])

---

## 7) Methodology & Evidence Rules

- **Tiering:** Prefer peer‑reviewed/theory (Tier A) for algorithm definitions; official vendor docs for DB usage (Tier B); news/blogs only for ancillary context (Tier C).
- **Recency:** Cite current DB docs (versions noted where relevant).
- **Reproducibility:** For each algorithm, include seed, parameters, and dataset hashes (if any).
- **Validation datasets:** Zachary’s Karate Club; SNAP samples; synthetic LFR communities.

---

## 8) Quality Gate (check before delivery)

- Complexity & contracts present for every algorithm.
- Pseudocode compiles conceptually; DB examples run on small toy graphs.
- At least **2 DBs covered per algorithm** where feasible; else justify (e.g., max‑flow not in some DBs).
- **References include DOI/URL + Accessed date** (see below).

---

## 9) Starter References (Primary & Docs)

> **Notation:** \[Accessed 2025‑09‑21]. The in‑line citations above refer to these entries.

**Shortest paths & traversals**

- Dijkstra, E. W. “A note on two problems in connexion with graphs.” _Numerische Mathematik_, 1959. DOI **10.1007/BF01386390**. ([SpringerLink][6])
- Floyd, R. W. “Algorithm 97: Shortest Path.” _Commun. ACM_, 1962. DOI **10.1145/367766.368168**. ([Semantic Scholar][35])
- Warshall, S. “A Theorem on Boolean Matrices.” _JACM_, 1962. DOI **10.1145/321105.321110**. ([Semantic Scholar][36])
- Johnson, D. B. “Efficient algorithms for shortest paths in sparse networks.” _JACM_, 1977. DOI **10.1145/321992.322005**. ([SCIRP][37])

**Connectivity, ordering**

- Tarjan, R. “Depth‑First Search and Linear Graph Algorithms.” _SICOMP_, 1972. DOI **10.1137/0201010**. ([SIAM E-Books][7])
- Kahn, A. B. “Topological sorting of large networks.” _Commun. ACM_, 1962. DOI **10.1145/368996.369025**. ([Semantic Scholar][38])

**Spanning trees**

- Kruskal, J. B. “On the shortest spanning subtree of a graph…” _Proc. AMS_, 1956. DOI **10.2307/2033241**. ([SCIRP][8])
- Prim, R. C. “Shortest connection networks and some generalizations.” _BSTJ_, 1957. DOI **10.1002/j.1538‑7305.1957.tb01515.x**. ([Wiley Online Library][39])

**Flows & cuts**

- Edmonds, J.; Karp, R. (1972). “Theoretical improvements in algorithmic efficiency for network flow problems.” _JACM_. DOI **10.1145/321694.321699**. ([Jamie Heller][9])
- Dinic, E. (1970). “Algorithm for maximal flow in a network.” _Doklady AN SSSR_. (English summaries available.) ([Wikipedia][29])
- Goldberg, A. V.; Tarjan, R. E. (1988) “A new approach to the maximum‑flow problem.” _JACM_. DOI **10.1145/42282.42283**. ([SpringerLink][40])
- Stoer, M.; Wagner, F. “A simple min‑cut algorithm.” _JACM_, 1997. DOI **10.1145/263867.263872**. ([ACM Digital Library][41])
- Gomory, R.; Hu, T. “Multi‑terminal network flows.” _SIAM Journal_, 1961. DOI **10.1137/0109047**. ([SIAM E-Books][42])

**Centrality**

- Brandes, U. “A faster algorithm for betweenness centrality.” _J. Math. Sociology_, 2001. DOI **10.1080/0022250X.2001.9990249**. ([SNAP][10])
- Bonacich, P. “Power and centrality.” _AJS_, 1987. DOI **10.1086/228631**. ([SCIRP][43])
- Brin, S.; Page, L. “The Anatomy of a Large‑Scale Hypertextual Web Search Engine.” 1998. (Google tech paper) URL. ([Infolab][21])
- Kleinberg, J. “Authoritative Sources in a Hyperlinked Environment.” _JACM_, 1999. DOI **10.1145/324133.324140**. ([ACM Digital Library][44])

**Communities**

- Blondel, V. D. et al. “Fast unfolding of communities…” _J. Stat. Mech._ (2008). arXiv:0803.0476. ([arXiv][11])
- Traag, V. A. et al. “From Louvain to Leiden…” _Sci. Rep._ 2019. DOI **10.1038/s41598‑019‑41695‑z**. ([Nature][24])
- Raghavan, U. N. et al. “Near linear time algorithm to detect community structures.” _Phys. Rev. E_, 2007. DOI **10.1103/PhysRevE.76.036106**. ([Physical Review Link Manager][30])
- Girvan, M.; Newman, M. “Community structure in social and biological networks.” _PNAS_ (2002). DOI **10.1073/pnas.122653799**. ([PNAS][45])

**Similarity & link prediction**

- Jaccard, P. (1901). Original similarity index; archival URL. ([E-Periodica][12])
- Adamic, L.; Adar, E. “Friends and neighbors on the Web.” _Social Networks_ (2003). DOI **10.1016/S0378‑8733(03)00009‑1**. ([ScienceDirect][46])
- Zhou, T. et al. “Predicting missing links via local information.” _Eur. Phys. J. B_ (2009). DOI **10.1140/epjb/e2009‑00335‑8**. ([SpringerLink][47])
- Katz, L. “A new status index…” _Psychometrika_ (1953). DOI **10.1007/BF02289026**. ([SpringerLink][48])

**Matching/assignment**

- Hopcroft, J.; Karp, R. “An $n^{5/2}$ algorithm for maximum matchings in bipartite graphs.” _SIAM J. Comput._, 1973. ([SIAM E-Books][13])
- Kuhn, H. “The Hungarian method for the assignment problem.” _NRL Quarterly_ (1955). PDF URL. ([EECS Department][49])

**Triangles/Clustering**

- Schank, T.; Wagner, D. “Finding, counting and listing all triangles…” (2005). LNCS chapter. ([ACM Digital Library][50])
- Watts, D.; Strogatz, S. “Collective dynamics of ‘small‑world’ networks.” _Nature_ (1998). DOI **10.1038/30918**. ([Nature][51])

**Embeddings**

- Perozzi, B. et al. “DeepWalk.” _KDD 2014_. DOI **10.1145/2623330.2623732**. ([ACM Digital Library][15])
- Grover, A.; Leskovec, J. “node2vec.” _KDD 2016_. DOI **10.1145/2939672.2939754**. ([ACM Digital Library][52])

**Isomorphism**

- Ullmann, J. R. “An algorithm for subgraph isomorphism.” _JACM_ (1976). DOI **10.1145/321921.321925**. ([ACM Digital Library][16])
- Cordella, L. et al. “(Sub)graph isomorphism for large graphs (VF2).” _TPAMI_ (2004). DOI **10.1109/TPAMI.2004.75**. ([PubMed][53])
- Jüttner, A. et al. “VF2++.” _Discrete Applied Mathematics_ (2018). ([ScienceDirect][54])

**Planarity**

- Hopcroft, J.; Tarjan, R. “Efficient Planarity Testing.” _JACM_ (1974). DOI **10.1145/321850.321852**. ([ACM Digital Library][17])

**DB Documentation (usage)**

- **Neo4j GDS:** PageRank; Louvain; Dijkstra; TriangleCount; procedures list. \[Docs URLs in citations]. ([Graph Database & Analytics][1])
- **TinkerPop/Gremlin:** reference docs; `pageRank()` step; vertex programs. ([tinkerpop.apache.org][55])
- **TigerGraph:** PageRank; Louvain; packaged algorithms. ([TigerGraph Documentation][56])
- **ArangoDB Pregel:** algorithms & REST API. ([ArangoDB Docs][4])
- **Memgraph MAGE:** PageRank usage. ([Memgraph][5])
- **NebulaGraph Algorithm:** overview. ([Nebula Graph Docs][34])
- **GraphBLAS:** API specs & SuiteSparse implementation. ([Welcome to the GraphBLAS Forum][32])

> **Accessed:** 2025‑09‑21 for all items above.

---

## 10) Appendix A — Evidence Map (JSON Template)

```json
{
  "topic": "Comprehensive graph algorithms for graph databases",
  "as_of_date": "2025-09-21",
  "claims": [
    {
      "id": "C-PageRank-Leiden",
      "statement": "Leiden improves on Louvain by guaranteeing well-connected communities and often runs faster.",
      "status": "corroborated",
      "confidence": "High",
      "evidence": [
        {
          "source_id": "S-Leiden2019",
          "support": "supports",
          "quote": "Leiden ... uncovers better partitions ... and provides explicit guarantees.",
          "page_or_section": "Abstract"
        }
      ],
      "notes": "Generalizes to weighted and directed variants."
    }
  ],
  "sources": [
    {
      "id": "S-Leiden2019",
      "title": "From Louvain to Leiden: guaranteeing well-connected communities",
      "type": "peer-reviewed",
      "publisher_or_journal": "Scientific Reports",
      "year": 2019,
      "doi_or_url": "https://doi.org/10.1038/s41598-019-41695-z",
      "accessed": "2025-09-21",
      "tier": "A"
    }
  ]
}
```

---

### 11) Appendix B — Minimal Test Datasets & Checks

- **Karate Club:** PageRank top‑k stable; Louvain ≈ 2 communities; Brandes BC top node = #34/#1 (depending on variant).
- **Small road network:** Dijkstra matches BFS when weights=1.
- **Synthetic bipartite:** Hopcroft–Karp returns maximum matching equal to min vertex cover size (Kőnig’s theorem).

---

### Final notes

- Algorithms and API names can vary across DB versions; always pin the versioned doc page and note parameters used.
- Some DBs (e.g., Arango Pregel, RedisGraph legacy) implement algorithms via **linear algebra/GraphBLAS**—be mindful of numeric stability and dangling‑mass handling for PageRank. ([Engineering People][57])

If you want, I can turn this prompt into a **filled catalog** for the specific DB you use (Neo4j, TigerGraph, etc.) with all cards completed and runnable queries end‑to‑end.

[1]: https://neo4j.com/docs/graph-data-science/current/algorithms/page-rank/?utm_source=chatgpt.com 'PageRank - Neo4j Graph Data Science'
[2]: https://tinkerpop.apache.org/docs/3.4.2/reference/?utm_source=chatgpt.com 'The Gremlin Console'
[3]: https://docs.tigergraph.com/graph-ml/3.10/using-an-algorithm/packaged-template-algorithms?utm_source=chatgpt.com 'Packaged Template Algorithms :: Graph Data Science Library'
[4]: https://docs.arangodb.com/3.10/data-science/pregel/algorithms/?utm_source=chatgpt.com 'Pregel Algorithms'
[5]: https://memgraph.com/docs/advanced-algorithms/run-algorithms?utm_source=chatgpt.com 'Run algorithms'
[6]: https://link.springer.com/article/10.1007/BF01386390?utm_source=chatgpt.com 'A note on two problems in connexion with graphs'
[7]: https://epubs.siam.org/doi/10.1137/0201010?utm_source=chatgpt.com 'Depth-First Search and Linear Graph Algorithms'
[8]: https://www.scirp.org/reference/referencespapers?referenceid=1449476&utm_source=chatgpt.com 'Kruskal, J.B. (1956) On the Shortest Spanning Subtree of a ...'
[9]: https://jamieheller.github.io/resources.html?utm_source=chatgpt.com 'Network Flow Theory using Edmonds-Karp Algorithm - GitHub Pages'
[10]: https://snap.stanford.edu/class/cs224w-readings/brandes01centrality.pdf?utm_source=chatgpt.com 'A Faster Algorithm for Betweenness Centrality'
[11]: https://arxiv.org/abs/0803.0476?utm_source=chatgpt.com 'Fast unfolding of communities in large networks'
[12]: https://www.e-periodica.ch/digbib/view?pid=bsv-002%3A1901%3A37%3A%3A579&utm_source=chatgpt.com 'Étude comparative de la distribution florale dans une ...'
[13]: https://epubs.siam.org/doi/10.1137/0202019?utm_source=chatgpt.com 'An $n^{5/2} $ Algorithm for Maximum Matchings in Bipartite ...'
[14]: https://link.springer.com/chapter/10.1007/11427186_54?utm_source=chatgpt.com 'Finding, Counting and Listing All Triangles in Large ...'
[15]: https://dl.acm.org/doi/10.1145/2623330.2623732?utm_source=chatgpt.com 'DeepWalk: online learning of social representations'
[16]: https://dl.acm.org/doi/10.1145/321921.321925?utm_source=chatgpt.com 'An Algorithm for Subgraph Isomorphism | Journal of the ACM'
[17]: https://dl.acm.org/doi/10.1145/321850.321852?utm_source=chatgpt.com 'Efficient Planarity Testing | Journal of the ACM'
[18]: https://neo4j.com/docs/graph-data-science/current/algorithms/dijkstra-source-target/?utm_source=chatgpt.com 'Dijkstra Source-Target Shortest Path'
[19]: https://stackoverflow.com/questions/66368394/gremlin-shortestpath-with-step?utm_source=chatgpt.com 'shortest path - gremlin shortestPath() with step'
[20]: https://docs.arangodb.com/3.11/develop/http-api/pregel/?utm_source=chatgpt.com 'Pregel HTTP API | ArangoDB Documentation'
[21]: https://infolab.stanford.edu/pub/papers/google.pdf?utm_source=chatgpt.com 'The Anatomy of a Large-Scale Hypertextual Web Search Engine'
[22]: https://neo4j.com/docs/graph-data-science/current/operations-reference/algorithm-references/?utm_source=chatgpt.com 'Graph Algorithms - Neo4j Graph Data Science'
[23]: https://neo4j.com/docs/graph-data-science/current/algorithms/louvain/?utm_source=chatgpt.com 'Louvain - Neo4j Graph Data Science'
[24]: https://www.nature.com/articles/s41598-019-41695-z?utm_source=chatgpt.com 'From Louvain to Leiden: guaranteeing well-connected communities'
[25]: https://docs.tigergraph.com/graph-ml/3.10/community-algorithms/louvain?utm_source=chatgpt.com 'Louvain :: Graph Data Science Library'
[26]: https://docs.arangodb.com/3.10/data-science/pregel/?utm_source=chatgpt.com 'Distributed Iterative Graph Processing (Pregel)'
[27]: https://neo4j.com/docs/graph-data-science/current/algorithms/strongly-connected-components/?utm_source=chatgpt.com 'Strongly Connected Components'
[28]: https://dl.acm.org/doi/10.1145/321879.321884?utm_source=chatgpt.com 'Efficiency of a Good But Not Linear Set Union Algorithm'
[29]: https://en.wikipedia.org/wiki/Maximum_flow_problem?utm_source=chatgpt.com 'Maximum flow problem'
[30]: https://link.aps.org/doi/10.1103/PhysRevE.76.036106?utm_source=chatgpt.com 'Near linear time algorithm to detect community structures in ...'
[31]: https://neo4j.com/docs/graph-data-science/current/algorithms/triangle-count/?utm_source=chatgpt.com 'Triangle Count - Neo4j Graph Data Science'
[32]: https://graphblas.org/?utm_source=chatgpt.com 'The GraphBLAS | Welcome to the GraphBLAS Forum'
[33]: https://tinkerpop.apache.org/javadocs/current/core/org/apache/tinkerpop/gremlin/process/computer/ranking/pagerank/PageRankVertexProgram.html?utm_source=chatgpt.com 'Class PageRankVertexProgram'
[34]: https://docs.nebula-graph.io/3.0.2/nebula-algorithm/?utm_source=chatgpt.com 'Nebula Algorithm'
[35]: https://www.semanticscholar.org/paper/Algorithm-97%3A-Shortest-path-Floyd/bab268857baf555ea6d2c1f638857e28b4fd5aa5?utm_source=chatgpt.com 'Algorithm 97: Shortest path'
[36]: https://www.semanticscholar.org/paper/A-Theorem-on-Boolean-Matrices-Warshall/6145f0b0df53ec2581d733f003d251e0cabef04a?utm_source=chatgpt.com 'A Theorem on Boolean Matrices | Semantic Scholar'
[37]: https://www.scirp.org/reference/referencespapers?referenceid=3009475&utm_source=chatgpt.com 'Johnson, D.B. (1977) Efficient Algorithms for Shortest Paths ...'
[38]: https://www.semanticscholar.org/paper/Topological-sorting-of-large-networks-Kahn/7724172425879e96bd4deee1c175ba840ebac5a6?utm_source=chatgpt.com 'Topological sorting of large networks'
[39]: https://onlinelibrary.wiley.com/doi/abs/10.1002/j.1538-7305.1957.tb01515.x?utm_source=chatgpt.com 'Shortest Connection Networks And Some Generalizations'
[40]: https://link.springer.com/chapter/10.1007/978-3-642-02158-9_19?utm_source=chatgpt.com 'Two-Level Push-Relabel Algorithm for the Maximum Flow ...'
[41]: https://dl.acm.org/doi/pdf/10.1145/263867.263872?utm_source=chatgpt.com 'A simple min-cut algorithm'
[42]: https://epubs.siam.org/doi/pdf/10.1137/0109047?utm_source=chatgpt.com 'Multi-Terminal Network Flows'
[43]: https://www.scirp.org/reference/referencespapers?referenceid=2251231&utm_source=chatgpt.com 'Bonacich, P. (1987) Power and Centrality A Family of ...'
[44]: https://dl.acm.org/doi/10.1145/324133.324140?utm_source=chatgpt.com 'Authoritative sources in a hyperlinked environment'
[45]: https://www.pnas.org/doi/10.1073/pnas.122653799?utm_source=chatgpt.com 'Community structure in social and biological networks'
[46]: https://www.sciencedirect.com/science/article/pii/S0378873303000091?utm_source=chatgpt.com 'Friends and neighbors on the Web'
[47]: https://link.springer.com/article/10.1140/epjb/e2009-00335-8?utm_source=chatgpt.com 'Predicting missing links via local information'
[48]: https://link.springer.com/article/10.1007/BF02289026?utm_source=chatgpt.com 'A new status index derived from sociometric analysis'
[49]: https://web.eecs.umich.edu/~pettie/matching/Kuhn-hungarian-assignment.pdf?utm_source=chatgpt.com 'The Hungarian method for the assignment problem'
[50]: https://dl.acm.org/doi/10.1007/11427186_54?utm_source=chatgpt.com 'Finding, counting and listing all triangles in large graphs, an ...'
[51]: https://www.nature.com/articles/30918?utm_source=chatgpt.com "Collective dynamics of 'small-world' networks"
[52]: https://dl.acm.org/doi/10.1145/2939672.2939754?utm_source=chatgpt.com 'node2vec: Scalable Feature Learning for Networks'
[53]: https://pubmed.ncbi.nlm.nih.gov/15641723/?utm_source=chatgpt.com 'A (sub)graph isomorphism algorithm for matching large ...'
[54]: https://www.sciencedirect.com/science/article/pii/S0166218X18300829?utm_source=chatgpt.com 'VF2++—An improved subgraph isomorphism algorithm'
[55]: https://tinkerpop.apache.org/docs/current/reference/?utm_source=chatgpt.com 'TinkerPop Documentation'
[56]: https://docs.tigergraph.com/graph-ml/3.10/centrality-algorithms/pagerank?utm_source=chatgpt.com 'PageRank :: Graph Data Science Library'
[57]: https://people.engr.tamu.edu/davis/GraphBLAS_files/08778293.pdf?utm_source=chatgpt.com 'RedisGraph GraphBLAS Enabled Graph Database'
