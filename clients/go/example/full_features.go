package main

import (
	"context"
	"fmt"
	"log"

	gql "go.spyder.org/geode/clients/go/gql"
)

func main() {
	// Create database connection with QUIC support
	db, err := gql.Open("quic://127.0.0.1:7567?page_size=100")
	if err != nil {
		log.Fatal(err)
	}
	// DB doesn't have Close method - connections are closed individually
	
	ctx := context.Background()
	
	// Connect to the database
	conn, err := db.Connect(ctx)
	if err != nil {
		log.Fatal(err)
	}
	defer conn.Close()
	
	fmt.Println("=== Geode Full Features Example ===")
	
	// 1. Authentication
	fmt.Println("1. Authentication:")
	auth := conn.Auth()
	session, err := auth.Login(ctx, "admin", "P@ssw0rd123!")
	if err != nil {
		log.Printf("Login failed: %v", err)
	} else {
		fmt.Printf("   ✓ Logged in as %s (token: %s...)\n", session.Username, session.Token[:10])
		defer auth.Logout(ctx, session.Token)
	}
	
	// 2. User Management
	fmt.Println("\n2. User Management:")
	user, err := auth.CreateUser(ctx, "alice", "alice@example.com", "P@ssw0rd456!", 
		[]string{"user"}, map[string]string{"department": "engineering"})
	if err != nil {
		log.Printf("Failed to create user: %v", err)
	} else {
		fmt.Printf("   ✓ Created user: %s (%s)\n", user.Username, user.Email)
	}
	
	// 3. Role and Permission Management
	fmt.Println("\n3. RBAC - Roles and Permissions:")
	role, err := auth.CreateRole(ctx, "developer", "Development team role", 
		[]string{"read_all", "write_code"})
	if err != nil {
		log.Printf("Failed to create role: %v", err)
	} else {
		fmt.Printf("   ✓ Created role: %s\n", role.Name)
	}
	
	// Check permissions
	hasPermission, err := auth.CheckPermission(ctx, user.ID, "graph", "read")
	if err == nil {
		fmt.Printf("   ✓ User has read permission on graph: %v\n", hasPermission)
	}
	
	// 4. Row-Level Security (ABAC)
	fmt.Println("\n4. Row-Level Security (ABAC):")
	policy := &gql.RLSPolicy{
		Name:      "user_own_data",
		Table:     "user_documents",
		Graph:     "default",
		Operation: "select",
		UsingExpression: "owner_id = current_user_id()",
		Permissive: true,
		Roles:     []int64{1}, // user role
		Enabled:   true,
		AuditLevel: "all_access",
	}
	
	err = auth.CreateRLSPolicy(ctx, policy)
	if err != nil {
		log.Printf("Failed to create RLS policy: %v", err)
	} else {
		fmt.Printf("   ✓ Created RLS policy: %s\n", policy.Name)
	}
	
	// 5. Transactions
	fmt.Println("\n5. Transactions:")
	err = conn.Begin(ctx)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("   ✓ Transaction started")
	
	// 6. Graph Operations
	fmt.Println("\n6. Graph Operations:")
	graph := conn.Graph()
	
	// Create nodes
	person1, err := graph.CreateNode(ctx, []string{"Person"}, map[string]gql.Value{
		"name": {Kind: gql.Str, Str: "Alice"},
		"age":  {Kind: gql.Int, Int: 30},
	})
	if err != nil {
		log.Printf("Failed to create node: %v", err)
	} else {
		fmt.Printf("   ✓ Created Person node: %d\n", person1.ID)
	}
	
	person2, err := graph.CreateNode(ctx, []string{"Person"}, map[string]gql.Value{
		"name": {Kind: gql.Str, Str: "Bob"},
		"age":  {Kind: gql.Int, Int: 25},
	})
	if err == nil {
		fmt.Printf("   ✓ Created Person node: %d\n", person2.ID)
	}
	
	company, err := graph.CreateNode(ctx, []string{"Company"}, map[string]gql.Value{
		"name":     {Kind: gql.Str, Str: "TechCorp"},
		"founded":  {Kind: gql.Int, Int: 2020},
	})
	if err == nil {
		fmt.Printf("   ✓ Created Company node: %d\n", company.ID)
	}
	
	// Create edges
	if person1 != nil && company != nil {
		edge1, err := graph.CreateEdge(ctx, person1.ID, company.ID, "WORKS_AT", 
			map[string]gql.Value{
				"since": {Kind: gql.Int, Int: 2021},
				"role":  {Kind: gql.Str, Str: "Engineer"},
			})
		if err == nil {
			fmt.Printf("   ✓ Created WORKS_AT edge: %d\n", edge1.ID)
		}
	}
	
	if person1 != nil && person2 != nil {
		edge2, err := graph.CreateEdge(ctx, person1.ID, person2.ID, "KNOWS", nil)
		if err == nil {
			fmt.Printf("   ✓ Created KNOWS edge: %d\n", edge2.ID)
		}
	}
	
	// 7. Pattern Matching
	fmt.Println("\n7. Pattern Matching:")
	pattern := &gql.GraphPattern{
		Nodes: []gql.NodePattern{
			{Variable: "p", Labels: []string{"Person"}},
			{Variable: "c", Labels: []string{"Company"}},
		},
		Edges: []gql.EdgePattern{
			{Source: "p", Target: "c", Label: "WORKS_AT"},
		},
		Where: "p.age > 25",
		OrderBy: []string{"p.name"},
		Limit: intPtr(10),
	}
	
	iter, err := graph.Match(ctx, pattern)
	if err != nil {
		log.Printf("Pattern match failed: %v", err)
	} else {
		fmt.Println("   ✓ Pattern match results:")
		for iter.Next() {
			row := iter.Row()
			if p, ok := row["p"]; ok && p.Kind == gql.Object {
				if name, ok := p.Obj["name"]; ok {
					fmt.Printf("     - Person: %s\n", name.Str)
				}
			}
		}
		iter.Close()
	}
	
	// 8. Shortest Path
	fmt.Println("\n8. Graph Algorithms:")
	if person1 != nil && person2 != nil {
		path, err := graph.ShortestPath(ctx, person1.ID, person2.ID, 5)
		if err != nil {
			log.Printf("Failed to find shortest path: %v", err)
		} else {
			fmt.Printf("   ✓ Shortest path length: %d nodes, %d edges\n", 
				len(path.Nodes), len(path.Edges))
		}
	}
	
	// 9. GQL Queries with ORDER BY, LIMIT, OFFSET
	fmt.Println("\n9. Advanced Queries:")
	page, pager, err := conn.Query(ctx, 
		"MATCH (p:Person)-[:WORKS_AT]->(c:Company) "+
		"WHERE p.age > 20 "+
		"RETURN p.name AS name, c.name AS company, p.age AS age "+
		"ORDER BY p.age DESC "+
		"LIMIT 5 OFFSET 0", 
		nil, 100)
	
	if err != nil {
		log.Printf("Query failed: %v", err)
	} else {
		fmt.Println("   ✓ Query results (ordered by age DESC):")
		for _, row := range page.Rows {
			name := row["name"].Str
			company := row["company"].Str
			age := row["age"].Int
			fmt.Printf("     - %s works at %s (age: %d)\n", name, company, age)
		}
		
		// Get next page if available
		if pager != nil {
			nextPage, err := pager(ctx)
			if err == nil && len(nextPage.Rows) > 0 {
				fmt.Printf("   ✓ Next page has %d more results\n", len(nextPage.Rows))
			}
		}
	}
	
	// 10. Aggregations
	fmt.Println("\n10. Aggregations:")
	aggPage, _, err := conn.Query(ctx,
		"MATCH (p:Person) "+
		"RETURN COUNT(p) AS total, AVG(p.age) AS avg_age, "+
		"MIN(p.age) AS min_age, MAX(p.age) AS max_age",
		nil, 100)
	
	if err != nil {
		log.Printf("Aggregation failed: %v", err)
	} else if len(aggPage.Rows) > 0 {
		row := aggPage.Rows[0]
		fmt.Printf("   ✓ Total persons: %d\n", row["total"].Int)
		avgAge, _ := row["avg_age"].Dec.Float64()
		fmt.Printf("   ✓ Average age: %.2f\n", avgAge)
		fmt.Printf("   ✓ Age range: %d - %d\n", row["min_age"].Int, row["max_age"].Int)
	}
	
	// 11. Commit transaction
	fmt.Println("\n11. Commit Transaction:")
	err = conn.Commit(ctx)
	if err != nil {
		log.Printf("Failed to commit: %v", err)
	} else {
		fmt.Println("   ✓ Transaction committed successfully")
	}
	
	// 12. Profile query execution
	fmt.Println("\n12. Query Profiling:")
	profilePage, _, err := conn.Query(ctx,
		"PROFILE MATCH (p:Person) RETURN p.name",
		nil, 100)
	
	if err != nil {
		log.Printf("Profile failed: %v", err)
	} else {
		fmt.Println("   ✓ Query profile generated")
		fmt.Printf("   ✓ Profile has %d result rows\n", len(profilePage.Rows))
	}
	
	fmt.Println("\n=== All Features Demonstrated Successfully ===")
}

func intPtr(i int) *int {
	return &i
}