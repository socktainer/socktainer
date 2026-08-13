package backend

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/socktainer/socktainer/guest/internal/api"
)

var errRequested = errors.New("requested failure")

type recordingNetworkRunner struct {
	commands []string
	failOn   string
}

func (r *recordingNetworkRunner) Run(name string, args ...string) error {
	command := strings.Join(append([]string{name}, args...), " ")
	r.commands = append(r.commands, command)
	if r.failOn != "" && strings.Contains(command, r.failOn) {
		return errRequested
	}
	return nil
}

type recordingNetworkNamespaces struct{ runner *recordingNetworkRunner }

func (n recordingNetworkNamespaces) Create(name, hostVeth, containerVeth, address string) error {
	return n.runner.Run("netlink", "create", name, hostVeth, containerVeth, "addr", address+"/16", "dev", "eth0", "route", "default", "via", "10.88.0.1")
}

func (n recordingNetworkNamespaces) Delete(name string) error {
	return n.runner.Run("netlink", "delete", name)
}

func newTestNetworkManager(runner *recordingNetworkRunner) *NetworkManager {
	return newNetworkManager(runner, recordingNetworkNamespaces{runner: runner})
}

func TestNetworkManagerCreatesConfiguredNamespace(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	path, err := manager.Create("container-one")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(path, "/run/netns/st") {
		t.Fatalf("unexpected namespace path %q", path)
	}
	joined := strings.Join(runner.commands, "\n")
	for _, expected := range []string{
		"ip link add socktainer0 type bridge",
		"sysctl -w net.ipv4.ip_forward=1",
		"iptables -t nat -A POSTROUTING -s 10.88.0.0/16",
		"addr 10.88.0.2/16 dev eth0",
		"route default via 10.88.0.1",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("commands do not contain %q:\n%s", expected, joined)
		}
	}
}

func TestNetworkManagerUsesUniqueIngressPortsForSameContainerPort(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	for _, id := range []string{"first", "second"} {
		if _, err := manager.Create(id); err != nil {
			t.Fatal(err)
		}
	}
	request := []api.PublishedPort{{ContainerPort: 80, Protocol: "tcp"}}
	first, err := manager.Publish("first", request)
	if err != nil {
		t.Fatal(err)
	}
	second, err := manager.Publish("second", request)
	if err != nil {
		t.Fatal(err)
	}
	if first[0].GuestPort == second[0].GuestPort {
		t.Fatalf("ingress ports collided: %d", first[0].GuestPort)
	}
	if first[0].ContainerPort != 80 || second[0].ContainerPort != 80 {
		t.Fatalf("container ports changed: %#v %#v", first, second)
	}
	before := len(runner.commands)
	repeated, err := manager.Publish("first", request)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(first, repeated) || len(runner.commands) != before {
		t.Fatal("repeat publication was not idempotent")
	}
}

func TestNetworkManagerReportsPreparedPublication(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	want := []api.PublishedPort{{ContainerPort: 80, GuestPort: 42000, Protocol: "tcp"}}
	if _, err := manager.Publish("web", want); err != nil {
		t.Fatal(err)
	}
	got := manager.Published("web")
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("published ports = %#v, want %#v", got, want)
	}
	got[0].GuestPort = 1
	if manager.Published("web")[0].GuestPort != 42000 {
		t.Fatal("Published returned mutable internal storage")
	}
}

func TestNetworkManagerResolvesOnlyPreparedPublishedTargets(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Publish("web", []api.PublishedPort{{
		ContainerPort: 8080, GuestPort: 42000, Protocol: "tcp",
	}}); err != nil {
		t.Fatal(err)
	}
	target, err := manager.PublishedTarget(42000, "tcp")
	if err != nil {
		t.Fatal(err)
	}
	if target != "10.88.0.2:8080" {
		t.Fatalf("target = %q, want 10.88.0.2:8080", target)
	}
	if _, err := manager.PublishedTarget(42001, "tcp"); err == nil {
		t.Fatal("unpublished guest port resolved")
	}
	if strings.Contains(strings.Join(runner.commands, "\n"), "PREROUTING") {
		t.Fatal("published port installed a native vmnet ingress rule")
	}
}

func TestNetworkManagerResolvesAndRemovesUDP(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("dns"); err != nil {
		t.Fatal(err)
	}
	published, err := manager.Publish("dns", []api.PublishedPort{{ContainerPort: 53, Protocol: "udp"}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := manager.PublishedTarget(published[0].GuestPort, "udp"); err != nil {
		t.Fatal(err)
	}
	if err := manager.Delete("dns"); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.PublishedTarget(published[0].GuestPort, "udp"); err == nil {
		t.Fatal("deleted UDP publication still resolves")
	}
}

func TestNetworkManagerPreservesHostSourceMetadataWithoutNativeIngress(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	requested := []api.PublishedPort{{
		ContainerPort: 80, GuestPort: 42000, Protocol: "tcp", HostSource: "192.168.64.1",
	}}
	published, err := manager.Publish("web", requested)
	if err != nil {
		t.Fatal(err)
	}
	if published[0].HostSource != "192.168.64.1" {
		t.Fatalf("host source = %q", published[0].HostSource)
	}
	joined := strings.Join(runner.commands, "\n")
	if strings.Contains(joined, "PREROUTING") {
		t.Fatalf("native ingress rule is present:\n%s", joined)
	}
}

func TestDeferredNetworkPreparationCreatesAndPublishesAtomically(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	backend := &Backend{network: manager}
	want := []api.PublishedPort{{ContainerPort: 80, GuestPort: 42000, Protocol: "tcp"}}
	if err := backend.prepareNetwork("web", want); err != nil {
		t.Fatal(err)
	}
	if got := manager.Published("web"); !reflect.DeepEqual(got, want) {
		t.Fatalf("published ports = %#v, want %#v", got, want)
	}
}

func TestDeferredNetworkPreparationRollsBackInvalidPublication(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	backend := &Backend{network: manager}
	err := backend.prepareNetwork("web", []api.PublishedPort{{ContainerPort: 0, Protocol: "tcp"}})
	if err == nil {
		t.Fatal("invalid publication succeeded")
	}
	if _, err := manager.Publish("web", []api.PublishedPort{{ContainerPort: 80}}); err == nil {
		t.Fatal("failed deferred preparation left its network behind")
	}
}

func TestNetworkManagerReusesKnownNamespaceWithoutAProcess(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	first, err := manager.Create("reused")
	if err != nil {
		t.Fatal(err)
	}
	commandCount := len(runner.commands)
	second, err := manager.Create("reused")
	if err != nil {
		t.Fatal(err)
	}
	if first != second {
		t.Fatalf("namespace path changed: %q != %q", first, second)
	}
	if len(runner.commands) != commandCount {
		t.Fatalf("known namespace executed another command: %#v", runner.commands[commandCount:])
	}
}

func TestNetworkManagerDeleteRemovesPublicationAndNamespace(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	published, err := manager.Publish("web", []api.PublishedPort{{ContainerPort: 8080, Protocol: "tcp"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.Delete("web"); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(runner.commands, "\n")
	if _, err := manager.PublishedTarget(published[0].GuestPort, "tcp"); err == nil {
		t.Fatal("deleted publication still resolves")
	}
	if !strings.Contains(joined, "netlink delete st") {
		t.Fatalf("namespace delete is absent:\n%s", joined)
	}
}
