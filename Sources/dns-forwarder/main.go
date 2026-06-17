// Minimal UDP DNS forwarder for socktainer inter-container DNS.
// Listens on :53 and forwards all queries to the upstream specified
// by DNS_UPSTREAM (the gateway IP on port 2054 where
// SocktainerDNSServer is already listening on the host).
package main

import (
	"log"
	"net"
	"os"
	"time"
)

// maxDNSSize is large enough for EDNS0 messages (RFC 6891 recommends 1232
// bytes to avoid IP fragmentation; 4096 is the practical EDNS0 upper bound).
const maxDNSSize = 4096

// maxConcurrent limits goroutines to prevent memory exhaustion under high
// query rates. Local dev DNS traffic is light; 64 concurrent forwarders is
// far more than enough and prevents DoS-by-fanout.
const maxConcurrent = 64

func main() {
	upstream := os.Getenv("DNS_UPSTREAM")
	if upstream == "" {
		log.Fatal("DNS_UPSTREAM not set")
	}

	pc, err := net.ListenPacket("udp", ":53")
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	defer pc.Close()
	log.Printf("dns-forwarder: listening on :53, upstream %s", upstream)

	sem := make(chan struct{}, maxConcurrent)
	buf := make([]byte, maxDNSSize)
	for {
		n, addr, err := pc.ReadFrom(buf)
		if err != nil {
			continue
		}
		query := make([]byte, n)
		copy(query, buf[:n])

		select {
		case sem <- struct{}{}:
			go func() {
				defer func() { <-sem }()
				forward(pc, addr, query, upstream)
			}()
		default:
			// Semaphore full — drop the query rather than block the read loop.
			// DNS clients retry automatically; this is the safe backpressure path.
		}
	}
}

func forward(pc net.PacketConn, client net.Addr, query []byte, upstream string) {
	conn, err := net.DialTimeout("udp", upstream, 2*time.Second)
	if err != nil {
		return
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write(query); err != nil {
		return
	}
	resp := make([]byte, maxDNSSize)
	n, err := conn.Read(resp)
	if err != nil {
		return
	}
	pc.WriteTo(resp[:n], client)
}
