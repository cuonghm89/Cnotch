//
//  NetworkSpeedTest.swift
//  CNotch
//
//  How fast the connection actually is, to somewhere near and somewhere far.
//

import Darwin
import Defaults
import Foundation
import os

/// A speed check that answers one question: is the connection slow, and is it
/// slow only on the way out of the country?
///
/// It is not Ookla. There is no server selection, no latency-under-load, no
/// figure to take to an ISP. What it does have is two targets measured the
/// same way, which is what makes the comparison mean anything -- a domestic
/// host and an international one, so "the internet is broken" can be told
/// apart from "the undersea route is congested" without opening a browser.
///
/// Sizing is adaptive rather than fixed. A fixed byte count either takes a
/// minute on a slow line or finishes before TCP has opened its window on a
/// fast one, so a short warm-up sets the size of the real run and every
/// connection spends about the same few seconds being measured.
@MainActor
final class NetworkSpeedTest: ObservableObject {
    static let shared = NetworkSpeedTest()

    struct Target {
        let name: String
        let host: String
        /// Builds a request for `bytes` bytes, offset so parallel streams do
        /// not fetch the same range twice.
        let request: (_ bytes: Int, _ offset: Int) -> URLRequest
    }

    struct Reading: Equatable {
        /// Milliseconds to open a TCP connection, best of several.
        var latency: Double?
        /// Megabits per second.
        var download: Double?
    }

    struct Result: Equatable {
        var domestic = Reading()
        var international = Reading()
        var measuredAt = Date()
    }

    @Published private(set) var lastResult: Result?
    @Published private(set) var isRunning = false
    /// What is being measured right now, for the panel to show.
    @Published private(set) var stage: String?

    /// A mirror rather than a speed-test server: Vietnam has no public
    /// speed-test endpoint that can be called without a licence, and a Linux
    /// mirror is both hosted here and built for bulk transfer. Range requests
    /// keep it to a few megabytes.
    private static let domestic = Target(
        name: "Vietnam",
        host: "mirror.bizflycloud.vn",
        request: { bytes, offset in
            var request = URLRequest(url: URL(string: "https://mirror.bizflycloud.vn/ubuntu/ls-lR.gz")!)
            request.setValue("bytes=\(offset)-\(offset + bytes - 1)", forHTTPHeaderField: "Range")
            return request
        }
    )

    private static let international = Target(
        name: "International",
        host: "speed.cloudflare.com",
        request: { bytes, _ in
            URLRequest(url: URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)")!)
        }
    )

    /// The mirror's file is around 38 MB; stay well inside it.
    private static let domesticFileSize = 30_000_000
    private static let streams = 4
    /// How long each direction is measured for, after the ramp-up below.
    private static let budget = 5.0
    /// Ignored at the start of every run. TCP opens its congestion window
    /// gradually, so the first second of any transfer is slower than the line
    /// really is -- measuring it drags the answer down by a third on a short
    /// run, which is exactly what the first version of this did.
    private static let rampUp = 1.0

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        stage = nil
        defer {
            isRunning = false
            stage = nil
        }

        var result = Result()

        stage = "Measuring latency"
        result.domestic.latency = await Self.latency(to: Self.domestic.host)
        result.international.latency = await Self.latency(to: Self.international.host)

        stage = "Testing local speed"
        result.domestic.download = await Self.download(from: Self.domestic, limit: Self.domesticFileSize)

        stage = "Testing international speed"
        result.international.download = await Self.download(from: Self.international, limit: .max)

        result.measuredAt = Date()
        lastResult = result
    }

    // MARK: - Latency

    /// Best of three TCP handshakes. Best rather than mean, because a single
    /// scheduling hiccup on this machine would otherwise read as a slow
    /// network.
    private static func latency(to host: String) async -> Double? {
        await Task.detached(priority: .userInitiated) {
            var best: Double?
            for _ in 0..<3 {
                if let sample = connectTime(host: host, port: 443, timeout: 3) {
                    best = min(best ?? .greatestFiniteMagnitude, sample)
                }
            }
            return best
        }.value
    }

    /// A POSIX connect, timed. `URLSession` would fold DNS, TLS and HTTP into
    /// the same number, and the handshake on its own is what "latency" means
    /// here.
    private nonisolated static func connectTime(host: String, port: UInt16, timeout: TimeInterval) -> Double? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let resolved = info else { return nil }
        defer { freeaddrinfo(info) }

        let descriptor = socket(resolved.pointee.ai_family, resolved.pointee.ai_socktype, resolved.pointee.ai_protocol)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL, 0) | O_NONBLOCK)

        let started = Date()
        if connect(descriptor, resolved.pointee.ai_addr, resolved.pointee.ai_addrlen) == 0 {
            return -started.timeIntervalSinceNow * 1000
        }
        guard errno == EINPROGRESS else { return nil }
        var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var failure: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else { return nil }
        return -started.timeIntervalSinceNow * 1000
    }

    // MARK: - Throughput

    /// Megabits per second, or nil if nothing arrived.
    ///
    /// Measured on a clock, not on a byte count. Asking for a fixed number of
    /// bytes means guessing the speed first, and guessing wrong either takes
    /// a minute on a slow line or stops before the line is up to speed.
    /// Instead: ask for far more than the budget can pull, stop when time is
    /// up, and divide.
    private static func download(from target: Target, limit: Int) async -> Double? {
        let meter = Meter(rampUp: rampUp)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = budget + 10
        let session = URLSession(configuration: configuration, delegate: meter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let perStream = min(40_000_000 / streams, max(limit / streams, 1_000_000))
        meter.begin()
        var tasks: [URLSessionDataTask] = []
        for index in 0..<streams {
            // Offsets wrap inside the file so parallel ranges stay valid.
            let offset = (index * perStream) % max(limit - perStream, 1)
            let task = session.dataTask(with: target.request(perStream, offset))
            tasks.append(task)
            task.resume()
        }

        try? await Task.sleep(for: .seconds(budget))
        tasks.forEach { $0.cancel() }

        guard let reading = meter.reading else { return nil }
        return Double(reading.bytes) * 8 / reading.seconds / 1_000_000
    }
}

/// Counts bytes as they land, so a run can be stopped on a clock rather than
/// at a byte count, and so the ramp-up can be left out of the arithmetic.
private final class Meter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var counted = 0
    private var settledAt: Date?
    private var settledBytes = 0
    private var started = Date()
    private let rampUp: TimeInterval

    init(rampUp: TimeInterval) { self.rampUp = rampUp }

    func begin() { started = Date() }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        defer { lock.unlock() }
        counted += data.count
        if settledAt == nil, -started.timeIntervalSinceNow >= rampUp {
            settledAt = Date()
            settledBytes = counted
        }
    }

    /// What arrived after the ramp-up -- or the whole run, when it was too
    /// short to have had one, which is better than reporting nothing.
    var reading: (bytes: Int, seconds: Double)? {
        lock.lock()
        defer { lock.unlock() }
        if let settledAt {
            let seconds = -settledAt.timeIntervalSinceNow
            let bytes = counted - settledBytes
            if bytes > 0, seconds > 0.3 { return (bytes, seconds) }
        }
        let seconds = -started.timeIntervalSinceNow
        return counted > 0 && seconds > 0 ? (counted, seconds) : nil
    }
}
