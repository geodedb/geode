// Transaction and savepoint example for Geode Go client.
//
// Demonstrates:
// - Transaction management (BEGIN, COMMIT, ROLLBACK)
// - Savepoints for partial rollback
// - Error handling with rollback
// - Connection pooling with transactions
package main

import (
	"context"
	"fmt"
	"log"
	"sync"

	"github.com/spyder/geode/clients/go/gql"
)

func basicTransactionExample(ctx context.Context) error {
	fmt.Println("=== Basic Transaction Example ===\n")

	db, err := gql.Open("quic:127.0.0.1:3141?skip_verify=true")
	if err != nil {
		return err
	}
	defer db.Close()

	conn, err := db.Connect(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()

	// Start a transaction
	if err := conn.Begin(ctx); err != nil {
		return err
	}

	// Create some nodes
	_, _, err = conn.Query(ctx, "CREATE (p:Person {name: 'Alice', age: 30})", nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}

	_, _, err = conn.Query(ctx, "CREATE (p:Person {name: 'Bob', age: 25})", nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}

	// Query within transaction
	page, _, err := conn.Query(ctx, "MATCH (p:Person) RETURN p.name AS name, p.age AS age", nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}

	fmt.Println("Created persons:")
	for _, row := range page.Rows {
		name := row["name"]
		age := row["age"]
		fmt.Printf("  - %v, age %v\n", name.Str, age.Int)
	}

	// Commit the transaction
	if err := conn.Commit(ctx); err != nil {
		return err
	}

	fmt.Println("\nTransaction committed successfully!\n")
	return nil
}

func savepointExample(ctx context.Context) error {
	fmt.Println("=== Savepoint Example ===\n")

	db, err := gql.Open("quic:127.0.0.1:3141?skip_verify=true")
	if err != nil {
		return err
	}
	defer db.Close()

	conn, err := db.Connect(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()

	// Start a transaction
	if err := conn.Begin(ctx); err != nil {
		return err
	}

	// Create initial data
	_, _, err = conn.Query(ctx, "CREATE (p:Person {name: 'Charlie', age: 35, city: 'NYC'})", nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("Created person: Charlie, age 35, city NYC")

	// Create a savepoint before making changes
	sp1, err := conn.Savepoint(ctx, "before_update")
	if err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("Created savepoint: before_update")

	// Make some changes
	_, _, err = conn.Query(ctx, "MATCH (p:Person {name: 'Charlie'}) SET p.age = 40", nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("Updated Charlie's age to 40")

	// Create another savepoint
	sp2, err := conn.Savepoint(ctx, "before_city_update")
	if err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("Created savepoint: before_city_update")

	// Make more changes
	_, _, err = conn.Query(ctx, "MATCH (p:Person {name: 'Charlie'}) SET p.city = 'SF'", nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("Updated Charlie's city to SF")

	// Rollback to sp2 (undoes city change)
	if err := conn.RollbackTo(ctx, sp2); err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("\nRolled back to savepoint: before_city_update")
	fmt.Println("Charlie's city is still NYC, age is still 40")

	// Commit the transaction
	if err := conn.Commit(ctx); err != nil {
		return err
	}
	fmt.Println("\nTransaction committed!\n")

	// Verify final state
	page, _, err := conn.Query(ctx, "MATCH (p:Person {name: 'Charlie'}) RETURN p.age AS age, p.city AS city", nil, 1000)
	if err != nil {
		return err
	}

	if len(page.Rows) > 0 {
		row := page.Rows[0]
		fmt.Printf("Final state: age=%v, city=%v\n", row["age"].Int, row["city"].Str)
	}

	return nil
}

func nestedSavepointsExample(ctx context.Context) error {
	fmt.Println("\n=== Nested Savepoints Example ===\n")

	db, err := gql.Open("quic:127.0.0.1:3141?skip_verify=true")
	if err != nil {
		return err
	}
	defer db.Close()

	conn, err := db.Connect(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()

	if err := conn.Begin(ctx); err != nil {
		return err
	}

	// Level 0: Initial state
	_, _, err = conn.Query(ctx, "CREATE (org:Organization {name: 'Acme Corp'})", nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("Created organization: Acme Corp")

	// Level 1: Add departments
	spDepts, err := conn.Savepoint(ctx, "departments")
	if err != nil {
		conn.Rollback(ctx)
		return err
	}

	_, _, err = conn.Query(ctx,
		"MATCH (org:Organization {name: 'Acme Corp'}) "+
			"CREATE (org)-[:HAS_DEPT]->(d:Department {name: 'Engineering'})",
		nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}

	_, _, err = conn.Query(ctx,
		"MATCH (org:Organization {name: 'Acme Corp'}) "+
			"CREATE (org)-[:HAS_DEPT]->(d:Department {name: 'Sales'})",
		nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("Added departments: Engineering, Sales")

	// Level 2: Add employees
	spEmployees, err := conn.Savepoint(ctx, "employees")
	if err != nil {
		conn.Rollback(ctx)
		return err
	}

	_, _, err = conn.Query(ctx,
		"MATCH (d:Department {name: 'Engineering'}) "+
			"CREATE (d)-[:HAS_EMPLOYEE]->(e:Employee {name: 'Alice'})",
		nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}

	_, _, err = conn.Query(ctx,
		"MATCH (d:Department {name: 'Engineering'}) "+
			"CREATE (d)-[:HAS_EMPLOYEE]->(e:Employee {name: 'Bob'})",
		nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("Added employees to Engineering: Alice, Bob")

	// Level 3: Add projects
	spProjects, err := conn.Savepoint(ctx, "projects")
	if err != nil {
		conn.Rollback(ctx)
		return err
	}

	_, _, err = conn.Query(ctx,
		"MATCH (e:Employee {name: 'Alice'}) "+
			"CREATE (e)-[:WORKS_ON]->(p:Project {name: 'Project X'})",
		nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("Added project: Project X for Alice")

	// Oops, we don't want projects yet - rollback to employees level
	if err := conn.RollbackTo(ctx, spEmployees); err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("\nRolled back to 'employees' savepoint (removed projects)")

	// We can continue from the employees level
	_, _, err = conn.Query(ctx,
		"MATCH (d:Department {name: 'Sales'}) "+
			"CREATE (d)-[:HAS_EMPLOYEE]->(e:Employee {name: 'Charlie'})",
		nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("Added employee to Sales: Charlie")

	// Commit everything
	if err := conn.Commit(ctx); err != nil {
		return err
	}
	fmt.Println("\nTransaction committed!\n")

	return nil
}

func poolWithTransactionsExample(ctx context.Context) error {
	fmt.Println("=== Connection Pool with Transactions ===\n")

	pool := gql.NewPool(
		"127.0.0.1:3141",
		"gql-go",
		"0.1",
		"min",
		1000,
		10,
		0, // No idle timeout
	)
	defer pool.Close()

	// Simulate concurrent transactions
	persons := []struct {
		name string
		age  int
	}{
		{"David", 28},
		{"Emma", 32},
		{"Frank", 45},
	}

	var wg sync.WaitGroup
	for _, p := range persons {
		wg.Add(1)
		go func(name string, age int) {
			defer wg.Done()

			conn, err := pool.Acquire(ctx)
			if err != nil {
				log.Printf("Failed to acquire connection: %v", err)
				return
			}
			defer pool.Release(conn)

			if err := conn.Begin(ctx); err != nil {
				log.Printf("Failed to begin transaction: %v", err)
				return
			}

			query := fmt.Sprintf("CREATE (p:Person {name: '%s', age: %d})", name, age)
			_, _, err = conn.Query(ctx, query, nil, 1000)
			if err != nil {
				conn.Rollback(ctx)
				log.Printf("Failed to create %s: %v", name, err)
				return
			}

			if err := conn.Commit(ctx); err != nil {
				log.Printf("Failed to commit for %s: %v", name, err)
				return
			}

			fmt.Printf("Created person: %s, age %d\n", name, age)
		}(p.name, p.age)
	}

	wg.Wait()
	fmt.Println("\nAll concurrent transactions completed!")

	return nil
}

func errorHandlingExample(ctx context.Context) error {
	fmt.Println("\n=== Error Handling Example ===\n")

	db, err := gql.Open("quic:127.0.0.1:3141?skip_verify=true")
	if err != nil {
		return err
	}
	defer db.Close()

	conn, err := db.Connect(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()

	if err := conn.Begin(ctx); err != nil {
		return err
	}

	// This will succeed
	_, _, err = conn.Query(ctx, "CREATE (p:Person {name: 'Grace', age: 27})", nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("Created person: Grace")

	// Create a savepoint before risky operation
	sp, err := conn.Savepoint(ctx, "before_risky_op")
	if err != nil {
		conn.Rollback(ctx)
		return err
	}

	// Try a risky operation
	_, _, err = conn.Query(ctx, "CREATE (INVALID SYNTAX", nil, 1000)
	if err != nil {
		fmt.Printf("Caught error in risky operation: %v\n", err)
		// Rollback to savepoint, keeping Grace
		if err := conn.RollbackTo(ctx, sp); err != nil {
			conn.Rollback(ctx)
			return err
		}
		fmt.Println("Rolled back risky operation, Grace is still there")
	}

	// Continue with valid operations
	_, _, err = conn.Query(ctx, "CREATE (p:Person {name: 'Henry', age: 29})", nil, 1000)
	if err != nil {
		conn.Rollback(ctx)
		return err
	}
	fmt.Println("Created person: Henry")

	// Commit the transaction
	if err := conn.Commit(ctx); err != nil {
		return err
	}
	fmt.Println("\nTransaction committed (Grace and Henry created)\n")

	return nil
}

func main() {
	ctx := context.Background()

	fmt.Println("Geode Go Client - Transaction Examples")
	fmt.Println("========================================\n")

	if err := basicTransactionExample(ctx); err != nil {
		log.Fatalf("Basic transaction example failed: %v", err)
	}

	if err := savepointExample(ctx); err != nil {
		log.Fatalf("Savepoint example failed: %v", err)
	}

	if err := nestedSavepointsExample(ctx); err != nil {
		log.Fatalf("Nested savepoints example failed: %v", err)
	}

	if err := poolWithTransactionsExample(ctx); err != nil {
		log.Fatalf("Pool example failed: %v", err)
	}

	if err := errorHandlingExample(ctx); err != nil {
		log.Fatalf("Error handling example failed: %v", err)
	}

	fmt.Println("\n✅ All transaction examples completed successfully!")
}
