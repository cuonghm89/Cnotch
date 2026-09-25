//
//  NetworkWakeSnapshot.swift
//  CNotch
//
//  Writes down what the network looked like the moment it broke.
//

import Darwin
import Defaults
import Foundation
import os

/// Captures the state of the network when the after-wake check fails.
///
/// This exists because three occurrences of a real bug were lost. The machine
/// loses all network after waking, only a reboot fixes it, and the one thing
/// that would identify the layer -- a look at it while it is broken -- never
/// happened, because the person it happens to wants their machine back and
/// reboots. Asking them to remember a script mid-outage has failed every
/// time, so the app remembers instead.
///
/// The unified log survives a reboot and carries a good deal, but not the
/// things that actually separate the candidates: whether a bare TCP connect
/// to a literal address succeeds, whether ICMP does, whether the gateway is
/// in the ARP table. Those have to be asked at the time.
enum NetworkWakeSnapshot {
    /// `~/Library/Logs/CNotch` -- where a Mac keeps this sort of thing, and
    /// somewhere the user can be pointed at without explaining a path.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CNotch", isDirectory: true)
    }

    static var existingSnapshots: [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("network-wake-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Its own serial queue, and blocking on it is deliberate.
    ///
    /// Every command here waits on a subprocess. On Swift concurrency's
    /// cooperative pool that would be a bug -- the pool is as wide as the
    /// machine has cores and the whole app shares it. On a queue of its own,
    /// used for nothing else, waiting is simply what this work does.
    private static let queue = DispatchQueue(label: "com.cuonghm89.cnotch.netsnapshot", qos: .utility)

    static func capture(_ result: NetworkDoctor.Result) {
        guard Defaults[.networkWakeSnapshotEnabled] else { return }
        queue.async {
            let text = compose(result)
            let url = directory.appendingPathComponent("network-wake-\(stamp()).txt")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                AppLog.display.notice("Wrote a network snapshot after a failed wake check")
                prune()
            } catch {
                AppLog.display.error("Could not write the network snapshot: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Contents

    private static func compose(_ result: NetworkDoctor.Result) -> String {
        var out = """
        CNotch network snapshot
        Taken     \(ISO8601DateFormatter().string(from: Date()))
        Version   \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        Uptime    \(uptimeDescription())

        The after-wake check reported: \(result.verdict.rawValue)
          Wi-Fi path   \(mark(result.hasPath))
          TCP          \(mark(result.tcpOK))
          DNS          \(mark(result.dnsOK))
          TLS          \(mark(result.tlsOK))

        """

        let gateway = defaultGateway()
        out += section("Default gateway", gateway ?? "(none found)")

        // The question the log cannot answer: does a bare TCP connect to a
        // literal address work? No DNS, no TLS, no proxy -- just the
        // handshake. If this fails while ICMP below succeeds, packets are
        // leaving and something local is refusing sockets.
        out += section("TCP to 1.1.1.1:443", describe(tcpProbe(host: "1.1.1.1", port: 443)))
        out += section("TCP to 8.8.8.8:53", describe(tcpProbe(host: "8.8.8.8", port: 53)))
        // The domestic fallback the after-wake check uses. If this answers
        // while the two above do not, the break is on the way out of the
        // country rather than on this machine.
        out += section("TCP to 203.113.131.1:53 (domestic)", describe(tcpProbe(host: "203.113.131.1", port: 53)))

        // The crossed pair, and the reason for it: on 2026-09-24 every port
        // 443 attempt timed out while every port 53 attempt succeeded -- but
        // the 443 attempts were to one set of hosts and the 53 attempts to
        // another, so host and port were confounded and the capture could
        // not say which mattered. These four ask the same two hosts on both
        // ports, which separates them outright.
        out += section("TCP to 1.1.1.1:53", describe(tcpProbe(host: "1.1.1.1", port: 53)))
        out += section("TCP to 1.1.1.1:80", describe(tcpProbe(host: "1.1.1.1", port: 80)))
        out += section("TCP to 8.8.8.8:443", describe(tcpProbe(host: "8.8.8.8", port: 443)))
        out += section("TCP to 203.113.131.1:443", describe(tcpProbe(host: "203.113.131.1", port: 443)))

        // Connecting is not the same as carrying data. On 2026-09-25 every
        // connect above succeeded -- 1.1.1.1:443 in 8ms -- while the TLS
        // probe failed, which leaves three possibilities the capture could
        // not tell apart: TLS itself, any data at all after the handshake, or
        // that one hostname. These two send real bytes to a literal address,
        // one encrypted and one not, and separate all three.
        out += section("HTTP to 1.1.1.1:80 (bytes, no TLS)", run("/usr/bin/curl", [
            "-sS", "--max-time", "8", "-o", "/dev/null",
            "-w", "HTTP %{http_code}, %{size_download} bytes, %{time_total}s",
            "http://1.1.1.1/",
        ]))
        // -k: the certificate cannot match a bare address, and whether the
        // handshake completes at all is the only question here.
        out += section("TLS to 1.1.1.1:443 (no DNS)", run("/usr/bin/curl", [
            "-sS", "--max-time", "8", "-k", "-o", "/dev/null",
            "-w", "HTTP %{http_code}, handshake %{time_appconnect}s, total %{time_total}s",
            "https://1.1.1.1/",
        ]))
        if let gateway {
            out += section("TCP to gateway:80", describe(tcpProbe(host: gateway, port: 80)))
        }

        out += section("ping 1.1.1.1", run("/sbin/ping", ["-c", "3", "-t", "4", "1.1.1.1"]))
        if let gateway {
            out += section("ping gateway", run("/sbin/ping", ["-c", "3", "-t", "4", gateway]))
        }
        // Both of these come back empty from an ordinary process on this
        // system -- exit 0, no bytes -- while working fine from a shell, so
        // treat them as a bonus rather than a source. The probes above answer
        // the same questions without them.
        out += section("ARP table", run("/usr/sbin/arp", ["-an"]))

        out += section("Interfaces", run("/sbin/ifconfig", ["en0"]))
        out += section("IPv4 routes", run("/usr/sbin/netstat", ["-rn", "-f", "inet"]))
        out += section("DNS configuration", run("/usr/sbin/scutil", ["--dns"]))
        out += section("Resolve www.apple.com", run("/usr/bin/dig", ["+time=3", "+tries=1", "+short", "www.apple.com"]))
        out += section("Resolve direct via 1.1.1.1", run("/usr/bin/dig", ["+time=3", "+tries=1", "+short", "@1.1.1.1", "www.apple.com"]))
        // Sockets stuck in SYN_SENT would be the signature of a handshake
        // that leaves and never comes back. See the note above: this is
        // often empty, and an empty section here means nothing either way.
        out += section("TCP sockets", run("/usr/sbin/netstat", ["-an", "-p", "tcp"], lineLimit: 40))
        out += section("Wi-Fi", run("/usr/sbin/system_profiler", ["SPAirPortDataType"], lineLimit: 40, timeout: 15))
        out += section("Network filters", NetworkFilters.current().map {
            "  \($0.name) — \($0.status)"
        }.joined(separator: "\n"))

        return out
    }

    private static func section(_ title: String, _ body: String) -> String {
        "\n=== \(title) ===\n\(body.isEmpty ? "(no output)" : body)\n"
    }

    private static func mark(_ ok: Bool) -> String { ok ? "ok" : "FAILED" }

    // MARK: - Probes

    private static func describe(_ outcome: (ok: Bool, milliseconds: Double)) -> String {
        outcome.ok
            ? String(format: "connected in %.0f ms", outcome.milliseconds)
            // The timing matters as much as the verdict: an immediate refusal
            // is something local, a slow one is the network giving up.
            : String(format: "FAILED after %.0f ms", outcome.milliseconds)
    }

    private static func tcpProbe(host: String, port: UInt16, timeout: TimeInterval = 5) -> (ok: Bool, milliseconds: Double) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        let started = Date()
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let resolved = info else {
            return (false, 0)
        }
        defer { freeaddrinfo(info) }

        let descriptor = socket(resolved.pointee.ai_family, resolved.pointee.ai_socktype, resolved.pointee.ai_protocol)
        guard descriptor >= 0 else { return (false, 0) }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)

        func elapsed() -> Double { -started.timeIntervalSinceNow * 1000 }

        if connect(descriptor, resolved.pointee.ai_addr, resolved.pointee.ai_addrlen) == 0 {
            return (true, elapsed())
        }
        guard errno == EINPROGRESS else { return (false, elapsed()) }
        var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return (false, elapsed()) }
        var failure: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 else { return (false, elapsed()) }
        return (failure == 0, elapsed())
    }

    private static func defaultGateway() -> String? {
        let routes = run("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        for line in routes.split(separator: "\n") where line.hasPrefix("default") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            if columns.count > 1 { return String(columns[1]) }
        }
        return nil
    }

    // MARK: - Running things

    /// Blocking, on purpose, on the queue above. Bounded so a wedged command
    /// cannot hold the snapshot open for ever -- which during a network
    /// failure is exactly what several of these would otherwise do.
    private static func run(
        _ path: String, _ arguments: [String], lineLimit: Int? = nil, timeout: TimeInterval = 8
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        guard (try? process.run()) != nil else { return "(could not run \(path))" }

        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        watchdog.cancel()

        // Leniently: some of these emit bytes that aren't valid UTF-8, and a
        // nil string would silently drop the whole section.
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let lineLimit {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > lineLimit {
                text = lines.prefix(lineLimit).joined(separator: "\n") + "\n… (\(lines.count - lineLimit) more lines)"
            }
        }
        return text
    }

    private static func uptimeDescription() -> String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return "unknown" }
        let seconds = Date().timeIntervalSince1970 - Double(boot.tv_sec)
        return String(format: "%.1f hours since boot", seconds / 3600)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Keep the last ten. A folder that grows without limit is its own small
    /// bug, and nobody reads the eleventh.
    private static func prune() {
        let extra = existingSnapshots.dropFirst(10)
        for url in extra { try? FileManager.default.removeItem(at: url) }
    }
}
