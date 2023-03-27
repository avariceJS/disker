import AppKit
import DiskerCore
import Foundation
import Observation

@MainActor
@Observable
final class ApplicationDiscoveryModel {
    private(set) var candidates: [ApplicationDiscoveryCandidate] = []
    private(set) var searchableCandidates: [ApplicationDiscoveryCandidate] = []
    private(set) var history: [ApplicationDiscoveryRecord] = []
    private(set) var isGathering = false
    private(set) var isRunning = false
    private(set) var statusMessage: String?
    private(set) var scopePaths: [String] = []
    private(set) var userSelectedScopePaths: [String] = []

    static let maximumUserSelectedScopeCount = SelectedScopeBookmarkStore.maximumBookmarkCount

    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var selectedScopeURLs: [URL] = []
    @ObservationIgnored private var securityScopedPaths = Set<String>()
    @ObservationIgnored private var savedScopeRestoreFailed = false

    init() {
        history = (try? ObservationStore.load().discoveredApplications) ?? []
    }

    func start() {
        guard query == nil else { return }
        savedScopeRestoreFailed = false
        let defaults = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter(Self.isRealDirectory)
        selectedScopeURLs = defaults
        restoreUserSelectedScopes()
        runQuery()
    }

    func addUserSelectedScope() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("Add an application discovery folder", comment: "Application discovery folder picker title")
        panel.prompt = NSLocalizedString("Search This Folder", comment: "Application discovery folder picker action")
        panel.message = NSLocalizedString(
            "Spotlight will look for application bundles inside this folder. Disker will not scan or measure its contents.",
            comment: "Application discovery folder picker explanation"
        )
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard userSelectedScopePaths.count < Self.maximumUserSelectedScopeCount else {
            statusMessage = NSLocalizedString(
                "Disker can remember up to 20 application discovery folders. Remove one before adding another.",
                comment: "Application discovery folder limit"
            )
            return
        }
        guard panel.runModal() == .OK,
              let url = panel.url?.standardizedFileURL,
              Self.isRealDirectory(url),
              !selectedScopeURLs.contains(where: { $0.path == url.path })
        else { return }

