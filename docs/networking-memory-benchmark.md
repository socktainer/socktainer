# Networking architecture and memory benchmark

## Decision

Socktainer now has one infrastructure VM per user-defined network, and that VM
is DNS-only. Published TCP/UDP ports are passed through
`ContainerConfiguration.publishedPorts`; Apple Container owns the listener,
guest forwarding, and teardown. The daemon keeps only a short-lived socket
reservation for Docker's `hostPort: 0` allocation between create and start.

This is the lowest-cost design supported by the current Apple APIs while
retaining Docker/Compose aliases and network isolation:

| Candidate | Decision | Reason |
| --- | --- | --- |
| Host DNS + host relay | Rejected | The host DNS server can bind a high port, but container DNS configuration has no port field; binding port 53 would require a privileged, system-wide listener. Apple’s built-in DNS handler resolves one network attachment hostname, not Docker/Compose aliases. A host relay duplicated Apple’s native published-port forwarder. |
| One combined DNS/relay helper per network | Rejected | Native Apple published ports remove the relay requirement entirely. Keeping a combined helper would preserve the VM cost without preserving a capability. |
| One shared helper VM across networks | Rejected | The public API has no attach/detach operation for an existing container. Recreating a multi-network helper would invalidate nameserver addresses baked into existing containers, and a single nameserver list cannot safely select the helper attachment for every isolated network. |
| One DNS-only helper per named network | Selected | The helper IP is local to the network, aliases remain explicit and isolated, network deletion has one owner, and each helper is right-sized to Apple’s hard 200 MiB minimum. |

