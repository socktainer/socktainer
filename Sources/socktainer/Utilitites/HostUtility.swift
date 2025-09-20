import Foundation

public func isDebug() -> Bool {
    #if DEBUG
    return true
    #else
    return false
    #endif
}

public func hostCPUCoreCount() -> Int {
    ProcessInfo.processInfo.processorCount
}

public func hostPhysicalMemory() -> UInt64 {
    ProcessInfo.processInfo.physicalMemory
}

public func hostName() -> String {
    var hostname = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN))
    gethostname(&hostname, Int(MAXHOSTNAMELEN))
    let length = hostname.firstIndex(of: 0) ?? hostname.count
    let bytes = hostname[..<length].map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

public func currentTime() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

public func getKernel() -> String {
    var uts = utsname()
    uname(&uts)
    let release = withUnsafePointer(to: &uts.release) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
            String(cString: $0)
        }
    }
    return release
}
