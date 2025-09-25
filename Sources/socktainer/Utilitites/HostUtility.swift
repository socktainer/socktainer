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

func findAvailablePort() throws -> Int {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else {
        throw NSError(domain: "PortAllocation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create socket"])
    }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = INADDR_ANY
    addr.sin_port = 0  // Let system choose port

    let bindResult = withUnsafePointer(to: addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }

    guard bindResult == 0 else {
        close(sock)
        throw NSError(domain: "PortAllocation", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to bind socket"])
    }

    var actualAddr = sockaddr_in()
    var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let getsocknameResult = withUnsafeMutablePointer(to: &actualAddr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(sock, $0, &addrLen)
        }
    }

    close(sock)

    guard getsocknameResult == 0 else {
        throw NSError(domain: "PortAllocation", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to get socket name"])
    }

    return Int(CFSwapInt16BigToHost(actualAddr.sin_port))
}

public func parseSignal(_ signal: String) throws -> Int32 {
    let signalUpper = signal.uppercased()
    switch signalUpper {
    case "SIGTERM", "TERM", "15":
        return SIGTERM
    case "SIGKILL", "KILL", "9":
        return SIGKILL
    case "SIGINT", "INT", "2":
        return SIGINT
    case "SIGHUP", "HUP", "1":
        return SIGHUP
    case "SIGQUIT", "QUIT", "3":
        return SIGQUIT
    case "SIGABRT", "ABRT", "6":
        return SIGABRT
    case "SIGSTOP", "STOP", "19":
        return SIGSTOP
    case "SIGCONT", "CONT", "18":
        return SIGCONT
    case "SIGUSR1", "USR1", "10":
        return SIGUSR1
    case "SIGUSR2", "USR2", "12":
        return SIGUSR2
    case "SIGWINCH", "WINCH", "28":
        return SIGWINCH
    case "SIGTSTP", "TSTP", "20":
        return SIGTSTP
    case "SIGTTIN", "TTIN", "21":
        return SIGTTIN
    case "SIGTTOU", "TTOU", "22":
        return SIGTTOU
    default:
        if let signalNum = Int32(signalUpper) {
            return signalNum
        }
        throw NSError(domain: "SignalParsing", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid signal: \(signal)"])
    }
}
