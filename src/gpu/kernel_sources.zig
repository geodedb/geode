const bfs_kernel_source = "__kernel void bfs( __global const uint* row_offsets, __global const uint* col_indices, __global uint* distances, const uint num_nodes) { uint tid = get_global_id(0); if (tid >= num_nodes) return; }";
const pagerank_kernel_source = "__kernel void pagerank(...) { }";
const shortest_path_kernel_source = "__kernel void dijkstra(...) { }";
