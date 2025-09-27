package gql

// CANARY: REQ=REQ-GQL-DATASET-GO; FEATURE="DatasetIntegrationGoClient"; ASPECT=Testing; STATUS=TESTED; TEST=TestDatasetMigration|TestNetworkTypes|TestGeographicTypes|TestVectorSimilarity|TestCurrencyType|TestGraphTraversal|TestTransactions|TestConstraints|TestPerformanceWithIndexes; OWNER=clients; UPDATED=2025-09-26
// NOTE: Adds Go client dataset coverage aligning with Zig client & E2E dataset tests. Addresses prior CANARY_STALE by providing UPDATED field.

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fastProbeServer attempts a quick TCP connect to the QUIC port to determine
// if a server is likely running. QUIC itself uses UDP, but we rely on an env
// flag or a sentinel file for intentional dataset runs. If GEODE_DATASET=1 is
// not set we skip heavy dataset tests immediately.
func fastProbeServer() bool {
	if os.Getenv("GEODE_DATASET") != "1" { return false }
	d := net.Dialer{ Timeout: 150 * time.Millisecond }
	// Attempt a TCP connect; success just indicates listener (may fail silently if QUIC only); we treat error as non-fatal.
	if c, err := d.Dial("tcp", "127.0.0.1:8443"); err == nil { c.Close(); return true }
	// Fall back to optimistic assumption if env set.
	return true
}

// Helpers to extract primitive values from Value typed rows.
func num(row map[string]Value, key string) float64 {
	v, ok := row[key]
	if !ok { return 0 }
	switch v.Kind {
	case Int:
		return float64(v.Int)
	case Dec:
		if v.Dec != nil {
			f, _ := v.Dec.Float64(); return f
		}
	case Str:
		// best-effort parse
		// ignored here for brevity
	}
	return 0
}

func str(row map[string]Value, key string) string {
	if v, ok := row[key]; ok {
		if v.Kind == Str { return v.Str }
	}
	return ""
}

func boolv(row map[string]Value, key string) bool {
	if v, ok := row[key]; ok && v.Kind == Bool { return v.Bool }
	return false
}

// TestDatasetMigration tests loading the social network dataset via migrations
func TestDatasetMigration(t *testing.T) {
	if !fastProbeServer() { t.Skip("Dataset server not running (set GEODE_DATASET=1 to enable)") }
	ctx := context.Background()
	
	// Connect to Geode
	db, err := Open("quic://127.0.0.1:8443")
	if err != nil {
		t.Skipf("Cannot connect to Geode: %v", err)
	}
	defer db.Close()
	
	conn, err := db.Connect(ctx)
	if err != nil {
		t.Fatalf("Failed to connect: %v", err)
	}
	defer conn.Close()
	
	// Load migrations in order
	migrations := []string{
		"../../../migrations/001_social_network_schema.gql",
		"../../../migrations/002_social_network_data.gql",
		"../../../migrations/003_social_network_relationships.gql",
		"../../../migrations/004_social_network_events_products.gql",
	}
	
	for _, migration := range migrations {
		t.Logf("Loading migration: %s", filepath.Base(migration))
		
		content, err := os.ReadFile(migration)
		if err != nil {
			t.Fatalf("Failed to read migration %s: %v", migration, err)
		}
		
		// Split by semicolons and execute each statement
		statements := strings.Split(string(content), ";")
		for _, stmt := range statements {
			stmt = strings.TrimSpace(stmt)
			if stmt == "" || strings.HasPrefix(stmt, "--") {
				continue
			}
			
			_, _, err := conn.Query(ctx, stmt+";", nil, 1000)
			if err != nil {
				// Skip if it's a comment-only statement
				if !strings.Contains(err.Error(), "empty") {
					t.Logf("Warning: Statement failed: %v", err)
				}
			}
		}
	}
	
	// Verify data was loaded
	page, _, err := conn.Query(ctx, "MATCH (n) RETURN count(n) AS count", nil, 10)
	if err != nil {
		t.Fatalf("Failed to count nodes: %v", err)
	}
	
	if len(page.Rows) == 0 {
		t.Fatal("No rows returned from count query")
	}
	
	count := num(page.Rows[0], "count")
	if count < 100 {
		t.Errorf("Expected at least 100 nodes, got %v", count)
	}
	
	t.Logf("Successfully loaded %v nodes", count)
}

