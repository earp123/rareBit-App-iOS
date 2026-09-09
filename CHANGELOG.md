# Changelog — Watch Receiver / rareBit

All notable changes to this project are documented here. Dates are ISO 8601.

---

## App Architecture

One Xcode project, two apps sharing a bundle (`rareBit.Watch-Receiver` v2.0.1):

### iOS app — `rareBit App/` (target: *Watch Receiver*)
Companion/management app for the rareBit device family (PRO Flag, PRO Receiver,
Relay, BLINK RED — exact-name matched in `RareBitFirmware.swift`).

- **`BleScanner`** — CoreBluetooth central. Scans for `rareBit`-named devices,
  handles multi-device connections, reads/writes the CFG service, tracks
  per-device battery level and firmware version, and reads the battery
  diagnostic characteristic where firmware exposes it.
- **`FirmwareService` / DFU** — firmware updates over Nordic SMP (McuManager)
  using bundled `.bin` images and GitHub Releases as the update source. Two
  channels: the public repo (stable, unauthenticated, cached) and, in Debug
  builds only, a PAT-authenticated development channel reading
  `development`-branch pre-releases from the private firmware repo.
- **`ScanListView` / `DeviceDetailView`** — device list and per-device
  config UI (short-press enable/delay, battery, DFU).

### watchOS app — `Watch Receiver Watch App/` (target: *Watch Receiver Watch App*)
On-wrist receiver a referee wears during a match. Two swipeable UI paths
(`ContentView` TabViews): device flow (DeviceDetail + Timer) and playback flow
(HapticPlayback + Timer).

- **`WatchBLEScanner`** — CoreBluetooth central. Filters scan results by name
  (all of `["rareBit", "Relay"]`) AND advertised service; connects to the
  Relay, subscribes to the notify characteristic, plays per-flag haptic
  presets on alerts, auto-reconnects once armed — including after a connect
  that never lands, not just after a disconnect.
- **`MatchTimer`** — match interval countdown (≤45:00, 2 periods) plus an
  independently-anchored count-up, so a stoppage can freeze the countdown
  while the count-up keeps tracking wall-clock time. Owns the expiry alarm: a
  scheduled smart-alarm `WKExtendedRuntimeSession` (`SmartAlarmSession`)
  buzzes from the background until acknowledged, with an in-process haptic
  loop as foreground fallback and a 5-minute auto-silence cap. Also owns the
  paused-state reminder (triple `.notification` every 20s, 30-minute cap) and
  the stoppage log — opened/closed delay segments summing to `stoppageTotal`,
  closed automatically on expiry.
- **`WorkoutManager`** — `HKWorkoutSession` wrapper. An active session gives
  background runtime (BLE + timer keep running) and makes wrist-raise return
  to the app instead of the watch face. Runs whenever a device is connected,
  playback is open, or a match is under way — including while paused, which
  is what lets the pause reminder tap off-screen.
- **`TimerView`** — countdown UI; ticker-driven text (stays populated in the
  always-on dim state), full-screen TAP-TO-STOP alarm state on expiry. The
  edit screen carries the duration, period, the count-up-through-pause
  toggle (stopwatch glyph, bottom-left) and the Stoppage capsule (top-right).
- Background modes (`Watch-Receiver-Watch-App-Info.plist`):
  `workout-processing`, `alarm`, `bluetooth-alert`.

---

## BLE Encoding Schemes

### Relay → Watch: alert service
- Service `33210001-28d5-4b7b-bad0-7dee1eee1b6d` (must be advertised to pass
  the watch scan filter)
- Notify characteristic `33210002-28d5-4b7b-bad0-7dee1eee1b6d` — single status
  byte per notification:

| Bits | Meaning |
|------|---------|
| 7 | Flag 1 linked |
| 6 | Flag 2 linked |
| 5–2 | (unused) |
| 1–0 | Alert source: `0x00` none (status only), `0x01` Flag 1, `0x02` Flag 2 |

