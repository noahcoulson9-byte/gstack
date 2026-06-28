# Ready

A native iOS readiness app. Reads heart rate variability, resting/sleeping
heart rate, sleep stages, respiratory rate, wrist temperature, blood oxygen,
active energy, steps, and workouts from Apple Health, and computes an
independent 0–100 daily readiness score, a training-session suggestion, and
tonight's recommended bedtime — entirely on-device. No backend, no
third-party API calls, no write access to Health.

This exists because devices like Bevel write their own computed recovery
score into Apple Health, but HealthKit does not let a third-party app read
another app's proprietary score — only the raw signals underneath it. Ready
reads those raw signals and computes its own score from scratch.

## Architecture

```
ready-app/
├── Ready.xcodeproj/       # thin app target: SwiftUI views + @main wiring only
├── Ready/
│   ├── ReadyApp.swift          # @main, scenePhase-driven refresh
│   ├── ReadinessViewModel.swift  # glues ReadyHealthKit fetch/map to ReadyScoring math
│   ├── Info.plist              # NSHealthShareUsageDescription, background processing mode
│   ├── Ready.entitlements      # HealthKit + background delivery entitlements
│   ├── Assets.xcassets/
│   └── Views/
│       ├── ReadinessView.swift
│       ├── ReadinessRingView.swift
│       ├── MetricCardView.swift
│       ├── ActivitySuggestionCardView.swift
│       ├── BedtimeCardView.swift
│       └── PermissionStatusView.swift
└── ReadyKit/               # local Swift Package — all non-UI logic
    ├── Sources/
    │   ├── ReadyHealthKit/   # HealthKit fetch + sample mapping (depends on HealthKit)
    │   ├── ReadyScoring/     # baseline/ACWR/sleep-debt/bedtime/scoring math (pure Foundation)
    │   └── ReadyTestSupport/ # deterministic mock fixtures for tests
    └── Tests/
        ├── ReadyScoringTests/   # runs with plain `swift test`, no simulator needed
        └── ReadyHealthKitTests/ # constructs HKQuantitySample/HKCategorySample directly
```

**Why a local package for the logic?** HealthKit queries only run inside a
simulator or device — they can't run under plain `swift test`. Splitting the
scoring math (z-scores, ACWR, sleep debt, bedtime, band thresholds) into
`ReadyScoring`, which has zero HealthKit dependency, makes the entire
correctness-critical core testable with `swift test` and no Xcode project
involved. `ReadyHealthKit`'s job is reduced to "fetch raw samples → map into
`ReadyScoring`'s plain model types," keeping the untestable-without-a-device
surface as thin as possible.

## How the score is computed

1. **Baseline** — 28-day trailing mean/stddev per metric (HRV, resting heart
   rate, respiratory rate), requiring at least 5 valid days or the metric is
   dropped rather than guessed at.
2. **Sleep sub-score** — duration vs. personal sleep-need estimate (70 pts)
   plus a deep/REM/core stage-quality mix (30 pts).
3. **Training load (ACWR)** — acute (7-day) vs. chronic (28-day) average
   active energy. Scores peak in the 0.8–1.3 "sweet spot," penalizing both
   detraining and injury-risk spikes.
4. **Final score** — weighted blend (HRV 35%, sleep 25%, resting HR 20%,
   ACWR 15%, respiratory rate 5%) of each metric's z-score deviation from
   baseline, normalized to 0–100. Missing metrics drop out and the remaining
   weights renormalize. Fewer than 2 available metrics → "insufficient data"
   instead of a misleading number.
5. **Band** — ≥75 Ready to Train, ≥50 Moderate, <50 Recover. Each band maps
   to a specific session suggestion, adjusted for high-intensity workouts in
   the last 24–48 hours.
6. **Bedtime** — adaptive sleep-need (median of trailing "clean" nights, or a
   480-minute default) plus 7-day sleep debt (50%-efficiency repayment on
   surplus nights), subtracted from a configurable target wake time.

## Run it

This was built without Xcode/macOS available in the build environment, so it
has **not been compiled or run**. To build and run:

```bash
cd ready-app
open Ready.xcodeproj
```

In Xcode: select a simulator or device running iOS 16+, set your own
development team under Signing & Capabilities (the entitlements already
declare HealthKit + background delivery), and run. The Health permission
sheet should appear on first launch — Ready requests read-only access and
never asks to write anything.

To run just the scoring logic's tests (no simulator needed):

```bash
swift test --package-path ready-app/ReadyKit
```

`ReadyHealthKitTests` (sample-mapping tests) need a simulator — run them from
within Xcode, or `xcodebuild test -scheme ReadyKit -destination
'platform=iOS Simulator,name=iPhone 15'`.

## HealthKit notes

- **Read-only.** `requestAuthorization` is always called with an empty
  `toShare` set; `Ready.entitlements`'s `healthkit.access` array is
  intentionally empty (that key is for clinical-record types, not the
  standard quantity/category types Ready reads).
- **Per-type read denial is unobservable.** HealthKit does not tell a
  read-only app which individual types the user left enabled in the
  permission sheet — `authorizationStatus(for:)` only reports `.notDetermined`
  reliably; past that it's `.sharingAuthorized` regardless of the user's
  actual per-type choice. `HealthKitAuthorizationStatus.swift` documents this
  and the UI shows "no data found" rather than asserting denial.
- **Background delivery** is registered for sleep analysis and HRV (the two
  types a nightly refresh actually depends on) every launch — HealthKit does
  not durably persist `HKObserverQuery` registrations across full app
  termination, only the background-delivery enable flag itself.

See `DECISIONS.md` for the ambiguity log from this build.
