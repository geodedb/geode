package gql

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	quic "github.com/quic-go/quic-go"
)

// Value is a native representation of Geode values, including DECIMAL and advanced types.
type Value struct {
	Kind     Kind
	Int      int64
	Bool     bool
	Str      string
	Dec      *big.Rat
	DecScale string
	Arr      []Value
	Obj      map[string]Value
	Bytes    []byte    // BYTEA
	Time     time.Time // temporal decoded when applicable
	Range    *Range    // RANGE
}

type Range struct {
	Lower  *Value
	Upper  *Value
	Bounds string
}

type Kind int

const (
	Null Kind = iota
	Int
	Bool
	Str
	Dec
	Array
	Object
	Bytea
	Date
	TimeOnly
	TimeTZ
	Timestamp
	TimestampTZ
	Interval
	Json
	Jsonb
	Xml
	Url
	Domain
	UUID
	Enum
	BitString
	RangeKind
)

type Column struct {
	Name string
	Type string
}

type Page struct {
	Columns   []Column
	Rows      []map[string]Value
	Ordered   bool
	OrderKeys []string
	Final     bool
}

type DB struct {
	path       string
	addr       string
	pageSize   int
	helloName  string
	helloVer   string
	conf       string
	caPath     string
	clientCert string
	clientKey  string
	skipVerify bool
}

func Open(dsn string) (*DB, error) {
	cfg := parseDSN(dsn)
	return &DB{path: cfg.Path, addr: cfg.Addr, pageSize: cfg.PageSize, helloName: cfg.HelloName, helloVer: cfg.HelloVer, conf: cfg.Conformance, caPath: cfg.CACertPath, clientCert: cfg.ClientCertPath, clientKey: cfg.ClientKeyPath, skipVerify: cfg.SkipVerify}, nil
}

type dsnConfig struct {
	Mode           string // process or quic
	Path           string // process path
	Addr           string // quic address
	PageSize       int
	HelloName      string
	HelloVer       string
	Conformance    string
	UseQUIC        bool
	CACertPath     string
	ClientCertPath string
	ClientKeyPath  string
	SkipVerify     bool
}

func parseDSN(dsn string) dsnConfig {
	// Default path depends on OS
	defaultPath := "./zig-out/bin/geode"
	if runtime.GOOS == "windows" {
		defaultPath = "./zig-out/bin/geode.exe"
	}

	cfg := dsnConfig{Mode: "process", Path: defaultPath, PageSize: 1000, HelloName: "gql-go", HelloVer: "0.1", Conformance: "min", UseQUIC: false}
	if dsn == "" {
		if p := os.Getenv("GEODE_SERVER_PATH"); p != "" {
			cfg.Path = p
		}
		return cfg
	}
	if strings.HasPrefix(dsn, "process:") {
		rest := strings.TrimPrefix(dsn, "process:")
		q := ""
		if i := strings.Index(rest, "?"); i >= 0 {
			cfg.Path = rest[:i]
			q = rest[i+1:]
		} else {
			cfg.Path = rest
		}
		if q != "" {
			for _, kv := range strings.Split(q, "&") {
				if kv == "" {
					continue
				}
				p := strings.SplitN(kv, "=", 2)
				k := p[0]
				v := ""
				if len(p) == 2 {
					v = p[1]
				}
				switch k {
				case "page_size":
					if n, err := strconv.Atoi(v); err == nil && n > 0 {
						cfg.PageSize = n
					}
				case "hello_name":
					if v != "" {
						cfg.HelloName = v
					}
				case "hello_ver":
					if v != "" {
						cfg.HelloVer = v
					}
				case "conformance":
					if v != "" {
						cfg.Conformance = v
					}
				}
			}
		}
		return cfg
	}
	// tcp: DSNs are no longer supported
	if strings.HasPrefix(dsn, "quic:") {
		cfg.Mode = "quic"
		cfg.UseQUIC = true
		rest := strings.TrimPrefix(dsn, "quic:")
		q := ""
		if i := strings.Index(rest, "?"); i >= 0 {
			cfg.Addr = rest[:i]
			q = rest[i+1:]
		} else {
			cfg.Addr = rest
		}
		if cfg.Addr == "" {
			cfg.Addr = "127.0.0.1:8443"
		}
		if q != "" {
			for _, kv := range strings.Split(q, "&") {
				if kv == "" {
					continue
				}
				p := strings.SplitN(kv, "=", 2)
				k := p[0]
				v := ""
				if len(p) == 2 {
					v = p[1]
				}
				switch k {
				case "page_size":
					if n, err := strconv.Atoi(v); err == nil && n > 0 {
						cfg.PageSize = n
					}
				case "hello_name":
					if v != "" {
						cfg.HelloName = v
					}
				case "hello_ver":
					if v != "" {
						cfg.HelloVer = v
					}
				case "conformance":
					if v != "" {
						cfg.Conformance = v
					}
				case "ca_cert":
					cfg.CACertPath = v
				case "client_cert":
					cfg.ClientCertPath = v
				case "client_key":
					cfg.ClientKeyPath = v
				case "skip_verify", "tls_insecure_skip_verify":
					cfg.SkipVerify = (v == "1" || strings.EqualFold(v, "true"))
				}
			}
		}
		return cfg
	}
	return cfg
}

