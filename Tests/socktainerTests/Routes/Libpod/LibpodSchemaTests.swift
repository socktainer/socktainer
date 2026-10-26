import Foundation
import Testing

@testable import socktainer

/// The shapes below are what the real podman client decodes for `/libpod/*` responses (podman's
/// `pkg/domain/entities` types), checked against a `podman` 6.1 client during development.
@Suite("LibpodSchema — Docker body → libpod body")
struct LibpodSchemaTests {
    private func object(_ value: Any) -> [String: Any] { value as? [String: Any] ?? [:] }
    private func array(_ value: Any) -> [[String: Any]] { value as? [[String: Any]] ?? [] }

    @Test("a container summary has an argv Command, an RFC3339 Created, bare names and image id")
    func containerSummary() {
        let docker: [String: Any] = [
            "Id": "abc", "Names": ["/web"], "Image": "alpine", "ImageID": "sha256:deadbeef",
            "Command": "sleep 300", "Created": 1_700_000_000, "State": "running", "Status": "Up 2 hours (healthy)",
            "Labels": ["k": "v"], "Mounts": [["Destination": "/data", "Type": "volume"]],
            "Ports": [["IP": "0.0.0.0", "PrivatePort": 80, "PublicPort": 8080, "Type": "tcp"]],
            "NetworkSettings": ["Networks": ["default": [String: Any]()]],
        ]
        let summary = LibpodSchema.containerSummary(docker, startedAt: 1_700_000_100)
        #expect(summary["Command"] as? [String] == ["sleep", "300"])
        #expect(summary["Created"] as? String == "2023-11-14T22:13:20Z")
        #expect(summary["Names"] as? [String] == ["web"])
        #expect(summary["ImageID"] as? String == "deadbeef")
        #expect(summary["Mounts"] as? [String] == ["/data"])
        #expect(summary["Networks"] as? [String] == ["default"])
        #expect(summary["StartedAt"] as? Int == 1_700_000_100)
        #expect(summary["Status"] as? String == "healthy")
        #expect(summary["State"] as? String == "running")
        let port = array(summary["Ports"] as Any).first
        #expect(port?["container_port"] as? Int == 80)
        #expect(port?["host_port"] as? Int == 8080)
        #expect(port?["protocol"] as? String == "tcp")
    }

    @Test("an exited container reports Exited with a non-epoch ExitedAt")
    func exitedContainer() {
        let summary = LibpodSchema.containerSummary(["Id": "x", "State": "exited", "Created": 100], startedAt: nil)
        #expect(summary["Exited"] as? Bool == true)
        #expect(summary["ExitedAt"] as? Int == 100)
        #expect(summary["Status"] as? String == "")
    }

    @Test("prune answers are arrays of per-item reports, not Docker's envelope")
    func pruneReports() {
        let containers = array(LibpodSchema.containerPruneReports(["ContainersDeleted": ["a", "b"], "SpaceReclaimed": 10]))
        #expect(containers.map { $0["Id"] as? String } == ["a", "b"])
        #expect(containers.first?["Size"] as? Int == 10)
        let volumes = array(LibpodSchema.volumePruneReports(["VolumesDeleted": ["v"], "SpaceReclaimed": 5]))
        #expect(volumes.first?["Id"] as? String == "v")
        let images = array(LibpodSchema.imagePruneReports(["ImagesDeleted": [["Untagged": "a:1"], ["Deleted": "sha256:x"]], "SpaceReclaimed": 7]))
        #expect(images.map { $0["Id"] as? String } == ["a:1", "sha256:x"])
        let networks = array(LibpodSchema.networkPruneReports(["NetworksDeleted": ["n"]]))
        #expect(networks.first?["Name"] as? String == "n")
        #expect(array(LibpodSchema.containerPruneReports(["ContainersDeleted": [String]()])).isEmpty)
    }

    @Test("podman's volume prune asks for every unused volume, Docker's only anonymous ones")
    func volumePruneFilters() throws {
        func filters(_ input: String?) throws -> [String: [String]] {
            try #require(try JSONSerialization.jsonObject(with: Data(LibpodSchema.volumePruneFilters(input).utf8)) as? [String: [String]])
        }
        #expect(try filters(nil)["all"] == ["true"])
        #expect(try filters(#"{"label":["e2e=1"]}"#) == ["label": ["e2e=1"], "all": ["true"]])
        #expect(try filters(#"{"all":["false"]}"#)["all"] == ["false"])  // an explicit choice is kept
    }

    @Test("a volume list is a bare array of volumes")
    func volumeList() {
        let list = array(LibpodSchema.volumeList(["Volumes": [["Name": "v1", "Driver": "local", "CreatedAt": "2026-01-01T00:00:00Z"]], "Warnings": [String]()]))
        #expect(list.count == 1)
        #expect(list.first?["Name"] as? String == "v1")
        #expect(list.first?["Labels"] is [String: Any])
    }

