package forwarder

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"time"
)

const headerSize = 8
const defaultMaximumSessions = 4096
const maximumFrameSize = 1024 * 1024

var headerMagic = [4]byte{'S', 'T', 'P', 'F'}

type DestinationResolver func(guestPort uint16) (string, bool)

type TCPServer struct {
	resolve         DestinationResolver
	dial            func(context.Context, string, string) (net.Conn, error)
	maximumSessions int
}

func NewTCPServer(resolve DestinationResolver) *TCPServer {
	dialer := net.Dialer{Timeout: 2 * time.Second}
	return &TCPServer{
		resolve:         resolve,
		dial:            dialer.DialContext,
		maximumSessions: defaultMaximumSessions,
	}
}

func (s *TCPServer) Serve(ctx context.Context, listener net.Listener) error {
	var sessions sync.WaitGroup
	slots := make(chan struct{}, s.maximumSessions)
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	for {
		connection, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				sessions.Wait()
				return nil
			}
			sessions.Wait()
			return err
		}
		select {
		case slots <- struct{}{}:
			sessions.Add(1)
			go func() {
				defer sessions.Done()
				defer func() { <-slots }()
				s.serveConnection(ctx, connection)
			}()
		default:
			_ = connection.Close()
		}
	}
}

func (s *TCPServer) serveConnection(ctx context.Context, client net.Conn) {
	defer client.Close()
	_ = client.SetReadDeadline(time.Now().Add(2 * time.Second))
	var header [headerSize]byte
	if _, err := io.ReadFull(client, header[:]); err != nil {
		return
	}
	_ = client.SetReadDeadline(time.Time{})
	if header[0] != headerMagic[0] || header[1] != headerMagic[1] ||
		header[2] != headerMagic[2] || header[3] != headerMagic[3] ||
		header[4] != 2 || header[5] != 0 {
		return
	}
	guestPort := binary.BigEndian.Uint16(header[6:])
	destination, allowed := s.resolve(guestPort)
	if !allowed {
		return
	}
	target, err := s.dial(ctx, "tcp4", destination)
	if err != nil {
		return
	}
	defer target.Close()
	sessionDone := make(chan struct{})
	defer close(sessionDone)
	go func() {
		select {
		case <-ctx.Done():
			_ = client.Close()
			_ = target.Close()
		case <-sessionDone:
		}
	}()

	done := make(chan error, 2)
	copyHalf := func(destination, source net.Conn) {
		_, err := io.Copy(destination, source)
		if closer, ok := destination.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		}
		done <- err
	}
	go func() { done <- copyFramedStream(target, client) }()
	go copyHalf(client, target)
	if err := <-done; err != nil {
		log.Printf("tcp relay session: %v", err)
		_ = client.Close()
		_ = target.Close()
	}
	<-done
}

func copyFramedStream(destination, source net.Conn) error {
	var header [4]byte
	var copied uint64
	for {
		if _, err := io.ReadFull(source, header[:]); err != nil {
			return err
		}
		length := binary.BigEndian.Uint32(header[:])
		if length == 0 {
			var expected [8]byte
			if _, err := io.ReadFull(source, expected[:]); err != nil {
				return err
			}
			if total := binary.BigEndian.Uint64(expected[:]); copied != total {
				return fmt.Errorf("framed stream length mismatch: copied %d of %d", copied, total)
			}
			if closer, ok := destination.(interface{ CloseWrite() error }); ok {
				return closer.CloseWrite()
			}
			return nil
		}
		if length > maximumFrameSize {
			return io.ErrUnexpectedEOF
		}
		if _, err := io.CopyN(destination, source, int64(length)); err != nil {
			return err
		}
		copied += uint64(length)
	}
}
