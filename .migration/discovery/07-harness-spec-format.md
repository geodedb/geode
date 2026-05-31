# harness:spec-format

## summary

FINAL CORRECTED REPORT (supersedes both prior outputs). Grounded in full reads of lib/spec.py (575 lines), lib/checks.py, lib/executor.py, the Makefile test targets, and 7 representative spec files. One earlier claim is now corrected: the YAML key `values:` is also NOT parsed (the spec.py/checks.py "values" hits were the English word in a comment + a Python `.values()` method, not the spec key). So `expect.values`, `expect.row_count`, `expect.geode_query{row_count,columns}`, `status_class` (outside sequential steps), `message_contains`, `max_results`, `invariants`, and `validation` are ALL silently ignored by the current harness — verified by grep against spec.py and checks.py.

=== WHERE SPECS LIVE ===
/data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/ . Flat root holds ~233 .yml; subdirs: encryption/ (5), legacy/ (13 — older/archived format), future/ (2 — unsupported features), quic/ (3 .yaml). The runner discovers by directory glob (--specs <dir>), so subdirs are included. NEW FTS and timeseries specs go directly in the specs/ ROOT as new .yml files (NOT in legacy/). An FTS spec already exists (fulltext_search_basic.yml); NO timeseries spec exists — greenfield.

=== EXACT YAML SCHEMA (lib/spec.py) ===
TOP LEVEL — required: name (str), tests (list). Optional: description, version('1.0' is cosmetic/unparsed), mode (server|cli, default server; only those two valid), server_args[list], env{map}, default_timeout_ms, parallel_tests(bool), setup(list), teardown(list), pre_server(list), tde_config(map), plaintext_verification(map), secrets{name:{source:env|keyring,key,service,required,default}}, skip_server(bool legacy→cli), and the NEW cli: block { binary, server:{enabled,port,data_dir,startup_timeout_ms,cleanup,args,env}, client:{timeout_ms,tls_verify,format} } (cli.server.enabled overrides mode; cli.server.args overrides server_args; cli.server.env merges over env).
PER-TEST (TestCase) — required: name. type: cli|http|sequential|bash|shell (default cli). CLI input (one of): query:"<GQL>" | command:"<shell|geode...>" | args:[query,'-'] with stdin:"<GQL>". Other: env{}, dsn, timeout_ms, restart_server(bool), skip/skip_reason, plaintext_check{enabled,search_patterns,scan_paths,exclude_extensions,fail_on_violation}, and setup: either a list-of-dicts (per-test setup queries run+checked before the main command, e.g. setup:[{args:[query,"CREATE INDEX ..."],expect:{exit_code:0}}]) or {files:[{path,content}]}. http test: requests:[{method,url,headers,body,timeout_ms,expect:{status_code,content_type,body_contains,body_not_contains,body_regex,headers}}]. sequential test: steps:[{type:gql|http|wait, query|method/url/body, wait_ms, expect:{...}}] (only status_class substring is checked for gql steps). shell test runs command from GEODE_SOURCE_DIR; bash runs via bash -c.
EXPECTED BLOCK — key `expected:` OR `expect:` (both accepted). ONLY these are enforced (ExpectedResult + checks.py): exit_code(int|[int]); status(success|error, used only if exit_code absent); stdout_contains|contains([str|{k:v}]) — matches stdout OR stderr; output_contains (combined); stderr_contains; stdout_not_contains|not_contains; stderr_not_contains; stdout_regex|regex|matches([pat] vs stdout or stderr); stderr_regex; stdout_exact; stderr_exact; result_contains; result_not_contains; result_matches; error_contains. Top-level legacy aliases folded in: expected_exit_code, expected_stdout, expected_stderr, expected_output:{contains:[...]}, expected_output_contains, expected_output_pattern.

