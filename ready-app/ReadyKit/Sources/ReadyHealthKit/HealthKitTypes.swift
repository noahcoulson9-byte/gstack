import HealthKit

/// Single source of truth for every HealthKit type Ready reads. Ready never writes to Health —
/// `requestAuthorization` is always called with an empty `toShare` set.
public enum ReadyHealthKitTypes {
    public static let hrv = HKQuantityType(.heartRateVariabilitySDNN)
    public static let restingHeartRate = HKQuantityType(.restingHeartRate)
    /// There is no dedicated "sleeping heart rate" identifier — Ready derives it by filtering
    /// regular `heartRate` samples down to windows that overlap a night's asleep* sleep stages.
    public static let heartRate = HKQuantityType(.heartRate)
    public static let respiratoryRate = HKQuantityType(.respiratoryRate)
    public static let wristTemperature = HKQuantityType(.appleSleepingWristTemperature)
    public static let oxygenSaturation = HKQuantityType(.oxygenSaturation)
    public static let activeEnergyBurned = HKQuantityType(.activeEnergyBurned)
    public static let stepCount = HKQuantityType(.stepCount)
    public static let heartRateRecoveryOneMinute = HKQuantityType(.heartRateRecoveryOneMinute)
    public static let sleepAnalysis = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    public static let workoutType = HKObjectType.workoutType()

    public static var allReadTypes: Set<HKObjectType> {
        [
            hrv,
            restingHeartRate,
            heartRate,
            respiratoryRate,
            wristTemperature,
            oxygenSaturation,
            activeEnergyBurned,
            stepCount,
            heartRateRecoveryOneMinute,
            sleepAnalysis,
            workoutType,
        ]
    }

    /// Types backed by `HKObserverQuery` + background delivery, since they're the ones a
    /// nightly refresh actually depends on (new sleep data, new HRV reading on waking).
    public static var backgroundDeliveryTypes: [HKSampleType] {
        [sleepAnalysis, hrv]
    }
}
