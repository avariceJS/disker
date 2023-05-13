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

extension Notification.Name {
    static let chooseFoldersToScan = Notification.Name("Disker.chooseFoldersToScan")
    static let chooseApplicationBundleToScan = Notification.Name("Disker.chooseApplicationBundleToScan")
}