***CRITICAL: row_count, values, columns, geode_query, status_class(non-sequential), message_contains, max_results, invariants, validation are PARSED-AWAY/IGNORED. storage_persistence_basic.yml (expect.values/row_count) and geode_index_comprehensive.yml (expect.geode_query.row_count/columns) are effectively asserting ONLY exit_code. To actually assert query RESULTS in new specs, use stdout_contains / result_contains / stdout_regex against the JSON output (cli.client.format defaults to json).***

=== DATA SETUP + ASSERT ===
mode:server spawns one geode per spec; all tests share state. Setup mechanisms: (1) top-level setup: list of GQL/shell strings run once before tests; (2) per-test setup: list-of-dicts run+checked before that test; (3) earlier ordered CREATE tests then a later MATCH test asserting via stdout_contains. teardown: cleans up. The harness auto-builds the geode command and injects --server, -U geode -P ${GEODE_ADMIN_PASSWORD}, --insecure-tls-skip-verify, --timeout (executor_build_cli_command), so test bodies only need query:/args:+stdin:.

=== RUN A SINGLE SPEC ===
From harness root: `make test-spec SPEC=fulltext_search_basic.yml` (SPEC is relative to specs/; use SPEC=legacy/foo.yml for subdir). With OTel: `GEODE_OTEL=1 make test-spec SPEC=timeseries_basic.yml`. Direct: `cd geodetestlab-cli && source .venv/bin/activate && python -m geodetestlab run --spec specs/<file>.yml -v`. Whole dir: `python -m geodetestlab run --specs specs --parallel 4 [--transport grpc] -v`. Full suite: `make test-everything GEODE_BINARY=/path/to/geode`. Pattern: `make test-grep PATTERN=fts`. Set GEODE_ADMIN_PASSWORD if not default.

=== MINIMAL ANNOTATED EXAMPLE (copy for new FTS/timeseries specs) ===
name: Timeseries Basic Tests        # REQUIRED suite name
description: temporal range + aggregation
cli:                                 # NEW-format server/client block (preferred)
  binary: ./zig-out/bin/geode
  server: {enabled: true, startup_timeout_ms: 60000, cleanup: true, args: [--log-level, warn], env: {GEODE_ALLOW_TEST_AUDIT_KEYS: '1'}}
  client: {timeout_ms: 30000, tls_verify: false, format: json}
tests:

- name: ts-setup                     # setup step: CREATE timestamped data
  args: [query, '-']
  stdin: "CREATE (:Reading {ts: DATETIME('2026-01-01T00:00:00Z'), v: 10}), (:Reading {ts: DATETIME('2026-01-02T00:00:00Z'), v: 20}) RETURN count(*) AS created"
  expect: {exit_code: 0, stdout_contains: [created]}
- name: ts-range-scan                # assertion: temporal predicate
  args: [query, '-']
  stdin: "MATCH (r:Reading) WHERE r.ts > DATETIME('2026-01-01T12:00:00Z') RETURN r.v AS v"
  expect: {exit_code: 0, stdout_contains: ['20']}   # assert the VALUE in JSON output
- name: ts-aggregate                 # assertion: aggregation
  args: [query, '-']
  stdin: "MATCH (r:Reading) RETURN avg(r.v) AS mean"
  expect: {exit_code: 0, stdout_contains: [mean]}
tags: [timeseries, temporal]

## perf_notes

