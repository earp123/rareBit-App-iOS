# Task: Stoppage timer — tap tracks delays without stopping the match clock (watch)

Directive (Sam, 2026-09-07): as an **optional setting**, a tap on a *running*
match timer must NOT pause anything. Instead it starts a new, separate timer
that counts up from 0 and keeps its own running elapsed total — a way to log
football delays (injury, VAR, substitutions) while the clock keeps running.
This is a **distinct setting from the existing count-up overlay** (the green
elapsed/period readout in `TimerView`), which stays as-is and is not the
subject of this task.
Scope: watch app only (`Watch Receiver Watch App/`: `MatchTimer`, `TimerView`).
iOS companion untouched. Branch: `feature/stoppage-timer`.

---

## Behavior

**Setting:** `stoppageTapEnabled` (Bool, default `false`, `@AppStorage`).
Exposed in the existing edit view (where the 1st/2nd period selector lives)
as a small toggle/capsule labelled **"Stoppage"**. Only editable when the timer
is not running (same rule as duration).

**Setting OFF** — no change from today: tap start/pause, alarm tap-to-stop.

**Setting ON, timer `.running`:**
1. Tap → **open** a stoppage segment: `stoppageSegmentStart = now`.
2. Tap again → **close** the segment: add its length to `stoppageTotal`,
   increment `stoppageCount`.
3. Repeat. Match clock is never paused by a tap.
4. **Long-press (~0.6 s) on the clock = pause** (the only way to pause while the
   setting is on). Long-press while paused/idle = start.
5. Match expiry (`.finished`) with a segment open → close it into the total.
   Alarm tap-to-stop is unchanged and takes priority over everything.
6. `reset()` clears `stoppageTotal`, `stoppageCount`, open segment.
   Period switch does not clear it (2nd half normally follows a reset anyway).

**Setting ON, timer `.idle`/`.paused`:** tap starts the match as today
(nothing to log yet). No stoppage segment can be opened unless `.running`.

**Display:** second overlay line directly under the green count-up, orange,
`+MM:SS` = `stoppageTotal + (open segment elapsed)`. While a segment is open,
show a small dot/“●” prefix (or brighter weight) so the ref can see it's
counting. Hidden entirely when the setting is off. Must render via the
existing 0.5 s ticker so it survives always-on dim state.

**Haptics:** one light `.click` on segment open, one `.directionDown`
(or similar, distinct from flag presets) on close — confirms the tap landed
without looking. Keep it far lighter than the expiry alarm.

## Autonomous decisions (flag if you disagree)

- Tap **toggles** a segment (open/close) rather than only ever opening new
  ones — a delay has a start and an end; the total is the sum of segments.
- Pause moves to **long-press** when the setting is on. Risk: discoverability;
  mitigation is a one-line hint in the edit view next to the toggle
  (“Tap logs delay · Hold pauses”).
- Stoppage state lives in `MatchTimer` (not the view) so it survives view
  reloads and can be closed on expiry inside the alarm path.

## Tasks

1. **Make:** `MatchTimer` — stoppage state + `toggleStoppage()`; close open
   segment on expiry/`alarmSessionDidFire`; clear on `reset()`. `TimerView` —
   `@AppStorage` toggle in edit view, tap/long-press routing in `handleTap`,
   orange overlay line.
2. **Test (on-wrist, setting ON):** start 2:00 timer → tap at ~0:30, tap at
   ~0:45, tap at ~1:10, let it expire with the segment open. Expect clock
   never paused; overlay shows ≈ +00:15 after 2nd tap, ≈ +01:05 at expiry;
   alarm still tap-to-stop; long-press pauses/resumes.
3. **Test (setting OFF):** tap pauses exactly as before; no orange line;
   count-up overlay unchanged in both modes.
4. **Assess:** always-on dim state keeps the orange line ticking; background
   (wrist down 30 s) → total is correct on return; reset clears it; no change
   in expiry-alarm behavior.
5. **CHANGELOG.md:** Features line + History entry; note the setting is
   distinct from the count-up overlay and that pause becomes long-press when on.

## Not in this task

- Persisting stoppage totals across app launches or to the iOS app.
- Per-segment history / list of delays (only count + total for now).
- Applying the setting to the iOS companion or Android/Garmin.
