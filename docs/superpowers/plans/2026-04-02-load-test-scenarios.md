# Load Test Scenarios Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Go load test binary to support progressive benchmark scenarios — from simple pings through point reads, single-hop, two-hop, and cross-type fan-out graph traversals — with increasing data sizes at each tier.

**Architecture:** Add a `-scenario` flag to the existing `geode-loadtest` binary. Each scenario defines data setup (graph creation via GQL), a benchmark query template (with random node selection), and teardown (data cleanup). Scenarios run the existing concurrency ramp against their dataset. Output extends the current JSON format with `scenario` and `data_size` fields. Baseline/comparison infrastructure is extended with scenario-qualified benchmark entries.

**Tech Stack:** Go 1.25+, Geode Go client (`database/sql` driver over QUIC), GQL queries, Python 3 (comparison scripts)

---

## Scenarios Overview

| Scenario | Nodes | Edges | Query | Purpose |
|----------|-------|-------|-------|---------|
| `ping` | 0 | 0 | `RETURN 1 AS x` | Baseline transport overhead (backward compat) |
| `point_read` | 500 | 0 | `MATCH (p:LT_Person {lt_id: N}) RETURN p.name, p.age` | Property lookup, index scan |
| `one_hop` | 1,000 | 3,000 | `MATCH (a:LT_Person {lt_id: N})-[:LT_KNOWS]->(b) RETURN b.name, b.age` | Single-hop traversal |
| `two_hop` | 2,000 | 8,000 | `MATCH (a:LT_Person {lt_id: N})-[:LT_KNOWS]->(b)-[:LT_KNOWS]->(c) RETURN DISTINCT c.name LIMIT 20` | Multi-hop traversal with dedup |
| `fan_out` | 2,200 | 8,000 | `MATCH (a:LT_Person {lt_id: N})-[:LT_KNOWS]->(b)-[:LT_WORKS_AT]->(c:LT_Company) RETURN b.name, c.name LIMIT 20` | Cross-type multi-hop traversal |

All labels prefixed `LT_` to avoid collision with user data. Teardown runs before setup to handle leftover data from crashed runs.

## File Structure

### New Files

- `../geode-test-harness/loadtest/go/scenario.go` — Scenario type, registry, and all 5 scenario definitions (~250 lines)
- `../geode-test-harness/loadtest/go/setup.go` — Data generation helpers: batch node/edge creation, generic row drain (~120 lines)

### Modified Files

- `../geode-test-harness/loadtest/go/main.go` — Add `-scenario` flag, integrate setup/teardown lifecycle, pass query function to workers
- `../geode-test-harness/Makefile` — Add `loadtest-scenarios` and per-scenario targets
- `benchmarks/loadtest/compare.py` — Handle `scenario` field in current results
- `benchmarks/loadtest/save_baseline.py` — Include `scenario` field in baseline records
- `benchmarks/loadtest/baseline.jsonl` — Extended with scenario-qualified entries after first run

---

### Task 1: Create scenario type definition and registry

**Files:**

- Create: `../geode-test-harness/loadtest/go/scenario.go`

- [ ] **Step 1: Create scenario.go with type definitions and registry**

```go
package main

import (
 "database/sql"
 "math/rand/v2"
)

// QueryFunc is the function each worker calls in its benchmark loop.
// rng is a per-worker random source for generating query parameters.
type QueryFunc func(db *sql.DB, rng *rand.Rand) error

// DataSize describes the dataset a scenario creates.
type DataSize struct {
 Nodes int `json:"nodes"`
 Edges int `json:"edges"`
}

// Scenario defines a benchmark profile with its own data and query.
type Scenario struct {
 Name        string
 Description string
 Data        DataSize
 Setup       func(db *sql.DB) error
 Teardown    func(db *sql.DB) error
 QueryFn     func(maxNodeID int) QueryFunc
}

// scenarios is the ordered registry of all available scenarios.
var scenarios = []Scenario{
 scenarioPing(),
 scenarioPointRead(),
 scenarioOneHop(),
 scenarioTwoHop(),
 scenarioFanOut(),
}

// scenarioNames returns a comma-separated list for help text.
func scenarioNames() string {
 names := ""
 for i, s := range scenarios {
  if i > 0 {
   names += ", "
  }
  names += s.Name
 }
 return names + ", all"
}

// findScenario returns the scenario with the given name, or nil.
func findScenario(name string) *Scenario {
 for i := range scenarios {
  if scenarios[i].Name == name {
   return &scenarios[i]
  }
 }
 return nil
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd ../geode-test-harness/loadtest/go && go build ./...
```

Expected: compile errors for undefined scenario functions — that's expected at this stage.

- [ ] **Step 3: Commit**

```bash
cd ../geode-test-harness/loadtest/go
git add scenario.go
git commit -m "feat(loadtest): add scenario type definition and registry"
```

---

### Task 2: Create data generation helpers

**Files:**

- Create: `../geode-test-harness/loadtest/go/setup.go`

- [ ] **Step 1: Create setup.go with batch creation and drain helpers**

