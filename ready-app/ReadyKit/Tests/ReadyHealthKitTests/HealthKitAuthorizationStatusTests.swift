import XCTest
import HealthKit
@testable import ReadyHealthKit

final class HealthKitAuthorizationStatusTests: XCTestCase {
    func testIsHealthDataAvailableDoesNotCrash() {
        // Smoke test only — the real answer depends on the runtime (simulator vs. iPad, which
        // lacks HealthKit entirely), so we just confirm the call is safe to make from any context.
        _ = HealthKitAuthorizationStatus().isHealthDataAvailable()
    }

    func testAllReadTypesContainsEveryDocumentedSource() {
        let types = ReadyHealthKitTypes.allReadTypes
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.hrv))
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.restingHeartRate))
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.heartRate))
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.respiratoryRate))
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.wristTemperature))
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.oxygenSaturation))
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.activeEnergyBurned))
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.stepCount))
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.heartRateRecoveryOneMinute))
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.sleepAnalysis))
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.workoutType))
        XCTAssertEqual(types.count, 11)
    }

    func testBackgroundDeliveryTypesCoverSleepAndHRV() {
        let types = ReadyHealthKitTypes.backgroundDeliveryTypes
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.sleepAnalysis))
        XCTAssertTrue(types.contains(ReadyHealthKitTypes.hrv))
    }
}
