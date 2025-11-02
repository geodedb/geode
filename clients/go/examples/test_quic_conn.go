package main

import (
	"database/sql"
	"fmt"
	"os"
	"time"

	_ "geode/clients/go/geode"
)

func main() {
	// Test QUIC connection to our server
	dsn := "quic:localhost:56794?tls=skip"

	fmt.Println("Testing Go client with quic-go...")
	fmt.Printf("DSN: %s\n", dsn)

	start := time.Now()
	db, err := sql.Open("geode", dsn)
	if err != nil {
		fmt.Fprintf(os.Stderr, "❌ Failed to open connection: %v\n", err)
		os.Exit(1)
	}
	defer db.Close()

	fmt.Printf("✅ Connection established (%v)\n", time.Since(start))

	// Test simple query
	fmt.Println("\nExecuting: RETURN 1 AS x")
	rows, err := db.Query("RETURN 1 AS x")
	if err != nil {
		fmt.Fprintf(os.Stderr, "❌ Query failed: %v\n", err)
		os.Exit(1)
	}
	defer rows.Close()

	fmt.Println("✅ Query executed successfully")

	// Read results
	for rows.Next() {
		var x int
		if err := rows.Scan(&x); err != nil {
			fmt.Fprintf(os.Stderr, "❌ Scan failed: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("✅ Result: x = %d\n", x)
	}

	if err := rows.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "❌ Rows error: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("\n✅ TEST PASSED - Go client with quic-go works!")
}
