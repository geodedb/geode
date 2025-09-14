package gql

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func ensureServer(t *testing.T) string {
	t.Helper()
	wd, _ := os.Getwd()
	root := filepath.Clean(filepath.Join(wd, "..", "..", ".."))
	path := filepath.Join(root, "zig-out", "bin", "geoded")
	if _, err := os.Stat(path); err == nil {
		return path
	}
	cmd := exec.Command("zig", "build")
	cmd.Dir = root
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("zig build failed: %v", err)
	}
	if _, err := os.Stat(path); err != nil { t.Fatalf("geoded not found after build: %v", err) }
	return path
}

func withConn(t *testing.T) *Conn {
	t.Helper()
	_ = ensureServer(t)
	db, err := Open("process:"+filepath.Join("..","..","..","zig-out","bin","geoded")+"?page_size=3")
	if err != nil { t.Fatalf("Open err: %v", err) }
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	conn, err := db.Connect(ctx)
	if err != nil { t.Fatalf("Connect err: %v", err) }
	t.Cleanup(func(){ _ = conn.Close() })
	return conn
}

func TestGQL_OrderLimit(t *testing.T) {
	c := withConn(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second); defer cancel()
	first, _, err := c.Query(ctx, "RETURN 1 AS x ORDER BY x LIMIT 1", nil, 10)
	if err != nil { t.Fatalf("query err: %v", err) }
	if len(first.Rows) != 1 { t.Fatalf("want 1 row, got %d", len(first.Rows)) }
	if first.Rows[0]["x"].Int != 1 { t.Fatalf("want x=1, got %v", first.Rows[0]["x"]) }
	if !first.Ordered { t.Fatalf("want ordered=true") }
	if len(first.OrderKeys) == 0 || first.OrderKeys[0] != "x" { t.Fatalf("want order_keys [x], got %v", first.OrderKeys) }
}

func TestGQL_UnorderedPaginationError(t *testing.T) {
	c := withConn(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second); defer cancel()
	_, _, err := c.Query(ctx, "RETURN 1 LIMIT 10 OFFSET 5", nil, 10)
	if err == nil { t.Fatalf("expected error for US001") }
	if got := err.Error(); !contains(got, "US001") { t.Fatalf("want error contains US001, got %q", got) }
}

func TestGQL_IllegalOrderKey(t *testing.T) {
	c := withConn(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second); defer cancel()
	_, _, err := c.Query(ctx, "RETURN a ORDER BY f(a)", nil, 10)
	if err == nil { t.Fatalf("expected error for IllegalOrderKey") }
	if got := err.Error(); !contains(got, "IllegalOrderKey") { t.Fatalf("want error contains IllegalOrderKey, got %q", got) }
}

func TestGQL_SetDistinct(t *testing.T) {
	c := withConn(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second); defer cancel()
	first, _, err := c.Query(ctx, "RETURN 1 AS x UNION RETURN 1 AS x", nil, 10)
	if err != nil { t.Fatalf("query err: %v", err) }
	if len(first.Rows) != 1 { t.Fatalf("want 1 row, got %d", len(first.Rows)) }
	if first.Rows[0]["x"].Int != 1 { t.Fatalf("want x=1, got %v", first.Rows[0]["x"]) }
	if first.Ordered { t.Fatalf("want ordered=false for DISTINCT union, got true") }
}

func TestGQL_CaseParams(t *testing.T) {
	c := withConn(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second); defer cancel()
	params := map[string]any{"a": []any{nil, true, false}}
	first, _, err := c.Query(ctx, "RETURN CASE WHEN a IS NULL THEN 'n' WHEN a THEN 't' ELSE 'f' END AS r", params, 10)
	if err != nil { t.Fatalf("query err: %v", err) }
	seen := map[string]bool{}
	for _, r := range first.Rows { seen[r["r"].Str] = true }
	if !(seen["n"] && seen["t"] && seen["f"]) { t.Fatalf("want rows n,t,f; got %v", seen) }
}

func contains(s, sub string) bool { return len(sub) == 0 || (len(s) >= len(sub) && (s == sub || (func() bool { return strings.Contains(s, sub) })())) }
