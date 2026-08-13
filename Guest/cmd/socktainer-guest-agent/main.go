package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/mdlayher/vsock"
	"github.com/socktainer/socktainer/guest/internal/backend"
	"github.com/socktainer/socktainer/guest/internal/portproxy"
	"github.com/socktainer/socktainer/guest/internal/server"
)

var version = "dev"

func main() {
	containerdAddress := flag.String("containerd", "/run/containerd/containerd.sock", "containerd socket")
	namespace := flag.String("namespace", "socktainer", "containerd namespace")
	snapshotter := flag.String("snapshotter", "overlayfs", "containerd snapshotter")
	runtimeName := flag.String("runtime", "io.containerd.runc.v2", "containerd runtime type")
	runtimeBinary := flag.String("runtime-binary", "/usr/bin/runc", "OCI runtime binary used by the runc v2 shim")
	unixAddress := flag.String("unix", "", "listen on a Unix socket instead of vsock (tests and diagnostics)")
	port := flag.Uint("vsock-port", 1025, "guest vsock port")
	proxyPort := flag.Uint("proxy-vsock-port", 1026, "published port proxy vsock port")
	bindRoot := flag.String("bind-root", "", "Apple virtiofs shared home path")
	flag.Parse()

	b, err := backend.New(*containerdAddress, *namespace, *snapshotter, *runtimeName, *runtimeBinary)
	if err != nil {
		log.Fatal(err)
	}
	defer b.Close()
	if *bindRoot != "" {
		b.ConfigureBindRoot(*bindRoot)
	}
	if err := b.InitializeNetwork(); err != nil {
		log.Fatal(err)
	}

	var listener net.Listener
	var proxyListener net.Listener
	if *unixAddress != "" {
		_ = os.Remove(*unixAddress)
		listener, err = net.Listen("unix", *unixAddress)
		if err == nil {
			proxyListener, err = net.Listen("tcp", "127.0.0.1:0")
		}
	} else {
		listener, err = vsock.Listen(uint32(*port), nil)
		if err == nil {
			proxyListener, err = vsock.Listen(uint32(*proxyPort), nil)
		}
	}
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()
	defer proxyListener.Close()
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	log.Printf("socktainer guest agent %s listening on %s", version, listener.Addr())
	guestServer := server.New(b, version)
	serveCtx, cancelServe := context.WithCancel(ctx)
	defer cancelServe()
	errors := make(chan error, 2)
	go func() { errors <- guestServer.Serve(serveCtx, listener) }()
	go func() { errors <- portproxy.Serve(serveCtx, proxyListener, b) }()
	firstError := <-errors
	cancelServe()
	secondError := <-errors
	if firstError != nil {
		fmt.Fprintln(os.Stderr, firstError)
		os.Exit(1)
	}
	if secondError != nil {
		fmt.Fprintln(os.Stderr, secondError)
		os.Exit(1)
	}
}