// Conn is a single session to geoded. Not concurrency-safe for Query calls.
type Conn struct {
	cmd     *exec.Cmd
	inW     io.WriteCloser
	outR    io.ReadCloser
	bufRd   *bufio.Reader
	nc      net.Conn
	qConn   interface{} // quic.Connection or quic.EarlyConnection
	qStream interface{} // *quic.Stream (pointer to avoid copy)
	cancel  func()
	useQUIC bool
}

func (db *DB) Close() error {
	// Nothing to close for DB itself
	return nil
}

func (db *DB) Connect(ctx context.Context) (*Conn, error) {
	if db.path == "" && db.addr == "" {
		return nil, fmt.Errorf("invalid config")
	}

	// Check if QUIC mode is requested
	if strings.HasPrefix(db.addr, "quic:") {
		// Parse the address for QUIC
		addr := strings.TrimPrefix(db.addr, "quic:")
		addr = strings.TrimPrefix(addr, "//")
		if addr == "" {
			addr = "127.0.0.1:8443"
		} // v0.18.0: Default QUIC port

		tlsConf := &tls.Config{
			InsecureSkipVerify: db.skipVerify || db.caPath == "",
			NextProtos:         []string{"geode/1"},
			MinVersion:         tls.VersionTLS13,
		}
		if db.caPath != "" {
			pool, err := loadRootCA(db.caPath)
			if err != nil {
				return nil, fmt.Errorf("failed to load CA cert: %w", err)
			}
			tlsConf.RootCAs = pool
			host, _, _ := net.SplitHostPort(addr)
			if host != "" {
				tlsConf.ServerName = host
			}
		}
		if db.clientCert != "" || db.clientKey != "" {
			if db.clientCert == "" || db.clientKey == "" {
				return nil, fmt.Errorf("mTLS requires both client_cert and client_key")
			}
			pair, err := tls.LoadX509KeyPair(db.clientCert, db.clientKey)
			if err != nil {
				return nil, fmt.Errorf("failed to load client cert/key: %w", err)
			}
			tlsConf.Certificates = []tls.Certificate{pair}
		}

		// Use QUIC config with keep-alive and proper timeouts
		qConfig := &quic.Config{
			MaxIdleTimeout:        30 * time.Second,
			KeepAlivePeriod:       10 * time.Second,
			HandshakeIdleTimeout:  10 * time.Second,
			MaxIncomingStreams:    100,
			MaxIncomingUniStreams: 100,
			Versions:              []quic.Version{quic.Version1}, // Force QUIC v1
		}
		
		fmt.Printf("DEBUG: Go client attempting to connect via QUIC to %s\n", addr)
		qConn, err := quic.DialAddr(ctx, addr, tlsConf, qConfig)
		if err != nil {
			fmt.Printf("DEBUG: Go client QUIC connection failed: %v\n", err)
			return nil, err
		}
		fmt.Printf("DEBUG: Go client QUIC connection established\n")
		
		// Wait a moment for handshake to stabilize
		select {
		case <-ctx.Done():
			_ = qConn.CloseWithError(0, "context cancelled")
			return nil, ctx.Err()
		case <-time.After(100 * time.Millisecond):
			// Continue after brief delay
		}

		qStream, err := qConn.OpenStreamSync(ctx)
		if err != nil {
			_ = qConn.CloseWithError(0, "failed to open stream")
			return nil, err
		}

		c := &Conn{
			qConn:   qConn,
			qStream: &qStream, // Store pointer to avoid copy
			bufRd:   bufio.NewReaderSize(qStream, 64<<10),
			useQUIC: true,
		}
		c.cancel = func() {
			if stream := c.qStream; stream != nil {
				if s, ok := stream.(*quic.Stream); ok {
					_ = (*s).Close()
				}
			}
			if conn := c.qConn; conn != nil {
				if qc, ok := conn.(interface {
					CloseWithError(quic.ApplicationErrorCode, string) error
				}); ok {
					_ = qc.CloseWithError(0, "closing")
				}
			}
		}
		hello := map[string]any{"type": "HELLO", "client_name": db.helloName, "client_ver": db.helloVer, "wanted_conformance": db.conf}
		if err := c.writeJSON(hello); err != nil {
			_ = c.Close()
			return nil, err
		}
		// Read and discard HELLO response
		if _, err := c.readLine(ctx); err != nil {
			_ = c.Close()
			return nil, err
		}
		return c, nil
	}

	if db.addr != "" {
		// Network mode is QUIC-only
		addr := db.addr
		addr = strings.TrimPrefix(addr, "quic://")
		addr = strings.TrimPrefix(addr, "quic:")
		addr = strings.TrimPrefix(addr, "//")
		if addr == "" {
			addr = "127.0.0.1:8443"
		} // v0.18.0: Default QUIC port
		tlsConf := &tls.Config{InsecureSkipVerify: db.skipVerify || db.caPath == "", NextProtos: []string{"geode/1"}, MinVersion: tls.VersionTLS13}
		if db.caPath != "" {
			pool, err := loadRootCA(db.caPath)
			if err != nil {
				return nil, fmt.Errorf("failed to load CA cert: %w", err)
			}
			tlsConf.RootCAs = pool
			host, _, _ := net.SplitHostPort(addr)
			if host != "" {
				tlsConf.ServerName = host
			}
		}
		if db.clientCert != "" || db.clientKey != "" {
			if db.clientCert == "" || db.clientKey == "" {
				return nil, fmt.Errorf("mTLS requires both client_cert and client_key")
			}
			pair, err := tls.LoadX509KeyPair(db.clientCert, db.clientKey)
			if err != nil {
				return nil, fmt.Errorf("failed to load client cert/key: %w", err)
			}
			tlsConf.Certificates = []tls.Certificate{pair}
		}
		
		// Use QUIC config with keep-alive and proper timeouts
		qConfig := &quic.Config{
			MaxIdleTimeout:        30 * time.Second,
			KeepAlivePeriod:       10 * time.Second,
			HandshakeIdleTimeout:  10 * time.Second,
			MaxIncomingStreams:    100,
			MaxIncomingUniStreams: 100,
			Versions:              []quic.Version{quic.Version1}, // Force QUIC v1
		}
		
		fmt.Printf("DEBUG: Go client attempting to connect via QUIC to %s\n", addr)
		qConn, err := quic.DialAddr(ctx, addr, tlsConf, qConfig)
		if err != nil {
			fmt.Printf("DEBUG: Go client QUIC connection failed: %v\n", err)
			return nil, err
		}
		fmt.Printf("DEBUG: Go client QUIC connection established\n")
		
		// Wait a moment for handshake to stabilize
		select {
		case <-ctx.Done():
			_ = qConn.CloseWithError(0, "context cancelled")
			return nil, ctx.Err()
		case <-time.After(100 * time.Millisecond):
			// Continue after brief delay
		}
		
		qStream, err := qConn.OpenStreamSync(ctx)
		if err != nil {
			_ = qConn.CloseWithError(0, "failed to open stream")
			return nil, err
		}
		c := &Conn{qConn: qConn, qStream: &qStream, bufRd: bufio.NewReaderSize(qStream, 64<<10), useQUIC: true}
		c.cancel = func() {
			if s, ok := c.qStream.(*quic.Stream); ok {
				_ = (*s).Close()
			}
			if qc, ok := c.qConn.(interface {
				CloseWithError(quic.ApplicationErrorCode, string) error
			}); ok {
				_ = qc.CloseWithError(0, "closing")
			}
		}
		hello := map[string]any{"type": "HELLO", "client_name": db.helloName, "client_ver": db.helloVer, "wanted_conformance": db.conf}
		if err := c.writeJSON(hello); err != nil {
			_ = c.Close()
			return nil, err
		}
		if _, err := c.readLine(ctx); err != nil {
			_ = c.Close()
			return nil, err
		}
		return c, nil
	}
	// process mode
	path := db.path
	if !filepath.IsAbs(path) {
		if wd, _ := os.Getwd(); wd != "" {
			path = filepath.Join(wd, path)
		}
	}

	// Check if the executable exists, and if not, try to build it
	if _, err := os.Stat(path); os.IsNotExist(err) {
		// Try to build the server if it doesn't exist
		buildCmd := exec.Command("zig", "build")
		buildCmd.Dir = filepath.Dir(filepath.Dir(filepath.Dir(path))) // Go up to project root
		buildCmd.Stdout = os.Stderr
		buildCmd.Stderr = os.Stderr
		if buildErr := buildCmd.Run(); buildErr == nil {
			// Check again after build
			if _, err := os.Stat(path); os.IsNotExist(err) {
				return nil, fmt.Errorf("geode not found after build: %w", err)
			}
		} else {
			return nil, fmt.Errorf("geode not found and build failed: %w", err)
		}
	}

	// Start server in QUIC mode on a random port
	port := 8443 + (os.Getpid() % 1000) // Use a semi-random port
	addr := fmt.Sprintf("127.0.0.1:%d", port)

	cmd := exec.Command(path, "serve", "--listen", addr)
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	// Wait a bit for server to start
	time.Sleep(500 * time.Millisecond)

	// Now connect via QUIC to the spawned server
	tlsConf := &tls.Config{
		InsecureSkipVerify: true,
		NextProtos:         []string{"geode/1"},
		MinVersion:         tls.VersionTLS13,
	}

	// Use QUIC config with keep-alive and proper timeouts
	qConfig := &quic.Config{
		MaxIdleTimeout:        30 * time.Second,
		KeepAlivePeriod:       10 * time.Second,
		HandshakeIdleTimeout:  10 * time.Second,
		MaxIncomingStreams:    100,
		MaxIncomingUniStreams: 100,
	}

	fmt.Printf("DEBUG: Go client attempting to connect to spawned server at %s\n", addr)
	qConn, err := quic.DialAddr(ctx, addr, tlsConf, qConfig)
	if err != nil {
		fmt.Printf("DEBUG: Go client connection to spawned server failed: %v\n", err)
		_ = cmd.Process.Kill()
		return nil, err
	}
	fmt.Printf("DEBUG: Go client connected to spawned server\n")
	
	// Wait a moment for handshake to stabilize
	select {
	case <-ctx.Done():
		_ = qConn.CloseWithError(0, "context cancelled")
		_ = cmd.Process.Kill()
		return nil, ctx.Err()
	case <-time.After(100 * time.Millisecond):
		// Continue after brief delay
	}

	qStream, err := qConn.OpenStreamSync(ctx)
	if err != nil {
		_ = qConn.CloseWithError(0, "failed to open stream")
		_ = cmd.Process.Kill()
		return nil, err
	}

	c := &Conn{
		cmd:     cmd,
		qConn:   qConn,
		qStream: &qStream,
		bufRd:   bufio.NewReaderSize(qStream, 64<<10),
		useQUIC: true,
	}
	c.cancel = func() {
		if stream := c.qStream; stream != nil {
			if s, ok := stream.(*quic.Stream); ok {
				_ = (*s).Close()
			}
		}
		if conn := c.qConn; conn != nil {
			if qc, ok := conn.(interface {
				CloseWithError(quic.ApplicationErrorCode, string) error
			}); ok {
				_ = qc.CloseWithError(0, "closing")
			}
		}
		_ = cmd.Process.Kill()
	}

	hello := map[string]any{"type": "HELLO", "client_name": db.helloName, "client_ver": db.helloVer, "wanted_conformance": db.conf}
	if err := c.writeJSON(hello); err != nil {
		_ = c.Close()
		return nil, err
	}

	// Read HELLO response
	if _, err := c.readLine(ctx); err != nil {
		_ = c.Close()
		return nil, err
	}

	return c, nil
}

