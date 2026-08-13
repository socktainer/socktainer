package backend

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"sync"

	"github.com/socktainer/socktainer/guest/internal/api"
)

const (
	bridgeName  = "socktainer0"
	bridgeCIDR  = "10.88.0.1/16"
	networkCIDR = "10.88.0.0/16"
)

type networkCommandRunner interface {
	Run(name string, args ...string) error
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
	initialized bool
	nextAddress uint32
	nextPort    uint16
	containers  map[string]*containerNetwork
}

func (m *NetworkManager) Path(id string) string {
	return "/run/netns/" + networkName(id)
}

func NewNetworkManager(runner networkCommandRunner) *NetworkManager {
	return &NetworkManager{runner: runner, nextAddress: 2, nextPort: 41000, containers: make(map[string]*containerNetwork)}
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
	commands := []string{
		"ip netns add " + name,
		"ip link add " + hostVeth + " type veth peer name " + containerVeth,
		"ip link set " + hostVeth + " master " + bridgeName,
		"ip link set " + hostVeth + " up",
		"ip link set " + containerVeth + " netns " + name,
		"ip -n " + name + " link set lo up",
		"ip -n " + name + " link set " + containerVeth + " name eth0",
		"ip -n " + name + " addr add " + address + "/16 dev eth0",
		"ip -n " + name + " link set eth0 up",
		"ip -n " + name + " route add default via 10.88.0.1",
	}
	if err := m.runner.Run("sh", "-c", strings.Join(commands, " && ")); err != nil {
		_ = m.runner.Run("ip", "netns", "delete", name)
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
		return append([]api.PublishedPort(nil), network.guestPorts...), nil
	}
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
			guestPort = m.nextPort
			m.nextPort++
		}
		destination := network.address + ":" + strconv.Itoa(int(port.ContainerPort))
		arguments := []string{"-t", "nat", "-A", "PREROUTING", "-p", protocol}
		if port.HostSource != "" {
			arguments = append(arguments, "-s", port.HostSource)
		}
		arguments = append(arguments, "--dport", strconv.Itoa(int(guestPort)), "-j", "DNAT", "--to-destination", destination)
		if err := m.runner.Run("iptables", arguments...); err != nil {
			m.removeRules(network, published)
			return nil, err
		}
		published = append(published, api.PublishedPort{ContainerPort: port.ContainerPort, GuestPort: guestPort, Protocol: protocol, HostSource: port.HostSource})
	}
	network.guestPorts = published
	return append([]api.PublishedPort(nil), published...), nil
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
	m.removeRules(network, network.guestPorts)
	if err := m.runner.Run("ip", "netns", "delete", network.name); err != nil {
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

func (m *NetworkManager) removeRules(network *containerNetwork, ports []api.PublishedPort) {
	for _, port := range ports {
		destination := network.address + ":" + strconv.Itoa(int(port.ContainerPort))
		protocol := strings.ToLower(port.Protocol)
		if protocol == "" {
			protocol = "tcp"
		}
		arguments := []string{"-t", "nat", "-D", "PREROUTING", "-p", protocol}
		if port.HostSource != "" {
			arguments = append(arguments, "-s", port.HostSource)
		}
		arguments = append(arguments, "--dport", strconv.Itoa(int(port.GuestPort)), "-j", "DNAT", "--to-destination", destination)
		_ = m.runner.Run("iptables", arguments...)
	}
}

func networkName(id string) string {
	digest := sha256.Sum256([]byte(id))
	return fmt.Sprintf("st%x", digest[:6])
}
