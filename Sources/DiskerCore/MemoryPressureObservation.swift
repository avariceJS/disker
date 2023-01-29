import Dispatch
import Foundation

public enum MemoryPressureLevel: String, Codable, Equatable, Sendable {
    case normal
    case warning
    case critical

    public static func from(events: DispatchSource.MemoryPressureEvent) -> Self? {
        if events.contains(.critical) { return .critical }
        if events.contains(.warning) { return .warning }
        if events.contains(.normal) { return .normal }
        return nil
    }
}

public struct MemoryPressureObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let observedAt: Date
    public let level: MemoryPressureLevel

    public init(id: UUID = UUID(), observedAt: Date, level: MemoryPressureLevel) {
        self.id = id
        self.observedAt = observedAt
        self.level = level
    }
}
