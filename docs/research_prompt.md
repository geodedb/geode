## DRA Prompt — ISO‑GQL–Aligned Research Report for a High‑Performance, Distributed, ACID Graph DB (with Zig POCs)

**As of:** 2025‑08‑30

### 0) Primary Inputs (treat these as normative/baseline)

- **ISO/IEC 39075:2024 (GQL)** — official property‑graph query language: scope, data model, grammar, semantics, features, and conformance (minimum + optional features). Use subclause anchors for traceability (e.g., _14.3 linear query statements; 14.4 match; 18.6–18.8 property types; 7._ session control; 9.2 procedures; 24.\* conformance; 23.2 diagnostics; 11.\* expressions; 21.\* lexical elements\*). &#x20;

  - **GQL scope & model.** GQL is a **declarative, transactional** language for **property graphs** and provides pattern‑matching semantics; it shares graph‑pattern syntax with SQL/PGQ but is **independent from SQL**. Use these statements as design invariants for your language layer and query engine.&#x20;

- **Existing Research Plan PDF** — use as structural backbone for chapters and Zig POC coverage; update all language/query sections to be GQL‑first.&#x20;

### 1) Objective

Produce a **highly detailed, technical research report (Markdown)** for a **low‑level Zig engineer** who will implement the **binary protocol, file storage, and system components** of a **novel, ACID‑compliant, distributed property‑graph database**. The report must be **ISO‑GQL aligned** and include **Zig Proof‑of‑Concept (POC)** code for critical components.

### 2) Scope & Research Questions (expand each into subsections with evidence + Zig POCs)

**A. Core Architecture & Data Model (GQL‑aligned)**

- **Map the data model** to GQL’s property graph: nodes/edges, labels, properties, supported property value types, identifiers and lexical elements; show how these choices influence binary layout and in‑memory form. Anchor to _Introduction/Scope_ and _21._ (lexical), _18.6–18.8_ (property / value / binding table types). &#x20;

  - Include **minimum value types** and **Unicode** requirement mandated by conformance (e.g., string, boolean, signed integer, float; Unicode ≥ 13.0). State how these affect storage, collation, and protocol encoding.&#x20;

- **Binary layouts & “index‑free adjacency.”** Evaluate adjacency lists/CSR/k²‑trees and dynamic variants; justify choices for traversal locality vs. update cost. Provide Zig POCs for on‑disk structs/pages and variable‑length property storage. Use the prior plan’s structures as a starting point.&#x20;

**B. Binary Protocol Design (GQL request/response mapping)**

- Design a **custom binary protocol** (or adopt a zero‑copy payload format) whose **message taxonomy** corresponds to **GQL statements** and **execution outcomes**:

  - **Linear query statements & primitives** (e.g., `MATCH`, `LET`, `FOR`, `FILTER`, `ORDER BY ...`), **`USE GRAPH`**, **SELECT/YIELD**, and **procedure calls**; define message frames, correlation IDs, and payload schemas per clause families in _14.3–14.4_ and _9.2_. &#x20;
  - **Sessions**: `SESSION SET/RESET/CLOSE` handling, defaults, and parameter typing; include negotiation and backpressure semantics. Map to _7._ session clauses.&#x20;
  - **Diagnostics**: Encode error classes and statement codes compatible with **diagnostic records** to simplify client interoperability.&#x20;

- Provide Zig POCs for **header framing**, **endianness**, **(de)serialization**, **multiplexing/pipelining**, and **async I/O** (keep alive, flow control), adapting the prior POCs to message types named after GQL constructs.&#x20;

**C. File Storage & Persistence (ACID, WAL/ARIES)**

- Detail page formats (slotted pages), property stores (inline vs. heap/columnar), and **WAL** with **ARIES‑style** recovery; describe **STEAL/NO‑FORCE** policy and **page LSN** interaction. Provide Zig POCs for **WAL records**, **checksum**, and **fsync** strategy. Align all **catalog‑modifying** changes (DDL) with a transactional log discipline; reference _12._ for catalog‑modifying statements in the GQL layer. &#x20;

**D. Indexing for Property Graphs**

- Vertex, edge, label/type, and **vertex‑centric** indexes; evaluate trade‑offs for pattern predicates and starting‑node discovery; ensure WAL/transactional invariants for index updates. Provide a Zig POC for a **B+‑tree leaf** tuned for property values.&#x20;

**E. Distributed Systems**

- **Partitioning** (edge‑cut vs vertex‑cut vs hybrid) and **replication/fault‑tolerance**; **distributed transactions** (2PC layered over per‑shard consensus like Raft), and **distributed traversal/processing** (Pregel‑like BSP). Include Zig POCs for **shard mapping** and a **2PC coordinator state machine**. Use the plan for algorithms and adapt to GQL query routing. &#x20;

**F. Caching Strategies (CPU↔GPU)**

- Multi‑level caching (buffer pool, neighbor lists, property columns) optimized for **read‑heavy traversals**; discuss **graph‑aware eviction** and **coherence** across nodes; include potential **GPU memory caching**.

**G. GPU Acceleration**

- Identify GPU‑amenable operators: neighbor expansion, frontier compaction, filtered scans, ranked results, index lookups; present data structures facilitating coalesced access.

**H. Extensibility**

