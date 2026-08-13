package portproxy

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

type fixedResolver struct{ target string }

func (r fixedResolver) PublishedTarget(port uint16, protocol string) (string, error) {
	if port == 42000 && (protocol == "tcp" || protocol == "udp") {
		return r.target, nil
	}
	return "", &net.AddrError{Err: "unpublished", Addr: protocol}
}

func TestServeProxiesFramedUDPPublication(t *testing.T) {
	backend, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	go func() {
		buffer := make([]byte, 64)
		count, address, readErr := backend.ReadFrom(buffer)
		if readErr == nil {
			_, _ = backend.WriteTo(buffer[:count], address)
		}
	}()

	frontend, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = Serve(ctx, frontend, fixedResolver{target: backend.LocalAddr().String()}) }()

	client, err := net.DialTimeout("tcp", frontend.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	header := []byte{'S', 'T', 'P', '1', ProtocolUDP, 0, 0, 0, 5}
	binary.BigEndian.PutUint16(header[5:], 42000)
	if _, err := client.Write(append(header, []byte("hello")...)); err != nil {
		t.Fatal(err)
	}
	frame := make([]byte, 7)
	if _, err := io.ReadFull(client, frame); err != nil {
		t.Fatal(err)
	}
	if binary.BigEndian.Uint16(frame[:2]) != 5 || string(frame[2:]) != "hello" {
		t.Fatalf("reply frame = %v", frame)
	}
}

func TestServeProxiesPreparedTCPPublication(t *testing.T) {
	backend, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	go func() {
		conn, acceptErr := backend.Accept()
		if acceptErr != nil {
			return
		}
		defer conn.Close()
		_, _ = io.Copy(conn, conn)
	}()

	frontend, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = Serve(ctx, frontend, fixedResolver{target: backend.Addr().String()}) }()

	client, err := net.DialTimeout("tcp", frontend.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	header := []byte{'S', 'T', 'P', '1', ProtocolTCP, 0, 0}
	binary.BigEndian.PutUint16(header[5:], 42000)
	if _, err := client.Write(append(header, []byte("hello")...)); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 5)
	if _, err := io.ReadFull(client, reply); err != nil {
		t.Fatal(err)
	}
	if string(reply) != "hello" {
		t.Fatalf("reply = %q, want hello", reply)
	}
}

func TestServePreservesTCPHalfClose(t *testing.T) {
	backend, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	go func() {
		connection, acceptErr := backend.Accept()
		if acceptErr != nil {
			return
		}
		defer connection.Close()
		request, readErr := io.ReadAll(connection)
		if readErr == nil {
			_, _ = connection.Write(request)
		}
	}()

	frontend, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = Serve(ctx, frontend, fixedResolver{target: backend.Addr().String()}) }()

	connection, err := net.DialTimeout("tcp", frontend.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	client := connection.(*net.TCPConn)
	defer client.Close()
	header := []byte{'S', 'T', 'P', '1', ProtocolTCP, 0, 0}
	binary.BigEndian.PutUint16(header[5:], 42000)
	if _, err := client.Write(append(header, []byte("request-before-eof")...)); err != nil {
		t.Fatal(err)
	}
	if err := client.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	reply, err := io.ReadAll(client)
	if err != nil {
		t.Fatal(err)
	}
	if string(reply) != "request-before-eof" {
		t.Fatalf("reply = %q", reply)
	}
}
