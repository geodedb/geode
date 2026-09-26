# Changelog

## [Unreleased] - Time-Series Audit and Gap Closure

### Added

- **CANARY Governance Tokens:** 24 CANARY markers added across timeseries source files (GAP-0281)
- **Legacy GAP ID Mapping:** Documented mapping from Grey Cardinal GAP-004/005/006 to GAP-0279+ numbering (GAP-0288)
- **Time-Series Audit Report:** `docs/TIMESERIES_AUDIT_REPORT.md` tracking all timeseries gap status

### Fixed

- **Documentation Accuracy:** Updated MIGRATION_GUIDE.md to reflect partial server wiring status and list in-progress functions (GAP-0291)
- **SUM/FIRST/LAST Aggregations:** Added test coverage for missing aggregation types (GAP-0284)
- **valueAt/timeBucketAvg Edge Cases:** Added boundary and empty-input tests (GAP-0285)
- **Step/Nearest Interpolation:** Added tests for step and nearest interpolation methods (GAP-0286)

---

## [v0.8.23] - Unreleased

### Security

- **QUIC listener certificate auto-generation fails closed in production
  (SONNY-2394):** this covers `QuicTransport.listen`'s own auto-generation
  only. That path serves the listeners whose certificate is not prepared at
  startup: the intra-cluster (cluster and Raft) QUIC listeners and the
  remote-KMS server. Such a listener self-signs a missing certificate only in
  dev posture (Debug build, `GEODE_ENV` not `production`) or when explicitly
  enabled (`GEODE_TLS_AUTOGENERATE_CERT=1`, or the per-listener
  `cert_auto_generate = .always` transport config). In production posture
  (release build or `GEODE_ENV=production`) it refuses to start instead.
  Server startup is unchanged: `geode serve` without `--cert`/`--key` still
  generates a self-signed certificate at startup when none exists (in its data
  or certificate directory, or `/tmp` when that is not writable), in every
  posture.
- **Traversals apply RLS and tenant scope to every hop (SONNY-2679):** a
  relationship pattern now applies the session's graph, tenant scope and RLS
  policies to every node it reaches and every edge it walks, not only to the
  start node. This covers:
  - single hop, variable length, `count`/`collect` and GROUP BY over hop
    targets;
  - OPTIONAL MATCH and multi-hop patterns;
  - pattern comprehensions, `COUNT {}`, `EXISTS {}` and `shortestPath()`.

  Before, an RLS-denied or other-tenant hop target could be read, and so could
  every node and path reached only through it. A label-deny policy on a
  relationship type, and an expression policy on one, now hide those edges on
  every traversal.

  **Behaviour change (SONNY-2693):** a tenant-scoped session sees an edge only
  when the edge's own tenant tag and both of its endpoints are visible to it,
  on every path. The single hop already did this. It is new for variable
  length, aggregation, grouping, OPTIONAL MATCH, the first hop of a multi-hop
  pattern, pattern comprehensions, `COUNT {}`, `EXISTS {}` and
  `shortestPath()`. Those paths followed any edge whose endpoints were
  visible, whatever its tag. So a tenant could read another tenant's edge
  between its own nodes, with its properties, and `COUNT {}`, `EXISTS {}` and
  `shortestPath()` showed that the edge existed. There is no exception for
  `default`: legacy edges tagged `default` between a tenant's own nodes
  (GAP-0891) are no longer followed. To re-tag them from their endpoints, an
  admin runs `CALL geode.tenant.backfill_edge_tags()`; pass `true` for a dry
  run. The procedure also lists every edge whose tags disagree in any other
  way, and leaves those edges unchanged.
- **Expression RLS policies apply to every label on a node (SONNY-2690):** a
  policy was looked up for a node's first label only, so a node whose policed
  label came second escaped it.
- **Expression-path graph scoping and nested post-filtering (SONNY-2687):**
  pattern comprehensions, `COUNT {}`, `EXISTS {}` and `shortestPath()` now read
  only the session's graph. The transport RLS post-filter now also finds a
  denied node or edge inside a list or a map, such as `collect(h)`.
- **RLS policy changes no longer race with queries (SONNY-2679 review):**
  creating or deleting an expression RLS policy changed the engine's policy
  map while queries on other connections read it; this covers
  `CALL geode.rls.add_attribute_policy` and the other policy procedures.
  That could crash the server. The map is now locked. A traversal now reads
  the label-deny policies once per statement, not once per edge. The
  transport RLS post-filter now stops searching at 64 levels of nested lists
  or maps, and drops a row nested deeper instead of passing it. The
  post-filter's label-deny snapshot, and the traversal's, now hold their own
  copy of each denied label. If a deny policy was removed while a query's
  post-filter ran, the post-filter could read freed memory.
- **A YIELD that names a column twice no longer crashes the server
  (SONNY-2755):** the YIELD filter of the procedures that honour YIELD
  (`algo.bfs.stream`, `algo.dfs.stream`, `algo.dijkstra.stream`,
  `geode.fts.*`, `geode.ts.*` and `geode.tenant.*`) put that column's name,
  and its values, in two columns. The result then freed them twice. A
  release build aborts on that double free, so any user allowed to call one
  of these procedures could stop the server, for example with
  `CALL algo.bfs.stream(1) YIELD path, path`.
  Such a YIELD is now refused with 42702 before the procedure runs, for
  every procedure. The filter also stopped leaking memory:
  - it frees the columns a YIELD drops;
  - it keeps the result's ownership of its values;
  - BFS, DFS and Dijkstra free their paths, and `geode.fts.rebuild` frees
    its index name, with or without a YIELD. These used to leak on every
    call.
