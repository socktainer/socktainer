import ContainerizationOS
import Testing

@testable import socktainer

/// Unit tests for `ExecRoute.initialTerminalSize`, which maps Docker's
/// exec-start `ConsoleSize` ([height, width]) to the initial PTY winsize.
///
/// Without applying this, an interactive `docker exec -it` opens a PTY whose
/// window size is never set, so `stty size` fails and full-screen TUIs
/// (vim/htop/less) render at size 0.
@Suite("ExecRoute.initialTerminalSize")
struct ExecInitialTerminalSizeTests {

    @Test("ConsoleSize [height, width] maps to Terminal.Size(width, height)")
    func mapsConsoleSize() throws {
        let size = try #require(ExecRoute.initialTerminalSize(tty: true, consoleSize: [40, 120]))
        #expect(size.width == 120)  // columns
        #expect(size.height == 40)  // rows
    }

    @Test("no TTY returns nil")
    func noTtyReturnsNil() {
        #expect(ExecRoute.initialTerminalSize(tty: false, consoleSize: [40, 120]) == nil)
    }

    @Test("absent ConsoleSize returns nil")
    func absentConsoleSizeReturnsNil() {
        #expect(ExecRoute.initialTerminalSize(tty: true, consoleSize: nil) == nil)
    }

    @Test("zero dimensions return nil")
    func zeroDimensionsReturnNil() {
        #expect(ExecRoute.initialTerminalSize(tty: true, consoleSize: [0, 0]) == nil)
    }

    @Test("wrong element count returns nil")
    func wrongCountReturnsNil() {
        #expect(ExecRoute.initialTerminalSize(tty: true, consoleSize: [40]) == nil)
        #expect(ExecRoute.initialTerminalSize(tty: true, consoleSize: [40, 120, 1]) == nil)
    }

    @Test("dimensions above UInt16.max are clamped")
    func clampsLargeDimensions() throws {
        let size = try #require(
            ExecRoute.initialTerminalSize(tty: true, consoleSize: [100_000, 100_000])
        )
        #expect(size.width == UInt16.max)
        #expect(size.height == UInt16.max)
    }
}
