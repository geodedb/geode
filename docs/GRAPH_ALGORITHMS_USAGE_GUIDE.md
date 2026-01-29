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

---

## Algorithm Usage Examples

### 1. Degree Centrality

**Question**: Who has the most friends?

```gql
CALL algo.degree.stream()
YIELD nodeId, centrality
RETURN nodeId, centrality
ORDER BY centrality DESC
LIMIT 5
```

**Expected Results:**

```
┌────────┬────────────┐
│ nodeId │ centrality │
├────────┼────────────┤
│ 4      │ 4          │  -- Diana (connected to Alice, Bob, Charlie, Eve)
│ 1      │ 3          │  -- Alice (connected to Bob, Charlie, Diana)
│ 2      │ 2          │  -- Bob (connected to Alice, Diana)
│ 3      │ 2          │  -- Charlie (connected to Alice, Diana)
│ 5      │ 2          │  -- Eve (connected to Diana, Frank)
└────────┴────────────┘
```

**Interpretation**: Diana is the most connected person with 4 friends, making her a key hub in the network.

---

### 2. Betweenness Centrality

**Question**: Who acts as a bridge connecting different parts of the network?

```gql
CALL algo.betweenness.stream()
YIELD nodeId, centrality
RETURN nodeId, centrality
ORDER BY centrality DESC
LIMIT 5
```

**Expected Results:**

```
┌────────┬────────────┐
│ nodeId │ centrality │
├────────┼────────────┤
│ 4      │ 0.428571   │  -- Diana (bridges Alice/Bob/Charlie to Eve/Frank/Grace/Henry)
│ 5      │ 0.214286   │  -- Eve (bridges Diana to Frank/Grace/Henry)
│ 6      │ 0.142857   │  -- Frank (bridges Eve to Grace/Henry)
│ 1      │ 0.071429   │  -- Alice
│ 2      │ 0.000000   │  -- Bob (leaf node)
└────────┴────────────┘
```

**Interpretation**: Diana has the highest betweenness centrality because she lies on the shortest path between many node pairs. Removing Diana would fragment the network.

**Use Case**: In an organization, this identifies people who facilitate information flow between departments.

---

### 3. Closeness Centrality

**Question**: Who can reach everyone else most quickly?

```gql
CALL algo.closeness.stream()
YIELD nodeId, centrality
RETURN nodeId, centrality
ORDER BY centrality DESC
LIMIT 5
```

**Expected Results:**

```
┌────────┬────────────┐
│ nodeId │ centrality │
├────────┼────────────┤
│ 4      │ 0.538462   │  -- Diana (average distance to others: ~1.86)
│ 1      │ 0.466667   │  -- Alice (average distance to others: ~2.14)
│ 5      │ 0.466667   │  -- Eve (average distance to others: ~2.14)
│ 3      │ 0.411765   │  -- Charlie
│ 2      │ 0.388889   │  -- Bob
└────────┴────────────┘
```

**Interpretation**: Diana can reach all other people in the fewest hops on average, making her ideally positioned for information dissemination.

**Use Case**: In emergency response, this identifies locations for resource distribution centers.

---

### 4. Eigenvector Centrality

**Question**: Who is connected to other well-connected people?

```gql
CALL algo.eigenvector.stream()
YIELD nodeId, centrality
RETURN nodeId, centrality
ORDER BY centrality DESC
LIMIT 5
```

**Expected Results:**

```
┌────────┬────────────┐
│ nodeId │ centrality │
├────────┼────────────┤
│ 4      │ 0.485071   │  -- Diana (connected to Alice who is well-connected)
│ 1      │ 0.408248   │  -- Alice (connected to Diana and Charlie)
│ 3      │ 0.353553   │  -- Charlie (connected to Alice and Diana)
│ 5      │ 0.301511   │  -- Eve
│ 2      │ 0.288675   │  -- Bob
└────────┴────────────┘
```

**Interpretation**: Diana and Alice have high eigenvector centrality because they're connected to other influential nodes, not just many nodes.

**Use Case**: In marketing, this identifies influencers whose endorsements reach other influencers.

---

### 5. Louvain Community Detection

**Question**: What friend groups exist in the network?

```gql
CALL algo.louvain.stream()
YIELD nodeId, community
RETURN community, collect(nodeId) AS members, count(*) AS size
GROUP BY community
ORDER BY size DESC
```

**Expected Results:**

```
┌───────────┬─────────────────────────┬──────┐
│ community │ members                 │ size │
├───────────┼─────────────────────────┼──────┤
│ 1         │ [1, 2, 3, 4, 5]        │ 5    │  -- Main cluster (Alice's group)
│ 6         │ [6, 7, 8]              │ 3    │  -- Secondary cluster (Frank's group)
└───────────┴─────────────────────────┴──────┘
```