- **An RLS policy from `geode-auth` no longer loads as a GPS policy
  (SONNY-2750):** GPS policies (`CREATE POLICY`) and RLS policies
  (`geode-auth policy create`, `geode auth policy create`) are stored as the
  same `:Policy` records in `__geode_security`. GPS loaded every record at
  startup as a GPS policy. An RLS `update` policy on any table therefore came
  back after a restart as "allow write on `default`, for everyone", which
  also passed the database-level write check.
  Policy records now carry a `kind` (`gps` or `rls`), covered by the record
  HMAC. GPS loads only GPS records. It refuses any other record, and any GPS
  record with a missing or mistyped property. For each refusal it logs a
  warning and writes a `REFUSE_POLICY_RECORD` audit event.
  A record written before this release has no kind. GPS loads one only if it
  has the properties GPS wrote. Its HMAC is unchanged, so an existing chain
  still verifies.
  `geode auth policy list`, `show` and `delete` see only RLS records. See
  `docs/security/gps-policy-ddl.md`.
- **Writes after `USE GRAPH` lock the graph they write (SONNY-2749):** the
  QUIC and gRPC handlers took the write lock of the session's graph as it
  was before the request. A request such as `USE GRAPH g2; MERGE (:K {id: 1})`
  therefore wrote `g2` while holding the other graph's lock. Two such
  requests at once could create the node twice, or corrupt `g2`'s label
  dictionary. gRPC always locked `default`, because it did not track the
  session's graph.
  The lock is now taken on the graph that the request's statements run on,
  after the request's own `USE GRAPH`, `SESSION SET GRAPH` or `SESSION RESET`.
  A request that changes data on more than one graph is refused with 0A000;
  send one request per graph. This includes `CREATE GRAPH g; USE GRAPH g;
  CREATE …`, which must now be two requests.
  A request that changes a graph that does not exist is refused with 3F000,
  and the graph is not created. The CLI's `-g` flag, which sends a
  `USE GRAPH` of the current graph before the query, works as before.
- **A session's transaction is its own (SONNY-2799, SONNY-2805):**
  - **A failed statement rolls back its own transaction.** A statement that
    fails inside a transaction fails it (GAP-0917). The executor rolled it
    back on the spot, under the request's lock (a read lock, or a read
    snapshot the undo went into, or another graph's lock), while the handler
    still thought it open. The session's ROLLBACK then ran with no
    transaction, and the undo log took transaction 0 to mean every entry:
    it undid other sessions' uncommitted changes, which those sessions then
    "committed". Now the handler rolls a failed transaction back itself,
    under the write lock of the graph it changed, once the request's lock
    is released. The transaction is then over, and a ROLLBACK finds none.
  - **The undo log never matches every entry.** Changes are recorded only
    for a thread in a transaction, and a thread with none rolls back
    nothing. Savepoints belong to their transaction: ROLLBACK TO undoes that
    transaction's later changes only, and another transaction's BEGIN or
    COMMIT no longer drops them.
  - **A transaction follows its session.** The handlers put the session's
    transaction on whichever thread serves a request, and take it back
    after. gRPC served a session's requests on any worker thread, so a
    change could be recorded under another session's transaction, or none,
    and one session's ROLLBACK could undo another session's autocommit
    write. The transaction id BEGIN returns is the undo log's.
  - **Transaction control runs in program order.** After
    `COMMIT; START TRANSACTION; ...` in one request, the handler had no
    transaction and the executor had begun one. A change of another graph
    then escaped the one-graph rule, the client's ROLLBACK did nothing,
    and the undo entries stayed. The fast paths that run only a request's
    last query no longer take a request with transaction control.
  - **COMMIT and ROLLBACK run on the transaction's graph.** A request that
    ends a transaction runs under the write lock of the graph the
    transaction changed. A ROLLBACK statement ran under the request's lock:
    a read lock, or a read snapshot. A request that also touches another
    graph's data is refused (0A000): send it on its own.
  - **`START TRANSACTION { ... }` commits or rolls back its body.** Its undo
    transaction was never ended.
  - QUIC's per-graph audit logger now takes the graph a request ran on. It
    used the session's graph as of the previous request.
- **Graph DDL needs the schema permission on its graph (SONNY-2803):** the
  only gate for CREATE GRAPH, DROP GRAPH and index and constraint DDL was the
  database-level write permission. So a ReadWrite user refused
  `USE GRAPH g1` (strict tenancy) could `DROP GRAPH g1`, and ReadWrite, which
  has no Schema permission, could create and drop any graph, index or
  constraint.
  - Each of these statements now needs `decide(schema)` and bind_graph on
    the graph it changes:
    - CREATE GRAPH and DROP GRAPH: the named graph;
    - CREATE INDEX and CREATE or DROP CONSTRAINT: the session's graph;
    - a fulltext CREATE INDEX, and every DROP INDEX: the default graph, the
      graph they lock (SONNY-2790).
  - The permission is checked before existence, so a caller refused gets
    42501 whether or not the graph or index exists.
  - Schema is Admin's builtin permission. A GPS policy `FOR SCHEMA` on a
    graph (or on `*`) grants it there.
  - ReadWrite users can no longer run these statements without such a
    policy.
