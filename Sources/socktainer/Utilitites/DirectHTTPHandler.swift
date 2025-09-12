import NIO
import NIOHTTP1
import Foundation

final class DirectHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: HTTPRouter
    private let client: any ClientProtocol

    init(router: HTTPRouter, client: any ClientProtocol) {
        self.router = router
        self.client = client
    }

    private var currentHead: HTTPRequestHead?
    private var accumulatedBody = Data()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let requestPart = self.unwrapInboundIn(data)
        switch requestPart {
        case .head(let requestHead):
            print("[DirectHTTPHandler] Received request: \(requestHead.method) \(requestHead.uri)")
            print("[DirectHTTPHandler] Request headers: \(requestHead.headers)")
            self.currentHead = requestHead
            self.accumulatedBody.removeAll(keepingCapacity: true)

        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                self.accumulatedBody.append(contentsOf: bytes)
            }

        case .end:
            guard let requestHead = self.currentHead else { return }
            let channel = context.channel
            let eventLoop = context.eventLoop
            let bodyData = self.accumulatedBody.isEmpty ? nil : self.accumulatedBody
            print("[DirectHTTPHandler] About to route request with body size: \(bodyData?.count ?? 0)")
            Task {
                do {
                    print("[DirectHTTPHandler] Routing request...", channel)
                    let handled = try await router.route(
                        requestHead: requestHead,
                        channel: channel,
                        client: client,
                        body: bodyData
                    )
                    print("[DirectHTTPHandler] Routing result: handled=\(handled)")
                    if !handled {
                        let responseHead = HTTPResponseHead(version: requestHead.version, status: .notFound)
                        eventLoop.execute {
                            channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
                            channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
                        }
                    }
                } catch {
                    print("[DirectHTTPHandler] Error handling request: \(error)")
                    let responseHead = HTTPResponseHead(version: requestHead.version, status: .internalServerError)
                    eventLoop.execute {
                        channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
                        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
                    }
                }
            }
            self.currentHead = nil
            self.accumulatedBody.removeAll(keepingCapacity: true)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("[DirectHTTPHandler] HTTP Error: \(error)")
        context.close(promise: nil)
    }
}