```go
package main

import (
 "context"
 "database/sql"
 "fmt"
 "os"
 "time"
)

// batchCreateNodes creates count nodes with label and sequential lt_id.
// Each node gets {lt_id: i, name: "Person_i", age: 20+(i%50)}.
func batchCreateNodes(db *sql.DB, label string, count int) error {
 for i := 0; i < count; i++ {
  ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
  _, err := db.ExecContext(ctx, fmt.Sprintf(
   "CREATE (:%s {lt_id: %d, name: '%s_%d', age: %d})",
   label, i, label, i, 20+(i%50)))
  cancel()
  if err != nil {
   return fmt.Errorf("create node %s %d: %w", label, i, err)
  }
  if (i+1)%200 == 0 {
   fmt.Fprintf(os.Stderr, "    setup: created %d/%d %s nodes\n", i+1, count, label)
  }
 }
 if count > 0 && count%200 != 0 {
  fmt.Fprintf(os.Stderr, "    setup: created %d/%d %s nodes\n", count, count, label)
 }
 return nil
}

// batchCreateEdges creates edges between nodes of the given labels.
// For each source node i (0..sourceCount-1), creates edgesPerNode edges
// to deterministic targets: (i + 1 + j*prime) % targetCount.
func batchCreateEdges(db *sql.DB, srcLabel, relType, dstLabel string,
 sourceCount, targetCount, edgesPerNode int) error {

 prime := 7
 total := sourceCount * edgesPerNode
 created := 0

 for i := 0; i < sourceCount; i++ {
  for j := 0; j < edgesPerNode; j++ {
   target := (i + 1 + j*prime) % targetCount
   if target == i && srcLabel == dstLabel {
    target = (target + 1) % targetCount
   }

   ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
   _, err := db.ExecContext(ctx, fmt.Sprintf(
    "MATCH (a:%s {lt_id: %d}), (b:%s {lt_id: %d}) CREATE (a)-[:%s]->(b)",
    srcLabel, i, dstLabel, target, relType))
   cancel()
   if err != nil {
    return fmt.Errorf("create edge %s -[%s]-> %s (%d->%d): %w",
     srcLabel, relType, dstLabel, i, target, err)
   }
   created++
   if created%500 == 0 {
    fmt.Fprintf(os.Stderr, "    setup: created %d/%d %s edges\n", created, total, relType)
   }
  }
 }
 if total > 0 && total%500 != 0 {
  fmt.Fprintf(os.Stderr, "    setup: created %d/%d %s edges\n", total, total, relType)
 }
 return nil
}

// deleteByLabel deletes all nodes with the given label.
func deleteByLabel(db *sql.DB, label string) error {
 ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
 defer cancel()
 _, err := db.ExecContext(ctx, fmt.Sprintf("MATCH (n:%s) DELETE n", label))
 return err
}

// deleteEdgesByType deletes all relationships of the given type.
func deleteEdgesByType(db *sql.DB, relType string) error {
 ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
 defer cancel()
 _, err := db.ExecContext(ctx, fmt.Sprintf("MATCH ()-[r:%s]->() DELETE r", relType))
 return err
}

// drainRows consumes all rows from a result set, discarding values.
func drainRows(rows *sql.Rows) error {
 cols, err := rows.Columns()
 if err != nil {
  return err
 }
 vals := make([]interface{}, len(cols))
 ptrs := make([]interface{}, len(cols))
 for i := range vals {
  ptrs[i] = &vals[i]
 }
 for rows.Next() {
  if err := rows.Scan(ptrs...); err != nil {
   return err
  }
 }
 return rows.Err()
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd ../geode-test-harness/loadtest/go && go build ./...
```

Expected: still fails (scenario functions undefined), but setup.go itself should have no errors.

- [ ] **Step 3: Commit**

```bash
cd ../geode-test-harness/loadtest/go
git add setup.go
git commit -m "feat(loadtest): add data generation helpers for scenario setup"
```

---

### Task 3: Implement all 5 scenario definitions

**Files:**

- Modify: `../geode-test-harness/loadtest/go/scenario.go` (append scenario functions)

- [ ] **Step 1: Add ping scenario (backward compat with existing `read` mode)**

Append to `scenario.go`:

```go
func scenarioPing() Scenario {
 return Scenario{
  Name:        "ping",
  Description: "Baseline transport: RETURN 1 AS x (no data)",
  Data:        DataSize{Nodes: 0, Edges: 0},
  Setup:       func(db *sql.DB) error { return nil },
  Teardown:    func(db *sql.DB) error { return nil },
  QueryFn: func(maxNodeID int) QueryFunc {
   return func(db *sql.DB, rng *rand.Rand) error {
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    rows, err := db.QueryContext(ctx, "RETURN 1 AS x")
    if err != nil {
     return err
    }
    defer rows.Close()
    for rows.Next() {
     var x int
     if err := rows.Scan(&x); err != nil {
      return err
     }
    }
    return rows.Err()
   }
  },
 }
}
```

- [ ] **Step 2: Add point_read scenario**

Append to `scenario.go`:

```go
func scenarioPointRead() Scenario {
 const numNodes = 500

 return Scenario{
  Name:        "point_read",
  Description: "Property lookup: MATCH by lt_id (500 nodes)",
  Data:        DataSize{Nodes: numNodes, Edges: 0},
  Setup: func(db *sql.DB) error {
   return batchCreateNodes(db, "LT_Person", numNodes)
  },
  Teardown: func(db *sql.DB) error {
   return deleteByLabel(db, "LT_Person")
  },
  QueryFn: func(maxNodeID int) QueryFunc {
   return func(db *sql.DB, rng *rand.Rand) error {
    id := rng.IntN(numNodes)
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    rows, err := db.QueryContext(ctx, fmt.Sprintf(
     "MATCH (p:LT_Person {lt_id: %d}) RETURN p.name, p.age", id))
    if err != nil {
     return err
    }
    defer rows.Close()
    return drainRows(rows)
   }
  },
 }
}
```

- [ ] **Step 3: Add one_hop scenario**

