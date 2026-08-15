package backend

import (
	"errors"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/glassdock/glassdock/guest/internal/api"
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
		"ip link add glassdock0 type bridge",
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

func TestNetworkManagerInstallsTCPKernelForwardingRules(t *testing.T) {
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
	joined := strings.Join(runner.commands, "\n")
	for _, expected := range []string{
		"iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 42000",
		"-j DNAT --to-destination 10.88.0.2:8080",
		"iptables -A FORWARD -i eth0 -o glassdock0 -p tcp -d 10.88.0.2 --dport 8080",
		"iptables -A FORWARD -i glassdock0 -o eth0 -p tcp -s 10.88.0.2 --sport 8080",
		"--comment glassdock:st",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("kernel rules do not contain %q:\n%s", expected, joined)
		}
	}
}

func TestNetworkManagerInstallsAndRemovesExactUDPRules(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
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
	guestPort := strconv.Itoa(int(published[0].GuestPort))
	for _, expected := range []string{
		"iptables -t nat -A PREROUTING -i eth0 -p udp --dport " + guestPort,
		"iptables -t nat -D PREROUTING -i eth0 -p udp --dport " + guestPort,
		"iptables -D FORWARD -i eth0 -o glassdock0 -p udp",
		"iptables -D FORWARD -i glassdock0 -o eth0 -p udp",
	} {
		if !strings.Contains(joined, expected) {
			t.Fatalf("UDP lifecycle does not contain %q:\n%s", expected, joined)
		}
	}
}

func TestNetworkManagerPreservesHostSourceMetadataWithKernelIngress(t *testing.T) {
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
	if !strings.Contains(joined, "PREROUTING -i eth0 -p tcp --dport 42000") {
		t.Fatalf("kernel ingress rule is absent:\n%s", joined)
	}
}

func TestDeferredNetworkPreparationCreatesAndPublishesAtomically(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	backend := &Backend{network: manager}
	want := []api.PublishedPort{{ContainerPort: 80, GuestPort: 42000, Protocol: "tcp"}}
	if _, err := backend.prepareNetwork("web", want); err != nil {
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
	_, err := backend.prepareNetwork("web", []api.PublishedPort{{ContainerPort: 0, Protocol: "tcp"}})
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
	_, err := manager.Publish("web", []api.PublishedPort{{ContainerPort: 8080, Protocol: "tcp"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.Delete("web"); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(runner.commands, "\n")
	if !strings.Contains(joined, "netlink delete st") {
		t.Fatalf("namespace delete is absent:\n%s", joined)
	}
}

func TestNetworkManagerRejectsDuplicateGuestPortAcrossContainers(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	for _, id := range []string{"first", "second"} {
		if _, err := manager.Create(id); err != nil {
			t.Fatal(err)
		}
	}
	port := []api.PublishedPort{{ContainerPort: 80, GuestPort: 42000, Protocol: "tcp"}}
	if _, err := manager.Publish("first", port); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Publish("second", port); err == nil || !strings.Contains(err.Error(), "already owned") {
		t.Fatalf("duplicate publication error = %v", err)
	}
}

func TestNetworkManagerRejectsDuplicateGuestPortInOneRequest(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	_, err := manager.Publish("web", []api.PublishedPort{
		{ContainerPort: 80, GuestPort: 42000, Protocol: "tcp"},
		{ContainerPort: 81, GuestPort: 42000, Protocol: "tcp"},
	})
	if err == nil || !strings.Contains(err.Error(), "duplicated") {
		t.Fatalf("duplicate request error = %v", err)
	}
	joined := strings.Join(runner.commands, "\n")
	if !strings.Contains(joined, "iptables -t nat -D PREROUTING") {
		t.Fatalf("duplicate request did not roll back its first rule set:\n%s", joined)
	}
}

func TestNetworkManagerAllowsTCPAndUDPOnSameGuestPort(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("dual"); err != nil {
		t.Fatal(err)
	}
	published, err := manager.Publish("dual", []api.PublishedPort{
		{ContainerPort: 80, GuestPort: 42000, Protocol: "TCP"},
		{ContainerPort: 53, GuestPort: 42000, Protocol: "udp"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if published[0].Protocol != "tcp" || published[1].Protocol != "udp" {
		t.Fatalf("protocols were not normalized: %#v", published)
	}
	joined := strings.Join(runner.commands, "\n")
	if !strings.Contains(joined, "-p tcp --dport 42000") ||
		!strings.Contains(joined, "-p udp --dport 42000") {
		t.Fatalf("dual-protocol rules are incomplete:\n%s", joined)
	}
}

func TestNetworkManagerRollsBackPartialRuleInstallation(t *testing.T) {
	runner := &recordingNetworkRunner{failOn: "-A FORWARD -i eth0"}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Publish("web", []api.PublishedPort{{ContainerPort: 80, GuestPort: 42000, Protocol: "tcp"}}); !errors.Is(err, errRequested) {
		t.Fatalf("publish error = %v", err)
	}
	joined := strings.Join(runner.commands, "\n")
	if !strings.Contains(joined, "iptables -t nat -D PREROUTING") {
		t.Fatalf("partial DNAT rule was not rolled back:\n%s", joined)
	}
	if got := manager.Published("web"); len(got) != 0 {
		t.Fatalf("failed publication became visible: %#v", got)
	}
}

func TestNetworkManagerRejectsChangedRepublish(t *testing.T) {
	runner := &recordingNetworkRunner{}
	manager := newTestNetworkManager(runner)
	if _, err := manager.Create("web"); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Publish("web", []api.PublishedPort{{ContainerPort: 80, GuestPort: 42000}}); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Publish("web", []api.PublishedPort{{ContainerPort: 81, GuestPort: 42000}}); err == nil {
		t.Fatal("changed publication was treated as idempotent")
	}
}
