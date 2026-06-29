import XCTest
import HealthKit
@testable import ReadyHealthKit
import ReadyScoring

final class HealthSampleMapperTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func categorySample(value: HKCategoryValueSleepAnalysis, start: Date, end: Date) -> HKCategorySample {
        HKCategorySample(type: ReadyHealthKitTypes.sleepAnalysis, value: value.rawValue, start: start, end: end)
    }

    func testMapsContiguousSamplesIntoOneNight() {
        let inBedStart = Date(timeIntervalSince1970: 1_700_000_000)
        let core = categorySample(value: .asleepCore, start: inBedStart, end: inBedStart.addingTimeInterval(4 * 3600))
        let deep = categorySample(value: .asleepDeep, start: inBedStart.addingTimeInterval(4 * 3600), end: inBedStart.addingTimeInterval(5 * 3600))
        let rem = categorySample(value: .asleepREM, start: inBedStart.addingTimeInterval(5 * 3600), end: inBedStart.addingTimeInterval(6 * 3600))
        let awake = categorySample(value: .awake, start: inBedStart.addingTimeInterval(6 * 3600), end: inBedStart.addingTimeInterval(6.2 * 3600))

        let nights = HealthSampleMapper.mapSleepSamples([core, deep, rem, awake], calendar: calendar)

        XCTAssertEqual(nights.count, 1)
        let night = nights[0]
        XCTAssertEqual(night.coreMinutes, 240, accuracy: 0.01)
        XCTAssertEqual(night.deepMinutes, 60, accuracy: 0.01)
        XCTAssertEqual(night.remMinutes, 60, accuracy: 0.01)
        XCTAssertEqual(night.awakeMinutes, 12, accuracy: 0.01)
    }

    func testSplitsSessionsSeparatedByLargeGapIntoSeparateNights() {
        let firstStart = Date(timeIntervalSince1970: 1_700_000_000)
        let firstNightSample = categorySample(value: .asleepCore, start: firstStart, end: firstStart.addingTimeInterval(6 * 3600))

        // A nap the following afternoon, well over an hour after the first session ended.
        let napStart = firstStart.addingTimeInterval(20 * 3600)
        let napSample = categorySample(value: .asleepCore, start: napStart, end: napStart.addingTimeInterval(1 * 3600))

        let nights = HealthSampleMapper.mapSleepSamples([firstNightSample, napSample], calendar: calendar)
        XCTAssertEqual(nights.count, 2)
    }

    func testDerivesSleepingHeartRateFromOverlappingHeartRateSamples() {
        let inBedStart = Date(timeIntervalSince1970: 1_700_000_000)
        let core = categorySample(value: .asleepCore, start: inBedStart, end: inBedStart.addingTimeInterval(4 * 3600))

        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let hr1 = HKQuantitySample(
            type: ReadyHealthKitTypes.heartRate,
            quantity: HKQuantity(unit: bpmUnit, doubleValue: 50),
            start: inBedStart.addingTimeInterval(3600),
            end: inBedStart.addingTimeInterval(3600)
        )
        let hr2 = HKQuantitySample(
            type: ReadyHealthKitTypes.heartRate,
            quantity: HKQuantity(unit: bpmUnit, doubleValue: 54),
            start: inBedStart.addingTimeInterval(7200),
            end: inBedStart.addingTimeInterval(7200)
        )
        // Daytime sample, outside the sleep window — must not be averaged in.
        let hrDaytime = HKQuantitySample(
            type: ReadyHealthKitTypes.heartRate,
            quantity: HKQuantity(unit: bpmUnit, doubleValue: 90),
            start: inBedStart.addingTimeInterval(20 * 3600),
            end: inBedStart.addingTimeInterval(20 * 3600)
        )

        let nights = HealthSampleMapper.mapSleepSamples([core], heartRateSamples: [hr1, hr2, hrDaytime], calendar: calendar)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].sleepingHeartRate ?? -1, 52, accuracy: 0.01)
    }

    func testMapWorkoutsClassifiesIntensityByEnergyPerMinute() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(3600) // 60 min

        let highIntensity = HKWorkout(
            activityType: .running,
            start: start,
            end: end,
            workoutEvents: nil,
            totalEnergyBurned: HKQuantity(unit: .kilocalorie(), doubleValue: 600), // 10 kcal/min
            totalDistance: nil,
            metadata: nil
        )
        let easy = HKWorkout(
            activityType: .walking,
            start: start,
            end: end,
            workoutEvents: nil,
            totalEnergyBurned: HKQuantity(unit: .kilocalorie(), doubleValue: 120), // 2 kcal/min
            totalDistance: nil,
            metadata: nil
        )

        let mapped = HealthSampleMapper.mapWorkouts([highIntensity, easy])
        XCTAssertEqual(mapped.count, 2)
        // These workouts were built via the deprecated totalEnergyBurned initializer (no
        // HKWorkoutBuilder), so mapWorkouts falls back to `workout.totalEnergyBurned` since
        // `statistics(for:)` returns nil for that construction path.
        XCTAssertEqual(mapped[0].intensity, .high)
        XCTAssertEqual(mapped[1].intensity, .low)
    }
}