Append to `scenario.go`:

```go
func scenarioOneHop() Scenario {
 const numNodes = 1000
 const edgesPerNode = 3
 const totalEdges = numNodes * edgesPerNode

 return Scenario{
  Name:        "one_hop",
  Description: "Single-hop traversal: person -[:LT_KNOWS]-> person (1K nodes, 3K edges)",
  Data:        DataSize{Nodes: numNodes, Edges: totalEdges},
  Setup: func(db *sql.DB) error {
   if err := batchCreateNodes(db, "LT_Person", numNodes); err != nil {
    return err
   }
   return batchCreateEdges(db, "LT_Person", "LT_KNOWS", "LT_Person",
    numNodes, numNodes, edgesPerNode)
  },
  Teardown: func(db *sql.DB) error {
   _ = deleteEdgesByType(db, "LT_KNOWS")
   return deleteByLabel(db, "LT_Person")
  },
  QueryFn: func(maxNodeID int) QueryFunc {
   return func(db *sql.DB, rng *rand.Rand) error {
    id := rng.IntN(numNodes)
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    rows, err := db.QueryContext(ctx, fmt.Sprintf(
     "MATCH (a:LT_Person {lt_id: %d})-[:LT_KNOWS]->(b) RETURN b.name, b.age", id))
    if err != nil {
     return err
    }
    defer rows.Close()
    return drainRows(rows)
   }
  },
 }
}
```

- [ ] **Step 4: Add two_hop scenario**

Append to `scenario.go`:

```go
func scenarioTwoHop() Scenario {
 const numNodes = 2000
 const edgesPerNode = 4
 const totalEdges = numNodes * edgesPerNode

 return Scenario{
  Name:        "two_hop",
  Description: "Two-hop traversal with DISTINCT: person->person->person (2K nodes, 8K edges)",
  Data:        DataSize{Nodes: numNodes, Edges: totalEdges},
  Setup: func(db *sql.DB) error {
   if err := batchCreateNodes(db, "LT_Person", numNodes); err != nil {
    return err
   }
   return batchCreateEdges(db, "LT_Person", "LT_KNOWS", "LT_Person",
    numNodes, numNodes, edgesPerNode)
  },
  Teardown: func(db *sql.DB) error {
   _ = deleteEdgesByType(db, "LT_KNOWS")
   return deleteByLabel(db, "LT_Person")
  },
  QueryFn: func(maxNodeID int) QueryFunc {
   return func(db *sql.DB, rng *rand.Rand) error {
    id := rng.IntN(numNodes)
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    rows, err := db.QueryContext(ctx, fmt.Sprintf(
     "MATCH (a:LT_Person {lt_id: %d})-[:LT_KNOWS]->(b)-[:LT_KNOWS]->(c) RETURN DISTINCT c.name LIMIT 20", id))
    if err != nil {
     return err
    }
    defer rows.Close()
    return drainRows(rows)
   }
  },
 }
}
```

- [ ] **Step 5: Add fan_out scenario**

Append to `scenario.go`:

```go
func scenarioFanOut() Scenario {
 const numPersons = 2000
 const numCompanies = 200
 const knowsPerPerson = 3
 const totalKnows = numPersons * knowsPerPerson
 const totalWorksAt = numPersons // each person works at 1 company

 return Scenario{
  Name:        "fan_out",
  Description: "Cross-type 2-hop: person->person->company (2.2K nodes, 8K edges)",
  Data:        DataSize{Nodes: numPersons + numCompanies, Edges: totalKnows + totalWorksAt},
  Setup: func(db *sql.DB) error {
   fmt.Fprintf(os.Stderr, "  Setting up fan_out scenario...\n")
   if err := batchCreateNodes(db, "LT_Person", numPersons); err != nil {
    return err
   }
   if err := batchCreateCompanies(db, numCompanies); err != nil {
    return err
   }
   if err := batchCreateEdges(db, "LT_Person", "LT_KNOWS", "LT_Person",
    numPersons, numPersons, knowsPerPerson); err != nil {
    return err
   }
   return batchCreateWorksAt(db, numPersons, numCompanies)
  },
  Teardown: func(db *sql.DB) error {
   _ = deleteEdgesByType(db, "LT_WORKS_AT")
   _ = deleteEdgesByType(db, "LT_KNOWS")
   _ = deleteByLabel(db, "LT_Company")
   return deleteByLabel(db, "LT_Person")
  },
  QueryFn: func(maxNodeID int) QueryFunc {
   return func(db *sql.DB, rng *rand.Rand) error {
    id := rng.IntN(numPersons)
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    rows, err := db.QueryContext(ctx, fmt.Sprintf(
     "MATCH (a:LT_Person {lt_id: %d})-[:LT_KNOWS]->(b)-[:LT_WORKS_AT]->(c:LT_Company) RETURN b.name, c.name LIMIT 20", id))
    if err != nil {
     return err
    }
    defer rows.Close()
    return drainRows(rows)
   }
  },
 }
}
```

- [ ] **Step 6: Add fan_out-specific data helpers to setup.go**

Append to `setup.go`:

