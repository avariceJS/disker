import SwiftUI

@main
struct DiskerApp: App {
    var body: some Scene {
        WindowGroup {
            DashboardView()
                .frame(minWidth: 760, minHeight: 540)
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