- **`geode.storage.stats` and `geode.storage.integrity` take the graph gate
  (SONNY-2804):** both read the graph named by their argument with no
  check.
  - A user refused a graph read its node, edge and page counts and its WAL
    position.
  - A graph that did not exist answered 42883, an existence oracle.
  - `__geode_*` graphs answered too.

  Now an internal graph is refused (42501, Admin included). Then the caller
  must be allowed to bind the graph (42501), and only then must the graph
  exist (3F000).
- **EXPLAIN and PROFILE run alone (SONNY-2802, SONNY-2752):** both
  handlers take a request's lock, write gate and transaction bookkeeping from
  the whole program. But they only plan an EXPLAIN'd statement and only run
  a PROFILE'd one, and every other statement in the request was dropped
  without a word. So `USE GRAPH g1; PROFILE CREATE (:X)` took g1's write lock
  and wrote to the session's graph beside that graph's writers, and
  `CREATE (:X); EXPLAIN ...` was permission-checked and never ran.
  - A request that carries an EXPLAIN or PROFILE with any other statement,
    transaction control included, is now refused (0A000). Send the other
    statements, and any USE GRAPH, in a request of their own.
  - The exception is a re-selection of the graph the session is already on,
    which changes nothing. So `geode query -g g1 "PROFILE ..."` runs when the
    session is on g1 (a DSN that names g1), and is refused on a session on
    another graph; select g1 first.
  - A PROFILE'd change is recorded in the session's transaction like any
    other. A change of a second graph is then refused, and ROLLBACK takes
    the write lock of the graph the transaction changed.
- **The generated admin password file is created safely, in the data
  directory only (SONNY-2778):** the first boot of `geode serve`,
  `geode auth init` and the legacy `SecurityManager` write a generated admin
  password to `<data-dir>/.geode_admin_password`. They opened it with
  O_CREAT | O_TRUNC. A file already at the path kept its mode and owner, so
  a world-readable file created there in advance received the password, and
  a symbolic link there was followed. With no data directory, the server and
  `SecurityManager` wrote the file into the current working directory. Now:
  - the file is created with O_CREAT | O_EXCL | O_NOFOLLOW and mode 0600,
    set again after the open whatever the umask, in the data directory only;
  - nothing is written when anything is already at the path, a file or a
    symbolic link. `geode auth init` refuses before it creates the admin;
    the server logs `[startup] generated initial admin password NOT
    written …`, and the password is then set with
    `geode user reset-password`;
  - with no data directory, nothing is written.

  Retrieval and rotation are in docs/USER_AUTH.md ("The generated admin
  password"), which no longer gives `geodesic` as a default password. The
  `geode-auth` tool no longer leaks the RLS policy strings it copies.
- **Offline auth commands verify the security graph before they change it
  (SONNY-2798):** offline commands (`geode user ...`, `geode role create|delete`,
  `geode policy create|delete`, `geode grant`, `geode revoke`,
  `geode apikey create|revoke|revoke-all`, `geode auth init`) loaded
  `__geode_security` as it was on disk. Some of them then re-signed the whole
  HMAC chain without checking it first. So a record written at rest without
  the key, such as an allow-write GPS policy, a superuser user or a graph
  grant, was signed by the next offline change and took effect at the next
  server start. Each of these commands now verifies the chain before it
  changes anything, and refuses a store that does not verify. It changes
  nothing and points to `geode auth verify` and `geode auth reseal`. A
  change made on a verified store is sealed, so a sequence of offline
  changes, and the next server start, verify without a manual reseal.
- **Policy DDL is durable or fails; the RLS compiler bounds the VM stack;
  the security loaders survive out-of-range values (SONNY-2757):**
  - ALTER POLICY and DROP POLICY used to change the in-memory catalog and
    only log a failed write to `__geode_security`, so a revocation (a DROP,
    or disabling an allow) came back at the next restart. Now the statement
    fails and the catalog is left as it was: DROP deletes the stored record
    first, and ALTER is undone.
  - `geode.auth.policy_create` makes CREATE POLICY's checks (field lengths,
    a USING expression that compiles, a unique name) and persists the
    policy, failing like CREATE POLICY. It accepted anything and persisted
    nothing. `geode.auth.policy_delete` persists its drop.
  - The RLS expression compiler refuses an expression whose evaluation would
    need more than the VM's 64 stack slots, for example a right-nested OR 63
    levels deep. Such an expression compiled and then overflowed on every
    row, denying every row silently.
  - A stored operation, audit level, action, role priority or failed-login
    count that does not fit its field marks the record tampered, and it is
    not loaded (a policy loads as malformed). It used to abort a safe build
    at startup, before the signature check.
- **`CALL algo.*` applies RLS, and reads the session's graph only
  (SONNY-2685):** the graph procedures (BFS, DFS, Dijkstra, degree, every
  centrality, community and component procedure, and the graph statistics)
  applied the session's tenant scope but not its RLS policies. A node or
  edge a label or expression policy hides took part in every path,
  distance, degree and score. They also walked every graph's nodes, so
  nodes of another graph, the security graph included, could be scored and
  returned. Each call now applies the traversal scope of MATCH (SONNY-2679):
  - a node is visible when it is in the session's graph, passes the tenant
    scope, and passes the RLS policies of every one of its labels;
  - an edge is traversable when it is in the graph, passes the policies on
    its type, and both of its endpoints are visible.

  A hidden node or edge is neither visited nor returned. Dijkstra no longer
  takes a hop's weight from a hidden parallel edge. A start node the session
  cannot see gives no rows, as for another tenant's node. The graph
  statistics count the session's graph only.
