import ContainerResource
import Foundation
import Vapor

// MARK: - Docker /containers/{id}/stats response model

struct RESTContainerStats: Content {
    let id: String
    let read: String  // ISO8601 timestamp of this sample
    let preread: String  // ISO8601 timestamp of previous sample

    let cpu_stats: CPUStats
    let precpu_stats: CPUStats
    let memory_stats: MemoryStats
    let networks: [String: NetworkStats]?
    let blkio_stats: BlkioStats
    let pids_stats: PidsStats

    struct CPUStats: Content {
        let cpu_usage: CPUUsage
        let system_cpu_usage: UInt64
        let online_cpus: Int
        let throttling_data: ThrottlingData

        struct CPUUsage: Content {
            let total_usage: UInt64  // nanoseconds
            let usage_in_kernelmode: UInt64
            let usage_in_usermode: UInt64
        }

        struct ThrottlingData: Content {
            let throttled_periods: UInt64
            let throttled_time: UInt64
            let throttling_periods: UInt64
        }
    }

    struct MemoryStats: Content {
        let usage: UInt64?
        let limit: UInt64?
        let stats: [String: UInt64]?
    }

    struct NetworkStats: Content {
        let rx_bytes: UInt64
        let rx_packets: UInt64
        let rx_errors: UInt64
        let rx_dropped: UInt64
        let tx_bytes: UInt64
        let tx_packets: UInt64
        let tx_errors: UInt64
        let tx_dropped: UInt64
    }

    struct BlkioStats: Content {
        let io_service_bytes_recursive: [BlkioEntry]?

        struct BlkioEntry: Content {
            let major: UInt64
            let minor: UInt64
            let op: String
            let value: UInt64
        }
    }

    struct PidsStats: Content {
        let current: UInt64?
    }
}

// MARK: - Builder

extension RESTContainerStats {
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Builds a Docker-compatible stats response from two Apple Container samples.
    /// `prev` is the earlier sample (maps to precpu_stats), `curr` is the latest.
    /// CPU total_usage is derived from cpuUsageUsec × 1000 (µs → ns).
    /// system_cpu_usage is synthesised as numCPUs × elapsed nanoseconds so Docker
    /// clients can compute the standard CPU% formula without dividing by zero.
    static func build(
        id: String,
        prev: ContainerResource.ContainerStats,
        curr: ContainerResource.ContainerStats,
        prevRead: Date,
        currRead: Date
    ) -> RESTContainerStats {
        let numCPUs = hostCPUCoreCount()
        let elapsedNs = UInt64(max(0, currRead.timeIntervalSince(prevRead) * 1_000_000_000))
        let systemCPU = UInt64(numCPUs) * elapsedNs

        func cpuStats(from sample: ContainerResource.ContainerStats, systemCPU: UInt64) -> CPUStats {
            let totalNs = (sample.cpuUsageUsec ?? 0) * 1000
            return CPUStats(
                cpu_usage: CPUStats.CPUUsage(
                    total_usage: totalNs,
                    usage_in_kernelmode: 0,
                    usage_in_usermode: totalNs
                ),
                system_cpu_usage: systemCPU,
                online_cpus: numCPUs,
                throttling_data: CPUStats.ThrottlingData(
                    throttled_periods: 0,
                    throttled_time: 0,
                    throttling_periods: 0
                )
            )
        }

        let blkioEntries: [BlkioStats.BlkioEntry]? =
            (curr.blockReadBytes != nil || curr.blockWriteBytes != nil)
            ? [
                BlkioStats.BlkioEntry(major: 8, minor: 0, op: "read", value: curr.blockReadBytes ?? 0),
                BlkioStats.BlkioEntry(major: 8, minor: 0, op: "write", value: curr.blockWriteBytes ?? 0),
            ]
            : nil

        let networks: [String: NetworkStats]?
        if curr.networkRxBytes != nil || curr.networkTxBytes != nil {
            networks = [
                "eth0": NetworkStats(
                    rx_bytes: curr.networkRxBytes ?? 0,
                    rx_packets: 0, rx_errors: 0, rx_dropped: 0,
                    tx_bytes: curr.networkTxBytes ?? 0,
                    tx_packets: 0, tx_errors: 0, tx_dropped: 0
                )
            ]
        } else {
            networks = nil
        }

        return RESTContainerStats(
            id: id,
            read: iso8601.string(from: currRead),
            preread: iso8601.string(from: prevRead),
            cpu_stats: cpuStats(from: curr, systemCPU: systemCPU),
            precpu_stats: cpuStats(from: prev, systemCPU: 0),
            memory_stats: MemoryStats(
                usage: curr.memoryUsageBytes,
                limit: curr.memoryLimitBytes ?? hostPhysicalMemory(),
                stats: nil
            ),
            networks: networks,
            blkio_stats: BlkioStats(io_service_bytes_recursive: blkioEntries),
            pids_stats: PidsStats(current: curr.numProcesses)
        )
    }
}
