# ADR-002: Memory Pooling Strategy

## Status
Accepted

## Context

GPU memory allocation is expensive:
- `cuMemAlloc` takes 100-1000+ microseconds
- Frequent allocations cause fragmentation
- Memory pressure leads to out-of-memory errors

Common patterns in GPU computing involve:
- Allocating similar-sized buffers repeatedly
- Temporary buffers for intermediate results
- Reusing buffers across kernel launches

We need a memory management strategy that reduces allocation overhead while being simple to use.

## Decision

Implement a buffer pooling system in the Memory manager.

### Design

```zig
pub const Memory = struct {
    device_pool: ArrayList(Buffer),  // Pooled buffers
    stats: MemoryStats,

    pub fn allocDevice(self: *Memory, size: usize) !Buffer {
        // 1. Align size
        const aligned_size = alignUp(size, 256);

        // 2. Check pool for reusable buffer
        for (self.device_pool.items) |*buf| {
            if (!buf.allocated and buf.size >= aligned_size) {
                buf.allocated = true;
                self.stats.pool_hits += 1;
                return buf.*;
            }
        }

        // 3. Allocate new buffer
        var dptr: CUdeviceptr = 0;
        try self.drv.memAlloc(&dptr, aligned_size);

        const buf = Buffer{ .ptr = dptr, .size = aligned_size, ... };
        try self.device_pool.append(buf);
        return buf;
    }

    pub fn freeDevice(self: *Memory, buf: Buffer) void {
        // Return to pool (mark as available)
        for (self.device_pool.items) |*pool_buf| {
            if (pool_buf.ptr == buf.ptr) {
                pool_buf.allocated = false;
                return;
            }
        }
    }
};
```

### Pool Management

Added in v0.3.0:
- `getPoolStats()`: Monitor fragmentation
- `defragment(threshold)`: Free small unused buffers
- `compact(keep_count)`: Keep only largest N free buffers
- `clearPool()`: Free all unused buffers

### Alignment

All allocations are aligned to 256 bytes:
- Matches CUDA's natural alignment
- Enables coalesced memory access
- Simplifies size matching in pool

## Consequences

### Positive

- **Reduced allocation overhead**: Pool hits are O(n) lookup vs GPU call
- **Reduced fragmentation**: Reusing buffers prevents fragmentation
- **Simple API**: Users call alloc/free, pooling is transparent
- **Monitoring**: Statistics help diagnose memory issues
- **Control**: Users can manage pool with defragment/compact

### Negative

- **Memory overhead**: Unused buffers remain allocated
- **Pool growth**: Without cleanup, pool can grow unbounded
- **Size mismatch**: Small requests may get larger buffers
- **Not thread-safe**: Each thread needs its own Memory instance

### Mitigation

- `clearPool()` for explicit cleanup
- `defragment()` for selective cleanup
- `compact()` for keeping useful buffers
- Document thread-safety requirements

## Alternatives Considered

### 1. No Pooling
Rejected: Allocation overhead too high for interactive workloads.

### 2. Fixed-Size Slab Allocator
Rejected: Too rigid for varying buffer sizes in real workloads.

### 3. CUDA Memory Pools (cuMemPool*)
Considered: Requires CUDA 11.2+, not available in older drivers.
May add as optional enhancement in future.

### 4. Per-Size-Class Pools
Rejected: Adds complexity without proportional benefit for our use cases.

## References

- [CUDA Best Practices: Memory Management](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/)
- [cuMemPool API](https://docs.nvidia.com/cuda/cuda-driver-api/group__CUDA__MEM__POOL.html)
