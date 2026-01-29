Comprehensive Graph Algorithms Catalog

This catalog covers key graph algorithms across various categories: traversal, shortest paths, connectivity, spanning structures, flows/cuts, centrality measures, community detection, similarity/link prediction, matching, triangles/clustering, embeddings, and isomorphism. Each algorithm entry outlines its purpose, input/output, complexity, pseudocode, implementation notes, and references to primary sources. The focus is on pseudocode and algorithmic behavior, with notes on typical usage in graph analytics. All complexities are given for a graph with $n=|V|$ vertices and $m=|E|$ edges, assuming adjacency-list representations unless noted. Directed/undirected and weighted/unweighted applicability are stated per algorithm. In practice, these algorithms can be run in graph databases by projecting the graph into memory and using built-in procedures or custom implementations. (Note: Many graph databases use linear algebra frameworks like GraphBLAS for performance, but here we emphasize pseudocode logic.)

Breadth-First Search (BFS)

Family: Traversal (Unweighted Shortest Paths)
Problem: Finds all nodes reachable from a source node $s$ in an unweighted graph, computing the minimum-hop distance to each. Input: Graph $G=(V,E)$ (directed or undirected, unweighted), start node $s$. Output: Distances $dist[v]$ (minimum number of edges from $s$ to $v$) and optionally tree of parent pointers (breadth-first tree). BFS requires the graph to be in memory or streamed; it explores neighbors layer by layer.
Complexity: $O(n + m)$ time and $O(n)$ memory. This linear complexity holds for both directed and undirected graphs.
Pseudocode:

```text

BFS(G=(V,E), s):
  for each v in V:
      dist[v] := ∞
      parent[v] := NIL
  dist[s] := 0
  Q := empty queue
  enqueue(Q, s)
  while Q not empty:
      u := dequeue(Q)
      for each neighbor v of u in E:   // for each edge (u,v)
          if dist[v] = ∞:            // not visited
              dist[v] := dist[u] + 1
              parent[v] := u
              enqueue(Q, v)
  return dist, parent

```

Implementation Notes: BFS operates in layers: first all nodes at distance 1 from the source, then distance 2, etc. It finds shortest paths in unweighted graphs (each tree edge from $s$ is the shortest path to that node in terms of hops). For undirected graphs, BFS from any node in a connected component will eventually visit the entire component. For directed graphs, BFS respects edge direction (it only visits nodes reachable via directed paths from $s$). If the graph is very large, one must ensure it’s projected or streamed efficiently (e.g. using an index on neighbors). BFS can be extended to multi-source BFS by initializing the queue with multiple start nodes (useful for finding distances from a set of sources simultaneously).
Use in Graph Databases: Many graph databases provide built-in BFS via a shortest path procedure on unweighted graphs. For example, Neo4j Graph Data Science (GDS) uses a single-source shortest path with unit weights to achieve BFS results. Apache TinkerPop Gremlin can do BFS by repeated .out() traversals or using its shortestPath() step on a graph computer.
Primary Sources: BFS was first described by E. F. Moore (1959) and independently by C. Y. Lee for maze routing; it’s a fundamental graph search algorithm. Its linear time complexity is well-known. Tarjan (1972) discusses BFS as a counterpart to depth-first search for linear graph algorithms.
Known Variants: Bidirectional BFS (simultaneously from source and target, meeting in middle, to find shortest path faster), Multi-source BFS, and Level-synchronous traversal (for parallel BFS). BFS is also the basis for algorithms like topological sort and connected components in unweighted graphs.

Depth-First Search (DFS)

Family: Traversal (Graph Search)
Problem: Explores a graph by diving as deep as possible along each branch before backtracking. Input: Graph $G=(V,E)$ (directed or undirected), optional start node (if none given, DFS will iterate over all components). Output: Discovery and finish times for each node; a depth-first forest (set of parent pointers forming DFS trees); and it can classify edges (tree, back, forward, cross edges in directed graphs). DFS is often used as a subroutine for other algorithms (finding cycles, topological sort, connected components, etc.).
Complexity: $O(n + m)$ time with adjacency list. Uses $O(n)$ recursion stack or explicit stack.
Pseudocode (recursive):

```text

DFS(G):
  for each v in V:
      state[v] := UNVISITED
      parent[v] := NIL
  time := 0
  for each v in V:
      if state[v] = UNVISITED:
          DFS-Visit(v)

DFS-Visit(u):
  state[u] := VISITING
  discovery[u] := time := time + 1
  for each neighbor w of u:
      if state[w] = UNVISITED:
          parent[w] := u
          DFS-Visit(w)
  state[u] := VISITED
  finish[u] := time := time + 1

```

Implementation Notes: The above marks timestamps for each node’s discovery and finish. In practice, recursive DFS may cause deep call stacks on very large graphs; an explicit stack can be used to avoid recursion. DFS can work on directed or undirected graphs (on undirected graphs, back edges indicate cycles; on directed, back edges indicate cycles and other edge types can be identified). Many algorithms are built atop DFS: e.g. finding Strongly Connected Components (Tarjan’s algorithm uses a DFS-based approach with a stack), biconnected components, and topological sorting (which can collect nodes in decreasing finish time order).
Use in Graph Databases: Depth-first traversal can be implemented with recursive queries or via procedures. Some graph libraries allow DFS as an option for traversals (though BFS is more common for shortest path). In Gremlin, a .repeat() step with a depth limit can simulate DFS or BFS depending on termination conditions.
Primary Sources: Tarjan’s seminal paper on DFS (1972) highlighted DFS’s power in solving linear graph problems. It introduced the stack method for SCC and other applications.
Known Variants: Iterative Deepening DFS (IDDFS) which performs DFS to increasing depth limits (useful when depth is unknown but solution likely shallow); Backtracking search is a form of DFS used in constraint solving; Random DFS (randomly ordering neighbors) can explore graphs in random spanning trees. The core DFS algorithm remains uniform, with modifications for specific tasks.

Dijkstra’s Algorithm (Single-Source Shortest Paths)

Family: Pathfinding (Weighted, nonnegative)
Problem: Computes the shortest path distances from a single source node $s$ to all other nodes in a graph with nonnegative edge weights. Input: Directed or undirected graph $G=(V,E)$ with weight function $w(u,v) \ge 0$ for each edge; source node $s$. Output: Distance $dist[v]$ for each vertex $v$ (minimum total weight from $s$ to $v$), and predecessor pointers that form a shortest path tree.
Complexity: $O((n + m)\log n)$ time with a binary heap implementation. Using a Fibonacci heap, $O(m + n\log n)$ is possible, though in practice binary heaps are often as good. Space is $O(n + m)$. If all edge weights are equal (e.g. 1), Dijkstra effectively does BFS in $O(n+m)$.
Pseudocode:

```text

Dijkstra(G, s):
  for each v in V:
      dist[v] := ∞
      parent[v] := NIL
  dist[s] := 0
  H := min-priority queue
  H.insert(s, key=0)
  while H is not empty:
      u := H.extract_min()          // node with smallest dist
      for each neighbor v of u:
          alt := dist[u] + w(u,v)
          if alt < dist[v]:
              dist[v] := alt
              parent[v] := u
              if v is in H:
                  H.decrease_key(v, alt)
              else:
                  H.insert(v, key=alt)
  return dist, parent

```

Implementation Notes: Dijkstra’s algorithm greedily “relaxes” edges. Once a node $u$ is extracted from the priority queue (settled), its distance is final. Directed vs Undirected: Works for both; on undirected graphs, each undirected edge can be treated as two directed edges. Graph requirements: Edge weights must be non-negative (if negative edges exist, use Bellman–Ford algorithm instead). Typical performance: For dense graphs ($m \approx n^2$), Dijkstra is $O(n^2)$ with simple array implementation. For sparse graphs, using a heap yields $O(m \log n)$. Many real networks are sparse (m ~ O(n)), so roughly $O(n \log n)$.
Graph DB Usage: Graph databases like Neo4j GDS have gds.shortestPath.dijkstra procedure, which requires projecting the graph and specifying a relationshipWeightProperty. In Apache TinkerPop, one can use the ShortestPath DSL or Gremlin's algorithm library. TigerGraph and others provide built-in shortest path queries (often BFS for unweighted, Dijkstra for weighted).
Primary Sources: Dijkstra’s original paper (1959) introduced the algorithm. It’s a classic example of a greedy algorithm. The complexity with modern data structures is detailed in standard texts like CLRS.
Known Variants: Bidirectional Dijkstra (runs two Dijkstras from source and target meeting in middle, roughly halving search space; effective for single-pair queries). Goal-directed Dijkstra (with heuristics, e.g. A search, see below). Multi-source Dijkstra (initialize multiple sources with distance 0). Johnson’s algorithm* (for all-pairs shortest paths on sparse graphs, uses Dijkstra repeatedly after reweighting, see below).

Bellman–Ford Algorithm (Single-Source Shortest Paths with Negative Weights)

Family: Pathfinding (Weighted, can handle negatives)
Problem: Finds shortest paths from a source $s$ in directed graphs that may have negative edge weights (but no negative-weight cycles reachable from $s$). Also detects negative cycles. Input: Directed graph $G=(V,E)$ with weight function $w(u,v)$ (can be negative), source node $s$. Output: Distance estimates $dist[v]$ for each node, and predecessors, or report that a negative cycle exists.
Complexity: $O(n \cdot m)$ time in the worst case. Uses $O(n)$ space for distances. This is slower than Dijkstra for large graphs, but it handles negative weights.
Pseudocode:

```text

BellmanFord(G, s):
  for each v in V:
      dist[v] := ∞
      parent[v] := NIL
  dist[s] := 0
  // Relax all edges (u,v) repeatedly
  for i from 1 to n-1:
      for each edge (u,v) in E:
          if dist[u] + w(u,v) < dist[v]:
              dist[v] := dist[u] + w(u,v)
              parent[v] := u
  // Optional: detect negative cycle
  for each edge (u,v) in E:
      if dist[u] + w(u,v) < dist[v]:
          return "Negative cycle detected"
  return dist, parent

```

Implementation Notes: Bellman–Ford relaxes all edges $n-1$ times (in a graph with no negative cycle, the longest possible shortest path uses $n-1$ edges). It can handle negative weights unlike Dijkstra. If a shorter path is found in the $n$-th iteration, a negative cycle is present. In practice, optimizations like early break (if an iteration does no update) can improve average performance. Graph requirements: Edges can have negative weights but not negative cycles reachable from $s$ (if a negative cycle is reachable, shortest path distances are not well-defined, which Bellman-Ford detects).
Use Cases: Often used in distance-vector routing protocols (e.g., Bellman-Ford is the basis of RIP). In graph databases, if negative weights are needed (less common in typical property graphs), one might implement Bellman-Ford via iterative Cypher queries or custom procedures; most built-in shortest path algorithms assume nonnegative weights.
Primary Sources: The algorithm is named after Richard Bellman and Lester Ford Jr., who published it in 1958. Also known as the Bellman-Ford–Moore algorithm (Moore also discovered it in 1959). It’s classic dynamic programming on graphs.
Known Variants: Shortest Path Faster Algorithm (SPFA) – an optimized Bellman-Ford using a queue to process only vertices whose distances get updated, often faster on average but same worst-case. Johnson’s algorithm uses Bellman-Ford once as a subroutine to reweight edges for all-pairs shortest paths.

Floyd–Warshall Algorithm (All-Pairs Shortest Paths)

Family: Pathfinding (Weighted, All-Pairs)
Problem: Computes shortest path distances between every pair of vertices. Input: Directed graph $G=(V,E)$ with weight $w(u,v)$ for each edge (if no direct edge, treat as $+\infty$). Can handle negative weights (no negative cycles). Output: A distance matrix $D[\,]$ where $D[i][j]$ is the minimum weight from $i$ to $j$ for all $i,j \in V$. Also can produce a predecessor matrix for paths.
Complexity: $O(n^3)$ time and $O(n^2)$ space. This cubic complexity becomes expensive if $n$ is large (e.g., for $n=10^4$, $10^{12}$ operations is infeasible). However, on dense graphs or for moderate $n$, Floyd–Warshall can be efficient and simpler than running $n$ single-source searches.
Pseudocode (distance matrix initialization and triple loop):

let D be an n×n matrix initialized with D[i][j] :=
    0          if i=j
    w(i,j)     if (i,j) in E
    ∞          otherwise
for k from 1 to n:
    for i from 1 to n:
        for j from 1 to n:
            if D[i][k] + D[k][j] < D[i][j]:
                D[i][j] := D[i][k] + D[k][j]
return D

Implementation Notes: The algorithm works by iterative improvement, allowing paths that go through a set of intermediate vertices. After the $k$-th outer loop iteration, all shortest paths that use only vertices ${1,\dots,k}$ as intermediates are correctly computed. Directed vs Undirected: Works for both; for undirected, the input matrix is symmetric and remains symmetric through computation. Negative weights: Allowed, as the relaxation in the inner loop will handle them; if a negative cycle exists, one can detect it by seeing $D[i][i] < 0$ at end. Practical considerations: Uses heavy memory for large $n$. If graph is sparse, repeated Dijkstra (Johnson’s algorithm) or other methods may be faster. On dense graphs, $O(n^3)$ can outperform $O(n^2 \log n)$ (Johnson) when $n$ is not too large. Modern improvements (like APSP with fast matrix multiplication) exist theoretically but are not practical for typical $n$.
Use in Graph DB: Few graph databases implement Floyd–Warshall due to its $O(n^3)$ cost. Instead, they rely on iterative breadth-first searches or specialized index-based methods for distance queries. However, Floyd–Warshall is conceptually simple and can be implemented with stored procedures for smaller graphs.
Primary Sources: Robert Floyd (1962) published this as “Algorithm 97”; independently Stephen Warshall (1962) gave a similar algorithm for Boolean reachability (which extends to weighted version). It is a classic dynamic programming approach.
Known Variants: Johnson’s Algorithm (1977) – better for sparse graphs, complexity $O(n^2 \log n + n \cdot m)$ using Dijkstra for each source after reweighting edges with Bellman-Ford. Repeated Dijkstra: $n$ times Dijkstra gives $O(n m \log n)$, which is often $O(n^2 \log n)$ for sparse cases (Johnson’s uses that idea with optimization for negative weights). Also, APSP via Matrix Multiplication: uses methods like Seidel’s algorithm or others with $O(n^{2.373})$ theoretically, but not used in practice for typical graph sizes.

