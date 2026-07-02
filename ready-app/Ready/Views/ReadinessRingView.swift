import ReadyScoring
import SwiftUI

struct ReadinessRingView: View {
    let score: Int?
    let band: ReadinessBand?

    private var ringColor: Color {
        switch band {
        case .readyToTrain: return .green
        case .moderate: return .yellow
        case .recover: return .red
        case .none: return .gray
        }
    }

    private var progress: Double {
        guard let score else { return 0 }
        return Double(score) / 100
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(ringColor.opacity(0.15), lineWidth: 18)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: progress)
            VStack(spacing: 4) {
                Text(score.map(String.init) ?? "--")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(band?.displayName ?? "Insufficient Data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 220, height: 220)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Readiness score \(score.map(String.init) ?? "unavailable"), \(band?.displayName ?? "insufficient data")")
    }
}