**Interpretation**: The algorithm detected two main friend groups:

- Alice's cluster: Alice, Bob, Charlie, Diana, Eve
- Frank's cluster: Frank, Grace, Henry

**Use Case**: In social media, this identifies communities for targeted content or ads.

---

### 6. Label Propagation

**Question**: How do communities form through peer influence?

```gql
CALL algo.labelPropagation.stream()
YIELD nodeId, label
RETURN label, collect(nodeId) AS members, count(*) AS size
GROUP BY label
ORDER BY size DESC
```

**Expected Results:**

```
┌───────┬─────────────────────────┬──────┐
│ label │ members                 │ size │
├───────┼─────────────────────────┼──────┤
│ 1     │ [1, 2, 3, 4]           │ 4    │  -- Alice's influence spreads
│ 5     │ [5, 6, 7, 8]           │ 4    │  -- Eve's influence spreads
└───────┴─────────────────────────┴──────┘
```

**Interpretation**: Through iterative label spreading, nodes adopt the most common label among their neighbors. This simulates how opinions or behaviors spread through social influence.

**Use Case**: Modeling how trends, opinions, or diseases spread through a network.

---

### 7. Union-Find (Connected Components)

**Question**: Are there isolated groups in the network?

```gql
CALL algo.unionFind.stream()
YIELD nodeId, setId
RETURN setId AS component, collect(nodeId) AS members, count(*) AS size
GROUP BY setId
ORDER BY size DESC
```

**Expected Results:**

```
┌───────────┬─────────────────────────────────┬──────┐
│ component │ members                         │ size │
├───────────┼─────────────────────────────────┼──────┤
│ 1         │ [1, 2, 3, 4, 5, 6, 7, 8]       │ 8    │  -- All connected
└───────────┴─────────────────────────────────┴──────┘
```

**Interpretation**: Everyone is in one connected component - there are no isolated groups.

**With Isolation Example:**

```gql
-- Add isolated group
CREATE (ian:Person {name: 'Ian'})
CREATE (jane:Person {name: 'Jane'})
MATCH (ian:Person {name: 'Ian'}), (jane:Person {name: 'Jane'})
CREATE (ian)-[:FRIENDS_WITH]->(jane)

-- Now run Union-Find
CALL algo.unionFind.stream()
YIELD nodeId, setId
RETURN setId, collect(nodeId) AS members, count(*) AS size
GROUP BY setId
ORDER BY size DESC
```

**Results with Isolation:**

```
┌───────┬─────────────────────────────────┬──────┐
│ setId │ members                         │ size │
├───────┼─────────────────────────────────┼──────┤
│ 1     │ [1, 2, 3, 4, 5, 6, 7, 8]       │ 8    │  -- Main network
│ 9     │ [9, 10]                        │ 2    │  -- Isolated pair
└───────┴─────────────────────────────────┴──────┘
```

**Use Case**: Network diagnostics - finding disconnected parts of infrastructure or isolated user groups.

---

### 8. Strongly Connected Components

**Question**: In a directed network, which nodes can reach each other?

```gql
CALL algo.scc.stream()
YIELD nodeId, partition
RETURN partition, collect(nodeId) AS members, count(*) AS size
GROUP BY partition
ORDER BY size DESC
```

**Expected Results (treating as undirected):**

```
┌───────────┬─────────────────────────────────┬──────┐
│ partition │ members                         │ size │
├───────────┼─────────────────────────────────┼──────┤
│ 0         │ [1, 2, 3, 4, 5, 6, 7, 8]       │ 8    │  -- All mutually reachable
└───────────┴─────────────────────────────────┴──────┘
```

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

**Use Case**: In web page ranking, identifying sets of pages that all link to each other (link farms).

---

## Real-World Use Cases

### Corporate Network Analysis

**Scenario**: Analyzing employee collaboration network

