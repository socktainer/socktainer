import Foundation
import SystemConfiguration
import Vapor

/// The host's global default DNS resolvers, used when the upstream is set to `auto`.
///
/// Forwarding is raw UDP to these addresses, so scoped / split DNS (`/etc/resolver/*`,
/// per-domain VPN resolvers) is not consulted; only the global default resolvers are used.
enum SystemDNSResolvers {
    static let dynamicStoreKey = "State:/Network/Global/DNS"

    /// IPv4 default resolvers from SystemConfiguration, else from `/etc/resolv.conf`, in order.
    static func current() -> [DNSUpstream] {
        if let store = SCDynamicStoreCreate(nil, "socktainer.dns" as CFString, nil, nil),
            let dict = SCDynamicStoreCopyValue(store, dynamicStoreKey as CFString) as? [String: Any]
        {
            let resolvers = resolvers(fromDynamicStore: dict)
            if !resolvers.isEmpty { return resolvers }
        }
        let text = (try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8)) ?? ""
        return resolvers(fromResolvConf: text)
    }

    /// Extracts `ServerAddresses` from a `State:/Network/Global/DNS` dictionary.
    static func resolvers(fromDynamicStore dict: [String: Any]) -> [DNSUpstream] {
        usable(dict["ServerAddresses"] as? [String] ?? [])
    }

    /// Extracts the `nameserver` lines of a resolv.conf file.
    static func resolvers(fromResolvConf text: String) -> [DNSUpstream] {
        let addresses = text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "nameserver" else { return nil }
            return String(fields[1])
        }
        return usable(addresses)
    }

    /// Keeps the addresses `DNSUpstream.parse` accepts (plain IPv4, no unspecified or broadcast
    /// address; IPv6 and zone-scoped entries are dropped), canonicalized and de-duplicated, in order.
    private static func usable(_ addresses: [String]) -> [DNSUpstream] {
        var seen: Set<DNSUpstream> = []
        var result: [DNSUpstream] = []
        for address in addresses {
            guard let upstream = try? DNSUpstream.parse(address), seen.insert(upstream).inserted else { continue }
            result.append(upstream)
        }
        return result
    }
}

struct SystemDNSResolverWatcherKey: StorageKey {
    typealias Value = SystemDNSResolverWatcher
}

/// Calls `onChange` with the current resolvers once at `start()` and whenever the host's global
/// DNS configuration changes (VPN connect/disconnect, network switch), until `stop()`.
final class SystemDNSResolverWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "socktainer.dns.system-resolvers")
    private let onChange: @Sendable ([DNSUpstream]) -> Void
    private var store: SCDynamicStore?

    init(onChange: @escaping @Sendable ([DNSUpstream]) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard store == nil else { return }
        onChange(SystemDNSResolvers.current())
        var context = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let watcher = Unmanaged<SystemDNSResolverWatcher>.fromOpaque(info).takeUnretainedValue()
            watcher.onChange(SystemDNSResolvers.current())
        }
        guard let store = SCDynamicStoreCreate(nil, "socktainer.dns.watch" as CFString, callback, &context) else { return }
        SCDynamicStoreSetNotificationKeys(store, [SystemDNSResolvers.dynamicStoreKey] as CFArray, nil)
        SCDynamicStoreSetDispatchQueue(store, queue)
        self.store = store
    }

    /// Detaches from the dynamic store; no callback runs after this returns.
    func stop() {
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        self.store = nil
        queue.sync {}  // drain a callback that was already in flight
    }
}

/// Stops the watcher when the application shuts down.
struct SystemDNSResolverWatcherLifecycle: LifecycleHandler {
    let watcher: SystemDNSResolverWatcher

    func shutdown(_ application: Application) {
        watcher.stop()
    }
}
