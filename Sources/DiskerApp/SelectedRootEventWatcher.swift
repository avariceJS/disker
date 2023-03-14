import CoreServices
import Foundation

/// Converts filesystem change notifications into a prompt for a later full,
/// metadata-only scan. Events never provide byte totals or alter the baseline.
final class SelectedRootEventWatcher {
    private var stream: FSEventStreamRef?
    private let queue: DispatchQueue
    private let rootURL: URL
    private let ownsSecurityScope: Bool
    private let onChange: @Sendable () -> Void
    private var isStarted = false

    init(rootURL: URL, ownsSecurityScope: Bool, onChange: @escaping @Sendable () -> Void) throws {
        self.rootURL = rootURL
        self.ownsSecurityScope = ownsSecurityScope
        self.onChange = onChange
        self.queue = DispatchQueue(label: "com.avaricejs.Disker.selected-root-events", qos: .utility)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let paths = [rootURL.path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.receiveEvents,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) else {
            if ownsSecurityScope { rootURL.stopAccessingSecurityScopedResource() }
            throw Self.streamError("Disker could not create a filesystem change stream for this selected folder.")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            if ownsSecurityScope { rootURL.stopAccessingSecurityScopedResource() }
            throw Self.streamError("macOS could not start filesystem change monitoring for this folder.")
        }
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        if ownsSecurityScope { rootURL.stopAccessingSecurityScopedResource() }
    }

    deinit {
        stop()
    }

    private static let receiveEvents: FSEventStreamCallback = {
        _, clientInfo, eventCount, _, _, _ in
        guard eventCount > 0, let clientInfo else { return }
        let watcher = Unmanaged<SelectedRootEventWatcher>.fromOpaque(clientInfo).takeUnretainedValue()

        // Even dropped or coalesced event streams only request a full scan;
        // they are never treated as an exact change log.
        DispatchQueue.main.async { watcher.onChange() }
    }

    private static func streamError(_ message: String) -> NSError {
        NSError(domain: "Disker.SelectedRootEventWatcher", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
