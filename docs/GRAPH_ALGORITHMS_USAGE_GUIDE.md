# Graph Algorithms Usage Guide

## Real GQL Queries and Data Examples

## Table of Contents

1. [Social Network Example](#social-network-example)
2. [Algorithm Usage Examples](#algorithm-usage-examples)
3. [Real-World Use Cases](#real-world-use-cases)
4. [Performance Tips](#performance-tips)

---

## Social Network Example

### Data Setup

Let's create a simple social network to demonstrate all algorithms:

```gql
-- Create people nodes
CREATE (alice:Person {name: 'Alice', age: 30})
CREATE (bob:Person {name: 'Bob', age: 25})
CREATE (charlie:Person {name: 'Charlie', age: 35})
CREATE (diana:Person {name: 'Diana', age: 28})
CREATE (eve:Person {name: 'Eve', age: 32})
CREATE (frank:Person {name: 'Frank', age: 27})
CREATE (grace:Person {name: 'Grace', age: 29})
CREATE (henry:Person {name: 'Henry', age: 31})

-- Create friendship relationships
MATCH (alice:Person {name: 'Alice'}), (bob:Person {name: 'Bob'})
CREATE (alice)-[:FRIENDS_WITH {since: 2020}]->(bob)

MATCH (alice:Person {name: 'Alice'}), (charlie:Person {name: 'Charlie'})
CREATE (alice)-[:FRIENDS_WITH {since: 2019}]->(charlie)

MATCH (bob:Person {name: 'Bob'}), (diana:Person {name: 'Diana'})
CREATE (bob)-[:FRIENDS_WITH {since: 2021}]->(diana)

MATCH (charlie:Person {name: 'Charlie'}), (diana:Person {name: 'Diana'})
CREATE (charlie)-[:FRIENDS_WITH {since: 2020}]->(diana)

MATCH (diana:Person {name: 'Diana'}), (eve:Person {name: 'Eve'})
CREATE (diana)-[:FRIENDS_WITH {since: 2022}]->(eve)

MATCH (eve:Person {name: 'Eve'}), (frank:Person {name: 'Frank'})
CREATE (eve)-[:FRIENDS_WITH {since: 2021}]->(frank)

MATCH (frank:Person {name: 'Frank'}), (grace:Person {name: 'Grace'})
CREATE (frank)-[:FRIENDS_WITH {since: 2020}]->(grace)

MATCH (grace:Person {name: 'Grace'}), (henry:Person {name: 'Henry'})
CREATE (grace)-[:FRIENDS_WITH {since: 2019}]->(henry)

MATCH (alice:Person {name: 'Alice'}), (diana:Person {name: 'Diana'})
CREATE (alice)-[:FRIENDS_WITH {since: 2021}]->(diana)
```

**Network Structure:**

```
Alice --- Bob
  |  \     |
  |   Diana --- Eve --- Frank --- Grace --- Henry
  |   /
Charlie
```

> **Verified outputs.** Every "Expected Results" table below is verified
> against the real `CALL algo.*` executors by
> `tests/test_gap0883_algo_procedures.zig` (`zig build test-gap0883`) over this
> exact fixture. Two things to know when reading them:
>
> 1. **Node ids are store-assigned 64-bit ids**, not small sequential
>    integers — the tables below therefore show the person's *name*; join
>    `nodeId` back to nodes with `MATCH (p:Person) WHERE id(p) = nodeId` to
>    reproduce them.
> 2. **Relationships are directed.** Algorithms that traverse both directions
>    (degree, betweenness, closeness, eigenvector, louvain, labelPropagation,
>    unionFind) see this network as drawn; `algo.scc.stream` follows outgoing
>    edges only (see §8).

---

## Algorithm Usage Examples

### 1. Degree Centrality

**Question**: Who has the most friends?

```gql
CALL algo.degree.stream()
YIELD nodeId, degree
RETURN nodeId, degree
ORDER BY degree DESC
LIMIT 5
```

**Expected Results** (verified; columns are `nodeId, degree` — names shown for readability):

```
┌─────────┬────────┐
│ person  │ degree │
├─────────┼────────┤
│ Diana   │ 4      │  -- connected to Alice, Bob, Charlie, Eve
│ Alice   │ 3      │  -- connected to Bob, Charlie, Diana
│ Bob     │ 2      │  -- connected to Alice, Diana
│ Charlie │ 2      │  -- connected to Alice, Diana
│ Eve     │ 2      │  -- connected to Diana, Frank
└─────────┴────────┘
(remaining: Frank 2, Grace 2, Henry 1)
```

**Interpretation**: Diana is the most connected person with 4 friends, making her a key hub in the network.

---

### 2. Betweenness Centrality

**Question**: Who acts as a bridge connecting different parts of the network?

```gql
CALL algo.betweenness.stream()
YIELD nodeId, betweenness
RETURN nodeId, betweenness
ORDER BY betweenness DESC
LIMIT 5
```

**Expected Results** (verified; the executor returns **raw, unnormalized Brandes
pair counts**, not [0,1]-normalized scores):

```
┌─────────┬─────────────┐
│ person  │ betweenness │
├─────────┼─────────────┤
│ Diana   │ 25          │  -- bridges Alice/Bob/Charlie to Eve/Frank/Grace/Henry
│ Eve     │ 24          │  -- bridges Diana's cluster to Frank/Grace/Henry
│ Frank   │ 20          │  -- bridges Eve to Grace/Henry
│ Grace   │ 12          │  -- bridges Frank to Henry
│ Alice   │ 1           │
└─────────┴─────────────┘
(Bob, Charlie, Henry: 0 — no shortest path passes through them)
```

**Interpretation**: Diana has the highest betweenness centrality because she lies on the shortest path between many node pairs. Removing Diana would fragment the network.

**Use Case**: In an organization, this identifies people who facilitate information flow between departments.

---

### 3. Closeness Centrality

**Question**: Who can reach everyone else most quickly?

```gql
CALL algo.closeness.stream()
YIELD nodeId, closeness
RETURN nodeId, closeness
ORDER BY closeness DESC
LIMIT 5
```

**Expected Results** (verified):

```
┌─────────┬───────────┐
│ person  │ closeness │
├─────────┼───────────┤
│ Diana   │ 0.538461  │  -- total distance to the other 7 people: 13
│ Eve     │ 0.538461  │  -- joint-highest: Eve is equally central on this chain
│ Frank   │ 0.466666  │
│ Alice   │ 0.411764  │
│ Bob     │ 0.388888  │  -- tied with Charlie
└─────────┴───────────┘
(remaining: Charlie 0.388888, Grace 0.368421, Henry 0.280000)
```

**Interpretation**: Diana and Eve tie for shortest average distance to everyone else; both are ideally positioned for information dissemination.

**Use Case**: In emergency response, this identifies locations for resource distribution centers.

---

### 4. Eigenvector Centrality

**Question**: Who is connected to other well-connected people?

```gql
CALL algo.eigenvector.stream()
YIELD nodeId, eigenvector
RETURN nodeId, eigenvector
ORDER BY eigenvector DESC
LIMIT 5
```

**Expected Results** (verified):

```
┌─────────┬─────────────┐
│ person  │ eigenvector │
├─────────┼─────────────┤
│ Diana   │ 0.579313    │  -- connected to the other three well-connected people
│ Alice   │ 0.510612    │
│ Bob     │ 0.402221    │  -- Bob and Charlie are structurally symmetric
│ Charlie │ 0.402221    │
│ Eve     │ 0.255037    │  -- scores decay down the Eve→Frank→Grace→Henry chain
└─────────┴─────────────┘
(remaining: Frank 0.111684, Grace 0.047739, Henry 0.017601)
```

**Interpretation**: Diana and Alice have high eigenvector centrality because they're connected to other influential nodes, not just many nodes.

**Use Case**: In marketing, this identifies influencers whose endorsements reach other influencers.

---

### 5. Louvain Community Detection

**Question**: What friend groups exist in the network?

```gql
CALL algo.louvain.stream()
YIELD nodeId, community
RETURN community, collect(nodeId) AS members, count(*) AS n
GROUP BY community
ORDER BY n DESC
```

**Expected Results** (verified — community ids are store-assigned node ids, so
the table shows membership; typical run):

```
┌───────────┬──────────────────────────────┬──────┐
│ community │ members                      │ n    │
├───────────┼──────────────────────────────┼──────┤
│ A         │ Alice, Bob, Charlie, Diana   │ 4    │  -- densely connected core
│ B         │ Eve, Frank                   │ 2    │  -- chain pair
│ C         │ Grace, Henry                 │ 2    │  -- chain pair
└───────────┴──────────────────────────────┴──────┘
```

**Interpretation**: The densely connected core (Alice, Bob, Charlie, Diana)
always forms one community. The Eve→Frank→Grace→Henry **chain** has no dense
sub-structure, so its grouping sits on near-tied modularity optima: the
typical outcome is the two pairs shown above, but the chain split can vary
between runs (2-3 communities total). What never happens — and what the
regression test pins — is the degenerate one-community-per-node output or the
chain tail merging into the core.

**Use Case**: In social media, this identifies communities for targeted content or ads.

---

### 6. Label Propagation

**Question**: How do communities form through peer influence?

```gql
CALL algo.labelPropagation.stream()
YIELD nodeId, label
RETURN label, collect(nodeId) AS members, count(*) AS n
GROUP BY label
ORDER BY n DESC
```

**Expected Results** (verified properties — the exact split is
**tie-break-order dependent** and varies between runs on a graph this small;
do not pin exact labels):

- Strictly fewer labels than nodes — propagation always merges somebody.
- Every node ends with the same label as at least one of its neighbors
  (local consistency at convergence).
- Observed outcomes on this fixture range from a single community to a few;
  on graphs with dense, well-separated clusters the partition is stable.

**Interpretation**: Through iterative label spreading, nodes adopt the most common label among their neighbors. This simulates how opinions or behaviors spread through social influence. Ties (equally common neighbor labels) are broken by iteration order, which is why small, chain-like graphs do not produce one canonical split.

**Use Case**: Modeling how trends, opinions, or diseases spread through a network.

---

### 7. Union-Find (Connected Components)

**Question**: Are there isolated groups in the network?

```gql
CALL algo.unionFind.stream()
YIELD nodeId, setId
RETURN setId, collect(nodeId) AS members, count(*) AS n
GROUP BY setId
ORDER BY n DESC
```

**Expected Results** (verified — `setId` is a store-assigned representative
node id, not a small integer):

```
┌───────────┬──────────────────────────────────────────────────────────┬──────┐
│ setId     │ members                                                  │ n    │
├───────────┼──────────────────────────────────────────────────────────┼──────┤
│ <setId>   │ Alice, Bob, Charlie, Diana, Eve, Frank, Grace, Henry     │ 8    │
└───────────┴──────────────────────────────────────────────────────────┴──────┘
```

**Interpretation**: Everyone is in one connected component - there are no isolated groups.

**With Isolation Example:**

```gql
-- Add isolated group
CREATE (:Person {name: 'Ian'})-[:FRIENDS_WITH]->(:Person {name: 'Jane'})

-- Now run Union-Find
CALL algo.unionFind.stream()
YIELD nodeId, setId
RETURN setId, collect(nodeId) AS members, count(*) AS n
GROUP BY setId
ORDER BY n DESC
```

**Results with Isolation** (verified — exactly two distinct `setId` values):

```
┌──────────┬──────────────────────────────────────────────────────────┬──────┐
│ setId    │ members                                                  │ n    │
├──────────┼──────────────────────────────────────────────────────────┼──────┤
│ <setId1> │ Alice, Bob, Charlie, Diana, Eve, Frank, Grace, Henry     │ 8    │
│ <setId2> │ Ian, Jane                                                │ 2    │
└──────────┴──────────────────────────────────────────────────────────┴──────┘
```

**Use Case**: Network diagnostics - finding disconnected parts of infrastructure or isolated user groups.

---

### 8. Strongly Connected Components

**Question**: In a directed network, which nodes can reach each other?

```gql
CALL algo.scc.stream()
YIELD nodeId, componentId
RETURN componentId, collect(nodeId) AS members, count(*) AS n
GROUP BY componentId
ORDER BY n DESC
```

**Expected Results** (verified — SCC is a **directed** algorithm and follows
outgoing edges only; it does NOT treat the graph as undirected):

```
┌─────────────┬──────────┬──────┐
│ componentId │ members  │ n    │
├─────────────┼──────────┼──────┤
│ 0..7        │ each     │ 1    │  -- 8 singleton SCCs
└─────────────┴──────────┴──────┘
```

The friendship fixture has no **directed cycle** (every `FRIENDS_WITH` edge
points one way), so every node is its own strongly connected component. To see
multi-node SCCs you need directed cycles — like the citation network below.

**Directed Graph Example:**

```gql
-- Create a directed citation network
CREATE (paper1:Paper {title: 'Foundation'})
CREATE (paper2:Paper {title: 'Building Blocks'})
CREATE (paper3:Paper {title: 'Advanced Topics'})
CREATE (paper4:Paper {title: 'Applications'})

MATCH (p1:Paper {title: 'Building Blocks'}), (p2:Paper {title: 'Foundation'})
CREATE (p1)-[:CITES]->(p2)

MATCH (p1:Paper {title: 'Advanced Topics'}), (p2:Paper {title: 'Building Blocks'})
CREATE (p1)-[:CITES]->(p2)

MATCH (p1:Paper {title: 'Applications'}), (p2:Paper {title: 'Advanced Topics'})
CREATE (p1)-[:CITES]->(p2)

-- Circular reference
MATCH (p1:Paper {title: 'Foundation'}), (p2:Paper {title: 'Applications'})
CREATE (p1)-[:CITES]->(p2)
```

The four `CITES` edges form a directed cycle (Foundation → Applications →
Advanced Topics → Building Blocks → Foundation), so `algo.scc.stream` reports
all four papers in **one** strongly connected component. (The directed-cycle
behavior is pinned by the two-directed-triangles test in
`tests/test_gap0883_algo_procedures.zig`.)

**Use Case**: In web page ranking, identifying sets of pages that all link to each other (link farms).

---

## Real-World Use Cases

### Corporate Network Analysis

**Scenario**: Analyzing employee collaboration network

```gql
-- Find key connectors in the organization
MATCH (e:Employee)
CALL algo.betweenness.stream()
YIELD nodeId, betweenness
FILTER id(e) = nodeId
RETURN e.name, e.department, betweenness
ORDER BY betweenness DESC
LIMIT 10
```

**Business Value**:

- Identify critical employees for knowledge transfer
- Find collaboration bottlenecks
- Plan redundancy for key positions

---

### Fraud Detection

**Scenario**: Finding connected accounts in transaction network

```gql
-- Find connected components in transaction network
MATCH (a:Account)
CALL algo.unionFind.stream()
YIELD nodeId, setId
FILTER id(a) = nodeId
RETURN setId, collect(a.accountNumber) AS accounts, count(*) AS accountCount
GROUP BY setId
HAVING count(*) > 5  -- Suspiciously large connected groups
ORDER BY accountCount DESC
```

**Business Value**:

- Detect fraud rings
- Identify money laundering networks
- Find coordinated fake account creation

---

### Recommendation Systems

**Scenario**: Friend recommendations using community detection

```gql
-- The people of each community; a query part runs one procedure call, so
-- pair the members who are not yet friends in the application (or join
-- the stored community ids of a previous run)
MATCH (p:Person)
CALL algo.louvain.stream()
YIELD nodeId, community
FILTER id(p) = nodeId
RETURN community, collect(p.name) AS members
GROUP BY community
```

**Business Value**:

- Suggest connections based on community membership
- Improve user engagement
- Network growth through relevant recommendations

---

### Supply Chain Analysis

**Scenario**: Finding critical suppliers using betweenness centrality

```gql
-- Identify critical nodes in supply chain
MATCH (s:Supplier)
CALL algo.betweenness.stream()
YIELD nodeId, betweenness
-- A high raw pair count indicates criticality (scores are unnormalized)
FILTER id(s) = nodeId AND betweenness > 100
RETURN s.name,
       s.location,
       betweenness,
       'CRITICAL - Find backup suppliers' AS risk_assessment
ORDER BY betweenness DESC
```

**Business Value**:

- Identify single points of failure
- Plan supply chain redundancy
- Risk mitigation strategies

---

### Content Viral Potential

**Scenario**: Predict content spread using eigenvector centrality

```gql
-- Find influencers (high eigenvector centrality) who shared content
MATCH (u:User)-[:SHARED]->(c:Content {id: 'viral-video-123'})
CALL algo.eigenvector.stream()
YIELD nodeId, eigenvector
FILTER id(u) = nodeId
RETURN sum(eigenvector) AS viralPotential,
       count(u) AS influencerCount,
       CASE
         WHEN sum(eigenvector) > 5.0 THEN 'HIGH - Likely to go viral'
         WHEN sum(eigenvector) > 2.0 THEN 'MEDIUM - Good engagement expected'
         ELSE 'LOW - Limited reach'
       END AS prediction
```

**Business Value**:

- Predict content virality
- Identify optimal influencers for campaigns
- Content strategy optimization

---

## Performance Tips

### 1. Use Appropriate Algorithms

**For Large Networks (>100K nodes)**:

- ❌ Avoid: Betweenness centrality (O(V*E) is expensive)
- ✅ Use: Degree centrality, Label Propagation

**For Small, Dense Networks**:

- ✅ Use: Any algorithm
- Best: Betweenness, Eigenvector for deep insights

### 2. Limit Result Sets

```gql
-- Bad: Process all nodes
CALL algo.betweenness.stream()
YIELD nodeId, betweenness
RETURN *

-- Good: Limit to top results
CALL algo.betweenness.stream()
YIELD nodeId, betweenness
RETURN nodeId, betweenness
ORDER BY betweenness DESC
LIMIT 100
```

### 3. Filter Before Algorithm

```gql
-- The procedures run over the whole graph (there is no subgraph argument
-- yet); join and filter their rows afterwards
MATCH (p:Person {active: true})
CALL algo.degree.stream()
YIELD nodeId, degree
FILTER id(p) = nodeId
RETURN p.name, degree
```

### 4. Batch Processing

```gql
-- Select a batch of nodes (the procedures still run over the whole graph)
MATCH (p:Person)
WITH p
ORDER BY p.createdDate DESC
LIMIT 10000
RETURN collect(id(p)) AS recentUsers
```

---

## Combining Algorithms

### Multi-Metric Influence Score

A query part runs one procedure call, so run one query per measure and
combine the scores in the application (or store each score as a property
and combine the properties in one query):

```gql
-- One measure per query, joined to the people it scores
MATCH (p:Person)
CALL algo.degree.stream()
YIELD nodeId, degree
FILTER id(p) = nodeId
RETURN p.name AS name, degree
ORDER BY degree DESC

-- After storing each score on the node (degree, betweenness, eigenvector)
MATCH (p:Person)
RETURN p.name AS name,
       p.degree * 0.3 + p.betweenness * 0.4 + p.eigenvector * 0.3 AS influenceScore
ORDER BY influenceScore DESC
LIMIT 10
```

---

## Error Handling

### Empty Graph

```gql
-- Check for nodes before running algorithms
MATCH (n)
WITH count(n) AS nodeCount
WHERE nodeCount > 0
CALL algo.betweenness.stream()
YIELD nodeId, betweenness
RETURN nodeId, betweenness
```

### Disconnected Components

```gql
-- First identify components, then analyze each
CALL algo.unionFind.stream()
YIELD nodeId, setId
RETURN setId, collect(nodeId) AS componentNodes
GROUP BY setId
HAVING count(*) >= 5  -- Only analyze substantial components
```

---

## Summary

All 8 implemented algorithms provide powerful graph analytics capabilities:

| Algorithm | Procedure | YIELD columns | Best For | Complexity |
|-----------|-----------|---------------|----------|------------|
| Degree | `algo.degree.stream` | `nodeId, degree` | Quick connectivity measure | O(V+E) |
| Betweenness | `algo.betweenness.stream` | `nodeId, betweenness` (raw, unnormalized) | Finding bridges | O(V*E) |
| Closeness | `algo.closeness.stream` | `nodeId, closeness` | Measuring reachability | O(V*(V+E)) |
| Eigenvector | `algo.eigenvector.stream` | `nodeId, eigenvector` | Influence through connections | O(k*(V+E)) |
| Louvain | `algo.louvain.stream` | `nodeId, community` | Community structure | O(k*(V+E)) |
| Label Propagation | `algo.labelPropagation.stream` | `nodeId, label` | Fast community detection | O(k*E) |
| Union-Find | `algo.unionFind.stream` | `nodeId, setId` | Connected components | O(E*α(V)) |
| SCC | `algo.scc.stream` | `nodeId, componentId` (directed) | Directed connectivity | O(V+E) |

All eight procedures are server-side `CALL` procedures dispatched through
`src/execution/algo_dispatch.zig`; the expected results in this guide are
verified end-to-end by `tests/test_gap0883_algo_procedures.zig`
(`zig build test-gap0883`).

**Choose based on**:

- Network size (performance)
- Directed vs undirected
- Insight needed (centrality vs community)
- Computational budget

---

*Document Created*: January 8, 2025 (Evening)
*Purpose*: Practical usage examples for all graph algorithm implementations
*Audience*: Developers, data analysts, and users of Geode graph database
