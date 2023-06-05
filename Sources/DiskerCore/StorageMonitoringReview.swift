import Foundation

/// Describes how current a path's retained complete observation is relative to
/// its explicitly opted-in reconciliation cadence. This is not an event log.
public enum StorageMonitoringObservationStatus: Equatable, Sendable {
    case noCompleteBaseline(latestAttemptAt: Date?)
    case baselineOnly(lastCompleteAt: Date)
    case current(lastCompleteAt: Date)
    case reconciliationDue(lastCompleteAt: Date)
    case reconciledGap(previousCompleteAt: Date, latestCompleteAt: Date)
    case latestAttemptIncomplete(lastCompleteAt: Date?, latestAttemptAt: Date)
    case volumeChanged(previousCompleteAt: Date, latestCompleteAt: Date)
    case volumeIdentityUnknown(previousCompleteAt: Date, latestCompleteAt: Date)
}

/// Builds bounded per-path status from retained observations without reading
/// the filesystem or combining paths.
public enum StorageMonitoringObservationReview {
    private struct Sample {
        let folder: FolderObservation
        let scanCancelled: Bool
        let historyIndex: Int

        var isCompleteBaseline: Bool {
            !scanCancelled && folder.complete && !folder.byteAccountingOverflowed
        }
    }

    public static func make(
        for selectedPaths: [String],
        in history: LocalHistory,
        interval: TimeInterval = StorageMonitoringPolicy.defaultInterval,
        at now: Date = .now
    ) -> [String: StorageMonitoringObservationStatus] {
        let paths = Set(selectedPaths.compactMap(standardizedPath))
        guard !paths.isEmpty else { return [:] }

        var samplesByPath: [String: [Sample]] = [:]
        for (historyIndex, scan) in history.observations.enumerated() {
            for folder in scan.folders {
                guard let path = standardizedPath(folder.path), paths.contains(path) else { continue }
                samplesByPath[path, default: []].append(Sample(
                    folder: folder,
                    scanCancelled: scan.cancelled,
                    historyIndex: historyIndex
                ))
            }
        }

        let effectiveInterval = max(
            StorageMonitoringPolicy.minimumInterval,
            interval.isFinite ? interval : StorageMonitoringPolicy.defaultInterval
        )
        var result: [String: StorageMonitoringObservationStatus] = [:]
        for path in paths {
            let samples = samplesByPath[path] ?? []
            let latest = samples.max(by: isEarlier)
            let completeSamples = samples.filter(\.isCompleteBaseline).sorted(by: isEarlier)
            guard let latest else {
                result[path] = .noCompleteBaseline(latestAttemptAt: nil)
                continue
            }
            let previousComplete = completeSamples.last

            guard latest.isCompleteBaseline else {
                result[path] = .latestAttemptIncomplete(
                    lastCompleteAt: previousComplete?.folder.finishedAt,
                    latestAttemptAt: latest.folder.finishedAt
                )
                continue
            }

            guard let latestComplete = previousComplete else {
                result[path] = .noCompleteBaseline(latestAttemptAt: latest.folder.finishedAt)
                continue
            }

            let priorComplete = completeSamples.dropLast().last
            if let priorComplete {
                guard let priorVolume = priorComplete.folder.volumeDeviceID,
                      let currentVolume = latestComplete.folder.volumeDeviceID else {
                    result[path] = .volumeIdentityUnknown(
                        previousCompleteAt: priorComplete.folder.finishedAt,
                        latestCompleteAt: latestComplete.folder.finishedAt
                    )
                    continue
                }
                if priorVolume != currentVolume {
                    result[path] = .volumeChanged(
                        previousCompleteAt: priorComplete.folder.finishedAt,
                        latestCompleteAt: latestComplete.folder.finishedAt
                    )
                    continue
                }
            }

            let age = now.timeIntervalSince(latestComplete.folder.finishedAt)
            if age < 0 {
                if let _ = priorComplete {
                    result[path] = .current(lastCompleteAt: latestComplete.folder.finishedAt)
                } else {
                    result[path] = .baselineOnly(lastCompleteAt: latestComplete.folder.finishedAt)
                }
            } else if age >= effectiveInterval {
                result[path] = .reconciliationDue(lastCompleteAt: latestComplete.folder.finishedAt)
            } else if let priorComplete {
                if latestComplete.folder.finishedAt.timeIntervalSince(priorComplete.folder.finishedAt) >= effectiveInterval {
                    result[path] = .reconciledGap(
                        previousCompleteAt: priorComplete.folder.finishedAt,
                        latestCompleteAt: latestComplete.folder.finishedAt
                    )
                } else {
                    result[path] = .current(lastCompleteAt: latestComplete.folder.finishedAt)
                }
            } else {
                result[path] = .baselineOnly(lastCompleteAt: latestComplete.folder.finishedAt)
            }
        }
        return result
    }

    private static func isEarlier(_ lhs: Sample, _ rhs: Sample) -> Bool {
        if lhs.historyIndex != rhs.historyIndex { return lhs.historyIndex < rhs.historyIndex }
        if lhs.folder.finishedAt != rhs.folder.finishedAt {
            return lhs.folder.finishedAt < rhs.folder.finishedAt
        }
        return lhs.folder.id.uuidString < rhs.folder.id.uuidString
    }

    private static func standardizedPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
