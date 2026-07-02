import ReadyHealthKit
import ReadyScoring
import SwiftUI

struct ReadinessView: View {
    @ObservedObject var viewModel: ReadinessViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    PermissionStatusView(
                        permissionState: viewModel.permissionState,
                        healthDataUnavailable: viewModel.healthDataUnavailable
                    )

                    ReadinessRingView(score: viewModel.result.score, band: viewModel.result.band)
                        .padding(.top, 8)

                    if viewModel.result.insufficientData {
                        Text("Not enough Health data yet to compute a readiness score. Keep wearing your Apple Watch and check back tomorrow.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    BedtimeCardView(bedtime: viewModel.recommendedBedtime)

                    ActivitySuggestionCardView(suggestion: viewModel.activitySuggestion)

                    if !viewModel.result.contributions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Today vs. Baseline")
                                .font(.headline)
                                .padding(.horizontal, 4)
                            ForEach(viewModel.result.contributions) { contribution in
                                MetricCardView(contribution: contribution)
                            }
                        }
                    }
                }
                .padding()
            }
            .refreshable {
                await viewModel.refresh()
            }
            .navigationTitle("Ready")
        }
    }
}
