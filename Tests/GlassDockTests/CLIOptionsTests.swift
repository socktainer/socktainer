import Testing

@testable import GlassDock

@Suite("Command-line runtime resources")
struct CLIOptionsTests {
    @Test("uses production defaults")
    func defaults() throws {
        let options = try CLIOptions.parse([])

        #expect(options.cpus == 6)
        #expect(options.memoryMiB == 1024)
        #expect(options.directTCPForwarding)
        #expect(options.fastPing)
        #expect(options.eventLoopThreads > 0)
    }

    @Test("can disable direct TCP forwarding")
    func directTCPForwarding() throws {
        let options = try CLIOptions.parse(["--no-direct-tcp-forwarding"])

        #expect(!options.directTCPForwarding)
    }

    @Test("can disable pre-router Docker ping")
    func fastPing() throws {
        let options = try CLIOptions.parse(["--no-fast-ping"])

        #expect(!options.fastPing)
    }

    @Test("accepts a single API event loop")
    func singleEventLoop() throws {
        let options = try CLIOptions.parse(["--event-loop-threads", "1"])

        #expect(options.eventLoopThreads == 1)
    }

    @Test("accepts a comparable benchmark allocation")
    func benchmarkAllocation() throws {
        let options = try CLIOptions.parse(["--cpus", "6", "--memory-mib", "4096"])

        #expect(options.cpus == 6)
        #expect(options.memoryMiB == 4096)
    }

    @Test(
        "rejects helper limits outside the supported range",
        arguments: [
            ["--cpus", "0"],
            ["--cpus", "65"],
            ["--memory-mib", "95"],
            ["--memory-mib", "65537"],
            ["--event-loop-threads", "0"],
            ["--event-loop-threads", "65"],
        ])
    func rejectsUnsupportedValues(arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try CLIOptions.parse(arguments)
        }
    }
}
