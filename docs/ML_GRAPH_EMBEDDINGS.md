# ML Graph Embeddings Integration System

> **STATUS: EXPERIMENTAL (GAP-0879, 2026-06-11).** The graph-embedding
> algorithms in `src/ml/graph_embeddings.zig` are simplified, small-scale
> implementations intended for experimentation — not production-grade
> representation learning. What is real and regression-tested
> (`zig build test-gap0879`):
>
> - **Node2Vec / DeepWalk walks** implement the genuine p/q transition bias
>   (Grover & Leskovec 2016) with deterministic seeding (`EmbeddingConfig.seed`).
> - **Training loss** is computed from the actual embeddings every epoch
>   (mean pre-update squared distance over skip-gram pairs) and is recorded in
>   `TrainingContext.initial_loss` / `TrainingContext.loss` — never simulated.
> - **GraphSAGE** uses a simplified aggregation (mean pooling + a single
>   learned linear projection), NOT the full per-layer weight stack of
>   Hamilton et al. 2017. Treat its output as experimental.
> - The skip-gram update itself is a simplified pull-together rule, not
>   negative-sampling SGNS.

## Overview

The ML Graph Embeddings system provides experimental machine learning capabilities for generating, managing, and utilizing graph embeddings in Geode. This system implements simplified variants of graph embedding algorithms including Node2Vec, GraphSAGE, and DeepWalk for analytics experimentation and similarity search prototyping.

## Architecture

### Core Components

#### GraphEmbeddingsManager

The central component that manages all embedding operations:

- **Embedding Storage**: Hash map of node IDs to embedding vectors
- **Algorithm Registry**: Configurable ML algorithm implementations
- **Training Context**: Comprehensive training state management
- **Statistics Tracking**: Performance metrics and convergence monitoring

#### Algorithm Implementations

- **Node2Vec**: Biased random walks with flexible exploration strategies (real p/q transition sampling)
- **GraphSAGE**: Inductive learning with simplified aggregation (experimental)
- **DeepWalk**: Uniform random walks (Node2Vec with p = q = 1)

#### Training System

- **Learning Rate Decay**: Adaptive learning rate reduction over time
- **Convergence Detection**: Automatic stopping when loss stabilizes
- **Early Stopping**: Patience-based training termination
- **Batch Processing**: Configurable batch sizes for memory efficiency

## Supported Algorithms

### Node2Vec

Biased random walk algorithm with configurable exploration parameters
(`EmbeddingConfig` in `src/ml/graph_embeddings.zig`):

```zig
// EmbeddingConfig fields
.p = 1.0,          // Return parameter: transition weight 1/p back to the previous node
.q = 1.0,          // In-out parameter: weight 1/q to nodes at distance 2 from the previous node
.walk_length = 80, // Length of each random walk
.num_walks = 10,   // Number of walks per node per epoch
.window_size = 10, // Skip-gram context window
.seed = null,      // Set for deterministic, reproducible walks and init
```

**Key Features:**

- Real p/q transition bias per Grover & Leskovec 2016 §3.2: unnormalized
  weight `1/p` to return to the previous node, `1` for neighbors of the
  previous node, `1/q` for distance-2 nodes (verified by
  `tests/test_ml_graph_embeddings_integration.zig`)
- Deterministic seeding via `EmbeddingConfig.seed`
- Per-epoch loss recorded in `TrainingContext` from real computation

### GraphSAGE (simplified aggregation — experimental)

Inductive learning with neighbor sampling and a SIMPLIFIED aggregation:
mean pooling over sampled neighbor embeddings followed by a single learned
linear projection, ReLU, and L2 normalization. This is NOT the full
GraphSAGE layer stack (`W · [self ‖ aggregated]` per layer with trained
unsupervised loss) from Hamilton et al. 2017.

```zig
// EmbeddingConfig fields
.neighbor_samples = 25,   // Number of neighbors to sample
.aggregator_type = .mean, // Only mean aggregation is actually applied
```

**Key Features:**