```go
// batchCreateCompanies creates LT_Company nodes with lt_id, name, and founded.
func batchCreateCompanies(db *sql.DB, count int) error {
 for i := 0; i < count; i++ {
  ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
  _, err := db.ExecContext(ctx, fmt.Sprintf(
   "CREATE (:LT_Company {lt_id: %d, name: 'Company_%d', founded: %d})",
   i, i, 1990+(i%35)))
  cancel()
  if err != nil {
   return fmt.Errorf("create company %d: %w", i, err)
  }
  if (i+1)%100 == 0 {
   fmt.Fprintf(os.Stderr, "    setup: created %d/%d LT_Company nodes\n", i+1, count)
  }
 }
 if count > 0 && count%100 != 0 {
  fmt.Fprintf(os.Stderr, "    setup: created %d/%d LT_Company nodes\n", count, count)
 }
 return nil
}

// batchCreateWorksAt creates LT_WORKS_AT edges from each LT_Person to a LT_Company.
// Person i works at company (i % numCompanies).
func batchCreateWorksAt(db *sql.DB, numPersons, numCompanies int) error {
 for i := 0; i < numPersons; i++ {
  companyID := i % numCompanies
  ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
  _, err := db.ExecContext(ctx, fmt.Sprintf(
   "MATCH (p:LT_Person {lt_id: %d}), (c:LT_Company {lt_id: %d}) CREATE (p)-[:LT_WORKS_AT]->(c)",
   i, companyID))
  cancel()
  if err != nil {
   return fmt.Errorf("create works_at %d->%d: %w", i, companyID, err)
  }
  if (i+1)%500 == 0 {
   fmt.Fprintf(os.Stderr, "    setup: created %d/%d LT_WORKS_AT edges\n", i+1, numPersons)
  }
 }
 if numPersons > 0 && numPersons%500 != 0 {
  fmt.Fprintf(os.Stderr, "    setup: created %d/%d LT_WORKS_AT edges\n", numPersons, numPersons)
 }
 return nil
}
```

- [ ] **Step 7: Verify all scenario files compile together**

```bash
cd ../geode-test-harness/loadtest/go && go build ./...
```

Expected: may still fail until main.go is updated. Verify no syntax errors in scenario.go and setup.go by checking the error output — only main.go reference issues should remain.

- [ ] **Step 8: Commit**

```bash
cd ../geode-test-harness/loadtest/go
git add scenario.go setup.go
git commit -m "feat(loadtest): implement 5 benchmark scenarios (ping, point_read, one_hop, two_hop, fan_out)"
```

---

### Task 4: Refactor main.go to support scenarios

**Files:**

- Modify: `../geode-test-harness/loadtest/go/main.go`

The key changes:

1. Add `-scenario` flag (default: `ping`)
2. Add `scenario` and `data_size` fields to `Report` struct
3. Wrap concurrency ramp with scenario setup/teardown
4. Pass `QueryFunc` to `runLevel` instead of `queryType` string
5. Remove old `execRead`/`execWrite` (replaced by scenarios)
6. Use per-worker `rand.Rand` for random query parameters

- [ ] **Step 1: Update imports and struct definitions**

Replace the import block and struct definitions in `main.go`:

```go
package main

import (
 "context"
 "database/sql"
 "encoding/json"
 "flag"
 "fmt"
 "math"
 "math/rand/v2"
 "os"
 "sort"
 "strconv"
 "strings"
 "sync"
 "sync/atomic"
 "time"

 _ "geodedb.com/geode"
)

type LevelResult struct {
 Concurrency  int      `json:"concurrency"`
 TotalQueries int64    `json:"total_queries"`
 Errors       int64    `json:"errors"`
 ErrorRate    float64  `json:"error_rate"`
 Duration     string   `json:"duration"`
 QPS          float64  `json:"qps"`
 LatencyP50   string   `json:"latency_p50"`
 LatencyP95   string   `json:"latency_p95"`
 LatencyP99   string   `json:"latency_p99"`
 LatencyMean  string   `json:"latency_mean"`
 LatencyMax   string   `json:"latency_max"`
 ErrorSamples []string `json:"error_samples,omitempty"`
}

type Report struct {
 Timestamp string        `json:"timestamp"`
 DSN       string        `json:"dsn"`
 Scenario  string        `json:"scenario"`
 QueryType string        `json:"query_type"`
 DataSize  DataSize      `json:"data_size"`
 Levels    []LevelResult `json:"levels"`
 Summary   string        `json:"summary"`
}
```

- [ ] **Step 2: Rewrite main() with scenario support**

