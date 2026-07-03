/// Accepts exactly the signals Docker accepts, mirroring moby's `signal.ParseSignal`
/// (github.com/moby/sys signal_linux.go): a non-zero integer, or a case-insensitive
/// name — optionally `SIG`-prefixed — from the Linux signal set.
enum DockerSignal {
    private static let names: Set<String> = {
        var set: Set<String> = [
            "ABRT", "ALRM", "BUS", "CHLD", "CLD", "CONT", "FPE", "HUP", "ILL", "INT",
            "IO", "IOT", "KILL", "PIPE", "POLL", "PROF", "PWR", "QUIT", "SEGV", "STKFLT",
            "STOP", "SYS", "TERM", "TRAP", "TSTP", "TTIN", "TTOU", "URG", "USR1", "USR2",
            "VTALRM", "WINCH", "XCPU", "XFSZ", "RTMIN", "RTMAX",
        ]
        for n in 1...15 { set.insert("RTMIN+\(n)") }
        for n in 1...14 { set.insert("RTMAX-\(n)") }
        return set
    }()

    static func isValid(_ raw: String) -> Bool {
        if let number = Int(raw) { return number != 0 }
        var name = raw.uppercased()
        if name.hasPrefix("SIG") { name.removeFirst(3) }
        return names.contains(name)
    }
}
