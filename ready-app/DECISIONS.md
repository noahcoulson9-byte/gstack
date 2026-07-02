# Decisions log — Ready build

Every ambiguity hit during the build, and the call made, in order.

## 1. New top-level `ready-app/` directory, matching repo convention

This repo (`gstack`) is AI-agent tooling with no existing native-iOS app.
Per explicit user confirmation, Ready lives at a new top-level `ready-app/`
directory, matching the `<name>-app/` convention already used by
`morning-dew-app/` and `weather-timer-app/` (each with their own
`README.md`/`DECISIONS.md`), rather than trying to retrofit it into an
existing folder or a different repo.

## 2. Local SPM package split: `ReadyScoring` (pure) vs. `ReadyHealthKit` (HealthKit-dependent)

HealthKit queries cannot run under plain `swift test` — they need a
simulator or device. Since this build environment has no Swift toolchain at
all (see decision 5), maximizing what's testable without one was the
priority. `ReadyScoring` depends only on `Foundation` and contains every
formula (baseline z-scores, ACWR, sleep debt, bedtime, band thresholds,
activity-suggestion branching) — fully unit-testable with
`swift test --package-path ready-app/ReadyKit`. `ReadyHealthKit` is reduced
to "fetch raw HealthKit samples → map into `ReadyScoring`'s plain model
types," the minimum surface that actually needs HealthKit.

## 3. Sleeping heart rate has no dedicated HealthKit identifier

HealthKit exposes `restingHeartRate` (a daily aggregate) and `heartRate`
(continuous samples) but no `sleepingHeartRate` type. Decision: derive it by
filtering regular `heartRate` samples down to those whose start time falls
inside that night's asleep-stage windows (`HealthSampleMapper.averageHeartRate`),
averaging across whatever heart-rate samples land in those windows. Daytime
heart-rate samples are excluded by construction since they fall outside
every asleep window.

## 4. Workout intensity classified by kcal/min, with a fallback for non-builder workouts

`HKWorkout.statistics(for:)` only returns data when the workout was recorded
via `HKWorkoutBuilder` (the modern path most fitness apps use). Workouts
imported or logged through older APIs return `nil` from `statistics(for:)`,
which would silently zero out their energy and misclassify them as low
intensity. Decision: `HealthSampleMapper.mapWorkouts` falls back to the
deprecated `workout.totalEnergyBurned` property when `statistics(for:)`
returns nil, so legacy-recorded workouts still classify correctly. Caught
while writing `HealthSampleMapperTests` — the original test only checked
that `mapWorkouts` didn't crash, not that intensity classification was
actually correct for workouts built via the deprecated initializer.

## 5. No Swift/Xcode toolchain available in the build sandbox

This Linux sandbox has no `swift`, `xcodebuild`, or simulator. Every Swift
file in this build — `ReadyScoring`, `ReadyHealthKit`, the Xcode app target,
and all SwiftUI views — was written and hand-verified against Apple's
documented API surface (iOS 16+ HealthKit identifiers, `HKWorkoutBuilder`
statistics API, Swift concurrency patterns) without ever being compiled.
The `Ready.xcodeproj/project.pbxproj` itself was hand-authored (no Xcode GUI
to generate it), since that was the only available path to a working Xcode
project. `ReadyScoringTests`' math was hand-traced rather than run, catching
at least two bugs that a compiler/test run would have caught immediately
(see decisions 4 and 6) — this is the best verification ceiling available
without macOS, and the README says so explicitly. First real build/run
should happen in Xcode before relying on this for actual training decisions.

## 6. Sleep-night attribution to the wake date, not the start date

A session that starts at 11pm and ends at 7am is conventionally "last
night's sleep" when discussed the next morning, even though it started the
day before. Decision: `HealthSampleMapper.night(from:)` attributes each
session to `calendar.startOfDay(for: inBedEnd)` — the wake date — not the
start date, matching how Health and most sleep-tracking apps surface "last
night." Sessions separated by more than `sessionGapHours` (1 hour) are split
into separate nights so a daytime nap doesn't merge into the same session as
the prior overnight sleep.

## 7. Bundle identifier and signing left as placeholders

`PRODUCT_BUNDLE_IDENTIFIER` is set to `com.readyapp.Ready` and
`CODE_SIGN_STYLE` to `Automatic` with no `DEVELOPMENT_TEAM`, since neither a
real bundle ID nor an Apple Developer team is available to this build.
Whoever opens the project in Xcode needs to set their own team under
Signing & Capabilities before it will run on a device (simulator works
without one). This is a one-line settings change, not a code change.