Alerts trigger the per-flag haptic preset (cooldown-gated). Presets
(`HapticPreset`): Double `.notification` / Quad `.success` / Triple `.failure`,
user-assignable per flag from the watch.

### iOS ↔ device: CFG service
- Service `23220001-38d5-4b7b-bad0-7dee1eee1b6d`
- CFG characteristic `23220002-…` — single config byte (read/notify/write;
  writes always preserve unrelated bits from the last device-reported byte):

| Bits | Meaning |
|------|---------|
| 7–6 | Battery level: `0` low, `1` mid, `2` high, `3` full |
| 5–2 | Short-press delay, ×20 ms (0–15) |
| 1 | (unused) |
| 0 | Short-press enabled |

- FWV characteristic `23220003-…` — firmware version byte: high nibble major,
  low nibble minor (e.g. `0x20` → 2.0).
- Battery diagnostic characteristic `23220005-…` — read-only, no notify,
  9 bytes little-endian. **Flag / Receiver ≥ 2.0 only**; absent on fielded
  1.9 / 1.8 / 10.0 and on the Relay, whose ADC is still a stub. Absence is
  the normal case and changes nothing:

| Bytes | Meaning |
|-------|---------|
| 0–1 | Raw ADC counts (int16) |
| 2–3 | Millivolts at the divider tap (int16); `-1` (`0xFFFF`) = read failed |
| 4–5 | errno from the last attempt (int16); `0` = OK |
| 6 | Graded level `0` low, `1` mid, `2` high, `3` full (same value as CFG bits 7–6) |
| 7 | bit0 USB docked · bit1 charger STAT high · bit2 sense fault |
| 8 | Sample counter, wraps |

### iOS ↔ device: DFU (Nordic SMP / McuManager)
- Service `8D53DC1D-1DB7-4CD3-868B-8A527460AA84`,
  characteristic `DA2E7828-FBCE-4E01-AE9E-261174997C48`
- Standard MCUboot image upload via `iOSMcuManagerLibrary`. Firmware for all
  products comes from the public `rareBit-firmware-releases` repo: releases
  tagged `<product>-v<version>` (flag / rx / rxrly / relay), each carrying a
  `manifest.json`; SMP products flash the SHA-256-verified `ota_image` .bin.

---

## Features

- **Match timer** (watch): ≤45-minute countdown, 1st/2nd period count-up
  overlay (2nd period counts 45:00→90:00), crown-editable duration,
  tap start/pause (long-press instead when the Stoppage setting is on), reset. Timer stays visible wrist-up and wrist-down
  (always-on display), and the app returns on wrist raise while running.
- **Count-up through stoppages** (watch): pausing stops the countdown while
  the count-up runs on through the stoppage, so it reads total elapsed time
  including stoppages (stopwatch toggle in the edit screen; off = both clocks
  freeze). A triple tap every 20 seconds reminds the wrist that the countdown
  is still paused.
- **Stoppage log** (watch, opt-in, off by default): with the Stoppage setting
  on, a tap on a *running* clock no longer pauses — it opens a delay segment,
  and the next tap closes it. Injuries, VAR and substitutions get logged as an
  orange `+MM:SS` running total under the count-up while the match clock keeps
  going; pause moves to a long-press. A distinct setting from the count-up
  overlay above, which is unaffected.
- **Expiry alarm** (watch): near-continuous heavy haptics from foreground or
  background until acknowledged by a screen tap anywhere; dedicated full-screen
  acknowledge UI; 5-minute auto-silence safety cap.
- **Flag alerts** (watch): Relay pushes flag events; per-flag assignable haptic
  presets with playback testing; link-status display for both flags.
- **Auto-connect** (watch): the first Relay to pass the scan filters is
  connected and opened straight to the flag screen, no tap needed. Assumes a
  single Relay in the field; with more than one it takes the strongest
  advertiser. The card stays tappable as the manual path.
- **Device management** (iOS): scan/connect multiple rareBit devices, battery
  and firmware readout, short-press configuration, OTA firmware update (DFU).

---

## History

