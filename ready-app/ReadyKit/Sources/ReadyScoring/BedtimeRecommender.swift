import Foundation

/// Combines target wake time, sleep-need estimate, and current sleep debt into tonight's
/// recommended bedtime.
public struct BedtimeRecommender: Sendable {
    /// Repay up to 30% of accumulated debt tonight, capped at sleeping 60 minutes earlier than need alone would suggest.
    public static let debtRepaymentFraction = 0.3
    public static let maxDebtAdjustmentMinutes = 60.0
    public static let defaultSleepOnsetLatencyMinutes = 15.0

    public init() {}

    /// `targetWakeTime` should be a `Date` representing tomorrow's intended wake moment (same
    /// calendar semantics as `sleepNeedMinutes`/`debtMinutes`, both in minutes).
    public func recommendedBedtime(
        targetWakeTime: Date,
        sleepNeedMinutes: Double,
        debtMinutes: Double,
        sleepOnsetLatencyMinutes: Double = BedtimeRecommender.defaultSleepOnsetLatencyMinutes
    ) -> Date {
        let debtAdjustment = min(debtMinutes * Self.debtRepaymentFraction, Self.maxDebtAdjustmentMinutes)
        let targetSleepDuration = sleepNeedMinutes + debtAdjustment
        let totalMinutesBeforeWake = targetSleepDuration + sleepOnsetLatencyMinutes
        return targetWakeTime.addingTimeInterval(-totalMinutesBeforeWake * 60)
    }
}