Functional specs have no latency gates; correctness is exit_code + stdout/result substring/regex assertions. For perf the harness uses a separate Go loadtest path (make loadtest-go / make loadtest-compare vs benchmarks/loadtest/baseline.jsonl in the geode repo). Inside functional specs you can run PROFILE/EXPLAIN (geode_index_comprehensive.yml) and assert plan text via stdout_contains. Any spec run can be observed with GEODE_OTEL=1 make test-spec SPEC=... (or make test-everything-otel) → reports/spans.jsonl with geode.query.*/geode.index.*/wal.* spans."}
<parameter name="api">[{"signature": "make test-spec SPEC=<file>.yml   (harness root; SPEC relative to geodetestlab-cli/specs/, e.g. SPEC=legacy/foo.yml)", "purpose": "Run one spec with -v. Prepend GEODE_OTEL=1 for span/metric capture."}, {"signature": "python -m geodetestlab run --spec specs/<file>.yml -v   (in geodetestlab-cli/ with .venv active)", "purpose": "Direct single-spec run."}, {"signature": "python -m geodetestlab run --specs specs --parallel <N> [--transport quic|grpc] -v", "purpose": "Run all specs (incl. subdirs) with N workers / transport."}, {"signature": "make test-grep PATTERN=<substr>   /   make test-everything GEODE_BINARY=/path/to/geode", "purpose": "Run specs matching a name pattern / full suite (unit+integration+shell+load)."}, {"signature": "TestSpec: {name(req), tests(req,list), description?, mode:server|cli=server, server_args?, env?, setup?, teardown?, pre_server?, default_timeout_ms?, parallel_tests?, secrets?, plaintext_verification?, tde_config?, cli:{binary,server:{enabled,args,env,startup_timeout_ms,cleanup,port,data_dir},client:{format,timeout_ms,tls_verify}}?}", "purpose": "Top-level spec schema (lib/spec.py TestSpec)."}, {"signature": "TestCase: {name(req), type:cli|http|sequential|bash|shell=cli, query|command|args+stdin(one req for cli), env?, dsn?, timeout_ms?, restart_server?, setup?(list-of-dicts | {files}), skip?/skip_reason?, plaintext_check?, expect|expected:{...}}", "purpose": "Per-test schema (lib/spec.py TestCase)."}, {"signature": "expect/expected: {exit_code:int|[int], status:success|error, stdout_contains|contains:[str|{k:v}], output_contains, stderr_contains, stdout_not_contains|not_contains, stderr_not_contains, stdout_regex|regex|matches:[pat], stderr_regex, stdout_exact, stderr_exact, result_contains, result_not_contains, result_matches, error_contains}", "purpose": "ONLY enforced assertion keys. row_count/values/columns/geode_query/status_class/message_contains/max_results/invariants are NOT enforced."}, {"signature": "${KEY} ${env:KEY} ${secret:KEY} ${data_dir}", "purpose": "Variable interpolation in command/url/stdin/args (executor._substitute_one); harness also auto-injects -U geode -P ${GEODE_ADMIN_PASSWORD} and --server."}]

## files

- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/geodetestlab/lib/spec.py — **role**: AUTHORITATIVE schema. ExpectedResult (153-218) = only enforced expect keys; TestCase (245-395) = per-test keys incl. setup list-of-dicts vs {files}; TestSpec (420-489) = top-level keys + cli: block handling (453-472); load_spec (492-575) = required-field validation (name, tests, mode in {server,cli}).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/geodetestlab/lib/checks.py — **role**: Enforcement. check_expectations() (211) runs exit_code,status,result_*,error_contains,stdout/output/stderr_contains/not/regex/exact. Proves row_count/values/columns/geode_query are never checked. check_http_expectations() (251).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/geodetestlab/lib/executor.py — **role**: Execution. run_cli_test (659) runs setup_files+setup_queries then _build_cli_command (381) which auto-injects --server/-U geode -P ${GEODE_ADMIN_PASSWORD}/--insecure-tls-skip-verify/--timeout. _run_sequential_test (923) is the ONLY honorer of status_class (1004). _substitute_one (1051): ${KEY} ${env:KEY} ${secret:KEY} ${data_dir}.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/fulltext_search_basic.yml — **role**: EXISTING active FTS spec — canonical template. cli: block + args:[query,'-']+stdin idiom + expect.exit_code/stdout_contains + tags. Tests CONTAINS predicate on Document nodes.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/geode_index_comprehensive.yml — **role**: Best index/storage DDL example: CREATE INDEX ... USING HNSW|RTree|IntervalTree|network_cidr|JsonbInverted|DomainTrie (WITH (...)), per-test setup: blocks, DROP INDEX, PROFILE/EXPLAIN. CAUTION: its expect.geode_query{} assertions are no-ops (only exit_code fires).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/storage_persistence_basic.yml — **role**: Storage template: top-level setup:/teardown: GQL, multi-statement query: with USE GRAPH, ordered setup→assert. CAUTION: its expect.row_count/values are no-ops — example of what NOT to rely on.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/advanced_types_basic.yml — **role**: TEMPORAL template. temporal-date/datetime/duration tests: DATE('2025-01-15'), current_timestamp(), DURATION('P1D') asserted via stdout_contains. Closest analog for a timeseries spec's timestamp/value setup.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/legacy/geode_fulltext_bm25_comprehensive.yml — **role**: Comprehensive (legacy) FTS reference: CREATE INDEX ... USING fulltext_simple|fulltext_standard|fulltext_english; fulltext_search(prop,terms,analyzer); CALL index.statistics(...); DROP INDEX. OLD steps/status_class/message_contains format — port the GQL into the modern expect.stdout_contains form for a new root spec.
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/legacy/geode_fts_bm25_optimization.yml — **role**: Second legacy FTS spec — BM25 query-plan/optimization angle (FTS + EXPLAIN/PROFILE).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/Makefile — **role**: Run targets: test-spec (386, SPEC relative to specs/), test (375), test-verbose (381), test-grep PATTERN= (397), test-quic/test-grpc/test-all-transports (490-509), test-everything (446→scripts/run_all_tests.sh), test-everything-otel (481).
- **path**: /data/home/benji/src/gl/gitlab.com/devnw/codepros/geode/geode-test-harness/geodetestlab-cli/specs/auto_index_id.yml — **role**: Smallest clean index skeleton: SHOW INDEXES + CREATE INDEX IF NOT EXISTS + query-by-id with stdout_contains/result_contains.

## integration_points

- **location**: geodetestlab-cli/specs/fts_<feature>.yml (new files in specs/ ROOT) — **note**: WHERE NEW FTS SPECS GO. Copy fulltext_search_basic.yml as skeleton. For BM25/index coverage port GQL from legacy/geode_fulltext_bm25_comprehensive.yml (CREATE INDEX ... USING fulltext_standard; fulltext_search(prop,'terms','analyzer'); CALL index.statistics; DROP INDEX) but rewrite assertions to expect.stdout_contains/result_contains (NOT status_class/message_contains). Run: make test-spec SPEC=fts_<feature>.yml
- **location**: geodetestlab-cli/specs/timeseries_<feature>.yml (new files in specs/ ROOT) — **note**: WHERE NEW TIMESERIES SPECS GO — greenfield. Use advanced_types_basic.yml temporal-* tests as type template. Setup CREATE nodes with a DATETIME/timestamp + numeric value prop, then assert temporal-range MATCH ... WHERE n.ts > DATETIME(...) and aggregation (count/avg/sum/min/max, GROUP BY via WITH) using expect.stdout_contains against JSON output. Run: make test-spec SPEC=timeseries_<feature>.yml
- **location**: geodetestlab-cli/geodetestlab/lib/spec.py:153-218 (ExpectedResult) — **note**: DEFINITIVE enforced-assertion-key list. row_count/values/columns/geode_query/status_class/message_contains/max_results/invariants are dropped (no error, no enforcement). Assert results via stdout_contains/result_contains/stdout_regex on the JSON client output.
- **location**: geodetestlab-cli/geodetestlab/lib/executor.py:381-537 (_build_cli_command) — **note**: Shows the exact CLI built for query:/command:/args: — auto-adds --server, -U geode -P ${GEODE_ADMIN_PASSWORD}, --insecure-tls-skip-verify, --timeout. New spec tests need only query: or args:[query,'-']+stdin:; don't hand-write auth/server flags.
- **location**: geodetestlab-cli/specs/geode_index_comprehensive.yml:94-167,231-235,357-461 (CREATE INDEX ... USING <type> [WITH (...)]) — **note**: Reference for the real index DDL grammar geode accepts. For FTS use USING fulltext_* (legacy spec); confirm exact analyzer/index names against the geode repo GQL grammar before pinning into a new spec.

