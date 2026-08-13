import Foundation

enum SocktainerDirectories {
    static var hostHome: URL {
        hostHome(environment: ProcessInfo.processInfo.environment)
    }

    static func hostHome(
        environment: [String: String],
        fallback: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["SOCKTAINER_HOST_HOME_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return fallback
    }
}
