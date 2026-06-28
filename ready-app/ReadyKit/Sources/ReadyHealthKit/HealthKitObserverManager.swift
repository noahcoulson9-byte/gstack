import HealthKit

/// Registers `HKObserverQuery` + background delivery for the types a nightly refresh actually
/// depends on (new sleep data overnight, a fresh HRV reading on waking). Must be re-registered
/// on every launch — HealthKit does not durably persist `HKObserverQuery` registrations across
/// full app termination the way it does the background-delivery enable flag itself.
public actor HealthKitObserverManager {
    private let healthStore: HKHealthStore
    private var activeQueries: [HKObserverQuery] = []
    private var onUpdate: (@Sendable () -> Void)?

    public init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    /// `onUpdate` fires once per HealthKit-delivered update, on an arbitrary background queue.
    /// Callers (typically `ReadinessViewModel`) should debounce/dispatch into their own refresh path.
    public func start(onUpdate: @escaping @Sendable () -> Void) async throws {
        self.onUpdate = onUpdate
        stop()

        for type in ReadyHealthKitTypes.backgroundDeliveryTypes {
            try await healthStore.enableBackgroundDelivery(for: type, frequency: .immediate)

            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completionHandler, _ in
                // Must call completionHandler before returning, or iOS throttles future background delivery.
                defer { completionHandler() }
                Task { await self?.notifyUpdate() }
            }
            healthStore.execute(query)
            activeQueries.append(query)
        }
    }

    public func stop() {
        for query in activeQueries {
            healthStore.stop(query)
        }
        activeQueries.removeAll()
    }

    private func notifyUpdate() {
        onUpdate?()
    }
}