func (c *Conn) Close() error {
	if c.useQUIC {
		if stream := c.qStream; stream != nil {
			if s, ok := stream.(*quic.Stream); ok {
				_ = (*s).Close()
			}
		}
		if conn := c.qConn; conn != nil {
			if qc, ok := conn.(interface {
				CloseWithError(quic.ApplicationErrorCode, string) error
			}); ok {
				_ = qc.CloseWithError(0, "closing")
			}
		}
		// Kill the process if we spawned it
		if c.cmd != nil {
			_ = c.cmd.Process.Kill()
			_ = c.cmd.Wait()
		}
		return nil
	}
	if c.nc != nil {
		// Attempt a small read-ahead with short deadline to ensure server flushed
		_ = c.nc.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
		buf := make([]byte, 256)
		for i := 0; i < 2; i++ { // bounded retries
			if c.nc == nil {
				break
			}
			if _, err := c.nc.Read(buf); err != nil {
				break
			}
		}
		_ = c.nc.Close()
		return nil
	}
	// Should not reach here anymore
	return nil
}

func (c *Conn) writeJSON(v any) error {
	b, e := json.Marshal(v)
	if e != nil {
		return e
	}
	b = append(b, '\n')
	if c.useQUIC {
		if stream := c.qStream; stream != nil {
			if s, ok := stream.(*quic.Stream); ok {
				_, e = (*s).Write(b)
				return e
			}
		}
		return fmt.Errorf("invalid QUIC stream")
	}
	if c.nc != nil {
		_, e = c.nc.Write(b)
		return e
	}
	return fmt.Errorf("no connection available")
}

