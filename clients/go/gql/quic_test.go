package gql

import (
	"context"
	"testing"
	"time"
)

func TestQUICHandshake(t *testing.T) {
	// This test assumes a server is running on 127.0.0.1:3141
	dsn := "quic://127.0.0.1:3141"

	t.Logf("Connecting to %s...", dsn)

	db, err := Open(dsn)
	if err != nil {
		t.Fatalf("Failed to open database: %v", err)
	}
	defer db.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn, err := db.Connect(ctx)
	if err != nil {
		t.Fatalf("Failed to connect: %v", err)
	}
	defer conn.Close()

	t.Log("✓ Successfully connected via QUIC!")

	// Try a simple query to verify 1-RTT data transfer
	result, _, err := conn.Query(ctx, "RETURN 1 AS x", nil, 100)
	if err != nil {
		t.Fatalf("Failed to execute query: %v", err)
	}

	t.Logf("✓ Query executed successfully: %+v", result)
	t.Log("✓ Full handshake and 1-RTT communication verified!")
}