### 2026-09-08 — Development firmware channel behind the hidden dev gesture (iOS)
- The hidden DFU card — the one behind the 3-second hold on the device title
  card — **is now the development channel**, rather than the stable updater
  with a dev panel stacked on top of it. Unlocked, the card leads with a
  "Development channel" header and carries a single primary button that reads
  `Fetch dev build`, then `Install dev v2.0.0 (build 57)` once armed. The
  stable Install Update / Manual buttons are not shown in that mode: the card
  isn't the stable updater while it's being a dev tool. iOS twin of Android's
  10 s `DEV_HOLD_MS` dev card.
- Unforced, the card is byte-for-byte what it was — same banner, same buttons,
  same behaviour. Only the hold-to-unlock state changed.
- **No version gate on the dev path.** Dev builds share a pinned version byte
  per stream (flag/rx `0x20`, RXRLY `0xA1`), so a version comparison says
  nothing about them — they're told apart by `build`. The armed release skips
  `checkFirmwareUpdate` entirely; the developer chose it. Ordering comes from
  parsing the `-dev.<n>` suffix rather than trusting GitHub's list order.
- **The stable path cannot be affected.** `latestDevRelease` never writes into
  `cached`, which is what feeds stable checks — so a failed or stale dev fetch
  can't poison a later `Install Update`. The public repo publishes from
  `production` only, so no prerelease guard is needed there (Android needed
  one only because it still reads stable from the private repo).
- Private-repo assets are fetched through the asset API `url` with
  `Accept: application/octet-stream` plus the PAT; `browser_download_url`
  404s on a private repo. SHA-256 verification is unchanged and still
  mandatory on the dev path.
- **The PAT cannot ship.** Every dev reference — the service call, the private
  repo URL, the armed-release state, the card — is inside `#if DEBUG`.
  Verified against a Release-configuration binary: no token-shaped string, no
  `githubPAT` symbol, and no trace of the private repo URL. `ship.sh` installs
  Debug, so the developer path is unaffected.
- The armed release clears on disconnect, on leaving the detail view, and
  hence after a successful flash (the reboot disconnects). Log lines:
  `[FW] dev <tag> → <byte> build <n>`, `[FW] dev armed`, `[FW] dev cleared`.
- Product mapping is the stable path's, so a receiver on RXRLY firmware
  fetches `RXRLY_` rather than `PRO_RX_`. Cross-grade via the dev channel is
  out of scope.
- **Verified on hardware (9 Sep):** a v1.9 Flag fetched
  `PRO_FLAG_v2.0.0-dev.8` (`0x20`, build 8), downloaded it from the private
  repo through the asset API URL, passed SHA-256, uploaded over SMP, rebooted
  and read back `FWV 0x20`. `[FW] dev cleared` fired on the reboot disconnect,
  so the armed release doesn't survive a flash. The PAT in `Secrets.swift` is
  confirmed still valid.
- The armed button says `Install build 8`, not the version — dev builds share
  a pinned version byte, so the build number is the identifying part, and the
  full version is already on the banner above it. Spelling it out truncated
  the button on a 4.7" screen.

### 2026-09-08 — Battery read failures and sense faults are no longer shown as "flat" (iOS)
- The CFG byte's battery bits (7–6) have no "unknown" value, so a unit whose
  ADC read fails — or whose sense divider is the wrong part, a 680R-for-68k1
  batch was confirmed on the bench — reports **LOW forever** and earns a red
  glow that isn't true. Firmware 2.0 exposes what it actually measured on a
  new read-only diagnostic characteristic (`23220005-…`, 9 bytes LE), so the
  app can stop calling a faulted unit a flat one.
- Two new `BatteryLevel` cases, `.unavailable` and `.senseFault`, and a new
  `effectiveBatteryLevel(for:)` with precedence: sense fault wins, then
  `mv == -1 || errno != 0` → unavailable, else the CFG bits as before. No
  diag (legacy units, Relay) falls straight through to the old path.
- **`DeviceConfig` and `BatteryLevel`-from-byte are untouched.** The CFG write
  base and the config re-apply cache keep deriving from the CFG byte exactly
  as before — the diagnostic is display-only and issues no writes.
