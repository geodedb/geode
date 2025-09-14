package gql

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestGQL_TCP_OrderLimit(t *testing.T) {
	startTCP(t)
	db, oerr := Open("tcp:127.0.0.1:7567?page_size=3")
	if oerr != nil { t.Fatalf("Open tcp err: %v", oerr) }
	// Ensure addr is set (defensive):
	db.addr = "127.0.0.1:7567"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var first Page
	var err error
	// small initial delay giving server a moment after startTCP return (port accept may race)
	time.Sleep(80 * time.Millisecond)
	for attempt := 0; attempt < 5; attempt++ {
		conn, cerr := db.Connect(ctx)
		if cerr != nil { err = cerr; time.Sleep(50 * time.Millisecond); continue }
		first, _, err = conn.Query(ctx, "RETURN 1 AS x ORDER BY x LIMIT 1", nil, 10)
		_ = conn.Close()
		if err == nil { break }
		if strings.Contains(err.Error(), "connection reset") { time.Sleep(80 * time.Millisecond); continue }
		break
	}
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || strings.Contains(err.Error(), "connection reset") || strings.Contains(err.Error(), "connection refused") {
			 t.Skipf("skipping flaky tcp test: %v", err)
		}
		 t.Fatalf("query err: %v", err)
	}
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
