import SwiftUI

@main
struct DiskerApp: App {
    var body: some Scene {
        WindowGroup {
#if DEBUG
            if let resultURL = DashboardModelMonitoringCheckHost.resultURL(
                from: ProcessInfo.processInfo.arguments
            ) {
                DashboardModelMonitoringCheckHost(resultURL: resultURL)
            } else if ProcessInfo.processInfo.arguments.contains("--application-workflow-qa") {
                if let configuration = ApplicationWorkflowQAConfiguration.from(
                    arguments: ProcessInfo.processInfo.arguments
                ) {
                    DashboardView(
                        initialSection: "Applications",
                        qaApplicationCandidatePath: configuration.candidatePath,
                        storeURLs: configuration.storeURLs
                    )
                        .frame(minWidth: 760, minHeight: 540)
                } else {
                    ContentUnavailableView(
                        "Application workflow QA storage is invalid",
                        systemImage: "externaldrive.badge.xmark",
                        description: Text("Pass an existing isolated ~/Desktop/Disker-WorkflowQA-*/state directory. QA mode refuses to use Disker’s regular history.")
                    )
                    .frame(minWidth: 760, minHeight: 540)
                }
            } else if let request = DiskerSnapshotRequest.from(arguments: ProcessInfo.processInfo.arguments) {
                DiskerSnapshotHost(request: request)
            } else {
                DashboardView()
                    .frame(minWidth: 760, minHeight: 540)
            }
#else
            DashboardView()
                .frame(minWidth: 760, minHeight: 540)
#endif
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Scan") {
                Button("Choose Folders to Scan…") {
                    NotificationCenter.default.post(name: .chooseFoldersToScan, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Choose an Application Bundle…") {
                    NotificationCenter.default.post(name: .chooseApplicationBundleToScan, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

#if DEBUG
private struct ApplicationWorkflowQAConfiguration {
    let storeURLs: DashboardModelStoreURLs
    let candidatePath: String

    static func from(arguments: [String]) -> ApplicationWorkflowQAConfiguration? {
        guard let index = arguments.firstIndex(of: "--application-workflow-qa-store-dir"),
              arguments.indices.contains(index + 1),
              let candidateIndex = arguments.firstIndex(of: "--application-workflow-qa-candidate"),
              arguments.indices.contains(candidateIndex + 1) else { return nil }
        let suppliedPath = arguments[index + 1]
        guard suppliedPath.hasPrefix("/Users/root1/Desktop/Disker-WorkflowQA-"),
              suppliedPath == URL(fileURLWithPath: suppliedPath).standardizedFileURL.path,
              (try? FileManager.default
                .attributesOfItem(atPath: suppliedPath)[.type] as? FileAttributeType) == .typeDirectory else {
            return nil
        }
        let root = URL(fileURLWithPath: suppliedPath, isDirectory: true)
        let qaRootPath = root.deletingLastPathComponent().path
        let qaRoot = root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let candidatePath = URL(fileURLWithPath: arguments[candidateIndex + 1])
            .resolvingSymlinksInPath().standardizedFileURL.path
        let candidateURL = URL(fileURLWithPath: candidatePath, isDirectory: true)
        guard root.lastPathComponent == "state",
              qaRootPath.hasPrefix("/Users/root1/Desktop/Disker-WorkflowQA-"),
              candidatePath.hasPrefix(qaRoot.path + "/"),
              candidateURL.pathExtension.lowercased() == "app",
              (try? FileManager.default
                .attributesOfItem(atPath: candidatePath)[.type] as? FileAttributeType) == .typeDirectory,
              let bundle = Bundle(url: candidateURL),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              bundle.bundleIdentifier?.isEmpty == false else { return nil }
        return ApplicationWorkflowQAConfiguration(storeURLs: DashboardModelStoreURLs(
            observations: root.appendingPathComponent("observations.json"),
            fileInventory: root.appendingPathComponent("file-inventory.plist"),
            selectedScopeBookmarks: root.appendingPathComponent("selected-scopes.json"),
            storageMonitoringPreferences: root.appendingPathComponent("storage-monitoring.json"),
            applicationDiscoveryScopes: root.appendingPathComponent("application-discovery-scopes.json")
        ), candidatePath: candidatePath)
    }
}
#endif

extension Notification.Name {
    static let chooseFoldersToScan = Notification.Name("Disker.chooseFoldersToScan")
    static let chooseApplicationBundleToScan = Notification.Name("Disker.chooseApplicationBundleToScan")
}
