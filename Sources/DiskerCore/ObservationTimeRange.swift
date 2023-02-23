import Foundation

/// A display filter anchored to the newest sample in an already comparable
/// series. It never changes the rules that decide which observations belong
/// to that series.
public enum ObservationTimeRange: String, CaseIterable, Identifiable, Sendable {
    case day, week, month, all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: "24 hours"
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All saved"
        }
    }

    public func includes(_ date: Date, relativeTo latest: Date) -> Bool {
        guard date <= latest else { return false }
        let duration: TimeInterval
        switch self {
        case .day: duration = 24 * 60 * 60
        case .week: duration = 7 * 24 * 60 * 60
        case .month: duration = 30 * 24 * 60 * 60
        case .all: return true
        }
        return date >= latest.addingTimeInterval(-duration)
    }
}
