import CPingGateway
import Foundation

struct DockerAPIGatewayConfiguration: Sendable {
    let publicSocketPath: String
    let backendSocketPath: String
    let apiVersion: String
    var builderVersion = ""
    var experimental = false
    var maxConnections: UInt32 = 1024
    var headerTimeoutMilliseconds: UInt32 = 5_000
}

enum DockerAPIGatewayError: Error, CustomStringConvertible {
    case startFailed(String)

    var description: String {
        switch self {
        case .startFailed(let message):
            "Could not start the Docker API gateway: \(message)"
        }
    }
}

final class DockerAPIGateway: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    init(configuration: DockerAPIGatewayConfiguration) throws {
        var error = [CChar](repeating: 0, count: 512)
        let started: OpaquePointer? = configuration.publicSocketPath.withCString { publicPath in
            configuration.backendSocketPath.withCString { backendPath in
                configuration.apiVersion.withCString { apiVersion in
                    configuration.builderVersion.withCString { builderVersion in
                        var cConfiguration = glassdock_ping_gateway_config_t(
                            public_socket_path: publicPath,
                            backend_socket_path: backendPath,
                            api_version: apiVersion,
                            builder_version: builderVersion,
                            experimental: configuration.experimental,
                            max_connections: configuration.maxConnections,
                            header_timeout_milliseconds: configuration.headerTimeoutMilliseconds
                        )
                        return glassdock_ping_gateway_start(
                            &cConfiguration,
                            &error,
                            error.count
                        )
                    }
                }
            }
        }
        guard let started else {
            let end = error.firstIndex(of: 0) ?? error.endIndex
            let message = String(
                decoding: error[..<end].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            throw DockerAPIGatewayError.startFailed(message)
        }
        handle = started
    }

    func stop() {
        let current: OpaquePointer? = lock.withLock {
            defer { handle = nil }
            return handle
        }
        glassdock_ping_gateway_stop(current)
    }

    deinit {
        stop()
    }
}
