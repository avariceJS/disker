import Foundation

/// Checked arithmetic for byte totals derived from filesystem metadata.
/// Overflow is saturated so a scan can report a bounded partial estimate
/// instead of wrapping to a misleading small value or trapping.
public enum CheckedByteCount {
    public static func adding(_ lhs: Int64, _ rhs: Int64) -> (value: Int64, overflowed: Bool) {
        let (value, overflowed) = lhs.addingReportingOverflow(rhs)
        return (overflowed ? Int64.max : value, overflowed)
    }

    public static func multiplying(_ lhs: Int64, _ rhs: Int64) -> (value: Int64, overflowed: Bool) {
        let (value, overflowed) = lhs.multipliedReportingOverflow(by: rhs)
        return (overflowed ? Int64.max : value, overflowed)
    }
}
