import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Foundation
import Logging

/// Persist ownership in the container configuration so rm -v still works after
/// a daemon restart. Only volumes allocated anonymously for this container belong
/// here; an explicit named mount must never be removed by rm -v or --rm.
enum ContainerAnonymousVolumes {
    static let label = "com.socktainer.anonymous-volumes"

    static func encode(_ names: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(names.sorted()), as: UTF8.self)
    }

    static func names(labels: [String: String]) -> [String] {
        guard let value = labels[label],
            let names = try? JSONDecoder().decode([String].self, from: Data(value.utf8))
        else { return [] }
        return Array(Set(names)).sorted()
    }

    static func remove(
        names: [String], logger: Logger, retries: Int = 0, retryDelayNanoseconds: UInt64 = 100_000_000,
        delete: @Sendable (String) async throws -> Void = { name in
            let volume = try await ClientVolume.inspect(name)
            guard volume.labels[ClientVolumeService.anonymousVolumeLabel] != nil else { return }
            // Apple Container atomically refuses deletion while any container
            // still references this volume. Never force removal of shared data.
            try await ClientVolume.delete(name: name)
        }
    ) async {
        for name in Set(names).sorted() {
            var attempt = 0
            while true {
                do {
                    try await delete(name)
                    break
                } catch {
                    // wait() can finish just before Apple's --rm teardown releases
                    // its mounts. Retry that specific race, never force deletion.
                    if isInUse(error), attempt < retries, !Task.isCancelled {
                        attempt += 1
                        do {
                            try await Task.sleep(nanoseconds: retryDelayNanoseconds)
                        } catch { return }
                        continue
                    }
                    if !VolumeNotFound.matches(error) {
                        logger.warning("Anonymous volume \(name) retained: \(error)")
                    }
                    break
                }
            }
        }
    }

    private static func isInUse(_ error: any Error) -> Bool {
        if let error = error as? VolumeError, case .volumeInUse = error { return true }
        guard let error = error as? ContainerizationError, error.code == .invalidArgument else { return false }
        return error.message.hasPrefix("volume '")
            && error.message.hasSuffix("' is currently in use and cannot be accessed by another container, or deleted")
    }
}
