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
- **A transaction's engine transaction belongs to its session and ends with
  its program (SONNY-2823):** a Geode transaction's writes share one storage
  engine transaction, so its commit costs one WAL fsync on the shard. That
  engine transaction lived in a thread-local slot until the Geode
  transaction's COMMIT, as if one thread served one session. gRPC serves a
  session's requests on any worker thread, QUIC serves many streams on one
  thread, and only QUIC's COMMIT and ROLLBACK messages ended it. So it stayed
  open on the worker thread:
  - a committed transaction's writes on its shard had no COMMIT record, and a
    crash lost them;
  - every later write to that graph on that thread, from any session, joined
    it and was lost with it.

  Now the session holds its engine transaction, and a request puts it on the
  serving thread and takes it back. It is committed when the program that
  opened it ends, while the request still holds the graph's write lock. The
  Geode transaction goes on across requests in the undo log, which undoes a
  committed change too. The COMMIT and ROLLBACK statements, a failed
  statement's rollback, gRPC's COMMIT and ROLLBACK RPCs, and a session's
  teardown end it as well. Stopping the server now rolls back every gRPC
  session's open transaction; it left the transaction's undo entries in the
  log.

  **Behaviour change:** a transaction sent as BEGIN and then N execute
  messages now commits one shard WAL write per message, not one for the
  whole transaction. A transaction sent as one request still commits once.
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
- **A HELLO creates a missing graph only with the schema permission
  (SONNY-2824):** a QUIC or gRPC HELLO naming a graph that did not exist
  created it for any Admin or ReadWrite user and bound the session to it.
  ReadWrite has no schema permission (SONNY-2803), so a ReadWrite user
  created any graph it named at connect time. The HELLO now checks in the
  order every session graph change does:
  - an internal graph is refused;
  - then a graph the principal may not bind is refused, whether or not it
    exists;
  - an existing graph is bound;
  - a missing graph is created only for a principal with the schema
    permission on it: Admin, or a GPS policy `FOR SCHEMA` on the graph.

  **Behaviour change:** a ReadWrite user's HELLO naming a missing graph is
  refused ("Graph does not exist and user lacks permission to create it"),
  and nothing is created. An administrator creates the graph, or grants
  `FOR SCHEMA` on it.
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
- **A float or a decimal narrowed to an integer no longer aborts the server
  (SONNY-2739):** a read-only query aborted a Debug or ReleaseSafe server
  wherever a float or a decimal was narrowed to an integer without a range
  check. This covers:
  - a GROUP BY or DISTINCT key of 2^63
    (`RETURN count(DISTINCT 9223372036854775808.0)`);
  - the power operator (`2 ^ 63`, `10 ^ 40`, `10 ^ 400`, `0 ^ -1`);
  - `toFloat`, `CAST(... AS FLOAT/DOUBLE/REAL)`, `degrees` and `radians`;
  - `ceil`, `floor`, `round` and `toInteger` over a decimal, and `sum()` and
    `avg()` of a list;
  - a JSON number, a typed ARRAY parameter, and a decimal literal with more
    than 255 fraction digits;
  - the geography and geometry functions (`st_x(st_point(1e35, 0))`,
    `altitude(latlonalt('0,0,1e300'))`);
  - weighted path costs, vector index scores, centrality scores, time-series
    interpolation and the distributed merge of a summed column.

  NaN produced a garbage value instead (`toFloat('nan')`,
  `latitude(latlon('nan,0'))`). Every such conversion is now checked: a value
  that does not fit is refused with SQLSTATE 22003, and zero to a negative
  power is 22012. An integer power is now exact (`3 ^ 39`), a JSON number
  past the decimal comes back as a double, `latlon()` refuses a NaN
  coordinate, and the TDE and audit benchmark procedures saturate their
  measurements. `round()` at an effective scale of 38
  (`round(0.99999999999999999999999999999999999999)`) no longer aborts
  either (a regression in the first fix).
- **MERGE never binds, rewrites or attaches to a row the session may not
  see (SONNY-2686, SONNY-2728):** MERGE matched existing nodes, and a
  relationship MERGE matched existing edges, on graph, tenant, labels and
  properties only, never on the session's RLS policies. It returned a
  hidden node's properties, rewrote a hidden node or edge through ON MATCH
  SET or SET (under an expression policy, possibly into view), and
  attached relationships to hidden nodes. A visible match is now used
  wherever it sits. When only rows the policies hide match (a node, or an
  edge whose type a label-deny policy denies or whose own properties an
  expression policy denies), the statement is refused with
  `MergeMatchNotVisible` (SQLSTATE 42501) before its first write, and
  nothing is bound, updated or created. The refusal tells the session that
  some hidden row equals the pattern, the same class of covert channel as
  PostgreSQL's `ON CONFLICT` error on a row the UPDATE policy hides, but
  over any property the pattern names; binding the row, or treating it as
  absent and creating a duplicate, is worse (see
  `docs/kb/RLS_IMPLEMENTATION.md`). Every refusal writes an `access_denied`
  audit record (action `MERGE_MATCH_NOT_VISIBLE`) with the user, the
  graph, the pattern's labels or relationship types and its property keys,
  never the values. There is no per-session rate limit on refusals yet.
- **The QUIC key-resolved write fast paths serve only unrestricted sessions
  (SONNY-2686, SONNY-2724):** the single-node MERGE, graph-selector MERGE,
  `/*+BATCH*/` MERGE, relationship MERGE and MATCH … CREATE edge fast paths
  find existing nodes by merge key alone, with no tenant check and no RLS.
  They now serve a request only when no tenant scope, strict tenancy or
  installed RLS policy restricts the session; every other request takes
  the general executor. **Behaviour change:** bulk ingest from
  tenant-scoped sessions, and from any authenticated session while an RLS
  policy is installed, runs on the executor and is slower.
- **indegree() and outdegree() count only what the session may see
  (SONNY-2691):** `indegree(-1)` panicked and aborted the server; it is 0
  now, like every id that names no node. The raw-id form read the degree
  of any node in any tenant or graph and under any policy, and both forms
  counted neighbours the policies hide. A node the session may not see now
  has degree 0, and a degree counts only the edges a traversal from the
  node may take. The raw-id form decides the node on a transient copy and
  retains nothing: before, each call kept a copy of the node in memory
  until the graph's next checkpoint, so one read that called it N times
  grew the store by N copies (P11). **Behaviour change:** in a restricted
  session, legacy edges tagged `default` and other tenants' edges no
  longer count.
- **knn() and vector_knn() rank only rows and edges the session may see
  (SONNY-2692):** both the brute-force scan and the vector-index path
  returned, ranked by distance to the caller's vector, the ids of rows the
  RLS policies hide. Every candidate now passes the session's row
  visibility before ranking and before it is cut to k (the index path asks
  the index for more when rows drop out). An edge's vector counts only
  when the RLS policies on its type allow it and both its endpoints are
  visible (under a tenant scope too, the single edge-tenant rule). Every
  vector-index answer is filtered by the session's graph and tenant, not
  only under RLS, so a row the index holds that the label authority check
  did not see never comes back.
- **The evaluator refuses to answer without row visibility (SONNY-2691):**
  in a process that never ran `execution.initEvaluator` (embedded use,
  tests), degree and knn() answered without the session's RLS policies,
  and pattern predicates, subqueries and shortestPath() panicked. A
  statement whose session carries a user or a principal is now refused
  with `EvaluatorNotInitialized` (XX000), and pattern predicates are
  refused instead of panicking. The server installs the evaluator once at
  startup; the connection handlers no longer rewrite it.
