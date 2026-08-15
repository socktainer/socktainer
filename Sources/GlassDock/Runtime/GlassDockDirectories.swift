import Darwin
import Foundation

enum GlassDockDirectories {
    static var hostHome: URL {
        hostHome(environment: ProcessInfo.processInfo.environment)
    }

    static var engineStateDirectory: URL {
        engineStateDirectory(environment: ProcessInfo.processInfo.environment)
    }

    static func engineStateDirectory(environment: [String: String]) -> URL {
        if let override = environment["GLASSDOCK_ENGINE_STATE_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return URL(
            fileURLWithPath: "/private/var/tmp/glassdock-\(Darwin.getuid())/engine",
            isDirectory: true
        )
    }

    static func hostHome(
        environment: [String: String],
        fallback: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["GLASSDOCK_HOST_HOME_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return fallback
    }
}