## tests

- geodetestlab-cli/specs/fulltext_search_basic.yml (active FTS)
- geodetestlab-cli/specs/legacy/geode_fulltext_bm25_comprehensive.yml (legacy BM25/full-text)
- geodetestlab-cli/specs/legacy/geode_fts_bm25_optimization.yml (legacy FTS optimization)
- geodetestlab-cli/specs/issue_475_icontains_case_insensitive.yml (ICONTAINS predicate)
- geodetestlab-cli/specs/where_clause_operators.yml (CONTAINS/STARTS WITH/ENDS WITH text ops)
- geodetestlab-cli/specs/advanced_types_basic.yml (DATE/DATETIME/DURATION temporal types)
- geodetestlab-cli/specs/geode_advanced_data_types.yml (temporal/duration/interval coverage)
- geodetestlab-cli/specs/cast_type_keywords.yml (temporal CAST keywords)
- geodetestlab-cli/specs/order_by_sorting_comprehensive.yml (ORDER BY over results)
- geodetestlab-cli/specs/gql_expressions_comprehensive.yml, gql_query_comprehensive.yml, geode_functions_comprehensive.yml (aggregation count/avg/sum/min/max, GROUP BY/WITH — analytics surface)
- geodetestlab-cli/specs/geode_index_comprehensive.yml, geode_advanced_index_lifecycle.yml, auto_index_id.yml (index DDL/lifecycle)
- geodetestlab-cli/specs/storage_persistence_basic.yml, storage_restart_persistence.yml, per_graph_storage.yml (storage)
- NO timeseries-specific spec exists — new ground

## risks

- MAJOR/VERIFIED: expect keys row_count, values, columns, geode_query, status_class (outside sequential steps), message_contains, max_results, invariants, validation are NOT parsed by lib/spec.py and are silently ignored (grep-confirmed). storage_persistence_basic.yml and geode_index_comprehensive.yml are effectively only asserting exit_code. New FTS/timeseries specs copying those patterns get false confidence — use stdout_contains/result_contains/stdout_regex instead.
- legacy/ specs use an OLDER format (steps/status_class/message_contains/setup.server_mode) largely unenforced now — do not copy verbatim; port only GQL into modern expect.stdout_contains and place new files in specs/ ROOT.
- stdout_contains matches against BOTH stdout and stderr (checks.py:108-122), so an error message containing your substring can mask a failure — assert specific returned values, not generic column headers.
- Harness auto-injects -U geode -P ${GEODE_ADMIN_PASSWORD}; wrong/unset password fails the geode command before the query runs. Set GEODE_ADMIN_PASSWORD for runs.
- FTS analyzer/index DDL names in legacy specs may be stale vs current geode grammar — unverified.

## open_questions

- Does the current geode build still accept the legacy FTS surface (CREATE INDEX ... USING fulltext_standard; fulltext_search(prop,terms,analyzer); CALL index.statistics)? Verify against the geode GQL grammar / a live `geode query` before authoring — the harness only checks exit_code + stdout substrings, so a query that errors-but-exits-0 or returns the asserted substring in an error could pass a weak assertion.
- Exact geode GQL for timeseries range + window/aggregation (is there a time_bucket/window function or just DATETIME comparison + GROUP BY/WITH?). advanced_types_basic.yml only proves DATE/DATETIME/DURATION literals parse, not range-scan or aggregation-over-time. Confirm in the geode repo.
- Confirm the JSON output shape geode emits (cli.client.format: json) so stdout_contains/stdout_regex substrings are stable across versions — since row_count/values are unenforced, substring assertions on the JSON are the only real result check.