```go
func main() {
 dsn := flag.String("dsn", "localhost:3141?insecure=true", "Geode DSN")
 levelsStr := flag.String("levels", "1,2,4,8,16,32,64", "Comma-separated concurrency levels")
 duration := flag.Duration("duration", 5*time.Second, "Duration per concurrency level")
 output := flag.String("output", "", "JSON output file (stdout if empty)")
 scenarioName := flag.String("scenario", "ping", "Scenario: "+scenarioNames())
 flag.Parse()

 levels := parseLevels(*levelsStr)

 // Resolve scenario
 sc := findScenario(*scenarioName)
 if sc == nil {
  fmt.Fprintf(os.Stderr, "ERROR: unknown scenario %q. Available: %s\n", *scenarioName, scenarioNames())
  os.Exit(1)
 }

 fmt.Fprintf(os.Stderr, "Geode Load Test\n")
 fmt.Fprintf(os.Stderr, "  DSN:      %s\n", *dsn)
 fmt.Fprintf(os.Stderr, "  Scenario: %s (%s)\n", sc.Name, sc.Description)
 fmt.Fprintf(os.Stderr, "  Data:     %d nodes, %d edges\n", sc.Data.Nodes, sc.Data.Edges)
 fmt.Fprintf(os.Stderr, "  Levels:   %v\n", levels)
 fmt.Fprintf(os.Stderr, "  Duration: %s per level\n\n", *duration)

 // Setup data
 if sc.Data.Nodes > 0 || sc.Data.Edges > 0 {
  fmt.Fprintf(os.Stderr, "  Setting up data...\n")
  setupDB, err := sql.Open("geode", *dsn)
  if err != nil {
   fmt.Fprintf(os.Stderr, "ERROR: setup connection: %v\n", err)
   os.Exit(1)
  }
  setupDB.SetMaxOpenConns(1)
  setupDB.SetMaxIdleConns(1)

  // Teardown first to clean leftover data from crashed runs
  _ = sc.Teardown(setupDB)
  if err := sc.Setup(setupDB); err != nil {
   fmt.Fprintf(os.Stderr, "ERROR: setup failed: %v\n", err)
   setupDB.Close()
   os.Exit(1)
  }
  setupDB.Close()
  fmt.Fprintf(os.Stderr, "  Setup complete.\n\n")
 }

 // Build query function
 queryFn := sc.QueryFn(sc.Data.Nodes)

 report := Report{
  Timestamp: time.Now().UTC().Format(time.RFC3339),
  DSN:       sanitizeDSN(*dsn),
  Scenario:  sc.Name,
  QueryType: sc.Description,
  DataSize:  sc.Data,
 }

 for _, concurrency := range levels {
  result := runLevel(*dsn, concurrency, *duration, queryFn)
  report.Levels = append(report.Levels, result)

  fmt.Fprintf(os.Stderr, "  c=%-3d  qps=%-8.1f  p50=%-14s  p99=%-14s  errors=%d/%d\n",
   result.Concurrency, result.QPS, result.LatencyP50, result.LatencyP99,
   result.Errors, result.TotalQueries)

  if result.ErrorRate > 0.5 {
   fmt.Fprintf(os.Stderr, "  ⚠ >50%% error rate at c=%d, stopping ramp\n", concurrency)
   break
  }
 }

 // Teardown data
 if sc.Data.Nodes > 0 || sc.Data.Edges > 0 {
  fmt.Fprintf(os.Stderr, "\n  Tearing down data...\n")
  teardownDB, err := sql.Open("geode", *dsn)
  if err == nil {
   teardownDB.SetMaxOpenConns(1)
   teardownDB.SetMaxIdleConns(1)
   _ = sc.Teardown(teardownDB)
   teardownDB.Close()
  }
  fmt.Fprintf(os.Stderr, "  Teardown complete.\n")
 }

 // Summary
 if len(report.Levels) > 0 {
  last := report.Levels[len(report.Levels)-1]
  best := report.Levels[0]
  for _, l := range report.Levels {
   if l.QPS > best.QPS && l.ErrorRate < 0.1 {
    best = l
   }
  }
  report.Summary = fmt.Sprintf("Peak QPS: %.1f at c=%d. Max tested: c=%d (%.1f QPS, %.1f%% errors)",
   best.QPS, best.Concurrency, last.Concurrency, last.QPS, last.ErrorRate*100)
 }

 data, _ := json.MarshalIndent(report, "", "  ")
 fmt.Fprintf(os.Stderr, "\n%s\n", report.Summary)

 if *output != "" {
  os.WriteFile(*output, data, 0644)
  fmt.Fprintf(os.Stderr, "Report: %s\n", *output)
 } else {
  fmt.Println(string(data))
 }
}
```

- [ ] **Step 3: Rewrite runLevel to use QueryFunc with per-worker RNG**

Replace the `runLevel` function:

```go
func runLevel(dsn string, concurrency int, duration time.Duration, queryFn QueryFunc) LevelResult {
 db, err := sql.Open("geode", dsn)
 if err != nil {
  return LevelResult{Concurrency: concurrency, ErrorSamples: []string{err.Error()}}
 }
 defer db.Close()

 db.SetMaxOpenConns(concurrency)
 db.SetMaxIdleConns(concurrency)
 db.SetConnMaxLifetime(time.Minute)

 // Warm up: establish connections
 ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
 defer cancel()
 if err := db.PingContext(ctx); err != nil {
  return LevelResult{Concurrency: concurrency, ErrorSamples: []string{"ping: " + err.Error()}}
 }

 var (
  totalQueries atomic.Int64
  totalErrors  atomic.Int64
  latencies    = make([][]time.Duration, concurrency)
  errSamples   []string
  errMu        sync.Mutex
  wg           sync.WaitGroup
 )

 for i := range concurrency {
  latencies[i] = make([]time.Duration, 0, 1000)
 }

 deadline := time.Now().Add(duration)
 wg.Add(concurrency)

 for i := range concurrency {
  go func(workerID int) {
   defer wg.Done()
   rng := rand.New(rand.NewPCG(uint64(workerID)*12345+1, uint64(workerID)*67890+1))
   for time.Now().Before(deadline) {
    start := time.Now()
    qerr := queryFn(db, rng)
    elapsed := time.Since(start)
    totalQueries.Add(1)

    if qerr != nil {
     totalErrors.Add(1)
     errMu.Lock()
     if len(errSamples) < 5 {
      errSamples = append(errSamples, qerr.Error())
     }
     errMu.Unlock()
    } else {
     latencies[workerID] = append(latencies[workerID], elapsed)
    }
   }
  }(i)
 }

 wg.Wait()

 // Merge and compute latencies
 var all []time.Duration
 for _, l := range latencies {
  all = append(all, l...)
 }

 total := totalQueries.Load()
 errors := totalErrors.Load()
 errorRate := float64(0)
 if total > 0 {
  errorRate = float64(errors) / float64(total)
 }

 result := LevelResult{
  Concurrency:  concurrency,
  TotalQueries: total,
  Errors:       errors,
  ErrorRate:    errorRate,
  Duration:     duration.String(),
  ErrorSamples: errSamples,
 }

 if len(all) > 0 {
  sort.Slice(all, func(i, j int) bool { return all[i] < all[j] })
  result.QPS = float64(len(all)) / duration.Seconds()
  result.LatencyP50 = percentile(all, 0.50).String()
  result.LatencyP95 = percentile(all, 0.95).String()
  result.LatencyP99 = percentile(all, 0.99).String()
  result.LatencyMax = all[len(all)-1].String()

  var sum time.Duration
  for _, d := range all {
   sum += d
  }
  result.LatencyMean = (sum / time.Duration(len(all))).String()
 }

 return result
}
```

