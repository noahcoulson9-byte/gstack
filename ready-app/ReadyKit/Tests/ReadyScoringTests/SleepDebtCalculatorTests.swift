import XCTest
@testable import ReadyScoring
import ReadyTestSupport

final class SleepDebtCalculatorTests: XCTestCase {
    let calculator = SleepDebtCalculator()

    func testEstimateFallsBackToDefaultWithFewerThanMinimumCandidateNights() {
        let referenceDate = Date()
        let nights = (1...5).map { i in
            SleepNeedCandidateNight(
                night: MockHealthData.sleepNight(offset: -i, deepMinutes: 90, remMinutes: 90, coreMinutes: 270, referenceDate: referenceDate),
                nextDayRestingHeartRateZScore: 0
            )
        }
        XCTAssertEqual(calculator.estimateSleepNeedMinutes(candidateNights: nights), SleepDebtCalculator.defaultSleepNeedMinutes)
    }

    func testEstimateUsesMedianOfCleanNightsWhenEnoughSignal() {
        let referenceDate = Date()
        // 12 clean nights all at 450 minutes total asleep.
        let nights = (1...12).map { i in
            SleepNeedCandidateNight(
                night: MockHealthData.sleepNight(offset: -i, deepMinutes: 80, remMinutes: 80, coreMinutes: 290, referenceDate: referenceDate),
                nextDayRestingHeartRateZScore: 0.2
            )
        }
        XCTAssertEqual(calculator.estimateSleepNeedMinutes(candidateNights: nights), 450, accuracy: 0.0001)
    }

    func testEstimateExcludesNightsWithElevatedNextDayRHR() {
        let referenceDate = Date()
        // 12 nights at 450 min, but 10 of them have an elevated next-day RHR -> only 2 clean nights -> falls back to default.
        var nights: [SleepNeedCandidateNight] = []
        for i in 1...12 {
            let z = i <= 10 ? 1.5 : 0.0
            nights.append(SleepNeedCandidateNight(
                night: MockHealthData.sleepNight(offset: -i, deepMinutes: 80, remMinutes: 80, coreMinutes: 290, referenceDate: referenceDate),
                nextDayRestingHeartRateZScore: z
            ))
        }
        XCTAssertEqual(calculator.estimateSleepNeedMinutes(candidateNights: nights), SleepDebtCalculator.defaultSleepNeedMinutes)
    }

    func testEstimateExcludesOutlierDurationNights() {
        let referenceDate = Date()
        // 12 nights, but all far outside [360,600] (e.g. 100 minutes — illness/nap) -> no clean nights -> default.
        let nights = (1...12).map { i in
            SleepNeedCandidateNight(
                night: MockHealthData.sleepNight(offset: -i, deepMinutes: 20, remMinutes: 20, coreMinutes: 60, referenceDate: referenceDate),
                nextDayRestingHeartRateZScore: 0
            )
        }
        XCTAssertEqual(calculator.estimateSleepNeedMinutes(candidateNights: nights), SleepDebtCalculator.defaultSleepNeedMinutes)
    }

    func testDebtAccruesAcrossDeficitNights() {
        let referenceDate = Date()
        let sleepNeed = 480.0
        // 3 consecutive nights at 420 minutes (60 min deficit each), no surplus nights.
        let nights = (1...3).reversed().map { i in
            MockHealthData.sleepNight(offset: -i, deepMinutes: 60, remMinutes: 60, coreMinutes: 300, referenceDate: referenceDate)
        }
        let debt = calculator.currentDebtMinutes(nights: nights, sleepNeedMinutes: sleepNeed)
        XCTAssertEqual(debt, 180, accuracy: 0.0001)
    }

    func testSurplusNightRepaysDebtAtHalfEfficiency() {
        let referenceDate = Date()
        let sleepNeed = 480.0
        // Night 1: 420 min (60 min deficit) -> debt = 60.
        // Night 2: 540 min (60 min surplus) -> repayment = min(60, 60*0.5) = 30 -> debt = 60 - 30 = 30.
        let nights = [
            MockHealthData.sleepNight(offset: -2, deepMinutes: 60, remMinutes: 60, coreMinutes: 300, referenceDate: referenceDate),
            MockHealthData.sleepNight(offset: -1, deepMinutes: 90, remMinutes: 90, coreMinutes: 360, referenceDate: referenceDate),
        ]
        let debt = calculator.currentDebtMinutes(nights: nights, sleepNeedMinutes: sleepNeed)
        XCTAssertEqual(debt, 30, accuracy: 0.0001)
    }

    func testDebtIsCappedAtMaximum() {
        let referenceDate = Date()
        let sleepNeed = 480.0
        // 30 nights of zero sleep would imply 14400 min of debt; must clamp to the 600-min cap.
        let nights = (1...30).map { i in
            MockHealthData.sleepNight(offset: -i, deepMinutes: 0, remMinutes: 0, coreMinutes: 0, awakeMinutes: 0, referenceDate: referenceDate)
        }
        let debt = calculator.currentDebtMinutes(nights: nights, sleepNeedMinutes: sleepNeed)
        XCTAssertEqual(debt, SleepDebtCalculator.maxDebtMinutes, accuracy: 0.0001)
    }
}
