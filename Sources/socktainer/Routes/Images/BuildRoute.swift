import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import ContainerPersistence
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import DataCompression
import Foundation
import NIO
import TerminalProgress
import Vapor

struct BuildRoute: RouteCollection {
    /// Prefix for the mixed-platform split build's scratch tags (see `performBuild`) — also
    /// used by `ClientImageService.list()` to hide one that survives a crash mid-build,
    /// before the normal cleanup runs.
    static let scratchTagPrefix = "socktainer-buildsplit-"

    let client: ClientContainerProtocol
    let builderClient: ClientBuilderProtocol
    let systemConfig: ContainerSystemConfig
    let manifestClient: ClientManifestServiceProtocol

    init(client: ClientContainerProtocol, builderClient: ClientBuilderProtocol, systemConfig: ContainerSystemConfig, manifestClient: ClientManifestServiceProtocol) {
        self.client = client
        self.builderClient = builderClient
        self.systemConfig = systemConfig
        self.manifestClient = manifestClient
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(
            .POST, pattern: "/build", use: BuildRoute.handler(client: client, builderClient: builderClient, systemConfig: systemConfig, manifestClient: manifestClient))

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
    var manifest: String?  // podman: add the built image(s) to this named manifest list, creating it if needed

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
    /// Recovers every value of the repeated `platform` query parameter from the raw
    /// query string.
    ///
    /// Real podman sends `--platform a,b` as the SAME query key repeated once per
    /// platform (`pkg/bindings/images/build.go`: `params.Del("platform")` then
    /// `params.Add("platform", ...)` per platform) — i.e. `?platform=linux/arm64&platform=linux/amd64`,
    /// not one comma-joined value. `Vapor.Content` decoding a repeated key into a
    /// scalar `String?` field silently keeps only the last occurrence, dropping every
    /// platform but one.
    static func parseAllPlatformQueryValues(from queryString: String?) -> [String] {
        allQueryValues(named: "platform", from: queryString)
    }

    /// Resolves the `t` (tag) query parameter to a concrete target image name.
    ///
    /// Real podman sends `t=` (present, but empty) when no explicit tag is given — treating
    /// that the same as "absent" (falling back, e.g. to a generated name) requires checking
    /// emptiness, not just nil, or the build ends up tagged as the literal empty string.
    static func resolvedTargetImageName(_ tag: String?, fallback: String) -> String {
        tag?.isEmpty == false ? tag! : fallback
    }

    /// Parses the `dockerfile` query parameter.
    ///
    /// Docker-compat clients send a plain path (e.g. `Dockerfile`). Real podman
    /// clients send it JSON-array-encoded (e.g. `["Dockerfile"]`, since buildah
    /// supports multiple Containerfiles). Only the first element is used —
    /// multi-Containerfile builds aren't supported here yet.
    static func parseDockerfileQueryParam(_ value: String, logger: Logger? = nil) throws -> String {
        // An empty top-level value means "no dockerfile was specified" — the same as the
        // param being omitted entirely (falls back to "Dockerfile" upstream) or JSON-decoding
        // to an empty array (below). `sanitizedDockerfilePath`'s own empty-value rejection is
        // for when a caller explicitly names a specific-but-degenerate path (e.g. an empty
        // string as an array's first element) — a materially different situation from simply
        // not asking for anything in particular.
        guard !value.isEmpty else { return "Dockerfile" }
        guard value.hasPrefix("[") else { return try sanitizedDockerfilePath(value) }
        guard let data = value.data(using: .utf8),
            let array = try? JSONDecoder().decode([String].self, from: data)
        else {
            throw Abort(.badRequest, reason: "dockerfile query param '\(value)' looks JSON-array-encoded but failed to decode")
        }
        guard let first = array.first else {
            logger?.warning("dockerfile query param decoded to an empty array; falling back to 'Dockerfile'")
            return "Dockerfile"
        }
        return try sanitizedDockerfilePath(first)
    }

    /// Rejects a dockerfile path that would escape the build context (absolute paths, or
    /// `..` components) with a client error instead of silently substituting a different
    /// file — the caller asked for a SPECIFIC dockerfile, so a fallback that builds
    /// something else entirely without telling them is worse than just failing the request.
    static func sanitizedDockerfilePath(_ value: String) throws -> String {
        let isAbsolute = value.hasPrefix("/")
        let hasTraversal = value.split(separator: "/").contains(where: { $0 == ".." })
        guard !value.isEmpty, !isAbsolute, !hasTraversal else {
            throw Abort(.badRequest, reason: "dockerfile path '\(value)' escapes the build context")
        }
        return value
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

    static func handler(client: ClientContainerProtocol, builderClient: ClientBuilderProtocol, systemConfig: ContainerSystemConfig, manifestClient: ClientManifestServiceProtocol)
        -> @Sendable (Request) async throws -> Response
    {
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
            let dockerfile = try BuildRoute.parseDockerfileQueryParam(query.dockerfile!, logger: req.logger)
            let targetImageName = BuildRoute.resolvedTargetImageName(query.t, fallback: UUID().uuidString.lowercased())
            let quiet = query.q!
            let noCache = query.nocache!
            let pull = query.pull.map { ["1", "true", "yes", "on"].contains($0.lowercased()) } ?? false
            let target = query.target!
            let platformQueryValues = BuildRoute.parseAllPlatformQueryValues(from: req.url.query)
            let platformString = platformQueryValues.isEmpty ? query.platform! : platformQueryValues.joined(separator: ",")
            let memory = query.memory ?? 2_048_000_000  // 2GB default
            let manifestName = query.manifest?.isEmpty == false ? query.manifest : nil

            // Parse the platform parameter early so we can select the right builder mode
            // before calling ensureReachable.  Supports comma-separated values, e.g.
            //   --platform linux/arm64,linux/s390x
            let parsedPlatforms: [Platform]
            do {
                if platformString.isEmpty {
                    parsedPlatforms = [try Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")]
                } else {
                    parsedPlatforms = try parseMultiPlatformString(platformString)
                }
            } catch {
                throw Abort(
                    .badRequest,
                    reason:
                        "Invalid platform specification '\(platformString)': expected os/architecture or comma-separated list (e.g. linux/arm64,linux/amd64): \(error.localizedDescription)"
                )
            }

            // Platforms that are neither arm64 nor amd64 require the QEMU-enabled builder
            // (a separate container named "buildkit-qemu") so the builder VM can emulate
            // foreign instruction sets via Linux binfmt_misc registration. The two builder
            // VMs are provisioned with mutually-exclusive emulation backends (Rosetta 2 vs.
            // generic QEMU binfmt), so a request mixing e.g. arm64/amd64 with s390x is split
            // and built against each backend independently, then merged — see performBuild.
            let rosettaPlatforms = parsedPlatforms.filter { !platformRequiresQEMU($0) }
            let qemuPlatforms = parsedPlatforms.filter { platformRequiresQEMU($0) }
            let needsQEMU = !qemuPlatforms.isEmpty
            let needsRosettaBuilder = !rosettaPlatforms.isEmpty

            do {
                if needsRosettaBuilder {
                    try await builderClient.ensureReachable(
                        timeout: .seconds(3), retryInterval: .milliseconds(250), qemu: false, logger: req.logger)
                }
                if needsQEMU {
                    try await builderClient.ensureReachable(
                        timeout: .seconds(3), retryInterval: .milliseconds(250), qemu: true, logger: req.logger)
                }
            } catch {
                throw Abort(.serviceUnavailable, reason: "BuildKit builder is not running or reachable: \(error.localizedDescription)")
            }

            // Extract tar archive from request body and unpack to temporary directory
            let contextDir: String
            let buildUUID = UUID().uuidString
            let appSupportDir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent("com.apple.container/builder")
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
                            var chunkCount = 0
                            for try await var chunk in req.body {
                                guard let data = chunk.readData(length: chunk.readableBytes) else {
                                    continue
                                }
                                chunkCount += 1
                                try fileHandle?.write(contentsOf: data)
                                totalBytesWritten += data.count
                            }
                        }

                        try fileHandle?.synchronize()
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
                        guard FileManager.default.fileExists(atPath: tarPath.path),
                            let fileAttributes = try? FileManager.default.attributesOfItem(atPath: tarPath.path),
                            let fileSize = fileAttributes[.size] as? Int64,
                            fileSize > 0
                        else {
                            req.logger.error("Tar file is missing or empty after writing \(totalBytesWritten) bytes")
                            throw Abort(.badRequest, reason: "Failed to write tar archive to disk")
                        }

                        // `docker compose build` (classic builder) streams a build
                        // context whose final tar entry is not padded out to a 512-byte
                        // block and which omits the end-of-archive marker. The Docker
                        // daemon's Go tar reader tolerates this, but libarchive treats
                        // the short final block as a truncated archive and aborts
                        // extraction. Append a terminator of zero bytes so the last
                        // entry's block is completed and a valid end-of-archive marker
                        // is present. Trailing zeros after a well-formed archive are
                        // ignored, so this is safe for already-terminated contexts too.
                        try Self.appendTarTerminator(to: tarPath)

                        // Extract the tar archive
                        let extractDir = tempContextDir.appendingPathComponent("context")
                        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true, attributes: nil)

                        do {
                            try ArchiveUtility.extract(tarPath: tarPath, to: extractDir, logger: req.logger)
                        } catch {
                            req.logger.error("Tar extraction failed: \(error)")

                            throw Abort(.badRequest, reason: "Failed to extract tar archive: \(error.localizedDescription)")
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

            let buildArgs = BuildRoute.parseBuildQueryParam(query.buildargs)
            let labels = BuildRoute.parseBuildQueryParam(query.labels)

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
                            pull: pull,
                            target: target,
                            platforms: parsedPlatforms,
                            memory: memory,
                            quiet: quiet,
                            builderClient: builderClient,
                            systemConfig: systemConfig,
                            manifestClient: manifestClient,
                            manifestName: manifestName,
                            writer: writer,
                            logger: req.logger
                        )

                        // Clean up temporary context directory if it was created
                        if contextDir != "." {
                            try? FileManager.default.removeItem(at: tempContextDir)
                        }
                    } catch {
                        req.logger.error("Build failed: \(error)")

                        // Extract error message - prioritize ContainerizationError message
                        let errorMessage: String
                        if error is ContainerizationError {
                            // Use string interpolation to get ContainerizationError's description
                            errorMessage = "\(error)"
                        } else {
                            errorMessage = error.localizedDescription
                        }

                        // Docker API compliant error response
                        let errorDetail: [String: Any] = [
                            "message": errorMessage
                        ]

                        let errorResponse: [String: Any] = [
                            "errorDetail": errorDetail,
                            "error": errorMessage,
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
        pull: Bool,
        target: String,
        platforms: [Platform],
        memory: Int,
        quiet: Bool,
        builderClient: ClientBuilderProtocol,
        systemConfig: ContainerSystemConfig,
        manifestClient: ClientManifestServiceProtocol,
        manifestName: String?,
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

        // resolve the full path to the Dockerfile
        sendStreamMessage(" ---> Reading Dockerfile")
        let dockerfilePath = URL(fileURLWithPath: contextDir).appendingPathComponent(dockerfile).path
        logger.info("Reading Dockerfile at path: \(dockerfilePath)")

        guard let dockerfileData = try? Data(contentsOf: URL(filePath: dockerfilePath)) else {
            throw ContainerizationError(.invalidArgument, message: "Dockerfile does not exist at path: \(dockerfilePath)")
        }

        sendStreamMessage(" ---> Setting up build environment")
        let builderExportPath = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("com.apple.container/builder")

        // Validate and normalize image name
        let imageName: String = try {
            let parsedReference = try Reference.parse(targetImageName)
            parsedReference.normalize()
            return parsedReference.description
        }()

        // The two builder VMs are provisioned with mutually-exclusive emulation backends
        // (Rosetta 2 vs. generic QEMU binfmt) — a request mixing e.g. arm64/amd64 with
        // s390x can't be satisfied by either builder alone without emulating everything
        // through the slower one. Split into a build per backend, run them concurrently,
        // and merge the results, rather than routing the whole request to whichever
        // builder the least-native platform requires.
        let rosettaPlatforms = platforms.filter { !platformRequiresQEMU($0) }
        let qemuPlatforms = platforms.filter { platformRequiresQEMU($0) }

        let builtReference: String
        let builtDigest: String

        if rosettaPlatforms.isEmpty || qemuPlatforms.isEmpty {
            // Not a mixed request — single build, exactly as before.
            let result = try await runSingleBuild(
                dockerfile: dockerfile, dockerfileData: dockerfileData, contextDir: contextDir,
                buildArgs: buildArgs, labels: labels, noCache: noCache, pull: pull, target: target,
                platforms: platforms, qemu: !qemuPlatforms.isEmpty, tags: [imageName], quiet: quiet,
                builderExportPath: builderExportPath, buildIDSuffix: "single",
                builderClient: builderClient, systemConfig: systemConfig,
                sendStreamMessage: sendStreamMessage, logger: logger
            )
            builtReference = result.reference
            builtDigest = result.digest
        } else {
            sendStreamMessage(
                " ---> Splitting build: \(rosettaPlatforms.map(\.description).joined(separator: ",")) via Rosetta, "
                    + "\(qemuPlatforms.map(\.description).joined(separator: ",")) via QEMU"
            )

            // Scratch tags, unrelated to targetImageName's own reference syntax so there's
            // no need to parse/rewrite it — cleaned up below once merged. Filtered out of
            // `ClientImageService.list()` too (see `scratchTagPrefix`) so one that survives a
            // crash mid-build (before cleanup runs) doesn't linger forever in image listings.
            // Lowercased: Docker/OCI reference syntax requires a lowercase repository name,
            // and UUID().uuidString is uppercase.
            let requestID = UUID().uuidString.lowercased()
            let rosettaTag = "\(Self.scratchTagPrefix)\(requestID)-rosetta"
            let qemuTag = "\(Self.scratchTagPrefix)\(requestID)-qemu"

            async let rosettaResult = runSingleBuild(
                dockerfile: dockerfile, dockerfileData: dockerfileData, contextDir: contextDir,
                buildArgs: buildArgs, labels: labels, noCache: noCache, pull: pull, target: target,
                platforms: rosettaPlatforms, qemu: false, tags: [rosettaTag], quiet: quiet,
                builderExportPath: builderExportPath, buildIDSuffix: "rosetta",
                builderClient: builderClient, systemConfig: systemConfig,
                sendStreamMessage: sendStreamMessage, logger: logger
            )
            async let qemuResult = runSingleBuild(
                dockerfile: dockerfile, dockerfileData: dockerfileData, contextDir: contextDir,
                buildArgs: buildArgs, labels: labels, noCache: noCache, pull: pull, target: target,
                platforms: qemuPlatforms, qemu: true, tags: [qemuTag], quiet: quiet,
                builderExportPath: builderExportPath, buildIDSuffix: "qemu",
                builderClient: builderClient, systemConfig: systemConfig,
                sendStreamMessage: sendStreamMessage, logger: logger
            )

            // Awaited as two separate statements (not `try await (rosettaResult, qemuResult)`)
            // so BOTH are always fully settled before any cleanup runs — a tuple await short-
            // circuits on the first throw, without waiting for the other side, which could
            // still be mid-build (and mid-tagging `qemuTag`/`rosettaTag`) by the time cleanup
            // below runs, racing a delete against a still-in-progress create.
            let rosettaOutcome: Result<(reference: String, digest: String), Error>
            do { rosettaOutcome = .success(try await rosettaResult) } catch { rosettaOutcome = .failure(error) }
            let qemuOutcome: Result<(reference: String, digest: String), Error>
            do { qemuOutcome = .success(try await qemuResult) } catch { qemuOutcome = .failure(error) }

            switch (rosettaOutcome, qemuOutcome) {
            case (.success(let rosetta), .success(let qemu)):
                sendStreamMessage(" ---> Merging split builds into \(imageName)")
                do {
                    builtDigest = try await manifestClient.mergeAndTag(name: imageName, images: [rosetta.reference, qemu.reference], logger: logger)
                } catch {
                    // Both halves succeeded and are still tagged — clean up regardless of
                    // whether the merge itself succeeded, or these scratch tags leak forever.
                    try? await manifestClient.delete(name: rosettaTag)
                    try? await manifestClient.delete(name: qemuTag)
                    throw error
                }
                try? await manifestClient.delete(name: rosettaTag)
                try? await manifestClient.delete(name: qemuTag)
                builtReference = imageName
            case (.failure(let rosettaError), .failure(let qemuError)):
                // Both halves failed — the thrown error only ever carries one of them
                // (matching the single-failure case below), so log the other rather than
                // silently dropping a second, independently useful failure reason.
                logger.error("QEMU build also failed (Rosetta error is being thrown): \(qemuError)")
                try? await manifestClient.delete(name: rosettaTag)
                try? await manifestClient.delete(name: qemuTag)
                throw rosettaError
            case (.failure(let error), _), (_, .failure(let error)):
                // Best-effort clean up whichever scratch tag DID get written (a delete of one
                // that was never created is a harmless no-op) before propagating — safe now
                // that both outcomes are guaranteed settled.
                try? await manifestClient.delete(name: rosettaTag)
                try? await manifestClient.delete(name: qemuTag)
                throw error
            }
        }

        // `--manifest <name>`: fold the just-built image's platform(s) into a named manifest
        // list, creating it if it doesn't exist yet — this is podman's real multi-arch
        // workflow (see containers/podman#27211): a bare multi-platform build alone never
        // produces one on the real client. Runs before the success message/stream close
        // (not as a best-effort afterthought) so a registration failure is reported as a
        // build failure instead of silently succeeding with an unregistered manifest.
        if let manifestName {
            sendStreamMessage(" ---> Adding to manifest list \(manifestName)")
            try await manifestClient.addBuiltImage(name: manifestName, builtReference: builtReference, logger: logger)
        }

        // Real podman clients (pkg/bindings/images/build.go) only treat a clean
        // stream EOF as success if they've already seen a "stream" line whose
        // content starts with 12+ raw hex chars (`iidRegex`) — otherwise EOF is
        // reported as `Error: decoding stream: EOF` even though the build (and
        // this response) genuinely succeeded. Real buildah/podman builds emit
        // the bare image ID as its own stream line for exactly this reason;
        // mirror that here so the client recognizes success.
        let bareID = builtDigest.hasPrefix("sha256:") ? String(builtDigest.dropFirst("sha256:".count)) : builtDigest
        sendStreamMessage(bareID)

        // Send success message in Docker API format
        sendStreamMessage("Successfully built \(imageName)")

        _ = writer.write(.end)
    }

    /// Runs a single BuildKit solve against one builder backend and loads/unpacks its
    /// output, returning the resulting image's reference and digest. Factored out of
    /// `performBuild` so a mixed-platform request can call this twice (once per backend)
    /// instead of duplicating the whole connect/build/load/unpack sequence inline.
    private static func runSingleBuild(
        dockerfile: String,
        dockerfileData: Data,
        contextDir: String,
        buildArgs: [String],
        labels: [String],
        noCache: Bool,
        pull: Bool,
        target: String,
        platforms: [Platform],
        qemu: Bool,
        tags: [String],
        quiet: Bool,
        builderExportPath: URL,
        buildIDSuffix: String,
        builderClient: ClientBuilderProtocol,
        systemConfig: ContainerSystemConfig,
        sendStreamMessage: @escaping @Sendable (String) -> Void,
        logger: Logger
    ) async throws -> (reference: String, digest: String) {
        let timeout: Duration = .seconds(300)

        sendStreamMessage(" ---> Connecting to build daemon (\(qemu ? "QEMU" : "Rosetta") builder)")
        let builder = try await builderClient.connect(
            timeout: timeout,
            retryInterval: .seconds(1),
            qemu: qemu,
            logger: logger
        )
        sendStreamMessage(" ---> Successfully connected to builder")

        let buildID = "\(UUID().uuidString)-\(buildIDSuffix)"
        let tempURL = builderExportPath.appendingPathComponent(buildID)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)
        // The exported OCI tarball is only needed for the ClientImage.load below — clean up
        // this per-build export directory on every exit path (success or failure) rather than
        // leaking it under Application Support forever.
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exports: [Builder.BuildExport] = try ["type=oci"].map { output in
            var exp = try Builder.BuildExport(from: output)
            if exp.destination == nil {
                exp.destination = tempURL.appendingPathComponent("out.tar")
            }
            return exp
        }

        let config = ContainerBuild.Builder.BuildConfig(
            buildID: buildID,
            contentStore: RemoteContentStoreClient(),
            buildArgs: buildArgs,
            // TODO: Implement secrets once integration with buildkit materializes
            secrets: [:],
            contextDir: contextDir,
            dockerfile: dockerfileData,
            dockerignore: nil,
            labels: labels,
            noCache: noCache,
            platforms: platforms,
            terminal: nil,  // No terminal for API
            tags: tags,
            target: target,
            quiet: quiet,
            exports: exports,
            cacheIn: [],
            cacheOut: [],
            pull: pull,
            containerSystemConfig: systemConfig
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

        for image in loaded.images {
            sendStreamMessage(" ---> Unpacking image layers")
            try await image.unpack(platform: nil, progressUpdate: { _ in })
        }

        // The loader tags images verbatim (e.g. `<uuid>:latest`, no `docker.io/library/`
        // prefix) — the as-stored reference is what later lookups (retag, manifest merge)
        // must use, not a re-derivation of the requested tag through normalization.
        guard let firstImage = loaded.images.first else {
            throw ContainerizationError(.internalError, message: "Build produced no image")
        }
        return (reference: firstImage.reference, digest: firstImage.digest)
    }
}
