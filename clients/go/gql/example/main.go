package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"time"

	gql "geode/clients/go/gql"
)

func main() {
	var (
		mode    = flag.String("mode", "process", "Connection mode: process or quic")
		server  = flag.String("server", "127.0.0.1:7567", "Server address for quic mode")
		query   = flag.String("query", "RETURN 1 AS x ORDER BY x LIMIT 1", "GQL query to execute")
		verbose = flag.Bool("v", false, "Verbose output")
	)
	flag.Parse()

	// Build DSN based on mode
	var dsn string
	switch *mode {
	case "quic":
		dsn = fmt.Sprintf("quic://%s?page_size=100", *server)
	default:
		dsn = "process:./zig-out/bin/geode?page_size=100"
	}

	if *verbose {
		log.Printf("Connecting with DSN: %s", dsn)
	}

	// Open database connection
	db, err := gql.Open(dsn)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}

	// Connect with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	conn, err := db.Connect(ctx)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}
	defer conn.Close()

	if *verbose {
		log.Printf("Connected successfully via %s", *mode)
	}

	// Execute query
	start := time.Now()
	page, _, err := conn.Query(ctx, *query, nil, 100)
	if err != nil {
		log.Fatalf("Query failed: %v", err)
	}
	elapsed := time.Since(start)

	// Display results
	fmt.Printf("Query executed in %v\n", elapsed)
	fmt.Printf("Columns: %v\n", page.Columns)
	fmt.Printf("Ordered: %v\n", page.Ordered)
	if len(page.OrderKeys) > 0 {
		fmt.Printf("Order Keys: %v\n", page.OrderKeys)
	}
	fmt.Printf("Rows returned: %d\n", len(page.Rows))

	// Display first few rows
	for i, row := range page.Rows {
		if i >= 5 {
			fmt.Println("...")
			break
		}
		fmt.Printf("Row %d: ", i+1)
		for _, col := range page.Columns {
			val := row[col.Name]
			switch val.Kind {
			case gql.Int:
				fmt.Printf("%s=%d ", col.Name, val.Int)
			case gql.Str:
				fmt.Printf("%s=%q ", col.Name, val.Str)
			case gql.Bool:
				fmt.Printf("%s=%v ", col.Name, val.Bool)
			case gql.Null:
				fmt.Printf("%s=NULL ", col.Name)
			default:
				fmt.Printf("%s=? ", col.Name)
			}
		}
		fmt.Println()
	}
}
