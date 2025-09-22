import Vapor

struct RESTNetworksListQuery: Content {
    let dangling: String?
    let driver: String?
    let id: String?
    let label: String?
    let name: String?
    let scope: String?
    let type: String?
}

public struct NetworkListFilters {
    public let dangling: Bool?
    public let driver: String?
    public let id: String?
    public let label: [String]?
    public let name: String?
    public let scope: String?
    public let type: String?

    public init(
        dangling: Bool? = nil,
        driver: String? = nil,
        id: String? = nil,
        label: [String]? = nil,
        name: String? = nil,
        scope: String? = nil,
        type: String? = nil
    ) {
        self.dangling = dangling
        self.driver = driver
        self.id = id
        self.label = label
        self.name = name
        self.scope = scope
        self.type = type
    }
}

struct NetworkListRoute: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get(":version", "networks", use: NetworkListRoute.handler)
    }

    static func handler(_ req: Request) async throws -> Response {
        let networkClient = ClientNetworkService()
        let filtersParam = try? req.query.get(String.self, at: "filters")

        var filters: [String: Any] = [:]
        var parsedFilters: [String: [String]] = [:]
        if let filtersParam = filtersParam, let data = filtersParam.data(using: .utf8) {
            if let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                filters = decoded
                for (key, value) in filters {
                    if let dict = value as? [String: Any] {
                        let keys = dict.compactMap { (key, value) in
                            (value as? Bool == true) ? key : nil
                        }
                        if !keys.isEmpty {
                            parsedFilters[key] = keys
                        }
                    } else if let arr = value as? [String] {
                        parsedFilters[key] = arr
                    }
                }
                req.logger.debug("Decoded filters: \(parsedFilters)")
            } else {
                req.logger.warning("Failed to decode filters")
            }
        }

        let filtersJSON = try JSONEncoder().encode(parsedFilters)
        let filtersJSONString = String(data: filtersJSON, encoding: .utf8)

        do {
            let networks = try await networkClient.list(filters: filtersJSONString, logger: req.logger)
            return Response(status: .ok, body: .init(data: try JSONEncoder().encode(networks)))
        } catch {
            return Response(status: .internalServerError, body: .init(string: "Failed to list networks: \(error)"))
        }
    }
}
