// === MULTI-LOOP SETUP (pseudocode) ===
//
// const N = cpu_count();
// for i in 0..N-1 {
//    spawn loopThread(i) { bind_udp_reuseport(port); set_affinity(i); run mainLoop(); }
// }
// Each loop holds its own connection hash map (5-tuple,CID)->ConnCtx; no global state on hot path.
// NIC RSS distributes UDP packets to queues matching reuseport sockets; locality preserved.
//
// Windows variant: one socket + IOCP with concurrency=N; partition connections by CID hash;
// ensure events for a connection are handled by its designated worker (no concurrent mutation).