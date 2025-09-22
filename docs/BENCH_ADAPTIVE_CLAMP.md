# Benchmark Schema: Adaptive Estimator Clamp Variance

// CANARY: REQ=REQ-GQL-075; FEATURE="Cost Model Enumeration Seed"; ASPECT=AdaptiveEstimatorBiasClampVarianceEnvelope; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_075_AdaptiveEstimatorBiasClampVarianceEnvelope; OWNER=planner; UPDATED=2025-09-22

## Purpose

Tracks saturation (clamp) streak dynamics for adaptive bias factors to detect instability or regression in estimator responsiveness.

## Workloads

- `stable`: Mild jitter with rare extremes; expected minimal clamp streak persistence.
- `volatile`: Structured bursts of low/high extremes; expected longer streaks.

## Output (JSON line)

Fields:

- `bench`: Identifier (fixed string).
- `stable_mean`: Mean clamp streak length (stable workload).
- `stable_cv`: Coefficient of variation for stable streak lengths.
- `volatile_mean`: Mean clamp streak length (volatile workload).
- `volatile_cv`: Coefficient of variation for volatile streak lengths.
- `stable_count`: Number of sampled streaks (stable).
- `volatile_count`: Number of sampled streaks (volatile).
- `stable_saturation_ratio`: Fraction of iterations with an active clamp (stable).
- `volatile_saturation_ratio`: Fraction of iterations with an active clamp (volatile).

## Current Thresholds

- Stable CV initial envelope: `<= 0.60` (to be ratcheted down after history collection).
- Responsiveness differentiation: `volatile_mean >= stable_mean`.

## Future Tightening Plan

1. Collect 20+ nightly samples.
2. Reduce stable CV target to `<= 0.45`; monitor flakes.
3. Reduce further to `<= 0.35` if zero unstable incidents over next 14 samples.
4. Introduce seeded stochastic jitter to avoid degenerate zero-CV cases.

## Rationale

Clamp streak metrics surface latent estimator rigidity (excessively long streaks) or oscillation (high variance). Maintaining low stable CV while ensuring volatile bursts yield longer streaks demonstrates adaptive sensitivity without runaway saturation.

## Example

```json
{
  "bench": "BenchmarkCANARY_REQ_GQL_075_AdaptiveEstimatorBiasClampVarianceEnvelope",
  "stable_mean": 1.0,
  "stable_cv": 0.0,
  "volatile_mean": 9.94,
  "volatile_cv": 0.055
}
```

## Failure Modes

- `StableClampVarianceExceeded`: Stable CV above envelope.
- `ClampResponsivenessNotDifferentiated`: Volatile mean not ≥ stable mean.

## Governance

Evidence recorded by `zig build test`. Use `scripts/capture_adaptive_clamp.sh` to append a timestamped result line to `benchmarks/history/adaptive_clamp.jsonl` for longitudinal analysis.
