const std = @import("std");

// BM25 Scoring Skeleton (flag gated - ADV_FTS)
// CANARY: REQ=REQ-GQL-FTS-001; FEATURE="BM25 skeleton"; ASPECT=SEARCH; STATUS=PARTIAL; TEST=tests/unit_bm25_skeleton.zig:1; OWNER=search; UPDATED=2025-09-26

pub const Params = struct {
    k1: f64 = 1.2,
    b: f64 = 0.75,
};

pub fn score(doc_tf: f64, doc_len: f64, avg_doc_len: f64, doc_freq: f64, total_docs: f64, params: Params) f64 {
    if (doc_tf == 0 or doc_len == 0 or avg_doc_len == 0 or doc_freq == 0) return 0;
    const idf = @log((total_docs - doc_freq + 0.5) / (doc_freq + 0.5));
    const norm = doc_tf * (params.k1 + 1) / (doc_tf + params.k1 * (1 - params.b + params.b * (doc_len / avg_doc_len)));
    return idf * norm;
}
