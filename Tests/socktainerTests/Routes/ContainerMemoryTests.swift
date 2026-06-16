import ContainerResource
import Testing

@testable import socktainer

@Suite("Container memory mapping")
struct ContainerMemoryTests {

    // MARK: - resolveMemoryInBytes

    @Test("nil memory returns nil (preserve Apple Container default)")
    func nilMemoryReturnsNil() {
        #expect(resolveMemoryInBytes(nil) == nil)
    }

    @Test("zero memory returns nil — Apple Container 1 GiB default is preserved")
    func zeroMemoryReturnsNil() {
        // Docker's 'no limit' sentinel (Memory=0) has no equivalent in Apple Container:
        // VMs require a fixed RAM amount. Returning nil preserves the 1 GiB default.
        #expect(resolveMemoryInBytes(0) == nil)
    }

    @Test("negative memory returns nil (invalid, treated as no limit)")
    func negativeMemoryReturnsNil() {
        #expect(resolveMemoryInBytes(-1) == nil)
        #expect(resolveMemoryInBytes(Int.min) == nil)
    }

    @Test("positive memory maps to UInt64 bytes")
    func positiveMemoryMapped() {
        let mib: Int = 512 * 1024 * 1024
        #expect(resolveMemoryInBytes(mib) == UInt64(mib))
    }

    @Test("1 byte is the minimum positive value accepted")
    func oneByteAccepted() {
        #expect(resolveMemoryInBytes(1) == 1)
    }

    // MARK: - ContainerConfiguration.Resources default

    @Test("Apple Container default VM memory is 1 GiB")
    func defaultMemoryIs1GiB() {
        let resources = ContainerConfiguration.Resources()
        #expect(resources.memoryInBytes == 1024 * 1024 * 1024)
    }

    @Test("Setting resources.memoryInBytes overrides the default")
    func overrideMemory() {
        var resources = ContainerConfiguration.Resources()
        resources.memoryInBytes = 512 * 1024 * 1024
        #expect(resources.memoryInBytes == 512 * 1024 * 1024)
    }
}
