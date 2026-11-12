# Changelog

## [Unreleased] - Time-Series Audit and Gap Closure

### Security

- **BEHAVIOUR CHANGE: one FLE encryption identity; no index over an
  encrypted field (SONNY-6335).** (1) The graph-store write primitives
  encrypted a plaintext value that reached them (raft apply, internal
  callers) with the store's tenant/schema and `node_<id>` / `edge_<id>`,
  which no reader used, so those values read as `FleDecryptionFailed`
  (58030). Every writer and reader now uses one identity (request tenant,
  label or edge type, field, `<id>` / `edge_<id>`); readers also try the old
  store identity, so values already written that way decrypt. (2) `CREATE
  INDEX` of any type and `CREATE CONSTRAINT ... IS UNIQUE` / `NODE KEY` over
  an FLE-encrypted field are refused (0A000): the index held ciphertext (a
  fulltext search, a seek or a UNIQUE check never matched). `CALL
  geode.fle.configureField` on a field with such an index or constraint is
  refused (0A000; drop it first), and a fulltext index made before its field
  was encrypted refuses searches (0A000) instead of matching nothing.
  Regression: `zig build test-sonny6335-fle-identity-and-indexes`.
- **BREAKING: the FLE role is bound to the authenticated user
  (SONNY-6341).** The FLE role a session reads encrypted fields with was
  whatever its client named in HELLO (`role`, the CLI's `--role`), checked
  for shape only, so every principal GPS lets decrypt (every Admin, any
  `ALLOW DECRYPT_FIELD`) could name any FLE role and read every field
  listed for it. With authentication on, a named role now counts only when
  the user holds it: `CALL geode.fle.grantRole(user, role)` /
  `CALL geode.fle.revokeRole(user, role)` (Admin only, audited, refused in
  cluster mode; stored as `FleRoleGrant` records in the HMAC-chained
  `__geode_security` graph and loaded at startup; a grant that cannot be
  saved is not applied, 58030; a revoke that cannot be saved stays in force
  and reports 58030). A HELLO naming a role the user does not hold still
  connects, with no FLE role (encrypted fields read `[REDACTED]`), and is an
  `access_denied` audit event. Grants and revokes count from the next
  request of every live session. The Admin builtin holds no FLE role
  implicitly. Authentication off and `--insecure-allow-all`: unchanged.
  **Upgrade note:** after upgrading no user holds any FLE role; each reader
  of plaintext needs `CALL geode.fle.grantRole('<user>', '<fle role>')` by
  an Admin (an Admin grants itself too). Regression:
  `zig build test-sonny6341-fle-role-binding`.
- **BEHAVIOUR CHANGE: FLE authorization (SONNY-6334).** (1)
  `geode.fle.configureField`, `grantPlaintext`, `revokePlaintext` and the
  key-affecting `tde.*` procedures (`initialize_key_hierarchy`,
  `rotate_keys`, `configure_*`, `zeroize_keys`, `cleanup_key_hierarchy`,
  the encrypted backup/restore ones) were gated by the GPS `write` action,
  so a ReadWrite user could grant its own FLE role plaintext access or
  reconfigure a field. They are now Admin only (42501 and an
  `access_denied` audit event otherwise; authentication off: implicit
  admin; `--insecure-allow-all`: bypassed as documented). (2) Plaintext
  needed only the request's FLE role in the field's visibility roles, a
  role the client names in HELLO; the GPS `decrypt_field` check sat in a
  function nothing called, so `DENY DECRYPT_FIELD` was not enforced. A read
  of an encrypted field now also needs GPS to allow `decrypt_field` for the
  authenticated principal on the session's graph (the Admin builtin, or an
  `ALLOW DECRYPT_FIELD` policy); a refusal reads as a role not in the list
  (`[REDACTED]`, 42501 for `n.p` on a searchable field). **Upgrade note:**
  a non-Admin user that read plaintext through a listed FLE role needs an
  `ALLOW DECRYPT_FIELD` policy. (3) gRPC never put the session's FLE role
  on the thread that encodes result rows (whole nodes and edges were
  `[REDACTED]` over gRPC), and its Handshake left the role and tenant on
  the Handshake's thread for the next session served there. The FLE role
  is now kept on the gRPC session, and QUIC and gRPC install one request
  context (`ServerState.installRequestThreadState`: tenant, FLE role, GPS
  gate) per request and clear it on every exit. (4) configureField, grant
  and revoke are audit events (`configuration_change`, success or failure
  with the error name: caller, `type.field`, role or visibility roles; no
  key material). Also fixed: `CALL geode.fle.configureField(...,
  {visibility: [...]})` dropped the list (a list literal parses as
  `ArrayLit`; only `List` was read), so a field configured online was
  readable by nobody until a grant. Removed dead code:
  `fle_hooks.decryptPropertyIfNeeded`, `planner/rewrite.performFLERewrite`.
  Regression: `zig build test-sonny6334-fle-authorization`.

- **BREAKING: fail-closed default role.** A user with no stored built-in
  role (not a superuser, no `HAS_ROLE` edge to `admin`, `user`, `readwrite`
  or `readonly`) used to fall back to `readwrite` and could read and write
  every graph. It now resolves to `none`: no global read, write, schema or
  admin, and no access to any graph (the `default` graph included) except
  those it holds a per-graph grant on, where the grant works as granted
  (`READ` reads, `WRITE` writes). The bootstrap admin, `CREATE USER` (which
  stores the `user` role when no `ROLE` is given) and explicitly assigned
  roles are unchanged. Operators upgrading a store with users that have no
  role must assign one (`ALTER USER u SET ROLE readwrite`) or grant per
  graph. See docs/GQL_AUTH_DDL.md, "Users with no stored role".
  Regression: `zig build test-default-role-fail-closed`.
- **`SHOW USERS` no longer raises read-only users to `readwrite`:** the
  persistent auth resolver read a query's read snapshot, which lacks the
  security graph, and fell back to the default role.
- **Per-graph `REVOKE` removes the right grant:** grant ids above
  `maxInt(i64)` were clamped when stored, so a revoke failed (58030) or hit
  another grant, and the auth chain failed to verify at restart.
- **Per-graph `GRANT` and `REVOKE` take effect at once:** they now
  invalidate cached authorization decisions, so a revoked `READ` grant stops
  working without a restart.
- **Per-graph grants are scoped to their graph and take effect at once, for
  every role (REQ-SEC-PER-GRAPH-GRANTS).** For a user with an explicit role,
  a runtime `GRANT WRITE ON GRAPH g TO u` only took effect after a server
  restart, and from then on it allowed writes on **every** graph: grants
  reached authorization only as Policy rows migrated from them at startup,
  and the handlers' database-wide write check matched any graph-scoped allow
  policy. `REVOKE` never removed the migrated row, so a migrated grant could
  not be revoked. Now `gps.decide` reads `READ`, `WRITE` and `SCHEMA` grants
  from the live grant table for every role, on the request's graph only;
  the write gate asks for write on the graph the program changes; an allow
  policy scoped to one graph (`CREATE POLICY ... ON GRAPH g`) covers only
  that graph; and startup drops the `auto_migrated_grant_*` policies earlier
  versions created. Global role permissions are unchanged. A `FOR WRITE`
  policy that relied on a single-graph scope to allow writes everywhere must
  be re-created `ON GRAPH *`. See docs/GQL_AUTH_DDL.md, "Per-graph grant
  semantics". Regression: `zig build test-per-graph-grants`.
- **The FLE catalog is no longer kept in /tmp (SONNY-6274):** the
  field-level-encryption catalog (which fields are encrypted, their
  algorithm, key scope and blind-index setting, and the roles that may read
  them in plaintext; no key material) was saved to and loaded from
  `{GEODE_DATA_DIR or /tmp}/geode_fle_catalog.dat`. With no data directory
  every session, test and process shared `/tmp/geode_fle_catalog.dat`, so a
  fresh session took its encrypted-field set from whatever an earlier run
  left there; and only `GEODE_DATA_DIR` counted, so a server started with
  `--data-dir` alone also kept its FLE catalog in `/tmp`. The file was
  opened `O_CREAT|O_TRUNC` with the default mode (0644 under the usual
  umask), and a symbolic link planted at the path was followed on read and
  write. The FLE catalog now lives in the store's data directory (the
  `--data-dir` override, else `GEODE_DATA_DIR`); with neither it is in
  memory, as the index catalog is. It is written to a new
  `O_EXCL|O_NOFOLLOW` 0600 file renamed over the path, and a link at the
  path is refused on read. **Upgrade note:** a server that ran with
  `--data-dir` and no `GEODE_DATA_DIR` had its FLE catalog in
  `/tmp/geode_fle_catalog.dat`; it is not read from there any more. Copy
  that file into the data directory (after checking it is yours) before
  restarting. `geode fle grant-plaintext` refuses to run without
  `GEODE_DATA_DIR`, where it used to write the grant to `/tmp`.
  Regression: `zig build test-sonny6274-fle-catalog-no-tmp`.
- **BEHAVIOUR CHANGE: FLE read gaps closed (SONNY-6327).** (1) An
  encrypted EDGE property was returned as stored (the ciphertext envelope)
  to every principal by `RETURN r.p` and `WHERE r.p = ...`, and every
  whole-value read (`properties(n|r)`, map projection, `RETURN n`,
  `RETURN r` and paths over QUIC/gRPC, and JSON) sent the stored bytes for
  nodes too. All of them now use the one node policy
  (`fle_integration.readStoredString`): the plaintext role reads the
  plaintext, any other principal reads `[REDACTED]` (an `n.p`/`r.p` read
  of a searchable field is 42501, as before), and while the FLE catalog
  cannot be loaded the read is refused (58030). (2) A value the principal
  may read that does not decrypt (damaged, or written under another
  `GEODE_MASTER_KEY`) was returned as the stored bytes; it is now refused,
  `FleDecryptionFailed` (58030), also inside builtin calls, predicates and
  aggregates. `GraphStore.getNodeProperty` now returns the stored value
  and never tries to decrypt; `getNodePropertyChecked` /
  `getEdgePropertyChecked` read through the policy. (3) The FLE catalog's
  readers (`getType`, `getFieldMetadata`, the plaintext-role check, the
  `geode.fle.getFieldConfig` / `listEncryptedFields` procedures) used
  catalog memory after releasing its lock, which a reconfigure, grant or
  revoke frees (a use-after-free in the authorization decision); they now
  answer under the lock or copy, and a deployment with no FLE field skips
  FLE without a lock. (4) New online `CALL geode.fle.revokePlaintext(type,
  field, role)`, mirroring `grantPlaintext` (mutating; refused in cluster
  mode; a failed save leaves the revoke in effect and reports 58030). (5)
  The QUIC write fast paths (simple CREATE, bulk MERGE, `/*+BATCH*/`,
  `USE GRAPH g; MERGE`, MATCH ... CREATE/MERGE edge) wrote an encrypted
  field's PLAINTEXT to disk; with any FLE field configured they now
  decline to the executor, which encrypts (bulk-ingest throughput on FLE
  deployments drops to executor speed), and the aggregate/point-write
  pushdowns decline too. Regression: `zig build test-sonny6327-fle-read-gaps`.
