import XCTest
@testable import ReadyScoring

final class BedtimeRecommenderTests: XCTestCase {
    let recommender = BedtimeRecommender()

    func testRecommendsBedtimeWithNoDebt() {
        let wake = Date(timeIntervalSince1970: 1_700_000_000) // arbitrary fixed instant
        let bedtime = recommender.recommendedBedtime(targetWakeTime: wake, sleepNeedMinutes: 480, debtMinutes: 0)
        // 480 min sleep + 15 min onset latency = 495 min before wake.
        let expected = wake.addingTimeInterval(-495 * 60)
        XCTAssertEqual(bedtime.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDebtPullsBedtimeEarlierUpToCap() {
        let wake = Date(timeIntervalSince1970: 1_700_000_000)
        // debt=100 -> adjustment = min(100*0.3, 60) = 30 min earlier.
        let bedtime = recommender.recommendedBedtime(targetWakeTime: wake, sleepNeedMinutes: 480, debtMinutes: 100)
        let expected = wake.addingTimeInterval(-(480 + 30 + 15) * 60)
        XCTAssertEqual(bedtime.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDebtAdjustmentIsCappedAtSixtyMinutes() {
        let wake = Date(timeIntervalSince1970: 1_700_000_000)
        // debt=600 -> raw adjustment would be 180, but capped at 60.
        let bedtime = recommender.recommendedBedtime(targetWakeTime: wake, sleepNeedMinutes: 480, debtMinutes: 600)
        let expected = wake.addingTimeInterval(-(480 + 60 + 15) * 60)
        XCTAssertEqual(bedtime.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001)
    }
}
