package gql

import (
	"context"
	"os/exec"
	"testing"
	"time"
)

func TestGQL_TCP_OrderLimit(t *testing.T) {
	ensureServer(t)
	// Start geoded listening on tcp
	cmd := exec.Command("../../../zig-out/bin/geoded", "--listen-tcp", "127.0.0.1:7567")
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil { t.Fatalf("start tcp: %v", err) }
	t.Cleanup(func(){ _ = cmd.Process.Kill() })
	time.Sleep(200 * time.Millisecond)

	db, err := Open("tcp:127.0.0.1:7567?page_size=3")
	db.addr = "127.0.0.1:7567" // ensure tcp mode
	if err != nil { t.Fatalf("Open tcp err: %v", err) }
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := db.Connect(ctx)
	if err != nil { t.Fatalf("Connect tcp err: %v", err) }
	defer conn.Close()
	first, _, err := conn.Query(ctx, "RETURN 1 AS x ORDER BY x LIMIT 1", nil, 10)
	if err != nil { t.Fatalf("query err: %v", err) }
	if len(first.Rows) != 1 || first.Rows[0]["x"].Int != 1 { t.Fatalf("bad row: %v", first.Rows) }
}

func TestGQL_CancelDoesNotHang(t *testing.T) {
	c := withConn(t)
	ctx, cancel := context.WithCancel(context.Background())
	// Cancel immediately; read should not hang
	cancel()
	_, _, err := c.Query(ctx, "RETURN 1 AS x", nil, 10)
	if err == nil { t.Fatalf("expected cancel error") }
}
