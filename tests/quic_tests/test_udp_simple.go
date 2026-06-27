//go:build ignore

package main

import (
	"fmt"
	"net"
	"time"
)

func main() {
	// Simple UDP client to test if server is receiving packets
	addr, err := net.ResolveUDPAddr("udp", "127.0.0.1:3141")
	if err != nil {
		panic(err)
	}

	conn, err := net.DialUDP("udp", nil, addr)
	if err != nil {
		panic(err)
	}
	defer conn.Close()

	// Send a simple test message
	msg := []byte("TEST UDP PACKET")
	for i := 0; i < 3; i++ {
		n, err := conn.Write(msg)
		if err != nil {
			panic(err)
		}
		fmt.Printf("Sent %d bytes to 127.0.0.1:3141\n", n)
		time.Sleep(100 * time.Millisecond)
	}
}