- **A malformed wire parameter no longer aborts the server
  (SONNY-2727):** any authenticated client could crash a ReleaseSafe server
  with one parameter: a SMALLINT outside i16, a CHAR or VARCHAR longer than
  65535 bytes, a decimal scale or original scale past 255, the same
  narrowings in a typed extended value, a binary decimal scale outside
  0..255, a binary length near 4 GiB, or a binary list nested thousands of
  levels deep. Each is now refused with SQLSTATE 22023. A REAL outside the
  f32 range is refused instead of becoming infinity, a binary list that
  claims more items than it holds is refused before it sizes an
  allocation, and a refused parameter frees what the parameters before it
  decoded. A distributed transaction's participant likewise refuses a
  decimal from a peer node whose scale is past 255 (it aborted the node),
  and frees what it converted from a refused nested list or a map that
  repeats a key.
- **A client parameter map that repeats a key no longer leaks
  (SONNY-2818):** the client parameter decoder kept the first copy of a
  repeated map key and never freed the second, or the value it replaced.
  QUIC decodes with the process allocator, so any authenticated client could
  grow the server's memory by about the size of each request. The decoder
  now frees the duplicate key and the replaced value (the last value still
  wins), as the peer path already did.
- **The audit log cannot be forged through a MERGE refusal (SONNY-2819):**
  the audit log's canonical JSON Lines writer printed every string
  unescaped. A MERGE refused for a hidden match (SONNY-2728) records the
  pattern's property keys, and a key can be a string literal holding a quote
  and a newline, so a restricted user could split the record and write a
  second, well-formed record of their choosing. Every string the writer
  prints is now JSON-escaped (quotes, backslashes, control characters,
  U+2028 and U+2029, and a byte that is not UTF-8 as U+FFFD), and the
  refusal's labels and keys hex-encode their control characters.

  **Behaviour change:** the record's timestamp prints as
  `YYYY-MM-DDTHH:MM:SS.mmmZ`; it printed signed fields
  (`2026-09-26T+15:+31:+58.+780Z`). Records written before the change still
  verify.
