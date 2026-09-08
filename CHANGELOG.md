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
  per-device battery level and firmware version.
- **`FirmwareService` / DFU** — firmware updates over Nordic SMP (McuManager)
  using bundled `.bin` images and GitHub Releases as the update source.
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
  paused-state reminder (triple `.notification` every 20s, 30-minute cap).
- **`WorkoutManager`** — `HKWorkoutSession` wrapper. An active session gives
  background runtime (BLE + timer keep running) and makes wrist-raise return
  to the app instead of the watch face. Runs whenever a device is connected,
  playback is open, or a match is under way — including while paused, which
  is what lets the pause reminder tap off-screen.
- **`TimerView`** — countdown UI; ticker-driven text (stays populated in the
  always-on dim state), full-screen TAP-TO-STOP alarm state on expiry. The
  edit screen carries the duration, period, and the count-up-through-pause
  toggle (stopwatch glyph, bottom-left).
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
  tap start/pause, reset. Timer stays visible wrist-up and wrist-down
  (always-on display), and the app returns on wrist raise while running.
- **Stoppage handling** (watch): pausing stops the countdown while the
  count-up runs on through the stoppage, so it reads total elapsed time
  including stoppages (toggle in the edit screen; off = both clocks freeze).
  A triple tap every 20 seconds reminds the wrist that the countdown is
  still paused.
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
