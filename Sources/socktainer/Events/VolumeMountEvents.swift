import ContainerResource

/// Emits moby's per-volume `mount`/`unmount` events for a container's named-volume
/// mounts (moby daemon/volumes_unix.go and container.UnmountVolumes). `containerId`
/// is the canonical 64-char Docker id, matching moby's full `c.ID` attribute.
/// Propagation has no equivalent on Apple Container and is reported as "" — the
/// same value the inspect route uses.
enum VolumeMountEvents {
    static func broadcastMounts(for snapshot: ContainerSnapshot, containerId: String, broadcaster: EventBroadcaster) async {
        for mount in volumeMounts(in: snapshot) {
            guard case .volume(let name, _, _, _) = mount.type else { continue }
            await broadcaster.broadcast(
                DockerEvent.make(
                    type: "volume", action: "mount", actorID: name,
                    attributes: [
                        "driver": "local",
                        "container": containerId,
                        "destination": mount.destination,
                        "read/write": String(!mount.options.readonly),
                        "propagation": "",
                    ]))
        }
    }

    static func broadcastUnmounts(for snapshot: ContainerSnapshot, containerId: String, broadcaster: EventBroadcaster) async {
        for mount in volumeMounts(in: snapshot) {
            guard case .volume(let name, _, _, _) = mount.type else { continue }
            await broadcaster.broadcast(
                DockerEvent.make(
                    type: "volume", action: "unmount", actorID: name,
                    attributes: [
                        "driver": "local",
                        "container": containerId,
                    ]))
        }
    }

    private static func volumeMounts(in snapshot: ContainerSnapshot) -> [Filesystem] {
        snapshot.configuration.mounts.filter {
            if case .volume = $0.type { return true }
            return false
        }
    }
}
