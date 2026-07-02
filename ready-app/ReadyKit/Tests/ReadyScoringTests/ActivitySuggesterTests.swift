import XCTest
@testable import ReadyScoring

final class ActivitySuggesterTests: XCTestCase {
    let suggester = ActivitySuggester()

    func testReadyToTrainWithNoRecentHardSessionSuggestsHardEffort() {
        let suggestion = suggester.suggestion(band: .readyToTrain, acwr: 1.0, hadHighIntensityWithin24h: false, hadHighIntensityWithin48h: false)
        XCTAssertEqual(suggestion.title, "Hard intervals or a long hard effort")
    }

    func testReadyToTrainButHardYesterdaySuggestsActiveRecovery() {
        let suggestion = suggester.suggestion(band: .readyToTrain, acwr: 1.0, hadHighIntensityWithin24h: true, hadHighIntensityWithin48h: true)
        XCTAssertEqual(suggestion.title, "Easy aerobic / active recovery")
    }

    func testReadyToTrainWithHighACWRSuggestsModerate() {
        let suggestion = suggester.suggestion(band: .readyToTrain, acwr: 1.6, hadHighIntensityWithin24h: false, hadHighIntensityWithin48h: false)
        XCTAssertEqual(suggestion.title, "Moderate steady-state")
    }

    func testModerateWithRecentHardSessionSuggestsEasyOrRest() {
        let suggestion = suggester.suggestion(band: .moderate, acwr: 1.0, hadHighIntensityWithin24h: false, hadHighIntensityWithin48h: true)
        XCTAssertEqual(suggestion.title, "Easy aerobic or rest")
    }

    func testModerateWithoutRecentHardSessionSuggestsSteadyState() {
        let suggestion = suggester.suggestion(band: .moderate, acwr: 1.0, hadHighIntensityWithin24h: false, hadHighIntensityWithin48h: false)
        XCTAssertEqual(suggestion.title, "Moderate-intensity steady-state, skip intervals")
    }

    func testRecoverAlwaysSuggestsRestRegardlessOfHistory() {
        let withHistory = suggester.suggestion(band: .recover, acwr: 1.6, hadHighIntensityWithin24h: true, hadHighIntensityWithin48h: true)
        let withoutHistory = suggester.suggestion(band: .recover, acwr: nil, hadHighIntensityWithin24h: false, hadHighIntensityWithin48h: false)
        XCTAssertEqual(withHistory.title, "Rest, mobility, or a short easy walk")
        XCTAssertEqual(withoutHistory.title, "Rest, mobility, or a short easy walk")
    }
}
