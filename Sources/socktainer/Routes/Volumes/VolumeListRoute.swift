import Vapor

struct VolumeListResponse: Content {
    let Volumes: [VolumeInfo]
    let Warnings: [String]
}

struct RESTVolumesListQuery: Content {
    let filters: String?
}

struct VolumeListRoute: RouteCollection {
    let client: ClientVolumeService
    init(client: ClientVolumeService) {
        self.client = client
    }

    func boot(routes: RoutesBuilder) throws {
        try routes.registerVersionedRoute(.GET, pattern: "/volumes", use: self.handler)
    }

    func handler(_ req: Request) async throws -> VolumeListResponse {
        let logger = req.logger
        let query = try req.query.decode(RESTVolumesListQuery.self)
        let filtersParam = query.filters
        let parsedFilters = try DockerVolumeFilterUtility.parseVolumeFilters(filtersParam: filtersParam, logger: logger)
        let filtersJSON = try JSONEncoder().encode(parsedFilters)
        let filtersJSONString = String(data: filtersJSON, encoding: .utf8)
        let filteredVolumes = try await client.list(filters: filtersJSONString, logger: logger)

        let volumeInfos = filteredVolumes.map { v in
            VolumeInfo(
                CreatedAt: v.CreatedAt ?? "",
                Driver: v.Driver,
                Labels: v.Labels,
                Mountpoint: v.Mountpoint,
                Name: v.Name,
                Options: v.Options,
                Scope: v.Scope,
                Status: v.Status,
                UsageData: v.UsageData
            )
        }

        let response = VolumeListResponse(
            Volumes: volumeInfos,
            Warnings: []  // we are not deriving any issues at the moment
        )
        return response
    }
}
