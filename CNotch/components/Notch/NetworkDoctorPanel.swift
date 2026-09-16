import SwiftUI

/// Per-layer result of a manual network check. The point is the *pattern*, not
/// any single row: TCP up + DNS up + TLS down is a filter problem, and that
/// combination is invisible in macOS's own Wi-Fi UI.
struct NetworkDoctorPanel: View {
    @ObservedObject private var doctor = NetworkDoctor.shared
    @State private var filters: [NetworkFilters.Filter] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let result = doctor.lastResult {
                VStack(alignment: .leading, spacing: 7) {
                    layerRow("Wi-Fi path", ok: result.hasPath)
                    layerRow("Routing (TCP to 1.1.1.1)", ok: result.tcpOK)
                    layerRow("DNS", ok: result.dnsOK)
                    layerRow("TLS through filters", ok: result.tlsOK)
                }

                Divider()

                Text(LocalizedStringKey(NetworkDoctor.subtitle(for: result.verdict)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !filters.isEmpty {
                    Divider()
                    Text("Network filters")
                        .font(.system(size: 11, weight: .semibold))
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(filters) { filter in
                            filterRow(filter)
                        }
                    }
                }
            } else if !doctor.isRunning {
                Text("No check run yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button {
                filters = NetworkFilters.current()
                Task { await doctor.runCheck() }
            } label: {
                Text(doctor.lastResult == nil ? "Run check" : "Run again")
            }
            .disabled(doctor.isRunning)
        }
        .padding(16)
        .frame(width: 290, alignment: .leading)
        .task {
            // Opening the panel is itself the request to check.
            filters = NetworkFilters.current()
            guard doctor.lastResult == nil, !doctor.isRunning else { return }
            await doctor.runCheck()
        }
    }

    private func filterRow(_ filter: NetworkFilters.Filter) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(filter.isOrphaned ? .red : (filter.isRunning ? .orange : .secondary))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                // A bundle identifier, so never localized.
                Text(verbatim: filter.id)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(LocalizedStringKey(statusText(for: filter)))
                    .font(.system(size: 10))
                    .foregroundStyle(filter.isOrphaned ? .red : .secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func statusText(for filter: NetworkFilters.Filter) -> String {
        if filter.isOrphaned { return "Enabled but not running" }
        return filter.isRunning ? "Filtering" : "Off"
    }

    @ViewBuilder
    private var header: some View {
        if doctor.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.headline)
            }
        } else if let result = doctor.lastResult {
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
                .font(.system(size: 11))
            Text(label)
                .font(.system(size: 11))
            Spacer(minLength: 8)
        }
    }
}