The published-port replacement is based on Apple Container 1.2.1’s native
runtime path: `RuntimeService` starts `SocketForwarder` instances from
`publishedPorts` and the container service rejects memory below 200 MiB. See
[Apple’s published-port implementation](https://github.com/apple/container/blob/1.2.1/Sources/Services/RuntimeLinux/Server/RuntimeService.swift#L953)
and the [200 MiB resource floor](https://github.com/apple/container/blob/1.2.1/Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift#L328-L334).
Apple’s [container DNS handler](https://github.com/apple/container/blob/1.2.1/Sources/APIServer/ContainerDNSHandler.swift)
is intentionally limited to the runtime network service lookup, so it cannot
replace Socktainer’s Docker alias registry.

## Lifecycle ownership

```text
Docker create
  ├─ resolve dynamic host ports (bounded reservation sockets only)
  ├─ persist the resolved mapping in Socktainer metadata
  └─ create native container with the same mapping in publishedPorts

Docker start/restart
  ├─ ensure the network's DNS-only helper
  ├─ release the short-lived dynamic reservation
  └─ Apple binds native TCP/UDP forwarders and reports bind failures

Container stop/delete/exit or network delete/prune
  ├─ Apple tears down native port forwarders with the container
  ├─ Socktainer releases any still-held dynamic reservation
  └─ the DNS manager removes the one helper before removing its network

Daemon restart
  ├─ Apple retains native port configuration and running containers
  ├─ metadata recovery re-adopts owned containers
  └─ DNS aliases are rebuilt from snapshots and metadata; no relay is recreated
```

The old relay VM, relay image, Unix-socket protocol, host relay listeners,
relay ownership labels, and port reconciliation manager were deleted. There is
one dynamic allocator for the create-to-start race and one DNS manager for
network infrastructure. Native Apple forwarding is the sole published-port
owner, so recovery is idempotent and cannot create competing listeners.

## Reproducible measurement

The benchmark is deliberately opt-in because it creates disposable resources
in the shared Apple Container service. It does not stop or restart that
service. Every network, container, volume, home directory, metadata directory,
and Unix socket is generated from one prefix; cleanup targets only those exact
names.

```bash
SOCKTAINER_MEMBENCH_ALLOW_RUNTIME=1 \
SOCKTAINER_BINARY=.build/debug/socktainer \
SOCKTAINER_MEMBENCH_IMAGE=postgres:17 \
scripts/benchmark-networking-memory.sh --run
```

The system-wide `footprint --sysFootprint`, `vm_stat`, `memory_pressure`, and
swap samples are intentionally disabled by default. Set
`SOCKTAINER_MEMBENCH_INCLUDE_SYSTEM=1` only on a host with no live workloads;
system pressure cannot be attributed safely while unrelated containers exist.

The script records three stable samples for idle, DNS activity, and published
port traffic, restarts the Socktainer daemon while the disposable resources
remain alive, then records three create/restart/delete lifecycle cycles. It
writes:

- `/usr/bin/footprint -f bytes --noCategories` per Socktainer, API-server,
  helper-VM, and workload-VM process;
- `vm_stat`, `memory_pressure`, and `vm.swapusage` per phase;
- Docker stats as supporting guest-reported evidence; and
- the raw process table and DNS/port success status for auditability.

`/usr/bin/footprint` is the primary host metric. RSS in the process table is
supporting evidence only. A result is valid only when both isolated networks
resolve their peer aliases and the published host port accepts traffic.

## Footprint ledger

The baseline below is the five-sample stable measurement supplied for the
two-network PostgreSQL workload. It is retained here as the comparison point;
the helper rows are the structural target, not a claim that guest memory is
host physical footprint.

| Component | Before: host physical footprint | After architecture | Notes |
| --- | ---: | ---: | --- |
| Socktainer daemon | 16.3 MB | 24,052,456 B / 22.94 MiB idle mean | Debug binary; remained bounded across the short scenarios and daemon restart. |
| container-apiserver | 8.5 MB | 10,431,723 B / 9.95 MiB idle mean | Shared Apple runtime process. |
| 2 workload VMs | 905.6 MiB | 2,012,889,643 B / 1,919.64 MiB idle mean for 4 disposable PostgreSQL VMs | Workload count differs; not used for the helper comparison. |
| 2 DNS helper VMs | 449.3 MiB | 494,842,507 B / 471.92 MiB idle mean | 200 MiB configured per helper; actual host footprint is measured. |
| 2 relay helper VMs | 475.8 MiB | 0 | Native Apple published ports replace them. |
| All four helpers | 925.1 MiB | 471.92 MiB idle mean for 2 DNS helpers | 453.18 MiB / 48.99% measured reduction. The configured 200 MiB floor alone permits at most 56.8%; the 70% goal is not reachable with one alias-capable helper per network under this platform floor. |
| Complete attributable host footprint | 1,972,300,288 B / 1.84 GiB | not sampled in this run | Whole-system sampling was skipped to avoid benchmarking the live EasyLink/Glass workloads. |

The disposable run used two isolated networks, four PostgreSQL containers, four
uniquely named volumes, three samples per short scenario, one daemon restart,
and three lifecycle cycles. DNS succeeded on both networks (`192.168.248.4` and
`192.168.247.4`).
Apple’s native published TCP ports accepted IPv4 traffic on `127.0.0.1:52402`
and IPv6 traffic on `[::1]:52407`. Helper totals were 471.92 MiB idle, 472.42
MiB during DNS activity, 472.88 MiB during port traffic, and 473.05 MiB after
daemon restart; the lifecycle samples remained bounded, with one final sample
coinciding with helper teardown. This is bounded short-scenario variation, not
a monotonic helper leak. System pressure and swap must be recorded separately
on a disposable-only host with the opt-in flag.

The hard floor is why the result is reported honestly rather than by lowering a
configuration below what Apple accepts or excluding the remaining DNS VMs from
the accounting. The relay removal is the maximal architecture-supported saving
without dropping Docker/Compose aliases or network isolation. If Apple exposes
an unprivileged host DNS endpoint with a selectable port, or a safe dynamic
network-attachment API, the DNS sidecars can be revisited independently.