- UI: the Battery label and the detail-screen glow read the effective level;
  both fault cases reuse the existing unknown yellow rather than adding a
  colour, since "don't trust this" is what yellow already means here. The
  glow's visibility gate moved to the same source so it can't disagree with
  the colour. A "Battery diagnostic" line (`1043 mV · errno 0 · docked · STAT
  high · #37`) appears in the expandable info area only when the
  characteristic is present.
- Read on discovery after the CFG read, and re-read on every CFG notification
  since the battery bits changing makes the diagnostic behind them stale. No
  in-flight guard — CoreBluetooth queues GATT ops.
- `ScanListView`'s border and its brighter "full" glow read the effective
  level too, so the scan list and the detail screen can't disagree about a
  faulted unit. Initially left on the CFG byte because the task scoped that
  file out — closed once the bench run produced a real sense-faulted Flag that
  glowed red in the list while the detail screen said SENSE FAULT.
- Firmware caveat recorded, not acted on: STAT high also reads high when
  nothing drives the pin, so sense fault is only unambiguous undocked. The app
  only ever sees a docked device and does no extra inference.
- **Verified on hardware (9 Sep), and it caught a real fault on first use.**
  Absence path first: the same Flag on v1.9 exposed no `…0005` characteristic,
  logged no `[BLE] BATT` lines, and showed the CFG-derived `LOW` unchanged —
  the per-notification re-read correctly no-ops when the handle is nil, so
  legacy units see no extra traffic. Flashed to 2.0 and the characteristic
  appeared: `mv=36 err=0 lvl=BATTERY_LOW flags=0x05 n=3`. Bit 2 set, so the
  app resolved `.senseFault` and showed **SENSE FAULT** in yellow where
  minutes earlier the same unit with the same cell had shown a red `LOW`.
  Exactly the false-flat this exists to stop.
- That unit reads **36–43 mV** at the divider tap across 40 samples against a
  healthy ~1000–1070 mV, with `errno 0` throughout — the ADC read succeeds and
  measures almost nothing, which is the 680R-for-68k1 divider batch. Note the
  sense-fault *bit* is only unambiguous undocked and this was read docked; the
  millivolt figure is the independent evidence. 40 reads produced no CFG
  write, no malformed payload and no SHA mismatch.

### 2026-09-07 — Stoppage log: tap tracks delays without stopping the clock (watch)
- Per Sam's directive: as an **optional setting**, a tap on a running match
  timer must not pause anything. `stoppageTapEnabled` (`@AppStorage`, default
  **off**) rewires the tap to open/close a delay segment instead, so injury,
  VAR and substitution time can be logged while the match clock runs on.
- **Distinct from the count-up overlay.** The green elapsed/period readout and
  its count-up-through-pause toggle are untouched by this — they answer "how
  much wall-clock has passed", the orange line answers "how much of it was
  delay". Both can be on at once; the two toggles sit at opposite corners of
  the edit screen and are separately persisted.
- Tap **toggles** rather than only ever opening: a delay has a start and an
  end, and `stoppageTotal` is the sum of closed segments (`stoppageCount`
  tracks how many). Segments can only be opened while `.running` — there is
  nothing to log before kick-off, and a paused clock is already logging the
  stoppage as pause time.
- **Pause moves to a long-press (0.6 s)** while the setting is on — the only
  way to pause in that mode. The discoverability cost is real, so the edit
  screen carries a "Tap logs delay · Hold pauses" hint under the toggle
  whenever it's on. With the setting off the gesture map is completely
  unchanged, long-press included.
- Display: second readout under the green count-up, orange `+MM:SS`,
  prefixed with `●` while a segment is open so "counting now" reads
  differently from "counted earlier". Driven by the existing 0.5 s ticker
  rather than a `Text(timerInterval:)`, so it survives the always-on dim
  state; `syncTicker()` now also keeps the ticker alive for an open segment,
  which is what makes a segment left open across a long-press pause keep
  counting.
