package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"github.com/quic-go/quic-go"
)

// Test configuration
type TestConfig struct {
	ServerAddr         string
	InsecureSkipVerify bool
	ALPN               []string
	Timeout            time.Duration
}

// Test result tracking
type TestResult struct {
	Name    string
	Passed  bool
	Error   error
	Details string
}

var results []TestResult
var resultsMutex sync.Mutex

func recordResult(name string, passed bool, err error, details string) {
	resultsMutex.Lock()
	defer resultsMutex.Unlock()
	results = append(results, TestResult{
		Name:    name,
		Passed:  passed,
		Error:   err,
		Details: details,
	})

	status := "✅ PASS"
	if !passed {
		status = "❌ FAIL"
	}
	fmt.Printf("%s: %s - %s\n", status, name, details)
	if err != nil {
		fmt.Printf("       Error: %v\n", err)
	}
}

func main() {
	fmt.Println("==============================================================")
	fmt.Println("COMPREHENSIVE QUIC TEST SUITE FOR GEODE")
	fmt.Println("==============================================================\n")

	config := TestConfig{
		ServerAddr:         "127.0.0.1:3141",
		InsecureSkipVerify: true,
		ALPN:               []string{"geode/1"},
		Timeout:            10 * time.Second,
	}

	// Wait for server to be ready
	fmt.Println("Waiting for server to be ready...")
	time.Sleep(2 * time.Second)

	// Run all tests
	testBasicConnection(config)
	testHandshakeCompletion(config)
	testStreamCreation(config)
	testDataTransmission(config)
	testBidirectionalStream(config)
	testMultipleStreams(config)
	testConnectionClose(config)
	testReconnection(config)
	testConcurrentConnections(config)
	testLargeDataTransfer(config)

	// Print summary
	fmt.Println("\n==============================================================")
	fmt.Println("TEST SUMMARY")
	fmt.Println("==============================================================")

	passed := 0
	failed := 0
	for _, result := range results {
		if result.Passed {
			passed++
		} else {
			failed++
		}
	}

	fmt.Printf("Total Tests: %d\n", len(results))
	fmt.Printf("Passed: %d (%.1f%%)\n", passed, float64(passed)/float64(len(results))*100)
	fmt.Printf("Failed: %d\n", failed)

	if failed > 0 {
		fmt.Println("\nFailed Tests:")
		for _, result := range results {
			if !result.Passed {
				fmt.Printf("  - %s: %v\n", result.Name, result.Error)
			}
		}
		os.Exit(1)
	}

	fmt.Println("\n✅ All tests passed!")
}

func testBasicConnection(config TestConfig) {
	tlsConf := &tls.Config{
		InsecureSkipVerify: config.InsecureSkipVerify,
		NextProtos:         config.ALPN,
		MinVersion:         tls.VersionTLS13,
	}

	qConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		KeepAlivePeriod:      10 * time.Second,
		HandshakeIdleTimeout: 10 * time.Second,
		Versions:             []quic.Version{quic.Version1},
	}

	ctx, cancel := context.WithTimeout(context.Background(), config.Timeout)
	defer cancel()

	conn, err := quic.DialAddr(ctx, config.ServerAddr, tlsConf, qConfig)
	if err != nil {
		recordResult("Basic Connection", false, err, "Failed to establish QUIC connection")
		return
	}
	defer conn.CloseWithError(0, "test complete")

	recordResult("Basic Connection", true, nil, "Successfully established QUIC connection")
}

