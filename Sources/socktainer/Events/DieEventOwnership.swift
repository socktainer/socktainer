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

    private var epoch: [String: Int] = [:]
    private var runs: [RunKey: Run] = [:]
    private var tombstoned: Set<String> = []

    /// Opens a run for `id` and returns its epoch, or joins the run already open.
    ///
    /// Called where the container starts executing: the attach route's bootstrap and a
    /// `POST /start` that started it. `docker run` does *both* concurrently — it attaches and
    /// starts, and whichever request wins the race starts the container while the other gets a
    /// benign "already booted". Joining an undecided run is what keeps that pair on one run:
    /// two runs for one physical exit would let each side's observer claim its own and emit a
    /// `die` apiece. A run whose exit was already reported is finished, so the next start opens
    /// a fresh one.
    func beginRun(id: String) -> Int {
        tombstoned.remove(id)
        let current = epoch[id] ?? 0
        if let open = runs[RunKey(id: id, epoch: current)], !open.emitterDecided {
            return current
        }
        return openNewRun(id: id)
    }

    /// Opens a run for a container the caller just stopped and started again — `POST /restart`
    /// and restart-policy restarts. Unconditional, because the stop ended the previous run even
    /// if its exit has not been reported yet; joining it would leave the new run unreportable.
    func beginRestartedRun(id: String) -> Int {
        tombstoned.remove(id)
        return openNewRun(id: id)
    }

    /// The run an observer joins when it did not start the container itself — attaching to an
    /// already-running container, or a `/start` that found it running.
    func currentEpoch(id: String) -> Int {
        epoch[id] ?? 0
    }

    private func openNewRun(id: String) -> Int {
        let next = (epoch[id] ?? 0) + 1
        epoch[id] = next
        runs[RunKey(id: id, epoch: next)] = Run()
        // A monitor can still be resolving the previous run's exit code, so its run stays
        // claimable; anything older than that is unreachable and would otherwise accumulate.
        runs.removeValue(forKey: RunKey(id: id, epoch: next - 2))
        return next
    }

    /// Drops a removed container's die-event bookkeeping.
    ///
    /// A run whose exit was already reported is tombstoned: further claims are refused, because
    /// an observer arriving after the record was dropped would otherwise find no run, take it,
    /// and emit a second `die` for that exit. That is the `--rm` path, which cleans up *after*
    /// broadcasting.
    ///
    /// A run still open is left claimable instead. `docker rm -f` stops and deletes a running
    /// container, and its exit monitor resolves the code (behind a flush grace) only after the
    /// delete has landed — refusing that claim would turn `die` into a race with teardown and
    /// drop the event Docker does send. Its epoch entry stays so a container recreated under the
    /// same name cannot be handed the dead run.
    func forget(id: String) {
        let current = epoch[id] ?? 0
        runs.removeValue(forKey: RunKey(id: id, epoch: current - 1))

        let key = RunKey(id: id, epoch: current)
        guard runs[key]?.emitterDecided ?? true else { return }
        runs.removeValue(forKey: key)
        epoch.removeValue(forKey: id)
        tombstoned.insert(id)
    }

    /// Declares that a start-route observer of `generation` will emit this run's `die`.
    /// Supersedes an older generation's reservation, so a redundant `/start` moves the
    /// obligation to the observer that will actually pass its generation check.
    func reserveForStart(id: String, epoch runEpoch: Int, generation: Int) {
        let key = RunKey(id: id, epoch: runEpoch)
        var run = runs[key] ?? Run()
        run.reservedGeneration = generation
        runs[key] = run
    }

    /// Called by a start-route observer once its generation check passed and it is about to
    /// broadcast. False means this run was already reported — by the exit monitor, when the
    /// container exited before this observer armed.
    func claimForStart(id: String, epoch runEpoch: Int, generation: Int) -> Bool {
        guard !tombstoned.contains(id) else { return false }
        let key = RunKey(id: id, epoch: runEpoch)
        var run = runs[key] ?? Run()
        guard !run.emitterDecided, run.reservedGeneration == generation else { return false }
        run.emitterDecided = true
        runs[key] = run
        return true
    }

    /// Called by the attach paths' exit monitor. False means a start-route observer reserved
    /// this run — `docker run` — and will emit the richer event, or the run is already reported.
    func claimForMonitor(id: String, epoch runEpoch: Int) -> Bool {
        guard !tombstoned.contains(id) else { return false }
        let key = RunKey(id: id, epoch: runEpoch)
        var run = runs[key] ?? Run()
        guard !run.emitterDecided, run.reservedGeneration == nil else { return false }
        run.emitterDecided = true
        runs[key] = run
        return true
    }
}
