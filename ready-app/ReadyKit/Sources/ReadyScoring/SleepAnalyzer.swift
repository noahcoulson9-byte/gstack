import Foundation

/// Aggregates raw sleep-stage durations into a per-night sleep sub-score (0-100): duration vs
/// need (70 pts) plus stage-quality mix (30 pts).
public struct SleepAnalyzer: Sendable {
    /// Duration ratio above this is capped — extra sleep beyond 110% of need doesn't add more points.
    public static let durationRatioCap = 1.1
    public static let durationPoints = 70.0
    public static let qualityPoints = 30.0

    /// Calibrated so a "typical good night" stage mix (roughly even deep/REM/core split weighted
    /// toward deep+REM) lands around 30/30 quality points.
    public static let referenceQualityMix = 0.5

    public static let deepWeight = 1.0
    public static let remWeight = 0.8
    public static let coreWeight = 0.5

    public init() {}

    public func sleepScore(for night: SleepNight, sleepNeedMinutes: Double) -> Double? {
        let totalAsleep = night.totalAsleepMinutes
        guard totalAsleep > 0, sleepNeedMinutes > 0 else { return nil }

        let durationRatio = min(totalAsleep / sleepNeedMinutes, Self.durationRatioCap)
        let durationScore = durationRatio * Self.durationPoints

        let weightedStageMix = (
            night.deepMinutes * Self.deepWeight +
            night.remMinutes * Self.remWeight +
            night.coreMinutes * Self.coreWeight
        ) / totalAsleep
        let qualityScore = Self.qualityPoints * (weightedStageMix / Self.referenceQualityMix)

        return min(max(durationScore + qualityScore, 0), 100)
    }
}
