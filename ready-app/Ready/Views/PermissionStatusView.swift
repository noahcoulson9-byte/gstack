import ReadyHealthKit
import SwiftUI

struct PermissionStatusView: View {
    let permissionState: HealthKitPermissionState
    let healthDataUnavailable: Bool

    private var message: String? {
        if healthDataUnavailable {
            return "This device doesn't support Health data."
        }
        switch permissionState {
        case .notRequestedYet:
            return "Requesting Health access\u{2026}"
        case .requestSheetDismissedWithoutGranting:
            return "Health access wasn't granted. Open Settings \u{2192} Health \u{2192} Data Access & Devices \u{2192} Ready to enable it."
        case .requestedPerTypeUnknown, .confirmedHasSamples, .confirmedNoSamples:
            return nil
        }
    }

    var body: some View {
        if let message {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
