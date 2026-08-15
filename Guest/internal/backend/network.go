package backend

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"sync"

	"github.com/glassdock/glassdock/guest/internal/api"
)

const (
	bridgeName  = "glassdock0"
	bridgeCIDR  = "10.88.0.1/16"
	networkCIDR = "10.88.0.0/16"
)

type networkCommandRunner interface {
	Run(name string, args ...string) error
}

type networkNamespaceOperations interface {
	Create(name, hostVeth, containerVeth, address string) error
	Delete(name string) error
}

type commandRunner struct{}

func (commandRunner) Run(name string, args ...string) error {
	output, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return nil
}

type containerNetwork struct {
	name       string
	address    string
	guestPorts []api.PublishedPort
}

// NetworkManager owns one bridge and one preconfigured network namespace per
// container. The namespace exists before runc starts the process, so outbound
// networking is ready when the process executes its first instruction.
type NetworkManager struct {
	mu          sync.Mutex
	runner      networkCommandRunner
	namespaces  networkNamespaceOperations
	initialized bool
	nextAddress uint32
	nextPort    uint16
	containers  map[string]*containerNetwork
}

func (m *NetworkManager) Path(id string) string {
	return "/run/netns/" + networkName(id)
}

func NewNetworkManager(runner networkCommandRunner) *NetworkManager {
	return newNetworkManager(runner, nativeNetworkNamespaceOperations{})
}

func newNetworkManager(runner networkCommandRunner, namespaces networkNamespaceOperations) *NetworkManager {
	return &NetworkManager{runner: runner, namespaces: namespaces, nextAddress: 2, nextPort: 41000, containers: make(map[string]*containerNetwork)}
}

func (m *NetworkManager) Initialize() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.initialize()
}

func (m *NetworkManager) Create(id string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if existing := m.containers[id]; existing != nil {
		return "/run/netns/" + existing.name, nil
	}
	if err := m.initialize(); err != nil {
		return "", err
	}
	if m.nextAddress >= 65535 {
		return "", errors.New("container bridge address space is exhausted")
	}
	name := networkName(id)
	address := fmt.Sprintf("10.88.%d.%d", m.nextAddress/256, m.nextAddress%256)
	m.nextAddress++
	hostVeth := "vh" + name[2:]
	containerVeth := "vc" + name[2:]
	if err := m.namespaces.Create(name, hostVeth, containerVeth, address); err != nil {
		_ = m.namespaces.Delete(name)
		return "", err
	}
	m.containers[id] = &containerNetwork{name: name, address: address}
	return "/run/netns/" + name, nil
}

func (m *NetworkManager) Publish(id string, requested []api.PublishedPort) ([]api.PublishedPort, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	network := m.containers[id]
	if network == nil {
		if len(requested) == 0 {
			return nil, nil
		}
		return nil, fmt.Errorf("private network does not exist for container %s", id)
	}
	if len(network.guestPorts) != 0 {
		if !publishedRequestMatches(network.guestPorts, requested) {
			return nil, fmt.Errorf("container %s already has a different published-port set", id)
		}
		return append([]api.PublishedPort(nil), network.guestPorts...), nil
	}
	published, err := m.normalizePublishedPorts(requested)
	if err != nil {
		return nil, err
	}
	installed := make([]api.PublishedPort, 0, len(published))
	selected := make(map[string]struct{}, len(published))
	for _, port := range published {
		key := port.Protocol + ":" + strconv.Itoa(int(port.GuestPort))
		if _, duplicate := selected[key]; duplicate {
			rollbackError := m.removeRules(network, installed)
			return nil, errors.Join(
				fmt.Errorf("published %s port %d is duplicated", port.Protocol, port.GuestPort),
				rollbackError,
			)
		}
		if conflictID, conflict := m.portOwner(port.GuestPort, port.Protocol); conflict {
			rollbackError := m.removeRules(network, installed)
			return nil, errors.Join(
				fmt.Errorf("published %s port %d is already owned by container %s", port.Protocol, port.GuestPort, conflictID),
				rollbackError,
			)
		}
		if err := m.addRules(network, port); err != nil {
			return nil, errors.Join(err, m.removeRules(network, installed))
		}
		installed = append(installed, port)
		selected[key] = struct{}{}
	}
	network.guestPorts = published
	return append([]api.PublishedPort(nil), published...), nil
}

func (m *NetworkManager) normalizePublishedPorts(requested []api.PublishedPort) ([]api.PublishedPort, error) {
	published := make([]api.PublishedPort, 0, len(requested))
	for _, port := range requested {
		protocol := strings.ToLower(port.Protocol)
		if protocol == "" {
			protocol = "tcp"
		}
		if (protocol != "tcp" && protocol != "udp") || port.ContainerPort == 0 {
			return nil, fmt.Errorf("unsupported published port %d/%s", port.ContainerPort, protocol)
		}
		guestPort := port.GuestPort
		if guestPort == 0 {
			var found bool
			for attempts := 0; attempts < 65535-41000+1; attempts++ {
				candidate := m.nextPort
				m.nextPort++
				if m.nextPort < 41000 {
					m.nextPort = 41000
				}
				if _, conflict := m.portOwner(candidate, protocol); !conflict {
					guestPort = candidate
					found = true
					break
				}
			}
			if !found {
				return nil, errors.New("published guest port range is exhausted")
			}
		}
		published = append(published, api.PublishedPort{ContainerPort: port.ContainerPort, GuestPort: guestPort, Protocol: protocol, HostSource: port.HostSource})
	}
	return published, nil
}

