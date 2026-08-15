package main

import (
	"context"
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/mdlayher/vsock"
	"github.com/glassdock/glassdock/guest/internal/backend"
	"github.com/glassdock/glassdock/guest/internal/server"
)

var version = "dev"

func main() {
	containerdAddress := flag.String("containerd", "/run/containerd/containerd.sock", "containerd socket")
	namespace := flag.String("namespace", "glassdock", "containerd namespace")
	snapshotter := flag.String("snapshotter", "overlayfs", "containerd snapshotter")
	runtimeName := flag.String("runtime", "io.containerd.runc.v2", "containerd runtime type")
	runtimeBinary := flag.String("runtime-binary", "/usr/bin/runc", "OCI runtime binary used by the runc v2 shim")
	unixAddress := flag.String("unix", "", "listen on a Unix socket instead of vsock (tests and diagnostics)")
	port := flag.Uint("vsock-port", 1025, "guest vsock port")
	hostBindSource := flag.String("host-bind-source", "", "host source exported by virtiofs")
	guestBindRoot := flag.String("guest-bind-root", "", "fixed guest mount point for the host source")
	excludedHostBindSource := flag.String("excluded-host-bind-source", "", "host engine state excluded from bind mounts")
	flag.Parse()

	b, err := backend.New(*containerdAddress, *namespace, *snapshotter, *runtimeName, *runtimeBinary)
	if err != nil {
		log.Fatal(err)
	}
	defer b.Close()
	if *hostBindSource == "" || *guestBindRoot == "" || *excludedHostBindSource == "" {
		log.Fatal("host bind source, guest bind root, and excluded host bind source are required")
	}
	b.ConfigureBindMount(*hostBindSource, *guestBindRoot, *excludedHostBindSource)
	if err := b.InitializeNetwork(); err != nil {
		log.Fatal(err)
	}

	var listener net.Listener
	if *unixAddress != "" {
		_ = os.Remove(*unixAddress)
		listener, err = net.Listen("unix", *unixAddress)
	} else {
		listener, err = vsock.Listen(uint32(*port), nil)
	}
	if err != nil {
		log.Fatal(err)
	}
	defer listener.Close()
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	log.Printf("glassdock guest agent %s listening on %s", version, listener.Addr())
	guestServer := server.New(b, version)
	if err := guestServer.Serve(ctx, listener); err != nil {
		log.Fatal(err)
	}
}
