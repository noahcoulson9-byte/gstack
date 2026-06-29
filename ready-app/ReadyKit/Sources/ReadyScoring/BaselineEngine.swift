import Foundation

/// Computes a rolling 14-28 day trailing baseline (mean + stddev) for a metric, and today's
/// z-score deviation from it. Pure math — no HealthKit dependency.
public struct BaselineEngine: Sendable {
    public static let baselineWindowDays = 28
    public static let minimumValidDays = 5

    public init() {}

    /// `samples` should already exclude today and be restricted to (at most) the trailing window;
    /// callers typically pass `Self.baselineWindowDays` of history. Returns nil if fewer than
    /// `minimumValidDays` distinct days have data — the caller should exclude the metric from
    /// scoring rather than compute a baseline off too few points.
    public func computeBaseline(from samples: [DailyMetricSample]) -> Baseline? {
        guard samples.count >= Self.minimumValidDays else { return nil }

        let values = samples.map(\.value)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { acc, v in acc + (v - mean) * (v - mean) } / Double(values.count)
        let stddev = variance.squareRoot()

        return Baseline(mean: mean, stddev: stddev, sampleCount: values.count)
    }

    /// Filters `allSamples` to the trailing window ending the day before `referenceDay`, then
    /// computes the baseline. Convenience wrapper so callers don't have to pre-filter by hand.
    public func trailingBaseline(
        allSamples: [DailyMetricSample],
        referenceDay: Date,
        windowDays: Int = BaselineEngine.baselineWindowDays,
        calendar: Calendar = .current
    ) -> Baseline? {
        let startOfReferenceDay = calendar.startOfDay(for: referenceDay)
        guard let windowStart = calendar.date(byAdding: .day, value: -windowDays, to: startOfReferenceDay) else {
            return nil
        }

        let windowed = allSamples.filter { sample in
            let day = calendar.startOfDay(for: sample.day)
            return day >= windowStart && day < startOfReferenceDay
        }

        return computeBaseline(from: windowed)
    }
}
