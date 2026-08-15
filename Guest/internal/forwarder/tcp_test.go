package forwarder

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

func relayHeader(port uint16) []byte {
	header := []byte{'S', 'T', 'P', 'F', 2, 0, 0, 0}
	binary.BigEndian.PutUint16(header[6:], port)
	return header
}

func framedPayload(payload []byte) []byte {
	result := make([]byte, 0, len(payload)+(len(payload)/(64*1024)+2)*4)
	for len(payload) > 0 {
		length := min(len(payload), 64*1024)
		var header [4]byte
		binary.BigEndian.PutUint32(header[:], uint32(length))
		result = append(result, header[:]...)
		result = append(result, payload[:length]...)
		payload = payload[length:]
	}
	var end [12]byte
	// The stream total excludes frame headers.
	var total uint64
	for offset := 0; offset < len(result); {
		length := binary.BigEndian.Uint32(result[offset:])
		total += uint64(length)
		offset += 4 + int(length)
	}
	binary.BigEndian.PutUint64(end[4:], total)
	result = append(result, end[:]...)
	return result
}

func startRelay(t *testing.T, server *TCPServer) (string, context.CancelFunc) {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		if err := server.Serve(ctx, listener); err != nil {
			t.Errorf("Serve error = %v", err)
		}
	}()
	return listener.Addr().String(), cancel
}

func TestTCPServerRelaysResponseAfterClientHalfClose(t *testing.T) {
	targetListener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer targetListener.Close()
	go func() {
		connection, acceptErr := targetListener.Accept()
		if acceptErr != nil {
			return
		}
		defer connection.Close()
		request, _ := io.ReadAll(connection)
		_, _ = connection.Write(append([]byte("reply:"), request...))
	}()

	server := NewTCPServer(func(port uint16) (string, bool) {
		return targetListener.Addr().String(), port == 41000
	})
	address, cancel := startRelay(t, server)
	defer cancel()
	connection, err := net.Dial("tcp4", address)
	if err != nil {
		t.Fatal(err)
	}
	tcp := connection.(*net.TCPConn)
	request := append(relayHeader(41000), framedPayload([]byte("request"))...)
	if _, err := tcp.Write(request); err != nil {
		t.Fatal(err)
	}
	response, err := io.ReadAll(tcp)
	if err != nil {
		t.Fatal(err)
	}
	if string(response) != "reply:request" {
		t.Fatalf("response = %q, want %q", response, "reply:request")
	}
}

func TestTCPServerRelaysLargeBidirectionalPayloads(t *testing.T) {
	targetListener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer targetListener.Close()
	request := bytes.Repeat([]byte("request-payload-"), 512*1024)
	response := bytes.Repeat([]byte("response-payload-"), 512*1024)
	targetResult := make(chan []byte, 1)
	go func() {
		connection, acceptErr := targetListener.Accept()
		if acceptErr != nil {
			return
		}
		defer connection.Close()
		writeDone := make(chan struct{})
		go func() {
			_, _ = connection.Write(response)
			if tcp, ok := connection.(*net.TCPConn); ok {
				_ = tcp.CloseWrite()
			}
			close(writeDone)
		}()
		payload, _ := io.ReadAll(connection)
		<-writeDone
		targetResult <- payload
	}()

	server := NewTCPServer(func(port uint16) (string, bool) {
		return targetListener.Addr().String(), port == 41000
	})
	address, cancel := startRelay(t, server)
	defer cancel()
	connection, err := net.Dial("tcp4", address)
	if err != nil {
		t.Fatal(err)
	}
	tcp := connection.(*net.TCPConn)
	writeDone := make(chan error, 1)
	go func() {
		_, writeErr := tcp.Write(append(relayHeader(41000), framedPayload(request)...))
		writeDone <- writeErr
	}()
	received, err := io.ReadAll(tcp)
	if err != nil {
		t.Fatal(err)
	}
	if err := <-writeDone; err != nil {
		t.Fatal(err)
	}
	_ = tcp.Close()
	if !bytes.Equal(received, response) {
		t.Fatalf("response length = %d, want %d", len(received), len(response))
	}
	if targetPayload := <-targetResult; !bytes.Equal(targetPayload, request) {
		t.Fatalf("request length = %d, want %d", len(targetPayload), len(request))
	}
}

func TestTCPServerRejectsInvalidAndUnauthorizedHeaders(t *testing.T) {
	var dialCount atomic.Int32
	server := NewTCPServer(func(uint16) (string, bool) { return "", false })
	server.dial = func(context.Context, string, string) (net.Conn, error) {
		dialCount.Add(1)
		return nil, nil
	}
	address, cancel := startRelay(t, server)
	defer cancel()

	for _, header := range [][]byte{
		[]byte("BAD!\x01\x00\xa0\x28"),
		[]byte("STPF\x01\x00\xa0\x28"),
		[]byte("STPF\x02\x01\xa0\x28"),
		relayHeader(41000),
	} {
		connection, err := net.Dial("tcp4", address)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := connection.Write(header); err != nil {
			t.Fatal(err)
		}
		_ = connection.SetReadDeadline(time.Now().Add(time.Second))
		buffer := make([]byte, 1)
		if count, err := connection.Read(buffer); count != 0 || err == nil {
			t.Fatalf("rejected connection read = (%d, %v), want EOF/error", count, err)
		}
		_ = connection.Close()
	}
	if dialCount.Load() != 0 {
		t.Fatalf("dial count = %d, want 0", dialCount.Load())
	}
}

func TestTCPServerCancellationClosesActiveSession(t *testing.T) {
	targetListener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer targetListener.Close()
	accepted := make(chan net.Conn, 1)
	go func() {
		connection, acceptErr := targetListener.Accept()
		if acceptErr == nil {
			accepted <- connection
		}
	}()
	server := NewTCPServer(func(uint16) (string, bool) { return targetListener.Addr().String(), true })
	address, cancel := startRelay(t, server)
	connection, err := net.Dial("tcp4", address)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := connection.Write(relayHeader(41000)); err != nil {
		t.Fatal(err)
	}
	peer := <-accepted
	defer peer.Close()
	cancel()
	_ = connection.SetReadDeadline(time.Now().Add(time.Second))
	buffer := make([]byte, 1)
	if count, err := connection.Read(buffer); count != 0 || err == nil {
		t.Fatalf("cancelled connection read = (%d, %v), want EOF/error", count, err)
	}
	_ = connection.Close()
}

func TestTCPServerRejectsSessionsOverLimit(t *testing.T) {
	server := NewTCPServer(func(uint16) (string, bool) { return "", false })
	server.maximumSessions = 1
	address, cancel := startRelay(t, server)
	defer cancel()
	first, err := net.Dial("tcp4", address)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	time.Sleep(20 * time.Millisecond)
	second, err := net.Dial("tcp4", address)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	_ = second.SetReadDeadline(time.Now().Add(time.Second))
	buffer := make([]byte, 1)
	if count, err := second.Read(buffer); count != 0 || err == nil {
		t.Fatalf("excess connection read = (%d, %v), want EOF/error", count, err)
	}
}