- [ ] **Step 4: Remove old execRead, execWrite — keep utility functions**

Delete `execRead`, `execWrite` functions. Keep `percentile`, `parseLevels`, `sanitizeDSN` unchanged.

The final `main.go` should contain:

- Imports, structs (LevelResult, Report)
- `main()` — flag parsing, scenario lifecycle, reporting
- `runLevel()` — concurrency ramp with QueryFunc
- `percentile()`, `parseLevels()`, `sanitizeDSN()` — unchanged helpers

- [ ] **Step 5: Build and verify compilation**

```bash
cd ../geode-test-harness/loadtest/go && go build -o geode-loadtest .
```

Expected: clean build, binary produced.

- [ ] **Step 6: Smoke test — run ping scenario (backward compat)**

```bash
cd ../geode-test-harness/loadtest/go && ./geode-loadtest \
  -dsn "localhost:3141?insecure=true&user=geode&pass=<password>" \
  -scenario ping -levels "1" -duration 2s
```

Expected: output matches existing format with additional `scenario` and `data_size` fields. QPS in the 400-500 range.

- [ ] **Step 7: Commit**

```bash
cd ../geode-test-harness/loadtest/go
git add main.go
git commit -m "refactor(loadtest): add -scenario flag, integrate setup/teardown lifecycle"
```

---

### Task 5: Update Makefile with scenario targets

**Files:**

- Modify: `../geode-test-harness/Makefile`

- [ ] **Step 1: Add per-scenario and all-scenarios targets**

Add after the existing `loadtest-go` target:

```makefile
# Run a specific load test scenario
# Usage: make loadtest-scenario SCENARIO=one_hop
SCENARIO ?= ping
loadtest-scenario: loadtest-build
 mkdir -p reports
 cd loadtest/go && ./geode-loadtest \
  -dsn "$(LOADTEST_DSN)" \
  -scenario "$(SCENARIO)" \
  -levels "$(LOADTEST_LEVELS)" \
  -duration $(LOADTEST_DURATION) \
  -output ../../reports/loadtest_$(SCENARIO).json

# Run all load test scenarios sequentially
loadtest-scenarios: loadtest-build
 mkdir -p reports
 @for scenario in ping point_read one_hop two_hop fan_out; do \
  echo ""; \
  echo "=== Running scenario: $$scenario ==="; \
  cd loadtest/go && ./geode-loadtest \
   -dsn "$(LOADTEST_DSN)" \
   -scenario "$$scenario" \
   -levels "$(LOADTEST_LEVELS)" \
   -duration $(LOADTEST_DURATION) \
   -output ../../reports/loadtest_$${scenario}.json; \
  cd ../..; \
 done
 @echo ""
 @echo "=== All scenarios complete ==="
 @echo "Reports: reports/loadtest_*.json"
```

- [ ] **Step 2: Update the help target to show new targets**

Add to the help output:

```makefile
 @echo "  make loadtest-scenario  SCENARIO=<name> - Run a specific load test scenario"
 @echo "  make loadtest-scenarios - Run all load test scenarios (ping, point_read, one_hop, two_hop, fan_out)"
```

- [ ] **Step 3: Verify**

```bash
cd ../geode-test-harness && make help | grep loadtest
```

Expected: shows both new targets.

- [ ] **Step 4: Commit**

```bash
cd ../geode-test-harness
git add Makefile
git commit -m "feat(loadtest): add Makefile targets for scenario-based load tests"
```

---

### Task 6: Update comparison infrastructure for scenarios

**Files:**

- Modify: `benchmarks/loadtest/compare.py`
- Modify: `benchmarks/loadtest/save_baseline.py`
- Modify: `benchmarks/loadtest/baseline.jsonl`

- [ ] **Step 1: Update save_baseline.py to include scenario field**

In `save_baseline.py`, modify the record construction (around line 87) to include the scenario:

```python
        # Extract scenario from input data (default to "ping" for backward compat)
        scenario = data.get("scenario", "ping")
```

And in the record dict (around line 87-101), add the scenario field:

```python
        rec = {
            "schema_version": 2,
            "kind": "LoadTest",
            "benchmark": f"{scenario}_c{c}",
            "scenario": scenario,
            "concurrency": c,
            # ... rest unchanged
        }
```

- [ ] **Step 2: Update compare.py to filter by scenario**

In `compare.py`, modify `load_baseline()` to key by `(scenario, concurrency)`:

```python
def load_baseline(path: str) -> dict[tuple[str, int], dict]:
    """Load baseline JSONL, returning a dict keyed by (scenario, concurrency)."""
    baseline = {}
    with open(path) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if rec.get("kind") != "LoadTest":
                continue
            if rec.get("schema_version") != 2:
                print(
                    f"WARNING: skipping baseline line {lineno}: "
                    f"schema_version={rec.get('schema_version')} (expected 2)",
                    file=sys.stderr,
                )
                continue
            scenario = rec.get("scenario", "ping")
            baseline[(scenario, rec["concurrency"])] = rec
    return baseline
```

