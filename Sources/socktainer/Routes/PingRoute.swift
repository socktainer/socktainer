import NIO
import NIOHTTP1
import Foundation

public struct PingRoute: HTTPRoute {
    public let methods: [HTTPMethod] = [.GET, .HEAD]
    public let paths: [String] = ["/_ping"]

    public init() {}

    public func handle(requestHead: HTTPRequestHead,
                       channel: Channel,
                       client: any ClientProtocol,
                       body: Data?) async throws {

    // print("[PingRoute] Entered handle()")
        print("[PingRoute] RequestHead: \(requestHead)")
        do {
            try await client.ping()
            print("[PingRoute] client.ping() succeeded")
        } catch {
            print("[PingRoute] client.ping() failed: \(error)")
            throw error
        }

    print("[PingRoute] Preparing response headers")
    var headers = HTTPHeaders()
    headers.add(name: "Content-Length", value: "2")
    headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
    headers.add(name: "Api-Version", value: "1.51")
    headers.add(name: "Cache-Control", value: "no-cache, no-store, must-revalidate")
    headers.add(name: "Pragma", value: "no-cache")

        // Send HTTP response on the channel's event loop
        let responseHead = HTTPResponseHead(version: requestHead.version, status: .ok, headers: headers)
        let eventLoop = channel.eventLoop
        print("[PingRoute] Sending response on event loop")
        eventLoop.execute {
            print("[PingRoute] Writing response head")
            channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
            if requestHead.method != .HEAD {
                var buffer = channel.allocator.buffer(capacity: 2)
                buffer.writeString("OK")
                print("[PingRoute] Writing response body")
                channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
            }
            print("[PingRoute] Flushing response end")
            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
        }
    }
}
