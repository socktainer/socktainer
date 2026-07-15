import Foundation
import Testing

@testable import socktainer

@Suite("DockerfileChangeApplier — docker import --change")
struct DockerfileChangeApplierTests {

    @Test("CMD in JSON exec form is applied as-is")
    func cmdExecForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["CMD [\"/app\", \"serve\"]"], to: &config)
        #expect(config.cmd == ["/app", "serve"])
    }

    @Test("CMD in shell form is wrapped as /bin/sh -c")
    func cmdShellForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["CMD /app serve"], to: &config)
        #expect(config.cmd == ["/bin/sh", "-c", "/app serve"])
    }

    @Test("ENTRYPOINT in JSON exec form is applied as-is")
    func entrypointExecForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENTRYPOINT [\"/app\"]"], to: &config)
        #expect(config.entrypoint == ["/app"])
    }

    @Test("multiple ENV pairs on one line are all applied")
    func envMultiplePairs() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV FOO=bar BAZ=qux"], to: &config)
        #expect(config.env == ["FOO=bar", "BAZ=qux"])
    }

    @Test("the legacy ENV KEY VALUE form is applied")
    func envLegacyForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV FOO bar"], to: &config)
        #expect(config.env == ["FOO=bar"])
    }

    @Test("a repeated ENV key overwrites in place rather than duplicating")
    func envOverwritesInPlace() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["ENV FOO=bar", "ENV FOO=baz"], to: &config)
        #expect(config.env == ["FOO=baz"])
    }

    @Test("LABEL with a quoted value containing spaces is parsed as one pair")
    func labelQuotedValue() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["LABEL description=\"two words\""], to: &config)
        #expect(config.labels == ["description": "two words"])
    }

    @Test("multiple LABEL pairs on one line are all applied")
    func labelMultiplePairs() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["LABEL a=1 b=2"], to: &config)
        #expect(config.labels == ["a": "1", "b": "2"])
    }

    @Test("EXPOSE without a protocol defaults to tcp")
    func exposeDefaultsToTcp() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["EXPOSE 8080"], to: &config)
        #expect(config.exposedPorts == ["8080/tcp"])
    }

    @Test("EXPOSE with an explicit protocol is kept as given")
    func exposeExplicitProtocol() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["EXPOSE 53/udp"], to: &config)
        #expect(config.exposedPorts == ["53/udp"])
    }

    @Test("EXPOSE accepts multiple ports on one line")
    func exposeMultiplePorts() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["EXPOSE 8080 53/udp"], to: &config)
        #expect(config.exposedPorts == ["8080/tcp", "53/udp"])
    }

    @Test("VOLUME in JSON array form is applied as-is")
    func volumeJSONForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["VOLUME [\"/data\"]"], to: &config)
        #expect(config.volumes == ["/data"])
    }

    @Test("VOLUME in shell form accepts multiple paths")
    func volumeShellForm() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["VOLUME /data /var/log"], to: &config)
        #expect(config.volumes == ["/data", "/var/log"])
    }

    @Test("USER sets the config's user")
    func userInstruction() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["USER app"], to: &config)
        #expect(config.user == "app")
    }

    @Test("WORKDIR sets the config's working directory")
    func workdirInstruction() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["WORKDIR /srv/app"], to: &config)
        #expect(config.workingDir == "/srv/app")
    }

    @Test("an instruction this endpoint does not support (e.g. STOPSIGNAL) is rejected, not silently dropped")
    func unsupportedInstructionIsRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["STOPSIGNAL SIGTERM"], to: &config)
        }
    }

    @Test("a genuinely invalid instruction (no value) is rejected")
    func missingValueIsRejected() throws {
        var config = SynthesizedImageConfig()
        #expect(throws: DockerfileChangeError.self) {
            try DockerfileChangeApplier.apply(["WORKDIR"], to: &config)
        }
    }

    @Test("an empty change entry is ignored")
    func emptyEntryIsIgnored() throws {
        var config = SynthesizedImageConfig()
        try DockerfileChangeApplier.apply(["  "], to: &config)
        #expect(config.cmd == nil)
        #expect(config.env.isEmpty)
    }
}