- **BEHAVIOUR CHANGE: the FLE catalog fails closed (SONNY-6324).**
  (1) `CALL geode.fle.configureField`, `CALL geode.fle.grantPlaintext`,
  `geode fle grant-plaintext` and `geode fle revoke-plaintext` logged a
  failed catalog save and reported success, so the change was lost at the
  next start: a field the operator was told is encrypted was not, and a
  revoked role read plaintext again. A failed save is now an error (58030).
  `configureField` and a grant are undone, so nothing changed; a revoke
  stays in effect in the running process (`FleRevokeNotPersisted`: it is
  not saved, and the role has access again after a restart unless a later
  change of the catalog, such as the retried revoke, is saved). With no data
  directory the catalog is memory-only and nothing is saved. (2) A catalog
  file that existed but could not be loaded (corrupt, truncated, written
  with another `GEODE_TDE_KEY` or with none set, a symbolic link,
  unreadable) gave an empty catalog, so the fields configured as encrypted
  were written in plaintext. **The server now refuses to start** and names
  the file and the cause; an embedded or CLI session gets
  `FleCatalogUnavailable` (58030) from everything that uses the catalog,
  and the engine refuses every string property write and every read of a
  string property while it lasts (it cannot tell which fields are
  encrypted); other writes run. An absent file is still a fresh, empty
  catalog. A string value that must be encrypted and cannot be is refused
  (`EncryptionRequired`, 58030) on the graph store's own write paths too,
  which wrote it in plaintext. (3) The catalog no longer leaks field names
  and role lists, and a corrupt enum byte in the file is an error instead
  of a crash. **Upgrade note (SONNY-6274):** the engine cannot tell that a
  store holds encrypted values whose catalog was left in
  `/tmp/geode_fle_catalog.dat` (no cheap, reliable signal: the values are
  opaque strings, and a key or a `/tmp` file proves nothing about this
  store), so it does not refuse to start; it warns at startup when the data
  directory has no catalog and that file exists. Copy it over (after
  checking it is yours) before serving traffic.
  Regression: `zig build test-sonny6324-fle-catalog-fail-closed`.

### Added

- **CANARY Governance Tokens:** 24 CANARY markers added across timeseries source files (GAP-0281)
- **Legacy GAP ID Mapping:** Documented mapping from Grey Cardinal GAP-004/005/006 to GAP-0279+ numbering (GAP-0288)
- **Time-Series Audit Report:** `docs/TIMESERIES_AUDIT_REPORT.md` tracking all timeseries gap status

### Fixed

- **BEHAVIOUR CHANGE: a relationship MERGE matches on the relationship's
  properties (SONNY-3357).** `MERGE (a)-[:T {w: 1}]->(b)` then `MERGE
  (a)-[:T {w: 2}]->(b)` left one edge (`w: 1`): the edge was matched on
  endpoints, type, graph and tenant only, and the second MERGE's ON MATCH
  SET ran on it. The whole pattern now has to match, its relationship
  properties included (MERGE is a Geode extension; ISO/IEC 39075:2024 has
  no MERGE, and this follows openCypher), or MERGE creates the edge, on the
  standalone MERGE and on MATCH ... MERGE. The server's MATCH ... MERGE edge
  fast path matched the same way and wrote the pattern's properties onto
  whatever edge it found; a relationship with properties now goes to the
  executor. A MERGE with no relationship properties is unchanged.
  Regression: `zig build test-sonny3357-merge-relationship-properties`.
- **BEHAVIOUR CHANGE: lean-mode late keys and runtime composite keys are
  complete in their indexes; a bit-63 reserved id takes property SETs
  again (SONNY-6354).** (1) Regression from SONNY-6268: a property SET,
  no-save SET or label add on a node whose reserved id has bit 63 set
  failed with `MergeHolderIdFlagged`. Such an id is never a MERGE index
  entry (the bit flags an entry), so the write now goes on and writes no
  entry, as every other path does; a removal for such an id no longer
  drops the entry of the node whose id has the same low bits. (2) With
  `GEODE_INDEX_MERGE_KEYS_ONLY=1` the exact node-property index held a key
  registered at runtime (the first MERGE on it) only for nodes written
  after, yet every seek trusted it as complete: `MATCH (n:L {k: v})`,
  WHERE seeks and both bulk endpoint resolvers missed older nodes (the
  resolvers reported a present endpoint as missing), and the index saved
  at shutdown carried the hole across a restart. The first access to a
  graph's exact index after such a registration now adds the older
  holders of the new key (one scan of the graph per registration, under
  the index's build mutex; a lean-off store never pays it), and an index is
  saved only once complete. (3) `prop_exact.idx` is stamped with the
  indexed-key set (format `GENPIDX5`): one saved under another key set, or
  with lean mode on and read with it off (it lacked every non-MERGE key, so
  seeks on them returned nothing), is rebuilt instead of trusted.
  **Upgrade note:** every graph's `prop_exact.idx` from an older binary is
  rebuilt once, in the background, on its first open. (4) A composite
  MERGE key registered at runtime gets the entries of holders written
  before it, from the label's postings (evicted nodes included), before a
  probe trusts a miss; it covered resident nodes only. The two eager scans
  of the node cache at registration, which walked every graph without its
  lock, are gone. (5) The unwired second constraint implementation
  (`src/schema/constraint_manager.zig`, `schema_manager.zig`) and the tests
  of it only are removed. Regression:
  `zig build test-sonny6354-lean-late-key-indexes`.
- **Lean mode: MERGE no longer duplicates a holder that is not resident
  (SONNY-3056).** With `GEODE_INDEX_MERGE_KEYS_ONLY=1`, a MERGE key is
  indexed only once registered (the first MERGE on it), and the
  registration backfilled MERGE's index from the resident nodes only, so a
  node written before (by CREATE, or a MERGE on another key) and evicted
  from the node cache had no entry: the executor's MERGE and the server's
  bulk MERGE trusted the miss and created a duplicate. A key registered at
  runtime is now backfilled per (graph, label) from the label's postings,
  hydrating nodes that are not resident, before the first lookup trusts a
  miss (`GraphStore.ensureLeanMergeBackfill`); the cost is one scan of the
  label per key, once (keys read from `merge_index_keys.dat` at start cost
  nothing). The legacy executor's point read through the same index
  (`lookupOnlyMergeHolder`) is covered too. The exact node-property index
  and runtime composite keys followed in SONNY-6354. Regression:
  `zig build test-sonny3056-lean-merge-evicted-holder`.

- **BEHAVIOUR CHANGE: NOT NULL, EXISTS and NODE KEY existence are enforced;
  `CREATE UNIQUE INDEX` is refused (SONNY-6281).** `REQUIRE n.p IS NOT
  NULL`, `ASSERT EXISTS (p)` and the existence half of `IS NODE KEY` were
  recorded and never checked. They are now checked at the end of every
  statement, through SONNY-2846's check: a statement that would leave a node
  of the label without the property (absent or `NULL`: CREATE, MERGE that
  creates, `SET n.p = NULL`, `SET n = {...}`, `REMOVE n.p`, `SET n:Label`)
  fails with 23502 (`not_null_violation`) and keeps none of its changes;
  `REMOVE n:Label` frees a node. **`CREATE CONSTRAINT` of these kinds over
  nodes that already lack the property is now refused** (23502, with the
  count); it used to be accepted. Every enforced constraint, of any kind,
  now sends the server's node-writing fast paths (simple CREATE, bulk
  MERGE, `/*+BATCH*/`, `USE GRAPH g; MERGE`) to the executor, and a cluster
  leader refuses a replicated non-delete write on such a graph, as for
  UNIQUE. **`CREATE UNIQUE INDEX` is now refused with 0A000**
  (`UniqueIndexNotSupported`): it built a plain index and ignored `UNIQUE`;
  use `CREATE CONSTRAINT ... IS UNIQUE`. ISO/IEC 39075:2024 has no
  constraint or index DDL; these are Geode extensions. **Upgrade note:** a
  NOT NULL / EXISTS / NODE KEY constraint created on an older version over
  data that lacks the property stays in the catalog and is enforced from
  now on for each node a statement writes (a statement that changes any
  property or label of such a node must also supply the missing one);
  nodes not written are not rechecked. Find them with `MATCH (n:Label)
  WHERE n.prop IS NULL`. The dead `catalog_mod` import in `crud_operations.zig` and its
  misleading `REQ-CONSTRAINT-ENFORCE-001` CANARY are removed. Regression:
  `zig build test-sonny6281-existence-constraints`.

- **`zig build test-graph-store` is green again (SONNY-6336, tests
  only):** seven inline tests set the process-global data-directory
  override through `initGlobalStore` and left it naming their removed
  scratch directory, so the later FLE inline test (GAP-0886), whose catalog
  save now fails closed (SONNY-6324), failed with `FileNotFound`. Those
  tests now restore the previous override
  (`graph_store.saveDataDirOverride` / `restore`), and the FLE inline tests
  point the FLE catalog at their own scratch directory and restore the
  previous one (`fle_catalog.saveDataDirOverride`). No product change.

- **Index and constraint catalogs are graph-scoped (SONNY-1319):** the
  catalog keyed a row `<label>:<name>` with no graph, so with two graphs
  `CREATE INDEX IF NOT EXISTS i ...` in one was a silent no-op when the other
  had `i`, a plain CREATE answered 42P07, `DROP INDEX i` in one graph removed
  the other's `i` (one tenant could drop another's indexes by name), `CREATE
  CONSTRAINT c` was refused (42710) when another graph had `c`, and `SHOW
  INDEXES` / `SHOW CONSTRAINTS` / `db.indexes()` / `db.constraints()` listed
  every graph's rows. Every row now records its graph (the session's; the
  default graph for a fulltext index, where its engine lives), persisted in a
  trailer after the catalog records and reloaded at restart. CREATE, IF NOT
  EXISTS, DROP INDEX and SHOW resolve within the session's graph; DROP INDEX
  now needs the schema permission on the session's graph (and, as before,
  on the database; on `default` too for a fulltext or engine-wide index).
  Two exceptions: an index whose runtime structure is keyed by name alone
  (vector/HNSW and the other advanced types, SONNY-1223) cannot share its
  name with another graph's index — that CREATE, IF NOT EXISTS included, is
  refused with 42P07 `IndexNameInUseByOtherGraph` instead of being
  swallowed; and rows from a catalog written before this change, and the
  implicit `auto_idx_*_id` indexes, are engine-wide (in every graph's
  catalog, as before), so an upgrade loses nothing. Constraint enforcement
  on writes is unchanged (SONNY-2846, SONNY-3358). Regression:
  `zig build test-sonny1319-graph-scoped-catalog`.
- **A dropped index stays dropped, and DROP INDEX takes the catalog lock
  (SONNY-2795):** DROP INDEX removed the catalog row in memory and never
  saved the catalog, so the index came back after a restart. It now saves
  as CREATE INDEX does; if the save fails the statement fails and the
  index stays, in memory and on disk. DROP INDEX also removed and freed
  the row without the catalog lock while readers could hold it; it now
  holds the lock exclusive, and the vector-index readers on the write and
  knn paths, `db.indexes()` and `CALL geode.fts.rebuild` copy what they
  need under the lock. CREATE INDEX and the vector dimension guard created
  the process-wide index manager with the statement's per-request
  allocator; it now uses the process allocator. A session with no data
  directory read and wrote its catalog at the shared
  `/tmp/geode_catalog.dat`, so separate sessions and processes shared one
  catalog and a new session loaded an earlier one's indexes; its catalog
  is now kept in memory only, as its store is. Regression:
  `zig build test-sonny2795-drop-index-catalog`.
