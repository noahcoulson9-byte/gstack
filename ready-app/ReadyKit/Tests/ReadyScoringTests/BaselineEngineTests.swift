import XCTest
@testable import ReadyScoring
import ReadyTestSupport

final class BaselineEngineTests: XCTestCase {
    let engine = BaselineEngine()

    func testReturnsNilBelowMinimumValidDays() {
        let samples = MockHealthData.dailySamples(offsets: [-1, -2, -3], value: { _ in 50 })
        XCTAssertNil(engine.computeBaseline(from: samples))
    }

    func testComputesMeanAndStddevForKnownValues() {
        let referenceDate = Date()
        let values: [Double] = [40, 50, 60, 50, 50]
        let samples = zip(Array((-5)...(-1)), values).map { offset, value in
            DailyMetricSample(day: MockHealthData.day(offset, referenceDate: referenceDate), value: value)
        }

        let baseline = engine.computeBaseline(from: samples)
        XCTAssertNotNil(baseline)
        XCTAssertEqual(baseline!.mean, 50, accuracy: 0.0001)
        // population variance = ((10^2)+(0)+(10^2)+0+0)/5 = 40 -> stddev = sqrt(40)
        XCTAssertEqual(baseline!.stddev, 40.0.squareRoot(), accuracy: 0.0001)
        XCTAssertEqual(baseline!.sampleCount, 5)
    }

    func testTrailingBaselineExcludesTodayAndOutOfWindowSamples() {
        let referenceDate = Date()
        var samples: [DailyMetricSample] = []
        // 30 days of history at value 100, plus today (offset 0) at a wildly different value.
        for offset in (-30)...(0) {
            let value = offset == 0 ? 9999.0 : 100.0
            samples.append(DailyMetricSample(day: MockHealthData.day(offset, referenceDate: referenceDate), value: value))
        }

        let baseline = engine.trailingBaseline(allSamples: samples, referenceDay: referenceDate, windowDays: 28, calendar: MockHealthData.calendar)
        XCTAssertNotNil(baseline)
        XCTAssertEqual(baseline!.mean, 100, accuracy: 0.0001)
        XCTAssertEqual(baseline!.sampleCount, 28)
    }

    func testZScoreUsesFloorToAvoidDivideByNearZero() {
        let baseline = Baseline(mean: 50, stddev: 0.0001, sampleCount: 10)
        let z = baseline.zScore(today: 52, floor: 2.0)
        XCTAssertEqual(z, 1.0, accuracy: 0.0001)
    }
}
