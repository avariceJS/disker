#if DEBUG
import AppKit
import SwiftUI

struct DiskerSnapshotRequest {
    let outputURL: URL
    let section: String
    let width: CGFloat
    let height: CGFloat
    let appearanceName: NSAppearance.Name?
    let suppressSpotlightDiscovery: Bool

    static func from(arguments: [String]) -> DiskerSnapshotRequest? {
        guard let outputIndex = arguments.firstIndex(of: "--snapshot-output"),
              arguments.indices.contains(outputIndex + 1) else { return nil }
        let sectionIndex = arguments.firstIndex(of: "--snapshot-section")
        let appearanceIndex = arguments.firstIndex(of: "--snapshot-appearance")
        let suppressSpotlightDiscovery = !arguments.contains("--snapshot-enable-spotlight")
        let section = sectionIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            ?? "Overview"
        let appearance = appearanceIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let appearanceName: NSAppearance.Name?
        switch appearance?.lowercased() {
        case "light": appearanceName = .aqua
        case "dark": appearanceName = .darkAqua
        default: appearanceName = nil
        }
        return DiskerSnapshotRequest(
            outputURL: URL(fileURLWithPath: arguments[outputIndex + 1]),
            section: section,
            width: 1_280,
            height: 900,
            appearanceName: appearanceName,
            suppressSpotlightDiscovery: suppressSpotlightDiscovery
        )
    }
}

struct DiskerSnapshotHost: View {
    let request: DiskerSnapshotRequest

    var body: some View {
        DashboardView(
            initialSection: request.section,
            expandSavedApplicationHistory: true,
            suppressSpotlightDiscovery: request.suppressSpotlightDiscovery,
            expandFirstSavedApplicationForSnapshot: true
        )
        .frame(width: request.width, height: request.height)
        .task {
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            captureWhenReady(attempt: 0)
        }
    }

    @MainActor
    private func captureWhenReady(attempt: Int) {
        guard let window = NSApp.windows
            .filter({ $0.contentView != nil })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let contentView = window.contentView else {
            retryOrFail(attempt: attempt, reason: "No native window is available to snapshot.")
            return
        }
        if let appearanceName = request.appearanceName {
            window.appearance = NSAppearance(named: appearanceName)
        }
        window.setContentSize(NSSize(width: request.width, height: request.height))
        contentView.frame = CGRect(origin: .zero, size: window.contentView?.frame.size ?? .zero)
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()
        guard contentView.bounds.width > 0, contentView.bounds.height > 0,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            retryOrFail(attempt: attempt, reason: "The native window has no drawable content bounds.")
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            retryOrFail(attempt: attempt, reason: "AppKit could not encode the native window bitmap.")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: request.outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: request.outputURL, options: .atomic)
            print("Disker snapshot saved: \(request.outputURL.path) (\(bitmap.pixelsWide)×\(bitmap.pixelsHigh))")
            NSApp.terminate(nil)
        } catch {
            retryOrFail(attempt: attempt, reason: "Snapshot write failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func retryOrFail(attempt: Int, reason: String) {
        guard attempt < 10 else {
            fputs("Disker snapshot failed: \(reason)\n", stderr)
            NSApp.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            captureWhenReady(attempt: attempt + 1)
        }
    }
}
#endif
