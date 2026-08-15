import Foundation
import Testing
import Vapor
import VaporTesting

@testable import GlassDock

@Suite("Docker events query semantics")
struct EventsRouteFilterTests {
    @Test("event stream flushes immediately before the first event")
    func streamFlushesImmediately() async throws {
        try await withApp(configure: { _ in }) { app in
            let regexRouter = app.regexRouter(with: app.logger)
            app.setRegexRouter(regexRouter)
            regexRouter.installMiddleware(on: app)
            app.storage[EventBroadcasterKey.self] = EventBroadcaster()
            try app.register(collection: EventsRoute())

            try await app.testing().test(.GET, "/v1.51/events?until=0") { response async in
                #expect(response.status == .ok)
                #expect(response.body.getString(at: 0, length: response.body.readableBytes) == "\n")
            }
        }
    }

    @Test("container names and Docker ID prefixes round-trip through event filters")
    func containerIdentityFilter() throws {
        let id = String(repeating: "a", count: 64)
        let event = DockerEvent.simpleEvent(
            id: id,
            type: "container",
            status: "start",
            image: "postgres:17",
            name: "project-db-1",
            labels: ["com.docker.compose.project": "project"]
        )

        #expect(try DockerEventFilter(#"{"container":["project-db-1"]}"#).matches(event))
        #expect(try DockerEventFilter(#"{"container":["aaaaaaaaaaaa"]}"#).matches(event))
        #expect(try DockerEventFilter(#"{"container":["st-opaque-native"]}"#).matches(event) == false)
    }

    @Test("different event filter keys compose with AND semantics")
    func combinedFilters() throws {
        let event = DockerEvent.simpleEvent(
            id: String(repeating: "b", count: 64),
            type: "container",
            status: "exec_start: sh -c true",
            image: "alpine:3.22",
            name: "worker",
            labels: ["role": "worker", "tier": "background"]
        )

        let matching = try DockerEventFilter(
            #"{"type":["container"],"event":["exec_start"],"image":["alpine:3.22"],"label":["role=worker","tier"]}"#
        )
        #expect(matching.matches(event))
        #expect(try DockerEventFilter(#"{"type":["image"]}"#).matches(event) == false)
        #expect(try DockerEventFilter(#"{"label":["role=api"]}"#).matches(event) == false)
    }

    @Test("legacy boolean-map filter encoding remains accepted")
    func legacyFilterEncoding() throws {
        let event = DockerEvent.simpleEvent(
            id: "volume-id", type: "volume", status: "create", name: "database"
        )
        let filter = try DockerEventFilter(
            #"{"type":{"volume":true,"container":false},"volume":{"database":true}}"#
        )
        #expect(filter.matches(event))
    }

    @Test("unknown and malformed filters are rejected")
    func invalidFilters() {
        #expect(throws: Abort.self) {
            _ = try DockerEventFilter(#"{"unsupported":["value"]}"#)
        }
        #expect(throws: Abort.self) {
            _ = try DockerEventFilter("not-json")
        }
    }

    @Test("timestamps accept Unix, RFC3339, and compound duration forms")
    func timestamps() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(try EventsRoute.eventTimestamp("123.5", relativeTo: now) == 123_500_000_000)
        #expect(
            try EventsRoute.eventTimestamp("1970-01-01T00:02:03Z", relativeTo: now)
                == 123_000_000_000
        )
        #expect(
            try EventsRoute.eventTimestamp("1h30m", relativeTo: now)
                == 4_600_000_000_000
        )
        #expect(throws: Abort.self) {
            _ = try EventsRoute.eventTimestamp("tomorrow-ish", relativeTo: now)
        }
    }

    @Test("since replays bounded daemon history without a subscription race")
    func sinceHistory() async {
        let broadcaster = EventBroadcaster()
        let first = DockerEvent.simpleEvent(id: "one", type: "container", status: "create")
        let second = DockerEvent.simpleEvent(id: "two", type: "container", status: "start")
        await broadcaster.broadcast(first)
        await broadcaster.broadcast(second)

        let stream = await broadcaster.stream(since: first.timeNano, until: second.timeNano)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.id == "one")
        #expect(await iterator.next()?.id == "two")
        #expect(await iterator.next() == nil)
    }
}