- **Permissive and restrictive RLS policies combine as PostgreSQL's do
  (SONNY-2710):** the expression engine combined a table's policies as
  "any permissive passes OR every restrictive passes". A table with only
  permissive policies never denied a row, and one passing permissive policy
  overrode a failing restrictive one. Now, for each table (a node label or
  an edge type), a row is visible when (a permissive policy passes, or no
  permissive policy applies and the default allows) AND every restrictive
  policy passes. A node is visible only if every one of its labels allows
  it. The label-deny engines' entries join the same combination: a deny
  entry is a restrictive policy that fails, an allow entry (new
  `addAllowPolicy`) a permissive one that passes. An allow entry never
  hides a row and cannot undo a deny; `removeDenyPolicy` now removes deny
  entries only.
- **The RLS post-filter fails closed (SONNY-2729):** the transport's
  label post-filter (every QUIC and gRPC result, and algorithm results) used
  to return the rows unfiltered when it could not allocate its snapshot of
  the session's denied labels. A filter that cannot run now withholds every
  row, and the request fails with 53200 (out of memory). The federation
  post-merge filter, and its callback, fail the query the same way. The rows
  a filter keeps now keep their order.
- **Fulltext DDL and `geode.fts.*` lock the default graph (SONNY-2790):**
  fulltext search works on the default graph only, by design. This covers
  `CREATE INDEX ... USING fulltext`, `DROP INDEX` and
  `geode.fts.search`/`phrase`/`proximity`/`rebuild`.

  Since SONNY-2749 the server locks the graph a request's statements run on,
  and it counted these as running on the session's graph. From a session on
  another graph they therefore read and rewrote the default graph's nodes
  and fulltext engine while holding only the other graph's lock. They now
  take the default graph's lock from any session. A request that runs one of
  them and also changes another graph is refused (0A000), as for any request
  that changes two graphs.
- **The internal `__geode_*` graphs are off limits to statements, and the
  recovery reseal no longer signs a planted policy record (SONNY-2791):**
  - No statement or HELLO selects, creates or drops a `__geode_*` graph,
    Admin included. This covers `USE GRAPH`, `SESSION SET [PROPERTY] GRAPH`,
    `CREATE GRAPH`, `DROP GRAPH` and a HELLO's graph; the refusal is 42501.
    An Admin could write `:Policy` nodes into `__geode_security` directly,
    and any user allowed to write could `DROP GRAPH __geode_security`.
  - No seal signs a policy record that has no kind and whose HMAC does not
    verify. Such a record was written before record kinds existed, and GPS
    loads it by its shape (with no USING text, unconditionally). A record
    planted in that shape broke the chain, and it was signed by
    `geode auth reseal`, by `GEODE_AUTH_RESEAL_CHAIN=1`, and by the seal
    after any auth change, such as an offline `geode user reset-password`.
    - An auth change on a store holding such a record now fails at its seal.
    - The recovery reseal refuses, and signs nothing, until the operator
      decides each such record by id: drop it (delete) or accept it (sign
      it):
      - `geode auth reseal --drop-legacy-policy <id>` or
        `--accept-legacy-policy <id>`, repeated for each record;
      - `GEODE_AUTH_RESEAL_DROP_LEGACY=<id>,<id>` and
        `GEODE_AUTH_RESEAL_ACCEPT_LEGACY=<id>,<id>` for the startup reseal.

    An accepted record is then stored with its kind and USING text. Records
    that verify are signed as before.
