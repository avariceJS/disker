import Foundation

/// Distinguishes explicit user scans from scans started by opted-in monitoring.
public enum StorageScanOrigin: Equatable, Sendable {
    case manual
    case scheduled
    case eventTriggered

    public var isMonitoring: Bool {
        self != .manual
    }
}

/// Pure scheduling decisions for opt-in scans of explicitly saved folder roots.
/// This type never resolves bookmarks, accesses paths, or starts/cancels work.
public enum StorageMonitoringPolicy {
    public static let defaultInterval: TimeInterval = 15 * 60
    public static let minimumInterval: TimeInterval = 5 * 60
    public static let eventDebounceInterval: TimeInterval = 3
    public static let minimumEventScanInterval: TimeInterval = minimumInterval

    /// Selects one stable, opted-in root for an event-triggered reconciliation.
    /// The throttle is shared with scheduled and manual full scans of that root.
    /// This does not treat events as a change log or authorize a filesystem scan.
    public static func nextEventTriggeredRoot(
        monitoringSessionOpen: Bool,
        scanInProgress: Bool,
        pendingRootIdentifiers: Set<String>,
        savedRootIdentifiers: Set<String>,
        selectedRootIdentifiers: Set<String>,
        pausedRootIdentifiers: Set<String>,
        lastScanAtByRoot: [String: Date],
        at now: Date
    ) -> String? {
        guard monitoringSessionOpen, !scanInProgress else { return nil }
        let eligible = pendingRootIdentifiers
            .intersection(savedRootIdentifiers)
            .intersection(selectedRootIdentifiers)
            .subtracting(pausedRootIdentifiers)
        return eligible.sorted().first { rootIdentifier in
            guard let lastScan = lastScanAtByRoot[rootIdentifier] else { return true }
            return now.timeIntervalSince(lastScan) >= minimumEventScanInterval
        }
    }

    /// Returns the remaining throttle wait for pending, otherwise eligible roots.
    /// A nil result means the caller should wait for another state change or retry later.
    public static func nextEventThrottleDelay(
        monitoringSessionOpen: Bool,
        scanInProgress: Bool,
        pendingRootIdentifiers: Set<String>,
        savedRootIdentifiers: Set<String>,
        selectedRootIdentifiers: Set<String>,
        pausedRootIdentifiers: Set<String>,
        lastScanAtByRoot: [String: Date],
        at now: Date
    ) -> TimeInterval? {
        guard monitoringSessionOpen, !scanInProgress else { return nil }
        let eligible = pendingRootIdentifiers
            .intersection(savedRootIdentifiers)
            .intersection(selectedRootIdentifiers)
            .subtracting(pausedRootIdentifiers)
        return eligible.compactMap { rootIdentifier in
            guard let lastScan = lastScanAtByRoot[rootIdentifier] else { return 0 }
            return max(0, lastScan.addingTimeInterval(minimumEventScanInterval).timeIntervalSince(now))
        }.min()
    }

    /// A scheduled root that yielded no measurable files and incomplete coverage
    /// cannot produce a useful comparison. Pause it until the user reviews access.
    public static func shouldPauseAfterScheduledScan(_ folder: FolderObservation) -> Bool {
        !folder.complete && folder.fileCount == 0
    }

    public struct Input: Sendable {
        public var enabled: Bool
        public var interval: TimeInterval
        /// Timestamp at which this opt-in monitoring session was enabled.
        /// A root without prior scheduled history waits one full interval from it.
        public var enabledAt: Date
        /// True while the user-selected Disker monitoring window remains open.
        /// Storage monitoring does not depend on which app currently has focus.
        public var monitoringSessionOpen: Bool
        public var globalScanInProgress: Bool
        public var savedRootIdentifiers: Set<String>
        public var selectedRootIdentifiers: Set<String>
        public var pausedRootIdentifiers: Set<String>
        /// Roots undergoing history reset. They remain paused until the reset finishes.
        public var resettingRootIdentifiers: Set<String>
        public var manualScanRootIdentifiers: Set<String>
        public var scheduledScanRootIdentifiers: Set<String>
        public var lastScheduledStartByRoot: [String: Date]