- **BEHAVIOUR CHANGE: UNIQUE constraints are enforced (SONNY-2846,
  SONNY-3358).** `CREATE CONSTRAINT ... IS UNIQUE` recorded a row and
  nothing checked it: CREATE, MERGE that creates, `ON CREATE SET`, `SET
  n.p = <taken value>` and `SET n:<constrained label>` all made duplicates,
  on in-memory and persisted sessions, and the server's write fast paths
  skipped the executor altogether. **Writes that used to succeed can now
  fail:** every statement is checked when it ends (SQL's rule for a
  constraint that is not deferred), and one that would leave two nodes
  holding one key fails with 23505 (`unique_violation`, naming the
  constraint, never the value) with none of its changes kept, a
  multi-element CREATE included. A swap is allowed. Uniqueness is per graph
  (an engine-wide row from an older catalog applies in every graph, each
  checked on its own) and per tenant tag, so a refusal never tells one
  tenant what another holds; NULL and missing values never conflict; values
  compare as MERGE matches them (`1` = `1.0`; strings byte for byte, so an
  NFC and an NFD spelling are distinct). **`CREATE CONSTRAINT ... IS UNIQUE`
  (or `NODE KEY`) over data that already has duplicates is now refused**
  (23505, with the number of duplicate groups); it used to be accepted. The
  uniqueness half of NODE KEY is enforced; NOT NULL, EXISTS and NODE KEY's
  existence half followed in SONNY-6281 (above). The holder is found through the
  exact node-property index, or, where it cannot answer (lean mode, the
  index rebuilding after a restart, an in-memory session, a non-scalar
  value), by a scan of the label, including nodes that are not resident.
  The simple-CREATE, bulk MERGE, `/*+BATCH*/` and `USE GRAPH g; MERGE` fast
  paths no longer serve a graph with a UNIQUE constraint (those writes run
  through the executor, and are slower); a fast-path write already past
  that check when the constraint is created is refused with 40001. A
  cluster leader refuses (40001) a replicated non-delete write on such a
  graph. The dead `validateConstraints` (crud_operations.zig) and
  `Catalog.getConstraintsForLabel` are removed. (`CREATE UNIQUE INDEX` is
  refused since SONNY-6281, above.) Regressions:
  `zig build test-sonny2846-unique-constraint-enforcement` and
  `zig build test-sonny2846-unique-fast-paths-wire`.
- **DROP CONSTRAINT drops the constraint (SONNY-6270):** it answered
  success and removed nothing, so the constraint stayed in `SHOW
  CONSTRAINTS`, kept being enforced and survived restarts. It now works as
  DROP INDEX does: the name resolves in the session's graph (its own rows,
  else an engine-wide row from an older catalog; a constraint of another
  graph is not found), all rows of that name there are removed and the
  catalog saved under the catalog lock, and a failed save fails the
  statement with the constraint still in place and enforced. A missing name
  is refused (`ConstraintNotFound`) unless `IF EXISTS` is given. Dropping
  an engine-wide row from any graph removes it for every graph. A UNIQUE or
  NODE KEY constraint stops being enforced at once, and once no UNIQUE row
  applies in a graph the server's bulk write fast paths serve it again. The
  permission checks are CREATE CONSTRAINT's (an engine-wide row also needs
  schema on `default`, as for DROP INDEX); cluster mode refuses it. DDL is
  not transactional: a ROLLBACK does not bring a dropped constraint back.
  `db.constraints()` read catalog rows after releasing the catalog lock; it
  now copies them under the lock, as SHOW CONSTRAINTS does. The unused
  `Catalog.removeConstraint`, `listAllConstraints` and
  `listConstraintsForGraph` are removed. Regression:
  `zig build test-sonny6270-drop-constraint`.
