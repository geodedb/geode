package gql

import (
	"context"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func ensureServer(t *testing.T) string {
	t.Helper()
	wd, _ := os.Getwd()
	root := filepath.Clean(filepath.Join(wd, "..", "..", ".."))
	
	// Add .exe extension on Windows
	serverName := "geoded"
	if runtime.GOOS == "windows" {
		serverName = "geoded.exe"
	}
	
	path := filepath.Join(root, "zig-out", "bin", serverName)
	if _, err := os.Stat(path); err == nil {
		return path
	}
	
	// In CI, if the server doesn't exist, skip the test rather than trying to build
	if os.Getenv("CI") != "" {
		t.Skipf("Server binary not found at %s, skipping test in CI", path)
		return ""
	}
	
	cmd := exec.Command("zig", "build")
	cmd.Dir = root
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		t.Skipf("zig build failed: %v, skipping test", err)
		return ""
	}
	if _, err := os.Stat(path); err != nil {
		t.Skipf("geoded not found after build: %v, skipping test", err)
		return ""
	}
	return path
}

// startTCP launches a geoded in TCP mode on the default port (127.0.0.1:7567) for the duration of the test.
// It waits until the port is accepting connections or fails the test after timeout.
func startTCP(t *testing.T) string {
	t.Helper()
	serverPath := ensureServer(t)
	// Kill any existing server on the port (could be QUIC or TCP from previous test)
	// On Windows, use taskkill instead of pkill
	if runtime.GOOS == "windows" {
		exec.Command("taskkill", "/F", "/IM", "geoded.exe").Run()
	} else {
		exec.Command("pkill", "-f", "geoded.*7567").Run()
	}
	time.Sleep(100 * time.Millisecond)
	
	cmd := exec.Command(serverPath, "--listen-tcp", "127.0.0.1:7567")
	if err := cmd.Start(); err != nil { t.Fatalf("start tcp server: %v", err) }
	// Wait readiness
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if c2, err := net.DialTimeout("tcp", "127.0.0.1:7567", 100*time.Millisecond); err == nil { _ = c2.Close(); break }
		time.Sleep(50 * time.Millisecond)
	}
	t.Cleanup(func(){ _ = cmd.Process.Kill() })
	return "127.0.0.1:7567"
}

func withConn(t *testing.T) *Conn {
	t.Helper()
	serverPath := ensureServer(t)
	db, err := Open("process:"+serverPath+"?page_size=3")
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

// startQUIC launches a geoded in QUIC mode on the default port (127.0.0.1:7567) for the duration of the test.
func startQUIC(t *testing.T) string {
	t.Helper()
	serverPath := ensureServer(t)
	if serverPath == "" {
		// Server not available, test was skipped
		return ""
	}
	// Check if already listening on QUIC
	cmd := exec.Command(serverPath, "--listen-quic", "127.0.0.1:7567")
	if err := cmd.Start(); err != nil { t.Fatalf("start quic server: %v", err) }
	// Wait for server to be ready
	time.Sleep(500 * time.Millisecond)
	t.Cleanup(func(){ _ = cmd.Process.Kill() })
	return "127.0.0.1:7567"
}

func TestGQL_QUIC_OrderLimit(t *testing.T) {
	if testing.Short() || os.Getenv("CI") != "" {
		t.Skip("Skipping QUIC test in CI/short mode")
	}
	addr := startQUIC(t)
	db, err := Open("quic://" + addr + "?page_size=3")
	if err != nil { t.Fatalf("Open err: %v", err) }
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := db.Connect(ctx)
	if err != nil { t.Fatalf("Connect err: %v", err) }
	defer conn.Close()
	
	first, _, err := conn.Query(ctx, "RETURN 1 AS x ORDER BY x LIMIT 1", nil, 10)
	if err != nil { t.Fatalf("query err: %v", err) }
	if len(first.Rows) != 1 { t.Fatalf("want 1 row, got %d", len(first.Rows)) }
	if first.Rows[0]["x"].Int != 1 { t.Fatalf("want x=1, got %v", first.Rows[0]["x"]) }
	if !first.Ordered { t.Fatalf("want ordered=true") }
	if len(first.OrderKeys) == 0 || first.OrderKeys[0] != "x" { t.Fatalf("want order_keys [x], got %v", first.OrderKeys) }
}

func TestGQL_TCP_OrderLimit(t *testing.T) {
	if testing.Short() || os.Getenv("CI") != "" {
		t.Skip("Skipping TCP test in CI/short mode")
	}
	addr := startTCP(t)
	db, err := Open("tcp://" + addr + "?page_size=3")
	if err != nil { t.Fatalf("Open err: %v", err) }
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := db.Connect(ctx)
	if err != nil { t.Fatalf("Connect err: %v", err) }
	defer conn.Close()
	
	first, _, err := conn.Query(ctx, "RETURN 1 AS x ORDER BY x LIMIT 1", nil, 10)
	if err != nil { t.Fatalf("query err: %v", err) }
	if len(first.Rows) != 1 { t.Fatalf("want 1 row, got %d", len(first.Rows)) }
	if first.Rows[0]["x"].Int != 1 { t.Fatalf("want x=1, got %v", first.Rows[0]["x"]) }
	if !first.Ordered { t.Fatalf("want ordered=true") }
	if len(first.OrderKeys) == 0 || first.OrderKeys[0] != "x" { t.Fatalf("want order_keys [x], got %v", first.OrderKeys) }
}
