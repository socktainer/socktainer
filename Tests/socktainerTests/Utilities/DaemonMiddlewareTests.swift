import Testing
import Vapor

@testable import socktainer

@Suite struct DaemonMiddlewareTests {
    @Test
    func accessLogsAreDebugOnly() async throws {
        let app = try await Application.make(.testing)
        configureDaemonMiddleware(app)

        let middleware = app.middleware.resolve()
        #expect(middleware.count == 2)
        #expect((middleware[0] as? RouteLoggingMiddleware)?.logLevel == .debug)
        #expect(middleware[1] is ErrorMiddleware)

        try await app.asyncShutdown()
    }
}