- Neighbor sampling with mean aggregation
- Inductive prediction for unseen nodes (`predictEmbedding`)
- EXPERIMENTAL: do not treat output as reference-quality GraphSAGE

### DeepWalk

Uniform random walk algorithm — implemented as Node2Vec with p = q = 1:

```zig
// EmbeddingConfig fields
.walk_length = 80,   // Length of each random walk
.num_walks = 10,     // Number of walks per node per epoch
.window_size = 10,   // Context window for skip-gram
```

## Usage Examples

### Basic Embedding Generation

Real API (see `tests/test_ml_graph_embeddings_integration.zig` for a full,
compiling example):

```zig
const ml = geode.ml.graph_embeddings;

// Initialize embeddings manager with a config
var manager = try ml.GraphEmbeddingsManager.init(allocator, .{
    .dimensions = 64,
    .learning_rate = 0.01,
    .epochs = 50,
    .p = 1.0,
    .q = 1.0,
    .walk_length = 10,
    .num_walks = 20,
    .seed = 42, // deterministic runs
});
defer manager.deinit();

// Train embeddings for ALL nodes of a GraphStore (cross-tenant: requires
// Admin role when authentication is enabled)
try manager.trainEmbeddings(&store, .node2vec, null, .Admin);

// Inspect the real training-loss trend
const ctx = manager.training_context.?;
std.debug.assert(ctx.loss < ctx.initial_loss);

// Read an embedding
const emb = manager.getEmbedding(node_id).?;
```

### Similarity Search

```zig
// Find similar nodes by cosine similarity over stored embeddings
// (threshold is a minimum cosine similarity, k caps the result count)
var results = try manager.findSimilarNodes(target_node_id, 10, 0.5);
defer results.deinit(allocator);

// Pairwise cosine similarity via the stored vectors
const a = manager.getEmbedding(node1_id).?;
const b = manager.getEmbedding(node2_id).?;
const similarity = a.cosineSimilarity(b);
```

### Training Context

`trainEmbeddings` populates `manager.training_context`; the fields are
computed from the real training run, never simulated:

```zig
const ctx = manager.training_context.?; // after trainEmbeddings
_ = ctx.epoch;             // last completed epoch
_ = ctx.initial_loss;      // mean skip-gram pair loss of epoch 0
_ = ctx.loss;              // mean skip-gram pair loss of the final epoch
_ = ctx.learning_rate;     // decayed learning rate
_ = ctx.convergence_score; // |loss delta| between the last two epochs
```

## Similarity Metrics

### Cosine Similarity

Measures the cosine of the angle between two vectors:

```
similarity = (A · B) / (||A|| * ||B||)
```

- Range: [-1, 1] (typically [0, 1] for positive embeddings)
- Best for: Angular similarity, text embeddings, normalized features

### Euclidean Distance

Measures the straight-line distance between two points:

```
distance = sqrt(sum((A[i] - B[i])^2))
```

- Range: [0, ∞)
- Best for: Spatial relationships, magnitude-sensitive comparisons

### Dot Product

Measures the projection of one vector onto another:

```
similarity = sum(A[i] * B[i])
```

- Range: (-∞, ∞)
- Best for: Magnitude and direction sensitivity

## Performance Optimization

### Memory Management

- **Vector Pooling**: Reuse embedding vectors to reduce allocations
- **Batch Processing**: Process multiple nodes simultaneously
- **Lazy Loading**: Load embeddings on-demand for large graphs
- **Memory Monitoring**: Track memory usage and implement cleanup

### Computational Efficiency

- **Parallel Training**: Multi-threaded embedding generation
- **Vectorized Operations**: SIMD optimization for similarity calculations
- **Caching**: Cache frequently accessed embeddings
- **Progressive Training**: Incremental updates for dynamic graphs

### Scalability Features

- **Streaming Updates**: Handle real-time graph changes
- **Distributed Training**: Support for multi-node training (future)
- **Compression**: Embedding compression for storage efficiency
- **Approximation**: Fast approximate similarity search

## Integration Points

### Graph Database Integration