        public init(
            enabled: Bool = false,
            interval: TimeInterval = StorageMonitoringPolicy.defaultInterval,
            enabledAt: Date = .distantFuture,
            monitoringSessionOpen: Bool = false,
            globalScanInProgress: Bool = false,
            savedRootIdentifiers: Set<String> = [],
            selectedRootIdentifiers: Set<String> = [],
            pausedRootIdentifiers: Set<String> = [],
            resettingRootIdentifiers: Set<String> = [],
            manualScanRootIdentifiers: Set<String> = [],
            scheduledScanRootIdentifiers: Set<String> = [],
            lastScheduledStartByRoot: [String: Date] = [:]
        ) {
            self.enabled = enabled
            self.interval = interval
            self.enabledAt = enabledAt
            self.monitoringSessionOpen = monitoringSessionOpen
            self.globalScanInProgress = globalScanInProgress
            self.savedRootIdentifiers = savedRootIdentifiers
            self.selectedRootIdentifiers = selectedRootIdentifiers
            self.pausedRootIdentifiers = pausedRootIdentifiers
            self.resettingRootIdentifiers = resettingRootIdentifiers
            self.manualScanRootIdentifiers = manualScanRootIdentifiers
            self.scheduledScanRootIdentifiers = scheduledScanRootIdentifiers
            self.lastScheduledStartByRoot = lastScheduledStartByRoot
        }
    }

    public struct Decision: Equatable, Sendable {
        /// Selected bookmark identifiers that are currently eligible for scheduling.
        public let eligibleRootIdentifiers: Set<String>
        /// Existing scheduled scans the caller should cancel before continuing.
        public let cancelScheduledRootIdentifiers: Set<String>
        /// At most one root per evaluation, chosen by stable lexical ordering.
        public let nextScheduledRootIdentifier: String?
        public let effectiveInterval: TimeInterval
    }

    public static func evaluate(_ input: Input, at now: Date) -> Decision {
        let interval = max(minimumInterval, input.interval.isFinite ? input.interval : defaultInterval)
        let eligible: Set<String>
        if input.enabled && input.monitoringSessionOpen {
            eligible = input.selectedRootIdentifiers
                .intersection(input.savedRootIdentifiers)
                .subtracting(input.pausedRootIdentifiers)
                .subtracting(input.resettingRootIdentifiers)
        } else {
            eligible = []
        }

        var cancel = input.scheduledScanRootIdentifiers.subtracting(eligible)
        // A user-started scan takes precedence over a scheduled scan of that same root.
        cancel.formUnion(input.scheduledScanRootIdentifiers.intersection(input.manualScanRootIdentifiers))

        guard input.enabled, input.monitoringSessionOpen,
              !input.globalScanInProgress,
              input.manualScanRootIdentifiers.isEmpty,
              input.scheduledScanRootIdentifiers.subtracting(cancel).isEmpty else {
            return Decision(
                eligibleRootIdentifiers: eligible,
                cancelScheduledRootIdentifiers: cancel,
                nextScheduledRootIdentifier: nil,
                effectiveInterval: interval
            )
        }

        let next = eligible.sorted().first { rootIdentifier in
            let anchor = input.lastScheduledStartByRoot[rootIdentifier] ?? input.enabledAt
            // A wall-clock rollback must delay the next scan, never make it due early.
            guard now >= anchor else { return false }
            return now.timeIntervalSince(anchor) >= interval
        }
        return Decision(
            eligibleRootIdentifiers: eligible,
            cancelScheduledRootIdentifiers: cancel,
            nextScheduledRootIdentifier: next,
            effectiveInterval: interval
        )
    }
}
