import Foundation
import NIO

// Get HOME directory
let homeDirectory = ProcessInfo.processInfo.environment["HOME"]

do {
    // Create router and register routes
    let router = HTTPRouter()
    let healthCheckClient = ClientService()
    
    // Register ping route
    router.register(route: PingRoute())
    router.register(route: ContainerInspectRoute())
    router.register(route: ExecGetRoute())
    router.register(route: ExecStartRoute())
    router.register(route: ExecCreateRoute())
    router.register(route: ExecResizeRoute())

    // Start Unix socket server with HTTP support
    let serverFuture = try startUnixSocketServer(
        homeDirectory: homeDirectory,
        router: router,
        client: healthCheckClient
    )
    
    // Wait for the server channel to be ready
    let serverChannel = try serverFuture.wait()
    
    // Keep the server alive indefinitely
    try serverChannel.closeFuture.wait()
    
} catch {
    print("❌ Server failed: \(error)")
}