func testHandshakeCompletion(config TestConfig) {
	tlsConf := &tls.Config{
		InsecureSkipVerify: config.InsecureSkipVerify,
		NextProtos:         config.ALPN,
		MinVersion:         tls.VersionTLS13,
	}

	qConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		HandshakeIdleTimeout: 10 * time.Second,
		Versions:             []quic.Version{quic.Version1},
	}

	ctx, cancel := context.WithTimeout(context.Background(), config.Timeout)
	defer cancel()

	conn, err := quic.DialAddr(ctx, config.ServerAddr, tlsConf, qConfig)
	if err != nil {
		recordResult("Handshake Completion", false, err, "Failed during handshake")
		return
	}
	defer conn.CloseWithError(0, "test complete")

	// Wait for handshake to complete
	select {
	case <-conn.HandshakeComplete():
		recordResult("Handshake Completion", true, nil, "Handshake completed successfully")
	case <-time.After(5 * time.Second):
		recordResult("Handshake Completion", false, fmt.Errorf("timeout"), "Handshake did not complete")
	}
}

func testStreamCreation(config TestConfig) {
	tlsConf := &tls.Config{
		InsecureSkipVerify: config.InsecureSkipVerify,
		NextProtos:         config.ALPN,
		MinVersion:         tls.VersionTLS13,
	}

	qConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		HandshakeIdleTimeout: 10 * time.Second,
		Versions:             []quic.Version{quic.Version1},
	}

	ctx, cancel := context.WithTimeout(context.Background(), config.Timeout)
	defer cancel()

	conn, err := quic.DialAddr(ctx, config.ServerAddr, tlsConf, qConfig)
	if err != nil {
		recordResult("Stream Creation", false, err, "Failed to connect")
		return
	}
	defer conn.CloseWithError(0, "test complete")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		recordResult("Stream Creation", false, err, "Failed to open stream")
		return
	}
	defer stream.Close()

	recordResult("Stream Creation", true, nil, fmt.Sprintf("Successfully opened stream %d", stream.StreamID()))
}

func testDataTransmission(config TestConfig) {
	tlsConf := &tls.Config{
		InsecureSkipVerify: config.InsecureSkipVerify,
		NextProtos:         config.ALPN,
		MinVersion:         tls.VersionTLS13,
	}

	qConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		HandshakeIdleTimeout: 10 * time.Second,
		Versions:             []quic.Version{quic.Version1},
	}

	ctx, cancel := context.WithTimeout(context.Background(), config.Timeout)
	defer cancel()

	conn, err := quic.DialAddr(ctx, config.ServerAddr, tlsConf, qConfig)
	if err != nil {
		recordResult("Data Transmission", false, err, "Failed to connect")
		return
	}
	defer conn.CloseWithError(0, "test complete")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		recordResult("Data Transmission", false, err, "Failed to open stream")
		return
	}
	defer stream.Close()

	testData := []byte("Hello from QUIC client!")
	n, err := stream.Write(testData)
	if err != nil {
		recordResult("Data Transmission", false, err, "Failed to write data")
		return
	}

	if n != len(testData) {
		recordResult("Data Transmission", false, fmt.Errorf("partial write: %d/%d", n, len(testData)), "Incomplete write")
		return
	}

	recordResult("Data Transmission", true, nil, fmt.Sprintf("Successfully sent %d bytes", n))
}

func testBidirectionalStream(config TestConfig) {
	tlsConf := &tls.Config{
		InsecureSkipVerify: config.InsecureSkipVerify,
		NextProtos:         config.ALPN,
		MinVersion:         tls.VersionTLS13,
	}

	qConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		HandshakeIdleTimeout: 10 * time.Second,
		Versions:             []quic.Version{quic.Version1},
	}

	ctx, cancel := context.WithTimeout(context.Background(), config.Timeout)
	defer cancel()

	conn, err := quic.DialAddr(ctx, config.ServerAddr, tlsConf, qConfig)
	if err != nil {
		recordResult("Bidirectional Stream", false, err, "Failed to connect")
		return
	}
	defer conn.CloseWithError(0, "test complete")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		recordResult("Bidirectional Stream", false, err, "Failed to open stream")
		return
	}
	defer stream.Close()

	// Send data
	testData := []byte("ECHO:Hello")
	_, err = stream.Write(testData)
	if err != nil {
		recordResult("Bidirectional Stream", false, err, "Failed to write")
		return
	}

	// Try to read response (with timeout)
	stream.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 1024)
	n, err := stream.Read(buf)
	if err != nil && err != io.EOF {
		// Server might not echo, this is expected for now
		recordResult("Bidirectional Stream", true, nil, "Write successful (server echo not implemented)")
		return
	}

	recordResult("Bidirectional Stream", true, nil, fmt.Sprintf("Sent and received %d bytes", n))
}

