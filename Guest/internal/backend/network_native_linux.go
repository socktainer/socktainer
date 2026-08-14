//go:build linux

package backend

import (
	"fmt"
	"net"
	"runtime"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
)

type nativeNetworkNamespaceOperations struct{}

func (nativeNetworkNamespaceOperations) Create(name, hostVeth, containerVeth, address string) (err error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	origin, err := netns.Get()
	if err != nil {
		return fmt.Errorf("open current network namespace: %w", err)
	}
	defer origin.Close()
	namespace, err := netns.NewNamed(name)
	if err != nil {
		return fmt.Errorf("create network namespace %s: %w", name, err)
	}
	defer namespace.Close()
	if err := netns.Set(origin); err != nil {
		return fmt.Errorf("restore current network namespace: %w", err)
	}

	attrs := netlink.NewLinkAttrs()
	attrs.Name = hostVeth
	if err := netlink.LinkAdd(&netlink.Veth{LinkAttrs: attrs, PeerName: containerVeth}); err != nil {
		return fmt.Errorf("create veth pair: %w", err)
	}
	host, err := netlink.LinkByName(hostVeth)
	if err != nil {
		return fmt.Errorf("find host veth: %w", err)
	}
	bridge, err := netlink.LinkByName(bridgeName)
	if err != nil {
		return fmt.Errorf("find bridge: %w", err)
	}
	if err := netlink.LinkSetMaster(host, bridge); err != nil {
		return fmt.Errorf("attach host veth to bridge: %w", err)
	}
	if err := netlink.LinkSetUp(host); err != nil {
		return fmt.Errorf("bring host veth up: %w", err)
	}
	peer, err := netlink.LinkByName(containerVeth)
	if err != nil {
		return fmt.Errorf("find container veth: %w", err)
	}
	if err := netlink.LinkSetNsFd(peer, int(namespace)); err != nil {
		return fmt.Errorf("move container veth: %w", err)
	}

	handle, err := netlink.NewHandleAt(namespace)
	if err != nil {
		return fmt.Errorf("open namespace netlink handle: %w", err)
	}
	defer handle.Close()
	loopback, err := handle.LinkByName("lo")
	if err != nil {
		return fmt.Errorf("find loopback: %w", err)
	}
	if err := handle.LinkSetUp(loopback); err != nil {
		return fmt.Errorf("bring loopback up: %w", err)
	}
	ethernet, err := handle.LinkByName(containerVeth)
	if err != nil {
		return fmt.Errorf("find namespace veth: %w", err)
	}
	if err := handle.LinkSetName(ethernet, "eth0"); err != nil {
		return fmt.Errorf("rename namespace veth: %w", err)
	}
	parsedAddress, err := netlink.ParseAddr(address + "/16")
	if err != nil {
		return fmt.Errorf("parse namespace address: %w", err)
	}
	if err := handle.AddrAdd(ethernet, parsedAddress); err != nil {
		return fmt.Errorf("assign namespace address: %w", err)
	}
	if err := handle.LinkSetUp(ethernet); err != nil {
		return fmt.Errorf("bring namespace veth up: %w", err)
	}
	if err := handle.RouteAdd(&netlink.Route{LinkIndex: ethernet.Attrs().Index, Gw: net.ParseIP("10.88.0.1")}); err != nil {
		return fmt.Errorf("add namespace default route: %w", err)
	}
	return nil
}

func (nativeNetworkNamespaceOperations) Delete(name string) error {
	return netns.DeleteNamed(name)
}
