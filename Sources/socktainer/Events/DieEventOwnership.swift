/// Guarantees exactly one observer broadcasts `die` per container run.
///
/// Two observers can watch the same exit:
/// - `ContainerStartRoute.observeExit`, armed when `POST /start` returns;
/// - `ContainerProcessExitMonitor`, which owns containers the attach route bootstrapped.
///
/// `docker run` goes through both (attach, then start) and must produce a single `die`.
/// `docker compose up` attaches to a stopped container and never calls `/start`, so without
/// the monitor emitting the event nothing does — and Compose's `--abort-on-container-exit`
/// waits forever for an exit it can never observe.
///
/// Ownership is scoped to a *run*, identified by the epoch `beginRun` returns, and the winner
/// keeps it for the rest of that run: handing it back after broadcasting lets the loser — which
/// reaches the same exit moments later — take the reopened claim and emit a second `die`. Every
/// observer carries the epoch of the run it watches, so a monitor still resolving a slow exit
/// cannot claim the *next* run and silence it.
///
/// Epochs come from one counter shared by every container and are never reused, because
/// container names are: `compose up` after `down` recreates a service's container under the same
/// name. With per-container numbering the recreated container would be handed epoch 1 again, and
/// the deleted container's lagging observer could claim it — emitting a stale `die` and leaving
/// the new run unable to report its own exit. A claim naming a run that is no longer tracked is
/// refused rather than treated as a fresh one.
///
/// Between the two observers the start-route one is preferred: its event carries `execDuration`
/// and the container's post-start labels, which the monitor cannot see. It therefore *reserves*
/// the run when it arms, and the monitor defers to that reservation. A redundant `POST /start`
/// arms a newer observer and supersedes the older reservation, so the observer that survives the
/// generation check is the one that emits.
actor DieEventOwnership {
    static let shared = DieEventOwnership()

    private struct Run {
        /// Generation of the start-route observer that intends to emit, if one armed.
        var reservedGeneration: Int?
        /// Set once an observer has taken this run's `die` event.
        var emitterDecided = false
    }

    private struct RunKey: Hashable {
        let id: String
        let epoch: Int
    }

    private var nextEpoch = 0
    private var currentEpochs: [String: Int] = [:]
    private var previousEpochs: [String: Int] = [:]
    private var runs: [RunKey: Run] = [:]
    private var pendingForget: Set<RunKey> = []

    /// Opens a run for `id` and returns its epoch, or joins the run already open.
    ///
    /// Called where the container starts executing: the attach route's bootstrap, and a
    /// `POST /start` whether or not it was the request that started it. `docker run` does both
    /// concurrently — it attaches and starts, and whichever request wins the race starts the
    /// container while the other gets a benign "already booted". Joining an open run is what
    /// keeps that pair on one run: two runs for one physical exit would let each side's observer
    /// claim its own and emit a `die` apiece. A run whose exit was already reported is finished,
    /// so the next start opens a fresh one.
    func beginRun(id: String) -> Int {
        if let epoch = currentEpochs[id], let run = runs[RunKey(id: id, epoch: epoch)], !run.emitterDecided {
            return epoch
        }
        return openRun(id: id)
    }

    /// Opens a run for a container the caller just stopped and started again — `POST /restart`
    /// and restart-policy restarts. Unconditional, because the stop ended the previous run even
    /// if its exit has not been reported yet; joining it would leave the new run unreportable.
    func beginRestartedRun(id: String) -> Int {
        openRun(id: id)
    }

    private func openRun(id: String) -> Int {
        nextEpoch += 1

        // The run before last is unreachable: both its observers have had a full run to report
        // it. The immediately previous one is kept, because a monitor can still be resolving its
        // exit code while the container is already running again.
        if let stale = previousEpochs[id] {
            runs.removeValue(forKey: RunKey(id: id, epoch: stale))
        }
        previousEpochs[id] = currentEpochs[id]
        currentEpochs[id] = nextEpoch
        runs[RunKey(id: id, epoch: nextEpoch)] = Run()
        return nextEpoch
    }

    /// Declares that a start-route observer of `generation` will emit this run's `die`.
    /// Supersedes an older generation's reservation, so a redundant `/start` moves the
    /// obligation to the observer that will actually pass its generation check.
    func reserveForStart(id: String, epoch: Int, generation: Int) {
        let key = RunKey(id: id, epoch: epoch)
        guard var run = runs[key] else { return }
        run.reservedGeneration = generation
        runs[key] = run
    }

    /// Called by a start-route observer once its generation check passed and it is about to
    /// broadcast. False means this run was already reported — by the exit monitor, when the
    /// container exited before this observer armed — or is no longer tracked at all.
    func claimForStart(id: String, epoch: Int, generation: Int) -> Bool {
        let key = RunKey(id: id, epoch: epoch)
        guard var run = runs[key], !run.emitterDecided, run.reservedGeneration == generation else { return false }
        run.emitterDecided = true
        runs[key] = run
        settle(key)
        return true
    }

    /// Called by the attach paths' exit monitor. False means a start-route observer reserved
    /// this run — `docker run` — and will emit the richer event, the run is already reported, or
    /// it is no longer tracked.
    func claimForMonitor(id: String, epoch: Int) -> Bool {
        let key = RunKey(id: id, epoch: epoch)
        guard var run = runs[key], !run.emitterDecided, run.reservedGeneration == nil else { return false }
        run.emitterDecided = true
        runs[key] = run
        settle(key)
        return true
    }

    /// Drops a removed container's die-event bookkeeping.
    ///
    /// A run whose exit was already reported is dropped outright: a claim naming an untracked run
    /// is refused, so an observer arriving after the record is gone cannot emit a second `die`
    /// for that exit. That is the `--rm` path, which cleans up *after* broadcasting.
    ///
    /// A run still open keeps its record. `docker rm -f` stops and deletes a running container,
    /// and its exit monitor resolves the code (behind a flush grace) only after the delete has
    /// landed — refusing that claim would turn `die` into a race with teardown and drop the event
    /// Docker does send. The container's name stops pointing at that run either way, so a
    /// container recreated under the same name opens its own instead of joining a dead one. The
    /// record is released once the pending observer reports the exit.
    func forget(id: String) {
        if let stale = previousEpochs.removeValue(forKey: id) {
            runs.removeValue(forKey: RunKey(id: id, epoch: stale))
        }

        guard let epoch = currentEpochs.removeValue(forKey: id) else { return }
        let key = RunKey(id: id, epoch: epoch)
        guard runs[key]?.emitterDecided ?? true else {
            pendingForget.insert(key)
            return
        }
        runs.removeValue(forKey: key)
    }

    /// Releases a removed container's last record once its exit has been reported, so nothing is
    /// retained for a container that no longer exists. Keyed by the run rather than the name,
    /// because a recreated container reuses the name while its runs are distinct.
    private func settle(_ key: RunKey) {
        guard pendingForget.remove(key) != nil else { return }
        runs.removeValue(forKey: key)
    }
}