Modify `load_current()` to include scenario:

```python
def load_current(path: str) -> tuple[str, dict[int, dict]]:
    """Load current Go load test JSON. Returns (scenario, {concurrency: data})."""
    with open(path) as f:
        data = json.load(f)

    scenario = data.get("scenario", "ping")
    current = {}
    for level in data.get("levels", []):
        c = level["concurrency"]
        dur_s = parse_go_duration_seconds(level["duration"])
        current[c] = {
            "concurrency": c,
            "qps": level["qps"],
            "latency_p50_ms": parse_go_duration(level["latency_p50"]),
            "latency_p99_ms": parse_go_duration(level["latency_p99"]),
            "errors": level["errors"],
            "error_rate": level.get("error_rate", 0),
            "total_queries": level["total_queries"],
            "duration_s": dur_s,
        }
    return scenario, current
```

Update `compare()` to accept scenario parameter:

```python
def compare(
    baseline: dict[tuple[str, int], dict],
    scenario: str,
    current: dict[int, dict],
    threshold_pct: float,
) -> tuple[list[dict], bool]:
    """Compare current results for a scenario against baseline."""
    results = []
    all_pass = True

    # Get baseline concurrencies for this scenario
    base_concurrencies = {c for (s, c) in baseline if s == scenario}
    curr_concurrencies = set(current.keys())
    concurrencies = sorted(base_concurrencies | curr_concurrencies)

    for c in concurrencies:
        base = baseline.get((scenario, c))
        curr = current.get(c)
        # ... rest of comparison logic unchanged, but use (scenario, c) key
        # and include "scenario" in output records
```

Update `main()` to handle the new signature:

```python
    scenario, current = load_current(args.current)
    results, all_pass = compare(baseline, scenario, current, args.threshold)
```

Add a `--scenario` flag to allow filtering:

```python
    parser.add_argument(
        "--scenario",
        default=None,
        help="Override scenario name (auto-detected from current results)",
    )
```

- [ ] **Step 3: Add backward-compatible scenario field to existing baseline.jsonl**

Update `benchmarks/loadtest/baseline.jsonl` — add `"scenario":"ping"` to each existing line. The benchmark field changes from `qps_c1` to `ping_c1`:

```jsonl
{"schema_version":2,"kind":"LoadTest","benchmark":"ping_c1","scenario":"ping","concurrency":1,"qps":564,"latency_p50_ms":1.7,"latency_p99_ms":2.3,"errors":0,"total_queries":2820,"duration_s":5.0,"pass":true,"threshold_qps_min":451.2,"threshold_p50_max_ms":2.1}
{"schema_version":2,"kind":"LoadTest","benchmark":"ping_c2","scenario":"ping","concurrency":2,"qps":854.6,"latency_p50_ms":2.4,"latency_p99_ms":2.8,"errors":0,"total_queries":4273,"duration_s":5.0,"pass":true,"threshold_qps_min":683.7,"threshold_p50_max_ms":2.9}
{"schema_version":2,"kind":"LoadTest","benchmark":"ping_c4","scenario":"ping","concurrency":4,"qps":1446.4,"latency_p50_ms":2.7,"latency_p99_ms":3.1,"errors":0,"total_queries":7232,"duration_s":5.0,"pass":true,"threshold_qps_min":1157.1,"threshold_p50_max_ms":3.2}
{"schema_version":2,"kind":"LoadTest","benchmark":"ping_c8","scenario":"ping","concurrency":8,"qps":2079.6,"latency_p50_ms":2.8,"latency_p99_ms":3.2,"errors":2,"total_queries":10400,"duration_s":5.0,"pass":true,"threshold_qps_min":1663.7,"threshold_p50_max_ms":3.3}
{"schema_version":2,"kind":"LoadTest","benchmark":"ping_c16","scenario":"ping","concurrency":16,"qps":3315,"latency_p50_ms":2.9,"latency_p99_ms":3.5,"errors":6,"total_queries":16581,"duration_s":5.0,"pass":true,"threshold_qps_min":2652.0,"threshold_p50_max_ms":3.4}
{"schema_version":2,"kind":"LoadTest","benchmark":"ping_c32","scenario":"ping","concurrency":32,"qps":5154,"latency_p50_ms":3.2,"latency_p99_ms":4.0,"errors":14,"total_queries":25784,"duration_s":5.0,"pass":true,"threshold_qps_min":4123.2,"threshold_p50_max_ms":3.8}
```

- [ ] **Step 4: Verify comparison still works with ping baseline**

```bash
cd geode
make loadtest-compare
```

Expected: comparison passes against ping baseline (new `scenario` field is handled).

- [ ] **Step 5: Commit**

```bash
git add benchmarks/loadtest/compare.py benchmarks/loadtest/save_baseline.py benchmarks/loadtest/baseline.jsonl
git commit -m "feat(loadtest): update comparison infrastructure for scenario-based benchmarks"
```

---

### Task 7: Integration verification — run all scenarios

- [ ] **Step 1: Run ping scenario (backward compat)**

```bash
cd ../geode-test-harness && make loadtest-scenario SCENARIO=ping \
  LOADTEST_DSN="localhost:3141?insecure=true&user=geode&pass=<password>" \
  LOADTEST_LEVELS="1,2,4" LOADTEST_DURATION=3s
```

