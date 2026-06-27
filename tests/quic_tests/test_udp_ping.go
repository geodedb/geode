//go:build ignore

package main

import (
	"fmt"
	"net"
	"time"
)

func main() {
	// Send a simple UDP packet to 127.0.0.1:3141
	conn, err := net.Dial("udp", "127.0.0.1:3141")
	if err != nil {
		fmt.Printf("Failed to dial: %v\n", err)
		return
	}
	defer conn.Close()

	// Send test data
	data := []byte("PING")
	_, err = conn.Write(data)
	if err != nil {
		fmt.Printf("Failed to write: %v\n", err)
		return
	}

	fmt.Println("Sent UDP packet")
	time.Sleep(1 * time.Second)
}
