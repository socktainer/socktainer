import NIO
import NIOHTTP1
import Foundation
enum ContainerInspectError: Error {
    case missingContainerID
    case containerNotFound
    case serializationFailed
}

public struct ContainerInspectRoute: HTTPRoute {
    public let methods: [HTTPMethod] = [.GET]
    public let paths: [String] = ["/:version/containers/:id/json", "/containers/:id/json"]

    public init() {}

    public func handle(requestHead: HTTPRequestHead,
                       channel: Channel,
                       client: any ClientProtocol,
                       body: Data?) async throws {

        print("[ContainerInspectRoute] Entered handle()")
        print("[ContainerInspectRoute] RequestHead: \(requestHead)")

        // Extract id from path
        let pathComponents = requestHead.uri.split(separator: "/")
                guard let idIndex = pathComponents.firstIndex(where: { $0 == "containers" })?.advanced(by: 1),
                            pathComponents.count > idIndex else {
                        print("[ContainerInspectRoute] Could not extract container id from path: \(requestHead.uri)")
                        throw ContainerInspectError.missingContainerID
                }
        let id = String(pathComponents[idIndex])
        print("[ContainerInspectRoute] Extracted id: \(id)")

        // Fetch container
                // Ensure client has getContainer method
               
                guard let container = try await client.getContainer(id: id) else {
                        print("[ContainerInspectRoute] Container not found: \(id)")
                        throw ContainerInspectError.containerNotFound
                }


        // Build response JSON
        let responseDict: [String: Any] = [
            "Id": container.id,
            "Names": ["/" + container.id],
            "Image": container.configuration.image.reference,
            "ImageID": container.configuration.image.digest,
            "State": [
                "Status": container.status.rawValue
            ]
        ]

        let jsonData: Data
        do {
            jsonData = try JSONSerialization.data(withJSONObject: responseDict, options: [])
        } catch {
            print("[ContainerInspectRoute] Failed to serialize JSON: \(error)")
            throw ContainerInspectError.serializationFailed
        }

        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "\(jsonData.count)")
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Api-Version", value: "1.51")
        headers.add(name: "Cache-Control", value: "no-cache, no-store, must-revalidate")
        headers.add(name: "Pragma", value: "no-cache")

        let responseHead = HTTPResponseHead(version: requestHead.version, status: .ok, headers: headers)
        let eventLoop = channel.eventLoop
        eventLoop.execute {
            channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
            var buffer = channel.allocator.buffer(capacity: jsonData.count)
            buffer.writeBytes(jsonData)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        }
    }
}
