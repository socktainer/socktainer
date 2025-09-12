import NIO           // for Channel, ByteBuffer
import NIOHTTP1      // for HTTPRequestHead, HTTPMethod
import Foundation

public final class HTTPRouter: @unchecked Sendable {
    private var routes: [HTTPRoute] = []
    
    public func register(route: HTTPRoute) {
        print("[HTTPRouter] Registering route: \(type(of: route)) with paths: \(route.paths)")
        routes.append(route)
        print("[HTTPRouter] Total routes registered: \(routes.count)")
    }
    
    public func route(requestHead: HTTPRequestHead, channel: Channel, client: any ClientProtocol, body: Data? = nil) async throws -> Bool {
        print("[HTTPRouter] Routing request: \(requestHead.method) \(requestHead.uri)")
        print("[HTTPRouter] Total registered routes: \(routes.count)")
        for (i, route) in routes.enumerated() {
            //print("[HTTPRouter] Checking route \(i): \(type(of: route)) with methods: \(route.methods)")
            guard route.methods.contains(requestHead.method) else { 
                //print("[HTTPRouter] Route \(i) \(type(of: route)) skipped - method mismatch")
                continue 
            }
            for pathPattern in route.paths {
                //print("[HTTPRouter] Checking route \(i) \(type(of: route)) with path pattern: \(pathPattern) against request: \(requestHead.uri)")
                if match(routePath: pathPattern, requestPath: requestHead.uri) {
                    print("[HTTPRouter] Route matched: \(type(of: route)) with pattern \(pathPattern) for request: \(requestHead.uri)")
                    try await route.handle(requestHead: requestHead, channel: channel, client: client, body: body)
                    return true
                } else {
                    //print("[HTTPRouter] Route \(i) \(type(of: route)) with pattern \(pathPattern) did NOT match request: \(requestHead.uri)")
                }
            }
        }
        print("[HTTPRouter] No route matched for request: \(requestHead.method) \(requestHead.uri)")
        return false
    }
    
    private func match(routePath: String, requestPath: String) -> Bool {
        // Strip query parameters from requestPath
        let pathOnly = requestPath.split(separator: "?").first.map(String.init) ?? requestPath
        let routeComponents = routePath.split(separator: "/")
        let requestComponents = pathOnly.split(separator: "/")
        //print("[HTTPRouter] Matching routePath: \(routePath) (components: \(routeComponents)) against requestPath: \(pathOnly) (components: \(requestComponents))")
        guard routeComponents.count == requestComponents.count else { 
            //print("[HTTPRouter] Component count mismatch: route has \(routeComponents.count), request has \(requestComponents.count)")
            return false 
        }
        
        for (i, (r, req)) in zip(routeComponents, requestComponents).enumerated() {
            if r.hasPrefix(":") { 
                //print("[HTTPRouter] Component \(i): '\(r)' is dynamic, matches '\(req)'")
                continue 
            } // dynamic segment
            if r != req { 
                //print("[HTTPRouter] Component \(i): route '\(r)' != request '\(req)' - NO MATCH")
                return false 
            }
            //print("[HTTPRouter] Component \(i): route '\(r)' == request '\(req)' - MATCH")
        }
        //print("[HTTPRouter] All components matched - SUCCESS")
        return true
    }
}