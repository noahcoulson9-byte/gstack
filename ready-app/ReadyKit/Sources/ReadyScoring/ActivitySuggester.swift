import Foundation

/// Maps (band, ACWR, recent workout history) onto a specific session suggestion with a
/// one-line rationale naming the driving metric.
public struct ActivitySuggester: Sendable {
    public init() {}

    public func suggestion(
        band: ReadinessBand,
        acwr: Double?,
        hadHighIntensityWithin24h: Bool,
        hadHighIntensityWithin48h: Bool
    ) -> ActivitySuggestion {
        switch band {
        case .readyToTrain:
            if hadHighIntensityWithin24h {
                return ActivitySuggestion(
                    title: "Easy aerobic / active recovery",
                    rationale: "Your readiness is high, but you trained hard in the last 24 hours — let that adaptation finish before going hard again."
                )
            }
            if let acwr, acwr > WorkoutLoadAnalyzer.sweetSpotHigh {
                return ActivitySuggestion(
                    title: "Moderate steady-state",
                    rationale: "Readiness is high, but your training load has climbed fast recently — hold off on adding more intensity on top of it."
                )
            }
            return ActivitySuggestion(
                title: "Hard intervals or a long hard effort",
                rationale: "Your body is well recovered and your training load is in a healthy range — this is a good day to push."
            )

        case .moderate:
            if hadHighIntensityWithin48h {
                return ActivitySuggestion(
                    title: "Easy aerobic or rest",
                    rationale: "Readiness is moderate and you had a hard session within the last two days — give it more time before another hard effort."
                )
            }
            return ActivitySuggestion(
                title: "Moderate-intensity steady-state, skip intervals",
                rationale: "Readiness is moderate — a solid aerobic session is fine, but save intervals for a day your numbers look better."
            )

        case .recover:
            return ActivitySuggestion(
                title: "Rest, mobility, or a short easy walk",
                rationale: "Your recovery signals are below baseline today — prioritize rest so tomorrow's training counts for more."
            )
        }
    }
}
