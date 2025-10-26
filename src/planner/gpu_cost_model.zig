// CANARY: REQ=REQ-GQL-051; FEATURE="GPU Acceleration"; ASPECT=CostModel; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_051_GPUCostModel; OWNER=engine; UPDATED=2025-10-26

const std = @import("std");

/// GPU cost model for automatic dispatch decision
pub const GPUCostModel = struct {
    /// PCIe bandwidth (GB/s) - typical PCIe 3.0 x16
    pcie_bandwidth_gbps: f64 = 12.0,
    
    /// GPU compute throughput estimates (operations/sec)
    bfs_edges_per_sec: f64 = 500_000_000.0, // 500M edges/sec
    pagerank_nodes_per_iter_per_sec: f64 = 100_000_000.0, // 100M nodes/iter/sec
    setop_elements_per_sec: f64 = 1_000_000_000.0, // 1B elements/sec
    dijkstra_edges_per_sec: f64 = 200_000_000.0, // 200M edges/sec
    
    /// CPU baseline throughput (for comparison)
    cpu_bfs_edges_per_sec: f64 = 50_000_000.0, // 50M edges/sec
    cpu_pagerank_nodes_per_iter_per_sec: f64 = 10_000_000.0, // 10M nodes/iter/sec
    cpu_setop_elements_per_sec: f64 = 100_000_000.0, // 100M elements/sec
    cpu_dijkstra_edges_per_sec: f64 = 20_000_000.0, // 20M edges/sec
    
    /// Thresholds for GPU dispatch
    min_edges_for_bfs: usize = 1_000_000,
    min_nodes_for_pagerank: usize = 500_000,
    min_elements_for_setop: usize = 1_000_000,
    min_edges_for_dijkstra: usize = 100_000,
    
    /// Overhead constants
    gpu_setup_overhead_ms: f64 = 5.0, // Context creation, etc.
    transfer_setup_overhead_ms: f64 = 0.5, // Per transfer
    
    pub fn init() GPUCostModel {
        return .{};
    }
    
    /// Estimate transfer time for data size
    fn estimateTransferTime(self: GPUCostModel, bytes: usize) f64 {
        const gb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0 * 1024.0);
        return (gb / self.pcie_bandwidth_gbps) * 1000.0 + self.transfer_setup_overhead_ms;
    }
    
    /// Should use GPU for BFS?
    pub fn shouldUseGpuForBfs(self: GPUCostModel, num_edges: usize, input_bytes: usize, output_bytes: usize) bool {
        if (num_edges < self.min_edges_for_bfs) return false;
        
        // Estimate CPU time
        const cpu_ms = (@as(f64, @floatFromInt(num_edges)) / self.cpu_bfs_edges_per_sec) * 1000.0;
        
        // Estimate GPU time
        const transfer_ms = self.estimateTransferTime(input_bytes) + 
                          self.estimateTransferTime(output_bytes);
        const compute_ms = (@as(f64, @floatFromInt(num_edges)) / self.bfs_edges_per_sec) * 1000.0;
        const gpu_ms = self.gpu_setup_overhead_ms + transfer_ms + compute_ms;
        
        // Use GPU if speedup > 1.5x (conservative)
        return gpu_ms < (cpu_ms / 1.5);
    }
    
    /// Should use GPU for PageRank?
    pub fn shouldUseGpuForPageRank(
        self: GPUCostModel, 
        num_nodes: usize, 
        _: usize, // num_edges (unused, for API consistency)
        iterations: usize,
        input_bytes: usize,
    ) bool {
        if (num_nodes < self.min_nodes_for_pagerank) return false;
        
        // PageRank needs to process nodes × iterations
        const total_ops = num_nodes * iterations;
        
        // Estimate CPU time
        const cpu_ms = (@as(f64, @floatFromInt(total_ops)) / self.cpu_pagerank_nodes_per_iter_per_sec) * 1000.0;
        
        // Estimate GPU time
        const transfer_ms = self.estimateTransferTime(input_bytes) + 
                          self.estimateTransferTime(num_nodes * @sizeOf(f64));
        const compute_ms = (@as(f64, @floatFromInt(total_ops)) / self.pagerank_nodes_per_iter_per_sec) * 1000.0;
        const gpu_ms = self.gpu_setup_overhead_ms + transfer_ms + compute_ms;
        
        return gpu_ms < (cpu_ms / 1.5);
    }
    
    /// Should use GPU for set operations?
    pub fn shouldUseGpuForSetOp(
        self: GPUCostModel, 
        set_a_size: usize, 
        set_b_size: usize,
        operation: SetOperation,
    ) bool {
        const total_elements = set_a_size + set_b_size;
        if (total_elements < self.min_elements_for_setop) return false;
        
        // Estimate CPU time
        const cpu_ms = (@as(f64, @floatFromInt(total_elements)) / self.cpu_setop_elements_per_sec) * 1000.0;
        
        // Estimate GPU time
        const element_size = @sizeOf(u32); // Typical element size
        const input_bytes = total_elements * element_size;
        const output_bytes = switch (operation) {
            .union_distinct => total_elements * element_size, // Worst case
            .intersect => @min(set_a_size, set_b_size) * element_size,
        };
        
        const transfer_ms = self.estimateTransferTime(input_bytes) + 
                          self.estimateTransferTime(output_bytes);
        const compute_ms = (@as(f64, @floatFromInt(total_elements)) / self.setop_elements_per_sec) * 1000.0;
        const gpu_ms = self.gpu_setup_overhead_ms + transfer_ms + compute_ms;
        
        return gpu_ms < (cpu_ms / 1.5);
    }
    
    /// Should use GPU for shortest path?
    pub fn shouldUseGpuForShortestPath(
        self: GPUCostModel, 
        num_nodes: usize, 
        num_edges: usize,
        input_bytes: usize,
    ) bool {
        if (num_edges < self.min_edges_for_dijkstra) return false;
        
        // Dijkstra processes each edge multiple times (relaxation rounds)
        const estimated_rounds = @as(f64, @floatFromInt(num_nodes)) * 0.1; // ~10% of nodes
        const total_ops = @as(f64, @floatFromInt(num_edges)) * estimated_rounds;
        
        // Estimate CPU time
        const cpu_ms = (total_ops / self.cpu_dijkstra_edges_per_sec) * 1000.0;
        
        // Estimate GPU time
        const output_bytes = num_nodes * @sizeOf(f64); // Distance array
        const transfer_ms = self.estimateTransferTime(input_bytes) + 
                          self.estimateTransferTime(output_bytes);
        const compute_ms = (total_ops / self.dijkstra_edges_per_sec) * 1000.0;
        const gpu_ms = self.gpu_setup_overhead_ms + transfer_ms + compute_ms;
        
        return gpu_ms < (cpu_ms / 1.5);
    }
    
    /// Estimate expected speedup for reporting
    pub fn estimateSpeedup(
        self: GPUCostModel,
        operation: Operation,
        _: OperationParams, // params (unused, for future expansion)
    ) f64 {
        return switch (operation) {
            .bfs => self.bfs_edges_per_sec / self.cpu_bfs_edges_per_sec,
            .pagerank => self.pagerank_nodes_per_iter_per_sec / self.cpu_pagerank_nodes_per_iter_per_sec,
            .set_op => self.setop_elements_per_sec / self.cpu_setop_elements_per_sec,
            .shortest_path => self.dijkstra_edges_per_sec / self.cpu_dijkstra_edges_per_sec,
        };
    }
};