- Both readouts were an `.overlay` on the countdown, and overlays swallow hit
  tests — so a tap landing on the numerals themselves never reached the clock.
  Now `.allowsHitTesting(false)`, making the whole screen one tap zone in
  fact rather than just in intent. Pre-existing bug, not introduced here.
- Timer screen relaid out around the new readout (Sam, on-wrist): reset and
  settings moved into a single top bar with the readouts centred between
  them, which frees the entire lower screen for the countdown, now anchored
  to the bottom edge with 2pt of padding. Two things had been keeping it
  visually centred — the button row's clearance, and ~20pt of descender space
  the rounded face reserves under the digits regardless of alignment.
  Readouts stayed at 24/18pt: the slot between the two buttons is only ~90pt
  wide and the stoppage line already fills ~77pt of it, so a size bump pushed
  the buttons apart. Sizing up would mean giving the readouts their own row.
- Edit screen: the up/down chevrons are gone — the crown is the only way to
  set the digits now. That freed the middle of the top row, which is what
  lets the period selector and the Stoppage capsule share it without
  colliding.
- Expiry closes an open segment into the total on both paths — the in-app
  `tick()` and `alarmSessionDidFire()`, which is what runs when the app was
  suspended through expiry. Silent in both cases: a confirmation haptic under
  a sounding alarm would be pointless. Alarm tap-to-stop is untouched and
  still takes priority over everything.
- Haptics are deliberately slight — `.click` on open, `.directionDown` on
  close — to confirm the tap landed without looking, and to stay far away
  from both the flag presets and the expiry alarm.
- `reset()` clears the total, count and any open segment; switching period
  does not (the second half normally follows a reset anyway). Turning the
  setting off closes an open segment first, so it can't keep counting
  invisibly from behind a hidden readout.
- Not in scope: persisting totals across launches, per-segment history, and
  any iOS-companion surface.

### 2026-09-04 — Auto-connect to the Relay on discovery (watch)
- Discovering a Relay now connects and pushes the flag screen automatically;
  previously it sat on a card waiting for a tap. Single-Relay assumption per
  Sam; `devices` is RSSI-sorted so `.first` is the strongest advertiser if
  that ever stops holding. Tapping the card still works.
- Both paths now go through `connectAndStayConnected`, which fixes a latent
  bug: the tap called the bare `connect`, so `isConnecting` was already true
  by the time `DeviceDetailView.onAppear` ran its
  `!isConnected && !isConnecting` guard — auto-reconnect was never armed from
  the tap path at all.
- `didFailToConnect` now retries via the reconnect scan when armed. Only
  `didDisconnectPeripheral` used to, so a connect that never landed stranded
  the detail screen on "Connecting…" with no back button — a path
  auto-connect makes far easier to hit.

### 2026-09-04 — Stoppage-time count-up and paused-countdown reminder (watch)
- The count-up now runs off its own anchor instead of being derived from the
  countdown, so pausing can stop one clock and not the other. After a
  stoppage the count-up leads the countdown's elapsed time by the time
  paused, and can exceed the match duration — that's the intent: it reads
  total elapsed time, stoppages included.
- Toggle `countUpContinuesWhilePaused` (stopwatch glyph, bottom-left of the
  edit screen, `UserDefaults`-persisted, default on). Off restores the old
  behaviour where both clocks freeze together. Toggling while paused takes
  effect on the stoppage already in progress.
- Paused-countdown reminder: three `.notification` taps 300ms apart — the
  closest WatchKit gets to a triple tap — repeating every 20s, first fired
  one full interval after the pause. Capped at 30 minutes so a watch left
  paused on the bench doesn't tap all night. Started on `.click`, the
  lightest haptic, and it was unnoticeable on the wrist; `.notification` is
  the strongest available, so rhythm rather than weight is what keeps the
  reminder distinct from the flag presets and the expiry alarm — a tight
  burst of exactly three against a slow pair and a continuous buzz.
- The workout session now survives a pause (`MatchTimer.isActive`), which is
  what lets the reminder tap while the app is off-screen; previously
  navigating away from a paused timer killed it.