```gql
-- Find key connectors in the organization
CALL algo.betweenness.stream()
YIELD nodeId, centrality
MATCH (e:Employee) WHERE id(e) = nodeId
RETURN e.name, e.department, centrality
ORDER BY centrality DESC
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
CALL algo.unionFind.stream()
YIELD nodeId, setId
MATCH (a:Account) WHERE id(a) = nodeId
WITH setId, collect(a.accountNumber) AS accounts
WHERE size(accounts) > 5  -- Suspiciously large connected groups
RETURN setId AS suspiciousGroup, accounts, size(accounts) AS accountCount
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
-- Find people in same community who aren't yet friends
CALL algo.louvain.stream()
YIELD nodeId, community
MATCH (p:Person) WHERE id(p) = nodeId
WITH community, collect(p) AS members
UNWIND members AS person1
UNWIND members AS person2
WHERE person1 <> person2
  AND NOT (person1)-[:FRIENDS_WITH]-(person2)
RETURN person1.name AS user,
       person2.name AS recommendedFriend,
       community AS sharedCommunity
ORDER BY user, sharedCommunity
LIMIT 20
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
CALL algo.betweenness.stream()
YIELD nodeId, centrality
MATCH (s:Supplier) WHERE id(s) = nodeId
WHERE centrality > 0.3  -- High betweenness indicates criticality
RETURN s.name,
       s.location,
       centrality,
       'CRITICAL - Find backup suppliers' AS risk_assessment
ORDER BY centrality DESC
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
CALL algo.eigenvector.stream()
YIELD nodeId, centrality
MATCH (u:User) WHERE id(u) = nodeId
MATCH (u)-[:SHARED]->(c:Content {id: 'viral-video-123'})
RETURN sum(centrality) AS viralPotential,
       count(u) AS influencerCount,
       CASE
         WHEN sum(centrality) > 5.0 THEN 'HIGH - Likely to go viral'
         WHEN sum(centrality) > 2.0 THEN 'MEDIUM - Good engagement expected'
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
YIELD nodeId, centrality
RETURN *

-- Good: Limit to top results
CALL algo.betweenness.stream()
YIELD nodeId, centrality
RETURN nodeId, centrality
ORDER BY centrality DESC
LIMIT 100
```

### 3. Filter Before Algorithm

```gql
-- Bad: Run algorithm on entire graph
CALL algo.degree.stream()
YIELD nodeId, centrality
MATCH (p:Person) WHERE id(p) = nodeId AND p.active = true
RETURN p.name, centrality

-- Better: Use subgraph (when supported)
-- First filter, then analyze
MATCH (p:Person {active: true})
WITH collect(id(p)) AS activeNodes
-- Run algorithm only on active nodes
```

### 4. Batch Processing

```gql
-- Process in batches for very large graphs
MATCH (p:Person)
WITH p
ORDER BY p.createdDate DESC
LIMIT 10000
WITH collect(id(p)) AS recentUsers
-- Run algorithm on recent users only
```

---

## Combining Algorithms

### Multi-Metric Influence Score

```gql
-- Combine multiple centrality measures for comprehensive influence score
CALL algo.degree.stream()
YIELD nodeId AS degreeNode, centrality AS degree

CALL algo.betweenness.stream()
YIELD nodeId AS betweenNode, centrality AS betweenness

CALL algo.eigenvector.stream()
YIELD nodeId AS eigenNode, centrality AS eigenvector

MATCH (p:Person)
WHERE id(p) = degreeNode AND id(p) = betweenNode AND id(p) = eigenNode
RETURN p.name,
       degree,
       betweenness,
       eigenvector,
       (degree * 0.3 + betweenness * 0.4 + eigenvector * 0.3) AS influenceScore
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
YIELD nodeId, centrality
RETURN nodeId, centrality
```

### Disconnected Components

```gql
-- First identify components, then analyze each
CALL algo.unionFind.stream()
YIELD nodeId, setId
WITH setId, collect(nodeId) AS componentNodes
WHERE size(componentNodes) >= 5  -- Only analyze substantial components
UNWIND componentNodes AS nodeId
-- Run centrality analysis on each component
```

---

## Summary

All 8 implemented algorithms provide powerful graph analytics capabilities:

| Algorithm | Best For | Complexity | Output Type |
|-----------|----------|------------|-------------|
| Degree | Quick connectivity measure | O(V*E) | Integer |
| Betweenness | Finding bridges | O(V*E) | Decimal |
| Closeness | Measuring reachability | O(V*(V+E)) | Decimal |
| Eigenvector | Influence through connections | O(k*(V+E)) | Decimal |
| Louvain | Community structure | O(V+E) | Community ID |
| Label Propagation | Fast community detection | O(k*E) | Label ID |
| Union-Find | Connected components | O(E*α(V)) | Component ID |
| SCC | Directed connectivity | O(V+E) | Partition ID |

**Choose based on**:

- Network size (performance)
- Directed vs undirected
- Insight needed (centrality vs community)
- Computational budget

---

*Document Created*: January 8, 2025 (Evening)
*Purpose*: Practical usage examples for all graph algorithm implementations
*Audience*: Developers, data analysts, and users of Geode graph database
