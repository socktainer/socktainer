import Containerization
import Foundation
import Synchronization

/// One `ImageStore` per store path, shared by every request.
///
/// `ImageStore` updates `state.json` with an unlocked read-modify-write that only
/// its own actor serializes. Two instances on the same path, such as two concurrent
/// `docker load`s, can each read the file before either writes it, and the later
/// write puts back the other's old reference (issue #518).
enum SharedImageStore {
    private static let stores = Mutex<[String: ImageStore]>([:])

    static func store(path: URL) throws -> ImageStore {
        let key = path.standardizedFileURL.path
        return try stores.withLock { stores in
            if let existing = stores[key] {
                return existing
            }
            let created = try ImageStore(path: path)
            stores[key] = created
            return created
        }
    }
}