func (c *Conn) readLine(ctx context.Context) ([]byte, error) {
	ch := make(chan struct {
		line []byte
		err  error
	}, 1)
	go func() {
		line, err := c.bufRd.ReadBytes('\n')
		if err == nil {
			if n := len(line); n > 0 && line[n-1] == '\n' {
				line = line[:n-1]
			}
		}
		ch <- struct {
			line []byte
			err  error
		}{line, err}
	}()
	select {
	case <-ctx.Done():
		if c.cancel != nil {
			c.cancel()
		}
		return nil, ctx.Err()
	case r := <-ch:
		return r.line, r.err
	}
}

func (c *Conn) readJSON(ctx context.Context) (map[string]any, error) {
	line, err := c.readLine(ctx)
	if err != nil {
		return nil, err
	}
	var result map[string]any
	if err := json.Unmarshal(line, &result); err != nil {
		return nil, fmt.Errorf("failed to parse JSON response: %w", err)
	}
	return result, nil
}

// Transactions
func (c *Conn) Begin(ctx context.Context) error {
	if err := c.writeJSON(map[string]any{"type": "BEGIN"}); err != nil {
		return err
	}
	_, err := c.readLine(ctx)
	return err
}
func (c *Conn) Commit(ctx context.Context) error {
	if err := c.writeJSON(map[string]any{"type": "COMMIT"}); err != nil {
		return err
	}
	_, err := c.readLine(ctx)
	return err
}
func (c *Conn) Rollback(ctx context.Context) error {
	if err := c.writeJSON(map[string]any{"type": "ROLLBACK"}); err != nil {
		return err
	}
	_, err := c.readLine(ctx)
	return err
}

