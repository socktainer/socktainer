/// Accepts exactly the signals Docker accepts, mirroring moby's `signal.ParseSignal`
/// (github.com/moby/sys signal_linux.go): a non-zero integer, or a case-insensitive
/// name — optionally `SIG`-prefixed — from the Linux signal set.
enum DockerSignal {
    private static let numbers: [String: UInt32] = [
        "HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "TRAP": 5, "ABRT": 6,
        "BUS": 7, "FPE": 8, "KILL": 9, "USR1": 10, "SEGV": 11,
        "USR2": 12, "PIPE": 13, "ALRM": 14, "TERM": 15, "CHLD": 17,
        "CONT": 18, "STOP": 19, "TSTP": 20, "TTIN": 21, "TTOU": 22,
        "URG": 23, "XCPU": 24, "XFSZ": 25, "VTALRM": 26, "PROF": 27,
        "WINCH": 28, "IO": 29, "PWR": 30, "SYS": 31,
    ]
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
        if let number = Int(raw) { return (1...64).contains(number) }
        var name = raw.uppercased()
        if name.hasPrefix("SIG") { name.removeFirst(3) }
        return names.contains(name)
    }

    static func number(_ raw: String) -> UInt32? {
        if let number = UInt32(raw), (1...64).contains(number) { return number }
        var name = raw.uppercased()
        if name.hasPrefix("SIG") { name.removeFirst(3) }
        if let number = numbers[name] { return number }
        switch name {
        case "IOT": return 6
        case "STKFLT": return 16
        case "CLD": return 17
        case "POLL": return 29
        case "RTMIN": return 34
        case "RTMAX": return 64
        default:
            if name.hasPrefix("RTMIN+"), let offset = UInt32(name.dropFirst(6)), (1...15).contains(offset) {
                return 34 + offset
            }
            if name.hasPrefix("RTMAX-"), let offset = UInt32(name.dropFirst(6)), (1...14).contains(offset) {
                return 64 - offset
            }
            return nil
        }
    }
}
