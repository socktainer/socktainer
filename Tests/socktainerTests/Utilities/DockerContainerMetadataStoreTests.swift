import ContainerResource
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

@Suite("Docker container metadata registry")
struct DockerContainerMetadataStoreTests {
    private func port(_ host: UInt16) throws -> PublishPort {
        try PublishPort(
            hostAddress: IPAddress("127.0.0.1"), hostPort: host,
            containerPort: 5432, proto: .tcp, count: 1
        )
    }

    @Test("rename preserves immutable native identity and published ports across reload")
    func renameRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("socktainer-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DockerContainerMetadataStore()
        try await store.configure(storageDirectory: directory)
        try await store.set(nativeID: "native-tmp", name: "compose-tmp", publishedPorts: [port(55432)])
        let renamed = try await store.rename(
            nativeID: "native-tmp", to: "postgres", existingNativeIDs: ["native-tmp"]
        )
        #expect(renamed.old == "compose-tmp")
        #expect(renamed.new == "postgres")

        let reloaded = DockerContainerMetadataStore()
        try await reloaded.configure(storageDirectory: directory)
        #expect(await reloaded.name(nativeID: "native-tmp") == "postgres")
        #expect(await reloaded.ports(nativeID: "native-tmp").first?.hostPort == 55432)
        #expect(try await reloaded.nativeID(named: "/postgres", existingNativeIDs: ["native-tmp"]) == "native-tmp")
    }

    @Test("concurrent renames preserve true name conflicts")
    func concurrentConflict() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("socktainer-metadata-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockerContainerMetadataStore()
        try await store.configure(storageDirectory: directory)
        try await store.set(nativeID: "one", name: "one", publishedPorts: [])
        try await store.set(nativeID: "two", name: "two", publishedPorts: [])

        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for id in ["one", "two"] {
                group.addTask {
                    do {
                        _ = try await store.rename(nativeID: id, to: "winner", existingNativeIDs: ["one", "two"])
                        return true
                    } catch { return false }
                }
            }
            var result: [Bool] = []
            for await value in group { result.append(value) }
            return result
        }
        #expect(outcomes.filter { $0 }.count == 1)
    }

    @Test("concurrent renames publish only the final DNS owner")
    func concurrentSameContainerDNS() async throws {
        let store = DockerContainerMetadataStore()
        let dns = SocktainerDNSServer()
        let ip = "192.168.65.44"
        try await store.set(nativeID: "st-db", name: "old-db", publishedPorts: [])
        dns.register(hostname: "old-db", ip: ip)

        await withTaskGroup(of: Void.self) { group in
            for name in ["renamed-a", "renamed-b"] {
                group.addTask {
                    _ = try? await store.rename(
                        nativeID: "st-db",
                        to: name,
                        existingNativeIDs: ["st-db"],
                        onCommit: { oldName, newName in
                            dns.unregisterIfOwned(hostname: oldName, expectedIP: ip)
                            dns.register(hostname: newName, ip: ip)
                        }
                    )
                }
            }
        }

        let finalName = await store.name(nativeID: "st-db")
        #expect(Set(dns.listEntries().keys) == [finalName])
        #expect(dns.listEntries()[finalName] == ip)
    }

    @Test("concurrent creates serialize name ownership before native publication")
    func concurrentReservations() async throws {
        let store = DockerContainerMetadataStore()
        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do {
                        _ = try await store.reserve(name: "postgres", existingNativeIDs: [])
                        return true
                    } catch { return false }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        #expect(outcomes.filter { $0 }.count == 1)
    }

    @Test("legacy adoption never duplicates canonical Docker name ownership")
    func adoptionConflict() async throws {
        let store = DockerContainerMetadataStore()
        try await store.set(
            nativeID: "st-managed",
            name: "legacy-db",
            publishedPorts: []
        )

        try await store.adopt(
            nativeID: "legacy-db",
            name: "legacy-db",
            publishedPorts: []
        )

        #expect(await store.name(nativeID: "st-managed") == "legacy-db")
        #expect(await store.name(nativeID: "legacy-db") == "legacy-db-native")
        #expect(
            try await store.nativeID(
                named: "legacy-db",
                existingNativeIDs: ["st-managed", "legacy-db"]
            ) == "st-managed"
        )
        #expect(
            try await store.nativeID(
                named: "legacy-db-native",
                existingNativeIDs: ["st-managed", "legacy-db"]
            ) == "legacy-db"
        )
    }

    @Test("pending native create survives an immediate restart reconciliation")
    func pendingCreateReconciliation() async throws {
        let store = DockerContainerMetadataStore()
        let reservation = try await store.reserve(name: "postgres", existingNativeIDs: [])
        try await store.commit(
            reservation: reservation,
            nativeID: "st-pending",
            publishedPorts: [port(55435)]
        )

        try await store.reconcile(existingNativeIDs: [])
        #expect(await store.name(nativeID: "st-pending") == "postgres")

        try await store.reconcile(existingNativeIDs: ["st-pending"])
        #expect(await store.entry(nativeID: "st-pending")?.pendingSince == nil)
        let missingAt = Date()
        try await store.reconcile(existingNativeIDs: [], now: missingAt)
        #expect(await store.entry(nativeID: "st-pending") != nil)
        try await store.reconcile(
            existingNativeIDs: [],
            now: missingAt.addingTimeInterval(10 * 60 + 1)
        )
        #expect(await store.entry(nativeID: "st-pending") == nil)
    }

    @Test("auto-remove intent survives daemon reload and rename")
    func autoRemovePersistence() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("socktainer-metadata-autoremove-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = DockerContainerMetadataStore()
        try await store.configure(storageDirectory: directory)
        let reservation = try await store.reserve(name: "ephemeral", existingNativeIDs: [])
        try await store.commit(
            reservation: reservation,
            nativeID: "st-ephemeral",
            publishedPorts: [],
            autoRemove: true
        )
        try await store.markCreated(nativeID: "st-ephemeral")

        let reloaded = DockerContainerMetadataStore()
        try await reloaded.configure(storageDirectory: directory)
        #expect(await reloaded.entry(nativeID: "st-ephemeral")?.autoRemove == true)
        _ = try await reloaded.rename(
            nativeID: "st-ephemeral",
            to: "renamed-ephemeral",
            existingNativeIDs: ["st-ephemeral"]
        )
        #expect(await reloaded.entry(nativeID: "st-ephemeral")?.autoRemove == true)
    }

    @Test("pending reservation expires without requiring another daemon restart")
    func pendingCreateExpires() async throws {
        let store = DockerContainerMetadataStore()
        let reservation = try await store.reserve(name: "postgres", existingNativeIDs: [])
        try await store.commit(
            reservation: reservation,
            nativeID: "st-abandoned",
            publishedPorts: []
        )
        let pendingSince = try #require(
            await store.entry(nativeID: "st-abandoned")?.pendingSince
        )

        try await store.reconcile(
            existingNativeIDs: [],
            now: pendingSince.addingTimeInterval(9 * 60)
        )
        #expect(await store.entry(nativeID: "st-abandoned") != nil)
        try await store.reconcile(
            existingNativeIDs: [],
            now: pendingSince.addingTimeInterval(10 * 60 + 1)
        )
        #expect(await store.entry(nativeID: "st-abandoned") == nil)
    }

    @Test("stale metadata is removed without affecting surviving entries")
    func reconciliation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("socktainer-metadata-reconcile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DockerContainerMetadataStore()
        try await store.configure(storageDirectory: directory)
        try await store.set(nativeID: "live", name: "db", publishedPorts: [port(55433)])
        try await store.set(nativeID: "gone", name: "old", publishedPorts: [])
        let firstAbsence = Date()
        try await store.reconcile(
            existingNativeIDs: ["live"],
            now: firstAbsence
        )
        #expect(await store.entry(nativeID: "gone") != nil)
        try await store.reconcile(
            existingNativeIDs: ["live"],
            now: firstAbsence.addingTimeInterval(10 * 60 + 1)
        )
        #expect(await store.entry(nativeID: "gone") == nil)
        #expect(await store.name(nativeID: "live") == "db")
    }
}