        let didStartAccess = url.startAccessingSecurityScopedResource()
        let isSandboxed: Bool
        do {
            isSandboxed = try SelectedScopeBookmarkStore.requiresSecurityScopedAccess()
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            statusMessage = error.localizedDescription
            return
        }
        guard didStartAccess || !isSandboxed else {
            statusMessage = NSLocalizedString(
                "macOS did not grant access to that discovery folder. No scan was started.",
                comment: "Discovery folder permission status"
            )
            return
        }
        guard let bookmarkURL = Self.bookmarkStoreURL() else {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            statusMessage = NSLocalizedString(
                "Disker could not prepare local storage for this discovery folder. No Spotlight query was started.",
                comment: "Application discovery folder bookmark storage unavailable"
            )
            return
        }
        do {
            _ = try SelectedScopeBookmarkStore.remember([url], at: bookmarkURL)
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            statusMessage = error.localizedDescription
            return
        }
        if didStartAccess { securityScopedPaths.insert(url.path) }
        selectedScopeURLs.append(url)
        userSelectedScopePaths.append(url.path)
        userSelectedScopePaths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        if query != nil { stopQuery(releaseScopes: false) }
        runQuery()
    }

    func removeUserSelectedScope(path: String) {
        guard userSelectedScopePaths.contains(path), let bookmarkURL = Self.bookmarkStoreURL() else { return }
        do {
            let bookmarks = try SelectedScopeBookmarkStore.remove(path: path, at: bookmarkURL)
            userSelectedScopePaths = bookmarks.map(\.path)
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        let wasRunning = query != nil
        if wasRunning { stopQuery(releaseScopes: false) }
        if let index = selectedScopeURLs.firstIndex(where: { $0.path == path }) {
            let url = selectedScopeURLs.remove(at: index)
            if securityScopedPaths.remove(path) != nil {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if wasRunning { runQuery() }
    }

    func stop() {
        stopQuery(releaseScopes: true)
    }

    func resetHistory() {
        let wasRunning = query != nil
        if wasRunning { stopQuery(releaseScopes: true) }
        history = []
        userSelectedScopePaths = []
        savedScopeRestoreFailed = false
        if let bookmarkURL = Self.bookmarkStoreURL() {
            do {
                try SelectedScopeBookmarkStore.clear(at: bookmarkURL)
            } catch {
                statusMessage = error.localizedDescription
            }
        }
        if wasRunning { start() }
    }

    private func restoreUserSelectedScopes() {
        guard let bookmarkURL = Self.bookmarkStoreURL() else {
            savedScopeRestoreFailed = true
            return
        }
        let bookmarks: [SelectedScopeBookmark]
        do {
            bookmarks = try SelectedScopeBookmarkStore.load(from: bookmarkURL)
        } catch {
            savedScopeRestoreFailed = true
            return
        }
        userSelectedScopePaths = bookmarks.map(\.path)

        let requiresScopedAccess: Bool
        do {
            requiresScopedAccess = try SelectedScopeBookmarkStore.requiresSecurityScopedAccess()
        } catch {
            savedScopeRestoreFailed = !bookmarks.isEmpty
            return
        }

        for bookmark in bookmarks {
            do {
                let url = try SelectedScopeBookmarkStore.resolve(bookmark, at: bookmarkURL)
                guard Self.isRealDirectory(url) else {
                    savedScopeRestoreFailed = true
                    continue
                }
                if requiresScopedAccess {
                    guard url.startAccessingSecurityScopedResource() else {
                        savedScopeRestoreFailed = true
                        continue
                    }
                    securityScopedPaths.insert(url.path)
                }
                if !selectedScopeURLs.contains(where: { $0.path == url.path }) {
                    selectedScopeURLs.append(url)
                }
            } catch {
                savedScopeRestoreFailed = true
            }
        }
    }

    private func stopQuery(releaseScopes: Bool) {
        query?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        self.query = nil
        isRunning = false
        isGathering = false
        candidates = []
        searchableCandidates = []
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
            statusMessage = NSLocalizedString(
                "No accessible application folders are available for Spotlight discovery.",
                comment: "No application discovery scopes are available"
            )
            return
        }

        let query = NSMetadataQuery()
        query.searchScopes = activeScopes
        query.predicate = NSPredicate(format: "kMDItemContentType == %@", "com.apple.application-bundle")
        query.notificationBatchingInterval = 1
        self.query = query
        scopePaths = activeScopes.map(\.path)
        statusMessage = NSLocalizedString(
            "Waiting for Spotlight's indexed results. Index coverage may be incomplete.",
            comment: "Application discovery is waiting for indexed results"
        )
        if savedScopeRestoreFailed {
            statusMessage = appendScopeRestoreWarning(to: statusMessage ?? "")
        }
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
            statusMessage = NSLocalizedString(
                "Spotlight could not start this scoped query. Try again later.",
                comment: "Application discovery query could not start"
            )
            stop()
        }
    }

    private func receive(_ query: NSMetadataQuery, finished: Bool) {
        guard self.query === query else { return }
        query.disableUpdates()
        defer { query.enableUpdates() }
        if finished { isGathering = false }

        var raw: [ApplicationDiscoveryCandidate] = []
        let maximumIndexedResults = ApplicationBundleIndex.maximumSearchableDiscoveryResults
        let maximumDisplayedResults = ApplicationBundleIndex.maximumDiscoveryRecords
        let count = min(query.resultCount, maximumIndexedResults)
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
        let scoped = ApplicationBundleIndex.scopedCandidateSample(
            raw, within: scopePaths, limit: maximumDisplayedResults
        )
        let searchable = ApplicationBundleIndex.scopedCandidates(
            raw, within: scopePaths, limit: maximumIndexedResults
        )
        searchableCandidates = searchable
        let sampleIsTruncated = query.resultCount > maximumIndexedResults || scoped.hasMore
        let displayed = scoped.candidates
        candidates = displayed
        let updatedHistory = ApplicationBundleIndex.updatingDiscoveryHistory(history, with: searchable)
        if updatedHistory != history {
            do {
                history = try ObservationStore.updateDiscoveredApplications(updatedHistory).discoveredApplications
            } catch {
                history = updatedHistory
                statusMessage = NSLocalizedString(
                    "Spotlight results are available, but their local discovery dates could not be saved.",
                    comment: "Application discovery history could not be saved"
                )
            }
        }
        let discoveryStatus = sampleIsTruncated
            ? NSLocalizedString(
                "The catalog shows up to 500 applications and searches up to 5,000 indexed results. Excluded or unindexed locations remain unknown.",
                comment: "Application discovery results are capped"
            )
            : NSLocalizedString(
                "Discovery uses Spotlight's current index; excluded or unindexed locations remain unknown.",
                comment: "Application discovery index coverage caveat"
            )
        statusMessage = savedScopeRestoreFailed
            ? appendScopeRestoreWarning(to: discoveryStatus)
            : discoveryStatus
    }

    private func appendScopeRestoreWarning(to message: String) -> String {
        let warning = NSLocalizedString(
            "One or more saved discovery folders could not be reopened. Reselect an accessible folder or remove the saved entry.",
            comment: "Saved application discovery folders could not be restored"
        )
        return message.isEmpty ? warning : "\(message) \(warning)"
    }

    private static func bookmarkStoreURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Disker", isDirectory: true)
            .appendingPathComponent("application-discovery-scopes.json")
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        ApplicationBundleIndex.isDirectoryWithoutFollowingSymlinks(at: url)
    }
}