    @Test("podman's volume create body maps Label/Options onto Docker's Labels/DriverOpts")
    func volumeCreateBody() {
        let docker = LibpodSchema.dockerVolumeCreateBody(fromLibpod: [
            "Name": "v", "Driver": "local", "Label": ["a": "1", "b": "old"], "Labels": ["b": "new"], "Options": ["o": "x"],
        ])
        #expect(docker["Name"] as? String == "v")
        #expect(object(docker["Labels"] as Any) as? [String: String] == ["a": "1", "b": "new"])
        #expect(object(docker["DriverOpts"] as Any) as? [String: String] == ["o": "x"])
    }

    @Test("a network has lower-case keys, a 64-hex id and its subnets")
    func network() {
        let docker: [String: Any] = [
            "Name": "n", "Driver": "nat", "Created": "2026-01-01T00:00:00Z", "Internal": false, "EnableIPv6": true,
            "IPAM": ["Config": [["Subnet": "10.0.0.0/24", "Gateway": "10.0.0.1"]]], "Labels": ["l": "1"],
        ]
        let network = LibpodSchema.network(docker)
        #expect(network["name"] as? String == "n")
        #expect((network["id"] as? String)?.count == 64)
        #expect(network["id"] as? String == LibpodSchema.networkID("n"))
        let subnet = array(network["subnets"] as Any).first
        #expect(subnet?["subnet"] as? String == "10.0.0.0/24")
        #expect(subnet?["gateway"] as? String == "10.0.0.1")
    }

    @Test("podman's network create body maps onto Docker's create body")
    func networkCreateBody() {
        let docker = LibpodSchema.dockerNetworkCreateBody(fromLibpod: [
            "name": "n", "driver": "bridge", "internal": true, "labels": ["a": "b"], "subnets": [["subnet": "10.1.0.0/24", "gateway": "10.1.0.1"]],
        ])
        #expect(docker["Name"] as? String == "n")
        #expect(docker["Internal"] as? Bool == true)
        let ipam = docker["IPAM"] as? [String: Any]
        #expect(ipam?["Driver"] as? String == "default")
        let config = ipam?["Config"] as? [[String: Any]]
        #expect(config?.first?["Subnet"] as? String == "10.1.0.0/24")
    }

    @Test("container inspect drops the leading slash and fixes never-set timestamps")
    func containerInspect() {
        let inspected = object(
            LibpodSchema.containerInspect([
                "Name": "/web", "Image": "alpine:latest", "State": ["StartedAt": "", "FinishedAt": "1970-01-01T00:00:00.000000000Z", "Status": "created"],
            ]))
        #expect(inspected["Name"] as? String == "web")
        #expect(inspected["ImageName"] as? String == "alpine:latest")
        let state = object(inspected["State"] as Any)
        #expect(state["StartedAt"] as? String == "0001-01-01T00:00:00Z")
        #expect(state["FinishedAt"] as? String == "0001-01-01T00:00:00Z")
    }

    @Test("image inspect has bare ids and top-level Labels copied from Config")
    func imageInspect() {
        let inspected = object(LibpodSchema.imageInspect(["Id": "sha256:abc", "Labels": NSNull(), "Config": ["Labels": ["a": "b"]]]))
        #expect(inspected["Id"] as? String == "abc")
        #expect(inspected["Labels"] as? [String: String] == ["a": "b"])
    }

    @Test("image lists use bare ids and Names")
    func imageList() {
        let list = array(LibpodSchema.imageList([["Id": "sha256:abc", "ParentId": "", "RepoTags": ["a:1"]]]))
        #expect(list.first?["Id"] as? String == "abc")
        #expect(list.first?["Names"] as? [String] == ["a:1"])
    }

    @Test("image remove reports carry the rmi exit code")
    func imageRemove() {
        let report = LibpodSchema.imageRemoveReport(untagged: ["a:1"], deleted: ["sha256:abc"], errors: ["nope"], exitCode: 1)
        #expect(report["Deleted"] as? [String] == ["abc"])
        #expect(report["ExitCode"] as? Int == 1)
        #expect(LibpodSchema.imageRemoveExitCode(for: 404) == 1)
        #expect(LibpodSchema.imageRemoveExitCode(for: 409) == 2)
        #expect(LibpodSchema.imageRemoveExitCode(for: 500) == 125)
    }

