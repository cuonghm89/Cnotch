//
//  MediaChecker.swift
//  CNotch
//
//  Created by Alexander on 2025-07-26.
//

import Foundation

final class MediaChecker: Sendable {

    enum MediaCheckerError: Error {
        case missingResources
        case processExecutionFailed
        case timeout
    }

    func checkDeprecationStatus() async throws -> Bool {
        guard let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let nowPlayingTestClientPath = Bundle.main.url(forResource: "MediaRemoteAdapterTestClient", withExtension: nil)?.path,
              let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else {
            throw MediaCheckerError.missingResources
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, nowPlayingTestClientPath, "test"]

        // `terminationHandler` rather than `waitUntilExit()`.
        //
        // This runs at launch, and waiting on a subprocess parks whatever
        // thread it is called on until that subprocess exits -- here, a thread
        // of Swift concurrency's cooperative pool, which is only as wide as
        // the machine has cores and which every `async` call in the app
        // shares. Ten seconds of a perl interpreter that never answers used to
        // cost the whole app one of those threads. The handler costs none: the
        // kernel tells us when the process is gone.
        let exited: Bool = try await withCheckedThrowingContinuation { continuation in
            let resumed = ManagedAtomicFlag()
            process.terminationHandler = { _ in
                if resumed.claim() { continuation.resume(returning: true) }
            }
            do {
                try process.run()
            } catch {
                if resumed.claim() { continuation.resume(throwing: MediaCheckerError.processExecutionFailed) }
                return
            }
            // A perl script that hangs must not hang the check with it.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 10) {
                guard process.isRunning else { return }
                process.terminate()
                if resumed.claim() { continuation.resume(returning: false) }
            }
        }

        guard exited else { throw MediaCheckerError.timeout }
        return process.terminationStatus == 1
    }
}

/// A continuation must be resumed exactly once, and the timeout can race the
/// termination handler.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
