# Changelog

## [Unreleased] - Time-Series Audit and Gap Closure

### Security

- **A server-side failure while checking a password is no longer a wrong
  password (SONNY-6598).** `verifyPasswordArgon2id` turned every Argon2
  key-derivation error (`catch return false`) and every malformed stored PHC
  string into "the password does not match", and the login verifier did the
  same with every error: a correct password whose Argon2id work could not
  allocate its memory on a loaded server was answered "Authentication
  failed" and counted toward the per-principal lockout, so server load could
  lock a user out and the operator saw a brute-force signal that was not
  one. A credential check now has three outcomes. Only a mismatch is
  "Authentication failed" and counted; a key derivation that could not run
  is "Authentication temporarily unavailable" (retryable), a malformed stored
  hash "Authentication unavailable: the stored credential of this account
  cannot be used (server-side error; contact the administrator)"; neither
  counts, both are logged at ERROR with the user name, on QUIC and gRPC
  alike, and an error never authenticates. The auth single-flight hands a
  waiter the owner's error instead of a rejection. With the process audit
  log on, every refused HELLO is audited: a failed login as
  `authentication_failure`/`LOGIN`/`failure`, a check that could not run as
  `system_event`/`AUTH_ERROR`/`error_` (refused HELLOs were not audited at
  all). The same rule now holds for `geode.auth.mfa_verify` / `mfa_enable`
  (a TOTP check the server cannot run is that error, e.g. 0A000, not 28000,
  and is not counted toward the MFA lockout), `SecurityManager.authenticate`
  (an unusable stored hash counts no failed attempt), the offline
  `geode user change-password --old-password`, and `__geode_security` chain
  verification (a check that could not run is `AuthChainUnverifiable` at
  startup and "could not be verified" in the CLI and the periodic check,
  not tampering). **Behaviour change:** `geode_auth.verifyPasswordArgon2id`
  and `user_management.verifyPassword` return `error.InvalidHashFormat` for
  a stored hash they cannot use (they returned `false`), and
  `hashPasswordArgon2id` returns `error.OutOfMemory` (not `HashingFailed`)
  when Argon2id cannot allocate. Regressions: `zig build
  test-sonny6598-verify-outcomes` (allocation-failure sweeps with
  `std.testing.checkAllAllocationFailures`), `test-sonny6598-kdf-error-hello`
  (a real Debug server, QUIC and gRPC, with a test-only KDF fault hook that
  exists only in test and Debug builds). See docs/USER_AUTH.md, "What a
  client sees when a login is refused".
- **Cluster mode: the Raft log and snapshots are encrypted under TDE
  (SONNY-6571).** With `GEODE_TDE_KEY` set, the storage engine encrypted its
  pages and WAL, but every cluster node's Raft log
  (`<data_dir>/raft/entries.wal`, written by the raft library's
  `FileStorage`) held each replicated write in plaintext: labels, property
  keys, string and integer values (a doc credited `raft_persistent.zig`,
  which nothing reached; removed by SONNY-6563). The Raft storage is now
  `FileStorage` behind a geode `Storage` (`src/distributed/raft_tde_storage.zig`)
  that seals every entry's and the snapshot's data with AES-256-GCM under a
  per-open key derived by HKDF-SHA256 from `GEODE_TDE_KEY` and a random salt,
  with a counter nonce; each entry is authenticated with its index, term and
  kind. The hard state (term and vote) holds no graph data and is written as
  before, so the vote is still durable before a reply leaves (SONNY-6563).
  `<data_dir>/raft/tde.marker` records that the directory is encrypted and
  under which key (a key check value, not the key). **BREAKING:** a cluster
  node with `GEODE_TDE_KEY` set refuses to start when its `<data_dir>/raft`
  holds Raft state written without TDE (`RaftStoragePlaintextUnderTde`; the
  directory is left as it was): rebuild the node from the cluster with an
  empty data directory (docs/TDE_FILE_LEVEL_ENCRYPTION.md, "Distributed
  Consensus (Raft)"). An encrypted Raft directory refuses to start without
  `GEODE_TDE_KEY` (`RaftStorageNeedsTdeKey`) or under another key
  (`RaftStorageTdeKeyMismatch`). Single-server data directories are
  unaffected. Not yet encrypted (found by the same scan, single server and
  cluster): label and relationship type NAMES in every shard's
  `labels.dict` and property key names in `props.idx` (graph-storage) and in
  geode's `prop_exact.idx` / `prop_rev.idx`; property values were found in
  none of them. Regressions: `zig build test-sonny6571-tde-at-rest` (real
  single server and 3-node cluster, every file under every data directory),
  `test-sonny6571-raft-tde-storage`; red until the names are encrypted:
  `test-sonny6571-schema-names` (docs/KNOWN_TEST_ISSUES.md).
- **The CLI no longer prints success for session, API-key and authn
  operations no server performs (SONNY-6554).** geode servers have no
  session-token authentication (the HELLO carries a user name and password
  only and no server keeps the session ids it issues) and read none of the
  CLI's API-key or authn state files. `geode session invalidate-all` said
  "invalidated" and did nothing; `geode auth validate --token` called any
  non-empty string valid; `geode session rotate` replaced the saved token
  with client-made random bytes; `session validate` / `check-idle`,
  `authn config|test-access|stepup-check|stepup-mark` and `apikey
  create|list|revoke|revoke-all|check-scope` reported results from local
  files or hard-coded rules. Each now exits 1 with `Error: ... is not
  supported by this server: <what>` and writes nothing (`--help` says so).
  `geode query --token` (parsed, never sent) and `geode auth logout
  --token` exit 2. `auth login`, `auth logout` and `session info` say the
  saved session is a local file no server accepts. **BREAKING:** exit codes
  and output of the commands above; scripts that relied on the old success
  lines (e.g. geodetestlab `authn_provider.yml`, `api_key_auth.yml`) must be
  updated. See docs/USER_AUTH.md, "Session and API-key commands".
- **One strict DSN parser for `--dsn` and the MCP endpoint (SONNY-6554,
  SONNY-6569).** `geode query` / `geode shell --dsn` ignored every query
  parameter but the credentials, including `insecure=true` (passed by the
  documented and test-harness DSNs) and `ca=`; `geode mcp --endpoint` used
  geode-client-zig's lenient `parseDSN`, so an out-of-range
  `connect_timeout` or a malformed `page_size` silently became the default.
  Both now parse with `geode.dsn_params.parse` (`parseDSNStrict` plus the
  docs/DSN.md parameter and boolean checks). The CLI applies `insecure=true`
  exactly like `--insecure-tls-skip-verify` (same warning, refused under
  production posture unless `GEODE_ALLOW_INSECURE_TLS=1`), `ca`/`cert`/`key`,
  `page_size` and `role`; refuses `tenant`, `server_name` and `tls=false`
  (exit 2), which it cannot apply; and warns that `hello_name`, `hello_ver`,
  `conformance` and the timeouts have no effect. **BREAKING (`--dsn` and
  MCP endpoint):** an unknown parameter, a parameter without `=`, a boolean
  other than `true/false/1/0/yes/no/on/off`, and a malformed or
  out-of-range `page_size` or timeout are refused; `--dsn` with a `:port`
  host (no host name) is refused, as the MCP endpoint refused it.
- **A credential in a `--server` host is refused, never resolved
  (SONNY-6569).** `host_port.split` accepted any byte in a host name, so
  `--server pw@host:3141` (and the REPL's `\connect pw@host:3141`) dialled a
  host named `pw@host`, sending the password to the resolver and the TLS
  server name. An `@` in a client address is now
  `UnencodedCredentialDelimiter`, and an unbracketed host must be ASCII
  letters, digits, `-`, `.`, `_` or `~` on every address path (client,
  `--listen`, peers). `geode restore` validates `--server` before printing
  it. **BREAKING:** such addresses are refused.

- **geode-client-zig v0.3.17: one set of DSN rules on every client path
  (SONNY-6550).** The MCP endpoint DSN (`geode mcp --endpoint`) is parsed by
  geode-client-zig, which split the userinfo at the first `@` anywhere in
  the DSN (a password holding `@` was cut short and its tail dialled as the
  host; an `@` in a query value moved the host into it), decoded `+` as a
  space, passed malformed `%` escapes through as typed and did not decode
  the graph path. v0.3.17 reads the userinfo by RFC 3986 §3.2 like the
  CLI's `--dsn`, and geode's `dsn_credentials` is now a re-export of the
  library's `config.redact` (one implementation; its decoder allocates a
  credential once at its exact size, where geode's resized the buffer and
  could free an unzeroed copy). The MCP endpoint now gives a userinfo
  credential precedence over a `user=` / `pass=` query parameter, per field,
  as docs/DSN.md and the CLI do (the library lets the query parameter win;
  geode puts the userinfo back). `geode query` / `geode shell` `--dsn`
  percent-decode the graph path like the library (`/my%5Fgraph` binds
  `my_graph`). A fragment and an out-of-range timeout get their own
  messages; no message echoes the DSN. **BREAKING (MCP endpoint):** a `%`
  in the user name, password, graph path or any query value must start a
  `%XX` escape (`50%off` is refused, `%25` is a literal `%`), `+` is a
  literal plus, and an `@` after the host (a raw `/`, `?` or `#` in a
  password, an `@` in the graph path or a query value) is refused; encode
  it as `%40`. **BREAKING (MCP endpoint and `--dsn`):** a fragment
  (`#...`) is refused (`--dsn` ignored it and dialled). **BREAKING (`--dsn`):**
  a `%` in the graph path must start a `%XX` escape. Port 0 is refused by
  the library itself now (`parseDSN` and `GeodeClient.connect`), so geode's
  own MCP port-0 check is gone; the IPv6 zone check stays. Regressions:
  `zig build test-sonny6550-dsn-rules`, `test-sonny6551-dsn-query-credentials`
  (shell and MCP endpoint precedence against a real server),
  `test-sonny6494-mcp-dsn-errors`, `test-sonny6531-cli-address-errors`.
- **Saved sessions: one std.json writer and reader, a private file, never
  through a symbolic link (SONNY-6551 items 1 and 2).** `geode auth login
  --save-session` wrote hand-built, unescaped JSON with the key
  `session_token` and no `system_fingerprint`, while `geode query` looked for
  `token` and `system_fingerprint`, so a saved session was never read back;
  the save followed a symbolic link at `~/.geode/credentials.json`, wrote in
  place, and in a Debug build panicked (fchmod of an `O_PATH` directory
  handle) whenever `~/.geode` existed; and a read-only `geode query`
  created `~/.geode` mode 0755. `session_storage.CredentialStore` is now the
  only writer and reader (`auth login`, `auth logout`, `auth token`,
  `query`, `session info|rotate`): std.json both ways, `~/.geode` 0700
  (group/other access removed, a symbolic link or another user's directory
  refused), a 0600 temporary file renamed over the final path, and a read
  that creates nothing and ignores, with a warning, a file that is garbage,
  in another format, a symbolic link, not yours, accessible by others,
  saved by another account or host (`system_fingerprint`), expired, or for
  another server. **Breaking:** files written before this change are not
  read (`Warning: saved session ignored: ...`) and not migrated; log in
  again. **Not fixed:** the QUIC HELLO has no session-token field and the
  server keeps no record of the session ids it returns, so a saved session
  still cannot authenticate a query; `geode query` now says so instead of
  silently doing nothing (docs/USER_AUTH.md, "Saved sessions"). The dead
  `tests/session_storage_integration_test.zig` (never compiled, wrote the
  real `~/.geode`) is removed. Regression: `zig build
  test-sonny6551-saved-session`.
- **The shell's history keeps no passwords and is never written to the
  working directory (SONNY-6551 item 3).** `CREATE USER` / `ALTER USER ...
  SET PASSWORD '...'`, `geode.auth.user_create(..., '<password>')` and
  `\connect user:password@host` were saved verbatim, to `<HOME>/.geode_history`
  for any HOME (a relative one included) or `.geode_history` in the working
  directory when HOME was unset, with the umask's mode. Following the mysql
  client, a line containing `password`, `identified` or `secret`, or calling
  `geode.auth.user_create` / `user_import` / `mfa_*`, is not recorded;
  `\connect` is recorded without its userinfo; the file is 0600; with no
  absolute HOME (or `GEODE_HISTORY`) there is no history file. Regression:
  `zig build test-sonny6551-repl-history` (pseudo-terminal, real server).
- **`geode serve` never puts its default data directory under the working
  directory (SONNY-6551 item 4).** With no `--data-dir` / `GEODE_DATA_DIR`,
  a relative `XDG_STATE_HOME` or HOME placed the data directory, HMAC key
  included, at `<cwd>/relstate/geode` or `<cwd>/relhome/.local/state/geode`.
  Both now count only when absolute (XDG Base Directory specification); an
  explicit relative `--data-dir` still works. Regression: `zig build
  test-sonny6551-relative-state-home`.
- **`--dsn` query-parameter credentials are read (SONNY-6551 item 5).**
  `geode query` / `geode shell` ignored `user=` / `pass=` and `username=` /
  `password=` (documented in docs/DSN.md, and the form test-harness DSNs
  use), so such a DSN logged in with no credentials. They are now read,
  percent-decoded; per field the userinfo takes precedence. Regression:
  `zig build test-sonny6551-dsn-query-credentials`.
- **A `--dsn` password may hold `@` and `:`, and no part of it is printed
  (SONNY-6544 item 1).** `geode query` and `geode shell` split `--dsn` at
  the first `@`, so `quic://admin:p@ss@host:3141` logged in with the
  password `p` at the address `ss@host:3141`, and `geode shell` printed the
  rest of the password in its `Connecting to ...` line. The userinfo now
  ends at the last `@` of the authority (RFC 3986 §3.2), user name and
  password are percent-decoded (`%40`, `%3A`, `%20`), and `+` is a literal
  plus. **Breaking:** a `%` in a DSN user name or password must start a
  `%XX` escape (write `%` as `%25`; `50%off` is refused instead of being
  sent as typed), and a DSN with an `@` after the host (a password holding
  an unencoded `/`, `?` or `#`, or an `@` in a graph name or parameter) is
  refused instead of being dialled at part of the password. Every client
  place that prints an address or DSN (`geode shell`'s `Connecting to`,
  `auth login`, the saved-session note, `session info`, `backup create`,
  `restore`, `--output`/remote-URI errors, REPL `\connect`, the
  `--audit-syslog` / `GEODE_AUDIT_SYSLOG_HOST` and LSP `--listen` errors)
  goes through `geode.dsn_credentials.redacted`: no userinfo, and secret
  query values (`pass=`, `password=`, `token=`, `*key*`, `*secret*`, ...)
  shown as `***`. Regressions: `zig build test-sonny6544-dsn-credentials`
  (real server whose admin password holds `@` and `:`, real CLI) and
  `zig build test-sonny6544-dsn-redaction` (table).
- **The mTLS client CAs are no longer trusted for server certificates
  (SONNY-6490 item 1).** Loading `GEODE_MTLS_CLIENT_CA` for
  `GEODE_MTLS_REQUIRED` also installed the bundle as the process-wide x509
  trust store, although the listener has taken it directly since SONNY-6457
  (`inline_client_ca_der`). Every client TLS context created later in the
  server process validates a server certificate against that store when it
  has no CA of its own, so a QUIC dial without one (`QuicClient.connect`,
  `connectEx` with no CA) accepted a server presenting a client identity
  from the bundle, or a chain ending in a client CA. The bundle now reaches
  the listener only (`loadClientCaTrust`, formerly `installClientCaTrust`).
  No outbound dial of a running server relied on it: the cluster peer dial
  (raft, coordinator, 2PC) and the remote KMS client pin their own CA, and
  the HTTP clients (KMS, S3 backup, webhook sink) use std's TLS with their
  own CA bundle. Also: with `GEODE_QUIC_PASSIVE_TEARDOWN=1` (tests) the
  transport is never torn down, and the client CA bundle it points at is now
  left allocated with it instead of being freed under it (item 2).
  Regression: `zig build test-sonny6490-client-ca-scope`.
- **The TLS exporter comes from the tls library again (SONNY-6448).** The
  remote-KMS attestation binds each reply to its channel with the RFC 8446
  §7.5 exporter (`EXPORTER-geode-kms-attest-v3`, SONNY-6442). geode computed
  that value itself because tls before v0.1.25 exported something else from
  a transcript the two ends did not share. quic v0.1.50 brings tls v0.1.27,
  whose `Context.exportSecret` is the RFC value, so geode's copy and the
  detector test that waited for the fix are removed. **Upgrade note:** the
  exported value is byte-for-byte the same as before (both are RFC 8446
  §7.5), so a KMS client and server on either side of this change still
  agree and a rolling upgrade needs no ordering. The exporter is used only by
  the remote-KMS channel; cluster peer TLS does not use it. Regression: the
  `exportSecret` known-answer test in `zig build test-quic-transport`, and
  `zig build test-sonny6442-kms-channel` end to end.
- **A user's own password change is refused in cluster mode (SONNY-1332).**
  `ALTER USER <self> SET PASSWORD` (and the forced reset after a
  `password_reset_required` login) is handled by the QUIC and gRPC
  transports, not by the auth DDL path, and had no cluster gate: it wrote
  the new password to the `__geode_security` graph of the one node it
  reached, so the old password stayed valid on every other member. It now
  fails closed like the other auth writes (`ClusterNotLeader` on a
  follower, `ClusterWriteNotReplicable` on the leader, 40001). Standalone
  mode is unaffected. Behaviour change: in cluster mode a user can no
  longer change their password, and one that must reset it at login cannot
  complete the reset until auth state is replicated. Regression: the
  `auth-self-password-change` surface of `zig build
  test-cluster-replicable-mutations`.
- **`db.relationshipTypes()` and `db.propertyKeys()` no longer list what
  only edges with an RLS-hidden endpoint carry (SONNY-6460 item 5).** The
  RLS label policies were applied to an edge's type only, so a user denied
  `:Sec` was still told the type and the property keys of edges that touch a
  `:Sec` node, which no MATCH of theirs reaches (SONNY-2679). Under a deny an
  edge now counts only when its type is allowed and neither endpoint is
  hidden; an endpoint that cannot be read counts as hidden. Regression:
  `zig build test-sonny6460-meta-rls` (in the aggregate).
- **Encrypted (TDE) stores no longer lose committed records
  (SONNY-6441; graph_storage 0.4.12).** The storage engine wrote the 16-byte
  AES-GCM tag over the last 16 bytes of every encrypted page. At the default
  8 KiB page size every node in the last slot of a node page (slot 169) lost
  its label count and flags and usually read back as deleted, and the last
  two incoming-edge heads of each directory page were lost; nothing errored
  because the page still authenticated. Fixed in the engine; a tampered page
  now fails instead of reading as empty. **Existing encrypted stores:** the
  fixed version reads them, but bytes already lost are not recoverable
  (affected nodes come back with a label count of zero; a deleted node in
  that slot reappears); `geode storage repair --tde-page-tail` (SONNY-6452,
  below) restores what is derivable.
  **No downgrade:** once pages are rewritten, older binaries fail with
  `DecryptionFailed`. Regression: `zig build
  test-sonny6435-tde-small-pool-node-loss` (now in the aggregate).
- **TDE cold-read overhead measured (SONNY-6452 item 3).** `zig build
  test-sonny6435-tde-overhead` now also times reads that miss the buffer
  pool (8-page pool per shard, 2.00 misses per read in both arms). With
  graph-storage v0.4.13 (hardware CRC32C) it is +55.7% to +61.4% on the dev
  host (about 6.2 against 9.8 us per read): an encrypted miss decrypts the
  page, a plaintext miss only checks its CRC. With 0.4.12's software CRC32C
  (about 15.9 us per 8 KiB page) the plaintext miss was the slower one
  (-72.5%). Published in docs/TDE_FILE_LEVEL_ENCRYPTION.md, "Measured
  overhead", with the other figures re-measured on 0.4.13; gated below
  +80%.
- **`geode storage verify --check tde-page-tail` and `geode storage repair
  --tde-page-tail` for encrypted stores written by graph_storage <= 0.4.11
  (SONNY-6452).** The check reads the store files without opening the store
  and reports, per graph and shard, the pages still in the old page format
  and what they lost: slot-169 nodes (`nodes_liveness_unknown`), nodes whose
  whole record was the lost tail (`nodes_lost`), lost incoming-edge
  directory heads, damaged adjacency entries; exit 1 while anything is lost.
  The repair (offline, takes the data-directory lock, refuses without
  `--i-have-a-backup` and `GEODE_TDE_KEY`) restores label counts from the
  label blocks and rebuilds the incoming-edge directory from the outgoing
  edges, rewriting those pages in the new format. Whether a slot-169 node
  had been deleted is recorded nowhere else: such nodes stay present and are
  listed. Run the check before the first start of the new build. See
  docs/TDE_FILE_LEVEL_ENCRYPTION.md, "Upgrading stores written before
  graph_storage 0.4.12". Regression: `zig build
  test-sonny6452-tde-page-tail-repair` (a store rewritten in the old page
  format).
- **`geode storage repair --tde-page-tail` restores damaged adjacency
  entries (SONNY-6452 item 1; graph-storage v0.4.13, SONNY-6461).** The last
  entry of a full v1 adjacency block (stores from before inline edge ids)
  lost its edge type and property head to the old page envelope, so the
  edge read untyped and without properties. The repair now runs
  graph_storage's `repairAdjTailEntries` first, which copies the lost
  fields back from the same edge's entry in the other direction's chain,
  then the node and directory repairs; the summary reports
  `adjacency_entries_repaired` and lists each entry it could not repair,
  with the reason, in `adjacency_unrepaired` (for example `mirror_in_tail`,
  when both copies lost the same bytes). geode had never updated the
  incoming copy's property head when it set an edge property, so the repair
  first sets it from the edge index the old build wrote
  (`adjacency_mirrors_realigned`); without that the edge would have been
  restored with no properties and, for an edge without an inline id, no
  public id. The repair also lowers a shard's live-node count by the nodes
  it reports lost (`node_count_corrected`): geode refused to load a graph
  whose shard counted more live nodes than it held, so a repaired store
  with a lost node could not be opened. The check takes its table of lost
  slots from graph_storage (`edge.legacyTailLoss`). Regression: `zig build
  test-sonny6452-tde-page-tail-repair`.
- **A graph refused for disagreeing shard label dictionaries says so, and a
  split left by the old ORDER BY path can be repaired on request
  (SONNY-6524).** Every label id geode has written into a record, on any
  shard, is shard 0's: names were given through a view of shard 0's
  dictionary (from the move to the sharded engine, 2026-04-25) or through
  `ShardedGraphEngine.getOrAssignLabel`, which has returned shard 0's id
  since it was added, and geode reads names through shard 0's dictionary
  only. When graph-storage 0.4.15 refuses a graph (above), geode now reads
  its 16 dictionaries and logs which of two shapes it has (ERROR, scope
  `storage`, with the graph name). (a) Shard 0 names every label the other
  shards name, in the same id order: what the old ORDER BY path, the
  shard-0-only naming before 2026-05-29 and a 0.4.14 broadcast that failed
  part-way left. Shard 0's names are the ones the records were written with.
  (b) A shard names a label shard 0 does not have, or orders two labels the
  other way round: shard 0 lost a name (graph-storage 0.4.13 and older wrote
  dictionaries only at checkpoint and went on to the next shard after one
  failed), and rewriting the other shards from shard 0 would drop or rename
  labels. New `GEODE_LABEL_DICT_ADOPT_SHARD0` (comma-separated graph names):
  a graph named there in shape (a) is opened with graph-storage's
  `.adopt_shard0`, which rewrites shards 1..15 from shard 0 (logged as a
  WARN); it opens normally from then on. Shape (b) is refused even then and
  needs a manual repair. geode does not adopt on its own: if shard 0 lost a
  name, the old ORDER BY path gave its id to a label no node had yet, and
  the lost name was named again, the dictionaries look exactly like shape
  (a) while the nodes written before the loss carry the reused id, and
  adopting reads them under the other label (as geode already did before
  0.4.15). Reads and writes of a refused graph now fail with 58000
  `LabelDictionaryDiverged` (they reported the generic `GraphQuarantined
  ... restart the server to retry`, which a restart does not fix).
  Regression: `zig build test-sonny6524-label-dict-split` (each shape built
  with the engine calls that produced it and written through the adapter's
  CREATE paths: refused by default with nothing written; adopted on
  request with every node and relationship on every shard read back under
  the label it was created with, through geode and through the owning
  shard's own dictionary; the lost-name shapes refused even when asked,
  and graph-storage's own adoption shown to read each of the 32 nodes
  written before the loss under a wrong label or none; a real server
  answers its other graphs throughout and counts the adopted graph's
  labels as created).
- **graph-storage v0.4.15 (SONNY-6524): a new label name costs about a
  sixth of what it did, a failed label write is undone, and shard label
  dictionaries are compared at open.** `ShardedGraphEngine.getOrAssignLabel`
  makes a new name durable on shard 0, then on shards 1..15 in parallel with
  shard 0's id (0.4.14 wrote the 16 dictionaries one after another: 32
  serial fsyncs). Measured against a real server with the 0.4.14 and 0.4.15
  binaries of this branch, 5 interleaved rounds, medians, dev host at load
  average about 4-5: a CREATE that introduces one new label 575 -> 96 ms, a
  MERGE 567 -> 96 ms; one CREATE that introduces 30 new labels
  16.7 -> 2.29 s; a `/*+BATCH*/` bulk-MERGE that introduces 10 new labels
  5.96 -> 0.79 s; CREATE and MERGE on existing labels unchanged (about
  17 ms in both). The same bench measured 0.4.13 at 325 ms per new label
  on 2026-11-13 (not re-run here), so a new label is now cheaper than it
  was before 0.4.14 made label names durable. A failed durable write of a
  new name no longer leaves the name in memory, where later statements
  found it and never wrote it (and the shards after the failing one never
  got it). geode has nothing left to remove: it stopped rewriting the 16
  dictionaries itself with SONNY-6491, and every path that names a label
  goes through `getOrAssignLabel`.
  **BREAKING (operator): a graph whose shard label dictionaries disagree in
  a way its records depend on is not opened.** `ShardedGraphEngine.open`
  compares each shard's `labels.dict` with shard 0's. A shard that is only
  missing names, or names ids no record on it uses, is rewritten from
  shard 0; otherwise the open fails with `LabelDictionaryDiverged` and
  nothing is written. Graphs split by geode's old ORDER BY path (below) are
  refused once a node, relationship or ordered index on shards 1..15 uses a
  label named after the split. Reads and writes of such a graph fail with
  a 58000 error; the server and its other graphs keep serving. No store
  format change and no downgrade restriction from 0.4.14. Same transitive
  dependencies as 0.4.14.
- **graph-storage v0.4.14 (SONNY-6473, SONNY-6491, SONNY-6470): crash
  recovery and checkpoint ordering.** Crash recovery applies only the
  newest committed image of each page (by LSN): transactions that overlapped
  a batched transaction on the same shard no longer lose committed writes
  after a crash, including in logs written by older releases that are still
  on disk at upgrade. A checkpoint now makes `free.store` durable before the
  manifest, and the manifest rename durable before the WAL truncate; a stale
  `free.store` left by a crash during an older release's checkpoint is
  detected at open and rebuilt from the store files (logged as a warning).
  A new label or relationship-type name is made durable (fsync, rename,
  directory fsync of each shard's `labels.dict`) when it is first assigned;
  checkpoints no longer write `labels.dict`, and creating a graph writes an
  empty one. A store whose `labels.dict` lost names to a crash during an
  older release's checkpoint logs a warning at open; those names cannot be
  recovered. WAL record checksums use the CPU's CRC32C instruction, which
  took about 50 us off each operation of the commit path without fsync in
  both TDE arms of `zig build test-sonny6435-tde-overhead`; encryption still
  costs about 26 us there, so the published TDE overhead on that path is
  now about +29% (four runs: +28.8% to +38.1%, the high one at load average
  99; 0.4.13: about +20%). With the default per-commit fsync it is about
  +1%, on buffer-pool misses about +60%; the gates (35%, 5%, 80%) are
  unchanged. docs/TDE_FILE_LEVEL_ENCRYPTION.md, README, KMS_PROVIDER_SYSTEM,
  DESIGN_TDE_KMS and SERVER_FEATURES carry the new figures.
  **Upgrade notes:** no store format change and no downgrade restriction
  from 0.4.13. The first record of each new label name costs 16 file fsyncs
  and 16 directory fsyncs (one of each per shard, serially, inside the
  engine); geode no longer rewrites the 16 dictionaries itself (it did on
  first sight of a name since GAP-0915: 16 file fsyncs, which 0.4.14 made
  redundant). Writes that reuse existing names are unchanged. Measured
  against a real server, 0.4.13 and 0.4.14 binaries as shipped, 5
  interleaved rounds, medians, dev host at load average about 5: a CREATE
  or MERGE that introduces one new label 325 -> 620 ms and 321 -> 618 ms
  (1.9x: 32 fsyncs against 16, about 20 ms each on this disk); one CREATE
  that introduces 30 new labels 8.9 -> 17.5 s; a `/*+BATCH*/` bulk-MERGE
  that introduces 10 new labels 3.1 -> 6.2 s; CREATE and MERGE on existing
  labels unchanged (19-23 ms in both). Without the removal it was about 3x
  (48 fsyncs). Ingest that introduces many distinct labels pays this once
  per name (graph-storage 0.4.15 brings it to 96 ms, above). Regression:
  `zig build test-sonny6491-label-name-crash` (every label-creating write
  shape, SIGKILL, restart, counted by label and listed by `db.labels()`).
- **An ORDER BY on a label no node has yet no longer loses that label or
  splits the shards' label ids (SONNY-6491).** `MATCH (n:L) RETURN n.k
  ORDER BY n.k LIMIT m` starts a one-time background build of the
  value-ordered index; for a label no node carried, the build named `L` in
  shard 0's label dictionary only, not through the engine. With
  graph-storage 0.4.14, which writes `labels.dict` only when the engine
  assigns a name, a following `CREATE (:L)` lost `L` after a crash
  (`MATCH (n:L)` found nothing) and `db.labels()` stopped listing it after
  any restart; and since shards 1..15 never learned `L`, every later new
  name got an id one lower on those shards than on shard 0. Queries read
  names through shard 0's dictionary, so no wrong rows came back, but the
  other shards' dictionaries on disk named the wrong labels for those ids.
  The ORDER BY now declines to start a build for a label no node has (a
  read names no labels; the first ORDER BY after the label's first node
  builds the index), `createOrderedIndex` names an unknown label through
  the engine on every shard, durably, and the shard 0 dictionary view
  refuses to assign names (`error.LabelDictionaryViewIsReadOnly`).
  **Existing stores:** dictionaries already split this way stay split (the
  engine does not reconcile them); geode reads only shard 0's, which is
  consistent with the records. (graph-storage 0.4.15, above, refuses to
  open such a graph once records use the disputed ids.) Regression: `zig build
  test-sonny6491-orderby-label-intern` (SIGKILL and clean restart, the 16
  shard dictionaries on disk compared name by name, `createOrderedIndex`
  on an unseen label, and the ORDER BY trigger naming nothing).
- **graph-storage v0.4.13 (SONNY-6461).** Adds `repairAdjTailEntries`,
  hardware CRC32C page checksums (an 8 KiB page about 15.6 us -> 0.75 us,
  on every buffer-pool miss and flush), an offline `free.store` reader and
  the compare-bench zero-baseline fix.
- **Crash durability (SONNY-6424): wal v0.1.23, graph-storage v0.4.12,
  raft v0.1.22, timeseries-storage v0.2.20.** The storage engine anchors its
  WAL sequence at the last checkpoint on open, and the WAL keeps its
  sequence file when compaction empties the log.
- **BREAKING (operator): `GEODE_MTLS_REQUIRED` verifies client
  certificates against `GEODE_MTLS_CLIENT_CA`, and refuses to start without
  it (SONNY-6453 item 1).** The server asked for a client certificate but
  never told the TLS layer which CA to trust, so a certificate from the
  operator's CA was rejected; and a client that sent ANY certificate without
  a CertificateVerify (no proof it holds the key, no chain validation) passed
  the "certificate present" check and went on to authenticate by password.
  Now `GEODE_MTLS_CLIENT_CA` (a PEM bundle of CA certificates) is the only
  trust anchor for client certificates; a certificate counts only with a
  verified CertificateVerify; and `geode serve` exits at startup when
  `GEODE_MTLS_REQUIRED` is set and `GEODE_MTLS_CLIENT_CA` is unset, cannot
  be loaded, or holds a non-CA certificate, or when `--listen-grpc` is also
  given (the gRPC transport does not verify client certificates).
  Regression: `zig build test-sonny6453-mtls-client-ca`.
- **An mTLS server accepts a leaf of a `GEODE_MTLS_CLIENT_CA` CA sent
  without its chain (SONNY-6457 item 2; quic v0.1.50, tls v0.1.27).** The
  TLS layer checked a client chain only as sent, so a leaf signed by a
  bundle CA was rejected unless the client also sent the CA; geode's Zig
  clients send only the leaf, so only a pinned self-signed CA certificate
  worked. `installClientCaTrust` now keeps the bundle's DER certificates
  and `geode serve` hands them to the QUIC server's TLS context
  (`QuicTransport.Config.inline_client_ca_der`), which trusts only those
  CAs for client chains and completes a leaf-only chain from them, also
  when the bundle holds several unrelated CAs. Unchanged: the certificate
  counts only with a verified CertificateVerify, every certificate must be
  within its validity period, a leaf whose extendedKeyUsage lacks
  clientAuth is rejected (one with no extendedKeyUsage is accepted, as RFC
  5280 specifies), and `geode serve` still refuses to start with mTLS
  required and no usable bundle. Regression: `zig build
  test-sonny6453-mtls-client-ca` (a leaf of a bundle CA sent alone, a leaf
  of the second of two unrelated bundle CAs, an expired leaf, a
  serverAuth-only leaf).
- **geode's internal QUIC client presents the client certificate it is
  given (SONNY-6457 item 1).** `QuicClient.connectEx` put a client
  certificate path in the vendor config's `cert_path`, which makes the
  vendored quic endpoint a server, and never loaded the certificate, so
  no geode-side dial could present one. It now loads the PEM certificate
  and key into the client TLS fields (`inline_client_cert_der` /
  `inline_client_priv_key`), and refuses before dialling when only one of
  the two is given (`ClientCertificateKeyMismatch`) or a file cannot be
  read or parsed. Cluster peer dials (`cluster_auth.dialClusterPeer`)
  still present no certificate: peer listeners do not request one and
  peers authenticate with `GEODE_CLUSTER_TOKEN`. `geode query` / `shell`
  / `backup` / `mcp` dial through geode-client-zig, which had the same
  defect; v0.3.15 presents the certificate as a client, so `geode query
  --client-cert --client-key` is accepted by an mTLS-required server.
  Regressions: `zig build test-sonny6457-connectex-client-cert` and `zig
  build test-sonny6457-cli-client-cert` (the real `geode query` binary).
- **The Vault Transit and AWS KMS clients compile again (SONNY-6457 item
  4).** `src/security/external_kms_client.zig` built `std.http.Client`
  without the `io` field Zig 0.16 requires and used the removed
  `open`/`write`/`finish`/`wait` request API; nothing constructs these
  clients yet (KMS wiring is SONNY-6380), so no build noticed. Both now
  POST through `std.http.Client.fetch`; the Vault token (and the
  configured `vault_namespace`, previously ignored, as
  `X-Vault-Namespace`) are privileged headers, dropped on a cross-host
  redirect; responses are parsed as JSON instead of by substring search,
  so a pretty-printed Vault response is read and a field name inside a
  string value is not; a decrypted data key must be exactly 32 bytes.
  Still not production-ready: AWS requests are not SigV4-signed,
  `tls_ca_cert` is not used (the system CA bundle is), and the Vault
  ciphertext lives only in memory. Regression: `zig build
  test-sonny6457-external-kms-compile` (no network calls).
- **BREAKING (CLI): `geode mtls` subcommands are refused as unsupported
  (SONNY-6457 item 5).** `geode mtls map create|list|delete`, `config` and
  `status` kept certificate-to-user mappings in `geode_mtls_state.db` in
  the CLI state directory and reported success, but the server never read
  that file and its certificate-to-user store is never populated, so a
  mapping changed nothing. Each now exits 1 with a message naming
  SONNY-6458 (the mapping story) and how mTLS is actually enabled
  (`GEODE_MTLS_REQUIRED=1` + `GEODE_MTLS_CLIENT_CA`); `geode mtls --help`
  says the same. An existing `geode_mtls_state.db` is left alone and
  ignored. Regression: `zig build test-sonny6457-mtls-cli-unsupported`.
- **BREAKING (operator): `geode query`, `geode shell` and the REPL refuse
  an implicit unverified connection under production posture, like
  `geode auth` (SONNY-6453 item 4).** With no `--ca-cert`, no client
  certificate and no `--insecure-tls-skip-verify`, they connected without
  verifying the server (a stderr warning since SONNY-6448). One rule now
  applies to every CLI command (`zig_quic_bridge.liveInsecurePosture`, the
  SEC-CLI-01 gate): a release build, or `GEODE_ENV=production`, refuses
  with `ImplicitInsecureTlsRefused` and says to pass `--ca-cert` (or the
  insecure flag with `GEODE_ALLOW_INSECURE_TLS=1`); `geode backup` /
  `restore` and the `geode auth` login path, which verified with no trust
  anchor and failed the handshake, now refuse up front with the same
  message. A Debug build outside `GEODE_ENV=production` keeps the
  warning-only developer default. Scripts that ran a release `geode query`
  with no CA must pass `--ca-cert`: `scripts/docker/test.sh`,
  `scripts/docker/test-ci.sh` (`GEODE_CA_CERT`, default `/certs/ca.crt`)
  and the `docker-compose.example.yml` dataset loader (`./certs/ca.crt`)
  are updated. Regression: `zig build test-sonny6453-cli-no-ca-default`.
- **BREAKING (operator): `geode mcp` refuses an endpoint DSN with
  `insecure=true` under production posture (SONNY-6453 item 3).** The DSN
  parameter (`insecure`, `insecure_tls_skip_verify`, `skip_verify`) turned
  server certificate verification off silently in any build. It now
  follows the CLI's `--insecure-tls-skip-verify` rule: refused
  (`InsecureTlsRefused`) in a release build or with `GEODE_ENV=production`
  unless `GEODE_ALLOW_INSECURE_TLS=1`, and a warning on stderr whenever
  accepted. Give the DSN a `ca=` bundle instead. Regression:
  `zig build test-sonny6453-mcp-insecure-dsn`.
- **Operator-visible: every compose file sets its PID limit as
  `deploy.resources.limits.pids` (SONNY-6453 item 5).**
  `docker-compose.yml`, `docker-compose.example.yml`,
  `docker-compose.gpu.yml`, `docker-compose.otel.yml`,
  `tests/docker-compose.test.yml` and `tests/ha/docker-compose.yml` used
  `pids_limit`, which Compose refuses next to a deploy limit; the limit
  (4096) is unchanged. The GPU and test-stack healthchecks ran
  `geode query` with no `--ca-cert`, which a release image now refuses
  (item 4); they use the image's shared `/usr/local/bin/health-check.sh`.
  `src/security/kms.zig` loses a dead `compat_fillRandom`; its inline tests,
  which no step could run (the file's import closure includes
  `external_kms_client.zig`'s Vault tests, which do not compile under Zig
  0.16), moved to `tests/test_kms_provider.zig` (`zig build
  test-kms-provider`), and the GAP-0499 secure-zero test has
  `zig build test-secure-zero`. Regression:
  `zig build test-sonny6453-hygiene`.
- **Operator-visible: every cluster peer dial uses one verified
  configuration (SONNY-6453 items 2 and 5).** The 2PC transport never read
  `GEODE_CLUSTER_CA_CERT`: it dialled with verification on and no trust
  anchor, so a verified 2PC handshake could never complete. It now dials
  exactly like raft and the cluster coordinator
  (`cluster_auth.dialClusterPeer`): verified against
  `GEODE_CLUSTER_CA_CERT`, or unverified with `GEODE_CLUSTER_INSECURE`
  (Debug builds only). With neither set, raft, the coordinator and 2PC
  refuse the dial with `ClusterCaRequired` and a log line naming the
  variable, instead of attempting a handshake against a "system CA bundle"
  geode never loads (the raft comment that promised one is corrected).
  2PC (`src/distributed/twophase.zig`) is reachable from no server path
  today. Regression: `zig build test-sonny6453-cluster-peer-tls`.
- **BREAKING (operator): QUIC clients verify against the CA bundle they are
  given, or do not connect (SONNY-6448 item 1).** `QuicClient.connectEx`
  (the cluster, Raft and 2PC peer path, which reads
  `GEODE_CLUSTER_CA_CERT`) logged a warning and connected WITHOUT a trust
  anchor when the bundle could not be loaded; a missing, unreadable or
  certificate-less file now fails the connect with the load error.
  `geode query`, `geode shell` and the REPL turned certificate verification
  off unless `--client-cert`/`--client-key` were given, so `--ca-cert` was
  ignored and a server signed by any CA was accepted; a `--ca-cert` now
  always verifies (chain and server name), and the no-trust-material
  default (no `--ca-cert`, no client certificate, no insecure flag) still
  connects unverified but says so once on stderr. Operators whose
  `--ca-cert` / `GEODE_HEALTH_CA_CERT` does not actually sign the server
  certificate (or whose certificate lacks the dialled name) now get a
  refused connection. Regression: `zig build test-sonny6448-tls-fail-closed`.
- **BREAKING (procedure): `CALL tde.test_transparent_encryption()` no longer
  answers `performance_impact_pct` (SONNY-6448 item 4).** The figure timed
  five AEAD encrypt+decrypt round trips against plain copies of the same
  buffers, which says nothing about TDE overhead (the flaw
  `tde.measure_overhead` had). The procedure still round-trips every test
  type through the server's TDE key and answers `types_tested`,
  `all_transparent` and `errors_encountered`. The overhead measurement is
  `zig build test-sonny6435-tde-overhead`. Regression:
  `zig build test-sonny6448-tde-transparent-encryption`.
- **Operator-visible: `docker compose config` accepts
  `docker-compose.distributed.yml` and
  `docker-integration/docker-compose.integration.yml` (SONNY-6448 item 5).**
  Their geode services set `pids_limit` next to `deploy.resources.limits`,
  which Compose rejects ("can't set distinct values on 'pids_limit' and
  'deploy.resources.limits.pids'"), so neither stack started. The limit
  (4096) is now `deploy.resources.limits.pids`. Docs and `.env.example` no
  longer give variables nothing reads (SONNY-6448 item 6): the cluster
  variables in `docs/docker/DOCKER.md` are the ones geode reads
  (`GEODE_CLUSTER_TOKEN`, `GEODE_PEERS`, `GEODE_NODE_ID`,
  `GEODE_CLUSTER_NAME`, `GEODE_CLUSTER_PORT`, `GEODE_CLUSTER_CA_CERT`), not
  `NODE_ID`, `NODE_ROLE`, `CLUSTER_NAME`, `GEODE_DISTRIBUTED`,
  `GEODE_SHARD_COUNT` or `GEODE_REPLICATION_FACTOR`; `docs/USAGE.md` drops
  `GEODE_LOG_LEVEL`, `GEODE_LOG_FORMAT`, `GEODE_TRACE_OPTIMIZER` and the
  `CDC_*` names and gives the TDE key as `GEODE_TDE_KEY` (not
  `GEODE_DISK_KEY_HEX`); `docs/deployment/DEPLOYMENT.md` and `.env.example`
  drop `GEODE_LISTEN_ADDR` (and `GEODE_MEMORY_LIMIT` / `GEODE_CPU_LIMIT`)
  and say `GEODE_LOG_LEVEL` is a compose variable passed as `--log-level`.
  The deploy-docs-truth test now runs `docker compose config` on every
  compose file (when docker is on PATH) and covers `docs/USAGE.md`,
  `docs/deployment/DEPLOYMENT.md`, `docs/docker/*.md` and `.env.example`.
  Regression: `zig build test-sonny6430-deploy-docs-truth`.
- **BREAKING (library): the `local_dev` KMS provider is removed (SONNY-6448
  item 7).** `KMSProvider` (`src/security/kms.zig`) offered a `local_dev`
  provider whose wrapping key was HKDF(key id); a wrapped key carries its
  key id, so anyone holding one could unwrap it, and its "legacy" unwrap
  used a nonce derived from CRC32(key id). It was constructible in a Debug
  build and nothing in the product used it (KMS wiring is SONNY-6380). It is
  gone with `localDevProvider`, the `defaultProvider` that returned it and
  their tests; `external_kms` (test builds only) is the one provider that
  wraps. The unused `connectClient` in
  `benchmarks/benchmark_remote_kms_unwrap_concurrency.zig`, which dialled the
  remote KMS with no CA bundle, is gone too. Regression:
  `zig build test-sonny6448-kms-dead-paths`.
- **BREAKING (operator): `geode fle migrate-encrypt` and in-process FLE
  refuse a `GEODE_MASTER_KEY` other than the recorded one (SONNY-6442 item
  8).** The key check value in `fle_master_key.kcv` (SONNY-6435) was
  checked by `geode serve` at startup only; `geode fle migrate-encrypt`
  and the in-process FLE key manager built a key manager from whatever key
  was set. Both now run the same check first, through the one helper
  `geode serve` now uses (`src/keys/master_key_check.zig`
  `verifyOrRecord`), against the data directory the FLE catalog lives in:
  another key fails with `MasterKeyMismatch` before any key is derived, and
  a directory without a value records one. Regression:
  `zig build test-sonny6442-master-key-check-paths`.
- **Operator-visible: compose health checks run, and geode no longer waits
  for Vault, MinIO or Redis (SONNY-6442 item 7).**
  `docker-compose.example.yml` and the three nodes of
  `docker-compose.distributed.yml` health-checked with
  `["CMD", "geode query", ...]`; exec form runs the first element as the
  program, so the check ran a program named `geode query` and never passed.
  They now run the image's `/usr/local/bin/health-check.sh` (GET `/health`
  on `GEODE_METRICS_PORT`). The `QUIC_GO_DISABLE_GSO` comment (a quic-go
  variable geode does not read) is gone from `docker-compose.yml`. The
  geode services of `docker-compose.yml`, `docker-compose.dev.yml` and
  `docker-compose.gpu.yml` no longer `depends_on` Vault, MinIO and Redis,
  which geode never uses; the dev stack no longer runs them (nor needs
  `VAULT_TOKEN`, `S3_ACCESS_KEY`, `S3_SECRET_KEY` or `REDIS_PASSWORD`). The
  full `docker-compose.yml` stack keeps them for its other services.
  Regression: `zig build test-sonny6430-deploy-docs-truth`.
- **BREAKING (procedure): `CALL tde.measure_overhead()` is refused as
  unsupported (SQLSTATE 0A000) (SONNY-6442 item 6).** It timed 1000
  alloc+memcpy+free of 1 KiB as the "baseline" against 1000 AEAD
  encryptions of the same buffer and answered
  `passes_threshold` = overhead < 5 %. Neither loop touches storage, so the
  percentage measured nothing about TDE overhead (and an AEAD call is always
  far slower than a memcpy). The measurement is
  `zig build test-sonny6435-tde-overhead` (the storage engine with page and
  WAL encryption off vs on). The procedure is no longer classified
  read-only. Regression: `zig build test-sonny6442-tde-measure-overhead`.
- **Operator-visible: the Docker images run the server at the log level
  they document (SONNY-6442 item 5).** `Dockerfile`, `Dockerfile.prebuilt`,
  `Dockerfile.simple` and `Dockerfile.reliable` set `ENV LOG_LEVEL=error`
  (as did `Dockerfile.base` and the dev images) and
  `docs/DOCKER_LOG_LEVEL_CONFIG.md` gave it as the server's log level, but
  geode reads no `LOG_LEVEL` (only the vendored QUIC logger does, and its
  default is already `error`): the server ran at `info`. The variable is
  gone and those images pass `--log-level error` in `CMD`, so their server
  now logs at `error` by default; give `--log-level` with the other
  arguments to change it (they replace `CMD`).
  `docker-integration/Dockerfile.server` and its compose file dropped the
  unread `GEODE_LOG_LEVEL` and `GEODE_LISTEN` (the compose file passes
  `--log-level ${GEODE_LOG_LEVEL:-info}`). `docs/DOCKER_LOG_LEVEL_CONFIG.md`
  and the log-level parts of `docs/docker/DOCKER.md` are rewritten.
  `zig build test-sonny6430-deploy-docs-truth` now checks every Dockerfile.
- **BREAKING (operator): `geode serve` refuses an unknown option (SONNY-6442
  item 4).** It skipped any argument it did not know, so a misspelt option
  (`--data-dri /srv/geode`) or a removed one started a server on the
  defaults. An unknown option or a stray argument now exits 2 with
  `Error: geode serve: unknown option '<arg>'`, and a known option without
  its value exits 2 with `option '<arg>' requires a value`, as
  `geode backup create` and `geode restore` do. Every option
  `geode serve --help` lists still parses (`--lsp-port=<n>` and
  `--lsp-bind-all` included), and so do the compatibility no-ops
  `--enable-auth`, `--enable-fle`, `--enable-tde` and `--tde-provider`.
  In-repo uses of options `geode serve` never had are gone:
  `--gpu-acceleration` (`Dockerfile.release.gpu` and its release manifest
  entry), `--dist-enable-raft` (`tests/e2e_dist_ping_leader.zig`),
  `--insecure` (five `tests/*index*_test.sh` scripts), `--no-cluster`
  (`tests/integration/test_mermaid_external.sh`), and `--log_json`,
  `--log-json`, `--result-format`, `--tls-cert`, `--tls-key`,
  `--kms-provider` and `--match-max-*` in the docs. Regression:
  `zig build test-sonny6442-serve-unknown-options` (parser and the built
  binary).
- **BREAKING (remote KMS client): the remote KMS client verifies the
  server, binds attestations to the TLS channel and has no local fallback
  (SONNY-6442 items 1-3).** `RemoteKmsClient.connect` dialed with
  `connectInsecure` (no certificate verification), so a man in the middle
  could relay the `Attest` exchange to the real server; unconnected,
  `generate` / `unwrap` / `privUnwrap` ran locally under a KEK derived from
  the public seed `0x12345678`; and the attested hash was
  SHA-256(token || kek[0..16]). The client now verifies the server's
  certificate chain against a CA bundle (`Options.ca_cert_path`, through the
  new `QuicClient.connectWithCa`, which fails if the bundle cannot be
  loaded) and its name against the dialed host, and refuses to connect
  without one (`KmsTrustAnchorMissing`); there is no unverified mode. The
  server signs `GEODE-KMS-ATTEST-V3 || nonce || hash || channel_binding`,
  where the binding is the RFC 8446 §7.5 exporter value
  (`EXPORTER-geode-kms-attest-v3`) of the connection the request arrived on
  (`QuicConnection` / `QuicClient.exportKeyingMaterial`), so a reply
  obtained on another channel is rejected; `verifyAttestResponse` and
  `verifyAttestation` take the caller's own binding. Generate / unwrap
  replies are protected by the verified TLS channel. Unconnected, every
  operation returns `NotConnected`. The attested hash is the KEK identifier
  HKDF-SHA256(ikm = KEK, salt = `GEODE-KMS-KEK-ID-V1`) (`kekIdentifier`),
  independent of the auth token. The seeded `external_kms_client.Client`
  (LocalSimulated) and the factory's `LocalSimulated` branch compile into
  test builds only; the `GEODE_ALLOW_LOCAL_KMS` override is gone.
  Regression: `zig build test-sonny6442-kms-channel` (real server over QUIC).
- **BREAKING (remote KMS protocol): the remote KMS client accepts only a
  fresh attestation signed by a pinned key (SONNY-6435 item 1).**
  `RemoteKmsClient.attest` returned whatever hash the server sent. It
  checked no signature, and a check would have proved nothing: the server
  signed with a key it handed out in the same reply, the client pinned no
  key (it dials with an unverified TLS certificate), and the signed message
  had no nonce, so a recorded reply replayed. An unconnected client made up
  a constant hash. The server now signs `GEODE-KMS-ATTEST-V2 || nonce ||
  hash` over the client's fresh 32-byte nonce and refuses an `Attest`
  without one (`AttestNonceRequired`); an operator provisions its key with
  `Server.setAttestationKeySeed` and gives clients the public key
  (`attestationPublicKey`) to pin (`pinAttestationKey` or
  `Options.attestation_public_key`). `attest` fails closed with no pinned
  key (`AttestationTrustAnchorMissing`), with no connection, for another
  key (`AttestationKeyMismatch`), another nonce
  (`AttestationNonceMismatch`) or a bad signature
  (`AttestationSignatureInvalid`), always verifying under the pinned key
  and its own nonce. The attestation is not bound to the TLS channel, so it
  authenticates the server's key, not the connection carrying later
  unwraps. Regression: `zig build test-sonny6435-kms-attestation` (real
  server over QUIC: no pin, unconnected, wrong-key server, tampered and
  replayed replies, nonce-less request).
- **BREAKING (operator): a `GEODE_MASTER_KEY` other than the one a data
  directory's encrypted fields were written with refuses startup
  (SONNY-6435 item 3).** Nothing recorded the key, so a server restarted
  with another key (or the same characters in another
  `GEODE_MASTER_KEY_FORMAT`) started, could not read the old fields and
  wrote new ones under the new key. The first start with a key now records
  its check value (HMAC-SHA256 of a fixed label under an HKDF-derived key,
  never the key) in `fle_master_key.kcv` beside the FLE catalog; a later
  start with another key refuses to start, naming the file and not the key,
  and an unreadable or malformed check file refuses too. A directory with no
  recorded value records one (upgrade path). Without `GEODE_MASTER_KEY`
  nothing is read or written. `docs/FIELD_LEVEL_ENCRYPTION.md` ("Master key
  check value"). Regression: `zig build test-sonny6435-master-key-check`
  (the built server across restarts: same key, another key, another format,
  upgrade, no key).
- **BREAKING (policy outcomes, `-Dallow-rls-raw-interp=true` builds only):
  the raw-string RLS interpreter splits a policy only outside quotes and
  parentheses, and denies a policy that does not parse (SONNY-6447 item
  4).** `rls_core.ContextEvaluator` split at the first ` OR ` / ` AND `,
  comparison operator and `(`, and at every `,` of a call's arguments,
  wherever they were. `name = 'q OR true OR q'` therefore admitted every
  row (its tail `true OR q'` held), a policy whose quotes or parentheses
  do not balance was evaluated up to the first OR that held (`active OR (`,
  `active OR 'unterminated` admitted), a parenthesised group inside AND /
  OR (`(off OR active) AND active`) failed to parse, and
  `has_role('a,b')` passed two arguments. Operators, comparisons, call
  parentheses and argument commas now count only outside quoted strings
  and at parenthesis depth 0, a call argument loses one pair of enclosing
  quotes, and an unbalanced policy is refused with `InvalidExpression`,
  which every caller turns into a deny. Default builds are unaffected (they
  refuse a raw-only policy, GAP-0732). Regression:
  `zig build test-sonny6447-rls-raw-tokenize`.
- **BREAKING (policy outcomes, `-Dallow-rls-raw-interp=true` builds only):
  a raw-string RLS policy admits a row only when its predicate is True
  (SONNY-6436 item 5).** The raw-string interpreter
  (`rls_core.ContextEvaluator`, used for a policy without compiled code
  only in a build with `-Dallow-rls-raw-interp=true`; default builds
  refuse such a policy, GAP-0732) now follows ISO/IEC 39075:2024 19.1 GR 2,
  as the compiled VM already did (SONNY-2709, SONNY-2732). These
  expressions change verdict:
  - a bare value that is not a boolean, which admitted every row: a column
    holding a non-zero integer, a non-empty string, a float or a timestamp
    (`cnt`, `flag`), an integer or string literal (`1`, `'anything'`), and
    a call that returns no boolean (`current_user()`,
    `current_timestamp()`), also inside AND / OR (`cnt AND active`) - now
    deny;
  - `a = b` and `a <> b` with a null or missing side (`missing = NULL`,
    `missing <> 'secret'`, `name <> NULL`; `NULL = NULL` admitted) or
    with values that do not compare (`owner_id <> 'x'`, `name <> 1`,
    `active <> 1`) or a NaN (`nan <> nan`) - `<>` admitted, now both
    deny (UNKNOWN); write `row IS NULL OR ...` explicitly in a compiled
    policy for the old meaning;
  - a call followed by a comparison (`func() = x`) was evaluated as the
    call alone: `current_user() = 999` admitted every row, and
    `has_role('auditor') = false` denied a user without that role; it is
    now the comparison (the latter admits that user);
  - an empty sub-expression (`()`, `active AND ()`) admitted - now denies.
  Unchanged: boolean columns and literals, comparisons of two values of
  one kind, `column = current_user()`, `has_role()` / `has_permission()`,
  AND / OR, and an empty policy (admits). The compiled VM's verdicts are
  unchanged and pinned against the same cases. Regression:
  `zig build test-sonny6436-rls-raw-truthiness`.
- **The security graph never opens unaudited, and an unreadable graph
  registry refuses startup (SONNY-6430 items 5 and 7).**
  `StorageAdapter.initAuditForGraph` returned null for any failure other
  than an unusable audit key pair, so an audit log that could not be opened
  (EACCES, a read-only graph directory, a tail that does not verify) let
  `__geode_security` open with no audit logger and every auth change went
  unaudited; every failure is now an error and the graph does not open
  (`geode serve` refuses to start). `StorageAdapter.init` only warned when
  `graph_registry.dat` existed but could not be read or parsed (a flipped
  byte, a truncated file, EACCES) and started with no graphs, so the first
  `CREATE GRAPH` rewrote the registry without them; it now fails, and the
  server exits with `Error: cannot open the data directory ...`. A missing
  registry is still a fresh data directory. Regression:
  `zig build test-sonny6430-storage-open-fail-closed`. SONNY-6435 item 4:
  `initAuditForGraph` is now typed `!*AuditLogger` (it never returned
  null), so no caller can read a null as "no audit logger"; regression
  `zig build test-sonny6435-audit-init-type`.
- **`GEODE_MASTER_KEY_FORMAT` reads a full 256-bit FLE master key, and an
  existing key never changes (SONNY-6430 item 2).** `GEODE_MASTER_KEY` was
  always used as raw bytes and only its first 32 counted, so the usual
  `openssl rand -hex 32` value gave a key of its first 32 hex characters
  (128 bits) and the rest was silently ignored. `GEODE_MASTER_KEY_FORMAT`
  now selects `hex` (exactly 64 hex characters), `base64` (32 bytes) or
  `raw` (exactly 32 bytes); a value that does not match, an unknown format
  or a format without a key refuses startup without printing the value.
  The format is never inferred from the value: with it unset the legacy
  reading is unchanged (reading an existing 64-hex value as hex would be a
  different key and make every encrypted field unreadable), and a value
  longer than 32 bytes starts with a warning that only its first 32 bytes
  are the key. `docs/FIELD_LEVEL_ENCRYPTION.md` ("Master key format") and
  `docs/DOCKER_OVERVIEW.md` document it. Regression:
  `zig build test-sonny6430-master-key-format` (includes a real FLE round
  trip: a field encrypted under a legacy 64-hex key stays readable).
- **BREAKING (operator): half-configured audit keys, a short
  `GEODE_MASTER_KEY`, a `GEODE_WAL_KEY` and a malformed
  `GEODE_MIGRATION_HMAC_KEY` are refused instead of falling back to a weaker
  mode (SONNY-6422 items 1-2).** With only one of `GEODE_AUDIT_PUB` /
  `GEODE_AUDIT_SEC` set the audit logger generated file-based keys, and the
  `__geode_security` graph opened with no audit logger at all; a
  `GEODE_AUDIT_PUB` that was not the seed's public key was never checked.
  `GEODE_MASTER_KEY` accepted any length and hashed a short value into the
  FLE master key. `GEODE_WAL_KEY` is read by nothing in the server (the
  storage-engine WAL is encrypted with `GEODE_TDE_KEY`), so a server given
  only `GEODE_WAL_KEY` wrote its WAL in plaintext. A
  `GEODE_MIGRATION_HMAC_KEY` that was not 64 hex characters made
  `geode migrate create` write an unsigned migration, or sign with
  `.hmac_key` instead. Now `geode serve` refuses to start before it creates
  the data directory, naming the variable and the required form and never
  printing the value: set both audit variables or neither (the public key
  must be the seed's: `AuditKeyPairIncomplete` / `AuditKeyInvalid` /
  `AuditKeyMismatch`), give `GEODE_MASTER_KEY` at least 32 bytes
  (`MasterKeyTooShort`; an empty value is unset), and unset `GEODE_WAL_KEY`.
  The `__geode_security` graph does not open on a bad audit pair, and the
  `geode migrate` commands exit 1 on an unusable key env var or `.hmac_key`
  file. `docs/AUDIT_LOGGING.md`, `docs/FIELD_LEVEL_ENCRYPTION.md`,
  `docs/TDE_FILE_LEVEL_ENCRYPTION.md` and `docs/DOCKER_OVERVIEW.md` document
  it. Regression: `zig build test-sonny6422-env-key-fail-closed`.
- **BREAKING (operator): a set but malformed `GEODE_TDE_KEY` refuses
  startup instead of writing plaintext pages (SONNY-6386 item 1).**
  `initGlobalAdapter` loaded the page key with `catch null`, so a value that
  is not 64 hex characters opened the store with no encryption key and every
  page (users, roles, data) was written in plaintext while TDE looked
  configured. `geode serve` now checks the key before it creates or opens
  the data directory and exits with `[startup] GEODE_TDE_KEY is set but
  unusable (InvalidKey) ... Refusing to start ... Nothing was written`,
  never printing the value; the adapter itself returns `InvalidKey`. The
  same swallow is fixed in two other loaders: a non-empty `GEODE_WAL_KEY`
  that is not 64 hex characters is `InvalidKey` (it fell back to
  `GEODE_TDE_KEY` or plaintext), and the auth-chain HMAC key resolver
  refuses a `GEODE_TDE_KEY` of the wrong length (`HmacKeyInvalid`) instead
  of sealing with `.geode_hmac_key`. An unset or empty `GEODE_TDE_KEY`
  behaves as before. `docs/TDE_FILE_LEVEL_ENCRYPTION.md` documents it.
  Regression: `zig build test-sonny6386-tde-key-fail-closed`.
- **BREAKING (operator): `geode fle rotate-key` refuses as unsupported
  instead of reporting a rotation it did not perform (SONNY-6386 item 2).**
  The CLI built a throwaway in-memory key manager from `GEODE_MASTER_KEY`,
  bumped a version in it, printed `Rotated FEK ... to version 2` (or
  `Rewrapped SK/TRK`) and exited 0; nothing was persisted and no field value
  was re-encrypted. `fle_commands.rotateKey` printed `TRK/SK/FEK rotation
  complete. New key version active.` without touching a key. Both now exit
  non-zero (`error.Unsupported`) with `FLE key rotation is not supported in
  this release (SONNY-6387)`, after the usual argument checks; `geode fle
  --help` says so, and `geode fle show-rotation` no longer reports the TRK
  as "Active" or a "Last rotation check: Now" that nothing measured. Real
  rotation is story SONNY-6387. `docs/GAP_ANALYSIS_RESOLVED.md` (GAP-0083,
  GAP-0004) is corrected. Regression:
  `zig build test-sonny6386-fle-rotate-key-unsupported`.
- **`geode backup create --server` writes `--output` atomically and durably
  (SONNY-6386 item 3).** It opened `--output` with a truncating create,
  streamed the server's backup into it in place, never synced it, and
  deleted it when the transfer failed: a previous backup at that path was
  destroyed as soon as a transfer started (and lost for good if it then
  failed), and a crash after "Backup completed" could leave a short file
  under the backup's name. The backup is now received into a private
  temporary file beside `--output` (`.<name>.tmp-<random>`, 0600, created
  exclusively), synced, renamed onto `--output`, and the directory is
  synced; a failure removes only the temporary file. `--local` already wrote
  this way (SONNY-6323). `geode backup create --help` says so. Regression:
  `zig build test-sonny6386-remote-backup-atomic-output`.
- **The phantom-prevention overhead claims state the measured cost, not 5%
  (SONNY-6386 item 9).** `test-canary-txn-phantom-anomaly` and
  `test-canary-txn-phantom-range` claimed at most 5% per transaction; with
  the SONNY-2439 methodology the transaction manager measures 27-36% and
  84-96% in ReleaseFast (61-63% and 54-61% in Debug; ten and three runs), so the enforced perf-gate job
  failed on them with no product change. Profiling the arms shows the cost is
  the tracking itself (a hash-map entry and a list allocation per tracking
  structure, a heap copy of every prefix and range bound, the commit-time
  scan of the transaction's writes; about 100-125 ns) against synthetic
  transactions of 120-350 ns that do no storage work, not an accidental scan
  or lock, and no server path runs it. The bounds are recalibrated per build
  mode to about 1.3-1.4x the highest median measured (anomaly 50% ReleaseFast
  / 90% Debug, range 125% / 80%), and
  `docs/ENHANCED_TRANSACTION_ISOLATION.md` gains a "Phantom prevention
  overhead" section with the measurements. Regression:
  `zig build test-sonny6386-phantom-overhead-claims`.
- **The JSON and scheduler latency bounds are batched perf_gate medians
  (SONNY-6386 item 6, the part SONNY-2439 left open).** The four claims in
  `src/performance/test_json_optimization.zig` (parse, serialize, 1000-row
  streaming, the REQ-PERF-JSON-001 query-result serialization) and
  `tests/test_performance_optimizations.zig` ("scheduler overhead") were one
  timed run on `std.testing.allocator`, read with their own clock helpers.
  They now take 31 batched samples through `tests/perf_gate.zig` from
  `perf_gate.bench_allocator`, claim on the median and check the robust
  envelope; correctness checks moved to their own test blocks. The unused
  `json_optimized_fixed.benchmarkJsonProcessing` is removed. Measured on a
  shared dev host, ReleaseFast with `GEODE_PERF_GATES=enforce`, three runs
  each, all passing: parse 1.25-1.31 µs, serialize 2.13-2.23 µs, CANARY
  serialization 77-80 µs (bounds 100 / 150 / 300 µs), scheduler 736-754 ns
  per call (bound 10 µs). Regression:
  `zig build test-sonny6386-latency-bound-methodology`.
- **`geode restore --hmac-key-file` with `GEODE_TDE_KEY` set: the refusal
  is documented and explained (SONNY-6386 item 7).** A server with
  `GEODE_TDE_KEY` set derives its auth-chain HMAC key from it
  (`GEODE_AUTH_HMAC_KEY` takes precedence) and never reads
  `.geode_hmac_key`, so restore refuses `--hmac-key-file` alongside either
  variable (`HmacKeySourceConflict`), and an encrypted backup, which needs
  `GEODE_TDE_KEY` to decrypt, is always restored with the source server's
  `GEODE_TDE_KEY` and no key file. The refusal used to read "both are set; a
  server uses the environment key, so give one"; it now says why, what to
  do, and that nothing was restored. `geode restore --help`,
  `docs/GQL_AUTH_DDL.md` ("HMAC key"), `docs/API_REFERENCE.md`,
  `docs/USAGE.md` and `docs/deployment/DEPLOYMENT.md` say so. Regression:
  `zig build test-sonny6386-restore-hmac-key-file-with-tde`.
- **BREAKING (library API): `security.key_rotation.KeyRegistry` loses the
  uncompiled `saveState` / `loadState` and the simulated-KMS
  `rotateWithKms` / `setKmsSeed` (SONNY-6386 item 5).** The registry has no
  production caller (it is exported from `lib.zig` and used by tests and
  `bench-tde-key-rotate`). The persistence functions predated the Zig 0.16
  std.Io migration and never compiled; `loadState` could unwrap a persisted
  envelope only with the local simulated KMS (a key derived from a seed),
  and `rotateWithKms` wrapped with that simulator. Their only tests
  (`tests/test_key_rotation_persistence.zig`, `_checksum.zig`,
  `_kms_envelopes.zig`) were in no build step and are removed. The markers
  that cited them are corrected: REQ-GQL-SEC-KEYROT-STATE-001 is removed;
  REQ-GQL-KMS-BACKEND-001, -CONFIG-001, REQ-KMS-TLS-SAFETY-001 and
  REQ-HEX-PARSE-001 are TESTED against new tests of the KMS production
  guards and envelope hex parsing, REQ-GQL-KMS-LOCALSIM-001 against
  `test-external-kms-provider`, and REQ-GQL-TDE-VAULT-001 / -AWS-001 (the
  Vault and AWS network clients, which no test reaches) are IMPL.
  `docs/DESIGN_TDE_KMS.md` no longer lists rotation persistence as
  implemented. Regression: `zig build test-sonny6386-key-rotation-truth`.
- **Dead mock test removed and stale architecture docs corrected
  (SONNY-6386 items 4 and 8).** `tests/test_backup_integration.zig`
  redefined `BackupConfig`, `BackupType`, `BackupMetadata` and a backup
  manager inside the test and tested those copies; no build step compiled
  it, and its CANARY (REQ-GQL-201, TESTED) claimed evidence for code it never
  touched. It is removed (`git rm`), with its status rows.
  `docs/CURRENT_ARCHITECTURE.md` described the backup path as "S3 Upload →
  Encryption → Compression" (no command uploads to object storage, and the
  payload is compressed before it is encrypted) and the language as Zig
  0.15.1+; it now describes the real path, files and tests and Zig 0.16.0+.
  The SONNY-2441 entry below no longer claims a `test-tde-kms-integration`
  run. Regression: `zig build test-sonny6386-dead-mock-and-stale-docs`.
- **BREAKING (operator): backups are encrypted under `GEODE_TDE_KEY` when it
  is set (SONNY-6355 items 1, 2, 5, 6).** `BackupManager` has encrypted the
  payload with AES-256-GCM under `GEODE_TDE_KEY` (and every restore path
  decrypts with it) since GAP-005, but the CLI local backup and the QUIC and
  gRPC server backups all passed `.encryption = false`, so a server whose
  pages are encrypted under the key wrote plaintext backups. With
  `GEODE_TDE_KEY` set a backup is now encrypted, and restoring it needs the
  key; a value that is not 64 hex characters fails the backup instead of
  writing plaintext. Without the key nothing changes. The server's
  `createFullBackup` file and `metadata.json` are now fsynced, the unread
  `BackupConfig.retention_days` is removed, and `geode backup create`
  refuses a missing `--output` directory on both paths before doing any
  work (`--local` used to create it; a server backup was taken and then
  failed to land). `docs/deployment/DEPLOYMENT.md`, `docs/SERVER_FEATURES.md`
  (which said AES-256-CTR with envelope encryption) and
  `docs/MIGRATION_GUIDE.md` say what is done. Regression:
  `zig build test-sonny6355-backup-encryption-fsync-output`.
- **BREAKING (operator): a symbolic `GEODE_KMS_URL` (`aws`, `azure`, `gcp`,
  `hashicorp`, `local`) refuses startup (SONNY-6348 items 1, 4-6).**
  `configureKMS` reported such a name configured after a local AES-GCM
  round trip with a random key, and startup logged "KMS configured" without
  contacting any KMS; no client for those providers is built in. An endpoint
  value is still probed with a TCP connect only, and the log now says "KMS
  endpoint reachable" (the configureKMS result strings are also freed).
  `tde.simulate_oltp_workload` ignored `concurrent_transactions`; it now
  runs that many worker threads (1-64, else `InvalidArgs`) and reports
  `concurrent_transactions` and `transactions` columns.
  `tde.encrypt_page_test` / `tde.encrypt_backup_test` gave every run id 1;
  each run now gets its own sequence number. Seven procedures the server
  refuses (`audit.get_recent_events`, `audit.verify_hash_chain`,
  `audit.comprehensive_integrity_check`, `tde.get_encryption_status`,
  `tde.verify_encrypted_state`, `tde.get_rotation_state`,
  `tde.audit_plaintext_keys`) are no longer classified read-only.
  `geode.fle.configureField` refuses `searchable` other than `false`
  (`SearchableFieldsUnsupported`) instead of dropping it, and the uncalled
  `fle_integration.lookupEncryptedField` / `matchesEncryptedField` and the
  unused audit imports are removed. The timeseries persistence and REPL
  path-completion inline tests use private temp dirs instead of fixed /tmp
  paths and now run (`test-sonny6348-inline-tmp`); the other files the
  ticket named were already removed (SONNY-6298). `docs/FEATURES_OVERVIEW.md`
  claimed searchable encryption and predicate rewriting; neither exists.
  Regression: `zig build test-sonny6348-kms-tmp-selftests-stale`.
- **A stored Argon2id hash outside the parameter bounds fails verification;
  startup log lines are written; the server frees its RBAC policy and
  proto-reader registry at exit (SONNY-6378).** `verifyPasswordArgon2id`
  ran any stored `t` and `m` up to 2^32-1, so a corrupt stored hash could
  burn CPU (t) or memory (m, up to 4 TiB) on every login; a hash outside
  1 <= t <= 10, 8*p <= m <= 262144 KiB and 1 <= p <= 16 now fails without
  running Argon2 (the hashes Geode writes, m=19456,t=2,p=1, and RFC 9106's
  m=64 MiB,t=3,p=4 are inside). The structured logger wrote stderr through
  a 4 KiB buffer nothing flushed, so startup `log.info` lines did not
  appear; every record is now one unbuffered write. A debug server
  reported the `GraphRBACPolicy` from `wireAuthDDLCallbacks` and the
  proto-reader registry capacity as leaked at exit; both are freed at
  shutdown. `KeyRegistry.rotateWithRemoteKms` (and `setRemoteKms`) never
  compiled under Zig 0.16, installed an all-zero active key and could not
  be reloaded by `loadState`; nothing called it and it is removed with its
  never-built test. `tests/e2e_security_tde_mfa.zig` was compiled but never
  run while REQ-GQL-TDE-001 cited it; it now also covers the enabled TDE
  round trip and RFC 6238 TOTP and runs as `test-e2e-security-tde-mfa`.
  The 172 CANARY markers of the GAP-0193 batch 2 engine, misc, security and
  testing suites, whose cases only parse a query, are IMPL instead of
  TESTED (GAP-0514: 412 IMPL, 7.0%). Dockerfile, Dockerfile.dev,
  Dockerfile.simple, Dockerfile.reliable, Dockerfile.gpu, the three compose
  files and `scripts/install-deps.sh` pinned Zig 0.15.x; they pin 0.16.0
  (Dockerfile and Dockerfile.gpu expect `docker/zig/zig-<arch>-linux-0.16.0.tar.xz`).
  `docs/USER_AUTH.md` said passwords were hashed with BLAKE2b; it now
  describes Argon2id and the bounds. Regression:
  `zig build test-sonny6378-server-exit-and-hygiene`.
- **BREAKING (library API): `KMSProvider` has no `remote_kms` provider
  (SONNY-2441).** `wrapDataKey` with `remote_kms` ignored the key it was
  given and returned one the remote KMS generated (the remote protocol has
  GENERATE and UNWRAP, no WRAP), so unwrapping never returned the caller's
  key; nothing called it, and the CANARYs claiming it TESTED cited test
  files no build step compiled. The provider, `remoteKMSProvider`,
  `createRemoteKMSTDE` and the `KMSConfig` port/remote-timeout fields are
  removed; the remote KMS client (`kms_remote.zig`, `test-remote-kms`)
  stays. `tests/test_kms_provider.zig` is built and run (`test-kms-provider`
  10/10). (Correction, SONNY-6386: this entry also said
  `tests/test_tde_kms_integration.zig` was built and run as a
  `test-tde-kms-integration` step, 8/8, and that building it fixed two
  compile errors and three leaks in `TDEKeyManager`. No such step, test or
  `src/security/tde_kms_integration.zig` exists in this tree: both files
  were removed as never compiled, SONNY-6298.) `docs/KMS_PROVIDER_SYSTEM.md` now says what `KMSProvider`
  does: local_dev and external_kms only (Vault/AWS/Azure configurations are
  refused), and neither it nor `TDEKeyManager` is used by the server.
  Regression: `zig build test-sonny2441-kms-provider-paths`.
- **A corrupt stored Argon2id hash is refused, not a panic; GEODE_ENABLE_ABAC
  no longer claims enforcement; `serve --help` (SONNY-6374 items 3-8).**
  `verifyPasswordArgon2id` narrowed the stored hash's `p` into Argon2's u24
  with `@intCast`, so a hash with `p` above 2^24-1 panicked a safe build; an
  unparseable `m`, `t` or `p` fell back to the default. Such a hash now fails
  verification. The startup log no longer says "ABAC enforcement enabled":
  no request path enforces ABAC (SONNY-6376), and the line now says so;
  `docs/DOCKER_OVERVIEW.md` described `GEODE_ENABLE_ABAC` as enabling ABAC.
  `geode serve --help` gave `--listen-grpc 0.0.0.0:3142`, the embedded LSP
  default port, as its gRPC example; it now gives 50051 and documents
  `--lsp-port` and `--lsp-bind-all`. Also: the GAP-0193 batch 2 security
  and testing suites lose their `... or true` assertions and are built
  (`test-gap0193-batch2-security`, `test-gap0193-batch2-testing`);
  canaryscan sorts rows of one requirement in a total order, so
  `tools/canaryscan/status.csv` no longer reorders between runs (both
  outputs regenerated); 51 CANARY `TEST=` tokens that named missing files
  are re-pointed to the tests that exercise them or, where none does,
  downgraded to IMPL (`REQ-AUTH-SESSION-ROTATE-001`, `REQ-AUTH-MTLS-002..004`,
  `REQ-HEX-PARSE-KEYPROV-001`, `REQ-HEX-PARSE-KEYROT-001/002`,
  `REQ-STREAMING-KEYROT-REENCRYPT-001`, `REQ-GQL-SEC-KEYROT-001`,
  `REQ-GQL-VAULT-KMS-001`, `REQ-GQL-2PC-001`); and the unimported
  `src/performance/async_io_simple.zig` and
  `src/distributed/federation_latency_aggregate.zig` (with its unbuilt tests
  and benchmark) are deleted. Regression:
  `zig build test-sonny6374-server-residuals`, `go test` in
  `tools/canaryscan`.
- **The embedded LSP listener no longer frees its AuthProvider while
  sessions use it (SONNY-6374 item 1).** `geode serve` freed the listener's
  `AuthProvider` in a `defer` inside the block that spawned the listener
  thread, so it was freed as soon as the thread started, and every LSP
  session's `initialize` verified its token against freed memory. A debug
  server panicked on the first such session, taking the whole server down.
  The listener, its sessions and the provider are now owned together: on
  shutdown the listener stops accepting, closes open sessions and waits up
  to 5 s for them, and only then is the provider freed (it is leaked, with a
  `[shutdown]` line, if a session outlives the wait). SIGTERM now prints
  `[shutdown] LSP listener stopped`. Regression:
  `zig build test-sonny6374-lsp-auth-provider-lifetime`.
- **BREAKING: a corrupt tenant registry line refuses startup (SONNY-6348
  item 2).** `TenantRegistry.hydrate` skipped a `registry.jsonl` line it
  could not parse, or that was not an object with a valid string
  `tenant_id`, with a warning, so that tenant (and its place in the
  hierarchy) was silently gone. A line that cannot become a tenant (bad
  JSON, not an object, no or a non-string or invalid `tenant_id`, a
  non-string `parent`, a repeated id) now fails hydrate with
  `TenantRegistryCorrupt`, naming the line number, and the server refuses to
  start (as for an unreadable registry since SONNY-6346). Regression:
  `zig build test-sonny6348-readonly-restore-checks-registry`.
- **A restore commits exactly the backup (SONNY-6348 item 3).** The server
  restore's graph count and its child `geode auth verify`, and `geode
  restore`'s count and chain check, opened the staged copy that was then
  committed. Opening a store writes to it (WAL replay checkpoints,
  manifests, store files) and opening `__geode_security` started a new
  audit key epoch (a new `audit.jsonl.key`, `audit.jsonl.pub.1` and a
  KEY_EPOCH record), so the restored directory was no longer the backup and
  its epoch was started by the check. The checks now run on a throwaway copy
  (`<target>.probe-<random>`, deleted afterwards); the committed directory
  holds the backup's files byte for byte plus the HMAC key file the restore
  adds, and the epoch starts when a server first serves it. A restore needs
  the backup's size again in free disk while it runs. Residual: `geode auth
  verify` itself still opens the store read-write (the storage engine has
  no read-only open). Regression:
  `zig build test-sonny6348-readonly-restore-checks-registry`.

- **BREAKING: no silent degrade in the tenant registry and the audit log
  writer (SONNY-6346).** A server whose `<data dir>/tenants` could not be
  created (or whose `registry.jsonl` could not be read) ran with an
  in-memory tenant registry and a warning, and every tenant was gone at the
  next restart; it now refuses to start and names the registry. An audit
  record with more than 32 detail keys was written without the extra keys
  (a fixed 32-entry buffer in rls_core); every key is written, in the same
  sorted order. `cleanupOldLogs` (`CALL audit.cleanup_log_files()`)
  scanned the working directory for `audit.jsonl.<ts>`, so the log's own
  rotated files were never removed and files in the working directory could
  be deleted; it deletes `<log file name>.<ms>` beside the log, older than
  its retention. Regression:
  `zig build test-sonny6346-silent-degrade-audit-housekeeping`.
- **BREAKING: the `tde.*` key-management stubs are refused (SONNY-6342).**
  36 `tde.*` procedures answered with constants: `tde.rotate_keys` reported
  success and a new master key id `mk-00000002` with nothing rotated,
  `initialize_key_hierarchy` answered `mk-00000001`,
  `get_encryption_status` answered `enabled=true` with TDE off,
  `configure_kms` / `configure_external_kms` reported a configured,
  connection-verified KMS nothing contacted, `zeroize_keys`,
  `cleanup_key_hierarchy` and `test_key_zeroization` reported zeroized keys
  that were never the server's, `audit_plaintext_keys` reported constant
  counts, and the rotation-schedule, access-control, KMS-failure and
  corrupted-key procedures returned hard-coded verdicts
  (`configure_mock_kms` also wrote `mock_kms_config.json` into the working
  directory). They fail with SQLSTATE `0A000` now (real key management is
  SONNY-6303). The procedures that run real cryptography on the server's
  TDE key still answer (`encrypt_page`, `test_encryption`,
  `test_decryption`, `test_key_escrow`, `test_transparent_encryption`,
  `encrypt_page_test`, `encrypt_backup_test`, `roundtrip_test`,
  `measure_overhead`, `simulate_oltp_workload`, `test_kms_wrap_unwrap`,
  `test_kms_attestation`); `test_transparent_encryption` measures its
  performance impact against a real unencrypted copy (it used an invented
  1000 µs). The dead `fle_integration.computeBlindIndex` (it did not
  compile) and its only caller, the unreferenced FLE predicate rewrite in
  `planner/rewrite.zig`, are removed; docs/FIELD_LEVEL_ENCRYPTION.md now
  says that searchable fields cannot be configured through
  `CALL geode.fle.configureField` and that equality search on encrypted
  fields is not available. The AuthProvider API-key unit test freed its
  result (3 leaked allocations) and runs as
  `zig build test-sonny6342-authn-inline`. Regression:
  `zig build test-sonny6342-tde-stub-procedures`.
- **BREAKING: audit and TDE procedures that reported work they did not do
  are refused (SONNY-6340).** 30 `audit.*` procedures answered with made-up
  rows: `audit.compliance_verification` said `compliant` with no check,
  `export_for_verification`, `prepare_forensic_package` and
  `generate_compliance_report` named `/tmp` files never written,
  `log_lifecycle_event` said `logged=true` without logging, the anomaly,
  threat-indicator, SIEM and privilege-escalation procedures counted
  hard-coded patterns, `performance_test` and `memory_usage_test` wrote
  synthetic events into the server's real audit log and reported constant
  memory figures, and `configure`, `configure_rotation` and
  `configure_retention` set up a logger of their own in the working
  directory (on the query's allocator, kept after the query ended). The
  `tde.*` backup family (`create_encrypted_backup`, `restore_with_keys`,
  `backup_encrypted`, `encrypt_backup`, `verify_backup_encryption`,
  `generate_key_manifest`, `restore_with_historical_keys`) reported backups,
  manifests and 1000 restored records that were never written or read. All
  of them now fail with SQLSTATE `0A000` (unsupported); the list is in
  docs/AUDIT_LOGGING.md. `audit.get_merkle_digests` hashes the server's
  audit log (it hashed the fixed `/etc/geode/geode_audit.jsonl`, and only
  its first MiB) and `audit.cleanup_log_files` cleans the server's log, both
  refused when the server writes no audit log; `tde.test_encryption` and
  `tde.test_decryption` report `success=false` when TDE is off or no key is
  loaded (they reported `true`); `audit.cleanup_test_artifacts` no longer
  reports `logs_archived=true`. The diagnostic audit logger is made with the
  process allocator. The server never rotated its audit log (nothing acts
  on `rotation_size_mb`); the rotation code, reachable only from the
  refused procedures, was removed. Regression:
  `zig build test-sonny6340-no-fabricated-procedures`.
- **BREAKING: the audit `event_hash` covers the whole record; old logs
  verify as format 1 (SONNY-3147).** A record's `event_hash` covered only
  the previous hash, the event type, `resource.id` and the action: the
  timestamp, actor, tenant, session, client address, reason, result,
  resource type and details could be edited in the log without breaking
  the chain, and `geode audit verify` never recomputed `event_hash` for an
  ordinary record at all. Every record now carries `"hash_v":2` (and
  `resource.graph` when set) and its `event_hash` is
  `SHA-256("geode.audit.event_hash.v2" 0x00 || kind || 0x00 || prev_hash ||
  body)`, `body` being the record's exact canonical bytes up to
  `"prev_hash"` and `kind` separating ordinary, DIGEST and KEY_EPOCH
  records. The verifier recomputes every record's hash (format 1 for
  records without `hash_v`, counted and reported in a `NOTICE` as not
  covering those fields), refuses a format-1 record after a format-2 one,
  reads `prev_hash`/`event_hash`/`signature` from the fixed record tail,
  rejects duplicate keys, returns an error instead of exiting the process
  on a broken chain link, and prints one verdict: `OK chain` only when
  everything verified (it was printed before a signature failure), else
  the first failing record and class and `FAILED`, exit 3 for a broken
  chain link and 1 otherwise, no record contents. A clean close and a
  rotation append a DIGEST when records were written since the last one.
  `CALL audit.verify_hash_chain()` is refused as unsupported: it reported
  `valid=true` for any log. Records after the last signed DIGEST, and a
  truncation back to a DIGEST, stay undetectable from the log alone (see
  docs/AUDIT_LOGGING.md). Regression:
  `zig build test-sonny3147-audit-hash-coverage`.
- **BREAKING: a server without `--data-dir` keeps its auth state and data
  (SONNY-6339).** A server resolves and locks its data directory from
  `--data-dir`, else `GEODE_DATA_DIR`, else the per-user default
  (`$XDG_STATE_HOME/geode`, `$HOME/.local/state/geode`,
  `$TMPDIR/geode-<uid>`), but then handed the raw flag (empty without it) to
  the HMAC key lookup, the auth graph, the default audit log path, the tenant
  registry, timeseries and raft storage. With `GEODE_DATA_DIR` only, the
  `.geode_hmac_key` was neither read nor created and the HMAC-chained auth
  graph was disabled without an error: `CREATE USER`, `CREATE ROLE`,
  `GRANT` and `CREATE POLICY` reported success, a per-graph grant did not
  take effect, and all of it was gone after a restart. With neither, the
  storage engine was not opened at all (every graph lived in memory), and
  the audit log went to the working directory. Now one resolver
  (`resolveServerDataDir`) reads the flag once and every consumer gets the
  resolved directory, which is also the store's data-directory override.
  The server refuses to start, instead of running with in-memory
  authentication, when the store does not open, when an HMAC key source is
  set but unusable (a malformed or unreadable `.geode_hmac_key`, a
  `GEODE_AUTH_HMAC_KEY` that is not 64 hex characters: it used to be skipped
  in favour of the file key), or when the auth graph manager or the first-boot
  admin cannot be set up. Operators who ran without `--data-dir` find their
  auth state, timeseries, tenants and audit log in the resolved directory
  from now on (none of it had been kept). Regression:
  `zig build test-sonny6339-resolved-data-dir`.
- **FLE key manager and blind index live for the process; the node-scan
  WHERE no longer leaks on FLE deployments (SONNY-2670).** The two
  process-wide FLE singletons were created on the first caller's allocator
  (a request arena, a per-node scratch arena, the read-budget metered
  allocator); once that was torn down the next encrypt or decrypt used freed
  memory. They are now made on the process allocator, as the FLE catalog
  is, and the engine-direct node scan runs a WHERE on its per-node scratch
  arena on deployments with encrypted fields too (it used the server's main
  allocator there and leaked every extended value a WHERE read, the
  SONNY-2656 leak). Regression: `zig build
  test-sonny2670-fle-singletons-process-allocator`.
- **Work submitted to an idle geode pool starts at once (SONNY-2440;
  thread-pool v0.2.11, SONNY-6479).** thread_pool 0.2.10 woke a parked
  worker only on every 32nd submit (`wake_coalesce_batch`) and counted on
  idle workers seeing queued work before they park; a worker already
  parked slept until its idle park expired, 500 ms in geode. So a
  connection, stream or background task submitted to an idle pool waited
  up to half a second (449 ms measured) while workers sat parked, and with
  every default-lane worker busy a further default-lane task waited the
  same for the parked blocking-lane worker, which a default-lane submit
  never woke. thread-pool v0.2.11 wakes a parked worker whenever work is
  queued and wakes the blocking-lane helper for default-lane work, so
  geode's interim `ThreadPoolConfig.wake_coalesce_batch = 1` override (a
  worker scan and a separate claim on every submit) is removed and the
  pools use the library default. Regressions: `zig build
  test-sonny2440-default-lane-wake` and `zig build
  test-sonny2440-blocking-worker-fallback`.
- **A CPU-starved or overloaded server is slowed, not killed by the acceptor
  wedge watchdog (SONNY-2719).** The watchdog exited the process with code 70
  ("ACCEPTOR WEDGE") once the listener's UDP rx_queue had stayed at or above
  its threshold for the deadline of wall-clock time, so a server that was
  draining its backlog more slowly than datagrams arrived (a 1-CPU runner, a
  throttled container, the CI thresholds of 64 KiB) was restarted and lost
  every connection. A wedge now also requires that no datagram was drained
  from the socket over the whole deadline (`QuicTransport.getDatagramsDrained`,
  counted on every server-side poll), and one 5 s sample interval adds at
  most 10 s to it (a longer gap means the watchdog itself did not run).
  A wedged acceptor, which drains nothing, is still restarted after the
  deadline. Regression: `zig build test-sonny2719-starved-acceptor-survives`
  (a real `geode serve` throttled to 5% of a CPU with a backlogged listener),
  and the tracker cases in `zig build test-acceptor-watchdog`.
- **The schema catalog lives for the process; a batch property write
  encrypts each FLE value once (SONNY-6468).** `ensureCatalogInstance` made
  the process-wide catalog on its first caller's allocator, so a request
  arena could own it and leave it freed (the SONNY-2670 class); it is now
  made on the process allocator. `setNodePropertiesBatch` and
  `setEdgePropertiesBatch` sealed each FLE value twice, once for the storage
  layer and once for the in-memory copy: twice the encryption work, and two
  different envelopes for one write (each seal draws a fresh nonce). Each
  value is now sealed once and both copies hold that envelope. Regression:
  `zig build test-sonny6468-catalog-and-batch-fle`.
- **FLE: a string shaped like an envelope is encrypted; the record's tenant
  is the encryption identity (SONNY-6347).** (2) The graph-store write
  primitives skipped encryption for any string with the shape of an FLE
  envelope (algorithm byte 1-3 and a matching length field), so a crafted
  plaintext of that shape reaching one outside the executor (a raft
  payload, an internal caller) was stored in the clear. A value is now kept
  as stored only when it authenticates as this record's envelope for the
  field; anything else is encrypted. (5) The identity used the writer's
  request tenant, so a parent tenant reading its child tenant's encrypted
  row failed with 58030. It now uses the record's stored tenant; readers
  still try the request tenant, so values written before decrypt as they
  did. (3) `CREATE INDEX` / `CREATE CONSTRAINT ... IS UNIQUE` and `CALL
  geode.fle.configureField` checked each other under different locks with
  nothing held between check and write, so racing they could leave an index
  over an encrypted field; the index DDL now reserves its fields until its
  row is recorded and configureField checks and encrypts under the same
  lock. (4) An index of another type than fulltext made before its field was
  encrypted was neither detected nor avoided: a seek over it returned no
  rows. It is now named in a `SECURITY` error line when the catalog opens,
  and index-served seeks, posting counts and ordered scans over an
  encrypted field fall back to a scan or sort. Regression: `zig build
  test-sonny6347-fle-envelope-identity`.
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

- **A cluster leader's MATCH ... SET updates only the rows the session's
  MATCH sees (SONNY-3246).** On a single node a MATCH ... SET reads through
  the RLS row filters, so a row a policy hides is never updated; the
  leader's replicated MATCH ... SET (`clusterReplicateMatchSet`) matched
  on graph, tenant, labels and properties only, and proposed updates of
  hidden rows to every node. It now drops a candidate the session's RLS
  policies hide (the row-visibility check MERGE's match phase uses,
  SONNY-2686) before evaluating its WHERE and SET. SET clause ordering
  already matched (SONNY-3242). **Not fixed:** WHERE truthiness still
  differs: the leader keeps a row only when its WHERE is true (SONNY-3184),
  while the single-node MATCH paths take a non-zero integer as true, so
  `MATCH (n) WHERE n.a SET ...` with an integer `a` writes on a single node
  and not on a leader; and a WHERE or SET expression that fails to
  evaluate answers 40001 (ClusterWriteNotReplicable) on a leader instead of
  its own error. `test-sonny3246-cluster-set-rls`.
- **A cluster applies a write under the writing session's tenant
  (SONNY-2726).** In cluster mode a write reaches the store only through
  the raft apply, whose thread has no request context, and the replicated
  payloads carried no tenant, so every node and edge written through raft
  was tagged `default` on every node; since SONNY-2693 a tenant's
  replicated edges, and its nodes, were hidden from it. The leader now
  wraps the entry of a session whose tenant is not `default` in a GTN1
  envelope naming the tenant (`cluster_replication.wrapWithTenant`, in
  `statement_proposals.proposeNow`, for every graph mutation: create,
  batch, delete, merge, update), and the apply sets that tenant for the
  entry (`raft_apply.applyGraphMutation`). A default-tenant write and
  every entry already in a log are unchanged. **Operator-visible:**
  upgrade every node of a cluster before tenant-scoped sessions write; a
  node running an older build skips a tenant-enveloped create (its
  unknown-payload arm) and cannot decode an enveloped delete, merge or
  update. **Not fixed:** data replicated before this change is still
  tagged `default`; a leader-driven re-tag replicated through raft does
  not exist yet (`geode.tenant.backfill_edge_tags` is refused in a
  cluster). `test-sonny2726-replicated-tenant`.
- **Tenant schema listings show what the session's MATCH sees; COUNT { hop }
  counts paths (SONNY-6344 items 1-2).** (2) `CALL db.labels()`,
  `db.relationshipTypes()`, `db.propertyKeys()`, SHOW TABLES and the LSP's
  schema completion read per-tenant structures by exact tag, and the edge
  property keys compared each edge's tag exactly, so a parent tenant listed
  only the labels, types and keys of rows tagged with its own tenant while
  its MATCH returns its descendants' rows too (GAP-0846). They now union
  the session's tenant and, when it is registered in the hierarchy, every
  descendant (`tenant_visibility.visibleTenantTagsAlloc`); a child and an
  unrelated tenant are unchanged. (1) An uncorrelated `COUNT { (a:S)-[:T]->(b) }`
  (and `EXISTS { ... }`) whose start node no outer variable binds counted
  the start nodes matching its head and ignored the relationship; it now
  counts the matching paths from every visible start node, as the
  correlated form does. **Behaviour change:** `RETURN COUNT { ()-[:L]->() }`
  answers the number of `:L` paths the session can walk, not the number of
  visible nodes. `test-sonny6344-tenant-schema-listings`; the two
  `test-sonny1326-expression-tenancy` assertions that pinned the node count
  now pin the path count.
- **Writes made after a checkpoint and a crash survive the next crash
  (SONNY-6384).** After an offline `geode user` change on a data directory,
  the server's later writes to `__geode_security` (CREATE USER, ALTER USER)
  were lost to a SIGKILL, and with enough of them the next start could fail
  to load the security graph (`admin bootstrap SKIPPED`,
  `hydration-time exact-index build failed … error.DataCorruption`). The
  cause was in graph persistence, for any graph, not in security code or in
  the CLI's hydration snapshots (the writes were lost with every snapshot
  removed). A full checkpoint compacts a shard WAL to empty and the WAL
  library deletes its `graph.wal.ckpt` sidecar, the only record of an empty
  WAL's LSN. A process that ended there without closing the engine (the
  offline CLI always did; so does a SIGKILL after any checkpoint) left the
  next open numbering the WAL from 0 while recovery replayed from the
  manifest's `last_checkpoint_lsn`: every later record was skipped after a
  crash, or past that many records only a torn tail was replayed. Opening a
  graph now appends a no-op checkpoint marker at the manifest's checkpoint
  LSN, and fsyncs it, when a shard WAL numbers below it (logged as "healed
  shard WAL LSN anchor"); an open whose marker cannot be written fails.
  Records an earlier recovery already skipped are not recovered.
  `test-sonny6384-offline-change-crash-durability`.
- **A gRPC chunked run that stops early still prints its summary; the Raft
  drop of a graph has no check-then-lock window (SONNY-6384 items 3, 4,
  6).** (6) `geode query --grpc --file`: when a chunk's connection failed
  after the chunk was sent, or the client timed out on it,
  `executeGrpcQuery` exited the process itself, so the run printed no
  "Chunked execution complete" summary and did not say how many statements
  were not run (the QUIC path did). It now returns to the chunked driver,
  which stops the run there (the chunk is still not sent again,
  SONNY-6377), prints the summary and exits 4 for a timeout, 1 otherwise.
  The statement-by-statement retry of a rejected chunk still exits inside
  `executeGrpcQuery` on those failures. (4) The Raft apply of `drop_graph`
  checked `graphExists` and then took the graph's write lock; a drop in
  between sent that lock to its global-exclusive fallback. It now calls
  `GraphStore.dropGraph`, which takes the write lock itself and reports a
  graph that is not there without locking it. (3)
  `tests/test_cli_file_chunked.zig`'s CANARY is TESTED (12/12 pass).
  `test-sonny6384-grpc-chunk-summary`.
- **`geode query` never sends a write again once the server may have
  applied it (SONNY-6377).** `geode query --file` on a file over 16 KiB
  ships each 32 KiB chunk as one program. A chunk of ~400 CREATEs takes
  ~38 s in a Debug server, past the default 30 s `--timeout`; the client's
  read timed out while the server was applying the chunk, and
  `executeChunkedQueries` took any transport error for a rejected chunk and
  replayed its statements one by one, so each landed twice (400 nodes
  became 800; `test-cli-file-chunked` failed 2 of 12). Over gRPC,
  `executeGrpcQuery` retried any error but a timeout or an incomplete
  response on a new connection, even after the Execute request was sent, so
  a connection reset after the server applied a CREATE ran it up to three
  times. The QUIC auto-retry in `executeQuicQuery` was not a cause (it
  retries only a failed HELLO); it now also checks that the query was not
  sent. **Behaviour change:** a chunk that was sent and got no answer is not
  sent again; the run stops there, says its statements may still be
  executing, and exits 4 for a timeout (as a single query does) or 1
  otherwise; the chunks after it are not run. A gRPC query whose connection
  fails after it was sent exits 1 with "may or may not have executed" and is
  not retried. `--retry` retries only before the query is sent.
  `test-sonny6377-query-no-resend`.
- **RLS row decisions, procedure results and the ABAC attribute store
  (SONNY-6377 items 3-5).** (3) `RLSEngine.checkRowAccess` cached its
  verdict under (graph, table, user, operation), a key with no row in it,
  and returned a cached deny before evaluating, so once one row was denied
  every later row of the table was denied to that user until the entry
  expired (fail closed, wrong results). A row-level decision is no longer
  cached, as `checkRowAccessByUsernameSeeded` already did (GAP-0284), and
  the evaluation holds the policy lock shared. (4) `geode.auth.user_import`
  and `geode.rls.list_deny_policies` results now own their rows (their
  strings leaked). **Behaviour change:** `geode.rls.policy_count()` and
  `list_deny_policies()` with no filter engine answer 55000, as the other
  `geode.rls` procedures do since SONNY-6369, instead of 0 and an empty
  list. (5) `user_attribute_store.setAttribute` allocates everything before
  it changes the store: an allocation failure after it inserted a new
  user's entry left that entry with the caller's username as its key and an
  undefined attribute map, and one after it removed the old value lost the
  attribute. (Item 6, security-graph writes outside a statement, did not
  reproduce: the login's hash upgrade and the ALTER USER intercepts survive
  a SIGKILL; the test pins it.) `test-sonny6377-security-residuals`.
- **One label-deny engine for the executor and the transport post-filter
  (SONNY-2729 part 2).** The post-filter (`server/rls_filter.zig`) had an
  engine type and global of its own, beside the executor's
  (`rls_types.RLSFilterEngine`), and `server/main.zig` kept the two in step
  (`addDenyToEngines` wrote each deny to both; remove, list and count used
  one of them), so a change that reached one engine and not the other, or a
  process that installed one, left the post-filter and the executor
  disagreeing about which labels a user may see. `rls_filter.RLSFilterEngine`
  and `LabelPolicy` are now rls_types' types, its global is rls_types'
  global, and the server creates one engine; `removeOneDenyPolicy` and
  `hasPoliciesForGraph` moved to rls_types' engine and `addDenyToEngines` is
  gone. Part 1 (the post-filters fail closed when they cannot run, 53200) was
  in v0.8.23.
- **Every `SecurityManager` method that touches shared state is locked
  (SONNY-2410).** One `SecurityManager` is shared by every connection
  thread. SONNY-2394 locked `authenticate`, `authenticateWithMFA` and
  `updatePassword`; the other methods read and changed the users, roles,
  permissions, role memberships, sessions, policies, MFA cache and audit log
  with no lock (`getUserIdByUsername`, which the QUIC and gRPC password
  change call, walked the users map while it could change; concurrent
  `createSession` / `hydrateUser` / `createRole` corrupted the maps and
  handed out one role id twice). Every public method but `init`,
  `initEmpty` and `deinit` now holds the manager's lock, which is
  re-entrant on one thread (`ReentrantMutex`). The pointers `createRole` and
  `createPermission` answer still point into the manager's maps and are
  moved by the next create.
- **The RLS policy cache owns its keys; no grant on graph `*` (SONNY-3135
  N6, N7d).** (N6) `RLSEngine.checkRowAccess` cached each decision under
  the graph and table strings its caller passed (`PolicyCache.put` kept the
  borrowed slices), so a library caller that freed them left every later
  cache lookup, invalidation and eviction reading freed memory (a crash in
  the eviction scan). The cache now keeps its own copy of each key and frees
  it with the entry. (N7d) **Behaviour change:** `geode.auth.grant(<priv>,
  <user>, '*')` answers 0A000 (`GrantWildcardNotSupported`) and stores
  nothing; it stored a grant on a graph named `*`, which no request matches,
  and reported it granted. A revoke of `*` still removes one an older
  release stored. N7c: see the next entry.
- **A graph drop waits for the graph's lock holders, whoever drops it
  (SONNY-3135 N7c).** DROP GRAPH's handlers take the graph's write lock
  before the executor drops it (SONNY-3028); every other caller of
  `GraphStore.dropGraph` held none: the executor's DROP GRAPH and CREATE OR
  REPLACE GRAPH of a graph created after the handler's lock attempt (or run
  by an embedded executor), the CREATE GRAPH rollback, the QUIC and gRPC
  HELLO auto-create rollbacks and `SchemaManager.createGraph`'s rollback.
  `StorageAdapter.dropGraph` only marks a pinned graph dropped (the pins
  kept its holders memory-safe), so such a drop returned while another
  request read or wrote the graph, and that request's writes went to a
  dropped graph while it reported success. `GraphStore.dropGraph` now takes
  the graph's write lock itself unless the calling thread holds it
  (`ManagedGraph.write_holder`, `StorageAdapter.threadHoldsGraphWriteLock`),
  first and released last; a missing graph is not locked (and not
  created). The raft apply already took the lock (SONNY-3350).
  `test-sonny3135-lockless-drop-waits`.
- **A write never creates a dropped graph again (SONNY-3122).** A session
  left on a graph another session dropped took the graph's write lock for
  its next write; the adapter no longer had the graph, and
  `materializeGraphForWriteLock` created it again so the write could go
  ahead, bringing the graph back for a principal without the schema
  permission (the SONNY-3033 class). A writer waiting for the lock while the
  drop ran was told the graph was gone and then created it the same way
  (review probe V12). The write lock now materializes only a graph the
  engine knows but has not opened (in its registry) and the default graph
  (ENG-3914 RC-3); for any other it answers GraphNotFound, also when the
  graph goes between its two attempts. **Behaviour change:** a write (or
  MERGE) from a session whose graph was dropped fails with GraphNotFound,
  over gRPC and over QUIC's general and fast paths alike; only CREATE GRAPH
  (and a HELLO allowed to create its graph) creates a graph.
  `test-sonny3122-dropped-graph-not-recreated`.
- **MERGE visibility refusals are rate-limited per session and label
  (SONNY-2817).** A MERGE refused for a row row-level security hides
  (`MergeMatchNotVisible`, 42501, SONNY-2686) is an equality oracle over
  any property its pattern names; SONNY-2728 audited each refusal, and
  nothing limited how fast a session could guess. **Behaviour change:** a
  session's fifth refusal within 60 s on one label of one graph starts a
  5-minute cooldown in which every MERGE naming that label there is refused
  with `MergeRefusalRateLimited` (SQLSTATE 53400), before what it would
  match is looked at, so the cooldown answers nothing. The cooldown's start
  (`MERGE_REFUSAL_RATE_LIMIT_ENGAGED`) and each refusal in it
  (`MERGE_REFUSAL_RATE_LIMITED`) are audited with the user, graph and
  labels, never a value. Other labels, other sessions and an embedded
  executor with no session are not limited
  (`src/execution/merge_refusal_limiter.zig`, `SessionState`; see
  `docs/kb/RLS_IMPLEMENTATION.md`). `test-sonny2817-merge-refusal-limit`.
- **`geode query` exit code, superuser roles, procedure errors, EXPLAIN
  POLICY's executor checks, legacy hashes (SONNY-6369).** (1) **Behaviour
  change:** `geode query` exits 1 when the server answers the query with an
  error (any non-00000 GQLSTATUS), on QUIC and gRPC, as `--batch` and
  `--file` already did; it exited 0 and only a transport failure was
  visible in the exit code. (2) **Behaviour change:** giving a superuser
  (the bootstrap admin, or any user stored with `is_superuser`) a role other
  than admin is refused: `ALTER USER ... SET ROLE` /
  `geode.auth.user_assign_role` answer 0A000 (`SuperuserRoleFixed`) and the
  offline `geode user assign-role` / `user update --role` exit 1, before
  anything is changed. A superuser always resolves to admin, so the role was
  stored, reported assigned and never took effect. (3) `geode.rls.add_deny_policy`,
  `remove_deny_policy`, `add_attribute_policy` and `remove_attribute_policy`
  answer missing arguments with 22023 and a process with no RLS engine with
  55000 (`RlsEngineNotInitialized`); they answered 00000 with an `error:`
  status row. (4) `geode.auth.user_set_attribute` / `user_remove_attribute`
  results own their rows (a caller freeing them leaked); removing an
  attribute the user does not have answers 42704 (`UserAttributeNotSet`)
  instead of a 00000 row, and `user_remove_attribute` checks its arguments
  (22023) and the user (42704 for an Admin) as `user_set_attribute` does.
  (5) EXPLAIN POLICY also reports the checks the executor makes itself:
  `bind_graph` for USE GRAPH, the procedure gate (`read` / `write` on
  `procedure:<name>`, refused too by a deny on the graph it runs on), and
  the DDL schema gates (`schema` and `bind_graph` on the graph, `schema` on
  `graph:*` for index, constraint and schema DDL). (6) A user whose stored
  hash is a legacy BLAKE2b hash (`user import --algorithm blake2b`) gets an
  Argon2id hash of the same password at its first successful login (saved
  to `__geode_security`, sealed; its auth version, sessions and reset flag
  are kept; not in cluster mode, where the legacy hash stays). Checking a
  password against a legacy hash now does Argon2id's work too, so the login
  time no longer tells which accounts hold a legacy hash. (7) Docs:
  `GQL_AUTH_DDL.md` gives a CREATE USER whose save fails as 58030;
  `ENTERPRISE_GAPS.md` and `KNOWN_TEST_ISSUES.md` give `gql_conformance` as
  21/21.
- **`geode.rls.*` restrictions survive a restart and are refused in
  cluster mode (SONNY-3034).** (1) **Behaviour change:** the label denies
  `geode.rls.add_deny_policy` adds and the attribute policies
  `geode.rls.add_attribute_policy` adds, and their removal, changed the
  in-memory RLS engines only: a restart dropped every restriction without
  a word (the v0.8.23 known limitation). They are now stored in
  `__geode_security` as policy records of their own kinds (`rls_deny`,
  `rls_attribute`; GPS hydration skips them), signed and sealed into the
  HMAC chain like the other security records
  (`AuthGraphManager.persistRlsRestriction` / `removeRlsRestriction`),
  and put back in force at startup before any listener starts
  (`[startup] geode.rls restrictions loaded: N of M`; one that cannot be
  applied is logged as an error and the rest still load). An add that
  cannot be stored is taken out of the engines again, and a removal that
  cannot be stored leaves the restriction in force; both fail with 58030
  (`RlsRestrictionNotPersisted`). A server whose auth graph manager is not
  active refuses them the same way. An executor with no security graph
  wired (embedded, unit tests) keeps them in memory only, as before.
  Records written by this release are not understood by older releases,
  which refuse to load them (the restriction is then not in force there).
  (2) **Behaviour change:** in cluster mode the four changes
  (`add_deny_policy`, `remove_deny_policy`, `add_attribute_policy`,
  `remove_attribute_policy`) are refused like the other unreplicated
  security changes (`cluster.gateUnreplicatedWrite`: follower 40001
  `ClusterNotLeader`, leader 40001 `ClusterWriteNotReplicable`); they
  applied on one node only. The user ABAC attributes
  (`geode.auth.user_set_attribute`) the attribute policies compare against
  are still memory-only.
- **The expression RLS engine frees what it owns of a policy
  (SONNY-2773).** `RLSEngine.deletePolicy` and `deinit` freed neither the
  bytecode the engine compiles for a policy's USING / CHECK expression nor
  the strings `geode.rls.add_attribute_policy` hands to it, and
  `updatePolicy` dropped the bytecode it replaced: every
  `geode.rls.remove_attribute_policy`, every geode-auth policy delete or
  expression change, and every engine teardown leaked them for the server's
  life. The engine now records what it owns (`Policy.owns_using_compiled` /
  `owns_check_compiled`, set when it compiles; `owns_strings`, set by an
  installer that hands its strings over, as `add_attribute_policy` does)
  and frees exactly that on delete, on replace (keeping what the
  replacement still points at) and at deinit. A pre-compiled expression a
  caller pins, and strings a caller keeps (UserManager's, SONNY-2778), stay
  the caller's.
- **EXPLAIN POLICY asks what the gates ask; tenant listings are read-only
  (SONNY-6313).** (1) **Behaviour change:** `EXPLAIN POLICY FOR <statement>`
  derived one action and asked `gps.decide` about it on the resource
  `database`, which no graph-scoped policy matches since SONNY-2753, so a
  graph-scoped deny or allow was reported as not applying, and it did not
  know the per-action write gate (SONNY-2781). It now reports one row per
  question the QUIC and gRPC handlers' gates ask, for the session's graph:
  the read gate's `decide(match_, graph)` on every graph the statement reads
  (`query_traits.programReadGraphList`), and the write gate's actions on the
  graph it changes (`write_walk.statementActions`: CREATE, UPDATE, DELETE;
  WRITE and SCHEMA for DDL; WRITE, CREATE, UPDATE and DELETE for a change
  no finer action names; for a self-locking procedure `gps.writePermitted`
  on the database). The `resource` column is `graph:<name>`, or `database`
  for a statement neither gate asks about (the security DDL, SHOW, session
  statements), which still reports the one action it names. A change now
  has two or more rows (its read, then its write). It still enforces
  nothing. (2) `geode.tenant.list` and `geode.tenant.show` were not on the
  read-only procedure list, so they counted as changes: a read-only request
  (`ExecuteRequest.read_only`, the MCP read-only mode) could not list
  tenants. They are read-only now and still need `admin_tenant` (Admin).
- **Offline user CLI and the remaining auth procedure failures
  (SONNY-6367).** (1) **Behaviour change:** `geode user create --role`,
  `user update --role`, `user import --role` and `user assign-role` stored a
  role node and never gave it to the user, then reported success: the user
  had no role. They now assign the built-in role as `ALTER USER ... SET
  ROLE` does (`cli_auth_helpers.assignBuiltinRole`); `create` / `import`
  with no `--role` give `user`. A role name that is not built in, and
  `assign-role` of a missing user, are refused before anything changes.
  Users created offline before this hold no role. `geode role create` used
  the next user id as the role id and could overwrite an existing role; it
  now goes through `AuthGraphManager.createRole`. (2) `geode user list`
  printed `(role: user)` for everyone and `geode user show` of a missing
  user printed made-up details and exited 0; they print the role the server
  resolves, and `show` of a missing user fails. (3) **Behaviour change:**
  `geode user enable | disable` of a missing user, and
  `geode.auth.user_enable` / `user_disable`, answered success; they fail
  (42704 for an Admin over the wire). (4) **Behaviour change:**
  `geode.auth.user_set_attribute`, `role_create`, `user_import`,
  `mfa_setup`, `mfa_verify`, `mfa_enable` and `mfa_disable` failures are
  GQLSTATUS errors (42704, 22023, 42710, 0A000, 55000 not enrolled, 28000
  invalid code, 53400 locked out) instead of 00000 status rows; a failed
  `mfa_verify` no longer reads as a pass to a caller that checks the status.
  Scripts and harness specs that matched those rows must match the error.
  (5) A user imported with `--algorithm blake2b` could never log in (the
  login verified only Argon2id); the login now verifies the legacy BLAKE2b
  format (`geode_auth.verifyPasswordBlake2bLegacy`, constant time, refused
  under FIPS). (6) The unreferenced `src/cli/user_storage_simple.zig` and
  `user_storage_secure.zig` were removed. (7) `tests/simple_stdio_test.sh`
  test 3 read only the first output line (a warning) and always failed.
  (8) The `gql_conformance` suite count in CLAUDE.md and the status docs is
  21/21 (T1–T20 and the `ZZ_cleanup` teardown), not 20/20.
- **Auth residuals (SONNY-6359).** (1) **Behaviour change:** an Admin's
  `ALTER USER <other> SET PASSWORD` over QUIC and gRPC was refused 42501 by
  the password intercept before the parser, although
  `docs/GQL_AUTH_DDL.md` maps the statement to
  `geode.auth.user_reset_password`. The intercept now handles only the
  session's own password (and refuses a request with no authenticated
  user); another user's goes to the parser and runs as
  `user_reset_password`: Admin only (42501 otherwise), the password policy
  (22000), audited (`proto_util.passwordInterceptApplies`). (2) **Behaviour
  change:** `geode.auth.user_change_password` skipped the old-password check
  when the old password was empty; it always checks it now (28000 and
  nothing changed). (3) **Behaviour change:** failures that answered SQLSTATE
  00000 with a status row starting `error:` or `note:` are GQLSTATUS errors:
  `user_create` / `CREATE USER` of an existing user 42710 and of the reserved
  `geode-cluster` 42939 (any other failure its own status);
  `user_enable` / `user_disable` and `user_assign_role` failures (e.g. an
  unreadable security graph, 58000); `user_assign_role` without arguments
  22023 and of a missing user 42704 for an Admin; an unknown privilege 22023;
  `GRANT` / `REVOKE` without `ON GRAPH` (and `geode.auth.grant` / `revoke`
  with an empty resource) 0A000, changing nothing. (4)
  `SecurityManager.validatePassword` counted runs of letters and digits as
  words while `PasswordPolicy` counts space-separated words, so
  `Alpha-Beta-Gamma-Delta-Epsilon` passed one and not the other; both use
  `PasswordPolicy.countPassphraseWords`. (5) `UserStorageBackend.hasGraphGrant`
  and `AuthGraphManager.listGraphGrants` / `listGraphGrantsForUser` (SHOW
  GRANTS, startup hydration) read the grant records without `auth_ddl_lock`,
  under which GRANT / REVOKE change them; they hold it now, and the GRANT /
  REVOKE write-throughs take it themselves (re-entrant). (6) `geode auth
  verify` ran the save path of a changing command and leaked the resolved
  data directory; it now tears down without sealing or saving
  (`cli_auth_helpers.deinitCliAuthWithoutSaving`) and leaks nothing.
  **Remaining (not fixed):** opening the store still writes: each graph's
  WAL is checkpointed (`graph.wal.ckpt`) and truncated, the graph registry
  and the timeseries WAL are rewritten, and `.geode.lock` records the
  holder; the storage engine has no read-only open, so a verify that
  writes nothing at all needs one. (7) The in-repo scripts (`tests/*.sh`,
  `scripts/cluster_spawn.sh`) seeded admin passwords that break the password
  policy (a forced reset at the first login, so every query failed with
  08P01); they seed the passphrase `Geode Test Admin Passphrase` (the
  backup scripts their own passphrases), and the scripts that built a
  command string with the password use `tests/lib/geode_cli_wrapper.sh` so
  the passphrase stays one argument.
  Regression: `zig build test-sonny6359-auth-residuals`.
- **User changes no longer hold the user store's mutex across the
  security-graph write; offline removals report a failed delete (SONNY-6352,
  items 3 to 5).** (3) `user_management`'s createUser, createUserWithHash,
  deleteUser, updateUserPassword, assignRole and setUserActive held
  `user_store_mutex` (lock tier 5) while the persistent writer wrote the
  `__geode_security` graph (tier 1), a lock-order reversal. Each now holds
  `auth_ddl_lock` (tier 1.7, re-entrant) for the whole change, so user
  changes stay serialized (the QUIC and gRPC `ALTER USER ... SET PASSWORD`
  intercepts, which did not take it, included), and takes `user_store_mutex`
  only to read the cache before the write-through and to apply the saved
  change after it; a created user is cached only once it is saved. The
  Argon2id work of CREATE USER and a password change (the reuse check and the
  new hash) now runs with the mutex released too. (4) **Behaviour change:**
  `geode user delete`, `geode role delete` and `geode policy delete`
  dropped the removal's error and reported the record deleted while it
  stayed stored; they now print the error, say nothing was deleted and exit
  1. `geode policy delete` of a name with no RLS policy said `deleted`; it
  now says `not found (noop)`, as `geode role delete` does. (5) DROP USER
  whose node delete fails (58030, the user stays stored and is locked out,
  its sessions stale, the chain verifies, the retry drops it) now has an
  end-to-end test. The lock-order table in `CLAUDE.md` lists
  `auth_ddl_lock`.
  Regression: `zig build test-sonny6352-auth-writer-and-removals`.
- **Offline `geode user create` and `geode user update --password` store an
  Argon2id hash, not the password, and seal the chain (SONNY-6358).** Both
  wrote the supplied password into the user record's `password_hash` as it
  was (`src/cli/user_mgmt_cli.zig`), so the credential sat in the clear in
  `__geode_security` and no login with it could succeed (the server checks
  an Argon2id PHC string). They now hash with the server's
  `geode_auth.hashPasswordArgon2id`; a password set on an existing user goes
  through `AuthGraphManager.updateUserPassword` (record HMAC, chain seal,
  forced-reset flag cleared, auth version moved on), as `change-password` /
  `reset-password` already did. On a store with no auth records the change
  was not sealed at all and the server refused to start (no chain root); it
  is now sealed with the key the server would use there
  (`cli_auth_helpers.changeKey`: `GEODE_AUTH_HMAC_KEY`, `GEODE_TDE_KEY`, else
  `.geode_hmac_key`, generated as at the server's first start). **Operator
  action:** a user created or updated offline before this fix has its
  password stored in the clear and cannot log in; set it again (`geode user
  reset-password`). FIPS builds refuse to set a password offline
  (`FipsUnsupported`), as on the server. `docs/USER_AUTH.md` no longer
  claims BLAKE2b is the current password hash.
  Regression: `zig build test-sonny6358-offline-password-hash`.
- **The periodic auth chain verification and `canUserAccessGraph` hold the
  auth DDL lock (SONNY-6352, items 1 and 2).** `AuthGraphManager.runVerifyRound`
  -> `verifyChain` read the role, policy and permission caches and the
  per-graph grant map, and `canUserAccessGraph` (LSP / schema visibility)
  iterated the grant map, without `auth_ddl_lock`, under which CREATE /
  DROP ROLE, CREATE / DROP POLICY, GRANT and REVOKE change them (SONNY-6329).
  A verification racing one of them could read a map mid-rehash, or count
  records that changed before it read them; the count mismatch reached a
  `catch unreachable` and crashed the verifying thread. Both now hold
  `auth_ddl_lock` (the round takes it before the store lock), and
  `verifyChain` fails with `RecordCountMismatch` instead of crashing when
  the records read do not match the count. A verification round now waits
  for an auth change in progress (and delays one for at most its bounded
  store-lock wait).
  Regression: `zig build test-sonny6352-auth-verify-locking`.
- **Offline auth CLI uses the server's data directory; `geode auth verify`
  no longer passes a store with no auth state; GRANT of a missing user is an
  error; auth DDL results own their rows (SONNY-6345).** (1) **Behaviour
  change:** with no `--data-dir` and no `GEODE_DATA_DIR`, `geode auth init |
  reseal | verify | policy | grant`, `geode user` and `geode role` opened
  `/var/lib/geode` (their help said `./data`) while `geode serve` opens the
  per-user default (`$XDG_STATE_HOME/geode`, `~/.local/state/geode`,
  `/tmp/geode-<uid>`), so they inspected and changed another store. They now
  resolve the directory as the store does
  (`cli_auth_helpers.resolveCliDataDir` over
  `graph_store.getPersistenceFilePath`); `geode auth init` creates it, and
  the HMAC key is looked up in the resolved directory (it was looked up only
  under an explicit `--data-dir`). Operators who relied on the
  `/var/lib/geode` default must pass `--data-dir /var/lib/geode` or set
  `GEODE_DATA_DIR`. (2) **Behaviour change:** `geode auth verify` on a
  directory with no `__geode_security` graph created the directory, the
  registry, a lock file and the security graph and printed `0 records,
  integrity OK` with exit 0; it now reads the registry only, creates
  nothing, and reports that there is no auth state with exit 1. (3)
  **Behaviour change:** `GRANT` / `REVOKE ... ON GRAPH` (and
  `geode.auth.grant` / `revoke`) of a user that does not exist answered
  00000 with a row `error: user not found`; it is now 42704 (`User does not
  exist`), and with no security graph wired 58030. (4) The status rows of
  `CREATE` / `ALTER` / `DROP USER`, `GRANT` and `REVOKE` are owned by their
  result (they leaked when the caller freed the result with a
  general-purpose allocator).
  Regression: `zig build test-sonny6345-auth-cli-and-grant`.
- **`GRANT ROLE <custom role>` is refused instead of reporting a grant that
  confers nothing (SONNY-6292).** A custom role (`CREATE ROLE`) carries no
  privileges. `GRANT ROLE <custom> TO <user>`, `ALTER USER <user> SET ROLE
  <custom>` and `geode.auth.user_assign_role(<user>, <custom>)` answered
  `assigned custom role ...` and kept the name in an in-memory table that was
  never saved (gone at restart), was not cleared by `DROP ROLE` (a role
  re-created under the same name went back to its old members), was read by
  no authorization path, and was read through a slice returned after its
  lock was released. **Behaviour change:** they now fail with SQLSTATE 0A000
  and change nothing; the table and `auth_dispatch.getCustomRolesForUser` are
  removed. Built-in roles are granted as before; an unknown role is still an
  error. Privileged custom roles with persisted membership remain
  unimplemented (docs/GQL_AUTH_DDL.md, Known Limitations).
  Regression: `zig build test-sonny6292-custom-role-membership`.
- **BREAKING: one password policy on every path that sets a password
  (SONNY-6331).** The documented policy (docs/USER_AUTH.md section 2: at
  least 20 characters, an upper and a lower case letter, at least 3
  space-separated words, the limits raised by `GEODE_PASSWORD_MIN_LENGTH` /
  `GEODE_PASSWORD_MIN_WORDS`) was applied by the offline `geode user` CLI and
  the forced reset only. On the server `CREATE USER` /
  `geode.auth.user_create` applied an older rule (8 characters, a letter and
  a digit) and `ALTER USER ... SET PASSWORD` / `geode.auth.user_reset_password`
  / `user_change_password` none (an empty password was accepted). They now
  apply the policy (`user_management.createUser` / `updateUserPassword`). A
  refused password answers SQLSTATE 22000 with the first rule it breaks and
  the configured limit (for example `Password too short (minimum 25
  characters)`; the policy's messages always said 20 characters and 3
  words), never the password, and nothing is created or changed.
  **Behaviour changes:** (1) clients that create users or set passwords with
  short or one-word passwords (`Alice123!`) are refused and must use
  passphrases; (2) a first-boot `GEODE_ADMIN_PASSWORD` /
  `GEODE_DEFAULT_PASSWORD` seed that does not meet the policy is still
  accepted, but the admin now has to set a compliant password at first login
  (a forced reset, as docs/USER_AUTH.md "Reset Triggers" states; it was
  accepted with a warning only), so deployments and test rigs that seed a
  one-word admin password (`GeodeTestPassword123!`) must seed a passphrase
  to avoid the reset; (3) generated passwords (the first-boot admin and its
  `.geode_admin_password` file, `geode user ... --generate-password`,
  `user_create`'s generated password) are passphrases of 8-character words
  that meet the policy instead of 32 hex characters, which it refused (so
  `geode user change-password --generate-password` failed its own check).
  Existing users are not locked out: a stored password that predates the
  policy keeps working, and the policy applies at its next change.
  `GEODE_PASSWORD_MIN_LENGTH` above 256 (the longest accepted password) is
  read as 256, and `GEODE_PASSWORD_MIN_WORDS` above 128 as 128 (no password
  could be set). docs/USER_AUTH.md no longer claims the server re-checks
  stored passwords at login (it does not).
  Regression: `zig build test-sonny6331-password-policy-paths`.
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
- **Restore rejects archive entries that escape the restore directory
  (SONNY-6280):** the per-graph restore joined each archive entry name onto
  the restore directory unchecked, so an uploaded backup (`upload_backup`,
  admin) with a `../` or absolute entry name wrote outside it. The server
  and CLI restore now check the whole archive before writing anything:
  entry names must be relative, without `.`, `..` or empty components,
  backslashes or NUL, and unique (`UnsafeArchiveEntryName`). Restored files
  are created mode 0600 and synced; they used to get the umask default,
  which left `server.key` and `.geode_hmac_key` from a backup world-readable.
- **BREAKING: backups no longer hold the TLS key, the auth-chain HMAC key,
  the generated admin password or the lock file; server backups move under
  the data directory (SONNY-6299).** A backup archived every top-level file
  of the data directory: `server.key` (the TLS private key), `.geode_hmac_key`
  (the key that seals the `__geode_security` auth chain, so whoever held a
  backup could re-seal forged auth records), `.geode_admin_password` and
  `.geode.lock`, which a restore then planted in the new directory. Backup
  files were mode 0664. Server backups went to `./server_backups` of the
  server's working directory, so where they landed, and whether a restore
  found them, depended on how the server was started. Now a backup holds
  graph data only (never those files, `server.crt`, or the backup
  directory itself); backup files and `metadata.json` are 0600; a server
  writes its backups to `<data dir>/backups/` (0700) of the data directory
  its engine has open, or to `GEODE_BACKUP_DIR` (absolute, outside the data
  directory, else `InvalidBackupDir`). A server restore still reads
  `./server_backups` for one release (newest backup in either); move old
  backups into `<data dir>/backups/`. **Restoring auth state now needs the
  HMAC key:** `geode restore <file>` of a backup with `__geode_security`
  records takes `--hmac-key-file <source data dir>/.geode_hmac_key` or
  `GEODE_AUTH_HMAC_KEY`/`GEODE_TDE_KEY`, verifies the chain with it before
  committing (`HmacKeyRequired`, `AuthChainVerificationFailed` otherwise),
  or, if the key is lost, `--unverified-auth`, after which no server starts
  until `geode auth reseal --data-dir <dir>` accepts the records. Keep the
  HMAC key with your key material, apart from the backups. A server restore
  copies the server's own key file into the restored directory. A restored
  directory gets a new self-signed TLS certificate on first start; copy
  `server.crt`/`server.key` over, or use `GEODE_CERT_DIR`, to keep the old
  identity. Backups written by older binaries still restore, with a
  warning; their key files are written 0600 and their lock file is not.
  Regression: `zig build test-sonny6299-backup-excludes-secrets`.
- **BREAKING: no TLS key, temp directory or backup at a fixed `/tmp` path
  (SONNY-6325).** The auto-generated TLS certificate and private key fell
  back to `/tmp/geode-server.crt` and `/tmp/geode-server.key` whenever the
  server ran without `--data-dir` (with `GEODE_DATA_DIR` or the per-user
  default only) and whenever the data or cert directory could not be
  written; a key already at that path was served whoever planted it, and
  openssl followed a symbolic link planted there. Now:
  - the auto pair lives in `GEODE_CERT_DIR` or the RESOLVED data directory
    (`--data-dir`, `GEODE_DATA_DIR` or the per-user default; a gRPC-only
    server no longer writes `./certs` of its working directory). There is
    no fallback: an unusable location **refuses startup** with the reason.
  - a new pair is generated in a private staging directory and installed
    exclusive and no-follow: key 0600, certificate 0644.
  - an existing auto key is used only when it is a regular file owned by the
    server's user with no group/other bits. **A symbolic link, another
    user's key, a group- or world-readable key (e.g. 0640), or a key without
    its certificate (or a certificate without its key) refuses startup**
    and is never changed: fix the mode (`chmod 600 server.key`), the owner,
    or remove both files to regenerate. An operator-provided `--cert`/`--key`
    is loaded as before (no ownership or mode check).
  - the `cert_gen` tool needs an output directory (`cert_gen <dir>`;
    `make cert-gen` uses `CERT_DIR`, default `certs`).
  - the per-user last-resort data/state directory is `$TMPDIR/geode-<uid>`
    (TMPDIR when absolute, else `/tmp`), used only when neither
    `XDG_STATE_HOME` nor `HOME` is set. It is created 0700; **an existing one
    that is a link, another user's, or not mode 0700 is refused**, never
    chmod-ed.
  - S3 restore stages in a private directory beside the target (random
    name, 0700), not `/tmp/geode_s3_restore_<id>`.
  - a backup with no data directory configured (no override, no
    `GEODE_DATA_DIR`) fails with `BackupDataDirUnknown`; it used to archive
    every top-level entry of `/tmp`.
  - `geode backup list` scans `./backups`, `./server_backups` and
    `$GEODE_DATA_DIR/backups`, not `/tmp`.
  - the audit diagnostic procedures (`audit.test_file_output`,
    `audit.test_auth_categories`, the test logger) write
    `<data dir>/audit-diagnostics/` (0700, files 0600, no link followed);
    `audit.cleanup_test_artifacts` removes files there only. It used to
    delete fixed `/tmp` files and `/etc/geode/geode_audit.jsonl`.
  - the schema catalog falls back to the resolved data directory, not
    `/tmp`; the uncalled `/tmp`-using `txn_session.zig`, undo-log file
    persistence and `wal.initGlobalWal` were removed.
  Regression: `zig build test-sonny6325-no-fixed-tmp-paths`.
- **BREAKING: backups no longer hold the audit signing seed; a restored store
  starts a new audit key epoch; startup never invents an HMAC key over auth
  records; a server restore verifies the auth chain (SONNY-6322).**
  - `<graph>/audit.jsonl.key` (the Ed25519 seed that signs the audit log) was
    archived, so whoever read a backup could sign forged audit entries. It is
    now excluded at any depth; the log and its public keys stay. With the seed
    missing, the logger used to generate a new pair and **truncate**
    `audit.jsonl.pub`, so the restored entries no longer verified. Now it
    starts key epoch n+1: the old public key files are kept byte for byte, the
    new public key goes to `audit.jsonl.pub.<n>`, and a `KEY_EPOCH` record
    signed by the new key is appended. `geode audit verify` takes one
    `--pubkey` per epoch, in order, and **fails when any signature does not
    verify** (it reported `signatures_failed=N` and exited 0) or when a
    `--pubkey` is not valid hex (it was ignored, which turned signature
    checks off). Continuity across an epoch boundary is attested by the
    operator who restored the store, not by the previous key (which is not in
    the backup). See docs/AUDIT_LOGGING.md, "File-Backed Keys and Key
    Epochs". Older archives that hold the seed restore with a warning naming
    it, 0600.
  - Server startup on a data directory with `__geode_security` records and no
    HMAC key (no `GEODE_AUTH_HMAC_KEY`, `GEODE_TDE_KEY` or `.geode_hmac_key`)
    **refuses with `HMAC key required`** and writes nothing; it used to write a
    junk `.geode_hmac_key`, exit `AuthChainTampered`, and leave the junk key
    for the next attempt. A first boot still creates the key.
  - A server restore verifies the staged copy's auth chain with the server's
    key (by running `geode auth verify` on the staging copy) before it
    commits; a backup sealed under another key **fails** with
    `AuthChainVerificationFailed` and leaves nothing behind (it used to
    succeed and fail at the next startup).
  Regression: `zig build test-sonny6322-audit-seed-and-hmac-startup`.
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
- **Retiring the `auto_migrated_grant_*` policies fails closed
  (SONNY-4877).** Startup collected the policy names and deleted the stored
  rows before touching the live catalog; if either step failed (out of
  memory, a failed `__geode_security` write), startup logged the error and
  carried on with the migrated allow policies still enabled, so a revoked
  grant kept authorizing. Every migrated allow policy is now disabled in the
  live catalog, and cached decisions invalidated, before any step that can
  fail; migrated deny policies stay in force until dropped; the next startup
  drops the rows left. A retry that finds a row already removed by a failed
  run reseals the auth chain, so it verifies again.
  Regression: `zig build test-sonny4877-grant-retire-fail-closed`.
- **A `GRANT`, `REVOKE` or `CREATE USER` whose save fails answers an error
  and leaves nothing in force that is not stored (SONNY-1333).** A per-graph
  `GRANT` (and `geode.auth.grant`) logged a failed write to
  `__geode_security` and answered `Granted ...`: when the store write failed
  nothing was granted, and when the live-table insert failed the stored
  grant appeared at the next start. It now answers 58030
  (`GrantNotPersisted`) and grants nothing: every privilege of the statement
  (all three for `ALL`) is stored and live, or none is, and a grant held
  before is kept. A `REVOKE` takes the privilege away in memory first, so a
  failed save (58030, as since SONNY-3038) no longer leaves it usable until
  the restart; the retry removes the stored record. A revoke whose record
  delete failed inside the store used to count as done (the store's delete
  reports nothing) and the grant came back at the next start; the delete is
  now checked. `CREATE USER` whose save fails answers `error:
  UserNotPersisted` and creates no user (it could log in until the restart),
  and a user stored without its role edge is removed again, so the retry
  succeeds. With no persistence installed a `GRANT` or `REVOKE` fails rather
  than reporting success. A user or role record whose node could not be
  written no longer stays cached: the next auth-chain seal panicked
  (`RecordCountMismatch`). These write-throughs undo themselves and are not
  replayed by the statement undo (SONNY-3348), which reverted the security
  graph behind the auth manager's record maps; behaviour change: a `GRANT`,
  `REVOKE` or `CREATE USER` inside an explicit transaction is not undone by
  `ROLLBACK` (its in-memory effect never was).
- **`SHOW GRANTS [ FOR <user> ]` lists per-graph grants (SONNY-1333).**
  After the GPS policies that apply to the user, one row per graph the user
  holds grants on, as stored in `__geode_security` (null `policy_name`, the
  privileges in `actions`). `FOR` is optional (the current user). A user may
  list its own grants; another user's need the Admin role (42501 otherwise,
  audited). The new read-only `geode.auth.grant_list([username])` procedure
  returns one row per stored grant with the same rule. Behaviour change:
  `SHOW GRANTS FOR <other user>`, which listed policies for any caller, is
  refused for a non-admin, and an unauthenticated one (auth on) answers
  28000 like the other auth `SHOW` statements.
  Regression: `zig build test-sonny1333-grant-persist-show-grants`.
- **The other auth write-throughs answer an error when the save fails, and
  fail closed (SONNY-3038).** `DROP USER`, `ALTER USER ... SET PASSWORD`,
  `... SET ROLE`, `... ENABLE` / `DISABLE` (and their `geode.auth.*`
  procedures), `CREATE ROLE`, `DROP ROLE` and `geode.auth.user_import`
  logged a failed write to `__geode_security` and reported success. The
  in-memory user is reloaded from the store whenever its auth version
  differs, so a dropped user could still log in, the old password worked
  again, a disabled user was active again and a downgraded role came back,
  right away; a role or imported user lived in memory only until the
  restart. Each is now saved first and answers 58030
  (`UserNotPersisted`, `RoleNotPersisted`) when it cannot be, with the
  stored user or role as it was. A delete, a disable, a password change or
  a role downgrade that could not be saved locks the user out instead
  (no login, sessions no longer current) until a later change to the user
  is saved or the next start, as a failed `REVOKE` takes the privilege away
  at once; `DROP ROLE` removes the role from memory and fails, and the
  retry removes the stored record. Inside the auth manager, a password,
  active-flag, role (a role change is several edge writes), role-record or
  policy change that failed part way, the chain seal included, is undone,
  so the stored record and the chain agree and the next start verifies;
  `CREATE POLICY` and `ALTER POLICY` no longer leave a stored change behind
  the catalog they put back. `CREATE USER` keeps its status-row error
  (SONNY-1333). Also, `DROP USER` of a user not in the in-memory cache
  (users are loaded at their first login after a start, and evicted)
  answered `deleted` and deleted nothing; it now loads and deletes the
  stored user. See docs/GQL_AUTH_DDL.md, "When a save fails".
  Regression: `zig build test-sonny3038-auth-rls-low-findings`.
- **A dropped policy no longer comes back at the next start (SONNY-3038):**
  `DROP POLICY` removed the first stored GPS record of the name; a second
  one (written before names were unique, or by another writer) was loaded
  at the next start. It removes every one.
- **A label deny is in both RLS engines or in neither (SONNY-3038):**
  `geode.rls.add_deny` added the deny to the post-filter and, when the
  executor's engine could not add it, logged that and reported success, so
  aggregates and projected properties still counted the denied rows. The
  call now fails and the post-filter entry is taken out again.
- **The algorithm post-filter checks evicted nodes (SONNY-3038):** a node id
  in a `CALL algo.*` row was looked up in the bounded resident node cache
  only, and a node evicted from it was taken for a deleted one, so the row
  of a denied node was returned. It is read from the storage engine.
- **Federation post-merge filter and cache (SONNY-3038):** the rows the
  filter removed were not freed, and the shortened row list was freed with
  the wrong length; the federation query cache was keyed on the query text
  only, so one user's RLS-filtered results could be served to another. The
  filter frees what it removes; the cache key includes the user, graph and
  tenant. (The federation manager is not wired into the server; SONNY-6279
  and SONNY-6298 then removed it and `rls_filter.applyRLSToFederatedResults`,
  so only the removal is left to test.)
- **Removed the unused RLS `QueryRewriter` (SONNY-3038):**
  `rls_core.QueryRewriter` and `RLSEngine.rewriteQuery` built query text
  from policy text and combined policies the old way; nothing called them.
- **`SHOW PERMISSIONS FOR <user>` needs Admin for another user
  (SONNY-6269).** The docs said so, but `geode.auth.user_permissions` did
  not check it, so any authenticated user could list any other user's
  permissions. It now applies the `SHOW GRANTS` rule (SONNY-1333), through
  the same check: a user may list its own permissions (no `FOR`, or `FOR`
  its own name); another user's, a user that does not exist included, need
  the Admin role, and a refusal answers 42501 and is audited
  (`access_denied`). `CALL geode.auth.user_permissions()` with no argument
  now lists the caller's permissions, as `geode.auth.grant_list()` does,
  instead of an unnamed user's. Behaviour change: a non-admin's
  `SHOW PERMISSIONS FOR <other user>` is refused.
  Regression: `zig build test-sonny6269-permissions-admin-gate`.
- **A failed `DROP POLICY` no longer leaves the auth chain stale
  (SONNY-6273).** The auth manager removed the policy's records and then
  sealed the `__geode_security` HMAC chain; a seal that failed twice (no
  memory, say) left the records gone and the chain still counting them,
  while the statement failed and the policy stayed in force in memory. The
  chain did not verify (`RecordCountMismatch`), so a restart before the next
  auth change refused to start (`AuthChainTampered`), and after a reseal the
  policy the failed statement had kept was gone at the next start. Now the
  new seal is computed, every allocation of it, while the records are still
  stored, and only then are the records removed and the seal stored: a
  failure answers an error with the records, the catalog entry and the
  chain as they were (a deny keeps denying, an allow keeps allowing, after a
  restart too), and the retry drops it. A failure of the graph store's own
  seal write is sealed again, as before.
  Regression: `zig build test-sonny6273-drop-policy-atomic`.
- **Custom roles are no longer kept in a request's freed memory
  (SONNY-6278).** `CREATE ROLE`, `GRANT ROLE <custom role> TO <user>` and
  the startup hydration of stored roles copied the role name, description
  and member names into the process-wide custom-role store with the
  allocator of the request running them (the statement's arena). Once the
  request ended the store pointed at freed memory: `SHOW ROLES` could list a
  garbage name, and a role lookup, `GRANT ROLE` or `DROP ROLE` read freed
  memory (a use after free). The store and its membership table now own
  their copies with a process-lifetime allocator, as the ABAC attribute
  store does (GAP-0284); `DROP ROLE` frees the role's copies (they leaked),
  re-creating a role frees its old description, and
  `auth_dispatch.deinitCustomRoleStore` frees the rest.
  Regression: `zig build test-sonny6278-custom-role-lifetime`.
- **`SHOW USERS` no longer leaks on every call, and user and role listings
  no longer read freed memory (SONNY-6312).** `geode.auth.user_list` (and
  `SHOW USERS`) took a snapshot allocated with the user store's allocator
  that nothing freed, so every call leaked for the life of the server; and
  its rows pointed at the cached users' names and email addresses after the
  store lock was released, so a `DROP USER` on another connection could
  free them while the response was built (a use after free).
  `geode.auth.user_show` and `SHOW ROLES` borrowed the store's strings the
  same way. Each now answers a copy made under the store's lock with the
  request's allocator, which the request frees
  (`user_management.listUsers(allocator)` / `getUserSummary`); a listing
  that cannot be made is now an error instead of an empty list. The
  status rows of `CREATE ROLE` / `DROP ROLE` and the permission rows of
  `SHOW PERMISSIONS` are freed with their result (they leaked).
  Regression: `zig build test-sonny6312-user-list-ownership`.
- **Auth user lookups and auth DDL are serialized; `geode serve --no-auth`
  fails (SONNY-6329).** (1) The auth manager's user cache had no lock:
  `graphGrantCheck` resolved the user on every policy decision the decision
  cache missed by walking it while `CREATE` / `DROP` / `ALTER USER` on other
  connections changed it (a reader in a rehashed or freed map, in an
  authorization path). It now has a leaf reader-writer lock: lookups hold
  it shared and copy the id or record, writers hold it exclusively for the
  map change only. (2) An auth or policy change (the change in memory, the
  write-through to `__geode_security`, the undo when that fails) was not
  serialized across connections: a `CREATE POLICY x` and a `DROP POLICY x`
  could interleave and leave the catalog and the security graph
  disagreeing (or the chain unverifiable) until the next start. Every
  `geode.auth.*` procedure that changes state (and so `CREATE` / `ALTER` /
  `DROP USER`, `CREATE` / `DROP ROLE`, `GRANT`, `REVOKE`) and `CREATE` /
  `ALTER` / `DROP POLICY` now run one at a time under one lock
  (`security/auth_ddl_lock.zig`, which states its lock order). (3)
  **Behaviour change:** `geode serve --no-auth` now fails at startup in
  every build mode. It was refused outside Debug builds, and in a Debug
  build it logged "Authentication disabled" while authentication stayed
  on. The unused `ServerConfig.enable_auth` field is removed;
  `--enable-auth` is still accepted and does nothing (authentication is
  always on). `geode lsp --no-auth` and `geode mcp --no-auth` are
  unchanged.
  Regression: `zig build test-sonny6329-user-cache-and-ddl-serialization`.
- **A security record whose node delete fails stays stored and in force
  (SONNY-6293).** `UserStorageBackend.removePolicy`, `removeRole`,
  `removeUser` and `removePermission` took the record out of memory first
  and then deleted its `__geode_security` node without checking it (the
  `HAS_ROLE` edge delete of a role revocation likewise). A delete that
  failed left the node stored while the record was gone from memory: the
  chain was sealed without it, the next start loaded the policy or role
  again with a sealed record count that no longer matched, and DROP POLICY
  reported success. The node now goes first through the checked delete
  (grant removal's since SONNY-1333), and the record leaves memory only once
  it is gone. DROP POLICY of a policy whose node cannot be deleted answers
  58030 (`SecurityRecordDeleteFailed`) with the record stored, the catalog
  entry kept (a DENY keeps denying, an ALLOW keeps allowing) and the chain
  verifying; DROP ROLE answers 58030 (`RoleNotPersisted`, as before: the
  role is out of memory now and returns at the next start unless retried;
  a role only grants, so this fails closed); a DROP USER whose delete fails
  answers 58030 (`UserNotPersisted`) and the user stays locked out
  (SONNY-3038). A retry succeeds.
  Regression: `zig build test-sonny6293-checked-auth-deletes`.
- **The `geode.auth.apikey_*` procedures answer "not supported", and
  `user_show` no longer shows other users or invents rows (SONNY-6291).**
  The server has no API-key store: nothing creates, stores, hashes or
  revokes a key, and the QUIC / gRPC handshake does not authenticate by one
  (the `geode apikey` CLI keeps its own local state file). The procedures
  were stubs: `apikey_check_scope` answered `scope granted` for any key,
  `apikey_revoke` answered `revoked` and revoked nothing, `apikey_create`
  printed a key built from its arguments, and `apikey_list` /
  `apikey_check_scope` told any caller whether a user exists. **Behaviour
  change:** every `geode.auth.apikey_*` procedure now answers 0A000
  (`apikey_create` / `apikey_revoke` / any other mutating name still need
  Admin first: 42501 for anyone else). docs/USER_AUTH.md no longer lists
  API keys as implemented. **Behaviour change:** `geode.auth.user_show`
  follows the SONNY-6269 rule: a user may show itself (with no argument,
  itself); another user needs Admin (42501, audited `access_denied`). A
  missing user is an error, not a made-up `unknown` / `user` / `active`
  row: 42704 (`User does not exist`) for an Admin, and the same 42501 as a
  forbidden user for anyone else (no existence oracle).
  `geode.auth.user_permissions` / `SHOW PERMISSIONS FOR` of a missing user
  is 42704 for an Admin (it listed the `user` role's permissions).
  `error.UserNotFound` now maps to 42704 on every path.
  Regression: `zig build test-sonny6291-apikey-user-show`.
- **A read-only request refuses the security DDL (SONNY-2751).** The
  statement classifier behind the per-request read-only floor
  (`ExecuteRequest.read_only`, QUIC and gRPC) and the MCP read-only mode
  counted `CREATE` / `ALTER` / `DROP USER`, `CREATE` / `DROP ROLE`, `GRANT`,
  `REVOKE` and `CREATE` / `ALTER` / `DROP POLICY` as reads, so a read-only
  request ran them (each kept its own Admin check, so an Admin connection
  marked read-only created users and granted privileges). A user's own
  `ALTER USER <self> SET PASSWORD`, which both handlers take from the raw
  text before the parser, skipped the floor too. The one write walk
  (`execution/write_walk.zig`) now records which changes a statement makes
  (`Actions`); the floors refuse any of them (`StatementPlan.changes_state`,
  `query_traits.changesStoredState`), the security DDL included, and the
  password intercepts check the floor first. Procedures were already
  classified fail-closed (anything not on the read-only list counts as a
  change), and every statement kind is classified at compile time.
  `CALL geode.auth.grant_list`, which only reads, was missing from the
  read-only procedure list and is now on it; a compile-time check keeps that
  list and the auth dispatcher's read-only set in step. The security DDL
  still takes no graph write lock and no write gate. Behaviour changes: a
  read-only request refuses the security DDL and password changes (42501);
  `CALL geode.auth.grant_list` runs on a read-only request and for a
  read-only user; the `read_only_covers_admin_ddl` capability is now `true`.
  Regression: `zig build test-sonny2751-readonly-security-ddl`.
- **A GPS deny scoped to one graph applies to that graph only
  (SONNY-2753).** `gps.decide` matched deny policies with a rule under which
  a policy scoped to graph `g` also matched every non-graph resource: a DENY
  READ on `g` refused every read-only procedure on every graph, a DENY WRITE
  on `g` every procedure that changes data, a deny on `g` a node or edge of
  any graph, and a DENY DECRYPT_FIELD on `g` every decryption. Allow and
  deny policies now cover resources by one rule: `*` covers everything; a
  graph-scoped policy covers its graph and the nodes and edges in it. A
  procedure is refused by a deny on the graph it runs on (or `*`); field
  decryption asks on the node in the graph being read. A change of every
  graph at once (a self-locking procedure CALL; index, constraint and schema
  DDL, which bind every graph) is refused by a deny on any graph, since it
  changes that graph too. (Plain writes to another graph were already
  allowed: the write gate asks on the graph a program changes since
  REQ-SEC-PER-GRAPH-GRANTS.) Behaviour changes: a graph-scoped deny no
  longer refuses procedures, nodes, edges or decryption on other graphs; a
  DENY SCHEMA on any graph now refuses `CREATE` / `DROP INDEX`,
  constraint and `CREATE` / `DROP SCHEMA` DDL from every graph; a
  graph-scoped allow of DECRYPT_FIELD now allows decryption on its graph
  (it never applied before).
  Regression: `zig build test-sonny2753-graph-scoped-deny`.
- **Every GPS action a policy can name is enforced (SONNY-2781).**
  Enforcement asked `gps.decide` about `write` (one gate for all DML and
  DDL), `read` / `write` on procedures and `decrypt_field` only, and the
  handlers' read gate skipped `decide` for every principal whose builtin
  role holds Read: a DENY READ or MATCH did not stop a plain MATCH, a DENY
  CREATE, UPDATE or DELETE stopped nothing, and an allow naming one of
  those allowed nothing (v0.8.23 documented them as accepted but not
  enforced). Now the handlers' write gate (`gps.changePermittedOn`) asks
  by what the program does, from the same write walk that decides the lock
  and the read-only floor: CREATE for CREATE / INSERT / MERGE, UPDATE for
  SET / REMOVE / a MERGE's ON MATCH SET, DELETE for DELETE, WRITE and
  SCHEMA for DDL, and WRITE with CREATE, UPDATE and DELETE for a procedure
  that changes data, BACKUP and RESTORE. WRITE is the umbrella (a DENY WRITE
  still stops every change; an ALLOW WRITE allows every data change). The
  read gate asks MATCH (matched by a READ or MATCH policy) for every
  principal, on every graph the program reads, an EXPLAIN'd statement's
  graph included. A deny naming UNWRAP_KEY, which nothing asks for, is
  refused when added (`error.PolicyActionNotEnforced`); an allow naming it
  is still accepted. `execution.checkPermission`, which had no callers, is
  removed. The security DDL no longer counts as touching the session's
  graph. Behaviour changes: a DENY READ / MATCH on a graph refuses every
  read of it, writes included (a change reads the graph it changes), and
  EXPLAIN of a statement on it; a DENY CREATE, UPDATE or DELETE refuses the
  matching statements; an allow naming CREATE, UPDATE or DELETE (with READ
  on the graph) now allows them; a DENY SCHEMA now also refuses CREATE /
  DROP GRAPH TYPE; adding a deny naming UNWRAP_KEY fails. See
  docs/security/gps-decide.md, "What each action enforces".
  Regression: `zig build test-sonny2781-gps-action-enforcement`.
- **The GPS policy catalog has a lock (SONNY-2756).** `gps.decide` walks
  the policy catalog on every read and write the handlers gate, and SHOW
  POLICIES, SHOW GRANTS FOR and `geode.auth.policy_list` list it, while
  CREATE, ALTER (RENAME, SET ENABLED) and DROP POLICY on other connections
  appended to, renamed in and freed from it with no lock: a reader could
  walk a list being reallocated or read a dropped policy's freed strings
  (SHOW POLICIES crashed under concurrent policy DDL), and a decision's deny
  scan and allow scan could see two different catalogs, so it could allow
  what no catalog allowed. The catalog now has a reader-writer lock: a
  decision holds it shared from its deny scan to its allow scan, listings
  copy their rows under it, and each change holds it exclusively for the
  change alone (never across the `__geode_security` write-through), with
  the policy version bumped and cached decisions invalidated under the same
  hold. Behaviour change: a policy change waits for the decisions and
  listings in progress (microseconds) and they wait for it. The DROP GRAPH
  half of the ticket was closed by SONNY-3028 (pinned graphs, DROP GRAPH
  waits for the graph's lock holders).
  Regression: `zig build test-sonny2756-policy-catalog-concurrency`.
- **With authentication disabled QUIC and gRPC treat a request the same
  (SONNY-2782).** The QUIC handler ran its write and read gates only for a
  session with a role, so with authentication disabled nothing was gated;
  the gRPC handler skipped its read gate likewise but ran its write gate for
  every session, and refused every change (42501) unless
  `--insecure-allow-all` was set, while it ran reads and every admin
  procedure. Both handled DDL and changing procedures by handing the
  executor an anonymous principal, which refused them. Now both handlers
  authorize through one function (`session_graph.requestPrincipal`,
  `requestChangePermitted`, `requestReadPermitted`): with authentication
  enabled every session is gated, whatever its role (one with none is
  refused); with it disabled there is no principal and every request runs
  as if by an administrator, on both transports, `--insecure-allow-all` or
  not. Authentication disabled is an in-process mode (embedders, tests):
  `geode serve` always enables authentication. Behaviour changes, with
  authentication disabled only: gRPC runs changes, DDL and changing
  procedures without `--insecure-allow-all`, and QUIC runs DDL and changing
  procedures; with authentication enabled, a QUIC session with no role is
  now gated (it was not; no such session arises today). See
  docs/security/gps-decide.md, "Authentication disabled".
  Regression: `zig build test-sonny2782-auth-disabled-transport-parity`.
- **The server's bulk MERGE matches a node only in the session's tenant
  (SONNY-2976, SONNY-2724).** MERGE's property index has no tenant in its
  key and names one node per key, the lowest id in any tenant, and the
  storage adapter's bulk MERGE (`bulkMergeNodeWithReservedIdForTenant`,
  the multi-property variant, `bulkMergeNode`) took that node as the match.
  A MERGE run for tenant B matched tenant A's node with the same key,
  rewrote its properties (`ON MATCH SET`, bare `SET`) and answered its id,
  and tenant B got no node of its own. **Security fix for v0.8.22 users:**
  v0.8.22 let any tenant-scoped QUIC client reach this through a simple
  MERGE; v0.8.23 refused tenant sessions at the QUIC dispatcher (SONNY-2686)
  but left the adapter wrong. The adapter now matches as the general
  executor's MERGE does: a request with a concrete tenant matches only a
  node tagged with exactly that tenant (the lowest such id, found through
  the exact node-property index or a label scan when the index names
  another tenant's node), and otherwise creates its own node tagged with
  it; an unscoped request (`default`) still matches the lowest holder in
  any tenant. The bulk edge paths' endpoint lookups and the bulk MERGE's
  first probe are confined the same way. **Behaviour change:** the node
  MERGE fast paths (node, graph-selector and `/*+BATCH*/` MERGE) serve
  tenant-scoped sessions again, under strict tenancy too, so bulk ingest
  from them is fast again; the relationship MERGE and MATCH … CREATE edge
  fast paths, and every fast path for a user while an RLS policy is
  installed, still take the executor. A tenant MERGE of a key whose lowest
  holder belongs to another tenant now searches that key's holders (the
  exact node-property index, or in lean mode a label scan) on each call.
  Regressions: `zig build test-sonny2976-merge-fast-path-tenant-scope`,
  `zig build test-sonny2724-quic-fast-path-gate`.
- **MERGE matches the rows the session's MATCH sees, with a tenant
  hierarchy too (SONNY-6338).** The executor's MERGE compared tenant tags
  exactly, while MATCH lets a parent tenant see its descendants' rows
  (GAP-0846). A parent's `MERGE (:L {k: 1})` of a key its child holds found
  no match and created a second node, and the parent's MATCH then returned
  both. Node, multi-property and relationship MERGE (the endpoints and the
  edge's own tag) now use the MATCH path's tenant predicate
  (`tenant_visibility.passesTenantFilterSlice` / `passesTenantFilterEdge`),
  so the parent binds the child's node. `ON MATCH SET` then writes it as the
  parent's `MATCH ... SET` already could, and never changes its tenant tag;
  `ON CREATE` still tags the new node with the session's tenant. A child
  still does not see, or match, its parent's rows, and unrelated tenants
  and unscoped sessions are unchanged. **Behaviour change:** the node MERGE
  fast paths (node, graph-selector and `/*+BATCH*/` MERGE) match the exact
  tenant tag, so they now decline a session whose tenant has descendants;
  its MERGEs take the executor (correct, slower). Sessions of a tenant with
  no descendants are served exactly as before. The cluster leader's
  MATCH ... SET and MATCH ... CREATE target resolution uses the same
  predicate and so also sees a parent's descendants' rows, as MATCH does.
  Regression: `zig build test-sonny6338-tenant-visibility-consistency`.
- **knn() ranks the rows the session's MATCH sees, with a tenant hierarchy
  too (SONNY-2820).** knn() compared tenant tags exactly, so a parent
  tenant missed every row of its descendants that MATCH returns. Both the
  scan and the vector-index path now use the MATCH path's tenant predicate,
  and still filter before cutting to k (the index path asks the index for
  twice as many rows until it has k visible ones or the index runs out), so
  a hidden row never takes a slot. Whether the index may answer alone is now
  decided over every tenant's carriers when the hierarchy lets the session
  see more than its own tag (it falls back to the scan more often for such
  a session). **Behaviour change:** for a session whose scope can hide rows
  (a concrete tenant scope, or a user an RLS policy may deny a row), a knn()
  property no visible row carries now answers an empty list, as MATCH
  answers an empty result, instead of `UnknownProperty` (42703). That
  includes a misspelled property: telling the two apart would reveal that a
  hidden row carries the property. Unscoped sessions with no policy keep the
  `UnknownProperty` diagnostic.
  Regressions: `zig build test-sonny6338-tenant-visibility-consistency`,
  `zig build test-sonny2692-knn-rls`.

### Added

- **The ISO FILTER statement after `CALL ... YIELD` (SONNY-6460 item 2).**
  `FILTER [WHERE] <condition>` (ISO/IEC 39075:2024 14.6) now follows
  `CALL ... [YIELD ...]` and `MATCH ... CALL ... YIELD ...`, and any number
  of FILTER statements may follow one another (after a MATCH only one was
  accepted). A row is kept only when the condition is True; False and NULL
  drop it. After a CALL the condition reads the yielded columns by their
  YIELD names; after `MATCH ... CALL` also the MATCH variables. The 42000
  refusal of a WHERE after YIELD now points at `FILTER [WHERE]` instead of
  saying Geode does not accept it. See `docs/GQL_COMPLIANCE.md` (FILTER
  Statement). Regression: `zig build test-sonny6460-filter-statement`.
- **CANARY Governance Tokens:** 24 CANARY markers added across timeseries source files (GAP-0281)
- **Legacy GAP ID Mapping:** Documented mapping from Grey Cardinal GAP-004/005/006 to GAP-0279+ numbering (GAP-0288)
- **Time-Series Audit Report:** `docs/TIMESERIES_AUDIT_REPORT.md` tracking all timeseries gap status

### Fixed

- **Fulltext indexes are kept current by every write path, after a restart
  too (SONNY-6591).** Two write paths skipped the fulltext maintenance
  hook. (1) Over QUIC, a single-statement `CREATE (n:L {k: v})` with no
  RETURN is served by the default write fast path
  (`executeBulkSimpleCreate`), which wrote the node through the storage
  adapter and indexed nothing: the node was not found by
  `geode.fts.search` / `phrase` until a later REMOVE, ROLLBACK or
  `geode.fts.rebuild` rebuilt the index. (2) The label -> fulltext index
  registry that every maintenance hook reads lived in memory and was filled
  only by CREATE INDEX and `geode.fts.rebuild`, so after any restart (clean
  or crash) no write reached the index on either transport. CREATE, SET and
  MERGE (executor, fast path, `/*+BATCH*/`) appended nothing, a DELETE left
  the node's postings, and a REMOVE or a SET replacing indexed text queued
  no rebuild, so the removed text stayed findable. Search kept answering
  the pre-restart contents, because the engine re-opens on the first
  search. The fast path now runs the hook on the connection thread before
  it answers, as the bulk MERGE paths do. The first maintenance hook on a
  graph after it is opened now fills the registry from the catalog's
  fulltext rows and opens their engines
  (`fts_index_ops.armLabelRegistry`; once per graph, one atomic load
  afterwards). TDE played no part. Regression:
  `zig build test-sonny6591-fts-write-paths` (a real server, QUIC and
  gRPC, with and without TDE: every write path looked up right after its
  write and after SIGKILL and SIGTERM restarts; 264 of 592 cells failed
  before).

- **A cluster node's vote is on disk before its grant can leave the node
  (SONNY-6563).** The raft library (v0.1.22) hands a RequestVote grant to
  its transport from inside `step()` and writes the hard state (term,
  voted_for; fsync) only in `advance()`, which `RaftNode.drainReady` calls
  after `step()` returns. Geode's bridge queued the grant on the peer's
  outbox at once and the outbox thread sends without the raft mutex, so a
  node could tell a candidate "granted", crash before the fsync, restart
  with no vote for that term and grant it to another candidate: two
  leaders in one term. The bridge now holds everything the library sends
  during `step` / `tick` / `propose` until `advance()` has succeeded, then
  queues it; if `ready()` or `advance()` fails the held messages are
  dropped (raft resends). Leader AppendEntries now leave after the
  leader's own append is durable (one fsync later than before). The vote
  already survived a clean restart (the library stores term and vote
  together); `test-raft-hardstate-durability` now asserts it and that the
  restarted node refuses a second candidate in the same term. Regression:
  `zig build test-sonny6563-vote-persist-before-send` (the grant reached
  the network while the disk held term 0, voted_for null).

- **CDC_DIAGNOSTICS and CDC_CONTROL answer the same on QUIC and gRPC
  (SONNY-6561).** The QUIC handler read `ServerState.cdc_engine`, which
  nothing assigned, so with CDC started by `CALL cdc.enable()` QUIC
  answered `NO_ENGINE` to every CDC_CONTROL action and reported CDC
  disabled, while gRPC read the running engine. Both transports now answer
  through one implementation (`storage_dispatch.cdcDiagnosticsAnswer` /
  `cdcControlAnswer`) and the field is deleted. **Changed refusals (both
  frames, both transports):** an unauthenticated caller is refused `28000`
  and a caller that is not an administrator `42501` (QUIC: an error frame;
  gRPC: grpc-status 16 / 7 with a grpc-message starting with the SQLSTATE).
  QUIC refused a non-admin's diagnostics `42000` (the 18 other privilege
  refusals answer `42501`) and answered its CDC_CONTROL `PERMISSION_DENIED`;
  gRPC answered a non-admin's or an unauthenticated caller's diagnostics
  with an empty "CDC disabled" payload and its CDC_CONTROL
  `AUTH_REQUIRED`. In cluster mode CDC_CONTROL is refused
  (`CLUSTER_NOT_LEADER` / `CLUSTER_WRITE_NOT_REPLICABLE`) as `CALL
  cdc.reset_guardrails()` is. `GEODE_CDC_ENABLE=1`, which
  docs/QUICK_REFERENCE.md documents and nothing read, starts the engine at
  startup through the path `CALL cdc.enable()` takes; the engine lives in
  the process allocator and `CALL cdc.disable()` now frees it
  (`CDCEngine.deinit`). Regression: `zig build
  test-sonny6561-cdc-transport-parity` (0 of 86 QUIC/gRPC answers differ;
  40 did) and `test-sonny6548-quic-cdc-control` (now in the aggregate).
- **The geode CLI refuses what it does not support (SONNY-6560).**
  **BREAKING: exit 2 (usage error) where these used to exit 0.** An option
  a command does not read, a value option given last without its value,
  and a stray argument are refused with exit 2 and a message naming them,
  before anything runs, by every command (`geode query`, `user`, `role`,
  `policy`, `grant`, `revoke`, `auth`, `login`, `logout`, `fle`, `apikey`,
  `session`, `authn`, `tenant`, `audit`, `completion`, `mcp`, `migrate`,
  `backup list|info`, and the global `--audit-file` / `--audit-syslog`;
  `serve`, `shell`, `lsp`, `storage`, `backup create|cleanup` and `restore`
  already did, and `mtls` refuses every subcommand as unsupported). They were skipped, so a misspelt option ran
  the command on its defaults. `geode query --format` takes json, table,
  csv, dot or mermaid and refuses anything else (`--format txt` printed
  nothing and exited 0; the renderer's fall-through is now an error).
  `--format dot` and `mermaid` draw paths and lists of nodes and
  relationships, print an error result's message on stderr (exit 1) and an
  EXPLAIN/PROFILE plan, note on stderr how many values were not graph
  elements, and escape `"` and `\` in DOT strings; they printed an empty
  graph for all of those and wrote a name holding `"` into DOT unescaped.
  Documented options nothing read are gone from the help and refused:
  `geode query --begin`, `--commit` and `--rollback` (`--begin --rollback`
  committed the write; an explicit transaction is `BEGIN` / ... / `COMMIT`
  or `ROLLBACK` lines of `geode query --batch`, on one connection), the
  global `--config`, `--json` and `-v`/`--verbose`, `geode role create
  --permissions` and `geode auth logout --token`. `geode audit verify
  --algo` refuses an algorithm other than sha256 and blake3 (it verified
  with sha256); `geode mcp --port` refuses a value that is not a port (it
  used to listen on 8080), and `geode mcp --help` documents `--token` and
  `--no-auth` and says HTTP is the default transport. The shell completion
  scripts no longer offer `-s`/`-f` for `geode query` (`-f` is `--file`).
  Regressions: `zig build test-sonny6560-cli-unsupported-options`,
  `zig build test-sonny6548-cli-query-options` (now in the aggregate).

- **MCP backend tools and resources work against a real server
  (SONNY-6559 items 5, 6, 10).** **BREAKING for MCP clients:** the
  `catalogs` tool is gone (it sent `SHOW CATALOGS`, which geode does not
  parse; geode has no catalog object, so `{catalog}` in a resource URI is
  always `default`). The backend tools and resources decode results with
  geode's own wire schema, as `geode query` does: the `schema` tool's label
  lists and the `query` tool's nodes, relationships, paths and lists were
  `null`, and `explain` answered `{"columns":[],"rows":[]}`; it now returns
  the plan `geode query "EXPLAIN ..." --format json` prints. The advertised
  `geode://{catalog}/{graph}/node/{label}` and `/relationship/{type}`
  templates read (a count and up to 25 elements) and `{graph}` is honoured
  by the schema and stats templates (it was ignored); every read goes
  through the normal client path, so the endpoint user's permissions and
  row-level security apply. A resource URI is parsed exactly
  (docs/MCP_SERVER.md, "Resources and the backend tools"); any other URI,
  and a graph that does not exist, is `-32002` (any path holding `config`
  or `/schema` used to match). Regression: `zig build
  test-sonny6559-mcp-backend`.

- **CLI commands return through `main`; the audit configuration is freed;
  `geode completion` writes to stdout (SONNY-6559 items 7, 8, 11).**
  `geode completion` wrote the script to stderr, so `geode completion
  --shell bash > file` wrote nothing; a shell named as an argument
  (`geode completion zsh`) was ignored and the bash script printed. `audit`, `login`, `logout`,
  `session`, `authn`, `mtls` and `tenant` ended with `std.process.exit(0)`
  before `main`'s Debug leak check and before the audit logger was closed;
  they return (exit 0, as before) and the CLI audit log now records each
  command's success (`"outcome":"success"`) when it returns. The audit
  configuration's strings (`GEODE_AUDIT_*`, `--audit-file`,
  `--audit-syslog`, `--audit-eventlog`) were duplicated and never freed (a
  flag after its environment variable leaked both); `--audit-eventlog`
  followed by a subcommand no longer takes the subcommand as the event
  source. Regression: `zig build test-sonny6559-cli-exit-paths`.

- **The parser applies ISO/IEC 39075:2024 21.3's identifier rule the right
  way round, and takes 16.11 edge quantifiers (SONNY-6564, BREAKING: queries
  using reserved words as names).** 21.3 SR 18: an unquoted identifier whose
  case-normal form is a reserved word is not one; a non-reserved word is; a
  delimited identifier may be any word. The parser accepted reserved words
  as variables (`MATCH (match:X) RETURN match` ran, `RETURN MATCH` parsed)
  while SET, REMOVE, DELETE, FOR, UNWIND and LET took only plain
  identifiers, so `MATCH (type:T) SET type.x = 1` (TYPE is non-reserved) was
  a syntax error. Now one predicate decides every name that binds or is
  referenced (variables, aliases, YIELD items, parameters and session
  parameters, VALUES columns, CTE names, comprehension variables): a 21.3
  non-reserved word or any word 21.3 does not list names it; a reserved word
  is 42000 naming its delimited form; `` `match` `` (accent-quoted, newly
  lexed) names anything. The two lists, verified word for word against the
  standard, are in src/gql/identifier_words.zig. **BREAKING:** an unquoted
  reserved word as a variable, alias or parameter (`RETURN sum(x) AS sum`,
  `WITH [1] AS list`, `$limit`, `$from`, `AS year`, `AS data`, ...) is now
  42000; write it delimited (`` AS `sum` ``, `` $`limit` ``). Decided with
  evidence (docs/GQL_COMPLIANCE.md "Reserved Words and Identifiers"): of
  14,410 queries in Geode's tests, docs and examples and the integration
  specs, strict 21.3 refused 260; five reserved words stay names, a
  documented non-conformance, because Geode's own procedures yield columns so
  named (PATH from `algo.*`, VALUE and AVG from `geode.ts.*`, COUNT and
  TIMESTAMP from RLS and storage procedures) and they are 123 of the 260;
  labels, relationship types and property names and keys still take any
  word. 141 queries are refused: 44 of Geode's own (35 test query
  literals in 20 files, corrected here with delimited names; 8 doc examples
  whose `$query` became `$query_vector`, with their source in
  src/gql/language_metadata.zig; the rest expect the refusal or are not
  queries) and 97 in 39 integration-harness specs. `RETURN no` returns a variable `no` (NO
  BINDINGS needs both words). 16.11: `-[:R]->{1,2}`, `{2}`, `{1,}`, `{,3}`,
  `+` and `*` (on full and abbreviated edges) read into the bounds
  `-[:R*m..n]->` sets and run on the same expansion; SR 3 bounds (`{0}`,
  `{3,1}`) and a second quantifier are 42000. docs/GQL_COMPLIANCE.md claimed
  "full quantifier support" with only the Cypher form; it now lists both
  and that quantified parenthesized paths (G035) are unsupported.
  Regressions: `zig build test-sonny6564-identifier-words` (every reserved
  and non-reserved word, every binding position; executed over QUIC and gRPC
  with the ISO quantifier results compared to `*m..n`),
  `test-sonny6548-gql-identifier-words` (now in the aggregate),
  `test-iso-conformance` (120/120, 11 new 21.3 and 16.11 cases).
- **Wire result metadata describes the result it is sent with (SONNY-6562,
  BREAKING: declared column types change).** Over QUIC and gRPC:
  (1) A decimal (`RETURN 1.25`, any fixed-point value) is declared `DECIMAL`,
  ISO/IEC 39075:2024 21.2's exact numeric type; it was `FLOAT`, the name of
  an approximate type. `type()` and `valueType()` answer `DECIMAL` for it
  too. (2) A column's declared type is the combination of the types of all
  its values (14.2, 22.18 / 22.19): exact numerics combine to the wider one
  (`DECIMAL` over the integer types), an approximate value makes the column
  `DOUBLE` (`REAL` only when every value is), character strings `STRING`, a
  zoned and a local datetime or time the zoned type, and values of different
  base types `ANY` (18.9's open dynamic union type); NULL adds nothing. It was
  the type of the first non-null value among the first 10 rows, so
  `RETURN 2 AS a UNION RETURN 1.25 AS a` declared `INTEGER` for a column
  holding 1.25, and an ORDER BY, a CASE, an OPTIONAL MATCH or an eleventh row
  could contradict a declared type. The node-scan stream (`MATCH (n:L)
  RETURN n.p` served without the executor) sends its schema frame after 10
  rows: when those are all its rows it declares their combined type, as the
  executor would; when more rows follow it declares each property column
  `ANY` (a bare node column stays `NODE`), since it has not read them (it
  declared the sample's type). Clients that switch on a declared type must
  accept `DECIMAL` and `ANY`; the value kinds on the wire are unchanged.
  (3) `ordered` / `order_keys` are set exactly when the statement that
  returns the rows ends in an ORDER BY (14.10; a UNION's trailing ORDER BY,
  14.2): `FOR a IN [2, 1, 3] RETURN a ORDER BY a DESC`, a FOR whose body
  reads, a chain whose last part orders (`MATCH ... WITH n MATCH ... RETURN
  ... ORDER BY k`) and `CALL p() YIELD x RETURN x ORDER BY x` reported
  `ordered:false`, and a WITH's ORDER BY ahead of an unordered RETURN (`WITH
  3 AS x ORDER BY x WITH x RETURN x`) reported `ordered:true`. One function,
  `query_traits.resultOrderBy`, now decides both the flag and the keys on
  both transports. (4) PROFILE reports no spill: the executor never spills a
  sort, DISTINCT, UNION or GROUP BY, but a version-1 PROFILE under
  `GEODE_SPILL_THRESHOLD_BYTES` (or `GEODE_QUERY_MEM_LIMIT_BYTES`) set
  `spill_reason:"threshold"` and a spill counter of 1 because its synthetic
  peak passed the threshold. The variables no longer change any output
  (docs/kb/PROFILING.md, docs/DOCKER_OVERVIEW.md);
  tests/e2e_protocol_profile_spill_first_index.zig, which no step ran and
  which pinned the made-up spill, is removed. docs/BINARY_PROTOCOL.md
  now describes the SCHEMA types, the ordering flag and the version-1 and
  version-2 PROFILE payloads geode sends. Regressions: `zig build
  test-sonny6562-wire-metadata` (5 tests, a real server over both
  transports, the protobuf value kinds checked against each declared type),
  `test-sonny6548-wire-result-metadata` (now in the aggregate),
  `test-sonny1221-fast-path-schema` (a stream longer than its sample declares
  `ANY`).
- **An ORDER BY on a column the ordered index cannot serve no longer starts
  its build (SONNY-6555 item 3, SONNY-6518 item 6).** `orderedScanFastPath`
  started the value-ordered index's background build (and its persisting
  checkpoint) for a `(label, key)` before anything knew the column's class,
  then declined that index forever when the column mixed order classes
  (INTEGER, DOUBLE, STRING), held a string that is not its own NFC form, or
  a value of no ordered class (SONNY-6499). The new
  `StorageAdapter.probeOrderedColumnClass` reads the column's values first
  (stopping at the first one that breaks it) and such a column is declined
  before the build starts. A single-class canonical column still builds; the
  probe reads the label's values once on the query path before that build
  (the heap fallback serving the same query reads them too). Regression:
  `zig build test-sonny6555-ordered-build-probe`.
- **The statements after a FOR read its whole table, and a chain's last
  RETURN DISTINCT reads every row (SONNY-6555 item 7, BREAKING: results
  change).** ISO/IEC 39075:2024 14.8: a FOR extends the working table, a
  record per element of each incoming record's list, and the statements
  after it read that table as a whole (14.3, 14.11, 14.9). A FOR whose body
  reads ran the body once per element (`statement_handlers.executeForBody`),
  so `FOR x IN [1, 1, 2] MATCH (z) WHERE z.k = x RETURN count(*)` gave one
  count per element and the body's WITH DISTINCT, WITH ... ORDER BY ...
  LIMIT, RETURN DISTINCT and RETURN ... ORDER BY ... LIMIT each read one
  element's rows; after a part (`MATCH (z) WITH z FOR x IN z.l MATCH ...`)
  the chain ran the FOR part per row binding nothing and returned one empty
  row per row. Such a body now runs as the rest of a chain whose part before
  it is the FOR's table (`query_execution.runReadForBody`, through
  `continueChain`, the SONNY-6540 stage logic). A body that writes still
  runs once per element (geode#876). Also: a chain's last RETURN DISTINCT
  after a part run per row (`MATCH (z) WITH z MATCH (z)-->(y) RETURN
  DISTINCT z.g`) was applied to each row's rows alone; it now reads every
  row, before the ORDER BY and window. A CALL subquery reaches no later
  stage (`CALL { } WITH` does not parse; `CALL { } MATCH ... WITH` is
  0A000). `test-sonny2683-return-shapes` pinned the per-element grouping
  (`FOR x IN [1, 2] MATCH (n:G) RETURN n.g, count(*) ... HAVING c > 7` as
  a|10, a|10, b|10, b|10); it now expects a|20, b|20, c|10, the tenant-scoped
  session included (the FOR statement makes its context the active one, as
  `executeQueryWithContext` does, so the per-row parts read its tenant
  scope). Regression: `zig build test-sonny6555-for-chain-stage`.
- **A function called with the wrong number of arguments is 42000 (SONNY-6555
  item 5, BREAKING: GQLSTATE changes).** ISO/IEC 39075:2024 4.7.3 step 4: a
  source that matches no production, or violates a Syntax Rule, fails with
  "syntax error or access rule violation" (42000); an operand count is
  decided by the program text, as SONNY-6540 item 9 pinned for `abs(1,
  2)`. The parser checks only a few functions, and the rest answered as
  their handler happened to: 22023 (`sqrt()`, `upper('a', 'b')`,
  `ipaddr()`, `toFloat()`, `datetime('a', 'b')`), NULL (`tail()`, `head([1],
  2)`, `url_host('a', 'b')`, `smallint(1, 2)`, `range(1)`) or 42883 "unknown
  function" (`nullif(1)`, `properties()`, `date(1, 2)`, `startsWith('a')`).
  Every arity refusal of the function dispatch (built-ins, timeseries
  functions, the extension registry) is now the new `WrongArgumentCount`,
  mapped to 42000 on QUIC and gRPC, and a function Geode lists (SHOW
  FUNCTIONS) that no handler took is that too, not 42883; it fails the
  statement in a grouped projection as well. `InvalidArgs` (22023) is left
  for an argument value a function refuses and for procedures (`CALL`),
  whose arity is unchanged. The check stays in the dispatch, which owns
  the function catalogue the parser does not (extension registry,
  timeseries flag): a call no row reaches is not refused. Regression: `zig
  build test-sonny6555-function-arity`.
- **A WITH takes SKIP / OFFSET before LIMIT (SONNY-6555 item 6).** ISO/IEC
  39075:2024 14.9 `<order by and page statement>` puts the offset clause
  (`OFFSET` or `SKIP`, 16.19) before the limit clause (16.18). A RETURN
  accepted `ORDER BY s SKIP 1 LIMIT 2`, but a WITH, a leading WITH, a
  UNION's trailing page and a FOR's RETURN refused it with 42000: each read
  LIMIT, then OFFSET, and nothing after. Every page clause now goes through
  one parser routine that takes the standard order. `LIMIT n OFFSET m` is
  kept as a documented Geode extension (the same page; docs/GQL_COMPLIANCE.md
  now shows the standard order); a repeated LIMIT or OFFSET is 42000. The
  ISO conformance case named "17.4: OFFSET" was written in the extension
  order; it now reads the standard order and the extension has its own
  case. Regression: `zig build test-sonny6555-page-clause-order`,
  `zig build test-iso-conformance`.
- **`length(NULL)` and `size(NULL)` are NULL, and a string's length counts
  characters (SONNY-6555 item 4, BREAKING: results change).** ISO/IEC
  39075:2024 20.22 GR 1 b), 3 b) and 4 e): the length or cardinality of the
  null value is the null value; GR 1 a) with NOTE 331: a character string's
  length is its number of characters. `length(NULL)`, `size(NULL)` and
  `size(n.missing)` answered 0, `length('héllo')` 6 (bytes), and
  `length(1)` / `size(true)` 0; they now answer NULL, 5 and 22G03. A sweep
  of every function the dispatch knows, called with NULL arguments, found
  the same defect in `tail(NULL)` (`[]`; a non-list is now 22G03 too),
  `indegree(NULL)` / `outdegree(NULL)` (0), `xml_is_well_formed(NULL)`
  (false), and every extension-registry function (`ipaddr`, `st_x`,
  `currency`, `hash`, `latlon`, ...) and the `url_*`, `domain_*`,
  `uuid_equal`, `to_hex`, `from_hex`, `array_*`, `bit_*`, `range_contains` /
  `range_overlaps`, `jsonb_get` / `jsonb_exists` functions, which raised
  22G03 for a NULL argument: each now answers NULL. Regression: `zig build
  test-sonny6555-null-arguments`.
- **Startup refuses to run with part of its auth state; per-graph grants
  load under the right graph (SONNY-6567 item 5).** **BREAKING (operator):**
  a server whose stored custom roles, per-graph grants, FLE role grants, GPS
  policies, or tenant hierarchy / quotas cannot all be loaded at startup now
  refuses to start (it logged a warning and ran with part of them: a missing
  grant or role changed authorization outcomes, and a deny policy not loaded
  hid nothing). `auth_dispatch.hydrateCustomRolesFromGraph` returns its
  error; the grant and FLE grant loads moved into the named module
  `auth_startup_hydration`. Found on the way: the startup grant load
  captured each stored grant BY VALUE and kept `getGraphName()`, a slice of
  that per-iteration stack copy, so a grant could be loaded under another
  graph's name after a restart. Regression: `zig build
  test-sonny6567-auth-hydration`.

- **Raft apply: no hydration persist under the Raft mutex, a follower
  hydrates before it steps, and a refused replicated drop halts the apply
  (SONNY-6567 item 6).** A statement batch whose entry wrote a graph not
  hydrated yet hydrated it WITH its completion persist under
  `inner_mutex`; with a reader holding that graph's lock the apply took
  3.2 s (now 0.2 s): every hydration on a thread applying an entry skips
  the persist (`GraphStore.enterReplicatedApply`). A follower now hydrates
  the graphs of an AppendEntries' entries on its receiving thread before
  `handleMessage` takes `inner_mutex` (measured: the scan of a 20,000-node
  graph held `inner_mutex` 0.23 s, linear in graph size). Log replay at
  restart still scans under `inner_mutex` (bounded by the scan; the node is
  not serving yet). A replicated DROP GRAPH refused on a node because a
  session transaction changed the graph now **halts that node's apply**
  (`raft_apply.applyHalted`, every later entry `ReplicatedApplyHalted`,
  an operator error to restart it) instead of going on without the drop;
  unreachable today (nothing proposes `schema_change`). Regression: `zig
  build test-sonny6567-raft-apply-hydration`, `test-sonny6547-single-voter-drop`.

- **A node or edge body that cannot be read is an error, not "absent"; read
  snapshots list evicted edges (SONNY-6567 item 2).** The hydrated getters
  turned a failed rebuild of an evicted body (out of memory, an engine read
  error) into null, the value that means "no such row", and their callers
  skipped it: `CALL db.propertyKeys()` / `db.relationshipTypes()` answered
  short lists, and an unreadable edge endpoint was taken for a hidden one.
  New checked getters (`getNodePtrHydratedChecked`,
  `getEdgePtrHydratedChecked`, `getEdgeHydratedChecked`) return the error;
  `db.*`, the security-graph loaders and listings (`user_storage`), the
  role resolver (an unreadable `HAS_ROLE` edge now resolves to no global
  role instead of possibly an older, higher one), edge property writes (FLE
  tenant identity) and the statement undo record use them and fail the
  statement. Found on the way: rebuilding an evicted node or edge read a
  tenant tag that could not be read as the `default` tenant's (fail open
  across tenants; now an error); `hydrateEdgeCb` freed the label, graph name
  and tenant twice on any error after the edge was built (heap corruption)
  and leaked a property on failure; a key removed from a bounded cache and
  inserted again left a stale FIFO entry that could evict the live key
  during its own insert, so an existing body read as absent; and a read
  snapshot (`QueryReadSession`, which serves top-level CALLs and server
  reads) copied only the RESIDENT edges of a bounded edge cache (the
  default, 1,000,000 entries), so every evicted edge was missing from its
  answers with nothing failing at all. Regressions: `zig build
  test-sonny6567-hydrated-getter-errors`, `test-bounded-node-cache`.

- **A fulltext hit whose node cannot be read fails the search (SONNY-6567
  item 3).** `geode.fts.search` / `phrase` / `proximity` skipped such a hit
  as if the node were gone and reported the shorter result as complete. A
  node deleted since indexing is still skipped and another tenant's node
  still filtered. Regression: `zig build test-sonny6567-fts-unreadable-hit`.

- **A tenant DROP that fails part-way fails, and can be retried (SONNY-6567
  item 4).** **BREAKING:** `geode.tenant.drop` is refused inside an explicit
  transaction (`TenantDropInTransaction`), and `geode.tenant.create` under a
  tenant being dropped is refused (`TenantDropping`). A cascade drop now
  marks the tenant (`active = false`, on disk) before removing anything,
  and every failure fails it: the registry's own write of its file (logged
  while the drop, and also `create` and `set_quota`, reported success; the
  tenant came back at the next restart), the hierarchy removal (logged, or
  `catch {}` for a child) and a child's registry lookup (`catch null`). The
  drop no longer takes part in the statement's undo: a failed drop rolled a
  child's rows back after the child had left the registry, orphaning them.
  Regression: `zig build test-sonny6567-tenant-drop-failures` (registry and
  statement allocation-failure sweeps, each followed by a restart and a
  retry). See docs/security/MULTI_TENANT_HARDENING.md.

- **gRPC client: every RPC on a connection gets its own HTTP/2 stream, and
  a pushed result is never cut short silently (SONNY-6567 item 1).** The
  client transport (`src/client/grpc_query_transport.zig`) sent every
  Execute on stream 3, so a second Execute on one connection reused a
  closed stream (RFC 9113 §5.1.1) and failed with `IncompleteResponse`; the
  library's `StreamingQueryAdapter` and the test client now take odd,
  increasing ids from a per-connection `StreamIds` (which refuses to wrap:
  `StreamIdsExhausted`, open a new connection), and a response is read only
  from its own stream. The CLI opens a connection per Execute and keeps
  using stream 3. Two defects the large-response check found: the client
  raised the per-stream receive window (SETTINGS) but never the
  connection window, which stays 65,535 octets until a WINDOW_UPDATE on
  stream 0, and the gRPC server cannot read WINDOW_UPDATEs while it pushes
  a result (SONNY-1560), so a result over 64 KiB was refused after its
  first pages; the client now raises the connection window to 16 MiB at
  connect. And `collectQueryWithTransport` took a pushed result whose
  stream ended before its final page for a complete one: `geode query
  --grpc` printed 384 of 4,000 rows and exited 0. It now fails with
  `IncompleteResponse` (the CLI's "the server closed the connection before
  the query completed", exit 1). Regression: `zig build
  test-sonny6567-grpc-stream-ids` (a real server: eight Execute RPCs, a
  4,000-row and a 90,000-row response and one more Execute on one
  connection; a multi-statement `--file` over gRPC).
- **A cluster node's vote is on disk before its grant can leave the node
  (SONNY-6563).** The raft library (v0.1.22) hands a RequestVote grant to
  its transport from inside `step()` and writes the hard state (term,
  voted_for; fsync) only in `advance()`, which `RaftNode.drainReady` calls
  after `step()` returns. Geode's bridge queued the grant on the peer's
  outbox at once and the outbox thread sends without the raft mutex, so a
  node could tell a candidate "granted", crash before the fsync, restart
  with no vote for that term and grant it to another candidate: two
  leaders in one term. The bridge now holds everything the library sends
  during `step` / `tick` / `propose` until `advance()` has succeeded, then
  queues it; if `ready()` or `advance()` fails the held messages are
  dropped (raft resends). Leader AppendEntries now leave after the
  leader's own append is durable (one fsync later than before). The vote
  already survived a clean restart (the library stores term and vote
  together); `test-raft-hardstate-durability` now asserts it and that the
  restarted node refuses a second candidate in the same term. Regression:
  `zig build test-sonny6563-vote-persist-before-send` (the grant reached
  the network while the disk held term 0, voted_for null).

- **CDC_DIAGNOSTICS and CDC_CONTROL answer the same on QUIC and gRPC
  (SONNY-6561).** The QUIC handler read `ServerState.cdc_engine`, which
  nothing assigned, so with CDC started by `CALL cdc.enable()` QUIC
  answered `NO_ENGINE` to every CDC_CONTROL action and reported CDC
  disabled, while gRPC read the running engine. Both transports now answer
  through one implementation (`storage_dispatch.cdcDiagnosticsAnswer` /
  `cdcControlAnswer`) and the field is deleted. **Changed refusals (both
  frames, both transports):** an unauthenticated caller is refused `28000`
  and a caller that is not an administrator `42501` (QUIC: an error frame;
  gRPC: grpc-status 16 / 7 with a grpc-message starting with the SQLSTATE).
  QUIC refused a non-admin's diagnostics `42000` (the 18 other privilege
  refusals answer `42501`) and answered its CDC_CONTROL `PERMISSION_DENIED`;
  gRPC answered a non-admin's or an unauthenticated caller's diagnostics
  with an empty "CDC disabled" payload and its CDC_CONTROL
  `AUTH_REQUIRED`. In cluster mode CDC_CONTROL is refused
  (`CLUSTER_NOT_LEADER` / `CLUSTER_WRITE_NOT_REPLICABLE`) as `CALL
  cdc.reset_guardrails()` is. `GEODE_CDC_ENABLE=1`, which
  docs/QUICK_REFERENCE.md documents and nothing read, starts the engine at
  startup through the path `CALL cdc.enable()` takes; the engine lives in
  the process allocator and `CALL cdc.disable()` now frees it
  (`CDCEngine.deinit`). Regression: `zig build
  test-sonny6561-cdc-transport-parity` (0 of 86 QUIC/gRPC answers differ;
  40 did) and `test-sonny6548-quic-cdc-control` (now in the aggregate).

- **`test-admin-bootstrap` is green again (SONNY-6551 item 6).** Its 14
  tests passed, but the one that replaces the security graph's engine
  directory with a file on purpose (`bootstrapDefaultAdmin fails CLOSED when
  the registered security graph cannot be opened`) made
  `StorageAdapter.openGraphLocked` log `failed to open ShardedGraphEngine`
  through `std.log.err` four times, and the Zig test runner fails a test
  that logs at `err`. The error is real and expected there (the caller fails
  closed on it); it now goes through geode's structured logger at ERROR
  (`geode.storage`, `graph=`, `error=`), as this file's other
  operator-facing errors do (GAP-ENT-0038), so operators still see it and
  the test no longer counts it as a failure.

- **`geode mcp` answers the MCP 2025-11-25 result objects and error codes,
  one message per line (SONNY-6552).** **BREAKING for MCP clients** that
  read the old shapes: `resources/list`, `resources/templates/list` and
  `prompts/list` returned bare, pretty-printed arrays instead of
  `{"resources":[...]}`, `{"resourceTemplates":[...]}` and
  `{"prompts":[...]}`; `resources/read` returned a bare
  `{uri,mimeType,text}` instead of `{"contents":[...]}`; an unknown prompt
  or resource URI was a success carrying `{"error": ...}` and is now a
  JSON-RPC error (`-32602` / `-32002`); an unknown tool was `-32603`
  InternalError and is now `-32602`, the spec's protocol error. The
  pretty-printed results spanned many lines, so on the newline-delimited
  stdio transport a client reading one message per line could not decode
  them; every result is now serialized on one line. A list `cursor` is
  `-32602` (each list is one page; geode never issues one). `prompts/get`
  refuses (`-32602`) a missing required argument, an argument the prompt
  does not take and a non-string value, and writes the argument values into
  the prompt text (they were ignored). The `query` tool no longer
  advertises `catalog` / `graph` and the `graphs` tool no longer advertises
  `catalog` (all were ignored; the `graphs` tool parsed `catalog` into
  memory its own block-scoped `defer` freed at once); passing them is now
  an `isError` tool result. `query` with `parameters` failed every call
  (`"{any}"` printed the formatter, not JSON) and now sends them; a
  statement the server reports as failed is `isError: true` for `schema`,
  `explain`, `catalogs` and `graphs` too, not only `query`. `geode mcp`
  and `geode completion` return through `main` instead of
  `std.process.exit` (exit code unchanged), so a Debug build reports their
  leaks. See [MCP_SERVER.md](MCP_SERVER.md#result-shapes-and-error-codes-sonny-6552).
  Regression (field by field against the schema, through
  `mcp.Server.processMessage` and a real `geode mcp --stdio` session):
  `zig build test-sonny6552-mcp-result-shapes`; `test-sonny6531-mcp-ownership`
  and `test-gap0875` updated to the new codes.
- **A failed transport-parity run fails its smoke (SONNY-6548 item 4).**
  Four `test-transport-parity` smokes (order metadata, US001, illegal order
  key, varlen dataset rows) caught a failed parity run, a port allocation
  or a server that never became ready, printed a skip mark and returned, so
  the step passed; they now return the error. The CASE 3VL smoke bound `a`
  with the deleted client's array `--param` expansion, compared two equal
  error outputs, and passed until a failed query exited 1 (SONNY-6369); it
  now uses `FOR a IN [null, true, false]` and checks the three rows.
  `test-cluster-3node-subprocess` and `test-datadir-lock-subprocess` spawn
  the geode this build emitted, so a missing binary now fails them instead
  of skipping with "run `zig build` first to populate zig-out/bin".
  `benchmarks/benchmark_rls_abac_variance.zig`, which no step built, timed a
  placeholder policy mock (`tests/canary_rls_abac.zig`), not geode's
  RLS/ABAC; both are removed and BENCHMARK_REPORT.md no longer cites it.
- **The 67 allowlisted test files that compiled but failed are triaged
  (SONNY-6548 item 1).** 21 had a stale expectation (behaviour that changed
  on purpose: `Catalog.addGraph` no longer persists, a PATH renders as
  `{"nodes","edges"}`, a DECIMAL as a JSON string, ExecutionGuardTrip is a
  flagger finding, the variance thresholds were raised, a read takes the
  version-2 PROFILE) or a test defect (a dataset nothing seeds, a data dir
  in the checkout, a duplicate check keyed on the first edge only, a BEGIN
  after COMMIT expected to fail, a BEGIN before HELLO, op counts that also
  counted `peak_contributors`); they are corrected and run in
  `zig build test-sonny6542-revived`. 46 are removed: written for the
  deleted client's options (`--begin`/`--commit`, `--utf16-input`,
  `--dist-enable-*`, `--no-estimates`, `--profile-memcurve`, array
  `--param` expansion), for US001 (never emitted; docs/BINARY_PROTOCOL.md),
  for exit 2 on a query error (it is 1, SONNY-6369), for the old
  `"result":{"type":"PROFILE"}` shape and the version-1 synthetic PROFILE
  of a read (the 25-file `e2e_protocol_profile_*` battery), or vacuous
  (`test_gap_0193_*`: ~420 parse-only and `@hasDecl` checks under feature
  CANARY markers; `e2e_hash_functions.zig`: mocked execution). Product bugs
  they exposed are intentionally red reproductions, out of the aggregate
  and listed in docs/KNOWN_TEST_ISSUES.md: `test-sonny6548-cli-query-options`,
  `-quic-cdc-control`, `-wire-result-metadata`,
  `-raft-persistent-voted-for`, `-gql-identifier-words`.

- **Every `tests/*.zig` file is compiled by a build step or listed with the
  reason it is not, and configuration fails otherwise (SONNY-6542).** 564
  test files ran in no step: `tests/all_tests.zig` imported 92 of them as
  unreferenced consts (`const _x = @import("x.zig");`), which Zig never
  analyzes, so only the ten it passed to `refAllDecls` compiled, and 460
  more were referenced by nothing. Their 1,110 CANARY markers (1,035
  `STATUS=TESTED`) counted as tested coverage. `checkTestSourcesReachable`
  in build.zig walks, when `build()` returns, every module of every
  compile step any step reaches, follows the relative `@import`s the
  compiler analyzes (scripts/ci/test_source_reachability.zig, unit-tested
  by `zig build test-sonny6542-test-source-reachability`) and panics on a
  tests/ file it does not reach that scripts/ci/unreachable_test_sources.zig
  does not list. 33 passing files now run in `zig build
  test-sonny6542-revived` (the e2e ones spawn this build's geode through
  `geode_test_bin` instead of `./zig-out/bin/geode`); 142 are removed:
  files that name code or files that no longer exist, debug scratch
  programs, files with no test block, and 19 that import only `std` and
  assert on their own copies of the structures, so no geode code ran; 387
  more are listed, each with a `TODO(SONNY-6542)` reason (does not compile
  under Zig 0.16; fails when run, untriaged; imports `../src/` by relative
  path; see docs/KNOWN_TEST_ISSUES.md). The CANARY markers in listed files,
  and 99 implementation-site markers whose only evidence was a dead test,
  now say `IMPL`. `tests/all_tests.zig` keeps only the
  imports it compiles. 62 `tests/*.sh` scripts that no Makefile target, CI
  job, hook, runbook, live source or kept script runs are removed (26 kept).
  `tests/qualify_backup_ca.py` requires `--binary` instead of defaulting to
  `zig-out/bin/geode`, and `proto_test_util.spawnServerRandom` no longer
  frees the listen address twice when a server misses its startup deadline.
- **A relative or empty HOME no longer panics the CLI or puts its state
  under the working directory (SONNY-6544 item 2).** `geode query` built
  `<HOME>/.geode` for the saved session and passed it to
  `createDirAbsolute`, which asserts an absolute path: `HOME=relhome geode
  query` panicked in a Debug build (a release build would have created
  `relhome/.geode` under the working directory). `auth login
  --save-session`, `auth token`, `session info` / `rotate` and the state
  directory of `session`, `authn`, `apikey` and `mtls` had the same assert,
  and the state directory was created relative to the working directory
  first. One rule now (`src/cli/security/home_dir.zig`): HOME (USERPROFILE
  on Windows when HOME is unset) must be absolute, else the command says
  `HOME is empty or not an absolute path ...` and writes nothing (`geode
  query` warns and runs without a saved session); a relative
  `XDG_STATE_HOME` is ignored, as the XDG Base Directory specification
  requires. Regression (real binary): `zig build
  test-sonny6544-relative-home`.
- **MCP `completion/complete` answers a CompleteResult (SONNY-6544 item
  3).** It answered `"result":[]`; MCP 2025-11-25 (the pinned mcp library's
  protocol) requires `{"completion":{"values":[...],"total"?,"hasMore"?}}`,
  so a client found no `completion` object. Geode still has no argument
  suggestions and now answers
  `{"completion":{"values":[],"total":0,"hasMore":false}}`. Regression
  (through `mcp.Server.processMessage`): `zig build
  test-sonny6544-mcp-completion`.
- **`geode mcp` no longer leaks every `resources/read` response (SONNY-6531
  item 1).** The pinned `mcp` library freed only `tools/call` results, so
  each resource document, and the JSON it stringified for `prompts/get`
  arguments and `completion/complete` params, stayed allocated for the life
  of the server. `mcp` is pinned at v0.1.22, which frees the result of
  every handler callback with the allocator given to `Server.init`; geode's
  handlers (`src/mcp/server.zig`) now all return bytes from that allocator,
  copying the fixed listings, prompts and empty CompleteResult instead of
  returning literals (an invalid free under the new contract). Regression
  (every method through `mcp.Server.processMessage` under
  `std.testing.allocator`, with no backend, an undialable DSN, a dead
  endpoint and a real `geode serve`, plus a real `geode mcp --stdio`
  session): `zig build test-sonny6531-mcp-ownership`; `test-gap0516`,
  `test-sonny6494-mcp-dsn-errors` and `test-sonny6544-mcp-completion` now
  run their resource and completion cases leak-checked.
- **No test step spawns `./zig-out/bin/geode` any more, and configuration
  fails if one does (SONNY-6535).** That path holds whatever the last install
  left (built from another commit or optimize mode, or nothing: the test
  then skipped). 14 named steps (`test-sonny2846-*`, `test-sonny3034-*`,
  `test-sonny3122-*`, `test-sonny3241-*`, `test-sonny6327-*`,
  `test-sonny6334-*`, `test-sonny6341-*`, `test-sonny6345-*`,
  `test-sonny6358-*`, `test-sonny6359-*`, `test-sonny6367-*`,
  `test-sonny6369-*`, `test-sonny6377-security-*`, `test-sonny6384-*`
  offline crash durability) depended on the install step and spawned that
  path; they and 14 files `tests/all_tests.zig` imports now spawn the
  executable this build emits through `spawnsBuiltGeode` and
  `@import("geode_test_bin")` (SONNY-2697). `checkSpawningTestsUseBuiltGeode`
  in build.zig scans, when `build()` returns, every test artifact a step runs
  (its tests/ modules and the tests/ files they `@import`) and panics,
  listing file:line, on code that names the path. Also corrected two comments
  that said a 400-CREATE chunk takes ~38 s in a Debug server with about 13
  fdatasync calls per statement: measured for SONNY-6534 it takes 6-10 s,
  about 2 per statement. Regression: `zig build -l` (configuration).
- **The CLI says what is wrong with a malformed `--server` or `--dsn`, in
  the MCP path's words (SONNY-6531 item 2).** `geode auth login` and
  `geode restore --server` printed `Invalid server address format. Expected
  host:port`, `geode backup create` a bare `InvalidAddress`, `geode shell`
  `REPL error: InvalidAddress` (after starting the REPL), and `geode query`
  its own line that echoed the address, which `--dsn` had cut out of a DSN
  (a password containing `@` could end up in it). They now print `Error:
  <message>` with the message `geode mcp` gives for the same fault (host,
  port, port 0, scheme, IPv6 zone; docs/DSN.md), from one mapping
  (`zig_quic_bridge.endpointErrorMessage`, which `src/mcp/client.zig` now
  re-exports), and never echo the address. `geode shell` checks the address
  before it starts the REPL; `geode migrate run` uses the same message. A
  `--dsn` with any scheme other than `quic://` / `grpc://` (not only
  `http`, `https`, `tcp`) is refused as an unsupported scheme, and a DSN
  without a host gets the host message instead of `DSN missing host`.
  Regression: `zig build test-sonny6531-cli-address-errors`.

- **Go sources are gofmt-formatted, and a pre-commit hook keeps them so
  (SONNY-6544 item 5).** `tools/canaryscan/*.go` was indented with spaces
  and `tests/quic_tests/test_quicgo_interop_regression.go` had a pre-1.19
  doc comment; nothing checked Go formatting. Formatting only (`git diff -w`
  is empty; the scanner built before and after writes a byte-identical
  `status.csv`). The local `gofmt` hook in `.pre-commit-config.yaml` fails a
  commit whose staged `.go` files `gofmt -l` lists.
- **canaryscan writes rows in source order, whatever `--root` is (SONNY-6531
  item 3).** The rows of one requirement in `tools/canaryscan/status.csv`
  and `status.json` were sorted by FEATURE, then ASPECT, STATUS, OWNER,
  UPDATED and file lists, so editing one of those fields moved rows inside
  the requirement, and the file column was the raw walk path, so `--root .`
  and an absolute root wrote different files. Entries are now sorted by
  their first marker's file and line, then the remaining fields; files are
  relative to `--root`; and the report is built from the collected markers
  so the visit order cannot matter. Both files were regenerated once in
  the new order (same rows; only the order changed). `docs/status.csv`
  (`make status-csv`) was already stable: its sort key ends in file and
  line, and two runs are byte-identical. Regression: `cd tools/canaryscan
  && go test ./...` (`order_test.go`).

- **A Raft `drop_graph` apply no longer deadlocks the Raft node with a
  leader request on the graph (SONNY-6541 item 1).** The apply runs under
  the Raft node's `inner_mutex` and drops the graph under its write lock,
  waiting for every holder (SONNY-3350). A statement on the leader holds
  its graph's lock until its writes are proposed and committed, and the
  propose takes `inner_mutex`: with a drop of that graph applying, each
  waited for the other forever, and the node stopped ticking, sending
  heartbeats and applying (forced in the regression: the request's propose
  never returned). The apply now announces its wait on the graph
  (`StorageAdapter.beginReplicatedDrop`); a request that holds the graph's
  lock no longer waits for `inner_mutex` or for a commit while it is
  announced (`RaftNode.lockInnerForRequest`,
  `waitForCommittedThenApplied`): a propose fails with GraphNotFound
  (nothing proposed), a commit wait with Timeout (the entry comes after the
  drop, and its writes to the graph are refused when it applies), and
  SHOW CLUSTER STATUS reads the term and leader unlocked. The request lets
  go of the lock and the drop proceeds. Lock order: a graph's rwlock ->
  `inner_mutex` -> `replicated_apply_mutex`. Nothing in the server proposes
  a `schema_change` today (CREATE and DROP GRAPH are not replicated in
  cluster mode), so no deployment reached this. Regression: `zig build
  test-sonny6541-drop-apply-deadlock`.
- **A checkpoint of a graph waits for a 2PC commit's write to it (SONNY-6541
  item 2).** A committed Raft `txn_decide` applies its prepared write set
  (`TxnCoordinator.handleDecide`) on the Raft apply thread, like a
  replicated graph mutation, but without the graph's
  `replicated_apply_mutex` that SONNY-6528 item 1 gave the mutation apply:
  a full checkpoint ran in the middle of its node create (forced in the
  regression). Each write-set operation now holds its graph's
  `replicated_apply_mutex`, after hydrating the graph outside it. Every
  cluster node registers the coordinator (`ClusterCoordinator.init`); no
  geode code proposes `txn_prepare` / `txn_decide` entries yet. Regression:
  `zig build test-sonny6541-2pc-apply-checkpoint-exclusion`.
- **The first read of a damaged graph fails closed in process too (SONNY-6541
  item 3).** The executor's quarantine gate (SONNY-6528) hydrated a
  program's graphs only for a change; the engine-direct reads (a filtered
  count, an ORDER BY, `max()`) read the pages and never hydrate, so as the
  first statement after a restart on a graph whose node pages were zeroed
  they answered from the zeroed pages (a count, no rows, a null maximum),
  on the default graph and on another one. The gate now hydrates the
  program's graphs for a read as well, so the damage is found and the read
  fails with 58000. Over the wire this was already closed: the QUIC and
  gRPC reads hydrate in their read snapshot (`snapshotUnderReadLock`)
  first. Cost on a healthy store, in process (the regression prints it):
  the gate's per-graph check of a hydrated graph is about 0.25 us (317 ns
  per call before, 569 ns with the hydration check); the first read after a
  restart now hydrates the graph, as a server's first read already did.
  Regression: `zig build test-sonny6541-quarantine-first-read` (in process
  and against a real server).
- **SHOW TABLES fails when its label listing fails (SONNY-6541 item 4).** It
  answered an empty table list instead (`catch &.{}`): forced in the
  regression by failing each of the statement's allocations in turn, four
  of which answered zero rows. A quarantined graph was refused only through
  the store's separate quarantine note. Regression: `zig build
  test-sonny6541-show-tables-errors`.
- **A session whose graph is quarantined can switch to another graph
  (SONNY-6541 item 7).** The QUIC and gRPC handlers' quarantine gate
  (SONNY-6523) checked the session's current graph for every program, so `USE GRAPH
  default`, `SESSION SET GRAPH default` and `SESSION RESET GRAPH` from a
  session on a damaged graph were refused with 58000 and the client had to
  reconnect. A program that touches no graph's data (`programDataGraph` is
  none: session and graph selection, transaction control) is no longer
  checked; `USE GRAPH damaged; MATCH ...` is still refused. The executor's
  own gate (SONNY-6528) already checked only the graphs whose data a
  program touches. Regression: `zig build test-sonny6541-quarantine-use-graph`
  (QUIC against a real server, gRPC and the executor in process).
- **The lazy adjacency hydrate and the full graph load no longer leak a
  node's edge slice when an allocation fails (SONNY-6540 item 3).**
  `GraphStore.hydrateAdjFromEngine` (the adjacency caches' hydrate-on-miss
  hook, on the query path) and `loadOneGraphFromAdapterFull` read a node's
  edges through `StorageAdapter.iterateOutgoingEdges` /
  `iterateIncomingEdges`; graph_storage (0.4.14, and 0.4.15) boxes the
  engine's edge slice in an iterator state and leaks the slice when the box
  cannot be allocated (`interface.zig` `sliceToEdgeIterator`). They now read
  the engine's slice directly (`getOutgoingEdges` / `getIncomingEdges`, as
  SONNY-6498 did for the other callers). The library defect remains for any
  other caller of the type-erased iterators (one geode test). Regression:
  `zig build test-sonny6540-adjacency-hydrate-oom` (every allocation-failure
  point, both directions).
- **A WITH in a later part of a chain that aggregates, is DISTINCT or has a
  SKIP / LIMIT reads every row reaching it (SONNY-6540 item 5, BREAKING:
  results change).** The chain executor (`executeQueryChain`) ran each
  later part once per row of the first part. For the first aggregating WITH
  it found it grouped the first part's rows directly, so a part in between
  (`WITH z WITH z.k * 2 AS k2 WITH sum(k2) AS t`) and the aggregating
  part's own MATCH (`WITH z MATCH (z)-[:R]->(y) WITH z.g AS g, sum(y.v)`)
  were skipped and their variables read NULL, and that part's WHERE after
  the WITH, ORDER BY, SKIP / LIMIT and DISTINCT were ignored; a DISTINCT or
  windowed WITH in a later part was applied to each first-part row's rows
  apart (`... MATCH (z)-->(y) WITH y ORDER BY y.v DESC LIMIT 1` gave one row
  per z). Such a part now runs its whole WITH stage over all of the rows
  reaching it, as the planned read runs one (the WHERE before the WITH, the
  projection and its grouping, DISTINCT, ORDER BY, SKIP and LIMIT, the WHERE
  after it; `match_operations.applyWithStage`, shared with the write
  steps), and the rest of the chain reads its rows; a WITH that starts a
  part before its MATCH is computed first, then the MATCH per row. ISO/IEC
  39075:2024 14.3 / 14.11: a return statement (Geode's WITH) is applied to
  the working table as a whole. Also: a WITH followed directly by another
  WITH kept its items but dropped its DISTINCT, ORDER BY, SKIP and LIMIT in
  the parser (`WITH DISTINCT g WITH g ...` returned duplicates), and the
  scope check refused the WHERE of such a WITH (`WITH x.g AS g, count(*) AS
  c WHERE c > 1 WITH ...`: 42000) because it read it before the
  projection. Regression: `zig build test-sonny6540-chain-with-stage`.
- **A 65,535-dimension vector literal parses (SONNY-6540 item 8).** The
  documented vector cap is 65,535 dimensions, but the array-literal form
  could not reliably reach it. Every decimal literal (`1.0`) built its
  digits in a buffer on the parser's arena and left it there, so a decimal
  element cost the parser more than twice an integer element; under an
  in-process executor's arena-over-arena the 65,536-element ENG-3922 (c)
  literal crossed the 64 MiB parser budget (SONNY-3244) and answered 54000
  before the dimension check could answer VectorTooLarge (`test-eng3922` was
  red). The digits are now stack scratch, freed at once: a decimal element
  costs what an integer one does (139 bytes of arena capacity each at 65,535
  elements over the page allocator; 300 before). And a sign on a numeric
  literal counted as an operator link against the 4096-link expression cap
  (SONNY-3181), so a vector literal with more than 4096 negative components
  answered 42000; ISO/IEC 39075:2024 21.2 makes the sign part of the
  `<signed numeric literal>`, and it is no longer counted. A sign on
  anything else (`-x`) still is, and the 64 MiB budget is unchanged: a
  1,000,000-element literal is still refused with 54000. Regression:
  `zig build test-sonny6540-vector-literal-parse` (`test-eng3922` is green
  again).
- **A refused graph answers every statement alike over QUIC, gRPC and the
  request handlers called in process (SONNY-6547 item 1).** Against a real
  server, QUIC and gRPC already agreed on all 85 shapes of the regression (a
  graph quarantined by zeroed node pages, the default one and a second one,
  and a graph whose shard label dictionaries diverged; every read and write
  shape of test-sonny6523-quarantine-fail-closed, first statement after a
  restart and again): a server always installs a row-security engine, so
  its reads go through a read snapshot that hydrates the graph first. The
  gRPC handler called in process with no row-security engine (embedded
  use) serves reads engine-direct and differed on 45 of 85 answers: 24 read
  the damaged graph and answered rows (a quarantine fail-open; the
  transport gate hydrated a graph only for a change), and 21 failed the
  call with a handler error (the node-scan stream returned every error but
  a limit out of the handler; the QUIC connection loop answers such an
  error with the generic "58000 Internal Server Error"). Both transports'
  gates now hydrate for a read too, as the executor's does (SONNY-6541
  item 3); the node-scan stream answers a storage-integrity refusal as
  itself; and an error a handler leaves unanswered is answered the same way
  by both (`proto_util.unhandledErrorInfo`: a limit or a storage-integrity
  refusal as itself, anything else 58000 "Internal Server Error"; gRPC
  failed the call). Regression: `zig build test-sonny6547-transport-parity`
  (real server, QUIC and gRPC, plus the gRPC handler in process). The
  regression's gRPC client opens one connection per Execute: the test
  client (`grpc_query_transport`) sends every Execute on HTTP/2 stream 3.
- **SHOW GRAPHS fails when its graph listing fails (SONNY-6547 item 2).** It
  answered an empty graph list instead (`listGraphNames(...) catch null`),
  the defect SONNY-6541 item 4 fixed for SHOW TABLES: forced in the
  regression by failing each of the statement's allocations in turn, two
  of which answered zero rows. The same sweep then crashed:
  `StorageAdapter.listGraphNames` and `GraphStore.listGraphNames` freed a
  graph name twice when an allocation after it was added to their
  de-duplication set failed (the insert's `errdefer` and the set's
  `defer`); the set now borrows the names. The other listing calls of the
  SHOW / `db.*` handlers already propagate their errors (sweep in the
  SONNY-6547 report). Regression: `zig build
  test-sonny6547-show-graphs-errors`.
- **A Raft `drop_graph` apply refused because the graph is in use no longer
  reports the graph dropped (SONNY-6547 item 3).** `GraphStore.dropGraph`
  refuses (`ObjectInUse`) a caller that holds the graph's read lock or a
  graph an open session transaction changed; the apply logged that, then
  logged the graph as dropped and returned success, so the entry counted as
  applied while the node kept the graph (every node replaying the log later
  drops it). It now fails: the Raft node counts and logs a committed entry
  not applied. The reported trigger, a one-voter cluster applying a drop
  on the proposer's own thread while it holds the graph's read lock, does
  not occur with the pinned raft library: a propose only appends, and the
  entry commits and applies on the next tick or step, on a thread that
  holds no graph lock; the regression runs it on a real one-voter cluster
  (the apply waits for the proposer's read lock, then drops the graph).
  Nothing in the server proposes a `schema_change` today (item 6).
  Regression: `zig build test-sonny6547-single-voter-drop`.
- **A replicated write's first hydration of its graph no longer stops the
  Raft node (SONNY-6547 item 4).** A Raft apply runs under the node's
  `inner_mutex`; the graph-mutation apply (and the 2PC decide apply)
  hydrated its graph there, and a first hydration persists its products
  with a checkpoint of the graph, which waits up to 5 s for the graph's
  lock. With a local reader holding that lock the leader's `inner_mutex`
  was unavailable for 6.3 s (measured: no tick, so no heartbeat, no inbound
  message, no propose; in a real cluster longer than an election timeout).
  The leader now hydrates an entry's graph before it proposes it, without
  `inner_mutex` (`raft_apply.prehydrateForApply` from
  `ClusterCoordinator.proposeWrite`), and the apply paths hydrate without
  the completion persist (`GraphStore.ensureGraphHydratedForReplicatedApply`;
  the next full checkpoint persists the products). Apply order is
  unchanged. Measured after: 117-129 ms longest wait (three runs) for `inner_mutex`.
  Remaining: on a follower, or for entries replayed after a restart, the
  hydration scan itself (no lock wait) still runs under `inner_mutex`.
  Regression: `zig build test-sonny6547-apply-hydration-stall`.
- **Docs no longer claim two-phase commit or replicated DDL in cluster mode
  (SONNY-6547 item 6).** The only server code that proposes a Raft entry is
  `statement_proposals.zig` (through `ClusterCoordinator.proposeWrite`), and
  it proposes `graph_mutation` entries only: no `schema_change`,
  `config_change`, `snapshot_pointer`, `txn_prepare` or `txn_decide`. CREATE
  / DROP GRAPH, index, constraint, policy, auth and tenant DDL are refused in
  cluster mode (`cluster.gateUnreplicatedWrite`). The apply arms for those
  entries (`raft_apply.zig`, `TxnCoordinator`) stay, as the tested receiving
  side of future features, and say so. `src/distributed/twophase.zig` is
  not compiled into the `geode` binary (no symbol of it in a Debug build;
  only `src/lib.zig`'s re-export and tests reference it); its removal waits
  for the `tests/all_tests.zig` cleanup (SONNY-6542), which imports its
  unit test. Corrected: CLAUDE.md (Phase 5), docs/FEATURES_OVERVIEW.md,
  docs/CURRENT_ARCHITECTURE.md, docs/IMPLEMENTATION_STATUS_OCTOBER_2025.md,
  docs/KNOWN_TEST_ISSUES.md (the coordinator IS instantiated in cluster
  mode) and src/distributed/README.md.
- **The SONNY-6377 "a chunk that timed out is not replayed" test no longer
  depends on a slow server (SONNY-6534).** It gave `geode query --file` a
  4 s `--timeout` for 400 CREATEs and counted on the server needing longer;
  the run takes 4.3-10.7 s on one Debug host (8.7 s on ReleaseSafe: the time
  follows disk syncs and host load, not the build), so it failed with
  `FixtureChunkDidNotTimeOut` on a quick host. SONNY-6523 did not change
  that time (same fdatasync/fsync counts and server CPU time before and
  after). The test now stops the server (SIGSTOP) once it is applying the
  chunk (its write(2) bytes rise past 16 KiB) and continues it when the
  client has exited, so the deadline always expires after the request was
  sent; the server then applies the whole chunk and the test still checks
  400 nodes, exit 4 and no replay. Its gRPC case waits for the count to
  settle (it read once, and a fresh server's first write can land after
  that read). The file and the two other steps that import it
  (`test-sonny6425-grpc-retry-summary`, `test-sonny6384-grpc-chunk-summary`)
  spawn the geode this build emitted instead of `./zig-out/bin/geode`
  (SONNY-2697), which `test-sonny6436-quic-retry-stops` and
  `test-sonny6447-quic-retry-connect-stops` never installed. Regression:
  `zig build test-sonny6377-query-no-resend`.
- **`tests/test_gap_0511_regression.zig` runs again (SONNY-6528 item 6).**
  `tests/all_tests.zig` imported it, but nothing compiled it (it used std
  APIs Zig 0.16 removed). Its MERGE and DELETE cases (node and relationship
  MERGE and DELETE take no read snapshot and no label scan; DELETE finds
  its nodes through the exact property index, MERGE through the MERGE
  property index since GAP-0894, which the old exact-lookup count no
  longer saw) and its `commitDeferRebuilds` case had no live counterpart;
  they are ported and run as `zig build test-gap0511-regression`. Two cases were dropped as superseded and covered
  by live steps: the per-transaction vector-index rebuild (an indexed write
  is an incremental insert since geode#875:
  `test-geode875-incremental-index`) and the sequential
  `rebuildAdvancedIndex` case (the function is gone; the rebuild mutex is
  covered by `test-vector-index-reader-quiescence`,
  `test-sonny6421-index-maintenance`, `test-geode875-nonblocking-backfill`).
- **Writes to the security graph exclude each other and its checkpoint
  (SONNY-6528 item 2).** The `__geode_security` records (users, roles,
  permissions, policies, grants, the HMAC chain root) were written with no
  lock of the graph's. The auth and policy DDL hold `auth_ddl_lock`, but the
  login-state write after a failed login, the password and legacy-hash
  writes do not, so two engine writers could work on the graph's shards at
  once, and a checkpoint of the graph did not wait for them (both forced in
  the regression: a permission record create, and a full checkpoint,
  completed inside a role record's node create). Every storage-adapter write
  to the security graph now holds the graph's write lock for the engine
  operation (`StorageAdapter.holdSecurityGraphForWrite`). Regression: `zig
  build test-sonny6528-security-write-exclusion`.
- **A checkpoint of a graph waits for a Raft apply's write to it (SONNY-6528
  item 1).** A checkpoint takes the graph's rwlock exclusively to drain its
  writers before it writes the shard manifests, the label index and the
  dirty pages; every local writer holds that lock, but the Raft apply of a
  replicated write (`raft_apply.applyGraphMutation`, which creates nodes
  through `createNodeWithId` -> `StorageAdapter.createNode` and sets
  properties, deletes and updates) held none, so on a cluster member a
  checkpoint ran in the middle of an apply's node create (forced in the
  regression: the full checkpoint completed between the engine counting the
  node and writing its record). The apply cannot take the rwlock (it runs
  under the Raft node's `inner_mutex`, which a leader's request takes while
  it holds its graph's rwlock to propose), so each replicated write now
  holds a per-graph `replicated_apply_mutex`, and a checkpoint takes it
  right after the rwlock. Regression: `zig build
  test-sonny6528-apply-checkpoint-exclusion`.
- **A quarantined graph refuses reads to in-process callers too (SONNY-6528
  item 4).** SONNY-6523 made the QUIC and gRPC handlers refuse a program on
  a quarantined graph (REQ-GQL-028: its hydration found its store damaged).
  A caller that runs the executor in process, or calls the store directly,
  was not covered: once the graph was quarantined, the executor still
  answered the engine-direct reads (filtered and exact-index counts, ORDER
  BY ... LIMIT, `max(n.i)`), `CALL geode.fts.search`, an index-served `MATCH
  ... SET` (0 rows, success), and `db.labels()`, `db.relationshipTypes()`,
  `db.propertyKeys()` and SHOW TABLES answered from the graph's partial label
  maps, as did the store's schema listings the LSP schema provider calls
  (`listNodeLabels`, `listEdgeTypes`, `listPropertiesForLabel`: their
  hydration skipped every graph whose hydration had already run, a failed
  one included). The executor now runs the transports' check itself at its
  outermost entry point (a program that changes data hydrates its graph
  first), and the listings fail with the quarantine error while any graph
  is quarantined. CREATE and DROP GRAPH of a quarantined graph still run; a
  dropped graph is no longer quarantined. **Operator-visible:** while any
  graph is quarantined, the cross-graph schema listings (`db.labels()`,
  `db.relationshipTypes()`, `db.propertyKeys()`, SHOW TABLES, LSP schema
  completion) fail with the quarantine error, from every session, until the
  graph is restored or dropped. Regression: `zig build
  test-sonny6528-quarantine-in-process` (in process, zeroed node pages; 23
  statement shapes and the six direct listings).
- **A replayed create of a node the node cache evicted is refused, not made
  twice (SONNY-6528 item 3).** `GraphStore.createNodeWithId` (the Raft apply
  of a replicated create, and every other create with a given id) decided
  whether the id existed by asking the node cache, which is bounded
  (`GEODE_NODE_CACHE_ENTRIES`, default 1,000,000): a node it had evicted, or
  one not read back since a restart, was not found, and the create wrote a
  second engine record under the same public id. A restarted cluster member
  re-applying its committed log duplicated every such node on disk (200
  re-applied creates on a 16-entry cache: 400 engine records live, 600 after
  a restart and a second replay). The engine-backed create now also checks
  the durable IdMaps and answers `NodeAlreadyExists`, which the apply treats
  as the idempotent no-op it is. Regression: `zig build
  test-sonny6528-evicted-node-create`.
- **The storage corruption errors say what happened and what to do
  (SONNY-6528 item 5).** `DataCorruption`, `ChecksumMismatch` and
  `InvalidData` (a read that found a graph's stored data damaged, and every
  statement on a quarantined graph) reached the client as SQLSTATE 58000
  with the bare error name. Each now names what failed, says the statement
  returned no partial result and that a graph found damaged when it was
  loaded refuses every read and write, and tells the operator to restore it
  from a backup or remove it with DROP GRAPH (the server log names the
  graph). The code is still 58000; no message carries a path. Regression:
  `zig build test-sonny6528-corruption-messages`.
- **A quarantined graph refuses every read and every write (SONNY-6523
  item 1).** A graph whose first-touch hydration fails (REQ-GQL-028: its
  store is damaged) is quarantined, and the executor failed a statement that
  touched it. The transports' fast paths did not: over QUIC, `MATCH (n:L)
  RETURN count(n)`, `MATCH (n) RETURN count(n)`, `count(*)`, the
  relationship counts and the filtered counts answered 0 (from the products
  the failed hydration left partial), an exact-index count answered from the
  index, `max(n.i)` answered NULL, `CALL db.labels()`,
  `db.relationshipTypes()`, `db.propertyKeys()` and `geode.fts.search`
  answered, and every write shape (the default and bulk CREATE and MERGE
  fast paths, `/*+BATCH*/`, MATCH ... CREATE of a relationship, the
  executor's SET) was accepted and written to the damaged store. The QUIC
  and gRPC handlers now refuse a program on a quarantined graph's data
  before any path serves it (`graph_store.programQuarantineError`; a
  program that changes data hydrates the graph first, so its damage is
  found before anything is written), the count fast paths and the
  engine-direct count check the quarantine their own hydration may have
  just found, and every storage-adapter write path refuses a quarantined
  graph (`ManagedGraph.quarantine`, set when the hydration fails). DROP
  GRAPH of a quarantined graph still runs, and CREATE GRAPH of the name
  makes a fresh graph. **Operator-visible:** the first write to a graph
  after a restart now waits for that graph's hydration, as its first read
  already did. Regression: `zig build test-sonny6523-quarantine-fail-closed`
  (real server, zeroed node pages; 27 read and write shapes, each as the
  first statement after the restart and again).
- **A node create that fails part-way leaves no record behind (SONNY-6523
  item 2).** The storage adapter's node creates (`createNode`, the
  reserved-id bulk insert behind the CREATE and MERGE fast paths and the
  group commit, `createNodesBatch`) allocate the engine slot first: the
  shard manifest counts the node at once. On a later error (a new label's
  dictionary write failing, any engine write error) they aborted their
  engine transaction and returned. graph-storage's abort drops the
  transaction's WAL records but neither returns the slot nor restores the
  pages it wrote, so the node record written before the error stayed in
  the page with no geode node over it, counted, and the next checkpoint
  made it durable: a ghost node that `MATCH (n)` did not return but every
  engine scan did (and, had the record not been written yet, a count one
  ahead of the records, which the live-count check reports as
  `DataCorruption`). The failed create now deletes the record in its own
  transaction (or, with none written, takes the count and the id back)
  before the abort (`releaseFailedNodeSlot`). Regression: `zig build
  test-sonny6523-failed-create-count` (each create path, failed by a
  directory at every shard's `labels.dict.tmp`; 25 live records instead of
  24 after the failure and 27 instead of 26 after a restart, before).
- **DROP GRAPH no longer takes time quadratic in the graph's label and
  relationship-type count (SONNY-6523 item 7).** Removing a graph's entries
  from the label postings, the label and relationship-type counts and the
  per-tenant introspection maps (shared by every graph) scanned each map
  from its start once per key removed. It now removes up to 256 keys per
  scan. Regression: `zig build test-sonny6523-drop-graph-purge` (a graph
  with 600 labels and 599 relationship types: 11 map scans, 1206 before).
- **The storage adapter's `free.store` sanitizer is removed (SONNY-6523
  item 4).** Before opening a graph, `sanitizeFreeStoreBeforeOpenLocked`
  validated `<graph root>/free.store` against its own copy of graph-storage's
  bitmap format and truncated it when it looked invalid. Every graph is
  sharded, and a shard keeps its `free.store` in its own directory
  (`<graph root>/graphs/<shard>/`), so the file it checked never exists and
  the check never ran. graph-storage 0.4.14 validates each shard's file
  itself (`loadFreeStore`: bounded per-store deserialization, and a stale
  bitmap is detected and rebuilt), so the function, its helpers and the
  test of it in the unbuilt `test_gap_0511_regression.zig` are deleted
  rather than pointed at the shard files: a malformed shard `free.store`
  fails the graph's open (fail closed), as graph-storage decides. No
  behaviour changes.
- **A graph dropped before a restart stays dropped after it (SONNY-6523
  item 5).** SONNY-6472 / SONNY-6492 made a write to a dropped graph's name
  (a bulk write, a replicated Raft apply) answer `GraphNotFound` instead of
  creating the graph again, but the dropped names lived in memory only:
  after a restart a replayed or late replicated write for a name dropped
  before it created the graph again, with the write in it. DROP GRAPH now
  records the name in `<data dir>/dropped_graphs.dat` (temporary file,
  fsync, rename, directory fsync) before it drops anything, and the adapter
  loads the names at open; CREATE GRAPH removes the name from the file
  before it creates the graph, which starts empty. A drop whose name cannot
  be written drops nothing and fails (`DroppedGraphNamesNotSaved`, also a
  failed replicated drop); a file that cannot be read refuses the open, as
  an unreadable graph registry does. Regression: `zig build
  test-sonny6523-dropped-graph-restart` (the real Raft apply entry point
  across three restarts).
- **Checkpoint settings do what they say; a failing checkpoint is counted
  and no longer floods the log (SONNY-6523 item 6).** The persistence tick
  (`--persist-interval`, 30 s by default) runs a light checkpoint every
  time; `GEODE_CHECKPOINT_OPS` and `GEODE_CHECKPOINT_INTERVAL_MS` only add
  bulk-ingest triggers and never stopped it (now documented in
  `docs/SERVER_FEATURES.md`, Checkpoints). The interval trigger measured
  the time since the last checkpoint from 0 on the monotonic clock, which
  counts from boot, until the first checkpoint: on a host up longer than
  the interval, the first tick with bulk work pending fired a checkpoint
  ("deferred-mode auto-checkpoint fired" with a 1-day interval). It now
  counts from the adapter's open. `--help` said `--persist-interval`
  defaults to 100 (it is 30000), and an unparsable value fell back to 100;
  it keeps the default now. A light checkpoint that fails for a graph (the
  pass carries on with the others and returns no error) was a WARN on every
  tick, and the tick's other failures an ERROR on every tick from up to
  three places: each is now counted (`adapter_checkpoint_failures_total`,
  `geode.runtime.*`) and logged at ERROR once per distinct cause, again at
  most every 10 minutes while it repeats, and once when checkpoints succeed
  again. Three crash tests whose comments said they ran with no checkpoint
  before the kill (`test-sonny6491-label-name-crash`,
  `test-sonny6491-orderby-label-intern`,
  `test-sonny2978-overlapping-engine-txn-crash`) set only the two
  variables; they now also start the server with no persistence tick. The
  hydration scan's comment that no write runs during a hydration is
  corrected (the shard-locked bulk writers do; SONNY-6492 item 2 allows for
  them). Regression: `zig build test-sonny6523-checkpoint-settings`.
- **A malformed MCP endpoint DSN says what is wrong (SONNY-6494;
  geode-client-zig v0.3.16).** The client library now parses a DSN with
  geode's host:port grammar and names the fault (`InvalidDSN`,
  `InvalidPort`, `UnsupportedScheme`), but geode's MCP tools answered every
  such endpoint with `Error: Failed to initialize client`, its resources
  with `Failed to connect to Geode server`, and `geode mcp --endpoint
  <bad DSN>` started anyway. `src/mcp/client.zig` maps each error to a
  message (docs/DSN.md, "How the MCP endpoint reports a bad DSN"); the
  tools and resources return it, and **`geode mcp` now refuses a bad
  `--endpoint` at startup** (exit 2, `Error: --endpoint: <message>`; the
  DSN is not echoed because it may carry a password). geode's own
  `checkDsnHost` pre-check is removed: the library refuses an unbracketed
  IPv6 host itself (the error is now `InvalidDSN`, was `InvalidAddress`).
  **Port 0 is refused for every client address** (`--server`, `--dsn`, the
  MCP endpoint): the grammar keeps accepting it for listeners, where it
  means "any free port", but a client dialling it failed at the first send
  with a bare `Unexpected`. An IPv6 zone in the MCP endpoint is refused
  with its reason. Regression: `zig build test-sonny6494-mcp-dsn-errors`.

- **The CLI reaches IPv6 servers (SONNY-6494 item 6; geode-client-zig
  v0.3.16).** `geode query`, `geode shell`, `geode backup` and the other
  QUIC CLI commands refused every IPv6 destination with
  `Ipv6EndpointUnsupported` (`src/client/quic_endpoint_host.zig`), because
  the client library bound an IPv4-only endpoint and formatted the dial
  address without brackets. v0.3.16 resolves the host itself: an address
  literal is dialled as written (IPv6 bracketed, from a `[::]:0` endpoint),
  and a host name is looked up in both families through the system resolver
  (hosts file and DNS), first IPv4 address first, otherwise its first IPv6
  address. geode's own resolver step is removed (it duplicated that rule)
  and the host goes to the library unchanged; the TLS server name stays the
  host as given. **Behaviour change:** `--server [::1]:3141`,
  `--dsn quic://[::1]:3141` and an IPv6-only host name now connect instead
  of being refused. An IPv6 address with a zone (`[fe80::1%eth0]:3141`) is
  still refused before dialling, now with `Ipv6ZoneUnsupported` and a
  message saying the QUIC dialler cannot use a zone. The steps
  `test-5077-quic-endpoint-host` and `test-sonny6487-endpoint-host-family`,
  which tested the removed module, are gone; the new end-to-end
  `zig build test-sonny6494-ipv6-query` drives a real server on `[::1]`
  through `--server`, `--dsn`, `ip6-localhost` and the MCP endpoint client.

- **Remote KMS latency stays flat on a long-lived connection, and a 16 MiB
  QUIC request is answered (SONNY-2412, SONNY-3232; quic v0.1.51,
  SONNY-6478/SONNY-6475).** quic v0.1.51 retires a finished stream and no
  longer resends acknowledged STREAM data: 64 remote KMS unwraps on one
  connection now take 11.1 ms -> 11.3 ms (1.01x; 43.7 ms -> 140.8 ms, 3.22x,
  on v0.1.50), so `test-sonny2412-kms-latency-flat` leaves the known-issues
  list and runs in the aggregate. The same release fixes the receive-side
  crawl of a request larger than the 10 MiB stream window: a request of the
  16 MiB maximum is answered (about 3.5 s, Debug server on loopback; it used
  to take ~168 s in ReleaseSafe and did not finish in Debug), and
  `test-sonny3232-quic-request-size` asserts it again instead of recording
  it. The earlier advice to keep QUIC requests well under 10 MiB no longer
  applies. Stalls of long transfers under heavy CPU load that remain in the
  library are tracked as SONNY-6522.

- **`MemoryMappedFile` says what it is; its tests write in a temporary
  directory (SONNY-6517 item 5, partial).** The type's doc claimed
  zero-copy memory-mapped I/O; it reads the whole file into a heap buffer,
  and no server path uses it (the docs already said so, SONNY-6511). Its
  inline tests wrote `test_mmap.dat` and `test_array.dat`, and
  `benchmarkMemoryMappedIO` `benchmark_mmap_test.dat`, into the working
  directory; the tests now use `std.testing.tmpDir`, and the benchmark
  takes the scratch file's path from its caller (API change).
- **Orphan test, fuzz and benchmark files: run or removed (SONNY-6517
  items 3, 4).** `tests/test_gql_conformance_rq.zig` and
  `tests/e2e_multi_graph_security.zig` were unreferenced `all_tests.zig`
  constants that never ran (their CANARY markers said TESTED). They are
  named steps now: `test-e2e-multi-graph-security` (stale `User` and
  `EnvironmentInfo` fields fixed) passes in the aggregate;
  `test-gql-conformance-rq` passes 24 of 24 in the aggregate. RQ-0019
  first demanded exactly 42000 for a privilege violation and failed on the
  gql dependency's 42501; ISO/IEC 39075:2024 23.1 allows subclass `000` or
  an implementation-defined subclass where 4.2.4.2 names none, so 42501
  conforms and the test now asserts that rule (SONNY-6536).
  Removed, as they name removed code and no build compiled them:
  `tests/test_feature_completion.zig` (`src/graph/builtin_algorithms.zig`),
  `fuzz/fuzz_distributed_features.zig` and
  `benchmarks/benchmark_distributed_features.zig` (`lib.planner_wcoj`,
  `lib.graph.leiden`, `std.rand`), `tests/memory_mapped_io_validation.zig`
  (`std.fs.cwd`, the removed `ChunkedMemoryMap`). `src/planner.zig`'s 14
  inline tests are ported and run by `test-sonny6511-lib-inline`; they
  found two defects in its `PathExpand` operator (managed ArrayLists; a
  result whose edge ids it had freed), both fixed.
- **substring, left and right count characters; substring's start follows
  the 1-based rule (SONNY-6518 item 5, BREAKING).** ISO/IEC 39075:2024
  20.24 LEFT / RIGHT take the first / last NC characters; Geode's
  `substring(str, start [, length])` (an extension, 1-based as documented)
  now takes the characters at positions start .. start + length - 1 that
  the string has, the rule of SQL's <character substring function>
  (ISO/IEC 9075-2). Changes: `substring('abc', 0, 1)` is '' (was 'a'),
  `substring('abc', 0, 2)` 'a' (was 'ab'), `substring('abc', -1, 3)` 'a'
  (was 'abc'), a negative length 22011 (was ''); multi-byte characters
  count as one (`left('日本語', 2)` is '日本': it answered half a
  character). Regression: `zig build test-sonny6518-substring-positions`.
- **toFloat, toInteger, toBoolean and toString are the CAST of their
  target (SONNY-6518 item 2, BREAKING).** They answer what `CAST(x AS
  FLOAT / INTEGER / BOOLEAN / STRING)` answers (ISO/IEC 39075:2024 20.8,
  the SONNY-6499 matrix), value and exception; none is documented as a
  lenient "try" conversion. Changes: `toFloat` / `toDouble` give a
  DOUBLE (was a DECIMAL at scale 6: `toFloat(1)` was 1.000000);
  `toInteger(-1.5)` is -1 (CAST truncates; it floored to -2);
  `toInteger(' 42 ')`, `toInteger('1e3')` and `toBoolean(' FALSE ')` read
  the trimmed literal (were NULL); text that is no literal of the target
  (`toInteger('abc')`, `toFloat('abc')`, `toBoolean('yes')`) is 22018 and
  an out-of-range integer text 22003 (were NULL); a type CAST does not
  convert (`toFloat(true)`) is 22G03 (was NULL); `toString(true)` is
  'TRUE' (was 'true'), `toString(date(...))` its ISO text (was ''); a
  wrong arity is 22023 (was NULL). The evaluator's `InvalidFormat` (a text
  that does not parse) maps to 22018, not 22G03. `call_handlers.castValue`
  is the one CAST body both paths run. Regression: `zig build
  test-sonny6518-conversion-functions`.
- **An aggregating WITH after the first part groups and aggregates
  (SONNY-6525 item 4, BREAKING).** `MATCH (z) WITH z WITH z.g AS g,
  sum(z.k) AS s WITH g, s RETURN g, s`: a part chained by its implicit
  RETURN keeps its items there, and the chain executor
  (`query_execution.executeQueryChain`) looked for an aggregating WITH in
  `with_clause` only, so it projected that part per row: no grouping, and
  every aggregate NULL. It now finds it (`projectionItems`) and groups its
  rows; the groups are keyed by `distinct_set.writeGroupKeyPart` as at
  every other grouping site (they were `formatValue` text, under which 1
  and '1', 'null' and NULL were one group), and the keys and aggregates
  read the statement's `$` parameters (they read NULL). Regression: `zig
  build test-sonny6525-with-group-keys`.
- **The `gql` tool's ORDER BY orders as the server does (SONNY-6518 item
  3, BREAKING).** `src/exec.zig` `stableOrderByTemporal` compared every
  non-temporal key by its printed text (10 before 9, -1 after 1) and put
  NULLs last ascending and first descending. Keys are now compared by the
  server's reference comparison (`return_and_sorting.compareValuesWithNullsPolicy`:
  numbers by exact value across INT and DECIMAL, strings by their NFC
  forms) with NULLS FIRST by default in either direction, as the server's
  full sort. Regression: `zig build test-sonny6518-exec-order`.
- **An allocation failure while parsing is OutOfMemory, not a syntax error
  (SONNY-6517 item 1, BREAKING for the status code).** `parseGqlOutcome`
  (`src/lib.zig`), the parse entry of the QUIC and gRPC servers, the LSP
  and the `gql` tool, answered every parser error as a refused statement
  with `parseErrorCode`'s SQLSTATE, and 42000 for one it does not list:
  a request that ran out of memory while parsing was told its statement
  was a syntax error, and the LSP published it as an error diagnostic. It
  now returns `error.OutOfMemory` (the LSP request fails with it). The
  parser's own fallbacks no longer swallow it either: the MATCH ... DELETE
  look-ahead (which re-parsed the other form) and an identifier's case
  fold (which kept the unfolded name). The servers answer OutOfMemory with
  SQLSTATE 53200 out_of_memory (`proto_util.mapError`), as the read and
  write budgets do; it fell through to 58000. The LSP allocation-failure
  test is back to `std.testing.checkAllAllocationFailures` (it allowed an
  error diagnostic). Regressions: `zig build test-sonny6517-parse-oom`,
  `test-lsp`. `test-eng3922`'s 58000 guard now uses an error no arm names.
- **`CREATE GRAPH TYPE` takes a type keyword as a field type (SONNY-6517
  item 2).** `CREATE GRAPH TYPE T AS { x STRING }` was refused: the lexer
  reads STRING, INTEGER, BOOLEAN, FLOAT, DECIMAL, DATE, TIME, DATETIME,
  TIMESTAMP and DURATION as keywords and `parseFieldDefinitions` took only
  an identifier (ISO/IEC 39075:2024 18.6 <property type>, 18.9 <value
  type>). A wrong token there now names what a field type is.
  `test-sonny6511-graph-type-string-field` is green and in the aggregate
  (removed from `not_in_aggregate_steps` and KNOWN_TEST_ISSUES).
- **`WITH *, item` is refused with a message naming the rule (SONNY-6525
  item 3).** ISO/IEC 39075:2024 14.11 <return statement body> is `*` or a
  list of items, never both, so `WITH *, n.k AS k` and `RETURN *, n` stay
  refused (42000), now with "`*` is the whole projection list ..."
  instead of "expected token 'RETURN', got 'comma'". Regression: `zig
  build test-sonny6525-star-items`.
- **Built-in functions raise their argument errors; only a NULL argument
  gives NULL (SONNY-6518 item 1, BREAKING).** ISO/IEC 39075:2024 19.1 GR 1,
  20.22 <numeric value function>, 20.24 <character string function>. The
  function dispatch turned any error it did not list into NULL (an
  extension function's own error, a failed argument, an allocation
  failure), and the numeric and string built-ins answered NULL for a value
  of the wrong type, a wrong number of arguments and a value outside their
  domain; the basic dispatch answered "unknown function" (42883) for a
  heap function's error and for a date / duration / interval argument of
  the wrong type. Now: wrong type 22G03, wrong arity 22023, `sqrt` of a
  negative number and `pow(0, negative)` / `pow(negative, fraction)` 2201F
  (new `InvalidPowerArgument`), `log` (LN) of a value <= 0 2201E (new
  `InvalidLogArgument`), `log10` of one, `asin` / `acos` outside [-1, 1]
  and a non-finite `exp` / `pow` / `tan` result 22003, `mod(x, 0)` 22012,
  `left` / `right` of a negative length 22011 (it answered ''), a
  constructor's text argument of another type (`date(1)`, `uuid(1)`, ...)
  22G03, an unlisted extension error 22023 (InvalidJson 22018), and an
  argument's own error is raised. `round(x, NULL)` is NULL (it ignored
  the NULL). Numeric built-ins take a DOUBLE argument (`abs`, `ceil`,
  `floor`, `sign`, `sqrt`, trig, `log`, `exp`, `pow`: it read as NULL;
  `ceil` / `floor` of a DOUBLE give a DOUBLE, 20.22 GR 12 b ii). Still
  open (stories): the numeric results are DECIMAL at scale 6 where ISO
  declares an approximate number; `upper` / `lower` fold ASCII only;
  `trim` trims whitespace, not only spaces; `left` / `right` / `substring`
  count bytes, not characters. Regression: `zig build
  test-sonny6518-builtin-errors`.
- **ORDER BY after DISTINCT or an aggregate reads only what the
  projection makes (SONNY-6525 item 8, BREAKING).** ISO/IEC 39075:2024
  14.10 SR 4 c) i) 2) A) III): after a RETURN (or WITH, or FOR ... RETURN)
  that is DISTINCT or aggregates, a sort key may reference only the names
  the projection makes; with GROUP BY, also the grouping keys' variables;
  a variable inside an aggregate function of a sort key reads the incoming
  record (IV). Geode accepted any incoming variable there and sorted the
  rows by a value no row holds: `RETURN DISTINCT n.g AS g ORDER BY n.k`,
  `RETURN count(*) AS c ORDER BY n.k`, `WITH DISTINCT n.g AS g ORDER BY n.k
  ...`. They are refused with 42000 (VariableNotInScope) before anything
  runs (`scope_check.orderKeys`). A sort key that is one of the projected
  expressions (`RETURN DISTINCT n.g ORDER BY n.g`, `RETURN DISTINCT x AS y
  ORDER BY x`) stays accepted: it reads that column. Regression: `zig build
  test-sonny6525-order-by-scope`.
- **A reference to a variable nothing binds is refused in every clause
  (SONNY-6525 item 2, BREAKING).** ISO/IEC 39075:2024 20.12 SR 8: the
  incoming working record of a reference has a field of its name, and a
  statement starts with an empty record; a violation is a Syntax Rule's,
  42000 (4.7.3). SONNY-6496 refused such a reference only after a WITH or
  NEXT; before the first projection it read NULL: `MATCH (n) RETURN m`
  answered a NULL row per node, `MATCH (n) WHERE m.k = 1` no rows,
  `count(m)` 0, `RETURN m` one NULL row, a UNION arm or a statement-level
  FOR the same, a WHERE read a RETURN alias as NULL, and a bare name read
  the request parameter of that name (`WHERE n.k = lo` with `$lo`
  supplied: write `$lo`). `scope_check.checkStatement` now starts every
  statement's queries (a query, UNION / INTERSECT / EXCEPT arms, FOR,
  CREATE / INSERT / MERGE / DELETE statements) with nothing in scope, from
  the statement walk every transport runs before executing, so nothing is
  written. Still accepted: forward references inside one MATCH's pattern
  list, OPTIONAL MATCH, pattern predicates' own variables, path variables,
  FOR / CALL { } / YIELD bindings, aliases in ORDER BY, `*`, `$`
  parameters. Not checked (scope coming in unknown): CTE bodies, the
  statement after VALUES, the columns of a CALL with no YIELD. Corrected
  tests: 13 refused write shapes of `test-sonny-write-allowlist` that name
  an unbound variable (`DELETE q` with no MATCH, `SET ... nn.y`, `nosuch`)
  and the C1 case of `test-sonny-write-allowlist-r4-transport`, 10 refused
  write shapes of `test-sonny3139-write-shapes` (`SET y.k`, `REMOVE m.t`,
  a HAVING naming `nope`), 6 HAVING / WHERE-after-RETURN cases of
  `test-sonny2675-aggregate-semantics` and 2 of
  `test-sonny2675-grouped-having` (`nosuchalias`, `nosuch`), and the GROUP
  BY `nosuch` case of `test-gap0914` now expect 42000 VariableNotInScope
  instead of the write shape's refusal (WriteClauseNotApplied / 0A000),
  42703 (UnknownHavingReference) or UnknownGroupKey, still with nothing
  written; and `HAVING count(*) > lim` with `$lim` supplied (SONNY-2675
  accepted a parameter named without its `$` there) is refused as an
  unbound variable: write `$lim`. The
  VariableNotInScope message names both rules. Regression: `zig build
  test-sonny6525-statement-scope`.
- **A correlated IN / NOT IN subquery reads the outer row; an uncorrelated
  one runs once per statement (SONNY-6525 item 1, BREAKING).** The subquery
  of `x IN (MATCH ... RETURN ...)` ran without the row around it, so an
  outer variable it named read NULL on every executor: `MATCH (n) WHERE n.k
  IN (MATCH (m) WHERE m.t = n.t RETURN m.k)` returned no rows and the NOT
  IN form kept every row (ISO/IEC 39075:2024 20.12 SR 8: the name is the
  incoming record's field). Each variable of the row the subquery mentions
  is now bound for it (`evaluator_adapter.runSubquery`); two levels deep
  the innermost reads the outermost row. A subquery whose own MATCH (or
  UNWIND, FOR, LET) binds a variable of the outer row would have to join
  with the row (14.4 SR 5 c), GR 1), which no executor does: it is refused
  with 0A000 (it matched afresh and answered every row). A subquery that
  mentions no variable of the row, nor a parameter a nested scope bound,
  runs once per statement that changes nothing and every row reads that
  result (`execution/subquery_cache.zig`; it ran once per row). An error
  inside a subquery now raises its own GQLSTATUS (a data exception was
  0A000). EXISTS { } and COUNT { } already read the outer row; a CALL { }
  after a MATCH stays refused (SONNY-6343). Also fixed: the planned read's
  WHERE freed its dropped rows before the kept rows' slice was made, so a
  failed allocation there freed them twice. Regressions: `zig build
  test-sonny6525-correlated-subquery`, two subquery shapes added to
  `test-sonny6297-allocation-failure-sweep`.
- **The Prometheus exporter frees its metric names; three server files'
  inline tests run (SONNY-6511 item 3).** `PrometheusExporter.registerMetric`
  copied each metric's name and help text and nothing freed them (20
  allocations for the standard metric set, and the old copies when a name
  was registered again). `zig build test-sonny6511-server-inline` (in the
  aggregate) runs the inline tests of `active_stream_registry.zig`'s
  `GlobalStreamThrottle` (one used the removed `std.Thread.sleep`),
  `buffered_proto_reader_metrics.zig` and `monitoring/metrics_server.zig`,
  whose test found the leak.
- **LSP and MCP recommendations point at their token, and their errors
  are no longer dropped (SONNY-6511 item 4).** Every recommendation of
  `src/gql/recommendations.zig` was reported at line 0, column 0, and an
  error of the engine (out of memory included) was turned into "no
  recommendations" by both `src/mcp/lsp.zig` `validateQuery` and
  `src/cli/lsp/features/diagnostics.zig`. The AST carries no positions, so
  `RecommendationEngine.analyzeSource` finds each recommendation's token
  (property or field name, `count`, the `*` of a variable-length path) in
  the source, outside strings and comments; the LSP range covers it
  (0-based) and MCP reports 1-based line/column with an exclusive end
  column. Errors now fail the request. The LSP diagnostics also dropped a
  semantic-analysis allocation failure the same way, leaked diagnostic
  messages, a scope key and a document when an allocation failed, and
  `Document.update` left the text pointing at freed memory when its copy
  failed; all fixed. `zig build test-sonny6511-recommendation-positions`
  and `test-lsp` (`src/cli/lsp/recommendation_positions_test.zig`).
- **`geode shell` keeps the character typed after ESC; audit switches take
  any-case booleans and refuse anything else (SONNY-6511 item 5).** The
  line editor consumed ESC and the following byte as one key whenever that
  byte was ASCII, but read the pair as Alt+<key> only for a letter, so ESC
  followed in one read by a digit, punctuation or a second ESC lost the
  character (`RETURN 'x<ESC>1y' AS v` returned `xy`). Only Alt+letter is
  consumed as a pair now. `GEODE_AUDIT_ENABLED`, `_SYSLOG_ENABLED`,
  `_FILE_ENABLED` and `_WINDOWS_EVENTLOG_ENABLED` were on only for exactly
  `1` or `true`; `TRUE`, `yes` or a typo turned audit off silently. They take
  `1`/`0`, `true`/`false`, `yes`/`no` in any case, and any other value
  refuses the command like the other audit settings (SONNY-6494). The
  REPL's `containsTransactionCommands`, which the ticket also named, had no
  caller since `\source` stopped wrapping files in a transaction
  (882bccfc8, 2026-01-30); it was removed with its tests and markers
  (REQ-SOURCE-PERF-011, -012). `zig build test-sonny6511-repl-audit`.
- **The inline tests of ten live files run again (SONNY-6511 item 1).**
  `zig build test-sonny6511-lib-inline` (in the aggregate) runs the inline
  tests of `security/multi_graph_security`, `client/quic_query_runner`,
  `client/repl/spinner`, `performance/memory_mapped_io`,
  `ml/graph_embeddings`, `planner/cost_calibration`, `planner/pipeline`,
  `graph/community_louvain`, `graph/community_label_propagation` and
  `graph/containers/lfu` (55 tests). None compiled on Zig 0.16 and no step
  ran them. The shell spinner writes through a `Spinner.out` writer when one
  is set (the process's stdout otherwise), so its tests no longer write
  frames into the test runner's control channel. Two query-runner tests
  still expected a PULL after an inline page; since the server sends every
  page inline (2026-04, "send all result pages inline") the client sends
  none, which they now assert. The plan-calibration variance envelope
  follows the shared perf-gate policy (reported, enforced under
  `GEODE_PERF_GATES=enforce`), and the duplicate degree-bucket envelope in
  `pipeline.zig` was dropped (the `bench_pathcache_degree_util` benchmark
  measures it).
- **`geode shell` handles long input (SONNY-6494 item 3).** The
  meta-commands formatted replies that echo user text into fixed stack
  buffers, so `\echo`, `\set <option>`, `\use`, `\graph`, `\connect`,
  `\history` (an entry over about 1 KiB) and the unknown-command error
  failed with `NoSpaceLeft` on long text, and `\source` with a path over
  about 500 bytes did nothing and printed nothing; the transaction-recovery
  prompt dropped a graph name over about 200 bytes. The replies are now
  sized to their text. The line editor called any input of 4096 bytes or
  more a complete statement, so a long statement typed across lines was
  submitted at the first line ending in a keyword such as `AS` or `WHERE`;
  it now checks only the end of the input. ESC followed by a non-ASCII
  character in one read was taken as Alt+<letter> and the character lost;
  it is now ESC and then the character. Still open: East Asian wide
  characters are drawn one column wide (neither geode nor its `strings`
  dependency has an East Asian Width table). Regression: `zig build
  test-sonny6494-repl-long-input` (the real shell, plain mode and a
  pseudo-terminal).
- **Command audit fails closed: `geode` refuses to run when the audit it
  was asked for cannot be set up (SONNY-6494 item 4).** A
  `GEODE_AUDIT_SYSLOG_PORT` that was not a port silently became 514, a host
  name in `GEODE_AUDIT_SYSLOG_HOST` was kept and every audit message
  dropped, an audit configuration error turned command audit off with a
  warning, and an audit file that could not be opened only printed a
  warning, so the command (including `geode serve`) ran unaudited. The env
  form now uses the `--audit-syslog` grammar (`geode.host_port`), and any of
  these makes the command exit non-zero naming the setting before it
  starts. **Behaviour change:** a deployment whose `GEODE_AUDIT_*` settings
  were silently ignored (for example `GEODE_AUDIT_FILE_ENABLED=1` with the
  default `/var/log/geode/cli-audit.log` not writable, or a syslog host
  name) no longer starts until they are corrected. See
  [AUDIT_LOGGING.md](AUDIT_LOGGING.md) ("Command audit").
  Regression: `zig build test-sonny6494-audit-failclosed` (the built
  binary).
- **The cluster listener binds an IPv6 `GEODE_CLUSTER_LISTEN_ADDRESS`; a
  port-only `--listen-grpc` no longer listens wider than QUIC (SONNY-6494
  item 5).** The QUIC transport bound `"{address}:{port}"`, so an IPv6
  address written bare (`GEODE_CLUSTER_LISTEN_ADDRESS=::1`, which the
  cluster listener passes through as written) became `::1:4242` and the
  listener could not start. The bind address is now bracketed for an IPv6
  host however it was written (`QuicTransport.formatBindAddress`). A failed
  bind also left the transport holding the listen configuration it had just
  freed, so `deinit` freed it again (a crash on, for example, an address the
  host does not have); it now returns the bind error cleanly. A port-only
  `--listen-grpc` beside an IPv6 or host-name `--listen` bound `0.0.0.0`
  (every IPv4 interface while QUIC listened on one address); it is now
  refused at startup with exit status 2 and a message naming both flags.
  **Behaviour change:** `geode serve --listen [::1]:3141 --listen-grpc 50051`
  no longer starts; give `--listen-grpc` an IPv4 address. Regression:
  `zig build test-sonny6494-listen-addresses` (also covers the acceptor
  watchdog of `--listen <port>` and `--listen <host>`, already correct
  after SONNY-6480).
- **MCP `validate` and LSP diagnostics show the WHERE, FILTER and ORDER BY
  recommendations again (SONNY-6494 item 1).** The recommendation engine
  (`src/gql/recommendations.zig`) recognised a property reference only as
  `.PropertyAccess`, but the parser writes `n.prop` as `.Member` on an
  identifier, so the index (`WHERE n.p = …`, `ORDER BY n.p`), fulltext
  index (`CONTAINS`, `STARTS WITH`) and coalesce (`IS NULL`) suggestions
  never fired. It now reads both forms and also checks the ISO `FILTER`
  statement. The suggestions and their triggers are listed in
  [LSP_FEATURES.md](LSP_FEATURES.md#recommendations). Regression:
  `zig build test-sonny6494-recommendations-inline` (the file's inline tests,
  which no step ran) and `zig build
  test-sonny6494-mcp-validate-recommendations` (MCP `tools/call` →
  `validate`).
- **Data errors answer their ISO/IEC 39075 Table 8 GQLSTATUS (SONNY-6499
  item 6).** `proto_util.mapError`, on QUIC and gRPC: `TypeMismatch` (a
  value of the wrong type for an operation, a function or a CAST) is 22G03
  invalid value type, was 58000; the internal failures it also stood for
  now keep their own errors (the evaluator mappers of `sqrt`, `asin`,
  `acos`, `log`, `toInteger`, `toReal` turned every other error, out of
  memory included, into `TypeMismatch`; the Prometheus exporter's metric
  kind mismatch is `MetricKindMismatch`). `FloatNaN` 22003 (no GQL number
  is NaN or infinite); `IndexOutOfBounds` 22011 (substring); `RangeTooLarge`
  54000 (range() past 10,000,000 elements, the class the other size limits
  use); `RangeBoundsError` 22000; text that does not parse as a JSON, XML,
  URL, domain, UUID, bit string, hexadecimal, subnet, IDNA name or enum
  value 22018 (were 58000), an IP or MAC address 22018 (was 22P02, a
  PostgreSQL code); a duration component past its field's range
  (`P999999999Y`) 22015 interval field overflow (was 22G0H; it was also
  turned into NULL by the function dispatch once it had its own identity,
  now surfaced). CAST: a source type with no conversion to the target
  (20.8 GR 7 d ii, Table 4 "N": a list to STRING, a BOOLEAN to DOUBLE) is
  22G03 (was 22018); a datetime string that does not parse is 22007 (GR k
  i; was 22018). The unused `InvalidTypeConversion` arm (no raise site) was
  removed. Durations: a string naming both unit groups (`P1M1D`) stays
  accepted as a Geode extension (ISO 20.29 GR 1 would make it 22G0H) and
  round-trips; adding or subtracting a year-to-month and a day-to-second
  duration stays 22G14 (SONNY-6489); documented in
  docs/TYPE_QUICK_REFERENCE.md. **Behaviour change:** clients see the codes
  above instead of 58000 / 22018 / 22P02 / 22G0H. Regression:
  `zig build test-sonny6499-gqlstate-residuals`.
- **The `exec` ORDER BY text fallback orders strings by NFC (SONNY-6499 item
  5).** `exec.stableOrderByTemporal` (the standalone `exec` executor's ORDER
  BY, used by the `gql --demo-sort` driver) compares keys it cannot order as
  datetimes by their text, after the partial `geode_unicode.nfcNormalize`
  (it knows é and É only): U+212A KELVIN SIGN sorted after every ASCII
  letter. It now compares with `canonical_string.orderNoAlloc`, the order
  the full ORDER BY uses (SONNY-3055). Regression:
  `zig build test-sonny6499-exec-order-nfc`.
- **`geode serve --data-dir` with a relative path holding `..` starts, and a
  startup refusal leaks nothing (SONNY-6499 item 3).** On a fresh directory
  `--data-dir ../X` refused to start with "HMAC key required": the server
  kept the path as given, the timeseries store behind the auth graph
  manager refuses any path holding `..` (`validateDataDir`,
  PathTraversal), and the startup guard (`storeHasAuthRecords`) read that
  failure as "auth records exist". The data directory is now made absolute
  and normalized once, where it is resolved (`resolveServerDataDir`); an
  auth graph manager that cannot be opened refuses startup naming its error
  (`AuthGraphUnavailable`) instead of claiming records exist; and every
  startup refusal frees the index catalog it had set up (5 allocations the
  debug allocator reported leaked). The log and messages show the absolute
  path. Regression: `zig build test-sonny6499-relative-data-dir`.
- **CAST follows ISO/IEC 39075 20.8 for every source and target (SONNY-6499
  item 2).** `CAST(x AS STRING)` returned NULL for a DOUBLE, a REAL, a
  stored DOUBLE (read back as an extended value), a list, a record and
  every other kind it did not name; `CAST(x AS FLOAT / DOUBLE / REAL)`
  returned a DECIMAL at scale 6 and refused a DOUBLE; a DOUBLE could not be
  cast to INTEGER or DECIMAL; text was not trimmed and `nan`, `inf`,
  `1_000` and `0x10` were read as numbers. Now (`src/eval/call_handlers.zig`
  `evalTypeCastFunction`): a DOUBLE casts to its shortest approximate
  numeric literal (`1.5E0`, `1.0E-1`, `0E0`; GR j ii), which reads back as
  the same DOUBLE; a BOOLEAN to `TRUE` / `FALSE` (GR j v); an approximate
  target gives a DOUBLE (GR i); a DOUBLE converts to INTEGER and DECIMAL
  truncated, 22003 out of range (GR g i); text is trimmed and must be a
  `<signed numeric literal>`, exponent included (`'1e3'` AS INTEGER is
  1000), else 22018, and `'1e400'` AS DOUBLE is 22003 (new
  `NumericOutOfRange`); a value with no character form is 22018, never
  NULL. Matrix: docs/TYPE_QUICK_REFERENCE.md. **Behaviour change:**
  `CAST(1 AS DOUBLE)` is `1.0` (DOUBLE), was `1.000000` (DECIMAL);
  `CAST(true AS STRING)` is `'TRUE'`, was `'true'`; `CAST('nan' AS
  DOUBLE)` is 22018, was 22003. Regression:
  `zig build test-sonny6499-cast-matrix`.
- **`ORDER BY ... LIMIT k` fast paths return the NULL rows, honour NULLS
  FIRST / LAST, and never serve a mis-ordered index (SONNY-6499 item 1).**
  Both fast paths for `MATCH (n:L) RETURN n.k ORDER BY n.k LIMIT k` (the
  value-ordered index, `orderedScanFastPath`, and the top-K heap,
  `topKOrderedFastPath`) skipped every node lacking the key (and the heap
  every stored NULL), so the NULL rows the full sort returns first were
  missing; both declined an explicit NULLS FIRST / NULLS LAST. They now
  place the NULL rows as the full sort does (ISO/IEC 39075 16.17 SR 6 and
  GR 1 g ii; Geode's default is NULLS FIRST in either direction) and serve
  NULLS FIRST / LAST. The value-ordered index (graph-storage) orders
  strings by their bytes, not by NFC (SONNY-3055), and decides eligibility
  per shard, so a column with INTEGERs on one shard and DOUBLEs on another
  was served with every INTEGER first: it is now served only when every
  indexed string is in NFC (a walk of the in-memory trees,
  `StorageAdapter.orderedIndexColumn`) and every shard holds one value
  class; otherwise the heap serves it. A node that loses the key between
  the index walk and the read, or a value of a kind the index does not
  order, declines the fast path instead of dropping the row. **Behaviour
  change:** those queries return their NULL rows; a non-NFC string column
  is no longer index-served (slower, correct). Regression:
  `zig build test-sonny6499-orderby-fastpath-nulls`.
- **EXPLAIN plans the start the planned read takes (SONNY-6496 item 4,
  partial).** A single directed hop whose tail pattern is more selective
  than its head starts from the tail and walks the hop backwards (Bug B);
  PROFILE's scan collected the tail's nodes while EXPLAIN planned the
  head's scan and the forward expand (`MATCH (a:H)-[:R]->(b:T {k: 2})`:
  `LabelScan(est 5) ExpandOut` for 5 heads, the run started from 1 tail).
  `planned_read_runtime.startsFromTail` now decides for both, so EXPLAIN
  plans `LabelScan(est 3) ExpandIn` and PROFILE traces the same operators.
  A multi-property inline map's seed key is chosen by the same function
  (`chooseStartSeed`) for EXPLAIN and the run. Still open: PROFILE version 1
  (the legacy executor's payload) does not report the exact-index seek the
  legacy executor takes. Regression: `zig build test-sonny6496-explain-start`.
- **FOR at the start of a subquery runs; DELETE ... RETURN ... ORDER BY /
  LIMIT runs; CALL there and MERGE ... CREATE are refused with 0A000
  (SONNY-6496 item 3).** Each was a syntax error (42000). A FOR may start
  the query of an IN / NOT IN subquery or a CTE body (ISO/IEC 39075:2024
  14.8 <for statement> is a <simple query statement>); it runs once over
  the incoming row, as `WITH * FOR ...`, through the executor's existing
  FOR-after-WITH path. `MATCH ... DELETE ... RETURN ... ORDER BY | SKIP |
  LIMIT` is parsed as the query form (the DELETE statement form has no
  page), which deletes every matched row and pages only the RETURN. A CALL
  of a named procedure at the start of a subquery or a CTE body, and a
  statement-level `MERGE ... CREATE`, are refused with
  `UnsupportedQueryShape` (0A000) naming the shape, before anything runs:
  no executor runs them. Regression: `zig build test-sonny6496-subquery-forms`.
- **The write step keeps the scan's node copy (SONNY-6498 item 4).**
  `match_operations.stabilizeValue` boxed again (`getNodePtrForScan`) a
  node the scan had already boxed, one more detached copy per written row,
  held until the graph's next checkpoint and charged to the write budget.
  `GraphStore.isScanBox` answers in constant time (a set of the detached
  boxes, kept with `scan_hydrated_nodes` under its leaf mutex) and such a
  node is kept. Measured over 32 rows (in-memory): one SET group 3.00 ->
  2.00 copies per row (1038 -> 705 bytes), two SET groups 4.00 -> 3.00
  (1694 -> 1281), a node every row writes 4.03 -> 2.03 (1464 -> 736).
  Regression: `zig build test-sonny3148-write-step-amplification` (bounds
  2.0 / 3.0 / 3.5).
- **An expression that fails fails the statement on every executor path
  (SONNY-6498 item 3, BREAKING).** ISO/IEC 39075:2024 19.1 GR 1: an
  exception raised while a value expression is evaluated is the
  statement's. About forty legacy-executor sites caught it instead: a comma
  pattern's property map that read another pattern's variable matched
  nothing (`MATCH (n), (t {k: n.k / 0})` answered no rows), its grouping
  key and non-aggregated items were NULL, its aggregates skipped the row
  whose argument failed; the chained-part aggregates (`... WITH n WITH n.g
  AS g, sum(n.k / 0) AS s`) summed 0 and grouped a failing key as NULL; a
  hop or variable-length WHERE was false; a shortestPath or EXISTS / COUNT
  pattern whose inline property or WHERE failed matched (or counted)
  anyway; the shared projection (`execution.zig` `evalGroupedExpr`) kept a
  "tolerance" that read a failing GROUP BY key or grouped item as NULL and a
  failing HAVING as false. Each now raises the error (22012, 22003, a type
  error ...). The planned read declines a comma pattern whose property map
  reads another pattern's variable (it filtered each chain with no variable
  bound, so `MATCH (n), (t {k: n.k})` matched nothing even when valid). The
  chained-part and comma-pattern aggregates use the shared
  `computeGroupAggregation` (every value type and DISTINCT; they folded
  integers only, so sum / avg / min / max over doubles or strings were
  NULL) and the evaluator's arithmetic over aggregates (division by zero
  was NULL); the nested chain's final aggregate is `chainFinalAggregate`
  (it ignored the part's pattern and the statement's parameters). Kept,
  because the predicate is evaluated again where it counts: the WHERE
  pushdown pre-filter, the seek-key and selectivity precomputations, the
  write pre-checks. What a newly raising site computes is lent from the
  statement's scratch arena, and its rows and names are freed on the error.
  `pattern_helpers.computeAggregationForGroup` was dead code and is
  removed. Regression: `zig build test-sonny6498-swallowed-errors`.
- **Temporaries a predicate, a CTE or a standalone WITH computes are freed
  (SONNY-6496 item 2).** A list literal, a map, a string or any other value
  a WHERE, a FILTER or a pattern's property map computed was allocated on
  the result allocator and never freed (once per row, every executor:
  `match_operations.zig`, `planned_read_runtime.zig`, the WHERE-equality
  start seed). It is lent from the statement's scratch arena now
  (`value_utilities.lentAllocator`), as projected items already were. A
  CTE's body results, each recursive iteration's working set and the CTE's
  value (bound for the whole statement) are the scratch's too; they leaked.
  The standalone `WITH ... FOR` / `WITH ... RETURN` path frees the WITH's
  rows (never freed on the FOR path), builds its one empty input row on the
  stack (it was allocated and dropped), lends its RETURN items and frees its
  result on an error. Regression: `zig build test-sonny6496-query-leaks`
  (leak-checked, with and without a scratch arena, four session kinds;
  `tests/statement_leak_harness.zig` now installs the execution callbacks a
  subquery needs, as every server does).
- **A statement whose allocation fails frees what it built, on every
  executor (SONNY-6498 item 1).** With its N-th allocation failing, for
  every N, 64 of the 68 runs of `test-sonny6297-allocation-failure-sweep`
  (17 statement shapes x the in-memory, persisted, tenant-scoped and RLS
  sessions) leaked. Fixed at each site: the chained-part executors
  (`query_execution.zig` `executeQueryChain`, `executeQueryChainWithBindings`,
  `forAfterPart`) now collect the parts' rows in `ChainRows`, which owns
  them and the part results in flight (they were freed by hand, only on
  success); `adoptEntities` merges atomically; the planned read adopts each
  materialized node and relationship into the result's tracker as it is
  made (`OwnedGraphEntities.adoptNode` / `adoptEdge`) and builds its result
  with `bindingResult`, its rows freed on any error; `buildPlanIfSupported`
  and `ensureBinding` keep every slice and copied name owned; EXPLAIN,
  PROFILE and `db.labels()` build their results with
  `result_utils.ResultBuilder` (the legacy EXPLAIN's cells and step texts
  were never freed, even on success); the variable-length `PathIterator`
  frees a path it cloned or dequeued; the legacy traversals free a row, an
  environment or a seed binding they could not keep; a group key moves
  from its writer without a lost copy; the MERGE RETURN, the bound-variable
  RETURN and the tenant tag list free what they made. The planned read's
  hops read the engine's own edge slice (`getOutgoingEdges` /
  `getIncomingEdges`): the type-erased `expandOut` boxed it and leaked it
  when the box could not be allocated (graph_storage 0.4.13
  `interface.zig` `sliceToEdgeIterator`). The sweep is green on every shape
  and session (about 40 s) and runs in the aggregate now. Regression:
  `zig build test-sonny6297-allocation-failure-sweep`.
- **After WITH or NEXT only the projected variables are in scope
  (SONNY-6496 item 1, BREAKING).** A reference to a variable the WITH (or
  the RETURN before a NEXT) does not project read NULL on every executor:
  `MATCH (n) WITH n.k AS k RETURN n.t` answered NULL rows, `... WITH n.k AS
  k WHERE n.t = 'a'` no rows, `count(n)` 0, and a later `MATCH (m) WHERE
  m.k = n.k` nothing. ISO/IEC 39075:2024 20.12 SR 8 requires the incoming
  working record to have a field of the referenced name, and 4.7.3 4) e)
  answers the violation with 42000; Geode now refuses such a statement with
  `VariableNotInScope` (42000) before anything runs, in every clause after
  the projection (WHERE, RETURN, ORDER BY, aggregates, GROUP BY, HAVING, a
  later MATCH's property map or WHERE, SET / REMOVE / DELETE / CREATE /
  MERGE, FOR, CALL ... YIELD, IN subqueries and comprehensions). The check
  is one pass of the statement walk every transport and entry point runs
  (`param_check` -> `scope_check.zig`), so the in-memory, persisted,
  tenant-scoped and RLS-policy sessions refuse the same statements. In
  scope stay the projected names, `WITH *`, variables a later MATCH, FOR,
  UNWIND, CALL ... YIELD, CALL { } or inline LET binds, parameters, and
  comprehension / quantifier / pattern-comprehension locals; ORDER BY after
  RETURN reads the RETURN's aliases and the variables before it (14.10 SR
  4 c) i) 2) A) III) 1)). Also: `WITH *` followed by its part's RETURN
  passes every variable on (it passed none, so `MATCH (n) WITH * RETURN
  n.t` was NULL). Before the first projection of a statement nothing new is
  checked. Regression: `zig build test-sonny6496-with-scope`.
- **MCP hover: function and procedure signatures are no longer built in
  fixed stack buffers (SONNY-6487 item 1).** `src/mcp/lsp.zig` `getHover`
  wrote a function's parameter list into a 1024-byte stack array and a
  procedure's YIELD column list into a 2048-byte one with unchecked index
  writes. A longer signature aborted the MCP server with `index out of
  bounds` in Debug and ReleaseSafe (the release mode) and wrote past the
  stack buffer in ReleaseFast. The hover text comes only from the built-in
  `language_metadata` table (longest today: 66 and 22 bytes), so no request
  could trigger it; the lists are now allocated to their real length
  (`formatHoverParams`, `formatHoverColumns`). Regression:
  `zig build test-sonny6487-mcp-hover-bounds`.
- **Addresses: one host:port grammar; IPv6 listen and dial; a bad port is
  an error (SONNY-6487 item 2).** `geode serve --listen` / `--listen-grpc`,
  the cluster peer list (`GEODE_PEERS`, `--peers`) and dialler, the 2PC
  participant dialler, `geode lsp --listen`, the `geode query` / `shell`
  `--server` paths, `--audit-syslog`, Kafka brokers, KMS endpoint probes and
  the shared test client split addresses on their last (or first) colon and
  ignored brackets, so `[::1]:4242` kept its brackets as the host and a bare
  `::1:4242` was read as host `::1`. They now all use
  `src/client/host_port.zig` (`geode.host_port`, the docs/DSN.md grammar
  `zig_quic_bridge.parseHostPort` already used). Operator-visible:
  `--listen <host>:<not a port>` refuses to start (it listened on port
  3141), `--listen localhost` binds 127.0.0.1:3141 (it bound 0.0.0.0:3141),
  a bare IPv6 address is refused everywhere (`geode lsp --listen ::1:9257`
  used to work by accident: write `[::1]:9257`), `GEODE_CLUSTER_PORT` that is
  not a port refuses cluster bootstrap (it fell back to 4242), and
  `--audit-syslog <host>:<not a port>` and `--audit-syslog <host name>` are
  refused (they sent to port 514, or dropped every message). The syslog
  sender addressed 127.0.0.1 as 1.0.0.127 (byte order) and dropped IPv6
  targets; both are delivered now. `--listen [::1]:<port>` serves over IPv6,
  and geode's own QUIC client (cluster peers, tests) binds an IPv6 endpoint
  and brackets the dial address for an IPv6 server. The CLI client
  (geode-client-zig) is still IPv4-only: it looks names up in both families,
  prefers IPv4, and refuses an IPv6-only destination with
  `Ipv6EndpointUnsupported` instead of failing with a bare `InvalidAddress`.
  Regressions: `zig build test-sonny6487-host-port`,
  `test-sonny6487-endpoint-host-family`, `test-sonny6487-ipv6-serve`.
- **Test infrastructure: `src/distributed/federation_flag.zig`'s inline
  test runs (SONNY-6487 item 5).** The build imported the file only as a
  named module of benchmarks and tests, so its test ran in no step:
  `zig build test-sonny6487-federation-flag-inline` (1/1).
- **Shell: the interactive editor keeps and edits non-ASCII text
  (SONNY-6487 item 3).** `geode shell`'s line editor
  (`src/client/repl/`) inserted only bytes 0x20-0x7e from typed keys, so
  `é`, `€` or a combining accent typed at the prompt were dropped (pasted
  text kept them); the cursor keys, Backspace and Delete moved or removed
  one byte, so they could split a character and send invalid UTF-8; the
  cursor column counted bytes; and Ctrl-R history search dropped non-ASCII
  search terms (and ended the editor on a match longer than about 1000
  bytes, `NoSpaceLeft` from a fixed 1024-byte line buffer). Typed UTF-8 is
  inserted; cursor moves, Backspace, Delete and vi `a`/`e`/Esc step over a
  whole grapheme cluster (`strings` UAX #29 segmentation, so `e` + U+0301
  is one step); a combining mark takes no column; Ctrl-R searches UTF-8 and
  writes its line without a fixed buffer. The Delete key (`ESC [ 3 ~`) did
  nothing in either keymap (its arm compared key `0x1f`, the parser produces
  `0x7f`); it deletes the character at the cursor now. Known gap: East Asian wide
  characters are drawn as one column (no East Asian Width table in the
  repository or its dependencies), so the cursor is placed one column left
  per wide character before it; the text is unaffected. Regressions:
  `zig build test-sonny6487-repl-utf8` (real `geode shell` through a
  pseudo-terminal against a real server) and
  `test-sonny6487-repl-line-text`.
- **Test infrastructure: the abandoned-read test measures idle per thread
  (SONNY-6487 item 4).** `tests/test_sonny6466_abandoned_read_cancel.zig`'s
  "vanish" case failed under parallel load although the server behaved: the
  stall watchdog cancelled the vanished client's read at a stream idle of
  12.8 s and the join stopped, but the test's "idle" was a one-second window
  in which the whole server process spent under 30 ticks, and an idle
  server's polling threads spend 32-38 ticks/s together when several
  server-spawning steps run at once (about 9 on a quiet machine). Idle is
  now a window in which no server thread spends 30 ticks and the thread
  that ran the join is not runnable (the join runs on one thread at 80-110
  ticks/s); the 10 s threshold and the 30 s / 20 s bounds are unchanged.
  `zig build test-sonny6466-abandoned-read-cancel`.
- **Server: removed the unused MVCC manager fields from the connection
  state (SONNY-6487 item 6).** `ServerState.mvcc_manager` and
  `current_mvcc_txn` (`src/server/server_state.zig`) were never set or read;
  the server never ran the `src/server/txn/mvcc.zig` conflict detector they
  named. Regression: `zig build test-sonny6487-server-state-mvcc-fields`.
- **Stored lists compare their string elements by NFC (SONNY-6489 item 3).**
  `value_types.eqVals` (the element rule of `[...] = [...]`) and
  `value_types.eqExtValues` (two stored extended values) compared STRING,
  TEXT, CHAR and VARCHAR elements by raw bytes, so a list property holding
  a precomposed `é` was not equal to one holding `e` + U+0301, although `=`
  finds the strings equal (SONNY-3055). Both now use
  `canonical_string.eqlNoAlloc`. **Not changed:** full-text search keeps its
  normaliser (`index/fts_tokenizer.zig`, a two-character NFC) on both the
  indexed and the query side, so it stays self-consistent; switching it to
  full NFC changes the tokens stored in existing fts-storage indexes and
  needs a versioned index rebuilt on open (story). `fts/advanced.zig`'s
  analyzer is not on any live path (`LanguageAnalyzer.analyze` uses the
  removed managed `std.ArrayList` API and is never compiled). Regression:
  `zig build test-sonny6489-list-string-nfc`.
- **Duration arithmetic raises the standard's exceptions (SONNY-6489 item
  6).** ISO/IEC 39075:2024 20.28 GR 5c ii: a duration plus or minus a
  duration of the other unit group is 22G14 (incompatible temporal instant
  unit groups); Table 8 (23.1) names 22015 interval field overflow (20.28 GR
  5d) and 22008 datetime field overflow. **Behaviour change:**
  `duration('P1M') + duration('P1D')` is 22G14 (it was P1M1D); a duration
  result out of range (`duration('P2147483647M') + duration('P1M')`,
  `duration('PT1H') * 9223372036854775807`, an instant difference) is 22015
  and a datetime or date result out of range (`DATE '2026-01-01' +
  duration('P2147483647D')`) 22008, where both were 22003. Unchanged: a
  zero duration is of either group, and a duration with both parts (Geode's
  mixed duration, `duration('P1M1D')`, an extension: 20.29 GR 1 allows one
  group per duration string) is added part by part. Regression: `zig build
  test-sonny6489-duration-unit-groups`.
- **`localdatetime()` is a local datetime; durations keep their fraction of a
  second (SONNY-6489 item 4).** `localdatetime()` and `localdatetime(s)`
  built a zoned (UTC) datetime that rendered with `Z` and compared as an
  instant; they are now local datetimes (ISO/IEC 39075 20.27 GR 10).
  Both duration writers dropped the fraction of a second (PT1.5S came out
  PT1S, PT0.5S as "PT"), and the wire writer (`Interval.toString`, QUIC and
  gRPC) split negative parts with a floor division (P-1M came out
  P-1Y-1M, PT-1.5S as PT-1H-1M-2S). Both now use one ISO 8601 writer
  (`Interval.writeIso`), whose output reads back as the same duration.
  `CAST(<date, time, datetime or duration> AS STRING)` is the value's
  literal form (it was NULL). **Behaviour change:** `localdatetime(...)`
  renders without `Z` and is a local datetime in comparisons and
  arithmetic; negative durations on the wire are correct. **Not changed
  (story):** a zoned datetime (TIMESTAMPTZ) still stores only its UTC
  instant, so `datetime('...+02:00')` reads back as the UTC time with `Z`;
  keeping the offset needs a new value encoding (in memory, on disk and on
  the wire) with a version for values stored before it. Regression: `zig
  build test-sonny6489-temporal-rendering`.
- **A QUIC listener that cannot bind frees its TLS configuration once
  (SONNY-6489 item 5).** `geode serve --listen ::1:0` (an unbracketed IPv6
  address, refused with InvalidAddress; the grammar is SONNY-6487) logged
  three DebugAllocator double frees: `QuicTransport.listen` recorded its
  config before creating the endpoint, its error path freed the config,
  certificate and key, and `deinit` freed them again. The error path now
  clears the recorded config. Regression: `zig build
  test-sonny6489-listen-error-free`.
- **`ORDER BY ... LIMIT k` returns the first k rows of the full ORDER BY
  (SONNY-6489 item 2).** The top-K heap that serves `MATCH (n:L) RETURN n.k
  ORDER BY n.k LIMIT k` compared an INT with a DOUBLE or DECIMAL through f64
  (9007199254740993 tied DOUBLE 2^53, DECIMAL 0.1 tied DOUBLE 0.1), ordered
  strings by raw bytes, returned a DECIMAL as a DOUBLE, and dropped every
  stored DOUBLE row (a DOUBLE is stored as an extended value). It now keeps
  the value the full path projects and orders with the full sort's own
  comparator (`compareValuesWithNullsPolicy`: numbers by exact value,
  SONNY-2807; strings by NFC, SONNY-3055); a key of any other kind makes the
  fast path decline (the full sort serves it) instead of dropping the row.
  The value-ordered index path returns a DECIMAL as a DECIMAL too.
  **Behaviour change:** those queries return the DOUBLE rows they omitted, a
  DECIMAL column comes back as DECIMAL (was DOUBLE), and ties broken by f64
  are ordered exactly. Regression: `zig build test-sonny6489-topk-order`.
- **Data exceptions answer their GQLSTATUS, not 58000 (SONNY-6489 item 1).**
  `proto_util.mapError` had no arm for these, so QUIC and gRPC clients were
  told the server broke (58000) when a value was bad. **Behaviour change**
  (ISO/IEC 39075:2024 23.1, Table 8): a date, time or datetime string that
  does not parse (`datetime('x')`, `date()`, `time()`, `localdatetime()`,
  ...) is 22007 invalid date, time, or datetime format; a duration string
  that does not parse (`duration('P1Q')`, `interval()`, including a
  component that overflows) is 22G0H invalid duration format (20.29 GR 1c;
  its own error, `DurationParse`, where it was `TimeParse`); DECIMAL division
  by zero (`decimal_div`) is 22012; `char(s, n)` of a longer string is 22001
  string data, right truncation. Regression: `zig build
  test-sonny6489-data-exception-codes` (QUIC and gRPC).
- **Data loss: nodes survive a crash during a checkpoint (SONNY-6492 item
  1).** graph-storage up to 0.4.13 wrote a shard's manifest and truncated
  its WAL during a checkpoint, and only then saved the shard's page bitmaps
  (`free.store`). The server runs a light checkpoint on every persistence
  tick (`--persist-interval`, 30 s by default; `GEODE_CHECKPOINT_INTERVAL_MS`
  and `GEODE_CHECKPOINT_OPS` do not stop it), so a SIGKILL could land
  between the two, and a failed bitmap save (ENOSPC, EIO) left the same
  state without a crash. The restart replayed no WAL and loaded the previous
  checkpoint's bitmaps: the node pages allocated since read as free, so
  every read missed the nodes on them, the first query after the restart
  failed with `DataCorruption` (the hydration scan's live-count check:
  "found 42 live node record(s) but the shard manifest counts 84"), and the
  allocator could hand out pages holding live data. This was the
  unexplained `DataCorruption` of `test-sonny6471-edge-prop-crash`.
  graph-storage 0.4.14 (SONNY-6491) saves `free.store` before the manifest,
  so a failed save fails the checkpoint before it advances anything, and
  detects and rebuilds a stale `free.store` that an older release left. The
  storage adapter's interim workaround (truncate a shard `free.store` older
  than its manifest) is removed: with 0.4.14 every `free.store` precedes its
  manifest, so it rebuilt every shard's bitmaps on every open, and it
  pre-empted graph-storage's own detection, which needs no modification
  times. Regression: `zig build test-sonny6492-checkpoint-free-store-crash`
  (real server, SIGKILLs, with and without TDE: a store an old release
  crashed in its window keeps all 464 nodes, and their properties after 800
  more; a failed save leaves the manifest and the WAL alone and WAL replay
  keeps all 464; a restart after a completed checkpoint rebuilds no bitmaps,
  32 before).
- **The hydration scan no longer fails with a false `DataCorruption` while
  nodes are being created (SONNY-6492 item 2).** The first-access hydration
  scan (`hydration_scan.scanShard`) has the same live-count check as the
  unlabeled scan (REQ-GQL-028) but none of the SONNY-6472 item 4 allowance
  for node writes in flight, and it read the count after its dirty-page
  snapshot, so a create finished in between was counted while its record
  was read from disk without it. Hydration holds no graph lock, so a node
  write that does not wait for it (an adapter-level write path) could make
  it fail and quarantine the graph. The count
  and the writers in flight are now read before the snapshot and the check
  allows one missing record per node write in flight at either read, as the
  unlabeled scan does; with none in flight it stays exact. Regression: `zig
  build test-sonny6492-hydration-live-count-race`; the detection itself:
  `test-sonny2409-zeroed-page-header`, `test-canary-recovery-corrupt-latency`.
- **A replicated write no longer creates a dropped graph again (SONNY-6492
  item 3).** The Raft apply of a data write (`raft_apply`, the
  `cluster_replication` apply helpers, the 2PC write-set apply) ensured its
  graph with `GraphStore.createGraph`, CREATE GRAPH, which creates a dropped
  name afresh: a write later in the log than a replicated DROP GRAPH brought
  the graph back with the write in it. They now use
  `GraphStore.ensureGraphForReplicatedWrite`, which answers `GraphNotFound`
  for a name dropped since the store opened, on every replica alike, and
  creates a never-dropped name lazily as before; a replicated CREATE GRAPH
  (schema_change) still creates the name again. `StorageAdapter.createNode`,
  which embedding code may call with no graph lock, now pins the graph for
  the create (a DROP GRAPH between its lookup and its write freed the graph
  under it) and fails with `GraphNotFound` when the graph was dropped before
  the create committed. Limit: the dropped names are kept in memory, so after
  a restart a replayed write of a name dropped before the restart is created
  lazily again. Regression: `zig build
  test-sonny6492-replicated-write-dropped-graph`.
- **DROP GRAPH clears the graph's counts of evicted nodes, and graph names
  with ':' no longer share counts (SONNY-6492 item 4).** The per-graph label
  and relationship-type counts and postings were keyed "graph:label":
  graph "g1" with label "x:y" and graph "g1:x" with label "y" shared one
  counter and one posting list. They are now keyed "graph\x00label", as the
  merge-index and tenant keys are. DROP GRAPH removed only the graph's
  resident nodes and edges from memory; with the node cache bounded, the
  evicted ones' counts and postings stayed, so a graph created again under
  the name started with the dropped graph's counts. DROP GRAPH now removes
  every entry keyed by the graph (label and relationship-type postings and
  counts, its node set, its tenant-introspection entries) and nothing of
  another graph. Regression: `zig build test-sonny6492-drop-graph-label-counts`
  (before: g1 counted 340 nodes with label `x:y`, its 300 and g1:x's 40;
  with the keys fixed but no purge, g1 created again counted 300).
- **Measured: the cost of the SONNY-6471 relationship-property images
  (SONNY-6492 item 5).** `zig build test-sonny6492-edge-prop-image-cost`
  sets the first property of relationships through
  `StorageAdapter.setEdgeProperty` with and without the head page images
  (interleaved perf_gate batches; the skip exists only in test binaries).
  Each SET that moves a property-chain head adds two 8 KiB page images to
  the WAL: 24.8 KB of WAL per SET instead of 8.3 KB (x3), in one
  transaction per SET and in a statement of 100 SETs alike (a SET whose
  relationship's source is on another shard than the statement transaction
  commits on its own, SONNY-2979). With the default fsync per commit the
  time is within noise (-5.3% and +0.5% at about 19 ms per SET on a loaded
  host); with `GEODE_WAL_SYNC=deferred` a SET takes 280 us instead of
  109 us (+156%). graph-storage does not deduplicate page images within a
  transaction. Not reduced in this change.
- **Test infrastructure: an explicit QUIC test-client timeout is a hard
  deadline (SONNY-6484 item 3).** `tests/proto_test_util.zig` bound every
  client connected to a loopback address to its server's liveness
  (SONNY-6301) and then treated every reply deadline as soft: while the
  server was alive the wait went on up to 120 s. So
  `executeAndCollectWithTimeout(.., 8)`, `helloWithTimeout(.., 1000)` and
  `readPacket(.., 5000)` never gave up on a live server, and the tests that
  rely on a short deadline to turn a hang into a fast failure (the
  sequential-upsert desync and high-concurrency e2e lanes) were measuring
  120 s. Those calls now fail with `Timeout` at their deadline (a server that
  exits still fails at once with `ServerExited`), and
  `executeAndCollectWithTimeout` bounds the whole exchange rather than each
  reply page. Waiting while the server is alive is a separately named
  choice: `ReplyWait.while_server_alive_ms` (`readPacketWait`, `helloWait`,
  `executeAndCollectWait`), used by the calls that take no timeout
  (`hello`, `executeAndCollect`, `ping`, `begin`, `commit`, ...).
  `tests/test_txn_coordinator_2pc.zig` ran 0 of 4 tests (all skipped behind
  a protobuf-union flag for a write-set format the coordinator stopped
  accepting in GAP-0870); they now build native G2PC write sets and run
  (4/4). Regression: `zig build test-sonny6484-client-hard-deadline`.
- **Docs: QUIC stream multiplexing defaults to on (SONNY-6484 item 4).**
  `docs/performance/quic-high-concurrency.md` said
  `GEODE_QUIC_ENABLE_STREAM_MULTIPLEXING` defaults to off; it has defaulted
  to on since 2026-07-06 (`src/server/server_init.zig`,
  `quic_stream_multiplexing_enabled = true`). Corrected there and in
  `docs/audit/quic-high-concurrency-2026-05-29.md`.

- **`geode shell --plain` no longer drops non-ASCII text (SONNY-6484 item
  2).** The plain-mode line reader kept only bytes 32-126, so every byte of
  a multi-byte UTF-8 character, and a tab, vanished without a word:
  `CREATE (:P {s: 'café'})` stored `'caf'`. Bytes pass through now;
  Backspace erases a whole character; a line that is not valid UTF-8 is
  refused (`Error: the line is not valid UTF-8; it was not run`) instead of
  being sent. Not fixed: the interactive (TTY) editor still drops typed
  non-ASCII keys (`keymap_emacs.zig`/`keymap_vi.zig` insert only 0x20-0x7e;
  pasted text keeps it). Regression: `zig build test-sonny6484-shell-utf8`
  (the real shell and server, 2-, 3- and 4-byte sequences and combining
  marks through CREATE and RETURN, read back over QUIC).

- **MCP language tools: three defects and two leaks found by running the
  inline tests of `src/mcp`, `src/storage/user_storage.zig` and
  `src/transactions/manager.zig` (SONNY-6484 item 1).** No step ran those
  tests; `zig build test-sonny6484-inline` (also part of
  `test-sonny6463-inline-wired` and the aggregate) now does, 73 tests.
  - `validate`/`diagnostics` leaked every recommendation message
    (`src/gql/recommendations.zig`: `RecommendationEngine.deinit` freed the
    list, not the `allocPrint`ed messages), and `hover` leaked the
    "Example:" text of every function, type and procedure it described;
    both grew a long-running `geode mcp` server (and `geode lsp`, which uses
    the same engine) per call. The engine now owns and frees every message.
  - `complete` on an empty document returned a validation-shaped rejection
    ("Query is empty") instead of completions; it now offers the clause
    keywords. `hover` on an empty document returns null contents. Every
    other input-chokepoint check still applies; `validate`/`diagnostics`
    still refuse an empty query.
  - `hover` for a word with no documentation answered `{}`: the JSON
    library drops null optionals by default. It answers
    `{"contents":null}`, as docs/MCP_LSP_BRIDGE.md states. Wire change for
    MCP clients that compared against `{}`.
  - The MCP endpoint DSN, `--server` and `--dsn` read an unbracketed IPv6
    literal wrongly: `::1` became host `:` port 1 (geode-client-zig's
    `parseDSN` and geode's `parseHostPort` split on the last colon), and
    `parseHostPort` kept the brackets of `[::1]:3141` in the host. Brackets
    are now stripped, a zone is accepted (`[fe80::1%eth0]:3141`), and a bare
    IPv6 literal or malformed brackets are refused with `InvalidAddress`
    (docs/DSN.md states the grammar). Behaviour change: `--server ::1` and
    an MCP endpoint `::1` are errors; write `[::1]`. Regression:
    `zig build test-sonny6484-ipv6-host-port`.
  - The `__geode_security` user-record HMAC was already deterministic; the
    inline test compared two records created in different milliseconds
    (`created_at`/`updated_at` are covered) and was rewritten.
    `persistUserWithHmac` and chain verification now share one function,
    `user_storage.userRecordHmac`, over the stored record, so the writer
    and the verifier cannot drift.
  - `transactions.Manager.commit` aborted a lock holder whose refused
    waiter was still active (the write-write check was symmetric); only the
    refused requester is doomed now. A transaction's wait-for list leaked at
    commit/rollback. The Manager is not used by any server path (see
    docs/ENHANCED_TRANSACTION_ISOLATION.md); the unused per-connection
    `ServerState.txn_manager`/`active_txn` were removed.

- **QUIC: a read a client abandons stops promptly (SONNY-6466).** A client
  that closed its connection (CONNECTION_CLOSE) while its read ran on a
  sibling stream, after the connection's first stream had ended, kept a
  server core busy until the per-connection stall watchdog (60 s): the
  accept reactor set the connection's cancel flag only while the first
  stream still owned the connection. Every read on a drained connection is
  now cancelled at its next row. A client that vanishes without
  CONNECTION_CLOSE is bounded by that watchdog, which grouped streams by the
  peer's IP: any other open connection from the same address (every client
  behind one NAT, every loopback client) hid the abandoned read — the
  regression stayed busy past 75 s — and could have its own reads cancelled
  with it. It now groups by connection, and its threshold is configurable:
  **`GEODE_QUIC_STALL_CANCEL_MS`** (default 60000, 1000-3600000; checked
  every 5 s). It also caps a single read that runs that long on a connection
  with no other stream reading, so set it above your longest read. The
  vendored quic v0.1.49 sends no PINGs and does not enforce the idle timeout
  it advertises, so a silent live client and a vanished one cannot be told
  apart sooner. Test clients (`QuicProtoClient.deinit`) now send
  CONNECTION_CLOSE (SONNY-6475 item 2; `abandon()` vanishes instead), and
  `test-sonny-write-allowlist-r4-transport` (SONNY-3368's abandoned join)
  runs in the aggregate again. Regression: `zig build
  test-sonny6466-abandoned-read-cancel`.
- **`range(start, end[, step])` is documented as what it is: a Geode
  extension with an exclusive end (SONNY-6466 item 3).** ISO/IEC 39075:2024
  defines no `range` function, yet the language metadata (LSP hover and
  completion) labelled it ISO GQL, and no document stated whether its end
  is included. It is half-open, as in Python: `range(1, 1500)` has 1,499
  elements, `range(1, 7, 2)` is `[1, 3, 5]`. openCypher's `range()` includes
  its end, so a query ported from Cypher must move the end by one step. The
  behaviour is unchanged (not breaking); the metadata now says "Geode
  extension", docs/TYPES_AND_FUNCTIONS.md, docs/GQL_COMPLIANCE.md and
  docs/API_REFERENCE_GENERATED.md state the contract, and the tests that
  called a `range(1, 1500)` seed "1,500 pairs" say 1,499.
- **`geode shell --plain` runs a line longer than 4,095 bytes whole
  (SONNY-6476 item 2).** The plain-mode reader used a fixed 4,096-byte line
  buffer and cut a longer line without a word: the first 4,095 bytes ran as
  one statement and the rest as another. The line now grows as it is read,
  up to 16 MiB (the server's largest request); a longer line is refused
  whole with an error. Regression: `zig build
  test-sonny6476-shell-long-line`.
- **macOS/BSD: the CLI session fingerprint reads the uid through libc
  (SONNY-6476 item 3).** `getSystemFingerprint` called the Linux `getuid`
  syscall on every non-Windows target. Regression: the inline test in
  `src/cli/security/session_storage.zig` (`zig build test-sonny6463-inline`).
- **`test-transport-parity` no longer depends on a leftover data directory
  (SONNY-6476 item 1).** The varlen dataset parity smoke ran against the
  fixed relative `./data/varlen_determinism`, which outlived every run; a
  store left there with other credentials failed the step (11/12), and the
  "curated dataset" was never seeded, so it compared two empty answers. It
  now seeds its dataset into a fresh temporary directory and asserts the
  rows.
- **Inline tests of 15 more live files now run (SONNY-6463 item 5).** The
  build imports them only as named modules or compiles them into an
  executable, so no test root collected their tests. `zig build
  test-sonny6463-inline-wired` (in the aggregate) roots each with the import
  table the build gives it: the thread pool and its parallel wrapper,
  logging, the FLE HKDF/HMAC/key-manager/blind-index wrappers, the storage
  backup module, the CLI auth helpers and auth init, `backup_cli.zig` and
  `cli_dispatcher.zig` (through `src/sonny6463_cli_test_root.zig`), and the
  fuzz harness; `test-sonny6463-inline` gains `std_shim.zig` (with
  `policy.zig`) and the GPU profiler. Fixed on the way: the profiler and the
  thread pool's tests used `std.time.nanoTimestamp` / `std.Thread.sleep`
  (removed in Zig 0.16), and `keys/manager.zig cacheStats` declared its own
  anonymous return type instead of the fle KeyManager's, so it did not
  compile once used. Still unwired, with failing tests: the MCP files (3
  failures, 1 leak), `storage/user_storage.zig` (1) and
  `transactions/manager.zig` (2).
- **Operator-visible: SHOW CLUSTER STATUS `last_contact_ms` is NULL for a
  peer never heard from (SONNY-6463 item 4).** A peer's `last_contact`
  started at the node's start time, so "never heard from" and "heard from
  at startup" read the same (the column grew from start until the first
  authenticated raft frame). It now starts unset and the column is NULL
  until that frame arrives; this node's own row stays 0. Regression: `zig
  build test-show-cluster-status`.
- **Dead distributed code removed (SONNY-6463 items 1-3).**
  `twophase.TwoPCCoordinator` (with `CoordinatorConfig` and the
  `twophase_participant.zig` participant only it used) had no user, and its
  `handleMessage` could not compile (protobuf cannot decode
  `TwoPhaseMessage`'s union submessages); `raft_consensus.Peer.alive`,
  `Peer.rpc_client` and the `RpcClient` type were never read or updated;
  `ClusterCoordinator.handleClusterMessage` → `handleShardQuery` (a 2PC
  write path that could not compile: `std.ArrayList(...).init`,
  `std.atomic.Atomic`) and its helpers had no caller. The live inbound
  cluster RPC path is `handleClusterRpcLocal`, unchanged. No inbound 2PC
  path existed, so no replay check was lost.
- **The acceptor watchdog watches the listener it serves (SONNY-6480).**
  The watchdog took its port from the `--listen` text, so `--listen host:0`
  switched it off; it read only `/proc/net/udp`, so an IPv6 listener was
  never watched; and it matched a row by port alone, so another socket on
  the port could be read instead. It now watches the transport's bound
  address (announced at startup: `[startup] acceptor watchdog: watching udp
  127.0.0.1 port N`; an IPv6 listener is given as `--listen [::1]:port`),
  reads `/proc/net/udp6` for an IPv6 listener, matches
  address and port, and among several sockets on that address the one the
  process owns; it does not sample once shutdown has begun. **Behaviour
  change:** the default `GEODE_ACCEPTOR_WATCHDOG_RX_BYTES` drops from 8 MiB to
  1 (any queued datagram): since SONNY-2719 a restart also needs no datagram
  drained between samples, so a busy, draining acceptor is never restarted
  whatever its backlog, while an acceptor wedged with a few connection
  attempts queued is now restarted within the 30 s deadline (with 8 MiB it
  never was). `QuicClientStream.readLineWithInterrupt` and
  `QuicStream.readLine` allocate only for a line they return (an 8 KiB
  allocation per poll retry before). Regression: `zig build
  test-sonny6480-acceptor-watchdog` and `test-sonny6480-readline-alloc`.
- **Temporal strings parse exactly (SONNY-2808).** The time parser read the
  first eight characters and ignored the rest. **Behaviour change:**
  `time('10:00:00+01:00')` is the zoned time 10:00:00+01:00 (it was the
  local time 10:00:00, offset dropped); `datetime('2024-01-01T10:00:00+02:00')`
  is 2024-01-01T08:00:00Z (the offset was ignored: 10:00Z); trailing text is
  refused with TimeParse in `time()`, `localtime()`, `timetz()`, `date()`,
  `datetime()`, `timestamp()`, `timestamptz()` and `localdatetime()`
  (`time('10:00:00xyz')` parsed); a zone in a local time or local datetime
  string is refused; `localtime()` and `localdatetime()` of a bad string are
  TimeParse (they were "unknown function", 42883); `time('10:00')` (reduced
  precision) is 10:00:00. `duration()` accepts what the GQL duration string
  grammar allows and it refused: a negative component (`P-1D`) and a
  fraction of a second (`PT1.5S`). `CAST(<string> AS TIME | TIMESTAMP |
  DATE)` follows the same rules (a zone or trailing text is 22018). The
  ticket's third item (an embedded caller's MERGE tagged the default tenant)
  was already fixed by SONNY-2686; the test pins it. Regression:
  `zig build test-sonny2808-temporal-parsing`.
- **Datetime and duration arithmetic (SONNY-2797).** Only `DATE +/-
  duration` was implemented; every other ISO/IEC 39075:2024 20.26 and 20.28
  operation was a type mismatch. Now: datetime, local datetime, date, time
  and zoned time `+`/`-` a duration (and duration `+` instant), months first
  as calendar months with the day clamped to the target month
  (`datetime('2024-01-31T10:00:00Z') + duration('P1M')` is
  2024-02-29T10:00:00Z), then the day-to-second part; a time of day wraps at
  24 hours; a date takes the whole days (so `date + PT48H` is two days later;
  it was the same date). Duration `+`/`-` duration (part by part, the
  day-to-second part normalized: `PT20H + PT20H` = `P1DT16H`), duration `*`
  number, number `*` duration and duration `/` number (a month count that is
  not whole, `P1M / 2`, is refused with 22023; a fraction of a microsecond is
  truncated; `/ 0` is 22012). `instant - instant` of one type is the
  day-to-second duration between them (a Geode extension for
  DURATION_BETWEEN; two types are 22G04). Overflow is 22003, as for `DATE +/-
  duration` (the standard names 22008/22015). Regression: `zig build
  test-sonny2797-duration-arithmetic` (incl. a fixed-seed property test).
- **Temporal fields before 1970 (SONNY-2796).** `.hour`, `.minute` and
  `.second` of a zoned datetime took the time of day with a truncating
  remainder, negative before 1970: `datetime('1969-12-31T23:30:15Z').hour`
  was -1 and `.minute` -30; they are now 23 and 30 (the floor modulo of a
  day; ISO/IEC 39075:2024 20.27 takes the fields of the ISO 8601
  representation). A local datetime (`timestamp()`), a zoned datetime built
  by `timestamptz()` and a zoned time (`timetz()`) had no fields (NULL); they
  now have `year`...`second` (and `millisecond`, `microsecond`) as their
  kind allows. A zoned datetime is held as its UTC instant, so its fields are
  UTC's. The ticket's `tde.configure_rotation('x', -1)` is already refused
  (0A000, SONNY-6342). Regression: `zig build
  test-sonny2796-temporal-fields`.
- **One string identity: NFC, on every path (SONNY-3055).** `=` compared
  two strings by their Unicode Normalization Form C (UAX #15) forms, but its
  NFC knew two characters (é and É), and everything else that decides string
  identity compared raw bytes: an inline property map and MERGE, the
  persisted read paths' matcher, GROUP BY and DISTINCT, the planned read's
  hash join, the exact node-property index the WHERE and inline-map seeks
  probe, MERGE's property index and tuple locks, and UNIQUE. So `WHERE n.s =
  'é'` (precomposed) missed a stored `'e' + U+0301` that `=` called equal,
  MERGE created a second node, and the two were two groups. Every path now
  compares, keys and hashes the full NFC form (the `strings` dependency's
  Unicode 15.1 normalizer; ISO/IEC 39075:2024 19.3 GR 3b compares strings by
  a collation, and leaves operations on unnormalized strings
  implementation-defined, IA003). **Behaviour change:**
  - `RETURN 'Å' = 'Å'` (U+212B ANGSTROM SIGN against U+00C5), Hangul
    syllables against their jamo, and marks in another order now compare
    equal (FALSE before); `'e' + U+0301 = 'é'` was already TRUE for `=`.
  - `MATCH (n) WHERE n.s = 'é'`, `{s: 'é'}`, `IN`, MERGE and UNIQUE find a
    stored decomposed `'é'` (they did not); GROUP BY, DISTINCT and
    `count(DISTINCT ...)` make the two forms one group (they were two).
  - ORDER BY, `<` and `min`/`max` order strings by their NFC bytes: a
    decomposed `'é'` sorts after `'f'`, as a precomposed one did.
  - **Upgrade:** the persisted exact index (`prop_exact.idx` GENPIDX6,
    `prop_rev.idx` GENRVIX3) and the hydration snapshots
    (`HYDRATION_SNAP_VERSION` 6) change format; files written by an earlier
    binary are stale and rebuilt on open (a one-time rebuild; no wrong answer
    is served from an old file). ASCII and NFC strings keep their keys.
  Regression: `zig build test-sonny3055-nfc-string-identity`.
- **One numeric equality rule: `=` compares a DOUBLE and an exact number by
  exact value (SONNY-2807).** ISO/IEC 39075:2024 19.3 (General Rule 3a)
  compares numbers "with respect to their numerical values". GROUP BY,
  DISTINCT, ORDER BY, an inline property map, MERGE and the exact index seek
  already did; `=`, `<>`, `<`, `<=`, `>`, `>=` (and IN, CASE and NULLIF,
  which use `=`) converted the exact operand to a double instead, so the
  same two values were equal to `=` and two groups to GROUP BY. They now
  compare exactly, NaN keeping IEEE semantics (it equals nothing). The
  planned read's two-pattern hash join (`MATCH (a:T), (b:T) WHERE a.x =
  b.x`) keys values by the GROUP BY key: it dropped every row whose key was
  a DECIMAL or an extended value (a DOUBLE parameter, a SMALLINT, a date),
  never joined an INT with an equal DOUBLE, and let the string `'i:1'` share
  a key with the integer 1. **Behaviour change** (for a DOUBLE, typically a
  client float parameter or a stored float property, against a DECIMAL
  literal such as `0.1`):
  - `RETURN $d = 0.1` with `$d` the DOUBLE 0.1: TRUE before, FALSE now
    (the double is 0.1000000000000000055...); `$d > 0.1` FALSE before, TRUE
    now; `$d IN [0.1]` TRUE before, FALSE now.
  - `MATCH (n) WHERE n.x = 0.1` no longer returns a node whose x is the
    DOUBLE 0.1 (it already did not match `{x: 0.1}` or group with 0.1).
    To compare with a double, compare with a double (`n.x = $d`).
  - `RETURN 9007199254740993 = $d` with `$d` the DOUBLE 2^53: TRUE before,
    FALSE now (no double holds 2^53 + 1).
  - A value a double holds exactly is unaffected: `DOUBLE 0.5 = 0.5`,
    `DOUBLE 1.0 = 1`.
  - On a persisted session, `MATCH (a:T), (b:T) WHERE a.x = b.x` returns
    the pairs whose x are equal (it returned none for decimal or DOUBLE
    properties).
  Regression: `zig build test-sonny2807-exact-numeric-equality`, and the
  updated past-2^53 case of `test-sonny2806-exact-property-matching`.
- **An unlabeled scan no longer fails with a false `DataCorruption` while
  nodes are being created or deleted (SONNY-6472 item 4).** The SONNY-2409
  check compares the live node records a shard scan finds with the shard's
  live-node count. The engine counts a new node before writing its record,
  and tombstones a deleted node's record before uncounting it, so a scan
  between the two steps of a write on another thread found one record
  fewer and failed the read. The adapter now counts the node creates and
  deletes in flight on the graph (`ManagedGraph.node_census_writers`) and
  the check allows one missing record per write in flight at either count
  read; with none in flight it stays exact. Regression: `zig build
  test-sonny6472-scan-live-count-race`; the detection itself:
  `test-sonny2409-zeroed-page-header`.
- **A write racing a DROP GRAPH no longer creates the graph again
  (SONNY-6472 item 2).** The storage adapter's write entry points
  (`createNode`, the bulk insert and MERGE helpers, `pinOrCreateGraph`)
  find their graph through `getOrCreateGraph`, which created any graph it
  did not have: a write that reached it after a DROP GRAPH brought the
  graph back, empty, for whoever wrote. The adapter now records the names
  it dropped; `getOrCreateGraph` answers `GraphNotFound` for them, and only
  CREATE GRAPH (`StorageAdapter.createGraph`, through
  `GraphStore.createGraph`) creates the name afresh. A name never dropped
  is still created by its first write. `bulkInsertNodeWithReservedId`
  also answers `GraphNotFound` when the graph was dropped between its
  lookup and its lock, as the bulk MERGE helpers do (SONNY-3121).
  `StorageAdapter.dropGraph` can now return `OutOfMemory` (nothing is
  dropped then). Regression: `zig build test-sonny6472-dropped-graph-writes`.
- **DROP GRAPH then CREATE GRAPH of the same name starts empty again
  (SONNY-6472 item 1).** DROP GRAPH takes the graph's nodes and edges out of
  memory after the storage engine has dropped the graph. Since SONNY-6268
  made node and edge deletes failure-atomic, those deletes read each
  node's incident edges and each edge's body through the dropped engine,
  failed with `GraphNotFound` and left the node in memory, so a graph
  created again under the name answered with the dropped graph's nodes
  (its label counts and postings): `test-sonny3033-batch-graph-gate`
  failed. The drop now removes the graph's resident edges, then its
  resident nodes, in memory directly. Regression: `zig build
  test-sonny3033-batch-graph-gate`.
- **A request's REMOVE and DELETE join its transaction's engine
  transaction on that shard (SONNY-6472 item 3).** Inside a Geode
  transaction, `StorageAdapter.deleteNode`, `removeNodeProperty` and
  `removeEdgeProperty` committed an engine transaction of their own even
  on the shard of the session's engine transaction, so a crash before the
  request ended kept them while losing the request's other changes on that
  shard. They now join it, as SET and CREATE already did; a relationship
  property removed inside it is written as a null tombstone (reads drop it,
  SONNY-6433). Changes on other shards still commit one engine transaction
  each (SONNY-2979). Regression: `zig build
  test-sonny2978-overlapping-engine-txn-crash` (new case: a SIGKILL during
  the request keeps the 4 of 64 nodes, node properties and relationship
  properties on that shard; before, none).
- **Data loss: relationship properties survive a crash (SONNY-6471).**
  Writing a relationship property moves the head of its property chain,
  which the relationship's adjacency entries and the edge index hold.
  `StorageAdapter.setEdgeProperty` and `setEdgePropertiesBatch` rewrote
  those entries without logging the pages in the engine transaction, so
  after a SIGKILL the property pages came back with nothing pointing at
  them: properties set by `SET r.p`, `SET r = {...}` and, in part, by
  CREATE and MERGE with inline relationship properties (the QUIC fast
  paths, the executor, a `/*+BATCH*/` program) were lost, inside and
  outside a transaction. `publishEdgePropHead` now logs the outgoing
  adjacency page, the source's node page and the incoming adjacency page
  in the same transaction as the property pages, as graph_storage's own
  `setEdgeProperty` does. Cost: three more 8 KiB page images in the WAL
  per relationship-property write that moves a head (no extra fsync).
  Regression: `zig build test-sonny6471-edge-prop-crash` (every write
  shape, outside and inside a transaction, same- and cross-shard, with and
  without TDE; read back outgoing, incoming and by an unlabeled scan after
  the restart).
- **Memory safety: an allocation failure no longer crashes a read, and
  fewer error paths leak (SONNY-6297).** Running statements with each of
  their allocations failing in turn found two crashes: tearing down a
  half-built read snapshot (`CALL db.labels()`) re-registered the default
  graph and panicked when that allocation failed, and the planned read's
  projection plan freed its key lists twice when a slice could not be
  made. Both are fixed, and a failed copy no longer leaves the copies made
  before it unowned (`duplicateValue`, `ownResultValues`,
  `adoptProjectionRowValues`), nor the shared projection a group key, a
  group's list or a column list, nor the planned read its final
  projection. Other error paths still leak; `zig build
  test-sonny6297-allocation-failure-sweep` reproduces them (an
  intentionally red step, see `docs/KNOWN_TEST_ISSUES.md`).
- **Per-row items of the legacy traversals are freed, and an item that
  fails fails the statement (SONNY-6297).** The variable-length traversal,
  the multi-pattern executors and the WITH stage's RETURN computed their
  items on the result's allocator while their rows borrow their cells
  (`a.s || '>' || b.s` leaked once per row on the in-memory, tenant-scoped
  and RLS sessions); they are lent from the statement's scratch arena. The
  multi-pattern executor answered an item that fails as NULL
  (`RETURN a.s || toString(c.i / 0)` gave NULL rows); it raises the error
  now (ISO/IEC 39075 19.1 GR 1). Regression: `zig build
  test-sonny6297-per-row-item-leaks`.
- **The write step keeps one detached copy of a written node per write
  (SONNY-3148).** Each refresh of a written node took a fresh detached copy
  (kept until the graph's next checkpoint and charged to the write budget):
  4.0 copies (1411 bytes) per row for `MATCH (n:W) SET n.x = n.i + 1 RETURN
  n.x`, 5.0 (2148 bytes) with two SET clauses. A refresh reuses its copy
  until the node is written again. A computed SET value (`SET n.t = n.s ||
  '-x'`, a list, a map) is lent from the statement's scratch arena; it
  leaked per row. Regression: `zig build
  test-sonny3148-write-step-amplification`.
- **Memory safety: the engine-direct node scan frees what a page built when
  an allocation fails (SONNY-2671).** A page over 256 rows dropped the row it
  had just built when growing its row list failed, and a failure while
  copying the column names freed column slots never filled (a crash). The
  row's slot is reserved before the row is built and only copied names are
  freed. Regression: `zig build test-sonny2671-scan-page-append-oom`.
- **A list literal over a relationship pattern reads its members on the
  planned read (SONNY-3126).** `MATCH (a:P)-[:R]->(b:Q) RETURN [a.s, b.s]`
  answered `[null, null]` on a persisted session: a bracket list literal
  parses as an array literal, which the planned read's projection analysis
  took for a constant, so the properties its elements read were not
  fetched for the projected nodes. Regression: `zig build
  test-sonny3126-list-projection-leaks` (keys(), collect() and list literals
  on every session, leak-checked).
- **A MERGE's or CREATE's RETURN map is freed with the result
  (SONNY-3378).** A write step's RETURN items (and a CREATE's WITH items)
  were evaluated on the result's allocator while the result borrows its
  cells, so `MERGE (m:M {k: 1}) RETURN {k: m.k}` leaked the map on every
  statement. They are lent from the statement's scratch arena, as every
  other projection's are. Regression: `zig build
  test-sonny3378-map-projection-leak`; the m-4 case of `zig build
  test-sonny-write-allowlist-r4b` runs on the testing allocator.
- **Query residuals: an aggregating WITH followed by another WITH, aggregates
  without MATCH under RLS, undirected self-loops, failing property maps
  (SONNY-6483).** (1) `MATCH (z:Z) WITH z.g AS g, sum(z.k) AS s WITH g, s
  RETURN g, s` answered NULL rows on the in-memory, tenant-scoped and RLS
  sessions (`WITH count(*) AS c WITH c` answered 1): the chained part's
  RETURN, which is the WITH's own items, was projected again over the rows
  the WITH had produced. The WITH stage's rows are now the part's answer.
  The per-row bindings the next part built, and the planned read's
  materialized nodes on the intermediate-aggregation path, leaked on every
  session; they are freed. (2) `RETURN count(1), sum(2)` answered `1, null`
  (and `collect(6)` UnknownFunction) on an RLS session, where the planned
  read is skipped: an aggregating RETURN without MATCH now aggregates over
  its one empty record in the shared projection. (3) `MATCH (a)-[r]-(b)`
  matched a self-loop twice on the legacy sessions; it is one path binding
  (ISO/IEC 39075:2024 22.3 GR, 4.11.6) and now matches once, as on the
  planned read. (4) A pattern's property map whose value fails to evaluate
  (`{i: 1 / 0}`) matched nothing on the planned read, and on every session
  for a relationship's map or the start node of a relationship pattern; it
  now fails the statement (ISO/IEC 39075 19.1 GR 1), as a node map did on
  the legacy sessions. (5) The `gql` developer tool's `--demo-eval` printed
  a RETURN label it had already freed (a crash) and leaked every row's
  computed values and every HAVING rewrite; `generateUniqueColumnNames` and
  the no-MATCH RETURN freed nothing when an allocation or an item failed.
  Regression: `zig build test-sonny6483-query-residuals`; the three
  `match_wrong` exemptions of `test-sonny2707-count-direction` are gone.
- **Memory safety: the legacy MATCH executor no longer returns rows that
  point into a freed snapshot (SONNY-2681).** The in-memory, tenant-scoped
  and RLS-policy sessions read through a `ReadView` that deep-copied the
  store whenever any write (to any graph or tenant) bumped the mutation
  epoch between its creation and its first read, and freed the copy when
  the read returned while its rows still held the copy's nodes and
  strings (a use-after-free: a crash or garbage cells under concurrent
  writes). The copy gave no isolation either (the epoch was checked once),
  so the executor now reads the store `getGlobalStore` gives it. The
  single-hop traversal also computed its RETURN items on the result's
  allocator, which no one freed (`a.s || '/' || b.s` leaked per row); they
  are lent from the statement's scratch arena as the other projections'
  are. Regression: `zig build test-sonny2681-read-view-snapshot-lifetime`.
- **Memory safety: with group commit off, a DROP GRAPH no longer frees a
  graph under a bulk MERGE (SONNY-3121).** With `GEODE_GROUP_COMMIT=0` the
  QUIC fast paths for a relationship MERGE and a multi-property node MERGE
  call their storage helpers with no graph lock held, and the helpers took
  no pin on the graph: a DROP GRAPH between their lookup and their locks
  freed it under them (a use-after-free). They now pin it for the whole
  operation (`StorageAdapter.pinOrCreateGraph`) and answer `GraphNotFound`
  for a graph dropped meanwhile. Regression: `zig build
  test-sonny3121-direct-bulk-pin`.
- **Cluster: a raft snapshot no longer crashes on a large or tiny DOUBLE
  property, and keeps every Float a Float (SONNY-2810).** The snapshot
  serializer printed a Float in positional notation into a 32-byte buffer
  and panicked when it did not fit (`1e40` needs 41 characters); an
  integral Float (`3.0`) came back an INTEGER, and NaN or an infinity made
  its node or relationship line invalid JSON, so the installer dropped it.
  Floats are now written in shortest round-trip scientific form, and NaN
  and the infinities as `{"$float":"nan"|"inf"|"-inf"}`, which the
  installer reads back. Regression: `zig build test-sonny2810-snapshot-float`.
- **An unlabeled scan over zeroed node pages fails instead of answering with
  the nodes missing (SONNY-2409).** graph_storage reads an all-zero page as
  a never-written one, so its node records read as empty: with every
  `nodes.store` page zeroed, `MATCH (n) RETURN n.name` answered OK with 0
  of 300 rows on a cold reopen, whether the derived indexes were loaded or
  rebuilt (labeled reads already failed closed, REQ-GQL-028). The engine
  node scan behind unlabeled reads (`StorageAdapter.scanAllNodes`) now
  compares the live records it finds on each shard with the shard
  manifest's live-node count and fails with `DataCorruption` (58000) when
  records are missing; `GEODE_DISABLE_HYDRATION_LIVE_COUNT_CHECK=1` turns the
  check off for salvage, as for hydration. A page whose header alone is
  zeroed already fails every read on graph_storage 0.4.12. Regression: `zig
  build test-sonny2409-zeroed-page-header`.
- **DATA LOSS: a REMOVE, DELETE or relationship-property REMOVE inside a
  transaction no longer comes back after a crash (SONNY-2978).** A
  transaction's changes join its session's engine transaction, which
  graph-storage batches: its WAL page images are written only when it
  commits (GAP-0900), and recovery replays the log in written order. A
  REMOVE of a property, a DELETE of a node and a REMOVE of a relationship
  property committed their own engine transaction on the same shard, so
  the transaction's older images of the same pages reached the log after
  theirs and a crash undid them. Since SONNY-6425 put a transaction's new
  nodes on its engine transaction's shard, this hit every node: measured
  against a real server killed with SIGKILL, `START TRANSACTION; CREATE`
  x64`; MATCH (n) REMOVE n.p; COMMIT` came back with `p` on 64 of 64 nodes
  (DELETE: 64 of 64 nodes back; edge-property REMOVE: 63 of 64). The
  statement and session engine transactions, which span many adapter
  calls, no longer hold their shard's WAL batch; group commit's shard
  transactions keep theirs (a worker writes only its own shard). The
  latent engine defect (recovery replays a batched transaction's images
  in written, not LSN, order) remains in graph-storage. Regression: `zig
  build test-sonny2978-overlapping-engine-txn-crash`.
- **A relationship property map with a parameter matches on every
  session, and an error in a WHERE fails the persisted read (SONNY-6296
  items 2 and 5). User-visible: a query whose WHERE raises now fails.**
  The legacy executor (in-memory, tenant-scoped and RLS sessions)
  evaluated a relationship's property map without the query parameters, so
  `-[:R {w: $p}]->` matched nothing, and a value it could not evaluate
  matched every edge; it now reads the statement's parameters, and such a
  value matches nothing. The persisted planned read turned an error in a
  row's WHERE or FILTER (22003 overflow, 22012 division by zero, a type
  mismatch, ...) into a dropped row and answered over the rest; it now
  fails the query, as the other executors do (ISO/IEC 39075:2024 19.1 GR 1
  evaluates the condition for every row; its exception is the
  statement's). Regression: `zig build test-sonny6296-legacy-read-gaps`
  (new).
- **`NOT (k = 1)` is a negated comparison, not a pattern; a CALL in a
  transaction body honours RETURN, ORDER BY, SKIP and LIMIT; FILTER after
  an inline LET and between MATCH statements (SONNY-6467 items 1-3).**
  After `NOT (`, any identifier not followed by `.` was taken for a node
  pattern, so `WHERE NOT (k = 1)` was a syntax error and `WHERE NOT (flag)`
  was `NOT EXISTS { (flag) }` (always false); an identifier is now a node
  pattern only when a label, a property map or an edge follows it.
  `START TRANSACTION { CALL p() YIELD x RETURN x ORDER BY x LIMIT 1 }`
  returned every yielded row in the procedure's order; the body's CALL is
  now finished as a statement's is. ISO/IEC 39075:2024 14.6 makes FILTER a
  simple query statement, so `MATCH ... LET x = e FILTER x > 2 RETURN ...`
  and `MATCH (a) FILTER a.k > 1 MATCH (a)-[:R]->(b) RETURN ...` are now
  accepted (a FILTER before CREATE or MERGE stays refused). Regression:
  `zig build test-sonny6467-query-residuals` (new).
- **ISO abbreviated edge patterns `-` and `<->`, and `<-[ ]->` matches
  either direction (SONNY-6267).** ISO/IEC 39075:2024 16.7 defines seven
  abbreviated edge patterns; Geode accepted `<-` and `->` (and Cypher's
  `--`, `-->`) but refused the `-` (<minus sign>, any direction) and `<->`
  (<left minus right>) spellings, and the full `<-[ ]->` (<full edge left or
  right>) matched outgoing edges only. `(a)-(b)`, `(a)<->(b)` and
  `(a)<-[r]->(b)` now match an edge in either direction (every Geode edge is
  directed). `(a)<--(b)` stays a syntax error, now with a message: it is not
  GQL (16.7 SR: `<-` juxtaposed with `-` would spell the `--` comment
  introducer, NOTE 238). The tilde forms (`~`, `<~`, `~>`) match undirected
  edges, which Geode does not store, and stay refused (SONNY-6433).
  Regression: `zig build test-sonny6267-abbreviated-edge-patterns` (new).
- **Breaking: an integer and a string are never equal (SONNY-6282).**
  `=` and `<>` compared an INT with a STRING by their text, so
  `WHERE n.id = 1` also matched a node whose `id` is the string `'1'`,
  `WHERE n.id = '1'` matched the integer too, `RETURN 1 = '1'` was true,
  and `WHERE n.id <> 1` dropped the string node; the inline map
  `(n {id: 1})` never equated them. ISO/IEC 39075:2024 19.3 GR 1: they are
  not essentially comparable values, and as universally comparable values
  `=` is False (NOTE 307), so `1 = '1'` is now false and `1 <> '1'` true in
  every session, as the inline map answers. `<`, `<=`, `>` and `>=` between
  them stay refused. A query that relied on the textual match must compare
  like types (`toString(n.id) = '1'`, `toInteger(n.id) = 1`). Regression:
  `zig build test-sonny6282-int-string-equality` (new).
- **ISO `NEXT` runs; unsupported inline `CALL` forms are refused with
  0A000 (SONNY-6343).** `NEXT` (ISO/IEC 39075:2024 9.2, Feature GQ20) was
  a keyword only: every `... RETURN ... NEXT ...` was a syntax error. The
  result table of the statement before `NEXT` now continues as the working
  table of the one after it, with its `DISTINCT`, aggregates, `ORDER BY`,
  `OFFSET` and `LIMIT`, and an optional `YIELD` (16.14) selecting and
  renaming columns: `MATCH (n) RETURN n.k AS k NEXT MATCH (m) WHERE m.k =
  k + 1 RETURN m`. It runs as Geode's WITH chain (the parser reads `RETURN
  ... NEXT [YIELD]` as `WITH ... [WITH]`, keeping every source position),
  so it has the WITH chain's validator, refusals and executors. A `NEXT`
  after a statement with no `RETURN` at its level, or after `UNION`,
  `INTERSECT`, `EXCEPT` or `OTHERWISE`, is refused with 0A000. Inline
  procedure calls: `CALL { } RETURN ...` and `CALL { } WITH ...` run as
  before; `CALL { }` followed by `MATCH`, a second `CALL` or a write,
  `MATCH ... CALL { }`, `CALL (x) { }` and `OPTIONAL CALL` were syntax
  errors (42000) and are now refused with 0A000 naming the form. Also: a
  `WITH ... WITH` chain (and so `NEXT ... NEXT`, `NEXT YIELD`) leaked two
  allocations per row on the bound-variables path; freed. Regression:
  `zig build test-sonny6343-next-and-call` (new). The stale OPTIONAL MATCH
  claims in `docs/kb/gql/` carry a status note.
- **A read-only `CALL { }` or procedure CALL inside an IN subquery reads
  (SONNY-3248, M1).** The write-shape validator's write walk counted any
  `CALL { }`, `FOR` or procedure call inside an expression or a CTE body as
  a write, so `MATCH (n) WHERE n.k IN (CALL { RETURN 2 AS x } RETURN x)
  RETURN n` and `... IN (MATCH (m) CALL db.labels() YIELD label RETURN
  m.k)` were refused with 0A000. A procedure there is classified as at the
  top of a statement, and a `CALL { }` or `FOR` body is walked like any
  part: a write inside one is still refused before anything is written.
  Regression: `zig build test-sonny3248-allowlist-minors` (new; also pins
  M6 WHERE truthiness, M7 `SET ... DETACH DELETE` and `WITH ... ORDER BY
  ... SKIP ... DELETE`, and UNIQUE on CREATE, SET and MERGE ... SET, which
  already held).
- **EXPLAIN describes the access path the executor takes (SONNY-6276).**
  SONNY-1335 made PROFILE name an index only when the executor seeked
  through a catalog btree or hash index; EXPLAIN kept guessing. A planned
  EXPLAIN said `IndexSeek` for an index of any type on the property (a
  fulltext index too) and for an indexed equality under an `AND`, where
  the executor seeks only on a WHERE that is one equality; the legacy
  EXPLAIN (a tenant-bound or RLS session over QUIC or gRPC, and the
  executor's own text plan) said `IndexSeek` whenever a catalog index
  matched, while the legacy executor scans. The planned EXPLAIN now asks
  the executor's own start decision (the seek `collectStartSlots` makes,
  and a catalog btree or hash index on that label and key, as PROFILE
  reports it); the legacy EXPLAIN says scan. The response flag
  `U:HeuristicIndexSelection`, sent with every query that had a WHERE or
  FILTER equality whether or not an index existed, is no longer sent.
  Regression: `zig build test-sonny6276-explain-access-path` (new).
- **The deepest nesting the parser allows fits a gRPC connection thread
  again (SONNY-738).** Nine nested FOR bodies (`... FOR x IN [1] MATCH (n)
  WITH n FOR ...`), within the documented limit of 10, were refused with
  42000 "nesting too deep for the parser's stack" on the 8 MiB gRPC
  connection threads of a Debug build: one level of query nesting cost the
  parser 0.33 MiB of stack (0.46 MiB for a FOR body). Every error exit of
  `parseQuery`, `parseForStatement` and `parseStatement` held a copy of the
  whole result (an `ast.Query` is 1.5 KiB, an `ast.Statement` 3 KiB) on the
  frame; they now parse into the caller's value and return nothing. A level
  costs 0.12 MiB (0.18 MiB for a FOR body), and the per-request
  `parseStatement` frame went from 562 to 331 KiB. Regression: `zig build
  test-sonny738-parser-frame-budget` (new, pins the cost per level) and
  `zig build test-sonny-write-allowlist-r4-transport`.
- **Breaking: one equality everywhere (SONNY-738).** After SONNY-6282 a
  pair of values could still be equal at one equality site and not at
  another. Now, as ISO/IEC 39075:2024 19.3 GR 1 and 22.12 define it, in
  every session:
  - values of types that are not comparable with each other (a number and a
    Boolean, a string and a Boolean, a date and a string, a number and a
    list, a node and a relationship, ...) are never equal: `=` is false and
    `<>` true, as for an integer and a string. `RETURN 1 = true` raised a
    type mismatch, which `WHERE` turned into an error on one path and a
    dropped row on another (so `WHERE n.k <> true` also dropped a node whose
    `k` is `1`). `<`, `<=`, `>` and `>=` between them stay refused;
  - lists compare element by element and records field by field, each pair
    as `=` compares it: `[1] = [1.0]` and `{v: 1} = {v: 1.0}` are true
    (were false); `[1, NULL] = [1, NULL]` is unknown (was true); a stored
    list property now equals a list value with a decimal in it in `WHERE`
    (`WHERE n.k = [1.0, 2]` missed a stored `[1, 2]`);
  - a simple `CASE x WHEN y` takes a WHEN only when `x = y` is true (20.7):
    `CASE 1 WHEN 1.0` takes it (took the ELSE), `CASE NULL WHEN NULL` does
    not (took it);
  - a TEXT, VARCHAR or CHAR value equals a string with the same characters
    (raised a type mismatch);
  - a recursive CTE's `UNION` drops `1.0` as a duplicate of `1`, and a
    decimal as a duplicate of itself (it ran to the iteration cap).
  `IN` follows `=`, so `1 IN [true]` is false (raised) and `42 IN ['42']`
  false. Regression: `zig build test-sonny738-equality-consistency` (new),
  and `zig build test-recursive-cte`.
- **Persisted sessions: a relationship walked from its target keeps its
  properties (SONNY-6266).** `MATCH (a)<-[{w: 2}]-(b)` answered 0, and an
  undirected hop with a relationship property map or a WHERE on the
  relationship lost every match taken backwards, on the planned read only.
  Writing an edge's properties (`StorageAdapter.setEdgeProperty` and
  `setEdgePropertiesBatch`) moved the new property head into the outgoing
  adjacency and into the target shard's legacy incoming chain; since
  graph_storage's edge co-location, incoming walks read the source shard's
  `adj_in_remote`, which kept head 0. Both copies and the edge index are
  now updated as graph_storage's own `setEdgeProperty` does. **Existing
  stores** keep a stale head 0 in the incoming entries of edges written
  before this fix; the planned read takes an incoming edge's property head
  from the edge index, which was always current, so they answer correctly
  without a rewrite.
  Regression: `zig build test-sonny6266-planned-reverse-edge-props` (new),
  and five `match_wrong` cases of `test-sonny2707-count-direction` now held
  to the test's own walk, warm and after a checkpoint and reload.
- **A variable-length MATCH returns one row per path, also through
  parallel edges and diamonds (SONNY-6264). User-visible: counts
  grow.** The traversal (`execution.PathIterator`, shared by the MATCH
  executors, `COUNT { }`, `EXISTS { }` and pattern comprehensions, and the
  planned read's engine-direct port of it) expanded only the first path to
  reach a node at a given depth, so every later path through that node lost
  its extensions: `MATCH (a:V {k: 0})-[*1..3]->(b) RETURN count(*)` gave 7
  where 12 paths exist. Two paths that differ in an edge are two bindings
  (ISO/IEC 39075:2024 22.2); the path mode (geode's default ACYCLIC, or an
  explicit TRAIL / WALK / SIMPLE) still restricts each path, and the
  10,000-iteration / 5,000-queue caps still bound the work. Regression:
  `zig build test-sonny6264-varlen-path-count` (new), and the six
  `path_dedup` cases of `test-sonny2707-count-direction` now held to the
  test's own walk.
- **`FOR x IN [ ... ]` no longer leaks the list it iterates
  (SONNY-6449 follow-up).** `executeFor` and the FOR header expansion
  evaluated the collection on the caller's allocator and never freed it,
  so every FOR over a list literal or a computed list leaked it once per
  statement. The list is now the statement's (its scratch arena), as every
  other computed projection value is since SONNY-6449; rows that borrow
  its elements stay valid until the result is copied out. Regression:
  `zig build test-for-write-body` (the SONNY-2463 case now runs on the
  strict testing allocator and frees its result).
- **Operator-visible: one checkpoint per persistence tick and one per clean
  shutdown, with per-phase shutdown timings (SONNY-6459 items 1-2).** Each
  persistence tick ran the light checkpoint twice (the checkpoint hook,
  then `adapter.checkpointAllLight()` again), so `checkpoints_total` rose
  by 2 per tick. A SIGTERM ran a light checkpoint while stopping the
  persistence thread, then the clean-shutdown FULL checkpoint, then a
  second FULL checkpoint in `deinitGlobalAdapter` after "[shutdown] data
  flush complete", which re-wrote every graph's exact property index and
  the graph registry ("full checkpoint: exact-index persist decision"
  logged twice per graph). A tick now runs one light checkpoint, and a
  clean shutdown runs the FULL checkpoint only. Durability is unchanged:
  every commit is fsynced to the engine WAL, and closing an engine still
  checkpoints any pages written after the flush. The shutdown log now
  reads "[shutdown] data flush complete (<n>ms, checkpoint runs since the
  signal: <k>)", "[shutdown] store closed (<n>ms)" and "[shutdown]
  teardown complete (<n>ms after the signal)". Measured on a busy disk
  (Debug build, one node written): SIGTERM-to-exit is about 8.5 s on the
  first shutdown after a graph is created and about 3 s afterwards. The
  rest is in dependencies: graph-storage's first FULL checkpoint of a new
  graph writes the derived indexes of all 16 shards (tmp file, fsync,
  rename, directory fsync per file; 5.8 s, then 155 ms on later
  shutdowns), each shard's WAL writes `graph.wal.ckpt` with fsyncs on close
  even when nothing changed (1.1-1.3 s for two graphs), and about 225 pool
  worker threads are joined one at a time (about 1 s). Regression:
  `zig build test-sonny6459-checkpoint-once`.
- **Operator-visible: SHOW CLUSTER STATUS `last_contact_ms` is the time
  since the peer was last heard from (SONNY-6459 item 3).** Each raft
  peer's `last_contact` was set once, when the peer list was built at
  startup, so the column grew from start for every peer, up or down. Every
  authenticated inbound raft frame from a peer now refreshes it (the same
  signal the health monitor uses); until the first one it still counts
  from startup. The field is written and read atomically. On a real
  three-node cluster the leader now reports 12-19 ms for live peers 10 s
  after start (it reported 7186 ms) and about 8 s for a follower killed 7 s
  earlier. Regression: `zig build test-sonny6459-cluster-last-contact`.
- **Operator-visible: the raft sender follows a peer to a new endpoint, and
  the cluster listener closes connections it cannot hand off (SONNY-6459
  items 5-6).** `raft_consensus.Transport` reused its cached connection to
  a peer whenever one was established, even after the peer's configured
  host or port changed, so frames for the peer kept going to its old
  address. A cached connection to an endpoint the peer no longer has is
  now dropped and rebuilt ("raft transport peer endpoint changed;
  reconnecting"); an IP change behind an unchanged host name stays with
  the re-resolve reaper. `ClusterCoordinator.networkLoop` did nothing with
  an accepted connection when it had no connection pool (the connection
  stayed tracked and open), and ended the accept loop, leaking the
  connection, when it could not allocate the task context. Both now close
  and untrack the connection and log it. Regression: `zig build
  test-sonny6459-cluster-transport`.
- **Test infrastructure: the distributed modules' inline tests run again,
  and test-graph-store compiles again (SONNY-6459 item 7).** Zig collects
  inline tests only from a test root's own module. The inline tests of
  `src/distributed/raft_consensus.zig`, `cluster.zig` and
  `cluster_auth.zig` are collected only by the unfiltered
  `src/graph_store.zig` and `src/eval.zig` roots (`zig build
  test-graph-store`, `test-gap0866`), and since SONNY-6456 (raft's
  `useRealQuicInTests`) neither compiled: raft_consensus.zig needs the
  `transport/quic` module in test builds too, and those roots did not have
  it. They now get their own instance of it. `twophase.zig`'s 23 inline
  tests were collected by no root; the new step `zig build
  test-sonny6459-distributed-inline` (a src/-rooted module wired like the
  graph_store root) runs the four files' tests, 59 in all. Fixed on the
  way: 13 twophase tests did not compile (pre-0.16
  `ArrayList.init`), and seven freed string literals (the 2PC send stubs
  and the undo-log tests now hand over allocated data, as the owners
  expect). Not run: twophase's two `TwoPCCoordinator.handleMessage` tests,
  because that function cannot compile (protobuf 0.1.6 cannot decode the
  union submessages of `TwoPhaseMessage`); nothing outside twophase.zig
  uses `TwoPCCoordinator`.
- **Docs: a cluster has no dynamic join and no shard failover (SONNY-6459
  items 4 and 8).** `ClusterCoordinator.handleJoinCluster` and
  `serializeClusterTopology` had no caller (the inbound cluster RPC
  dispatcher answers JOIN_CLUSTER with ERR) and did not compile
  (`nodes.append` without an allocator, `ArrayList(...).init`); Zig never
  analysed them, so nothing noticed. They are removed with what only they
  used (`parseNodeInfo`, `rebalanceShards`, `serializeMinimalJoinResponse`,
  `NodeInfoProto`, `JoinResponsePayload` and its inline test, the
  `Topology*` payloads). Membership is the static `--peers` list. Nothing
  in production fills the coordinator's shard table, so `forwardToShard`,
  `promoteReplica` and `ensureReplicationFactor` run only in tests; the
  code stays pending a decision. `src/distributed/README.md` no longer
  says the coordinator handles node join/leave, `docs/SERVER_FEATURES.md`
  no longer lists 32-shard, 3-5-replica horizontal scaling, and
  `docs/DISTRIBUTED_QUALITY_GAP_ANALYSIS.md` records the shard surface as
  an open residual. Regression: `zig build test-sonny6459-hygiene`.
- **Test infrastructure: an orphan test file is gone (SONNY-6459 item 9).**
  `tests/test_groupby_having_count_distinct.zig` was built by no step and
  could not compile (it imported `tests/exec.zig`, `tests/eval.zig` and
  `tests/planner.zig`, which do not exist, and called `planQuery` and
  `runGroupedQuery` with old signatures). It is removed; its CANARY
  marker (REQ-GQL-012 HavingCountDistinctFilter) moved to the end-to-end
  `HAVING count(DISTINCT n.i)` check in `zig build
  test-sonny2675-grouped-having`.
- **Remote backups of any size complete: quic v0.1.49, geode-client-zig
  v0.3.14, dns v0.1.28, audit v0.1.24 (SONNY-6434, SONNY-6447).** quic
  v0.1.48 walked its whole STREAM retransmit map on every ACK frame, and
  for each entry asked recovery for the packet's delivery state, a linear
  scan of the sent packets; an ACK frame also reached recovery as at most
  256 packet numbers. On a large transfer the server's QUIC poll thread fell
  to about 80 packets/s and `geode backup create --server` of about 24 MB
  stopped after 11-14 MB (SONNY-6430 item 1). v0.1.49 keeps the retransmit
  entries in packet-number order, hands recovery an ACK frame's ranges
  whole, retransmits at most two lost packets per ACK (oldest first; a
  failed send leaves the entry tracked) and bounds the work per packet:
  the 24 MB backup completes and `zig build
  test-sonny6430-remote-backup-large` is in the aggregate. `--timeout`
  still bounds the whole remote backup (default 300 s). geode-client-zig
  v0.3.14 moves in lockstep to quic v0.1.49. dns v0.1.28 (with audit
  v0.1.24, which pins it): the DNS resolver no longer panics at shutdown.
  `Address.eql` sized a receive's source address by its family, and one
  the kernel left unwritten (a peer with no address) had none; it now
  compares by family, and the receive paths zero the address.
  geode-client-zig still pins dns v0.1.27 until a client release moves it.
- **A CREATE in a query (`CREATE ... SET ... RETURN`, a FOR body's CREATE)
  commits one storage-engine transaction, as a CREATE statement does
  (SONNY-738).** `executeCreateQuery` opened no statement transaction, so
  each node, label, property and relationship it wrote committed on its
  own, one WAL fsync each, on whichever shard it landed: 8 commits for
  `CREATE (a:A)-[:E]->(b:B) SET ...`, 6 for each element of
  `FOR i IN ... CREATE (:A {i: i})-[:E]->(:B {i: i})`. A 1,500-element FOR
  seed against a server on an ext4 data dir took 191 s (27,567 fsync and
  fdatasync calls); it now takes 21 s, one graph WAL fsync per element.
  This was the cause of `test-sonny-write-allowlist-r4-transport`'s seed
  timeout, not the QUIC transfer. A FOR still commits once per element,
  not once per statement. Regression: `zig build
  test-sonny738-create-query-one-commit`.
- **An embedded PROFILE no longer leaks the member reads it evaluates
  (SONNY-6460 item 4).** `planned_read_runtime.executeProfiledIfSupported`
  runs a statement of its own but opened no statement scratch arena (the
  other executor entry points have since SONNY-6449), so called with none
  installed, a list property's copy and an FLE field's decrypted or
  redacted string were allocated on the caller's allocator and never freed.
  It now opens one and copies its result out before closing it. Regression:
  `zig build test-sonny6460-unscoped-eval` (leak-checked).
- **The `gql` executable's GROUP BY engine no longer leaks, crashes or
  hangs (SONNY-6460 item 3).** `src/exec.zig` `groupAndAggregate` never
  freed a group's accumulators or key slice (every grouped query leaked),
  and COUNT DISTINCT read its per-group set through an `undefined` pointer
  (a general protection fault). Its inline tests had compiled in no step;
  running them (`zig build test-sonny6460-exec-inline`, now in the
  aggregate) found more in the same engine: a HAVING with AND, OR or NOT
  pointed at dead stack and looped forever; an aggregate inside a HAVING
  comparison (`HAVING count(*) > 2 AND ...`) was never computed; the
  aggregate and set-operation (UNION/INTERSECT/EXCEPT) maps kept keys they
  had freed; an ORDER BY returned a freed buffer; `count_distinct(x)` read
  NULL; the planner refused `countDistinct`/`count_distinct` and a DECIMAL
  literal in HAVING. `groupAndAggregate`'s caller frees its result with
  `exec.freeGroupedRows`; `runGroupedQuery` allocates its result and
  scratch on the allocator it is given, which the `gql` executable now
  passes as a per-query arena. Regression: `zig build
  test-sonny6460-query-residuals` (leak-checked, including every
  allocation failure).
- **Test infrastructure: each cluster test step has loopback addresses of
  its own (SONNY-6460 item 6).** The two subprocess cluster suites
  (`test-cluster-steady-state`, `test-cluster-replicable-mutations`), which
  the aggregate `zig build test` already runs, both started their three
  nodes on 127.0.0.11-13, and the SONNY-6451 health test configured the
  same three; `test-sonny6453-cluster-peer-tls` and
  `test-gap0838-cluster-tls` listened on 127.0.0.2 with four other steps.
  Concurrent steps on one address could probe and bind the same free port.
  The replicable-mutations suite now uses 127.0.0.21-23, the health test
  127.0.0.14-16, the peer TLS tests 127.0.0.31 and 127.0.0.32;
  `zig build test-sonny6460-cluster-test-addresses` (in the aggregate)
  fails when a cluster test step's address appears in another test source.
- **Inline tests of 12 live files outside src/distributed run; dead files
  removed (SONNY-6463 item 5, partial).** `zig build test-sonny6463-inline`
  runs the inline tests of the MVCC heuristics (`conflict_repair_heuristics`,
  `early_detect`, `partial_rollback`, `predictive_skew_filter`),
  `stream_scheduler`, `index/selectivity`, `mcp/prompts`, `tools/bulk_loader`,
  `cli/tenant_cli`, `transactions/range_tracker`,
  `cli/security/session_storage` and `cli/geode_audit_verify` (78 tests), none
  of which any step ran. Found on the way: `CredentialStore.saveCredentials`
  / `deleteCredentials` did not compile under Zig 0.16 (ported);
  `getSystemFingerprint` leaked its environment copies on every call (the CLI
  calls it on each auto-loaded session); the CredentialStore tests wrote the
  real `~/.geode/credentials.json` (they now use a private HOME); the skew
  filter test contradicted its own documented threshold (corrected) and its
  uncompilable, uncalled `simulateHotWorkload` is removed. Removed as verified
  dead: `src/util/text_formatter.zig` (did not compile; its only importer was
  an unused alias in `src/server/main.zig`) and `src/security/audit_sink.zig`
  (no importer). The rest of the ticket's candidate list remains (see the
  SONNY-6463 report).

- **External KMS clients: AWS requests signed, TLS options honoured,
  unwrap from the envelope (SONNY-6465).** `src/security/external_kms_client.zig`
  (not yet constructed by the product; wiring is SONNY-6380): AWS KMS
  requests are now SigV4-signed for service `kms` (they were unsigned, so real
  AWS KMS refused them) and need static credentials (`aws_access_key` /
  `aws_secret_key`; instance-role credentials are refused with
  `AwsCredentialsRequired`, not implemented); `tls_ca_cert` is now the only
  trust anchor when set and `tls_skip_verify` is refused
  (`TlsSkipVerifyUnsupported`) instead of both being ignored; an envelope now
  carries its Vault ciphertext or AWS CiphertextBlob (`kms_ciphertext`, also
  in its JSON form as `kms_ct`) and `unwrap` decrypts that, checked against
  the envelope's hash (it decrypted whatever the last wrap left in memory, so
  nothing unwrapped after a restart); Vault `rotateKey` no longer bumps a local
  counter (the version comes from the next wrap's `vault:v<N>:`), AWS
  `rotateKey` refuses (`AwsKmsRotationIsManagedByAws`); `KmsProvider.deinit`
  frees what `createKmsProvider` allocated (it leaked). The file's inline tests
  run in `zig build test-sonny6465-external-kms-inline` (the live Vault / AWS
  cases skip unless `VAULT_ADDR` / `AWS_KMS_ENDPOINT` and credentials are set,
  and fail on any error once they are; they used to pass when a call failed).
  Regression `zig build test-sonny6465-external-kms` (no network call).

- **A QUIC request over the 16 MiB maximum is refused promptly
  (SONNY-3232).** The server refused such a message at its length prefix by
  ending the stream with no reply; it stopped reading, so the client, held by
  the stream window, blocked writing until its own 60 s writer deadline and
  learned nothing. The server now answers SQLSTATE 54000 (the message names
  the size and the 16,777,216-byte limit) and closes the connection with the
  new QUIC application error `message_too_large` (0x47450002), since the QUIC
  library cannot send STOP_SENDING; geode's own QUIC client stops writing as
  soon as the peer has closed the connection. Requests of 1 MiB and 4 MiB are
  answered (the loss-recovery stall round 15 hit, SONNY-3351, was fixed in
  quic 0.1.48). Still open: a request larger than the 10 MiB stream receive
  window crawls once the window is spent (ReleaseSafe answered 16 MiB in
  ~168 s; a Debug server did not answer it in 300 s), in the QUIC library's
  flow-control credit path. Keep QUIC requests well under 10 MiB (use
  parameters or `geode query --batch`). Regression
  `zig build test-sonny3232-quic-request-size`.

- **gRPC streaming Execute pages node-scan fast-path reads (SONNY-2465).**
  The streamed `/Execute` drain (`pushResultPages`) paged only an executor
  result; a statement served by the node-scan fast path holds a scan stream
  instead, so the client would get the schema frame and then zero rows. The
  drain now pages the scan stream as `Pull` does (a resource limit ends the
  stream with its SQLSTATE and fails the transaction; the final page
  releases the stream). Latent over the wire today: on `geode serve` the gRPC
  fast-path gate never opens for an authenticated session; this removes the
  hazard before that gate is aligned with QUIC's policy-aware one. The
  uncalled `buildStreamDataPage` was removed. Regression
  `zig build test-sonny2465-grpc-stream-node-scan`.

- **`--listen-grpc` binds the address it is given (SONNY-1336).** The
  address in `geode serve --listen-grpc <addr:port>` reached only a log line:
  the listener was created from the port alone and grpc-zig bound
  `127.0.0.1` (or `GRPC_ZIG_BIND_ADDR`), so `--listen-grpc 0.0.0.0:50051` in a
  container listened on loopback and a published port reached nothing; a
  port that did not parse silently became 3142. The listener now binds the
  given IPv4 address through grpc-zig's `initWithBind`; a port alone binds
  the `--listen` address (or `0.0.0.0`); a startup banner names the address
  and port bound. **Breaking:** an IPv6 address, a host name or a bad port in
  `--listen-grpc` is refused at startup (exit 2) instead of silently binding
  loopback. See `docs/GRPC_TRANSPORT.md` "Listen address". Regression
  `zig build test-sonny1336-grpc-bind-address` reads the bound socket from
  `/proc/net/tcp` and answers a real gRPC HELLO at the address.

- **`geode shell --plain` exits at end of input (SONNY-3060).** Piping a
  file or a here-doc into `geode shell --plain` used to run the statements
  and then print `geode>` prompts forever: the plain-mode reader treated
  Zig 0.16's `error.EndOfStream` as "end of this line" and read again. The
  shell now ends the session at EOF and exits with status 0 (a last line
  without a trailing newline still runs first); any other stdin read error
  ends the shell with a non-zero status instead of looping. Regression
  `zig build test-sonny3060-shell-plain-eof` runs the real shell against a
  real server with piped input.

- **Test infrastructure: in-process tests can run the real raft sender
  (SONNY-6456 item 3).** `src/distributed/raft_consensus.zig` replaced its
  QUIC client and listener with a do-nothing stub in every test binary, so
  `raft.Transport.send` sent nothing in any test and the SONNY-6451
  sender-side reconnect had only churn-log evidence. The stub is now the
  default and `raft_consensus.useRealQuicInTests(true)` makes the clients
  and listeners created afterwards real (production builds are
  unchanged). New regression `zig build test-sonny6456-raft-real-sender`
  drives the real sender against a started receiver: it delivers, sees
  `ConnectionClosed` after the receiver gives up the idle connection and
  rebuilds it, and reaches the receiver after it restarts. A peer moving
  to a new IP under the same name is not covered in process (it needs a
  DNS server the test controls); the netns membership-churn script covers
  it.
- **Operator-visible: the cluster health monitor reports a peer failed only
  when it stops being heard from (SONNY-6456 item 1).** A peer's
  `last_heartbeat` was written only when its entry was created, never when
  the peer was heard from, so 5 s after start every node logged "Node
  detected as failed" for every peer of a healthy cluster, once, and kept
  them all `failed`; a peer that really died looked the same as one that
  was up. Every authenticated inbound raft frame now refreshes its
  sender's liveness, so "failed" means "not heard from for 5 s". A node
  fails a peer over only when it expects to hear from it: a leader or
  candidate expects every peer, a follower of a known leader expects only
  that leader (followers do not talk to each other), and with no known
  leader every peer is expected. A failed peer that is heard from again
  logs "Node is active again". A failover error (`promoteReplica`'s
  `NoReplicasAvailable`) is logged and the pass goes on; it used to end the
  health thread, and with it the inbound-occupancy sweeper the same loop
  drives. `cluster_state.nodes` and `cluster_state.shards`, shared by the
  health loop, the inbound raft workers and shard forwarding, are now
  guarded by a leaf mutex (`cluster_state_mutex`). What `failed` drives
  today: a peer's state, the health log lines, and replica choice when
  re-replicating a shard (`getAvailableNodes`); production
  `cluster_state.shards` is never populated, so no shard failover ran, and
  shard forwarding, `sendToNode` and raft sends do not consult the state.
  Regressions: `zig build test-sonny6456-cluster-health-liveness` (three
  nodes) and `test-sonny6451-health-failed-peer`.
- **Operator-visible: a cluster node closes inbound raft connections whose
  peer went silent, and gives every finished inbound connection back to
  its listener (SONNY-6456 item 2).** `ClusterCoordinator.start` creates
  the intra-cluster QUIC listener itself and never set its
  dead-connection reap; `raft_consensus.Transport.listen`, the only code
  that did (`GEODE_RAFT_DEAD_CONN_REAP_MS`, default 30 s), is never called,
  so a connection from a peer that vanished without CONNECTION_CLOSE stayed
  open until the inbound idle deadline or the 300 s QUIC idle timeout. The
  production listener now uses the same reap budget. In addition, an
  inbound cluster connection handler that finished (peer gone, idle
  deadline, sweeper request, shutdown), and a connection dropped at accept
  because the connection limit or the worker queue was full, never closed
  the connection or removed it from the listener's tracked list: each one
  stayed tracked for the life of the process and the peer never received
  CONNECTION_CLOSE. They are now closed and untracked
  (`destroyConnection`). Regression:
  `zig build test-sonny6456-cluster-dead-conn-reap`.
- **Operator-visible: SIGTERM no longer stalls up to ~10 s before the final
  flush, and the default graph's periodic light checkpoint lands again
  (SONNY-6456 item 4).** The persistence loop and the final flush in
  `stopPersistenceThread` held the default graph's read lock while running
  the persistence checkpoint hook, which checkpoints through the storage
  adapter and so takes each graph's EXCLUSIVE lock. For the default graph
  it waited on its own thread's read lock until its 5 s deadline and
  skipped the graph: "bounded checkpoint skipped: rwlock busy past
  deadline graph=default rwlock_state=4294967296" on every persistence
  tick once the default graph held data, so its light checkpoint never
  ran while the server was up. At SIGTERM, stopping the persistence thread
  waited out the tick in progress and then the same deadline again
  (8.6 s measured on an idle server; SIGTERM-to-exit 10-12 s). The hook
  now runs holding no graph lock (the store lock still covers it when
  there is no adapter). The shutdown log gains "[shutdown] persistence
  thread stopped (<n>ms)" (13-17 ms idle). Regression:
  `zig build test-sonny6456-shutdown-persistence-stop`.
- **Operator-visible: on SIGTERM a cluster node stops its raft transport
  before the final flush and exits promptly (SONNY-6451 item 3).**
  `geode serve` stopped the `ClusterCoordinator` only in a defer that ran
  after "[shutdown] data flush complete", so the node kept leading or
  following (applying committed entries to the store) during and after the
  flush, its transport threads kept re-resolving peers, and the teardown
  then waited on inbound cluster handlers parked on a live peer's stream:
  "thread-pool deinit timed out after 2000ms with 2 active tasks", and the
  teardown watchdog force-exited the process 30 s later (orchestrators
  SIGKILLed it first). The coordinator is now stopped right before the full
  checkpoint, under the first-stage flush watchdog, and the log shows
  "[shutdown] cluster transport stopped (<n>ms)" before "[shutdown] data
  flush complete". Regression: `zig build test-sonny6451-cluster-sigterm`.
- **A cluster node keeps receiving raft traffic after its peers restart
  or move (SONNY-6451 item 1).** Raft frames ride one long-lived stream per
  peer, and the inbound handler on the receiver parked on that stream in a
  loop that only re-read it while it was quiet. A peer that went away
  without FIN or CONNECTION_CLOSE (a killed or force-exited process, a
  rescheduled pod whose old IP is gone) left the stream open, the QUIC
  library answers `WouldBlock` for it forever, and the RC1 idle reap, the
  RC-A occupancy sweeper and the shutdown flag were checked only between
  streams. Each such peer therefore held one of the receiver's 4 cluster
  connection workers for the life of the process; after four, the node
  serviced no inbound raft connection at all, so it never received the
  leader's appends while the leader logged "peer stalled ... evicting
  stale connection" over and over (the netns membership-churn M6-M8
  failures). The handler now gives a quiet stream up on shutdown, a closed
  connection, a sweeper request, or no frame for the inbound idle deadline
  (`GEODE_CLUSTER_INBOUND_IDLE_MS`, default 30 s; a live peer sends a
  heartbeat or response every ~50 ms), releases its worker and closes the
  connection; each frame refreshes the sweeper's activity clock. A raft
  sender whose connection the peer closed now rebuilds it on the next send
  instead of writing into it. Regression:
  `zig build test-sonny6451-raft-restarted-peer`.
- **The cluster health loop fails over only configured peers and keeps a
  failed peer's address (SONNY-6451 item 2).** `healthLoop` iterated
  `cluster_state.nodes` while `handleNodeFailure` `swapRemove`d the failed
  peer from it, so the same pass skipped the peer moved into its slot and
  read the vacated (`undefined`) slot as a node: the log's "Node detected
  as failed node_id=12297829382473034410" (0xAAAAAAAAAAAAAAAA), recorded in
  the health monitor and failed over. Removing the peer also dropped its
  endpoint from the address book for good (shard forwarding and
  `sendToNode` to it failed with `NodeNotFound` after it came back) and
  leaked the entry. A failed peer now stays in the list marked `failed`, is
  failed over once when it turns unhealthy, and is `active` again when it
  is heard from. Regression: `zig build test-sonny6451-health-failed-peer`.
- **The Python test runners fail a test that uses an undeclared secret
  (SONNY-6451 item 5).** `scripts/test/extended_test_runner.py` and
  `scripts/test/test_runner_core.py` substituted any `${secret:NAME}` other
  than `admin_password`, `user_password` and `api_token` that the spec's
  `secrets` section does not declare with `default-NAME`, a value nobody
  chose and one the password policy refuses for a password-named secret
  (so the test failed later with a misleading policy error). The test now
  fails at once with `UnknownSecretError` naming the secret. The
  fixture-secrets scan refuses a computed-name secret lookup with a
  fallback. Regression: `zig build test-sonny6436-fixture-secrets`.
- **`CALL db.relationshipTypes()` and `CALL db.propertyKeys()` omit what
  the session's RLS label policies hide (SONNY-6437 item 5).** `CALL
  db.labels()` omitted a denied label (SONNY-6351); the other two listed
  every type and key. A type is a table as a label is (SONNY-2710), so a
  denied edge type is omitted, and the keys of its edges; a node is hidden
  by a deny on any of its labels (SONNY-2690), so under a deny the keys are
  read from the visible nodes (the per-label key index lists a `:Pub:Sec`
  node's keys under `:Pub`). Regression: `zig build
  test-sonny6437-query-residuals`.
- **A WHERE after YIELD is refused with a message that names the ISO form
  (SONNY-6437 item 7).** `CALL db.labels() YIELD label WHERE ...` (a
  Cypher form) is not ISO/IEC 39075:2024 GQL: 16.14 `<yield clause>` is
  `YIELD <yield item list>` only, and a linear query (14.3) filters a call
  query statement (14.5) with a following filter statement (14.6, `FILTER
  [WHERE] <search condition>`). Both the statement-level `CALL` and `MATCH
  ... CALL` answer 42000 with that explanation; they answered 42000 "a
  statement ends at ';'..." and "expected token 'RETURN', got 'WHERE'".
  Geode does not yet accept a FILTER statement after `CALL ... YIELD`.
- **The `gql` executable's GROUP BY grouped every row on its own
  (SONNY-6437 item 3).** `exec.groupAndAggregate` freed each group's
  encoded key right after putting it in its group map, so the next row's
  lookup compared against freed bytes and missed. The map now owns the key
  (freed with the map); a row of an existing group frees its copy. Its sums
  were already checked (the unchecked `+=` was in `HashAggregator`, removed
  in SONNY-6436): a SUM or AVG past i64 range is NULL.
- **The 3-node cluster tests take their client and cluster ports from
  `tests/test_ports.zig` (SONNY-6450 item 2).**
  `test-cluster-replicable-mutations` and `test-cluster-steady-state`
  bound 127.0.0.11-13 on the fixed ports 3141 and 4242, so a second run on
  the host, or any geode on those ports, answered them. Each node keeps its
  own loopback address (the peer TLS certificate names them) and binds two
  free UDP ports chosen when the cluster starts. Both pass
  (9/9 and 3/3), and `docs/KNOWN_TEST_ISSUES.md` no longer lists
  `test-cluster-replicable-mutations` as an intentionally red timeout
  (SONNY-6450 item 1).
- **A stored property chain that holds the same key twice no longer leaks
  when it is read (SONNY-6450 item 6).** `getAllNodeProperties` /
  `getAllEdgeProperties` decode each entry of a chain into a map
  (`putDecodedProperty`), which copied the key and called `put`: for a key
  already in the map, `put` kept the map's key and overwrote the value, so
  the new key copy and the earlier value (a string's or an extended value's
  bytes) were never freed. The later entry's value is still the one kept,
  and the earlier one is now freed; a later null (the REMOVE tombstone)
  still removes the key. Regression: `zig build
  test-sonny6450-ownership-residuals` (3/3, 0 leaks; was 2 pass, 1 fail,
  9 leaks).
- **A member read (`n.p`) has one ownership, and every projection path owns
  the values it builds from it (SONNY-6449, SONNY-6450 items 3-5,
  SONNY-6437 items 1, 2, 6).** A read of an FLE-encrypted field returned a
  decrypted or redacted string the evaluator allocated, a plain field the
  store's bytes, and a list property a copy: callers could not tell which.
  The legacy RETURN projection, the WITH stage, `executeReturnClauseWithNodes`
  (CREATE / MERGE ... RETURN), the GROUP BY keys, the HAVING, both ORDER BY
  comparators and VALUES ... MATCH kept those values in rows they do not
  free, so each row leaked (a decrypted string, a list copy, a list
  comprehension's lists, a concatenation, an `upper()`), and the ORDER BY
  comparators leaked per comparison. Now: every executor entry point
  (`executeStatementWithContext`, `executeProgramWithContext`) runs with a
  scratch arena, the transport's or, for an embedded caller, one it opens
  (`query_arena.StatementScratch`) and copies its result out of before it
  closes it; a member read's copy and a list comprehension are lent from it
  (`eval.lentValueAllocator`) and never freed by a caller; the projections
  evaluate their items on it (`value_utilities.lentAllocator`) and the final
  projection copies every value (nothing is adopted while a scratch arena is
  installed: `upper(max(n.s))` computed on the arena was adopted and freed
  with the result's allocator); the GROUP BY keys and both ORDER BY
  comparators evaluate on an arena of their own, once per row. The
  engine-direct node scan (QUIC's single-label RETURN), whose cells own
  every value they do not copy out of their node, evaluates with nothing
  lent (`eval.evalExprNothingLent`). Leak-checked
  for plain and FLE-encrypted fields on every path (RETURN, DISTINCT, GROUP
  BY, ORDER BY, WITH, WITH DISTINCT, WITH ORDER BY, VALUES ... MATCH, CALL
  ... YIELD ... RETURN, CREATE / MERGE ... RETURN, list properties, list
  comprehensions, the engine-direct node scan), in memory and persisted, with and without a request
  scratch arena: `zig build test-sonny6449-projection-value-ownership` (9/9; was
  0/8; e.g. `RETURN n.ssn` leaked 3 allocations, `RETURN [y IN n.v | y]` 12,
  a persisted embedded read 39). An embedded caller's result is copied once
  more when the statement used its scratch arena (its nodes and
  relationships included, as the gRPC server copies a kept result).
- **`test-startup-lazy-hydrate` finishes in under a minute instead of
  running past 25 (SONNY-6433 item 9).** Every one of its 47 tests opens,
  writes (one fsync per commit), checkpoints, crashes or closes, and reopens
  a persisted store under `.zig-cache/tmp`; on a loaded host's shared disk
  each took 15 to 170 seconds and the run reached test 41 of 47 at the
  25-minute cap (the 3,000-node GAP-ENT-0048 seeding tests alone took
  minutes each), so its last tests, and those of its `-tsan` companion,
  never ran. Each test's data directory now lives on tmpfs (`/dev/shm`) when
  the host has one, as the write harness's do (SONNY-6333), and is removed
  with the test's scratch directory; the storage code paths and the
  assertions are unchanged. 47/47 in 38 s (was 40/47 at 1,500 s). The TSan
  companion now runs to completion (see `docs/KNOWN_TEST_ISSUES.md`).
- **An undirected edge pattern is refused with 0A000 and a message that
  says so (SONNY-6433 item 8).** ISO/IEC 39075:2024 16.5 / 16.7 spell an
  undirected edge `~[ ]~` (and `~`, `<~[ ]~`, `~[ ]~>`, `<~`, `~>`), Feature
  GH02, which Geode does not support: it stores directed edges only. The
  lexer has no `~` token, so `CREATE (a:W)~[:T]~(b:W)` was refused with
  42000 "a statement ends at ';' or at the end of the request; this clause
  cannot follow the one before it". CREATE, INSERT and MATCH now answer
  0A000 (feature not supported) with "undirected edges are not supported
  ..." and the directed alternatives. `=~` and `!~` are unchanged.
  Regression: `zig build test-sonny6433-undirected-edge-message`.
- **The ordered-index read paths hold the graph locks they need (SONNY-6433
  items 6, 7, 10).** (6) The planner gates `isOrderedIndexRegistered`,
  `isOrderedIndexEligible` and `isOrderedIndexFresh` read each shard's
  ordered-index registry, eligibility and freshness with no lock while
  `createOrderedIndex` (CREATE INDEX, the ORDER BY auto-build's background
  worker) changes them under the graph lock SHARED and the shard's lock
  EXCLUSIVE, and the full checkpoint under the graph lock EXCLUSIVE. They
  now pin the graph and read under `mg.rwlock` SHARED (unless the thread
  already holds the graph lock) and each `shard_locks[i]` SHARED, in the
  order `createOrderedIndex` takes them. (7) `orderedScan` resolved its
  graph with no pin and lets its locks go between batches, so a DROP GRAPH
  between two batches freed the graph the next batch read (a segmentation
  fault in the regression test). The scan now pins the graph for its whole
  run and fails with `GraphNotFound` when a batch finds it dropped (the
  planner then serves the heap path), the discipline of the graph-lock API
  (SONNY-3028). (10) The per-thread table of held graph locks had 16 slots,
  and past them every graph counted as held, so an ordered scan of a graph
  the thread had not locked read it with no graph lock. The table now grows
  (the room is reserved before a lock is taken, so recording it cannot
  fail; an acquisition that cannot get the room fails with out of memory
  before locking), and a graph the thread does not hold is never reported
  as held. Regression: `zig build test-sonny6433-ordered-index-locking`.
- **A member read of a string property (`n.p`) no longer leaks a copy per
  row (SONNY-6433 item 5).** SONNY-6327 routed every string read through the
  FLE read policy and made the member access (`memberOfValue`) return a copy
  of the stored bytes even when nothing was decrypted. A member value is
  borrowed by contract (`value_utilities.evaluatesFresh`): the final
  projection duplicates it (GAP-0535) and an ORDER BY compares it without
  freeing it, so the copy leaked on every row a projection or sort
  evaluated without a per-query arena (12 allocations in
  `test-sonny2653-planned-read-ext-read-leak`'s `RETURN a.s, r`). A member
  read now returns the stored bytes when the policy passes them unchanged,
  as before SONNY-6327; a decrypted or redacted string is still a fresh
  copy. Regression: `zig build test-sonny2653-planned-read-ext-read-leak`.
- **A cluster follower drops replaced or removed text from its fulltext
  indexes, as the leader does (SONNY-6433 item 3).** The fts engine cannot
  take words out of a document, so the executor queues every covering index
  for a rebuild when a SET replaces indexed text or a REMOVE drops it and
  rebuilds it at the statement's end (SONNY-6368, SONNY-6421). A follower
  applies the committed GUPD / GMRG entry with the store mutators and the
  FTS apply hook's upsert only: it appended the new text and kept answering
  `geode.fts.search` for the old words. The apply functions now report text
  a node lost (`cluster_replication.FtsApplyTextHooks`, registered by
  `fts_index_ops.registerFtsApplyHook`) and end each applied entry with the
  same flush, on the apply thread (a follower's only writer).
  `docs/FULLTEXT_SEARCH.md` is updated, and `tests/test_fts_apply_symmetry.zig`
  now expects the old term gone on the apply path. Regression: `zig build
  test-sonny6433-follower-fts-rebuild`.
- **BREAKING (query): a MERGE with a null key is refused (22004); a
  list-valued MERGE key matches by value; `FOR u IN [...] CREATE ... RETURN
  u` returns `u` (SONNY-6433 item 2, the SONNY-3245 remainder).** A null
  property value is absent (SONNY-3245, CREATE and SET) and `k = null` is
  never true (ISO/IEC 39075:2024 19.3), so `MERGE (n:L {k: null})` can match
  nothing; it created a node without `k` on every run. A MERGE whose node or
  relationship pattern gives a property the null value (a literal, a
  parameter, an expression such as `1 + null` or an unbound `m.v`) is now
  refused with 22004 (null value not allowed) and writes nothing, in a later
  MERGE clause too, and over QUIC's bulk MERGE fast paths, which answered
  58000 and still applied the other statements of a `/*+BATCH*/` run. Use a
  key with a value, or CREATE. A stored list reads back as an extended list
  and never compared equal to a list literal or parameter, so `MERGE (n:L
  {k: [1, 2]})` made a duplicate on every run (and `MATCH (n {k: [1, 2]})`
  found nothing); lists now compare element by element
  (`value_equality.valuesEqual`). `FOR u IN [1, 2] CREATE (...) RETURN u`
  evaluated its RETURN with none of the statement's parameters, where the
  FOR binds `u`, and returned nulls (`executeReturnClauseWithNodes` now takes
  them; MATCH ... CREATE ... RETURN too). `docs/ENTERPRISE_GAPS.md` (GAP-0926)
  is updated. Regression: `zig build test-sonny6433-merge-keys`,
  `test-sonny6433-merge-null-key-quic`.
- **`keys()` and `properties()` no longer list a property that `REMOVE` or
  `SET ... = null` took away (SONNY-6433 item 1).** Removing a node
  property writes a null tombstone into its stored property chain
  (`StorageAdapter.removeNodeProperty`), and `getAllNodeProperties` /
  `getAllEdgeProperties`, which every read that
  rebuilds a node or relationship from storage goes through (a bounded
  cache's hydrate, the planned read, the node-scan stream), copied the
  tombstone into the property map: `n.p` read null while `keys(n)` and
  `properties(n)` still listed `p`. A tombstone now takes the property out
  of the map (ISO/IEC 39075:2024 13.4: the property is removed from the
  element's property set). Regression: `zig build
  test-sonny6433-keys-after-remove`; `test-sonny3245-create-merge-forms`
  now asserts `keys()` after `SET n.p = null` too.
- **`zig build test-graph-store` and `zig build test-compile` compile again
  (SONNY-6433 item 4).** SONNY-6422 made the storage adapter check the
  audit signing keys (`AuditLogger.loadEnvSigningKey`), which reaches
  `src/security/audit.zig` and its `@import("rls")`. Three modules compile
  the adapter as their own source and had no `rls` import: the
  `graph_store` module (`test_graph_algorithms.zig`,
  `test_point_read_view_zero_copy.zig`,
  `test_point_read_view_mutation_invalidation.zig`) and the `graph_store.zig`
  and `eval.zig` inline-test roots (`test-graph-store`, `test-gap0866`), so
  those five artifacts, and with them `zig build test-compile` and the
  aggregate `zig build test`, failed to compile. They now import it.
  `tests/test_process_args.zig` still asserted that `serve --no-auth`
  disables authentication in a Debug build, through the `enable_auth` field
  SONNY-6329 removed; it now asserts the flag is refused
  (`NoAuthUnsupported`) in every build mode. All 829 `test-compile`
  artifacts and the artifacts of the named steps outside the aggregate
  compile.
- **TDE overhead is measured, not simulated, and no doc claims "<1%" or
  "<5%" (SONNY-6435 item 2).** `benchmarks/benchmark_tde_overhead.zig` (the
  `zig build bench` member) hashed a buffer with Wyhash and reported
  `overhead_pct=0.00 (simulated)`, `benchmarks/benchmark_tde_oltp_overhead
  .zig` was built by no step and simulated TDE too, and
  `src/security/test_tde_enforcement.zig` asserted `5 <= 5` under "TDE
  documentation claims <1% overhead"; all three are gone. `zig build
  test-sonny6435-tde-overhead` (also in `bench`) runs the storage engine
  geode opens every graph with, ReleaseFast, on the same insert-and-read
  workload with page and WAL encryption off and on, interleaved perf_gate
  batches, and asserts the encrypted arm writes no plaintext. Measured
  2026-11-12: +0.7% with the default per-commit fsync (four runs -1.3% to
  +0.7%, fsync-bound on that host), +19.5% to +21.0% (three runs) on the
  commit path without fsync. README, BENCHMARK_REPORT, FEATURES_OVERVIEW, TODO,
  SERVER_FEATURES, KMS_PROVIDER_SYSTEM, DESIGN_TDE_KMS, SECURITY_PROGRESS
  and the perf audit context now give those figures
  (`docs/TDE_FILE_LEVEL_ENCRYPTION.md` "Measured overhead"). Reads that miss
  the buffer pool are not measured: with a pool smaller than the store the
  encrypting graph_storage 0.4.10 engine loses committed nodes
  (`test-sonny6435-tde-small-pool-node-loss`, intentionally red).
  Regressions: `zig build test-sonny6435-tde-claims-truth`,
  `test-canary-tde-published-overhead-sync` (now requires the measurement
  to be cited).
- **The compose files and the deployment docs give geode only settings it
  reads (SONNY-6435 item 5).** The compose files passed geode `LOG_LEVEL`,
  `RUST_BACKTRACE`, `VAULT_ADDR` / `VAULT_TOKEN`, `REDIS_URL`, `FIPS_MODE`,
  `GPU_ENABLED`, `GEODE_LOG_JSON`, `GEODE_CERT_PATH` and, in
  `docker-compose.distributed.yml`, `NODE_*` / `RAFT_*` / `CLUSTER_*` /
  `GEODE_DISTRIBUTED` / `GEODE_SHARD_COUNT` / `GEODE_REPLICATION_FACTOR`
  plus Raft options `geode serve` does not have (it ignores unknown
  options), so the "cluster" was three standalone nodes. They are gone; the
  log level is now passed as `--log-level`, and the distributed file says
  it is not a cluster and names the real `GEODE_CLUSTER_TOKEN` /
  `GEODE_PEERS` / `GEODE_NODE_ID` variables. `docs/SERVER_FEATURES.md` 7.1
  (XTS-AES pages, a derived key hierarchy), 7.2 (Vault / AWS / Azure / GCP
  KMS providers, rotation) and Appendix B (`CDC_*`, `GEODE_LISTEN_*`,
  `GEODE_TLS_*`, `GEODE_MFA_ENABLED`, `GEODE_KMS_PROVIDER`, a sectioned TOML
  file) now describe AES-256-GCM pages under `GEODE_TDE_KEY`, no KMS key
  source and the flat config keys `geode serve` reads;
  `docs/DOCKER_OVERVIEW.md` drops 17 `GEODE_*` variables nothing reads, the
  Vault-backed TDE and cluster examples and `--gpu-acceleration`, and lists
  the real cluster variables; `docs/TDE_FILE_LEVEL_ENCRYPTION.md` no longer
  points to automated key rotation; `docs/NIX_DEPLOYMENT.md` uses
  `GEODE_ENV` and `--log-level`. Regression:
  `zig build test-sonny6430-deploy-docs-truth`, which now also fails when a
  compose file's environment or one of those docs names a `GEODE_*`
  variable no source file reads (a quoted literal in `src/**/*.zig` or
  `$NAME` in `docker/*.sh`).
- **The MATCH ... MERGE edge fast path resolves its endpoints for the
  request's tenant (SONNY-6447 item 6).** `executeBulkMatchMergeEdge`
  resolved both endpoints with no tenant
  (`lookupPublicNodeIdByLabelAndAllProps`) and was safe only because the
  session gate (`bulk_ingest.sessionAllowsKeyResolvedWrites`) sends every
  tenant-scoped session to the executor. It now calls
  `lookupPublicNodeIdByLabelAndAllPropsForTenant` with the request's
  tenant: an unscoped request is answered as before; a scoped one gets the
  sole matching node only when it is that tenant's, a miss when the sole
  match is another tenant's, and a decline (`MergeKeyNotUnique`, the
  executor answers) when several nodes match. Another tenant's node is never
  an endpoint, whatever gate the caller passed. No behaviour changes today
  (the gate still declines scoped sessions). Regression: `zig build
  test-sonny6429-sole-holder-tenant-wire`.
- **`geode query --file` over QUIC stops, with the summary, when the retry
  of a rejected chunk cannot connect (SONNY-6447 item 7).** When the server
  rejects a chunk, the CLI retries its statements one at a time on one new
  connection. When that connection or its HELLO failed, the run printed
  `Error retrying chunk statement-by-statement`, counted one error and went
  on with the next chunk, so the rejected chunk's statements were silently
  dropped and later chunks that may depend on them were sent. It now prints
  that the retry could not start, how many statements from that chunk on
  were not executed, and the chunked summary, and exits with
  `general_error`, as every other transport failure of a chunked run does.
  Regression: `zig build test-sonny6447-quic-retry-connect-stops` (a real
  server and CLI, with a UDP forwarder that drops the retry's connection).
- **The netns cluster scripts run their nodes as the invoking user and say
  when a node they killed survives (SONNY-6447 items 2 and 9).**
  `tests/cluster/netns_cluster_replication_test.sh` and
  `netns_cluster_membership_churn_test.sh` ran every node as
  `${SUDO_USER:-$(id -un)}`; a `SUDO_USER` left in the environment by an
  outer session (an ansible become) named a user that cannot reach the work
  directory, and no node started ("Permission denied"). `SUDO_USER` is now
  used only when the script itself runs as root under sudo. The churn
  script's `kill_and_reap` matched `sudo pkill -9 -f` against its own
  command line (it SIGKILLed its own sudo, whose pty hang-up can end pkill
  before it reaches a geode with a higher pid once pids wrap) and went on
  silently when a process survived; the pattern no longer matches itself,
  and a survivor fails the phase by name instead of surfacing only as the
  replacement's (correct) `DataDirLocked`. The data-dir lock itself needed
  no change: it is a kernel `flock` on an `O_CLOEXEC` descriptor and no
  geode process spawns children, so the lock ends with the process however
  it dies; `zig build test-datadir-lock-subprocess` now also covers a
  SIGABRTed holder (a panic ends in abort) and a frozen, live one (still
  refused).
- **Lean indexing registers and indexes every MERGE key, the 65th included
  (SONNY-6447 item 3).** With `GEODE_INDEX_MERGE_KEYS_ONLY=1` the
  registered-key set was a fixed table of 64 keys of at most 128 bytes, and
  `registerMergeIndexKey` dropped a 65th (or longer) key silently, although
  its comment said such a key fell back to being indexed. The key was then
  never indexed: `lookupMergeCandidate` answered `.not_indexable` for it for
  the life of the process, and the server's bulk MERGE fast path refused
  every MERGE on it (`MergeValueNotIndexable`). The set now grows (a map of
  owned keys under the same leaf mutex), so every MERGE key is registered.
  The `merge_index_keys.dat` sidecar keeps keys of any length (a key with a
  line break is not persisted and registers again at its first MERGE, as a
  late key), and its load cap is 1 MiB instead of the old table's size.
  Regression: `zig build test-sonny6447-lean-key-overflow`.
- **The MATCH ... MERGE edge fast path declines a composite endpoint key
  two nodes hold, and no merge lookup answers "no node holds it" for a key
  lean indexing left out of MERGE's index (SONNY-6436 items 2-3).**
  `lookupPublicNodeIdByLabelAndAllProps` resolved a registered composite
  merge key (the from-dump `{source, source_id}`) to the lowest of the
  nodes holding it, so `MATCH (a:L {k: 1, s: 'x'}), (b:...) MERGE
  (a)-[:R]->(b)` over two such nodes MERGEd one edge where the executor
  MERGEs one per node; only the key's sole holder answers now
  (`GraphStore.lookupOnlyCompositeMergeHolder`), and more declines to the
  executor. With `GEODE_INDEX_MERGE_KEYS_ONLY=1`, `lookupMergeCandidate`
  answered a key no MERGE registered as held by no node; it now answers
  that the index cannot know (`.not_indexable`), as
  `lookupOnlyMergeHolder` does since SONNY-6429. `lookupNodeByMergeKey[ForTenant]`
  report that as `error.MergeKeyNotUnique` (decline) instead of "not
  found", and `bulkInsertEdge` resolves endpoints as the MATCH ... CREATE
  edge fast path does (`lookupSoleNodeByMergeKey`), so it declines instead
  of skipping the edge. The executor's MERGE probes that run before the
  key is registered (`preResolveMergeNode`, `clusterReplicateMerge`) now
  fall back to the label scan for such a key instead of taking the index's
  miss as authoritative. Regression: `zig build test-sonny6429-sole-holder-tenant-wire`
  (in process, and over QUIC with group commit on and off and with lean
  indexing).
- **The Python test runners' default user password and the Zig client
  example's password meet the password policy (SONNY-6447 item 8).**
  `scripts/test/extended_test_runner.py`, `test_runner_core.py` and
  `parallel_test_runner.py` defaulted `${secret:user_password}` to
  `UserPass123!` / `password123`, which CREATE USER refuses, and
  `clients/zig/example_minimal.zig` set the one-word
  `GeodeTestPassword123!`; they are now `Geode Test User Passphrase` and
  `Geode Example Client Passphrase`. `zig build
  test-sonny6436-fixture-secrets` now also scans `clients/` (including a
  Zig source's `password = "..."` field) and the runners' `user_password`
  defaults.
- **The in-repo scripts and fixtures seed an HMAC key and admin passwords
  the server accepts (SONNY-6436 item 1).** The netns cluster scripts
  (`tests/cluster/netns_cluster_replication_test.sh`,
  `netns_cluster_membership_churn_test.sh`) passed a
  `GEODE_AUTH_HMAC_KEY` that is not 64 hex characters, so no node started;
  they now generate one with `openssl rand -hex 32`. They, the
  `scripts/` helpers and Python test runners (default
  `geode-test-password`), `scripts/perf-gate.sh`, the gap0894 repro, the
  OTel compose stack (`make otel-compose-up`,
  `scripts/otel-compose-verify.sh`: a bare random hex string) and three
  `tests/` scripts seeded an admin password the password policy refuses,
  which forces a reset at the first login, so every later query of the
  script failed; each now seeds a passphrase (the generated OTel one is
  wrapped in words), and the scripts quote it where it is passed on. The
  default of the runners' `admin_password` secret is now `Geode Test
  Admin Passphrase`, as in `tests/proto_test_util.zig`. Regression:
  `zig build test-sonny6436-fixture-secrets` scans tests/**, scripts/**,
  deployment/**, docker-compose* and the Makefile.
- **Deployment config and docs describe only settings the server has
  (SONNY-6430 item 9).** `docker-compose.yml`, `docker-compose.dev.yml` and
  `docker-compose.gpu.yml` passed `S3_ENDPOINT` / `S3_ACCESS_KEY` /
  `S3_SECRET_KEY` / `S3_BUCKET` to geode, which reads none of them.
  `docs/SERVER_FEATURES.md` 1.3 named `GEODE_DISK_KEY_HEX`, XTS-AES, a key
  hierarchy, Vault / AWS KMS integration and automatic rotation; the key is
  `GEODE_TDE_KEY` (AES-256-GCM pages and WAL), with no KMS source and no
  rotation, and Appendix B no longer lists `GEODE_DISK_*` / `GEODE_WAL_*`
  variables nothing reads. `docs/NIX_DEPLOYMENT.md` now says the Nix
  packaging was removed (commit `6d7d71dd`) and drops its federation
  blocks; `docs/audit/security-phase1-inventory.md` names `GEODE_TDE_KEY`,
  not `GEODE_WAL_KEY`, as the WAL key. Regression:
  `zig build test-sonny6430-deploy-docs-truth`.
- **`geode storage verify` checks the server's data directory, and `geode
  migrate create` refuses to write an unsigned migration without a key
  (SONNY-6430 items 6 and 8).** `storage verify` used the in-memory store
  `getGlobalStore` gives with no `GEODE_DATA_DIR` (it ignored
  `--data-dir`), printed PASS for nothing, and its verbose form exited 0
  when the check failed. It now opens the directory `geode serve` opens
  (`--data-dir`, else `GEODE_DATA_DIR`, else the per-user default), names
  it, takes the data directory's lock, reports the node count, and exits 1
  on any failure. `migrate create` with no `GEODE_MIGRATION_HMAC_KEY` and no
  `.hmac_key` wrote an unsigned file and exited 0, although its help said
  the key is required (SEC-MIG-03); it now exits 1 and writes nothing, and
  `--no-sign` is the explicit way to create an unsigned file. A file whose
  signing fails is removed. Regression:
  `zig build test-sonny6430-cli-fail-closed`.
- **`geode backup create --server` bounds the whole transfer by `--timeout`
  (SONNY-6430 item 1, partial).** Each 64 KiB chunk of a remote backup had
  a fixed 30 s wait of its own, whatever `--timeout` said, so a backup that
  stalled failed after 30 s and one that only progressed slowly had no
  overall bound. `--timeout` (default 300 s) now bounds the server's answer
  and every byte of the file, and a timeout reports how many of the
  announced bytes arrived. The stall itself, a backup of about 24 MB
  stopping after 11-14 MB in the vendored QUIC library's ACK processing,
  is fixed by quic v0.1.49 (SONNY-6434, below):
  `test-sonny6430-remote-backup-large` passes and is in the aggregate.
- **BREAKING (query results): a WHERE, FILTER or HAVING keeps a row only
  when its condition is the Boolean True (SONNY-6425 item 1).** ISO/IEC
  39075:2024 19.1 `<search condition>` General Rule 2 ("satisfied if and
  only if the result of the `<boolean value expression>` is True") and 16.13
  `<where clause>` General Rule 2b (a record is kept "If INCLUDE is True").
  The single-node MATCH (label scan, point read, hop, multi-chain, OPTIONAL
  MATCH), FILTER, WITH ... WHERE, GROUP BY ... HAVING, UNWIND ... WHERE, CALL
  ... WHERE, planned-read and streamed node-scan paths took a non-zero
  integer as true; the initial-WITH dispatcher (SONNY-3184) and a cluster
  leader's MATCH ... SET did not. Every site now keeps a row only for True.
  **What changes:** a statement whose WHERE / FILTER / HAVING evaluates to a
  non-zero integer, for example `MATCH (n) WHERE n.count RETURN n`,
  `MATCH (n) FILTER n.flag RETURN n` with an integer `flag`, `... GROUP BY
  n.k HAVING count(*)`, or `MATCH (n) WHERE n.a SET n.b = 1`, returned (or
  wrote) those rows and now returns (writes) none, on a single node as on a
  leader. Conditions that are Boolean (`n.count > 0`, `n.flag = 1`,
  `count(*) >= 1`), null, strings and zero are unchanged. ISO's Syntax Rule 3
  (a non-Boolean predicand is a type error) is not enforced: such a condition
  keeps no row rather than failing. Regression:
  `zig build test-sonny6425-where-truthiness`.
- **A cluster leader's MATCH ... SET answers a failing WHERE or SET
  expression's own error (SONNY-6425 item 2).** It answered 40001
  (`ClusterWriteNotReplicable`, which asks the client to retry, and no retry
  can succeed) where a single node answers the expression's error (for
  example `DivisionByZero` for `SET n.e = n.a / n.z` with a zero `z`).
  Nothing is proposed either way. Regression: `zig build
  test-sonny6425-where-truthiness`.
- **`CALL db.labels()`, `db.relationshipTypes()`, `db.propertyKeys()` and
  SHOW TABLES list the data after the store is reopened (SONNY-6425 item
  3).** After an open, a graph's resident structures (including the
  per-tenant label, type and property-key counts) are built on first touch;
  these procedures read a snapshot of the store, which copied only what was
  resident, so until a MATCH touched the graph they listed nothing, for every
  session. The snapshot now hydrates the graphs it copies first
  (`QueryReadSession.initScoped`). Regression: `zig build
  test-sonny6425-tenant-listings-reopen`.
- **A one-node CREATE commits one storage-engine transaction (SONNY-6425
  item 4).** The statement transaction and the node were placed on shards
  round-robin from the same counter, so the node always landed on another
  shard: its record and each property committed on their own (3 to 6 commits,
  each a WAL fsync, for one `CREATE (:L {a: 1, b: 2})`). With a statement
  transaction open, `StorageAdapter.createNode` now allocates the node on
  that transaction's shard. Regression: `zig build
  test-sonny6425-create-one-shard-commit`.
- **`GraphStore.dropGraph` refuses (`ObjectInUse`) when the calling thread
  holds the graph's read lock (SONNY-6425 item 5).** Since SONNY-3135 the drop
  takes the graph's write lock, and a thread holding the read lock waited for
  itself forever (no caller does this today). The adapter records the read
  locks each thread holds through `acquireGraphReadLock`. Regression: `zig
  build test-sonny6425-drop-under-own-read-lock`.
- **`geode query --grpc --file` stops with its summary when a statement it
  retries on its own gets no answer after it was sent (SONNY-6425 item 6).**
  A rejected chunk is retried statement by statement; on gRPC a statement
  whose client timed out, or whose connection failed after it was sent,
  exited the process with no "Chunked execution complete" summary. It is not
  sent again, the run stops, and the summary and the count of statements not
  executed are printed, as for a chunk (SONNY-6384). Exit code 1 (as before).
  Regression: `zig build test-sonny6425-grpc-retry-summary`.
- **`geode query --file` over QUIC stops with its summary when a statement
  it retries on its own gets no answer (SONNY-6436 item 7).** The QUIC
  retry runs a rejected chunk's statements over one connection; when one of
  them timed out or its connection failed, it returned the error, and the
  run went on with the NEXT chunk on a new connection: statements were
  written after one that may still be running or have been applied, and the
  rest of the chunk was silently dropped (counted as one error). The run
  now stops there, as the gRPC retry does: the statement is not sent again,
  the summary and the count of statements not executed are printed, and it
  exits 4 for a client timeout, 1 otherwise. A failure before the statement
  was sent says so (it was not executed) and also stops the run (exit 1).
  Regression: `zig build test-sonny6436-quic-retry-stops`.
- **Documented: cluster data written before SONNY-2726 stays tagged
  `default` (SONNY-6425 item 9).** The writer's tenant was never recorded
  (the raft entries carried none), so geode cannot re-tag it; the operator
  procedure (read the rows as admin, write them again from a session of the
  right tenant, delete the old copies) is in `docs/MIGRATION_GUIDE.md`.
- **A write inside an explicit transaction no longer crashes the server,
  and the MATCH ... CREATE / MATCH ... MERGE edge fast paths answer and
  write what the executor does (SONNY-6429 item 1).** The process-global
  transaction undo log kept the allocator of whichever call first touched
  it; in the server that could be a per-query scratch arena, so after an
  autocommit executor write the first statement inside `BEGIN` that recorded
  undo entries called through a reset arena and the server died with a
  segfault (`txn_undo_log.getGlobalUndoLog` now allocates from the process
  allocator in the server). The MATCH ... CREATE edge fast path answered no
  columns and no row where the executor answers its summary row
  (`nodes_created`, `relationships_created`); it now sends `0`, `1` when it
  wrote the edge (and, as before, nothing when an endpoint is missing, as
  the executor). The MATCH ... MERGE edge fast path took the first of
  several nodes an endpoint's properties match and MERGEd one edge where the
  executor MERGEs one per matched pair; it now declines such a statement to
  the executor. Under lean indexing (`GEODE_INDEX_MERGE_KEYS_ONLY=1`) the
  MATCH ... CREATE edge fast path's sole-holder lookup answered "no holder"
  for a key no MERGE had registered, so the edge was silently not created;
  such a key now declines to the executor. The tenant-scoped lookup
  (`lookupSoleNodeByMergeKeyForTenant`) never answers another tenant's node.
  Regression: `zig build test-sonny6429-sole-holder-tenant-wire`.
- **Docs no longer present S3 / DigitalOcean Spaces as a backup target or
  the removed TDE-KMS integration as current code (SONNY-6422 item 9).**
  No command reaches object storage (SONNY-6290; real support is story
  SONNY-6356), yet `docs/TODO.md` listed "S3 Cloud Backup: Production-ready
  with Digital Ocean Spaces integration", `docs/GQL_COMPLIANCE.md` said
  `geode backup create` had S3 / Spaces upload targets,
  `docs/SERVER_FEATURES.md` §1.4 described `s3_backup.zig` multipart uploads,
  incremental and point-in-time backups and their throughput,
  `docs/DOCKER_OVERVIEW.md` listed `S3_*` variables as geode's backup
  endpoint (geode reads none of them), and `docs/NIX_DEPLOYMENT.md` showed a
  `backup.s3Bucket` option no module defines. They now describe local backup
  files. `specs/security/field-level-enc-research-report-pqc-PR.md` cited
  `tde_kms_integration.zig` and its test as current; it carries a note that
  both were never compiled and were removed (SONNY-6298). Regression:
  `zig build test-sonny6422-backup-docs-truth`.
- **`geode backup create --server` prints each 10% progress step once
  (SONNY-6422 item 8).** `executeRemoteBackup` printed `Progress: N%` after
  every received chunk that left the running percentage on a multiple of 10,
  so a backup received in many 64 KiB chunks repeated lines (a 10 MB backup
  printed 22 lines, 11 of them repeats), and a chunk that crossed a step
  without landing on its exact multiple printed nothing. It now prints each
  reached step once, in order, ending with `Progress: 100%`. Regression:
  `zig build test-sonny6422-remote-backup-progress`.
- **The phantom check looks a transaction's read ranges up once per commit
  (SONNY-6422 item 7).** `Manager.detectPhantoms` called
  `RangeTracker.keyInRanges` for every write committed since the transaction
  began, and each call looked the transaction's range list up in the
  tracker's hash map again, so a transaction with no range reads paid one
  hash lookup per concurrent write. The list is now looked up once
  (`RangeTracker.rangesFor`), and with no ranges no write is checked.
  Measured with `zig build test-sonny6422-phantom-check-once-per-commit`
  (Debug, perf_gate interleaved medians, 4096 committed writes in the
  history): the no-range check went from 738,793 ns to 220 ns and stays flat
  from 64 to 4096 writes (64.8x growth before, 0.97x after); the per-write
  cost of a check with two read ranges went from 334.6 ns to 90.9 ns. The
  `test-canary-txn-phantom-range` / `-anomaly` benchmarks commit no
  concurrent writes, so their overhead figures are unchanged within noise
  (0.61 / 0.60 before, 0.68 / 0.67 after on the same loaded host).
  Detection is unchanged: a write inside a read range still fails the commit.
- **A CLI command fails on a data directory it cannot open instead of
  working on an empty in-memory store (SONNY-6422 item 6).** A command that
  reached the store through `getGlobalStore` with a data directory
  (`GEODE_DATA_DIR`) but no `initGlobalStore` opened the storage adapter in
  `graph_store.syncGlobalAdapterForDataDir`, and when that failed logged a
  warning and carried on in memory: `geode storage verify --check
  graph_store` printed `{"graph_store_ok":true,"node_count":0}` for a
  directory it never opened. That path now exits 1 with `Error: cannot open
  the data directory <dir> (<reason>); refusing to continue on an empty
  in-memory store.` The offline auth, API-key and tenant commands
  (`initCliAuthManager`) fell back the same way when `initGlobalStore`
  failed; they now report the directory and the error and change nothing.
  Regression: `zig build test-sonny6422-cli-data-dir-fail-closed`.
- **BREAKING (query): invalid CREATE / INSERT patterns are refused, a path's
  unnamed middle node is one node, `<-[:R]-` after a MATCH points left, and
  a null property value is absent (SONNY-3245).** Per ISO/IEC 39075:2024
  16.5, these now fail with `42000` (`InvalidInsertPattern`) and change
  nothing: a MATCH-bound variable given a label or property in CREATE
  (`MATCH (n) CREATE (n:Extra)` did nothing; `CREATE (n {extra: 1})`
  changed the matched node; use `SET`), a later occurrence of a variable
  given a label or property (`CREATE (a:R), (a:R)` made two nodes), an
  undirected inserted edge `-[:T]-` (stored a directed one) and several
  types `[:T|U]` (stored a T edge). `CREATE (a)-[:R]->(:M)-[:S]->(b)` made
  two M nodes, so the path did not exist; it makes one (standalone CREATE,
  INSERT, MATCH ... CREATE and the cluster-replicated CREATE). After a
  MATCH, `(a)<-[:R]-(b)` was stored a -> b; it is stored b -> a. `CREATE (n
  {p: null})` stored p and `SET n.p = null` kept it with a null value; a
  null value now leaves the property absent (nodes and relationships).
  Still open: MERGE on a null key creates a node, MERGE on a list key
  never matches, and `FOR u IN [...] CREATE ... RETURN u` returns null for
  `u`. Regression: `zig build test-sonny3245-create-merge-forms`.
- **An index-served read no longer waits for an exact-index build
  (SONNY-6362 item 6).** While a deferred build or a late-key catch-up of a
  graph's exact node-property index held its build mutex (an O(graph)
  scan), every property-equality seek on the graph
  (`getCandidateNodesByLabelAndProperty`, `countCandidateNodesByLabelAndProperty`,
  `collectPropertyPostingSummaries`) parked on it. They now answer
  `ExactIndexBusy` at once and their callers serve the read from a scan; a
  read finding the mutex free still builds the index itself. The MERGE
  resolver and the write paths still wait for the build. Regression:
  `zig build test-sonny6362-exact-index-read-fallback`.
- **Full-text and vector indexes follow `REMOVE n:L` and a `SET` that
  replaces indexed text; an undo repair survives a background vector
  rebuild (SONNY-6421).** `REMOVE n:L` called the store alone, so a
  full-text search still found the node by L's index and L's vector index
  still held it: it now rebuilds the vector indexes on L and queues every
  full-text index on L holding text of the node for a rebuild at the end of
  the statement, and `geode.fts.search` / `phrase` / `proximity` answer only
  nodes that carry the index's label. A `SET` that replaces a non-empty
  indexed string (by another value, a non-string, or `SET n = {map}`
  dropping or changing it) left the old words findable (the documented
  residual): it now queues the covering indexes for the same statement-end
  rebuild as `REMOVE n.prop`. A ROLLBACK whose vector-index repair landed
  while a non-blocking background rebuild was building from an earlier
  snapshot was overwritten by that rebuild's swap; an in-place rebuild or
  an overwrite of an indexed id during the window now makes the background
  rebuild run again from the store after its swap. The `IndexOnEncryptedField`
  refusal no longer tells users to "use a searchable (blind-index) field",
  which cannot be declared. On a store with no storage engine,
  `GraphStore.setNodeProperty` on an id that names no node answers
  `NodeNotFound` instead of succeeding. `docs/FULLTEXT_SEARCH.md` updated.
  Regression: `zig build test-sonny6421-index-maintenance`.
- **`ORDER BY <indexed> LIMIT` served from the value-ordered index no
  longer reads a freed or changing tree (SONNY-6375, geode side).**
  graph_storage's `OrderedBTree` has no locking of its own, and its cursor
  must not be iterated across a mutation. `StorageAdapter.orderedScan` read
  each shard's tree under that shard's lock only, while write statements
  change the tree under the graph's EXCLUSIVE lock with no shard lock, and
  the engine-direct and snapshot reads that reach it hold no graph lock;
  it also kept each shard's cursor across the lock release between two
  256-entry batches, so an ordered-index rebuild in that gap (the full
  checkpoint's refresh, `createOrderedIndex`, the ORDER BY auto-build)
  freed the nodes the cursor pointed into, and the next batch crashed. Each
  batch now holds `mg.rwlock` SHARED and then the shard lock (the order
  `createOrderedIndex` uses), opens a fresh cursor and resumes strictly
  after the last key it visited, and checks node liveness under that hold.
  A thread that already holds the graph's read or write lock through the
  graph-lock API (the point-read and fallback reads, a read statement of a
  write program) does not take `mg.rwlock` again; the API now records
  per thread which graphs it holds. `test-ordered-scan-tsan` reported 4
  ordered-scan races (`OrderedBTree.Cursor.next` / `normalizeForward` /
  `lowerBound` against `insertIntoLeaf`, `getNode` against `putNode`) and
  now reports none; its remaining reports are the thread_pool 0.2.9 queue
  races, fixed in thread_pool 0.2.10. The race test's writer now holds the
  graph write lock, as production writers do. Regressions:
  `zig build test-sonny6375-ordered-scan-locking` (and its `-tsan`
  companion).
- **`getCurrentGlobalStore` no longer copies the global store (SONNY-6375).**
  It tested `global_store != null` on the `?GraphStore` value, which copied
  the store's bytes, live mutexes included; ThreadSanitizer reported it
  against a concurrent `hydration_build_mutex` lock in
  `test-startup-lazy-hydrate-tsan`. The persistence loop and
  `flushForCleanShutdown` did the same. They now test the optional through
  a pointer capture. Regression: `zig build
  test-sonny6375-global-store-race` (and its `-tsan` companion).
- **The long write suites finish in minutes on a loaded host
  (SONNY-6333).** `tests/sonny738_write_harness.zig` opens, writes, reloads
  and closes a persisted store for every case in three sessions; on a
  loaded host's shared ext4 disk the test thread waited on the journal
  (`jbd2_log_wait_commit`) at about 14% of one core, and
  `test-sonny3139-write-shapes` was still running at a 25-minute cap
  (`test-sonny-write-allowlist` and `-r4b` had hit 50 and 60). A persisted
  session's store now lives on tmpfs (`/dev/shm`) when the host has one:
  the storage code paths are the same and fsync there returns at once.
  Three runs in a row with other builds running (load average 36-481):
  `test-sonny3139-write-shapes` 43-69 s, `test-sonny-write-allowlist`
  80-87 s, `test-sonny-write-allowlist-r4b` 285-345 s, all inside a
  10-minute budget; `test-sonny3040-chained-writes` 7 s (was 11 minutes).
  `-r4b` still runs 500-900 threads at 12-15 cores (now CPU-bound, not
  fsync-bound). Regression: `zig build test-sonny6333-write-harness-tmpfs`.
- **The TDE self-test procedure and FLE CANARYs cite tests that exercise
  them; GAP-0514 is reopened (SONNY-6321).** Twenty markers cited
  `tests/test_tde_kms_integration.zig`, which tests `TDEKeyManager` only.
  `test-sonny6321-tde-procedures` now drives `tde.test_encryption`,
  `test_decryption`, `encrypt_page_test`, `encrypt_backup_test`,
  `roundtrip_test`, `measure_overhead`, `test_kms_wrap_unwrap` and
  `test_kms_attestation` through the executor (real success with TDE on and
  a key; no success claim with TDE off from those that use the key), and
  their markers cite it. REQ-FLE-CATALOG-001, REQ-FLE-INTEGRATION-001 and
  REQ-FLE-KEY-001 cite `test-fle-online-grant`, `test-gap0852` and
  `test-fle-lifecycle`; REQ-TDE-PROC-046 and the FLE AST, PARSER, STORAGE,
  BI-002, SCHEMA, EXECUTION, ADMIN and MIGRATE-CLI markers are IMPL. IMPL is
  267 of 6,161 (4.3%), above GAP-0514's 250 target, so GAP-0514 is back in
  `docs/GAP_ANALYSIS.md` as Partial.
- **The TDE procedures' simulate_oltp_workload, GPS gate, argument checks
  and cluster mode, and six FLE requirements, have tests that execute them
  (SONNY-6321, remaining parts).** `test-sonny6321-tde-fle-cases` drives
  `tde.simulate_oltp_workload` through the executor's TDE dispatch, a CALL's
  GPS gate (a ReadOnly principal is refused the self tests classified as
  writes and may run `tde.measure_overhead`), out-of-range arguments, and
  cluster mode (the self tests run on a follower, `geode.fle.configureField`
  is refused), plus CREATE GRAPH TYPE field annotations in the AST and an FLE
  field written through the executor (no plaintext on disk, plaintext only
  for a role it is visible to); `test-sonny6321-fle-schema-blind-index`
  covers annotation metadata and the blind index. REQ-TDE-PROC-046 and
  REQ-FLE-AST/PARSER/SCHEMA/BI-002/EXECUTION/STORAGE-001 are TESTED against
  them. REQ-FLE-ADMIN-001 and REQ-FLE-MIGRATE-CLI-001 stay IMPL:
  `fle_commands.rotateKey` prints a completed rotation without rotating any
  key, and the migrate-encrypt CLI has no storage to migrate. GAP-0514: 405
  IMPL of 5,900 (6.9%).
- **The canary perf benchmarks take batched samples from the production
  allocator, interleave A/B arms and claim on the median and IQR; the
  phantom-range baseline enables phantom prevention (SONNY-2439, second
  slice).** `tests/perf_gate.zig` gains the measurement helpers
  (`nowNs`, `timeBatch` / `sampleBatches` / `interleavedAB`, which pass every
  result to `doNotOptimizeAway`, `robust` statistics, `robustEnvelope`,
  `medianOverhead`, and `bench_allocator`, the C allocator the server uses
  in optimized builds). The nine canary benchmarks with gated claims
  (phantom-range, phantom-anomaly, prune, enumerator, plan-selection,
  pipeline-selection, physiological-redo, write-skew, corrupt-recovery) use
  them instead of one-operation samples on DebugAllocator with mean/CV
  statistics; the three A/B claims run their arms interleaved. The
  phantom-range baseline never enabled phantom prevention, so its
  `predicateRead` returned at once and the overhead divided a full commit by
  an almost empty one; both arms now run with it on and differ only in the
  range reads. With the methodology fixed the two overhead claims still
  miss (reported, not enforced: phantom-range ~59%, phantom-anomaly ~54%
  against 5% on a loaded host). Still open: thresholds calibrated on the
  quiet runner (the robust bounds are the former bounds carried over), the
  single-shot latency bounds of `src/performance/test_json_optimization.zig`
  and `tests/test_performance_optimizations.zig`, and the GitLab schedule
  for `test-perf-gates-enforced`. Regression:
  `zig build test-sonny2439-perf-methodology`.
- **The perf-gated benchmarks time with a monotonic clock, and the two that
  timed only test-local code are removed (SONNY-2439, partial).** Every
  benchmark that makes a claim through `tests/perf_gate.zig` read
  `CLOCK_REALTIME`, which NTP slews and steps; they read `CLOCK_MONOTONIC`.
  `tests/canary_storage_redo_delta.zig` (a synthetic `simulateRedo` loop
  whose result was discarded) and `tests/canary_path_varlen_predicate.zig`
  (a 4-node test-local DFS) imported no product code, so a missed claim
  could not mean a product regression; they, their steps
  (`test-canary-storage-redo-delta`, `test-canary-path-varlen-predicate`) and
  their entries in the scheduled `test-perf-gates-enforced` job are removed.
  Still open: batch timing, the production allocator, interleaved A/B with
  median/IQR, calibrated thresholds, the phantom-range baseline that never
  enables phantom prevention, and the job's GitLab schedule. Regression:
  `zig build test-sonny2439-perf-methodology`.
- **BREAKING: `Dockerfile.prod` and `make docker-build-prod` are removed
  (SONNY-6272).** The image could not build: it installed Zig 0.15.2
  (build.zig.zon requires 0.16.0) and copied a `vendor/` directory that does
  not exist, its builder (ubuntu:26.04) and runtime (cuda
  base-ubuntu24.04, `libssl3`) did not match, and no CI job built it or
  checked it. The supported GPU image is `Dockerfile.release.gpu`, under
  `release/dockerfile_manifest.json` and its compatibility checks.
  `docker-compose.example.yml` now builds `Dockerfile` like the other
  compose files. Regression: `zig build test-sonny6272-dockerfile-prod`.
- **The QUIC test client fails at once on a connection the server closed
  (SONNY-6374 item 2).** `QuicProtoClient` (tests/proto_test_util.zig)
  waited for a reply until the 120 s liveness cap whenever the server was
  still alive, because a stream read on a closed connection reports
  WouldBlock. A refused connection (the server sends CONNECTION_CLOSE) now
  fails with `error.ConnectionClosed`: the F13 case of
  `test-sonny3253-round14-minors` failed every run at 120 s and now sees the
  refusal in about 250 ms.
- **No in-place restore; a restore syncs once; the CLI's server wait is
  configurable (SONNY-6300).** `BackupManager.restoreToPointInTime` wrote a
  backup over whatever directory it was given, the live data directory
  included, and then reopened the process-global adapter there, whose
  shutdown checkpoint wrote the old in-memory state back over the restore;
  `S3BackupManager.restore` called it. It is removed: `BackupManager.restoreInto`
  and `S3BackupManager.restore` use the staged, verified restore
  (`restoreBackupInto`: a new or empty target only, refused over a store,
  auth chain verified or the restore refused). The staged copy was fsynced
  file by file (about 700 fsyncs for a tiny two-graph store, over 10 s on a
  loaded disk); on Linux the filesystem is now synced once (`syncfs`) and the
  parent directory after the rename (which was not synced at all).
  `geode backup create` and `geode restore --server` wait up to 300 s (was a
  fixed 30 s) for the server's answer, set with `--timeout <seconds>`. A live
  in-place restore into a running server is not implemented: restart on the
  restored directory. Regression: `zig build test-sonny6300-staged-restore-paths`.
- **A local backup is written once (SONNY-6323).** `geode backup create
  --local --output <file>` wrote `full_<id>.backup` and `metadata.json` beside
  `<file>` and then copied it there; it now writes `<file>` once (through a
  synced temporary file, 0600). The dead `BackupManager.runRetention` (it
  could not compile) and `SimplifiedBackupManager.runRetention` (no caller)
  are removed, with five backup test files no build step compiled
  (`test_server_backup_api_integration.zig`, `test_server_backup_api_unit.zig`,
  `test_backup_e2e.zig`, `test_backup_comprehensive_integration.zig`,
  `canary_backup_restore.zig`). The `/tmp` data-directory fallback was
  already removed by SONNY-6325 and the test client's fixed 10 s backup wait
  by SONNY-6301. Regression: `zig build test-sonny6323-local-backup-written-once`.
- **BREAKING: backup commands the docs showed but the binary never had
  (SONNY-6290).** `docs/USAGE.md` and `docs/deployment/DEPLOYMENT.md`
  documented `geode backup --dest s3://... --mode full|incremental --parent
  <id>` and `--list`, and README, CLAUDE.md and the feature docs claimed an
  S3 / Digital Ocean Spaces backup target: the binary has no object-storage
  path (`src/storage/s3_backup.zig` is reached by no command). The docs now
  show the real commands and copying backup files with your own tool.
  `geode backup create` ignored options it did not know and took an
  `s3://` / `http(s)://` `--output` as a local path (with `--local` it
  created a directory named `s3:` and reported success); both are now usage
  errors (exit 2), as is an unknown option or extra argument to `geode
  restore`. Regression: `zig build test-sonny6290-backup-doc-commands`
  (every documented backup/restore command is checked against the built
  binary's `--help`).
- **Tests start servers on free ports, and the shared test clients wait for
  a live server instead of failing at a fixed deadline (SONNY-6301).**
  `tests/gql_conformance.zig` started every server on 127.0.0.1:3181, so two
  runs on one host reached each other's server: two concurrent runs failed
  in 5 of 5 rounds (11-18 of 21 each, HELLO timeouts and `42P07 Duplicate
  graph name` seeds). It, `test-first-boot-admin-breadcrumb`,
  `test-liveness-breadcrumb`, `test-quic-idle-cpu`, `test-cert-provided`
  and `test-sonny2394-kms-client-deadline` now take ports from
  `tests/test_ports.zig` (bind port 0, read the port, release it; UDP for
  QUIC, TCP for gRPC and metrics), and gRPC ports are no longer probed with
  UDP. A `QuicProtoClient` connected to a loopback address now treats every
  reply deadline as soft: it keeps waiting while the server still holds its
  port, up to 120 s (`liveness_cap_ns`, was 60 s and opt-in through
  `watchServerLiveness`), and fails at once with `error.ServerExited` when
  the port is released. `backup` failed at a fixed 10 s on a loaded host
  (test-sonny6288-server-restore-target, 2 of 5 runs), HELLO and queries at
  5 s. The gRPC test client's socket timeout is 120 s instead of 5 s (TCP
  reports an exited server at once). Regression:
  `zig build test-sonny6301-test-ports-and-timeouts`.
- **No test binds a fixed port, `geode serve` reports the port it bound,
  and `GEODE_LSP_PORT` sets the embedded LSP port (SONNY-6332).**
  `canary_remote_kms` (8876-8880), `canary_remote_kms_hardening`
  (13051-13054), `test_server_memory_pressure` (34717),
  `test_datadir_lock_subprocess` (23911-23920) and `test_perf_optimizations`
  (3182-3186) used fixed ports; the QUIC socket binds with `SO_REUSEADDR`,
  so two concurrent runs of `test-remote-kms-hardening` bound the same UDP
  port and failed with `RemoteError` / `AuthenticationFailed` from the other
  run's KMS key. The KMS suites now start on port 0 and dial the bound
  `RemoteKmsServer.port`; the others take ports from `tests/test_ports.zig`.
  `geode serve --listen host:0` logged port 0 in its JSON transport banner
  and `QUIC server started`; both now carry the bound port
  (`QuicTransport.boundPort`). Every `geode serve` opened the embedded LSP
  listener on TCP 3142, so concurrent test servers fought over it (the loser
  logs `LSP listener: bind failed` and runs without LSP): `GEODE_LSP_PORT`
  now sets the port when `--lsp-port` is absent (the flag wins, 0 disables,
  a non-number logs a warning and keeps 3142), and the build sets
  `GEODE_LSP_PORT=0` on every test Run step that spawns geode. With neither
  set the production default is unchanged (3142), and a failed LSP bind still
  logs an error and leaves the QUIC server running. Regression:
  `zig build test-sonny6332-no-fixed-ports` (also scans every test source
  the build compiles for a literal listen port).
- **The in-process gRPC test fixtures no longer crash after a vector index
  is created, and the I-4 vector case runs over gRPC (SONNY-3379).** The
  executor creates the process-wide index manager on the first CREATE INDEX
  from that statement's allocator; the fixtures
  (`tests/sonny738_r12_grpc_fixture.zig` and the round-4a transport test's)
  hand the gRPC handlers their request arena, so the manager and its HNSW
  worker pool lived in that arena, which the fixture freed before the
  catalog cleanup called into the manager (SIGSEGV). The fixtures now create
  the manager with the test allocator and tear down the catalog and the
  manager before the arena. `test-sonny-write-allowlist-r4-transport` runs
  SONNY-3319's label-SET vector check over gRPC as well as QUIC. Regression:
  `zig build test-sonny3379-grpc-vector-index-teardown`.
- **Thirteen test files that no build step compiled are built or removed
  (SONNY-6320).** Password hashing and timing-attack resistance had no
  running test: `src/security/test_argon2id_hashing.zig` called a removed
  `Auth` API and `test_timing_attacks.zig` asserted wall-clock variance.
  Both are replaced by `test-sonny6320-password-hashing`: Argon2id PHC
  strings with m=19456, t=2, p=1 and a fresh salt, verify refusing near
  misses and malformed or foreign PHC strings, and a structural check that
  every verify path compares digests through `timingSafeEql` (no clock).
  The GAP-0193 parse suites (`test_gap_0193_batch2_engine`,
  `test_gap_0193_batch2_misc`, `test_gap_0193_impl_verification`) are
  registered (`test-gap0193-*`) with their Cypher-only syntax replaced by
  GQL (`FOR ... IN`, `START TRANSACTION`, `EXISTS { }`, `REQUIRE`), their
  always-true `or true` / module-existence cases removed, and the cases for
  features Geode does not have (CHECK, range and `=~` constraints, `CREATE
  MATERIALIZED VIEW`, a bare `SHORTEST` prefix, `SET TRANSACTION ISOLATION
  LEVEL`) now asserting the parser's refusal.
  `tests/test_external_kms_provider.zig` is ported to the
  `external_kms_client` module (`test-external-kms-provider`: wrap/unwrap,
  tampered tag/ciphertext/nonce, foreign key). Removed as testing nothing
  live or duplicating registered tests: `test_abac_enforcement.zig` (struct
  field checks; its SecurityManager authorize/ABAC cases are covered by
  `tests/e2e_rls_security.zig`), `test_async_connection.zig` (the external
  thread_pool library), `e2e_rls_enhanced.zig` (imported modules that no
  longer exist), `canary_federation_latency_aggregate.zig` (duplicates the
  module's registered inline tests), `priority_implementations.zig`,
  `test_canary_core.zig` and `test_performance_integration.zig` (no-op,
  duplicate or mock-module cases). The ABAC-WIRE CANARY markers that cited
  `test_abac_enforcement.zig` are now IMPL: `SecurityManager.authorize`
  and its ABAC policies are called by no server request path (authorization
  is GPS), and `GEODE_ENABLE_ABAC` changes only a startup log line.
- **The ThreadSanitizer companion steps instrument the code (SONNY-6328).**
  With Zig 0.16 a Debug x86_64 build uses the self-hosted backend, which
  ignores `-fsanitize-thread`: the six `test-*-tsan` steps had no TSan
  instrumentation or runtime and passed while detecting nothing (a
  deliberate race passed too). They are now built with the LLVM backend
  (`tsanTest` in `build.zig`), configure refuses a `sanitize_thread` test
  built any other way, and `test-sonny6328-tsan-detects-race` (in the
  aggregate) requires ThreadSanitizer to report a deliberate race. The
  companions now report real races, in the thread_pool dependency's
  work-stealing queues and graph_storage's ordered B-tree cursor
  (`docs/KNOWN_TEST_ISSUES.md`), so they stay out of the aggregate and no CI
  job runs them until those are fixed. Until then concurrency fixes rest on
  deterministic lock-wait proofs and stress tests. Regression:
  `zig build test-sonny6328-tsan-detects-race`.
- **The mock S3 backup tests and the stale canaryscan rows are gone
  (SONNY-6355 item 4).** `tests/e2e_s3_backup_restore.zig` and
  `tests/test_s3_backup.zig` exercised a mock S3 client and were imported
  only by `tests/all_tests.zig`, which nothing compiles; the binary has no
  object-storage backup path (SONNY-6290). `tools/canaryscan/status.csv`
  and `status.json`, the scanner's committed output, are regenerated with
  `tools/canaryscan`: 224 rows named a source file that no longer exists
  (the backup API tests at rows 476, 1754 and 3429 among them, and rows
  from dependency checkouts under `zig-pkg/`). Regression:
  `zig build test-sonny6355-dead-backup-tests`.
- **The offline `geode user` CLI names the password-policy rule a password
  breaks; `reset-password` and `password` accept `--generate-password`
  (SONNY-6271).** `user create`, `update`, `password` and `reset-password`
  answered "password does not meet policy requirements (min 8 chars, letters
  and numbers)", the CLI's rule before it adopted the unified passphrase
  policy (20+ characters, upper and lower case, 3+ words; docs/USER_AUTH.md),
  so `resetpass12345` was refused with a message it satisfied. The message
  now ends with the rule that failed, e.g. `: Password too short (minimum 20
  characters)`, and never echoes the password. `reset-password` and
  `password` checked the policy against a `--generate-password` secret too
  (32 lower-case hex digits, which can never pass), so they refused every
  generated password; like `user create`, they now check only a password
  the operator supplies. `test-first-boot-admin-breadcrumb` uses a
  compliant passphrase and runs in the aggregate. Regression:
  `zig build test-sonny6271-password-policy-rules`.
- **`geode backup cleanup` deletes old backups instead of reporting a
  cleanup it never did; `geode backup info` no longer crashes (SONNY-6289).**
  `backup cleanup` printed "Cleaned 0 backup files" / "Backup cleanup
  completed" and exited 0 without looking at any file. It now needs `--dir`
  and `--older-than <n>s|m|h|d|w` (usage error, exit 2, otherwise), lists
  what it would delete unless `--yes` (or `--confirm`) is given, deletes
  only regular files directly in `--dir` whose header decodes as a geode
  backup and whose header timestamp is older than the age, never the newest
  backup, never a symlink or a subdirectory, drops deleted backups from the
  directory's `metadata.json`, reports each file, and exits 1 if a deletion
  failed. `backup info` cast the header straight from an unaligned buffer
  (a panic on every file) and printed enum and bool fields unchecked; for a
  `.gz`/`.zst` name it printed "gzip compressed, type full" without reading
  the file. `backup info`, `backup list` and the server's upload ingestion
  now decode headers through one range-checked function
  (`decodeBackupHeader`), and info exits 1 with `error: <Name>` for a
  damaged, truncated or non-geode file. Regression:
  `zig build test-sonny6289-backup-cleanup-info`.
- **BREAKING: a restore request to a running server no longer writes into
  `./data` or over the live store, and no longer reports a restore it does
  not serve (SONNY-6288).** The QUIC `restore` message, the gRPC
  `/geode.GeodeService/Restore` call and `geode restore --server` restored
  the server's newest backup into `GEODE_DATA_DIR` if set, otherwise into
  `./data` in the server's working directory, never into the directory the
  server was started on with `--data-dir`. A server started with
  `--data-dir X` wrote the restore into `./data` and answered "Restore
  completed" while it kept serving X. With `GEODE_DATA_DIR` naming the live
  directory it wrote the files in place over the open store and answered
  "Restore completed"; the server kept serving the old data, and after a
  restart the restore was gone. The write was in place, with no staging, so
  a failure part way left a half-written store. The gRPC handler took no
  lock at all. Now the server never writes a restore into its data
  directory (it cannot swap the store under its open engines): it restores
  into a new directory beside the data directory the storage engine has
  open, `<data dir>.restored-<backup id>-<ms>`, with the same sequence as
  `geode restore <file>` (decode and verify, write into a staging
  directory, compare every file, open the restored store and count each
  graph, rename), and the response names that directory, the per-graph
  counts, and that the server still serves its old data until restarted
  with `--data-dir <restored directory>`. A failed restore leaves no new
  directory and no staging directory. The request stays Admin-only, is now
  audited (`SERVER_RESTORE`), is refused in cluster mode (no replication
  slice), and an unparsable `target_time` is refused instead of meaning
  "latest"; the CLI converts an ISO-8601 `--target-time` to epoch ms.
  Regression: `zig build test-sonny6288-server-restore-target`.
- **BREAKING: `geode restore <file>` restores the backup (SONNY-6280).**
  From 2026-03-28 (`16833164`, which removed the legacy `graph_store.dat`
  restore) the local CLI restore wrote nothing to disk: it checked and
  decoded the backup, created an empty `./data/restore` in its working
  directory, and printed "Full backup restore completed" and "Restore
  completed successfully" with exit 0. It now writes the backup into the
  directory given by `--data-dir <path>` (or `GEODE_DATA_DIR`), offline,
  through the same decode and per-graph restore as the server path. The
  restore is written into a mode-0700 staging directory beside the target,
  every file is compared with the archive, the restored store is opened
  cold, and only then is it renamed onto the target and success printed,
  with each graph's node and edge counts. The target must not exist or be
  empty; a non-empty target is refused (`RestoreTargetNotEmpty`), never
  merged into. A restore with no target is a usage error (exit 2). A
  failed restore exits 1 with `error: <Name>` and leaves nothing at the
  target and no staging directory. `--target-time` takes epoch
  milliseconds or `YYYY-MM-DDTHH:MM:SS[Z]` (UTC, real calendar arithmetic);
  an unparsable value is a usage error instead of "restore the latest".
  `--server` with a backup file is a usage error. Restoring from an
  `s3://` or `http(s)://` source fails closed (the server ignored the URI
  and restored its own newest backup over its live data); download the file
  first. `geode restore --server <addr>` with no file asks the server to
  restore its own newest backup (see SONNY-6288 above). Regression:
  `zig build test-sonny6280-cli-restore-writes-data`.
- **A restore with the wrong decryption key no longer crashes:**
  `decryptData` freed its buffer twice on an authentication failure (the CLI
  segfaulted; the server path shared the pattern). It now returns
  `DecryptionFailed`.
- **`geode backup create --local` fails when it cannot write `--output`:**
  a failed copy to the requested path printed a warning and then "Backup
  created successfully".
- **Backup/restore regressions count the restored store the way the engine
  does (SONNY-6277):** `test-gap0862` (1 of 3) and `test-gap0880` (2 of 5)
  reported 0 nodes in a restored store (`expected 5, found 0`;
  `expected 2, found 0`). No data was lost: the restore writes every graph
  file, and the restored store holds every node, edge and property. The tests
  read `GraphStore.nodes.count()`, `edges.count()` and `edges.getPtr()`,
  which are resident caches, and since Phase 1b (`a31800da`, 2026-06-29)
  `loadFromFile` defers each graph's resident load to first access, so on a
  cold store those caches are empty. They now read through
  `getNodeCount`/`getEdgeCount`/`getEdgePtr`, which hydrate, with the same
  exact counts and property checks, and both steps run in the aggregate. The
  new `zig build test-sonny6277-backup-restore-roundtrip` backs up a store
  (default and named graph; String, Int, Float and Bool properties),
  restores it into a fresh data directory, and reads it cold through the
  executor and `getAllNodes`, and again after a reopen, uncompressed and
  with gzip.
- **GPU release image can start the release binary (SONNY-4884):**
  `Dockerfile.release.gpu` was based on
  `nvidia/cuda:13.4.2-runtime-ubuntu22.04`, whose glibc 2.35 is older than the
  GLIBC_2.36 the `x86_64-linux-gnu` release binary needs, so the published GPU
  image exited 1 before `main`. It now uses
  `nvidia/cuda:13.4.2-runtime-ubuntu24.04` and installs `libssl3t64`, the name
  Ubuntu 24.04 gives OpenSSL 3. Every release Dockerfile now runs
  `geode --version` as the non-root runtime user while the image builds, so a
  loader or glibc mismatch fails the build instead of shipping.
  `tools/release_dockerfile_manifest.py` now refuses a glibc base that is older
  than `release_binary.glibc_required`, or whose glibc it does not know.
  Regression: `tests/test_sonny4884_release_image_runtime_compat.py`.
- **FIPS release image can load the OpenSSL provider it ships (SONNY-4885):**
  `Dockerfile.release.fips` ran on `debian:bookworm-slim` (glibc 2.36), but the
  OpenSSL 3.6.2 provider tree it copies from `zig-fips:0.16.0` needs
  GLIBC_2.38, so the image could not load its own FIPS provider. It now runs on
  `debian:trixie-slim` with `libssl3t64`, like `Dockerfile.devimage.fips`. The
  image build runs the shipped `/usr/local/ssl/bin/openssl list -providers` as
  the non-root runtime user and fails unless the base and fips providers are
  active. The manifest entry records `glibc_required: "2.38"` and
  `openssl_provider_tree`, and `tools/release_dockerfile_manifest.py` now
  checks manual Dockerfiles too. Ordinary release images stay on bookworm.
  Regression: `tests/test_sonny4885_fips_release_runtime_compat.py`.
- **Required cross-build gates fail when a build fails (SONNY-4911):** the
  pre-push `cross-compile-check` hook ran
  `make cross-compile-required 2>&1 | tail -20` without `pipefail`, so it took
  `tail`'s exit status and passed when make failed. It now sets `pipefail` and
  still shows the last 20 lines. `cross-macos-x86_64` and `cross-macos-arm64`
  ran Zig inside an `if` and then echoed success unconditionally, so a compiler
  failure exited 0 and printed success. The success line is now chained with
  `&&`, so the recipe exits non-zero. Native-macOS skips are unchanged.
  Regression: `tests/test_sonny4911_cross_gate_status.py`
  (`make cross-gate-status-test`, a `cross-gate-status-regression` pre-commit
  hook, and the `governance-cross-gate-status` CI job).
- **The `zig-test` pre-push shards share one CPU budget (SONNY-4920):** the
  hook started all four `zig build test` shards at once with no `-j`, and each
  Zig build runner sized its job pool to every visible CPU, so the box ran
  about four times as many jobs as it had CPUs (50 processes / 509 threads on
  12 CPUs). The budget is now `nproc`, which honours CPU affinity, or
  `GEODE_PREPUSH_ZIG_JOBS` when set. Up to four shards run at once, each with
  an explicit `zig build -j<budget / shards running>` (at least 1); budgets
  below four run the shards in waves. Every shard still runs exactly once, a
  failed wave does not stop later ones, and the hook still fails on any shard
  failure or 40-minute timeout and keeps every shard log. An invalid budget
  stops the hook before any shard runs.
  Regression: `tests/test_sonny4920_prepush_shard_budget.py` (in
  `make cross-gate-status-test`, a `zig-test-budget-regression` pre-commit
  hook, and the `governance-cross-gate-status` CI job).
- **Concurrent-login test reports each caller's outcome (SONNY-4920):**
  `authenticate_concurrent_cached_user_singleflights_persistent_refresh`
  counted failed callers but dropped their errors. When it fails it now prints,
  per caller, the error name or returned role and the elapsed time. Bounds,
  caller count and assertions are unchanged.
- **Test steps spawn the geode this build emitted (SONNY-2697):** every test
  that starts a geode server or CLI spawned `./zig-out/bin/geode`, which held
  whatever the last install left. With `zig build -p <prefix>` the fresh
  binary went to the prefix and `test-gql-conformance` ran the old one; eight
  steps (`test-first-boot-admin-breadcrumb`, `test-cluster-steady-state`,
  `test-liveness-breadcrumb`, `test-quic-idle-cpu`,
  `test-cluster-replicable-mutations`, the aggregate `all_tests.zig` run, and
  the `cli_test.zig` and server-memory-pressure runs in `test-e2e`) did not
  build geode at all, so they ran a stale binary or SKIPped as passed. A test
  that spawns geode is now registered with build.zig's `spawnsBuiltGeode`,
  which gives it the `geode_test_bin` module: the absolute path of the
  executable this build emitted, built before the test compiles. The path
  does not depend on zig-out, the install prefix or the working directory,
  and a spawning test that is not registered fails to compile.
  Regression: `zig build test-sonny2697-spawned-geode-fresh`.
- **Test runs remove their scratch dirs from `/tmp` (SONNY-2413):** a test
  process that spawned a server without `--data-dir` gave it
  `/tmp/geode-test-<pid>`, and nothing removed it (one task's runs left 62).
  `test-gql-conformance` left one `/tmp/geode-gqlconf-<pid>-<n>` per query,
  20 per run. Scratch dirs now come from `tests/test_scratch.zig`. Each test
  process gets one root, `/tmp/geode-test-<pid>-<random>`, created fresh
  (nothing already there is reused or deleted). A small `/bin/sh` reaper
  removes the root when the process exits, even when the process is killed
  with SIGKILL. The default server data dir is `<root>/data`.
  `ScratchDir.create` makes a dir under the root for a single test, and
  `remove()`, deferred before the server is spawned, deletes it once the
  server has stopped. If the dir survives, `remove()` fails the test.
  `gql_conformance.zig` uses it. The cert dirs that
  `test-cert-provided` and `test-cluster-replicable-mutations` create are now
  removed when an `openssl` step fails, too.
  Regression: `zig build test-sonny2413-scratch-cleanup`.
- **`zig build tools` builds again, and every executable compiles
  (SONNY-2474, SONNY-2771):** thirteen executables had not compiled since
  the Zig 0.16 upgrade, eight of them under `zig build tools` (so
  `make tools` and `make doccheck` failed), and `test-compile` skipped all
  thirteen through `rotted_executables`. Three that a build step, a doc or a
  gate still runs now compile on Zig 0.16 and current engine APIs:
  `gen_fuzz` (`zig build gen-fuzz`, documented in fuzz/README.md; it now
  reports an existing target instead of claiming to create it),
  `benchmark_rls_row_skip` (`zig build bench-rls-row-skip`) and
  `bench_remote_kms_unwrap_concurrency` (run by `test-e2e`). The other ten
  had no caller and were deleted with their build steps (`canary`, `delta`,
  `variance`, `generate-fuzz-dict`): `bench_extract`, `bench_regress`, the
  four `fed_latency_*` tools, `run_variance_benches`, `impl_reality_delta`,
  `canary_main` and `generate_fuzz_dict`. So were the engine code only
  `canary_main` reached (`AdvancedIndexManager.persistAll`/`loadAll` and
  `src/index/interval_persist.zig`; interval-tree indexes were never
  persisted by the server) and the never-compiled tests that imported the
  deleted code. `rotted_executables` is now empty, so `test-compile`
  compiles every executable. Regression: `zig build test-sonny2771-gen-fuzz`.
- **Every named test step runs in the aggregate or is listed with a reason
  (SONNY-2772):** 108 named `test-*` steps ran in no aggregate `zig build
  test` shard, so no pre-push hook or CI shard ran them, and they rotted
  unseen (`test-gap0891-repro` once stopped compiling). Among them were
  security regressions (`test-new1-cross-graph-bola`,
  `test-sec002-cdc-preauth`, `test-sec002-grpc-cdc`) and the round-8
  server-spawning regressions `test-sonny2776-quic-graph-uses` and
  `test-sonny2791-internal-graphs-reseal`. 54 of them now run in the
  aggregate. The other 54 are listed in `build.zig`'s
  `not_in_aggregate_steps`, each with its reason: aggregators, TSan
  companions, the e2e, benchmark and perf lanes, GPU, the subprocess cluster
  and CLI e2e tests, per-file runners whose files already run in the
  aggregate, and five steps that do not pass
  (`test-first-boot-admin-breadcrumb`; `test-slab-packing-geode`, which
  had stopped compiling against graph_storage 0.4.10's `EdgeIndexMap` and,
  ported to `forEachLive`, does not finish in 30 minutes; `test-gap0862`
  and `test-gap0880`, whose restored store reports 0 nodes, SONNY-6277; and
  `test-sonny-write-allowlist-r4-transport`, whose SONNY-3368 QUIC case
  times out while seeding).
  `checkNamedTestStepsInAggregate` fails configuration, `zig build -l`
  included, when a named step is neither in the aggregate nor listed, or when
  a listed name matches no step or one that runs in the aggregate. The
  `getNodePtrHydrated` doc comment now gives its real contract: before a
  crash-reopened graph is hydrated it returns null for a node that exists,
  so callers take ids from a hydration chokepoint (every caller does).
  Regression: the configure-time guard (`zig build -l`).
- **MERGE's indexes answer only what the store holds (SONNY-6362, items
  2-5).** (2) A node could be created with an id whose bit 63 is set (a
  reserved or replicated id); MERGE's index keeps a flag in that bit, so the
  node was never an entry (a MERGE of a value it alone held created a
  duplicate) and the loader refuses such an id (the node vanished at
  restart). Creating one is now refused (`graph_store.refuseFlaggedNodeId`:
  the reserved-id creates, `createNodeWithId`, the adapter's bulk insert and
  MERGE). (3) `StorageAdapter.lookupNodeIdByLabelAndAllProps` (bulk edge
  endpoint resolution) trusted the exact index's posting for its seed filter
  unchecked; the posting is a value hash, so a collision or a stale posting
  returned a node holding another value. Every filter is now checked against
  the node, and the public-id resolver checks the seed too. (4)
  **BEHAVIOUR CHANGE:** MERGE on a property that is FLE-encrypted in any type
  is refused (0A000) with nothing written; it compared the stored randomized
  ciphertext with the plaintext pattern value, never matched, and created a
  duplicate every time. MERGE on an unencrypted key and `SET` the encrypted
  field instead; matching on encrypted values needs deterministic or
  blind-index encryption (SONNY-6350). `docs/FIELD_LEVEL_ENCRYPTION.md` no
  longer lists blind-index equality search as available (it is not wired to
  any query). (5) The MERGE index writers that cannot fail their write
  (hydration, the full rebuild, the label-add and composite helpers, the
  streaming load's merge stage) swallowed every error, out of memory
  included, and MERGE trusted the miss; a failed add now marks the index
  untrusted, so lookups answer "unable to tell" and the caller scans, until a
  full rebuild adds every entry. Regression:
  `zig build test-sonny6362-merge-index-residuals`.
- **Full-text and vector indexes follow SET n:L, REMOVE n.prop and every
  label; a repeated SET target answers 22G0M (SONNY-6368).** (1) **BEHAVIOUR
  CHANGE:** one SET clause assigning one property of an element twice
  (`SET q.c = 1, q.c = 2`, or two variables bound to one node) is refused
  with GQLSTATE 22G0M, data exception - multiple assignments to a graph
  element property (ISO/IEC 39075:2024 13.3 General Rule 7 a); it answered
  22G03 (invalid value type). Clients matching on 22G03 for it must match
  22G0M. (2) A live `SET n:L` put the node into neither the full-text nor the
  vector indexes on `L`, so neither search found it; the node now joins them
  with the properties it holds (`property_mutation.addNodeLabel`, every SET
  executor). (3) A committed `REMOVE n.prop` left the removed text in the
  full-text index, so the node stayed findable by the removed word. The
  engine cannot take one property's postings out of a document, so every
  full-text index covering the removed text is rebuilt from the store at the
  end of the statement, once per index however many rows it removed from.
  Cost: an O(nodes of the label) rebuild per statement that removes indexed
  text. (4) Vector and other advanced-index maintenance used only the node's
  first label (SET, `SET n = {map}`, REMOVE, and the batch CREATE path), so an
  index on a second label went stale; it now maintains every label's.
  (5) An undo (failed statement, ROLLBACK) whose index repair found a
  rebuild of the same full-text index running (`CALL geode.fts.rebuild`, a
  restore's or snapshot install's rebuild) was refused, logged and dropped,
  and the index kept the undone value that rebuild had read; the running
  rebuild now runs again from the store after its pass
  (`FtsStorageAdapter.requestRebuildAgain`). `CALL geode.fts.rebuild` itself
  still refuses a second concurrent rebuild of one index. Not changed:
  `CALL geode.fts.rebuild` from a session on another graph rebuilds the
  default graph's index, where every full-text index lives (SONNY-2790); the
  ticket's item asking it to use the session graph described the design.
  Regression: `zig build test-sonny6368-index-maintenance`.
- **The statement undo record is the statement's, not the thread's
  (SONNY-6362, item 1).** A write another thread made for a statement was
  not in the statement's undo record (`statement_undo` kept it in a
  thread-local), so a statement that failed did not undo it, and the UNIQUE
  and NOT NULL / EXISTS / NODE KEY checks at the statement's end, which read
  the record, never saw it. The record is now a `statement_undo.Record` that
  a thread working for the statement joins (`current` on the statement's
  thread, `attach` / `detach` on the worker); every change to it takes its
  mutex, and a create's reserved slot is counted per create, so concurrent
  threads lose no entry. The parallel UNION arms
  (`set_operations.tryParallelUnion`), the executor's one path that runs a
  statement's work on threads of its own, join it; they are read-only today,
  and the record no longer depends on that. Regression:
  `zig build test-sonny6362-statement-undo-threads`.
- **A failed statement and a ROLLBACK leave the full-text and vector
  indexes answering for what the store holds (SONNY-3381).** The executor
  maintains the full-text indexes and the advanced (vector, spatial, ...)
  indexes beside the graph store's write methods, while the undo of a failed
  statement and of `ROLLBACK` / rollback to a savepoint replays through those
  methods only. Afterwards `CALL geode.fts.search` still found a node by a
  word an undone SET wrote (also inside a transaction, where fulltext
  maintenance is not deferred), missed a node whose DELETE was undone (the
  engine's tombstone is permanent), and `knn()` ranked a node by a vector an
  undone SET had added. The undo now collects the (graph, label, property)
  of each node change it reverts (`txn_undo_log.IndexRepair`) and, when it
  is done, rebuilds every full-text and advanced index covering one of them
  from the store (`execution/undo_index_repair.zig`), on the undoing thread
  under its graph lock. Cost: an O(nodes of the label) rebuild, only after
  such an undo. Also fixed on the way: a transaction that wrote one
  vector-indexed property twice leaked the index name it queued for its
  COMMIT's rebuild, and a ROLLBACK left that queued rebuild for the next
  COMMIT of any session to run. Regression:
  `zig build test-sonny3381-undo-index-entries`.
- **The server's MATCH ... CREATE and MATCH ... MERGE edge fast paths write
  what the executor writes (SONNY-3241).** (1) `MATCH (a:P {k: 1}), (b:Q
  {k: 9}) CREATE (a)-[:E]->(b)` resolved each endpoint to the lowest node
  holding its key, so with two `(:P {k: 1})` it made one edge where the
  executor makes one per matched pair (two); and a key MERGE's index cannot
  hold (a non-integer number such as `1.5`, an over-long key) was taken as
  "no such node", so it made none where the executor finds the nodes. The
  fast path now takes an endpoint only when it is its key's single holder
  (`StorageAdapter.lookupSoleNodeByMergeKey`) and otherwise hands the
  statement to the executor, before writing anything; a key no node holds
  still creates nothing. (2) The MATCH ... MERGE edge fast path wrote its
  SET properties on the edge it matched as well as the one it created, so
  `ON CREATE SET r.c = 1` (alone, or beside a bare `SET`) changed an
  existing edge; such statements now go to the executor, and only a single
  bare `SET` (which applies on both branches) stays on the fast path, as for
  the node MERGE fast path. The node MERGE cases of this ticket (ON CREATE /
  ON MATCH SET beside a bare SET, also through `/*+BATCH*/` and `USE GRAPH
  g; MERGE`) were already declined since round 4a and are now pinned over
  the wire. Regression: `zig build test-sonny3241-fast-path-parity-wire`.
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
- **`COUNT { }`, `EXISTS { }` and pattern comprehensions see a cold store
  (SONNY-1562):** a subquery whose start node was not bound by the outer
  query looked only at the nodes resident in the node cache, so after a
  restart (or eviction) `RETURN COUNT { (a:A)-[:R]->(:B) }` answered 0,
  `EXISTS { … }` false and `[(a:A)-[:R]->(b) | b.k]` an empty list while the
  same `MATCH` returned every row. Their scans, and a `shortestPath()` start
  node's, now read every node of the session's graph the way MATCH does,
  still filtered by graph, tenant and RLS. Such a relationship pattern also
  counted its start nodes rather than its matches, so
  `COUNT { (a:A)-[:R]->(:B) }` was the number of `:A` nodes and
  `EXISTS { (a:A)-[:R]->(:B {k: 1}) }` was true whenever an `:A` existed; it
  now counts the relationship's matches.
- **`COUNT { }`, `EXISTS { }` and pattern comprehensions match the pattern
  the way MATCH does (SONNY-2707 parts 2 and 3):** a relationship in one of
  them was walked along the start node's outgoing edges whatever its
  direction, so `COUNT { (a)<-[r]-(b) }` and `COUNT { (a)-[r]-(b) }` counted
  `(a)-[r]->(b)` and `EXISTS { (a:B)<-[:S]-(:A) }` was false when such an
  edge existed. A relationship property map (`-[:R {w: 1}]->`) was ignored,
  and a WHERE inside the subquery could not read the relationship variable.
  A variable-length relationship (`<-[*1..2]-`, `-[*1..2]-`) followed
  outgoing edges only and counted the distinct nodes it reached instead of
  the paths, and a pattern comprehension took it for a single hop. Only the
  first hop of a multi-hop pattern (`COUNT { (a)-[:R]->(m)-[:R]->(b) }`
  counted `(a)-[:R]->(m)`), and only the first part of a comma pattern, was
  matched. The three now share one walk that follows the MATCH executors'
  rules: the pattern's direction for every hop, the relationship's types and
  property map, every hop and every comma part, variables bound outside the
  subquery or earlier in the pattern as constraints, and variable-length
  hops through the MATCH executors' own path iterator (one match per path).
  Every node and edge is still filtered by graph, tenant and RLS. A
  self-loop matches an undirected pattern once.
- **PROFILE reports the access path that ran and names only real indexes
  (SONNY-1335):** the version-1 profile payload (sent for every tenant-bound
  or RLS-evaluating session, and for a PROFILE'd data change) put a
  `NodeIndexScan` operator first whenever the query had a WHERE or FILTER
  equality and named it `"heuristic_index"`, with no catalog lookup, while
  the legacy executor behind it scanned the label. It now has no index
  operator (`NodeScan` is the scan it reports). The version-2 payload
  (planned reads) copied the plan's `IndexSeek` whether or not the executor
  then seeked, and never named the index. Its scan operator is now set from
  what the executor did: `IndexSeek`, with `index_name` the catalog index
  (the name SHOW INDEXES lists), only when the start nodes came from an
  index seek on a label and property a btree or hash catalog index covers;
  `LabelScan` or `AllNodesScan` otherwise, including an index on another
  label or property, a fulltext or vector index, a dropped index, and a
  WHERE whose equality sits under an AND (the executor seeks only on a WHERE
  that is a single equality). No field is renamed or removed and the
  version numbers are unchanged; see docs/EXPLAIN_PROFILE.md, "Index names
  in the profile payload". Regression:
  `zig build test-sonny1335-profile-access-path`.
- **An aggregate inside an expression is computed once per group
  (SONNY-2696):** a RETURN or WITH item with an aggregate inside it was
  computed wrongly on every session: `count(*) + 1`, `sum(n.i) / count(*)`
  and `count(*) > 0` were NULL; `toString(count(*))`, `[count(*), sum(n.i)]`,
  `{c: count(*)}`, `coalesce(max(n.i), 0)` and `CASE WHEN count(*) > 5 ...`
  were evaluated against each input row (`'1'` once per row). Every
  aggregate inside an item is now a hidden aggregate column computed by the
  same code as a bare aggregate item (an item that computes the same
  aggregate is reused), and the item is evaluated once per group over those
  columns and the group's keys, beside a GROUP BY, under ORDER BY and HAVING,
  and in a WITH. An input column beside an aggregate that is no grouping key
  (`RETURN n.i + count(*)`) answers 42803, as `RETURN n.i, count(*)` does; an
  aggregate inside another's argument anywhere in an item
  (`[sum(count(*))]`) answers 42803; arithmetic on an aggregate that
  overflows answers 22003 instead of NULL. A NEXT-chained part computes an
  aggregate call and arithmetic over aggregates only, and now refuses any
  other expression over an aggregate with 0A000 instead of answering NULL.
- **Aggregate arguments are computed by the expression evaluator on every
  session (SONNY-2734):** the legacy executor (in-memory, tenant-scoped and
  RLS sessions) computed ungrouped aggregates with loops that read only a
  property or member argument: `sum(n.i * $f)` was 0,
  `count(CASE WHEN n.i > 15 THEN 1 END)` counted every row, `avg(n.i + 1)`,
  `max(n.i * -1)` and `max` over dates were NULL, `collect(n.i + 1)` was empty,
  `count(DISTINCT n.i % 3)` was 0 and `count(n.v * 2)` counted NULLs. Every
  aggregating RETURN and WITH of such a read now goes through the shared
  projection over the rows its pattern binds, after the aggregate fast paths,
  whatever the pattern's shape, so the arguments are evaluated per input row
  with the query's parameters; tenant scope and row-level security still
  decide which rows are bound. This also fixes, on those sessions,
  `MATCH (a:P {k: 1})-[:R]->(b) RETURN count(*)`, which ignored the inline
  property (SONNY-2688 part 1), and `MATCH (a:P), (b:Q) RETURN sum(a.k)`,
  which answered one NULL row per binding. **Behaviour change:** an error
  inside an aggregate's argument (22003 overflow, 22012 division by zero, a
  type mismatch) now fails the query, as the same expression does outside an
  aggregate; the row was skipped. Regression (four sessions, leak-checked):
  `zig build test-sonny2696-aggregate-expressions`.
- **A CREATE path with more than one hop creates the node between two hops
  once (SONNY-6295):** `CREATE (:P {k: 1})-[:R]->(:Q {k: 1})-[:S]->(:T {k: 1})`
  created two `:Q` nodes, one with the `:R` relationship and one with the
  `:S` relationship, so the path was not connected (`MATCH (b:Q)` found two
  nodes and `MATCH (:P)-[:R]->(:Q)-[:S]->(:T)` none). Every node between two
  hops of a path was created once per hop when it had no variable; a named
  one (`(q:Q)`) was created once. This held for CREATE, INSERT, MATCH ...
  CREATE, CREATE with a SET, WITH or ORDER BY after it, FOR ... CREATE and
  PROFILE CREATE, on every session, and the cluster leader's replicated
  create made the same two nodes on every replica. The QUIC fast paths take
  no path with more than one hop, and a MERGE of one is refused (0A000), so
  neither was affected. Each hop now starts at the node the previous hop
  ended at. MATCH ... CREATE and a CREATE followed by SET, WITH or ORDER BY
  also stored a backward relationship (`(a)<-[:R]-(b)`) as `(a)-[:R]->(b)`;
  it is now stored `(b)-[:R]->(a)`, as a plain CREATE already did. The
  defect dates from the first CREATE executor (before v0.1.0) and is in
  every released version. **Data written by the affected shapes is not
  repaired:** each such statement left one extra node per inner node of the
  path, with the same labels and properties, and backward relationships
  stored forward. To find them, for each multi-hop shape your application
  creates without naming the inner nodes, count the inner nodes that have
  the next hop but not the previous one, for example
  `MATCH (q:Q)-[:S]->() WHERE NOT EXISTS { ()-[:R]->(q) } RETURN count(q)`
  for `(:P)-[:R]->(:Q)-[:S]->(:T)`; each is the second copy of a node whose
  first copy has `:R` but no `:S`. Repair them by hand (recreate the second
  hop's relationship from the first copy and delete the second copy) or
  rewrite the data. Regression (in-memory, persisted warm and reloaded,
  tenant-scoped and RLS sessions, leak-checked):
  `zig build test-sonny6295-create-path-middle-node`.
- **A variable a WITH passes on is joined in the next MATCH (SONNY-3046,
  SONNY-3376, SONNY-3388):** a node, relationship or path variable bound
  before a chained MATCH (after `WITH` or `NEXT`) was bound again by that
  MATCH unless it was a hop's start node, so the next part matched every
  element and multiplied the rows: `MATCH (q:Q) WITH q MATCH (q) RETURN
  count(*)` counted every node once per q, `MATCH (g:G {i: 1}) WITH g MATCH
  (g:X)` matched the X nodes, `... WITH r MATCH ()-[r]->()` and `WITH *`
  matched every relationship, `(y)-[:R]->(q)` with q bound matched every
  `:R`, and `MATCH p = ... WITH p MATCH p = ...` every path. Per ISO/IEC
  39075, a variable already bound is now a join wherever the next pattern
  names it: alone, at either end or in the middle of a hop, twice in one
  pattern, as a relationship or as a path; labels, a property map, a
  relationship type or a direction on it filter the bound element (no row
  when it does not match), and a node or relationship the pattern reaches
  from it is checked for tenant scope and row-level security like any other.
  The walk starts at the bound node (or at a bound relationship's endpoint)
  rather than scanning. A chain whose
  last part aggregates now computes the aggregate over the joined rows with
  the shared projection (any aggregate expression, GROUP BY, DISTINCT,
  ORDER BY), where it applied a part's WITH before its MATCH and read freed
  memory on a three-part chain; the chain no longer leaks the nodes a
  persisted read hands it. Refused with 0A000 instead of answered wrongly: a
  bound variable named as a variable-length relationship, a path variable
  named as a node or relationship (or the reverse), and a part with an
  `OPTIONAL MATCH` that names a bound variable. Writes in a
  chained part stay refused (0A000) until SONNY-3111. Regression (in-memory,
  persisted warm and reloaded, tenant-scoped and RLS sessions, leak-checked):
  `zig build test-sonny3046-with-bound-variable-join`.
- **OPTIONAL MATCH is a left outer join, after WITH too (SONNY-6337,
  SONNY-3184):** `MATCH (q:Q) WITH q OPTIONAL MATCH (q)-[:S]->(t)` was a
  syntax error (42601), and a part with an OPTIONAL MATCH naming a variable a
  WITH bound was refused (0A000). A WHERE written on an OPTIONAL MATCH
  filtered the whole row, so `MATCH (q) OPTIONAL MATCH (q)-[:S]->(t) WHERE
  t.k > 1` dropped every q without such a t instead of returning it with t
  NULL; an OPTIONAL MATCH chained on another (or with a second hop) bound
  NULL; a FILTER after one was ignored. Per ISO/IEC 39075, the MATCH and
  OPTIONAL MATCH clauses of a part are now joined left to right, each
  matched from the variables of the record before it (a variable a WITH
  bound too) with its own WHERE restricting its own match: a record with no
  surviving match is kept once with the clause's new variables NULL, and a
  pattern starting from a NULL variable matches nothing. A FILTER or a
  `WITH ... WHERE` after it drops records. Nodes and relationships it
  reaches pass the session's tenant scope and row-level security as in any
  MATCH, so a hidden one leaves the optional side NULL. `collect()` skips
  NULLs, like every set function. An OPTIONAL MATCH may now follow a WHERE
  with a WHERE of its own. Refused with 0A000: a path variable in a part with
  an OPTIONAL MATCH (on the optional pattern as before,
  `OptionalPathVariable`; on the MATCH beside it,
  `UnsupportedOptionalMatchShape`) and an inline LET there. An error in an
  OPTIONAL MATCH's WHERE fails the statement. Regression (in-memory,
  persisted, tenant-scoped and RLS sessions, leak-checked):
  `zig build test-sonny3184-optional-match-distinct-call`.
- **WITH DISTINCT on every session (SONNY-3167, SONNY-6296 item 1):** on
  the in-memory, tenant-scoped and RLS sessions (the legacy executor) a WITH
  DISTINCT after a hop or comma pattern, or projecting a value, was ignored:
  `MATCH (q:Q),(z:Z) WITH DISTINCT q MATCH (q) RETURN count(*)` counted 32
  instead of 4, and `MATCH (q:Q)-[:R]->(x) WITH DISTINCT q.f AS f RETURN f`
  returned every duplicate. Such a WITH now runs in the shared WITH stage
  the planned read uses (projection, DISTINCT with NULLs equal, ORDER BY,
  SKIP, LIMIT), whatever the pattern. Regression (in-memory, persisted,
  tenant-scoped and RLS sessions, leak-checked):
  `zig build test-sonny3184-optional-match-distinct-call`.
- **The statement after a CALL { } is applied (SONNY-3389, SONNY-3167):**
  `CALL { MATCH (x:X) RETURN x.k AS k } RETURN count(*)` returned the body's
  rows; a RETURN that computed (`RETURN k + 1`), was DISTINCT or aggregated
  was ignored the same way; `... RETURN k ORDER BY k LIMIT 2` was a syntax
  error; and `CALL { } WITH k WHERE k > 1 RETURN count(*)` returned one 1
  per row and leaked the WITH's rows. The WITH, its WHERE and the RETURN
  (aggregates, GROUP BY, DISTINCT, ORDER BY, SKIP, LIMIT) are now computed
  over the body's rows by the shared projection. Not covered by this fix
  (follow-ups): a CALL { } after a MATCH (`MATCH (q) CALL { ... }`), the
  variable scope clause `CALL (q) { ... }`, OPTIONAL CALL, and two CALL { }
  in sequence. Regression (in-memory, persisted, tenant-scoped and RLS
  sessions, leak-checked): `zig build test-sonny3184-optional-match-distinct-call`.
- **A SKIP after CALL { } ... RETURN is applied once (SONNY-2680):**
  `CALL { MATCH (x:X) RETURN x.k AS k } RETURN k ORDER BY k SKIP 1 LIMIT 2`
  answered one row: the RETURN's window was applied inside the CALL { }
  executor and again by the statement. A literal or parameter SKIP, OFFSET
  and LIMIT now window it once. Every other window site (single query,
  chain, UNION, OPTIONAL MATCH, write RETURN, planned and legacy reads) was
  already applying `$p` once; the batch test pins them. Regression:
  `zig build test-sonny2672-read-semantics-batch`.
- **ORDER BY by a variable the RETURN does not project, and ORDER BY key
  errors (SONNY-2811):** `MATCH (n) RETURN n.k AS k ORDER BY n.x` came back
  unsorted on every session (the key was evaluated against the projected
  row, where `n` is unbound, and was NULL), and `RETURN n.k AS x ORDER BY
  n.x` sorted by the column `x`. Such a key is now computed with the
  projection as a hidden column, sorted on, and dropped after the window
  (a RETURN that is DISTINCT or aggregates is unchanged). **Behaviour
  change:** an error evaluating an ORDER BY key (for example 22003 integer
  overflow in `ORDER BY n.k + 9223372036854775807`) now fails the statement;
  it was sorted as NULL. A WITH's ORDER BY key error is covered since
  SONNY-6351 (below).
  Regression: `zig build test-sonny2672-read-semantics-batch`.
- **Implicit grouping is refused on every entry point (SONNY-2682):** a
  RETURN mixing aggregates with plain items and no GROUP BY is refused with
  42000 (`GroupingError`) on the in-memory, persisted, tenant-scoped and RLS
  sessions alike. Two entry points grouped it implicitly instead: the last
  part of a chained query (`MATCH (q) WITH q MATCH (q)-[:R]->(x) RETURN
  q.f, count(*)`) and VALUES ... MATCH. **Behaviour change:** those two now
  refuse it too; write the GROUP BY. Regression:
  `zig build test-sonny2672-read-semantics-batch`.
- **A procedure CALL's window (SONNY-2779):** `CALL p() YIELD x RETURN x
  ... OFFSET n` past the last row returned every row (now none), LIMIT and
  OFFSET leaked the rows they dropped, a SKIP or LIMIT parameter was
  ignored, and `SKIP n LIMIT m` after the RETURN was a syntax error. The
  standalone CALL's RETURN clause and MATCH ... CALL ... YIELD are covered
  since SONNY-6351 (below). Regression:
  `zig build test-sonny2672-read-semantics-batch`.
- **Read-semantics residuals (SONNY-6351):** (1) on the legacy executor
  (in-memory, tenant-scoped and RLS sessions) an error evaluating a RETURN
  item, or an ORDER BY key computed with the projection, leaked the column
  names and the rows projected so far; they are freed. (4) VALUES ...
  MATCH leaked what a VALUES row computed (`VALUES ('a' || 'b') AS (s)
  MATCH ...`): it moves to the query's scratch arena, released after the
  result is sent (embedded callers that install none keep the leak). (5)
  `CREATE (n:W
  {i: 1}) RETURN n.i AS i ORDER BY n.i` was a syntax error even with the
  server's parse options; a CREATE ... RETURN takes ORDER BY, SKIP and
  LIMIT (the created rows are sorted, the statement windows them). (6) an
  error in a WITH's ORDER BY key is no longer sorted as NULL: it fails the
  statement (22003 for an overflow), and the key sees the query's
  parameters. A standalone procedure CALL applies its RETURN clause and its
  YIELD aliases (`CALL db.labels() YIELD label AS l RETURN l` returns the
  column `l`; it kept `label` and returned the procedure's rows as they
  came). MATCH ... CALL ... YIELD runs the procedure once for each MATCH
  row (read under the session's tenant scope, RLS policies and WHERE, every
  chain and hop) with the row's variables bound, and its RETURN reads both
  (a MATCH variable was NULL: the executor matched the first node of each
  chain, ran the procedure once and leaked its rows; it also applied SKIP
  and LIMIT a second time). **Behaviour change:** MATCH ... CALL now yields
  one set of procedure rows per MATCH row, not one set in total. (2)
  `CALL db.labels()` omits a label the session's RLS label policy denies (it
  listed it; a deny entry hides every node carrying the label). (3) The
  embedded `geode.parseGql` accepts an expression ORDER BY key by default, as
  the server does; `GEODE_ORDER_KEYS_EXPR` set to anything but empty, `1`,
  `true` or `on` selects the identifier-only policy, read as the server reads
  it. **Behaviour change** (embedded callers): `ORDER BY n.prop` parses; it
  was a syntax error unless the variable was set (to any value, `0`
  included). Regression: `zig build test-sonny2672-read-semantics-batch`,
  `zig build test-sonny6351-labels-parse-default`.
- **A parsed MATCH takes the engine-direct fast paths again (SONNY-6383):**
  since the parser records each MATCH clause of a part (SONNY-3184, unreleased),
  the field allowlists of the engine-direct node scan stream and of the bulk
  `MATCH ... CREATE` / `MATCH ... MERGE` edge paths refused every parsed
  MATCH, so every simple scan, filtered count and bulk edge write went
  through the executor (slower; the GAP-ENT-0055 O(1) filtered count was
  lost). The clause record is accepted when it describes plain MATCH clauses
  only; an OPTIONAL MATCH still goes to the executor. Regression:
  `zig build test-sonny6383-scan-stream-match-clauses`,
  `zig build test-gap0902-bounded-analytical`.
- **Query residuals (SONNY-6383 items 2-9):** (2) `CALL { ... } WITH ...
  RETURN ...` accepted no GROUP BY, ORDER BY, SKIP / OFFSET or LIMIT after
  the RETURN (a syntax error); they are parsed and applied, the GROUP BY and
  HAVING being the RETURN's. (3) A RETURN mixing aggregates and plain items
  was accepted when the only GROUP BY was the WITH's (`WITH g, count(*) AS c
  GROUP BY g RETURN g, sum(c)`); it is refused with 42000 like any other
  ungrouped mix. (4) An aggregate's name inside a list comprehension's WHERE
  or map is the scalar function evaluated per element: `RETURN [x IN [1] |
  sum([1.5, 2])]` failed with a type error, the sum being computed over the
  rows; the comprehension's source is still over the rows (`[x IN
  collect(n.k) | ...]`). **Behaviour change:** an aggregate of the
  comprehension's variable in a grouped HAVING or beside an aggregate is
  evaluated per element; it was refused with 0A000. (5) The two legacy
  RETURN loops reported to leak are out of reach of a parsed query (an
  OPTIONAL MATCH part goes to the OPTIONAL MATCH executor since SONNY-3184;
  an aggregating RETURN to the shared projection since SONNY-2734); not
  changed. (6)
  A WITH's ORDER BY evaluates each key once per row and frees it; the sort
  re-evaluated both keys at every comparison and freed none (a leak for an
  embedded caller with no scratch arena). (7) A standalone CALL's RETURN
  keeps the procedure result's flags. (8) VALUES ... MATCH frees what its
  rows computed when no scratch arena is installed (an embedded caller): the
  result owns copies of its values. (9) `test-sonny2739-float-narrowing` and
  `test-sonny3251-limit-errors` failed on this branch from items 4 and 1.
  Regression: `zig build test-sonny6383-query-residuals`,
  `zig build test-sonny6383-call-return-flags`.
- **An exact integer sum stays exact; past i64 it is 22003 (SONNY-2774):**
  `sum()` over integers continued as a DOUBLE once the running total left
  the i64 range, on the shared projection and on the GROUP BY fast path
  alike (a silent exact-to-approximate change). Both, and the legacy
  aggregate loops, now sum integers in an exact 128-bit accumulator: a total
  that fits i64 is returned exactly whatever the sums in between were
  (`MAX + 1 - 2` is `MAX - 1`), and one that does not fails with 22003
  (numeric value out of range, ISO/IEC 39075:2024 20.9 General Rules).
  `avg()` divides the exact sum and stays a DOUBLE. **Behaviour change:**
  an integer `sum()` past i64 is an error, not an approximate DOUBLE.
  Regression: `zig build test-sonny2774-exact-sum`.
- **A plain RETURN after MATCH ... CREATE / MERGE is one row per matched
  row (SONNY-3025):** a RETURN that neither aggregated nor was DISTINCT was
  evaluated once, over the last row's created or merged elements, so `MATCH
  (n:G) CREATE (n)-[:T]->(m:Z) RETURN n, m` over 25 `:G` nodes returned one
  row. Every RETURN is now projected over the matched rows, each extended
  with what its CREATE created or its MERGE bound (ISO/IEC 39075:2024 14.11).
  A relationship MERGE's RETURN (`MATCH (a), (b) MERGE (a)-[r:R]->(b) RETURN
  r`) returned no row at all; it returns one per matched row with `r` and
  its endpoints. **Behaviour change:** such statements return one row per
  matched row. Regression: `zig build test-sonny3025-match-write-return-rows`.
- **A GROUP BY after a RETURN that follows a WITH (SONNY-2698):** the parser
  kept one GROUP BY / HAVING per query part whichever clause it followed,
  and every executor gave it to the WITH, so `MATCH (z) WITH z WHERE z.k >= 2
  RETURN z.g, count(*) GROUP BY z.g` grouped the WITH's rows to one per key
  and counted 1 (in-memory, persisted, tenant-scoped and RLS sessions). A
  GROUP BY, HAVING or WHERE written after the RETURN items now belongs to
  the RETURN (ISO/IEC 39075:2024 14.11: the `<group by clause>` is part of
  the `<return statement body>`), on the planned and legacy executors; one
  written between the WITH and the RETURN stays the WITH's. The legacy
  executor's own grouping (a node and a relationship copy that replaced
  HAVING with "the group has at least two rows" and skipped the WITH stage)
  is deleted. **Behaviour changes:** a part that groups both before and
  after its RETURN (`WITH g, count(*) AS c GROUP BY g RETURN c, count(*)
  GROUP BY c`, or a WITH's GROUP BY / HAVING and a WHERE after the RETURN,
  or `RETURN ... WHERE w GROUP BY k HAVING h`) is refused at parse time
  (`UnexpectedToken`): the second grouping used to replace the first
  silently. A grouped
  aggregate the shared projection does not serve is refused with 0A000
  (`UnsupportedGroupedReturn`) instead of being answered by the deleted
  grouping. Regression: `zig build test-sonny2672-read-semantics-batch`.
- **Pattern predicates in a grouped HAVING (SONNY-2699):** `GROUP BY q
  HAVING EXISTS { (q)-[:S]->() }`, `NOT EXISTS`, `COUNT { } = n`, an EXISTS
  with its own WHERE, and a COUNT { } in an item beside an aggregate
  (`count(*) + COUNT { (q)-[:S]->() }`) were refused with 0A000 since
  v0.8.23. Each variable the pattern reads from outside is now bound to the
  group's value when it is a grouping key or a projected variable, and the
  predicate runs under the session's tenant scope and RLS policies as a
  WHERE EXISTS does. A variable with no single value in the group (an input
  binding that is neither), and a pattern variable named like an output
  column that does not hold it, stay refused with 0A000; so do a
  `shortestPath` and an IN subquery in a grouped HAVING. Regression:
  `zig build test-sonny2672-read-semantics-batch`.

### Removed

- **`src/client/repl/repl_config.zig` `Config.load` / `save` (SONNY-6554):**
  written against removed Zig APIs and never compiled (no caller), with
  `getConfigPath` and `shouldUseColor`; and `session_state.getDefaultPath`,
  which called a function that does not exist. The CLI state-directory
  resolver (`cli_auth_helpers.resolveStatePath`) went with its last users
  (`session`, `authn`, `apikey` state files), and `tests/test_sec_sess_log.zig`
  with the `session rotate` output seam it pinned (rotate is refused; the
  no-token-in-output check moved to `tests/test_sonny6554_cli_honesty.zig`).

- **Distributed modules the server never reached (SONNY-6563, SONNY-6567
  item 7).** Each had no reference chain from the server root (`lib.zig`
  exported some as unreferenced `distributed.*` decls; the rest were
  imported only by their own test roots or by each other) and no symbol in
  the Debug `geode` binary: `src/distributed/raft_persistent.zig` (it
  persisted the term and not the vote, so a reopened node forgot its vote;
  the cluster uses the raft library's FileStorage, which keeps both),
  `raft_log_storage.zig` with `raft_consensus.PersistentStorage` and the
  no-op `RaftNode.setStorage`, `twophase.zig` (a 2PC transport) and
  `value_convert.zig`, `query_planner.zig` (`DistributedQueryPlanner`,
  `FederationManager`) and the never-assigned
  `ServerState.distributed_query_planner`, `network_transport.zig`,
  `enhanced_query_transport.zig`, `node_registry.zig` and its test,
  `sharding.zig`, `consistent_hash.zig`, `federation_flag.zig`; with their
  tests, benchmarks and steps (`test-dist-query-planner`, `test-sharding`,
  `test-gap0889`, `test-sonny6487-federation-flag-inline`, the red
  `test-sonny6548-raft-persistent-voted-for`; `test-gap0870` keeps its Raft
  command half, `test-sonny6453-cluster-peer-tls` its raft / coordinator
  dial). `src/distributed/README.md` lists what remains, all of it reached
  by the server. docs/TDE_FILE_LEVEL_ENCRYPTION.md named
  `raft_persistent.zig` as the encrypted Raft state: the Raft hard state,
  log and snapshots are written in plaintext by the library's FileStorage.

- **Product code no build reached, which no longer compiled (SONNY-6548 item
  3).** Zig analyzes lazily, so these compiled only because nothing in the
  server referenced them: `src/types/hash.zig` (`hash`, `argon2idStrHash`,
  `argon2idStrVerify`, `blake2bKdf` did not compile; `lib.zig` re-exported
  it as `types.hash`, and `HashData`/`Blake2bKdf`/`Blake2sKdf`/
  `Argon2idHash` in `src/types/evaluator_functions.zig` and
  `cryptographic.hashString` called it, none of them called; GQL has no
  such functions, `RETURN HashData(...)` is 42883),
  `src/query/materialized_views.zig` (exported as `materialized_views`, no
  caller; the GAP-0876 manager in `src/query/enhanced_materialized_views.zig`
  stays), `src/optimizer/selectivity_estimator.zig` (imported only by two
  dead tests; the server's estimator is `index_selectivity`), and
  `GraphStore.findPaths`, `findPathsBidirectional`, `findPathsFiltered`,
  `shortestPath`, `allShortestPaths`, `kShortestPaths`, `expandFromNode` with
  their helpers and `PathOptions`/`ExpandOptions`/`Path`/`PathFilter` in
  `src/graph_store.zig` (`std.ArrayList.init`; the executor's path matching
  is in `src/execution/match_operations.zig`). The seven listed tests that
  named them go too. CANARY markers that claimed TESTED for this code
  (`REQ-MATERIALIZED-VIEWS-001..005`, `REQ-GQL-HASH-FUNC-001`,
  `REQ-GQL-PATH-UTIL-001`) go with it.

- **`tests/benchmark_merge_adapter_variance.zig` (SONNY-6541 item 6).**
  `tests/all_tests.zig` imported it as an unreferenced constant, so nothing
  ever compiled it, and it could not compile (`std.time.nanoTimestamp`,
  `std.Io.getStdErr`, both gone in Zig 0.16). Its counter assertions are
  stale as well: MERGE resolves its node through the MERGE property index
  since GAP-0894, which the exact-lookup counter it asserted on does not
  count. What it checked live elsewhere: node and relationship MERGE take
  no read snapshot and no label scan (`zig build test-gap0511-regression`),
  and MERGE throughput (`zig build bench-merge`). Its two CANARY markers
  (REQ-PERF-MERGE-004, REQ-PERF-MERGE-007, BENCHED) go with it.
- **A statement or session transaction keeps its shard's WAL record batch
  (SONNY-6528 item 7).** `beginStatementTxn` and `beginSessionTxn` wrote out
  the batch `beginTxn` had opened (`releaseSpanningTxnWalBatch`), so a
  transaction spanning many adapter calls logged its page images one write
  at a time: with graph-storage before 0.4.14 its late-written older image
  of a page could follow a newer committed one and undo it after a crash
  (SONNY-2978). graph-storage 0.4.14 (pinned here) applies per page only the
  highest-LSN committed image (SONNY-6473), so the release is removed.
  Evidence: `zig build test-sonny2978-overlapping-engine-txn-crash` passed
  five runs out of five without it; `zig build
  test-sonny6492-edge-prop-image-cost` reports the same WAL bytes per SET
  before and after (8342 / 24826 B), in both sync modes.
- **Dead code: the standalone Louvain and label propagation (SONNY-6540
  item 10).** `src/graph/community_louvain.zig` and
  `src/graph/community_label_propagation.zig` were called only by their own
  inline tests and `tests/e2e_graph_algos_new.zig`; `CALL algo.louvain` and
  `CALL algo.labelPropagation` run `src/execution/centrality_algorithms.zig`
  (`test-gap0883`). Removed with that test file. Also corrected
  `docs/kb/VARIANCE_ENVELOPES.md` (the two calibration envelopes listed as
  tightened to CV 0.20 / p95 2.50 have no such thresholds; the structural-key
  collision benchmark is compiled by no step) and annotated
  `docs/performance/2026-04-20-query-bench/FINAL.md` (the AST cache does not
  use `structural_key.zig`).
- **Dead code: `src/ml/integration_enhanced.zig`, `src/planner/pipeline.zig`
  and `src/planner/cost_calibration.zig` (SONNY-6555 item 8).** No server
  path reaches any of them (the server binary builds without them):
  `integration_enhanced.zig` (a second Node2Vec, a PageRank, a third
  Louvain, link prediction and `gds.node2vec/pageRank/louvain/linkPrediction`
  procedure stubs that no dispatcher registered) was compiled only by its own
  in-module tests in `test-gap0879` and `tests/e2e_ml_integration.zig`
  (compiled by nothing); `pipeline.zig` (the synthetic plan-selection runner)
  and `cost_calibration.zig` (with `cost_model.estimateWithCalibration`, its
  only user) only by `lib.zig`'s inline-test roots and three canary tests
  (`canary_planner_pipeline_selection`, `canary_planner_cost_model`,
  `canary_planner_join_reorder`). Removed with those tests, their build.zig
  registrations, the `test-canary-planner-pipeline-selection` step (and its
  perf-gate CI entry), and their allowlist rows. `src/canary.zig` claimed
  REQ-GQL-075 "Query Optimizer / AdvancedCostModel" TESTED by
  `TestCANARY_REQ_GQL_075_AdvancedCostModel`, which does not exist, and a
  BENCHED envelope of a benchmark that does not compile; both rows removed.
  Docs corrected: ML_GRAPH_EMBEDDINGS.md, CURRENT_ARCHITECTURE.md,
  SERVER_FEATURES.md, kb/PROFILING.md, kb/VARIANCE_ENVELOPES.md.
- **Dead code: the planner's `PathExpand` operator (SONNY-6540 item 6).**
  `PathExpand` and its `AdjacencyList` (`src/planner.zig`) were reached by
  no query: nothing outside `planner.zig` named them except 17 test and
  benchmark files that no build step compiled (they imported
  `../src/planner.zig`, outside any module) and the two inline tests
  `test-sonny6511-lib-inline` ran. Its simple-path check compared edge ids
  with node ids, and every result's `start_id` was the first start node, so
  it would have answered wrongly had anything called it. Variable-length
  patterns are expanded by `src/execution/match_operations.zig`. Removed
  with the 17 files and their REQ-GQL-016 CANARY markers.
- **Dead code: the `tryBasicFunction` branches the call handlers answer
  first (SONNY-6540 item 7).** `evalExpr` tries `src/eval/call_handlers.zig`
  (math, string, type-cast, collection, aggregate and advanced-type
  handlers) before `tryBasicFunction` (`src/eval.zig`), and each of those
  handlers answers every call of the names it owns (a value or an error,
  never "not mine"), so `tryBasicFunction`'s own branches for keys, values,
  length, size, upper, lower, trim, abs, sqrt, ceil, floor, pow, sin, cos,
  tan, asin, acos, log, exp, toString, toInteger, toFloat, toBoolean, head,
  tail, last, substring, replace, icontains, reverse, count, sum, avg, min,
  max, random, interval and range, and its second and third `type()`
  branches, never ran. They are removed; `power`, `log10`, `toReal`,
  `rand`, `duration` and the `decimal_*` functions, which only it answers,
  stay. No behaviour changes. One of the removed branches carried a
  CANARY claiming `length(NULL)` is NULL (REQ-BUG731-MATCH-SCOPING
  PathLength/NullPropagation); the live handler answers 0, so the claim
  was never true (reported for a follow-up).
- **Dead code: `ChunkedMemoryMap`, the graph-scoped audit log and
  `GraphRBACPolicy.getRolesForGraph` (SONNY-6511 item 1).**
  `ChunkedMemoryMap` and its `CacheStats` (`src/performance/memory_mapped_io.zig`)
  did not compile on Zig 0.16 (`getEndPos`, `seekTo`, `writeAll`,
  `sync()` on `std.Io.File`); only their own tests and an unbuilt test file
  named them. `GraphAuditEvent` / `GraphAuditLog` and
  `GraphRBACPolicy.getRolesForGraph` (`src/security/multi_graph_security.zig`)
  did not compile either and nothing called them; graph-scoped audit
  events go through `src/security/audit.zig` (`resource_graph`). The
  per-graph grant model the server uses (`grantGraphPermission`,
  `hasGraphGrant`, `loadGraphGrants`, the global policy) is unchanged and
  its inline tests now run.
- **Dead code: the synthetic planner pipeline and the modules only it drove
  (SONNY-6511 item 1).** `src/planner/{wcoj,adaptive_replan,phase_timing,rewrite,path_cache}.zig`,
  `pipeline.runPipeline` / `planQueryWithPipeline` / `plannerPathCacheLookup`
  / `plannerPathCacheInsert` / `planQueryRealTimed`, `planner.planQueryPhasedTimed`
  and 15 test files that only tested them. `runPipeline` described itself
  as "a deterministic synthetic pipeline used for integration tests &
  variance bench"; none of it ran in a query. None of it compiled on Zig 0.16
  (`std.math.fabs`, `std.time.nanoTimestamp`, array literals for mutable
  slices, string literals for `IdentRepr`), and no executable or running
  test reached it: the WCOJ executor was named only by `geode.planner_wcoj`
  and `tests/test_wcoj.zig` (an unreferenced `tests/all_tests.zig`
  constant); the rest only by `pipeline.zig` and test files no build step
  roots. `pipeline.planQuerySelectBest` (`zig build
  test-canary-planner-pipeline-selection`), the cost calibration it uses and
  `structural_key.zig` (the `bench_pathcache_degree_util` benchmark) stay.
  `docs/SERVER_FEATURES.md` (adaptive re-planning, PathCache) and the
  variance-envelope and crosswalk notes described the removed code.
- **Dead code: `src/server/flagger_impl_defined.zig` and the server's
  implementation-defined flag cache (SONNY-6511 item 1).** A second list of
  the ISO/IEC 39075 Annex B implementation-defined items whose `collect`
  did not compile on Zig 0.16 (`ArrayList.deinit()` without the
  allocator). `server_flags.initImplDefinedFlags`, its only product caller,
  was itself called by nothing (`src/server/main.zig` only aliased it), so
  the cache `getImplDefinedCodes` read stayed empty and nothing read that
  either. They go, with the uncompiled `tests/test_protocol_impl_defined_flags.zig`.
  The items remain listed by `conformance.collectImplDefinedFlags`
  (`zig build test-sonny6494-inline`); the server does not send that list to
  clients, which `docs/BINARY_PROTOCOL.md` now says.
- **Dead code: `src/server/txn/mvcc.zig` and
  `src/server/txn/phantom_read_prevention.zig` (SONNY-6511 item 1).** An
  MVCC manager and predicate-lock phantom prevention the server never ran
  (see `docs/ENHANCED_TRANSACTION_ISOLATION.md`). Neither compiled on Zig
  0.16 (`ArrayList.deinit()` with no allocator in the transaction, lock
  and manager `deinit`, `ArrayList.init` in `PhantomReadPrevention.init`),
  and nothing used them: a whole-repo search finds only the
  `geode.server_mvcc` re-export, which nothing named, and two test files
  no build step rooted (`tests/test_phantom_read_mvcc_integration.zig`,
  `tests/test_distributed_query_mvcc_integration.zig`), which go too.
  Their TESTED markers (REQ-TXN-PHANTOM-*, REQ-DISTRIBUTED-QUERY-007..009)
  described only this code.
- **Dead benchmarks: `src/benchmarks/pagination_variance.zig`,
  `src/benchmarks/pagination_execution_variance.zig` and
  `benchmarks/benchmark_pagination_order_variance.zig` (SONNY-6511
  item 1).** Variance envelopes of the planner phase timer on one
  `ORDER BY ... LIMIT` query and of a synthetic per-page workload ("simulates
  execution-phase latency"), not of geode's paging. Neither `src/benchmarks/` file
  compiled on Zig 0.16 (`std.time.nanoTimestamp`, `std.io.fixedBufferStream`)
  and nothing ran them: their only references were the
  `geode.benchmarks.pagination*` re-exports, which nothing named; the
  `benchmarks/` copy was rooted by no build step. Their BENCHED markers
  (REQ-GQL-004 PaginationOrderedVarianceEnvelope,
  PaginationExecutionVarianceEnvelope) described only these files.
- **Dead code: `src/types/i256.zig` (SONNY-6511 item 1).** An `Int256`
  stub (`add` with a `comptime_int` carry that cannot compile, `toString`
  allocating from `std.testing.allocator` in product code) that nothing
  used: its only reference was the `geode.types.int256` re-export, which
  nothing named. Geode has no 256-bit integer type.
- **Dead code: 37 of the 40 files under `src/graph/` and the 64 test files that only tested them
  (SONNY-6511 item 1 and 2).** A second set of graph algorithms and
  containers (builders, centrality incl. the "optimized" PageRank and
  closeness, traversal, topological sort, cycle detection, shortest paths,
  flow, connectivity, spanning trees, Leiden, bloom filter, count-min
  sketch, skip list, trie, KMP) that no executable called: the server's
  `CALL algo.*` procedures run `src/execution/centrality_algorithms.zig`.
  `src/graph/builders.zig`, which most of them build on, did not compile on
  Zig 0.16, nor did 14 others; the tests that used them were rooted by no
  build step or were unreferenced `tests/all_tests.zig` constants, which
  the compiler never analyses. `community_louvain.zig`,
  `community_label_propagation.zig` (`zig build test-e2e`,
  `tests/e2e_graph_algos_new.zig`) and `containers/lfu.zig`
  (`fuzz/targets/lfu_cache_fuzz.zig`) stay: a running test uses them.
  `docs/GRAPH_ALGORITHM_PERFORMANCE_ENHANCEMENTS.md` and the "20-90%
  performance gains" of Phase 7 described the removed modules.
- **`src/fts/advanced.zig`, `src/fts/bm25.zig` and
  `NetworkTransport.sendToNode` (SONNY-6499 item 4).** Nothing reached them
  and they did not compile: `LanguageAnalyzer.analyze` used the managed
  `std.ArrayList(T).init` that Zig 0.16 removed (its CANARY marker said
  TESTED; it was re-exported as `lib.fts_advanced` and never referenced),
  bm25.zig was imported only by it and by an unregistered skeleton test,
  and `sendToNode` called `std.time.sleep` and a `QuicTransport.connect`
  that do not exist. `EnhancedQueryTransport.sendWithRetry`, its only
  caller (itself unreached), now refuses (`InterNodeSendNotImplemented`)
  instead of claiming a send. docs/SERVER_FEATURES.md no longer claims
  Porter stemming, a configurable stop-word list or Levenshtein fuzzy
  matching for full-text search: none exists.

- **Dead benchmark: `tests/benchmark_hashagg_distinct_variance.zig`
  (SONNY-6456 item 5).** No build step compiled it and it could not
  compile: it imports `exec.zig`, `eval.zig` and `gql/ast.zig` relative to
  `tests/` (no such files), discards a capture (`|_|`), and calls
  `runGroupedQuery` with the old seven-argument arity. Grouped
  `count(DISTINCT ...)` is covered by `zig build
  test-sonny2675-grouped-having` and `test-sonny2675-aggregate-semantics`.
  Its BENCHED marker
  (REQ-GQL-012 HashAggDistinctHighCardVarianceEnvelope) described only that
  file. The netns membership-churn script's `kill_and_reap` now matches
  the binary under test by the name of `$BIN` (the script's first
  argument) instead of only a binary named `geode`, so a renamed binary
  (for example `geode-debug`) is stopped and reaped between restarts.
- **Dead code: three test files no build step compiles, and an unused
  import (SONNY-6447 item 9).** `tests/test_build_system_module_dependencies.zig`,
  its sibling `tests/test_build_system_module_dependencies_integration.zig`
  and `tests/index_optimizer_regression_test.zig` were referenced by no
  step and could not compile (Zig 0.15 `ArrayList(...).init`, an `@import`
  outside the module path, `try` on the `void` `removeNodeProperty`); what
  they touched is covered by compiled tests. Their CANARY markers
  (REQ-BUILD-SYSTEM-MODULE-DEPS-001..003 and -INTEGRATION-001..003)
  described only these files. `src/server/main.zig` no longer imports the
  unused `geode.exec`, and `tests/benchmark_hashagg_spill_variance.zig` no
  longer names the removed `HashAggregator`.
- **Dead benchmark: `tests/benchmark_hashagg_spill_variance.zig`
  (SONNY-6451 item 4).** It measured spilling in the `HashAggregator`
  removed under SONNY-6436 item 6 (geode has no aggregation spill path),
  no build step compiled it, and it could not compile (`../src` imports
  outside the module root, `ArrayList.init`, `std.mem.copy`, and the old
  `runGroupedQuery` arity). Its BENCHED marker (REQ-GQL-012
  HashAggSpillVarianceEnvelope) described only that code.
- **Dead code: `match_operations.executeMatchWithOptionalPatterns` and the
  legacy aggregate RETURN-after-WITH stage of `executeMatchQueryImpl`
  (SONNY-6437 item 4).** Neither was reached by a parsed query: an OPTIONAL
  MATCH clause is served by the left outer join (`optional_match`) or, with
  a SET or REMOVE, by the write step; an aggregating RETURN after a WITH by
  the shared projection, after an initial WITH once the WITH is bound. A
  reference search finds no other caller, and a run with a panic at both
  sites (`test-sonny6437-query-residuals`, `-2672-read-semantics-batch`,
  `-3184`, `-3039`, `-3041`, `-2694`, `-2674`, `-2675`, `-3148`,
  `gap0055`, `r4b-memory`, `gql-conformance` and 17 probe shapes) never
  hit either. About 1,770 lines go, with the helpers only the executor used
  (`whereReferencesLaterChains`, `whereNamesUnboundBy`); a query built
  another way that reaches either site is refused
  (`UnsupportedOptionalMatchShape`, `UnsupportedGroupedReturn`).
- **Dead code: `GraphStore.restoreNodeNoSave` / `restoreEdgeNoSave`
  (SONNY-6436 item 4).** No caller anywhere in the repository (a reference
  search finds only their definitions); both tagged the restored row tenant
  `default`.
- **Dead code: the old `src/server/graph/exec.zig` engine and
  `src/exec.zig`'s `HashAggregator` (SONNY-6436 item 6).** No executable
  reaches `server/graph/exec.zig` (it was re-exported as
  `geode.graph_exec` and imported only by test files no build step
  compiles); its `isTruthyValue` (a non-zero integer or non-empty string as
  true) went with it, with `tests/canary_property_access.zig`,
  `tests/debug/debug_property_access.zig`,
  `tests/benchmark_match_label_property_variance.zig` and the one test of
  `tests/index_optimizer_regression_test.zig` that used it. `src/exec.zig`
  is live (the `gql` executable runs its grouping and set operations;
  `groupAndAggregate` accumulates sums with overflow detection, and
  `runGroupedQuery`'s HAVING keeps a group only when True),
  but its `HashAggregator`, with the unchecked `+=` sums, was referenced by
  nothing in `src/` and no longer compiled (Zig 0.15 ArrayList calls); it
  and the eleven uncompiled `tests/*hashagg*` / mixed-aggregation files that
  only exercised it are removed. Their CANARY markers
  (REQ-WHERE-EVAL-001, REQ-WITH-WHERE-001, REQ-EXPR-TYPE-003,
  REQ-DECIMAL-OVERFLOW-001/002 and two REQ-GQL-017 entries) described
  only this code.
- **Test files no build step compiled, cited by TESTED markers (SONNY-6430
  item 4).** `tests/test_mfa_policies.zig` now drives the real
  `SecurityManager` and runs as `zig build test-mfa-policies` (6/6); the
  attestation signature checks of `tests/test_remote_kms_attestation.zig`
  run in `test-remote-kms-hardening`
  (`SignatureVerifyTamperDetect`). Removed, with their markers repointed to
  tests that run: `tests/canary_mfa_core_additional.zig` (it removed
  recovery codes itself and called no product code),
  `tests/test_remote_kms_auth_negative.zig` (covered by `InvalidAuth`),
  `tests/test_remote_kms_unwrap_attest.zig` and
  `tests/test_tde_oltp_overhead_threshold.zig` (it asserted `true`). The
  "<5% TDE overhead" figure in README.md and docs/KMS_PROVIDER_SYSTEM.md is
  now called a target: no geode test measures it.
- **The uninstalled mutation-notify callback in `src/graph_store.zig`
  (SONNY-6430 item 3).** `setMutationNotify` / `setMutationNotifyInhibit`
  had no caller since the WAL wrapper was removed (SONNY-6422), so the 15
  `notifyMutation` calls in the store's write paths never did anything; they,
  the callback type, `MutationOp` and the IMPL marker `REQ-PERF-WAL-002` are
  gone, with the graph-name copy `deleteEdge` made only for the notification.
- **The logical CDC `WriteAheadLog` wrapper in `src/wal.zig`, an unbuilt
  duplicate test, and false TESTED markers (SONNY-6422 items 3-5).** The
  wrapper (record types and serialization, the global instance, the
  `graph_store` mutation callback and the `GEODE_WAL_KEY` loader) had no
  production caller since `initGlobalWal` was removed (SONNY-6325); only
  `tests/test_wal.zig` opened one. `src/wal.zig` keeps the persistence-loop
  hooks the server installs (a light engine checkpoint every tick, the
  behaviour they had with no WAL behind them), and `zig build test-wal` now
  tests those. Crash recovery and WAL encryption are the storage engine's
  (its WAL, encrypted with `GEODE_TDE_KEY`). `tests/test_key_rotation_schedule.zig`
  was built by no step and claimed TESTED with a made-up test name; its two
  assertions are those `zig build test-gap0890` runs, so it is removed. The
  CANARY block of `docs/SECURITY_PROGRESS.md` cited tests that do not exist
  or that no step compiles: each TESTED marker now cites compiled tests, and
  WAL encryption, MFA audit logging, the MFA policy engine and the OLTP
  overhead validation are IMPL, with the matrix rows corrected. Regression:
  `zig build test-sonny6422-dead-wal-and-false-markers`.
- **Federated / scatter-gather query coordination code (SONNY-6279).**
  `src/distributed/federation.zig`, `federation_merge.zig`,
  `merge_strategies.zig`, `query_coordinator.zig`,
  `enhanced_query_coordinator.zig`, `query_transport.zig`, `result_utils.zig`
  and `mod.zig` were reachable from no executable or test in `build.zig`, so
  they were never compiled and nothing ran them. They are removed, with the
  tests and benchmarks that only exercised them. The docs that described
  distributed query coordination, federation-aware optimization and load
  balancing as working now say it is not implemented: a query runs on the
  node that receives it. The cluster path (Raft, `ClusterCoordinator`,
  replicated writes within the documented slice, fail-closed unreplicated
  surfaces) is unchanged.
- **`EnhancedRLSEngine.rewriteQueryEnhanced` (SONNY-6279).** It had no
  caller and spliced policy text into the query string; it is removed with
  its three private helpers.
- **Uncompiled probes, scaffolds and utilities (SONNY-6298).** These files
  were reachable from no executable or test in `build.zig`, and nothing
  outside `build.zig` ran them: `src/probe_{arraylist,fmt,io}.zig`,
  `src/dist/{rpc,scaffold}.zig` (a Raft/2PC RPC scaffold; the cluster's Raft
  traffic goes through `src/distributed/cluster.zig` and
  `raft_consensus.zig`), `src/util.zig`,
  `src/util/{yaml,yaml_test,memory_governor,conformance_generator}.zig`,
  `src/storage/{mod,snapshot_pipeline,queue_depth}.zig`,
  `src/federation/router.zig` (a stub that always returned `unsupported`) and
  `src/performance/{async_io,async_io_simple,simple_async_io,collection_optimized}.zig`.
  They are removed with the uncompiled tests and benchmarks that only
  exercised them; the cases in uncompiled mixed tests
  (`tests/priority_implementations.zig`, `tests/test_canary_core.zig`,
  `tests/test_performance_integration.zig`) that called them are removed and
  the rest is kept.
- **Uncompiled index snapshot writers, schema/transaction facades and the old
  Raft shim (SONNY-6298).** `src/index/{rtree,patricia,domain_trie,jsonb_inverted}_persist.zig`
  and `src/index/registry.zig` were never compiled (the domain-trie and JSONB
  writers were exported from `src/lib.zig` but nothing referenced them;
  compile-error probes in them never fired). The R-tree, Patricia, domain-trie
  and JSONB indexes therefore have no on-disk snapshot, and
  `docs/TDE_FILE_LEVEL_ENCRYPTION.md` no longer lists TDE-encrypted snapshot
  files for them. `src/schema/schema_manager.zig`,
  `src/transactions/{transaction_manager,two_phase_commit}.zig` (facades no
  code imported) and `src/distributed/raft.zig` (a string-node-ID shim over
  `raft_consensus.zig` whose only importer was removed in SONNY-6279) are
  removed with the uncompiled tests that imported them.
- **Uncompiled query optimizers and transaction-isolation code; the docs that
  claimed them (SONNY-6298).** `src/server/index_optimizer.zig`,
  `src/server/index_statistics.zig`, `src/server/union_advanced.zig`,
  `src/planner/{adaptive,optimizer,query_optimizer,stats_registry,rescore,cbo_small_n,gpu_cost_model,cost_cardinality_feedback}.zig`
  and `src/server/txn/{enhanced_isolation,isolation_integration}.zig` were
  reachable from no executable or test, so the cost-based IndexOptimizer and
  the "Enhanced Transaction Isolation" system (six isolation levels, SSI,
  predicate-lock phantom prevention, deadlock detection) never ran. They are
  removed with the uncompiled tests that exercised them. `CLAUDE.md`,
  `README.md`, `docs/FEATURES_OVERVIEW.md`, `docs/SERVER_FEATURES.md`,
  `docs/EXPLAIN_PROFILE.md`, `docs/CURRENT_ARCHITECTURE.md` and the index
  pages now say what the server does: index use is rule-based (UNIQUE-indexed
  equality seek, otherwise a label scan) and EXPLAIN shows fixed per-operator
  costs; writes are serialized per graph, each read sees one snapshot, and
  explicit transactions roll back through an undo log, with no isolation
  levels. `docs/ENHANCED_TRANSACTION_ISOLATION.md` and
  `docs/BM25_INDEX_OPTIMIZER_INTEGRATION.md` are now status notes.
- **`src/types/network/` (SONNY-6298).** `ipaddr.zig`, `subnet.zig`,
  `mac.zig` and `mod.zig` were an older copy of the network types that no
  build artifact compiled; the one consumer, the uncompiled root-level script
  `validate_current_features.zig`, goes with them. The network types the
  server uses are `src/types/network.zig` (over the `advanced_types`
  library), unchanged. The "<1μs parsing" figure is dropped from `CLAUDE.md`
  and `README.md`: no benchmark in the repository measures it.
- **Uncompiled security files; TDE-KMS integration documented as not
  implemented (SONNY-6298).** `src/security/tde_kms_integration.zig` (a
  `TDEKeyManager` that took the TDE master key from a KMS provider),
  `key_provider.zig`, `secure_mem.zig` and `backup_key_envelope.zig` were
  reachable from no executable or test, so none of them ever ran. They are
  removed with the uncompiled tests and benchmarks that used them, and the
  `key_provider.zig` case of `src/security/test_secure_zero.zig` (an
  `@embedFile` source check of the removed file) goes too.
  `docs/KMS_PROVIDER_SYSTEM.md`, `CLAUDE.md`, `README.md`,
  `docs/FEATURES_OVERVIEW.md`, `docs/security/README.md` and
  `docs/SECURITY_PROGRESS.md` now say that the TDE master key comes from
  `GEODE_TDE_KEY` and is not fetched from or wrapped by any KMS;
  `GEODE_KMS_URL` only makes startup fail when the endpoint is unreachable;
  `GEODE_KMS_PROVIDER` / `GEODE_VAULT_KEY_PATH` are read by nothing; and
  key-registry backup export/import is not implemented. The KMS provider
  clients in `src/security/kms.zig`, `kms_remote.zig`,
  `external_kms_client.zig` and `vault_kms_provider.zig` are unchanged.
- **Unread state in live files (SONNY-6298).** The QUIC handler created a
  `DistributedQueryPlanner` and `FederationManager` for every stream and
  stored them in two `ServerState` fields nothing read; they are gone.
  `rls_filter.applyRLSToFederatedResults` (no caller since the federation
  code was removed in SONNY-6279) and its tests are removed, as is
  `EnhancedRLSEngine.policy_optimizer` / `PolicyOptimizer`, which was only
  initialised and freed.
- **Uncompiled tests that carried TESTED markers (SONNY-6298).**
  `tests/test_rls_enhanced.zig` (8 TESTED markers; its subject,
  `src/security/rls_enhanced.zig`, is never analyzed by any build artifact),
  `tests/test_enhanced_query_transport.zig` (3 TESTED markers for
  cross-shard query coordination; it tested local mock structs only) and
  `tests/canary_raft_partition_simulation.zig` (asserted a boolean it had
  just set) were in no build step and are removed. The always-true
  assertions in the uncompiled `tests/test_gap_0193_batch2_testing.zig` now
  assert what they meant; its distributed-query case would fail, because
  neither `QueryCoordinator` nor `Federation` exists.
- **Uncompiled demos, micro-benchmarks, tools and containers (SONNY-6298).**
  `src/audit_demo.zig`, `src/bench/ordering_cmp_bench.zig`,
  `src/benchmarks/{adaptive_replan_autotune_variance,pagination_prefetch_sim,tde_bench}.zig`,
  `src/tools/{canary_freshness,doc_sync}.zig`,
  `src/runtime/{multi_loop_pseudocode,poller_iface}.zig`, `src/sentinel.zig`
  (a guard-byte allocator nothing used), `src/flagger_impl_defined.zig` (an
  older copy of `src/server/flagger_impl_defined.zig`, which is unchanged),
  `src/compat.zig`, `src/testing/fake_fs.zig` and
  `src/containers/{cursor_container,signaled_queue}.zig` were reachable from
  no executable or test, and nothing outside `build.zig` ran them. They are
  removed with the uncompiled tests and benchmarks that only exercised them.
- **Superseded modules that no build artifact compiled (SONNY-6298).**
  `src/geode_main.zig` (the `geode` executable's root is
  `src/unified_entry.zig`), `src/index.zig` (a `zig init` template),
  `src/parser/{lib,tokenize}.zig` (a partial schema-grammar stub; GQL is
  parsed by `src/gql/parser.zig`), `src/gql/match.zig` (MATCH runs in
  `src/execution/match_operations.zig`), `src/txn_session.zig`,
  `src/graph/{aggregator,pattern_matcher,concurrency_safe,path_algorithms}.zig`,
  `src/eval/temporal_arithmetic.zig`, `src/server/allocator_config.zig` (the
  server allocator is chosen by `ServerAllocator` in `src/server/main.zig`),
  `src/server/graph/variable_paths.zig`, `src/timeseries/chunk_storage.zig`
  and `src/build_options.zig` (the `build_options` module is generated by
  `build.zig`) are removed, with the uncompiled tests that imported them.
  `docs/TRANSACTION_MANAGEMENT.md` no longer says that a transaction is
  saved to a session file and survives across `geode query` invocations:
  the server keeps transaction state per connection.
- **Uncompiled CLI user-storage files and DB audit adapter (SONNY-6298).**
  `src/cli/user_storage_secure.zig` (an AES-256-GCM `users.dat` file store),
  `src/cli/user_storage_simple.zig`, `src/cli/user_management.zig` and
  `src/audit/db_adapter.zig` were reachable from no executable or test, so
  none of them ever ran. User records are stored in the HMAC-chained
  `__geode_security` graph (`src/server/persistent_auth_resolver.zig`,
  `src/security/user_management.zig`); there is no separate encrypted user
  file. The status notes in `docs/TODO.md` and
  `docs/GAP_ANALYSIS_RESOLVED.md` (GAP-0001) say so. The database-operation
  case of the uncompiled `tests/test_audit_integration.zig` goes with the
  adapter.
- **Uncompiled fuzz and GPU stubs (SONNY-6298).**
  `src/fuzz/decimal_order_fuzz.zig` and `src/fuzz/graphstore_durability_fuzz.zig`
  were in no build step, so the documented workflow (`zig build test
  --fuzz`, `fuzz/README.md`) never ran them; the wired targets under
  `fuzz/targets/` are unchanged.
  `src/gpu/opencl_loader.zig` (OpenCL bindings nothing imported) and the
  empty `src/gpu/driver_link.zig` were named by no build option either;
  the Vulkan GPU path is unchanged, and OpenCL has no detection path
  (`tests/test_gap0878_gpu_truth.zig`).
- **Never-compiled tests registered or corrected (SONNY-6298).**
  `src/security/test_tde_nonce.zig` is now `tests/test_tde_nonce.zig`,
  step `test-tde-nonce` (6/6: nonce uniqueness over 10,000 encryptions,
  nonce byte diversity, round-trip, wrong AAD and tampered ciphertext
  rejected). `tests/test_gap_0193_batch2_security.zig` is registered as
  `test-gap0193-batch2-security` (37/37). The always-true `or true`
  assertions in the GAP-0193 batch-2 security, engine and misc files and in
  `test_gap_0193_impl_verification.zig`, and the
  `x != y or x == y` assertion in `tests/priority_implementations.zig`, now
  assert what they meant. The engine and misc files stay unregistered: 7
  and 5 of their cases parse syntax the ISO GQL parser rejects (UNWIND,
  `CREATE CONSTRAINT ... ASSERT`, `BEGIN TRANSACTION`, `[*]`). In
  `test_gap_0193_impl_verification.zig` the CDC, metrics and CLI cases
  would now fail (the geode module exports no `cdc`, `metrics`/`telemetry`
  or `cli`). The mock-only `tests/e2e_cbo_small_n.zig` is removed.
- **CANARY markers that cited a never-compiled test (SONNY-6298).** 45
  markers cited `TEST=tests/test_tde_kms_integration.zig`, which was in no
  build step and was removed. 42 are now `STATUS=IMPL`: the 34 TDE
  procedure handlers in `src/execution/storage_dispatch.zig` and 8 FLE
  markers (`ast.zig`, `parser.zig`, `graph_store.zig`, `blind_index.zig`,
  `schema/annotations.zig`, `fle_hooks.zig`, `admin/fle_commands.zig`,
  `cli/fle_cli.zig`); no compiled test drives them. Three point at compiled
  aggregate tests that exercise them: `fle_catalog.zig` →
  `test-fle-online-grant`, `fle_integration.zig` → `test-gap0852`,
  `keys/types.zig` → `test-fle-lifecycle`. `docs/status.csv`: TESTED
  5,272 → 5,230, IMPL 216 → 258 of 5,940, above GAP-0514's ≤250 target;
  `CLAUDE.md`, `README.md` and the docs that state the counts say so.
- **`src/security/rls_enhanced.zig` (SONNY-6298).** The "Enhanced RLS"
  layer (`EnhancedRLSEngine`, `ExpressionCompiler`, `RLSStatisticsCollector`,
  `EnhancedCacheManager`) was exported from `src/lib.zig` but never analyzed
  by any build artifact: compile-error probes at file scope and in its
  public functions stayed silent in `zig build` and five RLS steps while
  control probes in `lib.zig`, `rls_core.zig` and `rls_filter.zig` fired.
  It is removed with its export. Row-level security is
  `src/security/rls_core.zig` (policies, bytecode expression policies in
  the MATCH loop, `current_user()` / `has_role()`, temporal and IPv4 CIDR
  conditions, policy cache) and `src/server/rls_filter.zig`, unchanged.
  `CLAUDE.md`, `README.md`, `docs/FEATURES_OVERVIEW.md`, `docs/README.md`,
  `docs/SERVER_FEATURES.md` and `docs/CURRENT_ARCHITECTURE.md` say so and no
  longer claim an RLS policy optimizer; status notes in
  `docs/ADVANCED_SECURITY_FEATURES_OCTOBER_2025.md` and
  `docs/GAP_ANALYSIS_RESOLVED.md` (GAP-0047, GAP-0287, GAP-0294).
  `docs/status.csv`: 5,940 → 5,937 rows (its one IMPL and two EXEMPT
  markers); IMPL is 257, still above GAP-0514's ≤250 target.

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
    converge on 22003. (Converged in the Unreleased section: SONNY-2774.)
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
  WHERE after `WITH ...` before a FOR is not applied. Writes in these shapes
  are refused. v0.8.24. (Unreleased: EXISTS { } with an inner WHERE is
  answered correctly since SONNY-2707; the OPTIONAL MATCH reads since
  SONNY-3184; WITH DISTINCT on the legacy path and the RETURN after
  `CALL { }` since SONNY-3167 / SONNY-3389.)
- **A plain RETURN after MATCH ... CREATE is one row (SONNY-3025):** a RETURN
  that neither aggregates nor is DISTINCT is evaluated once, over the last
  row's created and matched elements; the CREATE itself runs once per
  matched row. Aggregate the RETURN, or make it DISTINCT, to see every row.
  v0.8.24. (Fixed in the Unreleased section.)

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
