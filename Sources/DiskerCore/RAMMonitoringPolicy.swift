import Foundation

public enum RAMMonitoringPolicy {
    public static let interval: TimeInterval = 5 * 60

    public static func shouldSample(
        enabled: Bool, appIsActive: Bool, sampleInProgress: Bool
    ) -> Bool {
        enabled && appIsActive && !sampleInProgress
    }

    public static func shouldObservePressure(enabled: Bool, appIsActive: Bool) -> Bool {
        enabled && appIsActive
    }
}