    @Test("a libpod update maps the restart-policy query and OCI resources onto Docker's body")
    func updateBody() {
        let docker = LibpodSchema.dockerContainerUpdateBody(
            fromLibpod: ["memory": ["limit": 1024], "cpu": ["shares": 2, "cpus": "0-1"], "pids": ["limit": 9]], restartPolicy: "on-failure", restartRetries: 3)
        #expect((docker["RestartPolicy"] as? [String: Any])?["Name"] as? String == "on-failure")
        #expect((docker["RestartPolicy"] as? [String: Any])?["MaximumRetryCount"] as? Int == 3)
        #expect(docker["Memory"] as? Int == 1024)
        #expect(docker["CpuShares"] as? Int == 2)
        #expect(docker["CpusetCpus"] as? String == "0-1")
        #expect(docker["PidsLimit"] as? Int == 9)
    }

    @Test("container stats compute CPU percent like Docker and fold block/network counters")
    func containerStats() {
        let docker: [String: Any] = [
            "name": "/web", "id": "abc",
            "cpu_stats": ["cpu_usage": ["total_usage": 300], "system_cpu_usage": 2000, "online_cpus": 2],
            "precpu_stats": ["cpu_usage": ["total_usage": 100], "system_cpu_usage": 1000, "online_cpus": 2],
            "memory_stats": ["usage": 25, "limit": 100], "pids_stats": ["current": 3],
            "networks": ["eth0": ["rx_bytes": 10, "tx_bytes": 20]],
            "blkio_stats": ["io_service_bytes_recursive": [["op": "read", "value": 7], ["op": "Write", "value": 9]]],
        ]
        let stats = LibpodSchema.containerStats(docker, containerID: "abc")
        #expect(stats["Name"] as? String == "web")
        #expect(stats["CPU"] as? Double == 40)  // (300-100)/(2000-1000) * 2 CPUs * 100
        #expect(stats["MemPerc"] as? Double == 25)
        #expect(stats["BlockInput"] as? Int == 7)
        #expect(stats["BlockOutput"] as? Int == 9)
        #expect(stats["PIDs"] as? Int == 3)
        #expect((stats["Network"] as? [String: Any])?["eth0"] != nil)
    }

    @Test("podman's info and df use podman's own top-level shapes")
    func infoAndDF() {
        let info = object(LibpodSchema.info(["Name": "host", "NCPU": 4, "MemTotal": 1000, "ServerVersion": "1.5.0", "Images": 2, "Containers": 3]))
        #expect(object(info["host"] as Any)["hostname"] as? String == "host")
        #expect(object(info["host"] as Any)["cpus"] as? Int == 4)
        #expect(object(object(info["store"] as Any)["containerStore"] as Any)["number"] as? Int == 3)
        #expect(object(info["version"] as Any)["Version"] as? String == "1.5.0")

        let df = object(
            LibpodSchema.systemDF([
                "LayersSize": 100,
                "Images": [["Id": "sha256:abc", "RepoTags": ["docker.io/library/alpine:3"], "Created": 100, "Size": 10, "SharedSize": 4, "Containers": 1]],
                "Containers": [["Id": "c1", "Names": ["/n"], "Image": "alpine", "Command": "sh -c x", "Created": 100, "Status": "Up"]],
                "Volumes": [["Name": "v", "UsageData": ["Size": 5, "RefCount": 0]]],
            ]))
        #expect(df["ImagesSize"] as? Int == 100)
        let image = array(df["Images"] as Any).first
        #expect(image?["Repository"] as? String == "docker.io/library/alpine")
        #expect(image?["Tag"] as? String == "3")
        #expect(image?["UniqueSize"] as? Int == 6)
        #expect(image?["Created"] is String)
        let container = array(df["Containers"] as Any).first
        #expect(container?["Command"] as? [String] == ["sh", "-c", "x"])
        #expect(container?["Names"] as? String == "n")
        let volume = array(df["Volumes"] as Any).first
        #expect(volume?["ReclaimableSize"] as? Int == 5)
    }
}