### 2026-09-04 — Naming convention: "Relay" is the device, RXRLY is the firmware
- Customer-facing sweep: Receiver surfaces never say "Relay". Receiver
  firmware is "Receiver"/"RX"; the receiver-as-relay cross-grade firmware is
  "RXRLY" (card, buttons, alerts, error text). The word "Relay" appears only
  on surfaces about the Relay device itself.

### 2026-09-04 — Unified firmware fetch from the public releases repo (iOS)
- Bench-verified on hardware: two Relays updated v1.9 → v1.10 over the
  legacy-DFU path (prefix lookup), and an RXRLY receiver reverted to rx-v1.8
  over SMP with SHA-verified download and correct product re-resolution.
- All products (flag / rx / rxrly / relay) now fetch from
  `rareBit-firmware-releases`: latest release found by tag prefix (never
  `/latest`, which is meaningless in a shared repo), `manifest.json` parsed,
  artifacts SHA-256-verified before flashing. Session-cached per product.
- SMP products flash the verified `ota_image` .bin over McuManager (transport
  unchanged); Relay keeps the legacy-DFU zip flow. Receiver cross-grade cards
  (rx ↔ rxrly) use the same fetch path.
- Removed: private-repo `FirmwareService` (PAT-authenticated, hardcoded
  release tags), `releaseTag`/`firmwareResource` accessors, and the orphaned
  bundled .bin images. The GitHub PAT in `Secrets.swift` is no longer used.
- Fixed latent bug: the shipped Relay check used `/latest`, which now returns
  another product's release and would have broken Relay updates.

### 2026-08-23 — Relay OTA DFU flow (iOS)
- Implemented per `docs/relay-dfu-flow.md` (firmware side complete, relay-v1.9).
  Relay-only; PRO Flag / PRO Receiver keep the SMP (McuManager) flow unchanged.
- Update check: public `rareBit-firmware-releases` GitHub repo `/latest` +
  `manifest.json` (session-cached, unauthenticated), version byte compared to
  the FW characteristic; dfu zip SHA-256-verified before flashing.
- New CFG characteristic `23220004-…`: write `0xA8` (USB-docked only) to
  reboot into the bootloader; ATT errors mapped (0x03 = not docked).
- Flashing via Nordic legacy DFU (`NordicDFU` 4.16.0, new dependency);
  bootloader found by advertised service `00001530-…`, never by name.
- Recovery path: bootloader-mode Relays detected during scans surface a
  "Retry Flash" card in the scan list.
- UI: Firmware card on the Relay detail page (check / install / progress /
  post-flash version confirmation).

### 2026-08-22 — Match timer alarm, background survival, scan filtering
- Added smart-alarm `WKExtendedRuntimeSession` so timer expiry buzzes from the
  background until acknowledged (previously alarm died on backgrounding).
- Declared `WKBackgroundModes` (`workout-processing`, `alarm`,
  `bluetooth-alert`) — workout sessions now actually grant background runtime;
  the `.bluetoothAlert` background task is now functional.
- Workout session kept alive whenever the timer runs → wrist-raise returns to
  the app; timer digits stay populated in always-on dim state.
- Full-screen TAP-TO-STOP acknowledge UI; removed un-cancellable
  `repeatForever` pulse animation; more aggressive alarm haptics.
- Watch scanner now requires the alert service in the advertisement AND name
  containing both "rareBit" and "Relay" (was: any "rareBit" device).
- Fixed `watch_ship.sh` build/install script (watchOS destination ECID vs
  devicectl UUID; direct watch install).

### 2026 (earlier) — v2.0.1 groundwork
- Match timer with period support and settings UI; workout session manager;
  BLE auto-reconnect ("armed" after notify subscription); haptic preset
  playback view. *(commits: "Home stretch changes", "haptic sequences are
  assignable and testable for user playback now")*

### Initial release
- iOS companion app: scanning, CFG read/write, battery/firmware display,
  SMP DFU with bundled + GitHub-released images.
- watchOS receiver: Relay connection, flag alert haptics, link status.
