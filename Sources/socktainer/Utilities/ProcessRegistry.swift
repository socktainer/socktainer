import ContainerAPIClient

/// Shared registry of running ClientProcess instances keyed by container or exec ID.
/// Allows the resize routes to forward terminal size changes to the active process
/// without threading the process reference through the HTTP layer.
actor ProcessRegistry {
    static let shared = ProcessRegistry()

    private var processes: [String: any ClientProcess] = [:]

    func set(id: String, process: any ClientProcess) {
        processes[id] = process
    }

    func get(id: String) -> (any ClientProcess)? {
        processes[id]
    }

    func remove(id: String) {
        processes.removeValue(forKey: id)
    }
}
