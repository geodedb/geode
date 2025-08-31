# GQL front-end conformance matrix (quick scan)

Legend: D = Done (parse/AST/print); P = Parse-only; N = Not yet; Pol = Policy documented

| Area                        | Clause(s)          | Feature                                                         | Status | Evidence                                                                     |
| --------------------------- | ------------------ | --------------------------------------------------------------- | ------ | ---------------------------------------------------------------------------- |
| Result + ORDER & page       | 14.10; 16.18–16.19 | RETURN, ORDER BY, LIMIT/OFFSET                                  | D/Pol  | `parser.zig:parseQuery`; `print.zig`; policy tests in `src/planner.zig`      |
| ORDER BY key policy         | 14.10; 16.16–16.17 | Strict/idents-only/forbid calls; forbid path aliases            | D      | `parser.zig` flags; `isPathAlias`; CLI flags in `gql/main.zig`               |
| MATCH/OPTIONAL              | 14.4               | Node/rel patterns                                               | D      | `ast.zig` Node/Rel; `parser.zig:parseRelPattern`                             |
| Rel alternation/quantifiers | 22.4               | `:A\|B` `*` `k..m`                                              | D      | `parseRelPattern`; `printRel`                                                |
| Pattern comprehension       | —/20.x             | list over pattern with map expression; alias support            | D      | `Expr.PatternComp`; `parsePrimaryExpr`; printer                              |
| UNION                       | 14.12              | ALL/DISTINCT per tail                                           | D      | `Statement.Union` with `tails[]`                                             |
| GROUP BY                    | 14.10              | group keys parsed                                               | P      | `parseQuery: group_by`; printer                                              |
| INTERSECT/EXCEPT            | 14.12 Annex        | set ops                                                         | D      | tokens/lexer; `parseStatement`; tests in `src/gql.zig`                       |
| Expressions core            | 16.x               | arithmetic, IN, IS NULL                                         | D      | `parse*Expr`; tests in `src/gql.zig`                                         |
| String predicates           | 16.x               | STARTS/ENDS/CONTAINS                                            | D      | tokens/lexer, `parseCmpExpr`, printer                                        |
| Regex match                 | 16.x               | `=~`                                                            | D      | token `regex_match`, parser/printer                                          |
| CASE expression             | 16.x               | simple & searched                                               | D      | `Expr.Case`, parser/printer                                                  |
| Temporal literals           | 16.x               | DATE"yyyy-mm-dd", DATETIME"...", TIME"...", LOCAL DATETIME"..." | D      | tokens/lexer; `Expr.Date/DateTime/Time/LocalDateTime`; parser/printer; tests |
| Params, NULLS FIRST/LAST    | 16.x               | `$param`, nulls policy                                          | N      | —                                                                            |
| Aggregation semantics       | 14.10              | HAVING, scope checks                                            | N      | —                                                                            |
| Diagnostics + Flagger       | Annex/UA           | precedence, UA002                                               | N/Pol  | to be added per NEXT.md                                                      |

Notes:

- Scope is front-end only. Execution semantics for set ops/aggregation will be filled as the engine/planner evolves.
