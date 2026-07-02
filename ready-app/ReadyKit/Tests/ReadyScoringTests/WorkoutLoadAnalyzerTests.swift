import XCTest
@testable import ReadyScoring
import ReadyTestSupport

final class WorkoutLoadAnalyzerTests: XCTestCase {
    let analyzer = WorkoutLoadAnalyzer()

    func testACWRReturnsNilWithFewerThanMinimumChronicDays() {
        let referenceDate = Date()
        let samples = MockHealthData.dailySamples(offsets: Array((-10)...(-1)), value: { _ in 400 }, referenceDate: referenceDate)
        XCTAssertNil(analyzer.acwr(dailyLoad: samples, referenceDay: referenceDate, calendar: MockHealthData.calendar))
    }

    func testACWRComputesAcuteOverChronicRatio() {
        let referenceDate = Date()
        var samples: [DailyMetricSample] = []
        // Chronic baseline (days -28..-8): 400 kcal/day. Acute window (days -7..-1): 800 kcal/day (load spike).
        for offset in (-28)...(-8) {
            samples.append(DailyMetricSample(day: MockHealthData.day(offset, referenceDate: referenceDate), value: 400))
        }
        for offset in (-7)...(-1) {
            samples.append(DailyMetricSample(day: MockHealthData.day(offset, referenceDate: referenceDate), value: 800))
        }

        let acwr = analyzer.acwr(dailyLoad: samples, referenceDay: referenceDate, calendar: MockHealthData.calendar)
        XCTAssertNotNil(acwr)
        // chronicMean = (21*400 + 7*800) / 28 = 500; acuteMean = 800; ratio = 1.6
        XCTAssertEqual(acwr!, 1.6, accuracy: 0.01)
    }

    func testScoreIsFlatHundredInSweetSpot() {
        XCTAssertEqual(analyzer.score(forACWR: 0.8), 100, accuracy: 0.0001)
        XCTAssertEqual(analyzer.score(forACWR: 1.0), 100, accuracy: 0.0001)
        XCTAssertEqual(analyzer.score(forACWR: 1.3), 100, accuracy: 0.0001)
    }

    func testScorePenalizesUndertrainingBelowSweetSpot() {
        // 100 - (0.8 - 0.6) * 60 = 88
        XCTAssertEqual(analyzer.score(forACWR: 0.6), 88, accuracy: 0.0001)
    }

    func testScorePenalizesSpikeAboveSweetSpot() {
        // 100 - (1.6 - 1.3) * 120 = 64
        XCTAssertEqual(analyzer.score(forACWR: 1.6), 64, accuracy: 0.0001)
    }

    func testScoreClampsAtZero() {
        XCTAssertEqual(analyzer.score(forACWR: 3.0), 0, accuracy: 0.0001)
    }

    func testHadWorkoutWithinWindowDetectsRecentHighIntensitySession() {
        // Fixed reference time (not wall-clock "now") so the 24h boundary math is deterministic
        // regardless of what time the test suite happens to run.
        let referenceDate = MockHealthData.day(0).addingTimeInterval(12 * 3600) // noon today
        let workout = MockHealthData.workout(offsetDays: 0, durationHours: 1, intensity: .high, referenceDate: referenceDate)
        // Workout ends at 1am today, 11 hours before noon — well inside a 24h window.
        XCTAssertTrue(analyzer.hadWorkout(intensity: .high, withinHours: 24, of: referenceDate, in: [workout]))
        XCTAssertFalse(analyzer.hadWorkout(intensity: .low, withinHours: 24, of: referenceDate, in: [workout]))
    }

    func testHadWorkoutExcludesSessionsOutsideWindow() {
        let referenceDate = MockHealthData.day(0).addingTimeInterval(12 * 3600)
        let workout = MockHealthData.workout(offsetDays: -5, durationHours: 1, intensity: .high, referenceDate: referenceDate)
        XCTAssertFalse(analyzer.hadWorkout(intensity: .high, withinHours: 24, of: referenceDate, in: [workout]))
    }
}
