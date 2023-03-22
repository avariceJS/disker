import Foundation

private final class EventSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var eventCount = 0

    func record() {
        lock.lock()
        eventCount += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return eventCount
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
        while Date.now < deadline && signal.count == 0 {
            RunLoop.current.run(until: min(deadline, Date.now.addingTimeInterval(0.05)))
        }
        guard signal.count > 0 else {
            throw NSError(domain: "Disker.SelectedRootEventWatcherChecks", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "FSEvents did not notify Disker about a synthetic selected-root change within eight seconds."
            ])
        }
        // Drain any callbacks for the first write before establishing the
        // post-stop count. A stopped stream must not deliver later changes.
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.25))
        let countAfterFirstChange = signal.count
        watcher.stop()
        try Data([0x73, 0x74, 0x6f, 0x70]).write(
            to: fixtureRoot.appendingPathComponent("after-stop.bin")
        )
        let stopDeadline = Date.now.addingTimeInterval(1.5)
        while Date.now < stopDeadline {
            RunLoop.current.run(until: min(stopDeadline, Date.now.addingTimeInterval(0.05)))
        }
        guard signal.count == countAfterFirstChange else {
            throw NSError(domain: "Disker.SelectedRootEventWatcherChecks", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "A stopped FSEvents watcher delivered a later synthetic filesystem change."
            ])
        }
        print("PASS  selected-root FSEvents delivers changes and stops cleanly")
    }
}
