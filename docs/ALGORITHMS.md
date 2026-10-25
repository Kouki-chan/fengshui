# Algorithms

Spec §10 is the source; this page records how its "scale down partial evidence; document your scoring" was implemented. Every number is a named constant in `engine/fengshui_engine/config.py`. Deviations are listed in DECISIONS D-12 and D-13.

## Features (`features-v1`, per minute)

| Feature | Computation |
| --- | --- |
| `enmo_mg` | mean over samples of max(\|a\| − 1 g, 0) × 1000 |
| `mag_sd_mg` | population SD of \|a\| × 1000 |
| `cadence_hz` | \|a\| decimated to 25 Hz; per 10 s window: autocorrelation for lags 0.5–3.5 Hz, first local maximum ≥ 0.3, parabolic interpolation; median of the windows; NULL if none. Skipped when `mag_sd_mg` < 13 (still) |
| `active_frac` | share of 5 s epochs whose mean ENMO > 45 mg |
| `pressure_kpa` | mean barometer pressure in the minute |
| `vert_speed_m_min` | slope of altitude (−Δp × 8.3 m/hPa) by linear fit over samples within ± 2 min |
| `heading_change_deg` | sum of absolute circular heading differences (magnetometer heading, D-11) |
| `gyro_rms_dps` | RMS of \|ω\| in °/s |

Accelerometer source: tier 1, else tier 3. A minute is recomputed when a chunk for it arrives after its row was computed.

## Activity (`activity-v1`)

**Evidence per minute:** prorated steps (zero counts as evidence only on days with any step samples), heart rate (HealthKit + session HR, gaps ≤ 10 min interpolated), HRR = (HR − rest)/(max − rest) with rest = 7-day median resting HR (default 60) and max = 208 − 0.7 × age (default 35), raw features, prorated flights, phone motion (label + confidence), visits.

**Scores** (0–1). Missing sources contribute nothing; the label's score is the maximum over its evidence lines:

| Label | Evidence → score |
| --- | --- |
| workout | inside a logged workout → 1 (fixed) |
| sleep | inside the main sleep episode → 1 (fixed, below workout) |
| watch_off | inside a run of ≥ 60 min with `mag_sd_mg` < 13 and no HR sample → 1 |
| running | steps ≥ 130 → 1; 110–129 → 0.6 × (steps − 110)/20; phone running → 1.0 (high), 0.8 (medium), 0.4 (low); cadence ≥ 2.4 Hz and ENMO > 250 mg → 1 |
| walking | 60–129 steps → 1; 40–59 → 0.7 × (steps − 40)/20; ≥ 130 → 0.3; phone walking as above; cadence 1.4–2.4 Hz and ENMO 60–250 mg → 0.8 |
| stairs | climbing (flights > 0 or \|vert speed\| ≥ 3 m/min) → max(walking, running). When climbing, walking and running are capped at 0.1 |
| cycling | phone cycling as above; HRR ≥ 0.40, < 20 steps, ENMO 40–150 mg → 0.9; HRR 0.30–0.40 → 0.4 |
| in_vehicle | phone automotive as above; between places, ENMO < 45 mg, < 10 steps → 0.7 |
| sedentary | < 10 steps and ENMO < 45 mg → 1; only one of the two → 0.7 (0.85 if the phone is also stationary); phone stationary alone → 0.7 × phone score. Multiplied by (1 − in_vehicle). Capped at 0.2 inside a watch-off run |
| light | ENMO 45–100 mg and < 60 steps → 1; ENMO 100–150 mg and < 60 steps → 0.5; 10–39 steps with ENMO missing or < 45 mg → 0.6 |
| unknown | no usable source → 1; a source exists but every score is 0 → 0.7 |

**Smoothing:** Viterbi with emission cost −log(score + 0.001), a switch penalty of 2.0, and fixed minutes allowed only their override. Then minimum bout lengths: the shortest short bout merges into the non-fixed neighbour whose label has the higher mean score over the short bout's minutes, repeated until none are left.

**Bout fields:** intensity from mean HRR (< 0.40 light, < 0.60 moderate, else vigorous; walking ≥ 100 steps/min is at least moderate). Place: "at X" by majority of minutes; between visits that leave and return to the same named place → "near X"; else "between places". For in_vehicle, `from`/`to` are the visits before and after. Confidence = mean(winner − runner-up) × share of minutes with ≥ 2 sources.

**Incremental:** re-label from (last finalized − 120 min), widened to the start of the stored bout containing that minute. Bouts ending within 120 min of now are provisional. A re-run inserts only rows that differ and supersedes the rows they replace; identical re-runs write nothing.

## Wind-down (`wind_down-v1`)

Implemented exactly as spec §10.2. The arithmetic is in `wind_down.compose()`, and the spec's worked example is a unit test. Clock-time medians are circular (unwrapped around the circular mean). Day type needs two weeks of location history first (D-12). Cold start (< 3 nights) uses the onboarding answers: wake by day type, and habitual onset = bedtime + 15 min. `night_of` is today from noon and yesterday before noon. The outcome task runs before the plan in a combined run, so a length change applies the same morning.
