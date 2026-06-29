import XCTest
@testable import ReadyScoring
import ReadyTestSupport

final class SleepAnalyzerTests: XCTestCase {
    let analyzer = SleepAnalyzer()

    func testFullDurationAtReferenceQualityMixScoresNearMaximum() {
        // 480 min asleep, need 480 -> duration ratio 1.0 -> 70 pts.
        // Stage mix: deep=120*1.0 + rem=120*0.8 + core=240*0.5 = 120+96+120 = 336; /480 = 0.7
        // qualityScore = 30 * (0.7/0.5) = 42, but quality is clamped via final min(...,100) only on total.
        let night = MockHealthData.sleepNight(offset: -1, deepMinutes: 120, remMinutes: 120, coreMinutes: 240)
        let score = analyzer.sleepScore(for: night, sleepNeedMinutes: 480)
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 100, accuracy: 0.01) // 70 + 42 clamped to 100
    }

    func testShortNightScoresLowerThanFullNight() {
        // total asleep = 240 vs need 480 -> duration ratio 0.5 -> durationScore = 35.
        // Stage mix: (60*1.0 + 60*0.8 + 120*0.5)/240 = 0.7 -> qualityScore = 30*(0.7/0.5) = 42.
        // Total = 77, strictly less than a full 480-min night with the same stage mix ratio (100, clamped).
        let night = MockHealthData.sleepNight(offset: -1, deepMinutes: 60, remMinutes: 60, coreMinutes: 120)
        let score = analyzer.sleepScore(for: night, sleepNeedMinutes: 480)
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 77, accuracy: 0.01)
    }

    func testZeroSleepReturnsNil() {
        let night = MockHealthData.sleepNight(offset: -1, deepMinutes: 0, remMinutes: 0, coreMinutes: 0, awakeMinutes: 0)
        XCTAssertNil(analyzer.sleepScore(for: night, sleepNeedMinutes: 480))
    }

    func testDurationRatioIsCappedSoOversleepingDoesNotExceedCapPoints() {
        // 700 min asleep vs 480 need -> ratio capped at 1.1 -> durationScore = 77 max contribution from duration.
        let night = MockHealthData.sleepNight(offset: -1, deepMinutes: 200, remMinutes: 200, coreMinutes: 300)
        let score = analyzer.sleepScore(for: night, sleepNeedMinutes: 480)
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 100, accuracy: 0.01) // still clamped at the 100 ceiling
    }
}