@Suite("Apple published-port compatibility")
struct ApplePublishedPortCompatibilityTests {
    @Test("migration clears only native forwarding and preserves container configuration")
    func suppressesNativeForwarder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("socktainer-port-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("containers/db", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let process = ProcessConfiguration(
            executable: "/bin/postgres", arguments: [], environment: ["PGDATA=/data"],
            workingDirectory: "/", terminal: false, user: .id(uid: 999, gid: 999)
        )
        let image = ImageDescription(
            reference: "postgres:17",
            descriptor: Descriptor(mediaType: "application/vnd.oci.image.manifest.v1+json", digest: "sha256:abc", size: 1)
        )
        var configuration = ContainerConfiguration(id: "db", image: image, process: process)
        configuration.labels = ["durability": "fsync"]
        configuration.publishedPorts = [
            try PublishPort(hostAddress: IPAddress("127.0.0.1"), hostPort: 55434, containerPort: 5432, proto: .tcp, count: 1)
        ]
        try JSONEncoder().encode(configuration).write(to: bundle.appendingPathComponent("config.json"))
        let snapshot = ContainerSnapshot(configuration: configuration, status: .stopped, networks: [])

        try ApplePublishedPortCompatibility.suppressNativeForwarder(container: snapshot, appSupportURL: root)
        let migrated = try JSONDecoder().decode(
            ContainerConfiguration.self,
            from: Data(contentsOf: bundle.appendingPathComponent("config.json"))
        )
        #expect(migrated.id == configuration.id)
        #expect(migrated.image.descriptor == configuration.image.descriptor)
        #expect(migrated.initProcess.environment == configuration.initProcess.environment)
        #expect(migrated.labels == configuration.labels)
        #expect(migrated.publishedPorts.isEmpty)
    }
}
