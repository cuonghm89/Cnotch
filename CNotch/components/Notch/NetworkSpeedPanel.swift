import SwiftUI

/// The speed measurement, on its own.
///
/// It began life inside the diagnosis panel and did not belong there: that
/// panel answers "is anything broken", layer by layer, in a second. This one
/// takes ten seconds and answers "how fast is it" -- a different question,
/// asked at a different moment, and squeezing it underneath made both harder
/// to read.
struct NetworkSpeedPanel: View {
    @ObservedObject private var test = NetworkSpeedTest.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let result = test.lastResult {
                VStack(alignment: .leading, spacing: 14) {
                    reading("Domestic", result.domestic, scale: scale(for: result))
                    reading("International", result.international, scale: scale(for: result))
                }

                if let note = comparison(result) {
                    Text(LocalizedStringKey(note))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        // Both of these: the frame stops the Text asking for
                        // its full single-line width, and fixedSize stops the
                        // parent squeezing it back. Without the pair it
                        // truncated to one line with an ellipsis.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 4) {
                    Text("Measured at")
                    Text(result.measuredAt, style: .time)
                }
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            } else if !test.isRunning {
                Text("Compares a nearby server with one abroad, so a slow connection can be told apart from a congested international route.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await test.run() }
            } label: {
                Text(test.lastResult == nil ? "Measure speed" : "Measure again")
                    .frame(maxWidth: .infinity)
            }
            // Prominent on purpose: a plain button on this dark panel reads
            // as a label, and the only thing to do here is press it.
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(test.isRunning)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    @ViewBuilder
    private var header: some View {
        if test.isRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringKey(test.stage ?? "Measuring"))
                    .font(.headline)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .foregroundStyle(.secondary)
                Text("Network Speed").font(.headline)
            }
        }
    }

    /// One row: where, how fast, and a bar drawn against whichever of the two
    /// was faster -- the comparison is the whole point, so the bars are
    /// relative to each other rather than to some arbitrary "fast".
    private func reading(
        _ label: LocalizedStringKey, _ reading: NetworkSpeedTest.Reading, scale: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let latency = reading.latency {
                    Text(verbatim: String(format: "%.0f ms", latency))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let download = reading.download {
                    Text(verbatim: String(format: "%.1f", download))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(verbatim: "Mbps")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Couldn't measure")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * fraction(reading, scale: scale))
                }
            }
            .frame(height: 5)
        }
    }

    private func fraction(_ reading: NetworkSpeedTest.Reading, scale: Double) -> Double {
        guard let download = reading.download, scale > 0 else { return 0 }
        return min(max(download / scale, 0.02), 1)
    }

    private func scale(for result: NetworkSpeedTest.Result) -> Double {
        max(result.domestic.download ?? 0, result.international.download ?? 0)
    }

    /// The sentence the numbers are for. Nobody wants two figures; they want
    /// to know which side of the country the problem is on.
    private func comparison(_ result: NetworkSpeedTest.Result) -> String? {
        guard let domestic = result.domestic.download,
              let international = result.international.download,
              domestic > 0, international > 0
        else { return nil }

        // Anything inside a quarter is noise on a shared line, not a finding.
        let ratio = domestic / international
        if ratio > 1.5 {
            return "The international route is the slower half."
        }
        if ratio < 0.67 {
            return "The local route is the slower half, which is unusual — worth checking Wi-Fi and the router."
        }
        return "Both directions are about the same, so the limit is the connection itself rather than the route."
    }
}