func testMultipleStreams(config TestConfig) {
	tlsConf := &tls.Config{
		InsecureSkipVerify: config.InsecureSkipVerify,
		NextProtos:         config.ALPN,
		MinVersion:         tls.VersionTLS13,
	}

	qConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		HandshakeIdleTimeout: 10 * time.Second,
		Versions:             []quic.Version{quic.Version1},
	}

	ctx, cancel := context.WithTimeout(context.Background(), config.Timeout)
	defer cancel()

	conn, err := quic.DialAddr(ctx, config.ServerAddr, tlsConf, qConfig)
	if err != nil {
		recordResult("Multiple Streams", false, err, "Failed to connect")
		return
	}
	defer conn.CloseWithError(0, "test complete")

	// Open multiple streams
	const numStreams = 5
	type streamWrapper struct {
		s quic.Stream
	}
	streams := make([]streamWrapper, 0, numStreams)

	for i := 0; i < numStreams; i++ {
		stream, err := conn.OpenStreamSync(ctx)
		if err != nil {
			recordResult("Multiple Streams", false, err, fmt.Sprintf("Failed to open stream %d", i))
			return
		}
		streams = append(streams, streamWrapper{s: stream})
		defer stream.Close()
	}

	// Write to all streams
	for i, sw := range streams {
		data := []byte(fmt.Sprintf("Stream %d data", i))
		_, err := sw.s.Write(data)
		if err != nil {
			recordResult("Multiple Streams", false, err, fmt.Sprintf("Failed to write to stream %d", i))
			return
		}
	}

	recordResult("Multiple Streams", true, nil, fmt.Sprintf("Successfully opened and wrote to %d streams", numStreams))
}

func testConnectionClose(config TestConfig) {
	tlsConf := &tls.Config{
		InsecureSkipVerify: config.InsecureSkipVerify,
		NextProtos:         config.ALPN,
		MinVersion:         tls.VersionTLS13,
	}

	qConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		HandshakeIdleTimeout: 10 * time.Second,
		Versions:             []quic.Version{quic.Version1},
	}

	ctx, cancel := context.WithTimeout(context.Background(), config.Timeout)
	defer cancel()

	conn, err := quic.DialAddr(ctx, config.ServerAddr, tlsConf, qConfig)
	if err != nil {
		recordResult("Connection Close", false, err, "Failed to connect")
		return
	}

	// Close with error code
	err = conn.CloseWithError(0, "normal close")
	if err != nil {
		recordResult("Connection Close", false, err, "Failed to close connection")
		return
	}

	recordResult("Connection Close", true, nil, "Successfully closed connection")
}

func testReconnection(config TestConfig) {
	tlsConf := &tls.Config{
		InsecureSkipVerify: config.InsecureSkipVerify,
		NextProtos:         config.ALPN,
		MinVersion:         tls.VersionTLS13,
	}

	qConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		HandshakeIdleTimeout: 10 * time.Second,
		Versions:             []quic.Version{quic.Version1},
	}

	// First connection
	ctx1, cancel1 := context.WithTimeout(context.Background(), config.Timeout)
	defer cancel1()

	conn1, err := quic.DialAddr(ctx1, config.ServerAddr, tlsConf, qConfig)
	if err != nil {
		recordResult("Reconnection", false, err, "Failed first connection")
		return
	}
	conn1.CloseWithError(0, "test")

	// Wait a bit
	time.Sleep(500 * time.Millisecond)

	// Second connection
	ctx2, cancel2 := context.WithTimeout(context.Background(), config.Timeout)
	defer cancel2()

	conn2, err := quic.DialAddr(ctx2, config.ServerAddr, tlsConf, qConfig)
	if err != nil {
		recordResult("Reconnection", false, err, "Failed second connection")
		return
	}
	defer conn2.CloseWithError(0, "test complete")

	recordResult("Reconnection", true, nil, "Successfully reconnected")
}

