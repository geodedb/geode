// Copyright (c) 2024-2025 CodePros
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

// Basic data structures
pub const Stack = @import("stack.zig").Stack;
pub const Queue = @import("queue.zig").Queue;
pub const Deque = @import("deque.zig").Deque;
pub const Set = @import("set.zig").Set;
pub const MultiSet = @import("set.zig").MultiSet;

// Tree structures
pub const BST = @import("bst.zig").BST;
pub const RBTree = @import("rbtree.zig").RBTree;
pub const SkipList = @import("skiplist.zig").SkipList;
pub const Trie = @import("trie.zig").Trie;

// Graph structures
pub const Graph = @import("graph.zig").Graph;
pub const graph_core = @import("graph_core.zig");
pub const Vertex = graph_core.Vertex;
pub const Edge = graph_core.Edge;
pub const EdgeOptions = graph_core.EdgeOptions;
pub const createEdge = graph_core.createEdge;

// Graph algorithms
pub const graph_algorithms = @import("graph_algorithms.zig");
pub const bfsFrom = graph_algorithms.bfsFrom;
pub const dfsFrom = graph_algorithms.dfsFrom;
pub const topoKahn = graph_algorithms.topoKahn;
pub const topoDFS = graph_algorithms.topoDFS;
pub const cycleDetectDirected = graph_algorithms.cycleDetectDirected;
pub const cycleDetectUndirected = graph_algorithms.cycleDetectUndirected;
pub const multiSourceBFS = graph_algorithms.multiSourceBFS;

// Shortest path algorithms (single-source)
pub const shortest_paths = @import("shortest_paths.zig");
pub const Path = shortest_paths.Path;
pub const HeuristicFn = shortest_paths.HeuristicFn;
pub const reconstructPath = shortest_paths.reconstructPath;
pub const dijkstra = shortest_paths.dijkstra;
pub const aStar = shortest_paths.aStar;
pub const iddfs = shortest_paths.iddfs;
pub const dagShortestPath = shortest_paths.dagShortestPath;

// Shortest path algorithms (all-pairs)
pub const all_pairs_paths = @import("all_pairs_paths.zig");
pub const BellmanFordResult = all_pairs_paths.BellmanFordResult;
pub const bellmanFord = all_pairs_paths.bellmanFord;
pub const FloydWarshallResult = all_pairs_paths.FloydWarshallResult;
pub const floydWarshall = all_pairs_paths.floydWarshall;

// Connectivity algorithms
pub const connectivity = @import("connectivity.zig");
pub const SCCResult = connectivity.SCCResult;
pub const ArticulationResult = connectivity.ArticulationResult;
pub const sccTarjan = connectivity.sccTarjan;
pub const articulationBridges = connectivity.articulationBridges;

// Spanning tree algorithms
pub const spanning_trees = @import("spanning_trees.zig");
pub const MSTResult = spanning_trees.MSTResult;
pub const kruskal = spanning_trees.kruskal;
pub const prim = spanning_trees.prim;

// Union-Find data structure
pub const UnionFind = @import("unionfind.zig").UnionFind;

// Flow algorithms
pub const flow = @import("flow.zig");
pub const MaxFlowResult = flow.MaxFlowResult;
pub const edmondsKarp = flow.edmondsKarp;
pub const dinic = flow.dinic;

// Matching algorithms
pub const matching_mod = @import("matching.zig");
pub const BipartiteMatchingResult = matching_mod.BipartiteMatchingResult;
pub const hopcroftKarp = matching_mod.hopcroftKarp;

// Centrality algorithms
pub const centrality_mod = @import("centrality.zig");
pub const PageRankResult = centrality_mod.PageRankResult;
pub const CentralityResult = centrality_mod.CentralityResult;
pub const pageRank = centrality_mod.pageRank;
pub const computeCentrality = centrality_mod.computeCentrality;

// Caching & Probabilistic structures
pub const cache_mod = @import("cache.zig");
pub const LRU = cache_mod.LRU;
pub const LFU = cache_mod.LFU;
pub const BloomFilter = cache_mod.BloomFilter;
pub const CountMinSketch = cache_mod.CountMinSketch;

// String search algorithms
pub const string_search = @import("string_search.zig");
pub const findAllKMP = string_search.findAllKMP;
pub const findAllRabinKarp = string_search.findAllRabinKarp;
pub const findAllBoyerMoore = string_search.findAllBoyerMoore;

// DOT format support
pub const dot = @import("dot.zig");
pub const DOTGraph = dot.DOTGraph;

// GQL emission
pub const gql = @import("gql.zig");
pub const GQLResult = gql.GQLResult;
pub const emitCreateGQL = gql.emitCreateGQL;
pub const emitMatchShortestPathGQL = gql.emitMatchShortestPathGQL;

// Parallel utilities (spice-based)
pub const parallel = @import("parallel.zig");
pub const parallelReduce = parallel.parallelReduce;
pub const parallelSum = parallel.parallelSum;
pub const parallelMax = parallel.parallelMax;
pub const parallelMin = parallel.parallelMin;
pub const parallelMap = parallel.parallelMap;
pub const parallelCount = parallel.parallelCount;
pub const parallelAny = parallel.parallelAny;
pub const parallelAll = parallel.parallelAll;
pub const getSpicePool = parallel.getSpicePool;
pub const deinitSpicePool = parallel.deinitSpicePool;

test {
    std.testing.refAllDecls(@This());
    _ = @import("graph_algorithms_test.zig");
    _ = @import("shortest_paths_test.zig");
    _ = @import("connectivity_test.zig");
    _ = @import("spanning_trees_test.zig");
    _ = @import("unionfind_test.zig");
    _ = @import("flow_test.zig");
    _ = @import("matching_test.zig");
    _ = @import("centrality_test.zig");
    _ = @import("cache_test.zig");
    _ = @import("string_search_test.zig");
    _ = @import("dot_test.zig");
    _ = @import("gql_test.zig");
    _ = @import("property_test.zig");
}