```zig
// Integration with Geode's graph storage
const graph_node = try graph_storage.getNode(node_id);
const neighbors = try graph_storage.getNeighbors(node_id);

// Use graph structure for embedding generation
try embeddings_manager.generateEmbedding(node_id, MLAlgorithm.node2vec);
```

### Query Integration

> NOT IMPLEMENTED: there is no `ml.similarity` / `ml.knn` GQL surface today.
> The examples below are a design sketch only (kept for future reference).

```gql
-- Example GQL queries with ML embeddings (DESIGN SKETCH — not implemented)
MATCH (n:Person)
WHERE ml.similarity(n.embedding, $target_embedding, 'cosine') > 0.8
RETURN n.name, ml.similarity(n.embedding, $target_embedding, 'cosine') AS similarity
ORDER BY similarity DESC

-- Find similar items using embeddings
MATCH (item:Product)
WITH ml.knn(item.embedding, $query_embedding, 10) AS similar_items
RETURN similar_items
```

### Index Integration

```zig
// Integration with vector indexes
const vector_index = try VectorIndex.init(allocator, embedding_dimension);
defer vector_index.deinit();

// Add embeddings to vector index for fast similarity search
for (embeddings) |node_id, embedding| {
    try vector_index.addVector(node_id, embedding);
}

// Fast approximate nearest neighbor search
const ann_results = try vector_index.search(query_embedding, k);
```

## Configuration Options

### Algorithm Configuration

```zig
pub const AlgorithmConfig = struct {
    learning_rate: f32 = 0.01,
    num_epochs: u32 = 50,
    batch_size: u32 = 32,

    // Node2Vec specific
    p: f32 = 1.0,
    q: f32 = 1.0,
    walk_length: u32 = 10,
    num_walks: u32 = 20,

    // GraphSAGE specific
    aggregation_function: []const u8 = "mean",
    num_samples: u32 = 5,
    inductive: bool = true,

    // DeepWalk specific
    window_size: u32 = 5,

    // Training control
    convergence_threshold: f32 = 0.001,
    early_stopping_patience: u32 = 10,
    learning_rate_decay: f32 = 0.95,
};
```

### Manager Configuration

```zig
pub const ManagerConfig = struct {
    embedding_dimension: u32 = 128,
    max_embeddings: u32 = 1000000,
    memory_limit_mb: u32 = 1024,
    enable_statistics: bool = true,
    enable_caching: bool = true,
    cache_size: u32 = 10000,
};
```

## Error Handling

### Common Error Types

```zig
pub const MLError = error{
    InvalidDimension,
    NodeNotFound,
    AlgorithmNotConfigured,
    InsufficientMemory,
    TrainingFailed,
    ConvergenceTimeout,
    InvalidConfiguration,
    EmbeddingNotFound,
    IncompatibleAlgorithm,
};
```

### Error Recovery Strategies

- **Graceful Degradation**: Fall back to simpler algorithms
- **Memory Management**: Free resources on OOM errors
- **Retry Logic**: Retry failed operations with adjusted parameters
- **Logging**: Comprehensive error logging for debugging

## Testing Framework

Regression tests run via `zig build test-gap0879`:

`tests/test_ml_graph_embeddings_integration.zig` (drives the real
`GraphEmbeddingsManager` against a real `GraphStore`):

- Node2Vec return-parameter bias: walks with small `p` return to the previous
  node far more often than walks with large `p` (K4, deterministic seed)
- Node2Vec in-out-parameter bias: walks with small `q` step outward to
  distance-2 nodes far more often than walks with large `q` (5-cycle)
- Real training loss: finite, non-negative, and strictly decreasing from
  epoch 0 to the final epoch on a two-triangle graph
- Deterministic seeding: identical `config.seed` reproduces identical
  embeddings and loss trajectory

In-module tests in `src/ml/integration_enhanced.zig` (same build step):

- `GraphData.getNeighbors` caller-owned allocation contract
- `RandomWalker` p/q transition bias
- Node2Vec / PageRank / Louvain smoke tests on tiny graphs