@Suite("LibpodSchema — SpecGenerator → Docker create body")
struct LibpodCreateBodyTests {
    @Test("the fields `podman run` sends reach the Docker create body")
    func createBody() {
        let spec: [String: Any] = [
            "image": "alpine", "command": ["sleep", "1"], "entrypoint": ["/bin/sh"], "env": ["B": "2", "A": "1"],
            "labels": ["e2e": "1"], "work_dir": "/tmp", "user": "1000", "hostname": "h", "terminal": true, "stdin": true,
            "remove": true, "stop_signal": 15, "stop_timeout": 7, "privileged": false, "read_only_filesystem": true,
            "cap_add": ["NET_ADMIN"], "dns_server": ["1.1.1.1"], "hostadd": ["x:1.2.3.4"],
            "restart_policy": "on-failure", "restart_tries": 3,
            "portmappings": [["container_port": 80, "host_port": 8080, "protocol": "tcp", "host_ip": "", "range": 1]],
            "mounts": [["destination": "/a", "type": "bind", "source": "/host", "options": ["ro"]]],
            "volumes": [["Name": "vol", "Dest": "/b", "Options": [String]()]],
            "resource_limits": ["memory": ["limit": 1024], "cpu": ["shares": 5], "pids": ["limit": 8]],
            "r_limits": [["type": "RLIMIT_NOFILE", "soft": 1, "hard": 2]],
            "netns": ["nsmode": "bridge"],
        ]
        let body = LibpodSchema.dockerContainerCreateBody(fromSpec: spec)
        #expect(body["Image"] as? String == "alpine")
        #expect(body["Cmd"] as? [String] == ["sleep", "1"])
        #expect(body["Entrypoint"] as? [String] == ["/bin/sh"])
        #expect(body["Env"] as? [String] == ["A=1", "B=2"])
        #expect((body["Labels"] as? [String: Any])?["e2e"] as? String == "1")
        #expect(body["WorkingDir"] as? String == "/tmp")
        #expect(body["Tty"] as? Bool == true)
        #expect(body["OpenStdin"] as? Bool == true)
        #expect(body["StopSignal"] as? String == "15")
        let host = body["HostConfig"] as? [String: Any] ?? [:]
        #expect(host["AutoRemove"] as? Bool == true)
        #expect(host["ReadonlyRootfs"] as? Bool == true)
        #expect(host["CapAdd"] as? [String] == ["NET_ADMIN"])
        #expect(host["Dns"] as? [String] == ["1.1.1.1"])
        #expect(host["ExtraHosts"] as? [String] == ["x:1.2.3.4"])
        #expect(host["Memory"] as? Int == 1024)
        #expect(host["CpuShares"] as? Int == 5)
        #expect(host["PidsLimit"] as? Int == 8)
        #expect(host["NetworkMode"] as? String == "default")
        #expect((host["RestartPolicy"] as? [String: Any])?["Name"] as? String == "on-failure")
        let ports = host["PortBindings"] as? [String: [[String: Any]]]
        #expect(ports?["80/tcp"]?.first?["HostPort"] as? String == "8080")
        let mounts = host["Mounts"] as? [[String: Any]] ?? []
        #expect(mounts.count == 2)
        #expect(mounts.first?["Type"] as? String == "bind")
        #expect(mounts.first?["ReadOnly"] as? Bool == true)
        #expect(mounts.last?["Type"] as? String == "volume")
        #expect(mounts.last?["Source"] as? String == "vol")
        let ulimit = (host["Ulimits"] as? [[String: Any]])?.first
        #expect(ulimit?["Name"] as? String == "nofile")
    }

    @Test("a tmpfs mount carries no source (podman sends one, Docker's create rejects it)")
    func tmpfsMount() {
        let mounts = LibpodSchema.dockerMounts(fromSpec: ["mounts": [["destination": "/scratch", "type": "tmpfs", "source": "tmpfs", "options": ["nosuid"]]]])
        #expect(mounts.count == 1)
        #expect(mounts.first?["Type"] as? String == "tmpfs")
        #expect(mounts.first?["Target"] as? String == "/scratch")
        #expect(mounts.first?["Source"] == nil)
    }

    @Test("a port range expands to one binding per port")
    func portRange() {
        let bindings = LibpodSchema.dockerPortBindings(fromSpec: ["portmappings": [["container_port": 80, "host_port": 9000, "range": 3, "protocol": "tcp"]]])
        #expect(Set(bindings.keys) == ["80/tcp", "81/tcp", "82/tcp"])
    }

    @Test("an empty protocol (a plain `podman run -p 8080:80`) means tcp")
    func emptyPortProtocol() {
        let bindings = LibpodSchema.dockerPortBindings(fromSpec: ["portmappings": [["container_port": 80, "host_port": 8080, "range": 1, "protocol": "", "host_ip": ""]]])
        #expect(Set(bindings.keys) == ["80/tcp"])
    }

    @Test("--platform in the spec becomes os/arch[/variant]")
    func platformFromSpec() {
        #expect(LibpodSchema.platform(fromSpec: ["image_os": "linux", "image_arch": "amd64"]) == "linux/amd64")
        #expect(LibpodSchema.platform(fromSpec: ["image_arch": "arm64", "image_variant": "v8"]) == "linux/arm64/v8")
        #expect(LibpodSchema.platform(fromSpec: ["image_os": "linux"]) == nil)
        #expect(LibpodSchema.platform(fromSpec: [:]) == nil)
    }

    @Test("a named network wins over the namespace mode")
    func networkMode() {
        #expect(LibpodSchema.dockerNetworkMode(fromSpec: ["Networks": ["mynet": [String: Any]()], "netns": ["nsmode": "bridge"]]) == "mynet")
        #expect(LibpodSchema.dockerNetworkMode(fromSpec: ["netns": ["nsmode": "none"]]) == "none")
        #expect(LibpodSchema.dockerNetworkMode(fromSpec: [:]) == nil)
    }
}
