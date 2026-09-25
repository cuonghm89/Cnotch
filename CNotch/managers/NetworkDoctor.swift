//
//  NetworkDoctor.swift
//  CNotch
//

import AppKit
import Darwin
import Defaults
import Foundation

/// Probes the network one layer at a time so a failure can be pinned to the
/// layer that actually broke.
///
/// The case this exists for: after a sleep/wake cycle the Wi-Fi link, DHCP and
/// DNS can all come back perfectly while every connection still dies, because
/// content filters / transparent proxies (AdGuard, Kaspersky, Little Snitch...)
/// divert every flow through userspace and don't always survive the wake. The
/// system reports the path as "satisfied" the whole time, so macOS's own Wi-Fi
/// indicator shows nothing wrong and the usual remedies (renew DHCP, flush DNS,
/// toggle Wi-Fi) can't help -- they're all aimed at layers that were never
/// broken.
@MainActor
final class NetworkDoctor: ObservableObject {
    static let shared = NetworkDoctor()

    enum Verdict: String {
        /// Everything answered.
        case healthy
        /// No usable path at all -- genuinely offline.
        case offline
        /// Path exists but raw TCP to a known IP fails: routing is broken.
        case routeBroken
        /// Raw TCP works but name resolution doesn't.
        case dnsBroken
        /// TCP and DNS both fine, but TLS dies -- the filtering layer.
        case filterBroken
    }

    struct Result: Equatable {
        let hasPath: Bool
        /// True when *either* target answered.
        let tcpOK: Bool
        /// True only when the target outside the country answered. Equal to
        /// `tcpOK` on a healthy connection; false while `tcpOK` is true means
        /// the domestic route is up and the international one is not, which
        /// is a fault worth naming rather than averaging away.
        let tcpInternationalOK: Bool
        let dnsOK: Bool
        let tlsOK: Bool
        let verdict: Verdict
        let checkedAt: Date
    }

    @Published private(set) var lastResult: Result?
    @Published private(set) var isRunning = false
    /// Which layer is being probed right now, so a long check looks like work
    /// rather than a hang.
    @Published private(set) var stage: String?

    // `nonisolated`: the class is @MainActor, so these constants are too,
    // and the probes read them from detached tasks. Swift 6 makes that
    // isolation crossing an error rather than a warning.
    /// Raw-IP TCP target: Cloudflare's resolver, reachable without DNS.
    private nonisolated static let tcpProbeHost = "1.1.1.1"
    private nonisolated static let tcpProbePort: UInt16 = 443
    /// Tried only when the first fails, and it is inside the country on
    /// purpose: an international route can be congested or cut while the
    /// local network is perfectly well, and calling that "no route out"
    /// would be a false alarm. A resolver, because answering TCP on 53 is
    /// its job. Not anycast, so it is the fallback and never the first ask.
    private nonisolated static let domesticProbeHost = "203.113.131.1"
    private nonisolated static let domesticProbePort: UInt16 = 53
    private nonisolated static let dnsProbeHost = "www.apple.com"
    /// The same tiny page macOS itself uses for connectivity checks.
    private static let tlsProbeURL = URL(string: "https://www.apple.com/library/test/success.html")!

    private var wakeObserver: Any?
    private var wakeTask: Task<Void, Never>?