> The previous version of the integration test file SIMULATED decreasing
> training loss with fabricated numbers and ignored the p/q parameters in its
> walk helper; it also targeted an API that never existed and was not wired
> into any build step. It was replaced wholesale (GAP-0879).

## Performance

No published throughput numbers: earlier revisions of this document quoted
nodes/second figures with no referenced benchmark run, and they were removed
(GAP-0879). There is currently no benchmark harness for this experimental
module; if you need numbers, write a `benchmarks/`-style VarianceEnvelope
benchmark (see `benchmarks/benchmark_fts_storage.zig` for the house pattern)
and cite the run.

### Memory Usage (arithmetic, not measured)

- **Per Embedding**: `dimensions × 4` bytes (f32), e.g. 128-dim = 512 bytes
- **1M Embeddings**: ~512MB + hash-map overhead

### Search Complexity

- **Brute Force similarity search** (`findSimilarNodes`): O(n) over stored embeddings

## Future Enhancements

### Planned Features

- **Graph Attention Networks (GAT)**: Attention-based embedding generation
- **Heterogeneous Graphs**: Support for multiple node/edge types
- **Dynamic Embeddings**: Real-time embedding updates
- **Federated Learning**: Distributed training across multiple instances

### Optimization Opportunities

- **GPU Acceleration**: CUDA support for large-scale training
- **Quantization**: Reduced precision embeddings for storage efficiency
- **Compression**: Advanced compression algorithms for embeddings
- **Incremental Training**: Efficient updates for graph changes

## Production Deployment

### Monitoring

- **Training Metrics**: Loss, convergence rate, memory usage
- **Query Performance**: Similarity search latency, throughput
- **Resource Utilization**: CPU, memory, disk usage
- **Error Rates**: Failed training jobs, OOM errors

### Scaling Considerations

- **Horizontal Scaling**: Multiple embedding managers
- **Vertical Scaling**: Memory and CPU optimization
- **Storage Scaling**: Persistent embedding storage
- **Network Scaling**: Distributed similarity search

### Maintenance

- **Model Updates**: Retraining schedules and versioning
- **Performance Tuning**: Algorithm parameter optimization
- **Capacity Planning**: Growth projections and resource allocation
- **Backup and Recovery**: Embedding backup strategies

## API Reference

Actual exported surface of `src/ml/graph_embeddings.zig`
(`geode.ml.graph_embeddings`):

```zig
// Manager lifecycle
pub fn init(allocator: Allocator, config: EmbeddingConfig) !GraphEmbeddingsManager
pub fn deinit(self: *GraphEmbeddingsManager) void

// Training (cross-tenant: requires Admin when auth is enabled)
pub fn trainEmbeddings(self: *GraphEmbeddingsManager, graph: *const GraphStore, algorithm: MLAlgorithm, custom_config: ?EmbeddingConfig, caller_role: ?Role) !void

// Prediction / updates
pub fn predictEmbedding(self: *GraphEmbeddingsManager, node_id: u64, algorithm: MLAlgorithm) ![]f32
pub fn updateEmbedding(self: *GraphEmbeddingsManager, node_id: u64, new_embedding: []const f32) !void

// Lookup / search
pub fn getEmbedding(self: *const GraphEmbeddingsManager, node_id: u64) ?*const EmbeddingVector
pub fn findSimilarNodes(self: *const GraphEmbeddingsManager, node_id: u64, k: u32, similarity_threshold: f64) !ArrayList(...)
pub fn getStatistics(self: *const GraphEmbeddingsManager) EmbeddingStatistics

// Walks (exposed for verification/experimentation)
pub const RandomWalk = struct { ... pub fn transitionProbability(...) f64 ... };
pub fn generateRandomWalk(walk: *RandomWalk, graph: *const GraphStore, walk_length: u32, rng: std.Random) !void
```

## Conclusion

The ML Graph Embeddings system is an EXPERIMENTAL foundation for embedding
workflows in Geode. The Node2Vec walk bias, deterministic seeding, and
per-epoch loss reporting are real and regression-tested; the skip-gram update
and GraphSAGE aggregation are simplified variants. Validate quality on your
own data before relying on the embeddings for anything user-facing.
