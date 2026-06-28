import XCTest
@testable import ReadyScoring

final class ReadinessScorerTests: XCTestCase {
    let scorer = ReadinessScorer()

    func testInsufficientDataWhenFewerThanTwoMetricsAvailable() {
        let input = ReadinessScoringInput(
            hrv: .missing,
            restingHeartRate: .missing,
            respiratoryRate: .missing,
            sleepScore: 80,
            acwrScore: nil,
            acwr: nil
        )
        let result = scorer.score(input)
        XCTAssertTrue(result.insufficientData)
        XCTAssertNil(result.score)
        XCTAssertNil(result.band)
    }

    func testAllMetricsAtBaselineYieldsScoreAroundFifty() {
        let baselineHRV = Baseline(mean: 60, stddev: 5, sampleCount: 20)
        let baselineRHR = Baseline(mean: 55, stddev: 3, sampleCount: 20)
        let baselineResp = Baseline(mean: 14, stddev: 1, sampleCount: 20)

        let input = ReadinessScoringInput(
            hrv: ReadinessMetricInput(today: 60, baseline: baselineHRV),
            restingHeartRate: ReadinessMetricInput(today: 55, baseline: baselineRHR),
            respiratoryRate: ReadinessMetricInput(today: 14, baseline: baselineResp),
            sleepScore: 50,
            acwrScore: 50,
            acwr: 1.0
        )
        let result = scorer.score(input)
        XCTAssertFalse(result.insufficientData)
        // Every subscore is exactly 50 (z=0 everywhere, sleep/acwr fed in at 50) -> weighted average is 50.
        XCTAssertEqual(result.score, 50)
        XCTAssertEqual(result.band, .moderate)
    }

    func testBandBoundaryAtSeventyFiveIsReadyToTrain() {
        XCTAssertEqual(scorer.band(forScore: 75), .readyToTrain)
        XCTAssertEqual(scorer.band(forScore: 74), .moderate)
    }

    func testBandBoundaryAtFiftyIsModerate() {
        XCTAssertEqual(scorer.band(forScore: 50), .moderate)
        XCTAssertEqual(scorer.band(forScore: 49), .recover)
    }

    func testMissingMetricsRenormalizeRemainingWeights() {
        // Only HRV (z = +1, favorable) and sleep (90) available; RHR/resp/ACWR missing.
        let baselineHRV = Baseline(mean: 60, stddev: 5, sampleCount: 20)
        let input = ReadinessScoringInput(
            hrv: ReadinessMetricInput(today: 65, baseline: baselineHRV), // z = 1
            restingHeartRate: .missing,
            respiratoryRate: .missing,
            sleepScore: 90,
            acwrScore: nil,
            acwr: nil
        )
        let result = scorer.score(input)
        XCTAssertFalse(result.insufficientData)
        // hrvSubscore = 50 + 1*16.7 = 66.7; weights renormalize to hrv=0.35/0.60, sleep=0.25/0.60
        let expected = (0.35 * 66.7 + 0.25 * 90) / 0.60
        XCTAssertEqual(Double(result.score!), expected.rounded(), accuracy: 1.0)
    }

    func testHRVContributionDirectionUpWhenAboveBaseline() {
        let baselineHRV = Baseline(mean: 60, stddev: 5, sampleCount: 20)
        let baselineRHR = Baseline(mean: 55, stddev: 3, sampleCount: 20)
        let input = ReadinessScoringInput(
            hrv: ReadinessMetricInput(today: 70, baseline: baselineHRV),
            restingHeartRate: ReadinessMetricInput(today: 55, baseline: baselineRHR),
            respiratoryRate: .missing,
            sleepScore: nil,
            acwrScore: nil,
            acwr: nil
        )
        let result = scorer.score(input)
        let hrvContribution = result.contributions.first { $0.id == "hrv" }
        XCTAssertEqual(hrvContribution?.direction, .up)
        XCTAssertTrue(hrvContribution?.isFavorableDirectionUp ?? false)
    }

    func testRHRContributionDirectionDownIsFavorable() {
        let baselineRHR = Baseline(mean: 55, stddev: 3, sampleCount: 20)
        let baselineHRV = Baseline(mean: 60, stddev: 5, sampleCount: 20)
        let input = ReadinessScoringInput(
            hrv: ReadinessMetricInput(today: 60, baseline: baselineHRV),
            restingHeartRate: ReadinessMetricInput(today: 50, baseline: baselineRHR),
            respiratoryRate: .missing,
            sleepScore: nil,
            acwrScore: nil,
            acwr: nil
        )
        let result = scorer.score(input)
        let rhrContribution = result.contributions.first { $0.id == "rhr" }
        XCTAssertEqual(rhrContribution?.direction, .down)
        XCTAssertFalse(rhrContribution?.isFavorableDirectionUp ?? true)
    }
}
