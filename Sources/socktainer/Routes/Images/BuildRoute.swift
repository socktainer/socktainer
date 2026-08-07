import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import ContainerPersistence
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Darwin
import DataCompression
import Foundation
import NIO
import TerminalProgress
import Vapor

struct BuildRoute: RouteCollection {

    let client: ClientContainerProtocol
    let builderClient: ClientBuilderProtocol
    let systemConfig: ContainerSystemConfig
    let imageClient: any ClientImageProtocol
    let appleContainerAppSupportURL: URL
    let imageMutationCoordinator: ImageMutationCoordinator

    init(
        client: ClientContainerProtocol,
        builderClient: ClientBuilderProtocol,
        systemConfig: ContainerSystemConfig,
        imageClient: (any ClientImageProtocol)? = nil,
        appleContainerAppSupportURL: URL? = nil,
        imageMutationCoordinator: ImageMutationCoordinator =
            ImageMutationCoordinator()
    ) {
        self.client = client
        self.builderClient = builderClient
        self.systemConfig = systemConfig
        self.imageClient = imageClient ?? ClientImageService(containerSystemConfig: systemConfig)
        self.appleContainerAppSupportURL =
            appleContainerAppSupportURL
            ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.apple.container")
        self.imageMutationCoordinator = imageMutationCoordinator
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .POST,
            pattern: "/build",
            use: BuildRoute.handler(
                client: client,
                builderClient: builderClient,
                systemConfig: systemConfig,
                imageClient: imageClient,
                appleContainerAppSupportURL: appleContainerAppSupportURL,
                imageMutationCoordinator: imageMutationCoordinator
            )
        )

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
    static func builtImageID(
        loadedReferences: [String],
        capturedActorIDs: [String],
        identities: [String: String],
        fallback: String
    ) -> String {
        capturedActorIDs.first
            ?? loadedReferences.compactMap { identities[$0] }.first
            ?? fallback
    }

    /// Classic `/build` requests are disk-backed, but still need a finite
    /// compressed-input ceiling. Sixteen GiB accommodates unusually large
    /// monorepo contexts while preventing one client from streaming until the
    /// builder volume is exhausted. Expanded members have a separate 64-GiB
    /// ceiling in `ArchiveUtility.ExtractionLimits.buildContext`.
    private static let maxBuildContextBodySize = 16 * 1024 * 1024 * 1024
    private static let maxDockerfileSize = 16 * 1024 * 1024
    /// Owns all response-side resources. The managed response stream awaits
    /// this function, so it cannot outlive the channel callback. Disconnects
    /// propagate as cancellation; ordinary build failures remain Docker JSON
    /// error frames and end the response normally.
    static func produceBuildResponse(
        stagingRoot: URL,
        writer: any AsyncBodyStreamWriter,
        logger: Logger,
        heartbeatInterval: Duration =
            DisconnectCoupledResponseStream.defaultHeartbeatInterval,
        operation: @Sendable @escaping (any AsyncBodyStreamWriter) async throws -> Void
    ) async throws {
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        do {
            try await DisconnectCoupledResponseStream.run(
                writer: writer,
                heartbeatInterval: heartbeatInterval,
                operation: operation
            )
        } catch DisconnectCoupledResponseStream.ProducerError.clientDisconnected {
            logger.debug("Build client disconnected; cancelling build")
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("Build failed: \(error)")

            let errorMessage =
                error is ContainerizationError
                ? "\(error)" : error.localizedDescription
            let errorResponse: [String: Any] = [
                "errorDetail": ["message": errorMessage],
                "error": errorMessage,
            ]

            if let jsonData = try? JSONSerialization.data(
                withJSONObject: errorResponse
            ), let jsonString = String(data: jsonData, encoding: .utf8) {
                try await writer.write(
                    .buffer(ByteBuffer(string: jsonString + "\n"))
                )
            } else {
                let fallbackError = """
                    {"errorDetail":{"message":"Build failed"},"error":"Build failed"}

                    """
                try await writer.write(
                    .buffer(ByteBuffer(string: fallbackError))
                )
            }
        }
    }

