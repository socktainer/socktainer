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
}
