import CoreServices
import Foundation
import Vapor

struct FolderWatcherKey: StorageKey {
    typealias Value = FolderWatcher
}

// Static C callback function - no Swift object access in callback
private let fsEventsCallback: FSEventStreamCallback = { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
    guard let clientCallBackInfo = clientCallBackInfo else { return }

    // Get the callback handler from our info struct
    let callbackInfo = clientCallBackInfo.assumingMemoryBound(to: FSEventsCallbackInfo.self).pointee

    // Quick validity check
    guard callbackInfo.isValid else { return }

    // Convert paths safely
    let pathsArray = UnsafeBufferPointer(start: eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self), count: numEvents)
    let paths = pathsArray.compactMap { String(cString: $0) }

    // Call the handler
    callbackInfo.eventHandler(paths)
}

// C-compatible callback info struct
private struct FSEventsCallbackInfo {
    var isValid: Bool
    var eventHandler: ([String]) -> Void
}

final class FolderWatcher: @unchecked Sendable {
    private let rootURL: URL
    private let broadcaster: EventBroadcaster
    private var eventStream: FSEventStreamRef?
    private var callbackInfo: UnsafeMutablePointer<FSEventsCallbackInfo>?

    // Thread-safe state
    private let lock = NSLock()
    private var _isActive = false
    private var isActive: Bool {
        get { lock.withLock { _isActive } }
        set { lock.withLock { _isActive = newValue } }
    }

    // Debounce using DispatchSourceTimer for better control
    private var containerDebounceSource: DispatchSourceTimer?
    private var imageDebounceSource: DispatchSourceTimer?
    private let debounceQueue = DispatchQueue(label: "com.socktainer.debounce", qos: .utility)

    init(parentFolderURL: URL, broadcaster: EventBroadcaster) {
        self.rootURL = parentFolderURL
        self.broadcaster = broadcaster
    }

    func startWatching() {
        guard !isActive else { return }

        // Allocate callback info structure
        callbackInfo = UnsafeMutablePointer<FSEventsCallbackInfo>.allocate(capacity: 1)
        callbackInfo!.initialize(
            to: FSEventsCallbackInfo(
                isValid: true,
                eventHandler: { [weak self] paths in
                    self?.handleEvents(paths)
                }
            ))

        let pathsToWatch = [rootURL.path] as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(callbackInfo!),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        eventStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        )

        guard let stream = eventStream else {
            cleanupCallbackInfo()
            print("[FolderWatcher] Failed to create FSEventStream")
            return
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))

        if FSEventStreamStart(stream) {
            isActive = true
            print("[FolderWatcher] Started watching \(rootURL.path)")
        } else {
            FSEventStreamRelease(stream)
            eventStream = nil
            cleanupCallbackInfo()
            print("[FolderWatcher] Failed to start FSEventStream")
        }
    }

    func stopWatching() {
        guard isActive else { return }

        isActive = false

        // Mark callback info as invalid first
        if let info = callbackInfo {
            info.pointee.isValid = false
        }

        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            eventStream = nil
        }

        cancelDebounceTimers()
        cleanupCallbackInfo()

        print("[FolderWatcher] Stopped watching")
    }

    private func cleanupCallbackInfo() {
        if let info = callbackInfo {
            info.deinitialize(count: 1)
            info.deallocate()
            callbackInfo = nil
        }
    }

    private func cancelDebounceTimers() {
        containerDebounceSource?.cancel()
        imageDebounceSource?.cancel()
        containerDebounceSource = nil
        imageDebounceSource = nil
    }

    private func handleEvents(_ paths: [String]) {
        guard isActive else { return }

        for path in paths {
            if path.contains("/.") { continue }  // Skip hidden files

            if path.hasSuffix("state.json") {
                debounceImageEvent()
            } else if path.contains("/containers/") {
                debounceContainerEvent()
            }
        }
    }

    private func debounceContainerEvent() {
        containerDebounceSource?.cancel()

        containerDebounceSource = DispatchSource.makeTimerSource(queue: debounceQueue)
        containerDebounceSource?.schedule(deadline: .now() + 2.0)
        containerDebounceSource?.setEventHandler { [weak self] in
            guard let self = self, self.isActive else { return }

            let event = DockerEvent.simpleEvent(id: UUID().uuidString, type: "container", status: "remove")
            Task {
                await self.broadcaster.broadcast(event)
                // print("[FolderWatcher] Broadcasted container event")
            }
        }
        containerDebounceSource?.resume()
    }

    private func debounceImageEvent() {
        imageDebounceSource?.cancel()

        imageDebounceSource = DispatchSource.makeTimerSource(queue: debounceQueue)
        imageDebounceSource?.schedule(deadline: .now() + 2.0)
        imageDebounceSource?.setEventHandler { [weak self] in
            guard let self = self, self.isActive else { return }

            let event = DockerEvent.simpleEvent(id: UUID().uuidString, type: "image", status: "remove")
            Task {
                await self.broadcaster.broadcast(event)
                // print("[FolderWatcher] Broadcasted image event")
            }
        }
        imageDebounceSource?.resume()
    }

    deinit {
        // Mark as invalid immediately
        if let info = callbackInfo {
            info.pointee.isValid = false
        }

        if let stream = eventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }

        cancelDebounceTimers()
        cleanupCallbackInfo()
    }
}
