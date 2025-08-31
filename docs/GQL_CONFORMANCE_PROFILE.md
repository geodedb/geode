# GQL Conformance Profile (ISO/IEC 39075:2024)

## A. Product

- Implementation: <name/version>
- Scope: GQL front‑end + planner/executor for distributed ACID graph DB.

## B. Minimum conformance

- This implementation **correctly translates/executes** all GQL programs conforming to the language and to the implementation‑defined features claimed here; it **rejects** programs whose errors require detection by the standard. :contentReference[oaicite:69]{index=69}

## C. Optional features claimed (Annex D)

- **GQ03 UNION**, **GQ04/5 EXCEPT**, **GQ06/7 INTERSECT** (Phase 0/1 as implemented). :contentReference[oaicite:70]{index=70}
- **G060 bounded quantifiers** (if enabled). :contentReference[oaicite:71]{index=71}
- (Add others explicitly as you adopt them.)

## D. Implementation‑defined / dependent behaviors (partial)

- **US001**: Order chosen for OFFSET/LIMIT on unordered tables: `<doc policy>`. :contentReference[oaicite:72]{index=72}
- **UA005/UA006**: Path tie‑break `(length, src_id, dst_id, edge_id)` (document exact rule). (Anchors summarized in planner doc.) :contentReference[oaicite:73]{index=73}
- **UA002**: Multiple diagnostic conditions policy: `<doc policy>`. :contentReference[oaicite:74]{index=74}

## E. Extensions / Options

- Extra reserved words or processing modes (if any) and Flagger behavior. :contentReference[oaicite:75]{index=75}

## F. Flagger

- Provided; flags extensions/options/impl‑defined features and non‑conforming modes. :contentReference[oaicite:76]{index=76}
