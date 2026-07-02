import HealthKit
import ReadyScoring

/// Pure mapping functions: HealthKit sample types -> the plain (HealthKit-free) value types
/// consumed by `ReadyScoring`. Kept separate from `HealthKitManager` so they're testable by
/// constructing `HKQuantitySample`/`HKCategorySample` directly (works in-simulator, no Health
/// app UI needed) without exercising any real query machinery.
public enum HealthSampleMapper {
    /// Consecutive sleep-analysis samples with a gap larger than this are treated as separate
    /// sleep sessions (e.g. a daytime nap vs. the main overnight sleep).
    public static let sessionGapHours: TimeInterval = 1

    /// Groups raw sleep-analysis category samples into per-night `SleepNight` aggregates.
    /// Each contiguous run of samples (gap < `sessionGapHours`) becomes one night, attributed to
    /// the date the session ends (the wake date) — the common convention for "last night's sleep."
    public static func mapSleepSamples(
        _ samples: [HKCategorySample],
        heartRateSamples: [HKQuantitySample] = [],
        calendar: Calendar = .current
    ) -> [SleepNight] {
        guard !samples.isEmpty else { return [] }
        let sorted = samples.sorted { $0.startDate < $1.startDate }

        var sessions: [[HKCategorySample]] = []
        var current: [HKCategorySample] = [sorted[0]]
        for sample in sorted.dropFirst() {
            if let last = current.last, sample.startDate.timeIntervalSince(last.endDate) > sessionGapHours * 3600 {
                sessions.append(current)
                current = [sample]
            } else {
                current.append(sample)
            }
        }
        sessions.append(current)

        return sessions.compactMap { session in
            night(from: session, heartRateSamples: heartRateSamples, calendar: calendar)
        }
    }

    private static func night(
        from session: [HKCategorySample],
        heartRateSamples: [HKQuantitySample],
        calendar: Calendar
    ) -> SleepNight? {
        guard let inBedStart = session.map(\.startDate).min(),
              let inBedEnd = session.map(\.endDate).max()
        else { return nil }

        func minutes(forValues values: Set<Int>) -> Double {
            session
                .filter { values.contains($0.value) }
                .reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) / 60 }
        }

        let deepMinutes = minutes(forValues: [HKCategoryValueSleepAnalysis.asleepDeep.rawValue])
        let remMinutes = minutes(forValues: [HKCategoryValueSleepAnalysis.asleepREM.rawValue])
        let coreMinutes = minutes(forValues: [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
        ])
        let awakeMinutes = minutes(forValues: [HKCategoryValueSleepAnalysis.awake.rawValue])

        let asleepWindows = session.filter { sample in
            sample.value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                || sample.value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
                || sample.value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                || sample.value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
        }
        let sleepingHeartRate = averageHeartRate(during: asleepWindows, heartRateSamples: heartRateSamples)

        return SleepNight(
            night: calendar.startOfDay(for: inBedEnd),
            deepMinutes: deepMinutes,
            remMinutes: remMinutes,
            coreMinutes: coreMinutes,
            awakeMinutes: awakeMinutes,
            timeInBedMinutes: inBedEnd.timeIntervalSince(inBedStart) / 60,
            sleepingHeartRate: sleepingHeartRate,
            inBedStart: inBedStart,
            inBedEnd: inBedEnd
        )
    }

    /// Average of heart-rate samples whose start time falls inside any of the night's asleep
    /// windows — there's no dedicated "sleeping heart rate" HealthKit identifier, so this is the
    /// closest derivation from standard `heartRate` samples.
    private static func averageHeartRate(during windows: [HKCategorySample], heartRateSamples: [HKQuantitySample]) -> Double? {
        guard !windows.isEmpty, !heartRateSamples.isEmpty else { return nil }
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())

        let matching = heartRateSamples.filter { sample in
            windows.contains { window in
                sample.startDate >= window.startDate && sample.startDate < window.endDate
            }
        }
        guard !matching.isEmpty else { return nil }

        let total = matching.reduce(0.0) { $0 + $1.quantity.doubleValue(for: bpmUnit) }
        return total / Double(matching.count)
    }

    /// Maps `HKWorkout` records into `WorkoutRecord`, classifying intensity from average kcal/min
    /// — a simple, activity-type-agnostic proxy since HealthKit doesn't expose a normalized
    /// "intensity" field. High >= 8 kcal/min (e.g. intervals, running), moderate >= 4 (steady
    /// aerobic), else low (mobility, easy walk).
    public static func mapWorkouts(_ workouts: [HKWorkout]) -> [WorkoutRecord] {
        workouts.map { workout in
            // `statistics(for:)` only has data when the source app recorded it via HKWorkoutBuilder;
            // fall back to the deprecated aggregate property for older/legacy workout entries
            // that don't carry per-statistic breakdowns.
            let kcal = workout.statistics(for: ReadyHealthKitTypes.activeEnergyBurned)?
                .sumQuantity()?
                .doubleValue(for: .kilocalorie())
                ?? workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
                ?? 0
            let durationMinutes = max(workout.duration / 60, 1)
            let kcalPerMinute = kcal / durationMinutes

            let intensity: WorkoutIntensity
            if kcalPerMinute >= 8 {
                intensity = .high
            } else if kcalPerMinute >= 4 {
                intensity = .moderate
            } else {
                intensity = .low
            }

            return WorkoutRecord(start: workout.startDate, end: workout.endDate, activeEnergyKcal: kcal, intensity: intensity)
        }
    }
}
