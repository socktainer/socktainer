import CryptoKit
import Foundation
import Vapor

/// Pure translations from Docker-compat JSON bodies to the shapes the real podman client decodes
/// for `/libpod/*` endpoints (field names and types taken from podman's own
/// `pkg/domain/entities` and `libpod/define` structs).
enum LibpodSchema {
    // MARK: Containers

    static func rfc3339(unix seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    /// `[]ListContainer`: `Command` is an argv array and `Created` an RFC3339 time (Docker sends a
    /// joined string and a Unix integer), ports use libpod's own field names, and mounts are just
    /// destination paths.
    static func containerList(_ docker: Any?, startedAt: [String: Double] = [:]) -> Any {
        let items = docker as? [[String: Any]] ?? []
        return items.map { containerSummary($0, startedAt: startedAt[$0["Id"] as? String ?? ""]) }
    }

    /// `startedAt` is the container's start time (Unix seconds) when known: Docker's summary only
    /// carries a human-readable status, while podman computes "Up 2 hours" from `StartedAt`.
    static func containerSummary(_ docker: [String: Any], startedAt: Double? = nil) -> [String: Any] {
        let state = (docker["State"] as? String ?? "").lowercased()
        let created = (docker["Created"] as? NSNumber)?.doubleValue ?? 0
        let createdAt = rfc3339(unix: created)
        let command = (docker["Command"] as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let names = (docker["Names"] as? [String] ?? []).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        let imageID = (docker["ImageID"] as? String ?? "").replacingOccurrences(of: "sha256:", with: "")
        let mounts = (docker["Mounts"] as? [[String: Any]] ?? []).compactMap { $0["Destination"] as? String }
        let networks = ((docker["NetworkSettings"] as? [String: Any])?["Networks"] as? [String: Any])?.keys.sorted() ?? []
        let ports: [[String: Any]] = (docker["Ports"] as? [[String: Any]] ?? []).map { port in
            [
                "host_ip": port["IP"] as? String ?? "",
                "container_port": port["PrivatePort"] as? Int ?? 0,
                "host_port": port["PublicPort"] as? Int ?? 0,
                "range": 1,
                "protocol": port["Type"] as? String ?? "tcp",
            ]
        }
        return [
            "AutoRemove": false,
            "Command": command,
            "Created": createdAt,
            "CreatedAt": createdAt,
            "CIDFile": "",
            "Exited": state == "exited",
            // Apple Container keeps no separate stop time; the start time is the closest known.
            "ExitedAt": state == "exited" ? Int(startedAt ?? created) : 0,
            "ExitCode": 0,
            "Id": docker["Id"] as? String ?? "",
            "Image": docker["Image"] as? String ?? "",
            "ImageID": imageID,
            "IsInfra": false,
            "Labels": docker["Labels"] as? [String: Any] ?? [:],
            "Mounts": mounts,
            "Names": names,
            "Namespaces": [String: Any](),
            "Networks": networks,
            "Pid": 0,
            "Pod": "",
            "PodName": "",
            "Ports": ports,
            "Restarts": 0,
            "StartedAt": Int(startedAt ?? 0),
            "State": state,
            // Podman renders "Up 2 hours" itself from `State`/`StartedAt`; this field only carries
            // the health state it appends in parentheses, not Docker's already-rendered text.
            "Status": healthStatus(fromDockerStatus: docker["Status"] as? String ?? ""),
        ]
    }

    /// podman's `InspectContainerData`: names carry no leading slash and every timestamp must be a
    /// valid RFC3339 time (Docker leaves `StartedAt` empty for a container that never ran).
    static func containerInspect(_ docker: Any?) -> Any {
        guard var inspect = docker as? [String: Any] else { return docker ?? [String: Any]() }
        if let name = inspect["Name"] as? String, name.hasPrefix("/") { inspect["Name"] = String(name.dropFirst()) }
        if var state = inspect["State"] as? [String: Any] {
            for key in ["StartedAt", "FinishedAt"] where (state[key] as? String ?? "").isEmpty || (state[key] as? String)?.hasPrefix("1970-01-01") == true {
                state[key] = "0001-01-01T00:00:00Z"
            }
            inspect["State"] = state
        }
        if let image = inspect["Image"] as? String { inspect["ImageName"] = image }
        return inspect
    }

    /// podman's image inspect carries bare hex ids (Docker's keep the `sha256:` prefix) and a top-level `Labels`.
    static func imageInspect(_ docker: Any?) -> Any {
        guard var inspect = docker as? [String: Any] else { return docker ?? [String: Any]() }
        for key in ["Id", "Parent"] {
            if let value = inspect[key] as? String { inspect[key] = value.replacingOccurrences(of: "sha256:", with: "") }
        }
        // podman's `ImageData` carries the labels at the top level as well as under `Config`.
        if inspect["Labels"] is NSNull || inspect["Labels"] == nil {
            inspect["Labels"] = (inspect["Config"] as? [String: Any])?["Labels"] ?? [String: Any]()
        }
        return inspect
    }

    /// `[]ImageSummary`: ids are bare hex (no `sha256:`), and podman's own `Names` mirrors `RepoTags`.
    static func imageList(_ docker: Any?) -> Any {
        (docker as? [[String: Any]] ?? []).map { image in
            var summary = image
            for key in ["Id", "ParentId"] {
                if let value = image[key] as? String { summary[key] = value.replacingOccurrences(of: "sha256:", with: "") }
            }
            summary["Names"] = image["RepoTags"] as? [String] ?? []
            summary["IsManifestList"] = false
            return summary
        }
    }

    /// "Up 2 hours (healthy)" → "healthy"; empty when the container has no health state.
    static func healthStatus(fromDockerStatus status: String) -> String {
        for health in ["unhealthy", "healthy"] where status.contains("(\(health))") {
            return health
        }
        return status.contains("(health: starting)") ? "starting" : ""
    }

    /// `[]RmReport` — libpod answers 200 with one report per removed container, where Docker
    /// answers 204 with no body.
    static func containerRemoveReports(id: String) -> Any {
        [["Id": id]]
    }

    // MARK: Container create

    /// Podman's `SpecGenerator` (what `podman create`/`run` posts) → a Docker create body.
    /// Fields the Docker-compat create path has no equivalent for are left out.
    static func dockerContainerCreateBody(fromSpec spec: [String: Any]) -> [String: Any] {
        var body: [String: Any] = ["Image": spec["image"] as? String ?? ""]
        if let command = spec["command"] as? [String] { body["Cmd"] = command }
        if let entrypoint = spec["entrypoint"] as? [String] { body["Entrypoint"] = entrypoint }
        if let env = spec["env"] as? [String: Any] {
            body["Env"] = env.keys.sorted().map { "\($0)=\(env[$0] as? String ?? "")" }
        }
        if let labels = spec["labels"] as? [String: Any], !labels.isEmpty { body["Labels"] = labels }
        if let workDir = spec["work_dir"] as? String, !workDir.isEmpty { body["WorkingDir"] = workDir }
        if let user = spec["user"] as? String, !user.isEmpty { body["User"] = user }
        if let hostname = spec["hostname"] as? String, !hostname.isEmpty { body["Hostname"] = hostname }
        if let terminal = spec["terminal"] as? Bool { body["Tty"] = terminal }
        if let stdin = spec["stdin"] as? Bool { body["OpenStdin"] = stdin }
        // Podman sends the stop signal as its numeric value; Docker takes a name or number string.
        if let signal = spec["stop_signal"] as? NSNumber, signal.intValue > 0 { body["StopSignal"] = String(signal.intValue) }
        if let timeout = spec["stop_timeout"] as? NSNumber { body["StopTimeout"] = timeout }
        if let health = spec["healthconfig"] as? [String: Any], !health.isEmpty { body["Healthcheck"] = health }

        var host: [String: Any] = [:]
        if let remove = spec["remove"] as? Bool { host["AutoRemove"] = remove }
        let mounts = dockerMounts(fromSpec: spec)
        if !mounts.isEmpty { host["Mounts"] = mounts }
        let ports = dockerPortBindings(fromSpec: spec)
        if !ports.isEmpty { host["PortBindings"] = ports }
        if let publishAll = spec["publish_image_ports"] as? Bool { host["PublishAllPorts"] = publishAll }
        if let networkMode = dockerNetworkMode(fromSpec: spec) { host["NetworkMode"] = networkMode }
        if let dns = spec["dns_server"] as? [String], !dns.isEmpty { host["Dns"] = dns }
        if let search = spec["dns_search"] as? [String], !search.isEmpty { host["DnsSearch"] = search }
        if let options = spec["dns_option"] as? [String], !options.isEmpty { host["DnsOptions"] = options }
        if let hosts = spec["hostadd"] as? [String], !hosts.isEmpty { host["ExtraHosts"] = hosts }
        if let add = spec["cap_add"] as? [String], !add.isEmpty { host["CapAdd"] = add }
        if let drop = spec["cap_drop"] as? [String], !drop.isEmpty { host["CapDrop"] = drop }
        if let privileged = spec["privileged"] as? Bool { host["Privileged"] = privileged }
        if let readOnly = spec["read_only_filesystem"] as? Bool { host["ReadonlyRootfs"] = readOnly }
        if let initProcess = spec["init"] as? Bool { host["Init"] = initProcess }
        if let sysctl = spec["sysctl"] as? [String: Any], !sysctl.isEmpty { host["Sysctls"] = sysctl }
        if let shm = spec["shm_size"] as? NSNumber { host["ShmSize"] = shm }
        if let groups = spec["groups"] as? [String], !groups.isEmpty { host["GroupAdd"] = groups }
        if let policy = spec["restart_policy"] as? String, !policy.isEmpty {
            host["RestartPolicy"] = ["Name": policy, "MaximumRetryCount": (spec["restart_tries"] as? NSNumber) ?? 0] as [String: Any]
        }
        if let limits = spec["r_limits"] as? [[String: Any]], !limits.isEmpty {
            host["Ulimits"] = limits.compactMap { limit -> [String: Any]? in
                guard let type = limit["type"] as? String else { return nil }
                let name = type.lowercased().replacingOccurrences(of: "rlimit_", with: "")
                return ["Name": name, "Soft": limit["soft"] ?? 0, "Hard": limit["hard"] ?? 0]
            }
        }
        if let resources = spec["resource_limits"] as? [String: Any] {
            let memory = resources["memory"] as? [String: Any] ?? [:]
            if let limit = memory["limit"] { host["Memory"] = limit }
            if let reservation = memory["reservation"] { host["MemoryReservation"] = reservation }
            if let swap = memory["swap"] { host["MemorySwap"] = swap }
            let cpu = resources["cpu"] as? [String: Any] ?? [:]
            if let shares = cpu["shares"] { host["CpuShares"] = shares }
            if let quota = cpu["quota"] { host["CpuQuota"] = quota }
            if let period = cpu["period"] { host["CpuPeriod"] = period }
            if let cpus = cpu["cpus"] as? String, !cpus.isEmpty { host["CpusetCpus"] = cpus }
            if let mems = cpu["mems"] as? String, !mems.isEmpty { host["CpusetMems"] = mems }
            if let limit = (resources["pids"] as? [String: Any])?["limit"] { host["PidsLimit"] = limit }
        }
        if !host.isEmpty { body["HostConfig"] = host }
        return body
    }

    /// `os/arch[/variant]` from the spec's `image_os`/`image_arch`/`image_variant`, if a platform was requested.
    static func platform(fromSpec spec: [String: Any]) -> String? {
        let arch = spec["image_arch"] as? String ?? ""
        guard !arch.isEmpty else { return nil }
        let os = (spec["image_os"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "linux"
        let variant = spec["image_variant"] as? String ?? ""
        return variant.isEmpty ? "\(os)/\(arch)" : "\(os)/\(arch)/\(variant)"
    }

    /// `mounts` (OCI mounts) and `volumes` (named volumes) → Docker `HostConfig.Mounts`.
    static func dockerMounts(fromSpec spec: [String: Any]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for mount in spec["mounts"] as? [[String: Any]] ?? [] {
            guard let target = mount["destination"] as? String else { continue }
            let options = mount["options"] as? [String] ?? []
            var entry: [String: Any] = ["Type": mount["type"] as? String ?? "bind", "Target": target]
            // podman sends `source: "tmpfs"` for a tmpfs mount; Docker's create rejects any source there.
            if entry["Type"] as? String != "tmpfs", let source = mount["source"] as? String { entry["Source"] = source }
            if options.contains("ro") || options.contains("readonly") { entry["ReadOnly"] = true }
            result.append(entry)
        }
        for volume in spec["volumes"] as? [[String: Any]] ?? [] {
            guard let name = volume["Name"] as? String, let destination = volume["Dest"] as? String else { continue }
            let options = volume["Options"] as? [String] ?? []
            var entry: [String: Any] = ["Type": "volume", "Source": name, "Target": destination]
            if options.contains("ro") { entry["ReadOnly"] = true }
            result.append(entry)
        }
        return result
    }

    /// `portmappings` → Docker `PortBindings`, expanding `range` into one entry per port.
    static func dockerPortBindings(fromSpec spec: [String: Any]) -> [String: Any] {
        var result: [String: [[String: Any]]] = [:]
        for mapping in spec["portmappings"] as? [[String: Any]] ?? [] {
            guard let container = (mapping["container_port"] as? NSNumber)?.intValue else { continue }
            let host = (mapping["host_port"] as? NSNumber)?.intValue ?? 0
            let count = max((mapping["range"] as? NSNumber)?.intValue ?? 1, 1)
            for offset in 0..<count {
                // podman sends an empty protocol for a plain `-p host:container` (meaning tcp).
                let requested = mapping["protocol"] as? String ?? ""
                let proto = requested.isEmpty ? "tcp" : requested
                for protocolName in proto.split(separator: ",") {
                    let key = "\(container + offset)/\(protocolName)"
                    result[key, default: []].append(["HostIp": mapping["host_ip"] as? String ?? "", "HostPort": host == 0 ? "" : String(host + offset)])
                }
            }
        }
        return result
    }

    /// The first named network, else the namespace mode (`bridge` is the default network).
    static func dockerNetworkMode(fromSpec spec: [String: Any]) -> String? {
        if let networks = spec["Networks"] as? [String: Any], let first = (spec["networkOrder"] as? [String])?.first ?? networks.keys.sorted().first {
            return first
        }
        switch (spec["netns"] as? [String: Any])?["nsmode"] as? String {
        case "none": return "none"
        case "host": return "host"
        case "bridge", "private": return "default"
        default: return nil
        }
    }

    /// Podman's update call: the restart policy travels as `restartPolicy`/`restartRetries` query
    /// parameters and the resources as an OCI `LinuxResources` body. → Docker's update body.
    static func dockerContainerUpdateBody(fromLibpod body: [String: Any], restartPolicy: String?, restartRetries: Int?) -> [String: Any] {
        var docker: [String: Any] = [:]
        if let restartPolicy, !restartPolicy.isEmpty {
            docker["RestartPolicy"] = ["Name": restartPolicy, "MaximumRetryCount": restartRetries ?? 0] as [String: Any]
        }
        let memory = body["memory"] as? [String: Any] ?? [:]
        if let limit = memory["limit"] { docker["Memory"] = limit }
        if let swap = memory["swap"] { docker["MemorySwap"] = swap }
        if let reservation = memory["reservation"] { docker["MemoryReservation"] = reservation }
        let cpu = body["cpu"] as? [String: Any] ?? [:]
        if let shares = cpu["shares"] { docker["CpuShares"] = shares }
        if let period = cpu["period"] { docker["CpuPeriod"] = period }
        if let quota = cpu["quota"] { docker["CpuQuota"] = quota }
        if let cpus = cpu["cpus"] { docker["CpusetCpus"] = cpus }
        if let limit = (body["pids"] as? [String: Any])?["limit"] { docker["PidsLimit"] = limit }
        if let weight = (body["blockIO"] as? [String: Any])?["weight"] { docker["BlkioWeight"] = weight }
        return docker
    }

    /// podman's `define.ContainerStats` from one Docker stats sample. CPU is computed as Docker does
    /// (container CPU delta over system CPU delta, scaled by the online CPUs).
    static func containerStats(_ docker: [String: Any], containerID: String) -> [String: Any] {
        let cpu = docker["cpu_stats"] as? [String: Any] ?? [:]
        let previous = docker["precpu_stats"] as? [String: Any] ?? [:]
        func total(_ stats: [String: Any]) -> Double { Double(int((stats["cpu_usage"] as? [String: Any])?["total_usage"])) }
        func system(_ stats: [String: Any]) -> Double { Double(int(stats["system_cpu_usage"])) }
        let cpuDelta = total(cpu) - total(previous)
        let systemDelta = system(cpu) - system(previous)
        let online = max(Double(int(cpu["online_cpus"])), 1)
        let cpuPercent = systemDelta > 0 && cpuDelta > 0 ? cpuDelta / systemDelta * online * 100 : 0

        let memory = docker["memory_stats"] as? [String: Any] ?? [:]
        let usage = int(memory["usage"])
        let limit = int(memory["limit"])

        var network: [String: Any] = [:]
        for (name, value) in docker["networks"] as? [String: Any] ?? [:] {
            let stats = value as? [String: Any] ?? [:]
            network[name] = [
                "RxBytes": int(stats["rx_bytes"]), "RxDropped": int(stats["rx_dropped"]), "RxErrors": int(stats["rx_errors"]),
                "RxPackets": int(stats["rx_packets"]), "TxBytes": int(stats["tx_bytes"]), "TxDropped": int(stats["tx_dropped"]),
                "TxErrors": int(stats["tx_errors"]), "TxPackets": int(stats["tx_packets"]),
            ]
        }
        var blockInput = 0
        var blockOutput = 0
        let entries = (docker["blkio_stats"] as? [String: Any])?["io_service_bytes_recursive"] as? [[String: Any]] ?? []
        for entry in entries {
            switch (entry["op"] as? String ?? "").lowercased() {
            case "read": blockInput += int(entry["value"])
            case "write": blockOutput += int(entry["value"])
            default: break
            }
        }
        let name = docker["name"] as? String ?? ""
        return [
            "AvgCPU": cpuPercent, "ContainerID": containerID, "Name": name.hasPrefix("/") ? String(name.dropFirst()) : name,
            "CPU": cpuPercent, "CPUNano": Int(total(cpu)), "CPUSystemNano": Int(system(cpu)), "SystemNano": Int(Date().timeIntervalSince1970 * 1e9),
            "MemUsage": usage, "MemLimit": limit, "MemPerc": limit > 0 ? Double(usage) / Double(limit) * 100 : 0,
            "Network": network, "BlockInput": blockInput, "BlockOutput": blockOutput,
            "PIDs": int((docker["pids_stats"] as? [String: Any])?["current"]), "UpTime": 0, "Duration": 1_000_000_000,
        ] as [String: Any]
    }

    // MARK: Prune

    /// `podman volume prune` removes every unused volume; Docker-compat's prune only removes
    /// anonymous ones unless its `all` filter is true. Returns podman's `filters` JSON with
    /// `all=true` added when the caller did not say otherwise. A non-empty `filters` that is not
    /// a JSON object is rejected (as real podman does) rather than dropped: dropping it would
    /// turn a filtered prune into "prune every unused volume".
    static func volumePruneFilters(_ filters: String?) throws -> String {
        var parsed: [String: Any] = [:]
        if let filters, !filters.isEmpty {
            guard let data = filters.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw Abort(.badRequest, reason: "Invalid filters: \(filters)")
            }
            parsed = decoded
        }
        if parsed["all"] == nil { parsed["all"] = ["true"] }
        let data = (try? JSONSerialization.data(withJSONObject: parsed)) ?? Data("{\"all\":[\"true\"]}".utf8)
        return String(data: data, encoding: .utf8) ?? "{\"all\":[\"true\"]}"
    }

    /// `[]PruneReport` (`Id`, optional `Err`, `Size`). The reclaimed total is attributed to the
    /// first report since Docker's response carries no per-item size.
    static func pruneReports(ids: [String], spaceReclaimed: Int) -> Any {
        ids.enumerated().map { index, id in
            ["Id": id, "Size": index == 0 ? max(spaceReclaimed, 0) : 0] as [String: Any]
        }
    }

    static func containerPruneReports(_ docker: Any?) -> Any {
        let body = docker as? [String: Any] ?? [:]
        return pruneReports(ids: body["ContainersDeleted"] as? [String] ?? [], spaceReclaimed: (body["SpaceReclaimed"] as? NSNumber)?.intValue ?? 0)
    }

    static func volumePruneReports(_ docker: Any?) -> Any {
        let body = docker as? [String: Any] ?? [:]
        return pruneReports(ids: body["VolumesDeleted"] as? [String] ?? [], spaceReclaimed: (body["SpaceReclaimed"] as? NSNumber)?.intValue ?? 0)
    }

    static func imagePruneReports(_ docker: Any?) -> Any {
        let body = docker as? [String: Any] ?? [:]
        let ids = (body["ImagesDeleted"] as? [[String: Any]] ?? []).compactMap { ($0["Deleted"] ?? $0["Untagged"]) as? String }
        return pruneReports(ids: ids, spaceReclaimed: (body["SpaceReclaimed"] as? NSNumber)?.intValue ?? 0)
    }

    /// `[]NetworkPruneReport` (`Name`, `Error`).
    static func networkPruneReports(_ docker: Any?) -> Any {
        let body = docker as? [String: Any] ?? [:]
        return (body["NetworksDeleted"] as? [String] ?? []).map { ["Name": $0, "Error": NSNull()] as [String: Any] }
    }

    /// `[]NetworkRmReport` (`Name`, `Err`).
    static func networkRemoveReports(name: String) -> Any {
        [["Name": name, "Err": NSNull()]]
    }

    // MARK: System

    private static func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

    /// podman's `define.Info` from Docker's flat `/info` body.
    static func info(_ docker: Any?) -> Any {
        let d = docker as? [String: Any] ?? [:]
        let arch = (d["Architecture"] as? String).map { $0 == "aarch64" ? "arm64" : $0 } ?? "arm64"
        let root = d["DockerRootDir"] as? String ?? ""
        return [
            "host": [
                "arch": arch,
                "hostname": d["Name"] as? String ?? "",
                "kernel": d["KernelVersion"] as? String ?? "",
                "os": "linux",
                "cpus": int(d["NCPU"]),
                "memTotal": int(d["MemTotal"]),
                "serviceIsRemote": true,
                "buildahVersion": "",
                "ociRuntime": ["name": "apple-container", "package": "", "path": "", "version": d["ServerVersion"] as? String ?? ""],
                "distribution": ["distribution": "apple-container", "version": d["ServerVersion"] as? String ?? ""],
            ] as [String: Any],
            "store": [
                "graphDriverName": "apple-container",
                "graphRoot": root,
                "runRoot": root,
                "volumePath": root + "/volumes",
                "containerStore": [
                    "number": int(d["Containers"]), "running": int(d["ContainersRunning"]),
                    "paused": int(d["ContainersPaused"]), "stopped": int(d["ContainersStopped"]),
                ],
                "imageStore": ["number": int(d["Images"])],
            ] as [String: Any],
            "registries": [String: Any](),
            "plugins": ["volume": ["local"], "network": ["bridge"], "log": ["json-file"], "authorization": [String]()] as [String: Any],
            "version": [
                "APIVersion": "1.51", "Version": d["ServerVersion"] as? String ?? "", "GoVersion": "N/A", "GitCommit": "",
                "BuiltTime": "", "Built": 0, "OsArch": "linux/\(arch)", "Os": "linux",
            ] as [String: Any],
        ] as [String: Any]
    }

    /// podman's `SystemDfReport` from Docker's `/system/df` body.
    static func systemDF(_ docker: Any?) -> Any {
        let d = docker as? [String: Any] ?? [:]
        let images: [[String: Any]] = (d["Images"] as? [[String: Any]] ?? []).map { image in
            let tag = (image["RepoTags"] as? [String])?.first ?? ""
            var repository = "<none>"
            var version = "<none>"
            if let colon = tag.lastIndex(of: ":"), !tag[colon...].contains("/") {
                repository = String(tag[..<colon])
                version = String(tag[tag.index(after: colon)...])
            } else if !tag.isEmpty {
                repository = tag
            }
            let size = int(image["Size"])
            let shared = max(int(image["SharedSize"]), 0)
            return [
                "Repository": repository, "Tag": version,
                "ImageID": (image["Id"] as? String ?? "").replacingOccurrences(of: "sha256:", with: ""),
                "Created": rfc3339(unix: Double(int(image["Created"]))),
                "Size": size, "SharedSize": shared, "UniqueSize": max(size - shared, 0),
                "Containers": max(int(image["Containers"]), 0),
            ]
        }
        let containers: [[String: Any]] = (d["Containers"] as? [[String: Any]] ?? []).map { container in
            let name = (container["Names"] as? [String])?.first ?? ""
            return [
                "ContainerID": container["Id"] as? String ?? "",
                "Image": container["Image"] as? String ?? "",
                "Command": (container["Command"] as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init),
                "LocalVolumes": 0,
                "Size": max(int(container["SizeRootFs"]), 0), "RWSize": max(int(container["SizeRw"]), 0),
                "Created": rfc3339(unix: Double(int(container["Created"]))),
                "Status": container["Status"] as? String ?? "",
                "Names": name.hasPrefix("/") ? String(name.dropFirst()) : name,
            ]
        }
        let volumes: [[String: Any]] = (d["Volumes"] as? [[String: Any]] ?? []).map { volume in
            let usage = volume["UsageData"] as? [String: Any] ?? [:]
            let size = max(int(usage["Size"]), 0)
            let links = max(int(usage["RefCount"]), 0)
            return ["VolumeName": volume["Name"] as? String ?? "", "Links": links, "Size": size, "ReclaimableSize": links == 0 ? size : 0]
        }
        return ["ImagesSize": int(d["LayersSize"]), "Images": images, "Containers": containers, "Volumes": volumes] as [String: Any]
    }

    // MARK: Images

    /// podman's `LibpodImagesRemoveReport`: what was untagged and deleted, the per-image error
    /// messages, and the `podman rmi` exit code (1 = not found, 2 = in use / conflict, 125 = other).
    static func imageRemoveReport(untagged: [String], deleted: [String], errors: [String], exitCode: Int) -> [String: Any] {
        [
            "Untagged": untagged,
            "Deleted": deleted.map { $0.replacingOccurrences(of: "sha256:", with: "") },
            "Errors": errors,
            "ExitCode": exitCode,
        ]
    }

    static func imageRemoveExitCode(for status: UInt) -> Int {
        switch status {
        case 404: return 1
        case 409: return 2
        default: return 125
        }
    }

    // MARK: Volumes

    /// `VolumeConfigResponse` (podman's `InspectVolumeData`).
    static func volume(_ docker: [String: Any]) -> [String: Any] {
        [
            "Name": docker["Name"] as? String ?? "",
            "Driver": docker["Driver"] as? String ?? "local",
            "Mountpoint": docker["Mountpoint"] as? String ?? "",
            "CreatedAt": docker["CreatedAt"] as? String ?? "1970-01-01T00:00:00Z",
            "Status": docker["Status"] as? [String: Any] ?? [:],
            "Labels": docker["Labels"] as? [String: Any] ?? [:],
            "Scope": docker["Scope"] as? String ?? "local",
            "Options": docker["Options"] as? [String: Any] ?? [:],
            "UID": 0,
            "GID": 0,
            "MountCount": 0,
            "NeedsCopyUp": false,
            "NeedsChown": false,
            "LockNumber": 0,
        ]
    }

    /// Docker wraps volumes as `{Volumes: [...], Warnings: [...]}`; libpod returns the bare array.
    static func volumeList(_ docker: Any?) -> Any {
        let body = docker as? [String: Any] ?? [:]
        return (body["Volumes"] as? [[String: Any]] ?? []).map(volume)
    }

    static func volumeObject(_ docker: Any?) -> Any {
        volume(docker as? [String: Any] ?? [:])
    }

    /// Podman's `VolumeCreateOptions` (`Label`/`Labels`, `Options`) → Docker's create body
    /// (`Labels`, `DriverOpts`). `Labels` wins over the compatibility `Label`, as in podman.
    static func dockerVolumeCreateBody(fromLibpod body: [String: Any]) -> [String: Any] {
        var docker: [String: Any] = [:]
        if let name = body["Name"] as? String { docker["Name"] = name }
        if let driver = body["Driver"] as? String, !driver.isEmpty { docker["Driver"] = driver }
        var labels = body["Label"] as? [String: Any] ?? [:]
        for (key, value) in body["Labels"] as? [String: Any] ?? [:] { labels[key] = value }
        if !labels.isEmpty { docker["Labels"] = labels }
        if let options = body["Options"] as? [String: Any], !options.isEmpty { docker["DriverOpts"] = options }
        return docker
    }

    // MARK: Networks

    /// podman's `types.Network` from a Docker network summary.
    static func network(_ docker: [String: Any]) -> [String: Any] {
        let config = (docker["IPAM"] as? [String: Any])?["Config"] as? [[String: Any]] ?? []
        let subnets: [[String: Any]] = config.compactMap { entry in
            guard let subnet = entry["Subnet"] as? String else { return nil }
            var result: [String: Any] = ["subnet": subnet]
            if let gateway = entry["Gateway"] as? String { result["gateway"] = gateway }
            return result
        }
        let name = docker["Name"] as? String ?? ""
        return [
            "name": name,
            "id": networkID(name),
            "driver": docker["Driver"] as? String ?? "bridge",
            "network_interface": "",
            "created": docker["Created"] as? String ?? "1970-01-01T00:00:00Z",
            "subnets": subnets,
            "ipv6_enabled": docker["EnableIPv6"] as? Bool ?? false,
            "internal": docker["Internal"] as? Bool ?? false,
            "dns_enabled": true,
            "labels": docker["Labels"] as? [String: Any] ?? [:],
            "options": docker["Options"] as? [String: Any] ?? [:],
            "ipam_options": [String: Any](),
        ]
    }

    /// Apple Container names networks by a short id (`default`); podman slices the first 12
    /// characters of a 64-hex id for display, so expose a stable hash of the name instead.
    static func networkID(_ name: String) -> String {
        SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Podman's `types.Network` answer to a create request, from the request that created it.
    static func networkCreated(fromLibpod body: [String: Any]) -> [String: Any] {
        let name = body["name"] as? String ?? ""
        return [
            "name": name,
            "id": networkID(name),
            "driver": (body["driver"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "bridge",
            "network_interface": "",
            "created": ISO8601DateFormatter().string(from: Date()),
            "subnets": body["subnets"] as? [[String: Any]] ?? [],
            "ipv6_enabled": body["ipv6_enabled"] as? Bool ?? false,
            "internal": body["internal"] as? Bool ?? false,
            "dns_enabled": true,
            "labels": body["labels"] as? [String: Any] ?? [:],
            "options": body["options"] as? [String: Any] ?? [:],
            "ipam_options": [String: Any](),
        ]
    }

    static func networkList(_ docker: Any?) -> Any {
        (docker as? [[String: Any]] ?? []).map(network)
    }

    /// `NetworkInspectReport`: the network plus the containers attached to it.
    static func networkInspect(_ docker: Any?) -> Any {
        let source = docker as? [String: Any] ?? [:]
        var report = network(source)
        var containers: [String: Any] = [:]
        for (id, value) in source["Containers"] as? [String: Any] ?? [:] {
            let name = (value as? [String: Any])?["Name"] as? String ?? id
            containers[id] = ["name": name, "interfaces": [String: Any]()]
        }
        report["containers"] = containers
        return report
    }

    /// Podman's `types.Network` create body (lower-case keys) → Docker's `NetworksCreateQuery`.
    static func dockerNetworkCreateBody(fromLibpod body: [String: Any]) -> [String: Any] {
        var docker: [String: Any] = ["Name": body["name"] as? String ?? ""]
        if let driver = body["driver"] as? String, !driver.isEmpty { docker["Driver"] = driver }
        if let internalOnly = body["internal"] as? Bool { docker["Internal"] = internalOnly }
        if let labels = body["labels"] as? [String: Any], !labels.isEmpty { docker["Labels"] = labels }
        if let options = body["options"] as? [String: Any], !options.isEmpty { docker["Options"] = options }
        let subnets = body["subnets"] as? [[String: Any]] ?? []
        let config: [[String: Any]] = subnets.compactMap { entry in
            guard let subnet = entry["subnet"] as? String else { return nil }
            var result: [String: Any] = ["Subnet": subnet]
            if let gateway = entry["gateway"] as? String { result["Gateway"] = gateway }
            return result
        }
        // Docker's `IPAM` object requires its `Driver` (the create handler decodes it as non-optional).
        if !config.isEmpty { docker["IPAM"] = ["Driver": "default", "Config": config] as [String: Any] }
        return docker
    }
}
