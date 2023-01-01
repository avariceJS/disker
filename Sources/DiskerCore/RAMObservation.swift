import Darwin
import Foundation

public struct ProcessRAMSample: Codable, Equatable, Identifiable, Sendable {
    public var id: Int32 { processID }
    public let processID: Int32
    public let name: String
    public let residentBytes: UInt64
}

public struct RAMObservation: Codable, Equatable, Sendable {
    public let observedAt: Date
    public let physicalBytes: UInt64
    public let freeBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let processListAvailable: Bool
    public let sampledProcessCount: Int
    public let unavailableProcessCount: Int
    public let largestProcesses: [ProcessRAMSample]

    public static func current(processLimit: Int = 10) throws -> RAMObservation {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { values in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, values, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw RAMReadError.kernelFailure(status)
        }

        var pageSize: vm_size_t = 0
        let pageStatus = host_page_size(mach_host_self(), &pageSize)
        guard pageStatus == KERN_SUCCESS, pageSize > 0 else {
            throw RAMReadError.kernelFailure(pageStatus)
        }
        let pageBytes = UInt64(pageSize)
        let processList = (try? processIDs()).map { ($0, true) } ?? ([], false)
        let pids = processList.0
        var processes: [ProcessRAMSample] = []
        processes.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            var taskInfo = proc_taskinfo()
            let infoBytes = withUnsafeMutablePointer(to: &taskInfo) { pointer in
                proc_pidinfo(
                    pid, PROC_PIDTASKINFO, 0, pointer,
                    Int32(MemoryLayout<proc_taskinfo>.size)
                )
            }
            guard infoBytes == Int32(MemoryLayout<proc_taskinfo>.size) else { continue }
            processes.append(ProcessRAMSample(
                processID: pid,
                name: processName(pid) ?? "Process \(pid)",
                residentBytes: taskInfo.pti_resident_size
            ))
        }

        let sorted = processes.sorted { $0.residentBytes > $1.residentBytes }
        return RAMObservation(
            observedAt: .now,
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            freeBytes: UInt64(statistics.free_count) * pageBytes,
            activeBytes: UInt64(statistics.active_count) * pageBytes,
            inactiveBytes: UInt64(statistics.inactive_count) * pageBytes,
            wiredBytes: UInt64(statistics.wire_count) * pageBytes,
            compressedBytes: UInt64(statistics.compressor_page_count) * pageBytes,
            processListAvailable: processList.1,
            sampledProcessCount: processes.count,
            unavailableProcessCount: max(0, pids.count - processes.count),
            largestProcesses: Array(sorted.prefix(max(0, processLimit)))
        )
    }

    private static func processIDs() throws -> [pid_t] {
        let requiredBytes = proc_listallpids(nil, 0)
        guard requiredBytes > 0 else { throw RAMReadError.processListUnavailable }

        // libproc returns a process count; its input buffer size is still in bytes.
        // Retry if the process table grew between the sizing and listing calls.
        var capacity = Int(requiredBytes) + 16
        for _ in 0..<3 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let returnedCount = pids.withUnsafeMutableBytes { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count))
            }
            guard returnedCount >= 0 else { throw RAMReadError.processListUnavailable }
            if Int(returnedCount) <= pids.count {
                return Array(pids.prefix(Int(returnedCount))).filter { $0 > 0 }
            }
            capacity = Int(returnedCount) + 16
        }
        throw RAMReadError.processListUnavailable
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBufferPointer { bytes in
            proc_name(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }
}

public enum RAMReadError: Error, LocalizedError {
    case kernelFailure(kern_return_t)
    case processListUnavailable

    public var errorDescription: String? {
        switch self {
        case .kernelFailure(let code):
            return "macOS could not provide current RAM page statistics (Mach error \(code))."
        case .processListUnavailable:
            return "macOS did not provide a process list for this sample."
        }
    }
}