- **Audit text a client controls is unambiguous (SONNY-3045):** a MERGE
  refusal's labels and keys also hex-encode a comma and a backslash, so the
  text reads back as exactly its items. The Windows Event Log (XML), syslog
  and JSON audit exporters escape every string: XML text as entities and
  character references, syslog values quoted with `"`, `\` and `]` escaped
  and control characters hex-encoded, JSON strings JSON-escaped. They also
  compile against the audit event again (nothing called them).
- **A duplicate CREATE CONSTRAINT no longer aborts the server
  (SONNY-2809):** creating a constraint whose name already exists freed the
  catalog's key for it twice, which corrupted the allocator and aborted the
  server (a segfault in a release build) for any user allowed to run DDL. A
  duplicate name is now refused with 42710 (duplicate object), and
  `CREATE CONSTRAINT IF NOT EXISTS` is a no-op; the refusal used to return a
  result whose one column and one row were uninitialized memory. When saving
  the catalog fails, CREATE CONSTRAINT, CREATE SCHEMA and a new graph no
  longer leave the map holding a name already freed, and a catalog whose
  load fails at open no longer leaks what it had read.
- **Integer overflow and narrowing no longer abort the server
  (SONNY-2769):** integer overflow, a narrowing cast that does not fit, and
  minInt divided by -1 abort a Debug or ReleaseSafe server. A read-only query
  reached them through:
  - decimal `*` (the coefficient and the scale), `/`, `+` and `-`, and
    `CAST(... AS DECIMAL(p, s))`;
  - `-minInt`, `abs(minInt)`, `minInt / -1`, `minInt % -1` and
    `mod(minInt, -1)` (the last two a hardware division trap), and
    `true + maxInt`;
  - date +/- interval past the day range (`+ duration('P2147483647D')`);
  - any timestamp before 1970 and any date before year 0 in a result (the
    response encoder);
  - `range()` at the edge of i64, `char()`/`varchar()` lengths, `decimal()`
    scales and 39-digit strings, `vectori32` elements, int4 range bounds,
    `ip_netmask` prefixes, DTW windows, `indegree(-1)`, `interval_contains`,
    and `knn()` with a k past u32 over a vector index;
  - procedure arguments (`tde.configure_mock_kms`, `tde.configure_rotation`,
    `audit.configure`, `algo.bfs.stream` depth), a SMALLINT parameter, a
    typed DECIMAL parameter's scale, and a TIME literal with 256 fraction
    digits;
  - a decimal past scale 38, wherever 10^scale was computed in i128: CAST
    to STRING, VARCHAR or TEXT, string concatenation (`'a' || <it>`), an
    inline property map (`MATCH (n:T {x: <it>})` on the legacy executor,
    MERGE on every session), the legacy `WITH ... ORDER BY`, a map
    property's stored JSONB text, and the ORDER BY keys the server prints
    for a paged result (`ORDER BY x + <it>`).

  A value that does not fit is refused with 22003 (a procedure argument
  with InvalidArgs), or kept exactly where the answer is defined: `x % -1` is
  0, a pre-1970 timestamp and a negative year are formatted, a CAST string's
  fraction digits past the target scale are truncated, and a `knn()` k past
  u32 is clamped (more neighbours than the index holds is all of them).
  `CAST('-1.5' AS DECIMAL)` keeps its sign (it was -0.5). A decimal's text
  is exact at any scale: `CAST(-0.5 AS STRING)` is '-0.5' (it was '0.5'),
  a map property of -0.5 is stored as -0.5 (it was 0.5), and a decimal of
  more than 32 digits casts to its text (it was NULL). `toString()` of a
  decimal is exact too (it went through a double: `toString(1.50)` was
  '1.5', and 38 digits kept 17), and `'a' || <decimal>` takes its text at
  any length (past 64 characters it failed with 0A000). **Behaviour
  change:** an inline property map and MERGE compare two numbers by their
  exact value, as GROUP BY does: `MERGE (n:T {x: 1.0})` matches a node
  whose x is the integer 1 (it created a second node). `=` does not always
  agree: it compares a DOUBLE with an exact number approximately, in a
  double, so `DOUBLE 0.1 = 0.1` is true while `{x: 0.1}` does not match a
  stored DOUBLE 0.1 (SONNY-2807).

### Fixed

- **Bulk ingest leaves a transaction's changes to the executor
  (SONNY-2816):** with `GEODE_BULK_INGEST` set, QUIC's bulk-ingest fast
  paths (a simple CREATE or MERGE, and MATCH ... CREATE or MERGE of an edge)
  also served a change sent inside an open transaction. They write to
  storage directly and skip the undo log, so the transaction's ROLLBACK did
  not undo the change. A change in a transaction now takes the general
  executor, as it does without `GEODE_BULK_INGEST`; autocommit changes still
  take the fast paths.
- **ROLLBACK removes what MERGE created:** a node or edge that MERGE
  created inside a transaction was not recorded in the undo log, so
  ROLLBACK kept it: `START TRANSACTION; MERGE (:M {k: 1}); ROLLBACK` left
  the node, and a MERGE'd relationship left its edge and any endpoints it
  created. They are now recorded as CREATE's are, and ROLLBACK removes them
  with the properties the MERGE set on them. A change MERGE makes to a node
  or edge it matched is not undone yet.
- **An inline property map and MERGE match a stored value by its value on
  every path (SONNY-2806):** `MATCH (n:T {x: v})` and `MERGE` compare the
  stored property with `v` by value on the planned read and the streaming
  node scan of a persisted session, as the legacy executor does:
  - numbers by their exact value, as GROUP BY keys them: `{x: 1.50}`
    matches a stored 1.5, `{x: 1.0}` a stored 1, `{x: 1}` a stored 1.0,
    and `{x: $d}` a node created from the same DOUBLE `$d`. None of these
    matched on a persisted session; a DOUBLE and every extended value never
    matched there, and relationships (`[r:R {w: 1.0}]`) likewise;
  - durations by their months and day-to-second length (`{v: PT24H}`
    matches a stored P1D), and zoned times by their UTC time of day. The
    legacy executor compared both by representation, so MERGE also created
    a second node for them.
  - **Behaviour change (fixes a round-5 regression):** MERGE's property
    index keys an integer by its value, whatever its representation:
    `MERGE (n:U {x: 1})` created a second node beside a stored 1.0 on every
    session, while `MERGE (n:T {x: 1.0})` matched a stored 1. A number that
    is not an integer (1.5, a DOUBLE 0.25) stays out of that index, as in
    v0.8.22. The executor finds it by its label scan, and the server's bulk
    MERGE (`bulkMergeNode*`) through the exact node-property index (by a
    label scan in lean mode, where that index holds no value of a key
    registered after its nodes were written). So MERGE on the server fast
    path now works for a DECIMAL or DOUBLE key, in lean mode too: it failed
    with MergeValueNotIndexable, or, with ON MATCH SET, created a node on
    every run. Two concurrent bulk MERGEs of one value in two forms (INT 7
    and DECIMAL 7.0; DOUBLE 7.5 and DECIMAL 7.50) create one node: they now
    take one per-tuple lock, which was chosen by the value's representation.
  - **Behaviour change:** when two nodes hold one MERGE key (1 and 1.0, or
    two nodes CREATE wrote with one value), MERGE matches the one with the
    lowest node id, on the executor, the server's bulk MERGE and a reopened
    store. The index kept the node written last, so after a restart MERGE
    could match the other node, and deleting either node, or a SET that
    moved it off the key, dropped the entry: the next MERGE created a third
    node. The entry now goes only with the key's last holder. When the
    lowest holder goes, the next lookup of that key finds the next one
    through the exact node-property index, at a cost proportional to the
    key's holders, under the graph lock the lookup holds (EXCLUSIVE for the
    executor's MERGE, SHARED for the server's bulk MERGE and edge lookups).
    Measured with 200,040 nodes of one label: the first MERGE of such a key
    took 30 µs on average (84 µs at most), against 83 ms (108 ms) when it
    scanned the label, which is about 6 s at 14.27M nodes. It scans the
    label only in lean mode, in a store without an adapter, and while the
    exact index is deferred or being rebuilt after a reopen; it does not
    wait for that rebuild (for the cost in lean mode, see Known
    limitations). A lookup that found the holders while a writer inserted
    one could drop the new holder's entry (the next MERGE then created a
    second node); it now leaves the entry for the next lookup.
  - A string no longer shares MERGE's key with a boolean or an integer:
    the server's bulk MERGE of `true` matched a stored `'true'` (and v0.8.22's
    of `1` a stored `'1'`).
  - `MATCH (n:T {x: 1})` on the legacy executor (a session in memory, with
    an RLS policy or tenant-scoped) returned one node when two held the
    value (1 and 1.0, or two nodes CREATE wrote with 1): it read the node
    from MERGE's index. It uses the index only for a key's only holder now.
    A SET after such a MATCH changed that one node, with no error, on every
    session: `MATCH (p:P {tenant_id: $t}) SET p.state = 'new'` changed one
    of three nodes, with a literal, a WHERE, or a per-row or aggregate
    RETURN too (SONNY-2977). A map of two properties, and
    `WHERE p.tenant_id = $t`, changed all three.
  - The server's multi-property MERGE compares a stored value as the
    executor does: `MERGE (:T {a: 1, d: date('2020-01-01')})` created a node
    on every run (a stored date, duration or DOUBLE never matched), and
    `{a: 1}` did not find a stored 1.0.
  - A stored value that cannot be decoded fails the planned read or the
    streaming node scan; it was taken as a mismatch, and the row was
    dropped.

  A DOUBLE and a decimal are equal only when their values are exactly
  equal (`{x: 0.1}` does not match a stored DOUBLE 0.1), which is how
  GROUP BY treats them. `=` compares them in a double instead (SONNY-2807).
  The planned read's WHERE seek (`WHERE n.x = <integer>`) agrees with `=`
  past 2^53: `n.x = 9007199254740993` returned no row for a stored DOUBLE
  2^53, while `count(n)` returned 1. For an integer no double holds, the
  seek now also asks for the double nearest it.

  **Upgrade note:** the adapter's exact node-property index (`prop_exact.idx`
  and `prop_rev.idx`) hashes a number by its value now, and each entry of
  MERGE's index records whether other nodes hold its key.
  - A file written by an earlier version is stale. The first open of each
    graph after the upgrade rebuilds the exact index in the background.
    Until that rebuild ends (the code estimates about 14 minutes at 14.27M
    nodes), writes wait for it, not only the reads the index serves: every
    write that updates the index (CREATE of a node with properties, SET,
    REMOVE, DELETE, and the server's bulk CREATE and MERGE, which waits
    before it takes its locks whether it then matches or creates). A lookup
    that must find the holders of a MERGE key does not wait: it scans the
    label instead.
  - All three hydration snapshots (`hydration_counters.snap`,
    `hydration_labels.snap` and `hydration_merge.snap`, format 5) are
    invalidated, so the first open of each graph does a full hydration scan.
  - A rollback rebuilds too: v0.8.22 finds these files stale and rebuilds
    from a scan the same way.
  - Memory: MERGE's index (by default it holds every property; lean mode
    holds the MERGE keys only) now also holds a DOUBLE or DECIMAL property
    whose value is an integer, and an integer's key is 9 bytes (v0.8.22
    stored its text). Measured against v0.8.22, 2000 nodes with an INT, a
    DOUBLE and a DECIMAL property: 2000 entries in both (15b9aa0e: 6000),
    139 KB in memory against 128 KB, and `hydration_merge.snap` 92 KB
    against 81 KB. 25,000 nodes of a mixed schema (ids, strings, prices,
    ratings, coordinates): 55,767 entries against 55,502 (15b9aa0e: 90,543),
    4.7 MB against 4.6 MB, and a 2.9 MB snapshot against 2.7 MB. (A string
    or boolean key carries a one-byte tag: 30 KB of the 25,000 nodes' keys.)

- **MERGE sees a label that SET added and forgets one REMOVE took
  (SONNY-3109):** MERGE's property index is keyed by label, and `SET n:L` and
  `REMOVE n:L` did not update it. After `SET n:L`, `MERGE (:L {x: 1})` did
  not find the node and created a second one, on the executor and the
  server's bulk MERGE. After `REMOVE n:L`, the server's bulk MERGE matched
  the node that no longer carries L, and the legacy executor's
  `MATCH (n:L {x: 1})` returned it. A label added or removed now updates the
  node's entries under that label, and those of a registered composite key,
  as a node created with the label or deleted does.

- **Grouped queries report their errors (SONNY-2675):**
  - **Behaviour change:** a HAVING name that is no column, binding or
    parameter is refused with 42703; it was NULL.
  - **Behaviour change:** a grouping error (an ungrouped input column in a
    grouped HAVING or RETURN, a nested aggregate, an aggregate in a row
    filter) reaches the client as 42803; it was 42000.
  - An error that belongs to the query, not to one row, now fails a grouped
    query: an unknown function, a missing positional parameter, strict
    tenancy, an encrypted field searched without permission (42501), the read
    and write budgets, a cancel. Each was a skipped row, so the aggregate ran
    over the other rows.
  - `sum()` and `avg()` refuse every non-numeric input with a type error;
    they skipped a date, a list or an interval. A SmallInt or a BigInt is
    summed (it was skipped), and an integer sum past i64 continues as a
    double.

    **Known deviation:** ISO/IEC 39075 (following SQL's exact-numeric rules)
    implies an integer SUM past i64 should raise 22003. The shared
    projection continues it as a double (the value's magnitude is kept, its
    last digits are not), matching the GROUP BY fast path, until both paths
    converge on 22003.
- **Group and DISTINCT keys keep their type (SONNY-2675, SONNY-2735):** a
  GROUP BY, `count(DISTINCT)`, RETURN DISTINCT and WITH DISTINCT key keeps
  its type and value. Doubles, dates, decimals, texts, UUIDs and lists group
  by value; 1, '1', 'null' and NULL are four groups; a `|` inside a string no
  longer moves a key boundary. Keys were text, with "?" or "Other" for most
  types, so DISTINCT over doubles or dates returned one row whenever the
  streaming fast path declined (with ORDER BY, say). Keys now agree with the
  value order: numbers by their exact value (DECIMAL 0.5 equals DOUBLE 0.5,
  DECIMAL 0.1 does not equal DOUBLE 0.1), every NaN is one value, and a time
  with a time zone keys by its UTC time of day.

  **Behaviour change:** durations follow the standard's two kinds
  (ISO/IEC 39075 keeps year-to-month and day-to-second durations apart):
  - a month is not 30 days: 1 month and 30 days are two groups, and
    `duration('P1M') = duration('P30D')` is false (it was true);
  - a day is 24 hours: P1D and PT24H are one group, and equal;
  - ORDER BY, min and max order intervals by months, then by their
    day-to-second length;
  - `<`, `<=`, `>` and `>=` in WHERE and HAVING are defined when the months
    or the day-to-second lengths of the two sides are equal
    (`P1M < P2M`, `P1D < PT25H`); a year-to-month duration against a
    day-to-second one (`P1M < P30D`) raises 22G04 (values not comparable).
    They used to count a month as 30 days. The rule is conservative: it asks
    for one equal part, so `P1M1D < P2M` raises 22G04 although it holds for
    any month length.
  - A time with a time zone compares by its UTC time of day, the UTC time
    modulo 24 hours, in `=`, `<`, `>`, ORDER BY and the groups:
    `10:00+01:00 = 09:00+00:00`, and `01:00+14:00 = 11:00+00:00` (it was
    -13:00 UTC and sorted first). `=` compared the local time and the
    offset, and `<` and `>` were a type mismatch; a zoned datetime's `<` and
    `>` compare its UTC instant, as ORDER BY does.
  - **Behaviour change:** `x IN [a, b]` is `x = a OR x = b`, for a literal
    list, a list expression (`x IN $list`) and a subquery
    (`x IN (MATCH ... RETURN v)`, its first column) alike. (Geode reads
    parentheses after IN as a subquery; a list is written in brackets.) An
    item is in the list when `=` calls it equal, whatever its type
    (`1.50 IN [1.5]`, `1 IN [1.0]` and a DOUBLE 1.5 in `[1.5]` are true;
    they were false, and `1.5 IN (<a subquery returning 1.5>)` was false
    too, so NOT IN kept that row). The result is NULL when no item is equal
    and some comparison is NULL (`2 IN $list` with `$list = [1, NULL]` was
    false), and FALSE for an empty list or subquery, even for a NULL value
    (`NULL IN (<no rows>)` was NULL). `=`, `<` and `>` compare INT,
    SMALLINT, BIGINT and DECIMAL values by their exact value at any scale:
    `1 = <a scale-40 decimal>` is false (it failed with 0A000), and a
    SMALLINT or BIGINT parameter compares with an INT (a type mismatch).
  - IN evaluates `x = item` left to right and stops at the first item that
    is equal, as the OR it stands for does. An item `=` cannot compare with
    the value raises the error `=` raises, but only if IN reaches it:
    `'a' IN ['a', 1.5]` is true, while `'a' IN [1.5, 'a']` is a type
    mismatch, as `'a' = 1.5` is. (It was false.)
  - **Known divergence:** a WHERE predicate that raises for some rows, such
    as a property holding a string on one node and a number on another
    against `IN [1.5]`, fails the query on a legacy session (in memory,
    RLS or tenant-scoped), while the planned read of a persisted session
    counts an error as no match and returns the other rows (SONNY-2811).
- **min, max and ORDER BY order every value type (SONNY-2675):** min and max
  compared only integers and strings, so over doubles, decimals, dates or
  mixed numbers the first value won, and ORDER BY ranked doubles, temporal
  values and node or edge ids as equal. They now share one value order:
  numbers by exact value with NaN last, strings by bytes, dates, times,
  timestamps and intervals by their own order, booleans, then ids. The GROUP
  BY fast paths fold min and max exactly, a decimal included, so an ungrouped
  min or max over decimals or dates on a tenant-scoped session no longer
  answers NULL.

  **Upgrade note:** distributed merges use the new order too. During a
  rolling upgrade, a mixed-version cluster can merge distributed results out
  of order, because nodes still on the old order rank doubles, temporal
  values and ids as equal.
- **Writes behind an aggregating or DISTINCT RETURN are applied to every
  matched row (SONNY-2694):** the read fast paths answered a CREATE, MERGE
  or DELETE behind `count(*)`, sum, min, max, DISTINCT or a counted WHERE by
  reading, and wrote nothing; behind them MATCH ... CREATE and MATCH ...
  MERGE wrote once per RETURN row (once, for an aggregate), and a SET or
  REMOVE through a relationship or variable-length pattern was dropped. No
  read fast path answers a statement that writes; every write runs once per
  matched row, and the RETURN is computed over those rows.
  - **Behaviour change:** a CREATE's property values see the matched row
    and the parameters (`MATCH (n) CREATE (:Z {k: n.i})` wrote null).
  - **Behaviour change:** a DELETE's RETURN returns what it asks for,
    computed over the rows the statement deletes before it deletes them; it
    returned `deleted_count` whatever it asked for.
  - **Behaviour change:** `MATCH ... SET ... DELETE` (and REMOVE) deletes; the
    DELETE was dropped.
  - **Behaviour change:** a RETURN after DELETE that would return an element
    the statement deletes (the node, the edge, a path through one), or a
    JSONB, XML, URL, DOMAIN, bit string or extended value, is refused with
    0A000 before anything is written; return the element's properties or an
    aggregate instead.
  - A DELETE's RETURN of a relationship's property, `type(r)`, `keys(r)` or
    `collect(r.w)` returned freed memory on in-memory, tenant-scoped and RLS
    sessions; it now owns every value it returns, and frees the typed
    strings it copies (they leaked, SONNY-3045).
- **A SET or REMOVE through a variable-length pattern writes the path's ends
  (SONNY-2707 part 1):** `MATCH (a)-[*1..2]->(b) SET b.x = 1` matched and
  wrote nothing. It writes the start or end node of every path, once per
  path, through nodes the session may read; a LIMIT is no longer pushed into
  a traversal that writes.
  - **Behaviour change:** a SET or REMOVE on the variable-length relationship
    variable (the list of its edges) or on a path variable is refused with
    0A000; it was ignored. In a multi-hop pattern too (SONNY-3045).
- **Statements that write are accepted only in allowlisted shapes
  (SONNY-3139, SONNY-3146, SONNY-3166, SONNY-3182, SONNY-3183, SONNY-3184,
  SONNY-3190):** the write-shape validator of the fixes below refused the
  write shapes known to be broken, and each review found more that wrote the
  wrong rows or dropped a write: a SELECT projection before a write made it
  write every matched row; a path DELETE deleted nothing in a plain
  persisted session (the default server); the parser split a statement in
  two where no `;` was, and ran the tail as a statement of its own with its
  variables unbound (`... SET q.x = 1 DETACH DELETE q` dropped the DELETE,
  `... SET ... MATCH (q:Q) DELETE q` deleted every :Q, a trailing CREATE made
  unlinked nodes); a write inside an IN subquery, a RETURN or a CTE body ran
  unchecked, once per outer row, under the read lock; `WITH 5 AS k ... WHERE
  n.i = $k` read 5, not the client's `$k`; `UNWIND l AS n MATCH (n:G) SET`
  wrote every :G; an unbound variable was read as null (`WITH nosuch AS k
  ... SET` wrote nothing, `SET n.y = nosuch` stored null); a WHERE after an
  OPTIONAL MATCH filtered the whole row. The validator is now an ALLOWLIST: a
  statement that writes is accepted only when its whole shape is one of the
  shapes listed under Known limitations below, each verified in the
  in-memory, plain persisted, tenant-scoped and RLS-policy sessions; anything
  else is refused with 0A000 before anything is written.
  - **Behaviour change:** a statement ends at a `;` (SONNY-3166). Two
    statements without one between them are a syntax error, in a program and
    in a `START TRANSACTION { ... }` body.
  - **A program is checked whole before any statement runs (SONNY-3166):** a
    later statement's refusal came after an earlier one had written.
  - **No write inside an expression (SONNY-3182):** an IN or NOT IN subquery
    that writes, anywhere (a WHERE, a SET value, a RETURN, a property map),
    and a CTE body that writes are refused, in a read too, and the lock, the
    read-only floor and the cluster gate classify such a statement as a
    write.
  - **The write fast paths serve only an allowlisted shape (SONNY-3166):**
    QUIC's bulk-ingest CREATE and MERGE, the key-resolved MERGE and
    `/*+BATCH*/` skip the executor; each now serves a statement only when the
    validator accepts it, and checks its own shape by a compile-time walk
    over every field of the statement.
  - **A parse is linear in its clauses (SONNY-3190):** consecutive SET,
    REMOVE and CREATE clauses rebuilt the clause list for each new clause
    (32,000 SET clauses took 40 s and about 62 GB, before authorization).
    They are appended to one list, and a query part may carry at most 1024
    SET, REMOVE, CREATE and MERGE clauses (54000 beyond).
  - **A UNION's later parts run over the first part's bindings by one rule
    (SONNY-3183):** the executor decided by what the first part returned and
    the validator by whether it had a CREATE, so a FOR body's CREATE in the
    first part dropped a later part's write the validator had accepted.
- **A PROFILE'd statement passes the allowlist on every transport
  (SONNY-3139, SONNY-3182, SONNY-3184):** the QUIC and gRPC PROFILE arms ran
  the statement a PROFILE wraps through the planned runtime, which reached
  the query dispatcher with no write-shape check: `PROFILE WITH 1 AS one
  SELECT 2 AS two MATCH (n:G) WHERE n.i = 5 SET n.x = 1` wrote every :G,
  `PROFILE MATCH (n:G) SET n.x = 1, nn.y = 2` wrote every row, a write inside
  an IN subquery ran once per outer row, and in a cluster these were
  replicated unvalidated. Both arms now validate the whole program (and its
  parameters) first, and the planned runtime declines any query that writes,
  so a write always runs through the validated dispatcher.
- **One walk decides whether a statement writes, at any depth (SONNY-3182):**
  the walk that decided whether a nested query writes skipped its initial
  WITH and that WITH's WHERE, so `MATCH (n:G) WHERE n.i IN (WITH (1 IN (MATCH
  (w:Q) SET w.hit = 1 RETURN 1)) AS b MATCH (m:G) RETURN m.i) RETURN
  count(*)` validated, was classified as a read, and wrote once per outer
  row under the read lock, past a read-only role and the cluster gate; the
  initial WHERE and a CTE body's initial WITH did the same, and so did a
  hidden CREATE. The validator, the lock and gate classification
  (`isQueryMutating`) and a UNION arm's re-run check now share one walk over
  every field of every statement, query and expression (a new field is
  walked without being named); it keeps its own stack, so 20,000 `OR` terms
  no longer overflow the thread (SONNY-3244). A CALL, CALL { } or FOR inside
  an IN subquery or a CTE body still counts as a write (a read so written is
  refused; round-3 review M1, SONNY-3248). The fast-path shape check judges a
  RETURN clause and a pattern by each of their fields, as it does a query,
  so a field added to either is not taken as empty (round-3 review M5,
  SONNY-3248).
- **A write statement reads its own variables (SONNY-3240):** MERGE's ON
  CREATE SET, ON MATCH SET and a bare SET after it evaluated with no variable
  bound, so `MERGE (z:Z {k: 1}) ON CREATE SET z.n = 0 ON MATCH SET z.n = z.n +
  1` left n null, `MERGE ... SET z.n = coalesce(z.n, -1) + 1` wrote 0 every
  time, and a later chain read an earlier one's variables as null (`CREATE
  (a:Z {k: 1}), (b:Z {k: a.k + 1})` stored b.k null; the same for INSERT,
  `MERGE (a) MERGE (b {k: a.k + 1})`, MATCH ... CREATE and MATCH ... MERGE).
  This was in the released v0.8.20: go/oidc's JTI replay guard (`ON MATCH SET
  j.first_use = CASE WHEN j.expires_at > $now ...`) answered "first use" to a
  replay, and a TOTP re-enrollment (`CASE WHEN t.verified = true THEN
  t.totp_secret_enc ELSE ...`) overwrote a verified secret. Each executor
  (CREATE, INSERT, MERGE and their per-row forms, the SET after a CREATE,
  and the cluster leader's MERGE and MATCH ... SET) now binds each variable a
  chain makes for the chains after it, and every variable of the pattern for
  the SET clauses and the RETURN.
  - **Behaviour change:** a MERGE's ON CREATE / ON MATCH / bare SET run after
    every chain of the pattern (they follow the last MERGE clause), each on
    the variables that chain created or matched; a chain's property map may
    name only what the chains before it bind, and a forward reference
    (`CREATE (a {k: b.k}), (b {k: 5})`) is refused with 0A000 (it stored
    null). The write-shape validator's scope and the executors' binding are
    checked against each other (`test-sonny-write-allowlist-r4`).
- **SET evaluates a clause before it assigns it, with or without RETURN
  (SONNY-3242):** a RETURN routed MATCH ... SET to the write step and its
  absence to the traversals, which evaluated differently: `SET q.a = 1, q.b =
  q.a` stored b = 1 with a RETURN and the old a without; a swap `SET q.a =
  q.b, q.b = q.a` stored (b, b) with one and swapped without; a relationship
  read what the clause before had written. Geode had no documented rule, so
  it follows ISO GQL / openCypher: every right-hand side of one SET clause is
  evaluated against the bindings as they stood before the clause, then its
  assignments apply; a later SET clause (`SET q.a = 1 SET q.b = q.a`) reads
  what the one before wrote. Every SET and REMOVE of a MATCH runs in the one
  write step (a RETURN after it still shows what was written); MERGE's
  actions, the SET after a CREATE, and the cluster leader's MATCH ... SET
  (SONNY-3246's ordering part; its RLS check and WHERE truthiness remain)
  follow the same rule. The QUIC MERGE fast paths decline a MERGE whose
  actions hold more than one SET clause (`ON CREATE SET ... SET ...`), which
  they applied on the wrong branch (round-3 review I1, SONNY-3241; the
  MATCH ... CREATE edge fast path is not yet fixed).
  - **Behaviour change:** `SET a.c = coalesce(a.c, 0) + 1, b.c =
    coalesce(b.c, 0) + 1` with a and b the same node stores 1, not 2, and
    `SET a.c = b.i, b.c = a.c` stores b's old c. A MATCH ... SET or REMOVE
    without a RETURN answers the rows it wrote, as written.
- **A comma pattern binds every chain (SONNY-3318):** in a MATCH whose
  first chain has a relationship, a later chain of one node was skipped, so
  its variable was null: `MATCH (g:G)-[:R]->(x:X), (q:Q {i: 2}) SET q.c = 1`
  returned its rows and wrote nothing (a WHERE on q and a DETACH DELETE of q
  did the same), and the read counted q as 0. A later chain with a
  relationship read only its first hop, ignored its relationship's
  properties, and re-bound a variable an earlier chain had bound instead of
  joining on it (`MATCH (g {i: 1})-[:R]->(x), (a:G)-[:R]->(x)` returned
  every a). Each chain is now joined to the rows so far by one routine: its
  first node is an earlier chain's variable (checked against the pattern) or
  every visible node that matches, and each hop is walked with its types,
  direction, properties and scope, a bound far node or relationship having
  to be the one reached. The executor also never aggregated (`RETURN
  count(*)` gave one row per match); an aggregate over such a pattern now
  goes through the shared projection. The bug predates round 4a: it was the
  read's own; round 4a routed every SET through that read.
- **A label SET beside a vector SET checks the new label's index
  (SONNY-3319):** round 4a's pre-pass checked a SET's vector against the
  labels the node had before the statement, and so did each assignment, so
  `MATCH (n:VO) SET n:VD, n.emb = <2 dimensions>` stored the vector in VD's
  4-dimension HNSW index (the MERGE and CREATE ... SET forms too), and the
  next vector SET crashed: the failed index rebuild freed the index's name,
  which was then logged. The pre-pass and every node property write use the
  labels the node carries with the SET's own labels, the write is refused
  before anything is stored (22000), and an index name is copied before a
  rebuild.
- **Chained MERGE actions fire on the last MERGE clause (SONNY-3320):**
  round 4a keyed ON CREATE / ON MATCH on each target variable's own state,
  so `MERGE (v0:W {k: 1}) MERGE (v1:W {k: 2}) ON CREATE SET v0.ref = ...`
  wrote nothing when v1 was created and v0 matched, and wrote when v0 was
  created and v1 matched. The actions belong to the last MERGE clause (the
  parser ends a run of MERGE clauses at the first action): ON CREATE SET
  runs when that clause created any part of its pattern, ON MATCH SET when
  it matched it, on whichever variable they name. A single MERGE (go/oidc's
  ClaimJTI and TOTP statements) is unchanged.
- **The node-scan stream serves only the fields it reads (SONNY-3321):** the
  QUIC and gRPC engine-direct stream judged a statement by a hand-written
  list that missed `LET $x = ...` and applied only one of a WHERE and a
  FILTER, so `LET $x = 1 IN (MATCH (w) SET ... RETURN 1) MATCH (n:G) RETURN
  count(*)` was answered before the write-shape validator could refuse it,
  `LET $x = 2 MATCH (n:G) WHERE n.i = $x RETURN n` returned nothing, and
  `WHERE n.i > 0 FILTER n.i < 3` returned 9 rows, not 2. The stream now
  serves a statement only when every field it does not read is empty,
  checked field by field at compile time, and never a WHERE with a FILTER.
- **A CREATE's relationship variable is read after every insert
  (SONNY-3322):** CREATE, INSERT, MATCH ... CREATE and MERGE held each
  relationship they made as the store's pointer to it, and a later edge
  insert can move the store's edges: `CREATE (a)-[r:T {w: 3}]->(b), <150
  more relationship chains> RETURN r.w, type(r)` crashed the server, and at
  about 600 returned null. They hold the relationship's id, and read it once
  every chain has inserted; a relationship a later chain or a MERGE action
  reads is the statement's own copy.
- **The parser's limits (SONNY-3244):** parsing runs before authorization,
  and 25,000 `MATCH (n:G) SET n.x = 1;` statements (625 KB) took a 741 MB
  parser arena, so a 16 MB request could hold about 19 GB; about 60 chained
  WITH, or nested `CALL {` or `IN (`, overflowed the thread in a Debug build.
  A request may now carry at most 1,024 statements, counting those nested in
  others, and the parser at most 64 MiB (checked every 1,024 tokens, at every
  statement and query part, and at the end): past either, 54000 with a
  message that names the limit. Queries may nest at most 10 deep (WITH chain
  parts, CALL { }, IN (subquery), FOR bodies, CTE bodies): past it, 54001.
  Measured on a fresh thread, a Debug build overflows 8 MiB at 16 nested FOR
  bodies (19 IN subqueries, 22 WITH parts) and 16 MiB at 35; ReleaseSafe
  overflows 8 MiB at 156, and 1 MiB at 11. A parser limit now answers its
  class-54 code over QUIC and gRPC (it answered 42000).
- **An unsupplied parameter is refused (SONNY-3247):** a named parameter the
  request did not supply read as null, so `SET q.name = $nosuch` erased the
  property, `LIMIT $nosuch` wrote every row, and a MERGE keyed on one merged
  on null (the QUIC MERGE fast path too). Every parameter a statement names
  (an expression, a property map, a SET value, a MERGE key, LIMIT or SKIP, a
  subquery, a CTE body, a FOR's list) must be supplied by the request or
  defined by the statement's own `LET $x = ...`; otherwise the statement is
  refused before anything runs, with 42P02 (undefined_parameter). A variable
  a WITH, UNWIND or FOR binds is not a parameter: `WITH 5 AS k ... $k` is
  refused too.
  - **Behaviour change:** an out-of-range positional parameter (GAP-0926)
    answers 42P02, not 22023. go/oidc and sonny-upstream supply every
    parameter they reference (go/oidc's driver writes its `?` values into the
    text).
- **A SET or REMOVE after a WITH writes only the rows the WITH keeps
  (SONNY-3039, SONNY-3140, SONNY-3141, SONNY-3142):** the traversals wrote as
  they read, before the WITH, the WHERE after it, and its ORDER BY and LIMIT
  dropped rows: `MATCH (n:G) WITH n WHERE n.i >= 7 SET n.x = 1 RETURN
  count(*)` returned 3 and wrote every :G. A SET or REMOVE after a WITH now
  runs in one write step over the rows the WITH keeps, once per row, and a
  RETURN after it sees what was written. The write executors read those rows
  as the planned read runs a WITH: the WHERE before the WITH on the pattern's
  rows (the parser joined it to the one after the WITH, and it was evaluated
  over the WITH's rows, so `MATCH (n:G) WHERE n.i >= 7 WITH n AS m SET m.x =
  1` wrote nothing), then the projection with the WITH's GROUP BY and HAVING
  (dropped: every row was written), DISTINCT (ignored: `WITH DISTINCT n.g AS
  g CREATE (:Z {g: g})` created one node per match), ORDER BY, SKIP and
  LIMIT (a literal or a parameter), then the WHERE after it. This holds for a
  SET, REMOVE or DELETE after the WITH and for MATCH ... WITH ... CREATE or
  MERGE, in every pattern shape.
- **A write after a WITH that starts a new query part is applied or refused
  (SONNY-3040):** the chain executor never applied a CREATE, MERGE, SET,
  REMOVE or DELETE in a part after the first: `MATCH (n:G) WITH n CREATE
  (n)-[:T]->(:Z)` created nothing, and `MATCH (q:Q) WITH q MATCH (q) DELETE
  q` deleted nothing. `MATCH ... WITH ... CREATE` and `MATCH ... WITH ...
  MERGE` now run as MATCH ... CREATE or MERGE over the WITH's rows; any other
  chained write is refused (0A000, SONNY-3111) before any part runs.
- **A SET or REMOVE on a comma pattern or after an OPTIONAL MATCH writes
  every matched row (SONNY-3041):** those executors never read the SET and
  REMOVE clauses, so the statement returned its rows and wrote nothing. They
  run in the one write step; a variable an OPTIONAL MATCH did not bind is
  skipped on that row. The OPTIONAL MATCH accepted before a write is one
  chain, after the MATCH, that shares a variable with it, with no WHERE after
  it (SONNY-3184).
- **One validator decides, before a statement runs, whether each part's
  executor applies all of its writes (SONNY-3139 .. SONNY-3146):** the guard
  of the previous fix sat in some executors only, so the executors that did
  not call it still dropped writes, and a refusal inside one part came after
  an earlier UNION part had written. The statement dispatcher now checks
  every part of a statement (UNION parts, the parts of a chain, FOR bodies,
  the statement a PROFILE wraps, a CALL { } body) before any part runs. For
  each part it decides the executor that will run it (the query dispatcher
  switches on the same decision), and checks against that executor's row in
  one table that the executor applies every write clause (CREATE, MERGE and
  its ON CREATE / ON MATCH SET, SET, REMOVE, DELETE), that every SET, REMOVE
  and DELETE target is bound in that part to a node or a relationship, and
  that it honours every WITH feature before the write. (It refused only the
  shapes it modelled; the allowlist above replaces that.)
  - **An initial WITH is bound before the pattern (SONNY-3139):** a SET or
    REMOVE after `WITH ... MATCH` wrote every matched row (the initial WITH
    was applied as a projection after the traversal had written, and the
    WHERE was deferred past it), a CREATE after it created nothing, a MERGE
    after it read its variables as null, and its own WHERE was ignored or
    replaced by the MATCH's. A statement that writes after an initial WITH
    now evaluates the WITH once and runs with its values bound as parameters;
    its WHERE, SKIP and LIMIT decide whether the statement writes at all,
    under PROFILE too. A SELECT projection is not an initial WITH: a write
    after one is refused (it wrote every matched row).
  - **UNWIND before a write runs once per element (SONNY-3144):** no executor
    applied an UNWIND before a write: `WITH $rows AS rows UNWIND rows AS r
    CREATE (:U {id: r.id})` created one node with every property null, and
    `WITH ... UNWIND l AS u MATCH (n) WHERE n.i = u SET ...` read u as null
    and wrote every matched node. The statement now runs once per element,
    the element bound as a parameter, as a FOR body does. A statement still
    cannot start with UNWIND (it is not GQL): write `FOR r IN $rows CREATE
    ...`.
  - **A WHERE on a disconnected OPTIONAL MATCH filters after it
    (SONNY-3144):** `MATCH (q:Q) OPTIONAL MATCH (n:G) WHERE n.i = q.i RETURN
    ...` returned no row: the WHERE was evaluated on the first MATCH's rows,
    before n was bound. A WHERE that names any variable only a later pattern
    binds is applied after the optional matching. It still filters the whole
    row, not the optional part (SONNY-3184), so a write after it is refused.
  - **A DELETE of a variable-length relationship deletes its edges
    (SONNY-3146):** `DELETE r` on `-[r:R*1..2]->` deleted nothing (with a SET
    beside it, the SET ran and the DELETE was dropped). A DELETE of a path
    (`DETACH DELETE p`) is refused with 0A000: it deleted nothing in a plain
    persisted session, nor a single-node path or a path in a later comma
    chain in any session.
  - **No CREATE clause is lost (SONNY-3146):** a CREATE after a DELETE
    replaced a CREATE before it (`... CREATE (z:Z) DELETE q CREATE (w:W)`
    never created z). The parser keeps both, and the statement is refused.
  - **MATCH ... CREATE checks its SET before it creates (SONNY-3145):** a SET
    target or value refused after the CREATE ran left what it created (`SET
    y.k` on an unbound y, `SET r.k` on a variable-length relationship, `SET
    r:Foo`, a node as a property value).
  - **Consecutive SET clauses are one list (SONNY-3146):** `SET n.x = 1 SET
    n.y = 2` was a syntax error; so were two REMOVE clauses in a row. A SET
    after a REMOVE stays a syntax error.
  - **Behaviour change:** MATCH ... CREATE and MATCH ... MERGE with a WITH
    after the CREATE or MERGE are refused (SONNY-3143, a regression from the
    SONNY-3043 fix): `MATCH (n:G) CREATE (n)-[:T]->(z:Z) WITH z SET z.k = 1`
    created a junk node per row and never set k, and with a WHERE created
    nothing. MATCH ... WITH ... CREATE and MATCH ... WITH ... MERGE still run
    over the WITH's rows.
- **A statement refused for its DELETE writes nothing (SONNY-3042):** the
  DELETE's checks ran after the writes before it, so `MATCH (q:Q) SET q.x =
  1 DELETE q RETURN q` was refused with every q.x set, and `MATCH (x:X)<-[:R]-()
  SET x.x = 1 DELETE x` refused NodeHasEdges with x.x set. A node the DELETE
  removes must have no edge (none now, and none a CREATE in the statement
  attaches), and the RETURN must hold nothing it deletes, before any SET,
  REMOVE or CREATE.
- **MATCH ... CREATE applies its SET, REMOVE and DELETE (SONNY-3043):** a SET
  on a variable the CREATE made was dropped (`CREATE (z:Z) SET z.k = 5` left
  z.k null), a DELETE of a matched relationship was skipped, and a MERGE
  beside a CREATE or a DELETE was dropped. The CREATE, SET and REMOVE, RETURN
  and DELETE now run in order over the matched rows.
  - **Behaviour change:** a DELETE (without DETACH) of a node that has an
    edge after a CREATE refuses the statement with NodeHasEdges, as any
    DELETE does; it silently removed the node's edges.
  - **Behaviour change:** MERGE with CREATE, MERGE with DELETE, and a DELETE
    of a variable the CREATE introduces are refused with 0A000 (SONNY-3111).
- **A cluster DELETE returns its RETURN (SONNY-3044):** a cluster leader
  answered a `DELETE ... RETURN` with `deleted_count` whatever it asked for,
  so a cluster answered differently from a standalone server. It computes
  the RETURN over the deleted rows before it proposes the delete.

### Changed

- **More GROUP BY shapes materialize every row (SONNY-2675):** a GROUP BY on
  a text, a list or a document key, and a min or max over a string, an enum
  or a document, no longer stream on the GROUP BY fast path. The shared
  projection computes them, which materializes every input row and can reach
  the read budget (`GEODE_READ_EXECUTOR_BUDGET_MB`) on a large input.

### Known limitations

- **In lean mode, the server's MERGE of a number that is not an integer
  scans the label (SONNY-3056):** with `GEODE_INDEX_MERGE_KEYS_ONLY=1`, the
  exact node-property index holds no value of a key registered after its
  nodes were written, so a bulk MERGE (`bulkMergeNode*`) of a key whose
  value is a DECIMAL or DOUBLE that is not an integer (1.5) finds the key's
  holder by scanning the label's nodes, on every call. Measured with
  100,000 nodes of the label: about 115 ms per MERGE on average (349 ms at
  most), against 0.2 ms for an integer key, which MERGE's index answers.
  The cost grows with the label. A lookup that settles an entry whose
  lowest holder was removed scans the label in lean mode too. The default
  (lean mode off) reads the exact index instead.
- **ROLLBACK undoes only what a transaction created.** The undo log
  records the nodes and edges a CREATE or a MERGE creates, and nothing
  else. A SET, a REMOVE, a DELETE, a label change, and a change MERGE makes
  to a node or edge it matched stay after ROLLBACK, and after a failed
  statement's rollback. Until that is fixed, do not rely on ROLLBACK to
  undo changes to existing data.
- **A transaction is not crash-atomic (SONNY-2979).** 15 of the 16 shards
  commit each operation on its own, and the undo log lives in memory only.
  A crash (a kill or a power loss) in the middle of a transaction leaves
  the operations run so far applied, and nothing rolls them back at
  restart.
- **Index DDL runs on the default graph, and indexes are database-wide
  (SONNY-2803):** DROP INDEX and a fulltext CREATE INDEX need the schema
  permission on `default`, whatever the session's graph, because they run
  on it (SONNY-2790). Indexes and constraints are catalogued for the whole
  database, but the permission is checked on one graph, so a user with
  `FOR SCHEMA` on `default` can drop an index created from another graph
  (SONNY-3030).
- **Offline auth commands need the HMAC key (SONNY-2798):** on a store that
  holds any security record, an offline command refuses, and changes
  nothing, when no HMAC key is available to verify the chain with. Set
  `GEODE_AUTH_HMAC_KEY` or `GEODE_TDE_KEY` as the server does, or keep
  `.geode_hmac_key` in the data directory.
- **`CALL algo.*` is slower under RLS or a tenant scope (SONNY-2685):** a
  call decides every node and edge it visits on the calling thread, and
  degree centrality computes a restricted session's degrees there rather
  than on its worker threads. A label-deny entry hides its rows from every
  session, Admin included, in the graph procedures as in MATCH
  (SONNY-2710).
- **`geode.rls.*` restrictions are memory-only (SONNY-2757, SONNY-3034):**
  the deny and attribute policies that `geode.rls.add_deny_policy` and
  `geode.rls.add_attribute_policy` add, and their removal, are lost at a
  restart and are not replicated in a cluster. Policy DDL (CREATE, ALTER
  and DROP POLICY) is durable.
- **Statements that write are accepted only in these shapes; anything else
  is refused with 0A000 before anything is written (SONNY-3111):** each is
  verified in the in-memory, plain persisted, tenant-scoped and RLS-policy
  sessions (`zig build test-sonny-write-allowlist`).
  - `CREATE <nodes and relationships> [RETURN ...]`, and the same with
    INSERT;
  - `MERGE <node or relationship pattern> [MERGE ...] [ON CREATE SET ...]
    [ON MATCH SET ...] [SET ...] [RETURN ...]`, the SETs on a variable the
    MERGE binds (a node chain's node, a relationship);
  - `MATCH <pattern> [WHERE ...] [DETACH] DELETE <node, relationship or
    variable-length relationship variables> [RETURN ...]`;
  - `MATCH <pattern> [WHERE ...] SET/REMOVE ... [RETURN ...]`, and `... [SET
    /REMOVE ...] DELETE ... [RETURN ...]`;
  - `MATCH <pattern> [WHERE ...] CREATE <pattern> [SET/REMOVE ...] [DELETE
    <matched variables>] [RETURN ...]`;
  - `MATCH <pattern> [WHERE ...] MERGE <pattern> [ON CREATE SET ...] [ON
    MATCH SET ...] [SET ...] [RETURN ...]`;
  - `MATCH <pattern> [WHERE ...] WITH <variables and values> [WHERE ...]
    [DISTINCT] [GROUP BY ... [HAVING ...]] [ORDER BY ...] [SKIP/LIMIT]`
    followed by `SET/REMOVE/DELETE ...`, or by one `CREATE` or one `MERGE`,
    `[RETURN ...]`;
  - `CREATE <pattern> [WITH <the created variables>] [SET/REMOVE <a created
    node>] [RETURN ...]`;
  - `WITH <values> [WHERE ...] [SKIP/LIMIT] MERGE <node pattern> ...`;
  - any of the MATCH and CREATE shapes after `WITH <named values> [WHERE
    ...] [SKIP/LIMIT]` (bound once, as parameters), and the MATCH ... SET,
    DELETE and CREATE shapes and CREATE after such a WITH and `UNWIND <list>
    AS x` (run once per element; the RETURN may not aggregate, be DISTINCT,
    order or window);
  - `FOR x IN <list> <one of these>`, `WITH <named values> FOR x IN <list>
    <one of these>`, `PROFILE <one of these>`, `UNION [ALL]` of MATCH ...
    SET/REMOVE/DELETE shapes, and a program of these separated by `;`
    (inside `START TRANSACTION ... COMMIT` too).

  The pattern may have comma chains, relationship hops, several hops and
  variable-length hops, and before a SET, REMOVE or DELETE (not a CREATE or
  MERGE) one OPTIONAL MATCH chain after the MATCH that shares a variable
  with it. Refused, whatever else the statement holds: a path variable
  (`p = ...`, so a path DELETE; SONNY-3146), shortestPath(), a path mode, a
  WHERE after an OPTIONAL MATCH and any other OPTIONAL MATCH (SONNY-3184),
  EXISTS { }, COUNT { } and pattern comprehensions (SONNY-3184: EXISTS {
  MATCH ... WHERE <inner variable> } was always false), a SELECT projection,
  LET, FILTER, a CTE, CALL { } and a procedure CALL, VALUES, INTERSECT and
  EXCEPT, `WITH *`, `RETURN *`, a second WITH or a MATCH after a WITH (a
  chained part: SONNY-3040, SONNY-3046), a WITH after a CREATE or MERGE
  that follows a MATCH (SONNY-3143), a CREATE or MERGE after a WITH's GROUP
  BY or HAVING, an UNWIND before a WITH or a MERGE, MERGE with CREATE or
  DELETE (SONNY-3043), a DELETE of a variable the CREATE introduces, a
  CREATE on both sides of a DELETE (SONNY-3146), a SET or REMOVE on a
  relationship a CREATE without MATCH creates or on anything the part does
  not bind to a node or relationship (SONNY-3144), a SET or REMOVE on a
  variable-length relationship or a path (SONNY-2707), a grouped RETURN
  after a CREATE, MERGE or DELETE (SONNY-2683), a variable an expression
  names that is not bound where it is evaluated (SONNY-3183), a name an
  initial WITH, an UNWIND or a FOR binds that is also a pattern variable or
  a client parameter (SONNY-3183), a label SET or REMOVE inside an explicit
  transaction (a rolled-back `SET n:L` kept its label postings, SONNY-3059),
  and a write inside an expression (SONNY-3182). Split such a statement.
  Inside an explicit transaction the other shapes are accepted, but ROLLBACK
  does not undo a property SET, a REMOVE, a DELETE or a MERGE's SET
  (SONNY-3059, see above; not only a label), and a rolled-back MATCH ...
  CREATE can leave a node behind (round-3 review I7, round 4b).
- **Parser limits (SONNY-3244):** a request carries at most 1,024
  statements and at most 64 MiB of parsed form (54000); queries nest at most
  10 deep (54001). A Debug build's QUIC connection admission threads have
  1 MiB of stack, which a nested query overflows before any limit applies
  (the round-14 branch gives them 16 MiB, SONNY-3191).
- **A statement ends at a `;` (SONNY-3166):** the parser used to split two
  statements written without a `;` between them and run each on its own;
  that is now a syntax error (42601). Programs that relied on it (`CREATE
  ... CREATE ...` and `MERGE ... MERGE ...` stay one statement) need a `;`.
- **Reads that are wrong on the legacy path (SONNY-3167, SONNY-3184):** a
  read through a hop pattern ignores WITH DISTINCT on the in-memory and RLS
  paths (X2); `CALL { }` returns the subquery's rows instead of the outer
  RETURN; EXISTS { MATCH ... WHERE <inner variable> } is always false; an
  OPTIONAL MATCH chained on another OPTIONAL MATCH binds null; a WHERE after
  an OPTIONAL MATCH filters the whole row; a WHERE after `WITH ...` before
  a FOR is not applied. Writes in these shapes are refused. v0.8.24.
- **A chained MATCH does not join on the WITH's variables (SONNY-3046):**
  `MATCH (q:Q) WITH q MATCH (q) RETURN count(*)` counts every node for each
  q. v0.8.24; a chained MATCH that writes is refused until then.
- **A plain RETURN after MATCH ... CREATE is one row (SONNY-3025):** a RETURN
  that neither aggregates nor is DISTINCT is evaluated once, over the last
  row's created and matched elements; the CREATE itself runs once per
  matched row. Aggregate the RETURN, or make it DISTINCT, to see every row.
  v0.8.24.

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
