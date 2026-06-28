import Foundation

/// Computes acute:chronic workload ratio (ACWR) from daily training-load samples (active energy
/// or workout-duration proxy), and inspects recent workout history for activity-suggestion gating.
public struct WorkoutLoadAnalyzer: Sendable {
    public static let acuteWindowDays = 7
    public static let chronicWindowDays = 28
    public static let minimumChronicDays = 14

    public static let sweetSpotLow = 0.8
    public static let sweetSpotHigh = 1.3

    public init() {}

    /// `dailyLoad` is one sample per day (active energy kcal, or workout-minutes fallback),
    /// trailing up to `chronicWindowDays`, excluding today. Returns nil if there isn't enough
    /// chronic-window history to trust the ratio.
    public func acwr(dailyLoad: [DailyMetricSample], referenceDay: Date, calendar: Calendar = .current) -> Double? {
        let startOfReferenceDay = calendar.startOfDay(for: referenceDay)

        guard let chronicStart = calendar.date(byAdding: .day, value: -Self.chronicWindowDays, to: startOfReferenceDay),
              let acuteStart = calendar.date(byAdding: .day, value: -Self.acuteWindowDays, to: startOfReferenceDay)
        else { return nil }

        let chronicSamples = dailyLoad.filter { sample in
            let day = calendar.startOfDay(for: sample.day)
            return day >= chronicStart && day < startOfReferenceDay
        }
        guard chronicSamples.count >= Self.minimumChronicDays else { return nil }

        let acuteSamples = chronicSamples.filter { calendar.startOfDay(for: $0.day) >= acuteStart }
        guard !acuteSamples.isEmpty else { return nil }

        let chronicMean = chronicSamples.map(\.value).reduce(0, +) / Double(chronicSamples.count)
        let acuteMean = acuteSamples.map(\.value).reduce(0, +) / Double(acuteSamples.count)

        return acuteMean / Swift.max(chronicMean, 1)
    }

    /// Maps ACWR onto a 0-100 sub-score that peaks in the sweet spot and penalizes both
    /// undertraining (below) and spike risk (above).
    public func score(forACWR acwr: Double) -> Double {
        let raw: Double
        if acwr < Self.sweetSpotLow {
            raw = 100 - (Self.sweetSpotLow - acwr) * 60
        } else if acwr > Self.sweetSpotHigh {
            raw = 100 - (acwr - Self.sweetSpotHigh) * 120
        } else {
            raw = 100
        }
        return min(max(raw, 0), 100)
    }

    public func hadWorkout(intensity: WorkoutIntensity, withinHours hours: Double, of referenceDate: Date, in workouts: [WorkoutRecord]) -> Bool {
        let cutoff = referenceDate.addingTimeInterval(-hours * 3600)
        return workouts.contains { $0.intensity == intensity && $0.end >= cutoff && $0.end <= referenceDate }
    }
}
