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
            }
        }
    }
}

extension Notification.Name {
    static let chooseFoldersToScan = Notification.Name("Disker.chooseFoldersToScan")
}
