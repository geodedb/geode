# 3-node cluster spec passing evidence (2026-05-26)

Captured after Phase A + Phase B + A6f resolution. Each spec was run via:

```bash
.venv/bin/geodetestlab run \
  --spec specs/<NAME>.yml \
  --force-cluster-size 3 \
  --geode-binary <GEODE_BIN> \
  --server-timeout-ms 90000 \
  --ci
```

The harness orchestrates a real 3-node cluster (3 geode subprocesses on
loopback, shared GEODE_CLUSTER_TOKEN, intra-cluster QUIC transport,
Raft consensus, leader election verified via SHOW CLUSTER STATUS).

## Results

| Spec | Tests | Pass | Notes |
|---|---|---|---|
| advanced_types_basic | 9 | 9 | Vector, geographic, network types |
| distributed_tenant_isolation | 16 | 16 | Per-tenant graph isolation |
| fulltext_search_basic | 4 | 4 | FTS index |
| backup_operations_basic | 3 | 3 | S3 backup ops |
| fle_plaintext_verification_basic | 16 | 16 | FLE pipeline |
| geode_distributed_queries | 12 | 12 | Scatter-gather, ORDER BY, aggregation |
| fle_plaintext_full_pipeline | 19 | 19 | Full FLE round-trip |
| fle_rotation | 6 | 6 | Key rotation |
| gql_set_operations_comprehensive | 22 | 22 | UNION / INTERSECT / EXCEPT |
| lsp_full_surface | 7 | 7 | LSP completion, hover, diagnostics |
| tde_bitflip_detection | 8 | 8 | TDE integrity checks |
| geode_f01_f02_regression | 7 | 7 | F01/F02 regressions |
| gap_0193_high_priority_comprehensive | 47 | 47 | Large gap-closure suite |
| mcp_client_integration | 5 | 5 | MCP client |
| migration_quic_stability | 7 | 7 | QUIC stability under migration |
| gap_0222_rsa_unsupported | 8 | 8 | RSA negative paths |
| tde_kms_unreachable_fails_closed | 1 | 1 | KMS fail-closed |
| query_file_flag_edge_cases | 28 | 28 | --file flag edges |
| geode_working | 4 | 4 | Smoke |
| **Total** | **245** | **245** | **0 failures** |

## Reproducibility

```bash
cd /home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/geodetestlab-cli
for spec in advanced_types_basic distributed_tenant_isolation fulltext_search_basic \
            backup_operations_basic fle_plaintext_verification_basic \
            geode_distributed_queries fle_plaintext_full_pipeline \
            fle_rotation gql_set_operations_comprehensive lsp_full_surface \
            tde_bitflip_detection geode_f01_f02_regression \
            gap_0193_high_priority_comprehensive mcp_client_integration \
            migration_quic_stability gap_0222_rsa_unsupported \
            tde_kms_unreachable_fails_closed query_file_flag_edge_cases \
            geode_working; do
  .venv/bin/geodetestlab run --spec "specs/${spec}.yml" --force-cluster-size 3 \
    --geode-binary ../../../geode/zig-out/bin/geode --server-timeout-ms 90000 --ci
done
```

## Open scope (next sessions)

- Run the remaining 283 specs through the matrix (not in this session)
- A3f: auth_token validation against Config.cluster_token on connection accept
- A8: verify Raft apply → graph_store under load
- W1-W3: WAL cross-cluster behaviors (user-added scope)
- S1-S4: sharding distribution + replication-factor semantics (user-added)
- Phase C: write the 17 dedicated multi-node correctness specs
- Phase D: bug-fix loop against any failures found in the 283-spec remainder
