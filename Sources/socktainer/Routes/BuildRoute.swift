import ContainerBuild
import ContainerClient
import ContainerImagesServiceClient
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Foundation
import NIO
import TerminalProgress
import Vapor

struct BuildRoute: RouteCollection {

    let client: ClientContainerProtocol

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.POST, pattern: "/build", use: BuildRoute.handler(client: client))

    }

}

struct RESTBuildQuery: Vapor.Content {
    var dockerfile: String?
    var t: String?  // tag
    var extrahosts: String?  // path to extra hosts file
    var remote: String?  // remote URL to build context
    var q: Bool?  // quiet
    var nocache: Bool?  // no cache
    var cachefrom: String?  // cache from
    var pull: String?
    var rm: Bool?  // remove intermediate containers
    var forcerm: Bool?  // always remove intermediate containers
    var memory: Int?  // memory limit in bytes
    var memswap: Int?  // total memory (memory + swap); -1 to disable swap
    var cpushares: Int?  // CPU shares (relative weight)
    var cpusetcpus: String?  // CPUs in which to allow execution
    var cpuperiod: Int?  // limit CPU CFS period
    var cpuquota: Int?  // limit CPU CFS quota
    var buildargs: String?  // build arguments
    var shmsize: Int?  // size of /dev/shm in bytes
    var squash: Bool?  // squash the resulting image
    var labels: String?  // labels to set on the image
    var networkmode: String?  // networking mode for the RUN instructions during build
    var platform: String?  // target platform for build
    var target: String?  // target stage to build
    var outputs: String?  // output destination
    var version: String?  // API version

    init() {
        self.dockerfile = "Dockerfile"
        self.q = false
        self.nocache = false
        self.rm = true
        self.forcerm = false
        self.platform = "linux/arm64"
        self.target = ""
        self.outputs = ""
        self.version = "1"
    }
}

