import Foundation
import Vapor

public enum UnixSocketError: Error {
    case missingHomeDirectory
}

public func prepareUnixSocket(for app: Application, homeDirectory: String? = nil) throws {
    guard let homeDir = homeDirectory else {
        throw UnixSocketError.missingHomeDirectory
    }

    let fileManager = FileManager.default
    let socketDirectory = "\(homeDir)/.socktainer"
    let socketPath = "\(socketDirectory)/container.sock"

    if !fileManager.fileExists(atPath: socketDirectory) {
        try fileManager.createDirectory(atPath: socketDirectory, withIntermediateDirectories: true)
    }

    if fileManager.fileExists(atPath: socketPath) {
        try fileManager.removeItem(atPath: socketPath)
    }

    if !fileManager.fileExists(atPath: socketDirectory) {
        try fileManager.createDirectory(atPath: socketDirectory, withIntermediateDirectories: true)
    }

    if fileManager.fileExists(atPath: socketPath) {
        try fileManager.removeItem(atPath: socketPath)
    }

    app.http.server.configuration.hostname = ""
    app.http.server.configuration.port = 0
    app.http.server.configuration.address = .unixDomainSocket(path: socketPath)
}