    private init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleWakeCheck() }
        }
    }

    // MARK: - Checks

    @discardableResult
    func runCheck() async -> Result {
        isRunning = true
        defer {
            isRunning = false
            stage = nil
        }

        stage = "Checking the link"
        let hasPath = await hasUsablePath()
        // Probes run in order of dependency, and each one is skipped once a
        // lower layer has already failed -- a TLS timeout tells you nothing
        // new when there's no route to send it over.
        if hasPath { stage = "Checking routing" }
        let tcp = hasPath ? await tcpConnects() : (any: false, international: false)
        let tcpOK = tcp.any

        if tcpOK { stage = "Checking DNS" }
        let dnsOK = tcpOK ? await dnsResolves() : false

        if dnsOK { stage = "Checking TLS" }
        let tlsOK = dnsOK ? await tlsCompletes() : false

        let verdict: Verdict
        if !hasPath {
            verdict = .offline
        } else if !tcpOK {
            verdict = .routeBroken
        } else if !dnsOK {
            verdict = .dnsBroken
        } else if !tlsOK {
            verdict = .filterBroken
        } else {
            verdict = .healthy
        }

        let result = Result(
            hasPath: hasPath,
            tcpOK: tcpOK,
            tcpInternationalOK: tcp.international,
            dnsOK: dnsOK,
            tlsOK: tlsOK,
            verdict: verdict,
            checkedAt: Date()
        )
        lastResult = result
        return result
    }

    /// Whether there is a usable link at all.
    ///
    /// This used to ask `NWPathMonitor`, which is the documented way and works
    /// fine in a command-line tool -- but inside this app its handler is never
    /// called. Every generic path evaluator the process has ever started shows
    /// in the log as an `nw_path_evaluator_start` followed by a cancel at
    /// exactly this check's own timeout, with no update in between, so the
    /// probe reported "no path" on a perfectly healthy Mac and the three
    /// layers below it were skipped as unreachable -- the whole panel red,
    /// every time, for a network that was fine.
    ///
    /// `getifaddrs` answers the same question straight from the kernel in
    /// under a millisecond, with no callback that can fail to arrive.
    private func hasUsablePath() async -> Bool {
        await Task.detached(priority: .utility) { Self.hasConfiguredInterface() }.value
    }

    /// An interface that is up, running, not loopback, and carries a real
    /// address. Link-local doesn't count: `awdl0` and `llw0` always have one,
    /// so accepting those would report a usable path with Wi-Fi switched off.
    private nonisolated static func hasConfiguredInterface() -> Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return false }
        defer { freeifaddrs(addresses) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let address = interface.pointee.ifa_addr
            else { continue }

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr
                }
                // 169.254.0.0/16 -- self-assigned, which means DHCP never answered.
                if UInt32(bigEndian: raw) >> 16 != 0xA9FE { return true }
            case AF_INET6:
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr.__u6_addr.__u6_addr8
                }
                if !(bytes.0 == 0xFE && bytes.1 & 0xC0 == 0x80) { return true }
            default: continue
            }
        }
        return false
    }

    /// Whether TCP works at all, and whether it works beyond the country.
    private func tcpConnects() async -> (any: Bool, international: Bool) {
        await Task.detached(priority: .utility) {
            let international = Self.canConnect(
                host: Self.tcpProbeHost, port: Self.tcpProbePort, timeout: 3
            )
            if international { return (true, true) }
            // Only now, and with a shorter deadline: this runs after a probe
            // that has already spent its five seconds failing.
            let domestic = Self.canConnect(
                host: Self.domesticProbeHost, port: Self.domesticProbePort, timeout: 2
            )
            return (domestic, false)
        }.value
    }

    /// A plain POSIX socket rather than `NWConnection`. The same path
    /// evaluation that never answers for `NWPathMonitor` in this process sits
    /// underneath `NWConnection` too, and a probe whose whole job is to be
    /// believed when the network stack misbehaves has no business depending on
    /// the part of it that is misbehaving.
    private nonisolated static func canConnect(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        // A literal address only -- this layer must not depend on DNS, which
        // is the next probe down and reported separately.
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let resolved = info else { return false }
        defer { freeaddrinfo(info) }

        let descriptor = socket(
            resolved.pointee.ai_family, resolved.pointee.ai_socktype, resolved.pointee.ai_protocol
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // Non-blocking, so the connect can be given a deadline of our own
        // rather than the kernel's minute-and-a-bit.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        if connect(descriptor, resolved.pointee.ai_addr, resolved.pointee.ai_addrlen) == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return false }
        // Writable only means the attempt finished; it still has to have
        // finished successfully, and a refusal also reports as writable.
        var failure: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 else { return false }
        return failure == 0
    }

    private func dnsResolves() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var info: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(Self.dnsProbeHost, nil, &hints, &info)
                if let info { freeaddrinfo(info) }
                return status == 0
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func tlsCompletes() async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: Self.tlsProbeURL)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }

    // MARK: - Wake handling

    /// How long Wi-Fi is given to come back before its absence counts as a
    /// fault. Reassociating and getting an address took longer than the
    /// twenty-two seconds this used to allow on three occasions out of four
    /// -- every one of which was reported as "offline" and captured a
    /// snapshot of a machine whose card simply had not finished waking.
    private static let linkGracePeriod: TimeInterval = 90

    /// Waits for an interface to carry a real address again.
    private static func waitForLink(upTo seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await Task.detached(priority: .utility, operation: {
                hasConfiguredInterface()
            }).value {
                return true
            }
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return false }
        }
        return false
    }

    /// The stack legitimately needs time after wake, so nothing is judged
    /// until the link is back -- and then only a failure that survives a
    /// second look is worth interrupting the user for.
    private func scheduleWakeCheck() {
        guard Defaults[.networkDoctorOnWake] else { return }
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // No link yet is not a fault, it is a wake in progress. Only its
            // refusal to come back at all is worth saying anything about.
            guard await Self.waitForLink(upTo: Self.linkGracePeriod) else {
                guard !Task.isCancelled else { return }
                let stillDown = await self.runCheck()
                guard stillDown.verdict != .healthy else { return }
                NetworkWakeSnapshot.capture(stillDown)
                self.announce(stillDown)
                return
            }
            guard !Task.isCancelled else { return }

            // Associated is not the same as routable: DHCP and the default
            // route land a moment later.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }

            guard await self.runCheck().verdict != .healthy else { return }

            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }

            let confirmed = await self.runCheck()
            guard confirmed.verdict != .healthy else { return }
            // Write it down before anything else. The user's next move is
            // usually a reboot, and three occurrences of this bug have
            // already been lost that way.
            NetworkWakeSnapshot.capture(confirmed)
            self.announce(confirmed)
        }
    }

    private func announce(_ result: Result) {
        CNotchViewCoordinator.shared.toggleExpandingView(
            status: true,
            type: .liveActivity,
            value: -1,
            title: Self.title(for: result.verdict),
            subtitle: Self.subtitle(for: result.verdict),
            icon: Self.icon(for: result.verdict)
        )
    }

    // MARK: - Presentation

    /// Returned as plain English catalog keys, not `String(localized:)`:
    /// the in-app language picker works by overriding SwiftUI's environment
    /// locale, which `String(localized:)` doesn't read -- it would always
    /// follow the system language instead. The views wrap these in
    /// `LocalizedStringKey` so the lookup happens in the right locale.
    static func title(for verdict: Verdict) -> String {
        switch verdict {
        case .healthy: "Network is healthy"
        case .offline: "No network"
        case .routeBroken: "No route out"
        case .dnsBroken: "DNS is down"
        case .filterBroken: "Network filter is broken"
        }
    }

    static func subtitle(for verdict: Verdict) -> String {
        switch verdict {
        case .healthy: "All layers responded"
        case .offline: "Wi-Fi has no usable path"
        case .routeBroken: "Connected, but packets go nowhere"
        case .dnsBroken: "Connections work, names don't resolve"
        case .filterBroken: "Wi-Fi and DNS are fine — a content filter is eating traffic"
        }
    }

    static func icon(for verdict: Verdict) -> String {
        switch verdict {
        case .healthy: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        case .routeBroken: "network.slash"
        case .dnsBroken: "wifi.exclamationmark"
        case .filterBroken: "network.badge.shield.half.filled"
        }
    }
}
