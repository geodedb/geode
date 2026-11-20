# GQL → Engine Crosswalk (Contract)

| GQL Construct           | Clauses            | Logical op(s)          | Physical(s)                | Rules & Notes                               |
| ----------------------- | ------------------ | ---------------------- | -------------------------- | ------------------------------------------- |
| MATCH (n:ℓ {…})         | 14.4, 16.3–16.11   | NodeScan/Filter        | NodeIndexScan / CSR        | Label/prop pushdown                         |
| (a)-[e:τ*1..k]->(b)     | 16.7, 16.11 (G060) | Expand / PathExpand    | CSR expand (no WCOJ: `src/planner/wcoj.zig` was never compiled and was removed, SONNY-6511)  | Quantifier legality; UA005/UA006 tie‑break  |
| OPTIONAL MATCH          | 14.4               | LeftOuterJoin(pattern) | Hash Join (LOJ), null‑safe | Rewrite predicates for null‑safety          |
| RETURN / GROUP BY       | 14.10, 14.12       | Project/Group          | Vectorized project/agg     | Early projection; grouping legality         |
| ORDER BY / LIMIT/OFFSET | 14.10, 16.18–16.19 | Order / Limit / Offset | Sort / Top‑k               | **No OFFSET pushdown without stable order** |
| UNION/EXCEPT/INTERSECT  | 14.2 (GQ0x)        | SetOp                  | Merge/Hash SetOps          | DISTINCT/ALL semantics per clause           |
| Parenthesized path      | 16.7 (G046–G051)   | PathExpand             | BFS/DFS/BiBFS    | WHERE in PPPE; non‑local preds gate         |

(See `query_engine.md` for full table and Zig POCs; these clauses are the contract.) :contentReference[oaicite:77]{index=77}
