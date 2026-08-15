import Testing

@testable import GlassDock

@Suite("Command-line runtime resources")
struct CLIOptionsTests {
    @Test("uses production defaults")
    func defaults() throws {
        let options = try CLIOptions.parse([])

        #expect(options.cpus == 6)
        #expect(options.memoryMiB == 1024)
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
        ])
    func rejectsUnsupportedValues(arguments: [String]) {
        #expect(throws: (any Error).self) {
            _ = try CLIOptions.parse(arguments)
        }
    }
}