    /// Parses a Docker API build query parameter (`buildargs` or `labels`).
    ///
    /// The Docker Engine API sends these as a JSON-encoded `{"KEY":"VALUE"}` map.
    /// Returns `["KEY=VALUE", ...]` strings suitable for passing to BuildKit.
    static func parseBuildQueryParam(_ value: String?) -> [String] {
        guard let value,
            let data = value.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [] }
        return dict.map { "\($0.key)=\($0.value)" }
    }

    static func parseBuildPlatforms(_ value: String) throws -> Set<Platform> {
        if value.isEmpty {
            return [
                Platform(
                    arch: Arch.hostArchitecture().rawValue,
                    os: "linux"
                )
            ]
        }
        do {
            return [try Platform(from: value)]
        } catch {
            throw Abort(.badRequest, reason: "invalid platform: \(value)")
        }
    }

    /// Reads a Dockerfile through a no-follow descriptor chain rooted in the
    /// staged context. Lexical normalization alone is insufficient because an
    /// archive may contain a symlink whose target leaves the extraction root.
    static func readDockerfile(
        named name: String,
        in contextDirectory: String
    ) throws -> Data {
        guard !name.isEmpty,
            !name.hasPrefix("/"),
            !name.utf8.contains(0)
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Dockerfile path must be relative to the build context"
            )
        }

        var components: [String] = []
        for component in name.split(
            separator: "/",
            omittingEmptySubsequences: true
        ) {
            if component == "." { continue }
            guard component != ".." else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Dockerfile path escapes the build context: \(name)"
                )
            }
            components.append(String(component))
        }
        guard !components.isEmpty else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Dockerfile path must name a regular file"
            )
        }

        var fileDescriptor = open(
            contextDirectory,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard fileDescriptor >= 0 else {
            throw ContainerizationError(
                .invalidArgument,
                message: "build context is not a readable directory"
            )
        }
        defer { close(fileDescriptor) }

        for (index, component) in components.enumerated() {
            let isFinal = index == components.count - 1
            let flags =
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
                | (isFinal ? 0 : O_DIRECTORY)
            let nextDescriptor = openat(
                fileDescriptor,
                component,
                flags
            )
            guard nextDescriptor >= 0 else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Dockerfile is missing or leaves the build context: \(name)"
                )
            }
            close(fileDescriptor)
            fileDescriptor = nextDescriptor
        }

        var status = stat()
        guard fstat(fileDescriptor, &status) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            status.st_size >= 0,
            status.st_size <= Int64(maxDockerfileSize)
        else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Dockerfile must be a regular file no larger than \(maxDockerfileSize) bytes"
            )
        }

        var result = Data()
        result.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let bytesRead = buffer.withUnsafeMutableBytes {
                read(fileDescriptor, $0.baseAddress, $0.count)
            }
            guard bytesRead >= 0 else {
                throw ContainerizationError(
                    .unknown,
                    message: "failed to read Dockerfile: \(name)"
                )
            }
            guard bytesRead > 0 else { break }
            guard result.count <= maxDockerfileSize - bytesRead else {
                throw ContainerizationError(
                    .invalidArgument,
                    message: "Dockerfile exceeds the \(maxDockerfileSize)-byte limit"
                )
            }
            result.append(contentsOf: buffer.prefix(bytesRead))
        }
        return result
    }

    /// Appends a zero-filled end-of-archive terminator to a received build
    /// context tar so libarchive accepts contexts that omit the trailing
    /// block padding (notably `docker compose build` with the classic builder).
    /// For a gzip-compressed context a second gzip member of zeros is appended
    /// (gzip streams concatenate, so the inflated output gains the missing
    /// padding); for a plain tar, raw zero bytes are appended.
    static func appendTarTerminator(to tarPath: URL) throws {
        let handle = try FileHandle(forReadingFrom: tarPath)
        let magic = try handle.read(upToCount: 2)
        try handle.close()

        let zeros = Data(count: 4096)
        // `gzip()` of a fixed in-memory buffer is infallible.
        let isGzip = magic == Data([0x1f, 0x8b])
        let terminator = isGzip ? zeros.gzip()! : zeros

        let writeHandle = try FileHandle(forWritingTo: tarPath)
        defer { try? writeHandle.close() }
        try writeHandle.seekToEnd()
        try writeHandle.write(contentsOf: terminator)
    }

    struct StagedBuildContext: Sendable {
        let rootDirectory: URL
        let contextDirectory: URL
        let bodyBytes: Int
    }

    /// Stages one classic Build API context in a mode-0700 directory. The
    /// returned root belongs to the caller and must be removed after the build;
    /// every error/cancellation path is cleaned here before it escapes.
    static func stageBuildContext<Chunks: AsyncSequence>(
        _ chunks: Chunks,
        in parent: URL,
        maxBodyBytes: Int = maxBuildContextBodySize,
        extractionLimits: ArchiveUtility.ExtractionLimits = .buildContext
    ) async throws -> StagedBuildContext
    where Chunks.Element == ByteBuffer {
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let root =
            try RequestBodyFileWriter
            .createSecureTemporaryDirectory(in: parent)
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: root)
            }
        }

        let tarPath = root.appendingPathComponent("context.tar")
        let bodyBytes = try await RequestBodyFileWriter.write(
            chunks,
            to: tarPath,
            maxBytes: maxBodyBytes,
            kind: "build context"
        )
        guard bodyBytes > 0 else {
            throw Abort(
                .badRequest,
                reason: "build context body is required"
            )
        }

        try appendTarTerminator(to: tarPath)
        let contextDirectory = root.appendingPathComponent("context")
        try ArchiveUtility.extract(
            tarPath: tarPath,
            to: contextDirectory,
            limits: extractionLimits,
            transactional: true
        )
        completed = true
        return StagedBuildContext(
            rootDirectory: root,
            contextDirectory: contextDirectory,
            bodyBytes: bodyBytes
        )
    }

    static func handler(
        client: ClientContainerProtocol,
        builderClient: ClientBuilderProtocol,
        systemConfig: ContainerSystemConfig,
        imageClient: any ClientImageProtocol,
        appleContainerAppSupportURL: URL,
        imageMutationCoordinator: ImageMutationCoordinator
    ) -> @Sendable (Request) async throws -> Response {
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
            let pull = query.pull.map { ["1", "true", "yes", "on"].contains($0.lowercased()) } ?? false
            let target = query.target!
            let platform = query.platform!
            let platforms = try Self.parseBuildPlatforms(platform)
            let memory = query.memory ?? 2_048_000_000  // 2GB default

            let declaredBodyLength =
                req.headers.first(
                    name: .contentLength
                ).flatMap(Int.init) ?? 0
            let hasBody =
                req.body.data != nil || declaredBodyLength > 0
                || req.headers.first(name: "transfer-encoding")?
                    .lowercased() == "chunked"
            guard hasBody else {
                throw Abort(
                    .badRequest,
                    reason: "build context body is required"
                )
            }

            let appSupportDir =
                appleContainerAppSupportURL
                .appendingPathComponent("builder", isDirectory: true)
            let staged: StagedBuildContext
            do {
                staged = try await Self.stageBuildContext(
                    req.body,
                    in: appSupportDir
                )
            } catch {
                if error is CancellationError || error is Abort {
                    throw error
                }
                req.logger.error("Failed to stage build context: \(error)")
                throw Abort(
                    .badRequest,
                    reason: "Failed to extract tar archive: \(error.localizedDescription)"
                )
            }
            let tempContextDir = staged.rootDirectory
            var responseOwnsContext = false
            defer {
                if !responseOwnsContext {
                    try? FileManager.default.removeItem(at: tempContextDir)
                }
            }

            do {
                try await builderClient.ensureReachable(
                    timeout: .seconds(3),
                    retryInterval: .milliseconds(250),
                    logger: req.logger
                )
            } catch {
                throw Abort(
                    .serviceUnavailable,
                    reason: "BuildKit builder is not running or reachable: \(error.localizedDescription)"
                )
            }
            let contextDir = staged.contextDirectory.path

            let buildArgs = BuildRoute.parseBuildQueryParam(query.buildargs)
            let labels = BuildRoute.parseBuildQueryParam(query.labels)

            // Vapor owns and awaits this producer. The build is therefore a
            // child of the response stream instead of an unstructured task.
            let logger = req.logger
            let body = Response.Body(managedAsyncStream: { writer in
                try await BuildRoute.produceBuildResponse(
                    stagingRoot: tempContextDir,
                    writer: writer,
                    logger: logger
                ) { writer in
                    try await BuildRoute.performBuild(
                        dockerfile: dockerfile,
                        contextDir: contextDir,
                        targetImageName: targetImageName,
                        buildArgs: buildArgs,
                        labels: labels,
                        noCache: noCache,
                        pull: pull,
                        target: target,
                        platforms: platforms,
                        memory: memory,
                        quiet: quiet,
                        builderClient: builderClient,
                        systemConfig: systemConfig,
                        imageClient: imageClient,
                        appleContainerAppSupportURL: appleContainerAppSupportURL,
                        imageMutationCoordinator: imageMutationCoordinator,
                        writer: writer,
                        logger: logger
                    )
                }
            })

            let response = Response(
                status: .ok,
                headers: [
                    "Content-Type": "application/json",
                    "Transfer-Encoding": "chunked",
                ],
                body: body
            )
            responseOwnsContext = true
            return response
        }
    }

    private static func performBuild(
        dockerfile: String,
        contextDir: String,
        targetImageName: String,
        buildArgs: [String],
        labels: [String],
        noCache: Bool,
        pull: Bool,
        target: String,
        platforms: Set<Platform>,
        memory: Int,
        quiet: Bool,
        builderClient: ClientBuilderProtocol,
        systemConfig: ContainerSystemConfig,
        imageClient: any ClientImageProtocol,
        appleContainerAppSupportURL: URL,
        imageMutationCoordinator: ImageMutationCoordinator,
        writer: any AsyncBodyStreamWriter,
        logger: Logger
    ) async throws {

        // Helper function to send Docker API compliant streaming messages
        @Sendable func sendStreamMessage(_ message: String) async throws {
            // Preserve the original message with its formatting
            let streamResponse: [String: Any] = ["stream": message + "\n"]
            if let jsonData = try? JSONSerialization.data(withJSONObject: streamResponse),
                let jsonString = String(data: jsonData, encoding: .utf8)
            {
                try await writer.write(
                    .buffer(ByteBuffer(string: jsonString + "\n"))
                )
            }
        }

        // Send initial build started message
        try await sendStreamMessage(
            "Step 1/1 : Starting build for \(targetImageName)"
        )

        let timeout: Duration = .seconds(300)

        try await sendStreamMessage(" ---> Reading Dockerfile")
        logger.info("Reading Dockerfile \(dockerfile) from staged build context")
        let dockerfileData = try Self.readDockerfile(
            named: dockerfile,
            in: contextDir
        )

        try await sendStreamMessage(" ---> Setting up build environment")

        // Setup temp directory - must use the builder export path that's mounted in buildkit container
        let builderExportPath =
            appleContainerAppSupportURL
            .appendingPathComponent("builder", isDirectory: true)
        let buildID = UUID().uuidString
        let tempURL = builderExportPath.appendingPathComponent(buildID)
        try FileManager.default.createDirectory(
            at: tempURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Keep `out.tar` until image loading has completely consumed it, then
        // remove the whole per-build export on success, error, or cancellation.
        defer { try? FileManager.default.removeItem(at: tempURL) }

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

        // Build configuration
        let config = AppleContainerCompatibility.makeBuildConfig(
            .init(
                buildID: buildID,
                contentStore: RemoteContentStoreClient(),
                buildArgs: buildArgs,
                // TODO: Implement secrets once integration with buildkit materializes
                secrets: [:],
                // Docker's classic Build API does not carry an SSH forwarding endpoint.
                // Buildx SSH mounts use the standards-compatible docker-container driver.
                ssh: "",
                contextDir: contextDir,
                dockerfile: dockerfileData,
                dockerignore: nil,
                labels: labels,
                noCache: noCache,
                platforms: [Platform](platforms),
                tags: [imageName],
                target: target,
                quiet: quiet,
                exports: exports,
                cacheIn: [],
                cacheOut: [],
                pull: pull,
                containerSystemConfig: systemConfig
            ))

        try await sendStreamMessage(" ---> Connecting to build daemon")
        let builderSession = try await builderClient.connect(
            timeout: timeout,
            retryInterval: .seconds(1),
            logger: logger
        )
        try await sendStreamMessage(" ---> Successfully connected to builder")
        try await sendStreamMessage(" ---> Starting build process")

        // Apple image GC computes its keep-set solely from registered image
        // roots. ContainerBuild stages context and intermediate OCI objects in
        // the same remote content store before the final OCI export is rooted.
        // Exclude delete/prune GC for that vulnerable phase; release the lock
        // before `imageClient.load`, which is itself a coordinated mutation.
        try await BuilderSessionLifecycle.withSession(builderSession) {
            session in
            try await imageMutationCoordinator.withMutationExcluded {
                try await session.build(config)
            }
        }

        try await sendStreamMessage(" ---> Build process completed")

        try await sendStreamMessage(" ---> Build completed, processing image")

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
        try await sendStreamMessage(" ---> Loading built image")

        let loadedReferences: [String]
        let capturedActorIDs: [String]
        if let identityLoadingClient =
            imageClient as? any ImageLoadingWithIdentity
        {
            let loaded = try await identityLoadingClient.loadWithIdentities(
                tarballPath: destPath,
                platform: platforms.first ?? .current,
                appleContainerAppSupportUrl: appleContainerAppSupportURL,
                logger: logger
            )
            loadedReferences = loaded.references
            capturedActorIDs = loaded.actorIDs
        } else {
            loadedReferences = try await imageClient.load(
                tarballPath: destPath,
                platform: platforms.first ?? .current,
                appleContainerAppSupportUrl: appleContainerAppSupportURL,
                logger: logger
            )
            capturedActorIDs = []
        }
        guard !loadedReferences.isEmpty else {
            throw ContainerizationError(
                .notFound,
                message: "builder output did not contain a loadable image"
            )
        }
        try await sendStreamMessage(
            " ---> Loaded \(loadedReferences.joined(separator: ", "))"
        )

        // Docker's classic build stream reports the immutable image config ID,
        // not the requested tag or Apple's index/root descriptor.
        let identities =
            capturedActorIDs.isEmpty
            ? await imageClient.digestsByReference() : [:]
        let builtID = builtImageID(
            loadedReferences: loadedReferences,
            capturedActorIDs: capturedActorIDs,
            identities: identities,
            fallback: imageName
        )
        try await sendStreamMessage("Successfully built \(builtID)")

    }
}