extension BuildRoute {
    static func handler(client: ClientContainerProtocol) -> @Sendable (Request) async throws -> Response {
        { req in
            var query = try req.query.decode(RESTBuildQuery.self)

            // Apply Docker API defaults if not provided
            if query.dockerfile == nil { query.dockerfile = "Dockerfile" }
            if query.q == nil { query.q = false }
            if query.nocache == nil { query.nocache = false }
            if query.rm == nil { query.rm = true }
            if query.forcerm == nil { query.forcerm = false }
            if query.platform == nil { query.platform = "" }
            if query.target == nil { query.target = "" }
            if query.outputs == nil { query.outputs = "" }
            if query.version == nil { query.version = "1" }

            // Extract values with Docker-compliant defaults
            let dockerfile = query.dockerfile!
            let targetImageName = query.t ?? UUID().uuidString.lowercased()
            let quiet = query.q!
            let noCache = query.nocache!
            let target = query.target!
            let platform = query.platform!
            let memory = query.memory ?? 2_048_000_000  // 2GB default

            // Extract tar archive from request body and unpack to temporary directory
            let contextDir: String
            let buildUUID = UUID().uuidString
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            let appSupportDir = homeDirectory.appendingPathComponent(".socktainer").appendingPathComponent(".build")
            let tempContextDir = appSupportDir.appendingPathComponent(buildUUID)

            do {
                // Create temporary directory for build context
                try FileManager.default.createDirectory(at: tempContextDir, withIntermediateDirectories: true, attributes: nil)

                // Check if we have a request body to process
                let hasBody = req.body.data != nil || req.headers.first(name: "transfer-encoding")?.lowercased() == "chunked"

                if hasBody {

                    // Write the body data to a temporary tar file using streaming
                    let tarPath = tempContextDir.appendingPathComponent("context.tar")
                    var fileHandle: FileHandle?
                    var totalBytesWritten = 0

                    do {
                        // Create the tar file and open file handle for writing
                        FileManager.default.createFile(atPath: tarPath.path, contents: nil)
                        fileHandle = try FileHandle(forWritingTo: tarPath)

                        // Stream the body directly to the tar file without loading into memory
                        if let bodyData = req.body.data {
                            // Direct body data available
                            let data = Data(buffer: bodyData)
                            try fileHandle?.write(contentsOf: data)
                            totalBytesWritten = data.count
                        } else {
                            // Use ByteBuffer streaming to avoid loading all data into memory
                            for try await chunk in req.body {
                                let data = Data(buffer: chunk)
                                try fileHandle?.write(contentsOf: data)
                                totalBytesWritten += data.count
                            }
                        }

                        try fileHandle?.close()
                        fileHandle = nil
                    } catch {
                        // Clean up file handle and partial tar file on error
                        try? fileHandle?.close()
                        try? FileManager.default.removeItem(at: tarPath)
                        req.logger.error("Failed to stream body to tar file: \(error)")
                        throw Abort(.badRequest, reason: "Failed to process request body: \(error.localizedDescription)")
                    }

                    if totalBytesWritten > 0 {
                        // Extract the tar archive
                        let extractDir = tempContextDir.appendingPathComponent("context")
                        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true, attributes: nil)

                        // Use tar command to extract the archive
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                        process.arguments = ["-xf", tarPath.path, "-C", extractDir.path]

                        // Capture stderr for debugging
                        let pipe = Pipe()
                        process.standardError = pipe

                        try process.run()
                        process.waitUntilExit()

                        guard process.terminationStatus == 0 else {
                            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                            req.logger.error("Tar extraction failed with status \(process.terminationStatus): \(errorMessage)")
                            throw Abort(.badRequest, reason: "Failed to extract tar archive: \(errorMessage)")
                        }
                        contextDir = extractDir.path
                    } else {
                        req.logger.warning("No data received in request body")
                        contextDir = "."
                    }
                } else {
                    // No body provided, use current directory as fallback
                    req.logger.warning("No build context provided in request body, using current directory as fallback")
                    contextDir = "."
                }
            } catch {
                // Clean up on error
                try? FileManager.default.removeItem(at: tempContextDir)
                throw error
            }

            // Parse build arguments
            let buildArgs: [String] = {
                guard let buildArgsString = query.buildargs else { return [] }
                return buildArgsString.split(separator: ",").map(String.init)
            }()

            // Parse labels
            let labels: [String] = {
                guard let labelsString = query.labels else { return [] }
                return labelsString.split(separator: ",").map(String.init)
            }()

            // Create streaming response for build output
            let body = Response.Body { writer in
                Task.detached {
                    do {
                        try await BuildRoute.performBuild(
                            dockerfile: dockerfile,
                            contextDir: contextDir,
                            targetImageName: targetImageName,
                            buildArgs: buildArgs,
                            labels: labels,
                            noCache: noCache,
                            target: target,
                            platform: platform,
                            memory: memory,
                            quiet: quiet,
                            writer: writer,
                            logger: req.logger
                        )

                        // Clean up temporary context directory if it was created
                        if contextDir != "." {
                            try? FileManager.default.removeItem(at: tempContextDir)
                        }
                    } catch {
                        req.logger.error("Build failed: \(error)")

                        // Docker API compliant error response
                        let errorDetail: [String: Any] = [
                            "message": error.localizedDescription
                        ]

                        let errorResponse: [String: Any] = [
                            "errorDetail": errorDetail,
                            "error": error.localizedDescription,
                        ]

                        if let jsonData = try? JSONSerialization.data(withJSONObject: errorResponse),
                            let jsonString = String(data: jsonData, encoding: .utf8)
                        {
                            _ = writer.write(.buffer(ByteBuffer(string: jsonString + "\n")))
                        } else {
                            let fallbackError = """
                                {"errorDetail":{"message":"Build failed"},"error":"Build failed"}

                                """
                            _ = writer.write(.buffer(ByteBuffer(string: fallbackError)))
                        }

                        // Clean up temporary context directory on error
                        if contextDir != "." {
                            try? FileManager.default.removeItem(at: tempContextDir)
                        }
                        _ = writer.write(.end)
                    }
                }
            }

            return Response(
                status: .ok,
                headers: [
                    "Content-Type": "application/json",
                    "Transfer-Encoding": "chunked",
                ],
                body: body
            )
        }
    }

    private static func performBuild(
        dockerfile: String,
        contextDir: String,
        targetImageName: String,
        buildArgs: [String],
        labels: [String],
        noCache: Bool,
        target: String,
        platform: String,
        memory: Int,
        quiet: Bool,
        writer: BodyStreamWriter,
        logger: Logger
    ) async throws {

        // Helper function to send Docker API compliant streaming messages
        @Sendable func sendStreamMessage(_ message: String) {
            // Preserve the original message with its formatting
            let streamResponse: [String: Any] = ["stream": message + "\n"]
            if let jsonData = try? JSONSerialization.data(withJSONObject: streamResponse),
                let jsonString = String(data: jsonData, encoding: .utf8)
            {
                let result = writer.write(.buffer(ByteBuffer(string: jsonString + "\n")))

                // Log write failures for debugging but don't crash
                result.whenFailure { error in
                    logger.debug("BuildRoute: Write failed - \(error)")
                }
            }
        }

        func sendProgressMessage(id: String, status: String, progressDetail: [String: Any]? = nil) {
            var response: [String: Any] = [
                "id": id,
                "status": status,
            ]
            if let detail = progressDetail {
                response["progressDetail"] = detail
            }

            if let jsonData = try? JSONSerialization.data(withJSONObject: response),
                let jsonString = String(data: jsonData, encoding: .utf8)
            {
                let result = writer.write(.buffer(ByteBuffer(string: jsonString + "\n")))
                result.whenFailure { error in
                    logger.debug("BuildRoute: Progress message write failed - \(error)")
                }
            }
        }

        // Send initial build started message
        sendStreamMessage("Step 1/1 : Starting build for \(targetImageName)")

        let timeout: Duration = .seconds(300)

        sendStreamMessage(" ---> Connecting to build daemon")

        // Connect to builder (similar to BuildCommand logic)
        let builder: Builder? = try await withThrowingTaskGroup(of: Builder.self) { group in
            defer {
                group.cancelAll()
            }

            group.addTask {
                while true {
                    do {
                        let container = try await ClientContainer.get(id: "buildkit")
                        let fh = try await container.dial(8088)  // Default vsock port

                        let threadGroup: MultiThreadedEventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
                        let b = try Builder(socket: fh, group: threadGroup)

                        // If this call succeeds, then BuildKit is running.
                        let _ = try await b.info()
                        sendStreamMessage(" ---> Successfully connected to builder")
                        return b
                    } catch {
                        // Builder not available - throw error
                        throw ContainerizationError(.unknown, message: "BuildKit container is not running. Please start the builder first.")
                    }
                }
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw ContainerizationError(.timeout, message: "Timeout waiting for connection to builder")
            }

            return try await group.next()
        }

        guard let builder else {
            throw ContainerizationError(.unknown, message: "builder is not running")
        }

        // resolve the full path to the Dockerfile
        sendStreamMessage(" ---> Reading Dockerfile")
        let dockerfilePath = URL(fileURLWithPath: contextDir).appendingPathComponent(dockerfile).path
        logger.info("Reading Dockerfile at path: \(dockerfilePath)")

        guard let dockerfileData = try? Data(contentsOf: URL(filePath: dockerfilePath)) else {
            throw ContainerizationError(.invalidArgument, message: "Dockerfile does not exist at path: \(dockerfilePath)")
        }

        sendStreamMessage(" ---> Setting up build environment")

        // Setup temp directory - use BuildCommand approach
        let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let exportPath = systemHealth.appRoot.appendingPathComponent(".build")
        let buildID = UUID().uuidString
        let tempURL = exportPath.appendingPathComponent(buildID)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)

        // Validate and normalize image name
        let imageName: String = try {
            let parsedReference = try Reference.parse(targetImageName)
            parsedReference.normalize()
            return parsedReference.description
        }()

        // Setup exports - use BuildCommand approach
        let exports: [Builder.BuildExport] = try ["type=oci"].map { output in
            var exp = try Builder.BuildExport(from: output)
            if exp.destination == nil {
                exp.destination = tempURL.appendingPathComponent("out.tar")
            }
            return exp
        }

        // Parse platforms
        let platforms: Set<Platform> = {
            guard platform.isEmpty else {
                return [try! Platform(from: platform)]
            }
            return [try! Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")]
        }()

        // Build configuration
        let config = ContainerBuild.Builder.BuildConfig(
            buildID: buildID,
            contentStore: RemoteContentStoreClient(),
            buildArgs: buildArgs,
            contextDir: contextDir,
            dockerfile: dockerfileData,
            labels: labels,
            noCache: noCache,
            platforms: [Platform](platforms),
            terminal: nil,  // No terminal for API
            tag: imageName,
            target: target,
            quiet: quiet,
            exports: exports,
            cacheIn: [],
            cacheOut: []
        )

        sendStreamMessage(" ---> Starting build process")

        // Run build directly without output capture
        try await builder.build(config)

        sendStreamMessage(" ---> Build process completed")

        sendStreamMessage(" ---> Build completed, processing image")

        // Load and unpack the built image
        let destPath = tempURL.appendingPathComponent("out.tar")
        guard FileManager.default.fileExists(atPath: destPath.path) else {
            // List directory contents to help debug
            logger.error("Output image not found at expected path: \(destPath.path)")
            do {
                let parentDir = tempURL.path
                let contents = try FileManager.default.contentsOfDirectory(atPath: parentDir)
                logger.error("Contents of export directory \(parentDir): \(contents)")
            } catch {
                logger.error("Could not list contents of export directory: \(error)")
            }
            throw ContainerizationError(.unknown, message: "Build completed but no output image found at \(destPath.path)")
        }
        sendStreamMessage(" ---> Loading built image")

        let loaded = try await ClientImage.load(from: destPath.absolutePath())

        for image in loaded {
            sendStreamMessage(" ---> Unpacking image layers")
            try await image.unpack(platform: nil, progressUpdate: { _ in })
        }

        // Send success message in Docker API format
        sendStreamMessage("Successfully built \(imageName)")

        _ = writer.write(.end)
    }
}
