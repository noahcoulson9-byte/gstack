import Foundation

/// Per-metric today/baseline pair fed into the scorer. `today` and `baseline` are both nil when
/// the metric has no data for the relevant window; the scorer drops missing metrics and
/// renormalizes the remaining weights rather than guessing.
public struct ReadinessMetricInput: Sendable, Equatable {
    public let today: Double?
    public let baseline: Baseline?

    public init(today: Double?, baseline: Baseline?) {
        self.today = today
        self.baseline = baseline
    }

    public static let missing = ReadinessMetricInput(today: nil, baseline: nil)
}

public struct ReadinessScoringInput: Sendable, Equatable {
    public let hrv: ReadinessMetricInput
    public let restingHeartRate: ReadinessMetricInput
    public let respiratoryRate: ReadinessMetricInput
    /// Pre-computed 0-100 sub-score from `SleepAnalyzer`.
    public let sleepScore: Double?
    /// Pre-computed 0-100 sub-score from `WorkoutLoadAnalyzer`, plus the raw ratio for display.
    public let acwrScore: Double?
    public let acwr: Double?

    public init(
        hrv: ReadinessMetricInput,
        restingHeartRate: ReadinessMetricInput,
        respiratoryRate: ReadinessMetricInput,
        sleepScore: Double?,
        acwrScore: Double?,
        acwr: Double?
    ) {
        self.hrv = hrv
        self.restingHeartRate = restingHeartRate
        self.respiratoryRate = respiratoryRate
        self.sleepScore = sleepScore
        self.acwrScore = acwrScore
        self.acwr = acwr
    }
}

/// Combines per-metric baseline deviations, sleep quality, and training load into the final
/// 0-100 readiness score and recommendation band.
public struct ReadinessScorer: Sendable {
    public static let hrvFloor = 2.0
    public static let restingHeartRateFloor = 1.0
    public static let respiratoryRateFloor = 0.3

    public static let hrvClampRange = -3.0...1.5
    public static let inverseClampRange = -3.0...1.5
    public static let respClampRange = -2.0...1.0

    /// z=0 maps to subscore 50; the multiplier spreads the clamped contribution range
    /// (roughly -3...+1.5) across most of the 0-100 scale without clipping at the extremes.
    public static let subscoreSlope = 16.7

    public static let weightHRV = 0.35
    public static let weightRestingHeartRate = 0.20
    public static let weightSleep = 0.25
    public static let weightACWR = 0.15
    public static let weightRespiratoryRate = 0.05

    public static let minimumAvailableMetrics = 2

    public static let readyToTrainThreshold = 75
    public static let moderateThreshold = 50

    public init() {}

    public func score(_ input: ReadinessScoringInput) -> ReadinessResult {
        var weightedSubscores: [(weight: Double, subscore: Double)] = []
        var contributions: [MetricContribution] = []

        if let hrvSubscore = subscore(for: input.hrv, floor: Self.hrvFloor, clampRange: Self.hrvClampRange, invertSign: false) {
            weightedSubscores.append((Self.weightHRV, hrvSubscore))
        }
        if let today = input.hrv.today {
            contributions.append(contribution(id: "hrv", label: "HRV", today: today, baseline: input.hrv.baseline, favorableUp: true))
        }

        if let rhrSubscore = subscore(for: input.restingHeartRate, floor: Self.restingHeartRateFloor, clampRange: Self.inverseClampRange, invertSign: true) {
            weightedSubscores.append((Self.weightRestingHeartRate, rhrSubscore))
        }
        if let today = input.restingHeartRate.today {
            contributions.append(contribution(id: "rhr", label: "Resting Heart Rate", today: today, baseline: input.restingHeartRate.baseline, favorableUp: false))
        }

        if let respSubscore = subscore(for: input.respiratoryRate, floor: Self.respiratoryRateFloor, clampRange: Self.respClampRange, invertSign: true) {
            weightedSubscores.append((Self.weightRespiratoryRate, respSubscore))
        }
        if let today = input.respiratoryRate.today {
            contributions.append(contribution(id: "respiratoryRate", label: "Respiratory Rate", today: today, baseline: input.respiratoryRate.baseline, favorableUp: false))
        }

        if let sleepScore = input.sleepScore {
            weightedSubscores.append((Self.weightSleep, sleepScore))
        }

        if let acwrScore = input.acwrScore {
            weightedSubscores.append((Self.weightACWR, acwrScore))
        }

        guard weightedSubscores.count >= Self.minimumAvailableMetrics else {
            return ReadinessResult(score: nil, band: nil, insufficientData: true, contributions: contributions, acwr: input.acwr, sleepScore: input.sleepScore)
        }

        let totalWeight = weightedSubscores.reduce(0) { $0 + $1.weight }
        let weightedSum = weightedSubscores.reduce(0) { $0 + $1.weight * $1.subscore }
        let finalScore = min(max((weightedSum / totalWeight).rounded(), 0), 100)
        let band = self.band(forScore: Int(finalScore))

        return ReadinessResult(
            score: Int(finalScore),
            band: band,
            insufficientData: false,
            contributions: contributions,
            acwr: input.acwr,
            sleepScore: input.sleepScore
        )
    }

    public func band(forScore score: Int) -> ReadinessBand {
        if score >= Self.readyToTrainThreshold {
            return .readyToTrain
        } else if score >= Self.moderateThreshold {
            return .moderate
        } else {
            return .recover
        }
    }

    private func subscore(
        for metric: ReadinessMetricInput,
        floor: Double,
        clampRange: ClosedRange<Double>,
        invertSign: Bool
    ) -> Double? {
        guard let today = metric.today, let baseline = metric.baseline else { return nil }
        let z = baseline.zScore(today: today, floor: floor)
        let signed = invertSign ? -z : z
        let clamped = min(max(signed, clampRange.lowerBound), clampRange.upperBound)
        let subscore = 50 + clamped * Self.subscoreSlope
        return min(max(subscore, 0), 100)
    }

    private func contribution(
        id: String,
        label: String,
        today: Double,
        baseline: Baseline?,
        favorableUp: Bool
    ) -> MetricContribution {
        let direction: MetricContribution.Direction
        if let baseline {
            let epsilon = max(baseline.stddev * 0.1, 0.01)
            if today > baseline.mean + epsilon {
                direction = .up
            } else if today < baseline.mean - epsilon {
                direction = .down
            } else {
                direction = .flat
            }
        } else {
            direction = .flat
        }

        return MetricContribution(
            id: id,
            label: label,
            todayValue: today,
            baselineMean: baseline?.mean,
            direction: direction,
            isFavorableDirectionUp: favorableUp
        )
    }
}
