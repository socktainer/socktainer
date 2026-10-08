import Foundation
import Testing

@testable import socktainer

/// BuildKit output reaches socktainer in `progress=tty` mode (ANSI redraws of
/// the whole screen), so the collector must strip escapes, dedupe redraws and
/// keep the failure reason for the client instead of a bare RPCError (#386).
@Suite("BuildOutputCollector")
struct BuildOutputCollectorTests {

    @Test("ANSI sequences are stripped and split lines are reassembled")
    func stripsAnsiAndJoinsChunks() {
        var collector = BuildOutputCollector()
        #expect(collector.ingest(Data("\u{1B}[1A\u{1B}[K => [1/2] FROM docker.io/lib".utf8)).isEmpty)
        #expect(collector.ingest(Data("rary/alpine 0.1s\n".utf8)) == ["=> [1/2] FROM docker.io/library/alpine 0.1s"])
    }

    @Test("Redraw frames that differ only in timers are not repeated")
    func dedupesRedraws() {
        var collector = BuildOutputCollector()
        let first = collector.ingest(Data("[+] Building 0.2s (1/2)\n => [2/2] RUN make 0.1s\n".utf8))
        let second = collector.ingest(Data("\u{1B}[2A[+] Building 0.9s (1/2)\n => [2/2] RUN make 0.8s\n => => # compiling\n".utf8))
        #expect(first == ["=> [2/2] RUN make 0.1s"])
        #expect(second == ["=> => # compiling"])
    }

    @Test("Failure reason is the BuildKit process error line")
    func capturesFailureReason() {
        var collector = BuildOutputCollector()
        _ = collector.ingest(
            Data(
                """
                 => ERROR [2/2] RUN false 0.1s
                ------
                ERROR: process "/bin/sh -c false" did not complete successfully: exit code: 1

                """.utf8))
        #expect(collector.failureReason == #"ERROR: process "/bin/sh -c false" did not complete successfully: exit code: 1"#)
        #expect(BuildRoute.errorMessage(for: BuildRoute.BuildFailure(errorDescription: collector.failureReason)) == collector.failureReason)
    }

    @Test("Successful output has no failure reason and flushes a trailing line")
    func noFailure() {
        var collector = BuildOutputCollector()
        _ = collector.ingest(Data(" => exporting to oci image format 0.3s\n".utf8))
        #expect(collector.finish().isEmpty)
        #expect(collector.ingest(Data("done".utf8)).isEmpty)
        #expect(collector.finish() == ["done"])
        #expect(collector.failureReason == nil)
    }
}
