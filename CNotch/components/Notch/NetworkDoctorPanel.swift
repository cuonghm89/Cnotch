import SwiftUI

/// Per-layer result of a manual network check. The point is the *pattern*, not
/// any single row: TCP up + DNS up + TLS down is a filter problem, and that
/// combination is invisible in macOS's own Wi-Fi UI.
struct NetworkDoctorPanel: View {
    @StateObject private var doctor = NetworkDoctor.shared
    @State private var result: NetworkDoctor.Result?
    @State private var filters: [NetworkFilters.Filter] = []
    @State private var snapshots: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let result {
                VStack(alignment: .leading, spacing: 10) {
                    layerRow("Wi-Fi path", ok: result.hasPath)
                    layerRow("Routing (TCP)", ok: result.tcpOK)
                    if result.tcpOK, !result.tcpInternationalOK {
                        // Green above, because packets are moving; this is
                        // the part that green cannot say on its own.
                        Text("Only the domestic route answered — international is unreachable.")
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.leading)
                            .lineLimit(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 23)
                    }
                    layerRow("DNS", ok: result.dnsOK)
                    layerRow("TLS handshake", ok: result.tlsOK)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(NetworkDoctor.subtitle(for: result.verdict)))
                        .font(.system(size: 15))
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        // The pair, not just fixedSize: without the frame the
                        // Text asks for its whole width on one line and is
                        // then truncated instead of wrapped.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)

                    // When, so a result can never pass for current again.
                    HStack(spacing: 4) {
                        Text("Checked at")
                        Text(result.checkedAt, style: .time)
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                }

                if !filters.isEmpty {
                    Divider()
                    Text("Network filters")
                        .font(.system(size: 15, weight: .semibold))
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(filters) { filter in
                            filterRow(filter)
                        }
                    }
                }
            } else if !doctor.isRunning {
                Text("No check run yet.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            if !snapshots.isEmpty {
                Divider()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([snapshots[0]])
                } label: {
                    Label("Show saved diagnostics (\(snapshots.count))", systemImage: "folder")
                        .font(.system(size: 14))
                }
                .buttonStyle(.link)
            }

            Button {
                Task { filters = await Self.currentFilters() }
                Task { result = await doctor.runCheck() }
            } label: {
                Text(result == nil ? "Run check" : "Run again")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(doctor.isRunning)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .task {
            // Opening the panel is itself the request to check, every time.
            // Skipping when a result already existed meant the panel showed
            // whatever the last run found -- a red result captured during an
            // outage stayed on screen long after the network recovered, with
            // nothing to say it was an old one.
            filters = await Self.currentFilters()
            snapshots = NetworkWakeSnapshot.existingSnapshots
            guard !doctor.isRunning else { return }
            result = await doctor.runCheck()
        }
    }

    /// The scan lists every app bundle, reads each .appex's Info.plist and
    /// walks the path of every running process -- 70ms here and it grows with
    /// how much is installed, so it stays off the main actor.
    private static func currentFilters() async -> [NetworkFilters.Filter] {
        await Task.detached(priority: .utility) { NetworkFilters.current() }.value
    }

    private func filterRow(_ filter: NetworkFilters.Filter) -> some View {
        HStack(spacing: 8) {
            // The same marks as the four rows above, at the same size: a
            // coloured dot said the same thing in a different alphabet, and
            // the panel asks the reader to compare the two halves.
            Image(systemName: symbol(for: filter.status))
                .foregroundStyle(color(for: filter.status))
                .font(.system(size: 15))
            // A vendor name, so never localized.
            Text(verbatim: filter.name)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 10)
            Text(LocalizedStringKey(statusText(for: filter.status)))
                .font(.system(size: 14))
                .foregroundStyle(filter.status == .orphaned ? .red : .secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    /// Green means the same here as it does on the rows above: working as it
    /// should. A filter that is switched on is not a fault, so red is kept for
    /// the one state that genuinely is wrong.
    private func color(for status: NetworkFilters.Status) -> Color {
        switch status {
        case .enabled: .green
        case .orphaned: .red
        case .off, .installed: .secondary
        }
    }

    /// A tick for working, a cross for the broken state, a dash for the two
    /// that are simply not running -- which are told apart by the words
    /// beside them, not by the mark.
    private func symbol(for status: NetworkFilters.Status) -> String {
        switch status {
        case .enabled: "checkmark.circle.fill"
        case .orphaned: "xmark.circle.fill"
        case .off, .installed: "minus.circle.fill"
        }
    }

    /// Deliberately never says "Filtering". An extension can declare more than
    /// one role -- Kaspersky's is both a network filter and an endpoint
    /// security extension -- and switching its network half off in its own app
    /// leaves it enabled with the process still up for the other half. macOS
    /// exposes no per-role state, so claiming it is filtering would be
    /// asserting more than is known.
    private func statusText(for status: NetworkFilters.Status) -> String {
        switch status {
        case .enabled: "Enabled"
        case .orphaned: "Enabled but not running"
        case .off: "Off"
        case .installed: "Installed, not running"
        }
    }

    @ViewBuilder
    private var header: some View {
        if doctor.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringKey(doctor.stage ?? "Checking…")).font(.headline)
            }
        } else if let result {
            HStack(spacing: 8) {
                Image(systemName: NetworkDoctor.icon(for: result.verdict))
                    .foregroundStyle(result.verdict == .healthy ? .green : .orange)
                Text(LocalizedStringKey(NetworkDoctor.title(for: result.verdict)))
                    .font(.headline)
            }
        } else {
            Text("Network Diagnosis").font(.headline)
        }
    }

    private func layerRow(_ label: LocalizedStringKey, ok: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
                .font(.system(size: 15))
            Text(label)
                .font(.system(size: 15))
            Spacer(minLength: 8)
        }
    }
}
