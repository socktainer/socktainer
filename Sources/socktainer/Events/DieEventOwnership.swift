/// Guarantees exactly one observer broadcasts `die` for a container's current run.
///
/// Two observers can watch the same exit:
/// - `ContainerStartRoute.observeExit`, armed when `POST /start` returns;
/// - `ContainerProcessExitMonitor`, which owns containers the attach route bootstrapped.
///
/// `docker run` goes through both (attach, then start) and must produce a single `die`.
/// `docker compose up` attaches to a stopped container and never calls `/start`, so without
/// the monitor emitting the event nothing does — and Compose's `--abort-on-container-exit`
/// waits forever for an exit it can never observe.
actor DieEventOwnership {
    static let shared = DieEventOwnership()

    private var owners: Set<String> = []

    /// Returns true when the caller becomes the sole owner of this container's `die` event.
    func claim(id: String) -> Bool {
        owners.insert(id).inserted
    }

    func release(id: String) {
        owners.remove(id)
    }
}