- **`geode auth policy create` no longer overwrites a GPS policy
  (SONNY-2777):** the command took its policy id from the next *user* id, so
  it could reuse the id of an existing GPS policy and overwrite that record.
  The `geode-auth` tool used the current millisecond, so two policies
  created in the same millisecond shared one record. Every policy writer now
  takes its id from one sequence (one more than any policy record's). A new
  policy record never overwrites an existing one, and an update keeps the
  record's kind (GPS or RLS).
- **gRPC uses the session's graph, and a transaction changes one graph
  (SONNY-2776):** the gRPC handler never set its copy of the session's graph
  (`current_graph`), so every use of it meant `default`:
  - the RLS post-filter applied `default`'s label policies to rows read from
    another graph. `USE GRAPH g1; MATCH (n:Secret) RETURN n` returned rows that
    g1's policy hides;
  - COMMIT took `default`'s write lock while committing a transaction on
    another graph;
  - the rollback of an invalidated session locked `default`;
  - ROLLBACK and ROLLBACK TO SAVEPOINT took no lock at all.

  QUIC used a copy that trails the session within a request, with the same
  effects after a `USE GRAPH`. Now:
  - the RLS post-filter uses the graph the rows came from;
  - a transaction changes one graph. A request in an open transaction that
    changes a second graph is refused with 0A000. Commit or roll back first,
    as for a request that changes two graphs (SONNY-2749);
  - COMMIT, ROLLBACK, ROLLBACK TO SAVEPOINT, the rollback of an invalidated
    session and the stream-close teardown take the write lock of the graph
    the transaction changed.
- **SESSION SET GRAPH checks the graph permission and that the graph exists
  (SONNY-2775):** `SESSION SET [PROPERTY] GRAPH` took any name as given.
  - A user that `USE GRAPH` refused could switch with it and read or write
    the graph.
  - It did not check that the graph exists.
  - It let a connection bound to a graph leave it.
  - It created the test graphs `G1` and `G2` in the server.
  - On gRPC it stored the name with memory freed after the request.

  Every change of a session's graph now goes through one gate: `USE GRAPH`,
  `SESSION SET [PROPERTY] GRAPH`, `SESSION RESET`, `SESSION CLOSE`, and the
  graph a QUIC or gRPC HELLO binds. The gate checks:
  - the `bind_graph` permission (42501). Anyone may bind `default`;
  - that the graph exists (3F000);
  - that a connection bound to a graph stays on it. `SESSION RESET` and
    `SESSION CLOSE` keep that graph.

  `CURRENT_GRAPH` and `HOME_GRAPH` (and the `PROPERTY` forms) now mean the
  session's graph and its home graph; they were taken as graph names.
  The gRPC HELLO also checks the permission when it binds a graph that
  another session created at the same moment. The session's graph, time
  zone, schema and parameters are owned by the session.
  Scripts that switched to a graph before creating it must create it first.
  See `docs/SESSION_MANAGEMENT.md`.
- **Which GPS denies are enforced (SONNY-2781):** the SONNY-2744 note
  listed every action a policy can name as deniable. But enforcement asks
  `decide()` only for:
  - write: the change gate for all DML and the graph, graph type, schema,
    index and constraint DDL. The security DDL has its own Admin check
    (SONNY-2751);
  - read or write on `CALL` procedures;
  - decrypt_field.

  A deny on any other action is accepted but has no effect. DENY READ does
  not stop a plain MATCH, and DENY MATCH, CREATE, UPDATE, DELETE, SCHEMA and
  UNWRAP_KEY stop nothing. `docs/security/gps-decide.md` lists what is
  enforced; SONNY-2781 tracks wiring the rest.
- **GPS deny policies deny (SONNY-2744):** `decide()` skipped deny-effect
  policies, and the builtin-role check ran before the policy catalog, so a
  deny never denied. A matching deny now wins over a builtin role, an Admin
  shortcut and any allow policy, for every action a policy can name.
  `CREATE POLICY` still creates allow policies only; a deny comes from a
  stored policy with `permissive = false` in `__geode_security`, or from the
  policy catalog API. A deny whose expression does not compile keeps denying.
  See `docs/security/gps-decide.md`.
- **A read-only principal can no longer write through a multi-statement
  request (SONNY-2743):** the QUIC handler decided the lock and the
  write-permission check from a request's last query alone. If that query
  touched no data (`RETURN 1 AS c`), it took no lock and skipped the check,
  so `CREATE (:X); RETURN 1 AS c` from a read-only principal wrote, with no
  lock held; so did SET, DELETE, MERGE, REMOVE and DDL. Both QUIC and gRPC
  now decide over the whole request. The lock-free path for queries that
  touch no data, and the point-read path, are taken only when nothing else
  in the request does anything; a `USE GRAPH` of the current graph, as the
  CLI's `-g` flag prepends, still qualifies. A request ending in EXPLAIN is
  also checked if it changes data.
- **`geode.tenant.backfill_edge_tags` locks one graph at a time (SONNY-2733):**
  the procedure ran under the statement's lock on the session graph and
  re-tagged edges in every graph, while readers and writers of the other
  graphs ran alongside. Now:
  - it takes each graph's write lock in turn, re-tags that graph's edges, and
    releases the lock before it takes the next; it never holds two graph
    locks. It waits up to 120 seconds for each lock, as a write does; a graph
    still busy then is listed as one `failed` row with a null `edge_id`, and
    the run goes on;
  - send it as the only statement in its request. The server then runs it
    without the session graph's statement lock. Beside any other statement,
    including the `USE GRAPH` the CLI's `-g` flag prepends, it fails with
    `GraphLockHeld` and changes nothing;
  - it takes no `RETURN` or `ORDER BY` (`BackfillProjection`, 0A000), and
    changes nothing when it is given one. The server evaluates an
    `ORDER BY` after the procedure returns, and an expression such as
    `COUNT { MATCH … }` reads the store. With no statement lock held, that
    read ran unlocked. `YIELD`, `LIMIT` and `OFFSET` still work;
  - it skips the engine's own graphs (`__geode_security` and any other
    `__geode_…` graph);
  - an edge it cannot re-tag or read is listed with the new action `failed`,
    and the new `reason` column names the error. The edge is left as it was
    and the run goes on; a failure used to abort the run;
  - a session with a tenant scope is refused (`TenantScopedSession`), and so
    is a real run inside a transaction (`BackfillInTransaction`), which a
    ROLLBACK could not undo.

  Run the dry run first and review its `would_retag` rows: a `default` edge
  that an operator placed between one tenant's nodes on purpose looks like a
  legacy edge, and a real run moves it to that tenant.
- **Policy text no longer changes meaning across a restart (SONNY-2731):**
  `__geode_security` stores a policy's name and scope graph in 64-byte
  fields and its USING text in a 512-byte field. `CREATE POLICY` accepted
  longer values; the durable write then failed with only a warning, so the
  policy lived in memory until the next restart. The startup loader also
  cut any stored value longer than its field and compiled the cut text as a
  different policy. Now:
  - CREATE and ALTER POLICY refuse a name or graph longer than 63 bytes,
    or a USING text longer than 511, with `PolicyFieldTooLong`;
  - a CREATE whose durable write fails is rolled back and the statement
    fails;
  - a stored value that does not fit is loaded fail-closed. The policy
    grants nothing and lists with `valid = false`; it is no longer cut.
