import ReadyScoring
import SwiftUI

struct MetricCardView: View {
    let contribution: MetricContribution
    @State private var isExpanded = false

    private var arrowColor: Color {
        switch contribution.direction {
        case .flat: return .secondary
        case .up: return contribution.isFavorableDirectionUp ? .green : .red
        case .down: return contribution.isFavorableDirectionUp ? .red : .green
        }
    }

    private var arrowSymbol: String {
        switch contribution.direction {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .flat: return "minus"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(contribution.label)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    if let today = contribution.todayValue {
                        Image(systemName: arrowSymbol)
                            .foregroundStyle(arrowColor)
                        Text(String(format: "%.1f", today))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)

            if isExpanded, let baseline = contribution.baselineMean {
                Text("28-day baseline: \(String(format: "%.1f", baseline))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
