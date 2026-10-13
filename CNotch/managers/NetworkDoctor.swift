//
//  NetworkDoctor.swift
//  CNotch
//

import AppKit
import CoreWLAN
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
        /// Wi-Fi is switched on but has not joined a network. Split out of
        /// `offline` because the two want opposite remedies and the panel had
        /// been showing the same four red rows for both. On 2026-09-28 the
        /// Mac spent twelve minutes joining saved networks and leaving them
        /// again four to six seconds later, and every probe failed in under a
        /// millisecond with no route to send on -- which reads exactly like
        /// the filter fault this class was written for, and is nothing like
        /// it.
        case notAssociated
        /// Path exists but raw TCP to a known IP fails: routing is broken.
        case routeBroken
        /// Raw TCP works but name resolution doesn't.
        case dnsBroken
        /// TCP and DNS both fine, but TLS dies -- the filtering layer.
        case filterBroken
        /// Connections open and then carry nothing, encrypted or not.
        ///
        /// Told apart from `filterBroken` by a plaintext fetch, because a
        /// failing TLS probe does not mean TLS is at fault. On 2026-09-28 a
        /// bare HTTP request to a literal address returned zero bytes over a
        /// connection that had opened in 54ms, while ICMP and UDP were
        /// perfect -- so the break was in TCP payload and the word "TLS",
        /// which this bug had been called for two weeks, was wrong.
        case dataStalled
        /// Port 443 will not open while port 80 carries bytes to the same
        /// address.
        ///
        /// Nothing is eating TLS here -- the port itself is shut, which is
        /// what a guest network does once its sign-in lapses. On 2026-10-06
        /// this was reported as `filterBroken` on a Mac whose filter was
        /// switched off, because a failing TLS probe was being read as proof
        /// of a filter. Port 80 answered `HTTP 200, 463 bytes` in the same
        /// capture, and that is the fact that separates the two.
        case portBlocked
    }

    /// What a plaintext request to a literal address found. Three outcomes,
    /// not two: "the socket never opened" is not the same answer as "it
    /// opened and nothing came back", and collapsing them turns one fault
    /// into a different one.
    enum DataFlow {
        /// Bytes came back, whatever TLS is doing.
        case flowed
        /// The socket opened and then nothing arrived.
        case stalled
        /// The socket never opened, so this probe has nothing to say.
        case noConnection
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
        /// nil when it was never asked -- only a failing TLS probe is worth
        /// following with this one.
        let dataFlow: DataFlow?
        /// How many times the Wi-Fi link changed recently, and how many
        /// networks this Mac has saved. Both nil unless the Mac has joined
        /// nothing, which is the only verdict they explain.
        let wifiHops: Int?
        let savedNetworks: Int?
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
    /// The plaintext byte probe's target. Port 80 on the same address the
    /// TCP probe uses, so a failure here cannot be blamed on a different
    /// host, a different route, or a name that would not resolve.
    private nonisolated static let bytesProbePort: UInt16 = 80
    private nonisolated static let dnsProbeHost = "www.apple.com"
    /// The same tiny page macOS itself uses for connectivity checks.
    private static let tlsProbeURL = URL(string: "https://www.apple.com/library/test/success.html")!

    private var wakeObserver: Any?
    private var wakeTask: Task<Void, Never>?

    /// When the network was first seen broken, so a recovery can say how long
    /// it lasted. Cleared once the recovery has been announced.
    private var brokenSince: Date?
    private var recoveryWatch: Task<Void, Never>?

    /// Short blips are the after-wake check confirming itself, not an outage
    /// anyone noticed; that sequence spans about twenty seconds.
    private static let outageWorthMentioning: TimeInterval = 120
    /// Re-checks while broken, so a recovery is noticed within a minute
    /// instead of waiting for the next wake or for the panel to be opened.
    /// Only while broken: a healthy Mac polls nothing.
    private static let recoveryPollInterval: TimeInterval = 60
    /// A bounded watch. If it has been broken this long nobody is waiting on
    /// a notification any more, and the panel still reports on demand.
    private static let recoveryWatchLimit: TimeInterval = 3600

    private init() {
        // Counting has to start before the hunt does, not when the panel is
        // opened in the middle of one.
        WiFiHops.shared.start()
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

        // Only when TLS failed, and only to ask whether encryption had
        // anything to do with it.
        var dataFlow: DataFlow?
        if dnsOK, !tlsOK {
            stage = "Checking whether data flows"
            dataFlow = await plaintextBytesFlow()
        }

        let verdict: Verdict
        if !hasPath {
            verdict = await wifiIsOnButUnjoined() ? .notAssociated : .offline
        } else if !tcpOK {
            verdict = .routeBroken
        } else if !dnsOK {
            verdict = .dnsBroken
        } else if !tlsOK {
            switch dataFlow {
            case .stalled:
                verdict = .dataStalled
            // Bytes move on port 80, but port 443 would not even open. That
            // is a shut port, not something eating the handshake.
            case .flowed where !tcp.international:
                verdict = .portBlocked
            default:
                verdict = .filterBroken
            }
        } else {
            verdict = .healthy
        }

        // Only for the verdict they explain. The saved-network count costs a
        // subprocess, and a healthy Mac has no use for it.
        var hops: Int?
        var saved: Int?
        if verdict == .notAssociated {
            hops = WiFiHops.shared.recentCount
            saved = await savedNetworkCount()
        }

        let result = Result(
            hasPath: hasPath,
            tcpOK: tcpOK,
            tcpInternationalOK: tcp.international,
            dnsOK: dnsOK,
            tlsOK: tlsOK,
            dataFlow: dataFlow,
            wifiHops: hops,
            savedNetworks: saved,
            verdict: verdict,
            checkedAt: Date()
        )
        lastResult = result
        noteRecovery(verdict)
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

    /// Whether Wi-Fi is powered on yet has joined nothing.
    ///
    /// `hasConfiguredInterface` above cannot answer this. An unassociated
    /// `en0` still reports `UP` and `RUNNING` -- the 2026-09-28 capture has
    /// the flags written down -- so the interface walk sees a live interface
    /// carrying no address and reports "no path". True, and silent about why.
    private func wifiIsOnButUnjoined() async -> Bool {
        await Task.detached(priority: .utility) { Self.wifiUnjoined() }.value
    }

    /// `activePHYMode` rather than `ssid`: reading the network's name needs
    /// Location permission and returns nil without it, which would make every
    /// Mac that has not granted it look permanently unassociated. The PHY mode
    /// is `.modeNone` exactly when nothing is joined, and needs no permission.
    private nonisolated static func wifiUnjoined() -> Bool {
        guard let interface = CWWiFiClient.shared().interface() else { return false }
        return interface.powerOn() && interface.activePHYMode() == .modeNone
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
        guard let descriptor = openConnection(host: host, port: port, timeout: timeout) else { return false }
        close(descriptor)
        return true
    }

    /// A connected, non-blocking socket, or nil. The caller closes it.
    ///
    /// Shared by the two probes that need one, because "did the handshake
    /// finish" and "did any bytes follow" are the same connection asked two
    /// questions, and the second is only meaningful on a socket the first
    /// has already accepted.
    private nonisolated static func openConnection(
        host: String, port: UInt16, timeout: TimeInterval
    ) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        // A literal address only -- this layer must not depend on DNS, which
        // is the next probe down and reported separately.
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let resolved = info else { return nil }
        defer { freeaddrinfo(info) }

        let descriptor = socket(
            resolved.pointee.ai_family, resolved.pointee.ai_socktype, resolved.pointee.ai_protocol
        )
        guard descriptor >= 0 else { return nil }

        // Non-blocking, so the connect can be given a deadline of our own
        // rather than the kernel's minute-and-a-bit.
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)
        if connect(descriptor, resolved.pointee.ai_addr, resolved.pointee.ai_addrlen) == 0 {
            return descriptor
        }
        guard errno == EINPROGRESS else { close(descriptor); return nil }

        var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { close(descriptor); return nil }
        // Writable only means the attempt finished; it still has to have
        // finished successfully, and a refusal also reports as writable.
        var failure: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Whether a connection that opened will actually carry bytes.
    ///
    /// Deliberately plaintext and deliberately to a literal address: no TLS,
    /// no DNS, no proxy, nothing but a request out and an answer back. When
    /// this fails on a socket that connected, encryption cannot be the cause
    /// and neither can name resolution.
    ///
    /// A raw socket rather than `URLSession` because App Transport Security
    /// refuses cleartext http:// -- and the whole value of this probe is that
    /// it is cleartext.
    private func plaintextBytesFlow() async -> DataFlow {
        await Task.detached(priority: .utility) {
            Self.receivesBytes(
                host: Self.tcpProbeHost, port: Self.bytesProbePort, timeout: 4
            )
        }.value
    }

    private nonisolated static func receivesBytes(
        host: String, port: UInt16, timeout: TimeInterval
    ) -> DataFlow {
        guard let descriptor = openConnection(host: host, port: port, timeout: timeout) else {
            // Never opened, so this probe has nothing to say: the layer below
            // already reported the failure and calling it a data stall would
            // be inventing a second fault out of the first one.
            return .noConnection
        }
        defer { close(descriptor) }

        // HTTP/1.0 so the server closes rather than holding the connection
        // open, and Host: because 1.1.1.1 serves a name-based site.
        let request = "HEAD / HTTP/1.0\r\nHost: one.one.one.one\r\n\r\n"
        let sent = request.withCString { send(descriptor, $0, strlen($0), 0) }
        guard sent > 0 else { return .stalled }

        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return .stalled }
        var buffer = [UInt8](repeating: 0, count: 64)
        // Any byte at all is the answer. What it says does not matter -- a
        // captive portal's redirect proves the path carries data just as well
        // as a 200 from the real server.
        return recv(descriptor, &buffer, buffer.count, 0) > 0 ? .flowed : .stalled
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

    /// Says when the network comes back, which this never used to do.
    ///
    /// It only ever spoke up about failures, so an outage that cleared left
    /// the user with no sign of it. That matters because some apps do not
    /// recover on their own: on 2026-10-06 Gemini's long-lived connections
    /// died during a 55-minute outage and every call it made for the next
    /// four hours timed out, because the app had been running throughout and
    /// never rebuilt them. Quitting it was the fix; knowing to was the hard
    /// part.
    private func noteRecovery(_ verdict: Verdict) {
        guard verdict != .healthy else {
            recoveryWatch?.cancel()
            recoveryWatch = nil
            guard let since = brokenSince else { return }
            brokenSince = nil
            let outage = Date().timeIntervalSince(since)
            guard outage >= Self.outageWorthMentioning else { return }
            announceRecovery(after: outage)
            return
        }
        guard brokenSince == nil else { return }
        brokenSince = Date()
        startRecoveryWatch()
    }

    private func startRecoveryWatch() {
        recoveryWatch?.cancel()
        recoveryWatch = Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(Self.recoveryWatchLimit)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(Self.recoveryPollInterval))
                guard !Task.isCancelled, let self, self.brokenSince != nil else { return }
                // runCheck calls back into noteRecovery, which cancels this
                // task once the answer is healthy.
                _ = await self.runCheck()
            }
        }
    }

    /// Deliberately not interpolated with the outage length.
    ///
    /// These strings are plain catalog keys that the views look up by their
    /// literal text, because the in-app language picker overrides SwiftUI's
    /// environment locale and `String(localized:)` does not read it. An
    /// interpolated String would match no key and show English forever. The
    /// duration is decoration; "restart what you left open" is the whole
    /// point, and that fits in a fixed line.
    private func announceRecovery(after outage: TimeInterval) {
        CNotchViewCoordinator.shared.toggleExpandingView(
            status: true,
            type: .liveActivity,
            value: -1,
            title: "Network is back",
            subtitle: "Apps left open may need restarting",
            icon: "checkmark.circle.fill"
        )
    }

    /// How many networks this Mac would join on its own.
    ///
    /// The count is the cause, not a symptom: with 255 of them saved and the
    /// office's own SSID not among them, the best network this Mac knew at
    /// work was a captive portal, so it joined, found no way out, left, and
    /// moved to the next -- for twelve minutes on 2026-09-28 and again on
    /// 09-29.
    /// Its own queue, because this waits on a subprocess.
    ///
    /// `Task.detached` would put that wait on Swift concurrency's cooperative
    /// pool, which is only as wide as the machine has cores and is shared by
    /// the whole app. Blocking it is what deadlocked every async call in
    /// CNotch once already.
    private nonisolated static let shellQueue = DispatchQueue(
        label: "com.cuonghm89.cnotch.netdoctor.shell", qos: .utility
    )

    private func savedNetworkCount() async -> Int? {
        await withCheckedContinuation { continuation in
            Self.shellQueue.async {
                continuation.resume(returning: Self.readSavedNetworkCount())
            }
        }
    }

    private nonisolated static func readSavedNetworkCount() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listpreferredwirelessnetworks", "en0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // Bounded: a subprocess that never exits would hold this queue's
        // thread for good.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        watchdog.cancel()
        // The first line is "Preferred networks on en0:".
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        return max(0, lines.count - 1)
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
        case .notAssociated: "Wi-Fi is not connected"
        case .routeBroken: "No route out"
        case .dnsBroken: "DNS is down"
        case .filterBroken: "Network filter is broken"
        case .dataStalled: "Connections carry no data"
        case .portBlocked: "HTTPS is blocked"
        }
    }

    static func subtitle(for verdict: Verdict) -> String {
        switch verdict {
        case .healthy: "All layers responded"
        case .offline: "Wi-Fi is off, or no interface has an address"
        case .notAssociated: "Wi-Fi is on but hasn't joined a network — check which network it's on"
        case .routeBroken: "Connected, but packets go nowhere"
        case .dnsBroken: "Connections work, names don't resolve"
        case .filterBroken: "Wi-Fi and DNS are fine — a content filter is eating traffic"
        case .dataStalled: "Connections open and then stall — not encryption; a socket filter is holding traffic"
        case .portBlocked: "Plain web traffic works but port 443 won't open — a guest network may want you to sign in again"
        }
    }

    static func icon(for verdict: Verdict) -> String {
        switch verdict {
        case .healthy: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        case .notAssociated: "antenna.radiowaves.left.and.right.slash"
        case .routeBroken: "network.slash"
        case .dnsBroken: "wifi.exclamationmark"
        case .filterBroken: "network.badge.shield.half.filled"
        case .dataStalled: "arrow.up.arrow.down.circle.fill"
        case .portBlocked: "lock.slash"
        }
    }
}

