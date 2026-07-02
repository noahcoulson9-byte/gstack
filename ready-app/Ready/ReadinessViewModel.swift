import Combine
import Foundation
import HealthKit
import ReadyHealthKit
import ReadyScoring

/// Glues `ReadyHealthKit` (fetch + map raw samples) to `ReadyScoring` (pure math) and publishes
/// the result for `ReadinessView`. Owns the single `HealthKitManager`/`HealthKitObserverManager`
/// pair for the app's lifetime.
@MainActor
final class ReadinessViewModel: ObservableObject {
    @Published private(set) var permissionState: HealthKitPermissionState = .notRequestedYet
    @Published private(set) var result: ReadinessResult = .insufficient
    @Published private(set) var activitySuggestion: ActivitySuggestion?
    @Published private(set) var recommendedBedtime: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var healthDataUnavailable = false

    /// Hour-of-day (24h) used as the default target wake time for tonight's bedtime suggestion.
    var targetWakeHour = 7

    private let healthKitManager = HealthKitManager()
    private let observerManager: HealthKitObserverManager
    private let baselineEngine = BaselineEngine()
    private let sleepAnalyzer = SleepAnalyzer()
    private let sleepDebtCalculator = SleepDebtCalculator()
    private let bedtimeRecommender = BedtimeRecommender()
    private let workoutLoadAnalyzer = WorkoutLoadAnalyzer()
    private let readinessScorer = ReadinessScorer()
    private let activitySuggester = ActivitySuggester()
    private let calendar: Calendar = .current

    init() {
        observerManager = HealthKitObserverManager(healthStore: healthKitManager.healthStore)
    }

    /// Call once, from the app's root view `.task`. Requests authorization, registers background
    /// delivery, then runs the first `refresh()`.
    func start() async {
        guard healthKitManager.permissionStatus.isHealthDataAvailable() else {
            healthDataUnavailable = true
            return
        }

        do {
            let granted = try await healthKitManager.requestAuthorization()
            permissionState = granted ? .requestedPerTypeUnknown : .requestSheetDismissedWithoutGranting
        } catch {
            permissionState = .requestSheetDismissedWithoutGranting
            return
        }

        try? await observerManager.start { [weak self] in
            Task { @MainActor in
                await self?.refresh()
            }
        }

        await refresh()
    }

    /// Re-fetches everything and recomputes today's score. Safe to call repeatedly — from
    /// foreground (`scenePhase == .active`), pull-to-refresh, and the observer-query callback.
    func refresh() async {
        guard !healthDataUnavailable, permissionState != .notRequestedYet else { return }
        isLoading = true
        defer { isLoading = false }

        let now = Date()
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(
            byAdding: .day,
            value: -(BaselineEngine.baselineWindowDays + 1),
            to: today
        ) else { return }

        do {
            async let hrvSamples = healthKitManager.fetchDailyQuantitySamples(
                type: ReadyHealthKitTypes.hrv,
                unit: HKUnit.secondUnit(with: .milli),
                from: windowStart,
                to: now,
                options: .discreteAverage,
                calendar: calendar
            )
            async let rhrSamples = healthKitManager.fetchDailyQuantitySamples(
                type: ReadyHealthKitTypes.restingHeartRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                from: windowStart,
                to: now,
                options: .discreteAverage,
                calendar: calendar
            )
            async let respSamples = healthKitManager.fetchDailyQuantitySamples(
                type: ReadyHealthKitTypes.respiratoryRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                from: windowStart,
                to: now,
                options: .discreteAverage,
                calendar: calendar
            )
            async let energySamples = healthKitManager.fetchDailyQuantitySamples(
                type: ReadyHealthKitTypes.activeEnergyBurned,
                unit: .kilocalorie(),
                from: windowStart,
                to: now,
                options: .cumulativeSum,
                calendar: calendar
            )
            async let sleepCategorySamples = healthKitManager.fetchSleepSamples(from: windowStart, to: now)
            async let heartRateSamples = healthKitManager.fetchQuantitySamples(type: ReadyHealthKitTypes.heartRate, from: windowStart, to: now)
            async let workoutSamples = healthKitManager.fetchWorkouts(from: windowStart, to: now)

            let hrv = try await hrvSamples
            let rhr = try await rhrSamples
            let resp = try await respSamples
            let energy = try await energySamples
            let nights = HealthSampleMapper.mapSleepSamples(try await sleepCategorySamples, heartRateSamples: try await heartRateSamples, calendar: calendar)
            let workouts = HealthSampleMapper.mapWorkouts(try await workoutSamples)

            computeReadiness(hrv: hrv, rhr: rhr, respiratoryRate: resp, activeEnergy: energy, nights: nights, workouts: workouts, today: today, now: now)
        } catch {
            result = .insufficient
            activitySuggestion = nil
            recommendedBedtime = nil
        }
    }

