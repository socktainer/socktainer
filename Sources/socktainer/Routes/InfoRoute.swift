import ContainerClient
import Vapor

struct InfoRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "info", use: InfoRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        do {
            let containerClient = ClientContainerService()
            let allContainers = try await containerClient.list(showAll: true)

            let info = SystemInfo(
                Containers: allContainers.count,
                ContainersRunning: allContainers.filter { $0.status == .running }.count,
                // Apple container doesn't support pausing containers
                ContainersPaused: 0,
                ContainersStopped: allContainers.filter { $0.status == .stopped }.count,
                Images: try await ClientImageService().list().count,
                DockerRootDir: try await ClientHealthCheck.ping().appRoot.path,
                Debug: isDebug(),
                KernelVersion: try await getLinuxDefaultKernelName(),
                OSVersion: currentPlatform().osVersion ?? nil,
                OSType: currentPlatform().os,
                Architecture: currentPlatform().architecture,
                NCPU: hostCPUCoreCount(),
                MemTotal: Int64(hostPhysicalMemory()),
                HttpProxy: ProcessInfo.processInfo.environment["HTTP_PROXY"] ?? nil,
                HttpsProxy: ProcessInfo.processInfo.environment["HTTPS_PROXY"] ?? nil,
                NoProxy: ProcessInfo.processInfo.environment["NO_PROXY"] ?? nil,
                Name: hostName(),
                ExperimentalBuild: true,
                ServerVersion: try await ClientHealthCheck.ping().apiServerVersion,
                // TODO: Derive this dynamically somehow
                Runtimes: [
                    "container-runtime-linux": Runtime(
                        path: "/usr/local/libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux")
                ],
                DefaultRuntime: "container-runtime-linux",
                ProductLicense: "socktainer [Apache License 2.0], Apple container [Apache License 2.0]",
                SystemTime: currentTime(),
                Warnings: ["WARNING: Apple container system info may differ"],
            )
            return try await info.encodeResponse(for: req)
        } catch {
            let response = Response(status: .internalServerError)
            response.headers.add(name: .contentType, value: "application/json")
            response.body = .init(string: "{\"message\": \"Failed to generate system information\"}\n")
            return response
        }
    }
}
