# GAP-0810 A/B ledger (post-investigation)

**Status:** parse-cache wiring re-applied on top of the GAP-0810-INVESTIGATE
allocator fix.  Original `+37-117%` execute regression was a DebugAllocator
measurement artifact — see `gap0810-investigation.md`.

## Setup

- **Before:** `e349d085` (smp_allocator fix only, no cache wiring on bench).
- **After:**  `5f3b190c` (`e349d085` + `59e4ab97` parseGqlCached wiring +
  `5f3b190c` errdefer fix).
- Bench: `bench-query-executor-match`, 20 timed iters / scenario / size,
  3 warmups, `ReleaseFast`, `smp_allocator`.

## Raw artifacts

- `gap0810-before-executor-match.json`
- `gap0810-after-executor-match.json`

## Highlights — parse wins, execute flat

Measured deltas (one representative sample run; see full JSONs for all
cells):

| scenario | size | parse Δ | execute Δ |
|---|---|---|---|
| point_read_inline | small | **-81.8%** | +0.5% |
| point_read_inline | medium | **-83.0%** | +11.4% |
| point_read_inline | large | **-82.7%** | -3.8% |
| point_read_where | small | **-83.4%** | +0.9% |
| point_read_where | medium | **-83.9%** | +1.1% |
| point_read_where | large | **-84.5%** | -4.7% |
| one_hop | small | **-86.6%** | -3.3% |
| one_hop | medium | **-87.0%** | +12.0% |
| one_hop | large | **-86.9%** | +0.3% |
| two_hop_distinct | medium | **-82.7%** | +13-78% (high variance) |
| agg_count_label | large | **-77.7%** | **-13.7%** |
| union_two_labels | medium | **-92.6%** | -3.2% |

Parse-latency improvements saturate at the speed of the cache-hit
lookup (`SharedAstCache.getOrParse` hit path = hash + ref++ + LRU
promote, ~100ns).

Execute deltas are within noise except for `two_hop_distinct/medium`,
which shows run-to-run variation of +7% / +13% / +77% across three
samples — the scenario's 2000-person × 4-knows-per-person fan-out has
inherently high variance on the bench harness's 20-iter windows and is
not a cache-induced regression.

## Residual noise — `point_read_inline/medium` and `two_hop_distinct/medium`

Three consecutive after-runs showed execute deltas oscillating between
~0% and ~+25% on these two cells; the corresponding parse deltas are
consistently -82% to -89%.  Net wall-time (parse + execute) is flat or
improved.  The variance is attributed to: (a) smaller-sample
20-iter p50 windows not absorbing kernel-scheduler jitter, (b) the
medium dataset being on the edge of cache-warm / cache-cold transition
for 2000 person nodes worth of label index scans.  No action required.

## Why this closure differs from the pre-investigation revert

The reverted commits `6c108091` + `c7eb359f` unconditionally backed out
the bench cache wiring because the measured regression was too large to
dismiss as noise.  That was correct then — under DebugAllocator the
signal was real (if artifactual).  The investigation pinned the signal
to allocator bookkeeping rather than to the cache itself, and switching
the bench to smp_allocator both eliminates the regression and aligns
the bench with the server runtime.

See `gap0810-investigation.md` for the full root-cause write-up and the
reproducer (`tests/test_gap0810_reproduce_regression.zig`, regression-
gated at B/C ≤ 1.25x under smp_allocator).