func (m *NetworkManager) portOwner(guestPort uint16, protocol string) (string, bool) {
	for id, network := range m.containers {
		for _, published := range network.guestPorts {
			if published.GuestPort == guestPort && published.Protocol == protocol {
				return id, true
			}
		}
	}
	return "", false
}

func (m *NetworkManager) Published(id string) []api.PublishedPort {
	m.mu.Lock()
	defer m.mu.Unlock()
	if network := m.containers[id]; network != nil {
		return append([]api.PublishedPort(nil), network.guestPorts...)
	}
	return nil
}

func (m *NetworkManager) Delete(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	network := m.containers[id]
	if network == nil {
		return nil
	}
	if err := m.removeRules(network, network.guestPorts); err != nil {
		return err
	}
	if err := m.namespaces.Delete(network.name); err != nil {
		return err
	}
	delete(m.containers, id)
	return nil
}

func (m *NetworkManager) initialize() error {
	if m.initialized {
		return nil
	}
	commands := []string{
		"ip link add " + bridgeName + " type bridge",
		"ip addr add " + bridgeCIDR + " dev " + bridgeName,
		"ip link set " + bridgeName + " up",
		"sysctl -w net.ipv4.ip_forward=1",
		"iptables -t nat -A POSTROUTING -s " + networkCIDR + " ! -o " + bridgeName + " -j MASQUERADE",
		"iptables -A FORWARD -i " + bridgeName + " -j ACCEPT",
		"iptables -A FORWARD -o " + bridgeName + " -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT",
	}
	if err := m.runner.Run("sh", "-c", strings.Join(commands, " && ")); err != nil {
		return err
	}
	m.initialized = true
	return nil
}

func (m *NetworkManager) addRules(network *containerNetwork, port api.PublishedPort) error {
	rules := publicationRuleArguments("-A", network, port)
	for ruleIndex, rule := range rules {
		if err := m.runner.Run("iptables", rule...); err != nil {
			rollback := publicationRuleArguments("-D", network, port)
			var rollbackError error
			for installedIndex := ruleIndex - 1; installedIndex >= 0; installedIndex-- {
				rollbackError = errors.Join(
					rollbackError,
					m.runner.Run("iptables", rollback[installedIndex]...),
				)
			}
			return errors.Join(err, rollbackError)
		}
	}
	return nil
}

func (m *NetworkManager) removeRules(network *containerNetwork, ports []api.PublishedPort) error {
	var firstError error
	for portIndex := len(ports) - 1; portIndex >= 0; portIndex-- {
		rules := publicationRuleArguments("-D", network, ports[portIndex])
		for ruleIndex := len(rules) - 1; ruleIndex >= 0; ruleIndex-- {
			if err := m.runner.Run("iptables", rules[ruleIndex]...); err != nil && firstError == nil {
				firstError = err
			}
		}
	}
	return firstError
}

func publicationRuleArguments(operation string, network *containerNetwork, port api.PublishedPort) [][]string {
	guestPort := strconv.Itoa(int(port.GuestPort))
	containerPort := strconv.Itoa(int(port.ContainerPort))
	target := network.address + ":" + containerPort
	comment := "glassdock:" + network.name + ":" + port.Protocol + ":" + guestPort
	return [][]string{
		{"-t", "nat", operation, "PREROUTING", "-i", "eth0", "-p", port.Protocol, "--dport", guestPort, "-m", "comment", "--comment", comment, "-j", "DNAT", "--to-destination", target},
		{operation, "FORWARD", "-i", "eth0", "-o", bridgeName, "-p", port.Protocol, "-d", network.address, "--dport", containerPort, "-m", "conntrack", "--ctstate", "NEW,ESTABLISHED", "-m", "comment", "--comment", comment, "-j", "ACCEPT"},
		{operation, "FORWARD", "-i", bridgeName, "-o", "eth0", "-p", port.Protocol, "-s", network.address, "--sport", containerPort, "-m", "conntrack", "--ctstate", "ESTABLISHED", "-m", "comment", "--comment", comment, "-j", "ACCEPT"},
	}
}

func publishedRequestMatches(existing, requested []api.PublishedPort) bool {
	if len(existing) != len(requested) {
		return false
	}
	for index, request := range requested {
		protocol := strings.ToLower(request.Protocol)
		if protocol == "" {
			protocol = "tcp"
		}
		if existing[index].ContainerPort != request.ContainerPort ||
			existing[index].Protocol != protocol ||
			existing[index].HostSource != request.HostSource ||
			(request.GuestPort != 0 && existing[index].GuestPort != request.GuestPort) {
			return false
		}
	}
	return true
}

func networkName(id string) string {
	digest := sha256.Sum256([]byte(id))
	return fmt.Sprintf("st%x", digest[:6])
}
