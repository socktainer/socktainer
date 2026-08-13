package portproxy

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"time"
)

const (
	ProtocolTCP byte = 1
	ProtocolUDP byte = 2
)

var protocolMagic = [4]byte{'S', 'T', 'P', '1'}

type PublishedTargetResolver interface {
	PublishedTarget(port uint16, protocol string) (string, error)
}

func Serve(ctx context.Context, listener net.Listener, resolver PublishedTargetResolver) error {
	go func() {
		<-ctx.Done()
		_ = listener.Close()
	}()
	for {
		connection, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go handle(connection, resolver)
	}
}

func handle(connection net.Conn, resolver PublishedTargetResolver) {
	defer connection.Close()
	_ = connection.SetReadDeadline(time.Now().Add(5 * time.Second))
	header := make([]byte, 7)
	if _, err := io.ReadFull(connection, header); err != nil {
		return
	}
	if !bytes.Equal(header[:4], protocolMagic[:]) {
		return
	}
	_ = connection.SetReadDeadline(time.Time{})
	protocol := ""
	switch header[4] {
	case ProtocolTCP:
		protocol = "tcp"
	case ProtocolUDP:
		protocol = "udp"
	default:
		return
	}
	target, err := resolver.PublishedTarget(binary.BigEndian.Uint16(header[5:]), protocol)
	if err != nil {
		return
	}
	backend, err := net.Dial(protocol, target)
	if err != nil {
		return
	}
	defer backend.Close()
	if protocol == "tcp" {
		copyBidirectional(connection, backend)
	} else {
		copyDatagrams(connection, backend)
	}
}

func copyDatagrams(stream, datagrams net.Conn) {
	done := make(chan struct{}, 2)
	go func() {
		defer func() { done <- struct{}{} }()
		length := make([]byte, 2)
		for {
			if _, err := io.ReadFull(stream, length); err != nil {
				return
			}
			payload := make([]byte, int(binary.BigEndian.Uint16(length)))
			if _, err := io.ReadFull(stream, payload); err != nil {
				return
			}
			if _, err := datagrams.Write(payload); err != nil {
				return
			}
		}
	}()
	go func() {
		defer func() { done <- struct{}{} }()
		payload := make([]byte, 65_507)
		for {
			count, err := datagrams.Read(payload)
			if err != nil {
				return
			}
			frame := make([]byte, 2+count)
			binary.BigEndian.PutUint16(frame, uint16(count))
			copy(frame[2:], payload[:count])
			if _, err := stream.Write(frame); err != nil {
				return
			}
		}
	}()
	<-done
}

type closeWriter interface{ CloseWrite() error }

func copyBidirectional(client, backend net.Conn) {
	done := make(chan struct{}, 2)
	copyOneWay := func(destination, source net.Conn) {
		_, _ = io.Copy(destination, source)
		if writer, ok := destination.(closeWriter); ok {
			_ = writer.CloseWrite()
		}
		done <- struct{}{}
	}
	go copyOneWay(backend, client)
	go copyOneWay(client, backend)
	<-done
	<-done
}