    private func computeReadiness(
        hrv: [DailyMetricSample],
        rhr: [DailyMetricSample],
        respiratoryRate: [DailyMetricSample],
        activeEnergy: [DailyMetricSample],
        nights: [SleepNight],
        workouts: [WorkoutRecord],
        today: Date,
        now: Date
    ) {
        let hrvBaseline = baselineEngine.trailingBaseline(allSamples: hrv, referenceDay: today, calendar: calendar)
        let rhrBaseline = baselineEngine.trailingBaseline(allSamples: rhr, referenceDay: today, calendar: calendar)
        let respBaseline = baselineEngine.trailingBaseline(allSamples: respiratoryRate, referenceDay: today, calendar: calendar)

        let hrvToday = hrv.first(where: { calendar.isDate($0.day, inSameDayAs: today) })?.value
        let rhrToday = rhr.first(where: { calendar.isDate($0.day, inSameDayAs: today) })?.value
        let respToday = respiratoryRate.first(where: { calendar.isDate($0.day, inSameDayAs: today) })?.value

        let lastNight = nights.first(where: { calendar.isDate($0.night, inSameDayAs: today) })
            ?? nights.max(by: { $0.night < $1.night })

        let candidateNights: [SleepNeedCandidateNight] = nights.map { night in
            let nextDay = calendar.date(byAdding: .day, value: 1, to: night.night) ?? night.night
            let nextDayRHR = rhr.first(where: { calendar.isDate($0.day, inSameDayAs: nextDay) })?.value
            let z = nextDayRHR.flatMap { value in rhrBaseline?.zScore(today: value, floor: ReadinessScorer.restingHeartRateFloor) }
            return SleepNeedCandidateNight(night: night, nextDayRestingHeartRateZScore: z)
        }
        let sleepNeed = sleepDebtCalculator.estimateSleepNeedMinutes(candidateNights: candidateNights)

        let debtWindowStart = calendar.date(byAdding: .day, value: -SleepDebtCalculator.debtWindowDays, to: today)
        let trailingNights = nights
            .filter { night in debtWindowStart.map { night.night >= $0 } ?? false }
            .sorted { $0.night < $1.night }
        let debt = sleepDebtCalculator.currentDebtMinutes(nights: trailingNights, sleepNeedMinutes: sleepNeed)

        var wakeComponents = calendar.dateComponents([.year, .month, .day], from: today)
        wakeComponents.day = (wakeComponents.day ?? 0) + 1
        wakeComponents.hour = targetWakeHour
        wakeComponents.minute = 0
        let targetWakeTime = calendar.date(from: wakeComponents) ?? today.addingTimeInterval(24 * 3600)
        recommendedBedtime = bedtimeRecommender.recommendedBedtime(
            targetWakeTime: targetWakeTime,
            sleepNeedMinutes: sleepNeed,
            debtMinutes: debt
        )

        let sleepScore = lastNight.flatMap { sleepAnalyzer.sleepScore(for: $0, sleepNeedMinutes: sleepNeed) }

        let acwr = workoutLoadAnalyzer.acwr(dailyLoad: activeEnergy, referenceDay: today, calendar: calendar)
        let acwrScore = acwr.map { workoutLoadAnalyzer.score(forACWR: $0) }

        let input = ReadinessScoringInput(
            hrv: ReadinessMetricInput(today: hrvToday, baseline: hrvBaseline),
            restingHeartRate: ReadinessMetricInput(today: rhrToday, baseline: rhrBaseline),
            respiratoryRate: ReadinessMetricInput(today: respToday, baseline: respBaseline),
            sleepScore: sleepScore,
            acwrScore: acwrScore,
            acwr: acwr
        )
        let scoringResult = readinessScorer.score(input)
        result = scoringResult

        if let band = scoringResult.band {
            let hadHigh24h = workoutLoadAnalyzer.hadWorkout(intensity: .high, withinHours: 24, of: now, in: workouts)
            let hadHigh48h = workoutLoadAnalyzer.hadWorkout(intensity: .high, withinHours: 48, of: now, in: workouts)
            activitySuggestion = activitySuggester.suggestion(
                band: band,
                acwr: acwr,
                hadHighIntensityWithin24h: hadHigh24h,
                hadHighIntensityWithin48h: hadHigh48h
            )
        } else {
            activitySuggestion = nil
        }
    }
}
