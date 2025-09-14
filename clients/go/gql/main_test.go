package gql

import (
	"net"
	"os/exec"
	"testing"
	"time"
)

var tcpOnce struct{
	started bool
}

func TestMain(m *testing.M) {
	// Start TCP listener once
	if !tcpOnce.started {
		ensureServer(&testing.T{})
		cmd := exec.Command("../../../zig-out/bin/geoded", "--listen-tcp", "127.0.0.1:7567")
		_ = cmd.Start()
		// wait until port ready
		deadline := time.Now().Add(2 * time.Second)
		for time.Now().Before(deadline) {
			conn, err := net.Dial("tcp", "127.0.0.1:7567")
			if err == nil {
				_ = conn.Close()
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
		tcpOnce.started = true
	}
	m.Run()
}