// Query submits a GQL program and returns the first page and a pager function to pull more.
func (c *Conn) Query(ctx context.Context, text string, params map[string]any, pageSize int) (Page, func(context.Context) (Page, error), error) {
	if pageSize <= 0 {
		pageSize = 1000
	}
	run := map[string]any{"type": "RUN_GQL", "text": text}
	if len(params) > 0 {
		run["params"] = params
	}
	if err := c.writeJSON(run); err != nil {
		return Page{}, nil, err
	}
	l1, err := c.readLine(ctx)
	if err != nil {
		return Page{}, nil, err
	}
	var fr frame
	if err := json.Unmarshal(l1, &fr); err != nil {
		return Page{}, nil, fmt.Errorf("unmarshal error: %v, raw: %s", err, string(l1))
	}
	if fr.Result.Type == "ERROR" {
		return Page{}, nil, fmt.Errorf("%s: %s", fr.Result.Code, fr.Result.Message)
	}
	if fr.Result.Type != "SCHEMA" {
		return Page{}, nil, fmt.Errorf("unexpected: %s (raw: %s)", fr.Result.Type, string(l1))
	}
	cols := make([]Column, len(fr.Result.Columns))
	types := make(map[string]string, len(fr.Result.Columns))
	for i, cdef := range fr.Result.Columns {
		cols[i] = Column{Name: cdef.Name, Type: cdef.Type}
		types[cdef.Name] = cdef.Type
	}
	if err := c.writeJSON(map[string]any{"type": "PULL", "request_id": 1, "page_size": pageSize}); err != nil {
		return Page{}, nil, err
	}
	l2, err := c.readLine(ctx)
	if err != nil {
		return Page{}, nil, err
	}
	var b frame
	if err := json.Unmarshal(l2, &b); err != nil {
		return Page{}, nil, err
	}
	if b.Result.Type == "PROFILE" { // empty result set when profiling
		p := Page{Columns: cols, Rows: []map[string]Value{}, Ordered: false, Final: true}
		return p, func(context.Context) (Page, error) { return Page{}, io.EOF }, nil
	}
	if b.Result.Type != "BINDINGS" {
		return Page{}, nil, fmt.Errorf("unexpected: %s", b.Result.Type)
	}
	first := Page{Columns: cols, Rows: toRowsTyped(b.Result.Rows, types), Ordered: b.Result.Ordered, OrderKeys: b.Result.OrderKeys, Final: b.Result.Final}
	pager := func(ctx context.Context) (Page, error) {
		if first.Final {
			return Page{}, io.EOF
		}
		if err := c.writeJSON(map[string]any{"type": "PULL", "request_id": 1, "page_size": pageSize}); err != nil {
			return Page{}, err
		}
		ln, err := c.readLine(ctx)
		if err != nil {
			return Page{}, err
		}
		var f frame
		if err := json.Unmarshal(ln, &f); err != nil {
			return Page{}, err
		}
		if f.Result.Type == "ERROR" {
			return Page{}, io.EOF
		}
		if f.Result.Type != "BINDINGS" {
			return Page{}, fmt.Errorf("expected BINDINGS, got %s", f.Result.Type)
		}
		p := Page{Columns: cols, Rows: toRowsTyped(f.Result.Rows, types), Ordered: f.Result.Ordered, OrderKeys: f.Result.OrderKeys, Final: f.Result.Final}
		if p.Final {
			first.Final = true
		}
		return p, nil
	}
	return first, pager, nil
}

