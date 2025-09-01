# Geode CLI (gql)

Flags (subset):

- --ast | --ast-json | --ast-json-verbose
- --strict-order-keys | --ident-order-only | --forbid-orderby-calls | --forbid-orderby-paths
- --normalize-temporals | --clamp-frac <0-9> | --session-offset <Z|+HH[:MM]|-HH[:MM]>
- Demos:
  - --demo-sort: Sorts sample temporal rows using first ORDER BY key in the query file.
  - --demo-setops: Shows UNION/INTERSECT/EXCEPT ALL/DISTINCT semantics over sample rows.
  - --bench-setops: Micro-benchmark for UNION DISTINCT thresholded path.
  - --bench-eval: Micro-benchmarks for regex (=~) and IN/NOT IN evaluation.
  - --demo-eval: Evaluates WHERE and RETURN on a small synthetic rowset with identifiers a (Int) and s (Str).
  - --demo-diagnostics: Runs the planner and prints diagnostic codes for certain legality errors.

Examples

- gql --ast examples/q1.gql
- gql --session-offset +02 --demo-sort examples/order_by_temporal.gql
- gql --demo-eval examples/eval_where_return.gql
- gql --demo-diagnostics examples/offset_without_order.gql

Demo: evaluator recipes

- Basic WHERE and RETURN with identifiers a (Int) and s (Str):
  - Query: MATCH (n) WHERE s STARTS WITH "A" AND a = "42" RETURN CASE WHEN a IN ["41", "42"] THEN s ELSE "x" END
  - Run: gql --demo-eval examples/eval_where_return.gql
- IN and NOT IN with NULL semantics:
  - Query: MATCH (n) WHERE a NOT IN [1, null, 3] RETURN n
  - Note: If any NULL is present and there is no match, the result is NULL (unknown) for NOT IN.
- Mixed-type equality policy:
  - Eq/Ne across Int and Str compare decimal string forms (e.g., 7 = "7" is true; 7 = "007" is false). Ordering across Int/Str is not allowed.

## Policies

- Equality casting
  - Int vs Str: compare decimal forms
    - 7 = "7" → true
    - 7 = "007" → false
  - Int vs Str ordering (<, <=, >, >=): illegal (TypeMismatch)
- NULL behavior
  - IN: value NULL → NULL; list contains NULL and no match → NULL; match present → true
  - NOT IN: logical negation of IN when boolean; NULL stays NULL

## Troubleshooting

- TypeMismatch: shown when ordering compares incompatible types (e.g., Int vs Str). In CLI diagnostics, this may be surfaced as a parser/planner policy violation if applicable; otherwise reported as a runtime/evaluator error.
- Illegal ORDER BY key: enable flags to control strictness:
  - --strict-order-keys, --ident-order-only, --forbid-orderby-calls, --forbid-orderby-paths
    The CLI maps these to the IllegalOrderKey diagnostic when violated.