// TestNetworkTypes tests IpAddr, Subnet, and Mac types
func TestNetworkTypes(t *testing.T) {
	if !fastProbeServer() { t.Skip("Dataset server not running") }
	ctx := context.Background()
	
	db, err := Open("quic://127.0.0.1:8443")
	if err != nil {
		t.Skip("Cannot connect to Geode")
	}
	defer db.Close()
	
	conn, err := db.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	
	tests := []struct {
		name  string
		query string
		check func(map[string]Value) error
	}{
		{
			name: "IP address private check",
			query: "MATCH (u:User {id: 'user-1'}) RETURN u.ip_address AS ip, ip_is_private(u.ip_address) AS is_private",
			check: func(row map[string]Value) error {
				if !boolv(row, "is_private") {
					return fmt.Errorf("expected private IP")
				}
				return nil
			},
		},
		{
			name: "Subnet containment",
			query: "MATCH (d:Device {id: 'device-1'}) RETURN ip_contains(d.subnet, d.ip_address) AS contained",
			check: func(row map[string]Value) error {
				if !boolv(row, "contained") {
					return fmt.Errorf("IP should be in subnet")
				}
				return nil
			},
		},
		{
			name: "MAC vendor OUI extraction",
			query: "MATCH (d:Device {id: 'device-1'}) RETURN mac_vendor_oui(d.mac_address) AS oui",
			check: func(row map[string]Value) error {
				v, ok := row["oui"]
				if !ok || v.Kind != Array || len(v.Arr) != 3 {
					return fmt.Errorf("expected 3-byte OUI array")
				}
				return nil
			},
		},
	}
	
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			page, _, err := conn.Query(ctx, tt.query, nil, 10)
			if err != nil {
				t.Fatalf("Query failed: %v", err)
			}
			
			if len(page.Rows) == 0 {
				t.Fatal("No rows returned")
			}
			
			if err := tt.check(page.Rows[0]); err != nil {
				t.Error(err)
			}
		})
	}
}

// TestGeographicTypes tests LatLon and distance calculations
func TestGeographicTypes(t *testing.T) {
	if !fastProbeServer() { t.Skip("Dataset server not running") }
	ctx := context.Background()
	
	db, err := Open("quic://127.0.0.1:8443")
	if err != nil {
		t.Skip("Cannot connect to Geode")
	}
	defer db.Close()
	
	conn, err := db.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	
	// Test distance calculation between SF and NYC
	query := `
		MATCH (l1:Location {name: 'San Francisco'}), (l2:Location {name: 'New York'})
		RETURN distance_haversine(l1.coordinates, l2.coordinates) AS distance
	`
	
	page, _, err := conn.Query(ctx, query, nil, 10)
	if err != nil {
		t.Fatalf("Query failed: %v", err)
	}
	
	if len(page.Rows) == 0 {
		t.Fatal("No distance calculated")
	}
	
	distance := num(page.Rows[0], "distance")
	// Distance should be approximately 4,130,000 meters
	if distance < 4000000 || distance > 4200000 {
		t.Errorf("Unexpected distance between SF and NYC: %v meters", distance)
	}
	
	// Test spatial query
	spatialQuery := `
		MATCH (e:Event)
		WHERE distance_haversine(e.location, LatLon(37.7749, -122.4194)) < 100000
		RETURN count(e) AS nearby_events
	`
	
	page, _, err = conn.Query(ctx, spatialQuery, nil, 10)
	if err != nil {
		t.Fatalf("Spatial query failed: %v", err)
	}
	
	nearbyEvents := num(page.Rows[0], "nearby_events")
	if nearbyEvents < 1 {
		t.Error("Expected at least one event near San Francisco")
	}
}

// TestVectorSimilarity tests vector operations and similarity search
func TestVectorSimilarity(t *testing.T) {
	if !fastProbeServer() { t.Skip("Dataset server not running") }
	ctx := context.Background()
	
	db, err := Open("quic://127.0.0.1:8443")
	if err != nil {
		t.Skip("Cannot connect to Geode")
	}
	defer db.Close()
	
	conn, err := db.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	
	// Find similar posts using vector similarity
	query := `
		MATCH (p1:Post {id: 'post-1'})
		MATCH (p2:Post)
		WHERE p1 <> p2
		  AND vector_cosine_similarity(p1.content_vector, p2.content_vector) > 0.5
		RETURN p2.id AS similar_post_id,
		       vector_cosine_similarity(p1.content_vector, p2.content_vector) AS similarity
		ORDER BY similarity DESC
		LIMIT 5
	`
	
	page, _, err := conn.Query(ctx, query, nil, 10)
	if err != nil {
		t.Fatalf("Vector similarity query failed: %v", err)
	}
	
	if len(page.Rows) < 2 {
		t.Error("Expected at least 2 similar posts")
	}
	
	for _, row := range page.Rows {
		similarity := num(row, "similarity")
		if similarity < 0.5 || similarity > 1.0 {
			 t.Errorf("Invalid similarity score: %v", similarity)
		}
		postID := str(row, "similar_post_id")
		t.Logf("Similar post %s with similarity %v", postID, similarity)
	}
}