/// Counts how often the Wi-Fi link changes, so "not associated" can say
/// whether the Mac is sitting still or hunting.
///
/// The hunt is the shape of a real bug seen twice: macOS joins a saved
/// network, finds no way to the internet, leaves four to six seconds later
/// and tries the next one, round and round. A single snapshot of that looks
/// identical to a dead router -- it is only the churn that tells them apart,
/// and a count is something this app can measure rather than guess at.
///
/// `linkDidChange` rather than `ssidDidChange`: reading the network's name
/// needs Location permission, which this Mac has not granted, so the names
/// would come back empty. The count needs no permission.
@MainActor
final class WiFiHops: NSObject, CWEventDelegate {
    static let shared = WiFiHops()

    /// Long enough to cover a hunt, short enough that yesterday's roaming
    /// does not count towards today.
    private static let window: TimeInterval = 10 * 60
    private var changes: [Date] = []

    func start() {
        let client = CWWiFiClient.shared()
        client.delegate = self
        try? client.startMonitoringEvent(with: .linkDidChange)
    }

    /// Link changes in the last ten minutes. A join and a leave are two
    /// events, so a hunt counts roughly double -- which is why the panel
    /// talks about "changes" and not "networks".
    var recentCount: Int {
        let cutoff = Date().addingTimeInterval(-Self.window)
        changes.removeAll { $0 < cutoff }
        return changes.count
    }

    // Called on CoreWLAN's own thread.
    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in
            self?.changes.append(Date())
        }
    }
}