- **GQL procedures** and **UDFs**: show how the engine exposes safe extension points that respect GQL typing/binding tables and **procedure bodies** semantics.&#x20;
- Plan for **new native data types** and **catalog** evolution with minimal rewrite.

**I. Encryption & Key Management**

- Encryption‑at‑rest options (page vs. file vs. tablespace) and **key hierarchy** (HSM/KMS/TEE); quantify latency & throughput impact on WAL, compaction, and caching.

### 3) ISO‑GQL Conformance Profile (deliver a concrete table)

Produce a **Conformance Profile** per ISO §24:

- **Minimum conformance** plus the **feature set** the initial engine will support (e.g., GG01/GG02 open/closed graph types; selected **GQ** features such as `USE GRAPH` (GQ01), `EXISTS predicate` multiplicity, `FOR ... WITH OFFSET`, etc.; **GV** reference/value‑type features; **GS** session features). For each feature: **ID, name, rationale, engine implications (parser, planner, storage, protocol), and test hooks**. &#x20;
- Explicitly document **supported value types** and **Unicode version** to satisfy minimum conformance.&#x20;

### 4) GQL→Engine Crosswalk (must‑have artifact)

Create a **clause‑by‑clause mapping** from GQL constructs to:

- **Parser AST nodes** → **logical plan operators** → **physical plan operators** → **storage/index access paths** → **protocol messages** → **transaction/WAL actions** → **diagnostics**.
  Anchor to _14.3–14.4 (linear/match)_, _11._ (expressions, binding/graph refs), _18._ (types), _7._ (session), _9.2 (procedure body)_, _23.2 (diagnostics)_. Provide **worked examples** (e.g., `MATCH` with label/property filters) showing the **binding table** shape, intermediate state, and **page/LSN** effects. &#x20;

### 5) Zig POCs (per section; production‑quality snippets)

- **Types & Encoding:** property value (fixed/var‑len), label sets, binding‑table records; include **endianness** and **length‑prefix** helpers. Tie value domains to GQL property value types.&#x20;
- **Storage:** slotted pages, adjacency blocks, property heaps, index pages; **WAL write/commit** and LSN handling.&#x20;
- **Protocol:** message headers, `MATCH`/`SELECT` request & result frames, **session** control, **diagnostic** emissions, multiplexing. &#x20;
- **Distributed:** shard hashing, replica quorum, simple **2PC coordinator**; backoff/timeouts.&#x20;
- **Execution:** a minimal **`MATCH` path‑expand** kernel (CPU), with an optional **GPU** sketch for frontier expansion.

### 6) Evidence Rules

- **Tiering:** Prefer Tier‑A (peer‑reviewed/standards). ISO‑GQL is **primary** for language behavior. Cite ISO subclauses inline by number and page context. &#x20;
- **Recency window:** last **10–15 years** for academic systems work; justify older seminal citations.
- **Quantify**: include units/timeframes for performance claims; benchmark references must state dataset, scale (|V|, |E|), hardware, and metrics.

### 7) Deliverables

1. **Markdown report**, structured by the existing plan but GQL‑aligned (Ch.2–9), with **trade‑offs** and **best practices** per area.&#x20;
2. **GQL Conformance Profile** table (feature IDs, rationale, engine impact, tests).&#x20;
3. **GQL→Engine Crosswalk** with worked examples and plan diagrams.&#x20;
4. **Zig POCs**: compilable snippets for all critical components.
5. **Full bibliography** (APA/IEEE/Chicago ok) with DOI/URL + accessed dates; **flag preprints**.

### 8) Success Criteria

- Every language/engine decision **traces to ISO‑GQL** (by clause/feature) or to **peer‑reviewed** sources; no reliance on proprietary implementations unless studied academically.
- **POCs run** and demonstrate the key ideas (compilation/execution, storage/ACID, protocol, distributed coordination).
- **Clarity for implementers**: the Zig engineer can start building the binary protocol, storage, and concurrency control _immediately_.

### 9) Constraints & Safety

- Treat ISO text as **copyrighted**: **paraphrase**; short quotes ≤25 words if essential; always cite subclause.
- No medical/legal advice. Distinguish **fact vs. interpretation**; label speculation.

---

### Notes on ISO‑GQL Anchors (for the DRA)

- **Data model & scope**: GQL addresses **property graphs**; declarative + transactional; shares pattern syntax with SQL/PGQ while remaining independent. Use this to justify pattern‑matching–centric planning.&#x20;
- **Linear query statements & primitives**: `MATCH`, `LET`, `FOR`, `FILTER`, `ORDER BY AND PAGE`, `SELECT`, `CALL` — base your protocol verbs and execution stages on this decomposition.&#x20;
- **Expressions & binding**: Map **graph expressions**, **binding table expressions**, and **object expression primaries** to your AST and row model. &#x20;
- **Types**: **Property types** and **property value types** define legal on‑disk/in‑wire encodings; **binding table types** govern result shapes.&#x20;
- **Sessions/Procedures/Diagnostics**: Implement session lifecycle; support procedures with statement blocks; standardize diagnostics mapping for clients. &#x20;
- **Conformance**: Deliver a **minimum conformance** claim and enumerate supported **optional features** (with IDs) in your profile; include **Unicode** and **value‑type** sets.&#x20;