A* Search Algorithm (Heuristic Shortest Path)

Family: Pathfinding (Single-Pair, guided by heuristic)
Problem: Finds the shortest path from a source node $s$ to a target node $t$ faster by using a heuristic function to guide the search. Input: Graph $G=(V,E)$ with nonnegative weights, start $s$, goal $t$, and a heuristic function $h(v)$ that estimates the distance from any node $v$ to the goal $t$. Output: The shortest path from $s$ to $t$ (or its distance). A expands nodes in an order determined by $f(v) = g(v) + h(v)$ where $g(v)$ is the distance from $s$ to $v$ found so far.
Complexity: In the worst case, A can be as bad as $O(m \log n)$ (similar to Dijkstra) or worse, especially if the heuristic is poor (e.g. zero heuristic reduces to Dijkstra). With an admissible heuristic ($h(v) \le \text{dist}(v,t)$ for all $v$) that is also consistent, A is guaranteed to find the optimal path and generally expands far fewer nodes than Dijkstra, especially if the heuristic is close to the true distance. In practice, complexity is highly data-dependent.
Pseudocode:

```text

A*(G, s, t, h):
  for v in V:
      dist[v] := ∞
      parent[v] := NIL
  dist[s] := 0
  openSet := min-heap ordered by f(v) = dist[v] + h(v)
  openSet.insert(s, f=s.h())
  closedSet := ∅
  while openSet not empty:
      u := openSet.extract_min()         // node with lowest f
      if u = t:
          break    // found optimal path to target
      closedSet.add(u)
      for each neighbor v of u:
          tentative_g := dist[u] + w(u,v)
          if v in closedSet and tentative_g >= dist[v]:
              continue
          if tentative_g < dist[v]:
              dist[v] := tentative_g
              parent[v] := u
              f[v] := dist[v] + h(v)
              if v not in openSet:
                  openSet.insert(v, f[v])
              else:
                  openSet.update_key(v, f[v])
  return dist[t], path (reconstruct via parent pointers)

```

Implementation Notes: The heuristic $h(v)$ is crucial. It must be admissible (never overestimates true distance to $t$) to guarantee A finds an optimal path. A will then only expand nodes that are potentially on an optimal route. If $h$ is also consistent (monotonic), the first time the goal is extracted from the open set is the optimal solution, and no revisiting of closed nodes is needed. Common heuristics are Euclidean or Manhattan distance in spatial graphs, or other domain-specific estimates. With a perfect heuristic equal to actual distance, A examines only the path nodes (optimal scenario). With $h=0$, A becomes Dijkstra’s algorithm. Memory is a factor: A stores all open nodes in a priority queue (can grow large in dense graphs).
Use Cases: A is widely used in pathfinding for maps (e.g., road networks, game AI). In graph databases, one might implement A for geometric networks or when a target is known and we want the path faster than exploring the whole graph. Some graph frameworks have A procedures (Neo4j has a gds.alpha.shortestPath.astar for example).
Primary Sources: Introduced by Hart, Nilsson, and Raphael in 1968 as an extension of Dijkstra’s algorithm with heuristics. It has become the de facto algorithm for shortest path in AI applications.
Known Variants:  IDA (Iterative Deepening A) uses DFS with increasing cost limits to reduce memory. Bidirectional A: run A from both start and goal meeting in the middle (requires consistent heuristics on both ends, tricky but can speed up). Weighted A (WA*): allows a heuristic weight $w > 1$ to trade optimality for speed (finds suboptimal but faster). These are useful when exact optimality can be relaxed.

Connected Components (Weakly Connected Components)

Family: Connectivity
Problem: Identify all connected components in an undirected graph (or weakly connected components in a directed graph, ignoring edge direction). A connected component is a set of nodes where each is reachable from any other via some path. Input: Graph $G=(V,E)$ (undirected; or treat directed as undirected for weak connectivity). Output: Component labels for each node (e.g., an array component[v] assigning a component ID).
Complexity: $O(n + m)$ time. A simple traversal (BFS/DFS) from each unvisited node suffices. Using union-find (disjoint set union) by iterating over edges is another $O((n+m)\alpha(n)) \approx O(n+m)$ approach.
Pseudocode (DFS-based):

component := array of length n
comp_id := 0
for each v in V:
    if component[v] not set:
        comp_id := comp_id + 1
        // start a new component search
        DFS_mark(v, comp_id)

DFS_mark(u, comp_id):
    component[u] := comp_id
    for each neighbor w of u:
        if component[w] is NIL:
            DFS_mark(w, comp_id)

(Use BFS instead of DFS if desired – both traverse the component in linear time.)
Implementation Notes: For undirected graphs, this finds actual connected components. For directed graphs, this procedure finds weakly connected components (ignoring direction). If one needs strongly connected components, use Tarjan’s or Kosaraju’s algorithm (see below). The union-find approach: initially each node is its own set, then for each edge (u,v) do union(u,v); finally sets represent components. Union-find can quickly merge components especially if edges are given as an unsorted list. In memory, a BFS/DFS approach might be simpler if graph adjacency lists are available.
Graph DB Usage: Many graph analytics libraries have a Connected Components algorithm. For example, Neo4j GDS has gds.wcc for weakly connected components (undirected connectivity) and gds.unionFind in older versions【22†】. These run linear time on projected in-memory graphs.
Primary Sources: This is a basic application of DFS/BFS (dating back to early graph theory algorithms). Union-find (disjoint set) data structure was developed by Galler and Fischer (1964) and further by Tarjan (1975)【28†】, and it provides an efficient alternative method.
Known Variants: Strongly Connected Components (for directed graphs, see Tarjan’s algorithm below). Biconnected components (uses DFS to find articulation points). Connected Components in dynamic graphs (algorithms exist for when edges are added/removed over time). The static problem, however, is straightforward as above.

Strongly Connected Components (Tarjan’s Algorithm)

Family: Connectivity
Problem: Find all strongly connected components (SCCs) in a directed graph. An SCC is a maximal set of nodes where each node is reachable from every other node in the same set (a strongly connected subgraph). Input: Directed graph $G=(V,E)$. Output: A partition of the vertices into SCCs (often each component can be represented by a representative or an ID).
Complexity: $O(n + m)$ time and $O(n)$ space using Tarjan’s DFS-based algorithm. Another algorithm by Kosaraju (1978) also achieves $O(n+m)$ by two passes of DFS (first pass to compute finishing times, second on the transpose graph).
Pseudocode (Tarjan’s algorithm using single DFS):

global index := 0
global S := empty stack
initialize arrays: compIndex[v] = -1, lowlink[v], onStack[v] = false for all v

function strongconnect(v):
    compIndex[v] = index
    lowlink[v] = index
    index = index + 1
    S.push(v); onStack[v] = true

    for each w in neighbors of v:      // consider v → w
        if compIndex[w] = -1:
            // w not visited
            strongconnect(w)
            lowlink[v] = min(lowlink[v], lowlink[w])
        else if onStack[w]:
            // w is in current stack (back edge)
            lowlink[v] = min(lowlink[v], compIndex[w])
    // If v is root of SCC
    if lowlink[v] = compIndex[v]:
        print "SCC found:"
        repeat
            w = S.pop(); onStack[w] = false
            print w  (or assign SCC id)
        until w = v

// Main loop
for each v in V:
    if compIndex[v] = -1:
        strongconnect(v)

Implementation Notes: Tarjan’s algorithm performs a single DFS, keeping track of each node’s discovery order (compIndex) and the lowest reachable discovery index (lowlink) via any back edge. When a node $v$ has lowlink[v] == compIndex[v], $v$ is the root of an SCC; all nodes above $v$ on the stack form that SCC. The use of a stack ensures each node is output in exactly one SCC. Directed graphs only: For undirected graphs, “strong connectivity” is just connectivity. Tarjan’s algorithm is space-efficient (in-place on recursion stack). Kosaraju’s algorithm, by contrast, does two DFS passes: first to compute a finishing time order, then on the graph with edges reversed, process nodes in decreasing finish time to collect SCCs. Kosaraju is simpler conceptually but uses two passes (still linear time).
Graph DB Usage: Graph analytics libraries provide SCC. For instance, Neo4j GDS gds.stronglyConnectedComponents implements either Tarjan or Kosaraju under the hood【27†】. TigerGraph has an SCC algorithm as well. These typically require the graph to be directed; if the graph is very large, distributed solutions exist (but SCC is challenging to distribute due to its global nature).
Primary Source: Tarjan’s 1972 paper introduced this DFS-based SCC algorithm, proving linear time and space. Kosaraju’s method was earlier (Kosaraju-Sharir algorithm) but Tarjan’s is more commonly used due to single-pass efficiency.
Known Variants: Kosaraju–Sharir algorithm (two-pass DFS). Path-based SCC algorithm (similar to Tarjan’s, uses two stacks). Iterative SCC algorithms for large-scale systems (e.g. graph processing frameworks often implement variations to avoid deep recursion). For incrementally maintaining SCCs in dynamic graphs, more complex data structures are needed (beyond scope here).

Topological Sort (Kahn’s Algorithm)

Family: Ordering (Directed Acyclic Graphs)
Problem: Given a directed acyclic graph (DAG), produce a linear ordering of all its vertices such that for every directed edge $(u \to v)$, $u$ comes before $v$ in the order. This is known as a topological order. Input: Directed acyclic graph $G=(V,E)$. Output: An ordering (list) of vertices $L = [v_1, v_2, ..., v_n]$ respecting the partial order defined by edges. If the graph has a cycle, no topological sort exists.
Complexity: $O(n + m)$ time. Kahn’s algorithm uses in-degree counts and a queue【38†】. DFS-based approach (using recursion and stack for order) is also $O(n+m)$.
Pseudocode (Kahn’s algorithm):

in_deg := array of indegrees for each v in V
Q := queue()
for each v in V:
    if in_deg[v] = 0:
        enqueue(Q, v)
L := []   // result list
while Q not empty:
    u := dequeue(Q)
    append u to list L
    for each neighbor w of u:   // for each edge u -> w
        in_deg[w] := in_deg[w] - 1
        if in_deg[w] = 0:
            enqueue(Q, w)
if length(L) < n:
    print "Graph has a cycle (not a DAG)"
else:
    return L

Implementation Notes: Kahn’s algorithm repeatedly removes nodes with no incoming edges and appends them to the order. It uses a queue (or priority queue for lexicographically smallest order, if needed). The DFS-based approach: perform DFS, and whenever a node finishes (all descendants processed), push it onto a stack; then pop stack for order (essentially reverse of finish times). Both yield a valid topo sort if DAG. Graph requirements: Graph must be acyclic directed. If there’s a cycle, the algorithm will detect it (Kahn’s will end early with some nodes still having indegree > 0; DFS will detect a back edge).
Use Cases: Topological ordering is used in scheduling problems, build systems (compiling with dependencies), resolving package dependencies, etc. Graph databases might use topological sort implicitly when scheduling execution order of tasks with dependencies. One can implement this via repeated selection of vertices with no incoming edges (which might be done with repeated queries or an algorithm procedure).
Primary Sources: Kahn (1962) introduced the queue-based algorithm【38†】. The DFS method is described in many textbooks (and was known in early graph theory folklore). Both achieve linear complexity.
Known Variants: Lexicographically smallest topological sort: use a priority queue to always pick the smallest-numbered (or lexicographically smallest) vertex with indegree 0. All topological sorts: there are algorithms to enumerate all possible topological orders (exponential in worst case). For DAG longest path (which is NP-hard in general graphs), topological order allows a simple DP in DAGs.

Minimum Spanning Tree – Kruskal’s Algorithm

Family: Spanning Tree / Forest
Problem: Given an undirected, weighted graph, find a spanning tree of minimum total weight. A spanning tree connects all vertices with $n-1$ edges (assuming the graph is connected; otherwise, a spanning forest for each component). Input: Undirected graph $G=(V,E)$ with weight $w(e)$ on each edge. Output: Set of edges $T \subseteq E$ forming a spanning tree of minimum total weight $w(T) = \sum_{e \in T} w(e)$.
Complexity: $O(m \log m)$ time from sorting edges, or $O(m \log n)$ with union-find optimizations【28†】. The union-find operations (find/union) are almost constant amortized time (${O}(\alpha(n))$ per operation, where $\alpha$ is the inverse Ackermann function). Space $O(n)$ for union-find structure.
Pseudocode:

```text

Kruskal(G):
  T := ∅
  sort E by increasing weight
  make-set(v) for each v in V        // initialize union-find
  for each edge e = (u,v) in E (in sorted order):
      if find(u) ≠ find(v):         // if u and v are in different components
          T := T ∪ {e}
          union(u, v)
      // if find(u)=find(v), edge would form a cycle -> skip
  return T

```