pub const SetOperation = enum {
    union_distinct,
    intersect,
};

pub const Operation = enum {
    bfs,
    pagerank,
    set_op,
    shortest_path,
};

pub const OperationParams = union(enum) {
    bfs: struct { num_edges: usize },
    pagerank: struct { num_nodes: usize, iterations: usize },
    set_op: struct { elements: usize },
    shortest_path: struct { num_edges: usize },
};

test "GPUCostModel should prefer GPU for large graphs" {
    const model = GPUCostModel.init();
    
    // Large BFS - should prefer GPU
    const large_edges = 10_000_000;
    const input_bytes = large_edges * 4;
    const output_bytes = 1_000_000 * 4;
    try std.testing.expect(model.shouldUseGpuForBfs(large_edges, input_bytes, output_bytes));
    
    // Small BFS - should prefer CPU
    const small_edges = 10_000;
    try std.testing.expect(!model.shouldUseGpuForBfs(small_edges, input_bytes, output_bytes));
}

test "GPUCostModel PageRank threshold" {
    const model = GPUCostModel.init();
    
    // Large PageRank - should prefer GPU
    const large_nodes = 1_000_000;
    const num_edges = large_nodes * 10;
    const iterations = 20;
    const input_bytes = num_edges * 8;
    try std.testing.expect(model.shouldUseGpuForPageRank(large_nodes, num_edges, iterations, input_bytes));
    
    // Small PageRank - should prefer CPU
    const small_nodes = 10_000;
    try std.testing.expect(!model.shouldUseGpuForPageRank(small_nodes, num_edges, iterations, input_bytes));
}

test "GPUCostModel SetOp threshold" {
    const model = GPUCostModel.init();
    
    // Large sets - should prefer GPU
    const large_set = 10_000_000;
    try std.testing.expect(model.shouldUseGpuForSetOp(large_set, large_set, .union_distinct));
    
    // Small sets - should prefer CPU
    const small_set = 10_000;
    try std.testing.expect(!model.shouldUseGpuForSetOp(small_set, small_set, .union_distinct));
}
