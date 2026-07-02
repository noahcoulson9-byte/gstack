import HealthKit
import ReadyScoring

public enum HealthKitManagerError: Error, Sendable {
    case healthDataUnavailable
}

/// Owns the app's single `HKHealthStore` and exposes typed async fetch methods. Read-only:
/// `requestAuthorization` is always called with an empty `toShare` set. All query wiring lives
/// here so the rest of the app only deals in plain `ReadyScoring` model types.
public actor HealthKitManager {
    public let healthStore = HKHealthStore()
    public let permissionStatus = HealthKitAuthorizationStatus()

    public init() {}

    /// Returns `true` if the system reports the authorization sheet completed successfully.
    /// Per-type read grants remain unknowable (see `HealthKitAuthorizationStatus`).
    @discardableResult
    public func requestAuthorization() async throws -> Bool {
        guard permissionStatus.isHealthDataAvailable() else {
            throw HealthKitManagerError.healthDataUnavailable
        }
        try await healthStore.requestAuthorization(toShare: [], read: ReadyHealthKitTypes.allReadTypes)
        return true
    }

    /// One daily value per day in `[startDate, endDate)`, aggregated with `options`
    /// (e.g. `.discreteAverage` for HRV/RHR/respiratory rate, `.cumulativeSum` for active energy/steps).
    public func fetchDailyQuantitySamples(
        type: HKQuantityType,
        unit: HKUnit,
        from startDate: Date,
        to endDate: Date,
        options: HKStatisticsOptions,
        calendar: Calendar = .current
    ) async throws -> [DailyMetricSample] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        var interval = DateComponents()
        interval.day = 1

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: calendar.startOfDay(for: startDate),
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var samples: [DailyMetricSample] = []
                results?.enumerateStatistics(from: startDate, to: endDate) { statistics, _ in
                    let quantity: HKQuantity?
                    switch options {
                    case .cumulativeSum:
                        quantity = statistics.sumQuantity()
                    default:
                        quantity = statistics.averageQuantity()
                    }
                    guard let quantity else { return }
                    samples.append(DailyMetricSample(day: statistics.startDate, value: quantity.doubleValue(for: unit)))
                }
                continuation.resume(returning: samples)
            }
            healthStore.execute(query)
        }
    }

    /// Raw quantity samples in range, sorted oldest-to-newest. Used for sleeping-HR derivation
    /// (filtering `heartRate` samples down to a night's asleep windows) and cardio recovery.
    public func fetchQuantitySamples(
        type: HKQuantityType,
        from startDate: Date,
        to endDate: Date,
        limit: Int = HKObjectQueryNoLimit
    ) async throws -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sortDescriptor]) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKQuantitySample]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    public func fetchSleepSamples(from startDate: Date, to endDate: Date) async throws -> [HKCategorySample] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: ReadyHealthKitTypes.sleepAnalysis, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            healthStore.execute(query)
        }
    }

    public func fetchWorkouts(from startDate: Date, to endDate: Date) async throws -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: ReadyHealthKitTypes.workoutType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sortDescriptor]) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (results as? [HKWorkout]) ?? [])
            }
            healthStore.execute(query)
        }
    }
}
