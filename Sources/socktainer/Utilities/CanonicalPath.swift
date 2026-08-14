import Darwin
import Foundation

func canonicalFileURL(_ url: URL) -> URL {
    var existingAncestor = url.standardizedFileURL
    var missingComponents: [String] = []

    while true {
        if let resolvedPath = Darwin.realpath(existingAncestor.path, nil) {
            defer { Darwin.free(resolvedPath) }
            return missingComponents.reversed().reduce(
                URL(fileURLWithPath: String(cString: resolvedPath))
            ) { result, component in
                result.appendingPathComponent(component)
            }
        }
        guard existingAncestor.path != "/" else { return url.standardizedFileURL }
        missingComponents.append(existingAncestor.lastPathComponent)
        existingAncestor.deleteLastPathComponent()
    }
}