Implementation Notes: Kruskal’s algorithm adds edges in increasing weight order, skipping those that would create a cycle (checked via union-find). It works on undirected graphs. If the graph isn’t connected, the result will be a minimum spanning forest covering all components. Sorting edges is the slowest step. Union-Find details: Use union by rank and path compression for efficiency【28†】. Memory: sorting can be done in place; union-find uses arrays of size $n$. Directed graphs: MST is usually defined for undirected graphs (for directed, one could find minimum spanning arborescences with Edmonds’ algorithm, a different problem).
Use in Graph DB: Many graph systems provide an MST algorithm (though it’s less common in property graph analytics since those focus more on paths and centralities). One can implement Kruskal by retrieving all edges, sorting them (which may require pulling data out of DB). Neo4j GDS did not have MST as of older versions (one might write a custom procedure). TigerGraph GSQL could implement this via global accumulators to pick edges.
Primary Sources: Joseph Kruskal (1956) published this greedy algorithm【8†】. It’s proven that choosing the smallest edge that doesn’t cause a cycle yields an MST (cut property).
Known Variants: Prim’s algorithm (see below) grows the MST from a starting node, adding the cheapest edge from the tree to a new vertex at each step (better for dense graphs, $O(m + n \log n)$ with heap). Borůvka’s algorithm (1926) adds cheapest edge incident to each component in parallel rounds (good for parallel implementations). All three algorithms yield the same result. Kruskal is often easiest for implementation if edges can be easily sorted.

Minimum Spanning Tree – Prim’s Algorithm

Family: Spanning Tree / Forest
Problem: Same as above – find a minimum spanning tree in an undirected weighted graph. Approach: Prim’s algorithm builds the tree incrementally from an arbitrary start vertex.
Complexity: $O(m \log n)$ with a priority queue (each edge can cause an insert/decrease-key). In dense graphs ($m \approx n^2$), a simple array implementation yields $O(n^2)$ which can be fine for moderate $n$.
Pseudocode:

```text

Prim(G):
  let r be an arbitrary start vertex
  for v in V:
      dist[v] := ∞
      parent[v] := NIL
  dist[r] := 0
  H := min-heap keyed by dist[]
  H.insert(r, 0)
  while H not empty:
      u := H.extract_min()
      for each neighbor v of u:
          if v is in H and w(u,v) < dist[v]:
              parent[v] := u
              dist[v] := w(u,v)
              H.decrease_key(v, w(u,v))
  return {parent pointers or edges forming the tree}

```

Implementation Notes: Prim’s algorithm is essentially Dijkstra’s algorithm but using edge weights instead of distance (and no source-target concept – it grows until all vertices are included). It maintains a set of vertices in the tree and always picks the smallest edge crossing from the tree to a new vertex. Starting vertex: The choice doesn’t affect total weight (the MST is unique if all weights distinct, otherwise there can be multiple MSTs). Data structure: A min-heap of vertices by the minimum edge weight connecting them to the tree. This algorithm is well-suited when we want the actual tree structure as we go. If edges are extremely numerous (dense graph), an $O(n^2)$ approach (like a boolean array for included vertices and scanning adjacency lists for min edges) might be simpler and not too slow for smaller graphs.
Use in Graph DB: Similar to Kruskal, not typically a built-in in property graph libraries, but one could implement by starting from a node and expanding. Graph libraries that expose a priority queue or have a Pregel iterative approach could implement Prim’s. For example, ArangoDB’s Pregel has an MST algorithm in some versions.
Primary Sources: Prim’s algorithm was discovered by Vojtěch Jarník (1930) and rediscovered by Robert C. Prim (1957) and Dijkstra (also in 1959)【39†】【7†】. It’s sometimes called DJP or Jarník-Prim algorithm.
Known Variants: Fibonacci Heap version runs in $O(m + n \log n)$. Borůvka’s algorithm (as noted) can be combined with Prim in parallel implementations (Borůvka’s rounds reduce the number of components quickly, then Prim’s for final touches). In practice, for very large graphs in distributed systems, Borůvka’s parallel nature is advantageous.

Maximum Flow – Edmonds–Karp Algorithm

Family: Flow and Cut
Problem: Given a directed graph with a source $s$, sink $t$, and a capacity $c(u,v)$ on each edge, find the maximum flow from $s$ to $t$. The flow problem asks: how much flow (like fluid or traffic) can we send from $s$ to $t$ without exceeding capacities on edges? Edmonds–Karp is an implementation of the Ford-Fulkerson method using BFS to find augmenting paths. Input: Directed graph $G=(V,E)$ with capacities $c(u,v) \ge 0$, source $s$, sink $t$. Output: A flow value $F$ (maximum possible from $s$ to $t$) and the flow on each edge (or at least the value $F$).
Complexity: $O(n \cdot m^2)$ in worst case (each augmenting path found by BFS runs in $O(m)$ and it can find $O(n \cdot m)$ augmentations in worst-case networks). In practice, typically better than this pessimistic bound for reasonable networks.
Pseudocode (Ford-Fulkerson with BFS):

```text

initialize flow f(e) = 0 for all edges
while there exists a path P from s to t in the residual graph:
    // (use BFS in residual net to get shortest path in terms of hops)
    find bottleneck = min{ c(u,v) - f(u,v) | (u,v) in P }
    for each edge (u,v) in P:
        f(u,v) := f(u,v) + bottleneck
        f(v,u) := f(v,u) - bottleneck   // update residual reverse flow
// after no augmenting path, f is max flow

```

Implementation Notes: The residual graph initially equals the original capacities. Each augmentation uses BFS to guarantee the shortest path (in hops) is chosen (Edmonds–Karp strategy), which ensures a bound of $O(n \cdot m^2)$. Result: The max flow value equals the capacity of a min $s$-$t$ cut (Max-Flow Min-Cut Theorem). Memory: Need to maintain residual capacities for each edge (including backward edges for flow). Typical performance: Edmonds–Karp is easy to implement but can be slow if capacities are such that many small augmentations occur.
Use in Graph DB: Flow algorithms are not commonly built into graph databases oriented toward analytics, but one could implement via iterative breadth-first searches and updates. Some specialized graph computing systems or network flow libraries can be integrated if needed.
Primary Sources: Ford-Fulkerson (1956) introduced augmenting path idea; Edmonds-Karp (1972) added using BFS for a clear polynomial bound. This was one of the first polynomial-time max flow algorithms.
Known Variants: Dinic’s algorithm (see below) improves performance by using blocking flows on level graphs, significantly faster on many networks (worst-case $O(n^2 m)$, but often much better). Push–Relabel (Goldberg–Tarjan, 1988) uses a different approach (preflows) and achieves $O(n^3)$ worst-case, often very fast in practice for large graphs. There are also specialized algorithms for unit capacities, bipartite matching (which is a flow problem), etc.

Maximum Flow – Dinic’s Algorithm (Dinitz’ Algorithm)

Family: Flow and Cut
Problem: Same max flow problem (find maximum $s$–$t$ flow). Approach: Dinic’s algorithm uses BFS to build a level graph and then sends blocking flows with DFS, in iterative phases. This reduces redundant work by pushing flow through multiple augmenting paths in one phase.
Complexity: $O(n^2 \cdot m)$ in the general case. For unit capacities or unit networks, runs in $O(\min(n^{2/3}, m^{1/2}) \, m)$ which is much faster. In practice Dinic’s often outperforms Edmonds–Karp significantly.
Pseudocode (high-level):

```text

function DinicMaxFlow(G, s, t):
    flow := 0
    while BFS finds a level graph from s to t:
        // level graph has level distances dist(v) = length of shortest path from s
        // create ptr[u] to track next neighbor to explore for DFS (optimization)
        flow += sendBlockingFlow(s, t)
    return flow

function sendBlockingFlow(u, t):
    if u = t: return ∞  (or a very large number to indicate t reached)
    for v in neighbors of u starting from ptr[u]:
        if dist[v] = dist[u] + 1 and capacity(u,v) > 0:
            minFlow := sendBlockingFlow(v, t)
            if minFlow > 0:
                // push flow
                f := min(minFlow, capacity(u,v))
                update flow f on (u,v) and (v,u) in residual
                return f
    return 0

```

(The above is a simplified sketch: actual implementation sends multiple blocking flows until no augmenting path remains in the level graph.)
Implementation Notes: Dinic’s algorithm consists of repeating two steps: 1) BFS from $s$ to $t$ to construct a level graph (which layers the graph by distance from $s$). If $t$ is unreachable, max flow is achieved. 2) Using DFS (or iterative) to find blocking flows in the level graph (augmented until all paths from $s$ to $t$ in the level graph are saturated or dead ends). This combination reduces the number of BFS phases typically. The algorithm ensures that each edge is “critical” for at most $O(n)$ flow pushes across all phases, yielding $O(n m)$ average, and worst $O(n^2 m)$ in degenerate cases. Memory: Similar to Edmonds-Karp, storing residuals and level arrays.
Use Cases: Dinic’s algorithm is commonly used in network flow libraries due to its good performance on moderate to large graphs. It’s efficient for bipartite matching problems, circulation problems, etc.
Primary Sources: Dinic (or Dinitz) published it in 1970. Later, Shimon Even and colleagues popularized it. It’s a standard in algorithm texts.
Known Variants: Dinic with blocking flow via DFS (above), or using scaling (some implementations scale flow values). Push–Relabel (mentioned earlier) often outperforms Dinic in very large graphs. Scaling max-flow algorithms use binary scaling of capacities to achieve $O(m^2 \log U)$ for maximum capacity $U$. For specific cases like bipartite matching, Hopcroft–Karp (see matching section) is specialized but essentially a flow algorithm on a unit network.

Global Minimum Cut (Stoer–Wagner Algorithm)

Family: Flow and Cut
Problem: Find a minimum cut of an undirected weighted graph. A cut is a partition of vertices into two sets, and its weight is the sum of weights of edges crossing the partition. The global minimum cut is the cut with smallest total weight (not necessarily involving a specific source or sink). Input: Undirected graph $G=(V,E)$ with weights (if unweighted, treat each edge weight=1). Output: A set $S \subset V$ such that the weight of edges between $S$ and $V\setminus S$ is minimal among all possible cuts; and the cut weight value.
Complexity: $O(n^3)$ time naive, improved to $O(n^2 \log n + n m)$ with priority queue optimizations. Stoer-Wagner’s original algorithm (1995) runs in essentially $O(n \cdot (m + n)) = O(nm + n^2)$ which is good for dense graphs and okay for moderate sparse graphs.
Approach: Stoer-Wagner uses repeated minimum cut phase operations: in each phase, it picks an arbitrary start vertex and then repeatedly “grows” a set $A$ by adding the most tightly connected vertex not in $A$ (in terms of weights from that vertex to $A$). This is similar to Prim’s MST, but using weights as “edge connectivity” measure. The last vertex added in a phase, together with the rest of $A$ (minus that vertex), forms a cut. It keeps track of the minimum cut found. Then merges the last two vertices into one (contracting that edge) and repeats with one fewer vertex. After $n-1$ phases, the minimum cut found is the global minimum cut.
Pseudocode (simplified phase):