- **Strict RLS expression policies (SONNY-2732):**
  - Only a boolean TRUE admits a row. A policy that evaluated to a
    non-empty string or a non-zero number used to admit it. So `row.flag`
    admitted a flag of `'no'`, and a bare `'anything'` admitted every row.
  - `NOT`, `AND` and `OR` treat a non-boolean operand as UNKNOWN.
  - Creating or updating a policy whose expression does not compile now
    fails with `InvalidRlsExpression` and installs nothing. Such a policy
    used to be installed denying every row, with only a log line. Only
    policies loaded back from storage keep the deny-all fallback, and they
    are marked invalid.
  - SHOW POLICIES and `geode.auth.policy_list` have a new `valid` column.
    Startup logs how many stored GPS policies are invalid.
  - The lexer rejects a missing `)`, an unterminated string and an empty
    field name.
  - `geode.rls.add_attribute_policy` accepts only identifiers for its row
    property and attribute key. Both are pasted into the policy text, so a
    crafted property could append `OR TRUE`.
  - The expression VMs refuse out-of-range constant and jump indexes and
    stop a looping program.
  - An empty stack now denies in the second VM.
  - An update is compiled before it replaces the policy.

  **Behaviour change:** policies that relied on truthy strings or numbers,
  or on a forgiven `)`, must be rewritten. Range comparisons on string
  values are lexicographic, so range policies need numeric row values.
- **A large RLS policy no longer aborts the server (SONNY-2730):** the
  expression compiler cast every constant's index to a byte, so a policy with
  more than 256 constants crashed the server when it was compiled; a
  129-term allow-list was enough. It also recursed without a bound, so a long
  enough run of `(` or `NOT` overflowed the stack. A repeated field name or
  literal now takes one constant slot. A policy with more than 256 distinct
  constants, or nested more than 64 levels deep, is refused.
- **RLS range policies fail closed (SONNY-2709):** in an expression RLS
  policy, `<`, `<=`, `>` and `>=` treated a missing value, or two values of
  different types, as equal. So `<=` and `>=` held: a policy such as
  `row.level <= 3` passed every row whose `level` was missing or not a number,
  on nodes and on edges. A principal attribute is always a string, so
  `row.level <= principal.attribute.clearance` passed every row for every
  user. Now a comparison of values that have no order is UNKNOWN: a null, a
  NaN, a boolean, or a string against a number, say. UNKNOWN denies the row
  and stays UNKNOWN under `NOT`, `AND` and `OR`, so `NOT (row.level > 3)` does
  not pass a row with no level. A principal attribute compared with a number
  is parsed strictly as that number's type. Against an integer it must be an
  optional `-` and digits (`"3"`, `"-1"`). Against a float it may also have a
  `.` and a fraction (`"2.5"`). Anything else denies the row, and so does a
  missing attribute; for example `" 3"`, `"+3"`, `"3.0"` against an integer,
  or `"1e3"`. A row's own string is never read as a number. Two numbers and
  two strings (in byte order) compare as before, and two timestamps now
  compare too (they were always "equal").

  `=` and `<>` follow the same SQL three-valued logic. A comparison with a
  missing value or `NULL`, or between values of different kinds, is UNKNOWN,
  and a principal attribute is coerced for them as for the range operators.
  `IS NULL` and `IS NOT NULL` are new, and are never UNKNOWN. Decimal
  literals (`2.5`) are new. `NOT` now binds below the comparisons, as in SQL.
  An expression that does not parse completely now denies every row.
  Before, a valid prefix was enforced and the rest dropped, so
  `row.x IS NULL OR …` compiled as `row.x`. A branch on UNKNOWN in
  hand-written bytecode denies.

  **Behaviour change:** a policy comparison that meets a missing or mistyped
  value now denies the row. This covers the range operators, `=` and `<>`.
  `row.cls <> 'secret'` no longer admits a row without `cls`; write
  `row.cls IS NULL OR row.cls <> 'secret'` to keep that. `row.cls = NULL`
  matches nothing. A policy that relied on a numeric principal attribute now
  works as written. `NOT` over a missing value or an UNKNOWN comparison now
  denies instead of allowing.

---

## [v0.8.22] - September 19, 2026

Concurrency memory-safety fix in the graph-storage adjacency read path.

### Fixed

- **Borrowed-slice torn read on concurrent edge append (SONNY-1797):** the
  adjacency-list accessors now take an acquire-ordered (ptr,len) snapshot that
  pairs with the appender release publish, eliminating a torn
  one-past-the-old-buffer out-of-bounds read (UAF-class) reachable by any
  concurrent reader during edge append. The `test_edge_torn_read_stress`
  regression is un-quarantined and back in the sharded `test` suite.

---

## [v0.8.21] - September 19, 2026

grpc-zig fixes propagated through the devnw/zig dependency diamond, plus
Prometheus exposition naming (SONNY).

### Fixed

- **grpc-zig RST_STREAM handled as a stream error (SONNY-1838):** re-pinned
  onto grpc-zig v0.1.12, which handles an inbound RST_STREAM as an HTTP/2
  §5.4.2 stream error — failing only that stream's RPC and continuing to read
  the connection — instead of tearing the whole connection down and dropping
  every other in-flight RPC. GOAWAY and real connection loss still tear down.
