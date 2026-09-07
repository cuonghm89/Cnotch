import SwiftUI

/// Renders a live activity pushed by a third-party app or script (see
/// `CNotchViewCoordinator.setupExternalLiveActivityObserver`).
struct ExternalLiveActivityIndicator: View {
    let activity: ExpandedItem
    let physicalNotchWidth: CGFloat

    private var hasProgress: Bool {
        (0...1).contains(activity.value)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: activity.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 0) {
                    Text(activity.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !activity.subtitle.isEmpty {
                        Text(activity.subtitle)
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)

            Rectangle()
                .fill(.black)
                .frame(width: physicalNotchWidth)

            progressIndicator
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 12)
        }
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if hasProgress {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: activity.value)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 20, height: 20)
        }
    }
}
