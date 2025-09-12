import NIO
import NIOHTTP1
import Foundation

public enum UnixSocketServerError: Error {
    case missingHomeDirectory
}

public func startUnixSocketServer(
    homeDirectory: String? = nil,
    router: HTTPRouter,
    client: any ClientProtocol
) throws -> EventLoopFuture<Channel> {
    
    guard let homeDir = homeDirectory else {
        throw UnixSocketServerError.missingHomeDirectory
    }
    
    let socketDirectory = "\(homeDir)/.socktainer"
    let socketPath = "\(socketDirectory)/container.sock"
    let fileManager = FileManager.default
    
    // Ensure directory exists
    if !fileManager.fileExists(atPath: socketDirectory) {
        try fileManager.createDirectory(atPath: socketDirectory, withIntermediateDirectories: true)
    }
    
    // Remove old socket if exists
    if fileManager.fileExists(atPath: socketPath) {
        try fileManager.removeItem(atPath: socketPath)
    }
    
    // Create EventLoopGroup
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    
    // Configure NIO ServerBootstrap for Unix domain socket with HTTP support
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap { _ in
                channel.pipeline.addHandler(DirectHTTPHandler(router: router, client: client))
            }
        }
        .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
    
    return bootstrap.bind(unixDomainSocketPath: socketPath)
        .map { channel in
            print("✅ Unix socket server running at \(socketPath)")
            return channel
        }
}

