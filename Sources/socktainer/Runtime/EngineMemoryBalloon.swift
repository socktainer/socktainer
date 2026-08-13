import Containerization
import ContainerizationExtras
import Foundation
import Virtualization

@available(macOS 26.0, *)
final class EngineMemoryBalloon: VZInstanceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private weak var instance: VZVirtualMachineInstance?

    func configureVZ(
        _ config: inout VZVirtualMachineConfiguration,
        allocator: any AddressAllocator<Character>,
        storageDeviceCount: Int,
        mountsByID: [String: [Containerization.Mount]]
    ) throws {
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    }

    func didCreate(_ instance: VZVirtualMachineInstance) throws {
        lock.withLock { self.instance = instance }
    }

    func setTarget(_ bytes: UInt64) async throws {
        guard let instance = lock.withLock({ instance }) else {
            throw PersistentEngineError.invalidMachineSnapshot("memory balloon is unavailable")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            instance.vmQueue.async {
                guard
                    let device =
                        instance.vzVirtualMachine.memoryBalloonDevices.first
                        as? VZVirtioTraditionalMemoryBalloonDevice
                else {
                    continuation.resume(
                        throwing: PersistentEngineError.invalidMachineSnapshot(
                            "memory balloon device is unavailable"
                        )
                    )
                    return
                }
                device.targetVirtualMachineMemorySize = bytes
                continuation.resume(returning: ())
            }
        }
    }
}
