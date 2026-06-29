import HealthKit

/// HealthKit deliberately does not expose per-type read-denial state to the requesting app —
/// `authorizationStatus(for:)` is only meaningful for *share* (write) types. For a read-only app
/// like Ready, the honest UI states are:
///   - `.notRequestedYet`: we haven't called `requestAuthorization` yet.
///   - `.requestSheetDismissedWithoutGranting`: the *system* told us the whole sheet completed
///     with `success == false` — the one unambiguous negative signal HealthKit gives us.
///   - `.requestedPerTypeUnknown`: authorization was requested and the system reported success,
///     but we still cannot tell which individual read types the user actually left enabled.
///   - `.confirmedNoSamples(Date)`: we ran a query for this type and it returned zero samples —
///     UI-distinguishable from outright denial; copy should say "no data found" rather than
///     "access denied", since this can also mean the user's device simply doesn't produce this
///     metric (e.g. no Apple Watch for HRV/SpO2).
public enum HealthKitPermissionState: Sendable, Equatable {
    case notRequestedYet
    case requestSheetDismissedWithoutGranting
    case requestedPerTypeUnknown
    case confirmedNoSamples(lastChecked: Date)
    case confirmedHasSamples(lastChecked: Date)
}

public struct HealthKitAuthorizationStatus: Sendable {
    public init() {}

    public func isHealthDataAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Coarse signal from `authorizationStatus(for:)`. Reliable only for "not determined yet"
    /// (pre-prompt); once requested, HealthKit reports `.sharingAuthorized` for read-only types
    /// regardless of the user's actual per-type read choice, so callers should treat anything
    /// past `.notDetermined` as `.requestedPerTypeUnknown` rather than trusting this value
    /// further.
    public func coarseStatus(for type: HKObjectType, store: HKHealthStore) -> HKAuthorizationStatus {
        store.authorizationStatus(for: type)
    }
}
