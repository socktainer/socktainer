import ContainerResource
import Foundation
import Testing

@testable import socktainer

@Suite("ContainerStats")
struct ContainerStatsTests {

    // MARK: - Helpers

    private func makeSample(
        cpuUsec: UInt64 = 0,
        memUsage: UInt64? = nil,
        memLimit: UInt64? = nil,
        netRx: UInt64? = nil,
        netTx: UInt64? = nil,
        blkRead: UInt64? = nil,
        blkWrite: UInt64? = nil,
        pids: UInt64? = nil
    ) -> ContainerStats {
        ContainerStats(
            id: "test",
            memoryUsageBytes: memUsage,
            memoryLimitBytes: memLimit,
            cpuUsageUsec: cpuUsec,
            networkRxBytes: netRx,
            networkTxBytes: netTx,
            blockReadBytes: blkRead,
            blockWriteBytes: blkWrite,
            numProcesses: pids
        )
    }

    // MARK: - Model builder

    @Test("CPU total_usage converts µs to ns (× 1000)")
    func cpuUsecToNs() {
        let prev = makeSample(cpuUsec: 1_000_000)
        let curr = makeSample(cpuUsec: 2_000_000)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", prev: prev, curr: curr, prevRead: t0, currRead: t1)
        #expect(stats.cpu_stats.cpu_usage.total_usage == 2_000_000_000)
        #expect(stats.precpu_stats.cpu_usage.total_usage == 1_000_000_000)
    }

    @Test("precpu_stats system_cpu_usage is 0 (no elapsed time for baseline)")
    func precpuSystemIsZero() {
        let sample = makeSample(cpuUsec: 500_000)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", prev: sample, curr: sample, prevRead: t0, currRead: t1)
        #expect(stats.precpu_stats.system_cpu_usage == 0)
    }

    @Test("system_cpu_usage equals numCPUs × elapsed nanoseconds")
    func systemCPUUsage() {
        let sample = makeSample()
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", prev: sample, curr: sample, prevRead: t0, currRead: t1)
        let expected = UInt64(hostCPUCoreCount()) * 1_000_000_000
        // Allow ±5ms tolerance for timing
        #expect(abs(Int64(stats.cpu_stats.system_cpu_usage) - Int64(expected)) < 5_000_000)
    }

    @Test("online_cpus matches host CPU count")
    func onlineCPUs() {
        let sample = makeSample()
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", prev: sample, curr: sample, prevRead: t0, currRead: t1)
        #expect(stats.cpu_stats.online_cpus == hostCPUCoreCount())
    }

    @Test("memory_stats usage and limit are passed through")
    func memoryStats() {
        let curr = makeSample(memUsage: 128_000_000, memLimit: 4_000_000_000)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", prev: makeSample(), curr: curr, prevRead: t0, currRead: t1)
        #expect(stats.memory_stats.usage == 128_000_000)
        #expect(stats.memory_stats.limit == 4_000_000_000)
    }

    @Test("memory limit falls back to host physical memory when nil")
    func memoryLimitFallback() {
        let curr = makeSample(memUsage: 64_000_000, memLimit: nil)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", prev: makeSample(), curr: curr, prevRead: t0, currRead: t1)
        #expect(stats.memory_stats.limit == hostPhysicalMemory())
    }

    @Test("networks eth0 rx/tx bytes are populated when available")
    func networkStats() {
        let curr = makeSample(netRx: 1_234, netTx: 5_678)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", prev: makeSample(), curr: curr, prevRead: t0, currRead: t1)
        #expect(stats.networks?["eth0"]?.rx_bytes == 1_234)
        #expect(stats.networks?["eth0"]?.tx_bytes == 5_678)
    }

    @Test("networks is nil when no network data available")
    func networkStatsNil() {
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", prev: makeSample(), curr: makeSample(), prevRead: t0, currRead: t1)
        #expect(stats.networks == nil)
    }

    @Test("blkio_stats contains read and write entries when available")
    func blkioStats() {
        let curr = makeSample(blkRead: 10_000, blkWrite: 20_000)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", prev: makeSample(), curr: curr, prevRead: t0, currRead: t1)
        let entries = stats.blkio_stats.io_service_bytes_recursive
        #expect(entries?.first(where: { $0.op == "read" })?.value == 10_000)
        #expect(entries?.first(where: { $0.op == "write" })?.value == 20_000)
    }

    @Test("pids_stats current is passed through")
    func pidsStats() {
        let curr = makeSample(pids: 7)
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(id: "c1", prev: makeSample(), curr: curr, prevRead: t0, currRead: t1)
        #expect(stats.pids_stats.current == 7)
    }

    @Test("read and preread timestamps are ISO8601 strings")
    func timestamps() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = Date(timeIntervalSince1970: 1_000_001)
        let stats = RESTContainerStats.build(id: "c1", prev: makeSample(), curr: makeSample(), prevRead: t0, currRead: t1)
        #expect(stats.read.contains("T"))
        #expect(stats.preread.contains("T"))
        #expect(stats.read != stats.preread)
    }

    @Test("model serializes to JSON without errors")
    func jsonSerialization() throws {
        let t0 = Date()
        let t1 = Date(timeIntervalSince1970: t0.timeIntervalSince1970 + 1)
        let stats = RESTContainerStats.build(
            id: "c1",
            prev: makeSample(cpuUsec: 1_000_000, memUsage: 64_000_000, memLimit: 2_000_000_000),
            curr: makeSample(
                cpuUsec: 2_000_000, memUsage: 128_000_000, memLimit: 2_000_000_000,
                netRx: 1234, netTx: 5678, blkRead: 100, blkWrite: 200, pids: 5),
            prevRead: t0, currRead: t1
        )
        let data = try JSONEncoder().encode(stats)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["id"] as? String == "c1")
        #expect(json?["cpu_stats"] != nil)
        #expect(json?["memory_stats"] != nil)
        #expect(json?["networks"] != nil)
        #expect(json?["pids_stats"] != nil)
    }
}
