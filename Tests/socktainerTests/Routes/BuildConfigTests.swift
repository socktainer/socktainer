import ContainerBuild
import ContainerPersistence
import ContainerizationOCI
import Foundation
import Testing

@testable import socktainer

/// In quiet mode apple/container's `BuildStdio` drops the builder's output without the
/// ack the builder waits for, so `docker build -q` hung on any build with a `RUN` step
/// (apple/container#2387).
@Suite("BuildRoute builder configuration")
struct BuildConfigTests {
    static func config() throws -> ContainerBuild.Builder.BuildConfig {
        BuildRoute.buildConfig(
            buildID: "build-1",
            buildArgs: ["A=1"],
            contextDir: "/tmp/context",
            dockerfile: Data("FROM alpine\nRUN true\n".utf8),
            labels: ["l=1"],
            noCache: true,
            platforms: [try Platform(from: "linux/arm64")],
            tag: "docker.io/library/probe:1",
            target: "final",
            exports: [try Builder.BuildExport(from: "type=oci")],
            pull: true,
            systemConfig: ContainerSystemConfig()
        )
    }

    @Test("the builder is never asked to be quiet")
    func neverQuiet() throws {
        #expect(try Self.config().quiet == false)
    }

    @Test("the request's build settings reach the builder")
    func passesSettingsThrough() throws {
        let config = try Self.config()

        #expect(config.buildID == "build-1")
        #expect(config.buildArgs == ["A=1"])
        #expect(config.contextDir == "/tmp/context")
        #expect(config.dockerfile == Data("FROM alpine\nRUN true\n".utf8))
        #expect(config.labels == ["l=1"])
        #expect(config.noCache)
        #expect(config.platforms == [try Platform(from: "linux/arm64")])
        #expect(config.tags == ["docker.io/library/probe:1"])
        #expect(config.target == "final")
        #expect(config.exports.count == 1)
        #expect(config.pull)
        #expect(config.terminal == nil)
    }
}
