import AppKit
import DiskerCore
import Foundation
import Observation

@MainActor
@Observable
final class ApplicationDiscoveryModel {
    private(set) var candidates: [ApplicationDiscoveryCandidate] = []
    private(set) var history: [ApplicationDiscoveryRecord] = []
    private(set) var isGathering = false
    private(set) var isRunning = false
    private(set) var statusMessage: String?
    private(set) var scopePaths: [String] = []

    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var selectedScopeURLs: [URL] = []
    @ObservationIgnored private var securityScopedPaths = Set<String>()

    init() {
        history = (try? ObservationStore.load().discoveredApplications) ?? []
    }

    func start() {
        guard query == nil else { return }
        let defaults = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter(Self.isRealDirectory)
        selectedScopeURLs = defaults
        runQuery()
    }

    func addUserSelectedScope() {
        let panel = NSOpenPanel()
        panel.title = "Add an application discovery folder"
        panel.prompt = "Search This Folder"
        panel.message = "Spotlight will look for application bundles inside this folder. Disker will not scan or measure its contents."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK,
              let url = panel.url?.standardizedFileURL,
              Self.isRealDirectory(url),
              !selectedScopeURLs.contains(where: { $0.path == url.path })
        else { return }

        let didStartAccess = url.startAccessingSecurityScopedResource()
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        guard didStartAccess || !isSandboxed else {
            statusMessage = "macOS did not grant access to that discovery folder. No scan was started."
            return
        }
        if didStartAccess { securityScopedPaths.insert(url.path) }
        selectedScopeURLs.append(url)
        if query != nil { stopQuery(releaseScopes: false) }
        runQuery()
    }

    func stop() {
        stopQuery(releaseScopes: true)
    }

    func resetHistory() { history = [] }

    private func stopQuery(releaseScopes: Bool) {
        query?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        self.query = nil
        isRunning = false
        isGathering = false
        candidates = []
        if releaseScopes {
            for url in selectedScopeURLs where securityScopedPaths.remove(url.path) != nil {
                url.stopAccessingSecurityScopedResource()
            }
            selectedScopeURLs.removeAll()
            scopePaths.removeAll()
        }
    }

    private func runQuery() {
        let activeScopes = selectedScopeURLs.filter(Self.isRealDirectory)
        guard !activeScopes.isEmpty else {
            statusMessage = "No accessible application folders are available for Spotlight discovery."
            return
        }

        let query = NSMetadataQuery()
        query.searchScopes = activeScopes
        query.predicate = NSPredicate(format: "kMDItemContentType == %@", "com.apple.application-bundle")
        query.notificationBatchingInterval = 1
        self.query = query
        scopePaths = activeScopes.map(\.path)
        statusMessage = "Waiting for Spotlight's indexed results. Index coverage may be incomplete."
        isGathering = true
        isRunning = true

        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let query = notification.object as? NSMetadataQuery else { return }
                    self.receive(query, finished: notification.name == .NSMetadataQueryDidFinishGathering)
                }
            })
        }
        if !query.start() {
            statusMessage = "Spotlight could not start this scoped query. Try again later."
            stop()
        }
    }

    private func receive(_ query: NSMetadataQuery, finished: Bool) {
        guard self.query === query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        if finished { isGathering = false }

        var raw: [ApplicationDiscoveryCandidate] = []
        let count = min(query.resultCount, 5_000)
        for index in 0..<count {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard Self.isRealDirectory(url) else { continue }
            let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
                ?? url.deletingPathExtension().lastPathComponent
            raw.append(ApplicationDiscoveryCandidate(path: url.path, displayName: name))
        }
        let scoped = ApplicationBundleIndex.scopedCandidates(raw, within: scopePaths)
        candidates = scoped
        let updatedHistory = ApplicationBundleIndex.updatingDiscoveryHistory(history, with: scoped)
        if updatedHistory != history {
            do {
                history = try ObservationStore.updateDiscoveredApplications(updatedHistory).discoveredApplications
            } catch {
                history = updatedHistory
                statusMessage = "Spotlight results are available, but their local discovery dates could not be saved."
            }
        }
        statusMessage = query.resultCount > 5_000
            ? "Showing a bounded sample of Spotlight results. Search scope or index coverage may omit applications."
            : "Discovery uses Spotlight's current index; excluded or unindexed locations remain unknown."
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        ApplicationBundleIndex.isDirectoryWithoutFollowingSymlinks(at: url)
    }
}
