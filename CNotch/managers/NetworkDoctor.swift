//
//  NetworkDoctor.swift
//  CNotch
//

import AppKit
import Defaults
import Foundation
import Network

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
        let tcpOK: Bool
        let dnsOK: Bool
        let tlsOK: Bool
        let verdict: Verdict
        let checkedAt: Date
    }

    @Published private(set) var lastResult: Result?
    @Published private(set) var isRunning = false

    /// Raw-IP TCP target: Cloudflare's resolver, reachable without DNS.
    private static let tcpProbeHost = "1.1.1.1"
    private static let tcpProbePort: UInt16 = 443
    private static let dnsProbeHost = "www.apple.com"
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
        defer { isRunning = false }

        let hasPath = await hasUsablePath()
        // Probes run in order of dependency, and each one is skipped once a
        // lower layer has already failed -- a TLS timeout tells you nothing
        // new when there's no route to send it over.
        let tcpOK = hasPath ? await tcpConnects() : false
        let dnsOK = tcpOK ? await dnsResolves() : false
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
            dnsOK: dnsOK,
            tlsOK: tlsOK,
            verdict: verdict,
            checkedAt: Date()
        )
        lastResult = result
        return result
    }

    private func hasUsablePath() async -> Bool {
        await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                box.resume(path.status == .satisfied)
                monitor.cancel()
            }
            monitor.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                box.resume(false)
                monitor.cancel()
            }
        }
    }

    private func tcpConnects() async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: Self.tcpProbePort) else { return false }
        return await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)
            let connection = NWConnection(host: .init(Self.tcpProbeHost), port: port, using: .tcp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.resume(true)
                    connection.cancel()
                case .failed, .cancelled:
                    box.resume(false)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                box.resume(false)
                connection.cancel()
            }
        }
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
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func tlsCompletes() async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
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

    /// The stack legitimately needs a few seconds after wake, so the first
    /// failure is never reported -- only one that's still failing on a second
    /// look is worth interrupting the user for.
    private func scheduleWakeCheck() {
        guard Defaults[.networkDoctorOnWake] else { return }
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }

            guard await self.runCheck().verdict != .healthy else { return }

            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }

            let confirmed = await self.runCheck()
            guard confirmed.verdict != .healthy else { return }
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

/// NWConnection / NWPathMonitor handlers can fire more than once, and a timeout
/// can race them, so the continuation needs a one-shot guard.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
