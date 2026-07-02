import SwiftUI

struct BedtimeCardView: View {
    let bedtime: Date?

    private var formatted: String {
        guard let bedtime else { return "--:--" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: bedtime)
    }

    var body: some View {
        HStack {
            Image(systemName: "moon.stars.fill")
                .foregroundStyle(.indigo)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recommended Bedtime")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatted)
                    .font(.title2.bold())
            }
            Spacer()
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