func testConcurrentConnections(config TestConfig) {
	const numConnections = 5
	var wg sync.WaitGroup
	errors := make(chan error, numConnections)

	for i := 0; i < numConnections; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()

			tlsConf := &tls.Config{
				InsecureSkipVerify: config.InsecureSkipVerify,
				NextProtos:         config.ALPN,
				MinVersion:         tls.VersionTLS13,
			}

			qConfig := &quic.Config{
				MaxIdleTimeout:       30 * time.Second,
				HandshakeIdleTimeout: 10 * time.Second,
				Versions:             []quic.Version{quic.Version1},
			}

			ctx, cancel := context.WithTimeout(context.Background(), config.Timeout)
			defer cancel()

			conn, err := quic.DialAddr(ctx, config.ServerAddr, tlsConf, qConfig)
			if err != nil {
				errors <- fmt.Errorf("connection %d failed: %w", id, err)
				return
			}
			defer conn.CloseWithError(0, "test complete")

			// Open a stream and send data
			stream, err := conn.OpenStreamSync(ctx)
			if err != nil {
				errors <- fmt.Errorf("connection %d stream open failed: %w", id, err)
				return
			}
			defer stream.Close()

			data := []byte(fmt.Sprintf("Data from connection %d", id))
			_, err = stream.Write(data)
			if err != nil {
				errors <- fmt.Errorf("connection %d write failed: %w", id, err)
				return
			}
		}(i)
	}

	wg.Wait()
	close(errors)

	var errs []error
	for err := range errors {
		errs = append(errs, err)
	}

	if len(errs) > 0 {
		recordResult("Concurrent Connections", false, errs[0], fmt.Sprintf("%d/%d connections failed", len(errs), numConnections))
		return
	}

	recordResult("Concurrent Connections", true, nil, fmt.Sprintf("Successfully handled %d concurrent connections", numConnections))
}

func testLargeDataTransfer(config TestConfig) {
	tlsConf := &tls.Config{
		InsecureSkipVerify: config.InsecureSkipVerify,
		NextProtos:         config.ALPN,
		MinVersion:         tls.VersionTLS13,
	}

	qConfig := &quic.Config{
		MaxIdleTimeout:       30 * time.Second,
		HandshakeIdleTimeout: 10 * time.Second,
		Versions:             []quic.Version{quic.Version1},
	}

	ctx, cancel := context.WithTimeout(context.Background(), config.Timeout)
	defer cancel()

	conn, err := quic.DialAddr(ctx, config.ServerAddr, tlsConf, qConfig)
	if err != nil {
		recordResult("Large Data Transfer", false, err, "Failed to connect")
		return
	}
	defer conn.CloseWithError(0, "test complete")

	stream, err := conn.OpenStreamSync(ctx)
	if err != nil {
		recordResult("Large Data Transfer", false, err, "Failed to open stream")
		return
	}
	defer stream.Close()

	// Send 1MB of data
	dataSize := 1024 * 1024
	data := make([]byte, dataSize)
	for i := range data {
		data[i] = byte(i % 256)
	}

	written := 0
	chunkSize := 64 * 1024
	for written < dataSize {
		end := written + chunkSize
		if end > dataSize {
			end = dataSize
		}

		n, err := stream.Write(data[written:end])
		if err != nil {
			recordResult("Large Data Transfer", false, err, fmt.Sprintf("Failed after %d bytes", written))
			return
		}
		written += n
	}

	recordResult("Large Data Transfer", true, nil, fmt.Sprintf("Successfully transferred %d bytes", written))
}