Expected: same results as existing load test. Report at `reports/loadtest_ping.json`.

- [ ] **Step 2: Run point_read scenario**

```bash
make loadtest-scenario SCENARIO=point_read \
  LOADTEST_DSN="localhost:3141?insecure=true&user=geode&pass=<password>" \
  LOADTEST_LEVELS="1,2,4" LOADTEST_DURATION=3s
```

Expected: 500 nodes created during setup, queries execute, teardown cleans up. Report at `reports/loadtest_point_read.json`.

- [ ] **Step 3: Run one_hop scenario**

```bash
make loadtest-scenario SCENARIO=one_hop \
  LOADTEST_DSN="localhost:3141?insecure=true&user=geode&pass=<password>" \
  LOADTEST_LEVELS="1,2,4" LOADTEST_DURATION=3s
```

Expected: 1000 nodes + 3000 edges created, single-hop queries execute, teardown cleans up.

- [ ] **Step 4: Run two_hop scenario**

```bash
make loadtest-scenario SCENARIO=two_hop \
  LOADTEST_DSN="localhost:3141?insecure=true&user=geode&pass=<password>" \
  LOADTEST_LEVELS="1,2,4" LOADTEST_DURATION=3s
```

Expected: 2000 nodes + 8000 edges created, two-hop queries with DISTINCT and LIMIT execute, teardown cleans up.

- [ ] **Step 5: Run fan_out scenario**

```bash
make loadtest-scenario SCENARIO=fan_out \
  LOADTEST_DSN="localhost:3141?insecure=true&user=geode&pass=<password>" \
  LOADTEST_LEVELS="1,2,4" LOADTEST_DURATION=3s
```

Expected: 2200 nodes (2000 persons + 200 companies) + 8000 edges (6000 KNOWS + 2000 WORKS_AT), cross-type traversal queries execute, teardown cleans up.

- [ ] **Step 6: Run all scenarios**

```bash
make loadtest-scenarios \
  LOADTEST_DSN="localhost:3141?insecure=true&user=geode&pass=<password>" \
  LOADTEST_LEVELS="1,2,4,8,16,32" LOADTEST_DURATION=5s
```

Expected: all 5 scenarios run sequentially, 5 report files generated.

- [ ] **Step 7: Save baselines for all scenarios**

For each scenario, save a baseline:

```bash
cd ../geode
python3 benchmarks/loadtest/save_baseline.py \
  --input ../geode-test-harness/reports/loadtest_ping.json \
  --output /tmp/baseline_ping.jsonl

python3 benchmarks/loadtest/save_baseline.py \
  --input ../geode-test-harness/reports/loadtest_point_read.json \
  --output /tmp/baseline_point_read.jsonl

# ... repeat for all scenarios

# Merge all baselines
cat /tmp/baseline_ping.jsonl /tmp/baseline_point_read.jsonl \
    /tmp/baseline_one_hop.jsonl /tmp/baseline_two_hop.jsonl \
    /tmp/baseline_fan_out.jsonl > benchmarks/loadtest/baseline.jsonl
```

- [ ] **Step 8: Verify comparison against new baselines**

```bash
make loadtest-compare
```

Expected: all scenarios pass.

- [ ] **Step 9: Commit baselines**

```bash
git add benchmarks/loadtest/baseline.jsonl
git commit -m "perf: save initial baselines for all load test scenarios"
```

---

### Task 8: Update save_baseline.py to support merging multiple scenario files

**Files:**

- Modify: `benchmarks/loadtest/save_baseline.py`

- [ ] **Step 1: Add --append flag for incremental baseline building**

Add an `--append` flag that appends to the baseline file instead of overwriting, filtering out entries with the same scenario to avoid duplicates:

```python
    parser.add_argument(
        "--append",
        action="store_true",
        help="Append to existing baseline (replacing entries for same scenario)",
    )
```

In the output section, when `--append` is used:

```python
    if args.append and os.path.exists(args.output):
        # Load existing baseline, filter out this scenario's entries
        existing = []
        with open(args.output) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                rec = json.loads(line)
                if rec.get("scenario") != scenario:
                    existing.append(rec)
        records = existing + records

    with open(args.output, "w") as f:
        for rec in records:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
```

- [ ] **Step 2: Add corresponding Makefile target for saving all baselines**

Add to `Makefile` (geode repo):

```makefile
loadtest-save-all-baselines: ## Save baselines for all scenarios
 @for scenario in ping point_read one_hop two_hop fan_out; do \
  if [ -f ../geode-test-harness/reports/loadtest_$${scenario}.json ]; then \
   python3 benchmarks/loadtest/save_baseline.py \
    --input ../geode-test-harness/reports/loadtest_$${scenario}.json \
    --output benchmarks/loadtest/baseline.jsonl \
    --append; \
  fi; \
 done
```

- [ ] **Step 3: Commit**

```bash
git add benchmarks/loadtest/save_baseline.py Makefile
git commit -m "feat(loadtest): add --append flag and loadtest-save-all-baselines target"
```

---

## Execution Checklist

After all tasks are complete, verify:

1. `cd ../geode-test-harness/loadtest/go && go build -o geode-loadtest .` — clean build
2. `-scenario ping` produces identical behavior to the old `-query read`
3. All 5 scenarios run to completion with `loadtest-scenarios` target
4. Data is properly created during setup and cleaned during teardown
5. `make loadtest-compare` passes against the new baseline
6. The JSON output includes `scenario` and `data_size` fields
7. Existing CI workflows (if any) continue to work with the ping scenario
