// Our own recovery score (0-100) from this morning's Apple Watch metrics, scored
// against the user's personal rolling baseline. HRV (heart-rate variability) is
// the dominant signal — higher than your baseline means well recovered. Resting
// heart rate refines it (lower than baseline is better), and sleep nudges it.
//
// This is an honest approximation of a Whoop/Athlytic-style recovery score, not a
// clinical measure. It gets sharper as the baseline fills in: with fewer than a
// few days of history it falls back to gentle population anchors and is marked
// "calibrating".

function mean(arr) {
  const xs = arr.filter((v) => Number.isFinite(v));
  return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;
}
function clamp(n, lo, hi) { return Math.max(lo, Math.min(hi, n)); }

// today/baseline ratio -> 0..1. At baseline (1.0) you're solid; +15% is excellent,
// -20% is poor. Linear ramp between.
function hrvScore(ratio) { return clamp((ratio - 0.80) / (1.15 - 0.80), 0, 1); }
// baselineRHR - todayRHR (positive = lower HR than usual = better). +/-6 bpm spans the range.
function rhrScore(deltaBpm) { return clamp((deltaBpm + 6) / 12, 0, 1); }
// hours of sleep -> 0..1. ~4h is poor, ~8h is full.
function sleepScore(hours) { return hours == null ? null : clamp((hours - 4) / (8 - 4), 0, 1); }

const HRV_ANCHOR = 45;  // ms, gentle adult SDNN-ish reference used until a baseline exists
const RHR_ANCHOR = 60;  // bpm
const MIN_BASELINE_DAYS = 3;

// metrics: { hrv, rhr, sleepHours } (any may be null/undefined)
// history: array of prior-day { hrv, rhr } objects (today excluded)
function computeRecovery(metrics, history = []) {
  const hrv = Number(metrics.hrv);
  const rhr = Number(metrics.rhr);
  const sleepHours = metrics.sleepHours == null ? null : Number(metrics.sleepHours);

  const hrvHist = history.map((h) => Number(h.hrv)).filter(Number.isFinite);
  const rhrHist = history.map((h) => Number(h.rhr)).filter(Number.isFinite);
  const hrvBase = hrvHist.length >= MIN_BASELINE_DAYS ? mean(hrvHist) : null;
  const rhrBase = rhrHist.length >= MIN_BASELINE_DAYS ? mean(rhrHist) : null;

  const parts = [];
  if (Number.isFinite(hrv) && hrv > 0) {
    const ratio = hrv / (hrvBase || HRV_ANCHOR);
    parts.push({ w: 0.60, s: hrvScore(ratio) });
  }
  if (Number.isFinite(rhr) && rhr > 0) {
    parts.push({ w: 0.25, s: rhrScore((rhrBase || RHR_ANCHOR) - rhr) });
  }
  const ss = sleepScore(sleepHours);
  if (ss != null) parts.push({ w: 0.15, s: ss });

  if (!parts.length) return null;
  const wsum = parts.reduce((a, p) => a + p.w, 0);
  const score = parts.reduce((a, p) => a + p.w * p.s, 0) / wsum;
  return {
    recovery: Math.round(clamp(score * 100, 1, 99)),
    calibrating: hrvBase === null,           // true until enough baseline days
    baselineDays: hrvHist.length,
  };
}

module.exports = { computeRecovery };
