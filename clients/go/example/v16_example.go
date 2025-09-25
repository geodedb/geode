// +build ignore

package main

import (
	"context"
	"fmt"
	"log"
	
	"geode/clients/go/gql"
)

// Example demonstrating v0.16.0 features:
// - QUIC+TLS only transport (TCP removed)
// - Full Raft clustering support
// - RLS/ABAC enforcement
// - Materialized views
func main() {
	ctx := context.Background()
	
	// v0.16.0: QUIC is the only network transport
	// Default port changed from 7567 to 8443
	db, err := gql.Open("quic:127.0.0.1:8443?page_size=1000")
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}
	defer db.Close()
	
	// Connect to server
	conn, err := db.Connect(ctx)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}
	defer conn.Close()
	
	fmt.Println("Connected to Geode v0.16.0 via QUIC+TLS")
	
	// Demonstrate RLS/ABAC (v0.16.0: enforced by default)
	demonstrateRLS(ctx, conn)
	
	// Demonstrate Materialized Views (v0.16.0: fully implemented)
	demonstrateMaterializedViews(ctx, conn)
	
	// Demonstrate Clustering (v0.16.0: full Raft support)
	demonstrateClustering(ctx, conn)
	
	// Demonstrate Recursive CTEs (v0.16.0: integrated)
	demonstrateRecursiveCTE(ctx, conn)
}

func demonstrateRLS(ctx context.Context, conn *gql.Conn) {
	fmt.Println("\n=== Row-Level Security (v0.16.0) ===")
	
	// Create RLS policy
	policy := `
		CREATE POLICY tenant_isolation ON employees
		USING (tenant_id = current_setting('app.tenant_id')::int)
		WITH CHECK (tenant_id = current_setting('app.tenant_id')::int)
	`
	
	if _, _, err := conn.Query(ctx, policy, nil, 100); err != nil {
		log.Printf("Note: RLS policy may already exist: %v", err)
	}
	
	// Set tenant context
	if _, _, err := conn.Query(ctx, "SET app.tenant_id = 5", nil, 100); err != nil {
		log.Printf("Failed to set tenant: %v", err)
		return
	}
	
	// Query with RLS automatically applied
	page, next, err := conn.Query(ctx, 
		"SELECT * FROM employees ORDER BY name LIMIT 10",
		nil, 100)
	if err != nil {
		log.Printf("RLS query failed: %v", err)
		return
	}
	
	fmt.Printf("RLS-filtered results (tenant 5 only): %d rows\n", len(page.Rows))
	
	// Process remaining pages
	for {
		page, err = next(ctx)
		if err != nil || page == nil {
			break
		}
		fmt.Printf("Additional page: %d rows\n", len(page.Rows))
	}
}

func demonstrateMaterializedViews(ctx context.Context, conn *gql.Conn) {
	fmt.Println("\n=== Materialized Views (v0.16.0) ===")
	
	// Create materialized view
	createMV := `
		CREATE MATERIALIZED VIEW sales_summary AS
		SELECT 
			region,
			SUM(amount) as total_sales,
			COUNT(*) as transaction_count
		FROM sales
		GROUP BY region
		WITH (
			refresh_method = 'incremental',
			refresh_interval = '1 hour'
		)
	`
	
	if _, _, err := conn.Query(ctx, createMV, nil, 100); err != nil {
		log.Printf("Note: MV may already exist: %v", err)
	}
	
	// Manual refresh (v0.16.0: complete and incremental supported)
	refresh := "REFRESH MATERIALIZED VIEW sales_summary"
	if _, _, err := conn.Query(ctx, refresh, nil, 100); err != nil {
		log.Printf("MV refresh failed: %v", err)
		return
	}
	
	fmt.Println("Materialized view refreshed successfully")
	
	// Query the MV
	page, _, err := conn.Query(ctx,
		"SELECT * FROM sales_summary ORDER BY total_sales DESC",
		nil, 100)
	if err != nil {
		log.Printf("MV query failed: %v", err)
		return
	}
	
	fmt.Printf("Materialized view contains %d regions\n", len(page.Rows))
	for _, row := range page.Rows {
		region := row["region"].Str
		total := row["total_sales"].Dec
		count := row["transaction_count"].Int
		fmt.Printf("  %s: $%v from %d transactions\n", region, total, count)
	}
}

