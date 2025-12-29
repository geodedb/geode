# ADR-001: Deferral of Advanced Grey Cardinal Metrics

## Status
Accepted

## Date
2025-12-29

## Context
The "Grey Cardinal" research specification outlines a composite centrality score including Temporal, Dominator, and Cut-based metrics.
However, during the Alpha implementation (v0.16), we identified that:
1.  The core metrics (PageRank, Eigenvector, Betweenness) provide 80% of the value for the initial use case (identifying hidden influencers).
2.  The advanced metrics (Temporal, Dominator) add significant complexity and performance risk requiring distinct indexing structures that are not yet stable.
3.  The project timeline requires a stable Alpha release immediately.

## Decision
We will **measure and stabilize** the Grey Cardinal Score (GCS) using the existing metrics (PageRank, Eigenvector, Betweenness, Closeness, Bridge/Leverage) for the v0.16 Alpha release.
We will **defer** the implementation of Temporal Centrality, Dominator Trees, and Cut/Flow metrics to the v0.17 milestone.

## Consequences
### Positive
-   Reduced risk of instability in the Alpha release.
-   Earlier delivery of the core GCS functionality.
-   Allows time to benchmark the baseline composite score before adding complexity.

### Negative
-   The GCS will not fully match the research paper in the Alpha release.
-   Users specifically needing temporal analysis will have to wait for v0.17.

## Compliance
This decision formally addresses GAP-003 in the GAP_REGISTER.md by acknowledging the deviation and scheduling it for a future release.
