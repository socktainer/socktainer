import Foundation

actor ContainerInfoCache {
    static let shared = ContainerInfoCache()

    struct Info {
        let hexId: String
        let nativeId: String
        let image: String
        let labels: [String: String]
    }

    private var store: [String: Info] = [:]

    /// Maps each id of a `--rm` container (both hex and native) to its sibling id, so a
    /// consume by either id can atomically clear both. Kept separate from `store` so the
    /// routine `set()` at /start can't clobber it, and self-contained so the pairing does not
    /// depend on a `store` entry existing at consume time.
    private var autoRemoveSibling: [String: String] = [:]

    func set(hexId: String, nativeId: String, image: String, labels: [String: String]) {
        let info = Info(hexId: hexId, nativeId: nativeId, image: image, labels: labels)
        store[hexId] = info
        store[nativeId] = info
    }

    func get(id: String) -> Info? {
        store[id]
    }

    func remove(id: String) {
        if let info = store[id] {
            store.removeValue(forKey: info.hexId)
            store.removeValue(forKey: info.nativeId)
        }
    }

    /// Records that a container was created with `--rm`, keyed by both ids so either the
    /// hex (attach route) or native (die observer) lookup finds it.
    func markAutoRemove(hexId: String, nativeId: String) {
        autoRemoveSibling[hexId] = nativeId
        autoRemoveSibling[nativeId] = hexId
    }

    /// Atomically returns `true` exactly once if the container (by either id) was marked
    /// `--rm`, clearing the mark. This is both the auto-remove gate and the destroy dedup:
    /// whichever path (foreground attach or detached die observer) reaches it first emits the
    /// `destroy` event; the other sees `false` and skips — so exactly one destroy fires, matching
    /// moby's single post-`die` destroy for `--rm` containers.
    func consumeAutoRemove(id: String) -> Bool {
        guard let sibling = autoRemoveSibling[id] else { return false }
        autoRemoveSibling.removeValue(forKey: id)
        autoRemoveSibling.removeValue(forKey: sibling)
        return true
    }
}