func demonstrateClustering(ctx context.Context, conn *gql.Conn) {
	fmt.Println("\n=== Clustering Status (v0.16.0: Full Raft) ===")
	
	// Query cluster status
	status, _, err := conn.Query(ctx,
		"SHOW CLUSTER STATUS",
		nil, 100)
	if err != nil {
		log.Printf("Cluster status query failed: %v", err)
		return
	}
	
	if len(status.Rows) > 0 {
		for _, node := range status.Rows {
			nodeID := node["node_id"].Int
			role := node["role"].Str
			state := node["state"].Str
			term := node["term"].Int
			
			fmt.Printf("Node %d: %s (state=%s, term=%d)\n", 
				nodeID, role, state, term)
		}
	} else {
		fmt.Println("Single-node mode (clustering available)")
	}
	
	// Show replication status
	repl, _, err := conn.Query(ctx,
		"SHOW REPLICATION STATUS",
		nil, 100)
	if err == nil && len(repl.Rows) > 0 {
		fmt.Printf("Replication lag: %dms\n", repl.Rows[0]["lag_ms"].Int)
	}
}

func demonstrateRecursiveCTE(ctx context.Context, conn *gql.Conn) {
	fmt.Println("\n=== Recursive CTEs (v0.16.0: Integrated) ===")
	
	// Recursive query with bounded expansion
	recursive := `
		WITH RECURSIVE hierarchy AS (
			-- Anchor: top-level employees
			SELECT id, name, manager_id, 0 as level
			FROM employees
			WHERE manager_id IS NULL
			
			UNION ALL
			
			-- Recursive: find reports
			SELECT e.id, e.name, e.manager_id, h.level + 1
			FROM employees e
			JOIN hierarchy h ON e.manager_id = h.id
			WHERE h.level < 3  -- v0.16.0: Bounded to prevent runaway
		)
		SELECT * FROM hierarchy
		ORDER BY level, name
	`
	
	page, next, err := conn.Query(ctx, recursive, nil, 100)
	if err != nil {
		log.Printf("Recursive CTE failed: %v", err)
		return
	}
	
	fmt.Printf("Organization hierarchy (max depth 3):\n")
	currentLevel := -1
	for _, row := range page.Rows {
		level := int(row["level"].Int)
		name := row["name"].Str
		
		if level != currentLevel {
			currentLevel = level
			fmt.Printf("\nLevel %d:\n", level)
		}
		fmt.Printf("  - %s\n", name)
	}
	
	// Process remaining pages
	for {
		page, err = next(ctx)
		if err != nil || page == nil {
			break
		}
		for _, row := range page.Rows {
			level := int(row["level"].Int)
			name := row["name"].Str
			fmt.Printf("  Level %d: %s\n", level, name)
		}
	}
}

// Helper to demonstrate v0.16.0 transport changes
func demonstrateTransportInfo() {
	fmt.Println("\n=== Transport Info (v0.16.0) ===")
	fmt.Println("- TCP: REMOVED (no longer supported)")
	fmt.Println("- QUIC: MANDATORY (with TLS 1.3)")
	fmt.Println("- Default Port: 8443 (changed from 7567)")
	fmt.Println("- TLS: Auto-generates self-signed certs if missing")
	fmt.Println("- Process Mode: Still available for local development")
	
	// Show connection string examples
	fmt.Println("\nConnection String Examples:")
	fmt.Println("  Network:  quic:hostname:8443")
	fmt.Println("  Local:    process:/path/to/geoded")
	fmt.Println("  Invalid:  tcp:hostname:7567  (NO LONGER WORKS)")
}