- **grpc-zig FIPS dependency resolvable (SONNY-1852):** grpc-zig v0.1.12 pins
  `.fips` to the published git dependency (the spine's v0.1.1 content hash)
  rather than a machine-local `.path`, so `-Dfips=true` and the FIPS CI job
  resolve.
- **Prometheus naming conventions on /metrics (SONNY-1807):** the OTel →
  Prometheus responder now applies Prometheus/OpenMetrics naming — `_total`
  for monotonic counters and base-unit suffixes (`_seconds`, `_bytes`) — so
  scrapers and dashboards work without manual renaming.

### Changed

- **Dependency diamond re-pinned onto grpc-zig v0.1.12:** the `zig-tool
  sync-diamond` cascade re-released the ~18 intermediate devnw/zig libraries
  (otel v0.1.24, quic v0.1.44, geode-client-zig v0.3.12, graph-storage v0.4.6,
  …) so a single grpc-zig version converges across the dependency tree.

---

## [v0.8.20] - September 18, 2026

QUIC stream semantics: sibling-stream binding, idle-stream reclamation, and
statement cancellation on the wire (SONNY).

### Fixed

- **Unbound sibling QUIC streams (SONNY-1835):** a sibling stream opened without
  its own HELLO inherited no tenant/graph identity and silently returned zero
  rows. Such an unbound sibling is now refused with a typed error (GQLSTATE
  08003) instead of running unbound. Clients that send a per-stream HELLO,
  including the Go driver, are unaffected.
- **Statement cancellation on the QUIC wire (SONNY-1841):** there was no way to
  cancel an in-flight statement, so an abandoned mutation ran to completion
  holding the per-graph write lock to its ~120s deadline and blocking the next
  writer on another connection. A per-stream CANCEL message (proto oneof tag
  15, backward-compatible — old clients simply never send it) and a QUIC stream
  reset now abort the statement; the write path polls the cancellation and
  releases the write lock promptly (SQLSTATE 57014).

### Changed

- **Idle-open sibling stream reclamation (SONNY-1837):** idle-open sibling QUIC
  streams can now be reaped on an independent, tighter deadline via
  `GEODE_QUIC_STREAM_IDLE_REAP_MS` (default 0 = opt-in; the existing ~300s
  connection-deadline reclamation and the admission rejection on slot
  exhaustion are unchanged), letting operators reclaim stream-pool slots faster
  under handshake pressure.

---

## [v0.8.19] - September 18, 2026

Engine metrics correctness and QUIC teardown safety, plus CI/test-suite
hardening. Cut to unblock the sonny-upstream integration work (SONNY).

### Fixed

- **Cluster node health metric (SONNY-1803):** `geode.cluster.node.health`
  was a monotonic Counter and could never represent a return to healthy. It is
  now a Gauge (0 = unhealthy, 1 = healthy) observable in both directions.
- **QUIC stream-teardown use-after-free read (SONNY-1794):** teardown proved
  stream liveness by reading `tracking_index` on a wrapper that could already
  be freed. Membership is now decided by a pointer-only scan of the tracked
  list under `streams_mu`, so a freed wrapper is never dereferenced.
- **Accept-reactor inbox churn (SONNY-1796):** the stream accept reactor's
  `drainPending` discarded and reallocated the pending inbox on every
  non-quiet pass; it now reuses the backing capacity across passes.
- **Resident node-cache use-after-move (SONNY-1979):** `getNodePtrForScan`
  returned a live `*Node` into a shard's `AutoHashMap` value storage; a
  concurrent hydration insert that grew that shard rehash-moved the value,
  dangling the pointer (CWE-362, use-after-move). Resident hits are now
  snapshotted into a grace-lifetime detached box under the shared shard lock
  (matching the existing scan-miss path), so the returned pointer is stable
  across a concurrent shard grow.

### Changed

- **Bounded metric cardinality (SONNY-1805):** `db.namespace` on graph
  mutation metrics no longer emits the raw, unbounded (tenant-revealing) graph
  name; it emits a bounded id.
- **Closed metric label sets (SONNY-1806):** the reason/strategy attributes on
  the transport-close, query-plan, audit-drop, and CDC-drop metrics are now
  closed enums instead of open `[]const u8` strings.

### CI / Tests

- **Serialized k8s test shards (SONNY-1798):** the two 8-way test-stage
  matrices now carry a per-shard `resource_group`, capping concurrent pods.
- **Load-independent pre-push assertions (SONNY-1799):** the startup
  lazy-hydrate and gap0813 timing assertions no longer flake under host load;
  the gap0813 latency budget scales under CI.
- **Quarantined intermittent torn-read stress (SONNY-1797):**
  `test-edge-torn-read-stress` removed from the aggregate `test` step (still
  standalone-runnable), tracked in `docs/KNOWN_TEST_ISSUES.md`.
- **Verified SONNY-1795:** the `close_app_error` double-latch was confirmed
  already resolved — it is latched only in the disjoint `close()` and
  `requestShutdown()` paths.
- **Join spawned workers on all paths (SONNY-1982):** the lazy-hydrate
  concurrency tests could let a spawned worker outlive its test body on an
  error path (a `try` between spawn and join), which SIGSEGV'd under Zig's
  `--listen` test runner in the x4-sharded pre-push. Each worker is now joined
  on every exit path (guarded `defer`, release-then-join before captured state
  dies), fixing a pre-existing pre-push flake.

---

## [v0.8.18] - September 16, 2026

CI-only re-cut of v0.8.17. No engine code changes.

### Fixed

- **Cross-build shards (CI):** the v0.8.17 tag pipeline lost both aarch64
  cross-build shards to an out-of-memory kill inside `zig build` on the k8s
  cluster runner, so `build-release` never ran. `test-cross-build` now runs on
  the dedicated docker-executor fleet with `zig build -j2`. The v0.8.17 tag
  remains but never produced an image or packages.

---

## [v0.8.17] - September 16, 2026

CI-only re-cut of v0.8.16. No engine code changes.

### Fixed

- **Cross-build OpenSSL prefix (CI):** Debian removed openssl `3.5.6-1~deb13u2`
  from the trixie pool on 2026-09-16, so `scripts/ci/fetch-openssl-prefix.sh`
  404'd and the v0.8.16 tag pipeline's `aarch64-linux-gnu` cross-build failed
  before `build-release` could run. The Debian pins are refreshed to
  `3.5.7-1~deb13u2` with digests cross-checked against the trixie Packages
  index. The v0.8.16 tag remains but never produced an image or packages.

---

## [v0.8.16] - September 15, 2026

Engine release. Re-pins the whole `devnw/zig` dependency spine onto
grpc-zig v0.1.10 (SONNY-1568 per-connection reader threads) via the
`zig-tool sync-diamond` cascade, and ships the reviewed server/execution
/storage/transport fixes.

### Fixed

- **Tenant scope on engine-direct reads (SONNY-1229):** engine-direct reads now
  apply the caller's tenant scope instead of bypassing it.
- **Node-scan fast path (SONNY-1218):** the fast path is declined when no
  storage adapter is present rather than silently returning unscoped rows.
- **Tenant visibility in graph execution (SONNY-1318):** scoped degree workers
  hardened, FTS fails closed under strict tenancy, union-find edges are read by
  value, and the thread-safety audit was corrected.
- **Tenant scope in path and subquery operators (SONNY-1326):** `shortestPath`,
  `COUNT{}`, `EXISTS{}` and pattern comprehensions apply tenant scope;
  `graph_procedure_tenancy` is advertised as a capability.
- **UNION read-only gate (SONNY-1330):** the gate walks CTE bodies and
  expression subqueries, and parallel UNION arms no longer mutate shared state.
- **Exact-index persistence accounting (SONNY-1574):** a skipped or unattempted
  exact-index persist is never reported as done; it counts only for a FULL
  checkpoint the engine accepted, a timed-out worker wait fails, and the persist
  is spawned outside the build mutex.
- **gRPC flow control (SONNY-1560):** a pushed gRPC result no longer holds the
  session mutex across a page write; a stalled, abandoned or superseded stream
  releases the session cursor deterministically; an unsatisfiable peer
  flow-control window is classified `RESOURCE_EXHAUSTED` instead of being waited
  out; the library's RST ends an exhausted stream and the flow-control seam is
  pinned.
- **QUIC connection lifecycle (SONNY-1219):** every server-initiated connection
  close is named, the five try-escapes out of `handleQuicConnection` are named,
  stream wrappers are no longer double-freed, stream release is idempotent, and
  the accept reactor's OOM teardown runs outside `shard.mu`.

### Changed

- Re-pinned `grpc_zig` to v0.1.10 and cascaded the 18 intermediate libraries
  that sit between it and the engine (see the release report for the full tag
  list).

### Known limitations

- **Server-initiated close codes are named on the SENDING side only.** The
  connection-close codes introduced by SONNY-1219 are set when the server
  closes, but a peer cannot read them: the vendored quic layer discards the
  close code on receive. Until that is fixed the codes are useful for
  server-side logging and tests only, not for client-side behavior. Tracked as
  **T-8**.

---

## [v0.18.1] - January 28, 2026

### Added

- **TDE File-Level Encryption:** Extended TDE to all persistent storage files:
  - Index persistence: R-tree, HNSW, Patricia trie, Domain trie, JSONB inverted, Interval tree
  - Schema catalogs: Main catalog and FLE catalog
  - Distributed state: Raft consensus state, snapshots, and log files
  - All files encrypted with AES-256-GCM when `GEODE_TDE_KEY` is set
  - CANARY markers added: REQ-TDE-FILELEVEL-001

### Documentation

- Added [TDE_FILE_LEVEL_ENCRYPTION.md](TDE_FILE_LEVEL_ENCRYPTION.md)
- Updated SECURITY_PROGRESS.md with file-level encryption status
- Added geodetestlab spec: `tde_filelevel_encryption.yml`

---

## [v0.1.0] - Grey Cardinal Compliance

### Added

- **Backup Encryption:** Implemented AES-256-GCM encryption for backup files (GAP-005). Requires `GEODE_TDE_KEY`.
- **Time-Series Integration:** Added `timeseries.value()` GQL function to access in-memory time-series data (GAP-004).
- **WAL Replay:** Implemented WAL replay logic for incremental backup recovery (GAP-002).
- **Benchmarks:** Added Time-Series benchmarks (`src/benchmarks/bench_timeseries.zig`) (GAP-006).

### Fixed

- **Backup Compression:** Fixed shim implementation to use real ZStandard compression (GAP-001).
- **Graph Centrality:** Cleaned up unused headers; deferred advanced metrics to v0.18 (GAP-003).

### Security

- **TDE:** Transparent Data Encryption for backups.

---
Add OpenCL integration into GPUAccelerator: compile kernels via clCreateProgramWithSource/clBuildProgram/clCreateKernel, and store program/kernel/queue in KernelCompiledOpenCL; prepared Launch/Copy paths will be implemented later.