- **BEHAVIOUR CHANGE: index and constraint names are unique per graph;
  DROP INDEX is deterministic and locks the session's graph (SONNY-6294).**
  CREATE INDEX accepted one name on two labels of a graph, and DROP INDEX
  then dropped whichever row the catalog's hash order met first. A name is
  now one index of a graph: a second `CREATE INDEX` with the name, on any
  label, is refused (42P07; a no-op under `IF NOT EXISTS`), and the same
  for `CREATE CONSTRAINT` (42710). Another graph may still use the name
  (SONNY-1319). A catalog written before this may hold one name on several
  labels: DROP INDEX drops all of them in the scope it resolves (the
  graph's own rows, else the engine-wide rows) and adds a note to the
  result, as DROP CONSTRAINT does. The server took the default graph's
  write lock for every DROP INDEX (it might be a fulltext index), so a
  DROP INDEX in graph g ran beside g's writers and blocked default's; it
  now takes the session graph's lock, as constraint DDL does. A fulltext
  index lives in the default graph, so **a bare `DROP INDEX` of a fulltext
  index from a session on another graph is now refused (0A000)**: run
  `USE GRAPH default; DROP INDEX <name>`. `IndexNotFound` and
  `ConstraintNotFound` reached clients as 58000 (system error); they are
  42704 (undefined_object), and `IndexAlreadyExists` is 42P07. Clients or
  harness specs that matched 58000 for these must match 42704. Regression:
  `zig build test-sonny6294-drop-index-rules`.
- **A graph-store write that runs out of memory part way leaves nothing
  half done (SONNY-6268):** node and edge creates, property SET and REMOVE,
  label add and remove, and node and edge deletes either complete or leave
  the store, its indexes and the storage engine as they were, free what they
  copied, and report the failure. Before, a SET whose key copy failed left a
  property slot with an undefined key, so the next lookup on the node, its
  delete or the store's shutdown crashed; a create that failed after the node
  cache took the node left a node no caller knew of in the cache and in some
  indexes, or leaked its copies, or left an orphan node in the engine; a
  failed merge-index insert was ignored, so a later MERGE created a
  duplicate; and a delete that failed half way (edges not collected, a label
  posting not updated) still removed the node and reported nothing. The node
  cache's `put` is all-or-nothing and documents who owns the value when it
  fails (the caller). `GraphStore.deleteNodeChecked` and `deleteEdgeChecked`
  return the error (the executor's DELETE and the statement undo use them);
  `deleteNode` and `deleteEdge` log it and fail the running statement on out
  of memory. Regression:
  `zig build test-sonny6268-graph-store-failure-atomicity`.
- **No edge write, tenant drop or replicated delete reports success when the
  storage engine did not store it (SONNY-6302):** `setEdgeProperty` logged a
  failed engine write (or slot lookup) at debug level and wrote the property
  in memory anyway, so the client saw success and a restart lost the value;
  it now returns the error and leaves memory as it was, as `setNodeProperty`
  does. `removeEdgeProperty` prepares its in-memory removal before the engine
  write (memory could keep a property the engine had removed). A tenant drop
  (`CALL geode.tenant.drop(t, true)`) whose delete fails now fails before the
  tenant is removed, logs what was deleted and what remains, and a retry
  finishes it; it used to remove the tenant and report success with its rows
  left behind. The replicated-delete apply returns a failed delete to the raft
  apply loop (logged as not applied, counted in `apply_errors`) after applying
  the rest of the entry; the 2PC participant and coordinator fail a commit
  whose delete fails, as they do a failed create; the 2PC undo of a create
  logs a failed delete as an incomplete undo. Deleting a node or edge whose
  names pass 512 bytes reserves its index-key room before the engine delete,
  so the in-memory removal cannot leave the node in its label posting or a
  counter high. Regression:
  `zig build test-sonny6302-edge-write-and-delete-errors`.
- **Documentation Accuracy:** Updated MIGRATION_GUIDE.md to reflect partial server wiring status and list in-progress functions (GAP-0291)
- **SUM/FIRST/LAST Aggregations:** Added test coverage for missing aggregation types (GAP-0284)
- **valueAt/timeBucketAvg Edge Cases:** Added boundary and empty-input tests (GAP-0285)
- **Step/Nearest Interpolation:** Added tests for step and nearest interpolation methods (GAP-0286)
- **`FOR ... RETURN` aggregates over the loop's rows:** `FOR x IN [1, 2, 3]
  RETURN sum(x)` returned three rows of NULL instead of one row of 6, and
  `count`, `avg`, `min`, `max` and `collect` failed with UnknownFunction. The
  RETURN after a FOR now projects all of the rows the FOR produces, as a
  RETURN after a MATCH does: aggregates run over every row, a non-aggregated
  item beside one needs a `GROUP BY` (now accepted after a FOR's RETURN;
  42803 without it), and an empty list gives one row with `sum` NULL and
  `count` 0. Its `DISTINCT`, `ORDER BY`, `SKIP` and `LIMIT`, which were
  ignored, now apply.
- **`FOR ... RETURN x` names its column `x`:** an unaliased FOR column was
  named `?column?`. Columns are now named as after a MATCH: a variable after
  itself, `m.prop` after `prop`, an aggregate after its function.
- **FOR after MATCH, after WITH, and nested:** `MATCH (n) WITH n FOR x IN
  n.list RETURN x` returned one NULL per node, and its aggregates ran over
  the matched rows rather than the loop's. The FOR now runs over every row of
  the part before it. `MATCH (n) FOR x IN n.list RETURN ...` and nested
  `FOR x IN a FOR y IN x RETURN ...`, which were syntax errors, are accepted.

---

## [v0.8.23] - October 9, 2026

The SONNY-738 hardening release: the two v0.8.23 lines reconciled into one
(the v0823 line, with SONNY-2675's strict grouped HAVING, and the r12 line,
review rounds 12-19). Statements that write are accepted only in
allowlisted shapes and are atomic (a failed statement changes nothing and
ROLLBACK undoes every change the store made; see Known limitations),
integer and decimal arithmetic is checked, MERGE matches by exact value,
the parser and evaluator are bounded, and graph, session and transaction
lifetimes are closed against the races the reviews found. Where the lines disagreed the reconciliation keeps: the
v0823 write step (a SET before a DELETE is applied, in order), the v0823
query nesting limit (10) in front of the r12 stack guard, r12's expression
link cap (4096) and r12's full ROLLBACK, which lets a label SET or REMOVE
run inside an explicit transaction again.

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
- **EXPLAIN and PROFILE of transaction control are refused (SONNY-3026):**
  `PROFILE <statement>` parses for any statement, and the handlers' PROFILE
  arm ran the inner one with nothing looking inside. PROFILE ROLLBACK undid
  the transaction under a read lock (or none) and the handler kept the
  transaction open, so the client's next autocommit change joined a
  transaction that was rolled back at disconnect; PROFILE START TRANSACTION
  began a transaction the handler threw away; PROFILE COMMIT committed one
  the handler still held open. An EXPLAIN or PROFILE of START TRANSACTION,
  COMMIT, ROLLBACK, a SESSION statement, USE GRAPH or another EXPLAIN or
  PROFILE is now refused (0A000) on QUIC and gRPC, and the program traits
  (transaction control, the program's graph, the handlers' transaction
  bookkeeping) look inside PROFILE and EXPLAIN.

  **Behaviour change:** `PROFILE ROLLBACK`, `EXPLAIN USE GRAPH g` and the
  like answer 0A000.
- **A PROFILE'd change commits under its write lock (SONNY-3027):** a
  PROFILE'd query that writes in a transaction (`PROFILE MATCH (a:X) MERGE
  (:Y {k: 1})`) opened the session's engine transaction without passing an
  executor entry point, and only the end-of-request backstop committed it,
  after the PROFILE arm had released the graph's write lock: an engine
  transaction open while another thread held the lock (SONNY-2978's
  overlap). The profiled path is now an executor entry point, both handlers
  commit the engine transaction before they release a write lock, and the
  backstop aborts a transaction still open and rolls the session's
  transaction back instead of committing outside the lock.
- **DROP GRAPH frees a graph only when no thread holds it (SONNY-3028):**
  DROP GRAPH counted as a statement on the session's graph, so `DROP GRAPH
  g` from a session on `default` locked `default` and freed g under the
  threads that held or waited for g's lock and under engine transactions
  open on g: a use-after-free any holder of the schema permission could
  trigger (`START TRANSACTION; CREATE (:X); DROP GRAPH g; CREATE (:Y)`
  crashed the server). CREATE and DROP GRAPH now run on (and lock) the graph
  they name, so DROP GRAPH waits for the graph's requests; a graph is freed
  by the last of its lock's holders, waiters, group-commit batches and
  checkpoints, and a waiter that gets a dropped graph's lock is told the
  graph is gone; the session engine transaction's graph is checked and used
  under one pin.

  **Behaviour change:** DROP GRAPH (or CREATE OR REPLACE GRAPH) of the graph
  the session's transaction changed is refused with 55006 ("object in
  use"), and a program that changes data and also creates or drops another
  graph is refused as spanning graphs (0A000).
- **Group commit keeps no engine transaction open under the write lock
  (SONNY-3029):** a group-commit batch (on by default) kept its statement
  transaction open across ops that each took the graph's lock SHARED only
  while they ran, so the graph's write lock could be taken in between and
  the writer's engine transactions overlapped the batch's (a review probe
  saw open transactions in 15,314 of 864,308 samples), the SONNY-2978
  overlap that can lose committed writes on crash recovery. A batch now
  opens its transaction only while no thread holds or waits for the graph's
  write lock, and a writer takes the lock only once every open batch has
  committed. The 16 shard workers' batches stay concurrent:
  `bench-group-commit` (16-way with the coordinator) measured 8,471 / 9,145
  / 9,201 ops/s before and 9,351 / 9,243 / 8,989 after. Taking the graph's
  exclusive lock for each batch instead cost about 72%.
- **Index and constraint DDL need the schema permission on the database
  (SONNY-3030):** indexes and constraints are catalogued database-wide, but
  SONNY-2803 checked the schema permission on one graph, so a user with a
  `FOR SCHEMA` grant on one graph added constraints that bound every graph
  and dropped indexes an Admin created from another. CREATE and DROP INDEX
  (fulltext included) and CREATE and DROP CONSTRAINT now also need
  `decide(schema)` on the whole database.

  **Behaviour change:** these statements need Admin, or a GPS `FOR SCHEMA`
  policy on `*`; a `FOR SCHEMA` policy on single graphs no longer grants
  them.
- **A failed commit of a transaction's engine transaction fails the
  transaction (SONNY-3031):** it was only logged, so the request and the
  later COMMIT reported success for changes never committed to storage, and
  the engine transaction stayed in its shard's list of open transactions for
  good. The failed engine transaction is now aborted, the request fails
  (40000), and the transaction is rolled back, so its COMMIT reports the
  failure. The COMMIT statement, a START TRANSACTION body and the COMMIT
  RPC and message commit the engine transaction before the undo log.
- **A `/*+BATCH*/` never recreates a dropped graph (SONNY-3033):** the QUIC
  batch route ran before the graph-existence check, and the group-commit
  coordinator created whatever graph it was given, so a session left on a
  graph another session dropped recreated it with its next batch, without
  the schema permission. The route now applies the session-graph gate
  (internal, bind, existence), and the coordinator creates no graph but the
  default one.
- **Offline auth commands verify against the chain root (SONNY-3035):** a
  store whose security records were all removed at rest kept its chain root
  and skipped verification, so `geode auth init` bootstrapped a new admin
  into it and sealed it. And verification wrote a new `.geode_hmac_key`
  when there was none, then refused. A store now counts as empty only with
  no records and no chain root, and verification (and `geode auth verify`)
  looks the key up without generating one.
- **Deleting an RLS policy leaves no dangling map key (SONNY-3036):** the RLS
  engine's policy map borrowed its keys from the first policy of each graph
  and table, and kept them after `UserManager.deletePolicy` freed that
  policy's strings (a library caller could read freed memory). The map now
  owns its keys, and an emptied graph and table lose their entry.
- **`geode revoke --from` revokes that principal's grant (SONNY-3037):** it
  removed the first permission record with the permission's name, which
  could belong to another principal, and reported success when nothing
  matched; and `geode grant` reused one record id, so each grant replaced
  the previous one. Revoke now removes the named principal's grants (on the
  named resource, when given) and fails, changing nothing, when there is
  none; grant takes an id of its own.
- **`geode.auth.revoke` fails when the revoke cannot be saved, and schema DDL
  is gated (SONNY-3038):** a revoke whose durable write failed was logged
  and reported "Revoked", and the privilege came back at the next start; it
  now fails with 58030. CREATE and DROP SCHEMA were ungated; they now need
  the schema permission on the database, as index DDL does.

  **Behaviour change:** CREATE/DROP SCHEMA need Admin or a GPS `FOR SCHEMA`
  policy on `*`.
- **Graph DDL runs without statements on graph data (SONNY-3130):** the
  handlers lock the graph a program runs on before it runs, and since
  SONNY-3028 CREATE and DROP GRAPH count as statements on the graph they
  name. So `CREATE OR REPLACE GRAPH g; USE GRAPH g; CREATE (:R)` and `DROP
  GRAPH g; CREATE GRAPH g; USE GRAPH g; CREATE (:R)` held the old graph's
  write lock while the program wrote the new graph, which has a lock of its
  own, beside that graph's writers; and from a session on g, `DROP GRAPH g;
  CREATE (:R)` created g again. A program that creates, replaces or drops a
  graph and also has a statement on graph data, on any graph, before or
  after the DDL (a START TRANSACTION body and a PROFILE'd statement
  included), is now refused on QUIC and gRPC.

  **Behaviour change:** such a program answers 0A000; send the statements
  that use the graph in a request of their own. Graph DDL still runs with
  other graph DDL, graph selection, session statements and transaction
  control, so `DROP GRAPH IF EXISTS g; CREATE GRAPH g` and `CREATE GRAPH g;
  USE GRAPH g` run. `START TRANSACTION; CREATE (:X); DROP GRAPH g` answers
  0A000 where it answered 55006.
- **A checkpoint does not write a dropped graph back (SONNY-3131):** a
  regression of SONNY-3028 in this release. A graph-scoped checkpoint (the
  hydration persist, the exact-index persist worker, the ordered-index
  build, the self-heal flush) of a graph dropped while it waited for the
  graph's lock put the graph back into the registry, with its files gone.
  CREATE GRAPH of the name then answered 42P07, and every later registry
  save failed on the missing files and was only logged, so graphs created
  afterwards, and their data, were gone after a restart. The checkpoint now
  leaves the registry alone for a dropped graph, and a registry save skips
  (and logs at error level) an entry whose files cannot be read instead of
  failing, without lowering the registry's next ids.
- **The default graph cannot be dropped or replaced (SONNY-3132):**
  `GraphStore.dropGraph` dropped the storage engine's graph before it
  checked for `default`, and DROP GRAPH logged the refusal and answered ok:
  `DROP GRAPH default` from a user with the schema permission on `default`
  (a ReadWrite user with a `FOR SCHEMA` grant on it, too) deleted the
  default graph's engine and its files on disk, while the in-memory store
  still showed its data. The store and the storage engine now refuse `default`
  before dropping anything, and the refusal reaches the client; CREATE OR
  REPLACE GRAPH default is refused before anything is dropped.

  **Behaviour change:** DROP GRAPH default, DROP GRAPH IF EXISTS default and
  CREATE OR REPLACE GRAPH default answer 0A000, for every principal.
- **Deep nesting gets a parse error, not a crash (SONNY-3133):** parsing
  runs before authorization, and only the expression grammar counted its
  depth, so any authenticated user could overflow the stack of the thread
  parsing the request: a 408-byte `PROFILE EXPLAIN PROFILE ...` crashed the
  server at depth 50, and so did deep START TRANSACTION bodies,
  parenthesized statements, VALUES continuations, WITH chains, CALL { }
  subqueries, FOR bodies, and long NOT, unary minus or shortestPath()
  chains; `ORDER BY 1 + 1 + ... + 1` overflowed in the ORDER BY check. Every
  recursive entry of the parser now counts against the 128-level limit
  (GAP-0333), statements nest at most 8 deep, and a level is refused when
  less than 2 MiB (Debug) or 512 KiB of the thread's stack is left, so no
  nesting overflows the 16 MiB QUIC workers or the 8 MiB gRPC connection
  threads. The ORDER BY check walks operator and member-access chains in a
  loop.

  **Behaviour change:** more than 8 nested statements (EXPLAIN, PROFILE,
  EXPLAIN POLICY FOR, a START TRANSACTION body, a parenthesized statement, a
  VALUES continuation) answer 42000, and so do more than 128 levels of any
  nesting, NOT and unary minus chains and WITH chains included. A Debug
  build refuses somewhat less nesting than a release build, where the
  thread's stack runs short first.
- **DROP GRAPH is refused while any session's transaction has changed the
  graph (SONNY-3134):** SONNY-3028 refused DROP GRAPH of the graph the
  calling session's transaction changed. Another session's open
  transaction holds no lock between its requests, so the graph was dropped
  under it: that session's COMMIT reported success for changes that went
  with the graph, and its COMMIT or ROLLBACK created the graph again. A
  session's transaction now holds the graph it changed (its transaction
  graph, SONNY-2776) from its first change until it commits, rolls back or
  the session ends, and DROP GRAPH and CREATE OR REPLACE GRAPH of a held
  graph are refused. A QUIC session ends with its stream. A gRPC session
  ends when the server closes it: one idle in an open transaction for
  `--idle-in-transaction-timeout` (10 minutes) is closed and its
  transaction rolled back, which releases the hold (SONNY-3032, below).
  The hold goes as the COMMIT or ROLLBACK statement ends the transaction,
  so `COMMIT; DROP GRAPH g` runs in one program (SONNY-3191).

  **Behaviour change:** DROP GRAPH and CREATE OR REPLACE GRAPH of a graph
  that any session's open transaction has changed answer 55006, until that
  transaction ends. A transaction that only read the graph does not hold
  it.
- **EXPLAIN and PROFILE take a listed set of statements, and a failed
  request's engine transaction is aborted (SONNY-3135, part):** SONNY-3026
  refused the statements it listed and let the rest through: `PROFILE CALL
  geode.tenant.backfill_edge_tags()` ran the self-locking procedure under
  the handler's lock, where it waited up to 120 s on the lock its own
  request held, and DDL ran through the PROFILE arm, built for queries.
  EXPLAIN and PROFILE now take a query (set operations included), a data
  change (INSERT, CREATE, MERGE, DELETE, SET, REMOVE), FOR or a read-only
  CALL, and a PROFILE'd self-locking CALL counts as one. And a program that
  failed inside its transaction committed its engine transaction when it
  returned (a write lock's release did the same for one left open), so the
  failed changes were durable until the rollback undid them (the SONNY-2979
  crash window); the engine transaction is now aborted. What the rollback
  then undoes is what the undo log records: the nodes and edges a CREATE or
  a MERGE created. Other writes inside the transaction (SET, REMOVE,
  DELETE, a label change, and a change MERGE makes to data it matched)
  persisted after its ROLLBACK or its failure (SONNY-3059); round 18 fixed
  that (ROLLBACK undoes every change, below).

  **Behaviour change:** EXPLAIN or PROFILE of graph, index, constraint,
  schema, auth or policy DDL, SHOW, VALUES, EXPLAIN POLICY or a CALL that
  changes data answers 0A000.
- **An expression of more than 4096 operators is refused, and long
  operator chains no longer crash the server (SONNY-3181, SONNY-3189):**
  the parser builds operator and member-access chains with loops, so
  `RETURN 1 + 1 + ... + 1` with N terms is an expression N deep, and the
  code that walks expressions recursed once per operator. Before
  authorization, the request analysis crashed a server thread on an
  EXPLAIN RETURN chain of 100,000 terms (400 KB) or an OR chain of 400,000,
  and a Debug build on 20,000; printing an ORDER BY key crashed on long
  chains; and evaluation crashed a Debug build on 1,000 terms, and on
  `RETURN - - ... 1` 120 deep, for any role that can read. The parser now
  counts the operators of an expression (binary operators, unary prefixes,
  and member-access, index, slice and call links, over the whole
  expression and what nests in it) and refuses more than 4096
  (`max_expr_links`). The evaluator, the request analysis, the printer and
  the other walks over expressions follow chains with loops, and the
  evaluator and the grouped HAVING rewrite refuse nesting deeper than the
  thread's stack holds instead of overflowing it.

  Round 15 corrections (SONNY-3189, SONNY-3251): as first shipped, the
  walkers a grouped HAVING's rewrite calls (`containsAggregate`,
  `mentionsAnyName`, `exprEql`) still recursed once per link, so `GROUP BY
  v HAVING sum(n.v + 0 ... + 0) >= 0` near the cap crashed the server
  thread instead of being refused cleanly; and a 54001 refusal inside a
  WHERE, a WITH ... WHERE, an EXISTS or a grouped HAVING was silent: the
  row counted as not matching, and the query answered 0 rows. Both are
  fixed in round 15 (below). Integer arithmetic on aggregates that
  overflows answers 22003 on the WITH-chain path; the multi-node aggregate
  path answers NULL instead (SONNY-2696, open).

  **Behaviour change:** an expression with more than 4096 operators
  answers 42000 ("expression too long"). An IN list of literals has no
  operators, and an OR of a few hundred `n.v = k` terms (three each) fits;
  split a larger predicate into an IN list or parameters. An expression
  nested (lists, calls, CASE) deeper than the evaluating thread's stack
  holds answers 54001 where it crashed; a Debug build reaches that sooner.
- **Graph id maps are safe to use from sessions on different graphs at once
  (SONNY-3180):** the map from each graph to its node and edge id map was
  shared by the whole store with no lock of its own, and each graph's id
  map was stored inside it. Two sessions writing to different graphs at
  once corrupted it (a Debug build tripped the hash map's check; a release
  build had a data race and a use-after-free), and adding a graph moved
  every other graph's id map from under the threads using it. The map now
  has its own lock and each graph's id map an address of its own.

  Round 15 correction (SONNY-3180): as first shipped, only the map of id
  maps had a lock; each id map's contents were still read without its own
  lock by every snapshot read, by `CALL db.propertyKeys()`, the algorithms
  and the backup, so a read racing a writer of another graph, or a DROP
  GRAPH, could still crash. Fixed in round 15 (below).
- **Abandoned gRPC transactions and sessions are closed (SONNY-3032):** a
  gRPC session lived as long as the server, and a client that began a
  transaction, wrote and went away left the transaction open for good, with
  its undo entries, its storage transaction and its graph hold, so the
  graph could never be dropped. A gRPC session idle in an open transaction
  for `--idle-in-transaction-timeout` is closed and its transaction rolled
  back; any gRPC
  session idle for `--grpc-session-idle-timeout` is closed; a session a
  request is using is never closed. One user holds at most
  `--grpc-max-sessions-per-principal` gRPC sessions: past it a Handshake
  closes that user's least recently used idle session, or is refused when
  all are in use. Each is also a config-file key
  (`idle_in_transaction_timeout`, `grpc_session_idle_timeout`,
  `grpc_max_sessions_per_principal`); 0 turns it off.

  Round 15 corrections (SONNY-3252): as first shipped, the idle session a
  Handshake closed at the cap could be one idle inside an open
  transaction, which was rolled back; and without authentication every
  client was the same principal, so any client could close any other's
  session and transaction. Now a session in a transaction is never closed
  (below). The cap counts sessions per user name, not per tenant: one name
  in two tenants shares one cap.

  **Behaviour change:** a gRPC session idle in an open transaction for 10
  minutes is closed and its transaction rolled back, and a gRPC session
  idle for 30 minutes is closed; a closed session's Execute and Pull answer
  28000, and its BEGIN, COMMIT and ROLLBACK answer success=false (no SQLSTATE
  on those replies); the client handshakes again. A user holding 1024 gRPC
  sessions has its least recently used idle one closed at the next
  Handshake.
- **The rest of the round 13 review (SONNY-3191, SONNY-3122):**
  - A COMMIT or ROLLBACK statement releases its session's graph hold where
    it ends the transaction, not after the program, so `COMMIT; DROP GRAPH
    g` and `ROLLBACK; DROP GRAPH g` run.
  - Under overload the QUIC connection admission thread serves a
    connection's first stream itself, on a 1 MiB stack, where a plain MATCH
    was refused ("nesting too deep") and a Debug build crashed. It now has
    the 16 MiB stack of the threads that serve requests.
  - CURRENT_GRAPH, CURRENT_PROPERTY_GRAPH, HOME_GRAPH and HOME_PROPERTY_GRAPH
    are reserved: `CREATE GRAPH CURRENT_GRAPH` created a graph USE GRAPH
    could never select, and `DROP GRAPH CURRENT_GRAPH` dropped a graph of
    that name, not the current graph.
  - A policy expression with more than 64 nested parentheses or 1024 AND or
    OR operators is refused: it could overflow the stack of every request
    the policy applies to.
  - A read that resolves an edge type's name looks its graph up and pins
    it; it created the graph when it was missing, so a read racing a DROP
    GRAPH could create the graph again (SONNY-3122, part).

  **Behaviour change:** CREATE and DROP GRAPH of CURRENT_GRAPH,
  CURRENT_PROPERTY_GRAPH, HOME_GRAPH and HOME_PROPERTY_GRAPH (any case)
  answer 42939, and a HELLO cannot create one. A policy expression past
  the bounds above is refused at CREATE or ALTER POLICY. (A graph that
  already had such a name could not be dropped by it as first shipped;
  round 15, SONNY-3234, lets DROP GRAPH remove it, below.)
- **Round 15: the round 14 review's crashes and races (SONNY-3189,
  SONNY-3180, SONNY-3233, SONNY-3250, SONNY-3251, SONNY-3252, SONNY-3234,
  SONNY-3253):**
  - A grouped or implicit HAVING with an operator chain as long as the
    parser takes (`GROUP BY v HAVING sum(n.v + 0 ... x4090) >= 0`, the
    item-equality form, `RETURN count(n) AS c WHERE sum(...)`) crashed the
    server thread: the walkers the HAVING rewrite calls recursed once per
    link. They follow chains with loops, as does the projection analysis
    of a planned read with a hop, which recursed on index and slice
    chains with no stack guard (SONNY-3189).
  - The contents of each graph's id map are read under that map's own
    lock, and a snapshot read (every gRPC and QUIC read not served
    engine-direct) clones only its own graph, under the locks of what it
    walks. It cloned every graph's id map, nodes and edges with no lock,
    so reads crashed within a second next to a writer of another graph,
    and corrupted the heap next to DROP and CREATE GRAPH (SONNY-3180).
  - The node, edge and adjacency caches' growth, the adjacency and
    edge-type index of an in-memory (unbounded-cache) store, and the graph
    registry change under their locks: a batch CREATE on one graph racing
    a single CREATE on another panicked, and so did two edge writers on
    two graphs (SONNY-3233).
  - A nested EXISTS or COUNT subquery read an environment it had freed
    (`WHERE EXISTS { MATCH (m) WHERE EXISTS { ... } }` panicked, "@memcpy
    arguments alias"); pre-existing (SONNY-3250).
  - A resource limit the evaluator runs into (54001, the read budget, a
    cancel) fails the query; a WHERE, a HAVING, an aggregate or a subquery
    turned it into a row that did not match. (Round 16 correction: as
    shipped in round 15 this held on the request's own thread and for
    54001 only; a limit in a parallel UNION arm, an out of memory, and the
    node scan's inline-property seek could still become an answer. Fixed in
    round 16, SONNY-3316.)
    Index, slice, member and map-projection chains evaluate with a loop,
    so 4096 links is the real limit for them too (SONNY-3251).
  - At the gRPC per-principal session cap, a session in an open
    transaction is never closed: when every one of the principal's
    sessions is in use or in a transaction, the Handshake is refused
    (resource exhausted). Without authentication a client counts as
    `anonymous@<peer ip>`, and a federation peer as `federation@<peer
    ip>` (every peer node sends the one name the cluster token accepts,
    `geode-cluster`). A Handshake that fails closes nothing, and a closed
    session is torn down on the reaper thread, not the Handshake's
    (SONNY-3252). (Round 16 correction: as shipped in round 15 the peer
    address was "unknown" for every client, so all anonymous clients, and
    all federation peers, shared one cap; fixed in round 16, SONNY-3313.)
  - DROP GRAPH drops a graph that already had a reserved name (a
    CURRENT_GRAPH made before 0.8.23), and the server warns at start for
    each such graph; CREATE stays refused (SONNY-3234).
  - A dropped graph's id map is freed when no walk holds it; it was kept
    until the server stopped (about 0.5 KB per DROP GRAPH). A reload or a
    Raft snapshot install no longer frees id maps a walk holds. A QUIC
    admission thread's stack is 8 MiB in a release build (16 MiB in
    Debug), set by `GEODE_QUIC_ADMISSION_STACK_MB`: the stacks reserve
    `admission threads x stack` of address space (4096 x 16 MiB was 64
    GiB), which strict overcommit counts. A thread that cannot be spawned
    rejects its connection; the server serves on (SONNY-3253).

  **Behaviour change:** a query whose expression runs into a limit
  answers 54001 (or 53200, 57014) instead of fewer rows. At the gRPC
  session cap, a Handshake is refused rather than closing a session in a
  transaction; anonymous clients of one host share a cap. To remove a
  graph named CURRENT_GRAPH, CURRENT_PROPERTY_GRAPH, HOME_GRAPH or
  HOME_PROPERTY_GRAPH made before 0.8.23 (the start-up log names each),
  run `DROP GRAPH <name>` with the name exactly as stored.
- **Round 16: the round 15 review's findings (SONNY-3312, SONNY-3313,
  SONNY-3314, SONNY-3315, SONNY-3316, SONNY-3317):**
  - A read whose statements run on several graphs (`MATCH ...; USE GRAPH
    g2; MATCH ...`) reads each of them: round 15's snapshot copied only the
    session's graph, so the other graphs read as empty (a regression in
    round 15). The read takes each graph's read lock, shared and in name
    order, and snapshots every graph it reads (SONNY-3312).
  - A parallel UNION's result freed its nodes through an allocator that
    lived in a function that had returned: `MATCH (n:C) WHERE n.v >= 0
    RETURN [[...60 levels...]] AS v UNION ALL ...` hung the request thread,
    and any read could corrupt its stack; pre-existing (SONNY-3315).
  - A limit the evaluator runs into, out of memory included, fails the
    query where a caller had turned it into a value (an EXISTS or COUNT { }
    subquery's WHERE, an ORDER BY key, the node scan's inline-property seek)
    and in a parallel UNION arm (it runs on a thread of its own, and its
    record of the limit was lost). (Round 17 correction: this held for
    statements run through the executor's statement entry point only; a
    PROFILE, and an out of memory materializing a node in the node scan,
    could still become an answer. Fixed in round 17, SONNY-3349.) A
    grouped HAVING chain is compared only with projected items and keys of
    its own length: 32 items of 4088 links took 13 s to rewrite, now under
    0.1 s (SONNY-3316).
  - A dropped graph's id map and name are freed by their last holder: a
    lookup of a node or edge by id (the bounded caches' hydrate-on-miss), a
    first-touch hydration and a walk over every graph each hold the map they
    use. Round 15 freed them while such a lookup or hydration still used
    them (a use after free next to DROP GRAPH), and kept every dropped map
    while any walk ran, which overlapping walks made forever. DROP GRAPH now
    waits for a first-touch hydration of the graph and none starts during
    it: the two could deadlock, and a hydrate-on-miss racing the drop freed
    a node's labels twice (SONNY-3314).
  - The gRPC Handshake keys a client by its real peer address: it was
    "unknown" for every client, so every anonymous client counted against
    one `anonymous@unknown` session cap (one host holding its sessions in
    transactions refused every other host's Handshake), and the auth rate
    limiter's per-IP bucket was one bucket for all clients (one client's
    username-rotating guessing locked every client out). Clients behind
    one NAT gateway, proxy or load balancer share a cap and a bucket; an
    IPv6 host that rotates addresses within its /64 is several peers
    (SONNY-3313).
  - Smaller fixes (SONNY-3317): CREATE GRAPH that ran out of memory
    partway could free the graph's name twice; `GEODE_QUIC_ADMISSION_STACK_MB`
    takes at least 8 (it took 1, on which a plain MATCH was refused); a
    reload or a Raft snapshot install clears the node, edge and adjacency
    caches under their locks and the store's (pre-existing: a read racing
    one could crash); a gRPC Handshake for a tenant that ran out of memory
    kept one of the tenant's connections counted; a session closed to make
    room at the cap is logged when the reaper tears it down, too.

  **Behaviour change:** `GEODE_QUIC_ADMISSION_STACK_MB` below 8 is taken
  as 8.
- **Round 17: the round 16 review's findings (SONNY-3348, SONNY-3349,
  SONNY-3350):**
  - Once a caller swallows a limit (54001, out of memory, the read budget,
    a cancel) or an IN type error, the store refuses every further change
    of the statement, before the engine, the in-memory graph, the WAL and
    Raft replication see it, and a cluster leader proposes nothing. The
    relay failed the statement only after it had run, so its writes stayed:
    `MATCH (n:C) SET n.w = EXISTS { ... }`, where the subquery's WHERE ran
    into 54001, answered 54001 with `n.w` set to false on every row
    (SONNY-3348). (Round 18 correction: this refused only the changes made
    after the limit was recorded. Those made before it stayed: earlier
    rows, a SET before a RETURN or ORDER BY that ran into the limit, a
    change before a WITH the MATCH executor evaluates late, the point-write
    fast path's write (its only expression is its RETURN), MERGE, FOR and
    PROFILE. In an explicit transaction the session then left the
    transaction and ran its next statements in autocommit, and a
    `START TRANSACTION { ... }` body's rollback did nothing. Fixed in
    round 18, below.)
  - The limit relay covers exactly these paths: every statement the
    executor runs (`executeStatementWithContext`: the statements of a gRPC,
    QUIC or embedded program, and EXPLAIN'd or PROFILE'd statements other
    than queries); a PROFILE'd query (`executeProfiledIfSupported`, which
    answered a swallowed 54001 or out of memory as a profile, 00000, and
    kept a PROFILE'd change's writes); the arms of a parallel UNION; and
    the engine-direct node scan, whose paging scan, filtered count and
    WHERE + LIMIT enumeration fail on an out of memory materializing a
    node, where they skipped the node as if it had been deleted
    (SONNY-3349). The bulk-ingest fast paths take literals and parameters
    only, and fail on any evaluation error.
  - Smaller fixes (SONNY-3350): a Raft `drop_graph` entry takes the
    graph's write lock, as DROP GRAPH does, so it waits for the graph's
    requests (it freed the graph under them); the engine-direct readers
    pin a graph's id map while they read it (a reader holding only the
    global lock did not hold off a DROP GRAPH, which freed the map); and a
    read of several graphs checks the principal's access to each before it
    locks or copies any (it took the read lock of, and copied, a graph the
    principal was then refused).
- **Round 18: the round 17 review's findings (SONNY-3348, SONNY-3059,
  SONNY-3349, SONNY-3350):**
  - A statement that fails changes nothing. While a statement runs, each
    change the store makes records what it replaces (a property's old
    value or its absence, a label, a deleted node or edge with its labels,
    properties and edges, a created node or edge). When the statement
    fails, for any reason (54001, out of memory, the read budget, an IN
    type error, a division by zero), the record is undone,
    newest first, through the store's normal write methods, so the storage
    engine, the WAL mutation stream and the store's own indexes see the
    undo, before the error is answered. This covers every executor that
    changes data through the store (the MATCH executor and its write step,
    CREATE, MATCH ... CREATE, FOR, MERGE, DELETE, the point-write fast
    path, PROFILE'd statements), in autocommit and in a transaction. A
    retry applies the statement once (SONNY-3348). (Round 19 correction:
    on a cluster leader the statements that write once per row or per
    iteration proposed each row's write at once, so the rows before the
    failing one stayed on every node. Fixed in round 19, below.)
  - A failed statement aborts its explicit transaction. The transaction is
    rolled back at once, and every later statement of the session is
    refused with 25P02 until the client ends the transaction: ROLLBACK
    succeeds, and COMMIT fails with 40000 (the transaction was rolled
    back). A BEGIN is refused too. The session left the transaction
    silently, so the client's next statements autocommitted, and its
    ROLLBACK reported that no transaction was open.
  - ROLLBACK undoes every change a transaction made: SET and REMOVE of
    properties, labels added and removed, DELETE and DETACH DELETE (the
    node or edge comes back with its id, labels, properties and edges),
    MATCH ... CREATE, and the changes MERGE makes to what it matched; so
    does the rollback of a failed transaction and of a
    `START TRANSACTION { ... }` body. The undo log recorded only created
    nodes and edges, and undid through setters that changed the in-memory
    graph but not the storage engine (SONNY-3059).
  - A `START TRANSACTION { ... }` body's rollback runs when a limit failed
    the body; the write fence refused it. A body statement of a kind a body
    cannot hold (DELETE, for one) now rolls the body back too; it returned
    with the body's transaction still open on the thread.
  - Smaller fixes: the engine-direct readers no longer answer an engine
    slot as a node's id when they cannot read the node's public id; an out
    of memory there fails the query, and a node whose id is gone is
    skipped. The id map counts (`count(n)`, `count(r)`), the edge endpoint
    check and the per-graph edge list read the map pinned, as the other
    readers do.

  **Behaviour change:** after a statement fails in an explicit
  transaction, the session refuses every statement but ROLLBACK or COMMIT
  (25P02); COMMIT then answers 40000.
- **Round 19: the round 18 review's findings (SONNY-3348, SONNY-3384):**
  - On a cluster leader a statement commits all of its writes in one Raft
    entry, or none. The leader holds each write the statement makes and,
    once the whole statement has evaluated without an error, proposes them
    together: one entry as before when there is one, a statement batch
    (GBAT) when there are more. A statement that fails proposes nothing,
    and nothing proposed is undone. `FOR i IN [1, 2, 3] CREATE ...` and
    `MATCH ... MERGE ...` proposed one entry per row and waited for each,
    so when the third row failed the first two were committed on every
    node. Every node applies a batch's writes in order; a create in a batch
    takes ids of its own (`2^54 + (index * 4096 + position) * 64`). A
    client's idempotency key covers the whole statement: a retried
    statement is one no-op (the rows of one statement were taken for
    retries of each other).
  - A statement's undo record counts against the write budget
    (`GEODE_WRITE_EXECUTOR_BUDGET_MB`, 8192 MB by default, 0 for none):
    the record and the write executor's working set together stay under
    it. A write whose before-image does not fit is not made, and the
    statement fails with 53200 and undoes what it recorded:
    `MATCH (n) DETACH DELETE n` over a graph larger than the budget
    answers 53200 and leaves the graph as it was. The record held the
    image of every change it made, a whole graph for that statement, in
    memory no budget saw.
  - A failed statement whose undo cannot undo every change answers 40003
    (statement completion unknown), not its own error: it is partly
    applied, and a blind retry would apply the rest twice. ROLLBACK, and
    the rollback of a failed transaction, continue past a change they
    cannot undo (they stopped at the first and dropped the rest undone),
    and report it: ROLLBACK answers 40003, and so does the ROLLBACK or
    COMMIT that ends a transaction whose rollback was incomplete. The
    failures are counted (`statement_undo_replay_failures_total`, with
    `statement_undo_replayed_statements_total` and
    `statement_undo_budget_refusals_total`, on the metrics endpoint).
  - `MATCH ... SET ... DETACH DELETE x RETURN ...` deletes x with its
    edges and answers its RETURN. The query took DELETE after a SET but
    not DETACH DELETE: the SET was applied, the delete skipped, and the
    answer was one row of 0 (SONNY-3384). A SET or REMOVE before the
    DELETE is applied first, in order, by the one write step (SONNY-3042),
    and the RETURN is computed before the delete; a RETURN that holds an
    element the statement deletes is refused (0A000). (On the r12 line
    such a SET was refused; the v0.8.23 reconciliation keeps the v0823
    line's in-order write step.) `MATCH ... CREATE ... DETACH DELETE`
    likewise takes the deleted nodes' edges with them.
  - Smaller fixes:
    - A statement that fails in an explicit transaction aborts the
      session's engine transaction before its undo, which then commits on
      its own. The undo's changes joined the transaction's engine
      transaction, which was aborted next: after a crash the failed
      statement's write could come back.
    - A statement failing at a later page of its results, a node scan that
      fails to start with any error, and a request whose engine
      transaction outlived it all abort the explicit transaction; the last
      left the transaction silently, into autocommit.
    - The COMMIT and ROLLBACK messages carry the code of their failure:
      COMMIT of a failed transaction answers 40000 as the COMMIT statement
      does (it answered only `success = false`).
    - A node whose public id the engine-direct readers cannot read is
      skipped only when it is gone; any other read error fails the query.
    - The before-image of a deleted node reads its edges through the
      checked adjacency readers: an adjacency it cannot read refuses the
      delete (it recorded the node without its edges).
    - A Raft node freed the result of every entry it applied (a created
      node's id leaked, 8 bytes per create, on every node).

  **Behaviour change:** on a cluster leader, a statement whose later row
  reads what an earlier row of it wrote (MERGE of a key an earlier row
  merged with ON MATCH SET, a MATCH of a node or a label and property an
  earlier row created or changed) is refused (40001) before anything is
  proposed: the earlier rows are not applied until the statement's entry
  commits, so the leader cannot read them. A MERGE of a key an earlier row
  created, without ON MATCH SET, matches it. A statement of more than 4096
  writes, or of more than 1000 KiB of them, is refused the same way.

  **Upgrade note:** upgrade every node of a cluster before sending
  statements that write more than once. A node before round 19 does not
  know the batch entry: it logs "unknown create payload version —
  skipping" and applies none of it (no partial statement, no junk data),
  and falls behind the others. A statement with one write is proposed as
  before.

### Fixed

- **Inline TLS certificate options are honoured:** `--cert=...`,
  `--key=...`, `--listen=...` / `--listen-quic=...`, `--listen-grpc=...`,
  `--data-dir=...` / `--data_dir=...` and `--log-level=...` (the
  `--name=value` form Kubernetes argv uses) were dropped silently, so a
  server started that way ignored its explicit certificate and key. They
  are parsed as the `--name value` form is.
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
  read what the clause before had written. Geode had no documented rule; it
  now evaluates every right-hand side of one SET clause against the bindings
  as they stood before the clause, then applies its assignments, as SQL's
  UPDATE does; a later SET clause (`SET q.a = 1 SET q.b = q.a`) reads what
  the one before wrote. (This entry first cited openCypher for the rule:
  openCypher and Neo4j apply the items of one SET left to right, so a
  statement ported from Neo4j that reads, later in one SET clause, a
  property the clause assigns earlier reads the old value here. An
  evaluate-then-assign rule leaves two assignments to one element property
  in one SET with no order, so Geode refuses them; SONNY-3248 below.) Every SET and REMOVE of a MATCH runs in the one
  write step (a RETURN after it still shows what was written); MERGE's
  actions, the SET after a CREATE, and the cluster leader's MATCH ... SET
  (SONNY-3246's ordering part; its RLS check and WHERE truthiness remain)
  follow the same rule. The QUIC MERGE fast paths decline a MERGE whose
  actions hold more than one SET clause (`ON CREATE SET ... SET ...`), which
  they applied on the wrong branch (round-3 review I1, SONNY-3241; the
  MATCH ... CREATE edge fast path is not yet fixed).
  - **Behaviour change:** `SET a.c = b.i, b.c = a.c` stores b's old c.
    `SET a.c = coalesce(a.c, 0) + 1, b.c = coalesce(b.c, 0) + 1` with a and b
    the same node is refused (22G03, SONNY-3248 below; it stored 1). A MATCH
    ... SET or REMOVE without a RETURN answers the rows it wrote, as written.
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
- **The round-4a minors (SONNY-3248):**
  - **SKIP and LIMIT parameters:** a statement's SKIP or LIMIT given as a
    parameter was read by some executors only, so `MATCH (q:Q) SET q.z = 1
    RETURN q.i LIMIT $p` and an in-memory `MATCH (n) RETURN n.i ORDER BY i
    LIMIT $p` returned every row, and so did a LIMIT or SKIP parameter the
    statement's own `LET $x = ...` defines. The statement's window reads the
    parameter (the LET's value first, else the request's) as it reads a
    literal.
  - **One assignment per property in a SET clause:** a clause's values are
    all evaluated before it assigns them, so two assignments to one
    (element, property) have no order; the second silently won (`SET q.a =
    1, q.a = 2`, or `SET a.c = 1, b.c = 2` with a and b the same node). Such
    a clause is refused before anything is written (22G03, Geode's
    invalid-value code; this entry first said ISO GQL raises it, which the
    repository's grammar cannot confirm); so is `SET n = {map}` beside
    another assignment to n. Two clauses (`SET q.a = 1 SET q.a = 2`) still
    apply in order. Round 4b-1b: the refusal is decided on the statement,
    before any CREATE or MERGE inserts what it creates and before any
    transport's fast path runs it (below).
  - **A LET is scoped to its query:** `LET $z` inside a subquery defined $z
    for the whole statement, so `... IN (LET $z = 1 MATCH ... RETURN k.i)
    RETURN $z` passed the parameter check and read null. It is refused with
    42P02. A LET's parameter is defined for its own query, its expressions,
    and the parts and bodies it chains; a subquery inside an expression sees
    only its own LETs (the executor read an outer `$y` there as null, so
    `LET $y = 2 MATCH (q) WHERE q.i IN (MATCH (k) WHERE k.i = $y ...)`
    returned nothing; it is refused with 42P02).
  - **SESSION SET VALUE parameters are not readable:** `SESSION SET VALUE $sv
    = 3` stores a session parameter that no statement reads (it read as null
    before round 4a); a statement naming `$sv` is refused with 42P02 unless
    the request supplies it.
  - **UNIQUE constraints are not enforced on CREATE, MERGE or SET (known
    limitation):** the constraint check exists but no write path calls it;
    this is left for a later round.
- **A variable is one kind of element (SONNY-3367, round 4b-1 review
  C-1):** SONNY-3318's join read a later chain's first node pattern as
  unbound when its variable was bound as a relationship, so `MATCH (g)-[r:R]
  ->(x), (r) DETACH DELETE r` bound r to every node of the graph and deleted
  the graph, `... SET r.zz = 1` wrote every node, and over gRPC `... RETURN
  r` read a node as a relationship and aborted the server (integer
  overflow). A pattern that names one variable as two kinds of element (a
  node, a relationship, a variable-length relationship list or a path),
  within a statement part or through a WITH that passes the variable on
  (`WITH r`, `WITH r AS s`, and, since round 4b-1c, `WITH *`), is now
  refused as a syntax error (42000) before anything runs, on every
  transport and fast path; the join also never binds a relationship's name
  to a node. A node variable reused as a relationship (`(a)-[a]->(b)`), which
  joined silently before round 4b-1, is refused the same way.
- **A comma pattern's join streams (SONNY-3368, round 4b-1 review I-1):**
  SONNY-3318's join built each chain's product in full before the WHERE and
  the window saw it, and polled no budget: over 1,500 pairs, `MATCH
  (a:P)-[:E]->(b), (c:P)-[:E]->(d) RETURN a.i LIMIT 1` held 2.25 million
  bindings (37 GB, 54 s; 25 MB and 31 ms before round 4b-1). The join now
  completes one binding at a time, applies the WHERE to it before keeping
  it, stops at SKIP + LIMIT when nothing after the join needs every binding
  (no WHERE, FILTER, ORDER BY, DISTINCT, WITH, grouping, aggregate or
  write), and polls the read and write budgets (and, since round 4b-1c,
  at every step, not only at a completed binding), so a product past the
  read budget answers 53200 instead of exhausting memory.
  A WHERE that runs into a resource limit fails the query instead of
  dropping the row. What a comma read holds is the bindings it keeps; round
  4b-1's per-binding cost (three hash maps copied at every step, about
  16.7 KB a binding against 9.4 KB before) applies to the kept bindings
  only.
- **Every type of an alternation, on the first hop too (SONNY-3318, round
  4b-1 review I-5):** the first hop of a comma or multi-hop pattern, a
  variable-length hop, OPTIONAL MATCH's hops and an in-memory one-hop
  pattern read only the first type of `[:A|B]`: `MATCH (a)-[:S|R]->(b),
  (q:Q {i: 0}) RETURN count(*)` counted the S edges, and `... SET b.t = 1`
  wrote only their targets. Every type is walked now (the SONNY-3318 entry
  above said so of the later hops only).
- **A refused SET writes nothing, on every transport (SONNY-3248, round 4b-1
  review I-2, I-3):** a SET clause that assigns one property of a variable
  twice was refused only when the executor applied it: after a CREATE or
  MERGE had inserted what it created (`CREATE (z:Z) SET z.a = 1, z.a = 2`
  and `MERGE (a:W {k: 1}) ON CREATE SET a.x = 1, a.x = 2` answered 22G03
  and left the node), and never on the QUIC MERGE fast path, where the last
  assignment won (go/oidc's single-node key MERGE shape). It is refused
  from the statement now, before any path runs it. Two variables bound to
  one element are still refused where they are bound.
- **A label SET checks the node's vectors (SONNY-3319, round 4b-1 review
  I-4):** only a vector the same SET list assigned was checked against the
  labels it adds, so `MATCH (n:VO) SET n:VK` put a 2-dimension vector the
  node held under VK's 4-dimension HNSW index (and `CREATE (n:VP {emb: <2
  dimensions>}) SET n:VK` did the same). Each vector the node holds is
  checked against the indexes of the labels a SET adds (22000), and a
  CREATE's or MERGE's pattern is checked with the labels its SET (or ON
  CREATE) gives it, before the node is created.
- **LET chains, CALL { } bodies and window values (SONNY-3248, round 4b-1
  review I-6, m-2, m-3):** a LET was evaluated with no parameter in scope,
  so `LET $a = 2, $b = $a + 1 ... WHERE n.i = $b` and `LET $x = $p` read
  null, and `... LIMIT $b` returned every row; each LET now sees the
  request's parameters and the LETs before it (one naming a later LET is
  refused, 42P02). A `CALL { }` body sees the LETs before the CALL (`LET $x
  = 2 CALL { MATCH (n) WHERE n.i = $x RETURN n.i AS k } RETURN k` answered
  nothing). A SKIP or LIMIT parameter that is not a non-negative integer
  (`-1`, `2.0`, `'2'`) is refused (22G03) before anything runs; it read as
  "no window" and returned every row. A WITH's SKIP or LIMIT parameter
  windows the WITH in every session (an in-memory, tenant or RLS session
  returned every row).
- **A MERGE's RETURN holds no freed relationship (SONNY-3322, round 4b-1
  review m-4):** `MERGE ... MERGE (a)-[r:T]->(b) RETURN {rel: r}` returned
  a map holding the MERGE's own copy of r, which the MERGE freed; a map's
  (and a path's) relationships are the store's now, as a bare `RETURN r`'s
  were.
- **Comma MERGE actions (SONNY-3320, round 4b-1 review m-5):** a MERGE
  clause with a comma pattern (`MERGE (a:W {k: 1}), (b:W {k: 2}) ON MATCH
  SET a.m = 1 ON CREATE SET b.c = 1`) counts as created when it created any
  of its chains, so with a matched and b created, ON CREATE fires and ON
  MATCH does not: a.m is not set. Before round 4b-1 each action followed its
  own variable's state, so a.m was set too. This follows the
  MERGE-is-one-pattern rule of the SONNY-3320 entry above.
- **`WITH *`, a value and a FOR variable in a pattern (SONNY-3367, round
  4b-1b review I-A):** the kind check above carried a variable only through
  a WITH item naming it, so `MATCH (g:G {i: 1})-[r:R]->(x) WITH * MATCH (r)
  RETURN count(*)` bound `(r)` to every node (24 in the test graph), and
  `WITH * MATCH (a)-[g]->(b)` read a node as a relationship. `WITH *`
  passes every variable on with its kind now. A variable a WITH binds to
  an expression (`WITH r.w AS r`, `WITH collect(g) AS l`) or a FOR binds
  holds a value, not an element, and a later pattern naming it is refused
  the same way (42000); it bound every node (`FOR r IN [1, 2] MATCH (r)`),
  or none (`FOR n IN collect(g) MATCH (n)-[:R]->(x)`). An UNWIND, or a
  CALL { } that returns a variable, cannot be followed by a MATCH (the
  parser refuses both). Known, not changed: a variable passed on is not
  joined in the next part when the pattern names it alone or as a
  relationship (`WITH g MATCH (g)` matches every node, `WITH r MATCH
  (a)-[r]->(b)` every relationship); writes there are refused (0A000), so
  only reads are affected.
- **A comma join's memory is flat, and it polls at every step (SONNY-3368,
  round 4b-1b review I-B, I-C):** the join looked up the far node of every
  relationship it tried with `getNodePtrForScan`, which keeps a copy of the
  node until the graph's next checkpoint, outside the read budget: a WHERE
  that kept none of the 2.25 million bindings of two 1,500-pair chains grew
  the process by about 700 MB (1.4 GB at 2,121 pairs), and never answered
  53200. The join looks each node up once per statement now, and what it
  allocates to find a step's candidates, or to evaluate a binding's WHERE,
  is released when the step or binding is done: the same statement peaks
  at 40 MB in process (46 MB at 2,121 pairs), and adds less than 128 MiB to
  the peak of a gRPC or QUIC server (tested). The
  budgets and the stream's cancel were polled only at a completed binding,
  so a join whose last chain matched nothing (`MATCH (a:P)-[:E]->(b),
  (c:P), (d:P), (e:P {i: -1})`, 57 s at 400 pairs, about an hour at 1,500)
  could be stopped neither by a disconnect nor by the stall watchdog. Each
  step polls now, and a later chain whose start pattern binds a new
  variable and matches no node ends the join before it starts (4 ms). The
  LIMIT pushdown on the first hop's scan is kept for one chain of one hop
  with nothing after it that needs every binding; over a longer chain it
  cut `MATCH (a)-[:R]->(b)-[:S]->(c) RETURN c.i LIMIT 1` short.
  Cost (round 4b-1b review m-d, measured there): a one-hop `[:A|B]`
  pattern runs on the multi-chain executor since round 4b-1b; at 30,000
  relationships its time is that of `[:A]` (within 25%), and a WHERE over
  it peaks at about twice the memory (233 MB against 119 MB), the first
  chain's bindings being hash maps. A stopped join is stopped when the
  stream's cancel is set: a client disconnect, or the stall watchdog, which
  marks an idle QUIC connection's readers after 60 s (tested: an abandoned
  join over QUIC stops within 100 s).
- **A named path walks every type, and the multi-chain executor binds it
  (SONNY-3318, round 4b-1b review I-D):** `MATCH p = (a)-[:S|R]->(b)` read
  the first type only (1 or 10 of 11), and so did a shortest path's walk,
  an `EXISTS { }` or `COUNT { }` pattern, and the relationships a path
  reconstructs. A named path of more than one hop, or in a comma pattern,
  was never bound (`length(p)` 0, `p` null), and a one-hop path's WHERE
  (`WHERE length(p) = 1`) matched nothing. Every type is walked, the path
  is bound (for the WHERE too), and a shortest path keeps to the hop's
  types, direction and upper bound. Its end, when the query did not bind
  it, is the nearest node the end pattern matches; it was the first such
  node in the store's hash order, so `shortestPath((a:G {i: 1})-[:S|R*]->
  (c:Q))` answered a path or none depending on the session. A path
  variable on an OPTIONAL MATCH after the first pattern is refused (0A000):
  no executor binds it (`count(p)` was 0).
- **LET scoping, EXISTS and IN subqueries (SONNY-3248, round 4b-1b review
  I-E, m-a, m-b, m-e):** an EXISTS body evaluated its WHERE over names
  already freed, so it never matched:
  `WHERE EXISTS { MATCH (k:G) WHERE k.i = 2 }` answered 0 over every
  transport, with a literal, a parameter or a LET alike. An IN subquery
  now reads the statement's LETs as an EXISTS body does (it was refused,
  42P02, while the EXISTS form was accepted). A LET that names a request
  parameter shadows it: it was appended after the request's value, so
  `LET $a = 5 ... WHERE n.i = $a` read the request's $a while `LIMIT $a`
  read the LET's in memory and the request's in a persisted session. The
  LETs are evaluated once, before the statement runs, and every path reads
  them there (`LET $r = rand()` had two values, the window's and the
  statement's). A WITH's SKIP or LIMIT on a LET is checked on every path:
  `LET $w = -2 ... WITH n LIMIT $w` was 22G03 in memory and returned every
  row persisted. A CALL body's SKIP and LIMIT, a parameter's too, window it
  in every session:
  `CALL { MATCH (n:G) RETURN n.i AS k ORDER BY k SKIP 2 LIMIT 1 } RETURN k`
  returned every row. Known, not changed: the RETURN after a
  statement-level CALL body is not applied (`RETURN count(*)` returns the
  body's rows).
- **Two MERGEs of one node (SONNY-3248, round 4b-1b review m-c):** `MERGE
  (a:W {k: 1}) MERGE (b:W {k: 1}) SET a.x = 1, b.x = 2` answered 22G03 only
  where the executor bound a and b, after the first MERGE had created the
  node, which stayed. Two MERGE node patterns with the same labels and the
  same literal key name one node, and such a SET list is refused before
  anything is created.
- **A comma join's FILTER and WITH (SONNY-3386):** the multi-chain executor
  ignored a FILTER (`MATCH (g)-[:R]->(x), (q:Q) FILTER q.i = 3 AND g.i = 9`
  returned all 40 bindings) and a WITH's ORDER BY, SKIP and LIMIT after the
  join (`WITH g, q ORDER BY g.i DESC LIMIT 1` returned 40 rows, `WITH g, q
  SKIP 39` skipped none). The FILTER is applied after the WHERE, as the
  single-chain executors apply it, and a WITH after a comma join runs as
  every WITH stage does.
- **A node a chained part returns, over gRPC (SONNY-3385):** `MATCH (g:G {i:
  1}) WITH g MATCH (n:Q) RETURN n` aborted the gRPC server (an integer
  overflow in `nodeToProto`) on the Pull after the request: the stored
  result held the nodes the planned read materialized, whose labels and
  properties live in the request's scratch arena, returned to its pool when
  the request ended (a release build would have sent freed memory). The
  stored result owns copies of every node and relationship it holds (in a
  list, a map or a path too). Confirmed on a real gRPC server; QUIC
  serializes before the request ends and was not affected.
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
- **What a failed statement's undo and ROLLBACK do not reach
  (SONNY-3348, SONNY-3059).** They undo what the store changed. They do
  not revert a vector, full-text or other advanced index the executor
  updated for a changed property: such an index can keep the undone value
  until it is rebuilt. A change the storage engine refuses to undo (it
  runs out of memory mid-undo) is logged and counted
  (`statement_undo_replay_failures_total`), and the statement fails with
  40003 (round 19). A statement's record is its own thread's: a
  change made for it on another thread is not in it. A deleted node comes
  back with a new storage slot under its old id. The CLI's saved undo log
  does not keep a deleted node's tenant: after a CLI restart its ROLLBACK
  restores the node into the default tenant. The bulk-ingest fast paths
  (autocommit only) write storage directly and are not recorded; they take
  literals and parameters only and fail on any evaluation error.
- **A cluster write that fails after its Raft entry commits stays.** A
  statement on the leader proposes its writes, as one entry, only after it
  has evaluated completely without an error (round 19), so a limit or any
  other error in any row proposes nothing. If the entry then does not
  commit in time, the statement fails with 08006 and the outcome is
  unknown to the client, as for any timed-out commit: the entry may still
  commit, and nothing proposed is undone.
- **A Raft `drop_graph` entry can stall the apply loop (SONNY-3350, latent).**
  Applying it takes the graph's write lock. A leader writer that holds that
  lock while it waits (up to 5 s) for its own later entry to apply holds
  the apply loop, and the Raft ticks with it, for that long. Nothing
  proposes a `drop_graph` entry today.
- **Large QUIC requests can stall (SONNY-3232, left for S2).** The cause
  is loss recovery in the QUIC library (quic v0.1.44): when the receiver
  drains its socket slowly and the kernel drops datagrams in a burst, the
  library resends at most two lost packets per acknowledgement and then
  prunes the rest as if delivered, so the stream keeps a hole and the
  request is never answered. Whether that happens depends on timing (how
  loaded the server is, a Debug server more than a release one), not on the
  request's size: a release server answered 1 MiB in about 0.1 s and 4 MiB
  in about 1.4 s, and a Debug server stalled on 1 MiB in one run and
  answered 4 MiB in 15 s in another. The same loss recovery carries QUIC
  responses and the Raft transport. Keep QUIC requests small (use
  parameters). A request past the 16 MiB message cap is refused when its
  length arrives, but the server ends the stream without a reply, and the
  client, held by the stream window, fails only at its own timeout (34 to
  62 s observed). The server stays up and serves other connections in both
  cases.
- **A Debug build takes less nesting (SONNY-3191).** A Debug build's
  stack frames are several times a release build's: on an 8 MiB thread
  (the gRPC connection threads') it refuses some nesting of lists and calls
  past about 60, where a release build takes 128. (WITH, CALL { } and FOR
  chains stop at the 10-level query nesting limit in every build,
  SONNY-3244.) Debug builds are for development.
- **A transaction is not crash-atomic (SONNY-2979).** 15 of the 16 shards
  commit each operation on its own, and the undo log lives in memory only.
  A crash (a kill or a power loss) in the middle of a transaction leaves
  the operations run so far applied, and nothing rolls them back at
  restart.
- **Index DDL runs on the default graph, and indexes are database-wide
  (SONNY-2803, SONNY-3030):** DROP INDEX and a fulltext CREATE INDEX need
  the schema permission on `default`, whatever the session's graph, because
  they run on it (SONNY-2790). Indexes and constraints are catalogued for
  the whole database, so every index and constraint statement also needs
  the schema permission on the database (Admin, or `FOR SCHEMA` on `*`).
- **Offline auth commands need the HMAC key (SONNY-2798, SONNY-3035):** on
  a store that holds any security record or a chain root, an offline
  command refuses, and changes nothing, when no HMAC key is available to
  verify the chain with. Set
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
  a client parameter (SONNY-3183), and a write inside an expression
  (SONNY-3182). Split such a statement. Inside an explicit transaction every
  allowlisted shape is accepted, a label SET or REMOVE included (refused on
  the v0823 line while a rolled-back `SET n:L` kept its label postings), and
  ROLLBACK undoes it (SONNY-3059, round 18; see "What a failed statement's
  undo and ROLLBACK do not reach" under Known limitations).
- **Parser limits (SONNY-3244):** a request carries at most 1,024
  statements and at most 64 MiB of parsed form (54000); queries nest at most
  10 deep (54001). A Debug build's QUIC connection admission threads have
  16 MiB of stack (SONNY-3191), so a nested query reaches these limits
  rather than the end of its stack.
- **A statement ends at a `;` (SONNY-3166):** the parser used to split two
  statements written without a `;` between them and run each on its own;
  that is now a syntax error (42601). Programs that relied on it (`CREATE
  ... CREATE ...` and `MERGE ... MERGE ...` stay one statement) need a `;`.
  `USE [GRAPH] g <statement>` stays one focused statement (ISO/IEC 39075
  §10.3) and needs none.
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