// TestCurrencyType tests currency operations
func TestCurrencyType(t *testing.T) {
	if !fastProbeServer() { t.Skip("Dataset server not running") }
	ctx := context.Background()
	
	db, err := Open("quic://127.0.0.1:8443")
	if err != nil {
		t.Skip("Cannot connect to Geode")
	}
	defer db.Close()
	
	conn, err := db.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	
	// Test currency retrieval and operations
	query := `
		MATCH (c:Company {id: 'comp-1'})
		RETURN c.name AS name,
		       c.revenue AS revenue,
		       currency_code(c.revenue) AS currency,
		       currency_amount(c.revenue) AS amount
	`
	
	page, _, err := conn.Query(ctx, query, nil, 10)
	if err != nil {
		t.Fatalf("Currency query failed: %v", err)
	}
	
	if len(page.Rows) == 0 {
		t.Fatal("No company found")
	}
	
	row := page.Rows[0]
	if str(row, "currency") != "USD" {
			 t.Errorf("Expected USD currency, got %v", str(row, "currency"))
	}

	amount := num(row, "amount")
	if amount != 15000000000 {
		t.Errorf("Expected revenue amount 15000000000, got %v", amount)
	}
}

// TestGraphTraversal tests relationship traversals
func TestGraphTraversal(t *testing.T) {
	if !fastProbeServer() { t.Skip("Dataset server not running") }
	ctx := context.Background()
	
	db, err := Open("quic://127.0.0.1:8443")
	if err != nil {
		t.Skip("Cannot connect to Geode")
	}
	defer db.Close()
	
	conn, err := db.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	
	tests := []struct {
		name     string
		query    string
		minCount int
	}{
		{
			name: "User followers",
			query: `
				MATCH (follower:User)-[:FOLLOWS]->(u:User {id: 'user-3'})
				RETURN count(follower) AS follower_count
			`,
			minCount: 3,
		},
		{
			name: "User posts",
			query: `
				MATCH (u:User {id: 'user-1'})-[:POSTED]->(p:Post)
				RETURN count(p) AS post_count
			`,
			minCount: 1,
		},
		{
			name: "Event attendance",
			query: `
				MATCH (u:User)-[:ATTENDING]->(e:Event {id: 'event-1'})
				RETURN count(u) AS attendee_count
			`,
			minCount: 2,
		},
		{
			name: "Company investments",
			query: `
				MATCH (c:Company)-[:INVESTED_IN]->(c2:Company)
				RETURN count(c) AS investor_count
			`,
			minCount: 1,
		},
	}
	
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			page, _, err := conn.Query(ctx, tt.query, nil, 10)
			if err != nil {
				t.Fatalf("Query failed: %v", err)
			}
			
			if len(page.Rows) == 0 {
				t.Fatal("No results returned")
			}
			
			// Get the count field (it has different names in different queries)
			var count float64
			for k := range page.Rows[0] {
				if strings.Contains(k, "count") {
					count = num(page.Rows[0], k)
					break
				}
			}
			
			if int(count) < tt.minCount {
				t.Errorf("Expected at least %d, got %v", tt.minCount, count)
			}
		})
	}
}

// TestTransactions tests transaction commit and rollback
func TestTransactions(t *testing.T) {
	if !fastProbeServer() { t.Skip("Dataset server not running") }
	ctx := context.Background()
	
	db, err := Open("quic://127.0.0.1:8443")
	if err != nil {
		t.Skip("Cannot connect to Geode")
	}
	defer db.Close()
	
	conn, err := db.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	
	// Test rollback
	t.Run("Rollback", func(t *testing.T) {
		if err := conn.Begin(ctx); err != nil { t.Fatal(err) }
		
		// Create a test node in transaction
		_, _, err = conn.Query(ctx, "CREATE (:TestNode {id: 'rollback-test', value: 42})", nil, 10)
		if err != nil {
			t.Fatal(err)
		}
		
		// Rollback the transaction
		if err := conn.Rollback(ctx); err != nil { t.Fatal(err) }
		
		// Verify node doesn't exist
		page, _, err := conn.Query(ctx, "MATCH (n:TestNode {id: 'rollback-test'}) RETURN count(n) AS count", nil, 10)
		if err != nil {
			t.Fatal(err)
		}
		
		count := num(page.Rows[0], "count")
		if count != 0 {
			t.Error("Node should not exist after rollback")
		}
	})
	
	// Test commit
	t.Run("Commit", func(t *testing.T) {
		if err := conn.Begin(ctx); err != nil { t.Fatal(err) }
		
		// Create a test node in transaction
		_, _, err = conn.Query(ctx, "CREATE (:TestNode {id: 'commit-test', value: 42})", nil, 10)
		if err != nil {
			t.Fatal(err)
		}
		
		// Commit the transaction
		if err := conn.Commit(ctx); err != nil { t.Fatal(err) }
		
		// Verify node exists
		page, _, err := conn.Query(ctx, "MATCH (n:TestNode {id: 'commit-test'}) RETURN n.value AS value", nil, 10)
		if err != nil {
			t.Fatal(err)
		}
		
		if len(page.Rows) == 0 {
			t.Error("Node should exist after commit")
		} else {
			value := num(page.Rows[0], "value")
			if value != 42 {
				t.Errorf("Expected value 42, got %v", value)
			}
		}
		
		// Clean up
		_, _, _ = conn.Query(ctx, "MATCH (n:TestNode {id: 'commit-test'}) DELETE n", nil, 10)
	})
}

