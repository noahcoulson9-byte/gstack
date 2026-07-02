import Foundation
import ReadyScoring

/// Synthetic data builders shared by ReadyScoringTests and ReadyHealthKitTests, so each test
/// doesn't hand-roll its own date arithmetic.
public enum MockHealthData {
    public static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    public static func day(_ offsetFromToday: Int, referenceDate: Date = Date()) -> Date {
        calendar.date(byAdding: .day, value: offsetFromToday, to: calendar.startOfDay(for: referenceDate))!
    }

    /// `offsets` are day offsets relative to `referenceDate` (e.g. -1...-28 for a trailing baseline window).
    public static func dailySamples(
        offsets: [Int],
        value: (Int) -> Double,
        referenceDate: Date = Date()
    ) -> [DailyMetricSample] {
        offsets.map { offset in
            DailyMetricSample(day: day(offset, referenceDate: referenceDate), value: value(offset))
        }
    }

    /// A stable 28-day trailing series with low variance, useful as a "normal baseline" fixture.
    public static func stableSeries(
        mean: Double,
        stddev: Double,
        days: Int = 28,
        referenceDate: Date = Date(),
        seed: Int = 0
    ) -> [DailyMetricSample] {
        dailySamples(offsets: Array((-days)...(-1)), value: { offset in
            // Deterministic pseudo-noise so tests are reproducible without a real RNG dependency.
            let noise = Double((offset * 31 + seed * 17) % 11) / 10.0 - 0.5
            return mean + noise * stddev
        }, referenceDate: referenceDate)
    }

    public static func sleepNight(
        offset: Int,
        deepMinutes: Double,
        remMinutes: Double,
        coreMinutes: Double,
        awakeMinutes: Double = 10,
        sleepingHeartRate: Double? = 52,
        referenceDate: Date = Date()
    ) -> SleepNight {
        let night = day(offset, referenceDate: referenceDate)
        let inBedStart = night.addingTimeInterval(-2 * 3600)
        let total = deepMinutes + remMinutes + coreMinutes + awakeMinutes
        let inBedEnd = inBedStart.addingTimeInterval(total * 60)
        return SleepNight(
            night: night,
            deepMinutes: deepMinutes,
            remMinutes: remMinutes,
            coreMinutes: coreMinutes,
            awakeMinutes: awakeMinutes,
            timeInBedMinutes: total,
            sleepingHeartRate: sleepingHeartRate,
            inBedStart: inBedStart,
            inBedEnd: inBedEnd
        )
    }

    public static func workout(
        offsetDays: Int,
        durationHours: Double = 1,
        activeEnergyKcal: Double = 500,
        intensity: WorkoutIntensity = .high,
        referenceDate: Date = Date()
    ) -> WorkoutRecord {
        let start = day(offsetDays, referenceDate: referenceDate)
        let end = start.addingTimeInterval(durationHours * 3600)
        return WorkoutRecord(start: start, end: end, activeEnergyKcal: activeEnergyKcal, intensity: intensity)
    }
}
