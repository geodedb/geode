package gql

import "testing"

func TestDSN_TLSParseOnly(t *testing.T) { // TLS DSN parse test (QUIC)
	cfg := parseDSN("quic:127.0.0.1:7567?tls=true&ca=ca.pem&cert=client.pem&key=client.key")
	// Current parser ignores tls fields (placeholders) so just ensure no panic and defaults preserved
	if cfg.Mode != "quic" { t.Fatalf("want quic mode") }
	if cfg.Addr != "127.0.0.1:7567" { t.Fatalf("addr mismatch: %s", cfg.Addr) }
	// Document: TLS parameters currently ignored (parse-only placeholder)
}