min_cut_weight := ∞
set V' := V
while |V'| > 1:
    choose an arbitrary v0 in V'
    A := {v0}
    weights := array of size |V'| initialized to 0
    for i from 1 to |V'|:
        // "maximum weighted spanning tree" growth
        for each w in V' \ A:
            weights[w] += weight of edge between last_added and w (if any)
        let next := vertex in V' \ A with max weights[next]
        add next to A
        if i < |V'|: last_added := next
        else:
            // last added in this phase, compute cut
            S := A \ {next}
            if weight(S, V'\S) < min_cut_weight:
                min_cut_weight := weight(S, V'\S)
                best_cut := (S, V'\S)
            contract next and last_added in V'
            // merge vertices and continue outer loop

Implementation Notes: This algorithm is somewhat complex to implement but effective. The inner loop chooses the most tightly connected vertex (next)—if using a max-heap, this is $O(|V'|\log|V'|)$ per addition, making one phase $O(n \log n + m)$, and the overall algorithm $O(n^2 \log n + nm)$ for all phases. It contracts vertices (i.e., merges them) to reduce the problem size each iteration. In the end, the best cut recorded is the global min cut. Memory: Needs to maintain weight sums and the graph under contraction (can be done implicitly or by updating weights array).
Use Cases: Finding a minimum cut has applications in network reliability, clustering (though often one looks for balanced cuts in clustering rather than global min cut which can be trivial like a single edge). Gomory-Hu tree (see below) uses repeated min-cuts to derive cuts between all pairs.
Primary Sources: Stoer and Wagner (1997, J. ACM) described this algorithm【41†】. It improved on simpler $O(n^3)$ cut algorithms.
Known Variants: Karger’s randomized contraction algorithm (1993) finds a global min cut by randomly contracting edges until two vertices remain; by repeating the process a number of times ($\sim O(n^2 \log n)$ iterations) one gets the min cut with high probability. Karger’s algorithm is $O(n^2 m)$ for one iteration and with repetitions roughly $O(n^2 m \log n)$, which is usually worse than Stoer-Wagner for deterministic needs, but it introduced randomization in cuts. Gomory-Hu tree (next) uses $n-1$ max-flow or min-cut computations to summarize all pair cuts.

Gomory–Hu Tree (Cut Tree)

Family: Flow and Cut
Problem: Compute a tree representing all-pairs minimum cuts in an undirected weighted graph. A Gomory-Hu tree is a weighted tree on the same set of vertices such that for any two vertices $u$ and $v$, the minimum cut separating $u$ and $v$ in the graph is achieved by removing the edge of minimum weight on the unique path between $u$ and $v$ in the tree【42†】. Input: Undirected weighted graph $G=(V,E)$. Output: A weighted tree $T$ with vertex set $V$ and $n-1$ weighted edges capturing min-cut info.
Complexity: Using $n-1$ max-flow computations (e.g., $n-1$ times running Dinic or Edmonds-Karp between selected pairs) gives total complexity roughly $O(n \cdot \text{MaxFlow}(n,m))$. With efficient flow (e.g. push-relabel), this can be $O(n^4)$ worst-case. There are more efficient implementations for special cases, but generally constructing Gomory-Hu is computationally heavy for large graphs.
Method Outline: Gomory-Hu algorithm picks an arbitrary vertex, runs a max flow/min cut between it and another vertex to find a cut, then separates the graph by that cut, recurses on components, and links the tree with the cut edge. Specifically, one implementation:
1. Start with all vertices in one component.
2. Pick a vertex $u$, for each other vertex $v$ not yet separated from $u$, run max-flow between $u$ and $v$ to get a minimum cut value and cut $(S, V\setminus S)$.
3. Separate the vertex sets according to that cut, record the cut value as an edge weight between the two resulting components in the Gomory-Hu tree.
4. Recurse or iterate until all vertices separated. Actually, Gomory-Hu’s original algorithm uses a union-find structure to merge and then split based on cuts, performing $n-1$ flows.
Implementation Notes: The resulting tree has useful properties: For any $s,t$, the min cut between $s,t$ in $G$ is exactly the minimum edge on path between $s,t$ in the GH-tree. It’s a compact representation of many cut values. However, it requires many max-flow computations, so it’s not typically used in interactive graph DB queries, more in off-line analysis. Some improvements use the results of one flow to reduce work for others.
Primary Sources: Gomory and Hu (1961) introduced this concept【42†】. It’s an elegant theoretical tool.
Known Variants: In practice, one might not explicitly construct GH-tree for large graphs but instead query needed cut values via flow algorithms directly. Variants of min-cut problems include sto-connectivity and multi-terminal cuts (NP-hard beyond two terminals). GH-tree deals with all pairs of terminals in polynomial time by leveraging cut structure.

Degree Centrality

Family: Centrality (Node Importance)
Definition: Degree centrality of a node is simply its degree: the number of connections (edges) it has. In directed graphs, one can consider in-degree and out-degree separately (or sum for total degree). Problem Statement: Identify the most connected vertices by count of edges. Input: Graph $G=(V,E)$ (directed or undirected, unweighted or weighted). Output: A score $C_D(v) = \deg(v)$ for each vertex $v$. If weighted, sometimes the weighted degree (strength) is used: sum of weights of incident edges.
Complexity: $O(n + m)$ time to compute for all nodes by scanning adjacency lists once. This is trivial and very fast.
Interpretation: In many networks (like social networks), degree centrality can indicate influence or popularity (a high-degree node is connected to many others). However, it’s a local measure and doesn’t consider global structure.
Graph DB Usage: Degree is often directly accessible as a property (size((v)--()) in Cypher for undirected degree, etc.). Neo4j GDS has a degree centrality procedure as well (simply counts neighbors). For large graphs, counting edges per node is straightforward with MapReduce or similar.
Primary Sources: Freeman (1979) formalized various centrality measures including degree centrality. It’s essentially the oldest and simplest centrality concept.
Variants: In-degree centrality (for directed networks, measures how many edges come into a node – e.g., number of followers). Out-degree centrality (how many outgoing edges – e.g., following count). Normalized degree centrality (divide by $n-1$ to get a 0–1 score). H-index of degree (second-order measure: number of neighbors with degree ≥ k, etc.). But generally degree centrality is straightforward.

Closeness Centrality

Family: Centrality (Node Importance)
Definition: Closeness centrality of a node measures how close it is to all other nodes, typically defined as the reciprocal of the total distance from that node to all others: $C_C(v) = \frac{1}{\sum_{u \in V} d(v,u)}$. In other words, a node is central if it has short paths to all other nodes. Input: Graph $G=(V,E)$ (usually unweighted or one can use weighted distances), assume strongly connected or connected for distances to be finite. Output: For each node $v$, closeness $C_C(v)$ (sometimes normalized by $1/(n-1)$ factor).
Complexity: Computing closeness for all nodes requires computing all-pairs shortest paths or at least a single-source shortest path from each node. That’s $O(n \cdot (n+m))$ for unweighted (running BFS from each node) or $O(n \cdot m \log n)$ for weighted (running Dijkstra from each node). This is expensive for large $n$ (e.g., 10k nodes → 10k BFSes). Some optimizations exist (e.g., early stopping if graph is huge and approximate closeness).
Implementation Notes: Closeness assumes reachable distances. In a disconnected graph, often closeness is computed on each component separately (some definitions treat unreachable distance as infinite, making closeness 0). Some graph libraries normalize closeness by $(n-1)/( \sum d(v,u))$ so that a fully connected node in a small graph has closeness 1. Interpretation: Nodes with high closeness can quickly interact with others (think of centers in communication networks). It can be less meaningful in very large or disconnected networks.
Graph DB Usage: Neo4j GDS has a gds.alpha.closeness algorithm (usually requiring a BFS from each node). This is computationally heavy for large graphs, so sometimes people use approximation (e.g., sample a subset of source nodes, or use bidirectional BFS).
Primary Sources: Defined by Bavelas (1950) in social networks, later refined by Freeman (1979). It’s a classic centrality measure.
Known Variants: Harmonic centrality: Instead of summing distances, sum reciprocals of distances $\sum_{u \neq v} 1/d(v,u)$ (which handles infinite distances by treating them as 0 contribution, so disconnected nodes don’t completely ruin the measure). Harmonic centrality is a variant that is well-defined on disconnected graphs as well【45†】. Decay centrality: sum of decayed distances (to limit long-range effect).

Betweenness Centrality (Brandes’ Algorithm)

Family: Centrality (Node Importance)
Definition: Betweenness centrality $C_B(v)$ of a node $v$ is the sum over all pairs of other vertices $(s,t)$ of the fraction of shortest paths between $s$ and $t$ that pass through $v$. Formally, $C_B(v) = \sum_{s \neq v \neq t} \frac{\sigma_{st}(v)}{\sigma_{st}}$, where $\sigma_{st}$ is the total number of shortest paths from $s$ to $t$, and $\sigma_{st}(v)$ is the number of those paths that go through $v$. It measures how critical a node is for connecting different parts of the network. Input: Graph $G=(V,E)$ (usually unweighted or positively weighted; betweenness is typically defined for shortest paths). Output: $C_B(v)$ for all $v \in V$.
Complexity: Using Brandes’ algorithm (the fastest exact method), $O(nm)$ for unweighted graphs, and $O(nm + n^2 \log n)$ for weighted graphs. Without Brandes, a naive approach would be $O(n^3)$ (compute all pairs shortest paths and then count paths). Brandes’ algorithm leverages BFS (or Dijkstra for weighted) from each source to accumulate dependencies efficiently.
Pseudocode (Brandes 2001, unweighted case):

Brandes_Betweenness(G):
  BC[v] := 0 for all v
  for each source s in V:
      // single-source shortest paths
      S := empty stack
      P[w] := [] for all w in V       // predecessors on shortest paths
      σ[t] := 0 for all t in V        // number of shortest paths from s
      d[t] := -1 for all t in V       // distance from s
      σ[s] := 1; d[s] := 0
      Q := queue(); enqueue(Q, s)
      while Q not empty:            // BFS from s
          v := dequeue(Q)
          S.push(v)
          for each neighbor w of v:
              if d[w] < 0:          // w found for first time
                  d[w] := d[v] + 1
                  enqueue(Q, w)
              if d[w] = d[v] + 1:   // shortest path via v
                  σ[w] += σ[v]
                  P[w].append(v)
      // accumulation
      δ[v] := 0 for all v in V       // dependency
      while S not empty:
          w := S.pop()
          for v in P[w]:
              δ[v] += (σ[v] / σ[w]) * (1 + δ[w])
          if w ≠ s:
              BC[w] += δ[w]

(For weighted graphs, replace BFS with Dijkstra’s algorithm; distances $d[]$ guide the relaxation.)
Implementation Notes: The algorithm works by doing a BFS/Dijkstra from each source, collecting the number of shortest paths ($\sigma$) and predecessor lists $P$ for that source, then computing dependencies $\delta$ in a stack unwind. $\delta[v]$ ultimately gives $\sum_{s} \frac{\sigma_{sv}(v)}{\sigma_{sv}}$ for each $v$, which accumulates into $BC[v]$. This avoids recalculating all-pairs paths from scratch for each pair. Still, $O(nm)$ can be very slow for large graphs (e.g., $n=10^5$, $m=10^6$ is too large to do $10^5$ BFSes). Optimizations: One can compute approximate betweenness for large graphs by sampling a subset of source nodes $s$. Graph libraries sometimes implement approximation (e.g., Neo4j GDS has an approximate betweenness using random sampling). Interpretation: Nodes with high betweenness lie on many shortest routes – they are “bridges” in the network. For example, in the classic Karate Club network, the club president and instructor have highest betweenness because many communication paths go through them【45†】.
Graph DB Usage: Neo4j GDS provides gds.betweenness which uses Brandes’ algorithm for exact betweenness【22†】. One must project the graph into memory and it will be expensive if graph is large. TigerGraph and others also have betweenness in their libraries (often limited by memory).
Primary Source: Brandes (2001) presented this faster algorithm, bringing betweenness calculation from $O(n^3)$ to practical runtimes. Freeman (1977) originally defined betweenness.
Known Variants: Edge betweenness – similarly defined for edges (used in community detection by Girvan-Newman, below). Flow betweenness – uses maximum flow rather than shortest paths (less common). Approximate betweenness – as mentioned, sampling techniques (e.g., HyperBetweenness using hypergraph sketching) to estimate betweenness for large graphs.

Eigenvector Centrality

Family: Centrality (Node Importance)
Definition: Eigenvector centrality assigns each node a score proportional to the sum of scores of its neighbors. In matrix terms, if $A$ is the adjacency matrix of graph $G$, the centrality vector $x$ is defined by $x = \lambda^{-1} A x$, meaning $x$ is an eigenvector of $A$. Usually we take the principal eigenvector (the one with the largest eigenvalue) and corresponding entries as centrality scores【43†】. Intuitively, a node is important if it is connected to other important nodes. Input: Graph $G=(V,E)$ (often undirected, can be adapted to directed as well by considering the adjacency appropriately). Output: A centrality score $x[v]$ for each vertex $v$ (usually normalized so that max is 1 or sum of squares is 1).
Complexity: Computing the dominant eigenvector can be done by the power iteration method in about $O(m \cdot I)$ time, where $I$ is the number of iterations until convergence (which might be tens or hundreds). So roughly $O(m)$ per iteration. More sophisticated methods (Lanczos, etc.) can compute eigenvectors faster if high precision is needed. Typically, power iteration converges in polynomial time depending on the gap between largest and second eigenvalues.
Pseudocode (Power Iteration):

```text

initialize x[v] := 1 for all v
repeat T times or until convergence:
    x_next := array of size n with all 0
    for each edge (u,v) in E:
        x_next[v] += x[u]
        x_next[u] += x[v]   // if undirected, add both directions
    // for directed, only one direction addition depending on centrality type (in vs out)
    normalize x_next (e.g., divide by max or Euclidean norm)
    x := x_next
return x

```

Implementation Notes: For undirected graphs, adjacency matrix is symmetric and eigenvector centrality yields non-negative solutions (Perron-Frobenius theorem). For directed graphs, one can define eigenvector centrality on the transpose for “authority” scores (similar to HITS, next entry). In practice, one must be careful: if the graph is not strongly connected, the standard eigenvector centrality might put all weight in one component. Often a damping or restart is used (leading to PageRank). Interpretation: Eigenvector centrality identifies nodes with influential neighbors. It can get tricky: for example, in a star graph, the center has high eigenvector centrality, leaves have low (since they only connect to center which is high). But in a two-star graph connected by one edge, eigenvector might split scores in unintuitive ways (the eigenvector is unique up to scale only in a connected graph).
Graph DB Usage: Some graph systems have eigenvector centrality (Neo4j GDS includes it). It’s essentially computing the dominant eigenvector of adjacency. One might use it to find "influencers" when connections’ value is transitive.
Primary Sources: The concept was discussed by Phillip Bonacich (1972, 1987) in social networks【43†】. It’s closely related to Google’s PageRank and HITS (which are basically eigenvector methods on modified matrices).
Known Variants: Pagerank (next entry) is a variant with damping factor to ensure convergence on any graph and to incorporate random jump (also essentially an eigenvector of a stochastic matrix). Katz centrality (a generalization where you count all paths with attenuation, see Similarity section, Katz index). HITS (Hyperlink-Induced Topic Search) which gives each node two scores (authority and hub) via eigenvectors on $A^T A$ and $A A^T$.

PageRank

Family: Centrality (Node Importance, Link Analysis)
Definition: PageRank is essentially the stationary distribution of a random walk with restarts on a directed graph (originally for web link analysis)【21†】. Each node’s score can be thought of as: it gets a baseline $(1-\alpha)/n$ plus $\alpha$ times the sum of scores from neighbors linking to it, divided by their out-degree. Formula (for score vector $PR$) in matrix form: $PR = (1-\alpha)\frac{1}{n}\mathbf{1} + \alpha P^T PR$, where $P$ is the transition matrix of the graph. Typically $\alpha=0.85$. Input: Directed graph $G=(V,E)$ (can be weighted or not; if weighted, treat outgoing weights as proportions), damping factor $\alpha \in [0,1)$ (probability of continuing random walk versus reset). Output: PageRank score $PR[v]$ for each node $v$ (nonnegative, sums to 1 if normalized as probability).
Complexity: Power iteration takes $O(m)$ per iteration. Convergence typically in tens of iterations for $\alpha=0.85$ on large graphs, depending on eigen gap. So maybe $O((n+m) \cdot I)$. In practice, PageRank is very scalable (can be computed on billions of edges with distributed algorithms like MapReduce).
Pseudocode (iterative):

PageRank(G, α, T):
  n := |V|
  PR := array of size n, initialized to 1/n for all nodes
  for t = 1 to T:
      newPR := array of size n, initialized to 0
      // distribute PageRank score along out-links
      for each node u in V:
          if u has no out-neighbors:
              // dangling node: distribute its PR to all (random jump)
              for each v in V:
                  newPR[v] += α * PR[u] / n
          else:
              for each edge (u -> v):
                  newPR[v] += α * PR[u] / outdeg(u)
      // add random jump factor
      for each v in V:
          newPR[v] += (1-α) / n
      PR := newPR (or check convergence)
  return PR

Implementation Notes: The above handles dangling nodes (nodes with no outlinks) by redistributing their PageRank equally (one common approach). Many implementations accumulate the dangling node mass and add it proportionally. PageRank yields a probability distribution over nodes (in the limit as $t\to\infty$ if $\alpha<1$ on a strongly connected graph). If the graph is not strongly connected, the random reset ensures a unique solution. In practice, one iterates until the change (L1 norm difference) is below a tolerance. Use Cases: Originally for ranking webpages, now used in ranking influencers in social networks, identifying important proteins in biological networks, etc. It’s essentially an eigenvector centrality of the stochastic adjacency matrix.
Graph DB Usage: PageRank is widely available: Neo4j GDS: gds.pageRank (with dampingFactor and iterations), Apache Spark GraphX and GraphFrames have PageRank, TigerGraph has a builtin, ArangoDB Pregel provides it. It’s one of the easiest to scale on big data.
Primary Source: Brin and Page’s 1998 paper that launched Google search introduced PageRank【21†】. It builds on earlier work like eigenvector centrality and academic citation analysis.
Known Variants: Personalized PageRank: instead of random jump to uniform distribution, jump to a specific node or distribution (biasing the PageRank towards certain topics). Weighted PageRank: if edges have weights, use proportional transition probabilities. TrustRank: a variant to combat spam by personalizing to a set of trusted nodes. Also, HITS algorithm (below) is related but computes two scores instead of one.

HITS (Hyperlink-Induced Topic Search)

Family: Centrality (Node Importance, Link Analysis)
Definition: HITS assigns two scores to each node: an authority score and a hub score. Authorities are nodes with valuable content, and hubs are nodes that point to valuable content. In a web analogy, a good hub page points to many good authority pages; a good authority is pointed to by good hubs【44†】. The algorithm defines: authority scores $a[v]$ and hub scores $h[v]$ with relations $a[v] = \sum_{(u \to v) \in E} h[u]$ (sum of hub scores of those pointing to $v$), and $h[v] = \sum_{(v \to w) \in E} a[w]$【44†】. These can be seen as eigenvectors: $a = A^T h$ and $h = A a$ for adjacency matrix $A$, so $A^T A a = \lambda a$ (authority is principal eigenvector of $A^T A$). Input: Directed graph $G=(V,E)$ (often a focused subgraph from a query context). Output: Authority and hub scores for each node.
Complexity: Similar to PageRank/eigenvector computations. Each iteration is $O(m)$, and typically a few dozen iterations suffice for convergence. Often HITS is run on a subgraph of interest (like top relevant pages for a query).
Pseudocode (iterative update):

```text

initialize a[v] := 1, h[v] := 1 for all v
for t = 1 to T:
    // update authority scores
    for v in V:
        a_temp[v] := ∑_{u: (u -> v) ∈ E} h[u]
    // update hub scores
    for v in V:
        h_temp[v] := ∑_{w: (v -> w) ∈ E} a[w]
    // normalize (to prevent overflow and for convergence)
    norm_a := sqrt(∑_v a_temp[v]^2); norm_h := sqrt(∑_v h_temp[v]^2)
    for v in V:
        a[v] := a_temp[v] / norm_a
        h[v] := h_temp[v] / norm_h
return a, h

```

Implementation Notes: The normalization each iteration ensures the vectors don’t diverge and helps convergence. HITS is typically run on a query-specific subgraph: e.g., take the top search results for a query plus their immediate neighbors, then run HITS to see which are authorities/hubs for that query topic【44†】. Without focusing, HITS on a whole web graph can lead to dominance by a general “star” structure. Interpretation: A node with high authority is pointed by many high-hub nodes; high hub points to many high authorities. This circular definition converges to a fixed point. Authorities and hubs tend to form related sets (e.g., authorities on a topic and hubs that aggregate those authorities).
Use in Graph DB: Not as common as PageRank in general graph analytics, but conceptually could be implemented with iterative multiplications. Neo4j GDS as of current versions focuses on PageRank over HITS (since PageRank is more generalizable and easier to use on whole graph). However, one can implement HITS via Cypher or Gremlin by iterative updates.
Primary Source: Jon Kleinberg’s 1999 paper【44†】 introduced HITS in the context of web search (as an alternative to PageRank).
Known Variants: SALSA (Stochastic Approach for Link-Structure Analysis) which is like a randomized version of HITS on bipartite reformulation. IBM CLEVER project implemented HITS-like algorithms. HITS can be considered a specific case of eigenvector on a bipartite graph of in-links vs out-links.

Louvain Method (Community Detection via Modularity)

Family: Community Detection
Goal: Partition the graph’s nodes into communities (clusters) to maximize modularity or similar quality function. Louvain is a greedy heuristic that optimizes modularity, which measures density of links inside communities vs between communities. Input: Graph $G=(V,E)$ (undirected, weighted or unweighted). Output: A community assignment for each node (and a hierarchy of communities at multiple levels, since Louvain naturally produces a hierarchy).
Complexity: Louvain is quite fast in practice: $O(n \log n)$ average per iteration and a few iterations, overall often $O(m)$ or so, though worst-case not well-characterized. It’s approximate. The method is heuristic, but it scales to millions of nodes.
Pseudocode (high-level):

Louvain(G):
  assign each node to its own community
  improved := true
  while improved:
      improved := false
      // Phase 1: Local moving
      for each node v in V (in random order):
          let current_comm := comm[v]
          compute ΔQ for removing v from current_comm
          for each neighbor u of v:
              comm_u := comm[u]
              compute ΔQ_gain if v is placed in comm_u
          find comm* that maximizes ΔQ_gain (including possibility of staying in same community)
          move v to comm* if ΔQ_gain > 0
      // Phase 2: Community aggregation
      build a new graph G' whose nodes are the communities found, weights are sum of weights between communities
      if number of communities reduced (or modularity improved significantly):
          improved := true
          G := G'   // iterate on the coarse graph
  return community assignment (possibly with hierarchy)

Implementation Notes: Modularity $Q$ is defined as $Q = \frac{1}{2m} \sum_{ij} [A_{ij} - \frac{k_i k_j}{2m}] \delta(c_i, c_j)$, where $k_i$ is degree of $i$ and $\delta$ is 1 if $i,j$ in same community【11†】. Louvain’s greedy approach works surprisingly well, but it can get stuck in local maxima (result depends on order of nodes processed). The output is a hierarchy: initially each node separate, then communities merge into super-nodes and repeat, giving a multi-level structure. One can output the final assignment or intermediate levels. Directed graphs: Louvain is typically for undirected (for directed, modularity is less used, but one can treat edges as undirected or use directed modularity definitions). Weighted: Weighted edges are handled by summing weights (the algorithm accounts for edge weights in ΔQ calculation).
Graph DB Usage: Many graph analytics platforms implement Louvain. Neo4j GDS: gds.louvain produces community IDs【23†】. TigerGraph has tg_louvain in GSQL library【25†】. These are popular for finding clusters in social graphs, etc. Running time is pretty fast (e.g., millions of edges graph in seconds to minutes). Ensure the graph is treated undirected (or directed edges symmetrized if using modularity on directed).
Primary Source: Blondel et al. (2008) introduced Louvain method【11†】, which became one of the most used community detection algorithms due to its speed and reasonably good quality.
Known Variants: Leiden algorithm (2019, next entry) refines Louvain by fixing issues like disconnected communities and improves quality. Modularity optimization via simulated annealing or spectral methods exist but Louvain is faster. Other community algorithms: Label Propagation, Infomap, Girvan-Newman, etc., which are different approaches entirely.

Leiden Algorithm (Community Detection)

Family: Community Detection
Goal: An improvement over Louvain that ensures more well-connected communities and often yields better modularity and speed. Input/Output: Same as Louvain (undirected graph, communities assignment). Differences: Leiden refines the process by splitting communities internally before aggregation and guarantees that each community is connected (no trivial disconnected sub-parts). It also allows nodes to move to more communities (even empty ones) during local moving, leading to better exploration.
Process: Leiden has three phases per iteration: local moving (like Louvain but with ability to temporarily create singleton communities to improve exploration), refinement (after local move, split communities if they are not internally connected or can be improved by reassigning internally – this addresses the problem where Louvain could form a community that is actually disconnected or has internal structure), and aggregation (contract graph and repeat). The refinement phase ensures the subset optimality: no community can be split into parts that increase modularity by separating them.
Complexity: Similar to Louvain, often faster because it reaches good partitions in fewer iterations. The additional refinement step is efficient. Traag et al. reported it is faster and yields higher modularity partitions than Louvain on benchmark graphs【24†】.
Implementation Notes: Leiden’s key benefit is that it eliminates a known pitfall of Louvain: Louvain can get “locked” in a partition where one community contains multiple disconnected components (which is suboptimal). Leiden breaks those apart during refinement. The output community count can differ (Leiden often finds slightly more communities because it prevents lumping disparate groups together). For practical use, Leiden should be preferred over Louvain when available.
Graph DB Usage: Neo4j’s GDS library introduced Leiden as well (as of GDS 1.4+), often recommended over Louvain. One would call e.g. gds.beta.leiden.stream(...) for experimental support. It requires the graph and a starting partition (which can be every node itself by default). TigerGraph and others might not yet have Leiden, but one can implement as a post-processing of Louvain results.
Primary Source: Traag, Van Dooren & Nesterov, 2019 (published in Scientific Reports)【24†】. They prove the well-connectedness property and show empirically better results.
Known Variants: Leiden itself is a variant of Louvain. If one uses other quality functions (like CPM, etc.), Leiden can optimize those too. The approach could be extended beyond modularity to other clustering objective functions. For very large graphs, one might use a sampling or streaming variant, but generally Louvain/Leiden handle large graphs well.

Label Propagation (Community Detection)

Family: Community Detection
Idea: A fast, nearly linear-time algorithm where labels (community IDs) propagate through the network such that each node adopts the label that most of its neighbors have. It doesn’t optimize a formal objective like modularity but often finds reasonable communities. Input: Graph $G=(V,E)$ (undirected, unweighted for simplicity). Output: A label assignment (community for each node).
Complexity: $O(n + m)$ per iteration, and it usually converges in only a few iterations (often < 10). In practice, extremely fast (can scale to very large graphs easily). It’s not deterministic – different runs can yield different communities (tie-breaking is random).
Pseudocode:

```text

initialize label[v] := v for all v   // start with unique labels
changed := true
while changed:
    changed := false
    for each node v in V in random order:
        // count labels in neighbor set
        freq := map from label to count
        for each neighbor u of v:
            freq[label[u]] += 1
        L_max := argmax_{ℓ} freq[ℓ]  // label with highest frequency among neighbors
        if label[v] ≠ L_max:
            label[v] := L_max
            changed := true

```

Implementation Notes: The random traversal order helps avoid oscillations. One can also asynchronously update labels (as above) or synchronously (all nodes check neighbors then update, which may need damping to converge). Since there’s no guarantee of a single stable solution, the algorithm is often run until no change or until a maximum iterations cap. It can end up with trivial solution (all nodes same label) in some graphs if there’s one giant component with ambiguous structure; typically, small tie-breaking randomness prevents complete collapse. Use Cases: Good for quick community detection on large graphs when a rough partition is fine. It’s also used to initialize other algorithms. Because it doesn’t optimize a specific global metric, the communities might not maximize modularity but often correspond to intuitive clusters. It tends to find a slightly larger number of smaller communities than Louvain, etc., and can sometimes leave a few nodes with unique labels (assign them arbitrarily or treat as outliers).
Graph DB Usage: Neo4j GDS has gds.labelPropagation (super fast). It doesn’t require weight – for weighted edges one can incorporate weight into the neighbor count (e.g., weighted frequency). TigerGraph and others have similar algorithms (sometimes called “community label propagation”).
Primary Source: Raghavan, Albert, and Kumara (2007) introduced this near-linear algorithm【30†】. Despite its simplicity, it often performs surprisingly well.
Known Variants: Weighted label propagation (account for edge weights in vote count). Semi-synchronous update (to reduce oscillation, maybe update in batches). There are also approaches using label propagation for node classification (propagating known labels). Additionally, the algorithm can be extended to detect overlapping communities (by allowing nodes to hold multiple labels, etc., though that’s more complex).

Girvan–Newman Algorithm (Community via Edge Betweenness)

Family: Community Detection
Idea: A divisive algorithm that identifies communities by progressively removing edges with highest betweenness centrality, which eventually separates the graph into components. It’s conceptually simple but computationally expensive. Input: Graph $G=(V,E)$ (unweighted for simplicity). Output: A hierarchy of community splits (dendrogram). One can output communities at a chosen level (e.g., when modularity is highest).
Complexity: Betweenness computation is $O(nm)$ using Brandes’ algorithm. Removing one edge changes shortest paths, so recomputing betweenness after each removal yields $O(m \cdot n m) = O(n m^2)$ worst-case. For even moderate graphs, this is very slow. Typically, it’s only feasible for small networks (a few thousand nodes).
Process: Compute edge betweenness for all edges; remove the edge(s) with highest betweenness; this potentially splits a component. Recalculate betweenness on the modified graph; repeat. Track the communities as components at each step. Usually, one picks the partition at the step with maximal modularity.
Pseudocode (simplified):

G' := G
communities := {V}   // start with one component containing all nodes
best_modularity := -∞
best_partition := communities
while E(G') not empty:
    compute edge betweenness b(e) for all e in E(G')
    remove edge e with maximum b(e) from G' (if multiple, remove tied edges one by one or all at once if desired)
    update communities := connected components of G'
    compute modularity Q for current communities
    if Q > best_modularity:
        best_modularity := Q
        best_partition := communities
return best_partition

Implementation Notes: Removing edges one by one and recomputing betweenness is very slow. In practice, one might remove a batch of edges with similarly high betweenness before recomputing to save time (though the exact algorithm removes one at a time). The result is a dendrogram of splits. Girvan-Newman often reveals the hierarchy of community structure, but due to complexity it’s mostly of academic interest. On the classic Zachary’s Karate Club network (34 nodes), this algorithm famously finds the split that corresponds to the actual club fission into two groups【45†】. It’s a good teaching algorithm but not used for large-scale graphs.
Graph DB Usage: Unlikely to be implemented natively due to cost. One could theoretically use GDS betweenness repeatedly, but that’s very slow. Instead, faster community detection (Louvain, etc.) is used for large graphs.
Primary Source: Girvan and Newman’s 2002 paper【45†】 was influential in network science, introducing this algorithm and the concept of using betweenness to find community boundaries. It also defined modularity as a quality measure for communities.
Known Variants: Edge betweenness vs Node betweenness: The standard removes edges. One could remove vertices based on betweenness too, but that’s less common for community finding. Newman’s spectral algorithms: Later, Newman developed faster algorithms using eigenvectors of modularity matrix to detect communities in $O(n^2)$ or so, which is more tractable than Girvan-Newman for medium graphs. Those are beyond scope here.

(Infomap algorithm is another community detection approach based on compression of a random walk description, not detailed here due to space, but it’s an alternative to modularity methods.)

Jaccard, Adamic–Adar, and Related Similarity Metrics (Link Prediction)

Family: Similarity / Link Prediction
Problem: For a pair of nodes, assign a score indicating how likely a link exists or should exist between them, based on their neighbor sets. These measures are used in link prediction (predicting missing or future edges) and recommendation systems. We describe a few common local metrics: Jaccard coefficient, Adamic–Adar index, and Resource Allocation index. Input: Graph $G=(V,E)$, typically unweighted and undirected for these metrics (can be extended to directed by considering in/out neighbors accordingly). A pair of vertices $(u,v)$ for which we want a similarity score (often considering pairs that are not directly connected). Output: Similarity score for each pair (higher means more likely to have a link or stronger relation).
- Jaccard Coefficient: $J(u,v) = \frac{|N(u) \cap N(v)|}{|N(u) \cup N(v)|}$【12†】, where $N(x)$ is the set of neighbors of $x$. It measures the fraction of neighbors that two nodes share out of all neighbors either has.
- Adamic–Adar Index: $AA(u,v) = \sum_{w \in N(u) \cap N(v)} \frac{1}{\log |N(w)|}$【46†】. Common neighbors contribute to the score, with less-connected common neighbors (small $|N(w)|$) giving more weight (since a common neighbor that is very popular is less informative).
- Resource Allocation (RA) Index: $RA(u,v) = \sum_{w \in N(u) \cap N(v)} \frac{1}{|N(w)|}$【47†】. Similar to Adamic–Adar but uses $\frac{1}{|N(w)|}$ instead of $\frac{1}{\log |N(w)|}$. Both AA and RA give higher score if common neighbors have low degree, under the idea that a low-degree common neighbor is a strong sign of a specific connection.

Complexity: To compute these for a given pair $(u,v)$, one needs $N(u) \cap N(v)$. If degrees are $d(u)$ and $d(v)$, intersection can be done in $O(\min(d(u), d(v)))$ by checking each neighbor of the smaller set against a hash of the larger. If one wants all pairs scored, naive would be $O(n^2)$ which is infeasible for large $n$. Instead, one typically iterates over common neighbors: for each node $w$, consider all pairs of its neighbors $(u,v)$ and add contributions. This way, complexity is around $\sum_{w} \binom{d(w)}{2}$ contributions – can be large for high-degree nodes but manageable if network is sparse and not extremely hub-dominated. For link prediction, usually one only computes scores for pairs that are "candidate links" (e.g., have common neighbors).
Implementation Notes: These indices assume an undirected graph. For directed, one might use in-neighbors for common predecessor-based similarity (like in collaborative filtering). They are purely local: only immediate neighbors matter. This makes them fast and often effective (e.g., friends-of-friends heuristic). They don’t consider path lengths beyond 2. Adamic–Adar vs Resource Allocation: AA’s use of log is a bit less aggressive than RA’s reciprocal. RA is actually the same as the preferential attachment score if used differently (preferential attachment index is $|N(u)| \cdot |N(v)|$, which is another measure but opposite in spirit – it says high-degree nodes are more likely to link). Jaccard is bounded between 0 and 1. AA and RA are unbounded sums (though practically limited by number of common neighbors).
Use Cases: Link prediction (predicting missing links in social networks, recommender systems for user-item graphs by similarity), entity resolution (how similar two entities are by their connections), etc.
Graph DB Usage: These measures can be computed with queries (Cypher or Gremlin) focusing on two-hop neighborhoods. Neo4j GDS offers a gds.alpha.linkprediction pipeline with these metrics and more. For example, gds.alpha.linkprediction.adamicAdar(stream, {node1, node2}). These typically require the graph to be projected.
Primary Sources: Jaccard coefficient originates from Paul Jaccard (1901) in ecology for set similarity【12†】. Adamic–Adar was introduced by Lada Adamic and Eytan Adar (2003) for predicting friendships in a web context【46†】. Resource Allocation index was discussed by Zhou et al. (2009)【47†】.
Known Variants: Preferential Attachment: score = $|N(u)| \cdot |N(v)|$ (the opposite idea: popular nodes link more – often used as a baseline). Common Neighbors: (just count $|N(u)\cap N(v)|$ – simplest predictor). Sorensen Index: similar to Jaccard but uses average of degrees in denominator (2|N(u)∩N(v)|/(|N(u)|+|N(v)|)). Katz Index: (discussed next) which is a global measure summing over all paths.

Katz Index (Global Link Prediction)

Family: Similarity / Link Prediction
Definition: Katz index between two nodes $u$ and $v$ sums over all paths from $u$ to $v$, with longer paths penalized heavily. One formula: $\displaystyle \text{Katz}(u,v) = \sum_{\ell=1}^{\infty} \beta^\ell \cdot |{\text{paths of length }\ell \text{ from } u \text{ to } v}|$, where $0 < \beta < 1$ is a damping factor【48†】. Essentially it’s the $(u,v)$ entry of $(I - \beta A)^{-1} - I$ (the resolvent of adjacency matrix minus identity). Katz is like a refined version of counting common neighbors (which are paths of length 2) but also considers paths of length 3,4,... with exponentially decreasing weights. Input: Graph $G=(V,E)$, parameter $\beta$ (must be smaller than the reciprocal of the largest eigenvalue of $A$ to converge). Output: A score for each pair of nodes (higher means more connection strength).
Complexity: Direct computation via matrix inversion is $O(n^3)$ or so (or solving linear systems maybe $O(n^2.373})$, which is impractical for large graphs. However, since we often only care about relatively short paths, one can approximate by truncating at some length $L$: sum paths of length $\le L$. Then one can do BFS up to $L$ or multiply adjacency matrix $L$ times (though $A^\ell$ computation is expensive if $n$ large). In practice, Katz is global and expensive for big networks. Often, simpler indices suffice.
Implementation Notes: Katz essentially gives each pair a score similar to a matrix power series. If $\beta$ is small, only short paths matter. As $\beta$ approaches $1/\lambda_{\max}$, the scores blow up for nodes in the largest eigenvector support (thus Katz relates to eigenvector centrality: as $\beta \to 1/\lambda$, Katz scores are dominated by leading eigenvector). Many libraries don’t implement Katz due to complexity, but one can do approximate Katz by limiting path length or using sparse matrix methods. Interpretation: Katz can capture more nuanced relationships: e.g., two people with no immediate common neighbors might still have many 2-hop or 3-hop connections which suggests some similarity. However, it’s more computationally heavy and harder to interpret than local indices.
Graph DB Usage: Not common as a built-in. If needed, one could simulate Katz by computing $A, A^2, ...$ counts for each pair with small $\ell$, but that is combinatorial for large graphs. Usually, if one wants global measures, one might use truncated random walk or personalized PageRank as a proxy (PPR is somewhat analogous to Katz but for one source at a time).
Primary Source: Katz (1953) introduced a “new status index” for sociometric analysis【48†】, which is essentially this measure.
Known Variants: Leicht-Holme-Newman index: a normalized version of Katz that accounts for degree. Rooted PageRank / Personalized PageRank: can be used for link prediction similarly (score of one node relative to another via random walk). But Katz remains a classic academic measure.

Hopcroft–Karp Algorithm (Maximum Bipartite Matching)

Family: Matching / Assignment
Problem: Given a bipartite graph (vertices split into two disjoint sets $U$ and $V$, edges only between $U$ and $V$), find the maximum matching – the largest set of edges with no shared endpoints. This corresponds to pairing as many $U$’s with $V$’s as possible. Input: Bipartite graph $G=(U \cup V, E)$. Output: A matching $M \subseteq E$ of maximum size (and sometimes the size or which pairs).
Complexity: $O(m \sqrt{n})$. Specifically, $O(\sqrt{V} E)$ which for bipartite $n=|U|+|V|$ and $m=|E|$. This is much faster than augmenting path algorithms that are $O(n m)$. Hopcroft-Karp achieves this by finding multiple augmenting paths in each BFS/DFS phase.
Pseudocode (conceptual):

```text

initialize M := ∅ (empty matching)
repeat:
    // BFS to build layers (distance in alternating graph from free U nodes)
    dist := BFS_level_graph(G, M)   // find distance to each node in alternating graph from any free u ∈ U
    if no augmenting path exists (t not reached in BFS):
        break
    // DFS to find vertex-disjoint augmenting paths using dist info
    for each free u in U:
        DFS_find_path(u, M, dist)
        // this DFS uses dist[] to only follow edges if it leads closer to an unmatched V
        // each DFS that reaches a free v in V yields an augmenting path, which we augment (flip matched/unmatched edges along it)
until no augmenting path found

```

In simpler terms: BFS groups vertices by distance (in terms of alternating unmatched/matched edges) from free nodes in $U$ to find the shortest augmenting paths length. Then DFS finds as many disjoint augmenting paths of that minimum length as possible. Then the matching is augmented by all of them at once. This drastically reduces the number of phases needed (at most $O(\sqrt{n})$ phases, each BFS+DFS is $O(m)$).
Implementation Notes: We keep track of which nodes are matched (initially none). BFS on the “alternating graph” means: from a free $u$ node, you can follow an unmatched edge $(u \to v)$ to a $v$, then from a matched $v$ follow the matched edge $(v \to u')$ to $u'$, and so on, until you reach a free $v$. The distance layers help ensure these paths are shortest possible (so you find many of them of same length). This algorithm requires carefully managing the BFS level graph and then DFS using that level info (to ensure disjointness and no backtracking on longer paths).
Use Cases: Matching problems are common: job assignment (match people to jobs), network alignment, pairing algorithms in recommendation (user-item matches), etc. Bipartite matching is also used as a subroutine in more complex problems (like the Hungarian algorithm for weighted matching, or in flow algorithms).
Graph DB Usage: A graph database could implement Hopcroft-Karp for a bipartite graph given as two node labels and connecting relationships. I don’t recall built-in for Neo4j GDS (which focuses on analytics, not so much exact matching). One could model as a flow problem (each $U$ to each $V$ edge capacity 1, and source connects to all $U$, all $V$ to sink, then max flow equals max matching). So max bipartite matching can be solved via max flow too (with possibly higher complexity). If needed, one might export to a specialized library.
Primary Source: Hopcroft and Karp (1973) gave this algorithm【13†】, a classic in combinatorial optimization.
Known Variants: Hungarian Algorithm (a.k.a. Kuhn-Munkres, 1955) for weighted bipartite matching (assignment problem). Hungarian is $O(n^3)$ for $n$ jobs (which is typically $n = |U| = |V|$), uses augmenting paths with a different criteria (benefit/cost). For unweighted, Hopcroft-Karp is more efficient. Also, network flow algorithms can solve matching by converting it to a flow problem, but they are typically slower than Hopcroft-Karp for bipartite graphs. For general (non-bipartite) graph matching, algorithms like Edmonds’ blossom algorithm exist (much more complex, $O(n^3)$).

Hungarian Algorithm (Assignment Problem)

Family: Matching / Assignment (Weighted)
Problem: Given a complete bipartite graph between $n$ “workers” and $n$ “jobs” with a cost (or weight) for each worker-job pair, find a perfect matching (each worker assigned to one job, each job to one worker) that minimizes total cost (or maximizes total profit). This is the classic assignment problem. Input: An $n \times n$ cost matrix $C[i][j]$. Output: A permutation $\pi$ of ${1..n}$ assigning worker $i$ to job $\pi(i)$ such that $\sum_i C[i,\pi(i)]$ is minimized.
Complexity: $O(n^3)$. The Hungarian algorithm achieves cubic time【49†】. For moderately sized $n$ (hundreds or thousands), this is fine. For very large $n$, there are newer algorithms or use of network flow (which is also roughly $O(n^3)$ in worst case for bipartite flow).
Method Outline: The Hungarian algorithm can be understood in terms of reducing the matrix and finding augmenting paths in an equality graph (based on dual variables). Key steps: subtract row minima and column minima (this ensures there’s a zero in every row and column – it’s like setting a dual solution); then try to find a perfect matching using those zeros. If not possible, adjust the dual variables and repeat. Essentially it’s solving the assignment as a linear program (which has integrality) by primal-dual methods.
Pseudocode (sketch): (Omitting detailed steps due to complexity of algorithm)
1. Subtract the minimum value of each row from all entries of that row; then subtract the min of each column from all entries of that column. Now at least one zero in each row/col.
2. Find a minimum number of lines (rows or columns) to cover all zeros. If that number is $k < n$, adjust the matrix: subtract some value from all uncovered elements, add it to elements covered by two lines – this introduces more zeros. Continue until $k=n$ (enough independent zeros to potentially assign each row/col).
3. Once we have at least $n$ zeros that could allow a perfect matching, find an actual matching using those zeros (this is a bipartite matching problem on the “zero graph”). Use something like DFS or BFS to find augmenting path if the matching is not yet perfect, adjust which zeros are used (alternating zeros).
4. The matching found gives the optimal assignment.
This algorithm maintains dual feasibility and complementary slackness conditions and ends with an optimal solution.
Implementation Notes: It’s a bit complex but well-documented in algorithm texts. Modern implementations optimize the augmenting path search. For instance, using BFS to find augmenting path in O(n^2) repeated up to $n$ times yields $O(n^3)$. Memory is $O(n^2)$.
Use Cases: Assign tasks to agents with minimum cost or maximum efficiency. E.g., match tutors to students, match job candidates to jobs, assign deliveries to drivers with minimum total distance, etc. Also used in computing graph similarity (maximum matching in a bipartite graph of nodes for inexact graph matching).
Primary Source: Harold Kuhn (1955) developed it (“Hungarian” because based on earlier Hungarian mathematicians’ work)【49†】.
Variants: Munkres’ assignment algorithm is another name for Hungarian. Auction algorithm (Bertsekas) is an alternative $O(n^3)$ but sometimes faster in practice. Jonker-Volgenant algorithm is an optimized version of Hungarian for dense costs. For sparse assignment problems or very large, one might use min-cost max-flow algorithms.

Triangle Counting & Clustering Coefficient

Family: Triangles and Clustering
Triangle Counting Problem: Count the number of triangles (3-cycles) in an undirected graph. Also, count per node how many triangles that node is part of. Input: Graph $G=(V,E)$ undirected (can be unweighted or weighted for some generalizations). Output: Total triangle count $T$; for each node $v$, triangle count $T(v)$ (number of triangles that include $v$). Local clustering coefficient: $C(v) = \frac{T(v)}{\binom{d(v)}{2}}$, i.e., proportion of possible triangles through $v$ that actually exist. Global clustering coefficient (transitivity) = $\frac{3T}{\text{number of connected triples}} = \frac{3T}{\sum_v \binom{d(v)}{2}}$ (three times triangles over triples).
Complexity: A straightforward triangle count by checking every pair of neighbors for each node is $O(\sum_v \binom{d(v)}{2})$, which is worst-case $O(n^3)$ for dense graphs. Better algorithms exist using matrix multiplication or hashing intersections. An efficient method on adjacency list: for each edge $(u,v)$, intersect neighbor lists $N(u)$ and $N(v)$ – each common neighbor $w$ means a triangle $(u,v,w)$. If degrees are sorted ($d(u) \le d(v)$), you only iterate intersect on smaller neighbor sets on average. This can yield complexity about $O(m^{3/2})$ for typical sparse graphs. Graph orientation by degree is a common optimization: only count triangle via $(u,v)$ if $u < v$ and $u < w$ (some ordering) to avoid double counting. Using sorting or bitsets can also speed intersection.
Pseudocode (neighbor set intersection):

triangles := 0
for each vertex u:
    for each neighbor v in N(u):
        if u < v (for some ordering, e.g., degree-based or numeric id):
            // Intersect neighbors of u and v
            for each w in N(u):
                if w > u and edge (v,w) exists:
                    triangles++    // triangle (u,v,w)

(This counts each triangle once given the ordering constraint.) In practice, one would pick the smallest adjacency list to iterate and check membership of each neighbor in the larger list (which can be done via binary search or hash set).
Implementation Notes: Graph databases can count triangles via Cypher queries with triple self-join, but that’s expensive. Many systems have a built-in optimized triangle count (using techniques above). E.g., Neo4j GDS gds.triangleCount uses such an algorithm【31†】. Triangles are a key analytic for social networks (transitivity). Clustering coefficient is useful to measure how clustered a network is (e.g., social networks have high clustering: friends of friends likely also friends). Memory: If using bitset intersections, bitset of size $n$ per neighbor can speed up at cost of memory $O(n^2/word_size)$ in worst case. For large graphs, sticking to list intersections is better.
Primary Sources: Enumeration of triangles has long history; Chiba and Nishizeki (1985) gave an output-sensitive algorithm $O(m \alpha)$ where $\alpha$ is arboricity (for planar graphs or such). Schank & Wagner (2005) surveyed triangle listing algorithms【14†】.
Known Variants: Approximate triangle counting using wedges sampling (e.g., pick random triples). Triangle count in directed graphs (count directed triangles or ignore direction). Quadrangle counting (4-cycles) for bipartite graphs (common in recommender analysis). Triangles in weighted graphs lead to concepts like clustering coefficient weighted versions (e.g., using geometric mean of edge weights). Also, higher-order clustering generalizations beyond triangles.

Graph Embeddings – DeepWalk

Family: Graph Embedding (Learning)
Goal: Learn a vector representation (embedding) for each node such that nodes with similar graph neighborhoods have vectors close in the learned vector space. DeepWalk (Perozzi et al. 2014) is an early method that applies random walks on the graph and uses those as input to a skip-gram neural network (like word2vec) to learn node embeddings【15†】. Input: Graph $G=(V,E)$ (unweighted or weighted, typically unweighted for simplicity; can be directed or undirected; if directed, often treat as undirected or do walks respecting direction). Hyperparameters: embedding dimension $d$, number of walks per node $r$, walk length $l$, context window size $w$. Output: A matrix of size $|V| \times d$ where each row is a $d$-dimensional vector for a node.
Complexity: Generating walks: $r \cdot n$ walks of length $l$ each = $O(r \cdot n \cdot l)$. Each walk yields $(l-w)$ training contexts (sliding window). The skip-gram model training on corpus of size $O(r \cdot n \cdot l)$ with vocabulary $n$ and vector size $d$ is roughly $O(rnl \cdot d \cdot \log n)$ (if using negative sampling or hierarchical softmax). This can be heavy but is manageable for graphs of, say, millions of nodes with appropriate optimizations (often using negative sampling reduces cost).
Process Outline: 1. For each node $u \in V$, perform $r$ random walks of length $l$: $u = v_0 \to v_1 \to \dots \to v_l$ where each next step $v_{j+1}$ is a random neighbor of $v_j$ (in an unweighted graph, uniform among neighbors). 2. This yields sequences of node IDs like sentences of words. 3. Treat each sequence as a sentence and each node as a word, train a Skip-gram model (predict context nodes given a center node) with window size $w$. So for each occurrence of $v_j$ in a walk, we try to predict nodes $v_{j-w} ... v_{j+w}$ (the ones within window in that walk). 4. The learned latent vectors for each “word” (node) are the embeddings.
Implementation Notes: DeepWalk is essentially word2vec on random walk sequences. It captures community structure: nodes frequently co-visited in random walks get similar embeddings. It’s unsupervised feature learning. The result can be used in tasks like node classification, link prediction (feeding embedding features into classifiers). Parameter choices: $d=64$ or $128$ often, $r=10$, $l=40$, $w=5$ were typical defaults【15†】. Graph must be reasonably homogeneous (not extremely skewed in degree, or else random walks will be biased – though that bias is inherent info too). Memory: storing embeddings is $O(n d)$. For large graphs ($n$ millions, $d=128$, that’s hundreds of MBs which is fine). Training time is main factor; often an implementation leverages existing word2vec code.
Primary Source: Perozzi et al., KDD 2014【15†】. This was a breakthrough showing how to apply neural language model to graphs.
Known Variants: node2vec (next) extends DeepWalk by biased walks. LINE (2015) directly optimizes adjacency and 2-hop proximity in objective instead of random walks. Heterogeneous network embeddings (metapath2vec) for multi-typed nodes/edges. GraphSAGE (2017) moves to inductive learning by aggregating neighbor features instead of transductive matrix. DeepWalk itself is transductive (we learn only for existing nodes; new nodes require re-training or approximation).

Graph Embeddings – Node2Vec

Family: Graph Embedding (Learning)
Goal: Similar to DeepWalk – learn vector embeddings for nodes – but with more flexibility in random walk generation. node2vec (Grover & Leskovec 2016) introduced biased random walks that can interpolate between breadth-first (homophily-based) and depth-first (structural equivalence-based) sampling【52†】. Two parameters: $p$ and $q$ guide the random walk’s bias. Input/Output: Same as DeepWalk (graph and hyperparams), plus bias parameters $p, q$. Walk strategy: On a walk, when moving from node $u$ to neighbor $v$, the next step choice among neighbors of $v$ is biased by whether it’s backtracking to $u$, going to a neighbor of $v$ that is close to $u$, or an outwards move. Specifically, transition probabilities are: - If $x$ is the previous node (came from $x$ to $v$), then for each neighbor $y$ of $v$: - If $d(x,y) = 0$ (i.e., $x=y$, backtracking) probability $\propto 1/p$. - If $d(x,y) = 1$ (y is adjacent to x) probability $\propto 1$. - If $d(x,y) = 2$ (y not adjacent to x) probability $\propto 1/q$. Where $d(x,y)$ is shortest path distance between previous node $x$ and candidate $y$. Intuition: $q < 1$ encourages outward exploration (weight far nodes more), $q > 1$ encourages staying closer to the previous context. $p$ controls likelihood of immediately backtracking (if $p$ high, less likely to backtrack).
Complexity: Slightly more overhead than DeepWalk for computing transition weights (need to know if neighbor of neighbor is adjacent to previous). One can precompute $d(x,y)$ for neighbors of neighbors (basically whether something is adjacent or not) quickly by adjacency checks. Overall complexity similar to DeepWalk’s $O(r n l)$ walk generation and training.
Implementation Notes: node2vec with $p=1,q=1$ reduces to DeepWalk (unbiased). Setting $q<1$ means favor nodes that are far (so the walk behaves more like DFS exploring outwards – good for structural equivalence, i.e., learning roles), $q>1$ means bias toward nodes that are near previous node (so more like BFS – good for homophily, staying within community). People often tune $p,q$ or use defaults like $(p=1,q=2)$ etc. Practical: If $q$ is large, the walk tends to do triangular loops (staying in neighborhood). If $q$ small, it will jump out. If $p$ small (<1), you allow immediate backtrack which means you might oscillate (not recommended, usually $p>=1$). Graph DB Usage: These embedding methods are generally outside of Cypher; one would use a separate library or something like PyTorch Geometric or karateclub in Python. Some graph systems have them integrated (e.g., Neo4j had an alpha algorithm for node2vec, TigerGraph has embedding algorithms in GSQL library, etc.).
Primary Source: Grover and Leskovec, KDD 2016【52†】. Known Variants: Many – after node2vec, came Struc2vec (learn purely structural roles via comparing degree sequences instead of using graph connectivity). GraphSAGE (semi-supervised, uses feature aggregation). NetMF (shows DeepWalk is implicitly factorizing a matrix related to powers of adjacency). LINE (mentioned before), HOPE, etc. The field moved towards deep learning on graphs (Graph Neural Networks) which produce embeddings as well, but node2vec/DeepWalk remain popular for unsupervised embeddings.

Subgraph Isomorphism – Ullmann’s Algorithm

Family: Graph Isomorphism & Matching
Problem: Determine if a smaller “pattern” graph $P=(V_P,E_P)$ is isomorphic to a subgraph of a larger “target” graph $G=(V,E)$ – i.e., find a mapping from $V_P$ to some subset of $V$ that preserves adjacency. Subgraph isomorphism is NP-complete in general, so algorithms are backtracking search with pruning. Ullmann’s Algorithm (1976) is a classic backtracking algorithm for subgraph iso【16†】. Input: Pattern graph $P$ (with $n_p$ nodes), Target graph $G$ (with $n$ nodes). Output: Either a mapping (injective function) $f: V_P \to V$ such that $(u,v) \in E_P \implies (f(u), f(v)) \in E$ (and sometimes one may want all such mappings), or a boolean answer if just existence. Possibly consider labels on nodes/edges to prune matches.
Complexity: Worst-case exponential. In practice, algorithms prune heavily and work for moderate sizes (pattern of dozen nodes in graph of thousands, perhaps). Ullmann’s algorithm is $O(n!/(n-n_p)! )$ in worst case (trying assignments of $n_p$ pattern nodes to some of $n$ target nodes). But with pruning, it can be much faster.
Pseudocode (backtracking with refinement):

```text

function matchRecursive(mapping M, candidates C):
    if |M| = |V_P|:
        return M as a solution
    choose an unmapped pattern node p
    for each target node t in C[p]:
        if t is not already used in M:
            if for all neighbors p' of p (that are mapped in M to some t'), (t,t') is an edge in G:
                // partial consistency check
                M[p] = t
                refine candidate sets C' for remaining nodes using this assignment (e.g., neighbors of p must map to neighbors of t, etc.)
                matchRecursive(M, C')
                remove M[p] (backtrack)

```

Ullmann’s original algorithm uses an adjacency matrix and does bit-vector operations to prune, as well as a refinement step akin to coarse backtracking without full Ullmann's refinement. Modern improvements like VF2 (described next) add more efficient feasibility checks.
Implementation Notes: Key to prune: using compatibility matrices (which pattern nodes can map to which target nodes based on degree, label, etc.), and using forward-checking (once a mapping partial, eliminate targets for adjacent pattern nodes that don’t have required connectivity). Ullmann uses a matrix $M$ of size $n_p \times n$ where $M[i][j] = 1$ if pattern node $i$ can map to target node $j$ (initially based on labels or degree). Then it recursively tries to assign and updates this matrix by eliminating inconsistent possibilities (like AC-3 constraint propagation in CSP). This is often described as refinement using adjacency matrices multiplication to filter out neighbors.
Primary Source: Ullmann (Journal of ACM, 1976)【16†】. It was one of the first general algorithms for subgraph isomorphism and is straightforward but can be slow if not pruned enough.
Known Variants: VF2 algorithm (see below) is widely used with improved pruning and data structures. VF3, VF3Lite are more recent improvements for certain graph characteristics. Ullmann vs VF2: VF2 tends to outperform Ullmann on many cases due to better state pruning (like checking degree sequences and connectivity on the fly). However, Ullmann’s bit matrix approach can be fast for small patterns because of bit parallelism.

Subgraph Isomorphism – VF2 Algorithm

Family: Graph Isomorphism & Matching
Problem: Same subgraph isomorphism task. VF2 (Cordella et al. 2004) is an improved algorithm that uses a matching state representation and efficient pruning rules【53†】. It tracks a state consisting of partial mapping and sets of “core” (mapped), “in” (neighbors of core in target not yet matched) and “out” (neighbors of core in pattern not yet matched) nodes to efficiently pick the next candidate match and prune.
Key Features: - Feasibility rules: Before extending the mapping with a candidate pair (p in pattern, t in target), VF2 checks that degrees match (the number of neighbors of p that are already matched corresponds to number of neighbors of t that are matched, etc.), and that the addition won’t violate the possibility of completing the mapping (for example, ensures that target has enough neighbors to map the remaining neighbors of p). - It also checks label compatibility if nodes/edges have labels. - Uses in/out sets to limit search: it tends to map nodes that bring new neighbors incrementally.
Backtracking structure: It picks the next pattern node usually from those that are in the “out” set (neighbors of already mapped ones), to grow the matched subgraph outward. This helps localize the search.
Complexity: Exponential in worst case, but VF2 is generally faster than Ullmann on most benchmarks. Cordella’s paper showed it effective for reasonably sized graphs (patterns with dozens of nodes in graphs with thousands).
Implementation Notes: VF2 is implemented in many libraries (NetworkX, Boost Graph Library, etc.). It’s a backtracking search: a recursive function match(state) that attempts to add one more mapping. The state includes a mapping dict and sets of unmapped, and the in/out as described. The pruning conditions (feasibility) incorporate: - The semantic feasibility: labels match for the candidate pair. - The syntactic feasibility: for all already matched pairs $(p_i, t_j)$, ensure that adjacency relationships are preserved: if $p$ is adjacent to $p_i$ in pattern, then $t$ must be adjacent to $t_j$ in target (and vice versa for non-edges if looking for induced subgraph, though usually we allow subgraph not induced, so only require edges present, not worry about absent edges). - And degree conditions: for any not-yet-matched neighbor of $p$, there should be enough corresponding not-yet-matched neighbor of $t$ to accommodate them, etc. These checks prune many branches early. VF2++ (2018) further improves by ordering and additional pruning based on connectivity and simulation filters【54†】, VF3 improves memory.
Primary Source: Cordella et al., IEEE TPAMI 2004 (they presented VF2)【53†】. VF stands for “Vertex Focusing”. Known Variants: VF2 is for subgraph iso. VF2 can also be adapted to graph isomorphism (checking if two graphs are isomorphic) as a special case. VF2+ (2017) by Carletti et al. adds further pruning. VF3 (2018) by Carletti et al.【54†】 is meant for larger graphs by reducing memory usage and using different node ordering strategies. Ullmann vs VF2: often VF2 is superior. There are also Backtracking with constraint propagation algorithms like Ullmann’s with refined domains, and bitset-based ones for speed on smaller dense patterns. For very large graphs, often one uses dual simulation or heuristic pruning because exact subgraph search is hard. Also, Neo4j and other graph DBs solve small subgraph query via these or similar algorithms under the hood (Cypher might do a subgraph match using such backtracking and indexes on labels to cut down candidates).

Planarity Testing – Hopcroft–Tarjan Algorithm (Optional)

Family: Planarity (Graph Drawing)
Problem: Determine if a graph is planar – i.e., it can be drawn on a plane without any edges crossing. If planar, produce a planar embedding; if not, identify a Kuratowski subgraph (homeomorphic to K5 or K3,3) as a witness. Input: Graph $G=(V,E)$ (usually undirected). Output: Boolean planar / nonplanar, and optionally an embedding or obstruction.
Complexity: Hopcroft and Tarjan’s algorithm (1974) runs in linear time $O(n+m)$【17†】, which is non-trivial given the complexity of the problem. Their algorithm is quite intricate, involving DFS and carefully tracking back edges, and constructing a planar embedding or finding a subdivision of K5/K3,3.
Approach Outline: They perform a DFS and maintain structures called “PC-trees” or uses something akin to articulation points and biconnected components concepts. The algorithm incrementally attempts to embed edges and if a conflict arises that cannot be resolved, it reports nonplanarity. A simplified description is beyond scope, but essentially: - For each biconnected component (since cut vertices separate planarity concerns), attempt to embed it. - Use a DFS ordering and consider edges; maintain for each face a circular list of edges (embedding). - Handle “edge additions” and if an edge cannot be embedded without crossing, identify that as evidence of nonplanarity. It’s complex but elegant, using depth-first search similarly to how Tarjan did for SCC, but with extra structures.
Implementation Notes: Planarity algorithms are specialized; many implementations prefer simpler $O(n^2)$ ones for moderate size. However, linear algorithms exist (Hopcroft-Tarjan, and later algorithms by Boyer-Myrvold which is simpler to implement). Graph databases typically don’t need planarity check, but in some graph drawing or GIS contexts it’s relevant (e.g., road networks are planar except for overpasses, etc.).
Primary Source: Hopcroft and Tarjan, J. ACM 1974【17†】. This was a breakthrough giving the first linear time planarity test. Known Variants: Boyer-Myrvold algorithm (2004) is a simplification of Hopcroft-Tarjan, also linear, often used in practice for implementation. Planar embedding algorithms to actually draw the graph once you know it’s planar (like constructing a dual graph, etc.). Not directly used in typical graph analytics, hence optional here.



References (Accessed 2025-09-21):

Neo4j Graph Data Science: PageRank algorithm. Neo4j Documentation.

Apache TinkerPop 3.4.2 Documentation: Graph Computer & PageRank. TinkerPop Reference.

TigerGraph Graph Data Science Library: Louvain algorithm. TigerGraph Docs 3.10.

ArangoDB 3.10 Pregel Documentation: Pregel Algorithms (Pagerank, etc.).

Perozzi et al. (2014). "DeepWalk: Online Learning of Social Representations." KDD. DOI:10.1145/2623330.2623732【15†】.

Brin & Page (1998). "The Anatomy of a Large-Scale Hypertextual Web Search Engine." Computer Networks, 30(1-7). (Google’s PageRank)【21†】.

Tarjan, R. (1972). "Depth-First Search and Linear Graph Algorithms." SIAM J. Computing, 1(2): 146-160. DOI:10.1137/0201010.

Kruskal, J. (1956). "On the shortest spanning subtree of a graph and the traveling salesman problem." Proc. AMS, 7(1): 48-50. DOI:10.2307/2033241【8†】.

Edmonds, J. & Karp, R. (1972). "Theoretical improvements in algorithmic efficiency for network flow problems." J. ACM, 19(2): 248-264. DOI:10.1145/321694.321699.

Brandes, U. (2001). "A faster algorithm for betweenness centrality." J. Mathematical Sociology, 25(2): 163-177. DOI:10.1080/0022250X.2001.9990249.

Blondel, V. D., Guillaume, J.-L., Lambiotte, R., Lefebvre, E. (2008). "Fast unfolding of communities in large networks." J. Stat. Mech. P10008. arXiv:0803.0476【11†】.

Jaccard, P. (1901). "Étude comparative de la distribution florale..." Bull. Société Vaudoise des Sci. Nat. 37: 547-579【12†】. (Introduced Jaccard index).

Hopcroft, J., Karp, R. (1973). "An $n^{5/2}$ algorithm for maximum matchings in bipartite graphs." SIAM J. Computing, 2(4): 225-231. DOI:10.1137/0202019.

Schank, T., Wagner, D. (2005). "Finding, counting and listing all triangles in large graphs." WAW 2005, LNCS 3514: 606-609. DOI:10.1007/11427186_54.

Grover, A., Leskovec, J. (2016). "node2vec: Scalable Feature Learning for Networks." KDD. DOI:10.1145/2939672.2939754.

Ullmann, J. R. (1976). "An algorithm for subgraph isomorphism." J. ACM, 23(1): 31-42. DOI:10.1145/321921.321925.

Hopcroft, J., Tarjan, R. (1974). "Efficient planarity testing." J. ACM, 21(4): 549-568. DOI:10.1145/321850.321852.

Neo4j Graph Data Science: Triangle Count algorithm. Neo4j Docs..

Wikipedia: Maximum flow problem – Complexity. (Dinic $O(V^2E)$ etc.).

Stanford SNAP: Betweenness Centrality PDF (Brandes).

Nature Scientific Reports: Traag et al. (2019). "From Louvain to Leiden: guaranteeing well-connected communities." DOI:10.1038/s41598-019-41695-z.

Neo4j Graph Data Science: Algorithm Reference (Betweenness, etc.). Neo4j Docs 2023..

Neo4j Graph Data Science: Louvain algorithm. Neo4j Docs.【23†】.

Medium (P. Balci, 2025). "Understanding the Leiden Algorithm" (explains improvements over Louvain).

Neo4j Graph Data Science: PageRank documentation. Neo4j Docs..

blog.heycoach.in: "Time Complexity Of Maximum Flow Algorithms" (summarizes Edmonds-Karp, Dinic).

Neo4j Graph Data Science: Strongly Connected Components. Neo4j Docs..

Tarjan, R. (1975). "Efficiency of a good but not linear set union algorithm." J. ACM, 22(2): 215-225. DOI:10.1145/321879.321884 (Union-find analysis).

Raghavan, U., Albert, R., Kumara, S. (2007). "Near linear time algorithm to detect community structures." Phys. Rev. E, 76: 036106. DOI:10.1103/PhysRevE.76.036106【30†】.

Cordella, L. et al. (2004). "A (sub)graph isomorphism algorithm for matching large graphs." IEEE TPAMI, 26(10): 1367-1372. DOI:10.1109/TPAMI.2004.75【53†】.

Jüttner, A. et al. (2018). "VF2++: An improved subgraph isomorphism algorithm." Discrete Applied Math., 242: 69-81. DOI:10.1016/j.dam.2017.12.020【54†】.

Kuhn, H. (1955). "The Hungarian method for the assignment problem." Naval Res. Logist. Quart., 2(1-2): 83-97【49†】. (Original assignment algorithm paper).

Freeman, L. (1979). "Centrality in social networks: Conceptual clarification." Social Networks, 1: 215-239. (Defines degree, closeness, betweenness centralities).

Zhou, T., Lü, L., Zhang, Y. (2009). "Predicting missing links via local information." Eur. Phys. J. B, 71: 623–630. DOI:10.1140/epjb/e2009-00335-8 (Resource allocation index)【47†】.

Katz, L. (1953). "A new status index derived from sociometric analysis." Psychometrika, 18(1): 39-43. DOI:10.1007/BF02289026【48†】.

Kahn, A. (1962). "Topological sorting of large networks." Commun. ACM, 5(11): 558-562. DOI:10.1145/368996.369025【38†】.



Understanding the Leiden Algorithm | by Pelin Balci | Medium



GraphBLAS



blogs.asarkar.com



Triangle Count - Neo4j Graph Data Science



Johnson's algorithm - Wikipedia



A Note on the Complexity of Dijkstra's Algorithm for Graphs with ...



GraphStream - The All Pair Shortest Path (APSP) Algorithm



Maximum Flow: The Ultimate Guide - HeyCoach | Blogs



Graph Theory - Dinic's Algorithm - Tutorials Point



Dinitz' algorithm: The original version and even's version



Step-by-step solutions to common graph algorithm interview problems



[PDF] Network Flow



From Louvain to Leiden: guaranteeing well-connected communities



From Louvain to Leiden: guaranteeing well-connected communities



snap.stanford.edu



PageRank - Neo4j Graph Data Science



Hopcroft–Karp algorithm - Wikipedia



Finding, Counting and Listing All Triangles in Large Graphs, an ...
