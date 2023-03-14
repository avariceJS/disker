import Foundation

private final class EventSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var received = false

    func record() {
        lock.lock()
        received = true
        lock.unlock()
    }

    var didReceiveEvent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

@main
private enum SelectedRootEventWatcherChecks {
    static func main() throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("EventFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let signal = EventSignal()
        let watcher = try SelectedRootEventWatcher(rootURL: fixtureRoot, ownsSecurityScope: false) {
            signal.record()
        }
        defer { watcher.stop() }
        try Data([0x44, 0x69, 0x73, 0x6B, 0x65, 0x72]).write(
            to: fixtureRoot.appendingPathComponent("synthetic-growth.bin")
        )

        let deadline = Date.now.addingTimeInterval(8)
        while Date.now < deadline && !signal.didReceiveEvent {
            RunLoop.current.run(until: min(deadline, Date.now.addingTimeInterval(0.05)))
        }
        guard signal.didReceiveEvent else {
            throw NSError(domain: "Disker.SelectedRootEventWatcherChecks", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "FSEvents did not notify Disker about a synthetic selected-root change within eight seconds."
            ])
        }
        watcher.stop()
        print("PASS  selected-root FSEvents delivers a synthetic file change")
    }
}
