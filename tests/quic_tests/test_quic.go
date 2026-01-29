package main

import (
	"context"
	"fmt"
	"log"
	"time"

	gql "./clients/go/gql"
)

func main() {
	// Connect to the running QUIC server
	dsn := "quic://127.0.0.1:3141"

	fmt.Printf("Connecting to %s...\n", dsn)

	db, err := gql.Open(dsn)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := db.Connect(ctx)
	if err != nil {
		log.Fatalf("Failed to connect: %v", err)
	}
	defer conn.Close()

	fmt.Println("✓ Successfully connected via QUIC!")

	// Try a simple query
	result, err := conn.Query(ctx, "RETURN 1 AS x")
	if err != nil {
		log.Fatalf("Failed to execute query: %v", err)
	}

	fmt.Printf("✓ Query executed successfully: %+v\n", result)
	fmt.Println("✓ Full handshake and 1-RTT communication verified!")
}