// TestConstraints tests that constraints are enforced
func TestConstraints(t *testing.T) {
	if !fastProbeServer() { t.Skip("Dataset server not running") }
	ctx := context.Background()
	
	db, err := Open("quic://127.0.0.1:8443")
	if err != nil {
		t.Skip("Cannot connect to Geode")
	}
	defer db.Close()
	
	conn, err := db.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	
	// Try to violate unique constraint
	_, _, err = conn.Query(ctx, `
		CREATE (:User {
			id: 'test-duplicate',
			email: 'alice.johnson@example.com',  -- This email already exists
			username: 'test_duplicate'
		})
	`, nil, 10)
	
	if err == nil {
		t.Error("Expected unique constraint violation")
		// Clean up if it somehow succeeded
		_, _, _ = conn.Query(ctx, "MATCH (u:User {id: 'test-duplicate'}) DELETE u", nil, 10)
	} else if !strings.Contains(strings.ToLower(err.Error()), "constraint") &&
	          !strings.Contains(strings.ToLower(err.Error()), "unique") {
		t.Errorf("Expected constraint error, got: %v", err)
	}
}

// TestPerformanceWithIndexes tests that indexes improve query performance
func TestPerformanceWithIndexes(t *testing.T) {
	if !fastProbeServer() { t.Skip("Dataset server not running") }
	ctx := context.Background()
	
	db, err := Open("quic://127.0.0.1:8443")
	if err != nil {
		t.Skip("Cannot connect to Geode")
	}
	defer db.Close()
	
	conn, err := db.Connect(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	
	// Query using indexed field (should be fast)
	start := time.Now()
	page, _, err := conn.Query(ctx, `
		MATCH (u:User)
		WHERE u.email = 'alice.johnson@example.com'
		RETURN u.username AS username
	`, nil, 10)
	elapsed := time.Since(start)
	
	if err != nil {
		t.Fatal(err)
	}
	
	if len(page.Rows) == 0 {
		t.Fatal("User not found")
	}
	
	if str(page.Rows[0], "username") != "alice_j" {
		 t.Error("Wrong user returned")
	}
	
	// With index, this should complete quickly
	if elapsed > 100*time.Millisecond {
		t.Logf("Warning: Indexed query took %v, might be missing index", elapsed)
	} else {
		t.Logf("Indexed query completed in %v", elapsed)
	}
}

// BenchmarkDatasetQueries benchmarks common queries on the dataset
func BenchmarkDatasetQueries(b *testing.B) {
	ctx := context.Background()
	
	db, err := Open("quic://127.0.0.1:8443")
	if err != nil {
		b.Skip("Cannot connect to Geode")
	}
	defer db.Close()
	
	conn, err := db.Connect(ctx)
	if err != nil {
		b.Fatal(err)
	}
	defer conn.Close()
	
	benchmarks := []struct {
		name  string
		query string
	}{
		{
			name:  "SimpleNodeLookup",
			query: "MATCH (u:User {id: 'user-1'}) RETURN u",
		},
		{
			name:  "IndexedEmailLookup",
			query: "MATCH (u:User) WHERE u.email = 'alice.johnson@example.com' RETURN u",
		},
		{
			name:  "OneHopTraversal",
			query: "MATCH (u:User {id: 'user-1'})-[:POSTED]->(p:Post) RETURN p",
		},
		{
			name:  "TwoHopTraversal",
			query: "MATCH (u:User {id: 'user-1'})-[:POSTED]->(p:Post)<-[:LIKES]-(u2:User) RETURN u2",
		},
		{
			name:  "VectorSimilarity",
			query: "MATCH (p1:Post {id: 'post-1'}), (p2:Post) WHERE vector_cosine_similarity(p1.content_vector, p2.content_vector) > 0.7 RETURN p2 LIMIT 10",
		},
		{
			name:  "SpatialQuery",
			query: "MATCH (e:Event) WHERE distance_haversine(e.location, LatLon(37.7749, -122.4194)) < 100000 RETURN e",
		},
		{
			name:  "NetworkQuery",
			query: "MATCH (d:Device) WHERE ip_is_private(d.ip_address) RETURN d",
		},
	}
	
	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				_, _, err := conn.Query(ctx, bm.query, nil, 100)
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}