func toRowsTyped(in []map[string]json.RawMessage, types map[string]string) []map[string]Value {
	out := make([]map[string]Value, len(in))
	for i, r := range in {
		row := make(map[string]Value, len(r))
		for k, raw := range r {
			row[k] = decodeValue(raw, types[k])
		}
		out[i] = row
	}
	return out
}

func decimalScaleOf(s string) string {
	if i := strings.IndexByte(s, '.'); i >= 0 {
		return s[i+1:]
	}
	return ""
}

func decodeValue(raw json.RawMessage, typ string) Value {
	if string(raw) == "null" {
		return Value{Kind: Null}
	}
	switch typ {
	case "INT":
		var n json.Number
		if err := json.Unmarshal(raw, &n); err == nil {
			if i, e := n.Int64(); e == nil {
				return Value{Kind: Int, Int: i}
			}
		}
		if i, e := strconv.ParseInt(string(raw), 10, 64); e == nil {
			return Value{Kind: Int, Int: i}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "DECIMAL":
		s := strings.Trim(string(raw), "\"")
		r := new(big.Rat)
		if _, ok := r.SetString(s); ok {
			return Value{Kind: Dec, Dec: r, DecScale: decimalScaleOf(s)}
		}
		return Value{Kind: Str, Str: s}
	case "BOOL":
		var b bool
		if err := json.Unmarshal(raw, &b); err == nil {
			return Value{Kind: Bool, Bool: b}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "STRING":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: Str, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "BYTEA":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			if strings.HasPrefix(s, "\\x") {
				if b, err := hexToBytes(s[2:]); err == nil {
					return Value{Kind: Bytea, Bytes: b, Str: s}
				}
			}
			return Value{Kind: Bytea, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "JSON":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: Json, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "JSONB":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: Jsonb, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "XML":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: Xml, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "URL", "URI":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: Url, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "DOMAIN":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: Domain, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "UUID":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: UUID, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "ENUM":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: Enum, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "BIT", "VARBIT":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: BitString, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "DATE":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			if t, e := time.Parse("2006-01-02", s); e == nil {
				return Value{Kind: Date, Str: s, Time: t}
			}
			return Value{Kind: Date, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "TIMESTAMP":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			if t, e := time.Parse(time.RFC3339, s); e == nil {
				return Value{Kind: Timestamp, Str: s, Time: t}
			}
			return Value{Kind: Timestamp, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "TIMESTAMPTZ":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			if t, e := time.Parse(time.RFC3339, s); e == nil {
				return Value{Kind: TimestampTZ, Str: s, Time: t}
			}
			return Value{Kind: TimestampTZ, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "TIME":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: TimeOnly, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "TIMETZ":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: TimeTZ, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	case "INTERVAL":
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: Interval, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	}
	if strings.HasPrefix(strings.ToUpper(typ), "RANGE") || strings.HasPrefix(typ, "Range") {
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(raw, &obj); err == nil {
			r := &Range{Bounds: ""}
			if b, ok := obj["bounds"]; ok {
				_ = json.Unmarshal(b, &r.Bounds)
			}
			if lo, ok := obj["lower"]; ok {
				v := decodeValue(lo, "")
				r.Lower = &v
			}
			if up, ok := obj["upper"]; ok {
				v := decodeValue(up, "")
				r.Upper = &v
			}
			return Value{Kind: RangeKind, Range: r}
		}
		return Value{Kind: RangeKind, Str: string(raw)}
	}
	switch raw[0] {
	case '[':
		var arr []json.RawMessage
		if err := json.Unmarshal(raw, &arr); err != nil {
			return Value{Kind: Str, Str: string(raw)}
		}
		vals := make([]Value, len(arr))
		for i := range arr {
			vals[i] = decodeValue(arr[i], "")
		}
		return Value{Kind: Array, Arr: vals}
	case '{':
		var obj map[string]json.RawMessage
		if err := json.Unmarshal(raw, &obj); err != nil {
			return Value{Kind: Str, Str: string(raw)}
		}
		m := make(map[string]Value, len(obj))
		for k, v := range obj {
			m[k] = decodeValue(v, "")
		}
		return Value{Kind: Object, Obj: m}
	case '"':
		var s string
		if err := json.Unmarshal(raw, &s); err == nil {
			return Value{Kind: Str, Str: s}
		}
		return Value{Kind: Str, Str: string(raw)}
	default:
		s := string(raw)
		if strings.ContainsAny(s, ".eE") {
			r := new(big.Rat)
			if _, ok := r.SetString(s); ok {
				return Value{Kind: Dec, Dec: r}
			}
			return Value{Kind: Str, Str: s}
		}
		if i, e := strconv.ParseInt(s, 10, 64); e == nil {
			return Value{Kind: Int, Int: i}
		}
		return Value{Kind: Str, Str: s}
	}
}

func hexToBytes(s string) ([]byte, error) {
	if len(s)%2 != 0 {
		return nil, fmt.Errorf("odd hex length")
	}
	b := make([]byte, len(s)/2)
	for i := 0; i < len(b); i++ {
		v, err := strconv.ParseUint(s[i*2:i*2+2], 16, 8)
		if err != nil {
			return nil, err
		}
		b[i] = byte(v)
	}
	return b, nil
}

// loadRootCA loads a PEM CA bundle from path into a cert pool.
func loadRootCA(path string) (*x509.CertPool, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(b) {
		return nil, fmt.Errorf("invalid CA PEM")
	}
	return pool, nil
}

// Protocol frame structure used by client and iterator
type frame struct {
	StatusClass    string `json:"status_class"`
	StatusSubclass string `json:"status_subclass"`
	Result         struct {
		Type    string `json:"type"`
		Columns []struct {
			Name string `json:"name"`
			Type string `json:"type"`
		} `json:"columns"`
		Rows            []map[string]json.RawMessage `json:"rows"`
		Ordered         bool                         `json:"ordered"`
		OrderKeys       []string                     `json:"order_keys"`
		Final           bool                         `json:"final"`
		Code            string                       `json:"code"`
		Message         string                       `json:"message"`
		Anchor          string                       `json:"anchor"`
		JSON            json.RawMessage              `json:"json"`
		FlaggerFindings []string                     `json:"flagger_findings"`
	} `json:"result"`
}
