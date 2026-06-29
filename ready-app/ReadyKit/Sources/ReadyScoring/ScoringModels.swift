import Foundation

/// A single day's value for one HealthKit-derived metric (HRV, RHR, respiratory rate, active energy, ...).
/// Pure value type — no HealthKit dependency, so the scoring engine is testable without a device/simulator.
public struct DailyMetricSample: Sendable, Equatable {
    public let day: Date
    public let value: Double

    public init(day: Date, value: Double) {
        self.day = day
        self.value = value
    }
}

/// The set of stage durations (in minutes) and overall timing for one night of sleep.
public struct SleepNight: Sendable, Equatable {
    public let night: Date
    public let deepMinutes: Double
    public let remMinutes: Double
    public let coreMinutes: Double
    public let awakeMinutes: Double
    public let timeInBedMinutes: Double
    public let sleepingHeartRate: Double?
    public let inBedStart: Date
    public let inBedEnd: Date

    public init(
        night: Date,
        deepMinutes: Double,
        remMinutes: Double,
        coreMinutes: Double,
        awakeMinutes: Double,
        timeInBedMinutes: Double,
        sleepingHeartRate: Double?,
        inBedStart: Date,
        inBedEnd: Date
    ) {
        self.night = night
        self.deepMinutes = deepMinutes
        self.remMinutes = remMinutes
        self.coreMinutes = coreMinutes
        self.awakeMinutes = awakeMinutes
        self.timeInBedMinutes = timeInBedMinutes
        self.sleepingHeartRate = sleepingHeartRate
        self.inBedStart = inBedStart
        self.inBedEnd = inBedEnd
    }

    public var totalAsleepMinutes: Double { deepMinutes + remMinutes + coreMinutes }
}

/// Workout intensity bucket, derived from HKWorkoutActivityType + duration/energy, used to gate
/// activity suggestions ("don't prescribe intervals the day after a hard session").
public enum WorkoutIntensity: String, Sendable, Equatable {
    case low
    case moderate
    case high
}

public struct WorkoutRecord: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let activeEnergyKcal: Double
    public let intensity: WorkoutIntensity

    public init(start: Date, end: Date, activeEnergyKcal: Double, intensity: WorkoutIntensity) {
        self.start = start
        self.end = end
        self.activeEnergyKcal = activeEnergyKcal
        self.intensity = intensity
    }
}

/// Trailing-window baseline (mean + stddev) for a single metric, plus today's deviation from it.
public struct Baseline: Sendable, Equatable {
    public let mean: Double
    public let stddev: Double
    public let sampleCount: Int

    public init(mean: Double, stddev: Double, sampleCount: Int) {
        self.mean = mean
        self.stddev = stddev
        self.sampleCount = sampleCount
    }

    /// (today - mean) / max(stddev, floor). Caller supplies the floor since it's metric-specific.
    public func zScore(today: Double, floor: Double) -> Double {
        (today - mean) / Swift.max(stddev, floor)
    }
}

public enum ReadinessBand: String, Sendable, Equatable, CaseIterable {
    case readyToTrain
    case moderate
    case recover

    public var displayName: String {
        switch self {
        case .readyToTrain: return "Ready to Train"
        case .moderate: return "Moderate"
        case .recover: return "Recover"
        }
    }
}

/// Today vs baseline for one contributing metric, used to render the expandable metric cards.
public struct MetricContribution: Sendable, Equatable, Identifiable {
    public enum Direction: Sendable, Equatable {
        case up
        case down
        case flat
    }

    public let id: String
    public let label: String
    public let todayValue: Double?
    public let baselineMean: Double?
    public let direction: Direction
    public let isFavorableDirectionUp: Bool

    public init(
        id: String,
        label: String,
        todayValue: Double?,
        baselineMean: Double?,
        direction: Direction,
        isFavorableDirectionUp: Bool
    ) {
        self.id = id
        self.label = label
        self.todayValue = todayValue
        self.baselineMean = baselineMean
        self.direction = direction
        self.isFavorableDirectionUp = isFavorableDirectionUp
    }
}

/// Final output of the scoring pipeline for a single day, consumed by the UI layer.
public struct ReadinessResult: Sendable, Equatable {
    public let score: Int?
    public let band: ReadinessBand?
    public let insufficientData: Bool
    public let contributions: [MetricContribution]
    public let acwr: Double?
    public let sleepScore: Double?

    public init(
        score: Int?,
        band: ReadinessBand?,
        insufficientData: Bool,
        contributions: [MetricContribution],
        acwr: Double?,
        sleepScore: Double? = nil
    ) {
        self.score = score
        self.band = band
        self.insufficientData = insufficientData
        self.contributions = contributions
        self.acwr = acwr
        self.sleepScore = sleepScore
    }

    public static var insufficient: ReadinessResult {
        ReadinessResult(score: nil, band: nil, insufficientData: true, contributions: [], acwr: nil, sleepScore: nil)
    }
}

public struct ActivitySuggestion: Sendable, Equatable {
    public let title: String
    public let rationale: String

    public init(title: String, rationale: String) {
        self.title = title
        self.rationale = rationale
    }
}
