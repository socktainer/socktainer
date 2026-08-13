package backend

import (
	"errors"
	"reflect"
	"strconv"
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

func TestNetworkManagerCreatesConfiguredNamespace(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := NewNetworkManager(runner)
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
		"addr add 10.88.0.2/16 dev eth0",
		"route add default via 10.88.0.1",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("commands do not contain %q:\n%s", expected, joined)
		}
	}
}

func TestNetworkManagerUsesUniqueIngressPortsForSameContainerPort(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := NewNetworkManager(runner)
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
	manager := NewNetworkManager(runner)
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

func TestNetworkManagerPublishesAndRemovesUDP(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := NewNetworkManager(runner)
	if _, err := manager.Create("dns"); err != nil {
		t.Fatal(err)
	}
	published, err := manager.Publish("dns", []api.PublishedPort{{ContainerPort: 53, Protocol: "udp"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.Delete("dns"); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(runner.commands, "\n")
	for _, operation := range []string{"-A", "-D"} {
		want := "iptables -t nat " + operation + " PREROUTING -p udp --dport " + strconv.Itoa(int(published[0].GuestPort))
		if !strings.Contains(joined, want) {
			t.Fatalf("UDP DNAT %s is absent:\n%s", operation, joined)
		}
	}
}

func TestNetworkManagerRestrictsVmnetIngressToTheHostGateway(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := NewNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	requested := []api.PublishedPort{{
		ContainerPort: 80, GuestPort: 42000, Protocol: "tcp", HostSource: "192.168.64.1",
	}}
	if _, err := manager.Publish("web", requested); err != nil {
		t.Fatal(err)
	}
	if err := manager.Delete("web"); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(runner.commands, "\n")
	for _, operation := range []string{"-A", "-D"} {
		want := "iptables -t nat " + operation + " PREROUTING -p tcp -s 192.168.64.1 --dport 42000"
		if !strings.Contains(joined, want) {
			t.Fatalf("host-source restriction %s is absent:\n%s", operation, joined)
		}
	}
}

func TestNetworkManagerReusesKnownNamespaceWithoutAProcess(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := NewNetworkManager(runner)
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

func TestNetworkManagerDeleteRemovesDNATAndNamespace(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := NewNetworkManager(runner)
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
	if !strings.Contains(joined, "iptables -t nat -D PREROUTING -p tcp --dport "+strconv.Itoa(int(published[0].GuestPort))) {
		t.Fatalf("DNAT delete is absent:\n%s", joined)
	}
	if !strings.Contains(joined, "ip netns delete st") {
		t.Fatalf("namespace delete is absent:\n%s", joined)
	}
}
