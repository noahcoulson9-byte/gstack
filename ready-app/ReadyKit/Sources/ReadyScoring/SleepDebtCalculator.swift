import Foundation

/// One night's sleep duration plus the next day's RHR deviation, used to decide whether the
/// night is "clean" (not visibly debt/illness impaired) for adaptive sleep-need estimation.
public struct SleepNeedCandidateNight: Sendable, Equatable {
    public let night: SleepNight
    /// Z-score of the RHR recorded the day after this night, vs the personal baseline.
    /// `nil` when RHR data is unavailable for that day — treated as "not elevated" rather
    /// than excluding the night, since missing data shouldn't bias the estimate.
    public let nextDayRestingHeartRateZScore: Double?

    public init(night: SleepNight, nextDayRestingHeartRateZScore: Double?) {
        self.night = night
        self.nextDayRestingHeartRateZScore = nextDayRestingHeartRateZScore
    }
}

/// Estimates personal sleep need and accumulates/decays sleep debt over the trailing week.
public struct SleepDebtCalculator: Sendable {
    public static let defaultSleepNeedMinutes = 480.0
    public static let minSleepNeedMinutes = 360.0
    public static let maxSleepNeedMinutes = 600.0
    public static let minimumCandidateNights = 10
    public static let elevatedRHRZScoreThreshold = 1.0

    public static let debtWindowDays = 7
    public static let maxDebtMinutes = 600.0
    /// Sleeping in repays accumulated debt at 50% efficiency — extra sleep is only partly credited.
    public static let repaymentEfficiency = 0.5

    public init() {}

    /// Adaptive sleep-need estimate: median total-asleep-minutes across "clean" nights in the
    /// trailing window (duration in [360,600] min, next-day RHR not elevated >1 stddev). Falls
    /// back to the 480-minute default when there isn't enough clean signal yet.
    public func estimateSleepNeedMinutes(candidateNights: [SleepNeedCandidateNight]) -> Double {
        let clean = candidateNights.filter { candidate in
            let total = candidate.night.totalAsleepMinutes
            guard total >= Self.minSleepNeedMinutes, total <= Self.maxSleepNeedMinutes else { return false }
            if let z = candidate.nextDayRestingHeartRateZScore, z > Self.elevatedRHRZScoreThreshold {
                return false
            }
            return true
        }

        guard clean.count >= Self.minimumCandidateNights else {
            return Self.defaultSleepNeedMinutes
        }

        let sorted = clean.map { $0.night.totalAsleepMinutes }.sorted()
        let median = Self.median(of: sorted)
        return min(max(median, Self.minSleepNeedMinutes), Self.maxSleepNeedMinutes)
    }

    /// Walks the trailing `debtWindowDays` nights in chronological order, accruing a deficit
    /// each night the user slept short of `sleepNeedMinutes` and repaying part of the debt
    /// (at `repaymentEfficiency`) on nights with surplus sleep. `nights` must be sorted oldest
    /// to newest and need not be contiguous — missing nights simply contribute no deficit/surplus.
    public func currentDebtMinutes(nights: [SleepNight], sleepNeedMinutes: Double) -> Double {
        var debt = 0.0
        for night in nights {
            let total = night.totalAsleepMinutes
            let surplus = max(total - sleepNeedMinutes, 0)
            let deficit = max(sleepNeedMinutes - total, 0)
            let repayment = min(debt, surplus * Self.repaymentEfficiency)
            debt = min(max(debt - repayment + deficit, 0), Self.maxDebtMinutes)
        }
        return debt
    }

    private static func median(of sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let mid = sortedValues.count / 2
        if sortedValues.count % 2 == 0 {
            return (sortedValues[mid - 1] + sortedValues[mid]) / 2
        }
        return sortedValues[mid]
    }
}
