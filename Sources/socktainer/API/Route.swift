import NIO
import NIOHTTP1
import Foundation

public protocol HTTPRoute {
    var methods: [HTTPMethod] { get }
    var paths: [String] { get }

    /// `body` is the full request body, if any. Implementations may ignore it.
    func handle(requestHead: HTTPRequestHead,
                channel: Channel,
                client: any ClientProtocol,
                body: Data?) async throws
}