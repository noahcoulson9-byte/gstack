import ReadyScoring
import SwiftUI

struct ActivitySuggestionCardView: View {
    let suggestion: ActivitySuggestion?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Today's Activity")
                .font(.headline)
                .foregroundStyle(.secondary)
            if let suggestion {
                Text(suggestion.title)
                    .font(.title3.bold())
                Text(suggestion.rationale)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not enough data yet to suggest a session.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
